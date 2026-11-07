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

        @step("file previews before download: .py snippet, .pdf first page, binary .txt refused")
        def _():
            import base64
            # Alice only downloads on demand, so everything below is seen *before* the download
            A.call("set_storage_policy", auto_direct=0)
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
                A.call("set_storage_policy", auto_direct=25 << 20)
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
            wait_until(lambda: pb in A.call("story_viewers", story_id=st["id"]), 10, "story view")
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
            m2 = B.call("send_text", conv=conv_ab, text="tin của Bob, Alice xóa cho cả hai")
            wait_until(lambda: any(x["id"] == m1["id"] for x in B.call("messages", conv=conv_ab)), 10, "m1")
            wait_until(lambda: any(x["id"] == m2["id"] for x in A.call("messages", conv=f"d:{pb}")), 10, "m2")
            A.call("delete_message", conv=f"d:{pb}", msg_id=m1["id"], for_everyone=False)
            assert not any(x["id"] == m1["id"] for x in A.call("messages", conv=f"d:{pb}"))
            time.sleep(0.5)
            assert any(x["id"] == m1["id"] and not x["deleted"] for x in B.call("messages", conv=conv_ab)), "delete-for-me leaked"
            A.call("delete_message", conv=f"d:{pb}", msg_id=m2["id"], for_everyone=True)
            wait_until(lambda: [x for x in B.call("messages", conv=conv_ab) if x["id"] == m2["id"]][0]["deleted"], 10, "other's msg deleted for both")
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

        @step("invite link: removed member rejoins via signed link")
        def _():
            g = A.call("groups")[0]
            link = A.call("create_invite", gid=g["gid"], hours=1)["link"]
            info = C.call("inspect_invite", link=link)
            assert info["valid"] and not info["already_member"], info
            C.call("join_invite", link=link)
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
