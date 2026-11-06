//! Remote desktop + calls: session control protocol and media plumbing.
//!
//! Authentication for remote control never sends the password: the host issues a
//! random nonce and the viewer proves knowledge with
//! `BLAKE3-keyed(KDF(password), nonce ‖ viewer ‖ host)`. Five failures from a peer
//! lock it out with exponential back-off. Trusted peers (explicitly added) and
//! unattended mode are opt-in.
//!
//! **v2 (protocol 3)**: the fixed (unattended) password is stored only as a *verifier*:
//! `seed = Argon2id(password, salt, m/t/p)`, verifier = the Ed25519 public key of `seed`.
//! `Ext RemoteChallengeV2` carries the salt + KDF parameters, the viewer derives the seed
//! and signs `nonce ‖ viewer ‖ host`. Someone who copies the host's data learns nothing
//! that logs in (only an Argon2id-hardened offline guess target). The temporary password
//! (shown on screen, in memory only) keeps the v1 keyed proof, which is also what older
//! viewers send (`RemoteChallenge` v1 is still used for peers below protocol 3).

use super::*;
use bytes::Bytes;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

pub type SessionId = [u8; 16];

const PW_CHARS: &[u8] = b"abcdefghjkmnpqrstuvwxyz23456789";

fn pw_key(pw: &str) -> [u8; 32] {
    blake3::derive_key("lumora remote password v1", pw.trim().as_bytes())
}

/// Salted Argon2id parameters of the fixed password (sent in the v2 challenge).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub(crate) struct KdfParams {
    #[serde(with = "serde_bytes")]
    pub salt: Vec<u8>,
    /// memory (KiB), iterations, lanes
    pub m: u32,
    pub t: u32,
    pub p: u32,
}

impl KdfParams {
    fn fresh() -> KdfParams {
        // OWASP minimum for Argon2id (19 MiB, 2 passes): ~50–150 ms on a phone
        KdfParams { salt: crate::crypto::random_bytes::<16>().to_vec(), m: 19 * 1024, t: 2, p: 1 }
    }
    /// Reject parameters a malicious host could use to exhaust the viewer.
    fn sane(&self) -> bool {
        (8..=64).contains(&self.salt.len()) && (8 * 1024..=256 * 1024).contains(&self.m) && (1..=10).contains(&self.t) && (1..=4).contains(&self.p)
    }
}

/// What the host keeps for its fixed password (kv `remote.fixed_v2`).
#[derive(Serialize, Deserialize, Clone, Debug)]
pub(crate) struct FixedVerifier {
    pub kdf: KdfParams,
    #[serde(with = "serde_bytes")]
    pub verifier: Vec<u8>,
}

fn v2_seed(pw: &str, kdf: &KdfParams) -> Result<zeroize::Zeroizing<[u8; 32]>> {
    use argon2::{Algorithm, Argon2, Params, Version};
    anyhow::ensure!(kdf.sane(), "unreasonable password parameters");
    let params = Params::new(kdf.m, kdf.t, kdf.p, Some(32)).map_err(|e| anyhow!("{e}"))?;
    let mut out = zeroize::Zeroizing::new([0u8; 32]);
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
        .hash_password_into(pw.trim().as_bytes(), &kdf.salt, &mut out[..])
        .map_err(|e| anyhow!("{e}"))?;
    Ok(out)
}

fn v2_signed_bytes(nonce: &[u8; 16], viewer: &PeerId, host: &PeerId) -> Vec<u8> {
    let mut v = b"lumora-remote-v2".to_vec();
    v.extend_from_slice(nonce);
    v.extend_from_slice(&viewer.0);
    v.extend_from_slice(&host.0);
    v
}

/// Viewer: sign the challenge with the key derived from the typed password.
fn v2_sign(pw: &str, kdf: &KdfParams, nonce: &[u8; 16], viewer: &PeerId, host: &PeerId) -> Result<Vec<u8>> {
    let seed = v2_seed(pw, kdf)?;
    let id = Identity::from_secret(&seed);
    Ok(id.sign(&v2_signed_bytes(nonce, viewer, host)).to_vec())
}

/// Host: the verifier (public key) for a password — computed once when it is set.
fn v2_verifier(pw: &str, kdf: &KdfParams) -> Result<Vec<u8>> {
    let seed = v2_seed(pw, kdf)?;
    Ok(Identity::from_secret(&seed).peer_id().0.to_vec())
}

#[derive(Serialize, Deserialize, Debug)]
struct ChallengeV2 {
    session: [u8; 16],
    nonce: [u8; 16],
    /// present when the host has a fixed password
    #[serde(default)]
    kdf: Option<KdfParams>,
}

#[derive(Serialize, Deserialize, Debug)]
struct AuthV2 {
    session: [u8; 16],
    /// keyed proof with the typed password (temporary password / legacy fixed key)
    #[serde(with = "serde_bytes")]
    proof: Vec<u8>,
    /// signature with the Argon2id-derived key (fixed password), empty if no kdf was offered
    #[serde(default, with = "serde_bytes")]
    sig: Vec<u8>,
}

// ---------------------------------------------------------------- IP privacy: pre-auth
//
// A viewer that is not a friend first proves the password over sealed signaling mail
// (relays / Nostr: no connection, no addresses). Only after that (or for a trusted
// device) does the host keep a *pre-authenticated* host session, which lets
// `reveals_addrs_to` answer the viewer's connection offer. The real `RemoteRequest` then
// arrives over the connection and skips the challenge.
//   viewer → host  Ext REMOTE_PRE_REQ        {session, view_only, ts, cert}
//   host → viewer  Ext REMOTE_PRE_CHALLENGE  ChallengeV2 {session, nonce, kdf}
//   viewer → host  Ext REMOTE_PRE_AUTH       AuthV2 {session, proof, sig}
//   host → viewer  Ext REMOTE_PRE_RESULT     {session, ok, reason}

/// How long a verified pre-authentication lets the viewer reach the host (until the
/// session is accepted; then for the session's life).
const PRE_AUTH_TTL: Duration = Duration::from_secs(120);
/// Viewer: wait this long for the host's first answer before falling back to the
/// connect-first flow (older hosts ignore the pre-request).
const PRE_FIRST_WAIT: Duration = Duration::from_secs(8);
/// Viewer: after the challenge, wait this long for the verdict (Argon2 on both sides).
const PRE_RESULT_WAIT: Duration = Duration::from_secs(12);

#[derive(Serialize, Deserialize, Debug)]
struct PreReq {
    session: [u8; 16],
    #[serde(default)]
    view_only: bool,
    /// sender clock (ms): relay mailboxes may deliver late, stale requests are dropped
    #[serde(default)]
    ts: u64,
    /// a linked device's certificate (so the host knows the account, e.g. for trust)
    #[serde(default, with = "serde_bytes")]
    cert: Vec<u8>,
}

#[derive(Serialize, Deserialize, Debug)]
struct PreResult {
    session: [u8; 16],
    #[serde(default)]
    ok: bool,
    /// message key (`err.…`) when refused
    #[serde(default)]
    reason: String,
}

/// Host: a host session whose password was verified (or whose device is trusted) before
/// any connection.
#[derive(Clone, Copy, Debug)]
pub(crate) struct PreAuth {
    at: Instant,
    /// accept without asking the host user (trusted, or fixed password + unattended)
    auto: bool,
    /// the `RemoteRequest` over the connection already used it
    used: bool,
}

/// Viewer: an outstanding pre-authentication.
struct PreWait {
    host: PeerId,
    password: String,
    tx: mpsc::UnboundedSender<PreEvent>,
    challenged: bool,
}

enum PreEvent {
    Challenged,
    Result { ok: bool, reason: String },
}

enum PreOutcome {
    /// the host verified us: connect now
    Ok,
    Denied(String),
    /// no signaling channel / no answer (older host): connect-first flow
    Unanswered,
}

