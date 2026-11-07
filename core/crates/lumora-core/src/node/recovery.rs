//! Recovery from friends after a restore with the recovery phrase.
//!
//! An account restored on a fresh device from its 24 words has its identity back but none
//! of its friends, chats or groups. Its friends still have all of that, so they help:
//!
//! 1. **Hello** (`Ext RECOVER_HELLO`, restored → a peer that proved the friendship while
//!    the account is recovering): a friend's device sends its `Ext DHT_KEY` with a message
//!    the restored account itself signed in their 1-1 chat (`DhtKeyMsg.proof`); only such
//!    a peer gets `{to, ts, sig}` signed by the account key over
//!    `hello_bytes(account, to, ts)` — the restored device proves it is the same account,
//!    for this one peer, now (no replay elsewhere / later). Anyone else (anyone can send
//!    `DHT_KEY`) gets nothing and never learns the account is recovering. Friends only
//!    serve a plain account-key signature from the primary device (`ask_sig_ok`).
//! 2. **Offer** (`Ext RECOVER_OFFER`, friend → restored): only from a device whose account
//!    holds the restored account as a FRIEND in its own store (strangers, pending requests
//!    and blocked people get nothing) and whose user leaves "Giúp bạn bè khôi phục lịch sử"
//!    on (`privacy.help_restore`, default on, synced across the friend's devices). It says
//!    how much it can give back: messages of the last 6 months of OUR 1-1 conversation and
//!    the groups we are both still in, plus — when it has one — a message the restored
//!    account itself signed in that conversation (a verifiable proof of the friendship).
//! 3. **Review**: the restored user sees the offers (`recovery_offers`) and accepts or
//!    declines each. Nothing is stored before that, and only offers from peers that were
//!    sent a hello are kept at all. An offer without proof is kept as "unverified" (own
//!    small pool) and accepting it never makes the peer a friend or opens group welcomes.
//! 4. **Accept** (`Ext RECOVER_ACCEPT`, signed like the hello): the friend sends the
//!    history in ≤ 256 KB `RECOVER_BATCH` frames (at most 5,000 messages / 8 MB, once in a
//!    while per friend) and a group welcome for every shared group; the group's own
//!    anti-entropy then fetches its history (existing group sync).
//!
//! What a friend gives back is only ITS conversation with the restored account. Deleted,
//! cleared and disappearing messages are never served (deleted rows are tombstones with a
//! blanked body; their signed wire copies are dropped by a trigger the moment they are
//! deleted or edited, see store.rs `msg_wire`). Messages the friend wrote are taken on the
//! authenticated (TLS-pinned, end-to-end) connection; messages the restored account wrote
//! are verified against its own signature when the friend kept the signed copy.

use super::*;
use crate::proto::{ext, Body, ChatMsg};
use serde_bytes::ByteBuf;

/// The window of 1-1 history a friend hands back.
pub(crate) const RECOVER_WINDOW_MS: u64 = 183 * 86_400_000;
/// A restored account asks for help this long after the restore.
const RECOVERING_FOR_MS: u64 = 30 * 86_400_000;
const MAX_MESSAGES: usize = 5_000;
const MAX_TOTAL_BYTES: usize = 8 * 1024 * 1024;
const BATCH_BYTES: usize = 256 * 1024;
const BATCH_ITEMS: usize = 200;
const MAX_BODY: usize = 16 * 1024;
/// How far a hello's / accept's signed time may be from ours.
const SKEW_MS: u64 = 10 * 60_000;
/// A friend serves the same account at most this often (an interrupted transfer can be
/// asked for again: up to 3 times in this window).
const SERVE_WINDOW_MS: u64 = 86_400_000;
const SERVES_PER_WINDOW: usize = 3;
/// The restored side says hello to the same account at most this often.
const HELLO_EVERY_MS: u64 = 30 * 60_000;
/// Kinds that make sense without the original files (photos, files and voice messages
/// are not re-sent: their bytes are not part of the history transfer).
const KINDS: &[&str] = &["text", "location", "contact", "call", "poll", "checklist"];

pub(crate) const HELP_KEY: &str = "privacy.help_restore";
const SINCE_KEY: &str = "recover.since";
const OFFERS_KEY: &str = "recover.offers";
/// Set when my own linked device restored the history (friends are not asked).
const OWN_KEY: &str = "recover.own";
/// `join.pending` was set for this group by a recovery (its welcome is a "group restored").
pub(crate) const GROUP_KEY_PREFIX: &str = "recover.group.";
/// Meta of a handed-back message not signed by me: who gave it back.
pub(crate) const META_FROM: &str = "restored_from";
pub(crate) const META_PEER: &str = "restored_peer";
/// Meta of a handed-back message that claims to be mine but carries no valid signature of
/// mine (or came with an unverified offer): the bubble says so ("not verified").
pub(crate) const META_UNVERIFIED: &str = "restored_unverified";
/// Largest friendship proof (a signed `ChatMsg`) carried in `Ext DHT_KEY`.
pub(crate) const PROOF_MAX: usize = 4096;
/// Offers kept at once: verified (the friend proved our friendship) / unverified (a
/// separate small pool — they can never push verified offers out).
const MAX_OFFERS: usize = 500;
const MAX_UNVERIFIED_OFFERS: usize = 20;
/// A peer that handed back a message this account signed in our 1-1 chat.
const PROVEN_PREFIX: &str = "recover.proven.";

fn hello_bytes(tag: &[u8], account: &PeerId, to: &PeerId, ts: u64) -> Vec<u8> {
    let mut v = tag.to_vec();
    v.extend_from_slice(&account.0);
    v.extend_from_slice(&to.0);
    v.extend_from_slice(&ts.to_le_bytes());
    v
}
const HELLO_TAG: &[u8] = b"lumora-recover-hello-v1";
const ACCEPT_TAG: &[u8] = b"lumora-recover-accept-v1";

