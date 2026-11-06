//! Per-connection tasks, signaling, accept loop and background maintenance.

use super::*;

/// Content budget of one stranger (burst, then per second). Every message is charged
/// exactly once (a `Wrapped` one by its content, after dedupe): ~15 at once, then 1/s.
const STRANGER_BURST: f64 = 15.0;
const STRANGER_RATE: f64 = 1.0;
/// Budget shared by all strangers together (~50 at once, then ~5 messages/s).
const STRANGERS_BURST: f64 = 50.0;
const STRANGERS_RATE: f64 = 5.0;
/// "Solicited" devices (I dialed them) may answer / dial back for this long.
const SOLICITED_FOR: Duration = Duration::from_secs(600);
/// Largest sealed signal sent as live mail through Nostr (relays cap event sizes).
const NOSTR_MAIL_MAX: usize = 12 * 1024;
/// Incoming signals handled at once (one task each); more are dropped (senders retry).
pub(crate) const MAX_SIGNAL_TASKS: usize = 64;
/// Offers from one device may arrive out of order (several channels) by this much; an
/// offer older than that behind the newest one seen is a replay.
const OFFER_REORDER_MS: u64 = 30_000;
/// A relayed connection survives its relay's WebSocket being down this long (it
/// reconnects and the QUIC connection rides on).
const RELAY_DOWN_GRACE: Duration = Duration::from_secs(10);
/// Relay → direct upgrade attempts after failures: 30 s doubling up to 30 min.
const UPGRADE_FIRST_WAIT: Duration = Duration::from_secs(30);
const UPGRADE_MAX_WAIT: Duration = Duration::from_secs(1800);

/// A handler's "not now": the message is valid but can't be taken yet (e.g. too many
/// pending friend requests). It is left unacknowledged so the sender retries later —
/// never acknowledged and then dropped.
#[derive(Debug)]
pub(crate) struct NotNow(pub &'static str);

impl std::fmt::Display for NotNow {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "not now: {}", self.0)
    }
}

impl std::error::Error for NotNow {}

fn is_not_now(e: &anyhow::Error) -> bool {
    e.downcast_ref::<NotNow>().is_some()
}
/// Content budget of a trusted sender (friend, own device): burst, then per second. Over
/// it the sender is slowed down (its stream stalls), never dropped.
const FRIEND_BURST: f64 = 250.0;
const FRIEND_RATE: f64 = 40.0;

/// Per-sender content budgets (`inbound_allowed`): trusted senders by key; strangers in
/// a bounded LRU; all strangers together in one shared bucket.
pub(crate) struct InboundLimits {
    trusted: HashMap<PeerId, (f64, Instant)>,
    strangers: lru::LruCache<PeerId, (f64, Instant)>,
    all: Option<(f64, Instant)>,
}

impl Default for InboundLimits {
    fn default() -> Self {
        InboundLimits { trusted: HashMap::new(), strangers: lru::LruCache::new(std::num::NonZeroUsize::new(2048).unwrap()), all: None }
    }
}

fn msg_kind(m: &PeerMsg) -> String {
    match m {
        PeerMsg::Wrapped { inner, .. } => format!("Wrapped({})", msg_kind(inner)),
        other => {
            let d = format!("{other:?}");
            d.split(|c: char| !c.is_alphanumeric()).next().unwrap_or("?").to_string()
        }
    }
}

impl Node {
    pub(super) fn spawn_control(
        self: Arc<Self>,
        pc: Arc<PeerConn>,
        mut send: quinn::SendStream,
        mut recv: quinn::RecvStream,
        mut rx: mpsc::Receiver<PeerMsg>,
    ) {
        // writer
        let pc_w = pc.clone();
        let pc_w_store = self.store.clone();
        let node_w = self.clone();
        tokio::spawn(async move {
            let hello = PeerMsg::Hello {
                version: proto::PROTO_VERSION,
                name: String::new(),
                app: super::push::app_string(),
                os: std::env::consts::OS.into(),
            };
            let _ = &hello;
            loop {
                let m = tokio::select! {
                    // acknowledgements first, batched: never stuck behind a full queue
                    biased;
                    _ = pc_w.ack_notify.notified() => {
                        let ids = std::mem::take(&mut *pc_w.acks.lock());
                        let mut broken = false;
                        for chunk in ids.chunks(1000) {
                            if proto::write_frame(&mut send, &PeerMsg::Ack { ids: chunk.to_vec() }).await.is_err() {
                                broken = true;
                                break;
                            }
                        }
                        if broken {
                            pc_w.conn.close(2u32.into(), b"control stream failed");
                            break;
                        }
                        continue;
                    }
                    m = rx.recv() => match m {
                        Some(m) => m,
                        None => break,
                    },
                };
                // ratchet-encrypt here: wire order == ratchet order, re-sends use the current chain
                if !matches!(m, PeerMsg::Ping { .. } | PeerMsg::Pong { .. }) {
                    pc_w.touch_active();
                }
                let m = node_w.olm_for_wire(&pc_w.peer, m);
                if let PeerMsg::Wrapped { id, .. } = &m {
                    pc_w.mark_sent(*id);
                }
                match proto::write_frame(&mut send, &m).await {
                    Ok(()) => {}
                    Err(e) if e.to_string().contains("frame too large") => {
                        // never kill the whole control channel for one oversized message — but
                        // never show it as sent either: it failed, and the user is told why
                        tracing::warn!("dropping oversized control frame to {:?}", pc_w.peer);
                        if let PeerMsg::Wrapped { id, .. } = &m {
                            let _ = pc_w_store.outbox_remove(id, &pc_w.peer);
                            node_w.mark_send_failed(id, "err.message_too_large");
                        }
                    }
                    Err(_) => {
                        // broken stream: close the connection so peer()/connect() don't keep a zombie
                        pc_w.conn.close(2u32.into(), b"control stream failed");
                        break;
                    }
                }
            }
            let _ = send.finish();
        });
        // say hello first; which app / OS we run is only for friends and my own devices
        let trusted = pc.own || self.store.is_friend(&pc.account);
        let _ = pc.ctl.try_send(PeerMsg::Hello {
            version: proto::PROTO_VERSION,
            name: self.name(),
            app: if trusted { super::push::app_string() } else { String::new() },
            os: if trusted { std::env::consts::OS.into() } else { String::new() },
        });
        // reader
        tokio::spawn(async move {
            while let Ok(m) = proto::read_frame_lenient(&mut recv).await {
                let peer = pc.peer;
                // a message kind from a newer version: skip it, keep the connection
                let Some(m) = m else {
                    tracing::debug!("skipping undecodable control frame from {peer:?}");
                    continue;
                };
                let kind = msg_kind(&m);
                tracing::trace!("recv {kind} from {peer:?}");
                if !matches!(m, PeerMsg::Ping { .. } | PeerMsg::Pong { .. }) {
                    pc.touch_active();
                }
                let t0 = Instant::now();
                if let Err(e) = self.handle_msg(&pc, m).await {
                    tracing::debug!("handle {kind} from {peer:?}: {e:#}");
                }
                let dt = t0.elapsed();
                if dt > Duration::from_millis(500) {
                    tracing::warn!("slow handler: {kind} from {peer:?} took {} ms", dt.as_millis());
                }
            }
        });
    }

    pub(super) fn spawn_conn_tasks(self: Arc<Self>, pc: Arc<PeerConn>) {
        // bi streams (control from dialer)
        let node = self.clone();
        let p = pc.clone();
        tokio::spawn(async move {
            while let Ok((send, mut recv)) = p.conn.accept_bi().await {
                let mut kind = [0u8; 1];
                if recv.read_exact(&mut kind).await.is_err() {
                    continue;
                }
                if kind[0] == proto::STREAM_CONTROL {
                    if let Some(rx) = p.ctl_rx.lock().take() {
                        node.clone().spawn_control(p.clone(), send, recv, rx);
                    }
                } else if kind[0] == proto::STREAM_RELAY {
                    let n = node.clone();
                    let p2 = p.clone();
                    tokio::spawn(async move { n.serve_peer_relay(p2, send, recv).await });
                }
            }
        });
        // uni streams (files, media)
        let node = self.clone();
        let p = pc.clone();
        tokio::spawn(async move {
            while let Ok(mut recv) = p.conn.accept_uni().await {
                let node = node.clone();
                let p = p.clone();
                tokio::spawn(async move {
                    let mut kind = [0u8; 1];
                    if recv.read_exact(&mut kind).await.is_err() {
                        return;
                    }
                    match kind[0] {
                        proto::STREAM_FILE => {
                            if let Err(e) = node.receive_file_stream(&p, recv).await {
                                tracing::warn!("file stream: {e:#}");
                            }
                        }
                        proto::STREAM_MEDIA => node.remote.on_media_stream(&node, &p, recv).await,
                        proto::STREAM_SYNC => node.on_sync_stream(&p, recv).await,
                        _ => {}
                    }
                });
            }
        });
        // datagrams (audio, input)
        let node = self.clone();
        let p = pc.clone();
        tokio::spawn(async move {
            while let Ok(d) = p.conn.read_datagram().await {
                node.remote.on_datagram(&node, &p, d);
            }
        });
        // closed watcher
        let node = self;
        tokio::spawn(async move {
            let reason = pc.conn.closed().await;
            tracing::info!("disconnected {:?}: {reason}", pc.peer);
            // one of my own devices closed us out as revoked (it holds a list, signed by the
            // account key, where this device is revoked)
            if let quinn::ConnectionError::ApplicationClosed(ac) = &reason {
                if pc.own && !node.is_primary() && ac.error_code == quinn::VarInt::from_u32(3) {
                    node.self_revoke(false, false);
                }
            }
            let still_current = {
                let mut peers = node.peers.write();
                let cur = peers.get(&pc.peer).map(|c| Arc::ptr_eq(c, &pc)).unwrap_or(false);
                if cur {
                    peers.remove(&pc.peer);
                }
                cur
            };
            if still_current {
                let _ = node.store.set_contact_field(&pc.account, "last_seen", rusqlite::types::Value::Integer(now_ms() as i64));
                node.store.device_touch(&pc.peer, None);
                // an account is offline only once none of its devices is connected
                node.emit(
                    "presence",
                    json!({"peer": pc.account.to_base32(), "device": pc.peer.to_base32(), "online": node.is_online(&pc.account) && !pc.own, "own": pc.own, "device_online": false}),
                );
                if pc.own {
                    node.emit_devices();
                }
                node.remote.on_disconnect(&node, &pc.peer);
                // connections tunnelled through this friend (peer relay) are dead too: close
                // them now so they are re-dialed instead of idling out
                node.drop_peer_relay_via(&pc.peer);
                // Try to come back automatically if it was a friend or my own device (network
                // change, NAT rebinding, sleep…): fresh reflexive address, quick retries
                // (2, 5, 10, 20, 40 s) instead of waiting for the 2-minute sweep.
                if (node.store.is_friend(&pc.account) || pc.own) && !*node.shutdown.borrow() {
                    if pc.path != PathKind::Relay {
                        *node.info_refreshed.lock() = None;
                    }
                    let n2 = node.clone();
                    let peer = pc.peer;
                    tokio::spawn(async move {
                        for wait in [2u64, 5, 10, 20, 40] {
                            tokio::time::sleep(Duration::from_secs(wait)).await;
                            if *n2.shutdown.borrow() || n2.usable_peer(&peer).is_some() {
                                return;
                            }
                            if n2.connect(peer).await.is_ok() {
                                return;
                            }
                        }
                    });
                }
            }
        });
    }

    pub(super) async fn on_connected(self: &Arc<Self>, pc: &Arc<PeerConn>) {
        let peer = pc.peer;
        self.backoff.lock().remove(&peer);
        self.mail_retry.lock().remove(&peer);
        let _ = self.store.set_contact_field(&pc.account, "last_seen", rusqlite::types::Value::Integer(now_ms() as i64));
        self.store.device_touch(&peer, None);
        self.emit(
            "presence",
            json!({"peer": pc.account.to_base32(), "device": peer.to_base32(), "own": pc.own, "online": !pc.own, "device_online": true, "path": pc.path,
                   "remote_addr": crate::util::canon(pc.conn.remote_address()).to_string()}),
        );
        if pc.own {
            self.emit_devices();
        }
        self.maybe_offer_relay(pc);
        if !pc.own {
            self.send_profile(pc);
        }
        self.push_on_connected(&peer);
        self.olm_ensure_session(pc);
        self.resume_transfers(&peer);
        // flush outbox / mailbox / group sync from a separate task with back-pressure
        // (await on a bounded channel; nothing is dropped, the control reader is never blocked)
        let me = self.clone();
        let pc2 = pc.clone();
        tokio::spawn(async move {
            me.pump_outbox(&pc2).await;
            if !pc2.alive() {
                return;
            }
            // mail we keep for them: only removed from our store once handed to the stream
            if let Ok(items) = me.store.mailbox_take(&peer) {
                let mut it = items.into_iter();
                while let Some(sealed) = it.next() {
                    if pc2.ctl.send(PeerMsg::Mail { sealed: sealed.clone() }).await.is_err() {
                        // connection died: put the rest back
                        let _ = me.store.mailbox_put(&crate::crypto::random_bytes::<16>(), &peer, &sealed);
                        for rest in it {
                            let _ = me.store.mailbox_put(&crate::crypto::random_bytes::<16>(), &peer, &rest);
                        }
                        return;
                    }
                }
            }
            let shared: Vec<Gid> = me.groups.read().values().filter(|g| g.is_member(&me.me) && g.is_member(&pc2.account)).map(|g| g.gid).collect();
            for gid in shared {
                let heads = me.store.group_log_heads(&gid);
                if pc2.ctl.send(PeerMsg::GroupSync { gid, heads }).await.is_err() {
                    return;
                }
            }
        });
    }

