//! iPhone wake-ups through the optional push bridge (crate `lumora-push`,
//! docs/src/ops/push.md, docs/src/platforms/apple.md).
//!
//! * **Registering (on the iPhone):** `push_register` seals the APNs/VoIP tokens to the
//!   bridge's public key and keeps the resulting [`PushReg`] (map-encoded, extensible) in
//!   kv `push.self`. It is sent with `PeerMsg::PushReg` to friends whose `Hello.app`
//!   carries the [`CAP`] token, so older peers never receive a variant they can't decode.
//! * **Waking (on everyone else):** friends keep the blob in kv `push.peer.<id>`. When
//!   `deliver` has to queue chat content for that peer because it is offline, we POST
//!   `{bridge}/wake` **once per burst** ([`COALESCE`], reset when the peer connects).
//!   A call to an offline iPhone sends a `call` wake (PushKit → CallKit on the phone).
//! * The bridge sees an opaque token and an optional blob sealed to the recipient's
//!   notification key (sender name + short preview, opened by the Notification Service
//!   Extension on the phone). Nothing else.
//! * **Expiry and revocation:** sealed tokens expire after `lumora_push::TOKEN_TTL_SECS`;
//!   the phone re-seals a fresh copy (same generation) for friends that connect once its
//!   copy is a week old ([`REFRESH_AFTER_MS`]). A registration with a changed device token
//!   / bridge (or `rotate: true`) starts a new *generation* and tells the bridge
//!   (`POST /register`): every older copy friends still hold is refused from then on.
//!   `push_unregister` revokes all of them the same way.

use super::*;
use lumora_push::{Notify, PushReg, WakeRequest};
use std::collections::HashSet;
use std::sync::OnceLock;

/// Capability token appended to `Hello.app`.
pub const CAP: &str = "+push1";
/// At most one message wake per peer per this long while it stays offline.
pub const COALESCE: Duration = Duration::from_secs(60);
const CALL_COALESCE: Duration = Duration::from_secs(20);
/// Re-seal our token for friends (new expiry, same generation) once it is this old.
pub const REFRESH_AFTER_MS: u64 = 7 * 86_400_000;
/// kv key of our own unsealed registration (device tokens + bridge key; never sent).
const SELF_DEV: &str = "push.self.dev";

/// What we sealed last time, kept on this device only so the token can be refreshed and
/// revoked without the app's help.
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq)]
struct SelfDev {
    bridge: String,
    #[serde(with = "serde_bytes")]
    bridge_key: Vec<u8>,
    token: lumora_push::DeviceToken,
}

impl SelfDev {
    fn load(store: &crate::store::Store) -> Option<SelfDev> {
        store.kv_get(SELF_DEV).and_then(|b| crate::proto::from_slice_capped(&b).ok())
    }
    fn key(&self) -> Option<[u8; 32]> {
        self.bridge_key.as_slice().try_into().ok()
    }
    /// Same phone, same app, same bridge (expiry / generation aside)?
    fn same_device(&self, o: &SelfDev) -> bool {
        let (a, b) = (&self.token, &o.token);
        self.bridge == o.bridge && self.bridge_key == o.bridge_key && a.apns == b.apns && a.voip == b.voip && a.topic == b.topic && a.sandbox == b.sandbox
    }
}

/// Generation for a new registration: never lower than (or equal to) the previous one,
/// even if the clock went backwards.
fn next_generation(prev: Option<u64>) -> u64 {
    crate::util::now_ms().max(prev.map(|g| g + 1).unwrap_or(0))
}

fn token_exp() -> u64 {
    crate::util::now_ms() / 1000 + lumora_push::TOKEN_TTL_SECS
}
const PREVIEW_CHARS: usize = 140;

/// `Hello.app` value: `lumora/<version> +push1`.
pub fn app_string() -> String {
    format!("lumora/{} {CAP}", env!("CARGO_PKG_VERSION"))
}

pub fn peer_supports(app: &str) -> bool {
    app.split_whitespace().any(|t| t == CAP)
}

