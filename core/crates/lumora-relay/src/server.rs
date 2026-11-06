//! HTTP + WebSocket server, session registry and forwarding.

use crate::config::Config;
use crate::mailbox::Mailbox;
use crate::relay_proto::*;
use crate::stun;
use anyhow::Context;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::{Json, Router};
use axum_server::Handle;
use ed25519_dalek::{Signature, VerifyingKey};
use futures::{SinkExt, StreamExt};
use parking_lot::Mutex;
use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{mpsc, Notify};
use tokio::task::JoinHandle;

/// Maximum accepted |now - hello.ts|.
const HELLO_MAX_SKEW_MS: u64 = 5 * 60 * 1000;
/// How long a (pubkey, ts) pair is remembered to reject replays (> 2x skew window).
const REPLAY_KEEP_MS: u64 = 11 * 60 * 1000;
/// A write that takes longer than this means the client is stuck.
const WRITE_TIMEOUT: Duration = Duration::from_secs(20);

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn short(pk: &[u8; 32]) -> String {
    let s = data_encoding::BASE32_NOPAD.encode(pk).to_lowercase();
    s[..12].to_string()
}

fn error_frame(msg: &str) -> Vec<u8> {
    let mut v = Vec::with_capacity(1 + msg.len());
    v.push(T_ERROR);
    v.extend_from_slice(msg.as_bytes());
    v
}

#[derive(Default)]
struct Kill {
    notify: Notify,
    reason: Mutex<Option<&'static str>>,
}

impl Kill {
    fn fire(&self, reason: &'static str) {
        let mut r = self.reason.lock();
        if r.is_none() {
            *r = Some(reason);
            self.notify.notify_one();
        }
    }
}

#[derive(Clone)]
struct SessionHandle {
    id: u64,
    tx: mpsc::Sender<Vec<u8>>,
    kill: Arc<Kill>,
}

#[derive(Default)]
struct Stats {
    bytes_relayed: AtomicU64,
    data_frames: AtomicU64,
    signal_frames: AtomicU64,
    data_dropped: AtomicU64,
    signals_stored: AtomicU64,
    hello_rejected: AtomicU64,
    sessions_total: AtomicU64,
}

pub(crate) struct Shared {
    cfg: Config,
    sessions: Mutex<HashMap<[u8; 32], SessionHandle>>,
    conns: AtomicUsize,
    next_id: AtomicU64,
    replay: Mutex<HashMap<([u8; 32], u64), u64>>,
    mailbox: Mutex<Mailbox>,
    allow: Option<HashSet<[u8; 32]>>,
    started: Instant,
    stats: Stats,
}

/// A running relay (HTTP/WS server + optional STUN responder).
pub struct Relay {
    /// Bound HTTP(S) address (useful with port 0).
    pub addr: SocketAddr,
    /// Bound STUN UDP address, if enabled.
    pub stun_addr: Option<SocketAddr>,
    handle: Handle<SocketAddr>,
    shared: Arc<Shared>,
    server: JoinHandle<std::io::Result<()>>,
    aux: Vec<JoinHandle<()>>,
}

impl Relay {
    /// Close every session, stop accepting, persist the mailbox.
    pub async fn shutdown(self) {
        tracing::info!("shutting down");
        self.handle.graceful_shutdown(Some(Duration::from_secs(5)));
        let sessions: Vec<SessionHandle> = self.shared.sessions.lock().values().cloned().collect();
        for s in sessions {
            s.kill.fire("relay shutting down");
        }
        let _ = tokio::time::timeout(Duration::from_secs(6), self.server).await;
        for t in self.aux {
            t.abort();
        }
        save_mailbox(&self.shared).await;
    }
}

fn parse_allow(text: &str) -> anyhow::Result<HashSet<[u8; 32]>> {
    let mut set = HashSet::new();
    for (n, line) in text.lines().enumerate() {
        let s = line.split('#').next().unwrap_or("").trim();
        if s.is_empty() {
            continue;
        }
        let bytes = if s.len() == 64 {
            hex::decode(s).ok()
        } else {
            data_encoding::BASE32_NOPAD.decode(s.to_uppercase().as_bytes()).ok()
        };
        let pk: [u8; 32] = bytes
            .and_then(|b| b.try_into().ok())
            .with_context(|| format!("allow file line {}: not a 32-byte hex/base32 key", n + 1))?;
        set.insert(pk);
    }
    Ok(set)
}

