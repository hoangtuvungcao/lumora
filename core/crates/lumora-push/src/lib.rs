//! # lumora-push
//!
//! Lumora is serverless, but iOS only wakes a suspended app through Apple's push
//! service (APNs), and APNs only accepts pushes signed with the publisher's key.
//! This crate is the small, optional, self-hostable piece that bridges the two:
//!
//! * **The bridge never learns who talks to whom or what was said.** The iPhone seals
//!   its APNs token to the bridge's X25519 key ([`seal_token`]) and hands that opaque
//!   blob to its friends inside a [`PushReg`]. A friend whose message cannot be
//!   delivered POSTs the blob to `/wake`; only the bridge can open it, and it learns
//!   nothing but "some device should wake up".
//! * **The push carries no content.** An optional end-to-end blob ([`seal_notify`])
//!   lets the recipient's Notification Service Extension show the sender's name and a
//!   preview; it is sealed to a key that never leaves the recipient's devices, with a
//!   construction CryptoKit implements natively (X25519 → HKDF-SHA256 → ChaChaPoly).
//!
//! The library half (formats, sealing) is dependency-light and used by `lumora-core`.
//! The `server` feature adds the HTTP bridge and the APNs HTTP/2 client.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use serde::{Deserialize, Serialize};
use x25519_dalek::{PublicKey, StaticSecret};

#[cfg(feature = "server")]
pub mod apns;
#[cfg(feature = "server")]
pub mod server;

/// Maximum size of the end-to-end notification blob a sender may attach (APNs payloads
/// are limited to 4 KB; base64 + JSON overhead must fit).
pub const MAX_E2E: usize = 2048;
/// Maximum size of a sealed token.
pub const MAX_SEALED_TOKEN: usize = 1024;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SealError {
    #[error("sealed data is malformed")]
    Malformed,
    #[error("cannot open sealed data (wrong key or tampered)")]
    Open,
}

// ------------------------------------------------------------------ keys

/// A bridge (or notify) key pair. The secret is 32 random bytes.
#[derive(Clone)]
pub struct KeyPair {
    pub secret: [u8; 32],
    pub public: [u8; 32],
}

impl KeyPair {
    pub fn generate() -> Self {
        Self::from_secret(rand::random())
    }
    pub fn from_secret(secret: [u8; 32]) -> Self {
        let public = PublicKey::from(&StaticSecret::from(secret)).to_bytes();
        KeyPair { secret, public }
    }
}

pub fn b64(b: &[u8]) -> String {
    data_encoding::BASE64.encode(b)
}

pub fn unb64(s: &str) -> Option<Vec<u8>> {
    data_encoding::BASE64.decode(s.trim().as_bytes()).ok()
}

pub fn key32(s: &str) -> Option<[u8; 32]> {
    unb64(s)?.try_into().ok()
}

// ------------------------------------------------------------------ token sealing (device → bridge)

/// What the iPhone tells the bridge, sealed so only the bridge can read it.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
pub struct DeviceToken {
    /// APNs device token (hex) for alert pushes.
    pub apns: String,
    /// PushKit VoIP token (hex) for incoming calls; empty if calls should not ring.
    #[serde(default)]
    pub voip: String,
    /// App bundle id (APNs topic). The bridge only serves its own app's topic.
    pub topic: String,
    /// Development (sandbox) APNs environment.
    #[serde(default)]
    pub sandbox: bool,
    /// Expiry (unix seconds). 0 = never: tokens sealed by older apps. Current apps seal
    /// [`TOKEN_TTL_SECS`] ahead and re-seal (refresh) well before that.
    #[serde(default)]
    pub exp: u64,
    /// Registration generation, increasing per device. The bridge remembers the newest
    /// generation it has seen for each device token and refuses older sealed tokens, so
    /// re-registering with a new generation revokes every copy friends still hold.
    /// 0 = older app (no generation).
    #[serde(default)]
    pub gen: u64,
}

/// Lifetime of a sealed token: friends must receive a fresh one (on reconnect) at least
/// this often, so a leaked or stale copy stops working on its own.
pub const TOKEN_TTL_SECS: u64 = 30 * 86_400;

impl DeviceToken {
    /// Expired at `now` (unix seconds)? Tokens without an expiry (older apps) never are.
    pub fn expired(&self, now_secs: u64) -> bool {
        self.exp != 0 && now_secs > self.exp
    }
}

