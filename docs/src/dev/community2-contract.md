# Community 2.0 — roles, permissions, channels (core ⇄ app contract)

The app side is built against this (mock: `app/lib/core/mock_community.dart`, state
`app/lib/state/community.dart`, UI `app/lib/ui/groups/community/*`, `group_rights.dart`).
The core must implement exactly this. Applies to communities (group kind 1) AND plain groups (kind 0).

## Permissions
`view_channel, send_messages, send_media, manage_messages, mention_everyone, connect_voice,
manage_channels, manage_roles, kick, ban, timeout, manage_bots, invite, pin, manage_community`

* `send_media` gates `send_file` only (voice notes need just `send_messages`).
* Dissolve (delete for everyone) stays owner-only, not a permission.

## Effective permissions
1. Owner: all.
2. Admin with a role `admin:<their peer>` (plain-group "admin rights"): @everyone ∪ that role.
3. Any other admin (built-in admin role): ALL permissions (communities and plain groups alike —
   admins may change name/avatar/cover/description; owner decision 2026-11-07).
4. Everyone else: @everyone ∪ their custom roles.

## @everyone defaults
* Community: `view_channel, send_messages, send_media, connect_voice`.
* Plain group: `view_channel, send_messages, send_media, connect_voice, pin`.
* Invite links / adding people (`invite`) are the admins' by default; a role (or @everyone) may
  give it to others. (A group still on the old rules keeps 1.0.7's "any member of a plain group adds".)
* `manage_community` is off by default but may be switched on for @everyone in plain groups only.

## Roles
* `group_roles {gid}` → `[{id, name, color:"#RRGGBB", perms:[…], position, builtin}]`, highest first.
* Built-ins: `everyone` (position 0, only perms editable) and `admin` (always highest, n+1, not
  editable/deletable). Custom roles are renumbered 1..n after each change; a new role without
  position goes just above @everyone; a given position inserts there.
* `group_role_set {gid, id?, name, color, perms, position?}` → `{id}` (create when id absent; an id
  `admin:<peer>` may be created by id — name = id, color `#6C5CE7` (Lumora primary); hidden from role lists).
* `group_role_delete {gid, id}` (built-ins refused).
* `group_member_roles {gid, peer, roles:[id…]}` — custom role ids only; also accepts a bot's peer.
* Admin status itself stays `group_set_role {gid, peer, role:"admin"|"member"}`.
* Only someone with `manage_roles` edits roles; nobody can grant a permission they don't hold;
  only the owner can make/unmake admins or moderate admins.
* Role hierarchy: `manage_roles` never edits, deletes, gives or takes away a role holding a
  permission its holder lacks, and never changes an admin's / the owner's roles (owner only).
* A demoted admin's `admin:<peer>` rights role is cleared and never counts for a member.
* `manage_bots` adds bots only: someone an admin removed comes back only through an admin, and an
  existing member is never turned into a bot.

## Channels
* Channels need a stable id: renaming keeps `conv` (today the conv is derived from the name —
  give channels an id at creation and keep it).
* `group_channel {gid, name, voice, remove, category?, topic?}` (existing; create/delete).
* `group_channel_update {gid, name, new_name?, topic?, category?, position?, private?, allow_roles?:[id…], announce?:bool}`.
* `position` = index in display order across the whole community (uncategorised first, then each
  category in order of its first channel).
* Private: visible to owner/admins and members holding a role in `allow_roles` (`everyone` in
  `allow_roles` opens it). Everyone also needs `view_channel`. `spaces` and `group_info` list only
  channels I can see.
* **Confidentiality of private channels:** a member who can't see a channel keeps its envelopes
  (encrypted, relayed like any other) but never stores their plaintext, previews, notifies or
  accepts file offers for it, and drops actions in it. All channels share the group key, though:
  a modified app of any member can still read them. This hides content from other members'
  *apps*; it is no cryptographic boundary. Follow-up: per-channel keys (sealed to the members
  who may see the channel, rotated when that set shrinks) — not part of v1.0.8.
* Announcement: posting needs `manage_messages`, a role in `allow_roles`, or owner/admin.

## Moderation
* `group_timeout {gid, peer, until_ms}` (0 lifts). Timed-out members can't post or join voice.
  Can't time out/kick/ban yourself or the owner; only the owner moderates admins.
* Posting needs `send_messages` and no active timeout; refusals: `err.channel_readonly`,
  `err.timed_out`; info changes without `manage_community`: `err.admin_only`.
* `group_rename` / `group_meta` (avatar, cover, description) require `manage_community` in every group
  (replaces "any member may change a plain group's cover every 10 min").
* "Revoke every invite link" needs `manage_community` (one link: `invite`); a revoke-all dated more
  than `MAX_CLOCK_SKEW_MS` ahead of the receiver's clock is refused (it would cover future links).
* Untrusted clocks: a group message's own time must be its envelope's (≤ `MAX_CLOCK_SKEW_MS`
  earlier); rules are judged at the envelope's time. Ops and moderation actions dated more than 1 h
  before a cut of the author's rights (removed, demoted, timed out, a role taken away or made
  weaker) are refused; so is content dated that far before a change of what the author may post
  when today's rules refuse it — unless another member serves it (history it already took).
