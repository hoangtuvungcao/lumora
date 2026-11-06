//! "Magic socket": one UDP port that carries
//!   * QUIC packets (handed to quinn),
//!   * STUN requests/responses and NAT-punch probes (intercepted, never reach quinn),
//!   * QUIC packets tunnelled through relays (virtual addresses in `fd4c:756d::/32`).
//!
//! Because relayed packets are still QUIC, end-to-end TLS is preserved on every path
//! and the relay only sees ciphertext.

use bytes::Bytes;
use parking_lot::{Mutex, RwLock};
use quinn::udp::{RecvMeta, Transmit};
use quinn::{AsyncUdpSocket, Runtime, UdpPoller};
use std::collections::HashMap;
use std::fmt;
use std::io::{self, IoSliceMut};
use std::net::{IpAddr, Ipv6Addr, SocketAddr, UdpSocket};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use tokio::sync::mpsc;

use crate::identity::PeerId;

/// Prefix of probe packets used for hole punching (first byte 0 => never QUIC).
pub const PROBE_MAGIC: &[u8; 4] = b"\x00LMP";

/// Is this datagram something *we* handle (STUN / probes) rather than QUIC?
/// QUIC always sets the "fixed bit" (0x40); STUN always has the two top bits clear.
pub fn is_side_packet(d: &[u8]) -> bool {
    // Must match *exactly*: QUIC may "grease" the fixed bit (RFC 9287), so the first-byte
    // test alone would steal real QUIC packets.
    if d.is_empty() || (d[0] & 0xC0) != 0 {
        return false;
    }
    d.starts_with(PROBE_MAGIC) || super::stun::is_stun(d)
}

pub fn is_relay_addr(a: &SocketAddr) -> bool {
    match a.ip() {
        IpAddr::V6(v6) => {
            let s = v6.segments();
            s[0] == 0xfd4c && s[1] == 0x756d
        }
        _ => false,
    }
}

pub fn relay_addr(relay_idx: u16, peer: &PeerId) -> SocketAddr {
    let p = &peer.0;
    let ip = Ipv6Addr::new(
        0xfd4c,
        0x756d,
        relay_idx,
        u16::from_be_bytes([p[0], p[1]]),
        u16::from_be_bytes([p[2], p[3]]),
        u16::from_be_bytes([p[4], p[5]]),
        u16::from_be_bytes([p[6], p[7]]),
        u16::from_be_bytes([p[8], p[9]]),
    );
    SocketAddr::new(IpAddr::V6(ip), 7)
}

pub fn relay_idx_of(a: &SocketAddr) -> Option<u16> {
    match a.ip() {
        IpAddr::V6(v6) if is_relay_addr(a) => Some(v6.segments()[2]),
        _ => None,
    }
}

/// Outgoing datagram for a relay connection.
pub struct RelayOut {
    pub to: PeerId,
    pub data: Bytes,
}

/// Virtual relay addresses remembered at most (least recently registered ones go first).
pub const RELAY_PEERS_MAX: usize = 4096;

pub struct RelayRouter {
    /// relay index → sender into that relay connection
    pub relays: RwLock<HashMap<u16, mpsc::Sender<RelayOut>>>,
    /// virtual address → peer id (bounded LRU: a flood of relayed senders evicts the
    /// stalest entries, never everyone's)
    pub peers: Mutex<lru::LruCache<SocketAddr, PeerId>>,
}

impl Default for RelayRouter {
    fn default() -> Self {
        RelayRouter { relays: RwLock::new(HashMap::new()), peers: Mutex::new(lru::LruCache::new(std::num::NonZeroUsize::new(RELAY_PEERS_MAX).unwrap())) }
    }
}

impl RelayRouter {
    pub fn register_peer(&self, idx: u16, peer: PeerId) -> SocketAddr {
        let a = relay_addr(idx, &peer);
        self.peers.lock().put(a, peer);
        a
    }

    /// The peer behind a virtual relay address (also counts as use).
    pub fn peer_of(&self, a: &SocketAddr) -> Option<PeerId> {
        self.peers.lock().get(a).copied()
    }
}

pub struct MagicSock {
    inner: Arc<dyn AsyncUdpSocket>,
    raw: Arc<tokio::net::UdpSocket>,
    relay_in: Mutex<mpsc::Receiver<(SocketAddr, Bytes)>>,
    pub router: Arc<RelayRouter>,
    side_tx: mpsc::Sender<(SocketAddr, Vec<u8>)>,
}

impl fmt::Debug for MagicSock {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("MagicSock")
    }
}

pub struct MagicHandles {
    pub sock: Arc<MagicSock>,
    /// Raw sender (for STUN / probes) bound to the *same* port as QUIC.
    pub raw: Arc<tokio::net::UdpSocket>,
    /// Feed datagrams received from relays (virtual source address) into QUIC.
    pub relay_in_tx: mpsc::Sender<(SocketAddr, Bytes)>,
    /// STUN responses / probes received on the main port.
    pub side_rx: mpsc::Receiver<(SocketAddr, Vec<u8>)>,
}

