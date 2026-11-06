//! Peer relays: friends with an open/easy NAT bridge traffic for friends stuck behind
//! hard NATs — no server needed. Everything relayed is QUIC/TLS or sealed envelopes, so
//! the relaying friend sees only ciphertext. Strict rules keep it safe and light:
//!   * only between two of the relaying node's *friends* (any device of a friend's account,
//!     and my own devices — friendship is checked by account, never by device key)
//!   * per-client token bucket (default 1 MB/s), at most 16 clients
//!   * can be disabled in settings ("Help friends connect")

use super::*;
use crate::net::relay_proto::{decode_peer_frame, encode_peer_frame, T_DATA, T_GONE, T_SIGNAL};

const MAX_PEER_RELAY_CLIENTS: usize = 16;
const MAX_PEER_RELAYS_USED: usize = 3;

pub(crate) struct Bucket {
    tokens: f64,
    rate: f64,
    last: Instant,
}

impl Bucket {
    fn take(&mut self, n: usize) -> bool {
        let now = Instant::now();
        self.tokens = (self.tokens + now.duration_since(self.last).as_secs_f64() * self.rate).min(self.rate * 2.0);
        self.last = now;
        if self.tokens >= n as f64 {
            self.tokens -= n as f64;
            true
        } else {
            false
        }
    }
}

impl Node {
    /// "Help friends connect" (Settings › Privacy, kv `relay.help_friends`, default on).
    pub fn peer_relay_enabled(&self) -> bool {
        self.store.kv_get("relay.help_friends").map(|v| v != b"0").unwrap_or(true)
    }

    /// Turn relaying for friends on or off. Off: stop serving now (every friend's relay
    /// stream is closed, so their tunnelled connections re-dial another way) and stop
    /// offering; on: offer again to connected friends.
    pub fn set_help_friends(&self, on: bool) -> Result<()> {
        self.store.kv_set("relay.help_friends", if on { b"1" } else { b"0" })?;
        if on {
            for pc in self.connected_peers() {
                self.maybe_offer_relay(&pc);
            }
        } else {
            self.relay_clients.lock().clear();
            self.relay_stop.notify_waiters();
        }
        Ok(())
    }

    fn peer_relay_rate(&self) -> f64 {
        self.store.kv_get("relay.peer_bps").and_then(|v| v.try_into().ok()).map(u64::from_le_bytes).unwrap_or(1024 * 1024) as f64
    }

    /// A friend (by account) or one of my own devices.
    fn relay_partner(&self, dev: &PeerId) -> bool {
        let acc = self.account_of(dev);
        acc == self.me || self.store.is_friend(&acc)
    }

    /// Advertise relaying capability to a friend (any of its devices) or one of my own
    /// devices if our NAT is friendly. Runs for every new connection — also one that
    /// replaced another, whose relay stream dies with it.
    pub(super) fn maybe_offer_relay(&self, pc: &Arc<PeerConn>) {
        let nat = self.net.info.read().nat.clone();
        if self.peer_relay_enabled() && matches!(nat, NatKind::Open | NatKind::Easy) && (pc.own || self.store.is_friend(&pc.account)) && pc.path != PathKind::Relay {
            let _ = pc.ctl.try_send(PeerMsg::RelayOffer { kbps: (self.peer_relay_rate() / 128.0) as u32 });
        }
    }

    pub(super) async fn on_relay_offer(self: &Arc<Self>, pc: &Arc<PeerConn>) -> Result<()> {
        if !(pc.own || self.store.is_friend(&pc.account)) {
            return Ok(());
        }
        let name = format!("peer:{}", pc.peer.to_base32());
        let on_this_conn = self.peer_relay_on.lock().get(&pc.peer).copied() == Some(pc.conn.stable_id());
        let (have, using) = {
            let r = self.net.relays.read();
            (
                r.iter().any(|x| x.url == name && x.is_connected()),
                r.iter().filter(|x| x.url.starts_with("peer:") && x.url != name && x.is_connected()).count(),
            )
        };
        // already carried by this very connection; one riding on a retired connection is
        // replaced (it dies with that connection)
        if (have && on_this_conn) || using >= MAX_PEER_RELAYS_USED {
            return Ok(());
        }
        self.open_peer_relay(pc).await
    }

