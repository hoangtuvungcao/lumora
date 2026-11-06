//! Serverless signaling + directory over public Nostr relays.
//!
//! Hundreds of independent, free Nostr relays exist; we use several at once so the
//! loss of any one does not matter. Only *sealed* envelopes are posted, so relay
//! operators see random bytes addressed to a random-looking inbox tag.
//!
//! * live signaling – ephemeral events (kind 21212, never stored by relays)
//! * ID directory   – parameterised-replaceable kind 30078, `d = lumora:sid:<9 digits>`,
//!   content signed by the Ed25519 identity (relays cannot forge an ID mapping).

use crate::identity::{Identity, PeerId};
use data_encoding::BASE64;
use futures::{SinkExt, StreamExt};
use parking_lot::RwLock;
use secp256k1::{Keypair, Message as SMessage, SECP256K1};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{broadcast, mpsc};
use tokio_tungstenite::tungstenite::Message;

pub const SIGNAL_KIND: u64 = 21212;
/// Multi-device link rendezvous (ephemeral, never stored).
pub const LINK_KIND: u64 = 21213;
pub const DIR_KIND: u64 = 30078;

pub const DEFAULT_RELAYS: &[&str] = &[
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.primal.net",
    "wss://nostr.mom",
    "wss://relay.nostr.net",
];

/// Public inbox of a device: anyone who knows its key can compute it (first contact from
/// strangers). Subscribing to it tells a relay operator "this IP waits for mail to that
/// ID", so it is only subscribed while the user lets strangers find them, on a random
/// subset of the relays.
pub fn inbox_tag(peer: &PeerId) -> String {
    hex::encode(blake3::derive_key("lumora nostr inbox v1", &peer.0))
}

/// Friends' inbox of a device for `day` (days since the epoch): derived from the device's
/// friends-only key (`Ext DHT_KEY`, rotated when a friend leaves) — unlinkable to the ID
/// for anyone without the key, and different every day.
pub fn friend_inbox_tag(key: &[u8; 32], day: u64) -> String {
    let mut m = key.to_vec();
    m.extend_from_slice(&day.to_le_bytes());
    hex::encode(blake3::derive_key("lumora nostr friend inbox v1", &m))
}

pub fn today() -> u64 {
    crate::util::now_ms() / 86_400_000
}

/// What this device listens to: friends' tags on every relay, the public inbox (if any)
/// only on the relays picked for it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct InboxSubs {
    pub friend_tags: Vec<String>,
    pub public: Option<String>,
}

/// Untrusted relays: bounded WebSocket messages, and bounded results per query.
const WS_MAX_MESSAGE: usize = 256 * 1024;
const QUERY_MAX_EVENTS: usize = 200;
const QUERY_MAX_BYTES: usize = 512 * 1024;
/// Relays (out of the configured ones) that carry the public inbox subscription.
const PUBLIC_INBOX_RELAYS: usize = 2;

async fn ws_connect(
    url: &str,
    wait: Duration,
) -> anyhow::Result<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>> {
    let mut cfg = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default();
    cfg.max_message_size = Some(WS_MAX_MESSAGE);
    cfg.max_frame_size = Some(WS_MAX_MESSAGE);
    let (ws, _) = tokio::time::timeout(wait, tokio_tungstenite::connect_async_with_config(url, Some(cfg), false)).await??;
    Ok(ws)
}

/// Collect events from one query connection with a cap on count and bytes (a hostile
/// relay can't make us buffer without bound).
fn take_event(evs: &mut Vec<Value>, bytes: &mut usize, text_len: usize, ev: Value) -> bool {
    *bytes += text_len;
    if evs.len() >= QUERY_MAX_EVENTS || *bytes > QUERY_MAX_BYTES {
        return false;
    }
    evs.push(ev);
    true
}

fn sign_event(kp: &Keypair, kind: u64, tags: Value, content: &str) -> Value {
    let pubkey = hex::encode(kp.x_only_public_key().0.serialize());
    let created_at = crate::util::now_ms() / 1000;
    let ser = json!([0, pubkey, created_at, kind, tags, content]).to_string();
    let id: [u8; 32] = Sha256::digest(ser.as_bytes()).into();
    let msg = SMessage::from_digest(id);
    let sig = SECP256K1.sign_schnorr(&msg, kp);
    json!({
        "id": hex::encode(id), "pubkey": pubkey, "created_at": created_at,
        "kind": kind, "tags": tags, "content": content, "sig": hex::encode(sig.as_ref()),
    })
}

/// NIP-13 proof of work: find a nonce so the event id has `bits` leading zero bits.
fn sign_event_pow(kp: &Keypair, kind: u64, mut tags: Vec<Value>, content: &str, bits: u32) -> Value {
    let pubkey = hex::encode(kp.x_only_public_key().0.serialize());
    let created_at = crate::util::now_ms() / 1000;
    tags.push(json!(["nonce", "0", bits.to_string()]));
    let ni = tags.len() - 1;
    let mut nonce: u64 = rand::random::<u32>() as u64;
    loop {
        tags[ni][1] = json!(nonce.to_string());
        let ser = json!([0, pubkey, created_at, kind, tags, content]).to_string();
        let id: [u8; 32] = Sha256::digest(ser.as_bytes()).into();
        if leading_zero_bits(&id) >= bits {
            let sig = SECP256K1.sign_schnorr(&SMessage::from_digest(id), kp);
            return json!({
                "id": hex::encode(id), "pubkey": pubkey, "created_at": created_at,
                "kind": kind, "tags": tags, "content": content, "sig": hex::encode(sig.as_ref()),
            });
        }
        nonce += 1;
    }
}

