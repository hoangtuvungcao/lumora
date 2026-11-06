//! Local + global discovery helpers that need no server of our own:
//! * LAN multicast announcements (same Wi-Fi → direct LAN path, zero Internet)
//! * UPnP-IGD port mapping (router opens a port for us)
//! * BitTorrent Mainline DHT records: a public one (no addresses — anyone who knows our
//!   public key can read it) and a friends-only one with addresses, encrypted with a
//!   random key we hand only to friends and our own devices (`Ext DHT_KEY`)

use super::ConnInfo;
use crate::identity::PeerId;
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub const LAN_GROUP: Ipv4Addr = Ipv4Addr::new(239, 255, 76, 77);
pub const LAN_PORT: u16 = 47777;

/// Legacy LAN announcement (magic `LMRA`): carries the public key in clear, so anyone on
/// the same Wi-Fi learns who is there. Still *accepted* from older builds, never sent.
#[derive(Serialize, Deserialize)]
struct LanAnnounce {
    v: u8,
    peer: PeerId,
    port: u16,
    addrs: Vec<SocketAddr>,
}

/// LAN announcement (magic `LMRH`, older builds ignore it): only today's [`lan_hint`] —
/// like the mDNS advertisement, recognisable only by someone who already knows us.
#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct LanHintAnnounce {
    v: u8,
    /// 16 hex chars, rotates daily
    h: String,
    port: u16,
    /// LAN (non-global) addresses only
    #[serde(default)]
    addrs: Vec<SocketAddr>,
}

/// Packet for the LAN announcement of `me` today.
fn lan_hint_packet(me: &PeerId, port: u16, addrs: Vec<SocketAddr>) -> Vec<u8> {
    let a = LanHintAnnounce { v: 1, h: lan_hint(me, lan_day()), port, addrs: lan_only(addrs) };
    let mut pkt = b"LMRH".to_vec();
    pkt.extend(rmp_serde::to_vec_named(&a).unwrap_or_default());
    pkt
}

/// Only addresses that make sense on a LAN (never a public / global one).
pub fn lan_only(addrs: Vec<SocketAddr>) -> Vec<SocketAddr> {
    addrs.into_iter().filter(|a| !crate::util::is_global_ip(&a.ip()) && !crate::util::is_cgnat(&a.ip())).take(8).collect()
}

/// "A new device waiting to be linked" (multi-device short-code path). A separate packet
/// type (magic `LMRL`) because `LanAnnounce` v1 parsers reject extra fields; older
/// versions ignore unknown magics. Carries no secret: only the code's rendezvous hash.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct LinkBeacon {
    pub v: u8,
    /// first 8 bytes of `devices::code_rendezvous(code)`
    #[serde(with = "serde_bytes")]
    pub rv: Vec<u8>,
    pub peer: PeerId,
    pub port: u16,
    pub addrs: Vec<SocketAddr>,
}

/// A device heard announcing a link rendezvous: (device, addresses, when).
pub type LinkCandidate = (PeerId, Vec<SocketAddr>, Instant);

#[derive(Default)]
pub struct LanTable {
    /// While this device waits to be linked: the rendezvous id it announces.
    pub link_beacon: RwLock<Option<[u8; 8]>>,
    /// Link beacons heard: rendezvous id → candidates (unauthenticated: the PAKE decides).
    pub link_beacons: RwLock<HashMap<[u8; 8], Vec<LinkCandidate>>>,
    pub peers: RwLock<HashMap<PeerId, (Vec<SocketAddr>, Instant)>>,
    /// Bonjour/DNS-SD sightings keyed by the peer's daily LAN hint ([`lan_hint`]): the
    /// advertisement never contains the public key, so we only learn *which* known peer
    /// it is when we look one up by id.
    pub hints: RwLock<HashMap<String, (Vec<SocketAddr>, Instant)>>,
}

impl LanTable {
    /// Candidates (device, addresses) for a link code's rendezvous id, newest first.
    pub fn link_candidates(&self, rv: &[u8; 8]) -> Vec<(PeerId, Vec<SocketAddr>)> {
        let t = self.link_beacons.read();
        let mut v: Vec<_> = t.get(rv).cloned().unwrap_or_default().into_iter().filter(|(_, _, at)| at.elapsed() < Duration::from_secs(30)).collect();
        v.sort_by_key(|(_, _, at)| std::cmp::Reverse(*at));
        v.into_iter().map(|(p, a, _)| (p, a)).collect()
    }

