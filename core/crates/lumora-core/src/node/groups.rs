//! Group chats and communities (servers with channels) on top of `crate::group`.

use super::*;
use crate::group::{self, key_commit, GroupOp, KeyUpdate, Payload, Role, Signed, Welcome};
use crate::proto::{Body, MsgAction, MsgMeta};

const GOSSIP_FANOUT: usize = 6;

/// Reporting messages / members to the group's admins, blocked groups (node/reports.rs).
#[path = "reports.rs"]
pub(super) mod reports;

fn conv_for(gid: &Gid, channel: &str) -> String {
    if channel.is_empty() {
        format!("g:{}", hex::encode(gid))
    } else {
        format!("g:{}#{}", hex::encode(gid), channel)
    }
}

pub(super) fn group_scope(gid: &Gid, channel: &str) -> Vec<u8> {
    let mut v = b"g".to_vec();
    v.extend_from_slice(gid);
    v.extend_from_slice(channel.as_bytes());
    v
}

const LIMIT_SYNC: u8 = 1;
const LIMIT_JOIN: u8 = 2;
/// Asking for a group key we miss: once a minute per epoch.
const LIMIT_KEYREQ: u8 = 3;
/// Answering key requests: a few per member and group, then one every 30 s.
const LIMIT_KEYSERVE: u8 = 4;
/// Envelopes of epochs ahead of ours we hold until their key arrives.
const MAX_FUTURE_EPOCHS: u64 = 64;
/// Ops dated further back than this (vs the newest op) are bogus (the outbox gives up
/// after 30 days, so nothing legit is older).
const MAX_OP_BACKDATE_MS: u64 = 30 * 86_400_000;
/// Someone who lost rights (removed, banned, demoted, left) may have signed ops shortly
/// before learning it (concurrency); ops it dates further back than this are not taken.
const RIGHTS_GRACE_MS: u64 = 3_600_000;
/// Receive-time quotas: what arrives in a day may be this many days' worth of the
/// creation-time quotas (catching up after being offline), never more — backdating
/// content can't multiply them without bound.
const RCV_QUOTA_FACTOR: u64 = 4;
/// How long a member waits for the key of a new epoch before asking for it.
const KEY_WAIT: Duration = if cfg!(test) { Duration::from_millis(300) } else { Duration::from_secs(15) };

/// Key rotations in progress / key requests scheduled, per (device, gid).
static ROTATING: Mutex<Option<std::collections::HashSet<(PeerId, Gid)>>> = parking_lot::const_mutex(None);
static KEY_WAITS: Mutex<Option<std::collections::HashSet<(PeerId, Gid, u64)>>> = parking_lot::const_mutex(None);

/// `Ext GROUP_KEY_REQUEST`: a member at an epoch it has no key for asks members for it.
#[derive(Serialize, Deserialize, Default)]
pub(super) struct GroupKeyRequestMsg {
    #[serde(default, with = "serde_bytes")]
    pub gid: Vec<u8>,
    #[serde(default)]
    pub epoch: u64,
}

/// What a group log row carries (store column `k`) and the message it is about.
fn log_kind(p: &Payload) -> (u8, Option<[u8; 16]>) {
    match p {
        Payload::Op(_) => (1, None),
        Payload::Msg { msg, .. } => (2, Some(msg.id)),
        Payload::Action { action, .. } => (3, action_target(action)),
    }
}

fn action_target(a: &MsgAction) -> Option<[u8; 16]> {
    match a {
        MsgAction::ClearHistory { .. } | MsgAction::PurgeAuthor { .. } | MsgAction::Callback { .. } => None,
        MsgAction::React { target, .. }
        | MsgAction::Vote { target, .. }
        | MsgAction::Pin { target, .. }
        | MsgAction::LiveLocation { target, .. }
        | MsgAction::Edit { target, .. }
        | MsgAction::ChecklistToggle { target, .. }
        | MsgAction::ChecklistAdd { target, .. }
        | MsgAction::ReminderCancel { target }
        | MsgAction::ReminderSeen { target }
        | MsgAction::Delete { target } => Some(*target),
    }
}
type GroupLimitKey = (u8, PeerId, PeerId, Gid); // (use, me, peer, gid): several nodes may share a process
static GROUP_LIMITS: Mutex<Option<HashMap<GroupLimitKey, (f64, Instant)>>> = parking_lot::const_mutex(None);

/// Token bucket for group work a remote peer can make us do over and over (serving our
/// whole log for a GroupSync, publishing an Add + Welcome for a join): `burst` at once,
/// then `per_s` per second.
fn group_bucket(key: GroupLimitKey, burst: f64, per_s: f64) -> bool {
    let mut g = GROUP_LIMITS.lock();
    let m = g.get_or_insert_with(HashMap::new);
    let now = Instant::now();
    if m.len() > 4096 {
        m.retain(|_, (_, t)| now.duration_since(*t) < Duration::from_secs(600));
    }
    let e = m.entry(key).or_insert((burst, now));
    e.0 = (e.0 + now.duration_since(e.1).as_secs_f64() * per_s).min(burst);
    e.1 = now;
    if e.0 >= 1.0 {
        e.0 -= 1.0;
        true
    } else {
        false
    }
}

// ---- anti-flood (per author, per group), judged by *creation* time (the envelope's
// signed hlc), never by arrival time: anti-entropy sync legitimately replays hundreds of
// old envelopes at once and each one is counted where it was written.
//
// Over-limit envelopes are rejected, not stored, and not forwarded. That is safe for
// history: the verdict depends only on the envelope's own time and the author's other
// envelopes around that time, so every member reaches (nearly) the same verdict and a
// re-sync can't turn a legit message into a lost one; anything under the limits is
// stored no matter how fast it arrives. (Deferring instead would break the per-author
// head anti-entropy: a later envelope stored first moves the head past the deferred one.)
// Admins/owners and my own devices are exempt (admins have their own tools).
/// Messages / reactions per author (signing device) in any minute of creation time.
pub(super) const FLOOD_PER_MIN: u64 = 60;
/// ... and in any hour.
pub(super) const FLOOD_PER_HOUR: u64 = 600;
/// Bytes one author may add to one group per day (creation time).
pub(super) const AUTHOR_DAY_BYTES: u64 = if cfg!(test) { 256 * 1024 } else { 32 * 1024 * 1024 };
/// Bytes all members together may add to one group per day (the group's storage quota).
pub(super) const GROUP_DAY_BYTES: u64 = if cfg!(test) { 384 * 1024 } else { 128 * 1024 * 1024 };
/// Content dated further ahead than this is bogus (and would drag our clock forward).
const MAX_FUTURE_MS: u64 = 86_400_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Flood {
    /// too many messages in a minute / an hour
    Rate,
    /// this author's daily share of the group is used up
    AuthorQuota,
    /// the group's daily storage quota is used up
    GroupQuota,
}

impl Flood {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Flood::Rate => "rate",
            Flood::AuthorQuota => "author_quota",
            Flood::GroupQuota => "group_quota",
        }
    }
    /// The error my own app shows when I would exceed a limit.
    pub(super) fn user_err(self) -> crate::i18n::UserError {
        crate::i18n::user_err(match self {
            Flood::Rate => "err.group_too_fast",
            Flood::AuthorQuota => "err.group_quota_you",
            Flood::GroupQuota => "err.group_quota",
        })
    }
}

/// Last `group_flood` event per (me, gid, author): at most one per 10 minutes.
type FloodNoticeKey = (PeerId, Gid, PeerId);
static FLOOD_NOTICES: Mutex<Option<HashMap<FloodNoticeKey, Instant>>> = parking_lot::const_mutex(None);

fn hlc_back(hlc: u64, ms: u64) -> u64 {
    hlc.saturating_sub(ms << 8)
}

impl Node {
    /// A membership op by a plain member: only the rate limits (ops are small; a picture
    /// change has its own limit in the fold).
    fn group_op_flood_check(&self, st: &GroupState, author: &PeerId, signer: &PeerId, hlc: u64) -> Option<Flood> {
        if st.role(author).unwrap_or(Role::Member) >= Role::Admin {
            return None;
        }
        let gid = &st.gid[..];
        let (per_min, _) = self.store.group_log_window(gid, signer, hlc_back(hlc, 60_000), hlc);
        let (per_hour, _) = self.store.group_log_window(gid, signer, hlc_back(hlc, 3_600_000), hlc);
        (per_min >= FLOOD_PER_MIN || per_hour >= FLOOD_PER_HOUR).then_some(Flood::Rate)
    }

    /// Would content by `author` (signed by device `signer`, created at `hlc`, `bytes` long)
    /// flood group `st`? None = fine.
    pub(super) fn group_flood_check(&self, st: &GroupState, author: &PeerId, signer: &PeerId, hlc: u64, bytes: u64) -> Option<Flood> {
        if st.role(author).unwrap_or(Role::Member) >= Role::Admin {
            return None;
        }
        let gid = &st.gid[..];
        let (per_min, _) = self.store.group_log_window(gid, signer, hlc_back(hlc, 60_000), hlc);
        if per_min >= FLOOD_PER_MIN {
            return Some(Flood::Rate);
        }
        let (per_hour, _) = self.store.group_log_window(gid, signer, hlc_back(hlc, 3_600_000), hlc);
        if per_hour >= FLOOD_PER_HOUR {
            return Some(Flood::Rate);
        }
        let (_, day_bytes) = self.store.group_log_window(gid, signer, hlc_back(hlc, 86_400_000), hlc);
        if day_bytes + bytes > AUTHOR_DAY_BYTES {
            return Some(Flood::AuthorQuota);
        }
        if self.store.group_log_bytes(gid, hlc_back(hlc, 86_400_000), hlc) + bytes > GROUP_DAY_BYTES {
            return Some(Flood::GroupQuota);
        }
        // ...and by arrival: content dated into many different past days still counts
        // against what this device takes in per day
        let (rcv_author, rcv_group) = self.store.group_log_rcv_bytes(gid, signer, crate::util::now_ms().saturating_sub(86_400_000));
        if rcv_author + bytes > RCV_QUOTA_FACTOR * AUTHOR_DAY_BYTES {
            return Some(Flood::AuthorQuota);
        }
        if rcv_group + bytes > RCV_QUOTA_FACTOR * GROUP_DAY_BYTES {
            return Some(Flood::GroupQuota);
        }
        None
    }

    /// A member's content was rejected as a flood: tell the UI (at most every 10 min per
    /// author). Admins get a slow-mode suggestion.
    fn on_group_flood(&self, st: &GroupState, author: &PeerId, why: Flood) {
        {
            let mut g = FLOOD_NOTICES.lock();
            let m = g.get_or_insert_with(HashMap::new);
            if m.len() > 1024 {
                m.retain(|_, t| t.elapsed() < Duration::from_secs(600));
            }
            let k = (self.me, st.gid, *author);
            if m.get(&k).map(|t| t.elapsed() < Duration::from_secs(600)).unwrap_or(false) {
                return;
            }
            m.insert(k, Instant::now());
        }
        let admin = st.role(&self.me).unwrap_or(Role::Member) >= Role::Admin;
        let suggest = if !admin || why != Flood::Rate {
            0
        } else if st.slow_mode_s >= 10 {
            (st.slow_mode_s * 2).min(300)
        } else {
            10
        };
        let name = self.display(author);
        let s = suggest.to_string();
        let text = match (why, admin) {
            (Flood::GroupQuota, _) => crate::i18n::trf("group.quota_full", &[]),
            (_, true) if suggest > 0 => crate::i18n::trf("group.flood_admin", &[("name", &name), ("s", &s)]),
            _ => crate::i18n::trf("group.flood_member", &[("name", &name)]),
        };
        tracing::info!("group {}: content from {author:?} rejected ({})", hex::encode(st.gid), why.as_str());
        self.emit(
            "group_flood",
            json!({"gid": hex::encode(st.gid), "conv": st.conv_id(), "author": author.to_base32(), "name": name,
                   "reason": why.as_str(), "admin": admin, "suggest_slow_mode_s": suggest, "text": text}),
        );
    }

    /// Joins (public group / invite link) we serve as admin: at most 30 at once, then one
    /// every 2 s per group — a flood of fresh identities can't grow the member list (and
    /// everyone's op log) without bound or keep this device busy publishing.
    pub(super) fn join_allowed(&self, gid: &Gid) -> bool {
        group_bucket((LIMIT_JOIN, self.me, PeerId([0; 32]), *gid), 30.0, 0.5)
    }

    pub(super) fn load_groups(&self) {
        let all: Vec<GroupState> = self.store.group_all().iter().filter_map(|b| crate::proto::from_slice_capped::<GroupState>(b).ok()).collect();
        for st in &all {
            // keys stored by an older version (first one wins) are checked against the
            // winning commitment once
            self.revalidate_keys(st);
        }
        let mut g = self.groups.write();
        for st in all {
            g.insert(st.gid, st);
        }
    }

