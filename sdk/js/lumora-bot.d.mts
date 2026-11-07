// Type declarations for lumora-bot 1.1.0 (Lumora Bot SDK for JavaScript).
// License: MIT.

/// <reference types="node" />

export declare const VERSION: string;
export declare const MAX_TEXT_BYTES: number;
export declare const MAX_BUTTON_ROWS: number;
export declare const MAX_BUTTONS_PER_ROW: number;
export declare const MAX_BUTTON_TEXT: number;
export declare const MAX_BUTTON_DATA: number;
export declare const MAX_PREVIEW_TEXT_BYTES: number;
export declare const MAX_PREVIEW_IMAGE_BYTES: number;
export declare const MAX_CHECKLIST_ITEMS: number;
export declare const MAX_TASK_TEXT: number;
export declare const MAX_REMINDER_NOTE: number;

// ----------------------------------------------------------------------------- data shapes

/** An inline button. Pressing a `data` button sends a callback; a `url` button opens the link. */
export interface ButtonSpec {
  text: string;
  data?: string;
  url?: string;
}
/** `["Text", "data"]` or `["Text", "https://link"]`. */
export type ButtonTuple = [string, string];
export type AnyButton = ButtonSpec | ButtonTuple;
/** Rows of buttons (max 8×8), or one flat row. */
export type Buttons = AnyButton[][] | AnyButton[] | null | undefined;
/** `"all"` (default), `"private"` (direct chats) or `"group"`. */
export type Chats = "all" | "private" | "group";
/** A point in time: `Date`, epoch milliseconds, or `{ inMs }` from now. */
export type When = Date | number | { inMs: number };

export interface FilePreview {
  kind: string;
  text?: string;
  pages?: number;
  lines?: number;
}

/** A chat message. */
export interface Message {
  id: string;
  conv: string;
  author: string;
  hlc: number;
  ts: number;
  kind: "text" | "file" | "sticker" | "voice" | "location" | "contact" | "call" | "system" | "poll" | "checklist" | "reminder" | string;
  body: Record<string, any>;
  status: number;
  edited: boolean;
  deleted: boolean;
  reply_to: string | null;
  reactions: Record<string, any>;
  expires: number | null;
  pinned?: boolean;
  silent?: boolean;
  meta?: { mentions?: string[]; mention_all?: boolean; forwarded_from?: string | null; buttons?: ButtonSpec[][]; silent?: boolean };
  mine: boolean;
  file?: { state: number; progress: number; size: number; path: string; direction: number };
  [key: string]: any;
}

/** A file transfer. `state`: 0 offered, 1 transferring, 2 done, 3 failed, 4 cancelled, 5 paused. */
export interface FileEntry {
  id: string;
  conv: string;
  peer: string;
  name: string;
  size: number;
  hash: string;
  path: string;
  direction: 0 | 1;
  state: number;
  progress: number;
  created: number;
  speed_bps?: number;
  preview?: FilePreview;
  [key: string]: any;
}

/** `ctx.file` in `onFile` handlers. */
export interface FileInfo {
  file_id: string;
  name: string;
  size: number;
  mime: string;
  preview: FilePreview | null;
  state: number | null;
  path: string | null;
  [key: string]: any;
}

/** A user of the bot. `status`: 0 none, 1 sent, 2 received, 3 friend, 4 blocked. */
export interface Contact {
  peer: string;
  short_id: string;
  name: string;
  alias?: string | null;
  username?: string | null;
  handle?: string | null;
  status: number;
  online: boolean;
  [key: string]: any;
}

export interface GroupMember {
  peer: string;
  name: string;
  role: "owner" | "admin" | "member" | string;
  online?: boolean;
}

export interface GroupInfo {
  gid: string;
  conv: string;
  name: string;
  kind: number;
  owner: string;
  members: GroupMember[];
  my_role: "owner" | "admin" | "member" | "none" | string;
  description: string;
  slow_mode_s: number;
  admins_only: boolean;
  banned: string[];
  public: boolean;
  handle: string | null;
  bots: Array<{ peer: string; read_all: boolean }>;
  channels: Array<{ name: string; voice: boolean; conv: string }>;
  [key: string]: any;
}

export interface ChecklistItem {
  id: number;
  text: string;
  done: boolean;
  by: string | null;
  at: number | null;
}

export interface Checklist {
  msg_id: string;
  conv: string;
  title: string;
  items: ChecklistItem[];
  done: number;
  total: number;
}

