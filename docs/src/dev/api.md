# Core ⇄ UI API contract (v1)

The Rust core (`lumora-core::node`) exposes one JSON API. It is reachable through:

* **FFI** (`lumora-ffi`, used by the Flutter app):
  * `int32_t lumora_start(const char* config_json)` → 0 ok, <0 error (see `lumora_last_error`)
  * `char* lumora_request(const char* request_json)` → response JSON (blocking, call from a background isolate)
  * `char* lumora_next_event(int32_t timeout_ms)` → event JSON or NULL on timeout
  * `int32_t lumora_frame(uint32_t stream, uint8_t* dst, uint32_t cap, uint32_t* w, uint32_t* h)` → copies latest decoded RGBA frame, returns bytes written (0 = no new frame)
  * `void lumora_free(char*)`, `const char* lumora_last_error()` (plain, localized text), `const char* lumora_last_error_json()` (`{"error","code","detail"?}`), `void lumora_stop()`
  * Build feature `media` only — frames produced by the app instead of the core:
    * `int32_t lumora_push_camera_yuv(uint32_t w, uint32_t h, const uint8_t* y, uint32_t y_stride, const uint8_t* u, uint32_t u_stride, const uint8_t* v, uint32_t v_stride, uint32_t uv_pixel_stride, uint32_t rotation)` → camera picture for an active video call, straight from the platform capture (what the apps use). 4:2:0 in any common layout: I420 (`uv_pixel_stride` 1), NV12 (`v = u + 1`, 2), NV21 (`u = v + 1`, 2), Android YUV_420_888. The core rotates it `rotation & 0xffff` degrees clockwise (0/90/180/270) so it is upright, maps full range to video range when `rotation` has `0x10000` (`LUMORA_CAMERA_FULL_RANGE`), converts to I420 in one pass and drops 720p → 480p while the encoder lags. Returns 0 accepted, 1 dropped (encoder busy), 2 dropped (no call wants the camera), -1 bad arguments. Android calls it through JNI: `vn.lumora.lumora.LumoraNative.pushCameraYuv` with the `ImageProxy` planes' direct `ByteBuffer`s
    * `int32_t lumora_push_camera_frame(uint32_t w, uint32_t h, uint32_t stride, uint32_t format, const uint8_t* data, size_t len)` → packed camera frame (`format` 0 = RGBA, 1 = BGRA; no rotation). Returns 0, 1 dropped, -1 bad arguments
    * `int32_t lumora_push_screen_frame(w, h, stride, format, data, len)` → screen frame for remote-desktop/screen sharing where the OS only hands frames to the app (iOS ReplayKit; also tests). Returns 0, or -1 on bad arguments
    * `void lumora_set_screen_display(uint32_t w, uint32_t h, float scale)` (describe that screen before the first frame), `void lumora_clear_screen_frames()` (the source stopped)
  * `int32_t lumora_lan_candidate(const char* hint, const char* ip, uint16_t port)` → a Bonjour sighting from iOS (`NWBrowser`): 1 recorded, 0 ignored
  * Library: `liblumora_ffi.so` (Linux, Android), `lumora_ffi.dll` (Windows), `liblumora_ffi.dylib` in `Lumora.app/Contents/Frameworks` (macOS), static `liblumora_ffi.a` linked into the app on iOS (looked up with `DynamicLibrary.process()`); see [Apple platforms](../platforms/apple.md).
* Apple/mobile helpers (JSON commands): `resume` (app back in the foreground / network changed: re-dial friends now, retry relay → direct upgrades), `set_network_hint` (`{metered, low_battery}`: either one → no birthday spraying), `settings_set` `help_friends` (bool, default on: relay for friends behind hard NATs; off stops serving at once), `lan_advert` (Bonjour name/port to advertise), `push_register` / `push_unregister` / `push_status` (iPhone wake-ups, see [push bridge](../ops/push.md))
* **CLI daemon** (`lumorad --stdio`): one JSON request per line on stdin, responses and events as JSON lines on stdout.

## Config (`lumora_start` / `lumorad --config`)
```json
{ "data_dir": "/path", "passphrase": null, "port": 0, "name": "Alice",
  "relays": ["wss://relay.example.com/ws"], "nostr": null, "stun": null,
  "enable_lan": true, "enable_upnp": true, "enable_dht": true, "enable_nostr": true,
  "relay_delay_ms": 3500, "log": "info", "lang": "vi" }
```
`null` fields use defaults.