    fn apply_community_retention(&self, st: &GroupState) {
        let days = self.storage_policy().community_days;
        if st.kind == 1 && days > 0 && self.store.retention(&st.conv_id()).is_none() {
            let _ = self.store.set_retention(&st.conv_id(), Some(days as i64 * 86_400_000));
            for ch in st.channels.iter() {
                let _ = self.store.set_retention(&conv_for(&st.gid, &ch.name), Some(days as i64 * 86_400_000));
            }
        }
    }

    fn group_lock(&self, gid: &Gid) -> Arc<tokio::sync::Mutex<()>> {
        let mut m = self.group_locks.lock();
        // keyed by remote input (envelopes/welcomes for any gid): drop idle locks so the map
        // can't grow forever (an idle lock has no holder, so dropping it is always safe)
        if m.len() > 1024 {
            m.retain(|_, l| Arc::strong_count(l) > 1);
        }
        m.entry(*gid).or_default().clone()
    }

    fn save_group(&self, st: &GroupState) -> Result<()> {
        self.store.group_save(&st.gid, &rmp_serde::to_vec(st)?)?;
        self.groups.write().insert(st.gid, st.clone());
        Ok(())
    }

    pub fn group_info(&self, gid: &Gid) -> Result<Value> {
        let g = self.groups.read().get(gid).cloned().ok_or_else(|| crate::i18n::user_err("err.group_not_found"))?;
        let members: Vec<Value> = g
            .members
            .iter()
            .map(|(p, r)| {
                let name = if *p == self.me {
                    self.name()
                } else {
                    self.display(p)
                };
                let contact = *p != self.me && self.store.contact(p).map(|c| c.status == 3).unwrap_or(false);
                json!({"peer": p.to_base32(), "name": name, "role": r.as_str(), "online": *p == self.me || self.is_online(p),
                       "short_id": p.short_id_fmt(), "friend": contact})
            })
            .collect();
        Ok(json!({
            "gid": hex::encode(g.gid), "conv": g.conv_id(), "name": g.name, "kind": g.kind,
            "owner": g.owner.to_base32(), "members": members, "epoch": g.epoch,
            "my_role": g.role(&self.me).map(|r| r.as_str()).unwrap_or("none"),
            "description": g.description, "has_avatar": !g.avatar.is_empty(),
            "slow_mode_s": g.slow_mode_s, "admins_only": g.admins_only,
            "banned": g.banned.iter().map(|p| p.to_base32()).collect::<Vec<_>>(),
            "public": g.public,
            "handle": if g.public && !g.handle.is_empty() { json!(format!("@{}·{}", g.handle, group::group_tag(&g.gid))) } else { Value::Null },
            "bots": g.bots.iter().map(|(p, all)| json!({"peer": p.to_base32(), "read_all": all})).collect::<Vec<_>>(),
            "channels": g.channels.iter().map(|c| json!({"name": c.name, "voice": c.voice, "conv": conv_for(&g.gid, &c.name)})).collect::<Vec<_>>(),
        }))
    }

    pub fn groups_list(&self) -> Vec<Value> {
        // (a blocked group is left; until that op lands it is hidden already)
        let gids: Vec<Gid> = self.groups.read().keys().copied().filter(|g| !self.group_blocked(g)).collect();
        gids.iter().filter_map(|g| self.group_info(g).ok()).collect()
    }

    /// Store a system line as `{code, args}` (+ English fallback) so every UI renders it in its own language.
    fn system_msg(&self, gid: &Gid, code: &str, args: &[(&str, &str)]) {
        let conv = conv_for(gid, "");
        let id: [u8; 16] = crate::crypto::random_bytes();
        let hlc = self.hlc.tick();
        let text = crate::i18n::trf(code, args);
        let argv: serde_json::Map<String, Value> = args.iter().map(|(k, v)| (k.to_string(), Value::String(v.to_string()))).collect();
        let body = json!({"text": crate::i18n::trf_en(code, args), "code": code, "args": argv});
        if self.store.insert_message(&id, &conv, &self.me, hlc, "system", &body, 2, None, None).unwrap_or(false) {
            let _ = self.store.conv_touch(&conv, crate::util::hlc_to_ms(hlc) as i64, &text, false);
            if let Some(m) = self.store.message(&id) {
                self.emit("message", self.msg_json(&m));
            }
        }
    }

    /// I left the group (here or on another of my devices): its chats (main + channels)
    /// are deleted like "delete chat" — a left group isn't kept as a read-only chat.
    fn forget_left_group(&self, gid: &Gid) {
        for conv in self.store.group_convs(&conv_for(gid, "")) {
            let _ = self.clear_local(&conv, u64::MAX, true);
        }
    }

    /// Whether I'm out of `st` because of my own Leave (not a Remove / Ban by an admin).
    fn my_exit_was_leave(&self, st: &GroupState) -> bool {
        st.ops
            .iter()
            .rev()
            .find_map(|o| match &o.payload {
                Payload::Op(GroupOp::Leave) if o.author == self.me => Some(true),
                Payload::Op(GroupOp::Remove { peer } | GroupOp::Ban { peer }) if *peer == self.me => Some(false),
                _ => None,
            })
            .unwrap_or(false)
    }

    fn display(&self, p: &PeerId) -> String {
        if *p == self.me {
            return self.name();
        }
        self.store
            .contact(p)
            .map(|c| c.alias.unwrap_or(c.name))
            .filter(|n| !n.is_empty())
            .or_else(|| self.member_name(p))
            .unwrap_or_else(|| p.short_id_fmt())
    }

    /// Name a non-contact group member introduced itself with (connection `Hello`).
    pub(super) fn member_name(&self, p: &PeerId) -> Option<String> {
        self.store.kv_get(&format!("member.name.{}", p.to_base32())).and_then(|v| String::from_utf8(v).ok()).filter(|n| !n.is_empty())
    }

    pub(super) fn set_member_name(&self, p: &PeerId, name: &str) {
        if self.member_name(p).as_deref() != Some(name) {
            let _ = self.store.kv_set(&format!("member.name.{}", p.to_base32()), name.as_bytes());
        }
    }

    pub async fn create_group(self: &Arc<Self>, name: &str, members: Vec<PeerId>, kind: u8) -> Result<Value> {
        let name = name.trim();
        anyhow::ensure!(!name.is_empty(), crate::i18n::user_err("err.group_name_empty"));
        let members: Vec<PeerId> = members.into_iter().filter(|m| *m != self.me).collect();
        let (st, op) = group::create(&self.signer, self.hlc.tick(), name, members.clone(), kind)?;
        let key: [u8; 32] = crate::crypto::random_bytes();
        self.store.group_key_put(&st.gid, 0, &key)?;
        let env = group::seal_envelope(&key, 0, &op)?;
        self.store.group_log_put(&op.id, &st.gid, &self.device, op.hlc, &env)?;
        self.save_group(&st)?;
        self.store.ensure_conv(&st.conv_id(), 1, &st.name)?;
        self.apply_community_retention(&st);
        for ch in st.channels.iter().filter(|c| !c.voice) {
            self.store.ensure_conv(&conv_for(&st.gid, &ch.name), 1, &format!("{} › #{}", st.name, ch.name))?;
        }
        self.system_msg(&st.gid, "sys.group_created", &[("actor", &self.name()), ("name", &st.name)]);
        for m in members {
            self.send_welcome(&st.gid, m).await?;
        }
        // and my other devices
        self.send_welcome(&st.gid, self.me).await?;
        self.emit("group", self.group_info(&st.gid)?);
        self.emit_conv(&st.conv_id());
        Ok(json!({"gid": hex::encode(st.gid), "conv": st.conv_id()}))
    }

    async fn send_welcome(self: &Arc<Self>, gid: &Gid, to: PeerId) -> Result<()> {
        let st = self.groups.read().get(gid).cloned().ok_or_else(|| anyhow!("no group"))?;
        let key = if st.is_private_bot(&to) {
            [0u8; 32] // privacy-mode bot: membership info only, never the key
        } else {
            self.store.group_key_get(gid, st.epoch).ok_or_else(|| anyhow!("missing group key"))?
        };
        let w = rmp_serde::to_vec(&Welcome { gid: *gid, ops: st.compact_ops(), epoch: st.epoch, key })?;
        anyhow::ensure!(w.len() + 64 * 1024 <= proto::MAX_CONTROL_FRAME, "group state too large to welcome ({} bytes)", w.len());
        // sealed to each device of the account (my own other devices when `to == me`)
        self.deliver_sealed(to, &w, |sealed| PeerMsg::GroupWelcome { sealed }).await
    }

    /// Seal `body` to every device of `to` (each gets its own copy) and deliver reliably.
    pub(super) async fn deliver_sealed(self: &Arc<Self>, to: PeerId, body: &[u8], wrap: impl Fn(Vec<u8>) -> PeerMsg) -> Result<()> {
        for dev in self.delivery_targets(&to) {
            if dev == self.device {
                continue;
            }
            let sealed = seal_to(&self.id, &dev, body)?;
            let id: [u8; 16] = crate::crypto::random_bytes();
            self.deliver_dev(dev, id, wrap(sealed), true).await;
        }
        Ok(())
    }

    /// Sign, encrypt with the current epoch key, store and fan out.
    async fn publish(self: &Arc<Self>, gid: Gid, payload: Payload) -> Result<Signed> {
        let lock = self.group_lock(&gid);
        let guard = lock.lock().await;
        let st = self.groups.read().get(&gid).cloned().ok_or_else(|| crate::i18n::user_err("err.group_not_found"))?;
        anyhow::ensure!(st.is_member(&self.me), crate::i18n::user_err("err.not_member"));
        let Some(key) = self.store.group_key_get(&gid, st.epoch) else {
            self.request_group_key(gid, st.epoch);
            return Err(crate::i18n::user_err("err.group_syncing").detail("missing group key").into());
        };
        let s = Signed::new(&self.signer, gid, self.hlc.tick(), payload);
        // members drop ops dated too far ahead: never apply locally what they would reject
        anyhow::ensure!(
            crate::util::hlc_to_ms(s.hlc) <= now_ms() + crate::util::MAX_FUTURE_OP_MS,
            crate::i18n::user_err("err.group_syncing").detail("local clock ahead of the group")
        );
        let env = group::seal_envelope(&key, st.epoch, &s)?;
        // members would reject it: say so here instead of sending it into the void
        let flood = match &s.payload {
            Payload::Op(GroupOp::Leave) => None,
            Payload::Op(_) => self.group_op_flood_check(&st, &self.me, &self.device, s.hlc),
            _ => self.group_flood_check(&st, &self.me, &self.device, s.hlc, env.len() as u64),
        };
        if let Some(why) = flood {
            return Err(why.user_err().into());
        }
        // apply first: an op the group's rules reject (no permission, a banned peer…) is
        // neither stored nor sent, and the caller learns it
        let applied = self.apply_group_payload(&st, &s).await?;
        if !applied && matches!(s.payload, Payload::Op(_)) {
            // never sent: it must not wait among the held ops either
            let mut held = self.store.group_held_get(&gid);
            held.retain(|h| h.id != s.id);
            let _ = self.store.group_held_set(&gid, &held);
            return Err(crate::i18n::user_err("err.group_op_rejected").into());
        }
        let (k, mid) = log_kind(&s.payload);
        self.store.group_log_put_ex(&s.id, &gid, &self.device, s.hlc, &env, k, mid.as_ref().map(|m| &m[..]))?;
        drop(guard);
        let members: Vec<PeerId> = self.groups.read().get(&gid).map(|g| g.key_holders()).unwrap_or_else(|| st.key_holders());
        // privacy-mode bots get only what is addressed to them
        if let Payload::Msg { channel, msg } = &s.payload {
            let cur = self.groups.read().get(&gid).cloned().unwrap_or(st.clone());
            for (bot, read_all) in cur.bots.iter() {
                if !*read_all && *bot != self.me && self.addressed_to_bot(bot, msg) {
                    let id: [u8; 16] = crate::crypto::random_bytes();
                    self.deliver(*bot, id, PeerMsg::BotGroupMsg { gid, channel: channel.clone(), msg: msg.clone() }, false).await;
                }
            }
        }
        let small = members.len() <= 64;
        // every device of every member, including my own other devices (`me` → siblings)
        for m in members {
            let msg = PeerMsg::Group { gid, env: env.clone() };
            if small {
                self.deliver(m, s.id, msg, true).await;
            } else {
                self.send_now(&m, msg);
            }
        }
        // removed/banned members still need to learn they were removed
        if let Payload::Op(GroupOp::Remove { peer } | GroupOp::Ban { peer }) = &s.payload {
            // The op is applied: they are no co-member any more, so the address gate would
            // hold this notice forever when we are not friends. We are the ones contacting
            // them (and they knew our addresses a moment ago): count it as solicited.
            for dev in self.delivery_targets(peer) {
                self.note_solicited(dev);
            }
            self.deliver(*peer, s.id, PeerMsg::Group { gid, env: env.clone() }, true).await;
        }
        // Privacy-mode bots hold no key, so they can't read the op above: keep their view of
        // the membership current (who may command them, who gets their replies, whether
        // they are still in the group) with the signed ops alone.
        if let Payload::Op(op) = &s.payload {
            let cur = self.groups.read().get(&gid).cloned().unwrap_or(st.clone());
            let mut bots: Vec<PeerId> = cur.bots.iter().filter(|(b, all)| !**all && **b != self.me && cur.is_member(b)).map(|(b, _)| *b).collect();
            if let GroupOp::Remove { peer } | GroupOp::Ban { peer } = op {
                if st.is_private_bot(peer) && *peer != self.me {
                    bots.push(*peer);
                }
            }
            for b in bots {
                if let Err(e) = self.send_bot_ops(&gid, b).await {
                    tracing::debug!("membership update to bot {b:?}: {e:#}");
                }
            }
        }
        Ok(s)
    }

