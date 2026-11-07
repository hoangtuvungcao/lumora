//! Lumora objects → Bot API JSON (`User`, `Chat`, `Message`, keyboards).
//!
//! Ids stay Lumora strings: `chat.id` is the conversation id (`d:<peer>`, `g:<gid>`,
//! `g:<gid>#<channel>`), `message_id` the message id (32 hex chars), `from.id` the peer id.

use lumora_core::identity::PeerId;
use lumora_core::node::Node;
use serde_json::{json, Map, Value};
use std::sync::Arc;

/// A Lumora `chat_id` from what a caller gave: a conversation id, a bare peer id (direct
/// chat) or a bare group id (32 hex chars). Numeric chat ids don't exist here.
pub fn conv_of(chat_id: &str) -> Result<String, String> {
    let c = chat_id.trim();
    if c.is_empty() {
        return Err("Bad Request: chat_id is empty".into());
    }
    if c.starts_with("d:") || c.starts_with("g:") {
        return lumora_core::node::parse_conv(c).map(|_| c.to_string()).map_err(|_| format!("Bad Request: chat not found ({c})"));
    }
    if c.len() == 32 && c.chars().all(|x| x.is_ascii_hexdigit()) {
        return Ok(format!("g:{}", c.to_ascii_lowercase()));
    }
    if let Ok(p) = PeerId::from_str_any(c) {
        return Ok(format!("d:{}", p.to_base32()));
    }
    if c.parse::<i64>().is_ok() {
        return Err("Bad Request: chat_id must be a Lumora conversation id (d:<peer>, g:<gid> or g:<gid>#<channel>), not a number".into());
    }
    Err(format!("Bad Request: chat not found ({c})"))
}

/// A Bot API `User` for a Lumora peer.
pub fn user_of(node: &Arc<Node>, peer: &str, author_name: Option<&str>) -> Value {
    if peer == node.me.to_base32() {
        let mut u = json!({"id": peer, "is_bot": node.is_bot(), "first_name": node.name()});
        if let Some(n) = node.username() {
            u["username"] = json!(n);
        }
        return u;
    }
    let contact = PeerId::from_str_any(peer).ok().and_then(|p| node.store.contact(&p));
    let name = contact
        .as_ref()
        .map(|c| c.alias.clone().filter(|a| !a.is_empty()).unwrap_or_else(|| c.name.clone()))
        .filter(|n| !n.is_empty())
        .or_else(|| author_name.map(str::to_string))
        .unwrap_or_else(|| PeerId::from_str_any(peer).map(|p| p.short_id_fmt()).unwrap_or_else(|_| peer.to_string()));
    let mut u = json!({"id": peer, "is_bot": contact.as_ref().map(|c| c.bot.is_object()).unwrap_or(false), "first_name": name});
    if let Some(un) = contact.as_ref().and_then(|c| c.username.clone()).filter(|u| !u.is_empty()) {
        u["username"] = json!(un);
    }
    if let Some(h) = contact.as_ref().and_then(|c| c.handle.clone()) {
        u["lumora_handle"] = json!(h);
    }
    u
}

/// A Bot API `Chat` for a conversation: direct chats are "private", groups "group",
/// communities (and their channels) "supergroup".
pub fn chat_of(node: &Arc<Node>, conv: &str) -> Value {
    if let Some(p) = conv.strip_prefix("d:") {
        let u = user_of(node, p, None);
        let mut c = json!({"id": conv, "type": "private", "first_name": u["first_name"]});
        if let Some(un) = u.get("username") {
            c["username"] = un.clone();
        }
        return c;
    }
    if let Some(g) = conv.strip_prefix("g:") {
        let (gid, channel) = g.split_once('#').map(|(a, b)| (a, Some(b))).unwrap_or((g, None));
        let info = hex::decode(gid).ok().and_then(|b| <[u8; 16]>::try_from(b).ok()).and_then(|b| node.group_info(&b).ok());
        let name = info.as_ref().and_then(|i| i["name"].as_str()).unwrap_or("").to_string();
        let community = info.as_ref().and_then(|i| i["kind"].as_u64()).unwrap_or(0) == 1 || channel.is_some();
        let title = match channel {
            Some(ch) => format!("{name} › #{ch}"),
            None => name,
        };
        let mut c = json!({"id": conv, "type": if community { "supergroup" } else { "group" }, "title": title});
        if let Some(ch) = channel {
            c["lumora_channel"] = json!(ch);
        }
        if let Some(h) = info.as_ref().and_then(|i| i["handle"].as_str()) {
            c["lumora_handle"] = json!(h);
        }
        return c;
    }
    json!({"id": conv, "type": "private"})
}