    fn add_link_beacon(&self, b: LinkBeacon, src: SocketAddr) {
        let Ok(rv) = <[u8; 8]>::try_from(b.rv.as_slice()) else { return };
        let mut addrs = vec![SocketAddr::new(src.ip(), b.port)];
        for x in b.addrs.into_iter().take(8) {
            if !addrs.contains(&x) {
                addrs.push(x);
            }
        }
        let mut t = self.link_beacons.write();
        if t.len() > 64 {
            t.retain(|_, v| v.iter().any(|(_, _, at)| at.elapsed() < Duration::from_secs(30)));
        }
        if t.len() >= 128 && !t.contains_key(&rv) {
            return;
        }
        let e = t.entry(rv).or_default();
        e.retain(|(p, _, at)| *p != b.peer && at.elapsed() < Duration::from_secs(30));
        if e.len() < 8 {
            e.push((b.peer, addrs, Instant::now()));
        }
    }

    pub fn get(&self, p: &PeerId) -> Vec<SocketAddr> {
        let mut out = self
            .peers
            .read()
            .get(p)
            .filter(|(_, t)| t.elapsed() < Duration::from_secs(60))
            .map(|(a, _)| a.clone())
            .unwrap_or_default();
        let hints = self.hints.read();
        if !hints.is_empty() {
            // yesterday/today/tomorrow: tolerate clock skew around midnight UTC
            let d = lan_day();
            for day in [d, d.saturating_sub(1), d + 1] {
                if let Some((addrs, t)) = hints.get(&lan_hint(p, day)) {
                    if t.elapsed() < Duration::from_secs(120) {
                        for a in addrs {
                            if !out.contains(a) {
                                out.push(*a);
                            }
                        }
                    }
                }
            }
        }
        out
    }

    /// Record a DNS-SD sighting (from mdns-sd, or from iOS Bonjour via the FFI).
    pub fn add_hint(&self, hint: &str, addrs: Vec<SocketAddr>) -> bool {
        let hint = hint.trim().to_ascii_lowercase();
        if hint.len() != 16 || !hint.bytes().all(|c| c.is_ascii_hexdigit()) || addrs.is_empty() {
            return false;
        }
        let mut addrs = addrs;
        addrs.truncate(8);
        let mut h = self.hints.write();
        if h.len() > 256 {
            h.retain(|_, (_, at)| at.elapsed() < Duration::from_secs(120));
        }
        if h.len() >= 512 && !h.contains_key(&hint) {
            return false;
        }
        h.insert(hint, (addrs, Instant::now()));
        true
    }
}

/// Day number used for LAN hints (rotates daily so the advertisement is not a
/// long-term tracking id).
pub fn lan_day() -> u64 {
    crate::util::now_ms() / 86_400_000
}

/// 16-hex-char Bonjour instance name / TXT `id` for `p` on `day`. Not reversible to the
/// public key; only someone who already knows `p` can recognise it.
pub fn lan_hint(p: &PeerId, day: u64) -> String {
    let mut m = p.0.to_vec();
    m.extend_from_slice(&day.to_le_bytes());
    hex::encode(&blake3::derive_key("lumora lan hint v1", &m)[..8])
}

/// DNS-SD service type. Tests (debug builds only) may isolate themselves with
/// `LUMORA_MDNS_SERVICE`; release builds ignore the variable.
pub fn mdns_service() -> String {
    cfg!(debug_assertions)
        .then(|| std::env::var("LUMORA_MDNS_SERVICE").ok())
        .flatten()
        .filter(|s| s.starts_with('_') && s.ends_with(".local.") && s.len() < 64)
        .unwrap_or_else(|| "_lumora._udp.local.".to_string())
}

