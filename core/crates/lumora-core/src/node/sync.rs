//! Self-sync between the devices of one account (multi-device §3) and the bootstrap /
//! history transfer to a newly linked device (§2 step 6–8).
//!
//! * **Anti-entropy** (`Ext SelfSync`, own devices only): the store logs every change
//!   (`sync_log`) while the account has ≥ 2 devices. Each device sends its siblings
//!   `Have` (digests of what changed since the last acknowledged position), the sibling
//!   answers `Want` (only what differs), gets `Items`, applies them (idempotent merge
//!   rules, see store_sync.rs) and `Ack`s. Rounds start when a sibling connects and
//!   whenever the log moves (checked every second), so local actions reach the other
//!   devices within about a second; received messages that fan-out missed (old peers,
//!   stale device lists, mail sealed to the account) are repaired the same way.
//! * **Bootstrap + history** (`Ext HistoryRequest` + `STREAM_SYNC`): the new device asks
//!   the device that approved it for the account state (contacts, conversations, groups
//!   and their keys, settings, stickers…) and then the history window chosen at approval,
//!   in ≤ 256 KB batches imported one transaction each; the cursor is saved after every
//!   batch so an interrupted transfer resumes where it stopped.

use super::*;
use crate::proto::{ext, SyncBatch};
use crate::store::sync::{HistCursor, Imported, SyncItem};
use serde_bytes::ByteBuf;

const HAVE_BATCH: usize = 500;
const ITEMS_BYTES: usize = 1024 * 1024;
const BATCH_BYTES: usize = 256 * 1024;
const ROUND_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Serialize, Deserialize, Debug, Clone)]
pub(super) struct HaveEntry {
    pub k: u8,
    pub key: ByteBuf,
    #[serde(default)]
    pub d: Vec<u64>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub(super) enum SyncMsg {
    Have { upto: u64, entries: Vec<HaveEntry> },
    Want { upto: u64, keys: Vec<(u8, ByteBuf)> },
    Items { upto: u64, last: bool, items: Vec<ByteBuf> },
    Ack { upto: u64 },
}

#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub(super) struct HistoryRequestMsg {
    /// also send the account state first (bootstrap)
    #[serde(default)]
    pub state: bool,
    /// oldest message to copy (ms since epoch; 0 = everything)
    #[serde(default)]
    pub since_ms: u64,
    /// resume position (`HistCursor`, map-encoded); empty = from the start
    #[serde(default, with = "serde_bytes")]
    pub cursor: Vec<u8>,
    /// messages per batch the requester wants (0 = default; bounded by the server)
    #[serde(default)]
    pub limit: u32,
}

/// Saved on the new device (kv `link.history`): where and what to copy.
#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub(crate) struct HistoryPlan {
    pub source: String,
    pub since_ms: u64,
    #[serde(default)]
    pub media: bool,
    #[serde(default)]
    pub state_done: bool,
    #[serde(default)]
    pub done: bool,
    #[serde(default)]
    pub messages: u64,
}

#[derive(Default)]
pub struct SyncState {
    /// sibling → (round upto, started) while a round is in flight
    inflight: Mutex<HashMap<PeerId, (u64, Instant)>>,
    /// siblings we are streaming history to right now (generation: a newer request from
    /// the same device — e.g. after it reconnected — supersedes the old stream)
    serving: Mutex<HashMap<PeerId, u64>>,
    /// history requested from this sibling (avoid duplicate streams)
    requested: Mutex<HashMap<PeerId, Instant>>,
}

fn hist_batch_limit() -> usize {
    // test knob (debug builds only)
    let env = if cfg!(debug_assertions) { std::env::var("LUMORA_HIST_BATCH").ok() } else { None };
    env.and_then(|v| v.parse().ok()).filter(|n: &usize| *n > 0).unwrap_or(200)
}

impl Node {
    // ------------------------------------------------------------ dispatch