/// Result of checking a viewer's answer to a challenge.
enum Verdict {
    /// not for a live challenge (unknown session, other device, duplicate)
    Ignore,
    Deny(&'static str),
    Ok { s: Arc<Session>, auto: bool },
}

/// Execute a power action on this machine (host side).
fn power_action(action: &str) -> Result<()> {
    use std::process::Command;
    let ok = |c: &mut Command| -> Result<()> {
        let st = c.status()?;
        anyhow::ensure!(st.success(), "command failed: {st}");
        Ok(())
    };
    #[cfg(target_os = "linux")]
    return match action {
        "lock" => ok(Command::new("loginctl").arg("lock-session")),
        "logout" => ok(Command::new("loginctl").args(["terminate-session", &std::env::var("XDG_SESSION_ID").unwrap_or_default()])),
        "restart" => ok(Command::new("systemctl").arg("reboot")),
        _ => Err(anyhow!("unsupported")),
    };
    #[cfg(windows)]
    return match action {
        "lock" => ok(Command::new("rundll32.exe").args(["user32.dll,LockWorkStation"])),
        "logout" => ok(Command::new("shutdown").args(["/l"])),
        "restart" => ok(Command::new("shutdown").args(["/r", "/t", "5", "/c", "Lumora remote restart"])),
        _ => Err(anyhow!("unsupported")),
    };
    #[cfg(target_os = "macos")]
    return match action {
        "lock" => ok(Command::new("pmset").arg("displaysleepnow")),
        "logout" => ok(Command::new("osascript").args(["-e", "tell application \"System Events\" to log out"])),
        "restart" => ok(Command::new("osascript").args(["-e", "tell application \"System Events\" to restart"])),
        _ => Err(anyhow!("unsupported")),
    };
    #[allow(unreachable_code)]
    {
        let _ = (action, ok);
        Err(anyhow!("power actions are not supported on this platform"))
    }
}

/// Constant-time equality (no early exit leaking how many bytes matched).
fn ct_eq(a: &[u8; 32], b: &[u8; 32]) -> bool {
    a.iter().zip(b.iter()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn proof(key: &[u8; 32], nonce: &[u8; 16], viewer: &PeerId, host: &PeerId) -> [u8; 32] {
    let mut h = blake3::Hasher::new_keyed(key);
    h.update(nonce);
    h.update(&viewer.0);
    h.update(&host.0);
    *h.finalize().as_bytes()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Viewer,
    Host,
}

pub struct Session {
    pub id: SessionId,
    pub peer: PeerId,
    pub role: Role,
    pub view_only: bool,
    pub control: AtomicBool,
    pub nonce: Mutex<Option<[u8; 16]>>,
    pub accepted: AtomicBool,
    pub stream: u32,
    pub stop: Arc<AtomicBool>,
    pub width: AtomicU32,
    pub height: AtomicU32,
    pub display: AtomicU32,
    pub keyframe: Arc<AtomicBool>,
    pub bitrate: Arc<AtomicU32>,
    #[cfg(feature = "media")]
    /// input injection thread, started by the first event (see `media_pipe::handle_input`)
    pub(crate) injector: Mutex<Option<lumora_media::InjectorWorker>>,
    pub(crate) password_for_connect: Mutex<Option<String>>,
    pub created: Instant,
    /// Set once the session has ended; a restarted capture must not resurrect it.
    pub ended: AtomicBool,
    /// Host: verified before any connection (IP privacy pre-authentication).
    pub(crate) pre_auth: Mutex<Option<PreAuth>>,
}

#[derive(Clone)]
pub struct FrameSlot {
    pub w: u32,
    pub h: u32,
    pub rgba: Bytes,
    pub seq: u64,
}

/// `Ext CALL_ELSEWHERE` (own devices only): this incoming call was answered/declined on
/// another of my devices.
#[derive(Serialize, Deserialize, Default)]
pub(crate) struct CallElsewhere {
    #[serde(with = "serde_bytes", default)]
    pub call_id: Vec<u8>,
    #[serde(default)]
    pub answered: bool,
    #[serde(default)]
    pub device_name: String,
}

pub struct Call {
    pub id: [u8; 16],
    pub conv: String,
    pub peers: Mutex<Vec<PeerId>>,
    pub video: bool,
    pub state: Mutex<String>,
    pub mic: AtomicBool,
    pub cam: AtomicBool,
    pub screen: AtomicBool,
    pub started: Instant,
    pub stop: Arc<AtomicBool>,
    pub incoming_from: Option<PeerId>,
    pub media_started: AtomicBool,
    /// Everyone we rang (caller side) — they must hear about a hang-up before answering.
    pub invited: Mutex<Vec<PeerId>>,
}

pub struct RemoteState {
    password: Mutex<String>,
    /// Legacy (v1) fixed-password key from older versions: password-equivalent, kept only
    /// until the user sets the password again (then replaced by `fixed_v2`).
    fixed_key: Mutex<Option<[u8; 32]>>,
    fixed_v2: Mutex<Option<FixedVerifier>>,
    pub unattended: AtomicBool,
    pub allow_control: AtomicBool,
    pub allow_incoming: AtomicBool,
    pub sessions: Mutex<HashMap<SessionId, Arc<Session>>>,
    failures: Mutex<HashMap<PeerId, (u32, Instant)>>,
    global_fail: Mutex<(u32, Instant)>,
    /// Global lockouts in a row: each one doubles the next (5 min, 10, 20 … ≤ 21 h), so a
    /// fixed unattended password gets ~10 guesses a day, not ~2 900.
    global_strikes: AtomicU32,
    /// Viewer: pre-authentications waiting for the host's answer.
    pre_waits: Mutex<HashMap<SessionId, PreWait>>,
    /// Host: pre-requests already seen (the same mail arrives through several channels).
    pre_seen: Mutex<lru::LruCache<SessionId, ()>>,
    pub frames: Mutex<HashMap<u32, FrameSlot>>,
    next_stream: AtomicU32,
    pub calls: Mutex<HashMap<[u8; 16], Arc<Call>>>,
    #[cfg(feature = "media")]
    pub(crate) media: super::media_pipe::MediaState,
    #[cfg(feature = "media")]
    pub(crate) host_display: Mutex<Option<lumora_media::DisplayInfo>>,
}

impl RemoteState {
    pub fn new(store: &Store) -> Self {
        let pw: String = (0..8).map(|_| PW_CHARS[rand::random::<usize>() % PW_CHARS.len()] as char).collect();
        let fixed = store.kv_get("remote.fixed_key").and_then(|v| v.try_into().ok());
        let flag = |k: &str, d: bool| store.kv_get(k).map(|v| v == b"1").unwrap_or(d);
        let fixed_v2 = store.kv_get("remote.fixed_v2").and_then(|b| rmp_serde::from_slice::<FixedVerifier>(&b).ok()).filter(|f| f.verifier.len() == 32);
        RemoteState {
            password: Mutex::new(pw),
            fixed_key: Mutex::new(fixed),
            fixed_v2: Mutex::new(fixed_v2),
            unattended: AtomicBool::new(flag("remote.unattended", false)),
            allow_control: AtomicBool::new(flag("remote.allow_control", true)),
            allow_incoming: AtomicBool::new(flag("remote.allow_incoming", true)),
            sessions: Mutex::new(HashMap::new()),
            failures: Mutex::new(HashMap::new()),
            global_fail: Mutex::new((0, Instant::now())),
            global_strikes: AtomicU32::new(0),
            pre_waits: Mutex::new(HashMap::new()),
            pre_seen: Mutex::new(lru::LruCache::new(std::num::NonZeroUsize::new(512).unwrap())),
            frames: Mutex::new(HashMap::new()),
            next_stream: AtomicU32::new(1),
            calls: Mutex::new(HashMap::new()),
            #[cfg(feature = "media")]
            media: Default::default(),
            #[cfg(feature = "media")]
            host_display: Mutex::new(None),
        }
    }

    pub fn password(&self) -> String {
        self.password.lock().clone()
    }

    pub fn regenerate_password(&self) -> String {
        let pw: String = (0..8).map(|_| PW_CHARS[rand::random::<usize>() % PW_CHARS.len()] as char).collect();
        *self.password.lock() = pw.clone();
        pw
    }

    pub fn alloc_stream(&self) -> u32 {
        self.next_stream.fetch_add(1, Ordering::SeqCst)
    }

    pub fn put_frame(&self, stream: u32, w: u32, h: u32, rgba: Bytes) {
        let mut f = self.frames.lock();
        let seq = f.get(&stream).map(|s| s.seq + 1).unwrap_or(1);
        f.insert(stream, FrameSlot { w, h, rgba, seq });
    }

    fn global_lock_time(&self) -> Duration {
        let strikes = self.global_strikes.load(Ordering::Relaxed).clamp(1, 9);
        Duration::from_secs(300u64 << (strikes - 1))
    }

    fn locked_out(&self, p: &PeerId) -> bool {
        // global window: identities are free, so also limit total failures across all peers
        {
            let g = self.global_fail.lock();
            if g.0 >= 10 && g.1.elapsed() < self.global_lock_time() {
                return true;
            }
        }
        let f = self.failures.lock();
        match f.get(p) {
            Some((n, t)) if *n >= 5 => t.elapsed() < Duration::from_secs(30u64 << (n - 5).min(8)),
            _ => false,
        }
    }

    fn fail(&self, p: &PeerId) {
        {
            let mut f = self.failures.lock();
            if f.len() > 1000 {
                f.retain(|_, (_, t)| t.elapsed() < Duration::from_secs(3600));
            }
            let e = f.entry(*p).or_insert((0, Instant::now()));
            e.0 += 1;
            e.1 = Instant::now();
        }
        let mut g = self.global_fail.lock();
        let window = if g.0 >= 10 { self.global_lock_time() } else { Duration::from_secs(300) };
        if g.1.elapsed() > window {
            *g = (0, Instant::now());
        }
        g.0 += 1;
        if g.0 == 10 {
            // under attack: lock everyone out (counted from now, longer each time) and
            // rotate the temporary password as well
            g.1 = Instant::now();
            self.global_strikes.fetch_add(1, Ordering::Relaxed);
            drop(g);
            self.regenerate_password();
        }
    }

    fn prune_pending(&self) {
        // host-side sessions that never authenticated expire after 60 s; at most 8 pending
        // (a verified pre-authentication waits up to PRE_AUTH_TTL for the viewer to connect)
        let mut s = self.sessions.lock();
        s.retain(|_, x| x.accepted.load(Ordering::Relaxed) || x.role == Role::Viewer || x.created.elapsed() < Duration::from_secs(60) || x.pre_auth_live());
    }

    fn pending_count(&self) -> usize {
        self.sessions.lock().values().filter(|x| x.role == Role::Host && !x.accepted.load(Ordering::Relaxed)).count()
    }

    /// IP privacy: may this (otherwise unknown) device learn my addresses because of remote
    /// control? Only for a session the host user accepted, or whose password was verified
    /// first (address-less pre-authentication). Used by `Node::may_reveal_addrs`.
    pub(crate) fn reveals_addrs_to(&self, dev: &PeerId) -> bool {
        self.sessions
            .lock()
            .values()
            .any(|s| s.peer == *dev && s.role == Role::Host && !s.ended.load(Ordering::Relaxed) && (s.accepted.load(Ordering::Relaxed) || s.pre_auth_live()))
    }

    /// Host: the pre-authenticated (not yet used) session `session` of device `from`.
    fn take_pre_auth(&self, session: &SessionId, from: &PeerId) -> Option<(Arc<Session>, bool)> {
        let s = self.sessions.lock().get(session).cloned()?;
        if s.peer != *from || s.role != Role::Host || s.accepted.load(Ordering::Relaxed) || s.ended.load(Ordering::Relaxed) {
            return None;
        }
        let mut pa = s.pre_auth.lock();
        let p = pa.as_mut().filter(|p| !p.used && p.at.elapsed() < PRE_AUTH_TTL)?;
        p.used = true;
        let auto = p.auto;
        drop(pa);
        Some((s, auto))
    }

    /// Is this session id in use by another device, a viewer session or a running session?
    /// (A stale unaccepted one of the same device may be replaced.)
    fn id_taken(&self, session: &SessionId, from: &PeerId) -> bool {
        match self.sessions.lock().get(session) {
            Some(s) => s.peer != *from || s.role != Role::Host || s.accepted.load(Ordering::Relaxed),
            None => false,
        }
    }

    /// Host: check a viewer's answer to the challenge of `session` (v1: keyed `proof` only;
    /// v2: also `sig`). Consumes the nonce; counts failures and lockouts. Does not need a
    /// connection (also used for the address-less pre-authentication).
    #[allow(clippy::too_many_arguments)]
    fn check_answer(&self, store: &Store, host: &PeerId, from: &PeerId, acct: &PeerId, session: &SessionId, p: &[u8], sig: &[u8]) -> Verdict {
        let Some(s) = self.sessions.lock().get(session).cloned() else { return Verdict::Ignore };
        if s.peer != *from || s.role != Role::Host {
            return Verdict::Ignore;
        }
        let Some(nonce) = s.nonce.lock().take() else { return Verdict::Ignore };
        // sessions opened before a lockout (up to 8 pending) can't keep guessing
        let trusted = store.remote_trusted(acct).is_some() || store.remote_trusted(from).is_some();
        if self.locked_out(from) && !trusted {
            self.sessions.lock().remove(session);
            return Verdict::Deny("err.remote_disabled");
        }
        // the proof binds both *devices* (== accounts for single-device users)
        let p: [u8; 32] = p.try_into().unwrap_or([0u8; 32]);
        let temp_ok = ct_eq(&proof(&pw_key(&self.password()), &nonce, from, host), &p);
        let legacy_ok = self.fixed_key.lock().map(|k| ct_eq(&proof(&k, &nonce, from, host), &p)).unwrap_or(false);
        let v2_ok = !sig.is_empty()
            && self
                .fixed_v2
                .lock()
                .as_ref()
                .and_then(|f| <[u8; 32]>::try_from(f.verifier.as_slice()).ok())
                .map(|vk| PeerId(vk).verify(&v2_signed_bytes(&nonce, from, host), sig))
                .unwrap_or(false);
        let fixed_ok = legacy_ok || v2_ok;
        if !(temp_ok || fixed_ok || trusted) {
            self.fail(from);
            self.sessions.lock().remove(session);
            return Verdict::Deny("err.wrong_password");
        }
        self.failures.lock().remove(from);
        if temp_ok || fixed_ok {
            self.global_strikes.store(0, Ordering::Relaxed);
        }
        let auto = (fixed_ok && self.unattended.load(Ordering::Relaxed)) || trusted;
        Verdict::Ok { s, auto }
    }

    pub fn status(&self, node: &Node) -> Value {
        json!({
            "my_short_id": node.me.short_id_fmt(),
            "my_peer": node.me.to_base32(),
            "password": self.password(),
            "fixed_password": self.fixed_key.lock().is_some() || self.fixed_v2.lock().is_some(),
            // an older version stored a password-equivalent key: setting the password again upgrades it
            "fixed_password_legacy": self.fixed_key.lock().is_some(),
            "unattended": self.unattended.load(Ordering::Relaxed),
            "allow_control": self.allow_control.load(Ordering::Relaxed),
            "allow_incoming": self.allow_incoming.load(Ordering::Relaxed),
            "macs": super::wake::local_macs_peek().iter().map(super::wake::fmt_mac).collect::<Vec<_>>(),
            "sessions": self.sessions.lock().values().map(|s| json!({
                "session": hex::encode(s.id), "peer": s.peer.to_base32(), "role": s.role,
                "active": s.accepted.load(Ordering::Relaxed), "stream": s.stream,
            })).collect::<Vec<_>>(),
        })
    }

    pub fn set(&self, store: &Store, password: Option<&str>, unattended: Option<bool>, allow_control: Option<bool>, allow_incoming: Option<bool>) -> Result<()> {
        if let Some(pw) = password {
            // the legacy password-equivalent key is dropped either way
            *self.fixed_key.lock() = None;
            store.kv_del("remote.fixed_key")?;
            if pw.is_empty() {
                *self.fixed_v2.lock() = None;
                store.kv_del("remote.fixed_v2")?;
            } else {
                anyhow::ensure!(pw.chars().count() >= 8, crate::i18n::user_err("err.fixed_pw_len"));
                let kdf = KdfParams::fresh();
                let f = FixedVerifier { verifier: v2_verifier(pw, &kdf)?, kdf };
                store.kv_set("remote.fixed_v2", &rmp_serde::to_vec_named(&f)?)?;
                *self.fixed_v2.lock() = Some(f);
            }
        }
        if let Some(u) = unattended {
            self.unattended.store(u, Ordering::Relaxed);
            store.kv_set("remote.unattended", if u { b"1" } else { b"0" })?;
        }
        if let Some(c) = allow_control {
            self.allow_control.store(c, Ordering::Relaxed);
            store.kv_set("remote.allow_control", if c { b"1" } else { b"0" })?;
        }
        if let Some(c) = allow_incoming {
            self.allow_incoming.store(c, Ordering::Relaxed);
            store.kv_set("remote.allow_incoming", if c { b"1" } else { b"0" })?;
        }
        Ok(())
    }

    // ---------------------------------------------------------- inbound plumbing

    pub(crate) async fn on_media_stream(&self, node: &Arc<Node>, pc: &Arc<PeerConn>, recv: quinn::RecvStream) {
        #[cfg(feature = "media")]
        {
            super::media_pipe::on_media_stream(node, pc, recv).await;
        }
        #[cfg(not(feature = "media"))]
        {
            let _ = (node, pc, recv);
        }
    }

    pub(crate) fn on_datagram(&self, node: &Arc<Node>, pc: &Arc<PeerConn>, d: Bytes) {
        #[cfg(feature = "media")]
        {
            super::media_pipe::on_datagram(node, pc, d);
        }
        #[cfg(not(feature = "media"))]
        {
            let _ = (node, pc, d);
        }
    }

    pub(crate) fn on_disconnect(&self, node: &Arc<Node>, peer: &PeerId) {
        let ended: Vec<Arc<Session>> = self.sessions.lock().values().filter(|s| s.peer == *peer).cloned().collect();
        for s in ended {
            node.end_session(&s.id, false);
        }
        let calls: Vec<Arc<Call>> = self.calls.lock().values().cloned().collect();
        for c in calls {
            let (was_in, empty) = {
                let mut p = c.peers.lock();
                let n = p.len();
                p.retain(|x| x != peer);
                (p.len() != n, p.is_empty())
            };
            if empty {
                node.end_call(&c.id, false);
            } else if was_in {
                node.call_peer_left(&c, peer);
                node.emit_call(&c);
            }
        }
    }

    /// Host: check a viewer's answer (v1: keyed `proof` only; v2: also `sig`).
    async fn host_auth(&self, node: &Arc<Node>, pc: &Arc<PeerConn>, session: SessionId, p: &[u8], sig: &[u8]) -> Result<()> {
        let (s, auto) = match self.check_answer(&node.store, &node.device, &pc.peer, &pc.account, &session, p, sig) {
            Verdict::Ignore => return Ok(()),
            Verdict::Deny(reason) => {
                let _ = pc.ctl.try_send(PeerMsg::RemoteDeny { session, reason: reason.into() });
                return Ok(());
            }
            Verdict::Ok { s, auto } => (s, auto),
        };
        self.host_proceed(node, pc, &s, auto).await
    }

    /// Viewer: the host refused our session `session` (only the host itself may say so).
    fn viewer_denied(&self, node: &Node, session: &SessionId, host: &PeerId, reason: String) {
        let s = {
            let mut m = self.sessions.lock();
            match m.get(session) {
                Some(s) if s.peer == *host && s.role == Role::Viewer => m.remove(session),
                _ => None,
            }
        };
        if let Some(s) = s {
            s.stop.store(true, Ordering::SeqCst);
            // the host sends a message key ("err.…"); older versions send plain text
            let (code, text) = match crate::i18n::known_key(&reason) {
                Some(k) => (k.to_string(), crate::i18n::tr(k)),
                None => ("denied".to_string(), reason),
            };
            node.emit("remote_state", json!({"session": hex::encode(session), "peer": host.to_base32(), "state": "denied", "reason": text, "code": code}));
        }
    }

    /// Host: the viewer is authenticated (now, or before connecting): accept on its own
    /// (trusted / unattended) or ask the host user.
    async fn host_proceed(&self, node: &Arc<Node>, pc: &Arc<PeerConn>, s: &Arc<Session>, auto: bool) -> Result<()> {
        let (session, from, acct) = (s.id, pc.peer, pc.account);
        if auto {
            node.accept_session(&session, self.allow_control.load(Ordering::Relaxed) && !s.view_only).await?;
        } else {
            let name = pc.name.read().clone();
            node.emit("remote_request", json!({
                "session": hex::encode(session), "peer": acct.to_base32(), "device": from.to_base32(), "name": name,
                "short_id": acct.short_id_fmt(), "view_only": s.view_only,
            }));
        }
        Ok(())
    }

    /// Remote-control messages of protocol v3 (`Ext`).
    pub(crate) async fn on_ext(&self, node: &Arc<Node>, pc: &Arc<PeerConn>, kind: u16, body: &[u8]) -> Result<()> {
        match kind {
            proto::ext::REMOTE_AUTH_V2 => {
                let m: AuthV2 = proto::ext_body(body)?;
                self.host_auth(node, pc, m.session, &m.proof, &m.sig).await?;
            }
            proto::ext::REMOTE_CHALLENGE_V2 => {
                let m: ChallengeV2 = proto::ext_body(body)?;
                let Some(s) = self.sessions.lock().get(&m.session).cloned() else { return Ok(()) };
                if s.peer != pc.peer || s.role != Role::Viewer {
                    return Ok(());
                }
                let pw = s.password_for_connect.lock().take().unwrap_or_default();
                let (viewer, host) = (node.device, pc.peer);
                let p = proof(&pw_key(&pw), &m.nonce, &viewer, &host);
                // the Argon2id work happens off the async runtime
                let sig = match m.kdf.filter(|k| k.sane()) {
                    Some(kdf) if !pw.trim().is_empty() => {
                        let nonce = m.nonce;
                        tokio::task::spawn_blocking(move || v2_sign(&pw, &kdf, &nonce, &viewer, &host)).await??
                    }
                    _ => vec![],
                };
                let _ = pc.ctl.try_send(proto::ext(proto::ext::REMOTE_AUTH_V2, &AuthV2 { session: m.session, proof: p.to_vec(), sig }));
                node.emit("remote_state", json!({"session": hex::encode(m.session), "peer": pc.account.to_base32(), "state": "waiting", "role": "viewer"}));
            }
            _ => {}
        }
        Ok(())
    }

    pub(crate) async fn on_control(&self, node: &Arc<Node>, pc: &Arc<PeerConn>, m: PeerMsg) -> Result<()> {
        // sessions and calls are per device; permissions (friend, trusted, blocked) per account
        let from = pc.peer;
        let acct = pc.account;
        if let PeerMsg::RemoteRequest { session, .. } = &m {
            // a viewer that already proved the password before connecting (address-less
            // pre-authentication): no second challenge — only for that very device
            if let Some((s, auto)) = self.take_pre_auth(session, &from) {
                if !self.allow_incoming.load(Ordering::Relaxed) || node.store.is_blocked(&acct) {
                    self.sessions.lock().remove(session);
                    let _ = pc.ctl.try_send(PeerMsg::RemoteDeny { session: *session, reason: "err.remote_disabled".into() });
                    return Ok(());
                }
                let trusted = node.store.remote_trusted(&acct).is_some() || node.store.remote_trusted(&from).is_some();
                return self.host_proceed(node, pc, &s, auto || trusted).await;
            }
            // never take over someone else's (or a running) session by reusing its id
            if self.id_taken(session, &from) {
                return Ok(());
            }
        }
        match m {
            // ---------------- remote: host side
            PeerMsg::RemoteRequest { session, view_only, ask, .. } if ask => {
                // "Xin điều khiển": a friend asks without a password → the host user decides.
                self.prune_pending();
                if !self.allow_incoming.load(Ordering::Relaxed) || !(node.store.is_friend(&acct) || pc.own) || self.pending_count() >= 8 {
                    let _ = pc.ctl.try_send(PeerMsg::RemoteDeny { session, reason: "err.remote_disabled".into() });
                    return Ok(());
                }
                let s = Arc::new(Session::new(session, from, Role::Host, view_only, self.alloc_stream()));
                self.sessions.lock().insert(session, s.clone());
                if node.store.remote_trusted(&acct).is_some() || node.store.remote_trusted(&from).is_some() {
                    node.accept_session(&session, self.allow_control.load(Ordering::Relaxed) && !view_only).await?;
                } else {
                    let name = pc.name.read().clone();
                    node.emit("remote_request", json!({
                        "session": hex::encode(session), "peer": from.to_base32(), "name": name,
                        "short_id": from.short_id_fmt(), "view_only": view_only, "ask": true,
                    }));
                }
            }
            PeerMsg::RemoteRequest { session, view_only, .. } => {
                self.prune_pending();
                if !self.allow_incoming.load(Ordering::Relaxed) || self.locked_out(&from) || self.pending_count() >= 8 || node.store.is_blocked(&acct) {
                    let _ = pc.ctl.try_send(PeerMsg::RemoteDeny { session, reason: "err.remote_disabled".into() });
                    return Ok(());
                }
                let nonce: [u8; 16] = crate::crypto::random_bytes();
                let s = Arc::new(Session::new(session, from, Role::Host, view_only, self.alloc_stream()));
                *s.nonce.lock() = Some(nonce);
                self.sessions.lock().insert(session, s);
                if pc.proto.load(Ordering::Relaxed) >= proto::PROTO_V3 {
                    let kdf = self.fixed_v2.lock().as_ref().map(|f| f.kdf.clone());
                    let _ = pc.ctl.try_send(proto::ext(proto::ext::REMOTE_CHALLENGE_V2, &ChallengeV2 { session, nonce, kdf }));
                } else {
                    let _ = pc.ctl.try_send(PeerMsg::RemoteChallenge { session, nonce });
                }
            }
            PeerMsg::RemoteAuth { session, proof: p } => self.host_auth(node, pc, session, &p, &[]).await?,
            PeerMsg::RemoteInput { session, ev } => {
                #[cfg(feature = "media")]
                if let Ok(ev) = crate::proto::from_slice_capped::<Value>(&ev) {
                    super::media_pipe::handle_input(node, &from, session, &ev);
                }
                #[cfg(not(feature = "media"))]
                let _ = (session, ev);
            }
            PeerMsg::RemoteAction { session, action } => {
                let sess = self.sessions.lock().get(&session).cloned();
                if let Some(s) = sess {
                    if s.peer == from && s.role == Role::Host && s.accepted.load(Ordering::Relaxed) && s.control.load(Ordering::Relaxed) {
                        let allow_power = node.store.kv_get("remote.allow_power").map(|v| v == b"1").unwrap_or(false);
                        let r = match action.as_str() {
                            "lock" => power_action("lock"),
                            "restart" | "logout" if allow_power => power_action(&action),
                            "restart" | "logout" => Err(crate::i18n::user_err("err.power_not_allowed").into()),
                            _ => Err(anyhow!("unknown action")),
                        };
                        let mut ev = json!({"session": hex::encode(session), "action": action, "ok": r.is_ok()});
                        if let Err(e) = r {
                            let e = crate::i18n::or_user(e, "err.power_failed");
                            for (k, v) in crate::i18n::error_fields(&e) {
                                ev[k] = v;
                            }
                        }
                        node.emit("remote_action", ev);
                    }
                }
            }
            PeerMsg::RemoteSelectDisplay { session, index } => {
                let sess = self.sessions.lock().get(&session).cloned();
                if let Some(s) = sess {
                    if s.peer == from && s.role == Role::Host && s.accepted.load(Ordering::SeqCst) {
                        s.display.store(index, Ordering::SeqCst);
                        #[cfg(feature = "media")]
                        super::media_pipe::restart_host(node, &s);
                    }
                }
            }
            PeerMsg::KeyframeRequest { stream } => {
                // only for what we send to the requester: a remote session it views,
                // or a call it takes part in (`stream` names one stream, 0 = all of
                // them); the encoder forces at most one keyframe per 300 ms
                let mut ids: Vec<[u8; 16]> = self
                    .sessions
                    .lock()
                    .values()
                    .filter(|s| s.peer == from && s.role == Role::Host && s.accepted.load(Ordering::Relaxed))
                    .map(|s| s.id)
                    .collect();
                ids.extend(self.calls.lock().values().filter(|c| c.peers.lock().contains(&from)).map(|c| c.id));
                #[cfg(feature = "media")]
                self.media.request_keyframe(&ids, stream);
                #[cfg(not(feature = "media"))]
                let _ = (ids, stream);
            }
            PeerMsg::Bitrate { stream, kbps } => {
                let _ = stream;
                for s in self.sessions.lock().values() {
                    if s.peer == from && s.role == Role::Host {
                        s.bitrate.store(kbps.clamp(300, 50_000), Ordering::SeqCst);
                    }
                }
            }
            PeerMsg::Clipboard { text } => {
                // clipboard sync belongs to control: never on a view-only session (in
                // either direction — a viewer that may only watch doesn't get or set
                // the host's clipboard)
                let active = self.sessions.lock().values().any(|s| s.peer == from && s.accepted.load(Ordering::Relaxed) && s.control.load(Ordering::Relaxed));
                if active {
                    node.emit("clipboard", json!({"peer": from.to_base32(), "text": text}));
                }
            }
            // ---------------- remote: viewer side
            PeerMsg::RemoteChallenge { session, nonce } => {
                let Some(s) = self.sessions.lock().get(&session).cloned() else { return Ok(()) };
                if s.peer != from || s.role != Role::Viewer {
                    return Ok(());
                }
                let pw = s.password_for_connect.lock().take().unwrap_or_default();
                let p = proof(&pw_key(&pw), &nonce, &node.device, &from);
                let _ = pc.ctl.try_send(PeerMsg::RemoteAuth { session, proof: p });
                node.emit("remote_state", json!({"session": hex::encode(session), "peer": from.to_base32(), "state": "waiting", "role": "viewer"}));
            }
            PeerMsg::RemoteAccept { session, width, height, displays, control } => {
                let Some(s) = self.sessions.lock().get(&session).cloned() else { return Ok(()) };
                if s.peer != from || s.role != Role::Viewer {
                    return Ok(());
                }
                s.accepted.store(true, Ordering::SeqCst);
                s.control.store(control, Ordering::SeqCst);
                // (kept until now in case the pre-authenticated host challenged again)
                s.password_for_connect.lock().take();
                // remember for the "recent devices" list
                {
                    let name = pc.name.read().clone();
                    let mut list: Vec<Value> = node.store.kv_get_json("remote.recent").unwrap_or_default();
                    // keep what we learned earlier (wake-up info) when refreshing the entry
                    let macs = list.iter().find(|x| x["peer"].as_str() == Some(&from.to_base32())).map(|x| x["macs"].clone());
                    list.retain(|x| x["peer"].as_str() != Some(&from.to_base32()));
                    let mut e = json!({"peer": from.to_base32(), "short_id": from.short_id_fmt(), "name": name, "last": crate::util::now_ms()});
                    if let Some(m) = macs.filter(|m| m.is_array()) {
                        e["macs"] = m;
                    }
                    list.insert(0, e);
                    list.truncate(30);
                    let _ = node.store.kv_set_json("remote.recent", &list);
                }
                s.width.store(width, Ordering::SeqCst);
                s.height.store(height, Ordering::SeqCst);
                node.emit("remote_state", json!({
                    "session": hex::encode(session), "peer": from.to_base32(), "state": "active", "role": "viewer",
                    "width": width, "height": height, "stream": s.stream, "control": control,
                    "displays": displays.iter().map(|(w, h, n)| json!({"width": w, "height": h, "name": n})).collect::<Vec<_>>(),
                }));
            }
            PeerMsg::RemoteDeny { session, reason } => self.viewer_denied(node, &session, &from, reason),
            PeerMsg::RemoteEnd { session } => {
                let ok = self.sessions.lock().get(&session).map(|s| s.peer == from).unwrap_or(false);
                if ok {
                    node.end_session(&session, false);
                }
            }
            // ---------------- calls
            PeerMsg::CallInvite { call_id, video, group } => {
                let existing = self.calls.lock().get(&call_id).cloned();
                if let Some(c) = existing {
                    // joining an existing call (group): only someone invited, or a member
                    // of the call's group
                    if !call_may_join(node, &c, &from, &acct) {
                        return Ok(());
                    }
                    let mut p = c.peers.lock();
                    if !p.contains(&from) {
                        p.push(from);
                    }
                    return Ok(());
                }
                // group call invites must come from a member of that group
                if let Some(g) = group {
                    if !node.group_members(&g).contains(&acct) {
                        return Ok(());
                    }
                }
                if node.store.is_blocked(&acct) {
                    return Ok(());
                }
                let conv = match group {
                    Some(g) => format!("g:{}", hex::encode(g)),
                    None => direct_conv(&acct),
                };
                let busy = !self.calls.lock().is_empty();
                if busy {
                    let _ = pc.ctl.try_send(PeerMsg::CallAnswer { call_id, accept: false });
                    return Ok(());
                }
                let c = Arc::new(Call {
                    id: call_id,
                    conv,
                    peers: Mutex::new(vec![from]),
                    video,
                    state: Mutex::new("incoming".into()),
                    mic: AtomicBool::new(true),
                    cam: AtomicBool::new(video),
                    screen: AtomicBool::new(false),
                    started: Instant::now(),
                    stop: Arc::new(AtomicBool::new(false)),
                    incoming_from: Some(from),
                    media_started: AtomicBool::new(false),
                    invited: Mutex::new(vec![]),
                });
                self.calls.lock().insert(call_id, c.clone());
                node.emit_call(&c);
                // auto-miss after 45 s
                let n = node.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_secs(45)).await;
                    let c = n.remote.calls.lock().get(&call_id).cloned();
                    let missed = c.map(|c| *c.state.lock() == "incoming").unwrap_or(false);
                    if missed {
                        n.end_call(&call_id, true);
                    }
                });
            }
            PeerMsg::CallAnswer { call_id, accept } => {
                let Some(c) = self.calls.lock().get(&call_id).cloned() else { return Ok(()) };
                // only from a device we rang (or a member of the call's group)
                if !call_may_join(node, &c, &from, &acct) {
                    return Ok(());
                }
                // the callee's other devices that are still ringing: the first answer wins,
                // and a decline on one device is the account's answer
                let others: Vec<PeerId> = {
                    let mut inv = c.invited.lock();
                    let o: Vec<PeerId> = inv.iter().filter(|d| **d != from && node.account_of(d) == acct).copied().collect();
                    inv.retain(|d| !o.contains(d) && (accept || *d != from));
                    o
                };
                if !others.is_empty() {
                    // (CallEnd: every version stops ringing on it; a short delay lets the
                    // answering device tell its siblings first, so they say "answered elsewhere")
                    let n = node.clone();
                    tokio::spawn(async move {
                        tokio::time::sleep(Duration::from_millis(600)).await;
                        for d in others {
                            n.send_now_dev(&d, PeerMsg::CallEnd { call_id });
                        }
                    });
                }
                if accept {
                    *c.state.lock() = "active".into();
                    {
                        let mut p = c.peers.lock();
                        if !p.contains(&from) {
                            p.push(from);
                        }
                    }
                    #[cfg(feature = "media")]
                    super::media_pipe::start_call_media(node, &c);
                    node.emit_call(&c);
                } else {
                    let empty = {
                        let mut p = c.peers.lock();
                        p.retain(|x| *x != from);
                        p.is_empty()
                    };
                    if !empty {
                        node.call_peer_left(&c, &from);
                    }
                    // others still ringing (group call): keep going
                    let ringing = c.invited.lock().iter().any(|d| node.account_of(d) != acct);
                    if empty && !(ringing && *c.state.lock() == "ringing") {
                        node.end_call(&call_id, false);
                    }
                }
            }
            PeerMsg::CallEnd { call_id } => {
                let Some(c) = self.calls.lock().get(&call_id).cloned() else { return Ok(()) };
                if !call_may_join(node, &c, &from, &acct) {
                    return Ok(());
                }
                let (was_in, empty) = {
                    let mut p = c.peers.lock();
                    let n = p.len();
                    p.retain(|x| *x != from);
                    (p.len() != n, p.is_empty())
                };
                if empty {
                    node.end_call(&call_id, false);
                } else if was_in {
                    node.call_peer_left(&c, &from);
                    node.emit_call(&c);
                }
            }
            // ---------------- wake-on-LAN
            PeerMsg::RemoteHostInfo { session, macs } => {
                // only from a host that accepted our session
                let ok = self
                    .sessions
                    .lock()
                    .get(&session)
                    .map(|s| s.peer == from && s.role == Role::Viewer && s.accepted.load(Ordering::Relaxed))
                    .unwrap_or(false);
                if ok {
                    node.on_remote_host_info(from, macs);
                }
            }
            PeerMsg::WakeRequest { macs } => node.on_wake_request(acct, macs),
            PeerMsg::CallState { call_id, mic, cam, screen } => {
                node.emit("call_peer", json!({"call_id": hex::encode(call_id), "peer": from.to_base32(), "mic": mic, "cam": cam, "screen": screen}));
            }
            _ => {}
        }
        Ok(())
    }
}