    /// The group's signed ops without the key (privacy-mode bots, and a bot leaving).
    async fn send_bot_ops(self: &Arc<Self>, gid: &Gid, to: PeerId) -> Result<()> {
        let st = self.groups.read().get(gid).cloned().ok_or_else(|| anyhow!("no group"))?;
        let w = rmp_serde::to_vec(&Welcome { gid: *gid, ops: st.compact_ops(), epoch: st.epoch, key: [0u8; 32] })?;
        self.deliver_sealed(to, &w, |sealed| PeerMsg::GroupWelcome { sealed }).await
    }

    /// `from`: (account, device) of the connection it arrived on (None: offline mail).
    pub(super) async fn on_group_envelope(self: &Arc<Self>, from: Option<(PeerId, PeerId)>, gid: Gid, env: Vec<u8>, forward: bool) -> Result<()> {
        let lock = self.group_lock(&gid);
        let _guard = lock.lock().await;
        let Some(st) = self.groups.read().get(&gid).cloned() else { return Ok(()) };
        let epoch = group::envelope_epoch(&env).ok_or_else(|| anyhow!("bad env"))?;
        // the epoch's key, or the key of a concurrent rotation that lost (still valid for
        // what was sent under it)
        let keys = self.store.group_keys_all(&gid, epoch);
        let Some(s) = group::open_envelope_any(&keys, &gid, &env)? else {
            // A key we don't have (yet): an epoch ahead of ours, or a rotation we haven't
            // got the key of. Held (persisted, bounded) until it arrives — only from members.
            let from_member = from.map(|(f, _)| st.is_member(&f) || st.left.contains(&f)).unwrap_or(true);
            if from_member && epoch <= st.epoch.saturating_add(MAX_FUTURE_EPOCHS) {
                let _ = self.store.group_env_pending_put(&gid, epoch, &env);
                if epoch <= st.epoch && st.is_member(&self.me) && !st.is_private_bot(&self.me) {
                    self.request_group_key(gid, epoch);
                }
            }
            return Ok(());
        };
        // Author must be a member — or an ex-member: what it signed while it was one is
        // still valid (the fold / the checks below decide), so concurrent removals and
        // late history converge instead of depending on arrival order.
        let member_now = st.is_member(&s.author);
        if !member_now && !st.left.contains(&s.author) {
            return Ok(());
        }
        let signer = s.signer_device();
        if self.is_revoked(&s.author, &signer) {
            return Ok(()); // signed by a revoked device
        }
        if let Some(c) = crate::devices::devsig_cert(&s.author, &s.sig) {
            self.learn_cert(&c);
        }
        if let Payload::Op(op) = &s.payload {
            // Membership ops from any epoch (the fold orders them by creation time); never
            // far in the future, nor absurdly old.
            if crate::util::hlc_to_ms(s.hlc) > now_ms() + crate::util::MAX_FUTURE_OP_MS || s.hlc.saturating_add(MAX_OP_BACKDATE_MS << 8) < st.last_op_hlc {
                return Ok(());
            }
            // someone who lost its rights can't backdate ops to when it still had them
            // (beyond the concurrency window)
            if let Some(cut) = st.rights_cut(&s.author) {
                if s.hlc < cut && s.hlc.saturating_add(RIGHTS_GRACE_MS << 8) < cut {
                    return Ok(());
                }
            }
            if !matches!(op, GroupOp::Leave) && !self.store.group_log_has(&s.id) {
                if let Some(why) = self.group_op_flood_check(&st, &s.author, &signer, s.hlc) {
                    self.on_group_flood(&st, &s.author, why);
                    return Ok(());
                }
            }
        } else if s.author != self.me {
            // content can't predate its group, nor come from far in the future
            if s.hlc.saturating_add(600_000 << 8) < st.created || crate::util::hlc_to_ms(s.hlc) > now_ms() + MAX_FUTURE_MS {
                return Ok(());
            }
            // an ex-member's content: only what it wrote while it was a member
            if !member_now && st.role_at(&s.author, s.hlc).is_none() {
                return Ok(());
            }
            if !self.store.group_log_has(&s.id) {
                if let Some(why) = self.group_flood_check(&st, &s.author, &signer, s.hlc, env.len() as u64) {
                    self.on_group_flood(&st, &s.author, why);
                    return Ok(()); // not stored, not forwarded (see FLOOD_PER_MIN)
                }
            }
        }
        let (k, mid) = log_kind(&s.payload);
        // heads per signing device (== the author for primaries and older peers)
        if !self.store.group_log_put_ex(&s.id, &gid, &signer, s.hlc, &env, k, mid.as_ref().map(|m| &m[..]))? {
            return Ok(()); // seen
        }
        self.hlc.observe(s.hlc);
        self.apply_group_payload(&st, &s).await?;
        if forward {
            // Gossip with bounded fan-out: forward to at most GOSSIP_FANOUT random *connected*
            // members (not the sender/author). O(N·k) instead of O(N²) per message;
            // anti-entropy sync fills any gaps.
            use rand::seq::SliceRandom;
            let cur = self.groups.read().get(&gid).cloned();
            let from_dev = from.map(|(_, d)| d);
            let mut targets: Vec<Arc<PeerConn>> = self
                .connected_peers()
                .into_iter()
                .filter(|pc| {
                    cur.as_ref().map(|g| g.is_member(&pc.account)).unwrap_or(false)
                        && Some(pc.peer) != from_dev
                        && pc.peer != signer
                        && pc.peer != s.author
                })
                .collect();
            targets.shuffle(&mut rand::thread_rng());
            for pc in targets.into_iter().take(GOSSIP_FANOUT) {
                let _ = pc.ctl.try_send(PeerMsg::Group { gid, env: env.clone() });
            }
        }
        Ok(())
    }

