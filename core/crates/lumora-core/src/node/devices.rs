//! Multi-device at the node level: which devices an account has, where to deliver, how
//! device lists travel (`Ext DeviceSync / DeviceList / DeviceListRequest`), and content
//! signature checks that know about device certificates and revocation.
//! Pure parts: crate::devices. Design: docs/src/dev/multi-device.md.

use super::*;
use crate::devices::{self as dv, DeviceCert, DeviceEntry, DeviceListBody, SigBy, SignedDeviceList};
use crate::proto::ext;
use std::sync::atomic::Ordering;

/// A device not seen for this long (and added longer ago) gets no new copies; it catches
/// up from its siblings when it comes back.
const DORMANT_MS: u64 = 30 * 86_400_000;

#[derive(Serialize, Deserialize, Default, Debug)]
pub(super) struct DeviceSyncMsg {
    /// version of my account's list I can share (0 = nothing to share)
    #[serde(default)]
    pub mine: u64,
    /// version of your account's list I have (0 = none)
    #[serde(default)]
    pub yours: u64,
}

#[derive(Serialize, Deserialize, Default, Debug)]
pub(super) struct DeviceListMsg {
    #[serde(with = "serde_bytes")]
    pub list: Vec<u8>,
}

/// `Ext DEVICE_ACCEPT` (linked device → main device): the device's acceptance signature
/// for its entry in the account's device list.
#[derive(Serialize, Deserialize, Default, Debug)]
pub(super) struct DeviceAcceptMsg {
    #[serde(with = "serde_bytes", default)]
    pub proof: Vec<u8>,
}

#[derive(Serialize, Deserialize, Default, Debug)]
pub(super) struct DeviceListRequestMsg {
    #[serde(default)]
    pub account: Option<PeerId>,
}

/// Default device name / kind for this platform.
pub(crate) fn default_device_kind() -> u8 {
    match std::env::consts::OS {
        "android" | "ios" => dv::KIND_PHONE,
        "linux" | "windows" | "macos" if std::env::var("LUMORA_DEVICE_KIND").ok().as_deref() == Some("cli") => dv::KIND_CLI,
        "linux" | "windows" | "macos" => dv::KIND_DESKTOP,
        _ => dv::KIND_CLI,
    }
}

pub(crate) fn default_device_name() -> String {
    let os = match std::env::consts::OS {
        "android" => "Android",
        "ios" => "iPhone",
        "macos" => "Mac",
        "windows" => "Windows",
        "linux" => "Linux",
        o => o,
    };
    let host = std::env::var("HOSTNAME").or_else(|_| std::env::var("COMPUTERNAME")).unwrap_or_default();
    let n = if host.is_empty() { os.to_string() } else { format!("{os} · {host}") };
    n.chars().take(32).collect()
}

pub(crate) fn caps_for(kind: u8) -> u8 {
    dv::CAP_CALLS | if kind == dv::KIND_DESKTOP || kind == dv::KIND_CLI { dv::CAP_REMOTE_HOST } else { 0 }
}

impl Node {
    pub fn is_primary(&self) -> bool {
        self.device == self.me
    }

    /// The account behind a transport key (the key itself when unknown / single-device).
    pub fn account_of(&self, dev: &PeerId) -> PeerId {
        if *dev == self.device {
            return self.me;
        }
        self.store.device_account(dev).unwrap_or(*dev)
    }

    /// My account's current device list (validated), if any.
    pub(crate) fn own_list(&self) -> Option<DeviceListBody> {
        self.store.device_list_get(&self.me).and_then(|(_, b)| SignedDeviceList::decode(&b).ok()).and_then(|l| l.validate().ok())
    }

    /// Active devices of `account` from its list (dormant ones skipped unless that empties it).
    fn active_devices(&self, account: &PeerId) -> Vec<PeerId> {
        let rows = self.store.devices_of(account);
        let listed: Vec<_> = rows.into_iter().filter(|d| d.listed && d.revoked.is_none()).collect();
        let now = now_ms();
        let awake: Vec<PeerId> = listed
            .iter()
            .filter(|d| !(d.added + DORMANT_MS < now && d.last_seen > 0 && d.last_seen + DORMANT_MS < now))
            .map(|d| d.device)
            .collect();
        if awake.is_empty() {
            listed.into_iter().map(|d| d.device).collect()
        } else {
            awake
        }
    }

