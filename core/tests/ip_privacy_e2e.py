#!/usr/bin/env python3
"""IP privacy end-to-end test (scenario `ip_privacy`): strangers never learn my addresses.

    python3 core/tests/ip_privacy_e2e.py [--bin core/target/debug/lumorad] [--relay-bin core/target/debug/lumora-relay]

Real `lumorad` nodes (debug build: it honours LUMORA_TEST_EXTRA_ADDRS) with no LAN discovery
and no Nostr; a local relay server is the only signaling channel. Each "stranger" node
advertises an extra candidate address 127.0.0.1:<port> that is a UDP listener owned by this
script, so any packet the victim sends toward the stranger's addresses (punch probes, QUIC
dials, spraying) is counted here — no root, no packet capture.

Scenarios:
  * a stranger who knows only my ID sends an offer: the answer has no addresses, not one
    packet reaches the stranger's addresses, no contact row is created; the connection (if
    any) runs through the relay only;
  * the stranger's friend request still arrives; until I accept, still no packet; after
    I accept, we connect directly (positive control: the listener now sees packets);
  * a friend request sent while I'm offline arrives by mail when I come back;
  * remote-control probing by a stranger: a wrong password reveals nothing; the correct
    password, and only then, lets the viewer connect;
  * the LAN announcement carries no public key (only today's hint, magic LMRH);
  * (#3) a link invitation on screen doesn't open my addresses to every stranger;
  * (#4) members of a group I left are strangers again (private group: positive control
    before leaving);
  * (#1) a stranger's device list is not kept (nothing stored until I accept them; then
    their linked device shows up, proven by its own acceptance signature);
  * (#2) `resume` doesn't dial a pending requester I queued something for;
  * (#14) a relay only a stranger uses is never adopted, offered or advertised.
(The DHT record — only a friends-only one, under a key derived from the friends-only key —
is covered by Rust unit tests: `net::discovery::privacy_tests`.)
"""
import argparse, base64, os, shutil, socket, struct, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e import Node, wait_until, step, RESULTS  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Listener:
    """UDP socket standing in for a stranger's advertised address: counts what arrives."""

    def __init__(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.settimeout(0.2)
        self.port = self.sock.getsockname()[1]
        self.packets = []
        self.stop = False
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        while not self.stop:
            try:
                d, a = self.sock.recvfrom(4096)
                self.packets.append((time.time(), a, len(d)))
            except socket.timeout:
                pass
            except OSError:
                return

    def count(self):
        return len(self.packets)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def try_call(node, cmd, **kw):
    try:
        return node.call(cmd, **kw)
    except RuntimeError as e:
        return {"error": str(e)}


def settle(listener, quiet=3.0, limit=30):
    """Wait until no packet has reached `listener` for `quiet` seconds (stray retransmits of
    earlier dials end); returns the count then."""
    end = time.time() + limit
    while time.time() < end:
        last = listener.packets[-1][0] if listener.packets else 0
        if time.time() - last >= quiet:
            break
        time.sleep(0.3)
    return listener.count()


def log_lines(node, needle):
    with open(os.path.join(node.data, "node.log"), errors="replace") as f:
        return [l for l in f if needle in l]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, "target", "debug", "lumorad"))
    ap.add_argument("--relay-bin", default=os.path.join(ROOT, "target", "debug", "lumora-relay"))
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="lumora-ipp-")
    os.environ["E2E_TMP"] = tmp
    os.environ.setdefault("RUST_LOG", "info,mainline=warn")
    rport, sport = free_port(), free_port()
    relay_log = open(os.path.join(tmp, "relay.log"), "w")
    relay = subprocess.Popen([a.relay_bin, "--listen", f"127.0.0.1:{rport}", "--stun-port", str(sport), "--stun-bind", "127.0.0.1"],
                             stdout=relay_log, stderr=relay_log)
    url = f"ws://127.0.0.1:{rport}/ws"
    # no LAN, no Nostr, no public STUN: the relay is the only way to reach anyone
    extra = ["--no-nostr", "--no-lan", "--stun", f"127.0.0.1:{sport}", "--relay", url, "--relay-delay", "1500"]

    def start(name, listener=None, more=()):
        d = os.path.join(tmp, name)
        os.makedirs(d, exist_ok=True)
        old = os.environ.get("LUMORA_TEST_EXTRA_ADDRS")
        if listener:
            os.environ["LUMORA_TEST_EXTRA_ADDRS"] = f"127.0.0.1:{listener.port}"
        try:
            return Node(name, a.bin, d, extra + ["--downloads", os.path.join(d, "dl")] + list(more))
        finally:
            if old is None:
                os.environ.pop("LUMORA_TEST_EXTRA_ADDRS", None)
            else:
                os.environ["LUMORA_TEST_EXTRA_ADDRS"] = old

    print(f"data: {tmp}")
    LS, LS2 = Listener(), Listener()
    V = start("Victim")
    S = start("Stranger", LS)
    S2 = start("Prober", LS2)
    nodes = [V, S, S2]
    ctx_m = {}
    extra_relays = []
    ok = True
    try:
        pv, ps, ps2 = V.me["peer"], S.me["peer"], S2.me["peer"]
        print(f"victim {V.me['short_id']}  stranger {S.me['short_id']}  prober {S2.me['short_id']}")
        for n in nodes:
            wait_until(lambda n=n: all(r["connected"] for r in n.call("net_status")["relays"]), 20, f"{n.name} on the relay")

        @step("stranger's offer: no addresses in the answer, no packet toward the stranger, no contact row, relay-only")
        def _():
            r = S.call("connect", peer=pv, timeout=50)
            print(f"     path={r['path']} addr={r.get('remote_addr')}")
            assert r["path"] == "relay", r
            time.sleep(3)
            assert LS.count() == 0, f"{LS.count()} packets reached the stranger's address"
            answers = log_lines(S, "answer ")
            assert answers and all(" 0 addresses" in l for l in answers), answers
            assert not any(c["peer"] == ps for c in V.call("contacts")), "silent contact row for a stranger"
            st = [p for p in V.call("net_status")["peers"] if p["peer"] == ps]
            assert st and st[0]["remote_addr"] == "relay", st
            # a relayed stranger is never "upgraded" to a direct path
            try:
                S.call("upgrade", peer=pv, timeout=40)
            except RuntimeError:
                pass
            time.sleep(2)
            assert LS.count() == 0, "upgrade attempt reached the stranger"
        _()

        @step("the stranger's friend request arrives; nothing reaches them until I accept; then we connect directly")
        def _():
            S.call("add_contact", target=pv, note="Chào bạn, mình là người lạ")
            e = V.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == ps, 30, "friend_request")
            assert e["note"].startswith("Chào bạn"), e
            time.sleep(3)
            assert LS.count() == 0, "packets toward a pending requester"
            V.call("accept_contact", peer=ps)
            wait_until(lambda: any(c["peer"] == pv and c["status"] == 3 for c in S.call("contacts")), 30, "friends")
            # positive control: friends connect directly, so the victim now punches/dials the
            # stranger's advertised addresses (our listener sees it)
            wait_until(lambda: LS.count() > 0 or V.call("upgrade", peer=ps, timeout=45) and LS.count() > 0, 60, "victim reaches the new friend directly")
            print(f"     after accepting: {LS.count()} packets toward the new friend's address (expected)")
        _()

        @step("a friend request sent while I'm offline arrives by mail when I come back")
        def _():
            V.stop()
            T = start("Late")
            nodes.append(T)
            wait_until(lambda: all(r["connected"] for r in T.call("net_status")["relays"]), 20, "relay")
            T.call("add_contact", target=pv, note="gửi lúc bạn vắng")
            time.sleep(15)  # one dial attempt fails (victim offline) → sealed mail to the relay mailbox
            V.start()
            e = V.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == T.me["peer"], 60, "offline friend_request")
            assert e["note"] == "gửi lúc bạn vắng", e
        _()

        @step("remote control probing by a stranger: wrong password reveals nothing; the right one lets the viewer in")
        def _():
            wait_until(lambda: all(r["connected"] for r in V.call("net_status")["relays"]), 20, "victim back on the relay")
            r = S2.call("remote_connect", target=pv, password="doan-bua", view_only=True)
            e = S2.wait_event(lambda e: e["event"] == "remote_state" and e.get("session") == r["session"] and e["state"] in ("denied", "failed"), 40, "denied")
            assert e["state"] == "denied" and e.get("code") == "err.wrong_password", e
            time.sleep(3)
            assert LS2.count() == 0, f"{LS2.count()} packets reached the prober"
            assert not any(p["peer"] == ps2 for p in V.call("net_status")["peers"]), "the prober got a connection"
            assert not any(" from " in l and "addresses" in l and " 0 addresses" not in l for l in log_lines(S2, "answer ")), "an answer with addresses"
            temp = V.call("remote_status")["password"]
            r = S2.call("remote_connect", target=pv, password=temp, view_only=True)
            e = V.wait_event(lambda e: e["event"] == "remote_request" and e.get("session") == r["session"], 60, "request after the right password")
            V.call("remote_respond", session=e["session"], accept=True, control=False)
            S2.wait_event(lambda e: e["event"] == "remote_state" and e.get("session") == r["session"] and e["state"] == "active", 40, "active")
            S2.call("remote_end", session=r["session"])
        _()

        @step("#3 a link invitation on screen doesn't reveal my addresses to a stranger")
        def _():
            LX = Listener()
            X = start("Gawker", LX)
            nodes.append(X)
            wait_until(lambda: all(r["connected"] for r in X.call("net_status")["relays"]), 20, "relay")
            V.call("link_invite")
            try:
                r = X.call("connect", peer=pv, timeout=50)
                assert r["path"] == "relay", r
            except RuntimeError:
                pass  # (no relay-only answer is fine too)
            time.sleep(3)
            assert LX.count() == 0, f"{LX.count()} packets toward a stranger while a link code is shown"
            answers = log_lines(X, "answer ")
            assert all(" 0 addresses" in l for l in answers), answers
            V.call("link_cancel")
            LX.stop = True
        _()

        @step("#4 members of a group I left learn nothing (before leaving: they do)")
        def _():
            LG = Listener()
            G = start("GroupMate", LG)
            nodes.append(G)
            wait_until(lambda: all(r["connected"] for r in G.call("net_status")["relays"]), 20, "relay")
            pg = G.me["peer"]
            # a private group made by S (a friend of both), so G and I are co-members, not friends
            S.call("add_contact", target=pg, note="hi")
            G.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == ps, 40, "friend_request")
            G.call("accept_contact", peer=ps)
            wait_until(lambda: any(c["peer"] == pg and c["status"] == 3 for c in S.call("contacts")), 40, "S and G friends")
            g = S.call("create_group", name="Nhóm riêng", members=[pv, pg])
            wait_until(lambda: any(c["id"] == g["conv"] for c in V.call("conversations")), 60, "group arrives (me)")
            wait_until(lambda: any(c["id"] == g["conv"] for c in G.call("conversations")), 60, "group arrives (G)")
            assert not any(c["peer"] == pg and c["status"] == 3 for c in V.call("contacts")), "G is not my friend"
            # positive control: a co-member of a private group may connect directly
            wait_until(lambda: LG.count() > 0 or (try_call(G, "upgrade", peer=pv, timeout=45) is not None and LG.count() > 0), 90, "direct path between co-members")
            V.call("group_leave", gid=g["gid"])
            time.sleep(2)
            before = settle(LG)
            seen = len(log_lines(G, "answer "))
            # its next offer (upgrade / repair) gets no address and no packet from me
            try_call(G, "upgrade", peer=pv, timeout=45)
            time.sleep(4)
            assert LG.count() == before, f"{LG.count() - before} packets toward a member of a group I left"
            answers = log_lines(G, "answer ")[seen:]
            assert all(" 0 addresses" in l for l in answers), answers
            LG.stop = True
        _()

        @step("#1 a stranger's device list is not kept; once a friend, their proven linked device shows up")
        def _():
            LM = Listener()
            M = start("Mallory", LM)
            nodes.append(M)
            wait_until(lambda: all(r["connected"] for r in M.call("net_status")["relays"]), 20, "relay")
            # Mallory links a second device (QR invitation, loopback addresses in the QR)
            inv = M.call("link_invite")
            M1 = start("Mallory-2", more=["--link-pending"])
            nodes.append(M1)
            M1.call("link_scan", name="Mallory-2", qr=inv["qr"], timeout=60)
            ev = M.wait_event(lambda e: e["event"] == "link_request", 30, "link_request")
            M.call("link_approve", device=ev["device"], history="none")
            M1.wait_event(lambda e: e["event"] == "link_state" and e["state"] == "restart", 20, "restart")
            wait_until(lambda: M1.call("me")["account"] == M.me["peer"], 40, "linked")
            M1.extra = [x for x in M1.extra if x != "--link-pending"]
            pm = M.me["peer"]
            # Mallory asks me (I'm "someone she asked": she shares her list with me)
            M.call("add_contact", target=pv, note="xin chào")
            V.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == pm, 40, "friend_request")
            try:
                M.call("connect", peer=pv, timeout=50)
            except RuntimeError:
                pass
            time.sleep(5)
            devs = V.call("contact_devices", peer=pm)
            assert devs == [], f"a stranger's device list was kept: {devs}"
            # positive control: friends → her list (with the linked device's acceptance) is kept
            V.call("accept_contact", peer=pm)
            wait_until(lambda: len(V.call("contact_devices", peer=pm)) == 2, 60, "friend's two devices")
            ctx_m["M"] = M
        _()

        @step("#2 resume() doesn't dial a pending requester I queued something for")
        def _():
            LR = Listener()
            R = start("Requester", LR)
            nodes.append(R)
            wait_until(lambda: all(r["connected"] for r in R.call("net_status")["relays"]), 20, "relay")
            R.call("add_contact", target=pv, note="hi")
            V.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == R.me["peer"], 40, "friend_request")
            try:
                V.call("send_text", conv=f"d:{R.me['peer']}", text="trả lời trước khi đồng ý")
            except RuntimeError as e:
                print(f"     (send to a pending requester refused: {e}; queue empty)")
            before = LR.count()
            V.call("resume")
            time.sleep(6)
            assert LR.count() == before, f"{LR.count() - before} packets toward a pending requester after resume()"
            LR.stop = True
        _()

        @step("#14 a relay only a stranger uses is never adopted, offered or advertised by me")
        def _():
            rport2, sport2 = free_port(), free_port()
            relay2 = subprocess.Popen([a.relay_bin, "--listen", f"127.0.0.1:{rport2}", "--stun-port", str(sport2), "--stun-bind", "127.0.0.1"],
                                      stdout=relay_log, stderr=relay_log)
            extra_relays.append(relay2)
            url2 = f"ws://127.0.0.1:{rport2}/ws"
            LH = Listener()
            H = start("Hinter", LH, more=["--relay", url2])
            nodes.append(H)
            wait_until(lambda: sum(1 for r in H.call("net_status")["relays"] if r["connected"]) >= 2, 20, "both relays")
            try:
                H.call("connect", peer=pv, timeout=50)
            except RuntimeError:
                pass
            time.sleep(3)
            mine = [r["url"] for r in V.call("net_status")["relays"]]
            assert url2 not in mine, f"adopted a stranger's relay: {mine}"
            answers = log_lines(H, "answer ")
            assert answers and all(" 0 addresses, 1 relays" in l for l in answers), answers
            assert LH.count() == 0
            LH.stop = True
        _()

        @step("LAN announcement: no public key in clear, only today's hint (LMRH)")
        def _():
            ms = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
            ms.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if hasattr(socket, "SO_REUSEPORT"):
                ms.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            ms.bind(("", 47777))
            ms.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, struct.pack("4sl", socket.inet_aton("239.255.76.77"), socket.INADDR_ANY))
            ms.settimeout(0.5)
            port = free_port()
            os.makedirs(os.path.join(tmp, "lan"), exist_ok=True)
            W = Node("LanNode", a.bin, os.path.join(tmp, "lan"), ["--no-nostr", "--no-mdns", "--port", str(port)])
            nodes.append(W)
            key = base64.b32decode(W.me["peer"].upper() + "=" * (-len(W.me["peer"]) % 8))
            hints, leaks = [], []
            end = time.time() + 12
            while time.time() < end:
                try:
                    d, _src = ms.recvfrom(4096)
                except socket.timeout:
                    continue
                if key in d:
                    leaks.append(d[:4])
                if d[:4] == b"LMRH":
                    hints.append(d)  # (other test nodes on this machine may announce too)
            ms.close()
            assert not leaks, f"public key sent in clear on the LAN: {leaks[:3]}"
            assert hints, "no LMRH announcement heard"
        _()
    except Exception:
        ok = False
    finally:
        for n in nodes:
            n.stop()
        LS.stop = LS2.stop = True
        for rl in [relay] + extra_relays:
            rl.terminate()
            try:
                rl.wait(timeout=5)
            except Exception:
                rl.kill()
    passed = sum(1 for r in RESULTS if r[1])
    print(f"\n{passed}/{len(RESULTS)} scenarios passed")
    if not a.keep and ok:
        shutil.rmtree(tmp, ignore_errors=True)
    sys.exit(0 if ok and passed == len(RESULTS) else 1)


if __name__ == "__main__":
    main()
