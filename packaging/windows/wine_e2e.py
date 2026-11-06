#!/usr/bin/env python3
"""Windows ⇄ Linux end-to-end test: the Windows build of `lumorad.exe` runs under Wine
and talks to a native Linux `lumorad` over the JSON-lines API (see docs/src/dev/api.md).

    python3 packaging/windows/wine_e2e.py \
        [--exe core/target/x86_64-pc-windows-gnu/debug/lumorad.exe] \
        [--linux-bin core/target/debug/lumorad] [--relay ws://127.0.0.1:8443/ws] [--keep]

Scenarios: LAN discovery/connect, friend request both ways, chat both ways (Vietnamese +
emoji), 5 MB file transfer both ways with SHA-256 check, group create + messages,
`diagnostics` on the Windows node, remote-desktop host session on the Windows node
(view-only: no input is injected into the real desktop Wine draws on).

Paths: the Windows node's data dir is C:\\lumora-test in the default Wine prefix
($WINEPREFIX or ~/.wine), i.e. <prefix>/drive_c/lumora-test on the Linux side.
"""
import argparse, hashlib, json, os, queue, shutil, subprocess, sys, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PREFIX = os.environ.get("WINEPREFIX", os.path.expanduser("~/.wine"))
DRIVE_C = os.path.join(PREFIX, "drive_c")


def win_to_unix(p):
    """C:\\a\\b → <prefix>/drive_c/a/b ; Z:\\x → /x ; anything else unchanged."""
    if len(p) > 2 and p[1] == ":":
        rest = p[2:].replace("\\", "/").lstrip("/")
        if p[0] in "cC":
            return os.path.join(DRIVE_C, rest)
        if p[0] in "zZ":
            return "/" + rest
    return p


class Node:
    def __init__(self, name, argv, logfile, env=None):
        self.name = name
        self.events = queue.Queue()
        self.resp = {}
        self.cv = threading.Condition()
        self.next_id = 1
        self.log = open(logfile, "w")
        self.p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
                                  text=True, encoding="utf-8", errors="replace", bufsize=1, env=env)
        threading.Thread(target=self._reader, daemon=True).start()
        self.me = self.call("me", timeout=120)

    def _reader(self):
        for line in self.p.stdout:
            line = line.strip().lstrip("\ufeff")
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
        if self.p.poll() is not None:
            raise RuntimeError(f"{self.name}: process exited with {self.p.returncode}")
        self.p.stdin.write(json.dumps(kw, ensure_ascii=False) + "\n")
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
            raise RuntimeError(f"{self.name}: {cmd} failed: {r.get('error')}")
        return r.get("data")

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
            self.p.wait(timeout=10)
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


