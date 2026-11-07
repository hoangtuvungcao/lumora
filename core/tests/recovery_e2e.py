#!/usr/bin/env python3
"""Recovery from friends after a restore with the recovery phrase (node/recovery.rs).

    python3 core/tests/recovery_e2e.py [--bin core/target-md/debug/lumorad]

Alice has 1-1 history with Bob and Carol and a group with both. Her device is lost; she
restores the account from her 24 words on a fresh node. Bob (setting on) offers his chat
with her and the group; Carol (setting off) sends nothing. Alice reviews the offers and
accepts Bob's: the last 6 months of their 1-1 chat come back (never the deleted, the
disappearing or the 7-month-old message), Bob is a friend again, and the group comes back
with its history through the normal group sync. Built on e2e.py's restore-with-phrase step.
"""
import argparse, os, shutil, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e import Node, wait_until, step, RESULTS, ROOT  # noqa: E402


def texts(n, conv):
    return [m.get("body", {}).get("text") for m in n.all_messages(conv)]


def befriend(x, y):
    x.call("connect", peer=y.me["peer"], timeout=40)
    x.call("add_contact", target=y.me["peer"])
    y.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == x.me["peer"], what="friend_request")
    y.call("accept_contact", peer=x.me["peer"])
    wait_until(lambda: any(c["peer"] == y.me["peer"] and c["status"] == 3 for c in x.call("contacts")), 20, "friends")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, "target-md", "debug", "lumorad"))
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="lumora-recovery-")
    os.environ["E2E_TMP"] = tmp
    extra = ["--no-nostr"]
    dirs = {n: os.path.join(tmp, n) for n in ["alice", "bob", "carol", "alice-restored"]}
    for d in dirs.values():
        os.makedirs(d)
    A = Node("Alice", a.bin, dirs["alice"], extra)
    B = Node("Bob", a.bin, dirs["bob"], extra)
    C = Node("Carol", a.bin, dirs["carol"], extra)
    nodes = [A, B, C]
    pa, pb, pc = A.me["peer"], B.me["peer"], C.me["peer"]
    ab, ac = f"d:{pb}", f"d:{pa}"
    st = {}
    ok = True
    try:
        @step("setup: Alice friends with Bob and Carol, 1-1 history, a group that rotated its key")
        def _():
            befriend(B, A)
            befriend(C, A)
            # 7 months ago (outside the 6-month window)
            B.call("debug_backdate_next", ago_ms=210 * 86_400_000)
            B.call("send_text", conv=ac, text="tin 7 tháng trước")
            st["a1"] = A.call("send_text", conv=ab, text="Alice: chào Bình")["id"]
            st["b1"] = B.call("send_text", conv=ac, text="Bob: chào Alice 👋")["id"]
            gone = B.call("send_text", conv=ac, text="Bob: tin sẽ bị xoá")
            B.call("send_text", conv=ac, text="Bob: tự huỷ", ttl_ms=3_600_000)
            wait_until(lambda: len(A.all_messages(ab)) >= 5, 30, "Alice has the chat")
            B.call("delete_message", conv=ac, msg_id=gone["id"], for_everyone=True)
            wait_until(lambda: any(m["id"] == gone["id"] and m.get("deleted") for m in A.all_messages(ab)), 30, "deleted for both")
            # Alice also edits her message: the edited text comes back (unsigned copy)
            st["a2"] = A.call("send_text", conv=ab, text="Alice: tin cuối")["id"]
            wait_until(lambda: any(m["id"] == st["a2"] for m in B.all_messages(ac)), 30, "Bob got Alice's last message")
            C.call("send_text", conv=f"d:{pa}", text="Carol: bí mật của Carol")
            g = A.call("create_group", name="Nhóm Khôi Phục", members=[pb, pc])
            st["gid"], st["gconv"] = g["gid"], g["conv"]
            wait_until(lambda: any(x["gid"] == st["gid"] for x in B.call("groups")), 20, "Bob joined")
            wait_until(lambda: any(x["gid"] == st["gid"] for x in C.call("groups")), 20, "Carol joined")
            st["g1"] = A.call("send_text", conv=st["gconv"], text="nhóm: trước khi đổi khoá")["id"]
            wait_until(lambda: any(m["id"] == st["g1"] for m in B.call("messages", conv=st["gconv"])), 20, "g1 at Bob")
            A.call("group_remove", gid=st["gid"], peer=pc)
            wait_until(lambda: B.call("group_info", gid=st["gid"])["epoch"] >= 1, 20, "Bob has the new key")
            st["g2"] = B.call("send_text", conv=st["gconv"], text="nhóm: sau khi đổi khoá")["id"]
            wait_until(lambda: any(m["id"] == st["g2"] for m in A.call("messages", conv=st["gconv"])), 20, "g2 at Alice")
            # Carol keeps her friends' history to herself
            C.call("settings_set", help_restore=False)
            assert C.call("settings_get")["help_restore"] is False
            assert B.call("settings_get")["help_restore"] is True, "on by default"
        _()

        @step("restore on a fresh device from the 24 words: friends offer help, Carol (setting off) sends nothing")
        def _():
            phrase = A.call("recovery_phrase")["phrase"]
            A.stop()
            nodes.remove(A)
            N = Node("AliceMoi", a.bin, dirs["alice-restored"], extra + ["--restore-phrase", phrase, "--port", "0"])
            nodes.append(N)
            st["N"] = N
            assert N.me["peer"] == pa
            assert N.call("recovery_offers")["recovering"] is True
            assert N.call("contacts") == [] or all(c["status"] != 3 for c in N.call("contacts")), "restored with nothing"
            B.call("connect", peer=pa, timeout=40)
            C.call("connect", peer=pa, timeout=40)
            e = N.wait_event(lambda e: e["event"] == "recovery" and any(o["peer"] == pb for o in e["offers"]), 30, "Bob's offer")
            o = next(o for o in e["offers"] if o["peer"] == pb)
            assert o["state"] == "offered" and o["name"] == "Bob", o
            assert o["messages"] == 3, f"a1, b1, a2 only (not deleted / timed / 7 months old): {o}"
            assert o["groups"] == [st["gid"]], o
            assert o["verified"] is True, "Bob kept a message Alice signed"
            time.sleep(3)
            offers = N.call("recovery_offers")["offers"]
            assert not any(x["peer"] == pc for x in offers), f"Carol's setting is off: {offers}"
            assert not N.all_messages(ab), "nothing stored before the user accepts"
        _()

        @step("accept Bob's offer: 6 months of 1-1 history back, never deleted / disappearing / older; Bob a friend again")
        def _():
            N = st["N"]
            N.call("recovery_accept", peer=pb)
            wait_until(lambda: next(o for o in N.call("recovery_offers")["offers"] if o["peer"] == pb)["state"] == "done", 30, "transfer done")
            ms = N.all_messages(ab)
            ids = [m["id"] for m in ms]
            want = [m["id"] for m in B.all_messages(ac) if m["id"] in (st["a1"], st["b1"], st["a2"])]
            assert ids == want and len(ids) == 3, f"exactly the live messages, in Bob's order: {texts(N, ab)}"
            t = texts(N, ab)
            assert "Bob: tin sẽ bị xoá" not in t and "Bob: tự huỷ" not in t and "tin 7 tháng trước" not in t, t
            assert {m["id"]: m["author"] for m in ms} == {st["a1"]: pa, st["b1"]: pb, st["a2"]: pa}
            assert any(c["peer"] == pb and c["status"] == 3 for c in N.call("contacts")), "Bob is a friend again"
            assert not N.all_messages(f"d:{pc}"), "Carol sent nothing"
            # not signed by me → labelled with who gave it back; my own signed ones are not
            meta = {m["id"]: (m.get("meta") or {}) for m in ms}
            assert meta[st["b1"]].get("restored_from") == "Bob" and meta[st["b1"]].get("restored_peer") == pb, meta
            assert not meta[st["a1"]].get("restored_from") and not meta[st["a2"]].get("restored_from"), f"my signed messages carry no label: {meta}"
            # a new message works both ways after recovery
            m = B.call("send_text", conv=ac, text="Bob: mừng bạn trở lại")
            wait_until(lambda: any(x["id"] == m["id"] for x in N.all_messages(ab)), 30, "live chat after recovery")
        _()

        @step("group catch-up: welcomed back, history before and after the key change arrives via group sync")
        def _():
            N = st["N"]
            wait_until(lambda: any(x["gid"] == st["gid"] for x in N.call("groups")), 30, "group back")
            try:
                wait_until(lambda: {st["g1"], st["g2"]} <= {m["id"] for m in N.call("messages", conv=st["gconv"])}, 60, "group history")
            except TimeoutError:
                print("     restored group:", [(m.get("kind"), m.get("body")) for m in N.call("messages", conv=st["gconv"])], N.call("group_info", gid=st["gid"]).get("epoch"))
                raise
            codes = [m["body"].get("code") for m in N.call("messages", conv=st["gconv"]) if m.get("kind") == "system"]
            assert "sys.group_restored" in codes and "sys.you_added" not in codes, f"neutral notice, nobody 'added' me: {codes}"
            m = N.call("send_text", conv=st["gconv"], text="Alice: mình về rồi")
            wait_until(lambda: any(x["id"] == m["id"] for x in B.call("messages", conv=st["gconv"])), 30, "Alice posts again")
        _()

        @step("a stranger who connects gets nothing; \"stop asking friends\" ends recovery")
        def _():
            N = st["N"]
            # a stranger (Dan) connects: no offer, nothing sent its way
            nd = os.path.join(tmp, "dan")
            os.makedirs(nd)
            D = Node("Dan", a.bin, nd, extra)
            nodes.append(D)
            D.call("connect", peer=pa, timeout=40)
            time.sleep(3)
            assert not any(o["peer"] == D.me["peer"] for o in N.call("recovery_offers")["offers"])
            # the restore hello only goes to peers that proved the friendship (Ext DHT_KEY)
            log = open(os.path.join(dirs["alice-restored"], "node.log"), errors="replace").read()
            assert f"recovery: hello to {pb}" in log, "Bob was never asked"
            assert f"recovery: hello to {D.me['peer']}" not in log, "a stranger learned that Alice is recovering"
            N.call("recovery_dismiss")
            assert N.call("recovery_offers")["recovering"] is False
        _()
    except Exception as e:  # noqa: BLE001
        ok = False
        print(f"FAILED: {e}")
    finally:
        for n in nodes:
            n.stop()
        if not a.keep and ok:
            shutil.rmtree(tmp, ignore_errors=True)
        else:
            print(f"kept: {tmp}")
    passed = sum(1 for r in RESULTS if r[1])
    print(f"\n{passed}/{len(RESULTS)} steps passed")
    sys.exit(0 if ok and passed == len(RESULTS) else 1)


if __name__ == "__main__":
    main()