export interface ChecklistChange {
  item: number;
  text: string | null;
  done?: boolean;
  added?: boolean;
  by: string | null;
}

export interface Reminder {
  conv: string;
  msg_id: string;
  at_ms: number;
  title: string;
  note: string;
  author: string;
}

export interface DueReminder extends Reminder {
  mine: boolean;
  late: boolean;
}

export interface Me {
  peer: string;
  short_id: string;
  name: string;
  username: string | null;
  handle: string | null;
  version: string;
  [key: string]: any;
}

export interface Job {
  name: string;
  fn: () => any;
  next: number;
  cancelled: boolean;
}

// ----------------------------------------------------------------------------- options

export interface BotOptions {
  /** Display name for a bot made without Bot Studio (testing). Not needed with a token. */
  name?: string;
  /** Bot Studio token (default: `$LUMORA_BOT_TOKEN`). */
  token?: string;
  /** Identity, messages, storage and downloads (default `./lumora-bot`). */
  dataDir?: string;
  /** Path to `lumorad` (default `$LUMORAD`, then `lumorad`). */
  binary?: string;
  about?: string;
  lan?: boolean;
  publicDirectory?: boolean;
  extraArgs?: string[];
  /** Bot admins: peer ids or `@name·tag` handles. */
  admins?: string[];
  /** Overall send rate (default 15/s; per chat: burst 5, then 1/s). */
  ratePerSec?: number;
  /** Accepted for parity with the Python SDK; ignored. */
  workers?: number;
  /** Where received files are saved (default `<dataDir>/downloads`). */
  downloadsDir?: string;
  autoRestart?: boolean;
  allowGroups?: boolean;
  /** `"vi"` or `"en"`: language of error messages. */
  lang?: "vi" | "en" | null;
  logJson?: boolean;
  logLevel?: "debug" | "info" | "warning" | "warn" | "error" | string;
  /** Runner log file (default `<dataDir>/runner.log`; `""` discards). */
  runnerLog?: string;
  helpCommand?: boolean;
  denyText?: string;
}

export interface SendOptions {
  buttons?: Buttons;
  replyTo?: string;
  silent?: boolean;
  mentions?: string[];
  mentionAll?: boolean;
  ttlMs?: number;
}

export interface ReplyOptions extends SendOptions {
  /** Quote the message being answered. */
  reply?: boolean;
}

export interface FileOptions {
  /** Text snippet or `{kind, text, pages, lines}` shown before download (text ≤ 4 KB). */
  preview?: string | FilePreview;
  /** Path to a JPEG/PNG/WebP ≤ 64 KB shown with the file. */
  thumb?: string;
}

export interface BroadcastOptions {
  buttons?: Buttons;
  silent?: boolean;
  users?: Iterable<string>;
  onProgress?: (done: number, total: number) => any;
}

export interface CommandOptions {
  adminOnly?: boolean;
  role?: string | null;
  chats?: Chats;
  hidden?: boolean;
}

export interface MessageFilter {
  pattern?: RegExp | string;
  /** Default `["text"]`; `null` = all kinds. */
  kinds?: string[] | null;
  chats?: Chats;
}

export interface CallbackFilter {
  /** Exact data; ending in `*` = prefix. */
  data?: string;
  pattern?: RegExp | string;
}

export interface FileFilter {
  extensions?: string[];
  chats?: Chats;
}

export type Handler = (ctx: Context) => any;
export type Middleware = (ctx: Context, next: () => Promise<any>) => any;

// ----------------------------------------------------------------------------- errors

export declare class LumoraError extends Error {
  constructor(message: string, code?: string, detail?: string | null, cmd?: string | null);
  /** Plain sentence, safe to show to users. */
  message: string;
  /** Stable key: `err.*`, `internal` or `sdk.*`. */
  code: string;
  /** Technical cause (log it, don't show it). */
  detail: string | null;
  /** The command that failed. */
  cmd: string | null;
  toJSON(): { error: string; code: string; detail: string | null; cmd: string | null };
}
export declare class LumoraTimeout extends LumoraError {}
export declare class RunnerStopped extends LumoraError {}
export declare class NotAllowedForBots extends LumoraError {}

// ----------------------------------------------------------------------------- helpers

export declare function isBlockedCommand(cmd: string): boolean;
export declare function gidOf(convOrGid: string): string;
export declare function convOf(peerOrGid: string): string;
export declare function isGroupConv(conv: string): boolean;
export declare function Button(text: string, dataOrOptions?: string | { data?: string; url?: string }, url?: string): { text: string; data: string; url: string };