fn leading_zero_bits(id: &[u8]) -> u32 {
    let mut n = 0;
    for b in id {
        if *b == 0 {
            n += 8;
        } else {
            n += b.leading_zeros();
            break;
        }
    }
    n
}

/// What `sig2` of a group listing signs: every field a reader is shown, plus the proof.
fn group_listing_msg_v2(handle: &str, c: &Value) -> String {
    let shown = json!([c["gid"], c["title"], c["about"], c["members"], c["kind"], c["tag"], c["proof"]]).to_string();
    format!(
        "lumora-group-v2|{}|{}|{}|{}|{}|{}",
        handle,
        c["gid"].as_str().unwrap_or(""),
        c["ts"],
        c["expires"],
        c["admin"].as_str().unwrap_or(""),
        blake3::hash(shown.as_bytes()).to_hex()
    )
}

/// Check one group listing (the event's content) published under `handle`:
/// * `None`: forged, expired or malformed — drop it;
/// * `Some(false)`: a valid listing from an older version (signed by the admin it names,
///   but nothing proves that person administers the group) — show it as unverified;
/// * `Some(true)`: `proof` (the group's own signed ops, starting with the `Create` the gid
///   is derived from) makes `admin` an admin/owner, and `sig2` by that admin covers the
///   title, description, counts and proof.
pub fn check_group_listing(handle: &str, c: &Value, now_ms: u64) -> Option<bool> {
    let (Some(gid), Some(ts), Some(exp), Some(sig), Some(admin)) = (c["gid"].as_str(), c["ts"].as_u64(), c["expires"].as_u64(), c["sig"].as_str(), c["admin"].as_str()) else {
        return None;
    };
    if exp < now_ms {
        return None;
    }
    let a = PeerId::from_str_any(admin).ok()?;
    let gid16: crate::group::Gid = hex::decode(gid).ok()?.try_into().ok()?;
    let msg = format!("lumora-group-v1|{}|{}|{}|{}", handle, gid, ts, exp);
    if !a.verify(msg.as_bytes(), &hex::decode(sig).unwrap_or_default()) {
        return None;
    }
    if c.get("proof").is_none() && c.get("sig2").is_none() {
        return Some(false);
    }
    // claims a proof: it must hold, or the listing is a forgery
    let (Some(proof), Some(sig2)) = (c["proof"].as_str(), c["sig2"].as_str()) else { return None };
    if !a.verify(group_listing_msg_v2(handle, c).as_bytes(), &hex::decode(sig2).unwrap_or_default()) {
        return None;
    }
    let proof = data_encoding::BASE64.decode(proof.as_bytes()).ok()?;
    crate::group::verify_admin_proof(&gid16, &a, &proof).then_some(true)
}

/// One entry per group (verified beats unverified, then the newest), verified first;
/// proof material stripped.
pub fn rank_group_listings(list: Vec<Value>) -> Vec<Value> {
    let mut out: Vec<Value> = vec![];
    for mut c in list {
        if let Some(o) = c.as_object_mut() {
            o.remove("proof");
            o.remove("sig2");
        }
        let key = |v: &Value| (v["verified"].as_bool().unwrap_or(false), v["ts"].as_u64().unwrap_or(0));
        match out.iter_mut().find(|o| o["gid"] == c["gid"]) {
            Some(o) if key(&c) > key(o) => *o = c,
            Some(_) => {}
            None => out.push(c),
        }
    }
    // stable: relay order is kept within each class
    out.sort_by_key(|v| !v["verified"].as_bool().unwrap_or(false));
    out
}

pub const USERNAME_POW_BITS: u32 = 16;
pub const USERNAME_TTL_MS: u64 = 90 * 86_400_000;

/// 6-character tag derived from the key: `@name·tag` is unique and unforgeable.
pub fn handle_tag(p: &PeerId) -> String {
    data_encoding::BASE32_NOPAD.encode(&blake3::derive_key("lumora handle tag v1", &p.0)[..5]).to_lowercase()[..6].to_string()
}

pub fn valid_username(name: &str) -> bool {
    let n = name.len();
    (3..=24).contains(&n) && name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_') && !name.starts_with('_')
}

/// Fuzz-harness access to the private event checks (feature `fuzzing`, never shipped).
#[cfg(feature = "fuzzing")]
#[doc(hidden)]
pub fn fuzz_verify_event(ev: &Value) -> (bool, u32) {
    (verify_event(ev), leading_zero_bits(&hex::decode(ev["id"].as_str().unwrap_or("")).unwrap_or_default()))
}

fn verify_event(ev: &Value) -> bool {
    let (Some(pk), Some(ca), Some(kind), Some(tags), Some(content), Some(id), Some(sig)) = (
        ev["pubkey"].as_str(),
        ev["created_at"].as_u64(),
        ev["kind"].as_u64(),
        ev.get("tags"),
        ev["content"].as_str(),
        ev["id"].as_str(),
        ev["sig"].as_str(),
    ) else {
        return false;
    };
    let ser = json!([0, pk, ca, kind, tags, content]).to_string();
    let calc: [u8; 32] = Sha256::digest(ser.as_bytes()).into();
    if hex::encode(calc) != id {
        return false;
    }
    let (Ok(pkb), Ok(sigb)) = (hex::decode(pk), hex::decode(sig)) else { return false };
    let (Ok(xpk), Ok(s)) = (
        secp256k1::XOnlyPublicKey::from_slice(&pkb),
        secp256k1::schnorr::Signature::from_slice(&sigb),
    ) else {
        return false;
    };
    SECP256K1.verify_schnorr(&s, &SMessage::from_digest(calc), &xpk).is_ok()
}

