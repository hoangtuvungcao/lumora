#!/usr/bin/env python3
"""End-to-end test: spawns real `lumorad` nodes and drives them over the JSON API.

    python3 core/tests/e2e.py [--bin core/target/debug/lumorad] [--relay ws://127.0.0.1:8443/ws] [--relay-only]

Scenarios: LAN discovery + direct QUIC, friend request/accept, 1-1 chat with acks
and read receipts, edit/react/delete, file transfer with BLAKE3 verification,
checklists, reminders, silent messages,
group create/invite/message/remove with key rotation, offline queue (outbox) delivery
after restart, encrypted-at-rest check.
"""
import argparse, base64, json, os, queue, shutil, subprocess, sys, tempfile, threading, time, hashlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Node:
    def __init__(self, name, binary, data, extra):
        self.name = name
        self.data = data
        self.binary = binary
        self.extra = extra
        self.events = queue.Queue()
        self.resp = {}
        self.cv = threading.Condition()
        self.next_id = 1
        self.start()

    def start(self):
        args = [self.binary, "--data", self.data, "--name", self.name, "--no-dht", "--no-upnp", "--stdio"] + self.extra
        self.log = open(os.path.join(self.data, "node.log"), "a")
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, text=True, bufsize=1)
        threading.Thread(target=self._reader, daemon=True).start()
        self.me = self.call("me")

    def _reader(self):
        for line in self.p.stdout:
            try:
                v = json.loads(line)
            except Exception:
                continue
            if "event" in v:
                self.events.put(v)
            elif "id" in v:
                with self.cv:
                    self.resp[v["id"]] = v
                    self.cv.notify_all()

    def call(self, cmd, timeout=60, **kw):
        with self.cv:
            i = self.next_id
            self.next_id += 1
        kw.update({"id": i, "cmd": cmd})
        self.p.stdin.write(json.dumps(kw) + "\n")
        self.p.stdin.flush()
        deadline = time.time() + timeout
        with self.cv:
            while i not in self.resp:
                left = deadline - time.time()
                if left <= 0:
                    raise TimeoutError(f"{self.name}: {cmd} timed out")
                self.cv.wait(left)
            r = self.resp.pop(i)
        if not r.get("ok"):
            raise RuntimeError(f"{self.name}: {cmd} failed: [{r.get('code')}] {r.get('error')} {r.get('detail') or ''}")
        return r.get("data")

    def call_many(self, cmd, items, timeout=300):
        """Pipeline many requests at once (no waiting in between); returns their results."""
        with self.cv:
            base = self.next_id
            self.next_id += len(items)
        lines = [json.dumps(dict(kw, id=base + k, cmd=cmd)) for k, kw in enumerate(items)]
        self.p.stdin.write("\n".join(lines) + "\n")
        self.p.stdin.flush()
        out = []
        deadline = time.time() + timeout
        with self.cv:
            for i in range(base, base + len(items)):
                while i not in self.resp:
                    left = deadline - time.time()
                    if left <= 0:
                        raise TimeoutError(f"{self.name}: {cmd} x{len(items)} timed out")
                    self.cv.wait(left)
                r = self.resp.pop(i)
                if not r.get("ok"):
                    raise RuntimeError(f"{self.name}: {cmd} failed: [{r.get('code')}] {r.get('error')}")
                out.append(r.get("data"))
        return out

    def all_messages(self, conv):
        """Every message of a conversation (pages of 500, oldest first)."""
        out, before = [], None
        while True:
            page = self.call("messages", conv=conv, limit=500, **({"before": before} if before is not None else {}))
            out = page + out
            if len(page) < 500:
                return out
            before = page[0]["hlc"]

    def wait_event(self, pred, timeout=30, what="event"):
        deadline = time.time() + timeout
        stash = []
        try:
            while time.time() < deadline:
                try:
                    e = self.events.get(timeout=max(0.05, deadline - time.time()))
                except queue.Empty:
                    break
                if pred(e):
                    return e
                stash.append(e)
        finally:
            for e in stash:
                self.events.put(e)
        raise TimeoutError(f"{self.name}: waiting for {what}")

    def stop(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


def wait_until(fn, timeout=30, what="condition"):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            v = fn()
            if v:
                return v
        except Exception as e:
            last = e
        time.sleep(0.25)
    raise TimeoutError(f"timeout waiting for {what} (last error: {last})")


RESULTS = []


def step(name):
    def deco(fn):
        def run(*a, **k):
            t = time.time()
            # E2E_SKIP="remote control,burst": leave out scenarios whose name contains one
            skip = [x.strip() for x in os.environ.get("E2E_SKIP", "").split(",") if x.strip()]
            if any(x in name for x in skip):
                print(f"  ⏭  {name} (skipped)", flush=True)
                return
            try:
                fn(*a, **k)
                RESULTS.append((name, True, time.time() - t, ""))
                print(f"  ✅ {name} ({time.time() - t:.2f}s)", flush=True)
            except Exception as e:
                RESULTS.append((name, False, time.time() - t, str(e)))
                print(f"  ❌ {name}: {e}", flush=True)
                if os.environ.get("E2E_DUMP"):
                    import re as _re, glob as _g
                    for lf in sorted(_g.glob(os.path.join(os.environ.get("E2E_TMP", "/nonexistent"), "*", "node.log"))):
                        lines = [_re.sub(r"\x1b\[[0-9;]*m", "", l) for l in open(lf, errors="replace")]
                        lines = [l for l in lines if "keyring" not in l and "mainline" not in l]
                        print("----", lf)
                        print("".join(l[11:230] + ("\n" if len(l) > 230 else "") for l in lines[-25:]))
                raise
        return run
    return deco


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, "target", "debug", "lumorad"))
    ap.add_argument("--relay", default=None)
    ap.add_argument("--relay-only", action="store_true", help="disable LAN so the relay path is exercised")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="lumora-e2e-")
    os.environ["E2E_TMP"] = tmp
    # voice-room presence expires after 15 s here (45 s by default) so the crash step is quick
    os.environ.setdefault("LUMORA_VOICE_TTL_MS", "15000")
    # remote lock / restart / log out are simulated on the host (debug-build hook): this
    # machine is never really locked, restarted or logged out; log out is made to fail
    os.environ["LUMORA_TEST_POWER"] = "fail=logout"
    os.environ.setdefault("LUMORA_TEST_CAMERA", "1")  # never open a real webcam
    extra = ["--no-nostr"]
    if a.relay:
        extra += ["--relay", a.relay, "--relay-delay", "0" if a.relay_only else "1500"]
    if a.relay_only:
        extra += ["--no-lan"]
    dirs = {n: os.path.join(tmp, n) for n in ["alice", "bob", "carol"]}
    for d in dirs.values():
        os.makedirs(d)
    print(f"data: {tmp}")
    A = Node("Alice", a.bin, dirs["alice"], extra + ["--downloads", os.path.join(dirs["alice"], "dl")])
    B = Node("Bob", a.bin, dirs["bob"], extra + ["--downloads", os.path.join(dirs["bob"], "dl")])
    C = Node("Carol", a.bin, dirs["carol"], extra + ["--downloads", os.path.join(dirs["carol"], "dl")])
    nodes = [A, B, C]
    ok = True
    try:
        pa, pb, pc = A.me["peer"], B.me["peer"], C.me["peer"]
        print(f"Alice {A.me['short_id']}  Bob {B.me['short_id']}  Carol {C.me['short_id']}")

        @step("connect Bob → Alice (path discovery)")
        def _():
            if a.relay_only:
                wait_until(lambda: all(r["connected"] for r in A.call("net_status")["relays"]) and all(r["connected"] for r in B.call("net_status")["relays"]), 20, "relays")
            r = B.call("connect", peer=pa, timeout=40)
            print(f"     path={r['path']} rtt={r['rtt_ms']}ms addr={r['remote_addr']}")
            if a.relay_only:
                assert r["path"] == "relay", r
        _()

        @step("friend request + accept")
        def _():
            B.call("add_contact", target=pa, note="Chào Alice!")
            e = A.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == pb, what="friend_request")
            assert e["note"] == "Chào Alice!"
            A.call("accept_contact", peer=pb)
            wait_until(lambda: any(c["peer"] == pa and c["status"] == 3 for c in B.call("contacts")), 15, "Bob sees friend")
            wait_until(lambda: any(c["peer"] == pb and c["status"] == 3 for c in A.call("contacts")), 15, "Alice sees friend")
        _()

        conv_ab = f"d:{pa}"

        @step("1-1 chat with delivery ack + read receipt (Vietnamese + emoji)")
        def _():
            t0 = time.time()
            m = B.call("send_text", conv=conv_ab, text="Xin chào 👋 tiếng Việt có dấu: ắ ổ ữ")
            e = A.wait_event(lambda e: e["event"] == "message" and e["id"] == m["id"], what="message")
            print(f"     delivery latency {(time.time() - t0) * 1000:.0f} ms")
            assert e["body"]["text"].startswith("Xin chào"), e
            wait_until(lambda: [x for x in B.call("messages", conv=conv_ab) if x["id"] == m["id"]][0]["status"] >= 2, 10, "delivered status")
            A.call("mark_read", conv=f"d:{pb}")
            wait_until(lambda: [x for x in B.call("messages", conv=conv_ab) if x["id"] == m["id"]][0]["status"] == 3, 10, "read status")
        _()

        @step("Double Ratchet session forms between friends; chat keeps working through it")
        def _():
            wait_until(lambda: A.call("security_status", peer=pb)["forward_secrecy"] or B.call("security_status", peer=pa)["forward_secrecy"], 15, "ratchet session")
            for i in range(5):
                m = B.call("send_text", conv=conv_ab, text=f"tin mã hóa nhiều lớp {i}")
                A.wait_event(lambda e, mid=m["id"]: e["event"] == "message" and e["id"] == mid, what="ratcheted msg")
                m2 = A.call("send_text", conv=f"d:{pb}", text=f"trả lời {i}")
                B.wait_event(lambda e, mid=m2["id"]: e["event"] == "message" and e["id"] == mid, what="ratcheted reply")
        _()

        @step("edit + react + delete propagate")
        def _():
            m = A.call("send_text", conv=f"d:{pb}", text="bản nháp")
            B.wait_event(lambda e: e["event"] == "message" and e["id"] == m["id"], what="msg")
            A.call("edit_message", conv=f"d:{pb}", msg_id=m["id"], text="bản chính thức")
            wait_until(lambda: [x for x in B.call("messages", conv=conv_ab) if x["id"] == m["id"]][0]["body"].get("text") == "bản chính thức", 10, "edit")
            B.call("react", conv=conv_ab, msg_id=m["id"], emoji="❤️", on=True)
            wait_until(lambda: "❤️" in ([x for x in A.call("messages", conv=f"d:{pb}") if x["id"] == m["id"]][0]["reactions"] or {}), 10, "reaction")
            A.call("delete_message", conv=f"d:{pb}", msg_id=m["id"])
            wait_until(lambda: [x for x in B.call("messages", conv=conv_ab) if x["id"] == m["id"]][0]["deleted"], 10, "delete")
            # Bob must not be able to edit Alice's message
            try:
                B.call("edit_message", conv=conv_ab, msg_id=m["id"], text="hack")
            except RuntimeError:
                pass
            time.sleep(0.5)
            assert [x for x in A.call("messages", conv=f"d:{pb}") if x["id"] == m["id"]][0]["body"].get("text") != "hack"
        _()

        @step("file transfer 12 MB (stream + BLAKE3 verify)")
        def _():
            src = os.path.join(dirs["bob"], "video-test.bin")
            with open(src, "wb") as f:
                f.write(os.urandom(12 * 1024 * 1024))
            h = hashlib.sha256(open(src, "rb").read()).hexdigest()
            t0 = time.time()
            fobj = B.call("send_file", conv=conv_ab, path=src)
            fid = fobj["id"]
            def done():
                fs = [x for x in A.call("files") if x["id"] == fid]
                return fs and fs[0]["state"] == 2 and fs[0]
            r = wait_until(done, 60, "file done")
            dt = time.time() - t0
            got = hashlib.sha256(open(r["path"], "rb").read()).hexdigest()
            assert got == h, "hash mismatch"
            print(f"     {12 / dt:.1f} MB/s → {r['path']}")
            wait_until(lambda: [x for x in B.call("files") if x["id"] == fid][0]["state"] == 2, 10, "sender done")
        _()

        @step("forward a text and a received file to another chat (no re-download)")
        def _():
            src = os.path.join(dirs["bob"], "bao-cao.pdf")
            open(src, "wb").write(b"%PDF-1.4 " + os.urandom(300_000))
            f = B.call("send_file", conv=conv_ab, path=src)
            wait_until(lambda: any(x["id"] == f["id"] and x["state"] == 2 for x in A.call("files")), 30, "pdf received")
            fmsg = [x for x in A.call("messages", conv=f"d:{pb}") if x["kind"] == "file" and x["body"].get("name") == "bao-cao.pdf"][0]
            # Carol must be Alice's friend for the forward target
            C.call("add_contact", target=pa)
            A.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == pc, what="carol req")
            A.call("accept_contact", peer=pc)
            wait_until(lambda: any(c["peer"] == pa and c["status"] == 3 for c in C.call("contacts")), 15, "carol friend")
            fw = A.call("forward_message", msg_id=fmsg["id"], to_conv=f"d:{pc}")
            def got_file():
                xs = [x for x in C.call("files") if x["name"] == "bao-cao.pdf" and x["state"] == 2]
                return xs and open(xs[0]["path"], "rb").read() == open(src, "rb").read()
            wait_until(got_file, 30, "forwarded file arrives intact at Carol")
            t = A.call("send_text", conv=f"d:{pb}", text="tin để chuyển tiếp")
            ft = A.call("forward_message", msg_id=t["id"], to_conv=f"d:{pc}")
            wait_until(lambda: any(x["id"] == ft["id"] for x in C.call("messages", conv=f"d:{pa}")), 15, "forwarded text")
        _()

        @step("photo: instant inline thumbnail, then full image")
        def _():
            img = os.path.join(dirs["bob"], "anh-du-lich.jpg")
            subprocess.run(["convert", "-size", "1600x1000", "plasma:violet-cyan", img], check=True)
            m = B.call("send_file", conv=conv_ab, path=img)
            e = A.wait_event(lambda e: e["event"] == "message" and e.get("kind") == "file" and e["body"].get("name") == "anh-du-lich.jpg", what="photo msg")
            assert e["body"]["thumb"], "no thumbnail"
            assert e["body"]["width"] == 1600 and e["body"]["height"] == 1000, e["body"]
            assert len(e["body"]["thumb"]) < 70000
            def full():
                x = [x for x in A.call("messages", conv=f"d:{pb}") if x["kind"] == "file" and x["body"].get("name") == "anh-du-lich.jpg"][0]
                return x.get("file", {}).get("state") == 2 and os.path.exists(x["file"]["path"])
            wait_until(full, 30, "full image downloaded")
        _()

        @step("mobile data: a 3 MB photo downloads by itself, a 3 MB file waits for a tap; roaming: photos wait too")
        def _():
            ad = A.call("settings_get")["auto_download"]
            assert ad["cell"]["photo"] == 5 << 20 and ad["cell"]["file"] == 0 and ad["cell"]["video"] == 0, ad
            assert ad["wifi"]["file_group"] == 10 << 20 and ad["roaming"]["photo"] == 1 << 20, ad
            assert A.call("set_network_hint", metered=True)["metered"]
            try:
                assert A.call("settings_get")["metered"]
                doc = os.path.join(dirs["bob"], "so-tay-3mb.pdf")
                open(doc, "wb").write(b"%PDF-1.4 " + os.urandom(3 << 20))
                pic = os.path.join(dirs["bob"], "anh-3mb.jpg")
                open(pic, "wb").write(b"\xff\xd8\xff\xe0" + os.urandom(3 << 20))
                fd = B.call("send_file", conv=conv_ab, path=doc)["id"]
                fp = B.call("send_file", conv=conv_ab, path=pic)["id"]
                state = lambda fid: next((x["state"] for x in A.call("files") if x["id"] == fid), None)
                wait_until(lambda: state(fp) == 2, 60, "3 MB photo auto-downloaded on mobile data")
                assert state(fd) == 0, f"3 MB file downloaded on mobile data (state {state(fd)})"
                # a tap still downloads it
                A.call("accept_file", file_id=fd)
                wait_until(lambda: state(fd) == 2, 60, "file downloaded after a tap")
                # roaming (or a metered Wi-Fi): the same 3 MB photo is above the 1 MB limit
                r = A.call("set_network_hint", network="roaming")
                assert r["network"] == "roaming" and r["metered"], r
                pic2 = os.path.join(dirs["bob"], "anh-3mb-2.jpg")
                open(pic2, "wb").write(b"\xff\xd8\xff\xe0" + os.urandom(3 << 20))
                fr = B.call("send_file", conv=conv_ab, path=pic2)["id"]
                wait_until(lambda: state(fr) is not None, 30, "roaming photo offered")
                time.sleep(2)
                assert state(fr) == 0, f"3 MB photo downloaded while roaming (state {state(fr)})"
            finally:
                A.call("set_network_hint", network="wifi")
            assert not A.call("settings_get")["metered"] and A.call("settings_get")["network"] == "wifi"
        _()

        @step("file previews before download: .py snippet, .pdf first page, binary .txt refused")
        def _():
            import base64
            # Alice only downloads on demand, so everything below is seen *before* the download
            A.call("settings_set", auto_download={"wifi": {"file": 0}})
            try:
                py = os.path.join(dirs["bob"], "xu_ly_anh.py")
                code = "".join(f"def buoc_{i}(anh):\n    return anh  # bước {i} ✓\n\n" for i in range(400))
                open(py, "w", encoding="utf-8").write(code)
                m = B.call("send_file", conv=conv_ab, path=py)  # core makes the snippet itself
                e = A.wait_event(lambda e: e["event"] == "message" and isinstance(e.get("body"), dict) and e["body"].get("file_id") == m["id"], what="py msg")
                pv = e["body"].get("preview") or {}
                assert pv.get("kind") == "text" and pv["lines"] == 1200, pv
                assert pv["text"].startswith("def buoc_0(anh):\n    return anh  # bước 0 ✓"), pv
                assert 0 < len(pv["text"].encode()) <= 4096 and "\r" not in pv["text"], len(pv["text"])
                # app-made PDF preview: first page JPEG + page count (+ hostile text, sanitised)
                pdf = os.path.join(dirs["bob"], "hop-dong.pdf")
                open(pdf, "wb").write(b"%PDF-1.4 " + os.urandom(50_000))
                page = os.path.join(dirs["bob"], "page1.jpg")
                subprocess.run(["convert", "-size", "480x679", "xc:white", "-fill", "black", "-draw", "rectangle 40,40 440,90", "-quality", "70", page], check=True)
                jpg = open(page, "rb").read()
                m = B.call("send_file", conv=conv_ab, path=pdf, thumb_b64=base64.b64encode(jpg).decode(), width=480, height=679,
                           preview={"kind": "pdf", "pages": 12, "text": "Hợp đồng\x00\x1b[31m‮"})
                e = A.wait_event(lambda e: e["event"] == "message" and isinstance(e.get("body"), dict) and e["body"].get("file_id") == m["id"], what="pdf msg")
                b = e["body"]
                assert base64.b64decode(b["thumb"]) == jpg, "page image changed"
                assert b["preview"]["pages"] == 12 and b["preview"]["kind"] == "pdf", b["preview"]
                assert b["preview"]["text"] == "Hợp đồng[31m", repr(b["preview"]["text"])
                assert (b["width"], b["height"]) == (480, 679)
                fs = [x for x in A.call("files") if x["name"] == "hop-dong.pdf"]
                assert fs and fs[0]["state"] == 0 and fs[0]["preview"]["pages"] == 12, fs
                # a ZIP renamed to .txt gets no snippet
                fake = os.path.join(dirs["bob"], "ghi-chu.txt")
                open(fake, "wb").write(b"PK\x03\x04\x14\x00\x00\x00\x08\x00" + os.urandom(2000))
                m = B.call("send_file", conv=conv_ab, path=fake)
                e = A.wait_event(lambda e: e["event"] == "message" and isinstance(e.get("body"), dict) and e["body"].get("file_id") == m["id"], what="txt msg")
                assert "preview" not in e["body"] and not e["body"]["thumb"], e["body"]
                # forwarding keeps the preview (the core can't re-render a PDF itself)
                fmsg = [x for x in B.call("messages", conv=conv_ab) if x["kind"] == "file" and x["body"].get("name") == "hop-dong.pdf"][0]
                fw = B.call("forward_message", msg_id=fmsg["id"], to_conv=conv_ab)
                e = A.wait_event(lambda e: e["event"] == "message" and isinstance(e.get("body"), dict) and e["body"].get("file_id") == fw["id"], what="forwarded pdf")
                assert e["body"]["preview"]["pages"] == 12 and base64.b64decode(e["body"]["thumb"]) == jpg
            finally:
                A.call("settings_set", auto_download={"wifi": {"file": 25 << 20, "file_group": 10 << 20}})
        _()

        @step("group: create, invite, chat, gossip, remove + key rotation")
        def _():
            # Carol befriends Alice (unless an earlier scenario already did)
            if not any(c["peer"] == pc and c["status"] == 3 for c in A.call("contacts")):
                C.call("add_contact", target=pa)
                A.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == pc, what="carol req")
                A.call("accept_contact", peer=pc)
            g = A.call("create_group", name="Nhóm Dự Án 🚀", members=[pb, pc])
            gid, conv = g["gid"], g["conv"]
            wait_until(lambda: any(x["gid"] == gid for x in B.call("groups")), 20, "Bob joined")
            wait_until(lambda: any(x["gid"] == gid for x in C.call("groups")), 20, "Carol joined")
            m = B.call("send_text", conv=conv, text="Chào cả nhóm!")
            wait_until(lambda: any(x["id"] == m["id"] for x in C.call("messages", conv=conv)), 20, "Carol got Bob's group msg")
            wait_until(lambda: any(x["id"] == m["id"] for x in A.call("messages", conv=conv)), 20, "Alice got it")
            info = A.call("group_info", gid=gid)
            assert info["my_role"] == "owner" and len(info["members"]) == 3
            # Bob (member) cannot remove Carol
            try:
                B.call("group_remove", gid=gid, peer=pc)
                raise AssertionError("member removed someone")
            except RuntimeError:
                pass
            A.call("group_remove", gid=gid, peer=pc)
            wait_until(lambda: A.call("group_info", gid=gid)["epoch"] >= 1, 10, "rekey")
            wait_until(lambda: B.call("group_info", gid=gid)["epoch"] >= 1, 20, "Bob got new key")
            wait_until(lambda: C.call("group_info", gid=gid)["my_role"] == "none", 20, "Carol knows she was removed")
            secret = A.call("send_text", conv=conv, text="tin bí mật sau khi Carol rời")
            wait_until(lambda: any(x["id"] == secret["id"] for x in B.call("messages", conv=conv)), 20, "Bob reads after rekey")
            time.sleep(2)
            assert not any(x["id"] == secret["id"] for x in C.call("messages", conv=conv)), "removed member read new message!"
        _()

        @step("profile: bio, status, avatar propagate to friends")
        def _():
            import base64
            av = base64.b64encode(b"\x89PNG-fake-avatar" * 10).decode()
            A.call("set_profile", bio="Yêu công nghệ 💜", status="dnd", avatar=av)
            wait_until(lambda: [c for c in B.call("contacts") if c["peer"] == pa][0].get("bio") == "Yêu công nghệ 💜", 15, "bio")
            c = [c for c in B.call("contacts") if c["peer"] == pa][0]
            assert c["presence"] == "dnd" and c["has_avatar"], c
            assert B.call("contact_avatar", peer=pa)["avatar"] == av
        _()

        @step("mentions, forward, pin, poll + votes, saved messages")
        def _():
            gconv = [g for g in A.call("groups")][0]["conv"]
            m = A.call("send_message", conv=gconv, text="@Bob xem giúp nhé", mentions=[pb])
            B.wait_event(lambda e: e["event"] == "mention" and e["id"] == m["id"], what="mention")
            f = B.call("forward_message", msg_id=m["id"], to_conv=conv_ab)
            assert f["meta"]["forwarded_from"] == "Alice", f
            A.wait_event(lambda e: e["event"] == "message" and e["id"] == f["id"], what="forwarded msg")
            B.call("pin_message", conv=conv_ab, msg_id=f["id"], on=True)
            wait_until(lambda: any(x["id"] == f["id"] for x in A.call("pinned_messages", conv=f"d:{pb}")), 10, "pin propagates")
            poll = A.call("send_poll", conv=gconv, question="Đi ăn gì?", options=["Phở", "Bún chả", "Cơm tấm"])
            wait_until(lambda: any(x["id"] == poll["id"] for x in B.call("messages", conv=gconv)), 10, "poll arrives")
            B.call("vote", conv=gconv, msg_id=poll["id"], option=1)
            A.call("vote", conv=gconv, msg_id=poll["id"], option=1)
            def votes():
                x = [x for x in A.call("messages", conv=gconv) if x["id"] == poll["id"]][0]
                return len((x["reactions"] or {}).get("__votes", {})) == 2
            wait_until(votes, 10, "2 votes")
            sv = A.call("forward_message", msg_id=m["id"], to_conv="s:me")
            assert any(x["id"] == sv["id"] for x in A.call("messages", conv="s:me"))
        _()

        @step("message rules: forward names, author-only 1-1 delete, 48 h edits, timers")
        def _():
            def msg(node, conv, mid):
                xs = [x for x in node.call("messages", conv=conv) if x["id"] == mid]
                return xs[0] if xs else None

            def fence(sender, receiver, conv_s, conv_r):
                # a later message from the same sender: everything before it was handled
                f = sender.call("send_text", conv=conv_s, text="·")
                wait_until(lambda: msg(receiver, conv_r, f["id"]) is not None, 15, "fence message")

            # forwarding credits the author's own public name, never my nickname for them
            A.call("rename_contact", peer=pb, alias="Bạn thân bí mật")
            assert [c for c in A.call("contacts") if c["peer"] == pb][0].get("alias") == "Bạn thân bí mật"
            src = B.call("send_text", conv=conv_ab, text="tin gốc của Bob")
            wait_until(lambda: msg(A, f"d:{pb}", src["id"]) is not None, 15, "Bob's text")
            fw = A.call("forward_message", msg_id=src["id"], to_conv=f"d:{pc}")
            wait_until(lambda: msg(C, f"d:{pa}", fw["id"]) is not None, 15, "forwarded to Carol")
            got = msg(C, f"d:{pa}", fw["id"])
            assert got["meta"]["forwarded_from"] == "Bob", got["meta"]
            assert "bí mật" not in json.dumps(got, ensure_ascii=False)
            hid = A.call("forward_message", msg_id=src["id"], to_conv=f"d:{pc}", hide_sender=True)
            wait_until(lambda: msg(C, f"d:{pa}", hid["id"]) is not None, 15, "hidden-sender forward")
            got = msg(C, f"d:{pa}", hid["id"])
            assert not (got.get("meta") or {}).get("forwarded_from"), got
            A.call("rename_contact", peer=pb, alias="")

            # 1-1: only the author deletes for both — Bob can't delete Alice's message
            am = A.call("send_text", conv=f"d:{pb}", text="tin của Alice, Bob không xoá được")
            wait_until(lambda: msg(B, conv_ab, am["id"]) is not None, 15, "Alice's msg at Bob")
            try:
                B.call("delete_message", conv=conv_ab, msg_id=am["id"], for_everyone=True)
                raise AssertionError("Bob deleted Alice's message for both")
            except RuntimeError as e:
                assert "delete_not_yours" in str(e) or "chỉ có thể xoá" in str(e) or "own messages" in str(e), e
            # an older / modified app sends the delete anyway: Alice ignores it
            B.call("debug_action_unchecked", conv=conv_ab, msg_id=am["id"], kind="delete")
            fence(B, A, conv_ab, f"d:{pb}")
            assert not msg(A, f"d:{pb}", am["id"])["deleted"], "Alice's message deleted by Bob"
            # "delete for me" still works on any message
            B.call("delete_message", conv=conv_ab, msg_id=am["id"], for_everyone=False)
            assert msg(B, conv_ab, am["id"]) is None

            # edits: 48 h after the message's own signed time, no more
            A.call("debug_backdate_next", ago_ms=47 * 3_600_000)
            ok = A.call("send_text", conv=f"d:{pb}", text="47 giờ trước")
            A.call("debug_backdate_next", ago_ms=49 * 3_600_000)
            old = A.call("send_text", conv=f"d:{pb}", text="49 giờ trước")
            assert old["hlc"] < ok["hlc"]
            wait_until(lambda: msg(B, conv_ab, old["id"]) is not None and msg(B, conv_ab, ok["id"]) is not None, 15, "backdated msgs")
            A.call("edit_message", conv=f"d:{pb}", msg_id=ok["id"], text="sửa kịp")
            wait_until(lambda: msg(B, conv_ab, ok["id"])["body"].get("text") == "sửa kịp", 15, "edit within 48 h")
            try:
                A.call("edit_message", conv=f"d:{pb}", msg_id=old["id"], text="sửa muộn")
                raise AssertionError("edit after 48 h accepted on send")
            except RuntimeError as e:
                assert "edit_too_late" in str(e) or "48" in str(e), e
            A.call("debug_action_unchecked", conv=f"d:{pb}", msg_id=old["id"], kind="edit", text="sửa muộn")
            fence(A, B, f"d:{pb}", conv_ab)
            got = msg(B, conv_ab, old["id"])
            assert got["body"].get("text") == "49 giờ trước" and not got["edited"], got

            # self-destructing messages can't be forwarded
            t = B.call("send_text", conv=conv_ab, text="tự huỷ sau 1 phút", ttl_ms=60_000)
            wait_until(lambda: msg(A, f"d:{pb}", t["id"]) is not None, 15, "ttl msg")
            for who, mid in ((A, t["id"]), (B, t["id"])):
                try:
                    who.call("forward_message", msg_id=mid, to_conv="s:me")
                    raise AssertionError("forwarded a self-destructing message")
                except RuntimeError as e:
                    assert "cannot_forward_ttl" in str(e) or "tự huỷ" in str(e) or "Self-destructing" in str(e), e

            # groups: a message removed by an admin says so (deleted_by ≠ author)
            g = [g for g in A.call("groups")][0]
            gm = B.call("send_text", conv=g["conv"], text="tin Bob trong nhóm")
            wait_until(lambda: msg(A, g["conv"], gm["id"]) is not None, 20, "group msg at Alice")
            A.call("delete_message", conv=g["conv"], msg_id=gm["id"])
            wait_until(lambda: msg(B, g["conv"], gm["id"])["deleted"], 20, "admin removal reaches Bob")
            assert msg(B, g["conv"], gm["id"]).get("deleted_by") == pa
            own = B.call("send_text", conv=g["conv"], text="Bob tự thu hồi")
            wait_until(lambda: msg(A, g["conv"], own["id"]) is not None, 20, "Bob's 2nd group msg")
            B.call("delete_message", conv=g["conv"], msg_id=own["id"])
            wait_until(lambda: msg(A, g["conv"], own["id"])["deleted"], 20, "author recall reaches Alice")
            assert msg(A, g["conv"], own["id"]).get("deleted_by") == pb
        _()

        @step("location (static + live), contact card, voice message, stories")
        def _():
            loc = A.call("send_location", conv=f"d:{pb}", lat=10.7769, lon=106.7009, accuracy_m=12, label="Hồ Chí Minh", live_minutes=15)
            B.wait_event(lambda e: e["event"] == "message" and e["id"] == loc["id"], what="location")
            A.call("update_live_location", conv=f"d:{pb}", msg_id=loc["id"], lat=10.78, lon=106.71, accuracy_m=8)
            wait_until(lambda: abs([x for x in B.call("messages", conv=conv_ab) if x["id"] == loc["id"]][0]["body"]["lat"] - 10.78) < 1e-9, 10, "live update")
            card = A.call("send_contact", conv=f"d:{pb}", peer=pc)
            e = B.wait_event(lambda e: e["event"] == "message" and e["id"] == card["id"], what="contact card")
            assert e["body"]["peer"] == pc
            vf = os.path.join(dirs["alice"], "voice.ogg")
            open(vf, "wb").write(os.urandom(20000))
            v = A.call("send_voice", conv=f"d:{pb}", path=vf, duration_ms=4200, wave=[10, 80, 200, 120])
            def voice_done():
                x = [x for x in B.call("messages", conv=conv_ab) if x["id"] == v["id"]]
                return x and x[0].get("file", {}).get("state") == 2
            wait_until(voice_done, 20, "voice downloaded")
            st = A.call("post_story", text="Hôm nay trời đẹp ☀️", bg="sunset")
            B.wait_event(lambda e: e["event"] == "story" and e["id"] == st["id"], what="story")
            assert any(x["id"] == st["id"] for x in B.call("stories"))
            B.call("story_seen", story_id=st["id"])
            wait_until(lambda: pb in [v["peer"] for v in A.call("story_viewers", story_id=st["id"])], 10, "story view")
            # photo story: a big phone photo is shrunk to a JPEG and reaches the friend with its picture
            import struct, zlib
            w, h = 2400, 1600
            raw = b"".join(b"\x00" + bytes(v for x in range(w) for v in (x * 7 % 256, y % 256, 90)) for y in range(h))
            def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
            photo = os.path.join(dirs["alice"], "story.png")
            open(photo, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 1)) + chunk(b"IEND", b""))
            ps = A.call("post_story", image_path=photo, bg="aurora")
            B.wait_event(lambda e: e["event"] == "story" and e["id"] == ps["id"], what="photo story")
            assert [x for x in B.call("stories") if x["id"] == ps["id"]][0]["has_image"]
            assert not [x for x in B.call("stories") if x["id"] == st["id"]][0]["has_image"]
            img = base64.b64decode(B.call("story_image", story_id=ps["id"])["image"])
            assert img[:2] == b"\xff\xd8" and len(img) > 1000, len(img)
            # the author keeps it in their archive; deleting takes it down at the friend's too
            arch = A.call("story_archive")
            assert {ps["id"], st["id"]} <= {x["id"] for x in arch} and all(x["active"] for x in arch[:2])
            try:
                B.call("story_delete", story_id=ps["id"])
                raise AssertionError("deleted someone else's story")
            except RuntimeError as e:
                assert "err.story_not_yours" in str(e), e
            A.call("story_delete", story_id=ps["id"])
            assert not any(x["id"] == ps["id"] for x in A.call("stories") + A.call("story_archive"))
            B.wait_event(lambda e: e["event"] == "story_removed" and e["id"] == ps["id"], what="story removed at friend")
            assert not any(x["id"] == ps["id"] for x in B.call("stories"))
        _()

        @step("Khoảnh khắc audience: hidden friend left out, close-friends-only reaches only close friends")
        def _():
            def has(N, sid): return any(x["id"] == sid for x in N.call("stories"))
            def post(**kw): return A.call("post_story", bg="ocean", **kw)
            def arrives(N, sid, what): N.wait_event(lambda e: e["event"] == "story" and e["id"] == sid, what=what)
            try:
                # Carol is hidden: only Bob gets it
                A.call("settings_set", story_hidden=[pc, pa, "rác"])
                assert A.call("settings_get")["story_hidden"] == [pc], "own id / junk kept in the hidden list"
                h = post(text="Chỉ Bob thấy")
                assert h["recipients"] == 1, h
                arrives(B, h["id"], "story at Bob (not hidden)")
                # close friends = Carol, nobody hidden: only Carol gets the close-friends one
                A.call("settings_set", story_hidden=[], story_close=[pc])
                c = post(text="Bạn thân thôi", audience="close")
                assert c["recipients"] == 1, c
                arrives(C, c["id"], "close-friends story at Carol")
                # a story to all friends afterwards reaches both: the earlier ones were never
                # sent to the left-out friend (per-pair order), so they can't still be on the way
                f = post(text="Mọi người")
                assert f["recipients"] == 2, f
                arrives(B, f["id"], "story to all at Bob")
                arrives(C, f["id"], "story to all at Carol")
                assert not has(C, h["id"]), "hidden friend got the story"
                assert not has(B, c["id"]), "non-close friend got the close-friends story"
                assert has(B, h["id"]) and has(C, c["id"])
                # the hidden list wins over the close list
                A.call("settings_set", story_hidden=[pc])
                assert post(text="Không ai", audience="close")["recipients"] == 0
                try:
                    post(text="x", audience="public")
                    raise AssertionError("unknown audience accepted")
                except RuntimeError:
                    pass
                for x in [h, c, f]:
                    A.call("story_delete", story_id=x["id"])
            finally:
                A.call("settings_set", story_hidden=[], story_close=[])
            g = A.call("settings_get")
            assert g["story_hidden"] == [] and g["story_close"] == [], g
        _()

        @step("calls: caller hangs up while ringing → callee stops ringing; ask-to-control reaches friend")
        def _():
            c = A.call("call_start", conv=f"d:{pb}", video=False)
            B.wait_event(lambda e: e["event"] == "call" and e["call_id"] == c["call_id"] and e["state"] == "incoming", what="incoming call")
            A.call("call_end", call_id=c["call_id"])
            B.wait_event(lambda e: e["event"] == "call" and e["call_id"] == c["call_id"] and e["state"] == "ended", 10, what="callee ended")
            r = B.call("remote_connect", target=pa, password="", view_only=False)
            e = A.wait_event(lambda e: e["event"] == "remote_request" and e.get("ask"), 15, what="ask-to-control request")
            A.call("remote_respond", session=e["session"], accept=False)
            B.wait_event(lambda e: e["event"] == "remote_state" and e.get("session") == r["session"] and e["state"] == "denied", 10, what="denied")
        _()

        @step("remote control: lock / restart / log out results reach the controller (simulated host)")
        def _():
            # the host captures its screen once the session is accepted: only ever a nested
            # X server (DISPLAY=:77 LUMORA_CAPTURE=x11), never the real desktop
            if os.environ.get("LUMORA_CAPTURE") != "x11" or not os.environ.get("DISPLAY") or os.environ.get("DISPLAY") in (":0", ":1"):
                raise AssertionError("needs a nested X server: run with DISPLAY=:77 LUMORA_CAPTURE=x11")
            A.call("remote_allow_power", allow=False)
            r = B.call("remote_connect", target=pa, password="", view_only=False)
            sess = r["session"]
            e = A.wait_event(lambda e: e["event"] == "remote_request" and e.get("ask") and e.get("session") == sess, 15, what="ask-to-control request")
            A.call("remote_respond", session=sess, accept=True, control=True)
            B.wait_event(lambda e: e["event"] == "remote_state" and e.get("session") == sess and e["state"] == "active", 20, what="viewer active")

            def act(action):
                B.call("remote_power", session=sess, action=action)
                res = B.wait_event(lambda e: e["event"] == "remote_action_result" and e.get("session") == sess and e.get("action") == action, 15, what=f"{action} result at the controller")
                host = A.wait_event(lambda e: e["event"] == "remote_action" and e.get("session") == sess and e.get("action") == action, 15, what=f"{action} on the host")
                assert res["ok"] == host["ok"], (res, host)
                assert res["peer"] == pa, res
                return res
            try:
                assert act("lock")["ok"]
                res = act("restart")
                assert not res["ok"] and res["code"] == "err.power_not_allowed", res
                A.call("remote_allow_power", allow=True)
                assert act("restart")["ok"]
                res = act("logout")  # the test hook makes it fail
                assert not res["ok"] and res["code"] == "err.power_failed", res
            finally:
                A.call("remote_allow_power", allow=False)
                B.call("remote_end", session=sess)
        _()

        @step("add friend by 9-digit ID without internet directory (LAN)")
        def _():
            sid = C.me["short_id"]
            p = B.call("add_contact", target=sid)["peer"]
            assert p == pc, (p, pc)
        _()

        @step("custom stickers (static + animated GIF), dedup cache, save to own pack")
        def _():
            pk = A.call("sticker_pack_create", name="Mèo cute")
            png = os.path.join(dirs["alice"], "cat.png")
            gif = os.path.join(dirs["alice"], "cat.gif")
            subprocess.run(["convert", "-size", "300x300", "plasma:pink-yellow", png], check=True)
            subprocess.run(["convert", "-size", "120x120", "xc:red", "xc:blue", "-loop", "0", "-delay", "20", gif], check=True)
            s1 = A.call("sticker_add", pack=pk["id"], path=png, emoji="😺")
            s2 = A.call("sticker_add", pack=pk["id"], path=gif, emoji="🙀")
            assert s2["animated"] and not s1["animated"], (s1, s2)
            m = A.call("send_sticker", conv=f"d:{pb}", hash=s2["hash"])
            A.call("send_sticker", conv=f"d:{pb}", hash=s2["hash"])  # same sticker again → stored once
            def got():
                x = [x for x in B.call("messages", conv=conv_ab) if x["id"] == m["id"]]
                return x and x[0]["body"]["hash"] == s2["hash"]
            wait_until(got, 15, "sticker arrives")
            g = B.call("sticker_get", hash=s2["hash"])
            assert g["mime"] == "image/gif" and len(g["data"]) > 100
            mine = B.call("sticker_pack_create", name="Lưu")
            B.call("sticker_save", hash=s2["hash"], pack=mine["id"])
            assert any(st["hash"] == s2["hash"] for p in B.call("sticker_packs") for st in p["stickers"])
        _()

        @step("delete for me / for both, clear history for both")
        def _():
            m1 = A.call("send_text", conv=f"d:{pb}", text="xóa chỉ mình tôi")
            m2 = A.call("send_text", conv=f"d:{pb}", text="tin của Alice, Alice thu hồi cho cả hai")
            wait_until(lambda: any(x["id"] == m1["id"] for x in B.call("messages", conv=conv_ab)), 10, "m1")
            wait_until(lambda: any(x["id"] == m2["id"] for x in A.call("messages", conv=f"d:{pb}")), 10, "m2")
            A.call("delete_message", conv=f"d:{pb}", msg_id=m1["id"], for_everyone=False)
            assert not any(x["id"] == m1["id"] for x in A.call("messages", conv=f"d:{pb}"))
            time.sleep(0.5)
            assert any(x["id"] == m1["id"] and not x["deleted"] for x in B.call("messages", conv=conv_ab)), "delete-for-me leaked"
            A.call("delete_message", conv=f"d:{pb}", msg_id=m2["id"], for_everyone=True)
            wait_until(lambda: [x for x in B.call("messages", conv=conv_ab) if x["id"] == m2["id"]][0]["deleted"], 10, "own msg recalled for both")
            assert [x for x in B.call("messages", conv=conv_ab) if x["id"] == m2["id"]][0].get("deleted_by") == pa
            A.call("clear_history", conv=f"d:{pb}", for_everyone=True)
            wait_until(lambda: len(B.call("messages", conv=conv_ab)) == 0, 10, "history cleared on both")
            assert len(A.call("messages", conv=f"d:{pb}")) == 0
        _()

        @step("group admin: slow mode, announcement mode, purge member, seen-by")
        def _():
            g = A.call("groups")[0]
            gid, conv = g["gid"], g["conv"]
            m = B.call("send_text", conv=conv, text="tin để kiểm tra đã xem")
            wait_until(lambda: any(x["id"] == m["id"] for x in A.call("messages", conv=conv)), 10, "group msg")
            A.call("mark_read", conv=conv)
            wait_until(lambda: pa in B.call("seen_by", msg_id=m["id"]), 10, "seen by Alice")
            A.call("group_settings", gid=gid, slow_mode_s=60)
            wait_until(lambda: B.call("group_info", gid=gid)["slow_mode_s"] == 60, 10, "slow mode synced")
            # Bob posted moments ago → the next post inside the 60 s window must be refused
            try:
                B.call("send_text", conv=conv, text="tin quá nhanh")
                raise AssertionError("slow mode not enforced")
            except RuntimeError as e:
                assert "[err.slow_mode]" in str(e), e
            A.call("send_text", conv=conv, text="admin không bị giới hạn")  # admins are exempt
            A.call("group_settings", gid=gid, slow_mode_s=0)
            wait_until(lambda: B.call("group_info", gid=gid)["slow_mode_s"] == 0, 10, "slow mode off")
            A.call("group_settings", gid=gid, slow_mode_s=0, admins_only=True)
            wait_until(lambda: B.call("group_info", gid=gid)["admins_only"], 10, "announcement mode synced")
            try:
                B.call("send_text", conv=conv, text="member cannot post")
                raise AssertionError("announcement mode not enforced")
            except RuntimeError:
                pass
            A.call("group_settings", gid=gid, admins_only=False)
            wait_until(lambda: not B.call("group_info", gid=gid)["admins_only"], 10, "announcement off")
            A.call("group_purge_member", gid=gid, peer=pb)
            wait_until(lambda: all(x["deleted"] for x in B.call("messages", conv=conv) if x["author"] == pb and x["kind"] != "system"), 10, "purge on Bob")
        _()

        @step("invite link: a member an admin removed can't rejoin by link; the admin adds her back")
        def _():
            g = A.call("groups")[0]
            link = A.call("create_invite", gid=g["gid"], hours=1)["link"]
            info = C.call("inspect_invite", link=link)
            assert info["valid"] and not info["already_member"], info
            C.call("join_invite", link=link)
            ev = C.wait_event(lambda e: e["event"] == "group_join_denied" and e.get("gid") == g["gid"], 20, what="Carol: join denied")
            assert ev["reason"] == "removed" and ev["code"] == "err.removed_admin_only", ev
            assert C.call("group_info", gid=g["gid"])["my_role"] == "none", "removed member rejoined by link"
            # members don't add people by default (invite is the admins')…
            try:
                B.call("group_add", gid=g["gid"], peer=pc)
                raise AssertionError("a plain member added someone without `invite`")
            except RuntimeError as e:
                assert "admin_only_add" in str(e), e
            # …and even with `invite`, only admins bring back someone an admin removed
            inv = A.call("group_role_set", gid=g["gid"], name="Mời", color="#22C55E", perms=["invite"])["id"]
            A.call("group_member_roles", gid=g["gid"], peer=pb, roles=[inv])
            wait_until(lambda: "invite" in B.call("group_info", gid=g["gid"])["my_perms"], 20, "Bob may invite")
            try:
                B.call("group_add", gid=g["gid"], peer=pc)
                raise AssertionError("a member re-added someone an admin removed")
            except RuntimeError as e:
                assert "removed_admin_only" in str(e), e
            A.call("group_add", gid=g["gid"], peer=pc)
            wait_until(lambda: C.call("group_info", gid=g["gid"])["my_role"] == "member", 20, "Carol back in group")
            # banned members can NOT come back through the link
            A.call("group_ban", gid=g["gid"], peer=pc, ban=True)
            wait_until(lambda: C.call("group_info", gid=g["gid"])["my_role"] == "none", 20, "Carol banned")
            C.call("join_invite", link=link)
            time.sleep(3)
            assert C.call("group_info", gid=g["gid"])["my_role"] == "none", "banned member rejoined"
            A.call("group_ban", gid=g["gid"], peer=pc, ban=False)
            bad = link[:-3] + ("aaa" if not link.endswith("aaa") else "bbb")
            try:
                C.call("inspect_invite", link=bad)
                raise AssertionError("tampered link accepted")
            except RuntimeError:
                pass
        _()

        @step("scheduled message is sent at the requested time")
        def _():
            at = int(time.time() * 1000) + 3000
            sc = A.call("schedule_message", conv=f"d:{pb}", text="tin hẹn giờ ⏰", at=at)
            assert any(x["id"] == sc["id"] for x in A.call("scheduled_messages"))
            wait_until(lambda: any(x["body"].get("text") == "tin hẹn giờ ⏰" for x in B.call("messages", conv=conv_ab)), 20, "scheduled delivered")
        _()

        @step("checklist: ticks sync both ways (1-1 + group), sender adds items, others can't")
        def _():
            cl = A.call("send_checklist", conv=f"d:{pb}", title="Chuẩn bị đi Đà Lạt", items=["Đặt xe", "Mua đồ ăn", " ", "Sạc pin"])
            assert cl["kind"] == "checklist" and [i["text"] for i in cl["body"]["items"]] == ["Đặt xe", "Mua đồ ăn", "Sạc pin"], cl
            B.wait_event(lambda e: e["event"] == "message" and e["id"] == cl["id"], what="checklist arrives")
            B.call("checklist_toggle", conv=conv_ab, msg_id=cl["id"], item=2, done=True)
            def ticked(node, conv, item, by, done=True):
                x = [x for x in node.call("messages", conv=conv) if x["id"] == cl["id"]][0]
                c = (x["reactions"] or {}).get("__checks", {}).get(str(item))
                return c and c["done"] == done and c["by"] == by and c["at"] > 0
            wait_until(lambda: ticked(A, f"d:{pb}", 2, pb), 10, "Bob's tick reaches Alice")
            A.call("checklist_toggle", conv=f"d:{pb}", msg_id=cl["id"], item=2, done=False)
            wait_until(lambda: ticked(B, conv_ab, 2, pa, False), 10, "Alice's untick reaches Bob")
            A.call("checklist_add", conv=f"d:{pb}", msg_id=cl["id"], items=["Mang áo ấm"])
            wait_until(lambda: [i["text"] for i in [x for x in B.call("messages", conv=conv_ab) if x["id"] == cl["id"]][0]["body"]["items"]][-1] == "Mang áo ấm", 10, "added item reaches Bob")
            try:
                B.call("checklist_add", conv=conv_ab, msg_id=cl["id"], items=["hack"])
                raise AssertionError("non-sender added an item")
            except RuntimeError as e:
                assert "[err.checklist_owner_only]" in str(e), e
            # group: Bob ticks, Alice (and every member) sees who ticked it
            gconv = A.call("groups")[0]["conv"]
            gl = A.call("send_checklist", conv=gconv, title="Việc nhóm", items=["Viết báo cáo", "Làm slide"])
            wait_until(lambda: any(x["id"] == gl["id"] for x in B.call("messages", conv=gconv)), 15, "group checklist arrives")
            B.call("checklist_toggle", conv=gconv, msg_id=gl["id"], item=1, done=True)
            def gticked(node):
                x = [x for x in node.call("messages", conv=gconv) if x["id"] == gl["id"]][0]
                c = (x["reactions"] or {}).get("__checks", {}).get("1")
                return c and c["done"] and c["by"] == pb
            wait_until(lambda: gticked(A), 15, "group tick reaches Alice")
            assert gticked(B)
        _()

        @step("reminder: fires reminder_due on both sides; seen + cancel sync")
        def _():
            at = int(time.time() * 1000) + 3000
            r = A.call("send_reminder", conv=f"d:{pb}", title="Họp nhóm", at_ms=at, note="Phòng 3")
            assert r["kind"] == "reminder" and r["body"]["at_ms"] == at, r
            B.wait_event(lambda e: e["event"] == "message" and e["id"] == r["id"], what="reminder arrives")
            ea = A.wait_event(lambda e: e["event"] == "reminder_due" and e["msg_id"] == r["id"], 20, what="reminder_due on Alice")
            eb = B.wait_event(lambda e: e["event"] == "reminder_due" and e["msg_id"] == r["id"], 20, what="reminder_due on Bob")
            assert ea["title"] == eb["title"] == "Họp nhóm" and eb["note"] == "Phòng 3" and eb["conv"] == conv_ab, (ea, eb)
            assert time.time() * 1000 >= at - 50
            B.call("reminder_seen", conv=conv_ab, msg_id=r["id"])
            wait_until(lambda: pb in ([x for x in A.call("messages", conv=f"d:{pb}") if x["id"] == r["id"]][0]["reactions"] or {}).get("__seen", {}), 10, "seen reaches Alice")
            # a cancelled reminder never fires; only its sender can cancel
            r2 = A.call("send_reminder", conv=f"d:{pb}", title="Sẽ hủy", at_ms=int(time.time() * 1000) + 4000)
            B.wait_event(lambda e: e["event"] == "message" and e["id"] == r2["id"], what="reminder 2 arrives")
            try:
                B.call("reminder_cancel", conv=conv_ab, msg_id=r2["id"])
                raise AssertionError("non-sender cancelled")
            except RuntimeError as e:
                assert "[err.reminder_owner_only]" in str(e), e
            A.call("reminder_cancel", conv=f"d:{pb}", msg_id=r2["id"])
            wait_until(lambda: "__cancelled" in ([x for x in B.call("messages", conv=conv_ab) if x["id"] == r2["id"]][0]["reactions"] or {}), 10, "cancel reaches Bob")
            try:
                B.wait_event(lambda e: e["event"] == "reminder_due" and e["msg_id"] == r2["id"], 7, what="cancelled reminder")
                raise AssertionError("cancelled reminder fired")
            except TimeoutError:
                pass
            try:
                A.call("send_reminder", conv=f"d:{pb}", title="quá khứ", at_ms=int(time.time() * 1000) - 60000)
                raise AssertionError("past reminder accepted")
            except RuntimeError as e:
                assert "[err.reminder_past]" in str(e), e
        _()

        @step("silent message arrives flagged (1-1 + group); normal ones don't")
        def _():
            m = A.call("send_message", conv=f"d:{pb}", text="tin không âm báo", silent=True)
            assert m["silent"] is True, m
            e = B.wait_event(lambda e: e["event"] == "message" and e["id"] == m["id"], what="silent msg")
            assert e["silent"] is True and e["meta"]["silent"] is True, e
            n = A.call("send_text", conv=f"d:{pb}", text="tin bình thường")
            e = B.wait_event(lambda e: e["event"] == "message" and e["id"] == n["id"], what="normal msg")
            assert e["silent"] is False, e
            gconv = A.call("groups")[0]["conv"]
            g = A.call("send_text", conv=gconv, text="nhóm im lặng", silent=True)
            wait_until(lambda: [x for x in B.call("messages", conv=gconv) if x["id"] == g["id"]][0]["silent"] is True, 15, "group silent flag")
        _()

        @step("noise suppression + camera effects + wake-on-LAN settings round-trip; wake needs info first")
        def _():
            assert A.call("settings_get")["noise_suppression"] is True
            A.call("settings_set", noise_suppression=False)
            assert A.call("settings_get")["noise_suppression"] is False
            A.call("settings_set", noise_suppression=True)
            # camera effects: defaults, round-trip, clamping
            s = A.call("settings_get")
            assert (s["video_beauty"], s["video_lowlight"], s["video_mirror_send"]) == (0, True, False), s
            A.call("settings_set", video_beauty=2, video_lowlight=False, video_mirror_send=True)
            s = A.call("settings_get")
            assert (s["video_beauty"], s["video_lowlight"], s["video_mirror_send"]) == (2, False, True), s
            A.call("settings_set", video_beauty=9)
            assert A.call("settings_get")["video_beauty"] == 3
            A.call("settings_set", video_beauty=0, video_lowlight=True, video_mirror_send=False)
            try:
                A.call("remote_wake", peer=pb)
                raise AssertionError("wake without info")
            except RuntimeError as e:
                assert "[err.wake_no_info]" in str(e), e
        _()

        @step("burst: 1,000 messages, receiver offline mid-burst, lost ratchet session — all delivered once, in order")
        def _():
            conv_a = f"d:{pb}"

            def fire(tag, rng):
                A.call_many("send_text", [{"conv": conv_a, "text": f"{tag} {i}"} for i in rng])

            def tagged(n, conv, tag):
                return [m["id"] for m in n.all_messages(conv) if (m.get("body") or {}).get("text", "").startswith(tag + " ")]

            def delivered(tag, total, timeout):
                t0 = time.time()
                wait_until(lambda: len(set(tagged(B, conv_ab, tag))) >= total, timeout, f"{tag}: {total} delivered")
                dt = time.time() - t0
                theirs, mine = tagged(B, conv_ab, tag), tagged(A, conv_a, tag)
                assert len(theirs) == len(set(theirs)) == total, f"{tag}: {len(theirs)} rows, {len(set(theirs))} distinct"
                assert theirs == mine, f"{tag}: order differs from the sender's"
                return dt

            t0 = time.time()
            fire("burst", range(1000))
            delivered("burst", 1000, 180)
            dt = time.time() - t0
            print(f"     1,000-message burst delivered in {dt:.1f}s")
            # receiver goes offline in the middle of a burst, comes back later
            fire("offline-burst", range(500))
            B.stop()
            fire("offline-burst", range(500, 1000))
            time.sleep(2)
            t0 = time.time()
            B.start()
            delivered("offline-burst", 1000, 180)
            print(f"     offline catch-up of 1,000 messages in {time.time() - t0:.1f}s")
            # the receiver lost its ratchet sessions: the sender is handed a fresh key and
            # re-encrypts what wasn't acknowledged — nothing is lost
            B.call("debug_olm_drop", peer=pa)
            fire("resync", range(200))
            print(f"     resync of 200 after a lost ratchet session in {delivered('resync', 200, 120):.1f}s")
            assert A.call("security_status", peer=pb)["forward_secrecy"], "session not re-established"
        _()

        @step("offline delivery: message queued while Bob is down, delivered on restart")
        def _():
            B.stop()
            time.sleep(1)
            m = A.call("send_text", conv=f"d:{pb}", text="Bạn offline mà vẫn nhận được nhé")
            time.sleep(1)
            B.start()
            wait_until(lambda: any(x["id"] == m["id"] for x in B.call("messages", conv=conv_ab)), 60, "queued msg delivered")
        _()

        @step("'no history' mode wipes the chat on restart")
        def _():
            B.call("set_retention", conv=conv_ab, mode="session")
            assert B.call("get_retention", conv=conv_ab)["mode"] == "session"
            assert len(B.call("messages", conv=conv_ab)) > 0
            B.stop(); B.start()
            assert B.call("messages", conv=conv_ab) == [], "history survived restart"
            B.call("set_retention", conv=conv_ab, mode="forever")
        _()

        @step("move account to a new device with an encrypted backup")
        def _():
            bk = os.path.join(tmp, "alice.lumora-backup")
            r = A.call("export_backup", path=bk, password="mat-khau-sao-luu")
            assert r["bytes"] > 0
            raw = open(bk, "rb").read()
            assert "Xin chào".encode() not in raw and b"Alice" not in raw
            nd = os.path.join(tmp, "alice-new")
            os.makedirs(nd)
            N = Node("AliceNew", a.bin, nd, extra + ["--restore-backup", bk, "mat-khau-sao-luu", "--port", "0"])
            try:
                assert N.me["peer"] == pa, "identity not restored"
                assert len(N.call("contacts")) >= 2 and len(N.call("groups")) >= 1
            finally:
                N.stop()
        _()

        @step("sign out of the main device: refused without confirmation, then a fresh start on restart")
        def _():
            nd = os.path.join(tmp, "signout-main")
            os.makedirs(nd)
            D = Node("SignOut", a.bin, nd, extra + ["--port", "0", "--passphrase", "mk-cua-dave"])
            try:
                old = D.me["peer"]
                try:
                    D.call("device_logout", passphrase="mk-cua-dave")
                    raise AssertionError("main device signed out without confirmation")
                except RuntimeError as e:
                    assert "err.primary_logout" in str(e), e
                for bad in (None, "sai-mat-khau"):
                    try:
                        D.call("device_logout", primary_ok=True, **({"passphrase": bad} if bad else {}))
                        raise AssertionError("signed out without the account password")
                    except RuntimeError as e:
                        assert "err.wrong_passphrase" in str(e), e
                D.call("device_logout", primary_ok=True, passphrase="mk-cua-dave")
                D.wait_event(lambda e: e["event"] == "device_revoked" and e.get("by_self"), 10, what="signed out")
                D.stop(); D.start()
                assert D.me["peer"] != old, "account still on this device after signing out"
            finally:
                D.stop()
        _()

        @step("delete account on the main device: downloads wiped, a fresh identity on restart")
        def _():
            nd = os.path.join(tmp, "delete-account")
            os.makedirs(nd)
            dl = os.path.join(nd, "downloads")
            D = Node("DeleteMe", a.bin, nd, extra + ["--port", "0", "--passphrase", "mk-xoa", "--downloads", dl])
            try:
                old = D.me["peer"]
                D.call("add_contact", target=pa)
                A.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == old, what="delete-me req")
                A.call("accept_contact", peer=old)
                wait_until(lambda: any(c["peer"] == pa and c["status"] == 3 for c in D.call("contacts")), 20, "friends")
                src = os.path.join(dirs["alice"], "se-bi-xoa.bin")
                open(src, "wb").write(os.urandom(200_000))
                f = A.call("send_file", conv=f"d:{old}", path=src)

                def got():
                    xs = [x for x in D.call("files") if x["id"] == f["id"] and x["state"] == 2]
                    return xs and xs[0]
                r = wait_until(got, 30, "file downloaded on the device to delete")
                assert os.path.exists(r["path"]) and os.path.abspath(r["path"]).startswith(os.path.abspath(dl)), r["path"]
                try:
                    D.call("device_logout", primary_ok=True, passphrase="sai", wipe=True)
                    raise AssertionError("deleted without the account password")
                except RuntimeError as e:
                    assert "err.wrong_passphrase" in str(e), e
                assert os.path.exists(r["path"]), "a wrong password deleted files"
                D.call("device_logout", primary_ok=True, passphrase="mk-xoa", wipe=True)
                D.wait_event(lambda e: e["event"] == "device_revoked" and e.get("by_self") and e.get("wipe"), 10, what="deleted")
                assert not os.path.exists(r["path"]), "downloaded file kept after deleting the account"
                D.stop(); D.start()
                assert not os.path.exists(dl), "downloads folder survived deleting the account"
                assert D.me["peer"] != old, "account still on this device after deleting it"
                assert D.call("contacts") == [] and D.call("files") == [], "old data visible after deleting the account"
                assert not [p for p in os.listdir(tmp) if p.startswith("delete-account.signed-out-")], "data kept aside instead of deleted"
            finally:
                D.stop()
            A.call("remove_contact", peer=old)  # later steps count Alice's contacts
        _()

        @step("a deleted chat comes back to the list when either side writes again")
        def _():
            A.call("send_text", conv=f"d:{pb}", text="trước khi xoá")
            A.call("delete_conversation", conv=f"d:{pb}")
            assert not any(c["id"] == f"d:{pb}" for c in A.call("conversations")), "chat not deleted"
            m = B.call("send_text", conv=f"d:{pa}", text="nhắn lại sau khi bạn xoá")
            wait_until(lambda: any(c["id"] == f"d:{pb}" for c in A.call("conversations")), 30, "chat back after their message")
            assert [x["id"] for x in A.call("messages", conv=f"d:{pb}")] == [m["id"]]
            A.call("delete_conversation", conv=f"d:{pb}")
            mine = A.call("send_text", conv=f"d:{pb}", text="mình nhắn trước")
            assert any(c["id"] == f"d:{pb}" for c in A.call("conversations")), "chat missing after my own message"
            wait_until(lambda: any(x["id"] == mine["id"] for x in B.call("messages", conv=f"d:{pa}")), 30, "reaches Bob")
        _()

        @step("restore an account from its 24-word recovery phrase (and a legacy one)")
        def _():
            phrase = A.call("recovery_phrase")["phrase"]
            words = phrase.split(" ")
            assert len(words) == 24 and all(w.isalpha() and w.islower() for w in words), phrase[:20]
            # messy typing still works: upper case, new lines, 4-letter prefixes
            typed = "\n".join(w.upper() if i % 2 else w[:4] for i, w in enumerate(words))
            nd = os.path.join(tmp, "alice-words")
            os.makedirs(nd)
            N = Node("AliceWords", a.bin, nd, extra + ["--restore-phrase", typed, "--port", "0"])
            try:
                assert N.me["peer"] == pa, "identity not restored from words"
            finally:
                N.stop()
            # a phrase written down by an older version (base32 groups) restores the same
            # account as its 24 words (golden vector from the pre-word-list code)
            legacy = "ijbee-qscij-beeqs-cijbe-eqsci-jbeeq-scijb-eeqsc-ijbee-qscij-blz7y-r"
            same = ("drastic bamboo mountain loyal category cancel animal embark " * 3).strip()
            peers = []
            for i, p in enumerate([legacy, same]):
                nd = os.path.join(tmp, f"legacy-{i}")
                os.makedirs(nd)
                L = Node(f"Legacy{i}", a.bin, nd, extra + ["--restore-phrase", p, "--port", "0"])
                try:
                    peers.append(L.me["peer"])
                    assert L.call("recovery_phrase")["phrase"] == same, "legacy account shows its 24 words"
                finally:
                    L.stop()
            assert peers[0] == peers[1] == "efjprum3peosirjsilqv6lvlns3476t3njpngaexsyhangeb3mja", peers
        _()

        @step("bots in groups: privacy-mode bot follows membership, read-all switch, remove + re-add, leave; no public joins")
        def _():
            bd = os.path.join(tmp, "bot")
            os.makedirs(bd, exist_ok=True)
            Bt = Node("HelperBot", a.bin, bd, extra + ["--downloads", os.path.join(bd, "dl")])
            try:
                Bt.call("set_bot", commands=[{"command": "ping", "description": "ping"}],
                        group_commands=[{"command": "gping", "description": "ping"}], about="test bot", auto_accept=True)
                bot = Bt.me["peer"]
                g = A.call("create_group", name="Nhóm có bot", members=[pb])
                gid, gconv = g["gid"], g["conv"]
                wait_until(lambda: any(x["gid"] == gid for x in B.call("groups")), 30, "Bob got the group")
                A.call("group_add_bot", gid=gid, target=bot, read_all=False)
                wait_until(lambda: any(x["gid"] == gid for x in Bt.call("groups")), 40, "bot joined")

                def bot_members():
                    return {m["peer"] for m in Bt.call("group_info", gid=gid)["members"]}

                def texts(n):
                    return [(m["author"], (m.get("body") or {}).get("text", "")) for m in n.call("messages", conv=gconv, limit=200)]
                # 1) a member added AFTER the bot: the bot learns it (no key needed) and serves it
                A.call("group_add", gid=gid, peer=pc)
                wait_until(lambda: any(x["gid"] == gid for x in C.call("groups")), 40, "Carol got the group")
                wait_until(lambda: pc in bot_members(), 40, "privacy bot sees the new member")
                C.call("send_text", conv=gconv, text="/gping")
                wait_until(lambda: (pc, "/gping") in texts(Bt), 40, "bot got the late member's command")
                Bt.call("send_text", conv=gconv, text="gpong for Carol")
                wait_until(lambda: (bot, "gpong for Carol") in texts(C), 40, "late member got the bot's reply")
                B.call("send_text", conv=gconv, text="plain chat, not for the bot")
                time.sleep(2)
                assert (pb, "plain chat, not for the bot") not in texts(Bt), "privacy bot read plain chat"
                # names of members who aren't the bot's contacts
                names = {m["peer"]: m["name"] for m in Bt.call("group_info", gid=gid)["members"]}
                assert names.get(pc) == "Carol", names
                # 2) switched to read-all: it now gets the key and reads everything
                A.call("group_bot_policy", gid=gid, peer=bot, read_all=True)
                wait_until(lambda: [x for x in Bt.call("groups") if x["gid"] == gid][0]["bots"][0]["read_all"], 40, "policy reached the bot")
                B.call("send_text", conv=gconv, text="read-all now")
                wait_until(lambda: (pb, "read-all now") in texts(Bt), 40, "read-all bot reads plain chat")
                # 3) back to privacy mode, removed (it learns it), re-added with read-all
                A.call("group_bot_policy", gid=gid, peer=bot, read_all=False)
                time.sleep(1)
                A.call("group_remove", gid=gid, peer=bot)
                Bt.wait_event(lambda e: e["event"] == "group_removed" and e["gid"] == gid, 40, "bot told it was removed")
                assert Bt.call("group_info", gid=gid)["my_role"] == "none"
                A.call("group_add_bot", gid=gid, target=bot, read_all=True)
                wait_until(lambda: Bt.call("group_info", gid=gid)["my_role"] != "none", 40, "bot re-added")
                C.call("send_text", conv=gconv, text="after re-add")
                wait_until(lambda: (pc, "after re-add") in texts(Bt), 40, "re-added bot reads")
                # 4) a privacy-mode bot can leave (it has no key to publish with)
                A.call("group_bot_policy", gid=gid, peer=bot, read_all=False)
                wait_until(lambda: not [x for x in Bt.call("groups") if x["gid"] == gid][0]["bots"][0]["read_all"], 40, "privacy again")
                Bt.call("group_leave", gid=gid)
                wait_until(lambda: bot not in {m["peer"] for m in A.call("group_info", gid=gid)["members"]}, 40, "members see the bot left")
                # 5) bots never join by themselves
                try:
                    Bt.call("join_public", gid=gid, via=pa)
                    raise AssertionError("bot joined a public group by itself")
                except RuntimeError as e:
                    assert "[err.bot_join_public]" in str(e), e
            finally:
                Bt.stop()
        _()

        @step("group: concurrent admin removals/rotations + an offline member catching up — everyone converges")
        def _():
            import threading as _th
            extra_nodes = []
            try:
                for nm in ["Dave", "Eve"]:
                    d = os.path.join(tmp, nm.lower())
                    os.makedirs(d, exist_ok=True)
                    N = Node(nm, a.bin, d, extra + ["--downloads", os.path.join(d, "dl")])
                    extra_nodes.append(N)
                    N.call("add_contact", target=pa)
                    pn = N.me["peer"]
                    A.wait_event(lambda e, pn=pn: e["event"] == "friend_request" and e["peer"] == pn, what=f"{nm} request")
                    A.call("accept_contact", peer=pn)
                    wait_until(lambda N=N: any(c["peer"] == pa and c["status"] == 3 for c in N.call("contacts")), 15, f"{nm} friend")
                D, E = extra_nodes
                pd, pe = D.me["peer"], E.me["peer"]
                g = A.call("create_group", name="Đồng bộ khóa 🔐", members=[pb, pc, pd, pe])
                gid, conv = g["gid"], g["conv"]
                for N in (B, C, D, E):
                    wait_until(lambda N=N: any(x["gid"] == gid for x in N.call("groups")), 20, f"{N.name} joined")
                A.call("group_set_role", gid=gid, peer=pb, role="admin")
                wait_until(lambda: B.call("group_info", gid=gid)["my_role"] == "admin", 20, "Bob is admin")
                # Carol goes offline; the owner and the admin remove two members at the same
                # moment — two rotations race — and both keep talking
                C.stop()
                errs = []
                def run(fn):
                    try:
                        fn()
                    except Exception as e:  # noqa
                        errs.append(e)
                ts = [_th.Thread(target=run, args=(lambda: A.call("group_remove", gid=gid, peer=pe),)),
                      _th.Thread(target=run, args=(lambda: B.call("group_remove", gid=gid, peer=pd),))]
                for t in ts:
                    t.start()
                for t in ts:
                    t.join()
                assert not errs, errs
                def converged(nodes_):
                    infos = [n.call("group_info", gid=gid) for n in nodes_]
                    mem = [sorted(m["peer"] for m in i["members"]) for i in infos]
                    return all(m == mem[0] for m in mem) and all(i["epoch"] == infos[0]["epoch"] for i in infos) \
                        and pd not in mem[0] and pe not in mem[0] and infos[0]
                info = wait_until(lambda: converged([A, B]), 40, "owner and admin converge")
                print(f"     epoch after the race: {info['epoch']}")
                # the epoch is settled when no rotation is pending: both read each other
                def exchange(nodes_, tag):
                    sent = []
                    for n in nodes_:
                        sent.append((n, wait_until(lambda n=n: n.call("send_text", conv=conv, text=f"{tag} {n.name}"), 30, f"{n.name} can send")))
                    for n in nodes_:
                        for (src, m) in sent:
                            wait_until(lambda n=n, m=m: any(x["id"] == m["id"] for x in n.call("messages", conv=conv)), 40, f"{n.name} reads {src.name}")
                    return sent
                after = exchange([A, B], "sau cuộc đua")
                # Carol comes back and catches up: same members, same epoch, reads and is read
                C.start()
                wait_until(lambda: converged([A, B, C]), 60, "Carol converges after being offline")
                for (src, m) in after:
                    wait_until(lambda m=m: any(x["id"] == m["id"] for x in C.call("messages", conv=conv)), 60, f"Carol reads {src.name}'s message from while she was away")
                final = exchange([A, B, C], "cả nhóm")
                time.sleep(2)
                for (_, m) in after + final:
                    for X in (D, E):
                        assert not any(x["id"] == m["id"] for x in X.call("messages", conv=conv)), f"removed {X.name} read a new message"
                # (what is queued for the removed members is delivered before they go)
                try:
                    wait_until(lambda: sum(n.call("storage_stats")["outbox"] for n in nodes) == 0, 60, "outboxes drained")
                except Exception:
                    names = {n.me["peer"]: n.name for n in nodes + extra_nodes}
                    for n in nodes:
                        w = n.call("storage_stats").get("outbox_waiting", [])
                        print(f"     {n.name} outbox: " + ", ".join(f"{names.get(x['peer'], x['peer'][:8])}×{x['items']} (attempts {x['attempts']})" for x in w))
                    raise
            finally:
                for N in extra_nodes:
                    N.stop()
        _()

        @step("community: listed while I'm in it; leaving or being removed takes it off the list")
        def _():
            g = A.call("create_group", name="Cộng đồng e2e", members=[pb, pc], kind=1)
            gid = g["gid"]
            B.wait_event(lambda e: e["event"] == "group" and e.get("gid") == gid, 20, what="community at Bob")
            assert any(x["id"] == gid for x in A.call("spaces")) and any(x["id"] == gid for x in B.call("spaces"))
            B.call("group_leave", gid=gid)
            assert not any(x["id"] == gid for x in B.call("spaces")), "left community still listed"
            wait_until(lambda: not any(x["id"] == gid for x in C.call("spaces")) or any(x["id"] == gid for x in C.call("spaces")), 5, "carol")
            A.call("group_remove", gid=gid, peer=pc)
            wait_until(lambda: not any(x["id"] == gid for x in C.call("spaces")), 20, "removed member's list")
            assert any(x["id"] == gid for x in A.call("spaces")), "owner still has it"
            # cover (banner) + delete for everyone, on a second community with Bob and Carol
            import base64
            g2 = A.call("create_group", name="Cộng đồng có bìa", members=[pb, pc], kind=1)
            gid2, conv2 = g2["gid"], g2["conv"]
            for N in (B, C):
                wait_until(lambda N=N: any(x["id"] == gid2 for x in N.call("spaces")), 30, f"second community at {N.name}")
            cover = base64.b64encode(b"\xff\xd8\xff\xe0" + os.urandom(200_000)).decode()
            try:
                A.call("group_meta", gid=gid2, cover=base64.b64encode(os.urandom(300 * 1024 + 1)).decode())
                raise AssertionError("a cover over 300 KB was accepted")
            except RuntimeError as e:
                assert "image_too_large" in str(e), e
            A.call("group_meta", gid=gid2, cover=cover)
            assert A.call("group_cover", gid=gid2)["cover"] == cover
            for N in (B, C):
                wait_until(lambda N=N: N.call("group_cover", gid=gid2)["cover"] == cover, 40, f"{N.name} sees the cover")
            sp = next(x for x in B.call("spaces") if x["id"] == gid2)
            assert sp["has_cover"] and sp["cover_rev"] and sp["my_role"] == "member", sp
            gi = B.call("group_info", gid=gid2)
            assert gi["has_cover"] and gi["cover_rev"] == sp["cover_rev"]
            try:
                B.call("group_meta", gid=gid2, cover="")
                raise AssertionError("a plain member changed the community cover")
            except RuntimeError as e:
                assert "admin_only" in str(e), e
            try:
                B.call("group_dissolve", gid=gid2)
                raise AssertionError("a member dissolved the community")
            except RuntimeError as e:
                assert "owner_only" in str(e), e
            m = B.call("send_text", conv=conv2, text="trước khi xoá")
            wait_until(lambda: any(x["id"] == m["id"] for x in C.call("messages", conv=conv2)), 30, "Carol reads Bob")
            # Carol is offline while the owner deletes it
            C.stop()
            A.call("group_dissolve", gid=gid2)
            def gone(N):
                return not any(x["id"] == gid2 for x in N.call("spaces")) \
                    and not any(x["gid"] == gid2 for x in N.call("groups")) \
                    and not any(c["id"].startswith(conv2) for c in N.call("conversations"))
            assert gone(A), "owner still lists the deleted community"
            ev = B.wait_event(lambda e: e["event"] == "group_removed" and e.get("gid") == gid2, 30, what="Bob: group_removed")
            assert ev.get("dissolved") is True and ev.get("left") is False and ev.get("name") == "Cộng đồng có bìa", ev
            wait_until(lambda: gone(B), 20, "Bob's lists without the deleted community")
            assert B.call("group_cover", gid=gid2)["cover"] is None
            try:
                B.call("send_text", conv=conv2, text="sau khi xoá")
                raise AssertionError("posted to a deleted community")
            except RuntimeError:
                pass
            # Carol comes back: the normal catch-up brings the Dissolve
            C.start()
            wait_until(lambda: gone(C), 60, "Carol (offline during the delete) drops it after restarting")
            C.wait_event(lambda e: e["event"] == "group_removed" and e.get("gid") == gid2 and e.get("dissolved") is True, 10, what="Carol: group_removed")
            # and it stays gone after another restart (nothing brings it back)
            C.stop(); C.start()
            time.sleep(2)
            assert gone(C) and gone(B), "deleted community came back"
        _()

        @step("community 2.0: roles, timeout, private + renamed channels, ownership, revoked links, join approval")
        def _():
            g = A.call("create_group", name="Cộng đồng 2.0", members=[pb], kind=1)
            gid, conv = g["gid"], g["conv"]
            wait_until(lambda: any(x["gid"] == gid for x in B.call("groups")), 30, "Bob in community 2.0")
            info = A.call("group_info", gid=gid)
            assert [r["id"] for r in info["roles"]][0] == "admin" and info["roles"][-1]["id"] == "everyone", info["roles"]
            assert "manage_community" in info["my_perms"]
            bi = B.call("group_info", gid=gid)
            # (invite links are the admins' by default)
            assert sorted(bi["my_perms"]) == sorted(["view_channel", "send_messages", "send_media", "connect_voice"]), bi["my_perms"]
            # a role with pin, given to Bob
            rid = A.call("group_role_set", gid=gid, name="Ghim", color="#22C55E", perms=["pin"])["id"]
            A.call("group_member_roles", gid=gid, peer=pb, roles=[rid])
            wait_until(lambda: "pin" in B.call("group_info", gid=gid)["my_perms"], 20, "Bob gets the role")
            try:
                B.call("group_role_set", gid=gid, name="Tự phong", color="#000000", perms=["ban"])
                raise AssertionError("a member made a role")
            except RuntimeError as e:
                assert "no_permission" in str(e), e
            # private channel: Bob doesn't see it; renamed channel keeps its conversation
            A.call("group_channel", gid=gid, name="ban-dieu-hanh", category="THÔNG TIN", topic="riêng")
            A.call("group_channel_update", gid=gid, name="ban-dieu-hanh", private=True, allow_roles=[])
            gen = next(c for c in A.call("group_info", gid=gid)["channels"] if c["id"] == "general")
            A.call("group_channel_update", gid=gid, name=gen["name"], new_name="Sảnh chính", topic="nói chuyện")
            def bob_channels():
                return {c["id"]: c for c in B.call("group_info", gid=gid)["channels"]}
            wait_until(lambda: bob_channels().get("general", {}).get("name") == "sảnh-chính" and "ban-dieu-hanh" not in bob_channels(), 20, "Bob's channel list")
            assert bob_channels()["general"]["conv"] == gen["conv"], "a rename changed the conversation"
            sp = next(x for x in B.call("spaces") if x["id"] == gid)
            assert not any(c["id"] == "ban-dieu-hanh" for c in sp["channels"]) and any(c.get("topic") == "nói chuyện" for c in sp["channels"]), sp
            m = B.call("send_text", conv=gen["conv"], text="vẫn kênh cũ")
            wait_until(lambda: any(x["id"] == m["id"] for x in A.call("messages", conv=gen["conv"])), 20, "post in renamed channel")
            # timeout: Bob can't post until it is lifted
            A.call("group_timeout", gid=gid, peer=pb, until_ms=int(time.time() * 1000) + 600_000)
            wait_until(lambda: next(x for x in B.call("group_info", gid=gid)["members"] if x["peer"] == pb)["timeout_until"] > 0, 20, "timeout reaches Bob")
            try:
                B.call("send_text", conv=gen["conv"], text="đang bị cấm")
                raise AssertionError("timed-out member posted")
            except RuntimeError as e:
                assert "timed_out" in str(e), e
            A.call("group_timeout", gid=gid, peer=pb, until_ms=0)
            wait_until(lambda: next(x for x in B.call("group_info", gid=gid)["members"] if x["peer"] == pb)["timeout_until"] == 0, 20, "timeout lifted")
            # info changes need manage_community; @all needs mention_everyone
            try:
                B.call("group_rename", gid=gid, name="đổi tên")
                raise AssertionError("member renamed the community")
            except RuntimeError as e:
                assert "admin_only" in str(e), e
            try:
                B.call("send_message", conv=gen["conv"], text="@all chú ý", mention_all=True)
                raise AssertionError("member used @all")
            except RuntimeError as e:
                assert "no_permission" in str(e), e
            # revoked link → refused; approval mode → request, deny, approve
            l1 = A.call("create_invite", gid=gid, hours=1)
            assert l1["id"] and any(x["id"] == l1["id"] for x in A.call("group_invite_links", gid=gid))
            A.call("group_revoke_invite", gid=gid, id=l1["id"])
            assert not any(x["id"] == l1["id"] for x in A.call("group_invite_links", gid=gid))
            C.call("join_invite", link=l1["link"])
            ev = C.wait_event(lambda e: e["event"] == "group_join_denied" and e.get("gid") == gid, 20, what="revoked link")
            assert ev["reason"] == "revoked", ev
            A.call("group_settings", gid=gid, approve_joins=True)
            l2 = A.call("create_invite", gid=gid, hours=1)
            C.call("join_invite", link=l2["link"])
            wait_until(lambda: any(r["peer"] == pc for r in A.call("group_info", gid=gid)["join_requests"]), 20, "join request")
            A.call("group_join_deny", gid=gid, peer=pc)
            C.wait_event(lambda e: e["event"] == "group_join_denied" and e.get("gid") == gid and e["reason"] == "denied", 20, what="denied")
            C.call("join_invite", link=l2["link"])
            wait_until(lambda: any(r["peer"] == pc for r in A.call("group_info", gid=gid)["join_requests"]), 20, "join request again")
            A.call("group_add", gid=gid, peer=pc)
            wait_until(lambda: C.call("group_info", gid=gid)["my_role"] == "member", 30, "approved join")
            assert not A.call("group_info", gid=gid)["join_requests"]
            # ownership: the owner can't just leave; hands over first
            try:
                A.call("group_leave", gid=gid)
                raise AssertionError("owner left without a successor")
            except RuntimeError as e:
                assert "owner_must_transfer" in str(e), e
            A.call("group_transfer_owner", gid=gid, peer=pb)
            wait_until(lambda: B.call("group_info", gid=gid)["my_role"] == "owner", 20, "Bob owns it")
            assert A.call("group_info", gid=gid)["my_role"] == "admin"
            wait_until(lambda: any((x.get("body") or {}).get("code") == "sys.owner_changed" for x in C.call("messages", conv=conv)), 20, "owner-changed notice")
            A.call("group_leave", gid=gid)
        _()

        @step("privacy: invitations wait for an answer, calls that may not ring don't, plain group calls ring only the picked")
        def _():
            # Carol: nobody adds me directly
            C.call("settings_set", who_can_add="nobody", who_can_call="nobody")
            st = C.call("settings_get")
            assert st["who_can_add"] == "nobody" and st["who_can_call"] == "nobody" and st["who_sees_online"] == "friends", st
            g = A.call("create_group", name="Lời mời chờ", members=[pc])
            ev = C.wait_event(lambda e: e["event"] == "group_invite" and e.get("gid") == g["gid"], 20, what="invitation")
            assert ev["name"] == "Lời mời chờ" and ev["by"] == pa, ev
            assert not any(x["gid"] == g["gid"] for x in C.call("groups")), "joined without being asked"
            assert any(i["gid"] == g["gid"] for i in C.call("group_invites"))
            r = C.call("group_invite_answer", gid=g["gid"], accept=True)
            assert r["conv"] == g["conv"], r
            wait_until(lambda: C.call("group_info", gid=g["gid"])["my_role"] == "member", 20, "accepted")
            assert not C.call("group_invites")
            g2 = A.call("create_group", name="Không tham gia", members=[pc])
            C.wait_event(lambda e: e["event"] == "group_invite" and e.get("gid") == g2["gid"], 20, what="2nd invitation")
            C.call("group_invite_answer", gid=g2["gid"], accept=False)
            wait_until(lambda: not any(m["peer"] == pc for m in A.call("group_info", gid=g2["gid"])["members"]), 30, "declined → out")
            # who can call me: nobody → Alice's call never rings (and leaves no call line)
            def call_lines(N, conv):
                try:
                    return [m for m in N.call("messages", conv=conv) if m["kind"] == "call"]
                except Exception:
                    return []  # (no such chat)
            k_ac = len(call_lines(C, f"d:{pa}"))
            cid = A.call("call_start", conv=f"d:{pc}")["call_id"]
            time.sleep(4)
            try:
                C.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "incoming", 1, what="no ring")
                raise AssertionError("a call rang although nobody may call")
            except TimeoutError:
                pass
            A.call("call_end", call_id=cid)
            wait_until(lambda: len(call_lines(A, f"d:{pc}")) >= 1, 20, "Alice logs her own call")
            C.call("settings_set", who_can_add="friends", who_can_call="friends")
            # a friend's unanswered call is still logged at Carol ("friends" may call)
            cid = A.call("call_start", conv=f"d:{pc}")["call_id"]
            C.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "incoming", 20, what="friend rings")
            A.call("call_end", call_id=cid)
            wait_until(lambda: len(call_lines(C, f"d:{pa}")) == k_ac + 1, 30, "friend's missed call logged once (the blocked one left none)")
            # plain group call ringing nobody: Bob and Carol get a "Join" banner, Bob joins
            gg = A.call("create_group", name="Gọi nhóm", members=[pb, pc])
            for N in (B, C):
                wait_until(lambda N=N: any(x["gid"] == gg["gid"] for x in N.call("groups")), 30, f"{N.name} in call group")
            # a stranger (Bob: a fellow member, not a friend) calling Carol: no ring, and after
            # the call ends no trace at Carol — no chat with him, no "missed call" line
            assert not any(c["id"] == f"d:{pb}" for c in C.call("conversations")), "Carol had a chat with Bob already"
            cid = B.call("call_start", conv=f"d:{pc}")["call_id"]
            time.sleep(4)
            try:
                C.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "incoming", 1, what="no ring")
                raise AssertionError("a stranger's call rang although only friends may call")
            except TimeoutError:
                pass
            B.call("call_end", call_id=cid)
            wait_until(lambda: len(call_lines(B, f"d:{pc}")) >= 1, 20, "Bob logs his own call")
            time.sleep(6)
            assert not any(c["id"] == f"d:{pb}" for c in C.call("conversations")), "the blocked stranger's call made a chat"
            assert not call_lines(C, f"d:{pb}"), "the blocked stranger's call left a missed-call line"
            cid = A.call("call_start", conv=gg["conv"], ring=[])["call_id"]
            for N in (B, C):
                N.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "available", 20, what=f"{N.name}: available")
            B.call("call_answer", call_id=cid, accept=True)
            A.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and len(e.get("participants") or []) >= 1, 20, what="Bob joined the call")
            A.call("call_end", call_id=cid)
            C.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "ended", 20, what="Carol: banner gone")
            # ring list [Bob]: Carol gets only the banner (the plain invite behind it, for
            # older builds, never rings her); Bob declines → the call ends at once, the
            # banner member does not keep it "ringing" until the 45 s timeout
            cid = A.call("call_start", conv=gg["conv"], ring=[pb])["call_id"]
            C.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "available", 20, what="Carol: banner (ring list)")
            B.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "incoming", 20, what="Bob rung")
            t0 = time.time()
            B.call("call_answer", call_id=cid, accept=False)
            A.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "ended", 15, what="call ends once every rung member declined")
            assert time.time() - t0 < 15, "kept ringing for the banner member"
            C.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "ended", 20, what="Carol: banner gone (declined)")
            try:
                C.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "incoming", 1, what="no ring")
                raise AssertionError("the banner member was rung")
            except TimeoutError:
                pass
        _()

        @step("voice channel = drop-in room: nobody rung, presence reaches every member, media between participants, crash expires")
        def _():
            g = A.call("create_group", name="Phòng thoại e2e", members=[pb, pc], kind=1)
            gid = g["gid"]
            for N in (B, C):
                wait_until(lambda N=N: any(x["id"] == gid for x in N.call("spaces")), 30, f"community at {N.name}")
            sp = next(x for x in A.call("spaces") if x["id"] == gid)
            vconv = next(c["conv"] for c in sp["channels"] if c["voice"])
            dev = {N.name: N.call("me")["device"] for N in (A, B)}

            def parts(N):
                sp = next(x for x in N.call("spaces") if x["id"] == gid)
                return next(c["participants"] for c in sp["channels"] if c["conv"] == vconv)

            def voice_ev(N, pred, what, t=20):
                return N.wait_event(lambda e: e["event"] == "voice" and e.get("conv") == vconv and pred(e), t, what)

            def call_ev(N, pred, what, t=20):
                return N.wait_event(lambda e: e["event"] == "call" and e.get("conv") == vconv and pred(e), t, what)

            def flush(*ns):
                for N in ns:
                    while True:
                        try:
                            N.events.get_nowait()
                        except queue.Empty:
                            break

            def never_rung(N):
                try:
                    e = N.wait_event(lambda e: e["event"] == "call" and str(e.get("conv", "")).startswith(f"g:{gid}"), 1, "call")
                    raise AssertionError(f"{N.name} got a call event for the room: {e}")
                except TimeoutError:
                    pass

            # A joins: a silent room — B and C see A there (event + spaces), nobody rings
            flush(A, B, C)
            r = A.call("voice_join", conv=vconv)
            st = call_ev(A, lambda e: e["state"] == "active", "A's room call")
            assert st["room"] is True and st["participants"] == [], st
            for N in (B, C):
                voice_ev(N, lambda e: e["participants"] == [pa], f"{N.name}: voice event with A")
                assert parts(N) == [pa], (N.name, parts(N))
            assert parts(A) == [pa]
            never_rung(B)
            never_rung(C)
            # B joins: A and B are in one media session (same room call, each other's device)
            flush(A, B)
            rb = B.call("voice_join", conv=vconv)
            assert rb["call_id"] == r["call_id"], (r, rb)
            call_ev(A, lambda e: e["state"] == "active" and dev["Bob"] in [p["peer"] for p in e["participants"]], "A: B joins the media")
            call_ev(B, lambda e: e["state"] == "active" and dev["Alice"] in [p["peer"] for p in e["participants"]], "B: media with A")
            for N in (A, B, C):
                wait_until(lambda N=N: parts(N) == [pa, pb], 20, f"{N.name} sees A and B")
            assert A.call("voice_state", conv=vconv)["joined"] is True
            never_rung(C)
            # mute is part of the presence everyone sees
            A.call("call_set", call_id=r["call_id"], mic=False)
            wait_until(lambda: C.call("voice_state", conv=vconv)["muted"] == [pa], 15, "C: A muted")
            A.call("call_set", call_id=r["call_id"], mic=True)
            wait_until(lambda: C.call("voice_state", conv=vconv)["muted"] == [], 15, "C: A unmuted")
            # B leaves: presence updates everywhere, A's room goes on
            flush(A, B)
            B.call("voice_leave", conv=vconv)
            call_ev(B, lambda e: e["state"] == "ended", "B's room call ended")
            call_ev(A, lambda e: e["state"] == "active" and e["participants"] == [], "A: B left the media")
            for N in (A, B, C):
                wait_until(lambda N=N: parts(N) == [pa], 20, f"{N.name} sees only A")
            # A crashes (no goodbye): its presence expires for B and C
            ttl = int(os.environ["LUMORA_VOICE_TTL_MS"]) / 1000
            flush(B, C)
            A.p.kill()
            A.p.wait()
            t0 = time.time()
            for N in (B, C):
                wait_until(lambda N=N: parts(N) == [], ttl + 15, f"{N.name}: A's presence expires")
            print(f"     presence expired {time.time() - t0:.1f}s after the crash (ttl {ttl:.0f}s)")
            voice_ev(B, lambda e: e["participants"] == [], "B: voice event, room empty", 5)
            A.start()
            assert parts(A) == [], "a restarted node is in no room"
        _()

        @step("group seen-by survives a restart: B reads, A restarts, A still knows B's read mark")
        def _():
            g = A.call("create_group", name="Nhóm đã xem", members=[pb, pc])
            gid, conv = g["gid"], g["conv"]
            for N in (B, C):
                wait_until(lambda N=N: any(x["gid"] == gid for x in N.call("groups")), 30, f"{N.name} joined")
            m = A.call("send_text", conv=conv, text="ai đọc rồi thì báo nhé")
            for N in (B, C):
                wait_until(lambda N=N: any(x["id"] == m["id"] for x in N.call("messages", conv=conv)), 20, f"{N.name} got it")
            hlc = [x for x in A.call("messages", conv=conv) if x["id"] == m["id"]][0]["hlc"]
            B.call("mark_read", conv=conv)
            A.wait_event(lambda e: e["event"] == "group_read" and e["conv"] == conv and e["peer"] == pb and e["upto"] >= hlc, 20, what="B's receipt")
            reads = A.call("group_reads", conv=conv)
            assert reads.get(pb, 0) >= hlc and pc not in reads and pa not in reads, reads
            A.stop()
            A.start()
            reads = A.call("group_reads", conv=conv)
            assert reads.get(pb, 0) >= hlc, f"read mark lost on restart: {reads}"
            assert pc not in reads, reads
            assert pb in A.call("seen_by", msg_id=m["id"]) and pc not in A.call("seen_by", msg_id=m["id"])
            # C reads later: added next to B's kept mark
            C.call("mark_read", conv=conv)
            wait_until(lambda: A.call("group_reads", conv=conv).get(pc, 0) >= hlc, 20, "C's mark")
            assert A.call("group_reads", conv=conv).get(pb, 0) >= hlc
        _()

        @step("data at rest is encrypted (no plaintext in DB files)")
        def _():
            for n in nodes:
                for fn in os.listdir(n.data):
                    if fn.startswith("lumora.db"):
                        raw = open(os.path.join(n.data, fn), "rb").read()
                        for needle in ["Xin chào".encode(), "Chào cả nhóm".encode(), b"Alice", b"SQLite format"]:
                            assert needle not in raw, f"plaintext {needle!r} found in {n.name}/{fn}"
        _()

        @step("storage maintenance + outbox drained (bounded storage)")
        def _():
            def drained():
                tot = sum(n.call("storage_stats")["outbox"] for n in nodes)
                return tot == 0
            wait_until(drained, 20, "all outboxes empty")
            st = A.call("maintain")
            print(f"     {st}")
        _()
    except Exception:
        ok = False
    finally:
        for n in nodes:
            n.stop()
        passed = sum(1 for r in RESULTS if r[1])
        print(f"\n{passed}/{len(RESULTS)} scenarios passed")
        if not a.keep and ok:
            shutil.rmtree(tmp, ignore_errors=True)
        elif not ok:
            print(f"logs kept in {tmp}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