/// Advertise `_lumora._udp` (instance = today's hint, TXT `v=1`, `id=<hint>`) and browse for
/// others, feeding sightings into [`LanTable::add_hint`]. Pure DNS-SD (RFC 6762/6763): works
/// alongside Avahi/Bonjour and needs no Apple multicast entitlement on the other side.
#[cfg(all(feature = "mdns", not(target_os = "ios")))]
pub fn spawn_mdns(me: PeerId, port: u16, table: Arc<LanTable>, enabled: Arc<std::sync::atomic::AtomicBool>) {
    use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
    use std::sync::atomic::Ordering;
    let service = mdns_service();
    let daemon = match ServiceDaemon::new() {
        Ok(d) => d,
        Err(e) => {
            tracing::warn!("mDNS discovery disabled: {e}");
            return;
        }
    };
    let rx = match daemon.browse(&service) {
        Ok(rx) => rx,
        Err(e) => {
            tracing::warn!("mDNS browse failed: {e}");
            return;
        }
    };
    // advertiser: (re)register when the hint rotates or the user toggles LAN discovery
    let d2 = daemon.clone();
    let svc2 = service.clone();
    let en2 = enabled.clone();
    tokio::spawn(async move {
        let mut current: Option<String> = None;
        loop {
            let want = en2.load(Ordering::Relaxed).then(|| lan_hint(&me, lan_day()));
            if want != current {
                if let Some(old) = current.take() {
                    let _ = d2.unregister(&format!("{old}.{svc2}"));
                }
                if let Some(h) = want.clone() {
                    let props: HashMap<String, String> = [("v".to_string(), "1".to_string()), ("id".to_string(), h.clone())].into();
                    match ServiceInfo::new(&svc2, &h, &format!("{h}.local."), (), port, props) {
                        Ok(info) => match d2.register(info.enable_addr_auto()) {
                            Ok(()) => tracing::debug!("mDNS: advertising {h}.{svc2} port {port}"),
                            Err(e) => tracing::warn!("mDNS register failed: {e}"),
                        },
                        Err(e) => tracing::warn!("mDNS service info: {e}"),
                    }
                }
                current = want;
            }
            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    });
    tokio::spawn(async move {
        let _keep = daemon;
        while let Ok(ev) = rx.recv_async().await {
            let ServiceEvent::ServiceResolved(info) = ev else { continue };
            if !enabled.load(Ordering::Relaxed) {
                continue;
            }
            let Some(hint) = info.get_property_val_str("id").map(str::to_string) else { continue };
            if info.get_property_val_str("v") != Some("1") {
                continue;
            }
            let d = lan_day();
            if [d, d.saturating_sub(1), d + 1].iter().any(|day| lan_hint(&me, *day) == hint) {
                continue; // ourselves
            }
            let port = info.get_port();
            let mut addrs: Vec<SocketAddr> = info
                .get_addresses()
                .iter()
                .map(|ip| ip.to_ip_addr())
                .filter(|ip| !ip.is_unspecified() && !matches!(ip, IpAddr::V6(v6) if (v6.segments()[0] & 0xffc0) == 0xfe80))
                .map(|ip| SocketAddr::new(ip, port))
                .collect();
            addrs.sort_by_key(|a| (a.is_ipv6(), a.ip().is_loopback()));
            if table.add_hint(&hint, addrs) {
                tracing::debug!("mDNS: saw {hint} on the LAN");
            }
        }
    });
}

#[cfg(not(all(feature = "mdns", not(target_os = "ios"))))]
pub fn spawn_mdns(_me: PeerId, _port: u16, _table: Arc<LanTable>, _enabled: Arc<std::sync::atomic::AtomicBool>) {}

/// An IPv6 address whose interface id is derived from the hardware (MAC) address
/// (modified EUI-64: `xx:xxff:fexx:xxxx`): the same on every network — a tracking id.
pub fn is_eui64(v6: &std::net::Ipv6Addr) -> bool {
    let o = v6.octets();
    o[11] == 0xff && o[12] == 0xfe
}

/// Linux/Android: global IPv6 addresses flagged temporary (RFC 8981 privacy addresses).
fn temporary_v6() -> Vec<std::net::Ipv6Addr> {
    // Android: apps may not read /proc/net/if_inet6 (SELinux, API 29+: an audit
    // denial on every LAN announcement and no temporary addresses known), but
    // an RTM_GETADDR dump is allowed (bionic's getifaddrs uses it too).
    #[cfg(target_os = "android")]
    {
        temporary_v6_netlink().unwrap_or_default()
    }
    #[cfg(target_os = "linux")]
    {
        temporary_v6_proc()
    }
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    {
        vec![]
    }
}

/// /proc/net/if_inet6: addr idx prefixlen scope flags name; IFA_F_TEMPORARY = 0x01
#[cfg(any(target_os = "linux", test))]
fn temporary_v6_proc() -> Vec<std::net::Ipv6Addr> {
    let Ok(t) = std::fs::read_to_string("/proc/net/if_inet6") else { return vec![] };
    t.lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            let flags = u32::from_str_radix(f.get(4)?, 16).ok()?;
            let b = hex::decode(f.first()?).ok()?;
            let o: [u8; 16] = b.try_into().ok()?;
            (flags & 0x01 != 0).then(|| std::net::Ipv6Addr::from(o))
        })
        .collect()
}