pub struct NostrPool {
    relays: Vec<String>,
    out: broadcast::Sender<String>,
    pub connected: Arc<AtomicUsize>,
    eph: Keypair,
    dir_key: Keypair,
    pub status: Arc<RwLock<Vec<(String, bool)>>>,
    /// Reconnect every relay now (the network changed).
    kick: Arc<tokio::sync::Notify>,
    /// Ping every relay now; only one that doesn't answer reconnects.
    probe: Arc<tokio::sync::Notify>,
    /// Last sign of life from any relay.
    last_rx: Arc<parking_lot::Mutex<std::time::Instant>>,
    /// Inbox subscriptions (changed by the node: friends' keys, the privacy setting).
    subs: tokio::sync::watch::Sender<InboxSubs>,
    /// Devices whose friends-only key we hold: signals to them go to their friends' inbox.
    friend_keys: RwLock<std::collections::HashMap<PeerId, [u8; 32]>>,
}

impl NostrPool {
    pub fn spawn(id: &Identity, relays: Vec<String>, signals: mpsc::Sender<super::relay_client::IncomingSignal>) -> Arc<Self> {
        let (out, _) = broadcast::channel(256);
        let eph = Keypair::new(SECP256K1, &mut secp256k1::rand::thread_rng());
        let dsk = blake3::derive_key("lumora nostr dir key v1", &id.secret_bytes()[..]);
        let dir_key = Keypair::from_seckey_slice(SECP256K1, &dsk).expect("valid key");
        // until the node says otherwise: the public inbox (strangers may find me by default)
        let (subs, _) = tokio::sync::watch::channel(InboxSubs { friend_tags: vec![], public: Some(inbox_tag(&id.peer_id())) });
        let pool = Arc::new(NostrPool {
            relays: relays.clone(),
            out,
            connected: Arc::new(AtomicUsize::new(0)),
            eph,
            dir_key,
            status: Arc::new(RwLock::new(relays.iter().map(|r| (r.clone(), false)).collect())),
            kick: Arc::new(tokio::sync::Notify::new()),
            probe: Arc::new(tokio::sync::Notify::new()),
            last_rx: Arc::new(parking_lot::Mutex::new(std::time::Instant::now())),
            subs,
            friend_keys: RwLock::new(std::collections::HashMap::new()),
        });
        // the public inbox only on a random subset of the relays (fewer operators see
        // "this IP waits for mail to that ID"); senders post to all of them
        let mut order: Vec<usize> = (0..relays.len()).collect();
        for i in (1..order.len()).rev() {
            order.swap(i, rand::random::<usize>() % (i + 1));
        }
        let public_on: Vec<bool> = (0..relays.len()).map(|i| order.iter().position(|x| *x == i).unwrap_or(0) < PUBLIC_INBOX_RELAYS).collect();
        for (i, url) in relays.into_iter().enumerate() {
            let rx = pool.out.subscribe();
            let p = pool.clone();
            let signals = signals.clone();
            let subs = pool.subs.subscribe();
            let public = public_on[i];
            tokio::spawn(async move { p.relay_loop(i, url, public, subs, rx, signals).await });
        }
        pool
    }

    /// Replace the inbox subscriptions (every relay re-subscribes at once).
    pub fn set_inboxes(&self, subs: InboxSubs) {
        self.subs.send_if_modified(|cur| {
            if *cur == subs {
                return false;
            }
            *cur = subs;
            true
        });
    }

    pub fn inboxes(&self) -> InboxSubs {
        self.subs.borrow().clone()
    }

    /// Friends-only keys of other devices (to address their friends' inbox).
    pub fn set_friend_keys(&self, keys: std::collections::HashMap<PeerId, [u8; 32]>) {
        *self.friend_keys.write() = keys;
    }

    pub fn set_friend_key(&self, dev: PeerId, key: Option<[u8; 32]>) {
        match key {
            Some(k) => {
                self.friend_keys.write().insert(dev, k);
            }
            None => {
                self.friend_keys.write().remove(&dev);
            }
        }
    }

    /// The tag a signal to `to` is posted under.
    pub fn tag_for(&self, to: &PeerId) -> String {
        match self.friend_keys.read().get(to) {
            Some(k) => friend_inbox_tag(k, today()),
            None => inbox_tag(to),
        }
    }

    fn sub_req(subs: &InboxSubs, public: bool) -> Option<String> {
        let mut tags = subs.friend_tags.clone();
        if public {
            tags.extend(subs.public.clone());
        }
        if tags.is_empty() {
            return None;
        }
        let since = crate::util::now_ms() / 1000 - 30;
        Some(json!(["REQ", "lumora-in", {"kinds": [SIGNAL_KIND], "#p": tags, "since": since}]).to_string())
    }

    /// Connected and heard from (or reconnected) after `t`.
    pub fn alive_since(&self, t: std::time::Instant) -> bool {
        self.connected.load(Ordering::SeqCst) > 0 && *self.last_rx.lock() > t
    }

