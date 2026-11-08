//! Blind two-hop circuits through volunteer relays — calls and big files between two
//! devices that can't connect (symmetric NATs on both sides, typical of mobile networks),
//! with no server of ours and without any relay learning who talks to whom.
//!
//! ```text
//!   A ──udp──▶ R1 ──udp──▶ R2 ◀──udp── B        (QUIC A⇄B end to end, over the circuit)
//! ```
//!
//! * **Volunteers** — devices on an easy network that turned on "Giúp mạng Lumora"
//!   (`help_network`) — announce `IP:port` on the BitTorrent DHT under a fixed info-hash
//!   (net/discovery.rs). Nothing else: no account, no ID.
//! * The caller A picks two volunteers R1, R2 on different networks and a random 64-bit
//!   circuit token, and tells B (sealed mail, `Ext CIRCUIT_INVITE`) "meet at R2, token T".
//!   B sends `JOIN T` to R2; A sends `OPEN T → R2` to R1; R1 asks R2 (`PROBE T`) and only
//!   forwards anything once R2 answers `ACK T` — R1 can't be made to send to an address
//!   that didn't ask for it (no reflection / flooding through relays).
//! * **What each relay learns:** R1 sees A's address and R2; R2 sees B's address and R1.
//!   No relay sees both ends, and none sees an identity: the payload is the end-to-end
//!   QUIC connection (TLS 1.3 — certificates are encrypted), the token is random per circuit.
//! * Bounded: slots per relay and per source address, bytes per second per slot, idle
//!   slots expire. A device relays only while `help_network` is on.
//!
//! Wire (UDP, on the node's main port, recognised as a side packet like STUN/probes):
//! `"\0LMC" | type u8 | token u64 BE | payload`. OPEN's payload is the next hop
//! (`4|ipv4|port` or `6|ipv6|port`), DATA's the QUIC datagram.

use super::*;
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU64, Ordering};
use std::time::Instant;

pub const CIRCUIT_MAGIC: &[u8; 4] = b"\x00LMC";
const OPEN: u8 = 1;
const JOIN: u8 = 2;
const PROBE: u8 = 3;
const ACK: u8 = 4;
const READY: u8 = 5;
const DATA: u8 = 6;
const HDR: usize = 4 + 1 + 8;

/// Virtual relay indices of circuits (WebSocket relays use small indices).
pub const IDX_BASE: u16 = 0xC000;
/// Relay side: slots in all / per source IP / bytes per second per slot / idle expiry.
const MAX_SLOTS: usize = 256;
const SLOTS_PER_IP: usize = 8;
const SLOT_BPS: u64 = 4 * 1024 * 1024;
const SLOT_IDLE: Duration = Duration::from_secs(90);
/// Client side: a circuit nobody used for this long is dropped.
const CIRC_IDLE: Duration = Duration::from_secs(120);

struct Slot {
    /// Who opened (OPEN) or joined (JOIN) it.
    a: SocketAddr,
    /// The other side: the next relay (opener) / the relay that probed (joined).
    b: Option<SocketAddr>,
    opener: bool,
    ready: bool,
    last: Instant,
    win: Instant,
    bytes: u64,
}

struct Circ {
    idx: u16,
    peer: PeerId,
    hop: SocketAddr,
    last: Instant,
}

#[derive(Default)]
pub struct Circuits {
    /// This device relays for others ("Giúp mạng Lumora").
    pub help: AtomicBool,
    slots: Mutex<HashMap<u64, Slot>>,
    circs: Mutex<HashMap<u64, Circ>>,
    ready_waits: Mutex<HashMap<u64, oneshot::Sender<()>>>,
    next_idx: AtomicU16,
    /// Relays given by configuration (tests, `LUMORA_CIRCUIT_RELAYS`) — used before the DHT.
    pub fixed: RwLock<Vec<SocketAddr>>,
    found: RwLock<Vec<SocketAddr>>,
    found_at: AtomicU64,
    pub relayed_bytes: AtomicU64,
}

fn packet(kind: u8, token: u64, payload: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(HDR + payload.len());
    v.extend_from_slice(CIRCUIT_MAGIC);
    v.push(kind);
    v.extend_from_slice(&token.to_be_bytes());
    v.extend_from_slice(payload);
    v
}

