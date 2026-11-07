# Pending before the next release (owner-approved 2026-11-07)

Start when the current core agent (devices/voice/groups security fixes) finishes:

**Community 2.0 core** — implement docs/src/dev/community2-contract.md exactly (app side already done
on the mock), plus these approved group/privacy changes (same core files):
1. Owner leaving: must pick a new owner first (UI step); `TransferOwner` op; automatic succession by
   real join order (`join_hlc`), not PeerId order; system notice `sys.owner_changed`.
2. Removed (by an admin) members can only be re-added by admins (check `left` like `banned` in Add and
   invite-link joins).
3. Privacy "Ai được gọi cho tôi": Everyone / Friends / Nobody, default Friends; stranger calls never ring
   (also rate-limit CallInvite from strangers).
5. `@all` needs the `mention_everyone` permission (admins by default); a muted chat still notifies direct
   @mentions and replies to my messages (quiet channel); sync "mentions only" across my devices.
6. Privacy "Ai được thêm tôi vào nhóm": Friends / Nobody (invites wait for approval). Default Friends.
7. Invite links: admin-only by default (`invite` permission), revocable (RevokeInvite / revoked list),
   optional "approve new members" mode.
8. Plain group calls don't ring everyone: show a "Join" banner; optional "Call…" member picker.
13. Privacy "Ai thấy tôi đang online": Friends / Nobody.
Also: built-in admin role has ALL permissions (incl. manage_community); dissolve owner-only.

After the brand-name cleanup agent finishes:
15. Unify wording: "thiết bị chính" (not "máy chính"), "Xoá"/"khoá" spelling, stories = "Khoảnh khắc",
    "tệp" (not "file"), "Chủ cộng đồng" for community owners, "Hiện trạng thái 'Đã xem'", "Chỉ kết nối
    trực tiếp" (not "Chỉ P2P thuần"), friends = "bạn bè" (directory = "Tìm theo ID").

Then: integration pass (core⇄UI wiring, flows on emulator + desktop, consistency), final bug review,
small app fixes (CallStore.chatOpen reset on call end; ChatStore reload in-flight guard + default TTL for
chats found by load()), voice_rooms_test, full gate incl. NAT lab, Accessibility declaration text for Play,
release (version bump, tag, CI public→private, upload with watchdog, site deploy incl. /child-safety/
and /delete-account/).

## State at handoff (2026-11-07 evening, the VS Code chat kept crashing — conversation too large)
Everything below is UNCOMMITTED in the working tree (check `git status` / `git diff`); nothing is lost.
DONE (by agents, gates were green unless noted): voice rooms; community cover + dissolve; 12 audit
items; delete account (Play); bubbles fix + real PiP signal; security fixes D1/D2 (relist needs user
approval), V1–V4, G1–G4, E1, O1; remote power-action results; persisted group reads; restore-with-phrase
scenario; HTTP Bot API in lumora-cli (`--http-api`, header X-Lumora-Bot-Secret); brand-name cleanup
(BotFather → "Xưởng Bot"/"Bot Studio"); Community 2.0 UI on the mock (contract file); message rules
(forward never shows alias + hide-sender, 1-1 delete only own, 48 h edit, TTL no forward/copy) — its
e2e was cut short by a FULL DISK, re-run in the final gate; website pages /child-safety/ and
/delete-account/ (not deployed); manifest location optional.
INTERRUPTED (partial work in tree, re-run each as a fresh agent with the same brief, checking git diff first):
  a) Community 2.0 core + group/privacy items 1,2,3,5,6,7,8,13 (see contract + list above)
  b) recovery from friends after a phrase restore (signed friendship proof, review list, 1-1 history
     6 months, group catch-up, setting "Giúp bạn bè khôi phục lịch sử" default on)
  c) media auto-download by network/kind + Moments audience (hide from…, close friends, archive kept)
  d) wording vi+en unification + l10n completeness test
Build hygiene: ONE shared CARGO_TARGET_DIR=core/target-md; cargo -j 4; disk had filled up to 100% —
keep an eye on `df -h /`. Run agents from the terminal CLI (`claude`), not the VS Code chat panel.

## Status 2026-11-07 night: ALL DONE, released as v1.0.8
Tasks a–d + integration + security review (13 fixes) + correctness review (1.0.7 compat via per-group
`RulesV2` opt-in, protocol 4) + gate: clippy clean, cargo 402, e2e 45/45 ×3, multidevice 53/53,
ip_privacy 10/10, recovery 5/5, bot_http 9/9, mixed 1.0.7/1.0.8 11/11, NAT lab 144/145 then 33/33 + samenat 40/40
after fixes, soak 13/13, apple 8/8, flutter 1156, Android emulator, Wine 10/10, check_dist.
