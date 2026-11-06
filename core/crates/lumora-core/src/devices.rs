//! Multi-device identity (pure, no I/O). Design: docs/src/dev/multi-device.md.
//!
//! * The **account** is the existing Ed25519 identity (its public key is the `PeerId`
//!   friends know). Its secret stays on the **primary** device, whose device key *is* the
//!   account key, so every existing install is a primary and old peers keep working.
//! * A **secondary** device has its own key and a [`DeviceCert`] signed by the account.
//!   Content it signs carries a 170-byte [`DevSig`](sign_dev) inside the existing
//!   `sig: Vec<u8>` fields (no wire struct changes): old verifiers simply reject it.
//! * The account publishes a [`SignedDeviceList`] (root-signed, versioned) so friends
//!   know which devices to deliver to and which ones were revoked.
//! * Linking a new device uses a QR payload ([`LinkQr`]) or a 12-digit code
//!   (SPAKE2, [`code_*`](parse_code)) — helpers live here, the protocol in `node/link.rs`.

use crate::identity::{Identity, PeerId};
use anyhow::{anyhow, bail, Result};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;

pub const CAP_PRIMARY: u8 = 1;
pub const CAP_REMOTE_HOST: u8 = 2;
pub const CAP_CALLS: u8 = 4;
pub const MAX_DEVICES: usize = 8;
pub const MAX_REVOKED: usize = 32;
pub const DEVSIG_TAG: u8 = 0xD1;
pub const DEVSIG_LEN: usize = 170;
/// Device kinds shown in the UI.
pub const KIND_PHONE: u8 = 1;
pub const KIND_TABLET: u8 = 2;
pub const KIND_DESKTOP: u8 = 3;
pub const KIND_CLI: u8 = 4;

/// "Device `device` belongs to `account`", signed by the account (root) key.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceCert {
    pub account: PeerId,
    pub device: PeerId,
    pub created: u64,
    pub caps: u8,
    #[serde(with = "serde_bytes")]
    pub sig: Vec<u8>,
}

fn cert_bytes(account: &PeerId, device: &PeerId, created: u64, caps: u8) -> Vec<u8> {
    let mut v = b"lumora-devcert-v1".to_vec();
    v.extend_from_slice(&account.0);
    v.extend_from_slice(&device.0);
    v.extend_from_slice(&created.to_le_bytes());
    v.push(caps);
    v
}

impl DeviceCert {
    pub fn issue(root: &Identity, device: PeerId, created: u64, caps: u8) -> DeviceCert {
        let account = root.peer_id();
        let sig = root.sign(&cert_bytes(&account, &device, created, caps)).to_vec();
        DeviceCert { account, device, created, caps, sig }
    }
    pub fn verify(&self) -> bool {
        self.sig.len() == 64 && self.device != self.account && self.account.verify(&cert_bytes(&self.account, &self.device, self.created, self.caps), &self.sig)
    }
    pub fn encode(&self) -> Vec<u8> {
        rmp_serde::to_vec_named(self).unwrap_or_default()
    }
    pub fn decode(b: &[u8]) -> Result<DeviceCert> {
        Ok(rmp_serde::from_slice(b)?)
    }
    /// Value of the extra X.509 SAN URI carried by a secondary's TLS certificate.
    pub fn to_san(&self) -> String {
        format!("lumora:devcert:v1:{}", data_encoding::BASE32_NOPAD.encode(&self.encode()).to_lowercase())
    }
    pub fn from_san(s: &str) -> Option<DeviceCert> {
        let b = s.strip_prefix("lumora:devcert:v1:")?;
        let raw = data_encoding::BASE32_NOPAD.decode(b.to_uppercase().as_bytes()).ok()?;
        DeviceCert::decode(&raw).ok()
    }
}

/// Device signature: `0xD1 ‖ device ‖ cert.created ‖ cert.caps ‖ cert.sig ‖ device sig`.
/// The certificate is self-contained, so a verifier needs nothing but the author's
/// account key — even for a device whose list it hasn't fetched yet.
pub fn sign_dev(dev: &Identity, cert: &DeviceCert, msg: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(DEVSIG_LEN);
    v.push(DEVSIG_TAG);
    v.extend_from_slice(&cert.device.0);
    v.extend_from_slice(&cert.created.to_le_bytes());
    v.push(cert.caps);
    v.extend_from_slice(&cert.sig);
    v.extend_from_slice(&dev.sign(msg));
    v
}

