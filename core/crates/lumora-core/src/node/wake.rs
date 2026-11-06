//! Wake-on-LAN ("Đánh thức máy") for remote-desktop devices.
//!
//! The host shares the hardware addresses of its active, physical network cards with viewers
//! it accepted (`RemoteHostInfo`); the viewer keeps them with the "recent device" entry and can
//! later broadcast a magic packet on its own networks, or ask friends' devices that are online
//! to do the same on theirs (`WakeRequest`, friends only, rate limited).

use super::*;
use std::net::{Ipv4Addr, SocketAddrV4, UdpSocket};

pub type Mac = [u8; 6];

const WAKE_PORT: u16 = 9;
const MAX_MACS: usize = 8;
/// One wake request per friend per this long, and at most `GLOBAL_PER_MIN` overall.
const PER_FRIEND: Duration = Duration::from_secs(20);
const GLOBAL_PER_MIN: usize = 20;
const MAX_HELPERS: usize = 6;

pub fn fmt_mac(m: &Mac) -> String {
    m.iter().map(|b| format!("{b:02x}")).collect::<Vec<_>>().join(":")
}

pub fn parse_mac(s: &str) -> Option<Mac> {
    let hex: String = s.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    let v = hex::decode(hex).ok()?;
    let m: Mac = v.try_into().ok()?;
    usable(&m).then_some(m)
}

/// Not all-zero, not broadcast/multicast.
fn usable(m: &Mac) -> bool {
    *m != [0; 6] && m[0] & 1 == 0
}

/// 6 × 0xFF followed by the address repeated 16 times.
pub fn magic_packet(mac: &Mac) -> [u8; 102] {
    let mut p = [0xFFu8; 102];
    for i in 0..16 {
        p[6 + i * 6..12 + i * 6].copy_from_slice(mac);
    }
    p
}

/// Broadcast magic packets for `macs` on every local IPv4 network (plus 255.255.255.255).
/// Returns how many packets went out.
pub fn send_magic(macs: &[Mac]) -> usize {
    let mut targets: Vec<(Option<Ipv4Addr>, Ipv4Addr)> = vec![(None, Ipv4Addr::BROADCAST)];
    for i in if_addrs::get_if_addrs().unwrap_or_default() {
        if i.is_loopback() || i.is_p2p() || !i.is_oper_up() && i.oper_status != if_addrs::IfOperStatus::Unknown {
            continue;
        }
        if let if_addrs::IfAddr::V4(a) = &i.addr {
            if a.ip.is_link_local() {
                continue;
            }
            let bcast = a.broadcast.unwrap_or_else(|| Ipv4Addr::from(u32::from(a.ip) | !u32::from(a.netmask)));
            if bcast != a.ip && !targets.contains(&(Some(a.ip), bcast)) {
                targets.push((Some(a.ip), bcast));
            }
        }
    }
    let mut sent = 0;
    for (src, dst) in targets {
        // bind to the interface address so the broadcast leaves through that network card
        let bind = SocketAddrV4::new(src.unwrap_or(Ipv4Addr::UNSPECIFIED), 0);
        let Ok(sock) = UdpSocket::bind(bind) else { continue };
        if sock.set_broadcast(true).is_err() {
            continue;
        }
        for m in macs {
            if sock.send_to(&magic_packet(m), SocketAddrV4::new(dst, WAKE_PORT)).is_ok() {
                sent += 1;
            }
        }
    }
    sent
}

/// Hardware addresses of this computer's active, physical network cards (wired first).
pub fn local_macs() -> Vec<Mac> {
    let mut v = platform_macs();
    v.dedup();
    v.truncate(MAX_MACS);
    v
}

#[cfg(target_os = "linux")]
fn platform_macs() -> Vec<Mac> {
    let mut wired = vec![];
    let mut wireless = vec![];
    let Ok(dir) = std::fs::read_dir("/sys/class/net") else { return vec![] };
    for e in dir.flatten() {
        let p = e.path();
        // virtual interfaces (lo, docker, bridges, veth, VPN tunnels) have no backing device
        if !p.join("device").exists() {
            continue;
        }
        let up = std::fs::read_to_string(p.join("operstate")).map(|s| s.trim() == "up").unwrap_or(false);
        if !up {
            continue;
        }
        let Some(mac) = std::fs::read_to_string(p.join("address")).ok().and_then(|s| parse_mac(s.trim())) else { continue };
        if p.join("wireless").exists() || p.join("phy80211").exists() {
            wireless.push(mac);
        } else {
            wired.push(mac);
        }
    }
    wired.sort();
    wireless.sort();
    wired.extend(wireless);
    wired
}