fn enc_addr(a: &SocketAddr) -> Vec<u8> {
    let mut v = Vec::new();
    match a.ip() {
        IpAddr::V4(ip) => {
            v.push(4);
            v.extend_from_slice(&ip.octets());
        }
        IpAddr::V6(ip) => {
            v.push(6);
            v.extend_from_slice(&ip.octets());
        }
    }
    v.extend_from_slice(&a.port().to_be_bytes());
    v
}

fn dec_addr(b: &[u8]) -> Option<SocketAddr> {
    match b.first()? {
        4 if b.len() >= 7 => Some(SocketAddr::new(IpAddr::from(<[u8; 4]>::try_from(&b[1..5]).ok()?), u16::from_be_bytes([b[5], b[6]]))),
        6 if b.len() >= 19 => Some(SocketAddr::new(IpAddr::from(<[u8; 16]>::try_from(&b[1..17]).ok()?), u16::from_be_bytes([b[17], b[18]]))),
        _ => None,
    }
}

/// Is this a circuit packet (a side packet of the main port)?
pub fn is_circuit_packet(d: &[u8]) -> bool {
    d.len() >= HDR && d.starts_with(CIRCUIT_MAGIC)
}

/// Two relays for one circuit: on different networks (/16 for IPv4), never `me`.
pub fn pick_two(relays: &[SocketAddr], me: Option<IpAddr>) -> Option<(SocketAddr, SocketAddr)> {
    use rand::seq::SliceRandom;
    let net = |a: &SocketAddr| match a.ip() {
        IpAddr::V4(v) => {
            let o = v.octets();
            [o[0], o[1], 0, 0]
        }
        IpAddr::V6(v) => {
            let o = v.octets();
            [o[0], o[1], o[2], o[3]]
        }
    };
    let mut all: Vec<SocketAddr> = relays.iter().copied().filter(|a| Some(a.ip()) != me).collect();
    all.shuffle(&mut rand::thread_rng());
    let r1 = *all.first()?;
    let r2 = all.iter().copied().find(|a| net(a) != net(&r1)).or_else(|| all.iter().copied().find(|a| *a != r1))?;
    Some((r1, r2))
}

impl Transport {
    // ------------------------------------------------------------ relay (volunteer) side

