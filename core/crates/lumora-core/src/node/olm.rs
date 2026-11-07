//! Double Ratchet (Olm, via the audited `vodozemac` crate) for 1-1 chats.
//!
//! On top of the per-connection transport encryption, direct-chat content is encrypted
//! with an Olm session: a new key for every message (forward secrecy) and self-healing
//! after a key compromise (post-compromise security) — also for messages stored offline
//! in mailboxes. Everything is exchanged peer-to-peer; no key server exists.
//!
//! * Each device has an Olm account (Curve25519 identity + one-time keys), pickled and
//!   encrypted in the local database. Its Curve25519 key is signed by our Ed25519 identity.
//! * A sender without a session asks the friend for a one-time key (`OlmKeysRequest`),
//!   then creates an outbound session; the first message is a pre-key message.
//! * Sessions are only made with friends, my own devices and people I share a group with
//!   ([`Node::olm_peer_allowed`]): a stranger can't make us spend one-time keys or store
//!   session state for it.

use super::*;
use vodozemac::olm::{Account, AccountPickle, OlmMessage, Session, SessionConfig, SessionPickle};
use vodozemac::Curve25519PublicKey;

const MAX_SESSIONS_PER_PEER: usize = 3;

fn pickle_key(id: &Identity) -> [u8; 32] {
    blake3::derive_key("lumora olm pickle key v1", &id.secret_bytes()[..])
}

fn olm_key_bytes(curve: &[u8; 32], otk: &[u8; 32]) -> Vec<u8> {
    let mut v = b"lumora-olm-keys-v1".to_vec();
    v.extend_from_slice(curve);
    v.extend_from_slice(otk);
    v
}

fn olm_identity_bytes(curve: &[u8; 32]) -> Vec<u8> {
    let mut v = b"lumora-olm-identity-v1".to_vec();
    v.extend_from_slice(curve);
    v
}

pub struct OlmState {
    account: Mutex<Option<Account>>,
    /// peer → sessions (newest last)
    sessions: Mutex<HashMap<PeerId, Vec<Session>>>,
    requested: Mutex<HashMap<PeerId, Instant>>,
    /// Undecryptable reliable messages: (device, delivery id) → attempts. After a few
    /// attempts the message is acknowledged anyway (an old sender re-sends the same
    /// ciphertext forever; a current one re-encrypts every re-send).
    fails: Mutex<lru::LruCache<(PeerId, [u8; 16]), FailCount>>,
    /// Last unsolicited key hand-out per device (session repair, rate-limited).
    repaired: Mutex<HashMap<PeerId, Instant>>,
}

impl Default for OlmState {
    fn default() -> Self {
        OlmState {
            account: Mutex::new(None),
            sessions: Mutex::new(HashMap::new()),
            requested: Mutex::new(HashMap::new()),
            fails: Mutex::new(lru::LruCache::new(std::num::NonZeroUsize::new(4096).unwrap())),
            repaired: Mutex::new(HashMap::new()),
        }
    }
}

/// (failed deliveries of one message, since when)
type FailCount = (u8, Instant);

/// Give up on an undecryptable reliable message after this many deliveries...
pub(super) const OLM_MAX_FAILS: u8 = 4;
/// ...and only once it has failed for this long: the sender re-sends quickly, often before
/// the fresh key we handed it arrives (slow link / busy device) — counting those re-sends
/// alone acknowledged good messages that the new session would have carried, i.e. lost them.
pub(super) const OLM_GIVE_UP_AFTER: Duration = Duration::from_secs(600);

impl Node {
    fn olm_account<R>(&self, f: impl FnOnce(&mut Account) -> R) -> R {
        let mut g = self.olm.account.lock();
        if g.is_none() {
            let key = pickle_key(&self.id);
            let acc = self
                .store
                .kv_get("olm.account")
                .and_then(|v| String::from_utf8(v).ok())
                .and_then(|s| AccountPickle::from_encrypted(&s, &key).ok())
                .map(Account::from_pickle)
                .unwrap_or_default();
            *g = Some(acc);
        }
        let acc = g.as_mut().unwrap();
        let r = f(acc);
        let _ = self.store.kv_set("olm.account", acc.pickle().encrypt(&pickle_key(&self.id)).as_bytes());
        r
    }

    fn load_sessions(&self, peer: &PeerId) {
        let mut m = self.olm.sessions.lock();
        if m.contains_key(peer) {
            return;
        }
        let key = pickle_key(&self.id);
        let list: Vec<String> = self.store.kv_get_json(&format!("olm.sess.{}", peer.to_base32())).unwrap_or_default();
        let sess = list.iter().filter_map(|p| SessionPickle::from_encrypted(p, &key).ok()).map(Session::from_pickle).collect();
        m.insert(*peer, sess);
    }

