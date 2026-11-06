//! The node: owns identity, storage and transport; runs connections and the app protocol.

pub mod botfather;
mod bridge;
mod chat;
pub mod chat_locks;
mod conn;
pub mod devices;
mod extras;
mod files;
mod groups;
pub mod link;
#[cfg(feature = "media")]
pub mod media_pipe;
mod olm;
mod peer_relay;
mod push;
mod social;
mod stickers;
pub mod sync;
mod tasks;
pub mod wake;
pub mod remote;
mod revoke;

use crate::crypto::{open_sealed, seal_to};
use crate::group::{Gid, GroupState};
use crate::identity::{Identity, PeerId};
use crate::net::{self, ConnInfo, NatKind, NetConfig, Transport};
use crate::proto::{self, PeerMsg, Signal};
use crate::store::Store;
use crate::util::{now_ms, Hlc};
use anyhow::{anyhow, bail, Result};
use parking_lot::{Mutex, RwLock};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, mpsc, oneshot};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct NodeConfig {
    pub data_dir: PathBuf,
    pub passphrase: Option<String>,
    pub name: Option<String>,
    pub port: u16,
    pub relays: Option<Vec<String>>,
    pub nostr: Option<Vec<String>>,
    pub stun: Option<Vec<String>>,
    pub enable_lan: bool,
    /// See `NetConfig::lan_multicast` / `NetConfig::mdns`.
    pub lan_multicast: bool,
    pub mdns: bool,
    pub enable_upnp: bool,
    pub enable_dht: bool,
    pub enable_nostr: bool,
    pub relay_delay_ms: u64,
    pub downloads_dir: Option<PathBuf>,
    /// Restore an existing identity from its recovery phrase on first start: 24 BIP39
    /// words or the legacy base32 phrase (see `Identity::from_recovery_phrase`).
    #[serde(alias = "restore_phrase")]
    pub recovery_phrase: Option<String>,
    /// Restore from a backup file on first start: (path, backup password).
    pub restore_backup: Option<(String, String)>,
    /// Run as a bot created with BotFather (`lumora_bot_…` token).
    pub bot_token: Option<String>,
    /// UI language ("vi"/"en") for messages produced before the saved setting is loaded.
    pub lang: Option<String>,
    /// Start as a new device waiting to be linked into an existing account (shows a link
    /// QR / code; see node/link.rs). Nothing is published and no contacts are created.
    pub link_pending: bool,
    /// Open the account that already lives in `data_dir` (the app's unlock / lock screen):
    /// never create a new identity and never finish a pending sign-out here. A missing
    /// keystore fails with `err.no_account`, a pending sign-out with `err.device_signed_out`,
    /// so a password typed on the lock screen can never turn into a brand-new account.
    pub open_existing: bool,
}

