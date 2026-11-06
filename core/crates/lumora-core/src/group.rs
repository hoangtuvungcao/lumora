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
}

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
            let s: Signed = rmp_serde::from_slice(&plain)?;
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
    let s: Signed = rmp_serde::from_slice(&plain)?;
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
    pub fn is_member(&self, p: &PeerId) -> bool {
        self.members.contains_key(p)
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

    /// Apply one more signed op: incremental when it sorts after every op we have (the
    /// common case — no O(n) re-fold per message), a full fold otherwise. Returns the new
    /// state and whether the op was applied.
    ///
    /// `held`: verified ops the fold rejected so far (e.g. an admin's op that arrived before
    /// the promotion that makes it valid). They take part in every fold, so the result is
    /// the fold of everything received whatever the arrival order; on return it holds the
    /// ops that are still rejected (bounded, newest kept).
    pub fn with_op(&self, op: Signed, held: &mut Vec<Signed>) -> Result<(GroupState, bool)> {
        let key = |o: &Signed| (o.hlc, o.author.0, o.id, o.sig.clone());
        let id = op.id;
        let k = key(&op);
        let after_all = self.ops.last().map(|l| k > key(l)).unwrap_or(false) && held.iter().all(|h| key(h) < k);
        if after_all && !self.ops.iter().any(|o| o.id == id) {
            let mut st = self.clone();
            if st.apply(&op) {
                st.last_op_hlc = st.last_op_hlc.max(op.hlc);
                st.ops.push(op);
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

    fn bound_held(held: &mut Vec<Signed>) {
        if held.len() > MAX_HELD_OPS {
            held.sort_by_key(|h| std::cmp::Reverse(h.hlc));
            held.truncate(MAX_HELD_OPS);
            held.sort_by(|a, b| (a.hlc, a.author.0, a.id).cmp(&(b.hlc, b.author.0, b.id)));
        }
    }

    /// The ops a new member needs: superseded group settings (an older picture, name,
    /// slow-mode setting or visibility a later applied op replaced in full) are left out —
    /// dozens of 96 KB pictures would otherwise make the Welcome too large to deliver.
    pub fn compact_ops(&self) -> Vec<Signed> {
        let mut seen = [false; 4];
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
                    _ => return true,
                };
                !std::mem::replace(&mut seen[slot], true)
            })
            .cloned()
            .collect();
        out.reverse();
        out
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
        let owner_left = |o: &Signed| matches!(o.payload, Payload::Op(GroupOp::Leave)) && o.author != *p;
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
        let prefix: Vec<Signed> = self.ops.iter().take_while(|o| o.hlc <= hlc).cloned().collect();
        GroupState::fold(self.gid, prefix).ok().and_then(|st| st.role(p))
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

    /// Creation time of the latest op that took rights away from `p` (removed, banned,
    /// demoted, left). Ops `p` dates well before it are not accepted any more: an
    /// ex-admin can't backdate ops to when it still was one.
    pub fn rights_cut(&self, p: &PeerId) -> Option<u64> {
        self.ops.iter().rev().find_map(|o| match &o.payload {
            Payload::Op(GroupOp::Remove { peer } | GroupOp::Ban { peer }) if peer == p => Some(o.hlc),
            Payload::Op(GroupOp::SetRole { peer, role: Role::Member }) if peer == p => Some(o.hlc),
            Payload::Op(GroupOp::Leave) if o.author == *p => Some(o.hlc),
            _ => None,
        })
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
        Ok(st)
    }

    /// Validate + apply one op. Returns false if rejected (no permission / invalid).
    fn apply(&mut self, s: &Signed) -> bool {
        let Payload::Op(op) = &s.payload else { return false };
        let actor = match self.role(&s.author) {
            Some(r) => r,
            None => return false,
        };
        match op {
            GroupOp::Create { .. } => false,
            GroupOp::Add { peer } => {
                if actor < Role::Admin && self.kind == 1 {
                    return false; // communities: only admins add
                }
                if self.banned.contains(peer) && actor < Role::Admin {
                    return false; // only admins can bring back a banned member
                }
                self.left.retain(|p| p != peer);
                self.banned.retain(|p| p != peer);
                self.members.entry(*peer).or_insert(Role::Member);
                true
            }
            GroupOp::Remove { peer } => {
                let target = match self.role(peer) {
                    Some(r) => r,
                    None => return false,
                };
                if actor < Role::Admin || target >= actor {
                    return false;
                }
                self.members.remove(peer);
                self.bots.remove(peer);
                if !self.left.contains(peer) {
                    self.left.push(*peer);
                }
                true
            }
            GroupOp::SetRole { peer, role } => {
                if actor != Role::Owner || *role == Role::Owner || !self.is_member(peer) || *peer == self.owner {
                    return false;
                }
                self.members.insert(*peer, *role);
                true
            }
            GroupOp::Rename { name } => {
                if actor < Role::Admin && (self.kind == 1 || self.recent_op_by(&s.author, s.hlc, MEMBER_RENAME_GAP_MS, |o| matches!(o, GroupOp::Rename { .. }))) {
                    return false;
                }
                self.name = name.chars().take(64).collect();
                true
            }
            GroupOp::Leave => {
                self.members.remove(&s.author);
                if !self.left.contains(&s.author) {
                    self.left.push(s.author);
                }
                if s.author == self.owner {
                    // Succession: longest-standing admin, else longest member (BTreeMap order is stable).
                    let next = self
                        .members
                        .iter()
                        .find(|(_, r)| **r == Role::Admin)
                        .or_else(|| self.members.iter().next())
                        .map(|(p, _)| *p);
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
                if actor < Role::Admin {
                    return false;
                }
                self.public = *public;
                self.handle = handle.chars().take(24).collect();
                true
            }
            GroupOp::AddBot { peer, read_all } => {
                // only admins add bots (like Telegram); bots join as plain members (no admin rights)
                if actor < Role::Admin || self.banned.contains(peer) {
                    return false;
                }
                self.left.retain(|p| p != peer);
                self.members.entry(*peer).or_insert(Role::Member);
                self.bots.insert(*peer, *read_all);
                true
            }
            GroupOp::SetBotPolicy { peer, read_all } => {
                if actor < Role::Admin || !self.bots.contains_key(peer) {
                    return false;
                }
                self.bots.insert(*peer, *read_all);
                true
            }
            GroupOp::Ban { peer } => {
                let target = self.role(peer).unwrap_or(Role::Member);
                if actor < Role::Admin || (self.is_member(peer) && target >= actor) || *peer == self.owner {
                    return false;
                }
                self.members.remove(peer);
                if !self.left.contains(peer) {
                    self.left.push(*peer);
                }
                if !self.banned.contains(peer) {
                    self.banned.push(*peer);
                }
                true
            }
            GroupOp::Unban { peer } => {
                if actor < Role::Admin {
                    return false;
                }
                self.banned.retain(|p| p != peer);
                true
            }
            GroupOp::Settings { slow_mode_s, admins_only } => {
                if actor < Role::Admin {
                    return false;
                }
                self.slow_mode_s = (*slow_mode_s).min(3600);
                self.admins_only = *admins_only;
                true
            }
            GroupOp::Meta { avatar, description } => {
                // plain members of a group chat may change the picture too, but not over and
                // over: every change is part of the op log each new member receives
                if (actor < Role::Admin && (self.kind == 1 || self.recent_op_by(&s.author, s.hlc, MEMBER_META_GAP_MS, |o| matches!(o, GroupOp::Meta { .. }))))
                    || avatar.len() > 96 * 1024
                {
                    return false;
                }
                self.avatar = avatar.clone();
                self.description = description.chars().take(500).collect();
                true
            }
            GroupOp::Channel { name, voice, remove } => {
                if actor < Role::Admin {
                    return false;
                }
                self.channels.retain(|c| &c.name != name);
                if !remove {
                    self.channels.push(Channel { name: name.clone(), voice: *voice });
                }
                true
            }
        }
    }
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
            Payload::Op(GroupOp::SetRole { peer, .. }) => Some(*peer),
            _ => None,
        })
        .chain(std::iter::once(*admin))
        .collect();
    let roles: Vec<Signed> = st
        .ops
        .iter()
        .filter(|o| match &o.payload {
            Payload::Op(GroupOp::Create { .. } | GroupOp::SetRole { .. } | GroupOp::Leave) => true,
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
    match rmp_serde::from_slice::<Vec<Signed>>(proof) {
        Ok(ops) => proves_admin(gid, admin, &ops),
        Err(_) => false,
    }
}

/// Create a new group; returns (state, create op). The creator is the account.
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
        assert_eq!(rmp_serde::from_slice::<Vec<Signed>>(&pa).unwrap().len(), 1);
        assert!(verify_admin_proof(&gid, &a.account(), &pa));
        // a promoted admin: Create + the promotion (renames left out)
        let pb = admin_proof(&st, &b.account()).unwrap();
        assert_eq!(rmp_serde::from_slice::<Vec<Signed>>(&pb).unwrap().len(), 2);
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
}
