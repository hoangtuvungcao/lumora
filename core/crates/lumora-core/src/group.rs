//! Serverless groups.
//!
//! * Membership is an append-only log of **signed operations**. Every member folds the
//!   log in `(hlc, author)` order and validates permissions at each step, so all members
//!   converge to the same state without any coordinator (concurrent admin conflicts are
//!   resolved deterministically: earlier op wins; the owner outranks admins).
//! * Content is encrypted with a **group epoch key** (XChaCha20-Poly1305). Removing or
//!   losing a member rotates the key; the new key is sealed individually to each
//!   remaining member, so removed members cannot read anything new.
//! * Envelopes are signed by their author, so any member can relay/gossip them and
//!   help offline members catch up (anti-entropy by per-author HLC heads).

use crate::crypto::{aead_decrypt, aead_encrypt};
use crate::devices::Signer;
use crate::identity::PeerId;
use crate::community::{self, perm, ChanMeta, Community, RoleDef};
use crate::proto::{ChatMsg, MsgAction};
use anyhow::{anyhow, bail, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub type Gid = [u8; 16];

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Role {
    Member = 0,
    Admin = 1,
    Owner = 2,
}

impl Role {
    pub fn as_str(&self) -> &'static str {
        match self {
            Role::Member => "member",
            Role::Admin => "admin",
            Role::Owner => "owner",
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub enum GroupOp {
    Create { name: String, members: Vec<PeerId>, kind: u8 },
    Add { peer: PeerId },
    Remove { peer: PeerId },
    SetRole { peer: PeerId, role: Role },
    Rename { name: String },
    Leave,
    /// Announces the next epoch and commits to its key: commit = key_commit(gid, epoch, key).
    /// Keys received out-of-band are only accepted if they match this signed commitment.
    Rekey { epoch: u64, #[serde(default)] commit: [u8; 32] },
    Channel { name: String, voice: bool, remove: bool },
    /// Public group/channel: discoverable as @handle·tag, anyone can join (unless banned).
    Visibility { public: bool, handle: String },
    /// Add a bot. `read_all=false` (privacy mode, default): the bot never receives the group
    /// key — it only gets commands / mentions / replies addressed to it, delivered by senders.
    AddBot { peer: PeerId, read_all: bool },
    SetBotPolicy { peer: PeerId, read_all: bool },
    /// Remove *and* ban: the member cannot rejoin via invite links until unbanned.
    Ban { peer: PeerId },
    Unban { peer: PeerId },
    /// Admin settings: slow mode (seconds between messages per member, 0 = off) and
    /// announcement mode (only admins can post — like a Telegram channel).
    Settings { slow_mode_s: u32, admins_only: bool },
    /// Group picture (≤96 KB) and description.
    Meta { #[serde(with = "serde_bytes")] avatar: Vec<u8>, description: String },
    /// Cover / banner picture (JPEG ≤ [`MAX_COVER`]; empty = removed). Its own op so a
    /// description or avatar change never re-sends the large cover. Same rights as the
    /// avatar: communities → admins/owner; group chats → any member (rate-limited).
    Cover { #[serde(with = "serde_bytes")] cover: Vec<u8> },
    /// The owner deletes the group for everyone: final — every member's device forgets
    /// it and nothing (op or content) is accepted for it afterwards.
    Dissolve,
    // ---- Community 2.0 (docs/src/dev/community2-contract.md). Appended: older variants
    // keep their encoding.
    /// Create / change a role (`everyone`: its permissions only; `admin:<peer>`: a plain
    /// group's per-admin rights, owner only). `position`: 1 = just above @everyone.
    RoleSet { id: String, name: String, color: String, perms: u32, position: Option<u32> },
    RoleDelete { id: String },
    /// A member's (or bot's) custom roles, replacing the previous set.
    MemberRoles { peer: PeerId, roles: Vec<String> },
    /// Muted until `until_ms` (epoch ms; 0 lifts it).
    Timeout { peer: PeerId, until_ms: u64 },
    /// Channel settings; `name` is the channel's key (its conversation never changes).
    ChannelUpdate {
        name: String,
        new_name: Option<String>,
        topic: Option<String>,
        category: Option<String>,
        position: Option<u32>,
        private: Option<bool>,
        allow_roles: Option<Vec<String>>,
        announce: Option<bool>,
    },
    /// The owner hands the group over (and becomes an admin).
    TransferOwner { peer: PeerId },
    /// Revoke one invite link (`community::invite_id`), or every link made so far.
    RevokeInvite { id: Option<[u8; 8]> },
    /// "Approve new members": invite-link joins wait for an admin.
    JoinApproval { on: bool },
    /// The group switches to the Community 2.0 rules (permissions, roles, admin-only re-adds,
    /// succession by join order) for every op after it in fold order. Groups made by 1.0.8+
    /// carry it right after their Create; older groups switch when an admin publishes it
    /// (every member must run 1.0.8+: older apps can't read the new op kinds).
    RulesV2,
}

/// Lower bound for [`GroupOp::RulesV2`] (2026-11-07 UTC): one dated earlier is never
/// applied. The rules themselves are a per-group switch (the op), never a date: a 1.0.7
/// member keeps folding by the old rules, so a date cutoff would split mixed groups.
pub const V2_RULES_HLC: u64 = 1_794_009_600_000 << 8;

/// Largest group cover picture (bytes).
pub const MAX_COVER: usize = 300 * 1024;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub enum Payload {
    Op(GroupOp),
    Msg { channel: String, msg: Box<ChatMsg> },
    Action { channel: String, target_author: PeerId, action: MsgAction },
}

/// Signed plaintext inside the encrypted envelope.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Signed {
    pub id: [u8; 16],
    pub gid: Gid,
    pub author: PeerId,
    pub hlc: u64,
    pub payload: Payload,
    #[serde(with = "serde_bytes")]
    pub sig: Vec<u8>,
}

impl Signed {
    fn bytes(id: &[u8; 16], gid: &Gid, author: &PeerId, hlc: u64, payload: &Payload) -> Vec<u8> {
        let mut v = b"lumora-group-v1".to_vec();
        v.extend_from_slice(id);
        v.extend_from_slice(gid);
        v.extend_from_slice(&author.0);
        v.extend_from_slice(&hlc.to_le_bytes());
        v.extend(rmp_serde::to_vec(payload).unwrap_or_default());
        v
    }
    /// The bytes the signature covers.
    pub fn signing_bytes(&self) -> Vec<u8> {
        Self::bytes(&self.id, &self.gid, &self.author, self.hlc, &self.payload)
    }
    /// Signed as the account (`author` = account; a secondary device adds its DevSig).
    pub fn new(me: &Signer, gid: Gid, hlc: u64, payload: Payload) -> Signed {
        let id: [u8; 16] = crate::crypto::random_bytes();
        let author = me.account();
        let sig = me.sign(&Self::bytes(&id, &gid, &author, hlc, &payload));
        Signed { id, gid, author, hlc, payload, sig }
    }
    /// Account signature or a valid device signature of the author (revocation is checked
    /// by the node).
    pub fn verify(&self) -> bool {
        crate::devices::verify_by(&self.author, &Self::bytes(&self.id, &self.gid, &self.author, self.hlc, &self.payload), &self.sig).is_some()
    }
    /// The device that signed it: anti-entropy heads are kept per signing device, so two
    /// devices of one account posting concurrently never leave gaps.
    pub fn signer_device(&self) -> PeerId {
        crate::devices::signer_device(&self.author, &self.sig)
    }
}

/// Wire envelope = epoch(u64 LE) || AEAD(key[epoch], msgpack(Signed)).
pub fn seal_envelope(key: &[u8; 32], epoch: u64, s: &Signed) -> Result<Vec<u8>> {
    let plain = rmp_serde::to_vec(s)?;
    let mut out = epoch.to_le_bytes().to_vec();
    out.extend(aead_encrypt(key, &plain, &s.gid));
    Ok(out)
}

pub fn envelope_epoch(env: &[u8]) -> Option<u64> {
    env.get(..8).map(|b| u64::from_le_bytes(b.try_into().unwrap()))
}

/// Open with the first of `keys` that decrypts it: Ok(None) if none does (a key we don't
/// have yet); an error if it decrypts but is malformed or badly signed.
pub fn open_envelope_any(keys: &[[u8; 32]], gid: &Gid, env: &[u8]) -> Result<Option<Signed>> {
    if env.len() < 8 {
        bail!("short envelope");
    }
    for k in keys {
        if let Ok(plain) = aead_decrypt(k, &env[8..], gid) {
            let s: Signed = crate::proto::from_slice_capped(&plain)?;
            if &s.gid != gid || !s.verify() {
                bail!("bad group envelope signature");
            }
            return Ok(Some(s));
        }
    }
    Ok(None)
}

pub fn open_envelope(key: &[u8; 32], gid: &Gid, env: &[u8]) -> Result<Signed> {
    if env.len() < 8 {
        bail!("short envelope");
    }
    let plain = aead_decrypt(key, &env[8..], gid)?;
    let s: Signed = crate::proto::from_slice_capped(&plain)?;
    if &s.gid != gid || !s.verify() {
        bail!("bad group envelope signature");
    }
    Ok(s)
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Channel {
    pub name: String,
    pub voice: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct GroupState {
    pub gid: Gid,
    pub name: String,
    /// 0 = group chat, 1 = community/server with channels
    pub kind: u8,
    pub owner: PeerId,
    pub members: BTreeMap<PeerId, Role>,
    pub epoch: u64,
    pub channels: Vec<Channel>,
    pub created: u64,
    /// The signed ops this state was folded from (shared with new members).
    pub ops: Vec<Signed>,
    /// Ex-members (removed / left) — they must not be re-added by gossip.
    pub left: Vec<PeerId>,
    #[serde(default, with = "serde_bytes")]
    pub avatar: Vec<u8>,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub public: bool,
    #[serde(default)]
    pub handle: String,
    /// Bots in this group → may they read every message (have the key)?
    #[serde(default)]
    pub bots: BTreeMap<PeerId, bool>,
    #[serde(default)]
    pub slow_mode_s: u32,
    #[serde(default)]
    pub admins_only: bool,
    /// Members removed by an admin (cannot rejoin through invite links until re-added).
    #[serde(default)]
    pub banned: Vec<PeerId>,
    /// epoch → commitment of its key (from signed Rekey ops)
    #[serde(default)]
    pub key_commits: BTreeMap<u64, [u8; 32]>,
    /// highest hlc of an applied op (live ops far older than this are rejected)
    #[serde(default)]
    pub last_op_hlc: u64,
    /// Roles, permissions, channel settings, timeouts… (derived from `ops`, never
    /// serialized: older versions read this struct as a fixed array).
    #[serde(skip)]
    pub ext: Community,
}

/// Verified ops the fold rejected, kept per group for later folds (see `with_op`).
pub const MAX_HELD_OPS: usize = 2000;
/// Concurrent losing rotations kept per epoch (each one's key may have been used).
const MAX_REKEYS_PER_EPOCH: usize = 8;
/// A losing Rekey must be for one of the last few epochs (it raced the winner).
const MAX_LOSER_EPOCH_LAG: u64 = 4;
/// Plain members of a group chat: one picture/description change per 10 minutes …
const MEMBER_META_GAP_MS: u64 = 10 * 60_000;
/// … and one rename per minute (admins are not limited).
const MEMBER_RENAME_GAP_MS: u64 = 60_000;
/// Largest group picture (bytes).
pub const MAX_GROUP_AVATAR: usize = 96 * 1024;
/// Held (rejected, verified) ops kept per group, in bytes: pictures are large, so the op
/// count alone doesn't bound what the held list stores and rewrites.
pub const MAX_HELD_BYTES: usize = 2 * 1024 * 1024;
/// An owner's Dissolve racing its own Leave (e.g. from two of its devices): still final if
/// it was signed at most this long after the Leave (an ex-owner can't dissolve later).
pub(crate) const DISSOLVE_AFTER_LEAVE_MS: u64 = 3_600_000;
/// Picture ops of each kind (cover, avatar) that keep their bytes in the op log.
const KEEP_PICTURES: usize = 2;
/// Prefix fold snapshots kept per group (`prefix_state`).
const MAX_SNAPSHOTS: usize = 48;

/// Folds of op-log prefixes, shared by the clones of a group's state: judging late content
/// by the rules of its time (`state_for`, `role_at`) walks forward from the nearest
/// snapshot instead of re-folding the whole prefix for every message (catch-up on a big
/// community would be quadratic). Keyed by a hash of the prefix's op ids, so a snapshot is
/// only ever used for exactly the ops it was folded from.
#[derive(Clone, Default)]
pub struct Snapshots(std::sync::Arc<parking_lot::Mutex<Vec<Snapshot>>>);

/// (hash of the prefix's op ids, its length, its fold)
type Snapshot = ([u8; 32], usize, std::sync::Arc<GroupState>);

impl std::fmt::Debug for Snapshots {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Snapshots({})", self.0.lock().len())
    }
}

/// The state content is judged by (see `GroupState::state_for`).
pub enum StateAt<'a> {
    Now(&'a GroupState),
    Then(std::sync::Arc<GroupState>),
}

impl std::ops::Deref for StateAt<'_> {
    type Target = GroupState;
    fn deref(&self) -> &GroupState {
        match self {
            StateAt::Now(s) => s,
            StateAt::Then(s) => s,
        }
    }
}

pub fn key_commit(gid: &Gid, epoch: u64, key: &[u8; 32]) -> [u8; 32] {
    let mut h = blake3::Hasher::new_derive_key("lumora group key commit v1");
    h.update(gid);
    h.update(&epoch.to_le_bytes());
    h.update(key);
    *h.finalize().as_bytes()
}

impl GroupState {
    pub fn conv_id(&self) -> String {
        format!("g:{}", hex::encode(self.gid))
    }
    pub fn role(&self, p: &PeerId) -> Option<Role> {
        self.members.get(p).copied()
    }
    /// A member now (nobody is, once the group is dissolved).
    pub fn is_member(&self, p: &PeerId) -> bool {
        self.members.contains_key(p) && !self.dissolved()
    }
    /// Was `p` a member when the group was dissolved (or is it one now)? For serving the
    /// Dissolve to members that were offline.
    pub fn was_member(&self, p: &PeerId) -> bool {
        self.members.contains_key(p)
    }
    /// Deleted by its owner. Dissolve is final (the fold applies nothing after it), so it
    /// is always the last applied op.
    pub fn dissolved(&self) -> bool {
        matches!(self.ops.last().map(|o| &o.payload), Some(Payload::Op(GroupOp::Dissolve)))
    }
    /// The latest applied cover op (None: no cover ever set).
    fn cover_op(&self) -> Option<(&Signed, &Vec<u8>)> {
        // (one whose bytes were stripped is skipped: the one before it still shows)
        self.ops.iter().rev().find_map(|o| match &o.payload {
            Payload::Op(GroupOp::Cover { cover }) if !Self::stripped(o) => Some((o, cover)),
            _ => None,
        })
    }
    /// The cover picture (empty: none). Derived from the op log — the op is kept there
    /// anyway, so a copy in the state would only double what is stored and sent.
    pub fn cover(&self) -> &[u8] {
        self.cover_op().map(|(_, c)| c.as_slice()).unwrap_or(&[])
    }
    /// Changes whenever the cover does ("" when there is none): lets the UI cache it.
    pub fn cover_rev(&self) -> String {
        self.cover_op().filter(|(_, c)| !c.is_empty()).map(|(o, _)| hex::encode(o.id)).unwrap_or_default()
    }
    /// Members that hold the group key (everyone except privacy-mode bots).
    pub fn key_holders(&self) -> Vec<PeerId> {
        self.members.keys().copied().filter(|p| self.bots.get(p).copied().unwrap_or(true)).collect()
    }
    pub fn is_private_bot(&self, p: &PeerId) -> bool {
        self.bots.get(p) == Some(&false)
    }

    /// Commitments of every applied Rekey for `epoch` (the winner and concurrent losers).
    fn rekey_ops(&self, epoch: u64) -> impl Iterator<Item = &[u8; 32]> {
        self.ops.iter().filter_map(move |o| match &o.payload {
            Payload::Op(GroupOp::Rekey { epoch: e, commit }) if *e == epoch => Some(commit),
            _ => None,
        })
    }

    /// Every signed commitment for `epoch`'s key: the winning one first, then those of
    /// concurrent rotations that lost (their keys still open what was sent under them).
    pub fn rekey_commits(&self, epoch: u64) -> Vec<[u8; 32]> {
        let mut v: Vec<[u8; 32]> = self.key_commits.get(&epoch).copied().into_iter().collect();
        for c in self.rekey_ops(epoch) {
            if !v.contains(c) {
                v.push(*c);
            }
        }
        v
    }

    /// Did `author` apply an op matching `f` less than `gap_ms` before `hlc`? (deterministic:
    /// only applied ops, by creation time)
    fn recent_op_by(&self, author: &PeerId, hlc: u64, gap_ms: u64, f: impl Fn(&GroupOp) -> bool) -> bool {
        self.ops.iter().rev().take_while(|o| o.hlc.saturating_add(gap_ms << 8) > hlc).any(|o| {
            &o.author == author && o.hlc <= hlc && matches!(&o.payload, Payload::Op(op) if f(op))
        })
    }

    /// The op that took someone's access to the key away (removal, ban, departure, a bot
    /// switched to privacy mode) that no rotation covers yet: the key must be rotated.
    ///
    /// A shrink is covered only by a *winning* Rekey after it (in fold order) made by its
    /// rotator — the admin who made the shrink (it applied the shrink before rotating, so
    /// its key never went to the person who lost access), or the owner when that author
    /// can't rotate (a departure, an author no longer admin). A concurrent rotation by
    /// someone else that happens to sort after it doesn't count: it may have been handed
    /// to the removed member.
    pub fn rekey_due(&self) -> Option<&Signed> {
        let mut members: std::collections::HashSet<PeerId> = std::collections::HashSet::new();
        let mut shrinks: Vec<usize> = vec![];
        let mut rekeys: Vec<(usize, PeerId)> = vec![];
        for (i, o) in self.ops.iter().enumerate() {
            match &o.payload {
                Payload::Op(GroupOp::Create { members: m, .. }) => {
                    members.insert(o.author);
                    members.extend(m.iter().copied());
                }
                Payload::Op(GroupOp::Add { peer }) => {
                    members.insert(*peer);
                }
                Payload::Op(GroupOp::AddBot { peer, read_all }) => {
                    if !*read_all && members.contains(peer) {
                        shrinks.push(i); // a member became a privacy-mode bot
                    }
                    members.insert(*peer);
                }
                Payload::Op(GroupOp::SetBotPolicy { read_all: false, .. }) => shrinks.push(i),
                Payload::Op(GroupOp::Remove { peer } | GroupOp::Ban { peer }) => {
                    if members.remove(peer) {
                        shrinks.push(i);
                    }
                }
                Payload::Op(GroupOp::Leave) => {
                    if members.remove(&o.author) {
                        shrinks.push(i);
                    }
                }
                Payload::Op(GroupOp::Rekey { epoch, commit }) if self.key_commits.get(epoch) == Some(commit) => rekeys.push((i, o.author)),
                _ => {}
            }
        }
        shrinks.into_iter().rev().find(|&i| {
            let rot = self.rotator_of(&self.ops[i]);
            !rekeys.iter().any(|(r, a)| *r > i && *a == rot)
        }).map(|i| &self.ops[i])
    }

    /// Who rotates the key after `shrink`: its author while it is an admin, else the owner.
    pub fn rotator_of(&self, shrink: &Signed) -> PeerId {
        let leave = matches!(shrink.payload, Payload::Op(GroupOp::Leave));
        if !leave && self.role(&shrink.author).unwrap_or(Role::Member) >= Role::Admin {
            shrink.author
        } else {
            self.owner
        }
    }

    /// An op no fold can ever apply, whatever else arrives (a picture over its size cap, a
    /// second Create, a plain member's picture in a community): never held, never stored.
    /// Always a subset of what `apply` rejects, so dropping it can't change a fold.
    pub fn never_valid(&self, s: &Signed) -> bool {
        // (never by the author's role: the role it had when it signed — what the fold
        // judges by — may differ from the one it has now)
        match &s.payload {
            Payload::Op(GroupOp::Create { .. }) => self.ops.first().map(|c| c.id != s.id).unwrap_or(false),
            Payload::Op(GroupOp::Cover { cover }) => cover.len() > MAX_COVER,
            Payload::Op(GroupOp::Meta { avatar, .. }) => avatar.len() > MAX_GROUP_AVATAR,
            _ => false,
        }
    }

    /// Superseded pictures: only the latest applied Cover / Meta matters (`cover()`, the
    /// avatar, `compact_ops`), so the bytes of the older ones are dropped from the op log —
    /// a member changing the cover every 10 minutes would otherwise grow the state (and
    /// every save of it) by 300 KB each time. The ops themselves stay (same id, hlc,
    /// author, signature), so every fold — rate limits included — is unchanged.
    ///
    /// The latest [`KEEP_PICTURES`] of each kind keep their bytes: the newest one may still
    /// be rejected by a later re-fold (a demotion that sorts before it arrives), and the
    /// one before it then shows instead of an empty picture. A stripped op that becomes the
    /// latest anyway changes nothing (see `apply`, `cover_op`).
    fn strip_superseded_pictures(&mut self) {
        let (mut covers, mut metas) = (0usize, 0usize);
        for o in self.ops.iter_mut().rev() {
            match &mut o.payload {
                Payload::Op(GroupOp::Cover { cover }) => {
                    covers += 1;
                    if covers > KEEP_PICTURES && !cover.is_empty() {
                        *cover = Vec::new();
                    }
                }
                Payload::Op(GroupOp::Meta { avatar, .. }) => {
                    metas += 1;
                    if metas > KEEP_PICTURES && !avatar.is_empty() {
                        *avatar = Vec::new();
                    }
                }
                _ => {}
            }
        }
    }

    /// Ids of the picture ops whose stored envelopes are no longer needed: every Cover /
    /// Meta in the op log except the latest applied one of each, and those still held
    /// (rejected; their copy in `held` is what a later fold uses).
    pub fn superseded_picture_ids(&self, held: &[Signed]) -> Vec<[u8; 16]> {
        let is_pic = |o: &Signed| matches!(o.payload, Payload::Op(GroupOp::Cover { .. } | GroupOp::Meta { .. }));
        let latest = |cover: bool| {
            self.ops
                .iter()
                .rev()
                .filter(move |o| matches!((&o.payload, cover), (Payload::Op(GroupOp::Cover { .. }), true) | (Payload::Op(GroupOp::Meta { .. }), false)))
                .take(KEEP_PICTURES)
                .map(|o| o.id)
        };
        let keep: Vec<[u8; 16]> = latest(true).chain(latest(false)).collect();
        self.ops.iter().chain(held.iter()).filter(|o| is_pic(o) && !keep.contains(&o.id)).map(|o| o.id).collect()
    }

    /// `p` is out because of its own Leave, made while it was the owner, at most
    /// [`DISSOLVE_AFTER_LEAVE_MS`] before `hlc`.
    fn left_as_owner_before(&self, p: &PeerId, hlc: u64) -> bool {
        let Some(i) = self.ops.iter().rposition(|o| match &o.payload {
            Payload::Op(GroupOp::Leave) => o.author == *p,
            Payload::Op(GroupOp::Remove { peer } | GroupOp::Ban { peer } | GroupOp::Add { peer } | GroupOp::AddBot { peer, .. }) => peer == p,
            _ => false,
        }) else {
            return false;
        };
        let leave = &self.ops[i];
        if !matches!(leave.payload, Payload::Op(GroupOp::Leave)) || leave.hlc.saturating_add(DISSOLVE_AFTER_LEAVE_MS << 8) < hlc {
            return false;
        }
        // Only a Dissolve racing the Leave itself: once anything else was applied after the
        // Leave (the successor, or anyone, acted), the ex-owner has no say any more — it
        // can't come back within the hour and delete the group from under its new owner.
        // (Ops apply in creation order, so this is the same on every member.)
        if i + 1 < self.ops.len() {
            return false;
        }
        // the owner just before that Leave (ownership only ever moves on an owner's Leave)
        GroupState::fold(self.gid, self.ops[..i].to_vec()).map(|st| st.owner == *p).unwrap_or(false)
    }

    /// Apply one more signed op: incremental when it sorts after every op we have (the
    /// common case — no O(n) re-fold per message), a full fold otherwise. Returns the new
    /// state and whether the op was applied.
    ///
    /// `held`: verified ops the fold rejected so far (e.g. an admin's op that arrived before
    /// the promotion that makes it valid). They take part in every fold, so the result is
    /// the fold of everything received whatever the arrival order; on return it holds the
    /// ops that are still rejected (bounded, newest kept).
    pub fn with_op(&self, op: Signed, held: &mut Vec<Signed>) -> Result<(GroupState, bool)> {
        if self.never_valid(&op) {
            return Ok((self.clone(), false));
        }
        let key = |o: &Signed| (o.hlc, o.author.0, o.id, o.sig.clone());
        let id = op.id;
        let k = key(&op);
        let after_all = self.ops.last().map(|l| k > key(l)).unwrap_or(false) && held.iter().all(|h| key(h) < k);
        if after_all && !self.ops.iter().any(|o| o.id == id) {
            let mut st = self.clone();
            if st.apply(&op) {
                st.last_op_hlc = st.last_op_hlc.max(op.hlc);
                let pic = matches!(op.payload, Payload::Op(GroupOp::Cover { .. } | GroupOp::Meta { .. }));
                st.ops.push(op);
                if pic {
                    st.strip_superseded_pictures();
                }
                return Ok((st, true));
            }
            held.push(op);
            Self::bound_held(held);
            return Ok((st, false));
        }
        let mut ops = self.ops.clone();
        ops.extend(held.iter().cloned());
        ops.push(op.clone());
        let st = GroupState::fold(self.gid, ops)?;
        let applied: std::collections::HashSet<([u8; 16], Vec<u8>)> = st.ops.iter().map(|o| (o.id, o.sig.clone())).collect();
        // everything that is not applied now is held — including ops applied before that
        // an earlier-sorting op (a demotion, a removal) has just made invalid
        held.push(op.clone());
        held.extend(self.ops.iter().cloned());
        held.retain(|h| !applied.contains(&(h.id, h.sig.clone())));
        held.sort_by_key(key);
        held.dedup_by(|a, b| a.id == b.id && a.sig == b.sig);
        Self::bound_held(held);
        Ok((st, applied.contains(&(id, op.sig))))
    }

    /// Newest kept: at most [`MAX_HELD_OPS`] ops and [`MAX_HELD_BYTES`] bytes.
    fn bound_held(held: &mut Vec<Signed>) {
        let bytes: usize = held.iter().map(Self::held_weight).sum();
        if held.len() > MAX_HELD_OPS || bytes > MAX_HELD_BYTES {
            held.sort_by_key(|h| std::cmp::Reverse(h.hlc));
            let mut total = 0usize;
            let keep = held
                .iter()
                .take(MAX_HELD_OPS)
                .take_while(|h| {
                    total += Self::held_weight(h);
                    total <= MAX_HELD_BYTES
                })
                .count();
            held.truncate(keep);
            held.sort_by(|a, b| (a.hlc, a.author.0, a.id).cmp(&(b.hlc, b.author.0, b.id)));
        }
    }

    /// Approximate stored size of a held op (its variable-length parts + a fixed overhead).
    fn held_weight(o: &Signed) -> usize {
        160 + o.sig.len()
            + match &o.payload {
                Payload::Op(GroupOp::Cover { cover }) => cover.len(),
                Payload::Op(GroupOp::Meta { avatar, description }) => avatar.len() + description.len(),
                Payload::Op(GroupOp::Create { name, members, .. }) => name.len() + members.len() * 33,
                Payload::Op(GroupOp::Rename { name } | GroupOp::Channel { name, .. }) => name.len(),
                Payload::Op(GroupOp::Visibility { handle, .. }) => handle.len(),
                Payload::Op(GroupOp::RoleSet { id, name, color, .. }) => id.len() + name.len() + color.len(),
                Payload::Op(GroupOp::RoleDelete { id }) => id.len(),
                Payload::Op(GroupOp::MemberRoles { roles, .. }) => roles.iter().map(|r| r.len() + 2).sum(),
                Payload::Op(GroupOp::ChannelUpdate { name, new_name, topic, category, allow_roles, .. }) => {
                    name.len()
                        + new_name.as_ref().map_or(0, |x| x.len())
                        + topic.as_ref().map_or(0, |x| x.len())
                        + category.as_ref().map_or(0, |x| x.len())
                        + allow_roles.as_ref().map_or(0, |v| v.iter().map(|r| r.len() + 2).sum())
                }
                _ => 0,
            }
    }

    /// The ops a new member needs: superseded group settings (an older picture, name,
    /// slow-mode setting or visibility a later applied op replaced in full) are left out —
    /// dozens of 96 KB pictures would otherwise make the Welcome too large to deliver.
    pub fn compact_ops(&self) -> Vec<Signed> {
        let mut seen = [false; 5];
        let mut out: Vec<Signed> = self
            .ops
            .iter()
            .rev()
            .filter(|o| {
                let slot = match &o.payload {
                    Payload::Op(GroupOp::Meta { .. }) => 0,
                    Payload::Op(GroupOp::Rename { .. }) => 1,
                    Payload::Op(GroupOp::Settings { .. }) => 2,
                    Payload::Op(GroupOp::Visibility { .. }) => 3,
                    Payload::Op(GroupOp::Cover { .. }) => 4,
                    _ => return true,
                };
                // (a picture op whose bytes were stripped here — see
                // `strip_superseded_pictures` — no longer verifies: never sent; the latest
                // one that still has its bytes goes instead)
                if (slot == 0 || slot == 4) && Self::stripped(o) {
                    return false;
                }
                !std::mem::replace(&mut seen[slot], true)
            })
            .cloned()
            .collect();
        out.reverse();
        out
    }

    /// A picture op whose bytes `strip_superseded_pictures` dropped (it no longer verifies).
    fn stripped(o: &Signed) -> bool {
        match &o.payload {
            Payload::Op(GroupOp::Cover { cover }) => cover.is_empty() && !o.verify(),
            Payload::Op(GroupOp::Meta { avatar, .. }) => avatar.is_empty() && !o.verify(),
            _ => false,
        }
    }

    /// Slow mode / announcement mode in effect at `hlc` (content is judged by the settings
    /// of when it was written, so late history isn't dropped).
    pub fn settings_at(&self, hlc: u64) -> (u32, bool) {
        self.ops
            .iter()
            .rev()
            .filter(|o| o.hlc <= hlc)
            .find_map(|o| match &o.payload {
                Payload::Op(GroupOp::Settings { slow_mode_s, admins_only }) => Some(((*slow_mode_s).min(3600), *admins_only)),
                _ => None,
            })
            .unwrap_or((0, false))
    }

    /// `p`'s role at `hlc` (None: not a member then).
    pub fn role_at(&self, p: &PeerId, hlc: u64) -> Option<Role> {
        let owner_left = |o: &Signed| (matches!(o.payload, Payload::Op(GroupOp::Leave)) && o.author != *p) || matches!(o.payload, Payload::Op(GroupOp::TransferOwner { .. }));
        let touches = |o: &Signed| match &o.payload {
            Payload::Op(
                GroupOp::Add { peer } | GroupOp::AddBot { peer, .. } | GroupOp::Remove { peer } | GroupOp::Ban { peer } | GroupOp::SetRole { peer, .. },
            ) => peer == p,
            Payload::Op(GroupOp::Leave) => o.author == *p,
            _ => false,
        };
        // nothing about `p` changed since `hlc` (nor did anyone leave, which may pass on
        // the ownership): the current role is the role then
        if !self.ops.iter().rev().take_while(|o| o.hlc > hlc).any(|o| touches(o) || owner_left(o)) {
            return self.role(p);
        }
        self.prefix_state(self.ops.partition_point(|o| o.hlc <= hlc)).role(p)
    }

    /// When `p` last joined (the op that added it, or the group's creation).
    pub fn join_hlc(&self, p: &PeerId) -> Option<u64> {
        let added = self.ops.iter().rev().find_map(|o| match &o.payload {
            Payload::Op(GroupOp::Add { peer } | GroupOp::AddBot { peer, .. }) if peer == p => Some(o.hlc),
            _ => None,
        });
        added.or_else(|| match self.ops.first().map(|o| &o.payload) {
            Some(Payload::Op(GroupOp::Create { members, .. })) if members.contains(p) || *p == self.owner || self.ops[0].author == *p => Some(self.created),
            _ => None,
        })
    }

    /// The epoch current when `p` last joined (older keys are not for it).
    pub fn joined_epoch(&self, p: &PeerId) -> u64 {
        let Some(at) = self.join_hlc(p) else { return self.epoch };
        self.ops
            .iter()
            .filter(|o| o.hlc < at)
            .filter(|o| matches!(&o.payload, Payload::Op(GroupOp::Rekey { epoch, commit }) if self.key_commits.get(epoch) == Some(commit)))
            .count() as u64
    }

    /// Creation time of the latest op dated after `after` that took rights away from `p`:
    /// removed, banned, demoted, left, timed out, or a role / permission change (its roles,
    /// a role's permissions, a deleted role, the ownership handed over) that lowered `p`'s
    /// permissions. What `p` dates well before it is not accepted any more: an ex-admin
    /// can't backdate ops to when it still was one.
    pub fn rights_cut_after(&self, p: &PeerId, after: u64) -> Option<u64> {
        let start = self.ops.partition_point(|o| o.hlc <= after).max(1);
        if start >= self.ops.len() {
            return None;
        }
        let tail = &self.ops[start..];
        let simple = |o: &Signed| match &o.payload {
            Payload::Op(GroupOp::Remove { peer } | GroupOp::Ban { peer }) => peer == p,
            Payload::Op(GroupOp::SetRole { peer, role: Role::Member }) => peer == p,
            Payload::Op(GroupOp::Timeout { peer, until_ms }) => peer == p && *until_ms > 0,
            Payload::Op(GroupOp::Leave) => o.author == *p,
            _ => false,
        };
        let perms_op = |o: &Signed| {
            matches!(&o.payload, Payload::Op(GroupOp::MemberRoles { .. } | GroupOp::RoleSet { .. } | GroupOp::RoleDelete { .. } | GroupOp::TransferOwner { .. } | GroupOp::SetRole { .. }))
        };
        let mut cut = tail.iter().rev().find(|o| simple(o)).map(|o| o.hlc);
        if tail.iter().any(perms_op) {
            // replay from the prefix: did `p`'s permissions lose a bit at such an op?
            let mut st = (*self.prefix_state(start)).clone();
            for o in tail {
                let before = st.perms_of(p);
                if st.apply(o) {
                    st.ops.push(o.clone());
                }
                if perms_op(o) && before & !st.perms_of(p) != 0 {
                    cut = cut.max(Some(o.hlc));
                }
            }
        }
        cut
    }

    /// Did an op dated after `after` change what `p` may post (its membership, roles,
    /// timeout, a role's permissions, a channel's settings, the group's announcement mode)?
    pub fn posting_rules_changed_after(&self, p: &PeerId, after: u64) -> bool {
        self.ops.iter().rev().take_while(|o| o.hlc > after).any(|o| Self::matters_for(o, p) || matches!(o.payload, Payload::Op(GroupOp::Settings { .. })))
    }

    /// The fold of the first `len` ops (len ≥ 1), from the snapshot cache.
    pub fn prefix_state(&self, len: usize) -> std::sync::Arc<GroupState> {
        let len = len.clamp(1, self.ops.len().max(1));
        if len >= self.ops.len() {
            let mut me = self.clone();
            me.ext.snapshots = Snapshots::default();
            return std::sync::Arc::new(me);
        }
        // hashes of every prefix a snapshot has the length of (one pass over the ids)
        let lens: Vec<usize> = self.ext.snapshots.0.lock().iter().map(|(_, l, _)| *l).filter(|l| *l <= len).collect();
        let mut h = blake3::Hasher::new_derive_key("lumora group prefix v1");
        let mut at: Vec<(usize, [u8; 32])> = vec![];
        for (i, o) in self.ops[..len].iter().enumerate() {
            h.update(&o.id);
            h.update(&o.sig);
            if lens.contains(&(i + 1)) || i + 1 == len {
                at.push((i + 1, *h.clone().finalize().as_bytes()));
            }
        }
        let key = at.last().map(|(_, k)| *k).unwrap_or_default();
        let base = {
            let snaps = self.ext.snapshots.0.lock();
            if let Some((_, _, st)) = snaps.iter().find(|(k, l, _)| *l == len && *k == key) {
                return st.clone();
            }
            snaps.iter().filter(|(k, l, _)| at.iter().any(|(al, ak)| al == l && ak == k)).max_by_key(|(_, l, _)| *l).map(|(_, l, st)| (*l, st.clone()))
        };
        let st = match base {
            Some((l, b)) => {
                let mut st = (*b).clone();
                for o in &self.ops[l..len] {
                    if st.apply(o) {
                        st.last_op_hlc = st.last_op_hlc.max(o.hlc);
                        st.ops.push(o.clone());
                    }
                }
                st
            }
            None => match GroupState::fold(self.gid, self.ops[..len].to_vec()) {
                Ok(st) => st,
                Err(_) => self.clone(),
            },
        };
        let mut st = st;
        st.ext.snapshots = Snapshots::default(); // (no Arc cycle through the cache)
        let st = std::sync::Arc::new(st);
        let mut snaps = self.ext.snapshots.0.lock();
        if snaps.len() >= MAX_SNAPSHOTS {
            // catch-up walks forward: the shortest prefixes are the least useful
            if let Some(i) = snaps.iter().enumerate().min_by_key(|(_, (_, l, _))| *l).map(|(i, _)| i) {
                snaps.swap_remove(i);
            }
        }
        snaps.push((key, len, st.clone()));
        st
    }

    /// Channel names ever declared (messages written to a channel that was later removed
    /// are still valid history).
    pub fn channel_declared(&self, name: &str) -> bool {
        name.is_empty()
            || self.channels.iter().any(|c| c.name == name && !c.voice)
            || self.ops.iter().any(|o| matches!(&o.payload, Payload::Op(GroupOp::Channel { name: n, voice: false, remove: false }) if n == name))
    }

    /// Rebuild state from a set of signed ops (any order, duplicates ok).
    pub fn fold(gid: Gid, mut ops: Vec<Signed>) -> Result<GroupState> {
        // The signature is the last tie-break: two different ops a (malicious) author signed
        // with the same id and clock must still fold the same on every member, whatever order
        // they arrived in (found by fuzzing: core/fuzz group_fold).
        ops.sort_by(|a, b| (a.hlc, a.author.0, a.id, &a.sig).cmp(&(b.hlc, b.author.0, b.id, &b.sig)));
        ops.dedup_by(|a, b| a.id == b.id);
        let first = ops.first().ok_or_else(|| anyhow!("empty op log"))?;
        let (name, members, kind) = match &first.payload {
            Payload::Op(GroupOp::Create { name, members, kind }) => (name.clone(), members.clone(), *kind),
            _ => bail!("first op must be Create"),
        };
        // gid is bound to the creator + creation op id so nobody can forge a Create.
        if gid != derive_gid(&first.author, &first.id) {
            bail!("gid does not match creator");
        }
        let mut st = GroupState {
            gid,
            name,
            kind,
            owner: first.author,
            members: BTreeMap::new(),
            epoch: 0,
            channels: if kind == 1 {
                vec![Channel { name: "general".into(), voice: false }, Channel { name: "voice".into(), voice: true }]
            } else {
                vec![]
            },
            created: first.hlc,
            ops: vec![first.clone()],
            left: vec![],
            avatar: vec![],
            description: String::new(),
            key_commits: BTreeMap::new(),
            last_op_hlc: first.hlc,
            banned: vec![],
            slow_mode_s: 0,
            admins_only: false,
            bots: BTreeMap::new(),
            public: false,
            handle: String::new(),
            ext: Community::default(),
        };
        st.members.insert(first.author, Role::Owner);
        for m in members {
            st.members.entry(m).or_insert(Role::Member);
        }
        for op in ops.into_iter().skip(1) {
            if st.apply(&op) {
                st.last_op_hlc = st.last_op_hlc.max(op.hlc);
                st.ops.push(op);
            }
        }
        st.strip_superseded_pictures();
        Ok(st)
    }

    /// Validate + apply one op. Returns false if rejected (no permission / invalid).
    fn apply(&mut self, s: &Signed) -> bool {
        let Payload::Op(op) = &s.payload else { return false };
        if self.dissolved() {
            return false; // deleted: final
        }
        let actor = match self.role(&s.author) {
            Some(r) => r,
            // the owner's Dissolve stays final even though its own Leave sorts first (signed
            // concurrently, e.g. on two of its devices): otherwise the outcome would depend
            // on which of the two a member received first
            None => return matches!(op, GroupOp::Dissolve) && self.left_as_owner_before(&s.author, s.hlc),
        };
        // Community 2.0 rules (permissions) once the group switched to them; before that
        // exactly the rules 1.0.7 folds by (it may still be a member)
        let v2 = self.ext.rules_v2;
        let a = &s.author;
        match op {
            GroupOp::Create { .. } => false,
            GroupOp::RulesV2 => {
                if v2 || actor < Role::Admin || s.hlc < V2_RULES_HLC {
                    return false;
                }
                self.ext.rules_v2 = true;
                true
            }
            // the Community 2.0 kinds only exist under its rules
            GroupOp::RoleSet { .. }
            | GroupOp::RoleDelete { .. }
            | GroupOp::MemberRoles { .. }
            | GroupOp::Timeout { .. }
            | GroupOp::ChannelUpdate { .. }
            | GroupOp::TransferOwner { .. }
            | GroupOp::RevokeInvite { .. }
            | GroupOp::JoinApproval { .. }
                if !v2 =>
            {
                false
            }
            GroupOp::Add { peer } => {
                if v2 {
                    if !self.has(a, perm::INVITE) {
                        return false;
                    }
                    // banned or removed by an admin: only admins bring them back
                    if (self.banned.contains(peer) || self.ext.removed.contains(peer)) && actor < Role::Admin {
                        return false;
                    }
                } else {
                    if actor < Role::Admin && self.kind == 1 {
                        return false; // communities: only admins add
                    }
                    if self.banned.contains(peer) && actor < Role::Admin {
                        return false; // only admins can bring back a banned member
                    }
                }
                self.left.retain(|p| p != peer);
                self.banned.retain(|p| p != peer);
                self.ext.removed.retain(|p| p != peer);
                self.members.entry(*peer).or_insert(Role::Member);
                true
            }
            GroupOp::Remove { peer } => {
                let target = match self.role(peer) {
                    Some(r) => r,
                    None => return false,
                };
                if v2 {
                    let bot = self.bots.contains_key(peer);
                    if !(self.has(a, perm::KICK) || (bot && self.has(a, perm::MANAGE_BOTS))) || !self.may_moderate(a, peer) {
                        return false;
                    }
                } else if actor < Role::Admin || target >= actor {
                    return false;
                }
                self.members.remove(peer);
                self.bots.remove(peer);
                if !self.left.contains(peer) {
                    self.left.push(*peer);
                }
                self.ext.forget_member(peer);
                if !self.ext.removed.contains(peer) {
                    self.ext.removed.push(*peer);
                }
                true
            }
            GroupOp::SetRole { peer, role } => {
                if actor != Role::Owner || *role == Role::Owner || !self.is_member(peer) || *peer == self.owner {
                    return false;
                }
                self.members.insert(*peer, *role);
                if v2 && *role == Role::Member {
                    // an admin's rights role means nothing to a member: gone with the demotion
                    let rid = format!("{}{}", community::ADMIN_RIGHTS_PREFIX, peer.to_base32());
                    if let Some(v) = self.ext.member_roles.get_mut(peer) {
                        v.retain(|r| *r != rid);
                    }
                    self.ext.member_roles.retain(|_, v| !v.is_empty());
                }
                true
            }
            GroupOp::Rename { name } => {
                let limited = actor < Role::Admin && self.recent_op_by(a, s.hlc, MEMBER_RENAME_GAP_MS, |o| matches!(o, GroupOp::Rename { .. }));
                let ok = if v2 { self.has(a, perm::MANAGE_COMMUNITY) && !limited } else { actor >= Role::Admin || (self.kind != 1 && !limited) };
                if !ok {
                    return false;
                }
                self.name = name.chars().take(64).collect();
                true
            }
            GroupOp::Leave => {
                self.members.remove(a);
                if !self.left.contains(a) {
                    self.left.push(*a);
                }
                self.ext.forget_member(a);
                if *a == self.owner {
                    let next = if v2 {
                        self.successor()
                    } else {
                        // (before 2.0: longest-standing admin, else longest member — by key order)
                        self.members.iter().find(|(_, r)| **r == Role::Admin).or_else(|| self.members.iter().next()).map(|(p, _)| *p)
                    };
                    if let Some(n) = next {
                        self.owner = n;
                        self.members.insert(n, Role::Owner);
                    }
                }
                true
            }
            GroupOp::Rekey { epoch, commit } => {
                // only admins/owner rotate, strictly one epoch at a time (no u64::MAX bricking)
                if actor < Role::Admin {
                    return false;
                }
                if *epoch == self.epoch.saturating_add(1) {
                    // the first Rekey for an epoch in fold order — the lowest (hlc, author, id,
                    // sig) — wins on every member, whatever order they saw them in
                    self.epoch = *epoch;
                    self.key_commits.insert(*epoch, *commit);
                    return true;
                }
                // A concurrent rotation that lost: kept (its key still opens what its author
                // sent before learning about the winner), bounded per epoch.
                *epoch >= 1
                    && epoch.saturating_add(MAX_LOSER_EPOCH_LAG) >= self.epoch
                    && *epoch <= self.epoch
                    && self.key_commits.get(epoch) != Some(commit)
                    && self.rekey_ops(*epoch).count() < MAX_REKEYS_PER_EPOCH
                    && !self.rekey_ops(*epoch).any(|c| c == commit)
            }
            GroupOp::Visibility { public, handle } => {
                if !self.allowed(v2, actor, a, perm::MANAGE_COMMUNITY) {
                    return false;
                }
                self.public = *public;
                self.handle = handle.chars().take(24).collect();
                true
            }
            GroupOp::AddBot { peer, read_all } => {
                // bots join as plain members (no admin rights)
                if !self.allowed(v2, actor, a, perm::MANAGE_BOTS) || self.banned.contains(peer) {
                    return false;
                }
                // `manage_bots` is no back door: someone an admin removed comes back only by
                // an admin, and a member (a person) is never turned into a bot
                if v2 && ((self.ext.removed.contains(peer) && actor < Role::Admin) || (self.is_member(peer) && !self.bots.contains_key(peer))) {
                    return false;
                }
                self.left.retain(|p| p != peer);
                self.ext.removed.retain(|p| p != peer);
                self.members.entry(*peer).or_insert(Role::Member);
                self.bots.insert(*peer, *read_all);
                true
            }
            GroupOp::SetBotPolicy { peer, read_all } => {
                if !self.allowed(v2, actor, a, perm::MANAGE_BOTS) || !self.bots.contains_key(peer) {
                    return false;
                }
                self.bots.insert(*peer, *read_all);
                true
            }
            GroupOp::Ban { peer } => {
                let ok = if v2 {
                    self.has(a, perm::BAN) && *peer != self.owner && peer != a && (!self.is_member(peer) || self.may_moderate(a, peer))
                } else {
                    let target = self.role(peer).unwrap_or(Role::Member);
                    !(actor < Role::Admin || (self.is_member(peer) && target >= actor) || *peer == self.owner)
                };
                if !ok {
                    return false;
                }
                self.members.remove(peer);
                if v2 {
                    self.bots.remove(peer); // (1.0.7 kept the bot flag: so do its rules)
                }
                if !self.left.contains(peer) {
                    self.left.push(*peer);
                }
                if !self.banned.contains(peer) {
                    self.banned.push(*peer);
                }
                self.ext.forget_member(peer);
                true
            }
            GroupOp::Unban { peer } => {
                if !self.allowed(v2, actor, a, perm::BAN) {
                    return false;
                }
                self.banned.retain(|p| p != peer);
                true
            }
            GroupOp::Settings { slow_mode_s, admins_only } => {
                if !self.allowed(v2, actor, a, perm::MANAGE_COMMUNITY) {
                    return false;
                }
                self.slow_mode_s = (*slow_mode_s).min(3600);
                self.admins_only = *admins_only;
                true
            }
            GroupOp::Meta { avatar, description } => {
                // (an op whose picture bytes were stripped — it was superseded — that is the
                // latest again after a re-fold: keeps the picture we have)
                let stripped = avatar.is_empty() && Self::stripped(s);
                // a change is part of the op log each new member receives: plain members
                // (when allowed at all) not over and over
                let limited = actor < Role::Admin && self.recent_op_by(a, s.hlc, MEMBER_META_GAP_MS, |o| matches!(o, GroupOp::Meta { .. }));
                let ok = if v2 { self.has(a, perm::MANAGE_COMMUNITY) && !limited } else { actor >= Role::Admin || (self.kind != 1 && !limited) };
                if !ok || avatar.len() > MAX_GROUP_AVATAR {
                    return false;
                }
                if !stripped {
                    self.avatar = avatar.clone();
                }
                self.description = description.chars().take(500).collect();
                true
            }
            GroupOp::Cover { cover } => {
                // the avatar's rules
                let limited = actor < Role::Admin && self.recent_op_by(a, s.hlc, MEMBER_META_GAP_MS, |o| matches!(o, GroupOp::Cover { .. }));
                let ok = if v2 { self.has(a, perm::MANAGE_COMMUNITY) && !limited } else { actor >= Role::Admin || (self.kind != 1 && !limited) };
                ok && cover.len() <= MAX_COVER
            }
            GroupOp::Dissolve => actor == Role::Owner,
            GroupOp::Channel { name, voice, remove } => {
                if !self.allowed(v2, actor, a, perm::MANAGE_CHANNELS) {
                    return false;
                }
                let existed = self.channels.iter().any(|c| &c.name == name);
                self.channels.retain(|c| &c.name != name);
                if *remove {
                    self.ext.chan.remove(name);
                } else {
                    self.channels.push(Channel { name: name.clone(), voice: *voice });
                    if !existed && self.ext.chan.values().any(|m| m.position.is_some()) {
                        // a new channel goes last
                        let order: Vec<String> = self.channel_order().into_iter().map(|c| c.name.clone()).collect();
                        self.set_positions(&order);
                    }
                }
                true
            }
            GroupOp::RoleSet { id, name, color, perms, position } => {
                if !self.has(a, perm::MANAGE_ROLES) || id == community::ADMIN || id.is_empty() || id.len() > 80 {
                    return false;
                }
                let mine = self.perms_of(a);
                let mut perms = perms & perm::ALL;
                if id == community::EVERYONE {
                    // (communities: managing the community is never everyone's)
                    if self.kind == 1 {
                        perms &= !perm::MANAGE_COMMUNITY;
                    }
                    let old = self.ext.everyone_perms(self.kind);
                    if (perms & !old) & !mine != 0 {
                        return false; // nobody grants what they don't hold
                    }
                    self.ext.everyone = Some(perms);
                    return true;
                }
                let rights = id.starts_with(community::ADMIN_RIGHTS_PREFIX);
                if rights && actor != Role::Owner {
                    return false; // an admin's rights: the owner's call
                }
                let existing = self.ext.role(id).cloned();
                let old = existing.as_ref().map(|r| r.perms).unwrap_or(0);
                // nobody edits a role above its own rights (old & !mine), nor grants more
                if old & !mine != 0 || (perms & !old) & !mine != 0 || (existing.is_none() && self.ext.roles.len() >= community::MAX_ROLES) {
                    return false;
                }
                let name: String = if rights { id.clone() } else { name.trim().chars().take(32).collect() };
                let name = if name.is_empty() {
                    match &existing {
                        Some(r) => r.name.clone(),
                        None => return false,
                    }
                } else {
                    name
                };
                let color = if rights { community::ADMIN_COLOR.to_string() } else { community::clean_color(color) };
                self.ext.place_role(RoleDef { id: id.clone(), name, color, perms }, *position, existing.is_none());
                true
            }
            GroupOp::RoleDelete { id } => {
                if !self.has(a, perm::MANAGE_ROLES) || id == community::ADMIN || id == community::EVERYONE || self.ext.role(id).is_none() {
                    return false;
                }
                if id.starts_with(community::ADMIN_RIGHTS_PREFIX) && actor != Role::Owner {
                    return false;
                }
                // a role with rights its deleter lacks: not its call
                if self.ext.role(id).is_some_and(|r| r.perms & !self.perms_of(a) != 0) {
                    return false;
                }
                self.ext.delete_role(id);
                true
            }
            GroupOp::MemberRoles { peer, roles } => {
                // an admin's / the owner's roles are the owner's call
                if !self.has(a, perm::MANAGE_ROLES) || !self.is_member(peer) || (self.role(peer).unwrap_or(Role::Member) >= Role::Admin && actor != Role::Owner) {
                    return false;
                }
                let own_rights = format!("{}{}", community::ADMIN_RIGHTS_PREFIX, peer.to_base32());
                let mut new: Vec<String> = vec![];
                for r in roles {
                    let known = self.ext.role(r).is_some() && (!r.starts_with(community::ADMIN_RIGHTS_PREFIX) || *r == own_rights);
                    if known && !new.contains(r) && new.len() < community::MAX_MEMBER_ROLES {
                        new.push(r.clone());
                    }
                }
                let old = self.ext.roles_of(peer).to_vec();
                let mine = self.perms_of(a);
                // given or taken away: only roles within the actor's own rights
                for r in new.iter().filter(|r| !old.contains(r)).chain(old.iter().filter(|r| !new.contains(r))) {
                    let p = self.ext.role(r).map(|x| x.perms).unwrap_or(0);
                    if p & !mine != 0 {
                        return false;
                    }
                }
                let rights_changed = new.iter().chain(old.iter()).any(|r| r.starts_with(community::ADMIN_RIGHTS_PREFIX) && (new.contains(r) != old.contains(r)));
                if rights_changed && actor != Role::Owner {
                    return false;
                }
                if new.is_empty() {
                    self.ext.member_roles.remove(peer);
                } else {
                    self.ext.member_roles.insert(*peer, new);
                }
                true
            }
            GroupOp::Timeout { peer, until_ms } => {
                if !self.has(a, perm::TIMEOUT) || !self.is_member(peer) || !self.may_moderate(a, peer) {
                    return false;
                }
                let cap = crate::util::hlc_to_ms(s.hlc).saturating_add(366 * 86_400_000);
                if *until_ms == 0 {
                    self.ext.timeouts.remove(peer);
                } else {
                    self.ext.timeouts.insert(*peer, (*until_ms).min(cap));
                }
                true
            }
            GroupOp::ChannelUpdate { name, new_name, topic, category, position, private, allow_roles, announce } => {
                if !self.has(a, perm::MANAGE_CHANNELS) || !self.channels.iter().any(|c| &c.name == name) {
                    return false;
                }
                let new_name: Option<String> = match new_name.as_deref().map(clean_channel_name) {
                    Some(n) if n.is_empty() => return false,
                    Some(n) if &n == name => Some(String::new()), // back to its key
                    Some(n) => {
                        // a name another channel shows (or is keyed by) is taken
                        if self.channels.iter().any(|c| &c.name != name && (c.name == n || self.channel_name(&c.name) == n)) {
                            return false;
                        }
                        Some(n)
                    }
                    None => None,
                };
                let known: Vec<String> = allow_roles.as_ref().map(|v| {
                    let mut out: Vec<String> = vec![];
                    for r in v {
                        if (r == community::EVERYONE || self.ext.role(r).is_some()) && !out.contains(r) && out.len() < community::MAX_MEMBER_ROLES {
                            out.push(r.clone());
                        }
                    }
                    out
                }).unwrap_or_default();
                let m = self.ext.chan.entry(name.clone()).or_default();
                if let Some(n) = new_name {
                    m.name = if n.is_empty() { None } else { Some(n) };
                }
                if let Some(t) = topic {
                    m.topic = t.trim().chars().take(1024).collect();
                }
                if let Some(c) = category {
                    m.category = c.trim().chars().take(32).collect();
                }
                if let Some(p) = private {
                    m.private = *p;
                }
                if allow_roles.is_some() {
                    m.allow_roles = known;
                }
                if let Some(x) = announce {
                    m.announce = *x;
                }
                if let Some(p) = position {
                    let mut order: Vec<String> = self.channel_order().into_iter().map(|c| c.name.clone()).collect();
                    order.retain(|c| c != name);
                    order.insert((*p as usize).min(order.len()), name.clone());
                    self.set_positions(&order);
                }
                true
            }
            GroupOp::TransferOwner { peer } => {
                if actor != Role::Owner || !self.is_member(peer) || peer == a || self.bots.contains_key(peer) {
                    return false;
                }
                self.members.insert(*a, Role::Admin);
                self.members.insert(*peer, Role::Owner);
                self.owner = *peer;
                true
            }
            GroupOp::RevokeInvite { id } => {
                // one link: `invite`; every link at once: managing the community
                if !self.has(a, perm::INVITE) || (id.is_none() && !self.has(a, perm::MANAGE_COMMUNITY)) {
                    return false;
                }
                match id {
                    Some(id) => {
                        if !self.ext.revoked.contains(id) {
                            if self.ext.revoked.len() >= community::MAX_REVOKED {
                                self.ext.revoked.remove(0);
                            }
                            self.ext.revoked.push(*id);
                        }
                    }
                    None => self.ext.revoked_before_ms = self.ext.revoked_before_ms.max(crate::util::hlc_to_ms(s.hlc)),
                }
                true
            }
            GroupOp::JoinApproval { on } => {
                if !self.has(a, perm::MANAGE_COMMUNITY) {
                    return false;
                }
                self.ext.approve_joins = *on;
                true
            }
        }
    }

    /// Before 2.0 the right was "admin or owner"; since then it is a permission.
    fn allowed(&self, v2: bool, actor: Role, a: &PeerId, bit: u32) -> bool {
        if v2 {
            self.has(a, bit)
        } else {
            actor >= Role::Admin
        }
    }

    /// The owner who left gets a successor: the admin who joined first, else the member
    /// who joined first (bots only when nobody else is left). Join order is the group's
    /// own history (`join_hlc`), the same on every member.
    fn successor(&self) -> Option<PeerId> {
        let order = |p: &PeerId| (self.join_hlc(p).unwrap_or(u64::MAX), *p);
        let humans: Vec<PeerId> = self.members.keys().filter(|p| !self.bots.contains_key(p)).copied().collect();
        humans
            .iter()
            .filter(|p| self.role(p) == Some(Role::Admin))
            .min_by_key(|p| order(p))
            .or_else(|| humans.iter().min_by_key(|p| order(p)))
            .copied()
            .or_else(|| self.members.keys().min_by_key(|p| order(p)).copied())
    }

    // ---------------------------------------------------------------- Community 2.0

    /// Decode a stored / synced state: the derived part (`ext`) is rebuilt by re-folding
    /// its op log (all of them were applied, in this order, so the result is the same).
    pub fn decode(b: &[u8]) -> Result<GroupState> {
        let st: GroupState = crate::proto::from_slice_capped(b)?;
        Ok(st.rebuilt())
    }

    /// `ext` recomputed from `ops` (a state decoded from bytes has an empty one).
    pub fn rebuilt(self) -> GroupState {
        if self.ops.is_empty() {
            return self;
        }
        match GroupState::fold(self.gid, self.ops.clone()) {
            Ok(mut f) => {
                // (only what the fold derives; everything else stays as it was saved)
                f.last_op_hlc = f.last_op_hlc.max(self.last_op_hlc);
                f
            }
            Err(_) => self,
        }
    }

    /// `p`'s permissions now (contract "Effective permissions").
    pub fn perms_of(&self, p: &PeerId) -> u32 {
        match self.role(p) {
            None => 0,
            Some(Role::Owner) => perm::ALL,
            Some(Role::Admin) => {
                // a plain group's admin with an `admin:<peer>` rights role: those rights
                let rid = format!("{}{}", community::ADMIN_RIGHTS_PREFIX, p.to_base32());
                if self.ext.roles_of(p).contains(&rid) && self.ext.role(&rid).is_some() {
                    self.member_perms(p)
                } else {
                    perm::ALL
                }
            }
            Some(Role::Member) => self.member_perms(p),
        }
    }

    fn member_perms(&self, p: &PeerId) -> u32 {
        self.roles_in_effect(p).filter_map(|r| self.ext.role(r)).fold(self.ext.everyone_perms(self.kind), |acc, r| acc | r.perms)
    }

    /// `p`'s custom roles that count: an `admin:<peer>` rights role only while `p` is an admin.
    pub fn roles_in_effect<'a>(&'a self, p: &PeerId) -> impl Iterator<Item = &'a String> + 'a {
        let admin = self.role(p) == Some(Role::Admin);
        self.ext.roles_of(p).iter().filter(move |r| admin || !r.starts_with(community::ADMIN_RIGHTS_PREFIX))
    }

    pub fn has(&self, p: &PeerId, bit: u32) -> bool {
        self.perms_of(p) & bit == bit
    }

    /// May `actor` kick / ban / time out `target`? Never itself or the owner; admins only
    /// by the owner.
    pub fn may_moderate(&self, actor: &PeerId, target: &PeerId) -> bool {
        target != actor && *target != self.owner && (self.role(target).unwrap_or(Role::Member) < Role::Admin || self.role(actor) == Some(Role::Owner))
    }

    /// Timed out until (epoch ms; 0 = not).
    pub fn timeout_until(&self, p: &PeerId) -> u64 {
        self.ext.timeouts.get(p).copied().unwrap_or(0)
    }

    /// The name channel `key` shows.
    pub fn channel_name<'a>(&'a self, key: &'a str) -> &'a str {
        self.ext.chan.get(key).and_then(|m| m.name.as_deref()).unwrap_or(key)
    }

    /// The channel (key) showing `name`, or keyed by it.
    pub fn channel_key(&self, name: &str) -> Option<&Channel> {
        self.channels.iter().find(|c| self.channel_name(&c.name) == name).or_else(|| self.channels.iter().find(|c| c.name == name))
    }

    pub fn chan_meta(&self, key: &str) -> ChanMeta {
        self.ext.chan.get(key).cloned().unwrap_or_default()
    }

    /// Channels in display order: uncategorised first, then each category in the order of
    /// its first channel; inside, by position (then creation order).
    pub fn channel_order(&self) -> Vec<&Channel> {
        let mut list: Vec<(usize, &Channel)> = self.channels.iter().enumerate().collect();
        list.sort_by_key(|(i, c)| (self.ext.chan.get(&c.name).and_then(|m| m.position).map(|p| p as usize).unwrap_or(*i), *i));
        let mut cats: Vec<(String, Vec<&Channel>)> = vec![(String::new(), vec![])];
        for (_, c) in list {
            let cat = self.ext.chan.get(&c.name).map(|m| m.category.clone()).unwrap_or_default();
            match cats.iter_mut().find(|(k, _)| *k == cat) {
                Some((_, v)) => v.push(c),
                None => cats.push((cat, vec![c])),
            }
        }
        cats.into_iter().flat_map(|(_, v)| v).collect()
    }

    fn set_positions(&mut self, order: &[String]) {
        for (i, k) in order.iter().enumerate() {
            self.ext.chan.entry(k.clone()).or_default().position = Some(i as u32);
        }
    }

    /// May `p` see channel `key`? Owner/admins always; others need `view_channel` and, for
    /// a private channel, a role it allows (`everyone` opens it).
    pub fn can_see(&self, p: &PeerId, key: &str) -> bool {
        match self.role(p) {
            None => return false,
            Some(r) if r >= Role::Admin => return true,
            _ => {}
        }
        if !self.has(p, perm::VIEW_CHANNEL) {
            return false;
        }
        let Some(m) = self.ext.chan.get(key) else { return true };
        !m.private || m.allow_roles.iter().any(|r| r == community::EVERYONE || self.roles_in_effect(p).any(|x| x == r))
    }

    /// Why `p` may not post in `channel` at `at_ms` (a file: `media`) — None: it may.
    /// The codes are the user errors the sender sees (`err.*`).
    pub fn post_refusal(&self, p: &PeerId, channel: &str, at_ms: u64, media: bool) -> Option<&'static str> {
        let Some(role) = self.role(p) else { return Some("err.not_member") };
        let perms = self.perms_of(p);
        if role < Role::Admin && self.timeout_until(p) > at_ms {
            return Some("err.timed_out");
        }
        if perms & perm::SEND_MESSAGES == 0 {
            return Some("err.channel_readonly");
        }
        if media && perms & perm::SEND_MEDIA == 0 {
            return Some("err.no_permission");
        }
        if !channel.is_empty() {
            if !self.can_see(p, channel) {
                return Some("err.no_permission");
            }
            if let Some(m) = self.ext.chan.get(channel).filter(|m| m.announce) {
                let allowed = role >= Role::Admin
                    || perms & perm::MANAGE_MESSAGES != 0
                    || m.allow_roles.iter().any(|r| r == community::EVERYONE || self.roles_in_effect(p).any(|x| x == r));
                if !allowed {
                    return Some("err.channel_readonly");
                }
            }
        }
        None
    }

    /// The state `p`'s content created at `hlc` is judged by: this one, unless an op made
    /// after `hlc` changed what `p` may do (then the fold of everything before it).
    pub fn state_for(&self, p: &PeerId, hlc: u64) -> StateAt<'_> {
        if !self.ops.iter().rev().take_while(|o| o.hlc > hlc).any(|o| Self::matters_for(o, p)) {
            return StateAt::Now(self);
        }
        StateAt::Then(self.prefix_state(self.ops.partition_point(|o| o.hlc <= hlc)))
    }

    /// Does op `o` change what `p` may do with content (see `state_for`)?
    fn matters_for(o: &Signed, p: &PeerId) -> bool {
        match &o.payload {
            Payload::Op(
                GroupOp::Add { peer }
                | GroupOp::AddBot { peer, .. }
                | GroupOp::Remove { peer }
                | GroupOp::Ban { peer }
                | GroupOp::SetRole { peer, .. }
                | GroupOp::MemberRoles { peer, .. }
                | GroupOp::Timeout { peer, .. },
            ) => peer == p,
            Payload::Op(GroupOp::Leave) => true, // (an owner's Leave moves the ownership)
            Payload::Op(
                GroupOp::RoleSet { .. } | GroupOp::RoleDelete { .. } | GroupOp::ChannelUpdate { .. } | GroupOp::Channel { .. } | GroupOp::TransferOwner { .. } | GroupOp::RulesV2,
            ) => true,
            _ => false,
        }
    }

    /// Is invite link `id` (made at `created_ms` if known, expiring at `expires_ms`) revoked?
    pub fn invite_revoked(&self, id: &[u8; 8], created_ms: Option<u64>, expires_ms: u64) -> bool {
        self.ext.is_revoked(id, created_ms, expires_ms)
    }

    /// Was `p` removed by an admin (and not added back since)?
    pub fn removed_by_admin(&self, p: &PeerId) -> bool {
        self.ext.removed.contains(p) && !self.is_member(p)
    }
}

/// A channel name as channels are named (lower case, dashes, ≤ 32 characters).
pub fn clean_channel_name(n: &str) -> String {
    n.trim().to_lowercase().replace(' ', "-").chars().take(32).collect()
}

/// 6-char tag for a public group handle, derived from the group id (unforgeable).
pub fn group_tag(gid: &Gid) -> String {
    data_encoding::BASE32_NOPAD.encode(&blake3::derive_key("lumora group tag v1", gid)[..5]).to_lowercase()[..6].to_string()
}

pub fn derive_gid(creator: &PeerId, create_op_id: &[u8; 16]) -> Gid {
    let mut h = blake3::Hasher::new_derive_key("lumora gid v1");
    h.update(&creator.0);
    h.update(create_op_id);
    h.finalize().as_bytes()[..16].try_into().unwrap()
}

/// Largest admin proof carried by a public directory listing (msgpack bytes).
pub const MAX_ADMIN_PROOF: usize = 24 * 1024;
const MAX_PROOF_OPS: usize = 2000;

fn proves_admin(gid: &Gid, admin: &PeerId, ops: &[Signed]) -> bool {
    ops.len() <= MAX_PROOF_OPS
        && ops.iter().all(|o| &o.gid == gid && o.verify())
        && GroupState::fold(*gid, ops.to_vec()).map(|st| st.role(admin).unwrap_or(Role::Member) >= Role::Admin).unwrap_or(false)
}

/// Proof for a public directory listing that `admin` administers the group: the smallest
/// set of the group's own signed ops (always starting with the creator's `Create`, which
/// the gid is derived from) that folds into a state where `admin` is admin or owner.
/// `None` if no proof fits [`MAX_ADMIN_PROOF`] (the listing is then shown unverified).
pub fn admin_proof(st: &GroupState, admin: &PeerId) -> Option<Vec<u8>> {
    let create = st.ops.first()?.clone();
    let mut candidates: Vec<Vec<Signed>> = vec![vec![create.clone()]];
    // role history: promotions, departures (owner succession), and how those people joined
    let promoted: Vec<PeerId> = st
        .ops
        .iter()
        .filter_map(|o| match &o.payload {
            Payload::Op(GroupOp::SetRole { peer, .. } | GroupOp::TransferOwner { peer }) => Some(*peer),
            _ => None,
        })
        .chain(std::iter::once(*admin))
        .collect();
    let roles: Vec<Signed> = st
        .ops
        .iter()
        .filter(|o| match &o.payload {
            Payload::Op(GroupOp::Create { .. } | GroupOp::SetRole { .. } | GroupOp::Leave | GroupOp::TransferOwner { .. }) => true,
            Payload::Op(GroupOp::Add { peer } | GroupOp::AddBot { peer, .. } | GroupOp::Remove { peer } | GroupOp::Ban { peer }) => promoted.contains(peer),
            _ => false,
        })
        .cloned()
        .collect();
    candidates.push(roles);
    candidates.push(st.ops.clone());
    for c in candidates {
        let Ok(b) = rmp_serde::to_vec(&c) else { continue };
        if b.len() <= MAX_ADMIN_PROOF && proves_admin(&st.gid, admin, &c) {
            return Some(b);
        }
    }
    None
}

/// Check a listing's admin proof: genuine ops of group `gid` (its `Create` hashes to the
/// gid, every op is signed by its author) that make `admin` an admin or the owner.
pub fn verify_admin_proof(gid: &Gid, admin: &PeerId, proof: &[u8]) -> bool {
    if proof.len() > MAX_ADMIN_PROOF {
        return false;
    }
    match crate::proto::from_slice_capped::<Vec<Signed>>(proof) {
        Ok(ops) => proves_admin(gid, admin, &ops),
        Err(_) => false,
    }
}

/// Create a new group that follows the Community 2.0 rules from the start: its Create and
/// the `RulesV2` op right after it (both to be stored and sent).
pub fn create_v2(me: &Signer, hlc: u64, name: &str, members: Vec<PeerId>, kind: u8) -> Result<(GroupState, Vec<Signed>)> {
    let (st, c) = create(me, hlc, name, members, kind)?;
    let r = Signed::new(me, st.gid, hlc.max(V2_RULES_HLC) + 1, Payload::Op(GroupOp::RulesV2));
    let mut held = vec![];
    let (st, ok) = st.with_op(r.clone(), &mut held)?;
    anyhow::ensure!(ok, "RulesV2 not applied");
    Ok((st, vec![c, r]))
}

/// Does `s` use an op kind 1.0.7 can't decode (it would drop the whole Welcome / envelope)?
pub fn op_is_v2_kind(s: &Signed) -> bool {
    match &s.payload {
        Payload::Op(op) => !matches!(
            op,
            GroupOp::Create { .. }
                | GroupOp::Add { .. }
                | GroupOp::Remove { .. }
                | GroupOp::SetRole { .. }
                | GroupOp::Rename { .. }
                | GroupOp::Leave
                | GroupOp::Rekey { .. }
                | GroupOp::Channel { .. }
                | GroupOp::Visibility { .. }
                | GroupOp::AddBot { .. }
                | GroupOp::SetBotPolicy { .. }
                | GroupOp::Ban { .. }
                | GroupOp::Unban { .. }
                | GroupOp::Settings { .. }
                | GroupOp::Meta { .. }
        ),
        _ => false,
    }
}

/// Create a new group; returns (state, create op). The creator is the account. (Old rules
/// until a `RulesV2`: see [`create_v2`].)
pub fn create(me: &Signer, hlc: u64, name: &str, members: Vec<PeerId>, kind: u8) -> Result<(GroupState, Signed)> {
    let payload = Payload::Op(GroupOp::Create { name: name.chars().take(64).collect(), members, kind });
    let id: [u8; 16] = crate::crypto::random_bytes();
    let author = me.account();
    let gid = derive_gid(&author, &id);
    let sig = me.sign(&Signed::bytes(&id, &gid, &author, hlc, &payload));
    let s = Signed { id, gid, author, hlc, payload, sig };
    let st = GroupState::fold(gid, vec![s.clone()])?;
    Ok((st, s))
}

/// Sealed to a new member: everything needed to join.
#[derive(Serialize, Deserialize)]
pub struct Welcome {
    pub gid: Gid,
    pub ops: Vec<Signed>,
    pub epoch: u64,
    /// all-zero for privacy-mode bots (they never get the group key)
    pub key: [u8; 32],
}

#[derive(Serialize, Deserialize)]
pub struct KeyUpdate {
    pub gid: Gid,
    pub epoch: u64,
    pub key: [u8; 32],
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::devices::{DeviceCert, Signer};
    use crate::identity::Identity;

    trait AsSigner {
        fn s(&self) -> Signer;
    }
    impl AsSigner for Identity {
        fn s(&self) -> Signer {
            Signer::primary(self)
        }
    }

    #[test]
    fn convergence_and_permissions() {
        let a = Identity::generate().s();
        let b = Identity::generate().s();
        let c = Identity::generate().s();
        let (st, create_op) = create(&a, 1, "Nhóm", vec![b.account()], 0).unwrap();
        let gid = st.gid;
        // b (member) tries to remove a (owner): rejected
        let bad = Signed::new(&b, gid, 5, Payload::Op(GroupOp::Remove { peer: a.account() }));
        let add_c = Signed::new(&a, gid, 3, Payload::Op(GroupOp::Add { peer: c.account() }));
        let promote_b = Signed::new(&a, gid, 4, Payload::Op(GroupOp::SetRole { peer: b.account(), role: Role::Admin }));
        let b_kicks_c = Signed::new(&b, gid, 6, Payload::Op(GroupOp::Remove { peer: c.account() }));
        let ops1 = vec![create_op.clone(), bad.clone(), add_c.clone(), promote_b.clone(), b_kicks_c.clone()];
        let mut ops2 = ops1.clone();
        ops2.reverse();
        let s1 = GroupState::fold(gid, ops1).unwrap();
        let s2 = GroupState::fold(gid, ops2).unwrap();
        assert_eq!(s1.members, s2.members);
        assert!(s1.is_member(&a.account()));
        assert_eq!(s1.role(&b.account()), Some(Role::Admin));
        assert!(!s1.is_member(&c.account()));
        // forged create with someone else's gid is rejected
        assert!(GroupState::fold(gid, vec![Signed::new(&c, gid, 1, create_op.payload.clone())]).is_err());
    }
    #[test]
    fn envelope_roundtrip() {
        let a = Identity::generate().s();
        let (st, op) = create(&a, 1, "x", vec![], 0).unwrap();
        let key = crate::crypto::random_bytes::<32>();
        let env = seal_envelope(&key, 0, &op).unwrap();
        assert_eq!(envelope_epoch(&env), Some(0));
        let back = open_envelope(&key, &st.gid, &env).unwrap();
        assert_eq!(back.id, op.id);
        let other = crate::crypto::random_bytes::<32>();
        assert!(open_envelope(&other, &st.gid, &env).is_err());
    }
    #[test]
    fn admin_proof_is_bound_to_the_gid() {
        let a = Identity::generate().s();
        let b = Identity::generate().s();
        let c = Identity::generate().s();
        let (st, create_op) = create(&a, 1, "Công khai", vec![b.account(), c.account()], 0).unwrap();
        let gid = st.gid;
        let mut ops = vec![create_op.clone()];
        for i in 0..40u64 {
            ops.push(Signed::new(&a, gid, 10 + i, Payload::Op(GroupOp::Rename { name: format!("tên {i}") })));
        }
        ops.push(Signed::new(&a, gid, 100, Payload::Op(GroupOp::SetRole { peer: b.account(), role: Role::Admin })));
        let st = GroupState::fold(gid, ops).unwrap();
        // the creator: the Create op alone
        let pa = admin_proof(&st, &a.account()).unwrap();
        assert_eq!(crate::proto::from_slice_capped::<Vec<Signed>>(&pa).unwrap().len(), 1);
        assert!(verify_admin_proof(&gid, &a.account(), &pa));
        // a promoted admin: Create + the promotion (renames left out)
        let pb = admin_proof(&st, &b.account()).unwrap();
        assert_eq!(crate::proto::from_slice_capped::<Vec<Signed>>(&pb).unwrap().len(), 2);
        assert!(verify_admin_proof(&gid, &b.account(), &pb));
        // a plain member has no proof, and nobody else can use someone's proof
        assert!(admin_proof(&st, &c.account()).is_none());
        assert!(!verify_admin_proof(&gid, &c.account(), &pb));
        // the same proof doesn't work for another gid, a self-made group, or tampered bytes
        let (other, other_create) = create(&c, 1, "Giả mạo", vec![], 0).unwrap();
        assert!(!verify_admin_proof(&other.gid, &b.account(), &pb));
        let fake = rmp_serde::to_vec(&vec![other_create]).unwrap();
        assert!(!verify_admin_proof(&gid, &c.account(), &fake));
        // c signs a promotion of itself: not the owner, so it proves nothing
        let self_promo = Signed::new(&c, gid, 50, Payload::Op(GroupOp::SetRole { peer: c.account(), role: Role::Admin }));
        assert!(!verify_admin_proof(&gid, &c.account(), &rmp_serde::to_vec(&vec![create_op.clone(), self_promo]).unwrap()));
        let mut bad = pb.clone();
        let n = bad.len();
        bad[n - 3] ^= 1;
        assert!(!verify_admin_proof(&gid, &b.account(), &bad));
        assert!(!verify_admin_proof(&gid, &b.account(), b"junk"));
    }

    #[test]
    fn owner_leave_succession() {
        let a = Identity::generate().s();
        let b = Identity::generate().s();
        let (st, op) = create(&a, 1, "x", vec![b.account()], 0).unwrap();
        let leave = Signed::new(&a, st.gid, 2, Payload::Op(GroupOp::Leave));
        let s = GroupState::fold(st.gid, vec![op, leave]).unwrap();
        assert_eq!(s.owner, b.account());
        assert_eq!(s.role(&b.account()), Some(Role::Owner));
    }

    /// Two devices of one account: ops and messages from the secondary (DevSig) fold like
    /// the account's own, the gid is bound to the account, and heads are per device.
    #[test]
    fn devsig_ops_fold_and_heads_are_per_device() {
        let root = Identity::generate();
        let dev = Identity::generate();
        let a0 = Signer::primary(&root);
        let a1 = Signer::secondary(&dev, DeviceCert::issue(&root, dev.peer_id(), 1, 0)).unwrap();
        let b = Identity::generate().s();
        // the secondary creates the group: creator = the account
        let (st, create_op) = create(&a1, 1, "Nhà", vec![b.account()], 0).unwrap();
        assert_eq!(st.owner, root.peer_id());
        assert_eq!(st.gid, derive_gid(&root.peer_id(), &create_op.id));
        assert!(create_op.verify());
        assert_eq!(create_op.signer_device(), dev.peer_id());
        // interleaved ops from both devices converge in any order
        let o1 = Signed::new(&a0, st.gid, 2, Payload::Op(GroupOp::Rename { name: "x".into() }));
        let o2 = Signed::new(&a1, st.gid, 3, Payload::Op(GroupOp::SetRole { peer: b.account(), role: Role::Admin }));
        let o3 = Signed::new(&a0, st.gid, 4, Payload::Op(GroupOp::Rename { name: "y".into() }));
        let ops = vec![create_op.clone(), o1.clone(), o2.clone(), o3.clone()];
        let mut rev = ops.clone();
        rev.reverse();
        let s1 = GroupState::fold(st.gid, ops).unwrap();
        let s2 = GroupState::fold(st.gid, rev).unwrap();
        assert_eq!((s1.name.clone(), s1.members.clone()), (s2.name.clone(), s2.members.clone()));
        assert_eq!(s1.name, "y");
        assert_eq!(s1.role(&b.account()), Some(Role::Admin));
        // heads keyed by signing device: no gap when both devices post with interleaved hlcs
        let heads: std::collections::BTreeMap<PeerId, u64> =
            [&o1, &o2, &o3].iter().fold(Default::default(), |mut m, o| {
                let e = m.entry(o.signer_device()).or_insert(0);
                *e = (*e).max(o.hlc);
                m
            });
        assert_eq!(heads.get(&root.peer_id()), Some(&4));
        assert_eq!(heads.get(&dev.peer_id()), Some(&3));
        // a device certificate of another account doesn't make its ops valid here
        let other = Identity::generate();
        let fake = Signer::secondary(&dev, DeviceCert::issue(&other, dev.peer_id(), 1, 0)).unwrap();
        let mut forged = Signed::new(&fake, st.gid, 5, Payload::Op(GroupOp::Rename { name: "z".into() }));
        forged.author = root.peer_id();
        assert!(!forged.verify());
        // envelopes from the secondary open for everyone holding the key
        let key = crate::crypto::random_bytes::<32>();
        let env = seal_envelope(&key, 0, &o2).unwrap();
        assert_eq!(open_envelope(&key, &st.gid, &env).unwrap().signer_device(), dev.peer_id());
    }

    /// Concurrent rotations: the lowest (hlc, author, …) wins for its epoch in any order,
    /// losers stay (their keys are valid), and only a rotation by the remover (or the
    /// owner when the remover can't) covers a removal.
    #[test]
    fn concurrent_rekeys_resolve_the_same_everywhere() {
        let o = Identity::generate().s();
        let a = Identity::generate().s();
        let b = Identity::generate().s();
        let x = Identity::generate().s();
        let (st, create_op) = create(&o, 1, "g", vec![a.account(), b.account(), x.account()], 0).unwrap();
        let gid = st.gid;
        let pa = Signed::new(&o, gid, 2, Payload::Op(GroupOp::SetRole { peer: a.account(), role: Role::Admin }));
        let pb = Signed::new(&o, gid, 3, Payload::Op(GroupOp::SetRole { peer: b.account(), role: Role::Admin }));
        let rm = Signed::new(&a, gid, 10, Payload::Op(GroupOp::Remove { peer: x.account() }));
        let rb = Signed::new(&b, gid, 11, Payload::Op(GroupOp::Rekey { epoch: 1, commit: [1; 32] })); // B didn't know
        let ra = Signed::new(&a, gid, 12, Payload::Op(GroupOp::Rekey { epoch: 1, commit: [2; 32] })); // A's, lost
        let base = vec![create_op.clone(), pa.clone(), pb.clone(), rm.clone(), rb.clone(), ra.clone()];
        let mut rev = base.clone();
        rev.reverse();
        let s1 = GroupState::fold(gid, base.clone()).unwrap();
        let s2 = GroupState::fold(gid, rev).unwrap();
        assert_eq!((s1.epoch, s1.key_commits.clone()), (s2.epoch, s2.key_commits.clone()));
        assert_eq!(s1.key_commits.get(&1), Some(&[1; 32]), "lowest hlc wins");
        assert_eq!(s1.rekey_commits(1), vec![[1; 32], [2; 32]], "the loser is kept");
        // B's winning key may have gone to X: A's removal is not covered yet
        assert_eq!(s1.rekey_due().map(|d| d.id), Some(rm.id));
        assert_eq!(s1.rotator_of(&rm), a.account());
        // A rotates again (epoch 2): covered
        let ra2 = Signed::new(&a, gid, 20, Payload::Op(GroupOp::Rekey { epoch: 2, commit: [3; 32] }));
        let s3 = s1.with_op(ra2.clone(), &mut vec![]).unwrap().0;
        assert_eq!(s3.epoch, 2);
        assert!(s3.rekey_due().is_none());
        // a third concurrent rotation for an old epoch is a bounded loser, never a new epoch
        let late = Signed::new(&o, gid, 21, Payload::Op(GroupOp::Rekey { epoch: 1, commit: [9; 32] }));
        let (s4, ok) = s3.with_op(late, &mut vec![]).unwrap();
        assert!(ok && s4.epoch == 2 && s4.key_commits.get(&1) == Some(&[1; 32]));
        // a departure is the owner's to cover
        let leave = Signed::new(&b, gid, 30, Payload::Op(GroupOp::Leave));
        let s5 = s4.with_op(leave.clone(), &mut vec![]).unwrap().0;
        assert_eq!(s5.rotator_of(s5.rekey_due().unwrap()), o.account());
        let by_a = Signed::new(&a, gid, 31, Payload::Op(GroupOp::Rekey { epoch: 3, commit: [4; 32] }));
        assert!(s5.with_op(by_a, &mut vec![]).unwrap().0.rekey_due().is_some(), "a concurrent admin rotation doesn't cover a departure");
        let by_o = Signed::new(&o, gid, 31, Payload::Op(GroupOp::Rekey { epoch: 3, commit: [5; 32] }));
        assert!(s5.with_op(by_o, &mut vec![]).unwrap().0.rekey_due().is_none());
        // a member turned into a privacy-mode bot must not keep reading
        let to_bot = Signed::new(&o, gid, 40, Payload::Op(GroupOp::AddBot { peer: a.account(), read_all: false }));
        let s6 = GroupState::fold(gid, vec![create_op, pa, to_bot.clone()]).unwrap();
        assert_eq!(s6.rekey_due().map(|d| d.id), Some(to_bot.id));
    }

    /// Incremental application gives exactly the full fold, in any arrival order.
    #[test]
    fn incremental_fold_matches_full_fold() {
        use rand::{seq::SliceRandom, Rng, SeedableRng};
        let mut rng = rand::rngs::StdRng::seed_from_u64(42);
        let ids: Vec<Signer> = (0..5).map(|_| Identity::generate().s()).collect();
        let (st, create_op) = create(&ids[0], 1, "g", ids[1..4].iter().map(|s| s.account()).collect(), 0).unwrap();
        let gid = st.gid;
        let mut ops = vec![];
        for i in 0..300u64 {
            let who = &ids[rng.gen_range(0..5)];
            let peer = ids[rng.gen_range(0..5)].account();
            let op = match rng.gen_range(0..8) {
                0 => GroupOp::Add { peer },
                1 => GroupOp::Remove { peer },
                2 => GroupOp::SetRole { peer, role: if rng.gen() { Role::Admin } else { Role::Member } },
                3 => GroupOp::Rename { name: format!("n{i}") },
                4 => GroupOp::Rekey { epoch: rng.gen_range(1..6), commit: [rng.gen(); 32] },
                5 => GroupOp::Ban { peer },
                6 => GroupOp::Meta { avatar: vec![1; 3], description: format!("{i}") },
                _ => GroupOp::Leave,
            };
            ops.push(Signed::new(who, gid, 2 + rng.gen_range(0..400), Payload::Op(op)));
        }
        let full = GroupState::fold(gid, std::iter::once(create_op.clone()).chain(ops.iter().cloned()).collect()).unwrap();
        for _ in 0..5 {
            ops.shuffle(&mut rng);
            let mut st = GroupState::fold(gid, vec![create_op.clone()]).unwrap();
            let mut held = vec![];
            let mut seen = vec![create_op.clone()];
            for o in &ops {
                st = st.with_op(o.clone(), &mut held).unwrap().0;
                seen.push(o.clone());
                // after every arrival: exactly the fold of everything received so far
                let f = GroupState::fold(gid, seen.clone()).unwrap();
                assert_eq!(f.ops.iter().map(|o| o.id).collect::<Vec<_>>(), st.ops.iter().map(|o| o.id).collect::<Vec<_>>());
            }
            let ids_a: Vec<_> = st.ops.iter().map(|o| o.id).collect();
            let ids_b: Vec<_> = full.ops.iter().map(|o| o.id).collect();
            assert_eq!(ids_a, ids_b);
            assert_eq!((st.members.clone(), st.epoch, st.key_commits.clone(), st.name.clone()), (full.members.clone(), full.epoch, full.key_commits.clone(), full.name.clone()));
        }
        // compacted ops fold to the same visible state
        let c = GroupState::fold(gid, full.compact_ops()).unwrap();
        assert_eq!((c.members, c.name, c.description, c.epoch), (full.members.clone(), full.name.clone(), full.description.clone(), full.epoch));
    }

    /// Fuzz regression (core/fuzz group_fold): an author signs two different ops with the
    /// same id and clock; members receiving them in different orders must still agree.
    #[test]
    fn same_id_ops_fold_the_same_in_any_order() {
        let a = Identity::generate().s();
        let b = Identity::generate().s();
        let (st, create) = create(&a, 1, "x", vec![b.account()], 0).unwrap();
        let mut r1 = Signed::new(&a, st.gid, 5, Payload::Op(GroupOp::Rename { name: "one".into() }));
        let r2_payload = Payload::Op(GroupOp::Rename { name: "two".into() });
        let r2 = Signed { id: r1.id, sig: a.sign(&Signed::bytes(&r1.id, &st.gid, &a.account(), 5, &r2_payload)), payload: r2_payload, ..r1.clone() };
        assert!(r1.verify() && r2.verify());
        let s1 = GroupState::fold(st.gid, vec![create.clone(), r1.clone(), r2.clone()]).unwrap();
        let s2 = GroupState::fold(st.gid, vec![create.clone(), r2.clone(), r1.clone()]).unwrap();
        assert_eq!(s1.name, s2.name);
        r1.sig.clear();
        assert!(!r1.verify());
    }

    /// Cover op: who may set it (communities: admins/owner; group chats: like the avatar),
    /// the size cap, removal, and the compacted Welcome keeps only the latest one.
    #[test]
    fn cover_permissions_and_size_cap() {
        let o = Identity::generate().s();
        let a = Identity::generate().s();
        let m = Identity::generate().s();
        let cover = |b: u8, n: usize| Payload::Op(GroupOp::Cover { cover: vec![b; n] });
        // community: plain members can't, admins and the owner can
        let (st, create_op) = create(&o, 1, "Cộng đồng", vec![a.account(), m.account()], 1).unwrap();
        let gid = st.gid;
        let promote = Signed::new(&o, gid, 2, Payload::Op(GroupOp::SetRole { peer: a.account(), role: Role::Admin }));
        let st = st.with_op(promote, &mut vec![]).unwrap().0;
        assert!(st.cover().is_empty() && st.cover_rev().is_empty());
        let (st, ok) = st.with_op(Signed::new(&m, gid, 3, cover(1, 1000)), &mut vec![]).unwrap();
        assert!(!ok, "a plain community member set the cover");
        let by_admin = Signed::new(&a, gid, 4, cover(2, 1000));
        let (st, ok) = st.with_op(by_admin.clone(), &mut vec![]).unwrap();
        assert!(ok && st.cover() == vec![2; 1000].as_slice());
        assert_eq!(st.cover_rev(), hex::encode(by_admin.id));
        // over the cap: rejected even for the owner; at the cap: fine
        let (st, ok) = st.with_op(Signed::new(&o, gid, 5, cover(3, MAX_COVER + 1)), &mut vec![]).unwrap();
        assert!(!ok && st.cover()[0] == 2);
        let (st, ok) = st.with_op(Signed::new(&o, gid, 6, cover(4, MAX_COVER)), &mut vec![]).unwrap();
        assert!(ok && st.cover().len() == MAX_COVER);
        // an avatar/description change leaves the cover alone
        let meta = Signed::new(&o, gid, 7, Payload::Op(GroupOp::Meta { avatar: vec![9; 10], description: "d".into() }));
        let st = st.with_op(meta, &mut vec![]).unwrap().0;
        assert_eq!(st.cover().len(), MAX_COVER);
        // removal
        let (st, ok) = st.with_op(Signed::new(&o, gid, 8, cover(0, 0)), &mut vec![]).unwrap();
        assert!(ok && st.cover().is_empty() && st.cover_rev().is_empty());
        // new members get only the latest cover op, and fold to the same picture
        let st = st.with_op(Signed::new(&a, gid, 9, cover(5, 2000)), &mut vec![]).unwrap().0;
        let compact = st.compact_ops();
        assert_eq!(compact.iter().filter(|o| matches!(o.payload, Payload::Op(GroupOp::Cover { .. }))).count(), 1);
        assert_eq!(GroupState::fold(gid, compact).unwrap().cover(), st.cover());
        // group chat: a plain member may, but not again within 10 minutes
        let (g, _) = create(&o, 1, "Nhóm", vec![m.account()], 0).unwrap();
        let t = 1_000u64 << 8;
        let (g, ok) = g.with_op(Signed::new(&m, g.gid, t, cover(6, 100)), &mut vec![]).unwrap();
        assert!(ok);
        let (g, ok) = g.with_op(Signed::new(&m, g.gid, t + (60_000 << 8), cover(7, 100)), &mut vec![]).unwrap();
        assert!(!ok && g.cover()[0] == 6, "a member changed the cover twice in a minute");
        let (g, ok) = g.with_op(Signed::new(&m, g.gid, t + ((11 * 60_000) << 8), cover(8, 100)), &mut vec![]).unwrap();
        assert!(ok && g.cover()[0] == 8);
        let (g, ok) = g.with_op(Signed::new(&m, g.gid, t + ((12 * 60_000) << 8), cover(9, MAX_COVER + 1)), &mut vec![]).unwrap();
        assert!(!ok && g.cover()[0] == 8);
        let _ = create_op;
    }

    /// Dissolve: only the owner (not an admin, not a member); afterwards nobody is a member
    /// and every op is rejected, in any arrival order.
    #[test]
    fn dissolve_is_owner_only_and_final() {
        let o = Identity::generate().s();
        let a = Identity::generate().s();
        let m = Identity::generate().s();
        let x = Identity::generate().s();
        let (st, create_op) = create(&o, 1, "Cộng đồng", vec![a.account(), m.account()], 1).unwrap();
        let gid = st.gid;
        let promote = Signed::new(&o, gid, 2, Payload::Op(GroupOp::SetRole { peer: a.account(), role: Role::Admin }));
        let st = st.with_op(promote.clone(), &mut vec![]).unwrap().0;
        for who in [&a, &m] {
            let (s2, ok) = st.with_op(Signed::new(who, gid, 3, Payload::Op(GroupOp::Dissolve)), &mut vec![]).unwrap();
            assert!(!ok && !s2.dissolved(), "a non-owner dissolved the group");
        }
        assert!(st.is_member(&m.account()));
        let dissolve = Signed::new(&o, gid, 10, Payload::Op(GroupOp::Dissolve));
        let (st, ok) = st.with_op(dissolve.clone(), &mut vec![]).unwrap();
        assert!(ok && st.dissolved());
        assert!(!st.is_member(&o.account()) && !st.is_member(&m.account()));
        assert!(st.was_member(&m.account()) && !st.was_member(&x.account()));
        // nothing after it: not the owner, not an admin, not a re-add, not a second dissolve
        let later = [
            Signed::new(&o, gid, 11, Payload::Op(GroupOp::Add { peer: x.account() })),
            Signed::new(&o, gid, 12, Payload::Op(GroupOp::Rename { name: "again".into() })),
            Signed::new(&a, gid, 13, Payload::Op(GroupOp::Cover { cover: vec![1; 10] })),
            Signed::new(&m, gid, 14, Payload::Op(GroupOp::Leave)),
            Signed::new(&o, gid, 15, Payload::Op(GroupOp::Dissolve)),
        ];
        let mut cur = st.clone();
        let mut held = vec![];
        for op in later.iter().cloned() {
            let (s2, ok) = cur.with_op(op, &mut held).unwrap();
            assert!(!ok, "an op was applied after the dissolve");
            assert!(s2.dissolved());
            cur = s2;
        }
        assert_eq!(cur.name, "Cộng đồng");
        // full folds in any order agree
        let mut all = vec![create_op, promote, dissolve];
        all.extend(later);
        let f1 = GroupState::fold(gid, all.clone()).unwrap();
        all.reverse();
        let f2 = GroupState::fold(gid, all).unwrap();
        assert!(f1.dissolved() && f2.dissolved());
        assert_eq!(f1.ops.len(), 3);
        assert_eq!(f1.ops.iter().map(|o| o.id).collect::<Vec<_>>(), f2.ops.iter().map(|o| o.id).collect::<Vec<_>>());
    }

    /// The owner's Leave and its Dissolve, signed concurrently (Leave first by hlc): every
    /// arrival order ends dissolved. Before, a member that got the Dissolve first dropped
    /// the late Leave (dissolved), while one that got the Leave first rejected the Dissolve
    /// (the ex-owner was no member any more) — they disagreed forever.
    #[test]
    fn owner_dissolve_is_final_despite_its_concurrent_leave() {
        let o = Identity::generate().s();
        let a = Identity::generate().s();
        let m = Identity::generate().s();
        let (st, create_op) = create(&o, 1 << 8, "Nhóm", vec![a.account(), m.account()], 0).unwrap();
        let gid = st.gid;
        let leave = Signed::new(&o, gid, 5 << 8, Payload::Op(GroupOp::Leave));
        let dissolve = Signed::new(&o, gid, 10 << 8, Payload::Op(GroupOp::Dissolve));
        let (d1, ok) = st.with_op(dissolve.clone(), &mut vec![]).unwrap();
        assert!(ok && d1.dissolved());
        let (d1, _) = d1.with_op(leave.clone(), &mut vec![]).unwrap();
        let (l2, ok) = st.with_op(leave.clone(), &mut vec![]).unwrap();
        assert!(ok && !l2.dissolved() && l2.owner != o.account());
        let (d2, ok) = l2.with_op(dissolve.clone(), &mut vec![]).unwrap();
        assert!(ok, "the owner's Dissolve was rejected because its own Leave came first");
        let f = GroupState::fold(gid, vec![dissolve.clone(), leave.clone(), create_op.clone()]).unwrap();
        for s in [&d1, &d2, &f] {
            assert!(s.dissolved());
            assert!(!s.is_member(&a.account()) && !s.is_member(&m.account()));
        }
        let ids = |s: &GroupState| s.ops.iter().map(|o| o.id).collect::<Vec<_>>();
        assert_eq!(ids(&d1), ids(&d2));
        assert_eq!(ids(&d1), ids(&f));

        // not a licence for later: an ex-owner's Dissolve long after its Leave is rejected
        // (in every order too), and so is the Dissolve of a member who left
        let late = Signed::new(&o, gid, (5 << 8) + ((2 * DISSOLVE_AFTER_LEAVE_MS) << 8), Payload::Op(GroupOp::Dissolve));
        let (x1, ok) = l2.with_op(late.clone(), &mut vec![]).unwrap();
        assert!(!ok && !x1.dissolved());
        let (x2, _) = st.with_op(late.clone(), &mut vec![]).unwrap();
        assert!(x2.dissolved());
        let mut held = vec![];
        let (x2, _) = x2.with_op(leave.clone(), &mut held).unwrap();
        assert!(!x2.dissolved(), "a re-fold must undo the Dissolve the earlier Leave invalidates");
        assert_eq!((ids(&x1), x1.owner), (ids(&x2), x2.owner));
        let m_leave = Signed::new(&m, gid, 6 << 8, Payload::Op(GroupOp::Leave));
        let m_dissolve = Signed::new(&m, gid, 7 << 8, Payload::Op(GroupOp::Dissolve));
        let g = GroupState::fold(gid, vec![create_op, m_leave, m_dissolve]).unwrap();
        assert!(!g.dissolved());
    }

    /// Ops no fold can ever accept are not held; held ops are bounded in bytes; the bytes
    /// of superseded pictures leave the op log without changing any fold.
    #[test]
    fn never_valid_ops_are_not_held_and_old_pictures_are_dropped() {
        let o = Identity::generate().s();
        let a = Identity::generate().s();
        let m = Identity::generate().s();
        let cover = |b: u8, n: usize| Payload::Op(GroupOp::Cover { cover: vec![b; n] });
        let min = |n: u64| (n * 60_000) << 8;
        // community: a plain member's picture / an oversized one is dropped, not held
        let (c, _) = create(&o, 1 << 8, "Cộng đồng", vec![a.account(), m.account()], 1).unwrap();
        let mut held = vec![];
        // (a plain member's picture is rejected by the fold, but never "never valid": its
        // author may have been an admin when it signed)
        for op in [
            Signed::new(&m, c.gid, 2 << 8, cover(1, 1000)),
            Signed::new(&m, c.gid, 3 << 8, Payload::Op(GroupOp::Meta { avatar: vec![1; 10], description: String::new() })),
        ] {
            assert!(!c.never_valid(&op));
            let mut h = vec![];
            assert!(!c.with_op(op, &mut h).unwrap().1);
        }
        for op in [
            Signed::new(&o, c.gid, 4 << 8, cover(1, MAX_COVER + 1)),
            Signed::new(&o, c.gid, 5 << 8, Payload::Op(GroupOp::Meta { avatar: vec![1; MAX_GROUP_AVATAR + 1], description: String::new() })),
            Signed::new(&o, c.gid, 6 << 8, Payload::Op(GroupOp::Create { name: "x".into(), members: vec![], kind: 0 })),
        ] {
            assert!(c.never_valid(&op));
            let (_, ok) = c.with_op(op, &mut held).unwrap();
            assert!(!ok);
        }
        assert!(held.is_empty(), "never-valid ops were held");
        // a rate-limited cover may still become valid (an earlier op could change things):
        // held, but the held list stays within its byte budget
        let (mut g, create_op) = create(&o, 1 << 8, "Nhóm", vec![m.account()], 0).unwrap();
        let gid = g.gid;
        let mut all = vec![create_op];
        let mut held = vec![];
        for i in 0..30u64 {
            // every 10 minutes: applied; plus one 5 minutes later: rate-limited → held
            for (t, ok_expected) in [(min(10 * i + 1), true), (min(10 * i + 6), false)] {
                let op = Signed::new(&m, gid, t, cover(i as u8, MAX_COVER));
                all.push(op.clone());
                let (g2, ok) = g.with_op(op, &mut held).unwrap();
                assert_eq!(ok, ok_expected);
                g = g2;
            }
        }
        assert!(!held.is_empty());
        assert!(held.iter().map(GroupState::held_weight).sum::<usize>() <= MAX_HELD_BYTES);
        // only the latest two covers keep their bytes; the fold is the same as a full fold
        let with_bytes = g.ops.iter().filter(|o| matches!(&o.payload, Payload::Op(GroupOp::Cover { cover }) if !cover.is_empty())).count();
        assert_eq!(with_bytes, KEEP_PICTURES);
        assert_eq!(g.cover(), vec![29u8; MAX_COVER].as_slice());
        let f = GroupState::fold(gid, all).unwrap();
        assert_eq!(g.ops.iter().map(|o| o.id).collect::<Vec<_>>(), f.ops.iter().map(|o| o.id).collect::<Vec<_>>());
        assert_eq!(f.cover(), g.cover());
        let state_bytes = rmp_serde::to_vec(&g).unwrap().len();
        assert!(state_bytes < 3 * MAX_COVER, "superseded covers still stored in the state ({state_bytes} B)");
        // what to blank in the envelope log: every cover but the latest two
        let ids = g.superseded_picture_ids(&held);
        assert_eq!(ids.len(), g.ops.iter().filter(|o| matches!(o.payload, Payload::Op(GroupOp::Cover { .. }))).count() - KEEP_PICTURES + held.len());
        assert!(!ids.contains(&g.cover_op().unwrap().0.id));
        // a new member gets the effective cover (which verifies), never a stripped one
        let compact = g.compact_ops();
        assert!(compact.iter().all(|o| o.verify()));
        assert_eq!(GroupState::fold(gid, compact).unwrap().cover(), g.cover());
        // a stripped op left as the newest picture (its successor invalidated later) is
        // not sent either
        let mut s = g.clone();
        s.ops.retain(|o| !matches!(&o.payload, Payload::Op(GroupOp::Cover { cover }) if !cover.is_empty()));
        assert!(s.compact_ops().iter().all(|o| o.verify()));
    }
}
