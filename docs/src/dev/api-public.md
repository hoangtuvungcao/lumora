# Lumora JSON API (public reference, v1.2)

The commands and events available to bots (through `bot.call(cmd, …)` in the SDKs) and to app integrations.

## Transport

Lumora Bot Runner reads one JSON request per line and writes responses and events as JSON lines.
The bot SDKs ([Python](https://getlumora.pages.dev/developers/sdk/python/lumora_bot.py), [JavaScript](https://getlumora.pages.dev/developers/sdk/js/lumora-bot.mjs)) start
the Bot Runner for you and expose `bot.call(cmd, **args)` / `bot.call(cmd, args)` for any command below.

## Request / response

```json
→ {"id": 7, "cmd": "send_message", "conv": "d:<peer>", "text": "hi"}
← {"id": 7, "ok": true, "data": { ... }}
← {"id": 7, "ok": false, "error": "Nhóm đang bật chế độ chậm. Bạn có thể gửi lại sau 12 giây.", "code": "err.slow_mode"}
← {"id": 7, "ok": false, "error": "Có lỗi xảy ra. Vui lòng thử lại.", "code": "internal", "detail": "<technical cause>"}
```

The top-level `id` is always the request id; command arguments never use the key `id`.

**Errors.** `error` is a plain sentence in the language set with `set_lang` (safe to show to users), `code` is a
stable key (`err.*`, or `internal` for unexpected failures) and `detail` (optional) is the technical cause, for logs.
The SDKs raise these as `LumoraError` with `.code`, `.message` and `.detail`.

**Bots.** Bots may use every command below except remote help, calls, the recovery phrase, backups and passwords;
the SDKs refuse those with `sdk.not_for_bots`. A bot can only message people who messaged it first
(`err.bot_cannot_start`) and joins groups only when a group admin adds it.

**Identifiers.** User ids (`peer`) are 52-character lowercase strings. `short_id` is the 9-digit ID shown to users ("123 456 789").
Usernames are shown as `@name·tag`: the tag belongs to the account, so a handle cannot be impersonated. Bot usernames end with `bot`.
Conversation ids: `d:<peer>` direct chat, `g:<gid hex32>` group/community channel, `s:me` saved messages.
Message, file, call, session and story ids are 32 hex chars. Timestamps are ms since epoch.

## Commands

### Identity & profile
| cmd | args | data |
|---|---|---|
| `ping` | – | `"pong"` |
| `me` | – | `{peer, short_id, name, username, handle, protection, version}` |
| `set_name` | `name` | – |
| `profile` | – | `{name, bio, status, avatar}` |
| `set_profile` | `name?, bio?, status?: "online"\|"away"\|"dnd"\|"invisible", avatar?: base64 (≤ 96 KB)` | profile |
| `set_cover` | `cover` (base64 image) | profile |
| `set_username` | `username` (3–24 chars `a–z 0–9 _`, not starting with `_`; empty = remove) | `{username, handle}` |
| `resolve_username` | `handle` (`@name` or `@name·tag`) | `[{peer, handle, name?, contact}]` |
| `change_passphrase` | `old?, new?` | `{protection}` |
| `set_lang` | `lang: "vi"\|"en"` | `{lang}` |
| `i18n_catalog` | – | `{en:{key:text}, vi:{…}}`. System messages are stored as `body:{code,args,text}`; render `code` with this catalog |

### Contacts
| cmd | args | data |
|---|---|---|
| `contacts` | – | `[Contact]` |
| `add_contact` | `target` (peer, 9-digit short id or `@name·tag`), `note?` | `{peer}` (sends a friend request) |
| `lookup` | `short_id` | `[{peer, name}]` |
| `accept_contact` / `remove_contact` / `block_contact` / `unblock_contact` | `peer` | – |
| `rename_contact` | `peer, alias` | – |
| `verify_contact` | `peer` | `{safety_number, verified}` |
| `mark_verified` | `peer, verified: bool` | – |
| `contact_avatar` / `contact_cover` | `peer` | `{avatar}` / `{cover}` (base64 or null) |

### Conversations & messages
| cmd | args | data |
|---|---|---|
| `conversations` | – | `[Conversation]` (`last_mine`: the last message is mine — show "You:") |
| `messages` | `conv, before?: hlc, limit?: 50` | `[Message]` (oldest → newest; file messages carry `body.preview` and local `file {state, path}`) |
| `send_text` | `conv, text, reply_to?, ttl_ms?, silent?, client_id?` | `Message` (every `send_*` takes `client_id` ≤ 64 chars: a retry with the same id within 24 h returns the first message instead of a duplicate) |
| `send_message` | `conv, text, reply_to?, ttl_ms?, mentions?: [peer], mention_all?, buttons?: [[Button]], silent?` | `Message` (receivers get a `mention` event). Text ≤ 64 KB (`err.message_too_long`); `silent: true` = no sound or notification |
| `edit_message` | `conv, msg_id, text` | – |
| `delete_message` | `conv, msg_id, for_everyone?: true` | – (`false` = delete for me: removed on all your devices, with the copy Lumora downloaded; others keep it) |
| `react` | `conv, msg_id, emoji, on` | – |
| `forward_message` | `msg_id, to_conv` | `Message` (`meta.forwarded_from`) |
| `pin_message` / `pinned_messages` | `conv, msg_id, on` / `conv` | – / `[Message]` |
| `send_poll` / `vote` | `conv, question, options[2..10]` / `conv, msg_id, option` | `Message` / – (votes in `reactions.__votes`) |
| `schedule_message` / `scheduled_messages` / `cancel_scheduled` | `conv, text, at` / – / `sched_id` | – |
| `send_location` | `conv, lat, lon, accuracy_m?, label?, live_minutes?` | `Message` (`live_minutes > 0` = live location) |
| `update_live_location` | `conv, msg_id, lat, lon, accuracy_m?, stop?` | – |
| `send_voice` | `conv, path, duration_ms, wave?: [0..255]` | `Message` |
| `send_contact` | `conv, peer` | `Message` (contact card) |
| `mark_read` | `conv` | – |
| `typing` | `conv, on` | – |
| `seen_by` | `msg_id` | readers of a group message |
| `search` | `q` | `[Message]` |
| `conv_flag` | `conv, flag: "muted"\|"pinned"\|"archived", value` | – |
| `mute` | `conv, until?` (ms timestamp; `0` = unmute; omitted = forever) | `{muted, until}` |
| `set_retention` / `get_retention` | `conv, mode: "forever"\|"session"\|"24h"\|"7d"\|"30d"` / `conv` | – / `{mode}` |
| `clear_history` | `conv, for_everyone?: false` | – |
| `delete_conversation` | `conv, for_everyone?: false` | – |
| `set_wallpaper` / `get_wallpaper` | `conv` (or `"default"`), `wallpaper` / `conv` | – / `{wallpaper}` |

### Checklists & reminders
| cmd | args | data |
|---|---|---|
| `send_checklist` | `conv, title, items: [text] (1..100, ≤ 200 chars), silent?` | `Message` `kind: "checklist"`, body `{title, items: [{id, text}]}` |
| `checklist_toggle` | `conv, msg_id, item (id), done` | – (anyone in the chat; state in `reactions.__checks {"<id>": {done, by, at}}`, newest wins) |
| `checklist_add` | `conv, msg_id, items: [text]` | – (sender only; `message_update {body}`) |
| `send_reminder` | `conv, title, at_ms (future), note?, silent?` | `Message` `kind: "reminder"`, body `{title, at_ms, note}` |
| `reminder_cancel` / `reminder_seen` | `conv, msg_id` | – (cancel: sender only; `reactions.__cancelled` / `reactions.__seen`) |
| `reminders` | – | upcoming `[{conv, msg_id, at_ms, title, note, author}]` on this device |

### Bots
| cmd | args | data |
|---|---|---|
| `set_bot` | `commands: [{command, description}], group_commands?, about?, auto_accept?: true, allow_groups?: true` | – (turns this identity into a bot; clients show the command menu) |
| `send_message` | `…, buttons: [[{text, data?, url?}]]` | `Message` (max 8×8 buttons; `text`/`data` ≤ 64 chars) |
| `press_button` | `msg_id, data` | – (client side: delivers a `callback` event to the message author) |

### Stickers
| cmd | args | data |
|---|---|---|
| `send_sticker` | `conv, hash` (custom) or `conv, pack, sticker` (built-in) | `Message` |
| `sticker_packs` | – | `[pack]` |
| `sticker_pack_create` / `sticker_pack_delete` | `name` / `pack` | pack / – |
| `sticker_add` | `pack, path, emoji?` (PNG/WebP/GIF, animated supported) | sticker |
| `sticker_remove` / `sticker_save` | `hash, pack` | – |
| `sticker_get` | `hash` | `{mime, data}` (base64) |
| `sticker_pack_export` / `sticker_pack_import` | `pack, path` / `path` | result |

### Stories (24 h)
| cmd | args | data |
|---|---|---|
| `post_story` | `text?, image_path?, bg?: "aurora", audience?: "friends" \| "close"` | `{id, recipients}` (friends on `story_hidden` never get it; `close` = only `story_close`) |
| `stories` | – | `[story]` |
| `story_image` | `story_id` | `{image}` (base64) |
| `story_seen` / `story_viewers` | `story_id` | – / viewers |

### Groups & communities
| cmd | args | data |
|---|---|---|
| `create_group` | `name, members[], kind?: 0` (`0` group, `1` community with channels) | `{gid, conv}` |
| `groups` / `spaces` | – | groups / communities with channels |
| `group_info` | `gid` | `{gid, name, owner, members:[{peer,name,role}], epoch, my_role, …}` |
| `group_add` / `group_remove` | `gid, peer` | – |
| `group_set_role` | `gid, peer, role: "admin"\|"member"` | – |
| `group_rename` | `gid, name` | – |
| `group_meta` / `group_avatar` / `group_cover` | `gid, avatar?, description?, cover?` (cover: JPEG ≤ 300 KB base64, `""` removes; communities: admins only) / `gid` / `gid` | – / `{avatar}` / `{cover}` |
| `group_dissolve` | `gid` (owner only) | – ; every member then gets `conversation_removed` + `group_removed {dissolved: true, name, kind}` |
| `group_channel` | `gid, name, voice?, remove?` | – |
| `group_settings` | `gid, slow_mode_s?, admins_only?` (announcement channel) | – |
| `group_ban` | `gid, peer, ban?: true` | – |
| `group_purge_member` | `gid, peer` | – (delete a member's messages) |
| `group_clear_history` | `gid` | – |
| `group_leave` | `gid` | – |
| `group_add_bot` / `group_bot_policy` | `gid, target (bot @name·tag, id or peer), read_all?: false` / `gid, peer, read_all` | `{peer}` / – (admins; `read_all: false` = privacy mode: the bot only gets commands, mentions and replies) |
| `group_visibility` | `gid, public, handle?` | group info (admins; public groups are found by `@handle·tag`) |
| `search_groups` | `q` (`@handle` or `@handle·tag`) | `[{gid, title, members, handle, joined}]` |
| `join_public` | `gid, via` (an admin's peer) | `{pending}` (people only; bots join when an admin adds them) |
| `create_invite` / `inspect_invite` / `join_invite` | `gid, hours?: 168` / `link` / `link` | `{link}` / `{name, valid, already_member}` / `{pending}` |

### Files & storage
| cmd | args | data |
|---|---|---|
| `send_file` | `conv, path, preview?: {kind, text, pages, lines}, thumb_b64?, width?, height?` | `File`. Text files get a preview automatically; `preview.text` ≤ 4 KB, `thumb_b64` = JPEG/PNG/WebP ≤ 64 KB shown before download |
| `accept_file` | `file_id, dir?` | – (downloads into `dir` or the downloads folder; done when the `file` event has `state: 2`) |
| `pause_file` / `cancel_file` | `file_id` | – |
| `files` | – | `[File]` |
| `storage_stats` | – | usage stats (`media_bytes`, `db_bytes`, `by_conv`, `policy`, …) |
| `storage_policy` / `set_storage_policy` | – / `max_cache?, media_days?, community_days?, auto_download?: {wifi?, cell?: {photo?, video?, voice?, file?, file_group?}}` (bytes; 0 = off, 2^50 = always; `auto_direct` / `auto_group` are legacy and no longer decide) | policy |
| `clear_media` | `conv?: "*"` | result |
| `maintain` | – | runs storage cleanup |

### Settings
| cmd | args | data |
|---|---|---|
| `settings_get` | – | `{read_receipts, typing, p2p_only, downloads_dir, …}` |
| `settings_set` | `read_receipts?, typing?, p2p_only?, downloads_dir?, auto_download?, story_hidden?: [id], story_close?: [id]` | – (`p2p_only`: never use a bridge; does **not** hide your IP) |

### Calls
| cmd | args | data |
|---|---|---|
| `call_start` | `conv, video` | `{call_id}` |
| `call_answer` | `call_id, accept` | – |
| `call_end` | `call_id` | – |
| `call_set` | `call_id, mic?, cam?, screen?` | – (`screen` = screen sharing) |
| `voice_join` / `voice_leave` | `conv` (voice channel) | `{call_id}` / – |

### Remote help
| cmd | args | data |
|---|---|---|
| `remote_trust` | `peer, trusted?: true` | – |
| `remote_recent` / `remote_recent_remove` | – / `peer?` | recent devices / – |
| `remote_connect` | `target` (short id or peer), `password`, `view_only` | `{session}` |
| `remote_respond` | `session, accept, control` | – |
| `remote_input` | `session, ev` (see Input events) | – |
| `remote_quality` | `session, preset: "smooth"\|"balanced"\|"sharp"\|"saver"` | `{max_kbps}` |
| `remote_display` | `session, index` | – |
| `remote_clipboard` | `session, text` | – |
| `remote_power` / `remote_allow_power` | `session, action: "lock"\|"restart"\|"logout"` / `allow` | – |
| `remote_end` | `session` | – |
| `diagnostics` | – | `{platform, checks:[{id, ok, title, detail, fix_steps[]}]}` (screen-capture / input permissions) |

### Input events (`remote_input.ev`)
```json
{"t":"move","x":0.5,"y":0.25}
{"t":"button","b":"left","down":true}
{"t":"wheel","dx":0,"dy":-1}
{"t":"key","code":"KeyA","down":true}
{"t":"text","s":"Xin chào"}
```
`x`/`y` are normalised 0..1, `b` is `left|right|middle`, `code` uses W3C `KeyboardEvent.code` names, `text` sends unicode (IME).

## Events (pushed)

| event | payload |
|---|---|
| `ready` | `{peer, short_id}` |
| `presence` | `{peer, online}` |
| `contact` | `Contact` (added/updated) |
| `friend_request` | `{peer, name, note}` |
| `message` | `Message` (new, incoming or outgoing echo) |
| `message_update` | `{conv, id, status?, body?, edited?, deleted?, reactions?, pinned?}` |
| `mention` | `{conv, id, author}` |
| `callback` | `{conv, msg_conv, msg_id, from, data}`: a button on your message was pressed (bots); `msg_conv` is where the message is |
| `bot_user` | `{peer, name}`: a new user added your bot |
| `reminder_due` | `{conv, msg_id, title, note, at_ms, author, mine, late}`: a reminder is due (on every device holding it) |
| `conversation` / `conversation_removed` | `Conversation` / `{conv}` |
| `typing` | `{conv, peer, on}` |
| `group` | group_info payload |
| `story` / `story_view` | `{id, author}` / `{id, viewer}` |
| `file` | `File` (progress / state changes) |
| `call` | `{call_id, conv, peer, state: "ringing"\|"incoming"\|"active"\|"ended", video, participants[]}` |
| `video_stream` | `{call_id, peer, stream}` |
| `remote_request` | `{session, peer, name, view_only}` |
| `remote_state` | `{session, peer, state: "connecting"\|"active"\|"ended"\|"denied", width, height, role: "viewer"\|"host", stream}` |
| `clipboard` | `{peer, text}` |
| `storage_low` | `{message}` |
| `error` | `{message}` |

## Data shapes

```
Contact      {peer, short_id, name, alias, username, handle, status(0 none,1 sent,2 received,3 friend,4 blocked),
              added, last_seen, verified, bio, presence, has_avatar, bot, online}
Conversation {id, kind(0 direct,1 group), title, last_ts, unread, muted, pinned, last_text}
Message      {id, conv, author, hlc, ts, kind("text"|"file"|"sticker"|"voice"|"location"|"contact"|"call"|"system"|"poll"|
              "checklist"|"reminder"), body, status(0 pending,1 sent,2 delivered,3 read,9 failed), edited, deleted, reply_to,
              reactions:{emoji:[peer], __votes?, __checks?, __seen?, __cancelled?}, expires, pinned, silent,
              meta:{mentions, mention_all, forwarded_from, buttons, silent}, mine, file?:{state, progress, size, path, direction}}
File body    {file_id, name, size, mime, hash, thumb (base64|null), width, height, preview?:{kind, text, pages, lines}}
Button       {text, data, url}
File         {id, conv, peer, name, size, hash, path, direction(0 out,1 in),
              state(0 offered,1 transferring,2 done,3 failed,4 cancelled,5 paused), progress(bytes), created, speed_bps?}
```