    /// Where content for `to` goes: every active device of the account (or just the key
    /// when no list is known — old peers, single devices, bots). `to == me` → my other
    /// devices. A device key that isn't an account is delivered to as is.
    pub fn delivery_targets(&self, to: &PeerId) -> Vec<PeerId> {
        let devs = self.active_devices(to);
        if *to == self.me {
            return devs.into_iter().filter(|d| *d != self.device).collect();
        }
        if devs.is_empty() {
            vec![*to]
        } else {
            devs
        }
    }

    /// My other active devices.
    pub fn siblings(&self) -> Vec<PeerId> {
        self.delivery_targets(&self.me)
    }

    /// Is this (account, device) revoked by the newest list we hold?
    pub fn is_revoked(&self, account: &PeerId, dev: &PeerId) -> bool {
        if dev == account {
            return false;
        }
        self.store.device_get(dev).map(|d| d.account == *account && d.revoked.is_some()).unwrap_or(false)
    }

    /// Does this device understand `Ext` (announced v3, or it is part of a device list /
    /// presented a device certificate — both imply v3)?
    pub(crate) fn dev_speaks_v3(&self, dev: &PeerId) -> bool {
        if let Some(pc) = self.peer(dev) {
            if pc.proto.load(Ordering::Relaxed) >= proto::PROTO_V3 {
                return true;
            }
        }
        self.peer_proto(dev) >= proto::PROTO_V3 || self.store.device_get(dev).is_some()
    }

    /// Known to run a version older than v3 (it would skip `Ext`): announced 1 or 2, and
    /// not part of a device list. Unknown versions are not "older".
    pub(crate) fn dev_known_pre_v3(&self, dev: &PeerId) -> bool {
        if self.dev_speaks_v3(dev) {
            return false;
        }
        let v = self.peer(dev).map(|pc| pc.proto.load(Ordering::Relaxed)).filter(|v| *v > 0).unwrap_or_else(|| self.peer_proto(dev));
        v > 0 && v < proto::PROTO_V3
    }

    /// Learn (device → account) from a valid certificate (TLS SAN or DevSig — both prove
    /// the device itself presents it). Never re-assigns a device known under another account.
    pub(crate) fn learn_cert(&self, cert: &DeviceCert) {
        // only for accounts we have something to do with (strangers mint keys for free:
        // don't let them fill the table)
        let known = cert.account == self.me
            || self.store.contact(&cert.account).map(|c| c.status > 0).unwrap_or(false)
            || self.groups.read().values().any(|g| g.is_member(&self.me) && g.is_member(&cert.account));
        if known && cert.verify() && cert.device != self.device {
            if let Ok(true) = self.store.device_learn(&cert.device, &cert.account, cert.caps, cert.created) {
                tracing::info!("learned device {:?} of {:?}", cert.device, cert.account);
                // the account's list we hold already signed it out: it stays out
                if let Some(at) = self.list_revocation(&cert.account, &cert.device) {
                    let _ = self.store.device_set_revoked(&cert.device, &cert.account, at);
                    return;
                }
                // our copy of their list doesn't know this device yet: ask for a fresh one
                self.send_now_dev(&cert.device, proto::ext(ext::DEVICE_LIST_REQUEST, &DeviceListRequestMsg { account: Some(cert.account) }));
            }
        }
    }

    /// The list version at which `account`'s list (the one we hold) revoked `dev`.
    fn list_revocation(&self, account: &PeerId, dev: &PeerId) -> Option<u64> {
        let (_, raw) = self.store.device_list_get(account)?;
        let body = SignedDeviceList::decode(&raw).ok()?.validate().ok()?;
        body.revoked.iter().find(|r| r.device == *dev).map(|r| r.at)
    }

    /// May we keep `account`'s device list? Me, people I asked / friends, and members of
    /// a group I am in whom it lets me reach (see `group_reveals_to`). A stranger's list is
    /// dropped: nothing stored, nothing changed.
    pub(crate) fn may_hold_devices_of(&self, account: &PeerId) -> bool {
        *account == self.me
            || self.store.contact(account).map(|c| c.status == 1 || c.status == 3).unwrap_or(false)
            || self.group_reveals_to(account)
    }

    /// Verify a content signature by `author` (account): plain account signature or a
    /// DevSig from a non-revoked device. Learns the device on the way.
    pub(crate) fn verify_content(&self, author: &PeerId, msg: &[u8], sig: &[u8]) -> bool {
        match dv::verify_by(author, msg, sig) {
            Some(SigBy::Account) => true,
            Some(SigBy::Device { device, cert }) => {
                if self.is_revoked(author, &device) {
                    tracing::warn!("dropping content signed by revoked device {device:?}");
                    return false;
                }
                self.learn_cert(&cert);
                true
            }
            None => false,
        }
    }