    /// Apply a verified payload; false if the group's rules rejected it (not applied).
    async fn apply_group_payload(self: &Arc<Self>, before: &GroupState, s: &Signed) -> Result<bool> {
        let gid = before.gid;
        match &s.payload {
            Payload::Op(op) => {
                // (ops rejected earlier take part: an op that arrived before what makes it
                // valid — a promotion, an Add — is applied once that arrives)
                let mut held = self.store.group_held_get(&gid);
                let held_before = held.len();
                let (after, accepted) = before.with_op(s.clone(), &mut held)?;
                if held.len() != held_before || !accepted {
                    let _ = self.store.group_held_set(&gid, &held);
                }
                if !accepted {
                    if after.ops.len() != before.ops.len() {
                        // still, held ops may have become valid
                        self.save_group(&after)?;
                        self.after_group_change(&after);
                        self.emit("group", self.group_info(&gid)?);
                    }
                    return Ok(false);
                }
                self.save_group(&after)?;
                // a Rekey (ours, a concurrent one, or one that arrived late) may change which
                // key each epoch uses: check what we hold against the winning commitments
                if matches!(op, GroupOp::Rekey { .. }) && self.revalidate_keys(&after) {
                    self.retry_pending(gid);
                }
                let actor = self.display(&s.author);
                let peer_name = |p: &PeerId| self.display(p);
                // my own Leave (from this device or another of mine): the chat goes away
                let i_left = matches!(op, GroupOp::Leave) && s.author == self.me && before.is_member(&self.me);
                let line: Option<(&str, Vec<(&str, String)>)> = match op {
                    _ if i_left => None,
                    GroupOp::Add { peer } => Some(("sys.member_added", vec![("actor", actor.clone()), ("peer", peer_name(peer))])),
                    GroupOp::Remove { peer } => Some(("sys.member_removed", vec![("actor", actor.clone()), ("peer", peer_name(peer))])),
                    GroupOp::Ban { peer } => Some(("sys.member_banned", vec![("actor", actor.clone()), ("peer", peer_name(peer))])),
                    GroupOp::Leave => Some(("sys.member_left", vec![("actor", actor.clone())])),
                    GroupOp::Rename { name } => {
                        // (a late rename that lost to a newer one doesn't change the title)
                        self.store.ensure_conv(&after.conv_id(), 1, &after.name)?;
                        // and the channel chats this device has ("<group> › #<channel>")
                        let have = self.store.group_convs(&after.conv_id());
                        for ch in after.channels.iter().filter(|c| !c.voice) {
                            let conv = conv_for(&gid, &ch.name);
                            if conv != after.conv_id() && have.contains(&conv) {
                                self.store.ensure_conv(&conv, 1, &format!("{} › #{}", after.name, ch.name))?;
                            }
                        }
                        Some(("sys.group_renamed", vec![("actor", actor.clone()), ("name", name.clone())]))
                    }
                    GroupOp::SetRole { peer, role } => Some((
                        if *role == Role::Admin { "sys.role_admin" } else { "sys.role_member" },
                        vec![("actor", actor.clone()), ("peer", peer_name(peer))],
                    )),
                    GroupOp::Channel { name, voice, remove } => {
                        if !remove && !voice {
                            self.store.ensure_conv(&conv_for(&gid, name), 1, &format!("{} › #{}", after.name, name))?;
                        }
                        None
                    }
                    _ => None,
                };
                if let Some((code, args)) = line {
                    let a: Vec<(&str, &str)> = args.iter().map(|(k, v)| (*k, v.as_str())).collect();
                    self.system_msg(&gid, code, &a);
                }
                // Someone lost access to the key after the current epoch's (winning) rotation
                // → rotate again; key of the current epoch missing → ask for it.
                self.after_group_change(&after);
                if !after.is_member(&self.me) && before.is_member(&self.me) {
                    if i_left {
                        self.forget_left_group(&gid);
                    } else {
                        self.system_msg(&gid, "sys.you_removed", &[]);
                    }
                    self.emit("group_removed", json!({"gid": hex::encode(gid), "conv": after.conv_id(), "left": i_left}));
                }
                self.emit("group", self.group_info(&gid)?);
                if matches!(op, GroupOp::Rename { .. }) && !i_left {
                    // the chat list and the chat header show the new title
                    for conv in self.store.group_convs(&after.conv_id()) {
                        self.emit_conv(&conv);
                    }
                }
                Ok(true)
            }
            Payload::Msg { channel, msg } => {
                if msg.author != s.author || !self.verify_content(&msg.author, &msg.signing_bytes(&group_scope(&gid, channel)), &msg.sig) {
                    bail!("bad group chat signature");
                }
                anyhow::ensure!(super::chat::chat_msg_size_ok(msg), "group message too large");
                // only the group's own channels (an undeclared one would dodge moderation)
                if !before.channel_declared(channel) {
                    return Ok(false);
                }
                // blocked on another of my devices, our Leave not applied yet: no chat
                if self.group_blocked(&gid) {
                    return Ok(true);
                }
                // Judged by the rules in effect when it was written — the settings and the
                // author's role at its hlc, and the author's previous message by creation
                // time — so every member reaches the same verdict in any arrival order and
                // history that was valid when written is never dropped.
                let (slow_mode_s, admins_only) = before.settings_at(msg.hlc);
                if slow_mode_s > 0 || admins_only {
                    let role = before.role_at(&msg.author, s.hlc).unwrap_or(Role::Member);
                    if admins_only && role < Role::Admin {
                        return Ok(false); // announcement group: members can't post
                    }
                    if slow_mode_s > 0 && role < Role::Admin && msg.author != self.me {
                        let convs = self.store.group_convs(&conv_for(&gid, ""));
                        if let Some(prev) = self.store.prev_hlc_by(&convs, &msg.author, msg.hlc) {
                            let gap_ms = crate::util::hlc_to_ms(msg.hlc).saturating_sub(crate::util::hlc_to_ms(prev as u64));
                            if gap_ms < slow_mode_s as u64 * 1000 {
                                return Ok(false); // slow mode violated (dropped by every member)
                            }
                        }
                    }
                }
                let conv = conv_for(&gid, channel);
                let title = if channel.is_empty() { before.name.clone() } else { format!("{} › #{}", before.name, channel) };
                self.store.ensure_conv(&conv, 1, &title)?;
                let expires = msg.ttl_ms.map(|t| crate::util::hlc_to_ms(msg.hlc).saturating_add(t.min(365 * 86_400_000)) as i64);
                let mine = msg.author == self.me;
                let new = self.store.insert_message(
                    &msg.id,
                    &conv,
                    &msg.author,
                    msg.hlc,
                    msg.body.kind(),
                    &msg.body.to_json(),
                    if mine { 1 } else { 2 },
                    msg.reply_to.as_ref().map(|r| &r[..]),
                    expires,
                )?;
                if new {
                    let _ = self.store.set_message_device(&msg.id, &crate::devices::signer_device(&msg.author, &msg.sig));
                    self.store_meta(msg);
                    self.cache_sticker(&msg.body);
                    self.track_reminder(&conv, msg);
                    self.check_mention(&conv, msg);
                    // a moderator's delete / the author's edit that arrived first
                    self.apply_pending_actions(&msg.id);
                    let preview = format!("{}: {}", self.display(&msg.author), msg.body.preview());
                    self.store.conv_touch(&conv, crate::util::hlc_to_ms(msg.hlc) as i64, &preview, !mine)?;
                    if let Some(m) = self.store.message(&msg.id) {
                        self.emit("message", self.msg_json(&m));
                    }
                    self.emit_conv(&conv);
                    if !mine {
                        match &msg.body {
                            Body::File { file_id, name, size, hash, .. } => {
                                self.on_file_offer(msg.author, *file_id, name.clone(), *size, *hash, conv.clone())?
                            }
                            Body::Voice { file_id, size, hash, .. } if *size > 0 => self.on_file_offer(
                                msg.author,
                                *file_id,
                                format!("voice-{}.ogg", &hex::encode(file_id)[..8]),
                                *size,
                                *hash,
                                conv.clone(),
                            )?,
                            _ => {}
                        }
                    }
                }
                Ok(new)
            }
            Payload::Action { channel, target_author, action } => {
                anyhow::ensure!(super::chat::action_size_ok(action), "group action too large");
                if !before.channel_declared(channel) {
                    return Ok(false);
                }
                let conv = conv_for(&gid, channel);
                // moderation rights are those the actor had when it acted
                let actor_role_at = || before.role_at(&s.author, s.hlc).unwrap_or(Role::Member);
                match action {
                    MsgAction::ClearHistory { upto_hlc, .. } => {
                        // owner/admin wipes the group history for everyone — every channel,
                        // declared or not, and never beyond the clear itself / "now"
                        if actor_role_at() >= Role::Admin {
                            let upto = (*upto_hlc).min(s.hlc).min(crate::util::clamp_hlc_now());
                            for c in self.store.group_convs(&conv_for(&gid, "")) {
                                let _ = self.clear_local_ex(&c, upto, false, true);
                            }
                            let _ = self.store.group_log_clear(&gid, upto);
                        }
                        return Ok(true);
                    }
                    MsgAction::PurgeAuthor { author } => {
                        let actor_role = actor_role_at();
                        let target_role = before.role_at(author, s.hlc).unwrap_or(Role::Member);
                        if actor_role >= Role::Admin && (target_role < actor_role || *author == s.author) {
                            let convs = self.store.group_convs(&conv_for(&gid, ""));
                            for c in &convs {
                                let files = self.store.file_messages(c, i64::MAX, Some(author))?;
                                self.forget_files_of(&files);
                            }
                            for (c, id) in self.store.purge_author(&convs, author)? {
                                if let Ok(id16) = <[u8; 16]>::try_from(id.as_slice()) {
                                    self.untrack_reminder(&id16);
                                }
                                self.emit("message_update", json!({"conv": c, "id": hex::encode(id), "deleted": true}));
                            }
                        }
                        return Ok(true);
                    }
                    MsgAction::Callback { .. } => return Ok(true), // callbacks go directly to the author
                    _ => {}
                }
                let target_id = match action {
                    MsgAction::ClearHistory { .. } | MsgAction::PurgeAuthor { .. } | MsgAction::Callback { .. } => [0u8; 16],
                    MsgAction::React { target, .. }
                    | MsgAction::Vote { target, .. }
                    | MsgAction::Pin { target, .. }
                    | MsgAction::LiveLocation { target, .. }
                    | MsgAction::Edit { target, .. }
                    | MsgAction::ChecklistToggle { target, .. }
                    | MsgAction::ChecklistAdd { target, .. }
                    | MsgAction::ReminderCancel { target }
                    | MsgAction::ReminderSeen { target }
                    | MsgAction::Delete { target } => *target,
                };
                // the target must live in this group's conversation (no cross-conversation tampering)
                match self.store.message(&target_id) {
                    Some(m) if m.conv == conv && m.author == target_author.to_base32() => {}
                    Some(_) => return Ok(false),
                    None => {
                        // not here yet (other sender's queue, history still syncing): a
                        // moderator's delete / the author's edit is remembered and applied
                        // when the message arrives — it must not resurface
                        let allowed = match action {
                            MsgAction::Delete { .. } => *target_author == s.author || actor_role_at() >= Role::Admin,
                            MsgAction::Edit { .. } => *target_author == s.author,
                            _ => false,
                        };
                        if allowed {
                            let _ = self.store.pending_action_put(&target_id, &conv, target_author, &s.author, &rmp_serde::to_vec(action)?);
                        }
                        return Ok(false);
                    }
                }
                let actor_role = if matches!(action, MsgAction::Pin { .. } | MsgAction::Delete { .. }) { actor_role_at() } else { Role::Member };
                let ok = match action {
                    MsgAction::ClearHistory { .. } | MsgAction::PurgeAuthor { .. } | MsgAction::Callback { .. } => false,
                    MsgAction::React { .. } | MsgAction::Vote { .. } => true,
                    MsgAction::Pin { .. } => before.kind == 0 || actor_role >= Role::Admin,
                    MsgAction::LiveLocation { .. } => *target_author == s.author,
                    MsgAction::Edit { .. } => *target_author == s.author,
                    MsgAction::Delete { .. } => *target_author == s.author || actor_role >= Role::Admin,
                    // any member ticks / marks seen; only the sender extends or cancels
                    MsgAction::ChecklistToggle { .. } | MsgAction::ReminderSeen { .. } => true,
                    MsgAction::ChecklistAdd { .. } | MsgAction::ReminderCancel { .. } => *target_author == s.author,
                };
                if ok {
                    match action {
                        MsgAction::Delete { target } if *target_author != s.author => {
                            if self.delete_message_everywhere(target, None)? {
                                self.untrack_reminder(target);
                                self.emit("message_update", json!({"conv": conv, "id": hex::encode(target), "deleted": true}));
                            }
                        }
                        MsgAction::Delete { .. } | MsgAction::Edit { .. } => self.apply_action_at(&conv, target_author, action, s.hlc)?,
                        MsgAction::React { .. }
                        | MsgAction::Vote { .. }
                        | MsgAction::Pin { .. }
                        | MsgAction::LiveLocation { .. }
                        | MsgAction::ChecklistToggle { .. }
                        | MsgAction::ChecklistAdd { .. }
                        | MsgAction::ReminderCancel { .. }
                        | MsgAction::ReminderSeen { .. } => self.apply_action_at(&conv, &s.author, action, s.hlc)?,
                        MsgAction::ClearHistory { .. } | MsgAction::PurgeAuthor { .. } | MsgAction::Callback { .. } => {}
                    }
                }
                Ok(ok)
            }
        }
    }

    /// Type-erased (and explicitly `Send`) to break the publish → apply → rotate cycle.
    fn rotate_key_boxed(self: Arc<Self>, gid: Gid) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<()>> + Send>> {
        Box::pin(async move { self.rotate_key(gid).await })
    }

    pub(super) async fn rotate_key(self: &Arc<Self>, gid: Gid) -> Result<()> {
        let st = self.groups.read().get(&gid).cloned().ok_or_else(|| anyhow!("no group"))?;
        let epoch = st.epoch.checked_add(1).ok_or_else(|| anyhow!("epoch overflow"))?;
        let key: [u8; 32] = crate::crypto::random_bytes();
        // kept as a candidate: it becomes the epoch's key only if our Rekey wins (a
        // concurrent one by another admin may come first in every member's fold)
        self.store.group_key_add_alt(&gid, epoch, &key)?;
        // 1) signed commitment to the new key, published under the current epoch
        self.publish(gid, Payload::Op(GroupOp::Rekey { epoch, commit: key_commit(&gid, epoch, &key) })).await?;
        let (won, members) = match self.groups.read().get(&gid) {
            Some(g) => (g.key_commits.get(&epoch) == Some(&key_commit(&gid, epoch, &key)), g.key_holders()),
            None => (false, vec![]),
        };
        if !won {
            // lost to a concurrent rotation: never used for sending, nobody needs it
            tracing::info!("group {}: our rotation to epoch {epoch} lost to a concurrent one", hex::encode(gid));
            return Ok(());
        }
        // 2) the key itself, sealed to each device of each remaining key holder (privacy-mode
        //    bots excluded) — my own other devices included (`me` → siblings)
        let ku = rmp_serde::to_vec(&KeyUpdate { gid, epoch, key })?;
        for m in members {
            self.deliver_sealed(m, &ku, |sealed| PeerMsg::GroupKey { sealed }).await?;
        }
        Ok(())
    }

    /// After an op changed the group: rotate the key if someone lost access to it after
    /// the current epoch's winning rotation (by the device that signed that op, or the
    /// owner's main device when its author can't), and fetch a missing current key.
    fn after_group_change(self: &Arc<Self>, st: &GroupState) {
        if !st.is_member(&self.me) || st.is_private_bot(&self.me) {
            return;
        }
        if self.store.group_key_get(&st.gid, st.epoch).is_none() {
            self.schedule_key_request(st.gid, st.epoch);
        }
        if self.rotation_duty(st) {
            self.spawn_rotation(st.gid);
        }
    }

    /// Is a rotation due that this device must make? (the device that signed the shrink,
    /// or the owner's main device when the shrink's author can't rotate)
    fn rotation_duty(&self, st: &GroupState) -> bool {
        let Some(due) = st.rekey_due() else { return false };
        if st.role(&self.me).unwrap_or(Role::Member) < Role::Admin || st.rotator_of(due) != self.me {
            return false;
        }
        if due.author == self.me && !matches!(due.payload, Payload::Op(GroupOp::Leave)) {
            due.signer_device() == self.device
        } else {
            self.is_primary()
        }
    }

    /// Rotate (once at a time per group) until no rotation is due any more — a concurrent
    /// rotation made before a removal may win the epoch, then we go again.
    fn spawn_rotation(self: &Arc<Self>, gid: Gid) {
        {
            let mut g = ROTATING.lock();
            if !g.get_or_insert_with(Default::default).insert((self.device, gid)) {
                return;
            }
        }
        let me = self.clone();
        tokio::spawn(async move {
            for _ in 0..3 {
                let due = me.groups.read().get(&gid).map(|g| g.rekey_due().is_some() && g.is_member(&me.me)).unwrap_or(false);
                if !due {
                    break;
                }
                if let Err(e) = me.clone().rotate_key_boxed(gid).await {
                    tracing::warn!("group key rotation failed: {e:#}");
                    break;
                }
            }
            if let Some(s) = ROTATING.lock().as_mut() {
                s.remove(&(me.device, gid));
            }
        });
    }

    /// Check the keys we hold against the winning Rekey commitments: adopt keys that
    /// arrived before their Rekey, make the matching key the epoch's key, and stop sending
    /// with one that lost (kept for reading). True if an epoch got its key.
    pub(super) fn revalidate_keys(&self, st: &GroupState) -> bool {
        let gid = st.gid;
        for (epoch, key) in self.store.group_key_pending_all(&gid) {
            if st.rekey_commits(epoch).contains(&key_commit(&gid, epoch, &key)) {
                let _ = self.store.group_key_add_alt(&gid, epoch, &key);
                let _ = self.store.group_key_pending_del(&gid, epoch, &key);
            }
        }
        let mut got = false;
        // only recent epochs can still change (a losing Rekey trails the winner closely)
        for (&epoch, commit) in st.key_commits.range(st.epoch.saturating_sub(8)..) {
            let main = self.store.group_key_get(&gid, epoch);
            if main.map(|k| key_commit(&gid, epoch, &k) == *commit).unwrap_or(false) {
                continue;
            }
            match self.store.group_keys_all(&gid, epoch).into_iter().find(|k| key_commit(&gid, epoch, k) == *commit) {
                Some(k) => {
                    let _ = self.store.group_key_put(&gid, epoch, &k);
                    got = true;
                }
                None if main.is_some() => {
                    tracing::info!("group {}: our key for epoch {epoch} lost to a concurrent rotation", hex::encode(gid));
                    let _ = self.store.group_key_demote(&gid, epoch);
                }
                None => {}
            }
        }
        got
    }