/// May device `from` (account `acct`) join or answer call `c`? Only a device we
/// rang, one already in the call, or — for a group call — a member of that group.
fn call_may_join(node: &Node, c: &Call, from: &PeerId, acct: &PeerId) -> bool {
    if c.peers.lock().contains(from) || c.invited.lock().contains(from) {
        return true;
    }
    if node.store.is_blocked(acct) {
        return false;
    }
    match parse_conv(&c.conv) {
        Ok(ConvRef::Group(g, _)) => node.group_members(&g).contains(acct),
        _ => false,
    }
}

impl Session {
    /// Host: verified before connecting, recently enough to let the viewer reach us.
    pub(crate) fn pre_auth_live(&self) -> bool {
        self.pre_auth.lock().map(|p| p.at.elapsed() < PRE_AUTH_TTL).unwrap_or(false)
    }

    pub fn new(id: SessionId, peer: PeerId, role: Role, view_only: bool, stream: u32) -> Self {
        Session {
            id,
            peer,
            role,
            view_only,
            control: AtomicBool::new(false),
            nonce: Mutex::new(None),
            accepted: AtomicBool::new(false),
            stream,
            stop: Arc::new(AtomicBool::new(false)),
            width: AtomicU32::new(0),
            height: AtomicU32::new(0),
            display: AtomicU32::new(0),
            keyframe: Arc::new(AtomicBool::new(true)),
            bitrate: Arc::new(AtomicU32::new(8000)),
            #[cfg(feature = "media")]
            injector: Mutex::new(None),
            password_for_connect: Mutex::new(None),
            created: Instant::now(),
            ended: AtomicBool::new(false),
            pre_auth: Mutex::new(None),
        }
    }
}

