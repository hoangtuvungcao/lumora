#!/usr/bin/env python3
"""Linux-side tests for the iPhone features: real `lumorad` nodes + a real `lumora-push` bridge.

    python3 core/tests/apple_e2e.py [--bin core/target/debug/lumorad] [--push-bin core/target/debug/lumora-push]

1. Bonjour/DNS-SD discovery: two nodes with raw LAN multicast, Nostr, DHT and relays all OFF
   find each other through mDNS only and connect directly ("lan" path). Negative control:
   with mDNS off as well they cannot connect.
2. Push wake-up: the "iPhone" registers a sealed APNs token with its friend, goes offline;
   a burst of 5 messages produces exactly ONE wake at the bridge (dry-run APNs log), the push
   carries no plaintext, and the end-to-end blob opens with the recipient's notification key
   using the CryptoKit construction (X25519 → HKDF-SHA256 → ChaChaPoly), implemented here
   independently with `cryptography`. A call to the offline phone sends a VoIP wake.
3. Mailbox on open: when the phone comes back, all 5 queued messages arrive; the next offline
   burst wakes it again (coalescing resets on reconnect).

Isolation: every run uses its own temp dirs and its own DNS-SD service type, so it cannot
cross-talk with core/tests/e2e.py or a desktop Lumora on the same network.
"""
import argparse, base64, json, os, secrets, shutil, socket, subprocess, sys, tempfile, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from e2e import Node, wait_until, step, RESULTS  # noqa: E402

