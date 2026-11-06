//! Linking a new device into an existing account (multi-device §2).
//!
//! * The **new device** (N) calls `link_start`: it shows a QR (`lumora://link/…` with its
//!   device key, a one-time secret and where it can be dialed) and a 12-digit code. It
//!   advertises the code's rendezvous id (first 6 digits only) on the LAN and Nostr.
//! * The **existing device** (E, the primary) calls `link_scan` with the QR or the code,
//!   dials N (TLS pins N's key) and proves it knows the secret, bound to the TLS channel:
//!   QR → keyed BLAKE3 proof; code → SPAKE2 with all 12 digits + key confirmation (one
//!   guess per session; the code rotates after 3 failures).
//! * Invitation (the other direction, what the app uses): E calls `link_invite` and shows
//!   the QR / code; N (started with `link_pending`) calls `link_scan` and dials E. The same
//!   proofs run with the roles of dialer and responder swapped; both then describe
//!   themselves (`LinkInfo`), E's app gets `link_request` and its user approves.
//! * N describes itself (`LinkInfo`); E's user approves (`link_approve`): E issues a device
//!   certificate, signs a new device list and sends `LinkAccept`. N stores the account and
//!   asks to be restarted (`link_state: restart`); after the restart it is a device of the
//!   account and pulls the account state + chosen history from E (node/sync.rs).
//! * IP privacy: the device showing the QR / code reveals its addresses only to a device
//!   that proved the QR secret / code first — over sealed signaling mail (`Ext LINK_PRE`:
//!   QR proof, or SPAKE2 + confirmation; one guess per attempt, counted with the others).
//!   The scanning side doesn't dial a candidate found by rendezvous (unauthenticated)
//!   before that either; only LAN beacon candidates are dialed directly (LAN addresses,
//!   no signaling there). Pre-authentication attempts are rate-limited.

use super::devices::{caps_for, default_device_kind};
use super::*;
use crate::devices::{self as dv, DeviceCert, DeviceEntry, LinkQr, SignedDeviceList};
use crate::proto::ext;
use serde_bytes::ByteBuf;
use std::collections::HashSet;

const LINK_TTL_MS: u64 = 10 * 60_000;

/// Addresses that may go into the public Nostr link beacon: LAN only — never public
/// (global / carrier-grade NAT) addresses nor relay placeholders.
fn beacon_addrs(addrs: Vec<SocketAddr>) -> Vec<SocketAddr> {
    addrs
        .into_iter()
        .filter(|a| {
            let ip = crate::util::canon(*a).ip();
            !net::magicsock::is_relay_addr(a) && !crate::util::is_global_ip(&ip) && !crate::util::is_cgnat(&ip)
        })
        .collect()
}
const MAX_CODE_FAILURES: u32 = 3;
const SCAN_TIMEOUT: Duration = Duration::from_secs(25);
/// Each step of the pre-authentication over signaling waits this long for the answer.
const PRE_STEP_WAIT: Duration = Duration::from_secs(8);
/// Pre-authentication attempts a device showing a code / QR accepts per minute.
const MAX_PRE_PER_MIN: u32 = 10;

/// `Ext LINK_PRE` stages.
const PRE_QR: u8 = 1;
const PRE_QR_OK: u8 = 2;
const PRE_PAKE_A: u8 = 3;
const PRE_PAKE_B: u8 = 4;
const PRE_CONFIRM: u8 = 5;
const PRE_OK: u8 = 6;
const PRE_FAIL: u8 = 7;

/// `Ext LINK_PRE` (sealed signaling mail only).
#[derive(Serialize, Deserialize, Default, Clone, Debug)]
pub(super) struct LinkPreMsg {
    #[serde(default)]
    stage: u8,
    /// session nonce chosen by the scanning side
    #[serde(with = "serde_bytes", default)]
    nonce: Vec<u8>,
    /// SPAKE2 message (stages 3, 4) or QR proof (1, 2)
    #[serde(with = "serde_bytes", default)]
    msg: Vec<u8>,
    /// key confirmation (4, 5, 6)
    #[serde(with = "serde_bytes", default)]
    mac: Vec<u8>,
}

#[derive(Serialize, Deserialize, Default)]
struct LinkHelloMsg {
    #[serde(with = "serde_bytes")]
    proof: Vec<u8>,
}

#[derive(Serialize, Deserialize, Default)]
struct LinkPakeMsg {
    #[serde(with = "serde_bytes")]
    msg: Vec<u8>,
}

#[derive(Serialize, Deserialize, Default)]
struct LinkConfirmMsg {
    #[serde(with = "serde_bytes")]
    mac: Vec<u8>,
}

#[derive(Serialize, Deserialize, Default, Clone, Debug)]
pub struct LinkInfoMsg {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub kind: u8,
    #[serde(default)]
    pub os: String,
    #[serde(default)]
    pub app: String,
    /// The new device's acceptance signature for the account it joins (goes into its
    /// device-list entry, so friends can tell it really is a device of that account).
    #[serde(default, with = "serde_bytes")]
    pub accept: Vec<u8>,
}

#[derive(Serialize, Deserialize, Default)]
struct LinkAcceptMsg {
    cert: ByteBuf,
    list: ByteBuf,
    #[serde(default)]
    history: String,
    #[serde(default)]
    since_ms: u64,
    #[serde(default)]
    media: bool,
}

#[derive(Serialize, Deserialize, Default)]
struct LinkRejectMsg {
    #[serde(default)]
    reason: String,
}

/// Rendezvous announcement on Nostr (no secret). Anyone can read it, so `a` carries only
/// LAN addresses (see [`beacon_addrs`]); older builds may still send public ones.
#[derive(Serialize, Deserialize)]
struct NostrBeacon {
    d: String,
    #[serde(default)]
    a: Vec<SocketAddr>,
    #[serde(default)]
    r: Vec<String>,
}

/// New-device side: what we show and who proved they saw it.
struct Offer {
    secret: [u8; 32],
    digits: String,
    expires: u64,
    failures: u32,
    name: String,
    kind: u8,
    pake: HashMap<PeerId, [u8; 32]>,
    authed: HashSet<PeerId>,
    accepted: bool,
    /// shown by the existing device (an invitation): the new device dials us
    invite: bool,
    /// devices that proved the QR / code over signaling: they may learn our addresses
    pre_authed: HashSet<PeerId>,
    /// code path, waiting for the other side's confirmation: (key, nonce)
    pre_keys: HashMap<PeerId, ([u8; 32], Vec<u8>)>,
}

