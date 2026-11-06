# JavaScript SDK reference

`lumora-bot` 1.1.0 · Node.js 18+ · ES module, no dependencies, TypeScript types in `lumora-bot.d.ts`. Generated from the JSDoc in `sdk/js/lumora-bot.mjs` by `sdk/tools/gen_reference.py`; do not edit by hand. Every method that talks to Lumora returns a `Promise`.

```js
import { Bot, Button, LumoraError } from "lumora-bot";
```

## Bot {#bot}

`new Bot(options?)`

A Lumora bot.

Options: `name` (display name for a bot made without BotFather, for tests), `token`
(BotFather token; default `$LUMORA_BOT_TOKEN`, never hard-code it in public code),
`dataDir` (identity, messages, storage and downloads; default `./lumora-bot`, one folder
per bot, keep it private and back it up), `binary` (path to `lumorad`; default
`$LUMORAD`, then `lumorad`), `about`, `lan` (also find users on the local network),
`publicDirectory` (let people find the bot by ID / @name), `extraArgs`, `admins` (peer ids
or `@name·tag` handles), `ratePerSec` (overall send rate, default 15/s; per chat: burst 5,
then 1/s), `downloadsDir` (default `<dataDir>/downloads`), `autoRestart` (default true),
`allowGroups` (default true), `lang` (`"vi"`/`"en"`: error message language), `logJson`,
`logLevel`, `runnerLog` (Lumora Bot Runner's own log; default `<dataDir>/runner.log`,
`""` discards), `helpCommand` (auto `/help`, default true), `denyText`.

```js
const bot = new Bot({ token: process.env.LUMORA_BOT_TOKEN, admins: ["@owner·k7q2xz"] });
```

### Handlers {#bot-handlers}