/// The same list from the kernel over netlink: one `RTM_GETADDR` dump (AF_INET6),
/// keeping addresses whose flags (`IFA_FLAGS` when present, else `ifa_flags`)
/// carry `IFA_F_TEMPORARY`.
#[cfg(any(target_os = "android", all(target_os = "linux", test)))]
fn temporary_v6_netlink() -> std::io::Result<Vec<std::net::Ipv6Addr>> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    const NLMSG_HDR: usize = 16; // len u32, type u16, flags u16, seq u32, pid u32
    const IFADDRMSG: usize = 8; // family, prefixlen, flags, scope: u8; index: u32
    const IFA_ADDRESS: u16 = 1;
    const IFA_FLAGS: u16 = 8;
    const IFA_F_TEMPORARY: u32 = 0x01;
    let align = |n: usize| (n + 3) & !3;

    // SAFETY: plain socket(2); the fd is owned (closed) by `OwnedFd` right away.
    let fd = unsafe { libc::socket(libc::AF_NETLINK, libc::SOCK_RAW | libc::SOCK_CLOEXEC, libc::NETLINK_ROUTE) };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };
    let tv = libc::timeval { tv_sec: 1, tv_usec: 0 };
    // SAFETY: valid fd, pointer/size of a live timeval.
    unsafe {
        libc::setsockopt(fd.as_raw_fd(), libc::SOL_SOCKET, libc::SO_RCVTIMEO, (&tv as *const libc::timeval).cast(), std::mem::size_of::<libc::timeval>() as libc::socklen_t);
    }
    let seq: u32 = 0x4c4d_0001;
    let mut req = Vec::with_capacity(NLMSG_HDR + IFADDRMSG);
    req.extend_from_slice(&((NLMSG_HDR + IFADDRMSG) as u32).to_ne_bytes());
    req.extend_from_slice(&libc::RTM_GETADDR.to_ne_bytes());
    req.extend_from_slice(&((libc::NLM_F_REQUEST | libc::NLM_F_DUMP) as u16).to_ne_bytes());
    req.extend_from_slice(&seq.to_ne_bytes());
    req.extend_from_slice(&0u32.to_ne_bytes());
    req.extend_from_slice(&[libc::AF_INET6 as u8, 0, 0, 0, 0, 0, 0, 0]);
    // SAFETY: valid fd and buffer; the kernel is the default destination (no bind needed).
    if unsafe { libc::send(fd.as_raw_fd(), req.as_ptr().cast(), req.len(), 0) } < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let mut out = Vec::new();
    let mut buf = vec![0u8; 32 * 1024];
    loop {
        // SAFETY: valid fd, writable buffer of buf.len() bytes.
        let n = unsafe { libc::recv(fd.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len(), 0) };
        if n < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let msgs = &buf[..n as usize];
        if msgs.is_empty() {
            return Ok(out);
        }
        let mut off = 0;
        while off + NLMSG_HDR <= msgs.len() {
            let len = u32::from_ne_bytes(msgs[off..off + 4].try_into().unwrap()) as usize;
            let ty = u16::from_ne_bytes(msgs[off + 4..off + 6].try_into().unwrap());
            let mseq = u32::from_ne_bytes(msgs[off + 8..off + 12].try_into().unwrap());
            if len < NLMSG_HDR || off + len > msgs.len() {
                return Ok(out);
            }
            if mseq == seq {
                match ty as i32 {
                    libc::NLMSG_DONE => return Ok(out),
                    libc::NLMSG_ERROR => return Err(std::io::Error::other("netlink error")),
                    _ if ty == libc::RTM_NEWADDR && len >= NLMSG_HDR + IFADDRMSG => {
                        let body = &msgs[off + NLMSG_HDR..off + len];
                        let mut flags = body[2] as u32;
                        let mut addr = None;
                        let mut a = IFADDRMSG;
                        while a + 4 <= body.len() {
                            let rlen = u16::from_ne_bytes(body[a..a + 2].try_into().unwrap()) as usize;
                            let rty = u16::from_ne_bytes(body[a + 2..a + 4].try_into().unwrap());
                            if rlen < 4 || a + rlen > body.len() {
                                break;
                            }
                            let v = &body[a + 4..a + rlen];
                            if rty == IFA_ADDRESS && v.len() == 16 {
                                addr = Some(std::net::Ipv6Addr::from(<[u8; 16]>::try_from(v).unwrap()));
                            } else if rty == IFA_FLAGS && v.len() >= 4 {
                                flags = u32::from_ne_bytes(v[..4].try_into().unwrap());
                            }
                            a += align(rlen);
                        }
                        if let Some(ip) = addr.filter(|_| flags & IFA_F_TEMPORARY != 0) {
                            out.push(ip);
                        }
                    }
                    _ => {}
                }
            }
            off += align(len);
        }
    }
}

pub fn local_addrs(port: u16) -> Vec<SocketAddr> {
    let mut out = Vec::new();
    let temp = temporary_v6();
    if let Ok(ifs) = if_addrs::get_if_addrs() {
        for i in ifs {
            if i.is_loopback() {
                continue;
            }
            let ip = i.ip();
            if let IpAddr::V6(v6) = ip {
                if (v6.segments()[0] & 0xffc0) == 0xfe80 {
                    continue; // link-local needs scope ids; skip
                }
                // never hand out an address that embeds the hardware address
                if is_eui64(&v6) {
                    continue;
                }
            }
            // skip docker/virtual bridges commonly 172.17.x
            if i.name.starts_with("docker") || i.name.starts_with("br-") || i.name.starts_with("veth") {
                continue;
            }
            out.push(SocketAddr::new(ip, port));
        }
    }
    // prefer temporary (privacy) IPv6 addresses: when there are some, stable global ones
    // go last (only a few global IPv6 candidates are used)
    if !temp.is_empty() {
        out.sort_by_key(|a| match a.ip() {
            IpAddr::V6(v6) if crate::util::is_global_ip(&a.ip()) => !temp.contains(&v6),
            _ => false,
        });
        let mut stable_v6 = 0;
        out.retain(|a| match a.ip() {
            IpAddr::V6(v6) if crate::util::is_global_ip(&a.ip()) && !temp.contains(&v6) => {
                stable_v6 += 1;
                stable_v6 <= 1
            }
            _ => true,
        });
    }
    out
}