/// Should queuing `m` for an offline peer wake it, and with which preview?
/// `Some("")` = wake without preview (groups, friend requests, media).
pub fn preview_of(m: &PeerMsg) -> Option<(String, Option<String>)> {
    match m {
        PeerMsg::Chat(c) => Some((c.body.preview().chars().take(PREVIEW_CHARS).collect(), None)),
        PeerMsg::FriendRequest { .. } => Some((String::new(), None)),
        PeerMsg::Group { gid, .. } => Some((String::new(), Some(format!("g:{}", hex::encode(gid))))),
        PeerMsg::BotGroupPost { gid, .. } => Some((String::new(), Some(format!("g:{}", hex::encode(gid))))),
        _ => None,
    }
}

type Key = (PeerId, PeerId); // (me, peer): several nodes may share one process (tests)

fn last_wake() -> &'static Mutex<HashMap<(Key, bool), Instant>> {
    static M: OnceLock<Mutex<HashMap<(Key, bool), Instant>>> = OnceLock::new();
    M.get_or_init(|| Mutex::new(HashMap::new()))
}

fn capable() -> &'static Mutex<HashSet<Key>> {
    static M: OnceLock<Mutex<HashSet<Key>>> = OnceLock::new();
    M.get_or_init(|| Mutex::new(HashSet::new()))
}

/// Returns true (and records the time) if a wake may be sent now.
fn coalesce_take(key: Key, call: bool) -> bool {
    let mut m = last_wake().lock();
    if m.len() > 4096 {
        m.retain(|_, t| t.elapsed() < COALESCE);
    }
    let window = if call { CALL_COALESCE } else { COALESCE };
    match m.get(&(key, call)) {
        Some(t) if t.elapsed() < window => false,
        _ => {
            m.insert((key, call), Instant::now());
            true
        }
    }
}

fn peer_key(p: &PeerId) -> String {
    format!("push.peer.{}", p.to_base32())
}

impl Node {
    // ------------------------------------------------------------ the iPhone side

    /// Register this device for wake-ups. Params (JSON): `bridge_url`, `bridge_key` (base64
    /// X25519), `apns` (hex), optional `voip` (hex), `topic` (bundle id), `sandbox`,
    /// optional `notify_key` (base64 X25519 public key of the notification extension).
    pub fn push_register(self: &Arc<Self>, p: &Value) -> Result<Value> {
        let s = |k: &str| p.get(k).and_then(|v| v.as_str()).unwrap_or("").trim().to_string();
        let bridge = s("bridge_url");
        anyhow::ensure!(lumora_push::bridge_url_allowed(&bridge), "push bridge URL must be https:// (or http:// on this machine)");
        let bridge_key = lumora_push::key32(&s("bridge_key")).ok_or_else(|| anyhow!("bad bridge_key"))?;
        let hexok = |t: &str| !t.is_empty() && t.len() <= 200 && t.bytes().all(|c| c.is_ascii_hexdigit());
        let apns = s("apns").to_ascii_lowercase();
        let voip = s("voip").to_ascii_lowercase();
        anyhow::ensure!(hexok(&apns), "bad APNs token");
        anyhow::ensure!(voip.is_empty() || hexok(&voip), "bad VoIP token");
        let topic = s("topic");
        anyhow::ensure!(!topic.is_empty() && topic.len() <= 155, "missing topic (bundle id)");
        let notify = match s("notify_key").as_str() {
            "" => vec![],
            k => lumora_push::key32(k).ok_or_else(|| anyhow!("bad notify_key"))?.to_vec(),
        };
        let token = lumora_push::DeviceToken { apns, voip, topic, sandbox: p.get("sandbox").and_then(|v| v.as_bool()).unwrap_or(false), exp: 0, gen: 0 };
        let mut dev = SelfDev { bridge: bridge.clone(), bridge_key: bridge_key.to_vec(), token };
        // The app registers on every launch: an identical registration keeps its generation
        // (friends that were offline meanwhile keep a working copy); a new device token,
        // bridge, or an explicit `rotate` revokes every copy handed out so far.
        let prev = SelfDev::load(&self.store);
        let rotate = p.get("rotate").and_then(|v| v.as_bool()).unwrap_or(false);
        let rotated = match &prev {
            Some(old) if old.same_device(&dev) && old.token.gen != 0 && !rotate => {
                dev.token.gen = old.token.gen;
                false
            }
            _ => {
                dev.token.gen = next_generation(prev.as_ref().map(|o| o.token.gen));
                true
            }
        };
        dev.token.exp = token_exp();
        let sealed = lumora_push::seal_token(&bridge_key, &dev.token);
        self.store.kv_set(SELF_DEV, &rmp_serde::to_vec_named(&dev)?)?;
        let reg = PushReg { v: 1, bridge: bridge.clone(), token: sealed.clone(), notify, at: crate::util::now_ms() };
        self.store.kv_set("push.self", &reg.encode())?;
        if rotated {
            // tell the bridge now, so older copies stop working before anyone uses this one
            let body = serde_json::to_vec(&lumora_push::RegisterRequest { token: lumora_push::b64(&sealed) }).unwrap_or_default();
            let url = bridge.clone();
            tokio::spawn(async move {
                match http_post(&url, "/register", &body).await {
                    Ok(s) => tracing::debug!("push bridge registration: HTTP {s}"),
                    Err(e) => tracing::debug!("push bridge registration failed: {e:#}"),
                }
            });
            // a different bridge: revoke what the old one would still accept
            if let Some(old) = prev.filter(|o| o.bridge != bridge || o.bridge_key != dev.bridge_key) {
                Self::push_revoke_at(old, dev.token.gen);
            }
        }
        let n = self.push_broadcast(&reg);
        Ok(json!({"registered": true, "friends_notified": n, "rotated": rotated}))
    }