/// Bind and start serving. Returns once listening.
pub async fn start(cfg: Config) -> anyhow::Result<Relay> {
    let allow = match &cfg.allow {
        Some(p) => {
            let text = std::fs::read_to_string(p).with_context(|| format!("reading {}", p.display()))?;
            let set = parse_allow(&text)?;
            tracing::info!(keys = set.len(), "private relay mode (allow list)");
            Some(set)
        }
        None => None,
    };
    let mut mailbox = Mailbox::new(cfg.mailbox_max_items, cfg.mailbox_max_item, cfg.mailbox_total, cfg.mailbox_ttl * 1000);
    if let (true, Some(p)) = (cfg.mailbox, &cfg.mailbox_file) {
        if p.exists() {
            match mailbox.load(p, now_ms()) {
                Ok(n) => tracing::info!(items = n, file = %p.display(), "mailbox loaded"),
                Err(e) => tracing::warn!(error = %e, file = %p.display(), "mailbox file ignored"),
            }
        }
    }
    let shared = Arc::new(Shared {
        sessions: Mutex::new(HashMap::new()),
        conns: AtomicUsize::new(0),
        next_id: AtomicU64::new(1),
        replay: Mutex::new(HashMap::new()),
        mailbox: Mutex::new(mailbox),
        allow,
        started: Instant::now(),
        stats: Stats::default(),
        cfg,
    });

    let mut aux = Vec::new();
    let mut stun_addr = None;
    if shared.cfg.stun_port != 0 {
        let bind = SocketAddr::new(shared.cfg.stun_bind, shared.cfg.stun_port);
        let sock = tokio::net::UdpSocket::bind(bind).await.with_context(|| format!("binding STUN on udp {bind}"))?;
        stun_addr = Some(sock.local_addr()?);
        aux.push(tokio::spawn(stun::serve(sock)));
    }
    aux.push(tokio::spawn(janitor(shared.clone())));

    let app = Router::new()
        .route("/", get(root))
        .route("/health", get(health))
        .route("/ws", get(ws_handler))
        .with_state(shared.clone())
        .into_make_service_with_connect_info::<SocketAddr>();

    let handle: Handle<SocketAddr> = Handle::new();
    let listener = std::net::TcpListener::bind(shared.cfg.listen).with_context(|| format!("binding tcp {}", shared.cfg.listen))?;
    listener.set_nonblocking(true)?;
    let addr = listener.local_addr()?;
    let tls = match (&shared.cfg.tls_cert, &shared.cfg.tls_key) {
        (Some(c), Some(k)) => Some(
            axum_server::tls_rustls::RustlsConfig::from_pem_file(c, k)
                .await
                .context("loading TLS certificate/key")?,
        ),
        _ => None,
    };
    let scheme = if tls.is_some() { "wss" } else { "ws" };
    let server = match tls {
        Some(tls) => {
            let srv = axum_server::from_tcp_rustls(listener, tls)?.handle(handle.clone());
            tokio::spawn(async move { srv.serve(app).await })
        }
        None => {
            let srv = axum_server::from_tcp(listener)?.handle(handle.clone());
            tokio::spawn(async move { srv.serve(app).await })
        }
    };
    tracing::info!(%addr, ?stun_addr, "lumora relay listening on {scheme}://{addr}/ws");
    Ok(Relay { addr, stun_addr, handle, shared, server, aux })
}

async fn save_mailbox(sh: &Arc<Shared>) {
    let Some(path) = sh.cfg.mailbox_file.clone() else { return };
    if !sh.cfg.mailbox {
        return;
    }
    let bytes = {
        let mut mb = sh.mailbox.lock();
        if !mb.dirty {
            return;
        }
        mb.dirty = false;
        mb.serialize()
    };
    let res = tokio::task::spawn_blocking(move || Mailbox::save_bytes(&path, &bytes)).await;
    if let Ok(Err(e)) = res {
        tracing::warn!(error = %e, "saving mailbox failed");
    }
}