impl Node {
    // ---------------------------------------------------------- remote desktop API

    pub async fn remote_connect(self: &Arc<Self>, id: &str, password: &str, view_only: bool, device: Option<&str>) -> Result<Value> {
        let resolved = self.resolve_id(id).await?;
        let peer = self.remote_target(resolved, device)?;
        anyhow::ensure!(peer != self.device, crate::i18n::user_err("err.self_control"));
        let session: SessionId = crate::crypto::random_bytes();
        let s = Arc::new(Session::new(session, peer, Role::Viewer, view_only, self.remote.alloc_stream()));
        *s.password_for_connect.lock() = Some(password.to_string());
        // no password + friend → ask the friend to accept instead of authenticating
        let acct = self.account_of(&peer);
        let ask_mode = password.trim().is_empty() && (self.store.is_friend(&acct) || acct == self.me);
        self.remote.sessions.lock().insert(session, s.clone());
        self.emit("remote_state", json!({"session": hex::encode(session), "peer": peer.to_base32(), "state": "connecting", "role": "viewer", "stream": s.stream}));
        // IP privacy: unless the host may know us anyway (friends, my own devices, already
        // connected, same LAN), prove the password over sealed signaling first — a host that
        // refuses never reveals where it is. Older hosts don't answer: connect-first as before.
        let known_old = (1..proto::PROTO_V3).contains(&self.peer_proto(&peer));
        let pre = !(ask_mode || acct == self.me || self.store.is_friend(&acct) || known_old || self.peer(&peer).is_some() || !self.net.lan.get(&peer).is_empty());
        let pw = password.to_string();
        let me = self.clone();
        tokio::spawn(async move {
            let r = async {
                if pre {
                    match me.remote_pre_auth(peer, session, view_only, &pw).await {
                        PreOutcome::Ok | PreOutcome::Unanswered => {}
                        PreOutcome::Denied(reason) => {
                            me.remote.viewer_denied(&me, &session, &peer, reason);
                            return Ok(());
                        }
                    }
                    if !me.remote.sessions.lock().contains_key(&session) {
                        return Ok(()); // cancelled meanwhile
                    }
                }
                let c = me.connect(peer).await?;
                let ask = ask_mode;
                #[cfg(feature = "media")]
                super::media_pipe::send_caps(&me, &c); // the host picks the format from these
                c.ctl.send(PeerMsg::RemoteRequest { session, proof: None, view_only, ask }).await.map_err(|_| crate::i18n::user_err("err.connection_lost"))?;
                Ok::<_, anyhow::Error>(())
            }
            .await;
            if let Err(e) = r {
                me.remote.sessions.lock().remove(&session);
                let e = crate::i18n::or_user(e, "err.peer_offline");
                let mut ev = json!({"session": hex::encode(session), "peer": peer.to_base32(), "state": "failed"});
                for (k, v) in crate::i18n::error_fields(&e) {
                    ev[if k == "error" { "reason" } else { k.as_str() }] = v;
                }
                me.emit("remote_state", ev);
            }
        });
        Ok(json!({"session": hex::encode(session), "peer": peer.to_base32(), "stream": s.stream}))
    }

