//! Persistent WebSocket connection to one relay (VPS, Cloudflare Worker…).
//! Carries (a) signaling envelopes and (b) — only as a last resort — QUIC datagrams.

use super::magicsock::{RelayOut, RelayRouter};
use super::relay_proto::*;
use crate::identity::{Identity, PeerId};
use bytes::Bytes;
use futures::{SinkExt, StreamExt};
use parking_lot::RwLock;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

#[derive(Debug, Clone)]
pub struct IncomingSignal {
    pub via: String,
    pub data: Vec<u8>,
}

pub struct RelayClient {
    pub url: String,
    pub idx: u16,
    pub connected: Arc<AtomicBool>,
    pub observed: Arc<RwLock<Option<String>>>,
    signal_tx: mpsc::Sender<(PeerId, Vec<u8>)>,
    /// Reconnect now (the network changed: the TCP connection is probably dead).
    kick: Arc<tokio::sync::Notify>,
    /// Check the WebSocket now: ping, and reconnect only if nothing comes back quickly.
    probe: Arc<tokio::sync::Notify>,
    /// Removed in Settings: the connection loop ends.
    stopped: Arc<AtomicBool>,
    /// Since when the WebSocket is down (None while connected).
    down_since: Arc<parking_lot::Mutex<Option<Instant>>>,
    /// Last sign of life (anything received, or the connection coming up).
    last_rx: Arc<parking_lot::Mutex<Instant>>,
}

/// How long to wait for any answer to a probe ping before reconnecting.
const PROBE_WAIT: Duration = Duration::from_millis(1000);