fn token_key(shared: &[u8; 32], eph: &[u8; 32], bridge: &[u8; 32]) -> [u8; 32] {
    let mut m = Vec::with_capacity(96);
    m.extend_from_slice(shared);
    m.extend_from_slice(eph);
    m.extend_from_slice(bridge);
    blake3::derive_key("lumora-push token v1", &m)
}

/// Seal a [`DeviceToken`] to the bridge public key: `eph_pub(32) || ChaCha20-Poly1305(ct)`.
/// The key is fresh per seal (ephemeral X25519), so the all-zero nonce is safe.
pub fn seal_token(bridge_pub: &[u8; 32], t: &DeviceToken) -> Vec<u8> {
    let eph = StaticSecret::from(rand::random::<[u8; 32]>());
    let eph_pub = PublicKey::from(&eph).to_bytes();
    let shared = eph.diffie_hellman(&PublicKey::from(*bridge_pub)).to_bytes();
    let k = token_key(&shared, &eph_pub, bridge_pub);
    let plain = rmp_serde::to_vec_named(t).expect("serialize token");
    let ct = ChaCha20Poly1305::new(Key::from_slice(&k))
        .encrypt(Nonce::from_slice(&[0u8; 12]), Payload { msg: &plain, aad: b"lumora-push token" })
        .expect("encrypt");
    let mut out = eph_pub.to_vec();
    out.extend(ct);
    out
}

pub fn open_token(bridge: &KeyPair, sealed: &[u8]) -> Result<DeviceToken, SealError> {
    if sealed.len() < 32 + 16 || sealed.len() > MAX_SEALED_TOKEN {
        return Err(SealError::Malformed);
    }
    let eph_pub: [u8; 32] = sealed[..32].try_into().map_err(|_| SealError::Malformed)?;
    let shared = StaticSecret::from(bridge.secret).diffie_hellman(&PublicKey::from(eph_pub)).to_bytes();
    let k = token_key(&shared, &eph_pub, &bridge.public);
    let plain = ChaCha20Poly1305::new(Key::from_slice(&k))
        .decrypt(Nonce::from_slice(&[0u8; 12]), Payload { msg: &sealed[32..], aad: b"lumora-push token" })
        .map_err(|_| SealError::Open)?;
    rmp_serde::from_slice(&plain).map_err(|_| SealError::Malformed)
}

/// Stable, non-reversible id of a device token (rate limits, dead-token list).
pub fn token_id(device_token_hex: &str) -> [u8; 32] {
    blake3::derive_key("lumora-push token id v1", device_token_hex.trim().to_ascii_lowercase().as_bytes())
}

// ------------------------------------------------------------------ notification sealing (sender → recipient)

/// Shown by the recipient's Notification Service Extension after decrypting on-device.
/// JSON so the Swift side can decode it with `Codable`.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
pub struct Notify {
    /// "msg" or "call".
    pub k: String,
    /// Sender peer id (base32).
    pub from: String,
    /// Sender display name.
    #[serde(default)]
    pub name: String,
    /// Short preview ("" for media / groups / when the sender has none).
    #[serde(default)]
    pub preview: String,
    /// Conversation id as the recipient sees it (e.g. `d:<sender>`).
    #[serde(default)]
    pub conv: String,
    /// Call id (hex) for `k == "call"`.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub call: String,
    #[serde(default)]
    pub video: bool,
    /// Unix milliseconds.
    #[serde(default)]
    pub t: u64,
}

const NOTIFY_INFO: &[u8] = b"lumora-push notify v1";

fn notify_key(shared: &[u8; 32], eph_pub: &[u8; 32], notify_pub: &[u8; 32]) -> [u8; 32] {
    // HKDF-SHA256(ikm = X25519 shared secret, salt = eph_pub || recipient_pub, info).
    // CryptoKit: sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt:, sharedInfo:, outputByteCount: 32)
    let mut salt = [0u8; 64];
    salt[..32].copy_from_slice(eph_pub);
    salt[32..].copy_from_slice(notify_pub);
    let hk = hkdf::Hkdf::<sha2::Sha256>::new(Some(&salt), shared);
    let mut k = [0u8; 32];
    hk.expand(NOTIFY_INFO, &mut k).expect("hkdf length");
    k
}