    /// Send everything queued for this device that this connection hasn't carried yet,
    /// oldest first, awaiting the bounded control channel (back-pressure, nothing dropped).
    /// One pump per connection at a time; items already written to this connection are
    /// skipped (the stream is ordered and reliable — the receiver acks them as it gets to
    /// them) unless they have been waiting for an ack unusually long.
    pub(super) async fn pump_outbox(self: &Arc<Self>, pc: &Arc<PeerConn>) {
        use std::sync::atomic::Ordering::SeqCst;
        if pc.flushing.swap(true, SeqCst) {
            return;
        }
        let mut after = 0i64;
        'pages: loop {
            let page = self.store.outbox_page(&pc.peer, after, 256).unwrap_or_default();
            if page.is_empty() {
                break;
            }
            for (rowid, id, payload) in page {
                after = rowid;
                let Ok(id) = <[u8; 16]>::try_from(id.as_slice()) else { continue };
                if pc.sent_recently(&id) {
                    continue;
                }
                let Ok(m) = crate::proto::decode_peer_msg(&payload) else { continue };
                if matches!(&m, PeerMsg::Wrapped { inner, .. } if matches!(**inner, PeerMsg::Ext { .. })) && !self.dev_speaks_v3(&pc.peer) {
                    continue;
                }
                pc.mark_sent(id);
                if !pc.alive() || pc.ctl.send(m).await.is_err() {
                    break 'pages;
                }
            }
        }
        pc.flushing.store(false, SeqCst);
    }

    /// A sender whose content is never dropped (friends, people I asked, my own devices).
    fn trusted_sender(&self, from: &PeerId) -> bool {
        *from == self.me || self.store.contact(from).map(|c| c.status == 1 || c.status == 3).unwrap_or(false)
    }

    /// Anti-spam: per-peer budget for content messages (chat, group, actions, stories).
    /// Friends: 40 msg/s sustained, burst 250 — far above human typing, slows flooding bots/peers.
    /// Over budget, a trusted sender is slowed down (`handle_msg` waits, which stalls its
    /// stream), never dropped; a stranger's message is dropped unacknowledged.
    pub(super) fn inbound_allowed(&self, from: &PeerId, m: &PeerMsg) -> bool {
        let content = matches!(
            m,
            // (group envelopes are excluded: anti-entropy sync legitimately bursts hundreds;
            // groups have their own slow mode / admin tools)
            PeerMsg::Chat(_)
                | PeerMsg::Olm { .. }
                | PeerMsg::Action { .. }
                | PeerMsg::Story { .. }
                | PeerMsg::FriendRequest { .. }
                | PeerMsg::FileOffer { .. }
                | PeerMsg::Profile { .. }
                | PeerMsg::ProfileV2 { .. }
        );
        if !content {
            return true;
        }
        // Strangers (anyone we haven't accepted or asked: identities are free) get a much
        // smaller budget, and all of them together share one more (key: the all-zero id),
        // so a swarm of fresh identities can't multiply the per-peer budget.
        let trusted = self.trusted_sender(from);
        let now = Instant::now();
        let refill = |e: &mut (f64, Instant), burst: f64, rate: f64| {
            e.0 = (e.0 + now.duration_since(e.1).as_secs_f64() * rate).min(burst);
            e.1 = now;
        };
        let mut lim = self.inbound_limits.lock();
        if trusted {
            if lim.trusted.len() > 4096 {
                lim.trusted.retain(|_, (_, t)| t.elapsed() < Duration::from_secs(600));
            }
            let e = lim.trusted.entry(*from).or_insert((FRIEND_BURST, now));
            refill(e, FRIEND_BURST, FRIEND_RATE);
            let ok = e.0 >= 1.0;
            if ok {
                e.0 -= 1.0;
            }
            return ok;
        }
        // strangers: their own bounded LRU, so a swarm of identities can neither grow memory
        // nor push out anyone else's state; the shared budget lives apart from it
        let InboundLimits { strangers, all, .. } = &mut *lim;
        let e = strangers.get_or_insert_mut(*from, || (STRANGER_BURST, now));
        refill(e, STRANGER_BURST, STRANGER_RATE);
        if e.0 < 1.0 {
            return false;
        }
        let g = all.get_or_insert((STRANGERS_BURST, now));
        refill(g, STRANGERS_BURST, STRANGERS_RATE);
        if g.0 < 1.0 {
            return false;
        }
        g.0 -= 1.0;
        e.0 -= 1.0;
        true
    }

    /// One frame from a connection's control stream: dedupe, budget, then dispatch.
    async fn handle_msg(self: &Arc<Self>, pc: &Arc<PeerConn>, m: PeerMsg) -> Result<()> {
        let from = pc.account;
        let dev = pc.peer;
        // already processed (re-send / mail copy / reconnect flush): ack, costs no budget
        if let PeerMsg::Wrapped { id, .. } = &m {
            if self.seen_wrapped.lock().contains(&(dev, *id)) {
                pc.queue_ack(&[*id]);
                return Ok(());
            }
        }
        let inner_ref = match &m {
            PeerMsg::Wrapped { inner, .. } => inner.as_ref(),
            other => other,
        };
        if !self.inbound_allowed(&from, inner_ref) {
            if !self.trusted_sender(&from) {
                tracing::warn!("rate limit: dropping {} from {from:?}", msg_kind(inner_ref));
                // not acked → the sender's outbox retries later
                return Ok(());
            }
            // A friend over budget is slowed down, not dropped: waiting here stalls this
            // connection's stream (QUIC flow control pushes back to the sender's queue).
            let mut slowed = false;
            while !self.inbound_allowed(&from, inner_ref) {
                if !slowed {
                    tracing::debug!("rate limit: slowing down {from:?}");
                    slowed = true;
                }
                if !pc.alive() || *self.shutdown.borrow() {
                    return Ok(());
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        }
        self.dispatch(pc, m).await
    }

    async fn dispatch(self: &Arc<Self>, pc: &Arc<PeerConn>, m: PeerMsg) -> Result<()> {
        // account-level handlers see the account; transport-level ones the device
        let from = pc.account;
        let dev = pc.peer;
        let inner_ref = match &m {
            PeerMsg::Wrapped { inner, .. } => inner.as_ref(),
            other => other,
        };
        // my own devices talk to me through sync, never as a "friend"
        if pc.own && !Self::own_device_msg(inner_ref) {
            tracing::debug!("ignoring {} from own device {dev:?}", msg_kind(inner_ref));
            if let PeerMsg::Wrapped { id, .. } = &m {
                pc.queue_ack(&[*id]);
            }
            return Ok(());
        }
        match m {
            PeerMsg::Wrapped { id, inner } => {
                if matches!(*inner, PeerMsg::Wrapped { .. }) {
                    bail!("nested wrapper");
                }
                // already processed (resend / mail copy / reconnect flush): just ack again
                if self.seen_wrapped.lock().contains(&(dev, id)) {
                    pc.queue_ack(&[id]);
                    return Ok(());
                }
                // Ratchet-encrypted content is decrypted before it counts as received: if it
                // can't be (desynced or lost session, gap beyond the ratchet window), it stays
                // unacknowledged and the sender gets a fresh key to start a new session with;
                // its next re-send is encrypted with that session.
                let inner = match *inner {
                    PeerMsg::Olm { msg_type, ciphertext, curve, curve_sig } => match self.olm_unwrap(&dev, msg_type, &ciphertext, curve, &curve_sig) {
                        Ok(p) => p,
                        Err(e) => {
                            self.olm_repair(pc);
                            if self.olm_give_up(&dev, id) {
                                self.seen_wrapped.lock().put((dev, id), ());
                                pc.queue_ack(&[id]);
                            }
                            bail!("undecryptable ratchet message: {e:#}");
                        }
                    },
                    other => other,
                };
                if matches!(inner, PeerMsg::Olm { .. } | PeerMsg::Wrapped { .. }) {
                    bail!("nested wrapper");
                }
                self.seen_wrapped.lock().put((dev, id), ());
                let r = Box::pin(self.dispatch(pc, inner)).await;
                if let Err(e) = &r {
                    if is_not_now(e) {
                        // valid but can't be taken yet: unacknowledged, processed on a re-send
                        self.seen_wrapped.lock().pop(&(dev, id));
                        return r;
                    }
                }
                // ack even on (permanent) handling errors so the sender stops retrying
                pc.queue_ack(&[id]);
                r?;
            }
            PeerMsg::OlmKeysRequest => self.on_olm_keys_request(pc),
            PeerMsg::OlmKeys { curve, otk, sig } => {
                self.on_olm_keys(dev, curve, otk, sig)?;
                // a new session (asked for, or the receiver couldn't decrypt us): whatever
                // is still unacknowledged goes out again, encrypted with it
                pc.sent.lock().clear();
                let (me, pc2) = (self.clone(), pc.clone());
                tokio::spawn(async move { me.pump_outbox(&pc2).await });
            }
            PeerMsg::Olm { msg_type, ciphertext, curve, curve_sig } => {
                let inner = self.olm_unwrap(&dev, msg_type, &ciphertext, curve, &curve_sig)?;
                anyhow::ensure!(matches!(inner, PeerMsg::Chat(_) | PeerMsg::Action { .. }), "unexpected ratchet payload");
                Box::pin(self.dispatch(pc, inner)).await?;
            }
            PeerMsg::Hello { version, name, app, .. } => {
                self.push_on_hello(pc, &app);
                let name: String = name.chars().take(48).collect();
                if version > proto::PROTO_VERSION + 10 {
                    tracing::warn!("{from:?} speaks newer protocol {version}");
                }
                self.record_peer_proto(&dev, version);
                pc.proto.store(version, std::sync::atomic::Ordering::Relaxed);
                self.store.device_touch(&dev, Some(version));
                *pc.name.write() = name.clone();
                if !pc.own {
                    if let Some(c) = self.store.contact(&from) {
                        if c.name != name && !name.is_empty() {
                            self.store.upsert_contact(&from, Some(&name), None)?;
                            self.emit_contact(&from);
                        }
                    } else if !name.is_empty() && self.groups.read().values().any(|g| g.is_member(&from)) {
                        // a fellow group member who isn't a contact: remember the name it
                        // introduces itself with, so the member list shows names
                        self.set_member_name(&from, &name);
                    }
                }
                if version >= proto::PROTO_V3 {
                    self.device_sync_on_hello(pc);
                    self.on_v3_hello(pc);
                    self.share_dht_key(pc);
                }
            }
            PeerMsg::Profile { name } => {
                let name: String = name.chars().take(48).collect();
                *pc.name.write() = name.clone();
                if self.store.contact(&from).is_some() {
                    self.store.upsert_contact(&from, Some(&name), None)?;
                    self.emit_contact(&from);
                }
            }
            PeerMsg::RelayOffer { .. } => self.on_relay_offer(pc).await?,
            PeerMsg::ProfileV2 { name, bio, status, avatar, cover, bot, username } => {
                let name: String = name.chars().take(48).collect();
                *pc.name.write() = name.clone();
                self.on_profile_v2(from, name, bio, status, avatar, cover, bot, username)?;
            }
            PeerMsg::JoinRequest { gid, expires, sig } => self.on_join_request(from, gid, expires, sig).await?,
            PeerMsg::Story { id, author, created, text, image, bg, sig } => self.on_story(from, id, author, created, text, image, bg, sig)?,
            PeerMsg::StorySeen { id } => self.on_story_seen(from, id)?,
            PeerMsg::GroupRead { gid, conv, upto_hlc } => self.on_group_read(from, gid, conv, upto_hlc)?,
            PeerMsg::BotGroupMsg { gid, channel, msg } => self.on_bot_group_msg(from, gid, channel, *msg)?,
            PeerMsg::JoinPublic { gid } => self.on_join_public(from, gid).await?,
            PeerMsg::BotGroupPost { gid, channel, msg } => self.on_bot_group_post(from, gid, channel, *msg)?,
            PeerMsg::Ping { t } => {
                let _ = pc.ctl.try_send(PeerMsg::Pong { t });
            }
            PeerMsg::Pong { .. } => {}
            PeerMsg::FriendRequest { name, note } => self.on_friend_request(from, name, note)?,
            PeerMsg::FriendAccept { name } => self.on_friend_accept(from, name)?,
            PeerMsg::FriendRemove => {
                if self.store.is_friend(&from) {
                    self.store.upsert_contact(&from, None, Some(0))?;
                    self.emit_contact(&from);
                    self.forget_friend_keys(&from);
                    self.rotate_dht_key();
                }
            }
            PeerMsg::Chat(msg) => self.on_direct_chat(pc, msg).await?,
            PeerMsg::Action { id, author, hlc, action, sig } => self.on_direct_action(from, id, author, hlc, action, sig)?,
            PeerMsg::Ack { ids } => {
                for id in ids.iter().take(1000) {
                    pc.sent.lock().remove(id);
                }
                self.on_acks(dev, from, pc.own, ids)?;
            }
            PeerMsg::Read { upto_hlc } => {
                let conv = direct_conv(&from);
                let ids = self.store.mark_conv_read_upto(&conv, &from, upto_hlc as i64)?;
                // ids are *their* messages; we need ours → statuses of our messages to them
                let _ = ids;
                let c = self.store.conn_mark_mine_read(&conv, &self.me, upto_hlc as i64)?;
                for id in c {
                    self.emit("message_update", json!({"conv": conv, "id": hex::encode(id), "status": 3}));
                }
            }
            PeerMsg::Typing { on, .. } => {
                self.emit("typing", json!({"conv": direct_conv(&from), "peer": from.to_base32(), "on": on}));
            }
            PeerMsg::Group { gid, env } => self.on_group_envelope(Some((from, dev)), gid, env, true).await?,
            PeerMsg::GroupSync { gid, heads } => self.on_group_sync(pc, gid, heads).await?,
            PeerMsg::GroupWelcome { sealed } => self.on_group_welcome(dev, &sealed).await?,
            PeerMsg::GroupKey { sealed } => self.on_group_key(dev, &sealed)?,
            PeerMsg::GroupTyping { gid, on } => {
                if self.groups.read().get(&gid).map(|g| g.is_member(&from)).unwrap_or(false) {
                    self.emit("typing", json!({"conv": format!("g:{}", hex::encode(gid)), "peer": from.to_base32(), "on": on}));
                }
            }
            PeerMsg::StoreFor { to, id, sealed } => {
                // Only keep mail for our friends (and own devices) from our friends / own
                // devices (bounded, encrypted to the device `to`).
                let to_acc = self.account_of(&to);
                if (self.store.is_friend(&from) || pc.own) && (self.store.is_friend(&to_acc) || to_acc == self.me) {
                    if to == self.device {
                        self.on_mail(&sealed).await?;
                    } else if let Some(c) = self.peer(&to) {
                        let _ = c.ctl.try_send(PeerMsg::Mail { sealed });
                    } else {
                        self.store.mailbox_put(&id, &to, &sealed)?;
                    }
                }
            }
            PeerMsg::Mail { sealed } => self.on_mail(&sealed).await?,
            // standalone offers are not used by this version (offers ride on signed chat messages)
            PeerMsg::FileOffer { .. } => {}
            PeerMsg::FileRequest { file_id, offset } => self.on_file_request(pc.clone(), file_id, offset).await?,
            PeerMsg::FileCancel { file_id } => self.file_cancel_from(&from, &dev, pc.own, &file_id),
            PeerMsg::FileDone { file_id, ok } => self.on_file_done(&from, &file_id, ok),
            PeerMsg::PushReg { blob } => self.push_on_reg(dev, &blob)?,
            PeerMsg::Ext { kind, body } => self.on_ext(pc, kind, body).await?,
            other => self.remote.on_control(self, pc, other).await?,
        }
        Ok(())
    }

    /// Mail = a sealed PeerMsg delivered while we were offline (via relay mailbox or friend).
    pub(super) async fn on_mail(self: &Arc<Self>, sealed: &[u8]) -> Result<()> {
        // sealed by a device; account-level handlers get its account
        let (dev, ts, body) = open_sealed(&self.id, sealed)?;
        if dev == self.device || now_ms().saturating_sub(ts) > 30 * 86_400_000 {
            return Ok(());
        }
        let mut m: PeerMsg = crate::proto::decode_peer_msg(&body)?;
        let mut wrapped = None;
        if let PeerMsg::Wrapped { id, inner } = m {
            if self.seen_wrapped.lock().contains(&(dev, id)) {
                // offline copy of something we already have: ack if the sender is online
                self.ack_now_dev(&dev, id);
                return Ok(());
            }
            wrapped = Some(id);
            m = *inner;
        }
        if let PeerMsg::Olm { msg_type, ciphertext, curve, curve_sig } = m {
            // undecryptable offline copy (sealed with an older ratchet step than we keep, or
            // a session we lost): not acked, so the sender re-sends it, freshly encrypted
            m = match self.olm_unwrap(&dev, msg_type, &ciphertext, curve, &curve_sig) {
                Ok(m) => m,
                Err(e) => {
                    if let Some(pc) = self.peer(&dev) {
                        self.olm_repair(&pc);
                    }
                    return Err(e);
                }
            };
            anyhow::ensure!(matches!(m, PeerMsg::Chat(_) | PeerMsg::Action { .. }), "unexpected ratchet payload");
        }
        // a device we don't know yet: its signed content carries its certificate
        if self.store.device_account(&dev).is_none() {
            let sig = match &m {
                PeerMsg::Chat(c) => Some((c.author, c.sig.clone())),
                PeerMsg::Action { author, sig, .. } => Some((*author, sig.clone())),
                _ => None,
            };
            if let Some(cert) = sig.and_then(|(a, s)| crate::devices::devsig_cert(&a, &s)).filter(|c| c.device == dev) {
                self.learn_cert(&cert);
            }
        }
        let from = self.account_of(&dev);
        if self.store.is_blocked(&from) || self.is_revoked(&from, &dev) {
            return Ok(());
        }
        let own = from == self.me;
        // offline copies from strangers (relay mailboxes accept anyone's) share the
        // strangers' budget; friends' backlogs are never throttled (already acked)
        let trusted = own || self.store.contact(&from).map(|c| c.status == 1 || c.status == 3).unwrap_or(false);
        if !trusted && !self.inbound_allowed(&from, &m) {
            tracing::debug!("rate limit: dropping offline {} from {from:?}", msg_kind(&m));
            return Ok(());
        }
        if let Some(id) = wrapped {
            self.seen_wrapped.lock().put((dev, id), ());
        }
        let r = self.on_mail_msg(dev, from, own, m).await;
        if let (Err(e), Some(id)) = (&r, wrapped) {
            if is_not_now(e) {
                self.seen_wrapped.lock().pop(&(dev, id));
                return r;
            }
        }
        // received (also on a permanent handling error): ack — over the connection if the
        // sender is connected, else (batched) by sealed signaling mail, so a sender that
        // can't reach us directly stops re-sending
        if let Some(id) = wrapped {
            if !self.ack_now_dev(&dev, id) {
                self.queue_mail_ack(dev, id);
            }
        }
        r
    }

    /// Acknowledged by `dev` (of account `from`): drop from the outbox, mark delivered.
    fn on_acks(&self, dev: PeerId, from: PeerId, own: bool, ids: Vec<[u8; 16]>) -> Result<()> {
        for id in ids.into_iter().take(1000) {
            self.store.outbox_remove(&id, &dev)?;
            if let Some(m) = self.store.message(&id) {
                // only our own messages in the conversation with this peer (or its groups)
                let ours = m.author == self.me.to_base32();
                let related = m.conv == direct_conv(&from) || m.conv.starts_with("g:") || own;
                if ours && related && m.status < 2 {
                    self.store.set_message_status(&id, 2)?;
                    self.emit("message_update", json!({"conv": m.conv, "id": m.id, "status": 2}));
                }
            }
        }
        Ok(())
    }

    /// Acknowledge on the device's connection, if any (ahead of queued traffic).
    fn ack_now_dev(&self, dev: &PeerId, id: [u8; 16]) -> bool {
        match self.peer(dev) {
            Some(pc) => {
                pc.queue_ack(&[id]);
                true
            }
            None => false,
        }
    }

    /// A message that can never go out (e.g. larger than a control frame): out of the
    /// outbox, marked failed, and the user is told in plain words.
    pub(crate) fn mark_send_failed(&self, id: &[u8; 16], code: &str) {
        if let Some(m) = self.store.message(id) {
            if m.author == self.me.to_base32() && m.status < 2 {
                // 4 = failed (statuses only move forward; the app shows "Failed")
                let _ = self.store.set_message_status(id, 4);
                self.emit("message_update", json!({"conv": m.conv, "id": m.id, "status": 4}));
            }
            self.emit("error", json!({"message": crate::i18n::tr(code), "code": code.trim_start_matches("err."), "conv": m.conv, "id": m.id}));
        } else {
            self.emit("error", json!({"message": crate::i18n::tr(code), "code": code.trim_start_matches("err.")}));
        }
    }

    /// Batch acks for a device we only hear from by mail into one sealed signal (~1.5 s).
    fn queue_mail_ack(&self, dev: PeerId, id: [u8; 16]) {
        let first = {
            let mut q = self.mail_acks.lock();
            if q.len() > 256 && !q.contains_key(&dev) {
                return; // the sender's outbox re-sends; acked over a connection later
            }
            let e = q.entry(dev).or_default();
            if e.len() < 1000 {
                e.push(id);
            }
            e.len() == 1
        };
        if !first {
            return;
        }
        let Some(me) = self.self_ref.lock().as_ref().and_then(|w| w.upgrade()) else { return };
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(1500)).await;
            let ids = me.mail_acks.lock().remove(&dev).unwrap_or_default();
            if ids.is_empty() {
                return;
            }
            match me.peer(&dev) {
                Some(pc) => pc.queue_ack(&ids),
                None => {
                    me.send_sealed_signal(&dev, &PeerMsg::Ack { ids }).await;
                }
            }
        });
    }

    async fn on_mail_msg(self: &Arc<Self>, dev: PeerId, from: PeerId, own: bool, m: PeerMsg) -> Result<()> {
        match m {
            PeerMsg::Chat(msg) if !own => {
                self.on_direct_chat_offline(from, dev, msg).await?;
            }
            PeerMsg::FriendRequest { name, note } if !own => self.on_friend_request(from, name, note)?,
            PeerMsg::FriendAccept { name } if !own => self.on_friend_accept(from, name)?,
            PeerMsg::Action { id, author, hlc, action, sig } if !own => self.on_direct_action(from, id, author, hlc, action, sig)?,
            PeerMsg::GroupWelcome { sealed } => self.on_group_welcome(dev, &sealed).await?,
            PeerMsg::GroupKey { sealed } => self.on_group_key(dev, &sealed)?,
            PeerMsg::Group { gid, env } => self.on_group_envelope(None, gid, env, true).await?,
            PeerMsg::Ext { kind, body } => self.on_ext_mail(dev, from, kind, body).await?,
            // acknowledgements of what we mailed (the recipient can't reach us directly)
            PeerMsg::Ack { ids } => self.on_acks(dev, from, own, ids)?,
            _ => {}
        }
        Ok(())
    }

    /// Messages one of my own devices may send me directly (everything else between my
    /// devices travels as sync items).
    fn own_device_msg(m: &PeerMsg) -> bool {
        !matches!(
            m,
            PeerMsg::FriendRequest { .. }
                | PeerMsg::FriendAccept { .. }
                | PeerMsg::FriendRemove
                | PeerMsg::Profile { .. }
                | PeerMsg::ProfileV2 { .. }
                | PeerMsg::Chat(_)
                | PeerMsg::Action { .. }
                | PeerMsg::Read { .. }
                | PeerMsg::Typing { .. }
                | PeerMsg::Story { .. }
                | PeerMsg::StorySeen { .. }
                | PeerMsg::JoinRequest { .. }
                | PeerMsg::JoinPublic { .. }
                | PeerMsg::BotGroupMsg { .. }
                | PeerMsg::BotGroupPost { .. }
                | PeerMsg::GroupRead { .. }
                | PeerMsg::GroupTyping { .. }
                | PeerMsg::PushReg { .. }
                | PeerMsg::WakeRequest { .. }
        )
    }

    /// Queue a message for an account: one reliable copy per active device of it (`to ==
    /// me`: my other devices). Old/single-device peers: just their key.
    pub(super) async fn deliver(self: &Arc<Self>, to: PeerId, id: [u8; 16], m: PeerMsg, mail: bool) {
        // friends on pre-multi-device apps can't check a linked device's signatures and
        // don't know its key: the main device re-signs and delivers for it (node/bridge.rs)
        if !self.is_primary() && to != self.me && !self.speaks_multidevice(&to) {
            Box::pin(self.bridge_send(to, id, m)).await;
            return;
        }
        for dev in self.delivery_targets(&to) {
            if dev == self.device {
                continue;
            }
            Box::pin(self.deliver_dev(dev, id, m.clone(), mail)).await;
        }
    }

    /// Queue a message for one device: send now if connected, else outbox + store-and-forward.
    pub(super) async fn deliver_dev(self: &Arc<Self>, to: PeerId, id: [u8; 16], m: PeerMsg, mail: bool) {
        // never queue a message kind the device can't decode (it would block nothing, but
        // it would never be acknowledged either)
        // A device whose version we don't know yet gets it queued: it goes out once its
        // Hello says v3 (outbox pump), never silently lost (e.g. a rekey request after a
        // revocation, to an admin device we never talked to).
        let is_ext = matches!(&m, PeerMsg::Ext { .. }) || matches!(&m, PeerMsg::Wrapped { inner, .. } if matches!(**inner, PeerMsg::Ext { .. }));
        if is_ext && self.dev_known_pre_v3(&to) {
            tracing::debug!("not sending Ext to {to:?} (older version)");
            return;
        }
        // iPhone wake-up candidate
        let wake = if mail { super::push::preview_of(&m) } else { None };
        let m = match m {
            w @ PeerMsg::Wrapped { .. } => w,
            other => PeerMsg::Wrapped { id, inner: Box::new(other) },
        };
        // The outbox keeps the plain message: direct-chat content is ratchet-encrypted when
        // it is written to a connection (connection writer), so every (re-)send uses the
        // current chain in stream order. Offline copies are encrypted below, one step each.
        let payload = rmp_serde::to_vec(&m).unwrap_or_default();
        let _ = self.store.outbox_add(&id, &to, &payload);
        let kind = msg_kind(&m);
        if self.send_now_dev(&to, m.clone()) {
            tracing::trace!("deliver {kind} → {to:?}: sent");
            return;
        }
        tracing::debug!("deliver {kind} → {to:?}: peer not connected, queued");
        if let Some((preview, conv)) = wake {
            self.push_on_queued(to, preview, conv);
        }
        // Offline peers: one dial attempt at a time with exponential back-off (30 s → 30 min),
        // instead of a connect storm for every queued message. The outbox keeps everything;
        // the reconnect sweep and the peer's own reconnect deliver it later.
        let dial_now = self.dial_due(&to);
        let payload = if mail { rmp_serde::to_vec(&self.olm_for_wire(&to, m.clone())).unwrap_or_default() } else { payload };
        // IP privacy: a stranger is never dialed (that would send it my addresses);
        // whatever is queued for it goes as sealed mail only. Someone I asked who hasn't
        // accepted yet won't answer my offer with addresses (newer apps): the request also
        // goes as sealed mail right away.
        let may_dial = self.may_reveal_addrs(&to);
        let acc = self.account_of(&to);
        let pending = may_dial && acc != self.me && !self.store.is_friend(&acc);
        if mail {
            self.mail_retry.lock().entry(to).or_insert((Instant::now() + Duration::from_secs(120), Duration::from_secs(120)));
            // offline mail is cheap and independent of dialing
            if !dial_now || !may_dial || pending {
                let node = self.clone();
                let payload2 = payload.clone();
                tokio::spawn(async move { node.store_and_forward(to, id, &payload2).await });
            }
        }
        if !dial_now || !may_dial {
            return;
        }
        let node = self.clone();
        tokio::spawn(async move {
            match node.connect(to).await {
                Ok(c) => {
                    node.backoff.lock().remove(&to);
                    let _ = c.ctl.send(m).await;
                }
                Err(e) => {
                    tracing::debug!("deliver to {to:?} deferred: {e:#}");
                    node.note_dial_failed(&to);
                    if mail && !pending {
                        node.store_and_forward(to, id, &payload).await;
                    }
                }
            }
        });
    }

    pub(crate) fn upgrade_due(&self, dev: &PeerId) -> bool {
        !matches!(self.upgrade_backoff.lock().get(dev), Some((at, _)) if Instant::now() < *at)
    }

    /// A relay → direct upgrade failed: wait twice as long before the next one.
    pub(crate) fn note_upgrade_failed(&self, dev: &PeerId) -> Duration {
        let mut b = self.upgrade_backoff.lock();
        if b.len() > 4096 {
            b.retain(|_, (at, _)| *at > Instant::now());
        }
        let wait = b.get(dev).map(|(_, w)| (*w * 2).min(UPGRADE_MAX_WAIT)).unwrap_or(UPGRADE_FIRST_WAIT);
        b.insert(*dev, (Instant::now() + wait, wait));
        wait
    }

    /// May `dev` be dialed now (exponential back-off 30 s → 30 min after failed dials)?
    pub(crate) fn dial_due(&self, dev: &PeerId) -> bool {
        let mut b = self.backoff.lock();
        if b.len() > 4096 {
            b.retain(|_, (t, _)| t.elapsed() < Duration::from_secs(3600));
        }
        !matches!(b.get(dev), Some((t, wait)) if t.elapsed() < *wait)
    }

    pub(crate) fn note_dial_failed(&self, dev: &PeerId) {
        let mut b = self.backoff.lock();
        let next = b.get(dev).map(|(_, w)| (*w * 2).min(Duration::from_secs(1800))).unwrap_or(Duration::from_secs(30));
        b.insert(*dev, (Instant::now(), next));
    }

    /// Re-send what is queued for an unreachable device as sealed mail (Nostr live mail,
    /// relay mailboxes, friends' store-and-forward), with back-off 2 min → 1 h. Covers
    /// strangers (never dialed) and friends we can't reach directly.
    pub(super) async fn remail_outbox(self: &Arc<Self>, dev: PeerId) {
        {
            let mut m = self.mail_retry.lock();
            let now = Instant::now();
            if matches!(m.get(&dev), Some((at, _)) if *at > now) {
                return;
            }
            let wait = m.get(&dev).map(|(_, w)| (*w * 2).min(Duration::from_secs(3600))).unwrap_or(Duration::from_secs(120));
            m.insert(dev, (now + wait, wait));
        }
        for (_, id, payload) in self.store.outbox_page(&dev, 0, 16).unwrap_or_default() {
            let Ok(id) = <[u8; 16]>::try_from(id.as_slice()) else { continue };
            if payload.len() > NOSTR_MAIL_MAX {
                continue; // large items wait for a connection
            }
            let Ok(m) = crate::proto::decode_peer_msg(&payload) else { continue };
            if matches!(&m, PeerMsg::Wrapped { inner, .. } if matches!(**inner, PeerMsg::Ext { .. })) && self.dev_known_pre_v3(&dev) {
                continue;
            }
            let wire = rmp_serde::to_vec(&self.olm_for_wire(&dev, m)).unwrap_or_default();
            self.store_and_forward(dev, id, &wire).await;
        }
    }

    /// The connection to `friend` carried my peer relay: drop that relay and close the
    /// connections tunnelled through it (they are dead now).
    pub(super) fn drop_peer_relay_via(&self, friend: &PeerId) {
        let name = format!("peer:{}", friend.to_base32());
        let idx = self.net.relays.read().iter().find(|r| r.url == name).map(|r| r.idx);
        let Some(idx) = idx else { return };
        self.net.remove_relay(&name);
        for c in self.connected_peers() {
            if c.path == PathKind::Relay && net::magicsock::relay_idx_of(&c.conn.remote_address()) == Some(idx) {
                tracing::info!("closing {:?}: its peer relay {name} is gone", c.peer);
                c.conn.close(0u32.into(), b"relay gone");
            }
        }
    }

    /// Offline delivery: sealed mail via relay mailboxes and online mutual friends.
    pub(super) async fn store_and_forward(self: &Arc<Self>, to: PeerId, id: [u8; 16], payload: &[u8]) {
        let Ok(sealed) = seal_to(&self.id, &to, payload) else { return };
        let sig = Signal::Mail { payload: sealed.clone() };
        let env = rmp_serde::to_vec(&sig).ok().and_then(|b| seal_to(&self.id, &to, &b).ok());
        // Live mail: a sealed signal through Nostr (ephemeral, stored by no one) reaches a
        // recipient that is online but not directly reachable — a stranger we must not
        // dial, or a friend behind a NAT we can't punch. Small messages only.
        if let Some(env) = env.as_ref().filter(|e| e.len() <= NOSTR_MAIL_MAX) {
            let pool = self.net.nostr.read().clone();
            if let Some(p) = pool {
                p.send_signal(&to, env);
            }
        }
        let enabled = self.store.kv_get("privacy.store_forward").map(|v| v != b"0").unwrap_or(true);
        if !enabled {
            return;
        }
        let mut handed = 0;
        let to_acc = self.account_of(&to);
        {
            if let Some(env) = env {
                let hint = self.store.contact(&to).map(|c| c.relays).unwrap_or_default();
                // Nostr ephemeral events are not stored, so only relays with mailbox count.
                let relays = self.net.relays.read().clone();
                for r in relays.iter() {
                    if r.send_signal(to, env.clone()).await {
                        handed += 1;
                    }
                }
                let _ = hint;
            }
        }
        for pc in self.connected_peers() {
            // Privacy: a StoreFor tells the keeper who gets mail from me and when. Only my own
            // devices, and friends who already know the recipient as far as I can tell (a
            // private group the three of us share) keep it; never another device of the
            // recipient. Everyone else: relay mailboxes / Nostr only.
            if pc.peer != to
                && pc.account != to_acc
                && (pc.own || (self.store.is_friend(&pc.account) && self.knows_each_other(&pc.account, &to_acc)))
                && pc.ctl.try_send(PeerMsg::StoreFor { to, id, sealed: sealed.clone() }).is_ok()
            {
                handed += 1;
            }
        }
        if handed > 0 {
            let _ = self.store.set_message_status(&id, 1);
        }
    }

    /// Do accounts `a` and `b` know each other, as far as I can tell: members of a private
    /// group (not a public one) that I am in too.
    pub(crate) fn knows_each_other(&self, a: &PeerId, b: &PeerId) -> bool {
        self.groups.read().values().any(|g| !g.public && g.is_member(&self.me) && g.is_member(a) && g.is_member(b))
    }

    // ---------------------------------------------------------------- accept

    pub(super) fn spawn_accept_loop(self: Arc<Self>) {
        tokio::spawn(async move {
            while let Some(inc) = self.net.endpoint.accept().await {
                let node = self.clone();
                tokio::spawn(async move {
                    let remote = inc.remote_address();
                    match tokio::time::timeout(Duration::from_secs(15), inc).await {
                        Ok(Ok(conn)) => {
                            let peer = match crate::tls::remote_peer(&conn) {
                                Ok(p) => p,
                                Err(_) => return,
                            };
                            let path = if net::magicsock::is_relay_addr(&remote) {
                                PathKind::Relay
                            } else if !crate::util::is_global_ip(&crate::util::canon(remote).ip()) {
                                PathKind::Lan
                            } else {
                                PathKind::Direct
                            };
                            if let Err(e) = node.clone().setup_conn(conn, path, peer, None).await {
                                tracing::debug!("incoming setup failed: {e:#}");
                            }
                        }
                        Ok(Err(e)) => tracing::debug!("incoming handshake from {remote} failed: {e}"),
                        Err(_) => {}
                    }
                });
            }
        });
    }

    // ---------------------------------------------------------------- signals

    pub(super) fn spawn_signal_loop(self: Arc<Self>, mut rx: mpsc::Receiver<net::relay_client::IncomingSignal>) {
        tokio::spawn(async move {
            while let Some(sig) = rx.recv().await {
                // bounded: a flood of signals can't spawn unbounded tasks
                let Ok(permit) = self.signal_sem.clone().try_acquire_owned() else {
                    tracing::debug!("too many signals at once: dropping one from {}", sig.via);
                    continue;
                };
                let node = self.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    if let Err(e) = node.handle_signal(sig).await {
                        tracing::debug!("signal: {e:#}");
                    }
                });
            }
        });
    }

    async fn handle_signal(self: &Arc<Self>, sig: net::relay_client::IncomingSignal) -> Result<()> {
        // `from` is the sending *device* (signals are sealed by transport keys)
        let (from, ts, body) = open_sealed(&self.id, &sig.data)?;
        let account = self.account_of(&from);
        if from == self.device || self.store.is_blocked(&account) || self.is_revoked(&account, &from) {
            return Ok(());
        }
        let s: Signal = crate::proto::from_slice_capped(&body)?;
        match s {
            Signal::Offer { sid, info, name } => {
                if now_ms().abs_diff(ts) > 120_000 {
                    return Ok(()); // stale / replayed
                }
                let _ = name; // strangers are not remembered (no silent contact rows)
                if !self.may_reveal_addrs(&from) {
                    // (strangers' offers are deduped in their own small cache: spamming it
                    // can't evict the entries of people we answer)
                    if self.stranger_offers.lock().put((from, sid), ()).is_some() {
                        return Ok(());
                    }
                    // IP privacy: a stranger (also a pending requester, status 2) learns none
                    // of our addresses and gets no packet from us. At most a relay-only
                    // answer (a relay the user configured; never a friend's peer relay), so
                    // their friend request / remote-control request can still reach us.
                    // Global limit: max 20 stranger offers a minute (reflection / DoS).
                    if !self.stranger_offer_allowed() || self.net.cfg.read().relay_delay_ms >= 600_000 {
                        return Ok(());
                    }
                    let relays: Vec<String> = self
                        .net
                        .relay_status()
                        .into_iter()
                        .filter(|(u, ok)| *ok && !u.starts_with("peer:") && self.net.is_user_relay(u))
                        .map(|(u, _)| u)
                        .collect();
                    if relays.is_empty() {
                        tracing::debug!("offer from stranger {from:?}: not answered (no relay to offer)");
                        return Ok(());
                    }
                    tracing::debug!("offer from stranger {from:?}: relay-only answer");
                    let ans = Signal::Answer { sid, info: ConnInfo { relays, ..Default::default() } };
                    let sealed = seal_to(&self.id, &from, &rmp_serde::to_vec(&ans)?)?;
                    self.net.send_signal(&from, sealed, &[]).await;
                    return Ok(());
                }
                // Authorized: dedupe (same offer via several channels) and replay checks —
                // only after the gate, so strangers can't evict these entries.
                if self.recent_offers.lock().put((from, sid), ()).is_some() {
                    return Ok(());
                }
                {
                    let mut last = self.offer_ts.lock();
                    let newest = last.get(&from).copied().unwrap_or(0);
                    if ts + OFFER_REORDER_MS < newest {
                        tracing::debug!("offer {sid} from {from:?} is older than one already seen: replay, ignored");
                        return Ok(());
                    }
                    if ts > newest {
                        last.put(from, ts);
                    }
                }
                // Path state: none → connect; relayed → upgrade attempt; "direct" but the peer
                // offers anyway → its side of our path died (NAT rebinding…): repair it now
                // instead of waiting for the idle timeout (both sides mark the old path, so
                // the new connection replaces it on both). Only an offer made after our
                // connection came up can be about it (a replayed older one is not).
                let cur = self.peer(&from);
                let upgrade = cur.as_ref().map(|c| c.path == PathKind::Relay).unwrap_or(false);
                let repair = cur.as_ref().map(|c| c.path != PathKind::Relay && ts + 10_000 > c.since_ms()).unwrap_or(false);
                if repair {
                    if let Some(c) = &cur {
                        tracing::info!("{from:?} offers while we look connected: repairing the path");
                        c.mark_suspect();
                    }
                    // a peer relay carried by that path is as dead as the path
                    self.drop_peer_relay_via(&from);
                    // our reflexive address may have changed too
                    *self.info_refreshed.lock() = None;
                }
                let mine = self.ensure_info().await;
                let ans = Signal::Answer { sid, info: mine.clone() };
                let sealed = seal_to(&self.id, &from, &rmp_serde::to_vec(&ans)?)?;
                self.net.send_signal(&from, sealed, &[]).await;
                if !info.relays.is_empty() && (self.store.is_friend(&account) || account == self.me) {
                    let _ = self.store.set_contact_field(
                        &from,
                        "relays",
                        rusqlite::types::Value::Text(serde_json::to_string(&info.relays).unwrap_or_default()),
                    );
                }
                // We also dial: simultaneous dials punch holes on both NATs.
                let me = self.clone();
                tokio::spawn(async move {
                    let lock = me.dial_locks.lock().entry(from).or_default().clone();
                    let Ok(_g) = lock.try_lock() else { return }; // our own connect() is running
                    if !upgrade && !repair && me.is_online(&from) {
                        return;
                    }
                    match me.race_paths_opt(from, sid, &mine, &info, !upgrade).await {
                        Ok((c, path, ep)) => {
                            let _ = me.clone().setup_conn(c, path, me.device, ep).await;
                        }
                        Err(e) => tracing::debug!("answer-side dial failed: {e:#}"),
                    }
                });
            }
            Signal::Answer { sid, info } => {
                tracing::info!("answer {sid} from {from:?}: {} addresses, {} relays", info.addrs.len(), info.relays.len());
                if let Some((peer, tx)) = self.pending_answers.lock().remove(&sid) {
                    if peer == from {
                        let _ = tx.send(info);
                    }
                }
            }
            Signal::Mail { payload } => {
                self.on_mail(&payload).await?;
            }
        }
        Ok(())
    }

    // ---------------------------------------------------------------- background

    pub(super) fn spawn_background(self: Arc<Self>) {
        // network info + DHT publish + directory
        let node = self.clone();
        tokio::spawn(async move {
            let mut last_info = String::new();
            let mut last_addrs = String::new();
            let mut tick = 0u64;
            loop {
                *node.info_refreshed.lock() = Some(Instant::now());
                let info = node.net.refresh_info().await;
                let sig = format!("{:?}{:?}{:?}", info.nat, info.addrs, info.relays);
                if sig != last_info {
                    let addrs = format!("{:?}", info.addrs);
                    let addrs_changed = !last_addrs.is_empty() && addrs != last_addrs;
                    last_addrs = addrs;
                    last_info = sig;
                    node.emit("net", node.net_status());
                    // another network: failed upgrades may work now
                    if addrs_changed {
                        node.upgrade_backoff.lock().clear();
                    }
                }
                // friends' inbox tags rotate daily (and follow the privacy setting)
                node.refresh_nostr_inboxes(false);
                if tick.is_multiple_of(10) {
                    if let Some(dht) = &node.net.dht {
                        // Only the friends-only record (no public one: it would map "ID → IP"
                        // for DHT nodes); it is stored under a key derived from the random
                        // friends-only key, never the identity key.
                        let fkey = node.own_dht_key();
                        if !node.store.friend_ids().is_empty() || !node.siblings().is_empty() {
                            if let Err(e) = dht.publish_friend(&node.device, &info, &fkey).await {
                                tracing::debug!("dht friend record: {e:#}");
                            }
                        }
                        // the account's devices (main device, only with ≥ 2 devices)
                        if let Some(b) = node.own_list().filter(|b| node.is_primary() && b.devices.len() >= 2) {
                            let rec = crate::net::discovery::DhtDevices { version: b.version, devices: b.devices.iter().map(|e| (e.device, e.caps)).collect() };
                            if let Err(e) = dht.publish_devices(&node.me, &rec, &fkey).await {
                                tracing::debug!("dht device record: {e:#}");
                            }
                        }
                    }
                    let nostr = if !node.cfg.link_pending { node.net.nostr.read().clone() } else { None };
                    node.publish_directory_now();
                    match nostr {
                        Some(p) if node.is_primary() => {
                            if tick.is_multiple_of(1440) {
                                let gids: Vec<Gid> = node.groups.read().keys().copied().collect();
                                for g in gids {
                                    node.publish_group_directory(g);
                                }
                                if let Some(u) = node.username() {
                                    let id = node.id.clone();
                                    let n = node.clone();
                                    tokio::task::spawn_blocking(move || {
                                        let ev = p.publish_username(&id, &u, None);
                                        n.keep_nostr_event("user", ev);
                                    });
                                }
                            }
                        }
                        Some(p) => {
                            // a linked device: its own short ID (remote control picks devices by
                            // it; published above), and the main device's signed records while
                            // that one is away
                            if node.peer(&node.me).is_none() {
                                for ev in node.kept_nostr_events() {
                                    p.publish_raw(&ev);
                                }
                            }
                        }
                        None => {}
                    }
                }
                tick += 1;
                let mut sd = node.shutdown.subscribe();
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(60)) => {}
                    _ = sd.changed() => return,
                }
            }
        });
        // reconnect friends + retry outbox
        let node = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(3)).await;
            loop {
                // every active device of every friend, my own other devices, and anyone
                // we still have queued messages for
                let mut targets: Vec<PeerId> = vec![];
                if !node.cfg.link_pending {
                    for f in node.store.friend_ids() {
                        if !node.is_primary() && !node.speaks_multidevice(&f) {
                            continue; // older app: only my main device talks to it
                        }
                        // lazy: a friend's main key always, its other devices only if seen
                        // recently (else they are dialed when there is something for them)
                        let recent = now_ms().saturating_sub(7 * 86_400_000);
                        targets.extend(
                            node.delivery_targets(&f)
                                .into_iter()
                                .filter(|d| *d == f || node.store.device_get(d).map(|r| r.last_seen >= recent || r.added >= recent).unwrap_or(true))
                                .take(super::MAX_DEVICES_PER_SWEEP),
                        );
                    }
                    targets.extend(node.siblings());
                }
                let queued = node.store.outbox_peers().unwrap_or_default();
                for p in queued.iter() {
                    if !targets.contains(p) {
                        targets.push(*p);
                    }
                }
                targets.retain(|p| *p != node.device);
                targets.dedup();
                for p in targets {
                    if node.usable_peer(&p).is_some() {
                        continue;
                    }
                    // never dial a stranger or a pending requester (their queued items go
                    // as sealed mail), and re-mail what waits for anyone we can't reach.
                    // Dials respect the back-off (a sleeping device is retried 30 s → 30 min).
                    let dial = node.may_reveal_addrs(&p) && node.dial_due(&p);
                    let remail = queued.contains(&p);
                    if !dial && !remail {
                        continue;
                    }
                    let n = node.clone();
                    tokio::spawn(async move {
                        if dial {
                            match n.connect(p).await {
                                Ok(_) => {
                                    n.backoff.lock().remove(&p);
                                    return;
                                }
                                Err(_) => n.note_dial_failed(&p),
                            }
                        }
                        if remail {
                            n.remail_outbox(p).await;
                        }
                    });
                    tokio::time::sleep(Duration::from_millis(200)).await;
                }
                tokio::time::sleep(Duration::from_secs(120)).await;
            }
        });
        // re-send unacknowledged outbox items to peers that are online (covers frames lost
        // when a duplicate connection was retired); receivers dedupe by id.
        let node = self.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(8)).await;
                for pc in node.connected_peers() {
                    node.olm_ensure_session(&pc); // friends without a ratchet session yet
                    if pc.since.elapsed() < Duration::from_secs(5) {
                        continue;
                    }
                    let n = node.clone();
                    tokio::spawn(async move { n.pump_outbox(&pc).await });
                }
            }
        });
        // path watchdog: notice a dead path in seconds instead of the 40 s idle timeout
        self.clone().spawn_path_watchdog();
        // relay → direct upgrades (keeps latency low; relays are only a bridge)
        let node = self.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(30)).await;
                let relayed: Vec<PeerId> = node
                    .connected_peers()
                    .iter()
                    .filter(|p| p.path == PathKind::Relay && node.may_reveal_addrs(&p.peer) && node.upgrade_due(&p.peer))
                    .map(|p| p.peer)
                    .collect();
                for p in relayed {
                    let n = node.clone();
                    tokio::spawn(async move {
                        if let Err(e) = n.try_upgrade(p).await {
                            // back off: 30 s, 1, 2, 4 … 30 min (reset on a network change)
                            let wait = n.note_upgrade_failed(&p);
                            tracing::debug!("upgrade {p:?} failed: {e:#} (next try in {} s)", wait.as_secs());
                        } else {
                            n.upgrade_backoff.lock().remove(&p);
                            tracing::info!("upgraded {p:?} from relay to direct");
                        }
                    });
                }
            }
        });
        self.clone().spawn_scheduler();
        // storage hygiene
        let node = self;
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(600)).await;
                if let Err(e) = node.store.maintain() {
                    tracing::warn!("maintain: {e:#}");
                }
                node.sync_maintain();
                let _ = node.store.trim_group_logs(5000);
                if let Ok(r) = node.clean_media(None) {
                    if r["removed_files"].as_u64().unwrap_or(0) > 0 {
                        node.emit("storage", r);
                    }
                }
                if node.low_disk() {
                    node.emit("storage_low", json!({"message": crate::i18n::tr("err.disk_full")}));
                }
            }
        });
    }

    /// "Let strangers find me by ID" (Settings › Privacy): publish my short-ID directory
    /// record, or replace it with a tombstone.
    pub fn discoverable_by_id(&self) -> bool {
        self.store.kv_get("privacy.discoverable").map(|v| v != b"0").unwrap_or(true)
    }

    /// (Re)publish this device's short-ID directory record now — or withdraw it.
    pub fn publish_directory_now(&self) {
        if self.cfg.link_pending {
            return;
        }
        let Some(p) = self.net.nostr.read().clone() else { return };
        let ev = if !self.discoverable_by_id() {
            p.unpublish_directory(&self.id)
        } else if self.is_primary() {
            p.publish_directory(&self.id, &self.name())
        } else {
            let cert = self.store.kv_get("account.cert").unwrap_or_default();
            let name = self.store.kv_get("device.name").and_then(|v| String::from_utf8(v).ok()).unwrap_or_else(|| self.name());
            p.publish_directory_ext(&self.id, &name, Some((&self.me, &cert)))
        };
        if self.is_primary() {
            self.keep_nostr_event("dir", ev);
        }
    }

    /// Watch every connection's received-datagram count. A path that went quiet gets a
    /// ping; still nothing → it is marked dead (a new connection replaces it at once) and,
    /// for people allowed to know my addresses, re-dialed with a fresh reflexive address.
    /// Active connections (messages in the last 2 min, transfers) are watched closely
    /// (ping after 3 s, dead after 6 s), idle ones loosely (12 s / 16 s; keep-alive 10 s).
    fn spawn_path_watchdog(self: Arc<Self>) {
        tokio::spawn(async move {
            let mut sd = self.shutdown.subscribe();
            loop {
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(1)) => {}
                    _ = sd.changed() => return,
                }
                let now = Instant::now();
                for pc in self.connected_peers() {
                    let rx = pc.conn.stats().udp_rx.datagrams;
                    let active = now_ms().saturating_sub(pc.active_at.load(std::sync::atomic::Ordering::Relaxed)) < 120_000
                        || pc.busy.load(std::sync::atomic::Ordering::Relaxed) > 0;
                    let (ping_after, dead_after) = if active { (Duration::from_secs(3), Duration::from_secs(6)) } else { (Duration::from_secs(12), Duration::from_secs(16)) };
                    // Tunnelled through a relay that is gone (friend's peer relay dropped, or a
                    // server relay's WebSocket down for more than a grace period — a brief drop
                    // reconnects and the QUIC connection rides on): dead, no need to wait for
                    // silence.
                    let relay_idx = if pc.path == PathKind::Relay { net::magicsock::relay_idx_of(&pc.conn.remote_address()) } else { None };
                    let relay_down = relay_idx
                        .map(|idx| match self.net.relays.read().iter().find(|r| r.idx == idx) {
                            None => true,
                            Some(r) => r.is_stopped() || r.down_for() > RELAY_DOWN_GRACE,
                        })
                        .unwrap_or(false);
                    let (ping, dead) = {
                        let mut g = pc.rx_seen.lock();
                        if relay_down {
                            (false, true)
                        } else if rx != g.0 {
                            *g = (rx, now, None);
                            // alive again long after being marked: not dead after all
                            if pc.is_suspect() && pc.suspect_since.lock().map(|t| t.elapsed() > Duration::from_secs(30)).unwrap_or(false) {
                                pc.suspect.store(false, std::sync::atomic::Ordering::Relaxed);
                            }
                            continue;
                        } else {
                            let quiet = now.duration_since(g.1);
                            let ping = quiet >= ping_after && g.2.is_none();
                            if ping {
                                g.2 = Some(now);
                            }
                            let dead = quiet >= dead_after && g.2.map(|t| now.duration_since(t) >= Duration::from_millis(2500)).unwrap_or(false);
                            (ping, dead)
                        }
                    };
                    if ping {
                        let _ = pc.ctl.try_send(PeerMsg::Ping { t: now_ms() });
                    }
                    // (already marked while its relay was briefly down — gone for good now:
                    // close it so it is re-dialed, not left until the idle timeout)
                    if relay_down && pc.is_suspect() {
                        tracing::info!("relay under {:?} stayed down: closing", pc.peer);
                        pc.conn.close(0u32.into(), b"relay gone");
                        continue;
                    }
                    if dead && !pc.is_suspect() {
                        tracing::info!("path to {:?} ({:?}) went silent: repairing", pc.peer, pc.path);
                        pc.mark_suspect();
                        if relay_down {
                            pc.conn.close(0u32.into(), b"relay gone");
                        } else if pc.path != PathKind::Relay {
                            // A direct path silent this long is dead for us (NAT rebinding,
                            // network change). Close it now rather than at the idle timeout:
                            // while it lives it keeps retransmitting on the old 5-tuple, whose
                            // fresh NAT mapping the peer can't learn — and the repair dial,
                            // from the same socket to the same address, rides that mapping
                            // (NAT lab `keepalive`: 42 s → ~7 s).
                            pc.conn.close(0u32.into(), b"path dead");
                        }
                        self.drop_peer_relay_via(&pc.peer);
                        if pc.path != PathKind::Relay {
                            *self.info_refreshed.lock() = None;
                        }
                        if let (false, Some(idx)) = (relay_down, relay_idx) {
                            // silent relayed path: check that relay's socket only
                            self.net.probe_relay(idx);
                        }
                        if self.may_reveal_addrs(&pc.peer) && !*self.shutdown.borrow() {
                            let n = self.clone();
                            let peer = pc.peer;
                            let direct = pc.path != PathKind::Relay;
                            tokio::spawn(async move {
                                if direct {
                                    // the signaling sockets through the same NAT may be dead
                                    // too: probe them (a healthy one is left alone)
                                    n.net.probe_signaling().await;
                                }
                                if let Err(e) = n.connect_repair(peer).await {
                                    tracing::debug!("path repair {peer:?}: {e:#}");
                                }
                            });
                        }
                    }
                }
            }
        });
    }

    /// IP privacy gate: may this device learn my addresses (answer its offers with them,
    /// dial / punch / spray toward it, cache its addresses)? Friends, people I asked, my own
    /// devices, current group co-members, a remote-control partner after consent / a
    /// verified password, a device being linked, and devices I dialed myself recently.
    /// Everyone else is a stranger (pending requesters too).
    pub(crate) fn may_reveal_addrs(&self, dev: &PeerId) -> bool {
        if *dev == self.device {
            return false;
        }
        let account = self.account_of(dev);
        if self.store.is_blocked(&account) || self.store.is_blocked(dev) {
            return false;
        }
        if account == self.me || self.store.contact(&account).map(|c| c.status == 1 || c.status == 3).unwrap_or(false) {
            return true;
        }
        if self.group_reveals_to(&account) {
            return true;
        }
        {
            let mut s = self.solicited.lock();
            match s.get(dev) {
                Some(t) if t.elapsed() < SOLICITED_FOR => return true,
                Some(_) => {
                    s.remove(dev);
                }
                None => {}
            }
        }
        self.remote.reveals_addrs_to(dev) || self.link_reveals_addrs_to(dev)
    }

    /// Group rule of the address gate (#4). Only groups I am in myself count (a group I left
    /// or was removed from stays in memory, its members are strangers again). In a private
    /// group, members were invited by someone in it: co-members may learn my addresses. A
    /// PUBLIC group is open to anyone, so co-membership there reveals nothing — except to
    /// its owner/admins (whom I chose to trust by joining); ordinary members reach each
    /// other through relays / sealed mail and the group's gossip, never directly.
    pub(crate) fn group_reveals_to(&self, account: &PeerId) -> bool {
        self.groups.read().values().any(|g| {
            g.is_member(&self.me)
                && g.is_member(account)
                && (!g.public || g.role(account).map(|r| r >= crate::group::Role::Admin).unwrap_or(false))
        })
    }

    /// I'm contacting this device myself (my offer reveals my addresses to it anyway).
    pub(crate) fn note_solicited(&self, dev: PeerId) {
        let mut s = self.solicited.lock();
        if s.len() > 1024 {
            s.retain(|_, t| t.elapsed() < SOLICITED_FOR);
        }
        s.insert(dev, Instant::now());
    }

    /// We just became friends with `account`: what normally happens when a friend's
    /// connection comes up (ratchet session, peer-relay offer, friends-only DHT key).
    pub(crate) fn on_became_friends(&self, account: &PeerId) {
        for pc in self.peers_of(account) {
            // what we only kept in memory while they were a stranger
            let v = pc.proto.load(std::sync::atomic::Ordering::Relaxed);
            if v > 0 {
                self.record_peer_proto(&pc.peer, v);
            }
            // the Hello they got while we were strangers had no app / OS (push wake-ups need it)
            let _ = pc.ctl.try_send(PeerMsg::Hello {
                version: proto::PROTO_VERSION,
                name: self.name(),
                app: super::push::app_string(),
                os: std::env::consts::OS.into(),
            });
            self.olm_ensure_session(&pc);
            self.maybe_offer_relay(&pc);
            self.share_dht_key(&pc);
            // we met as strangers through a relay: friends may connect directly now
            if pc.path == PathKind::Relay {
                if let Some(me) = self.self_ref.lock().as_ref().and_then(|w| w.upgrade()) {
                    let peer = pc.peer;
                    tokio::spawn(async move {
                        if let Err(e) = me.try_upgrade(peer).await {
                            tracing::debug!("upgrade new friend {peer:?}: {e:#}");
                        }
                    });
                }
            }
        }
    }

    /// This device's key for its friends-only DHT address record (rotated on unfriending).
    pub(crate) fn own_dht_key(&self) -> [u8; 32] {
        if let Some(k) = self.store.kv_get("dht.fkey").and_then(|v| <[u8; 32]>::try_from(v.as_slice()).ok()) {
            return k;
        }
        let k: [u8; 32] = crate::crypto::random_bytes();
        let _ = self.store.kv_set("dht.fkey", &k);
        k
    }

    /// Someone left my friends: their copy of my DHT key must stop working (the DHT record
    /// moves to a target they can't compute, and my friends' Nostr inbox moves too — the
    /// previous key's inbox is still listened to for a week, for friends who are offline
    /// and get the new key when they come back).
    pub(crate) fn rotate_dht_key(&self) {
        let old = self.own_dht_key();
        let _ = self.store.kv_set("dht.fkey.prev", &old);
        let _ = self.store.kv_set("dht.fkey.prev_at", &now_ms().to_le_bytes());
        let k: [u8; 32] = crate::crypto::random_bytes();
        let _ = self.store.kv_set("dht.fkey", &k);
        for pc in self.connected_peers() {
            self.share_dht_key(&pc);
        }
        self.refresh_nostr_inboxes(true);
    }

    /// The friends-only key before the last rotation (for a week).
    fn prev_dht_key(&self) -> Option<[u8; 32]> {
        let at = self.store.kv_get("dht.fkey.prev_at").and_then(|v| v.try_into().ok()).map(u64::from_le_bytes)?;
        if now_ms().saturating_sub(at) > 7 * 86_400_000 {
            return None;
        }
        self.store.kv_get("dht.fkey.prev").and_then(|v| <[u8; 32]>::try_from(v.as_slice()).ok())
    }

    /// Nostr inboxes (#5): friends reach me under daily tags derived from my friends-only
    /// key (unlinkable to my ID without it); the public inbox — computable from my ID, so
    /// a relay operator sees "this IP waits for mail to that ID" — is only listened to
    /// while strangers may find me ("Cho người lạ tìm thấy tôi"), or while a device link
    /// is pending. `keys`: also refresh the friends' keys signals to them are posted under.
    pub(crate) fn refresh_nostr_inboxes(&self, keys: bool) {
        let Some(p) = self.net.nostr.read().clone() else { return };
        let day = crate::net::nostr::today();
        let mut own = vec![self.own_dht_key()];
        own.extend(self.prev_dht_key());
        let friend_tags = own.iter().flat_map(|k| [day.saturating_sub(1), day, day + 1].map(|d| crate::net::nostr::friend_inbox_tag(k, d))).collect();
        let public = (self.discoverable_by_id() || self.cfg.link_pending || self.link_offer_live()).then(|| crate::net::nostr::inbox_tag(&self.device));
        p.set_inboxes(crate::net::nostr::InboxSubs { friend_tags, public });
        if keys {
            let mut devs = self.siblings();
            for f in self.store.friend_ids() {
                devs.extend(self.delivery_targets(&f));
            }
            let m = devs.into_iter().filter_map(|d| self.friend_dht_key(&d).map(|k| (d, k))).collect();
            p.set_friend_keys(m);
        }
    }

    /// A friend left: forget the friends-only keys its devices gave us.
    pub(crate) fn forget_friend_keys(&self, account: &PeerId) {
        let mut devs = self.delivery_targets(account);
        devs.push(*account);
        for d in devs {
            let _ = self.store.kv_del(&format!("dhtk.{}", d.to_base32()));
        }
        self.refresh_nostr_inboxes(true);
    }

    /// The friends-only DHT key a friend's device gave us.
    pub(crate) fn friend_dht_key(&self, dev: &PeerId) -> Option<[u8; 32]> {
        self.store.kv_get(&format!("dhtk.{}", dev.to_base32())).and_then(|v| <[u8; 32]>::try_from(v.as_slice()).ok())
    }

    /// Give a friend's (or my own) v3 device the key to my friends-only DHT record.
    pub(crate) fn share_dht_key(&self, pc: &Arc<PeerConn>) {
        if !(pc.own || self.store.is_friend(&pc.account)) || !self.dev_speaks_v3(&pc.peer) {
            return;
        }
        let body = DhtKeyMsg { key: self.own_dht_key().to_vec() };
        let _ = pc.ctl.try_send(proto::ext(proto::ext::DHT_KEY, &body));
    }

    pub(crate) fn on_dht_key(&self, pc: &Arc<PeerConn>, body: &[u8]) -> Result<()> {
        if !(pc.own || self.store.is_friend(&pc.account)) {
            return Ok(());
        }
        let m: DhtKeyMsg = proto::ext_body(body)?;
        let key: [u8; 32] = m.key.as_slice().try_into().map_err(|_| anyhow!("bad dht key"))?;
        self.store.kv_set(&format!("dhtk.{}", pc.peer.to_base32()), &key)?;
        // signals to this device now go to its friends' inbox
        if let Some(p) = self.net.nostr.read().clone() {
            p.set_friend_key(pc.peer, Some(key));
        }
        Ok(())
    }

    fn stranger_offer_allowed(&self) -> bool {
        let mut w = self.stranger_window.lock();
        let now = Instant::now();
        if now.duration_since(w.0) > Duration::from_secs(60) {
            *w = (now, 0);
        }
        w.1 += 1;
        w.1 <= 20
    }

    pub fn net_status(&self) -> Value {
        let info = self.net.info.read().clone();
        let peers: Vec<Value> = self
            .connected_peers()
            .iter()
            .map(|p| {
                json!({
                    "peer": p.peer.to_base32(),
                    "name": p.name.read().clone(),
                    "path": p.path,
                    "rtt_ms": p.conn.rtt().as_millis() as u64,
                    "remote_addr": if p.path == PathKind::Relay { "relay".to_string() } else { crate::util::canon(p.conn.remote_address()).to_string() },
                    "since_s": p.since.elapsed().as_secs(),
                    "lost_packets": p.conn.stats().path.lost_packets,
                    "sent_packets": p.conn.stats().path.sent_packets,
                    "congestion_events": p.conn.stats().path.congestion_events,
                    "mtu": p.conn.stats().path.current_mtu,
                })
            })
            .collect();
        json!({
            "nat": info.nat.label(),
            "public_ip": info.public_ip.map(|i| i.to_string()),
            "port": info.port,
            "addrs": info.addrs.iter().map(|a| a.to_string()).collect::<Vec<_>>(),
            "upnp": info.upnp.map(|a| a.to_string()),
            "relays": self.net.relay_status().into_iter().map(|(u, c)| json!({"url": u, "connected": c})).collect::<Vec<_>>(),
            "nostr": self.net.nostr_status().into_iter().map(|(u, c)| json!({"url": u, "connected": c})).collect::<Vec<_>>(),
            "dht": self.net.dht.is_some(),
            "lan_peers": self.net.lan.peers.read().len() + self.net.lan.hints.read().len(),
            "peers": peers,
        })
    }

    pub(super) fn emit_contact(&self, p: &PeerId) {
        if *p == self.me {
            return;
        }
        if let Some(c) = self.store.contact(p) {
            let mut v = serde_json::to_value(&c).unwrap_or(Value::Null);
            v["online"] = Value::Bool(self.is_online(p));
            // a linked device reaches this friend's old app only through my main device
            v["bridged"] = Value::Bool(!self.is_primary() && !self.speaks_multidevice(p));
            self.emit("contact", v);
        }
    }
}

