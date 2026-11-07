//! HTTP Bot API against real nodes: auth, sendMessage to a friend, getUpdates, webhook.

use super::*;
use lumora_core::node::NodeConfig;
use std::time::Instant;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const TOKEN: &str = "lumora_bot_testtoken0123456789abcdefghijklmnop";

async fn node(dir: &std::path::Path, name: &str, lan: bool) -> Arc<Node> {
    Node::start(NodeConfig {
        data_dir: dir.join("data"),
        downloads_dir: Some(dir.join("dl")),
        name: Some(name.into()),
        enable_lan: lan,
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

async fn bot_api(bot: &Arc<Node>, dir: &std::path::Path) -> (Arc<BotApi>, String) {
    let cfg = Config { addr: "127.0.0.1:0".parse().unwrap(), token: TOKEN.into(), state_file: Some(dir.join("bot_api.json")), upload_dir: dir.join("uploads") };
    let (api, addr) = start(bot.clone(), cfg).await.unwrap();
    (api, format!("http://{addr}"))
}

async fn call(base: &str, token: &str, method: &str, body: Value) -> (u16, Value) {
    let r = http::request("POST", &format!("{base}/bot{token}/{method}"), &[("Content-Type", "application/json")], body.to_string().as_bytes(), Duration::from_secs(60))
        .await
        .unwrap();
    (r.status, serde_json::from_slice(&r.body).unwrap_or(Value::Null))
}

async fn ok(base: &str, method: &str, body: Value) -> Value {
    let (st, v) = call(base, TOKEN, method, body).await;
    assert_eq!(st, 200, "{method}: {v}");
    assert_eq!(v["ok"], true, "{method}: {v}");
    v["result"].clone()
}

async fn core(n: &Arc<Node>, req: Value) -> Value {
    let r = lumora_core::api::handle(n, &req).await;
    assert_eq!(r["ok"], true, "{req}: {r}");
    r["data"].clone()
}

async fn wait_for<F: FnMut() -> Option<T>, T>(what: &str, secs: u64, mut f: F) -> T {
    let end = Instant::now() + Duration::from_secs(secs);
    loop {
        if let Some(v) = f() {
            return v;
        }
        assert!(Instant::now() < end, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

#[test]
fn constant_time_compare() {
    assert!(ct_eq(b"abc", b"abc"));
    assert!(!ct_eq(b"abc", b"abd"));
    assert!(!ct_eq(b"abc", b"abcd"));
    assert!(!ct_eq(b"", b"a"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn auth_and_errors() {
    let tmp = tempfile::tempdir().unwrap();
    let bot = node(tmp.path(), "Auth Bot", false).await;
    core(&bot, json!({"cmd": "set_bot", "commands": [{"command": "start", "description": "Start"}], "about": "x"})).await;
    let (_api, base) = bot_api(&bot, tmp.path()).await;

    // wrong / missing / prefix-only token: 401, Bot API error shape
    for t in ["lumora_bot_wrong", "", &TOKEN[..TOKEN.len() - 1], &format!("{TOKEN}x")] {
        let (st, v) = call(&base, t, "getMe", json!({})).await;
        assert_eq!(st, 401, "token {t:?}");
        assert_eq!(v, json!({"ok": false, "error_code": 401, "description": "Unauthorized"}));
    }
    let r = http::request("GET", &format!("{base}/nothing"), &[], b"", Duration::from_secs(5)).await.unwrap();
    assert_eq!(r.status, 404);

    let me = ok(&base, "getMe", json!({})).await;
    assert_eq!(me["id"], json!(bot.me.to_base32()));
    assert_eq!(me["is_bot"], true);
    assert_eq!(me["first_name"], "Auth Bot");
    // GET with a query string works too, method names are case-insensitive
    let r = http::request("GET", &format!("{base}/bot{TOKEN}/GETME?x=1"), &[], b"", Duration::from_secs(5)).await.unwrap();
    assert_eq!(r.status, 200);

    let (st, v) = call(&base, TOKEN, "noSuchMethod", json!({})).await;
    assert_eq!((st, v["error_code"].clone(), v["description"].clone()), (404, json!(404), json!("Not Found: method not found")));
    let (st, v) = call(&base, TOKEN, "sendMessage", json!({"text": "hi"})).await;
    assert_eq!((st, v["ok"].clone()), (400, json!(false)));
    assert_eq!(v["description"], "Bad Request: chat_id is empty");
    let (st, v) = call(&base, TOKEN, "sendMessage", json!({"chat_id": 12345, "text": "hi"})).await;
    assert_eq!(st, 400);
    assert!(v["description"].as_str().unwrap().contains("Lumora conversation id"), "{v}");
    let (st, _) = call(&base, TOKEN, "sendMessage", json!({"chat_id": "d:x", "text": "hi", "parse_mode": "BBCode"})).await;
    assert_eq!(st, 400);

    // commands: setMyCommands per scope ↔ the bot profile the SDKs publish
    ok(&base, "setMyCommands", json!({"commands": [{"command": "help", "description": "Help"}, {"command": "price", "description": "Prices"}]})).await;
    ok(&base, "setMyCommands", json!({"commands": [{"command": "ban", "description": "Ban"}], "scope": {"type": "all_group_chats"}})).await;
    let c = ok(&base, "getMyCommands", json!({})).await;
    assert_eq!(c, json!([{"command": "help", "description": "Help"}, {"command": "price", "description": "Prices"}]));
    let c = ok(&base, "getMyCommands", json!({"scope": {"type": "all_group_chats"}})).await;
    assert_eq!(c, json!([{"command": "ban", "description": "Ban"}]));
    let info = bot.store.kv_get_json::<lumora_core::proto::BotInfo>("bot.info").unwrap();
    assert_eq!(info.commands.len(), 2);
    assert_eq!(info.group_commands, vec![("ban".to_string(), "Ban".to_string())]);
    assert_eq!(info.about, "x");
    let (st, _) = call(&base, TOKEN, "setMyCommands", json!({"commands": [{"command": "Bad Cmd!", "description": "x"}]})).await;
    assert_eq!(st, 400);
    ok(&base, "deleteMyCommands", json!({"scope": {"type": "all_private_chats"}})).await;
    assert_eq!(ok(&base, "getMyCommands", json!({})).await, json!([]));
    bot.shutdown();
}

/// A tiny HTTP server: answers the first `fail` requests with 500, then 200; hands every
/// request (head, body) to the test.
async fn hook_server(fail: usize) -> (String, tokio::sync::mpsc::UnboundedReceiver<(String, String)>) {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/hook/path?x=1", l.local_addr().unwrap());
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    tokio::spawn(async move {
        let mut n = 0usize;
        loop {
            let Ok((mut s, _)) = l.accept().await else { break };
            let mut buf = Vec::new();
            let mut tmp = [0u8; 4096];
            let (head, body) = loop {
                let k = s.read(&mut tmp).await.unwrap_or(0);
                if k == 0 {
                    break (String::new(), String::new());
                }
                buf.extend_from_slice(&tmp[..k]);
                let txt = String::from_utf8_lossy(&buf).to_string();
                if let Some(i) = txt.find("\r\n\r\n") {
                    let len = txt[..i]
                        .lines()
                        .find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap_or(0)))
                        .unwrap_or(0);
                    if buf.len() >= i + 4 + len {
                        break (txt[..i].to_string(), String::from_utf8_lossy(&buf[i + 4..i + 4 + len]).to_string());
                    }
                }
            };
            n += 1;
            let resp: &[u8] = if n <= fail { b"HTTP/1.1 500 Oops\r\nContent-Length: 0\r\n\r\n" } else { b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" };
            let _ = s.write_all(resp).await;
            let _ = s.shutdown().await;
            let _ = tx.send((head, body));
        }
    });
    (url, rx)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn webhook_posts_with_secret_and_retries() {
    let tmp = tempfile::tempdir().unwrap();
    let bot = node(tmp.path(), "Hook Bot", false).await;
    let (api, base) = bot_api(&bot, tmp.path()).await;
    let (url, mut rx) = hook_server(2).await;

    let (st, _) = call(&base, TOKEN, "setWebhook", json!({"url": url, "secret_token": "bad secret!"})).await;
    assert_eq!(st, 400);
    ok(&base, "setWebhook", json!({"url": url, "secret_token": "s3cr3t_-X"})).await;
    // webhook and getUpdates are mutually exclusive
    let (st, v) = call(&base, TOKEN, "getUpdates", json!({})).await;
    assert_eq!(st, 409, "{v}");
    assert!(v["description"].as_str().unwrap().starts_with("Conflict:"));

    let t0 = Instant::now();
    let id1 = api.store.push("message", json!({"message_id": "aa", "text": "first"}));
    let id2 = api.store.push("message", json!({"message_id": "bb", "text": "second"}));
    let mut got = Vec::new();
    for _ in 0..4 {
        let (head, body) = tokio::time::timeout(Duration::from_secs(20), rx.recv()).await.expect("webhook POST").unwrap();
        got.push((head, body));
    }
    let elapsed = t0.elapsed();
    for (head, _) in &got {
        assert!(head.starts_with("POST /hook/path?x=1 HTTP/1.1\r\n"), "{head}");
        assert!(head.contains("\r\nX-Lumora-Bot-Secret: s3cr3t_-X"), "{head}");
        assert!(head.to_ascii_lowercase().contains("content-type: application/json"), "{head}");
    }
    let ids: Vec<i64> = got.iter().map(|(_, b)| serde_json::from_str::<Value>(b).unwrap()["update_id"].as_i64().unwrap()).collect();
    // the first update is retried until it's accepted, then the next one: order is kept
    assert_eq!(ids, vec![id1, id1, id1, id2]);
    assert_eq!(serde_json::from_str::<Value>(&got[0].1).unwrap()["message"]["text"], "first");
    // back-off: 1 s then 2 s before the third attempt
    assert!(elapsed >= Duration::from_millis(2900), "retried too fast: {elapsed:?}");
    wait_for("queue drained", 10, || (api.store.lock().pending.is_empty()).then_some(())).await;
    let info = ok(&base, "getWebhookInfo", json!({})).await;
    assert_eq!(info["url"], json!(url));
    assert_eq!(info["pending_update_count"], 0);
    assert!(info["last_error_message"].as_str().unwrap_or("").contains("500"), "{info}");

    // the settings survive a restart of the runner (state file)
    api.store.flush();
    let saved: Value = serde_json::from_slice(&std::fs::read(tmp.path().join("bot_api.json")).unwrap()).unwrap();
    assert_eq!(saved["webhook"]["url"], json!(url));
    assert!(saved["next_update_id"].as_i64().unwrap() > id2);

    // deleteWebhook → getUpdates works again and sees new updates
    ok(&base, "deleteWebhook", json!({})).await;
    let id3 = api.store.push("message", json!({"message_id": "cc", "text": "third"}));
    let u = ok(&base, "getUpdates", json!({"timeout": 1})).await;
    assert_eq!(u.as_array().unwrap().iter().map(|x| x["update_id"].as_i64().unwrap()).collect::<Vec<_>>(), vec![id3]);
    assert_eq!(ok(&base, "getWebhookInfo", json!({})).await["url"], "");
    bot.shutdown();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn messages_both_ways() {
    let tmp = tempfile::tempdir().unwrap();
    let (bd, ud) = (tmp.path().join("bot"), tmp.path().join("user"));
    let bot = node(&bd, "Http Bot", true).await;
    let user = node(&ud, "Người dùng", true).await;
    core(&bot, json!({"cmd": "set_bot", "commands": [], "about": "", "auto_accept": true})).await;
    let (api, base) = bot_api(&bot, &bd).await;
    let bot_peer = bot.me.to_base32();
    let user_peer = user.me.to_base32();

    // the user adds the bot; bots accept by themselves
    core(&user, json!({"cmd": "add_contact", "target": bot_peer})).await;
    let u2 = user.clone();
    let bp = bot.me;
    wait_for("bot accepts the friend request", 60, || (u2.store.contact(&bp).map(|c| c.status) == Some(3)).then_some(())).await;
    let chat = format!("d:{user_peer}");

    // sendMessage (MarkdownV2 + buttons + silent) → the friend receives it
    let m = ok(
        &base,
        "sendMessage",
        json!({"chat_id": chat, "text": "*Xin chào* qua HTTP", "parse_mode": "MarkdownV2", "disable_notification": true,
               "reply_markup": {"inline_keyboard": [[{"text": "Có", "callback_data": "yes"}, {"text": "Web", "url": "https://example.com"}]]}}),
    )
    .await;
    let mid = m["message_id"].as_str().unwrap().to_string();
    assert_eq!(mid.len(), 32);
    assert_eq!(m["chat"]["id"], json!(chat));
    assert_eq!(m["chat"]["type"], "private");
    assert_eq!(m["from"]["id"], json!(bot_peer));
    assert_eq!(m["text"], "**Xin chào** qua HTTP");
    assert_eq!(m["reply_markup"]["inline_keyboard"][0][0]["callback_data"], "yes");
    let bot_conv = format!("d:{bot_peer}");
    let u2 = user.clone();
    let bc = bot_conv.clone();
    let mid2 = mid.clone();
    let got = wait_for("friend receives the message", 60, || {
        u2.store.messages(&bc, None, 20).ok()?.into_iter().find(|x| x.id == mid2)
    })
    .await;
    assert_eq!(got.body["text"], "**Xin chào** qua HTTP");
    assert_eq!(got.meta["silent"], true);
    assert_eq!(got.meta["buttons"][0][1]["url"], "https://example.com");

    // getUpdates long poll, waiting before the message is sent
    let b2 = base.clone();
    let poll = tokio::spawn(async move { ok(&b2, "getUpdates", json!({"timeout": 30})).await });
    tokio::time::sleep(Duration::from_millis(300)).await;
    let sent = core(&user, json!({"cmd": "send_text", "conv": bot_conv, "text": "/start hello", "reply_to": mid})).await;
    let ups = tokio::time::timeout(Duration::from_secs(40), poll).await.expect("long poll answered").unwrap();
    let ups = ups.as_array().unwrap();
    assert_eq!(ups.len(), 1, "{ups:?}");
    let msg = &ups[0]["message"];
    assert_eq!(msg["message_id"], sent["id"]);
    assert_eq!(msg["text"], "/start hello");
    assert_eq!(msg["chat"]["id"], json!(chat));
    assert_eq!(msg["from"]["id"], json!(user_peer));
    assert_eq!(msg["from"]["first_name"], "Người dùng");
    assert_eq!(msg["from"]["is_bot"], false);
    assert_eq!(msg["entities"][0], json!({"type": "bot_command", "offset": 0, "length": 6}));
    assert_eq!(msg["reply_to_message"]["message_id"], json!(mid));
    let first_id = ups[0]["update_id"].as_i64().unwrap();
    // not confirmed yet: returned again; confirmed with offset: gone
    assert_eq!(ok(&base, "getUpdates", json!({})).await.as_array().unwrap().len(), 1);
    assert_eq!(ok(&base, "getUpdates", json!({"offset": first_id + 1})).await, json!([]));

    // a newer getUpdates ends an older one with 409 (only one consumer)
    let b2 = base.clone();
    let older = tokio::spawn(async move { call(&b2, TOKEN, "getUpdates", json!({"timeout": 20, "offset": first_id + 1})).await });
    tokio::time::sleep(Duration::from_millis(300)).await;
    let b3 = base.clone();
    let newer = tokio::spawn(async move { call(&b3, TOKEN, "getUpdates", json!({"timeout": 2, "offset": first_id + 1})).await });
    let (st, v) = tokio::time::timeout(Duration::from_secs(10), older).await.unwrap().unwrap();
    assert_eq!(st, 409, "{v}");
    assert_eq!(tokio::time::timeout(Duration::from_secs(10), newer).await.unwrap().unwrap().0, 200);

    // the user presses the button → callback_query
    core(&user, json!({"cmd": "press_button", "msg_id": m["message_id"], "data": "yes"})).await;
    let a2 = api.clone();
    let cb = wait_for("callback_query update", 30, || {
        a2.store.lock().pending.iter().find(|p| p.kind() == "callback_query").map(|p| p.update.clone())
    })
    .await;
    let q = &cb["callback_query"];
    assert_eq!(q["data"], "yes");
    assert_eq!(q["from"]["id"], json!(user_peer));
    assert_eq!(q["message"]["message_id"], json!(mid));
    assert_eq!(ok(&base, "answerCallbackQuery", json!({"callback_query_id": q["id"], "text": "ok"})).await, json!(true));

    // the user edits their message → edited_message
    core(&user, json!({"cmd": "edit_message", "conv": bot_conv, "msg_id": sent["id"], "text": "/start edited"})).await;
    let a2 = api.clone();
    let ed = wait_for("edited_message update", 30, || {
        a2.store.lock().pending.iter().find(|p| p.kind() == "edited_message").map(|p| p.update.clone())
    })
    .await;
    assert_eq!(ed["edited_message"]["text"], "/start edited");
    assert!(ed["edited_message"]["edit_date"].as_i64().unwrap() > 0);

    // editMessageText / deleteMessage reach the friend
    let e = ok(&base, "editMessageText", json!({"chat_id": chat, "message_id": mid, "text": "<b>Đã sửa</b>", "parse_mode": "HTML"})).await;
    assert_eq!(e["text"], "**Đã sửa**");
    let (st, _) = call(&base, TOKEN, "editMessageText", json!({"chat_id": chat, "message_id": sent["id"], "text": "not mine"})).await;
    assert_eq!(st, 400);
    let u2 = user.clone();
    let mid2 = mid.clone();
    wait_for("friend sees the edit", 30, || {
        let id = hex::decode(&mid2).ok()?;
        u2.store.message(&id).filter(|x| x.body["text"] == "**Đã sửa**").map(|_| ())
    })
    .await;
    assert_eq!(ok(&base, "deleteMessage", json!({"chat_id": chat, "message_id": mid})).await, json!(true));
    let u2 = user.clone();
    wait_for("friend sees the delete", 30, || {
        let id = hex::decode(&mid).ok()?;
        u2.store.message(&id).map(|x| x.deleted).unwrap_or(true).then_some(())
    })
    .await;

    // sendDocument as a multipart upload (+ caption) → a file message for the friend
    let boundary = "lumoraTestBoundary";
    let mut body = Vec::new();
    for (k, v) in [("chat_id", chat.as_str()), ("caption", "Báo cáo")] {
        body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n").as_bytes());
    }
    body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; filename=\"report.txt\"\r\nContent-Type: text/plain\r\n\r\n").as_bytes());
    body.extend_from_slice(b"line 1\nline 2\n");
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    let ct = format!("multipart/form-data; boundary={boundary}");
    let r = http::request("POST", &format!("{base}/bot{TOKEN}/sendDocument"), &[("Content-Type", ct.as_str())], &body, Duration::from_secs(30)).await.unwrap();
    let v: Value = serde_json::from_slice(&r.body).unwrap();
    assert_eq!(r.status, 200, "{v}");
    assert_eq!(v["result"]["document"]["file_name"], "report.txt");
    assert_eq!(v["result"]["caption"], "Báo cáo");
    let u2 = user.clone();
    let bc = bot_conv.clone();
    wait_for("friend gets the file and its caption", 60, || {
        let ms = u2.store.messages(&bc, None, 50).ok()?;
        let f = ms.iter().find(|x| x.kind == "file" && x.body["name"] == "report.txt")?;
        ms.iter().find(|x| x.body["text"] == "Báo cáo" && x.reply_to.as_deref() == Some(f.id.as_str())).map(|_| ())
    })
    .await;
    bot.shutdown();
    user.shutdown();
}