    /// Stop wake-ups: friends get a revocation (empty registration), and the bridge is told
    /// to refuse every token this device handed out.
    pub fn push_unregister(self: &Arc<Self>) -> Result<Value> {
        let reg = PushReg { v: 1, at: crate::util::now_ms(), ..Default::default() };
        self.store.kv_set("push.self", &reg.encode())?;
        if let Some(old) = SelfDev::load(&self.store) {
            let gen = next_generation(Some(old.token.gen));
            Self::push_revoke_at(old, gen);
        }
        self.store.kv_del(SELF_DEV)?;
        let n = self.push_broadcast(&reg);
        Ok(json!({"registered": false, "friends_notified": n}))
    }

    /// Register an already-expired token of generation `gen` at `old`'s bridge: the bridge
    /// learns the newer generation (so it refuses all older copies) while the token itself
    /// wakes nothing.
    fn push_revoke_at(old: SelfDev, gen: u64) {
        let Some(key) = old.key() else { return };
        if !lumora_push::bridge_url_allowed(&old.bridge) {
            return;
        }
        let t = lumora_push::DeviceToken { gen, exp: 1, ..old.token };
        let body = serde_json::to_vec(&lumora_push::RegisterRequest { token: lumora_push::b64(&lumora_push::seal_token(&key, &t)) }).unwrap_or_default();
        tokio::spawn(async move {
            let _ = http_post(&old.bridge, "/register", &body).await;
        });
    }

    /// Our registration blob for a friend, re-sealed with a fresh expiry (same generation)
    /// once the stored copy is [`REFRESH_AFTER_MS`] old.
    fn push_self_blob(&self) -> Option<Vec<u8>> {
        let blob = self.store.kv_get("push.self")?;
        let reg = PushReg::decode(&blob)?;
        if !reg.is_active() || crate::util::now_ms().saturating_sub(reg.at) < REFRESH_AFTER_MS {
            return Some(blob);
        }
        let Some(mut dev) = SelfDev::load(&self.store).filter(|d| d.bridge == reg.bridge) else { return Some(blob) };
        let Some(key) = dev.key() else { return Some(blob) };
        dev.token.exp = token_exp();
        let fresh = PushReg { token: lumora_push::seal_token(&key, &dev.token), at: crate::util::now_ms(), ..reg };
        let b = fresh.encode();
        let _ = self.store.kv_set(SELF_DEV, &rmp_serde::to_vec_named(&dev).unwrap_or_default());
        let _ = self.store.kv_set("push.self", &b);
        Some(b)
    }