/// `RECOVER_HELLO` / `RECOVER_ACCEPT`.
#[derive(Serialize, Deserialize, Default)]
pub(crate) struct SignedAsk {
    #[serde(with = "serde_bytes", default)]
    pub to: Vec<u8>,
    #[serde(default)]
    pub ts: u64,
    #[serde(with = "serde_bytes", default)]
    pub sig: Vec<u8>,
}

#[derive(Serialize, Deserialize, Default)]
pub(crate) struct Offer {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub messages: u32,
    #[serde(default)]
    pub groups: Vec<ByteBuf>,
    /// oldest message offered (ms), 0 = none
    #[serde(default)]
    pub since: u64,
    /// a `ChatMsg` the restored account signed in our conversation (MessagePack)
    #[serde(with = "serde_bytes", default)]
    pub proof: Vec<u8>,
}

#[derive(Serialize, Deserialize, Default, Clone)]
pub(crate) struct Item {
    #[serde(with = "serde_bytes", default)]
    pub id: Vec<u8>,
    #[serde(with = "serde_bytes", default)]
    pub author: Vec<u8>,
    #[serde(default)]
    pub hlc: u64,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub reply_to: Option<ByteBuf>,
    /// the author's signed `ChatMsg` (MessagePack), when the friend kept it
    #[serde(with = "serde_bytes", default)]
    pub wire: Vec<u8>,
}

#[derive(Serialize, Deserialize, Default)]
pub(crate) struct Batch {
    #[serde(default)]
    pub items: Vec<Item>,
    #[serde(default)]
    pub done: bool,
}

/// One friend's offer as the restored device keeps it (kv `recover.offers`).
#[derive(Serialize, Deserialize, Clone, Default, Debug, PartialEq)]
pub(crate) struct OfferState {
    pub peer: String,
    pub name: String,
    pub messages: u32,
    pub groups: Vec<String>,
    pub since: u64,
    pub verified: bool,
    /// "offered" | "accepted" | "done" | "declined"
    pub state: String,
    #[serde(default)]
    pub received: u32,
    pub at: u64,
}

/// A handed-back message that passed the checks: (id, author, hlc, kind, body, reply_to,
/// signed by me — verified against my own signature).
type Checked = (Vec<u8>, PeerId, u64, String, Value, Option<Vec<u8>>, bool);

/// Is a received message of this kind kept as a signed copy for recovery?
pub(crate) fn keeps_wire(b: &Body) -> bool {
    KINDS.contains(&b.kind())
}

/// Chat-list line for a handed-back message (text, poll question, checklist title…).
fn preview(body: &Value) -> String {
    ["text", "question", "title", "name"].iter().find_map(|k| body.get(*k).and_then(|t| t.as_str())).unwrap_or_default().chars().take(120).collect()
}

impl Node {
    // ------------------------------------------------------------ settings / state

    /// "Giúp bạn bè khôi phục lịch sử" (default on, synced across my devices).
    pub fn help_restore_enabled(&self) -> bool {
        self.store.kv_get(HELP_KEY).map(|v| v != b"0").unwrap_or(true)
    }

    /// Called at start-up when the account was just restored from its phrase into an
    /// empty data folder: ask friends for help for a while.
    pub(crate) fn mark_restored(&self) {
        let _ = self.store.kv_set(SINCE_KEY, now_ms().to_string().as_bytes());
    }

    /// Restored from the phrase recently, still asking friends for help?
    pub fn recovering(&self) -> bool {
        if !self.is_primary() {
            return false;
        }
        let since = self.store.kv_get(SINCE_KEY).and_then(|v| String::from_utf8(v).ok()).and_then(|s| s.parse::<u64>().ok());
        since.is_some_and(|t| t > 0 && now_ms().saturating_sub(t) < RECOVERING_FOR_MS)
    }

    fn offers(&self) -> Vec<OfferState> {
        self.store.kv_get_json::<Vec<OfferState>>(OFFERS_KEY).unwrap_or_default()
    }

    fn save_offers(&self, v: &[OfferState]) {
        let _ = self.store.kv_set(OFFERS_KEY, serde_json::to_string(v).unwrap_or_default().as_bytes());
    }

    fn update_offer(&self, peer: &PeerId, f: impl FnOnce(&mut OfferState)) -> Option<OfferState> {
        let mut all = self.offers();
        let k = peer.to_base32();
        let o = all.iter_mut().find(|o| o.peer == k)?;
        f(o);
        let out = o.clone();
        self.save_offers(&all);
        self.emit("recovery", json!({"offers": all}));
        Some(out)
    }

    /// The review list: who offered what (`recovery_offers`).
    pub fn recovery_offers(&self) -> Value {
        json!({"recovering": self.recovering(), "offers": self.offers()})
    }

    /// Stop asking friends (the user closed the review list for good).
    pub fn recovery_dismiss(&self) -> Result<()> {
        self.store.kv_set(SINCE_KEY, b"0")?;
        self.emit("recovery", json!({"offers": self.offers(), "recovering": false}));
        Ok(())
    }

    pub fn recovery_decline(&self, peer: &PeerId) -> Result<()> {
        self.update_offer(peer, |o| o.state = "declined".into()).ok_or_else(|| anyhow!("no such offer"))?;
        Ok(())
    }

