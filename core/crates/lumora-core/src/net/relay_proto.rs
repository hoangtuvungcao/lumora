//! Wire format spoken between nodes and Lumora relays (VPS / Cloudflare Worker /
//! peer relay). Deliberately tiny and dependency-light so the relay server and the
//! Cloudflare Worker (JavaScript) can implement it in a few dozen lines.
//!
//! Every frame is one WebSocket binary message: `[type u8][...]`.
//!
//! | type | dir | layout                                   |
//! |------|-----|------------------------------------------|
//! | 1 HELLO   | c→s | pubkey[32] ts_ms u64be sig[64]      |
//! | 2 WELCOME | s→c | observed address (utf8)             |
//! | 3 DATA    | ↔   | peer[32] payload  (QUIC datagram)   |
//! | 4 SIGNAL  | ↔   | peer[32] payload  (sealed envelope) |
//! | 5 GONE    | s→c | peer[32]                            |
//! | 6 ERROR   | s→c | utf8 message                        |
//!
//! The relay authenticates who is connected (HELLO signature) so nobody can
//! receive another node's traffic; payloads are end-to-end encrypted, so the relay
//! cannot read or forge them. Signals for offline peers may be stored (mailbox)
//! for a limited time if the relay operator enabled it.

pub const T_HELLO: u8 = 1;
pub const T_WELCOME: u8 = 2;
pub const T_DATA: u8 = 3;
pub const T_SIGNAL: u8 = 4;
pub const T_GONE: u8 = 5;
pub const T_ERROR: u8 = 6;

pub const HELLO_CONTEXT: &[u8] = b"lumora-relay-hello-v1";
pub const MAX_FRAME: usize = 64 * 1024;

pub fn hello_message(pubkey: &[u8; 32], ts: u64) -> Vec<u8> {
    let mut m = HELLO_CONTEXT.to_vec();
    m.extend_from_slice(pubkey);
    m.extend_from_slice(&ts.to_be_bytes());
    m
}

pub fn encode_hello(pubkey: &[u8; 32], ts: u64, sig: &[u8; 64]) -> Vec<u8> {
    let mut v = Vec::with_capacity(1 + 32 + 8 + 64);
    v.push(T_HELLO);
    v.extend_from_slice(pubkey);
    v.extend_from_slice(&ts.to_be_bytes());
    v.extend_from_slice(sig);
    v
}

pub fn decode_hello(f: &[u8]) -> Option<([u8; 32], u64, [u8; 64])> {
    if f.len() != 1 + 32 + 8 + 64 || f[0] != T_HELLO {
        return None;
    }
    let pk: [u8; 32] = f[1..33].try_into().ok()?;
    let ts = u64::from_be_bytes(f[33..41].try_into().ok()?);
    let sig: [u8; 64] = f[41..105].try_into().ok()?;
    Some((pk, ts, sig))
}

pub fn encode_peer_frame(t: u8, peer: &[u8; 32], payload: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(33 + payload.len());
    v.push(t);
    v.extend_from_slice(peer);
    v.extend_from_slice(payload);
    v
}

pub fn decode_peer_frame(f: &[u8]) -> Option<(u8, [u8; 32], &[u8])> {
    if f.len() < 33 {
        return None;
    }
    Some((f[0], f[1..33].try_into().ok()?, &f[33..]))
}
