use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Hybrid logical clock: monotonic, close to wall time, totally ordered with author id.
pub struct Hlc {
    last: AtomicU64,
}

impl Default for Hlc {
    fn default() -> Self {
        Self::new()
    }
}

impl Hlc {
    pub const fn new() -> Self {
        Hlc { last: AtomicU64::new(0) }
    }
    /// Value is milliseconds << 8 | counter.
    pub fn tick(&self) -> u64 {
        let wall = now_ms() << 8;
        let mut cur = self.last.load(Ordering::SeqCst);
        loop {
            let next = if wall > cur { wall } else { cur + 1 };
            match self.last.compare_exchange(cur, next, Ordering::SeqCst, Ordering::SeqCst) {
                Ok(_) => return next,
                Err(c) => cur = c,
            }
        }
    }
    /// Merge a remote timestamp so our next tick is after it. Remote clocks are untrusted
    /// (a stranger's DM, any member's content): we only follow them up to
    /// [`MAX_CLOCK_SKEW_MS`] ahead of our wall clock, so nobody can drag our clock so far
    /// ahead that every op we sign is rejected by the receivers' future bound
    /// ([`MAX_FUTURE_OP_MS`]). The sender's own value is still stored for ordering.
    pub fn observe(&self, remote: u64) {
        self.last.fetch_max(remote.min(clamp_hlc_now()), Ordering::SeqCst);
    }
}

/// How far ahead of our wall clock a remote clock may move ours (and how far ahead a
/// received timestamp is trusted for local purposes: chat list order, read positions).
pub const MAX_CLOCK_SKEW_MS: u64 = 2 * 60_000;
/// Group ops dated further ahead than this are rejected by every member — and refused when
/// we publish (`MAX_CLOCK_SKEW_MS` keeps our own clock well inside it).
pub const MAX_FUTURE_OP_MS: u64 = 10 * 60_000;
const _: () = assert!(MAX_CLOCK_SKEW_MS < MAX_FUTURE_OP_MS);

/// The latest hlc we accept as "now" for local purposes (wall clock + allowed skew).
pub fn clamp_hlc_now() -> u64 {
    (now_ms() + MAX_CLOCK_SKEW_MS) << 8
}

/// A received hlc, clamped for local clock purposes (sorting the chat list, read marks).
pub fn clamp_hlc(h: u64) -> u64 {
    h.min(clamp_hlc_now())
}

pub fn hlc_to_ms(h: u64) -> u64 {
    h >> 8
}

/// Normalise IPv4-mapped IPv6 addresses back to IPv4.
pub fn canon(addr: SocketAddr) -> SocketAddr {
    match addr {
        SocketAddr::V6(v6) => match v6.ip().to_ipv4_mapped() {
            Some(v4) => SocketAddr::new(IpAddr::V4(v4), v6.port()),
            None => addr,
        },
        a => a,
    }
}

pub fn is_global_ip(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            !(v4.is_private()
                || v4.is_loopback()
                || v4.is_link_local()
                || v4.is_unspecified()
                || v4.is_broadcast()
                || v4.is_documentation()
                || (v4.octets()[0] == 100 && (v4.octets()[1] & 0xC0) == 64))
        }
        IpAddr::V6(v6) => {
            let s = v6.segments();
            (s[0] & 0xE000) == 0x2000 // 2000::/3 global unicast
        }
    }
}

pub fn is_cgnat(ip: &IpAddr) -> bool {
    matches!(ip, IpAddr::V4(v4) if v4.octets()[0] == 100 && (v4.octets()[1] & 0xC0) == 64)
}

pub fn human_bytes(n: u64) -> String {
    const U: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1024.0 && i < 4 {
        v /= 1024.0;
        i += 1;
    }
    format!("{:.1} {}", v, U[i])
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn hlc_monotonic() {
        let h = Hlc::new();
        let a = h.tick();
        let b = h.tick();
        assert!(b > a);
        h.observe(b + 1000);
        assert!(h.tick() > b + 1000);
    }
    /// A remote clock a day ahead (a stranger's DM) moves ours by at most the allowed skew.
    #[test]
    fn hlc_observe_is_bounded() {
        let h = Hlc::new();
        h.observe((now_ms() + 86_400_000) << 8);
        let t = hlc_to_ms(h.tick());
        assert!(t <= now_ms() + MAX_CLOCK_SKEW_MS + 1, "clock dragged {} ms ahead", t - now_ms());
        assert_eq!(clamp_hlc(5), 5);
        assert!(clamp_hlc(u64::MAX) <= clamp_hlc_now());
    }
    #[test]
    fn ip_classes() {
        assert!(!is_global_ip(&"192.168.1.2".parse().unwrap()));
        assert!(!is_global_ip(&"100.64.1.1".parse().unwrap()));
        assert!(is_global_ip(&"8.8.8.8".parse().unwrap()));
        assert!(is_global_ip(&"2001:4860::1".parse().unwrap()));
        assert!(!is_global_ip(&"fe80::1".parse().unwrap()));
    }
}

/// "2026-11-05 14:30 UTC" (no timezone database needed; used for plain-text fallbacks).
pub fn fmt_utc_time(ms: u64) -> String {
    let secs = ms / 1000;
    let (days, rem) = ((secs / 86_400) as i64, secs % 86_400);
    // civil-from-days (Howard Hinnant)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{y:04}-{m:02}-{d:02} {:02}:{:02} UTC", rem / 3600, rem % 3600 / 60)
}

#[cfg(test)]
mod fmt_tests {
    #[test]
    fn utc_time() {
        assert_eq!(super::fmt_utc_time(0), "1970-01-01 00:00 UTC");
        assert_eq!(super::fmt_utc_time(1_772_461_800_000), "2026-03-02 14:30 UTC");
    }
}
