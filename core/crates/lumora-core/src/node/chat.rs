//! Friends and direct (1-1) chat.

use super::*;
use crate::proto::{Body, ChatMsg, MsgAction, MsgMeta};
use crate::store::StoredMessage;

/// Incoming friend requests kept pending at most (anti-spam; identities are free).
pub(crate) const MAX_PENDING_REQUESTS: usize = 500;
/// Largest received chat message we store, inline sticker image excluded (senders cap
/// text at 64 KB and thumbnails/previews at ~70 KB; a control frame may carry 4 MB).
pub(crate) const MAX_STORED_MSG: usize = 160 * 1024;

/// Receive-side size check for a chat message (direct or group) before it is stored.
pub(crate) fn chat_msg_size_ok(m: &ChatMsg) -> bool {
    let sticker = match &m.body {
        Body::Sticker { data, .. } => data.len(),
        _ => 0,
    };
    sticker <= 1024 * 1024 && rmp_serde::to_vec(m).map(|v| v.len().saturating_sub(sticker) <= MAX_STORED_MSG).unwrap_or(false)
}

/// Receive-side size check for an edit/reaction/etc. (an edit carries a whole new text).
pub(crate) fn action_size_ok(a: &MsgAction) -> bool {
    rmp_serde::to_vec(a).map(|v| v.len() <= MAX_STORED_MSG).unwrap_or(false)
}

type SendOnceLocks = HashMap<(PeerId, String), Arc<tokio::sync::Mutex<()>>>;
static SEND_ONCE_LOCKS: Mutex<Option<SendOnceLocks>> = parking_lot::const_mutex(None);

pub(crate) fn dm_scope(a: &PeerId, b: &PeerId) -> Vec<u8> {
    let (x, y) = if a < b { (a, b) } else { (b, a) };
    let mut v = b"d".to_vec();
    v.extend_from_slice(&x.0);
    v.extend_from_slice(&y.0);
    v
}

pub(super) fn action_bytes(id: &[u8; 16], author: &PeerId, hlc: u64, a: &MsgAction) -> Vec<u8> {
    let mut v = b"lumora-action-v1".to_vec();
    v.extend_from_slice(id);
    v.extend_from_slice(&author.0);
    v.extend_from_slice(&hlc.to_le_bytes());
    v.extend(rmp_serde::to_vec(a).unwrap_or_default());
    v
}

impl Node {
    pub fn msg_json(&self, m: &StoredMessage) -> Value {
        let mut v = serde_json::to_value(m).unwrap_or(Value::Null);
        v["mine"] = Value::Bool(m.author == self.me.to_base32());
        v["silent"] = Value::Bool(m.meta["silent"].as_bool().unwrap_or(false));
        // a locked chat (account setting): every device hides its notification content
        if self.chat_locked(&m.conv) {
            v["locked"] = Value::Bool(true);
        }
        // group members who aren't my contacts: the name they gave the group (else the app
        // can only show a short id)
        if m.conv.starts_with("g:") && !v["mine"].as_bool().unwrap_or(false) {
            if let Some(n) = self.store.kv_get(&format!("member.name.{}", m.author)).and_then(|v| String::from_utf8(v).ok()).filter(|n| !n.is_empty()) {
                v["author_name"] = Value::String(n);
            }
        }
        // attach local file state so the UI can show the picture/progress inline
        if m.kind == "file" || m.kind == "voice" {
            if let Some(f) = self.file_of_message(m) {
                v["file"] = json!({
                    "state": f.state, "progress": f.progress, "size": f.size,
                    "path": if f.state == 2 || f.direction == 0 { f.path.clone() } else { String::new() },
                    "direction": f.direction,
                });
            }
            // file ids are per sender: when this sender's id collides with another peer's,
            // the app addresses the file by its local id (accept/cancel/progress events)
            if let Some(local) = self.local_file_ref(m) {
                v["body"]["wire_file_id"] = v["body"]["file_id"].clone();
                v["body"]["file_id"] = json!(local);
            }
        }
        v
    }

    fn emit_message(&self, id: &[u8]) {
        if let Some(m) = self.store.message(id) {
            self.emit("message", self.msg_json(&m));
        }
    }

    /// The chat list (each row says whether its last message is mine).
    pub fn conversations(&self) -> Result<Vec<crate::store::Conversation>> {
        self.store.conversations_for(Some(&self.me))
    }

    /// Run a send at most once per app `client_id` (≤ 64 chars) on this device: a retry
    /// within 24 h (lost response, app restart, double tap) gets the message created the
    /// first time — its current state — instead of a duplicate.
    pub async fn send_once<F, Fut>(&self, client_id: &str, send: F) -> Result<Value>
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = Result<Value>>,
    {
        anyhow::ensure!(!client_id.is_empty() && client_id.chars().count() <= 64, "client_id must be 1–64 characters");
        // concurrent retries with the same id: one at a time
        let lock = {
            let mut m = SEND_ONCE_LOCKS.lock();
            let m = m.get_or_insert_with(HashMap::new);
            if m.len() > 1024 {
                m.retain(|_, l| Arc::strong_count(l) > 1);
            }
            m.entry((self.device, client_id.to_string())).or_default().clone()
        };
        let _g = lock.lock().await;
        if let Some(prev) = self.store.send_client_get(client_id) {
            let current = prev["id"].as_str().and_then(|h| hex::decode(h).ok()).and_then(|id| self.store.message(&id)).map(|m| self.msg_json(&m));
            return Ok(current.unwrap_or(prev));
        }
        let v = send().await?;
        let _ = self.store.send_client_put(client_id, &v);
        Ok(v)
    }

    pub(super) fn emit_conv(&self, conv: &str) {
        if let Ok(list) = self.conversations() {
            if let Some(c) = list.into_iter().find(|c| c.id == conv) {
                self.emit("conversation", serde_json::to_value(c).unwrap_or(Value::Null));
            }
        }
    }

    // ------------------------------------------------------------ contacts