    /// Can `account` verify device signatures (any of its devices announced v3, or it
    /// has a device list)? Unknown → assume yes only if we never heard an older version.
    pub(crate) fn speaks_multidevice(&self, account: &PeerId) -> bool {
        if self.store.device_list_get(account).is_some() {
            return true;
        }
        let v = self.peer_proto(account);
        v == 0 || v >= proto::PROTO_V3
    }

    /// Version of the newest protocol a device announced (persisted for devices we keep
    /// something about; strangers' only in a bounded in-memory cache).
    pub(crate) fn peer_proto(&self, dev: &PeerId) -> u32 {
        self.store
            .kv_get(&format!("peer.proto.{}", dev.to_base32()))
            .and_then(|v| v.try_into().ok())
            .map(u32::from_le_bytes)
            .or_else(|| self.stranger_proto.lock().peek(dev).copied())
            .unwrap_or(0)
    }

    /// Primary only: make sure the account has a device list (version 1 = this device).
    /// It is never sent anywhere while it has a single device.
    pub(super) fn ensure_own_list(&self) {
        if !self.is_primary() || self.is_bot() {
            return;
        }
        if self.store.device_list_get(&self.me).is_some() {
            return;
        }
        let kind = default_device_kind();
        let name = self.store.kv_get("device.name").and_then(|v| String::from_utf8(v).ok()).unwrap_or_else(default_device_name);
        let body = DeviceListBody {
            v: 1,
            account: self.me,
            version: 1,
            devices: vec![DeviceEntry::new(self.me, name, kind, dv::CAP_PRIMARY | caps_for(kind), now_ms())],
            revoked: vec![],
        };
        if let Ok(l) = SignedDeviceList::sign(&self.id, &body) {
            let _ = self.store.device_list_put(&l.encode(), &body);
        }
    }

    /// Primary: sign and store a new version of the list, then push it everywhere.
    pub(crate) fn publish_own_list(self: &Arc<Self>, mutate: impl FnOnce(&mut DeviceListBody)) -> Result<DeviceListBody> {
        anyhow::ensure!(self.is_primary(), crate::i18n::user_err("err.primary_only"));
        self.ensure_own_list();
        let mut body = self.own_list().ok_or_else(|| anyhow!("no device list"))?;
        mutate(&mut body);
        let prev = body.version;
        body.version = (prev + 1).max(self.hlc.tick());
        for r in body.revoked.iter_mut().filter(|r| r.at == 0) {
            r.at = body.version;
        }
        let l = SignedDeviceList::sign(&self.id, &body)?;
        self.store.device_list_put(&l.encode(), &body)?;
        self.refresh_sync_enabled();
        self.emit_devices();
        self.push_own_list(&l);
        Ok(body)
    }

    /// Sibling sync only runs while the account has ≥ 2 devices.
    pub(super) fn refresh_sync_enabled(&self) {
        let n = self.own_list().map(|b| b.devices.len()).unwrap_or(1);
        self.store.set_sync_enabled(n >= 2);
    }

    fn list_shareable(&self) -> Option<(u64, Vec<u8>)> {
        let (v, b) = self.store.device_list_get(&self.me)?;
        let l = SignedDeviceList::decode(&b).ok()?;
        let body = l.validate().ok()?;
        (body.devices.len() >= 2 || !body.revoked.is_empty()).then_some((v, b))
    }

    /// May `pc` see my device list (names, count)? Own devices, contacts, group co-members.
    fn may_see_my_devices(&self, pc: &PeerConn) -> bool {
        if pc.own {
            return true;
        }
        if self.store.contact(&pc.account).map(|c| (1..=3).contains(&c.status)).unwrap_or(false) {
            return true;
        }
        self.groups.read().values().any(|g| g.is_member(&pc.account) && g.is_member(&self.me))
    }

    /// Push my account's list to my other devices and to every device of every friend.
    pub(super) fn push_own_list(self: &Arc<Self>, l: &SignedDeviceList) {
        let msg = proto::ext(ext::DEVICE_LIST, &DeviceListMsg { list: l.encode() });
        for pc in self.connected_peers() {
            if self.may_see_my_devices(&pc) && pc.proto.load(Ordering::Relaxed) >= proto::PROTO_V3 {
                let _ = pc.ctl.try_send(msg.clone());
            }
        }
        // reliable for my own devices (they must learn about revocations / new siblings)
        let me = self.clone();
        tokio::spawn(async move {
            let id: [u8; 16] = crate::crypto::random_bytes();
            me.deliver(me.me, id, msg, true).await;
        });
    }