## Request / response
```json
→ {"id": 7, "cmd": "send_text", "conv": "d:<peer>", "text": "hi"}
← {"id": 7, "ok": true, "data": { ... }}
← {"id": 7, "ok": false, "error": "Bạn đã chặn người này. Hãy bỏ chặn để nhắn tin.", "code": "err.blocked"}
← {"id": 7, "ok": false, "error": "Có lỗi xảy ra. Vui lòng thử lại.", "code": "internal", "detail": "<raw technical cause>"}
```

Errors: `error` is always a plain sentence in the UI language (`set_lang`, or `lang` in the
config before the core has loaded its own setting) and safe to show as-is. `code` is a stable
key: an `err.*` catalog key (see `i18n_catalog`) for situations the user can act on, or
`internal` for unexpected failures. `detail` (optional) carries the technical cause and must
only be shown behind a collapsed "Technical details" view. In the core, user-facing errors
are created with `crate::i18n::user_err("err.key").with("arg", v)` (works with `?`,
`bail!`, `ensure!`); anything else is reported as `internal`.

Note: the top-level `id` field is always the request id; command arguments never use the key `id`.

Identifiers: peers = base32 lowercase (52 chars), `short_id` = "123 456 789". Conversation ids: `d:<peer>` for direct chats, `g:<gid hex32>` for groups. Message ids = 32 hex chars. Timestamps = ms since epoch.

### Commands
| cmd | args | data |
|---|---|---|
| `me` | – | `{peer, short_id, name, recovery_phrase_available, safety}` |
| `set_name` | `name` | – |
| `recovery_phrase` | – | `{phrase}` — 24 English BIP39 words separated by spaces (the 32-byte identity seed + 8-bit SHA-256 checksum; no PBKDF2 step). Restore with start config `recovery_phrase` (alias `restore_phrase`) or `lumorad --restore-phrase`; the pre-wordlist base32 phrase (`abcde-fghij-…`, 12 groups) of the same account is still accepted. Errors: `err.phrase_word` `{n}`, `err.phrase_checksum`, `err.phrase_count` `{n,t}`, `err.bad_recovery_phrase` (damaged legacy phrase). The app bundles the wordlist (`app/lib/core/bip39_wordlist.dart`). |
| `net_status` | – | `{nat, public_ip, port, addrs[], upnp, relays:[{url,connected}], nostr:[{url,connected}], dht, lan_peers, peers:[{peer, path:"direct"|"lan"|"relay", rtt_ms, remote_addr}]}` |
| `contacts` | – | `[Contact]` |
| `add_contact` | `target` (base32 peer or 9-digit short id), `note?` | `{peer}` (sends friend request) |
| `lookup` | `short_id` | `[{peer, name}]` |
| `accept_contact` / `remove_contact` / `block_contact` | `peer` | – |
| `rename_contact` | `peer, alias` | – |
| `verify_contact` | `peer` | `{safety_number}` ; `mark_verified` `peer, verified:bool` |
| `conversations` | – | `[Conversation]` |
| `messages` | `conv, before?: hlc, limit?: 50` | `[Message]` (oldest→newest) |
| `send_text` | `conv, text, reply_to?, ttl_ms?` | `Message` |
| `edit_message` | `conv, msg_id, text` | – |
| `delete_message` | `conv, msg_id` | – |
| `react` | `conv, msg_id, emoji, on` | – |
| `mark_read` | `conv` | – |
| `typing` | `conv, on` | – |
| `conv_flag` | `conv, flag:"muted"|"pinned", value` | – |
| `delete_conversation` | `conv` | – |
| `set_retention` | `conv, mode: "forever"|"session"|"24h"|"7d"|"30d"` | – ("session" = no history: wiped on restart, secure-deleted) |
| `get_retention` | `conv` | `{mode}` |
| `set_lang` | `lang: "vi"|"en"` | `{lang}` (core error texts + system messages) |
| `i18n_catalog` | – | `{en:{key:text}, vi:{...}}` — system messages are stored as `body:{code,args,text}`; render `code` with this catalog |
| `search` | `q` | `[Message]` |
| `create_group` | `name, members[]` | `{gid, conv}` |
| `group_info` | `gid` | `{gid, name, owner, members:[{peer,name,role}], epoch, my_role}` |
| `group_add` / `group_remove` | `gid, peer` | – |
| `group_set_role` | `gid, peer, role:"admin"|"member"` | – |
| `group_rename` | `gid, name` | – |
| `group_leave` | `gid` | – |
| `send_file` | `conv, path` | `File` |
| `accept_file` | `file_id, dir?` | – |
| `cancel_file` | `file_id` | – |
| `files` | – | `[File]` |
| `call_start` | `conv, video` | `{call_id}` |
| `call_answer` | `call_id, accept` | – |
| `call_end` | `call_id` | – |
| `call_set` | `call_id, mic?, cam?, screen?` | – |
| `remote_status` | – | `{my_short_id, password, unattended, allow_control, wayland:{...diagnostics}}` |
| `remote_set` | `password?, unattended?, allow_control?` | – |
| `remote_connect` | `target` (short id or peer), `password`, `view_only` | `{session}` |
| `remote_respond` | `session, accept, control` | – |
| `remote_input` | `session, ev` (see Input) | – |
| `remote_end` | `session` | – |
| `diagnostics` | – | `{platform, session_type, desktop, checks:[{id, ok, title, detail, fix_steps[]}]}` |
| `storage_stats` | – | db stats |
| `maintain` | – | runs storage cleanup |


