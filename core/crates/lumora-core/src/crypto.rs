//! Symmetric + public-key primitives.
//!
//! * `seal_to` / `open_sealed`: authenticated, anonymous-sender-hiding envelope for one
//!   recipient (ephemeral X25519 → BLAKE3 KDF → XChaCha20-Poly1305). The inner payload is
//!   additionally signed by the sender's Ed25519 key so the recipient learns who sent it,
//!   but relays / mailboxes / Nostr relays only see random bytes.
//! * `aead_*`: XChaCha20-Poly1305 with random 24-byte nonces (group keys, at-rest blobs).
//! * `derive_db_key`: Argon2id for the optional local passphrase.

use crate::identity::{Identity, PeerId};
use anyhow::{anyhow, bail, Result};
use chacha20poly1305::{
    aead::{Aead, KeyInit, Payload},
    XChaCha20Poly1305, XNonce,
};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

pub fn random_bytes<const N: usize>() -> [u8; N] {
    let mut b = [0u8; N];
    rand::rngs::OsRng.fill_bytes(&mut b);
    b
}

pub fn aead_encrypt(key: &[u8; 32], plaintext: &[u8], aad: &[u8]) -> Vec<u8> {
    let cipher = XChaCha20Poly1305::new(key.into());
    let nonce: [u8; 24] = random_bytes();
    let mut out = nonce.to_vec();
    out.extend(cipher.encrypt(XNonce::from_slice(&nonce), Payload { msg: plaintext, aad }).expect("encrypt"));
    out
}

pub fn aead_decrypt(key: &[u8; 32], data: &[u8], aad: &[u8]) -> Result<Vec<u8>> {
    if data.len() < 24 + 16 {
        bail!("ciphertext too short");
    }
    let cipher = XChaCha20Poly1305::new(key.into());
    cipher
        .decrypt(XNonce::from_slice(&data[..24]), Payload { msg: &data[24..], aad })
        .map_err(|_| anyhow!("decryption failed"))
}

#[derive(Serialize, Deserialize)]
struct SealedInner {
    from: PeerId,
    to: PeerId,
    ts: u64,
    #[serde(with = "serde_bytes")]
    body: Vec<u8>,
    #[serde(with = "serde_bytes")]
    sig: Vec<u8>,
}

fn seal_key(shared: &[u8; 32], eph: &[u8; 32], to: &[u8; 32]) -> Zeroizing<[u8; 32]> {
    let mut h = blake3::Hasher::new_derive_key("lumora seal v1");
    h.update(shared);
    h.update(eph);
    h.update(to);
    Zeroizing::new(*h.finalize().as_bytes())
}

/// Encrypt `body` so only `to` can read it; the recipient can verify it came from `me`.
pub fn seal_to(me: &Identity, to: &PeerId, body: &[u8]) -> Result<Vec<u8>> {
    let to_x = to.x25519().ok_or_else(|| anyhow!("invalid recipient key"))?;
    let ts = crate::util::now_ms();
    let mut signed = Vec::with_capacity(body.len() + 72);
    signed.extend_from_slice(b"lumora-sealed-v1");
    signed.extend_from_slice(&to.0);
    signed.extend_from_slice(&ts.to_le_bytes());
    signed.extend_from_slice(body);
    let inner = SealedInner { from: me.peer_id(), to: *to, ts, body: body.to_vec(), sig: me.sign(&signed).to_vec() };
    let plain = rmp_serde::to_vec(&inner)?;
    let eph = StaticSecret::random_from_rng(rand::rngs::OsRng);
    let eph_pub = PublicKey::from(&eph);
    let shared = eph.diffie_hellman(&PublicKey::from(to_x));
    let key = seal_key(shared.as_bytes(), eph_pub.as_bytes(), &to.0);
    let mut out = Vec::with_capacity(plain.len() + 80);
    out.push(1u8);
    out.extend_from_slice(eph_pub.as_bytes());
    out.extend(aead_encrypt(&key, &plain, eph_pub.as_bytes()));
    Ok(out)
}

/// Returns (sender, timestamp_ms, body).
pub fn open_sealed(me: &Identity, data: &[u8]) -> Result<(PeerId, u64, Vec<u8>)> {
    if data.len() < 33 || data[0] != 1 {
        bail!("bad envelope");
    }
    let eph_pub: [u8; 32] = data[1..33].try_into().unwrap();
    let sk = StaticSecret::from(*me.x25519_secret());
    let shared = sk.diffie_hellman(&PublicKey::from(eph_pub));
    let key = seal_key(shared.as_bytes(), &eph_pub, &me.peer_id().0);
    let plain = aead_decrypt(&key, &data[33..], &eph_pub)?;
    let inner: SealedInner = crate::proto::from_slice_capped(&plain)?;
    if inner.to != me.peer_id() {
        bail!("envelope not for us");
    }
    let mut signed = Vec::with_capacity(inner.body.len() + 72);
    signed.extend_from_slice(b"lumora-sealed-v1");
    signed.extend_from_slice(&inner.to.0);
    signed.extend_from_slice(&inner.ts.to_le_bytes());
    signed.extend_from_slice(&inner.body);
    if !inner.from.verify(&signed, &inner.sig) {
        bail!("bad sender signature");
    }
    Ok((inner.from, inner.ts, inner.body))
}

/// Argon2id(passphrase, salt) → 32 byte key. Parameters tuned for ~0.5s on a laptop.
pub fn derive_passphrase_key(pass: &str, salt: &[u8; 16]) -> Result<Zeroizing<[u8; 32]>> {
    use argon2::{Algorithm, Argon2, Params, Version};
    let params = Params::new(64 * 1024, 3, 1, Some(32)).map_err(|e| anyhow!("{e}"))?;
    let a = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut out = Zeroizing::new([0u8; 32]);
    a.hash_password_into(pass.as_bytes(), salt, &mut out[..]).map_err(|e| anyhow!("{e}"))?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn seal_roundtrip() {
        let a = Identity::generate();
        let b = Identity::generate();
        let c = Identity::generate();
        let env = seal_to(&a, &b.peer_id(), b"secret hello").unwrap();
        let (from, _ts, body) = open_sealed(&b, &env).unwrap();
        assert_eq!(from, a.peer_id());
        assert_eq!(body, b"secret hello");
        assert!(open_sealed(&c, &env).is_err());
        let mut bad = env.clone();
        let l = bad.len();
        bad[l - 1] ^= 1;
        assert!(open_sealed(&b, &bad).is_err());
    }
    #[test]
    fn aead() {
        let k = random_bytes::<32>();
        let ct = aead_encrypt(&k, b"x", b"ad");
        assert_eq!(aead_decrypt(&k, &ct, b"ad").unwrap(), b"x");
        assert!(aead_decrypt(&k, &ct, b"other").is_err());
    }
}