    /// Hello with version ≥ 3: compare device-list versions.
    pub(super) fn device_sync_on_hello(&self, pc: &Arc<PeerConn>) {
        let mine = self.list_shareable().map(|(v, _)| v).unwrap_or(0);
        let yours = if pc.account == self.me { 0 } else { self.store.device_list_get(&pc.account).map(|(v, _)| v).unwrap_or(0) };
        let _ = pc.ctl.try_send(proto::ext(ext::DEVICE_SYNC, &DeviceSyncMsg { mine, yours }));
        // a linked device whose entry in the list has no acceptance proof yet (linked before
        // proofs existed): give the main device one, so friends accept the entry
        if pc.own && pc.peer == self.me && !self.is_primary() {
            let proven = self.own_list().and_then(|b| b.devices.into_iter().find(|e| e.device == self.device)).map(|e| e.proven_for(&self.me)).unwrap_or(false);
            if !proven {
                let _ = pc.ctl.try_send(proto::ext(ext::DEVICE_ACCEPT, &DeviceAcceptMsg { proof: dv::sign_accept(&self.id, &self.me) }));
            }
        }
    }

    pub(super) fn on_device_ext(self: &Arc<Self>, pc: &Arc<PeerConn>, kind: u16, body: &[u8]) -> Result<()> {
        match kind {
            ext::DEVICE_SYNC => {
                let m: DeviceSyncMsg = proto::ext_body(body)?;
                // they hold a newer list of MY account than I do (another device was made the
                // main one, or a sibling's change I missed): ask for it
                let mine_v = self.store.device_list_get(&self.me).map(|(v, _)| v).unwrap_or(0);
                if !pc.own && m.yours > mine_v && mine_v > 0 {
                    let _ = pc.ctl.try_send(proto::ext(ext::DEVICE_LIST_REQUEST, &DeviceListRequestMsg { account: Some(self.me) }));
                }
                let (cur, list) = match self.list_shareable() {
                    Some(x) => x,
                    None => return Ok(()),
                };
                let behind = if pc.own { self.store.device_list_get(&self.me).map(|(v, _)| v).unwrap_or(0) > m.mine } else { m.yours < cur };
                if behind && self.may_see_my_devices(pc) {
                    let _ = pc.ctl.try_send(proto::ext(ext::DEVICE_LIST, &DeviceListMsg { list }));
                }
            }
            ext::DEVICE_LIST_REQUEST => {
                let m: DeviceListRequestMsg = proto::ext_body(body).unwrap_or_default();
                // a device of a friend asks for its own account's list (it fell behind)
                if let Some(acct) = m.account.filter(|a| *a != self.me && *a == pc.account) {
                    if let Some((_, list)) = self.store.device_list_get(&acct) {
                        let _ = pc.ctl.try_send(proto::ext(ext::DEVICE_LIST, &DeviceListMsg { list }));
                    }
                    return Ok(());
                }
                if let Some((_, list)) = self.list_shareable() {
                    if self.may_see_my_devices(pc) {
                        let _ = pc.ctl.try_send(proto::ext(ext::DEVICE_LIST, &DeviceListMsg { list }));
                    }
                }
            }
            ext::DEVICE_LIST => {
                let m: DeviceListMsg = proto::ext_body(body)?;
                self.accept_device_list(&m.list, pc.account, pc.own)?;
            }
            ext::DEVICE_ACCEPT if pc.own && self.is_primary() => {
                let m: DeviceAcceptMsg = proto::ext_body(body)?;
                anyhow::ensure!(dv::verify_accept(&self.me, &pc.peer, &m.proof), "bad device acceptance");
                let missing = self.own_list().map(|b| b.devices.iter().any(|e| e.device == pc.peer && !e.proven_for(&self.me))).unwrap_or(false);
                if missing {
                    let d = pc.peer;
                    self.publish_own_list(|b| {
                        for e in b.devices.iter_mut().filter(|e| e.device == d) {
                            e.proof = m.proof.clone();
                        }
                    })?;
                }
            }
            _ => {}
        }
        Ok(())
    }

