//! Signing devices out of an account (multi-device Phase 6): revocation by the main device,
//! "sign out this device" from a linked device, remote wipe, and making a linked device the
//! main one with the recovery phrase. Design: docs/src/dev/multi-device.md §1, §5, §10.
//!
//! * `device_revoke` (main device): a new signed device list with a `Revoked` entry. Every
//!   holder of the list then refuses the device (connections closed with "revoked",
//!   content it signs dropped, nothing queued for it); its ratchet sessions are dropped and
//!   group keys rotate (by us where we are admin, else an admin is asked with
//!   `GroupRekeyRequest`), so it can't read what is sent after.
//! * The device itself learns it from the list (live, offline mail, or a sibling closing
//!   the connection with "revoked"): it writes a reset marker, tells the app
//!   (`device_revoked`), and its data is wiped when the core starts next.
//! * `device_promote`: the recovery phrase gives the account key; this device re-wraps its
//!   keystore with it (same database), signs a list where it is the main device and its old
//!   device key is revoked, and restarts as the main device.

use super::*;
use crate::devices::{self as dv, DeviceEntry, Revoked, SignedDeviceList};
use crate::group::{GroupOp, Payload, Role};
use crate::proto::ext;

/// Written into the data folder when this device is signed out; the next start wipes the
/// account's data (keystore + database, and downloads with `wipe_media`).
pub(crate) const RESET_MARKER: &str = "device_reset.json";

#[derive(Serialize, Deserialize, Default)]
pub(super) struct RevokeRequestMsg {
    #[serde(default)]
    pub wipe: bool,
}

#[derive(Serialize, Deserialize, Default)]
pub(super) struct RekeyRequestMsg {
    #[serde(with = "serde_bytes", default)]
    pub gid: Vec<u8>,
    /// the requester's signed device list (proves a device was revoked after the last rekey)
    #[serde(with = "serde_bytes", default)]
    pub list: Vec<u8>,
}

#[derive(Serialize, Deserialize, Default)]
struct ResetMarker {
    #[serde(default)]
    wipe_media: bool,
}

/// Called before the keystore is opened: finish a sign-out (fresh install afterwards).
pub(crate) fn apply_reset_marker(dir: &std::path::Path) {
    let m = dir.join(RESET_MARKER);
    let Ok(raw) = std::fs::read(&m) else { return };
    let marker: ResetMarker = serde_json::from_slice(&raw).unwrap_or_default();
    for f in ["keystore.json", ".device_key", "lumora.db", "lumora.db-wal", "lumora.db-shm"] {
        let _ = std::fs::remove_file(dir.join(f));
    }
    if marker.wipe_media {
        let _ = std::fs::remove_dir_all(dir.join("downloads"));
    }
    let _ = std::fs::remove_file(&m);
    tracing::info!("signed-out device: account data removed, starting fresh");
}