    /// Ping every relay; one that doesn't answer within 1 s reconnects.
    pub fn probe(&self) {
        self.probe.notify_waiters();
    }

    async fn relay_loop(
        self: Arc<Self>,
        idx: usize,
        url: String,
        public: bool,
        mut subs: tokio::sync::watch::Receiver<InboxSubs>,
        mut out: broadcast::Receiver<String>,
        signals: mpsc::Sender<super::relay_client::IncomingSignal>,
    ) {
        let mut backoff = 2u64;
        loop {
            let res: anyhow::Result<()> = async {
                let ws = ws_connect(&url, Duration::from_secs(10)).await?;
                let (mut tx, mut rx) = ws.split();
                let cur = subs.borrow_and_update().clone();
                if let Some(req) = Self::sub_req(&cur, public) {
                    tx.send(Message::Text(req.into())).await?;
                }
                self.connected.fetch_add(1, Ordering::SeqCst);
                self.status.write()[idx].1 = true;
                *self.last_rx.lock() = std::time::Instant::now();
                let r: anyhow::Result<()> = async {
                    let mut ping = tokio::time::interval(Duration::from_secs(30));
                    let mut probe_until: Option<tokio::time::Instant> = None;
                    loop {
                        let probe_wait = async {
                            match probe_until {
                                Some(t) => tokio::time::sleep_until(t).await,
                                None => futures::future::pending::<()>().await,
                            }
                        };
                        tokio::select! {
                            m = rx.next() => {
                                let Some(m) = m else { anyhow::bail!("closed") };
                                let m = m?;
                                probe_until = None;
                                *self.last_rx.lock() = std::time::Instant::now();
                                if let Message::Text(t) = m {
                                    let v: Value = serde_json::from_str(&t).unwrap_or(Value::Null);
                                    if v[0] == "EVENT" && verify_event(&v[2]) {
                                        if let Some(c) = v[2]["content"].as_str() {
                                            if let Ok(data) = BASE64.decode(c.as_bytes()) {
                                                let _ = signals.send(super::relay_client::IncomingSignal { via: url.clone(), data }).await;
                                            }
                                        }
                                    }
                                }
                            }
                            o = out.recv() => {
                                match o {
                                    Ok(s) => tx.send(Message::Text(s.into())).await?,
                                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                                    Err(_) => anyhow::bail!("pool closed"),
                                }
                            }
                            _ = ping.tick() => { tx.send(Message::Ping(Vec::new().into())).await?; }
                            _ = self.kick.notified() => anyhow::bail!("reconnect requested"),
                            _ = self.probe.notified() => {
                                if probe_until.is_none() {
                                    probe_until = Some(tokio::time::Instant::now() + Duration::from_millis(1000));
                                }
                                tx.send(Message::Ping(Vec::new().into())).await?;
                            }
                            _ = probe_wait => anyhow::bail!("reconnect requested"),
                            ch = subs.changed() => {
                                if ch.is_err() {
                                    anyhow::bail!("pool closed");
                                }
                                let cur = subs.borrow_and_update().clone();
                                let msg = Self::sub_req(&cur, public).unwrap_or_else(|| json!(["CLOSE", "lumora-in"]).to_string());
                                tx.send(Message::Text(msg.into())).await?;
                            }
                        }
                    }
                }
                .await;
                self.connected.fetch_sub(1, Ordering::SeqCst);
                self.status.write()[idx].1 = false;
                r
            }
            .await;
            if let Err(e) = res {
                if e.to_string() == "reconnect requested" {
                    backoff = 2;
                    continue;
                }
                tracing::debug!("nostr {url}: {e:#}");
            }
            tokio::time::sleep(Duration::from_secs(backoff)).await;
            backoff = (backoff * 2).min(120);
        }
    }

    /// Post a sealed envelope to `to`'s inbox on every connected relay.
    pub fn send_signal(&self, to: &PeerId, sealed: &[u8]) -> bool {
        let ev = sign_event(&self.eph, SIGNAL_KIND, json!([["p", self.tag_for(to)]]), &BASE64.encode(sealed));
        self.out.send(json!(["EVENT", ev]).to_string()).is_ok() && self.connected.load(Ordering::SeqCst) > 0
    }

    /// Publish "short id → public key" so others can dial us with 9 digits. Returns the
    /// signed event (linked devices keep it and re-broadcast it while the main one is off).
    pub fn publish_directory(&self, id: &Identity, name: &str) -> Value {
        self.publish_directory_ext(id, name, None)
    }

    /// A linked device's own short ID (remote control by device): also names its account
    /// and carries its device certificate (older resolvers ignore both fields).
    pub fn publish_directory_ext(&self, id: &Identity, name: &str, device_of: Option<(&PeerId, &[u8])>) -> Value {
        let p = id.peer_id();
        let ts = crate::util::now_ms();
        let msg = format!("lumora-dir-v1|{}|{}|{}", p.short_id(), p.to_base32(), ts);
        let mut content = json!({"peer": p.to_base32(), "ts": ts, "name": name, "sig": hex::encode(id.sign(msg.as_bytes()))});
        if let Some((account, cert)) = device_of {
            content["account"] = json!(account.to_base32());
            content["cert"] = json!(hex::encode(cert));
        }
        let tags = json!([["d", format!("lumora:sid:{}", p.short_id())]]);
        let ev = sign_event(&self.dir_key, DIR_KIND, tags, &content.to_string());
        let _ = self.out.send(json!(["EVENT", ev.clone()]).to_string());
        ev
    }