/// Periodic cleanup: replay cache, expired mailbox items, mailbox persistence.
async fn janitor(sh: Arc<Shared>) {
    let mut tick = tokio::time::interval(Duration::from_secs(30));
    let mut n = 0u64;
    loop {
        tick.tick().await;
        let now = now_ms();
        sh.replay.lock().retain(|_, exp| *exp > now);
        sh.mailbox.lock().prune(now);
        n += 1;
        if n.is_multiple_of(2) {
            save_mailbox(&sh).await;
        }
    }
}

async fn root() -> &'static str {
    "Lumora relay. WebSocket endpoint: /ws  Stats: /health\n\
     Payloads are end-to-end encrypted; this relay cannot read them.\n"
}

async fn health(State(sh): State<Arc<Shared>>) -> Json<serde_json::Value> {
    let (mb_peers, mb_items, mb_bytes) = sh.mailbox.lock().stats();
    let s = &sh.stats;
    Json(serde_json::json!({
        "status": "ok",
        "version": env!("CARGO_PKG_VERSION"),
        "uptime_secs": sh.started.elapsed().as_secs(),
        "clients": sh.sessions.lock().len(),
        "connections": sh.conns.load(Ordering::Relaxed),
        "max_clients": sh.cfg.max_clients,
        "bytes_relayed": s.bytes_relayed.load(Ordering::Relaxed),
        "data_frames": s.data_frames.load(Ordering::Relaxed),
        "signal_frames": s.signal_frames.load(Ordering::Relaxed),
        "data_dropped": s.data_dropped.load(Ordering::Relaxed),
        "signals_stored": s.signals_stored.load(Ordering::Relaxed),
        "hello_rejected": s.hello_rejected.load(Ordering::Relaxed),
        "sessions_total": s.sessions_total.load(Ordering::Relaxed),
        "mailbox": { "enabled": sh.cfg.mailbox, "peers": mb_peers, "items": mb_items, "bytes": mb_bytes },
        "private": sh.allow.is_some(),
    }))
}

/// Address reported in WELCOME. Behind a trusted proxy the client port is unknown,
/// so only the IP is reported.
fn observed_addr(trust_proxy: bool, remote: SocketAddr, headers: &HeaderMap) -> String {
    if trust_proxy {
        let hdr = |n: &str| headers.get(n).and_then(|v| v.to_str().ok());
        if let Some(ip) = hdr("cf-connecting-ip").and_then(|s| s.trim().parse::<IpAddr>().ok()) {
            return ip.to_string();
        }
        // Right-most entry = the address our own proxy saw.
        if let Some(ip) = hdr("x-forwarded-for").and_then(|s| s.rsplit(',').next()).and_then(|s| s.trim().parse::<IpAddr>().ok()) {
            return ip.to_string();
        }
    }
    stun::canon(remote).to_string()
}

async fn ws_handler(
    State(sh): State<Arc<Shared>>,
    ConnectInfo(remote): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    // Allow some slack above max_clients for reconnects that replace a session.
    let limit = sh.cfg.max_clients + sh.cfg.max_clients / 10 + 16;
    if sh.conns.load(Ordering::Relaxed) >= limit {
        return (StatusCode::SERVICE_UNAVAILABLE, "relay full").into_response();
    }
    let observed = observed_addr(sh.cfg.trust_proxy, remote, &headers);
    // Oversized frames are rejected in-protocol (ERROR); hard-cap at 2x to bound memory.
    let cap = sh.cfg.max_frame.saturating_mul(2).max(1024);
    ws.max_message_size(cap)
        .max_frame_size(cap)
        .on_upgrade(move |sock| async move {
            sh.conns.fetch_add(1, Ordering::Relaxed);
            handle_socket(sh.clone(), sock, observed).await;
            sh.conns.fetch_sub(1, Ordering::Relaxed);
        })
}

async fn reject(sh: &Shared, mut sock: WebSocket, why: &str) {
    sh.stats.hello_rejected.fetch_add(1, Ordering::Relaxed);
    let _ = tokio::time::timeout(Duration::from_secs(2), async {
        let _ = sock.send(Message::Binary(error_frame(why).into())).await;
        let _ = sock.send(Message::Close(None)).await;
    })
    .await;
}

