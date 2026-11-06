//! Multi-device storage: device lists, the sibling change log (anti-entropy), and the
//! row-level items exchanged between the devices of one account (self-sync, bootstrap,
//! history). Items are map-encoded and decoded one by one, so a newer device's unknown
//! item kinds are skipped instead of failing a whole batch.
//!
//! Change tracking: every mutation of a message / conversation / contact / synced
//! setting / group key appends `(kind, key)` to `sync_log` while the account has ≥ 2
//! devices. Siblings compare small digests (`Have`) and fetch only what differs
//! (`Want` → `Items`). Messages carry a `rev` (last-change stamp) for last-writer-wins
//! on mutable fields; statuses and read positions only move forward.

use super::*;
use crate::devices::DeviceListBody;
use serde_bytes::ByteBuf;
use std::sync::atomic::Ordering;

pub const K_MSG: u8 = 1;
pub const K_PURGE: u8 = 2;
pub const K_CONV: u8 = 3;
pub const K_CONV_DEL: u8 = 4;
pub const K_CONTACT: u8 = 5;
pub const K_KV: u8 = 6;
pub const K_GKEY: u8 = 7;
/// a sticker pack (name + its stickers, or its removal) — key: pack id
pub const K_SPACK: u8 = 8;
/// a sticker image — key: hash
pub const K_SBLOB: u8 = 9;

