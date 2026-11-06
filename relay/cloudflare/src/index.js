// Lumora relay on Cloudflare Workers + Durable Objects (WebSocket Hibernation API).
//
// Same wire protocol as the Rust relay (core/crates/lumora-core/src/net/relay_proto.rs):
// every frame is one binary WebSocket message `[type u8][...]`.
//   1 HELLO   c→s  pubkey[32] ts_ms u64be sig[64]   (Ed25519 over "lumora-relay-hello-v1"||pk||ts)
//   2 WELCOME s→c  observed address (utf8)
//   3 DATA    ↔    peer[32] payload  (QUIC datagram, end-to-end encrypted)
//   4 SIGNAL  ↔    peer[32] payload  (sealed envelope, end-to-end encrypted)
//   5 GONE    s→c  peer[32]
//   6 ERROR   s→c  utf8 message
//
// Design: one "hub" Durable Object per HUB name holds every socket. Peers must use
// the same hub to reach each other. Sockets are accepted untagged (the key is only
// known after HELLO); the key is stored with serializeAttachment() and an in-memory
// index pk → socket is rebuilt from getWebSockets() whenever the object wakes up.
// Offline SIGNALs go to a mailbox table in the object's SQLite storage.

import { DurableObject } from "cloudflare:workers";

const T_HELLO = 1, T_WELCOME = 2, T_DATA = 3, T_SIGNAL = 4, T_GONE = 5, T_ERROR = 6;
const HELLO_CONTEXT = new TextEncoder().encode("lumora-relay-hello-v1");
const HELLO_LEN = 1 + 32 + 8 + 64;
const HELLO_MAX_SKEW_MS = 5 * 60 * 1000;
const REPLAY_KEEP_MS = 11 * 60 * 1000;
const HELLO_TIMEOUT_MS = 10_000;
const SWEEP_MS = 30_000;
const DAY_MS = 86_400_000;

const enc = new TextEncoder();

function num(v, d) {
  const n = Number(v);
  return v === undefined || v === "" || !Number.isFinite(n) ? d : n;
}
function bool(v, d) {
  if (v === undefined || v === "") return d;
  return ["1", "true", "yes", "on"].includes(String(v).toLowerCase());
}

function settings(env) {
  return {
    hub: env.HUB || "global",
    maxClients: num(env.MAX_CLIENTS, 5000),
    maxFrame: num(env.MAX_FRAME, 64 * 1024),
    signalRate: num(env.SIGNAL_RATE, 20),
    dataRate: num(env.DATA_RATE, 2 * 1024 * 1024),
    dataBurst: num(env.DATA_BURST, 4 * 1024 * 1024),
    dataBudget: num(env.DATA_BUDGET_BYTES, 200 * 1024 * 1024),
    mailbox: bool(env.MAILBOX, true),
    mbMaxItems: num(env.MAILBOX_MAX_ITEMS, 200),
    mbMaxItem: num(env.MAILBOX_MAX_ITEM, 64 * 1024),
    mbTtlMs: num(env.MAILBOX_TTL_SECS, 7 * 86400) * 1000,
    mbTotal: num(env.MAILBOX_TOTAL_BYTES, 64 * 1024 * 1024),
    allow: parseAllow(env.ALLOW || ""),
  };
}

// ---- encoding helpers -------------------------------------------------------