/// Validate a HELLO frame. Returns the authenticated key or an error message.
fn check_hello(sh: &Shared, frame: &[u8]) -> Result<[u8; 32], &'static str> {
    let (pk, ts, sig) = decode_hello(frame).ok_or("expected HELLO")?;
    if now_ms().abs_diff(ts) > HELLO_MAX_SKEW_MS {
        return Err("HELLO timestamp out of range (check clock)");
    }
    let vk = VerifyingKey::from_bytes(&pk).map_err(|_| "bad public key")?;
    vk.verify_strict(&hello_message(&pk, ts), &Signature::from_bytes(&sig))
        .map_err(|_| "bad signature")?;
    {
        let mut replay = sh.replay.lock();
        if replay.contains_key(&(pk, ts)) {
            return Err("replayed HELLO");
        }
        replay.insert((pk, ts), now_ms() + REPLAY_KEEP_MS);
    }
    if let Some(allow) = &sh.allow {
        if !allow.contains(&pk) {
            return Err("not allowed on this relay");
        }
    }
    Ok(pk)
}

async fn handle_socket(sh: Arc<Shared>, mut sock: WebSocket, observed: String) {
    // ---- HELLO -------------------------------------------------------------
    let first = tokio::time::timeout(Duration::from_secs(sh.cfg.hello_timeout), async {
        loop {
            match sock.recv().await {
                Some(Ok(Message::Binary(b))) => return Some(b),
                Some(Ok(Message::Ping(_) | Message::Pong(_))) => continue,
                _ => return None,
            }
        }
    })
    .await;
    let frame = match first {
        Ok(Some(b)) => b,
        Ok(None) => return,
        Err(_) => return reject(&sh, sock, "HELLO timeout").await,
    };
    let pk = match check_hello(&sh, &frame) {
        Ok(pk) => pk,
        Err(why) => {
            tracing::debug!(reason = why, "hello rejected");
            return reject(&sh, sock, why).await;
        }
    };
    let id = sh.next_id.fetch_add(1, Ordering::Relaxed);
    let (tx, rx) = mpsc::channel::<Vec<u8>>(sh.cfg.queue_len.max(16));
    let kill = Arc::new(Kill::default());
    let full = {
        let mut sessions = sh.sessions.lock();
        if sessions.len() >= sh.cfg.max_clients && !sessions.contains_key(&pk) {
            true
        } else {
            if let Some(old) = sessions.insert(pk, SessionHandle { id, tx: tx.clone(), kill: kill.clone() }) {
                old.kill.fire("replaced by a newer connection");
            }
            false
        }
    };
    if full {
        return reject(&sh, sock, "relay full").await;
    }
    sh.stats.sessions_total.fetch_add(1, Ordering::Relaxed);
    let peer = short(&pk);
    tracing::info!(peer = %peer, session = id, "session open");
    tracing::debug!(peer = %peer, %observed, "observed address");

    let mut welcome = vec![T_WELCOME];
    welcome.extend_from_slice(observed.as_bytes());
    let _ = tx.try_send(welcome);
    if sh.cfg.mailbox {
        let now = now_ms();
        let items = sh.mailbox.lock().take(&pk, now);
        if !items.is_empty() {
            tracing::debug!(peer = %peer, n = items.len(), "delivering mailbox");
            let mut back = Vec::new();
            for f in items {
                if let Err(e) = tx.try_send(f) {
                    back.push(e.into_inner());
                }
            }
            if !back.is_empty() {
                sh.mailbox.lock().restore(pk, back, now);
            }
        }
    }

    let (sink, mut stream) = sock.split();
    let mut writer = tokio::spawn(writer_task(sh.clone(), pk, sink, rx, kill.clone()));
    let mut writer_done = false;

    // ---- main loop -----------------------------------------------------------
    let mut data_bucket = Bucket::new(sh.cfg.bandwidth as f64, sh.cfg.burst.max(sh.cfg.max_frame as u64) as f64);
    let mut sig_bucket = Bucket::new(sh.cfg.signal_rate, (sh.cfg.signal_rate * 2.0).max(1.0));
    let mut gone_sent: HashMap<[u8; 32], Instant> = HashMap::new();
    let idle = Duration::from_secs(sh.cfg.idle_timeout.max(1));
    let mut close_reason = "client closed";
    loop {
        let msg = tokio::select! {
            r = tokio::time::timeout(idle, stream.next()) => r,
            _ = &mut writer => { writer_done = true; close_reason = "writer finished"; break; }
        };
        let b = match msg {
            Err(_) => { close_reason = "idle timeout"; break; }
            Ok(None) | Ok(Some(Err(_))) | Ok(Some(Ok(Message::Close(_)))) => break,
            Ok(Some(Ok(Message::Binary(b)))) => b,
            Ok(Some(Ok(_))) => continue, // ping/pong/text: just keep-alive
        };
        if b.is_empty() {
            continue;
        }
        if b.len() > sh.cfg.max_frame {
            let _ = tx.try_send(error_frame("frame too large"));
            continue;
        }
        match b[0] {
            T_DATA => {
                let Some((_, to, payload)) = decode_peer_frame(&b) else { continue };
                if !data_bucket.take(b.len() as f64) {
                    sh.stats.data_dropped.fetch_add(1, Ordering::Relaxed);
                    continue;
                }
                forward_data(&sh, &pk, to, payload, &tx, &mut gone_sent);
            }
            T_SIGNAL => {
                let Some((_, to, payload)) = decode_peer_frame(&b) else { continue };
                if !sig_bucket.take(1.0) {
                    let _ = tx.try_send(error_frame("signal rate limit exceeded"));
                    continue;
                }
                forward_signal(&sh, &pk, to, payload, &tx);
            }
            T_HELLO => {
                let _ = tx.try_send(error_frame("already authenticated"));
            }
            _ => {
                let _ = tx.try_send(error_frame("unknown frame type"));
            }
        }
    }

    // ---- teardown -----------------------------------------------------------
    {
        let mut sessions = sh.sessions.lock();
        if sessions.get(&pk).is_some_and(|s| s.id == id) {
            sessions.remove(&pk);
        }
    }
    kill.fire("session closed");
    if !writer_done && tokio::time::timeout(Duration::from_secs(6), &mut writer).await.is_err() {
        writer.abort();
    }
    tracing::info!(peer = %peer, session = id, reason = close_reason, "session closed");
}

