# Python SDK reference

`lumora_bot` 1.1.0 · Python 3.8+ · one file, no dependencies. Generated from the docstrings in `sdk/python/lumora_bot.py` by `sdk/tools/gen_reference.py`; do not edit by hand.

```python
from lumora_bot import Bot, Button, LumoraError
```

## Bot {#bot}

```python
Bot(
    name: str = "",
    data_dir: str = "./lumora-bot",
    binary: Optional[str] = None,
    token: Optional[str] = None,
    about: str = "",
    lan: bool = True,
    public_directory: bool = True,
    workers: int = 4,
    extra_args: Optional[List[str]] = None,
    admins: Optional[List[str]] = None,
    rate_per_sec: float = 15.0,
    *,
    downloads_dir: Optional[str] = None,
    auto_restart: bool = True,
    allow_groups: bool = True,
    lang: Optional[str] = None,
    log_json: Optional[bool] = None,
    log_level: Optional[str] = None,
    runner_log: Optional[str] = None,
    help_command: bool = True,
    deny_text: str = "⛔ Bạn không có quyền dùng lệnh này. / You are not allowed to use this command.",
)
```

A Lumora bot.

**Parameters**

- `name`: Display name for a bot made without BotFather (testing). Not needed with a token.
- `data_dir`: Folder for the bot's identity, messages, storage and downloads. Keep it private and back it up; one folder per bot.
- `binary`: Path to `lumorad` (default: `$LUMORAD`, then `lumorad` on `PATH`).
- `token`: BotFather token (default: `$LUMORA_BOT_TOKEN`). Never hard-code it in public code.
- `about`: Short description shown on the bot's profile.
- `lan`: Also find users on the local network.
- `public_directory`: Let people find the bot by ID / `@name` (turn off for tests).
- `workers`: Handler threads (events of one conversation always run in order).
- `extra_args`: Extra `lumorad` arguments.
- `admins`: Bot admins: peer ids or `@name·tag` handles. They may use `admin_only` commands and pass every role check.
- `rate_per_sec`: Overall send rate (default 15/s; per chat: burst 5, then 1/s).
- `downloads_dir`: Where received files are saved (default `<data_dir>/downloads`).
- `auto_restart`: Restart Lumora Bot Runner if it exits unexpectedly.
- `allow_groups`: Accept being added to groups.
- `lang`: `"vi"` or `"en"`: language of error messages and system texts.
- `log_json`: Log as JSON lines (default: `$LUMORA_BOT_LOG_FORMAT == "json"`).
- `log_level`: `"DEBUG"`, `"INFO"`… (default `$LUMORA_BOT_LOG_LEVEL` or INFO).
- `runner_log`: File for Lumora Bot Runner's own log (default `<data_dir>/runner.log`; `""` to discard).
- `help_command`: Answer `/help` with the command list when you don't define one.
- `deny_text`: Reply sent when someone uses a command they are not allowed to.

### Handlers {#bot-handlers}