* An ex-owner's Dissolve is final only while it races its own Leave: once any op was applied after
  that Leave, or the Leave arrived here more than 1 h ago, it is refused.
* Edits: within 48 h of the message's signed time *and* of the receiver's clock (+ skew).
* Moderators with `manage_messages` may delete others' messages for everyone.

## Info / events
* `group_info` (all groups) gains `roles`, `my_perms`, `members[].roles`, `members[].timeout_until`,
  `channels[].{topic, category, position, private, allow_roles, announce}`, `bots[].roles`.
* `spaces` channels gain `topic, category, position, private`.
* The `group` event carries the full updated info.

## Enforcement
Every rule above must be enforced by every member's core when folding the signed op log (not only
by the sender's UI): an op or message from someone lacking the permission is rejected the same way
on every device.

## Core implementation notes (v1.0.8)
* Rules live in the fold (`core/.../group.rs`, `community.rs`); derived state (`GroupState::ext`)
  is never serialized — `GroupState::decode` re-folds the op log. New ops are appended to `GroupOp`:
  `RoleSet, RoleDelete, MemberRoles, Timeout, ChannelUpdate, TransferOwner, RevokeInvite, JoinApproval`.
* The Community 2.0 rules are a **per-group switch**, not a date: op `RulesV2` (appended to
  `GroupOp`). Groups created by 1.0.8+ carry it right after their Create; until a group has it,
  every op folds exactly as 1.0.7 folds it (member renames in plain groups, PeerId-order
  succession, any member of a plain group adds, banned bots keep their flag) and the new op kinds
  are rejected — a 1.0.7 member keeps converging. An admin switches an old group with
  `group_upgrade_rules {gid}` (refused with `err.group_upgrade_blocked` while a member's device
  announced protocol < 4); the owner's main device does it by itself once every member device it
  knows of announced protocol 4. `group_info.rules_v2` tells the app which rules apply.
  `V2_RULES_HLC` remains only as a lower bound for `RulesV2`.
* Protocol 4 (`PROTO_V4`): reads the new op kinds. A Welcome holding them is never sent to a device
  that announced an older protocol: `group_add` / `create_group` refuse with `err.group_peer_outdated
  {name}` ("ask them to update"), so 1.0.7 never receives a group it can't decode.
* Invitations: declining never joins (nothing stored, nobody dialled); the inviter alone gets my
  signed Leave as sealed mail. A group joined on another of my devices drops the invitation here,
  and declining it here then does nothing. A `group_join_denied` counts only from the peer I asked.
* Channel ids: `group_info.channels[].id` (and `spaces`) is the channel's key = its conversation;
  `name` is what it shows after renames.
* Groups 2.0 commands: `group_transfer_owner`, `group_leave` → `err.owner_must_transfer` while others
  remain; `create_invite` → `{id, link, created, expires}`; `group_invite_links`, `group_revoke_invite`;
  `group_settings {approve_joins}` + `group_info.{approve_joins, join_requests}`, `group_join_deny`;
  `group_invites`, `group_invite_answer` (events `group_invite`, `group_invites`); a refused link join
  emits `group_join_denied {gid, reason: revoked|removed|denied, code}` on the joiner.
  Join requests (approve mode) reach the link's maker, which copies each one (`Ext GROUP_JOIN_REQUEST`
  0x36, also `drop` when handled) to every admin holding `invite` and its own devices: all of them list
  it in `group_info.join_requests` (event `group_join_request`) and may approve (`group_add`) or decline.
* Plain group calls: `call_start {ring: [peer]}` rings only those; the others get `call` state
  `available` (join = `call_answer accept`, dismiss = local).
* Privacy (`settings_get/set`, synced): `who_can_call` everyone|friends|nobody, `who_can_add`
  friends|nobody, `who_sees_online` friends|nobody (defaults friends), `mentions_only` [conv].
  Only friends ever show online; strangers' calls never ring (with "everyone": ≤ 3 per 10 min).