    /// A signed list arrived from `from_account` (`own`: from one of my devices, which
    /// may also pass on lists of my friends).
    ///
    /// Safety (a list is signed by its account alone, and anyone can make an account):
    /// * only lists of accounts we have something to do with are kept (`may_hold_devices_of`);
    /// * a listed device is bound to the account only with its own acceptance signature,
    ///   or if we already know it under that account (certificate it presented, earlier
    ///   proven list) — and a device known under another account is never re-assigned;
    /// * a revocation only affects devices that were this account's.
    pub(crate) fn accept_device_list(&self, raw: &[u8], from_account: PeerId, own: bool) -> Result<bool> {
        let l = SignedDeviceList::decode(raw)?;
        let body = l.validate()?;
        // (my own account's list may come from anyone: only the account key signs it)
        anyhow::ensure!(body.account == from_account || own || body.account == self.me, "device list for another account");
        if !self.may_hold_devices_of(&body.account) {
            tracing::debug!("dropping the device list of {:?}: not someone we know", body.account);
            return Ok(false);
        }
        let cached = self.store.device_list_get(&body.account).and_then(|(v, b)| SignedDeviceList::decode(&b).ok().map(|c| (v, c.digest())));
        if !l.newer_than(body.version, cached) {
            return Ok(false);
        }
        // a newer list of my own account that I (the main device) didn't sign: another device
        // holds the account key now (made main with the recovery phrase) — step down
        if body.account == self.me && self.is_primary() && cached.is_some() {
            tracing::warn!("another device became the main device of this account: signing out");
            self.self_revoke(false, false);
            return Ok(false);
        }
        // devices we already know under this account (certificate, earlier list)
        let known: std::collections::HashSet<PeerId> = self.store.devices_of(&body.account).into_iter().map(|d| d.device).collect();
        let mut bound = body.clone();
        if body.account != self.me {
            bound.devices.retain(|e| {
                let ok = e.proven_for(&body.account) || known.contains(&e.device);
                if !ok {
                    tracing::debug!("device {:?} listed by {:?} without its acceptance: not bound", e.device, body.account);
                }
                ok
            });
        }
        bound.revoked.retain(|r| known.contains(&r.device));
        // a friend's devices before this list (None: the first list we learn — nothing to say)
        let before: Option<Vec<PeerId>> = (body.account != self.me)
            .then(|| self.store.device_list_get(&body.account))
            .flatten()
            .and_then(|(_, b)| SignedDeviceList::decode(&b).ok())
            .and_then(|l| l.validate().ok())
            .map(|b| b.devices.iter().map(|e| e.device).chain(b.revoked.iter().map(|r| r.device)).collect());
        self.store.device_list_put(raw, &bound)?;
        self.hlc.observe(body.version);
        for d in &bound.revoked {
            if d.device != self.device {
                self.forget_revoked(&d.device);
            }
        }
        if body.account == self.me {
            // a sibling we hear about for the first time gets the past from the device that
            // approved it (history window), never from us: start our log for it here
            let head = self.store.sync_head();
            for e in &body.devices {
                if e.device != self.device && self.store.sync_peer_sent(&e.device).is_none() {
                    let _ = self.store.sync_peer_set_sent(&e.device, head);
                }
            }
            self.refresh_sync_enabled();
            self.emit_devices();
            if !body.is_active(&self.device) && !self.is_primary() {
                self.self_revoke(body.revoked.iter().any(|r| r.device == self.device && r.wipe), false);
            }
        } else {
            self.emit("contact_devices", json!({"peer": body.account.to_base32(), "devices": self.contact_devices_json(&body.account)}));
            let fresh: Vec<PeerId> = match &before {
                Some(b) => bound.devices.iter().filter(|e| !b.contains(&e.device)).map(|e| e.device).collect(),
                // the first list we learn (lists are only shared from 2 devices on, so this is
                // usually "their first extra device"): only devices linked after we became
                // friends and recently — not an old setup we only hear about now
                None => {
                    let since = self.store.contact(&body.account).map(|c| c.added.max(0) as u64).unwrap_or(u64::MAX);
                    let recent = now_ms().saturating_sub(7 * 86_400_000);
                    bound.devices.iter().filter(|e| e.device != body.account && e.added > since && e.added > recent).map(|e| e.device).collect()
                }
            };
            for d in fresh {
                self.note_contact_device_added(&body.account, &d);
            }
        }
        Ok(true)
    }

    /// "Lan vừa thêm một thiết bị mới. Mã bảo mật đã thay đổi." in the direct chat with a
    /// friend whose signed device list gained a device. The id is derived from (account,
    /// device), so my other devices — which each see the same list — end up with one line.
    pub(crate) fn note_contact_device_added(&self, account: &PeerId, dev: &PeerId) {
        let Some(c) = self.store.contact(account).filter(|c| c.status == 3) else {
            return; // only friends have a direct chat to put it in
        };
        let name = c.alias.filter(|a| !a.trim().is_empty()).unwrap_or(c.name);
        let name = if name.trim().is_empty() { account.short_id_fmt() } else { name };
        let mut h = blake3::Hasher::new();
        h.update(b"lumora-sys-contact-device-added");
        h.update(&account.0);
        h.update(&dev.0);
        let mut id = [0u8; 16];
        id.copy_from_slice(&h.finalize().as_bytes()[..16]);
        self.direct_system_msg(account, id, "sys.contact_device_added", &[("name", &name), ("peer", &account.to_base32())]);
    }