    pub async fn resolve_id(self: &Arc<Self>, id: &str) -> Result<PeerId> {
        if id.trim().starts_with('@') {
            let c = self.resolve_username(id).await?;
            return match c.len() {
                0 => Err(crate::i18n::user_err("err.username_not_found").with("name", id.trim()).into()),
                1 => PeerId::from_str_any(c[0]["peer"].as_str().unwrap_or("")),
                _ => Err(crate::i18n::user_err("err.username_ambiguous").with("name", id.trim()).into()),
            };
        }
        let digits: String = id.chars().filter(|c| c.is_ascii_digit()).collect();
        if digits.len() == 9 && id.chars().all(|c| c.is_ascii_digit() || c.is_whitespace()) {
            let sid: u32 = digits.parse()?;
            // local contacts first
            for c in self.store.contacts()? {
                let p = PeerId::from_str_any(&c.peer)?;
                if p.short_id() == sid {
                    return Ok(p);
                }
            }
            // connected peers and devices on the same network first (works fully offline)
            for pc in self.connected_peers() {
                if pc.peer.short_id() == sid {
                    return Ok(pc.peer);
                }
            }
            // devices of my account and of my contacts (each device has its own short ID)
            if let Some(d) = self.store.device_by_short_id(sid) {
                return Ok(d);
            }
            let lan: Vec<PeerId> = self.net.lan.peers.read().keys().copied().collect();
            if let Some(p) = lan.into_iter().find(|p| p.short_id() == sid) {
                return Ok(p);
            }
            let pool = self.net.nostr.read().clone().ok_or_else(|| crate::i18n::user_err("err.id_not_found").with("sid", sid))?;
            let found = pool.lookup_short_id_full(sid).await;
            if let [(d, _, Some(cert))] = found.as_slice() {
                self.learn_directory_cert(d, cert);
            }
            return match found.len() {
                0 => Err(crate::i18n::user_err("err.id_not_found").with("sid", sid).into()),
                1 => Ok(found[0].0),
                _ => Err(crate::i18n::user_err("err.id_ambiguous").with("sid", sid).into()),
            };
        }
        PeerId::from_str_any(id).map_err(|e| anyhow::Error::from(crate::i18n::user_err("err.invalid_id").detail(e)))
    }

    pub async fn add_contact(self: &Arc<Self>, id: &str, note: &str) -> Result<PeerId> {
        // Telegram rule: bots can't start conversations — users must start the bot first
        anyhow::ensure!(!self.is_bot(), crate::i18n::user_err("err.bot_cannot_start"));
        let p = self.resolve_id(id).await?;
        // a device's own ID: befriend its account
        let p = self.account_of(&p);
        anyhow::ensure!(p != self.me, crate::i18n::user_err("err.own_id"));
        let cur = self.store.contact(&p).map(|c| c.status).unwrap_or(0);
        if cur == 2 {
            self.accept_contact(&p).await?;
            return Ok(p);
        }
        if cur != 3 {
            self.store.upsert_contact(&p, None, Some(1))?;
        }
        self.emit_contact(&p);
        let id: [u8; 16] = crate::crypto::random_bytes();
        self.deliver(p, id, PeerMsg::FriendRequest { name: self.name(), note: note.chars().take(200).collect() }, true).await;
        Ok(p)
    }

    pub async fn accept_contact(self: &Arc<Self>, p: &PeerId) -> Result<()> {
        self.store.upsert_contact(p, None, Some(3))?;
        let name = self.store.contact(p).map(|c| c.name).unwrap_or_default();
        self.store.ensure_conv(&direct_conv(p), 0, &name)?;
        self.emit_contact(p);
        self.emit_conv(&direct_conv(p));
        let id: [u8; 16] = crate::crypto::random_bytes();
        self.deliver(*p, id, PeerMsg::FriendAccept { name: self.name() }, true).await;
        self.push_profile_to(*p);
        self.on_became_friends(p);
        Ok(())
    }

    pub fn remove_contact(&self, p: &PeerId, block: bool) -> Result<()> {
        anyhow::ensure!(*p != self.me, crate::i18n::user_err("err.own_id"));
        let was_friend = self.store.is_friend(p);
        self.store.upsert_contact(p, None, Some(if block { 4 } else { 0 }))?;
        if was_friend {
            self.rotate_dht_key(); // their copy of my friends-only DHT key stops working
        }
        self.send_now(p, PeerMsg::FriendRemove);
        if block {
            for c in self.peers_of(p) {
                c.conn.close(1u32.into(), b"blocked");
            }
        }
        self.emit_contact(p);
        Ok(())
    }

    pub(super) fn on_friend_request(&self, from: PeerId, name: String, note: String) -> Result<()> {
        let name: String = name.chars().take(48).collect();
        let cur = self.store.contact(&from).map(|c| c.status).unwrap_or(0);
        match cur {
            4 => return Ok(()),
            3 | 1 => {
                // already friends or we asked them too → mutual
                self.store.upsert_contact(&from, Some(&name), Some(3))?;
                self.store.ensure_conv(&direct_conv(&from), 0, &name)?;
                self.send_now(&from, PeerMsg::FriendAccept { name: self.name() });
                self.push_profile_to(from);
                self.on_became_friends(&from);
                self.emit_contact(&from);
                self.emit_conv(&direct_conv(&from));
            }
            _ if self.store.kv_get("bot.auto_accept").map(|v| v == b"1").unwrap_or(false) => {
                // bots accept everyone (like Telegram bots: anyone can start a chat)
                self.store.upsert_contact(&from, Some(&name), Some(3))?;
                self.store.ensure_conv(&direct_conv(&from), 0, &name)?;
                self.send_now(&from, PeerMsg::FriendAccept { name: self.name() });
                if let Some(me) = self.self_ref.lock().as_ref().and_then(|w| w.upgrade()) {
                    let n = self.name();
                    tokio::spawn(async move {
                        let id: [u8; 16] = crate::crypto::random_bytes();
                        me.deliver(from, id, PeerMsg::FriendAccept { name: n }, true).await;
                    });
                }
                self.push_profile_to(from);
                self.on_became_friends(&from);
                self.emit_contact(&from);
                self.emit("bot_user", json!({"peer": from.to_base32(), "name": name}));
            }
            _ => {
                // anti-spam: identities are free, so bound what strangers can make us store
                // and notify — a repeat from a pending requester is not a new request, and the
                // pending list is capped (the oldest stay; new ones wait until the user acts)
                let repeat = cur == 2;
                if !repeat && self.store.contacts().map(|c| c.iter().filter(|c| c.status == 2).count()).unwrap_or(0) >= MAX_PENDING_REQUESTS {
                    // not acknowledged: the sender's outbox tries again later (never acked-then-lost)
                    tracing::warn!("friend request from {from:?} deferred: {MAX_PENDING_REQUESTS} requests already pending");
                    return Err(super::conn::NotNow("pending friend requests").into());
                }
                self.store.upsert_contact(&from, Some(&name), Some(2))?;
                self.emit_contact(&from);
                if !repeat {
                    let note: String = note.chars().take(200).collect();
                    self.emit("friend_request", json!({"peer": from.to_base32(), "name": name, "note": note, "short_id": from.short_id_fmt()}));
                }
            }
        }
        Ok(())
    }

