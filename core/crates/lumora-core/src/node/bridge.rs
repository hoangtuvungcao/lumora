//! Legacy bridge (multi-device Phase 9): a linked device reaches friends still on an app
//! from before multi-device through the account's main device.
//!
//! Older apps only accept content signed by the account key, which only the main device
//! holds. A linked device therefore hands what it sends them to the main device
//! (`Ext PROXY`, own devices only, also as offline mail). The main device checks that a
//! current device of the account signed it, signs it again with the account key — same
//! ids and clock, so newer apps that also got the device-signed copy see one message — and
//! delivers it like its own. Until the main device is online, it waits in the linked
//! device's queue (the message shows as "sending").
//!
//! Bridged: direct messages, message actions (edit / react / delete…), and group
//! envelopes (opened with the group key, op and message signatures replaced, sealed again).

use super::*;
use crate::devices::SigBy;
use crate::group::Payload;
use crate::proto::ext;

#[derive(Serialize, Deserialize, Default)]
pub(super) struct ProxyMsg {
    /// the older friend (account key)
    #[serde(with = "serde_bytes", default)]
    pub to: Vec<u8>,
    /// the device-signed `PeerMsg` (Chat / Action / Group)
    #[serde(with = "serde_bytes", default)]
    pub msg: Vec<u8>,
}

impl Node {
    /// Linked device → older friend: through the main device. Kinds an older app can't be
    /// helped with (typing, receipts, profile…) are skipped, as before.
    pub(super) async fn bridge_send(self: &Arc<Self>, to: PeerId, id: [u8; 16], m: PeerMsg) {
        let inner = match m {
            PeerMsg::Wrapped { inner, .. } => *inner,
            other => other,
        };
        if !matches!(inner, PeerMsg::Chat(_) | PeerMsg::Action { .. } | PeerMsg::Group { .. }) {
            tracing::debug!("not bridging this kind to {to:?} (older app)");
            return;
        }
        let Ok(msg) = rmp_serde::to_vec(&inner) else { return };
        let p = proto::ext(ext::PROXY, &ProxyMsg { to: to.0.to_vec(), msg });
        // one queue slot per (item, friend): a group envelope goes to several older friends
        let mut h = blake3::Hasher::new();
        h.update(b"lumora-bridge-v1");
        h.update(&id);
        h.update(&to.0);
        let qid: [u8; 16] = h.finalize().as_bytes()[..16].try_into().unwrap_or(id);
        // reliable, to the main device only (its key is the account key)
        self.deliver_dev(self.me, qid, p, true).await;
    }

    /// Main device: a linked device asks us to pass `msg` on to an older friend.
    pub(super) async fn on_proxy(self: &Arc<Self>, dev: PeerId, body: &[u8]) -> Result<()> {
        anyhow::ensure!(self.is_primary(), "bridge: not the main device");
        anyhow::ensure!(dev != self.device && self.own_list().map(|b| b.is_active(&dev)).unwrap_or(false), "bridge: not one of my devices");
        let m: ProxyMsg = proto::ext_body(body)?;
        let to = PeerId(m.to.as_slice().try_into().map_err(|_| anyhow!("bridge: bad target"))?);
        let inner: PeerMsg = rmp_serde::from_slice(&m.msg)?;
        // signed by that device, as this account
        let by_dev = |author: &PeerId, bytes: &[u8], sig: &[u8]| {
            *author == self.me && matches!(crate::devices::verify_by(author, bytes, sig), Some(SigBy::Device { device, .. }) if device == dev)
        };
        match inner {
            PeerMsg::Chat(mut c) => {
                anyhow::ensure!(self.store.is_friend(&to), "bridge: not a friend");
                let scope = super::chat::dm_scope(&self.me, &to);
                anyhow::ensure!(by_dev(&c.author, &c.signing_bytes(&scope), &c.sig), "bridge: bad chat signature");
                // keep our own copy now (self-sync brings the same row later): the friend's
                // delivery / read receipts come to this device and must find it
                let conv = direct_conv(&to);
                if self.store_chat(&conv, &c, 1).unwrap_or(false) {
                    let _ = self.store.conv_touch(&conv, crate::util::hlc_to_ms(c.hlc) as i64, &c.body.preview(), false);
                    if let Some(sm) = self.store.message(&c.id) {
                        self.emit("message", self.msg_json(&sm));
                    }
                    self.emit_conv(&conv);
                }
                c.sig = self.id.sign(&c.signing_bytes(&scope)).to_vec();
                tracing::debug!("bridge: message {} → {to:?}", hex::encode(c.id));
                self.deliver_dev(to, c.id, PeerMsg::Chat(c), true).await;
            }
            PeerMsg::Action { id, author, hlc, action, sig } => {
                anyhow::ensure!(self.store.is_friend(&to), "bridge: not a friend");
                let bytes = super::chat::action_bytes(&id, &author, hlc, &action);
                anyhow::ensure!(by_dev(&author, &bytes, &sig), "bridge: bad action signature");
                let sig = self.id.sign(&bytes).to_vec();
                let mid: [u8; 16] = crate::crypto::random_bytes();
                self.deliver_dev(to, mid, PeerMsg::Action { id, author, hlc, action, sig }, true).await;
            }
            PeerMsg::Group { gid, env } => {
                let st = self.groups.read().get(&gid).cloned().ok_or_else(|| anyhow!("bridge: unknown group"))?;
                anyhow::ensure!(st.is_member(&to), "bridge: not a member");
                let epoch = crate::group::envelope_epoch(&env).ok_or_else(|| anyhow!("bad env"))?;
                let key = self.store.group_key_get(&gid, epoch).ok_or_else(|| anyhow!("bridge: no group key"))?;
                let mut s = crate::group::open_envelope(&key, &gid, &env)?;
                anyhow::ensure!(by_dev(&s.author, &s.signing_bytes(), &s.sig), "bridge: bad op signature");
                if let Payload::Msg { channel, msg } = &mut s.payload {
                    let scope = super::groups::group_scope(&gid, channel);
                    anyhow::ensure!(by_dev(&msg.author, &msg.signing_bytes(&scope), &msg.sig), "bridge: bad message signature");
                    msg.sig = self.id.sign(&msg.signing_bytes(&scope)).to_vec();
                }
                s.sig = self.id.sign(&s.signing_bytes()).to_vec();
                let env = crate::group::seal_envelope(&key, epoch, &s)?;
                self.deliver_dev(to, s.id, PeerMsg::Group { gid, env }, true).await;
            }
            _ => bail!("bridge: unsupported kind"),
        }
        Ok(())
    }
}