/// `Ext DHT_KEY` (friends and own devices, v3): the key of the sender's friends-only DHT
/// address record.
#[derive(Serialize, Deserialize, Default)]
pub(crate) struct DhtKeyMsg {
    #[serde(with = "serde_bytes", default)]
    pub key: Vec<u8>,
}

#[cfg(test)]
mod ip_privacy_tests {
    use super::*;
    use crate::identity::Identity;

    async fn node(tmp: &std::path::Path) -> Arc<Node> {
        Node::start(NodeConfig {
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
        })
        .await
        .unwrap()
    }

    fn offer(from: &Identity, to: &PeerId, sid: u64, addr: SocketAddr) -> net::relay_client::IncomingSignal {
        let info = ConnInfo { addrs: vec![addr], port: addr.port(), ..Default::default() };
        let s = Signal::Offer { sid, info, name: "Kẻ lạ".into() };
        net::relay_client::IncomingSignal { via: "test".into(), data: seal_to(from, to, &rmp_serde::to_vec(&s).unwrap()).unwrap() }
    }

    /// Packets that arrive at `sock` within `wait`.
    async fn count_packets(sock: &tokio::net::UdpSocket, wait: Duration) -> usize {
        let mut n = 0;
        let mut buf = [0u8; 2048];
        let end = tokio::time::Instant::now() + wait;
        while let Ok(Ok(_)) = tokio::time::timeout_at(end, sock.recv_from(&mut buf)).await {
            n += 1;
        }
        n
    }