    pub(super) fn on_friend_accept(&self, from: PeerId, name: String) -> Result<()> {
        let r = self.on_friend_accept_inner(from, name);
        if self.store.is_friend(&from) {
            self.on_became_friends(&from);
        }
        r
    }

    fn on_friend_accept_inner(&self, from: PeerId, name: String) -> Result<()> {
        let cur = self.store.contact(&from).map(|c| c.status).unwrap_or(0);
        // only an answer to *our* request (1) makes a friend: a pending requester (2) sending
        // FriendAccept on its own must not friend itself without the user's consent
        if cur == 1 || cur == 3 {
            let name: String = name.chars().take(48).collect();
            self.store.upsert_contact(&from, Some(&name), Some(3))?;
            self.store.ensure_conv(&direct_conv(&from), 0, &name)?;
            if cur != 3 {
                self.push_profile_to(from);
            }
            self.emit_contact(&from);
            self.emit_conv(&direct_conv(&from));
        }
        Ok(())
    }

    // ------------------------------------------------------------ messages

    pub fn new_chat_msg(&self, scope: &[u8], body: Body, reply_to: Option<[u8; 16]>, ttl_ms: Option<u64>) -> ChatMsg {
        self.new_chat_msg_meta(scope, body, reply_to, ttl_ms, MsgMeta::default())
    }

    pub fn new_chat_msg_meta(&self, scope: &[u8], body: Body, reply_to: Option<[u8; 16]>, ttl_ms: Option<u64>, meta: MsgMeta) -> ChatMsg {
        let mut m = ChatMsg {
            id: crate::crypto::random_bytes(),
            author: self.me,
            hlc: self.hlc.tick(),
            body,
            reply_to,
            ttl_ms,
            meta,
            sig: vec![],
        };
        m.sig = self.signer.sign(&m.signing_bytes(scope));
        m
    }

    pub(super) fn store_meta(&self, m: &ChatMsg) {
        let meta = &m.meta;
        if !meta.mentions.is_empty() || meta.forwarded_from.is_some() || meta.mention_all || !meta.buttons.is_empty() || meta.silent {
            let v = json!({
                "mentions": meta.mentions.iter().map(|p| p.to_base32()).collect::<Vec<_>>(),
                "forwarded_from": meta.forwarded_from, "mention_all": meta.mention_all,
                "buttons": meta.buttons, "silent": meta.silent,
            });
            let _ = self.store.set_message_meta(&m.id, &v);
        }
    }

    pub(super) fn check_mention(&self, conv: &str, m: &ChatMsg) {
        if m.author != self.me && (m.meta.mention_all || m.meta.mentions.contains(&self.me)) {
            // (a short preview: the notification list shows what was said)
            let text: String = m.body.preview().chars().take(140).collect();
            let mut ev = json!({"conv": conv, "id": hex::encode(m.id), "author": m.author.to_base32(), "text": text});
            if self.chat_locked(conv) {
                ev["locked"] = Value::Bool(true); // (see msg_json)
            }
            self.emit("mention", ev);
        }
    }

    pub(super) fn store_chat(&self, conv: &str, m: &ChatMsg, status: i64) -> Result<bool> {
        let expires = m.ttl_ms.map(|t| crate::util::hlc_to_ms(m.hlc).saturating_add(t.min(365 * 86_400_000)) as i64);
        let r = self.store_chat_inner(conv, m, status, expires);
        if let Ok(true) = r {
            // "sent from": the device that signed it
            let _ = self.store.set_message_device(&m.id, &crate::devices::signer_device(&m.author, &m.sig));
            self.store_meta(m);
            self.cache_sticker(&m.body);
            self.track_reminder(conv, m);
        }
        r
    }

    fn store_chat_inner(&self, conv: &str, m: &ChatMsg, status: i64, expires: Option<i64>) -> Result<bool> {
        self.store.insert_message(
            &m.id,
            conv,
            &m.author,
            m.hlc,
            m.body.kind(),
            &m.body.to_json(),
            status,
            m.reply_to.as_ref().map(|r| &r[..]),
            expires,
        )
    }

    pub async fn send_body(self: &Arc<Self>, conv: &str, body: Body, reply_to: Option<[u8; 16]>, ttl_ms: Option<u64>) -> Result<Value> {
        self.send_body_meta(conv, body, reply_to, ttl_ms, MsgMeta::default()).await
    }