impl Node {
    /// Main device: sign `dev` out of the account (optionally wiping its downloads).
    pub async fn device_revoke(self: &Arc<Self>, dev: &PeerId, wipe: bool) -> Result<Value> {
        anyhow::ensure!(self.is_primary(), crate::i18n::user_err("err.primary_only"));
        anyhow::ensure!(*dev != self.device, crate::i18n::user_err("err.cannot_revoke_self"));
        anyhow::ensure!(self.own_list().map(|b| b.is_active(dev)).unwrap_or(false), crate::i18n::user_err("err.device_not_found"));
        let d = *dev;
        let body = self.publish_own_list(|b| {
            b.devices.retain(|e| e.device != d);
            b.revoked.retain(|r| r.device != d);
            // `at` = the new list version (filled in by `publish_own_list`)
            b.revoked.push(Revoked { device: d, at: 0, wipe });
            while b.revoked.len() > dv::MAX_REVOKED {
                b.revoked.remove(0);
            }
        })?;
        self.forget_revoked(dev);
        // the device itself: the new list (live if connected — `publish_own_list` pushed it
        // already — and as offline mail), then the connection is closed
        if let Some((_, raw)) = self.store.device_list_get(&self.me) {
            let msg = proto::ext(ext::DEVICE_LIST, &super::devices::DeviceListMsg { list: raw });
            if let Ok(sealed) = rmp_serde::to_vec(&PeerMsg::Wrapped { id: crate::crypto::random_bytes(), inner: Box::new(msg) }) {
                let me = self.clone();
                tokio::spawn(async move { me.store_and_forward(d, crate::crypto::random_bytes(), &sealed).await });
            }
        }
        if let Some(pc) = self.peer(dev) {
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_secs(3)).await;
                pc.conn.close(3u32.into(), b"revoked");
            });
        }
        // what is sent from now on must not be readable with keys it holds
        let me = self.clone();
        let version = body.version;
        tokio::spawn(async move { me.rekey_after_revoke(version).await });
        Ok(self.devices_json())
    }

    /// Local cleanup for a revoked device of my account or of a contact.
    pub(super) fn forget_revoked(&self, dev: &PeerId) {
        self.olm_drop_sessions(dev);
        let _ = self.store.forget_device(dev);
    }

    /// Rotate the keys of my groups (where I may), or ask an admin to.
    async fn rekey_after_revoke(self: &Arc<Self>, version: u64) {
        let Some((_, raw)) = self.store.device_list_get(&self.me) else { return };
        let groups: Vec<GroupStateLite> = self
            .groups
            .read()
            .values()
            .filter(|g| g.is_member(&self.me))
            .map(|g| GroupStateLite { gid: g.gid, admin: g.role(&self.me).unwrap_or(Role::Member) >= Role::Admin, owner: g.owner, admins: g.members.iter().filter(|(_, r)| **r >= Role::Admin).map(|(p, _)| *p).collect() })
            .collect();
        for g in groups {
            if g.admin {
                if let Err(e) = self.rotate_key(g.gid).await {
                    tracing::warn!("rekey after revocation: {e:#}");
                }
                continue;
            }
            // one admin is enough (the owner if it is an admin, else the first)
            let target = if g.admins.contains(&g.owner) { Some(g.owner) } else { g.admins.first().copied() };
            if let Some(a) = target.filter(|a| *a != self.me) {
                let m = proto::ext(ext::GROUP_REKEY_REQUEST, &RekeyRequestMsg { gid: g.gid.to_vec(), list: raw.clone() });
                let id: [u8; 16] = crate::crypto::random_bytes();
                self.deliver(a, id, m, true).await;
            }
        }
        tracing::info!("revocation (list v{version}): group keys rotated / requested");
    }

    /// Admin side: a member revoked one of its devices and asks for a new group key.
    pub(super) async fn on_rekey_request(self: &Arc<Self>, from: PeerId, body: &[u8]) -> Result<()> {
        // one rotation per request: only the admin account's main device acts on it
        if !self.is_primary() {
            return Ok(());
        }
        let m: RekeyRequestMsg = proto::ext_body(body)?;
        let gid: Gid = m.gid.as_slice().try_into().map_err(|_| anyhow!("bad gid"))?;
        let Some(st) = self.groups.read().get(&gid).cloned() else { return Ok(()) };
        if !st.is_member(&from) || st.role(&self.me).unwrap_or(Role::Member) < Role::Admin {
            return Ok(());
        }
        let _ = self.accept_device_list(&m.list, from, false);
        let Some(list) = self.store.device_list_get(&from).and_then(|(_, b)| SignedDeviceList::decode(&b).ok()).and_then(|l| l.validate().ok()) else {
            return Ok(());
        };
        // only if a device was revoked after the key of the current epoch was made
        let last_rekey = st
            .ops
            .iter()
            .filter_map(|o| match &o.payload {
                Payload::Op(GroupOp::Rekey { epoch, .. }) if *epoch == st.epoch => Some(o.hlc),
                _ => None,
            })
            .max()
            .unwrap_or(st.created);
        if !list.revoked.iter().any(|r| r.at > last_rekey) {
            return Ok(());
        }
        // at most once a minute per group
        let k = format!("rekey.last.{}", hex::encode(gid));
        let last: u64 = self.store.kv_get(&k).and_then(|v| v.try_into().ok()).map(u64::from_le_bytes).unwrap_or(0);
        if now_ms().saturating_sub(last) < 60_000 {
            return Ok(());
        }
        self.store.kv_set(&k, &now_ms().to_le_bytes())?;
        tracing::info!("rotating the key of {} after a member revoked a device", hex::encode(gid));
        self.rotate_key(gid).await
    }

    /// Linked device: sign this device out (the main device is asked to revoke it).
    pub async fn device_logout(self: &Arc<Self>) -> Result<Value> {
        anyhow::ensure!(!self.is_primary(), crate::i18n::user_err("err.primary_logout"));
        let msg = proto::ext(ext::DEVICE_REVOKE_REQUEST, &RevokeRequestMsg { wipe: false });
        let primary = self.me;
        let notified = match tokio::time::timeout(Duration::from_secs(6), self.connect(primary)).await {
            Ok(Ok(pc)) => pc.ctl.send(msg.clone()).await.is_ok(),
            _ => false,
        };
        if !notified {
            // offline: the request travels as mail (this device's queue is about to go)
            if let Ok(p) = rmp_serde::to_vec(&PeerMsg::Wrapped { id: crate::crypto::random_bytes(), inner: Box::new(msg) }) {
                self.store_and_forward(primary, crate::crypto::random_bytes(), &p).await;
            }
        } else {
            tokio::time::sleep(Duration::from_millis(400)).await; // let the frame leave
        }
        self.self_revoke(false, true);
        Ok(json!({"notified": notified}))
    }

    /// Main device: one of my devices asks to be signed out.
    pub(super) async fn on_revoke_request(self: &Arc<Self>, dev: PeerId, body: &[u8]) -> Result<()> {
        let m: RevokeRequestMsg = proto::ext_body(body).unwrap_or_default();
        if !self.is_primary() || dev == self.device || !self.own_list().map(|b| b.is_active(&dev)).unwrap_or(false) {
            return Ok(());
        }
        tracing::info!("device {dev:?} signed itself out");
        self.device_revoke(&dev, m.wipe).await.map(|_| ())
    }

    /// This device is no longer part of the account: remember to wipe, tell the app.
    pub(crate) fn self_revoke(&self, wipe: bool, by_self: bool) {
        if self.store.kv_get("device.signed_out").is_some() {
            return;
        }
        let _ = self.store.kv_set("device.signed_out", b"1");
        if wipe {
            let dl = self.downloads_dir();
            for p in self.store.file_paths() {
                let p = std::path::PathBuf::from(p);
                if p.starts_with(&dl) || p.starts_with(&self.cfg.data_dir) {
                    let _ = std::fs::remove_file(&p);
                }
            }
        }
        let marker = serde_json::to_vec(&ResetMarker { wipe_media: wipe }).unwrap_or_default();
        let _ = crate::keystore::write_private(&self.cfg.data_dir.join(RESET_MARKER), &marker);
        tracing::warn!("this device was signed out of the account (wipe: {wipe})");
        self.emit("device_revoked", json!({"device": self.device.to_base32(), "wipe": wipe, "by_self": by_self, "restart": true}));
    }

    /// Linked device + recovery phrase → this device becomes the main device.
    pub async fn device_promote(self: &Arc<Self>, phrase: &str, passphrase: Option<&str>) -> Result<Value> {
        anyhow::ensure!(!self.is_primary(), crate::i18n::user_err("err.already_primary"));
        let root = Identity::from_recovery_phrase(phrase).map_err(|e| crate::i18n::or_user(e, "err.bad_phrase"))?;
        anyhow::ensure!(root.peer_id() == self.me, crate::i18n::user_err("err.phrase_mismatch"));
        let unlocked = crate::keystore::unlock(&self.cfg.data_dir, passphrase)?;
        let mut body = self.own_list().ok_or_else(|| crate::i18n::user_err("err.data_corrupt").detail("device list missing"))?;
        let old = self.device;
        let mine = body.devices.iter().find(|e| e.device == old).cloned();
        let kind = mine.as_ref().map(|e| e.kind).unwrap_or_else(super::devices::default_device_kind);
        let name = mine.map(|e| e.name).unwrap_or_else(super::devices::default_device_name);
        let now = now_ms();
        body.devices.retain(|e| e.device != old && e.device != self.me);
        body.devices.insert(0, DeviceEntry::new(self.me, name.clone(), kind, dv::CAP_PRIMARY | super::devices::caps_for(kind), now));
        body.version = (body.version + 1).max(self.hlc.tick());
        body.revoked.retain(|r| r.device != old && r.device != self.me);
        body.revoked.push(Revoked { device: old, at: body.version, wipe: false });
        while body.revoked.len() > dv::MAX_REVOKED {
            body.revoked.remove(0);
        }
        let l = SignedDeviceList::sign(&root, &body)?;
        // everything that depended on the old device key
        self.store.device_list_put(&l.encode(), &body)?;
        for k in ["account.role", "account.cert", "account.id"] {
            self.store.kv_del(k)?;
        }
        self.store.kv_set("device.name", name.as_bytes())?;
        self.store.kv_set("devices.push_pending", b"1")?;
        self.store.kv_del_prefix("olm.")?;
        // same database, now opened by the account key
        let pass = passphrase.filter(|p| !p.is_empty() && unlocked.protection == "passphrase");
        crate::keystore::create_with_db_key(&self.cfg.data_dir, &root, pass, unlocked.db_key.clone())?;
        tracing::info!("promoted to main device — restarting");
        self.emit("link_state", json!({"state": "restart", "reason": "promoted", "account": self.me.to_base32()}));
        Ok(json!({"promoted": true}))
    }

    /// After a promotion: tell my other devices about the list where I am the main device.
    pub(super) fn push_list_after_promote(self: &Arc<Self>) {
        if !self.is_primary() || self.store.kv_get("devices.push_pending").is_none() {
            return;
        }
        let me = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(2)).await;
            if let Some(l) = me.store.device_list_get(&me.me).and_then(|(_, b)| SignedDeviceList::decode(&b).ok()) {
                me.push_own_list(&l);
                let _ = me.store.kv_del("devices.push_pending");
            }
        });
    }
}

struct GroupStateLite {
    gid: Gid,
    admin: bool,
    owner: PeerId,
    admins: Vec<PeerId>,
}