/// Who signed a verified signature.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SigBy {
    /// The account key itself (the primary device, or any pre-multi-device peer).
    Account,
    /// A secondary device with its certificate.
    Device { device: PeerId, cert: DeviceCert },
}

/// Parse the certificate embedded in a DevSig (not verified).
pub fn devsig_cert(author: &PeerId, sig: &[u8]) -> Option<DeviceCert> {
    if sig.len() != DEVSIG_LEN || sig[0] != DEVSIG_TAG {
        return None;
    }
    Some(DeviceCert {
        account: *author,
        device: PeerId(sig[1..33].try_into().ok()?),
        created: u64::from_le_bytes(sig[33..41].try_into().ok()?),
        caps: sig[41],
        sig: sig[42..106].to_vec(),
    })
}

/// Verify a content signature by `author` (an account): a plain 64-byte account
/// signature or a DevSig with a valid certificate. Pure: revocation is checked by the node.
pub fn verify_by(author: &PeerId, msg: &[u8], sig: &[u8]) -> Option<SigBy> {
    if sig.len() == 64 {
        return author.verify(msg, sig).then_some(SigBy::Account);
    }
    let cert = devsig_cert(author, sig)?;
    if !cert.verify() || !cert.device.verify(msg, &sig[106..170]) {
        return None;
    }
    Some(SigBy::Device { device: cert.device, cert })
}

/// The device that produced `sig` (the author itself for a 64-byte signature). Only
/// meaningful after [`verify_by`] succeeded.
pub fn signer_device(author: &PeerId, sig: &[u8]) -> PeerId {
    devsig_cert(author, sig).map(|c| c.device).unwrap_or(*author)
}

/// Signs content as the account: plain signatures on the primary, DevSig elsewhere.
#[derive(Clone)]
pub struct Signer {
    id: Identity,
    account: PeerId,
    cert: Option<DeviceCert>,
}

impl Signer {
    pub fn primary(id: &Identity) -> Signer {
        Signer { id: id.clone(), account: id.peer_id(), cert: None }
    }
    pub fn secondary(id: &Identity, cert: DeviceCert) -> Result<Signer> {
        anyhow::ensure!(cert.device == id.peer_id() && cert.verify(), "device certificate does not match this device");
        Ok(Signer { id: id.clone(), account: cert.account, cert: Some(cert) })
    }
    pub fn sign(&self, msg: &[u8]) -> Vec<u8> {
        match &self.cert {
            None => self.id.sign(msg).to_vec(),
            Some(c) => sign_dev(&self.id, c, msg),
        }
    }
    pub fn account(&self) -> PeerId {
        self.account
    }
    pub fn device(&self) -> PeerId {
        self.id.peer_id()
    }
    pub fn cert(&self) -> Option<&DeviceCert> {
        self.cert.as_ref()
    }
    pub fn is_primary(&self) -> bool {
        self.cert.is_none()
    }
}

// ------------------------------------------------------------------ device lists

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct DeviceEntry {
    pub device: PeerId,
    /// ≤ 32 chars
    #[serde(default)]
    pub name: String,
    /// [`KIND_PHONE`] … [`KIND_CLI`]
    #[serde(default)]
    pub kind: u8,
    #[serde(default)]
    pub caps: u8,
    #[serde(default)]
    pub added: u64,
    /// The device's acceptance: its own signature over [`accept_bytes`]`(account, device)`
    /// — proof that the device agreed to belong to this account (the list signature only
    /// proves the account claims it). Not needed for the account's own key. Lists from
    /// before proofs existed lack it (encoded identically when empty).
    #[serde(default, with = "serde_bytes", skip_serializing_if = "Vec::is_empty")]
    pub proof: Vec<u8>,
}

impl DeviceEntry {
    pub fn new(device: PeerId, name: impl Into<String>, kind: u8, caps: u8, added: u64) -> DeviceEntry {
        DeviceEntry { device, name: name.into(), kind, caps, added, proof: vec![] }
    }

    /// Is this entry proven to belong to `account` by the device itself?
    pub fn proven_for(&self, account: &PeerId) -> bool {
        self.device == *account || verify_accept(account, &self.device, &self.proof)
    }
}