    /// Which device to control: the one asked for, the only one that can be controlled, or
    /// (several) `err.choose_device` with the choices as JSON in `detail`.
    fn remote_target(&self, resolved: PeerId, device: Option<&str>) -> Result<PeerId> {
        let acct = self.account_of(&resolved);
        if let Some(d) = device.map(str::trim).filter(|d| !d.is_empty()) {
            let d = PeerId::from_str_any(d).map_err(|_| crate::i18n::user_err("err.device_not_found"))?;
            anyhow::ensure!(d == resolved || self.account_of(&d) == acct, crate::i18n::user_err("err.device_not_found"));
            return Ok(d);
        }
        if resolved != acct {
            return Ok(resolved); // a device's own ID
        }
        let hosts: Vec<_> = self
            .store
            .devices_of(&acct)
            .into_iter()
            .filter(|d| d.listed && d.revoked.is_none() && d.device != self.device && d.caps & crate::devices::CAP_REMOTE_HOST != 0)
            .collect();
        match hosts.len() {
            0 => Ok(resolved),
            1 => Ok(hosts[0].device),
            _ => {
                let choices: Vec<Value> = hosts
                    .iter()
                    .map(|d| json!({"device": d.device.to_base32(), "name": d.name, "kind": d.kind, "short_id": d.device.short_id_fmt(), "online": self.peer(&d.device).is_some()}))
                    .collect();
                bail!(crate::i18n::user_err("err.choose_device").detail(serde_json::to_string(&choices).unwrap_or_default()))
            }
        }
    }

    pub async fn remote_respond(self: &Arc<Self>, session: &SessionId, accept: bool, control: bool) -> Result<()> {
        let s = self.remote.sessions.lock().get(session).cloned().ok_or_else(|| crate::i18n::user_err("err.no_session"))?;
        if accept {
            self.accept_session(session, control && !s.view_only && self.remote.allow_control.load(Ordering::Relaxed)).await
        } else {
            self.remote.sessions.lock().remove(session);
            self.send_now_dev(&s.peer, PeerMsg::RemoteDeny { session: *session, reason: "err.partner_declined".into() });
            Ok(())
        }
    }

    pub(crate) async fn accept_session(self: &Arc<Self>, session: &SessionId, control: bool) -> Result<()> {
        let s = self.remote.sessions.lock().get(session).cloned().ok_or_else(|| crate::i18n::user_err("err.no_session"))?;
        s.accepted.store(true, Ordering::SeqCst);
        s.control.store(control, Ordering::SeqCst);
        #[cfg(feature = "media")]
        let (w, h, displays) = match super::media_pipe::start_host(self, &s).await {
            Ok(x) => x,
            Err(e) => {
                self.remote.sessions.lock().remove(session);
                self.send_now_dev(&s.peer, PeerMsg::RemoteDeny { session: *session, reason: "err.capture_failed".into() });
                self.emit("remote_state", json!({
                    "session": hex::encode(session), "state": "failed", "reason": crate::i18n::tr("err.capture_failed"),
                    "code": "err.capture_failed", "detail": format!("{e:#}"), "role": "host",
                }));
                return Ok(());
            }
        };
        #[cfg(not(feature = "media"))]
        let (w, h, displays): (u32, u32, Vec<(u32, u32, String)>) = (0, 0, vec![]);
        s.width.store(w, Ordering::SeqCst);
        s.height.store(h, Ordering::SeqCst);
        self.send_now_dev(&s.peer, PeerMsg::RemoteAccept { session: *session, width: w, height: h, displays, control });
        self.share_wake_info(*session, s.peer);
        self.emit("remote_state", json!({
            "session": hex::encode(session), "peer": s.peer.to_base32(), "state": "active", "role": "host",
            "width": w, "height": h, "control": control,
        }));
        Ok(())
    }

    pub fn end_session(self: &Arc<Self>, session: &SessionId, notify: bool) {
        let removed = self.remote.sessions.lock().remove(session);
        // a pre-authentication in flight stops waiting
        self.remote.pre_waits.lock().remove(session);
        if let Some(s) = removed {
            s.ended.store(true, Ordering::SeqCst);
            s.stop.store(true, Ordering::SeqCst);
            if notify {
                self.send_now_dev(&s.peer, PeerMsg::RemoteEnd { session: *session });
            }
            self.remote.frames.lock().remove(&s.stream);
            #[cfg(feature = "media")]
            {
                for st in self.remote.media.cleanup(session, &[]) {
                    self.remote.frames.lock().remove(&st);
                }
            }
            self.emit("remote_state", json!({"session": hex::encode(session), "peer": s.peer.to_base32(), "state": "ended", "role": s.role}));
        }
    }

    pub fn remote_input(self: &Arc<Self>, session: &SessionId, ev: &Value) -> Result<()> {
        let s = self.remote.sessions.lock().get(session).cloned().ok_or_else(|| crate::i18n::user_err("err.no_session"))?;
        anyhow::ensure!(s.role == Role::Viewer && s.accepted.load(Ordering::Relaxed), crate::i18n::user_err("err.no_session"));
        anyhow::ensure!(s.control.load(Ordering::Relaxed), crate::i18n::user_err("err.view_only"));
        let pc = self.peer(&s.peer).ok_or_else(|| crate::i18n::user_err("err.connection_lost"))?;
        let mut d = vec![proto::dgram::INPUT];
        d.extend_from_slice(session);
        d.extend(rmp_serde::to_vec(ev)?);
        // pointer moves/wheel: datagrams (newest wins, lowest latency);
        // keys/buttons/text: reliable control stream so a lost "key up" never sticks a key
        let t = ev["t"].as_str().unwrap_or("");
        if (t == "move" || t == "wheel") && pc.conn.send_datagram(Bytes::from(d)).is_ok() {
            return Ok(());
        }
        let _ = pc.ctl.try_send(PeerMsg::RemoteInput { session: *session, ev: rmp_serde::to_vec(ev)? });
        Ok(())
    }

    pub fn remote_power(&self, session: &SessionId, action: &str) -> Result<()> {
        let s = self.remote.sessions.lock().get(session).cloned().ok_or_else(|| crate::i18n::user_err("err.no_session"))?;
        anyhow::ensure!(s.role == Role::Viewer && s.control.load(Ordering::Relaxed), crate::i18n::user_err("err.view_only"));
        self.send_now_dev(&s.peer, PeerMsg::RemoteAction { session: *session, action: action.to_string() });
        Ok(())
    }

    pub fn remote_select_display(&self, session: &SessionId, index: u32) -> Result<()> {
        let s = self.remote.sessions.lock().get(session).cloned().ok_or_else(|| crate::i18n::user_err("err.no_session"))?;
        self.send_now_dev(&s.peer, PeerMsg::RemoteSelectDisplay { session: *session, index });
        Ok(())
    }