    pub(super) async fn on_circuit_packet(&self, src: SocketAddr, d: &[u8]) {
        let kind = d[4];
        let token = u64::from_be_bytes(d[5..13].try_into().unwrap());
        let body = &d[HDR..];
        // my own circuits first (I am A or B)
        if kind == DATA || kind == READY {
            let hit = {
                let mut c = self.circuits.circs.lock();
                c.get_mut(&token).filter(|c| c.hop == src).map(|c| {
                    c.last = Instant::now();
                    (c.idx, c.peer)
                })
            };
            if let Some((idx, peer)) = hit {
                if kind == READY {
                    if let Some(tx) = self.circuits.ready_waits.lock().remove(&token) {
                        let _ = tx.send(());
                    }
                } else {
                    let _ = self.relay_in_tx.try_send((magicsock::relay_addr(idx, &peer), Bytes::copy_from_slice(body)));
                }
                return;
            }
        }
        if !self.circuits.help.load(Ordering::Relaxed) {
            return;
        }
        let now = Instant::now();
        let mut out: Option<(SocketAddr, Vec<u8>)> = None;
        {
            let mut slots = self.circuits.slots.lock();
            if slots.len() >= MAX_SLOTS / 2 {
                slots.retain(|_, s| now.duration_since(s.last) < SLOT_IDLE);
            }
            let room = slots.len() < MAX_SLOTS && slots.values().filter(|s| s.a.ip() == src.ip()).count() < SLOTS_PER_IP;
            match kind {
                OPEN => {
                    let Some(next) = dec_addr(body) else { return };
                    if !crate::util::is_global_ip(&next.ip()) && !cfg!(debug_assertions) {
                        return; // a circuit goes to another public relay only
                    }
                    match slots.get_mut(&token) {
                        Some(s) if s.opener && s.a == src && s.b == Some(next) => {
                            s.last = now;
                            if s.ready {
                                out = Some((src, packet(READY, token, &[])));
                            } else {
                                out = Some((next, packet(PROBE, token, &[])));
                            }
                        }
                        Some(_) => return, // someone else's token
                        None if room => {
                            slots.insert(token, Slot { a: src, b: Some(next), opener: true, ready: false, last: now, win: now, bytes: 0 });
                            out = Some((next, packet(PROBE, token, &[])));
                        }
                        None => return,
                    }
                }
                JOIN => match slots.get_mut(&token) {
                    Some(s) if !s.opener && s.a == src => s.last = now,
                    Some(_) => return,
                    None if room => {
                        slots.insert(token, Slot { a: src, b: None, opener: false, ready: false, last: now, win: now, bytes: 0 });
                    }
                    None => return,
                },
                PROBE => {
                    // the first relay asks whether the joiner is here
                    if let Some(s) = slots.get_mut(&token).filter(|s| !s.opener && (s.b.is_none() || s.b == Some(src))) {
                        s.b = Some(src);
                        s.ready = true;
                        s.last = now;
                        out = Some((src, packet(ACK, token, &[])));
                    }
                }
                ACK => {
                    if let Some(s) = slots.get_mut(&token).filter(|s| s.opener && s.b == Some(src)) {
                        s.ready = true;
                        s.last = now;
                        out = Some((s.a, packet(READY, token, &[])));
                    }
                }
                DATA => {
                    if let Some(s) = slots.get_mut(&token).filter(|s| s.ready) {
                        let to = if src == s.a { s.b } else if Some(src) == s.b { Some(s.a) } else { None };
                        if let Some(to) = to {
                            if now.duration_since(s.win) >= Duration::from_secs(1) {
                                s.win = now;
                                s.bytes = 0;
                            }
                            s.bytes += body.len() as u64;
                            s.last = now;
                            if s.bytes <= SLOT_BPS {
                                out = Some((to, d.to_vec()));
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        if let Some((to, p)) = out {
            if kind == DATA {
                self.circuits.relayed_bytes.fetch_add(p.len() as u64, Ordering::Relaxed);
            }
            let _ = self.raw.send_to(&p, to).await;
        }
    }

    // ------------------------------------------------------------ circuit ends (A and B)

    /// A circuit end: a virtual relay index whose datagrams go to `hop` wrapped in DATA.
    fn circuit_end(&self, peer: PeerId, token: u64, hop: SocketAddr) -> SocketAddr {
        let idx = IDX_BASE + (self.circuits.next_idx.fetch_add(1, Ordering::Relaxed) % 0x3FFF);
        let (tx, mut rx) = mpsc::channel::<magicsock::RelayOut>(1024);
        self.sock.router.relays.write().insert(idx, tx);
        self.circuits.circs.lock().insert(token, Circ { idx, peer, hop, last: Instant::now() });
        let raw = self.raw.clone();
        tokio::spawn(async move {
            while let Some(o) = rx.recv().await {
                let _ = raw.send_to(&packet(DATA, token, &o.data), hop).await;
            }
        });
        self.sock.router.register_peer(idx, peer)
    }

    /// Caller (A): open a circuit to `peer` through `r1` then `r2` (where `peer` joins).
    /// Returns the virtual address to dial once both relays are linked.
    pub async fn circuit_open(&self, peer: PeerId, token: u64, r1: SocketAddr, r2: SocketAddr) -> Result<SocketAddr> {
        let (tx, mut rx) = oneshot::channel();
        self.circuits.ready_waits.lock().insert(token, tx);
        let vaddr = self.circuit_end(peer, token, r1);
        let open = packet(OPEN, token, &enc_addr(&r2));
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        loop {
            let _ = self.raw.send_to(&open, r1).await;
            tokio::select! {
                r = &mut rx => { r.map_err(|_| anyhow!("circuit cancelled"))?; return Ok(vaddr); }
                _ = tokio::time::sleep(Duration::from_millis(400)) => {}
            }
            if tokio::time::Instant::now() > deadline {
                self.circuits.ready_waits.lock().remove(&token);
                self.circuit_drop(token);
                bail!("circuit: relays didn't link");
            }
        }
    }

    /// Callee (B): join the circuit `token` at `r2`, for `peer` (A's device). The join is
    /// repeated (NAT mapping + until A's side links) and kept alive while the circuit is used.
    pub fn circuit_join(self: &Arc<Self>, peer: PeerId, token: u64, r2: SocketAddr) -> SocketAddr {
        let vaddr = self.circuit_end(peer, token, r2);
        let me = self.clone();
        tokio::spawn(async move {
            let join = packet(JOIN, token, &[]);
            let t0 = Instant::now();
            loop {
                let _ = me.raw.send_to(&join, r2).await;
                let alive = me.circuits.circs.lock().get(&token).map(|c| c.last.elapsed() < CIRC_IDLE);
                match alive {
                    None => return,
                    Some(false) if t0.elapsed() > Duration::from_secs(30) => {
                        me.circuit_drop(token);
                        return;
                    }
                    _ => {}
                }
                let every = if t0.elapsed() < Duration::from_secs(12) { 1 } else { 15 };
                tokio::time::sleep(Duration::from_secs(every)).await;
            }
        });
        vaddr
    }

    /// QUIC over a circuit (end-to-end TLS, as on any path).
    pub async fn dial_circuit(&self, peer: PeerId, vaddr: SocketAddr) -> Result<quinn::Connection> {
        let cc = crate::tls::client_config(&self.id, self.devcert.as_ref(), Some(peer))?;
        let c = self.endpoint.connect_with(cc, vaddr, "lumora.peer")?;
        Ok(tokio::time::timeout(Duration::from_secs(12), c).await??)
    }

    /// Is the circuit behind virtual relay index `idx` still there?
    pub fn circuit_alive(&self, idx: u16) -> bool {
        self.circuits.circs.lock().values().any(|c| c.idx == idx)
    }

    fn circuit_drop(&self, token: u64) {
        if let Some(c) = self.circuits.circs.lock().remove(&token) {
            self.sock.router.relays.write().remove(&c.idx);
        }
    }

    /// Circuits nobody used for a while go (the QUIC connection over one is gone too).
    pub fn circuit_sweep(&self) {
        let dead: Vec<u64> = self.circuits.circs.lock().iter().filter(|(_, c)| c.last.elapsed() > CIRC_IDLE).map(|(t, _)| *t).collect();
        for t in dead {
            self.circuit_drop(t);
        }
    }

    /// Volunteer relays to build circuits with: configured ones, then the DHT's (cached).
    pub async fn circuit_relays(&self) -> Vec<SocketAddr> {
        let mut out = self.circuits.fixed.read().clone();
        let at = self.circuits.found_at.load(Ordering::Relaxed);
        if crate::util::now_ms().saturating_sub(at) > 10 * 60_000 {
            if let Some(d) = self.dht.as_ref() {
                let found = d.find_circuit_relays().await;
                if !found.is_empty() {
                    *self.circuits.found.write() = found;
                    self.circuits.found_at.store(crate::util::now_ms(), Ordering::Relaxed);
                }
            }
        }
        for a in self.circuits.found.read().iter() {
            if !out.contains(a) {
                out.push(*a);
            }
        }
        out
    }

    /// Volunteering: announce this node as a circuit relay (only on an easy network with a
    /// known public address — a relay others can actually reach).
    pub async fn circuit_announce(&self) {
        if !self.circuits.help.load(Ordering::Relaxed) {
            return;
        }
        let info = self.info.read().clone();
        if info.nat.is_hard() || matches!(info.nat, NatKind::UdpBlocked | NatKind::Unknown) || info.public_ip.is_none() {
            return;
        }
        let port = info.mapped_ports.first().copied().unwrap_or(info.port);
        if let Some(d) = self.dht.as_ref() {
            if let Err(e) = d.announce_circuit_relay(port).await {
                tracing::debug!("circuit relay announce: {e:#}");
            } else {
                tracing::info!("helping the Lumora network: circuit relay announced on port {port}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addr_roundtrip_and_packet_shape() {
        for a in ["1.2.3.4:5678", "[2001:db8::1]:443"] {
            let a: SocketAddr = a.parse().unwrap();
            assert_eq!(dec_addr(&enc_addr(&a)), Some(a));
        }
        let p = packet(DATA, 7, b"x");
        assert!(is_circuit_packet(&p) && magicsock::is_side_packet(&p));
        assert!(!is_circuit_packet(b"\x00LMC"), "too short");
        // a QUIC packet (fixed bit set) is never taken for a circuit packet
        assert!(!magicsock::is_side_packet(&[0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
    }

    #[test]
    fn two_relays_on_different_networks_never_me() {
        let r: Vec<SocketAddr> = ["1.2.3.4:1", "1.2.9.9:1", "5.6.7.8:1"].iter().map(|s| s.parse().unwrap()).collect();
        for _ in 0..50 {
            let (a, b) = pick_two(&r, Some("5.6.7.8".parse().unwrap())).unwrap_or((r[0], r[1]));
            assert_ne!(a, b);
            assert_ne!(a.ip().to_string(), "5.6.7.8");
            assert_ne!(b.ip().to_string(), "5.6.7.8");
        }
        let (a, b) = pick_two(&r, None).unwrap();
        assert_ne!(a, b);
        assert!(pick_two(&r[..1], None).is_none());
    }
}
