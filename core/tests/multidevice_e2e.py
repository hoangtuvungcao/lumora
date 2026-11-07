#!/usr/bin/env python3
"""Multi-device end-to-end test: one account on several devices (docs/src/dev/multi-device.md).

    python3 core/tests/multidevice_e2e.py [--bin core/target/debug/lumorad] [--only base|matrix]

The sync matrix (`run_matrix`, runs first) drives one account on three devices (M0 main,
M1 + M2 linked, later M3) and friends F, G (+ H, S): every synced data type is changed on
one device and checked on all the others within a few seconds — live, with a device
offline / restarted meanwhile, under races (same item changed on two devices at once,
messages arriving while a device links) — plus search (Vietnamese with / without
diacritics) and finding people by 9-digit ID, @username and invite link from each device.

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
import argparse, base64, json, os, shutil, struct, sys, tempfile, threading, time, hashlib, zlib

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


# ---------------------------------------------------------------------------------------
# Sync matrix: one account on three devices (M0 main, M1 + M2 linked) and two friends (F, G).
# Every data type is changed on one device and must reach every other device within a few
# seconds — live, with a device offline (and restarted) meanwhile, and under races.
# ---------------------------------------------------------------------------------------

SYNC_S = 12  # convergence budget per device (the sibling sync runs every second)


def _png(path, w=24, h=24, rgb=(200, 80, 40)):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    return path


def run_matrix(tmp, start, link, befriend):
    """Returns True when every matrix scenario passed (each one is reported on its own)."""
    nodes = []
    ok = [True]

    only = os.environ.get("MATRIX_ONLY")  # debug: run setup + scenarios whose name has this text

    def scenario(name):
        def deco(fn):
            if only and only not in name and not name.startswith("setup"):
                return lambda: None
            try:
                step("matrix: " + name)(fn)()
            except Exception:
                ok[0] = False
            return lambda: None  # (already ran)
        return deco

    def everywhere(devs, pred, what, t=SYNC_S):
        for d in devs:
            wait_until(lambda d=d: pred(d), t, f"{d.name}: {what}")

    def msg(n, conv, mid):
        return next((m for m in msgs(n, conv) if m["id"] == mid), None)

    def contact(n, peer):
        return next((c for c in n.call("contacts") if c["peer"] == peer), None)

    def group_of(n, gid):
        return next((g for g in n.call("groups") if g["gid"] == gid), None)

    def in_group(n, gid):
        try:
            return n.call("group_info", gid=gid)["my_role"] != "none"
        except RuntimeError:
            return False

    def devnames(n):
        return {d["device"]: d["name"] for d in n.call("devices")["devices"]}

    def running(*ns):
        """(after a failed scenario left a device stopped)"""
        for n in ns:
            if n.p.poll() is not None or n.p.stdin.closed:
                n.start()

    ctx = {}
    try:
        M0 = start("M0")
        F = start("F")
        G = start("G")
        nodes += [M0, F, G]
        pm, pf, pg = M0.me["peer"], F.me["peer"], G.me["peer"]
        dF, dG, dM = f"d:{pf}", f"d:{pg}", f"d:{pm}"

        @scenario("setup: M0 + friends F, G; M1 and M2 linked (3 devices)")
        def _():
            befriend(F, M0)
            befriend(G, M0)
            befriend(F, G)
            F.call("set_username", username="ban_f")
            # (in "Saved messages": the chats with F and G get cleared / deleted further on)
            ctx["viet"] = M0.call("send_text", conv="s:me", text="Tiếng Việt có dấu: chúc mừng năm mới")["id"]
            m = F.call("send_text", conv=dM, text="trước khi liên kết")
            M0.wait_event(lambda e: e["event"] == "message" and e["id"] == m["id"], 15, "pre-link msg")
            for nm in ("M1", "M2"):
                N = link(M0, nm, "qr", history="all")
                nodes.append(N)
                ctx[nm] = N
                wait_until(lambda N=N: N.call("history_status")["done"], 60, f"{nm} history")
            for n in (M0, ctx["M1"], ctx["M2"]):
                wait_until(lambda n=n: len(n.call("devices")["devices"]) == 3, 20, f"{n.name} lists 3 devices")
            wait_until(lambda: len(F.call("contact_devices", peer=pm)) == 3, 20, "F learns 3 devices")
        _()
        M1, M2 = ctx["M1"], ctx["M2"]
        A = [M0, M1, M2]

        # ------------------------------------------------------------ messages
        @scenario("1-1: sent from a linked device → friend + every sibling; friend's reply → all")
        def _():
            m = M1.call("send_text", conv=dF, text="xin chào từ M1")
            F.wait_event(lambda e: e["event"] == "message" and e["id"] == m["id"], 15, "F got it")
            everywhere(A, lambda n: (msg(n, dF, m["id"]) or {}).get("mine") is True, "M1's message, mine")
            r = F.call("send_text", conv=dM, text="trả lời cho M")
            everywhere(A, lambda n: msg(n, dF, r["id"]) is not None, "F's reply")
            ctx["r"] = r["id"]
        _()

        @scenario("group: created on M2 → M0, M1 members; messages both ways reach every device")
        def _():
            g = M2.call("create_group", name="Nhóm ma trận", members=[pf, pg])
            ctx["g"] = g
            everywhere(A + [F, G], lambda n: in_group(n, g["gid"]), "in the group")
            gm = G.call("send_text", conv=g["conv"], text="G chào nhóm")
            everywhere(A + [F], lambda n: msg(n, g["conv"], gm["id"]) is not None, "G's group message")
            mm = M0.call("send_text", conv=g["conv"], text="M0 chào nhóm")
            everywhere([M1, M2, F, G], lambda n: msg(n, g["conv"], mm["id"]) is not None, "M0's group message")
            ctx["gm"] = mm["id"]
        _()

        @scenario("edit: M0 edits, then M2 edits the same message again → every device + friend")
        def _():
            e = M0.call("send_text", conv=dF, text="bản gốc")
            everywhere(A[1:] + [F], lambda n: msg(n, dF if n is not F else dM, e["id"]) is not None, "original")
            M0.call("edit_message", conv=dF, msg_id=e["id"], text="đã sửa")
            everywhere(A[1:] + [F], lambda n: (msg(n, dF if n is not F else dM, e["id"]) or {}).get("body", {}).get("text") == "đã sửa", "edit 1")
            M2.call("edit_message", conv=dF, msg_id=e["id"], text="sửa lần hai")
            everywhere(A + [F], lambda n: (msg(n, dF if n is not F else dM, e["id"]) or {}).get("body", {}).get("text") == "sửa lần hai", "edit 2")
            # group edit too
            M1.call("edit_message", conv=ctx["g"]["conv"], msg_id=ctx["gm"], text="M0 chào nhóm (sửa)")
            everywhere(A + [F, G], lambda n: (msg(n, ctx["g"]["conv"], ctx["gm"]) or {}).get("body", {}).get("text") == "M0 chào nhóm (sửa)", "group edit")
        _()

        @scenario("delete for everyone (M2) and delete for me (M0) → every device")
        def _():
            d = M1.call("send_text", conv=dF, text="xoá cho mọi người")
            everywhere(A, lambda n: msg(n, dF, d["id"]) is not None, "msg")
            F.wait_event(lambda e: e["event"] == "message" and e["id"] == d["id"], 15, "F got it")
            M2.call("delete_message", conv=dF, msg_id=d["id"], for_everyone=True)
            gone = lambda n, c: (msg(n, c, d["id"]) is None) or msg(n, c, d["id"])["deleted"]
            everywhere(A, lambda n: gone(n, dF), "deleted for everyone")
            wait_until(lambda: gone(F, dM), SYNC_S, "F: deleted for everyone")
            x = F.call("send_text", conv=dM, text="xoá cho tôi")
            everywhere(A, lambda n: msg(n, dF, x["id"]) is not None, "msg")
            M0.call("delete_message", conv=dF, msg_id=x["id"], for_everyone=False)
            everywhere(A, lambda n: msg(n, dF, x["id"]) is None, "deleted for me")
            time.sleep(1)
            assert msg(F, dM, x["id"]) is not None, "delete-for-me reached the friend"
        _()

        @scenario("reactions: add on M1, remove on M2 → every device + friend")
        def _():
            rid = ctx["r"]
            M1.call("react", conv=dF, msg_id=rid, emoji="❤️", on=True)
            has = lambda n, c: "❤️" in ((msg(n, c, rid) or {}).get("reactions") or {})
            everywhere(A, lambda n: has(n, dF), "reaction")
            wait_until(lambda: has(F, dM), SYNC_S, "F sees the reaction")
            M2.call("react", conv=dF, msg_id=rid, emoji="❤️", on=False)
            everywhere(A, lambda n: not has(n, dF), "reaction removed")
            wait_until(lambda: not has(F, dM), SYNC_S, "F: reaction removed")
        _()

        @scenario("read state + unread counts: read on M2 → 0 unread on M0, M1; friend sees 'read'")
        def _():
            ids = [F.call("send_text", conv=dM, text=f"chưa đọc {i}")["id"] for i in range(2)]
            everywhere(A, lambda n: all(msg(n, dF, i) for i in ids) and conv_row(n, dF)["unread"] >= 2, "2 unread")
            M2.call("mark_read", conv=dF)
            everywhere(A, lambda n: conv_row(n, dF)["unread"] == 0, "unread cleared")
            wait_until(lambda: all((msg(F, dM, i) or {}).get("status") == 3 for i in ids), SYNC_S, "F sees read")
        _()

        @scenario("pins: message pin (M0) and chat pin / unpin (M1 / M2) → every device")
        def _():
            rid = ctx["r"]
            M0.call("pin_message", conv=dF, msg_id=rid, on=True)
            everywhere(A, lambda n: (msg(n, dF, rid) or {}).get("pinned") is True, "message pinned")
            M1.call("conv_flag", conv=dF, flag="pinned", value=True)
            everywhere(A, lambda n: conv_row(n, dF)["pinned"] is True, "chat pinned")
            M2.call("conv_flag", conv=dF, flag="pinned", value=False)
            everywhere(A, lambda n: conv_row(n, dF)["pinned"] is False, "chat unpinned")
        _()

        @scenario("archive (M2) and mute / unmute (M1 / M0) → every device")
        def _():
            M2.call("conv_flag", conv=dG, flag="archived", value=True)
            everywhere(A, lambda n: conv_row(n, dG)["archived"] is True, "archived")
            M2.call("conv_flag", conv=dG, flag="archived", value=False)
            everywhere(A, lambda n: conv_row(n, dG)["archived"] is False, "unarchived")
            M1.call("mute", conv=dF, until=now_ms() + 3_600_000)
            everywhere(A, lambda n: conv_row(n, dF)["muted"] is True, "muted")
            M0.call("mute", conv=dF, until=0)
            everywhere(A, lambda n: conv_row(n, dF)["muted"] is False, "unmuted")
        _()

        @scenario("retention (M0 sets 7 days, M1 back to forever) → every device")
        def _():
            M0.call("set_retention", conv=dG, mode="7d")
            everywhere(A, lambda n: n.call("get_retention", conv=dG)["mode"] == "7d", "7d")
            M1.call("set_retention", conv=dG, mode="forever")
            everywhere(A, lambda n: n.call("get_retention", conv=dG)["mode"] == "forever", "forever")
        _()

        @scenario("profile: name, bio, avatar (M1), cover (M2), username (M2) → every device + friend")
        def _():
            av = base64.b64encode(b"\x89PNG-avatar-matrix" * 20).decode()
            cv = base64.b64encode(b"\x89PNG-cover-matrix" * 40).decode()
            M1.call("set_profile", name="Mai Ma Trận", bio="tiểu sử mới", avatar=av)
            everywhere(A, lambda n: (lambda p: p["name"] == "Mai Ma Trận" and p["bio"] == "tiểu sử mới" and p["avatar"] == av)(n.call("profile")), "profile")
            everywhere(A, lambda n: n.call("me")["name"] == "Mai Ma Trận", "me.name")
            M2.call("set_cover", cover=cv)
            everywhere(A, lambda n: n.call("profile")["cover"] == cv, "cover")
            M2.call("set_username", username="mai_matran")
            everywhere(A, lambda n: n.call("profile")["username"] == "mai_matran", "username")
            wait_until(lambda: (contact(F, pm) or {}).get("name") == "Mai Ma Trận", SYNC_S, "F sees the new name")
            wait_until(lambda: F.call("contact_avatar", peer=pm)["avatar"] == av, SYNC_S, "F sees the avatar")
            wait_until(lambda: F.call("contact_cover", peer=pm)["cover"] == cv, SYNC_S, "F sees the cover")
            wait_until(lambda: any(r["peer"] == pm for r in F.call("resolve_username", handle="@mai_matran")), SYNC_S, "F finds @mai_matran")
        _()

        @scenario("contacts: request accepted on M1, nickname (M2), remove (M0), add (M0), block / unblock → every device")
        def _():
            H = start("H")
            nodes.append(H)
            ph = H.me["peer"]
            ctx["H"] = H
            H.call("connect", peer=pm, timeout=40)
            H.call("add_contact", target=pm, note="cho mình kết bạn")
            everywhere(A, lambda n: (contact(n, ph) or {}).get("status") == 2, "incoming request")
            M1.call("accept_contact", peer=ph)
            everywhere(A, lambda n: (contact(n, ph) or {}).get("status") == 3, "friends")
            wait_until(lambda: (contact(H, pm) or {}).get("status") == 3, SYNC_S, "H: friends")
            everywhere(A, lambda n: conv_row(n, f"d:{ph}") is not None, "direct chat")
            M2.call("rename_contact", peer=ph, alias="Bạn H")
            everywhere(A, lambda n: (contact(n, ph) or {}).get("alias") == "Bạn H", "nickname")
            M0.call("remove_contact", peer=ph)
            everywhere(A, lambda n: (contact(n, ph) or {}).get("status", 0) == 0, "removed")
            M0.call("add_contact", target=ph, note="kết bạn lại")
            everywhere(A, lambda n: (contact(n, ph) or {}).get("status") == 1, "request sent")
            H.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == pm, 20, "H gets the request")
            H.call("accept_contact", peer=pm)
            everywhere(A, lambda n: (contact(n, ph) or {}).get("status") == 3, "friends again")
            M1.call("block_contact", peer=ph)
            everywhere(A, lambda n: (contact(n, ph) or {}).get("status") == 4, "blocked")
            M2.call("unblock_contact", peer=ph)
            everywhere(A, lambda n: (contact(n, ph) or {}).get("status", 0) == 0, "unblocked")
        _()

        @scenario("groups: join by link (M1), roles + settings + rename (M0/M1/M2), member changes, leave (M2) → every device")
        def _():
            g = ctx["g"]
            gid = g["gid"]
            M0.call("group_set_role", gid=gid, peer=pf, role="admin")
            role = lambda n: next((m["role"] for m in n.call("group_info", gid=gid)["members"] if m["peer"] == pf), None)
            everywhere(A + [F, G], lambda n: role(n) == "admin", "F is admin")
            M1.call("group_settings", gid=gid, admins_only=True)
            everywhere(A + [F, G], lambda n: n.call("group_info", gid=gid)["admins_only"] is True, "admins only")
            M2.call("group_rename", gid=gid, name="Nhóm ma trận 2")
            everywhere(A + [F, G], lambda n: n.call("group_info", gid=gid)["name"] == "Nhóm ma trận 2", "renamed")
            everywhere(A, lambda n: (conv_row(n, g["conv"]) or {}).get("title") == "Nhóm ma trận 2", "chat title")
            M0.call("group_remove", gid=gid, peer=pg)
            everywhere(A + [F], lambda n: all(m["peer"] != pg for m in n.call("group_info", gid=gid)["members"]), "G removed")
            M1.call("group_add", gid=gid, peer=pg)
            everywhere(A + [F, G], lambda n: any(m["peer"] == pg for m in n.call("group_info", gid=gid)["members"]), "G back")
            # someone else's group, joined by link on a linked device
            gx = G.call("create_group", name="Nhóm của G", members=[pf])
            link_ = G.call("create_invite", gid=gx["gid"])["link"]
            M1.call("join_invite", link=link_)
            everywhere(A, lambda n: in_group(n, gx["gid"]), "joined by link")
            everywhere(A, lambda n: conv_row(n, gx["conv"]) is not None, "chat of the joined group")
            wait_until(lambda: any(m["peer"] == pm for m in G.call("group_info", gid=gx["gid"])["members"]), SYNC_S, "G sees M")
            mx = G.call("send_text", conv=gx["conv"], text="chào thành viên mới")
            everywhere(A, lambda n: msg(n, gx["conv"], mx["id"]) is not None, "message in the joined group")
            M2.call("group_leave", gid=gx["gid"])
            everywhere(A, lambda n: not in_group(n, gx["gid"]), "left")
            wait_until(lambda: all(m["peer"] != pm for m in G.call("group_info", gid=gx["gid"])["members"]), SYNC_S, "G sees M left")
        _()

        @scenario("community: cover set on M0 → linked devices + members; deleted for everyone on M0 → gone on every device")
        def _():
            import base64
            c = M0.call("create_group", name="Cộng đồng đa thiết bị", members=[pf, pg], kind=1)
            gid, conv = c["gid"], c["conv"]
            everywhere(A + [F, G], lambda n: any(x["id"] == gid for x in n.call("spaces")), "community listed")
            cover = base64.b64encode(b"\xff\xd8\xff\xe0" + os.urandom(120_000)).decode()
            M0.call("group_meta", gid=gid, cover=cover)
            everywhere([M1, M2, F, G], lambda n: n.call("group_cover", gid=gid)["cover"] == cover, "the cover")
            rev = M0.call("group_info", gid=gid)["cover_rev"]
            everywhere([M1, M2], lambda n: next(x for x in n.call("spaces") if x["id"] == gid)["cover_rev"] == rev, "cover_rev in spaces")
            m = F.call("send_text", conv=conv, text="chào cộng đồng")
            everywhere(A, lambda n: msg(n, conv, m["id"]) is not None, "F's community message")
            # (a linked device of the owner may delete it too; here the main device does)
            M0.call("group_dissolve", gid=gid)
            def gone(n):
                return not any(x["id"] == gid for x in n.call("spaces")) and group_of(n, gid) is None \
                    and not any(r["id"].startswith(conv) for r in n.call("conversations"))
            everywhere(A + [F, G], gone, "community gone")
            for n in (M1, M2, F):
                n.wait_event(lambda e: e["event"] == "group_removed" and e.get("gid") == gid and e.get("dissolved") is True, SYNC_S, f"{n.name}: group_removed dissolved")
            for n in (M1, F):
                try:
                    n.call("send_text", conv=conv, text="vẫn còn?")
                    raise AssertionError(f"{n.name} posted to a deleted community")
                except RuntimeError:
                    pass
            # a restart doesn't bring it back
            M2.stop(); M2.start()
            time.sleep(2)
            assert gone(M2) and gone(M1), "deleted community came back"
        _()

        @scenario("stickers: pack + sticker made on M0, removed on M1 → every device")
        def _():
            pk = M0.call("sticker_pack_create", name="Gói ma trận")
            png = _png(os.path.join(tmp, "matrix-sticker.png"))
            s1 = M0.call("sticker_add", pack=pk["id"], path=png, emoji="😺")
            h = s1.get("hash") if isinstance(s1, dict) else None
            pack = lambda n: next((p for p in n.call("sticker_packs") if p["id"] == pk["id"]), None)
            everywhere(A, lambda n: pack(n) is not None and len(pack(n)["stickers"]) == 1, "pack with its sticker")
            if h:
                everywhere(A, lambda n: n.call("sticker_get", hash=h)["data"], "sticker image")
            M1.call("sticker_pack_delete", pack=pk["id"])
            everywhere(A, lambda n: pack(n) is None, "pack deleted")
        _()

        @scenario("Bot Studio bots: made on M1, deleted on M2 → every device")
        def _():
            M1.call("bot_create", name="Trợ lý ma trận", username="matran_bot")
            has = lambda n: any(b.get("username") == "matran_bot" for b in n.call("bot_list"))
            everywhere(A, has, "bot listed")
            M2.call("bot_delete", username="matran_bot")
            everywhere(A, lambda n: not has(n), "bot deleted")
        _()

        @scenario("chat locks, privacy settings and wallpaper → every device")
        def _():
            M0.call("locked_chats_set", chats=[dF])
            everywhere(A, lambda n: n.call("locked_chats_get")["chats"] == [dF], "locked")
            M2.call("locked_chats_set", chats=[])
            everywhere(A, lambda n: n.call("locked_chats_get")["chats"] == [], "unlocked")
            M1.call("settings_set", read_receipts=False, typing=False)
            everywhere(A, lambda n: (lambda s: not s["read_receipts"] and not s["typing"])(n.call("settings_get")), "privacy off")
            M0.call("settings_set", read_receipts=True, typing=True)
            everywhere(A, lambda n: (lambda s: s["read_receipts"] and s["typing"])(n.call("settings_get")), "privacy on")
            M2.call("set_wallpaper", conv=dF, wallpaper="midnight")
            everywhere(A, lambda n: n.call("get_wallpaper", conv=dF)["wallpaper"] == "midnight", "wallpaper")
            # auto-download rules have their own synced key: a later cache change on another
            # device (the whole storage.policy re-saved) doesn't undo them
            M1.call("settings_set", auto_download={"cell": {"photo": 0}})
            everywhere(A, lambda n: n.call("settings_get")["auto_download"]["cell"]["photo"] == 0, "auto-download rule")
            M2.call("set_storage_policy", max_cache=3 << 30)
            everywhere(A, lambda n: n.call("storage_policy")["max_cache"] == 3 << 30, "cache size")
            time.sleep(2)
            assert all(n.call("settings_get")["auto_download"]["cell"]["photo"] == 0 for n in A), "rule reset by a policy change"
            # "mentions only": emptied on one device stays empty everywhere (not "never set")
            M0.call("settings_set", mentions_only=[dF])
            everywhere(A, lambda n: n.call("settings_get")["mentions_only"] == [dF], "mentions only")
            M1.call("settings_set", mentions_only=[])
            everywhere(A, lambda n: n.call("settings_get")["mentions_only"] == [], "mentions only cleared")
        _()

        @scenario("stories: posted on M0 → M1, M2 and friends; deleted on M1 → gone everywhere")
        def _():
            s = M0.call("post_story", text="tin ma trận", bg="aurora")
            has = lambda n: any(x.get("id") == s["id"] for x in n.call("stories"))
            everywhere(A + [F], has, "story")
            M1.call("story_delete", story_id=s["id"])
            everywhere(A + [F], lambda n: not has(n), "story deleted")
        _()

        @scenario("checklists (M1 sends, M2 ticks) and reminders (M0) → every device")
        def _():
            c = M1.call("send_checklist", conv=dF, title="Việc cần làm", items=["mua sữa", "gọi điện"])
            everywhere(A, lambda n: msg(n, dF, c["id"]) is not None, "checklist")
            before = msg(M2, dF, c["id"])
            M2.call("checklist_toggle", conv=dF, msg_id=c["id"], item=1, done=True)
            after = lambda n, cv=dF: (lambda m: m and (m["body"], m["reactions"]) != (before["body"], before["reactions"]) and m)(msg(n, cv, c["id"]))
            wait_until(lambda: after(M2), SYNC_S, "ticked on M2")
            want = (msg(M2, dF, c["id"])["body"], msg(M2, dF, c["id"])["reactions"])
            everywhere(A, lambda n: (lambda m: (m["body"], m["reactions"]) == want)(msg(n, dF, c["id"])), "tick")
            wait_until(lambda: after(F, dM), SYNC_S, "F sees the tick")
            r = M0.call("send_reminder", conv=dF, title="Họp nhóm", at_ms=now_ms() + 3_600_000)
            everywhere(A, lambda n: any(x["msg_id"] == r["id"] for x in n.call("reminders")), "reminder pending")
            M2.call("reminder_cancel", conv=dF, msg_id=r["id"])
            everywhere(A, lambda n: not any(x["msg_id"] == r["id"] for x in n.call("reminders")), "reminder cancelled")
        _()

        @scenario("call history: F calls, M1 answers → call line on every device; M1 calls F → line on siblings")
        def _():
            c = F.call("call_start", conv=dM, video=False)
            M1.wait_event(lambda e: e["event"] == "call" and e["call_id"] == c["call_id"] and e["state"] == "incoming", 20, "M1 rings")
            M1.call("call_answer", call_id=c["call_id"], accept=True)
            F.wait_event(lambda e: e["event"] == "call" and e["call_id"] == c["call_id"] and e["state"] == "active", 15, "active")
            time.sleep(1)
            F.call("call_end", call_id=c["call_id"])
            calls = lambda n: [m for m in msgs(n, dF) if m["kind"] == "call"]
            everywhere(A, lambda n: len(calls(n)) >= 1, "call line (incoming)")
            k = len(calls(M0))
            c2 = M1.call("call_start", conv=dF, video=False)
            F.wait_event(lambda e: e["event"] == "call" and e["call_id"] == c2["call_id"] and e["state"] == "incoming", 20, "F rings")
            F.call("call_answer", call_id=c2["call_id"], accept=False)
            everywhere(A, lambda n: len(calls(n)) >= k + 1, "call line (outgoing, from M1)")
        _()

        @scenario("clear history (M1) and delete conversation (M2) → every device; new messages come back")
        def _():
            old = F.call("send_text", conv=dM, text="trước khi xoá lịch sử")
            everywhere(A, lambda n: msg(n, dF, old["id"]) is not None, "msg")
            M1.call("clear_history", conv=dF)
            everywhere(A, lambda n: msg(n, dF, old["id"]) is None, "history cleared")
            new = F.call("send_text", conv=dM, text="sau khi xoá lịch sử")
            everywhere(A, lambda n: msg(n, dF, new["id"]) is not None, "new message after clear")
            g1 = G.call("send_text", conv=f"d:{pm}", text="tin trong chat sẽ bị xoá")
            everywhere(A, lambda n: msg(n, dG, g1["id"]) is not None, "msg")
            M2.call("delete_conversation", conv=dG)
            everywhere(A, lambda n: conv_row(n, dG) is None, "conversation deleted")
            g2 = G.call("send_text", conv=f"d:{pm}", text="chat mới sau khi xoá")
            everywhere(A, lambda n: msg(n, dG, g2["id"]) is not None and conv_row(n, dG) is not None, "chat back with the new message")
        _()

        @scenario("device list: rename (M0) → every device and friends")
        def _():
            M0.call("device_rename", device=M2.me["device"], name="Máy tính M2")
            everywhere(A, lambda n: devnames(n).get(M2.me["device"]) == "Máy tính M2", "device name")
            wait_until(lambda: any(d["name"] == "Máy tính M2" for d in F.call("contact_devices", peer=pm)), SYNC_S, "F sees the name")
        _()

        # ------------------------------------------------------------ search
        @scenario("search: a linked device finds history from the main device (Vietnamese with / without diacritics, any case)")
        def _():
            vid = ctx["viet"]
            for n in A:
                for q in ("tiếng việt", "Tiếng Việt", "TIẾNG VIỆT", "tieng viet", "TIENG VIET", "chuc mung nam moi", "năm mới"):
                    got = [m["id"] for m in n.call("search", q=q)]
                    assert vid in got, f"{n.name}: '{q}' → {len(got)} results, not the message"
                # field names of the stored body are not text
                assert not any(m["id"] == vid for m in n.call("search", q="text")), f"{n.name}: 'text' matched the JSON key"
            # a message that only exists on the main device's history → found on a linked one
            live = M0.call("send_text", conv=dF, text="Đặt lịch họp đầu năm")
            everywhere(A, lambda n: live["id"] in [m["id"] for m in n.call("search", q="dat lich hop")], "search a synced message")
        _()

        @scenario("find people from every device: 9-digit ID, @username, invite link, device ID")
        def _():
            S = start("S")
            nodes.append(S)
            ps = S.me["peer"]
            sid = S.me["short_id"].replace(" ", "")
            for n in A:
                n.call("connect", peer=ps, timeout=40)
            for n in A:
                for t in (sid, S.me["short_id"], f"{sid[:3]}-{sid[3:6]}-{sid[6:]}", f"lumora://add/{ps}", f"https://getlumora.pages.dev/add/{ps}?id={sid}"):
                    r = n.call("add_contact", target=t, note="")
                    assert r["peer"] == ps, (n.name, t, r)
            S.wait_event(lambda e: e["event"] == "friend_request" and e["peer"] == pm, 20, "S gets the request")
            everywhere(A, lambda n: (contact(n, ps) or {}).get("status") == 1, "request pending")
            for n in A:
                got = n.call("resolve_username", handle="@ban_f")
                assert any(x["peer"] == pf for x in got), (n.name, got)
            # a friend's linked device's own 9-digit ID → the friend's account
            F1 = link(F, "F1", "qr", history="none")
            nodes.append(F1)
            fsid = F1.me["device"]
            wait_until(lambda: all(any(d["device"] == fsid for d in n.call("contact_devices", peer=pf)) for n in A), 20, "F's 2nd device known")
            short = [d for d in M1.call("contact_devices", peer=pf) if d["device"] == fsid][0]["short_id"]
            for n in A:
                assert n.call("add_contact", target=short, note="")["peer"] == pf
        _()

        # ------------------------------------------------------------ offline + restart
        @scenario("offline: M2 off while M0/M1 change everything, M2 restarts → converges")
        def _():
            M2.stop()
            H = ctx["H"]
            sent = M0.call("send_text", conv=dF, text="lúc M2 tắt (M0)")["id"]
            wait_until(lambda: msg(M1, dF, sent) is not None, SYNC_S, "M1 has M0's message")
            got = [F.call("send_text", conv=dM, text=f"F gửi lúc M2 tắt {i}")["id"] for i in range(3)]
            M1.call("edit_message", conv=dF, msg_id=sent, text="lúc M2 tắt (sửa trên M1)")
            M1.call("react", conv=dF, msg_id=got[0], emoji="👍", on=True)
            M0.call("set_profile", name="Tên khi M2 tắt", bio="bio khi M2 tắt")
            M1.call("conv_flag", conv=dF, flag="pinned", value=True)
            M0.call("mute", conv=dF, until=now_ms() + 7_200_000)
            M1.call("bot_create", name="Bot offline", username="offline_bot")
            M0.call("locked_chats_set", chats=[dF])
            M1.call("rename_contact", peer=pf, alias="F (offline)")
            pk = M0.call("sticker_pack_create", name="Gói offline")
            st = M1.call("post_story", text="tin lúc M2 tắt")
            gm = M1.call("send_text", conv=ctx["g"]["conv"], text="nhóm lúc M2 tắt")
            M0.call("pin_message", conv=dF, msg_id=got[1], on=True)
            for i in got:
                wait_until(lambda i=i: msg(M1, dF, i) is not None, SYNC_S, "M1 got F's message")
            M1.call("mark_read", conv=dF)
            time.sleep(1)
            M2.start()
            checks = [
                ("sent by M0", lambda: msg(M2, dF, sent) is not None),
                ("edit by M1", lambda: msg(M2, dF, sent)["body"]["text"] == "lúc M2 tắt (sửa trên M1)"),
                ("F's messages", lambda: all(msg(M2, dF, i) for i in got)),
                ("reaction", lambda: "👍" in (msg(M2, dF, got[0])["reactions"] or {})),
                ("message pin", lambda: msg(M2, dF, got[1])["pinned"] is True),
                ("profile", lambda: (lambda p: p["name"] == "Tên khi M2 tắt" and p["bio"] == "bio khi M2 tắt")(M2.call("profile"))),
                ("me.name", lambda: M2.call("me")["name"] == "Tên khi M2 tắt"),
                ("chat pinned + muted + read", lambda: (lambda c: c["pinned"] and c["muted"] and c["unread"] == 0)(conv_row(M2, dF))),
                ("bot", lambda: any(b.get("username") == "offline_bot" for b in M2.call("bot_list"))),
                ("chat lock", lambda: M2.call("locked_chats_get")["chats"] == [dF]),
                ("nickname", lambda: contact(M2, pf)["alias"] == "F (offline)"),
                ("sticker pack", lambda: any(p["id"] == pk["id"] for p in M2.call("sticker_packs"))),
                ("story", lambda: any(x.get("id") == st["id"] for x in M2.call("stories"))),
                ("group message", lambda: msg(M2, ctx["g"]["conv"], gm["id"]) is not None),
            ]
            for what, fn in checks:
                wait_until(fn, 30, f"M2 after restart: {what}")
            M0.call("locked_chats_set", chats=[])
            assert H  # (H stays a stranger now)
        _()

        @scenario("offline main device: M1 and M2 keep syncing with each other; M0 restarts → converges")
        def _():
            running(M0, M1, M2)
            M0.stop()
            m = M1.call("send_text", conv=dF, text="lúc máy chính tắt")
            wait_until(lambda: msg(M2, dF, m["id"]) is not None, SYNC_S, "M2 gets M1's message")
            f = F.call("send_text", conv=dM, text="F gửi lúc máy chính tắt")
            everywhere([M1, M2], lambda n: msg(n, dF, f["id"]) is not None, "F's message")
            M2.call("set_profile", name="Tên lúc máy chính tắt")
            wait_until(lambda: M1.call("me")["name"] == "Tên lúc máy chính tắt", SYNC_S, "M1 name")
            M2.call("conv_flag", conv=dF, flag="pinned", value=False)
            wait_until(lambda: conv_row(M1, dF)["pinned"] is False, SYNC_S, "M1 unpinned")
            M0.start()
            for what, fn in [
                ("M1's message", lambda: msg(M0, dF, m["id"]) is not None),
                ("F's message", lambda: msg(M0, dF, f["id"]) is not None),
                ("name", lambda: M0.call("me")["name"] == "Tên lúc máy chính tắt"),
                ("unpinned", lambda: conv_row(M0, dF)["pinned"] is False),
                ("3 devices", lambda: len(M0.call("devices")["devices"]) == 3),
            ]:
                wait_until(fn, 30, f"M0 after restart: {what}")
        _()

        @scenario("both linked devices offline, changes on M0, both restart → converge")
        def _():
            running(M0, M1, M2)
            M1.stop()
            M2.stop()
            m = M0.call("send_text", conv=dF, text="cả hai máy phụ tắt")
            M0.call("set_profile", bio="bio lúc hai máy phụ tắt")
            M0.call("conv_flag", conv=dF, flag="archived", value=True)
            M1.start()
            M2.start()
            everywhere([M1, M2], lambda n: msg(n, dF, m["id"]) is not None and n.call("profile")["bio"] == "bio lúc hai máy phụ tắt"
                       and conv_row(n, dF)["archived"] is True, "converged", t=30)
            M0.call("conv_flag", conv=dF, flag="archived", value=False)
        _()

        # ------------------------------------------------------------ races
        def both(f1, f2):
            ts = [threading.Thread(target=f1), threading.Thread(target=f2)]
            for t in ts:
                t.start()
            for t in ts:
                t.join()

        @scenario("race: the same message edited on M0 and M1 at once → one text everywhere (friend too)")
        def _():
            running(M0, M1, M2)
            e = M0.call("send_text", conv=dF, text="trước khi sửa cùng lúc")
            everywhere(A, lambda n: msg(n, dF, e["id"]) is not None, "msg")
            both(lambda: M0.call("edit_message", conv=dF, msg_id=e["id"], text="sửa từ M0"),
                 lambda: M1.call("edit_message", conv=dF, msg_id=e["id"], text="sửa từ M1"))
            time.sleep(3)
            txt = lambda n, c=dF: msg(n, c, e["id"])["body"]["text"]
            if os.environ.get("MATRIX_DEBUG"):
                print("   texts:", {n.name: txt(n) for n in A}, "F:", txt(F, dM), flush=True)
            wait_until(lambda: len({txt(n) for n in A} | {txt(F, dM)}) == 1, SYNC_S, f"one text (now { {n.name: txt(n) for n in A} } F={txt(F, dM)})")
        _()

        @scenario("race: chat pinned on M0 and unpinned on M1 at once; names set on M1 and M2 at once → converge")
        def _():
            both(lambda: M0.call("conv_flag", conv=dF, flag="pinned", value=True),
                 lambda: M1.call("conv_flag", conv=dF, flag="pinned", value=False))
            wait_until(lambda: len({conv_row(n, dF)["pinned"] for n in A}) == 1, SYNC_S, "one pin state")
            both(lambda: M1.call("set_name", name="Tên từ M1"), lambda: M2.call("set_name", name="Tên từ M2"))
            wait_until(lambda: len({n.call("me")["name"] for n in A}) == 1, SYNC_S, "one name")
            name = M0.call("me")["name"]
            wait_until(lambda: (contact(F, pm) or {}).get("name") == name, SYNC_S, f"F sees the winning name {name}")
        _()

        @scenario("race: F and M1 react to the same message at once → both reactions on every device")
        def _():
            t = F.call("send_text", conv=dM, text="thả tim cùng lúc")
            everywhere(A, lambda n: msg(n, dF, t["id"]) is not None, "msg")
            both(lambda: F.call("react", conv=dM, msg_id=t["id"], emoji="😂", on=True),
                 lambda: M1.call("react", conv=dF, msg_id=t["id"], emoji="🔥", on=True))
            r = lambda n, c=dF: set((msg(n, c, t["id"])["reactions"] or {}).keys())
            everywhere(A, lambda n: {"😂", "🔥"} <= r(n), "both reactions")
            wait_until(lambda: {"😂", "🔥"} <= r(F, dM), SYNC_S, "F: both reactions")
            time.sleep(3)
            for n in A:
                assert {"😂", "🔥"} <= r(n), f"{n.name} lost a reaction later: {r(n)}"
        _()

        @scenario("race: messages arrive while a new device links (M3) → none lost, none doubled")
        def _():
            running(M0, M1, M2)
            sent = []
            stop = threading.Event()

            def spam():
                i = 0
                while not stop.is_set() and i < 40:
                    sent.append(F.call("send_text", conv=dM, text=f"lúc đang liên kết {i}")["id"])
                    i += 1
                    time.sleep(0.15)
            th = threading.Thread(target=spam)
            th.start()
            M3 = link(M0, "M3", "qr", history="all")
            nodes.append(M3)
            ctx["M3"] = M3
            th.join()
            stop.set()
            wait_until(lambda: M3.call("history_status")["done"], 60, "M3 history")
            wait_until(lambda: all(msg(M3, dF, i) for i in sent), 30, "M3 has every message")
            ids = [m["id"] for m in msgs(M3, dF)]
            assert len(ids) == len(set(ids)), "duplicates"
            everywhere(A, lambda n: len(n.call("devices")["devices"]) == 4, "4 devices")
            # search on the new device finds the main device's history
            assert ctx["viet"] in [m["id"] for m in M3.call("search", q="tieng viet")], "M3 search"
        _()

        @scenario("device list: revoke (M0 signs M3 out) and sign out (M2) → every device + friend")
        def _():
            M3 = ctx["M3"]
            d3 = M3.me["device"]
            M0.call("device_revoke", device=d3, wipe_media=False)
            everywhere([M0, M1, M2], lambda n: d3 not in devnames(n), "M3 gone")
            wait_until(lambda: all(d["device"] != d3 for d in F.call("contact_devices", peer=pm)), SYNC_S, "F drops M3")
            d2 = M2.me["device"]
            M2.call("device_logout")
            everywhere([M0, M1], lambda n: d2 not in devnames(n), "M2 gone")
            wait_until(lambda: all(d["device"] != d2 for d in F.call("contact_devices", peer=pm)), SYNC_S, "F drops M2")
        _()
    except Exception as e:  # setup failed: the scenarios above were reported one by one
        print(f"  matrix aborted: {e}")
        ok[0] = False
    finally:
        for n in nodes:
            n.stop()
    return ok[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, "target", "debug", "lumorad"))
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--only", choices=["all", "base", "matrix"], default="all",
                    help="base: the original scenarios; matrix: the sync matrix (3 devices + 2 friends)")
    a = ap.parse_args()
    os.environ.setdefault("LUMORA_TEST_CAMERA", "1")  # never open a real webcam

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

    ok = True
    if a.only != "base":
        ok = run_matrix(tmp, start, link, befriend) and ok
        if a.only == "matrix":
            passed = sum(1 for r in RESULTS if r[1])
            print(f"\n{passed}/{len(RESULTS)} scenarios passed")
            if not a.keep and ok:
                shutil.rmtree(tmp, ignore_errors=True)
            elif not ok:
                print(f"logs kept in {tmp}")
            sys.exit(0 if ok else 1)
    A0 = start("A0")
    B0 = start("B0")
    C = start("C")
    nodes = [A0, B0, C]
    pa, pb, pc = A0.me["peer"], B0.me["peer"], C.me["peer"]
    dA, dB, dC = f"d:{pa}", f"d:{pb}", f"d:{pc}"
    ctx = {}
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

        @step("voice rooms across my devices: a linked device sees me in the room; joining there moves me")
        def _():
            A1 = ctx["A1"]
            g = A0.call("create_group", name="Phòng thoại", members=[pb], kind=1)
            gid = g["gid"]
            for n in (A1, B0):
                wait_until(lambda n=n: any(x["id"] == gid for x in n.call("spaces")), 40, f"{n.name} has the community")
            sp = next(x for x in A0.call("spaces") if x["id"] == gid)
            vconv = next(c["conv"] for c in sp["channels"] if c["voice"])
            d0, d1, db = A0.call("me")["device"], A1.call("me")["device"], B0.call("me")["device"]

            def state(n):
                return n.call("voice_state", conv=vconv)

            def on(n, dev):
                st = state(n)
                return st["participants"] == [pa] and st["devices"].get(pa) == dev

            A0.call("voice_join", conv=vconv)
            for n in (A1, B0):
                wait_until(lambda n=n: on(n, d0), 20, f"{n.name} sees A in the room on A0")
            sp1 = next(x for x in A1.call("spaces") if x["id"] == gid)
            assert next(c["participants"] for c in sp1["channels"] if c["conv"] == vconv) == [pa]
            assert state(A1)["joined"] is False and state(A0)["joined"] is True
            # joining on A1 moves me there: A0 leaves the room by itself
            A1.call("voice_join", conv=vconv)
            ev = A0.wait_event(lambda e: e["event"] == "voice" and e.get("conv") == vconv and e.get("moved") is True, 20, "A0 told it moved")
            assert ev["device"] == d1, ev
            A0.wait_event(lambda e: e["event"] == "call" and e.get("conv") == vconv and e["state"] == "ended", 10, "A0's room call ended")
            for n in (A0, A1, B0):
                wait_until(lambda n=n: on(n, d1), 20, f"{n.name}: A is in the room on A1")
            assert state(A1)["joined"] is True and state(A0)["joined"] is False
            # a friend joining gets media with A1 (not A0)
            B0.call("voice_join", conv=vconv)
            A1.wait_event(lambda e: e["event"] == "call" and e.get("conv") == vconv and db in [p["peer"] for p in e["participants"]], 20, "A1 has media with B0")
            B0.wait_event(lambda e: e["event"] == "call" and e.get("conv") == vconv and [p["peer"] for p in e["participants"]] == [d1], 20, "B0 has media with A1 only")
            A1.call("voice_leave", conv=vconv)
            B0.call("voice_leave", conv=vconv)
            for n in (A0, A1, B0):
                wait_until(lambda n=n: state(n)["participants"] == [], 20, f"{n.name}: room empty")
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

        @step("restore with the recovery phrase while linked devices exist: no device is signed out or re-listed without the user; signed-out ones stay out")
        def _():
            R0 = start("R0")
            nodes.append(R0)
            pr = R0.me["peer"]
            befriend(C, R0)
            R1 = link(R0, "R1", "qr", history="all")
            R2 = link(R0, "R2", "qr", history="none")
            R3 = link(R0, "R3", "qr", history="none")
            nodes.extend([R1, R2, R3])
            d1, d2, d3 = R1.me["device"], R2.me["device"], R3.me["device"]
            wait_until(lambda: R1.call("history_status")["done"], 60, "R1 history")
            wait_until(lambda: {d1, d2, d3} <= {d["device"] for d in R1.call("devices")["devices"]}, 20, "R1 knows R2, R3")
            # R2 and R3 (say, a stolen phone and an old laptop) are offline when the main
            # device signs them out: they never hear about it
            R2.stop()
            R3.stop()
            R0.call("device_revoke", device=d2, wipe_media=False)
            R0.call("device_revoke", device=d3, wipe_media=False)
            wait_until(lambda: not {d2, d3} & {d["device"] for d in R1.call("devices")["devices"]}, 30, "R1 has the revocations")
            phrase = R0.call("recovery_phrase")["phrase"]
            # the main device is lost for good; R1 is off too. The account is restored on a
            # new main device, which knows nothing about R2 / R3
            R1.stop()
            R0.stop()
            nodes.remove(R0)
            N = start("R0-moi", more=["--restore-phrase", phrase])
            nodes.append(N)
            assert N.me["peer"] == pr and N.me["primary"] and N.me["device"] == pr, N.me

            def listed(n):
                return {d["device"] for d in n.call("devices")["devices"]}

            def asked(dev, t):
                return N.wait_event(lambda e: e["event"] == "device_relist_request" and e["device"] == dev, t, f"relist request of {dev[:8]}")

            # the signed-out phone comes back first: the user is asked, it is NOT listed
            R2.start()
            ev = asked(d2, 40)
            assert ev["name"] == "R2" or ev["name"], ev
            time.sleep(3)
            assert d2 not in listed(N), "a missing device was listed without the user's approval"
            assert d2 in {r["device"] for r in N.call("device_relist_requests")}
            N.call("device_relist", device=d2, approve=False)  # "not mine — sign it out"
            R2.wait_event(lambda e: e["event"] == "device_revoked", 40, "R2 signed out after the refusal")
            assert d2 not in listed(N) and d2 in {r["device"] for r in N.call("devices")["revoked"]}
            # the real linked device comes back: never signed out, listed once the user allows it
            R1.start()
            asked(d1, 40)
            time.sleep(3)
            assert d1 not in listed(N), "listed without the user's approval"
            assert N.call("history_status")["done"] and not N.call("history_status").get("source"), "an unapproved device became the history source"
            me1 = R1.call("me")
            assert me1["peer"] == pr and me1["device"] == d1 and not me1["primary"], me1
            N.call("device_relist", device=d1, approve=True)
            wait_until(lambda: d1 in listed(N), 10, "R1 listed after the approval")
            wait_until(lambda: listed(R1) == {pr, d1}, 30, "R1 has the new list")
            # R1 brought the old list along: R3's earlier revocation is known on the new main
            wait_until(lambda: d3 in {r["device"] for r in N.call("devices")["revoked"]}, 30, "R3's revocation taken over")
            # restored with nothing: the account (friends, chats) comes back from the approved R1
            wait_until(lambda: N.call("history_status")["done"], 60, "account copied from R1")
            wait_until(lambda: any(c["peer"] == pc and c["status"] == 3 for c in N.call("contacts")), 20, "C is a friend again on the new main device")
            # the old laptop comes back: told it was signed out, the user is never asked
            R3.start()
            R3.wait_event(lambda e: e["event"] == "device_revoked", 60, "R3 signed out")
            try:
                asked(d3, 2)
                raise AssertionError("the user was asked about a device signed out before")
            except TimeoutError:
                pass
            assert d3 not in listed(N) and d3 not in listed(R1)
            # a friend's message reaches both devices of the restored account
            m = C.call("send_text", conv=f"d:{pr}", text="gửi tới tài khoản vừa khôi phục")
            for n in (N, R1):
                n.wait_event(lambda e: e["event"] == "message" and e["id"] == m["id"], 40, f"{n.name} got the friend's message")
            assert R1.call("me")["device"] == d1
            try:
                R1.wait_event(lambda e: e["event"] == "device_revoked", 1, "R1 still signed in")
                raise AssertionError("R1 was signed out")
            except TimeoutError:
                pass
        _()

        @step("outboxes drain on every device (bounded storage)")
        def _():
            def drained():
                return sum(n.call("storage_stats")["outbox"] for n in nodes) == 0
            try:
                wait_until(drained, 40, "outboxes empty")
            except TimeoutError:
                print("     outbox left:", {n.name: n.call("storage_stats")["outbox"] for n in nodes})
                for n in nodes:
                    for o in n.call("debug_outbox"):
                        print(f"       {n.name} → {o['to'][:10]} ({o['attempts']}x): {o['msg'][:120]}")
                raise
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
