//! Encrypted local storage (SQLCipher, AES-256 page encryption + HMAC).
//!
//! Long-running memory/disk hygiene:
//! * page cache hard-capped (`cache_size`), WAL checkpointed and truncated periodically
//! * `auto_vacuum = INCREMENTAL` + periodic `incremental_vacuum` returns freed pages
//! * expired (self-destruct) messages and old mailbox items are purged
//! * all list queries are paginated; nothing loads a whole conversation into RAM

use crate::identity::PeerId;
use anyhow::{Context, Result};
use parking_lot::Mutex;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::Path;
use zeroize::Zeroizing;

#[path = "store_sync.rs"]
pub mod sync;

/// Store-and-forward mail we keep for others: bytes per recipient device / overall.
/// (Small in unit tests so the caps can be exercised quickly.)
pub const MAILBOX_MAX_PER_PEER: usize = if cfg!(test) { 512 * 1024 } else { 32 * 1024 * 1024 };
pub const MAILBOX_MAX_TOTAL: usize = if cfg!(test) { 1024 * 1024 } else { 256 * 1024 * 1024 };
/// Active stories kept per author (a friend posting more is ignored until some expire).
pub const MAX_STORIES_PER_AUTHOR: i64 = 50;
/// Stranger contact rows (status 0) with nothing attached are forgotten after this long.
pub const STRANGER_TTL_MS: i64 = 30 * 86_400_000;
/// Received-sticker cache budget (bytes); least recently used stickers that aren't in
/// one of my packs are evicted beyond it.
pub const STICKER_CACHE_MAX: u64 = if cfg!(test) { 2 * 1024 * 1024 } else { 200 * 1024 * 1024 };
/// Envelope bytes kept per group for anti-entropy (oldest dropped beyond it).
pub const GROUP_LOG_MAX_BYTES: u64 = if cfg!(test) { 4 * 1024 * 1024 } else { 64 * 1024 * 1024 };