impl Default for NodeConfig {
    fn default() -> Self {
        let d = NetConfig::default();
        NodeConfig {
            data_dir: dirs::data_dir().unwrap_or_else(|| PathBuf::from(".")).join("lumora"),
            passphrase: None,
            name: None,
            port: 0,
            relays: None,
            nostr: None,
            stun: None,
            enable_lan: d.enable_lan,
            lan_multicast: d.lan_multicast,
            mdns: d.mdns,
            enable_upnp: d.enable_upnp,
            enable_dht: d.enable_dht,
            enable_nostr: d.enable_nostr,
            relay_delay_ms: d.relay_delay_ms,
            downloads_dir: None,
            recovery_phrase: None,
            restore_backup: None,
            bot_token: None,
            lang: None,
            link_pending: false,
            open_existing: false,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PathKind {
    Lan,
    Direct,
    Relay,
}

impl PathKind {
    fn rank(&self) -> u8 {
        match self {
            PathKind::Lan | PathKind::Direct => 0,
            PathKind::Relay => 1,
        }
    }
}

pub struct PeerConn {
    /// The remote *device* (transport key, TLS-pinned).
    pub peer: PeerId,
    /// The account behind it (from its TLS device certificate / a device list; else `peer`).
    pub account: PeerId,
    /// One of my own other devices.
    pub own: bool,
    /// Protocol version from its `Hello` (0 until it arrives; persisted per device).
    pub proto: std::sync::atomic::AtomicU32,
    pub conn: quinn::Connection,
    pub path: PathKind,
    pub dialer: PeerId,
    pub ctl: mpsc::Sender<PeerMsg>,
    pub since: Instant,
    pub name: RwLock<String>,
    pub(crate) ctl_rx: Mutex<Option<mpsc::Receiver<PeerMsg>>>,
    /// Open file/media streams; a retired connection is only closed once this reaches 0.
    pub busy: std::sync::atomic::AtomicUsize,
    /// Reliable (`Wrapped`) ids written to this connection and not acknowledged yet:
    /// the outbox pump never re-sends them on the same (ordered, reliable) stream.
    pub(crate) sent: Mutex<HashMap<[u8; 16], Instant>>,
    /// An outbox pump is running for this connection.
    pub(crate) flushing: std::sync::atomic::AtomicBool,
    /// Extra endpoint created by birthday spraying — must outlive the connection.
    _extra_ep: Option<quinn::Endpoint>,
    /// The path looks dead (nothing received for a while, or the peer asked to repair it):
    /// a new connection replaces it at once instead of losing the dedupe tiebreak.
    pub(crate) suspect: std::sync::atomic::AtomicBool,
    pub(crate) suspect_since: Mutex<Option<Instant>>,
    /// Path watchdog: UDP datagrams received so far and when that count last moved; when
    /// the watchdog last pinged.
    pub(crate) rx_seen: Mutex<(u64, Instant, Option<Instant>)>,
    /// Last application message either way (ms): "active" connections are watched closely.
    pub(crate) active_at: std::sync::atomic::AtomicU64,
    /// Acknowledgements to send, written before anything else queued (a full control
    /// channel — e.g. an outbox flush — must never cost acks).
    pub(crate) acks: Mutex<Vec<[u8; 16]>>,
    pub(crate) ack_notify: tokio::sync::Notify,
    /// Installed because the connection it replaced looked dead (this side repaired).
    pub(crate) chosen_by_repair: std::sync::atomic::AtomicBool,
    /// A losing duplicate: the connection it lost to (see `Ext PATH_CHOSEN`).
    pub(crate) lost_to: Mutex<Option<std::sync::Weak<PeerConn>>>,
}

/// Acks waiting to be written per connection, at most (beyond that the sender re-sends).
const MAX_PENDING_ACKS: usize = 100_000;

/// A reliable message written to a connection but still unacknowledged after this long
/// is sent again on the same connection (normally the ack arrives within a second; a
/// receiver slowing a burst down acks at its own pace).
const RESEND_SAME_CONN: Duration = Duration::from_secs(300);

impl PeerConn {
    pub fn alive(&self) -> bool {
        self.conn.close_reason().is_none()
    }

    pub(crate) fn mark_sent(&self, id: [u8; 16]) {
        let mut s = self.sent.lock();
        if s.len() > 50_000 {
            s.retain(|_, t| t.elapsed() < RESEND_SAME_CONN);
        }
        s.insert(id, Instant::now());
    }

    pub(crate) fn sent_recently(&self, id: &[u8; 16]) -> bool {
        self.sent.lock().get(id).map(|t| t.elapsed() < RESEND_SAME_CONN).unwrap_or(false)
    }

    pub(crate) fn is_suspect(&self) -> bool {
        self.suspect.load(std::sync::atomic::Ordering::Relaxed)
    }

    pub(crate) fn mark_suspect(&self) {
        if !self.suspect.swap(true, std::sync::atomic::Ordering::Relaxed) {
            *self.suspect_since.lock() = Some(Instant::now());
        }
    }

    pub(crate) fn touch_active(&self) {
        self.active_at.store(now_ms(), std::sync::atomic::Ordering::Relaxed);
    }

    /// Acknowledge `ids` on this connection (batched, ahead of queued traffic).
    pub(crate) fn queue_ack(&self, ids: &[[u8; 16]]) {
        {
            let mut a = self.acks.lock();
            if a.len() + ids.len() > MAX_PENDING_ACKS {
                return; // unacked → the sender re-sends; acked then
            }
            a.extend_from_slice(ids);
        }
        self.ack_notify.notify_one();
    }

    /// Wall-clock time (ms) the connection was set up.
    pub(crate) fn since_ms(&self) -> u64 {
        now_ms().saturating_sub(self.since.elapsed().as_millis() as u64)
    }
}

/// keys waiting for their group to arrive: (group, epoch) → keys
pub(crate) type PendingKeys = HashMap<(Gid, u64), Vec<[u8; 32]>>;

pub struct Node {
    /// This device's key (TLS, sealing, Olm). On the primary it is the account key.
    pub id: Identity,
    /// The account (what friends know as my id). Fixed for the life of a `Node`.
    pub me: PeerId,
    /// This device (== `me` on the primary).
    pub device: PeerId,
    /// Signs content as the account (DevSig on secondary devices).
    pub signer: crate::devices::Signer,
    pub store: Arc<Store>,
    pub net: Arc<Transport>,
    pub hlc: Hlc,
    pub cfg: NodeConfig,
    pub protection: String,
    name: RwLock<String>,
    peers: RwLock<HashMap<PeerId, Arc<PeerConn>>>,
    dial_locks: Mutex<HashMap<PeerId, Arc<tokio::sync::Mutex<()>>>>,
    pending_answers: Mutex<HashMap<u64, (PeerId, oneshot::Sender<ConnInfo>)>>,
    recent_offers: Mutex<lru::LruCache<(PeerId, u64), ()>>,
    events: broadcast::Sender<Value>,
    pub(crate) groups: RwLock<HashMap<Gid, GroupState>>,
    pub(crate) pending_group: Mutex<HashMap<Gid, Vec<Vec<u8>>>>,
    pub(crate) group_locks: Mutex<HashMap<Gid, Arc<tokio::sync::Mutex<()>>>>,
    pub(crate) pending_keys: Mutex<PendingKeys>,
    pub(crate) stranger_window: Mutex<(Instant, u32)>,
    pub(crate) seen_wrapped: Mutex<lru::LruCache<(PeerId, [u8; 16]), ()>>,
    pub(crate) backoff: Mutex<HashMap<PeerId, (Instant, Duration)>>,
    /// Failed relay → direct upgrades: when the next attempt is due, and the current wait.
    pub(crate) upgrade_backoff: Mutex<HashMap<PeerId, (Instant, Duration)>>,
    /// Hint from the app: metered network / low battery → no birthday spraying.
    pub(crate) power_saving: std::sync::atomic::AtomicBool,
    pub(crate) inbound_limits: Mutex<conn::InboundLimits>,
    /// Protocol versions announced by devices we keep nothing about (strangers): memory only.
    pub(crate) stranger_proto: Mutex<lru::LruCache<PeerId, u32>>,
    /// Highest offer timestamp accepted per device (replayed offers are older).
    pub(crate) offer_ts: Mutex<lru::LruCache<PeerId, u64>>,
    /// Offers from strangers already answered (their own small LRU: spam can't evict the
    /// entries of authorized peers).
    pub(crate) stranger_offers: Mutex<lru::LruCache<(PeerId, u64), ()>>,
    /// Signals handled at once (each one is a task).
    pub(crate) signal_sem: Arc<tokio::sync::Semaphore>,
    pub(crate) olm: olm::OlmState,
    pub(crate) self_ref: Mutex<Option<std::sync::Weak<Node>>>,
    pub(crate) relay_clients: Mutex<HashMap<PeerId, mpsc::Sender<Vec<u8>>>>,
    /// Peer relays I use: the connection (stable id) each one rides on.
    pub(crate) peer_relay_on: Mutex<HashMap<PeerId, usize>>,
    /// "Help friends connect" switched off: every peer-relay serving loop ends.
    pub(crate) relay_stop: tokio::sync::Notify,
    pub(crate) files: files::Transfers,
    pub remote: remote::RemoteState,
    info_refreshed: Mutex<Option<Instant>>,
    shutdown: tokio::sync::watch::Sender<bool>,
    pub(crate) link: link::LinkState,
    pub(crate) sync: sync::SyncState,
    /// Devices I dialed myself recently (my offer already carried my addresses): their
    /// offers / dial-backs are answered for a while even if they are not contacts.
    pub(crate) solicited: Mutex<HashMap<PeerId, Instant>>,
    /// Offline/unreachable devices: when their queued messages may next go out again as
    /// sealed signaling mail, and the current back-off.
    pub(crate) mail_retry: Mutex<HashMap<PeerId, (Instant, Duration)>>,
    /// Last queued "seen up to" receipt per (group chat, member): a newer one replaces it
    /// in the outbox instead of piling up for an offline member.
    pub(crate) group_read_ids: Mutex<HashMap<(String, PeerId), [u8; 16]>>,
    /// Acks owed to devices that reached us only by signaling mail (batched).
    pub(crate) mail_acks: Mutex<HashMap<PeerId, Vec<[u8; 16]>>>,
}

pub fn direct_conv(p: &PeerId) -> String {
    format!("d:{}", p.to_base32())
}

pub const SAVED_CONV: &str = "s:me";

/// Reconnect sweep: at most this many devices per friend.
pub(crate) const MAX_DEVICES_PER_SWEEP: usize = 3;

/// Predicted external ports of a sequential symmetric NAT: the next ones, nearest first (a
/// wider sweep when we are sequential too), then a few just *before* the reported ones — a
/// flow the peer's NAT mapped right before its STUN probes (e.g. a dead connection still
/// retransmitting toward us after its NAT rebound) holds the port below them, and every new
/// attempt from the same socket to our address reuses that mapping.
fn predicted_ports(their: &ConnInfo, both_sequential: bool) -> Vec<SocketAddr> {
    let (NatKind::HardSequential(d), Some(ip), Some(first), Some(last)) = (&their.nat, their.public_ip, their.mapped_ports.first(), their.mapped_ports.last()) else {
        return vec![];
    };
    let n = if both_sequential { 32 } else { 8 };
    // a peer's report is untrusted: a huge delta must not overflow
    let at = |base: u16, k: i64| -> Option<SocketAddr> {
        let p = (base as i64).checked_add((*d as i64).checked_mul(k)?)?;
        (1..=65535).contains(&p).then(|| SocketAddr::new(ip, p as u16))
    };
    let mut out: Vec<SocketAddr> = (1..=n).filter_map(|k: i64| at(*last, k)).collect();
    for k in 1..=4i64 {
        if let Some(a) = at(*first, -k).filter(|a| !their.mapped_ports.contains(&a.port()) && !out.contains(a)) {
            out.push(a);
        }
    }
    out
}

/// Identical on both sides of a QUIC connection (TLS keying-material exporter).
/// The connection runs over IPv6 (v4-mapped addresses count as IPv4).
fn direct_v6(c: &quinn::Connection) -> bool {
    crate::util::canon(c.remote_address()).is_ipv6()
}

fn conn_tiebreak_id(c: &quinn::Connection) -> [u8; 16] {
    let mut out = [0u8; 16];
    let _ = c.export_keying_material(&mut out, b"lumora-conn-tiebreak", b"");
    out
}

static SPRAY_SEM: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(1);

/// One running Lumora per data folder: an OS file lock held for the life of the process
/// (in-process restarts of the same folder reuse it).
/// Data folders locked by this process (the lock is released by dropping the file).
static HELD_DIRS: Mutex<Vec<(std::path::PathBuf, std::fs::File)>> = parking_lot::const_mutex(Vec::new());

fn data_dir_key(dir: &std::path::Path) -> std::path::PathBuf {
    dir.canonicalize().unwrap_or_else(|_| dir.to_path_buf())
}

/// Lock the data folder against a second app instance. Returns whether this call took the
/// lock (false: this process already held it).
fn lock_data_dir(dir: &std::path::Path) -> Result<bool> {
    let key = data_dir_key(dir);
    let mut held = HELD_DIRS.lock();
    if held.iter().any(|(p, _)| *p == key) {
        return Ok(false);
    }
    let f = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dir.join(".lock"))
        .map_err(|e| crate::i18n::user_err("err.data_unreadable").detail(e))?;
    match f.try_lock() {
        Ok(()) => {}
        Err(std::fs::TryLockError::WouldBlock) => bail!(crate::i18n::user_err("err.already_running")),
        // file locks unsupported here (some network/Android filesystems): carry on
        Err(std::fs::TryLockError::Error(e)) => tracing::debug!("data folder lock unavailable: {e}"),
    }
    held.push((key, f));
    Ok(true)
}

/// Release the data folder lock (so the app can rename/remove the folder, e.g. on Windows
/// after a wrong password in the "forgot password" rescue flow).
fn unlock_data_dir(dir: &std::path::Path) {
    let key = data_dir_key(dir);
    HELD_DIRS.lock().retain(|(p, _)| *p != key);
}

/// Wipe start-up secrets from the config (they are only needed to open the keystore).
fn scrub_secrets(cfg: &mut NodeConfig) {
    use zeroize::Zeroize;
    if let Some(p) = cfg.passphrase.as_mut() {
        p.zeroize();
    }
    if let Some(p) = cfg.recovery_phrase.as_mut() {
        p.zeroize();
    }
    if let Some((_, pw)) = cfg.restore_backup.as_mut() {
        pw.zeroize();
    }
    cfg.passphrase = None;
    cfg.recovery_phrase = None;
    cfg.restore_backup = None;
}

/// Data folder 0700 / files 0600 on Unix (other local accounts can't copy the encrypted
/// database or keystore for offline password guessing). Windows: per-user profile ACLs.
fn restrict_to_owner(path: &std::path::Path, dir: bool) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if path.exists() {
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(if dir { 0o700 } else { 0o600 }));
        }
    }
    #[cfg(not(unix))]
    let _ = (path, dir);
}