    pub fn push_status(&self) -> Value {
        let me = self.store.kv_get("push.self").and_then(|b| PushReg::decode(&b)).filter(|r| r.is_active());
        let friends: Vec<String> = self
            .store
            .friend_ids()
            .into_iter()
            .filter(|f| self.store.kv_get(&peer_key(f)).and_then(|b| PushReg::decode(&b)).map(|r| r.is_active()).unwrap_or(false))
            .map(|f| f.to_base32())
            .collect();
        json!({"registered": me.is_some(), "bridge": me.map(|r| r.bridge), "friends_with_push": friends})
    }

    fn push_broadcast(&self, reg: &PushReg) -> usize {
        let blob = reg.encode();
        let caps = capable().lock().clone();
        let mut n = 0;
        for pc in self.connected_peers() {
            if self.store.is_friend(&pc.account) && caps.contains(&(self.me, pc.peer)) && pc.ctl.try_send(PeerMsg::PushReg { blob: blob.clone() }).is_ok() {
                n += 1;
            }
        }
        n
    }

    // ------------------------------------------------------------ protocol hooks

    /// `Hello` received: remember whether the peer understands `PushReg`; if so and it is a
    /// friend, hand it our registration.
    pub(super) fn push_on_hello(self: &Arc<Self>, pc: &Arc<PeerConn>, app: &str) {
        if !peer_supports(app) {
            capable().lock().remove(&(self.me, pc.peer));
            return;
        }
        // only friends are ever woken (and a stranger's Hello must not grow this set)
        if !(pc.own || self.store.is_friend(&pc.account)) {
            return;
        }
        capable().lock().insert((self.me, pc.peer));
        if self.store.is_friend(&pc.account) {
            if let Some(blob) = self.push_self_blob() {
                let _ = pc.ctl.try_send(PeerMsg::PushReg { blob });
            }
        }
    }

    pub(super) fn push_on_reg(&self, from: PeerId, blob: &[u8]) -> Result<()> {
        if !self.store.is_friend(&self.account_of(&from)) {
            return Ok(());
        }
        let Some(reg) = PushReg::decode(blob) else { return Ok(()) };
        if reg.is_active() && !lumora_push::bridge_url_allowed(&reg.bridge) {
            return Ok(());
        }
        let old = self.store.kv_get(&peer_key(&from)).and_then(|b| PushReg::decode(&b));
        if old.as_ref().map(|o| o.at > reg.at).unwrap_or(false) {
            return Ok(()); // stale
        }
        self.store.kv_set(&peer_key(&from), &reg.encode())?;
        tracing::debug!("push registration from {from:?}: {}", if reg.is_active() { "active" } else { "revoked" });
        Ok(())
    }

    /// The peer is reachable again: the next offline burst may wake it again.
    pub(super) fn push_on_connected(&self, peer: &PeerId) {
        let mut m = last_wake().lock();
        m.remove(&((self.me, *peer), false));
        m.remove(&((self.me, *peer), true));
    }

    fn push_reg_of(&self, peer: &PeerId) -> Option<PushReg> {
        self.store.kv_get(&peer_key(peer)).and_then(|b| PushReg::decode(&b)).filter(|r| r.is_active())
    }

    /// `deliver` queued wake-worthy content for an offline peer.
    pub(super) fn push_on_queued(self: &Arc<Self>, to: PeerId, preview: String, conv: Option<String>) {
        let Some(reg) = self.push_reg_of(&to) else { return };
        if !coalesce_take((self.me, to), false) {
            return;
        }
        let n = Notify {
            k: "msg".into(),
            from: self.me.to_base32(),
            name: self.name(),
            preview,
            conv: conv.unwrap_or_else(|| format!("d:{}", self.me.to_base32())),
            t: crate::util::now_ms(),
            ..Default::default()
        };
        let me = self.clone();
        tokio::spawn(async move { me.post_wake(to, &reg, "msg", &n).await });
    }

