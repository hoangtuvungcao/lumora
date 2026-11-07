//! HTTP Bot API (the familiar Bot API style) served by the Lumora Bot Runner: `lumorad --http-api ADDR`.
//!
//! `POST|GET /bot<TOKEN>/<method>` with parameters in the query string, a urlencoded or
//! multipart form, or a JSON body; answers `{"ok": true, "result": …}` or
//! `{"ok": false, "error_code": N, "description": "…"}`. Only the token
//! of the bot this runner is running is accepted (compared in constant time).
//!
//! Everything goes through the same JSON API the stdio protocol uses (`lumora_core::api`);
//! incoming messages, edits and button presses become `Update` objects, handed out by
//! `getUpdates` (long polling) or POSTed to a webhook (`setWebhook`), never both.
//! Docs (methods, id formats, notes / limitations): docs/src/bots/guides.md#http-api.

pub mod convert;
pub mod format;
pub mod http;
pub mod updates;

#[cfg(test)]
mod tests;

use convert::{buttons_of, chat_of, conv_of, message_of, user_of};
use http::Params;
use lumora_core::node::Node;
use serde_json::{json, Value};
use std::collections::{HashSet, VecDeque};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use updates::{allowed, now_ms, Store, Webhook};

/// Largest request body (50 MB upload limit for bots).
const MAX_BODY: usize = 50 << 20;
/// Largest file served by `/file/bot<token>/…`.
const MAX_DOWNLOAD: u64 = 200 << 20;
/// Webhook retry back-off cap.
const MAX_BACKOFF_S: u64 = 60;

pub struct Config {
    pub addr: SocketAddr,
    /// the running bot's token (`lumora_bot_…`)
    pub token: String,
    /// where pending updates and the webhook settings are kept (`None` = memory only)
    pub state_file: Option<PathBuf>,
    /// where uploaded files are kept until sent (receivers fetch them from here)
    pub upload_dir: PathBuf,
}

/// A Bot API error (`ok: false`, `error_code`, `description`).
#[derive(Debug)]
pub struct ApiError {
    pub code: u16,
    pub description: String,
}

impl ApiError {
    fn bad(d: impl Into<String>) -> Self {
        let d = d.into();
        ApiError { code: 400, description: if d.starts_with("Bad Request") { d } else { format!("Bad Request: {d}") } }
    }
    fn conflict(d: &str) -> Self {
        ApiError { code: 409, description: format!("Conflict: {d}") }
    }
}

impl From<String> for ApiError {
    fn from(s: String) -> Self {
        ApiError::bad(s)
    }
}
impl From<&str> for ApiError {
    fn from(s: &str) -> Self {
        ApiError::bad(s)
    }
}

type R = Result<Value, ApiError>;

pub struct BotApi {
    pub node: Arc<Node>,
    token: String,
    pub store: Store,
    upload_dir: PathBuf,
    /// message ids already turned into updates (an event can repeat)
    seen: Mutex<(HashSet<String>, VecDeque<String>)>,
    /// setWebhook / deleteWebhook: ends a webhook back-off early
    webhook_changed: tokio::sync::Notify,
}

/// Start the API on `cfg.addr`; returns it and the bound address (port 0 = any).
pub async fn start(node: Arc<Node>, cfg: Config) -> anyhow::Result<(Arc<BotApi>, SocketAddr)> {
    let listener = tokio::net::TcpListener::bind(cfg.addr).await.map_err(|e| anyhow::anyhow!("HTTP Bot API: can't listen on {}: {e}", cfg.addr))?;
    let addr = listener.local_addr()?;
    let api = Arc::new(BotApi {
        node: node.clone(),
        token: cfg.token.trim().to_string(),
        store: Store::open(cfg.state_file),
        upload_dir: cfg.upload_dir,
        seen: Mutex::new((HashSet::new(), VecDeque::new())),
        webhook_changed: tokio::sync::Notify::new(),
    });
    clean_uploads(&api.upload_dir);
    // subscribe now: nothing that arrives after start() returns is missed
    let mut ev = node.subscribe();
    let a = api.clone();
    tokio::spawn(async move {
        loop {
            match ev.recv().await {
                Ok(e) => a.on_event(&e),
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => tracing::warn!("bot api: {n} events missed (too busy)"),
                Err(_) => break,
            }
        }
    });
    let a = api.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_millis(500)).await;
            let s = a.clone();
            let _ = tokio::task::spawn_blocking(move || s.store.flush()).await;
        }
    });
    // the webhook loop must outlive any bug in one delivery: restarted if it ever panics
    let a = api.clone();
    tokio::spawn(async move {
        loop {
            match tokio::spawn(webhook_loop(a.clone())).await {
                Err(e) if e.is_panic() => {
                    tracing::error!("bot api: webhook loop crashed, restarting: {e}");
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
                _ => break,
            }
        }
    });
    let app = axum::Router::new().fallback(serve).with_state(api.clone());
    tokio::spawn(async move {
        if let Err(e) = axum::serve(listener, app).await {
            tracing::error!("HTTP Bot API stopped: {e}");
        }
    });
    Ok((api, addr))
}

