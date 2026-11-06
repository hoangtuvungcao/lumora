#!/usr/bin/env python3
"""Multi-device end-to-end test: one account on several devices (docs/src/dev/multi-device.md).

    python3 core/tests/multidevice_e2e.py [--bin core/target/debug/lumorad]

Real `lumorad` nodes on the LAN (no Internet services), driven over the JSON API with the
harness from e2e.py. Devices: A0 (main device), A1 (linked by QR), A2 (linked by code),
A3 (resumable history), B0 + B1 (a friend with two devices) and C (single-device friend).

Scenarios: linking by QR and by code (wrong code, code rotation), linking by invitation
(the main device shows the QR / code, the new device scans), device lists, fan-out of a
friend's messages to every device, self-sync of sent messages / read state / pins /
profile, offline catch-up, history window + file fetched from the other device, groups
with multi-device members (one key rotation per removal), resumable history transfer,
remote control with the v2 password verifier and per-device targets,
calls ringing every device (first answer wins), device short IDs, revocation with remote
wipe and group re-keying, signing a device out, promoting a linked device with the
recovery phrase.
"""
import argparse, json, os, shutil, sys, tempfile, time, hashlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e import Node, wait_until, step, RESULTS  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def now_ms():
    return int(time.time() * 1000)


def msgs(n, conv, limit=500):
    return n.call("messages", conv=conv, limit=limit)


def has_msg(n, conv, mid):
    return any(m["id"] == mid for m in msgs(n, conv))