    // ---------------------------------------------------------- calls API

    pub fn emit_call(&self, c: &Call) {
        self.emit("call", self.call_json(c));
    }

    fn call_json(&self, c: &Call) -> Value {
        let peers: Vec<Value> = c
            .peers
            .lock()
            .iter()
            .map(|p| {
                let acct = self.account_of(p);
                json!({"peer": p.to_base32(), "account": acct.to_base32(), "name": self.store.contact(&acct).map(|c| c.alias.unwrap_or(c.name)).unwrap_or_default()})
            })
            .collect();
        json!({
            "call_id": hex::encode(c.id), "conv": c.conv, "state": c.state.lock().clone(), "video": c.video,
            "participants": peers, "mic": c.mic.load(Ordering::Relaxed), "cam": c.cam.load(Ordering::Relaxed),
            "screen": c.screen.load(Ordering::Relaxed), "duration_s": c.started.elapsed().as_secs(),
            "from": c.incoming_from.map(|p| self.account_of(&p).to_base32()),
        })
    }

    pub async fn call_start(self: &Arc<Self>, conv: &str, video: bool) -> Result<Value> {
        anyhow::ensure!(self.remote.calls.lock().is_empty(), crate::i18n::user_err("err.in_other_call"));
        let call_id: [u8; 16] = crate::crypto::random_bytes();
        let (targets, group) = match parse_conv(conv)? {
            ConvRef::Direct(p) => (vec![p], None),
            ConvRef::Group(g, _) => (self.group_members(&g).into_iter().filter(|m| *m != self.me).collect(), Some(g)),
            ConvRef::Saved => bail!(crate::i18n::user_err("err.cannot_call_saved")),
        };
        let c = Arc::new(Call {
            id: call_id,
            conv: conv.to_string(),
            peers: Mutex::new(vec![]),
            video,
            state: Mutex::new("ringing".into()),
            mic: AtomicBool::new(true),
            cam: AtomicBool::new(video),
            screen: AtomicBool::new(false),
            started: Instant::now(),
            stop: Arc::new(AtomicBool::new(false)),
            incoming_from: None,
            media_started: AtomicBool::new(false),
            invited: Mutex::new(vec![]),
        });
        // every device of every callee rings (the first to answer wins); never my own devices
        let mut rung: Vec<(PeerId, PeerId)> = vec![];
        for t in targets.into_iter().take(24) {
            for d in self.delivery_targets(&t).into_iter().take(crate::devices::MAX_DEVICES) {
                if d != self.device && self.account_of(&d) != self.me {
                    rung.push((t, d));
                }
            }
        }
        *c.invited.lock() = rung.iter().map(|(_, d)| *d).collect();
        self.remote.calls.lock().insert(call_id, c.clone());
        self.emit_call(&c);
        let mut woken: Vec<PeerId> = vec![];
        for (t, dev) in rung {
            let me = self.clone();
            let wake = !woken.contains(&t);
            woken.push(t);
            tokio::spawn(async move {
                // An offline iPhone with push enabled: ring it through the bridge (PushKit →
                // CallKit), then keep re-inviting while it starts Lumora and comes online.
                let woke = wake && me.push_call_wake(t, call_id, video).await;
                let mut tries = 0;
                loop {
                    let sent = async {
                        let pc = me.connect(dev).await?;
                        #[cfg(feature = "media")]
                        super::media_pipe::send_caps(&me, &pc); // codec choice needs no extra round trip
                        pc.ctl.send(PeerMsg::CallInvite { call_id, video, group }).await.map_err(|_| anyhow!("connection lost"))
                    };
                    match sent.await {
                        Ok(()) => break,
                        Err(e) => tracing::debug!("call invite to {dev:?}: {e:#}"),
                    }
                    tries += 1;
                    let ringing = me.remote.calls.lock().get(&call_id).map(|c| *c.state.lock() == "ringing").unwrap_or(false);
                    if !woke || !ringing || tries >= 12 {
                        break;
                    }
                    tokio::time::sleep(Duration::from_secs(3)).await;
                }
            });
        }
        let me = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(45)).await;
            let unanswered = me.remote.calls.lock().get(&call_id).map(|c| *c.state.lock() == "ringing").unwrap_or(false);
            if unanswered {
                me.end_call(&call_id, true);
            }
        });
        Ok(json!({"call_id": hex::encode(call_id)}))
    }

    pub async fn call_answer(self: &Arc<Self>, call_id: &[u8; 16], accept: bool) -> Result<()> {
        let c = self.remote.calls.lock().get(call_id).cloned().ok_or_else(|| crate::i18n::user_err("err.call_ended"))?;
        let peers = c.peers.lock().clone();
        if c.incoming_from.is_some() {
            // my other devices are ringing too: they stop and say where it was answered
            let name = self.own_list().and_then(|b| b.devices.into_iter().find(|e| e.device == self.device)).map(|e| e.name).unwrap_or_default();
            let m = proto::ext(proto::ext::CALL_ELSEWHERE, &CallElsewhere { call_id: call_id.to_vec(), answered: accept, device_name: name });
            for pc in self.peers_of(&self.me) {
                let _ = pc.ctl.try_send(m.clone());
            }
        }
        for p in peers.iter() {
            #[cfg(feature = "media")]
            if accept {
                super::media_pipe::send_caps_to(self, p);
            }
            self.send_now_dev(p, PeerMsg::CallAnswer { call_id: *call_id, accept });
        }
        if accept {
            *c.state.lock() = "active".into();
            #[cfg(feature = "media")]
            super::media_pipe::start_call_media(self, &c);
            self.emit_call(&c);
        } else {
            self.end_call(call_id, false);
        }
        Ok(())
    }

    /// One of my other devices answered (or declined) this incoming call.
    pub(crate) fn on_call_elsewhere(self: &Arc<Self>, body: &[u8]) -> Result<()> {
        let m: CallElsewhere = proto::ext_body(body)?;
        let call_id: [u8; 16] = m.call_id.as_slice().try_into().map_err(|_| anyhow!("bad call id"))?;
        let c = {
            let mut calls = self.remote.calls.lock();
            match calls.get(&call_id) {
                Some(c) if c.incoming_from.is_some() && *c.state.lock() == "incoming" => calls.remove(&call_id),
                _ => None,
            }
        };
        let Some(c) = c else { return Ok(()) };
        c.stop.store(true, Ordering::SeqCst);
        *c.state.lock() = "ended".into();
        let mut ev = self.call_json(&c);
        ev["reason"] = json!(if m.answered { "answered_elsewhere" } else { "declined_elsewhere" });
        ev["device_name"] = json!(m.device_name.chars().take(32).collect::<String>());
        self.emit("call", ev);
        Ok(())
    }

    /// `peer` left call `c`, which goes on: free its decoders/speaker right away and
    /// tell the app its streams ended.
    pub(crate) fn call_peer_left(&self, c: &Call, peer: &PeerId) {
        #[cfg(feature = "media")]
        for (st, camera) in self.remote.media.remove_peer(&c.id, peer) {
            self.remote.frames.lock().remove(&st);
            self.emit("video_stream", json!({
                "call_id": hex::encode(c.id), "peer": peer.to_base32(), "stream": -1, "ended_stream": st,
                "kind": if camera { "camera" } else { "screen" },
            }));
        }
        #[cfg(not(feature = "media"))]
        let _ = (c, peer);
    }

    pub fn end_call(self: &Arc<Self>, call_id: &[u8; 16], missed: bool) {
        let removed = self.remote.calls.lock().remove(call_id);
        let Some(c) = removed else { return };
        c.stop.store(true, Ordering::SeqCst);
        #[cfg(feature = "media")]
        {
            let peers = c.peers.lock().clone();
            for st in self.remote.media.cleanup(call_id, &peers) {
                self.remote.frames.lock().remove(&st);
            }
        }
        let mut notify: Vec<PeerId> = c.peers.lock().clone();
        for p in c.invited.lock().iter() {
            if !notify.contains(p) {
                notify.push(*p);
            }
        }
        for p in notify {
            self.send_now(&p, PeerMsg::CallEnd { call_id: *call_id });
        }
        *c.state.lock() = "ended".into();
        self.emit_call(&c);
        // call log entry in the conversation
        let dur = c.started.elapsed().as_secs() as u32;
        let me = self.clone();
        let conv = c.conv.clone();
        let video = c.video;
        let incoming = c.incoming_from.is_some();
        tokio::spawn(async move {
            if let ConvRef::Direct(_) = parse_conv(&conv).unwrap_or(ConvRef::Direct(me.me)) {
                if !incoming {
                    let _ = me.send_body(&conv, crate::proto::Body::Call { video, duration_s: if missed { 0 } else { dur }, missed }, None, None).await;
                }
            }
        });
    }

    pub fn call_set(self: &Arc<Self>, call_id: &[u8; 16], mic: Option<bool>, cam: Option<bool>, screen: Option<bool>) -> Result<()> {
        let c = self.remote.calls.lock().get(call_id).cloned().ok_or_else(|| crate::i18n::user_err("err.call_ended"))?;
        if let Some(m) = mic {
            c.mic.store(m, Ordering::SeqCst);
        }
        if let Some(v) = cam {
            let was = c.cam.swap(v, Ordering::SeqCst);
            #[cfg(feature = "media")]
            if was != v && *c.state.lock() == "active" {
                super::media_pipe::toggle_call_camera(self, &c, v);
            }
            #[cfg(not(feature = "media"))]
            let _ = was;
        }
        if let Some(s) = screen {
            c.screen.store(s, Ordering::SeqCst);
            #[cfg(feature = "media")]
            super::media_pipe::toggle_call_screen(self, &c, s);
        }
        for p in c.peers.lock().iter() {
            self.send_now_dev(
                p,
                PeerMsg::CallState {
                    call_id: *call_id,
                    mic: c.mic.load(Ordering::Relaxed),
                    cam: c.cam.load(Ordering::Relaxed),
                    screen: c.screen.load(Ordering::Relaxed),
                },
            );
        }
        self.emit_call(&c);
        Ok(())
    }
}

// ---------------------------------------------------------------- IP privacy: pre-auth
impl Node {
    /// Send one message sealed to `dev` through the signaling channels only (relays, Nostr):
    /// no connection, so nobody learns an address. Same envelope as offline mail
    /// (`Signal::Mail`, see `store_and_forward`), arriving in `on_mail` → `on_ext_mail`.
    /// Returns the number of channels that took it (0: no signaling available).
    pub(crate) async fn send_sealed_signal(self: &Arc<Self>, dev: &PeerId, m: &PeerMsg) -> usize {
        let env = (|| -> Result<Vec<u8>> {
            let sealed = seal_to(&self.id, dev, &rmp_serde::to_vec(m)?)?;
            seal_to(&self.id, dev, &rmp_serde::to_vec(&Signal::Mail { payload: sealed })?)
        })();
        match env {
            Ok(env) => self.net.send_signal(dev, env, &[]).await,
            Err(_) => 0,
        }
    }