    /// The user accepts a friend's offer: the friend is a friend again, the shared groups
    /// may welcome us back, and the friend is asked for the history.
    ///
    /// An UNVERIFIED offer (the peer never proved our friendship) only brings the labelled,
    /// unverified 1-1 history: it never makes the peer a friend and never lets a group
    /// welcome us without asking ("who can add me") — re-adding is the normal friend flow.
    pub fn recovery_accept(&self, peer: &PeerId) -> Result<()> {
        let o = self.offers().into_iter().find(|o| o.peer == peer.to_base32()).ok_or_else(|| anyhow!("no such offer"))?;
        anyhow::ensure!(!self.store.is_blocked(peer), "blocked");
        let name: String = o.name.chars().take(48).collect();
        if o.verified {
            let cur = self.store.contact(peer).map(|c| c.status).unwrap_or(0);
            if cur != 3 {
                self.store.upsert_contact(peer, Some(&name), Some(3))?;
                self.push_profile_to(*peer);
                self.on_became_friends(peer);
            }
            for g in &o.groups {
                let _ = self.store.kv_set(&format!("join.pending.{g}"), b"1");
                let _ = self.store.kv_set(&format!("{GROUP_KEY_PREFIX}{g}"), b"1");
            }
        }
        self.store.ensure_conv(&direct_conv(peer), 0, &name)?;
        self.emit_contact(peer);
        self.emit_conv(&direct_conv(peer));
        self.update_offer(peer, |o| o.state = "accepted".into());
        self.send_recover_accept(peer, None);
        Ok(())
    }

    /// To ONE device of the friend (each device that gets it serves the whole history):
    /// `via`, else the device that made the offer, else any connected one.
    fn send_recover_accept(&self, peer: &PeerId, via: Option<PeerId>) {
        let ts = now_ms();
        let m = SignedAsk { to: peer.0.to_vec(), ts, sig: self.signer.sign(&hello_bytes(ACCEPT_TAG, &self.me, peer, ts)) };
        let offered = self.store.kv_get(&format!("{OFFER_DEV_PREFIX}{}", peer.to_base32())).and_then(|v| PeerId::from_str_any(std::str::from_utf8(&v).ok()?).ok());
        let live: Vec<PeerId> = self.peers_of(peer).iter().filter(|c| c.proto.load(std::sync::atomic::Ordering::Relaxed) >= proto::PROTO_V3).map(|c| c.peer).collect();
        if let Some(d) = accept_target(via, offered, &live) {
            self.send_now_dev(&d, proto::ext(ext::RECOVER_ACCEPT, &m));
        }
    }

    // ------------------------------------------------------------ restored side

    /// My own linked device brought the account's history back (sync from a sibling):
    /// friends are not asked any more (offers already accepted still finish).
    pub(super) fn recovery_own_history(&self) {
        if !self.recovering() {
            return;
        }
        tracing::info!("history restored from my own device: not asking friends");
        let _ = self.store.kv_set(SINCE_KEY, b"0");
        let _ = self.store.kv_set(OWN_KEY, b"1");
        self.emit("recovery", json!({"offers": self.offers(), "recovering": false, "own_device": true}));
    }

    /// A device of someone else proved it holds this account as a FRIEND (it gave us the
    /// key to its friends-only record, `Ext DHT_KEY`, which a device only sends to accounts
    /// that are friends in its own store): while recovering, ask its account for help.
    /// Nobody else is sent a hello — strangers, pending requests and group co-members never
    /// learn that this account is recovering (docs/src/dev/multi-device.md).
    pub(super) fn recovery_on_hello(&self, pc: &Arc<PeerConn>) {
        if pc.own || pc.account == self.me || !self.recovering() || self.store.is_blocked(&pc.account) || !self.recovery_proven(&pc.account) {
            return;
        }
        let k = format!("recover.asked.{}", pc.account.to_base32());
        let last = self.store.kv_get(&k).and_then(|v| String::from_utf8(v).ok()).and_then(|s| s.parse::<u64>().ok()).unwrap_or(0);
        let state = self.offers().into_iter().find(|o| o.peer == pc.account.to_base32()).map(|o| o.state);
        // accepted but cut off before the end: ask again (the friend allows a few repeats)
        if state.as_deref() == Some("accepted") {
            self.send_recover_accept(&pc.account, Some(pc.peer));
            return;
        }
        if state.is_some() || now_ms().saturating_sub(last) < HELLO_EVERY_MS {
            return;
        }
        let _ = self.store.kv_set(&k, now_ms().to_string().as_bytes());
        let ts = now_ms();
        let m = SignedAsk { to: pc.account.0.to_vec(), ts, sig: self.signer.sign(&hello_bytes(HELLO_TAG, &self.me, &pc.account, ts)) };
        tracing::info!("recovery: hello to {}", pc.account.to_base32());
        let _ = pc.ctl.try_send(proto::ext(ext::RECOVER_HELLO, &m));
    }

    /// Is `proof` a message THIS account signed in its 1-1 chat with `peer` (MessagePack
    /// `ChatMsg`)? Only someone we wrote to ourselves can hold one.
    pub(crate) fn recovery_proof_ok(&self, peer: &PeerId, proof: &[u8]) -> bool {
        !proof.is_empty()
            && proof.len() <= PROOF_MAX
            && *peer != self.me
            && crate::proto::from_slice_capped::<ChatMsg>(proof)
                .map(|c| c.author == self.me && self.verify_content(&self.me, &c.signing_bytes(&super::chat::dm_scope(&self.me, peer)), &c.sig))
                .unwrap_or(false)
    }

    pub(crate) fn recovery_note_proven(&self, peer: &PeerId) {
        let _ = self.store.kv_set(&format!("{PROVEN_PREFIX}{}", peer.to_base32()), b"1");
    }

    fn recovery_proven(&self, peer: &PeerId) -> bool {
        self.store.kv_get(&format!("{PROVEN_PREFIX}{}", peer.to_base32())).is_some()
    }

