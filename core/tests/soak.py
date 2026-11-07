#!/usr/bin/env python3
"""Limits + long-use soak test: what happens after weeks of heavy chatting?

    python3 core/tests/soak.py [--msgs 20000] [--file-mb 300] [--group 4]

1. Limits: empty / 64 KB / oversize text, oversize avatar, empty file, big file
   (integrity + speed), media cache cap enforced by maintenance.
2. Soak: friends and a group chat non-stop. RAM, CPU, database size and pending
   deliveries are sampled; RAM must plateau (no leak), every message must arrive,
   and the bytes stored per message tell how the disk grows over months.
"""
import argparse, hashlib, os, shutil, sys, tempfile, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e import Node, wait_until
from scale import rss_mb, cpu_s

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
results = []


def check(name, cond, info=""):
    results.append((name, bool(cond)))
    print(f"  {'✅' if cond else '❌'} {name} {info}")


def expect_error(fn):
    try:
        fn()
        return None
    except RuntimeError as e:
        return str(e)


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def befriend(a, b):
    b.call("add_contact", target=a.me["peer"])
    a.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == b.me["peer"], what="request")
    a.call("accept_contact", peer=b.me["peer"])
    wait_until(lambda: any(c["peer"] == a.me["peer"] and c["status"] == 3 for c in b.call("contacts")), 20, "friends")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--msgs", type=int, default=20000, help="total messages in the soak phase")
    ap.add_argument("--file-mb", type=int, default=300)
    ap.add_argument("--group", type=int, default=4)
    ap.add_argument("--bin", default=os.path.join(ROOT, "target", "debug", "lumorad"))
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="lumora-soak-")
    nodes = []
    try:
        for i in range(max(2, a.group)):
            d = os.path.join(tmp, f"n{i}")
            os.makedirs(d)
            nodes.append(Node(f"Người {i}", a.bin, d, ["--no-nostr", "--downloads", os.path.join(d, "dl")]))
        A, B = nodes[0], nodes[1]
        for n in nodes[1:]:
            befriend(A, n)
        dm = f"d:{B.me['peer']}"
        dm_b = f"d:{A.me['peer']}"

        print("== limits")
        check("empty message rejected", expect_error(lambda: A.call("send_text", conv=dm, text="   ")))
        m = A.call("send_text", conv=dm, text="ả" * (64 * 1024 // 3))
        wait_until(lambda: any(x["id"] == m["id"] for x in B.call("messages", conv=dm_b, limit=5)), 20, "64 KB text")
        check("64 KB message delivered", True)
        err = expect_error(lambda: A.call("send_text", conv=dm, text="x" * (64 * 1024 + 1)))
        check("message over 64 KB rejected", err, f"→ {err}")
        import base64
        err = expect_error(lambda: A.call("set_profile", avatar=base64.b64encode(b"\xff\xd8" + os.urandom(200_000)).decode()))
        check("oversize avatar rejected", err, f"→ {err}")
        empty = os.path.join(tmp, "rong.txt")
        open(empty, "wb").close()
        err = expect_error(lambda: A.call("send_file", conv=dm, path=empty))
        if not err:
            wait_until(lambda: any(x["name"] == "rong.txt" and x["state"] == 2 for x in B.call("files")), 20, "empty file")
        check("empty file handled", True, f"({'rejected: ' + err if err else 'delivered'})")

        print(f"== big file {a.file_mb} MB")
        src = os.path.join(tmp, "video-lon.mp4")
        with open(src, "wb") as f:
            for _ in range(a.file_mb):
                f.write(os.urandom(1 << 20))
        want = sha(src)
        B.call("set_storage_policy", auto_download={"wifi": {"video": 8 << 30}})
        r0 = max(rss_mb(A.p.pid), 1), max(rss_mb(B.p.pid), 1)
        t0 = time.time()
        fm = A.call("send_file", conv=dm, path=src, timeout=120)
        peak = [0, 0]

        def done():
            peak[0] = max(peak[0], rss_mb(A.p.pid))
            peak[1] = max(peak[1], rss_mb(B.p.pid))
            xs = [x for x in B.call("files") if x["id"] == fm["id"] and x["state"] == 2]
            return xs and xs[0]
        got = wait_until(done, 600, "big file")
        dt = time.time() - t0
        check("big file arrives intact", sha(got["path"]) == want, f"{a.file_mb / dt:.0f} MB/s, {dt:.1f}s")
        check("RAM stays flat while sending a big file", peak[0] - r0[0] < 150 and peak[1] - r0[1] < 150,
              f"sender +{peak[0] - r0[0]:.0f} MB, receiver +{peak[1] - r0[1]:.0f} MB")
        os.remove(src)

        print("== media cache cap")
        B.call("set_storage_policy", max_cache=64 << 20)
        before = B.call("storage_stats")["media_bytes"]
        B.call("maintain", timeout=120)
        after = B.call("storage_stats")["media_bytes"]
        check("old media trimmed to the cache cap", after <= 64 << 20, f"{before >> 20} MB → {after >> 20} MB")
        B.call("set_storage_policy", max_cache=5 << 30)

        print(f"== soak: {a.msgs} messages (DM + group of {len(nodes)})")
        g = A.call("create_group", name="Nhóm chat liên tục", members=[n.me["peer"] for n in nodes[1:]])
        wait_until(lambda: all(any(x["gid"] == g["gid"] for x in n.call("groups")) for n in nodes), 60, "group")
        # a throughput soak, not a flood test: members sending this fast would (rightly) hit
        # the per-member group rate limit (60/min for non-admins), so everyone is an admin
        for n in nodes[1:]:
            A.call("group_set_role", gid=g["gid"], peer=n.me["peer"], role="admin")
        for n in nodes[1:]:
            wait_until(lambda n=n: all(m.get("role") in ("admin", "owner") for m in n.call("group_info", gid=g["gid"])["members"]), 60, "admins everywhere")
        convs = [(A, dm), (B, dm_b)] + [(n, g["conv"]) for n in nodes]
        db0 = sum(n.call("storage_stats")["db_bytes"] for n in nodes)
        samples, stop = [], threading.Event()

        def sampler():
            while not stop.is_set():
                samples.append((time.time(), [rss_mb(n.p.pid) for n in nodes], [cpu_s(n.p.pid) for n in nodes]))
                stop.wait(2)
        threading.Thread(target=sampler, daemon=True).start()
        t0 = time.time()
        last_ids = {}
        for i in range(a.msgs):
            n, conv = convs[i % len(convs)]
            m = n.call("send_text", conv=conv, text=f"Tin số {i} — chúc cả nhà một ngày vui vẻ 🌞 " + "lorem ipsum " * (i % 8))
            last_ids[(n.name, conv)] = m["id"]
            if i % 2000 == 0 and i:
                print(f"   … {i} sent, {i / (time.time() - t0):.0f} msg/s, RAM {[int(x) for x in samples[-1][1]]} MB")
        send_dt = time.time() - t0

        def all_arrived():
            # the last message of every sender reached everyone in that chat
            ok = True
            for (name, conv), mid in last_ids.items():
                if conv == g["conv"]:
                    targets = [(x, conv) for x in nodes if x.name != name]
                elif conv == dm:
                    targets = [(B, dm_b)]
                else:
                    targets = [(A, dm)]
                for x, c in targets:
                    if not any(m["id"] == mid for m in x.call("messages", conv=c, limit=50)):
                        ok = False
                        missing.add(f"{name}→{x.name} {'group' if conv == g['conv'] else 'dm'}")
            return ok
        missing = set()
        try:
            wait_until(lambda: (missing.clear(), all_arrived())[1], 300, "every message delivered")
        except TimeoutError:
            print("   missing:", sorted(missing))
            for n in nodes:
                st = n.call("storage_stats")
                print(f"   {n.name}: outbox={st['outbox']} messages={st['messages']}")
            raise
        total_dt = time.time() - t0
        wait_until(lambda: sum(n.call("storage_stats")["outbox"] for n in nodes) == 0, 120, "outboxes drained")
        stop.set()
        check("every message delivered, nothing left pending", True,
              f"send {a.msgs / send_dt:.0f} msg/s, all delivered after {total_dt:.0f}s")

        # RAM plateau: compare the 2nd quarter with the last quarter of the run
        q = max(1, len(samples) // 4)
        mid = [sum(s[1]) / len(nodes) for s in samples[q:2 * q]] or [0]
        end = [sum(s[1]) / len(nodes) for s in samples[-q:]] or [0]
        m1, m2 = sum(mid) / len(mid), sum(end) / len(end)
        check("RAM plateaus (no leak)", m2 < m1 * 1.25 + 10, f"avg per device {m1:.0f} MB → {m2:.0f} MB, max {max(max(s[1]) for s in samples):.0f} MB")
        cpu = [samples[-1][2][i] - samples[0][2][i] for i in range(len(nodes))]
        check("CPU per device reasonable", max(cpu) / max(total_dt, 1) < 0.9,
              f"avg {sum(cpu) / len(cpu) / max(total_dt, 1) * 100:.0f}% of one core during non-stop chat")
        for n in nodes:
            n.call("maintain", timeout=120)
        db1 = sum(n.call("storage_stats")["db_bytes"] for n in nodes)
        per_msg = (db1 - db0) / (a.msgs * len(nodes))
        check("storage per message small", per_msg < 2048, f"≈{per_msg:.0f} bytes/message/device "
              f"→ 1,000 msgs/day for a year ≈ {per_msg * 365_000 / 1e6:.0f} MB")

        print("== restart after heavy use")
        t = time.time()
        B.stop()
        B.start()
        n = len(B.call("messages", conv=dm_b, limit=100))
        check("restart fast with a big history", time.time() - t < 10 and n > 0, f"{time.time() - t:.1f}s")
    except Exception as e:
        import traceback
        traceback.print_exc()
        results.append(("run", False))
    finally:
        for n in nodes:
            n.stop()
        shutil.rmtree(tmp, ignore_errors=True)
    bad = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(bad)}/{len(results)} checks passed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