pub struct Store {
    conn: Mutex<Connection>,
    /// Multi-device: log changes for sibling anti-entropy (only while the account has ≥ 2
    /// active devices, so single-device users pay nothing).
    sync_on: std::sync::atomic::AtomicBool,
    last_rev: std::sync::atomic::AtomicU64,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Contact {
    pub peer: String,
    pub short_id: String,
    pub name: String,
    pub alias: Option<String>,
    /// 0 none, 1 request sent, 2 request received, 3 friend, 4 blocked
    pub status: i64,
    pub added: i64,
    pub last_seen: i64,
    pub verified: bool,
    pub relays: Vec<String>,
    #[serde(default)]
    pub bio: String,
    #[serde(default)]
    pub presence: String,
    #[serde(default)]
    pub has_avatar: bool,
    /// Bot profile (commands, about) if this contact is a bot.
    #[serde(default)]
    pub bot: Value,
    #[serde(default)]
    pub username: Option<String>,
    /// `@name·tag` (tag verified from the key)
    #[serde(default)]
    pub handle: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Conversation {
    pub id: String,
    pub kind: i64,
    pub title: String,
    pub last_ts: i64,
    pub unread: i64,
    pub muted: bool,
    pub pinned: bool,
    pub last_text: String,
    #[serde(default)]
    pub archived: bool,
    /// The last message is mine (the list shows "You: …"); system lines never are.
    #[serde(default)]
    pub last_mine: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct StoredMessage {
    pub id: String,
    pub conv: String,
    pub author: String,
    pub hlc: i64,
    pub ts: i64,
    pub kind: String,
    pub body: Value,
    pub status: i64,
    pub edited: bool,
    pub deleted: bool,
    pub reply_to: Option<String>,
    pub reactions: Value,
    pub expires: Option<i64>,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub meta: Value,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct FileRow {
    pub id: String,
    pub conv: String,
    pub peer: String,
    pub name: String,
    pub size: i64,
    pub hash: String,
    pub path: String,
    /// 0 outgoing, 1 incoming
    pub direction: i64,
    /// 0 offered, 1 transferring, 2 done, 3 failed, 4 cancelled, 5 paused,
    /// 6 removed locally (fetch again from the sender), 7 kept on another of my devices
    /// (history copied to this device; fetched from that device on demand)
    pub state: i64,
    pub progress: i64,
    pub created: i64,
}

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v BLOB);
CREATE TABLE IF NOT EXISTS contacts(
  peer BLOB PRIMARY KEY, name TEXT NOT NULL DEFAULT '', alias TEXT, status INTEGER NOT NULL DEFAULT 0,
  added INTEGER NOT NULL DEFAULT 0, last_seen INTEGER NOT NULL DEFAULT 0, verified INTEGER NOT NULL DEFAULT 0,
  relays TEXT NOT NULL DEFAULT '[]');
CREATE TABLE IF NOT EXISTS convs(
  id TEXT PRIMARY KEY, kind INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '', last_ts INTEGER NOT NULL DEFAULT 0,
  unread INTEGER NOT NULL DEFAULT 0, muted INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0,
  last_text TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS messages(
  id BLOB PRIMARY KEY, conv TEXT NOT NULL, author BLOB NOT NULL, hlc INTEGER NOT NULL, kind TEXT NOT NULL,
  body TEXT NOT NULL, status INTEGER NOT NULL DEFAULT 0, edited INTEGER NOT NULL DEFAULT 0,
  deleted INTEGER NOT NULL DEFAULT 0, reply_to BLOB, reactions TEXT NOT NULL DEFAULT '{}', expires INTEGER);
CREATE INDEX IF NOT EXISTS messages_conv ON messages(conv, hlc);
CREATE INDEX IF NOT EXISTS messages_expires ON messages(expires) WHERE expires IS NOT NULL;
CREATE TABLE IF NOT EXISTS groups(id BLOB PRIMARY KEY, state BLOB NOT NULL, updated INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS group_ops(id BLOB PRIMARY KEY, gid BLOB NOT NULL, hlc INTEGER NOT NULL, author BLOB NOT NULL, op BLOB NOT NULL);
CREATE INDEX IF NOT EXISTS group_ops_gid ON group_ops(gid, hlc);
CREATE TABLE IF NOT EXISTS group_keys(gid BLOB NOT NULL, epoch INTEGER NOT NULL, key BLOB NOT NULL, PRIMARY KEY(gid, epoch));
CREATE TABLE IF NOT EXISTS group_log(id BLOB PRIMARY KEY, gid BLOB NOT NULL, author BLOB NOT NULL, hlc INTEGER NOT NULL, env BLOB NOT NULL);
CREATE INDEX IF NOT EXISTS group_log_gid ON group_log(gid, author, hlc);
CREATE TABLE IF NOT EXISTS outbox(id BLOB NOT NULL, to_peer BLOB NOT NULL, payload BLOB NOT NULL, created INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(id, to_peer));
CREATE TABLE IF NOT EXISTS mailbox(id BLOB PRIMARY KEY, for_peer BLOB NOT NULL, payload BLOB NOT NULL, created INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS mailbox_peer ON mailbox(for_peer);
CREATE TABLE IF NOT EXISTS files(id BLOB PRIMARY KEY, conv TEXT NOT NULL, peer BLOB NOT NULL, name TEXT NOT NULL,
  size INTEGER NOT NULL, hash BLOB NOT NULL, path TEXT NOT NULL, direction INTEGER NOT NULL, state INTEGER NOT NULL,
  progress INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS peer_cache(peer BLOB PRIMARY KEY, info BLOB NOT NULL, updated INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS stories(id BLOB PRIMARY KEY, author BLOB NOT NULL, created INTEGER NOT NULL, text TEXT NOT NULL,
  image BLOB, bg TEXT NOT NULL DEFAULT '', seen INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS story_views(id BLOB NOT NULL, viewer BLOB NOT NULL, at INTEGER NOT NULL, PRIMARY KEY(id, viewer));
CREATE TABLE IF NOT EXISTS sticker_packs(id TEXT PRIMARY KEY, name TEXT NOT NULL, created INTEGER NOT NULL, sort INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS stickers(hash BLOB NOT NULL, pack TEXT NOT NULL, mime TEXT NOT NULL, emoji TEXT NOT NULL DEFAULT '',
  animated INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL, PRIMARY KEY(hash, pack));
CREATE TABLE IF NOT EXISTS sticker_blobs(hash BLOB PRIMARY KEY, mime TEXT NOT NULL, data BLOB NOT NULL, used INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS group_reads(conv TEXT NOT NULL, peer BLOB NOT NULL, upto INTEGER NOT NULL, PRIMARY KEY(conv, peer));
CREATE TABLE IF NOT EXISTS retention(conv TEXT PRIMARY KEY, ms INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS remote_trusted(peer BLOB PRIMARY KEY, perms INTEGER NOT NULL, added INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS device_lists(account BLOB PRIMARY KEY, version INTEGER NOT NULL, list BLOB NOT NULL, updated INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS devices(device BLOB PRIMARY KEY, account BLOB NOT NULL, name TEXT NOT NULL DEFAULT '', kind INTEGER NOT NULL DEFAULT 0,
  caps INTEGER NOT NULL DEFAULT 0, added INTEGER NOT NULL DEFAULT 0, listed INTEGER NOT NULL DEFAULT 0, revoked INTEGER,
  last_seen INTEGER NOT NULL DEFAULT 0, proto INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS devices_account ON devices(account);
CREATE TABLE IF NOT EXISTS sync_log(seq INTEGER PRIMARY KEY AUTOINCREMENT, kind INTEGER NOT NULL, key BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS sync_peers(device BLOB PRIMARY KEY, sent_upto INTEGER NOT NULL DEFAULT 0, hist_cursor BLOB, hist_done INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS lww(key TEXT PRIMARY KEY, rev INTEGER NOT NULL);
"#;

/// Additive schema migrations (idempotent).
fn migrate(c: &Connection) {
    for sql in [
        "ALTER TABLE contacts ADD COLUMN bio TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE contacts ADD COLUMN presence TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE contacts ADD COLUMN avatar BLOB",
        "ALTER TABLE contacts ADD COLUMN cover BLOB",
        "ALTER TABLE contacts ADD COLUMN bot TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE contacts ADD COLUMN username TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE messages ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE messages ADD COLUMN meta TEXT NOT NULL DEFAULT '{}'",
        "ALTER TABLE convs ADD COLUMN archived INTEGER NOT NULL DEFAULT 0",
        "CREATE INDEX IF NOT EXISTS messages_pinned ON messages(conv) WHERE pinned=1",
        // per-sender file-id namespace: a row whose local id differs from the sender's
        // file_id keeps the wire id here (NULL = same as `id`, i.e. every existing row)
        "ALTER TABLE files ADD COLUMN wire_id BLOB",
        // multi-device: authoring device, last-change stamp (sibling sync), read/clear marks
        "ALTER TABLE messages ADD COLUMN device BLOB",
        "ALTER TABLE messages ADD COLUMN rev INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE convs ADD COLUMN read_upto INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE convs ADD COLUMN cleared_upto INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE convs ADD COLUMN rev INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE contacts ADD COLUMN rev INTEGER NOT NULL DEFAULT 0",
        // group anti-flood: recent bytes per group by creation time
        "CREATE INDEX IF NOT EXISTS group_log_gid_hlc ON group_log(gid, hlc)",
        // group log: arrival time (quotas by receive time too), what an envelope carries
        // (0 unknown/older row, 1 op, 2 message, 3 action) and the message it is about
        // (purged with the message: disappearing, cleared and deleted content)
        "ALTER TABLE group_log ADD COLUMN rcv INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE group_log ADD COLUMN k INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE group_log ADD COLUMN msg_id BLOB",
        "CREATE INDEX IF NOT EXISTS group_log_msg ON group_log(msg_id) WHERE msg_id IS NOT NULL",
        "CREATE INDEX IF NOT EXISTS group_log_rcv ON group_log(gid, rcv)",
        // every key we hold for a group epoch: the one matching the winning Rekey is in
        // group_keys, keys of concurrent rotations that lost stay here (they still open
        // what was sent under them)
        "CREATE TABLE IF NOT EXISTS group_key_alts(gid BLOB NOT NULL, epoch INTEGER NOT NULL, key BLOB NOT NULL, PRIMARY KEY(gid, epoch, key))",
        // keys that arrived before their Rekey (validated against it when it comes)
        "CREATE TABLE IF NOT EXISTS group_key_pending(gid BLOB NOT NULL, epoch INTEGER NOT NULL, sender BLOB NOT NULL, key BLOB NOT NULL, at INTEGER NOT NULL,
           PRIMARY KEY(gid, epoch, sender, key))",
        // envelopes we can't open yet (their key hasn't arrived)
        "CREATE TABLE IF NOT EXISTS group_env_pending(id INTEGER PRIMARY KEY, gid BLOB NOT NULL, epoch INTEGER NOT NULL, env BLOB NOT NULL, at INTEGER NOT NULL)",
        "CREATE INDEX IF NOT EXISTS group_env_pending_gid ON group_env_pending(gid)",
        // send idempotency: an app retrying a send with the same client_id gets the same
        // message back (this device only, 24 h)
        "CREATE TABLE IF NOT EXISTS send_client_ids(cid TEXT PRIMARY KEY, resp TEXT NOT NULL, created INTEGER NOT NULL)",
        // verified group ops the fold rejected so far (they take part in later folds)
        "CREATE TABLE IF NOT EXISTS group_held(gid BLOB PRIMARY KEY, ops BLOB NOT NULL)",
        // a moderator's delete / an edit that arrived before the message it is about
        "CREATE TABLE IF NOT EXISTS pending_actions(target BLOB NOT NULL, conv TEXT NOT NULL, target_author BLOB NOT NULL, actor BLOB NOT NULL,
           action BLOB NOT NULL, at INTEGER NOT NULL)",
        "CREATE INDEX IF NOT EXISTS pending_actions_target ON pending_actions(target)",
        // file messages removed by housekeeping whose downloaded copies still need removing
        "CREATE TABLE IF NOT EXISTS file_gc(conv TEXT NOT NULL, author BLOB NOT NULL, body TEXT NOT NULL)",
        // hot lookups (perf review): slow mode's previous message per author, file refcounts / dedupe
        "CREATE INDEX IF NOT EXISTS messages_author ON messages(conv, author, hlc)",
        "CREATE INDEX IF NOT EXISTS files_path ON files(path)",
        "CREATE INDEX IF NOT EXISTS files_hash ON files(hash)",
    ] {
        let _ = c.execute(sql, []);
    }
}

fn b32(b: &[u8]) -> String {
    data_encoding::BASE32_NOPAD.encode(b).to_lowercase()
}

/// How peer ids appear in stored rows (`StoredMessage::author`, …).
pub fn b32_pub(b: &[u8]) -> String {
    b32(b)
}

/// `(conv, target_author, actor, msgpack action)` of an action waiting for its message.
pub type PendingAction = (String, Vec<u8>, Vec<u8>, Vec<u8>);

/// `(rowid, id, payload)` of a queued reliable message.
pub type OutboxRow = (i64, Vec<u8>, Vec<u8>);

impl Store {
    pub fn open(path: &Path, key: &Zeroizing<[u8; 32]>) -> Result<Store> {
        let conn = Connection::open(path).with_context(|| format!("open {}", path.display()))?;
        let hexkey = Zeroizing::new(hex::encode(&key[..]));
        conn.execute_batch(&format!("PRAGMA key = \"x'{}'\";", hexkey.as_str()))?;
        // Fails here if the key is wrong.
        conn.query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0))
            .context("database key rejected (wrong passphrase or corrupted file)")?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-8000;
             PRAGMA temp_store=MEMORY; PRAGMA foreign_keys=ON; PRAGMA auto_vacuum=INCREMENTAL;
             PRAGMA cipher_memory_security=OFF; PRAGMA journal_size_limit=8388608; PRAGMA secure_delete=ON;",
        )?;
        conn.execute_batch(SCHEMA)?;
        migrate(&conn);
        conn.set_prepared_statement_cache_capacity(64);
        Ok(Self::wrap(conn))
    }

    pub fn open_memory() -> Result<Store> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch(SCHEMA)?;
        migrate(&conn);
        Ok(Self::wrap(conn))
    }

    fn wrap(conn: Connection) -> Store {
        Store { conn: Mutex::new(conn), sync_on: Default::default(), last_rev: Default::default() }
    }

    /// Housekeeping, call every few minutes.
    pub fn maintain(&self) -> Result<()> {
        let c = self.conn.lock();
        let now = crate::util::now_ms() as i64;
        // the downloaded copies of file messages that go away are removed by the node
        // (`file_gc`, same rules as delete-for-everyone)
        c.execute(
            "INSERT INTO file_gc(conv,author,body) SELECT conv,author,body FROM messages
             WHERE expires IS NOT NULL AND expires < ?1 AND kind IN ('file','voice') AND deleted=0",
            params![now],
        )?;
        c.execute("DELETE FROM messages WHERE expires IS NOT NULL AND expires < ?1", params![now])?;
        c.execute("DELETE FROM mailbox WHERE created < ?1", params![now - 14 * 86_400_000])?;
        // per-conversation retention (ms > 0): drop messages older than the window
        let old = "SELECT m.id FROM messages m JOIN retention r ON m.conv=r.conv WHERE r.ms>0 AND (m.hlc>>8) < ?1 - r.ms";
        c.execute(
            &format!("INSERT INTO file_gc(conv,author,body) SELECT conv,author,body FROM messages WHERE kind IN ('file','voice') AND deleted=0 AND id IN ({old})"),
            params![now],
        )?;
        c.execute(&format!("DELETE FROM messages WHERE id IN ({old})"), params![now])?;
        // their group envelopes (and actions on them) are not kept or re-served either
        Self::group_log_purge_gone_on(&c)?;
        c.execute("DELETE FROM pending_actions WHERE at < ?1", params![now - 30 * 86_400_000])?;
        c.execute("DELETE FROM send_client_ids WHERE created < ?1", params![now - 86_400_000])?;
        c.execute("DELETE FROM group_key_pending WHERE at < ?1", params![now - 30 * 86_400_000])?;
        c.execute("DELETE FROM group_env_pending WHERE at < ?1", params![now - 30 * 86_400_000])?;
        c.execute("DELETE FROM outbox WHERE created < ?1", params![now - 30 * 86_400_000])?;
        c.execute("DELETE FROM stories WHERE created < ?1", params![now - 86_400_000])?;
        c.execute(
            "DELETE FROM sticker_blobs WHERE used < ?1 AND hash NOT IN (SELECT hash FROM stickers)",
            params![now - 60 * 86_400_000],
        )?;
        c.execute("DELETE FROM story_views WHERE at < ?1", params![now - 86_400_000])?;
        let _ = Self::sticker_cache_enforce_on(&c, STICKER_CACHE_MAX);
        let _ = Self::gc_stranger_contacts_on(&c, now);
        c.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA incremental_vacuum(2000); PRAGMA optimize;")?;
        c.cache_flush()?;
        Ok(())
    }

    /// Stranger rows (status 0: someone who contacted us, nothing more) are dropped after
    /// [`STRANGER_TTL_MS`] without contact. Kept: anyone with a decision (alias, verified,
    /// request either way, friend, blocked), a conversation, messages (also in groups),
    /// files, queued mail, or a shared group. Runs from `maintain` at most every 6 h.
    fn gc_stranger_contacts_on(c: &Connection, now: i64) -> Result<usize> {
        let last: i64 = c
            .query_row("SELECT v FROM kv WHERE k='gc.strangers.at'", [], |r| r.get::<_, Vec<u8>>(0))
            .optional()?
            .and_then(|v| String::from_utf8(v).ok())
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        if now - last < 6 * 3_600_000 {
            return Ok(0);
        }
        c.execute("INSERT OR REPLACE INTO kv(k,v) VALUES('gc.strangers.at',?1)", params![now.to_string().into_bytes()])?;
        Self::gc_strangers_now(c, now)
    }

    fn gc_strangers_now(c: &Connection, now: i64) -> Result<usize> {
        use std::collections::HashSet;
        let blobs = |sql: &str| -> Result<HashSet<Vec<u8>>> {
            let mut st = c.prepare(sql)?;
            let v = st.query_map([], |r| r.get::<_, Vec<u8>>(0))?.filter_map(|r| r.ok()).collect();
            Ok(v)
        };
        let candidates: Vec<Vec<u8>> = {
            let mut st = c.prepare(
                "SELECT peer FROM contacts WHERE status=0 AND alias IS NULL AND verified=0 AND MAX(added, last_seen) < ?1 LIMIT 5000",
            )?;
            let v = st.query_map(params![now - STRANGER_TTL_MS], |r| r.get::<_, Vec<u8>>(0))?.filter_map(|r| r.ok()).collect();
            v
        };
        if candidates.is_empty() {
            return Ok(0);
        }
        let mut keep = blobs("SELECT DISTINCT author FROM messages")?;
        keep.extend(blobs("SELECT DISTINCT peer FROM files")?);
        keep.extend(blobs("SELECT DISTINCT to_peer FROM outbox")?);
        let convs: HashSet<String> = {
            let mut st = c.prepare("SELECT id FROM convs WHERE id LIKE 'd:%'")?;
            let v = st.query_map([], |r| r.get::<_, String>(0))?.filter_map(|r| r.ok()).collect();
            v
        };
        for state in blobs("SELECT state FROM groups")? {
            if let Ok(g) = rmp_serde::from_slice::<crate::group::GroupState>(&state) {
                keep.extend(g.members.keys().map(|p| p.0.to_vec()));
            }
        }
        let mut n = 0;
        for peer in candidates {
            let Ok(p) = <[u8; 32]>::try_from(peer.as_slice()) else { continue };
            if keep.contains(&peer) || convs.contains(&format!("d:{}", PeerId(p).to_base32())) {
                continue;
            }
            n += c.execute("DELETE FROM contacts WHERE peer=?1 AND status=0", params![peer])?;
        }
        if n > 0 {
            tracing::debug!("forgot {n} stranger contact rows");
        }
        Ok(n)
    }

    /// Test hook: run the stranger GC now (ignores the 6 h spacing).
    #[cfg(test)]
    pub fn gc_stranger_contacts_now(&self, now: i64) -> Result<usize> {
        Self::gc_strangers_now(&self.conn.lock(), now)
    }

    /// Retention policy for a conversation: None = keep forever, Some(-1) = no history
    /// (wiped when the app restarts), Some(ms) = rolling window.
    pub fn set_retention(&self, conv: &str, ms: Option<i64>) -> Result<()> {
        {
            let c = self.conn.lock();
            Self::set_retention_on(&c, conv, ms)?;
        }
        // follows the user to their other devices (and to a new one at bootstrap)
        let k = format!("retention.{conv}");
        match ms {
            None => self.kv_del(&k),
            Some(v) => self.kv_set(&k, &v.to_le_bytes()),
        }
    }
    pub(crate) fn set_retention_on(c: &Connection, conv: &str, ms: Option<i64>) -> Result<()> {
        match ms {
            None => c.execute("DELETE FROM retention WHERE conv=?1", params![conv])?,
            Some(v) => c.execute("INSERT OR REPLACE INTO retention(conv,ms) VALUES(?1,?2)", params![conv, v])?,
        };
        Ok(())
    }
    pub fn retention(&self, conv: &str) -> Option<i64> {
        self.conn.lock().query_row("SELECT ms FROM retention WHERE conv=?1", params![conv], |r| r.get(0)).optional().ok().flatten()
    }
    /// Called at startup: wipe "no history" conversations completely.
    pub fn wipe_ephemeral(&self) -> Result<usize> {
        let c = self.conn.lock();
        c.execute(
            "INSERT INTO file_gc(conv,author,body) SELECT conv,author,body FROM messages
             WHERE conv IN (SELECT conv FROM retention WHERE ms=-1) AND kind IN ('file','voice') AND deleted=0",
            [],
        )?;
        let n = c.execute("DELETE FROM messages WHERE conv IN (SELECT conv FROM retention WHERE ms=-1)", [])?;
        Self::group_log_purge_gone_on(&c)?;
        c.execute("UPDATE convs SET last_text='', unread=0 WHERE id IN (SELECT conv FROM retention WHERE ms=-1)", [])?;
        if n > 0 {
            c.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA incremental_vacuum;")?;
        }
        Ok(n)
    }

    pub fn rekey(&self, key: &Zeroizing<[u8; 32]>) -> Result<()> {
        let hexkey = Zeroizing::new(hex::encode(&key[..]));
        self.conn.lock().execute_batch(&format!("PRAGMA rekey = \"x'{}'\";", hexkey.as_str()))?;
        Ok(())
    }

    // ---------- kv ----------
    pub fn kv_get(&self, k: &str) -> Option<Vec<u8>> {
        self.conn.lock().query_row("SELECT v FROM kv WHERE k=?1", params![k], |r| r.get(0)).optional().ok().flatten()
    }
    pub fn kv_set(&self, k: &str, v: &[u8]) -> Result<()> {
        let c = self.conn.lock();
        if sync::kv_synced(k) {
            let old: Option<Vec<u8>> = c.query_row("SELECT v FROM kv WHERE k=?1", params![k], |r| r.get(0)).optional()?.flatten();
            if old.as_deref() == Some(v) {
                return Ok(());
            }
            self.touch_kv(&c, k);
        }
        c.execute("INSERT INTO kv(k,v) VALUES(?1,?2) ON CONFLICT(k) DO UPDATE SET v=excluded.v", params![k, v])?;
        Ok(())
    }
    pub fn kv_del(&self, k: &str) -> Result<()> {
        let c = self.conn.lock();
        if c.execute("DELETE FROM kv WHERE k=?1", params![k])? > 0 && sync::kv_synced(k) {
            self.touch_kv(&c, k);
        }
        Ok(())
    }
    pub fn kv_get_json<T: for<'de> Deserialize<'de>>(&self, k: &str) -> Option<T> {
        self.kv_get(k).and_then(|v| serde_json::from_slice(&v).ok())
    }
    pub fn kv_set_json<T: Serialize>(&self, k: &str, v: &T) -> Result<()> {
        self.kv_set(k, &serde_json::to_vec(v)?)
    }

    // ---------- contacts ----------
    fn row_contact(r: &rusqlite::Row) -> rusqlite::Result<Contact> {
        let peer: Vec<u8> = r.get(0)?;
        let p = PeerId(peer.as_slice().try_into().unwrap_or([0; 32]));
        let relays: String = r.get(7)?;
        Ok(Contact {
            peer: p.to_base32(),
            short_id: p.short_id_fmt(),
            name: r.get(1)?,
            alias: r.get(2)?,
            status: r.get(3)?,
            added: r.get(4)?,
            last_seen: r.get(5)?,
            verified: r.get::<_, i64>(6)? != 0,
            relays: serde_json::from_str(&relays).unwrap_or_default(),
            bio: r.get(8)?,
            presence: r.get(9)?,
            has_avatar: r.get::<_, i64>(10)? != 0,
            bot: serde_json::from_str(&r.get::<_, String>(11)?).unwrap_or(Value::Null),
            username: Some(r.get::<_, String>(12)?).filter(|u| !u.is_empty()),
            handle: Some(r.get::<_, String>(12)?).filter(|u| !u.is_empty()).map(|u| format!("@{}·{}", u, crate::net::nostr::handle_tag(&p))),
        })
    }
    pub fn contacts(&self) -> Result<Vec<Contact>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached(
            "SELECT peer,name,alias,status,added,last_seen,verified,relays,bio,presence,avatar IS NOT NULL,bot,username FROM contacts WHERE status>0 ORDER BY status=3 DESC, name COLLATE NOCASE",
        )?;
        let rows = st.query_map([], Self::row_contact)?.filter_map(|r| r.ok()).collect();
        Ok(rows)
    }
    pub fn contact(&self, p: &PeerId) -> Option<Contact> {
        let c = self.conn.lock();
        c.query_row(
            "SELECT peer,name,alias,status,added,last_seen,verified,relays,bio,presence,avatar IS NOT NULL,bot,username FROM contacts WHERE peer=?1",
            params![&p.0[..]],
            Self::row_contact,
        )
        .optional()
        .ok()
        .flatten()
    }
    pub fn upsert_contact(&self, p: &PeerId, name: Option<&str>, status: Option<i64>) -> Result<()> {
        let c = self.conn.lock();
        let before: Option<i64> = c.query_row("SELECT status FROM contacts WHERE peer=?1", params![&p.0[..]], |r| r.get(0)).optional()?;
        c.execute(
            "INSERT INTO contacts(peer,name,status,added) VALUES(?1,COALESCE(?2,''),COALESCE(?3,0),?4)
             ON CONFLICT(peer) DO UPDATE SET name=COALESCE(?2,name), status=COALESCE(?3,status)",
            params![&p.0[..], name, status, crate::util::now_ms() as i64],
        )?;
        // the user's own decisions (friend / blocked / removed) follow them to every device
        if status.is_some() && before != status {
            self.touch_contact(&c, p);
        }
        Ok(())
    }
    pub fn set_contact_field(&self, p: &PeerId, field: &str, v: rusqlite::types::Value) -> Result<()> {
        let allowed = ["alias", "last_seen", "verified", "relays", "status", "name", "bio", "presence", "avatar", "cover", "bot", "username"];
        anyhow::ensure!(allowed.contains(&field), "field not allowed");
        let c = self.conn.lock();
        let n = c.execute(&format!("UPDATE contacts SET {field}=?1 WHERE peer=?2 AND {field} IS NOT ?1"), params![v, &p.0[..]])?;
        if n > 0 && matches!(field, "alias" | "verified" | "status") {
            self.touch_contact(&c, p);
        }
        Ok(())
    }
    pub fn contact_cover(&self, p: &PeerId) -> Option<Vec<u8>> {
        self.conn.lock().query_row("SELECT cover FROM contacts WHERE peer=?1", params![&p.0[..]], |r| r.get(0)).optional().ok().flatten().flatten()
    }
    pub fn contact_avatar(&self, p: &PeerId) -> Option<Vec<u8>> {
        self.conn.lock().query_row("SELECT avatar FROM contacts WHERE peer=?1", params![&p.0[..]], |r| r.get(0)).optional().ok().flatten().flatten()
    }
    pub fn is_friend(&self, p: &PeerId) -> bool {
        self.contact(p).map(|c| c.status == 3).unwrap_or(false)
    }
    pub fn is_blocked(&self, p: &PeerId) -> bool {
        self.contact(p).map(|c| c.status == 4).unwrap_or(false)
    }
    pub fn friend_ids(&self) -> Vec<PeerId> {
        let c = self.conn.lock();
        let Ok(mut st) = c.prepare_cached("SELECT peer FROM contacts WHERE status=3") else { return vec![] };
        st.query_map([], |r| r.get::<_, Vec<u8>>(0))
            .map(|it| it.filter_map(|r| r.ok()).filter_map(|v| v.try_into().ok().map(PeerId)).collect())
            .unwrap_or_default()
    }

    // ---------- conversations ----------
    pub fn ensure_conv(&self, id: &str, kind: i64, title: &str) -> Result<()> {
        let c = self.conn.lock();
        let exists = c.query_row("SELECT 1 FROM convs WHERE id=?1", params![id], |_| Ok(())).optional()?.is_some();
        c.execute(
            "INSERT INTO convs(id,kind,title) VALUES(?1,?2,?3) ON CONFLICT(id) DO UPDATE SET title=CASE WHEN ?3<>'' THEN ?3 ELSE title END",
            params![id, kind, title],
        )?;
        if !exists {
            self.track(&c, sync::K_CONV, id.as_bytes());
        }
        Ok(())
    }
    pub fn conversations(&self) -> Result<Vec<Conversation>> {
        self.conversations_for(None)
    }
    /// The chat list; with `me`, each row says whether its last message is mine.
    pub fn conversations_for(&self, me: Option<&PeerId>) -> Result<Vec<Conversation>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached(
            "SELECT id,kind,title,last_ts,unread,muted,pinned,last_text,archived,
                    COALESCE((SELECT m.author=?1 AND m.kind<>'system' FROM messages m WHERE m.conv=convs.id ORDER BY m.hlc DESC LIMIT 1), 0)
             FROM convs ORDER BY pinned DESC, last_ts DESC LIMIT 500",
        )?;
        let me_b: Vec<u8> = me.map(|p| p.0.to_vec()).unwrap_or_default();
        let rows = st
            .query_map(params![me_b], |r| {
                Ok(Conversation {
                    id: r.get(0)?,
                    kind: r.get(1)?,
                    title: r.get(2)?,
                    last_ts: r.get(3)?,
                    unread: r.get(4)?,
                    muted: r.get::<_, i64>(5)? != 0,
                    pinned: r.get::<_, i64>(6)? != 0,
                    last_text: r.get(7)?,
                    archived: r.get::<_, i64>(8)? != 0,
                    last_mine: r.get::<_, i64>(9)? != 0,
                })
            })?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }
    pub fn conv_touch(&self, id: &str, ts: i64, text: &str, unread_inc: bool) -> Result<()> {
        let preview: String = text.chars().take(120).collect();
        // a sender's clock far ahead (or a forged date) must not pin the chat to the top
        let ts = ts.min(crate::util::hlc_to_ms(crate::util::clamp_hlc_now()) as i64);
        self.conn.lock().execute(
            "UPDATE convs SET last_ts=MAX(last_ts,?2), last_text=?3, unread=unread+?4 WHERE id=?1",
            params![id, ts, preview, if unread_inc { 1 } else { 0 }],
        )?;
        Ok(())
    }
    pub fn conv_cleared_upto(&self, id: &str) -> Option<i64> {
        self.conn.lock().query_row("SELECT cleared_upto FROM convs WHERE id=?1", params![id], |r| r.get(0)).optional().ok().flatten()
    }
    pub fn conv_mark_read(&self, id: &str) -> Result<()> {
        let c = self.conn.lock();
        c.execute("UPDATE convs SET unread=0 WHERE id=?1", params![id])?;
        // read position (max wins across the account's devices) — never beyond "now": a
        // message dated in the future must not mark everything after it as read
        let n = c.execute(
            "UPDATE convs SET read_upto=MIN(?2, (SELECT MAX(hlc) FROM messages WHERE conv=?1)) WHERE id=?1
             AND read_upto < MIN(?2, COALESCE((SELECT MAX(hlc) FROM messages WHERE conv=?1), 0))",
            params![id, crate::util::clamp_hlc_now().min(i64::MAX as u64) as i64],
        )?;
        if n > 0 {
            self.track(&c, sync::K_CONV, id.as_bytes());
        }
        Ok(())
    }
    pub fn conv_set_flag(&self, id: &str, flag: &str, v: bool) -> Result<()> {
        anyhow::ensure!(flag == "muted" || flag == "pinned" || flag == "archived");
        let c = self.conn.lock();
        if c.execute(&format!("UPDATE convs SET {flag}=?2 WHERE id=?1 AND {flag}<>?2"), params![id, v as i64])? > 0 {
            c.execute("UPDATE convs SET rev=?2 WHERE id=?1", params![id, self.next_rev() as i64])?;
            self.track(&c, sync::K_CONV, id.as_bytes());
        }
        Ok(())
    }
    pub fn delete_conv(&self, id: &str) -> Result<()> {
        let c = self.conn.lock();
        c.execute("DELETE FROM messages WHERE conv=?1", params![id])?;
        Self::group_log_purge_gone_on(&c)?;
        if c.execute("DELETE FROM convs WHERE id=?1", params![id])? > 0 {
            self.track(&c, sync::K_CONV_DEL, id.as_bytes());
        }
        Ok(())
    }

    // ---------- messages ----------
    fn row_msg(r: &rusqlite::Row) -> rusqlite::Result<StoredMessage> {
        let id: Vec<u8> = r.get(0)?;
        let author: Vec<u8> = r.get(2)?;
        let hlc: i64 = r.get(3)?;
        let body: String = r.get(5)?;
        let reply: Option<Vec<u8>> = r.get(9)?;
        let reactions: String = r.get(10)?;
        Ok(StoredMessage {
            id: hex::encode(id),
            conv: r.get(1)?,
            author: b32(&author),
            hlc,
            ts: hlc >> 8,
            kind: r.get(4)?,
            body: serde_json::from_str(&body).unwrap_or(Value::Null),
            status: r.get(6)?,
            edited: r.get::<_, i64>(7)? != 0,
            deleted: r.get::<_, i64>(8)? != 0,
            reply_to: reply.map(hex::encode),
            reactions: serde_json::from_str(&reactions).unwrap_or(Value::Null),
            expires: r.get(11)?,
            pinned: r.get::<_, i64>(12)? != 0,
            meta: serde_json::from_str(&r.get::<_, String>(13)?).unwrap_or(Value::Null),
        })
    }

    /// Insert; returns false if it already existed (dedupe for gossip/resends).
    #[allow(clippy::too_many_arguments)]
    pub fn insert_message(
        &self,
        id: &[u8],
        conv: &str,
        author: &PeerId,
        hlc: u64,
        kind: &str,
        body: &Value,
        status: i64,
        reply_to: Option<&[u8]>,
        expires: Option<i64>,
    ) -> Result<bool> {
        let c = self.conn.lock();
        // a conversation cleared up to here stays cleared (late or re-sent history)
        let cleared: i64 = c.query_row("SELECT cleared_upto FROM convs WHERE id=?1", params![conv], |r| r.get(0)).optional()?.unwrap_or(0);
        if (hlc.min(i64::MAX as u64) as i64) <= cleared {
            return Ok(false);
        }
        let n = c.execute(
            "INSERT OR IGNORE INTO messages(id,conv,author,hlc,kind,body,status,reply_to,expires,rev) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
            params![id, conv, &author.0[..], hlc.min(i64::MAX as u64) as i64, kind, body.to_string(), status, reply_to, expires, self.next_rev() as i64],
        )?;
        if n > 0 {
            self.track(&c, sync::K_MSG, id);
        }
        Ok(n > 0)
    }
    pub fn message(&self, id: &[u8]) -> Option<StoredMessage> {
        let c = self.conn.lock();
        c.query_row(
            "SELECT id,conv,author,hlc,kind,body,status,edited,deleted,reply_to,reactions,expires,pinned,meta FROM messages WHERE id=?1",
            params![id],
            Self::row_msg,
        )
        .optional()
        .ok()
        .flatten()
    }
    /// Page backwards from `before_hlc` (exclusive). Newest-last ordering for UI.
    pub fn messages(&self, conv: &str, before_hlc: Option<i64>, limit: i64) -> Result<Vec<StoredMessage>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached(
            "SELECT id,conv,author,hlc,kind,body,status,edited,deleted,reply_to,reactions,expires,pinned,meta FROM messages
             WHERE conv=?1 AND hlc < ?2 ORDER BY hlc DESC LIMIT ?3",
        )?;
        let mut rows: Vec<StoredMessage> = st
            .query_map(params![conv, before_hlc.unwrap_or(i64::MAX), limit.clamp(1, 500)], Self::row_msg)?
            .filter_map(|r| r.ok())
            .collect();
        rows.reverse();
        Ok(rows)
    }
    pub fn search(&self, q: &str, limit: i64) -> Result<Vec<StoredMessage>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached(
            "SELECT id,conv,author,hlc,kind,body,status,edited,deleted,reply_to,reactions,expires,pinned,meta FROM messages
             WHERE deleted=0 AND kind='text' AND body LIKE ?1 ESCAPE '\\' ORDER BY hlc DESC LIMIT ?2",
        )?;
        let pat = format!("%{}%", q.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_"));
        let rows = st.query_map(params![pat, limit], Self::row_msg)?.filter_map(|r| r.ok()).collect();
        Ok(rows)
    }
    /// Author-only body replacement without the "edited" flag (live location updates).
    pub fn update_body(&self, id: &[u8], author: &PeerId, body: &Value) -> Result<bool> {
        let c = self.conn.lock();
        let n = c.execute(
            "UPDATE messages SET body=?3 WHERE id=?1 AND author=?2 AND deleted=0",
            params![id, &author.0[..], body.to_string()],
        )?;
        self.bump_if(&c, n, id);
        Ok(n > 0)
    }
    /// Store a story; false if already known or its author already has
    /// [`MAX_STORIES_PER_AUTHOR`] active (≤ 24 h old) stories.
    pub fn story_put(&self, id: &[u8], author: &PeerId, created: i64, text: &str, image: &[u8], bg: &str) -> Result<bool> {
        let c = self.conn.lock();
        let active: i64 = c.query_row(
            "SELECT count(*) FROM stories WHERE author=?1 AND created > ?2",
            params![&author.0[..], crate::util::now_ms() as i64 - 86_400_000],
            |r| r.get(0),
        )?;
        if active >= MAX_STORIES_PER_AUTHOR {
            return Ok(false);
        }
        Ok(c.execute(
            "INSERT OR IGNORE INTO stories(id,author,created,text,image,bg) VALUES(?1,?2,?3,?4,?5,?6)",
            params![id, &author.0[..], created, text, if image.is_empty() { None } else { Some(image) }, bg],
        )? > 0)
    }
    /// Active (≤ 24 h old) stories of `author`.
    pub fn story_count(&self, author: &PeerId) -> i64 {
        self.conn
            .lock()
            .query_row(
                "SELECT count(*) FROM stories WHERE author=?1 AND created > ?2",
                params![&author.0[..], crate::util::now_ms() as i64 - 86_400_000],
                |r| r.get(0),
            )
            .unwrap_or(0)
    }
    pub fn stories(&self) -> Result<Vec<Value>> {
        let c = self.conn.lock();
        let since = crate::util::now_ms() as i64 - 86_400_000;
        let mut st = c.prepare_cached(
            "SELECT s.id, s.author, s.created, s.text, s.image IS NOT NULL, s.bg, s.seen, (SELECT count(*) FROM story_views v WHERE v.id=s.id)
             FROM stories s WHERE s.created > ?1 ORDER BY s.created DESC LIMIT 300",
        )?;
        let rows = st
            .query_map(params![since], |r| {
                let id: Vec<u8> = r.get(0)?;
                let a: Vec<u8> = r.get(1)?;
                Ok(serde_json::json!({
                    "id": hex::encode(id), "author": b32(&a), "created": r.get::<_, i64>(2)?, "text": r.get::<_, String>(3)?,
                    "has_image": r.get::<_, i64>(4)? != 0, "bg": r.get::<_, String>(5)?, "seen": r.get::<_, i64>(6)? != 0,
                    "views": r.get::<_, i64>(7)?,
                }))
            })?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }
    pub fn story_image(&self, id: &[u8]) -> Option<Vec<u8>> {
        self.conn.lock().query_row("SELECT image FROM stories WHERE id=?1", params![id], |r| r.get(0)).optional().ok().flatten().flatten()
    }
    pub fn story_author(&self, id: &[u8]) -> Option<PeerId> {
        let v: Option<Vec<u8>> = self.conn.lock().query_row("SELECT author FROM stories WHERE id=?1", params![id], |r| r.get(0)).optional().ok().flatten();
        v.and_then(|v| v.try_into().ok()).map(PeerId)
    }
    pub fn story_mark_seen(&self, id: &[u8]) -> Result<()> {
        self.conn.lock().execute("UPDATE stories SET seen=1 WHERE id=?1", params![id])?;
        Ok(())
    }
    pub fn story_view(&self, id: &[u8], viewer: &PeerId) -> Result<()> {
        self.conn.lock().execute(
            "INSERT OR IGNORE INTO story_views(id,viewer,at) VALUES(?1,?2,?3)",
            params![id, &viewer.0[..], crate::util::now_ms() as i64],
        )?;
        Ok(())
    }
    pub fn story_viewers(&self, id: &[u8]) -> Vec<String> {
        let c = self.conn.lock();
        let Ok(mut st) = c.prepare_cached("SELECT viewer FROM story_views WHERE id=?1 ORDER BY at") else { return vec![] };
        st.query_map(params![id], |r| r.get::<_, Vec<u8>>(0)).map(|it| it.filter_map(|r| r.ok()).map(|v| b32(&v)).collect()).unwrap_or_default()
    }
    /// Group moderation: soft-delete every message of `author` in the given conversations.
    pub fn purge_author(&self, convs: &[String], author: &PeerId) -> Result<Vec<(String, Vec<u8>)>> {
        let c = self.conn.lock();
        let mut out = vec![];
        for conv in convs {
            let mut st = c.prepare_cached("SELECT id FROM messages WHERE conv=?1 AND author=?2 AND deleted=0")?;
            let ids: Vec<Vec<u8>> = st.query_map(params![conv, &author.0[..]], |r| r.get(0))?.filter_map(|r| r.ok()).collect();
            c.execute("UPDATE messages SET deleted=1, body='{}' WHERE conv=?1 AND author=?2", params![conv, &author.0[..]])?;
            for i in &ids {
                self.bump_if(&c, 1, i);
                Self::group_log_forget_on(&c, i)?;
            }
            out.extend(ids.into_iter().map(|i| (conv.clone(), i)));
        }
        Ok(out)
    }
    // ---------- group read markers ("seen by") ----------
    pub fn group_read_set(&self, conv: &str, peer: &PeerId, upto: i64) -> Result<()> {
        self.conn.lock().execute(
            "INSERT INTO group_reads(conv,peer,upto) VALUES(?1,?2,?3) ON CONFLICT(conv,peer) DO UPDATE SET upto=MAX(upto, excluded.upto)",
            params![conv, &peer.0[..], upto],
        )?;
        Ok(())
    }
    pub fn group_seen_by(&self, conv: &str, hlc: i64) -> Vec<String> {
        let c = self.conn.lock();
        let Ok(mut st) = c.prepare_cached("SELECT peer FROM group_reads WHERE conv=?1 AND upto>=?2") else { return vec![] };
        st.query_map(params![conv, hlc], |r| r.get::<_, Vec<u8>>(0)).map(|it| it.filter_map(|r| r.ok()).map(|v| b32(&v)).collect()).unwrap_or_default()
    }
    /// The latest message `author` wrote in any of `convs` before `before_hlc` (slow mode
    /// judges a message against the author's previous one by creation time, not arrival).
    pub fn prev_hlc_by(&self, convs: &[String], author: &PeerId, before_hlc: u64) -> Option<i64> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached("SELECT MAX(hlc) FROM messages WHERE conv=?1 AND author=?2 AND hlc<?3").ok()?;
        convs
            .iter()
            .filter_map(|conv| {
                st.query_row(params![conv, &author.0[..], before_hlc.min(i64::MAX as u64) as i64], |r| r.get::<_, Option<i64>>(0)).ok().flatten()
            })
            .max()
    }
    /// The conversations of a group: `g:<gid>` and its channels `g:<gid>#…` (index range).
    pub fn group_convs(&self, base: &str) -> Vec<String> {
        let c = self.conn.lock();
        let Ok(mut st) = c.prepare_cached("SELECT id FROM convs WHERE id=?1 OR (id>=?2 AND id<?3)") else { return vec![base.to_string()] };
        let mut v: Vec<String> = st
            .query_map(params![base, format!("{base}#"), format!("{base}$")], |r| r.get(0))
            .map(|it| it.filter_map(|r| r.ok()).collect())
            .unwrap_or_default();
        if !v.iter().any(|x| x == base) {
            v.insert(0, base.to_string());
        }
        v
    }

    // ---------- stickers (content-addressed, deduplicated) ----------
    pub fn sticker_blob_put(&self, hash: &[u8; 32], mime: &str, data: &[u8]) -> Result<()> {
        self.conn.lock().execute(
            "INSERT INTO sticker_blobs(hash,mime,data,used) VALUES(?1,?2,?3,?4) ON CONFLICT(hash) DO UPDATE SET used=excluded.used",
            params![&hash[..], mime, data, crate::util::now_ms() as i64],
        )?;
        Ok(())
    }
    /// A sticker's bytes; reading it counts as a use (LRU order, at most one write an hour).
    pub fn sticker_blob(&self, hash: &[u8]) -> Option<(String, Vec<u8>)> {
        let c = self.conn.lock();
        let now = crate::util::now_ms() as i64;
        let _ = c.execute("UPDATE sticker_blobs SET used=?2 WHERE hash=?1 AND used < ?2 - 3600000", params![hash, now]);
        c.query_row("SELECT mime,data FROM sticker_blobs WHERE hash=?1", params![hash], |r| Ok((r.get(0)?, r.get(1)?))).optional().ok().flatten()
    }
    pub fn sticker_blob_has(&self, hash: &[u8]) -> bool {
        self.conn.lock().query_row("SELECT 1 FROM sticker_blobs WHERE hash=?1", params![hash], |_| Ok(())).optional().ok().flatten().is_some()
    }
    /// LRU bound for received stickers: keep the most recently used ones up to `max_bytes`,
    /// evict the rest. Stickers in one of my packs are never evicted (nor counted).
    pub fn sticker_cache_enforce(&self, max_bytes: u64) -> Result<usize> {
        let c = self.conn.lock();
        Self::sticker_cache_enforce_on(&c, max_bytes)
    }
    fn sticker_cache_enforce_on(c: &Connection, max_bytes: u64) -> Result<usize> {
        Ok(c.execute(
            "DELETE FROM sticker_blobs WHERE hash IN (
               SELECT hash FROM (SELECT hash, SUM(length(data)) OVER (ORDER BY used DESC, hash ROWS UNBOUNDED PRECEDING) AS cum
                                 FROM sticker_blobs WHERE hash NOT IN (SELECT hash FROM stickers))
               WHERE cum > ?1)",
            params![max_bytes.min(i64::MAX as u64) as i64],
        )?)
    }
    /// Received stickers not in any pack and unused for 60 days are dropped (bounded cache).
    pub fn sticker_cache_trim(&self) -> Result<usize> {
        let cut = crate::util::now_ms() as i64 - 60 * 86_400_000;
        Ok(self.conn.lock().execute(
            "DELETE FROM sticker_blobs WHERE used < ?1 AND hash NOT IN (SELECT hash FROM stickers)",
            params![cut],
        )?)
    }
    pub fn sticker_pack_create(&self, id: &str, name: &str) -> Result<()> {
        self.conn.lock().execute(
            "INSERT OR REPLACE INTO sticker_packs(id,name,created) VALUES(?1,?2,?3)",
            params![id, name, crate::util::now_ms() as i64],
        )?;
        Ok(())
    }
    pub fn sticker_pack_delete(&self, id: &str) -> Result<()> {
        let c = self.conn.lock();
        c.execute("DELETE FROM stickers WHERE pack=?1", params![id])?;
        c.execute("DELETE FROM sticker_packs WHERE id=?1", params![id])?;
        Ok(())
    }
    pub fn sticker_add(&self, hash: &[u8; 32], pack: &str, mime: &str, emoji: &str, animated: bool) -> Result<()> {
        let c = self.conn.lock();
        let n: i64 = c.query_row("SELECT count(*) FROM stickers WHERE pack=?1", params![pack], |r| r.get(0))?;
        anyhow::ensure!(n < 120, crate::i18n::user_err("err.pack_full").with("max", 120));
        c.execute(
            "INSERT OR IGNORE INTO stickers(hash,pack,mime,emoji,animated,created) VALUES(?1,?2,?3,?4,?5,?6)",
            params![&hash[..], pack, mime, emoji, animated as i64, crate::util::now_ms() as i64],
        )?;
        Ok(())
    }
    pub fn sticker_remove(&self, hash: &[u8], pack: &str) -> Result<()> {
        self.conn.lock().execute("DELETE FROM stickers WHERE hash=?1 AND pack=?2", params![hash, pack])?;
        Ok(())
    }
    pub fn sticker_packs(&self) -> Result<Vec<Value>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached("SELECT id,name,created FROM sticker_packs ORDER BY sort, created")?;
        let packs: Vec<(String, String, i64)> = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.filter_map(|r| r.ok()).collect();
        let mut out = vec![];
        for (id, name, created) in packs {
            let mut st2 = c.prepare_cached("SELECT hash,mime,emoji,animated FROM stickers WHERE pack=?1 ORDER BY created")?;
            let items: Vec<Value> = st2
                .query_map(params![id], |r| {
                    let h: Vec<u8> = r.get(0)?;
                    Ok(serde_json::json!({"hash": hex::encode(h), "mime": r.get::<_, String>(1)?, "emoji": r.get::<_, String>(2)?, "animated": r.get::<_, i64>(3)? != 0}))
                })?
                .filter_map(|r| r.ok())
                .collect();
            out.push(serde_json::json!({"id": id, "name": name, "created": created, "stickers": items}));
        }
        Ok(out)
    }

    /// Remove a message row entirely ("delete for me").
    pub fn purge_message(&self, id: &[u8]) -> Result<bool> {
        let c = self.conn.lock();
        let n = c.execute("DELETE FROM messages WHERE id=?1", params![id])?;
        if n > 0 {
            self.track(&c, sync::K_PURGE, id);
            Self::group_log_forget_on(&c, id)?;
        }
        Ok(n > 0)
    }
    /// Remove all messages of a conversation up to `upto_hlc` (inclusive).
    pub fn clear_conv(&self, conv: &str, upto_hlc: i64) -> Result<usize> {
        let c = self.conn.lock();
        let n = c.execute("DELETE FROM messages WHERE conv=?1 AND hlc<=?2", params![conv, upto_hlc])?;
        if n > 0 {
            Self::group_log_purge_gone_on(&c)?;
        }
        c.execute("UPDATE convs SET last_text='', unread=0 WHERE id=?1", params![conv])?;
        if c.execute("UPDATE convs SET cleared_upto=?2 WHERE id=?1 AND cleared_upto<?2", params![conv, upto_hlc])? > 0 {
            self.track(&c, sync::K_CONV, conv.as_bytes());
        }
        Ok(n)
    }
    pub fn set_message_meta(&self, id: &[u8], meta: &Value) -> Result<()> {
        let c = self.conn.lock();
        let n = c.execute("UPDATE messages SET meta=?2 WHERE id=?1", params![id, meta.to_string()])?;
        self.bump_if(&c, n, id);
        Ok(())
    }
    pub fn set_pinned(&self, id: &[u8], on: bool) -> Result<bool> {
        let c = self.conn.lock();
        let n = c.execute("UPDATE messages SET pinned=?2 WHERE id=?1 AND deleted=0", params![id, on as i64])?;
        self.bump_if(&c, n, id);
        Ok(n > 0)
    }
    pub fn pinned(&self, conv: &str) -> Result<Vec<StoredMessage>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached(
            "SELECT id,conv,author,hlc,kind,body,status,edited,deleted,reply_to,reactions,expires,pinned,meta FROM messages WHERE conv=?1 AND pinned=1 ORDER BY hlc DESC LIMIT 50",
        )?;
        let rows = st.query_map(params![conv], Self::row_msg)?.filter_map(|r| r.ok()).collect();
        Ok(rows)
    }
    /// Message state kept inside the reactions JSON under a "__" key (checklist ticks, reminder
    /// seen/cancelled). `f` edits the map and returns whether anything changed; returns the new
    /// reactions JSON, or Null when the message (of `kind`) is missing or nothing changed.
    pub fn patch_state(&self, id: &[u8], kind: &str, f: impl FnOnce(&mut serde_json::Map<String, Value>) -> bool) -> Result<Value> {
        let c = self.conn.lock();
        let cur: Option<String> =
            c.query_row("SELECT reactions FROM messages WHERE id=?1 AND kind=?2 AND deleted=0", params![id, kind], |r| r.get(0)).optional()?;
        let Some(cur) = cur else { return Ok(Value::Null) };
        let mut v: serde_json::Map<String, Value> = serde_json::from_str(&cur).unwrap_or_default();
        if !f(&mut v) {
            return Ok(Value::Null);
        }
        let out = Value::Object(v);
        c.execute("UPDATE messages SET reactions=?2 WHERE id=?1", params![id, out.to_string()])?;
        self.bump_if(&c, 1, id);
        Ok(out)
    }
    /// Single-choice poll vote stored inside the reactions JSON under "__votes".
    pub fn vote(&self, id: &[u8], who: &PeerId, option: u32) -> Result<Value> {
        let c = self.conn.lock();
        let cur: Option<(String, String)> =
            c.query_row("SELECT reactions, body FROM messages WHERE id=?1 AND kind='poll' AND deleted=0", params![id], |r| Ok((r.get(0)?, r.get(1)?))).optional()?;
        let Some((cur, body)) = cur else { return Ok(Value::Null) };
        // only an existing option (a forged index would grow the state without bound)
        let options = serde_json::from_str::<Value>(&body).ok().and_then(|b| b["options"].as_array().map(|a| a.len())).unwrap_or(0);
        if option as usize >= options {
            return Ok(Value::Null);
        }
        let mut v: serde_json::Map<String, Value> = serde_json::from_str(&cur).unwrap_or_default();
        let votes = v.entry("__votes".to_string()).or_insert_with(|| Value::Object(Default::default()));
        if let Value::Object(m) = votes {
            m.insert(b32(&who.0), Value::from(option));
        }
        let out = Value::Object(v);
        c.execute("UPDATE messages SET reactions=?2 WHERE id=?1", params![id, out.to_string()])?;
        self.bump_if(&c, 1, id);
        Ok(out)
    }
    pub fn set_message_status(&self, id: &[u8], status: i64) -> Result<()> {
        // statuses only move forward (sent → delivered → read)
        let c = self.conn.lock();
        if c.execute("UPDATE messages SET status=?2 WHERE id=?1 AND status<>9 AND status<?2", params![id, status])? > 0 {
            self.track(&c, sync::K_MSG, id);
        }
        Ok(())
    }
    pub fn mark_conv_read_upto(&self, conv: &str, author_not: &PeerId, hlc: i64) -> Result<Vec<Vec<u8>>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached("SELECT id FROM messages WHERE conv=?1 AND author<>?2 AND hlc<=?3 AND status<3")?;
        let ids: Vec<Vec<u8>> =
            st.query_map(params![conv, &author_not.0[..], hlc], |r| r.get(0))?.filter_map(|r| r.ok()).collect();
        c.execute("UPDATE messages SET status=3 WHERE conv=?1 AND author<>?2 AND hlc<=?3", params![conv, &author_not.0[..], hlc])?;
        Ok(ids)
    }
    /// Mark *our* messages in `conv` up to `hlc` as read by the other side; returns changed ids.
    pub fn conn_mark_mine_read(&self, conv: &str, me: &PeerId, hlc: i64) -> Result<Vec<Vec<u8>>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached("SELECT id FROM messages WHERE conv=?1 AND author=?2 AND hlc<=?3 AND status<3 AND status<>9")?;
        let ids: Vec<Vec<u8>> = st.query_map(params![conv, &me.0[..], hlc], |r| r.get(0))?.filter_map(|r| r.ok()).collect();
        c.execute("UPDATE messages SET status=3 WHERE conv=?1 AND author=?2 AND hlc<=?3 AND status<>9", params![conv, &me.0[..], hlc])?;
        for i in &ids {
            self.track(&c, sync::K_MSG, i);
        }
        Ok(ids)
    }
    pub fn edit_message(&self, id: &[u8], author: &PeerId, body: &Value) -> Result<bool> {
        let c = self.conn.lock();
        let n = c.execute(
            "UPDATE messages SET body=?3, edited=1 WHERE id=?1 AND author=?2 AND deleted=0 AND kind='text'",
            params![id, &author.0[..], body.to_string()],
        )?;
        self.bump_if(&c, n, id);
        Ok(n > 0)
    }
    pub fn delete_message(&self, id: &[u8], author: Option<&PeerId>) -> Result<bool> {
        let c = self.conn.lock();
        let n = match author {
            Some(a) => c.execute(
                "UPDATE messages SET deleted=1, body='{}' WHERE id=?1 AND author=?2",
                params![id, &a.0[..]],
            )?,
            None => c.execute("UPDATE messages SET deleted=1, body='{}' WHERE id=?1", params![id])?,
        };
        self.bump_if(&c, n, id);
        if n > 0 {
            Self::group_log_forget_on(&c, id)?;
        }
        Ok(n > 0)
    }
    pub fn react(&self, id: &[u8], who: &PeerId, emoji: &str, on: bool) -> Result<Value> {
        let c = self.conn.lock();
        let cur: Option<String> =
            c.query_row("SELECT reactions FROM messages WHERE id=?1", params![id], |r| r.get(0)).optional()?;
        let Some(cur) = cur else { return Ok(Value::Null) };
        let mut v: serde_json::Map<String, Value> = serde_json::from_str(&cur).unwrap_or_default();
        let who_s = b32(&who.0);
        let entry = v.entry(emoji.to_string()).or_insert_with(|| Value::Array(vec![]));
        if let Value::Array(arr) = entry {
            arr.retain(|x| x.as_str() != Some(&who_s));
            if on {
                arr.push(Value::String(who_s));
            }
        }
        // keep message state ("__votes", "__checks", …) next to the emoji reactions
        v.retain(|k, x| k.starts_with("__") || x.as_array().map(|a| !a.is_empty()).unwrap_or(false));
        let out = Value::Object(v);
        c.execute("UPDATE messages SET reactions=?2 WHERE id=?1", params![id, out.to_string()])?;
        self.bump_if(&c, 1, id);
        Ok(out)
    }

    // ---------- outbox / mailbox ----------
    pub fn outbox_add(&self, id: &[u8], to: &PeerId, payload: &[u8]) -> Result<()> {
        self.conn.lock().execute(
            "INSERT OR REPLACE INTO outbox(id,to_peer,payload,created) VALUES(?1,?2,?3,?4)",
            params![id, &to.0[..], payload, crate::util::now_ms() as i64],
        )?;
        Ok(())
    }
    pub fn outbox_for(&self, to: &PeerId) -> Result<Vec<(Vec<u8>, Vec<u8>)>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached("SELECT id,payload FROM outbox WHERE to_peer=?1 ORDER BY created LIMIT 500")?;
        let rows = st.query_map(params![&to.0[..]], |r| Ok((r.get(0)?, r.get(1)?)))?.filter_map(|r| r.ok()).collect();
        Ok(rows)
    }
    /// Outbox items for one device in queue order, after `after_rowid` (paging cursor):
    /// `(rowid, id, payload)`.
    pub fn outbox_page(&self, to: &PeerId, after_rowid: i64, limit: i64) -> Result<Vec<OutboxRow>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached("SELECT rowid,id,payload FROM outbox WHERE to_peer=?1 AND rowid>?2 ORDER BY rowid LIMIT ?3")?;
        let rows = st.query_map(params![&to.0[..], after_rowid, limit], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.filter_map(|r| r.ok()).collect();
        Ok(rows)
    }
    pub fn outbox_peers(&self) -> Result<Vec<PeerId>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached("SELECT DISTINCT to_peer FROM outbox")?;
        let rows = st
            .query_map([], |r| r.get::<_, Vec<u8>>(0))?
            .filter_map(|r| r.ok())
            .filter_map(|v| v.try_into().ok().map(PeerId))
            .collect();
        Ok(rows)
    }
    pub fn outbox_remove(&self, id: &[u8], to: &PeerId) -> Result<()> {
        self.conn.lock().execute("DELETE FROM outbox WHERE id=?1 AND to_peer=?2", params![id, &to.0[..]])?;
        Ok(())
    }
    pub fn mailbox_put(&self, id: &[u8], for_peer: &PeerId, payload: &[u8]) -> Result<()> {
        let c = self.conn.lock();
        // cap per recipient to keep storage bounded
        let (cnt, bytes): (i64, i64) = c.query_row(
            "SELECT count(*), COALESCE(sum(length(payload)),0) FROM mailbox WHERE for_peer=?1",
            params![&for_peer.0[..]],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        if cnt >= 2000 || payload.len() > 64 * 1024 || bytes as usize + payload.len() > MAILBOX_MAX_PER_PEER {
            return Ok(());
        }
        // …and overall: mail we hold for friends must not fill this device's disk
        let total: i64 = c.query_row("SELECT COALESCE(sum(length(payload)),0) FROM mailbox", [], |r| r.get(0))?;
        if total as usize + payload.len() > MAILBOX_MAX_TOTAL {
            return Ok(());
        }
        c.execute(
            "INSERT OR IGNORE INTO mailbox(id,for_peer,payload,created) VALUES(?1,?2,?3,?4)",
            params![id, &for_peer.0[..], payload, crate::util::now_ms() as i64],
        )?;
        Ok(())
    }
    pub fn mailbox_take(&self, for_peer: &PeerId) -> Result<Vec<Vec<u8>>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached("SELECT payload FROM mailbox WHERE for_peer=?1 ORDER BY created")?;
        let rows: Vec<Vec<u8>> = st.query_map(params![&for_peer.0[..]], |r| r.get(0))?.filter_map(|r| r.ok()).collect();
        c.execute("DELETE FROM mailbox WHERE for_peer=?1", params![&for_peer.0[..]])?;
        Ok(rows)
    }