    fn save_sessions(&self, peer: &PeerId) {
        let key = pickle_key(&self.id);
        let list: Vec<String> = self.olm.sessions.lock().get(peer).map(|v| v.iter().map(|s| s.pickle().encrypt(&key)).collect()).unwrap_or_default();
        let _ = self.store.kv_set_json(&format!("olm.sess.{}", peer.to_base32()), &list);
    }

    pub fn olm_has_session(&self, peer: &PeerId) -> bool {
        self.load_sessions(peer);
        self.olm.sessions.lock().get(peer).map(|v| !v.is_empty()).unwrap_or(false)
    }

    /// May we keep a ratchet session with (any device of) `account`? Friends, my own
    /// account, and members of a group I'm in — nobody else.
    pub(super) fn olm_peer_allowed(&self, account: &PeerId) -> bool {
        *account == self.me
            || self.store.is_friend(account)
            || self.groups.read().values().any(|g| g.is_member(account) && g.is_member(&self.me))
    }

    /// Ask a connected friend for a one-time key (at most once a minute).
    pub(super) fn olm_ensure_session(&self, pc: &Arc<PeerConn>) {
        // sessions are per device: every device of a friend, and my own other devices
        if !(pc.own || self.olm_peer_allowed(&pc.account)) || self.olm_has_session(&pc.peer) {
            return;
        }
        {
            let mut r = self.olm.requested.lock();
            if r.get(&pc.peer).map(|t| t.elapsed() < Duration::from_secs(60)).unwrap_or(false) {
                return;
            }
            r.insert(pc.peer, Instant::now());
        }
        let _ = pc.ctl.try_send(PeerMsg::OlmKeysRequest);
    }

    /// Friend asked for keys: hand out one fresh one-time key, signed by our identity.
    pub(super) fn on_olm_keys_request(&self, pc: &Arc<PeerConn>) {
        if !(pc.own || self.olm_peer_allowed(&pc.account)) {
            return;
        }
        if let Some(m) = self.olm_keys_msg() {
            let _ = pc.ctl.try_send(m);
        }
    }

    /// We couldn't decrypt what this device sent us (lost/rolled-back state, a message gap
    /// beyond the ratchet's window, a session we no longer keep): hand it a fresh one-time
    /// key unasked. Every version starts a new outbound session on `OlmKeys`, and current
    /// senders re-encrypt everything not yet acknowledged with it — nothing is lost.
    /// At most once per 10 s per device (each hand-out spends a one-time key).
    pub(super) fn olm_repair(&self, pc: &Arc<PeerConn>) {
        if !(pc.own || self.olm_peer_allowed(&pc.account)) {
            return;
        }
        {
            let mut r = self.olm.repaired.lock();
            if r.get(&pc.peer).map(|t| t.elapsed() < Duration::from_secs(10)).unwrap_or(false) {
                return;
            }
            if r.len() > 1024 {
                r.retain(|_, t| t.elapsed() < Duration::from_secs(60));
            }
            r.insert(pc.peer, Instant::now());
        }
        tracing::info!("olm: repairing the session with {:?}", pc.peer);
        if let Some(m) = self.olm_keys_msg() {
            let _ = pc.ctl.try_send(m);
        }
    }

    /// Count a failed decryption of reliable message `id`; true = give up (acknowledge).
    pub(super) fn olm_give_up(&self, dev: &PeerId, id: [u8; 16]) -> bool {
        let mut f = self.olm.fails.lock();
        let (n, first) = f.get(&(*dev, id)).copied().unwrap_or((0, Instant::now()));
        let n = n.saturating_add(1);
        f.put((*dev, id), (n, first));
        n >= OLM_MAX_FAILS && first.elapsed() >= OLM_GIVE_UP_AFTER
    }

    fn olm_keys_msg(&self) -> Option<PeerMsg> {
        let (curve, otk) = self.olm_account(|a| {
            if a.one_time_keys().is_empty() {
                a.generate_one_time_keys(10);
            }
            let otk = a.one_time_keys().values().next().copied();
            a.mark_keys_as_published();
            (a.curve25519_key(), otk)
        });
        let otk = otk?;
        let (c, o) = (curve.to_bytes(), otk.to_bytes());
        let sig = self.id.sign(&olm_key_bytes(&c, &o)).to_vec();
        Some(PeerMsg::OlmKeys { curve: c, otk: o, sig })
    }