/// Inline keyboard (`reply_markup.inline_keyboard`) → Lumora buttons `[[{text, data, url}]]`.
pub fn buttons_of(markup: Option<&Value>) -> Result<Value, String> {
    let Some(m) = markup else { return Ok(json!([])) };
    let Some(rows) = m.get("inline_keyboard") else {
        // reply / remove / force-reply keyboards have no Lumora equivalent: ignored
        return Ok(json!([]));
    };
    let rows = rows.as_array().ok_or("Bad Request: inline_keyboard must be an array of button rows")?;
    let mut out = Vec::new();
    for row in rows {
        let row = row.as_array().ok_or("Bad Request: inline_keyboard rows must be arrays")?;
        let mut r = Vec::new();
        for b in row {
            let text = b["text"].as_str().ok_or("Bad Request: inline keyboard button text is missing")?;
            let data = b["callback_data"].as_str().unwrap_or("");
            let url = b["url"].as_str().unwrap_or("");
            if data.is_empty() && url.is_empty() {
                return Err("Bad Request: only callback_data and url buttons are supported".into());
            }
            r.push(json!({"text": text, "data": data, "url": url}));
        }
        out.push(Value::Array(r));
    }
    Ok(Value::Array(out))
}

fn keyboard_of(meta: &Value) -> Option<Value> {
    let rows = meta.get("buttons")?.as_array().filter(|r| !r.is_empty())?;
    let kb: Vec<Value> = rows
        .iter()
        .map(|row| {
            Value::Array(
                row.as_array()
                    .map(|r| {
                        r.iter()
                            .map(|b| {
                                let mut o = json!({"text": b["text"]});
                                if b["url"].as_str().map(|u| !u.is_empty()).unwrap_or(false) {
                                    o["url"] = b["url"].clone();
                                } else {
                                    o["callback_data"] = b["data"].clone();
                                }
                                o
                            })
                            .collect()
                    })
                    .unwrap_or_default(),
            )
        })
        .collect();
    Some(json!({"inline_keyboard": kb}))
}

fn utf16_len(s: &str) -> usize {
    s.encode_utf16().count()
}