    /// The network changed: reconnect every relay now (their TCP connections are likely dead).
    pub fn kick(&self) {
        self.kick.notify_waiters();
    }

    /// Withdraw this key's short-ID directory record ("let strangers find me by ID" off):
    /// a replacement without a key, which every resolver skips.
    pub fn unpublish_directory(&self, id: &Identity) -> Value {
        let p = id.peer_id();
        let tags = json!([["d", format!("lumora:sid:{}", p.short_id())]]);
        let ev = sign_event(&self.dir_key, DIR_KIND, tags, &json!({"released": true}).to_string());
        let _ = self.out.send(json!(["EVENT", ev.clone()]).to_string());
        ev
    }

    /// Re-broadcast an event signed earlier (by this account's main device).
    pub fn publish_raw(&self, ev: &Value) {
        if verify_event(ev) {
            let _ = self.out.send(json!(["EVENT", ev]).to_string());
        }
    }

    /// Publish (or renew) `@name·tag`. Each identity holds one name; the record expires
    /// after 90 days unless renewed (clients renew automatically while running).
    pub fn publish_username(&self, id: &Identity, name: &str, old: Option<&str>) -> Value {
        self.publish_username_owned(id, name, old, None)
    }

    /// Bots add their owner's signed proof: the handle tag then derives from owner+name.
    pub fn publish_username_owned(&self, id: &Identity, name: &str, old: Option<&str>, owner: Option<&Value>) -> Value {
        let p = id.peer_id();
        let ts = crate::util::now_ms();
        let expires = ts + USERNAME_TTL_MS;
        let msg = format!("lumora-user-v1|{}|{}|{}|{}", name, p.to_base32(), ts, expires);
        let mut content = json!({"peer": p.to_base32(), "name": name, "ts": ts, "expires": expires, "sig": hex::encode(id.sign(msg.as_bytes()))});
        if let Some(o) = owner {
            content["owner"] = o.clone();
        }
        let tags = vec![json!(["d", format!("lumora:user:{name}")]), json!(["expiration", (expires / 1000).to_string()])];
        let ev = sign_event_pow(&self.dir_key, DIR_KIND, tags, &content.to_string(), USERNAME_POW_BITS);
        let _ = self.out.send(json!(["EVENT", ev.clone()]).to_string());
        if let Some(old) = old.filter(|o| *o != name) {
            // release the old name: overwrite our record with an expired tombstone
            let tomb = json!({"peer": p.to_base32(), "name": old, "released": true});
            let tags = vec![json!(["d", format!("lumora:user:{old}")]), json!(["expiration", (ts / 1000).to_string()])];
            let ev = sign_event(&self.dir_key, DIR_KIND, json!(tags), &tomb.to_string());
            let _ = self.out.send(json!(["EVENT", ev]).to_string());
        }
        ev
    }

    /// Tombstone a username record published by `id` (used by BotFather to delete a bot).
    pub fn unpublish_user_as(&self, id: &Identity, name: &str) {
        let dsk = blake3::derive_key("lumora nostr dir key v1", &id.secret_bytes()[..]);
        let Ok(kp) = Keypair::from_seckey_slice(SECP256K1, &dsk) else { return };
        let ts = crate::util::now_ms() / 1000;
        let tags = json!([["d", format!("lumora:user:{name}")], ["expiration", ts.to_string()]]);
        let ev = sign_event(&kp, DIR_KIND, tags, &json!({"released": true, "name": name}).to_string());
        let _ = self.out.send(json!(["EVENT", ev]).to_string());
    }

    /// All live owners of `name` (verified signature, PoW, not expired, not released).
    /// Bot records carrying a valid owner proof get the owner-derived tag; for each such tag
    /// only the newest bot key counts (token revocation).
    pub async fn lookup_username(&self, name: &str) -> Vec<(PeerId, String)> {
        let d = format!("lumora:user:{name}");
        let evs = self.query(json!({"kinds": [DIR_KIND], "#d": [d], "limit": 50})).await;
        let now = crate::util::now_ms();
        let mut found: Vec<(PeerId, String)> = vec![];
        let mut found_created: Vec<(String, u64)> = vec![];
        for ev in evs {
            if !verify_event(&ev) || leading_zero_bits(&hex::decode(ev["id"].as_str().unwrap_or("")).unwrap_or_default()) < USERNAME_POW_BITS {
                continue;
            }
            let Ok(c) = serde_json::from_str::<Value>(ev["content"].as_str().unwrap_or("")) else { continue };
            if c["released"].as_bool() == Some(true) {
                continue;
            }
            let (Some(ps), Some(ts), Some(exp), Some(sig)) = (c["peer"].as_str(), c["ts"].as_u64(), c["expires"].as_u64(), c["sig"].as_str()) else { continue };
            if c["name"].as_str() != Some(name) || exp < now || exp > now + USERNAME_TTL_MS + 86_400_000 {
                continue;
            }
            let Ok(p) = PeerId::from_str_any(ps) else { continue };
            let msg = format!("lumora-user-v1|{}|{}|{}|{}", name, p.to_base32(), ts, exp);
            if !p.verify(msg.as_bytes(), &hex::decode(sig).unwrap_or_default()) {
                continue;
            }
            // bot ownership proof?
            let mut tag = handle_tag(&p);
            let mut created = 0u64;
            if let Some(o) = c.get("owner") {
                if let (Some(os), Some(cr), Some(osig)) = (o["owner"].as_str(), o["created"].as_u64(), o["sig"].as_str()) {
                    if let Ok(owner) = PeerId::from_str_any(os) {
                        if owner.verify(&crate::node::botfather::ownership_bytes(&p, name, cr), &hex::decode(osig).unwrap_or_default()) {
                            tag = crate::node::botfather::bot_tag(&owner, name);
                            created = cr;
                        }
                    }
                }
            }
            if let Some(i) = found_created.iter().position(|(t, _)| *t == tag) {
                if created > found_created[i].1 {
                    found.retain(|(_, t)| *t != tag);
                    found_created[i].1 = created;
                    found.push((p, tag));
                }
                continue;
            }
            if !found.iter().any(|(f, _)| *f == p) {
                found_created.push((tag.clone(), created));
                found.push((p, tag));
            }
        }
        found
    }