    pub(super) fn on_group_key(self: &Arc<Self>, from_dev: PeerId, sealed: &[u8]) -> Result<()> {
        let (sender_dev, _ts, body) = open_sealed(&self.id, sealed)?;
        let _ = from_dev;
        let sender = self.account_of(&sender_dev);
        anyhow::ensure!(!self.is_revoked(&sender, &sender_dev), "key from a revoked device");
        let ku: KeyUpdate = crate::proto::from_slice_capped(&body)?;
        let Some(st) = self.groups.read().get(&ku.gid).cloned() else {
            // the key came before its group's welcome: hold a few (checked on the welcome)
            let mut p = self.pending_keys.lock();
            if p.len() < 256 || p.contains_key(&(ku.gid, ku.epoch)) {
                let v = p.entry((ku.gid, ku.epoch)).or_default();
                if v.len() < 4 && !v.contains(&ku.key) {
                    v.push(ku.key);
                }
            }
            return Ok(());
        };
        anyhow::ensure!(st.is_member(&sender), "key from non-member");
        let c = key_commit(&ku.gid, ku.epoch, &ku.key);
        if st.key_commits.get(&ku.epoch) == Some(&c) {
            // the winning commitment: this is the epoch's key (replacing a loser's)
            let new = self.store.group_key_get(&ku.gid, ku.epoch) != Some(ku.key);
            self.store.group_key_put(&ku.gid, ku.epoch, &ku.key)?;
            if new {
                self.retry_pending(ku.gid);
                // a sender whose copy of my device list is stale may have missed my other
                // devices: pass the key on (cheap, sealed per device)
                if sender != self.me {
                    self.forward_to_siblings(body, |sealed| PeerMsg::GroupKey { sealed });
                }
            }
        } else if st.rekey_commits(ku.epoch).contains(&c) {
            // a concurrent rotation that lost: still opens what was sent under it
            self.store.group_key_add_alt(&ku.gid, ku.epoch, &ku.key)?;
            self.retry_pending(ku.gid);
        } else if ku.epoch == 0 && !st.key_commits.contains_key(&0) {
            // the creation key has no commitment: only from an admin, only if we lack it
            if st.role(&sender).unwrap_or(Role::Member) >= Role::Admin && self.store.group_key_get(&ku.gid, 0).is_none() {
                self.store.group_key_put(&ku.gid, 0, &ku.key)?;
                self.retry_pending(ku.gid);
            }
        } else if ku.epoch <= st.epoch.saturating_add(MAX_FUTURE_EPOCHS) {
            // Its Rekey hasn't arrived (a later epoch, or a concurrent rotation we haven't
            // seen): persisted, bounded per sender, validated when the Rekey comes. No room
            // → not acknowledged (the sender retries), never acked-then-lost.
            if !self.store.group_key_pending_put(&ku.gid, ku.epoch, &sender, &ku.key)? {
                return Err(super::conn::NotNow("pending group keys").into());
            }
        } else {
            bail!("group key does not match its commitment");
        }
        Ok(())
    }

    /// Envelopes held for a missing key: try them again (a key arrived).
    pub(super) fn retry_pending(self: &Arc<Self>, gid: Gid) {
        let st = self.groups.read().get(&gid).cloned();
        if let Some(st) = st {
            self.revalidate_keys(&st);
            // a rotation we owe may have been waiting for this key (we rotate under it)
            if self.store.group_key_get(&gid, st.epoch).is_some() && self.rotation_duty(&st) {
                self.spawn_rotation(gid);
            }
        }
        // (envelopes held in memory by an older version of this code path, then the store)
        let mut pending = self.pending_group.lock().remove(&gid).unwrap_or_default();
        pending.extend(self.store.group_env_pending_take(&gid));
        if pending.is_empty() {
            return;
        }
        // Re-dispatch asynchronously through the normal path.
        let me = self.clone();
        tokio::spawn(async move {
            for env in pending {
                let _ = me.on_group_envelope(None, gid, env, false).await;
            }
        });
    }