    pub(super) async fn open_peer_relay(self: &Arc<Self>, pc: &Arc<PeerConn>) -> Result<()> {
        // a peer relay riding on a server relay adds nothing (it dies with that relay)
        anyhow::ensure!(pc.path != PathKind::Relay, "peer relay over a relayed connection");
        let (mut send, recv) = pc.conn.open_bi().await?;
        send.write_all(&[proto::STREAM_RELAY]).await?;
        let name = format!("peer:{}", pc.peer.to_base32());
        self.peer_relay_on.lock().insert(pc.peer, pc.conn.stable_id());
        // (the transport removes exactly this stream when it ends — a newer one with the
        // same name stays)
        self.net.add_stream_relay(name.clone(), send, recv, || {});
        tracing::info!("using {name} as peer relay");
        Ok(())
    }

    /// Make sure a relay named in a peer's ConnInfo is usable from here.
    pub(super) async fn ensure_relay(self: &Arc<Self>, url: &str) {
        if let Some(p) = url.strip_prefix("peer:") {
            if self.net.relay_status().iter().any(|(u, c)| u == url && *c) {
                return;
            }
            let Ok(f) = PeerId::from_str_any(p) else { return };
            if f == self.device || !self.relay_partner(&f) {
                return;
            }
            if let Some(pc) = self.peer(&f) {
                let _ = self.open_peer_relay(&pc).await;
            }
        } else {
            self.net.add_remote_relay(url);
        }
    }