    /// Remote-control pre-authentication messages (sealed mail from device `dev`).
    pub(crate) async fn on_remote_pre_mail(self: &Arc<Self>, dev: PeerId, kind: u16, body: &[u8]) -> Result<()> {
        match kind {
            proto::ext::REMOTE_PRE_REQ => self.on_pre_req(dev, proto::ext_body(body)?).await,
            proto::ext::REMOTE_PRE_AUTH => self.on_pre_auth(dev, proto::ext_body(body)?).await,
            proto::ext::REMOTE_PRE_CHALLENGE => self.on_pre_challenge(dev, proto::ext_body(body)?).await?,
            proto::ext::REMOTE_PRE_RESULT => {
                let m: PreResult = proto::ext_body(body)?;
                let tx = self.remote.pre_waits.lock().get(&m.session).filter(|w| w.host == dev).map(|w| w.tx.clone());
                if let Some(tx) = tx {
                    let _ = tx.send(PreEvent::Result { ok: m.ok, reason: m.reason });
                }
            }
            _ => {}
        }
        Ok(())
    }

    async fn pre_reply(self: &Arc<Self>, dev: &PeerId, session: SessionId, ok: bool, reason: &str) {
        let m = proto::ext(proto::ext::REMOTE_PRE_RESULT, &PreResult { session, ok, reason: reason.into() });
        self.send_sealed_signal(dev, &m).await;
    }

    /// The account behind a device that isn't connected: what we know, or its certificate.
    fn pre_account(&self, dev: &PeerId, cert: &[u8]) -> PeerId {
        let known = self.account_of(dev);
        if known != *dev || cert.is_empty() {
            return known;
        }
        match crate::devices::DeviceCert::decode(cert) {
            Ok(c) if c.device == *dev && c.verify() && !self.is_revoked(&c.account, dev) => c.account,
            _ => *dev,
        }
    }

    /// Host: someone (usually a stranger) asks to control this device without connecting.
    async fn on_pre_req(self: &Arc<Self>, dev: PeerId, m: PreReq) {
        if now_ms().abs_diff(m.ts) > 120_000 || self.remote.pre_seen.lock().put(m.session, ()).is_some() {
            return; // stale (late mailbox copy) / the same request through another channel
        }
        let st = &self.remote;
        if st.sessions.lock().contains_key(&m.session) {
            return;
        }
        let acct = self.pre_account(&dev, &m.cert);
        let trusted = self.store.remote_trusted(&acct).is_some() || self.store.remote_trusted(&dev).is_some();
        st.prune_pending();
        if !st.allow_incoming.load(Ordering::Relaxed) || self.store.is_blocked(&acct) || (st.locked_out(&dev) && !trusted) || st.pending_count() >= 8 {
            self.pre_reply(&dev, m.session, false, "err.remote_disabled").await;
            return;
        }
        let s = Arc::new(Session::new(m.session, dev, Role::Host, m.view_only, st.alloc_stream()));
        if trusted {
            *s.pre_auth.lock() = Some(PreAuth { at: Instant::now(), auto: true, used: false });
            st.sessions.lock().insert(m.session, s);
            self.pre_reply(&dev, m.session, true, "").await;
            return;
        }
        let nonce: [u8; 16] = crate::crypto::random_bytes();
        *s.nonce.lock() = Some(nonce);
        st.sessions.lock().insert(m.session, s);
        let kdf = st.fixed_v2.lock().as_ref().map(|f| f.kdf.clone());
        let c = proto::ext(proto::ext::REMOTE_PRE_CHALLENGE, &ChallengeV2 { session: m.session, nonce, kdf });
        self.send_sealed_signal(&dev, &c).await;
    }

    /// Host: the answer to a pre-challenge. Verified → the viewer may now reach us.
    async fn on_pre_auth(self: &Arc<Self>, dev: PeerId, m: AuthV2) {
        let acct = self.account_of(&dev);
        match self.remote.check_answer(&self.store, &self.device, &dev, &acct, &m.session, &m.proof, &m.sig) {
            Verdict::Ignore => {}
            Verdict::Deny(reason) => self.pre_reply(&dev, m.session, false, reason).await,
            Verdict::Ok { s, auto } => {
                *s.pre_auth.lock() = Some(PreAuth { at: Instant::now(), auto, used: false });
                self.pre_reply(&dev, m.session, true, "").await;
            }
        }
    }

    /// Viewer: the host's challenge (answered once, whatever channel brought it first).
    async fn on_pre_challenge(self: &Arc<Self>, dev: PeerId, m: ChallengeV2) -> Result<()> {
        let (pw, tx) = {
            let mut w = self.remote.pre_waits.lock();
            let Some(x) = w.get_mut(&m.session).filter(|x| x.host == dev && !x.challenged) else { return Ok(()) };
            x.challenged = true;
            (x.password.clone(), x.tx.clone())
        };
        let _ = tx.send(PreEvent::Challenged);
        let (viewer, host) = (self.device, dev);
        let p = proof(&pw_key(&pw), &m.nonce, &viewer, &host);
        // the Argon2id work happens off the async runtime
        let sig = match m.kdf.filter(|k| k.sane()) {
            Some(kdf) if !pw.trim().is_empty() => {
                let nonce = m.nonce;
                tokio::task::spawn_blocking(move || v2_sign(&pw, &kdf, &nonce, &viewer, &host)).await??
            }
            _ => vec![],
        };
        let a = proto::ext(proto::ext::REMOTE_PRE_AUTH, &AuthV2 { session: m.session, proof: p.to_vec(), sig });
        self.send_sealed_signal(&dev, &a).await;
        self.emit("remote_state", json!({"session": hex::encode(m.session), "peer": dev.to_base32(), "state": "waiting", "role": "viewer"}));
        Ok(())
    }

    /// Viewer: prove the password to `host` before connecting, so a host that refuses
    /// never reveals where it is.
    async fn remote_pre_auth(self: &Arc<Self>, host: PeerId, session: SessionId, view_only: bool, password: &str) -> PreOutcome {
        let (tx, mut rx) = mpsc::unbounded_channel();
        self.remote.pre_waits.lock().insert(session, PreWait { host, password: password.to_string(), tx, challenged: false });
        let cert = self.store.kv_get("account.cert").unwrap_or_default();
        let req = proto::ext(proto::ext::REMOTE_PRE_REQ, &PreReq { session, view_only, ts: now_ms(), cert });
        let out = if self.send_sealed_signal(&host, &req).await == 0 {
            PreOutcome::Unanswered
        } else {
            let mut wait = PRE_FIRST_WAIT;
            loop {
                match tokio::time::timeout(wait, rx.recv()).await {
                    Ok(Some(PreEvent::Challenged)) => wait = PRE_RESULT_WAIT,
                    Ok(Some(PreEvent::Result { ok: true, .. })) => break PreOutcome::Ok,
                    Ok(Some(PreEvent::Result { reason, .. })) => break PreOutcome::Denied(reason),
                    // timeout, or the session was ended meanwhile
                    _ => break PreOutcome::Unanswered,
                }
            }
        };
        self.remote.pre_waits.lock().remove(&session);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn proof_binds_everything() {
        let a = PeerId([1; 32]);
        let b = PeerId([2; 32]);
        let k = pw_key("abc123");
        let n = [7u8; 16];
        assert_eq!(proof(&k, &n, &a, &b), proof(&pw_key(" abc123 "), &n, &a, &b));
        assert_ne!(proof(&k, &n, &a, &b), proof(&k, &n, &b, &a));
        assert_ne!(proof(&k, &n, &a, &b), proof(&pw_key("abc124"), &n, &a, &b));
    }
}

#[cfg(test)]
mod v2_tests {
    use super::*;

    #[test]
    fn v2_host_keeps_only_a_verifier() {
        let store = Store::open_memory().unwrap();
        let st = RemoteState::new(&store);
        st.set(&store, Some("mat-khau-co-dinh"), None, None, None).unwrap();
        let raw = store.kv_get("remote.fixed_v2").unwrap();
        let f: FixedVerifier = rmp_serde::from_slice(&raw).unwrap();
        // nothing password-equivalent at rest: no v1 key, and the stored verifier can't
        // produce a valid answer without the password
        assert!(store.kv_get("remote.fixed_key").is_none());
        assert!(!raw.windows(32).any(|w| w == pw_key("mat-khau-co-dinh")));
        let (viewer, host, nonce) = (PeerId([1; 32]), PeerId([2; 32]), [7u8; 16]);
        let good = v2_sign("mat-khau-co-dinh", &f.kdf, &nonce, &viewer, &host).unwrap();
        let vk = PeerId(f.verifier.clone().try_into().unwrap());
        assert!(vk.verify(&v2_signed_bytes(&nonce, &viewer, &host), &good));
        let bad = v2_sign("mat-khau-sai-roi", &f.kdf, &nonce, &viewer, &host).unwrap();
        assert!(!vk.verify(&v2_signed_bytes(&nonce, &viewer, &host), &bad));
        // bound to the nonce and both devices
        assert!(!vk.verify(&v2_signed_bytes(&[8; 16], &viewer, &host), &good));
        assert!(!vk.verify(&v2_signed_bytes(&nonce, &host, &viewer), &good));
        // survives a restart; clearing removes it
        assert!(RemoteState::new(&store).fixed_v2.lock().is_some());
        st.set(&store, Some(""), None, None, None).unwrap();
        assert!(store.kv_get("remote.fixed_v2").is_none());
    }

    #[test]
    fn v2_rejects_abusive_kdf_parameters() {
        let huge = KdfParams { salt: vec![1; 16], m: 4 * 1024 * 1024, t: 2, p: 1 };
        assert!(v2_sign("x", &huge, &[0; 16], &PeerId([1; 32]), &PeerId([2; 32])).is_err());
        let slow = KdfParams { salt: vec![1; 16], m: 19 * 1024, t: 1000, p: 1 };
        assert!(!slow.sane());
        assert!(KdfParams::fresh().sane());
    }

    #[test]
    fn legacy_key_is_upgraded_when_the_password_is_set_again() {
        let store = Store::open_memory().unwrap();
        store.kv_set("remote.fixed_key", &pw_key("mat-khau-cu-123")).unwrap();
        let st = RemoteState::new(&store);
        assert!(st.fixed_key.lock().is_some());
        st.set(&store, Some("mat-khau-moi-456"), None, None, None).unwrap();
        assert!(st.fixed_key.lock().is_none() && store.kv_get("remote.fixed_key").is_none());
        assert!(st.fixed_v2.lock().is_some());
    }
}

#[cfg(test)]
mod security_tests {
    //! Adversarial tests from the security audit (remote-control password guessing).
    use super::*;

    /// PoC: with free identities an attacker got 10 guesses every 5 minutes forever
    /// (~2 900/day, ~1 M/year) against a fixed unattended-access password.
    #[test]
    fn global_lockout_escalates_after_repeated_attacks() {
        let st = RemoteState::new(&Store::open_memory().unwrap());
        let fresh = PeerId([9; 32]);
        for i in 0..10u8 {
            st.fail(&PeerId([i; 32]));
        }
        assert!(st.locked_out(&fresh), "10 failures from different ids must lock everyone out");
        // first lockout over (5 min) → the next burst of 10 locks out for longer
        st.global_fail.lock().1 = Instant::now() - Duration::from_secs(301);
        assert!(!st.locked_out(&fresh));
        for i in 10..20u8 {
            st.fail(&PeerId([i; 32]));
        }
        st.global_fail.lock().1 = Instant::now() - Duration::from_secs(301);
        assert!(st.locked_out(&fresh), "second lockout must last longer than the first");
    }
}

#[cfg(test)]
mod pre_auth_tests {
    //! IP privacy: a host only becomes reachable for a stranger after the password was
    //! verified over sealed signaling (no connection, no addresses).
    use super::*;
    use crate::proto::ext;

