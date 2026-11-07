#!/usr/bin/env python3
"""Mixed-version end-to-end test: the previous release's `lumorad` next to the new one.

    python3 core/tests/mixed_version_e2e.py --old <lumorad of the previous release> [--bin core/target/debug/lumorad]

Build the old binary from its tag, e.g.:
    git worktree add /tmp/old v1.0.7 && (cd /tmp/old/core && CARGO_TARGET_DIR=/tmp/t-old cargo build -p lumora-cli)

Nodes: Ann (old), Dan (old), Ben (new), Cat (new), all friends with each other.
Covers: 1-1 chat both ways old↔new, file transfer both ways, a 1-1 call rings both ways;
an OLD-rules group created by the old app (members of both versions): rename by a plain
member, the owner leaves → every node agrees on owner / name / members, messages still
flow both ways after the key rotation; a group created by the new app (Community 2.0
rules) refuses the old member with the "update the app" error; a group call with a ring
list rings the old member (and a new member not on the list only gets the banner).
"""
import argparse, base64, hashlib, os, shutil, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e import Node, wait_until, step, RESULTS, ROOT  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, "target", "debug", "lumorad"), help="new lumorad")
    ap.add_argument("--old", required=True, help="lumorad of the previous release")
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="lumora-e2e-mixed-")
    os.environ["E2E_TMP"] = tmp
    os.environ.setdefault("LUMORA_TEST_CAMERA", "1")
    extra = ["--no-nostr"]
    spec = [("Ann", a.old), ("Dan", a.old), ("Ben", a.bin), ("Cat", a.bin)]
    nodes = {}
    print(f"data: {tmp}")
    for name, binary in spec:
        d = os.path.join(tmp, name.lower())
        os.makedirs(d)
        nodes[name] = Node(name, binary, d, extra + ["--downloads", os.path.join(d, "dl")])
    A, D, B, C = nodes["Ann"], nodes["Dan"], nodes["Ben"], nodes["Cat"]
    ALL = [A, B, C, D]
    P = {n.name: n.me["peer"] for n in ALL}
    ok = True

    def msgs(n, conv):
        return n.call("messages", conv=conv, limit=500)

    def got_text(n, conv, text):
        return any((x.get("body") or {}).get("text") == text for x in msgs(n, conv))

    try:
        @step("everyone befriends everyone (old ↔ new, old ↔ old, new ↔ new)")
        def _():
            for i, x in enumerate(ALL):
                for y in ALL[i + 1:]:
                    x.call("add_contact", target=P[y.name])
                    y.wait_event(lambda e, x=x: e["event"] == "friend_request" and e["peer"] == P[x.name], 30, what=f"request {x.name}→{y.name}")
                    y.call("accept_contact", peer=P[x.name])
                    wait_until(lambda x=x, y=y: any(c["peer"] == P[y.name] and c["status"] == 3 for c in x.call("contacts")), 20, f"{x.name}↔{y.name} friends")
                    wait_until(lambda x=x, y=y: any(c["peer"] == P[x.name] and c["status"] == 3 for c in y.call("contacts")), 20, f"{y.name}↔{x.name} friends")
        _()

        @step("1-1 chat both ways old ↔ new (delivery + read receipts)")
        def _():
            for s, r in ((A, B), (B, A), (D, C), (C, D)):
                text = f"{s.name} → {r.name}: chào bạn ✅ {time.time():.3f}"
                m = s.call("send_text", conv=f"d:{P[r.name]}", text=text)
                r.wait_event(lambda e, m=m: e["event"] == "message" and e.get("id") == m["id"], 30, what=f"{s.name}→{r.name} message")
                wait_until(lambda s=s, r=r, m=m: [x for x in msgs(s, f"d:{P[r.name]}") if x["id"] == m["id"]][0]["status"] >= 2, 20, f"{s.name}: delivered")
                r.call("mark_read", conv=f"d:{P[s.name]}")
                wait_until(lambda s=s, r=r, m=m: [x for x in msgs(s, f"d:{P[r.name]}") if x["id"] == m["id"]][0]["status"] == 3, 20, f"{s.name}: read")
        _()

        @step("file transfer both ways old ↔ new (2 MB, hash verified)")
        def _():
            for s, r in ((A, B), (C, D)):
                src = os.path.join(s.data, f"tep-{s.name}.bin")
                with open(src, "wb") as f:
                    f.write(os.urandom(2 * 1024 * 1024))
                h = hashlib.sha256(open(src, "rb").read()).hexdigest()
                fid = s.call("send_file", conv=f"d:{P[r.name]}", path=src)["id"]

                def done(r=r, fid=fid):
                    fs = [x for x in r.call("files") if x["id"] == fid]
                    return fs and fs[0]["state"] == 2 and fs[0]
                fr = wait_until(done, 60, f"{s.name}→{r.name} file")
                assert hashlib.sha256(open(fr["path"], "rb").read()).hexdigest() == h, "hash mismatch"
        _()

        @step("1-1 call rings both ways old ↔ new; hang-up reaches the callee")
        def _():
            for s, r in ((B, A), (A, B)):
                c = s.call("call_start", conv=f"d:{P[r.name]}", video=False)
                r.wait_event(lambda e, c=c: e["event"] == "call" and e.get("call_id") == c["call_id"] and e.get("state") == "incoming", 20, what=f"{r.name} rings")
                s.call("call_end", call_id=c["call_id"])
                r.wait_event(lambda e, c=c: e["event"] == "call" and e.get("call_id") == c["call_id"] and e.get("state") == "ended", 20, what=f"{r.name}: ended")
        _()

        state = {}

        def view(n, gid):
            g = n.call("group_info", gid=gid)
            return (g["name"], g["owner"], tuple(sorted((m["peer"], m["role"]) for m in g["members"])))

        def agree(gid, members, what, cond=lambda v: True):
            def same():
                vs = {n.name: view(n, gid) for n in members}
                return len(set(vs.values())) == 1 and cond(list(vs.values())[0]) and vs
            try:
                return wait_until(same, 40, what)
            except TimeoutError:
                for n in members:
                    print(f"     {n.name}: {view(n, gid)}")
                raise

        @step("old-rules group made by the old app: members of both versions join, chat both ways")
        def _():
            g = A.call("create_group", name="Nhóm cũ", members=[P["Ben"], P["Cat"], P["Dan"]])
            state["gid"], state["conv"] = g["gid"], g["conv"]
            for n in (B, C, D):
                wait_until(lambda n=n: any(x["gid"] == g["gid"] for x in n.call("groups")), 40, f"{n.name} in the group")
            assert B.call("group_info", gid=g["gid"])["rules_v2"] is False, "an old group switched rules"
            agree(g["gid"], ALL, "same group view", cond=lambda v: len(v[2]) == 4)
            for s in (A, B):
                text = f"{s.name}: chào cả nhóm"
                s.call("send_text", conv=g["conv"], text=text)
                for n in ALL:
                    if n is not s:
                        wait_until(lambda n=n, text=text: got_text(n, g["conv"], text), 30, f"{n.name} got {s.name}'s post")
        _()

        @step("old group: rename by a plain member → everyone agrees (new app: admins only, as the old app's UI)")
        def _():
            gid = state["gid"]
            # the new app offers "change group info" to admins (as the old app's UI did)
            try:
                B.call("group_rename", gid=gid, name="Đổi bởi Ben")
                raise AssertionError("plain member renamed from the new app")
            except RuntimeError as e:
                assert "admin_only" in str(e), e
            # the old app's API lets a plain member rename (old rules allow it): all agree
            D.call("group_rename", gid=gid, name="Đổi bởi Dan")
            vs = agree(gid, ALL, "rename by Dan", cond=lambda v: v[0] == "Đổi bởi Dan")
            assert list(vs.values())[0][0] == "Đổi bởi Dan", vs
        _()

        @step("old group: the (old-app) owner leaves → same new owner / name / members everywhere")
        def _():
            gid = state["gid"]
            A.call("group_leave", gid=gid)
            rest = [B, C, D]
            vs = agree(gid, rest, "same view after the owner left", cond=lambda v: P["Ann"] not in [m for m, _ in v[2]])
            name, owner, members = list(vs.values())[0]
            assert owner != P["Ann"] and owner in P.values(), vs
            assert P["Ann"] not in [m for m, _ in members], vs
            assert {m for m, _ in members} == {P["Ben"], P["Cat"], P["Dan"]}, vs
            assert name == "Đổi bởi Dan", vs
            print(f"     new owner: {[k for k, v in P.items() if v == owner][0]}")
            # messages still flow both ways after the rotation
            for s in (D, C):
                text = f"{s.name}: sau khi chủ nhóm rời"
                s.call("send_text", conv=state["conv"], text=text)
                for n in rest:
                    if n is not s:
                        wait_until(lambda n=n, text=text: got_text(n, state["conv"], text), 40, f"{n.name} got {s.name}'s post")
            assert B.call("group_info", gid=gid)["rules_v2"] is False
        _()

        @step("Community 2.0 group (made by the new app) refuses the old member: update-app error")
        def _():
            g = B.call("create_group", name="Nhóm mới", members=[P["Cat"]])
            assert B.call("group_info", gid=g["gid"])["rules_v2"] is True
            try:
                B.call("group_add", gid=g["gid"], peer=P["Dan"])
                raise AssertionError("an old app was added to a Community 2.0 group")
            except RuntimeError as e:
                assert "group_peer_outdated" in str(e), e
            try:
                B.call("create_group", name="Nhóm mới 2", members=[P["Cat"], P["Ann"]])
                raise AssertionError("a Community 2.0 group was made with an old app")
            except RuntimeError as e:
                assert "group_peer_outdated" in str(e), e
            time.sleep(1)
            assert not any(x["gid"] == g["gid"] for x in D.call("groups")), "the old app got the new group"
            assert all(m["peer"] != P["Dan"] for m in B.call("group_info", gid=g["gid"])["members"])
        _()

        @step("group call with a ring list rings the old member; a new member off the list gets the banner")
        def _():
            conv = state["conv"]
            cid = B.call("call_start", conv=conv, ring=[P["Dan"]])["call_id"]
            D.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "incoming", 20, what="Dan (old) rung")
            C.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "available", 20, what="Cat: banner")
            try:
                C.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "incoming", 2, what="no ring")
                raise AssertionError("the banner member was rung")
            except TimeoutError:
                pass
            D.call("call_answer", call_id=cid, accept=False)
            B.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "ended", 20, what="ends once Dan declined")
            D.wait_event(lambda e: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "ended", 20, what="Dan: ended")
            # rung by the old app (it rings everyone): both new members ring
            cid = D.call("call_start", conv=conv)["call_id"]
            for n in (B, C):
                n.wait_event(lambda e, n=n: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "incoming", 20, what=f"{n.name} rung by the old app")
            D.call("call_end", call_id=cid)
            for n in (B, C):
                n.wait_event(lambda e, n=n: e["event"] == "call" and e.get("call_id") == cid and e.get("state") == "ended", 20, what=f"{n.name}: ended")
        _()

        @step("old group handed to a new-app owner: info edits reach the old app; a cover or delete-for-everyone the old app can't read is refused")
        def _():
            g = A.call("create_group", name="Nhóm cũ 2", members=[P["Ben"], P["Dan"]])
            gid, conv = g["gid"], g["conv"]
            for n in (B, D):
                wait_until(lambda n=n: any(x["gid"] == gid for x in n.call("groups")), 40, f"{n.name} in group 2")
            A.call("group_set_role", gid=gid, peer=P["Ben"], role="admin")
            agree(gid, [A, B, D], "Ben admin everywhere", cond=lambda v: (P["Ben"], "admin") in v[2])
            A.call("group_leave", gid=gid)
            vs = agree(gid, [B, D], "same view after the owner left", cond=lambda v: P["Ann"] not in [m for m, _ in v[2]])
            assert list(vs.values())[0][1] == P["Ben"], f"the admin should succeed: {vs}"
            B.call("group_meta", gid=gid, description="mô tả mới")
            wait_until(lambda: D.call("group_info", gid=gid)["description"] == "mô tả mới", 30, "description reaches the old app")
            jpg = base64.b64encode(b"\xff\xd8\xff" + os.urandom(2000)).decode()
            for what, fn in (("cover", lambda: B.call("group_meta", gid=gid, cover=jpg)),
                             ("dissolve", lambda: B.call("group_dissolve", gid=gid))):
                try:
                    fn()
                    raise AssertionError(f"{what}: an op the old member can't read was published")
                except RuntimeError as e:
                    assert "group_peer_outdated" in str(e), e
            agree(gid, [B, D], "still the same group on both")
            assert not D.call("group_info", gid=gid).get("dissolved")
            text = "vẫn chung một nhóm"
            B.call("send_text", conv=conv, text=text)
            wait_until(lambda: got_text(D, conv, text), 30, "old app still gets posts")
        _()

        @step("outboxes drain on both versions")
        def _():
            wait_until(lambda: sum(n.call("storage_stats")["outbox"] for n in ALL) == 0, 40, "all outboxes empty")
        _()
    except Exception:
        ok = False
    finally:
        for n in ALL:
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
