#!/usr/bin/env python3
"""Multi-user stability test: N real nodes in one group, everyone sends, everyone must receive all.

    python3 core/tests/scale.py [--n 12] [--per 5]
    python3 core/tests/scale.py --idle-devices 3 [--idle-s 60]   # multi-device idle budget

`--idle-devices N`: an account on N linked devices with two friends sits idle; its RAM and
CPU are compared with the same account on a single device (budget: main device within
+25% CPU, every device's RSS within +25%).
"""
import argparse, os, sys, tempfile, time, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e import Node, wait_until

def rss_mb(pid):
    try:
        for l in open(f"/proc/{pid}/status"):
            if l.startswith("VmRSS"):
                return int(l.split()[1]) / 1024
    except Exception:
        return 0
    return 0

def cpu_s(pid):
    try:
        f = open(f"/proc/{pid}/stat").read().split()
        return (int(f[13]) + int(f[14])) / os.sysconf("SC_CLK_TCK")
    except Exception:
        return 0

def idle_budget(a):
    """Idle cost of an account on N devices vs one device."""
    tmp = tempfile.mkdtemp(prefix="lumora-idle-")
    nodes = []

    def mk(name, more=()):
        d = os.path.join(tmp, name)
        os.makedirs(d)
        n = Node(name, a.bin, d, ["--no-nostr"] + list(more))
        nodes.append(n)
        return n

    def befriend(x, y):
        x.call("add_contact", target=y.me["peer"])
        y.wait_event(lambda e: e["event"] == "friend_request", 30, "request")
        y.call("accept_contact", peer=x.me["peer"])
        wait_until(lambda: any(c["peer"] == y.me["peer"] and c["status"] == 3 for c in x.call("contacts")), 30, "friends")

    def measure(ns, secs):
        c0 = [cpu_s(n.p.pid) for n in ns]
        time.sleep(secs)
        c1 = [cpu_s(n.p.pid) for n in ns]
        return [(c1[i] - c0[i]) / secs * 100 for i in range(len(ns))], [rss_mb(n.p.pid) for n in ns]

    try:
        # baseline: one device + two friends
        A, F1, F2 = mk("solo"), mk("f1"), mk("f2")
        befriend(F1, A)
        befriend(F2, A)
        time.sleep(10)
        cpu1, rss1 = measure([A], a.idle_s)
        for n in list(nodes):
            n.stop()
        nodes.clear()
        # the same with N devices
        A0, G1, G2 = mk("main"), mk("g1"), mk("g2")
        befriend(G1, A0)
        befriend(G2, A0)
        devs = [A0]
        for i in range(a.idle_devices - 1):
            N = mk(f"dev{i + 1}", ["--link-pending"])
            inv = A0.call("link_invite")
            N.call("link_scan", qr=inv["qr"], timeout=60)
            ev = A0.wait_event(lambda e: e["event"] == "link_request", 30, "link_request")
            A0.call("link_approve", device=ev["device"], history="none")
            wait_until(lambda: N.call("me")["account"] == A0.me["peer"], 60, "linked")
            wait_until(lambda: N.call("history_status")["done"], 60, "bootstrap")
            devs.append(N)
        time.sleep(10)
        cpuN, rssN = measure(devs, a.idle_s)
        print(f"idle {a.idle_s}s, 1 device: CPU {cpu1[0]:.2f}%  RSS {rss1[0]:.0f} MB")
        for i, n in enumerate(devs):
            print(f"idle {a.idle_s}s, {a.idle_devices} devices, {n.name}: CPU {cpuN[i]:.2f}%  RSS {rssN[i]:.0f} MB")
        out = sum(n.call("storage_stats")["outbox"] for n in devs)
        print(f"outbox items left: {out}")
        main_cpu_ok = cpuN[0] <= max(cpu1[0] * 1.25, cpu1[0] + 0.5)
        rss_ok = all(r <= rss1[0] * 1.25 + 5 for r in rssN)
        print("RESULT:", "PASS" if main_cpu_ok and rss_ok and out == 0 else "FAIL")
    finally:
        for n in nodes:
            n.stop()
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=12)
    ap.add_argument("--per", type=int, default=5)
    ap.add_argument("--idle-devices", type=int, default=0, help="measure idle cost of an account on N devices")
    ap.add_argument("--idle-s", type=int, default=60)
    ap.add_argument("--bin", default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "target", "debug", "lumorad"))
    a = ap.parse_args()
    if a.idle_devices:
        return idle_budget(a)
    tmp = tempfile.mkdtemp(prefix="lumora-scale-")
    nodes = []
    try:
        for i in range(a.n):
            d = os.path.join(tmp, f"n{i}")
            os.makedirs(d)
            nodes.append(Node(f"User{i:02d}", a.bin, d, ["--no-nostr"]))
        owner = nodes[0]
        po = owner.me["peer"]
        t0 = time.time()
        for n in nodes[1:]:
            n.call("add_contact", target=po)
        def all_requests():
            reqs = {c["peer"] for c in owner.call("contacts") if c["status"] == 2}
            return len(reqs) >= a.n - 1 and reqs
        reqs = wait_until(all_requests, 60, "friend requests")
        for p in reqs:
            owner.call("accept_contact", peer=p)
        g = owner.call("create_group", name="Nhóm tải 🚀", members=list(reqs))
        conv = g["conv"]
        wait_until(lambda: all(any(x["gid"] == g["gid"] for x in n.call("groups")) for n in nodes), 90, "everyone joined")
        print(f"setup: {a.n} nodes joined in {time.time() - t0:.1f}s")
        sent = set()
        t1 = time.time()
        for r in range(a.per):
            for n in nodes:
                m = n.call("send_text", conv=conv, text=f"{n.name} #{r}")
                sent.add(m["id"])
        def everyone():
            missing = 0
            for n in nodes:
                ids = {x["id"] for x in n.call("messages", conv=conv, limit=500)}
                missing += len(sent - ids)
            return missing == 0 or (print(f"  … {missing} deliveries pending") and False)
        wait_until(everyone, 120, "all messages everywhere")
        dt = time.time() - t1
        total = len(sent) * a.n
        print(f"delivered {len(sent)} msgs × {a.n} nodes = {total} deliveries in {dt:.1f}s")
        rss = [rss_mb(n.p.pid) for n in nodes]
        cpu = [cpu_s(n.p.pid) for n in nodes]
        print(f"RSS per node: avg {sum(rss)/len(rss):.0f} MB, max {max(rss):.0f} MB")
        print(f"CPU per node: avg {sum(cpu)/len(cpu):.1f}s, max {max(cpu):.1f}s (whole run)")
        out = sum(n.call("storage_stats")["outbox"] for n in nodes)
        print(f"outbox items left: {out}")
        print("RESULT: PASS")
    except Exception as e:
        print("RESULT: FAIL", e)
    finally:
        for n in nodes:
            n.stop()
        shutil.rmtree(tmp, ignore_errors=True)

if __name__ == "__main__":
    main()
