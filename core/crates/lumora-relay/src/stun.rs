//! Minimal RFC 5389 STUN binding responder (XOR-MAPPED-ADDRESS), logic mirrored
//! from lumora-core/src/net/stun.rs.

use std::net::{IpAddr, SocketAddr};
use tokio::net::UdpSocket;

pub const MAGIC: u32 = 0x2112_A442;
const BINDING_REQUEST: u16 = 0x0001;
const BINDING_SUCCESS: u16 = 0x0101;
const ATTR_XOR_MAPPED: u16 = 0x0020;

pub fn is_binding_request(d: &[u8]) -> Option<[u8; 12]> {
    if d.len() >= 20
        && (d[0] & 0xC0) == 0
        && u32::from_be_bytes([d[4], d[5], d[6], d[7]]) == MAGIC
        && u16::from_be_bytes([d[0], d[1]]) == BINDING_REQUEST
    {
        d[8..20].try_into().ok()
    } else {
        None
    }
}

pub fn canon(addr: SocketAddr) -> SocketAddr {
    match addr {
        SocketAddr::V6(v6) => match v6.ip().to_ipv4_mapped() {
            Some(v4) => SocketAddr::new(IpAddr::V4(v4), v6.port()),
            None => addr,
        },
        a => a,
    }
}

pub fn binding_response(txid: &[u8; 12], addr: SocketAddr) -> Vec<u8> {
    let addr = canon(addr);
    let mut attr = Vec::with_capacity(20);
    let port = addr.port() ^ (MAGIC >> 16) as u16;
    match addr.ip() {
        IpAddr::V4(ip) => {
            attr.extend_from_slice(&[0, 1]);
            attr.extend_from_slice(&port.to_be_bytes());
            attr.extend_from_slice(&(u32::from(ip) ^ MAGIC).to_be_bytes());
        }
        IpAddr::V6(ip) => {
            attr.extend_from_slice(&[0, 2]);
            attr.extend_from_slice(&port.to_be_bytes());
            let mut key = [0u8; 16];
            key[..4].copy_from_slice(&MAGIC.to_be_bytes());
            key[4..].copy_from_slice(txid);
            attr.extend(ip.octets().iter().zip(key.iter()).map(|(o, k)| o ^ k));
        }
    }
    let mut v = Vec::with_capacity(20 + 4 + attr.len());
    v.extend_from_slice(&BINDING_SUCCESS.to_be_bytes());
    v.extend_from_slice(&((4 + attr.len()) as u16).to_be_bytes());
    v.extend_from_slice(&MAGIC.to_be_bytes());
    v.extend_from_slice(txid);
    v.extend_from_slice(&ATTR_XOR_MAPPED.to_be_bytes());
    v.extend_from_slice(&(attr.len() as u16).to_be_bytes());
    v.extend_from_slice(&attr);
    v
}

/// Answer binding requests forever; everything else is ignored.
pub async fn serve(sock: UdpSocket) {
    let mut buf = [0u8; 1500];
    loop {
        match sock.recv_from(&mut buf).await {
            Ok((n, from)) => {
                if let Some(tx) = is_binding_request(&buf[..n]) {
                    let _ = sock.send_to(&binding_response(&tx, from), from).await;
                }
            }
            Err(e) => {
                // ICMP port-unreachable etc. surface here on some OSes; keep going.
                tracing::debug!(error = %e, "stun recv error");
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        }
    }
}