| Method | Description |
|---|---|
| [`command`](#bot-command) | Register `/name`. |
| [`on_message`](#bot-on-message) | Handle incoming messages that are not commands. |
| [`on_text`](#bot-on-text) | Handle text messages matching `pattern` (regex, searched anywhere in the text). |
| [`on_callback`](#bot-on-callback) | Handle inline button presses on the bot's messages. |
| [`on_new_user`](#bot-on-new-user) | Called when someone starts a chat with the bot for the first time (`ctx.conv` is their direct chat). |
| [`on_new_member`](#bot-on-new-member) | Called when someone joins a group the bot is in (`ctx.member` = `{peer, name, role}`, `ctx.sender` = the new member, `ctx.conv` = the group). |
| [`on_member_left`](#bot-on-member-left) | Called when a member leaves or is removed from a group (full access needed). |
| [`on_added_to_group`](#bot-on-added-to-group) | Called when a group admin adds the bot to a group (`ctx.conv` = the group). |
| [`on_file`](#bot-on-file) | Handle received files. |
| [`on_reminder_due`](#bot-on-reminder-due) | Called when a reminder in one of the bot's chats is due. |
| [`on_checklist`](#bot-on-checklist) | Called when someone ticks / unticks checklist items or items are added. |
| [`on_event`](#bot-on-event) | Low-level: receive every raw event `name` (`"message_update"`, `"typing"`, `"*"` for all). |
| [`middleware`](#bot-middleware) | Wrap every handled update. |
| [`use`](#bot-use) | Same as `middleware`. |
| [`on_error`](#bot-on-error) | Called with `(ctx, exception)` when a handler raises. |
| [`on_start`](#bot-on-start) | Called once the bot is online (and again after an automatic restart). |

#### `command(name: str, description: str = "", admin_only: bool = False, role: Optional[str] = None, *, chats: str = "all", hidden: bool = False)` {#bot-command}

Register `/name`.

**Parameters**

- `name`: Command name without `/` (`/name@yourbot` works too in groups).
- `description`: Shown in the app's command menu and `/help`.
- `admin_only`: Only bot admins may use it (hidden from the menu).
- `role`: Only users with this bot role (or admins) may use it (hidden from the menu).
- `chats`: `"all"`, `"private"` (direct chats only) or `"group"`.
- `hidden`: Keep it out of the command menu.

**Example**

```python
@bot.command("ban", "Ban a user", admin_only=True, chats="group")
def ban(ctx): ...
```

#### `on_message(fn: Optional[Handler] = None, *, pattern: Union[str, Pattern, None] = None, kinds: Optional[Sequence[str]] = ('text',), chats: str = "all")` {#bot-on-message}

Handle incoming messages that are not commands.

Usable bare (`@bot.on_message`: every text message) or with filters.

**Parameters**

- `pattern`: Regex searched in the text; the first matching handler wins and catch-all handlers don't run. The match is in `ctx.match`.
- `kinds`: Message kinds: `"text"` (default), `"file"`, `"voice"`, `"sticker"`, `"location"`, `"contact"`, `"poll"`, `"checklist"`, `"reminder"`; `None` = all.
- `chats`: `"all"`, `"private"` or `"group"`.

#### `on_text(pattern: Union[str, Pattern], *, chats: str = "all")` {#bot-on-text}

Handle text messages matching `pattern` (regex, searched anywhere in the text).

**Example**

```python
@bot.on_text(r"(?i)\bprice\b")
def price(ctx): ctx.reply("From 25k")
```

#### `on_callback(fn: Optional[Handler] = None, *, data: Optional[str] = None, pattern: Union[str, Pattern, None] = None)` {#bot-on-callback}

Handle inline button presses on the bot's messages.

**Parameters**

- `data`: Only buttons whose data equals this. A value ending in `*` matches by prefix (`data="buy:*"`).
- `pattern`: Regex matched against the data (`ctx.match`).

#### `on_new_user(fn: Handler)` {#bot-on-new-user}

Called when someone starts a chat with the bot for the first time
(`ctx.conv` is their direct chat).

#### `on_new_member(fn: Handler)` {#bot-on-new-member}

Called when someone joins a group the bot is in (`ctx.member` = `{peer, name,
role}`, `ctx.sender` = the new member, `ctx.conv` = the group). `name` is the
9-digit ID when the bot doesn't know the person yet: greet them with
`mentions=[ctx.sender]` instead. Needs full access ("read all") in that group: a
privacy-mode bot is not told about membership changes.

#### `on_member_left(fn: Handler)` {#bot-on-member-left}

Called when a member leaves or is removed from a group (full access needed).

#### `on_added_to_group(fn: Handler)` {#bot-on-added-to-group}

Called when a group admin adds the bot to a group (`ctx.conv` = the group).

#### `on_file(fn: Optional[Handler] = None, *, extensions: Optional[Sequence[str]] = None, chats: str = "all")` {#bot-on-file}

Handle received files. `ctx.file` has `file_id`, `name`, `size`, `mime`
and `preview` (`{kind, text, pages, lines}` or `None`, available before
downloading). Call `ctx.download()` to get the file on disk.

**Parameters**

- `extensions`: Only these file extensions, e.g. `["txt", "csv"]`.

#### `on_reminder_due(fn: Handler)` {#bot-on-reminder-due}

Called when a reminder in one of the bot's chats is due. `ctx.reminder` has
`title`, `note`, `at_ms`, `author`, `mine` and `late`.

#### `on_checklist(fn: Handler)` {#bot-on-checklist}

Called when someone ticks / unticks checklist items or items are added.
`ctx.checklist` = `{msg_id, conv, title, items: [{id, text, done, by, at}],
done, total}`; `ctx.changes` = `[{item, text, done, by}]`. Changes made by the
bot itself are not reported.

#### `on_event(name: str)` {#bot-on-event}

Low-level: receive every raw event `name` (`"message_update"`, `"typing"`,
`"*"` for all). `ctx.event` is the raw dict. Runs in addition to other handlers.

#### `middleware(fn: Callable[[Context, Callable[[], Any]], Any])` {#bot-middleware}

Wrap every handled update. `fn(ctx, next)` must call `next()` to continue;
not calling it stops the update (useful for bans, per-user limits, logging).

**Example**

```python
@bot.middleware
def timing(ctx, next):
    t = time.time(); r = next(); log.info("%s took %.0f ms", ctx.kind, (time.time()-t)*1000); return r
```

#### `use(fn: Callable[[Context, Callable[[], Any]], Any])` {#bot-use}

Same as `middleware` (the name used by the JavaScript SDK).

#### `on_error(fn: Callable[[Context, BaseException], Any])` {#bot-on-error}

Called with `(ctx, exception)` when a handler raises. The error is logged anyway.

#### `on_start(fn: Callable[[], Any])` {#bot-on-start}

Called once the bot is online (and again after an automatic restart).

### Sending messages {#bot-sending}

| Method | Description |
|---|---|
| [`send`](#bot-send) | Send a text message (paced so receivers never see the bot as spam). |
| [`send_file`](#bot-send-file) | Send a file. |
| [`send_poll`](#bot-send-poll) | Send a poll (2–10 options, question ≤ 300 chars). |
| [`send_sticker`](#bot-send-sticker) | Send a built-in sticker (`pack`, `sticker`) or a custom one by `hash`. |
| [`send_location`](#bot-send-location) | Send a location (`live_minutes > 0`: live location you update with `update_live_location`, max 8 h). |
| [`update_live_location`](#bot-update-live-location) | Move a live location, or end it (`stop=True`). |
| [`send_contact`](#bot-send-contact) | Send a contact card of user `peer` (or of the bot itself). |
| [`send_voice`](#bot-send-voice) | Send a voice message (Ogg/Opus file ≤ 32 MB; `wave`: 0–255 bars for the waveform). |
| [`broadcast`](#bot-broadcast) | Send `text` to every user (or `users`), paced (≈ 15 messages/s). |

#### `send(conv: str, text: str, buttons: Buttons = None, reply_to: Optional[str] = None, *, silent: bool = False, mentions: Optional[Sequence[str]] = None, mention_all: bool = False, ttl_ms: Optional[int] = None)` {#bot-send}

Send a text message (paced so receivers never see the bot as spam).

**Parameters**

- `conv`: Conversation id (`d:<peer>`, `g:<gid>`). A bare peer id is accepted.
- `text`: Up to 64 KB of UTF-8 text.
- `buttons`: Inline buttons (rows; max 8×8, text/data ≤ 64 chars).
- `reply_to`: Message id to quote.
- `silent`: No sound or notification on the receivers' devices.
- `mentions`: Peer ids to mention (they get a mention notification).
- `mention_all`: Mention everyone (groups).
- `ttl_ms`: Disappear this many ms after being read.

**Returns**

The sent message (`id`, `conv`, `ts`…).

#### `send_file(conv: str, path: str, *, preview: Union[str, Dict[str, Any], None] = None, thumb: Optional[str] = None)` {#bot-send-file}

Send a file. Text/code files get an automatic preview of their first lines.

**Parameters**

- `conv`: Conversation id.
- `path`: Local file path (readable by Lumora Bot Runner).
- `preview`: Custom preview shown before download: a text snippet (`str`) or `{"kind": "text"|"pdf"|…, "text", "pages", "lines"}`. Text is cut to 4 KB.
- `thumb`: Path to a JPEG/PNG/WebP picture ≤ 64 KB shown with the file (e.g. a chart or the first page of a PDF).

**Returns**

The file transfer entry (`id`, `name`, `size`, `state`…).

#### `send_poll(conv: str, question: str, options: Sequence[str])` {#bot-send-poll}

Send a poll (2–10 options, question ≤ 300 chars). Votes arrive as
`message_update` events (`reactions.__votes`).

#### `send_sticker(conv: str, pack: str = "", sticker: str = "", *, hash: Optional[str] = None)` {#bot-send-sticker}

Send a built-in sticker (`pack`, `sticker`) or a custom one by `hash`.

#### `send_location(conv: str, lat: float, lon: float, label: str = "", *, accuracy_m: float = 0, live_minutes: int = 0)` {#bot-send-location}

Send a location (`live_minutes > 0`: live location you update with
`update_live_location`, max 8 h).

#### `update_live_location(conv: str, msg_id: str, lat: float, lon: float, *, accuracy_m: float = 0, stop: bool = False)` {#bot-update-live-location}

Move a live location, or end it (`stop=True`).

#### `send_contact(conv: str, peer: str)` {#bot-send-contact}

Send a contact card of user `peer` (or of the bot itself).

#### `send_voice(conv: str, path: str, duration_ms: int, wave: Optional[Sequence[int]] = None)` {#bot-send-voice}

Send a voice message (Ogg/Opus file ≤ 32 MB; `wave`: 0–255 bars for the waveform).

#### `broadcast(text: str, buttons: Buttons = None, *, silent: bool = False, users: Optional[Iterable[str]] = None, on_progress: Optional[Callable[[int, int], Any]] = None)` {#bot-broadcast}

Send `text` to every user (or `users`), paced (≈ 15 messages/s).

**Returns**

How many users received it. Failures are logged and skipped.

### Checklists and reminders {#bot-tasks}

| Method | Description |
|---|---|
| [`send_checklist`](#bot-send-checklist) | Send a checklist (1–100 items, ≤ 200 chars each). |
| [`checklist_toggle`](#bot-checklist-toggle) | Tick (`done=True`) or untick item `item` (its id) of a checklist. |
| [`checklist_add`](#bot-checklist-add) | Add items to a checklist the bot sent. |
| [`checklist`](#bot-checklist) | Current state of a checklist: `{msg_id, conv, title, items: [{id, text, done, by, at}], done, total}` or `None` if not found. |
| [`send_reminder`](#bot-send-reminder) | Send a reminder. |
| [`reminder_cancel`](#bot-reminder-cancel) | Cancel a reminder the bot sent. |
| [`reminders`](#bot-reminders) | Upcoming reminders known to the bot (soonest first): `[{conv, msg_id, at_ms, title, note, author}]`. |

#### `send_checklist(conv: str, title: str, items: Sequence[str], *, silent: bool = False)` {#bot-send-checklist}

Send a checklist (1–100 items, ≤ 200 chars each). Anyone in the chat can tick
items; see `on_checklist`.

**Returns**

The message; `body.items` = `[{id, text}]` (ids start at 1).

#### `checklist_toggle(conv: str, msg_id: str, item: int, done: bool = True)` {#bot-checklist-toggle}

Tick (`done=True`) or untick item `item` (its id) of a checklist.

#### `checklist_add(conv: str, msg_id: str, items: Sequence[str])` {#bot-checklist-add}

Add items to a checklist the bot sent.

#### `checklist(conv: str, msg_id: str)` {#bot-checklist}

Current state of a checklist: `{msg_id, conv, title, items: [{id, text, done,
by, at}], done, total}` or `None` if not found.

#### `send_reminder(conv: str, title: str, at: When, note: str = "", *, silent: bool = False)` {#bot-send-reminder}

Send a reminder. Everyone in the chat (and the bot) gets `reminder_due` at
`at`.

**Parameters**

- `title`: ≤ 200 chars. note: ≤ 1000 chars.
- `at`: `datetime`, `timedelta` from now, or epoch ms. Must be in the future.

#### `reminder_cancel(conv: str, msg_id: str)` {#bot-reminder-cancel}

Cancel a reminder the bot sent.

#### `reminders()` {#bot-reminders}

Upcoming reminders known to the bot (soonest first):
`[{conv, msg_id, at_ms, title, note, author}]`.

### Message actions {#bot-actions}

| Method | Description |
|---|---|
| [`edit_message`](#bot-edit-message) | Edit the text of one of the bot's messages. |
| [`delete_message`](#bot-delete-message) | Delete a message. |
| [`pin_message`](#bot-pin-message) | Pin (`on=True`) or unpin a message. |
| [`pinned_messages`](#bot-pinned-messages) | Pinned messages of a conversation. |
| [`react`](#bot-react) | Add (or remove) an emoji reaction. |
| [`forward_message`](#bot-forward-message) | Forward a message to another conversation. |
| [`messages`](#bot-messages) | Recent messages of a conversation, oldest first. |
| [`typing`](#bot-typing) | Show (or hide) "typing…". |
| [`mark_read`](#bot-mark-read) | Mark a conversation as read. |
| [`schedule_message`](#bot-schedule-message) | Let Lumora send `text` at `at` (kept while the bot runs; ≤ 500 pending). |
| [`scheduled_messages`](#bot-scheduled-messages) | Pending scheduled messages. |
| [`cancel_scheduled`](#bot-cancel-scheduled) | Cancel a scheduled message. |

#### `edit_message(conv: str, msg_id: str, text: str)` {#bot-edit-message}

Edit the text of one of the bot's messages.

#### `delete_message(conv: str, msg_id: str, for_everyone: bool = True)` {#bot-delete-message}

Delete a message. In groups, deleting others' messages needs admin rights.

#### `pin_message(conv: str, msg_id: str, on: bool = True)` {#bot-pin-message}

Pin (`on=True`) or unpin a message.

#### `pinned_messages(conv: str)` {#bot-pinned-messages}

Pinned messages of a conversation.

#### `react(conv: str, msg_id: str, emoji: str, on: bool = True)` {#bot-react}

Add (or remove) an emoji reaction.

#### `forward_message(msg_id: str, to_conv: str)` {#bot-forward-message}

Forward a message to another conversation.

#### `messages(conv: str, limit: int = 50, before: Optional[int] = None)` {#bot-messages}

Recent messages of a conversation, oldest first. File messages carry
`body.preview` and `file` (`state`, `path` once downloaded).

#### `typing(conv: str, on: bool = True)` {#bot-typing}

Show (or hide) "typing…".

#### `mark_read(conv: str)` {#bot-mark-read}

Mark a conversation as read.

#### `schedule_message(conv: str, text: str, at: When)` {#bot-schedule-message}

Let Lumora send `text` at `at` (kept while the bot runs; ≤ 500 pending).
Returns `{id, conv, text, at}`.

#### `scheduled_messages()` {#bot-scheduled-messages}

Pending scheduled messages.

#### `cancel_scheduled(sched_id: str)` {#bot-cancel-scheduled}

Cancel a scheduled message.

### Files {#bot-files}

| Method | Description |
|---|---|
| [`files`](#bot-files) | All file transfers (`id`, `conv`, `name`, `size`, `state`, `path`, `direction`, `preview`…). |
| [`accept_file`](#bot-accept-file) | Start (or resume) downloading a received file into `dir` (default: `downloads_dir`). |
| [`cancel_file`](#bot-cancel-file) | Stop a transfer. |
| [`download_file`](#bot-download-file) | Download a received file and wait until it is complete. |

#### `files()` {#bot-files}

All file transfers (`id`, `conv`, `name`, `size`, `state`, `path`,
`direction`, `preview`…). `state`: 0 offered, 1 transferring, 2 done,
3 failed, 4 cancelled, 5 paused.

#### `accept_file(file_id: str, dir: Optional[str] = None)` {#bot-accept-file}

Start (or resume) downloading a received file into `dir`
(default: `downloads_dir`).

#### `cancel_file(file_id: str)` {#bot-cancel-file}

Stop a transfer.

#### `download_file(file_id: str, dir: Optional[str] = None, timeout: float = 300)` {#bot-download-file}

Download a received file and wait until it is complete. Returns the local path.

Small files from users are downloaded automatically; this also works for those.

**Raises**

- `LumoraError`: `sdk.download_failed` (failed / cancelled) or `sdk.timeout`.

### Groups {#bot-groups}

| Method | Description |
|---|---|
| [`groups`](#bot-groups) | Groups the bot is in (`gid`, `conv`, `name`, `members`, `my_role`, `bots` [{peer, read_all}], `slow_mode_s`…). |
| [`group_info`](#bot-group-info) | Details of a group (`group`: gid or `g:` conversation id). |
| [`group_access`](#bot-group-access) | What the bot may do in a group: `{"read_all": bool, "admin": bool}`. |
| [`member_role`](#bot-member-role) | Role of `peer` in a group: `"owner"`, `"admin"`, `"member"` or `None`. |
| [`group_ban`](#bot-group-ban) | Ban (or unban) a member: removes them and stops them from rejoining. |
| [`group_unban`](#bot-group-unban) | Lift a ban. |
| [`group_remove`](#bot-group-remove) | Remove (kick) a member; they may be added again. |
| [`group_settings`](#bot-group-settings) | Change group settings (admin): `slow_mode_s` (seconds between two messages of a member, 0 = off) and `admins_only` (only admins may post). |
| [`set_slow_mode`](#bot-set-slow-mode) | Shortcut for `group_settings(group, slow_mode_s=seconds)`. |
| [`group_purge_member`](#bot-group-purge-member) | Delete every message of `peer` in the group (admin; e.g. |
| [`group_leave`](#bot-group-leave) | Leave a group. |
| [`search_groups`](#bot-search-groups) | Find public groups by `@handle` or `@handle·tag` (read-only; bots join a group only when one of its admins adds them). |

#### `groups()` {#bot-groups}

Groups the bot is in (`gid`, `conv`, `name`, `members`, `my_role`,
`bots` [{peer, read_all}], `slow_mode_s`…).

#### `group_info(group: str)` {#bot-group-info}

Details of a group (`group`: gid or `g:` conversation id).

#### `group_access(group: str)` {#bot-group-access}

What the bot may do in a group: `{"read_all": bool, "admin": bool}`.
`read_all` = an admin allowed "read all messages" (full access); `admin` = the
bot is a group admin (needed for ban / slow mode / purge / delete others').

#### `member_role(group: str, peer: str)` {#bot-member-role}

Role of `peer` in a group: `"owner"`, `"admin"`, `"member"` or `None`.

#### `group_ban(group: str, peer: str, ban: bool = True)` {#bot-group-ban}

Ban (or unban) a member: removes them and stops them from rejoining.
The bot must be a group admin with full access.

#### `group_unban(group: str, peer: str)` {#bot-group-unban}

Lift a ban.

#### `group_remove(group: str, peer: str)` {#bot-group-remove}

Remove (kick) a member; they may be added again. Needs admin rights.

#### `group_settings(group: str, *, slow_mode_s: Optional[int] = None, admins_only: Optional[bool] = None)` {#bot-group-settings}

Change group settings (admin): `slow_mode_s` (seconds between two messages of
a member, 0 = off) and `admins_only` (only admins may post).

#### `set_slow_mode(group: str, seconds: int)` {#bot-set-slow-mode}

Shortcut for `group_settings(group, slow_mode_s=seconds)`.

#### `group_purge_member(group: str, peer: str)` {#bot-group-purge-member}

Delete every message of `peer` in the group (admin; e.g. after spam).

#### `group_leave(group: str)` {#bot-group-leave}

Leave a group.

#### `search_groups(query: str)` {#bot-search-groups}

Find public groups by `@handle` or `@handle·tag` (read-only; bots join a
group only when one of its admins adds them).

### Users and profile {#bot-users}

| Method | Description |
|---|---|
| [`users`](#bot-users) | Everyone who started a chat with the bot (peer ids). |
| [`contacts`](#bot-contacts) | Full user entries (`peer`, `short_id`, `name`, `handle`, `online`…). |
| [`name_of`](#bot-name-of) | Display name of a user (cached; falls back to the 9-digit ID). |
| [`resolve_username`](#bot-resolve-username) | Look up `@name` / `@name·tag`: `[{peer, handle, name?, contact}]`. |
| [`block_user`](#bot-block-user) | Block a user: they can no longer message the bot. |
| [`unblock_user`](#bot-unblock-user) | Unblock a user. |
| [`set_profile`](#bot-set-profile) | Update the bot's profile. |
| [`set_commands`](#bot-set-commands) | Publish the command menu again (done automatically at start). |

#### `users()` {#bot-users}

Everyone who started a chat with the bot (peer ids).

#### `contacts()` {#bot-contacts}

Full user entries (`peer`, `short_id`, `name`, `handle`, `online`…).

#### `name_of(peer: str)` {#bot-name-of}

Display name of a user (cached; falls back to the 9-digit ID).

#### `resolve_username(handle: str)` {#bot-resolve-username}

Look up `@name` / `@name·tag`: `[{peer, handle, name?, contact}]`.

#### `block_user(peer: str)` {#bot-block-user}

Block a user: they can no longer message the bot.

#### `unblock_user(peer: str)` {#bot-unblock-user}

Unblock a user.

#### `set_profile(*, name: Optional[str] = None, bio: Optional[str] = None, avatar: Optional[str] = None)` {#bot-set-profile}

Update the bot's profile. `avatar`: path to an image (≤ 96 KB).

#### `set_commands()` {#bot-set-commands}

Publish the command menu again (done automatically at start).

### Jobs (scheduled tasks) {#bot-jobs}

| Method | Description |
|---|---|
| [`every`](#bot-every) | Run `fn()` every `seconds` (decorator or direct call). |
| [`daily`](#bot-daily) | Run `fn()` every day at local time `"HH:MM"` (decorator or direct call). |
| [`after`](#bot-after) | Run `fn()` once, `seconds` from now. |
| [`cancel`](#bot-cancel) | Cancel a job returned by `every`, `daily` or `after`. |

#### `every(seconds: float, fn: Optional[Callable[[], Any]] = None, *, first_in: Optional[float] = None)` {#bot-every}

Run `fn()` every `seconds` (decorator or direct call). Returns the job;
`bot.cancel(job)` stops it.

#### `daily(at: str, fn: Optional[Callable[[], Any]] = None)` {#bot-daily}

Run `fn()` every day at local time `"HH:MM"` (decorator or direct call).

#### `after(seconds: float, fn: Callable[[], Any])` {#bot-after}

Run `fn()` once, `seconds` from now. Returns the job.

#### `cancel(job: dict)` {#bot-cancel}

Cancel a job returned by `every`, `daily` or `after`.

### Lifecycle {#bot-lifecycle}

| Method | Description |
|---|---|
| [`start`](#bot-start) | Start Lumora Bot Runner and go online (non-blocking). |
| [`run`](#bot-run) | Start and block until stopped (Ctrl+C, SIGTERM or `stop`). |
| [`stop`](#bot-stop) | Stop gracefully: no new events, wait up to `timeout` s for running handlers, then close Lumora Bot Runner (it saves everything and exits). |

#### `start()` {#bot-start}

Start Lumora Bot Runner and go online (non-blocking). See `run`.

#### `run()` {#bot-run}

Start and block until stopped (Ctrl+C, SIGTERM or `stop`). Shuts down
gracefully: running handlers finish, then Lumora Bot Runner exits.

#### `stop(timeout: float = 10)` {#bot-stop}

Stop gracefully: no new events, wait up to `timeout` s for running handlers,
then close Lumora Bot Runner (it saves everything and exits).

### Low-level API {#bot-lowlevel}

| Method | Description |
|---|---|
| [`call`](#bot-call) | Run any command of the Lumora JSON API and return its `data`. |
| [`acall`](#bot-acall) | Awaitable `call` (runs in a thread, safe from any event loop). |
| [`aio`](#bot-aio) | Awaitable versions of every method: `await bot.aio.send(conv, "hi")`. |

#### `call(cmd: str, timeout: float = 60, **args)` {#bot-call}

Run any command of the Lumora JSON API and return its `data`.

Commands bots may not use (remote control, recovery phrase, backups, passwords,
calls) raise `NotAllowedForBots`.

**Raises**

- `LumoraError`: the command failed (`.code`, `.message`, `.detail`).
- `LumoraTimeout`: no answer within `timeout` seconds.
- `RunnerStopped`: Lumora Bot Runner is not running.

#### `acall(cmd: str, timeout: float = 60, **args)` {#bot-acall}

*async*

Awaitable `call` (runs in a thread, safe from any event loop).

#### `aio` {#bot-aio}

*property*

Awaitable versions of every method: `await bot.aio.send(conv, "hi")`.

## Context {#context}

What a handler receives: the event plus shortcuts to answer it.

Common attributes (empty / `None` when not relevant to the event):

- `kind`: `"command"`, `"message"`, `"callback"`, `"new_user"`,
`"new_member"`, `"member_left"`, `"added_to_group"`, `"file"`,
`"reminder_due"`, `"checklist"`, `"job"` or the raw event name.
- `conv`: conversation id (`d:<peer>` direct chat, `g:<gid>` group).
- `sender`: the user who caused the event; `sender_name`: their display name.
- `text`, `command`, `args`, `match` (regex match of `on_text`).
- `data`: button data (callbacks). `msg_id`: message id.
- `msg_kind` and `body`: message kind (`"text"`, `"file"`, `"location"`…) and body.
- `is_group`, `gid`: group chat and its id.
- `file`: file info (`on_file`); `reminder`; `checklist` and `changes`;
`member` (`on_new_member`).
- `event`: the raw event dict.

#### `is_group` {#context-is-group}

*property*

True when the event happened in a group or community channel.

#### `gid` {#context-gid}

*property*

Group id for group events, else `None`.

#### `sender_name` {#context-sender-name}

*property*

Display name of `sender` (falls back to the 9-digit ID).

#### `is_admin` {#context-is-admin}

*property*

True when the sender is one of this bot's admins (`Bot(admins=[...])`).

#### `has_role(role: str)` {#context-has-role}

True when the sender has bot role `role` (bot admins always do).

#### `is_group_admin` {#context-is-group-admin}

*property*

True when the sender is an admin or the owner of the current group.

#### `aio` {#context-aio}

*property*

Awaitable versions of this context's methods: `await ctx.aio.reply("hi")`.

#### `reply(text: str, buttons: Buttons = None, reply: bool = False, *, silent: bool = False, mentions: Optional[Sequence[str]] = None, mention_all: bool = False)` {#context-reply}

Send `text` to the same conversation.

**Parameters**

- `text`: Message text (max 64 KB).
- `buttons`: Inline buttons, see `Button`.
- `reply`: Quote the message being answered.
- `silent`: Deliver without sound or notification.
- `mentions`: Users (peer ids) to mention.
- `mention_all`: Mention everyone in a group.

**Returns**

The sent message.

#### `reply_file(path: str, preview: Union[str, Dict[str, Any], None] = None, *, thumb: Optional[str] = None)` {#context-reply-file}

Send a file to the same conversation (see `send_file`).

#### `send_file(path: str)` {#context-send-file}

Send a file to the same conversation (kept for older bots; prefer `reply_file`).

#### `reply_checklist(title: str, items: Sequence[str], *, silent: bool = False)` {#context-reply-checklist}

Send a checklist to the same conversation.

#### `reply_reminder(title: str, at: When, note: str = "", *, silent: bool = False)` {#context-reply-reminder}

Send a reminder to the same conversation.

#### `reply_poll(question: str, options: Sequence[str])` {#context-reply-poll}

Send a poll to the same conversation.

#### `react(emoji: str, on: bool = True)` {#context-react}

React to the current message with `emoji` (`on=False` removes it).

#### `edit(text: str)` {#context-edit}

Edit the current message. For callbacks that is the bot's message whose button
was pressed, so `ctx.edit("Done ✅")` updates it in place.

#### `delete(for_everyone: bool = True)` {#context-delete}

Delete the current message (others' messages in groups need admin rights).

#### `pin(on: bool = True)` {#context-pin}

Pin (or unpin) the current message.

#### `typing(on: bool = True)` {#context-typing}

Show (or hide) "typing…" in this conversation.

#### `download(dir: Optional[str] = None, timeout: float = 300)` {#context-download}

Download the file of this message (`on_file`) and return its local path.

## Storage {#storage}

*class* `Storage(dict)`

A `dict` saved as JSON in the bot's data folder (`bot-storage.json`).

Setting or deleting a top-level key saves the file atomically. If you change a nested
value in place (`bot.storage["list"].append(x)`) call `save` afterwards, or use
`update_key`. Values must be JSON-serialisable. Thread-safe.

#### `save()` {#storage-save}

Write the whole store to disk now (atomic replace).

#### `setdefault(k, default = None)` {#storage-setdefault}



#### `update(*a, **kw)` {#storage-update}



#### `pop(k, *default)` {#storage-pop}



#### `update_key(key: str, fn: Callable[[Any], Any], default: Any = None)` {#storage-update-key}

Atomically replace `storage[key]` with `fn(old)` and save. Returns the new value.

Example: `bot.storage.update_key("visits", lambda n: n + 1, 0)`

## Roles {#roles}

Bot-level roles (`"mod"`, `"vip"`…) kept in storage: user → set of roles.

These are *your bot's* roles, separate from group admins. Bot admins
(`Bot(admins=[...])`) pass every role check.

#### `grant(peer: str, role: str)` {#roles-grant}

Give `role` to user `peer`.

#### `revoke(peer: str, role: str)` {#roles-revoke}

Take `role` away from user `peer`.

#### `of(peer: str)` {#roles-of}

Roles of `peer` (a set, empty when none).

#### `members(role: str)` {#roles-members}

Users that have `role`.

## Button {#button}

*class* `Button(dict)`

An inline button. `Button("Buy", data="buy:42")` or `Button("Site", url="https://…")`.

`text` and `data` are at most 64 characters. Pressing a data button sends a
`callback` to the bot (`@bot.on_callback`); a URL button opens the link.

`Button(text: str, data: str = "", url: str = "")`

## LumoraError {#lumoraerror}

*class* `LumoraError(RuntimeError)`

Error returned by Lumora (or raised by the SDK).

**Attributes**

- `code`: Stable machine key, e.g. `"err.slow_mode"`, `"err.admin_only"`, `"internal"`, or `"sdk.*"` for errors raised by the SDK itself.
- `message`: Plain sentence in the bot's language (`Bot(lang=...)`), safe to show.
- `detail`: Technical cause (may be `None`). Log it, don't show it to users.
- `cmd`: The command that failed (`"send_message"`…), when known.

`LumoraError(message: str, code: Optional[str] = None, detail: Optional[str] = None, cmd: Optional[str] = None)`

#### `to_dict()` {#lumoraerror-to-dict}

`{"error", "code", "detail", "cmd"}` for structured logs.

## LumoraTimeout {#lumoratimeout}

*class* `LumoraTimeout(LumoraError, TimeoutError)`

A request got no answer in time (code `sdk.timeout`).

## RunnerStopped {#runnerstopped}

*class* `RunnerStopped(LumoraError)`

Lumora Bot Runner is not running, or stopped while a request was pending
(code `sdk.runner_stopped`).

## NotAllowedForBots {#notallowedforbots}

*class* `NotAllowedForBots(LumoraError)`

The command is not available to bots (code `sdk.not_for_bots`).

## Helpers {#helpers}

#### `gid_of(conv_or_gid: str)` {#gid-of}

Group id (32 hex chars) from a group conversation id (`g:<gid>` or
`g:<gid>#channel`) or a bare gid. Raises `ValueError` for direct chats.

#### `conv_of(peer_or_gid: str)` {#conv-of}

Conversation id for a user (`d:<peer>`) or a group gid (`g:<gid>`).
Conversation ids are returned unchanged.

#### `is_group_conv(conv: str)` {#is-group-conv}

True for group / community channel conversations (`g:…`).

#### `is_blocked_command(cmd: str)` {#is-blocked-command}

True when `cmd` is a core command bots may not use (remote control, recovery
phrase, backups, passwords, calls, BotFather management).

## Constants {#constants}

| Name | Value | Meaning |
|---|---|---|
| `MAX_TEXT_BYTES` | 65536 | Text message size (UTF-8 bytes) |
| `MAX_BUTTON_ROWS` | 8 | Button rows |
| `MAX_BUTTONS_PER_ROW` | 8 | Buttons per row |
| `MAX_BUTTON_TEXT` | 64 | Button text length |
| `MAX_BUTTON_DATA` | 64 | Button data length |
| `MAX_PREVIEW_TEXT_BYTES` | 4096 | File preview text |
| `MAX_PREVIEW_IMAGE_BYTES` | 65536 | File preview picture |
| `MAX_CHECKLIST_ITEMS` | 100 | Checklist items |
| `MAX_TASK_TEXT` | 200 | Checklist item / reminder title length |
| `MAX_REMINDER_NOTE` | 1000 | Reminder note length |