export declare class Storage {
  constructor(path: string);
  readonly path: string;
  data: Record<string, any>;
  get<T = any>(key: string, def?: T): T;
  has(key: string): boolean;
  keys(): string[];
  set(key: string, value: any): void;
  delete(key: string): void;
  updateKey<T = any>(key: string, fn: (old: T) => T, def?: T): T;
  save(): void;
  toJSON(): Record<string, any>;
}

export declare class Roles {
  constructor(storage: Storage);
  grant(peer: string, role: string): void;
  revoke(peer: string, role: string): void;
  of(peer: string): Set<string>;
  members(role: string): string[];
}

export interface Logger {
  debug(msg: string, fields?: Record<string, any>): void;
  info(msg: string, fields?: Record<string, any>): void;
  warn(msg: string, fields?: Record<string, any>): void;
  error(msg: string, fields?: Record<string, any>): void;
}

// ----------------------------------------------------------------------------- context

export declare class Context {
  constructor(bot: Bot, ev: Record<string, any>, kind?: string);
  bot: Bot;
  event: Record<string, any>;
  kind: string;
  conv: string;
  sender: string;
  body: Record<string, any>;
  msgKind: string;
  text: string;
  data: string;
  msgId: string;
  replyTo: string | null;
  silent: boolean;
  match: RegExpExecArray | null;
  file: FileInfo | null;
  reminder: DueReminder | null;
  checklist: Checklist | null;
  changes: ChecklistChange[];
  member: GroupMember | null;
  command: string | null;
  args: string;
  handled: boolean;
  readonly isGroup: boolean;
  readonly gid: string | null;
  /** Cached display name of the sender. */
  readonly senderName: string;
  readonly isAdmin: boolean;
  hasRole(role: string): boolean;
  isGroupAdmin(): Promise<boolean>;
  reply(text: string, buttonsOrOptions?: Buttons | ReplyOptions, options?: ReplyOptions): Promise<Message>;
  replyFile(path: string, options?: FileOptions): Promise<FileEntry>;
  sendFile(path: string): Promise<FileEntry>;
  replyChecklist(title: string, items: string[], options?: { silent?: boolean }): Promise<Message>;
  replyReminder(title: string, at: When, options?: { note?: string; silent?: boolean }): Promise<Message>;
  replyPoll(question: string, options: string[]): Promise<Message>;
  react(emoji: string, on?: boolean): Promise<void>;
  edit(text: string): Promise<void>;
  delete(forEveryone?: boolean): Promise<void>;
  pin(on?: boolean): Promise<void>;
  typing(on?: boolean): Promise<void>;
  download(options?: { dir?: string; timeoutMs?: number }): Promise<string>;
}

// ----------------------------------------------------------------------------- bot

export declare class Bot {
  constructor(options?: BotOptions);
  log: Logger;
  token: string | undefined;
  name: string;
  dataDir: string;
  about: string;
  binary: string;
  downloadsDir: string;
  storage: Storage;
  roles: Roles;
  adminPeers: Set<string>;
  commands: Map<string, { fn: Handler; description: string; hidden: boolean; chats: Chats }>;
  me: Me | null;

  // handlers
  command(name: string, description: string, fn: Handler, options?: CommandOptions): this;
  command(name: string, fn: Handler): this;
  onMessage(fn: Handler, filter?: MessageFilter): this;
  onMessage(filter: MessageFilter, fn: Handler): this;
  onText(pattern: RegExp | string, fn: Handler, options?: { chats?: Chats }): this;
  onCallback(fn: Handler, filter?: CallbackFilter): this;
  onCallback(filter: CallbackFilter, fn: Handler): this;
  onNewUser(fn: Handler): this;
  onNewMember(fn: Handler): this;
  onMemberLeft(fn: Handler): this;
  onAddedToGroup(fn: Handler): this;
  onFile(fn: Handler, filter?: FileFilter): this;
  onFile(filter: FileFilter, fn: Handler): this;
  onReminderDue(fn: Handler): this;
  onChecklist(fn: Handler): this;
  onEvent(name: string, fn: Handler): this;
  use(fn: Middleware): this;
  middleware(fn: Middleware): this;
  onError(fn: (ctx: Context, err: unknown) => any): this;
  onStart(fn: () => any): this;

  // jobs
  every(seconds: number, fn: () => any, options?: { firstIn?: number }): Job;
  daily(at: string, fn: () => any): Job;
  after(seconds: number, fn: () => any): Job;
  cancel(job: Job): void;