/// Uploads older than 30 days are gone from the receivers' view anyway.
fn clean_uploads(dir: &std::path::Path) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    let old = std::time::SystemTime::now() - Duration::from_secs(30 * 86400);
    for e in rd.flatten() {
        if e.metadata().and_then(|m| m.modified()).map(|t| t < old).unwrap_or(false) {
            let _ = std::fs::remove_dir_all(e.path());
        }
    }
}

/// Constant-time comparison (time depends only on the lengths).
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    let mut d = (a.len() ^ b.len()) as u64;
    for i in 0..a.len().max(b.len()) {
        let x = a.get(i).copied().unwrap_or(0);
        let y = b.get(i).copied().unwrap_or(0);
        d |= (x ^ y) as u64;
    }
    std::hint::black_box(d) == 0
}

fn reply(status: u16, body: Value) -> axum::response::Response {
    axum::response::Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .header("cache-control", "no-store")
        .body(axum::body::Body::from(body.to_string()))
        .unwrap_or_default()
}

fn err_reply(e: ApiError) -> axum::response::Response {
    reply(e.code, json!({"ok": false, "error_code": e.code, "description": e.description}))
}

async fn serve(axum::extract::State(api): axum::extract::State<Arc<BotApi>>, req: axum::extract::Request) -> axum::response::Response {
    let path = req.uri().path().to_string();
    let query = req.uri().query().map(str::to_string);
    let not_found = || err_reply(ApiError { code: 404, description: "Not Found".into() });
    if let Some(rest) = path.strip_prefix("/file/bot") {
        let Some((tok, file)) = rest.split_once('/') else { return not_found() };
        if !ct_eq(tok.as_bytes(), api.token.as_bytes()) {
            return err_reply(ApiError { code: 401, description: "Unauthorized".into() });
        }
        return api.download(file).await;
    }
    let Some(rest) = path.strip_prefix("/bot") else { return not_found() };
    let Some((tok, method)) = rest.split_once('/') else { return not_found() };
    if !ct_eq(tok.as_bytes(), api.token.as_bytes()) {
        return err_reply(ApiError { code: 401, description: "Unauthorized".into() });
    }
    let ct = req.headers().get("content-type").and_then(|v| v.to_str().ok()).map(str::to_string);
    let body = match axum::body::to_bytes(req.into_body(), MAX_BODY).await {
        Ok(b) => b,
        Err(_) => return err_reply(ApiError { code: 413, description: "Request Entity Too Large".into() }),
    };
    let params = match Params::parse(query.as_deref(), ct.as_deref(), &body) {
        Ok(p) => p,
        Err(e) => return err_reply(ApiError::bad(e)),
    };
    match api.call(method, params).await {
        Ok(v) => reply(200, json!({"ok": true, "result": v})),
        Err(e) => err_reply(e),
    }
}

fn hex16(s: &str, what: &str) -> Result<String, ApiError> {
    let s = s.trim();
    if s.len() == 32 && s.chars().all(|c| c.is_ascii_hexdigit()) {
        Ok(s.to_ascii_lowercase())
    } else {
        Err(ApiError::bad(format!("{what} not found (Lumora message ids are 32 hex characters)")))
    }
}

/// Image signatures → extension (an upload named "blob" should still show as a photo).
fn sniff_ext(data: &[u8]) -> Option<&'static str> {
    if data.starts_with(b"\x89PNG") {
        Some("png")
    } else if data.starts_with(&[0xff, 0xd8, 0xff]) {
        Some("jpg")
    } else if data.starts_with(b"GIF8") {
        Some("gif")
    } else if data.len() > 12 && &data[..4] == b"RIFF" && &data[8..12] == b"WEBP" {
        Some("webp")
    } else if data.starts_with(b"%PDF") {
        Some("pdf")
    } else {
        None
    }
}

fn safe_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("");
    let clean: String = base.chars().filter(|c| !c.is_control() && !matches!(c, ':' | '*' | '?' | '"' | '<' | '>' | '|')).take(120).collect();
    let clean = clean.trim().trim_start_matches('.').to_string();
    if clean.is_empty() {
        "file".into()
    } else {
        clean
    }
}

impl BotApi {
    /// One call of the core JSON API (the one the stdio protocol uses).
    async fn core(&self, req: Value) -> R {
        let r = lumora_core::api::handle(&self.node, &req).await;
        if r["ok"].as_bool() == Some(true) {
            return Ok(r["data"].clone());
        }
        let mut d = r["error"].as_str().unwrap_or("error").to_string();
        if let Some(det) = r["detail"].as_str().filter(|x| !x.is_empty()) {
            d = format!("{d} ({det})");
        }
        Err(ApiError::bad(d))
    }