    /// No key for `epoch` yet: give the KeyUpdate a moment, then ask members for it.
    fn schedule_key_request(self: &Arc<Self>, gid: Gid, epoch: u64) {
        {
            let mut g = KEY_WAITS.lock();
            if !g.get_or_insert_with(Default::default).insert((self.device, gid, epoch)) {
                return;
            }
        }
        let me = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(KEY_WAIT).await;
            if let Some(s) = KEY_WAITS.lock().as_mut() {
                s.remove(&(me.device, gid, epoch));
            }
            let still = me.groups.read().get(&gid).map(|g| g.epoch == epoch && g.is_member(&me.me)).unwrap_or(false);
            if still && me.store.group_key_get(&gid, epoch).is_none() {
                me.request_group_key(gid, epoch);
            }
        });
    }

    /// Ask the group's admins (and a few connected members) for the key of `epoch`
    /// (`Ext GROUP_KEY_REQUEST`, v3). At most once a minute per epoch.
    pub(super) fn request_group_key(self: &Arc<Self>, gid: Gid, epoch: u64) {
        let mut ek = [0u8; 32];
        ek[..8].copy_from_slice(&epoch.to_le_bytes());
        if !group_bucket((LIMIT_KEYREQ, self.device, PeerId(ek), gid), 1.0, 1.0 / 60.0) {
            return;
        }
        let Some(st) = self.groups.read().get(&gid).cloned() else { return };
        let mut targets: Vec<PeerId> = st.members.iter().filter(|(_, r)| **r >= Role::Admin).map(|(p, _)| *p).take(8).collect();
        let connected: Vec<PeerId> = self.connected_peers().into_iter().map(|pc| pc.account).filter(|a| st.is_member(a)).collect();
        for a in connected {
            if targets.len() >= 12 {
                break;
            }
            if !targets.contains(&a) {
                targets.push(a);
            }
        }
        // my own other devices may have it too
        if !targets.contains(&self.me) {
            targets.push(self.me);
        }
        tracing::info!("group {}: asking {} members for the key of epoch {epoch}", hex::encode(gid), targets.len());
        let msg = proto::ext(proto::ext::GROUP_KEY_REQUEST, &GroupKeyRequestMsg { gid: gid.to_vec(), epoch });
        // one queued request per (group, epoch, member): repeats replace it
        let mut h = blake3::Hasher::new_derive_key("lumora group key request v1");
        h.update(&gid);
        h.update(&epoch.to_le_bytes());
        let id: [u8; 16] = h.finalize().as_bytes()[..16].try_into().unwrap_or([0; 16]);
        let me = self.clone();
        tokio::spawn(async move {
            for t in targets {
                me.deliver(t, id, msg.clone(), true).await;
            }
        });
    }

    /// A member asks for an epoch key it misses: send what we hold for that epoch (the
    /// winning key and concurrent losers' keys), sealed to its devices — only to a current
    /// key holder, only for epochs since it (last) joined, rate-limited.
    pub(super) async fn on_group_key_request(self: &Arc<Self>, from: PeerId, body: &[u8]) -> Result<()> {
        let m: GroupKeyRequestMsg = proto::ext_body(body)?;
        let gid: Gid = m.gid.as_slice().try_into().map_err(|_| anyhow!("bad gid"))?;
        let Some(st) = self.groups.read().get(&gid).cloned() else { return Ok(()) };
        if !st.is_member(&self.me) || !st.is_member(&from) || st.is_private_bot(&from) || m.epoch > st.epoch || m.epoch < st.joined_epoch(&from) {
            return Ok(());
        }
        let keys: Vec<[u8; 32]> = self.store.group_keys_all(&gid, m.epoch).into_iter().take(8).collect();
        if keys.is_empty() || !group_bucket((LIMIT_KEYSERVE, self.device, from, gid), 4.0, 1.0 / 30.0) {
            return Ok(());
        }
        for key in keys {
            let ku = rmp_serde::to_vec(&KeyUpdate { gid, epoch: m.epoch, key })?;
            self.deliver_sealed(from, &ku, |sealed| PeerMsg::GroupKey { sealed }).await?;
        }
        Ok(())
    }

    /// Periodic group upkeep (scheduler): fetch missing current keys, and retry a rotation
    /// this device owes that hasn't happened.
    pub(super) fn group_upkeep(self: &Arc<Self>) {
        let groups: Vec<GroupState> = self.groups.read().values().filter(|g| g.is_member(&self.me) && !g.is_private_bot(&self.me)).cloned().collect();
        let now_h = now_ms() << 8;
        for st in groups {
            if self.store.group_key_get(&st.gid, st.epoch).is_none() {
                self.request_group_key(st.gid, st.epoch);
            }
            // a rotation that failed earlier (e.g. the key wasn't there yet) is retried
            if st.rekey_due().map(|d| d.hlc.saturating_add(30_000 << 8) < now_h).unwrap_or(false) && self.rotation_duty(&st) {
                self.spawn_rotation(st.gid);
            }
        }
    }

    /// Re-seal `body` to each of my other devices (best effort, reliable delivery).
    fn forward_to_siblings(self: &Arc<Self>, body: Vec<u8>, wrap: fn(Vec<u8>) -> PeerMsg) {
        if self.siblings().is_empty() {
            return;
        }
        let me = self.clone();
        tokio::spawn(async move {
            let _ = me.deliver_sealed(me.me, &body, wrap).await;
        });
    }

    pub(super) async fn on_group_welcome(self: &Arc<Self>, from: PeerId, sealed: &[u8]) -> Result<()> {
        // `from`: the device it arrived from; `sender`: the account that sealed it
        let (sender_dev, _ts, body) = open_sealed(&self.id, sealed)?;
        let sender = self.account_of(&sender_dev);
        anyhow::ensure!(!self.is_revoked(&sender, &sender_dev), "welcome from a revoked device");
        let w: Welcome = crate::proto::from_slice_capped(&body)?;
        let lock = self.group_lock(&w.gid);
        let guard = lock.lock().await;
        let existing_state = self.groups.read().get(&w.gid).cloned();
        // a group I reported and blocked: never (re-)joined, by anyone
        if self.group_blocked(&w.gid) && !existing_state.as_ref().is_some_and(|ex| ex.is_member(&self.me)) {
            tracing::info!("welcome to blocked group {} ignored", hex::encode(w.gid));
            return Ok(());
        }
        if let Some(ex) = &existing_state {
            if ex.is_member(&self.me) {
                return self.welcome_update(ex, w, sender, from, guard).await;
            }
        } else {
            // unsolicited group from a non-friend → ignore (no spam groups), unless we asked to join
            let asked = self.store.kv_get(&format!("join.pending.{}", hex::encode(w.gid))).map(|v| v == b"1").unwrap_or(false);
            let bot_ok = self.is_bot() && self.store.kv_get("bot.allow_groups").map(|v| v != b"0").unwrap_or(true);
            if !self.store.is_friend(&sender) && sender != self.me && !asked && !bot_ok {
                return Ok(());
            }
        }
        let st = GroupState::fold(w.gid, w.ops)?;
        let keyless = w.key == [0u8; 32] && st.is_private_bot(&self.me);
        if !keyless && w.epoch > 0 && st.key_commits.get(&w.epoch) != Some(&key_commit(&w.gid, w.epoch, &w.key)) {
            bail!("welcome key does not match its commitment");
        }
        if w.epoch != st.epoch {
            bail!("welcome epoch mismatch");
        }
        anyhow::ensure!(st.is_member(&sender), "welcome from non-member");
        if !st.is_member(&self.me) {
            return Ok(());
        }
        let existing = self.groups.read().get(&w.gid).cloned();
        let merged = match existing {
            Some(ex) => {
                let mut ops = ex.ops.clone();
                ops.extend(st.ops.clone());
                GroupState::fold(w.gid, ops)?
            }
            None => st,
        };
        if !keyless {
            self.store.group_key_put(&w.gid, w.epoch, &w.key)?;
        }
        self.save_group(&merged)?;
        // keys that came before this welcome: checked against the signed commitments
        let early: Vec<(u64, Vec<[u8; 32]>)> = {
            let mut p = self.pending_keys.lock();
            let ks: Vec<(Gid, u64)> = p.keys().filter(|(g, _)| *g == w.gid).copied().collect();
            ks.into_iter().filter_map(|k| p.remove(&k).map(|v| (k.1, v))).collect()
        };
        for (epoch, keys) in early {
            for k in keys {
                if merged.rekey_commits(epoch).contains(&key_commit(&w.gid, epoch, &k)) {
                    let _ = self.store.group_key_add_alt(&w.gid, epoch, &k);
                } else if epoch > merged.epoch && epoch <= merged.epoch.saturating_add(MAX_FUTURE_EPOCHS) {
                    let _ = self.store.group_key_pending_put(&w.gid, epoch, &sender, &k);
                }
            }
        }
        self.revalidate_keys(&merged);
        let _ = self.store.kv_set(&format!("join.pending.{}", hex::encode(w.gid)), b"");
        self.store.ensure_conv(&merged.conv_id(), 1, &merged.name)?;
        self.apply_community_retention(&merged);
        for ch in merged.channels.iter().filter(|c| !c.voice) {
            self.store.ensure_conv(&conv_for(&merged.gid, &ch.name), 1, &format!("{} › #{}", merged.name, ch.name))?;
        }
        if sender != self.me {
            self.system_msg(&w.gid, "sys.you_added", &[("actor", &self.display(&sender)), ("name", &merged.name)]);
        }
        drop(guard);
        self.emit("group", self.group_info(&w.gid)?);
        self.emit_conv(&merged.conv_id());
        self.retry_pending(w.gid);
        // pull history we are allowed to read
        let heads = self.store.group_log_heads(&w.gid);
        self.send_now_dev(&from, PeerMsg::GroupSync { gid: w.gid, heads });
        // my other devices join too (if the sender didn't know them)
        if sender != self.me {
            self.forward_to_siblings(body, |sealed| PeerMsg::GroupWelcome { sealed });
        }
        Ok(())
    }

    /// A welcome while already a member (privacy-mode bots get one for every membership
    /// change; a bot switched to "read all" gets the key; a bot leaving sends its Leave op).
    /// It can only add correctly signed ops we missed, and the key of the current epoch if we
    /// don't have one — matched against its signed commitment (epoch 0: from an admin).
    async fn welcome_update(self: &Arc<Self>, ex: &GroupState, w: Welcome, sender: PeerId, from: PeerId, guard: tokio::sync::MutexGuard<'_, ()>) -> Result<()> {
        anyhow::ensure!(ex.is_member(&sender), "welcome from non-member");
        let known: std::collections::HashSet<[u8; 16]> = ex.ops.iter().map(|o| o.id).collect();
        let fresh: Vec<group::Signed> = w.ops.into_iter().filter(|o| !known.contains(&o.id) && o.gid == w.gid).take(10_000).collect();
        anyhow::ensure!(fresh.iter().all(|o| o.verify()), "badly signed op in welcome");
        let changed = !fresh.is_empty();
        let merged = if changed {
            let mut ops = ex.ops.clone();
            ops.extend(fresh);
            GroupState::fold(w.gid, ops)?
        } else {
            ex.clone()
        };
        let mut got_key = false;
        if w.key != [0u8; 32]
            && merged.is_member(&self.me)
            && !merged.is_private_bot(&self.me)
            && w.epoch == merged.epoch
            && self.store.group_key_get(&w.gid, w.epoch).is_none()
        {
            let ok = if w.epoch > 0 {
                merged.key_commits.get(&w.epoch) == Some(&key_commit(&w.gid, w.epoch, &w.key))
            } else {
                merged.role(&sender).unwrap_or(Role::Member) >= Role::Admin
            };
            if ok {
                self.store.group_key_put(&w.gid, w.epoch, &w.key)?;
                got_key = true;
            }
        }
        if !changed && !got_key {
            return Ok(());
        }
        let removed = !merged.is_member(&self.me);
        self.save_group(&merged)?;
        if changed && self.revalidate_keys(&merged) {
            got_key = true;
        }
        let left = removed && self.my_exit_was_leave(&merged);
        if removed && ex.is_member(&self.me) {
            if left {
                self.forget_left_group(&w.gid);
            } else {
                self.system_msg(&w.gid, "sys.you_removed", &[]);
            }
        }
        drop(guard);
        if removed && ex.is_member(&self.me) {
            self.emit("group_removed", json!({"gid": hex::encode(w.gid), "conv": merged.conv_id(), "left": left}));
        }
        self.emit("group", self.group_info(&w.gid)?);
        if got_key {
            self.retry_pending(w.gid);
            let heads = self.store.group_log_heads(&w.gid);
            self.send_now_dev(&from, PeerMsg::GroupSync { gid: w.gid, heads });
        }
        Ok(())
    }

    pub(super) async fn on_group_sync(self: &Arc<Self>, pc: &Arc<PeerConn>, gid: Gid, heads: Vec<(PeerId, u64)>) -> Result<()> {
        let g = self.groups.read().get(&gid).cloned();
        let is_member = g.as_ref().map(|g| g.is_member(&pc.account)).unwrap_or(false);
        if !is_member {
            return Ok(());
        }
        // a tiny request makes us stream up to the whole log: a few per device and group,
        // then one every 15 s (legit peers sync on connect and after a welcome)
        if !group_bucket((LIMIT_SYNC, self.me, pc.peer, gid), 4.0, 1.0 / 15.0) {
            tracing::debug!("GroupSync from {:?} rate limited", pc.peer);
            return Ok(());
        }
        // older peers can't verify device signatures: only serve what members' account
        // keys signed (heads keyed by a device would never match theirs anyway)
        let legacy = pc.proto.load(std::sync::atomic::Ordering::Relaxed) < proto::PROTO_V3 && !self.dev_speaks_v3(&pc.peer);
        let member_keys: Vec<PeerId> = g.as_ref().map(|g| g.members.keys().copied().chain(g.left.iter().copied()).collect()).unwrap_or_default();
        // Content the requester must not get: from before it (last) joined, or what this
        // group's history no longer holds here (cleared, outside the retention window).
        let conv = conv_for(&gid, "");
        let mut content_from = g.as_ref().and_then(|g| g.join_hlc(&pc.account)).unwrap_or(0);
        content_from = content_from.max(self.store.conv_cleared_upto(&conv).map(|c| c.max(0) as u64 + 1).unwrap_or(0));
        if let Some(ms) = self.store.retention(&conv).filter(|ms| *ms > 0) {
            content_from = content_from.max(now_ms().saturating_sub(ms as u64) << 8);
        }
        // served from its own task with back-pressure, never blocking the control reader
        let me = self.clone();
        let pc = pc.clone();
        tokio::spawn(async move {
            let theirs: HashMap<PeerId, u64> = heads.into_iter().take(10_000).collect();
            for (author, my_head) in me.store.group_log_heads(&gid) {
                if legacy && !member_keys.contains(&author) {
                    continue;
                }
                let their = theirs.get(&author).copied().unwrap_or(0);
                if my_head > their {
                    for env in me.store.group_log_since_for(&gid, &author, their, content_from, 500) {
                        if pc.ctl.send(PeerMsg::Group { gid, env }).await.is_err() {
                            return;
                        }
                    }
                }
            }
        });
        Ok(())
    }

    pub async fn send_group_body(
        self: &Arc<Self>,
        gid: Gid,
        channel: &str,
        body: Body,
        reply_to: Option<[u8; 16]>,
        ttl_ms: Option<u64>,
        meta: MsgMeta,
    ) -> Result<Value> {
        if let Some(g) = self.groups.read().get(&gid).cloned() {
            let role = g.role(&self.me).unwrap_or(Role::Member);
            anyhow::ensure!(!(g.admins_only && role < Role::Admin), crate::i18n::user_err("err.admins_only_post"));
            if g.slow_mode_s > 0 && role < Role::Admin {
                let convs = self.store.group_convs(&conv_for(&gid, ""));
                if let Some(last) = self.store.prev_hlc_by(&convs, &self.me, u64::MAX) {
                    let wait = (g.slow_mode_s as u64 * 1000).saturating_sub(crate::util::now_ms().saturating_sub(crate::util::hlc_to_ms(last as u64)));
                    anyhow::ensure!(wait == 0, crate::i18n::user_err("err.slow_mode").with("s", wait.div_ceil(1000)));
                }
            }
        }
        let mut meta = meta;
        if meta.silent && !self.group_members(&gid).iter().all(|m| *m == self.me || self.peer_speaks_v2(m)) {
            // a member on an older app couldn't read the message at all: send it normally
            meta.silent = false;
        }
        let msg = self.new_chat_msg_meta(&group_scope(&gid, channel), body, reply_to, ttl_ms, meta);
        let id = msg.id;
        let private_bot = self.groups.read().get(&gid).map(|g| g.is_private_bot(&self.me)).unwrap_or(false);
        if private_bot {
            // no group key: hand the (signed) message to every member directly
            let conv = conv_for(&gid, channel);
            self.store.ensure_conv(&conv, 1, "")?;
            self.store.insert_message(&msg.id, &conv, &self.me, msg.hlc, msg.body.kind(), &msg.body.to_json(), 1, msg.reply_to.as_ref().map(|r| &r[..]), None)?;
            self.store_meta(&msg);
            let members: Vec<PeerId> = self.group_members(&gid).into_iter().filter(|m| *m != self.me).take(512).collect();
            for m in members {
                let mid: [u8; 16] = crate::crypto::random_bytes();
                self.deliver(m, mid, PeerMsg::BotGroupPost { gid, channel: channel.to_string(), msg: Box::new(msg.clone()) }, false).await;
            }
            let sm = self.store.message(&id).ok_or_else(|| anyhow!("store"))?;
            let v = self.msg_json(&sm);
            self.emit("message", v.clone());
            return Ok(v);
        }
        self.publish(gid, Payload::Msg { channel: channel.to_string(), msg: Box::new(msg) }).await?;
        let m = self.store.message(&id).ok_or_else(|| anyhow!("store"))?;
        Ok(self.msg_json(&m))
    }

    pub(super) async fn group_action(self: &Arc<Self>, gid: Gid, channel: &str, target: [u8; 16], action: MsgAction) -> Result<()> {
        let m = self.store.message(&target).ok_or_else(|| crate::i18n::user_err("err.message_not_found"))?;
        let target_author = PeerId::from_str_any(&m.author)?;
        self.publish(gid, Payload::Action { channel: channel.to_string(), target_author, action }).await?;
        Ok(())
    }

    fn my_role(&self, gid: &Gid) -> Option<Role> {
        self.groups.read().get(gid).and_then(|g| g.role(&self.me))
    }

    pub async fn group_add(self: &Arc<Self>, gid: Gid, peer: PeerId) -> Result<()> {
        let st = self.groups.read().get(&gid).cloned().ok_or_else(|| crate::i18n::user_err("err.group_not_found"))?;
        anyhow::ensure!(!st.is_member(&peer), crate::i18n::user_err("err.already_member"));
        if st.kind == 1 {
            anyhow::ensure!(self.my_role(&gid).unwrap_or(Role::Member) >= Role::Admin, crate::i18n::user_err("err.admin_only_add"));
        }
        self.publish(gid, Payload::Op(GroupOp::Add { peer })).await?;
        self.send_welcome(&gid, peer).await
    }

    pub async fn group_remove(self: &Arc<Self>, gid: Gid, peer: PeerId) -> Result<()> {
        anyhow::ensure!(self.my_role(&gid).unwrap_or(Role::Member) >= Role::Admin, crate::i18n::user_err("err.no_perm_remove"));
        self.publish(gid, Payload::Op(GroupOp::Remove { peer })).await?;
        Ok(())
    }

    pub async fn group_ban(self: &Arc<Self>, gid: Gid, peer: PeerId, ban: bool) -> Result<()> {
        anyhow::ensure!(self.my_role(&gid).unwrap_or(Role::Member) >= Role::Admin, crate::i18n::user_err("err.no_perm_remove"));
        let op = if ban { GroupOp::Ban { peer } } else { GroupOp::Unban { peer } };
        self.publish(gid, Payload::Op(op)).await?;
        Ok(())
    }

    pub async fn group_set_role(self: &Arc<Self>, gid: Gid, peer: PeerId, admin: bool) -> Result<()> {
        anyhow::ensure!(self.my_role(&gid) == Some(Role::Owner), crate::i18n::user_err("err.owner_only_role"));
        self.publish(gid, Payload::Op(GroupOp::SetRole { peer, role: if admin { Role::Admin } else { Role::Member } })).await?;
        Ok(())
    }

    pub async fn group_rename(self: &Arc<Self>, gid: Gid, name: &str) -> Result<()> {
        anyhow::ensure!(!name.trim().is_empty(), crate::i18n::user_err("err.name_empty"));
        self.publish(gid, Payload::Op(GroupOp::Rename { name: name.trim().to_string() })).await?;
        Ok(())
    }

    pub async fn group_channel(self: &Arc<Self>, gid: Gid, name: &str, voice: bool, remove: bool) -> Result<()> {
        let name: String = name.trim().to_lowercase().replace(' ', "-").chars().take(32).collect();
        anyhow::ensure!(!name.is_empty(), crate::i18n::user_err("err.channel_empty"));
        self.publish(gid, Payload::Op(GroupOp::Channel { name, voice, remove })).await?;
        Ok(())
    }

    pub async fn group_meta(self: &Arc<Self>, gid: Gid, avatar_b64: Option<&str>, description: Option<&str>) -> Result<()> {
        let cur = self.groups.read().get(&gid).cloned().ok_or_else(|| crate::i18n::user_err("err.group_not_found"))?;
        let avatar = match avatar_b64 {
            Some("") => vec![],
            Some(a) => data_encoding::BASE64.decode(a.as_bytes())?,
            None => cur.avatar.clone(),
        };
        anyhow::ensure!(avatar.len() <= 96 * 1024, crate::i18n::user_err("err.image_too_large").with("max", "96 KB"));
        let description = description.map(|d| d.to_string()).unwrap_or(cur.description.clone());
        self.publish(gid, Payload::Op(GroupOp::Meta { avatar, description })).await?;
        Ok(())
    }

    pub fn group_avatar(&self, gid: &Gid) -> Option<Vec<u8>> {
        self.groups.read().get(gid).map(|g| g.avatar.clone()).filter(|a| !a.is_empty())
    }

    pub async fn group_settings(self: &Arc<Self>, gid: Gid, slow_mode_s: Option<u32>, admins_only: Option<bool>) -> Result<()> {
        let g = self.groups.read().get(&gid).cloned().ok_or_else(|| crate::i18n::user_err("err.group_not_found"))?;
        anyhow::ensure!(g.role(&self.me).unwrap_or(Role::Member) >= Role::Admin, crate::i18n::user_err("err.admin_only"));
        self.publish(gid, Payload::Op(GroupOp::Settings {
            slow_mode_s: slow_mode_s.unwrap_or(g.slow_mode_s),
            admins_only: admins_only.unwrap_or(g.admins_only),
        })).await?;
        Ok(())
    }

    pub(super) fn on_group_read(&self, from: PeerId, gid: Gid, conv: String, upto: u64) -> Result<()> {
        let ok = self.groups.read().get(&gid).map(|g| g.is_member(&from)).unwrap_or(false);
        if ok && conv.starts_with(&format!("g:{}", hex::encode(gid))) {
            self.store.group_read_set(&conv, &from, crate::util::clamp_hlc(upto).min(i64::MAX as u64) as i64)?;
            self.emit("group_read", json!({"conv": conv, "peer": from.to_base32(), "upto": upto}));
        }
        Ok(())
    }

    /// Admin: delete every message of `peer` in this group for everyone.
    pub async fn group_purge_member(self: &Arc<Self>, gid: Gid, peer: PeerId) -> Result<()> {
        anyhow::ensure!(self.my_role(&gid).unwrap_or(Role::Member) >= Role::Admin, crate::i18n::user_err("err.admin_only"));
        self.publish(gid, Payload::Action { channel: String::new(), target_author: peer, action: MsgAction::PurgeAuthor { author: peer } }).await?;
        Ok(())
    }

    /// Admin: wipe the whole group history for everyone.
    pub async fn group_clear_history(self: &Arc<Self>, gid: Gid) -> Result<()> {
        anyhow::ensure!(self.my_role(&gid).unwrap_or(Role::Member) >= Role::Admin, crate::i18n::user_err("err.admin_only"));
        let upto = self.hlc.tick();
        self.publish(gid, Payload::Action { channel: String::new(), target_author: self.me, action: MsgAction::ClearHistory { upto_hlc: upto, delete_chat: false } }).await?;
        Ok(())
    }

    pub async fn group_leave(self: &Arc<Self>, gid: Gid) -> Result<()> {
        let st = self.groups.read().get(&gid).cloned().ok_or_else(|| crate::i18n::user_err("err.group_not_found"))?;
        if st.is_private_bot(&self.me) && self.store.group_key_get(&gid, st.epoch).is_none() {
            return self.bot_leave(st).await;
        }
        self.publish(gid, Payload::Op(GroupOp::Leave)).await?;
        Ok(())
    }

    /// A privacy-mode bot has no group key to publish with: its signed Leave op goes to every
    /// member inside a keyless welcome (members merge it like any op).
    async fn bot_leave(self: &Arc<Self>, st: GroupState) -> Result<()> {
        anyhow::ensure!(st.is_member(&self.me), crate::i18n::user_err("err.not_member"));
        let leave = group::Signed::new(&self.signer, st.gid, self.hlc.tick(), Payload::Op(GroupOp::Leave));
        let mut ops = st.ops.clone();
        ops.push(leave);
        let after = GroupState::fold(st.gid, ops)?;
        let w = rmp_serde::to_vec(&Welcome { gid: st.gid, ops: after.ops.clone(), epoch: st.epoch, key: [0u8; 32] })?;
        for m in st.members.keys().filter(|m| **m != self.me) {
            self.deliver_sealed(*m, &w, |sealed| PeerMsg::GroupWelcome { sealed }).await?;
        }
        self.save_group(&after)?;
        self.forget_left_group(&st.gid);
        self.emit("group_removed", json!({"gid": hex::encode(st.gid), "conv": after.conv_id(), "left": true}));
        self.emit("group", self.group_info(&st.gid)?);
        Ok(())
    }

    /// Telegram-style privacy mode: commands (optionally /cmd@bot), mentions of the bot,
    /// and replies to the bot's own messages are addressed to it.
    fn addressed_to_bot(&self, bot: &PeerId, msg: &crate::proto::ChatMsg) -> bool {
        if msg.meta.mentions.contains(bot) {
            return true;
        }
        if let Some(r) = msg.reply_to {
            if self.store.message(&r).map(|m| m.author == bot.to_base32()).unwrap_or(false) {
                return true;
            }
        }
        if let Body::Text { text } = &msg.body {
            if let Some(first) = text.split_whitespace().next() {
                if let Some(cmd) = first.strip_prefix('/') {
                    return match cmd.split_once('@') {
                        None => true,
                        Some((_, target)) => {
                            let target = target.to_lowercase();
                            let c = self.store.contact(bot);
                            let uname = c.as_ref().and_then(|c| c.username.clone()).unwrap_or_default();
                            let name = c.map(|c| c.name.to_lowercase().replace(' ', "")).unwrap_or_default();
                            target == uname || target == name || (!uname.is_empty() && target.starts_with(&uname))
                        }
                    };
                }
            }
        }
        false
    }

    /// Bot side: a command/mention/reply forwarded to us by a member.
    pub(super) fn on_bot_group_msg(&self, from: PeerId, gid: Gid, channel: String, msg: crate::proto::ChatMsg) -> Result<()> {
        let g = self.groups.read().get(&gid).cloned().ok_or_else(|| anyhow!("unknown group"))?;
        anyhow::ensure!(g.is_member(&from) && msg.author == from, "not a member");
        anyhow::ensure!(self.verify_content(&msg.author, &msg.signing_bytes(&group_scope(&gid, &channel)), &msg.sig), "bad signature");
        let conv = conv_for(&gid, &channel);
        self.store.ensure_conv(&conv, 1, &g.name)?;
        if self.store.insert_message(&msg.id, &conv, &msg.author, msg.hlc, msg.body.kind(), &msg.body.to_json(), 2, msg.reply_to.as_ref().map(|r| &r[..]), None)? {
            self.store_meta(&msg);
            if let Some(m) = self.store.message(&msg.id) {
                let mut v = self.msg_json(&m);
                v["chat_type"] = json!(if g.kind == 1 { "community" } else { "group" });
                self.emit("message", v);
            }
        }
        Ok(())
    }

    /// Member side: a privacy-mode bot posted into the group.
    pub(super) fn on_bot_group_post(&self, from: PeerId, gid: Gid, channel: String, msg: crate::proto::ChatMsg) -> Result<()> {
        let g = self.groups.read().get(&gid).cloned().ok_or_else(|| anyhow!("unknown group"))?;
        anyhow::ensure!(g.bots.contains_key(&from) && g.is_member(&from) && msg.author == from, "not a bot of this group");
        anyhow::ensure!(self.verify_content(&msg.author, &msg.signing_bytes(&group_scope(&gid, &channel)), &msg.sig), "bad signature");
        if g.admins_only && g.role(&from).unwrap_or(Role::Member) < Role::Admin {
            return Ok(());
        }
        let conv = conv_for(&gid, &channel);
        if self.store.insert_message(&msg.id, &conv, &msg.author, msg.hlc, msg.body.kind(), &msg.body.to_json(), 2, msg.reply_to.as_ref().map(|r| &r[..]), None)? {
            self.store_meta(&msg);
            self.track_reminder(&conv, &msg);
            let preview = format!("{}: {}", self.display(&msg.author), msg.body.preview());
            self.store.conv_touch(&conv, crate::util::hlc_to_ms(msg.hlc) as i64, &preview, true)?;
            if let Some(m) = self.store.message(&msg.id) {
                self.emit("message", self.msg_json(&m));
            }
            self.emit_conv(&conv);
        }
        Ok(())
    }

    /// Make a group public (discoverable by @handle·tag, anyone may join) or private.
    pub async fn group_visibility(self: &Arc<Self>, gid: Gid, public: bool, handle: &str) -> Result<Value> {
        let handle = handle.trim().trim_start_matches('@').to_lowercase();
        anyhow::ensure!(self.my_role(&gid).unwrap_or(Role::Member) >= Role::Admin, crate::i18n::user_err("err.admin_only"));
        if public {
            anyhow::ensure!(crate::net::nostr::valid_username(&handle), crate::i18n::user_err("err.username_invalid"));
        }
        let old = self.groups.read().get(&gid).map(|g| g.handle.clone()).unwrap_or_default();
        self.publish(gid, Payload::Op(GroupOp::Visibility { public, handle: handle.clone() })).await?;
        let pool = self.net.nostr.read().clone();
        if let Some(pool) = pool {
            if !old.is_empty() && (!public || old != handle) {
                pool.unpublish_group(&old);
            }
        }
        self.publish_group_directory(gid);
        self.group_info(&gid)
    }

    /// (Re)announce a public group in the directory (called on change and daily).
    pub(super) fn publish_group_directory(&self, gid: Gid) {
        let Some(g) = self.groups.read().get(&gid).cloned() else { return };
        if !g.public || g.handle.is_empty() || g.role(&self.me).unwrap_or(Role::Member) < Role::Admin || !self.is_primary() {
            return;
        }
        let pool = self.net.nostr.read().clone();
        if let Some(pool) = pool {
            let mut info = json!({
                "gid": hex::encode(g.gid), "title": g.name, "about": g.description.chars().take(200).collect::<String>(),
                "members": g.members.len(), "kind": g.kind, "tag": group::group_tag(&g.gid),
            });
            // proof that we administer this gid (readers show the listing as verified)
            if let Some(p) = group::admin_proof(&g, &self.me) {
                info["proof"] = json!(data_encoding::BASE64.encode(&p));
            }
            let id = self.id.clone();
            let handle = g.handle.clone();
            tokio::task::spawn_blocking(move || pool.publish_group(&id, &handle, &info));
        }
    }

    /// Search public groups: `@name·tag` exact, `@name` all matches. Local groups first.
    pub async fn search_groups(&self, q: &str) -> Result<Vec<Value>> {
        let h = q.trim().trim_start_matches('@').to_lowercase();
        let (name, tag) = match h.split_once(['·', '.', '#']) {
            Some((n, t)) => (n.to_string(), Some(t.to_string())),
            None => (h.clone(), None),
        };
        anyhow::ensure!(crate::net::nostr::valid_username(&name), crate::i18n::user_err("err.username_invalid"));
        let mut out = vec![];
        for g in self.groups.read().values() {
            if self.group_blocked(&g.gid) {
                continue;
            }
            if g.public && g.handle == name && tag.as_deref().map(|t| t == group::group_tag(&g.gid)).unwrap_or(true) {
                out.push(json!({"gid": hex::encode(g.gid), "title": g.name, "members": g.members.len(), "joined": g.is_member(&self.me),
                                "handle": format!("@{}·{}", g.handle, group::group_tag(&g.gid)), "verified": true}));
            }
        }
        let pool = self.net.nostr.read().clone();
        if let Some(pool) = pool {
            for mut c in pool.lookup_group(&name).await {
                let gid = c["gid"].as_str().unwrap_or("").to_string();
                let Ok(gb) = hex::decode(&gid) else { continue };
                let Ok(gid16) = <[u8; 16]>::try_from(gb.as_slice()) else { continue };
                let t = group::group_tag(&gid16);
                // a group I reported / blocked isn't offered again
                if tag.as_deref().map(|x| x == t).unwrap_or(true) && !out.iter().any(|o| o["gid"].as_str() == Some(&gid)) && !self.group_blocked(&gid16) {
                    c["handle"] = json!(format!("@{name}·{t}"));
                    c["joined"] = json!(false);
                    out.push(c);
                }
            }
        }
        Ok(out)
    }

    /// Join a public group through one of its admins (no invite link needed).
    pub async fn join_public(self: &Arc<Self>, gid: Gid, via: PeerId) -> Result<()> {
        // bots only join when an admin adds them
        anyhow::ensure!(!self.group_blocked(&gid), crate::i18n::user_err("err.group_blocked"));
        anyhow::ensure!(!self.is_bot(), crate::i18n::user_err("err.bot_join_public"));
        self.store.kv_set(&format!("join.pending.{}", hex::encode(gid)), b"1")?;
        self.send_to(via, PeerMsg::JoinPublic { gid }).await
    }

    pub(super) async fn on_join_public(self: &Arc<Self>, from: PeerId, gid: Gid) -> Result<()> {
        let Some(g) = self.groups.read().get(&gid).cloned() else { return Ok(()) };
        if g.public && !g.banned.contains(&from) && !g.is_member(&from) && !self.store.is_blocked(&from) && g.role(&self.me).unwrap_or(Role::Member) >= Role::Admin {
            if !self.join_allowed(&gid) {
                tracing::warn!("public join from {from:?} dropped: join rate limit for this group");
                return Ok(());
            }
            self.group_add(gid, from).await?;
        }
        Ok(())
    }

    pub async fn group_add_bot(self: &Arc<Self>, gid: Gid, bot: PeerId, read_all: bool) -> Result<()> {
        anyhow::ensure!(self.my_role(&gid).unwrap_or(Role::Member) >= Role::Admin, crate::i18n::user_err("err.admin_only_add"));
        self.publish(gid, Payload::Op(GroupOp::AddBot { peer: bot, read_all })).await?;
        self.send_welcome(&gid, bot).await
    }

    pub async fn group_bot_policy(self: &Arc<Self>, gid: Gid, bot: PeerId, read_all: bool) -> Result<()> {
        anyhow::ensure!(self.my_role(&gid).unwrap_or(Role::Member) >= Role::Admin, crate::i18n::user_err("err.admin_only"));
        self.publish(gid, Payload::Op(GroupOp::SetBotPolicy { peer: bot, read_all })).await?;
        if read_all {
            self.send_welcome(&gid, bot).await?; // now give it the key
        }
        // read_all=false: the op makes a rotation due (a new key the bot doesn't get),
        // done by this device right after (`after_group_change`)
        Ok(())
    }

    pub fn group_members(&self, gid: &Gid) -> Vec<PeerId> {
        self.groups.read().get(gid).map(|g| g.members.keys().copied().collect()).unwrap_or_default()
    }
}