    /// Ring an offline iPhone. Returns true if a wake was sent (caller then keeps retrying
    /// the invite while the phone starts Lumora).
    pub(super) async fn push_call_wake(self: &Arc<Self>, to: PeerId, call_id: [u8; 16], video: bool) -> bool {
        if self.is_online(&to) {
            return false;
        }
        let Some(reg) = self.push_reg_of(&to) else { return false };
        if !coalesce_take((self.me, to), true) {
            return true;
        }
        let n = Notify {
            k: "call".into(),
            from: self.me.to_base32(),
            name: self.name(),
            conv: format!("d:{}", self.me.to_base32()),
            call: hex::encode(call_id),
            video,
            t: crate::util::now_ms(),
            ..Default::default()
        };
        self.post_wake(to, &reg, "call", &n).await == 202
    }

    async fn post_wake(&self, to: PeerId, reg: &PushReg, kind: &str, n: &Notify) -> u16 {
        let e2e = reg.notify_key().map(|k| lumora_push::b64(&lumora_push::seal_notify(&k, n))).unwrap_or_default();
        let body = serde_json::to_vec(&WakeRequest { token: lumora_push::b64(&reg.token), kind: kind.into(), e2e }).unwrap_or_default();
        let status = match http_post(&reg.bridge, "/wake", &body).await {
            Ok(s) => s,
            Err(e) => {
                tracing::debug!("push wake for {to:?} failed: {e:#}");
                return 0;
            }
        };
        tracing::debug!("push wake ({kind}) for {to:?}: HTTP {status}");
        if status == 410 {
            // the phone uninstalled Lumora / switched off notifications: stop calling the bridge
            let dead = PushReg { v: 1, at: reg.at, ..Default::default() };
            let _ = self.store.kv_set(&peer_key(&to), &dead.encode());
        }
        status
    }

    // ------------------------------------------------------------ app lifecycle

    /// The app came back to the foreground (or the network changed): reconnect now instead of
    /// waiting for back-off timers, so friends flush what they queued for us (outbox / mailbox).
    pub fn resume(self: &Arc<Self>) -> Value {
        self.backoff.lock().clear();
        // (a new network, maybe: failed relay → direct upgrades may work now)
        self.upgrade_backoff.lock().clear();
        let mut targets = self.store.friend_ids();
        let queued = self.store.outbox_peers().unwrap_or_default();
        for p in queued.iter() {
            if !targets.contains(p) {
                targets.push(*p);
            }
        }
        targets.retain(|p| !self.is_online(p));
        // IP privacy (same gate as the reconnect sweep): only people allowed to learn my
        // addresses are dialed; what waits for anyone else goes as sealed mail
        let (dial, mail): (Vec<PeerId>, Vec<PeerId>) = targets.into_iter().partition(|p| self.may_reveal_addrs(p));
        let mut dial = dial;
        dial.truncate(64);
        let n = dial.len();
        for (i, p) in dial.into_iter().enumerate() {
            let node = self.clone();
            tokio::spawn(async move {
                // small stagger: 64 simultaneous handshakes would hurt a phone on cellular
                tokio::time::sleep(Duration::from_millis(40 * i as u64)).await;
                let _ = node.connect(p).await;
            });
        }
        for p in mail.into_iter().filter(|p| queued.contains(p)).take(64) {
            let node = self.clone();
            tokio::spawn(async move { node.remail_outbox(p).await });
        }
        json!({"dialing": n})
    }
}