    /// Public group directory: `@handle·tag` → {gid, title, about, members, admins to ask}.
    /// Signed by an admin's identity; expires after 90 days unless renewed. With `proof`
    /// (base64 of [`crate::group::admin_proof`]) the listing also carries `sig2`, which
    /// covers everything shown, so readers can check the admin from the gid itself.
    pub fn publish_group(&self, id: &Identity, handle: &str, info: &Value) {
        let ts = crate::util::now_ms();
        let expires = ts + USERNAME_TTL_MS;
        let mut c = info.clone();
        c["ts"] = json!(ts);
        c["expires"] = json!(expires);
        c["admin"] = json!(id.peer_id().to_base32());
        let msg = format!("lumora-group-v1|{}|{}|{}|{}", handle, c["gid"].as_str().unwrap_or(""), ts, expires);
        c["sig"] = json!(hex::encode(id.sign(msg.as_bytes())));
        if c["proof"].is_string() {
            c["sig2"] = json!(hex::encode(id.sign(group_listing_msg_v2(handle, &c).as_bytes())));
        }
        let tags = vec![json!(["d", format!("lumora:group:{handle}")]), json!(["expiration", (expires / 1000).to_string()])];
        let ev = sign_event_pow(&self.dir_key, DIR_KIND, tags, &c.to_string(), USERNAME_POW_BITS);
        let _ = self.out.send(json!(["EVENT", ev]).to_string());
    }

    pub fn unpublish_group(&self, handle: &str) {
        let ts = crate::util::now_ms() / 1000;
        let tags = json!([["d", format!("lumora:group:{handle}")], ["expiration", ts.to_string()]]);
        let ev = sign_event(&self.dir_key, DIR_KIND, tags, &json!({"released": true}).to_string());
        let _ = self.out.send(json!(["EVENT", ev]).to_string());
    }

    /// Public groups named `handle` (signature by the listed admin, PoW, not expired).
    /// Each result has `verified`: true when the admin is proven from the gid (see
    /// [`check_group_listing`]); verified listings come first, and an unverified listing
    /// never shadows a verified one for the same group (same gid ⇒ same `@handle·tag`).
    pub async fn lookup_group(&self, handle: &str) -> Vec<Value> {
        let evs = self.query(json!({"kinds": [DIR_KIND], "#d": [format!("lumora:group:{handle}")], "limit": 50})).await;
        let now = crate::util::now_ms();
        let mut out: Vec<Value> = vec![];
        for ev in evs {
            if !verify_event(&ev) || leading_zero_bits(&hex::decode(ev["id"].as_str().unwrap_or("")).unwrap_or_default()) < USERNAME_POW_BITS {
                continue;
            }
            let Ok(mut c) = serde_json::from_str::<Value>(ev["content"].as_str().unwrap_or("")) else { continue };
            let Some(verified) = check_group_listing(handle, &c, now) else { continue };
            c["verified"] = json!(verified);
            out.push(c);
        }
        rank_group_listings(out)
    }

    /// Multi-device link rendezvous (short code): an ephemeral, unsigned-by-us event under a
    /// tag derived from the code's first 4 digits. It carries no secret (see devices.rs).
    pub fn post_link_beacon(&self, tag: &str, content: &str) -> bool {
        let ev = sign_event(&self.eph, LINK_KIND, json!([["p", tag]]), content);
        self.out.send(json!(["EVENT", ev]).to_string()).is_ok() && self.connected.load(Ordering::SeqCst) > 0
    }

    /// Listen for link beacons under `tag` for `wait` (ephemeral events are never stored,
    /// so this waits for the next periodic post).
    pub async fn watch_link_beacons(&self, tag: &str, wait: Duration) -> Vec<Value> {
        let since = crate::util::now_ms() / 1000 - 20;
        let filter = json!({"kinds": [LINK_KIND], "#p": [tag], "since": since});
        let mut tasks = Vec::new();
        for url in self.relays.clone() {
            let filter = filter.clone();
            tasks.push(tokio::spawn(async move {
                let r: anyhow::Result<Vec<Value>> = async {
                    let ws = ws_connect(&url, Duration::from_secs(6)).await?;
                    let (mut tx, mut rx) = ws.split();
                    tx.send(Message::Text(json!(["REQ", "lumora-link", filter]).to_string().into())).await?;
                    let mut evs = Vec::new();
                    let deadline = tokio::time::Instant::now() + wait;
                    while let Ok(Some(m)) = tokio::time::timeout_at(deadline, rx.next()).await {
                        if let Message::Text(t) = m? {
                            let v: Value = serde_json::from_str(&t).unwrap_or(Value::Null);
                            if v[0] == "EVENT" && verify_event(&v[2]) {
                                evs.push(v[2].clone());
                                if evs.len() >= 8 {
                                    break;
                                }
                            }
                        }
                    }
                    let _ = tx.send(Message::Close(None)).await;
                    Ok(evs)
                }
                .await;
                r.unwrap_or_default()
            }));
        }
        let mut out = vec![];
        for t in tasks {
            out.extend(t.await.unwrap_or_default());
        }
        out
    }