fn accept_bytes(account: &PeerId, device: &PeerId) -> Vec<u8> {
    let mut v = b"lumora-devaccept-v1".to_vec();
    v.extend_from_slice(&account.0);
    v.extend_from_slice(&device.0);
    v
}

/// A device's signature saying "I am a device of `account`" (goes into its list entry).
pub fn sign_accept(dev: &Identity, account: &PeerId) -> Vec<u8> {
    dev.sign(&accept_bytes(account, &dev.peer_id())).to_vec()
}

pub fn verify_accept(account: &PeerId, device: &PeerId, proof: &[u8]) -> bool {
    proof.len() == 64 && device.verify(&accept_bytes(account, device), proof)
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Revoked {
    pub device: PeerId,
    /// list version that revoked it
    pub at: u64,
    #[serde(default)]
    pub wipe: bool,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct DeviceListBody {
    pub v: u8,
    pub account: PeerId,
    pub version: u64,
    #[serde(default)]
    pub devices: Vec<DeviceEntry>,
    #[serde(default)]
    pub revoked: Vec<Revoked>,
}

impl DeviceListBody {
    pub fn is_active(&self, d: &PeerId) -> bool {
        self.devices.iter().any(|e| e.device == *d)
    }
    pub fn is_revoked(&self, d: &PeerId) -> bool {
        self.revoked.iter().any(|r| r.device == *d)
    }
}

/// The account's device list: the signature covers the stored body bytes (never a
/// re-encoded struct), `b"lumora-devlist-v1" ‖ body`.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct SignedDeviceList {
    #[serde(with = "serde_bytes")]
    pub body: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub sig: Vec<u8>,
}

fn list_signing_bytes(body: &[u8]) -> Vec<u8> {
    let mut v = b"lumora-devlist-v1".to_vec();
    v.extend_from_slice(body);
    v
}

impl SignedDeviceList {
    pub fn sign(root: &Identity, body: &DeviceListBody) -> Result<SignedDeviceList> {
        anyhow::ensure!(body.account == root.peer_id(), "only the account key signs its device list");
        let b = rmp_serde::to_vec_named(body)?;
        let sig = root.sign(&list_signing_bytes(&b)).to_vec();
        let l = SignedDeviceList { body: b, sig };
        l.validate()?;
        Ok(l)
    }

    /// Signature + structure checks (not freshness: see [`Self::newer_than`]).
    pub fn validate(&self) -> Result<DeviceListBody> {
        let b: DeviceListBody = rmp_serde::from_slice(&self.body)?;
        if !b.account.verify(&list_signing_bytes(&self.body), &self.sig) {
            bail!("device list signature invalid");
        }
        if b.v != 1 {
            bail!("unsupported device list version");
        }
        if b.devices.is_empty() || b.devices.len() > MAX_DEVICES || b.revoked.len() > MAX_REVOKED {
            bail!("device list size out of range");
        }
        let mut seen = std::collections::HashSet::new();
        for e in &b.devices {
            if !seen.insert(e.device) {
                bail!("duplicate device in list");
            }
            if b.is_revoked(&e.device) {
                bail!("device both active and revoked");
            }
            if e.device == b.account && e.caps & CAP_PRIMARY == 0 {
                bail!("account device must be primary");
            }
            if e.name.chars().count() > 32 {
                bail!("device name too long");
            }
        }
        Ok(b)
    }

    pub fn digest(&self) -> [u8; 32] {
        *blake3::hash(&self.body).as_bytes()
    }

    /// Does this list replace a cached one with `(version, digest)`? Strictly newer
    /// version wins; two lists with the same version: the larger body hash wins.
    pub fn newer_than(&self, version: u64, cached: Option<(u64, [u8; 32])>) -> bool {
        match cached {
            None => true,
            Some((v, d)) => version > v || (version == v && self.digest() > d),
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        rmp_serde::to_vec_named(self).unwrap_or_default()
    }
    pub fn decode(b: &[u8]) -> Result<SignedDeviceList> {
        Ok(rmp_serde::from_slice(b)?)
    }
}

// ------------------------------------------------------------------ linking helpers

/// Payload of a link QR code (`lumora://link/<base32>`): shown by the new device (scanned
/// by the main device), or by the main device as an invitation (`i`, scanned by the new one).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct LinkQr {
    pub v: u8,
    /// the new device's key
    pub d: PeerId,
    /// 32-byte one-time secret
    #[serde(with = "serde_bytes")]
    pub s: Vec<u8>,
    /// where it can be dialed (≤ 4)
    #[serde(default)]
    pub a: Vec<SocketAddr>,
    /// relays it uses (≤ 2)
    #[serde(default)]
    pub r: Vec<String>,
    #[serde(default)]
    pub n: String,
    #[serde(default)]
    pub k: u8,
    /// expiry (ms since epoch)
    #[serde(default)]
    pub e: u64,
    /// Invitation shown by an existing device (`d` is that device): the new device scans it.
    #[serde(default)]
    pub i: bool,
}

pub const LINK_QR_PREFIX: &str = "lumora://link/";

impl LinkQr {
    pub fn to_uri(&self) -> String {
        format!("{LINK_QR_PREFIX}{}", data_encoding::BASE32_NOPAD.encode(&rmp_serde::to_vec_named(self).unwrap_or_default()).to_lowercase())
    }
    pub fn parse(uri: &str) -> Result<LinkQr> {
        let b = uri.trim().strip_prefix(LINK_QR_PREFIX).ok_or_else(|| anyhow!("not a link code"))?;
        let raw = data_encoding::BASE32_NOPAD.decode(b.to_uppercase().as_bytes())?;
        let q: LinkQr = rmp_serde::from_slice(&raw)?;
        anyhow::ensure!(q.v == 1 && q.s.len() == 32, "unsupported link code");
        Ok(q)
    }
}

/// 12 random digits shown as `rrrr-pppp-pppp`. The first 6 only find the other device
/// (rendezvous: 10⁶ buckets, so concurrent links rarely share one); all 12 are the SPAKE2
/// password. What is published can be ground offline to at most those 6 digits: the 6
/// others (10⁶) stay for the online PAKE, one guess per attempt and a new code after 3
/// failures.
pub fn new_code() -> String {
    let n: u64 = rand::random::<u64>() % 1_000_000_000_000;
    let s = format!("{n:012}");
    format!("{}-{}-{}", &s[..4], &s[4..8], &s[8..])
}

/// Normalise a typed code to its 12 digits (spaces/dashes ignored).
pub fn parse_code(s: &str) -> Result<String> {
    let d: String = s.chars().filter(|c| !c.is_whitespace() && *c != '-' && *c != '.').collect();
    anyhow::ensure!(d.len() == 12 && d.chars().all(|c| c.is_ascii_digit()), "a link code has 12 digits");
    Ok(d)
}

/// Digits of the code that make up its rendezvous id.
pub const RENDEZVOUS_DIGITS: usize = 6;

/// Rendezvous id of a code (its first [`RENDEZVOUS_DIGITS`] digits): Nostr tag / LAN beacon id.
pub fn code_rendezvous(digits: &str) -> [u8; 32] {
    blake3::derive_key("lumora link rv v2", digits.get(..RENDEZVOUS_DIGITS).unwrap_or("").as_bytes())
}

/// Link pre-authentication over sealed signaling (before either side reveals an address):
/// QR path — proof that the sender saw the QR secret, bound to both devices, the session
/// nonce and the direction (`tag`).
pub fn pre_qr_proof(secret: &[u8], holder: &PeerId, scanner: &PeerId, nonce: &[u8], tag: &[u8]) -> [u8; 32] {
    let key: [u8; 32] = blake3::derive_key("lumora link pre qr v1", secret);
    let mut h = blake3::Hasher::new_keyed(&key);
    h.update(&holder.0);
    h.update(&scanner.0);
    h.update(nonce);
    h.update(tag);
    *h.finalize().as_bytes()
}

/// Code path pre-authentication: the confirmation MACs of a SPAKE2 run over signaling
/// (roles 11 = holder, 12 = scanner, 13 = holder's final OK), bound to the session nonce.
pub fn pre_pake_confirm(key: &[u8; 32], role: u8, holder: &PeerId, scanner: &PeerId, nonce: &[u8]) -> [u8; 32] {
    pake_confirm(key, role, holder, scanner, &blake3::derive_key("lumora link pre ctx v1", nonce))
}

/// QR path: the existing device proves it saw the QR secret, bound to this TLS channel.
pub fn qr_proof(secret: &[u8], new_dev: &PeerId, existing_dev: &PeerId, account: &PeerId, exporter: &[u8; 32]) -> [u8; 32] {
    let key: [u8; 32] = blake3::derive_key("lumora link qr key v1", secret);
    let mut h = blake3::Hasher::new_keyed(&key);
    h.update(b"lumora-link-qr-v1");
    h.update(&new_dev.0);
    h.update(&existing_dev.0);
    h.update(&account.0);
    h.update(exporter);
    *h.finalize().as_bytes()
}

/// Code path: start SPAKE2 (symmetric) with all 12 digits. Returns (state, outbound msg).
pub fn pake_start(digits: &str) -> (spake2::Spake2<spake2::Ed25519Group>, Vec<u8>) {
    spake2::Spake2::<spake2::Ed25519Group>::start_symmetric(&spake2::Password::new(digits.as_bytes()), &spake2::Identity::new(b"lumora-link-v1"))
}

/// Finish SPAKE2 → shared key (both sides agree only if the codes matched).
pub fn pake_finish(state: spake2::Spake2<spake2::Ed25519Group>, inbound: &[u8]) -> Result<[u8; 32]> {
    let k = state.finish(inbound).map_err(|e| anyhow!("pake: {e:?}"))?;
    Ok(blake3::derive_key("lumora link pake key v1", &k))
}

/// Key confirmation MAC, bound to the role, both devices and the TLS channel.
pub fn pake_confirm(key: &[u8; 32], role: u8, new_dev: &PeerId, existing_dev: &PeerId, exporter: &[u8; 32]) -> [u8; 32] {
    let mut h = blake3::Hasher::new_keyed(key);
    h.update(b"lumora-link-confirm-v1");
    h.update(&[role]);
    h.update(&new_dev.0);
    h.update(&existing_dev.0);
    h.update(exporter);
    *h.finalize().as_bytes()
}

/// Constant-time 32-byte comparison.
pub fn ct_eq32(a: &[u8; 32], b: &[u8]) -> bool {
    b.len() == 32 && a.iter().zip(b.iter()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pair() -> (Identity, Identity, DeviceCert) {
        let root = Identity::generate();
        let dev = Identity::generate();
        let cert = DeviceCert::issue(&root, dev.peer_id(), 1000, CAP_CALLS);
        (root, dev, cert)
    }

    #[test]
    fn cert_issue_verify_and_san_roundtrip() {
        let (root, dev, cert) = pair();
        assert!(cert.verify());
        assert_eq!(cert.account, root.peer_id());
        let back = DeviceCert::from_san(&cert.to_san()).unwrap();
        assert_eq!(back, cert);
        let mut bad = cert.clone();
        bad.caps |= CAP_PRIMARY;
        assert!(!bad.verify(), "caps are signed");
        let mut other = cert.clone();
        other.device = Identity::generate().peer_id();
        assert!(!other.verify());
        // a "cert" for the account key itself is meaningless
        assert!(!DeviceCert::issue(&root, root.peer_id(), 1, 0).verify());
        let _ = dev;
    }

    #[test]
    fn devsig_verifies_and_rejects_tampering() {
        let (root, dev, cert) = pair();
        let signer = Signer::secondary(&dev, cert.clone()).unwrap();
        let msg = b"lumora-chat-v1 hello";
        let sig = signer.sign(msg);
        assert_eq!(sig.len(), DEVSIG_LEN);
        let a = root.peer_id();
        assert_eq!(verify_by(&a, msg, &sig), Some(SigBy::Device { device: dev.peer_id(), cert: cert.clone() }));
        assert_eq!(signer_device(&a, &sig), dev.peer_id());
        // tampered content
        assert!(verify_by(&a, b"lumora-chat-v1 hellO", &sig).is_none());
        // cert for a different account
        let other = Identity::generate();
        assert!(verify_by(&other.peer_id(), msg, &sig).is_none());
        // wrong cert (signed by someone else for this device)
        let forged = DeviceCert::issue(&other, dev.peer_id(), 1000, CAP_CALLS);
        let fsig = sign_dev(&dev, &forged, msg);
        assert!(verify_by(&a, msg, &fsig).is_none());
        // tampered cert fields inside the DevSig
        let mut t = sig.clone();
        t[41] ^= 1;
        assert!(verify_by(&a, msg, &t).is_none());
        // plain 64-byte signatures still verify (primary / old peers)
        let p = Signer::primary(&root);
        let s64 = p.sign(msg);
        assert_eq!(s64.len(), 64);
        assert_eq!(verify_by(&a, msg, &s64), Some(SigBy::Account));
        assert_eq!(signer_device(&a, &s64), a);
        // old verifiers reject a DevSig cleanly
        assert!(!a.verify(msg, &sig));
        // a signer refuses a cert for another device
        assert!(Signer::secondary(&Identity::generate(), cert).is_err());
    }

    fn body(root: &Identity, version: u64, devs: &[(PeerId, u8)], revoked: &[PeerId]) -> DeviceListBody {
        DeviceListBody {
            v: 1,
            account: root.peer_id(),
            version,
            devices: devs.iter().map(|(d, caps)| DeviceEntry::new(*d, "x", KIND_CLI, *caps, 1)).collect(),
            revoked: revoked.iter().map(|d| Revoked { device: *d, at: version, wipe: false }).collect(),
        }
    }

    #[test]
    fn device_list_validation() {
        let (root, dev, _) = pair();
        let a = root.peer_id();
        let l = SignedDeviceList::sign(&root, &body(&root, 2, &[(a, CAP_PRIMARY), (dev.peer_id(), 0)], &[])).unwrap();
        let b = l.validate().unwrap();
        assert!(b.is_active(&dev.peer_id()));
        assert_eq!(SignedDeviceList::decode(&l.encode()).unwrap(), l);
        // replayed lower version / tie-break
        assert!(l.newer_than(2, Some((1, [0; 32]))));
        assert!(!l.newer_than(2, Some((3, [0; 32]))));
        assert!(l.newer_than(2, None));
        assert_eq!(l.newer_than(2, Some((2, [0; 32]))), l.digest() > [0; 32]);
        assert!(!l.newer_than(2, Some((2, l.digest()))), "the same list is not newer than itself");
        // duplicate device
        assert!(SignedDeviceList::sign(&root, &body(&root, 3, &[(a, CAP_PRIMARY), (a, CAP_PRIMARY)], &[])).is_err());
        // more than 8 devices
        let many: Vec<(PeerId, u8)> = (0..9).map(|_| (Identity::generate().peer_id(), 0)).collect();
        assert!(SignedDeviceList::sign(&root, &body(&root, 3, &many, &[])).is_err());
        // active and revoked at once
        assert!(SignedDeviceList::sign(&root, &body(&root, 3, &[(a, CAP_PRIMARY), (dev.peer_id(), 0)], &[dev.peer_id()])).is_err());
        // the account device must carry CAP_PRIMARY
        assert!(SignedDeviceList::sign(&root, &body(&root, 3, &[(a, 0)], &[])).is_err());
        // someone else can't sign our list
        let mut forged = l.clone();
        forged.sig = dev.sign(&list_signing_bytes(&l.body)).to_vec();
        assert!(forged.validate().is_err());
        assert!(SignedDeviceList::sign(&dev, &body(&root, 3, &[(a, CAP_PRIMARY)], &[])).is_err());
    }

    #[test]
    fn link_qr_and_code_helpers() {
        let q = LinkQr { v: 1, d: PeerId([3; 32]), s: vec![5; 32], a: vec!["192.168.1.2:4000".parse().unwrap()], r: vec![], n: "Laptop".into(), k: KIND_DESKTOP, e: 99, i: false };
        let uri = q.to_uri();
        assert!(uri.starts_with(LINK_QR_PREFIX));
        assert_eq!(LinkQr::parse(&uri).unwrap(), q);
        assert!(LinkQr::parse("lumora://link/zzzz").is_err());
        // an invitation (shown by the main device) keeps its flag; a QR made before the flag
        // existed (no `i` key) reads as a new device's QR
        let inv = LinkQr { i: true, ..q.clone() };
        assert!(LinkQr::parse(&inv.to_uri()).unwrap().i);
        #[derive(Serialize)]
        struct Old {
            v: u8,
            d: PeerId,
            #[serde(with = "serde_bytes")]
            s: Vec<u8>,
        }
        let old = Old { v: 1, d: PeerId([3; 32]), s: vec![5; 32] };
        let uri = format!("{LINK_QR_PREFIX}{}", data_encoding::BASE32_NOPAD.encode(&rmp_serde::to_vec_named(&old).unwrap()).to_lowercase());
        assert!(!LinkQr::parse(&uri).unwrap().i);
        let c = new_code();
        assert_eq!(c.len(), 14);
        let d = parse_code(&c).unwrap();
        assert_eq!(d.len(), 12);
        assert_eq!(parse_code(" 1234 5678-9012 ").unwrap(), "123456789012");
        assert!(parse_code("1234-5678-901").is_err());
        assert!(parse_code("1234-5678-901x").is_err());
        assert_eq!(code_rendezvous("123456999999"), code_rendezvous("123456000000"), "rendezvous uses only the first 6 digits");
        assert_ne!(code_rendezvous("123456999999"), code_rendezvous("123457999999"));
    }

    #[test]
    fn device_acceptance_proofs() {
        let account = Identity::generate();
        let dev = Identity::generate();
        let other = Identity::generate();
        let p = sign_accept(&dev, &account.peer_id());
        let mut e = DeviceEntry::new(dev.peer_id(), "Phone", KIND_PHONE, 0, 1);
        assert!(!e.proven_for(&account.peer_id()), "no proof");
        e.proof = p.clone();
        assert!(e.proven_for(&account.peer_id()));
        assert!(!e.proven_for(&other.peer_id()), "a proof is for one account only");
        // someone else can't make one for this device
        e.proof = sign_accept(&other, &account.peer_id());
        assert!(!e.proven_for(&account.peer_id()));
        // the account's own key needs none
        assert!(DeviceEntry::new(account.peer_id(), "Main", KIND_DESKTOP, CAP_PRIMARY, 1).proven_for(&account.peer_id()));
        // an entry without a proof encodes as before (old lists keep their signatures valid)
        let plain = DeviceEntry::new(dev.peer_id(), "Phone", KIND_PHONE, 0, 1);
        #[derive(Serialize)]
        struct Old {
            device: PeerId,
            name: String,
            kind: u8,
            caps: u8,
            added: u64,
        }
        let old = Old { device: dev.peer_id(), name: "Phone".into(), kind: KIND_PHONE, caps: 0, added: 1 };
        assert_eq!(rmp_serde::to_vec_named(&plain).unwrap(), rmp_serde::to_vec_named(&old).unwrap());
    }

    #[test]
    fn qr_proof_is_bound_to_the_channel() {
        let (n, e, a) = (PeerId([1; 32]), PeerId([2; 32]), PeerId([3; 32]));
        let p = qr_proof(&[7; 32], &n, &e, &a, &[9; 32]);
        assert_eq!(p, qr_proof(&[7; 32], &n, &e, &a, &[9; 32]));
        assert_ne!(p, qr_proof(&[7; 32], &n, &e, &a, &[8; 32]), "another TLS channel → another proof");
        assert_ne!(p, qr_proof(&[6; 32], &n, &e, &a, &[9; 32]));
        assert_ne!(p, qr_proof(&[7; 32], &n, &a, &e, &[9; 32]));
    }

    #[test]
    fn pake_agrees_only_with_the_same_code() {
        let (s1, m1) = pake_start("123456789012");
        let (s2, m2) = pake_start("123456789012");
        let k1 = pake_finish(s1, &m2).unwrap();
        let k2 = pake_finish(s2, &m1).unwrap();
        assert_eq!(k1, k2);
        let (n, e, x) = (PeerId([1; 32]), PeerId([2; 32]), [4u8; 32]);
        assert_eq!(pake_confirm(&k1, 1, &n, &e, &x), pake_confirm(&k2, 1, &n, &e, &x));
        assert_ne!(pake_confirm(&k1, 1, &n, &e, &x), pake_confirm(&k1, 2, &n, &e, &x));
        // a wrong code yields a different key (confirmation fails)
        let (s3, m3) = pake_start("123456789013");
        let (s4, m4) = pake_start("123456789012");
        let k3 = pake_finish(s3, &m4).unwrap_or([0; 32]);
        let k4 = pake_finish(s4, &m3).unwrap_or([1; 32]);
        assert_ne!(k3, k4);
        assert!(ct_eq32(&k1, &k2));
        assert!(!ct_eq32(&k3, &k4));
    }
}