    fn mark_seen(&self, id: &str) -> bool {
        let mut s = self.seen.lock().unwrap_or_else(|e| e.into_inner());
        if !s.0.insert(id.to_string()) {
            return false;
        }
        s.1.push_back(id.to_string());
        if s.1.len() > 4096 {
            if let Some(old) = s.1.pop_front() {
                s.0.remove(&old);
            }
        }
        true
    }

    /// Core events → updates.
    pub fn on_event(&self, e: &Value) {
        let me = self.node.me.to_base32();
        match e["event"].as_str().unwrap_or("") {
            "message" => {
                let kind = e["kind"].as_str().unwrap_or("");
                if e["author"].as_str() == Some(me.as_str()) || e["mine"].as_bool() == Some(true) || matches!(kind, "system" | "call") {
                    return;
                }
                let id = e["id"].as_str().unwrap_or("");
                if id.is_empty() || e["deleted"].as_bool() == Some(true) || !self.mark_seen(id) {
                    return;
                }
                self.store.push("message", message_of(&self.node, e, 0));
            }
            "message_update" if e["edited"].as_bool() == Some(true) => {
                let Some(sm) = e["id"].as_str().and_then(|i| hex::decode(i).ok()).and_then(|i| self.node.store.message(&i)) else { return };
                if sm.author == me {
                    return;
                }
                self.store.push("edited_message", message_of(&self.node, &self.node.msg_json(&sm), 0));
            }
            "callback" => {
                let mid = e["msg_id"].as_str().unwrap_or("");
                let msg = hex::decode(mid)
                    .ok()
                    .and_then(|i| self.node.store.message(&i))
                    .map(|sm| message_of(&self.node, &self.node.msg_json(&sm), 0))
                    .unwrap_or_else(|| json!({"message_id": mid, "chat": chat_of(&self.node, e["msg_conv"].as_str().unwrap_or(""))}));
                let rnd: [u8; 8] = lumora_core::crypto::random_bytes();
                self.store.push(
                    "callback_query",
                    json!({
                        "id": hex::encode(rnd),
                        "from": user_of(&self.node, e["from"].as_str().unwrap_or(""), None),
                        "message": msg,
                        "chat_instance": e["msg_conv"],
                        "data": e["data"],
                    }),
                );
            }
            _ => {}
        }
    }

    fn conv(&self, p: &Params) -> Result<String, ApiError> {
        Ok(conv_of(&p.str("chat_id").unwrap_or_default())?)
    }

    fn stored(&self, msg_id: &str) -> Option<Value> {
        let sm = hex::decode(msg_id).ok().and_then(|i| self.node.store.message(&i))?;
        Some(self.node.msg_json(&sm))
    }