    /// Got a friend's signed keys: start the outbound ratchet.
    pub(super) fn on_olm_keys(&self, from: PeerId, curve: [u8; 32], otk: [u8; 32], sig: Vec<u8>) -> Result<()> {
        anyhow::ensure!(self.olm_peer_allowed(&self.account_of(&from)), "ratchet keys from a stranger");
        anyhow::ensure!(from.verify(&olm_key_bytes(&curve, &otk), &sig), "bad olm key signature");
        let s = self.olm_account(|a| a.create_outbound_session(SessionConfig::version_1(), Curve25519PublicKey::from_bytes(curve), Curve25519PublicKey::from_bytes(otk)))?;
        self.load_sessions(&from);
        {
            let mut m = self.olm.sessions.lock();
            let v = m.entry(from).or_default();
            v.push(s);
            while v.len() > MAX_SESSIONS_PER_PEER {
                v.remove(0);
            }
        }
        self.save_sessions(&from);
        Ok(())
    }

    /// Forget every ratchet session with a device (revoked device; tests simulate a lost
    /// session with it). The next message from it is repaired by `olm_repair`.
    pub(crate) fn olm_drop_sessions(&self, dev: &PeerId) {
        self.olm.sessions.lock().remove(dev);
        self.olm.requested.lock().remove(dev);
        let _ = self.store.kv_del(&format!("olm.sess.{}", dev.to_base32()));
    }

    /// The frame as it goes on the wire to `to`: reliable direct-chat content is
    /// ratchet-encrypted here, at write time, so the order of ratchet steps is exactly the
    /// order on the (ordered) stream, and every re-send uses the current chain. Queues
    /// (outbox) keep the plain `Wrapped` message.
    pub(super) fn olm_for_wire(&self, to: &PeerId, m: PeerMsg) -> PeerMsg {
        match m {
            PeerMsg::Wrapped { id, inner } if matches!(*inner, PeerMsg::Chat(_) | PeerMsg::Action { .. }) => match self.olm_wrap(to, &inner) {
                Some(o) => PeerMsg::Wrapped { id, inner: Box::new(o) },
                None => PeerMsg::Wrapped { id, inner },
            },
            other => other,
        }
    }

    /// Encrypt a direct-chat message for `to` if a ratchet session exists.
    pub(super) fn olm_wrap(&self, to: &PeerId, inner: &PeerMsg) -> Option<PeerMsg> {
        if !self.olm_has_session(to) {
            return None;
        }
        let plain = rmp_serde::to_vec(inner).ok()?;
        let (t, ct) = {
            let mut m = self.olm.sessions.lock();
            let s = m.get_mut(to)?.last_mut()?;
            s.encrypt(&plain).ok()?.to_parts()
        };
        self.save_sessions(to);
        let curve = self.olm_account(|a| a.curve25519_key()).to_bytes();
        let csig = self.id.sign(&olm_identity_bytes(&curve)).to_vec();
        Some(PeerMsg::Olm { msg_type: t as u8, ciphertext: ct, curve, curve_sig: csig })
    }

    /// Decrypt a ratchet message from `from` back into the inner PeerMsg.
    pub(super) fn olm_unwrap(&self, from: &PeerId, msg_type: u8, ciphertext: &[u8], curve: [u8; 32], curve_sig: &[u8]) -> Result<PeerMsg> {
        anyhow::ensure!(from.verify(&olm_identity_bytes(&curve), curve_sig), "olm identity not signed by sender");
        let msg = OlmMessage::from_parts(msg_type as usize, ciphertext).map_err(|e| anyhow!("{e}"))?;
        self.load_sessions(from);
        // existing sessions first
        let plain = {
            let mut m = self.olm.sessions.lock();
            let v = m.entry(*from).or_default();
            let mut out = None;
            for s in v.iter_mut().rev() {
                if let Ok(p) = s.decrypt(&msg) {
                    out = Some(p);
                    break;
                }
            }
            out
        };
        let plain = match plain {
            Some(p) => p,
            None => {
                let OlmMessage::PreKey(pk) = &msg else { bail!("no matching ratchet session") };
                anyhow::ensure!(self.olm_peer_allowed(&self.account_of(from)), "no ratchet sessions with strangers");
                let r = self.olm_account(|a| a.create_inbound_session(SessionConfig::version_1(), Curve25519PublicKey::from_bytes(curve), pk))?;
                let mut m = self.olm.sessions.lock();
                let v = m.entry(*from).or_default();
                v.push(r.session);
                while v.len() > MAX_SESSIONS_PER_PEER {
                    v.remove(0);
                }
                r.plaintext
            }
        };
        self.save_sessions(from);
        Ok(crate::proto::decode_peer_msg(&plain)?)
    }
}