def step(name, fn):
    t = time.time()
    try:
        info = fn()
        RESULTS.append((name, True, time.time() - t, info or ""))
        print(f"  PASS {name} ({time.time() - t:.2f}s){' — ' + str(info) if info else ''}", flush=True)
        return True
    except Exception as e:
        RESULTS.append((name, False, time.time() - t, str(e)))
        print(f"  FAIL {name}: {e}", flush=True)
        return False


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", default=os.path.join(ROOT, "core/target/x86_64-pc-windows-gnu/debug/lumorad.exe"))
    ap.add_argument("--linux-bin", default=os.path.join(ROOT, "core/target/debug/lumorad"))
    ap.add_argument("--relay", default=None, help="e.g. ws://127.0.0.1:8443/ws (used by both nodes)")
    ap.add_argument("--wine", default=shutil.which("wine") or "/usr/bin/wine")
    ap.add_argument("--keep", action="store_true", help="keep data dirs")
    ap.add_argument("--capture", default=None, choices=["dxgi", "gdi"],
                    help="force LUMORA_CAPTURE on the Windows node; with 'dxgi' under Wine the remote-desktop "
                         "step expects a graceful failure (no GDI fallback) instead of a session")
    a = ap.parse_args()

    win_data = r"C:\lumora-test"
    win_xfer = r"C:\lumora-xfer"
    lin_data = "/tmp/lumora-win-peer"
    for d in (win_to_unix(win_data), win_to_unix(win_xfer), lin_data):
        shutil.rmtree(d, ignore_errors=True)
    os.makedirs(win_to_unix(win_xfer) + "/in", exist_ok=True)
    os.makedirs(lin_data + "/dl", exist_ok=True)
    logdir = os.path.join(lin_data, "logs")
    os.makedirs(logdir, exist_ok=True)

    extra = ["--no-nostr", "--no-dht", "--no-upnp"]
    if a.relay:
        extra += ["--relay", a.relay]
    wenv = dict(os.environ, WINEDEBUG=os.environ.get("WINEDEBUG", "-all"), RUST_LOG="info", NO_COLOR="1")
    wenv.setdefault("WINEPREFIX", PREFIX)
    if a.capture:
        wenv["LUMORA_CAPTURE"] = a.capture
    # GNU cross builds import libstdc++-6.dll / libgcc_s_seh-1.dll (C++ in OpenH264 / AEC):
    # let Wine find mingw's copies instead of copying them next to the exe.
    import glob
    mingw = sorted(glob.glob("/usr/lib/gcc/x86_64-w64-mingw32/*-win32")) + ["/usr/x86_64-w64-mingw32/lib"]
    wenv["WINEPATH"] = ";".join([wenv.get("WINEPATH", "")] + ["Z:" + d.replace("/", "\\") for d in mingw]).strip(";")
    print(f"wine prefix {PREFIX}; logs in {logdir}")
    W = Node("Máy Windows", [a.wine, a.exe, "--data", win_data, "--name", "Máy Windows", "--downloads",
                             win_xfer + r"\in", "--stdio"] + extra, os.path.join(logdir, "windows.log"), wenv)
    L = Node("Máy Linux", [a.linux_bin, "--data", lin_data, "--name", "Máy Linux", "--downloads", lin_data + "/dl",
                           "--stdio"] + extra, os.path.join(logdir, "linux.log"), dict(os.environ, NO_COLOR="1"))
    pw, pl = W.me["peer"], L.me["peer"]
    print(f"Windows {W.me['short_id']} {pw[:12]}…   Linux {L.me['short_id']} {pl[:12]}…")
    cw, cl = f"d:{pl}", f"d:{pw}"  # conversation ids as seen from W and from L

    try:
        def connect():
            r = wait_until(lambda: L.call("connect", peer=pw, timeout=40), 60, "connect")
            return f"path={r['path']} rtt={r['rtt_ms']}ms addr={r['remote_addr']}"
        step("connect Linux → Windows", connect)

        def friend_l2w():
            L.call("add_contact", target=pw, note="Chào máy Windows!")
            e = W.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == pl, what="friend_request")
            assert e["note"] == "Chào máy Windows!", e
            W.call("accept_contact", peer=pl)
            wait_until(lambda: any(c["peer"] == pw and c["status"] == 3 for c in L.call("contacts")), 20, "Linux sees friend")
            wait_until(lambda: any(c["peer"] == pl and c["status"] == 3 for c in W.call("contacts")), 20, "Windows sees friend")
            return f"name on Windows side: {e.get('name')!r}"
        step("friend request Linux → Windows + accept", friend_l2w)

        def friend_w2l():
            # Remove + re-add in the other direction (request originates on Windows).
            L.call("remove_contact", peer=pw)
            W.call("remove_contact", peer=pl)
            time.sleep(1)
            W.call("add_contact", target=L.me["short_id"].replace(" ", ""), note="Xin chào từ Windows 🪟")
            e = L.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == pw, 40, what="friend_request")
            assert e["note"] == "Xin chào từ Windows 🪟", e
            L.call("accept_contact", peer=pw)
            wait_until(lambda: any(c["peer"] == pl and c["status"] == 3 for c in W.call("contacts")), 20, "Windows sees friend")
            wait_until(lambda: any(c["peer"] == pw and c["status"] == 3 for c in L.call("contacts")), 20, "Linux sees friend")
            return f"by 9-digit id, name {e.get('name')!r}"
        step("friend request Windows → Linux (by 9-digit ID) + accept", friend_w2l)

        def chat():
            out = []
            for src, dst, conv_src, conv_dst, text in [
                (W, L, cw, cl, "Xin chào từ Windows 👋 tiếng Việt: ắ ổ ữ đ"),
                (L, W, cl, cw, "Linux trả lời: Chúc mừng năm mới 🎉"),
            ]:
                t0 = time.time()
                m = src.call("send_text", conv=conv_src, text=text)
                e = dst.wait_event(lambda e: e["event"] == "message" and e["id"] == m["id"], what="message")
                assert e["body"]["text"] == text, e["body"]
                wait_until(lambda: [x for x in src.call("messages", conv=conv_src) if x["id"] == m["id"]][0]["status"] >= 2, 15, "delivered")
                dst.call("mark_read", conv=conv_dst)
                wait_until(lambda: [x for x in src.call("messages", conv=conv_src) if x["id"] == m["id"]][0]["status"] == 3, 15, "read")
                out.append(f"{src.name}→{dst.name} {(time.time() - t0) * 1000:.0f} ms")
            return "; ".join(out)
        step("chat both ways (delivered + read receipts, UTF-8)", chat)

        def xfer(src, dst, src_path_native, src_path_api, conv_src, label):
            with open(src_path_native, "wb") as f:
                f.write(os.urandom(5 * 1024 * 1024))
            h = sha256(src_path_native)
            t0 = time.time()
            fid = src.call("send_file", conv=conv_src, path=src_path_api)["id"]
            def done():
                fs = [x for x in dst.call("files") if x["id"] == fid]
                if fs and fs[0]["state"] == 0:  # offered, not auto-accepted
                    dst.call("accept_file", file_id=fid)
                return fs and fs[0]["state"] == 2 and fs[0]
            r = wait_until(done, 120, f"{label} done")
            dt = time.time() - t0
            got_path = win_to_unix(r["path"])
            got = sha256(got_path)
            assert got == h, f"hash mismatch {got} != {h}"
            wait_until(lambda: [x for x in src.call("files") if x["id"] == fid][0]["state"] == 2, 15, "sender done")
            return f"{5 / dt:.1f} MB/s, sha256 {h[:16]}… OK → {r['path']}"

        step("file 5 MB Linux → Windows (SHA-256)",
             lambda: xfer(L, W, lin_data + "/linux-5mb.bin", lin_data + "/linux-5mb.bin", cl, "L→W"))
        step("file 5 MB Windows → Linux (SHA-256)",
             lambda: xfer(W, L, win_to_unix(win_xfer + r"\windows-5mb.bin"), win_xfer + r"\windows-5mb.bin", cw, "W→L"))

        def group():
            g = W.call("create_group", name="Nhóm Win+Linux 🚀", members=[pl])
            gid, conv = g["gid"], g["conv"]
            wait_until(lambda: any(x["gid"] == gid for x in L.call("groups")), 30, "Linux joined")
            m1 = W.call("send_text", conv=conv, text="Windows chào cả nhóm")
            wait_until(lambda: any(x["id"] == m1["id"] for x in L.call("messages", conv=conv)), 20, "Linux got group msg")
            m2 = L.call("send_text", conv=conv, text="Linux đã nhận ✔")
            wait_until(lambda: any(x["id"] == m2["id"] for x in W.call("messages", conv=conv)), 20, "Windows got group msg")
            info = W.call("group_info", gid=gid)
            assert info["my_role"] == "owner" and len(info["members"]) == 2, info
            return f"gid {gid[:8]}…, members {[m['name'] for m in info['members']]}"
        step("group create + messages both ways", group)

        diag_box = {}
        def diagnostics():
            d = W.call("diagnostics", timeout=90)
            diag_box["d"] = d
            print(json.dumps(d, ensure_ascii=False, indent=1))
            assert d["platform"] == "windows", d
            return f"capture_backend={d.get('capture_backend')!r} input_backend={d.get('input_backend')!r} session={d.get('session_type')}"
        step("diagnostics on the Windows node", diagnostics)

        def remote():
            st = W.call("remote_status")
            assert st.get("password"), st
            r = L.call("remote_connect", target=W.me["short_id"].replace(" ", ""), password=st["password"], view_only=True, timeout=60)
            sess = r["session"]
            e = W.wait_event(lambda e: e["event"] == "remote_request", 30, what="remote_request")
            W.call("remote_respond", session=e["session"], accept=True, control=False, timeout=90)
            hs = W.wait_event(lambda e: e["event"] == "remote_state" and e.get("role") == "host" and e["state"] in ("active", "failed"), 90, what="host state")
            if hs["state"] == "failed":
                v = L.wait_event(lambda e: e["event"] == "remote_state" and e.get("session") == sess and e["state"] in ("denied", "failed", "ended"), 30, what="viewer told")
                msg = f"host failed gracefully: {hs.get('reason')!r}; viewer state={v['state']} reason={v.get('reason')!r}"
                time.sleep(1)
                assert W.p.poll() is None, "Windows node died"
                if a.capture == "dxgi":
                    return "expected failure — " + msg
                raise AssertionError(msg)
            v = L.wait_event(lambda e: e["event"] == "remote_state" and e.get("session") == sess and e["state"] == "active", 30, what="viewer active")
            time.sleep(4)  # let a few frames flow
            assert W.p.poll() is None, "Windows node crashed during capture"
            L.call("remote_end", session=sess)
            W.wait_event(lambda e: e["event"] == "remote_state" and e.get("role") == "host" and e["state"] == "ended", 20, what="host ended")
            return f"host {hs.get('width')}x{hs.get('height')}, viewer sees {v.get('width')}x{v.get('height')}"
        step("remote desktop: Windows node hosts (view-only)", remote)

        def still_alive():
            assert W.p.poll() is None and L.p.poll() is None
            return W.call("net_status")["peers"]
        step("both nodes still alive", still_alive)
    finally:
        W.stop()
        L.stop()

    print("\nSUMMARY")
    for name, ok, dt, info in RESULTS:
        print(f"  {'PASS' if ok else 'FAIL'}  {name}  ({dt:.1f}s)  {info}")
    print(f"logs: {logdir}")
    if not a.keep:
        for d in (win_to_unix(win_xfer),):
            shutil.rmtree(d, ignore_errors=True)
    sys.exit(0 if all(r[1] for r in RESULTS) else 1)


if __name__ == "__main__":
    main()