/// Bind a dual-stack UDP socket (falls back to IPv4-only).
pub fn bind_udp(port: u16) -> io::Result<UdpSocket> {
    use socket2::{Domain, Protocol, Socket, Type};
    let try_v6 = || -> io::Result<UdpSocket> {
        let s = Socket::new(Domain::IPV6, Type::DGRAM, Some(Protocol::UDP))?;
        s.set_only_v6(false)?;
        let _ = s.set_recv_buffer_size(4 * 1024 * 1024);
        let _ = s.set_send_buffer_size(4 * 1024 * 1024);
        s.bind(&SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), port).into())?;
        s.set_nonblocking(true)?;
        Ok(s.into())
    };
    match try_v6() {
        Ok(s) => Ok(s),
        Err(_) => {
            let s = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
            let _ = s.set_recv_buffer_size(4 * 1024 * 1024);
            s.bind(&SocketAddr::from(([0, 0, 0, 0], port)).into())?;
            s.set_nonblocking(true)?;
            Ok(s.into())
        }
    }
}

impl MagicSock {
    pub fn create(sock: UdpSocket) -> io::Result<MagicHandles> {
        let dup = sock.try_clone()?;
        let raw = Arc::new(tokio::net::UdpSocket::from_std(dup)?);
        #[cfg(not(windows))]
        let inner = quinn::TokioRuntime.wrap_udp_socket(sock)?;
        #[cfg(windows)]
        let inner = win_plain::wrap(sock, &raw)?;
        let (relay_in_tx, relay_in_rx) = mpsc::channel(4096);
        let (side_tx, side_rx) = mpsc::channel(1024);
        let ms = Arc::new(MagicSock {
            inner,
            raw: raw.clone(),
            relay_in: Mutex::new(relay_in_rx),
            router: Arc::new(RelayRouter::default()),
            side_tx,
        });
        Ok(MagicHandles { sock: ms, raw, relay_in_tx, side_rx })
    }

    fn send_relay(&self, t: &Transmit) -> io::Result<()> {
        let Some(idx) = relay_idx_of(&t.destination) else { return Ok(()) };
        let Some(peer) = self.router.peer_of(&t.destination) else { return Ok(()) };
        let relays = self.router.relays.read();
        let Some(tx) = relays.get(&idx) else { return Ok(()) };
        let seg = t.segment_size.unwrap_or(t.contents.len()).max(1);
        for chunk in t.contents.chunks(seg) {
            // Drop on overflow – QUIC recovers, exactly like a congested UDP link.
            let _ = tx.try_send(RelayOut { to: peer, data: Bytes::copy_from_slice(chunk) });
        }
        Ok(())
    }

    pub fn local_port(&self) -> u16 {
        self.raw.local_addr().map(|a| a.port()).unwrap_or(0)
    }
}

impl AsyncUdpSocket for MagicSock {
    fn create_io_poller(self: Arc<Self>) -> Pin<Box<dyn UdpPoller>> {
        self.inner.clone().create_io_poller()
    }

    fn try_send(&self, transmit: &Transmit) -> io::Result<()> {
        if is_relay_addr(&transmit.destination) {
            return self.send_relay(transmit);
        }
        match self.inner.try_send(transmit) {
            // Unreachable networks (e.g. IPv6 candidate without v6 route) must not kill the endpoint.
            Err(e) if e.kind() != io::ErrorKind::WouldBlock => Ok(()),
            r => r,
        }
    }

    fn poll_recv(
        &self,
        cx: &mut Context,
        bufs: &mut [IoSliceMut<'_>],
        meta: &mut [RecvMeta],
    ) -> Poll<io::Result<usize>> {
        // 1. relayed packets
        {
            let mut rx = self.relay_in.lock();
            if let Poll::Ready(Some((addr, data))) = rx.poll_recv(cx) {
                let n = data.len().min(bufs[0].len());
                bufs[0][..n].copy_from_slice(&data[..n]);
                meta[0] = RecvMeta { addr, len: n, stride: n, ecn: None, dst_ip: None };
                return Poll::Ready(Ok(1));
            }
        }
        // 2. real UDP; intercept STUN/probes
        loop {
            match self.inner.poll_recv(cx, &mut bufs[..1], &mut meta[..1]) {
                Poll::Ready(Ok(n)) if n > 0 => {
                    let m = meta[0];
                    let d = &bufs[0][..m.len];
                    if m.len == m.stride && is_side_packet(d) {
                        let _ = self.side_tx.try_send((crate::util::canon(m.addr), d.to_vec())); // drop on overload
                        continue;
                    }
                    return Poll::Ready(Ok(n));
                }
                Poll::Ready(Err(e)) if e.kind() == io::ErrorKind::ConnectionRefused => continue,
                other => return other,
            }
        }
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        self.inner.local_addr()
    }
    fn max_transmit_segments(&self) -> usize {
        self.inner.max_transmit_segments()
    }
    fn max_receive_segments(&self) -> usize {
        // Must match the real socket: with UDP GRO the kernel coalesces several datagrams
        // into one buffer, and quinn sizes its receive buffers from this value.
        self.inner.max_receive_segments()
    }
    fn may_fragment(&self) -> bool {
        self.inner.may_fragment()
    }
}

/// Windows: quinn-udp enables IP_PKTINFO / IP_RECVECN / IP_DONTFRAGMENT and fails hard if
/// the stack rejects one of them (Wine ≤ 9 has no IP_RECVECN → WSAENOPROTOOPT; some
/// third-party firewall/VPN layered providers do the same). Rather than refusing to start,
/// fall back to a plain non-blocking UDP socket (no ECN, no GSO/GRO, no DF bit).
#[cfg(windows)]
mod win_plain {
    use super::*;