/// Seal `n` to the recipient's notify key: `eph_pub(32) || nonce(12) || ciphertext || tag(16)`.
/// The last 3 parts are exactly CryptoKit's `ChaChaPoly.SealedBox.combined`.
pub fn seal_notify(notify_pub: &[u8; 32], n: &Notify) -> Vec<u8> {
    let eph = StaticSecret::from(rand::random::<[u8; 32]>());
    let eph_pub = PublicKey::from(&eph).to_bytes();
    let shared = eph.diffie_hellman(&PublicKey::from(*notify_pub)).to_bytes();
    let k = notify_key(&shared, &eph_pub, notify_pub);
    let nonce: [u8; 12] = rand::random();
    let mut plain = serde_json::to_vec(n).expect("serialize notify");
    // keep the push small: trim the preview until it fits
    let mut n2 = n.clone();
    while plain.len() > MAX_E2E - 60 && !n2.preview.is_empty() {
        let keep = n2.preview.chars().count() * 3 / 4;
        n2.preview = n2.preview.chars().take(keep).collect();
        plain = serde_json::to_vec(&n2).expect("serialize notify");
    }
    let ct = ChaCha20Poly1305::new(Key::from_slice(&k)).encrypt(Nonce::from_slice(&nonce), plain.as_slice()).expect("encrypt");
    let mut out = eph_pub.to_vec();
    out.extend_from_slice(&nonce);
    out.extend(ct);
    out
}

pub fn open_notify(notify: &KeyPair, blob: &[u8]) -> Result<Notify, SealError> {
    if blob.len() < 32 + 12 + 16 || blob.len() > MAX_E2E {
        return Err(SealError::Malformed);
    }
    let eph_pub: [u8; 32] = blob[..32].try_into().map_err(|_| SealError::Malformed)?;
    let shared = StaticSecret::from(notify.secret).diffie_hellman(&PublicKey::from(eph_pub)).to_bytes();
    let k = notify_key(&shared, &eph_pub, &notify.public);
    let plain = ChaCha20Poly1305::new(Key::from_slice(&k))
        .decrypt(Nonce::from_slice(&blob[32..44]), &blob[44..])
        .map_err(|_| SealError::Open)?;
    serde_json::from_slice(&plain).map_err(|_| SealError::Malformed)
}

// ------------------------------------------------------------------ wire types

/// What an iPhone gives its friends (inside `PeerMsg::PushReg`). Map-encoded
/// (`rmp_serde::to_vec_named`) so fields can be added without breaking anyone.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
pub struct PushReg {
    pub v: u8,
    /// Bridge base URL, e.g. `https://push.example.org`. Empty = registration revoked.
    pub bridge: String,
    /// [`seal_token`] output (opaque to everyone but the bridge).
    #[serde(with = "serde_bytes")]
    pub token: Vec<u8>,
    /// X25519 public key for [`seal_notify`]; empty = "do not send previews".
    #[serde(default, with = "serde_bytes")]
    pub notify: Vec<u8>,
    /// Registration time (unix ms); newer replaces older.
    #[serde(default)]
    pub at: u64,
}

impl PushReg {
    pub fn encode(&self) -> Vec<u8> {
        rmp_serde::to_vec_named(self).unwrap_or_default()
    }
    pub fn decode(b: &[u8]) -> Option<Self> {
        if b.len() > 4096 {
            return None;
        }
        rmp_serde::from_slice(b).ok()
    }
    pub fn is_active(&self) -> bool {
        !self.bridge.is_empty() && !self.token.is_empty()
    }
    pub fn notify_key(&self) -> Option<[u8; 32]> {
        self.notify.as_slice().try_into().ok()
    }
}

/// Body of `POST {bridge}/register`: the phone tells the bridge about its newest sealed
/// token so older generations are refused at once (not only after a friend uses the new
/// one). Replaying a friend's copy is harmless: it can only repeat a generation the bridge
/// already knows. Older bridges answer 404, which clients ignore.
#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub struct RegisterRequest {
    /// base64 of the sealed token.
    pub token: String,
}

/// Body of `POST {bridge}/wake`.
#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub struct WakeRequest {
    /// base64 of the sealed token.
    pub token: String,
    /// "msg" | "call".
    pub kind: String,
    /// Optional base64 of a [`seal_notify`] blob, forwarded untouched.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub e2e: String,
}