async fn writer_task(
    sh: Arc<Shared>,
    pk: [u8; 32],
    mut sink: futures::stream::SplitSink<WebSocket, Message>,
    mut rx: mpsc::Receiver<Vec<u8>>,
    kill: Arc<Kill>,
) {
    loop {
        tokio::select! {
            biased;
            _ = kill.notify.notified() => {
                let reason = kill.reason.lock().unwrap_or("closed");
                let _ = tokio::time::timeout(Duration::from_secs(5), async {
                    let _ = sink.send(Message::Binary(error_frame(reason).into())).await;
                    let _ = sink.send(Message::Close(None)).await;
                }).await;
                break;
            }
            f = rx.recv() => {
                let Some(f) = f else { break };
                match tokio::time::timeout(WRITE_TIMEOUT, sink.send(Message::Binary(f.into()))).await {
                    Ok(Ok(())) => {}
                    _ => break,
                }
            }
        }
    }
    // Never lose signals silently: whatever is still queued goes to the mailbox.
    rx.close();
    let mut pending = Vec::new();
    while let Ok(f) = rx.try_recv() {
        if f.first() == Some(&T_SIGNAL) {
            pending.push(f);
        }
    }
    if !pending.is_empty() && sh.cfg.mailbox {
        let n = pending.len();
        let now = now_ms();
        let mut mb = sh.mailbox.lock();
        for f in pending {
            if mb.put(pk, f, now).is_ok() {
                sh.stats.signals_stored.fetch_add(1, Ordering::Relaxed);
            }
        }
        tracing::debug!(peer = %short(&pk), n, "queued signals moved to mailbox");
    }
}