    pub async fn call(self: &Arc<Self>, method: &str, p: Params) -> R {
        match method.to_ascii_lowercase().as_str() {
            "getme" => self.get_me().await,
            "sendmessage" => self.send_message(&p).await,
            "sendphoto" => self.send_file(&p, "photo").await,
            "senddocument" => self.send_file(&p, "document").await,
            "sendvideo" => self.send_file(&p, "video").await,
            "sendaudio" => self.send_file(&p, "audio").await,
            "sendanimation" => self.send_file(&p, "animation").await,
            "editmessagetext" => self.edit_text(&p).await,
            "deletemessage" => {
                let conv = self.conv(&p)?;
                let id = hex16(&p.str("message_id").unwrap_or_default(), "message to delete")?;
                self.core(json!({"cmd": "delete_message", "conv": conv, "msg_id": id, "for_everyone": true})).await?;
                Ok(json!(true))
            }
            "deletemessages" => {
                let conv = self.conv(&p)?;
                let ids = p.json("message_ids")?.and_then(|v| v.as_array().cloned()).ok_or("message_ids must be a JSON array")?;
                for i in ids {
                    let id = hex16(&i.as_str().map(str::to_string).unwrap_or_else(|| i.to_string()), "message to delete")?;
                    self.core(json!({"cmd": "delete_message", "conv": conv, "msg_id": id, "for_everyone": true})).await?;
                }
                Ok(json!(true))
            }
            "forwardmessage" => {
                let conv = self.conv(&p)?;
                let id = hex16(&p.str("message_id").unwrap_or_default(), "message to forward")?;
                let m = self.core(json!({"cmd": "forward_message", "msg_id": id, "to_conv": conv})).await?;
                Ok(message_of(&self.node, &m, 0))
            }
            "sendchataction" => {
                let conv = self.conv(&p)?;
                // Lumora shows "typing…" for every action; it ends after 5 s
                self.core(json!({"cmd": "typing", "conv": conv, "on": true})).await?;
                let api = self.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    let _ = api.core(json!({"cmd": "typing", "conv": conv, "on": false})).await;
                });
                Ok(json!(true))
            }
            "pinchatmessage" | "unpinchatmessage" => {
                let on = method.eq_ignore_ascii_case("pinchatmessage");
                let conv = self.conv(&p)?;
                let id = match p.str("message_id") {
                    Some(id) => hex16(&id, "message to pin")?,
                    None if !on => {
                        let pinned = self.core(json!({"cmd": "pinned_messages", "conv": conv})).await?;
                        match pinned.as_array().and_then(|a| a.last()).and_then(|m| m["id"].as_str()) {
                            Some(i) => i.to_string(),
                            None => return Ok(json!(true)),
                        }
                    }
                    None => return Err(ApiError::bad("message_id is required")),
                };
                self.core(json!({"cmd": "pin_message", "conv": conv, "msg_id": id, "on": on})).await?;
                Ok(json!(true))
            }
            "sendpoll" => {
                let conv = self.conv(&p)?;
                let q = p.str("question").filter(|q| !q.trim().is_empty()).ok_or("poll question must be non-empty")?;
                let opts: Vec<Value> = p
                    .json("options")?
                    .and_then(|v| v.as_array().cloned())
                    .ok_or("options must be a JSON array")?
                    .into_iter()
                    .map(|o| if o.is_object() { o["text"].clone() } else { o })
                    .collect();
                let m = self.core(json!({"cmd": "send_poll", "conv": conv, "question": q, "options": opts})).await?;
                Ok(message_of(&self.node, &m, 0))
            }
            "sendlocation" => {
                let conv = self.conv(&p)?;
                let lat = p.float("latitude").ok_or("latitude is required")?;
                let lon = p.float("longitude").ok_or("longitude is required")?;
                let live_min = p.int("live_period").map(|s| (s.max(0) as u64).div_ceil(60)).unwrap_or(0);
                let m = self
                    .core(json!({"cmd": "send_location", "conv": conv, "lat": lat, "lon": lon,
                                 "accuracy_m": p.float("horizontal_accuracy").unwrap_or(0.0), "live_minutes": live_min}))
                    .await?;
                Ok(message_of(&self.node, &m, 0))
            }
            "getchat" => {
                let conv = self.conv(&p)?;
                let mut c = chat_of(&self.node, &conv);
                if let Some(g) = conv.strip_prefix("g:") {
                    let gid = g.split('#').next().unwrap_or("");
                    let info = self.core(json!({"cmd": "group_info", "gid": gid})).await?;
                    c["description"] = info["description"].clone();
                    c["lumora_members"] = json!(info["members"].as_array().map(|a| a.len()).unwrap_or(0));
                }
                Ok(c)
            }
            "getfile" => self.get_file(&p).await,
            "getupdates" => self.get_updates(&p).await,
            "setwebhook" => self.set_webhook(&p),
            "deletewebhook" => {
                {
                    let mut st = self.store.lock();
                    st.webhook = None;
                    st.last_error_date = None;
                    st.last_error_message = None;
                    if p.bool("drop_pending_updates") {
                        st.pending.clear();
                    }
                }
                self.store.mark_dirty();
                self.webhook_changed.notify_waiters();
                Ok(json!(true))
            }
            "getwebhookinfo" => {
                let st = self.store.lock();
                let mut v = json!({"url": "", "has_custom_certificate": false, "pending_update_count": st.pending.len()});
                if let Some(w) = &st.webhook {
                    v["url"] = json!(w.url);
                    v["max_connections"] = json!(w.max_connections);
                    if let Some(a) = &w.allowed_updates {
                        v["allowed_updates"] = json!(a);
                    }
                    if let Some(d) = st.last_error_date {
                        v["last_error_date"] = json!(d);
                    }
                    if let Some(m) = &st.last_error_message {
                        v["last_error_message"] = json!(m);
                    }
                }
                Ok(v)
            }
            "answercallbackquery" => {
                // Lumora has no toast / alert for button presses: accepted, nothing shown
                p.str("callback_query_id").filter(|s| !s.is_empty()).ok_or("callback_query_id is required")?;
                Ok(json!(true))
            }
            "setmycommands" => self.set_commands(&p, false).await,
            "deletemycommands" => self.set_commands(&p, true).await,
            "getmycommands" => {
                let scope = Self::scope(&p)?;
                let info = self.bot_info();
                let list = if scope == "group" && !info.group_commands.is_empty() { &info.group_commands } else { &info.commands };
                Ok(Value::Array(list.iter().map(|(c, d)| json!({"command": c, "description": d})).collect()))
            }
            "logout" | "close" => Ok(json!(true)),
            _ => Err(ApiError { code: 404, description: "Not Found: method not found".into() }),
        }
    }

    async fn get_me(&self) -> R {
        let me = self.core(json!({"cmd": "me"})).await?;
        let allow_groups = self.node.store.kv_get("bot.allow_groups").map(|v| v != b"0").unwrap_or(true);
        Ok(json!({
            "id": me["peer"], "is_bot": true, "first_name": me["name"], "username": me["username"],
            "can_join_groups": allow_groups, "can_read_all_group_messages": false, "supports_inline_queries": false,
            "can_connect_to_business": false, "has_main_web_app": false,
            "lumora_handle": me["handle"], "lumora_short_id": me["short_id"],
        }))
    }

    fn reply_to(p: &Params) -> Result<Option<String>, ApiError> {
        let id = match p.str("reply_to_message_id") {
            Some(i) => Some(i),
            None => p.json("reply_parameters")?.and_then(|r| r["message_id"].as_str().map(str::to_string)),
        };
        id.filter(|i| !i.is_empty()).map(|i| hex16(&i, "message to be replied")).transpose()
    }

    async fn send_message(&self, p: &Params) -> R {
        let conv = self.conv(p)?;
        let text = p.str("text").filter(|t| !t.trim().is_empty()).ok_or("message text is empty")?;
        let text = format::to_lumora(&text, p.str("parse_mode").as_deref())?;
        let buttons = buttons_of(p.json("reply_markup")?.as_ref())?;
        let mut req = json!({"cmd": "send_message", "conv": conv, "text": text, "buttons": buttons, "silent": p.bool("disable_notification")});
        if let Some(r) = Self::reply_to(p)? {
            req["reply_to"] = json!(r);
        }
        let m = self.core(req).await?;
        Ok(message_of(&self.node, &m, 0))
    }

    async fn send_file(&self, p: &Params, field: &str) -> R {
        let conv = self.conv(p)?;
        let path = if let Some(up) = p.files.get(field) {
            let mut name = safe_name(&up.filename);
            if !name.contains('.') {
                if let Some(ext) = sniff_ext(&up.data) {
                    name = format!("{name}.{ext}");
                }
            }
            let rnd: [u8; 8] = lumora_core::crypto::random_bytes();
            let dir = self.upload_dir.join(hex::encode(rnd));
            let target = dir.join(&name);
            let data = up.data.clone();
            let t2 = target.clone();
            tokio::task::spawn_blocking(move || -> std::io::Result<()> {
                std::fs::create_dir_all(&dir)?;
                std::fs::write(&t2, data)
            })
            .await
            .map_err(|e| ApiError::bad(e.to_string()))?
            .map_err(|e| ApiError { code: 500, description: format!("Internal Server Error: can't store the upload: {e}") })?;
            target
        } else if let Some(s) = p.str(field).filter(|s| !s.trim().is_empty()) {
            let s = s.trim();
            if s.starts_with("http://") || s.starts_with("https://") {
                return Err(ApiError::bad("sending files by URL is not supported: upload the file (multipart/form-data) or give a local path"));
            }
            let local = s.strip_prefix("file://").unwrap_or(s);
            let pb = PathBuf::from(local);
            if pb.is_absolute() {
                pb
            } else if let Some(row) = hex::decode(s).ok().filter(|b| b.len() == 16).and_then(|b| self.node.store.file_get(&b)).filter(|r| !r.path.is_empty()) {
                // a Lumora file id this bot sent or downloaded before
                PathBuf::from(row.path)
            } else {
                return Err(ApiError::bad(format!("{field}: give a multipart upload, an absolute local path (file:///…) or a known file_id")));
            }
        } else {
            return Err(ApiError::bad(format!("there is no {field} in the request")));
        };
        let f = self.core(json!({"cmd": "send_file", "conv": conv, "path": path.to_string_lossy()})).await?;
        let fid = f["id"].as_str().unwrap_or("").to_string();
        let me = self.node.me.to_base32();
        let msg = self
            .node
            .store
            .messages(&conv, None, 50)
            .unwrap_or_default()
            .into_iter()
            .rev()
            .find(|m| m.kind == "file" && m.author == me && m.body["file_id"].as_str() == Some(fid.as_str()))
            .map(|m| self.node.msg_json(&m));
        let mut out = match &msg {
            Some(m) => message_of(&self.node, m, 0),
            None => json!({"chat": chat_of(&self.node, &conv), "date": now_ms() / 1000, "document": {"file_id": fid}}),
        };
        // captions and buttons: a text message right after the file, replying to it
        let caption = p.str("caption").filter(|c| !c.trim().is_empty());
        let buttons = buttons_of(p.json("reply_markup")?.as_ref())?;
        if caption.is_some() || buttons.as_array().map(|a| !a.is_empty()).unwrap_or(false) {
            let text = format::to_lumora(caption.as_deref().unwrap_or("⬆️"), p.str("parse_mode").as_deref())?;
            let mut req = json!({"cmd": "send_message", "conv": conv, "text": text, "buttons": buttons, "silent": p.bool("disable_notification")});
            if let Some(id) = msg.as_ref().and_then(|m| m["id"].as_str()) {
                req["reply_to"] = json!(id);
            }
            let cm = self.core(req).await?;
            if let Some(c) = caption {
                out["caption"] = json!(c);
            }
            out["lumora_caption_message_id"] = cm["id"].clone();
            if let Some(kb) = message_of(&self.node, &cm, 1).get("reply_markup") {
                out["reply_markup"] = kb.clone();
            }
        }
        Ok(out)
    }

    async fn edit_text(&self, p: &Params) -> R {
        if p.str("inline_message_id").is_some() {
            return Err(ApiError::bad("inline messages don't exist in Lumora"));
        }
        let conv = self.conv(p)?;
        let id = hex16(&p.str("message_id").unwrap_or_default(), "message to edit")?;
        let text = p.str("text").filter(|t| !t.trim().is_empty()).ok_or("message text is empty")?;
        let text = format::to_lumora(&text, p.str("parse_mode").as_deref())?;
        let cur = self.stored(&id).ok_or("message to edit not found")?;
        if cur["author"].as_str() != Some(self.node.me.to_base32().as_str()) {
            return Err(ApiError::bad("message can't be edited (only the bot's own messages)"));
        }
        if cur["body"]["text"].as_str() == Some(text.as_str()) {
            return Err(ApiError::bad("message is not modified: specified new message content and reply markup are exactly the same as a current content and reply markup of the message"));
        }
        self.core(json!({"cmd": "edit_message", "conv": conv, "msg_id": id, "text": text})).await?;
        Ok(self.stored(&id).map(|m| message_of(&self.node, &m, 0)).unwrap_or(json!(true)))
    }

    async fn get_file(&self, p: &Params) -> R {
        let fid = p.str("file_id").unwrap_or_default();
        let raw = hex::decode(fid.trim()).ok().filter(|b| b.len() == 16).ok_or("invalid file_id")?;
        let row = self.node.store.file_get(&raw).ok_or("invalid file_id")?;
        if row.state != 2 || row.path.is_empty() || !std::path::Path::new(&row.path).exists() {
            if row.direction == 0 && std::path::Path::new(&row.path).exists() {
                // own upload: always available
            } else {
                // Lumora files are fetched from the sender: download now (≤ 2 min)
                self.core(json!({"cmd": "accept_file", "file_id": fid.trim()})).await?;
                let end = tokio::time::Instant::now() + Duration::from_secs(120);
                loop {
                    let r = self.node.store.file_get(&raw);
                    if r.as_ref().map(|r| r.state == 2 && std::path::Path::new(&r.path).exists()).unwrap_or(false) {
                        break;
                    }
                    if tokio::time::Instant::now() > end {
                        return Err(ApiError::bad("file is still downloading from the sender, try again later"));
                    }
                    tokio::time::sleep(Duration::from_millis(200)).await;
                }
            }
        }
        let row = self.node.store.file_get(&raw).ok_or("invalid file_id")?;
        Ok(json!({"file_id": row.id, "file_unique_id": row.hash, "file_size": row.size, "file_path": format!("{}/{}", row.id, safe_name(&row.name))}))
    }

    async fn download(&self, file: &str) -> axum::response::Response {
        let id = file.split('/').next().unwrap_or("");
        let row = hex::decode(id).ok().filter(|b| b.len() == 16).and_then(|b| self.node.store.file_get(&b));
        let Some(row) = row.filter(|r| (r.state == 2 || r.direction == 0) && !r.path.is_empty()) else {
            return err_reply(ApiError { code: 404, description: "Not Found: file not found (call getFile first)".into() });
        };
        match tokio::fs::metadata(&row.path).await {
            Ok(m) if m.len() > MAX_DOWNLOAD => return err_reply(ApiError::bad("file is too big to download here; it is at the runner's downloads folder")),
            Err(_) => return err_reply(ApiError { code: 404, description: "Not Found: file not found".into() }),
            _ => {}
        }
        match tokio::fs::read(&row.path).await {
            Ok(b) => axum::response::Response::builder()
                .status(200)
                .header("content-type", "application/octet-stream")
                .body(axum::body::Body::from(b))
                .unwrap_or_default(),
            Err(e) => err_reply(ApiError { code: 500, description: format!("Internal Server Error: {e}") }),
        }
    }

    async fn get_updates(&self, p: &Params) -> R {
        let offset = p.int("offset").unwrap_or(0);
        let limit = p.int("limit").unwrap_or(100).clamp(1, 100) as usize;
        let timeout = p.int("timeout").unwrap_or(0).clamp(0, 50) as u64;
        let allowed_now = p.json("allowed_updates")?.and_then(|v| v.as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect::<Vec<_>>()));
        let my_gen = {
            let mut st = self.store.lock();
            if st.webhook.is_some() {
                return Err(ApiError::conflict("can't use getUpdates method while webhook is active; use deleteWebhook to delete the webhook first"));
            }
            if allowed_now.is_some() {
                st.poll_allowed = allowed_now;
            }
            st.poll_gen += 1;
            st.poll_gen
        };
        self.store.notify.notify_waiters(); // an older long poll ends (409)
        if offset > 0 {
            self.store.confirm(offset);
        } else if offset < 0 {
            let mut st = self.store.lock();
            let keep = (-offset) as usize;
            while st.pending.len() > keep {
                st.pending.pop_front();
            }
            drop(st);
            self.store.mark_dirty();
        }
        let deadline = tokio::time::Instant::now() + Duration::from_secs(timeout);
        loop {
            let notified = self.store.notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            {
                let st = self.store.lock();
                if st.poll_gen != my_gen {
                    return Err(ApiError::conflict("terminated by other getUpdates request; make sure that only one bot instance is running"));
                }
                if st.webhook.is_some() {
                    return Err(ApiError::conflict("terminated by setWebhook request"));
                }
                let out: Vec<Value> = st
                    .pending
                    .iter()
                    .filter(|u| u.id() >= offset && allowed(&st.poll_allowed, u.kind()))
                    .take(limit)
                    .map(|u| u.update.clone())
                    .collect();
                if !out.is_empty() || tokio::time::Instant::now() >= deadline {
                    return Ok(Value::Array(out));
                }
            }
            if tokio::time::timeout_at(deadline, notified).await.is_err() {
                // timed out: one last look happens at the top of the loop
                let st = self.store.lock();
                if st.poll_gen != my_gen {
                    return Err(ApiError::conflict("terminated by other getUpdates request; make sure that only one bot instance is running"));
                }
                let out: Vec<Value> = st.pending.iter().filter(|u| u.id() >= offset && allowed(&st.poll_allowed, u.kind())).take(limit).map(|u| u.update.clone()).collect();
                return Ok(Value::Array(out));
            }
        }
    }

    fn set_webhook(&self, p: &Params) -> R {
        let url = p.str("url").unwrap_or_default().trim().to_string();
        let secret = p.str("secret_token").filter(|s| !s.is_empty());
        if let Some(s) = &secret {
            if s.len() > 256 || !s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
                return Err(ApiError::bad("secret token contains unallowed characters (1-256 of A-Z, a-z, 0-9, _ and -)"));
            }
        }
        if !(url.is_empty() || url.starts_with("https://") || url.starts_with("http://")) {
            return Err(ApiError::bad("bad webhook: the URL must start with https:// or http://"));
        }
        let allowed_updates = p.json("allowed_updates")?.and_then(|v| v.as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()));
        {
            let mut st = self.store.lock();
            st.webhook = if url.is_empty() {
                None
            } else {
                Some(Webhook { url, secret_token: secret, max_connections: p.int("max_connections").unwrap_or(40).clamp(1, 100) as u32, allowed_updates })
            };
            st.last_error_date = None;
            st.last_error_message = None;
            st.poll_gen += 1;
            if p.bool("drop_pending_updates") {
                st.pending.clear();
            }
        }
        self.store.mark_dirty();
        self.store.notify.notify_waiters();
        self.webhook_changed.notify_waiters();
        Ok(json!(true))
    }

    fn bot_info(&self) -> lumora_core::proto::BotInfo {
        self.node.store.kv_get_json::<lumora_core::proto::BotInfo>("bot.info").unwrap_or_default()
    }

    /// "private" / "group" / "both" from a `BotCommandScope`.
    fn scope(p: &Params) -> Result<&'static str, ApiError> {
        let s = p.json("scope")?;
        match s.as_ref().and_then(|v| v["type"].as_str()).unwrap_or("default") {
            "default" => Ok("both"),
            "all_private_chats" => Ok("private"),
            "all_group_chats" => Ok("group"),
            other => Err(ApiError::bad(format!("command scope '{other}' is not supported (use default, all_private_chats or all_group_chats)"))),
        }
    }

    /// setMyCommands / deleteMyCommands → the bot's command menu (`set_bot`, same as the SDKs).
    async fn set_commands(&self, p: &Params, delete: bool) -> R {
        let scope = Self::scope(p)?;
        let list: Vec<(String, String)> = if delete {
            vec![]
        } else {
            let cmds = p.json("commands")?.and_then(|v| v.as_array().cloned()).ok_or("commands must be a JSON array")?;
            if cmds.len() > 100 {
                return Err(ApiError::bad("too many commands (max 100)"));
            }
            let mut out = Vec::new();
            for c in cmds {
                let name = c["command"].as_str().unwrap_or("").trim().trim_start_matches('/').to_ascii_lowercase();
                let desc = c["description"].as_str().unwrap_or("").trim().to_string();
                if name.is_empty() || name.len() > 32 || !name.chars().all(|x| x.is_ascii_alphanumeric() || x == '_') {
                    return Err(ApiError::bad(format!("BOT_COMMAND_INVALID: '{name}' (1-32 of a-z, 0-9 and _)")));
                }
                if desc.is_empty() || desc.chars().count() > 256 {
                    return Err(ApiError::bad(format!("command description of '{name}' must be 1-256 characters")));
                }
                out.push((name, desc));
            }
            out
        };
        let info = self.bot_info();
        let (mut cmds, mut group) = (info.commands.clone(), info.group_commands.clone());
        if group.is_empty() {
            group = cmds.clone(); // empty group list meant "same as private"
        }
        match scope {
            "private" => cmds = list,
            "group" => group = list,
            _ => {
                cmds = list.clone();
                group = list;
            }
        }
        let to_json = |l: &[(String, String)]| Value::Array(l.iter().map(|(c, d)| json!({"command": c, "description": d})).collect());
        let auto_accept = self.node.store.kv_get("bot.auto_accept").map(|v| v != b"0").unwrap_or(true);
        self.core(json!({"cmd": "set_bot", "commands": to_json(&cmds), "group_commands": to_json(&group), "about": info.about, "auto_accept": auto_accept}))
            .await?;
        Ok(json!(true))
    }
}

