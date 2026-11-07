/**
 * Lumora Bot SDK for JavaScript (Node.js ≥ 18): build bots for the Lumora messaging app.
 *
 * A bot is a normal Lumora account run by your code through **Lumora Bot Runner**
 * (`lumorad`). Users find it by its 9-digit ID or `@name·tag` and chat with it like with any
 * friend; messages are end-to-end encrypted and there is no central API.
 *
 * @example
 * import { Bot, Button } from "lumora-bot";
 *
 * const bot = new Bot();                       // token from LUMORA_BOT_TOKEN (Bot Studio)
 * bot.command("start", "Start", (ctx) =>
 *   ctx.reply("Hi! Pick one:", [[Button("👍 Like", "like"), Button("Website", { url: "https://example.com" })]]));
 * bot.onCallback({ data: "like" }, (ctx) => ctx.reply("Thanks!"));
 * bot.onText(/hello|hi/i, (ctx) => ctx.reply(`Hello ${ctx.senderName}!`));
 * await bot.run();
 *
 * Everything is Promise-based. Events of one conversation are handled one after another
 * (in order); different conversations run concurrently.
 *
 * Requirements: Node.js 18+ and the `lumorad` binary (`LUMORAD=/path/to/lumorad` or
 * `new Bot({ binary })`). About 30 MB RAM per bot, close to 0 % CPU when idle.
 *
 * License: MIT.
 * @module lumora-bot
 */
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import {
  closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, statSync, writeSync,
} from "node:fs";
import { extname, join, resolve } from "node:path";

/** @typedef {import("./lumora-bot.d.ts").Buttons} Buttons */
/** @typedef {import("./lumora-bot.d.ts").ReplyOptions} ReplyOptions */
/** @typedef {import("./lumora-bot.d.ts").SendOptions} SendOptions */
/** @typedef {import("./lumora-bot.d.ts").FileOptions} FileOptions */
/** @typedef {import("./lumora-bot.d.ts").When} When */
/** @typedef {import("./lumora-bot.d.ts").Handler} Handler */
/** @typedef {import("./lumora-bot.d.ts").Middleware} Middleware */
/** @typedef {import("./lumora-bot.d.ts").BotOptions} BotOptions */
/** @typedef {import("./lumora-bot.d.ts").CommandOptions} CommandOptions */
/** @typedef {import("./lumora-bot.d.ts").MessageFilter} MessageFilter */
/** @typedef {import("./lumora-bot.d.ts").CallbackFilter} CallbackFilter */
/** @typedef {import("./lumora-bot.d.ts").FileFilter} FileFilter */
/** @typedef {import("./lumora-bot.d.ts").Chats} Chats */
/** @typedef {import("./lumora-bot.d.ts").Job} Job */
/** @typedef {import("./lumora-bot.d.ts").Message} Message */
/** @typedef {import("./lumora-bot.d.ts").FileEntry} FileEntry */
/** @typedef {import("./lumora-bot.d.ts").Checklist} Checklist */
/** @typedef {import("./lumora-bot.d.ts").Reminder} Reminder */
/** @typedef {import("./lumora-bot.d.ts").GroupInfo} GroupInfo */
/** @typedef {import("./lumora-bot.d.ts").Contact} Contact */
/** @typedef {import("./lumora-bot.d.ts").BroadcastOptions} BroadcastOptions */

/** SDK version. */
export const VERSION = "1.1.0";

/** Text message size limit enforced by Lumora (UTF-8 bytes). */
export const MAX_TEXT_BYTES = 64 * 1024;
/** Max rows of inline buttons. */
export const MAX_BUTTON_ROWS = 8;
/** Max buttons per row. */
export const MAX_BUTTONS_PER_ROW = 8;
/** Max characters of a button label. */
export const MAX_BUTTON_TEXT = 64;
/** Max characters of a button's callback data. */
export const MAX_BUTTON_DATA = 64;
/** File preview text cap (UTF-8 bytes); receivers drop anything bigger. */
export const MAX_PREVIEW_TEXT_BYTES = 4 * 1024;
/** File preview picture cap (bytes). */
export const MAX_PREVIEW_IMAGE_BYTES = 64 * 1024;
/** Max checklist items. */
export const MAX_CHECKLIST_ITEMS = 100;
/** Max characters of a checklist item / reminder title. */
export const MAX_TASK_TEXT = 200;
/** Max characters of a reminder note. */
export const MAX_REMINDER_NOTE = 1000;

// Commands a bot must never run. Remote control, recovery phrase, backups and passwords
// belong to people, not bots; calls need a human on the other end.
const BLOCKED = new Set([
  "recovery_phrase", "export_backup", "change_passphrase", "ui_secret_get", "ui_secret_set",
  "push_register", "push_unregister", "push_status", "call_start", "call_answer", "voice_join",
  "bot_create", "bot_token", "bot_revoke", "bot_delete",
]);
const BLOCKED_PREFIXES = ["remote_"];

/**
 * True when `cmd` is a core command bots may not use (remote control, recovery phrase,
 * backups, passwords, calls, Bot Studio management).
 * @param {string} cmd - Command name.
 * @returns {boolean} Whether the command is blocked.
 */
export function isBlockedCommand(cmd) {
  return BLOCKED.has(cmd) || BLOCKED_PREFIXES.some((p) => cmd.startsWith(p));
}

// ----------------------------------------------------------------------------- errors

/**
 * Error returned by Lumora (or raised by the SDK).
 *
 * `message` is a plain sentence in the bot's language (`new Bot({ lang })`), safe to show
 * to users; `code` is a stable key (`"err.slow_mode"`, `"err.admin_only"`, `"internal"`, or
 * `"sdk.*"` for errors raised by the SDK itself); `detail` is the technical cause (log it,
 * don't show it); `cmd` is the command that failed.
 */
export class LumoraError extends Error {
  /**
   * @param {string} message - Plain, user-safe sentence.
   * @param {string} [code="internal"] - Stable machine key.
   * @param {string|null} [detail=null] - Technical cause.
   * @param {string|null} [cmd=null] - The command that failed.
   */
  constructor(message, code = "internal", detail = null, cmd = null) {
    const msg = message || "error";
    super(detail ? `${msg} (${detail})` : msg);
    this.name = "LumoraError";
    /** Plain sentence, safe to show to users. @type {string} */
    this.message = msg;
    /** Stable machine key. @type {string} */
    this.code = code || "internal";
    /** Technical cause, or null. @type {string|null} */
    this.detail = detail ?? null;
    /** The command that failed, or null. @type {string|null} */
    this.cmd = cmd ?? null;
  }
  /** `"<name>: <message> (<detail>)"`. @returns {string} */
  toString() { return `${this.name}: ${this.message}${this.detail ? ` (${this.detail})` : ""}`; }
  /** `{error, code, detail, cmd}` for structured logs. @returns {{error: string, code: string, detail: string|null, cmd: string|null}} */
  toJSON() { return { error: this.message, code: this.code, detail: this.detail, cmd: this.cmd }; }
}

/** A request got no answer in time (code `sdk.timeout`). */
export class LumoraTimeout extends LumoraError {
  constructor(...a) { super(...a); this.name = "LumoraTimeout"; }
}
/** Lumora Bot Runner is not running, or stopped while a request was pending (code `sdk.runner_stopped`). */
export class RunnerStopped extends LumoraError {
  constructor(...a) { super(...a); this.name = "RunnerStopped"; }
}
/** The command is not available to bots (code `sdk.not_for_bots`). */
export class NotAllowedForBots extends LumoraError {
  constructor(...a) { super(...a); this.name = "NotAllowedForBots"; }
}

// ----------------------------------------------------------------------------- helpers

/**
 * Group id (32 hex chars) from a group conversation id (`g:<gid>` or `g:<gid>#channel`) or a
 * bare gid. Throws `TypeError` for direct chats.
 * @param {string} convOrGid - Conversation id or gid.
 * @returns {string} The gid.
 */
export function gidOf(convOrGid) {
  let s = String(convOrGid).trim();
  if (s.startsWith("g:")) s = s.slice(2).split("#", 1)[0];
  if (!/^[0-9a-f]{32}$/.test(s)) throw new TypeError(`not a group: ${JSON.stringify(convOrGid)}`);
  return s;
}

/**
 * Conversation id for a user (`d:<peer>`) or a group gid (`g:<gid>`). Conversation ids are
 * returned unchanged.
 * @param {string} peerOrGid - Peer id, gid or conversation id.
 * @returns {string} Conversation id.
 */
export function convOf(peerOrGid) {
  const s = String(peerOrGid).trim();
  if (["d:", "g:", "s:"].includes(s.slice(0, 2))) return s;
  return (/^[0-9a-f]{32}$/.test(s) ? "g:" : "d:") + s;
}

/**
 * True for group / community channel conversations (`g:…`).
 * @param {string} conv - Conversation id.
 * @returns {boolean} Whether it is a group conversation.
 */
export function isGroupConv(conv) {
  return String(conv || "").startsWith("g:");
}

function toMs(when) {
  if (when instanceof Date) return when.getTime();
  if (when && typeof when === "object" && "inMs" in when) return Date.now() + Number(when.inMs);
  if (typeof when === "number" && Number.isFinite(when)) return Math.trunc(when);
  throw new TypeError("time must be a Date, epoch milliseconds, or { inMs }");
}

function clipUtf8(text, limit) {
  const b = Buffer.from(text, "utf8");
  if (b.length <= limit) return text;
  let cut = limit;
  while (cut > 0 && (b[cut] & 0xc0) === 0x80) cut--;
  return b.subarray(0, cut).toString("utf8");
}

const sleep = (ms) => new Promise((r) => setTimeout(r, Math.max(0, ms)));

function gate() {
  let open;
  const p = new Promise((r) => { open = r; });
  return { p, open };
}

/**
 * Make an inline button. Pressing a data button sends a `callback` to the bot
 * (`bot.onCallback`); a URL button opens the link. `text` and `data` are at most 64 chars.
 * @param {string} text - Label.
 * @param {string|{data?: string, url?: string}} [dataOrOptions=""] - Callback data, a
 *   `https://` link, or `{ data }` / `{ url }`.
 * @param {string} [url=""] - Link (alternative to `{ url }`).
 * @returns {{text: string, data: string, url: string}} The button.
 * @example
 * Button("Buy", "buy:42");  Button("Site", { url: "https://example.com" });
 */