    pub(super) async fn on_ext(self: &Arc<Self>, pc: &Arc<PeerConn>, kind: u16, body: Vec<u8>) -> Result<()> {
        match kind {
            ext::DEVICE_SYNC | ext::DEVICE_LIST | ext::DEVICE_LIST_REQUEST | ext::DEVICE_ACCEPT => self.on_device_ext(pc, kind, &body)?,
            ext::PATH_CHOSEN => self.on_path_chosen(pc),
            ext::DEVICE_REVOKE_REQUEST if pc.own => self.on_revoke_request(pc.peer, &body).await?,
            ext::GROUP_REKEY_REQUEST => self.on_rekey_request(pc.account, &body).await?,
            ext::GROUP_KEY_REQUEST => self.on_group_key_request(pc.account, &body).await?,
            ext::LINK_HELLO..=ext::LINK_REJECT => self.on_link_ext(pc, kind, &body).await?,
            ext::SELF_SYNC if pc.own => self.on_self_sync(pc, &body)?,
            ext::HISTORY_REQUEST if pc.own => self.on_history_request(pc, &body)?,
            ext::REMOTE_CHALLENGE_V2 | ext::REMOTE_AUTH_V2 => self.remote.on_ext(self, pc, kind, &body).await?,
            ext::CALL_ELSEWHERE if pc.own => self.on_call_elsewhere(&body)?,
            #[cfg(feature = "media")]
            ext::VIDEO_CAPS => super::media_pipe::on_video_caps(self, pc, &body)?,
            ext::PROXY if pc.own => self.on_proxy(pc.peer, &body).await?,
            ext::DHT_KEY => self.on_dht_key(pc, &body)?,
            _ => tracing::debug!("ignoring ext kind {kind:#x} from {:?}", pc.peer),
        }
        Ok(())
    }

    /// `Ext` that arrived as offline mail (sealed by `dev` of `from`).
    pub(super) async fn on_ext_mail(self: &Arc<Self>, dev: PeerId, from: PeerId, kind: u16, body: Vec<u8>) -> Result<()> {
        let _ = dev;
        if kind == ext::DEVICE_LIST {
            let m: super::devices::DeviceListMsg = proto::ext_body(&body)?;
            self.accept_device_list(&m.list, from, from == self.me)?;
        } else if kind == ext::DEVICE_REVOKE_REQUEST && from == self.me {
            self.on_revoke_request(dev, &body).await?;
        } else if kind == ext::PROXY && from == self.me {
            self.on_proxy(dev, &body).await?;
        } else if kind == ext::GROUP_REKEY_REQUEST {
            self.on_rekey_request(from, &body).await?;
        } else if kind == ext::GROUP_KEY_REQUEST {
            self.on_group_key_request(from, &body).await?;
        } else if kind == ext::LINK_PRE {
            // multi-device link pre-authentication (before any address is revealed)
            self.on_link_pre_mail(dev, &body).await?;
        } else if (ext::REMOTE_PRE_REQ..=ext::REMOTE_PRE_RESULT).contains(&kind) {
            // remote-control pre-authentication (no connection, no addresses): node/remote.rs
            self.on_remote_pre_mail(dev, kind, &body).await?;
        }
        Ok(())
    }

    /// A device speaking v3 said hello.
    pub(super) fn on_v3_hello(self: &Arc<Self>, pc: &Arc<PeerConn>) {
        if !pc.own {
            return;
        }
        self.olm_ensure_session(pc);
        self.sync.inflight.lock().remove(&pc.peer);
        self.sync_round(pc);
        self.maybe_request_history(pc);
    }

    // ------------------------------------------------------------ anti-entropy