    fn on_recover_offer(&self, pc: &Arc<PeerConn>, body: &[u8]) -> Result<()> {
        // only answers to our own hello, while recovering
        if pc.own || !self.recovering() || self.store.kv_get(&format!("recover.asked.{}", pc.account.to_base32())).is_none() || self.store.is_blocked(&pc.account) {
            return Ok(());
        }
        let m: Offer = proto::ext_body(body)?;
        // the accept goes back to this device only (first offer wins)
        let dk = format!("{OFFER_DEV_PREFIX}{}", pc.account.to_base32());
        if self.store.kv_get(&dk).is_none() {
            let _ = self.store.kv_set(&dk, pc.peer.to_base32().as_bytes());
        }
        let fallback = pc.name.read().clone();
        self.store_offer(&pc.account, &fallback, &m);
        Ok(())
    }

    /// Keep `peer`'s offer for review (verified or not, each in its own pool).
    fn store_offer(&self, peer: &PeerId, fallback_name: &str, m: &Offer) {
        let verified = self.recovery_proven(peer) || self.recovery_proof_ok(peer, &m.proof);
        let mut all = self.offers();
        let k = peer.to_base32();
        if all.iter().any(|o| o.peer == k) {
            return;
        }
        // separate pools: unverified offers can never fill the list for the real friends
        let pool = all.iter().filter(|o| o.verified == verified).count();
        if pool >= if verified { MAX_OFFERS } else { MAX_UNVERIFIED_OFFERS } {
            return;
        }
        let name: String = m.name.chars().take(48).collect();
        let name = if name.trim().is_empty() { fallback_name.chars().take(48).collect() } else { name };
        all.push(OfferState {
            peer: k,
            name,
            messages: m.messages.min(MAX_MESSAGES as u32),
            groups: m.groups.iter().filter(|g| g.len() == 16).take(200).map(hex::encode).collect(),
            since: m.since,
            verified,
            state: "offered".into(),
            received: 0,
            at: now_ms(),
        });
        self.save_offers(&all);
        self.emit("recovery", json!({"offers": all}));
    }

    /// Check one handed-back message; `None` = drop it.
    fn recover_item(&self, friend: &PeerId, it: &Item) -> Option<Checked> {
        let id: [u8; 16] = it.id.as_slice().try_into().ok()?;
        let author = PeerId(it.author.as_slice().try_into().ok()?);
        let now = now_ms();
        let ms = crate::util::hlc_to_ms(it.hlc);
        if ms + RECOVER_WINDOW_MS + 7 * 86_400_000 < now || ms > now + 86_400_000 {
            return None;
        }
        let reply = it.reply_to.as_ref().and_then(|r| <[u8; 16]>::try_from(r.as_slice()).ok()).map(|r| r.to_vec());
        if !it.wire.is_empty() {
            // a signed copy: must be the author's own, unchanged, not disappearing
            let c: ChatMsg = crate::proto::from_slice_capped(&it.wire).ok()?;
            if c.id != id || c.author != author || c.hlc != it.hlc || c.ttl_ms.is_some() || !super::chat::chat_msg_size_ok(&c) {
                return None;
            }
            if !self.verify_content(&author, &c.signing_bytes(&super::chat::dm_scope(&self.me, friend)), &c.sig) {
                return None;
            }
            let kind = c.body.kind();
            if !KINDS.contains(&kind) {
                return None;
            }
            return Some((id.to_vec(), author, c.hlc, kind.to_string(), c.body.to_json(), c.reply_to.map(|r| r.to_vec()), author == self.me));
        }
        // unsigned row: only the two of us, a known kind, a small JSON object
        if (author != *friend && author != self.me) || !KINDS.contains(&it.kind.as_str()) || it.body.len() > MAX_BODY {
            return None;
        }
        let body: Value = serde_json::from_str(&it.body).ok().filter(|v: &Value| v.is_object())?;
        Some((id.to_vec(), author, it.hlc, it.kind.clone(), body, reply, false))
    }

    fn on_recover_batch(&self, pc: &Arc<PeerConn>, body: &[u8]) -> Result<()> {
        if pc.own {
            return Ok(());
        }
        let b: Batch = proto::ext_body(body)?;
        self.apply_recover_batch(&pc.account, &b);
        Ok(())
    }

    /// Store a batch of `friend`'s hand-back (only for an offer the user accepted).
    fn apply_recover_batch(&self, friend: &PeerId, b: &Batch) {
        let friend = *friend;
        let Some(o) = self.offers().into_iter().find(|o| o.peer == friend.to_base32()) else { return };
        if o.state != "accepted" {
            return;
        }
        let conv = direct_conv(&friend);
        let room = (MAX_MESSAGES as u32).saturating_sub(o.received) as usize;
        let mut n = 0u32;
        let mut newest: Option<(u64, String)> = None;
        for it in b.items.iter().take(room.min(BATCH_ITEMS)) {
            let Some((id, author, hlc, kind, body, reply, mine_signed)) = self.recover_item(&friend, it) else { continue };
            if self.store.insert_message(&id, &conv, &author, hlc, &kind, &body, 2, reply.as_deref(), None).unwrap_or(false) {
                n += 1;
                // not signed by me: the bubble says where it came from ("Restored from …");
                // "mine" without my signature (or anything from an unverified offer) is
                // also flagged unverified — never shown as a normal message of mine
                if !mine_signed {
                    let mut meta = json!({META_FROM: o.name, META_PEER: friend.to_base32()});
                    if author == self.me || !o.verified {
                        meta[META_UNVERIFIED] = json!(true);
                    }
                    let _ = self.store.set_message_meta(&id, &meta);
                }
                let pv = preview(&body);
                if newest.as_ref().map(|(h, _)| hlc > *h).unwrap_or(true) {
                    newest = Some((hlc, pv));
                }
            }
        }
        if let Some((hlc, pv)) = newest {
            let _ = self.store.conv_touch(&conv, crate::util::hlc_to_ms(hlc) as i64, &pv, false);
        }
        self.update_offer(&friend, |o| {
            o.received = o.received.saturating_add(n);
            if b.done {
                o.state = "done".into();
            }
        });
        if n > 0 || b.done {
            self.emit_conv(&conv);
        }
    }