pub fn parse_conv(conv: &str) -> Result<ConvRef> {
    if conv == SAVED_CONV {
        return Ok(ConvRef::Saved);
    }
    if let Some(p) = conv.strip_prefix("d:") {
        return Ok(ConvRef::Direct(PeerId::from_str_any(p)?));
    }
    if let Some(g) = conv.strip_prefix("g:") {
        let (gid, ch) = match g.split_once('#') {
            Some((a, b)) => (a, b.to_string()),
            None => (g, String::new()),
        };
        let b = hex::decode(gid)?;
        return Ok(ConvRef::Group(b.try_into().map_err(|_| anyhow!("bad gid"))?, ch));
    }
    bail!("unknown conversation id")
}

pub enum ConvRef {
    Saved,
    Direct(PeerId),
    Group(Gid, String),
}

impl Node {
    pub async fn start(cfg: NodeConfig) -> Result<Arc<Node>> {
        if let Some(l) = cfg.lang.as_deref().filter(|l| !l.is_empty()) {
            crate::i18n::set_lang(l);
        }
        std::fs::create_dir_all(&cfg.data_dir).map_err(|e| crate::i18n::user_err("err.data_unreadable").detail(e))?;
        restrict_to_owner(&cfg.data_dir, true);
        let dir = cfg.data_dir.clone();
        let took_lock = lock_data_dir(&dir)?;
        let r = Self::start_locked(cfg).await;
        if r.is_err() && took_lock {
            // failed start (wrong password, damaged data…): don't keep the folder locked
            unlock_data_dir(&dir);
        }
        r
    }

    fn open_keystore(cfg: &NodeConfig) -> Result<crate::keystore::Unlocked> {
        let dir = cfg.data_dir.clone();
        Ok(if crate::keystore::exists(&dir) {
            // A restore must never be silently ignored (that would keep a
            // half-made identity, e.g. an abandoned link, under the user's
            // name): only the same account's phrase may reopen existing data.
            let phrase = cfg.recovery_phrase.as_deref().filter(|p| !p.trim().is_empty());
            if cfg.restore_backup.is_some() || phrase.is_some_and(|p| crate::keystore::phrase_matches(&dir, p) != Some(true)) {
                return Err(crate::i18n::user_err("err.restore_data_exists").into());
            }
            crate::keystore::unlock(&dir, cfg.passphrase.as_deref())?
        } else if let Some(tok) = cfg.bot_token.as_deref().filter(|t| !t.is_empty()) {
            let t = botfather::BotToken::decode(tok)?;
            crate::keystore::create(&dir, &t.identity(), cfg.passphrase.as_deref())?
        } else if let Some((file, pw)) = &cfg.restore_backup {
            crate::keystore::import_backup(&dir, std::path::Path::new(file), pw, cfg.passphrase.as_deref())?
        } else {
            let id = match &cfg.recovery_phrase {
                Some(p) if !p.trim().is_empty() => Identity::from_recovery_phrase(p)?,
                _ => Identity::generate(),
            };
            crate::keystore::create(&dir, &id, cfg.passphrase.as_deref())?
        })
    }