    async fn node(tmp: &std::path::Path) -> Arc<Node> {
        let cfg = NodeConfig {
            data_dir: tmp.join("data"),
            downloads_dir: Some(tmp.join("dl")),
            enable_lan: false,
            enable_upnp: false,
            enable_dht: false,
            enable_nostr: false,
            relays: Some(vec![]),
            nostr: Some(vec![]),
            stun: Some(vec![]),
            ..Default::default()
        };
        Node::start(cfg).await.unwrap()
    }

    fn named<T: Serialize>(v: &T) -> Vec<u8> {
        rmp_serde::to_vec_named(v).unwrap()
    }

    fn req(session: SessionId, ts: u64) -> Vec<u8> {
        named(&PreReq { session, view_only: false, ts, cert: vec![] })
    }

    fn nonce_of(h: &Node, session: &SessionId) -> [u8; 16] {
        h.remote.sessions.lock().get(session).and_then(|s| *s.nonce.lock()).expect("challenge issued")
    }

    #[tokio::test]
    async fn stranger_reaches_the_host_only_after_the_password() {
        let tmp = tempfile::tempdir().unwrap();
        let h = node(tmp.path()).await;
        let viewer = Identity::generate().peer_id();
        let other = Identity::generate().peer_id();

        // wrong password: denied, nothing revealed, session gone
        let s1 = [1u8; 16];
        h.on_remote_pre_mail(viewer, ext::REMOTE_PRE_REQ, &req(s1, now_ms())).await.unwrap();
        assert!(!h.remote.reveals_addrs_to(&viewer), "the request alone must not reveal anything");
        let n1 = nonce_of(&h, &s1);
        let bad = AuthV2 { session: s1, proof: proof(&pw_key("doan-sai-1"), &n1, &viewer, &h.device).to_vec(), sig: vec![] };
        h.on_remote_pre_mail(viewer, ext::REMOTE_PRE_AUTH, &named(&bad)).await.unwrap();
        assert!(!h.remote.reveals_addrs_to(&viewer));
        assert!(!h.remote.sessions.lock().contains_key(&s1));
        assert_eq!(h.remote.failures.lock().get(&viewer).map(|f| f.0), Some(1), "a wrong guess counts toward the lockout");
        // the same request again (another channel / replay): ignored
        h.on_remote_pre_mail(viewer, ext::REMOTE_PRE_REQ, &req(s1, now_ms())).await.unwrap();
        assert!(!h.remote.sessions.lock().contains_key(&s1));
        // a stale request (late mailbox copy): ignored
        let old = [9u8; 16];
        h.on_remote_pre_mail(viewer, ext::REMOTE_PRE_REQ, &req(old, now_ms() - 10 * 60_000)).await.unwrap();
        assert!(!h.remote.sessions.lock().contains_key(&old));

        // right (temporary) password: the viewer — and only the viewer — may now connect
        let s2 = [2u8; 16];
        h.on_remote_pre_mail(viewer, ext::REMOTE_PRE_REQ, &req(s2, now_ms())).await.unwrap();
        assert!(!h.remote.reveals_addrs_to(&viewer));
        let n2 = nonce_of(&h, &s2);
        // an answer from another device for this session is ignored (and keeps the nonce)
        let foreign = AuthV2 { session: s2, proof: proof(&pw_key(&h.remote.password()), &n2, &other, &h.device).to_vec(), sig: vec![] };
        h.on_remote_pre_mail(other, ext::REMOTE_PRE_AUTH, &named(&foreign)).await.unwrap();
        assert!(!h.remote.reveals_addrs_to(&other) && !h.remote.reveals_addrs_to(&viewer));
        let good = AuthV2 { session: s2, proof: proof(&pw_key(&h.remote.password()), &n2, &viewer, &h.device).to_vec(), sig: vec![] };
        h.on_remote_pre_mail(viewer, ext::REMOTE_PRE_AUTH, &named(&good)).await.unwrap();
        assert!(h.remote.reveals_addrs_to(&viewer));
        assert!(!h.remote.reveals_addrs_to(&other));
        assert!(h.remote.failures.lock().get(&viewer).is_none(), "success clears the failure count");

        // the RemoteRequest over the connection uses it once, from that device only
        assert!(h.remote.take_pre_auth(&s2, &other).is_none());
        assert!(h.remote.id_taken(&s2, &other), "another device can't take the session id over");
        let (_, auto) = h.remote.take_pre_auth(&s2, &viewer).unwrap();
        assert!(!auto, "temporary password: the host user still decides");
        assert!(h.remote.take_pre_auth(&s2, &viewer).is_none(), "used once");

        // expiry: not accepted within PRE_AUTH_TTL → nothing revealed any more
        let s = h.remote.sessions.lock().get(&s2).cloned().unwrap();
        s.pre_auth.lock().as_mut().unwrap().at = Instant::now() - PRE_AUTH_TTL - Duration::from_secs(1);
        assert!(!h.remote.reveals_addrs_to(&viewer));
        // accepted → revealed for the session's life, until it ends
        s.accepted.store(true, Ordering::SeqCst);
        assert!(h.remote.reveals_addrs_to(&viewer));
        s.ended.store(true, Ordering::SeqCst);
        assert!(!h.remote.reveals_addrs_to(&viewer));
        h.shutdown();
    }

    #[tokio::test]
    async fn fixed_password_unattended_and_trusted_devices() {
        let tmp = tempfile::tempdir().unwrap();
        let h = node(tmp.path()).await;
        h.remote.set(&h.store, Some("mat-khau-co-dinh"), Some(true), None, None).unwrap();
        let viewer = Identity::generate().peer_id();
        let s1 = [1u8; 16];
        h.on_remote_pre_mail(viewer, ext::REMOTE_PRE_REQ, &req(s1, now_ms())).await.unwrap();
        let n1 = nonce_of(&h, &s1);
        let kdf = h.remote.fixed_v2.lock().as_ref().unwrap().kdf.clone();
        let sig = v2_sign("mat-khau-co-dinh", &kdf, &n1, &viewer, &h.device).unwrap();
        let a = AuthV2 { session: s1, proof: proof(&pw_key("mat-khau-co-dinh"), &n1, &viewer, &h.device).to_vec(), sig };
        h.on_remote_pre_mail(viewer, ext::REMOTE_PRE_AUTH, &named(&a)).await.unwrap();
        assert!(h.remote.reveals_addrs_to(&viewer));
        assert!(h.remote.take_pre_auth(&s1, &viewer).unwrap().1, "fixed password + unattended: accepted without asking");

        // a trusted device needs no password at all (no challenge)
        let trusted = Identity::generate().peer_id();
        h.store.remote_trust(&trusted, Some(1)).unwrap();
        let s2 = [2u8; 16];
        h.on_remote_pre_mail(trusted, ext::REMOTE_PRE_REQ, &req(s2, now_ms())).await.unwrap();
        assert!(h.remote.reveals_addrs_to(&trusted));
        assert!(h.remote.sessions.lock().get(&s2).unwrap().nonce.lock().is_none());
        h.shutdown();
    }

    #[tokio::test]
    async fn lockouts_and_pending_limit_apply_before_connecting() {
        let tmp = tempfile::tempdir().unwrap();
        let h = node(tmp.path()).await;
        let viewer = Identity::generate().peer_id();
        for _ in 0..5 {
            h.remote.fail(&viewer);
        }
        h.on_remote_pre_mail(viewer, ext::REMOTE_PRE_REQ, &req([1; 16], now_ms())).await.unwrap();
        assert!(!h.remote.sessions.lock().contains_key(&[1; 16]), "locked out: no challenge");
        // at most 8 pending pre-requests from strangers
        for i in 0..8u8 {
            let d = Identity::generate().peer_id();
            h.on_remote_pre_mail(d, ext::REMOTE_PRE_REQ, &req([10 + i; 16], now_ms())).await.unwrap();
        }
        assert_eq!(h.remote.pending_count(), 8);
        let late = Identity::generate().peer_id();
        h.on_remote_pre_mail(late, ext::REMOTE_PRE_REQ, &req([50; 16], now_ms())).await.unwrap();
        assert!(!h.remote.sessions.lock().contains_key(&[50; 16]));
        // remote control switched off: refused
        h.remote.allow_incoming.store(false, Ordering::SeqCst);
        h.remote.sessions.lock().clear();
        h.on_remote_pre_mail(late, ext::REMOTE_PRE_REQ, &req([51; 16], now_ms())).await.unwrap();
        assert!(!h.remote.sessions.lock().contains_key(&[51; 16]));
        h.shutdown();
    }

    #[tokio::test]
    async fn viewer_answers_one_challenge_and_falls_back_without_signaling() {
        let tmp = tempfile::tempdir().unwrap();
        let v = node(tmp.path()).await;
        let host = Identity::generate().peer_id();
        // no relay / Nostr: nothing can carry the pre-request → connect-first fallback, at once
        let t = Instant::now();
        assert!(matches!(v.remote_pre_auth(host, [1; 16], false, "abc").await, PreOutcome::Unanswered));
        assert!(t.elapsed() < Duration::from_secs(2));
        assert!(v.remote.pre_waits.lock().is_empty());
        // the waiter: one challenge (whatever channel brings it first), the host's verdict
        let (tx, mut rx) = mpsc::unbounded_channel();
        let s = [2u8; 16];
        v.remote.pre_waits.lock().insert(s, PreWait { host, password: "abc".into(), tx, challenged: false });
        let ch = named(&ChallengeV2 { session: s, nonce: [7; 16], kdf: None });
        v.on_remote_pre_mail(host, ext::REMOTE_PRE_CHALLENGE, &ch).await.unwrap();
        v.on_remote_pre_mail(host, ext::REMOTE_PRE_CHALLENGE, &ch).await.unwrap();
        assert!(matches!(rx.try_recv(), Ok(PreEvent::Challenged)));
        assert!(rx.try_recv().is_err(), "a duplicate challenge is not answered twice");
        // a verdict from anyone but the host is ignored
        let other = Identity::generate().peer_id();
        let res = |ok: bool| named(&PreResult { session: s, ok, reason: if ok { String::new() } else { "err.wrong_password".into() } });
        v.on_remote_pre_mail(other, ext::REMOTE_PRE_RESULT, &res(true)).await.unwrap();
        assert!(rx.try_recv().is_err());
        v.on_remote_pre_mail(host, ext::REMOTE_PRE_RESULT, &res(false)).await.unwrap();
        assert!(matches!(rx.try_recv(), Ok(PreEvent::Result { ok: false, reason }) if reason == "err.wrong_password"));
        v.shutdown();
    }

    #[test]
    fn pre_messages_are_map_encoded_and_tolerant() {
        // decodes with optional fields missing (older/newer senders)
        #[derive(Serialize)]
        struct Min {
            session: [u8; 16],
        }
        let b = named(&Min { session: [4; 16] });
        let r: PreReq = proto::ext_body(&b).unwrap();
        assert!(!r.view_only && r.ts == 0 && r.cert.is_empty());
        let p: PreResult = proto::ext_body(&b).unwrap();
        assert!(!p.ok && p.reason.is_empty());
        let PeerMsg::Ext { kind, .. } = proto::ext(ext::REMOTE_PRE_REQ, &PreReq { session: [1; 16], view_only: true, ts: 1, cert: vec![] }) else { panic!() };
        assert_eq!(kind, 0x52);
    }
}