impl RelayClient {
    /// Spawn the connection loop (auto-reconnect with backoff).
    pub fn spawn(
        url: String,
        idx: u16,
        id: Identity,
        router: Arc<RelayRouter>,
        relay_in: mpsc::Sender<(SocketAddr, Bytes)>,
        signals: mpsc::Sender<IncomingSignal>,
    ) -> Arc<RelayClient> {
        let (data_tx, data_rx) = mpsc::channel::<RelayOut>(2048);
        let (signal_tx, signal_rx) = mpsc::channel::<(PeerId, Vec<u8>)>(256);
        router.relays.write().insert(idx, data_tx);
        let rc = Arc::new(RelayClient {
            url: url.clone(),
            idx,
            connected: Arc::new(AtomicBool::new(false)),
            observed: Arc::new(RwLock::new(None)),
            signal_tx,
            kick: Arc::new(tokio::sync::Notify::new()),
            probe: Arc::new(tokio::sync::Notify::new()),
            stopped: Arc::new(AtomicBool::new(false)),
            down_since: Arc::new(parking_lot::Mutex::new(Some(Instant::now()))),
            last_rx: Arc::new(parking_lot::Mutex::new(Instant::now())),
        });
        let me = rc.clone();
        tokio::spawn(async move {
            let mut data_rx = data_rx;
            let mut signal_rx = signal_rx;
            let mut backoff = 1u64;
            loop {
                if me.stopped.load(Ordering::SeqCst) {
                    break;
                }
                let mut kicked = false;
                match me.run_once(&id, &router, &relay_in, &signals, &mut data_rx, &mut signal_rx).await {
                    Ok(()) => backoff = 1,
                    Err(e) => {
                        kicked = e.to_string() == KICKED;
                        tracing::debug!("relay {} error: {e:#}", me.url)
                    }
                }
                me.set_down();
                if me.stopped.load(Ordering::SeqCst) {
                    break;
                }
                if kicked {
                    backoff = 1;
                    continue;
                }
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(backoff)) => {}
                    _ = me.kick.notified() => {}
                }
                backoff = (backoff * 2).min(60);
            }
            // removed: its virtual relay addresses lead nowhere any more
            router.relays.write().remove(&me.idx);
            tracing::info!("relay removed: {}", me.url);
        });
        rc
    }

    fn set_down(&self) {
        if self.connected.swap(false, Ordering::SeqCst) || self.down_since.lock().is_none() {
            *self.down_since.lock() = Some(Instant::now());
        }
    }

    fn set_up(&self) {
        *self.down_since.lock() = None;
        *self.last_rx.lock() = Instant::now();
        self.connected.store(true, Ordering::SeqCst);
    }

    /// Connected and heard from (or reconnected) after `t`.
    pub fn alive_since(&self, t: Instant) -> bool {
        self.is_connected() && *self.last_rx.lock() > t
    }

    /// How long the WebSocket has been down (zero while connected).
    pub fn down_for(&self) -> Duration {
        if self.is_connected() {
            return Duration::ZERO;
        }
        self.down_since.lock().map(|t| t.elapsed()).unwrap_or(Duration::ZERO)
    }

    /// Stop this relay for good (removed in Settings): close the WebSocket, end the loop.
    pub fn stop(&self) {
        self.stopped.store(true, Ordering::SeqCst);
        self.kick.notify_waiters();
        self.kick.notify_one();
    }

    pub fn is_stopped(&self) -> bool {
        self.stopped.load(Ordering::SeqCst)
    }

    /// Ping the relay now; reconnect only if it doesn't answer within 1.5 s (a path that
    /// died under us, e.g. NAT rebinding). A healthy WebSocket is left alone.
    pub fn probe(&self) {
        self.probe.notify_one();
    }

    pub async fn send_signal(&self, to: PeerId, data: Vec<u8>) -> bool {
        if !self.connected.load(Ordering::SeqCst) {
            return false;
        }
        // never wait long on one relay: a peer relay riding on a dead connection (or a
        // stalled WebSocket) must not hold up the other channels or the caller's dial
        match self.signal_tx.try_send((to, data)) {
            Ok(()) => true,
            Err(mpsc::error::TrySendError::Full(item)) => {
                matches!(tokio::time::timeout(Duration::from_millis(300), self.signal_tx.send(item)).await, Ok(Ok(())))
            }
            Err(mpsc::error::TrySendError::Closed(_)) => false,
        }
    }

    pub fn is_connected(&self) -> bool {
        self.connected.load(Ordering::SeqCst)
    }

    async fn run_once(
        &self,
        id: &Identity,
        router: &Arc<RelayRouter>,
        relay_in: &mpsc::Sender<(SocketAddr, Bytes)>,
        signals: &mpsc::Sender<IncomingSignal>,
        data_rx: &mut mpsc::Receiver<RelayOut>,
        signal_rx: &mut mpsc::Receiver<(PeerId, Vec<u8>)>,
    ) -> anyhow::Result<()> {
        let (ws, _) = tokio::time::timeout(Duration::from_secs(10), tokio_tungstenite::connect_async(&self.url)).await??;
        let (mut tx, mut rx) = ws.split();
        let pk = id.peer_id().0;
        let ts = crate::util::now_ms();
        let sig = id.sign(&hello_message(&pk, ts));
        tx.send(Message::Binary(encode_hello(&pk, ts, &sig).into())).await?;
        self.set_up();
        tracing::info!("relay connected: {}", self.url);
        let mut ping = tokio::time::interval(Duration::from_secs(20));
        // a probe is waiting for any sign of life until then
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
                    probe_until = None;
                    *self.last_rx.lock() = Instant::now();
                    match m? {
                        Message::Binary(b) => {
                            if b.is_empty() { continue }
                            match b[0] {
                                T_WELCOME => { *self.observed.write() = Some(String::from_utf8_lossy(&b[1..]).to_string()); }
                                T_DATA | T_SIGNAL => {
                                    if let Some((t, peer, payload)) = decode_peer_frame(&b) {
                                        let peer = PeerId(peer);
                                        if t == T_DATA {
                                            let addr = router.register_peer(self.idx, peer);
                                            let _ = relay_in.try_send((addr, Bytes::copy_from_slice(payload)));
                                        } else {
                                            let _ = signals.send(IncomingSignal { via: self.url.clone(), data: payload.to_vec() }).await;
                                        }
                                    }
                                }
                                T_ERROR => tracing::warn!("relay {}: {}", self.url, String::from_utf8_lossy(&b[1..])),
                                _ => {}
                            }
                        }
                        Message::Close(_) => anyhow::bail!("closed by relay"),
                        _ => {}
                    }
                }
                Some(out) = data_rx.recv() => {
                    tx.send(Message::Binary(encode_peer_frame(T_DATA, &out.to.0, &out.data).into())).await?;
                }
                Some((to, data)) = signal_rx.recv() => {
                    tx.send(Message::Binary(encode_peer_frame(T_SIGNAL, &to.0, &data).into())).await?;
                }
                _ = ping.tick() => { tx.send(Message::Ping(Vec::new().into())).await?; }
                _ = self.kick.notified() => anyhow::bail!(KICKED),
                _ = self.probe.notified() => {
                    if probe_until.is_none() {
                        probe_until = Some(tokio::time::Instant::now() + PROBE_WAIT);
                    }
                    tx.send(Message::Ping(Vec::new().into())).await?;
                }
                _ = probe_wait => {
                    tracing::info!("relay {}: no answer to a probe, reconnecting", self.url);
                    anyhow::bail!(KICKED)
                }
            }
        }
    }

    /// Drop the WebSocket and reconnect at once (no-op for peer relays).
    pub fn kick(&self) {
        self.kick.notify_waiters();
    }
}