/// Existing-device side: one link attempt with a candidate new device.
struct Scan {
    qr: bool,
    pake: Option<spake2::Spake2<spake2::Ed25519Group>>,
    key: Option<[u8; 32]>,
    authed: bool,
    info: Option<LinkInfoMsg>,
    path: PathKind,
    waiter: Option<oneshot::Sender<std::result::Result<LinkInfoMsg, String>>>,
    /// invitation: a new device that proved our code and waits for approval
    incoming: bool,
}

#[derive(Default)]
pub struct LinkState {
    offer: Mutex<Option<Offer>>,
    scans: Mutex<HashMap<PeerId, Scan>>,
    /// Scanning side: pre-authentication answers awaited, per device.
    pre_waits: Mutex<HashMap<PeerId, mpsc::Sender<LinkPreMsg>>>,
    /// Pre-authentication attempts this minute (rate limit).
    pre_window: Mutex<Option<(Instant, u32)>>,
}

fn exporter(c: &quinn::Connection) -> [u8; 32] {
    let mut out = [0u8; 32];
    let _ = c.export_keying_material(&mut out, b"lumora-link", b"");
    out
}

fn fmt_code(d: &str) -> String {
    format!("{}-{}-{}", &d[..4], &d[4..8], &d[8..])
}

fn history_since(history: &str, now: u64) -> u64 {
    const M: u64 = 30 * 86_400_000;
    match history {
        "all" => 0,
        "1m" => now.saturating_sub(M),
        "3m" => now.saturating_sub(3 * M),
        "6m" => now.saturating_sub(6 * M),
        "12m" => now.saturating_sub(12 * M),
        _ => now, // "none": account state only
    }
}

impl Node {
    // ================================================================ new device (N)

    /// Show a link QR + code on this (fresh) device.
    pub async fn link_start(self: &Arc<Self>, name: Option<&str>) -> Result<Value> {
        anyhow::ensure!(!self.is_bot() && self.cfg.bot_token.is_none(), crate::i18n::user_err("err.bot_single_device"));
        anyhow::ensure!(self.is_primary() && self.store.is_fresh(), crate::i18n::user_err("err.link_not_fresh"));
        let name: String = name
            .map(|n| n.trim().to_string())
            .filter(|n| !n.is_empty())
            .or_else(|| self.store.kv_get("device.name").and_then(|v| String::from_utf8(v).ok()))
            .unwrap_or_else(super::devices::default_device_name)
            .chars()
            .take(32)
            .collect();
        let _ = self.store.kv_set("device.name", name.as_bytes());
        let digits = dv::parse_code(&dv::new_code())?;
        let secret: [u8; 32] = crate::crypto::random_bytes();
        let expires = now_ms() + LINK_TTL_MS;
        let kind = default_device_kind();
        *self.link.offer.lock() = Some(Offer {
            secret,
            digits: digits.clone(),
            expires,
            failures: 0,
            name: name.clone(),
            kind,
            pake: HashMap::new(),
            authed: HashSet::new(),
            accepted: false,
            invite: false,
            pre_authed: HashSet::new(),
            pre_keys: HashMap::new(),
        });
        let info = self.ensure_info().await;
        let mut addrs: Vec<SocketAddr> = info.addrs.iter().copied().filter(|a| !net::magicsock::is_relay_addr(a)).collect();
        addrs = net::order_candidates(addrs);
        addrs.truncate(4);
        let relays: Vec<String> = info.relays.iter().take(2).cloned().collect();
        let qr = LinkQr { v: 1, d: self.device, s: secret.to_vec(), a: addrs.clone(), r: relays.clone(), n: name.clone(), k: kind, e: expires, i: false };
        self.link_advertise(&digits, addrs, relays);
        // strangers' sealed mail (the other device's pre-authentication) must reach us
        self.refresh_nostr_inboxes(false);
        self.emit("link_state", json!({"state": "waiting"}));
        Ok(json!({"qr": qr.to_uri(), "code": fmt_code(&digits), "expires": expires, "device": self.device.to_base32(), "name": name}))
    }

    /// Main device: invite a new device — show this QR / code on it, then approve.
    pub async fn link_invite(self: &Arc<Self>) -> Result<Value> {
        anyhow::ensure!(!self.is_bot() && self.cfg.bot_token.is_none(), crate::i18n::user_err("err.bot_single_device"));
        anyhow::ensure!(!self.cfg.link_pending, crate::i18n::user_err("err.link_failed").detail("this device is waiting to be linked"));
        anyhow::ensure!(self.is_primary(), crate::i18n::user_err("err.link_on_primary"));
        let cur = self.own_list().map(|b| b.devices.len()).unwrap_or(1);
        anyhow::ensure!(cur < dv::MAX_DEVICES, crate::i18n::user_err("err.too_many_devices").with("max", dv::MAX_DEVICES));
        self.ensure_own_list();
        let entry = self.own_list().and_then(|b| b.devices.into_iter().find(|e| e.device == self.device));
        let name = entry.as_ref().map(|e| e.name.clone()).unwrap_or_else(super::devices::default_device_name);
        let kind = entry.map(|e| e.kind).unwrap_or_else(default_device_kind);
        let digits = dv::parse_code(&dv::new_code())?;
        let secret: [u8; 32] = crate::crypto::random_bytes();
        let expires = now_ms() + LINK_TTL_MS;
        *self.link.offer.lock() = Some(Offer {
            secret,
            digits: digits.clone(),
            expires,
            failures: 0,
            name: name.clone(),
            kind,
            pake: HashMap::new(),
            authed: HashSet::new(),
            accepted: false,
            invite: true,
            pre_authed: HashSet::new(),
            pre_keys: HashMap::new(),
        });
        let info = self.ensure_info().await;
        let mut addrs: Vec<SocketAddr> = info.addrs.iter().copied().filter(|a| !net::magicsock::is_relay_addr(a)).collect();
        addrs = net::order_candidates(addrs);
        addrs.truncate(4);
        let relays: Vec<String> = info.relays.iter().take(2).cloned().collect();
        let qr = LinkQr { v: 1, d: self.device, s: secret.to_vec(), a: addrs.clone(), r: relays.clone(), n: name.clone(), k: kind, e: expires, i: true };
        self.link_advertise(&digits, addrs, relays);
        self.refresh_nostr_inboxes(false);
        self.emit("link_state", json!({"state": "waiting", "invite": true}));
        Ok(json!({"qr": qr.to_uri(), "code": fmt_code(&digits), "expires": expires, "device": self.device.to_base32(), "name": name}))
    }

