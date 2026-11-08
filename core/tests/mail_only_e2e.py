#!/usr/bin/env python3
"""Two friends whose devices can never connect (both behind symmetric NATs, no friend to
relay): only sealed signaling mail goes through. Photos and small files must arrive anyway.

    python3 core/tests/mail_only_e2e.py [--bin core/target/debug/lumorad] [--relay-bin core/target/debug/lumora-relay]

`LUMORA_TEST_NO_CONNECT=1` (debug builds) makes every dial fail; a local lumora-relay
carries signaling only (its relayed data path is a dial too, so it is refused as well).
Checks: friend request + accept by mail; a text; a photo message (its preview makes it
bigger than one signal — sent in pieces); the photo itself (~300 KB, by mail chunks, hash
checked); a voice-sized file; a 12 MB file is NOT pushed by mail (it waits for a path).
"""
import argparse
import hashlib
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
from e2e import Node, wait_until  # noqa: E402


def write_noise_png(path, w, h):
    """An RGB PNG of random pixels, no imaging library needed (CI has none)."""
    import struct
    import zlib

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + os.urandom(w * 3) for _ in range(h))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows, 1)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, "target", "debug", "lumorad"))
    ap.add_argument("--relay-bin", default=os.path.join(ROOT, "target", "debug", "lumora-relay"))
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="lumora-mailonly-")
    rport, sport = free_port(), free_port()
    relay = subprocess.Popen([a.relay_bin, "--listen", f"127.0.0.1:{rport}", "--stun-port", str(sport), "--stun-bind", "127.0.0.1"],
                             stdout=subprocess.DEVNULL, stderr=open(os.path.join(tmp, "relay.log"), "w"))
    time.sleep(1)
    url = f"ws://127.0.0.1:{rport}/ws"
    os.environ["LUMORA_TEST_NO_CONNECT"] = "1"
    os.environ.setdefault("LUMORA_LOG", "info,lumora_core::node::file_mail=debug")
    extra = ["--no-nostr", "--no-lan", "--no-mdns", "--no-dht", "--no-upnp", "--stun", f"127.0.0.1:{sport}", "--relay", url]
    results = []

    def start(name):
        d = os.path.join(tmp, name)
        os.makedirs(d)
        return Node(name, a.bin, d, extra + ["--downloads", os.path.join(d, "dl")])

    def step(label, fn):
        t = time.time()
        try:
            fn()
            results.append(True)
            print(f"  ✅ {label} ({time.time() - t:.1f}s)", flush=True)
        except Exception as e:  # noqa: BLE001
            results.append(False)
            print(f"  ❌ {label}: {type(e).__name__}: {e}", flush=True)

    A = B = None
    try:
        A, B = start("A"), start("B")
        pa, pb = A.me["peer"], B.me["peer"]
        conv_ab = f"d:{pb}"  # A's chat with B
        conv_ba = f"d:{pa}"

        def befriend():
            A.call("add_contact", target=pb)
            wait_until(lambda: any(c["peer"] == pa and c["status"] == 2 for c in B.call("contacts")), 60, "request by mail")
            B.call("accept_contact", peer=pa)
            wait_until(lambda: any(c["peer"] == pb and c["status"] == 3 for c in A.call("contacts")), 60, "accepted by mail")
            assert not any(c.get("online") for c in A.call("contacts") if c["peer"] == pb), "they must not be connected"
        step("friends by mail only (no connection at all)", befriend)

        def text():
            A.call("send_text", conv=conv_ab, text="xin chào qua hộp thư")
            wait_until(lambda: any((m.get("body") or {}).get("text") == "xin chào qua hộp thư" for m in B.call("messages", conv=conv_ba)), 60, "text")
        step("text by mail", text)

        def photo_and_file(name, size, kind):
            src = os.path.join(tmp, name)
            if kind == "png":
                # a noisy picture (its preview is > 12 KB, so the photo message goes in pieces)
                write_noise_png(src, 800, 600)
            else:
                open(src, "wb").write(os.urandom(size))
            h = hashlib.sha256(open(src, "rb").read()).hexdigest()
            m = A.call("send_file", conv=conv_ab, path=src)
            fid = m["id"] if "id" in m and len(m.get("id", "")) == 32 and "body" not in m else (m.get("body") or {}).get("file_id") or m.get("id")
            msg = wait_until(lambda: next((x for x in B.call("messages", conv=conv_ba) if (x.get("body") or {}).get("name") == name), None), 90, f"{name}: message by mail")
            bid = msg["body"]["file_id"]
            B.call("accept_file", file_id=bid)
            done = wait_until(lambda: next((f for f in B.call("files") if f["id"] == bid and f["state"] == 2), None), 240, f"{name}: file by mail")
            assert hashlib.sha256(open(done["path"], "rb").read()).hexdigest() == h, "content differs"
            return fid

        step("photo (~1.4 MB): the message in pieces, the photo by mail chunks", lambda: photo_and_file("photo.png", 0, "png"))
        step("voice-sized file (40 KB) by mail", lambda: photo_and_file("voice.m4a", 40_000, "bin"))

        def big_waits():
            src = os.path.join(tmp, "video.mp4")
            open(src, "wb").write(os.urandom(12 * 1024 * 1024))
            A.call("send_file", conv=conv_ab, path=src)
            msg = wait_until(lambda: next((x for x in B.call("messages", conv=conv_ba) if (x.get("body") or {}).get("name") == "video.mp4"), None), 90, "big file message")
            bid = msg["body"]["file_id"]
            B.call("accept_file", file_id=bid)
            time.sleep(15)
            f = next(f for f in B.call("files") if f["id"] == bid)
            assert f["state"] == 1 and f["progress"] == 0, f"a 12 MB file must wait for a connection, not go by mail: {f}"
        step("12 MB file is not pushed by mail (waits for a direct path)", big_waits)
    finally:
        for n in (A, B):
            if n:
                n.p.terminate()
        relay.terminate()
        if not a.keep:
            shutil.rmtree(tmp, ignore_errors=True)
    n = len(results)
    print(f"{sum(results)}/{n} passed", flush=True)
    sys.exit(0 if all(results) and n == 5 else 1)


if __name__ == "__main__":
    main()