#[cfg(test)]
#[path = "groups_regress.rs"]
mod regress;

#[cfg(test)]
mod abuse_tests {
    use super::*;

    #[tokio::test]
    async fn lock_map_and_group_work_are_bounded() {
        let tmp = tempfile::tempdir().unwrap();
        let n = Node::start(NodeConfig {
            data_dir: tmp.path().join("data"),
            enable_lan: false,
            enable_upnp: false,
            enable_dht: false,
            enable_nostr: false,
            relays: Some(vec![]),
            nostr: Some(vec![]),
            stun: Some(vec![]),
            ..Default::default()
        })
        .await
        .unwrap();
        // envelopes / welcomes for random gids from anyone: the lock map stays bounded,
        // and a lock in use survives the pruning
        let held = n.group_lock(&[7; 16]);
        let _g = held.try_lock().unwrap();
        for i in 0..5000u32 {
            let mut gid = [0u8; 16];
            gid[..4].copy_from_slice(&i.to_le_bytes());
            gid[15] = 1;
            let _ = n.group_lock(&gid);
        }
        assert!(n.group_locks.lock().len() <= 1100, "{}", n.group_locks.lock().len());
        assert!(Arc::ptr_eq(&held, &n.group_lock(&[7; 16])), "a held lock was replaced");
        // GroupSync serving: a few at once per device and group, then throttled
        let (peer, gid) = (PeerId([3; 32]), [9u8; 16]);
        let served = (0..20).filter(|_| group_bucket((LIMIT_SYNC, n.me, peer, gid), 4.0, 1.0 / 15.0)).count();
        assert_eq!(served, 4);
        assert!(group_bucket((LIMIT_SYNC, n.me, PeerId([4; 32]), gid), 4.0, 1.0 / 15.0), "other devices unaffected");
        // joins we serve as admin: bounded per group
        let joins = (0..100).filter(|_| n.join_allowed(&gid)).count();
        assert_eq!(joins, 30);
        assert!(n.join_allowed(&[10; 16]), "other groups unaffected");
        n.shutdown();
    }

