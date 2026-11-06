//! JSON command dispatcher shared by the FFI library and the CLI daemon.
//! Contract: docs/src/dev/api.md

use crate::identity::PeerId;
use crate::node::Node;
use crate::proto::MsgAction;
use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::sync::Arc;

fn s<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v.get(k).and_then(|x| x.as_str()).ok_or_else(|| anyhow!("missing '{k}'"))
}
fn b(v: &Value, k: &str) -> Option<bool> {
    v.get(k).and_then(|x| x.as_bool())
}
fn id16(v: &Value, k: &str) -> Result<[u8; 16]> {
    let h = hex::decode(s(v, k)?)?;
    h.try_into().map_err(|_| anyhow!("'{k}' must be 32 hex chars"))
}
fn strs(v: &Value, k: &str) -> Vec<String> {
    v.get(k).and_then(|x| x.as_array()).map(|a| a.iter().filter_map(|x| x.as_str()).map(String::from).collect()).unwrap_or_default()
}
/// `silent: true` → "Gửi không âm báo" (receivers get no sound / notification).
fn silent_meta(v: &Value) -> crate::proto::MsgMeta {
    crate::proto::MsgMeta { silent: b(v, "silent").unwrap_or(false), ..Default::default() }
}
/// UI secrets live under their own namespace; keys must start with "ui." (≤ 64 chars).
fn ui_secret_key(k: &str) -> Result<String> {
    anyhow::ensure!(
        k.starts_with("ui.") && k.len() > 3 && k.len() <= 64 && k.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c)),
        "key must start with 'ui.' (letters, digits, . _ -; max 64)"
    );
    Ok(format!("uisecret:{k}"))
}
fn peer(v: &Value, k: &str) -> Result<PeerId> {
    PeerId::from_str_any(s(v, k)?)
}

pub async fn handle(node: &Arc<Node>, req: &Value) -> Value {
    let id = req.get("id").cloned().unwrap_or(Value::Null);
    match dispatch(node, req).await {
        Ok(data) => json!({"id": id, "ok": true, "data": data}),
        Err(e) => {
            if crate::i18n::find_user_err(&e).is_none() {
                tracing::debug!("request failed: {e:#}");
            }
            let mut m = crate::i18n::error_fields(&e);
            m.insert("id".into(), id);
            m.insert("ok".into(), Value::Bool(false));
            Value::Object(m)
        }
    }
}

async fn dispatch(node: &Arc<Node>, r: &Value) -> Result<Value> {
    // send_* with a `client_id`: idempotent (a retry returns the message created first)
    if s(r, "cmd")?.starts_with("send_") {
        if let Some(cid) = r.get("client_id").and_then(|x| x.as_str()) {
            return node.send_once(cid, || dispatch_cmd(node, r)).await;
        }
    }
    dispatch_cmd(node, r).await
}

