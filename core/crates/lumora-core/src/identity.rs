//! Device identity: an Ed25519 key pair that never leaves the device.
//!
//! * `PeerId` – the 32-byte public key; displayed as base32 (52 chars).
//! * `short_id` – a 9-digit number derived from the key (UltraViewer-style). It is
//!   *verifiable*: anyone can recompute it from the public key, so a directory
//!   cannot lie about which key owns an ID (only collisions are possible and are
//!   surfaced to the user).

use data_encoding::BASE32_NOPAD;
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use std::fmt;
use zeroize::Zeroizing;

#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct PeerId(pub [u8; 32]);

impl PeerId {
    pub fn to_base32(&self) -> String {
        BASE32_NOPAD.encode(&self.0).to_lowercase()
    }
    pub fn from_str_any(s: &str) -> anyhow::Result<Self> {
        let s = s.trim();
        if s.len() == 64 {
            let v = hex::decode(s)?;
            return Ok(PeerId(v.try_into().map_err(|_| anyhow::anyhow!("bad len"))?));
        }
        let v = BASE32_NOPAD.decode(s.to_uppercase().as_bytes())?;
        Ok(PeerId(v.try_into().map_err(|_| anyhow::anyhow!("bad len"))?))
    }
    /// 9 digit, human friendly, verifiable ID.
    pub fn short_id(&self) -> u32 {
        let h = blake3::derive_key("lumora short id v1", &self.0);
        let n = u64::from_le_bytes(h[..8].try_into().unwrap());
        (n % 900_000_000) as u32 + 100_000_000
    }
    pub fn short_id_fmt(&self) -> String {
        let s = self.short_id().to_string();
        format!("{} {} {}", &s[0..3], &s[3..6], &s[6..9])
    }
    pub fn verify(&self, msg: &[u8], sig: &[u8]) -> bool {
        let Ok(vk) = VerifyingKey::from_bytes(&self.0) else { return false };
        let Ok(sig) = Signature::from_slice(sig) else { return false };
        vk.verify(msg, &sig).is_ok()
    }
    /// X25519 public key (Montgomery form) used for sealing data to this peer.
    pub fn x25519(&self) -> Option<[u8; 32]> {
        let vk = VerifyingKey::from_bytes(&self.0).ok()?;
        Some(vk.to_montgomery().to_bytes())
    }
    /// Personal security code (6 groups of 5 digits): lets a friend check, in person or by
    /// voice, that the account they added is really this one.
    pub fn security_code(&self) -> String {
        let h = blake3::derive_key("lumora personal security code v1", &self.0);
        (0..6)
            .map(|i| format!("{:05}", u32::from_le_bytes([h[i * 4], h[i * 4 + 1], h[i * 4 + 2], h[i * 4 + 3]]) % 100_000))
            .collect::<Vec<_>>()
            .join(" ")
    }
    /// Safety number shown to both users to detect a man-in-the-middle.
    pub fn safety_number(a: &PeerId, b: &PeerId) -> String {
        let (x, y) = if a < b { (a, b) } else { (b, a) };
        let mut h = blake3::Hasher::new_derive_key("lumora safety number v1");
        h.update(&x.0);
        h.update(&y.0);
        let out = h.finalize();
        let mut groups = Vec::new();
        for i in 0..12 {
            let v = u32::from_le_bytes([out.as_bytes()[i * 2], out.as_bytes()[i * 2 + 1], out.as_bytes()[24 + (i % 8)], 0]) % 100_000;
            groups.push(format!("{:05}", v));
        }
        groups.join(" ")
    }
}

impl fmt::Debug for PeerId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Peer({})", &self.to_base32()[..10])
    }
}
impl fmt::Display for PeerId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_base32())
    }
}

pub struct Identity {
    key: SigningKey,
}

impl Clone for Identity {
    fn clone(&self) -> Self {
        Identity { key: SigningKey::from_bytes(&self.key.to_bytes()) }
    }
}