/// Minimal HTTP/1.1 POST (JSON) over TCP or TLS; returns the status code.
async fn http_post(base: &str, path: &str, body: &[u8]) -> Result<u16> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let (tls, rest) = if let Some(r) = base.strip_prefix("https://") {
        (true, r)
    } else if let Some(r) = base.strip_prefix("http://") {
        (false, r)
    } else {
        bail!("unsupported URL");
    };
    let (authority, prefix) = match rest.split_once('/') {
        Some((a, p)) => (a, format!("/{}", p.trim_end_matches('/'))),
        None => (rest, String::new()),
    };
    let (host, port) = match authority.rsplit_once(':') {
        Some((h, p)) if !h.contains(':') => (h.to_string(), p.parse::<u16>()?),
        _ => (authority.trim_matches(['[', ']']).to_string(), if tls { 443 } else { 80 }),
    };
    let head = format!(
        "POST {prefix}{path} HTTP/1.1\r\nHost: {authority}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nUser-Agent: lumora\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let mut req = head.into_bytes();
    req.extend_from_slice(body);
    let fut = async {
        let tcp = tokio::net::TcpStream::connect((host.as_str(), port)).await?;
        let mut resp = Vec::new();
        if tls {
            let mut roots = tokio_rustls::rustls::RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            let cfg = tokio_rustls::rustls::ClientConfig::builder_with_provider(Arc::new(tokio_rustls::rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()?
                .with_root_certificates(roots)
                .with_no_client_auth();
            let name = tokio_rustls::rustls::pki_types::ServerName::try_from(host.clone())?;
            let mut s = tokio_rustls::TlsConnector::from(Arc::new(cfg)).connect(name, tcp).await?;
            s.write_all(&req).await?;
            let _ = (&mut s).take(4096).read_to_end(&mut resp).await;
        } else {
            let mut s = tcp;
            s.write_all(&req).await?;
            let _ = (&mut s).take(4096).read_to_end(&mut resp).await;
        }
        let line = String::from_utf8_lossy(&resp).lines().next().unwrap_or("").to_string();
        let code: u16 = line.split_whitespace().nth(1).and_then(|c| c.parse().ok()).ok_or_else(|| anyhow!("bad HTTP response"))?;
        Ok::<u16, anyhow::Error>(code)
    };
    tokio::time::timeout(Duration::from_secs(15), fut).await.map_err(|_| anyhow!("timeout"))?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capability_token() {
        assert!(peer_supports(&app_string()));
        assert!(!peer_supports("lumora/0.1.0"));
        assert!(!peer_supports("lumora/0.1.0 +push10"));
    }

    #[test]
    fn coalescing_is_per_pair_and_kind() {
        let a = PeerId([1; 32]);
        let b = PeerId([2; 32]);
        let c = PeerId([3; 32]);
        assert!(coalesce_take((a, b), false));
        assert!(!coalesce_take((a, b), false));
        assert!(coalesce_take((a, c), false));
        assert!(coalesce_take((a, b), true));
        assert!(coalesce_take((c, b), false));
    }

    /// Mock bridge: records `(path, body)` of every POST, answers 202.
    async fn mock_bridge() -> (String, Arc<Mutex<Vec<(String, Value)>>>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", l.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(vec![]));
        let s2 = seen.clone();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = l.accept().await {
                let mut buf = vec![];
                let mut chunk = [0u8; 4096];
                loop {
                    let n = s.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 {
                        break;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                    let t = String::from_utf8_lossy(&buf).to_string();
                    if let Some((head, body)) = t.split_once("\r\n\r\n") {
                        let len: usize = head.lines().find_map(|l| l.strip_prefix("Content-Length: ")).and_then(|v| v.trim().parse().ok()).unwrap_or(0);
                        if body.len() >= len {
                            let path = head.split_whitespace().nth(1).unwrap_or("").to_string();
                            s2.lock().push((path, serde_json::from_str(body).unwrap_or(Value::Null)));
                            break;
                        }
                    }
                }
                let _ = s.write_all(b"HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\n\r\n").await;
            }
        });
        (url, seen)
    }

    #[tokio::test]
    async fn registration_generations_expiry_refresh_and_revocation() {
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
        let bridge = lumora_push::KeyPair::generate();
        let (url, seen) = mock_bridge().await;
        let params = |apns: &str, rotate: bool| {
            json!({"bridge_url": url, "bridge_key": lumora_push::b64(&bridge.public), "apns": apns, "voip": "cd".repeat(32),
                   "topic": "vn.lumora.lumora", "rotate": rotate})
        };
        let mine = |n: &Arc<Node>| {
            let r = PushReg::decode(&n.store.kv_get("push.self").unwrap()).unwrap();
            (r.clone(), lumora_push::open_token(&bridge, &r.token).unwrap())
        };
        let wait_posts = |k: usize| {
            let seen = seen.clone();
            async move {
                for _ in 0..200 {
                    if seen.lock().len() >= k {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
                seen.lock().clone()
            }
        };
        let now_s = crate::util::now_ms() / 1000;

        // first registration: a generation, a 30-day expiry, and the bridge is told
        let r = n.push_register(&params(&"ab".repeat(32), false)).unwrap();
        assert_eq!(r["rotated"], true);
        let (_, t1) = mine(&n);
        assert!(t1.gen > 0 && t1.exp >= now_s + lumora_push::TOKEN_TTL_SECS - 5 && t1.exp <= now_s + lumora_push::TOKEN_TTL_SECS + 5, "{t1:?}");
        let posts = wait_posts(1).await;
        assert_eq!(posts[0].0, "/register");
        let sent = lumora_push::open_token(&bridge, &lumora_push::unb64(posts[0].1["token"].as_str().unwrap()).unwrap()).unwrap();
        assert_eq!(sent.gen, t1.gen);

        // the app re-registers on every launch: same generation, nothing revoked
        let r = n.push_register(&params(&"ab".repeat(32), false)).unwrap();
        assert_eq!(r["rotated"], false);
        assert_eq!(mine(&n).1.gen, t1.gen);

        // a new device token (or rotate:true) starts a newer generation
        n.push_register(&params(&"ef".repeat(32), false)).unwrap();
        let (_, t2) = mine(&n);
        assert!(t2.gen > t1.gen);
        n.push_register(&params(&"ef".repeat(32), true)).unwrap();
        let (_, t3) = mine(&n);
        assert!(t3.gen > t2.gen);
        assert_eq!(wait_posts(3).await.len(), 3);

        // a week later a friend connecting gets a refreshed copy: new expiry, same generation
        let (mut reg, _) = mine(&n);
        let mut dev = SelfDev::load(&n.store).unwrap();
        dev.token.exp = now_s + 3600;
        reg.token = lumora_push::seal_token(&bridge.public, &dev.token);
        reg.at = crate::util::now_ms() - REFRESH_AFTER_MS - 1000;
        n.store.kv_set(SELF_DEV, &rmp_serde::to_vec_named(&dev).unwrap()).unwrap();
        n.store.kv_set("push.self", &reg.encode()).unwrap();
        let fresh = PushReg::decode(&n.push_self_blob().unwrap()).unwrap();
        let ft = lumora_push::open_token(&bridge, &fresh.token).unwrap();
        assert_eq!(ft.gen, t3.gen);
        assert!(ft.exp > now_s + lumora_push::TOKEN_TTL_SECS - 5 && fresh.at > reg.at);
        // a recent copy is handed out as is
        assert_eq!(n.push_self_blob().unwrap(), fresh.encode());

        // unregister: friends get an empty registration, the bridge a newer, already
        // expired generation (revoking every copy), and the device tokens are forgotten
        n.push_unregister().unwrap();
        let posts = wait_posts(4).await;
        let revoke = lumora_push::open_token(&bridge, &lumora_push::unb64(posts[3].1["token"].as_str().unwrap()).unwrap()).unwrap();
        assert!(revoke.gen > t3.gen && revoke.expired(now_s));
        assert!(!PushReg::decode(&n.store.kv_get("push.self").unwrap()).unwrap().is_active());
        assert!(n.store.kv_get(SELF_DEV).is_none());
        n.shutdown();
    }

    #[test]
    fn generations_only_grow() {
        let g = next_generation(None);
        assert!(g >= crate::util::now_ms() - 1000);
        assert_eq!(next_generation(Some(u64::MAX - 1)), u64::MAX);
        assert!(next_generation(Some(g)) > g);
    }

    #[tokio::test]
    async fn http_post_reads_status() {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = l.local_addr().unwrap();
        tokio::spawn(async move {
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            let (mut s, _) = l.accept().await.unwrap();
            let mut buf = vec![0u8; 2048];
            let n = s.read(&mut buf).await.unwrap();
            let req = String::from_utf8_lossy(&buf[..n]).to_string();
            assert!(req.starts_with("POST /base/wake HTTP/1.1\r\n"), "{req}");
            s.write_all(b"HTTP/1.1 410 Gone\r\nContent-Length: 0\r\n\r\n").await.unwrap();
        });
        assert_eq!(http_post(&format!("http://{addr}/base"), "/wake", b"{}").await.unwrap(), 410);
    }
}