const HEX = Array.from({ length: 256 }, (_, i) => i.toString(16).padStart(2, "0"));
function toHex(u8) {
  let s = "";
  for (let i = 0; i < u8.length; i++) s += HEX[u8[i]];
  return s;
}
function fromHex(s) {
  if (!/^[0-9a-fA-F]*$/.test(s) || s.length % 2) return null;
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.substr(i * 2, 2), 16);
  return out;
}
function fromBase32(s) {
  const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = 0, val = 0;
  const out = [];
  for (const c of s.toUpperCase()) {
    const i = A.indexOf(c);
    if (i < 0) return null;
    val = (val << 5) | i;
    bits += 5;
    if (bits >= 8) {
      out.push((val >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return new Uint8Array(out);
}
/** ALLOW = comma/space/newline separated keys (64-char hex or Lumora base32 peer ids). */
function parseAllow(text) {
  const keys = text.split(/[\s,]+/).filter(Boolean);
  if (!keys.length) return null;
  const set = new Set();
  for (const k of keys) {
    const b = k.length === 64 ? fromHex(k) : fromBase32(k);
    if (b && b.length === 32) set.add(toHex(b));
  }
  return set;
}

function frame(type, ...parts) {
  let len = 1;
  for (const p of parts) len += p.length;
  const out = new Uint8Array(len);
  out[0] = type;
  let o = 1;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}
const errorFrame = (msg) => frame(T_ERROR, enc.encode(msg));

function send(ws, bytes) {
  try {
    ws.send(bytes);
    return true;
  } catch {
    return false;
  }
}

async function verifyHello(u8) {
  const pk = u8.slice(1, 33);
  const tsBytes = u8.slice(33, 41);
  const sig = u8.slice(41, 105);
  const ts = Number(new DataView(tsBytes.buffer).getBigUint64(0));
  if (Math.abs(Date.now() - ts) > HELLO_MAX_SKEW_MS) return { err: "HELLO timestamp out of range (check clock)" };
  const msg = new Uint8Array(HELLO_CONTEXT.length + 40);
  msg.set(HELLO_CONTEXT, 0);
  msg.set(pk, HELLO_CONTEXT.length);
  msg.set(tsBytes, HELLO_CONTEXT.length + 32);
  let ok = false;
  try {
    const key = await crypto.subtle.importKey("raw", pk, { name: "Ed25519" }, false, ["verify"]);
    ok = await crypto.subtle.verify({ name: "Ed25519" }, key, sig, msg);
  } catch {
    return { err: "bad public key" };
  }
  if (!ok) return { err: "bad signature" };
  return { pk, ts };
}

class Bucket {
  constructor(rate, burst) {
    this.rate = rate;
    this.burst = burst;
    this.tokens = burst;
    this.last = Date.now();
  }
  take(n) {
    if (this.rate <= 0) return true;
    const now = Date.now();
    this.tokens = Math.min(this.burst, this.tokens + ((now - this.last) / 1000) * this.rate);
    this.last = now;
    if (this.tokens >= n) {
      this.tokens -= n;
      return true;
    }
    return false;
  }
}

// ---- Worker entry -----------------------------------------------------------

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/") {
      return new Response(
        "Lumora relay (Cloudflare). WebSocket endpoint: /ws  Stats: /health\n" +
          "Payloads are end-to-end encrypted; this relay cannot read them.\n",
        { headers: { "content-type": "text/plain; charset=utf-8" } },
      );
    }
    if (url.pathname !== "/ws" && url.pathname !== "/health") {
      return new Response("not found\n", { status: 404 });
    }
    if (url.pathname === "/ws" && request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("expected WebSocket upgrade\n", { status: 426 });
    }
    const name = env.HUB || "global";
    const id = env.RELAY.idFromName(name);
    const stub = env.LOCATION_HINT ? env.RELAY.get(id, { locationHint: env.LOCATION_HINT }) : env.RELAY.get(id);
    return stub.fetch(request);
  },
};

// ---- Hub Durable Object -------------------------------------------------------

export class RelayHub extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.cfg = settings(env);
    this.sql = ctx.storage.sql;
    /** pkHex → WebSocket (authenticated sessions) */
    this.byPk = new Map();
    /** ws → per-socket volatile state (rate limiters, pending HELLO) */
    this.vol = new Map();
    this.budgetDay = 0;
    this.budgetUsed = 0;
    this.budgetUnflushed = 0;
    this.budgetFlushedAt = 0;
    ctx.blockConcurrencyWhile(async () => {
      this.sql.exec(`CREATE TABLE IF NOT EXISTS mailbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT, rcpt TEXT NOT NULL, exp INTEGER NOT NULL, frame BLOB NOT NULL)`);
      this.sql.exec(`CREATE INDEX IF NOT EXISTS mailbox_rcpt ON mailbox(rcpt)`);
      this.sql.exec(`CREATE TABLE IF NOT EXISTS hello_seen (k TEXT PRIMARY KEY, exp INTEGER NOT NULL)`);
      this.sql.exec(`CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v INTEGER NOT NULL)`);
      this.mbBytes = this.kvGet("mb_bytes");
      this.mbItems = this.kvGet("mb_items");
      this.budgetDay = this.kvGet("budget_day");
      this.budgetUsed = this.kvGet("budget_used");
    });
    for (const ws of ctx.getWebSockets()) {
      const a = ws.deserializeAttachment();
      if (a?.pk) this.byPk.set(a.pk, ws);
    }
  }

  kvGet(k) {
    const r = this.sql.exec("SELECT v FROM kv WHERE k = ?", k).toArray();
    return r.length ? Number(r[0].v) : 0;
  }
  kvSet(k, v) {
    this.sql.exec("INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", k, v);
  }

  volatile(ws) {
    let v = this.vol.get(ws);
    if (!v) {
      v = {
        data: new Bucket(this.cfg.dataRate, Math.max(this.cfg.dataBurst, this.cfg.maxFrame)),
        sig: new Bucket(this.cfg.signalRate, Math.max(1, this.cfg.signalRate * 2)),
        gone: new Map(),
        lastBudgetErr: 0,
        pending: null,
      };
      this.vol.set(ws, v);
    }
    return v;
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/health") return this.health();
    if (this.ctx.getWebSockets().length >= this.cfg.maxClients + Math.floor(this.cfg.maxClients / 10) + 16) {
      return new Response("relay full\n", { status: 503 });
    }
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    const ip = request.headers.get("CF-Connecting-IP") || "";
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ pk: null, ip, t: Date.now() });
    await this.ensureAlarm(HELLO_TIMEOUT_MS + 1000);
    return new Response(null, { status: 101, webSocket: client });
  }

  health() {
    this.rollBudgetDay();
    return Response.json({
      status: "ok",
      runtime: "cloudflare-durable-object",
      hub: this.cfg.hub,
      clients: this.byPk.size,
      connections: this.ctx.getWebSockets().length,
      max_clients: this.cfg.maxClients,
      data_budget_bytes: this.cfg.dataBudget,
      data_used_today: this.budgetUsed,
      mailbox: { enabled: this.cfg.mailbox, items: this.mbItems, bytes: this.mbBytes },
      private: this.cfg.allow !== null,
    });
  }

  async ensureAlarm(inMs) {
    const cur = await this.ctx.storage.getAlarm();
    const want = Date.now() + inMs;
    if (cur === null || cur > want) await this.ctx.storage.setAlarm(want);
  }

  // Hello timeouts, replay-cache and mailbox expiry.
  async alarm() {
    const now = Date.now();
    let unauth = 0;
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment();
      if (a && !a.pk && !a.dead) {
        if (now - a.t > HELLO_TIMEOUT_MS) this.reject(ws, "HELLO timeout");
        else unauth++;
      }
    }
    this.sql.exec("DELETE FROM hello_seen WHERE exp < ?", now);
    if (this.mbItems > 0) {
      const r = this.sql.exec("DELETE FROM mailbox WHERE exp < ?", now);
      if (r.rowsWritten > 0) this.recountMailbox();
    }
    this.flushBudget(true);
    if (unauth > 0) await this.ctx.storage.setAlarm(now + SWEEP_MS / 3);
    else if (this.mbItems > 0 || this.byPk.size > 0) await this.ctx.storage.setAlarm(now + 3600_000);
  }

  recountMailbox() {
    const r = this.sql.exec("SELECT COUNT(*) AS n, COALESCE(SUM(length(frame)), 0) AS b FROM mailbox").one();
    this.mbItems = Number(r.n);
    this.mbBytes = Number(r.b);
    this.kvSet("mb_items", this.mbItems);
    this.kvSet("mb_bytes", this.mbBytes);
  }

  reject(ws, why) {
    send(ws, errorFrame(why));
    try {
      ws.close(1008, why.slice(0, 120));
    } catch {}
    this.drop(ws);
  }

  drop(ws) {
    const a = ws.deserializeAttachment();
    if (a?.pk && this.byPk.get(a.pk) === ws) this.byPk.delete(a.pk);
    this.vol.delete(ws);
  }

  async webSocketMessage(ws, message) {
    if (typeof message === "string") return; // text frames are not part of the protocol
    const u8 = new Uint8Array(message);
    if (u8.length === 0) return;
    const v = this.volatile(ws);
    if (v.pending) await v.pending; // keep order behind an in-flight HELLO check
    const a = ws.deserializeAttachment();
    if (!a) return;
    if (!a.pk) {
      v.pending = this.handleHello(ws, a, u8).finally(() => {
        v.pending = null;
      });
      return v.pending;
    }
    if (u8.length > this.cfg.maxFrame) {
      send(ws, errorFrame("frame too large"));
      return;
    }
    switch (u8[0]) {
      case T_DATA:
        return this.onData(ws, a, v, u8);
      case T_SIGNAL:
        return this.onSignal(ws, a, v, u8);
      case T_HELLO:
        send(ws, errorFrame("already authenticated"));
        return;
      default:
        send(ws, errorFrame("unknown frame type"));
    }
  }

  async handleHello(ws, a, u8) {
    if (u8.length !== HELLO_LEN || u8[0] !== T_HELLO) return this.reject(ws, "expected HELLO");
    const r = await verifyHello(u8);
    if (r.err) return this.reject(ws, r.err);
    const pk = toHex(r.pk);
    const key = `${pk}:${r.ts}`;
    if (this.sql.exec("SELECT 1 FROM hello_seen WHERE k = ?", key).toArray().length) {
      return this.reject(ws, "replayed HELLO");
    }
    this.sql.exec("INSERT INTO hello_seen (k, exp) VALUES (?, ?)", key, Date.now() + REPLAY_KEEP_MS);
    if (this.cfg.allow && !this.cfg.allow.has(pk)) return this.reject(ws, "not allowed on this relay");
    const old = this.byPk.get(pk);
    if (!old && this.byPk.size >= this.cfg.maxClients) return this.reject(ws, "relay full");
    if (old && old !== ws) {
      send(old, errorFrame("replaced by a newer connection"));
      try {
        old.close(1000, "replaced");
      } catch {}
      this.vol.delete(old);
      old.serializeAttachment({ ...old.deserializeAttachment(), pk: null, dead: true });
    }
    ws.serializeAttachment({ ...a, pk });
    this.byPk.set(pk, ws);
    send(ws, frame(T_WELCOME, enc.encode(a.ip || "")));
    if (this.cfg.mailbox && this.mbItems > 0) this.deliverMailbox(ws, pk);
  }

  deliverMailbox(ws, pk) {
    const rows = this.sql
      .exec("SELECT id, frame FROM mailbox WHERE rcpt = ? AND exp > ? ORDER BY id", pk, Date.now())
      .toArray();
    if (!rows.length) return;
    let delivered = 0;
    for (const row of rows) {
      if (!send(ws, new Uint8Array(row.frame))) break;
      delivered = row.id;
    }
    if (delivered) {
      this.sql.exec("DELETE FROM mailbox WHERE rcpt = ? AND id <= ?", pk, delivered);
      this.recountMailbox();
    }
  }

  // DATA: forward with the peer field rewritten to the sender's key.
  onData(ws, a, v, u8) {
    if (u8.length < 33) return;
    this.rollBudgetDay();
    if (this.cfg.dataBudget > 0 && this.budgetUsed >= this.cfg.dataBudget) {
      const now = Date.now();
      if (now - v.lastBudgetErr > 5000) {
        v.lastBudgetErr = now;
        send(ws, errorFrame("daily relay data budget exhausted"));
      }
      return;
    }
    if (!v.data.take(u8.length)) return; // over bandwidth: drop (UDP semantics)
    const to = toHex(u8.subarray(1, 33));
    const target = this.byPk.get(to);
    if (!target) {
      const now = Date.now();
      const last = v.gone.get(to) || 0;
      if (now - last >= 1000) {
        if (v.gone.size > 1024) v.gone.clear();
        v.gone.set(to, now);
        send(ws, frame(T_GONE, u8.subarray(1, 33)));
      }
      return;
    }
    const out = new Uint8Array(u8);
    out.set(fromHex(a.pk), 1);
    if (send(target, out)) this.addBudget(out.length);
  }

  async onSignal(ws, a, v, u8) {
    if (u8.length < 33) return;
    if (!v.sig.take(1)) {
      send(ws, errorFrame("signal rate limit exceeded"));
      return;
    }
    const toBytes = u8.subarray(1, 33);
    const to = toHex(toBytes);
    const out = new Uint8Array(u8);
    out.set(fromHex(a.pk), 1);
    const target = this.byPk.get(to);
    if (target && send(target, out)) return;
    if (!this.cfg.mailbox) {
      send(ws, frame(T_GONE, toBytes));
      return;
    }
    const err = await this.mailboxPut(to, out);
    if (err) send(ws, errorFrame(err));
  }

  async mailboxPut(to, out) {
    if (out.length - 33 > this.cfg.mbMaxItem) return "signal too large for mailbox";
    if (this.mbBytes + out.length > this.cfg.mbTotal) return "relay mailbox full";
    const n = this.sql.exec("SELECT COUNT(*) AS n FROM mailbox WHERE rcpt = ? AND exp > ?", to, Date.now()).one().n;
    if (Number(n) >= this.cfg.mbMaxItems) return "mailbox full for this peer";
    this.sql.exec("INSERT INTO mailbox (rcpt, exp, frame) VALUES (?, ?, ?)", to, Date.now() + this.cfg.mbTtlMs, out.buffer);
    this.mbItems += 1;
    this.mbBytes += out.length;
    this.kvSet("mb_items", this.mbItems);
    this.kvSet("mb_bytes", this.mbBytes);
    await this.ensureAlarm(3600_000);
    return null;
  }

  rollBudgetDay() {
    const day = Math.floor(Date.now() / DAY_MS);
    if (day !== this.budgetDay) {
      this.budgetDay = day;
      this.budgetUsed = 0;
      this.budgetUnflushed = 1; // force a write of the reset
      this.flushBudget(true);
    }
  }

  addBudget(n) {
    this.budgetUsed += n;
    this.budgetUnflushed += n;
    this.flushBudget(false);
  }

  // Persist the daily counter rarely (SQLite row writes are metered).
  flushBudget(force) {
    if (!this.budgetUnflushed) return;
    const now = Date.now();
    if (force || this.budgetUnflushed > 1024 * 1024 || now - this.budgetFlushedAt > 10_000) {
      this.kvSet("budget_day", this.budgetDay);
      this.kvSet("budget_used", this.budgetUsed);
      this.budgetUnflushed = 0;
      this.budgetFlushedAt = now;
    }
  }

  async webSocketClose(ws, code) {
    this.drop(ws);
    this.flushBudget(true);
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code, "bye");
    } catch {}
  }

  async webSocketError(ws) {
    this.drop(ws);
  }
}