    /// A local system line in the direct chat with `peer` (`{text, code, args}` like groups:
    /// the app renders `code` in its own language, `text` is the English fallback).
    pub(crate) fn direct_system_msg(&self, peer: &PeerId, id: [u8; 16], code: &str, args: &[(&str, &str)]) {
        let conv = direct_conv(peer);
        let title = self.store.contact(peer).map(|c| c.name).unwrap_or_default();
        if self.store.ensure_conv(&conv, 0, &title).is_err() {
            return;
        }
        let hlc = self.hlc.tick();
        let text = crate::i18n::trf(code, args);
        let argv: serde_json::Map<String, Value> = args.iter().map(|(k, v)| (k.to_string(), Value::String(v.to_string()))).collect();
        let body = json!({"text": crate::i18n::trf_en(code, args), "code": code, "args": argv});
        if self.store.insert_message(&id, &conv, &self.me, hlc, "system", &body, 2, None, None).unwrap_or(false) {
            let _ = self.store.conv_touch(&conv, crate::util::hlc_to_ms(hlc) as i64, &text, false);
            if let Some(m) = self.store.message(&id) {
                self.emit("message", self.msg_json(&m));
            }
        }
    }

    // ------------------------------------------------------------ directory records

    /// Main device: keep its latest signed directory events (synced to my other devices,
    /// which re-broadcast them verbatim while the main device is away).
    pub(crate) fn keep_nostr_event(&self, kind: &str, ev: Value) {
        if self.siblings().is_empty() {
            return;
        }
        let mut all: serde_json::Map<String, Value> = self.store.kv_get_json("nostr.events").unwrap_or_default();
        all.insert(kind.to_string(), ev);
        let _ = self.store.kv_set_json("nostr.events", &all);
    }

    pub(crate) fn kept_nostr_events(&self) -> Vec<Value> {
        let all: serde_json::Map<String, Value> = self.store.kv_get_json("nostr.events").unwrap_or_default();
        all.into_values().collect()
    }

    /// A device short ID found in the directory with its certificate: remember its account.
    pub(crate) fn learn_directory_cert(&self, dev: &PeerId, cert: &[u8]) {
        if let Ok(c) = DeviceCert::decode(cert) {
            if c.device == *dev && c.verify() && c.device != self.device {
                let _ = self.store.device_learn(&c.device, &c.account, c.caps, c.created);
            }
        }
    }

    // ------------------------------------------------------------ API views

    pub fn devices_json(&self) -> Value {
        let list = self.own_list();
        let online: std::collections::HashSet<PeerId> = self.connected_peers().iter().filter(|p| p.own).map(|p| p.peer).collect();
        let devs: Vec<Value> = match &list {
            Some(b) => b
                .devices
                .iter()
                .map(|e| {
                    let row = self.store.device_get(&e.device);
                    json!({
                        "device": e.device.to_base32(), "name": e.name, "kind": e.kind, "caps": e.caps, "added": e.added,
                        "primary": e.device == self.me, "this": e.device == self.device, "short_id": e.device.short_id_fmt(),
                        "online": e.device == self.device || online.contains(&e.device),
                        "last_seen": if e.device == self.device { now_ms() } else { row.map(|r| r.last_seen).unwrap_or(0) },
                    })
                })
                .collect(),
            None => vec![json!({
                "device": self.device.to_base32(), "name": default_device_name(), "kind": default_device_kind(), "caps": 0, "added": 0,
                "primary": self.is_primary(), "this": true, "online": true, "last_seen": now_ms(), "short_id": self.device.short_id_fmt(),
            })],
        };
        json!({
            "account": self.me.to_base32(), "device": self.device.to_base32(), "primary": self.is_primary(),
            "version": list.as_ref().map(|b| b.version).unwrap_or(0),
            "devices": devs,
            "revoked": list.map(|b| b.revoked.iter().map(|r| json!({"device": r.device.to_base32(), "at": r.at, "wipe": r.wipe})).collect::<Vec<_>>()).unwrap_or_default(),
        })
    }

    pub fn emit_devices(&self) {
        self.emit("devices", self.devices_json());
    }