### Added in v1.1
| cmd | args | data |
|---|---|---|
| `profile` | – | `{name, bio, status, avatar}` |
| `set_profile` | `name?, bio?, status?: online|away|dnd|invisible, avatar?: base64 (≤96 KB)` | profile |
| `contact_avatar` | `peer` | `{avatar}` |
| `send_message` | `conv, text, reply_to?, ttl_ms?, mentions?: [peer], mention_all?` | Message (event `mention` on receivers) |
| `forward_message` | `msg_id, to_conv` | Message (`meta.forwarded_from`) |
| `pin_message` / `pinned_messages` | `conv, msg_id, on` / `conv` | – / `[Message]` |
| `send_poll` / `vote` | `conv, question, options[2..10]` / `conv, msg_id, option` | Message / – (votes in `reactions.__votes`) |
| `schedule_message` / `scheduled_messages` / `cancel_scheduled` | `conv, text, at` / – / `sched_id` | – |
| `create_invite` / `inspect_invite` / `join_invite` | `gid, hours` / `link` / `link` | `{link}` / `{name, valid, already_member}` / `{pending}` |
| `export_backup` | `path, password (≥6), passphrase?` | `{path, bytes}` — restore with start config `restore_backup: [path, password]` |
| `remote_quality` | `session, preset: smooth|balanced|sharp|saver` | `{max_kbps}` (host adapts bitrate to network each second, 60 fps capture) |
| `set_retention` / `get_retention` | `conv, mode` / `conv` | – / `{mode}` |
| `set_lang` / `i18n_catalog` | `lang` / – | – |

Saved messages: conversation id `s:me`. Conversation flag `archived`. Events: `mention`, `video_stream {call_id, peer, stream}`, `clipboard {peer, text}`.

### Added in v1.2 (protocol 2)
| cmd | args | data |
|---|---|---|
| `send_text` / `send_message` | `…, silent?: bool` | Message (`silent: true`, `meta.silent`) — receivers show it without sound or notification |
| `send_checklist` | `conv, title, items: [text] (1..100), silent?` | Message `kind: "checklist"`, body `{title, items: [{id, text}]}` |
| `checklist_toggle` | `conv, msg_id, item (id), done` | – (anyone in the chat; state in `reactions.__checks {"<id>": {done, by, at}}`, newest `at` wins) |
| `checklist_add` | `conv, msg_id, items: [text]` | – (sender only; `message_update {body}`) |
| `send_reminder` | `conv, title, at_ms (future), note?, silent?` | Message `kind: "reminder"`, body `{title, at_ms, note}` |
| `reminder_seen` / `reminder_cancel` | `conv, msg_id` | – (`reactions.__seen {peer: ms}` / `reactions.__cancelled {by, at}`, cancel: sender only) |
| `reminders` | – | upcoming `[{conv, msg_id, at_ms, title, note, author}]` on this device |
| `remote_wake` | `peer` (or 9-digit ID) of a recent remote device | `{sent, helpers}` — magic packets on every local network, plus friends' online devices asked to send one |
| `ui_secret_get` / `ui_secret_set` | `key` ("ui." prefix) / `key, value: string (≤ 4 KB) \| null` | string \| null / – (kept in the encrypted database) |
| `locked_chats_get` / `locked_chats_set` | – / `chats: [conv]` (≤ 1000) | `{chats, set}` / `{chats}` — account setting `privacy.locked_chats`, synced to the account's devices; `message` events of a locked chat carry `locked: true` |
| `botfather_history` / `botfather_append` / `botfather_clear` | – / `entries: [{mine, text, kind?, u?, ts?}]` / – | `{entries}` — BotFather chat, synced to the account's devices, last 200 lines (≤ 64 KB), tokens masked |

