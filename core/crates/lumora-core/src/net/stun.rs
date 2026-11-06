//! Minimal RFC 5389 STUN: binding request/response with XOR-MAPPED-ADDRESS.
//! Every Lumora node also *answers* binding requests on its main port, so peers can
//! learn their public address from each other even if all public STUN servers vanish.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

pub const MAGIC: u32 = 0x2112_A442;
const BINDING_REQUEST: u16 = 0x0001;
const BINDING_SUCCESS: u16 = 0x0101;
const ATTR_XOR_MAPPED: u16 = 0x0020;
const ATTR_MAPPED: u16 = 0x0001;

/// Public STUN servers operated by large companies; long-lived and free.
pub const DEFAULT_STUN: &[&str] = &[
    "stun.l.google.com:19302",
    "stun1.l.google.com:19302",
    "stun.cloudflare.com:3478",
    "stun2.l.google.com:19302",
    "stun.nextcloud.com:443",
];

pub fn is_stun(d: &[u8]) -> bool {
    d.len() >= 20 && (d[0] & 0xC0) == 0 && u32::from_be_bytes([d[4], d[5], d[6], d[7]]) == MAGIC
}

pub fn binding_request(txid: &[u8; 12]) -> Vec<u8> {
    let mut v = Vec::with_capacity(20);
    v.extend_from_slice(&BINDING_REQUEST.to_be_bytes());
    v.extend_from_slice(&0u16.to_be_bytes());
    v.extend_from_slice(&MAGIC.to_be_bytes());
    v.extend_from_slice(txid);
    v
}

pub fn is_binding_request(d: &[u8]) -> Option<[u8; 12]> {
    if is_stun(d) && u16::from_be_bytes([d[0], d[1]]) == BINDING_REQUEST {
        Some(d[8..20].try_into().unwrap())
    } else {
        None
    }
}

pub fn binding_response(txid: &[u8; 12], addr: SocketAddr) -> Vec<u8> {
    let addr = crate::util::canon(addr);
    let mut attr = Vec::new();
    let port = addr.port() ^ (MAGIC >> 16) as u16;
    match addr.ip() {
        IpAddr::V4(ip) => {
            attr.extend_from_slice(&[0, 1]);
            attr.extend_from_slice(&port.to_be_bytes());
            let x = u32::from(ip) ^ MAGIC;
            attr.extend_from_slice(&x.to_be_bytes());
        }
        IpAddr::V6(ip) => {
            attr.extend_from_slice(&[0, 2]);
            attr.extend_from_slice(&port.to_be_bytes());
            let mut key = [0u8; 16];
            key[..4].copy_from_slice(&MAGIC.to_be_bytes());
            key[4..].copy_from_slice(txid);
            let o = ip.octets();
            for i in 0..16 {
                attr.push(o[i] ^ key[i]);
            }
        }
    }
    let mut v = Vec::new();
    v.extend_from_slice(&BINDING_SUCCESS.to_be_bytes());
    v.extend_from_slice(&((4 + attr.len()) as u16).to_be_bytes());
    v.extend_from_slice(&MAGIC.to_be_bytes());
    v.extend_from_slice(txid);
    v.extend_from_slice(&ATTR_XOR_MAPPED.to_be_bytes());
    v.extend_from_slice(&(attr.len() as u16).to_be_bytes());
    v.extend_from_slice(&attr);
    v
}

/// Parse a binding success response → (transaction id, mapped address).
pub fn parse_response(d: &[u8]) -> Option<([u8; 12], SocketAddr)> {
    if !is_stun(d) || u16::from_be_bytes([d[0], d[1]]) != BINDING_SUCCESS {
        return None;
    }
    let txid: [u8; 12] = d[8..20].try_into().ok()?;
    let len = u16::from_be_bytes([d[2], d[3]]) as usize;
    let body = d.get(20..20 + len)?;
    let mut i = 0;
    let mut fallback = None;
    while i + 4 <= body.len() {
        let t = u16::from_be_bytes([body[i], body[i + 1]]);
        let l = u16::from_be_bytes([body[i + 2], body[i + 3]]) as usize;
        let v = body.get(i + 4..i + 4 + l)?;
        if (t == ATTR_XOR_MAPPED || t == ATTR_MAPPED) && v.len() >= 8 {
            let xor = t == ATTR_XOR_MAPPED;
            let fam = v[1];
            let mut port = u16::from_be_bytes([v[2], v[3]]);
            if xor {
                port ^= (MAGIC >> 16) as u16;
            }
            let ip = if fam == 1 {
                let mut x = u32::from_be_bytes([v[4], v[5], v[6], v[7]]);
                if xor {
                    x ^= MAGIC;
                }
                IpAddr::V4(Ipv4Addr::from(x))
            } else if fam == 2 && v.len() >= 20 {
                let mut o: [u8; 16] = v[4..20].try_into().ok()?;
                if xor {
                    let mut key = [0u8; 16];
                    key[..4].copy_from_slice(&MAGIC.to_be_bytes());
                    key[4..].copy_from_slice(&txid);
                    for k in 0..16 {
                        o[k] ^= key[k];
                    }
                }
                IpAddr::V6(Ipv6Addr::from(o))
            } else {
                return None;
            };
            let a = SocketAddr::new(ip, port);
            if xor {
                return Some((txid, a));
            }
            fallback = Some(a);
        }
        i += 4 + ((l + 3) & !3);
    }
    fallback.map(|a| (txid, a))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn roundtrip_v4_v6() {
        let tx = [9u8; 12];
        for a in ["1.2.3.4:5678", "[2001:db8::1]:443"] {
            let a: SocketAddr = a.parse().unwrap();
            let r = binding_response(&tx, a);
            let (t, got) = parse_response(&r).unwrap();
            assert_eq!(t, tx);
            assert_eq!(got, a);
        }
        assert!(is_binding_request(&binding_request(&tx)).is_some());
    }
}