    pub fn contact_devices_json(&self, account: &PeerId) -> Value {
        let online: std::collections::HashSet<PeerId> = self.connected_peers().iter().filter(|p| p.account == *account).map(|p| p.peer).collect();
        let rows = self.store.devices_of(account);
        Value::Array(
            rows.into_iter()
                .filter(|d| d.listed && d.revoked.is_none())
                .map(|d| {
                    json!({
                        "device": d.device.to_base32(), "name": d.name, "kind": d.kind, "caps": d.caps,
                        "primary": d.device == *account, "online": online.contains(&d.device), "last_seen": d.last_seen,
                        "short_id": d.device.short_id_fmt(), "safety": d.device.security_code(),
                    })
                })
                .collect(),
        )
    }

    /// Primary: rename one of the account's devices.
    pub fn device_rename(self: &Arc<Self>, dev: &PeerId, name: &str) -> Result<()> {
        let name: String = name.trim().chars().take(32).collect();
        anyhow::ensure!(!name.is_empty(), crate::i18n::user_err("err.name_empty"));
        if *dev == self.device {
            self.store.kv_set("device.name", name.as_bytes())?;
        }
        let d = *dev;
        self.publish_own_list(|b| {
            for e in b.devices.iter_mut() {
                if e.device == d {
                    e.name = name.clone();
                }
            }
        })?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn node(tmp: &std::path::Path) -> Arc<Node> {
        let cfg = NodeConfig {
            data_dir: tmp.join("data"),
            downloads_dir: Some(tmp.join("dl")),
            enable_lan: false,
            enable_upnp: false,
            enable_dht: false,
            enable_nostr: false,
            relays: Some(vec![]),
            nostr: Some(vec![]),
            stun: Some(vec![]),
            ..Default::default()
        };
        Node::start(cfg).await.unwrap()
    }

    /// A device of `account` that accepted to be one (its acceptance in the entry).
    fn entry_of(account: &PeerId, added: u64) -> (PeerId, DeviceEntry) {
        let id = Identity::generate();
        let mut e = DeviceEntry::new(id.peer_id(), "Phone", dv::KIND_PHONE, 0, added);
        e.proof = dv::sign_accept(&id, account);
        (id.peer_id(), e)
    }

    fn main(account: PeerId, added: u64) -> DeviceEntry {
        DeviceEntry::new(account, "Phone", dv::KIND_PHONE, dv::CAP_PRIMARY, added)
    }

    fn list(root: &Identity, version: u64, devices: Vec<DeviceEntry>) -> Vec<u8> {
        let body = DeviceListBody { v: 1, account: root.peer_id(), version, devices, revoked: vec![] };
        SignedDeviceList::sign(root, &body).unwrap().encode()
    }

    fn system_lines(n: &Node, conv: &str) -> Vec<Value> {
        n.store
            .messages(conv, None, 50)
            .unwrap()
            .into_iter()
            .filter(|m| m.kind == "system")
            .map(|m| m.body)
            .collect()
    }

    /// A friend's signed device list gains a device → one "Lan added a new device" line in
    /// the direct chat; devices we already knew (or an old setup we only learn now) → none.
    #[tokio::test]
    async fn new_friend_device_adds_a_system_line() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let lan = Identity::generate();
        let acct = lan.peer_id();
        n.store.upsert_contact(&acct, Some("Lan"), Some(3)).unwrap();
        let conv = direct_conv(&acct);
        let day = 86_400_000;
        let (_, old) = entry_of(&acct, now_ms() - 30 * day);
        // first list we learn: the laptop was linked long before we became friends → silent
        let primary = main(acct, now_ms() - 400 * day);
        assert!(n.accept_device_list(&list(&lan, 5, vec![primary.clone(), old.clone()]), acct, false).unwrap());
        assert!(system_lines(&n, &conv).is_empty());
        // a new phone shows up
        let (phone, pe) = entry_of(&acct, now_ms());
        let v6 = list(&lan, 6, vec![primary.clone(), old.clone(), pe.clone()]);
        assert!(n.accept_device_list(&v6, acct, false).unwrap());
        let lines = system_lines(&n, &conv);
        assert_eq!(lines.len(), 1, "{lines:?}");
        assert_eq!(lines[0]["code"], "sys.contact_device_added");
        assert_eq!(lines[0]["args"]["name"], "Lan");
        assert_eq!(lines[0]["text"], "Lan added a new device. Their security code changed.");
        // a rename (same devices) and the same list again add nothing
        let v7 = list(&lan, 7, vec![primary.clone(), old.clone(), DeviceEntry { name: "Lan's phone".into(), ..pe.clone() }]);
        assert!(n.accept_device_list(&v7, acct, false).unwrap());
        assert!(!n.accept_device_list(&v7, acct, false).unwrap());
        assert_eq!(system_lines(&n, &conv).len(), 1);
        // the same device seen again (e.g. relayed by another of my devices) stays one line
        n.note_contact_device_added(&acct, &phone);
        assert_eq!(system_lines(&n, &conv).len(), 1);
        n.shutdown();
    }