`settings_get`/`settings_set` gain `noise_suppression` (default on, applies mid-call) and `wake_for_friends`
(default on: send wake-up packets when a friend asks). `remote_recent` entries gain `macs`, `online`, `can_wake`;
`remote_status` gains `macs` (this computer). `file` events / `files` entries of active transfers carry
`speed_bps` (smoothed over ~2 s). Events: `reminder_due {conv, msg_id, title, note, at_ms, author, mine, late}`
on every device holding the reminder.

Camera effects (see [Video effects](video-effects.md)): `settings_get`/`settings_set` gain `video_beauty`
(0 = off, 1–3 = Nhẹ/Vừa/Mạnh, default 0), `video_lowlight` (default on) and `video_mirror_send` (default off);
stored as `video.beauty` / `video.lowlight` / `video.mirror_send` and applied to a running camera on its next
frame. While the camera is on, the core emits `video_stream {call_id, peer: <me>, stream, kind: "camera",
local: true}` for the self-view (processed, mirrored frames via `frame`), and `stream: -1, ended_stream` when it stops.

Compatibility: peers announce `Hello.version`; the new message kinds, actions and `silent` are only sent to peers
known to speak protocol ≥ 2. Older peers get checklists/reminders as plain text in 1-1 chats; in groups they
don't see them. Undecodable control frames are skipped instead of closing the connection.

### Added in v1.3 (protocol 3): multi-device
One account on up to 8 devices (design: [Multi-device](multi-device.md)). `peer` everywhere is still the
**account**; each device also has its own key (`device`). The main (primary) device is the original install
(its device key *is* the account key); linked devices are "secondary".

Config: `link_pending: true` (CLI `--link-pending`) starts a fresh device waiting to be linked.