const KICKED: &str = "reconnect requested";

impl RelayClient {
    /// Peer relay: the same frame protocol tunnelled over a QUIC bi-stream to a friend.
    /// Frames are length-prefixed (u32 BE) instead of WebSocket messages.
    #[allow(clippy::too_many_arguments)]
    pub fn spawn_stream(
        name: String,
        idx: u16,
        router: Arc<RelayRouter>,
        relay_in: mpsc::Sender<(SocketAddr, Bytes)>,
        signals: mpsc::Sender<IncomingSignal>,
        mut send: quinn::SendStream,
        mut recv: quinn::RecvStream,
        on_close: impl FnOnce() + Send + 'static,
    ) -> Arc<RelayClient> {
        let (data_tx, mut data_rx) = mpsc::channel::<RelayOut>(1024);
        let (signal_tx, mut signal_rx) = mpsc::channel::<(PeerId, Vec<u8>)>(128);
        router.relays.write().insert(idx, data_tx);
        let rc = Arc::new(RelayClient {
            url: name.clone(),
            idx,
            connected: Arc::new(AtomicBool::new(true)),
            observed: Arc::new(RwLock::new(None)),
            signal_tx,
            kick: Arc::new(tokio::sync::Notify::new()),
            probe: Arc::new(tokio::sync::Notify::new()),
            stopped: Arc::new(AtomicBool::new(false)),
            down_since: Arc::new(parking_lot::Mutex::new(None)),
            last_rx: Arc::new(parking_lot::Mutex::new(Instant::now())),
        });
        let me = rc.clone();
        // Reader runs in its own task: `read_exact` is not cancel-safe, so it must never sit
        // inside a `select!` with the writer branches (a partial read would desync framing).
        let reader_router = router.clone();
        let reader_name = name.clone();
        let mut reader = tokio::spawn(async move {
            let mut len = [0u8; 4];
            loop {
                if recv.read_exact(&mut len).await.is_err() {
                    return;
                }
                let n = u32::from_be_bytes(len) as usize;
                if n > MAX_FRAME + 64 {
                    return;
                }
                let mut b = vec![0u8; n];
                if recv.read_exact(&mut b).await.is_err() {
                    return;
                }
                if let Some((t, peer, payload)) = decode_peer_frame(&b) {
                    let peer = PeerId(peer);
                    match t {
                        T_DATA => {
                            let addr = reader_router.register_peer(idx, peer);
                            let _ = relay_in.try_send((addr, Bytes::copy_from_slice(payload)));
                        }
                        T_SIGNAL => {
                            let _ = signals.send(IncomingSignal { via: reader_name.clone(), data: payload.to_vec() }).await;
                        }
                        _ => {}
                    }
                }
            }
        });
        tokio::spawn(async move {
            let r: anyhow::Result<()> = async {
                loop {
                    tokio::select! {
                        _ = &mut reader => anyhow::bail!("reader ended"),
                        _ = me.kick.notified() => anyhow::bail!("stopped"),
                        Some(out) = data_rx.recv() => {
                            let f = encode_peer_frame(T_DATA, &out.to.0, &out.data);
                            let mut buf = (f.len() as u32).to_be_bytes().to_vec();
                            buf.extend(f);
                            send.write_all(&buf).await?;
                        }
                        Some((to, data)) = signal_rx.recv() => {
                            let f = encode_peer_frame(T_SIGNAL, &to.0, &data);
                            let mut buf = (f.len() as u32).to_be_bytes().to_vec();
                            buf.extend(f);
                            send.write_all(&buf).await?;
                        }
                    }
                }
            }
            .await;
            reader.abort();
            tracing::debug!("peer relay {} closed: {r:?}", me.url);
            me.set_down();
            router.relays.write().remove(&idx);
            on_close();
        });
        rc
    }
}