    // ------------------------------------------------------------ friend's side

    fn ask_ok(&self, pc: &Arc<PeerConn>, tag: &[u8], m: &SignedAsk) -> bool {
        let fresh = now_ms().abs_diff(m.ts) <= SKEW_MS;
        fresh
            && !pc.own
            && m.to.as_slice() == self.me.0.as_slice()
            // the stored friendship decides — nothing is given to strangers / pending / blocked
            && self.store.is_friend(&pc.account)
            && !self.store.is_blocked(&pc.account)
            && self.help_restore_enabled()
            && ask_sig_ok(&pc.peer, &pc.account, tag, &self.me, m)
            && !self.is_revoked(&pc.account, &pc.peer)
    }

    fn shared_groups(&self, account: &PeerId) -> Vec<Gid> {
        self.groups.read().values().filter(|g| g.is_member(&self.me) && g.is_member(account)).map(|g| g.gid).take(200).collect()
    }

    fn on_recover_hello(&self, pc: &Arc<PeerConn>, body: &[u8]) -> Result<()> {
        let m: SignedAsk = proto::ext_body(body)?;
        if !self.ask_ok(pc, HELLO_TAG, &m) {
            return Ok(());
        }
        let k = format!("recover.offered.{}", pc.account.to_base32());
        let last = self.store.kv_get(&k).and_then(|v| String::from_utf8(v).ok()).and_then(|s| s.parse::<u64>().ok()).unwrap_or(0);
        if now_ms().saturating_sub(last) < 60_000 {
            return Ok(());
        }
        let _ = self.store.kv_set(&k, now_ms().to_string().as_bytes());
        let rows = self.recovery_rows(&pc.account);
        let proof = rows.iter().find(|r| r.author == pc.account.0 && r.wire.is_some()).and_then(|r| r.wire.clone()).unwrap_or_default();
        let offer = Offer {
            name: self.name(),
            messages: rows.len() as u32,
            groups: self.shared_groups(&pc.account).into_iter().map(|g| ByteBuf::from(g.to_vec())).collect(),
            since: rows.last().map(|r| crate::util::hlc_to_ms(r.hlc as u64)).unwrap_or(0),
            proof,
        };
        if offer.messages == 0 && offer.groups.is_empty() {
            return Ok(());
        }
        let _ = pc.ctl.try_send(proto::ext(ext::RECOVER_OFFER, &offer));
        Ok(())
    }

    /// What I can give back to `friend`: our 1-1 conversation of the last 6 months, newest
    /// first, live messages of the kinds that make sense without files.
    fn recovery_rows(&self, friend: &PeerId) -> Vec<crate::store::RecoveryRow> {
        let since = (now_ms().saturating_sub(RECOVER_WINDOW_MS) << 8) as i64;
        let mut rows = self.store.recovery_rows(&direct_conv(friend), since, i64::MAX, MAX_MESSAGES * 2);
        rows.retain(|r| KINDS.contains(&r.kind.as_str()) && (r.author == friend.0 || r.author == self.me.0) && r.body.len() <= MAX_BODY);
        rows.truncate(MAX_MESSAGES);
        rows
    }

    fn on_recover_accept(self: &Arc<Self>, pc: &Arc<PeerConn>, body: &[u8]) -> Result<()> {
        let m: SignedAsk = proto::ext_body(body)?;
        if !self.ask_ok(pc, ACCEPT_TAG, &m) {
            return Ok(());
        }
        // rate limit: a few transfers a day per friend
        let k = format!("recover.served.{}", pc.account.to_base32());
        let now = now_ms();
        let mut served: Vec<u64> = self.store.kv_get_json::<Vec<u64>>(&k).unwrap_or_default();
        served.retain(|t| now.saturating_sub(*t) < SERVE_WINDOW_MS);
        if served.len() >= SERVES_PER_WINDOW {
            tracing::info!("recovery for {:?}: served {} times today, not again", pc.account, served.len());
            return Ok(());
        }
        served.push(now);
        self.store.kv_set(&k, serde_json::to_string(&served)?.as_bytes())?;
        let (me, pc) = (self.clone(), pc.clone());
        tokio::spawn(async move {
            if let Err(e) = me.serve_recovery(&pc).await {
                tracing::warn!("recovery for {:?}: {e:#}", pc.account);
            }
        });
        Ok(())
    }