    async fn query(&self, filter: Value) -> Vec<Value> {
        let mut tasks = Vec::new();
        for url in self.relays.clone() {
            let filter = filter.clone();
            tasks.push(tokio::spawn(async move {
                let r: anyhow::Result<Vec<Value>> = async {
                    let ws = ws_connect(&url, Duration::from_secs(6)).await?;
                    let (mut tx, mut rx) = ws.split();
                    tx.send(Message::Text(json!(["REQ", "lumora-q", filter]).to_string().into())).await?;
                    let mut evs = Vec::new();
                    let mut bytes = 0usize;
                    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
                    while let Ok(Some(m)) = tokio::time::timeout_at(deadline, rx.next()).await {
                        if let Message::Text(t) = m? {
                            let v: Value = serde_json::from_str(&t).unwrap_or(Value::Null);
                            if v[0] == "EVENT" {
                                if !take_event(&mut evs, &mut bytes, t.len(), v[2].clone()) {
                                    break;
                                }
                            } else if v[0] == "EOSE" {
                                break;
                            }
                        }
                    }
                    let _ = tx.send(Message::Close(None)).await;
                    Ok(evs)
                }
                .await;
                r.unwrap_or_default()
            }));
        }
        let mut out = vec![];
        for t in tasks {
            out.extend(t.await.unwrap_or_default());
        }
        out.truncate(QUERY_MAX_EVENTS * 4);
        out
    }

    /// Resolve a 9-digit ID. Only keys that hash to that ID are accepted.
    pub async fn lookup_short_id(&self, sid: u32) -> Vec<(PeerId, String)> {
        self.lookup_short_id_full(sid).await.into_iter().map(|(p, n, _)| (p, n)).collect()
    }