    pub async fn send_body_meta(
        self: &Arc<Self>,
        conv: &str,
        body: Body,
        reply_to: Option<[u8; 16]>,
        ttl_ms: Option<u64>,
        meta: MsgMeta,
    ) -> Result<Value> {
        match parse_conv(conv)? {
            ConvRef::Saved => {
                self.store.ensure_conv(conv, 2, "Saved")?;
                let m = self.new_chat_msg_meta(b"s", body, reply_to, ttl_ms, meta);
                self.store_chat(conv, &m, 3)?;
                self.store.conv_touch(conv, crate::util::hlc_to_ms(m.hlc) as i64, &m.body.preview(), false)?;
                let sm = self.store.message(&m.id).ok_or_else(|| anyhow!("store"))?;
                let v = self.msg_json(&sm);
                self.emit("message", v.clone());
                self.emit_conv(conv);
                Ok(v)
            }
            ConvRef::Direct(p) => {
                anyhow::ensure!(!self.store.is_blocked(&p), crate::i18n::user_err("err.blocked"));
                anyhow::ensure!(!self.is_bot() || self.store.is_friend(&p), crate::i18n::user_err("err.bot_cannot_start"));
                // (a friend on an app from before multi-device gets it through the main
                // device: `deliver` → node/bridge.rs)
                let title = self.store.contact(&p).map(|c| c.alias.unwrap_or(c.name)).unwrap_or_default();
                self.store.ensure_conv(conv, 0, &title)?;
                let scope = dm_scope(&self.me, &p);
                let mut m = self.new_chat_msg_meta(&scope, body, reply_to, ttl_ms, meta);
                // older apps can't read the new kinds: they get the same message as plain text
                let old_peer = !self.peer_speaks_v2(&p);
                if old_peer && m.meta.silent {
                    m.meta.silent = false;
                    m.sig = self.signer.sign(&m.signing_bytes(&scope));
                }
                self.store_chat(conv, &m, 0)?;
                self.store.conv_touch(conv, crate::util::hlc_to_ms(m.hlc) as i64, &m.body.preview(), false)?;
                let wire = match super::tasks::fallback_body(&m.body).filter(|_| old_peer) {
                    Some(text) => {
                        let mut w = m.clone();
                        w.body = text;
                        w.sig = self.signer.sign(&w.signing_bytes(&scope));
                        w
                    }
                    None => m.clone(),
                };
                self.deliver(p, m.id, PeerMsg::Chat(wire), true).await;
                let sm = self.store.message(&m.id).ok_or_else(|| anyhow!("store"))?;
                let v = self.msg_json(&sm);
                self.emit("message", v.clone());
                self.emit_conv(conv);
                Ok(v)
            }
            ConvRef::Group(gid, channel) => self.send_group_body(gid, &channel, body, reply_to, ttl_ms, meta).await,
        }
    }

    pub async fn send_text(self: &Arc<Self>, conv: &str, text: &str, reply_to: Option<[u8; 16]>, ttl_ms: Option<u64>) -> Result<Value> {
        self.send_text_meta(conv, text, reply_to, ttl_ms, MsgMeta::default()).await
    }

    pub async fn send_text_meta(
        self: &Arc<Self>,
        conv: &str,
        text: &str,
        reply_to: Option<[u8; 16]>,
        ttl_ms: Option<u64>,
        meta: MsgMeta,
    ) -> Result<Value> {
        let text = text.trim_end();
        anyhow::ensure!(!text.trim().is_empty(), crate::i18n::user_err("err.empty_message"));
        anyhow::ensure!(text.len() <= 64 * 1024, crate::i18n::user_err("err.message_too_long"));
        self.send_body_meta(conv, Body::Text { text: text.to_string() }, reply_to, ttl_ms, meta).await
    }