    /// P1: a stranger who only knows my ID sends an offer. Before: auto-answer with all my
    /// addresses, dial/punch back, and a silent status-0 contact. Now: no answer with
    /// addresses, not one packet toward the stranger's addresses, no contact row — and the
    /// same offer from a friend does get punched back (the test can see packets).
    #[tokio::test]
    async fn stranger_offers_get_no_packets_and_leave_no_trace() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let listener = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let at = listener.local_addr().unwrap();
        let stranger = Identity::generate();
        let s = stranger.peer_id();
        n.handle_signal(offer(&stranger, &n.device, 1, at)).await.unwrap();
        assert_eq!(count_packets(&listener, Duration::from_secs(2)).await, 0, "packets sent toward a stranger");
        assert!(n.store.contact(&s).is_none(), "a silent contact row was created for a stranger");
        assert!(n.store.peer_cache_get(&s).is_none(), "a stranger's addresses were cached");
        // a pending requester (status 2) is still a stranger
        n.store.upsert_contact(&s, Some("x"), Some(2)).unwrap();
        n.handle_signal(offer(&stranger, &n.device, 2, at)).await.unwrap();
        assert_eq!(count_packets(&listener, Duration::from_secs(2)).await, 0, "packets sent toward a pending requester");
        // once accepted (a friend), the same offer is answered and punched back
        n.store.upsert_contact(&s, None, Some(3)).unwrap();
        n.handle_signal(offer(&stranger, &n.device, 3, at)).await.unwrap();
        assert!(count_packets(&listener, Duration::from_secs(3)).await > 0, "a friend's offer was not punched back");
        assert!(n.store.peer_cache_get(&s).is_some(), "a friend's addresses are cached");
        n.shutdown();
    }

    #[tokio::test]
    async fn who_may_learn_my_addresses() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let p = |st: Option<i64>| {
            let id = Identity::generate().peer_id();
            if let Some(st) = st {
                n.store.upsert_contact(&id, Some("x"), Some(st)).unwrap();
            }
            id
        };
        assert!(!n.may_reveal_addrs(&p(None)), "unknown");
        assert!(!n.may_reveal_addrs(&p(Some(0))), "stranger row");
        assert!(!n.may_reveal_addrs(&p(Some(2))), "pending requester");
        assert!(n.may_reveal_addrs(&p(Some(1))), "someone I asked");
        assert!(n.may_reveal_addrs(&p(Some(3))), "friend");
        assert!(!n.may_reveal_addrs(&p(Some(4))), "blocked");
        assert!(!n.may_reveal_addrs(&n.device));
        let d = p(None);
        n.note_solicited(d);
        assert!(n.may_reveal_addrs(&d), "a device I dialed myself");
        n.shutdown();
    }

    #[test]
    fn hello_to_strangers_carries_no_app_or_os() {
        // (spawn_control) the gate is "own device or friend"; documented here so a refactor
        // that sends `os`/`app` to everyone again fails review
        let src = include_str!("conn.rs");
        assert!(src.contains("app: if trusted { super::push::app_string() } else { String::new() }"));
        assert!(src.contains("os: if trusted { std::env::consts::OS.into() } else { String::new() }"));
    }
}