#[cfg(target_os = "macos")]
fn platform_macs() -> Vec<Mac> {
    // `ifconfig`: blocks per interface; keep en* with "status: active" and an ether line
    let Ok(out) = std::process::Command::new("/sbin/ifconfig").output() else { return vec![] };
    let text = String::from_utf8_lossy(&out.stdout);
    let mut res = vec![];
    let (mut name, mut mac, mut active) = (String::new(), None, false);
    let mut flush = |name: &str, mac: Option<Mac>, active: bool, res: &mut Vec<Mac>| {
        if name.starts_with("en") && active {
            if let Some(m) = mac {
                res.push(m);
            }
        }
    };
    for line in text.lines() {
        if !line.starts_with(['\t', ' ']) {
            flush(&name, mac, active, &mut res);
            name = line.split(':').next().unwrap_or("").to_string();
            mac = None;
            active = false;
        } else if let Some(m) = line.trim().strip_prefix("ether ") {
            mac = parse_mac(m.trim());
        } else if line.trim() == "status: active" {
            active = true;
        }
    }
    flush(&name, mac, active, &mut res);
    res
}

#[cfg(windows)]
fn platform_macs() -> Vec<Mac> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let out = std::process::Command::new("powershell")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Sort-Object MediaType | ForEach-Object MacAddress",
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
    let Ok(out) = out else { return vec![] };
    String::from_utf8_lossy(&out.stdout).lines().filter_map(|l| parse_mac(l.trim())).collect()
}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
fn platform_macs() -> Vec<Mac> {
    vec![] // phones/tablets can't be woken over the network
}

static MAC_CACHE: Mutex<Option<(Instant, Vec<Mac>)>> = parking_lot::const_mutex(None);

/// Cached [`local_macs`] (refreshed every 10 minutes; may block on first use).
pub fn local_macs_cached() -> Vec<Mac> {
    if let Some((t, v)) = MAC_CACHE.lock().as_ref() {
        if t.elapsed() < Duration::from_secs(600) {
            return v.clone();
        }
    }
    let v = local_macs();
    *MAC_CACHE.lock() = Some((Instant::now(), v.clone()));
    v
}

/// Non-blocking peek at the cache (refreshes in the background when stale).
pub fn local_macs_peek() -> Vec<Mac> {
    let cur = MAC_CACHE.lock().clone();
    match cur {
        Some((t, v)) if t.elapsed() < Duration::from_secs(600) => v,
        other => {
            std::thread::spawn(local_macs_cached);
            other.map(|(_, v)| v).unwrap_or_default()
        }
    }
}

/// (last request per friend, all requests in the last minute)
type WakeLimits = (HashMap<PeerId, Instant>, Vec<Instant>);
static WAKE_LIMITS: Mutex<Option<WakeLimits>> = parking_lot::const_mutex(None);

fn wake_allowed(from: &PeerId) -> bool {
    let mut g = WAKE_LIMITS.lock();
    let (per, all) = g.get_or_insert_with(Default::default);
    let now = Instant::now();
    per.retain(|_, t| now.duration_since(*t) < PER_FRIEND);
    all.retain(|t| now.duration_since(*t) < Duration::from_secs(60));
    if per.contains_key(from) || all.len() >= GLOBAL_PER_MIN {
        return false;
    }
    per.insert(*from, now);
    all.push(now);
    true
}

impl Node {
    /// Host side: after accepting a viewer, tell it how to wake this computer later.
    pub(super) fn share_wake_info(self: &Arc<Self>, session: [u8; 16], viewer: PeerId) {
        if !self.peer_speaks_v2(&viewer) {
            return;
        }
        let me = self.clone();
        tokio::spawn(async move {
            let macs = tokio::task::spawn_blocking(local_macs_cached).await.unwrap_or_default();
            if !macs.is_empty() {
                me.send_now_dev(&viewer, PeerMsg::RemoteHostInfo { session, macs });
            }
        });
    }