impl Identity {
    pub fn generate() -> Self {
        let mut rng = rand::rngs::OsRng;
        Identity { key: SigningKey::generate(&mut rng) }
    }
    pub fn from_secret(secret: &[u8; 32]) -> Self {
        Identity { key: SigningKey::from_bytes(secret) }
    }
    pub fn secret_bytes(&self) -> Zeroizing<[u8; 32]> {
        Zeroizing::new(self.key.to_bytes())
    }
    pub fn peer_id(&self) -> PeerId {
        PeerId(self.key.verifying_key().to_bytes())
    }
    pub fn sign(&self, msg: &[u8]) -> [u8; 64] {
        self.key.sign(msg).to_bytes()
    }
    pub fn signing_key(&self) -> &SigningKey {
        &self.key
    }
    /// X25519 static secret matching `PeerId::x25519`.
    pub fn x25519_secret(&self) -> Zeroizing<[u8; 32]> {
        Zeroizing::new(self.key.to_scalar_bytes())
    }
    /// PKCS#8 DER for TLS certificates.
    pub fn pkcs8_der(&self) -> Zeroizing<Vec<u8>> {
        use ed25519_dalek::pkcs8::EncodePrivateKey;
        Zeroizing::new(self.key.to_pkcs8_der().expect("pkcs8").as_bytes().to_vec())
    }
    /// Recovery phrase: the identity secret (Ed25519 seed) as 24 English BIP39 words
    /// separated by spaces (see [`crate::bip39`]; no PBKDF2 step, the words *are* the seed).
    pub fn recovery_phrase(&self) -> String {
        crate::bip39::encode(&self.secret_bytes())
    }
    /// Restores from a recovery phrase in either format:
    /// * 24 BIP39 English words — any case, extra spaces / newlines / list numbering,
    ///   4-letter prefixes; the checksum is verified;
    /// * the legacy base32 phrase (12 dash-separated groups, BLAKE3 checksum) printed by
    ///   versions before the word list — the same account, so old notes keep working.
    pub fn from_recovery_phrase(p: &str) -> anyhow::Result<Self> {
        use crate::bip39::DecodeError;
        use crate::i18n::user_err;
        if let Some(secret) = legacy_phrase_secret(p)? {
            return Ok(Self::from_secret(&secret));
        }
        let words = Zeroizing::new(crate::bip39::tokens(p));
        let secret = Zeroizing::new(crate::bip39::decode(&words).map_err(|e| match e {
            DecodeError::Count(n) => user_err("err.phrase_count").with("n", n).with("t", crate::bip39::WORDS),
            DecodeError::Word(n) => user_err("err.phrase_word").with("n", n),
            DecodeError::Checksum => user_err("err.phrase_checksum"),
        })?);
        Ok(Self::from_secret(&secret))
    }
}

/// The secret in a legacy base32 phrase: `Ok(None)` when `p` doesn't look like one
/// (so it is parsed as words), an error when it does but is damaged.
fn legacy_phrase_secret(p: &str) -> anyhow::Result<Option<[u8; 32]>> {
    let s = Zeroizing::new(p.chars().filter(|c| c.is_ascii_alphanumeric()).collect::<String>());
    // 32-byte secret + 3-byte check = 35 bytes = 56 base32 characters. A 24-word phrase
    // has at least 72 letters, so the two formats can't be confused. A damaged legacy
    // phrase is still recognised by its shape (dash-joined groups, or ~12 short groups
    // with digits) so the user gets the legacy error rather than a word-list one.
    let b32 = |t: &str| !t.is_empty() && t.chars().all(|c| c.is_ascii_lowercase() || ('2'..='7').contains(&c));
    let lower = Zeroizing::new(p.trim().to_lowercase());
    let compact = Zeroizing::new(lower.chars().filter(|c| !c.is_whitespace()).collect::<String>());
    let groups: Vec<&str> = lower.split(|c: char| c.is_whitespace() || c == '-').filter(|t| !t.is_empty()).collect();
    let short_groups = (10..=13).contains(&groups.len()) && groups.iter().all(|g| g.len() <= 5 && b32(g));
    let looks_legacy = s.len() == 56 || (short_groups && (compact.contains('-') || groups.iter().any(|g| g.chars().any(|c| c.is_ascii_digit()))));
    if !looks_legacy {
        return Ok(None);
    }
    let bad = || crate::i18n::user_err("err.bad_recovery_phrase");
    let data = Zeroizing::new(BASE32_NOPAD.decode(s.to_uppercase().as_bytes()).map_err(|e| bad().detail(e))?);
    anyhow::ensure!(data.len() == 35, bad().detail("phrase length"));
    let secret: [u8; 32] = data[..32].try_into().unwrap();
    anyhow::ensure!(blake3::hash(&secret).as_bytes()[..3] == data[32..], bad().detail("checksum mismatch"));
    Ok(Some(secret))
}