    pub(super) fn wrap(sock: UdpSocket, raw: &Arc<tokio::net::UdpSocket>) -> io::Result<Arc<dyn AsyncUdpSocket>> {
        let spare = sock.try_clone()?;
        match quinn::TokioRuntime.wrap_udp_socket(sock) {
            Ok(s) => {
                drop(spare);
                Ok(s)
            }
            Err(e) => {
                tracing::warn!("UDP socket: optimized I/O unavailable ({e}); using plain UDP (no ECN/GSO)");
                drop(spare);
                Ok(Arc::new(PlainUdp { io: raw.clone() }))
            }
        }
    }

    struct PlainUdp {
        io: Arc<tokio::net::UdpSocket>,
    }

    impl fmt::Debug for PlainUdp {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str("PlainUdp")
        }
    }

    struct Poller {
        io: Arc<tokio::net::UdpSocket>,
    }

    impl fmt::Debug for Poller {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str("PlainUdpPoller")
        }
    }

    impl UdpPoller for Poller {
        fn poll_writable(self: Pin<&mut Self>, cx: &mut Context) -> Poll<io::Result<()>> {
            self.io.poll_send_ready(cx)
        }
    }

    impl AsyncUdpSocket for PlainUdp {
        fn create_io_poller(self: Arc<Self>) -> Pin<Box<dyn UdpPoller>> {
            Box::pin(Poller { io: self.io.clone() })
        }

        fn try_send(&self, t: &Transmit) -> io::Result<()> {
            let seg = t.segment_size.unwrap_or(t.contents.len()).max(1);
            for chunk in t.contents.chunks(seg) {
                self.io.try_send_to(chunk, t.destination)?;
            }
            Ok(())
        }

        fn poll_recv(&self, cx: &mut Context, bufs: &mut [IoSliceMut<'_>], meta: &mut [RecvMeta]) -> Poll<io::Result<usize>> {
            loop {
                let mut rb = tokio::io::ReadBuf::new(&mut bufs[0]);
                match self.io.poll_recv_from(cx, &mut rb) {
                    Poll::Ready(Ok(addr)) => {
                        let n = rb.filled().len();
                        meta[0] = RecvMeta { addr, len: n, stride: n, ecn: None, dst_ip: None };
                        return Poll::Ready(Ok(1));
                    }
                    // ICMP port unreachable surfaces as WSAECONNRESET on Windows UDP sockets.
                    Poll::Ready(Err(e))
                        if matches!(e.kind(), io::ErrorKind::ConnectionReset | io::ErrorKind::ConnectionRefused) =>
                    {
                        continue
                    }
                    other => return other.map_ok(|_| 0),
                }
            }
        }

        fn local_addr(&self) -> io::Result<SocketAddr> {
            self.io.local_addr()
        }
        fn max_transmit_segments(&self) -> usize {
            1
        }
        fn max_receive_segments(&self) -> usize {
            1
        }
        fn may_fragment(&self) -> bool {
            true
        }
    }
}

#[cfg(test)]
mod router_tests {
    use super::*;

    /// #21: past 4096 entries the whole map was cleared (every relayed connection lost its
    /// route at once); now only the least recently used address goes.
    #[test]
    fn relay_router_evicts_one_entry_not_all() {
        let r = RelayRouter::default();
        let first = r.register_peer(1, PeerId([1; 32]));
        for i in 0..(RELAY_PEERS_MAX as u32 + 100) {
            let mut k = [0u8; 32];
            k[..4].copy_from_slice(&i.to_le_bytes());
            k[31] = 7;
            r.register_peer(1, PeerId(k));
            // the busy connection keeps using its route
            assert!(r.peer_of(&first).is_some(), "an active route was dropped after {i} others");
        }
        assert_eq!(r.peers.lock().len(), RELAY_PEERS_MAX);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn classify() {
        assert!(is_side_packet(&super::super::stun::binding_request(&[1; 12])));
        assert!(is_side_packet(b"\x00LMP\x01abcdefgh"));
        // greased QUIC short header (fixed bit cleared) must NOT be taken
        assert!(!is_side_packet(&[0x00, 0x01, 0, 0, 9, 9, 9, 9]));
        assert!(!is_side_packet(&[0xC0, 0]));
        assert!(!is_side_packet(&[0x40, 0]));
        let p = PeerId([7; 32]);
        let a = relay_addr(3, &p);
        assert!(is_relay_addr(&a));
        assert_eq!(relay_idx_of(&a), Some(3));
        assert!(!is_relay_addr(&"[2001::1]:5".parse().unwrap()));
    }
}