    /// Serve a friend's relay stream.
    pub(super) async fn serve_peer_relay(self: &Arc<Self>, pc: Arc<PeerConn>, mut send: quinn::SendStream, mut recv: quinn::RecvStream) {
        let client = pc.peer;
        if !self.peer_relay_enabled() || !(pc.own || self.store.is_friend(&pc.account)) || self.relay_clients.lock().len() >= MAX_PEER_RELAY_CLIENTS {
            let _ = send.reset(1u32.into());
            return;
        }
        let (tx, mut rx) = mpsc::channel::<Vec<u8>>(512);
        // a client that reconnected (new connection) replaces its old stream
        self.relay_clients.lock().insert(client, tx.clone());
        // writer
        let writer = tokio::spawn(async move {
            while let Some(f) = rx.recv().await {
                let mut buf = (f.len() as u32).to_be_bytes().to_vec();
                buf.extend(f);
                if send.write_all(&buf).await.is_err() {
                    break;
                }
            }
        });
        let mut bucket = Bucket { tokens: self.peer_relay_rate() * 2.0, rate: self.peer_relay_rate(), last: Instant::now() };
        let mut len = [0u8; 4];
        loop {
            // (cancelling a half-read frame is fine: the stream ends right after)
            let frame = async {
                recv.read_exact(&mut len).await.ok()?;
                let n = u32::from_be_bytes(len) as usize;
                if n > 70 * 1024 {
                    return None;
                }
                let mut b = vec![0u8; n];
                recv.read_exact(&mut b).await.ok()?;
                Some(b)
            };
            let b = tokio::select! {
                f = frame => match f {
                    Some(b) => b,
                    None => break,
                },
                _ = self.relay_stop.notified() => break,
            };
            if !self.peer_relay_enabled() || !self.relay_clients.lock().get(&client).map(|t| t.same_channel(&tx)).unwrap_or(false) {
                break; // switched off (or replaced by a newer stream of this client)
            }
            let Some((t, target, payload)) = decode_peer_frame(&b) else { continue };
            let target = PeerId(target);
            if t != T_DATA && t != T_SIGNAL {
                continue;
            }
            if t == T_DATA && !bucket.take(payload.len()) {
                continue; // over budget: drop like a congested link
            }
            let out = self.relay_clients.lock().get(&target).cloned();
            match out {
                Some(o) if target != client && self.relay_partner(&target) => {
                    let _ = o.try_send(encode_peer_frame(t, &client.0, payload));
                }
                _ => {
                    if let Some(o) = self.relay_clients.lock().get(&client).cloned() {
                        let _ = o.try_send(encode_peer_frame(T_GONE, &target.0, &[]));
                    }
                }
            }
        }
        {
            // only our own entry: a newer stream of the same client stays
            let mut rc = self.relay_clients.lock();
            if rc.get(&client).map(|t| t.same_channel(&tx)).unwrap_or(false) {
                rc.remove(&client);
            }
        }
        drop(tx);
        writer.abort();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// #11: peer relays are given to / taken from friends by ACCOUNT (a friend's linked
    /// device too) and my own devices — not by device key; strangers never.
    #[tokio::test]
    async fn relay_partners_are_friends_by_account() {
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
        let lan = Identity::generate();
        let la = lan.peer_id();
        n.store.upsert_contact(&la, Some("Lan"), Some(3)).unwrap();
        let phone = Identity::generate();
        let mut e = crate::devices::DeviceEntry::new(phone.peer_id(), "Phone", 1, 0, 1);
        e.proof = crate::devices::sign_accept(&phone, &la);
        let body = crate::devices::DeviceListBody { v: 1, account: la, version: 2, devices: vec![crate::devices::DeviceEntry::new(la, "Main", 3, 1, 1), e], revoked: vec![] };
        let raw = crate::devices::SignedDeviceList::sign(&lan, &body).unwrap().encode();
        assert!(n.accept_device_list(&raw, la, false).unwrap());
        assert!(n.relay_partner(&la));
        assert!(n.relay_partner(&phone.peer_id()), "a friend's linked device is a relay partner");
        assert!(!n.relay_partner(&Identity::generate().peer_id()));
        n.shutdown();
    }

    /// "Help friends connect" off: stop serving at once and stop offering; on again: offer.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn help_friends_switch_stops_serving_now() {
        let tmp = tempfile::tempdir().unwrap();
        let mk = |d: &str| NodeConfig {
            data_dir: tmp.path().join(d),
            enable_lan: false,
            enable_upnp: false,
            enable_dht: false,
            enable_nostr: false,
            relays: Some(vec![]),
            nostr: Some(vec![]),
            stun: Some(vec![]),
            ..Default::default()
        };
        let a = Node::start(mk("a")).await.unwrap();
        let b = Node::start(mk("b")).await.unwrap();
        a.store.upsert_contact(&b.me, Some("b"), Some(3)).unwrap();
        b.store.upsert_contact(&a.me, Some("a"), Some(3)).unwrap();
        assert!(a.peer_relay_enabled(), "on by default");
        let addr: SocketAddr = format!("127.0.0.1:{}", a.net.local_port()).parse().unwrap();
        let c = b.net.dial_direct(a.device, vec![addr], Duration::from_secs(5)).await.unwrap();
        let pc = b.clone().setup_conn(c, PathKind::Lan, b.device, None).await.unwrap();
        // b uses a as its peer relay
        b.open_peer_relay(&pc).await.unwrap();
        let name = format!("peer:{}", a.device.to_base32());
        let served = || a.relay_clients.lock().contains_key(&b.device);
        let end = Instant::now() + Duration::from_secs(5);
        while Instant::now() < end && !served() {
            // the stream reaches a with the first frame
            let _ = b.net.send_signal(&PeerId([9; 32]), vec![1, 2, 3], &[]).await;
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        assert!(served(), "relay stream not served");
        a.set_help_friends(false).unwrap();
        assert!(!a.peer_relay_enabled());
        assert!(a.relay_clients.lock().is_empty());
        // b's relay through a ends (stream closed) — no waiting for a frame or a restart
        let end = Instant::now() + Duration::from_secs(5);
        while Instant::now() < end && b.net.relay_status().iter().any(|(u, ok)| *u == name && *ok) {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(!b.net.relay_status().iter().any(|(u, ok)| *u == name && *ok), "still relaying after switching it off");
        // a new stream is refused while off
        b.open_peer_relay(&pc).await.unwrap();
        let _ = b.net.send_signal(&PeerId([9; 32]), vec![1], &[]).await;
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(!served());
        a.set_help_friends(true).unwrap();
        assert!(a.peer_relay_enabled());
        a.shutdown();
        b.shutdown();
    }

    #[test]
    fn bucket_limits() {
        let mut b = Bucket { tokens: 1000.0, rate: 1000.0, last: Instant::now() };
        assert!(b.take(800));
        assert!(!b.take(800));
    }
}