    /// Like `lookup_short_id`, plus the device certificate a linked device published.
    pub async fn lookup_short_id_full(&self, sid: u32) -> Vec<(PeerId, String, Option<Vec<u8>>)> {
        let mut tasks = Vec::new();
        for url in self.relays.clone() {
            tasks.push(tokio::spawn(async move {
                let r: anyhow::Result<Vec<Value>> = async {
                    let ws = ws_connect(&url, Duration::from_secs(6)).await?;
                    let (mut tx, mut rx) = ws.split();
                    let req = json!(["REQ", "lumora-dir", {"kinds": [DIR_KIND], "#d": [format!("lumora:sid:{sid}")], "limit": 10}]);
                    tx.send(Message::Text(req.to_string().into())).await?;
                    let mut evs = Vec::new();
                    let mut bytes = 0usize;
                    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
                    while let Ok(Some(m)) = tokio::time::timeout_at(deadline, rx.next()).await {
                        if let Message::Text(t) = m? {
                            let v: Value = serde_json::from_str(&t).unwrap_or(Value::Null);
                            if v[0] == "EVENT" {
                                if !take_event(&mut evs, &mut bytes, t.len(), v[2].clone()) {
                                    break;
                                }
                            } else if v[0] == "EOSE" {
                                break;
                            }
                        }
                    }
                    let _ = tx.send(Message::Close(None)).await;
                    Ok(evs)
                }
                .await;
                r.unwrap_or_default()
            }));
        }
        let mut found: Vec<(PeerId, String, Option<Vec<u8>>)> = Vec::new();
        for t in tasks {
            for ev in t.await.unwrap_or_default() {
                if !verify_event(&ev) {
                    continue;
                }
                let Ok(c) = serde_json::from_str::<Value>(ev["content"].as_str().unwrap_or("")) else { continue };
                let (Some(ps), Some(ts), Some(sig)) = (c["peer"].as_str(), c["ts"].as_u64(), c["sig"].as_str()) else { continue };
                let Ok(p) = PeerId::from_str_any(ps) else { continue };
                if p.short_id() != sid {
                    continue;
                }
                let msg = format!("lumora-dir-v1|{}|{}|{}", sid, p.to_base32(), ts);
                if !p.verify(msg.as_bytes(), &hex::decode(sig).unwrap_or_default()) {
                    continue;
                }
                if !found.iter().any(|(f, _, _)| *f == p) {
                    let cert = c["cert"].as_str().and_then(|h| hex::decode(h).ok());
                    found.push((p, c["name"].as_str().unwrap_or("").to_string(), cert));
                }
            }
        }
        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pow_and_handles() {
        let kp = Keypair::new(SECP256K1, &mut secp256k1::rand::thread_rng());
        let ev = sign_event_pow(&kp, DIR_KIND, vec![json!(["d", "x"])], "{}", 12);
        assert!(verify_event(&ev));
        assert!(leading_zero_bits(&hex::decode(ev["id"].as_str().unwrap()).unwrap()) >= 12);
        assert!(valid_username("minh_anh99") && !valid_username("Ab") && !valid_username("_x1") && !valid_username("có_dấu"));
        let p = PeerId([9; 32]);
        assert_eq!(handle_tag(&p).len(), 6);
    }

    #[test]
    fn group_listings_need_a_proof_to_be_verified() {
        use crate::devices::Signer;
        use crate::group::{self, GroupOp, Payload, Role, Signed};
        let owner = Identity::generate();
        let admin = Identity::generate();
        let mallory = Identity::generate();
        let (st, create_op) = group::create(&Signer::primary(&owner), 1, "Hội yêu mèo", vec![admin.peer_id()], 0).unwrap();
        let promote = Signed::new(&Signer::primary(&owner), st.gid, 2, Payload::Op(GroupOp::SetRole { peer: admin.peer_id(), role: Role::Admin }));
        let st = group::GroupState::fold(st.gid, vec![create_op, promote]).unwrap();
        let gid = hex::encode(st.gid);
        let now = crate::util::now_ms();
        // the content `publish_group` would build for signer `id`
        let listing = |id: &Identity, gid: &str, title: &str, proof: Option<Vec<u8>>| {
            let (ts, expires) = (now, now + USERNAME_TTL_MS);
            let mut c = json!({"gid": gid, "title": title, "about": "", "members": 2, "kind": 0, "tag": "abcdef",
                               "ts": ts, "expires": expires, "admin": id.peer_id().to_base32()});
            let msg = format!("lumora-group-v1|meo|{gid}|{ts}|{expires}");
            c["sig"] = json!(hex::encode(id.sign(msg.as_bytes())));
            if let Some(p) = proof {
                c["proof"] = json!(data_encoding::BASE64.encode(&p));
                c["sig2"] = json!(hex::encode(id.sign(group_listing_msg_v2("meo", &c).as_bytes())));
            }
            c
        };
        let real = listing(&admin, &gid, "Hội yêu mèo", group::admin_proof(&st, &admin.peer_id()));
        assert_eq!(check_group_listing("meo", &real, now), Some(true));
        // older version without proof: valid but unverified
        let legacy = listing(&owner, &gid, "Hội yêu mèo", None);
        assert_eq!(check_group_listing("meo", &legacy, now), Some(false));
        // Mallory lists the real gid under her own key: a v1 signature is all she can make
        let fake = listing(&mallory, &gid, "Hội yêu mèo (chính thức)", None);
        assert_eq!(check_group_listing("meo", &fake, now), Some(false));
        // ...and borrowing the real proof doesn't help (it names someone else as admin)
        let stolen = listing(&mallory, &gid, "Hội yêu mèo", group::admin_proof(&st, &admin.peer_id()));
        assert_eq!(check_group_listing("meo", &stolen, now), None);
        // changing what is shown breaks sig2; a proof without sig2 is a forgery
        let mut edited = real.clone();
        edited["title"] = json!("Bán hàng giá rẻ");
        assert_eq!(check_group_listing("meo", &edited, now), None);
        let mut half = real.clone();
        half.as_object_mut().unwrap().remove("sig2");
        assert_eq!(check_group_listing("meo", &half, now), None);
        // expired, wrong handle
        assert_eq!(check_group_listing("meo", &real, now + USERNAME_TTL_MS + 1), None);
        assert_eq!(check_group_listing("cho", &real, now), None);

        // ranking: the verified listing wins its gid and comes first; others follow
        let other_gid = hex::encode([5u8; 16]);
        let mut unrelated = listing(&mallory, &other_gid, "Mèo khác", None);
        unrelated["verified"] = json!(false);
        let mut f2 = fake.clone();
        f2["verified"] = json!(false);
        f2["ts"] = json!(now + 1000); // newer, but unverified
        let mut r2 = real.clone();
        r2["verified"] = json!(true);
        let ranked = rank_group_listings(vec![unrelated, f2, r2]);
        assert_eq!(ranked.len(), 2);
        assert_eq!(ranked[0]["gid"], json!(gid));
        assert_eq!(ranked[0]["verified"], json!(true));
        assert_eq!(ranked[0]["title"], json!("Hội yêu mèo"));
        assert!(ranked[0].get("proof").is_none() && ranked[0].get("sig2").is_none());
        assert_eq!(ranked[1]["verified"], json!(false));
    }

    /// #20: a hostile relay can't make a query buffer without bound.
    #[test]
    fn query_results_are_capped() {
        let mut evs = vec![];
        let mut bytes = 0;
        let mut taken = 0;
        for _ in 0..10_000 {
            if !take_event(&mut evs, &mut bytes, 100, json!({})) {
                break;
            }
            taken += 1;
        }
        assert_eq!(taken, QUERY_MAX_EVENTS);
        let (mut evs, mut bytes) = (vec![], 0);
        assert!(!take_event(&mut evs, &mut bytes, QUERY_MAX_BYTES + 1, json!({})));
        assert_ne!(friend_inbox_tag(&[1; 32], 10), friend_inbox_tag(&[1; 32], 11), "friends' tags rotate daily");
        assert_ne!(friend_inbox_tag(&[1; 32], 10), friend_inbox_tag(&[2; 32], 10));
    }

    #[test]
    fn event_sign_verify() {
        let kp = Keypair::new(SECP256K1, &mut secp256k1::rand::thread_rng());
        let ev = sign_event(&kp, 1, json!([["p", "ab"]]), "hello");
        assert!(verify_event(&ev));
        let mut bad = ev.clone();
        bad["content"] = json!("tampered");
        assert!(!verify_event(&bad));
    }
}