    async fn quiet_node(dir: &std::path::Path) -> Arc<Node> {
        Node::start(NodeConfig {
            data_dir: dir.join("data"),
            enable_lan: false,
            enable_upnp: false,
            enable_dht: false,
            enable_nostr: false,
            relays: Some(vec![]),
            nostr: Some(vec![]),
            stun: Some(vec![]),
            ..Default::default()
        })
        .await
        .unwrap()
    }

    /// A member's chat message as it arrives over the wire.
    fn member_env(who: &crate::identity::Identity, gid: Gid, key: &[u8; 32], hlc: u64, text: &str) -> (Vec<u8>, [u8; 16]) {
        let mut m = crate::proto::ChatMsg {
            id: crate::crypto::random_bytes(),
            author: who.peer_id(),
            hlc,
            body: Body::Text { text: text.into() },
            reply_to: None,
            ttl_ms: None,
            meta: MsgMeta::default(),
            sig: vec![],
        };
        m.sig = who.sign(&m.signing_bytes(&group_scope(&gid, ""))).to_vec();
        let id = m.id;
        let s = Signed::new(&crate::devices::Signer::primary(who), gid, hlc, Payload::Msg { channel: String::new(), msg: Box::new(m) });
        (group::seal_envelope(key, 0, &s).unwrap(), id)
    }

    fn hlc_at(ms: u64) -> u64 {
        ms << 8
    }

    #[tokio::test]
    async fn member_flood_is_rejected_by_creation_time_but_sync_replays_pass() {
        let tmp = tempfile::tempdir().unwrap();
        let n = quiet_node(tmp.path()).await;
        let mut events = n.subscribe();
        let bob = crate::identity::Identity::generate();
        let carol = crate::identity::Identity::generate();
        let now = crate::util::now_ms();
        // a group created 3 days ago (so old history can be replayed into it)
        let (st, _op) = group::create(&n.signer, hlc_at(now - 3 * 86_400_000), "Ồn ào", vec![bob.peer_id(), carol.peer_id()], 0).unwrap();
        let gid = st.gid;
        let key: [u8; 32] = crate::crypto::random_bytes();
        n.store.group_key_put(&gid, 0, &key).unwrap();
        n.save_group(&st).unwrap();
        let conv = st.conv_id();
        let stored = |id: &[u8; 16]| n.store.message(id).is_some();

        // 1) anti-entropy replays 300 of Bob's old messages (2 a minute, 2.5 days ago) in
        //    one burst: all stored — they are judged by when they were written
        let base = now - 60 * 3_600_000;
        let mut old_ids = vec![];
        for i in 0..300u64 {
            let (env, id) = member_env(&bob, gid, &key, hlc_at(base + i * 30_000), &format!("cũ {i}"));
            n.on_group_envelope(None, gid, env, false).await.unwrap();
            old_ids.push(id);
        }
        assert!(old_ids.iter().all(stored), "sync replay of old history must never be rate limited");

        // 2) live: Bob posts 70 messages within 7 seconds — the first 60 pass, the rest are
        //    rejected (not stored, not in the anti-entropy log)
        let mut live = vec![];
        for i in 0..70u64 {
            let (env, id) = member_env(&bob, gid, &key, hlc_at(now + i * 100), &format!("spam {i}"));
            n.on_group_envelope(None, gid, env, false).await.unwrap();
            live.push(id);
        }
        assert_eq!(live.iter().filter(|id| stored(id)).count(), FLOOD_PER_MIN as usize);
        assert!(!stored(&live[65]));
        assert_eq!(n.store.group_log_window(&gid, &bob.peer_id(), hlc_at(now) - 1, hlc_at(now + 7_000)).0, FLOOD_PER_MIN);
        // the same flood replayed later by a sync gets the same verdict
        let (env, id) = member_env(&bob, gid, &key, hlc_at(now + 6_500), "spam again");
        n.on_group_envelope(None, gid, env, false).await.unwrap();
        assert!(!stored(&id));
        // ...while a minute later Bob may speak again
        let (env, id) = member_env(&bob, gid, &key, hlc_at(now + 61_000), "xin lỗi mọi người");
        n.on_group_envelope(None, gid, env, false).await.unwrap();
        assert!(stored(&id));

        // the owner (this node) got one slow-mode suggestion, not one per message
        let mut floods = vec![];
        while let Ok(e) = events.try_recv() {
            if e["event"] == "group_flood" {
                floods.push(e);
            }
        }
        assert_eq!(floods.len(), 1, "{floods:?}");
        let f = &floods[0];
        assert_eq!((f["gid"].as_str().unwrap(), f["conv"].as_str().unwrap()), (hex::encode(gid).as_str(), conv.as_str()));
        assert_eq!(f["author"], json!(bob.peer_id().to_base32()));
        assert_eq!((f["reason"].as_str(), f["admin"].as_bool(), f["suggest_slow_mode_s"].as_u64()), (Some("rate"), Some(true), Some(10)));
        assert!(!f["text"].as_str().unwrap().is_empty());

        // 3) content can't predate the group or come from next week
        let (env, id) = member_env(&bob, gid, &key, hlc_at(now - 5 * 86_400_000), "trước khi có nhóm");
        n.on_group_envelope(None, gid, env, false).await.unwrap();
        assert!(!stored(&id));
        let (env, id) = member_env(&bob, gid, &key, hlc_at(now + 7 * 86_400_000), "tương lai");
        n.on_group_envelope(None, gid, env, false).await.unwrap();
        assert!(!stored(&id));

        // 4) storage quotas: Carol's big messages (spaced out, so not a rate problem) stop at
        //    her daily share; then the group's daily quota stops everyone but admins
        let big = "x".repeat(30 * 1024);
        let t0 = now - 20 * 3_600_000;
        let mut carol_ok = 0;
        for i in 0..20u64 {
            let (env, id) = member_env(&carol, gid, &key, hlc_at(t0 + i * 120_000), &big);
            n.on_group_envelope(None, gid, env, false).await.unwrap();
            carol_ok += stored(&id) as usize;
        }
        assert!((6..10).contains(&carol_ok), "author quota: {carol_ok}");
        assert_eq!(n.group_flood_check(&st, &carol.peer_id(), &carol.peer_id(), hlc_at(t0 + 41 * 120_000), 40_000), Some(Flood::AuthorQuota));
        let dave = crate::identity::Identity::generate();
        let mut st2 = st.clone();
        st2.members.insert(dave.peer_id(), Role::Member);
        n.save_group(&st2).unwrap();
        let mut dave_ok = 0;
        for i in 0..20u64 {
            let (env, id) = member_env(&dave, gid, &key, hlc_at(t0 + 30_000 + i * 120_000), &big);
            n.on_group_envelope(None, gid, env, false).await.unwrap();
            dave_ok += stored(&id) as usize;
        }
        assert!(dave_ok < carol_ok, "group quota must stop Dave first: {dave_ok}");
        assert_eq!(n.group_flood_check(&st2, &dave.peer_id(), &dave.peer_id(), hlc_at(t0 + 45 * 120_000), 1), Some(Flood::GroupQuota));
        // admins are exempt; my own sending is refused with a friendly error instead
        assert_eq!(n.group_flood_check(&st2, &n.me, &n.device, hlc_at(t0 + 45 * 120_000), 1), None);
        let e = anyhow::Error::from(Flood::Rate.user_err());
        assert_eq!(crate::i18n::find_user_err(&e).unwrap().key, "err.group_too_fast");
        n.shutdown();
    }
}
