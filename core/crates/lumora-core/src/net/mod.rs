//! Lumora transport: QUIC over a "magic" UDP socket with aggressive NAT traversal.
//!
//! Path preference (all attempted in parallel, first one wins, relay only last):
//!  1. LAN (multicast discovery)      4. UDP hole punch (simultaneous QUIC dial)
//!  2. IPv6 global                    5. Port prediction / birthday spraying (symmetric NAT)
//!  3. UPnP mapped port               6. Relay (peer → VPS → Cloudflare), upgraded later

pub mod discovery;
pub mod magicsock;
pub mod nostr;
pub mod relay_client;
pub mod relay_proto;
pub mod stun;

use crate::identity::{Identity, PeerId};
use anyhow::{anyhow, bail, Result};
use bytes::Bytes;
use magicsock::{MagicSock, PROBE_MAGIC};
use parking_lot::{Mutex, RwLock};
use relay_client::{IncomingSignal, RelayClient};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Default)]
pub enum NatKind {
    #[default]
    Unknown,
    /// Public IP directly on an interface (or UPnP mapping).
    Open,
    /// Endpoint-independent mapping: classic hole punching works.
    Easy,
    /// Symmetric NAT, ports allocated sequentially with this delta.
    HardSequential(i32),
    /// Symmetric NAT with random ports.
    HardRandom,
    /// No STUN answer at all: UDP likely blocked.
    UdpBlocked,
}

