# Changelog

Lumora Bot SDK for Python (`lumora-bot` on pip) and JavaScript (`lumora-bot` on npm).
Both SDKs share one version number and one feature set. Format: [Keep a Changelog](https://keepachangelog.com/),
versioning: [SemVer](https://semver.org/).

## 1.1.0 (2026-11-05)

### Added
- **Checklists:** `send_checklist` / `sendChecklist`, `checklist_toggle`, `checklist_add`, `checklist()` and the
  `on_checklist` / `onChecklist` handler with the list state and what changed.
- **Reminders:** `send_reminder`, `reminder_cancel`, `reminders()` and the `on_reminder_due` / `onReminderDue` handler.
- **Silent messages:** `silent=True` / `{ silent: true }` on every send (no sound or notification).
- **Files:** `send_file(..., preview=..., thumb=...)` (custom preview shown before download), `on_file` / `onFile`
  with an extensions filter, `ctx.file` (name, size, preview), `download_file()` / `ctx.download()`, `files()`,
  `accept_file()`, `cancel_file()`. Received files go to `<data_dir>/downloads` by default.
- **More message types:** polls, stickers, location and live location, contact cards, voice messages.
- **Message actions:** edit, delete, pin, react, forward, mentions, reply-to, `typing`, `messages()`, `ctx.edit()` on callbacks.
- **Groups:** `on_new_member`, `on_member_left`, `on_added_to_group`; admin actions `group_ban`, `group_unban`,
  `group_remove`, `group_settings` / `set_slow_mode`, `group_purge_member`, `group_leave`; `group_info`, `group_access`,
  `member_role`, `ctx.is_group_admin`, `search_groups`; `chats="private"|"group"` filters on commands and handlers;
  `/cmd@otherbot` is ignored.
- **Handler filters:** `on_text(regex)`, `on_message(pattern=, kinds=, chats=)`, `on_callback(data="buy:*")` or
  `pattern=`, `on_event(name)` for raw events. Specific handlers win over catch-alls.
- **Middleware** (`bot.middleware` / `bot.use`), `on_error`, `on_start`.
- **Jobs:** `every(seconds)`, `daily("HH:MM")`, `after(seconds)`, `cancel(job)` for scheduled broadcasts and tasks.
- **Errors:** `LumoraError` with `.code`, `.message`, `.detail`, `.cmd`; `LumoraTimeout`, `RunnerStopped`,
  `NotAllowedForBots`.
- **Runtime:** structured logging (JSON with `LUMORA_BOT_LOG_FORMAT=json`), Lumora Bot Runner log in
  `<data_dir>/runner.log`, automatic restart of the runner, graceful shutdown on SIGTERM/Ctrl+C, events of one
  conversation handled in order, a fair send queue (15 messages/s overall; per chat a burst of 5, then 1/s).
- Python: optional asyncio support (`async def` handlers, `bot.aio.*`, `bot.acall`). JavaScript: TypeScript
  declarations (`lumora-bot.d.ts`).
- Packaging: `pyproject.toml` (`pip install lumora-bot`), `package.json` with `exports` and `types`.

### Changed
- Errors are `LumoraError` (a `RuntimeError` subclass in Python), so existing `except RuntimeError` code still works.
  In JavaScript `err.message` is now the plain sentence; the technical cause is in `err.detail`.
- Callbacks from a group answer in that group (`ctx.conv` is the conversation of the message whose button was pressed).
- Commands bots must not use (remote control, recovery phrase, backups, passwords, calls) raise `NotAllowedForBots`
  from `call()`.

### Compatible
- Bots written for 1.0 run unchanged: same constructor arguments, `command`, `on_message`, `on_callback`,
  `on_new_user`, `send`, `broadcast`, `users`, `storage`, `roles`, `call`, `ctx.reply`, `ctx.send_file`.

## 1.0.0

- First release: commands with a menu, inline buttons and callbacks, bot admins and roles, JSON storage,
  paced broadcasts, Bot Studio tokens.