fn forward_data(
    sh: &Shared,
    from: &[u8; 32],
    to: [u8; 32],
    payload: &[u8],
    me: &mpsc::Sender<Vec<u8>>,
    gone_sent: &mut HashMap<[u8; 32], Instant>,
) {
    let target = sh.sessions.lock().get(&to).cloned();
    match target {
        Some(t) => {
            let frame = encode_peer_frame(T_DATA, from, payload);
            let len = frame.len() as u64;
            match t.tx.try_send(frame) {
                Ok(()) => {
                    sh.stats.bytes_relayed.fetch_add(len, Ordering::Relaxed);
                    sh.stats.data_frames.fetch_add(1, Ordering::Relaxed);
                }
                // UDP semantics: congested receiver → drop.
                Err(_) => {
                    sh.stats.data_dropped.fetch_add(1, Ordering::Relaxed);
                }
            }
        }
        None => {
            let now = Instant::now();
            if gone_sent.get(&to).is_none_or(|t| now.duration_since(*t) >= Duration::from_secs(1)) {
                if gone_sent.len() > 1024 {
                    gone_sent.retain(|_, t| now.duration_since(*t) < Duration::from_secs(1));
                }
                gone_sent.insert(to, now);
                let mut g = vec![T_GONE];
                g.extend_from_slice(&to);
                let _ = me.try_send(g);
            }
        }
    }
}

fn forward_signal(sh: &Shared, from: &[u8; 32], to: [u8; 32], payload: &[u8], me: &mpsc::Sender<Vec<u8>>) {
    let frame = encode_peer_frame(T_SIGNAL, from, payload);
    let len = frame.len() as u64;
    let target = sh.sessions.lock().get(&to).cloned();
    let frame = match target {
        Some(t) => match t.tx.try_send(frame) {
            Ok(()) => {
                sh.stats.bytes_relayed.fetch_add(len, Ordering::Relaxed);
                sh.stats.signal_frames.fetch_add(1, Ordering::Relaxed);
                return;
            }
            Err(mpsc::error::TrySendError::Full(f)) => {
                tracing::info!(peer = %short(&to), "closing slow client (send queue full)");
                t.kill.fire("too slow: send queue overflow");
                f
            }
            Err(mpsc::error::TrySendError::Closed(f)) => f,
        },
        None => frame,
    };
    // Recipient offline or being disconnected.
    if !sh.cfg.mailbox {
        let mut g = vec![T_GONE];
        g.extend_from_slice(&to);
        let _ = me.try_send(g);
        return;
    }
    let res = sh.mailbox.lock().put(to, frame, now_ms());
    match res {
        Ok(()) => {
            sh.stats.signals_stored.fetch_add(1, Ordering::Relaxed);
        }
        Err(e) => {
            let _ = me.try_send(error_frame(e.message()));
        }
    }
}

/// Classic token bucket; rate 0 = unlimited.
struct Bucket {
    rate: f64,
    burst: f64,
    tokens: f64,
    last: Instant,
}

impl Bucket {
    fn new(rate: f64, burst: f64) -> Self {
        Bucket { rate, burst, tokens: burst, last: Instant::now() }
    }
    fn take(&mut self, n: f64) -> bool {
        if self.rate <= 0.0 {
            return true;
        }
        let now = Instant::now();
        self.tokens = (self.tokens + now.duration_since(self.last).as_secs_f64() * self.rate).min(self.burst);
        self.last = now;
        if self.tokens >= n {
            self.tokens -= n;
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allow_file_parsing() {
        let hex = "11".repeat(32);
        let b32 = data_encoding::BASE32_NOPAD.encode(&[2u8; 32]).to_lowercase();
        let set = parse_allow(&format!("# comment\n{hex}\n\n{b32}  # bob\n")).unwrap();
        assert!(set.contains(&[0x11; 32]) && set.contains(&[2u8; 32]));
        assert!(parse_allow("nope").is_err());
    }

    #[test]
    fn proxy_headers() {
        let remote: SocketAddr = "[::ffff:10.0.0.1]:5555".parse().unwrap();
        let mut h = HeaderMap::new();
        h.insert("x-forwarded-for", "6.6.6.6, 1.2.3.4".parse().unwrap());
        assert_eq!(observed_addr(false, remote, &h), "10.0.0.1:5555");
        assert_eq!(observed_addr(true, remote, &h), "1.2.3.4");
        h.insert("cf-connecting-ip", "2001:db8::1".parse().unwrap());
        assert_eq!(observed_addr(true, remote, &h), "2001:db8::1");
    }
}