impl NatKind {
    pub fn is_hard(&self) -> bool {
        matches!(self, NatKind::HardSequential(_) | NatKind::HardRandom)
    }
    pub fn label(&self) -> &'static str {
        match self {
            NatKind::Unknown => "unknown",
            NatKind::Open => "open",
            NatKind::Easy => "easy",
            NatKind::HardSequential(_) => "symmetric-sequential",
            NatKind::HardRandom => "symmetric-random",
            NatKind::UdpBlocked => "udp-blocked",
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct ConnInfo {
    pub addrs: Vec<SocketAddr>,
    pub nat: NatKind,
    pub public_ip: Option<IpAddr>,
    pub mapped_ports: Vec<u16>,
    pub relays: Vec<String>,
    pub port: u16,
    pub upnp: Option<SocketAddr>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NetConfig {
    pub port: u16,
    pub stun: Vec<String>,
    pub relays: Vec<String>,
    pub nostr: Vec<String>,
    pub enable_lan: bool,
    pub enable_upnp: bool,
    pub enable_dht: bool,
    pub enable_nostr: bool,
    /// Wait this long for a direct path before also trying a relay.
    pub relay_delay_ms: u64,
    /// LAN discovery by raw multicast announcements (239.255.76.77). Both LAN methods
    /// also obey `enable_lan` / the runtime `lan_enabled` switch.
    #[serde(default = "default_true")]
    pub lan_multicast: bool,
    /// LAN discovery by Bonjour/DNS-SD (`_lumora._udp`), interoperable with iOS.
    #[serde(default = "default_true")]
    pub mdns: bool,
}

fn default_true() -> bool {
    true
}

impl Default for NetConfig {
    fn default() -> Self {
        NetConfig {
            port: 0,
            stun: stun::DEFAULT_STUN.iter().map(|s| s.to_string()).collect(),
            relays: vec![],
            nostr: nostr::DEFAULT_RELAYS.iter().map(|s| s.to_string()).collect(),
            enable_lan: true,
            enable_upnp: true,
            enable_dht: true,
            enable_nostr: true,
            relay_delay_ms: 3500,
            lan_multicast: true,
            mdns: true,
        }
    }
}

pub struct Transport {
    pub id: Identity,
    /// This device's certificate when it is a secondary device of an account (TLS SAN).
    pub devcert: Option<crate::devices::DeviceCert>,
    pub cfg: RwLock<NetConfig>,
    pub endpoint: quinn::Endpoint,
    pub sock: Arc<MagicSock>,
    raw: Arc<tokio::net::UdpSocket>,
    relay_in_tx: mpsc::Sender<(SocketAddr, Bytes)>,
    stun_pending: Mutex<HashMap<[u8; 12], oneshot::Sender<SocketAddr>>>,
    pub info: RwLock<ConnInfo>,
    pub relays: Arc<RwLock<Vec<Arc<RelayClient>>>>,
    pub nostr: RwLock<Option<Arc<nostr::NostrPool>>>,
    pub dht: Option<discovery::Dht>,
    pub lan: Arc<discovery::LanTable>,
    pub lan_enabled: Arc<AtomicBool>,
    signal_tx: mpsc::Sender<IncomingSignal>,
}

impl Transport {
    pub async fn start(
        id: Identity,
        devcert: Option<crate::devices::DeviceCert>,
        cfg: NetConfig,
    ) -> Result<(Arc<Transport>, mpsc::Receiver<IncomingSignal>)> {
        let udp = magicsock::bind_udp(cfg.port).or_else(|_| magicsock::bind_udp(0))?;
        let h = MagicSock::create(udp)?;
        let endpoint = quinn::Endpoint::new_with_abstract_socket(
            endpoint_config(),
            Some(crate::tls::server_config(&id, devcert.as_ref())?),
            h.sock.clone(),
            Arc::new(quinn::TokioRuntime),
        )?;
        let (signal_tx, signal_rx) = mpsc::channel(512);
        let dht = if cfg.enable_dht { discovery::Dht::start().ok() } else { None };
        let t = Arc::new(Transport {
            id: id.clone(),
            devcert,
            cfg: RwLock::new(cfg.clone()),
            endpoint,
            sock: h.sock.clone(),
            raw: h.raw.clone(),
            relay_in_tx: h.relay_in_tx.clone(),
            stun_pending: Mutex::new(HashMap::new()),
            info: RwLock::new(ConnInfo { port: h.sock.local_port(), ..Default::default() }),
            relays: Arc::new(RwLock::new(Vec::new())),
            nostr: RwLock::new(None),
            dht,
            lan: Arc::new(discovery::LanTable::default()),
            lan_enabled: Arc::new(AtomicBool::new(cfg.enable_lan)),
            signal_tx: signal_tx.clone(),
        });
        t.clone().spawn_side_dispatcher(h.side_rx);
        for url in cfg.relays.iter() {
            t.add_relay(url.clone());
        }
        if cfg.enable_nostr && !cfg.nostr.is_empty() {
            *t.nostr.write() = Some(nostr::NostrPool::spawn(&id, cfg.nostr.clone(), signal_tx.clone()));
        }
        if cfg.lan_multicast {
            discovery::spawn_lan(id.peer_id(), t.local_port(), t.lan.clone(), t.lan_enabled.clone());
        }
        if cfg.mdns {
            discovery::spawn_mdns(id.peer_id(), t.local_port(), t.lan.clone(), t.lan_enabled.clone());
        }
        Ok((t, signal_rx))
    }

    pub fn local_port(&self) -> u16 {
        self.sock.local_port()
    }

    /// Register a peer relay (QUIC stream to a friend). Returns its relay name.
    pub fn add_stream_relay(
        &self,
        name: String,
        send: quinn::SendStream,
        recv: quinn::RecvStream,
        on_close: impl FnOnce() + Send + 'static,
    ) -> Arc<RelayClient> {
        let mut relays = self.relays.write();
        // one stream per name: an older one (a retired connection's) is replaced
        relays.retain(|r| {
            if r.url == name {
                r.stop();
            }
            r.url != name
        });
        let idx = loop {
            let i = 1000 + (rand::random::<u16>() % 30000);
            if !relays.iter().any(|r| r.idx == i) {
                break i;
            }
        };
        let list = Arc::downgrade(&self.relays_handle());
        let rc = RelayClient::spawn_stream(
            name,
            idx,
            self.sock.router.clone(),
            self.relay_in_tx.clone(),
            self.signal_tx.clone(),
            send,
            recv,
            move || {
                // only this stream (by its index): a newer one with the same name stays
                if let Some(l) = list.upgrade() {
                    l.write().retain(|r| r.idx != idx);
                }
                on_close();
            },
        );
        relays.push(rc.clone());
        rc
    }

    fn relays_handle(&self) -> Arc<RwLock<Vec<Arc<RelayClient>>>> {
        self.relays.clone()
    }

    /// A relay suggested by a (friend) peer: only public `wss://` hosts, bounded count.
    pub fn add_remote_relay(&self, url: &str) -> bool {
        if self.relays.read().iter().any(|r| r.url == url) {
            return true;
        }
        if !is_safe_remote_relay(url) {
            return false;
        }
        let server_relays = self.relays.read().iter().filter(|r| !r.url.starts_with("peer:")).count();
        if server_relays >= 8 {
            return false;
        }
        self.add_relay(url.to_string());
        true
    }

    /// Remove a relay (Settings, or a peer relay that is gone): its connection loop stops.
    pub fn remove_relay(&self, name: &str) {
        self.relays.write().retain(|r| {
            if r.url == name {
                r.stop();
            }
            r.url != name
        });
    }

    /// A relay the user configured (or the app shipped with) — the only ones offered to
    /// or used with people who aren't friends.
    pub fn is_user_relay(&self, url: &str) -> bool {
        self.cfg.read().relays.iter().any(|r| r == url)
    }

    pub fn add_relay(&self, url: String) {
        if url.starts_with("peer:") {
            return; // peer relays are opened by the node layer
        }
        let mut relays = self.relays.write();
        if relays.iter().any(|r| r.url == url) {
            return;
        }
        let idx = relays.iter().filter(|r| r.idx < 1000).count() as u16 + 1;
        relays.push(RelayClient::spawn(
            url,
            idx,
            self.id.clone(),
            self.sock.router.clone(),
            self.relay_in_tx.clone(),
            self.signal_tx.clone(),
        ));
    }

    fn spawn_side_dispatcher(self: Arc<Self>, mut rx: mpsc::Receiver<(SocketAddr, Vec<u8>)>) {
        tokio::spawn(async move {
            while let Some((src, d)) = rx.recv().await {
                if let Some(txid) = stun::is_binding_request(&d) {
                    // Be a STUN server for our peers.
                    let _ = self.raw.send_to(&stun::binding_response(&txid, src), src).await;
                } else if let Some((txid, mapped)) = stun::parse_response(&d) {
                    if let Some(tx) = self.stun_pending.lock().remove(&txid) {
                        let _ = tx.send(crate::util::canon(mapped));
                    }
                } else if d.len() >= 5 && &d[..4] == PROBE_MAGIC && d[4] == 1 {
                    // Punch ping → pong from the same port (confirms the hole to the sender).
                    let mut pong = d.clone();
                    pong[4] = 2;
                    let _ = self.raw.send_to(&pong, src).await;
                }
            }
        });
    }

    async fn stun_query(&self, server: SocketAddr) -> Option<SocketAddr> {
        for _ in 0..3 {
            let txid: [u8; 12] = crate::crypto::random_bytes();
            let (tx, rx) = oneshot::channel();
            self.stun_pending.lock().insert(txid, tx);
            let _ = self.raw.send_to(&stun::binding_request(&txid), server).await;
            match tokio::time::timeout(Duration::from_millis(900), rx).await {
                Ok(Ok(a)) => return Some(a),
                _ => {
                    self.stun_pending.lock().remove(&txid);
                }
            }
        }
        None
    }

    /// Gather candidates and classify our NAT. Cheap enough to run every minute.
    pub async fn refresh_info(&self) -> ConnInfo {
        let port = self.local_port();
        let cfg = self.cfg.read().clone();
        let mut addrs = discovery::local_addrs(port);
        // Resolve STUN servers (v4 + v6) and query in parallel.
        let mut servers: Vec<SocketAddr> = Vec::new();
        for s in cfg.stun.iter() {
            if let Ok(Ok(it)) = tokio::time::timeout(Duration::from_secs(3), tokio::net::lookup_host(s.as_str())).await {
                let mut got4 = false;
                let mut got6 = false;
                for a in it {
                    if a.is_ipv4() && !got4 {
                        servers.push(a);
                        got4 = true;
                    } else if a.is_ipv6() && !got6 {
                        servers.push(a);
                        got6 = true;
                    }
                }
            }
        }
        let futs = servers.iter().map(|s| self.stun_query(*s));
        let results: Vec<(SocketAddr, Option<SocketAddr>)> =
            servers.iter().copied().zip(futures::future::join_all(futs).await).collect();
        let mut v4_mapped: Vec<SocketAddr> = Vec::new();
        for (srv, m) in results.iter() {
            if let Some(m) = m {
                if srv.is_ipv4() && m.is_ipv4() {
                    // keep distinct server IPs only for classification
                    v4_mapped.push(*m);
                }
                if !addrs.contains(m) {
                    addrs.push(*m);
                }
            }
        }
        // tests (debug builds only): advertise extra candidates, e.g. a UDP listener that
        // counts packets a peer sends toward us (core/tests/ip_privacy_e2e.py)
        if cfg!(debug_assertions) {
            if let Ok(v) = std::env::var("LUMORA_TEST_EXTRA_ADDRS") {
                for a in v.split(',').filter_map(|x| x.trim().parse::<SocketAddr>().ok()) {
                    if !addrs.contains(&a) {
                        addrs.push(a);
                    }
                }
            }
        }
        let local_ips: Vec<IpAddr> = discovery::local_addrs(0).iter().map(|a| a.ip()).collect();
        // No STUN answer at all (servers blocked/gone)? Use the public IP a relay observed
        // plus our UDP port — port-preserving home routers make this a valid candidate.
        let mut relay_guess = None;
        if v4_mapped.is_empty() {
            for r in self.relays.read().iter() {
                if let Some(obs) = r.observed.read().clone() {
                    let ip_s = obs.rsplit_once(':').map(|(h, _)| h.trim_matches(['[', ']'])).unwrap_or(&obs).to_string();
                    if let Ok(ip) = ip_s.parse::<IpAddr>() {
                        let ip = crate::util::canon(SocketAddr::new(ip, 0)).ip();
                        if ip.is_ipv4() && !local_ips.contains(&ip) {
                            relay_guess = Some(SocketAddr::new(ip, port));
                            break;
                        }
                    }
                }
            }
        }
        if let Some(g) = relay_guess {
            if !addrs.contains(&g) {
                addrs.push(g);
            }
        }
        let public_ip = v4_mapped.first().map(|a| a.ip()).or(relay_guess.map(|g| g.ip()));
        let mapped_ports: Vec<u16> = v4_mapped.iter().map(|a| a.port()).collect();
        let nat = if v4_mapped.is_empty() {
            no_v4_mapping_kind(!servers.is_empty(), results.iter().any(|(_, m)| m.is_some()))
        } else if public_ip.map(|ip| local_ips.contains(&ip)).unwrap_or(false) {
            NatKind::Open
        } else {
            let ports: Vec<i32> = mapped_ports.iter().map(|p| *p as i32).collect();
            if ports.windows(2).all(|w| w[0] == w[1]) {
                NatKind::Easy
            } else {
                let deltas: Vec<i32> = ports.windows(2).map(|w| w[1] - w[0]).collect();
                let d0 = deltas[0];
                if d0 != 0 && d0.abs() <= 16 && deltas.iter().all(|d| (*d - d0).abs() <= 2) {
                    NatKind::HardSequential(d0)
                } else {
                    NatKind::HardRandom
                }
            }
        };
        let upnp = {
            let cur = self.info.read().upnp;
            if cur.is_some() || !cfg.enable_upnp {
                cur
            } else {
                discovery::upnp_map(port).await
            }
        };
        if let Some(u) = upnp {
            if !addrs.contains(&u) {
                addrs.insert(0, u);
            }
        }
        let nat = if upnp.is_some() && nat != NatKind::Open { NatKind::Open } else { nat };
        let relays: Vec<String> = self.relays.read().iter().filter(|r| r.is_connected()).map(|r| r.url.clone()).collect();
        let info = ConnInfo { addrs, nat, public_ip, mapped_ports, relays, port, upnp };
        {
            let prev = self.info.read();
            if prev.nat != info.nat {
                tracing::info!("network: NAT {} → {} (mapped ports {:?})", prev.nat.label(), info.nat.label(), info.mapped_ports);
            } else if prev.mapped_ports != info.mapped_ports {
                tracing::debug!("network: mapped ports {:?}", info.mapped_ports);
            }
        }
        *self.info.write() = info.clone();
        info
    }

    /// Deliver a sealed signaling envelope through every available channel.
    pub async fn send_signal(&self, to: &PeerId, sealed: Vec<u8>, extra_relays: &[String]) -> usize {
        let mut n = 0;
        for url in extra_relays {
            self.add_remote_relay(url);
        }
        // (a peer relay run by the recipient itself can't reach it any better)
        let own = format!("peer:{}", to.to_base32());
        let relays: Vec<Arc<RelayClient>> = self.relays.read().iter().filter(|r| r.url != own).cloned().collect();
        for r in relays {
            if r.send_signal(*to, sealed.clone()).await {
                n += 1;
            }
        }
        let pool = self.nostr.read().clone();
        if let Some(p) = pool {
            if p.send_signal(to, &sealed) {
                n += 1;
            }
        }
        n
    }

    /// A direct path just died (NAT rebinding / network change): the signaling WebSockets
    /// through the same NAT may be dead too. Probe them (a ping each; only one that doesn't
    /// answer within 1.5 s reconnects — healthy ones are left alone) and wait (≤ 3 s) until
    /// they are up, so the repair offer and its answer get through.
    pub async fn probe_signaling(&self) {
        let t0 = std::time::Instant::now();
        let servers: Vec<Arc<RelayClient>> = self.relays.read().iter().filter(|r| !r.url.starts_with("peer:")).cloned().collect();
        let pool = self.nostr.read().clone();
        for r in &servers {
            r.probe();
        }
        if let Some(p) = &pool {
            p.probe();
        }
        let end = tokio::time::Instant::now() + Duration::from_secs(3);
        while tokio::time::Instant::now() < end {
            tokio::time::sleep(Duration::from_millis(30)).await;
            // answered the probe (or came back) after we asked
            let relays_up = servers.is_empty() || servers.iter().any(|r| r.alive_since(t0));
            let nostr_up = pool.as_ref().map(|p| p.alive_since(t0)).unwrap_or(true);
            if relays_up && nostr_up {
                return;
            }
        }
    }

    /// Probe one relay (by its index), e.g. the one a relayed connection rides on.
    pub fn probe_relay(&self, idx: u16) {
        if let Some(r) = self.relays.read().iter().find(|r| r.idx == idx) {
            r.probe();
        }
    }

    /// Fire punch probes so our NAT has a mapping before QUIC Initials arrive.
    pub async fn punch(&self, addrs: &[SocketAddr], sid: u64) {
        let mut p = PROBE_MAGIC.to_vec();
        p.push(1);
        p.extend_from_slice(&sid.to_be_bytes());
        for a in addrs {
            if magicsock::is_relay_addr(a) {
                continue;
            }
            let _ = self.raw.send_to(&p, *a).await;
        }
    }

    /// Dial every candidate in parallel, first successful handshake wins.
    pub async fn dial_direct(&self, peer: PeerId, addrs: Vec<SocketAddr>, timeout: Duration) -> Result<quinn::Connection> {
        if addrs.is_empty() {
            bail!("no candidates");
        }
        let cc = crate::tls::client_config(&self.id, self.devcert.as_ref(), Some(peer))?;
        let mut futs = Vec::new();
        for (i, a) in addrs.into_iter().enumerate() {
            let a = match a {
                SocketAddr::V4(v4) if self.local_is_v6() => {
                    SocketAddr::new(IpAddr::V6(v4.ip().to_ipv6_mapped()), v4.port())
                }
                other => other,
            };
            let ep = self.endpoint.clone();
            let cc = cc.clone();
            futs.push(Box::pin(async move {
                // Stagger slightly: LAN/IPv6 first, then the rest.
                tokio::time::sleep(Duration::from_millis((i as u64).min(10) * 25)).await;
                let c = ep.connect_with(cc, a, "lumora.peer")?;
                Ok::<_, anyhow::Error>(c.await?)
            }));
        }
        match tokio::time::timeout(timeout, futures::future::select_ok(futs)).await {
            Ok(Ok((c, _rest))) => Ok(c),
            Ok(Err(e)) => Err(e),
            Err(_) => Err(anyhow!("direct dial timeout")),
        }
    }

    fn local_is_v6(&self) -> bool {
        self.raw.local_addr().map(|a| a.is_ipv6()).unwrap_or(false)
    }

    /// QUIC through a relay (still end-to-end TLS).
    pub async fn dial_relay(&self, peer: PeerId, relay_url: &str) -> Result<quinn::Connection> {
        let idx = {
            let relays = self.relays.read();
            let r = relays.iter().find(|r| r.url == relay_url && r.is_connected()).ok_or_else(|| anyhow!("relay not connected"))?;
            r.idx
        };
        let addr = self.sock.router.register_peer(idx, peer);
        let cc = crate::tls::client_config(&self.id, self.devcert.as_ref(), Some(peer))?;
        let c = self.endpoint.connect_with(cc, addr, "lumora.peer")?;
        Ok(tokio::time::timeout(Duration::from_secs(12), c).await??)
    }

    /// Hard side of the birthday attack: many sockets → peer's (easy) address.
    /// Returns a connection plus the extra endpoint that must be kept alive.
    pub async fn spray_from_hard(
        &self,
        peer: PeerId,
        targets: Vec<SocketAddr>,
        sid: u64,
        dur: Duration,
        nsock: usize,
    ) -> Result<(quinn::Connection, quinn::Endpoint)> {
        let mut socks = Vec::new();
        for _ in 0..nsock {
            if let Ok(s) = std::net::UdpSocket::bind("0.0.0.0:0") {
                s.set_nonblocking(true)?;
                socks.push(Arc::new(tokio::net::UdpSocket::from_std(s)?));
            }
        }
        let (won_tx, mut won_rx) = mpsc::channel::<(usize, SocketAddr)>(4);
        let mut ping = PROBE_MAGIC.to_vec();
        ping.push(1);
        ping.extend_from_slice(&sid.to_be_bytes());
        let mut tasks = Vec::new();
        for (i, s) in socks.iter().enumerate() {
            let s = s.clone();
            let won = won_tx.clone();
            tasks.push(tokio::spawn(async move {
                let mut buf = [0u8; 64];
                while let Ok((n, src)) = s.recv_from(&mut buf).await {
                    if n >= 5 && &buf[..4] == PROBE_MAGIC {
                        let _ = won.send((i, src)).await;
                        return;
                    }
                }
            }));
        }
        let deadline = tokio::time::Instant::now() + dur;
        let mut tick = tokio::time::interval(Duration::from_millis(200));
        let result = loop {
            tokio::select! {
                _ = tick.tick() => {
                    if tokio::time::Instant::now() > deadline { break None }
                    for s in socks.iter() { for t in targets.iter() { let _ = s.send_to(&ping, *t).await; } }
                }
                w = won_rx.recv() => { break w }
            }
        };
        for t in tasks {
            t.abort();
        }
        let (i, src) = result.ok_or_else(|| anyhow!("spray: no hole found"))?;
        tracing::info!("birthday spray: hole found on socket {i} → {src}");
        let std_sock = socks[i].clone();
        drop(socks);
        let std_sock = Arc::try_unwrap(std_sock).map_err(|_| anyhow!("socket busy"))?.into_std()?;
        let ep = quinn::Endpoint::new(endpoint_config(), None, std_sock, Arc::new(quinn::TokioRuntime))?;
        let cc = crate::tls::client_config(&self.id, self.devcert.as_ref(), Some(peer))?;
        let c = ep.connect_with(cc, src, "lumora.peer")?;
        let conn = tokio::time::timeout(Duration::from_secs(8), c).await??;
        Ok((conn, ep))
    }

    /// Easy side of the birthday attack: probe many ports on the hard peer's IP from our main port.
    pub async fn spray_from_easy(&self, ip: IpAddr, nat: &NatKind, last_ports: &[u16], sid: u64, dur: Duration) {
        let mut ping = PROBE_MAGIC.to_vec();
        ping.push(1);
        ping.extend_from_slice(&sid.to_be_bytes());
        let mut ports: Vec<u16> = Vec::new();
        if let (NatKind::HardSequential(d), Some(last)) = (nat, last_ports.last()) {
            for k in 1..=256i64 {
                // untrusted delta from the peer: no overflow
                let Some(p) = (*d as i64).checked_mul(k).and_then(|x| x.checked_add(*last as i64)) else { break };
                if (1024..=65535).contains(&p) {
                    ports.push(p as u16);
                }
            }
        }
        let deadline = tokio::time::Instant::now() + dur;
        let mut sent = 0usize;
        while tokio::time::Instant::now() < deadline && sent < 4096 {
            for _ in 0..20 {
                let port = if sent < ports.len() { ports[sent] } else { 1024 + rand::random::<u16>() % 64511 };
                let _ = self.raw.send_to(&ping, SocketAddr::new(ip, port)).await;
                sent += 1;
            }
            tokio::time::sleep(Duration::from_millis(40)).await; // ~500 pps
        }
    }

    pub fn relay_status(&self) -> Vec<(String, bool)> {
        self.relays.read().iter().map(|r| (r.url.clone(), r.is_connected())).collect()
    }
    pub fn nostr_status(&self) -> Vec<(String, bool)> {
        self.nostr.read().as_ref().map(|p| p.status.read().clone()).unwrap_or_default()
    }
}

/// QUIC bit greasing off: our socket multiplexes STUN/probes on the same port and relies on
/// the fixed bit being set on every QUIC packet.
fn endpoint_config() -> quinn::EndpointConfig {
    let mut c = quinn::EndpointConfig::default();
    c.grease_quic_bit(false);
    c
}

/// Remote-suggested relays must be TLS and point at a public host (no SSRF into LAN/localhost).
pub fn is_safe_remote_relay(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("wss://") else { return false };
    let host_port = rest.split('/').next().unwrap_or("");
    let host = if host_port.starts_with('[') {
        host_port.trim_start_matches('[').split(']').next().unwrap_or("")
    } else {
        host_port.rsplit_once(':').map(|(h, _)| h).unwrap_or(host_port)
    };
    if host.is_empty() || host.eq_ignore_ascii_case("localhost") || host.ends_with(".local") || host.ends_with(".lan") {
        return false;
    }
    match host.parse::<IpAddr>() {
        Ok(ip) => crate::util::is_global_ip(&ip),
        Err(_) => host.contains('.') && url.len() < 256,
    }
}

/// NAT kind when no STUN server reported an IPv4 mapping.
///  * some server answered (over IPv6 only) → v6-only connectivity, treated as easy;
///  * servers were asked and none answered → UDP is filtered: say so, so both sides go to
///    the relay at once instead of waiting `relay_delay_ms` (the relay-observed public IP is
///    still offered as a candidate in case only the STUN servers are unreachable);
///  * no server configured / resolvable → we simply don't know (two-sided birthday spray).
fn no_v4_mapping_kind(asked_stun: bool, any_answer: bool) -> NatKind {
    if any_answer {
        NatKind::Easy
    } else if asked_stun {
        NatKind::UdpBlocked
    } else {
        NatKind::Unknown
    }
}

/// Candidate list for dialing a peer, ordered by preference.
pub fn order_candidates(mut addrs: Vec<SocketAddr>) -> Vec<SocketAddr> {
    addrs.retain(|a| a.port() != 0 && !a.ip().is_unspecified() && !magicsock::is_relay_addr(a));
    addrs.sort_by_key(|a| {
        let ip = a.ip();
        if !crate::util::is_global_ip(&ip) && !crate::util::is_cgnat(&ip) {
            0 // LAN
        } else if ip.is_ipv6() {
            1
        } else {
            2
        }
    });
    addrs.dedup();
    addrs.truncate(24);
    addrs
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn nat_kind_without_v4_mapping() {
        // STUN asked, silence: UDP blocked (NAT lab `udpblock`: relay at once, not after 4 s)
        assert_eq!(no_v4_mapping_kind(true, false), NatKind::UdpBlocked);
        // no STUN configured (or DNS down): unknown, even if a relay saw our IP
        assert_eq!(no_v4_mapping_kind(false, false), NatKind::Unknown);
        // only IPv6 STUN answered
        assert_eq!(no_v4_mapping_kind(true, true), NatKind::Easy);
    }

    #[test]
    fn relay_url_policy() {
        assert!(is_safe_remote_relay("wss://relay.example.com/ws"));
        assert!(!is_safe_remote_relay("ws://relay.example.com/ws"));
        assert!(!is_safe_remote_relay("wss://127.0.0.1:8443/ws"));
        assert!(!is_safe_remote_relay("wss://192.168.1.5/ws"));
        assert!(!is_safe_remote_relay("wss://localhost/ws"));
        assert!(is_safe_remote_relay("wss://8.8.8.8/ws"));
    }
}