/// Bridge URLs a client is willing to call: HTTPS anywhere, plain HTTP only on
/// loopback (tests, a bridge on the same machine).
pub fn bridge_url_allowed(url: &str) -> bool {
    let u = url.trim();
    if u.len() > 256 || u.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return false;
    }
    if let Some(rest) = u.strip_prefix("https://") {
        return !rest.is_empty() && !rest.starts_with('/');
    }
    if let Some(rest) = u.strip_prefix("http://") {
        let host = rest.split(['/', '?']).next().unwrap_or("");
        let host = host.rsplit_once(':').map(|(h, _)| h).unwrap_or(host);
        return matches!(host, "127.0.0.1" | "localhost" | "[::1]");
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_round_trip_and_tamper() {
        let bridge = KeyPair::generate();
        let t = DeviceToken { apns: "ab".repeat(32), voip: "cd".repeat(32), topic: "vn.lumora.lumora".into(), sandbox: true, exp: 9, gen: 3 };
        let s = seal_token(&bridge.public, &t);
        assert_eq!(open_token(&bridge, &s).unwrap(), t);
        // fresh ephemeral key: two seals of the same token are unlinkable
        assert_ne!(seal_token(&bridge.public, &t), s);
        let mut bad = s.clone();
        let n = bad.len();
        bad[n - 1] ^= 1;
        assert_eq!(open_token(&bridge, &bad), Err(SealError::Open));
        assert_eq!(open_token(&KeyPair::generate(), &s), Err(SealError::Open));
        assert_eq!(open_token(&bridge, &s[..20]), Err(SealError::Malformed));
    }

    #[test]
    fn token_expiry_and_old_format() {
        let t = DeviceToken { exp: 100, ..Default::default() };
        assert!(!t.expired(100) && t.expired(101));
        assert!(!DeviceToken::default().expired(u64::MAX), "tokens from older apps never expire");
        // a token sealed by an older app (no exp / gen fields) still opens, as legacy
        #[derive(Serialize)]
        struct Old<'a> {
            apns: &'a str,
            voip: &'a str,
            topic: &'a str,
            sandbox: bool,
        }
        let bridge = KeyPair::generate();
        let plain = rmp_serde::to_vec_named(&Old { apns: "ab", voip: "", topic: "t", sandbox: false }).unwrap();
        let eph = StaticSecret::from(rand::random::<[u8; 32]>());
        let eph_pub = PublicKey::from(&eph).to_bytes();
        let k = token_key(&eph.diffie_hellman(&PublicKey::from(bridge.public)).to_bytes(), &eph_pub, &bridge.public);
        let ct = ChaCha20Poly1305::new(Key::from_slice(&k))
            .encrypt(Nonce::from_slice(&[0u8; 12]), Payload { msg: &plain, aad: b"lumora-push token" })
            .unwrap();
        let sealed = [eph_pub.to_vec(), ct].concat();
        let t = open_token(&bridge, &sealed).unwrap();
        assert_eq!((t.apns.as_str(), t.exp, t.gen), ("ab", 0, 0));
    }

    #[test]
    fn notify_round_trip_and_size_cap() {
        let rk = KeyPair::generate();
        let n = Notify { k: "msg".into(), from: "peer".into(), name: "Lan".into(), preview: "Xin chào 👋".into(), conv: "d:peer".into(), ..Default::default() };
        let b = seal_notify(&rk.public, &n);
        assert_eq!(open_notify(&rk, &b).unwrap(), n);
        assert!(open_notify(&KeyPair::generate(), &b).is_err());
        let long = Notify { preview: "ắ".repeat(5000), ..n };
        let b = seal_notify(&rk.public, &long);
        assert!(b.len() <= MAX_E2E, "{}", b.len());
        assert!(open_notify(&rk, &b).unwrap().preview.chars().count() < 5000);
    }

    #[test]
    fn push_reg_is_map_encoded_and_extensible() {
        let r = PushReg { v: 1, bridge: "https://push.example".into(), token: vec![1, 2, 3], notify: vec![9; 32], at: 5 };
        let b = r.encode();
        assert_eq!(b[0] & 0xf0, 0x80, "fixmap expected (named encoding)");
        assert_eq!(PushReg::decode(&b).unwrap(), r);
        // a future version with an extra field still decodes
        #[derive(Serialize)]
        struct Future<'a> {
            v: u8,
            bridge: &'a str,
            #[serde(with = "serde_bytes")]
            token: &'a [u8],
            extra: u32,
        }
        let f = rmp_serde::to_vec_named(&Future { v: 2, bridge: "https://x", token: &[1], extra: 7 }).unwrap();
        assert_eq!(PushReg::decode(&f).unwrap().bridge, "https://x");
    }

    #[test]
    fn url_policy() {
        assert!(bridge_url_allowed("https://push.lumora.vn"));
        assert!(bridge_url_allowed("http://127.0.0.1:8099"));
        assert!(!bridge_url_allowed("http://push.lumora.vn"));
        assert!(!bridge_url_allowed("http://10.0.0.1"));
        assert!(!bridge_url_allowed("file:///etc/passwd"));
        assert!(!bridge_url_allowed("https://"));
    }
}