    /// Background: start rounds for connected siblings whenever the log moved.
    pub(super) fn spawn_sync_loop(self: &Arc<Self>) {
        let node = self.clone();
        tokio::spawn(async move {
            let mut sd = node.shutdown.subscribe();
            loop {
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(1)) => {}
                    _ = sd.changed() => return,
                }
                if !node.store.sync_enabled() {
                    continue;
                }
                for pc in node.connected_peers() {
                    if pc.own && pc.proto.load(std::sync::atomic::Ordering::Relaxed) >= proto::PROTO_V3 {
                        node.sync_round(&pc);
                    }
                }
            }
        });
    }

    fn sync_round(&self, pc: &Arc<PeerConn>) {
        if !self.store.sync_enabled() {
            return;
        }
        let sent = self.store.sync_peer_sent(&pc.peer).unwrap_or(0);
        if self.store.sync_head() <= sent {
            return;
        }
        {
            let mut inf = self.sync.inflight.lock();
            if let Some((_, t)) = inf.get(&pc.peer) {
                if t.elapsed() < ROUND_TIMEOUT {
                    return;
                }
            }
            let entries = self.store.sync_log_since(sent, HAVE_BATCH);
            let Some(upto) = entries.iter().map(|e| e.0).max() else { return };
            inf.insert(pc.peer, (upto, Instant::now()));
            let entries: Vec<HaveEntry> = entries
                .into_iter()
                .map(|(_, k, key)| {
                    let d = self.store.sync_digest(k, &key).unwrap_or_default();
                    HaveEntry { k, key: ByteBuf::from(key), d }
                })
                .collect();
            let _ = pc.ctl.try_send(proto::ext(ext::SELF_SYNC, &SyncMsg::Have { upto, entries }));
        }
    }

    fn on_self_sync(self: &Arc<Self>, pc: &Arc<PeerConn>, body: &[u8]) -> Result<()> {
        match proto::ext_body::<SyncMsg>(body)? {
            SyncMsg::Have { upto, entries } => {
                let keys: Vec<(u8, ByteBuf)> =
                    entries.into_iter().take(HAVE_BATCH).filter(|e| self.store.sync_wants(e.k, &e.key, &e.d)).map(|e| (e.k, e.key)).collect();
                let _ = pc.ctl.try_send(proto::ext(ext::SELF_SYNC, &SyncMsg::Want { upto, keys }));
            }
            SyncMsg::Want { upto, keys } => {
                if keys.is_empty() {
                    self.sync_acked(pc, upto);
                    return Ok(());
                }
                let mut batch: Vec<ByteBuf> = vec![];
                let mut bytes = 0;
                for (k, key) in keys.into_iter().take(HAVE_BATCH) {
                    let Some(item) = self.store.sync_export(k, &key) else { continue };
                    let b = item.encode();
                    if bytes + b.len() > ITEMS_BYTES && !batch.is_empty() {
                        let _ = pc.ctl.try_send(proto::ext(ext::SELF_SYNC, &SyncMsg::Items { upto, last: false, items: std::mem::take(&mut batch) }));
                        bytes = 0;
                    }
                    bytes += b.len();
                    batch.push(ByteBuf::from(b));
                }
                let _ = pc.ctl.try_send(proto::ext(ext::SELF_SYNC, &SyncMsg::Items { upto, last: true, items: batch }));
            }
            SyncMsg::Items { upto, last, items } => {
                for b in items {
                    if let Some(it) = SyncItem::decode(&b) {
                        if let Err(e) = self.apply_sync_item(it, true) {
                            tracing::debug!("sync item from {:?}: {e:#}", pc.peer);
                        }
                    }
                }
                if last {
                    let _ = pc.ctl.try_send(proto::ext(ext::SELF_SYNC, &SyncMsg::Ack { upto }));
                }
            }
            SyncMsg::Ack { upto } => self.sync_acked(pc, upto),
        }
        Ok(())
    }

    fn sync_acked(&self, pc: &Arc<PeerConn>, upto: u64) {
        let _ = self.store.sync_peer_set_sent(&pc.peer, upto);
        self.sync.inflight.lock().remove(&pc.peer);
        // more to send? go on right away
        self.sync_round(pc);
    }

    /// Apply one item from my own device and tell the UI.
    pub(super) fn apply_sync_item(self: &Arc<Self>, item: SyncItem, live: bool) -> Result<()> {
        if let SyncItem::DeviceList { list } = &item {
            self.accept_device_list(list, self.me, true)?;
            return Ok(());
        }
        let r = self.store.sync_import(&item, &self.me, live)?;
        self.after_import(r, live);
        Ok(())
    }

    fn after_import(self: &Arc<Self>, r: Imported, live: bool) {
        match r {
            Imported::Nothing | Imported::Stored => {}
            Imported::MsgNew { conv, id } => {
                if !live {
                    return;
                }
                if let Some(m) = self.store.message(&id) {
                    // our copy of a friend's file: offered like any received file
                    if (m.kind == "file" || m.kind == "voice") && m.author != self.me.to_base32() {
                        if let (Ok(author), Some(fid)) = (PeerId::from_str_any(&m.author), m.body["file_id"].as_str().and_then(|h| hex::decode(h).ok())) {
                            if let Ok(fid) = <[u8; 16]>::try_from(fid.as_slice()) {
                                let hash = m.body["hash"].as_str().and_then(|h| hex::decode(h).ok()).and_then(|h| <[u8; 32]>::try_from(h.as_slice()).ok());
                                let name = m.body["name"].as_str().map(String::from).unwrap_or_else(|| format!("voice-{}.ogg", &hex::encode(fid)[..8]));
                                if let Some(hash) = hash {
                                    let _ = self.on_file_offer(author, fid, name, m.body["size"].as_u64().unwrap_or(0), hash, conv.clone());
                                }
                            }
                        }
                    }
                    let preview = preview_of_row(&m);
                    let text = if conv.starts_with("g:") && m.author != self.me.to_base32() {
                        let a = PeerId::from_str_any(&m.author).map(|p| self.display_name(&p)).unwrap_or_default();
                        format!("{a}: {preview}")
                    } else {
                        preview
                    };
                    let _ = self.store.conv_touch(&conv, m.ts, &text, false);
                    self.emit("message", self.msg_json(&m));
                }
                self.emit_conv(&conv);
            }
            Imported::MsgUpdated { conv, id } => {
                if let Some(m) = self.store.message(&id) {
                    self.emit(
                        "message_update",
                        json!({"conv": conv, "id": m.id, "status": m.status, "edited": m.edited, "deleted": m.deleted,
                               "reactions": m.reactions, "pinned": m.pinned, "body": m.body}),
                    );
                }
            }
            Imported::MsgPurged { conv, id } => {
                self.emit("message_update", json!({"conv": conv, "id": hex::encode(id), "removed": true}));
                self.emit_conv(&conv);
            }
            Imported::Conv { conv, cleared_upto } => {
                if let Some(upto) = cleared_upto {
                    let _ = self.clear_local(&conv, upto.max(0) as u64, false);
                }
                self.emit_conv(&conv);
            }
            Imported::ConvDeleted { conv } => {
                let _ = self.clear_local(&conv, i64::MAX as u64, true);
            }
            Imported::Contact { peer } => self.emit_contact(&peer),
            Imported::Kv { key } => {
                if key == "profile.name" {
                    if let Some(n) = self.store.kv_get("profile.name").and_then(|v| String::from_utf8(v).ok()) {
                        *self.name.write() = n;
                    }
                }
                if key == "ui.lang" {
                    if let Some(l) = self.store.kv_get("ui.lang").and_then(|v| String::from_utf8(v).ok()) {
                        crate::i18n::set_lang(&l);
                    }
                }
                if key.starts_with("profile.") {
                    self.emit("profile", json!({"key": key, "name": self.name()}));
                }
            }
            Imported::GroupKey { gid, .. } => {
                if let Ok(g) = <[u8; 16]>::try_from(gid.as_slice()) {
                    self.retry_pending(g);
                }
            }
            Imported::Group { gid } => {
                if let Some(st) = self.store.group_load(&gid).and_then(|b| crate::proto::from_slice_capped::<GroupState>(&b).ok()) {
                    let conv = st.conv_id();
                    self.groups.write().insert(st.gid, st);
                    if live {
                        self.emit_conv(&conv);
                    }
                }
            }
        }
    }

    fn display_name(&self, p: &PeerId) -> String {
        if *p == self.me {
            return self.name();
        }
        self.store.contact(p).map(|c| c.alias.unwrap_or(c.name)).filter(|n| !n.is_empty()).unwrap_or_else(|| p.short_id_fmt())
    }

    /// Storage hygiene: the log only needs what some sibling hasn't acknowledged, and
    /// devices gone for a month don't keep copies queued (they catch up from siblings).
    pub(super) fn sync_maintain(&self) {
        let now = now_ms();
        let dormant = |d: &crate::store::sync::DeviceRow| d.last_seen > 0 && d.last_seen + 30 * 86_400_000 < now && d.added + 30 * 86_400_000 < now;
        for acc in self.store.friend_ids().into_iter().chain(std::iter::once(self.me)) {
            for d in self.store.devices_of(&acc) {
                if d.device != acc && d.device != self.device && (d.revoked.is_some() || dormant(&d)) {
                    let _ = self.store.outbox_purge_device(&d.device);
                }
            }
        }
        let sibs = self.siblings();
        if sibs.is_empty() {
            let _ = self.store.sync_log_trim(u64::MAX >> 1);
        } else if let Some(min) = self.store.sync_peers_min_sent(&sibs) {
            let _ = self.store.sync_log_trim(min);
        }
    }

    // ------------------------------------------------------------ history (new device side)

    pub(crate) fn history_plan(&self) -> Option<HistoryPlan> {
        self.store.kv_get_json("link.history")
    }

    fn maybe_request_history(&self, pc: &Arc<PeerConn>) {
        let Some(plan) = self.history_plan() else { return };
        if plan.done {
            return;
        }
        // prefer the device that approved us; any sibling once it's been gone a while
        let from_source = PeerId::from_str_any(&plan.source).map(|s| s == pc.peer).unwrap_or(true);
        if !from_source && self.sync.requested.lock().values().any(|t| t.elapsed() < Duration::from_secs(120)) {
            return;
        }
        {
            let mut r = self.sync.requested.lock();
            if r.get(&pc.peer).map(|t| t.elapsed() < Duration::from_secs(10)).unwrap_or(false) {
                return;
            }
            r.insert(pc.peer, Instant::now());
        }
        let (cursor, _) = self.store.sync_peer_hist(&pc.peer).unwrap_or_default();
        let req = HistoryRequestMsg { state: !plan.state_done, since_ms: plan.since_ms, cursor, limit: hist_batch_limit() as u32 };
        tracing::info!("requesting {} history from {:?}", if req.state { "state +" } else { "" }, pc.peer);
        let _ = pc.ctl.try_send(proto::ext(ext::HISTORY_REQUEST, &req));
        self.emit("link_state", json!({"state": "syncing"}));
    }

    /// One `STREAM_SYNC` from my own device: import batch by batch (one transaction each).
    pub(super) async fn receive_sync_stream(self: &Arc<Self>, pc: &Arc<PeerConn>, mut recv: quinn::RecvStream) -> Result<()> {
        anyhow::ensure!(pc.own, "sync stream from a device that isn't mine");
        let mut plan = self.history_plan().unwrap_or_default();
        while let Some(b) = proto::read_sync_frame(&mut recv).await? {
            let items: Vec<SyncItem> = b.items.iter().filter_map(|x| SyncItem::decode(x)).collect();
            let lists: Vec<Vec<u8>> = items.iter().filter_map(|i| if let SyncItem::DeviceList { list } = i { Some(list.to_vec()) } else { None }).collect();
            let store_items: Vec<SyncItem> = items.into_iter().filter(|i| !matches!(i, SyncItem::DeviceList { .. })).collect();
            let results = {
                let s = self.store.clone();
                let me = self.me;
                tokio::task::spawn_blocking(move || s.sync_import_batch(&store_items, &me, false)).await??
            };
            for l in lists {
                let _ = self.accept_device_list(&l, self.me, true);
            }
            let mut msgs = 0u64;
            for r in results {
                if matches!(r, Imported::MsgNew { .. }) {
                    msgs += 1;
                }
                self.after_import(r, false);
            }
            if b.phase == 1 {
                if b.done {
                    plan.state_done = true;
                    self.store.kv_set_json("link.history", &plan)?;
                    // the bootstrap brought the profile name
                    if let Some(n) = self.store.kv_get("profile.name").and_then(|v| String::from_utf8(v).ok()) {
                        *self.name.write() = n;
                    }
                    self.emit("link_state", json!({"state": "state_synced"}));
                    for g in self.groups_list() {
                        self.emit("group", g);
                    }
                }
                continue;
            }
            plan.messages += msgs;
            self.store.sync_peer_set_hist(&pc.peer, &b.cursor, b.done)?;
            if b.done {
                plan.done = true;
            }
            self.store.kv_set_json("link.history", &plan)?;
            self.emit(
                "history_sync",
                json!({"messages": plan.messages, "convs_done": b.convs_done, "convs_total": b.convs_total, "done": b.done, "from": pc.peer.to_base32()}),
            );
            if b.done {
                if let Ok(list) = self.conversations() {
                    for c in list {
                        self.emit("conversation", serde_json::to_value(c).unwrap_or(Value::Null));
                    }
                }
                break;
            }
        }
        Ok(())
    }

    pub fn history_status(&self) -> Value {
        match self.history_plan() {
            Some(p) => json!({"active": !p.done, "state_done": p.state_done, "done": p.done, "messages": p.messages, "since_ms": p.since_ms, "source": p.source}),
            None => json!({"active": false, "done": true, "messages": 0}),
        }
    }

    // ------------------------------------------------------------ history (serving side)

    fn on_history_request(self: &Arc<Self>, pc: &Arc<PeerConn>, body: &[u8]) -> Result<()> {
        let req: HistoryRequestMsg = proto::ext_body(body)?;
        let gen: u64 = rand::random();
        self.sync.serving.lock().insert(pc.peer, gen);
        let me = self.clone();
        let pc = pc.clone();
        tokio::spawn(async move {
            pc.busy.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            if let Err(e) = me.serve_history(&pc, req, gen).await {
                tracing::info!("history stream to {:?} stopped: {e:#}", pc.peer);
            }
            pc.busy.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
            let mut s = me.sync.serving.lock();
            if s.get(&pc.peer) == Some(&gen) {
                s.remove(&pc.peer);
            }
        });
        Ok(())
    }

    fn superseded(&self, dev: &PeerId, gen: u64) -> bool {
        self.sync.serving.lock().get(dev) != Some(&gen)
    }

    async fn serve_history(self: &Arc<Self>, pc: &Arc<PeerConn>, req: HistoryRequestMsg, gen: u64) -> Result<()> {
        let mut s = pc.conn.open_uni().await?;
        s.set_priority(-2)?; // chat, control and files first
        s.write_all(&[proto::STREAM_SYNC]).await?;
        if req.state {
            let items = {
                let st = self.store.clone();
                tokio::task::spawn_blocking(move || st.bootstrap_items()).await?
            };
            let mut batch = SyncBatch { phase: 1, ..Default::default() };
            let mut bytes = 0;
            for it in items {
                let b = it.encode();
                if b.len() > proto::MAX_SYNC_FRAME - 1024 {
                    continue;
                }
                if bytes + b.len() > BATCH_BYTES && !batch.items.is_empty() {
                    proto::write_sync_frame(&mut s, &batch).await?;
                    batch.items.clear();
                    bytes = 0;
                }
                bytes += b.len();
                batch.items.push(ByteBuf::from(b));
            }
            batch.done = true;
            proto::write_sync_frame(&mut s, &batch).await?;
        }
        let since_hlc = (req.since_ms as i64) << 8;
        let mut cur: HistCursor = if req.cursor.is_empty() { HistCursor::default() } else { crate::proto::from_slice_capped(&req.cursor).unwrap_or_default() };
        let total = self.store.history_conv_count(since_hlc);
        let limit = if req.limit > 0 { (req.limit as usize).clamp(10, 1000) } else { hist_batch_limit() };
        let mut convs_seen: std::collections::HashSet<String> = Default::default();
        loop {
            anyhow::ensure!(!self.superseded(&pc.peer, gen), "superseded by a newer request");
            let (items, next, done) = {
                let st = self.store.clone();
                let c = cur.clone();
                tokio::task::spawn_blocking(move || st.history_page(&c, since_hlc, limit)).await?
            };
            let mut batch = SyncBatch { phase: 2, convs_total: total, ..Default::default() };
            let mut bytes = 0;
            for it in items {
                if let SyncItem::Msg(m) = &it {
                    convs_seen.insert(m.conv.clone());
                }
                let b = it.encode();
                if b.len() > proto::MAX_SYNC_FRAME - 1024 {
                    continue;
                }
                if bytes + b.len() > BATCH_BYTES && !batch.items.is_empty() {
                    // an intermediate frame carries the *previous* cursor: safe to resume from
                    batch.cursor = rmp_serde::to_vec_named(&cur).unwrap_or_default();
                    batch.convs_done = convs_seen.len() as u32;
                    proto::write_sync_frame(&mut s, &batch).await?;
                    batch.items.clear();
                    bytes = 0;
                }
                bytes += b.len();
                batch.items.push(ByteBuf::from(b));
            }
            cur = next;
            batch.cursor = rmp_serde::to_vec_named(&cur).unwrap_or_default();
            batch.convs_done = convs_seen.len() as u32;
            batch.done = done;
            proto::write_sync_frame(&mut s, &batch).await?;
            if done {
                break;
            }
            tokio::task::yield_now().await;
        }
        s.finish()?;
        let _ = s.stopped().await;
        Ok(())
    }
}

/// Chat-list preview for a stored row (bodies are kept as JSON).
fn preview_of_row(m: &crate::store::StoredMessage) -> String {
    match m.kind.as_str() {
        "text" | "system" => m.body["text"].as_str().unwrap_or("").to_string(),
        "file" => {
            let mime = m.body["mime"].as_str().unwrap_or("");
            if mime.starts_with("image/") {
                "🖼️ Photo".into()
            } else if mime.starts_with("video/") {
                "🎬 Video".into()
            } else {
                crate::i18n::trf("pv.file", &[("name", m.body["name"].as_str().unwrap_or(""))])
            }
        }
        "voice" => "🎤 Voice message".into(),
        "sticker" => "🙂 Sticker".into(),
        "location" => "📍 Location".into(),
        "poll" => crate::i18n::trf("pv.poll", &[("question", m.body["question"].as_str().unwrap_or(""))]),
        "checklist" => crate::i18n::trf("pv.checklist", &[("title", m.body["title"].as_str().unwrap_or(""))]),
        "reminder" => crate::i18n::trf("pv.reminder", &[("title", m.body["title"].as_str().unwrap_or(""))]),
        _ => String::new(),
    }
}