/// A Bot API `Message` for a Lumora message (the JSON of `messages` / the `message` event).
pub fn message_of(node: &Arc<Node>, m: &Value, depth: u8) -> Value {
    let conv = m["conv"].as_str().unwrap_or("");
    let author = m["author"].as_str().unwrap_or("");
    let mut o = Map::new();
    o.insert("message_id".into(), m["id"].clone());
    o.insert("date".into(), json!(m["ts"].as_i64().unwrap_or(0) / 1000));
    o.insert("chat".into(), chat_of(node, conv));
    o.insert("from".into(), user_of(node, author, m["author_name"].as_str()));
    if let Some(ch) = conv.split_once('#').map(|(_, c)| c) {
        o.insert("lumora_channel".into(), json!(ch));
    }
    if m["edited"].as_bool().unwrap_or(false) {
        o.insert("edit_date".into(), json!(lumora_now_s()));
    }
    if let Some(r) = m["reply_to"].as_str().filter(|r| !r.is_empty()) {
        let replied = if depth == 0 {
            hex::decode(r).ok().and_then(|id| node.store.message(&id)).map(|sm| message_of(node, &node.msg_json(&sm), depth + 1))
        } else {
            None
        };
        o.insert("reply_to_message".into(), replied.unwrap_or_else(|| json!({"message_id": r, "chat": {"id": conv}})));
    }
    let meta = &m["meta"];
    if let Some(f) = meta["forwarded_from"].as_str() {
        o.insert("forward_origin".into(), json!({"type": "hidden_user", "sender_user_name": f, "date": m["ts"].as_i64().unwrap_or(0) / 1000}));
    }
    let body = &m["body"];
    let kind = m["kind"].as_str().unwrap_or("");
    match kind {
        "text" => {
            let text = body["text"].as_str().unwrap_or("");
            o.insert("text".into(), json!(text));
            if let Some(cmd) = text.split_whitespace().next().filter(|w| w.starts_with('/') && w.len() > 1 && text.starts_with('/')) {
                o.insert("entities".into(), json!([{"type": "bot_command", "offset": 0, "length": utf16_len(cmd)}]));
            }
        }
        "file" => {
            let mime = body["mime"].as_str().unwrap_or("");
            let fid = body["file_id"].clone();
            let uniq = body["hash"].clone();
            if mime.starts_with("image/") {
                o.insert(
                    "photo".into(),
                    json!([{"file_id": fid, "file_unique_id": uniq, "width": body["width"], "height": body["height"], "file_size": body["size"]}]),
                );
            } else {
                let mut d = json!({"file_id": fid, "file_unique_id": uniq, "file_name": body["name"], "mime_type": mime, "file_size": body["size"]});
                if mime.starts_with("video/") {
                    d["width"] = body["width"].clone();
                    d["height"] = body["height"].clone();
                    o.insert("video".into(), d.clone());
                }
                o.insert("document".into(), d);
            }
        }
        "voice" => {
            o.insert(
                "voice".into(),
                json!({"file_id": body["file_id"], "file_unique_id": body["file_id"], "duration": body["duration_ms"].as_u64().unwrap_or(0) / 1000,
                       "mime_type": "audio/ogg", "file_size": body["size"]}),
            );
        }
        "location" => {
            let mut l = json!({"latitude": body["lat"], "longitude": body["lon"]});
            if body["accuracy_m"].as_f64().unwrap_or(0.0) > 0.0 {
                l["horizontal_accuracy"] = body["accuracy_m"].clone();
            }
            o.insert("location".into(), l);
        }
        "contact" => {
            o.insert("contact".into(), json!({"user_id": body["peer"], "first_name": body["name"], "phone_number": ""}));
        }
        "sticker" => {
            o.insert("sticker".into(), json!({"file_id": body["hash"], "file_unique_id": body["hash"], "emoji": body["emoji"], "is_animated": body["animated"], "type": "regular"}));
        }
        "poll" => {
            let votes = &m["reactions"];
            let opts: Vec<Value> = body["options"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .enumerate()
                        .map(|(i, t)| {
                            let n = votes.get("__votes").and_then(|v| v.as_object()).map(|v| v.values().filter(|x| x.as_u64() == Some(i as u64)).count()).unwrap_or(0);
                            json!({"text": t, "voter_count": n})
                        })
                        .collect()
                })
                .unwrap_or_default();
            let total: u64 = opts.iter().filter_map(|o| o["voter_count"].as_u64()).sum();
            o.insert(
                "poll".into(),
                json!({"id": m["id"], "question": body["question"], "options": opts, "total_voter_count": total, "is_closed": false,
                       "is_anonymous": false, "type": "regular", "allows_multiple_answers": false}),
            );
        }
        _ => {}
    }
    if kind != "text" {
        let mut b = body.clone();
        if let Some(x) = b.as_object_mut() {
            x.remove("thumb");
            x.remove("wave");
        }
        o.insert("lumora".into(), json!({"kind": kind, "body": b}));
    }
    if let Some(kb) = keyboard_of(meta) {
        o.insert("reply_markup".into(), kb);
    }
    Value::Object(o)
}

pub fn lumora_now_s() -> i64 {
    (super::updates::now_ms() / 1000) as i64
}