/// Settings that follow the user to every device. Never `net.*`, `olm.*`, `remote.*`,
/// `bot.*`, `account.*`, `device.*`, `link.*`, `push.*`, `uisecret:*` (device-local).
pub fn kv_synced(k: &str) -> bool {
    // `retention.<conv>`: the chat's history policy (mirrors the `retention` table)
    const PREFIXES: &[&str] = &["profile.", "privacy.", "wallpaper.", "mute_until.", "retention."];
    // `botfather.bots`: the bots this account manages (tokens stay inside the account's own,
    // end-to-end encrypted device links) — a bot made on one device shows up on the others
    k == "ui.lang" || k == "storage.policy" || k == "nostr.events" || k == "botfather.bots" || PREFIXES.iter().any(|p| k.starts_with(p))
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct MsgRow {
    pub id: ByteBuf,
    pub conv: String,
    pub author: ByteBuf,
    pub hlc: i64,
    pub kind: String,
    pub body: String,
    pub status: i64,
    #[serde(default)]
    pub edited: bool,
    #[serde(default)]
    pub deleted: bool,
    #[serde(default)]
    pub reply_to: Option<ByteBuf>,
    #[serde(default)]
    pub reactions: String,
    #[serde(default)]
    pub expires: Option<i64>,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub meta: String,
    #[serde(default)]
    pub device: Option<ByteBuf>,
    #[serde(default)]
    pub rev: i64,
    /// Last change of MY reactions on it (newer builds; 0 = unknown). My reactions to a
    /// friend's 1-1 message reach my other devices only through sync, while everyone
    /// else's arrive on each device directly: they merge instead of the whole row
    /// winning (a friend's reaction applied a moment later used to wipe mine).
    #[serde(default)]
    pub my_rev: i64,
    /// Signed time (hlc) of the edit that gave it its text (newer builds; 0 = never
    /// edited / unknown): concurrent edits end the same on every device and at the friend.
    #[serde(default)]
    pub edit_hlc: i64,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ConvRow {
    pub id: String,
    pub kind: i64,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub last_ts: i64,
    #[serde(default)]
    pub last_text: String,
    #[serde(default)]
    pub unread: i64,
    #[serde(default)]
    pub muted: bool,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub read_upto: i64,
    #[serde(default)]
    pub cleared_upto: i64,
    #[serde(default)]
    pub rev: i64,
    /// Per-flag change stamps [muted, pinned, archived] (newer builds): a chat pinned on
    /// one device and muted on another at the same time keeps both.
    #[serde(default)]
    pub frev: Vec<i64>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ContactRow {
    pub peer: ByteBuf,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub alias: Option<String>,
    pub status: i64,
    #[serde(default)]
    pub added: i64,
    #[serde(default)]
    pub verified: bool,
    #[serde(default)]
    pub relays: String,
    #[serde(default)]
    pub bio: String,
    #[serde(default)]
    pub bot: String,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub avatar: Option<ByteBuf>,
    #[serde(default)]
    pub cover: Option<ByteBuf>,
    #[serde(default)]
    pub rev: i64,
}

/// One unit of sibling sync / bootstrap / history.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub enum SyncItem {
    Msg(MsgRow),
    Purge { id: ByteBuf },
    Conv(ConvRow),
    /// `upto`: how far it was cleared (hlc) — newer builds; 0 from 1.0.x
    ConvDel {
        conv: String,
        #[serde(default)]
        upto: i64,
    },
    Contact(ContactRow),
    Kv { key: String, value: Option<ByteBuf>, rev: i64 },
    GroupKey { gid: ByteBuf, epoch: u64, key: ByteBuf },
    /// rmp(GroupState) — bootstrap only (afterwards groups converge through their own sync)
    Group { gid: ByteBuf, state: ByteBuf },
    GroupLog { id: ByteBuf, gid: ByteBuf, author: ByteBuf, hlc: i64, env: ByteBuf },
    /// A file known on the sending device (imported as "on another device", state 7).
    File(FileRow),
    /// A cached (friend's) signed device list — validated by the node.
    DeviceList { list: ByteBuf },
    RemoteTrusted { peer: ByteBuf, perms: i64 },
    StickerPack { id: String, name: String, created: i64 },
    Sticker { hash: ByteBuf, pack: String, mime: String, emoji: String, animated: bool },
    StickerBlob { hash: ByteBuf, mime: String, data: ByteBuf },
    /// A sticker pack as it is now (live sync, last writer wins on `rev`): made, renamed,
    /// stickers added / removed, or `deleted`. (1.0.x builds skip this kind.)
    StickerPackState {
        id: String,
        #[serde(default)]
        name: String,
        #[serde(default)]
        created: i64,
        #[serde(default)]
        stickers: Vec<StickerRef>,
        #[serde(default)]
        deleted: bool,
        rev: i64,
    },
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct StickerRef {
    pub hash: ByteBuf,
    #[serde(default)]
    pub mime: String,
    #[serde(default)]
    pub emoji: String,
    #[serde(default)]
    pub animated: bool,
}

impl SyncItem {
    pub fn encode(&self) -> Vec<u8> {
        rmp_serde::to_vec_named(self).unwrap_or_default()
    }
    pub fn decode(b: &[u8]) -> Option<SyncItem> {
        crate::proto::from_slice_capped(b).ok()
    }
}

/// What an import changed (the node turns this into UI events).
#[derive(Debug, Clone, PartialEq)]
pub enum Imported {
    Nothing,
    MsgNew { conv: String, id: Vec<u8> },
    MsgUpdated { conv: String, id: Vec<u8> },
    MsgPurged { conv: String, id: Vec<u8> },
    Conv { conv: String, cleared_upto: Option<i64> },
    ConvDeleted { conv: String, upto: i64 },
    Contact { peer: PeerId },
    Kv { key: String },
    GroupKey { gid: Vec<u8>, epoch: u64 },
    /// a sticker pack (or a sticker image) changed
    Stickers,
    Group { gid: Vec<u8> },
    /// stored silently (group log rows, files, stickers…)
    Stored,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeviceRow {
    pub device: PeerId,
    pub account: PeerId,
    pub name: String,
    pub kind: u8,
    pub caps: u8,
    pub added: u64,
    pub listed: bool,
    pub revoked: Option<u64>,
    pub last_seen: u64,
    pub proto: u32,
}

/// Position in a history transfer: messages by (conv, hlc, id), then group log rows,
/// then file rows. Stable across inserts/deletes and VACUUM (no rowids).
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct HistCursor {
    #[serde(default)]
    pub stage: u8,
    #[serde(default)]
    pub conv: String,
    #[serde(default)]
    pub hlc: i64,
    #[serde(default)]
    pub id: ByteBuf,
}

fn pid(v: &[u8]) -> Option<PeerId> {
    v.try_into().ok().map(PeerId)
}

const MSG_COLS: &str = "id,conv,author,hlc,kind,body,status,edited,deleted,reply_to,reactions,expires,pinned,meta,device,rev";

fn row_msgrow(r: &rusqlite::Row) -> rusqlite::Result<MsgRow> {
    Ok(MsgRow {
        id: ByteBuf::from(r.get::<_, Vec<u8>>(0)?),
        conv: r.get(1)?,
        author: ByteBuf::from(r.get::<_, Vec<u8>>(2)?),
        hlc: r.get(3)?,
        kind: r.get(4)?,
        body: r.get(5)?,
        status: r.get(6)?,
        edited: r.get::<_, i64>(7)? != 0,
        deleted: r.get::<_, i64>(8)? != 0,
        reply_to: r.get::<_, Option<Vec<u8>>>(9)?.map(ByteBuf::from),
        reactions: r.get(10)?,
        expires: r.get(11)?,
        pinned: r.get::<_, i64>(12)? != 0,
        meta: r.get(13)?,
        device: r.get::<_, Option<Vec<u8>>>(14)?.map(ByteBuf::from),
        rev: r.get(15)?,
        my_rev: 0,
        edit_hlc: 0,
    })
}

/// The chat flags that sync one by one (order of `ConvRow::frev`).
pub(crate) const CONV_FLAGS: [&str; 3] = ["muted", "pinned", "archived"];

const CONV_COLS: &str = "id,kind,title,last_ts,last_text,unread,muted,pinned,archived,read_upto,cleared_upto,rev";

fn row_convrow(r: &rusqlite::Row) -> rusqlite::Result<ConvRow> {
    Ok(ConvRow {
        id: r.get(0)?,
        kind: r.get(1)?,
        title: r.get(2)?,
        last_ts: r.get(3)?,
        last_text: r.get(4)?,
        unread: r.get(5)?,
        muted: r.get::<_, i64>(6)? != 0,
        pinned: r.get::<_, i64>(7)? != 0,
        archived: r.get::<_, i64>(8)? != 0,
        read_upto: r.get(9)?,
        cleared_upto: r.get(10)?,
        rev: r.get(11)?,
        frev: vec![],
    })
}

const CONTACT_COLS: &str = "peer,name,alias,status,added,verified,relays,bio,bot,username,avatar,cover,rev";

fn row_contactrow(r: &rusqlite::Row) -> rusqlite::Result<ContactRow> {
    Ok(ContactRow {
        peer: ByteBuf::from(r.get::<_, Vec<u8>>(0)?),
        name: r.get(1)?,
        alias: r.get(2)?,
        status: r.get(3)?,
        added: r.get(4)?,
        verified: r.get::<_, i64>(5)? != 0,
        relays: r.get(6)?,
        bio: r.get(7)?,
        bot: r.get(8)?,
        username: r.get(9)?,
        avatar: r.get::<_, Option<Vec<u8>>>(10)?.map(ByteBuf::from),
        cover: r.get::<_, Option<Vec<u8>>>(11)?.map(ByteBuf::from),
        rev: r.get(12)?,
    })
}

fn row_device(r: &rusqlite::Row) -> rusqlite::Result<DeviceRow> {
    let d: Vec<u8> = r.get(0)?;
    let a: Vec<u8> = r.get(1)?;
    Ok(DeviceRow {
        device: pid(&d).unwrap_or(PeerId([0; 32])),
        account: pid(&a).unwrap_or(PeerId([0; 32])),
        name: r.get(2)?,
        kind: r.get::<_, i64>(3)? as u8,
        caps: r.get::<_, i64>(4)? as u8,
        added: r.get::<_, i64>(5)? as u64,
        listed: r.get::<_, i64>(6)? != 0,
        revoked: r.get::<_, Option<i64>>(7)?.map(|x| x as u64),
        last_seen: r.get::<_, i64>(8)? as u64,
        proto: r.get::<_, i64>(9)? as u32,
    })
}

/// Reactions after a sibling's copy (`theirs`) arrived: my account's own entries from
/// `theirs` when `take_mine` (they changed them last), everyone else's as this device has
/// them (each device gets those from their authors directly); the message state kept in
/// "__" keys (votes, checklist ticks…) from `theirs` when `take_state` (their row is newer).
fn merge_reactions(local: &str, theirs: &str, me: &PeerId, take_state: bool, take_mine: bool) -> String {
    use serde_json::{Map, Value};
    let parse = |s: &str| serde_json::from_str::<Map<String, Value>>(s).unwrap_or_default();
    let (l, t) = (parse(local), parse(theirs));
    let me = crate::store::b32_pub(&me.0);
    let mut out = Map::new();
    let keys: std::collections::BTreeSet<&String> = l.keys().chain(t.keys()).collect();
    for k in keys {
        if k.starts_with("__") {
            if let Some(v) = if take_state { t.get(k) } else { l.get(k) } {
                out.insert(k.clone(), v.clone());
            }
            continue;
        }
        let who = |m: &Map<String, Value>| -> Vec<String> {
            m.get(k).and_then(|v| v.as_array()).map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default()
        };
        let mut list: Vec<String> = who(&l).into_iter().filter(|p| *p != me).collect();
        let mine = if take_mine { who(&t) } else { who(&l) }.contains(&me);
        if mine {
            list.push(me.clone());
        }
        if !list.is_empty() {
            out.insert(k.clone(), Value::Array(list.into_iter().map(Value::String).collect()));
        }
    }
    Value::Object(out).to_string()
}

impl Store {
    // ------------------------------------------------------------ change tracking

    /// Monotonic change stamp (µs-ish): orders concurrent edits across own devices.
    pub(super) fn next_rev(&self) -> u64 {
        let now = crate::util::now_ms().saturating_mul(1000);
        let salt = self.rev_salt.load(Ordering::Relaxed) % 1000;
        let mut cur = self.last_rev.load(Ordering::Relaxed);
        loop {
            let next = now.max(cur + 1);
            // (rounded up to this device's residue: see `rev_salt`)
            let next = next + (salt + 1000 - next % 1000) % 1000;
            match self.last_rev.compare_exchange(cur, next, Ordering::Relaxed, Ordering::Relaxed) {
                Ok(_) => return next,
                Err(x) => cur = x,
            }
        }
    }
    fn observe_rev(&self, rev: i64) {
        self.last_rev.fetch_max(rev.max(0) as u64, Ordering::Relaxed);
    }

    pub(super) fn track(&self, c: &Connection, kind: u8, key: &[u8]) {
        if self.sync_on.load(Ordering::Relaxed) {
            let _ = c.execute("INSERT INTO sync_log(kind,key) VALUES(?1,?2)", params![kind as i64, key]);
        }
    }
    /// A message changed: new `rev` + log it.
    pub(super) fn bump_if(&self, c: &Connection, n: usize, id: &[u8]) {
        if n > 0 {
            let _ = c.execute("UPDATE messages SET rev=?2 WHERE id=?1", params![id, self.next_rev() as i64]);
            self.track(c, K_MSG, id);
        }
    }
    pub(super) fn touch_kv(&self, c: &Connection, k: &str) {
        let _ = c.execute(
            "INSERT INTO lww(key,rev) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET rev=excluded.rev",
            params![format!("kv:{k}"), self.next_rev() as i64],
        );
        self.track(c, K_KV, k.as_bytes());
    }
    /// I (this account) reacted to a message: my reactions on it changed.
    pub(crate) fn touch_my_reactions(&self, id: &[u8]) {
        let c = self.conn.lock();
        let _ = c.execute(
            "INSERT INTO lww(key,rev) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET rev=excluded.rev",
            params![format!("mr:{}", hex::encode(id)), self.next_rev() as i64],
        );
        self.track(&c, K_MSG, id);
    }
    /// Order of an edit: its signed time, then (for two edits signed in the same instant on
    /// two devices) a few bits of the text's hash — one number, so the sync digest compares
    /// it too and the device holding the losing text asks for the winner. 0 = never edited.
    pub(crate) fn edit_rank(hlc: i64, body: &str) -> u64 {
        if hlc <= 0 {
            return 0;
        }
        let h = blake3::hash(body.as_bytes());
        ((hlc as u64) << 14) | (u16::from_le_bytes([h.as_bytes()[0], h.as_bytes()[1]]) as u64 & 0x3fff)
    }

    pub(crate) fn lww_get(c: &Connection, key: &str) -> Option<i64> {
        c.query_row("SELECT rev FROM lww WHERE key=?1", params![key], |r| r.get(0)).optional().ok().flatten()
    }
    pub(crate) fn lww_set(c: &Connection, key: &str, rev: i64) -> rusqlite::Result<usize> {
        c.execute("INSERT INTO lww(key,rev) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET rev=MAX(rev,excluded.rev)", params![key, rev])
    }
    /// Per-flag stamps of a chat ([muted, pinned, archived]). A chat whose flags were only
    /// ever set by an older build has none: the row's stamp stands for all three.
    fn conv_flag_revs(c: &Connection, id: &str, row_rev: i64) -> Vec<i64> {
        let own: Vec<Option<i64>> = CONV_FLAGS.iter().map(|f| Self::lww_get(c, &format!("cf:{id}:{f}"))).collect();
        let legacy = own.iter().all(|x| x.is_none());
        own.into_iter().map(|x| x.unwrap_or(if legacy { row_rev } else { 0 })).collect()
    }

    /// A sticker pack changed (made, renamed, a sticker added / removed, deleted).
    pub(super) fn touch_sticker_pack(&self, c: &Connection, id: &str) {
        let _ = c.execute(
            "INSERT INTO lww(key,rev) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET rev=excluded.rev",
            params![format!("spack:{id}"), self.next_rev() as i64],
        );
        self.track(c, K_SPACK, id.as_bytes());
    }
    pub(super) fn touch_contact(&self, c: &Connection, p: &PeerId) {
        let _ = c.execute("UPDATE contacts SET rev=?2 WHERE peer=?1", params![&p.0[..], self.next_rev() as i64]);
        self.track(c, K_CONTACT, &p.0);
    }

    /// Which device this store belongs to (its change stamps never equal another's).
    pub fn set_rev_device(&self, device: &PeerId) {
        let h = blake3::hash(&device.0);
        self.rev_salt.store(u64::from_le_bytes(h.as_bytes()[..8].try_into().unwrap_or_default()) % 1000, Ordering::Relaxed);
    }

    pub fn set_sync_enabled(&self, on: bool) {
        self.sync_on.store(on, Ordering::Relaxed);
    }
    pub fn sync_enabled(&self) -> bool {
        self.sync_on.load(Ordering::Relaxed)
    }

    // ------------------------------------------------------------ device lists

    pub fn device_list_get(&self, account: &PeerId) -> Option<(u64, Vec<u8>)> {
        self.conn
            .lock()
            .query_row("SELECT version, list FROM device_lists WHERE account=?1", params![&account.0[..]], |r| Ok((r.get::<_, i64>(0)? as u64, r.get(1)?)))
            .optional()
            .ok()
            .flatten()
    }

    /// Store a validated list and refresh the `devices` rows of that account. `body` holds
    /// only the entries the caller accepted (proven devices, revocations of this account's
    /// own devices). A device bound to another account is never re-assigned, and a
    /// revocation never creates a row (rows are per (account, device) in effect).
    pub fn device_list_put(&self, list: &[u8], body: &DeviceListBody) -> Result<()> {
        let mut c = self.conn.lock();
        let tx = c.transaction()?;
        let acc = &body.account.0[..];
        tx.execute(
            "INSERT INTO device_lists(account,version,list,updated) VALUES(?1,?2,?3,?4)
             ON CONFLICT(account) DO UPDATE SET version=excluded.version, list=excluded.list, updated=excluded.updated",
            params![acc, body.version as i64, list, crate::util::now_ms() as i64],
        )?;
        tx.execute("UPDATE devices SET listed=0 WHERE account=?1", params![acc])?;
        for e in &body.devices {
            let n = tx.execute(
                "INSERT INTO devices(device,account,name,kind,caps,added,listed,revoked) VALUES(?1,?2,?3,?4,?5,?6,1,NULL)
                 ON CONFLICT(device) DO UPDATE SET name=excluded.name, kind=excluded.kind, caps=excluded.caps,
                 added=excluded.added, listed=1, revoked=NULL WHERE devices.account=excluded.account",
                params![&e.device.0[..], acc, e.name, e.kind as i64, e.caps as i64, e.added as i64],
            )?;
            // a stranger row created for this device before we knew its account
            if n > 0 {
                tx.execute("DELETE FROM contacts WHERE peer=?1 AND status=0 AND ?1<>?2", params![&e.device.0[..], acc])?;
            }
        }
        for r in &body.revoked {
            tx.execute(
                "UPDATE devices SET listed=0, revoked=?3 WHERE device=?1 AND account=?2",
                params![&r.device.0[..], acc, r.at as i64],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    /// A device we know under `account` that the account's list signs out.
    pub fn device_set_revoked(&self, dev: &PeerId, account: &PeerId, at: u64) -> Result<()> {
        self.conn
            .lock()
            .execute("UPDATE devices SET listed=0, revoked=?3 WHERE device=?1 AND account=?2", params![&dev.0[..], &account.0[..], at as i64])?;
        Ok(())
    }

    pub fn device_lists_all(&self) -> Vec<Vec<u8>> {
        let c = self.conn.lock();
        let Ok(mut st) = c.prepare_cached("SELECT list FROM device_lists") else { return vec![] };
        st.query_map([], |r| r.get(0)).map(|it| it.filter_map(|r| r.ok()).collect()).unwrap_or_default()
    }

    pub fn devices_of(&self, account: &PeerId) -> Vec<DeviceRow> {
        let c = self.conn.lock();
        let Ok(mut st) = c.prepare_cached(
            "SELECT device,account,name,kind,caps,added,listed,revoked,last_seen,proto FROM devices WHERE account=?1 ORDER BY added, device",
        ) else {
            return vec![];
        };
        st.query_map(params![&account.0[..]], row_device).map(|it| it.filter_map(|r| r.ok()).collect()).unwrap_or_default()
    }

    /// A known (non-revoked) device whose short ID is `sid`.
    pub fn device_by_short_id(&self, sid: u32) -> Option<PeerId> {
        let c = self.conn.lock();
        let mut st = c.prepare_cached("SELECT device FROM devices WHERE revoked IS NULL").ok()?;
        let devs: Vec<Vec<u8>> = st.query_map([], |r| r.get(0)).ok()?.filter_map(|r| r.ok()).collect();
        devs.into_iter().filter_map(|v| <[u8; 32]>::try_from(v.as_slice()).ok().map(PeerId)).find(|p| p.short_id() == sid)
    }

    pub fn device_get(&self, dev: &PeerId) -> Option<DeviceRow> {
        self.conn
            .lock()
            .query_row(
                "SELECT device,account,name,kind,caps,added,listed,revoked,last_seen,proto FROM devices WHERE device=?1",
                params![&dev.0[..]],
                row_device,
            )
            .optional()
            .ok()
            .flatten()
    }

    /// The account a device belongs to, if known (from a device list or a certificate).
    pub fn device_account(&self, dev: &PeerId) -> Option<PeerId> {
        let v: Option<Vec<u8>> = self
            .conn
            .lock()
            .query_row("SELECT account FROM devices WHERE device=?1", params![&dev.0[..]], |r| r.get(0))
            .optional()
            .ok()
            .flatten();
        v.and_then(|v| pid(&v))
    }

    /// Remember a device learned from a valid certificate (not listed yet). Returns true
    /// when this mapping is new.
    pub fn device_learn(&self, dev: &PeerId, account: &PeerId, caps: u8, created: u64) -> Result<bool> {
        let c = self.conn.lock();
        let n = c.execute(
            "INSERT OR IGNORE INTO devices(device,account,caps,added,listed) VALUES(?1,?2,?3,?4,0)",
            params![&dev.0[..], &account.0[..], caps as i64, created as i64],
        )?;
        if n > 0 {
            c.execute("DELETE FROM contacts WHERE peer=?1 AND status=0", params![&dev.0[..]])?;
        }
        Ok(n > 0)
    }

    pub fn device_touch(&self, dev: &PeerId, proto: Option<u32>) {
        let c = self.conn.lock();
        let _ = c.execute("UPDATE devices SET last_seen=?2 WHERE device=?1", params![&dev.0[..], crate::util::now_ms() as i64]);
        if let Some(p) = proto {
            let _ = c.execute("UPDATE devices SET proto=MAX(proto,?2) WHERE device=?1", params![&dev.0[..], p as i64]);
        }
    }

    /// Drop queued items for a device that will never fetch them (revoked / dormant).
    pub fn outbox_purge_device(&self, dev: &PeerId) -> Result<usize> {
        let c = self.conn.lock();
        let n = c.execute("DELETE FROM outbox WHERE to_peer=?1", params![&dev.0[..]])?;
        c.execute("DELETE FROM mailbox WHERE for_peer=?1", params![&dev.0[..]])?;
        Ok(n)
    }

    pub fn set_message_device(&self, id: &[u8], dev: &PeerId) -> Result<()> {
        self.conn.lock().execute("UPDATE messages SET device=?2 WHERE id=?1 AND device IS NULL", params![id, &dev.0[..]])?;
        Ok(())
    }

    pub fn message_device(&self, id: &[u8]) -> Option<PeerId> {
        let v: Option<Vec<u8>> =
            self.conn.lock().query_row("SELECT device FROM messages WHERE id=?1", params![id], |r| r.get(0)).optional().ok().flatten().flatten();
        v.and_then(|v| pid(&v))
    }

    /// A fresh device joining an account: forget what it set up while it stood alone
    /// (its own profile/settings and single-device list), so the account's win.
    pub fn reset_for_link(&self, own: &PeerId) -> Result<()> {
        let c = self.conn.lock();
        let keys: Vec<String> = c.prepare("SELECT k FROM kv")?.query_map([], |r| r.get(0))?.filter_map(|r| r.ok()).collect();
        for k in keys.into_iter().filter(|k| kv_synced(k)) {
            c.execute("DELETE FROM kv WHERE k=?1", params![k])?;
        }
        c.execute("DELETE FROM lww", [])?;
        c.execute("DELETE FROM device_lists WHERE account=?1", params![&own.0[..]])?;
        c.execute("DELETE FROM sync_log", [])?;
        Ok(())
    }

    /// A device left the account (revoked): its queued copies, mail we kept for it and its
    /// sync cursors go.
    pub fn forget_device(&self, dev: &PeerId) -> Result<()> {
        let c = self.conn.lock();
        c.execute("DELETE FROM outbox WHERE to_peer=?1", params![&dev.0[..]])?;
        c.execute("DELETE FROM mailbox WHERE for_peer=?1", params![&dev.0[..]])?;
        c.execute("DELETE FROM sync_peers WHERE device=?1", params![&dev.0[..]])?;
        Ok(())
    }

    /// Delete local-only kv keys under a prefix (`olm.` after the identity changed).
    pub fn kv_del_prefix(&self, prefix: &str) -> Result<usize> {
        let c = self.conn.lock();
        Ok(c.execute("DELETE FROM kv WHERE substr(k,1,length(?1))=?1", params![prefix])?)
    }

    /// Paths of downloaded files (to remove them when a device is signed out with "wipe").
    pub fn file_paths(&self) -> Vec<String> {
        let c = self.conn.lock();
        let Ok(mut st) = c.prepare("SELECT path FROM files WHERE path<>''") else { return vec![] };
        st.query_map([], |r| r.get::<_, String>(0)).map(|it| it.filter_map(|r| r.ok()).collect()).unwrap_or_default()
    }

    /// Nothing worth keeping yet (a device may only be linked into an account when fresh).
    pub fn is_fresh(&self) -> bool {
        let c = self.conn.lock();
        let n: i64 = c
            .query_row(
                "SELECT (SELECT count(*) FROM contacts WHERE status>0) + (SELECT count(*) FROM messages) + (SELECT count(*) FROM groups)",
                [],
                |r| r.get(0),
            )
            .unwrap_or(1);
        n == 0
    }

    // ------------------------------------------------------------ sibling log

    pub fn sync_head(&self) -> u64 {
        self.conn.lock().query_row("SELECT COALESCE(MAX(seq),0) FROM sync_log", [], |r| r.get::<_, i64>(0)).unwrap_or(0) as u64
    }

    /// Latest log entry per (kind, key) after `after`, oldest first: (seq, kind, key).
    pub fn sync_log_since(&self, after: u64, limit: usize) -> Vec<(u64, u8, Vec<u8>)> {
        let c = self.conn.lock();
        let Ok(mut st) = c.prepare_cached("SELECT MAX(seq), kind, key FROM sync_log WHERE seq>?1 GROUP BY kind, key ORDER BY 1 LIMIT ?2") else {
            return vec![];
        };
        st.query_map(params![after as i64, limit as i64], |r| Ok((r.get::<_, i64>(0)? as u64, r.get::<_, i64>(1)? as u8, r.get(2)?)))
            .map(|it| it.filter_map(|r| r.ok()).collect())
            .unwrap_or_default()
    }

    pub fn sync_log_trim(&self, upto: u64) -> Result<usize> {
        Ok(self.conn.lock().execute("DELETE FROM sync_log WHERE seq<=?1", params![upto as i64])?)
    }

    pub fn sync_peer_sent(&self, dev: &PeerId) -> Option<u64> {
        self.conn
            .lock()
            .query_row("SELECT sent_upto FROM sync_peers WHERE device=?1", params![&dev.0[..]], |r| r.get::<_, i64>(0))
            .optional()
            .ok()
            .flatten()
            .map(|x| x as u64)
    }
    pub fn sync_peer_set_sent(&self, dev: &PeerId, upto: u64) -> Result<()> {
        self.conn.lock().execute(
            "INSERT INTO sync_peers(device,sent_upto) VALUES(?1,?2) ON CONFLICT(device) DO UPDATE SET sent_upto=MAX(sent_upto,excluded.sent_upto)",
            params![&dev.0[..], upto as i64],
        )?;
        Ok(())
    }
    /// History transfer progress *from* `dev` (receiver side): (cursor, done).
    pub fn sync_peer_hist(&self, dev: &PeerId) -> Option<(Vec<u8>, bool)> {
        self.conn
            .lock()
            .query_row("SELECT hist_cursor, hist_done FROM sync_peers WHERE device=?1", params![&dev.0[..]], |r| {
                Ok((r.get::<_, Option<Vec<u8>>>(0)?.unwrap_or_default(), r.get::<_, i64>(1)? != 0))
            })
            .optional()
            .ok()
            .flatten()
    }
    pub fn sync_peer_set_hist(&self, dev: &PeerId, cursor: &[u8], done: bool) -> Result<()> {
        self.conn.lock().execute(
            "INSERT INTO sync_peers(device,hist_cursor,hist_done) VALUES(?1,?2,?3)
             ON CONFLICT(device) DO UPDATE SET hist_cursor=excluded.hist_cursor, hist_done=excluded.hist_done",
            params![&dev.0[..], cursor, done as i64],
        )?;
        Ok(())
    }
    pub fn sync_peers_min_sent(&self, devs: &[PeerId]) -> Option<u64> {
        devs.iter().map(|d| self.sync_peer_sent(d).unwrap_or(0)).min()
    }

    // ------------------------------------------------------------ digests / export

    /// Small fingerprint of the current state of (kind, key); `None` = absent here.
    pub fn sync_digest(&self, kind: u8, key: &[u8]) -> Option<Vec<u64>> {
        let c = self.conn.lock();
        let q = |sql: &str, k: &dyn rusqlite::ToSql, n: usize| -> Option<Vec<u64>> {
            c.query_row(sql, params![k], |r| (0..n).map(|i| r.get::<_, i64>(i).map(|x| x.max(0) as u64)).collect::<rusqlite::Result<Vec<u64>>>())
                .optional()
                .ok()
                .flatten()
        };
        match kind {
            K_MSG | K_PURGE => q("SELECT rev, status FROM messages WHERE id=?1", &key, 2).map(|mut d| {
                d.push(Self::lww_get(&c, &format!("mr:{}", hex::encode(key))).unwrap_or(0).max(0) as u64);
                let ed = Self::lww_get(&c, &format!("ed:{}", hex::encode(key))).unwrap_or(0);
                let body: String = c.query_row("SELECT body FROM messages WHERE id=?1", params![key], |r| r.get(0)).unwrap_or_default();
                d.push(Self::edit_rank(ed, &body));
                d
            }),
            K_CONV | K_CONV_DEL => {
                let id = String::from_utf8_lossy(key).to_string();
                q("SELECT rev, read_upto, cleared_upto FROM convs WHERE id=?1", &id, 3).map(|mut d| {
                    let row_rev = d[0] as i64;
                    d.extend(Self::conv_flag_revs(&c, &id, row_rev).into_iter().map(|x| x.max(0) as u64));
                    d
                })
            }
            K_CONTACT => q("SELECT rev FROM contacts WHERE peer=?1", &key, 1),
            K_KV => {
                let k = String::from_utf8_lossy(key).to_string();
                let exists = c.query_row("SELECT 1 FROM kv WHERE k=?1", params![k], |_| Ok(())).optional().ok().flatten().is_some();
                let rev: i64 = c.query_row("SELECT rev FROM lww WHERE key=?1", params![format!("kv:{k}")], |r| r.get(0)).optional().ok().flatten().unwrap_or(0);
                (exists || rev > 0).then(|| vec![rev.max(0) as u64])
            }
            K_GKEY => {
                if key.len() != 24 {
                    return None;
                }
                let epoch = u64::from_le_bytes(key[16..24].try_into().ok()?);
                c.query_row("SELECT 1 FROM group_keys WHERE gid=?1 AND epoch=?2", params![&key[..16], epoch as i64], |_| Ok(vec![]))
                    .optional()
                    .ok()
                    .flatten()
            }
            K_SPACK => {
                let id = String::from_utf8_lossy(key).to_string();
                let exists = c.query_row("SELECT 1 FROM sticker_packs WHERE id=?1", params![id], |_| Ok(())).optional().ok().flatten().is_some();
                let rev: i64 =
                    c.query_row("SELECT rev FROM lww WHERE key=?1", params![format!("spack:{id}")], |r| r.get(0)).optional().ok().flatten().unwrap_or(0);
                (exists || rev > 0).then(|| vec![rev.max(0) as u64])
            }
            K_SBLOB => c.query_row("SELECT 1 FROM sticker_blobs WHERE hash=?1", params![key], |_| Ok(vec![])).optional().ok().flatten(),
            _ => None,
        }
    }

    /// Should we ask for (kind, key) given the sender's digest?
    pub fn sync_wants(&self, kind: u8, key: &[u8], theirs: &[u64]) -> bool {
        let mine = self.sync_digest(kind, key);
        match kind {
            // tombstones: only if we still have the thing
            K_PURGE | K_CONV_DEL => mine.is_some(),
            // deleted "for me" here: never fetch it back
            K_MSG if mine.is_none() && Store::is_purged_on(&self.conn.lock(), key) => false,
            _ => match mine {
                None => true,
                Some(m) => theirs.iter().zip(m.iter().chain(std::iter::repeat(&0))).any(|(t, l)| t > l),
            },
        }
    }

    /// Current state of (kind, key) as an item (None if there is nothing to send).
    pub fn sync_export(&self, kind: u8, key: &[u8]) -> Option<SyncItem> {
        let c = self.conn.lock();
        match kind {
            K_MSG => c.query_row(&format!("SELECT {MSG_COLS} FROM messages WHERE id=?1"), params![key], row_msgrow).optional().ok().flatten().map(|mut m| {
                m.my_rev = Self::lww_get(&c, &format!("mr:{}", hex::encode(key))).unwrap_or(0);
                m.edit_hlc = Self::lww_get(&c, &format!("ed:{}", hex::encode(key))).unwrap_or(0);
                SyncItem::Msg(m)
            }),
            K_PURGE => {
                let gone = c.query_row("SELECT 1 FROM messages WHERE id=?1", params![key], |_| Ok(())).optional().ok().flatten().is_none();
                gone.then(|| SyncItem::Purge { id: ByteBuf::from(key.to_vec()) })
            }
            K_CONV => {
                let id = String::from_utf8_lossy(key).to_string();
                c.query_row(&format!("SELECT {CONV_COLS} FROM convs WHERE id=?1"), params![id], row_convrow).optional().ok().flatten().map(|mut r| {
                    r.frev = Self::conv_flag_revs(&c, &r.id, r.rev);
                    SyncItem::Conv(r)
                })
            }
            K_CONV_DEL => {
                let id = String::from_utf8_lossy(key).to_string();
                let gone = c.query_row("SELECT 1 FROM convs WHERE id=?1", params![id], |_| Ok(())).optional().ok().flatten().is_none();
                let upto: i64 = c.query_row("SELECT upto FROM conv_gone WHERE id=?1", params![id], |r| r.get(0)).optional().ok().flatten().unwrap_or(0);
                gone.then_some(SyncItem::ConvDel { conv: id, upto })
            }
            K_CONTACT => c
                .query_row(&format!("SELECT {CONTACT_COLS} FROM contacts WHERE peer=?1"), params![key], row_contactrow)
                .optional()
                .ok()
                .flatten()
                .map(SyncItem::Contact),
            K_KV => {
                let k = String::from_utf8_lossy(key).to_string();
                if !kv_synced(&k) {
                    return None;
                }
                let v: Option<Vec<u8>> = c.query_row("SELECT v FROM kv WHERE k=?1", params![k], |r| r.get(0)).optional().ok().flatten().flatten();
                let rev: i64 = c.query_row("SELECT rev FROM lww WHERE key=?1", params![format!("kv:{k}")], |r| r.get(0)).optional().ok().flatten().unwrap_or(0);
                Some(SyncItem::Kv { key: k, value: v.map(ByteBuf::from), rev })
            }
            K_GKEY => {
                if key.len() != 24 {
                    return None;
                }
                let epoch = u64::from_le_bytes(key[16..24].try_into().ok()?);
                let k: Option<Vec<u8>> =
                    c.query_row("SELECT key FROM group_keys WHERE gid=?1 AND epoch=?2", params![&key[..16], epoch as i64], |r| r.get(0)).optional().ok().flatten();
                k.map(|k| SyncItem::GroupKey { gid: ByteBuf::from(key[..16].to_vec()), epoch, key: ByteBuf::from(k) })
            }
            K_SPACK => {
                let id = String::from_utf8_lossy(key).to_string();
                let rev: i64 =
                    c.query_row("SELECT rev FROM lww WHERE key=?1", params![format!("spack:{id}")], |r| r.get(0)).optional().ok().flatten().unwrap_or(0);
                let pack: Option<(String, i64)> =
                    c.query_row("SELECT name, created FROM sticker_packs WHERE id=?1", params![id], |r| Ok((r.get(0)?, r.get(1)?))).optional().ok().flatten();
                Some(match pack {
                    None => SyncItem::StickerPackState { id, name: String::new(), created: 0, stickers: vec![], deleted: true, rev },
                    Some((name, created)) => {
                        let stickers = c
                            .prepare_cached("SELECT hash, mime, emoji, animated FROM stickers WHERE pack=?1 ORDER BY created")
                            .and_then(|mut st| {
                                st.query_map(params![id], |r| {
                                    Ok(StickerRef {
                                        hash: ByteBuf::from(r.get::<_, Vec<u8>>(0)?),
                                        mime: r.get(1)?,
                                        emoji: r.get(2)?,
                                        animated: r.get::<_, i64>(3)? != 0,
                                    })
                                })
                                .map(|it| it.filter_map(|r| r.ok()).collect())
                            })
                            .unwrap_or_default();
                        SyncItem::StickerPackState { id, name, created, stickers, deleted: false, rev }
                    }
                })
            }
            K_SBLOB => c
                .query_row("SELECT mime, data FROM sticker_blobs WHERE hash=?1", params![key], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?)))
                .optional()
                .ok()
                .flatten()
                .map(|(mime, data)| SyncItem::StickerBlob { hash: ByteBuf::from(key.to_vec()), mime, data: ByteBuf::from(data) }),
            _ => None,
        }
    }

    // ------------------------------------------------------------ import

    /// Apply one item from a sibling. `live`: an ongoing change (update previews/unread);
    /// false for history (conversation rows come with the bootstrap).
    pub fn sync_import(&self, item: &SyncItem, me: &PeerId, live: bool) -> Result<Imported> {
        let c = self.conn.lock();
        self.import_one(&c, item, me, live)
    }

    /// Apply a batch in one transaction (history / bootstrap): all or nothing, idempotent.
    pub fn sync_import_batch(&self, items: &[SyncItem], me: &PeerId, live: bool) -> Result<Vec<Imported>> {
        let mut c = self.conn.lock();
        let tx = c.transaction()?;
        let mut out = Vec::with_capacity(items.len());
        for it in items {
            out.push(self.import_one(&tx, it, me, live)?);
        }
        tx.commit()?;
        Ok(out)
    }

    fn import_one(&self, c: &Connection, item: &SyncItem, me: &PeerId, live: bool) -> Result<Imported> {
        Ok(match item {
            SyncItem::Msg(m) => self.import_msg(c, m, me, live)?,
            SyncItem::Purge { id } => {
                // remembered even when the message hasn't reached this device yet
                Self::note_purged_on(c, id)?;
                let conv: Option<String> = c.query_row("SELECT conv FROM messages WHERE id=?1", params![&id[..]], |r| r.get(0)).optional()?;
                match conv {
                    Some(conv) => {
                        c.execute("DELETE FROM messages WHERE id=?1", params![&id[..]])?;
                        self.track(c, K_PURGE, id);
                        Imported::MsgPurged { conv, id: id.to_vec() }
                    }
                    None => Imported::Nothing,
                }
            }
            SyncItem::Conv(r) => self.import_conv(c, r, me)?,
            SyncItem::ConvDel { conv, upto } => {
                if c.query_row("SELECT 1 FROM convs WHERE id=?1", params![conv], |_| Ok(())).optional()?.is_some() {
                    Imported::ConvDeleted { conv: conv.clone(), upto: *upto } // the node deletes (files, events)
                } else {
                    if *upto > 0 {
                        // never had it (or already gone): still keep late copies out
                        c.execute(
                            "INSERT INTO conv_gone(id,upto,at) VALUES(?1,?2,?3) ON CONFLICT(id) DO UPDATE SET upto=MAX(upto,excluded.upto)",
                            params![conv, upto, crate::util::now_ms() as i64],
                        )?;
                    }
                    Imported::Nothing
                }
            }
            SyncItem::Contact(r) => self.import_contact(c, r)?,
            SyncItem::Kv { key, value, rev } => {
                // what the main device knows about friends' app versions (bootstrap only)
                if key.starts_with("peer.proto.") && key.len() < 80 {
                    if let Some(v) = value.as_ref().filter(|v| v.len() == 4) {
                        c.execute("INSERT OR IGNORE INTO kv(k,v) VALUES(?1,?2)", params![key, &v[..]])?;
                    }
                    return Ok(Imported::Stored);
                }
                if !kv_synced(key) {
                    return Ok(Imported::Nothing);
                }
                let lk = format!("kv:{key}");
                let local: i64 = c.query_row("SELECT rev FROM lww WHERE key=?1", params![lk], |r| r.get(0)).optional()?.unwrap_or(0);
                if *rev <= local {
                    return Ok(Imported::Nothing);
                }
                match value {
                    Some(v) => c.execute("INSERT INTO kv(k,v) VALUES(?1,?2) ON CONFLICT(k) DO UPDATE SET v=excluded.v", params![key, &v[..]])?,
                    None => c.execute("DELETE FROM kv WHERE k=?1", params![key])?,
                };
                if let Some(conv) = key.strip_prefix("retention.") {
                    let ms = value.as_ref().and_then(|v| <[u8; 8]>::try_from(&v[..]).ok()).map(i64::from_le_bytes);
                    Self::set_retention_on(c, conv, ms)?;
                }
                c.execute("INSERT INTO lww(key,rev) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET rev=excluded.rev", params![lk, rev])?;
                self.observe_rev(*rev);
                self.track(c, K_KV, key.as_bytes());
                Imported::Kv { key: key.clone() }
            }
            SyncItem::GroupKey { gid, epoch, key } => {
                anyhow::ensure!(gid.len() == 16 && key.len() == 32, "bad group key item");
                if c.execute("INSERT OR IGNORE INTO group_keys(gid,epoch,key) VALUES(?1,?2,?3)", params![&gid[..], *epoch as i64, &key[..]])? > 0 {
                    let mut k = gid.to_vec();
                    k.extend_from_slice(&epoch.to_le_bytes());
                    self.track(c, K_GKEY, &k);
                    Imported::GroupKey { gid: gid.to_vec(), epoch: *epoch }
                } else {
                    Imported::Nothing
                }
            }
            SyncItem::Group { gid, state } => {
                let n = c.execute(
                    "INSERT OR IGNORE INTO groups(id,state,updated) VALUES(?1,?2,?3)",
                    params![&gid[..], &state[..], crate::util::now_ms() as i64],
                )?;
                if n > 0 {
                    Imported::Group { gid: gid.to_vec() }
                } else {
                    Imported::Nothing
                }
            }
            SyncItem::GroupLog { id, gid, author, hlc, env } => {
                c.execute(
                    "INSERT OR IGNORE INTO group_log(id,gid,author,hlc,env) VALUES(?1,?2,?3,?4,?5)",
                    params![&id[..], &gid[..], &author[..], hlc, &env[..]],
                )?;
                Imported::Stored
            }
            SyncItem::File(f) => {
                let id = hex::decode(&f.id)?;
                c.execute(
                    "INSERT OR IGNORE INTO files(id,conv,peer,name,size,hash,path,direction,state,progress,created) VALUES(?1,?2,?3,?4,?5,?6,'',?7,7,0,?8)",
                    params![
                        id,
                        f.conv,
                        PeerId::from_str_any(&f.peer).map(|p| p.0.to_vec()).unwrap_or_default(),
                        f.name,
                        f.size,
                        hex::decode(&f.hash).unwrap_or_default(),
                        f.direction.clamp(0, 1),
                        f.created
                    ],
                )?;
                Imported::Stored
            }
            SyncItem::DeviceList { .. } => Imported::Nothing, // validated by the node
            SyncItem::RemoteTrusted { peer, perms } => {
                c.execute(
                    "INSERT OR IGNORE INTO remote_trusted(peer,perms,added) VALUES(?1,?2,?3)",
                    params![&peer[..], perms, crate::util::now_ms() as i64],
                )?;
                Imported::Stored
            }
            SyncItem::StickerPack { id, name, created } => {
                c.execute("INSERT OR IGNORE INTO sticker_packs(id,name,created) VALUES(?1,?2,?3)", params![id, name, created])?;
                Imported::Stored
            }
            SyncItem::Sticker { hash, pack, mime, emoji, animated } => {
                c.execute(
                    "INSERT OR IGNORE INTO stickers(hash,pack,mime,emoji,animated,created) VALUES(?1,?2,?3,?4,?5,?6)",
                    params![&hash[..], pack, mime, emoji, *animated as i64, crate::util::now_ms() as i64],
                )?;
                Imported::Stored
            }
            SyncItem::StickerBlob { hash, mime, data } => {
                let n = c.execute(
                    "INSERT OR IGNORE INTO sticker_blobs(hash,mime,data,used) VALUES(?1,?2,?3,?4)",
                    params![&hash[..], mime, &data[..], crate::util::now_ms() as i64],
                )?;
                // (live: a sticker of one of my packs whose image just arrived)
                if n > 0 && live {
                    Imported::Stickers
                } else {
                    Imported::Stored
                }
            }
            SyncItem::StickerPackState { id, name, created, stickers, deleted, rev } => {
                anyhow::ensure!(!id.is_empty() && id.len() <= 64 && stickers.len() <= 500, "bad sticker pack item");
                self.observe_rev(*rev);
                let lk = format!("spack:{id}");
                let local: i64 = c.query_row("SELECT rev FROM lww WHERE key=?1", params![lk], |r| r.get(0)).optional()?.unwrap_or(0);
                if *rev <= local {
                    return Ok(Imported::Nothing);
                }
                c.execute("DELETE FROM stickers WHERE pack=?1", params![id])?;
                if *deleted {
                    c.execute("DELETE FROM sticker_packs WHERE id=?1", params![id])?;
                } else {
                    let name: String = name.chars().take(48).collect();
                    c.execute(
                        "INSERT INTO sticker_packs(id,name,created) VALUES(?1,?2,?3) ON CONFLICT(id) DO UPDATE SET name=excluded.name",
                        params![id, name, created],
                    )?;
                    let now = crate::util::now_ms() as i64;
                    for (i, s) in stickers.iter().enumerate() {
                        if s.hash.len() != 32 {
                            continue;
                        }
                        // (in the pack's order)
                        c.execute(
                            "INSERT OR IGNORE INTO stickers(hash,pack,mime,emoji,animated,created) VALUES(?1,?2,?3,?4,?5,?6)",
                            params![&s.hash[..], id, s.mime, s.emoji, s.animated as i64, now + i as i64],
                        )?;
                    }
                }
                c.execute("INSERT INTO lww(key,rev) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET rev=excluded.rev", params![lk, rev])?;
                self.track(c, K_SPACK, id.as_bytes());
                Imported::Stickers
            }
        })
    }

    fn import_msg(&self, c: &Connection, m: &MsgRow, me: &PeerId, live: bool) -> Result<Imported> {
        self.observe_rev(m.rev);
        type Local = (i64, i64, i64, String);
        let local: Option<Local> = c
            .query_row("SELECT rev, status, deleted, conv FROM messages WHERE id=?1", params![&m.id[..]], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .optional()?;
        match local {
            None => {
                // a conversation the user cleared (or deleted) up to here stays cleared, and a
                // message deleted "for me" on one of my devices stays deleted
                if m.hlc <= Self::cleared_upto_on(c, &m.conv)? || Self::is_purged_on(c, &m.id) {
                    return Ok(Imported::Nothing);
                }
                let n = c.execute(
                    &format!("INSERT OR IGNORE INTO messages({MSG_COLS}) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)"),
                    params![
                        &m.id[..], m.conv, &m.author[..], m.hlc, m.kind, if m.deleted { "{}".to_string() } else { m.body.clone() }, m.status,
                        m.edited as i64, m.deleted as i64, m.reply_to.as_ref().map(|r| r.to_vec()),
                        if m.reactions.is_empty() { "{}".to_string() } else { m.reactions.clone() }, m.expires, m.pinned as i64,
                        if m.meta.is_empty() { "{}".to_string() } else { m.meta.clone() }, m.device.as_ref().map(|d| d.to_vec()), m.rev
                    ],
                )?;
                if n == 0 {
                    return Ok(Imported::Nothing);
                }
                if live {
                    let mine = m.author[..] == me.0[..];
                    let read_upto: i64 = c.query_row("SELECT read_upto FROM convs WHERE id=?1", params![m.conv], |r| r.get(0)).optional()?.unwrap_or(0);
                    let unread = !mine && m.hlc > read_upto && !m.deleted && m.kind != "system";
                    c.execute(
                        "UPDATE convs SET last_ts=MAX(last_ts,?2), unread=unread+?3 WHERE id=?1",
                        params![m.conv, m.hlc >> 8, unread as i64],
                    )?;
                }
                self.track(c, K_MSG, &m.id);
                Ok(Imported::MsgNew { conv: m.conv.clone(), id: m.id.to_vec() })
            }
            Some((rev, status, deleted, conv)) => {
                let mut changed = false;
                if m.status > status && status != 9 {
                    changed |= c.execute("UPDATE messages SET status=?2 WHERE id=?1", params![&m.id[..], m.status])? > 0;
                }
                if m.deleted && deleted == 0 {
                    changed |= c.execute("UPDATE messages SET deleted=1, body='{}' WHERE id=?1", params![&m.id[..]])? > 0;
                }
                let mr_key = format!("mr:{}", hex::encode(&m.id[..]));
                let local_mr = Self::lww_get(c, &mr_key).unwrap_or(0);
                let take_mine = m.my_rev > local_mr;
                // the text: the latest edit (by its signed time, the same order the friend
                // uses) wins — not whichever device's row changed last for another reason
                let ed_key = format!("ed:{}", hex::encode(&m.id[..]));
                let local_ed = Self::lww_get(c, &ed_key).unwrap_or(0);
                let (local_body, local_reactions): (String, String) =
                    c.query_row("SELECT body, reactions FROM messages WHERE id=?1", params![&m.id[..]], |r| Ok((r.get(0)?, r.get(1)?)))?;
                let take_body = if m.edit_hlc != 0 || local_ed != 0 {
                    (Self::edit_rank(m.edit_hlc, &m.body), &m.body) > (Self::edit_rank(local_ed, &local_body), &local_body)
                } else {
                    m.rev > rev
                };
                if take_body {
                    c.execute(
                        "UPDATE messages SET body=CASE WHEN deleted=1 THEN body ELSE ?2 END, edited=MAX(edited,?3) WHERE id=?1",
                        params![&m.id[..], m.body, m.edited as i64],
                    )?;
                    if m.edit_hlc > local_ed {
                        Self::lww_set(c, &ed_key, m.edit_hlc)?;
                    }
                    changed = true;
                }
                if m.rev > rev || take_mine {
                    // an older sibling (no stamps for my reactions on either side): the whole row
                    // wins as before; otherwise my reactions come from whoever changed them last
                    // and everyone else's stay as this device received them
                    let reactions = if m.my_rev == 0 && local_mr == 0 {
                        if m.reactions.is_empty() { "{}".to_string() } else { m.reactions.clone() }
                    } else {
                        merge_reactions(&local_reactions, &m.reactions, me, m.rev > rev, take_mine)
                    };
                    if m.rev > rev {
                        c.execute(
                            "UPDATE messages SET reactions=?2, pinned=?3, meta=?4, rev=?5, device=COALESCE(device,?6) WHERE id=?1",
                            params![
                                &m.id[..], reactions, m.pinned as i64, if m.meta.is_empty() { "{}".to_string() } else { m.meta.clone() }, m.rev,
                                m.device.as_ref().map(|d| d.to_vec())
                            ],
                        )?;
                    } else {
                        c.execute("UPDATE messages SET reactions=?2 WHERE id=?1", params![&m.id[..], reactions])?;
                    }
                    if take_mine {
                        Self::lww_set(c, &mr_key, m.my_rev)?;
                        self.observe_rev(m.my_rev);
                    }
                    changed = true;
                }
                if changed {
                    self.track(c, K_MSG, &m.id);
                    Ok(Imported::MsgUpdated { conv, id: m.id.to_vec() })
                } else {
                    Ok(Imported::Nothing)
                }
            }
        }
    }

    fn import_conv(&self, c: &Connection, r: &ConvRow, me: &PeerId) -> Result<Imported> {
        self.observe_rev(r.rev);
        let local: Option<ConvRow> = c.query_row(&format!("SELECT {CONV_COLS} FROM convs WHERE id=?1"), params![r.id], row_convrow).optional()?;
        let Some(l) = local else {
            // a chat deleted here: only a copy with newer activity brings it back (cleared)
            let gone: Option<i64> = c.query_row("SELECT upto FROM conv_gone WHERE id=?1", params![r.id], |x| x.get(0)).optional()?;
            if let Some(g) = gone {
                if r.last_ts <= crate::util::hlc_to_ms(g.max(0) as u64) as i64 {
                    return Ok(Imported::Nothing);
                }
            }
            let r = &ConvRow { cleared_upto: r.cleared_upto.max(gone.unwrap_or(0)), ..r.clone() };
            c.execute(
                &format!("INSERT OR IGNORE INTO convs({CONV_COLS}) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)"),
                params![
                    r.id, r.kind, r.title, r.last_ts, r.last_text, r.unread, r.muted as i64, r.pinned as i64, r.archived as i64,
                    r.read_upto, r.cleared_upto, r.rev
                ],
            )?;
            if r.frev.len() == CONV_FLAGS.len() {
                for (i, f) in CONV_FLAGS.iter().enumerate() {
                    Self::lww_set(c, &format!("cf:{}:{f}", r.id), r.frev[i])?;
                }
            }
            self.track(c, K_CONV, r.id.as_bytes());
            return Ok(Imported::Conv { conv: r.id.clone(), cleared_upto: None });
        };
        let mut changed = false;
        if r.frev.len() == CONV_FLAGS.len() {
            // flag by flag: the newest change of each wins
            let mine = Self::conv_flag_revs(c, &r.id, l.rev);
            let vals = [r.muted, r.pinned, r.archived];
            for (i, f) in CONV_FLAGS.iter().enumerate() {
                if r.frev[i] > mine[i] {
                    self.observe_rev(r.frev[i]);
                    c.execute(&format!("UPDATE convs SET {f}=?2 WHERE id=?1"), params![r.id, vals[i] as i64])?;
                    Self::lww_set(c, &format!("cf:{}:{f}", r.id), r.frev[i])?;
                    changed = true;
                }
            }
            if r.rev > l.rev {
                c.execute("UPDATE convs SET rev=?2 WHERE id=?1", params![r.id, r.rev])?;
            }
        } else if r.rev > l.rev {
            c.execute(
                "UPDATE convs SET muted=?2, pinned=?3, archived=?4, rev=?5 WHERE id=?1",
                params![r.id, r.muted as i64, r.pinned as i64, r.archived as i64, r.rev],
            )?;
            changed = true;
        }
        if r.read_upto > l.read_upto {
            c.execute("UPDATE convs SET read_upto=?2 WHERE id=?1", params![r.id, r.read_upto])?;
            // what's left unread here, and our copies of their messages count as read
            c.execute(
                "UPDATE messages SET status=3 WHERE conv=?1 AND author<>?2 AND hlc<=?3 AND status<3",
                params![r.id, &me.0[..], r.read_upto],
            )?;
            let unread: i64 = c.query_row(
                "SELECT count(*) FROM messages WHERE conv=?1 AND author<>?2 AND hlc>?3 AND deleted=0 AND kind<>'system'",
                params![r.id, &me.0[..], r.read_upto],
                |x| x.get(0),
            )?;
            c.execute("UPDATE convs SET unread=MIN(unread,?2) WHERE id=?1", params![r.id, unread])?;
            changed = true;
        }
        let mut cleared = None;
        if r.cleared_upto > l.cleared_upto {
            cleared = Some(r.cleared_upto); // the node clears (files, events) and records it
            changed = true;
        }
        if changed {
            self.track(c, K_CONV, r.id.as_bytes());
            Ok(Imported::Conv { conv: r.id.clone(), cleared_upto: cleared })
        } else {
            Ok(Imported::Nothing)
        }
    }

    fn import_contact(&self, c: &Connection, r: &ContactRow) -> Result<Imported> {
        let Some(p) = pid(&r.peer) else { return Ok(Imported::Nothing) };
        self.observe_rev(r.rev);
        let local: Option<ContactRow> =
            c.query_row(&format!("SELECT {CONTACT_COLS} FROM contacts WHERE peer=?1"), params![&r.peer[..]], row_contactrow).optional()?;
        match local {
            None => {
                c.execute(
                    &format!("INSERT OR IGNORE INTO contacts({CONTACT_COLS}) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)"),
                    params![
                        &r.peer[..], r.name, r.alias, r.status, r.added, r.verified as i64, if r.relays.is_empty() { "[]".to_string() } else { r.relays.clone() },
                        r.bio, r.bot, r.username, r.avatar.as_ref().map(|a| a.to_vec()), r.cover.as_ref().map(|a| a.to_vec()), r.rev
                    ],
                )?;
                self.track(c, K_CONTACT, &r.peer);
                Ok(Imported::Contact { peer: p })
            }
            Some(l) => {
                let mut changed = false;
                if r.rev > l.rev {
                    c.execute(
                        "UPDATE contacts SET status=?2, alias=?3, verified=?4, rev=?5 WHERE peer=?1",
                        params![&r.peer[..], r.status, r.alias, r.verified as i64, r.rev],
                    )?;
                    changed = true;
                }
                // fill what this device hasn't heard from the friend yet
                if l.name.is_empty() && !r.name.is_empty() {
                    changed |= c.execute("UPDATE contacts SET name=?2 WHERE peer=?1", params![&r.peer[..], r.name])? > 0;
                }
                if l.avatar.is_none() && r.avatar.is_some() {
                    changed |= c.execute(
                        "UPDATE contacts SET avatar=?2, cover=COALESCE(cover,?3), bio=CASE WHEN bio='' THEN ?4 ELSE bio END WHERE peer=?1",
                        params![&r.peer[..], r.avatar.as_ref().map(|a| a.to_vec()), r.cover.as_ref().map(|a| a.to_vec()), r.bio],
                    )? > 0;
                }
                if changed {
                    self.track(c, K_CONTACT, &r.peer);
                    Ok(Imported::Contact { peer: p })
                } else {
                    Ok(Imported::Nothing)
                }
            }
        }
    }

    // ------------------------------------------------------------ bootstrap / history export

    /// Everything small a new device needs, as items (profile, contacts, conversations,
    /// groups and all their keys, cached device lists, stickers, trusted remote peers).
    pub fn bootstrap_items(&self) -> Vec<SyncItem> {
        let c = self.conn.lock();
        let mut out = vec![];
        if let Ok(mut st) = c.prepare("SELECT k, v FROM kv") {
            let rows: Vec<(String, Vec<u8>)> = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).map(|it| it.filter_map(|r| r.ok()).collect()).unwrap_or_default();
            for (k, v) in rows {
                if k.starts_with("peer.proto.") {
                    out.push(SyncItem::Kv { key: k, value: Some(ByteBuf::from(v)), rev: 0 });
                } else if kv_synced(&k) {
                    let rev: i64 = c.query_row("SELECT rev FROM lww WHERE key=?1", params![format!("kv:{k}")], |r| r.get(0)).optional().ok().flatten().unwrap_or(1);
                    out.push(SyncItem::Kv { key: k, value: Some(ByteBuf::from(v)), rev: rev.max(1) });
                }
            }
        }
        let mut grab = |sql: &str, f: &dyn Fn(&rusqlite::Row) -> rusqlite::Result<SyncItem>| {
            if let Ok(mut st) = c.prepare(sql) {
                if let Ok(it) = st.query_map([], f) {
                    out.extend(it.filter_map(|r| r.ok()));
                }
            }
        };
        grab(&format!("SELECT {CONTACT_COLS} FROM contacts WHERE status>0"), &|r| row_contactrow(r).map(SyncItem::Contact));
        grab(&format!("SELECT {CONV_COLS} FROM convs"), &|r| row_convrow(r).map(SyncItem::Conv));
        grab("SELECT id, state FROM groups", &|r| {
            Ok(SyncItem::Group { gid: ByteBuf::from(r.get::<_, Vec<u8>>(0)?), state: ByteBuf::from(r.get::<_, Vec<u8>>(1)?) })
        });
        grab("SELECT gid, epoch, key FROM group_keys", &|r| {
            Ok(SyncItem::GroupKey { gid: ByteBuf::from(r.get::<_, Vec<u8>>(0)?), epoch: r.get::<_, i64>(1)? as u64, key: ByteBuf::from(r.get::<_, Vec<u8>>(2)?) })
        });
        grab("SELECT list FROM device_lists", &|r| Ok(SyncItem::DeviceList { list: ByteBuf::from(r.get::<_, Vec<u8>>(0)?) }));
        grab("SELECT peer, perms FROM remote_trusted", &|r| Ok(SyncItem::RemoteTrusted { peer: ByteBuf::from(r.get::<_, Vec<u8>>(0)?), perms: r.get(1)? }));
        grab("SELECT id, name, created FROM sticker_packs", &|r| Ok(SyncItem::StickerPack { id: r.get(0)?, name: r.get(1)?, created: r.get(2)? }));
        grab("SELECT hash, pack, mime, emoji, animated FROM stickers", &|r| {
            Ok(SyncItem::Sticker { hash: ByteBuf::from(r.get::<_, Vec<u8>>(0)?), pack: r.get(1)?, mime: r.get(2)?, emoji: r.get(3)?, animated: r.get::<_, i64>(4)? != 0 })
        });
        grab("SELECT b.hash, b.mime, b.data FROM sticker_blobs b WHERE b.hash IN (SELECT hash FROM stickers)", &|r| {
            Ok(SyncItem::StickerBlob { hash: ByteBuf::from(r.get::<_, Vec<u8>>(0)?), mime: r.get(1)?, data: ByteBuf::from(r.get::<_, Vec<u8>>(2)?) })
        });
        out
    }

    /// Number of conversations with history in the window (progress display).
    pub fn history_conv_count(&self, since_hlc: i64) -> u32 {
        self.conn
            .lock()
            .query_row("SELECT count(DISTINCT conv) FROM messages WHERE hlc>=?1", params![since_hlc], |r| r.get::<_, i64>(0))
            .unwrap_or(0) as u32
    }

    /// Next page of history after `cur` (messages with hlc ≥ `since_hlc`, then the group
    /// log rows and file rows of that window). Returns (items, next cursor, done).
    pub fn history_page(&self, cur: &HistCursor, since_hlc: i64, limit: usize) -> (Vec<SyncItem>, HistCursor, bool) {
        let c = self.conn.lock();
        let limit = limit.clamp(1, 2000) as i64;
        let mut next = cur.clone();
        if cur.stage == 0 {
            let rows: Vec<MsgRow> = c
                .prepare_cached(&format!(
                    "SELECT {MSG_COLS} FROM messages WHERE hlc>=?1 AND (conv>?2 OR (conv=?2 AND (hlc>?3 OR (hlc=?3 AND id>?4))))
                     AND NOT EXISTS (SELECT 1 FROM retention r WHERE r.conv=messages.conv AND (r.ms=-1 OR (r.ms>0 AND (messages.hlc>>8) < ?6 - r.ms)))
                     ORDER BY conv, hlc, id LIMIT ?5"
                ))
                .and_then(|mut st| {
                    st.query_map(params![since_hlc, cur.conv, cur.hlc, &cur.id[..], limit, crate::util::now_ms() as i64], row_msgrow)
                        .map(|it| it.filter_map(|r| r.ok()).collect())
                })
                .unwrap_or_default();
            if let Some(last) = rows.last() {
                next.conv = last.conv.clone();
                next.hlc = last.hlc;
                next.id = last.id.clone();
            }
            if (rows.len() as i64) < limit {
                next = HistCursor { stage: 1, ..Default::default() };
            }
            return (rows.into_iter().map(SyncItem::Msg).collect(), next, false);
        }
        if cur.stage == 1 {
            let rows: Vec<SyncItem> = c
                .prepare_cached("SELECT id, gid, author, hlc, env FROM group_log WHERE hlc>=?1 AND id>?2 AND length(env)>0 ORDER BY id LIMIT ?3")
                .and_then(|mut st| {
                    st.query_map(params![since_hlc, &cur.id[..], limit], |r| {
                        Ok(SyncItem::GroupLog {
                            id: ByteBuf::from(r.get::<_, Vec<u8>>(0)?),
                            gid: ByteBuf::from(r.get::<_, Vec<u8>>(1)?),
                            author: ByteBuf::from(r.get::<_, Vec<u8>>(2)?),
                            hlc: r.get(3)?,
                            env: ByteBuf::from(r.get::<_, Vec<u8>>(4)?),
                        })
                    })
                    .map(|it| it.filter_map(|r| r.ok()).collect())
                })
                .unwrap_or_default();
            if let Some(SyncItem::GroupLog { id, .. }) = rows.last() {
                next.id = id.clone();
            }
            if (rows.len() as i64) < limit {
                next = HistCursor { stage: 2, ..Default::default() };
            }
            return (rows, next, false);
        }
        if cur.stage == 2 {
            // file rows we can serve: our uploads and finished downloads in the window
            let since_ms = since_hlc >> 8;
            let rows: Vec<SyncItem> = c
                .prepare_cached(
                    "SELECT id,conv,peer,name,size,hash,path,direction,state,progress,created FROM files
                     WHERE created>=?1 AND id>?2 AND (direction=0 OR state=2) ORDER BY id LIMIT ?3",
                )
                .and_then(|mut st| st.query_map(params![since_ms, &cur.id[..], limit], Self::row_file).map(|it| it.filter_map(|r| r.ok()).map(SyncItem::File).collect()))
                .unwrap_or_default();
            if let Some(SyncItem::File(f)) = rows.last() {
                next.id = ByteBuf::from(hex::decode(&f.id).unwrap_or_default());
            }
            if (rows.len() as i64) < limit {
                next = HistCursor { stage: 3, ..Default::default() };
            }
            let done = next.stage == 3;
            return (rows, next, done);
        }
        (vec![], HistCursor { stage: 3, ..Default::default() }, true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::devices::{DeviceEntry, Revoked};

    fn msg(s: &Store, id: u8, conv: &str, author: &PeerId, hlc: u64) {
        s.insert_message(&[id; 16], conv, author, hlc, "text", &serde_json::json!({"text": format!("m{id}")}), 2, None, None).unwrap();
    }

    #[test]
    fn history_cursor_is_stable_across_inserts_and_deletes() {
        let s = Store::open_memory().unwrap();
        let a = PeerId([1; 32]);
        for i in 1..=20u8 {
            msg(&s, i, if i % 2 == 0 { "d:x" } else { "d:y" }, &a, (i as u64) << 8);
        }
        let mut cur = HistCursor::default();
        let mut got = vec![];
        let mut pages = 0;
        loop {
            let (items, next, done) = s.history_page(&cur, 0, 3);
            for it in &items {
                if let SyncItem::Msg(m) = it {
                    got.push(m.id[0]);
                }
            }
            pages += 1;
            if pages == 2 {
                // a delete behind the cursor and an insert ahead of it don't disturb paging
                s.purge_message(&[got[0]; 16]).unwrap();
                msg(&s, 99, "d:z", &a, 50 << 8);
            }
            cur = next;
            if done {
                break;
            }
        }
        let mut expect: Vec<u8> = (1..=20).collect();
        expect.push(99);
        let mut sorted = got.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), got.len(), "no duplicates");
        assert_eq!(sorted, expect);
        // window: only hlc >= since
        let (items, _, _) = s.history_page(&HistCursor::default(), 15 << 8, 100);
        assert!(items.iter().all(|i| matches!(i, SyncItem::Msg(m) if m.hlc >= 15 << 8)));
    }

    #[test]
    fn import_batch_is_idempotent_and_merges() {
        let src = Store::open_memory().unwrap();
        let dst = Store::open_memory().unwrap();
        let me = PeerId([9; 32]);
        let a = PeerId([1; 32]);
        src.ensure_conv("d:x", 0, "X").unwrap();
        msg(&src, 1, "d:x", &a, 5 << 8);
        let items: Vec<SyncItem> = [src.sync_export(K_CONV, b"d:x").unwrap(), src.sync_export(K_MSG, &[1; 16]).unwrap()].to_vec();
        let r1 = dst.sync_import_batch(&items, &me, true).unwrap();
        assert!(r1.iter().any(|r| matches!(r, Imported::MsgNew { .. })));
        let r2 = dst.sync_import_batch(&items, &me, true).unwrap();
        assert!(r2.iter().all(|r| *r == Imported::Nothing), "{r2:?}");
        assert_eq!(dst.messages("d:x", None, 10).unwrap().len(), 1);
        assert_eq!(dst.conversations().unwrap()[0].unread, 1);
        // a newer edit wins, an older one doesn't; status only moves forward
        src.react(&[1; 16], &a, "👍", true).unwrap();
        src.set_message_status(&[1; 16], 3).unwrap();
        let newer = src.sync_export(K_MSG, &[1; 16]).unwrap();
        assert!(matches!(dst.sync_import(&newer, &me, true).unwrap(), Imported::MsgUpdated { .. }));
        assert_eq!(dst.message(&[1; 16]).unwrap().status, 3);
        assert!(dst.message(&[1; 16]).unwrap().reactions["👍"].is_array());
        let SyncItem::Msg(mut old) = newer.clone() else { panic!() };
        old.rev -= 10;
        old.reactions = "{}".into();
        old.status = 1;
        assert_eq!(dst.sync_import(&SyncItem::Msg(old), &me, true).unwrap(), Imported::Nothing);
        assert_eq!(dst.message(&[1; 16]).unwrap().status, 3);
        // read position: max wins and clears unread
        src.conv_mark_read("d:x").unwrap();
        let conv = src.sync_export(K_CONV, b"d:x").unwrap();
        dst.sync_import(&conv, &me, true).unwrap();
        assert_eq!(dst.conversations().unwrap()[0].unread, 0);
        // purge tombstone
        src.purge_message(&[1; 16]).unwrap();
        let p = src.sync_export(K_PURGE, &[1; 16]).unwrap();
        assert!(matches!(dst.sync_import(&p, &me, true).unwrap(), Imported::MsgPurged { .. }));
        assert!(dst.message(&[1; 16]).is_none());
    }

    /// A chat's history policy follows the user to their other devices (and to a new one
    /// at bootstrap), and history transfer leaves out what the policy no longer keeps.
    #[test]
    fn retention_syncs_and_limits_history() {
        let src = Store::open_memory().unwrap();
        let dst = Store::open_memory().unwrap();
        let me = PeerId([9; 32]);
        let a = PeerId([1; 32]);
        src.set_sync_enabled(true);
        src.set_retention("d:x", Some(86_400_000)).unwrap();
        src.set_retention("d:s", Some(-1)).unwrap();
        for key in ["retention.d:x", "retention.d:s"] {
            let it = src.sync_export(K_KV, key.as_bytes()).expect("synced");
            dst.sync_import(&it, &me, true).unwrap();
        }
        assert_eq!(dst.retention("d:x"), Some(86_400_000));
        assert_eq!(dst.retention("d:s"), Some(-1));
        assert!(src.bootstrap_items().iter().any(|i| matches!(i, SyncItem::Kv { key, .. } if key == "retention.d:x")));
        src.set_retention("d:x", None).unwrap();
        dst.sync_import(&src.sync_export(K_KV, b"retention.d:x").unwrap(), &me, true).unwrap();
        assert_eq!(dst.retention("d:x"), None);
        // history pages skip session-only chats and messages outside a window
        let now = crate::util::now_ms();
        msg(&src, 1, "d:s", &a, now << 8);
        src.set_retention("d:w", Some(3_600_000)).unwrap();
        msg(&src, 2, "d:w", &a, (now - 7_200_000) << 8);
        msg(&src, 3, "d:w", &a, now << 8);
        let (items, _, _) = src.history_page(&HistCursor::default(), 0, 100);
        let ids: Vec<u8> = items.iter().filter_map(|i| if let SyncItem::Msg(m) = i { Some(m.id[0]) } else { None }).collect();
        assert_eq!(ids, vec![3]);
    }

    /// A history transfer carries messages, group log rows and file rows to the new device.
    #[test]
    fn history_transfer_carries_files_and_group_log() {
        let src = Store::open_memory().unwrap();
        let dst = Store::open_memory().unwrap();
        let me = PeerId([9; 32]);
        let now = crate::util::now_ms();
        src.ensure_conv("d:x", 0, "x").unwrap();
        msg(&src, 1, "d:x", &me, now << 8);
        src.group_log_put_ex(&[7; 16], &[1; 16], &me, now << 8, b"env", 2, Some(&[1; 16])).unwrap();
        let f = crate::store::FileRow {
            id: hex::encode([5u8; 16]), conv: "d:x".into(), peer: me.to_base32(), name: "a.bin".into(), size: 3,
            hash: hex::encode([1u8; 32]), path: "/tmp/a.bin".into(), direction: 0, state: 2, progress: 3, created: now as i64,
        };
        src.file_put(&f).unwrap();
        let mut cur = HistCursor::default();
        loop {
            let (items, next, done) = src.history_page(&cur, ((now - 60_000) << 8) as i64, 200);
            dst.sync_import_batch(&items, &me, false).unwrap();
            cur = next;
            if done {
                break;
            }
        }
        assert!(dst.message(&[1; 16]).is_some());
        assert!(dst.group_log_has(&[7; 16]));
        assert_eq!(dst.file_get(&[5; 16]).map(|f| f.state), Some(7), "file row not copied");
    }

    #[test]
    fn sync_log_tracks_only_when_enabled_and_trims() {
        let s = Store::open_memory().unwrap();
        let a = PeerId([1; 32]);
        msg(&s, 1, "d:x", &a, 1);
        assert_eq!(s.sync_head(), 0, "single device: nothing logged");
        s.set_sync_enabled(true);
        msg(&s, 2, "d:x", &a, 2);
        s.react(&[2; 16], &a, "❤️", true).unwrap();
        s.kv_set("profile.bio", b"hi").unwrap();
        s.kv_set("profile.bio", b"hi").unwrap(); // unchanged: no new entry
        s.kv_set("olm.account", b"secret").unwrap(); // device-local: never synced
        let log = s.sync_log_since(0, 100);
        assert_eq!(log.len(), 2, "{log:?}"); // msg 2 (latest entry only) + profile.bio
        assert!(log.iter().any(|(_, k, key)| *k == K_KV && key == b"profile.bio"));
        let head = s.sync_head();
        s.sync_log_trim(head).unwrap();
        assert!(s.sync_log_since(0, 100).is_empty());
        // LWW on settings
        let dst = Store::open_memory().unwrap();
        let it = s.sync_export(K_KV, b"profile.bio").unwrap();
        assert!(matches!(dst.sync_import(&it, &a, true).unwrap(), Imported::Kv { .. }));
        assert_eq!(dst.kv_get("profile.bio").unwrap(), b"hi");
        dst.kv_set("profile.bio", b"newer here").unwrap();
        assert_eq!(dst.sync_import(&it, &a, true).unwrap(), Imported::Nothing, "older value doesn't win");
        assert!(!s.sync_wants(K_KV, b"profile.bio", &[0]));
        assert!(dst.sync_wants(K_MSG, &[2; 16], &[1, 0]));
    }

    #[test]
    fn bots_made_on_one_device_reach_the_others_live() {
        // used to arrive only once, at link time: a bot made afterwards stayed on its device
        let a = PeerId([9; 32]);
        let src = Store::open_memory().unwrap();
        src.set_sync_enabled(true);
        src.kv_set("botfather.bots", b"list-v1").unwrap();
        assert!(src.sync_log_since(0, 100).iter().any(|(_, k, key)| *k == K_KV && key == b"botfather.bots"), "a change is logged for sync");
        let dst = Store::open_memory().unwrap();
        let it = src.sync_export(K_KV, b"botfather.bots").unwrap();
        assert!(matches!(dst.sync_import(&it, &a, true).unwrap(), Imported::Kv { .. }));
        assert_eq!(dst.kv_get("botfather.bots").unwrap(), b"list-v1");
        // a later change (new bot / revoked bot) replaces the older list
        src.kv_set("botfather.bots", b"list-v2").unwrap();
        let it2 = src.sync_export(K_KV, b"botfather.bots").unwrap();
        assert!(matches!(dst.sync_import(&it2, &a, true).unwrap(), Imported::Kv { .. }));
        assert_eq!(dst.kv_get("botfather.bots").unwrap(), b"list-v2");
    }

    /// One sibling-sync round src → dst, as node/sync.rs runs it (Have → Want → Items).
    fn push(src: &Store, dst: &Store, me: &PeerId) -> Vec<Imported> {
        let mut out = vec![];
        for (_, k, key) in src.sync_log_since(0, 100_000) {
            let d = src.sync_digest(k, &key).unwrap_or_default();
            if dst.sync_wants(k, &key, &d) {
                if let Some(it) = src.sync_export(k, &key) {
                    out.push(dst.sync_import(&it, me, true).unwrap());
                }
            }
        }
        out
    }

    fn sibs(n: usize) -> Vec<Store> {
        (0..n)
            .map(|_| {
                let s = Store::open_memory().unwrap();
                s.set_sync_enabled(true);
                s
            })
            .collect()
    }

    /// Regression (matrix "delete for me"): a sibling that hadn't heard of the deletion yet
    /// (or a friend's late copy) brought the message back on every device.
    #[test]
    fn deleted_for_me_stays_deleted() {
        let me = PeerId([1; 32]);
        let f = PeerId([2; 32]);
        let d = sibs(3);
        for s in &d {
            msg(s, 7, "d:f", &f, 10 << 8);
        }
        assert!(d[0].purge_message(&[7; 16]).unwrap());
        push(&d[0], &d[1], &me);
        assert!(d[1].message(&[7; 16]).is_none(), "purge synced");
        push(&d[2], &d[1], &me); // d[2] still has it and logged it
        push(&d[2], &d[0], &me);
        assert!(d[1].message(&[7; 16]).is_none() && d[0].message(&[7; 16]).is_none(), "not brought back by a stale sibling");
        msg(&d[1], 7, "d:f", &f, 10 << 8); // the friend's copy arriving late
        assert!(d[1].message(&[7; 16]).is_none(), "not brought back by a late copy");
        push(&d[0], &d[2], &me);
        assert!(d[2].message(&[7; 16]).is_none());
    }

    /// A deleted chat: a stale sibling neither brings back the chat nor its old messages;
    /// a newer message does bring the chat back (with only what is new).
    #[test]
    fn deleted_chat_stays_deleted() {
        let me = PeerId([1; 32]);
        let f = PeerId([2; 32]);
        let d = sibs(2);
        for s in &d {
            s.ensure_conv("d:f", 0, "F").unwrap();
            msg(s, 1, "d:f", &f, 10 << 8);
            s.conv_touch("d:f", 10, "m1", false).unwrap();
        }
        d[0].clear_conv("d:f", 20 << 8).unwrap();
        d[0].delete_conv("d:f").unwrap();
        push(&d[1], &d[0], &me);
        assert!(d[0].conversations().unwrap().is_empty() && d[0].message(&[1; 16]).is_none(), "nothing came back");
        let it = d[0].sync_export(K_CONV_DEL, b"d:f").unwrap();
        assert!(matches!(it, SyncItem::ConvDel { upto, .. } if upto == 20 << 8));
        msg(&d[1], 2, "d:f", &f, 30 << 8);
        d[1].conv_touch("d:f", 30, "m2", false).unwrap();
        push(&d[1], &d[0], &me);
        assert!(d[0].message(&[2; 16]).is_some() && d[0].message(&[1; 16]).is_none(), "only the new message");
        assert_eq!(d[0].conv_cleared_upto("d:f"), Some(20 << 8));
        assert!(!d[0].insert_message(&[1; 16], "d:f", &f, 10 << 8, "text", &serde_json::json!({"text": "m1"}), 2, None, None).unwrap());
    }

    /// Regression: a chat pinned on one device and muted on another at the same time —
    /// the whole row used to win, so one of the two changes was lost.
    #[test]
    fn chat_flags_merge_one_by_one() {
        let me = PeerId([1; 32]);
        let d = sibs(2);
        for s in &d {
            s.ensure_conv("d:f", 0, "F").unwrap();
        }
        push(&d[0], &d[1], &me);
        d[0].conv_set_flag("d:f", "pinned", true).unwrap();
        d[1].conv_set_flag("d:f", "muted", true).unwrap(); // later stamp, pinned=0 in its row
        push(&d[1], &d[0], &me);
        push(&d[0], &d[1], &me);
        for s in &d {
            let c = &s.conversations().unwrap()[0];
            assert!(c.pinned && c.muted, "{c:?}");
        }
        // and a later unpin still wins
        d[1].conv_set_flag("d:f", "pinned", false).unwrap();
        push(&d[1], &d[0], &me);
        assert!(!d[0].conversations().unwrap()[0].pinned);
    }

    /// Regression (matrix races): my reaction on one device and a friend's reaction applied
    /// a moment later on another — the later row wiped my reaction; and a message copy that
    /// arrived late (fresh insert) beat the reactions / edits made meanwhile.
    #[test]
    fn my_reactions_merge_and_late_copies_lose() {
        let me = PeerId([1; 32]);
        let f = PeerId([2; 32]);
        let d = sibs(2);
        msg(&d[0], 5, "d:f", &f, 10 << 8);
        msg(&d[1], 5, "d:f", &f, 10 << 8);
        d[0].react(&[5; 16], &me, "🔥", true).unwrap();
        d[0].touch_my_reactions(&[5; 16]);
        // the friend's reaction reaches both devices directly, d[1] last
        d[0].react(&[5; 16], &f, "😂", true).unwrap();
        d[1].react(&[5; 16], &f, "😂", true).unwrap();
        push(&d[1], &d[0], &me);
        push(&d[0], &d[1], &me);
        for s in &d {
            let r = s.message(&[5; 16]).unwrap().reactions;
            assert!(r.get("🔥").is_some() && r.get("😂").is_some(), "{r}");
        }
        // I take mine back on d[1]: gone on d[0] too
        d[1].react(&[5; 16], &me, "🔥", false).unwrap();
        d[1].touch_my_reactions(&[5; 16]);
        push(&d[1], &d[0], &me);
        let r = d[0].message(&[5; 16]).unwrap().reactions;
        assert!(r.get("🔥").is_none() && r.get("😂").is_some(), "{r}");
        // a third device gets the message late from the friend: the reactions and an edit
        // made meanwhile win over its fresh copy
        let late = Store::open_memory().unwrap();
        late.set_sync_enabled(true);
        d[0].react(&[5; 16], &me, "👍", true).unwrap();
        d[0].touch_my_reactions(&[5; 16]);
        msg(&late, 5, "d:f", &f, 10 << 8);
        push(&d[0], &late, &me);
        assert!(late.message(&[5; 16]).unwrap().reactions.get("👍").is_some());
    }

    /// Regression (matrix races): the same setting changed on two devices in the same
    /// millisecond got equal stamps, and each device kept its own value for good.
    #[test]
    fn simultaneous_changes_never_tie() {
        let me = PeerId([1; 32]);
        let d = sibs(2);
        d[0].set_rev_device(&PeerId([10; 32]));
        d[1].set_rev_device(&PeerId([11; 32]));
        assert_ne!(d[0].rev_salt.load(Ordering::Relaxed), d[1].rev_salt.load(Ordering::Relaxed));
        for i in 0..20 {
            d[0].kv_set("profile.name", format!("A{i}").as_bytes()).unwrap();
            d[1].kv_set("profile.name", format!("B{i}").as_bytes()).unwrap();
            push(&d[0], &d[1], &me);
            push(&d[1], &d[0], &me);
            assert_eq!(d[0].kv_get("profile.name"), d[1].kv_get("profile.name"), "round {i}");
        }
        let (a, b) = (d[0].next_rev(), d[0].next_rev());
        assert!(b > a && a % 1000 == b % 1000 && a % 1000 != d[1].next_rev() % 1000);
    }

    /// Regression (matrix race): the same message edited on two of my devices at once —
    /// my devices settled on one text, the friend (arrival order) on the other.
    #[test]
    fn crossing_edits_settle_on_the_latest_signed_one() {
        let me = PeerId([1; 32]);
        let d = sibs(2);
        let friend = Store::open_memory().unwrap();
        for s in d.iter().chain(std::iter::once(&friend)) {
            msg(s, 4, "d:f", &me, 10 << 8);
        }
        let (old, new) = (serde_json::json!({"text": "older edit"}), serde_json::json!({"text": "newer edit"}));
        assert!(d[0].edit_message(&[4; 16], &me, &new, 50 << 8).unwrap());
        assert!(d[1].edit_message(&[4; 16], &me, &old, 40 << 8).unwrap());
        // the friend gets both, the older one last
        assert!(friend.edit_message(&[4; 16], &me, &new, 50 << 8).unwrap());
        assert!(!friend.edit_message(&[4; 16], &me, &old, 40 << 8).unwrap(), "an older edit arriving late is ignored");
        // d[1]'s row has the newer change stamp, but not the newer edit
        d[1].react(&[4; 16], &PeerId([2; 32]), "👍", true).unwrap();
        push(&d[1], &d[0], &me);
        push(&d[0], &d[1], &me);
        for s in d.iter().chain(std::iter::once(&friend)) {
            assert_eq!(s.message(&[4; 16]).unwrap().body["text"], "newer edit");
        }
    }

    #[test]
    fn edits_signed_in_the_same_instant_still_converge() {
        // two of my devices edit in the same millisecond: equal signed times. The losing
        // side must still see a different digest and ask for the winner (it didn't before:
        // the digest held only the time, so the side with the newer row stamp never asked).
        let me = PeerId([1; 32]);
        let d = sibs(2);
        let friend = Store::open_memory().unwrap();
        for s in d.iter().chain(std::iter::once(&friend)) {
            msg(s, 5, "d:f", &me, 10 << 8);
        }
        let (a, b) = (serde_json::json!({"text": "sửa từ M0"}), serde_json::json!({"text": "sửa từ M1"}));
        assert!(d[0].edit_message(&[5; 16], &me, &a, 60 << 8).unwrap());
        assert!(d[1].edit_message(&[5; 16], &me, &b, 60 << 8).unwrap());
        // the friend gets them in either order and settles on one
        friend.edit_message(&[5; 16], &me, &b, 60 << 8).unwrap();
        friend.edit_message(&[5; 16], &me, &a, 60 << 8).unwrap();
        let winner = friend.message(&[5; 16]).unwrap().body["text"].clone();
        // the device with the losing text has the newer row stamp
        let loser = if winner == "sửa từ M0" { 1 } else { 0 };
        d[loser].react(&[5; 16], &PeerId([2; 32]), "👍", true).unwrap();
        for _ in 0..2 {
            push(&d[0], &d[1], &me);
            push(&d[1], &d[0], &me);
        }
        for s in &d {
            assert_eq!(s.message(&[5; 16]).unwrap().body["text"], winner);
        }
        assert_eq!(d[0].sync_digest(K_MSG, &[5; 16]).unwrap()[3], d[1].sync_digest(K_MSG, &[5; 16]).unwrap()[3]);
    }

    #[test]
    fn sticker_packs_sync_live() {
        let me = PeerId([1; 32]);
        let d = sibs(2);
        d[0].sticker_pack_create("p1", "Mèo").unwrap();
        let h = [3u8; 32];
        d[0].sticker_blob_put(&h, "image/png", b"\x89PNG-data").unwrap();
        d[0].sticker_add(&h, "p1", "image/png", "😺", false).unwrap();
        let got = push(&d[0], &d[1], &me);
        assert!(got.contains(&Imported::Stickers));
        let packs = d[1].sticker_packs().unwrap();
        assert_eq!(packs.len(), 1);
        assert_eq!(packs[0]["stickers"].as_array().unwrap().len(), 1);
        assert!(d[1].sticker_blob(&h).is_some(), "the image came along");
        d[1].sticker_remove(&h, "p1").unwrap();
        push(&d[1], &d[0], &me);
        assert!(d[0].sticker_packs().unwrap()[0]["stickers"].as_array().unwrap().is_empty());
        d[0].sticker_pack_delete("p1").unwrap();
        push(&d[0], &d[1], &me);
        assert!(d[1].sticker_packs().unwrap().is_empty(), "deletion synced");
        // an older build's item kinds are skipped by decoders that don't know them
        let it = d[0].sync_export(K_SPACK, b"p1").unwrap();
        assert!(SyncItem::decode(&it.encode()).is_some());
    }

    #[test]
    fn device_list_rows_follow_the_list() {
        let s = Store::open_memory().unwrap();
        let acc = PeerId([1; 32]);
        let d1 = PeerId([2; 32]);
        let d2 = PeerId([3; 32]);
        s.upsert_contact(&d1, Some("stranger"), Some(0)).unwrap();
        let e = |d: PeerId, caps| DeviceEntry::new(d, "n", 1, caps, 1);
        let body = DeviceListBody { v: 1, account: acc, version: 1, devices: vec![e(acc, 1), e(d1, 0)], revoked: vec![] };
        s.device_list_put(b"L1", &body).unwrap();
        assert_eq!(s.device_account(&d1), Some(acc));
        assert!(s.contact(&d1).is_none(), "stranger row for a known device is dropped");
        assert_eq!(s.devices_of(&acc).iter().filter(|d| d.listed).count(), 2);
        let body2 = DeviceListBody { v: 1, account: acc, version: 2, devices: vec![e(acc, 1), e(d2, 0)], revoked: vec![Revoked { device: d1, at: 2, wipe: false }] };
        s.device_list_put(b"L2", &body2).unwrap();
        let devs = s.devices_of(&acc);
        assert_eq!(devs.iter().find(|d| d.device == d1).unwrap().revoked, Some(2));
        assert!(devs.iter().find(|d| d.device == d2).unwrap().listed);
        assert_eq!(s.device_list_get(&acc).unwrap(), (2, b"L2".to_vec()));
        assert!(s.device_learn(&PeerId([4; 32]), &acc, 0, 5).unwrap());
        assert!(!s.device_learn(&PeerId([4; 32]), &acc, 0, 5).unwrap());
    }
}