/// Announce ourselves on the LAN every few seconds and listen for others.
pub fn spawn_lan(me: PeerId, port: u16, table: Arc<LanTable>, enabled: Arc<std::sync::atomic::AtomicBool>) {
    tokio::spawn(async move {
        use socket2::{Domain, Protocol, Socket, Type};
        let open = || -> std::io::Result<tokio::net::UdpSocket> {
            let s = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
            s.set_reuse_address(true)?;
            #[cfg(unix)]
            let _ = s.set_reuse_port(true);
            s.bind(&SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, LAN_PORT)).into())?;
            s.join_multicast_v4(&LAN_GROUP, &Ipv4Addr::UNSPECIFIED)?;
            s.set_multicast_loop_v4(true)?;
            s.set_nonblocking(true)?;
            tokio::net::UdpSocket::from_std(s.into())
        };
        // The multicast join fails (ENODEV / ENETUNREACH) while there is no network, e.g. the
        // app starts during a Wi-Fi switch or before the laptop's Wi-Fi is up: keep retrying
        // instead of leaving LAN discovery (and linking by code) off until the next restart.
        let mut backoff = Duration::from_secs(1);
        let mut warned = false;
        let sock = loop {
            match open() {
                Ok(s) => {
                    if warned {
                        tracing::info!("LAN discovery enabled");
                    }
                    break s;
                }
                Err(e) => {
                    if !warned {
                        tracing::warn!("LAN discovery unavailable, retrying: {e}");
                        warned = true;
                    }
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(Duration::from_secs(30));
                }
            }
        };
        let mut tick = tokio::time::interval(Duration::from_secs(5));
        let mut buf = vec![0u8; 2048];
        let dest = SocketAddr::V4(SocketAddrV4::new(LAN_GROUP, LAN_PORT));
        // today's hint only (no public key in clear); never the legacy `LMRA` format
        let pkt_for = move || lan_hint_packet(&me, port, local_addrs(port));
        let mut last_reply = Instant::now() - Duration::from_secs(10);
        let link_pkt = |rv: [u8; 8]| {
            let b = LinkBeacon { v: 1, rv: rv.to_vec(), peer: me, port, addrs: lan_only(local_addrs(port)) };
            let mut pkt = b"LMRL".to_vec();
            pkt.extend(rmp_serde::to_vec_named(&b).unwrap_or_default());
            pkt
        };
        let mut link_tick = tokio::time::interval(Duration::from_secs(2));
        loop {
            tokio::select! {
                _ = tick.tick() => {
                    if !enabled.load(std::sync::atomic::Ordering::Relaxed) { continue }
                    let _ = sock.send_to(&pkt_for(), dest).await;
                }
                _ = link_tick.tick() => {
                    let rv = *table.link_beacon.read();
                    if let Some(rv) = rv {
                        let _ = sock.send_to(&link_pkt(rv), dest).await;
                    }
                }
                r = sock.recv_from(&mut buf) => {
                    let Ok((n, src)) = r else { continue };
                    if n >= 4 && &buf[..4] == b"LMRL" {
                        if let Ok(b) = crate::proto::from_slice_capped::<LinkBeacon>(&buf[4..n]) {
                            if b.peer != me && b.v == 1 {
                                table.add_link_beacon(b, src);
                            }
                        }
                        continue;
                    }
                    if n >= 4 && &buf[..4] == b"LMRH" {
                        let Ok(a) = crate::proto::from_slice_capped::<LanHintAnnounce>(&buf[4..n]) else { continue };
                        let d = lan_day();
                        if a.v != 1 || [d, d.saturating_sub(1), d + 1].iter().any(|day| lan_hint(&me, *day) == a.h) {
                            continue; // ourselves
                        }
                        let mut addrs = vec![SocketAddr::new(src.ip(), a.port)];
                        for x in lan_only(a.addrs) { if !addrs.contains(&x) { addrs.push(x) } }
                        let is_new = !table.hints.read().contains_key(&a.h);
                        if table.add_hint(&a.h, addrs) && is_new && last_reply.elapsed() > Duration::from_millis(300) && enabled.load(std::sync::atomic::Ordering::Relaxed) {
                            last_reply = Instant::now();
                            let _ = sock.send_to(&pkt_for(), dest).await;
                        }
                        continue;
                    }
                    // legacy announcement (older builds): still understood
                    if n < 4 || &buf[..4] != b"LMRA" { continue }
                    let Ok(a) = crate::proto::from_slice_capped::<LanAnnounce>(&buf[4..n]) else { continue };
                    if a.peer == me || a.v != 1 { continue }
                    // Prefer the observed source IP; fall back to announced addresses.
                    let mut addrs = vec![SocketAddr::new(src.ip(), a.port)];
                    for x in a.addrs.into_iter().take(8) { if !addrs.contains(&x) { addrs.push(x) } }
                    let is_new = {
                        let mut t = table.peers.write();
                        if t.len() > 256 {
                            t.retain(|_, (_, at)| at.elapsed() < Duration::from_secs(60));
                        }
                        t.len() < 512 && t.insert(a.peer, (addrs, Instant::now())).is_none()
                    };
                    // A newcomer: answer immediately so discovery takes milliseconds, not one interval.
                    if is_new && last_reply.elapsed() > Duration::from_millis(300) && enabled.load(std::sync::atomic::Ordering::Relaxed) {
                        last_reply = Instant::now();
                        let _ = sock.send_to(&pkt_for(), dest).await;
                    }
                }
            }
        }
    });
}