    async fn start_locked(mut cfg: NodeConfig) -> Result<Arc<Node>> {
        let dir = cfg.data_dir.clone();
        if cfg.open_existing {
            // unlocking the existing account: a pending sign-out is shown to the user (the app
            // reads the marker), never silently turned into a fresh account under this password
            if dir.join(revoke::RESET_MARKER).exists() {
                scrub_secrets(&mut cfg);
                return Err(crate::i18n::user_err("err.device_signed_out").into());
            }
            if !crate::keystore::exists(&dir) {
                scrub_secrets(&mut cfg);
                return Err(crate::i18n::user_err("err.no_account").into());
            }
        } else {
            // this device was signed out of its account last time: start as a fresh install
            revoke::apply_reset_marker(&dir);
        }
        let unlocked = Self::open_keystore(&cfg);
        // the password / recovery phrase / backup password are not needed any more: wipe
        // them now (also on failure) instead of keeping them in `node.cfg` for the app's life
        scrub_secrets(&mut cfg);
        let unlocked = unlocked?;
        let _ = crate::keystore::ensure_owner_tag(&dir, &unlocked.identity);
        let store = Arc::new(Store::open(&dir.join("lumora.db"), &unlocked.db_key).map_err(|e| crate::i18n::or_user(e, "err.data_corrupt"))?);
        for f in ["lumora.db", "lumora.db-wal", "lumora.db-shm", "keystore.json"] {
            restrict_to_owner(&dir.join(f), false);
        }
        let _ = store.wipe_ephemeral();
        let id = unlocked.identity;
        let device = id.peer_id();
        // a linked (secondary) device acts for the account in its certificate
        let secondary = store.kv_get("account.role").map(|v| v == b"secondary").unwrap_or(false);
        let (me, signer, devcert) = if secondary {
            let cert = store
                .kv_get("account.cert")
                .and_then(|b| crate::devices::DeviceCert::decode(&b).ok())
                .ok_or_else(|| crate::i18n::user_err("err.data_corrupt").detail("device certificate missing"))?;
            let signer = crate::devices::Signer::secondary(&id, cert.clone()).map_err(|e| crate::i18n::user_err("err.data_corrupt").detail(e))?;
            (cert.account, signer, Some(cert))
        } else {
            (device, crate::devices::Signer::primary(&id), None)
        };
        let protection = unlocked.protection;
        // already linked: "waiting to be linked" no longer applies
        cfg.link_pending &= !secondary;

        let mut ncfg = NetConfig {
            port: if cfg.port != 0 {
                cfg.port
            } else {
                store.kv_get("net.port").and_then(|v| v.try_into().ok()).map(u16::from_le_bytes).unwrap_or(0)
            },
            ..Default::default()
        };
        if let Some(r) = &cfg.relays {
            ncfg.relays = r.clone();
        }
        if let Some(saved) = store.kv_get_json::<Vec<String>>("net.relays") {
            for r in saved {
                if !ncfg.relays.contains(&r) {
                    ncfg.relays.push(r);
                }
            }
        }
        if let Some(n) = &cfg.nostr {
            ncfg.nostr = n.clone();
        }
        if let Some(s) = &cfg.stun {
            ncfg.stun = s.clone();
        }
        ncfg.enable_lan = cfg.enable_lan;
        ncfg.lan_multicast = cfg.lan_multicast;
        ncfg.mdns = cfg.mdns;
        ncfg.enable_upnp = cfg.enable_upnp;
        ncfg.enable_dht = cfg.enable_dht;
        ncfg.enable_nostr = cfg.enable_nostr;
        ncfg.relay_delay_ms = if store.kv_get("net.p2p_only").map(|v| v == b"1").unwrap_or(false) { u64::MAX } else { cfg.relay_delay_ms };

        let (net, signals) = Transport::start(id.clone(), devcert, ncfg).await.map_err(|e| crate::i18n::or_user(e, "err.net_start"))?;
        // keep the same UDP port across restarts (friends' caches stay valid)
        let _ = store.kv_set("net.port", &net.local_port().to_le_bytes());

        store.set_rev_device(&device);
        // a secondary's `cfg.name` names the device, never the (shared) profile. The name
        // given at start (the app passes the one typed at onboarding, every time) only
        // names a new profile: the stored one may have been changed since, here or on
        // another device of the account — overwriting it (with a fresh sync stamp) undid
        // a rename made on the phone each time the PC restarted.
        let name = store
            .kv_get("profile.name")
            .and_then(|v| String::from_utf8(v).ok())
            .filter(|n| !n.is_empty())
            .or_else(|| cfg.name.clone().filter(|n| !n.is_empty() && !secondary))
            .unwrap_or_else(|| format!("Lumora {}", &me.short_id().to_string()[..3]));
        if !secondary {
            let _ = store.kv_set("profile.name", name.as_bytes());
        }
        if store.kv_get("device.name").is_none() {
            let dn = if cfg.link_pending || secondary { cfg.name.clone().filter(|n| !n.is_empty()) } else { None };
            let dn: String = dn.unwrap_or_else(devices::default_device_name).chars().take(32).collect();
            let _ = store.kv_set("device.name", dn.as_bytes());
        }

        if let Some(l) = store.kv_get("ui.lang").and_then(|v| String::from_utf8(v).ok()) {
            crate::i18n::set_lang(&l);
        }
        let (events, _) = broadcast::channel(4096);
        let (shutdown, _) = tokio::sync::watch::channel(false);
        let node = Arc::new(Node {
            id: id.clone(),
            me,
            device,
            signer,
            store: store.clone(),
            net,
            hlc: Hlc::new(),
            cfg: cfg.clone(),
            protection,
            name: RwLock::new(name),
            peers: RwLock::new(HashMap::new()),
            dial_locks: Mutex::new(HashMap::new()),
            pending_answers: Mutex::new(HashMap::new()),
            recent_offers: Mutex::new(lru::LruCache::new(std::num::NonZeroUsize::new(4096).unwrap())),
            events,
            groups: RwLock::new(HashMap::new()),
            pending_group: Mutex::new(HashMap::new()),
            group_locks: Mutex::new(HashMap::new()),
            pending_keys: Mutex::new(HashMap::new()),
            stranger_window: Mutex::new((Instant::now(), 0)),
            seen_wrapped: Mutex::new(lru::LruCache::new(std::num::NonZeroUsize::new(20_000).unwrap())),
            backoff: Mutex::new(HashMap::new()),
            upgrade_backoff: Mutex::new(HashMap::new()),
            power_saving: std::sync::atomic::AtomicBool::new(false),
            inbound_limits: Mutex::new(Default::default()),
            stranger_proto: Mutex::new(lru::LruCache::new(std::num::NonZeroUsize::new(1024).unwrap())),
            offer_ts: Mutex::new(lru::LruCache::new(std::num::NonZeroUsize::new(4096).unwrap())),
            stranger_offers: Mutex::new(lru::LruCache::new(std::num::NonZeroUsize::new(1024).unwrap())),
            signal_sem: Arc::new(tokio::sync::Semaphore::new(conn::MAX_SIGNAL_TASKS)),
            olm: Default::default(),
            self_ref: Mutex::new(None),
            relay_clients: Mutex::new(HashMap::new()),
            peer_relay_on: Mutex::new(HashMap::new()),
            relay_stop: tokio::sync::Notify::new(),
            files: files::Transfers::default(),
            remote: remote::RemoteState::new(&store),
            info_refreshed: Mutex::new(None),
            shutdown,
            link: Default::default(),
            sync: Default::default(),
            solicited: Mutex::new(HashMap::new()),
            mail_retry: Mutex::new(HashMap::new()),
            group_read_ids: Mutex::new(HashMap::new()),
            mail_acks: Mutex::new(HashMap::new()),
        });
        *node.self_ref.lock() = Some(Arc::downgrade(&node));
        node.ensure_own_list();
        node.push_list_after_promote();
        node.refresh_sync_enabled();
        node.load_groups();
        node.clone().spawn_accept_loop();
        node.clone().spawn_signal_loop(signals);
        node.clone().spawn_background();
        node.spawn_sync_loop();
        if let Some(tok) = cfg.bot_token.as_deref().filter(|t| !t.is_empty()) {
            let t = botfather::BotToken::decode(tok)?;
            node.apply_bot_token(&t)?;
        }
        node.emit("ready", json!({"peer": me.to_base32(), "short_id": me.short_id_fmt(), "device": device.to_base32(), "primary": me == device}));
        Ok(node)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Value> {
        self.events.subscribe()
    }

    pub fn emit(&self, event: &str, mut data: Value) {
        if let Value::Object(ref mut m) = data {
            m.insert("event".into(), Value::String(event.into()));
        } else {
            data = json!({"event": event, "data": data});
        }
        let _ = self.events.send(data);
    }

    pub fn name(&self) -> String {
        self.name.read().clone()
    }

    pub fn set_name(&self, n: &str) -> Result<()> {
        let n: String = n.trim().chars().take(48).collect();
        anyhow::ensure!(!n.is_empty(), crate::i18n::user_err("err.name_empty"));
        *self.name.write() = n.clone();
        self.store.kv_set("profile.name", n.as_bytes())?;
        for pc in self.connected_peers() {
            if !pc.own {
                let _ = pc.ctl.try_send(PeerMsg::Profile { name: n.clone() });
            }
        }
        // the directory entry is signed by the account key: primary only (and only while
        // the user lets strangers find them by ID)
        if self.is_primary() {
            self.publish_directory_now();
        }
        Ok(())
    }

    pub fn shutdown(&self) {
        let _ = self.shutdown.send(true);
        self.net.endpoint.close(0u32.into(), b"bye");
    }

    // ------------------------------------------------------------------ peers

    pub fn connected_peers(&self) -> Vec<Arc<PeerConn>> {
        self.peers.read().values().filter(|p| p.alive()).cloned().collect()
    }

    /// The connection to one device.
    pub fn peer(&self, p: &PeerId) -> Option<Arc<PeerConn>> {
        self.peers.read().get(p).filter(|c| c.alive()).cloned()
    }

    /// Every live connection to a device of `account` (or to the key itself).
    pub fn peers_of(&self, account: &PeerId) -> Vec<Arc<PeerConn>> {
        self.peers.read().values().filter(|c| c.alive() && (c.account == *account || c.peer == *account)).cloned().collect()
    }

    /// An account is online if any of its devices is connected.
    pub fn is_online(&self, p: &PeerId) -> bool {
        self.peer(p).is_some() || !self.peers_of(p).is_empty()
    }

    /// Send a control message to every connected device of an account (no dialing).
    /// `Ext` only goes to devices that understand it.
    pub fn send_now(&self, p: &PeerId, m: PeerMsg) -> bool {
        let mut ok = false;
        for c in self.peers_of(p) {
            if matches!(m, PeerMsg::Ext { .. }) && c.proto.load(std::sync::atomic::Ordering::Relaxed) < proto::PROTO_V3 {
                continue;
            }
            ok |= c.ctl.try_send(m.clone()).is_ok();
        }
        ok
    }

    /// Send to exactly one device (no dialing).
    pub fn send_now_dev(&self, dev: &PeerId, m: PeerMsg) -> bool {
        // acknowledgements go ahead of queued traffic (never dropped on a full queue)
        if let PeerMsg::Ack { ids } = &m {
            return match self.peer(dev) {
                Some(c) => {
                    c.queue_ack(ids);
                    true
                }
                None => false,
            };
        }
        match self.peer(dev) {
            Some(c) if matches!(m, PeerMsg::Ext { .. }) && !self.dev_speaks_v3(dev) => {
                let _ = c;
                false
            }
            Some(c) => {
                let id = match &m {
                    PeerMsg::Wrapped { id, .. } => Some(*id),
                    _ => None,
                };
                let ok = c.ctl.try_send(m).is_ok();
                if let (true, Some(id)) = (ok, id) {
                    c.mark_sent(id);
                }
                ok
            }
            None => false,
        }
    }

    /// Connect (if needed) to some device of the account, then send.
    pub async fn send_to(self: &Arc<Self>, p: PeerId, m: PeerMsg) -> Result<()> {
        let c = self.connect_any(p).await?;
        c.ctl.send(m).await.map_err(|_| crate::i18n::user_err("err.connection_lost").into())
    }

    /// A connection to any device of `account` (already connected first, else race them).
    pub async fn connect_any(self: &Arc<Self>, account: PeerId) -> Result<Arc<PeerConn>> {
        if let Some(c) = self.peers_of(&account).into_iter().next() {
            return Ok(c);
        }
        let targets = self.delivery_targets(&account);
        if targets.len() <= 1 {
            let first = self.connect(targets.first().copied().unwrap_or(account)).await;
            if first.is_ok() || targets.first() != Some(&account) {
                return first;
            }
            // no list cached and the account key is unreachable: its other devices, from
            // the DHT record its main device publishes (each proves itself over TLS)
            // (stored under the main device's friends-only key: only friends can find it)
            let devs = match (&self.net.dht, self.friend_dht_key(&account)) {
                (Some(dht), Some(k)) => dht.lookup_devices(&account, &k).await.map(|r| r.devices).unwrap_or_default(),
                _ => vec![],
            };
            let futs: Vec<_> = devs.into_iter().map(|(d, _)| d).filter(|d| *d != account && *d != self.device).take(crate::devices::MAX_DEVICES).map(|d| Box::pin(self.connect(d))).collect();
            if futs.is_empty() {
                return first;
            }
            return match futures::future::select_ok(futs).await {
                Ok((c, _)) if c.account == account => Ok(c),
                _ => first,
            };
        }
        let futs: Vec<_> = targets.into_iter().map(|d| Box::pin(self.connect(d))).collect();
        match futures::future::select_ok(futs).await {
            Ok((c, _)) => Ok(c),
            Err(e) => Err(e),
        }
    }

    async fn ensure_info(&self) -> ConnInfo {
        // Sequential symmetric NATs: the peer predicts our next ports from the reflexive
        // ports we report, so they must be fresh (every new destination shifts them).
        let max_age = if matches!(self.net.info.read().nat, NatKind::HardSequential(_)) { Duration::from_secs(10) } else { Duration::from_secs(90) };
        // (also when nothing was gathered yet: the background refresh marks itself as done
        // when it starts, so right after start-up the cached info may still be empty)
        let stale = self.info_refreshed.lock().map(|t| t.elapsed() > max_age).unwrap_or(true) || self.net.info.read().addrs.is_empty();
        let mut info = if stale {
            *self.info_refreshed.lock() = Some(Instant::now());
            self.net.refresh_info().await
        } else {
            self.net.info.read().clone()
        };
        // relays come and go (a server relay dies, a friend's peer relay appears): always
        // offer the ones connected right now, never a cached list
        info.relays = self.net.relays.read().iter().filter(|r| r.is_connected()).map(|r| r.url.clone()).collect();
        info
    }

    /// Establish (or reuse) a connection, trying every path; relays only last.
    /// Failures are reported to the user as "can't reach this person" (raw cause in detail).
    pub async fn connect(self: &Arc<Self>, peer: PeerId) -> Result<Arc<PeerConn>> {
        if peer == self.device {
            bail!(crate::i18n::user_err("err.own_id"));
        }
        self.connect_inner(peer).await.map_err(|e| crate::i18n::or_user(e, "err.peer_offline"))
    }

    /// The app says the device is on a metered network or saving battery.
    pub fn set_power_saving(&self, on: bool) {
        self.power_saving.store(on, std::sync::atomic::Ordering::Relaxed);
    }

    /// A live connection to the device that doesn't look dead.
    pub(crate) fn usable_peer(&self, p: &PeerId) -> Option<Arc<PeerConn>> {
        self.peer(p).filter(|c| !c.is_suspect())
    }

    /// Path repair (the watchdog saw our path die): like `connect`, but never queued behind
    /// an answer-side dial already running for this peer — that one races with what the
    /// peer's offer said before our NAT mapping changed and can hold the dial lock for its
    /// whole 25 s deadline, while a fresh offer of ours gets through at once.
    pub(crate) async fn connect_repair(self: &Arc<Self>, peer: PeerId) -> Result<Arc<PeerConn>> {
        if let Some(c) = self.usable_peer(&peer) {
            return Ok(c);
        }
        let lock = self.dial_locks.lock().entry(peer).or_default().clone();
        let _g = lock.try_lock().ok();
        if let Some(c) = self.usable_peer(&peer) {
            return Ok(c);
        }
        self.note_solicited(peer);
        match self.connect_paths(peer).await {
            Err(e) => self.usable_peer(&peer).ok_or(e),
            ok => ok,
        }
    }

    async fn connect_inner(self: &Arc<Self>, peer: PeerId) -> Result<Arc<PeerConn>> {
        if let Some(c) = self.usable_peer(&peer) {
            return Ok(c);
        }
        let lock = self.dial_locks.lock().entry(peer).or_default().clone();
        let _g = lock.lock().await;
        {
            // keep the map from growing forever: drop idle locks
            let mut dl = self.dial_locks.lock();
            if dl.len() > 512 {
                dl.retain(|_, l| Arc::strong_count(l) > 1);
            }
        }
        if let Some(c) = self.usable_peer(&peer) {
            return Ok(c);
        }
        // I'm dialing them (my offer carries my addresses anyway): their answer-side dial
        // and offers are welcome for a while, even if they aren't a contact
        self.note_solicited(peer);
        let r = self.connect_paths(peer).await;
        if let Err(e) = &r {
            tracing::debug!("connect {peer:?} failed: {e:#}");
        }
        // both sides' attempts may complete at once and the duplicate we hold be closed
        // first: the surviving one (installed by the accept side) is still a success
        match r {
            Err(e) => self.usable_peer(&peer).ok_or(e),
            ok => ok,
        }
    }

    async fn connect_paths(self: &Arc<Self>, peer: PeerId) -> Result<Arc<PeerConn>> {
        // 1. LAN fast path
        let lan = self.net.lan.get(&peer);
        if !lan.is_empty() {
            if let Ok(c) = self.net.dial_direct(peer, lan, Duration::from_millis(1500)).await {
                return self.clone().setup_conn(c, PathKind::Lan, self.device, None).await;
            }
        }
        // 2. Signal an offer through every channel and race all paths.
        let info = self.ensure_info().await;
        let sid: u64 = rand::random();
        let (tx, rx) = oneshot::channel();
        self.pending_answers.lock().insert(sid, (peer, tx));
        let offer = Signal::Offer { sid, info: info.clone(), name: self.name() };
        let sealed = seal_to(&self.id, &peer, &rmp_serde::to_vec(&offer)?)?;
        // only friends' relay hints are followed (strangers can't steer our traffic)
        let acc = self.account_of(&peer);
        let hint_relays = if self.store.is_friend(&acc) || acc == self.me { self.store.contact(&peer).map(|c| c.relays).unwrap_or_default() } else { vec![] };
        let channels = self.net.send_signal(&peer, sealed.clone(), &hint_relays).await;
        tracing::debug!("offer {sid} → {peer:?} via {channels} channels");

        // Cached addresses from last time (often still valid: same port kept). Only for
        // people allowed to know mine (strangers are never cached, never probed), and not
        // from a sequential NAT: each new destination there shifts the ports the peer
        // predicts for us (see `race_paths_opt`).
        let seq = matches!(info.nat, NatKind::HardSequential(_));
        let cached: Vec<SocketAddr> = if seq || !self.may_reveal_addrs(&peer) {
            vec![]
        } else {
            self.store.peer_cache_get(&peer).and_then(|b| crate::proto::from_slice_capped::<ConnInfo>(&b).ok()).map(|i| i.addrs).unwrap_or_default()
        };
        let me = self.clone();
        let cached_try = async move {
            if cached.is_empty() {
                futures::future::pending::<()>().await;
            }
            me.net.punch(&cached, sid).await;
            match me.net.dial_direct(peer, net::order_candidates(cached), Duration::from_secs(4)).await {
                Ok(c) => Ok::<_, anyhow::Error>(c),
                // stale cache: drop out of the race, the signaled attempt goes on
                Err(_) => futures::future::pending().await,
            }
        };

        let answer = async {
            match tokio::time::timeout(Duration::from_secs(6), rx).await {
                Ok(Ok(i)) => Ok(i),
                _ => {
                    // No answer: ask the DHT where the peer can be reached and retry via its relays.
                    // Only the friends-only record exists (found and read with the key the peer
                    // gave us): strangers name no relays for us to connect to (#14).
                    let fkey = self.friend_dht_key(&peer).filter(|_| self.store.is_friend(&acc) || acc == self.me);
                    if let (Some(dht), Some(k)) = (&self.net.dht, fkey) {
                        if let Some(mut rec) = dht.lookup_friend(&peer, &k).await {
                            rec.relays.retain(|r| !r.starts_with("peer:"));
                            let _ = self.store.set_contact_field(
                                &peer,
                                "relays",
                                rusqlite::types::Value::Text(serde_json::to_string(&rec.relays).unwrap_or_default()),
                            );
                            let (tx2, rx2) = oneshot::channel();
                            self.pending_answers.lock().insert(sid ^ 1, (peer, tx2));
                            let offer2 = Signal::Offer { sid: sid ^ 1, info: info.clone(), name: self.name() };
                            if let Ok(s2) = seal_to(&self.id, &peer, &rmp_serde::to_vec(&offer2).unwrap_or_default()) {
                                self.net.send_signal(&peer, s2, &rec.relays).await;
                            }
                            if !rec.addrs.is_empty() {
                                // Peer may be directly reachable (open NAT / UPnP).
                                let mut i = ConnInfo { addrs: rec.addrs.clone(), relays: rec.relays.clone(), ..Default::default() };
                                if let Ok(Ok(a)) = tokio::time::timeout(Duration::from_secs(6), rx2).await {
                                    i = a;
                                }
                                return Ok(i);
                            }
                            return tokio::time::timeout(Duration::from_secs(6), rx2)
                                .await
                                .map_err(|_| crate::i18n::user_err("err.peer_offline"))?
                                .map_err(|_| anyhow!("cancelled"));
                        }
                    }
                    Err(anyhow::Error::from(crate::i18n::user_err("err.peer_offline")))
                }
            }
        };

        let main = async {
            let their = answer.await?;
            self.race_paths(peer, sid, &info, &their).await
        };
        // Peer may show up on the LAN while we wait for signaling.
        let me2 = self.clone();
        let lan_watch = async move {
            for _ in 0..60 {
                tokio::time::sleep(Duration::from_millis(500)).await;
                let lan = me2.net.lan.get(&peer);
                if !lan.is_empty() {
                    if let Ok(c) = me2.net.dial_direct(peer, lan, Duration::from_millis(2500)).await {
                        return Ok::<_, anyhow::Error>(c);
                    }
                }
            }
            futures::future::pending().await
        };
        let res = tokio::select! {
            r = main => r,
            r = cached_try => r.map(|c| (c, PathKind::Direct, None)),
            r = lan_watch => r.map(|c| (c, PathKind::Lan, None)),
            _ = self.wait_path(peer, false, Duration::from_secs(40)) => {
                // the other side's dial-back won the race
                self.pending_answers.lock().remove(&sid);
                self.pending_answers.lock().remove(&(sid ^ 1));
                return self.usable_peer(&peer).ok_or_else(|| anyhow!("connection lost"));
            }
        };
        self.pending_answers.lock().remove(&sid);
        self.pending_answers.lock().remove(&(sid ^ 1));
        let (c, path, ep) = res?;
        self.clone().setup_conn(c, path, self.device, ep).await
    }

    /// Run direct / spray / relay attempts concurrently (relay delayed).
    async fn race_paths(
        self: &Arc<Self>,
        peer: PeerId,
        sid: u64,
        mine: &ConnInfo,
        their: &ConnInfo,
    ) -> Result<(quinn::Connection, PathKind, Option<quinn::Endpoint>)> {
        self.race_paths_opt(peer, sid, mine, their, true).await
    }

    pub(super) async fn race_paths_opt(
        self: &Arc<Self>,
        peer: PeerId,
        sid: u64,
        mine: &ConnInfo,
        their: &ConnInfo,
        allow_relay: bool,
    ) -> Result<(quinn::Connection, PathKind, Option<quinn::Endpoint>)> {
        // IP privacy: never probe, dial or spray a device that isn't allowed to learn our
        // addresses (a stranger), and never keep its addresses
        anyhow::ensure!(self.may_reveal_addrs(&peer), "not dialing a stranger's addresses");
        let _ = self.store.peer_cache_put(&peer, &rmp_serde::to_vec(their).unwrap_or_default());
        // Port prediction for sequential symmetric NATs. Probes go to the predicted ports
        // FIRST, in ascending order, before any other address of the peer: on a sequential
        // NAT every new destination takes the next port, so when both sides do this the
        // k-th probe of each (a+k → b+k, b+k → a+k) mirror each other and open a hole.
        let predicted = predicted_ports(their, matches!(mine.nat, NatKind::HardSequential(_)));
        let rest = net::order_candidates(their.addrs.iter().copied().filter(|a| !predicted.contains(a)).collect());
        let lan_ips: Vec<SocketAddr> = rest.iter().copied().filter(|a| !crate::util::is_global_ip(&a.ip())).collect();
        if !predicted.is_empty() {
            self.net.punch(&predicted, sid).await;
        }
        self.net.punch(&rest, sid).await;
        let cands: Vec<SocketAddr> = predicted.iter().copied().chain(rest.iter().copied()).collect();

        let me = self.clone();
        let c2 = cands.clone();
        let direct = async move {
            let r = me.net.dial_direct(peer, c2, Duration::from_secs(9)).await?;
            let path = if lan_ips.iter().any(|a| a.ip() == crate::util::canon(r.remote_address()).ip()) {
                PathKind::Lan
            } else {
                PathKind::Direct
            };
            Ok::<_, anyhow::Error>((r, path, None))
        };

        // Birthday spraying when exactly one side is hard.
        let me = self.clone();
        let (mine_c, their_c) = (mine.clone(), their.clone());
        let power_saving = self.power_saving.load(std::sync::atomic::Ordering::Relaxed);
        let spray = async move {
            // metered network / battery saver (hint from the app): no spraying at all
            if power_saving {
                return futures::future::pending::<Result<(quinn::Connection, PathKind, Option<quinn::Endpoint>)>>().await;
            }
            // Birthday spraying opens 256 sockets / sends ≤4k probes: strictly one at a time
            // (bounded cost even under a flood of offers, which are also rate-limited).
            let _permit = SPRAY_SEM.acquire().await;
            let unknown = matches!(mine_c.nat, NatKind::Unknown) || matches!(their_c.nat, NatKind::Unknown);
            let targets: Vec<SocketAddr> =
                their_c.addrs.iter().copied().filter(|a| crate::util::is_global_ip(&a.ip()) && a.is_ipv4()).collect();
            if unknown && !targets.is_empty() && their_c.nat != NatKind::UdpBlocked {
                // No STUN → we can't tell who is "hard": play both roles at once (two-sided birthday).
                let me2 = me.clone();
                let tc = their_c.clone();
                let easy = async move {
                    if let Some(ip) = tc.public_ip {
                        me2.net.spray_from_easy(ip, &tc.nat, &tc.mapped_ports, sid, Duration::from_secs(8)).await;
                    }
                    futures::future::pending::<()>().await;
                };
                tokio::select! {
                    r = me.net.spray_from_hard(peer, targets, sid, Duration::from_secs(8), 256) => {
                        let (c, ep) = r?;
                        return Ok((c, PathKind::Direct, Some(ep)));
                    }
                    _ = easy => {}
                }
            } else if mine_c.nat.is_hard() && !their_c.nat.is_hard() && their_c.nat != NatKind::UdpBlocked {
                if !targets.is_empty() {
                    let (c, ep) = me.net.spray_from_hard(peer, targets, sid, Duration::from_secs(8), 256).await?;
                    return Ok((c, PathKind::Direct, Some(ep)));
                }
            } else if their_c.nat.is_hard() && !mine_c.nat.is_hard() {
                if let Some(ip) = their_c.public_ip {
                    me.net.spray_from_easy(ip, &their_c.nat, &their_c.mapped_ports, sid, Duration::from_secs(8)).await;
                }
            }
            futures::future::pending::<Result<(quinn::Connection, PathKind, Option<quinn::Endpoint>)>>().await
        };

        // Relay: last resort, after a grace period, via a relay both sides use.
        let me = self.clone();
        let their_relays = their.relays.clone();
        // If a direct path is hopeless (both symmetric-random, or UDP blocked), don't wait.
        let hopeless = matches!(mine.nat, NatKind::UdpBlocked)
            || matches!(their.nat, NatKind::UdpBlocked)
            || (matches!(mine.nat, NatKind::HardRandom) && matches!(their.nat, NatKind::HardRandom));
        let cfg_delay = self.net.cfg.read().relay_delay_ms;
        // "P2P only" mode: relay_delay_ms ≥ 600 000 (or u64::MAX) disables relayed data entirely;
        // relays are then only used to exchange encrypted signaling messages.
        let p2p_only = cfg_delay >= 600_000;
        let delay = if hopeless { 0 } else { cfg_delay };
        let relay = async move {
            if !allow_relay || p2p_only {
                return Err(anyhow!("relay disabled"));
            }
            tokio::time::sleep(Duration::from_millis(delay)).await;
            let acc = me.account_of(&peer);
            let trusted = me.store.is_friend(&acc) || acc == me.me;
            if trusted {
                for url in their_relays.iter() {
                    me.ensure_relay(url).await;
                }
            }
            // anyone else: only relays the user configured (never one a stranger named)
            let their_relays: Vec<String> = their_relays.into_iter().filter(|u| trusted || me.net.is_user_relay(u)).collect();
            // give newly added relays a moment to connect
            for _ in 0..20 {
                if their_relays.iter().any(|u| me.net.relay_status().iter().any(|(x, ok)| x == u && *ok)) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
            let mut last = anyhow!("no common relay");
            for url in their_relays.iter() {
                match me.net.dial_relay(peer, url).await {
                    Ok(c) => return Ok((c, PathKind::Relay, None)),
                    Err(e) => last = e,
                }
            }
            Err(last)
        };

        // First success wins; failures of one path don't cancel others.
        let mut futs: Vec<std::pin::Pin<Box<dyn std::future::Future<Output = Result<_>> + Send>>> =
            vec![Box::pin(direct), Box::pin(spray), Box::pin(relay)];
        let deadline = tokio::time::sleep(Duration::from_secs(25));
        tokio::pin!(deadline);
        let mut errors = Vec::new();
        loop {
            if futs.is_empty() {
                bail!("all paths failed: {}", errors.join("; "));
            }
            tokio::select! {
                (r, _i, rest) = futures::future::select_all(futs) => {
                    match r {
                        Ok(x) => return Ok(x),
                        Err(e) => { errors.push(e.to_string()); futs = rest; }
                    }
                }
                _ = &mut deadline => bail!("connection timeout: {}", errors.join("; ")),
            }
        }
    }

    /// Peer is reachable only through a relay: try again for a direct path (no relay),
    /// the dedupe logic swaps the connection seamlessly if it succeeds.
    pub async fn try_upgrade(self: &Arc<Self>, peer: PeerId) -> Result<()> {
        // a relayed stranger stays relayed: a direct path would reveal both addresses
        anyhow::ensure!(self.may_reveal_addrs(&peer), crate::i18n::user_err("err.no_faster_path"));
        self.note_solicited(peer);
        let info = self.ensure_info().await;
        let sid: u64 = rand::random();
        let (tx, rx) = oneshot::channel();
        self.pending_answers.lock().insert(sid, (peer, tx));
        let offer = Signal::Offer { sid, info: info.clone(), name: self.name() };
        let sealed = seal_to(&self.id, &peer, &rmp_serde::to_vec(&offer)?)?;
        self.net.send_signal(&peer, sealed, &[]).await;
        let their = tokio::time::timeout(Duration::from_secs(6), rx).await;
        self.pending_answers.lock().remove(&sid);
        let their = their.map_err(|_| crate::i18n::user_err("err.peer_offline"))?.map_err(|_| anyhow!("cancelled"))?;
        // a relay-only answer (we are a stranger to them): there is no direct path to try
        anyhow::ensure!(!their.addrs.is_empty(), crate::i18n::user_err("err.no_faster_path"));
        // Either our attempt succeeds, or the other side's (it punches/sprays too) lands first.
        tokio::select! {
            r = self.race_paths_opt(peer, sid, &info, &their, false) => {
                let (c, path, ep) = r?;
                self.clone().setup_conn(c, path, self.device, ep).await?;
            }
            _ = self.wait_path(peer, true, Duration::from_secs(25)) => {}
        }
        anyhow::ensure!(self.peer(&peer).map(|c| c.path != PathKind::Relay).unwrap_or(false), crate::i18n::user_err("err.no_faster_path"));
        Ok(())
    }

    /// Resolve once the peer is connected (optionally: via a non-relay path).
    pub(super) async fn wait_path(&self, peer: PeerId, direct: bool, max: Duration) {
        let end = Instant::now() + max;
        while Instant::now() < end {
            if let Some(c) = self.peer(&peer) {
                if !direct || c.path != PathKind::Relay {
                    return;
                }
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        futures::future::pending::<()>().await
    }

    /// A replaced connection: drained, then closed (never in the middle of a transfer).
    fn retire(old: Arc<PeerConn>) {
        tokio::spawn(async move {
            // a dead path has nothing in flight worth waiting for (the outbox re-sends)
            if !old.is_suspect() {
                tokio::time::sleep(Duration::from_secs(10)).await;
            }
            // never cut a running file/media transfer; give it up to 30 min to finish
            for _ in 0..1800 {
                if old.busy.load(std::sync::atomic::Ordering::Relaxed) == 0 {
                    break;
                }
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
            old.conn.close(0u32.into(), b"upgraded");
        });
    }

    /// Is `pc` the connection in use for its device?
    pub(crate) fn is_current(&self, pc: &Arc<PeerConn>) -> bool {
        self.peers.read().get(&pc.peer).map(|c| Arc::ptr_eq(c, pc)).unwrap_or(false)
    }

    /// `Ext PATH_CHOSEN` on `pc`: the other side switched to this connection because the
    /// one we kept looked dead to it. Switch too — only when `pc` lost to the connection
    /// still in use and that one wasn't itself a repair (two fresh connections are settled
    /// by the shared tiebreak alone, so both sides end on the same one).
    pub(crate) fn on_path_chosen(self: &Arc<Self>, pc: &Arc<PeerConn>) {
        if !pc.alive() {
            return;
        }
        {
            let peers = self.peers.read();
            if let Some(cur) = peers.get(&pc.peer).filter(|c| c.alive()) {
                if Arc::ptr_eq(cur, pc) {
                    return; // already the one in use
                }
                let lost_to_cur = pc.lost_to.lock().as_ref().and_then(|w| w.upgrade()).map(|l| Arc::ptr_eq(&l, cur)).unwrap_or(false);
                if !lost_to_cur || cur.chosen_by_repair.load(std::sync::atomic::Ordering::Relaxed) {
                    return;
                }
                cur.mark_suspect();
            }
        }
        tracing::info!("{:?} repaired onto another connection: switching too", pc.peer);
        self.adopt(pc);
    }

    /// Make a (so far losing) duplicate the connection in use; the one it replaces is
    /// retired.
    fn adopt(self: &Arc<Self>, pc: &Arc<PeerConn>) {
        pc.chosen_by_repair.store(true, std::sync::atomic::Ordering::Relaxed);
        let old = self.peers.write().insert(pc.peer, pc.clone()).filter(|o| !Arc::ptr_eq(o, pc));
        if let Some(old) = old {
            let pending = old.ctl_rx.lock().take();
            if let Some(mut rx) = pending {
                while let Ok(m) = rx.try_recv() {
                    let _ = pc.ctl.try_send(m);
                }
            }
            if old.alive() {
                Self::retire(old);
            }
        }
        let (me, pc2) = (self.clone(), pc.clone());
        tokio::spawn(async move { me.on_connected(&pc2).await });
    }

    /// Install a freshly established connection (dedupe, spawn tasks, run hello/sync).
    async fn setup_conn(
        self: Arc<Self>,
        conn: quinn::Connection,
        path: PathKind,
        dialer: PeerId,
        extra_ep: Option<quinn::Endpoint>,
    ) -> Result<Arc<PeerConn>> {
        let (peer, cert) = crate::tls::remote_identity(&conn)?;
        if let Some(c) = &cert {
            self.learn_cert(c);
        }
        let account = cert.as_ref().map(|c| c.account).unwrap_or_else(|| self.account_of(&peer));
        if self.store.is_blocked(&account) || self.store.is_blocked(&peer) {
            conn.close(1u32.into(), b"blocked");
            bail!("peer is blocked");
        }
        if self.is_revoked(&account, &peer) {
            conn.close(3u32.into(), b"revoked");
            bail!("device was revoked");
        }
        // The dialer opens the control stream first (cheap, no round trip) so the receiver
        // half is never stranded in a shared slot.
        let (ctl_tx, ctl_rx) = mpsc::channel::<PeerMsg>(1024);
        let mut dial_stream = None;
        if dialer == self.device {
            let (mut send, recv) = conn.open_bi().await?;
            send.write_all(&[proto::STREAM_CONTROL]).await?;
            dial_stream = Some((send, recv));
        }
        let (slot_rx, own_rx) = if dial_stream.is_some() { (None, Some(ctl_rx)) } else { (Some(ctl_rx), None) };
        let pc = Arc::new(PeerConn {
            peer,
            account,
            own: account == self.me && peer != self.device,
            proto: std::sync::atomic::AtomicU32::new(self.peer_proto(&peer)),
            conn: conn.clone(),
            path,
            dialer,
            ctl: ctl_tx,
            since: Instant::now(),
            name: RwLock::new(self.store.contact(&account).map(|c| c.name).unwrap_or_default()),
            ctl_rx: Mutex::new(slot_rx),
            busy: std::sync::atomic::AtomicUsize::new(0),
            sent: Mutex::new(HashMap::new()),
            flushing: std::sync::atomic::AtomicBool::new(false),
            _extra_ep: extra_ep,
            suspect: std::sync::atomic::AtomicBool::new(false),
            suspect_since: Mutex::new(None),
            rx_seen: Mutex::new((0, Instant::now(), None)),
            active_at: std::sync::atomic::AtomicU64::new(now_ms()),
            acks: Mutex::new(Vec::new()),
            ack_notify: tokio::sync::Notify::new(),
            chosen_by_repair: std::sync::atomic::AtomicBool::new(false),
            lost_to: Mutex::new(None),
        });
        // Dedupe atomically: better path wins; on a tie, the connection dialed by the smaller key
        // wins (both sides compute the same answer).
        let existing = {
            let mut peers = self.peers.write();
            let old = peers.get(&peer).filter(|c| c.alive()).cloned();
            if let Some(old) = &old {
                // Both ends derive the same id from the TLS session, so they always agree on
                // which duplicate survives regardless of the order connections completed.
                // A path that looks dead (watchdog, or the peer asked to repair it) loses to
                // any new connection. Only one side may think so (its watchdog fired, the
                // other's didn't yet): that side then says `PATH_CHOSEN` on the new
                // connection and the other switches too (`on_path_chosen`).
                let keep_old = if old.is_suspect() {
                    false
                } else if path.rank() != old.path.rank() {
                    old.path.rank() < path.rank()
                } else if old.path == PathKind::Direct && path == PathKind::Direct && direct_v6(&old.conn) != direct_v6(&conn) {
                    // Two direct paths over different families (both punched at once): keep the
                    // IPv6 one — no NAT on it to time out or rebind. Both ends see the same family
                    // for a given connection, so they still agree (NAT lab v6-pc used to pick
                    // IPv4 about one time in nine through the random tiebreak below).
                    direct_v6(&old.conn)
                } else {
                    conn_tiebreak_id(&old.conn) <= conn_tiebreak_id(&conn)
                };
                if keep_old {
                    let keep = old.clone();
                    *pc.lost_to.lock() = Some(Arc::downgrade(&keep));
                    drop(peers);
                    // Still *read* the losing duplicate until it closes: the other side may have
                    // written frames on it before it reached the same decision.
                    if let (Some((send, recv)), Some(rx)) = (dial_stream, own_rx) {
                        self.clone().spawn_control(pc.clone(), send, recv, rx);
                    }
                    self.clone().spawn_conn_tasks(pc.clone());
                    let (me, dup) = (self.clone(), pc.clone());
                    tokio::spawn(async move {
                        // graceful: let in-flight frames drain before closing the duplicate
                        tokio::time::sleep(Duration::from_secs(10)).await;
                        // (unless the other side repaired onto it meanwhile: then it is ours —
                        // also when the one we kept has died since)
                        if me.is_current(&dup) {
                            return;
                        }
                        if dup.alive() && me.peer(&dup.peer).is_none() {
                            me.adopt(&dup);
                        } else {
                            dup.conn.close(0u32.into(), b"dup");
                        }
                    });
                    return Ok(keep);
                }
                if old.is_suspect() {
                    pc.chosen_by_repair.store(true, std::sync::atomic::Ordering::Relaxed);
                }
            }
            peers.insert(peer, pc.clone());
            old
        };
        if pc.chosen_by_repair.load(std::sync::atomic::Ordering::Relaxed) {
            // tell the other side, which may still trust the old path (older peers skip it)
            let _ = pc.ctl.try_send(proto::ext(proto::ext::PATH_CHOSEN, &PathChosenMsg::default()));
        }
        if let Some(old) = &existing {
            // Messages queued on the retired connection whose control stream never opened
            // would be stranded — move them to the new connection.
            let pending = old.ctl_rx.lock().take();
            if let Some(mut rx) = pending {
                while let Ok(m) = rx.try_recv() {
                    let _ = pc.ctl.try_send(m);
                }
            }
        }
        if let Some(old) = existing {
            Self::retire(old);
        }
        tracing::info!("connected {:?} via {:?} ({})", peer, path, conn.remote_address());

        if let (Some((send, recv)), Some(rx)) = (dial_stream, own_rx) {
            self.clone().spawn_control(pc.clone(), send, recv, rx);
        }
        // (accepting side: the stream acceptor picks up `ctl_rx` when the dialer's stream arrives)
        self.clone().spawn_conn_tasks(pc.clone());
        self.on_connected(&pc).await;
        Ok(pc)
    }
}

/// `Ext PATH_CHOSEN` (empty map; room for later fields).
#[derive(Serialize, Deserialize, Default)]
pub(crate) struct PathChosenMsg {}

#[cfg(test)]
mod lock_tests {
    use super::*;

    #[tokio::test]
    async fn failed_start_releases_the_data_folder() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("data");
        std::fs::create_dir_all(&dir).unwrap();
        crate::keystore::create(&dir, &Identity::generate(), Some("dung-mat-khau")).unwrap();
        let cfg = |pw: &str| NodeConfig {
            data_dir: dir.clone(),
            passphrase: Some(pw.into()),
            enable_lan: false,
            enable_upnp: false,
            enable_dht: false,
            enable_nostr: false,
            relays: Some(vec![]),
            nostr: Some(vec![]),
            stun: Some(vec![]),
            ..Default::default()
        };
        assert!(Node::start(cfg("sai-mat-khau")).await.is_err());
        // the lock is free again: another holder can take it, and the file can be removed
        {
            let f = std::fs::OpenOptions::new().write(true).open(dir.join(".lock")).unwrap();
            assert!(f.try_lock().is_ok(), "data folder still locked after a failed start");
        }
        std::fs::remove_file(dir.join(".lock")).unwrap();
        // …and a correct start in the same process still works (and locks the folder)
        let n = Node::start(cfg("dung-mat-khau")).await.expect("start with the right password");
        let f = std::fs::OpenOptions::new().write(true).open(dir.join(".lock")).unwrap();
        assert!(matches!(f.try_lock(), Err(std::fs::TryLockError::WouldBlock)));
        n.shutdown();
    }

    /// Review #4: a restore over existing data (e.g. an abandoned link identity) used to
    /// be silently ignored and the half-made identity kept. It must be refused, unless
    /// the phrase is the existing account's own.
    #[test]
    fn restore_over_existing_keystore_is_refused() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("data");
        std::fs::create_dir_all(&dir).unwrap();
        let mine = Identity::generate();
        crate::keystore::create(&dir, &mine, None).unwrap();
        let other = Identity::generate();
        let with = |phrase: Option<String>, backup: Option<(String, String)>| NodeConfig {
            data_dir: dir.clone(),
            recovery_phrase: phrase,
            restore_backup: backup,
            ..Default::default()
        };
        let err = Node::open_keystore(&with(Some(other.recovery_phrase().to_string()), None)).err().expect("other phrase refused");
        assert!(format!("{err:#}").contains(&crate::i18n::tr("err.restore_data_exists")), "{err:#}");
        assert!(Node::open_keystore(&with(None, Some(("/nope.lumora-backup".into(), "pw".into())))).is_err(), "backup over data refused");
        let same = Node::open_keystore(&with(Some(mine.recovery_phrase().to_string()), None)).expect("same account reopens");
        assert_eq!(same.identity.peer_id(), mine.peer_id());
        assert_eq!(Node::open_keystore(&with(None, None)).unwrap().identity.peer_id(), mine.peer_id());
    }

    /// PoC: the data password (and restore secrets) stayed in `node.cfg` for the life of
    /// the process, and the data folder / database were created with the umask (0755/0644).
    #[tokio::test]
    async fn start_scrubs_secrets_and_keeps_the_data_folder_private() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("data");
        let n = Node::start(NodeConfig {
            data_dir: dir.clone(),
            passphrase: Some("mat-khau-du-lieu".into()),
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
        assert!(n.cfg.passphrase.is_none(), "data password kept in memory after unlock");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode(&dir), 0o700, "data folder open to other users");
            assert_eq!(mode(&dir.join("lumora.db")), 0o600, "database readable by other users");
        }
        n.shutdown();
    }
}