export function Button(text, dataOrOptions = "", url = "") {
  if (dataOrOptions && typeof dataOrOptions === "object") {
    return { text: String(text), data: String(dataOrOptions.data ?? ""), url: String(dataOrOptions.url ?? "") };
  }
  const d = String(dataOrOptions ?? "");
  if (!url && /^https?:\/\//.test(d)) return { text: String(text), data: "", url: d };
  return { text: String(text), data: d, url: String(url ?? "") };
}

function oneButton(b) {
  if (Array.isArray(b)) {
    const [text, data] = b;
    return /^https?:\/\//.test(String(data)) ? { text: String(text), data: "", url: String(data) } : { text: String(text), data: String(data ?? ""), url: "" };
  }
  return { text: String(b?.text ?? ""), data: String(b?.data ?? ""), url: String(b?.url ?? "") };
}

function normButtons(rows) {
  let list = Array.isArray(rows) ? rows : [];
  const first = list[0];
  // a single flat row: [{…}, {…}] or [["Text", "data"], …]
  if (first && ((!Array.isArray(first) && typeof first === "object") || (Array.isArray(first) && typeof first[0] === "string"))) list = [list];
  const out = list.map((row) => (Array.isArray(row) ? row : [row]).map(oneButton));
  if (out.length > MAX_BUTTON_ROWS || out.some((r) => r.length > MAX_BUTTONS_PER_ROW)) {
    throw new LumoraError("Too many buttons (max 8 rows × 8).", "sdk.bad_buttons");
  }
  for (const b of out.flat()) {
    if (b.text.length > MAX_BUTTON_TEXT || b.data.length > MAX_BUTTON_DATA) {
      throw new LumoraError("Button text and data must be at most 64 characters.", "sdk.bad_buttons", b.text.slice(0, 20));
    }
  }
  return out;
}

function toRegExp(p) {
  if (p == null) return null;
  if (p instanceof RegExp) return p.global || p.sticky ? new RegExp(p.source, p.flags.replace(/[gy]/g, "")) : p;
  return new RegExp(p);
}

/** Split `(buttonsOrOptions, options)` into `{buttons, ...options}`. */
function splitOpts(b, o) {
  if (b == null || Array.isArray(b)) return { ...(o || {}), buttons: b ?? o?.buttons };
  if (typeof b === "object") return { ...b, ...(o || {}) };
  return { ...(o || {}) };
}

// ----------------------------------------------------------------------------- logging

const LEVELS = { debug: 10, info: 20, warning: 30, warn: 30, error: 40, critical: 50 };

/** Structured logger writing to STDERR (text, or JSON lines). Fields are added to JSON output. */
class Logger {
  constructor(json, level) {
    this.json = json;
    this.level = LEVELS[String(level || "info").toLowerCase()] ?? 20;
  }
  #out(level, msg, fields) {
    if ((LEVELS[level] ?? 20) < this.level) return;
    const f = fields && typeof fields === "object" ? fields : {};
    const line = this.json
      ? JSON.stringify({ ts: Math.round(Date.now()) / 1000, level, logger: "lumora_bot", msg: String(msg), ...f })
      : `${new Date().toISOString()} [lumora-bot] ${level.toUpperCase()} ${msg}${Object.keys(f).length ? " " + JSON.stringify(f) : ""}`;
    process.stderr.write(line + "\n");
  }
  /** @param {string} msg @param {object} [fields] */
  debug(msg, fields) { this.#out("debug", msg, fields); }
  /** @param {string} msg @param {object} [fields] */
  info(msg, fields) { this.#out("info", msg, fields); }
  /** @param {string} msg @param {object} [fields] */
  warn(msg, fields) { this.#out("warning", msg, fields); }
  /** @param {string} msg @param {object} [fields] */
  error(msg, fields) { this.#out("error", msg, fields); }
}

function errFields(e) {
  return e instanceof LumoraError ? e.toJSON() : { error: String(e?.stack || e) };
}

// ----------------------------------------------------------------------------- storage

/**
 * Key/value store saved as JSON in the bot's data folder (`bot-storage.json`).
 *
 * `set` / `delete` / `updateKey` save the file atomically. If you change a nested value in
 * place (`storage.get("list").push(x)`) call `save()` afterwards. Values must be
 * JSON-serialisable. The file format is shared with the Python SDK.
 */
export class Storage {
  /** @param {string} path - JSON file path. */
  constructor(path) {
    this.path = path;
    /** The raw object (read-only use recommended). @type {Record<string, any>} */
    this.data = {};
    try { this.data = JSON.parse(readFileSync(path, "utf8")) || {}; } catch { this.data = {}; }
  }
  /**
   * Value of `key`, or `def` when missing.
   * @param {string} key - Key. @param {any} [def] - Default.
   * @returns {any} The value.
   */
  get(key, def) { return Object.prototype.hasOwnProperty.call(this.data, key) ? this.data[key] : def; }
  /** @param {string} key - Key. @returns {boolean} Whether the key exists. */
  has(key) { return Object.prototype.hasOwnProperty.call(this.data, key); }
  /** @returns {string[]} All keys. */
  keys() { return Object.keys(this.data); }
  /**
   * Set `key` and save.
   * @param {string} key - Key. @param {any} value - JSON-serialisable value.
   */
  set(key, value) { this.data[key] = value; this.save(); }
  /** Delete `key` and save. @param {string} key - Key. */
  delete(key) { if (this.has(key)) { delete this.data[key]; this.save(); } }
  /**
   * Replace `key` with `fn(old)` and save. Returns the new value.
   * @param {string} key - Key.
   * @param {(old: any) => any} fn - Updater.
   * @param {any} [def] - Value passed to `fn` when the key is missing.
   * @returns {any} The new value.
   * @example
   * bot.storage.updateKey("visits", (n) => n + 1, 0);
   */
  updateKey(key, fn, def) {
    const v = fn(this.get(key, def));
    this.data[key] = v;
    this.save();
    return v;
  }
  /** Write the whole store to disk now (atomic replace). */
  save() {
    const tmp = this.path + ".tmp";
    const fd = openSync(tmp, "w");
    try {
      writeSync(fd, JSON.stringify(this.data));
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
    renameSync(tmp, this.path);
  }
  /** @returns {Record<string, any>} The data. */
  toJSON() { return this.data; }
}

/**
 * Bot-level roles (`"mod"`, `"vip"`…) kept in storage: user → roles. These are *your
 * bot's* roles, separate from group admins. Bot admins (`admins` option) pass every check.
 */
export class Roles {
  /** @param {Storage} storage - The bot's storage. */
  constructor(storage) {
    this.s = storage;
    if (!this.s.get("__roles__")) this.s.set("__roles__", {});
  }
  /** Give `role` to user `peer`. @param {string} peer - Peer id. @param {string} role - Role. */
  grant(peer, role) {
    this.s.updateKey("__roles__", (r) => {
      const n = { ...(r || {}) };
      const cur = n[peer] || [];
      n[peer] = cur.includes(role) ? cur : [...cur, role];
      return n;
    }, {});
  }
  /** Take `role` away from `peer`. @param {string} peer - Peer id. @param {string} role - Role. */
  revoke(peer, role) {
    this.s.updateKey("__roles__", (r) => {
      const n = { ...(r || {}) };
      n[peer] = (n[peer] || []).filter((x) => x !== role);
      if (!n[peer].length) delete n[peer];
      return n;
    }, {});
  }
  /** Roles of `peer`. @param {string} peer - Peer id. @returns {Set<string>} Roles (empty set when none). */
  of(peer) { return new Set((this.s.get("__roles__", {}) || {})[peer] || []); }
  /** Users that have `role`. @param {string} role - Role. @returns {string[]} Peer ids. */
  members(role) {
    return Object.entries(this.s.get("__roles__", {}) || {}).filter(([, rs]) => rs.includes(role)).map(([p]) => p);
  }
}

// ----------------------------------------------------------------------------- context

/**
 * What a handler receives: the event plus shortcuts to answer it.
 *
 * Fields are empty / `null` when not relevant: `kind` (`"command"`, `"message"`,
 * `"callback"`, `"new_user"`, `"new_member"`, `"member_left"`, `"added_to_group"`, `"file"`,
 * `"reminder_due"`, `"checklist"`, `"job"`, `"start"` or the raw event name), `conv`, `sender`,
 * `text`, `command`, `args`, `match`, `data`, `msgId`, `replyTo`, `body`, `msgKind`, `file`,
 * `reminder`, `checklist`, `changes`, `member`, `event` (raw dict).
 */
export class Context {
  /**
   * @param {Bot} bot - The bot.
   * @param {object} ev - Raw event.
   * @param {string} [kind] - Context kind.
   */
  constructor(bot, ev, kind = "") {
    /** @type {Bot} */
    this.bot = bot;
    /** Raw event. @type {Record<string, any>} */
    this.event = ev;
    /** What happened. @type {string} */
    this.kind = kind || ev.event || "";
    // callbacks: answer where the button is (a group member may never have opened a direct
    // chat with the bot, and bots can't start one)
    /** Conversation id (`d:<peer>` direct chat, `g:<gid>` group). @type {string} */
    this.conv = (ev.event === "callback" ? ev.msg_conv : null) || ev.conv || ev.msg_conv || "";
    /** The user who caused the event (peer id). @type {string} */
    this.sender = ev.author || ev.from || "";
    const body = ev.body;
    /** Message body. @type {Record<string, any>} */
    this.body = body && typeof body === "object" ? body : {};
    /** Message kind (`"text"`, `"file"`, `"location"`…). @type {string} */
    this.msgKind = "body" in ev ? ev.kind || "" : "";
    /** Message text. @type {string} */
    this.text = typeof this.body.text === "string" ? this.body.text : "";
    /** Button data (callbacks). @type {string} */
    this.data = ev.data ?? "";
    /** Message id (for callbacks: the bot's message whose button was pressed). @type {string} */
    this.msgId = ev.msg_id || ev.id || "";
    /** Id of the quoted message, or null. @type {string|null} */
    this.replyTo = ev.reply_to ?? null;
    /** Delivered without sound/notification. @type {boolean} */
    this.silent = !!ev.silent;
    /** Regex match of `onText` / `onCallback({pattern})`. @type {RegExpExecArray|null} */
    this.match = null;
    /** File info (`onFile`): `{file_id, name, size, mime, preview, state, path}`. @type {Record<string, any>|null} */
    this.file = null;
    /** Reminder (`onReminderDue`): `{title, note, at_ms, author, mine, late, conv, msg_id}`. @type {Record<string, any>|null} */
    this.reminder = null;
    /** Checklist state (`onChecklist`). @type {Record<string, any>|null} */
    this.checklist = null;
    /** Checklist changes (`onChecklist`): `[{item, text, done, by}]`. @type {Array<Record<string, any>>} */
    this.changes = [];
    /** Group member (`onNewMember`, `onMemberLeft`): `{peer, name, role}`. @type {Record<string, any>|null} */
    this.member = null;
    /** Command name without `/`, or null. @type {string|null} */
    this.command = null;
    /** Text after the command. @type {string} */
    this.args = "";
    this._commandTarget = "";
    const t = this.text.trim();
    const m = /^(\S+)(?:\s+([\s\S]*))?$/.exec(t);
    if (m && m[1].startsWith("/") && m[1].length > 1) {
      const head = m[1].slice(1);
      const at = head.indexOf("@");
      this.command = at >= 0 ? head.slice(0, at) : head;
      this._commandTarget = at >= 0 ? head.slice(at + 1).toLowerCase() : "";
      this.args = m[2] ?? "";
    }
    /** Whether a handler ran. @type {boolean} */
    this.handled = false;
  }

  /** True when the event happened in a group or community channel. @type {boolean} */
  get isGroup() { return isGroupConv(this.conv); }
  /** Group id for group events, else null. @type {string|null} */
  get gid() { return this.isGroup ? gidOf(this.conv) : null; }
  /**
   * Display name of the sender (from the bot's cache; falls back to the first 8 characters
   * of the id). Use `await bot.nameOf(peer)` to refresh.
   * @type {string}
   */
  get senderName() { return this.sender ? this.bot.cachedName(this.sender) : ""; }
  /** True when the sender is one of this bot's admins (`admins` option). @type {boolean} */
  get isAdmin() { return this.bot.adminPeers.has(this.sender); }
  /**
   * True when the sender has bot role `role` (bot admins always do).
   * @param {string} role - Role. @returns {boolean} Whether the sender has it.
   */
  hasRole(role) { return this.isAdmin || this.bot.roles.of(this.sender).has(role); }
  /**
   * True when the sender is an admin or the owner of the current group.
   * @returns {Promise<boolean>} Whether the sender is a group admin.
   */
  async isGroupAdmin() {
    if (!this.isGroup || !this.sender) return false;
    return ["admin", "owner"].includes(await this.bot.memberRole(this.conv, this.sender));
  }

  /**
   * Send `text` to the same conversation.
   * @param {string} text - Message text (max 64 KB).
   * @param {Buttons|ReplyOptions} [buttonsOrOptions] - Buttons, or the options object.
   * @param {ReplyOptions} [options] - `{buttons, reply, silent, mentions, mentionAll}`;
   *   `reply: true` quotes the message being answered.
   * @returns {Promise<object>} The sent message.
   * @example
   * await ctx.reply("Saved ✅", { reply: true, silent: true });
   */
  reply(text, buttonsOrOptions, options) {
    const o = splitOpts(buttonsOrOptions, options);
    return this.bot.send(this.conv, text, {
      buttons: o.buttons, replyTo: o.reply && this.msgId ? this.msgId : o.replyTo,
      silent: o.silent, mentions: o.mentions, mentionAll: o.mentionAll, ttlMs: o.ttlMs,
    });
  }
  /**
   * Send a file to the same conversation (see `bot.sendFile`).
   * @param {string} path - File path. @param {FileOptions} [options] - `{preview, thumb}`.
   * @returns {Promise<object>} The file transfer entry.
   */
  replyFile(path, options) { return this.bot.sendFile(this.conv, path, options); }
  /**
   * Send a file to the same conversation (kept for older bots; prefer `replyFile`).
   * @param {string} path - File path. @returns {Promise<object>} The file transfer entry.
   */
  sendFile(path) { return this.replyFile(path); }
  /**
   * Send a checklist to the same conversation.
   * @param {string} title - Title. @param {string[]} items - Items.
   * @param {{silent?: boolean}} [options] - Options.
   * @returns {Promise<object>} The message.
   */
  replyChecklist(title, items, options) { return this.bot.sendChecklist(this.conv, title, items, options); }
  /**
   * Send a reminder to the same conversation.
   * @param {string} title - Title. @param {When} at - When.
   * @param {{note?: string, silent?: boolean}} [options] - Options.
   * @returns {Promise<object>} The message.
   */
  replyReminder(title, at, options) { return this.bot.sendReminder(this.conv, title, at, options); }
  /**
   * Send a poll to the same conversation.
   * @param {string} question - Question. @param {string[]} options - 2–10 options.
   * @returns {Promise<object>} The message.
   */
  replyPoll(question, options) { return this.bot.sendPoll(this.conv, question, options); }
  /**
   * React to the current message.
   * @param {string} emoji - Emoji. @param {boolean} [on=true] - `false` removes it.
   * @returns {Promise<void>}
   */
  react(emoji, on = true) { return this.bot.react(this.conv, this.msgId, emoji, on); }
  /**
   * Edit the current message. For callbacks that is the bot's message whose button was
   * pressed, so `ctx.edit("Done ✅")` updates it in place.
   * @param {string} text - New text. @returns {Promise<void>}
   */
  edit(text) { return this.bot.editMessage(this.event.msg_conv || this.conv, this.msgId, text); }
  /**
   * Delete the current message (others' messages in groups need admin rights).
   * @param {boolean} [forEveryone=true] - Delete for everyone. @returns {Promise<void>}
   */
  delete(forEveryone = true) { return this.bot.deleteMessage(this.event.msg_conv || this.conv, this.msgId, forEveryone); }
  /** Pin (or unpin) the current message. @param {boolean} [on=true] - Pin. @returns {Promise<void>} */
  pin(on = true) { return this.bot.pinMessage(this.event.msg_conv || this.conv, this.msgId, on); }
  /** Show (or hide) "typing…" here. @param {boolean} [on=true] - Show. @returns {Promise<void>} */
  typing(on = true) { return this.bot.typing(this.conv, on); }
  /**
   * Download the file of this message (`onFile`) and return its local path.
   * @param {{dir?: string, timeoutMs?: number}} [options] - Folder and timeout (default 300 s).
   * @returns {Promise<string>} Local path.
   */
  download(options) {
    if (!this.file) return Promise.reject(new LumoraError("This message has no file.", "sdk.no_file"));
    return this.bot.downloadFile(this.file.file_id, options);
  }
}

// ----------------------------------------------------------------------------- runtime pieces

/**
 * Send pacing (GCRA): ≤ `rate` messages/s overall, and per chat a burst of `chatBurst` then
 * `chatRate`/s. Reservations are taken in call order, so concurrent senders queue fairly.
 */
class Pacer {
  constructor(rate, chatRate = 1, chatBurst = 5) {
    this.setRate(rate);
    this.cT = 1 / chatRate;
    this.ctau = (Math.max(1, chatBurst) - 1) * this.cT;
    this.tat = new Map();
  }
  setRate(rate) {
    rate = Math.max(0.1, Number(rate));
    this.gT = 1 / rate;
    this.gtau = (Math.max(1, rate) - 1) * this.gT;
  }
  reserve(key) {
    const now = performance.now() / 1000;
    const g = Math.max(this.tat.get("*") ?? now, now);
    const c = Math.max(this.tat.get(key) ?? now, now);
    const t = Math.max(now, g - this.gtau, c - this.ctau);
    this.tat.set("*", Math.max(g, t) + this.gT);
    this.tat.set(key, Math.max(c, t) + this.cT);
    if (this.tat.size > 5000) for (const [k, v] of this.tat) if (v <= now) this.tat.delete(k);
    return t - now;
  }
  async wait(key) {
    const d = this.reserve(key);
    if (d > 0) await sleep(d * 1000);
  }
}

/** Runs jobs with the same key one after another (in order), different keys concurrently. */
class KeyedRunner {
  constructor(log) {
    this.log = log;
    this.tails = new Map();
    this.inflight = 0;
    this.closed = false;
    this.idle = [];
  }
  submit(key, fn) {
    if (this.closed) return false;
    this.inflight++;
    const k = key ?? Symbol("event");
    const prev = this.tails.get(k) || Promise.resolve();
    const p = prev
      .then(() => fn())
      .catch((e) => this.log.error(`unexpected error in worker: ${e}`, { event: "worker_error" }))
      .finally(() => {
        this.inflight--;
        if (this.tails.get(k) === p) this.tails.delete(k);
        if (this.inflight === 0) this.idle.splice(0).forEach((r) => r());
      });
    this.tails.set(k, p);
    return true;
  }
  async close(timeoutMs) {
    this.closed = true;
    if (this.inflight === 0) return true;
    let t;
    const done = await Promise.race([
      new Promise((r) => this.idle.push(() => r(true))),
      new Promise((r) => { t = setTimeout(() => r(false), timeoutMs); }),
    ]);
    clearTimeout(t);
    return done;
  }
}

class Route {
  constructor(fn, { pattern = null, data = null, kinds = ["text"], chats = "all", exts = null } = {}) {
    this.fn = fn;
    this.pattern = toRegExp(pattern);
    this.data = data;
    this.kinds = kinds ? [...kinds] : null;
    this.chats = chats || "all";
    this.exts = exts ? exts.map((e) => String(e).toLowerCase().replace(/^\./, "")) : null;
    this.specific = this.pattern !== null || data !== null || this.exts !== null;
  }
}

const chatOk = (chats, ctx) => !chats || chats === "all" || (chats === "group") === ctx.isGroup;

/** Accept `(fn)`, `(fn, opts)` or `(opts, fn)`. */
function fnOpts(a, b) {
  return typeof a === "function" ? [a, b || {}] : [b, a || {}];
}

const MAX_TIMER = 2 ** 31 - 1;

// ----------------------------------------------------------------------------- bot

/**
 * A Lumora bot.
 *
 * Options: `name` (display name for a bot made without Bot Studio, for tests), `token`
 * (Bot Studio token; default `$LUMORA_BOT_TOKEN`, never hard-code it in public code),
 * `dataDir` (identity, messages, storage and downloads; default `./lumora-bot`, one folder
 * per bot, keep it private and back it up), `binary` (path to `lumorad`; default
 * `$LUMORAD`, then `lumorad`), `about`, `lan` (also find users on the local network),
 * `publicDirectory` (let people find the bot by ID / @name), `extraArgs`, `admins` (peer ids
 * or `@name·tag` handles), `ratePerSec` (overall send rate, default 15/s; per chat: burst 5,
 * then 1/s), `downloadsDir` (default `<dataDir>/downloads`), `autoRestart` (default true),
 * `allowGroups` (default true), `lang` (`"vi"`/`"en"`: error message language), `logJson`,
 * `logLevel`, `runnerLog` (Lumora Bot Runner's own log; default `<dataDir>/runner.log`,
 * `""` discards), `helpCommand` (auto `/help`, default true), `denyText`.
 *
 * @example
 * const bot = new Bot({ token: process.env.LUMORA_BOT_TOKEN, admins: ["@owner·k7q2xz"] });
 */
export class Bot {
  /** @param {BotOptions} [options] - Bot options. */
  constructor({
    name = "", token, dataDir = "./lumora-bot", binary, about = "", lan = true, publicDirectory = true,
    extraArgs = [], admins = [], ratePerSec = 15, workers, downloadsDir, autoRestart = true, allowGroups = true,
    lang = null, logJson, logLevel, runnerLog, helpCommand = true,
    denyText = "⛔ Bạn không có quyền dùng lệnh này. / You are not allowed to use this command.",
  } = {}) {
    void workers; // accepted for parity with Python; JS handlers are async
    /** The SDK's logger (`debug/info/warn/error(msg, fields)`); use it in handlers too. */
    this.log = new Logger(logJson ?? (process.env.LUMORA_BOT_LOG_FORMAT || "").toLowerCase() === "json",
      logLevel || process.env.LUMORA_BOT_LOG_LEVEL || "info");
    // token from the in-app Bot Studio (recommended): name/@username come from it
    /** @type {string|undefined} */
    this.token = token || process.env.LUMORA_BOT_TOKEN || undefined;
    if (!name && !this.token) throw new Error("give the bot a name, or a token created in the app (Bot Studio)");
    this.name = name;
    this.dataDir = dataDir;
    this.about = about;
    this.binary = binary || process.env.LUMORAD || "lumorad";
    this.extraArgs = [...extraArgs, ...(lan ? [] : ["--no-lan"]), ...(publicDirectory ? [] : ["--no-directory"])];
    this.downloadsDir = downloadsDir || join(dataDir, "downloads");
    this.autoRestart = autoRestart;
    this.allowGroups = allowGroups;
    this.lang = lang;
    this.helpCommand = helpCommand;
    this.denyText = denyText;
    this.runnerLog = runnerLog ?? join(dataDir, "runner.log");
    this.ratePerSec = ratePerSec;
    mkdirSync(dataDir, { recursive: true });
    /** Persistent key/value store. @type {Storage} */
    this.storage = new Storage(join(dataDir, "bot-storage.json"));
    /** Bot roles. @type {Roles} */
    this.roles = new Roles(this.storage);
    this.adminSpecs = [...admins];
    /** Resolved bot admins (peer ids). @type {Set<string>} */
    this.adminPeers = new Set();
    /** Registered commands: name → `{fn, description, hidden, chats}`. */
    this.commands = new Map();
    /** The bot's own account (`peer`, `short_id`, `name`, `username`, `handle`, `version`) once started. */
    this.me = null;
    /** Lumora Bot Runner process (internal). */
    this.proc = null;
    this._pacer = new Pacer(ratePerSec);
    this._routes = new Map();
    this._raw = new Map();
    this._middleware = [];
    this._errorHandlers = [];
    this._startHooks = [];
    this._runner = new KeyedRunner(this.log);
    this._jobs = new Set();
    this._pending = new Map();
    this._nextId = 1;
    this._gen = 0;
    this._ready = false;
    this._readyGate = gate();
    this._started = false;
    this._stopping = false;
    this._stopped = false;
    this._stoppedGate = gate();
    this._restarts = [];
    this._groups = new Map();
    this._names = new Map();
    this._checklists = new Map();
    this._fileWaiters = new Map();
  }

  #route(name, r) {
    if (!this._routes.has(name)) this._routes.set(name, []);
    this._routes.get(name).push(r);
    return this;
  }

  // ================================================================== handlers
  /**
   * Register `/name`.
   * @param {string} name - Command name without `/` (`/name@yourbot` works too in groups).
   * @param {string} description - Shown in the app's command menu and `/help`.
   * @param {Handler} fn - Handler.
   * @param {CommandOptions} [options] - `{adminOnly, role, chats: "all"|"private"|"group", hidden}`.
   *   `adminOnly` / `role` restrict who may use it and hide it from the menu.
   * @returns {this} The bot (chainable).
   * @example
   * bot.command("ban", "Ban a user", (ctx) => …, { adminOnly: true, chats: "group" });
   */
  command(name, description, fn, { adminOnly = false, role = null, chats = "all", hidden = false } = {}) {
    if (typeof description === "function") [description, fn] = ["", description];
    const guarded = (ctx) => {
      if ((adminOnly && !ctx.isAdmin) || (role && !ctx.hasRole(role))) return ctx.reply(this.denyText);
      return this.#callHandler(fn, ctx);
    };
    this.commands.set(String(name).replace(/^\//, ""), { fn: guarded, description: description || "", hidden: adminOnly || !!role || hidden, chats });
    return this;
  }

  /**
   * Handle incoming messages that are not commands. `onMessage(fn)` gets every text message;
   * filters: `pattern` (regex searched in the text; the first matching handler wins and
   * catch-all handlers don't run; the match is in `ctx.match`), `kinds` (default `["text"]`;
   * also `"file"`, `"voice"`, `"sticker"`, `"location"`, `"contact"`, `"poll"`,
   * `"checklist"`, `"reminder"`; `null` = all), `chats` (`"all"`, `"private"`, `"group"`).
   * @param {Handler|MessageFilter} fnOrFilter - Handler, or the filter.
   * @param {Handler|MessageFilter} [filterOrFn] - The other one.
   * @returns {this} The bot (chainable).
   * @example
   * bot.onMessage({ kinds: ["location"] }, (ctx) => ctx.reply(`📍 ${ctx.body.lat}, ${ctx.body.lon}`));
   */
  onMessage(fnOrFilter, filterOrFn) {
    const [fn, o] = fnOpts(fnOrFilter, filterOrFn);
    return this.#route("message", new Route(fn, { pattern: o.pattern, kinds: o.kinds === undefined ? ["text"] : o.kinds, chats: o.chats }));
  }

  /**
   * Handle text messages matching `pattern` (regex, searched anywhere in the text).
   * @param {RegExp|string} pattern - Pattern. @param {Handler} fn - Handler.
   * @param {{chats?: Chats}} [options] - Options.
   * @returns {this} The bot (chainable).
   * @example
   * bot.onText(/\bprice\b/i, (ctx) => ctx.reply("From 25k"));
   */
  onText(pattern, fn, { chats = "all" } = {}) {
    return this.#route("message", new Route(fn, { pattern, kinds: ["text"], chats }));
  }

  /**
   * Handle inline button presses on the bot's messages. Filters: `data` (exact; ending in
   * `*` = prefix, e.g. `"buy:*"`), `pattern` (regex on the data, `ctx.match`).
   * @param {Handler|CallbackFilter} fnOrFilter - Handler, or the filter.
   * @param {Handler|CallbackFilter} [filterOrFn] - The other one.
   * @returns {this} The bot (chainable).
   */
  onCallback(fnOrFilter, filterOrFn) {
    const [fn, o] = fnOpts(fnOrFilter, filterOrFn);
    return this.#route("callback", new Route(fn, { data: o.data ?? null, pattern: o.pattern ?? null }));
  }

  /**
   * Called when someone starts a chat with the bot for the first time (`ctx.conv` is their
   * direct chat).
   * @param {Handler} fn - Handler. @returns {this} The bot.
   */
  onNewUser(fn) { return this.#route("new_user", new Route(fn)); }

  /**
   * Called when someone joins a group the bot is in (`ctx.member` = `{peer, name, role}`,
   * `ctx.sender` = the new member, `ctx.conv` = the group). `name` is the 9-digit ID when the
   * bot doesn't know the person yet: greet them with `{ mentions: [ctx.sender] }` instead.
   * Needs full access ("read all") in that group: a privacy-mode bot is not told about
   * membership changes.
   * @param {Handler} fn - Handler. @returns {this} The bot.
   */
  onNewMember(fn) { return this.#route("new_member", new Route(fn)); }

  /**
   * Called when a member leaves or is removed from a group (full access needed).
   * @param {Handler} fn - Handler. @returns {this} The bot.
   */
  onMemberLeft(fn) { return this.#route("member_left", new Route(fn)); }

  /**
   * Called when a group admin adds the bot to a group (`ctx.conv` = the group).
   * @param {Handler} fn - Handler. @returns {this} The bot.
   */
  onAddedToGroup(fn) { return this.#route("added_to_group", new Route(fn)); }

  /**
   * Handle received files. `ctx.file` has `file_id`, `name`, `size`, `mime` and `preview`
   * (`{kind, text, pages, lines}` or null, available before downloading). Call
   * `await ctx.download()` to get the file on disk. Filter: `extensions` (e.g.
   * `["txt", "csv"]`; such handlers win over catch-alls), `chats`.
   * @param {Handler|FileFilter} fnOrFilter - Handler, or the filter.
   * @param {Handler|FileFilter} [filterOrFn] - The other one.
   * @returns {this} The bot (chainable).
   */
  onFile(fnOrFilter, filterOrFn) {
    const [fn, o] = fnOpts(fnOrFilter, filterOrFn);
    return this.#route("file", new Route(fn, { exts: o.extensions ?? null, chats: o.chats }));
  }

  /**
   * Called when a reminder in one of the bot's chats is due. `ctx.reminder` has `title`,
   * `note`, `at_ms`, `author`, `mine` and `late`.
   * @param {Handler} fn - Handler. @returns {this} The bot.
   */
  onReminderDue(fn) { return this.#route("reminder_due", new Route(fn)); }

  /**
   * Called when someone ticks / unticks checklist items or items are added.
   * `ctx.checklist` = `{msg_id, conv, title, items: [{id, text, done, by, at}], done, total}`;
   * `ctx.changes` = `[{item, text, done, by}]`. Changes made by the bot itself are not reported.
   * @param {Handler} fn - Handler. @returns {this} The bot.
   */
  onChecklist(fn) { return this.#route("checklist", new Route(fn)); }

  /**
   * Low-level: receive every raw event `name` (`"message_update"`, `"typing"`, `"*"` for
   * all). `ctx.event` is the raw object. Runs in addition to other handlers.
   * @param {string} name - Event name. @param {Handler} fn - Handler.
   * @returns {this} The bot (chainable).
   */
  onEvent(name, fn) {
    if (!this._raw.has(name)) this._raw.set(name, []);
    this._raw.get(name).push(fn);
    return this;
  }

  /**
   * Wrap every handled update. `fn(ctx, next)` must `await next()` to continue; not calling
   * it stops the update (bans, per-user limits, logging).
   * @param {Middleware} fn - Middleware. @returns {this} The bot (chainable).
   * @example
   * bot.use(async (ctx, next) => { const t = Date.now(); await next(); bot.log.info("handled", { kind: ctx.kind, ms: Date.now() - t }); });
   */
  use(fn) { this._middleware.push(fn); return this; }

  /** Alias of `use`. @param {Middleware} fn - Middleware. @returns {this} The bot. */
  middleware(fn) { return this.use(fn); }

  /**
   * Called with `(ctx, error)` when a handler throws. The error is logged anyway.
   * @param {(ctx: Context, err: unknown) => any} fn - Error handler. @returns {this} The bot.
   */
  onError(fn) { this._errorHandlers.push(fn); return this; }

  /**
   * Called once the bot is online (and again after an automatic restart).
   * @param {() => any} fn - Hook. @returns {this} The bot.
   */
  onStart(fn) { this._startHooks.push(fn); return this; }

  // ================================================================== jobs
  #arm(job) {
    if (job.cancelled || this._stopping) return;
    const delay = job.next - Date.now();
    job.timer = setTimeout(() => {
      if (job.next - Date.now() > 50) return this.#arm(job);   // long delays are armed in steps
      this.#runJob(job);
      const nxt = job.reschedule();
      if (nxt == null) { this._jobs.delete(job); return; }
      job.next = nxt;
      this.#arm(job);
    }, Math.min(Math.max(0, delay), MAX_TIMER));
  }
  #addJob(job) {
    this._jobs.add(job);
    if (this._started) this.#arm(job);
    return job;
  }
  #runJob(job) {
    if (job.cancelled || this._stopping) return;
    this._runner.submit(`job:${job.name}`, () => this.#callHandler(() => job.fn(), new Context(this, { event: "job" }, "job")));
  }

  /**
   * Run `fn()` every `seconds`. Returns the job; `bot.cancel(job)` stops it.
   * @param {number} seconds - Interval in seconds. @param {() => any} fn - Job.
   * @param {{firstIn?: number}} [options] - First run after `firstIn` seconds (default: `seconds`).
   * @returns {Job} The job.
   */
  every(seconds, fn, { firstIn } = {}) {
    const job = { name: fn.name || "job", fn, next: Date.now() + (firstIn ?? seconds) * 1000, cancelled: false };
    job.reschedule = () => Math.max(job.next + seconds * 1000, Date.now() + 1);
    return this.#addJob(job);
  }

  /**
   * Run `fn()` every day at local time `"HH:MM"`.
   * @param {string} at - Local time `"HH:MM"`. @param {() => any} fn - Job.
   * @returns {Job} The job.
   */
  daily(at, fn) {
    const [hh, mm] = String(at).split(":").map(Number);
    const nextAfter = (t) => {
      const d = new Date(t);
      const n = new Date(d.getFullYear(), d.getMonth(), d.getDate(), hh, mm, 0, 0);
      if (n.getTime() <= t) n.setDate(n.getDate() + 1);
      return n.getTime();
    };
    const job = { name: fn.name || "daily", fn, next: nextAfter(Date.now()), cancelled: false };
    job.reschedule = () => nextAfter(job.next + 1000);
    return this.#addJob(job);
  }

  /**
   * Run `fn()` once, `seconds` from now.
   * @param {number} seconds - Delay in seconds. @param {() => any} fn - Job.
   * @returns {Job} The job.
   */
  after(seconds, fn) {
    return this.#addJob({ name: fn.name || "once", fn, next: Date.now() + seconds * 1000, cancelled: false, reschedule: () => null });
  }

  /**
   * Cancel a job returned by `every`, `daily` or `after`.
   * @param {Job} job - The job.
   */
  cancel(job) {
    job.cancelled = true;
    clearTimeout(job.timer);
    this._jobs.delete(job);
  }

  // ================================================================== low-level API
  /**
   * Run any command of the Lumora JSON API and return its `data`. Commands bots may not use
   * (remote control, recovery phrase, backups, passwords, calls) reject with
   * `NotAllowedForBots`.
   * @param {string} cmd - Command name. @param {object} [args={}] - Arguments.
   * @param {number} [timeoutMs=60000] - Timeout.
   * @returns {Promise<any>} The command's `data`.
   * @throws {LumoraError} The command failed (`.code`, `.message`, `.detail`).
   * @throws {LumoraTimeout} No answer in time. @throws {RunnerStopped} Runner not running.
   */
  async call(cmd, args = {}, timeoutMs = 60000) {
    if (isBlockedCommand(cmd)) throw new NotAllowedForBots("This command is not available to bots.", "sdk.not_for_bots", cmd, cmd);
    return this.#call(cmd, args, timeoutMs);
  }

  #setReady() { this._ready = true; this._readyGate.open(); }
  #clearReady() { if (this._ready) { this._ready = false; this._readyGate = gate(); } }

  async #waitReady(ms) {
    let t;
    const r = await Promise.race([
      this._readyGate.p.then(() => true),
      this._stoppedGate.p.then(() => false),
      new Promise((res) => { t = setTimeout(() => res(false), ms); }),
    ]);
    clearTimeout(t);
    return r;
  }

  async #call(cmd, args, timeoutMs = 60000, waitReady = true) {
    const deadline = Date.now() + timeoutMs;
    if (waitReady && !this._ready) {
      if (this._stopped || !(await this.#waitReady(timeoutMs))) {
        throw new RunnerStopped("Lumora Bot Runner is not running.", "sdk.runner_stopped", null, cmd);
      }
    }
    const proc = this.proc;
    if (!proc || proc.exitCode !== null || proc.signalCode !== null || !proc.stdin || proc.stdin.destroyed || !proc.stdin.writable) {
      throw new RunnerStopped("Lumora Bot Runner is not running.", "sdk.runner_stopped", null, cmd);
    }
    const id = this._nextId++;
    return new Promise((resolveP, reject) => {
      const timer = setTimeout(() => {
        this._pending.delete(id);
        reject(new LumoraTimeout(`No answer from Lumora Bot Runner for '${cmd}'.`, "sdk.timeout", null, cmd));
      }, Math.max(0, deadline - Date.now()));
      this._pending.set(id, {
        timer,
        done: (r) => {
          clearTimeout(timer);
          if (r.ok) return resolveP(r.data ?? null);
          // "error" is a plain sentence; "code" is stable; "detail" has the technical cause
          const Cls = r.code === "sdk.runner_stopped" ? RunnerStopped : LumoraError;
          reject(new Cls(r.error || "error", r.code, r.detail ?? null, cmd));
        },
      });
      try {
        proc.stdin.write(JSON.stringify({ ...args, id, cmd }) + "\n");
      } catch (e) {
        clearTimeout(timer);
        this._pending.delete(id);
        reject(new RunnerStopped("Lumora Bot Runner is not running.", "sdk.runner_stopped", String(e), cmd));
      }
    });
  }

  #failPending(detail) {
    for (const [id, p] of this._pending) {
      this._pending.delete(id);
      p.done({ ok: false, error: "Lumora Bot Runner stopped.", code: "sdk.runner_stopped", detail });
    }
  }

  async #sendCmd(conv, cmd, args, timeoutMs = 60000) {
    await this._pacer.wait(conv);
    return this.call(cmd, args, timeoutMs);
  }

  // ================================================================== messages
  /**
   * Send a text message (paced so receivers never see the bot as spam).
   * @param {string} conv - Conversation id (`d:<peer>`, `g:<gid>`); a bare peer id works too.
   * @param {string} text - Up to 64 KB of UTF-8 text.
   * @param {Buttons|SendOptions} [buttonsOrOptions] - Buttons, or the options object.
   * @param {SendOptions} [options] - `{buttons, replyTo, silent, mentions, mentionAll, ttlMs}`:
   *   `silent` = no sound/notification; `mentions` = peer ids; `ttlMs` = disappear after read.
   * @returns {Promise<Message>} The sent message.
   * @example
   * await bot.send(conv, "Sale today!", { silent: true, buttons: [[Button("Open", "open")]] });
   */
  async send(conv, text, buttonsOrOptions, options) {
    const o = splitOpts(buttonsOrOptions, options);
    conv = convOf(conv);
    const args = { conv, text: String(text), buttons: normButtons(o.buttons) };
    if (o.replyTo) args.reply_to = o.replyTo;
    if (o.silent) args.silent = true;
    if (o.mentions?.length) args.mentions = [...o.mentions];
    if (o.mentionAll) args.mention_all = true;
    if (o.ttlMs) args.ttl_ms = Math.trunc(o.ttlMs);
    return this.#sendCmd(conv, "send_message", args);
  }

  /**
   * Send a file. Text/code files get an automatic preview of their first lines.
   * @param {string} conv - Conversation id. @param {string} path - Local file path.
   * @param {FileOptions} [options] - `preview`: a text snippet (string) or
   *   `{kind, text, pages, lines}` shown before download (text cut to 4 KB); `thumb`: path to a
   *   JPEG/PNG/WebP ≤ 64 KB shown with the file.
   * @returns {Promise<FileEntry>} The file transfer entry.
   */
  async sendFile(conv, path, { preview, thumb } = {}) {
    conv = convOf(conv);
    const args = { conv, path: resolve(path) };
    if (preview != null) {
      const p = typeof preview === "string" ? { kind: "text", text: preview } : { ...preview };
      if (typeof p.text === "string") p.text = clipUtf8(p.text, MAX_PREVIEW_TEXT_BYTES);
      args.preview = p;
    }
    if (thumb) {
      const b = readFileSync(thumb);
      if (b.length > MAX_PREVIEW_IMAGE_BYTES) {
        throw new LumoraError("The preview picture must be at most 64 KB.", "sdk.preview_too_large", `${b.length} bytes`, "send_file");
      }
      args.thumb_b64 = b.toString("base64");
    }
    return this.#sendCmd(conv, "send_file", args, 120000);
  }

  /**
   * Send a poll (2–10 options, question ≤ 300 chars). Votes arrive as `message_update` events.
   * @param {string} conv - Conversation id. @param {string} question - Question.
   * @param {string[]} options - Options. @returns {Promise<Message>} The message.
   */
  async sendPoll(conv, question, options) {
    conv = convOf(conv);
    return this.#sendCmd(conv, "send_poll", { conv, question, options: [...options] });
  }

  /**
   * Send a checklist (1–100 items, ≤ 200 chars each). Anyone in the chat can tick items;
   * see `onChecklist`.
   * @param {string} conv - Conversation id. @param {string} title - Title.
   * @param {string[]} items - Items. @param {{silent?: boolean}} [options] - Options.
   * @returns {Promise<Message>} The message; `body.items` = `[{id, text}]` (ids start at 1).
   */
  async sendChecklist(conv, title, items, { silent = false } = {}) {
    conv = convOf(conv);
    const m = await this.#sendCmd(conv, "send_checklist", { conv, title, items: [...items], silent });
    this.#rememberChecklist(m);
    return m;
  }

  /**
   * Tick (`done=true`) or untick a checklist item.
   * @param {string} conv - Conversation id. @param {string} msgId - Checklist message id.
   * @param {number} item - Item id. @param {boolean} [done=true] - Ticked.
   * @returns {Promise<void>}
   */
  async checklistToggle(conv, msgId, item, done = true) {
    await this.call("checklist_toggle", { conv: convOf(conv), msg_id: msgId, item: Math.trunc(item), done: !!done });
  }

  /**
   * Add items to a checklist the bot sent.
   * @param {string} conv - Conversation id. @param {string} msgId - Checklist message id.
   * @param {string[]} items - New items. @returns {Promise<void>}
   */
  async checklistAdd(conv, msgId, items) {
    await this.call("checklist_add", { conv: convOf(conv), msg_id: msgId, items: [...items] });
  }

  /**
   * Current state of a checklist, or null if not found.
   * @param {string} conv - Conversation id. @param {string} msgId - Checklist message id.
   * @returns {Promise<Checklist|null>} `{msg_id, conv, title, items: [{id, text, done, by, at}], done, total}`.
   */
  async checklist(conv, msgId) {
    const st = this._checklists.get(msgId) || (await this.#loadChecklist(convOf(conv), msgId));
    return st ? Bot.#checklistView(st) : null;
  }

  /**
   * Send a reminder. Everyone in the chat (and the bot) gets `reminder_due` at `at`.
   * @param {string} conv - Conversation id. @param {string} title - ≤ 200 chars.
   * @param {When} at - `Date`, epoch milliseconds, or `{ inMs }` from now. Must be in the future.
   * @param {{note?: string, silent?: boolean}} [options] - `note` ≤ 1000 chars.
   * @returns {Promise<Message>} The message.
   */
  async sendReminder(conv, title, at, { note = "", silent = false } = {}) {
    conv = convOf(conv);
    return this.#sendCmd(conv, "send_reminder", { conv, title, at_ms: toMs(at), note, silent });
  }

  /**
   * Cancel a reminder the bot sent.
   * @param {string} conv - Conversation id. @param {string} msgId - Reminder message id.
   * @returns {Promise<void>}
   */
  async reminderCancel(conv, msgId) { await this.call("reminder_cancel", { conv: convOf(conv), msg_id: msgId }); }

  /**
   * Upcoming reminders known to the bot (soonest first).
   * @returns {Promise<Reminder[]>} `[{conv, msg_id, at_ms, title, note, author}]`.
   */
  reminders() { return this.call("reminders"); }

  /**
   * Send a built-in sticker (`pack`, `sticker`) or a custom one by `{hash}`.
   * @param {string} conv - Conversation id. @param {string} [pack] - Pack.
   * @param {string} [sticker] - Sticker id. @param {{hash?: string}} [options] - Custom sticker hash.
   * @returns {Promise<Message>} The message.
   */
  async sendSticker(conv, pack = "", sticker = "", { hash } = {}) {
    conv = convOf(conv);
    return this.#sendCmd(conv, "send_sticker", hash ? { conv, hash } : { conv, pack, sticker });
  }

  /**
   * Send a location (`liveMinutes > 0`: live location, update with `updateLiveLocation`, max 8 h).
   * @param {string} conv - Conversation id. @param {number} lat - Latitude. @param {number} lon - Longitude.
   * @param {string} [label=""] - Label. @param {{accuracyM?: number, liveMinutes?: number}} [options] - Options.
   * @returns {Promise<Message>} The message.
   */
  async sendLocation(conv, lat, lon, label = "", { accuracyM = 0, liveMinutes = 0 } = {}) {
    conv = convOf(conv);
    return this.#sendCmd(conv, "send_location", { conv, lat, lon, label, accuracy_m: accuracyM, live_minutes: liveMinutes });
  }

  /**
   * Move a live location, or end it (`stop: true`).
   * @param {string} conv - Conversation id. @param {string} msgId - Location message id.
   * @param {number} lat - Latitude. @param {number} lon - Longitude.
   * @param {{accuracyM?: number, stop?: boolean}} [options] - Options. @returns {Promise<void>}
   */
  async updateLiveLocation(conv, msgId, lat, lon, { accuracyM = 0, stop = false } = {}) {
    await this.call("update_live_location", { conv: convOf(conv), msg_id: msgId, lat, lon, accuracy_m: accuracyM, stop });
  }

  /**
   * Send a contact card of user `peer` (or of the bot itself).
   * @param {string} conv - Conversation id. @param {string} peer - Peer id.
   * @returns {Promise<Message>} The message.
   */
  async sendContact(conv, peer) {
    conv = convOf(conv);
    return this.#sendCmd(conv, "send_contact", { conv, peer });
  }

  /**
   * Send a voice message (Ogg/Opus file ≤ 32 MB; `wave`: 0–255 bars for the waveform).
   * @param {string} conv - Conversation id. @param {string} path - Audio file.
   * @param {number} durationMs - Duration. @param {number[]} [wave] - Waveform bars.
   * @returns {Promise<Message>} The message.
   */
  async sendVoice(conv, path, durationMs, wave = []) {
    conv = convOf(conv);
    return this.#sendCmd(conv, "send_voice", { conv, path: resolve(path), duration_ms: Math.trunc(durationMs), wave: [...wave] });
  }

  /**
   * Edit the text of one of the bot's messages.
   * @param {string} conv - Conversation id. @param {string} msgId - Message id.
   * @param {string} text - New text. @returns {Promise<void>}
   */
  async editMessage(conv, msgId, text) { await this.call("edit_message", { conv: convOf(conv), msg_id: msgId, text }); }

  /**
   * Delete a message. In groups, deleting others' messages needs admin rights.
   * @param {string} conv - Conversation id. @param {string} msgId - Message id.
   * @param {boolean} [forEveryone=true] - Delete for everyone. @returns {Promise<void>}
   */
  async deleteMessage(conv, msgId, forEveryone = true) {
    await this.call("delete_message", { conv: convOf(conv), msg_id: msgId, for_everyone: forEveryone });
  }

  /**
   * Pin (`on=true`) or unpin a message.
   * @param {string} conv - Conversation id. @param {string} msgId - Message id.
   * @param {boolean} [on=true] - Pin. @returns {Promise<void>}
   */
  async pinMessage(conv, msgId, on = true) { await this.call("pin_message", { conv: convOf(conv), msg_id: msgId, on }); }

  /**
   * Pinned messages of a conversation.
   * @param {string} conv - Conversation id. @returns {Promise<Message[]>} Messages.
   */
  pinnedMessages(conv) { return this.call("pinned_messages", { conv: convOf(conv) }); }

  /**
   * Add (or remove) an emoji reaction.
   * @param {string} conv - Conversation id. @param {string} msgId - Message id.
   * @param {string} emoji - Emoji. @param {boolean} [on=true] - Add. @returns {Promise<void>}
   */
  async react(conv, msgId, emoji, on = true) { await this.call("react", { conv: convOf(conv), msg_id: msgId, emoji, on }); }

  /**
   * Forward a message to another conversation.
   * @param {string} msgId - Message id. @param {string} toConv - Target conversation.
   * @returns {Promise<Message>} The new message.
   */
  async forwardMessage(msgId, toConv) {
    toConv = convOf(toConv);
    return this.#sendCmd(toConv, "forward_message", { msg_id: msgId, to_conv: toConv });
  }

  /**
   * Recent messages of a conversation, oldest first. File messages carry `body.preview` and
   * `file` (`state`, `path` once downloaded).
   * @param {string} conv - Conversation id.
   * @param {{limit?: number, before?: number}} [options] - `limit` (default 50), `before` (hlc).
   * @returns {Promise<Message[]>} Messages.
   */
  messages(conv, { limit = 50, before } = {}) {
    const args = { conv: convOf(conv), limit: Math.trunc(limit) };
    if (before != null) args.before = before;
    return this.call("messages", args);
  }

  /** Show (or hide) "typing…". @param {string} conv - Conversation id. @param {boolean} [on=true] - Show. @returns {Promise<void>} */
  async typing(conv, on = true) { await this.call("typing", { conv: convOf(conv), on }); }

  /** Mark a conversation as read. @param {string} conv - Conversation id. @returns {Promise<void>} */
  async markRead(conv) { await this.call("mark_read", { conv: convOf(conv) }); }

  /**
   * Let Lumora send `text` at `at` (kept while the bot runs; ≤ 500 pending).
   * @param {string} conv - Conversation id. @param {string} text - Text. @param {When} at - When.
   * @returns {Promise<{id: string, conv: string, text: string, at: number}>} The scheduled entry.
   */
  scheduleMessage(conv, text, at) { return this.call("schedule_message", { conv: convOf(conv), text, at: toMs(at) }); }

  /** Pending scheduled messages. @returns {Promise<Array<{id: string, conv: string, text: string, at: number}>>} Entries. */
  scheduledMessages() { return this.call("scheduled_messages"); }

  /** Cancel a scheduled message. @param {string} schedId - Entry id. @returns {Promise<void>} */
  async cancelScheduled(schedId) { await this.call("cancel_scheduled", { sched_id: schedId }); }

  // ================================================================== files
  /**
   * All file transfers. `state`: 0 offered, 1 transferring, 2 done, 3 failed, 4 cancelled, 5 paused.
   * @returns {Promise<FileEntry[]>} Transfers.
   */
  files() { return this.call("files"); }

  /**
   * Start (or resume) downloading a received file into `dir` (default: `downloadsDir`).
   * @param {string} fileId - File id. @param {string} [dir] - Folder. @returns {Promise<void>}
   */
  async acceptFile(fileId, dir) {
    const args = { file_id: fileId };
    if (dir) args.dir = resolve(dir);
    await this.call("accept_file", args);
  }

  /** Stop a transfer. @param {string} fileId - File id. @returns {Promise<void>} */
  async cancelFile(fileId) { await this.call("cancel_file", { file_id: fileId }); }

  /**
   * Download a received file and wait until it is complete. Small files from users are
   * downloaded automatically; this also works for those.
   * @param {string} fileId - File id.
   * @param {{dir?: string, timeoutMs?: number}} [options] - Folder and timeout (default 300 s).
   * @returns {Promise<string>} Local path.
   * @throws {LumoraError} `sdk.download_failed` (failed / cancelled) or `sdk.timeout`.
   */
  async downloadFile(fileId, { dir, timeoutMs = 300000 } = {}) {
    const w = { wake: null };
    this._fileWaiters.set(fileId, w);
    try {
      let f = await this.#fileEntry(fileId);
      if (!(f && f.state === 2 && f.path && existsSync(f.path))) await this.acceptFile(fileId, dir);
      const deadline = Date.now() + timeoutMs;
      for (;;) {
        f = await this.#fileEntry(fileId);
        if (f && f.state === 2 && f.path) return f.path;
        if (f && (f.state === 3 || f.state === 4)) throw new LumoraError("The file could not be downloaded.", "sdk.download_failed", `state ${f.state}`, "accept_file");
        const left = deadline - Date.now();
        if (left <= 0) throw new LumoraTimeout("The download did not finish in time.", "sdk.timeout", fileId, "accept_file");
        let t;
        await new Promise((r) => { w.wake = r; t = setTimeout(r, Math.min(1000, left)); });
        clearTimeout(t);
      }
    } finally {
      this._fileWaiters.delete(fileId);
    }
  }

  async #fileEntry(fileId) {
    return (await this.files()).find((f) => f.id === fileId) || null;
  }

  // ================================================================== groups
  /** Groups the bot is in. @returns {Promise<GroupInfo[]>} Groups. */
  groups() { return this.call("groups"); }

  /**
   * Details of a group.
   * @param {string} group - gid or `g:` conversation id. @returns {Promise<GroupInfo>} The group.
   */
  groupInfo(group) { return this.call("group_info", { gid: gidOf(group) }); }

  /**
   * What the bot may do in a group: `{readAll, admin}`. `readAll` = an admin allowed "read all
   * messages" (full access); `admin` = the bot is a group admin (needed for ban / slow mode /
   * purge / deleting others' messages).
   * @param {string} group - gid or conversation id.
   * @returns {Promise<{readAll: boolean, admin: boolean}>} Access.
   */
  async groupAccess(group) {
    const g = await this.groupInfo(group);
    const me = this.me?.peer;
    const b = (g.bots || []).find((x) => x.peer === me);
    return { readAll: !b || !!b.read_all, admin: ["admin", "owner"].includes(g.my_role) };
  }

  /**
   * Role of `peer` in a group.
   * @param {string} group - gid or conversation id. @param {string} peer - Peer id.
   * @returns {Promise<"owner"|"admin"|"member"|null>} The role, or null.
   */
  async memberRole(group, peer) {
    const gid = gidOf(group);
    let members = this._groups.get(gid);
    if (!members || !members.has(peer)) {
      try { this.#trackGroup(await this.groupInfo(gid)); } catch (e) { if (e instanceof LumoraError) return null; throw e; }
      members = this._groups.get(gid) || new Map();
    }
    return members.get(peer)?.role ?? null;
  }

  /**
   * Ban (or unban) a member: removes them and stops them from rejoining. The bot must be a
   * group admin with full access.
   * @param {string} group - gid or conversation id. @param {string} peer - Peer id.
   * @param {boolean} [ban=true] - Ban. @returns {Promise<void>}
   */
  async groupBan(group, peer, ban = true) { await this.call("group_ban", { gid: gidOf(group), peer, ban }); }

  /** Lift a ban. @param {string} group - gid or conversation id. @param {string} peer - Peer id. @returns {Promise<void>} */
  groupUnban(group, peer) { return this.groupBan(group, peer, false); }

  /**
   * Remove (kick) a member; they may be added again. Needs admin rights.
   * @param {string} group - gid or conversation id. @param {string} peer - Peer id. @returns {Promise<void>}
   */
  async groupRemove(group, peer) { await this.call("group_remove", { gid: gidOf(group), peer }); }

  /**
   * Change group settings (admin): `slowModeS` (seconds between two messages of a member,
   * 0 = off) and `adminsOnly` (only admins may post).
   * @param {string} group - gid or conversation id.
   * @param {{slowModeS?: number, adminsOnly?: boolean}} settings - Settings. @returns {Promise<void>}
   */
  async groupSettings(group, { slowModeS, adminsOnly } = {}) {
    const args = { gid: gidOf(group) };
    if (slowModeS != null) args.slow_mode_s = Math.trunc(slowModeS);
    if (adminsOnly != null) args.admins_only = !!adminsOnly;
    await this.call("group_settings", args);
  }

  /**
   * Shortcut for `groupSettings(group, { slowModeS: seconds })`.
   * @param {string} group - gid or conversation id. @param {number} seconds - 0 = off. @returns {Promise<void>}
   */
  setSlowMode(group, seconds) { return this.groupSettings(group, { slowModeS: seconds }); }

  /**
   * Delete every message of `peer` in the group (admin; e.g. after spam).
   * @param {string} group - gid or conversation id. @param {string} peer - Peer id. @returns {Promise<void>}
   */
  async groupPurgeMember(group, peer) { await this.call("group_purge_member", { gid: gidOf(group), peer }); }

  /** Leave a group. @param {string} group - gid or conversation id. @returns {Promise<void>} */
  async groupLeave(group) { await this.call("group_leave", { gid: gidOf(group) }); }

  /**
   * Find public groups by `@handle` or `@handle·tag` (read-only; bots join a group only when
   * one of its admins adds them).
   * @param {string} query - Handle. @returns {Promise<object[]>} Matches.
   */
  searchGroups(query) { return this.call("search_groups", { q: query }); }

  // ================================================================== users / profile
  /** Everyone who started a chat with the bot. @returns {Promise<string[]>} Peer ids. */
  async users() {
    return (await this.call("contacts")).filter((c) => c.status === 3).map((c) => c.peer);
  }

  /** Full user entries. @returns {Promise<Contact[]>} Contacts. */
  contacts() { return this.call("contacts"); }

  /**
   * Display name from the cache (no request); falls back to the first 8 characters of the id.
   * @param {string} peer - Peer id. @returns {string} Name.
   */
  cachedName(peer) { return this._names.get(peer) || String(peer || "").slice(0, 8); }

  /**
   * Display name of a user (refreshes the cache when unknown).
   * @param {string} peer - Peer id. @returns {Promise<string>} Name.
   */
  async nameOf(peer) {
    if (this._names.get(peer)) return this._names.get(peer);
    try { await this.#refreshNames(); } catch (e) { if (!(e instanceof LumoraError)) throw e; }
    return this.cachedName(peer);
  }

  async #refreshNames() {
    for (const c of await this.call("contacts")) {
      const n = c.alias || c.name || c.short_id;
      if (n) this._names.set(c.peer, n);
    }
  }

  /**
   * Look up `@name` / `@name·tag`.
   * @param {string} handle - Handle. @returns {Promise<Array<{peer: string, handle: string, name?: string, contact: boolean}>>} Matches.
   */
  resolveUsername(handle) { return this.call("resolve_username", { handle }); }

  /** Block a user: they can no longer message the bot. @param {string} peer - Peer id. @returns {Promise<void>} */
  async blockUser(peer) { await this.call("block_contact", { peer }); }

  /** Unblock a user. @param {string} peer - Peer id. @returns {Promise<void>} */
  async unblockUser(peer) { await this.call("unblock_contact", { peer }); }

  /**
   * Update the bot's profile. `avatar`: path to an image (≤ 96 KB).
   * @param {{name?: string, bio?: string, avatar?: string}} profile - Fields to change.
   * @returns {Promise<object>} The profile.
   */
  setProfile({ name, bio, avatar } = {}) {
    const args = {};
    if (name != null) args.name = name;
    if (bio != null) args.bio = bio;
    if (avatar) args.avatar = readFileSync(avatar).toString("base64");
    return this.call("set_profile", args);
  }

  #menus() {
    const all = [...this.commands];
    return {
      commands: all.filter(([, c]) => !c.hidden && c.chats !== "group").map(([command, c]) => ({ command, description: c.description })),
      group_commands: all.filter(([, c]) => !c.hidden && c.chats !== "private").map(([command, c]) => ({ command, description: c.description })),
    };
  }

  /** Publish the command menu again (done automatically at start). @returns {Promise<void>} */
  async setCommands() {
    await this.call("set_bot", { ...this.#menus(), about: this.about, auto_accept: true, allow_groups: this.allowGroups });
  }

  /**
   * Send `text` to every user (or `users`), paced (≈ 15 messages/s). Failures are logged and skipped.
   * @param {string} text - Text.
   * @param {Buttons|BroadcastOptions} [buttonsOrOptions] - Buttons, or the options object.
   * @param {BroadcastOptions} [options] - `{buttons, silent, users, onProgress(done, total)}`.
   * @returns {Promise<number>} How many users received it.
   */
  async broadcast(text, buttonsOrOptions, options) {
    const o = splitOpts(buttonsOrOptions, options);
    const targets = o.users ? [...o.users] : await this.users();
    let n = 0;
    for (let i = 0; i < targets.length; i++) {
      if (this._stopping) break;
      const p = targets[i];
      try {
        await this.send(convOf(p), text, { buttons: o.buttons, silent: o.silent });
        n++;
      } catch (e) {
        if (!(e instanceof LumoraError)) throw e;
        this.log.warn(`broadcast to ${p.slice(0, 10)}… failed: ${e.message}`, { event: "broadcast_failed", peer: p, ...e.toJSON() });
      }
      if (o.onProgress) await o.onProgress(i + 1, targets.length);
    }
    return n;
  }

  // ================================================================== lifecycle
  /**
   * Start Lumora Bot Runner and go online (resolves once online). See `run`.
   * @returns {Promise<this>} The bot.
   */
  async start() {
    mkdirSync(this.dataDir, { recursive: true });
    mkdirSync(this.downloadsDir, { recursive: true });
    this._stopping = false;
    if (this._stopped) { this._stopped = false; this._stoppedGate = gate(); }
    this._runner.closed = false;
    await this.#spawn();
    this._started = true;
    for (const job of this._jobs) if (!job.timer) this.#arm(job);
    return this;
  }

  async #spawn() {
    const args = ["--data", this.dataDir, "--stdio", "--downloads", resolve(this.downloadsDir), ...this.extraArgs];
    if (!this.token) args.splice(2, 0, "--name", this.name);
    let stderr = "ignore";
    let fd = null;
    if (this.runnerLog) {
      try {
        if (existsSync(this.runnerLog) && statSync(this.runnerLog).size > 10 << 20) renameSync(this.runnerLog, this.runnerLog + ".1");
        fd = openSync(this.runnerLog, "a");
        stderr = fd;
      } catch {
        stderr = "ignore";
      }
    }
    // the token goes through the environment, never on the command line
    const env = this.token ? { ...process.env, LUMORA_BOT_TOKEN: this.token } : process.env;
    const proc = spawn(this.binary, args, { stdio: ["pipe", "pipe", stderr], env });
    if (fd !== null) closeSync(fd);
    this.#clearReady();
    const gen = ++this._gen;
    this.proc = proc;
    const failed = new Promise((_, rej) => proc.once("error", rej));
    failed.catch(() => {});
    proc.stdin.on("error", () => {}); // EPIPE when the runner dies: handled on exit
    createInterface({ input: proc.stdout }).on("line", (line) => this.#onLine(line));
    proc.once("close", (code, sig) => this.#onExit(gen, code ?? sig));
    try {
      await Promise.race([this.#setup(), failed]);
    } catch (e) {
      try { proc.kill(); } catch { /* already gone */ }
      this.#failPending(String(e?.message || e));
      if (e?.code === "ENOENT") {
        throw new RunnerStopped(`Lumora Bot Runner not found: ${this.binary}. Set LUMORAD=/path/to/lumorad.`, "sdk.runner_missing", this.binary);
      }
      if (e instanceof RunnerStopped || e instanceof LumoraTimeout) {
        const hint = this.runnerLog ? ` See ${this.runnerLog}.` : "";
        throw new RunnerStopped("Lumora Bot Runner could not start." + hint, "sdk.runner_failed", e.detail || e.message);
      }
      throw e;
    }
    this.#setReady();
    for (const fn of this._startHooks) {
      this._runner.submit("start", () => this.#callHandler(() => fn(), new Context(this, { event: "start" }, "start")));
    }
  }

  async #setup() {
    this.me = await this.#call("me", {}, 30000, false);
    if (this.lang) await this.#call("set_lang", { lang: this.lang }, 10000, false);
    this.adminPeers.clear();
    for (const a of this.adminSpecs) {
      if (a.startsWith("@")) {
        try {
          const found = await this.#call("resolve_username", { handle: a }, 30000, false);
          if (found.length === 1) this.adminPeers.add(found[0].peer);
          else this.log.warn(`admin ${a}: ${found.length} matches, use the full @name·tag`, { event: "admin_unresolved" });
        } catch (e) {
          if (!(e instanceof LumoraError)) throw e;
          this.log.warn(`admin ${a}: ${e.message}`, { event: "admin_unresolved", ...e.toJSON() });
        }
      } else this.adminPeers.add(a);
    }
    // admin-only commands are hidden from the public command menu
    await this.#call("set_bot", { ...this.#menus(), about: this.about, auto_accept: true, allow_groups: this.allowGroups }, 30000, false);
    try {
      for (const g of (await this.#call("groups", {}, 30000, false)) || []) this.#trackGroup(g);
      for (const c of (await this.#call("contacts", {}, 30000, false)) || []) {
        const n = c.alias || c.name || c.short_id;
        if (n) this._names.set(c.peer, n);
      }
    } catch (e) {
      if (!(e instanceof LumoraError)) throw e;
    }
  }

  /**
   * Start and wait until stopped (Ctrl+C, SIGTERM or `stop()`). Shuts down gracefully:
   * running handlers finish, then Lumora Bot Runner exits.
   * @returns {Promise<void>} Resolves after shutdown.
   */
  async run() {
    await this.start();
    const label = this.me.handle || this.me.name || this.name;
    console.log(`🤖 ${label} is online — ID ${this.me.short_id} (${this.me.peer})`);
    this.log.info(`online as ${label}`, { event: "online", peer: this.me.peer, version: this.me.version });
    const onSignal = () => { this._stopped = true; this._stoppedGate.open(); };
    const sigs = ["SIGTERM", "SIGINT", ...(process.platform === "win32" ? [] : ["SIGHUP"])];
    for (const s of sigs) process.on(s, onSignal);
    try {
      await this._stoppedGate.p;
    } finally {
      for (const s of sigs) process.off(s, onSignal);
      await this.stop();
    }
  }

  /**
   * Stop gracefully: no new events, wait up to `timeoutMs` for running handlers, then close
   * Lumora Bot Runner (it saves everything and exits).
   * @param {number} [timeoutMs=10000] - How long to wait for running handlers.
   * @returns {Promise<void>}
   */
  async stop(timeoutMs = 10000) {
    if (this._stopping && this.proc === null) return;
    this._stopping = true;
    for (const job of this._jobs) { clearTimeout(job.timer); job.timer = null; }
    if (!(await this._runner.close(timeoutMs))) {
      this.log.warn(`some handlers were still running after ${timeoutMs / 1000} s`, { event: "shutdown_timeout" });
    }
    const proc = this.proc;
    this.proc = null;
    this.#clearReady();
    if (proc && proc.exitCode === null && proc.signalCode === null) {
      const exited = new Promise((r) => proc.once("exit", r));
      try { proc.stdin.end(); } catch { /* closed */ }
      let t;
      const ok = await Promise.race([exited.then(() => true), new Promise((r) => { t = setTimeout(() => r(false), 5000); })]);
      clearTimeout(t);
      if (!ok) proc.kill("SIGKILL");
    }
    this.#failPending("stopped");
    try { this.storage.save(); } catch { /* read-only */ }
    this._stopped = true;
    this._stoppedGate.open();
    this.log.info("stopped", { event: "stopped" });
  }

  // ================================================================== reader / restart
  #onLine(line) {
    let v;
    try { v = JSON.parse(line); } catch { return; }
    if (v && typeof v === "object" && "event" in v) this.#onEvent(v);
    else if (v && v.id != null && this._pending.has(v.id)) {
      const p = this._pending.get(v.id);
      this._pending.delete(v.id);
      p.done(v);
    }
  }

  #onExit(gen, code) {
    if (gen !== this._gen) return;
    this.#clearReady();
    this.#failPending(`exit code ${code}`);
    if (this._stopping || !this._started) return;
    this.log.error(`Lumora Bot Runner exited (code ${code})`, { event: "runner_exit", exit_code: code });
    if (!this.autoRestart) {
      this._stopped = true;
      this._stoppedGate.open();
      return;
    }
    this.#restartLoop();
  }

  async #restartLoop() {
    let delay = 1000;
    while (!this._stopping) {
      const now = Date.now();
      this._restarts = [...this._restarts.filter((t) => now - t < 600000), now];
      if (this._restarts.length > 20) {
        this.log.error("Lumora Bot Runner keeps crashing; giving up", { event: "restart_giveup" });
        this._stopped = true;
        this._stoppedGate.open();
        return;
      }
      await Promise.race([sleep(delay), this._stoppedGate.p]);
      if (this._stopping || this._stopped) return;
      try {
        await this.#spawn();
        this.log.info("Lumora Bot Runner restarted", { event: "runner_restarted" });
        return;
      } catch (e) {
        this.log.error(`restart failed: ${e.message}`, { event: "restart_failed", ...errFields(e) });
        delay = Math.min(delay * 2, 30000);
      }
    }
  }

  // ================================================================== dispatch
  #onEvent(ev) {
    const kind = ev.event;
    // cheap state kept in arrival order
    if (kind === "file" && this._fileWaiters.has(ev.id)) this._fileWaiters.get(ev.id).wake?.();
    if (kind === "contact" && ev.peer) {
      const n = ev.alias || ev.name;
      if (n) this._names.set(ev.peer, n);
    }
    if (this._stopping) return;
    const key = ev.conv || ev.msg_conv || ev.gid || ev.peer || null;
    this._runner.submit(key, () => this.#dispatch(ev));
  }

  async #dispatch(ev) {
    const kind = ev.event || "";
    for (const name of [kind, "*"]) {
      for (const fn of this._raw.get(name) || []) await this.#callHandler(fn, new Context(this, ev, kind));
    }
    try {
      if (kind === "message") await this.#dispatchMessage(ev);
      else if (kind === "callback") await this.#dispatchCallback(ev);
      else if (kind === "bot_user") {
        if (ev.name && !this._names.get(ev.peer)) this._names.set(ev.peer, ev.name);
        const ctx = new Context(this, { event: "bot_user", conv: "d:" + ev.peer, from: ev.peer }, "new_user");
        await this.#runRoutes("new_user", ctx);
      } else if (kind === "group") await this.#dispatchGroup(ev);
      else if (kind === "reminder_due") {
        const ctx = new Context(this, { event: kind, conv: ev.conv, msg_id: ev.msg_id, author: ev.author }, "reminder_due");
        ctx.reminder = Object.fromEntries(["title", "note", "at_ms", "author", "mine", "late", "conv", "msg_id"].map((k) => [k, ev[k] ?? null]));
        ctx.text = ev.title || "";
        await this.#runRoutes("reminder_due", ctx);
      } else if (kind === "message_update") await this.#dispatchUpdate(ev);
    } catch (e) {
      this.log.error(`dispatch error: ${e}`, { event: "dispatch_error", ...errFields(e) });
    }
  }

  async #run(ctx, final) {
    const chain = [...this._middleware];
    const step = (i) => (i < chain.length
      ? this.#callHandler((c) => chain[i](c, () => step(i + 1)), ctx)
      : this.#callHandler(final, ctx));
    await step(0);
  }

  async #callHandler(fn, ctx) {
    try {
      return await fn(ctx);
    } catch (e) {
      this.log.error(`handler error in ${fn.name || "handler"}: ${e instanceof LumoraError ? e.message : e}`, {
        event: "handler_error", kind: ctx.kind, conv: ctx.conv, ...errFields(e),
      });
      for (const h of this._errorHandlers) {
        try { await h(ctx, e); } catch (e2) { this.log.error(`onError handler failed: ${e2}`, { event: "on_error_failed" }); }
      }
      return undefined;
    }
  }

  async #runRoutes(name, ctx, select = null) {
    const routes = this._routes.get(name) || [];
    if (!routes.length) return false;
    const final = async (c) => {
      for (const r of routes.filter((x) => x.specific)) {
        const m = select ? select(r) : true;
        if (m) {
          if (m !== true && Array.isArray(m)) c.match = m;
          c.handled = true;
          return this.#callHandler(r.fn, c);
        }
      }
      for (const r of routes) {
        if (!r.specific && (select === null || (select(r) ?? null) !== null)) {
          c.handled = true;
          await this.#callHandler(r.fn, c);
        }
      }
      return undefined;
    };
    await this.#run(ctx, final);
    return true;
  }

  #addressedElsewhere(ctx) {
    const t = ctx._commandTarget;
    if (!t) return false;
    const uname = String(this.me?.username || "").toLowerCase();
    const name = String(this.me?.name || this.name || "").toLowerCase().replace(/ /g, "");
    return !(t === uname || t === name || (uname && t.startsWith(uname)));
  }

  async #dispatchMessage(ev) {
    if (ev.mine) {
      if (ev.kind === "checklist") this.#rememberChecklist(ev);
      return;
    }
    const mk = ev.kind || "";
    if (mk === "system") return;
    const ctx = new Context(this, ev, "message");
    if (ev.author && !this._names.get(ev.author)) {
      try { await this.nameOf(ev.author); } catch { /* best effort */ }
    }
    if (mk === "checklist") this.#rememberChecklist(ev);
    if (mk === "text" && ctx.command !== null) {
      if (this.#addressedElsewhere(ctx)) return;
      const entry = this.commands.get(ctx.command);
      if (entry) {
        if (!chatOk(entry.chats, ctx)) return;
        ctx.kind = "command";
        await this.#run(ctx, (c) => entry.fn(c));
        return;
      }
      if (ctx.command === "help" && this.helpCommand) {
        ctx.kind = "command";
        const lines = [...this.commands]
          .filter(([, c]) => (!c.hidden || ctx.isAdmin) && chatOk(c.chats, ctx))
          .map(([c, { description }]) => `/${c} — ${description}`);
        await this.#run(ctx, (c) => c.reply(lines.join("\n") || "No commands"));
        return;
      }
    }
    if (mk === "file" || mk === "voice") {
      ctx.file = { ...ctx.body, state: ev.file?.state ?? null, path: ev.file?.path || null };
      if (!("preview" in ctx.file)) ctx.file.preview = null;
      if (mk === "file" && this._routes.get("file")?.length) {
        const ext = extname(ctx.file.name || "").toLowerCase().replace(/^\./, "");
        const fctx = new Context(this, ev, "file");
        fctx.file = ctx.file;
        await this.#runRoutes("file", fctx, (r) => ((r.exts === null || r.exts.includes(ext)) && chatOk(r.chats, fctx) ? true : null));
        if (fctx.handled) return;
      }
    }
    const sel = (r) => {
      if (r.kinds !== null && !r.kinds.includes(mk)) return null;
      if (!chatOk(r.chats, ctx)) return null;
      if (r.pattern !== null) return mk === "text" ? r.pattern.exec(ctx.text) : null;
      return true;
    };
    await this.#runRoutes("message", ctx, sel);
  }

  async #dispatchCallback(ev) {
    const ctx = new Context(this, ev, "callback");
    if (ev.from && !this._names.get(ev.from)) {
      try { await this.nameOf(ev.from); } catch { /* best effort */ }
    }
    const sel = (r) => {
      if (r.data !== null) {
        if (r.data.endsWith("*")) return ctx.data.startsWith(r.data.slice(0, -1)) ? true : null;
        return ctx.data === r.data ? true : null;
      }
      if (r.pattern !== null) return r.pattern.exec(ctx.data);
      return true;
    };
    await this.#runRoutes("callback", ctx, sel);
  }

  #trackGroup(g) {
    const gid = String(g.gid || "");
    const now = new Map((g.members || []).map((m) => [m.peer, { ...m }]));
    if (g.owner && now.has(g.owner)) now.set(g.owner, { ...now.get(g.owner), role: "owner" });
    for (const [p, m] of now) if (m.name) this._names.set(p, m.name);
    const old = this._groups.get(gid) ?? null;
    this._groups.set(gid, now);
    return [old, now];
  }

  async #dispatchGroup(ev) {
    const me = this.me?.peer;
    const [old, now] = this.#trackGroup(ev);
    const conv = ev.conv || "g:" + (ev.gid || "");
    if (old === null) {
      if (now.has(me)) {
        const ctx = new Context(this, { event: "group", conv, from: ev.owner }, "added_to_group");
        ctx.member = now.get(me);
        await this.#runRoutes("added_to_group", ctx);
      }
      return;
    }
    for (const [p, m] of now) {
      if (p === me || old.has(p)) continue;
      const ctx = new Context(this, { event: "group", conv, from: p }, "new_member");
      ctx.member = m;
      await this.#runRoutes("new_member", ctx);
    }
    for (const [p, m] of old) {
      if (p === me || now.has(p)) continue;
      const ctx = new Context(this, { event: "group", conv, from: p }, "member_left");
      ctx.member = m;
      await this.#runRoutes("member_left", ctx);
    }
  }

  // ---- checklists
  #rememberChecklist(m) {
    const mid = m?.id;
    if (!mid || (m.kind && m.kind !== "checklist")) return;
    const body = m.body || {};
    const st = this._checklists.get(mid) || { msg_id: mid, conv: m.conv, title: "", items: [], checks: {} };
    st.title = body.title ?? st.title;
    st.items = body.items ?? st.items;
    if (m.reactions && typeof m.reactions === "object" && m.reactions.__checks && typeof m.reactions.__checks === "object") {
      st.checks = { ...m.reactions.__checks };
    }
    this._checklists.delete(mid);
    this._checklists.set(mid, st);
    while (this._checklists.size > 2000) this._checklists.delete(this._checklists.keys().next().value);
  }

  async #loadChecklist(conv, msgId) {
    try {
      for (const m of await this.messages(conv, { limit: 500 })) {
        if (m.id === msgId && m.kind === "checklist") {
          this.#rememberChecklist(m);
          return this._checklists.get(msgId) || null;
        }
      }
    } catch (e) {
      if (!(e instanceof LumoraError)) throw e;
    }
    return null;
  }

  static #checklistView(st) {
    const items = (st.items || []).map((it) => {
      const c = (st.checks || {})[String(it.id)] || {};
      return { id: it.id, text: it.text, done: !!c.done, by: c.by ?? null, at: c.at ?? null };
    });
    return { msg_id: st.msg_id, conv: st.conv, title: st.title, items, done: items.filter((i) => i.done).length, total: items.length };
  }

  async #dispatchUpdate(ev) {
    const mid = String(ev.id || "");
    const conv = String(ev.conv || "");
    const reactions = ev.reactions && typeof ev.reactions === "object" ? ev.reactions : {};
    const body = ev.body && typeof ev.body === "object" ? ev.body : {};
    const isChecks = reactions.__checks && typeof reactions.__checks === "object";
    const isItems = Array.isArray(body.items) && "title" in body;
    if (!mid || !(isChecks || isItems)) return;
    const st = this._checklists.get(mid) || (await this.#loadChecklist(conv, mid));
    if (!st) return;
    const me = this.me?.peer;
    const changes = [];
    if (isChecks) {
      const texts = Object.fromEntries((st.items || []).map((i) => [String(i.id), i.text]));
      for (const [k, v] of Object.entries(reactions.__checks)) {
        const old = st.checks[k];
        if (JSON.stringify(old) !== JSON.stringify(v) && v?.by !== me) {
          changes.push({ item: Number(k), text: texts[k] ?? null, done: !!v?.done, by: v?.by ?? null });
        }
      }
      st.checks = { ...reactions.__checks };
    }
    if (isItems) {
      const oldIds = new Set((st.items || []).map((i) => i.id));
      st.items = body.items;
      st.title = body.title ?? st.title;
      for (const it of body.items) if (!oldIds.has(it.id)) changes.push({ item: it.id, text: it.text, added: true, by: null });
    }
    if (!changes.length) return;
    const by = [...changes].reverse().find((c) => c.by)?.by || "";
    const ctx = new Context(this, { event: "message_update", conv, msg_id: mid, from: by }, "checklist");
    ctx.checklist = Bot.#checklistView(st);
    ctx.changes = changes;
    ctx.text = st.title || "";
    await this.#runRoutes("checklist", ctx);
  }
}