/// Try UPnP-IGD. Returns the external address mapped to our UDP port.
pub async fn upnp_map(port: u16) -> Option<SocketAddr> {
    use igd_next::{aio::tokio::search_gateway, PortMappingProtocol, SearchOptions};
    let mut opts = SearchOptions::default();
    opts.timeout = Some(Duration::from_secs(3));
    let gw = search_gateway(opts).await.ok()?;
    let gw_ip = gw.addr.ip();
    // Find our LAN address that routes to the gateway.
    let probe = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    probe.connect(SocketAddr::new(gw_ip, 1900)).ok()?;
    let local_ip = probe.local_addr().ok()?.ip();
    let local = SocketAddr::new(local_ip, port);
    let ext_ip = gw.get_external_ip().await.ok()?;
    let mut ext_port = port;
    for attempt in 0..3 {
        match gw.add_port(PortMappingProtocol::UDP, ext_port, local, 3600, "Lumora P2P").await {
            Ok(()) => return Some(SocketAddr::new(ext_ip, ext_port)),
            Err(_) if attempt < 2 => ext_port = 20000 + (rand::random::<u16>() % 40000),
            Err(e) => {
                tracing::debug!("upnp add_port failed: {e}");
            }
        }
    }
    None
}

// ---------------- Mainline DHT ----------------

#[derive(Serialize, Deserialize, Default, Clone, Debug)]
pub struct DhtRecord {
    pub addrs: Vec<SocketAddr>,
    pub relays: Vec<String>,
    pub ts: u64,
}

/// An account's devices on the DHT (multi-device, main device only, ≥ 2 devices): a hint
/// for reaching its other devices when no signed list is cached. Stored under a key only
/// friends can compute (see [`friend_signing_key`]); each device still proves itself with
/// its TLS certificate.
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub struct DhtDevices {
    pub version: u64,
    pub devices: Vec<(PeerId, u8)>,
}

fn dht_devices_key(p: &PeerId) -> [u8; 32] {
    blake3::derive_key("lumora dht devices v1", &p.0)
}

const DEVICES_SALT: &[u8] = b"lumora-devs2";
const FRIEND_SALT: &[u8] = b"lumora-f2";

fn friend_record(info: &ConnInfo) -> DhtRecord {
    DhtRecord {
        addrs: info.addrs.iter().copied().filter(|a| crate::util::is_global_ip(&a.ip())).take(6).collect(),
        relays: info.relays.iter().filter(|r| !r.starts_with("peer:")).take(4).cloned().collect(),
        ts: crate::util::now_ms(),
    }
}

fn friend_record_key(p: &PeerId, key: &[u8; 32]) -> [u8; 32] {
    let mut m = key.to_vec();
    m.extend_from_slice(&p.0);
    blake3::derive_key("lumora dht friend record v1", &m)
}

/// The DHT signing key of the friends-only records, derived from the device's random
/// friends-only key (`Ext DHT_KEY`, rotated when a friend leaves) — never the identity
/// key. Its public half (the DHT target) can't be computed from the public ID, so DHT
/// nodes can't link "this IP stores records" to a Lumora ID; only friends can find it.
pub fn friend_signing_key(key: &[u8; 32]) -> mainline::SigningKey {
    mainline::SigningKey::from_bytes(&blake3::derive_key("lumora dht friend signing v1", key))
}