    /// Forward a stored message to another conversation (text, sticker, poll, or a file we hold).
    pub async fn forward(self: &Arc<Self>, msg_id: &[u8; 16], to_conv: &str) -> Result<Value> {
        let m = self.store.message(msg_id).ok_or_else(|| crate::i18n::user_err("err.message_not_found"))?;
        let author = PeerId::from_str_any(&m.author)?;
        let from_name = if author == self.me {
            self.name()
        } else {
            self.store.contact(&author).map(|c| c.alias.unwrap_or(c.name)).unwrap_or_else(|| author.short_id_fmt())
        };
        let meta = MsgMeta { forwarded_from: Some(from_name), ..Default::default() };
        match m.kind.as_str() {
            "text" => {
                let t = m.body["text"].as_str().unwrap_or("").to_string();
                self.send_text_meta(to_conv, &t, None, None, meta).await
            }
            "sticker" => {
                let h = m.body["hash"].as_str().unwrap_or("");
                if !h.is_empty() {
                    return self.send_sticker(to_conv, h).await;
                }
                let b = Body::Sticker {
                    pack: m.body["pack"].as_str().unwrap_or("").into(),
                    id: m.body["id"].as_str().unwrap_or("").into(),
                    hash: [0; 32],
                    mime: String::new(),
                    data: vec![],
                    emoji: String::new(),
                    animated: false,
                };
                self.send_body_meta(to_conv, b, None, None, meta).await
            }
            "poll" => {
                let q = m.body["question"].as_str().unwrap_or("").to_string();
                let opts = m.body["options"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
                self.send_body_meta(to_conv, Body::Poll { question: q, options: opts }, None, None, meta).await
            }
            "file" => {
                let f = self.file_of_message(&m).ok_or_else(|| crate::i18n::user_err("err.file_not_found"))?;
                anyhow::ensure!(f.state == 2 || f.direction == 0, crate::i18n::user_err("err.file_not_found"));
                self.send_file_with(to_conv, &f.path, super::files::FileExtras::from_body(&m.body)).await
            }
            _ => bail!(crate::i18n::user_err("err.cannot_forward")),
        }
    }

    async fn accept_direct(self: &Arc<Self>, from: PeerId, msg: ChatMsg) -> Result<bool> {
        if msg.author != from || from == self.me || !self.verify_content(&msg.author, &msg.signing_bytes(&dm_scope(&self.me, &from)), &msg.sig) {
            bail!("bad chat signature");
        }
        if self.store.is_blocked(&from) {
            return Ok(false);
        }
        anyhow::ensure!(chat_msg_size_ok(&msg), "chat message too large");
        // anyone who can DM us (a stranger) is untrusted: our clock follows theirs only
        // within the allowed skew; the message keeps its own hlc for ordering
        self.hlc.observe(msg.hlc);
        let conv = direct_conv(&from);
        let contact = self.store.contact(&from);
        let title = contact.as_ref().map(|c| c.alias.clone().unwrap_or(c.name.clone())).unwrap_or_default();
        self.store.ensure_conv(&conv, 0, &title)?;
        let new = self.store_chat(&conv, &msg, 2)?;
        if new {
            self.check_mention(&conv, &msg);
            self.apply_pending_actions(&msg.id);
            // (conv_touch clamps a future date: a stranger can't pin the chat to the top)
            self.store.conv_touch(&conv, crate::util::hlc_to_ms(msg.hlc) as i64, &msg.body.preview(), true)?;
            self.emit_message(&msg.id);
            self.emit_conv(&conv);
            match &msg.body {
                // a File/Voice chat message doubles as an offer
                Body::File { file_id, name, size, hash, .. } => self.on_file_offer(from, *file_id, name.clone(), *size, *hash, conv.clone())?,
                Body::Voice { file_id, size, hash, .. } if *size > 0 => {
                    self.on_file_offer(from, *file_id, format!("voice-{}.ogg", &hex::encode(file_id)[..8]), *size, *hash, conv.clone())?
                }
                _ => {}
            }
        }
        Ok(new)
    }

    pub(super) async fn on_direct_chat(self: &Arc<Self>, pc: &Arc<PeerConn>, msg: ChatMsg) -> Result<()> {
        let id = msg.id;
        self.accept_direct(pc.account, msg).await?;
        pc.queue_ack(&[id]);
        Ok(())
    }

    pub(super) async fn on_direct_chat_offline(self: &Arc<Self>, from: PeerId, dev: PeerId, msg: ChatMsg) -> Result<()> {
        let id = msg.id;
        self.accept_direct(from, msg).await?;
        self.send_now_dev(&dev, PeerMsg::Ack { ids: vec![id] });
        Ok(())
    }

    pub async fn message_action(self: &Arc<Self>, conv: &str, target: [u8; 16], action: MsgAction) -> Result<()> {
        match parse_conv(conv)? {
            ConvRef::Direct(p) => {
                if let MsgAction::Edit { target, .. } = &action {
                    // only text can be edited (an edit replaces the body with text)
                    let ok = self.store.message(target).map(|m| m.conv == conv && m.kind == "text" && !m.deleted).unwrap_or(false);
                    anyhow::ensure!(ok, crate::i18n::user_err("err.cannot_edit"));
                }
                match &action {
                    // Telegram-style: in 1-1 chats either side may delete any message for both
                    MsgAction::Delete { target } => {
                        anyhow::ensure!(self.store.message(target).map(|m| m.conv == conv).unwrap_or(false), crate::i18n::user_err("err.message_not_found"));
                        if self.delete_message_everywhere(target, None)? {
                            self.emit("message_update", json!({"conv": conv, "id": hex::encode(target), "deleted": true}));
                        }
                    }
                    MsgAction::ClearHistory { upto_hlc, delete_chat } => self.clear_local_ex(conv, *upto_hlc, *delete_chat, true)?,
                    _ => self.apply_action(conv, &self.me.clone(), &action)?,
                }
                // older apps saw a plain-text copy: checklist/reminder updates stay on this side
                if super::tasks::action_is_v2(&action) && !self.peer_speaks_v2(&p) {
                    return Ok(());
                }
                let hlc = self.hlc.tick();
                let sig = self.signer.sign(&action_bytes(&target, &self.me, hlc, &action));
                let mid: [u8; 16] = crate::crypto::random_bytes();
                self.deliver(p, mid, PeerMsg::Action { id: target, author: self.me, hlc, action, sig }, true).await;
                Ok(())
            }
            ConvRef::Group(gid, channel) => {
                if let MsgAction::Edit { target, .. } = &action {
                    let ok = self.store.message(target).map(|m| m.kind == "text" && !m.deleted).unwrap_or(false);
                    anyhow::ensure!(ok, crate::i18n::user_err("err.cannot_edit"));
                }
                self.group_action(gid, &channel, target, action).await
            }
            ConvRef::Saved => self.apply_action(conv, &self.me.clone(), &action),
        }
    }

    /// Apply edit/delete/react locally (authorisation: only authors edit/delete own messages).
    pub(super) fn apply_action(&self, conv: &str, actor: &PeerId, action: &MsgAction) -> Result<()> {
        self.apply_action_at(conv, actor, action, self.hlc.tick())
    }

    /// Same, `hlc` = the signed time of the action (the sender's, the same on every
    /// receiver: last-writer-wins state like checklist ticks is decided by it).
    pub(super) fn apply_action_at(&self, conv: &str, actor: &PeerId, action: &MsgAction, hlc: u64) -> Result<()> {
        match action {
            MsgAction::Edit { target, text } => {
                if self.store.edit_message(target, actor, &json!({"text": text}))? {
                    self.emit("message_update", json!({"conv": conv, "id": hex::encode(target), "body": {"text": text}, "edited": true}));
                }
            }
            MsgAction::Delete { target } => {
                if self.delete_message_everywhere(target, Some(actor))? {
                    self.untrack_reminder(target);
                    self.emit("message_update", json!({"conv": conv, "id": hex::encode(target), "deleted": true}));
                }
            }
            MsgAction::React { target, emoji, on } => {
                let emoji: String = emoji.chars().take(8).collect();
                let r = self.store.react(target, actor, &emoji, *on)?;
                if !r.is_null() {
                    self.emit("message_update", json!({"conv": conv, "id": hex::encode(target), "reactions": r}));
                }
            }
            MsgAction::LiveLocation { target, lat, lon, accuracy_m, stop } => {
                if let Some(m) = self.store.message(target) {
                    if m.kind == "location" && m.author == actor.to_base32() {
                        let mut b = m.body.clone();
                        b["lat"] = json!(lat);
                        b["lon"] = json!(lon);
                        b["accuracy_m"] = json!(accuracy_m);
                        b["updated"] = json!(crate::util::now_ms());
                        if *stop {
                            b["live_until"] = json!(crate::util::now_ms());
                        }
                        if self.store.update_body(target, actor, &b)? {
                            self.emit("message_update", json!({"conv": conv, "id": hex::encode(target), "body": b}));
                        }
                    }
                }
            }
            MsgAction::Pin { target, on } => {
                if self.store.set_pinned(target, *on)? {
                    self.emit("message_update", json!({"conv": conv, "id": hex::encode(target), "pinned": on}));
                }
            }
            MsgAction::ClearHistory { .. } | MsgAction::PurgeAuthor { .. } => {}
            MsgAction::Callback { target, data } => {
                // only the author of the message (typically a bot) receives button presses
                if let Some(m) = self.store.message(target) {
                    if m.author == self.me.to_base32() {
                        self.emit("callback", json!({
                            "conv": conv, "msg_conv": m.conv, "msg_id": hex::encode(target),
                            "from": actor.to_base32(), "data": data.chars().take(64).collect::<String>(),
                        }));
                    }
                }
            }
            MsgAction::Vote { target, option } => {
                let r = self.store.vote(target, actor, *option)?;
                if !r.is_null() {
                    self.emit("message_update", json!({"conv": conv, "id": hex::encode(target), "reactions": r}));
                }
            }
            MsgAction::ChecklistToggle { .. } | MsgAction::ChecklistAdd { .. } | MsgAction::ReminderCancel { .. } | MsgAction::ReminderSeen { .. } => {
                self.apply_task_action(conv, actor, action, hlc)?
            }
        }
        Ok(())
    }

    pub(super) fn on_direct_action(
        &self,
        from: PeerId,
        target: [u8; 16],
        author: PeerId,
        hlc: u64,
        action: MsgAction,
        sig: Vec<u8>,
    ) -> Result<()> {
        if author != from || from == self.me || !self.verify_content(&author, &action_bytes(&target, &author, hlc, &action), &sig) {
            bail!("bad action signature");
        }
        anyhow::ensure!(action_size_ok(&action), "action too large");
        // dated far ahead: bogus (and it would win every last-writer-wins forever)
        if crate::util::hlc_to_ms(hlc) > now_ms() + 86_400_000 {
            return Ok(());
        }
        let conv = direct_conv(&from);
        match &action {
            MsgAction::ClearHistory { upto_hlc, delete_chat } => {
                // the other participant wiped the shared history (Telegram "also delete for X")
                // — up to when it did, never "everything forever" (u64::MAX would block all
                // future messages of the chat)
                let upto = (*upto_hlc).min(hlc).min(crate::util::clamp_hlc_now());
                self.clear_local_ex(&conv, upto, *delete_chat, true)?;
                return Ok(());
            }
            MsgAction::Callback { .. } => {
                // callbacks may target messages in any conversation we authored (groups too)
                self.apply_action(&conv, &from, &action)?;
                return Ok(());
            }
            MsgAction::Delete { target } => {
                match self.store.message(target) {
                    Some(m) if m.conv == conv => {
                        if self.delete_message_everywhere(target, None)? {
                            self.untrack_reminder(target);
                            self.emit("message_update", json!({"conv": conv, "id": hex::encode(target), "deleted": true}));
                        }
                    }
                    Some(_) => {}
                    // not here yet: delete it when it arrives (either side may delete in 1-1)
                    None => {
                        let _ = self.store.pending_action_put(target, &conv, &PeerId([0; 32]), &from, &rmp_serde::to_vec(&action)?);
                    }
                }
                return Ok(());
            }
            MsgAction::Edit { target, .. } if self.store.message(target).is_none() => {
                let _ = self.store.pending_action_put(target, &conv, &from, &from, &rmp_serde::to_vec(&action)?);
                return Ok(());
            }
            _ => {}
        }
        // make sure the target belongs to this conversation
        if self.store.message(&target).map(|m| m.conv == conv).unwrap_or(false) {
            self.apply_action_at(&conv, &from, &action, hlc)?;
        }
        Ok(())
    }

    /// Actions that arrived before their message (a moderator's / the other side's delete,
    /// the author's edit): authorised when they came, applied now that it is here.
    pub(super) fn apply_pending_actions(&self, id: &[u8; 16]) {
        for (conv, target_author, actor, action) in self.store.pending_actions_take(id) {
            let Some(m) = self.store.message(id) else { return };
            let any_author = target_author == [0u8; 32];
            if m.conv != conv || (!any_author && m.author != crate::store::b32_pub(&target_author)) {
                continue;
            }
            let (Ok(action), Ok(actor)) = (crate::proto::from_slice_capped::<MsgAction>(&action), <[u8; 32]>::try_from(actor.as_slice()).map(PeerId)) else { continue };
            let r = match &action {
                MsgAction::Delete { target } if any_author || m.author != actor.to_base32() => match self.delete_message_everywhere(target, None) {
                    Ok(true) => {
                        self.untrack_reminder(target);
                        self.emit("message_update", json!({"conv": conv, "id": hex::encode(target), "deleted": true}));
                        Ok(())
                    }
                    other => other.map(|_| ()),
                },
                MsgAction::Delete { .. } | MsgAction::Edit { .. } => self.apply_action(&conv, &actor, &action),
                _ => Ok(()),
            };
            if let Err(e) = r {
                tracing::debug!("pending action on {}: {e:#}", hex::encode(id));
            }
        }
    }

    /// User pressed an inline button: notify the message author (bot) directly.
    pub async fn press_button(self: &Arc<Self>, msg_id: [u8; 16], data: &str) -> Result<()> {
        let m = self.store.message(&msg_id).ok_or_else(|| crate::i18n::user_err("err.message_not_found"))?;
        let author = PeerId::from_str_any(&m.author)?;
        anyhow::ensure!(author != self.me, crate::i18n::user_err("err.own_button"));
        let action = MsgAction::Callback { target: msg_id, data: data.chars().take(64).collect() };
        let hlc = self.hlc.tick();
        let sig = self.signer.sign(&action_bytes(&msg_id, &self.me, hlc, &action));
        let mid: [u8; 16] = crate::crypto::random_bytes();
        self.deliver(author, mid, PeerMsg::Action { id: msg_id, author: self.me, hlc, action, sig }, false).await;
        Ok(())
    }

    /// Clear (or delete) a chat on this account's devices.
    pub(super) fn clear_local(&self, conv: &str, upto_hlc: u64, delete_chat: bool) -> Result<()> {
        self.clear_local_ex(conv, upto_hlc, delete_chat, false)
    }

    /// `for_everyone`: every participant clears it (1-1 "also for X", an admin's group
    /// clear) — my own uploads are forgotten too. Otherwise they stay offered: the others
    /// still see those messages and may not have downloaded them yet.
    pub(super) fn clear_local_ex(&self, conv: &str, upto_hlc: u64, delete_chat: bool, for_everyone: bool) -> Result<()> {
        let upto = upto_hlc.min(i64::MAX as u64) as i64;
        // Lumora's own downloaded copies go with the history (never a sender's original)
        let mut files = self.store.file_messages(conv, if delete_chat { i64::MAX } else { upto }, None)?;
        if !for_everyone {
            let me = self.me.to_base32();
            files.retain(|m| m.author != me);
        }
        self.forget_files_of(&files);
        self.store.clear_conv(conv, upto)?;
        self.prune_reminders();
        if delete_chat {
            self.store.delete_conv(conv)?;
            self.emit("conversation_removed", json!({"conv": conv}));
        } else {
            self.emit("history_cleared", json!({"conv": conv}));
            self.emit_conv(conv);
        }
        Ok(())
    }

    /// "Delete for me" (any message, incl. the other person's): removed on all of this account's devices (synced as a purge), and
    /// the copy Lumora downloaded goes with it. My own upload stays offered (the others
    /// still have the message).
    pub fn delete_for_me(&self, conv: &str, msg_id: &[u8; 16]) -> Result<()> {
        let m = self.store.message(msg_id).ok_or_else(|| crate::i18n::user_err("err.message_not_found"))?;
        anyhow::ensure!(m.conv == conv, crate::i18n::user_err("err.message_not_found"));
        if (m.kind == "file" || m.kind == "voice") && m.author != self.me.to_base32() {
            self.forget_files_of(std::slice::from_ref(&m));
        }
        self.untrack_reminder(msg_id);
        self.store.purge_message(msg_id)?;
        self.emit("message_update", json!({"conv": conv, "id": hex::encode(msg_id), "removed": true}));
        Ok(())
    }

    /// Clear a chat for me, or (1-1 only) for both sides; optionally remove the chat itself.
    pub async fn clear_history(self: &Arc<Self>, conv: &str, for_everyone: bool, delete_chat: bool) -> Result<()> {
        let upto = self.hlc.tick();
        match parse_conv(conv)? {
            ConvRef::Direct(_) if for_everyone => {
                self.message_action(conv, [0u8; 16], MsgAction::ClearHistory { upto_hlc: upto, delete_chat }).await?;
            }
            _ => self.clear_local(conv, upto, delete_chat)?,
        }
        Ok(())
    }

    pub fn mark_read(&self, conv: &str) -> Result<()> {
        self.store.conv_mark_read(conv)?;
        // groups: tell online members how far we've read ("seen by"), respecting privacy settings
        if let ConvRef::Group(gid, _) = parse_conv(conv)? {
            let receipts = self.store.kv_get("privacy.read_receipts").map(|v| v != b"0").unwrap_or(true) && !self.status_is("invisible");
            if receipts {
                if let Some(last) = self.store.messages(conv, None, 1)?.last() {
                    let members: Vec<PeerId> = self.groups.read().get(&gid).map(|g| g.members.keys().copied().collect()).unwrap_or_default();
                    // Reliable, to every device of each member (an offline one gets it when
                    // it's back): "seen by" is the same on all of their devices. Only the
                    // newest receipt per member waits in the outbox.
                    if let Some(me) = self.self_ref.lock().as_ref().and_then(|w| w.upgrade()) {
                        let (conv, upto) = (conv.to_string(), last.hlc as u64);
                        tokio::spawn(async move {
                            for m in members.into_iter().filter(|m| *m != me.me).take(256) {
                                let id: [u8; 16] = crate::crypto::random_bytes();
                                let prev = me.group_read_ids.lock().insert((conv.clone(), m), id);
                                if let Some(prev) = prev {
                                    for dev in me.delivery_targets(&m) {
                                        let _ = me.store.outbox_remove(&prev, &dev);
                                    }
                                }
                                me.deliver(m, id, PeerMsg::GroupRead { gid, conv: conv.clone(), upto_hlc: upto }, false).await;
                            }
                        });
                    }
                }
            }
        }
        if let ConvRef::Direct(p) = parse_conv(conv)? {
            let receipts = self.store.kv_get("privacy.read_receipts").map(|v| v != b"0").unwrap_or(true) && !self.status_is("invisible");
            if receipts {
                if let Some(last) = self.store.messages(conv, None, 1)?.last() {
                    let ids = self.store.mark_conv_read_upto(conv, &self.me, last.hlc)?;
                    let _ = ids;
                    // reliable (acked) so receipts survive connection swaps
                    if let Some(me) = self.self_ref.lock().as_ref().and_then(|w| w.upgrade()) {
                        let upto = last.hlc as u64;
                        tokio::spawn(async move {
                            let id: [u8; 16] = crate::crypto::random_bytes();
                            me.deliver(p, id, PeerMsg::Read { upto_hlc: upto }, false).await;
                        });
                    }
                }
            }
        }
        self.emit_conv(conv);
        Ok(())
    }

    pub fn typing(&self, conv: &str, on: bool) -> Result<()> {
        let enabled = self.store.kv_get("privacy.typing").map(|v| v != b"0").unwrap_or(true) && !self.status_is("invisible");
        if !enabled {
            return Ok(());
        }
        match parse_conv(conv)? {
            ConvRef::Saved => {}
            ConvRef::Direct(p) => {
                self.send_now(&p, PeerMsg::Typing { conv: String::new(), on });
            }
            ConvRef::Group(gid, _) => {
                let members: Vec<PeerId> = self.groups.read().get(&gid).map(|g| g.members.keys().copied().collect()).unwrap_or_default();
                for m in members {
                    if m != self.me {
                        self.send_now(&m, PeerMsg::GroupTyping { gid, on });
                    }
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod abuse_tests {
    //! A modified client may send any message, at any rate, from any number of fresh identities.
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

    fn status(n: &Node, p: &PeerId) -> i64 {
        n.store.contact(p).map(|c| c.status).unwrap_or(-1)
    }

    /// PoC: FriendRequest followed by an unsolicited FriendAccept made a stranger a friend
    /// (mailbox storage, push token, auto-download, peer relay) without the user's consent.
    #[tokio::test]
    async fn pending_requester_cannot_accept_itself() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let mallory = Identity::generate().peer_id();
        n.on_friend_request(mallory, "m".into(), String::new()).unwrap();
        assert_eq!(status(&n, &mallory), 2);
        n.on_friend_accept(mallory, "m".into()).unwrap();
        assert_eq!(status(&n, &mallory), 2, "stranger befriended itself");
        assert!(!n.store.is_friend(&mallory));
        // the real flow still works: an answer to *our* request
        let bob = Identity::generate().peer_id();
        n.store.upsert_contact(&bob, None, Some(1)).unwrap();
        n.on_friend_accept(bob, "b".into()).unwrap();
        assert!(n.store.is_friend(&bob));
        n.shutdown();
    }

    #[tokio::test]
    async fn pending_friend_requests_are_capped() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let first = Identity::generate().peer_id();
        n.on_friend_request(first, "a".into(), "x".repeat(100_000)).unwrap();
        for i in 1..MAX_PENDING_REQUESTS {
            let mut b = [0u8; 32];
            b[..8].copy_from_slice(&(i as u64).to_le_bytes());
            n.store.upsert_contact(&PeerId(b), Some("s"), Some(2)).unwrap();
        }
        let late = Identity::generate().peer_id();
        let e = n.on_friend_request(late, "z".into(), String::new()).unwrap_err();
        assert!(e.downcast_ref::<super::super::conn::NotNow>().is_some(), "a request beyond the cap must stay unacknowledged: {e:#}");
        assert_eq!(status(&n, &late), -1, "request beyond the cap was stored");
        // a repeat from someone already pending is fine (no new row)
        n.on_friend_request(first, "a2".into(), String::new()).unwrap();
        assert_eq!(status(&n, &first), 2);
        n.shutdown();
    }

    /// Fresh identities are free: strangers get a small budget each and share one more.
    #[tokio::test]
    async fn strangers_share_a_small_budget() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let m = |_: ()| PeerMsg::FriendRequest { name: String::new(), note: String::new() };
        let s1 = Identity::generate().peer_id();
        let ok1 = (0..100).filter(|_| n.inbound_allowed(&s1, &m(()))).count();
        assert!((15..=16).contains(&ok1), "one stranger: {ok1}");
        let swarm = (0..200).filter(|_| n.inbound_allowed(&Identity::generate().peer_id(), &m(()))).count();
        assert!(ok1 + swarm <= 52, "a swarm multiplied the budget: {ok1} + {swarm}");
        // friends (and people we asked) keep the generous budget
        let f = Identity::generate().peer_id();
        n.store.upsert_contact(&f, None, Some(3)).unwrap();
        assert_eq!((0..150).filter(|_| n.inbound_allowed(&f, &m(()))).count(), 150);
        // non-content messages are never throttled
        assert!(n.inbound_allowed(&s1, &PeerMsg::Ping { t: 0 }));
        n.shutdown();
    }

    #[test]
    fn oversized_messages_are_rejected() {
        let a = PeerId([9; 32]);
        let msg = |body: Body| ChatMsg { id: [1; 16], author: a, hlc: 1, body, reply_to: None, ttl_ms: None, meta: MsgMeta::default(), sig: vec![0; 64] };
        assert!(chat_msg_size_ok(&msg(Body::Text { text: "a".repeat(64 * 1024) })));
        assert!(!chat_msg_size_ok(&msg(Body::Text { text: "a".repeat(3 * 1024 * 1024) })));
        let sticker = |n: usize| Body::Sticker { pack: "p".into(), id: "i".into(), hash: [0; 32], mime: "image/webp".into(), data: vec![0; n], emoji: String::new(), animated: true };
        assert!(chat_msg_size_ok(&msg(sticker(900 * 1024))), "inline sticker images are cached separately");
        assert!(!chat_msg_size_ok(&msg(sticker(2 * 1024 * 1024))));
        let mut m = msg(Body::Text { text: "hi".into() });
        m.meta.forwarded_from = Some("x".repeat(1024 * 1024));
        assert!(!chat_msg_size_ok(&m), "meta counts too");
        assert!(action_size_ok(&MsgAction::Edit { target: [0; 16], text: "ok".into() }));
        assert!(!action_size_ok(&MsgAction::Edit { target: [0; 16], text: "a".repeat(1024 * 1024) }));
    }

    /// Profile pictures from people we never accepted are not stored (disk per free identity).
    #[tokio::test]
    async fn stranger_profiles_store_no_pictures() {
        let tmp = tempfile::tempdir().unwrap();
        let n = node(tmp.path()).await;
        let pic = vec![1u8; 4096];
        let s = Identity::generate().peer_id();
        n.store.upsert_contact(&s, Some("s"), Some(0)).unwrap(); // e.g. after a stranger's offer
        n.on_profile_v2(s, "s".into(), String::new(), String::new(), pic.clone(), pic.clone(), None, String::new()).unwrap();
        assert!(!n.store.contact(&s).unwrap().has_avatar && n.store.contact_cover(&s).is_none());
        let r = Identity::generate().peer_id();
        n.on_friend_request(r, "r".into(), String::new()).unwrap();
        n.on_profile_v2(r, "r".into(), String::new(), String::new(), pic.clone(), pic.clone(), None, String::new()).unwrap();
        assert!(n.store.contact(&r).unwrap().has_avatar && n.store.contact_cover(&r).is_none(), "requester: avatar only");
        let f = Identity::generate().peer_id();
        n.store.upsert_contact(&f, Some("f"), Some(3)).unwrap();
        n.on_profile_v2(f, "f".into(), String::new(), String::new(), pic.clone(), pic.clone(), None, String::new()).unwrap();
        assert!(n.store.contact(&f).unwrap().has_avatar && n.store.contact_cover(&f).is_some());
        n.shutdown();
    }
}