#[cfg(test)]
mod tests {
    use vodozemac::olm::{Account, OlmMessage, SessionConfig};

    #[tokio::test]
    async fn ratchet_sessions_only_with_friends_own_devices_and_group_co_members() {
        use super::*;
        let tmp = tempfile::tempdir().unwrap();
        let n = Node::start(NodeConfig {
            data_dir: tmp.path().join("data"),
            enable_lan: false,
            enable_upnp: false,
            enable_dht: false,
            enable_nostr: false,
            relays: Some(vec![]),
            nostr: Some(vec![]),
            stun: Some(vec![]),
            ..Default::default()
        })
        .await
        .unwrap();
        // someone's signed keys + a pre-key message, as they would arrive over the wire
        let pre_key_from = |who: &Identity| {
            let mut acc = Account::new();
            acc.generate_one_time_keys(1);
            let ours = n.olm_keys_msg().unwrap();
            let PeerMsg::OlmKeys { curve, otk, .. } = ours else { panic!() };
            let mut out = acc.create_outbound_session(SessionConfig::version_1(), Curve25519PublicKey::from_bytes(curve), Curve25519PublicKey::from_bytes(otk)).unwrap();
            let inner = rmp_serde::to_vec(&PeerMsg::Typing { on: true, conv: String::new() }).unwrap_or_default();
            let (t, ct) = out.encrypt(&inner).unwrap().to_parts();
            let c = acc.curve25519_key().to_bytes();
            let otk2 = *acc.one_time_keys().values().next().unwrap();
            let keys_sig = who.sign(&olm_key_bytes(&c, &otk2.to_bytes())).to_vec();
            (t as u8, ct, c, who.sign(&olm_identity_bytes(&c)).to_vec(), otk2.to_bytes(), keys_sig)
        };
        let stranger = Identity::generate();
        let (t, ct, c, csig, otk, ksig) = pre_key_from(&stranger);
        let sp = stranger.peer_id();
        assert!(!n.olm_peer_allowed(&sp));
        assert!(n.on_olm_keys(sp, c, otk, ksig).is_err(), "a stranger's keys start no session");
        assert!(n.olm_unwrap(&sp, t, &ct, c, &csig).is_err(), "a stranger's pre-key message starts no session");
        assert!(!n.olm_has_session(&sp));
        assert!(n.store.kv_get(&format!("olm.sess.{}", sp.to_base32())).map(|v| v == b"[]").unwrap_or(true));

        // a friend: both directions work
        let friend = Identity::generate();
        let fp = friend.peer_id();
        n.store.upsert_contact(&fp, Some("Lan"), Some(3)).unwrap();
        let (_, _, c, _, otk, ksig) = pre_key_from(&friend);
        n.on_olm_keys(fp, c, otk, ksig).unwrap();
        assert!(n.olm_has_session(&fp));
        // a pending request (status 1 / 2) is not enough
        let asked = Identity::generate();
        n.store.upsert_contact(&asked.peer_id(), None, Some(1)).unwrap();
        assert!(!n.olm_peer_allowed(&asked.peer_id()));

        // a member of one of my groups
        let co = Identity::generate();
        n.create_group("Lớp 12A", vec![co.peer_id()], 0).await.unwrap();
        assert!(n.olm_peer_allowed(&co.peer_id()));
        let (t, ct, c, csig, _, _) = pre_key_from(&co);
        n.olm_unwrap(&co.peer_id(), t, &ct, c, &csig).unwrap();
        assert!(n.olm_has_session(&co.peer_id()));
        // ...and my own account
        assert!(n.olm_peer_allowed(&n.me));
        n.shutdown();
    }

    #[test]
    fn ratchet_roundtrip_and_forward_secrecy() {
        let alice = Account::new();
        let mut bob = Account::new();
        bob.generate_one_time_keys(1);
        let otk = *bob.one_time_keys().values().next().unwrap();
        bob.mark_keys_as_published();
        let mut a = alice.create_outbound_session(SessionConfig::version_1(), bob.curve25519_key(), otk).unwrap();
        let m1 = a.encrypt("xin chào").unwrap();
        let OlmMessage::PreKey(pk) = &m1 else { panic!() };
        let mut r = bob.create_inbound_session(SessionConfig::version_1(), alice.curve25519_key(), pk).unwrap();
        assert_eq!(r.plaintext, b"xin ch\xc3\xa0o");
        let m2 = a.encrypt("tin 2").unwrap();
        assert_eq!(r.session.decrypt(&m2).unwrap(), b"tin 2");
        // a replayed message can't be decrypted again (its key is gone)
        assert!(r.session.decrypt(&m2).is_err());
    }
}