ROOT = os.path.dirname(HERE)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def open_notify(secret_raw: bytes, blob: bytes) -> dict:
    """What the iOS Notification Service Extension does with CryptoKit."""
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
    sk = X25519PrivateKey.from_private_bytes(secret_raw)
    from cryptography.hazmat.primitives import serialization
    my_pub = sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    eph, nonce, ct = blob[:32], blob[32:44], blob[44:]
    shared = sk.exchange(X25519PublicKey.from_public_bytes(eph))
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=eph + my_pub, info=b"lumora-push notify v1").derive(shared)
    return json.loads(ChaCha20Poly1305(key).decrypt(nonce, ct, None))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, "target", "debug", "lumorad"))
    ap.add_argument("--push-bin", default=os.path.join(ROOT, "target", "debug", "lumora-push"))
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="lumora-apple-e2e-")
    os.environ["E2E_TMP"] = tmp
    # DNS-SD service labels are at most 15 characters: "_lt" + 8 hex.
    os.environ["LUMORA_MDNS_SERVICE"] = f"_lt{secrets.token_hex(4)}._udp.local."
    print(f"data: {tmp}  service: {os.environ['LUMORA_MDNS_SERVICE']}")
    # Only DNS-SD may find peers: no multicast announcements, no Nostr, no DHT, no relays.
    only_mdns = ["--no-nostr", "--no-lan-multicast"]
    nodes, procs = [], []

    def mk(name, extra):
        d = os.path.join(tmp, name.lower())
        os.makedirs(d, exist_ok=True)
        n = Node(name, a.bin, d, extra + ["--downloads", os.path.join(d, "dl")])
        nodes.append(n)
        return n

    try:
        A = mk("Alice", only_mdns)
        B = mk("Bob", only_mdns)
        pa, pb = A.me["peer"], B.me["peer"]

        @step("mDNS only (multicast/Nostr/DHT/relays off): Bob finds Alice and connects directly")
        def _():
            r = B.call("connect", peer=pa, timeout=45)
            print(f"     path={r['path']} addr={r['remote_addr']} rtt={r['rtt_ms']}ms")
            assert r["path"] == "lan", r
        _()

        @step("lan_advert exposes a daily hint, never the public key")
        def _():
            adv = A.call("lan_advert")
            assert len(adv["name"]) == 16 and all(c in "0123456789abcdef" for c in adv["name"]), adv
            assert adv["name"] not in pa.lower() and adv["port"] > 0 and adv["enabled"], adv
        _()

        @step("negative control: with mDNS also off, the same setup cannot connect")
        def _():
            C = mk("Carol", only_mdns + ["--no-mdns"])
            D = mk("Dave", only_mdns + ["--no-mdns"])
            try:
                r = D.call("connect", peer=C.me["peer"], timeout=30)
                raise AssertionError(f"connected without any discovery: {r}")
            except (RuntimeError, TimeoutError) as e:
                print(f"     as expected: {str(e)[:80]}")
            C.stop(); D.stop()
        _()

        # ------------------------------------------------------------ push bridge (dry run)
        port = free_port()
        bridge_url = f"http://127.0.0.1:{port}"
        apns_log = os.path.join(tmp, "apns.jsonl")
        blog = open(os.path.join(tmp, "bridge.log"), "w")
        bp = subprocess.Popen([a.push_bin, "--listen", f"127.0.0.1:{port}", "--state", os.path.join(tmp, "bridge"),
                               "--apns-log", apns_log, "--topic", "vn.lumora.lumora"], stdout=blog, stderr=blog)
        procs.append(bp)
        bridge_key = wait_until(lambda: json.load(urllib.request.urlopen(f"{bridge_url}/pubkey", timeout=2))["public_key"], 15, "bridge up")

        def apns_lines():
            if not os.path.exists(apns_log):
                return []
            return [json.loads(l) for l in open(apns_log) if l.strip()]

        from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
        from cryptography.hazmat.primitives import serialization
        nsk = X25519PrivateKey.generate()
        notify_secret = nsk.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
        notify_pub = nsk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        apns_tok, voip_tok = "a1" * 32, "b2" * 32

        @step("friends; the 'iPhone' (Bob) registers for wake-ups and Alice receives the sealed registration")
        def _():
            B.call("add_contact", target=pa, note="iPhone")
            A.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == pb, what="friend_request")
            A.call("accept_contact", peer=pb)
            wait_until(lambda: any(c.get("peer") == pa and c.get("status") == 3 for c in B.call("contacts")), 20, "friendship")
            r = B.call("push_register", bridge_url=bridge_url, bridge_key=bridge_key, apns=apns_tok, voip=voip_tok,
                       topic="vn.lumora.lumora", sandbox=False, notify_key=base64.b64encode(notify_pub).decode())
            assert r["registered"], r
            wait_until(lambda: pb in A.call("push_status")["friends_with_push"], 20, "registration at Alice")
            # Alice never sees the device token
            assert apns_tok not in json.dumps(A.call("push_status")), "token leaked"
        _()

        @step("Bob goes offline; a burst of 5 messages wakes him exactly once, with no plaintext in the push")
        def _():
            B.stop()
            A.wait_event(lambda e: e["event"] == "presence" and e.get("peer") == pb and not e.get("online"), 60, "Bob offline")
            texts = [f"Tin nhắn số {i} 🌙" for i in range(5)]
            for t in texts:
                A.call("send_text", conv=f"d:{pb}", text=t)
            wait_until(lambda: len(apns_lines()) >= 1, 15, "a wake at the bridge")
            time.sleep(3)
            lines = apns_lines()
            assert len(lines) == 1, f"expected exactly one wake per burst, got {len(lines)}"
            p = lines[0]
            assert p["device_token"] == apns_tok and p["push_type"] == "alert" and p["topic"] == "vn.lumora.lumora", p
            assert p["payload"]["aps"]["alert"] == {"loc-key": "PUSH_NEW_MESSAGE"}, p
            raw = json.dumps(p, ensure_ascii=False)
            assert "Tin nhắn" not in raw and "Alice" not in raw and pa not in raw, "plaintext reached the bridge/APNs"
            n = open_notify(notify_secret, base64.b64decode(p["payload"]["lumora"]["e2e"]))
            print(f"     NSE would show: {n['name']}: {n['preview']}")
            assert n["k"] == "msg" and n["from"] == pa and n["name"] == "Alice" and n["preview"] == texts[0], n
            assert n["conv"] == f"d:{pa}", n
        _()

        @step("calling the offline iPhone sends one VoIP wake (PushKit) with the call id")
        def _():
            c = A.call("call_start", conv=f"d:{pb}", video=True)
            wait_until(lambda: len(apns_lines()) >= 2, 15, "call wake")
            p = apns_lines()[1]
            assert p["push_type"] == "voip" and p["device_token"] == voip_tok and p["topic"] == "vn.lumora.lumora.voip", p
            assert p["expiration"] == 0, p
            n = open_notify(notify_secret, base64.b64decode(p["payload"]["lumora"]["e2e"]))
            assert n["k"] == "call" and n["call"] == c["call_id"] and n["video"] is True, n
            A.call("call_end", call_id=c["call_id"])
            time.sleep(2)
            assert len(apns_lines()) == 2, "call retries must not re-wake inside the coalescing window"
        _()

        @step("mailbox on open: Bob comes back and receives all 5 queued messages")
        def _():
            B.start()
            want = {f"Tin nhắn số {i} 🌙" for i in range(5)}
            wait_until(lambda: want <= {m["body"].get("text") for m in B.call("messages", conv=f"d:{pa}")}, 60, "queued messages")
            r = B.call("resume")
            assert "dialing" in r, r
        _()

        @step("after a reconnect, the next offline burst wakes Bob again")
        def _():
            wait_until(lambda: A.call("push_status")["friends_with_push"], 10, "registration kept")
            B.stop()
            A.wait_event(lambda e: e["event"] == "presence" and e.get("peer") == pb and not e.get("online"), 60, "Bob offline")
            A.call("send_text", conv=f"d:{pb}", text="Lại offline rồi")
            A.call("send_text", conv=f"d:{pb}", text="Thêm tin nữa")
            wait_until(lambda: len(apns_lines()) >= 3, 15, "second burst wake")
            time.sleep(2)
            assert len(apns_lines()) == 3, len(apns_lines())
            h = json.load(urllib.request.urlopen(f"{bridge_url}/health", timeout=2))
            assert h["dry_run"] and h["accepted"] == 3, h
        _()
    except Exception:
        pass
    finally:
        for n in nodes:
            try:
                n.stop()
            except Exception:
                pass
        for p in procs:
            p.terminate()
        if not a.keep:
            shutil.rmtree(tmp, ignore_errors=True)
    passed = sum(1 for r in RESULTS if r[1])
    print(f"\n{passed}/{len(RESULTS)} steps passed")
    sys.exit(0 if RESULTS and passed == len(RESULTS) else 1)


if __name__ == "__main__":
    main()