fn seal_friend_record(p: &PeerId, key: &[u8; 32], rec: &DhtRecord) -> anyhow::Result<Vec<u8>> {
    let ct = crate::crypto::aead_encrypt(&friend_record_key(p, key), &rmp_serde::to_vec(rec)?, b"dht-f1");
    anyhow::ensure!(ct.len() <= 1000, "dht friend record too large");
    Ok(ct)
}

fn open_friend_record(p: &PeerId, key: &[u8; 32], ct: &[u8]) -> Option<DhtRecord> {
    let plain = crate::crypto::aead_decrypt(&friend_record_key(p, key), ct, b"dht-f1").ok()?;
    crate::proto::from_slice_capped(&plain).ok()
}

pub struct Dht {
    dht: mainline::async_dht::AsyncDht,
}

impl Dht {
    pub fn start() -> anyhow::Result<Self> {
        let d = mainline::Dht::client()?;
        Ok(Dht { dht: d.as_async() })
    }

    // (There is no public record any more: it held nothing but relay hints, and storing it
    // under the identity key told DHT nodes which IP runs that ID.)

    /// The friends-only record: addresses (global ones) and public relays, encrypted with
    /// `key` and stored under [`friend_signing_key`]`(key)` (random, given only to friends
    /// and own devices, rotated on unfriending).
    pub async fn publish_friend(&self, me: &PeerId, info: &ConnInfo, key: &[u8; 32]) -> anyhow::Result<()> {
        let ct = seal_friend_record(me, key, &friend_record(info))?;
        let seq = (crate::util::now_ms() / 1000) as i64;
        let item = mainline::MutableItem::new(friend_signing_key(key), &ct, seq, Some(FRIEND_SALT));
        self.dht.put_mutable(item, None).await.map_err(|e| anyhow::anyhow!("{e:?}"))?;
        Ok(())
    }

    pub async fn lookup_friend(&self, p: &PeerId, key: &[u8; 32]) -> Option<DhtRecord> {
        let target = friend_signing_key(key).verifying_key().to_bytes();
        let item = tokio::time::timeout(Duration::from_secs(12), self.dht.get_mutable_most_recent(&target, Some(FRIEND_SALT)))
            .await
            .ok()??;
        open_friend_record(p, key, item.value())
    }

    /// The account's devices, under the main device's friends-only key (`key`).
    pub async fn publish_devices(&self, account: &PeerId, rec: &DhtDevices, key: &[u8; 32]) -> anyhow::Result<()> {
        let plain = rmp_serde::to_vec(rec)?;
        let ct = crate::crypto::aead_encrypt(&dht_devices_key(account), &plain, b"dht-devs");
        anyhow::ensure!(ct.len() <= 1000, "dht device record too large");
        let seq = (crate::util::now_ms() / 1000) as i64;
        let item = mainline::MutableItem::new(friend_signing_key(key), &ct, seq, Some(DEVICES_SALT));
        self.dht.put_mutable(item, None).await.map_err(|e| anyhow::anyhow!("{e:?}"))?;
        Ok(())
    }

    pub async fn lookup_devices(&self, account: &PeerId, key: &[u8; 32]) -> Option<DhtDevices> {
        let target = friend_signing_key(key).verifying_key().to_bytes();
        let item = tokio::time::timeout(Duration::from_secs(12), self.dht.get_mutable_most_recent(&target, Some(DEVICES_SALT)))
            .await
            .ok()??;
        let plain = crate::crypto::aead_decrypt(&dht_devices_key(account), item.value(), b"dht-devs").ok()?;
        crate::proto::from_slice_capped(&plain).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dht_device_record_fits_for_eight_devices() {
        let rec = DhtDevices { version: u64::MAX, devices: (0..8u8).map(|i| (PeerId([i; 32]), 0xff)).collect() };
        let plain = rmp_serde::to_vec(&rec).unwrap();
        let ct = crate::crypto::aead_encrypt(&dht_devices_key(&PeerId([1; 32])), &plain, b"dht-devs");
        assert!(ct.len() <= 1000, "{} bytes", ct.len());
        let back: DhtDevices = crate::proto::from_slice_capped(&crate::crypto::aead_decrypt(&dht_devices_key(&PeerId([1; 32])), &ct, b"dht-devs").unwrap()).unwrap();
        assert_eq!(back, rec);
        // only who knows the account can read it
        assert!(crate::crypto::aead_decrypt(&dht_devices_key(&PeerId([2; 32])), &ct, b"dht-devs").is_err());
    }

    #[test]
    fn lan_hint_is_daily_short_and_not_the_key() {
        let p = PeerId([7; 32]);
        let h = lan_hint(&p, 20_000);
        assert_eq!(h.len(), 16);
        assert_ne!(h, lan_hint(&p, 20_001), "rotates daily");
        assert_ne!(h, lan_hint(&PeerId([8; 32]), 20_000));
        assert!(!hex::encode(p.0).contains(&h));
    }

    #[test]
    fn mdns_sightings_resolve_only_for_known_peers() {
        let t = LanTable::default();
        let p = PeerId([9; 32]);
        let a: SocketAddr = "192.168.1.20:4433".parse().unwrap();
        assert!(t.get(&p).is_empty());
        assert!(!t.add_hint("not-hex!", vec![a]));
        assert!(!t.add_hint(&lan_hint(&p, lan_day()), vec![]));
        assert!(t.add_hint(&lan_hint(&p, lan_day()).to_uppercase(), vec![a]));
        assert_eq!(t.get(&p), vec![a]);
        // yesterday's advertisement still matches (clock skew around midnight)
        let q = PeerId([10; 32]);
        let b: SocketAddr = "[fd00::5]:4433".parse().unwrap();
        assert!(t.add_hint(&lan_hint(&q, lan_day() - 1), vec![b]));
        assert_eq!(t.get(&q), vec![b]);
        assert!(t.get(&PeerId([11; 32])).is_empty());
    }
}

#[cfg(test)]
mod privacy_tests {
    use super::*;