| cmd | args | data |
|---|---|---|
| `me` | – | adds `account` (= `peer`), `device`, `primary`, `device_name`, `devices` (count), `link_pending` |
| `recovery_phrase` | – | on a linked device: error `err.phrase_on_primary` |
| `devices` | – | `{account, device, primary, version, devices: [{device, name, kind (1 phone, 2 tablet, 3 desktop, 4 cli), caps (1 main, 2 remote-controllable, 4 calls), added, primary, this, online, last_seen, short_id}], revoked: [{device, at, wipe}]}` |
| `device_rename` | `device, name` | `devices` data (main device only: `err.primary_only`) |
| `device_revoke` | `device, wipe_media?` | **main device**: signs a device out of the account (new signed list; it is refused everywhere, gets no new keys, group keys rotate; with `wipe_media` its downloads are erased too) → `devices` data. Errors `err.primary_only`, `err.cannot_revoke_self`, `err.device_not_found` |
| `device_logout` | – | **linked device**: asks the main device to revoke it, then signs out → `{notified}` (then `device_revoked`). On the main device: `err.primary_logout` |
| `device_promote` | `phrase, passphrase?` | **linked device** + the 24-word recovery phrase: becomes the main device (keystore re-wrapped with the account key, its old device key revoked) → `{promoted}` then `link_state {state: restart, reason: "promoted"}`. Errors `err.already_primary`, `err.phrase_mismatch`, `err.bad_phrase` (or the phrase's own word errors). A previous main device that comes back signs itself out |
| `contact_devices` | `peer` | `[{device, name, kind, caps, primary, online, last_seen, short_id, safety}]` (a friend's devices from its signed list; `safety` = that device's security code) |
| `link_invite` | – | **main device** (the direction the app uses): `{qr, code, expires, device, name}` — the new device scans the QR / types the code with `link_scan`; then `link_request {device, name, kind, os, app, path}` arrives here and `link_approve` / `link_reject` answer it. One invitation = one device |
| `link_start` (alias `device_link_start`) | `name?` | **new device**: `{qr: "lumora://link/…", code: "1234-5678-9012", expires (ms), device, name}`; needs a fresh, non-bot device (`err.link_not_fresh`, `err.bot_single_device`). Valid 10 min; the code rotates after 3 wrong attempts (`link_state code_rotated {code}`) |
| `link_scan` (alias `device_link_accept`) | `qr` \| `code` | **main device**: finds + authenticates the new device → `{device, name, kind, os, app, path}`. **New device** (started with `link_pending`): scans the main device's invitation → `{device, name, kind, os, path, state: "awaiting_approval"}`, then `link_state approved` + `restart` once approved (or `failed {reason: declined \| cancelled}`). Errors `err.link_code_invalid`, `err.link_code_expired`, `err.link_code_wrong`, `err.link_not_found`, `err.link_failed`, `err.link_on_primary`) |
| `link_approve` (alias `device_link_confirm`) | `device, history: "none"\|"1m"\|"3m"\|"6m"\|"12m"\|"all" (default 3m), history_since_ms?, media?` | `devices` data. The new device restarts and copies the account state + that much history |
| `link_reject` | `device` | – |
| `link_cancel` | – | – (either side) |
| `history_status` | – | `{active, state_done, done, messages, since_ms, source}` on a newly linked device |
| `remote_status` | – | `fixed_password` (any kind), `fixed_password_legacy` (stored by an older version as a password-equivalent key — setting the password again upgrades it) |

Events: `link_state {state: waiting | connecting | verifying | awaiting_approval | approved | restart | syncing |
state_synced | code_rotated | failed | cancelled, reason?, code?, device?, account?}` — on **`restart`** the host
must stop the core and start it again with the same config (`lumorad` does it in-process; the app calls
`lumora_stop` + `lumora_start`); `link_request {device, name, kind, os, path}`; `devices` (the `devices` data,
on change and when one of my devices connects/disconnects); `contact_devices {peer, devices}`;
`history_sync {messages, convs_done, convs_total, done, from}`; `device_revoked {device, wipe, by_self, restart: true}`
(this device was signed out: the host stops the core and starts it again — the next start wipes the account's data
and begins as a fresh install; `lumorad` does it in-process); `profile {key, name}` (a profile setting changed on
another device); `group_removed {gid, conv, left?}` (this account left / was removed from a group — bots too).
Calls ring every device of the callee: when another of my devices answers or declines, the ringing one gets
`call {state: "ended", reason: "answered_elsewhere" | "declined_elsewhere", device_name}`. `call.participants[]`
gains `account`. `remote_connect` takes `device?`: an account with several controllable devices needs one
(`err.choose_device`, `detail` = JSON `[{device, name, kind, short_id, online}]`); a device's own 9-digit ID
(`short_id`) also works as `target`.
`presence` gains `device` and `own` (one of my devices; `online` stays account-level for friends).
`ready` gains `device`, `primary`. Messages gain no new fields; files may have `state: 7` = "kept on your other
device" (`accept_file` fetches it from there; `err.file_on_other_device` if none is online).

Friends on pre-multi-device apps get what a linked device sends them through the main device (it re-signs
with the account key, same ids); until the main device is online those messages stay "sending".

Group members who aren't contacts: `group_info.members[]` has `name` (from the name they introduce themselves
with), `short_id` and `friend`. Bots can't join groups by themselves (`join_public` → `err.bot_join_public`);
privacy-mode bots follow membership changes (they get the signed ops without the key) and can `group_leave`.

### Reports ("Báo cáo") — no server, no moderation team
A report goes to the people who can act on it (design: `node/reports.rs`).