    // ---------- groups ----------
    pub fn group_save(&self, gid: &[u8], state: &[u8]) -> Result<()> {
        self.conn.lock().execute(
            "INSERT INTO groups(id,state,updated) VALUES(?1,?2,?3) ON CONFLICT(id) DO UPDATE SET state=excluded.state, updated=excluded.updated",
            params![gid, state, crate::util::now_ms() as i64],
        )?;
        Ok(())
    }
    pub fn group_load(&self, gid: &[u8]) -> Option<Vec<u8>> {
        self.conn.lock().query_row("SELECT state FROM groups WHERE id=?1", params![gid], |r| r.get(0)).optional().ok().flatten()
    }
    pub fn group_all(&self) -> Vec<Vec<u8>> {
        let c = self.conn.lock();
        let Ok(mut st) = c.prepare_cached("SELECT state FROM groups") else { return vec![] };
        st.query_map([], |r| r.get(0)).map(|it| it.filter_map(|r| r.ok()).collect()).unwrap_or_default()
    }
    pub fn group_delete(&self, gid: &[u8]) -> Result<()> {
        let c = self.conn.lock();
        c.execute("DELETE FROM groups WHERE id=?1", params![gid])?;
        c.execute("DELETE FROM group_keys WHERE gid=?1", params![gid])?;
        c.execute("DELETE FROM group_log WHERE gid=?1", params![gid])?;
        c.execute("DELETE FROM group_held WHERE gid=?1", params![gid])?;
        Ok(())
    }
    /// Set the key of `epoch` (the caller validated it: the epoch-0 key, or the one
    /// matching the winning Rekey commitment). A different key held before is kept as an
    /// alternative (it may still open what was sent under it).
    pub fn group_key_put(&self, gid: &[u8], epoch: u64, key: &[u8; 32]) -> Result<()> {
        let c = self.conn.lock();
        c.execute("INSERT OR IGNORE INTO group_key_alts(gid,epoch,key) VALUES(?1,?2,?3)", params![gid, epoch as i64, &key[..]])?;
        let old: Option<Vec<u8>> = c.query_row("SELECT key FROM group_keys WHERE gid=?1 AND epoch=?2", params![gid, epoch as i64], |r| r.get(0)).optional()?;
        if old.as_deref() == Some(&key[..]) {
            return Ok(());
        }
        if let Some(o) = old {
            c.execute("INSERT OR IGNORE INTO group_key_alts(gid,epoch,key) VALUES(?1,?2,?3)", params![gid, epoch as i64, o])?;
        }
        c.execute("INSERT OR REPLACE INTO group_keys(gid,epoch,key) VALUES(?1,?2,?3)", params![gid, epoch as i64, &key[..]])?;
        let mut k = gid.to_vec();
        k.extend_from_slice(&epoch.to_le_bytes());
        self.track(&c, sync::K_GKEY, &k);
        Ok(())
    }
    /// Remember a key for `epoch` that is not (or not yet known to be) the winning one.
    pub fn group_key_add_alt(&self, gid: &[u8], epoch: u64, key: &[u8; 32]) -> Result<()> {
        self.conn.lock().execute("INSERT OR IGNORE INTO group_key_alts(gid,epoch,key) VALUES(?1,?2,?3)", params![gid, epoch as i64, &key[..]])?;
        Ok(())
    }
    /// The key held for `epoch` turned out not to match the winning commitment: stop
    /// sending with it (it stays as an alternative for reading).
    pub fn group_key_demote(&self, gid: &[u8], epoch: u64) -> Result<()> {
        let c = self.conn.lock();
        c.execute(
            "INSERT OR IGNORE INTO group_key_alts(gid,epoch,key) SELECT gid,epoch,key FROM group_keys WHERE gid=?1 AND epoch=?2",
            params![gid, epoch as i64],
        )?;
        c.execute("DELETE FROM group_keys WHERE gid=?1 AND epoch=?2", params![gid, epoch as i64])?;
        Ok(())
    }
    /// Every key we hold for `epoch`: the current one first, then alternatives.
    pub fn group_keys_all(&self, gid: &[u8], epoch: u64) -> Vec<[u8; 32]> {
        let c = self.conn.lock();
        let mut out: Vec<[u8; 32]> = vec![];
        let main: Option<Vec<u8>> = c.query_row("SELECT key FROM group_keys WHERE gid=?1 AND epoch=?2", params![gid, epoch as i64], |r| r.get(0)).optional().ok().flatten();
        out.extend(main.and_then(|k| <[u8; 32]>::try_from(k.as_slice()).ok()));
        if let Ok(mut st) = c.prepare_cached("SELECT key FROM group_key_alts WHERE gid=?1 AND epoch=?2") {
            if let Ok(it) = st.query_map(params![gid, epoch as i64], |r| r.get::<_, Vec<u8>>(0)) {
                for k in it.filter_map(|r| r.ok()).filter_map(|k| <[u8; 32]>::try_from(k.as_slice()).ok()) {
                    if !out.contains(&k) {
                        out.push(k);
                    }
                }
            }
        }
        out
    }
    /// A key that arrived before the Rekey it belongs to (bounded per sender and group, so
    /// junk from one member can't push out the real key). False: no room, don't ack it.
    pub fn group_key_pending_put(&self, gid: &[u8], epoch: u64, sender: &PeerId, key: &[u8; 32]) -> Result<bool> {
        let c = self.conn.lock();
        let exists = c
            .query_row("SELECT 1 FROM group_key_pending WHERE gid=?1 AND epoch=?2 AND key=?3", params![gid, epoch as i64, &key[..]], |_| Ok(()))
            .optional()?
            .is_some();
        if exists {
            return Ok(true);
        }
        let per_sender: i64 = c.query_row(
            "SELECT count(*) FROM group_key_pending WHERE gid=?1 AND sender=?2",
            params![gid, &sender.0[..]],
            |r| r.get(0),
        )?;
        let total: i64 = c.query_row("SELECT count(*) FROM group_key_pending WHERE gid=?1", params![gid], |r| r.get(0))?;
        if per_sender >= 16 || total >= 256 {
            return Ok(false);
        }
        c.execute(
            "INSERT OR IGNORE INTO group_key_pending(gid,epoch,sender,key,at) VALUES(?1,?2,?3,?4,?5)",
            params![gid, epoch as i64, &sender.0[..], &key[..], crate::util::now_ms() as i64],
        )?;
        Ok(true)
    }
    pub fn group_key_pending_all(&self, gid: &[u8]) -> Vec<(u64, [u8; 32])> {
        let c = self.conn.lock();
        let Ok(mut st) = c.prepare_cached("SELECT epoch, key FROM group_key_pending WHERE gid=?1") else { return vec![] };
        st.query_map(params![gid], |r| Ok((r.get::<_, i64>(0)? as u64, r.get::<_, Vec<u8>>(1)?)))
            .map(|it| it.filter_map(|r| r.ok()).filter_map(|(e, k)| k.try_into().ok().map(|k| (e, k))).collect())
            .unwrap_or_default()
    }
    pub fn group_key_pending_del(&self, gid: &[u8], epoch: u64, key: &[u8; 32]) -> Result<()> {
        self.conn.lock().execute("DELETE FROM group_key_pending WHERE gid=?1 AND epoch=?2 AND key=?3", params![gid, epoch as i64, &key[..]])?;
        Ok(())
    }
    /// What a send with this `client_id` returned (≤ 24 h ago), if any.
    pub fn send_client_get(&self, cid: &str) -> Option<Value> {
        let s: Option<String> = self
            .conn
            .lock()
            .query_row("SELECT resp FROM send_client_ids WHERE cid=?1 AND created>=?2", params![cid, crate::util::now_ms() as i64 - 86_400_000], |r| r.get(0))
            .optional()
            .ok()
            .flatten();
        s.and_then(|s| serde_json::from_str(&s).ok())
    }
    pub fn send_client_put(&self, cid: &str, resp: &Value) -> Result<()> {
        self.conn.lock().execute(
            "INSERT OR REPLACE INTO send_client_ids(cid,resp,created) VALUES(?1,?2,?3)",
            params![cid, resp.to_string(), crate::util::now_ms() as i64],
        )?;
        Ok(())
    }
    /// Verified ops of group `gid` that its fold rejected (msgpack `Vec<Signed>`).
    pub fn group_held_get(&self, gid: &[u8]) -> Vec<crate::group::Signed> {
        let b: Option<Vec<u8>> = self.conn.lock().query_row("SELECT ops FROM group_held WHERE gid=?1", params![gid], |r| r.get(0)).optional().ok().flatten();
        b.and_then(|b| rmp_serde::from_slice(&b).ok()).unwrap_or_default()
    }
    pub fn group_held_set(&self, gid: &[u8], ops: &[crate::group::Signed]) -> Result<()> {
        let c = self.conn.lock();
        if ops.is_empty() {
            c.execute("DELETE FROM group_held WHERE gid=?1", params![gid])?;
        } else {
            c.execute("INSERT OR REPLACE INTO group_held(gid,ops) VALUES(?1,?2)", params![gid, rmp_serde::to_vec(ops)?])?;
        }
        Ok(())
    }
    /// An envelope we can't open yet, kept until its key arrives (bounded per group).
    pub fn group_env_pending_put(&self, gid: &[u8], epoch: u64, env: &[u8]) -> Result<bool> {
        let c = self.conn.lock();
        let dup = c
            .query_row("SELECT 1 FROM group_env_pending WHERE gid=?1 AND env=?2", params![gid, env], |_| Ok(()))
            .optional()?
            .is_some();
        if dup {
            return Ok(false);
        }
        let (n, bytes): (i64, i64) =
            c.query_row("SELECT count(*), COALESCE(SUM(length(env)),0) FROM group_env_pending WHERE gid=?1", params![gid], |r| Ok((r.get(0)?, r.get(1)?)))?;
        if n >= 2000 || bytes as usize + env.len() > 16 * 1024 * 1024 {
            return Ok(false);
        }
        c.execute(
            "INSERT INTO group_env_pending(gid,epoch,env,at) VALUES(?1,?2,?3,?4)",
            params![gid, epoch as i64, env, crate::util::now_ms() as i64],
        )?;
        Ok(true)
    }
    pub fn group_env_pending_take(&self, gid: &[u8]) -> Vec<Vec<u8>> {
        let c = self.conn.lock();
        let rows: Vec<Vec<u8>> = c
            .prepare_cached("SELECT env FROM group_env_pending WHERE gid=?1 ORDER BY id")
            .and_then(|mut st| st.query_map(params![gid], |r| r.get(0)).map(|it| it.filter_map(|r| r.ok()).collect()))
            .unwrap_or_default();
        let _ = c.execute("DELETE FROM group_env_pending WHERE gid=?1", params![gid]);
        rows
    }
    pub fn group_env_pending_count(&self, gid: &[u8]) -> i64 {
        self.conn.lock().query_row("SELECT count(*) FROM group_env_pending WHERE gid=?1", params![gid], |r| r.get(0)).unwrap_or(0)
    }
    pub fn group_key_get(&self, gid: &[u8], epoch: u64) -> Option<[u8; 32]> {
        let v: Option<Vec<u8>> = self
            .conn
            .lock()
            .query_row("SELECT key FROM group_keys WHERE gid=?1 AND epoch=?2", params![gid, epoch as i64], |r| r.get(0))
            .optional()
            .ok()
            .flatten();
        v.and_then(|v| v.try_into().ok())
    }
    /// Signed+encrypted group envelopes kept for anti-entropy sync (bounded per group).
    pub fn group_log_put(&self, id: &[u8], gid: &[u8], author: &PeerId, hlc: u64, env: &[u8]) -> Result<bool> {
        self.group_log_put_ex(id, gid, author, hlc, env, 0, None)
    }
    /// `k`: 1 op, 2 message, 3 action (0 unknown); `msg_id`: the message it carries or acts on.
    #[allow(clippy::too_many_arguments)]
    pub fn group_log_put_ex(&self, id: &[u8], gid: &[u8], author: &PeerId, hlc: u64, env: &[u8], k: u8, msg_id: Option<&[u8]>) -> Result<bool> {
        let c = self.conn.lock();
        let n = c.execute(
            "INSERT OR IGNORE INTO group_log(id,gid,author,hlc,env,rcv,k,msg_id) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
            params![id, gid, &author.0[..], hlc.min(i64::MAX as u64) as i64, env, crate::util::now_ms() as i64, k as i64, msg_id],
        )?;
        Ok(n > 0)
    }
    /// A message went away (deleted, purged, cleared, expired): blank its envelope and the
    /// actions on it (edits carry the text). The row stays as a tombstone so the envelope is
    /// neither re-served to anyone nor taken again from a peer.
    fn group_log_forget_on(c: &Connection, msg_id: &[u8]) -> Result<usize> {
        Ok(c.execute("UPDATE group_log SET env=x'' WHERE msg_id=?1 AND length(env)>0", params![msg_id])?)
    }
    /// Blank the envelopes of messages that no longer exist here (see `group_log_forget_on`).
    fn group_log_purge_gone_on(c: &Connection) -> Result<usize> {
        Ok(c.execute(
            "UPDATE group_log SET env=x'' WHERE k IN (2,3) AND msg_id IS NOT NULL AND length(env)>0
             AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.id=group_log.msg_id)",
            [],
        )?)
    }
    pub fn group_log_forget(&self, msg_id: &[u8]) -> Result<usize> {
        Self::group_log_forget_on(&self.conn.lock(), msg_id)
    }
    /// Admin cleared the group history: blank all content envelopes up to `upto`.
    pub fn group_log_clear(&self, gid: &[u8], upto: u64) -> Result<usize> {
        Ok(self.conn.lock().execute(
            "UPDATE group_log SET env=x'' WHERE gid=?1 AND k IN (2,3) AND hlc<=?2 AND length(env)>0",
            params![gid, upto.min(i64::MAX as u64) as i64],
        )?)
    }
    /// Envelopes of `author` after `after` (anti-entropy). Content dated before
    /// `content_from` (the requester joined later, or history was cleared/expired) is not
    /// served; blanked tombstones never are.
    pub fn group_log_since_for(&self, gid: &[u8], author: &PeerId, after: u64, content_from: u64, limit: i64) -> Vec<Vec<u8>> {
        let c = self.conn.lock();
        let Ok(mut st) = c.prepare_cached(
            "SELECT env FROM group_log WHERE gid=?1 AND author=?2 AND hlc>?3 AND length(env)>0 AND (k IN (0,1) OR hlc>=?4) ORDER BY hlc LIMIT ?5",
        ) else {
            return vec![];
        };
        st.query_map(params![gid, &author.0[..], after.min(i64::MAX as u64) as i64, content_from.min(i64::MAX as u64) as i64, limit], |r| r.get(0))
            .map(|it| it.filter_map(|r| r.ok()).collect())
            .unwrap_or_default()
    }
    /// Anti-flood by *arrival* time: (bytes from `signer`, bytes from everyone) received
    /// for group `gid` since `since_ms` — backdated content can't multiply the daily quotas.
    pub fn group_log_rcv_bytes(&self, gid: &[u8], signer: &PeerId, since_ms: u64) -> (u64, u64) {
        let c = self.conn.lock();
        c.query_row(
            "SELECT COALESCE(SUM(CASE WHEN author=?2 THEN length(env) ELSE 0 END),0), COALESCE(SUM(length(env)),0) FROM group_log WHERE gid=?1 AND rcv>?3",
            params![gid, &signer.0[..], since_ms.min(i64::MAX as u64) as i64],
            |r| Ok((r.get::<_, i64>(0)? as u64, r.get::<_, i64>(1)? as u64)),
        )
        .unwrap_or((0, 0))
    }
    pub fn group_log_heads(&self, gid: &[u8]) -> Vec<(PeerId, u64)> {
        let c = self.conn.lock();
        let Ok(mut st) = c.prepare_cached("SELECT author, MAX(hlc) FROM group_log WHERE gid=?1 GROUP BY author") else {
            return vec![];
        };
        st.query_map(params![gid], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)?)))
            .map(|it| {
                it.filter_map(|r| r.ok())
                    .filter_map(|(a, h)| a.try_into().ok().map(|a| (PeerId(a), h as u64)))
                    .collect()
            })
            .unwrap_or_default()
    }
    pub fn group_log_since(&self, gid: &[u8], author: &PeerId, after: u64, limit: i64) -> Vec<Vec<u8>> {
        let c = self.conn.lock();
        let Ok(mut st) =
            c.prepare_cached("SELECT env FROM group_log WHERE gid=?1 AND author=?2 AND hlc>?3 AND length(env)>0 ORDER BY hlc LIMIT ?4")
        else {
            return vec![];
        };
        st.query_map(params![gid, &author.0[..], after as i64, limit], |r| r.get(0))
            .map(|it| it.filter_map(|r| r.ok()).collect())
            .unwrap_or_default()
    }
    pub fn group_log_authors(&self, gid: &[u8]) -> Vec<PeerId> {
        self.group_log_heads(gid).into_iter().map(|(a, _)| a).collect()
    }
    pub fn group_log_has(&self, id: &[u8]) -> bool {
        self.conn.lock().query_row("SELECT 1 FROM group_log WHERE id=?1", params![id], |_| Ok(())).optional().ok().flatten().is_some()
    }
    /// Anti-flood: (count, bytes) of envelopes `signer` created in group `gid` with
    /// `from < hlc <= to` (creation time, so a sync replay of old history counts where it
    /// was written, not when it arrived).
    pub fn group_log_window(&self, gid: &[u8], signer: &PeerId, from: u64, to: u64) -> (u64, u64) {
        let c = self.conn.lock();
        c.query_row(
            "SELECT COUNT(*), COALESCE(SUM(length(env)),0) FROM group_log WHERE gid=?1 AND author=?2 AND hlc>?3 AND hlc<=?4",
            params![gid, &signer.0[..], from.min(i64::MAX as u64) as i64, to.min(i64::MAX as u64) as i64],
            |r| Ok((r.get::<_, i64>(0)? as u64, r.get::<_, i64>(1)? as u64)),
        )
        .unwrap_or((0, 0))
    }
    /// Anti-flood: bytes of every author's envelopes in group `gid` with `from < hlc <= to`.
    pub fn group_log_bytes(&self, gid: &[u8], from: u64, to: u64) -> u64 {
        let c = self.conn.lock();
        c.query_row(
            "SELECT COALESCE(SUM(length(env)),0) FROM group_log WHERE gid=?1 AND hlc>?2 AND hlc<=?3",
            params![gid, from.min(i64::MAX as u64) as i64, to.min(i64::MAX as u64) as i64],
            |r| r.get::<_, i64>(0),
        )
        .unwrap_or(0) as u64
    }

    // ---------- files ----------
    pub fn file_put(&self, f: &FileRow) -> Result<()> {
        let id = hex::decode(&f.id)?;
        let peer = PeerId::from_str_any(&f.peer)?;
        let hash = hex::decode(&f.hash).unwrap_or_default();
        self.conn.lock().execute(
            "INSERT INTO files(id,conv,peer,name,size,hash,path,direction,state,progress,created) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
             ON CONFLICT(id) DO UPDATE SET path=excluded.path, state=excluded.state, progress=excluded.progress",
            params![id, f.conv, &peer.0[..], f.name, f.size, hash, f.path, f.direction, f.state, f.progress, f.created],
        )?;
        Ok(())
    }
    pub fn file_get(&self, id: &[u8]) -> Option<FileRow> {
        let c = self.conn.lock();
        c.query_row(
            "SELECT id,conv,peer,name,size,hash,path,direction,state,progress,created FROM files WHERE id=?1",
            params![id],
            Self::row_file,
        )
        .optional()
        .ok()
        .flatten()
    }
    fn row_file(r: &rusqlite::Row) -> rusqlite::Result<FileRow> {
        let id: Vec<u8> = r.get(0)?;
        let peer: Vec<u8> = r.get(2)?;
        let hash: Vec<u8> = r.get(5)?;
        Ok(FileRow {
            id: hex::encode(id),
            conv: r.get(1)?,
            peer: b32(&peer),
            name: r.get(3)?,
            size: r.get(4)?,
            hash: hex::encode(hash),
            path: r.get(6)?,
            direction: r.get(7)?,
            state: r.get(8)?,
            progress: r.get(9)?,
            created: r.get(10)?,
        })
    }
    pub fn files(&self, limit: i64) -> Result<Vec<FileRow>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached(
            "SELECT id,conv,peer,name,size,hash,path,direction,state,progress,created FROM files ORDER BY created DESC LIMIT ?1",
        )?;
        let rows = st.query_map(params![limit], Self::row_file)?.filter_map(|r| r.ok()).collect();
        Ok(rows)
    }
    /// Received, completed files, oldest first (for cache eviction).
    pub fn received_files(&self) -> Result<Vec<FileRow>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached(
            "SELECT id,conv,peer,name,size,hash,path,direction,state,progress,created FROM files WHERE direction=1 AND state=2 ORDER BY created ASC",
        )?;
        let rows = st.query_map([], Self::row_file)?.filter_map(|r| r.ok()).collect();
        Ok(rows)
    }
    /// Bodies of the file messages of `conv` that carry a preview (for `files`).
    pub fn file_preview_bodies(&self, conv: &str) -> Vec<Value> {
        let c = self.conn.lock();
        let Ok(mut st) = c.prepare_cached("SELECT body FROM messages WHERE conv=?1 AND kind='file' AND body LIKE '%\"preview\"%'") else {
            return vec![];
        };
        st.query_map(params![conv], |r| r.get::<_, String>(0))
            .map(|rows| rows.filter_map(|r| r.ok()).filter_map(|b| serde_json::from_str(&b).ok()).collect())
            .unwrap_or_default()
    }
    pub fn file_by_hash(&self, hash_hex: &str) -> Option<String> {
        let h = hex::decode(hash_hex).ok()?;
        self.conn
            .lock()
            .query_row("SELECT path FROM files WHERE hash=?1 AND state=2 AND path<>'' ORDER BY created DESC LIMIT 1", params![h], |r| r.get(0))
            .optional()
            .ok()
            .flatten()
    }
    /// A completed *received* copy of `hash` that `peer` itself sent us, or that was shared
    /// in `conv` (so reusing it reveals nothing the offering peer doesn't already know).
    /// Never one of our own originals (direction 0: arbitrary paths on this device).
    pub fn file_dedupe_source(&self, hash_hex: &str, conv: &str, peer: &PeerId, size: i64) -> Option<String> {
        let h = hex::decode(hash_hex).ok()?;
        self.conn
            .lock()
            .query_row(
                "SELECT path FROM files WHERE hash=?1 AND state=2 AND direction=1 AND path<>'' AND size=?4 AND (conv=?2 OR peer=?3)
                 ORDER BY created DESC LIMIT 1",
                params![h, conv, &peer.0[..], size],
                |r| r.get(0),
            )
            .optional()
            .ok()
            .flatten()
    }
    /// The sender's `file_id` (wire) of a file row (`id` unless it was re-keyed locally).
    pub fn file_wire_id(&self, id: &[u8]) -> Option<[u8; 16]> {
        let w: Vec<u8> = self.conn.lock().query_row("SELECT coalesce(wire_id, id) FROM files WHERE id=?1", params![id], |r| r.get(0)).optional().ok()??;
        w.try_into().ok()
    }
    pub fn file_set_wire_id(&self, id: &[u8], wire: &[u8]) -> Result<()> {
        self.conn.lock().execute("UPDATE files SET wire_id=?2 WHERE id=?1", params![id, wire])?;
        Ok(())
    }
    /// Not-yet-deleted file/voice messages of `conv` up to `upto_hlc` (optionally by one author).
    pub fn file_messages(&self, conv: &str, upto_hlc: i64, author: Option<&PeerId>) -> Result<Vec<StoredMessage>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached(
            "SELECT id,conv,author,hlc,kind,body,status,edited,deleted,reply_to,reactions,expires,pinned,meta FROM messages
             WHERE conv=?1 AND hlc<=?2 AND kind IN ('file','voice') AND deleted=0 AND (?3 IS NULL OR author=?3)",
        )?;
        let a: Option<Vec<u8>> = author.map(|p| p.0.to_vec());
        let rows = st.query_map(params![conv, upto_hlc, a], Self::row_msg)?.filter_map(|r| r.ok()).collect();
        Ok(rows)
    }
    /// Forget a file row (its message was deleted for everyone).
    pub fn file_delete(&self, id: &[u8]) -> Result<()> {
        self.conn.lock().execute("DELETE FROM files WHERE id=?1", params![id])?;
        Ok(())
    }
    /// Rows still using `path`: every row that isn't final (failed, cancelled, removed) —
    /// a pending forward or an upload still offered to members needs its source too.
    pub fn path_refcount(&self, path: &str) -> i64 {
        self.conn.lock().query_row("SELECT count(*) FROM files WHERE path=?1 AND state NOT IN (3,4,6)", params![path], |r| r.get(0)).unwrap_or(1)
    }
    /// File messages removed by housekeeping (expired / retention / session-only chats)
    /// whose files the node still has to forget: (conv, author, body).
    pub fn file_gc_take(&self, limit: i64) -> Vec<(String, Vec<u8>, String)> {
        let c = self.conn.lock();
        let rows: Vec<(i64, String, Vec<u8>, String)> = c
            .prepare_cached("SELECT rowid, conv, author, body FROM file_gc ORDER BY rowid LIMIT ?1")
            .and_then(|mut st| st.query_map(params![limit], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))).map(|it| it.filter_map(|r| r.ok()).collect()))
            .unwrap_or_default();
        if let Some(last) = rows.last() {
            let _ = c.execute("DELETE FROM file_gc WHERE rowid<=?1", params![last.0]);
        }
        rows.into_iter().map(|(_, a, b, c)| (a, b, c)).collect()
    }
    /// A moderator's delete / an author's edit that arrived before its message.
    pub fn pending_action_put(&self, target: &[u8], conv: &str, target_author: &PeerId, actor: &PeerId, action: &[u8]) -> Result<bool> {
        let c = self.conn.lock();
        let n: i64 = c.query_row("SELECT count(*) FROM pending_actions WHERE conv=?1", params![conv], |r| r.get(0))?;
        let dup = c
            .query_row("SELECT 1 FROM pending_actions WHERE target=?1 AND actor=?2 AND action=?3", params![target, &actor.0[..], action], |_| Ok(()))
            .optional()?
            .is_some();
        if n >= 2000 || dup {
            return Ok(false);
        }
        c.execute(
            "INSERT INTO pending_actions(target,conv,target_author,actor,action,at) VALUES(?1,?2,?3,?4,?5,?6)",
            params![target, conv, &target_author.0[..], &actor.0[..], action, crate::util::now_ms() as i64],
        )?;
        Ok(true)
    }
    /// Take the remembered actions on `target`: (conv, target_author, actor, action).
    pub fn pending_actions_take(&self, target: &[u8]) -> Vec<PendingAction> {
        let c = self.conn.lock();
        let rows: Vec<PendingAction> = c
            .prepare_cached("SELECT conv, target_author, actor, action FROM pending_actions WHERE target=?1 ORDER BY rowid")
            .and_then(|mut st| st.query_map(params![target], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))).map(|it| it.filter_map(|r| r.ok()).collect()))
            .unwrap_or_default();
        if !rows.is_empty() {
            let _ = c.execute("DELETE FROM pending_actions WHERE target=?1", params![target]);
        }
        rows
    }
    /// Per-conversation usage: messages count + bytes of files on disk.
    pub fn usage_by_conv(&self) -> Result<Vec<Value>> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached(
            "SELECT c.id, c.title, (SELECT count(*) FROM messages m WHERE m.conv=c.id),
                    (SELECT coalesce(sum(length(m.body)),0) FROM messages m WHERE m.conv=c.id),
                    (SELECT coalesce(sum(f.size),0) FROM files f WHERE f.conv=c.id AND f.direction=1 AND f.state=2)
             FROM convs c ORDER BY 5 DESC, 4 DESC LIMIT 200",
        )?;
        let rows = st
            .query_map([], |r| {
                Ok(serde_json::json!({
                    "conv": r.get::<_, String>(0)?, "title": r.get::<_, String>(1)?, "messages": r.get::<_, i64>(2)?,
                    "message_bytes": r.get::<_, i64>(3)?, "media_bytes": r.get::<_, i64>(4)?,
                }))
            })?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }
    /// Keep group anti-entropy logs bounded: at most `max_rows` newest envelopes per group,
    /// and at most [`GROUP_LOG_MAX_BYTES`] of them (inline stickers are up to 1 MB each).
    pub fn trim_group_logs(&self, max_rows: i64) -> Result<usize> {
        self.trim_group_logs_to(max_rows, GROUP_LOG_MAX_BYTES)
    }
    pub fn trim_group_logs_to(&self, max_rows: i64, max_bytes: u64) -> Result<usize> {
        let c = self.conn.lock();
        Ok(c.execute(
            "DELETE FROM group_log WHERE rowid IN (
               SELECT rowid FROM (SELECT rowid, ROW_NUMBER() OVER w rn, SUM(length(env)) OVER w cum FROM group_log
                                  WINDOW w AS (PARTITION BY gid ORDER BY hlc DESC, rowid DESC ROWS UNBOUNDED PRECEDING))
               WHERE rn > ?1 OR cum > ?2)",
            params![max_rows, max_bytes.min(i64::MAX as u64) as i64],
        )?)
    }
    pub fn file_update(&self, id: &[u8], state: i64, progress: i64) -> Result<()> {
        self.conn.lock().execute("UPDATE files SET state=?2, progress=?3 WHERE id=?1", params![id, state, progress])?;
        Ok(())
    }

    // ---------- peer cache / trust ----------
    pub fn peer_cache_put(&self, p: &PeerId, info: &[u8]) -> Result<()> {
        self.conn.lock().execute(
            "INSERT INTO peer_cache(peer,info,updated) VALUES(?1,?2,?3) ON CONFLICT(peer) DO UPDATE SET info=excluded.info, updated=excluded.updated",
            params![&p.0[..], info, crate::util::now_ms() as i64],
        )?;
        Ok(())
    }
    pub fn peer_cache_get(&self, p: &PeerId) -> Option<Vec<u8>> {
        self.conn.lock().query_row("SELECT info FROM peer_cache WHERE peer=?1", params![&p.0[..]], |r| r.get(0)).optional().ok().flatten()
    }
    pub fn remote_trust(&self, p: &PeerId, perms: Option<i64>) -> Result<()> {
        let c = self.conn.lock();
        match perms {
            Some(pr) => c.execute(
                "INSERT OR REPLACE INTO remote_trusted(peer,perms,added) VALUES(?1,?2,?3)",
                params![&p.0[..], pr, crate::util::now_ms() as i64],
            )?,
            None => c.execute("DELETE FROM remote_trusted WHERE peer=?1", params![&p.0[..]])?,
        };
        Ok(())
    }
    pub fn remote_trusted(&self, p: &PeerId) -> Option<i64> {
        self.conn.lock().query_row("SELECT perms FROM remote_trusted WHERE peer=?1", params![&p.0[..]], |r| r.get(0)).optional().ok().flatten()
    }

    pub fn stats(&self) -> Value {
        let c = self.conn.lock();
        let q = |sql: &str| c.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap_or(0);
        serde_json::json!({
            "messages": q("SELECT count(*) FROM messages"),
            "contacts": q("SELECT count(*) FROM contacts WHERE status=3"),
            "groups": q("SELECT count(*) FROM groups"),
            "outbox": q("SELECT count(*) FROM outbox"),
            "mailbox": q("SELECT count(*) FROM mailbox"),
            "files": q("SELECT count(*) FROM files"),
            "db_pages": q("PRAGMA page_count"),
            "free_pages": q("PRAGMA freelist_count"),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    /// Perf review: 400k messages, hot queries before (old SQL / no index) and after.
    /// `cargo test -p lumora-core --release --lib -- --ignored bench_400k --nocapture`
    #[test]
    #[ignore]
    fn bench_400k() {
        use std::time::Instant;
        let s = Store::open_memory().unwrap();
        let authors: Vec<PeerId> = (0..50u8).map(|i| PeerId([i; 32])).collect();
        let t = Instant::now();
        {
            let mut c = s.conn.lock();
            let tx = c.transaction().unwrap();
            for i in 0..400_000u32 {
                let g = i % 200;
                let conv = if g < 100 { format!("g:{:032x}", g) } else { format!("d:{g}") };
                tx.execute(
                    "INSERT INTO messages(id,conv,author,hlc,kind,body,status) VALUES(?1,?2,?3,?4,'text','{\"text\":\"hello\"}',2)",
                    params![i.to_be_bytes(), conv, &authors[(i % 50) as usize].0[..], (i as i64 + 1) << 8],
                )
                .unwrap();
                if i % 20 == 0 {
                    tx.execute(
                        "INSERT INTO files(id,conv,peer,name,size,hash,path,direction,state,created) VALUES(?1,?2,?3,'f',1,?4,?5,1,2,1)",
                        params![i.to_be_bytes(), conv, &authors[0].0[..], blake3::hash(&i.to_be_bytes()).as_bytes().to_vec(), format!("/dl/{i}")],
                    )
                    .unwrap();
                }
            }
            tx.commit().unwrap();
        }
        eprintln!("insert 400k: {:?}", t.elapsed());
        let c = s.conn.lock();
        let time = |name: &str, n: u32, f: &dyn Fn(u32)| {
            let t = Instant::now();
            for i in 0..n {
                f(i);
            }
            eprintln!("{name:<44} {:>10.1} µs/op", t.elapsed().as_secs_f64() * 1e6 / n as f64);
        };
        let plan = |sql: &str| {
            let mut st = c.prepare(&format!("EXPLAIN QUERY PLAN {sql}")).unwrap();
            let rows: Vec<String> = st.query_map([], |r| r.get::<_, String>(3)).unwrap().filter_map(|r| r.ok()).collect();
            eprintln!("  plan: {}", rows.join(" | "));
        };
        let q1 = |sql: &str, p: &[&dyn rusqlite::ToSql]| {
            let _ = c.query_row(sql, p, |_| Ok(()));
        };
        let g5 = format!("g:{:032x}", 5);
        // slow mode: previous message of an author in a group (old: LIKE over the prefix)
        time("last_hlc_by (old: conv LIKE)", 50, &|i| q1("SELECT MAX(hlc) FROM messages WHERE conv LIKE ?1 AND author=?2", &[&format!("{g5}%"), &&authors[(i % 50) as usize].0[..]]));
        plan("SELECT MAX(hlc) FROM messages WHERE conv LIKE 'g:x%' AND author=x'00'");
        time("prev_hlc_by (new: conv= AND author=)", 2000, &|i| q1("SELECT MAX(hlc) FROM messages WHERE conv=?1 AND author=?2 AND hlc<?3", &[&g5, &&authors[(i % 50) as usize].0[..], &i64::MAX]));
        plan("SELECT MAX(hlc) FROM messages WHERE conv='g:x' AND author=x'00' AND hlc<5");
        for (idx, sql, arg) in [
            ("files_hash", "SELECT path FROM files WHERE hash=?1 AND state=2 AND path<>'' ORDER BY created DESC LIMIT 1", "hash"),
            ("files_path", "SELECT count(*) FROM files WHERE path=?1 AND state NOT IN (3,4,6)", "path"),
        ] {
            let arg_of = |i: u32| -> Box<dyn rusqlite::ToSql> {
                let k = (i * 20) % 400_000;
                if arg == "hash" { Box::new(blake3::hash(&k.to_be_bytes()).as_bytes().to_vec()) } else { Box::new(format!("/dl/{k}")) }
            };
            c.execute_batch(&format!("DROP INDEX {idx}")).unwrap();
            time(&format!("{idx} (old: no index)"), 50, &|i| q1(sql, &[&*arg_of(i)]));
            c.execute_batch(&format!("CREATE INDEX {idx} ON files({})", if arg == "hash" { "hash" } else { "path" })).unwrap();
            time(&format!("{idx} (new: indexed)"), 5000, &|i| q1(sql, &[&*arg_of(i)]));
            plan(&sql.replace("?1", "x'00'"));
        }
        time("messages page (conv, hlc)", 2000, &|_| {
            let mut st = c.prepare_cached("SELECT id FROM messages WHERE conv=?1 AND hlc<?2 ORDER BY hlc DESC LIMIT 50").unwrap();
            let _ = st.query_map(params![g5, i64::MAX], |r| r.get::<_, Vec<u8>>(0)).unwrap().count();
        });
        plan("SELECT id FROM messages WHERE conv='x' AND hlc<5 ORDER BY hlc DESC LIMIT 50");
        time("mark read (max hlc of conv)", 2000, &|_| q1("SELECT MAX(hlc) FROM messages WHERE conv=?1", &[&g5]));
        plan("SELECT MAX(hlc) FROM messages WHERE conv='x'");
        time("group convs (range on convs pk)", 2000, &|_| q1("SELECT id FROM convs WHERE id=?1 OR (id>=?2 AND id<?3)", &[&g5, &format!("{g5}#"), &format!("{g5}$")]));
        plan("SELECT id FROM convs WHERE id='a' OR (id>='a#' AND id<'a$')");
        plan("SELECT env FROM group_log WHERE gid=x'00' AND author=x'00' AND hlc>5 AND length(env)>0 AND (k IN (0,1) OR hlc>=6) ORDER BY hlc LIMIT 500");
        plan("UPDATE group_log SET env=x'' WHERE msg_id=x'00' AND length(env)>0");
        plan("SELECT COALESCE(SUM(length(env)),0) FROM group_log WHERE gid=x'00' AND rcv>5");
        drop(c);
        let t = Instant::now();
        s.maintain().unwrap();
        eprintln!("maintain() on 400k: {:?}", t.elapsed());
    }

    /// Group logs are bounded in bytes too (inline stickers), newest kept; keys: the
    /// winning one is "the" key, others stay readable; tombstones aren't re-served.
    #[test]
    fn group_log_bytes_keys_and_tombstones() {
        let s = Store::open_memory().unwrap();
        let (g, a) = ([1u8; 16], PeerId([2; 32]));
        for i in 0..40u32 {
            s.group_log_put_ex(&i.to_be_bytes(), &g, &a, i as u64 + 1, &vec![0u8; 200 * 1024], 2, Some(&[i as u8; 16])).unwrap();
        }
        s.trim_group_logs(5000).unwrap();
        let kept = s.group_log_since(&g, &a, 0, 1000);
        assert!(kept.len() as u64 * 200 * 1024 <= GROUP_LOG_MAX_BYTES && !kept.is_empty(), "{}", kept.len());
        assert_eq!(s.group_log_heads(&g), vec![(a, 40)], "newest kept");
        // a forgotten message's envelope stays as a tombstone (seen) but is never served
        s.group_log_forget(&[39u8; 16]).unwrap();
        assert!(s.group_log_has(&39u32.to_be_bytes()));
        assert!(s.group_log_since(&g, &a, 39, 10).is_empty());
        // keys
        let (k1, k2) = ([1u8; 32], [2u8; 32]);
        s.group_key_put(&g, 1, &k1).unwrap();
        s.group_key_put(&g, 1, &k2).unwrap(); // replaced (validated by the caller)
        assert_eq!(s.group_key_get(&g, 1), Some(k2));
        assert_eq!(s.group_keys_all(&g, 1), vec![k2, k1]);
        s.group_key_demote(&g, 1).unwrap();
        assert_eq!(s.group_key_get(&g, 1), None);
        assert_eq!(s.group_keys_all(&g, 1).len(), 2);
        // pending keys: bounded per sender, the real one from someone else still fits
        let (junk, real) = (PeerId([3; 32]), PeerId([4; 32]));
        let stored = (0..40u8).filter(|i| s.group_key_pending_put(&g, 3, &junk, &[*i; 32]).unwrap()).count();
        assert!(stored < 40);
        assert!(s.group_key_pending_put(&g, 3, &real, &[200; 32]).unwrap());
    }

    #[test]
    fn insert_respects_cleared_upto_and_vote_bounds() {
        let s = Store::open_memory().unwrap();
        let a = PeerId([3; 32]);
        s.ensure_conv("d:x", 0, "x").unwrap();
        s.insert_message(b"1", "d:x", &a, 10, "text", &serde_json::json!({"text": "a"}), 2, None, None).unwrap();
        s.clear_conv("d:x", 100).unwrap();
        assert!(!s.insert_message(b"2", "d:x", &a, 50, "text", &serde_json::json!({"text": "late"}), 2, None, None).unwrap(), "cleared history came back");
        assert!(s.insert_message(b"3", "d:x", &a, 150, "text", &serde_json::json!({"text": "new"}), 2, None, None).unwrap());
        s.insert_message(b"p", "d:x", &a, 160, "poll", &serde_json::json!({"question": "?", "options": ["a", "b"]}), 2, None, None).unwrap();
        assert!(!s.vote(b"p", &a, 1).unwrap().is_null());
        assert!(s.vote(b"p", &a, 7).unwrap().is_null(), "vote for a non-existent option");
        assert!(!s.edit_message(b"p", &a, &serde_json::json!({"text": "x"})).unwrap(), "a poll was edited into text");
        assert!(s.edit_message(b"3", &a, &serde_json::json!({"text": "x"})).unwrap());
    }

    #[test]
    fn encrypted_db_rejects_wrong_key() {
        let dir = std::env::temp_dir().join(format!("lumora-test-{}", rand::random::<u64>()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.db");
        let k1 = Zeroizing::new([1u8; 32]);
        let k2 = Zeroizing::new([2u8; 32]);
        {
            let s = Store::open(&path, &k1).unwrap();
            s.kv_set("a", b"secret-value").unwrap();
        }
        assert!(Store::open(&path, &k2).is_err());
        let raw = std::fs::read(&path).unwrap();
        assert!(!raw.windows(12).any(|w| w == b"secret-value"), "plaintext leaked to disk");
        let s = Store::open(&path, &k1).unwrap();
        assert_eq!(s.kv_get("a").unwrap(), b"secret-value");
        std::fs::remove_dir_all(dir).ok();
    }
    #[test]
    fn messages_paging_and_dedupe() {
        let s = Store::open_memory().unwrap();
        let p = PeerId([3; 32]);
        s.ensure_conv("d:x", 0, "x").unwrap();
        for i in 0..10u64 {
            assert!(s.insert_message(&i.to_be_bytes(), "d:x", &p, i + 1, "text", &serde_json::json!({"text": i}), 1, None, None).unwrap());
        }
        assert!(!s.insert_message(&0u64.to_be_bytes(), "d:x", &p, 1, "text", &Value::Null, 1, None, None).unwrap());
        let page = s.messages("d:x", None, 4).unwrap();
        assert_eq!(page.len(), 4);
        assert_eq!(page.last().unwrap().hlc, 10);
        let older = s.messages("d:x", Some(page[0].hlc), 100).unwrap();
        assert_eq!(older.len(), 6);
        let r = s.react(&0u64.to_be_bytes(), &p, "👍", true).unwrap();
        assert_eq!(r["👍"].as_array().unwrap().len(), 1);
    }
    /// Abuse: a (malicious) friend handing us StoreFor mail must not fill our disk —
    /// bytes are capped per recipient and overall, not only the item count.
    #[test]
    fn mailbox_is_bounded_in_bytes() {
        let s = Store::open_memory().unwrap();
        let item = vec![7u8; 60 * 1024];
        let count = |p: &PeerId| s.conn.lock().query_row("SELECT count(*) FROM mailbox WHERE for_peer=?1", params![&p.0[..]], |r| r.get::<_, i64>(0)).unwrap() as usize;
        let a = PeerId([1; 32]);
        for i in 0..50u32 {
            s.mailbox_put(&i.to_be_bytes(), &a, &item).unwrap();
        }
        assert_eq!(count(&a), MAILBOX_MAX_PER_PEER / item.len(), "per-recipient byte cap");
        for (n, p) in [PeerId([2; 32]), PeerId([3; 32]), PeerId([4; 32])].iter().enumerate() {
            for i in 0..50u32 {
                s.mailbox_put(&(1000 * (n as u32 + 1) + i).to_be_bytes(), p, &item).unwrap();
            }
        }
        let total: i64 = s.conn.lock().query_row("SELECT sum(length(payload)) FROM mailbox", [], |r| r.get(0)).unwrap();
        assert!(total as usize <= MAILBOX_MAX_TOTAL && total as usize + item.len() > MAILBOX_MAX_TOTAL, "overall byte cap: {total}");
        // taking a recipient's mail frees room again
        assert_eq!(s.mailbox_take(&a).unwrap().len(), MAILBOX_MAX_PER_PEER / item.len());
        s.mailbox_put(b"again", &PeerId([5; 32]), &item).unwrap();
        assert_eq!(count(&PeerId([5; 32])), 1);
    }

    #[test]
    fn stories_are_capped_per_author() {
        let s = Store::open_memory().unwrap();
        let (spammer, friend) = (PeerId([1; 32]), PeerId([2; 32]));
        let now = crate::util::now_ms() as i64;
        let put = |id: u32, a: &PeerId, created: i64| s.story_put(&id.to_be_bytes(), a, created, "hi", &[], "").unwrap();
        // expired stories don't count
        for i in 0..10u32 {
            assert!(put(10_000 + i, &spammer, now - 2 * 86_400_000));
        }
        let stored = (0..200u32).filter(|i| put(*i, &spammer, now)).count();
        assert_eq!(stored as i64, MAX_STORIES_PER_AUTHOR);
        assert_eq!(s.story_count(&spammer), MAX_STORIES_PER_AUTHOR);
        assert!(put(5000, &friend, now), "other authors unaffected");
    }

    #[test]
    fn sticker_cache_is_lru_bounded_and_spares_my_packs() {
        let s = Store::open_memory().unwrap();
        let blob = vec![9u8; 300 * 1024];
        let h = |i: u8| [i; 32];
        // one of my packs holds sticker 0
        s.sticker_blob_put(&h(0), "image/png", &blob).unwrap();
        s.sticker_pack_create("p", "Của tôi").unwrap();
        s.sticker_add(&h(0), "p", "image/png", "", false).unwrap();
        for i in 1..=12u8 {
            s.sticker_blob_put(&h(i), "image/png", &blob).unwrap();
            // distinct, increasing "used" times
            s.conn.lock().execute("UPDATE sticker_blobs SET used=?2 WHERE hash=?1", params![&h(i)[..], i as i64 * 1000]).unwrap();
        }
        s.conn.lock().execute("UPDATE sticker_blobs SET used=0 WHERE hash=?1", params![&h(0)[..]]).unwrap();
        // sticker 2 was looked at recently: it becomes the most recently used
        assert!(s.sticker_blob(&h(2)).is_some());
        let evicted = s.sticker_cache_enforce(STICKER_CACHE_MAX).unwrap();
        let cached: u64 = s
            .conn
            .lock()
            .query_row("SELECT SUM(length(data)) FROM sticker_blobs WHERE hash NOT IN (SELECT hash FROM stickers)", [], |r| r.get::<_, i64>(0))
            .unwrap() as u64;
        assert!(evicted > 0 && cached <= STICKER_CACHE_MAX, "{evicted} {cached}");
        assert!(s.sticker_blob_has(&h(0)), "my own pack is never evicted");
        assert!(s.sticker_blob_has(&h(2)) && s.sticker_blob_has(&h(12)), "recently used survive");
        assert!(!s.sticker_blob_has(&h(1)), "least recently used goes first");
    }

    #[test]
    fn stale_stranger_rows_are_forgotten_but_nothing_that_matters() {
        let s = Store::open_memory().unwrap();
        let now = crate::util::now_ms() as i64;
        let old = now - STRANGER_TTL_MS - 86_400_000;
        let mk = |i: u8, status: i64| {
            let p = PeerId([i; 32]);
            s.upsert_contact(&p, Some("x"), Some(status)).unwrap();
            s.conn.lock().execute("UPDATE contacts SET added=?2, last_seen=0 WHERE peer=?1", params![&p.0[..], old]).unwrap();
            p
        };
        let stale = mk(1, 0);
        let blocked = mk(2, 4);
        let pending = mk(3, 2);
        let asked = mk(4, 1);
        let friend = mk(5, 3);
        let chatted = mk(6, 0);
        s.ensure_conv(&format!("d:{}", chatted.to_base32()), 0, "x").unwrap();
        let poster = mk(7, 0);
        s.ensure_conv("g:00", 1, "g").unwrap();
        s.insert_message(b"m1", "g:00", &poster, 1, "text", &serde_json::json!({"text": "hi"}), 2, None, None).unwrap();
        let aliased = mk(8, 0);
        s.set_contact_field(&aliased, "alias", rusqlite::types::Value::Text("Bạn cũ".into())).unwrap();
        let recent = mk(9, 0);
        s.conn.lock().execute("UPDATE contacts SET last_seen=?2 WHERE peer=?1", params![&recent.0[..], now - 86_400_000]).unwrap();
        // a co-member of one of my groups
        let co = mk(10, 0);
        let me = crate::identity::Identity::generate();
        let (st, _) = crate::group::create(&crate::devices::Signer::primary(&me), 1, "Nhóm", vec![co], 0).unwrap();
        s.group_save(&st.gid, &rmp_serde::to_vec(&st).unwrap()).unwrap();

        assert_eq!(s.gc_stranger_contacts_now(now).unwrap(), 1);
        assert!(s.contact(&stale).is_none());
        for p in [blocked, pending, asked, friend, chatted, poster, aliased, recent, co] {
            assert!(s.contact(&p).is_some(), "{p:?} must be kept");
        }
        // maintain() runs it too, at most every 6 h
        let again = mk(11, 0);
        s.maintain().unwrap();
        assert!(s.contact(&again).is_none());
        let third = mk(12, 0);
        s.maintain().unwrap();
        assert!(s.contact(&third).is_some(), "spaced out: not again within 6 h");
    }
}