async fn dispatch_cmd(node: &Arc<Node>, r: &Value) -> Result<Value> {
    let cmd = s(r, "cmd")?;
    Ok(match cmd {
        "ping" => json!("pong"),
        "set_lang" => {
            let l = s(r, "lang")?;
            crate::i18n::set_lang(l);
            node.store.kv_set("ui.lang", crate::i18n::lang().as_bytes())?;
            json!({"lang": crate::i18n::lang()})
        }
        "i18n_catalog" => crate::i18n::catalog(),
        "me" => {
            let devs = node.devices_json();
            json!({
                "peer": node.me.to_base32(), "short_id": node.me.short_id_fmt(), "name": node.name(),
                "username": node.username(), "handle": node.handle(),
                "protection": node.protection, "version": env!("CARGO_PKG_VERSION"),
                "safety": node.me.security_code(),
                // multi-device: `peer` is the account; this is one of its devices
                "account": node.me.to_base32(), "device": node.device.to_base32(), "primary": node.is_primary(),
                "device_name": node.store.kv_get("device.name").and_then(|v| String::from_utf8(v).ok()).unwrap_or_default(),
                "devices": devs["devices"].as_array().map(|a| a.len()).unwrap_or(1),
                "link_pending": node.cfg.link_pending,
            })
        }
        "set_name" => {
            node.set_name(s(r, "name")?)?;
            Value::Null
        }
        "recovery_phrase" => {
            // a linked device holds its own device key, never the account's
            anyhow::ensure!(node.is_primary(), crate::i18n::user_err("err.phrase_on_primary"));
            json!({"phrase": node.id.recovery_phrase()})
        }
        "phrase_check" => {
            // Does a typed phrase belong to this account? Also works on a linked
            // device (which never holds the phrase): the account is derived from it.
            let matches = crate::identity::Identity::from_recovery_phrase(s(r, "phrase")?).map(|id| id.peer_id() == node.me).unwrap_or(false);
            json!({"matches": matches})
        }
        "check_passphrase" => {
            // re-confirm the data password before showing secrets (wrong → err.wrong_passphrase)
            crate::keystore::unlock(&node.cfg.data_dir, Some(s(r, "passphrase")?))?;
            json!({"ok": true})
        }
        // ---- multi-device (docs/src/dev/multi-device.md §8)
        "devices" => node.devices_json(),
        "device_rename" => {
            node.device_rename(&peer(r, "device")?, s(r, "name")?)?;
            node.devices_json()
        }
        "device_revoke" => node.device_revoke(&peer(r, "device")?, b(r, "wipe_media").or_else(|| b(r, "wipe")).unwrap_or(false)).await?,
        "device_logout" => node.device_logout().await?,
        "device_promote" => node.device_promote(s(r, "phrase")?, r.get("passphrase").and_then(|x| x.as_str())).await?,
        "contact_devices" => node.contact_devices_json(&peer(r, "peer")?),
        // main device: invite a new device (it scans this QR / types this code)
        "link_invite" => node.link_invite().await?,
        // new device: show a QR + 12-digit code (older direction: the main device scans it)
        "link_start" | "device_link_start" => node.link_start(r.get("name").and_then(|x| x.as_str())).await?,
        // existing (main) device: scan the QR or type the code → who is asking
        "link_scan" | "device_link_accept" => node.link_scan(r.get("qr").and_then(|x| x.as_str()), r.get("code").and_then(|x| x.as_str()), r.get("name").and_then(|x| x.as_str())).await?,
        // existing device: approve with a history choice
        "link_approve" | "device_link_confirm" => {
            node.link_approve(
                &peer(r, "device")?,
                r.get("history").and_then(|x| x.as_str()).unwrap_or("3m"),
                r.get("history_since_ms").and_then(|x| x.as_u64()),
                b(r, "media").unwrap_or(false),
            )
            .await?
        }
        "link_reject" => {
            node.link_reject(&peer(r, "device")?)?;
            Value::Null
        }
        "link_cancel" => {
            node.link_cancel();
            Value::Null
        }
        "history_status" => node.history_status(),
        "net_status" => node.net_status(),
        // iPhone wake-ups via the optional push bridge (node/push.rs)
        "push_register" => node.push_register(r)?,
        "push_unregister" => node.push_unregister()?,
        "push_status" => node.push_status(),
        // app back in the foreground: reconnect now so friends flush what they queued
        "resume" => node.resume(),
        // the app's view of the device: metered network / battery saver → no birthday
        // spraying for relay → direct upgrades (relayed calls stay relayed)
        "set_network_hint" => {
            let metered = r.get("metered").and_then(|x| x.as_bool()).unwrap_or(false);
            let low_battery = r.get("low_battery").and_then(|x| x.as_bool()).unwrap_or(false);
            node.set_power_saving(metered || low_battery);
            json!({"power_saving": metered || low_battery})
        }
        // Bonjour/DNS-SD: what to advertise (iOS does it from Swift) and sightings to add
        "lan_advert" => json!({
            "name": crate::net::discovery::lan_hint(&node.me, crate::net::discovery::lan_day()),
            "service": crate::net::discovery::mdns_service(),
            "port": node.net.local_port(),
            "enabled": node.net.lan_enabled.load(std::sync::atomic::Ordering::Relaxed),
        }),
        "refresh_net" => {
            node.net.refresh_info().await;
            node.net_status()
        }
        "contacts" => {
            let list = node.store.contacts()?;
            Value::Array(
                list.into_iter()
                    .map(|c| {
                        let p = PeerId::from_str_any(&c.peer).ok();
                        let online = p.map(|p| node.is_online(&p)).unwrap_or(false);
                        // linked device + friend's app too old for multi-device: our messages
                        // go through the main device ("Gửi qua thiết bị chính của bạn")
                        let bridged = p.map(|p| !node.is_primary() && !node.speaks_multidevice(&p)).unwrap_or(false);
                        let mut v = serde_json::to_value(c).unwrap_or(Value::Null);
                        v["online"] = Value::Bool(online);
                        v["bridged"] = Value::Bool(bridged);
                        v
                    })
                    .collect(),
            )
        }
        "add_contact" => {
            let p = node.add_contact(s(r, "target")?, r.get("note").and_then(|x| x.as_str()).unwrap_or("")).await?;
            json!({"peer": p.to_base32()})
        }
        "lookup" => {
            let sid: u32 = s(r, "short_id")?.chars().filter(|c| c.is_ascii_digit()).collect::<String>().parse().map_err(|_| crate::i18n::user_err("err.invalid_id"))?;
            let pool = node.net.nostr.read().clone().ok_or_else(|| crate::i18n::user_err("err.lookup_off"))?;
            Value::Array(pool.lookup_short_id(sid).await.into_iter().map(|(p, n)| json!({"peer": p.to_base32(), "name": n})).collect())
        }
        "accept_contact" => {
            node.accept_contact(&peer(r, "peer")?).await?;
            Value::Null
        }
        "remove_contact" => {
            node.remove_contact(&peer(r, "peer")?, false)?;
            Value::Null
        }
        "block_contact" => {
            node.remove_contact(&peer(r, "peer")?, true)?;
            Value::Null
        }
        "unblock_contact" => {
            node.store.upsert_contact(&peer(r, "peer")?, None, Some(0))?;
            Value::Null
        }
        "rename_contact" => {
            let p = peer(r, "peer")?;
            let alias = s(r, "alias")?.trim().to_string();
            node.store.set_contact_field(
                &p,
                "alias",
                if alias.is_empty() { rusqlite::types::Value::Null } else { rusqlite::types::Value::Text(alias) },
            )?;
            Value::Null
        }
        "security_status" => {
            let p = peer(r, "peer")?;
            json!({"forward_secrecy": node.olm_has_session(&p), "verified": node.store.contact(&p).map(|c| c.verified).unwrap_or(false)})
        }
        // test builds only: lose the ratchet sessions with every device of a peer (the
        // session-repair path must then deliver everything anyway)
        "debug_olm_drop" if cfg!(debug_assertions) => {
            let p = peer(r, "peer")?;
            for d in node.delivery_targets(&p) {
                node.olm_drop_sessions(&d);
            }
            Value::Null
        }
        "verify_contact" => {
            let p = peer(r, "peer")?;
            json!({"safety_number": PeerId::safety_number(&node.me, &p), "verified": node.store.contact(&p).map(|c| c.verified).unwrap_or(false)})
        }
        "mark_verified" => {
            node.store.set_contact_field(&peer(r, "peer")?, "verified", rusqlite::types::Value::Integer(b(r, "verified").unwrap_or(true) as i64))?;
            Value::Null
        }
        "conversations" => serde_json::to_value(node.conversations()?)?,
        "messages" => {
            let conv = s(r, "conv")?;
            let before = r.get("before").and_then(|x| x.as_i64());
            let limit = r.get("limit").and_then(|x| x.as_i64()).unwrap_or(50);
            Value::Array(node.store.messages(conv, before, limit)?.iter().map(|m| node.msg_json(m)).collect())
        }
        "send_text" => {
            let reply = r.get("reply_to").and_then(|x| x.as_str()).and_then(|h| hex::decode(h).ok()).and_then(|v| v.try_into().ok());
            let ttl = r.get("ttl_ms").and_then(|x| x.as_u64());
            node.send_text_meta(s(r, "conv")?, s(r, "text")?, reply, ttl, silent_meta(r)).await?
        }
        "send_message" => {
            // generic send with mentions: {conv, text, reply_to?, ttl_ms?, mentions?: [peer], mention_all?}
            let reply = r.get("reply_to").and_then(|x| x.as_str()).and_then(|h| hex::decode(h).ok()).and_then(|v| v.try_into().ok());
            let ttl = r.get("ttl_ms").and_then(|x| x.as_u64());
            let mentions: Vec<PeerId> = r.get("mentions").and_then(|m| m.as_array())
                .map(|a| a.iter().filter_map(|x| x.as_str()).filter_map(|x| PeerId::from_str_any(x).ok()).collect()).unwrap_or_default();
            let buttons: Vec<Vec<crate::proto::Button>> = r
                .get("buttons")
                .map(|v| serde_json::from_value(v.clone()))
                .transpose()
                .map_err(|e| anyhow!("bad 'buttons' (expected [[{{text, data?, url?}}]]): {e}"))?
                .unwrap_or_default();
            anyhow::ensure!(buttons.len() <= 8 && buttons.iter().all(|row| row.len() <= 8), "max 8×8 buttons");
            anyhow::ensure!(buttons.iter().flatten().all(|b| b.data.len() <= 64 && b.text.chars().count() <= 64), "button text/data too long (64)");
            let meta = crate::proto::MsgMeta {
                mentions,
                mention_all: b(r, "mention_all").unwrap_or(false),
                forwarded_from: None,
                buttons,
                silent: b(r, "silent").unwrap_or(false),
            };
            node.send_text_meta(s(r, "conv")?, s(r, "text")?, reply, ttl, meta).await?
        }
        "send_poll" => {
            let opts: Vec<String> = r.get("options").and_then(|o| o.as_array())
                .map(|a| a.iter().filter_map(|x| x.as_str()).map(|x| x.chars().take(100).collect()).collect()).unwrap_or_default();
            anyhow::ensure!((2..=10).contains(&opts.len()), crate::i18n::user_err("err.poll_options"));
            node.send_body(s(r, "conv")?, crate::proto::Body::Poll { question: s(r, "question")?.chars().take(300).collect(), options: opts }, None, None).await?
        }
        "vote" => {
            let opt = r.get("option").and_then(|x| x.as_u64()).ok_or_else(|| anyhow!("missing 'option'"))? as u32;
            node.message_action(s(r, "conv")?, id16(r, "msg_id")?, MsgAction::Vote { target: id16(r, "msg_id")?, option: opt }).await?;
            Value::Null
        }
        // ---- checklists ("Danh sách việc") and reminders ("Nhắc hẹn")
        "send_checklist" => node.send_checklist(s(r, "conv")?, s(r, "title")?, &strs(r, "items"), silent_meta(r)).await?,
        "checklist_toggle" => {
            let item = r.get("item").and_then(|x| x.as_u64()).ok_or_else(|| anyhow!("missing 'item'"))? as u32;
            node.checklist_toggle(s(r, "conv")?, id16(r, "msg_id")?, item, b(r, "done").unwrap_or(true)).await?;
            Value::Null
        }
        "checklist_add" => {
            node.checklist_add(s(r, "conv")?, id16(r, "msg_id")?, &strs(r, "items")).await?;
            Value::Null
        }
        "send_reminder" => {
            let at = r.get("at_ms").and_then(|x| x.as_u64()).ok_or_else(|| anyhow!("missing 'at_ms'"))?;
            node.send_reminder(s(r, "conv")?, s(r, "title")?, at, r.get("note").and_then(|x| x.as_str()).unwrap_or(""), silent_meta(r)).await?
        }
        "reminder_cancel" => {
            node.reminder_cancel(s(r, "conv")?, id16(r, "msg_id")?).await?;
            Value::Null
        }
        "reminder_seen" => {
            node.reminder_seen(s(r, "conv")?, id16(r, "msg_id")?).await?;
            Value::Null
        }
        "reminders" => Value::Array(node.reminders()),
        "pin_message" => {
            node.message_action(s(r, "conv")?, id16(r, "msg_id")?, MsgAction::Pin { target: id16(r, "msg_id")?, on: b(r, "on").unwrap_or(true) }).await?;
            Value::Null
        }
        "pinned_messages" => Value::Array(node.store.pinned(s(r, "conv")?)?.iter().map(|m| node.msg_json(m)).collect()),
        "forward_message" => node.forward(&id16(r, "msg_id")?, s(r, "to_conv")?).await?,
        "profile" => node.profile(),
        "set_profile" => {
            node.set_profile(r.get("name").and_then(|x| x.as_str()), r.get("bio").and_then(|x| x.as_str()),
                r.get("status").and_then(|x| x.as_str()), r.get("avatar").and_then(|x| x.as_str()))?;
            node.profile()
        }
        "set_cover" => {
            node.set_cover(s(r, "cover")?)?;
            node.profile()
        }
        "contact_cover" => {
            let a = node.store.contact_cover(&peer(r, "peer")?);
            json!({"cover": a.map(|a| data_encoding::BASE64.encode(&a))})
        }
        "contact_avatar" => {
            let a = node.store.contact_avatar(&peer(r, "peer")?);
            json!({"avatar": a.map(|a| data_encoding::BASE64.encode(&a))})
        }
        "create_invite" => json!({"link": node.create_invite(id16(r, "gid")?, r.get("hours").and_then(|x| x.as_u64()).unwrap_or(168))?}),
        "inspect_invite" => node.inspect_invite(s(r, "link")?)?,
        "join_invite" => node.join_invite(s(r, "link")?).await?,
        "schedule_message" => node.schedule_text(s(r, "conv")?, s(r, "text")?, r.get("at").and_then(|x| x.as_u64()).ok_or_else(|| anyhow!("missing 'at'"))?)?,
        "scheduled_messages" => serde_json::to_value(node.scheduled())?,
        "cancel_scheduled" => {
            node.cancel_scheduled(s(r, "sched_id")?)?;
            Value::Null
        }
        "send_sticker" => {
            // custom sticker by hash, or a built-in one by {pack, sticker}
            if let Some(h) = r.get("hash").and_then(|x| x.as_str()) {
                node.send_sticker(s(r, "conv")?, h).await?
            } else {
                node.send_body(s(r, "conv")?, crate::proto::Body::Sticker {
                    pack: s(r, "pack")?.into(), id: s(r, "sticker")?.into(), hash: [0; 32],
                    mime: String::new(), data: vec![], emoji: String::new(), animated: false,
                }, None, None).await?
            }
        }
        "sticker_packs" => Value::Array(node.store.sticker_packs()?),
        "sticker_pack_create" => node.sticker_pack_create(s(r, "name")?)?,
        "sticker_pack_delete" => {
            node.store.sticker_pack_delete(s(r, "pack")?)?;
            Value::Null
        }
        "sticker_add" => node.sticker_add(s(r, "pack")?, s(r, "path")?, r.get("emoji").and_then(|x| x.as_str()).unwrap_or("")).await?,
        "sticker_remove" => {
            node.store.sticker_remove(&hex::decode(s(r, "hash")?)?, s(r, "pack")?)?;
            Value::Null
        }
        "sticker_save" => {
            node.sticker_save(s(r, "hash")?, s(r, "pack")?)?;
            Value::Null
        }
        "sticker_get" => {
            let (mime, data) = node.store.sticker_blob(&hex::decode(s(r, "hash")?)?).ok_or_else(|| crate::i18n::user_err("err.sticker_not_found"))?;
            json!({"mime": mime, "data": data_encoding::BASE64.encode(&data)})
        }
        "sticker_pack_export" => node.sticker_pack_export(s(r, "pack")?, s(r, "path")?)?,
        "sticker_pack_import" => node.sticker_pack_import(s(r, "path")?)?,
        "edit_message" => {
            node.message_action(s(r, "conv")?, id16(r, "msg_id")?, MsgAction::Edit { target: id16(r, "msg_id")?, text: s(r, "text")?.into() }).await?;
            Value::Null
        }
        "delete_message" => {
            // for_everyone (default true): delete on both sides (1-1: any message; groups: own or as admin)
            // for_everyone=false: "delete for me" — removed on your devices (all devices of
            // this account), together with the copy Lumora downloaded; others keep it
            if b(r, "for_everyone").unwrap_or(true) {
                node.message_action(s(r, "conv")?, id16(r, "msg_id")?, MsgAction::Delete { target: id16(r, "msg_id")? }).await?;
            } else {
                node.delete_for_me(s(r, "conv")?, &id16(r, "msg_id")?)?;
            }
            Value::Null
        }
        "clear_history" => {
            node.clear_history(s(r, "conv")?, b(r, "for_everyone").unwrap_or(false), false).await?;
            Value::Null
        }
        "react" => {
            node.message_action(
                s(r, "conv")?,
                id16(r, "msg_id")?,
                MsgAction::React { target: id16(r, "msg_id")?, emoji: s(r, "emoji")?.into(), on: b(r, "on").unwrap_or(true) },
            )
            .await?;
            Value::Null
        }
        "mark_read" => {
            node.mark_read(s(r, "conv")?)?;
            Value::Null
        }
        "typing" => {
            node.typing(s(r, "conv")?, b(r, "on").unwrap_or(true))?;
            Value::Null
        }
        "conv_flag" => {
            node.store.conv_set_flag(s(r, "conv")?, s(r, "flag")?, b(r, "value").unwrap_or(true))?;
            Value::Null
        }
        "set_retention" => {
            // mode: "forever" | "session" (no history) | "24h" | "7d" | "30d"
            let conv = s(r, "conv")?;
            let ms = match s(r, "mode")? {
                "forever" => None,
                "session" => Some(-1),
                "24h" => Some(86_400_000),
                "7d" => Some(7 * 86_400_000),
                "30d" => Some(30 * 86_400_000),
                other => return Err(anyhow!("unknown retention mode '{other}'")),
            };
            node.store.set_retention(conv, ms)?;
            node.store.maintain()?;
            Value::Null
        }
        "get_retention" => {
            let conv = s(r, "conv")?;
            json!({"mode": match node.store.retention(conv) { None => "forever", Some(-1) => "session", Some(86_400_000) => "24h", Some(604_800_000) => "7d", Some(_) => "30d" }})
        }
        "delete_conversation" => {
            node.clear_history(s(r, "conv")?, b(r, "for_everyone").unwrap_or(false), true).await?;
            Value::Null
        }
        "remote_recent" => {
            let mut list: Vec<Value> = node.store.kv_get_json("remote.recent").unwrap_or_default();
            for e in list.iter_mut() {
                let online = e["peer"].as_str().and_then(|p| PeerId::from_str_any(p).ok()).map(|p| node.is_online(&p)).unwrap_or(false);
                e["online"] = Value::Bool(online);
                e["can_wake"] = Value::Bool(e["macs"].as_array().map(|a| !a.is_empty()).unwrap_or(false));
            }
            Value::Array(list)
        }
        "remote_wake" => {
            let id = r.get("peer").or_else(|| r.get("target")).and_then(|x| x.as_str()).ok_or_else(|| anyhow!("missing 'peer'"))?;
            node.remote_wake(id).await?
        }
        "remote_recent_remove" => {
            // peer: remove one device (also revokes "always allow"); no peer: clear the whole list
            match r.get("peer").and_then(|x| x.as_str()) {
                Some(p) => {
                    let mut list: Vec<Value> = node.store.kv_get_json("remote.recent").unwrap_or_default();
                    list.retain(|x| x["peer"].as_str() != Some(p));
                    node.store.kv_set_json("remote.recent", &list)?;
                    if let Ok(pid) = PeerId::from_str_any(p) {
                        node.store.remote_trust(&pid, None)?;
                    }
                }
                None => node.store.kv_set_json("remote.recent", &Vec::<Value>::new())?,
            }
            Value::Null
        }
        "search" if r.get("global").and_then(|x| x.as_bool()) == Some(true) => {
            // global search: people (@user), bots and public groups by handle
            let q = s(r, "q")?;
            let people = node.resolve_username(q).await.unwrap_or_default();
            let groups = node.search_groups(q).await.unwrap_or_default();
            json!({"people": people, "groups": groups})
        }
        "search" => Value::Array(node.store.search(s(r, "q")?, 100)?.iter().map(|m| node.msg_json(m)).collect()),
        "groups" => Value::Array(node.groups_list()),
        "spaces" => {
            // communities (kind 1) in the shape the UI's Space model expects
            let convs = node.store.conversations()?;
            Value::Array(
                node.groups_list()
                    .into_iter()
                    .filter(|g| g["kind"].as_u64() == Some(1))
                    .map(|g| {
                        let chans: Vec<Value> = g["channels"].as_array().cloned().unwrap_or_default().into_iter().map(|c| {
                            let conv = c["conv"].as_str().unwrap_or("").to_string();
                            let unread = convs.iter().find(|x| x.id == conv).map(|x| x.unread).unwrap_or(0);
                            json!({"id": c["name"], "name": c["name"], "voice": c["voice"], "conv": conv, "unread": unread, "participants": []})
                        }).collect();
                        json!({"id": g["gid"], "name": g["name"], "members": g["members"].as_array().map(|m| m.len()).unwrap_or(0), "channels": chans})
                    })
                    .collect(),
            )
        }
        "voice_join" => node.call_start(s(r, "conv")?, false).await?,
        "voice_leave" => {
            let conv = s(r, "conv")?.to_string();
            let ids: Vec<[u8; 16]> = node.remote.calls.lock().values().filter(|c| c.conv == conv).map(|c| c.id).collect();
            for id in ids {
                node.end_call(&id, false);
            }
            Value::Null
        }
        "create_group" => {
            let members: Vec<PeerId> = r
                .get("members")
                .and_then(|m| m.as_array())
                .map(|a| a.iter().filter_map(|x| x.as_str()).filter_map(|x| PeerId::from_str_any(x).ok()).collect())
                .unwrap_or_default();
            let kind = r.get("kind").and_then(|k| k.as_u64()).unwrap_or(0) as u8;
            node.create_group(s(r, "name")?, members, kind).await?
        }
        "group_info" => node.group_info(&id16(r, "gid")?)?,
        "group_add" => {
            node.group_add(id16(r, "gid")?, peer(r, "peer")?).await?;
            Value::Null
        }
        "group_remove" => {
            node.group_remove(id16(r, "gid")?, peer(r, "peer")?).await?;
            Value::Null
        }
        "group_set_role" => {
            node.group_set_role(id16(r, "gid")?, peer(r, "peer")?, s(r, "role")? == "admin").await?;
            Value::Null
        }
        "group_rename" => {
            node.group_rename(id16(r, "gid")?, s(r, "name")?).await?;
            Value::Null
        }
        "group_channel" => {
            node.group_channel(id16(r, "gid")?, s(r, "name")?, b(r, "voice").unwrap_or(false), b(r, "remove").unwrap_or(false)).await?;
            Value::Null
        }
        "send_location" => {
            let f = |k: &str| r.get(k).and_then(|x| x.as_f64()).ok_or_else(|| anyhow!("missing '{k}'"));
            node.send_location(s(r, "conv")?, f("lat")?, f("lon")?, r.get("accuracy_m").and_then(|x| x.as_f64()).unwrap_or(0.0) as f32,
                r.get("label").and_then(|x| x.as_str()).unwrap_or(""), r.get("live_minutes").and_then(|x| x.as_u64()).unwrap_or(0)).await?
        }
        "update_live_location" => {
            let f = |k: &str| r.get(k).and_then(|x| x.as_f64()).unwrap_or(0.0);
            node.update_live_location(s(r, "conv")?, id16(r, "msg_id")?, f("lat"), f("lon"), f("accuracy_m") as f32, b(r, "stop").unwrap_or(false)).await?;
            Value::Null
        }
        "send_voice" => {
            let wave: Vec<u8> = r.get("wave").and_then(|w| w.as_array()).map(|a| a.iter().filter_map(|x| x.as_u64()).map(|x| x.min(255) as u8).collect()).unwrap_or_default();
            node.send_voice(s(r, "conv")?, s(r, "path")?, r.get("duration_ms").and_then(|x| x.as_u64()).unwrap_or(0) as u32, wave).await?
        }
        "send_contact" => node.send_contact_card(s(r, "conv")?, peer(r, "peer")?).await?,
        "post_story" => node.post_story(r.get("text").and_then(|x| x.as_str()).unwrap_or(""), r.get("image_path").and_then(|x| x.as_str()), r.get("bg").and_then(|x| x.as_str()).unwrap_or("aurora")).await?,
        "stories" => Value::Array(node.store.stories()?),
        "story_image" => json!({"image": node.store.story_image(&id16(r, "story_id")?).map(|a| data_encoding::BASE64.encode(&a))}),
        "story_seen" => {
            node.story_seen(id16(r, "story_id")?).await?;
            Value::Null
        }
        "story_viewers" => json!(node.store.story_viewers(&id16(r, "story_id")?)),
        "press_button" => {
            node.press_button(id16(r, "msg_id")?, r.get("data").and_then(|x| x.as_str()).unwrap_or("")).await?;
            Value::Null
        }
        "bot_create" => node.bot_create(s(r, "name")?, s(r, "username")?)?,
        "bot_list" => Value::Array(node.bot_list()),
        "bot_token" => json!({"token": node.bot_token(s(r, "username")?)?}),
        "bot_revoke" => node.bot_revoke(s(r, "username")?)?,
        "bot_delete" => {
            node.bot_delete(s(r, "username")?)?;
            Value::Null
        }
        // BotFather conversation (account setting, synced; bounded, no tokens)
        "botfather_history" => json!({"entries": crate::node::botfather::transcript(&node.store)}),
        "botfather_append" => {
            let entries = r.get("entries").and_then(|x| x.as_array()).ok_or_else(|| anyhow::anyhow!("'entries' must be a list"))?;
            anyhow::ensure!(entries.len() <= crate::node::botfather::TRANSCRIPT_MAX, "too many entries");
            json!({"entries": crate::node::botfather::transcript_append(&node.store, entries)?})
        }
        "botfather_clear" => {
            crate::node::botfather::transcript_clear(&node.store)?;
            Value::Null
        }
        // locked chats (account setting, synced; the PIN stays per device in ui_secret)
        "locked_chats_get" => match crate::node::chat_locks::locked_chats(&node.store) {
            Some(l) => json!({"chats": l, "set": true}),
            None => json!({"chats": [], "set": false}),
        },
        "locked_chats_set" => {
            let list: Vec<String> = r
                .get("chats")
                .and_then(|x| x.as_array())
                .ok_or_else(|| anyhow::anyhow!("'chats' must be a list"))?
                .iter()
                .map(|x| x.as_str().map(str::to_string).ok_or_else(|| anyhow::anyhow!("'chats' must be strings")))
                .collect::<Result<_>>()?;
            json!({"chats": crate::node::chat_locks::set_locked_chats(&node.store, &list)?})
        }
        "set_username" => node.set_username(s(r, "username")?)?,
        "resolve_username" => Value::Array(node.resolve_username(s(r, "handle")?).await?),
        "set_bot" => {
            let parse = |k: &str| -> Vec<(String, String)> {
                r.get(k).and_then(|c| c.as_array()).map(|a| a.iter().filter_map(|x| {
                    Some((x["command"].as_str()?.trim_start_matches('/').to_string(), x["description"].as_str().unwrap_or("").to_string()))
                }).collect()).unwrap_or_default()
            };
            node.set_bot(parse("commands"), parse("group_commands"), r.get("about").and_then(|x| x.as_str()).unwrap_or(""), b(r, "auto_accept").unwrap_or(true))?;
            if let Some(v) = b(r, "allow_groups") {
                node.store.kv_set("bot.allow_groups", if v { b"1" } else { b"0" })?;
            }
            Value::Null
        }
        "group_visibility" => node.group_visibility(id16(r, "gid")?, b(r, "public").unwrap_or(false), r.get("handle").and_then(|x| x.as_str()).unwrap_or("")).await?,
        "search_groups" => Value::Array(node.search_groups(s(r, "q")?).await?),
        "join_public" => {
            node.join_public(id16(r, "gid")?, peer(r, "via")?).await?;
            json!({"pending": true})
        }
        "group_add_bot" => {
            let botp = node.resolve_id(s(r, "target")?).await?;
            node.group_add_bot(id16(r, "gid")?, botp, b(r, "read_all").unwrap_or(false)).await?;
            json!({"peer": botp.to_base32()})
        }
        "group_bot_policy" => {
            node.group_bot_policy(id16(r, "gid")?, peer(r, "peer")?, b(r, "read_all").unwrap_or(false)).await?;
            Value::Null
        }
        "group_ban" => {
            node.group_ban(id16(r, "gid")?, peer(r, "peer")?, b(r, "ban").unwrap_or(true)).await?;
            Value::Null
        }
        "group_settings" => {
            node.group_settings(id16(r, "gid")?, r.get("slow_mode_s").and_then(|x| x.as_u64()).map(|x| x as u32), b(r, "admins_only")).await?;
            Value::Null
        }
        "seen_by" => {
            let m = node.store.message(&id16(r, "msg_id")?).ok_or_else(|| crate::i18n::user_err("err.message_not_found"))?;
            json!(node.store.group_seen_by(&m.conv, m.hlc))
        }
        "mute" => {
            // until: ms timestamp, 0 = unmute, u64::MAX = forever
            let conv = s(r, "conv")?;
            let until = r.get("until").and_then(|x| x.as_u64()).unwrap_or(u64::MAX);
            node.store.conv_set_flag(conv, "muted", until > 0)?;
            node.store.kv_set(&format!("mute_until.{conv}"), &until.to_le_bytes())?;
            json!({"muted": until > 0, "until": until})
        }
        "group_purge_member" => {
            node.group_purge_member(id16(r, "gid")?, peer(r, "peer")?).await?;
            Value::Null
        }
        "group_clear_history" => {
            node.group_clear_history(id16(r, "gid")?).await?;
            Value::Null
        }
        "group_meta" => {
            node.group_meta(id16(r, "gid")?, r.get("avatar").and_then(|x| x.as_str()), r.get("description").and_then(|x| x.as_str())).await?;
            Value::Null
        }
        "group_avatar" => json!({"avatar": node.group_avatar(&id16(r, "gid")?).map(|a| data_encoding::BASE64.encode(&a))}),
        "set_wallpaper" => {
            // conv id or "default"; wallpaper = preset name ("aurora", "midnight", ...), "color:#RRGGBB",
            // "image:<base64>" (≤ 1.5 MB) or "" to reset. Stored locally (encrypted DB), never sent.
            let conv = s(r, "conv")?;
            let w = s(r, "wallpaper")?;
            anyhow::ensure!(w.len() <= 2 * 1024 * 1024, crate::i18n::user_err("err.image_too_large").with("max", "1.5 MB"));
            let key = format!("wallpaper.{conv}");
            if w.is_empty() { node.store.kv_set(&key, b"")?; } else { node.store.kv_set(&key, w.as_bytes())?; }
            Value::Null
        }
        "get_wallpaper" => {
            let conv = s(r, "conv")?;
            let get = |k: &str| node.store.kv_get(k).and_then(|v| String::from_utf8(v).ok()).filter(|v| !v.is_empty());
            json!({"wallpaper": get(&format!("wallpaper.{conv}")).or_else(|| get("wallpaper.default"))})
        }
        "group_leave" => {
            node.group_leave(id16(r, "gid")?).await?;
            Value::Null
        }
        "send_file" => node.send_file_args(s(r, "conv")?, s(r, "path")?, r).await?,
        "accept_file" => {
            let dir = r.get("dir").and_then(|d| d.as_str()).map(std::path::PathBuf::from);
            node.accept_file(&id16(r, "file_id")?, dir).await?;
            Value::Null
        }
        "cancel_file" => {
            node.cancel_file(&id16(r, "file_id")?)?;
            Value::Null
        }
        "files" => Value::Array(node.files_list()?),
        "pause_file" => {
            node.pause_file(&id16(r, "file_id")?)?;
            Value::Null
        }
        "call_start" => node.call_start(s(r, "conv")?, b(r, "video").unwrap_or(false)).await?,
        "call_answer" => {
            node.call_answer(&id16(r, "call_id")?, b(r, "accept").unwrap_or(true)).await?;
            Value::Null
        }
        "call_end" => {
            node.end_call(&id16(r, "call_id")?, false);
            Value::Null
        }
        "call_set" => {
            node.call_set(&id16(r, "call_id")?, b(r, "mic"), b(r, "cam"), b(r, "screen"))?;
            Value::Null
        }
        "remote_status" => {
            let mut v = node.remote.status(node);
            v["diagnostics"] = diagnostics();
            v
        }
        "remote_set" => {
            node.remote.set(
                &node.store,
                r.get("password").and_then(|x| x.as_str()),
                b(r, "unattended"),
                b(r, "allow_control"),
                b(r, "allow_incoming"),
            )?;
            node.remote.status(node)
        }
        "remote_new_password" => json!({"password": node.remote.regenerate_password()}),
        "remote_trust" => {
            node.store.remote_trust(&peer(r, "peer")?, if b(r, "trusted").unwrap_or(true) { Some(1) } else { None })?;
            Value::Null
        }
        "remote_connect" => {
            node.remote_connect(s(r, "target")?, r.get("password").and_then(|x| x.as_str()).unwrap_or(""), b(r, "view_only").unwrap_or(false), r.get("device").and_then(|x| x.as_str())).await?
        }
        "remote_respond" => {
            node.remote_respond(&id16(r, "session")?, b(r, "accept").unwrap_or(false), b(r, "control").unwrap_or(true)).await?;
            Value::Null
        }
        "remote_input" => {
            node.remote_input(&id16(r, "session")?, r.get("ev").ok_or_else(|| anyhow!("missing ev"))?)?;
            Value::Null
        }
        "remote_power" => {
            // action: "lock" | "restart" | "logout" (restart/logout need the host's opt-in)
            node.remote_power(&id16(r, "session")?, s(r, "action")?)?;
            Value::Null
        }
        "remote_allow_power" => {
            node.store.kv_set("remote.allow_power", if b(r, "allow").unwrap_or(false) { b"1" } else { b"0" })?;
            Value::Null
        }
        "remote_display" => {
            node.remote_select_display(&id16(r, "session")?, r.get("index").and_then(|x| x.as_u64()).unwrap_or(0) as u32)?;
            Value::Null
        }
        "remote_clipboard" => {
            let sid = id16(r, "session")?;
            let sess = node.remote.sessions.lock().get(&sid).cloned().ok_or_else(|| crate::i18n::user_err("err.no_session"))?;
            // clipboard sync only with control rights: a view-only viewer neither gets
            // the host's clipboard nor sets it (the peer refuses it as well)
            anyhow::ensure!(sess.accepted.load(std::sync::atomic::Ordering::Relaxed), crate::i18n::user_err("err.no_session"));
            anyhow::ensure!(sess.control.load(std::sync::atomic::Ordering::Relaxed), crate::i18n::user_err("err.view_only"));
            node.send_now(&sess.peer, crate::proto::PeerMsg::Clipboard { text: s(r, "text")?.chars().take(1 << 20).collect() });
            Value::Null
        }
        "remote_end" => {
            node.end_session(&id16(r, "session")?, true);
            Value::Null
        }
        "diagnostics" => diagnostics(),
        // video codecs: what this device can do (OS H.264 hardware? bundled VP8/VP9) and
        // what the last call used — shown in call stats / Settings › Nâng cao
        #[cfg(feature = "media")]
        "video_codec" => {
            crate::node::media_pipe::warm_up(node);
            lumora_media::codec::status()
        }
        // small encrypted key-value store for the UI (app-lock PIN hash, failure counter…),
        // kept in the encrypted database instead of plain settings files
        "ui_secret_get" => {
            let k = ui_secret_key(s(r, "key")?)?;
            match node.store.kv_get(&k) {
                Some(v) => Value::String(String::from_utf8(v).unwrap_or_default()),
                None => Value::Null,
            }
        }
        "ui_secret_set" => {
            let k = ui_secret_key(s(r, "key")?)?;
            match r.get("value") {
                None | Some(Value::Null) => node.store.kv_del(&k)?,
                Some(Value::String(v)) => {
                    anyhow::ensure!(v.len() <= 4096, "value too large (max 4 KB)");
                    node.store.kv_set(&k, v.as_bytes())?;
                }
                Some(_) => anyhow::bail!("'value' must be a string or null"),
            }
            Value::Null
        }
        "settings_get" => {
            let g = |k: &str, d: &str| node.store.kv_get(k).and_then(|v| String::from_utf8(v).ok()).unwrap_or_else(|| d.to_string());
            json!({
                "read_receipts": g("privacy.read_receipts", "1") != "0",
                "typing": g("privacy.typing", "1") != "0",
                "store_forward": g("privacy.store_forward", "1") != "0",
                "discoverable_by_id": g("privacy.discoverable", "1") != "0",
                // "Help friends connect": relay for friends stuck behind hard NATs
                "help_friends": node.peer_relay_enabled(),
                "echo_cancel": g("audio.aec", "1") != "0",
                "noise_suppression": g("audio.ns", "1") != "0",
                // camera effects: 0 = off, 1..3 = Nhẹ / Vừa / Mạnh
                "video_beauty": g("video.beauty", "0").trim().parse::<u8>().unwrap_or(0).min(3),
                "video_lowlight": g("video.lowlight", "1") != "0",
                "video_mirror_send": g("video.mirror_send", "0") != "0",
                "wake_for_friends": g("remote.wake_for_friends", "1") != "0",
                "lan": node.net.lan_enabled.load(std::sync::atomic::Ordering::Relaxed),
                "relays": node.store.kv_get_json::<Vec<String>>("net.relays").unwrap_or_default(),
                "relay_delay_ms": node.net.cfg.read().relay_delay_ms,
                "p2p_only": node.net.cfg.read().relay_delay_ms >= 600_000,
                "downloads_dir": node.downloads_dir().to_string_lossy(),
            })
        }
        "settings_set" => {
            let setb = |k: &str, key: &str| -> Result<()> {
                if let Some(v) = b(r, k) {
                    node.store.kv_set(key, if v { b"1" } else { b"0" })?;
                }
                Ok(())
            };
            setb("read_receipts", "privacy.read_receipts")?;
            setb("typing", "privacy.typing")?;
            setb("store_forward", "privacy.store_forward")?;
            if let Some(v) = b(r, "help_friends") {
                node.set_help_friends(v)?;
            }
            if let Some(v) = b(r, "discoverable_by_id") {
                node.store.kv_set("privacy.discoverable", if v { b"1" } else { b"0" })?;
                node.publish_directory_now();
                // the public Nostr inbox is only listened to while strangers may find me
                node.refresh_nostr_inboxes(false);
            }
            setb("echo_cancel", "audio.aec")?;
            setb("noise_suppression", "audio.ns")?;
            if let Some(v) = r.get("video_beauty").and_then(|x| x.as_u64()) {
                node.store.kv_set("video.beauty", v.min(3).to_string().as_bytes())?;
            }
            setb("video_lowlight", "video.lowlight")?;
            setb("video_mirror_send", "video.mirror_send")?;
            #[cfg(feature = "media")]
            if ["video_beauty", "video_lowlight", "video_mirror_send"].iter().any(|k| r.get(*k).is_some()) {
                crate::node::media_pipe::camera_fx_changed(); // applies mid-call, next frame
            }
            setb("wake_for_friends", "remote.wake_for_friends")?;
            if let Some(v) = b(r, "lan") {
                node.net.lan_enabled.store(v, std::sync::atomic::Ordering::Relaxed);
            }
            if let Some(d) = r.get("relay_delay_ms").and_then(|x| x.as_u64()) {
                node.net.cfg.write().relay_delay_ms = d.clamp(0, 60_000);
            }
            // "Chỉ P2P thuần": never carry data through any relay
            if let Some(v) = b(r, "p2p_only") {
                node.net.cfg.write().relay_delay_ms = if v { u64::MAX } else { 3500 };
                node.store.kv_set("net.p2p_only", if v { b"1" } else { b"0" })?;
            }
            if let Some(d) = r.get("downloads_dir").and_then(|x| x.as_str()) {
                node.store.kv_set("files.dir", d.as_bytes())?;
            }
            if let Some(list) = r.get("relays").and_then(|x| x.as_array()) {
                let relays: Vec<String> = list
                    .iter()
                    .filter_map(|x| x.as_str())
                    .map(|x| x.trim().to_string())
                    .filter(|x| x.starts_with("ws://") || x.starts_with("wss://"))
                    .collect();
                // removed ones stop now (not at the next start)
                let old: Vec<String> = node.store.kv_get_json("net.relays").unwrap_or_default();
                node.store.kv_set_json("net.relays", &relays)?;
                for u in old.iter().filter(|u| !relays.contains(u)) {
                    node.net.cfg.write().relays.retain(|x| x != u);
                    node.net.remove_relay(u);
                }
                for u in relays {
                    if !node.net.cfg.read().relays.contains(&u) {
                        node.net.cfg.write().relays.push(u.clone());
                    }
                    node.net.add_relay(u);
                }
            }
            Value::Null
        }
        "storage_stats" => {
            let mut v = node.store.stats();
            let rows = node.store.received_files()?;
            v["media_bytes"] = json!(rows.iter().map(|r| r.size as u64).sum::<u64>());
            v["db_bytes"] = json!(std::fs::metadata(node.cfg.data_dir.join("lumora.db")).map(|m| m.len()).unwrap_or(0));
            v["low_disk"] = json!(node.low_disk());
            v["policy"] = serde_json::to_value(node.storage_policy())?;
            v["by_conv"] = Value::Array(node.store.usage_by_conv()?);
            v
        }
        "storage_policy" => serde_json::to_value(node.storage_policy())?,
        "set_storage_policy" => {
            let mut p = node.storage_policy();
            let g = |k: &str| r.get(k).and_then(|x| x.as_u64());
            if let Some(v) = g("max_cache") { p.max_cache = v; }
            if let Some(v) = g("media_days") { p.media_days = v; }
            if let Some(v) = g("auto_direct") { p.auto_direct = v; }
            if let Some(v) = g("auto_group") { p.auto_group = v; }
            if let Some(v) = g("community_days") { p.community_days = v; }
            node.set_storage_policy(&p)?;
            node.clean_media(None)?;
            serde_json::to_value(p)?
        }
        "clear_media" => node.clean_media(Some(r.get("conv").and_then(|x| x.as_str()).unwrap_or("*")))?,
        "maintain" => {
            node.store.maintain()?;
            node.store.stats()
        }
        "export_backup" => {
            let un = crate::keystore::unlock(&node.cfg.data_dir, r.get("passphrase").and_then(|x| x.as_str()))?;
            node.store.maintain()?;
            let out = std::path::PathBuf::from(s(r, "path")?);
            let n = crate::keystore::export_backup(&node.cfg.data_dir, &un, &out, s(r, "password")?)?;
            json!({"path": out.to_string_lossy(), "bytes": n})
        }
        "remote_quality" => {
            // preset: "smooth" (60 fps, adaptive ≤8 Mbps) | "balanced" (≤5 Mbps) | "sharp" (≤15 Mbps) | "saver" (≤1.5 Mbps)
            let kbps = match s(r, "preset")? { "smooth" => 8000, "sharp" => 15000, "saver" => 1500, _ => 5000 };
            let sid = id16(r, "session")?;
            let sess = node.remote.sessions.lock().get(&sid).cloned().ok_or_else(|| crate::i18n::user_err("err.no_session"))?;
            node.send_now(&sess.peer, crate::proto::PeerMsg::Bitrate { stream: sess.stream, kbps });
            node.send_now(&sess.peer, crate::proto::PeerMsg::KeyframeRequest { stream: 0 });
            json!({"max_kbps": kbps})
        }
        "change_passphrase" => {
            let un = crate::keystore::unlock(&node.cfg.data_dir, r.get("old").and_then(|x| x.as_str()))?;
            let new = r.get("new").and_then(|x| x.as_str()).filter(|p| !p.is_empty());
            let prot = crate::keystore::change_protection(&node.cfg.data_dir, &un, new)?;
            json!({"protection": prot})
        }
        "upgrade" => {
            // try to replace a relayed connection by a direct one right now
            let p = peer(r, "peer")?;
            node.try_upgrade(p).await.map_err(|e| crate::i18n::or_user(e, "err.no_faster_path"))?;
            let c = node.peer(&p).ok_or_else(|| crate::i18n::user_err("err.connection_lost"))?;
            json!({"path": c.path, "rtt_ms": c.conn.rtt().as_millis() as u64})
        }
        "connect" => {
            let c = node.connect(peer(r, "peer")?).await?;
            json!({"path": c.path, "rtt_ms": c.conn.rtt().as_millis() as u64, "remote_addr": c.conn.remote_address().to_string()})
        }
        other => return Err(anyhow!("unknown command '{other}'")),
    })
}

pub fn diagnostics() -> Value {
    #[cfg(feature = "media")]
    {
        serde_json::to_value(lumora_media::diag::diagnostics()).unwrap_or(Value::Null)
    }
    #[cfg(not(feature = "media"))]
    {
        json!({"platform": std::env::consts::OS, "checks": []})
    }
}