    /// IP privacy: only the device being linked learns this one's addresses — one that
    /// proved the QR secret / code over signaling (`LINK_PRE`) or over a connection it
    /// opened itself, while the offer lives; and the devices this one is linking with
    /// (`scans`: it chose them). Never everyone while a code is shown.
    pub(crate) fn link_reveals_addrs_to(&self, dev: &PeerId) -> bool {
        let authed = self
            .link
            .offer
            .lock()
            .as_ref()
            .map(|o| !o.accepted && o.expires > now_ms() && (o.pre_authed.contains(dev) || o.authed.contains(dev)))
            .unwrap_or(false);
        authed || self.link.scans.lock().contains_key(dev)
    }

    /// A link offer / invitation is shown right now.
    pub(crate) fn link_offer_live(&self) -> bool {
        self.link.offer.lock().as_ref().map(|o| !o.accepted && o.expires > now_ms()).unwrap_or(false) || !self.link.pre_waits.lock().is_empty()
    }

    /// Advertise the code's rendezvous id (LAN beacon + Nostr) while the offer lives.
    /// The Nostr beacon is public: no public addresses in it (only LAN ones); beyond the
    /// LAN the other device reaches this one through signaling.
    fn link_advertise(self: &Arc<Self>, digits: &str, addrs: Vec<SocketAddr>, relays: Vec<String>) {
        let addrs = beacon_addrs(addrs);
        let rv = dv::code_rendezvous(digits);
        *self.net.lan.link_beacon.write() = Some(rv[..8].try_into().unwrap_or([0; 8]));
        let me = self.clone();
        let tag = hex::encode(rv);
        let content = serde_json::to_string(&NostrBeacon { d: self.device.to_base32(), a: addrs, r: relays }).unwrap_or_default();
        let digits = digits.to_string();
        tokio::spawn(async move {
            loop {
                let live = me.link.offer.lock().as_ref().map(|o| o.digits == digits && !o.accepted && o.expires > now_ms()).unwrap_or(false);
                if !live {
                    break;
                }
                if let Some(p) = me.net.nostr.read().clone() {
                    p.post_link_beacon(&tag, &content);
                }
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        });
    }

    pub fn link_cancel(&self) {
        *self.link.offer.lock() = None;
        *self.net.lan.link_beacon.write() = None;
        let scans: Vec<PeerId> = self.link.scans.lock().drain().map(|(k, _)| k).collect();
        for d in scans {
            self.send_now_dev(&d, proto::ext(ext::LINK_REJECT, &LinkRejectMsg { reason: "cancelled".into() }));
        }
        self.emit("link_state", json!({"state": "cancelled"}));
    }

    fn link_fail(&self, pc: &Arc<PeerConn>, reason: &str) {
        let _ = pc.ctl.try_send(proto::ext(ext::LINK_REJECT, &LinkRejectMsg { reason: reason.into() }));
        if let Some(o) = self.link.offer.lock().as_mut() {
            o.pake.remove(&pc.peer);
        }
        self.link_failure(reason, true);
        // the connection stays (the other side may try again; each attempt is counted)
    }

    /// One failed (or, `counted` = false, one more possible) guess at the code: after
    /// [`MAX_CODE_FAILURES`] a new code (the old one is useless to an attacker).
    fn link_failure(&self, reason: &str, counted: bool) {
        let rotated = {
            let mut g = self.link.offer.lock();
            match g.as_mut() {
                Some(o) => {
                    if counted {
                        o.failures += 1;
                    }
                    if o.failures >= MAX_CODE_FAILURES {
                        o.failures = 0;
                        o.digits = dv::parse_code(&dv::new_code()).unwrap_or_default();
                        o.pre_keys.clear();
                        Some(o.digits.clone())
                    } else {
                        None
                    }
                }
                None => None,
            }
        };
        if counted {
            self.emit("link_state", json!({"state": "failed", "reason": reason}));
        }
        if let Some(d) = rotated {
            // too many wrong guesses: a new code (the old one is useless to an attacker)
            if let Some(me) = self.self_ref.lock().as_ref().and_then(|w| w.upgrade()) {
                let info = me.net.info.read().clone();
                me.link_advertise(&d, info.addrs.clone(), info.relays.clone());
            }
            self.emit("link_state", json!({"state": "code_rotated", "code": fmt_code(&d)}));
        }
    }

    fn send_link_info(&self, pc: &Arc<PeerConn>) {
        // the offer's (new device showing a QR) or, scanning an invitation, our own
        let (name, kind) = self.link.offer.lock().as_ref().map(|o| (o.name.clone(), o.kind)).unwrap_or_else(|| {
            let n = self.store.kv_get("device.name").and_then(|v| String::from_utf8(v).ok()).filter(|n| !n.is_empty());
            (n.unwrap_or_else(super::devices::default_device_name), default_device_kind())
        });
        // (the account we'd join is the other side's: our acceptance goes into our entry)
        let accept = dv::sign_accept(&self.id, &pc.account);
        let info = LinkInfoMsg { name, kind, os: std::env::consts::OS.into(), app: env!("CARGO_PKG_VERSION").into(), accept };
        let _ = pc.ctl.try_send(proto::ext(ext::LINK_INFO, &info));
        self.emit("link_state", json!({"state": "awaiting_approval"}));
    }

    // ================================================================ existing device (E)

    /// Dial the new device from its QR, or find it by its code; authenticate and return
    /// what it says about itself (shown on the approval sheet).
    pub async fn link_scan(self: &Arc<Self>, qr: Option<&str>, code: Option<&str>, name: Option<&str>) -> Result<Value> {
        anyhow::ensure!(!self.is_bot(), crate::i18n::user_err("err.bot_single_device"));
        anyhow::ensure!(self.is_primary(), crate::i18n::user_err("err.link_on_primary"));
        // a new device (started to be linked) scans an invitation; any other device scans a
        // new device's QR
        let joining = self.cfg.link_pending;
        if joining {
            anyhow::ensure!(self.store.is_fresh(), crate::i18n::user_err("err.link_not_fresh"));
            if let Some(n) = name.map(str::trim).filter(|n| !n.is_empty()) {
                let n: String = n.chars().take(32).collect();
                let _ = self.store.kv_set("device.name", n.as_bytes());
            }
        }
        // a pasted code may come with the link text around it
        let qr = qr.map(|q| q.trim()).filter(|q| !q.is_empty());
        let (qr, code) = match (qr, code) {
            (Some(q), c) if !q.starts_with(dv::LINK_QR_PREFIX) && q.chars().filter(|c| c.is_ascii_digit()).count() == 12 => (None, Some(q).or(c)),
            other => other,
        };
        if let Some(q) = qr {
            let q = LinkQr::parse(q).map_err(|e| crate::i18n::user_err("err.link_code_invalid").detail(e))?;
            anyhow::ensure!(q.e > now_ms(), crate::i18n::user_err("err.link_code_expired"));
            anyhow::ensure!(q.i == joining, crate::i18n::user_err("err.link_code_invalid").detail(if joining { "not an invitation" } else { "an invitation: scan it on the new device" }));
            let already = q.d == self.device || self.own_list().map(|b| b.is_active(&q.d)).unwrap_or(false);
            anyhow::ensure!(!already, crate::i18n::user_err("err.link_already"));
            let secret = q.s.clone();
            // directly at the addresses in the QR (it was scanned: authentic); else the
            // other device must first see the QR proof over signaling before it answers
            let (pc, rx) = match self.link_open(q.d, q.a.clone(), true, false).await {
                Ok(x) => x,
                Err(_) => {
                    // (the QR is authentic, so dialing it is fine even if the proof can't get
                    // through — e.g. no signaling at all: the LAN path still finds it)
                    let pre = self.link_pre_qr(q.d, &secret).await;
                    match self.link_open(q.d, vec![], true, true).await {
                        Ok(x) => x,
                        Err(e) => return Err(pre.err().unwrap_or(e)),
                    }
                }
            };
            let proof = dv::qr_proof(&secret, &q.d, &self.device, &self.me, &exporter(&pc.conn));
            let _ = pc.ctl.try_send(proto::ext(ext::LINK_HELLO, &LinkHelloMsg { proof: proof.to_vec() }));
            return self.link_wait(pc, rx).await;
        }
        if joining && code.map(|c| c.trim().is_empty()).unwrap_or(true) {
            bail!(crate::i18n::user_err("err.link_code_invalid"));
        }
        let digits = dv::parse_code(code.unwrap_or("")).map_err(|e| crate::i18n::user_err("err.link_code_invalid").detail(e))?;
        let rv = dv::code_rendezvous(&digits);
        let rv8: [u8; 8] = rv[..8].try_into().unwrap_or([0; 8]);
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut tried: HashSet<PeerId> = HashSet::new();
        let mut last_err: anyhow::Error = crate::i18n::user_err("err.link_not_found").into();
        let mut answered = false; // some candidate ran the PAKE and the code didn't match
        while Instant::now() < deadline {
            // candidates: LAN beacons, then Nostr (both unauthenticated — the PAKE decides)
            let mut cands: Vec<(PeerId, Vec<SocketAddr>, bool)> = self.net.lan.link_candidates(&rv8).into_iter().map(|(d, a)| (d, a, true)).collect();
            if cands.iter().all(|(p, _, _)| tried.contains(p)) {
                let pool = self.net.nostr.read().clone();
                if let Some(pool) = pool {
                    for ev in pool.watch_link_beacons(&hex::encode(rv), Duration::from_secs(6)).await {
                        if let Some(b) = ev["content"].as_str().and_then(|c| serde_json::from_str::<NostrBeacon>(c).ok()) {
                            if let Ok(d) = PeerId::from_str_any(&b.d) {
                                cands.push((d, b.a, false));
                            }
                        }
                    }
                } else {
                    tokio::time::sleep(Duration::from_millis(500)).await;
                }
            }
            let fresh = cands.iter().any(|(d, _, _)| *d != self.device && !tried.contains(d));
            if answered && !fresh {
                break; // wrong code: don't wait for other devices that will never show up
            }
            for (dev, addrs, lan) in cands {
                if dev == self.device || !tried.insert(dev) {
                    continue;
                }
                // A rendezvous candidate is unauthenticated: beyond the LAN (where we dial
                // its LAN addresses directly) it must first prove the code over signaling —
                // only then is it dialed (and only then does it answer us with addresses).
                if !lan {
                    if let Err(e) = self.link_pre_code(dev, &digits).await {
                        answered |= e.to_string().contains("auth");
                        last_err = e;
                        continue;
                    }
                }
                let (st, msg) = dv::pake_start(&digits);
                match self.link_open(dev, addrs, false, !lan).await {
                    Ok((pc, rx)) => {
                        if let Some(s) = self.link.scans.lock().get_mut(&dev) {
                            s.pake = Some(st);
                        }
                        let _ = pc.ctl.try_send(proto::ext(ext::LINK_PAKE, &LinkPakeMsg { msg }));
                        match self.link_wait(pc, rx).await {
                            Ok(v) => return Ok(v),
                            Err(e) => {
                                answered = true;
                                last_err = e;
                            }
                        }
                    }
                    Err(e) => last_err = e,
                }
            }
        }
        Err(last_err)
    }

    /// Connect to the device being linked: directly at `addrs`, else (`signaled`: it has
    /// proven itself, see `link_pre_*`) through signaling like any connection.
    async fn link_open(
        self: &Arc<Self>,
        dev: PeerId,
        addrs: Vec<SocketAddr>,
        qr: bool,
        signaled: bool,
    ) -> Result<(Arc<PeerConn>, oneshot::Receiver<std::result::Result<LinkInfoMsg, String>>)> {
        self.emit("link_state", json!({"state": "connecting", "device": dev.to_base32()}));
        let pc = match self.peer(&dev) {
            Some(c) => c,
            None => {
                // (+ where LAN discovery saw that very key: TLS pins it)
                let mut addrs = addrs;
                addrs.extend(self.net.lan.get(&dev));
                let direct = if addrs.is_empty() {
                    None
                } else {
                    let lan = addrs.iter().any(|a| !crate::util::is_global_ip(&a.ip()));
                    self.net.dial_direct(dev, net::order_candidates(addrs), Duration::from_secs(5)).await.ok().map(|c| (c, if lan { PathKind::Lan } else { PathKind::Direct }))
                };
                match direct {
                    Some((c, path)) => self.clone().setup_conn(c, path, self.device, None).await?,
                    None if signaled => {
                        // (a scan in progress: its answer-side dial-back is welcome)
                        self.link.scans.lock().entry(dev).or_insert_with(|| Scan { qr, pake: None, key: None, authed: false, info: None, path: PathKind::Relay, waiter: None, incoming: false });
                        let r = self.connect(dev).await;
                        if r.is_err() {
                            self.link.scans.lock().remove(&dev);
                        }
                        r.map_err(|_| crate::i18n::user_err("err.link_not_found"))?
                    }
                    None => bail!(crate::i18n::user_err("err.link_not_found")),
                }
            }
        };
        let (tx, rx) = oneshot::channel();
        self.link.scans.lock().insert(dev, Scan { qr, pake: None, key: None, authed: false, info: None, path: pc.path, waiter: Some(tx), incoming: false });
        self.emit("link_state", json!({"state": "verifying", "device": dev.to_base32()}));
        Ok((pc, rx))
    }

    async fn link_wait(&self, pc: Arc<PeerConn>, rx: oneshot::Receiver<std::result::Result<LinkInfoMsg, String>>) -> Result<Value> {
        let r = tokio::time::timeout(SCAN_TIMEOUT, rx).await;
        let info = match r {
            Ok(Ok(Ok(i))) => i,
            Ok(Ok(Err(reason))) => {
                self.link.scans.lock().remove(&pc.peer);
                bail!(crate::i18n::user_err(if reason == "auth" { "err.link_code_wrong" } else { "err.link_failed" }).detail(reason));
            }
            _ => {
                self.link.scans.lock().remove(&pc.peer);
                bail!(crate::i18n::user_err("err.link_failed").detail("timeout"));
            }
        };
        let mut v = json!({
            "device": pc.peer.to_base32(), "name": info.name, "kind": info.kind, "os": info.os, "app": info.app,
            "path": pc.path,
        });
        if self.cfg.link_pending {
            // new device that scanned an invitation: now the main device's user approves
            v["state"] = json!("awaiting_approval");
            self.emit("link_state", json!({"state": "awaiting_approval", "device": pc.peer.to_base32(), "name": info.name}));
        } else {
            self.emit("link_request", v.clone());
        }
        Ok(v)
    }

    /// Approve the new device: certificate + new device list + history choice.
    pub async fn link_approve(self: &Arc<Self>, dev: &PeerId, history: &str, since_ms: Option<u64>, media: bool) -> Result<Value> {
        anyhow::ensure!(self.is_primary(), crate::i18n::user_err("err.link_on_primary"));
        let (info, path) = {
            let s = self.link.scans.lock();
            let sc = s.get(dev).ok_or_else(|| crate::i18n::user_err("err.link_failed").detail("no pending link"))?;
            anyhow::ensure!(sc.authed || sc.qr, crate::i18n::user_err("err.link_failed").detail("not verified"));
            (sc.info.clone().ok_or_else(|| crate::i18n::user_err("err.link_failed").detail("no device info"))?, sc.path)
        };
        let _ = path;
        let pc = self.peer(dev).ok_or_else(|| crate::i18n::user_err("err.link_failed").detail("connection lost"))?;
        let cur = self.own_list().map(|b| b.devices.len()).unwrap_or(1);
        anyhow::ensure!(cur < dv::MAX_DEVICES, crate::i18n::user_err("err.too_many_devices").with("max", dv::MAX_DEVICES));
        let kind = if (1..=4).contains(&info.kind) { info.kind } else { dv::KIND_CLI };
        let caps = caps_for(kind);
        let now = now_ms();
        let cert = DeviceCert::issue(&self.id, *dev, now, caps);
        let name: String = info.name.chars().take(32).collect();
        let d = *dev;
        // its acceptance (from its LinkInfo) goes into its entry: friends bind it only so
        let proof = if dv::verify_accept(&self.me, dev, &info.accept) { info.accept.clone() } else { vec![] };
        self.publish_own_list(|b| {
            b.revoked.retain(|r| r.device != d);
            if !b.is_active(&d) {
                b.devices.push(DeviceEntry { proof, ..DeviceEntry::new(d, name, kind, caps, now) });
            }
        })?;
        // it gets everything before this point with the bootstrap/history stream
        self.store.sync_peer_set_sent(dev, self.store.sync_head())?;
        let since = since_ms.unwrap_or_else(|| history_since(history, now));
        let (_, list) = self.store.device_list_get(&self.me).ok_or_else(|| anyhow!("device list missing"))?;
        let acc = LinkAcceptMsg { cert: ByteBuf::from(cert.encode()), list: ByteBuf::from(list), history: history.into(), since_ms: since, media };
        pc.ctl.send(proto::ext(ext::LINK_ACCEPT, &acc)).await.map_err(|_| crate::i18n::user_err("err.link_failed").detail("connection lost"))?;
        self.link.scans.lock().remove(dev);
        let invite = self.link.offer.lock().as_ref().map(|o| o.invite).unwrap_or(false);
        if invite {
            // one invitation, one device
            *self.link.offer.lock() = None;
            *self.net.lan.link_beacon.write() = None;
        }
        self.emit("link_state", json!({"state": "approved", "device": dev.to_base32()}));
        Ok(self.devices_json())
    }

    pub fn link_reject(&self, dev: &PeerId) -> Result<()> {
        self.link.scans.lock().remove(dev);
        self.send_now_dev(dev, proto::ext(ext::LINK_REJECT, &LinkRejectMsg { reason: "declined".into() }));
        if let Some(pc) = self.peer(dev) {
            if !pc.own && !self.store.is_friend(&pc.account) {
                let c = pc.conn.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    c.close(4u32.into(), b"link declined");
                });
            }
        }
        Ok(())
    }

    // ================================================================ protocol

    pub(super) async fn on_link_ext(self: &Arc<Self>, pc: &Arc<PeerConn>, kind: u16, body: &[u8]) -> Result<()> {
        let x = exporter(&pc.conn);
        match kind {
            // ---------------- N: someone proves they saw our QR
            ext::LINK_HELLO => {
                let m: LinkHelloMsg = proto::ext_body(body)?;
                let ok = {
                    let mut g = self.link.offer.lock();
                    let Some(o) = g.as_mut().filter(|o| o.expires > now_ms() && !o.accepted) else { return Ok(()) };
                    let want = dv::qr_proof(&o.secret, &self.device, &pc.peer, &pc.account, &x);
                    let ok = dv::ct_eq32(&want, &m.proof);
                    if ok {
                        o.authed.insert(pc.peer);
                    }
                    ok
                };
                if ok {
                    self.emit("link_state", json!({"state": "verifying", "device": pc.peer.to_base32()}));
                    self.link_responder_authed(pc);
                } else {
                    self.link_fail(pc, "auth");
                }
            }
            // ---------------- both: SPAKE2 messages
            ext::LINK_PAKE => {
                let m: LinkPakeMsg = proto::ext_body(body)?;
                // E side: our scan is waiting for N's answer
                let st = self.link.scans.lock().get_mut(&pc.peer).and_then(|s| s.pake.take());
                if let Some(st) = st {
                    match dv::pake_finish(st, &m.msg) {
                        Ok(key) => {
                            if let Some(s) = self.link.scans.lock().get_mut(&pc.peer) {
                                s.key = Some(key);
                            }
                            let mac = dv::pake_confirm(&key, 1, &pc.peer, &self.device, &x);
                            let _ = pc.ctl.try_send(proto::ext(ext::LINK_CONFIRM, &LinkConfirmMsg { mac: mac.to_vec() }));
                        }
                        Err(_) => self.scan_done(&pc.peer, Err("auth".into())),
                    }
                    return Ok(());
                }
                // N side: answer with ours
                let digits = match self.link.offer.lock().as_ref().filter(|o| o.expires > now_ms() && !o.accepted) {
                    Some(o) => o.digits.clone(),
                    None => return Ok(()),
                };
                let (st, mine) = dv::pake_start(&digits);
                match dv::pake_finish(st, &m.msg) {
                    Ok(key) => {
                        if let Some(o) = self.link.offer.lock().as_mut() {
                            o.pake.insert(pc.peer, key);
                        }
                        let _ = pc.ctl.try_send(proto::ext(ext::LINK_PAKE, &LinkPakeMsg { msg: mine }));
                    }
                    Err(_) => self.link_fail(pc, "auth"),
                }
            }
            ext::LINK_CONFIRM => {
                let m: LinkConfirmMsg = proto::ext_body(body)?;
                // E side: N's confirmation of the shared key
                let key = self.link.scans.lock().get(&pc.peer).and_then(|s| s.key);
                if let Some(key) = key {
                    let want = dv::pake_confirm(&key, 2, &pc.peer, &self.device, &x);
                    if dv::ct_eq32(&want, &m.mac) {
                        if let Some(s) = self.link.scans.lock().get_mut(&pc.peer) {
                            s.authed = true;
                        }
                    } else {
                        self.scan_done(&pc.peer, Err("auth".into()));
                    }
                    return Ok(());
                }
                // N side: E's confirmation
                let key = self.link.offer.lock().as_ref().and_then(|o| o.pake.get(&pc.peer).copied());
                let Some(key) = key else { return Ok(()) };
                let want = dv::pake_confirm(&key, 1, &self.device, &pc.peer, &x);
                if dv::ct_eq32(&want, &m.mac) {
                    if let Some(o) = self.link.offer.lock().as_mut() {
                        o.authed.insert(pc.peer);
                    }
                    let mac = dv::pake_confirm(&key, 2, &self.device, &pc.peer, &x);
                    let _ = pc.ctl.try_send(proto::ext(ext::LINK_CONFIRM, &LinkConfirmMsg { mac: mac.to_vec() }));
                    self.emit("link_state", json!({"state": "verifying", "device": pc.peer.to_base32()}));
                    self.link_responder_authed(pc);
                } else {
                    self.link_fail(pc, "auth");
                }
            }
            // ---------------- E: the new device describes itself
            ext::LINK_INFO => {
                let info: LinkInfoMsg = proto::ext_body(body)?;
                let (ok, incoming) = self.link.scans.lock().get(&pc.peer).map(|s| (s.qr || s.authed, s.incoming)).unwrap_or((false, false));
                if ok {
                    let info = LinkInfoMsg { name: info.name.chars().take(32).collect(), os: info.os.chars().take(32).collect(), app: info.app.chars().take(32).collect(), ..info };
                    if let Some(s) = self.link.scans.lock().get_mut(&pc.peer) {
                        if s.info.is_some() {
                            return Ok(()); // once per attempt
                        }
                        s.info = Some(info.clone());
                    }
                    if incoming {
                        // invitation: the new device that proved our code asks to join
                        self.emit("link_request", json!({
                            "device": pc.peer.to_base32(), "name": info.name, "kind": info.kind, "os": info.os, "app": info.app, "path": pc.path,
                        }));
                    } else {
                        if self.cfg.link_pending {
                            // we scanned an invitation: the main device verified us — describe
                            // ourselves so its user can approve
                            self.send_link_info(pc);
                        }
                        self.scan_done(&pc.peer, Ok(info));
                    }
                }
            }
            // ---------------- N: approved
            ext::LINK_ACCEPT => {
                let authed = self.link.offer.lock().as_ref().map(|o| o.authed.contains(&pc.peer) && !o.accepted && !o.invite).unwrap_or(false)
                    || (self.cfg.link_pending && self.link.scans.lock().get(&pc.peer).map(|s| !s.incoming && (s.qr || s.authed) && s.info.is_some()).unwrap_or(false));
                if !authed {
                    return Ok(());
                }
                let m: LinkAcceptMsg = proto::ext_body(body)?;
                self.link_accepted(pc, m)?;
            }
            ext::LINK_REJECT => {
                let m: LinkRejectMsg = proto::ext_body(body).unwrap_or_default();
                let waiting = self.link.scans.lock().get(&pc.peer).map(|s| (s.waiter.is_some(), s.incoming));
                if let Some((waiter, incoming)) = waiting {
                    let reason = if m.reason.is_empty() { "declined".to_string() } else { m.reason.clone() };
                    self.scan_done(&pc.peer, Err(reason.clone()));
                    self.link.scans.lock().remove(&pc.peer);
                    if !waiter && !incoming {
                        // the main device declined us after our scan returned
                        self.emit("link_state", json!({"state": "failed", "reason": reason}));
                    }
                } else if self.link.offer.lock().as_ref().map(|o| o.authed.contains(&pc.peer)).unwrap_or(false) {
                    self.emit("link_state", json!({"state": "failed", "reason": m.reason}));
                }
            }
            _ => {}
        }
        Ok(())
    }

    // ================================================================ pre-authentication
    //
    // Over sealed signaling mail, before either side reveals an address (#3 of the network
    // review): the scanning side proves the QR secret / code to the device showing it; only
    // then does that device answer its offers (and the scanning side dial it).

    fn pre_allowed(&self) -> bool {
        let mut w = self.link.pre_window.lock();
        let now = Instant::now();
        match w.as_mut() {
            Some((t, n)) if now.duration_since(*t) < Duration::from_secs(60) => {
                *n += 1;
                *n <= MAX_PRE_PER_MIN
            }
            _ => {
                *w = Some((now, 1));
                true
            }
        }
    }

    async fn pre_send(self: &Arc<Self>, dev: &PeerId, m: &LinkPreMsg) {
        self.send_sealed_signal(dev, &proto::ext(ext::LINK_PRE, m)).await;
    }

    /// Scanning side: open the answer channel for `dev` (our public inbox is listened to
    /// meanwhile — the answer comes from a stranger).
    async fn pre_begin(self: &Arc<Self>, dev: PeerId) -> mpsc::Receiver<LinkPreMsg> {
        let (tx, rx) = mpsc::channel(4);
        self.link.pre_waits.lock().insert(dev, tx);
        let before = self.net.nostr.read().as_ref().map(|p| p.inboxes().public.is_some()).unwrap_or(true);
        self.refresh_nostr_inboxes(false);
        if !before {
            // let the relays take the new subscription before the answer can come
            tokio::time::sleep(Duration::from_millis(800)).await;
        }
        rx
    }

    fn pre_end(&self, dev: &PeerId) {
        self.link.pre_waits.lock().remove(dev);
        self.refresh_nostr_inboxes(false);
    }

    async fn pre_wait(rx: &mut mpsc::Receiver<LinkPreMsg>, stage: u8) -> Result<LinkPreMsg> {
        loop {
            match tokio::time::timeout(PRE_STEP_WAIT, rx.recv()).await {
                Ok(Some(m)) if m.stage == stage => return Ok(m),
                Ok(Some(m)) if m.stage == PRE_FAIL => bail!(crate::i18n::user_err("err.link_code_wrong").detail("auth")),
                Ok(Some(_)) => continue,
                _ => bail!(crate::i18n::user_err("err.link_not_found").detail("no answer over signaling")),
            }
        }
    }

    /// Scanning side, QR: prove we saw the QR secret; the QR's device proves it too.
    async fn link_pre_qr(self: &Arc<Self>, dev: PeerId, secret: &[u8]) -> Result<()> {
        let nonce: [u8; 16] = crate::crypto::random_bytes();
        let mut rx = self.pre_begin(dev).await;
        let r = async {
            let msg = dv::pre_qr_proof(secret, &dev, &self.device, &nonce, b"req").to_vec();
            self.pre_send(&dev, &LinkPreMsg { stage: PRE_QR, nonce: nonce.to_vec(), msg, mac: vec![] }).await;
            let ok = Self::pre_wait(&mut rx, PRE_QR_OK).await?;
            let want = dv::pre_qr_proof(secret, &dev, &self.device, &nonce, b"ok");
            anyhow::ensure!(dv::ct_eq32(&want, &ok.msg), crate::i18n::user_err("err.link_failed").detail("auth"));
            Ok(())
        }
        .await;
        self.pre_end(&dev);
        r
    }

    /// Scanning side, code: SPAKE2 with all 12 digits over signaling, with confirmations
    /// both ways (one guess per attempt, counted by the other side).
    async fn link_pre_code(self: &Arc<Self>, dev: PeerId, digits: &str) -> Result<()> {
        let nonce: [u8; 16] = crate::crypto::random_bytes();
        let mut rx = self.pre_begin(dev).await;
        let r = async {
            let (st, msg) = dv::pake_start(digits);
            self.pre_send(&dev, &LinkPreMsg { stage: PRE_PAKE_A, nonce: nonce.to_vec(), msg, mac: vec![] }).await;
            let b = Self::pre_wait(&mut rx, PRE_PAKE_B).await?;
            let auth = || anyhow::Error::from(crate::i18n::user_err("err.link_code_wrong").detail("auth"));
            let key = dv::pake_finish(st, &b.msg).map_err(|_| auth())?;
            if !dv::ct_eq32(&dv::pre_pake_confirm(&key, 11, &dev, &self.device, &nonce), &b.mac) {
                return Err(auth());
            }
            let mac = dv::pre_pake_confirm(&key, 12, &dev, &self.device, &nonce).to_vec();
            self.pre_send(&dev, &LinkPreMsg { stage: PRE_CONFIRM, nonce: nonce.to_vec(), msg: vec![], mac }).await;
            let ok = Self::pre_wait(&mut rx, PRE_OK).await?;
            if !dv::ct_eq32(&dv::pre_pake_confirm(&key, 13, &dev, &self.device, &nonce), &ok.mac) {
                return Err(auth());
            }
            Ok(())
        }
        .await;
        self.pre_end(&dev);
        r
    }

    /// `Ext LINK_PRE` by sealed mail from device `dev`.
    pub(super) async fn on_link_pre_mail(self: &Arc<Self>, dev: PeerId, body: &[u8]) -> Result<()> {
        let m: LinkPreMsg = proto::ext_body(body)?;
        // scanning side: an answer we wait for
        if matches!(m.stage, PRE_QR_OK | PRE_PAKE_B | PRE_OK | PRE_FAIL) {
            let tx = self.link.pre_waits.lock().get(&dev).cloned();
            if let Some(tx) = tx {
                let _ = tx.try_send(m);
            }
            return Ok(());
        }
        anyhow::ensure!(m.nonce.len() == 16, "bad link nonce");
        let fail = LinkPreMsg { stage: PRE_FAIL, nonce: m.nonce.clone(), ..Default::default() };
        match m.stage {
            PRE_QR => {
                if !self.pre_allowed() {
                    return Ok(());
                }
                let ok = {
                    let mut g = self.link.offer.lock();
                    let Some(o) = g.as_mut().filter(|o| o.expires > now_ms() && !o.accepted) else { return Ok(()) };
                    let want = dv::pre_qr_proof(&o.secret, &self.device, &dev, &m.nonce, b"req");
                    let ok = dv::ct_eq32(&want, &m.msg);
                    if ok {
                        o.pre_authed.insert(dev);
                    }
                    ok.then(|| dv::pre_qr_proof(&o.secret, &self.device, &dev, &m.nonce, b"ok"))
                };
                match ok {
                    Some(proof) => self.pre_send(&dev, &LinkPreMsg { stage: PRE_QR_OK, nonce: m.nonce, msg: proof.to_vec(), mac: vec![] }).await,
                    None => self.pre_send(&dev, &fail).await,
                }
            }
            PRE_PAKE_A => {
                if !self.pre_allowed() {
                    return Ok(());
                }
                // each attempt is one guess: counted now, forgiven when it confirms
                self.link_failure("auth", false);
                let digits = {
                    let mut g = self.link.offer.lock();
                    let Some(o) = g.as_mut().filter(|o| o.expires > now_ms() && !o.accepted) else { return Ok(()) };
                    o.failures += 1;
                    o.digits.clone()
                };
                let (st, mine) = dv::pake_start(&digits);
                let Ok(key) = dv::pake_finish(st, &m.msg) else {
                    self.pre_send(&dev, &fail).await;
                    return Ok(());
                };
                if let Some(o) = self.link.offer.lock().as_mut() {
                    if o.pre_keys.len() >= 16 {
                        o.pre_keys.clear();
                    }
                    o.pre_keys.insert(dev, (key, m.nonce.clone()));
                }
                let mac = dv::pre_pake_confirm(&key, 11, &self.device, &dev, &m.nonce).to_vec();
                self.pre_send(&dev, &LinkPreMsg { stage: PRE_PAKE_B, nonce: m.nonce, msg: mine, mac }).await;
            }
            PRE_CONFIRM => {
                let ok = {
                    let mut g = self.link.offer.lock();
                    let Some(o) = g.as_mut().filter(|o| o.expires > now_ms() && !o.accepted) else { return Ok(()) };
                    let Some((key, nonce)) = o.pre_keys.remove(&dev).filter(|(_, n)| *n == m.nonce) else { return Ok(()) };
                    let ok = dv::ct_eq32(&dv::pre_pake_confirm(&key, 12, &self.device, &dev, &nonce), &m.mac);
                    if ok {
                        o.failures = o.failures.saturating_sub(1);
                        o.pre_authed.insert(dev);
                    }
                    ok.then(|| dv::pre_pake_confirm(&key, 13, &self.device, &dev, &nonce))
                };
                match ok {
                    Some(mac) => {
                        self.emit("link_state", json!({"state": "verifying", "device": dev.to_base32()}));
                        self.pre_send(&dev, &LinkPreMsg { stage: PRE_OK, nonce: m.nonce, msg: vec![], mac: mac.to_vec() }).await
                    }
                    None => {
                        self.pre_send(&dev, &fail).await;
                        self.link_failure("auth", false);
                    }
                }
            }
            _ => {}
        }
        Ok(())
    }

    /// Responder: the dialer proved it saw our QR / code. New device: describe ourselves.
    /// Invitation (main device): describe ourselves too (that tells the new device it is
    /// verified) and wait for its description → `link_request` → approval.
    fn link_responder_authed(&self, pc: &Arc<PeerConn>) {
        let invite = self.link.offer.lock().as_ref().map(|o| o.invite).unwrap_or(false);
        if invite {
            self.link.scans.lock().insert(
                pc.peer,
                Scan { qr: false, pake: None, key: None, authed: true, info: None, path: pc.path, waiter: None, incoming: true },
            );
            let (name, kind) = self.link.offer.lock().as_ref().map(|o| (o.name.clone(), o.kind)).unwrap_or_default();
            let info = LinkInfoMsg { name, kind, os: std::env::consts::OS.into(), app: env!("CARGO_PKG_VERSION").into(), accept: vec![] };
            let _ = pc.ctl.try_send(proto::ext(ext::LINK_INFO, &info));
        } else {
            self.send_link_info(pc);
        }
    }

    fn scan_done(&self, dev: &PeerId, r: std::result::Result<LinkInfoMsg, String>) {
        let w = self.link.scans.lock().get_mut(dev).and_then(|s| s.waiter.take());
        if let Some(w) = w {
            let _ = w.send(r);
        }
    }

    /// N: store the account, then ask the host to restart this node as a device of it.
    fn link_accepted(self: &Arc<Self>, pc: &Arc<PeerConn>, m: LinkAcceptMsg) -> Result<()> {
        let cert = DeviceCert::decode(&m.cert)?;
        anyhow::ensure!(cert.device == self.device && cert.verify() && cert.account == pc.account, "certificate is not for this device");
        let list = SignedDeviceList::decode(&m.list)?;
        let body = list.validate()?;
        anyhow::ensure!(body.account == cert.account && body.is_active(&self.device), "device list doesn't include this device");
        anyhow::ensure!(self.store.is_fresh(), crate::i18n::user_err("err.link_not_fresh"));
        self.store.reset_for_link(&self.device)?;
        self.store.device_list_put(&m.list, &body)?;
        let plan = super::sync::HistoryPlan { source: pc.peer.to_base32(), since_ms: m.since_ms, media: m.media, ..Default::default() };
        self.store.kv_set_json("link.history", &plan)?;
        // our own stand-alone identity is gone: drop its single-device list
        self.store.kv_set("account.cert", &cert.encode())?;
        self.store.kv_set("account.id", cert.account.to_base32().as_bytes())?;
        self.store.kv_set("account.role", b"secondary")?;
        if let Some(o) = self.link.offer.lock().as_mut() {
            o.accepted = true;
        }
        *self.net.lan.link_beacon.write() = None;
        tracing::info!("linked to account {:?} — restarting as one of its devices", cert.account);
        self.emit("link_state", json!({"state": "approved", "account": cert.account.to_base32()}));
        self.emit("link_state", json!({"state": "restart", "account": cert.account.to_base32()}));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nostr_link_beacon_carries_no_public_address() {
        let addrs: Vec<SocketAddr> = vec![
            "8.8.4.4:4433".parse().unwrap(),       // public v4
            "[2001:db8::1]:4433".parse().unwrap(), // global v6 (2000::/3)
            "[::ffff:1.2.3.4]:4433".parse().unwrap(), // public v4, v6-mapped
            "100.72.1.2:4433".parse().unwrap(),    // carrier-grade NAT
            "192.168.1.20:4433".parse().unwrap(),
            "10.0.0.5:4433".parse().unwrap(),
            "[fd00::5]:4433".parse().unwrap(),
            "[fe80::1]:4433".parse().unwrap(),
        ];
        let kept = beacon_addrs(addrs);
        for a in &kept {
            let ip = crate::util::canon(*a).ip();
            assert!(!crate::util::is_global_ip(&ip) && !crate::util::is_cgnat(&ip), "public address {a} in the beacon");
        }
        for want in ["192.168.1.20:4433", "10.0.0.5:4433", "[fd00::5]:4433", "[fe80::1]:4433"] {
            assert!(kept.contains(&want.parse().unwrap()), "LAN address {want} dropped");
        }
        assert!(!kept.contains(&"8.8.4.4:4433".parse().unwrap()));
        assert!(!kept.contains(&"[::ffff:1.2.3.4]:4433".parse().unwrap()));
        assert!(!kept.contains(&"[2001:db8::1]:4433".parse().unwrap()));
        assert!(!kept.contains(&"100.72.1.2:4433".parse().unwrap()));
    }

    #[test]
    fn nostr_link_beacon_stays_compatible() {
        // an older build's beacon (with addresses) still parses, and so does one without `a`
        let old = r#"{"d":"abc","a":["8.8.4.4:4433"],"r":["wss://relay.example"]}"#;
        let b: NostrBeacon = serde_json::from_str(old).unwrap();
        assert_eq!(b.a.len(), 1);
        let new: NostrBeacon = serde_json::from_str(r#"{"d":"abc","r":[]}"#).unwrap();
        assert!(new.a.is_empty());
        // what we publish from public-only candidates: an empty (but present) list
        let ours = serde_json::to_string(&NostrBeacon { d: "abc".into(), a: beacon_addrs(vec!["8.8.4.4:4433".parse().unwrap()]), r: vec![] }).unwrap();
        assert!(!ours.contains("8.8.4.4"));
        let back: NostrBeacon = serde_json::from_str(&ours).unwrap();
        assert!(back.a.is_empty());
    }
}