    fn info() -> ConnInfo {
        ConnInfo {
            addrs: vec!["1.2.3.4:4433".parse().unwrap(), "192.168.1.5:4433".parse().unwrap(), "[2001:db8::1234]:4433".parse().unwrap()],
            relays: vec!["wss://relay.example/ws".into(), format!("peer:{}", PeerId([3; 32]).to_base32())],
            ..Default::default()
        }
    }

    /// P2: there is no public DHT record any more; the friends-only record needs the key
    /// only friends get — to read it AND to find it (#5: its DHT target is derived from that
    /// key, not from the public ID, so DHT nodes can't map "ID → IP").
    #[test]
    fn friend_dht_record_is_unlinkable_to_the_id() {
        let me = PeerId([1; 32]);
        let key = [9u8; 32];
        let ct = seal_friend_record(&me, &key, &friend_record(&info())).unwrap();
        let back = open_friend_record(&me, &key, &ct).unwrap();
        assert_eq!(back.addrs, vec!["1.2.3.4:4433".parse::<SocketAddr>().unwrap(), "[2001:db8::1234]:4433".parse().unwrap()]);
        assert!(back.relays.iter().all(|r| !r.starts_with("peer:")));
        // another key opens nothing
        assert!(open_friend_record(&me, &[8u8; 32], &ct).is_none());
        // the DHT target: not the ID, different per key
        let t = friend_signing_key(&key).verifying_key().to_bytes();
        assert_ne!(t, me.0);
        assert_ne!(t, friend_signing_key(&[8u8; 32]).verifying_key().to_bytes());
        let id = crate::identity::Identity::generate();
        assert_ne!(friend_signing_key(&key).verifying_key().to_bytes(), id.peer_id().0);
    }

    /// P14: the LAN announcement doesn't carry the public key; P19: no EUI-64 addresses.
    #[test]
    fn lan_announcement_hides_the_key_and_public_addresses() {
        let me = PeerId([0x5a; 32]);
        let pkt = lan_hint_packet(&me, 4433, info().addrs);
        assert_eq!(&pkt[..4], b"LMRH");
        assert!(!pkt.windows(32).any(|w| w == me.0), "public key in the LAN packet");
        let a: LanHintAnnounce = crate::proto::from_slice_capped(&pkt[4..]).unwrap();
        assert_eq!(a.h, lan_hint(&me, lan_day()));
        assert_eq!(a.addrs, vec!["192.168.1.5:4433".parse::<SocketAddr>().unwrap()], "only LAN addresses");
        // a known peer recognises it; the table resolves it only by key
        let t = LanTable::default();
        assert!(t.add_hint(&a.h, vec!["192.168.1.5:4433".parse().unwrap()]));
        assert_eq!(t.get(&me).len(), 1);
        assert!(is_eui64(&"2001:db8::21a:2bff:fe3c:4d5e".parse().unwrap()));
        assert!(!is_eui64(&"2001:db8::9c1f:62e1:aa31:7b02".parse().unwrap()));
        assert!(local_addrs(1).iter().all(|a| !matches!(a.ip(), IpAddr::V6(v6) if is_eui64(&v6))));
    }

    /// The netlink reader (used on Android, where /proc/net/if_inet6 is off limits)
    /// finds exactly the temporary IPv6 addresses /proc lists.
    #[cfg(target_os = "linux")]
    #[test]
    fn temporary_v6_netlink_matches_proc() {
        let mut nl = temporary_v6_netlink().expect("RTM_GETADDR dump");
        let mut pr = temporary_v6_proc();
        nl.sort();
        pr.sort();
        assert_eq!(nl, pr);
    }
}