| Method | Description |
|---|---|
| [`command`](#bot-command) | Register `/name`. |
| [`onMessage`](#bot-on-message) | Handle incoming messages that are not commands. |
| [`onText`](#bot-on-text) | Handle text messages matching `pattern` (regex, searched anywhere in the text). |
| [`onCallback`](#bot-on-callback) | Handle inline button presses on the bot's messages. |
| [`onNewUser`](#bot-on-new-user) | Called when someone starts a chat with the bot for the first time (`ctx.conv` is their direct chat). |
| [`onNewMember`](#bot-on-new-member) | Called when someone joins a group the bot is in (`ctx.member` = `{peer, name, role}`, `ctx.sender` = the new member, `ctx.conv` = the group). |
| [`onMemberLeft`](#bot-on-member-left) | Called when a member leaves or is removed from a group (full access needed). |
| [`onAddedToGroup`](#bot-on-added-to-group) | Called when a group admin adds the bot to a group (`ctx.conv` = the group). |
| [`onFile`](#bot-on-file) | Handle received files. |
| [`onReminderDue`](#bot-on-reminder-due) | Called when a reminder in one of the bot's chats is due. |
| [`onChecklist`](#bot-on-checklist) | Called when someone ticks / unticks checklist items or items are added. |
| [`onEvent`](#bot-on-event) | Low-level: receive every raw event `name` (`"message_update"`, `"typing"`, `"*"` for all). |
| [`middleware`](#bot-middleware) | Alias of `use`. |
| [`use`](#bot-use) | Wrap every handled update. |
| [`onError`](#bot-on-error) | Called with `(ctx, error)` when a handler throws. |
| [`onStart`](#bot-on-start) | Called once the bot is online (and again after an automatic restart). |

#### `command(name, description, fn, options?)` {#bot-command}

Register `/name`.

**Parameters**

- `name` `string`: Command name without `/` (`/name@yourbot` works too in groups).
- `description` `string`: Shown in the app's command menu and `/help`.
- `fn` `Handler`: Handler.
- `options` `CommandOptions` (optional): `{adminOnly, role, chats: "all"|"private"|"group", hidden}`. `adminOnly` / `role` restrict who may use it and hide it from the menu.

**Returns** `this`: The bot (chainable).

```js
bot.command("ban", "Ban a user", (ctx) => …, { adminOnly: true, chats: "group" });
```

#### `onMessage(fnOrFilter, filterOrFn?)` {#bot-on-message}

Handle incoming messages that are not commands. `onMessage(fn)` gets every text message;
filters: `pattern` (regex searched in the text; the first matching handler wins and
catch-all handlers don't run; the match is in `ctx.match`), `kinds` (default `["text"]`;
also `"file"`, `"voice"`, `"sticker"`, `"location"`, `"contact"`, `"poll"`,
`"checklist"`, `"reminder"`; `null` = all), `chats` (`"all"`, `"private"`, `"group"`).

**Parameters**

- `fnOrFilter` `Handler|MessageFilter`: Handler, or the filter.
- `filterOrFn` `Handler|MessageFilter` (optional): The other one.

**Returns** `this`: The bot (chainable).

```js
bot.onMessage({ kinds: ["location"] }, (ctx) => ctx.reply(`📍 ${ctx.body.lat}, ${ctx.body.lon}`));
```

#### `onText(pattern, fn, options?)` {#bot-on-text}

Handle text messages matching `pattern` (regex, searched anywhere in the text).

**Parameters**

- `pattern` `RegExp|string`: Pattern.
- `fn` `Handler`: Handler.
- `options` `{chats?: Chats}` (optional): Options.

**Returns** `this`: The bot (chainable).

```js
bot.onText(/\bprice\b/i, (ctx) => ctx.reply("From 25k"));
```

#### `onCallback(fnOrFilter, filterOrFn?)` {#bot-on-callback}

Handle inline button presses on the bot's messages. Filters: `data` (exact; ending in
`*` = prefix, e.g. `"buy:*"`), `pattern` (regex on the data, `ctx.match`).

**Parameters**

- `fnOrFilter` `Handler|CallbackFilter`: Handler, or the filter.
- `filterOrFn` `Handler|CallbackFilter` (optional): The other one.

**Returns** `this`: The bot (chainable).

#### `onNewUser(fn)` {#bot-on-new-user}

Called when someone starts a chat with the bot for the first time (`ctx.conv` is their
direct chat).

**Parameters**

- `fn` `Handler`: Handler.

**Returns** `this`: The bot.

#### `onNewMember(fn)` {#bot-on-new-member}

Called when someone joins a group the bot is in (`ctx.member` = `{peer, name, role}`,
`ctx.sender` = the new member, `ctx.conv` = the group). `name` is the 9-digit ID when the
bot doesn't know the person yet: greet them with `{ mentions: [ctx.sender] }` instead.
Needs full access ("read all") in that group: a privacy-mode bot is not told about
membership changes.

**Parameters**

- `fn` `Handler`: Handler.

**Returns** `this`: The bot.

#### `onMemberLeft(fn)` {#bot-on-member-left}

Called when a member leaves or is removed from a group (full access needed).

**Parameters**

- `fn` `Handler`: Handler.

**Returns** `this`: The bot.

#### `onAddedToGroup(fn)` {#bot-on-added-to-group}

Called when a group admin adds the bot to a group (`ctx.conv` = the group).

**Parameters**

- `fn` `Handler`: Handler.

**Returns** `this`: The bot.

#### `onFile(fnOrFilter, filterOrFn?)` {#bot-on-file}

Handle received files. `ctx.file` has `file_id`, `name`, `size`, `mime` and `preview`
(`{kind, text, pages, lines}` or null, available before downloading). Call
`await ctx.download()` to get the file on disk. Filter: `extensions` (e.g.
`["txt", "csv"]`; such handlers win over catch-alls), `chats`.

**Parameters**

- `fnOrFilter` `Handler|FileFilter`: Handler, or the filter.
- `filterOrFn` `Handler|FileFilter` (optional): The other one.

**Returns** `this`: The bot (chainable).

#### `onReminderDue(fn)` {#bot-on-reminder-due}

Called when a reminder in one of the bot's chats is due. `ctx.reminder` has `title`,
`note`, `at_ms`, `author`, `mine` and `late`.

**Parameters**

- `fn` `Handler`: Handler.

**Returns** `this`: The bot.

#### `onChecklist(fn)` {#bot-on-checklist}

Called when someone ticks / unticks checklist items or items are added.
`ctx.checklist` = `{msg_id, conv, title, items: [{id, text, done, by, at}], done, total}`;
`ctx.changes` = `[{item, text, done, by}]`. Changes made by the bot itself are not reported.

**Parameters**

- `fn` `Handler`: Handler.

**Returns** `this`: The bot.

#### `onEvent(name, fn)` {#bot-on-event}

Low-level: receive every raw event `name` (`"message_update"`, `"typing"`, `"*"` for
all). `ctx.event` is the raw object. Runs in addition to other handlers.

**Parameters**

- `name` `string`: Event name.
- `fn` `Handler`: Handler.

**Returns** `this`: The bot (chainable).

#### `middleware(fn)` {#bot-middleware}

Alias of `use`.

**Parameters**

- `fn` `Middleware`: Middleware.

**Returns** `this`: The bot.

#### `use(fn)` {#bot-use}

Wrap every handled update. `fn(ctx, next)` must `await next()` to continue; not calling
it stops the update (bans, per-user limits, logging).

**Parameters**

- `fn` `Middleware`: Middleware.

**Returns** `this`: The bot (chainable).

```js
bot.use(async (ctx, next) => { const t = Date.now(); await next(); bot.log.info("handled", { kind: ctx.kind, ms: Date.now() - t }); });
```

#### `onError(fn)` {#bot-on-error}

Called with `(ctx, error)` when a handler throws. The error is logged anyway.

**Parameters**

- `fn` `(ctx: Context, err: unknown) => any`: Error handler.

**Returns** `this`: The bot.

#### `onStart(fn)` {#bot-on-start}

Called once the bot is online (and again after an automatic restart).

**Parameters**

- `fn` `() => any`: Hook.

**Returns** `this`: The bot.

### Sending messages {#bot-sending}

| Method | Description |
|---|---|
| [`send`](#bot-send) | Send a text message (paced so receivers never see the bot as spam). |
| [`sendFile`](#bot-send-file) | Send a file. |
| [`sendPoll`](#bot-send-poll) | Send a poll (2–10 options, question ≤ 300 chars). |
| [`sendSticker`](#bot-send-sticker) | Send a built-in sticker (`pack`, `sticker`) or a custom one by `{hash}`. |
| [`sendLocation`](#bot-send-location) | Send a location (`liveMinutes > 0`: live location, update with `updateLiveLocation`, max 8 h). |
| [`updateLiveLocation`](#bot-update-live-location) | Move a live location, or end it (`stop: true`). |
| [`sendContact`](#bot-send-contact) | Send a contact card of user `peer` (or of the bot itself). |
| [`sendVoice`](#bot-send-voice) | Send a voice message (Ogg/Opus file ≤ 32 MB; `wave`: 0–255 bars for the waveform). |
| [`broadcast`](#bot-broadcast) | Send `text` to every user (or `users`), paced (≈ 15 messages/s). |

#### `send(conv, text, buttonsOrOptions?, options?)` {#bot-send}

*async*

Send a text message (paced so receivers never see the bot as spam).

**Parameters**

- `conv` `string`: Conversation id (`d:<peer>`, `g:<gid>`); a bare peer id works too.
- `text` `string`: Up to 64 KB of UTF-8 text.
- `buttonsOrOptions` `Buttons|SendOptions` (optional): Buttons, or the options object.
- `options` `SendOptions` (optional): `{buttons, replyTo, silent, mentions, mentionAll, ttlMs}`: `silent` = no sound/notification; `mentions` = peer ids; `ttlMs` = disappear after read.

**Returns** `Promise<Message>`: The sent message.

```js
await bot.send(conv, "Sale today!", { silent: true, buttons: [[Button("Open", "open")]] });
```

#### `sendFile(conv, path, options?)` {#bot-send-file}

*async*

Send a file. Text/code files get an automatic preview of their first lines.

**Parameters**

- `conv` `string`: Conversation id.
- `path` `string`: Local file path.
- `options` `FileOptions` (optional): `preview`: a text snippet (string) or `{kind, text, pages, lines}` shown before download (text cut to 4 KB); `thumb`: path to a JPEG/PNG/WebP ≤ 64 KB shown with the file.

**Returns** `Promise<FileEntry>`: The file transfer entry.

#### `sendPoll(conv, question, options)` {#bot-send-poll}

*async*

Send a poll (2–10 options, question ≤ 300 chars). Votes arrive as `message_update` events.

**Parameters**

- `conv` `string`: Conversation id.
- `question` `string`: Question.
- `options` `string[]`: Options.

**Returns** `Promise<Message>`: The message.

#### `sendSticker(conv, pack?, sticker?, options?)` {#bot-send-sticker}

*async*

Send a built-in sticker (`pack`, `sticker`) or a custom one by `{hash}`.

**Parameters**

- `conv` `string`: Conversation id.
- `pack` `string` (optional): Pack.
- `sticker` `string` (optional): Sticker id.
- `options` `{hash?: string}` (optional): Custom sticker hash.

**Returns** `Promise<Message>`: The message.

#### `sendLocation(conv, lat, lon, label?, options?)` {#bot-send-location}

*async*

Send a location (`liveMinutes > 0`: live location, update with `updateLiveLocation`, max 8 h).

**Parameters**

- `conv` `string`: Conversation id.
- `lat` `number`: Latitude.
- `lon` `number`: Longitude.
- `label` `string` (optional, default `""`): Label.
- `options` `{accuracyM?: number, liveMinutes?: number}` (optional): Options.

**Returns** `Promise<Message>`: The message.

#### `updateLiveLocation(conv, msgId, lat, lon, options?)` {#bot-update-live-location}

*async*

Move a live location, or end it (`stop: true`).

**Parameters**

- `conv` `string`: Conversation id.
- `msgId` `string`: Location message id.
- `lat` `number`: Latitude.
- `lon` `number`: Longitude.
- `options` `{accuracyM?: number, stop?: boolean}` (optional): Options.

**Returns** `Promise<void>`:

#### `sendContact(conv, peer)` {#bot-send-contact}

*async*

Send a contact card of user `peer` (or of the bot itself).

**Parameters**

- `conv` `string`: Conversation id.
- `peer` `string`: Peer id.

**Returns** `Promise<Message>`: The message.

#### `sendVoice(conv, path, durationMs, wave?)` {#bot-send-voice}

*async*

Send a voice message (Ogg/Opus file ≤ 32 MB; `wave`: 0–255 bars for the waveform).

**Parameters**

- `conv` `string`: Conversation id.
- `path` `string`: Audio file.
- `durationMs` `number`: Duration.
- `wave` `number[]` (optional): Waveform bars.

**Returns** `Promise<Message>`: The message.

#### `broadcast(text, buttonsOrOptions?, options?)` {#bot-broadcast}

*async*

Send `text` to every user (or `users`), paced (≈ 15 messages/s). Failures are logged and skipped.

**Parameters**

- `text` `string`: Text.
- `buttonsOrOptions` `Buttons|BroadcastOptions` (optional): Buttons, or the options object.
- `options` `BroadcastOptions` (optional): `{buttons, silent, users, onProgress(done, total)}`.

**Returns** `Promise<number>`: How many users received it.

### Checklists and reminders {#bot-tasks}

| Method | Description |
|---|---|
| [`sendChecklist`](#bot-send-checklist) | Send a checklist (1–100 items, ≤ 200 chars each). |
| [`checklistToggle`](#bot-checklist-toggle) | Tick (`done=true`) or untick a checklist item. |
| [`checklistAdd`](#bot-checklist-add) | Add items to a checklist the bot sent. |
| [`checklist`](#bot-checklist) | Current state of a checklist, or null if not found. |
| [`sendReminder`](#bot-send-reminder) | Send a reminder. |
| [`reminderCancel`](#bot-reminder-cancel) | Cancel a reminder the bot sent. |
| [`reminders`](#bot-reminders) | Upcoming reminders known to the bot (soonest first). |

#### `sendChecklist(conv, title, items, options?)` {#bot-send-checklist}

*async*

Send a checklist (1–100 items, ≤ 200 chars each). Anyone in the chat can tick items;
see `onChecklist`.

**Parameters**

- `conv` `string`: Conversation id.
- `title` `string`: Title.
- `items` `string[]`: Items.
- `options` `{silent?: boolean}` (optional): Options.

**Returns** `Promise<Message>`: The message; `body.items` = `[{id, text}]` (ids start at 1).

#### `checklistToggle(conv, msgId, item, done?)` {#bot-checklist-toggle}

*async*

Tick (`done=true`) or untick a checklist item.

**Parameters**

- `conv` `string`: Conversation id.
- `msgId` `string`: Checklist message id.
- `item` `number`: Item id.
- `done` `boolean` (optional, default `true`): Ticked.

**Returns** `Promise<void>`:

#### `checklistAdd(conv, msgId, items)` {#bot-checklist-add}

*async*

Add items to a checklist the bot sent.

**Parameters**

- `conv` `string`: Conversation id.
- `msgId` `string`: Checklist message id.
- `items` `string[]`: New items.

**Returns** `Promise<void>`:

#### `checklist(conv, msgId)` {#bot-checklist}

*async*

Current state of a checklist, or null if not found.

**Parameters**

- `conv` `string`: Conversation id.
- `msgId` `string`: Checklist message id.

**Returns** `Promise<Checklist|null>`: `{msg_id, conv, title, items: [{id, text, done, by, at}], done, total}`.

#### `sendReminder(conv, title, at, options?)` {#bot-send-reminder}

*async*

Send a reminder. Everyone in the chat (and the bot) gets `reminder_due` at `at`.

**Parameters**

- `conv` `string`: Conversation id.
- `title` `string`: ≤ 200 chars.
- `at` `When`: `Date`, epoch milliseconds, or `{ inMs }` from now. Must be in the future.
- `options` `{note?: string, silent?: boolean}` (optional): `note` ≤ 1000 chars.

**Returns** `Promise<Message>`: The message.

#### `reminderCancel(conv, msgId)` {#bot-reminder-cancel}

*async*

Cancel a reminder the bot sent.

**Parameters**

- `conv` `string`: Conversation id.
- `msgId` `string`: Reminder message id.

**Returns** `Promise<void>`:

#### `reminders()` {#bot-reminders}

Upcoming reminders known to the bot (soonest first).

**Returns** `Promise<Reminder[]>`: `[{conv, msg_id, at_ms, title, note, author}]`.

### Message actions {#bot-actions}

| Method | Description |
|---|---|
| [`editMessage`](#bot-edit-message) | Edit the text of one of the bot's messages. |
| [`deleteMessage`](#bot-delete-message) | Delete a message. |
| [`pinMessage`](#bot-pin-message) | Pin (`on=true`) or unpin a message. |
| [`pinnedMessages`](#bot-pinned-messages) | Pinned messages of a conversation. |
| [`react`](#bot-react) | Add (or remove) an emoji reaction. |
| [`forwardMessage`](#bot-forward-message) | Forward a message to another conversation. |
| [`messages`](#bot-messages) | Recent messages of a conversation, oldest first. |
| [`typing`](#bot-typing) | Show (or hide) "typing…". |
| [`markRead`](#bot-mark-read) | Mark a conversation as read. |
| [`scheduleMessage`](#bot-schedule-message) | Let Lumora send `text` at `at` (kept while the bot runs; ≤ 500 pending). |
| [`scheduledMessages`](#bot-scheduled-messages) | Pending scheduled messages. |
| [`cancelScheduled`](#bot-cancel-scheduled) | Cancel a scheduled message. |

#### `editMessage(conv, msgId, text)` {#bot-edit-message}

*async*

Edit the text of one of the bot's messages.

**Parameters**

- `conv` `string`: Conversation id.
- `msgId` `string`: Message id.
- `text` `string`: New text.

**Returns** `Promise<void>`:

#### `deleteMessage(conv, msgId, forEveryone?)` {#bot-delete-message}

*async*

Delete a message. In groups, deleting others' messages needs admin rights.

**Parameters**

- `conv` `string`: Conversation id.
- `msgId` `string`: Message id.
- `forEveryone` `boolean` (optional, default `true`): Delete for everyone.

**Returns** `Promise<void>`:

#### `pinMessage(conv, msgId, on?)` {#bot-pin-message}

*async*

Pin (`on=true`) or unpin a message.

**Parameters**

- `conv` `string`: Conversation id.
- `msgId` `string`: Message id.
- `on` `boolean` (optional, default `true`): Pin.

**Returns** `Promise<void>`:

#### `pinnedMessages(conv)` {#bot-pinned-messages}

Pinned messages of a conversation.

**Parameters**

- `conv` `string`: Conversation id.

**Returns** `Promise<Message[]>`: Messages.

#### `react(conv, msgId, emoji, on?)` {#bot-react}

*async*

Add (or remove) an emoji reaction.

**Parameters**

- `conv` `string`: Conversation id.
- `msgId` `string`: Message id.
- `emoji` `string`: Emoji.
- `on` `boolean` (optional, default `true`): Add.

**Returns** `Promise<void>`:

#### `forwardMessage(msgId, toConv)` {#bot-forward-message}

*async*

Forward a message to another conversation.

**Parameters**

- `msgId` `string`: Message id.
- `toConv` `string`: Target conversation.

**Returns** `Promise<Message>`: The new message.

#### `messages(conv, options?)` {#bot-messages}

Recent messages of a conversation, oldest first. File messages carry `body.preview` and
`file` (`state`, `path` once downloaded).

**Parameters**

- `conv` `string`: Conversation id.
- `options` `{limit?: number, before?: number}` (optional): `limit` (default 50), `before` (hlc).

**Returns** `Promise<Message[]>`: Messages.

#### `typing(conv, on?)` {#bot-typing}

*async*

Show (or hide) "typing…".

**Parameters**

- `conv` `string`: Conversation id.
- `on` `boolean` (optional, default `true`): Show.

**Returns** `Promise<void>`:

#### `markRead(conv)` {#bot-mark-read}

*async*

Mark a conversation as read.

**Parameters**

- `conv` `string`: Conversation id.

**Returns** `Promise<void>`:

#### `scheduleMessage(conv, text, at)` {#bot-schedule-message}

Let Lumora send `text` at `at` (kept while the bot runs; ≤ 500 pending).

**Parameters**

- `conv` `string`: Conversation id.
- `text` `string`: Text.
- `at` `When`: When.

**Returns** `Promise<{id: string, conv: string, text: string, at: number`: >} The scheduled entry.

#### `scheduledMessages()` {#bot-scheduled-messages}

Pending scheduled messages.

**Returns** `Promise<Array<{id: string, conv: string, text: string, at: number`: >>} Entries.

#### `cancelScheduled(schedId)` {#bot-cancel-scheduled}

*async*

Cancel a scheduled message.

**Parameters**

- `schedId` `string`: Entry id.

**Returns** `Promise<void>`:

### Files {#bot-files}

| Method | Description |
|---|---|
| [`files`](#bot-files) | All file transfers. |
| [`acceptFile`](#bot-accept-file) | Start (or resume) downloading a received file into `dir` (default: `downloadsDir`). |
| [`cancelFile`](#bot-cancel-file) | Stop a transfer. |
| [`downloadFile`](#bot-download-file) | Download a received file and wait until it is complete. |

#### `files()` {#bot-files}

All file transfers. `state`: 0 offered, 1 transferring, 2 done, 3 failed, 4 cancelled, 5 paused.

**Returns** `Promise<FileEntry[]>`: Transfers.

#### `acceptFile(fileId, dir?)` {#bot-accept-file}

*async*

Start (or resume) downloading a received file into `dir` (default: `downloadsDir`).

**Parameters**

- `fileId` `string`: File id.
- `dir` `string` (optional): Folder.

**Returns** `Promise<void>`:

#### `cancelFile(fileId)` {#bot-cancel-file}

*async*

Stop a transfer.

**Parameters**

- `fileId` `string`: File id.

**Returns** `Promise<void>`:

#### `downloadFile(fileId, options?)` {#bot-download-file}

*async*

Download a received file and wait until it is complete. Small files from users are
downloaded automatically; this also works for those.

**Parameters**

- `fileId` `string`: File id.
- `options` `{dir?: string, timeoutMs?: number}` (optional): Folder and timeout (default 300 s).

**Returns** `Promise<string>`: Local path.

**Throws**

- `LumoraError`: `sdk.download_failed` (failed / cancelled) or `sdk.timeout`.

### Groups {#bot-groups}

| Method | Description |
|---|---|
| [`groups`](#bot-groups) | Groups the bot is in. |
| [`groupInfo`](#bot-group-info) | Details of a group. |
| [`groupAccess`](#bot-group-access) | What the bot may do in a group: `{readAll, admin}`. |
| [`memberRole`](#bot-member-role) | Role of `peer` in a group. |
| [`groupBan`](#bot-group-ban) | Ban (or unban) a member: removes them and stops them from rejoining. |
| [`groupUnban`](#bot-group-unban) | Lift a ban. |
| [`groupRemove`](#bot-group-remove) | Remove (kick) a member; they may be added again. |
| [`groupSettings`](#bot-group-settings) | Change group settings (admin): `slowModeS` (seconds between two messages of a member, 0 = off) and `adminsOnly` (only admins may post). |
| [`setSlowMode`](#bot-set-slow-mode) | Shortcut for `groupSettings(group, { slowModeS: seconds })`. |
| [`groupPurgeMember`](#bot-group-purge-member) | Delete every message of `peer` in the group (admin; e.g. |
| [`groupLeave`](#bot-group-leave) | Leave a group. |
| [`searchGroups`](#bot-search-groups) | Find public groups by `@handle` or `@handle·tag` (read-only; bots join a group only when one of its admins adds them). |

#### `groups()` {#bot-groups}

Groups the bot is in.

**Returns** `Promise<GroupInfo[]>`: Groups.

#### `groupInfo(group)` {#bot-group-info}

Details of a group.

**Parameters**

- `group` `string`: gid or `g:` conversation id.

**Returns** `Promise<GroupInfo>`: The group.

#### `groupAccess(group)` {#bot-group-access}

*async*

What the bot may do in a group: `{readAll, admin}`. `readAll` = an admin allowed "read all
messages" (full access); `admin` = the bot is a group admin (needed for ban / slow mode /
purge / deleting others' messages).

**Parameters**

- `group` `string`: gid or conversation id.

**Returns** `Promise<{readAll: boolean, admin: boolean`: >} Access.

#### `memberRole(group, peer)` {#bot-member-role}

*async*

Role of `peer` in a group.

**Parameters**

- `group` `string`: gid or conversation id.
- `peer` `string`: Peer id.

**Returns** `Promise<"owner"|"admin"|"member"|null>`: The role, or null.

#### `groupBan(group, peer, ban?)` {#bot-group-ban}

*async*

Ban (or unban) a member: removes them and stops them from rejoining. The bot must be a
group admin with full access.

**Parameters**

- `group` `string`: gid or conversation id.
- `peer` `string`: Peer id.
- `ban` `boolean` (optional, default `true`): Ban.

**Returns** `Promise<void>`:

#### `groupUnban(group, peer)` {#bot-group-unban}

Lift a ban.

**Parameters**

- `group` `string`: gid or conversation id.
- `peer` `string`: Peer id.

**Returns** `Promise<void>`:

#### `groupRemove(group, peer)` {#bot-group-remove}

*async*

Remove (kick) a member; they may be added again. Needs admin rights.

**Parameters**

- `group` `string`: gid or conversation id.
- `peer` `string`: Peer id.

**Returns** `Promise<void>`:

#### `groupSettings(group, settings)` {#bot-group-settings}

*async*

Change group settings (admin): `slowModeS` (seconds between two messages of a member,
0 = off) and `adminsOnly` (only admins may post).

**Parameters**

- `group` `string`: gid or conversation id.
- `settings` `{slowModeS?: number, adminsOnly?: boolean}`: Settings.

**Returns** `Promise<void>`:

#### `setSlowMode(group, seconds)` {#bot-set-slow-mode}

Shortcut for `groupSettings(group, { slowModeS: seconds })`.

**Parameters**

- `group` `string`: gid or conversation id.
- `seconds` `number`: 0 = off.

**Returns** `Promise<void>`:

#### `groupPurgeMember(group, peer)` {#bot-group-purge-member}

*async*

Delete every message of `peer` in the group (admin; e.g. after spam).

**Parameters**

- `group` `string`: gid or conversation id.
- `peer` `string`: Peer id.

**Returns** `Promise<void>`:

#### `groupLeave(group)` {#bot-group-leave}

*async*

Leave a group.

**Parameters**

- `group` `string`: gid or conversation id.

**Returns** `Promise<void>`:

#### `searchGroups(query)` {#bot-search-groups}

Find public groups by `@handle` or `@handle·tag` (read-only; bots join a group only when
one of its admins adds them).

**Parameters**

- `query` `string`: Handle.

**Returns** `Promise<object[]>`: Matches.

### Users and profile {#bot-users}

| Method | Description |
|---|---|
| [`users`](#bot-users) | Everyone who started a chat with the bot. |
| [`contacts`](#bot-contacts) | Full user entries. |
| [`nameOf`](#bot-name-of) | Display name of a user (refreshes the cache when unknown). |
| [`cachedName`](#bot-cached-name) | Display name from the cache (no request); falls back to the first 8 characters of the id. |
| [`resolveUsername`](#bot-resolve-username) | Look up `@name` / `@name·tag`. |
| [`blockUser`](#bot-block-user) | Block a user: they can no longer message the bot. |
| [`unblockUser`](#bot-unblock-user) | Unblock a user. |
| [`setProfile`](#bot-set-profile) | Update the bot's profile. |
| [`setCommands`](#bot-set-commands) | Publish the command menu again (done automatically at start). |

#### `users()` {#bot-users}

*async*

Everyone who started a chat with the bot.

**Returns** `Promise<string[]>`: Peer ids.

#### `contacts()` {#bot-contacts}

Full user entries.

**Returns** `Promise<Contact[]>`: Contacts.

#### `nameOf(peer)` {#bot-name-of}

*async*

Display name of a user (refreshes the cache when unknown).

**Parameters**

- `peer` `string`: Peer id.

**Returns** `Promise<string>`: Name.

#### `cachedName(peer)` {#bot-cached-name}

Display name from the cache (no request); falls back to the first 8 characters of the id.

**Parameters**

- `peer` `string`: Peer id.

**Returns** `string`: Name.

#### `resolveUsername(handle)` {#bot-resolve-username}

Look up `@name` / `@name·tag`.

**Parameters**

- `handle` `string`: Handle.

**Returns** `Promise<Array<{peer: string, handle: string, name?: string, contact: boolean`: >>} Matches.

#### `blockUser(peer)` {#bot-block-user}

*async*

Block a user: they can no longer message the bot.

**Parameters**

- `peer` `string`: Peer id.

**Returns** `Promise<void>`:

#### `unblockUser(peer)` {#bot-unblock-user}

*async*

Unblock a user.

**Parameters**

- `peer` `string`: Peer id.

**Returns** `Promise<void>`:

#### `setProfile(profile)` {#bot-set-profile}

Update the bot's profile. `avatar`: path to an image (≤ 96 KB).

**Parameters**

- `profile` `{name?: string, bio?: string, avatar?: string}`: Fields to change.

**Returns** `Promise<object>`: The profile.

#### `setCommands()` {#bot-set-commands}

*async*

Publish the command menu again (done automatically at start).

**Returns** `Promise<void>`:

### Jobs (scheduled tasks) {#bot-jobs}

| Method | Description |
|---|---|
| [`every`](#bot-every) | Run `fn()` every `seconds`. |
| [`daily`](#bot-daily) | Run `fn()` every day at local time `"HH:MM"`. |
| [`after`](#bot-after) | Run `fn()` once, `seconds` from now. |
| [`cancel`](#bot-cancel) | Cancel a job returned by `every`, `daily` or `after`. |

#### `every(seconds, fn, options?)` {#bot-every}

Run `fn()` every `seconds`. Returns the job; `bot.cancel(job)` stops it.

**Parameters**

- `seconds` `number`: Interval in seconds.
- `fn` `() => any`: Job.
- `options` `{firstIn?: number}` (optional): First run after `firstIn` seconds (default: `seconds`).

**Returns** `Job`: The job.

#### `daily(at, fn)` {#bot-daily}

Run `fn()` every day at local time `"HH:MM"`.

**Parameters**

- `at` `string`: Local time `"HH:MM"`.
- `fn` `() => any`: Job.

**Returns** `Job`: The job.

#### `after(seconds, fn)` {#bot-after}

Run `fn()` once, `seconds` from now.

**Parameters**

- `seconds` `number`: Delay in seconds.
- `fn` `() => any`: Job.

**Returns** `Job`: The job.

#### `cancel(job)` {#bot-cancel}

Cancel a job returned by `every`, `daily` or `after`.

**Parameters**

- `job` `Job`: The job.

### Lifecycle {#bot-lifecycle}

| Method | Description |
|---|---|
| [`start`](#bot-start) | Start Lumora Bot Runner and go online (resolves once online). |
| [`run`](#bot-run) | Start and wait until stopped (Ctrl+C, SIGTERM or `stop()`). |
| [`stop`](#bot-stop) | Stop gracefully: no new events, wait up to `timeoutMs` for running handlers, then close Lumora Bot Runner (it saves everything and exits). |

#### `start()` {#bot-start}

*async*

Start Lumora Bot Runner and go online (resolves once online). See `run`.

**Returns** `Promise<this>`: The bot.

#### `run()` {#bot-run}

*async*

Start and wait until stopped (Ctrl+C, SIGTERM or `stop()`). Shuts down gracefully:
running handlers finish, then Lumora Bot Runner exits.

**Returns** `Promise<void>`: Resolves after shutdown.

#### `stop(timeoutMs?)` {#bot-stop}

*async*

Stop gracefully: no new events, wait up to `timeoutMs` for running handlers, then close
Lumora Bot Runner (it saves everything and exits).

**Parameters**

- `timeoutMs` `number` (optional, default `10000`): How long to wait for running handlers.

**Returns** `Promise<void>`:

### Low-level API {#bot-lowlevel}

| Method | Description |
|---|---|
| [`call`](#bot-call) | Run any command of the Lumora JSON API and return its `data`. |

#### `call(cmd, args?, timeoutMs?)` {#bot-call}

*async*

Run any command of the Lumora JSON API and return its `data`. Commands bots may not use
(remote control, recovery phrase, backups, passwords, calls) reject with
`NotAllowedForBots`.

**Parameters**

- `cmd` `string`: Command name.
- `args` `object` (optional, default `{}`): Arguments.
- `timeoutMs` `number` (optional, default `60000`): Timeout.

**Returns** `Promise<any>`: The command's `data`.

**Throws**

- `LumoraError`: The command failed (`.code`, `.message`, `.detail`).
- `LumoraTimeout`: No answer in time.
- `RunnerStopped`: Runner not running.

### Properties and other members {#bot-other}

#### `log` {#bot-log}

*property*

The SDK's logger (`debug/info/warn/error(msg, fields)`); use it in handlers too.

#### `token` {#bot-token}

*property*

*Type:* `string|undefined`

#### `storage` {#bot-storage}

*property*

Persistent key/value store.

*Type:* `Storage`

#### `roles` {#bot-roles}

*property*

Bot roles.

*Type:* `Roles`

#### `adminPeers` {#bot-admin-peers}

*property*

Resolved bot admins (peer ids).

*Type:* `Set<string>`

#### `commands` {#bot-commands}

*property*

Registered commands: name → `{fn, description, hidden, chats}`.

#### `me` {#bot-me}

*property*

The bot's own account (`peer`, `short_id`, `name`, `username`, `handle`, `version`) once started.

#### `proc` {#bot-proc}

*property*

Lumora Bot Runner process (internal).

## Context {#context}

`new Context(bot, ev, kind?)`

What a handler receives: the event plus shortcuts to answer it.

Fields are empty / `null` when not relevant: `kind` (`"command"`, `"message"`,
`"callback"`, `"new_user"`, `"new_member"`, `"member_left"`, `"added_to_group"`, `"file"`,
`"reminder_due"`, `"checklist"`, `"job"`, `"start"` or the raw event name), `conv`, `sender`,
`text`, `command`, `args`, `match`, `data`, `msgId`, `replyTo`, `body`, `msgKind`, `file`,
`reminder`, `checklist`, `changes`, `member`, `event` (raw dict).

#### `bot` {#context-bot}

*property*

*Type:* `Bot`

#### `event` {#context-event}

*property*

Raw event.

*Type:* `Record<string, any>`

#### `kind` {#context-kind}

*property*

What happened.

*Type:* `string`

#### `conv` {#context-conv}

*property*

Conversation id (`d:<peer>` direct chat, `g:<gid>` group).

*Type:* `string`

#### `sender` {#context-sender}

*property*

The user who caused the event (peer id).

*Type:* `string`

#### `body` {#context-body}

*property*

Message body.

*Type:* `Record<string, any>`

#### `msgKind` {#context-msg-kind}

*property*

Message kind (`"text"`, `"file"`, `"location"`…).

*Type:* `string`

#### `text` {#context-text}

*property*

Message text.

*Type:* `string`

#### `data` {#context-data}

*property*

Button data (callbacks).

*Type:* `string`

#### `msgId` {#context-msg-id}

*property*

Message id (for callbacks: the bot's message whose button was pressed).

*Type:* `string`

#### `replyTo` {#context-reply-to}

*property*

Id of the quoted message, or null.

*Type:* `string|null`

#### `silent` {#context-silent}

*property*

Delivered without sound/notification.

*Type:* `boolean`

#### `match` {#context-match}

*property*

Regex match of `onText` / `onCallback({pattern})`.

*Type:* `RegExpExecArray|null`

#### `file` {#context-file}

*property*

File info (`onFile`): `{file_id, name, size, mime, preview, state, path}`.

*Type:* `Record<string, any>|null`

#### `reminder` {#context-reminder}

*property*

Reminder (`onReminderDue`): `{title, note, at_ms, author, mine, late, conv, msg_id}`.

*Type:* `Record<string, any>|null`

#### `checklist` {#context-checklist}

*property*

Checklist state (`onChecklist`).

*Type:* `Record<string, any>|null`

#### `changes` {#context-changes}

*property*

Checklist changes (`onChecklist`): `[{item, text, done, by}]`.

*Type:* `Array<Record<string, any>>`

#### `member` {#context-member}

*property*

Group member (`onNewMember`, `onMemberLeft`): `{peer, name, role}`.

*Type:* `Record<string, any>|null`

#### `command` {#context-command}

*property*

Command name without `/`, or null.

*Type:* `string|null`

#### `args` {#context-args}

*property*

Text after the command.

*Type:* `string`

#### `handled` {#context-handled}

*property*

Whether a handler ran.

*Type:* `boolean`

#### `isGroup` {#context-is-group}

*property*

True when the event happened in a group or community channel.

*Type:* `boolean`

#### `gid` {#context-gid}

*property*

Group id for group events, else null.

*Type:* `string|null`

#### `senderName` {#context-sender-name}

*property*

Display name of the sender (from the bot's cache; falls back to the first 8 characters
of the id). Use `await bot.nameOf(peer)` to refresh.

*Type:* `string`

#### `isAdmin` {#context-is-admin}

*property*

True when the sender is one of this bot's admins (`admins` option).

*Type:* `boolean`

#### `hasRole(role)` {#context-has-role}

True when the sender has bot role `role` (bot admins always do).

**Parameters**

- `role` `string`: Role.

**Returns** `boolean`: Whether the sender has it.

#### `isGroupAdmin()` {#context-is-group-admin}

*async*

True when the sender is an admin or the owner of the current group.

**Returns** `Promise<boolean>`: Whether the sender is a group admin.

#### `reply(text, buttonsOrOptions?, options?)` {#context-reply}

Send `text` to the same conversation.

**Parameters**

- `text` `string`: Message text (max 64 KB).
- `buttonsOrOptions` `Buttons|ReplyOptions` (optional): Buttons, or the options object.
- `options` `ReplyOptions` (optional): `{buttons, reply, silent, mentions, mentionAll}`; `reply: true` quotes the message being answered.

**Returns** `Promise<object>`: The sent message.

```js
await ctx.reply("Saved ✅", { reply: true, silent: true });
```

#### `replyFile(path, options?)` {#context-reply-file}

Send a file to the same conversation (see `bot.sendFile`).

**Parameters**

- `path` `string`: File path.
- `options` `FileOptions` (optional): `{preview, thumb}`.

**Returns** `Promise<object>`: The file transfer entry.

#### `sendFile(path)` {#context-send-file}

Send a file to the same conversation (kept for older bots; prefer `replyFile`).

**Parameters**

- `path` `string`: File path.

**Returns** `Promise<object>`: The file transfer entry.

#### `replyChecklist(title, items, options?)` {#context-reply-checklist}

Send a checklist to the same conversation.

**Parameters**

- `title` `string`: Title.
- `items` `string[]`: Items.
- `options` `{silent?: boolean}` (optional): Options.

**Returns** `Promise<object>`: The message.

#### `replyReminder(title, at, options?)` {#context-reply-reminder}

Send a reminder to the same conversation.

**Parameters**

- `title` `string`: Title.
- `at` `When`: When.
- `options` `{note?: string, silent?: boolean}` (optional): Options.

**Returns** `Promise<object>`: The message.

#### `replyPoll(question, options)` {#context-reply-poll}

Send a poll to the same conversation.

**Parameters**

- `question` `string`: Question.
- `options` `string[]`: 2–10 options.

**Returns** `Promise<object>`: The message.

#### `react(emoji, on?)` {#context-react}

React to the current message.

**Parameters**

- `emoji` `string`: Emoji.
- `on` `boolean` (optional, default `true`): `false` removes it.

**Returns** `Promise<void>`:

#### `edit(text)` {#context-edit}

Edit the current message. For callbacks that is the bot's message whose button was
pressed, so `ctx.edit("Done ✅")` updates it in place.

**Parameters**

- `text` `string`: New text.

**Returns** `Promise<void>`:

#### `delete(forEveryone?)` {#context-delete}

Delete the current message (others' messages in groups need admin rights).

**Parameters**

- `forEveryone` `boolean` (optional, default `true`): Delete for everyone.

**Returns** `Promise<void>`:

#### `pin(on?)` {#context-pin}

Pin (or unpin) the current message.

**Parameters**

- `on` `boolean` (optional, default `true`): Pin.

**Returns** `Promise<void>`:

#### `typing(on?)` {#context-typing}

Show (or hide) "typing…" here.

**Parameters**

- `on` `boolean` (optional, default `true`): Show.

**Returns** `Promise<void>`:

#### `download(options?)` {#context-download}

Download the file of this message (`onFile`) and return its local path.

**Parameters**

- `options` `{dir?: string, timeoutMs?: number}` (optional): Folder and timeout (default 300 s).

**Returns** `Promise<string>`: Local path.

## Storage {#storage}

`new Storage(path)`

Key/value store saved as JSON in the bot's data folder (`bot-storage.json`).

`set` / `delete` / `updateKey` save the file atomically. If you change a nested value in
place (`storage.get("list").push(x)`) call `save()` afterwards. Values must be
JSON-serialisable. The file format is shared with the Python SDK.

#### `data` {#storage-data}

*property*

The raw object (read-only use recommended).

*Type:* `Record<string, any>`

#### `get(key, def?)` {#storage-get}

Value of `key`, or `def` when missing.

**Parameters**

- `key` `string`: Key.
- `def` `any` (optional): Default.

**Returns** `any`: The value.

#### `has(key)` {#storage-has}

**Parameters**

- `key` `string`: Key.

**Returns** `boolean`: Whether the key exists.

#### `keys()` {#storage-keys}

**Returns** `string[]`: All keys.

#### `set(key, value)` {#storage-set}

Set `key` and save.

**Parameters**

- `key` `string`: Key.
- `value` `any`: JSON-serialisable value.

#### `delete(key)` {#storage-delete}

Delete `key` and save.

**Parameters**

- `key` `string`: Key.

#### `updateKey(key, fn, def?)` {#storage-update-key}

Replace `key` with `fn(old)` and save. Returns the new value.

**Parameters**

- `key` `string`: Key.
- `fn` `(old: any) => any`: Updater.
- `def` `any` (optional): Value passed to `fn` when the key is missing.

**Returns** `any`: The new value.

```js
bot.storage.updateKey("visits", (n) => n + 1, 0);
```

#### `save()` {#storage-save}

Write the whole store to disk now (atomic replace).

#### `toJSON()` {#storage-to-j-s-o-n}

**Returns** `Record<string, any>`: The data.

## Roles {#roles}

`new Roles(storage)`

Bot-level roles (`"mod"`, `"vip"`…) kept in storage: user → roles. These are *your
bot's* roles, separate from group admins. Bot admins (`admins` option) pass every check.

#### `grant(peer, role)` {#roles-grant}

Give `role` to user `peer`.

**Parameters**

- `peer` `string`: Peer id.
- `role` `string`: Role.

#### `revoke(peer, role)` {#roles-revoke}

Take `role` away from `peer`.

**Parameters**

- `peer` `string`: Peer id.
- `role` `string`: Role.

#### `of(peer)` {#roles-of}

Roles of `peer`.

**Parameters**

- `peer` `string`: Peer id.

**Returns** `Set<string>`: Roles (empty set when none).

#### `members(role)` {#roles-members}

Users that have `role`.

**Parameters**

- `role` `string`: Role.

**Returns** `string[]`: Peer ids.

## LumoraError {#lumoraerror}

`new LumoraError(message, code?, detail?, cmd?)`

Error returned by Lumora (or raised by the SDK).

`message` is a plain sentence in the bot's language (`new Bot({ lang })`), safe to show
to users; `code` is a stable key (`"err.slow_mode"`, `"err.admin_only"`, `"internal"`, or
`"sdk.*"` for errors raised by the SDK itself); `detail` is the technical cause (log it,
don't show it); `cmd` is the command that failed.

#### `message` {#lumoraerror-message}

*property*

Plain sentence, safe to show to users.

*Type:* `string`

#### `code` {#lumoraerror-code}

*property*

Stable machine key.

*Type:* `string`

#### `detail` {#lumoraerror-detail}

*property*

Technical cause, or null.

*Type:* `string|null`

#### `cmd` {#lumoraerror-cmd}

*property*

The command that failed, or null.

*Type:* `string|null`

#### `toString()` {#lumoraerror-to-string}

`"<name>: <message> (<detail>)"`.

**Returns** `string`:

#### `toJSON()` {#lumoraerror-to-j-s-o-n}

`{error, code, detail, cmd}` for structured logs.

**Returns** `{error: string, code: string, detail: string|null, cmd: string|null`: }

## LumoraTimeout {#lumoratimeout}

A request got no answer in time (code `sdk.timeout`).

## RunnerStopped {#runnerstopped}

Lumora Bot Runner is not running, or stopped while a request was pending (code `sdk.runner_stopped`).

## NotAllowedForBots {#notallowedforbots}

The command is not available to bots (code `sdk.not_for_bots`).

## Helpers {#helpers}

#### `isBlockedCommand(cmd)` {#is-blocked-command}

True when `cmd` is a core command bots may not use (remote control, recovery phrase,
backups, passwords, calls, BotFather management).

**Parameters**

- `cmd` `string`: Command name.

**Returns** `boolean`: Whether the command is blocked.

#### `gidOf(convOrGid)` {#gid-of}

Group id (32 hex chars) from a group conversation id (`g:<gid>` or `g:<gid>#channel`) or a
bare gid. Throws `TypeError` for direct chats.

**Parameters**

- `convOrGid` `string`: Conversation id or gid.

**Returns** `string`: The gid.

#### `convOf(peerOrGid)` {#conv-of}

Conversation id for a user (`d:<peer>`) or a group gid (`g:<gid>`). Conversation ids are
returned unchanged.

**Parameters**

- `peerOrGid` `string`: Peer id, gid or conversation id.

**Returns** `string`: Conversation id.

#### `isGroupConv(conv)` {#is-group-conv}

True for group / community channel conversations (`g:…`).

**Parameters**

- `conv` `string`: Conversation id.

**Returns** `boolean`: Whether it is a group conversation.

#### `Button(text, dataOrOptions = "", url = "")` {#-button}

Make an inline button. Pressing a data button sends a `callback` to the bot
(`bot.onCallback`); a URL button opens the link. `text` and `data` are at most 64 chars.

**Parameters**

- `text` `string`: Label.
- `dataOrOptions` `string|{data?: string, url?: string}` (optional, default `""`): Callback data, a `https://` link, or `{ data }` / `{ url }`.
- `url` `string` (optional, default `""`): Link (alternative to `{ url }`).

**Returns** `{text: string, data: string, url: string`: } The button.

```js
Button("Buy", "buy:42");  Button("Site", { url: "https://example.com" });
```

## Constants {#constants}

| Name | Value | Meaning |
|---|---|---|
| `VERSION` | `"1.1.0"` | SDK version. |
| `MAX_TEXT_BYTES` | `64 * 1024` | Text message size limit enforced by Lumora (UTF-8 bytes). |
| `MAX_BUTTON_ROWS` | `8` | Max rows of inline buttons. |
| `MAX_BUTTONS_PER_ROW` | `8` | Max buttons per row. |
| `MAX_BUTTON_TEXT` | `64` | Max characters of a button label. |
| `MAX_BUTTON_DATA` | `64` | Max characters of a button's callback data. |
| `MAX_PREVIEW_TEXT_BYTES` | `4 * 1024` | File preview text cap (UTF-8 bytes); receivers drop anything bigger. |
| `MAX_PREVIEW_IMAGE_BYTES` | `64 * 1024` | File preview picture cap (bytes). |
| `MAX_CHECKLIST_ITEMS` | `100` | Max checklist items. |
| `MAX_TASK_TEXT` | `200` | Max characters of a checklist item / reminder title. |
| `MAX_REMINDER_NOTE` | `1000` | Max characters of a reminder note. |