    /// Viewer side: store the host's wake info with its "recent device" entry.
    pub(super) fn on_remote_host_info(&self, from: PeerId, macs: Vec<Mac>) {
        let macs: Vec<String> = macs.iter().filter(|m| usable(m)).take(MAX_MACS).map(fmt_mac).collect();
        if macs.is_empty() {
            return;
        }
        let mut list: Vec<Value> = self.store.kv_get_json("remote.recent").unwrap_or_default();
        let me = from.to_base32();
        if let Some(e) = list.iter_mut().find(|x| x["peer"].as_str() == Some(me.as_str())) {
            e["macs"] = json!(macs);
            let _ = self.store.kv_set_json("remote.recent", &list);
        }
    }

    /// "Đánh thức máy": wake a recent remote device (`id`: its peer id or 9-digit ID).
    pub async fn remote_wake(self: &Arc<Self>, id: &str) -> Result<Value> {
        let list: Vec<Value> = self.store.kv_get_json("remote.recent").unwrap_or_default();
        let digits: String = id.chars().filter(|c| c.is_ascii_digit()).collect();
        let entry = list
            .iter()
            .find(|x| x["peer"].as_str() == Some(id.trim()) || (!digits.is_empty() && x["short_id"].as_str().map(|s| s.replace(' ', "")) == Some(digits.clone())))
            .cloned();
        let macs: Vec<Mac> = entry
            .as_ref()
            .and_then(|e| e["macs"].as_array().cloned())
            .unwrap_or_default()
            .iter()
            .filter_map(|m| m.as_str().and_then(parse_mac))
            .take(MAX_MACS)
            .collect();
        anyhow::ensure!(!macs.is_empty(), crate::i18n::user_err("err.wake_no_info"));
        let target = entry.as_ref().and_then(|e| e["peer"].as_str()).and_then(|p| PeerId::from_str_any(p).ok());
        let m2 = macs.clone();
        let sent = tokio::task::spawn_blocking(move || send_magic(&m2)).await.unwrap_or(0);
        // friends' devices online right now may sit on the same network as the computer
        let helpers: Vec<PeerId> = self
            .connected_peers()
            .into_iter()
            .filter(|pc| Some(pc.peer) != target && Some(pc.account) != target && self.store.is_friend(&pc.account) && self.peer_speaks_v2(&pc.peer))
            .map(|pc| pc.peer)
            .take(MAX_HELPERS)
            .collect();
        for h in &helpers {
            self.send_now_dev(h, PeerMsg::WakeRequest { macs: macs.clone() });
        }
        anyhow::ensure!(sent > 0 || !helpers.is_empty(), crate::i18n::user_err("err.wake_failed"));
        Ok(json!({"sent": sent, "helpers": helpers.len()}))
    }

    /// A friend asks us to send a wake-up packet on our network (optional, on by default).
    pub(super) fn on_wake_request(&self, from: PeerId, macs: Vec<Mac>) {
        let enabled = self.store.kv_get("remote.wake_for_friends").map(|v| v != b"0").unwrap_or(true);
        if !enabled || !self.store.is_friend(&from) || !wake_allowed(&from) {
            return;
        }
        let macs: Vec<Mac> = macs.into_iter().filter(usable).take(MAX_MACS).collect();
        if !macs.is_empty() {
            std::thread::spawn(move || {
                let n = send_magic(&macs);
                tracing::debug!("wake request from {from:?}: sent {n} packets");
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn magic_packet_layout() {
        let m = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55];
        let p = magic_packet(&m);
        assert_eq!(&p[..6], &[0xFF; 6]);
        for i in 0..16 {
            assert_eq!(&p[6 + i * 6..12 + i * 6], &m);
        }
    }

    #[test]
    fn mac_parse_and_format() {
        let m = parse_mac("AA-BB-CC-DD-EE-0F").unwrap();
        assert_eq!(fmt_mac(&m), "aa:bb:cc:dd:ee:0f");
        assert_eq!(parse_mac("aa:bb:cc:dd:ee:0f"), Some(m));
        assert!(parse_mac("00:00:00:00:00:00").is_none());
        assert!(parse_mac("ff:ff:ff:ff:ff:ff").is_none());
        assert!(parse_mac("aa:bb").is_none());
    }

    #[test]
    fn local_macs_and_send_do_not_fail() {
        let macs = local_macs();
        assert!(macs.iter().all(usable));
        // a packet for a made-up card: harmless; must not panic even without networks
        let _ = send_magic(&[[0x02, 0, 0, 0, 0, 1]]);
    }

    #[test]
    fn wake_rate_limit() {
        let p = PeerId([7; 32]);
        assert!(wake_allowed(&p));
        assert!(!wake_allowed(&p));
    }
}