/// Regression tests for the pre-release network/privacy review (each one failed before
/// its fix: the reviewer's PoCs with the assertions turned around).
#[cfg(test)]
mod review_regression_tests {
    use super::*;
    use crate::identity::Identity;

    async fn node(tmp: &std::path::Path) -> Arc<Node> {
        Node::start(NodeConfig {
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
        })
        .await
        .unwrap()
    }

    async fn count_packets(sock: &tokio::net::UdpSocket, wait: Duration) -> usize {
        let mut n = 0;
        let mut buf = [0u8; 2048];
        let end = tokio::time::Instant::now() + wait;
        while let Ok(Ok(_)) = tokio::time::timeout_at(end, sock.recv_from(&mut buf)).await {
            n += 1;
        }
        n
    }

    /// #3: a live link invitation used to open the address gate to every device.
    #[tokio::test]
    async fn link_invite_does_not_open_the_gate_for_everyone() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let s = Identity::generate().peer_id();
        assert!(!n.may_reveal_addrs(&s));
        n.link_invite().await.unwrap();
        assert!(!n.may_reveal_addrs(&s), "a link invitation revealed my addresses to a stranger");
        n.shutdown();
    }

    /// #2: `resume()` dialed strangers that had something queued (and the dial itself then
    /// marked them "solicited", opening the gate).
    #[tokio::test]
    async fn resume_does_not_dial_strangers_in_the_outbox() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let s = Identity::generate().peer_id();
        n.store.outbox_add(&[7u8; 16], &s, b"x").unwrap();
        assert!(!n.may_reveal_addrs(&s));
        let _ = n.resume();
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(!n.may_reveal_addrs(&s), "resume() dialed a stranger");
        n.shutdown();
    }

    /// #4: members of a group I am not (or no longer) in were treated as co-members.
    #[tokio::test]
    async fn members_of_a_group_i_left_are_strangers() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let owner = Identity::generate();
        let x = Identity::generate().peer_id();
        let (st, _op) = crate::group::create(&crate::devices::Signer::primary(&owner), 1, "g", vec![x], 0).unwrap();
        assert!(!st.is_member(&n.me));
        n.groups.write().insert(st.gid, st);
        assert!(!n.may_reveal_addrs(&x), "member of a group I am not in learns my addresses");
        n.shutdown();
    }

    /// #1 (critical): one sealed mail from a stranger re-assigned a friend's key to the
    /// stranger's account, revoked it, wiped its outbox and cut it off.
    #[tokio::test]
    async fn stranger_device_list_cannot_hijack_a_friend() {
        use crate::devices::{DeviceEntry, DeviceListBody, Revoked, SignedDeviceList, CAP_PRIMARY};
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let friend = Identity::generate();
        let f = friend.peer_id();
        n.store.upsert_contact(&f, Some("friend"), Some(3)).unwrap();
        n.store.outbox_add(&[9u8; 16], &f, b"queued for friend").unwrap();
        let listener = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let at = listener.local_addr().unwrap();
        let attacker = Identity::generate();
        let a = attacker.peer_id();
        let ae = DeviceEntry::new(a, "x", 3, CAP_PRIMARY, 1);
        // the attacker's own list names my friend's key as revoked, and (another
        // version) as one of its devices
        for (version, devices, revoked) in [
            (5, vec![ae.clone()], vec![Revoked { device: f, at: 5, wipe: false }]),
            (6, vec![ae.clone(), DeviceEntry::new(f, "y", 1, 0, 1)], vec![]),
        ] {
            let body = DeviceListBody { v: 1, account: a, version, devices, revoked };
            let l = SignedDeviceList::sign(&attacker, &body).unwrap();
            let msg = crate::proto::ext(crate::proto::ext::DEVICE_LIST, &crate::node::devices::DeviceListMsg { list: l.encode() });
            let sealed = seal_to(&attacker, &n.device, &rmp_serde::to_vec(&msg).unwrap()).unwrap();
            // plain sealed mail (Nostr / relay mailbox): no relationship needed to send it
            let _ = n.on_mail(&sealed).await;
        }
        assert_eq!(n.account_of(&f), f, "friend's key re-assigned to the attacker's account");
        assert!(!n.is_revoked(&n.account_of(&f), &f), "friend marked revoked");
        assert_eq!(n.store.outbox_page(&f, 0, 10).unwrap().len(), 1, "friend's outbox deleted");
        assert!(n.may_reveal_addrs(&f), "friend cut off");
        assert!(n.store.device_list_get(&a).is_none(), "a stranger's device list was stored");
        let info = ConnInfo { addrs: vec![at], port: at.port(), ..Default::default() };
        let s = Signal::Offer { sid: 77, info, name: "f".into() };
        let sig = net::relay_client::IncomingSignal { via: "test".into(), data: seal_to(&friend, &n.device, &rmp_serde::to_vec(&s).unwrap()).unwrap() };
        n.handle_signal(sig).await.unwrap();
        assert!(count_packets(&listener, Duration::from_secs(3)).await > 0, "friend's offer no longer answered");
        n.shutdown();
    }

    /// Two nodes on loopback that are friends.
    async fn pair(tmp: &std::path::Path) -> (Arc<Node>, Arc<Node>) {
        let a = node(&tmp.join("a")).await;
        let b = node(&tmp.join("b")).await;
        a.store.upsert_contact(&b.me, Some("b"), Some(3)).unwrap();
        b.store.upsert_contact(&a.me, Some("a"), Some(3)).unwrap();
        (a, b)
    }

    /// `a` dials `b` directly on loopback (no signaling); waits until `b` has it too.
    async fn link(a: &Arc<Node>, b: &Arc<Node>) -> Arc<PeerConn> {
        let addr: SocketAddr = format!("127.0.0.1:{}", b.net.local_port()).parse().unwrap();
        let c = a.net.dial_direct(b.device, vec![addr], Duration::from_secs(5)).await.unwrap();
        let pc = a.clone().setup_conn(c, PathKind::Lan, a.device, None).await.unwrap();
        for _ in 0..100 {
            if b.peer(&a.device).is_some() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        pc
    }

    fn wrapped_ping(i: u32, side: u8) -> ([u8; 16], Vec<u8>) {
        let mut id = [side; 16];
        id[..4].copy_from_slice(&i.to_le_bytes());
        (id, rmp_serde::to_vec(&PeerMsg::Wrapped { id, inner: Box::new(PeerMsg::Ping { t: 0 }) }).unwrap())
    }

    /// #10: both sides flush a long outbox at once (each control channel full): the acks
    /// must still get through, or everything stays queued until the 5-minute re-send.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn two_way_catch_up_keeps_its_acks() {
        let tmp = tempfile::tempdir().unwrap();
        let (a, b) = pair(tmp.path()).await;
        const N: u32 = 1500;
        for i in 0..N {
            let (id, p) = wrapped_ping(i, 1);
            a.store.outbox_add(&id, &b.device, &p).unwrap();
            let (id, p) = wrapped_ping(i, 2);
            b.store.outbox_add(&id, &a.device, &p).unwrap();
        }
        link(&a, &b).await;
        let left = |n: &Node, to: &PeerId| n.store.outbox_page(to, 0, 2000).unwrap().len();
        let end = Instant::now() + Duration::from_secs(40);
        while Instant::now() < end && (left(&a, &b.device) > 0 || left(&b, &a.device) > 0) {
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        assert_eq!((left(&a, &b.device), left(&b, &a.device)), (0, 0), "acks lost during a two-way catch-up");
        a.shutdown();
        b.shutdown();
    }

    /// #7: only one side thinks the path died and dials anew; the other side's tiebreak
    /// may prefer the old connection. Both must end on the same connection.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn one_sided_repair_ends_on_the_same_connection() {
        let tmp = tempfile::tempdir().unwrap();
        let (a, b) = pair(tmp.path()).await;
        link(&a, &b).await;
        for round in 0..6 {
            a.peer(&b.device).unwrap().mark_suspect();
            link(&a, &b).await;
            let end = Instant::now() + Duration::from_secs(5);
            let same = || {
                let (Some(x), Some(y)) = (a.peer(&b.device), b.peer(&a.device)) else { return false };
                conn_tiebreak_id(&x.conn) == conn_tiebreak_id(&y.conn)
            };
            while Instant::now() < end && !same() {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            assert!(same(), "round {round}: the two sides use different connections");
        }
        a.shutdown();
        b.shutdown();
    }

    /// #12: an offer captured earlier and replayed (after strangers flooded the dedupe
    /// cache) must not mark a healthy connection as dead.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn replayed_offer_does_not_break_a_healthy_connection() {
        let tmp = tempfile::tempdir().unwrap();
        let (a, b) = pair(tmp.path()).await;
        let dead: SocketAddr = "127.0.0.1:9".parse().unwrap();
        let info = ConnInfo { addrs: vec![dead], port: 9, ..Default::default() };
        let s = Signal::Offer { sid: 4242, info, name: "b".into() };
        let captured = net::relay_client::IncomingSignal { via: "test".into(), data: seal_to(&b.id, &a.device, &rmp_serde::to_vec(&s).unwrap()).unwrap() };
        a.handle_signal(captured.clone()).await.unwrap();
        tokio::time::sleep(Duration::from_millis(11_000)).await;
        link(&a, &b).await;
        let cur = a.peer(&b.device).unwrap();
        // strangers' offers (they used to evict entries of the shared dedupe cache)
        for i in 0..5000u64 {
            let x = Identity::generate();
            let s = Signal::Offer { sid: i, info: ConnInfo::default(), name: String::new() };
            let sig = net::relay_client::IncomingSignal { via: "t".into(), data: seal_to(&x, &a.device, &rmp_serde::to_vec(&s).unwrap()).unwrap() };
            let _ = a.handle_signal(sig).await;
        }
        a.handle_signal(captured).await.unwrap();
        assert!(!cur.is_suspect(), "a replayed offer marked a healthy connection as dead");
        assert!(a.usable_peer(&b.device).is_some());
        a.shutdown();
        b.shutdown();
    }

    /// #4: co-members of a PUBLIC group are strangers (anyone can join one) — except its
    /// owner/admins; a private group's co-members are not.
    #[tokio::test]
    async fn public_group_co_members_do_not_learn_my_addresses() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let owner = Identity::generate();
        let (x, adm) = (Identity::generate().peer_id(), Identity::generate().peer_id());
        let (mut st, _) = crate::group::create(&crate::devices::Signer::primary(&owner), 1, "pub", vec![n.me, x, adm], 0).unwrap();
        st.members.insert(adm, crate::group::Role::Admin);
        st.public = true;
        n.groups.write().insert(st.gid, st.clone());
        assert!(!n.may_reveal_addrs(&x), "an ordinary member of a public group learns my addresses");
        assert!(n.may_reveal_addrs(&adm), "public group admin");
        assert!(n.may_reveal_addrs(&owner.peer_id()), "public group owner");
        st.public = false;
        n.groups.write().insert(st.gid, st);
        assert!(n.may_reveal_addrs(&x), "private group co-member");
        n.shutdown();
    }

    /// #13: a stranger's Hello leaves nothing in the database (version kept in memory).
    #[tokio::test]
    async fn stranger_versions_are_not_persisted() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let s = Identity::generate().peer_id();
        n.record_peer_proto(&s, 3);
        assert!(n.store.kv_get(&format!("peer.proto.{}", s.to_base32())).is_none(), "stranger's version persisted");
        assert_eq!(n.peer_proto(&s), 3);
        let f = Identity::generate().peer_id();
        n.store.upsert_contact(&f, Some("f"), Some(3)).unwrap();
        n.record_peer_proto(&f, 3);
        assert!(n.store.kv_get(&format!("peer.proto.{}", f.to_base32())).is_some());
        n.shutdown();
    }

    /// #17: an `Ext` for a device whose version we don't know yet is queued (sent once its
    /// Hello says v3), not silently dropped.
    #[tokio::test]
    async fn ext_to_a_device_of_unknown_version_is_queued() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let d = Identity::generate().peer_id();
        let m = proto::ext(proto::ext::GROUP_REKEY_REQUEST, &json!({"gid": "x"}));
        n.deliver_dev(d, [3; 16], m.clone(), false).await;
        assert_eq!(n.store.outbox_page(&d, 0, 10).unwrap().len(), 1, "Ext dropped for a device of unknown version");
        // known to be older: not queued
        let old = Identity::generate().peer_id();
        n.store.upsert_contact(&old, Some("o"), Some(3)).unwrap();
        n.record_peer_proto(&old, 2);
        n.deliver_dev(old, [4; 16], m, false).await;
        assert!(n.store.outbox_page(&old, 0, 10).unwrap().is_empty());
        n.shutdown();
    }

    /// #18: a message too large for a control frame is not shown as sent: it fails and the
    /// user is told.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn oversized_message_is_marked_failed() {
        let tmp = tempfile::tempdir().unwrap();
        let (a, b) = pair(tmp.path()).await;
        let mut ev = a.subscribe();
        link(&a, &b).await;
        let id = [0x5au8; 16];
        let conv = direct_conv(&b.me);
        a.store.ensure_conv(&conv, 0, "b").unwrap();
        assert!(a.store.insert_message(&id, &conv, &a.me, a.hlc.tick(), "text", &json!({"text": "x"}), 0, None, None).unwrap());
        let big = PeerMsg::Ext { kind: 0x7ff0, body: vec![7u8; proto::MAX_CONTROL_FRAME + 10] };
        assert!(a.send_now_dev(&b.device, PeerMsg::Wrapped { id, inner: Box::new(big) }));
        let end = Instant::now() + Duration::from_secs(5);
        let mut told = false;
        while Instant::now() < end && !told {
            if let Ok(Ok(v)) = tokio::time::timeout(Duration::from_millis(200), ev.recv()).await {
                told |= v["event"] == "error" && v["code"] == "message_too_large";
            }
        }
        assert!(told, "no error event for an oversized message");
        assert_eq!(a.store.message(&id).unwrap().status, 4, "oversized message not marked failed");
        a.shutdown();
        b.shutdown();
    }

    /// #19: store-and-forward goes only to friends who know the recipient as far as we can
    /// tell (a private group the three share) — not to every connected friend.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn store_for_goes_only_to_friends_who_know_the_recipient() {
        let tmp = tempfile::tempdir().unwrap();
        let (a, c) = pair(tmp.path()).await;
        let r = Identity::generate().peer_id();
        a.store.upsert_contact(&r, Some("r"), Some(3)).unwrap();
        c.store.upsert_contact(&r, Some("r"), Some(3)).unwrap();
        link(&a, &c).await;
        a.store_and_forward(r, [1; 16], b"sealed").await;
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(c.store.mailbox_take(&r).unwrap().is_empty(), "StoreFor sent to a friend with no tie to the recipient");
        let owner = Identity::generate();
        let (st, _) = crate::group::create(&crate::devices::Signer::primary(&owner), 1, "g", vec![a.me, c.me, r], 0).unwrap();
        a.groups.write().insert(st.gid, st);
        a.store_and_forward(r, [2; 16], b"sealed").await;
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert_eq!(c.store.mailbox_take(&r).unwrap().len(), 1, "StoreFor not sent to a friend who shares a group with the recipient");
        a.shutdown();
        c.shutdown();
    }

    /// #8 / #9: failed upgrades and dials back off (30 s doubling, capped at 30 min).
    #[tokio::test]
    async fn upgrades_and_dials_back_off() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let p = Identity::generate().peer_id();
        assert!(n.upgrade_due(&p));
        assert_eq!(n.note_upgrade_failed(&p), Duration::from_secs(30));
        assert!(!n.upgrade_due(&p));
        assert_eq!(n.note_upgrade_failed(&p), Duration::from_secs(60));
        for _ in 0..20 {
            n.note_upgrade_failed(&p);
        }
        assert_eq!(n.note_upgrade_failed(&p), Duration::from_secs(1800));
        let _ = n.resume(); // a new network: try again
        assert!(n.upgrade_due(&p));
        assert!(n.dial_due(&p));
        n.note_dial_failed(&p);
        assert!(!n.dial_due(&p), "the reconnect sweep would dial a device that just failed");
        n.shutdown();
    }

    /// #5: friends' Nostr inbox (daily tags from the friends-only key); the public inbox
    /// only while strangers may find me or a link is pending.
    #[tokio::test]
    async fn nostr_public_inbox_follows_the_privacy_setting() {
        let tmp = tempfile::tempdir().unwrap();
        let n = Node::start(NodeConfig {
            data_dir: tmp.path().join("data"),
            downloads_dir: Some(tmp.path().join("dl")),
            enable_lan: false,
            enable_upnp: false,
            enable_dht: false,
            enable_nostr: true,
            relays: Some(vec![]),
            nostr: Some(vec!["ws://127.0.0.1:9/".into()]),
            stun: Some(vec![]),
            ..Default::default()
        })
        .await
        .unwrap();
        let p = n.net.nostr.read().clone().unwrap();
        n.refresh_nostr_inboxes(true);
        let subs = p.inboxes();
        assert_eq!(subs.public, Some(crate::net::nostr::inbox_tag(&n.device)), "discoverable by default");
        assert!(!subs.friend_tags.is_empty());
        assert!(!subs.friend_tags.contains(&crate::net::nostr::inbox_tag(&n.device)));
        n.store.kv_set("privacy.discoverable", b"0").unwrap();
        n.refresh_nostr_inboxes(false);
        assert_eq!(p.inboxes().public, None, "public inbox listened to while hidden from strangers");
        n.link_invite().await.unwrap();
        assert!(p.inboxes().public.is_some(), "a pending link needs the public inbox");
        // a friend's device that gave us its key gets signals under its friends' tag
        let f = Identity::generate().peer_id();
        assert_eq!(p.tag_for(&f), crate::net::nostr::inbox_tag(&f));
        p.set_friend_key(f, Some([5; 32]));
        assert_ne!(p.tag_for(&f), crate::net::nostr::inbox_tag(&f));
        n.shutdown();
    }

    /// #15: removing a relay stops its connection loop now.
    #[tokio::test]
    async fn removed_relay_stops() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        n.net.add_relay("ws://127.0.0.1:9/ws".into());
        let rc = n.net.relays.read().iter().find(|r| r.url == "ws://127.0.0.1:9/ws").cloned().unwrap();
        n.net.remove_relay("ws://127.0.0.1:9/ws");
        assert!(rc.is_stopped());
        assert!(n.net.relay_status().is_empty());
        let end = Instant::now() + Duration::from_secs(5);
        while Instant::now() < end && n.net.sock.router.relays.read().contains_key(&rc.idx) {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(!n.net.sock.router.relays.read().contains_key(&rc.idx), "removed relay still routing");
        n.shutdown();
    }

    /// #16: a peer announcing a huge sequential delta overflowed the port arithmetic.
    #[test]
    fn predicted_ports_do_not_overflow() {
        for d in [i32::MAX / 4, i32::MAX, i32::MIN, -1] {
            let their = ConnInfo { nat: NatKind::HardSequential(d), public_ip: Some("1.2.3.4".parse().unwrap()), mapped_ports: vec![1000], ..Default::default() };
            let r = std::panic::catch_unwind(|| predicted_ports(&their, true));
            assert!(r.is_ok(), "predicted_ports panicked for delta {d}");
            assert!(r.unwrap().iter().all(|a| a.port() > 0));
        }
        // after a NAT rebinding the flow toward us was often mapped just before the STUN
        // probes: the port below the reported ones is tried too (NAT lab `keepalive`)
        let their = ConnInfo { nat: NatKind::HardSequential(1), public_ip: Some("1.2.3.4".parse().unwrap()), mapped_ports: vec![50011, 50012], ..Default::default() };
        let p: Vec<u16> = predicted_ports(&their, false).iter().map(|a| a.port()).collect();
        assert_eq!(&p[..8], &[50013, 50014, 50015, 50016, 50017, 50018, 50019, 50020]);
        assert!(p.contains(&50010) && !p.contains(&50011) && !p.contains(&50012), "{p:?}");
    }
}