/// The legacy base32 phrase of `id` (tests: proves old notes still restore).
#[cfg(test)]
fn legacy_phrase(id: &Identity) -> String {
    let secret = id.secret_bytes();
    let check = blake3::hash(&secret[..]);
    let mut data = secret.to_vec();
    data.extend_from_slice(&check.as_bytes()[..3]);
    let s = BASE32_NOPAD.encode(&data).to_lowercase();
    s.as_bytes().chunks(5).map(|c| std::str::from_utf8(c).unwrap()).collect::<Vec<_>>().join("-")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn roundtrip() {
        let id = Identity::generate();
        let p = id.peer_id();
        assert_eq!(PeerId::from_str_any(&p.to_base32()).unwrap(), p);
        let sig = id.sign(b"hi");
        assert!(p.verify(b"hi", &sig));
        assert!(!p.verify(b"ho", &sig));
        let sid = p.short_id();
        assert!((100_000_000..1_000_000_000).contains(&sid));
        let phrase = id.recovery_phrase();
        assert_eq!(phrase.split(' ').count(), 24);
        let id2 = Identity::from_recovery_phrase(&phrase).unwrap();
        assert_eq!(id2.peer_id(), p);
    }

    /// Phrases written by the pre-word-list code (generated with that code, before the
    /// switch) and the 24 words for the same secrets: both restore the same account.
    const GOLDEN: &[(&str, &str, &str, &str)] = &[
        (
            "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20",
            "aebag-bafay-dqqci-kbmga-2dqpc-airee-yucul-bogaz-dinry-hi6d4-qpbum-e",
            "absurd avoid scissors anxiety gather lottery category door army half long cage bachelor another expect people blade school educate curtain scrub monitor lady beyond",
            "pg2vmlup4zkpsqdywejorkmlu6ib7bj242k35v7a4oiqxlieszsa",
        ),
        (
            "4242424242424242424242424242424242424242424242424242424242424242",
            "ijbee-qscij-beeqs-cijbe-eqsci-jbeeq-scijb-eeqsc-ijbee-qscij-blz7y-r",
            "drastic bamboo mountain loyal category cancel animal embark drastic bamboo mountain loyal category cancel animal embark drastic bamboo mountain loyal category cancel animal embark",
            "efjprum3peosirjsilqv6lvlns3476t3njpngaexsyhangeb3mja",
        ),
    ];

    #[test]
    fn legacy_and_word_phrases_restore_the_same_account() {
        for (hex_secret, legacy, words, peer) in GOLDEN {
            let secret: [u8; 32] = hex::decode(hex_secret).unwrap().try_into().unwrap();
            let id = Identity::from_secret(&secret);
            assert_eq!(id.peer_id().to_base32(), *peer);
            assert_eq!(id.recovery_phrase(), *words);
            assert_eq!(legacy_phrase(&id), *legacy);
            let a = Identity::from_recovery_phrase(legacy).unwrap();
            let b = Identity::from_recovery_phrase(words).unwrap();
            assert_eq!(a.peer_id(), b.peer_id());
            assert_eq!(a.peer_id().to_base32(), *peer);
            // legacy variants accepted as before: upper case, spaces instead of dashes, no separators
            for v in [legacy.to_uppercase(), legacy.replace('-', " "), legacy.replace('-', "")] {
                assert_eq!(Identity::from_recovery_phrase(&v).unwrap().peer_id(), a.peer_id());
            }
        }
        // random accounts too
        for _ in 0..50 {
            let id = Identity::generate();
            let a = Identity::from_recovery_phrase(&legacy_phrase(&id)).unwrap();
            let b = Identity::from_recovery_phrase(&id.recovery_phrase()).unwrap();
            assert_eq!(a.peer_id(), id.peer_id());
            assert_eq!(b.peer_id(), id.peer_id());
        }
    }

    #[test]
    fn phrase_errors_are_user_errors() {
        let code = |p: &str| {
            let e = Identity::from_recovery_phrase(p).err().expect("rejected");
            crate::i18n::find_user_err(&e).map(|u| (u.key, u.args.clone())).expect("user error")
        };
        let words: Vec<&str> = GOLDEN[0].2.split(' ').collect();
        // messy but valid: case, newlines, numbering, prefixes
        let messy: String = words.iter().enumerate().map(|(i, w)| format!("{}. {}\n", i + 1, &w[..w.len().min(4)].to_uppercase())).collect();
        assert_eq!(Identity::from_recovery_phrase(&messy).unwrap().peer_id().to_base32(), GOLDEN[0].3);
        let mut w = words.clone();
        w[6] = "lumora";
        let (k, args) = code(&w.join(" "));
        assert_eq!(k, "err.phrase_word");
        assert_eq!(args, vec![("n", "7".to_string())]);
        let mut w = words.clone();
        w.swap(2, 3);
        assert_eq!(code(&w.join(" ")).0, "err.phrase_checksum");
        assert_eq!(code(&words[..12].join(" ")).0, "err.phrase_count");
        // a damaged legacy phrase keeps the legacy message
        let damaged = GOLDEN[0].1.replacen("aebag", "aebah", 1);
        assert_eq!(code(&damaged).0, "err.bad_recovery_phrase");
        assert_eq!(code(&GOLDEN[0].1[..64]).0, "err.bad_recovery_phrase");
    }
}