  // low level
  call<T = any>(cmd: string, args?: Record<string, any>, timeoutMs?: number): Promise<T>;

  // messages
  send(conv: string, text: string, buttonsOrOptions?: Buttons | SendOptions, options?: SendOptions): Promise<Message>;
  sendFile(conv: string, path: string, options?: FileOptions): Promise<FileEntry>;
  sendPoll(conv: string, question: string, options: string[]): Promise<Message>;
  sendChecklist(conv: string, title: string, items: string[], options?: { silent?: boolean }): Promise<Message>;
  checklistToggle(conv: string, msgId: string, item: number, done?: boolean): Promise<void>;
  checklistAdd(conv: string, msgId: string, items: string[]): Promise<void>;
  checklist(conv: string, msgId: string): Promise<Checklist | null>;
  sendReminder(conv: string, title: string, at: When, options?: { note?: string; silent?: boolean }): Promise<Message>;
  reminderCancel(conv: string, msgId: string): Promise<void>;
  reminders(): Promise<Reminder[]>;
  sendSticker(conv: string, pack?: string, sticker?: string, options?: { hash?: string }): Promise<Message>;
  sendLocation(conv: string, lat: number, lon: number, label?: string, options?: { accuracyM?: number; liveMinutes?: number }): Promise<Message>;
  updateLiveLocation(conv: string, msgId: string, lat: number, lon: number, options?: { accuracyM?: number; stop?: boolean }): Promise<void>;
  sendContact(conv: string, peer: string): Promise<Message>;
  sendVoice(conv: string, path: string, durationMs: number, wave?: number[]): Promise<Message>;
  editMessage(conv: string, msgId: string, text: string): Promise<void>;
  deleteMessage(conv: string, msgId: string, forEveryone?: boolean): Promise<void>;
  pinMessage(conv: string, msgId: string, on?: boolean): Promise<void>;
  pinnedMessages(conv: string): Promise<Message[]>;
  react(conv: string, msgId: string, emoji: string, on?: boolean): Promise<void>;
  forwardMessage(msgId: string, toConv: string): Promise<Message>;
  messages(conv: string, options?: { limit?: number; before?: number }): Promise<Message[]>;
  typing(conv: string, on?: boolean): Promise<void>;
  markRead(conv: string): Promise<void>;
  scheduleMessage(conv: string, text: string, at: When): Promise<{ id: string; conv: string; text: string; at: number }>;
  scheduledMessages(): Promise<Array<{ id: string; conv: string; text: string; at: number }>>;
  cancelScheduled(schedId: string): Promise<void>;

  // files
  files(): Promise<FileEntry[]>;
  acceptFile(fileId: string, dir?: string): Promise<void>;
  cancelFile(fileId: string): Promise<void>;
  downloadFile(fileId: string, options?: { dir?: string; timeoutMs?: number }): Promise<string>;

  // groups
  groups(): Promise<GroupInfo[]>;
  groupInfo(group: string): Promise<GroupInfo>;
  groupAccess(group: string): Promise<{ readAll: boolean; admin: boolean }>;
  memberRole(group: string, peer: string): Promise<"owner" | "admin" | "member" | null>;
  groupBan(group: string, peer: string, ban?: boolean): Promise<void>;
  groupUnban(group: string, peer: string): Promise<void>;
  groupRemove(group: string, peer: string): Promise<void>;
  groupSettings(group: string, settings: { slowModeS?: number; adminsOnly?: boolean }): Promise<void>;
  setSlowMode(group: string, seconds: number): Promise<void>;
  groupPurgeMember(group: string, peer: string): Promise<void>;
  groupLeave(group: string): Promise<void>;
  searchGroups(query: string): Promise<Array<Record<string, any>>>;

  // users / profile
  users(): Promise<string[]>;
  contacts(): Promise<Contact[]>;
  cachedName(peer: string): string;
  nameOf(peer: string): Promise<string>;
  resolveUsername(handle: string): Promise<Array<{ peer: string; handle: string; name?: string; contact: boolean }>>;
  blockUser(peer: string): Promise<void>;
  unblockUser(peer: string): Promise<void>;
  setProfile(profile: { name?: string; bio?: string; avatar?: string }): Promise<Record<string, any>>;
  setCommands(): Promise<void>;
  broadcast(text: string, buttonsOrOptions?: Buttons | BroadcastOptions, options?: BroadcastOptions): Promise<number>;

  // lifecycle
  start(): Promise<this>;
  run(): Promise<void>;
  stop(timeoutMs?: number): Promise<void>;
}