    async fn serve_recovery(self: &Arc<Self>, pc: &Arc<PeerConn>) -> Result<()> {
        let friend = pc.account;
        let mut rows = self.recovery_rows(&friend);
        rows.reverse(); // oldest first
        let mut total = 0usize;
        let mut batch = Batch::default();
        let mut size = 0usize;
        let mut sent = 0usize;
        for r in rows {
            let it = Item {
                id: r.id,
                author: r.author.clone(),
                hlc: r.hlc as u64,
                kind: r.kind,
                body: r.body,
                reply_to: r.reply_to.map(ByteBuf::from),
                // every signed copy I kept travels (the restored account verifies its own
                // messages against its signature; mine arrive on this authenticated link)
                wire: r.wire.unwrap_or_default(),
            };
            let sz = it.body.len() + it.wire.len() + 96;
            if total + sz > MAX_TOTAL_BYTES {
                break;
            }
            if size + sz > BATCH_BYTES || batch.items.len() >= BATCH_ITEMS {
                pc.ctl.send(proto::ext(ext::RECOVER_BATCH, &std::mem::take(&mut batch))).await.map_err(|_| anyhow!("connection closed"))?;
                size = 0;
                // gentle on the link: ~5 MB/s at most
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            total += sz;
            size += sz;
            sent += 1;
            batch.items.push(it);
        }
        batch.done = true;
        pc.ctl.send(proto::ext(ext::RECOVER_BATCH, &batch)).await.map_err(|_| anyhow!("connection closed"))?;
        // groups we are both still in: welcome them back (state + current key); the group's
        // anti-entropy brings its history
        for gid in self.shared_groups(&friend) {
            if let Err(e) = self.send_welcome(&gid, friend).await {
                tracing::debug!("recovery welcome {}: {e:#}", hex::encode(gid));
            }
        }
        tracing::info!("recovery for {friend:?}: {sent} messages handed back");
        self.emit("recovery_helped", json!({"peer": friend.to_base32(), "messages": sent}));
        Ok(())
    }

    /// Does `key` open an envelope of `epoch` held for a missing key, signed by a member of
    /// `st` other than `sender`? (Proof that it is the group's real key: a member can't make
    /// someone else's signed envelope out of a key of its own.)
    pub(super) fn key_opens_held(&self, st: &crate::group::GroupState, epoch: u64, key: &[u8; 32], sender: &PeerId) -> bool {
        self.store.group_env_pending_peek(&st.gid, epoch, 200).iter().any(|env| {
            matches!(crate::group::open_envelope_any(&[*key], &st.gid, env), Ok(Some(s))
                if s.author != *sender && (st.members.contains_key(&s.author) || st.left.contains(&s.author)))
        })
    }

    // ------------------------------------------------------------ dispatch

    pub(super) fn on_recovery_ext(self: &Arc<Self>, pc: &Arc<PeerConn>, kind: u16, body: &[u8]) -> Result<()> {
        match kind {
            ext::RECOVER_HELLO => self.on_recover_hello(pc, body),
            ext::RECOVER_OFFER => self.on_recover_offer(pc, body),
            ext::RECOVER_ACCEPT => self.on_recover_accept(pc, body),
            ext::RECOVER_BATCH => self.on_recover_batch(pc, body),
            _ => Ok(()),
        }
    }
}

/// Device of a friend that made its offer (`recover.offer_dev.<account>`).
const OFFER_DEV_PREFIX: &str = "recover.offer_dev.";

/// Which one device of a friend gets the accept: `via` / the offering device when
/// connected, else the first connected device; nobody connected: none (asked again on
/// the next connection, `recovery_on_hello`).
fn accept_target(via: Option<PeerId>, offered: Option<PeerId>, live: &[PeerId]) -> Option<PeerId> {
    [via, offered].into_iter().flatten().find(|d| live.contains(d)).or_else(|| live.first().copied())
}

/// A restore hello / accept must come from the account's PRIMARY device itself (the one
/// holding the account key, i.e. restored from the phrase) and carry a plain account-key
/// signature: a linked device — revoked, lost or compromised — holds no account key and
/// can never pull a friend's 1-1 history.
fn ask_sig_ok(dev: &PeerId, account: &PeerId, tag: &[u8], me: &PeerId, m: &SignedAsk) -> bool {
    dev == account && m.sig.len() == 64 && account.verify(&hello_bytes(tag, account, me, m.ts), &m.sig)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;

    /// Regression (1.0.8 review): the accept reaches one device of the friend, never all
    /// of them (each would serve the whole history).
    #[test]
    fn recovery_accept_goes_to_one_device() {
        let [a, b, c] = [0; 3].map(|_| Identity::generate().peer_id());
        assert_eq!(accept_target(None, Some(b), &[a, b, c]), Some(b), "the offering device");
        assert_eq!(accept_target(Some(c), Some(b), &[a, b, c]), Some(c), "the device that just connected");
        assert_eq!(accept_target(Some(c), Some(b), &[a, b]), Some(b));
        assert_eq!(accept_target(None, Some(b), &[a, c]), Some(a), "offering device gone: exactly one other");
        assert_eq!(accept_target(None, None, &[]), None);
    }

    #[test]
    fn signed_asks_bind_account_peer_time_and_purpose() {
        let a = Identity::generate();
        let (pa, pb) = (a.peer_id(), Identity::generate().peer_id());
        let sig = a.sign(&hello_bytes(HELLO_TAG, &pa, &pb, 7));
        assert!(pa.verify(&hello_bytes(HELLO_TAG, &pa, &pb, 7), &sig));
        assert!(!pa.verify(&hello_bytes(HELLO_TAG, &pa, &pb, 8), &sig), "other time");
        assert!(!pa.verify(&hello_bytes(ACCEPT_TAG, &pa, &pb, 7), &sig), "a hello is no accept");
        assert!(!pa.verify(&hello_bytes(HELLO_TAG, &pa, &pa, 7), &sig), "other peer");
    }

    /// Deleted, edited, cleared, purged and disappearing messages are never handed back,
    /// and their signed copies don't outlive them.
    #[test]
    fn tombstones_and_timers_are_never_served() {
        let dir = tempfile::tempdir().unwrap();
        let s = crate::store::Store::open(&dir.path().join("t.db"), &zeroize::Zeroizing::new([7u8; 32])).unwrap();
        let (a, b) = (Identity::generate().peer_id(), Identity::generate().peer_id());
        let conv = direct_conv(&b);
        let put = |n: u8, author: &PeerId, expires: Option<i64>| {
            let id = [n; 16];
            assert!(s.insert_message(&id, &conv, author, (n as u64) << 20, "text", &json!({"text": format!("m{n}")}), 2, None, expires).unwrap());
            s.wire_put(&id, &conv, b"signed").unwrap();
            id
        };
        let live = put(1, &a, None);
        let deleted = put(2, &b, None);
        let edited = put(3, &a, None);
        let purged = put(4, &b, None);
        let _timer = put(5, &a, Some(i64::MAX));
        s.delete_message(&deleted, None, None).unwrap();
        assert!(s.edit_message(&edited, &a, &json!({"text": "đã sửa"}), 9 << 20).unwrap());
        s.purge_message(&purged).unwrap();
        let rows = s.recovery_rows(&conv, 0, i64::MAX, 100);
        let ids: Vec<_> = rows.iter().map(|r| r.id.clone()).collect();
        assert_eq!(ids, vec![edited.to_vec(), live.to_vec()], "only live, non-disappearing messages");
        assert!(rows.iter().all(|r| !r.body.contains("m2") && !r.body.contains("m4")));
        let e = rows.iter().find(|r| r.id == edited).unwrap();
        assert!(e.body.contains("đã sửa") && e.wire.is_none(), "an edit drops the old signed copy");
        assert_eq!(rows.iter().find(|r| r.id == live).unwrap().wire.as_deref(), Some(&b"signed"[..]));
        // the deleted message's signed copy is gone too (not just filtered out)
        s.clear_conv(&conv, i64::MAX).unwrap();
        assert!(s.recovery_rows(&conv, 0, i64::MAX, 100).is_empty());
        assert_eq!(s.wire_gc(), 0, "triggers already removed every orphaned copy");
    }

    #[test]
    fn wire_bodies_round_trip_map_encoded() {
        let b = Batch { items: vec![Item { id: vec![1; 16], author: vec![2; 32], hlc: 9, kind: "text".into(), body: "{}".into(), ..Default::default() }], done: true };
        let PeerMsg::Ext { body, .. } = proto::ext(ext::RECOVER_BATCH, &b) else { panic!() };
        let back: Batch = proto::ext_body(&body).unwrap();
        assert!(back.done && back.items[0].kind == "text" && back.items[0].hlc == 9);
    }

    async fn test_node(tmp: &std::path::Path) -> Arc<Node> {
        Node::start(NodeConfig {
            data_dir: tmp.join("data"),
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

    /// Security fix 1: only a message the restored account signed in a 1-1 chat with the
    /// peer proves a friendship; unverified offers live in their own small pool and
    /// accepting one never makes a friend or opens group welcomes ("who can add me").
    /// Fix 6: anything "mine" without my signature is flagged unverified.
    #[tokio::test]
    async fn only_proven_friends_are_greeted_and_unverified_offers_stay_harmless() {
        let tmp = tempfile::tempdir().unwrap();
        let n = test_node(tmp.path()).await;
        n.mark_restored();
        let f = Identity::generate().peer_id();
        let stranger = Identity::generate().peer_id();
        let mine = n.new_chat_msg(&super::super::chat::dm_scope(&n.me, &f), Body::Text { text: "chào bạn".into() }, None, None);
        let proof = rmp_serde::to_vec(&mine).unwrap();
        assert!(n.recovery_proof_ok(&f, &proof));
        assert!(!n.recovery_proof_ok(&stranger, &proof), "a proof is bound to the chat with that peer");
        assert!(!n.recovery_proof_ok(&stranger, &[]) && !n.recovery_proof_ok(&stranger, b"rac"));
        let mut forged = mine.clone();
        forged.body = Body::Text { text: "đã sửa".into() };
        assert!(!n.recovery_proof_ok(&f, &rmp_serde::to_vec(&forged).unwrap()), "tampered");
        assert!(!n.recovery_proven(&stranger));
        // the old DHT_KEY body (no proof) still decodes
        let old = rmp_serde::to_vec_named(&serde_json::json!({"key": serde_bytes::ByteBuf::from(vec![1u8; 32])})).unwrap();
        assert!(proto::ext_body::<super::super::conn::DhtKeyMsg>(&old).unwrap().proof.is_empty());

        // 30 unverified offers: only 20 kept, the real friend still gets in
        let gid = hex::encode([7u8; 16]);
        let fake = |proof: Vec<u8>| Offer { name: "Bob".into(), messages: 5000, groups: vec![ByteBuf::from(vec![7u8; 16])], since: 1, proof };
        let mut strangers = vec![];
        for _ in 0..30 {
            let p = Identity::generate().peer_id();
            n.store_offer(&p, "x", &fake(vec![]));
            strangers.push(p);
        }
        n.store_offer(&f, "F", &fake(proof.clone()));
        let offers = n.offers();
        assert_eq!(offers.iter().filter(|o| !o.verified).count(), MAX_UNVERIFIED_OFFERS);
        assert!(offers.iter().any(|o| o.peer == f.to_base32() && o.verified), "the proven friend is not evicted");

        // accepting an unverified offer: no friendship, no group welcome allowed
        let u = strangers[0];
        n.recovery_accept(&u).unwrap();
        assert!(!n.store.is_friend(&u), "unverified offer made a friend");
        assert!(n.store.kv_get(&format!("join.pending.{gid}")).is_none(), "unverified offer opened a group welcome");
        let unsigned_mine = |id: u8| Item { id: vec![id; 16], author: n.me.0.to_vec(), hlc: mine.hlc, kind: "text".into(), body: r#"{"text":"tôi nói thế"}"#.into(), ..Default::default() };
        n.apply_recover_batch(&u, &Batch { items: vec![unsigned_mine(3)], done: true });
        let m = n.store.message(&[3u8; 16]).unwrap();
        assert_eq!(m.meta[META_UNVERIFIED], json!(true), "{:?}", m.meta);
        assert_eq!(m.meta[META_FROM], json!("Bob"));

        // the proven friend: a friend again, groups may welcome us back
        n.recovery_accept(&f).unwrap();
        assert!(n.store.is_friend(&f));
        assert!(n.store.kv_get(&format!("join.pending.{gid}")).is_some());
        let signed = Item { id: mine.id.to_vec(), author: n.me.0.to_vec(), hlc: mine.hlc, kind: "text".into(), body: "{}".into(), wire: proof.clone(), ..Default::default() };
        let theirs = Item { id: vec![5; 16], author: f.0.to_vec(), hlc: mine.hlc, kind: "text".into(), body: r#"{"text":"bạn nói"}"#.into(), ..Default::default() };
        n.apply_recover_batch(&f, &Batch { items: vec![unsigned_mine(4), signed, theirs], done: true });
        let unsigned = n.store.message(&[4u8; 16]).unwrap();
        assert_eq!(unsigned.meta[META_UNVERIFIED], json!(true), "my message without my signature: {:?}", unsigned.meta);
        assert!(unsigned.meta[META_FROM].is_string(), "labelled with who gave it back");
        let ok = n.store.message(&mine.id).unwrap();
        assert!(ok.meta.get(META_FROM).is_none() && ok.meta.get(META_UNVERIFIED).is_none(), "my signed message is a normal one: {:?}", ok.meta);
        let t = n.store.message(&[5u8; 16]).unwrap();
        assert!(t.meta[META_FROM].is_string() && t.meta.get(META_UNVERIFIED).is_none(), "{:?}", t.meta);
        n.shutdown();
    }

    /// Plausible fix: a linked device (revoked / compromised) can't ask friends for the
    /// account's 1-1 history — only the primary with a plain account-key signature.
    #[test]
    fn only_the_primary_with_the_account_key_may_ask() {
        let acc = Identity::generate();
        let (pa, me) = (acc.peer_id(), Identity::generate().peer_id());
        let linked = Identity::generate();
        let ts = now_ms();
        let good = SignedAsk { to: me.0.to_vec(), ts, sig: acc.sign(&hello_bytes(HELLO_TAG, &pa, &me, ts)).to_vec() };
        assert!(ask_sig_ok(&pa, &pa, HELLO_TAG, &me, &good));
        assert!(!ask_sig_ok(&linked.peer_id(), &pa, HELLO_TAG, &me, &good), "from a linked device's connection");
        assert!(!ask_sig_ok(&pa, &pa, ACCEPT_TAG, &me, &good), "a hello is no accept");
        // a device signature (DevSig, longer than 64 bytes) is refused even if valid
        let mut devsig = linked.sign(&hello_bytes(HELLO_TAG, &pa, &me, ts)).to_vec();
        devsig.extend_from_slice(&[0u8; 106]);
        assert!(!ask_sig_ok(&pa, &pa, HELLO_TAG, &me, &SignedAsk { sig: devsig, ..good }));
    }

    #[test]
    fn friendship_proof_is_the_newest_small_signed_message_of_that_author() {
        let dir = tempfile::tempdir().unwrap();
        let s = crate::store::Store::open(&dir.path().join("t.db"), &zeroize::Zeroizing::new([7u8; 32])).unwrap();
        let (a, b) = (Identity::generate().peer_id(), Identity::generate().peer_id());
        let conv = direct_conv(&b);
        assert!(s.wire_proof(&conv, &b.0, PROOF_MAX).is_none());
        for (n, author, wire) in [(1u8, &b, vec![1u8; 10]), (2, &a, vec![2u8; 10]), (3, &b, vec![3u8; 9000]), (4, &b, vec![4u8; 10])] {
            assert!(s.insert_message(&[n; 16], &conv, author, (n as u64) << 20, "text", &json!({"text": "x"}), 2, None, None).unwrap());
            s.wire_put(&[n; 16], &conv, &wire).unwrap();
        }
        assert_eq!(s.wire_proof(&conv, &b.0, PROOF_MAX), Some(vec![4u8; 10]));
        s.delete_message(&[4u8; 16], None, None).unwrap();
        assert_eq!(s.wire_proof(&conv, &b.0, PROOF_MAX), Some(vec![1u8; 10]), "deleted and oversized copies are skipped");
        assert!(s.wire_proof(&direct_conv(&a), &b.0, PROOF_MAX).is_none());
    }

    /// Integration item 4(iii): when my own linked device brings the history back (sync),
    /// friends are not asked any more and the app's banner goes away.
    #[tokio::test]
    async fn own_device_history_ends_asking_friends() {
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
        n.mark_restored();
        assert!(n.recovering());
        let mut rx = n.subscribe();
        let friend = Identity::generate().peer_id();
        let row = crate::store::sync::MsgRow {
            id: ByteBuf::from(vec![9u8; 16]),
            conv: direct_conv(&friend),
            author: ByteBuf::from(friend.0.to_vec()),
            hlc: (now_ms() << 16) as i64,
            kind: "text".into(),
            body: json!({"text": "từ thiết bị của tôi"}).to_string(),
            status: 2,
            edited: false,
            deleted: false,
            reply_to: None,
            reactions: String::new(),
            expires: None,
            pinned: false,
            meta: String::new(),
            device: None,
            rev: 1,
            my_rev: 0,
            edit_hlc: 0,
        };
        n.apply_sync_item(crate::store::sync::SyncItem::Msg(row), true).unwrap();
        assert!(!n.recovering(), "still asking friends after my own device restored the history");
        assert_eq!(n.recovery_offers()["recovering"], json!(false));
        let mut saw = false;
        while let Ok(e) = rx.try_recv() {
            saw |= e["event"] == "recovery" && e["recovering"] == json!(false) && e["own_device"] == json!(true);
        }
        assert!(saw, "the app was not told");
        n.shutdown();
    }
}
