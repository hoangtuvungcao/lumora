# Tham chiếu SDK | SDK reference

<!-- Bilingual source for /developers/reference/ (format: see quickstart.md). The per-language
     references are generated from the SDK sources: reference-python.md and reference-js.md. -->

<!-- section: sdks -->
## Hai SDK, một bộ tính năng | Two SDKs, one feature set

<!-- vi -->
SDK Python và JavaScript có cùng tính năng, cùng quy tắc và cùng định dạng lưu trữ. Tên hàm theo thói quen của từng ngôn ngữ: `send_checklist` trong Python là `sendChecklist` trong JavaScript; tham số từ khoá của Python là đối tượng tuỳ chọn trong JavaScript; mọi hàm JavaScript làm việc với Lumora trả về `Promise`.

- [Tham chiếu SDK Python](https://getlumora.pages.dev/developers/reference/python/): tạo tự động từ docstring của `lumora_bot.py`.
- [Tham chiếu SDK JavaScript](https://getlumora.pages.dev/developers/reference/js/): tạo tự động từ JSDoc của `lumora-bot.mjs` (kiểu TypeScript trong `lumora-bot.d.ts`).
- [Tài liệu JSON API](https://getlumora.pages.dev/developers/api/): mọi lệnh gọi được bằng `bot.call(...)`.
<!-- en -->
The Python and JavaScript SDKs have the same features, the same rules and the same storage format. Names follow each language: Python's `send_checklist` is `sendChecklist` in JavaScript; Python keyword arguments become an options object in JavaScript; every JavaScript method that talks to Lumora returns a `Promise`.

- [Python SDK reference](https://getlumora.pages.dev/developers/reference/python/): generated from the docstrings in `lumora_bot.py`.
- [JavaScript SDK reference](https://getlumora.pages.dev/developers/reference/js/): generated from the JSDoc in `lumora-bot.mjs` (TypeScript types in `lumora-bot.d.ts`).
- [JSON API reference](https://getlumora.pages.dev/developers/api/): every command you can run with `bot.call(...)`.
<!-- all -->
| Python | JavaScript |
|---|---|
| `Bot(token=…, data_dir=…, admins=[…])` | `new Bot({ token, dataDir, admins })` |
| `@bot.command("name", "desc", admin_only=True)` | `bot.command("name", "desc", fn, { adminOnly: true })` |
| `@bot.on_text(r"…")` | `bot.onText(/…/, fn)` |
| `@bot.on_message(kinds=["file"], chats="group")` | `bot.onMessage({ kinds: ["file"], chats: "group" }, fn)` |
| `@bot.on_callback(data="buy:*")` | `bot.onCallback({ data: "buy:*" }, fn)` |
| `@bot.on_file(extensions=["csv"])` | `bot.onFile({ extensions: ["csv"] }, fn)` |
| `@bot.middleware` | `bot.use(fn)` |
| `ctx.reply(text, buttons, reply=True, silent=True)` | `ctx.reply(text, { buttons, reply: true, silent: true })` |
| `bot.send_reminder(conv, title, timedelta(minutes=5), note="…")` | `bot.sendReminder(conv, title, { inMs: 300000 }, { note: "…" })` |
| `ctx.download(timeout=120)` (seconds) | `ctx.download({ timeoutMs: 120000 })` |
| `ctx.is_group_admin` (property) | `await ctx.isGroupAdmin()` |
| `bot.storage["k"] = v` | `bot.storage.set("k", v)` |
| `@bot.every(60)` / `@bot.daily("08:00")` | `bot.every(60, fn)` / `bot.daily("08:00", fn)` |
| `except LumoraError as e: e.code` | `catch (e) { e.code }` |

<!-- section: context -->
## Ngữ cảnh (ctx) | The context (ctx)

<!-- vi -->
Mỗi hàm xử lý nhận một `ctx`. Trường không liên quan đến sự kiện thì rỗng hoặc `None`/`null`.
<!-- en -->
Every handler receives a `ctx`. Fields that don't apply to the event are empty or `None`/`null`.
<!-- all -->
| Python | JavaScript | |
|---|---|---|
| `ctx.kind` | `ctx.kind` | `command`, `message`, `callback`, `new_user`, `new_member`, `member_left`, `added_to_group`, `file`, `reminder_due`, `checklist`, `job` |
| `ctx.conv` | `ctx.conv` | `d:<peer>` (direct chat) or `g:<gid>` (group) |
| `ctx.sender`, `ctx.sender_name` | `ctx.sender`, `ctx.senderName` | who caused the event |
| `ctx.text`, `ctx.command`, `ctx.args`, `ctx.match` | same | text, command without `/`, text after it, regex match |
| `ctx.data` | `ctx.data` | button data (callbacks) |
| `ctx.msg_id`, `ctx.reply_to` | `ctx.msgId`, `ctx.replyTo` | message id, quoted message id |
| `ctx.msg_kind`, `ctx.body` | `ctx.msgKind`, `ctx.body` | message kind and body (`lat`/`lon`, `question`…) |
| `ctx.is_group`, `ctx.gid` | `ctx.isGroup`, `ctx.gid` | group chat and its id |
| `ctx.file` | `ctx.file` | `{file_id, name, size, mime, preview, state, path}` |
| `ctx.reminder` | `ctx.reminder` | `{title, note, at_ms, author, mine, late}` |
| `ctx.checklist`, `ctx.changes` | same | `{msg_id, title, items, done, total}`, `[{item, text, done, by}]` |
| `ctx.member` | `ctx.member` | `{peer, name, role}` |
| `ctx.is_admin`, `ctx.has_role(r)`, `ctx.is_group_admin` | `ctx.isAdmin`, `ctx.hasRole(r)`, `await ctx.isGroupAdmin()` | permissions |
| `ctx.reply`, `reply_file`, `reply_checklist`, `reply_reminder`, `reply_poll` | `reply`, `replyFile`, `replyChecklist`, `replyReminder`, `replyPoll` | answer in the same chat |
| `ctx.edit`, `delete`, `pin`, `react`, `typing`, `download` | same | act on the current message |
| `ctx.event` | `ctx.event` | the raw event |

<!-- section: events -->
## Sự kiện | Events

<!-- vi -->
Hàm xử lý nào chạy khi nào. Cột cuối là sự kiện gốc của Lumora (nhận trực tiếp bằng `on_event` / `onEvent`).
<!-- en -->
Which handler runs when. The last column is the raw Lumora event (receive it directly with `on_event` / `onEvent`).
<!-- all -->
| Python | JavaScript | When | Raw event |
|---|---|---|---|
| `command` | `command` | a `/command` the bot handles | `message` |
| `on_text` | `onText` | a text message matching a regex | `message` |
| `on_message` | `onMessage` | any other message (filters: `kinds`, `chats`, `pattern`) | `message` |
| `on_callback` | `onCallback` | a button on the bot's message was pressed | `callback {conv, msg_conv, msg_id, from, data}` |
| `on_new_user` | `onNewUser` | someone opened a chat with the bot for the first time | `bot_user {peer, name}` |
| `on_added_to_group` | `onAddedToGroup` | a group admin added the bot | `group` |
| `on_new_member` | `onNewMember` | someone joined a group (bot has "Read all messages") | `group` |
| `on_member_left` | `onMemberLeft` | someone left or was removed (bot has "Read all messages") | `group` |
| `on_file` | `onFile` | a file was received (filter: `extensions`) | `message` (`kind: "file"`), then `file` |
| `on_reminder_due` | `onReminderDue` | a reminder in one of the bot's chats is due | `reminder_due {conv, msg_id, title, note, at_ms, author, mine, late}` |
| `on_checklist` | `onChecklist` | someone ticked/unticked items, or items were added | `message_update {conv, id, reactions.__checks \| body}` |
| `on_start` | `onStart` | the bot is online (again after an automatic restart) | `ready` |
| `on_error` | `onError` | a handler raised an error | – |
| `every`, `daily`, `after` | same | a scheduled job is due (`ctx.kind == "job"`) | – |
| `on_event(name)` | `onEvent(name, fn)` | any raw event, `"*"` = all | `message_update`, `typing`, `mention`, `contact`, `file`, `presence`… |

<!-- section: errors -->
## Mã lỗi | Error codes

<!-- vi -->
`LumoraError.code` ổn định giữa các phiên bản; `message` là câu dễ hiểu theo ngôn ngữ của bot; `detail` là nguyên nhân kỹ thuật. Bảng dưới là các mã bot hay gặp.
<!-- en -->
`LumoraError.code` is stable across versions; `message` is a plain sentence in the bot's language; `detail` is the technical cause. These are the codes bots meet most often.
<!-- all -->
| Code | Meaning |
|---|---|
| `err.bot_cannot_start` | Bots can only message people who messaged them first. |
| `err.message_too_long` | Text over 64 KB. |
| `err.empty_message` | Empty text. |
| `err.slow_mode` | The group has slow mode on (`{s}` seconds left). |
| `err.admins_only_post` | Only admins may post in this group. |
| `err.admin_only`, `err.no_perm_remove` | The action needs a group admin. |
| `err.group_syncing` | In a group where the bot is in privacy mode: the action needs "Read all messages". |
| `err.group_not_found`, `err.not_member` | Unknown group, or the bot is not in it. |
| `err.message_not_found` | The message doesn't exist (any more). |
| `err.checklist_title`, `err.checklist_items`, `err.checklist_item_missing` | Bad checklist title, item count (1–100) or item id. |
| `err.checklist_owner_only`, `err.reminder_owner_only` | Only the sender may add items / cancel. |
| `err.reminder_title`, `err.reminder_past` | Missing title, or the time is not in the future. |
| `err.poll_options` | A poll needs 2–10 options. |
| `err.too_many_scheduled` | More than 500 scheduled messages. |
| `err.bad_location` | Latitude/longitude out of range. |
| `err.file_not_found`, `err.file_unreadable`, `err.disk_full` | File problems. |
| `err.own_button` | You can't press a button on your own message. |
| `err.bad_bot_token`, `err.bot_token_mismatch` | Wrong/revoked token, or a data folder of another bot. |
| `internal` | Unexpected failure; see `detail` and `runner.log`. |
| `sdk.timeout` | No answer in time (`LumoraTimeout`). |
| `sdk.runner_stopped`, `sdk.runner_failed`, `sdk.runner_missing` | Lumora Bot Runner stopped, could not start, or was not found (`RunnerStopped`). |
| `sdk.not_for_bots` | The command is not available to bots (`NotAllowedForBots`). |
| `sdk.bad_buttons` | More than 8×8 buttons, or text/data over 64 characters. |
| `sdk.preview_too_large` | A preview picture over 64 KB. |
| `sdk.download_failed`, `sdk.no_file` | A download failed or was cancelled; the message has no file. |

<!-- section: changelog -->
## Nhật ký thay đổi | Changelog

<!-- vi -->
Nhật ký thay đổi được viết bằng tiếng Anh.
<!-- en -->
<!-- all -->
{{#include ../../../sdk/CHANGELOG.md:6:}}
