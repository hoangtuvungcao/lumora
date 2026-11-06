//! Profiles (avatar, bio, presence), group invite links and scheduled messages.

use super::*;
use data_encoding::BASE32_NOPAD;

pub const MAX_AVATAR: usize = 96 * 1024;
pub const MAX_COVER: usize = 320 * 1024;

#[derive(Serialize, Deserialize, Clone)]
struct Invite {
    gid: Gid,
    inviter: PeerId,
    expires: u64,
    name: String,
    #[serde(with = "serde_bytes")]
    sig: Vec<u8>,
}

fn invite_bytes(gid: &Gid, inviter: &PeerId, expires: u64) -> Vec<u8> {
    let mut v = b"lumora-invite-v1".to_vec();
    v.extend_from_slice(gid);
    v.extend_from_slice(&inviter.0);
    v.extend_from_slice(&expires.to_le_bytes());
    v
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Scheduled {
    pub id: String,
    pub conv: String,
    pub text: String,
    pub at: u64,
    /// "" = waiting, "failed" = could not be sent (kept so the user sees it and can retry
    /// or remove it)
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub state: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub error: String,
}

/// Serialises read-modify-write of the `scheduled` list (API calls and the scheduler).
static SCHEDULED_LOCK: parking_lot::Mutex<()> = parking_lot::const_mutex(());

impl Node {
    // ------------------------------------------------------------ profile

    pub fn profile(&self) -> Value {
        let g = |k: &str| self.store.kv_get(k).and_then(|v| String::from_utf8(v).ok()).unwrap_or_default();
        let avatar = self.store.kv_get("profile.avatar").filter(|a| !a.is_empty()).map(|a| data_encoding::BASE64.encode(&a));
        let st = g("profile.status");
        let status = if st.is_empty() { "online".to_string() } else { st };
        let cover = self.store.kv_get("profile.cover").filter(|a| !a.is_empty()).map(|a| data_encoding::BASE64.encode(&a));
        json!({"name": self.name(), "bio": g("profile.bio"), "status": status, "avatar": avatar, "cover": cover,
               "username": self.username(), "handle": self.handle()})
    }

    fn profile_msg(&self) -> PeerMsg {
        let g = |k: &str| self.store.kv_get(k).and_then(|v| String::from_utf8(v).ok()).unwrap_or_default();
        let status = g("profile.status");
        PeerMsg::ProfileV2 {
            name: self.name(),
            username: self.username().unwrap_or_default(),
            bot: self.store.kv_get_json::<crate::proto::BotInfo>("bot.info").map(|mut b| {
                b.owner = self.bot_owner_proof();
                b
            }),
            bio: g("profile.bio"),
            // invisible users appear offline to others
            status: if status == "invisible" { "offline".into() } else { status },
            avatar: self.store.kv_get("profile.avatar").unwrap_or_default(),
            cover: self.store.kv_get("profile.cover").unwrap_or_default(),
        }
    }

    pub fn set_cover(&self, cover_b64: &str) -> Result<()> {
        let bytes = if cover_b64.is_empty() { vec![] } else { data_encoding::BASE64.decode(cover_b64.as_bytes())? };
        anyhow::ensure!(bytes.len() <= MAX_COVER, crate::i18n::user_err("err.image_too_large").with("max", "320 KB"));
        self.store.kv_set("profile.cover", &bytes)?;
        self.set_profile(None, None, None, None)
    }

    pub fn set_profile(&self, name: Option<&str>, bio: Option<&str>, status: Option<&str>, avatar_b64: Option<&str>) -> Result<()> {
        if let Some(n) = name {
            self.set_name(n)?;
        }
        if let Some(b) = bio {
            self.store.kv_set("profile.bio", b.chars().take(160).collect::<String>().as_bytes())?;
        }
        if let Some(s) = status {
            anyhow::ensure!(["online", "away", "dnd", "invisible"].contains(&s), "status must be online|away|dnd|invisible");
            self.store.kv_set("profile.status", s.as_bytes())?;
        }
        if let Some(a) = avatar_b64 {
            let bytes = if a.is_empty() { vec![] } else { data_encoding::BASE64.decode(a.as_bytes())? };
            anyhow::ensure!(bytes.len() <= MAX_AVATAR, crate::i18n::user_err("err.image_too_large").with("max", "96 KB"));
            self.store.kv_set("profile.avatar", &bytes)?;
        }
        // reliable + idempotent: one outbox slot per friend, newest profile overwrites older ones
        if let Some(me) = self.self_ref.lock().as_ref().and_then(|w| w.upgrade()) {
            let m = self.profile_msg();
            tokio::spawn(async move {
                for f in me.store.friend_ids() {
                    // unique per update: receivers dedupe by id, so a fixed slot id would drop later updates
                    let id: [u8; 16] = crate::crypto::random_bytes();
                    if me.is_online(&f) {
                        me.deliver(f, id, m.clone(), false).await;
                    } else {
                        // offline friends get the latest profile on next connect
                        let _ = me.store.outbox_add(&id, &f, &rmp_serde::to_vec(&PeerMsg::Wrapped { id, inner: Box::new(m.clone()) }).unwrap_or_default());
                    }
                }
            });
        }
        Ok(())
    }

    /// Push our profile to one (new) friend, reliably (one outbox slot per friend).
    pub(super) fn push_profile_to(&self, peer: PeerId) {
        if let Some(me) = self.self_ref.lock().as_ref().and_then(|w| w.upgrade()) {
            let m = self.profile_msg();
            tokio::spawn(async move {
                let id: [u8; 16] = crate::crypto::random_bytes();
                me.deliver(peer, id, m, false).await;
            });
        }
    }

    pub(super) fn send_profile(&self, pc: &Arc<PeerConn>) {
        if self.store.is_friend(&pc.account) {
            let _ = pc.ctl.try_send(self.profile_msg());
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn on_profile_v2(
        &self,
        from: PeerId,
        name: String,
        bio: String,
        status: String,
        avatar: Vec<u8>,
        cover: Vec<u8>,
        bot: Option<crate::proto::BotInfo>,
        username: String,
    ) -> Result<()> {
        if self.store.contact(&from).is_some() {
            let u = if crate::net::nostr::valid_username(&username) { username } else { String::new() };
            self.store.set_contact_field(&from, "username", rusqlite::types::Value::Text(u))?;
        }
        if self.store.contact(&from).is_some() {
            let v = bot
                .map(|b| {
                    let owner = b.owner.as_ref().and_then(|o| {
                        let op = PeerId::from_str_any(o["owner"].as_str()?).ok()?;
                        let ok = crate::devices::verify_by(
                            &op,
                            &super::botfather::ownership_bytes(&from, o["username"].as_str()?, o["created"].as_u64()?),
                            &hex::decode(o["sig"].as_str()?).ok()?,
                        )
                        .is_some();
                        ok.then(|| op.to_base32())
                    });
                    json!({
                        "owner": owner,
                        "about": b.about.chars().take(300).collect::<String>(),
                        "commands": b.commands.into_iter().take(50)
                            .map(|(c, d)| json!({"command": c.chars().take(32).collect::<String>(), "description": d.chars().take(120).collect::<String>()}))
                            .collect::<Vec<_>>(),
                        "group_commands": b.group_commands.into_iter().take(50)
                            .map(|(c, d)| json!({"command": c.chars().take(32).collect::<String>(), "description": d.chars().take(120).collect::<String>()}))
                            .collect::<Vec<_>>(),
                    })
                    .to_string()
                })
                .unwrap_or_default();
            self.store.set_contact_field(&from, "bot", rusqlite::types::Value::Text(v))?;
        }
        // pictures cost up to 416 KB of disk per identity: never for strangers / blocked
        // (status 0/4, which anyone can reach by dialing us); a pending requester (2) gets
        // its avatar shown, the cover only once accepted
        let rel = self.store.contact(&from).map(|c| c.status).unwrap_or(0);
        let (avatar_ok, cover_ok) = (matches!(rel, 1..=3), matches!(rel, 1 | 3));
        if cover_ok && cover.len() <= MAX_COVER {
            self.store.set_contact_field(
                &from,
                "cover",
                if cover.is_empty() { rusqlite::types::Value::Null } else { rusqlite::types::Value::Blob(cover) },
            )?;
        }
        if self.store.contact(&from).is_none() {
            return Ok(());
        }
        let name: String = name.chars().take(48).collect();
        if !name.is_empty() {
            self.store.upsert_contact(&from, Some(&name), None)?;
        }
        self.store.set_contact_field(&from, "bio", rusqlite::types::Value::Text(bio.chars().take(160).collect()))?;
        self.store.set_contact_field(&from, "presence", rusqlite::types::Value::Text(status.chars().take(16).collect()))?;
        if avatar_ok && avatar.len() <= MAX_AVATAR {
            self.store.set_contact_field(
                &from,
                "avatar",
                if avatar.is_empty() { rusqlite::types::Value::Null } else { rusqlite::types::Value::Blob(avatar) },
            )?;
        }
        self.emit_contact(&from);
        Ok(())
    }

    pub fn status_is(&self, s: &str) -> bool {
        self.store.kv_get("profile.status").map(|v| v == s.as_bytes()).unwrap_or(false)
    }

    // ------------------------------------------------------------ @usernames

    pub fn username(&self) -> Option<String> {
        self.store.kv_get("profile.username").and_then(|v| String::from_utf8(v).ok()).filter(|s| !s.is_empty())
    }

    pub fn handle(&self) -> Option<String> {
        let u = self.username()?;
        let owner = self.bot_owner_proof().and_then(|o| o["owner"].as_str().and_then(|p| PeerId::from_str_any(p).ok()));
        Some(match owner {
            Some(o) => format!("@{}·{}", u, super::botfather::bot_tag(&o, &u)),
            None => format!("@{}·{}", u, crate::net::nostr::handle_tag(&self.me)),
        })
    }

    pub fn set_username(&self, name: &str) -> Result<Value> {
        let name = name.trim().trim_start_matches('@').to_lowercase();
        let old = self.username();
        if name.is_empty() {
            self.store.kv_set("profile.username", b"")?;
        } else {
            anyhow::ensure!(crate::net::nostr::valid_username(&name), crate::i18n::user_err("err.username_invalid"));
            self.store.kv_set("profile.username", name.as_bytes())?;
        }
        // the username claim is signed by the account key: published by the primary
        let pool = if self.is_primary() { self.net.nostr.read().clone() } else { None };
        if let Some(pool) = pool {
            if !name.is_empty() {
                let id = self.id.clone();
                let n2 = name.clone();
                let old2 = old.clone();
                // PoW takes a few ms–100 ms: keep it off the async runtime
                let proof = self.bot_owner_proof();
                tokio::task::spawn_blocking(move || pool.publish_username_owned(&id, &n2, old2.as_deref(), proof.as_ref()));
            }
        }
        self.set_profile(None, None, None, None)?;
        Ok(json!({"username": if name.is_empty() { Value::Null } else { json!(name) }, "handle": self.handle()}))
    }

    /// `@name·tag` → exact owner; `@name` → all verified candidates (with tags).
    pub async fn resolve_username(&self, handle: &str) -> Result<Vec<Value>> {
        let h = handle.trim().trim_start_matches('@').to_lowercase();
        let (name, tag) = match h.split_once(['·', '.', '#']) {
            Some((n, t)) => (n.to_string(), Some(t.to_string())),
            None => (h.clone(), None),
        };
        anyhow::ensure!(crate::net::nostr::valid_username(&name), crate::i18n::user_err("err.username_invalid"));
        let mut out = vec![];
        // contacts first (offline)
        for c in self.store.contacts()? {
            if let Ok(p) = PeerId::from_str_any(&c.peer) {
                let t = crate::net::nostr::handle_tag(&p);
                if c.username.as_deref() == Some(name.as_str()) && tag.as_deref().map(|x| x == t).unwrap_or(true) {
                    out.push(json!({"peer": c.peer, "handle": format!("@{name}·{t}"), "name": c.name, "contact": true}));
                }
            }
        }
        let pool = self.net.nostr.read().clone();
        if let Some(pool) = pool {
            for (p, t) in pool.lookup_username(&name).await {
                if tag.as_deref().map(|x| x == t).unwrap_or(true) && !out.iter().any(|o| o["peer"].as_str() == Some(&p.to_base32())) {
                    out.push(json!({"peer": p.to_base32(), "handle": format!("@{name}·{t}"), "contact": false}));
                }
            }
        }
        Ok(out)
    }

    // ------------------------------------------------------------ bots

    /// Turn this identity into a bot: command list shown by clients, optional auto-accept.
    pub fn set_bot(&self, commands: Vec<(String, String)>, group_commands: Vec<(String, String)>, about: &str, auto_accept: bool) -> Result<()> {
        let info = crate::proto::BotInfo { commands, group_commands, about: about.chars().take(300).collect(), owner: None };
        self.store.kv_set_json("bot.info", &info)?;
        self.store.kv_set("bot.auto_accept", if auto_accept { b"1" } else { b"0" })?;
        self.set_profile(None, None, None, None)
    }

    pub fn is_bot(&self) -> bool {
        self.store.kv_get_json::<crate::proto::BotInfo>("bot.info").is_some()
    }

    // ------------------------------------------------------------ invite links

    pub fn create_invite(&self, gid: Gid, hours: u64) -> Result<String> {
        let g = self.groups.read().get(&gid).cloned().ok_or_else(|| crate::i18n::user_err("err.group_not_found"))?;
        anyhow::ensure!(g.is_member(&self.me), crate::i18n::user_err("err.not_member"));
        if g.kind == 1 {
            anyhow::ensure!(g.role(&self.me).map(|r| r >= crate::group::Role::Admin).unwrap_or(false), crate::i18n::user_err("err.admin_only_add"));
        }
        let expires = now_ms() + hours.clamp(1, 24 * 30) * 3_600_000;
        let sig = self.signer.sign(&invite_bytes(&gid, &self.me, expires));
        let inv = Invite { gid, inviter: self.me, expires, name: g.name.clone(), sig };
        Ok(format!("lumora://join/{}", BASE32_NOPAD.encode(&rmp_serde::to_vec(&inv)?).to_lowercase()))
    }

    pub fn inspect_invite(&self, link: &str) -> Result<Value> {
        let inv = parse_invite(link)?;
        Ok(json!({
            "gid": hex::encode(inv.gid), "name": inv.name, "inviter": inv.inviter.to_base32(),
            "expires": inv.expires, "valid": inv.expires > now_ms(),
            "already_member": self.groups.read().get(&inv.gid).map(|g| g.is_member(&self.me)).unwrap_or(false),
            "blocked": self.group_blocked(&inv.gid),
        }))
    }

    pub async fn join_invite(self: &Arc<Self>, link: &str) -> Result<Value> {
        let inv = parse_invite(link)?;
        anyhow::ensure!(inv.expires > now_ms(), crate::i18n::user_err("err.invite_expired"));
        // a group I reported and blocked (on any of my devices): unblock it first
        anyhow::ensure!(!self.group_blocked(&inv.gid), crate::i18n::user_err("err.group_blocked"));
        self.store.kv_set(&format!("join.pending.{}", hex::encode(inv.gid)), b"1")?;
        self.send_to(inv.inviter, PeerMsg::JoinRequest { gid: inv.gid, expires: inv.expires, sig: inv.sig }).await?;
        Ok(json!({"gid": hex::encode(inv.gid), "name": inv.name, "pending": true}))
    }

    pub(super) async fn on_join_request(self: &Arc<Self>, from: PeerId, gid: Gid, expires: u64, sig: Vec<u8>) -> Result<()> {
        anyhow::ensure!(expires > now_ms(), "expired invite");
        anyhow::ensure!(self.verify_content(&self.me, &invite_bytes(&gid, &self.me, expires), &sig), "forged invite");
        let (member, banned) = self.groups.read().get(&gid).map(|g| (g.is_member(&from), g.banned.contains(&from))).unwrap_or((false, false));
        // (a leaked link must not let a flood of fresh identities join without bound)
        if !member && !banned && !self.store.is_blocked(&from) && self.join_allowed(&gid) {
            self.group_add(gid, from).await?;
        }
        Ok(())
    }

    // ------------------------------------------------------------ scheduled messages

    pub fn scheduled(&self) -> Vec<Scheduled> {
        self.store.kv_get_json::<Vec<Scheduled>>("scheduled").unwrap_or_default()
    }

    pub fn schedule_text(&self, conv: &str, text: &str, at: u64) -> Result<Value> {
        parse_conv(conv)?;
        anyhow::ensure!(!text.trim().is_empty(), crate::i18n::user_err("err.empty_message"));
        let _g = SCHEDULED_LOCK.lock();
        let mut list = self.scheduled();
        anyhow::ensure!(list.len() < 500, crate::i18n::user_err("err.too_many_scheduled").with("max", 500));
        let item = Scheduled {
            id: hex::encode(crate::crypto::random_bytes::<8>()),
            conv: conv.into(),
            text: text.into(),
            at,
            state: String::new(),
            error: String::new(),
        };
        list.push(item.clone());
        self.store.kv_set_json("scheduled", &list)?;
        Ok(serde_json::to_value(item)?)
    }

    pub fn cancel_scheduled(&self, id: &str) -> Result<()> {
        let _g = SCHEDULED_LOCK.lock();
        let mut list = self.scheduled();
        list.retain(|s| s.id != id);
        self.store.kv_set_json("scheduled", &list)
    }

    /// Scheduled messages that are due (taken out of the list).
    fn take_due_scheduled(&self, now: u64) -> Vec<Scheduled> {
        let _g = SCHEDULED_LOCK.lock();
        let list = self.scheduled();
        if !list.iter().any(|s| s.at <= now && s.state.is_empty()) {
            return vec![];
        }
        let (due, rest): (Vec<_>, Vec<_>) = list.into_iter().partition(|s| s.at <= now && s.state.is_empty());
        let _ = self.store.kv_set_json("scheduled", &rest);
        due
    }

    /// A scheduled message could not be sent: keep it (marked failed) and tell the user —
    /// an event for the app and a line in the chat itself.
    pub(super) fn scheduled_failed(&self, mut s: Scheduled, err: &anyhow::Error) {
        let reason = crate::i18n::find_user_err(err).map(|u| u.message()).unwrap_or_else(|| format!("{err:#}"));
        tracing::warn!("scheduled message failed: {err:#}");
        s.state = "failed".into();
        s.error = reason.chars().take(200).collect();
        {
            let _g = SCHEDULED_LOCK.lock();
            let mut list = self.scheduled();
            list.retain(|x| x.id != s.id);
            list.push(s.clone());
            let _ = self.store.kv_set_json("scheduled", &list);
        }
        let preview: String = s.text.chars().take(80).collect();
        self.emit("scheduled_failed", json!({"id": s.id, "conv": s.conv, "text": s.text, "at": s.at, "error": s.error}));
        self.local_notice(&s.conv, "sys.scheduled_failed", &[("text", &preview), ("error", &s.error)]);
    }

    /// A line in a chat shown only on this device (rendered in each UI's language).
    pub(super) fn local_notice(&self, conv: &str, code: &str, args: &[(&str, &str)]) {
        if !self.store.conversations().map(|l| l.iter().any(|c| c.id == conv)).unwrap_or(false) {
            return;
        }
        let id: [u8; 16] = crate::crypto::random_bytes();
        let hlc = self.hlc.tick();
        let argv: serde_json::Map<String, Value> = args.iter().map(|(k, v)| (k.to_string(), Value::String(v.to_string()))).collect();
        let body = json!({"text": crate::i18n::trf_en(code, args), "code": code, "args": argv, "local": true});
        if self.store.insert_message(&id, conv, &self.me, hlc, "system", &body, 2, None, None).unwrap_or(false) {
            let _ = self.store.conv_touch(conv, crate::util::hlc_to_ms(hlc) as i64, &crate::i18n::trf(code, args), false);
            if let Some(m) = self.store.message(&id) {
                self.emit("message", self.msg_json(&m));
            }
            self.emit_conv(conv);
        }
    }

    /// Files of messages housekeeping removed (expired, outside the retention window,
    /// session-only chats): forget Lumora's downloaded copies like delete-for-everyone.
    pub(super) fn file_gc(&self) {
        loop {
            let batch = self.store.file_gc_take(200);
            if batch.is_empty() {
                return;
            }
            let msgs: Vec<crate::store::StoredMessage> = batch
                .into_iter()
                .map(|(conv, author, body)| crate::store::StoredMessage {
                    id: String::new(),
                    conv,
                    author: crate::store::b32_pub(&author),
                    hlc: 0,
                    ts: 0,
                    kind: "file".into(),
                    body: serde_json::from_str(&body).unwrap_or(Value::Null),
                    status: 0,
                    edited: false,
                    deleted: false,
                    reply_to: None,
                    reactions: Value::Null,
                    expires: None,
                    pinned: false,
                    meta: Value::Null,
                })
                .collect();
            self.forget_files_of(&msgs);
        }
    }

    pub(super) fn spawn_scheduler(self: Arc<Self>) {
        self.clone().spawn_reminders();
        // files of session-only chats wiped at startup
        self.file_gc();
        tokio::spawn(async move {
            let mut tick: u64 = 0;
            loop {
                tokio::time::sleep(Duration::from_secs(5)).await;
                tick += 1;
                if tick.is_multiple_of(6) {
                    // every 30 s: downloaded copies of expired messages, missing group keys,
                    // overdue key rotations
                    self.file_gc();
                    self.group_upkeep();
                }
                let now = now_ms();
                // expire timed mutes
                if let Ok(convs) = self.store.conversations() {
                    for c in convs.iter().filter(|c| c.muted) {
                        let until = self.store.kv_get(&format!("mute_until.{}", c.id)).and_then(|v| v.try_into().ok()).map(u64::from_le_bytes);
                        if let Some(u) = until {
                            if u != u64::MAX && u <= now {
                                let _ = self.store.conv_set_flag(&c.id, "muted", false);
                                self.emit_conv(&c.id);
                            }
                        }
                    }
                }
                for s in self.take_due_scheduled(now) {
                    if let Err(e) = self.send_text(&s.conv, &s.text, None, None).await {
                        self.scheduled_failed(s, &e);
                    }
                }
            }
        });
    }
}

/// Fuzz-harness access to [`parse_invite`] (feature `fuzzing`, never shipped).
#[cfg(feature = "fuzzing")]
impl Node {
    #[doc(hidden)]
    pub fn fuzz_parse_invite(link: &str) -> bool {
        parse_invite(link).is_ok()
    }
}

fn parse_invite(link: &str) -> Result<Invite> {
    let tok = link.trim().trim_start_matches("lumora://join/").trim_start_matches("https://lumora.app/join/");
    let bad = || crate::i18n::user_err("err.invite_invalid");
    let raw = BASE32_NOPAD.decode(tok.to_uppercase().as_bytes()).map_err(|e| bad().detail(e))?;
    let inv: Invite = crate::proto::from_slice_capped(&raw).map_err(|e| bad().detail(e))?;
    anyhow::ensure!(
        crate::devices::verify_by(&inv.inviter, &invite_bytes(&inv.gid, &inv.inviter, inv.expires), &inv.sig).is_some(),
        bad().detail("signature mismatch")
    );
    Ok(inv)
}