    /// First list for a friend whose extra device was linked after we became friends (lists
    /// are only shared from 2 devices on): that is their first new device → one line.
    /// A stranger's list is not kept at all (#1).
    #[tokio::test]
    async fn first_list_with_a_recent_device() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let lan = Identity::generate();
        let acct = lan.peer_id();
        n.store.upsert_contact(&acct, Some("Lan"), Some(3)).unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        let (_, pe) = entry_of(&acct, now_ms());
        assert!(n.accept_device_list(&list(&lan, 2, vec![main(acct, 1), pe]), acct, false).unwrap());
        assert_eq!(system_lines(&n, &direct_conv(&acct)).len(), 1);

        let stranger = Identity::generate();
        let sp = stranger.peer_id();
        let (p2, e2) = entry_of(&sp, now_ms());
        assert!(!n.accept_device_list(&list(&stranger, 2, vec![main(sp, 1), e2]), sp, false).unwrap());
        assert!(n.store.device_list_get(&sp).is_none(), "a stranger's list was stored");
        assert_eq!(n.account_of(&p2), p2);
        assert!(system_lines(&n, &direct_conv(&sp)).is_empty());
        n.shutdown();
    }

    /// #1: a friend's (or anyone's) list can't take over a device: no acceptance → not
    /// bound; a device of another account is never re-assigned; a revocation only touches
    /// that account's own devices.
    #[tokio::test]
    async fn lists_cannot_take_over_devices() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let (lan, minh) = (Identity::generate(), Identity::generate());
        let (la, ma) = (lan.peer_id(), minh.peer_id());
        n.store.upsert_contact(&la, Some("Lan"), Some(3)).unwrap();
        n.store.upsert_contact(&ma, Some("Minh"), Some(3)).unwrap();
        // Lan's phone, properly listed
        let (phone, pe) = entry_of(&la, now_ms());
        assert!(n.accept_device_list(&list(&lan, 2, vec![main(la, 1), pe.clone()]), la, false).unwrap());
        assert_eq!(n.account_of(&phone), la);
        n.store.outbox_add(&[1; 16], &phone, b"for Lan's phone").unwrap();
        // Minh lists Lan's phone (no acceptance for Minh's account) and Lan's main key
        let stolen = DeviceEntry::new(phone, "mine now", dv::KIND_PHONE, 0, 5);
        let lan_key = DeviceEntry::new(la, "mine too", dv::KIND_PHONE, 0, 5);
        assert!(n.accept_device_list(&list(&minh, 3, vec![main(ma, 1), stolen.clone(), lan_key]), ma, false).unwrap());
        assert_eq!(n.account_of(&phone), la, "device re-assigned");
        assert_eq!(n.account_of(&la), la);
        // even with Lan's phone's acceptance for Lan's account copied in, it stays Lan's
        let copied = DeviceEntry { proof: pe.proof.clone(), ..stolen };
        assert!(n.accept_device_list(&list(&minh, 4, vec![main(ma, 1), copied]), ma, false).unwrap());
        assert_eq!(n.account_of(&phone), la);
        // Minh "revokes" Lan's phone and Lan's key: nothing happens to them
        let body = DeviceListBody { v: 1, account: ma, version: 5, devices: vec![main(ma, 1)], revoked: vec![dv::Revoked { device: phone, at: 5, wipe: false }, dv::Revoked { device: la, at: 5, wipe: false }] };
        let raw = SignedDeviceList::sign(&minh, &body).unwrap().encode();
        assert!(n.accept_device_list(&raw, ma, false).unwrap());
        assert!(!n.is_revoked(&la, &phone));
        assert_eq!(n.store.outbox_page(&phone, 0, 10).unwrap().len(), 1, "outbox of another account's device wiped");
        assert!(n.delivery_targets(&la).contains(&phone));
        // Lan herself revoking it works
        let body = DeviceListBody { v: 1, account: la, version: 6, devices: vec![main(la, 1)], revoked: vec![dv::Revoked { device: phone, at: 6, wipe: false }] };
        assert!(n.accept_device_list(&SignedDeviceList::sign(&lan, &body).unwrap().encode(), la, false).unwrap());
        assert!(n.is_revoked(&la, &phone));
        assert!(n.store.outbox_page(&phone, 0, 10).unwrap().is_empty());
        n.shutdown();
    }
}