| cmd | args | data |
|---|---|---|
| `group_report` | `gid, msg_id? \| peer?, reason: "spam"\|"harassment"\|"adult"\|"other", note? (≤ 300), hide?` | `{id, sent_to}` — sent (`Ext GROUP_REPORT` 0x32, outbox) to every device of the group's owner and admins, never to the reported member. `msg_id`: a message of this group (its author is the reported member; text excerpt ≤ 200 chars). `hide`: also `set_member_hidden`. Errors `err.group_not_found`, `err.not_member`, `err.report_reason`, `err.report_target` (own message, another chat, not a member), `err.report_no_admins`, `err.message_not_found` |
| `group_reports` | – | admin: reports waiting on this device, newest first: `[GroupReport]` |
| `group_report_done` | `ids: [id]` (or `id`) | – : handled (dismissed / acted on). Gone here and on my other devices (`Ext GROUP_REPORT_DONE` 0x33, own devices only); a late copy of a handled report is dropped |
| `group_block` | `gid, name?` | `[{gid, name, at}]` — report a whole group: leave it (if a member), delete its chats, block it. Account setting `privacy.blocked_groups` (synced): hidden from `groups` / `search_groups`, `join_invite` / `join_public` → `err.group_blocked`, `inspect_invite` gains `blocked`, welcomes (being added) ignored |
| `group_unblock` | `gid` | `[{gid, name, at}]` |
| `blocked_groups` | – | `[{gid, name, at}]` |
| `hidden_members` | – | `[peer]` — account setting `privacy.hidden_members` (synced); the app hides their group messages |
| `set_member_hidden` | `peer, hidden` | `[peer]` |

`GroupReport`: `{id, gid, conv, group_name, msg_id?, excerpt, msg_exists, member, member_name, member_in_group,
reporter, reporter_name, reason, note, ts}` — `excerpt` is the admin device's own copy of the message, never
the reporter's text. The admin's device keeps a report only when the reporter is a current member, the message
is in that group and by the reported member (or the member is / was in it), the reason is known, it isn't a
duplicate, and the reporter is under 5 reports per 10 minutes (then 1 every 2 min).

Events: `group_report` (`GroupReport`, admin devices), `group_report_handled {ids}` (handled here or on another
of my devices), `settings {key: "privacy.blocked_groups" | "privacy.hidden_members"}` (changed here or synced
from another device; a group blocked elsewhere also gets `group_removed {left: true}` and is left here too).

### Input events (`remote_input.ev`)
```json
{"t":"move","x":0.5,"y":0.25}          // normalised 0..1
{"t":"button","b":"left|right|middle","down":true}
{"t":"wheel","dx":0,"dy":-1}
{"t":"key","code":"KeyA","down":true}   // W3C KeyboardEvent.code names
{"t":"text","s":"Xin chào"}             // unicode text (IME)
```

### Events (pushed)
| event | payload |
|---|---|
| `ready` | `{peer, short_id, device, primary}` |
| `net` | same as `net_status` data (on change) |
| `presence` | `{peer, device, own, online, path}` |
| `contact` | `Contact` (added/updated) |
| `friend_request` | `{peer, name, note}` |
| `message` | `Message` (new, incoming or outgoing echo) |
| `message_update` | `{conv, id, status?, body?, edited?, deleted?, reactions?}` |
| `conversation` | `Conversation` |
| `typing` | `{conv, peer, on}` |
| `group` | group_info payload |
| `file` | `File` (progress / state changes) |
| `call` | `{call_id, conv, peer, state:"ringing"|"incoming"|"active"|"ended", video, participants[]}` |
| `remote_request` | `{session, peer, name, view_only}` |
| `remote_state` | `{session, peer, state:"connecting"|"active"|"ended"|"denied", width, height, role:"viewer"|"host", stream}` |
| `error` | `{message}` |

### Data shapes
```
Contact      {peer, short_id, name, alias, status(0 none,1 sent,2 received,3 friend,4 blocked), added, last_seen, verified, relays[], online}
Conversation {id, kind(0 direct,1 group), title, last_ts, unread, muted, pinned, last_text}
Message      {id, conv, author, hlc, ts, kind("text"|"file"|"sticker"|"voice"|"call"|"system"|"poll"), body, status(0 pending,1 sent,2 delivered,3 read,9 failed), edited, deleted, reply_to, reactions:{emoji:[peer]}, expires, mine}
File         {id, conv, peer, name, size, hash, path, direction(0 out,1 in), state(0 offered,1 transferring,2 done,3 failed,4 cancelled,5 paused), progress(bytes), created, speed_bps?}
```