def conv_row(n, conv):
    return next((c for c in n.call("conversations") if c["id"] == conv), None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, "target", "debug", "lumorad"))
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="lumora-md-")
    os.environ["E2E_TMP"] = tmp
    # isolated Bonjour service so concurrent test runs don't see each other
    os.environ.setdefault("LUMORA_MDNS_SERVICE", f"_lmd{os.getpid() % 10000}._udp.local.")
    extra = ["--no-nostr"]

    def mk(name):
        d = os.path.join(tmp, name)
        os.makedirs(d, exist_ok=True)
        return d

    def start(name, binary=None, more=(), env=None):
        d = mk(name)
        old = {}
        for k, v in (env or {}).items():
            old[k] = os.environ.get(k)
            os.environ[k] = v
        try:
            return Node(name, binary or a.bin, d, extra + ["--downloads", os.path.join(d, "dl")] + list(more))
        finally:
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

    print(f"data: {tmp}")
    A0 = start("A0")
    B0 = start("B0")
    C = start("C")
    nodes = [A0, B0, C]
    ok = True
    pa, pb, pc = A0.me["peer"], B0.me["peer"], C.me["peer"]
    dA, dB, dC = f"d:{pa}", f"d:{pb}", f"d:{pc}"
    ctx = {}

    def befriend(x, y):
        x.call("connect", peer=y.me["peer"], timeout=40)
        x.call("add_contact", target=y.me["peer"], note="hi")
        y.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == x.me["peer"], 20, "friend_request")
        y.call("accept_contact", peer=x.me["peer"])
        wait_until(lambda: any(c["peer"] == y.me["peer"] and c["status"] == 3 for c in x.call("contacts")), 15, "friends")

    def link(E, name, mode="qr", history="all", since=None, env=None, wrong_codes=0):
        N = start(name, more=["--link-pending"], env=env)
        st = N.call("link_start", name=name)
        assert st["qr"].startswith("lumora://link/") and len(st["code"]) == 14, st
        assert N.call("me")["primary"] is True
        if mode == "qr":
            info = E.call("link_scan", qr=st["qr"], timeout=60)
        else:
            code = st["code"]
            for i in range(wrong_codes):
                digits = code.replace("-", "")
                bad = digits[:4] + ("%08d" % ((int(digits[4:]) + 1 + i) % 10**8))
                try:
                    E.call("link_scan", code=bad, timeout=60)
                    raise AssertionError("a wrong code was accepted")
                except RuntimeError as e:
                    assert "err.link_code_wrong" in str(e) or "err.link_failed" in str(e) or "err.link_not_found" in str(e), e
            if wrong_codes >= 3:
                ev = N.wait_event(lambda e: e["event"] == "link_state" and e["state"] == "code_rotated", 20, "code rotated")
                assert ev["code"] != code
                code = ev["code"]
            info = E.call("link_scan", code=code, timeout=60)
        assert info["device"] == st["device"] and info["name"] == name, info
        kw = {"device": info["device"], "history": history}
        if since is not None:
            kw["history_since_ms"] = since
        devs = E.call("link_approve", **kw)
        assert any(d["device"] == st["device"] for d in devs["devices"]), devs
        N.wait_event(lambda e: e["event"] == "link_state" and e["state"] == "restart", 20, "restart")
        wait_until(lambda: N.call("me")["account"] == E.me["account"], 40, "restarted as a device of the account")
        N.me = N.call("me")
        N.extra = [x for x in N.extra if x != "--link-pending"]  # later restarts: a normal device
        assert N.me["peer"] == E.me["account"] and N.me["primary"] is False and N.me["device"] == st["device"], N.me
        return N

    def link_invite(E, name, mode="qr", history="all"):
        """The main device shows the invitation; the new device scans it / types the code."""
        N = start(name, more=["--link-pending"])
        inv = E.call("link_invite")
        assert inv["qr"].startswith("lumora://link/") and len(inv["code"]) == 14, inv
        r = N.call("link_scan", name=name, **({"qr": inv["qr"]} if mode == "qr" else {"code": inv["code"]}), timeout=60)
        assert r["state"] == "awaiting_approval" and r["device"] == E.me["device"], r
        ev = E.wait_event(lambda e: e["event"] == "link_request" and e["device"] == N.me["device"], 30, "link_request")
        assert ev["name"] == name and ev["kind"] in (1, 2, 3, 4), ev
        E.call("link_approve", device=ev["device"], history=history)
        N.wait_event(lambda e: e["event"] == "link_state" and e["state"] == "restart", 20, "restart")
        wait_until(lambda: N.call("me")["account"] == E.me["account"], 40, "restarted as a device of the account")
        N.me = N.call("me")
        N.extra = [x for x in N.extra if x != "--link-pending"]
        assert N.me["peer"] == E.me["account"] and not N.me["primary"], N.me
        return N

    try:
        print(f"A {A0.me['short_id']}  B {B0.me['short_id']}  C {C.me['short_id']}")

        @step("setup: friends, chats, a group and a file")
        def _():
            befriend(B0, A0)
            befriend(C, A0)
            befriend(B0, C)
            m = B0.call("send_text", conv=dA, text="trước khi liên kết")
            A0.wait_event(lambda e: e["event"] == "message" and e["id"] == m["id"], 15, "pre-link msg")
            g = A0.call("create_group", name="Nhà mình", members=[pb, pc])
            ctx["g0"] = g
            for n in (B0, C):
                wait_until(lambda n=n: any(x["gid"] == g["gid"] for x in n.call("groups")), 20, f"{n.name} in group")
            gm = A0.call("send_text", conv=g["conv"], text="chào cả nhà")
            B0.wait_event(lambda e: e["event"] == "message" and e["id"] == gm["id"], 15, "group msg")
        _()

        @step("link a new device by QR (A1): same account, 2 devices, contacts + groups + history copied")
        def _():
            A1 = link(A0, "A1", "qr", history="all")
            nodes.append(A1)
            ctx["A1"] = A1
            devs = A0.call("devices")
            assert len(devs["devices"]) == 2 and devs["primary"], devs
            wait_until(lambda: A1.call("history_status")["done"], 60, "history copied")
            d1 = A1.call("devices")
            assert len(d1["devices"]) == 2 and not d1["primary"], d1
            friends = {c["peer"] for c in A1.call("contacts") if c["status"] == 3}
            assert {pb, pc} <= friends, friends
            assert any(x["gid"] == ctx["g0"]["gid"] for x in A1.call("groups")), "group copied"
            assert any(m["body"].get("text") == "trước khi liên kết" for m in msgs(A1, dB)), "history copied"
            assert A1.call("me")["name"] == A0.me["name"], (A1.call("me")["name"], A0.me["name"])
            # the recovery phrase stays on the main device
            try:
                A1.call("recovery_phrase")
                raise AssertionError("secondary showed the recovery phrase")
            except RuntimeError as e:
                assert "err.phrase_on_primary" in str(e)
            # no stranger rows for the new device anywhere; friends learn the device list
            assert not any(c["peer"] == A1.me["device"] for c in A0.call("contacts"))
            wait_until(lambda: len(B0.call("contact_devices", peer=pa)) == 2, 20, "B learns A's 2 devices")
        _()

        @step("link a third device by 12-digit code over LAN (A2): 3 wrong codes rotate it, history window honoured")
        def _():
            m1 = B0.call("send_text", conv=dA, text="đợt 1 (ngoài khoảng)")
            A0.wait_event(lambda e: e["event"] == "message" and e["id"] == m1["id"], 15, "batch1")
            time.sleep(1.2)
            t = now_ms()
            m2 = B0.call("send_text", conv=dA, text="đợt 2 (trong khoảng)")
            A0.wait_event(lambda e: e["event"] == "message" and e["id"] == m2["id"], 15, "batch2")
            # a file sent inside the window: A2 will fetch it from A0 later
            fpath = os.path.join(tmp, "baocao.bin")
            with open(fpath, "wb") as f:
                f.write(os.urandom(300_000))
            ctx["file_hash"] = hashlib.sha256(open(fpath, "rb").read()).hexdigest()
            fm = A0.call("send_file", conv=dB, path=fpath)
            ctx["file_msg"] = fm["id"]
            A2 = link(A0, "A2", "code", history="1m", since=t, wrong_codes=3)
            nodes.append(A2)
            ctx["A2"] = A2
            wait_until(lambda: A2.call("history_status")["done"], 60, "history copied")
            texts = [m["body"].get("text") for m in msgs(A2, dB)]
            assert "đợt 2 (trong khoảng)" in texts, texts
            assert "đợt 1 (ngoài khoảng)" not in texts and "trước khi liên kết" not in texts, texts
            assert len(A0.call("devices")["devices"]) == 3
            wait_until(lambda: len(ctx["A1"].call("devices")["devices"]) == 3, 20, "A1 learns A2")
            wait_until(lambda: len(B0.call("contact_devices", peer=pa)) == 3, 20, "B learns A2")
        _()
        A1, A2 = ctx["A1"], ctx["A2"]

        @step("messages from a friend reach every device of the account (one copy each); sender sees delivered")
        def _():
            m = B0.call("send_text", conv=dA, text="gửi tới mọi thiết bị 📱💻")
            for n in (A0, A1, A2):
                n.wait_event(lambda e: e["event"] == "message" and e["id"] == m["id"], 20, f"{n.name} got it")
            time.sleep(1.5)
            for n in (A0, A1, A2):
                assert sum(1 for x in msgs(n, dB) if x["id"] == m["id"]) == 1
            wait_until(lambda: [x for x in msgs(B0, dA) if x["id"] == m["id"]][0]["status"] >= 2, 15, "delivered")
        _()

        @step("a message sent from A1 reaches the friend and appears on A0 and A2 (self-sync)")
        def _():
            m = A1.call("send_text", conv=dB, text="gửi từ máy tính bảng")
            B0.wait_event(lambda e: e["event"] == "message" and e["id"] == m["id"], 20, "B got it")
            got = [x for x in msgs(B0, dA) if x["id"] == m["id"]][0]
            assert got["author"] == pa, got
            for n in (A0, A2):
                wait_until(lambda n=n: has_msg(n, dB, m["id"]), 20, f"{n.name} sees A1's message")
                mine = [x for x in msgs(n, dB) if x["id"] == m["id"]][0]
                assert mine["mine"] is True, mine
        _()

        @step("read state, pins and the profile name sync across the account's devices")
        def _():
            m = B0.call("send_text", conv=dA, text="chưa đọc")
            for n in (A0, A1):
                n.wait_event(lambda e: e["event"] == "message" and e["id"] == m["id"], 20, "unread msg")
            wait_until(lambda: conv_row(A0, dB)["unread"] > 0, 10, "A0 unread")
            A1.call("mark_read", conv=dB)
            wait_until(lambda: conv_row(A0, dB)["unread"] == 0, 15, "A0 unread cleared by A1")
            wait_until(lambda: conv_row(A2, dB)["unread"] == 0, 15, "A2 unread cleared by A1")
            wait_until(lambda: [x for x in msgs(B0, dA) if x["id"] == m["id"]][0]["status"] == 3, 15, "B sees read")
            A1.call("conv_flag", conv=dB, flag="pinned", value=True)
            wait_until(lambda: conv_row(A0, dB)["pinned"], 15, "pin synced")
            A2.call("set_name", name="An Nguyễn")
            wait_until(lambda: A0.call("me")["name"] == "An Nguyễn", 15, "name synced to A0")
            wait_until(lambda: A1.call("me")["name"] == "An Nguyễn", 15, "name synced to A1")
        _()

        @step("an offline device catches up (A2 stopped; B → A and A1 → B meanwhile; A2 back)")
        def _():
            A2.stop()
            fromB = [B0.call("send_text", conv=dA, text=f"lúc A2 tắt {i}")["id"] for i in range(5)]
            fromA1 = [A1.call("send_text", conv=dB, text=f"A1 gửi lúc A2 tắt {i}")["id"] for i in range(3)]
            for mid in fromA1:
                B0.wait_event(lambda e, mid=mid: e["event"] == "message" and e["id"] == mid, 20, "B got A1 msg")
            A2.start()
            assert A2.me["device"] == ctx["A2"].me["device"] and not A2.me["primary"]
            for mid in fromB + fromA1:
                wait_until(lambda mid=mid: has_msg(A2, dB, mid), 40, "A2 caught up")
            ids = [x["id"] for x in msgs(A2, dB)]
            assert len(ids) == len(set(ids)), "duplicates"
        _()

        @step("history: a file in the window is kept on A0 and fetched from it on demand")
        def _():
            def fmsg():
                return [x for x in msgs(A2, dB) if x["kind"] == "file" and x["body"].get("file_id") == ctx["file_msg"]]
            fm = fmsg()
            assert fm, "file message copied"
            fid = fm[0]["body"]["file_id"]
            assert fm[0].get("file", {}).get("state") == 7, fm[0].get("file")
            A2.call("accept_file", file_id=fid)
            wait_until(lambda: fmsg()[0]["file"]["state"] == 2, 30, "downloaded from A0")
            path = fmsg()[0]["file"]["path"]
            assert hashlib.sha256(open(path, "rb").read()).hexdigest() == ctx["file_hash"]
        _()

        @step("groups with multi-device members: every device gets every message; removal rotates the key once")
        def _():
            B1 = link(B0, "B1", "qr", history="none")
            nodes.append(B1)
            ctx["B1"] = B1
            wait_until(lambda: B1.call("history_status")["done"], 60, "B1 bootstrap")
            wait_until(lambda: len(A0.call("contact_devices", peer=pb)) == 2, 20, "A learns B's devices")
            wait_until(lambda: len(A1.call("contact_devices", peer=pb)) == 2, 20, "A1 learns B's devices")
            g = A1.call("create_group", name="Multi", members=[pb, pc])
            ctx["g1"] = g
            members = [A0, A1, A2, B0, B1, C]
            for n in members:
                wait_until(lambda n=n: any(x["gid"] == g["gid"] for x in n.call("groups")), 30, f"{n.name} in group")
            posts = []
            for n in (A0, A1, B0, B1, C):
                posts.append(n.call("send_text", conv=g["conv"], text=f"xin chào từ {n.name}")["id"])
            for n in members:
                for mid in posts:
                    wait_until(lambda n=n, mid=mid: has_msg(n, g["conv"], mid), 30, f"{n.name} got {mid[:6]}")
            A1.call("group_remove", gid=g["gid"], peer=pc)
            for n in (A0, A1, A2, B0, B1):
                wait_until(lambda n=n: n.call("group_info", gid=g["gid"])["epoch"] == 1, 30, f"{n.name} epoch 1")
            time.sleep(2)
            for n in (A0, A1, A2, B0, B1):
                assert n.call("group_info", gid=g["gid"])["epoch"] == 1, "rotated more than once"
            after = B1.call("send_text", conv=g["conv"], text="sau khi xoá C")
            for n in (A0, A1, A2, B0):
                wait_until(lambda n=n: has_msg(n, g["conv"], after["id"]), 30, f"{n.name} reads epoch 1")
            time.sleep(1)
            assert not has_msg(C, g["conv"], after["id"]), "removed member read a new message"
        _()

        @step("resumable history: transfer interrupted mid-way resumes with no duplicates")
        def _():
            # a long backlog (in "Saved messages", no network involved)
            for i in range(300):
                A0.call("send_text", conv="s:me", text=f"lịch sử dài {i}")
            A3 = link(A0, "A3", "qr", history="all", env={"LUMORA_HIST_BATCH": "10"})
            nodes.append(A3)
            try:
                A3.wait_event(lambda e: e["event"] == "history_sync" and not e["done"], 30, "first batch")
            except TimeoutError:
                pass
            A3.p.kill()
            A3.p.wait()
            partial = None
            old = os.environ.get("LUMORA_HIST_BATCH")
            os.environ["LUMORA_HIST_BATCH"] = "10"
            try:
                A3.start()
            finally:
                if old is None:
                    os.environ.pop("LUMORA_HIST_BATCH", None)
                else:
                    os.environ["LUMORA_HIST_BATCH"] = old
            partial = A3.call("history_status")
            print(f"     after restart: {partial}")
            wait_until(lambda: A3.call("history_status")["done"], 90, "history completed after restart")
            want = {m["id"] for m in msgs(A0, "s:me", 500)} | {m["id"] for m in msgs(A0, dB, 500)}
            got = [m["id"] for m in msgs(A3, "s:me", 500)] + [m["id"] for m in msgs(A3, dB, 500)]
            assert len(got) == len(set(got)), "duplicates after resume"
            missing = want - set(got)
            assert not missing, f"{len(missing)} messages missing"
        _()

        @step("remote control v2: fixed password kept as a verifier (unattended login); temporary password needs the host's approval")
        def _():
            A0.call("remote_set", password="mat-khau-may-tinh", unattended=True)
            st = A0.call("remote_status")
            assert st["fixed_password"] and not st["fixed_password_legacy"], st
            # several controllable devices: the target must be chosen
            try:
                B0.call("remote_connect", target=pa, password="x", view_only=True)
                raise AssertionError("no device choice asked")
            except RuntimeError as e:
                assert "err.choose_device" in str(e) and A1.me["device"] in str(e), e
            r = B0.call("remote_connect", target=pa, device=pa, password="mat-khau-may-tinh", view_only=True)
            B0.wait_event(lambda e: e["event"] == "remote_state" and e.get("session") == r["session"] and e["state"] == "active", 30, "v2 unattended login")
            B0.call("remote_end", session=r["session"])
            r = C.call("remote_connect", target=pa, device=pa, password="sai-mat-khau", view_only=True)
            C.wait_event(lambda e: e["event"] == "remote_state" and e.get("session") == r["session"] and e["state"] == "denied", 30, "wrong password denied")
            temp = A0.call("remote_status")["password"]
            r = C.call("remote_connect", target=pa, device=pa, password=temp, view_only=True)
            e = A0.wait_event(lambda e: e["event"] == "remote_request" and e.get("peer") == pc, 30, "temp password request")
            A0.call("remote_respond", session=e["session"], accept=True, control=False)
            C.wait_event(lambda e: e["event"] == "remote_state" and e.get("session") == r["session"] and e["state"] == "active", 30, "temp password ok")
            C.call("remote_end", session=r["session"])
        _()

        @step("link by invitation: the main device shows the QR (A4) / the 12-digit code (A5); the new device scans or types it")
        def _():
            A4 = link_invite(A0, "A4", "qr", history="none")
            nodes.append(A4)
            ctx["A4"] = A4
            A5 = link_invite(A0, "A5", "code", history="none")
            nodes.append(A5)
            ctx["A5"] = A5
            for n in (A4, A5):
                wait_until(lambda n=n: n.call("history_status")["done"], 60, f"{n.name} bootstrap")
                assert {pb, pc} <= {c["peer"] for c in n.call("contacts") if c["status"] == 3}
            assert len(A0.call("devices")["devices"]) == 6
            m = B0.call("send_text", conv=dA, text="tới máy mới")
            for n in (A4, A5):
                n.wait_event(lambda e: e["event"] == "message" and e["id"] == m["id"], 30, f"{n.name} got it")
        _()

        @step("device short IDs: B controls A1 by A1's own 9-digit ID; only A1 is asked")
        def _():
            devs = {d["device"]: d for d in A0.call("devices")["devices"]}
            sid = devs[A1.me["device"]]["short_id"]
            assert sid != A0.me["short_id"], sid
            r = B0.call("remote_connect", target=sid.replace(" ", ""), password="", view_only=True)
            assert r["peer"] == A1.me["device"], r
            e = A1.wait_event(lambda e: e["event"] == "remote_request", 30, "A1 asked")
            A1.call("remote_respond", session=e["session"], accept=False)
            time.sleep(1)
            try:
                A0.wait_event(lambda e: e["event"] == "remote_request", 1, "A0 not asked")
                raise AssertionError("A0 was asked too")
            except TimeoutError:
                pass
        _()

        @step("calls ring every device of the callee; the first to answer wins, the others stop ('answered elsewhere')")
        def _():
            c = B0.call("call_start", conv=dA, video=False)
            for n in (A0, A1):
                n.wait_event(lambda e: e["event"] == "call" and e["call_id"] == c["call_id"] and e["state"] == "incoming", 20, f"{n.name} rings")
            A1.call("call_answer", call_id=c["call_id"], accept=True)
            e = A0.wait_event(lambda e: e["event"] == "call" and e["call_id"] == c["call_id"] and e["state"] == "ended", 5, "A0 stops ringing")
            assert e.get("reason") == "answered_elsewhere" and e.get("device_name") == "A1", e
            st = B0.wait_event(lambda e: e["event"] == "call" and e["call_id"] == c["call_id"] and e["state"] == "active", 10, "B active")
            assert [p["peer"] for p in st["participants"]] == [A1.me["device"]], st["participants"]
            B0.call("call_end", call_id=c["call_id"])
            time.sleep(1)
            # a decline on one device is the account's answer
            c = B0.call("call_start", conv=dA, video=False)
            for n in (A0, A1):
                n.wait_event(lambda e: e["event"] == "call" and e["call_id"] == c["call_id"] and e["state"] == "incoming", 20, f"{n.name} rings")
            A0.call("call_answer", call_id=c["call_id"], accept=False)
            A1.wait_event(lambda e: e["event"] == "call" and e["call_id"] == c["call_id"] and e["state"] == "ended", 5, "A1 stops ringing")
            B0.wait_event(lambda e: e["event"] == "call" and e["call_id"] == c["call_id"] and e["state"] == "ended", 10, "call ended for B")
        _()

        @step("revocation with wipe: A0 signs A2 out; friends drop it, its data is wiped, group keys rotate")
        def _():
            g = ctx["g1"]
            ep = B0.call("group_info", gid=g["gid"])["epoch"]
            dev2 = A2.me["device"]
            A0.call("device_revoke", device=dev2, wipe_media=True)
            ev = A2.wait_event(lambda e: e["event"] == "device_revoked", 30, "A2 told")
            assert ev["wipe"] is True, ev
            # lumorad restarts it as a fresh install
            wait_until(lambda: A2.call("me")["peer"] != pa, 40, "A2 restarted fresh")
            fresh = A2.call("me")
            assert fresh["device"] != dev2 and fresh["primary"] and A2.call("contacts") == [] and A2.call("groups") == [], fresh
            wait_until(lambda: dev2 not in [d["device"] for d in B0.call("contact_devices", peer=pa)], 30, "B drops A2")
            assert dev2 not in [d["device"] for d in A1.call("devices")["devices"]]
            # A is the group's owner: the main device rotated the key (A2 can't read what follows)
            wait_until(lambda: B0.call("group_info", gid=g["gid"])["epoch"] > ep, 40, "group key rotated")
            m = B0.call("send_text", conv=g["conv"], text="sau khi gỡ A2")
            for n in (A0, A1):
                wait_until(lambda n=n: has_msg(n, g["conv"], m["id"]), 30, f"{n.name} reads the new epoch")
        _()

        @step("plain member revokes a device: B0 signs B1 out → the group admin rotates the key on request")
        def _():
            g = ctx["g1"]
            ep = A0.call("group_info", gid=g["gid"])["epoch"]
            B1 = ctx["B1"]
            B0.call("device_revoke", device=B1.me["device"], wipe_media=False)
            B1.wait_event(lambda e: e["event"] == "device_revoked", 30, "B1 told")
            wait_until(lambda: A0.call("group_info", gid=g["gid"])["epoch"] == ep + 1, 40, "admin rotated on request")
            time.sleep(2)
            assert A0.call("group_info", gid=g["gid"])["epoch"] == ep + 1, "rotated more than once"
            m = A1.call("send_text", conv=g["conv"], text="khoá mới")
            wait_until(lambda: has_msg(B0, g["conv"], m["id"]), 30, "B0 reads the new epoch")
        _()

        @step("a linked device signs itself out (A3): the main device revokes it, A3 starts fresh")
        def _():
            A3 = [n for n in nodes if n.name == "A3"][0]
            dev3 = A3.me["device"]
            r = A3.call("device_logout")
            assert r["notified"] is True, r
            wait_until(lambda: dev3 not in [d["device"] for d in A0.call("devices")["devices"]], 30, "A0 revoked A3")
            wait_until(lambda: A3.call("me")["peer"] != pa, 40, "A3 restarted fresh")
            try:
                A0.call("device_logout")
                raise AssertionError("the main device signed itself out")
            except RuntimeError as e:
                assert "err.primary_logout" in str(e), e
        _()

        @step("promote: with A0 lost, A1 becomes the main device with the recovery phrase; A0 steps down when back")
        def _():
            phrase = A0.call("recovery_phrase")["phrase"]
            old1 = A1.me["device"]
            try:
                A1.call("device_promote", phrase=" ".join(reversed(phrase.split())))
                raise AssertionError("a wrong phrase was accepted")
            except RuntimeError as e:
                assert "err." in str(e), e
            A0.stop()
            A1.call("device_promote", phrase=phrase)
            A1.wait_event(lambda e: e["event"] == "link_state" and e["state"] == "restart", 20, "restart")
            wait_until(lambda: A1.call("me")["primary"], 40, "A1 restarted as the main device")
            me1 = A1.call("me")
            assert me1["device"] == pa and me1["peer"] == pa, me1
            devs = A1.call("devices")
            assert devs["primary"] and old1 in [r["device"] for r in devs["revoked"]], devs
            A1.call("recovery_phrase")  # the main device shows it now
            m = B0.call("send_text", conv=dA, text="gửi cho máy chính mới")
            A1.wait_event(lambda e: e["event"] == "message" and e["id"] == m["id"], 30, "new main device gets messages")
            wait_until(lambda: any(d["device"] == pa for d in B0.call("contact_devices", peer=pa)), 30, "B sees the new list")
            # the old main device comes back: it learns it was replaced and signs out
            A0.start()
            A0.wait_event(lambda e: e["event"] == "device_revoked", 60, "old main device steps down")
        _()

        @step("outboxes drain on every device (bounded storage)")
        def _():
            def drained():
                return sum(n.call("storage_stats")["outbox"] for n in nodes) == 0
            wait_until(drained, 40, "outboxes empty")
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
