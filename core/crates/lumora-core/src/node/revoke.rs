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

#[derive(Serialize, Deserialize)]
struct ResetMarker {
    #[serde(default)]
    wipe_media: bool,
    /// The user signed this device out here (not the main device / another main device).
    #[serde(default)]
    by_self: bool,
    /// Signed out without anyone asking for a wipe (e.g. another device became the main
    /// device): the account's files are moved aside to `<data_dir>.signed-out-<unix time>`
    /// instead of being deleted, so nothing is lost if it happened by mistake. Missing (a
    /// marker from an older version) or a damaged marker: kept too, unless a wipe was asked.
    #[serde(default = "keep_by_default")]
    keep: bool,
}

fn keep_by_default() -> bool {
    true
}

/// Called before the keystore is opened when a new account is being made here: finish a
/// sign-out (fresh install afterwards). Files are deleted only when the sign-out asked for
/// it; otherwise they are kept aside (see [`ResetMarker::keep`]).
pub(crate) fn apply_reset_marker(dir: &std::path::Path) {
    let m = dir.join(RESET_MARKER);
    let Ok(raw) = std::fs::read(&m) else { return };
    let marker: ResetMarker = serde_json::from_slice(&raw).unwrap_or(ResetMarker { wipe_media: false, by_self: false, keep: true });
    let files = ["keystore.json", ".device_key", "lumora.db", "lumora.db-wal", "lumora.db-shm"];
    if marker.keep && !marker.wipe_media {
        let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let mut aside = dir.as_os_str().to_owned();
        aside.push(format!(".signed-out-{secs}"));
        let aside = std::path::PathBuf::from(aside);
        if let Err(e) = std::fs::create_dir_all(&aside) {
            // never delete what could not be kept: leave everything as it is
            tracing::warn!("signed-out device: cannot keep the old data aside ({e}); leaving it in place");
            return;
        }
        restrict_to_owner(&aside, true);
        for f in files {
            let from = dir.join(f);
            if from.exists() {
                if let Err(e) = std::fs::rename(&from, aside.join(f)) {
                    tracing::warn!("signed-out device: cannot move {f} aside ({e}); leaving the data in place");
                    return;
                }
            }
        }
        let _ = std::fs::remove_file(&m);
        tracing::info!("signed-out device: account data kept aside in {}, starting fresh", aside.display());
        return;
    }
    for f in files {
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
    pub(super) async fn rekey_after_revoke(self: &Arc<Self>, version: u64) {
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

    /// Sign this device out. A linked device asks the main device to revoke it; the main device
    /// (only with `primary_ok`, after the user confirmed they kept the 24-word recovery phrase)
    /// simply forgets the account here, so someone else can sign in on this machine. Linked
    /// devices keep working and one of them can become the main device with the phrase.
    /// With a password-protected install, [passphrase] must be that password (someone who just
    /// picks up an unlocked phone can't wipe the account from it).
    /// With [wipe] ("Delete account"), this device's downloads are deleted too and a linked
    /// device asks the main device to revoke it with a media wipe.
    pub async fn device_logout(self: &Arc<Self>, primary_ok: bool, passphrase: Option<String>, wipe: bool) -> Result<Value> {
        let dir = self.cfg.data_dir.clone();
        if crate::keystore::needs_passphrase(&dir) {
            let pass = passphrase.filter(|p| !p.is_empty()).ok_or_else(|| crate::i18n::user_err("err.wrong_passphrase"))?;
            tokio::task::spawn_blocking(move || crate::keystore::unlock(&dir, Some(&pass)).map(|_| ())).await??;
        }
        if self.is_primary() {
            anyhow::ensure!(primary_ok, crate::i18n::user_err("err.primary_logout"));
            tracing::info!("main device signed out by its user (wipe: {wipe})");
            self.self_revoke(wipe, true);
            return Ok(json!({"notified": true}));
        }
        let msg = proto::ext(ext::DEVICE_REVOKE_REQUEST, &RevokeRequestMsg { wipe });
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
        self.self_revoke(wipe, true);
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
        // a sign-out nobody on this device asked for and that wipes nothing (another device
        // became the main device, the main device dropped this one): keep the data aside
        let marker = serde_json::to_vec(&ResetMarker { wipe_media: wipe, by_self, keep: !wipe && !by_self }).unwrap_or_default();
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

/// Regression (Android, password-protected install): a device signed out in the background
/// came back on the lock screen; the password typed there finished the sign-out and created
/// a brand-new account, so friends, chats and settings looked gone.
#[cfg(test)]
mod reset_tests {
    use super::*;

    fn cfg(tmp: &std::path::Path, open_existing: bool) -> NodeConfig {
        NodeConfig {
            data_dir: tmp.join("data"),
            downloads_dir: Some(tmp.join("dl")),
            passphrase: Some("mật khẩu".into()),
            enable_lan: false,
            enable_upnp: false,
            enable_dht: false,
            enable_nostr: false,
            relays: Some(vec![]),
            nostr: Some(vec![]),
            stun: Some(vec![]),
            open_existing,
            ..Default::default()
        }
    }

    fn err_key(e: &anyhow::Error) -> &'static str {
        crate::i18n::find_user_err(e).map(|u| u.key).unwrap_or("")
    }

    async fn stop(n: Arc<Node>) {
        n.shutdown();
        drop(n);
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    fn aside_dirs(tmp: &std::path::Path) -> Vec<std::path::PathBuf> {
        std::fs::read_dir(tmp)
            .unwrap()
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("data.signed-out-")))
            .collect()
    }

    #[tokio::test]
    async fn unlock_never_turns_a_signed_out_account_into_a_new_one() {
        let tmp = tempfile::tempdir().unwrap();
        let n = Node::start(cfg(tmp.path(), false)).await.unwrap();
        let me = n.me;
        // signed out without anyone asking for a wipe (another device became the main one)
        n.self_revoke(false, false);
        stop(n).await;
        let data = tmp.path().join("data");

        // the lock screen: refused, and nothing touched
        let e = Node::start(cfg(tmp.path(), true)).await.err().expect("unlock must not start");
        assert_eq!(err_key(&e), "err.device_signed_out");
        assert!(data.join("keystore.json").exists() && data.join("lumora.db").exists() && data.join(RESET_MARKER).exists());
        assert!(aside_dirs(tmp.path()).is_empty());

        // "Start over" → a new account; the old one is kept aside, never deleted
        let n2 = Node::start(cfg(tmp.path(), false)).await.unwrap();
        assert_ne!(n2.me, me);
        stop(n2).await;
        let aside = aside_dirs(tmp.path());
        assert_eq!(aside.len(), 1, "{aside:?}");
        assert!(aside[0].join("lumora.db").exists());
        let old = crate::keystore::unlock(&aside[0], Some("mật khẩu")).unwrap();
        assert_eq!(old.identity.peer_id(), me, "the kept data is the old account");
    }

    #[test]
    fn old_or_damaged_markers_keep_the_data() {
        for raw in [&b"{\"wipe_media\":false}"[..], b"garbage"] {
            let tmp = tempfile::tempdir().unwrap();
            let data = tmp.path().join("data");
            std::fs::create_dir_all(&data).unwrap();
            std::fs::write(data.join("lumora.db"), b"db").unwrap();
            std::fs::write(data.join(RESET_MARKER), raw).unwrap();
            apply_reset_marker(&data);
            assert!(!data.join("lumora.db").exists() && !data.join(RESET_MARKER).exists());
            let aside = aside_dirs(tmp.path());
            assert_eq!(std::fs::read(aside[0].join("lumora.db")).unwrap(), b"db");
        }
    }

    #[tokio::test]
    async fn unlock_never_creates_an_account() {
        let tmp = tempfile::tempdir().unwrap();
        let e = Node::start(cfg(tmp.path(), true)).await.err().expect("nothing to unlock");
        assert_eq!(err_key(&e), "err.no_account");
        assert!(!crate::keystore::exists(&tmp.path().join("data")));
    }

    #[tokio::test]
    async fn signing_out_here_still_removes_the_account() {
        let tmp = tempfile::tempdir().unwrap();
        let n = Node::start(cfg(tmp.path(), false)).await.unwrap();
        let me = n.me;
        n.self_revoke(false, true); // the user signed this device out
        stop(n).await;
        let n2 = Node::start(cfg(tmp.path(), false)).await.unwrap();
        assert_ne!(n2.me, me);
        stop(n2).await;
        assert!(aside_dirs(tmp.path()).is_empty());
    }
}