/// Deliver pending updates to the webhook in order; failures are retried with back-off
/// (1 s, 2 s, 4 s … 60 s) until the update is 24 h old.
async fn webhook_loop(api: Arc<BotApi>) {
    let mut attempt: u32 = 0;
    loop {
        let notified = api.store.notify.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();
        let job = {
            let mut st = api.store.lock();
            let cutoff = now_ms().saturating_sub(updates::MAX_AGE_MS);
            while st.pending.front().map(|p| p.at < cutoff).unwrap_or(false) {
                st.pending.pop_front();
            }
            match (&st.webhook, st.pending.front()) {
                (Some(w), Some(p)) => Some((w.clone(), p.clone())),
                _ => None,
            }
        };
        let Some((hook, upd)) = job else {
            attempt = 0;
            notified.await;
            continue;
        };
        if !allowed(&hook.allowed_updates, upd.kind()) {
            api.store.confirm(upd.id() + 1);
            continue;
        }
        let body = upd.update.to_string();
        let mut headers = vec![("Content-Type", "application/json")];
        if let Some(s) = &hook.secret_token {
            headers.push(("X-Lumora-Bot-Secret", s.as_str()));
        }
        // one delivery runs on its own task: whatever the webhook server answers, a failure
        // (even a panic while parsing) is just a failed delivery, retried with back-off
        let res = {
            let url = hook.url.clone();
            let headers: Vec<(String, String)> = headers.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
            tokio::spawn(async move {
                let h: Vec<(&str, &str)> = headers.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
                http::request("POST", &url, &h, body.as_bytes(), Duration::from_secs(30)).await
            })
            .await
            .unwrap_or_else(|e| Err(anyhow::anyhow!("webhook delivery crashed: {e}")))
        };
        let error = match res {
            Ok(r) if (200..300).contains(&r.status) => {
                api.store.confirm(upd.id() + 1);
                attempt = 0;
                // the reply may itself be a method call {"method": "sendMessage", …}
                let ct = r.header("content-type").unwrap_or("").to_string();
                if ct.to_ascii_lowercase().starts_with("application/json") {
                    if let Ok(Value::Object(m)) = serde_json::from_slice::<Value>(&r.body) {
                        if let Some(method) = m.get("method").and_then(|x| x.as_str()).map(str::to_string) {
                            let a = api.clone();
                            tokio::spawn(async move {
                                let p = Params { map: m, ..Default::default() };
                                if let Err(e) = a.call(&method, p).await {
                                    tracing::warn!("bot api: webhook reply {method} failed: {}", e.description);
                                }
                            });
                        }
                    }
                }
                continue;
            }
            Ok(r) => format!("Wrong response from the webhook: {}", r.status),
            Err(e) => format!("{e:#}"),
        };
        {
            let mut st = api.store.lock();
            if st.webhook.as_ref() == Some(&hook) {
                st.last_error_date = Some((now_ms() / 1000) as i64);
                st.last_error_message = Some(error.clone());
            }
        }
        tracing::debug!("bot api: webhook delivery of update {} failed: {error}", upd.id());
        let delay = Duration::from_millis((1000u64 << attempt.min(6)).min(MAX_BACKOFF_S * 1000));
        attempt = attempt.saturating_add(1);
        let changed = api.webhook_changed.notified();
        tokio::select! {
            _ = tokio::time::sleep(delay) => {}
            _ = changed => { attempt = 0; }
        }
    }
}
