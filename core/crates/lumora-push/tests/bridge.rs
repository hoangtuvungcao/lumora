//! Bridge ⇄ mock APNs (HTTP/2 cleartext) integration tests.
#![cfg(feature = "server")]

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;

use axum::http::StatusCode;
use lumora_push::apns::{ApnsClient, ApnsConfig};
use lumora_push::server::{Bridge, BridgeConfig, Limits, Rate};
use lumora_push::*;
use parking_lot::Mutex;
use ring::rand::SystemRandom;
use ring::signature::{EcdsaKeyPair, KeyPair as _, UnparsedPublicKey, ECDSA_P256_SHA256_FIXED, ECDSA_P256_SHA256_FIXED_SIGNING};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const TOPIC: &str = "vn.lumora.lumora";
const DEAD_DEVICE: &str = "dead00dead00dead00dead00dead00dead00dead00dead00dead00dead00dead";

#[derive(Clone, Debug)]
struct Seen {
    path: String,
    headers: Vec<(String, String)>,
    body: serde_json::Value,
}

impl Seen {
    fn h(&self, k: &str) -> String {
        self.headers.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone()).unwrap_or_default()
    }
}

/// Mock APNs: records every request; answers 410 for DEAD_DEVICE, 200 otherwise.
async fn mock_apns() -> (String, Arc<Mutex<Vec<Seen>>>) {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", l.local_addr().unwrap());
    let s2 = seen.clone();
    tokio::spawn(async move {
        loop {
            let Ok((tcp, _)) = l.accept().await else { return };
            let seen = s2.clone();
            tokio::spawn(async move {
                let mut conn = h2::server::handshake(tcp).await.unwrap();
                while let Some(Ok((req, mut respond))) = conn.accept().await {
                    let (parts, mut body) = req.into_parts();
                    let mut data = Vec::new();
                    while let Some(c) = body.data().await {
                        let c = c.unwrap();
                        let _ = body.flow_control().release_capacity(c.len());
                        data.extend_from_slice(&c);
                    }
                    let path = parts.uri.path().to_string();
                    let headers = parts.headers.iter().map(|(k, v)| (k.to_string(), v.to_str().unwrap_or("").to_string())).collect();
                    seen.lock().push(Seen { path: path.clone(), headers, body: serde_json::from_slice(&data).unwrap_or_default() });
                    let (status, reason) = if path.ends_with(DEAD_DEVICE) { (410, "Unregistered") } else { (200, "") };
                    let resp = http::Response::builder().status(status).body(()).unwrap();
                    let mut stream = respond.send_response(resp, reason.is_empty()).unwrap();
                    if !reason.is_empty() {
                        stream.send_data(bytes::Bytes::from(format!("{{\"reason\":\"{reason}\"}}")), true).unwrap();
                    }
                }
            });
        }
    });
    (url, seen)
}

struct Fixture {
    bridge: Arc<Bridge>,
    keypair: KeyPair,
    seen: Arc<Mutex<Vec<Seen>>>,
    apns_pub: Vec<u8>,
}

async fn fixture(limits: Limits) -> Fixture {
    let (url, seen) = mock_apns().await;
    let rng = SystemRandom::new();
    let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
    let apns_pub = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap().public_key().as_ref().to_vec();
    let apns = ApnsClient::new(ApnsConfig {
        production_url: url.clone(),
        sandbox_url: url,
        key_id: "ABCDE12345".into(),
        team_id: "TEAM123456".into(),
        key_pkcs8: Some(pkcs8.as_ref().to_vec()),
        dry_run_log: None,
    })
    .unwrap();
    let keypair = KeyPair::generate();
    let bridge = Bridge::new(BridgeConfig { keypair: keypair.clone(), topics: vec![TOPIC.into()], limits, dead_file: None, gen_file: None, trust_proxy: false }, apns);
    Fixture { bridge, keypair, seen, apns_pub }
}

fn sealed(f: &Fixture, apns: &str, voip: &str, topic: &str) -> String {
    b64(&seal_token(&f.keypair.public, &DeviceToken { apns: apns.into(), voip: voip.into(), topic: topic.into(), ..Default::default() }))
}

fn sealed_gen(f: &Fixture, apns: &str, voip: &str, gen: u64, exp: u64) -> String {
    b64(&seal_token(&f.keypair.public, &DeviceToken { apns: apns.into(), voip: voip.into(), topic: TOPIC.into(), gen, exp, ..Default::default() }))
}

fn unix_now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
}

const IP: IpAddr = IpAddr::V4(Ipv4Addr::LOCALHOST);

#[tokio::test]
async fn message_wake_is_a_content_free_alert_with_a_valid_jwt() {
    let f = fixture(Limits::default()).await;
    let recipient = KeyPair::generate();
    let e2e = seal_notify(&recipient.public, &Notify { k: "msg".into(), from: "alice".into(), name: "Alice".into(), preview: "bí mật".into(), ..Default::default() });
    let device = "aa".repeat(32);
    let req = WakeRequest { token: sealed(&f, &device, "", TOPIC), kind: "msg".into(), e2e: b64(&e2e) };
    assert_eq!(f.bridge.wake(IP, &req).await, (StatusCode::ACCEPTED, "ok"));

    let seen = f.seen.lock().clone();
    assert_eq!(seen.len(), 1);
    let s = &seen[0];
    assert_eq!(s.path, format!("/3/device/{device}"));
    assert_eq!(s.h("apns-topic"), TOPIC);
    assert_eq!(s.h("apns-push-type"), "alert");
    assert_eq!(s.h("apns-priority"), "10");
    assert_eq!(s.body["aps"]["alert"]["loc-key"], "PUSH_NEW_MESSAGE");
    assert_eq!(s.body["aps"]["mutable-content"], 1);
    // no plaintext anywhere in the push; the e2e blob is forwarded untouched
    let raw = s.body.to_string();
    assert!(!raw.contains("bí mật") && !raw.contains("Alice"), "{raw}");
    let blob = unb64(s.body["lumora"]["e2e"].as_str().unwrap()).unwrap();
    assert_eq!(open_notify(&recipient, &blob).unwrap().preview, "bí mật");

    // provider JWT: ES256 over header.claims, verifiable with the .p8 public key
    let auth = s.h("authorization");
    let jwt = auth.strip_prefix("bearer ").expect("bearer token");
    let parts: Vec<&str> = jwt.split('.').collect();
    assert_eq!(parts.len(), 3);
    let header: serde_json::Value = serde_json::from_slice(&data_encoding::BASE64URL_NOPAD.decode(parts[0].as_bytes()).unwrap()).unwrap();
    let claims: serde_json::Value = serde_json::from_slice(&data_encoding::BASE64URL_NOPAD.decode(parts[1].as_bytes()).unwrap()).unwrap();
    assert_eq!(header["alg"], "ES256");
    assert_eq!(header["kid"], "ABCDE12345");
    assert_eq!(claims["iss"], "TEAM123456");
    let sig = data_encoding::BASE64URL_NOPAD.decode(parts[2].as_bytes()).unwrap();
    UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, &f.apns_pub)
        .verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &sig)
        .expect("JWT signature verifies");
}

#[tokio::test]
async fn call_wake_uses_pushkit_voip_or_falls_back_to_alert() {
    let f = fixture(Limits::default()).await;
    let (apns, voip) = ("bb".repeat(32), "cc".repeat(32));
    let r = f.bridge.wake(IP, &WakeRequest { token: sealed(&f, &apns, &voip, TOPIC), kind: "call".into(), e2e: String::new() }).await;
    assert_eq!(r.0, StatusCode::ACCEPTED);
    let r = f.bridge.wake(IP, &WakeRequest { token: sealed(&f, &apns, "", TOPIC), kind: "call".into(), e2e: String::new() }).await;
    assert_eq!(r.0, StatusCode::ACCEPTED);
    let seen = f.seen.lock().clone();
    assert_eq!(seen[0].path, format!("/3/device/{voip}"));
    assert_eq!(seen[0].h("apns-topic"), format!("{TOPIC}.voip"));
    assert_eq!(seen[0].h("apns-push-type"), "voip");
    assert_eq!(seen[0].h("apns-expiration"), "0");
    assert_eq!(seen[1].path, format!("/3/device/{apns}"));
    assert_eq!(seen[1].h("apns-push-type"), "alert");
    assert_eq!(seen[1].body["aps"]["alert"]["loc-key"], "PUSH_INCOMING_CALL");
}

#[tokio::test]
async fn unregistered_token_is_dropped_and_never_sent_again() {
    let f = fixture(Limits::default()).await;
    let req = WakeRequest { token: sealed(&f, DEAD_DEVICE, "", TOPIC), kind: "msg".into(), e2e: String::new() };
    assert_eq!(f.bridge.wake(IP, &req).await, (StatusCode::GONE, "unregistered"));
    assert_eq!(f.seen.lock().len(), 1);
    // a fresh seal of the same token (unlinkable bytes) is still recognised as dead
    let req2 = WakeRequest { token: sealed(&f, DEAD_DEVICE, "", TOPIC), kind: "msg".into(), e2e: String::new() };
    assert_eq!(f.bridge.wake(IP, &req2).await, (StatusCode::GONE, "unregistered"));
    assert_eq!(f.seen.lock().len(), 1, "APNs must not be contacted for a dead token");
}

#[tokio::test]
async fn rate_limits_per_device_and_per_ip() {
    let limits = Limits { msg: Rate { burst: 2.0, every_secs: 1000.0 }, call: Rate { burst: 1.0, every_secs: 1000.0 }, ip: Rate { burst: 100.0, every_secs: 1.0 }, ..Limits::default() };
    let f = fixture(limits).await;
    let tok = sealed(&f, &"dd".repeat(32), "", TOPIC);
    let req = WakeRequest { token: tok.clone(), kind: "msg".into(), e2e: String::new() };
    assert_eq!(f.bridge.wake(IP, &req).await.0, StatusCode::ACCEPTED);
    assert_eq!(f.bridge.wake(IP, &req).await.0, StatusCode::ACCEPTED);
    assert_eq!(f.bridge.wake(IP, &req).await, (StatusCode::TOO_MANY_REQUESTS, "rate_limited"));
    // other devices are unaffected
    let other = WakeRequest { token: sealed(&f, &"ee".repeat(32), "", TOPIC), kind: "msg".into(), e2e: String::new() };
    assert_eq!(f.bridge.wake(IP, &other).await.0, StatusCode::ACCEPTED);
    assert_eq!(f.seen.lock().len(), 3);

    let limits = Limits { ip: Rate { burst: 2.0, every_secs: 1000.0 }, ..Limits::default() };
    let f = fixture(limits).await;
    let req = WakeRequest { token: sealed(&f, &"ff".repeat(32), "", TOPIC), kind: "msg".into(), e2e: String::new() };
    assert_eq!(f.bridge.wake(IP, &req).await.0, StatusCode::ACCEPTED);
    assert_eq!(f.bridge.wake(IP, &req).await.0, StatusCode::ACCEPTED);
    assert_eq!(f.bridge.wake(IP, &req).await.0, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(f.bridge.wake(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 9)), &req).await.0, StatusCode::ACCEPTED);
}

#[tokio::test]
async fn rejects_garbage_foreign_apps_and_oversized_payloads() {
    let f = fixture(Limits::default()).await;
    let bad = |token: String, kind: &str, e2e: String| WakeRequest { token, kind: kind.into(), e2e };
    assert_eq!(f.bridge.wake(IP, &bad("!!!".into(), "msg", String::new())).await.1, "bad_token");
    assert_eq!(f.bridge.wake(IP, &bad(b64(&[7u8; 80]), "msg", String::new())).await.1, "bad_token");
    // sealed to a different bridge
    let other = KeyPair::generate();
    let t = b64(&seal_token(&other.public, &DeviceToken { apns: "aa".repeat(32), topic: TOPIC.into(), ..Default::default() }));
    assert_eq!(f.bridge.wake(IP, &bad(t, "msg", String::new())).await.1, "bad_token");
    assert_eq!(f.bridge.wake(IP, &bad(sealed(&f, &"aa".repeat(32), "", "com.evil.app"), "msg", String::new())).await, (StatusCode::FORBIDDEN, "wrong_app"));
    assert_eq!(f.bridge.wake(IP, &bad(sealed(&f, "not-hex", "", TOPIC), "msg", String::new())).await.1, "bad_token");
    assert_eq!(f.bridge.wake(IP, &bad(sealed(&f, &"aa".repeat(32), "", TOPIC), "spam", String::new())).await.1, "bad_kind");
    assert_eq!(f.bridge.wake(IP, &bad(sealed(&f, &"aa".repeat(32), "", TOPIC), "msg", b64(&vec![0u8; MAX_E2E + 1]))).await.1, "bad_e2e");
    assert!(f.seen.lock().is_empty());
}

async fn http(addr: SocketAddr, raw: String) -> (u16, serde_json::Value) {
    let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
    s.write_all(raw.as_bytes()).await.unwrap();
    let mut out = Vec::new();
    s.read_to_end(&mut out).await.unwrap();
    let text = String::from_utf8_lossy(&out).to_string();
    let status = text.split_whitespace().nth(1).unwrap().parse().unwrap();
    let body = text.split("\r\n\r\n").nth(1).unwrap_or("");
    (status, serde_json::from_str(body.trim()).unwrap_or_default())
}

#[tokio::test]
async fn http_endpoints() {
    let f = fixture(Limits::default()).await;
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(lumora_push::server::serve(l, f.bridge.clone()));
    let (st, v) = http(addr, "GET /pubkey HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".into()).await;
    assert_eq!(st, 200);
    assert_eq!(key32(v["public_key"].as_str().unwrap()).unwrap(), f.keypair.public);
    let body = serde_json::to_string(&WakeRequest { token: sealed(&f, &"ab".repeat(32), "", TOPIC), kind: "msg".into(), e2e: String::new() }).unwrap();
    let (st, v) = http(addr, format!("POST /wake HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len())).await;
    assert_eq!((st, v["code"].as_str().unwrap()), (202, "ok"));
    let body = serde_json::to_string(&RegisterRequest { token: sealed_gen(&f, &"ab".repeat(32), "", 7, unix_now() + 60) }).unwrap();
    let (st, v) = http(addr, format!("POST /register HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len())).await;
    assert_eq!((st, v["code"].as_str().unwrap()), (202, "ok"));
    let (st, _) = http(addr, "POST /wake HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nConnection: close\r\n\r\n{x}".into()).await;
    assert_eq!(st, 400);
    let (st, v) = http(addr, "GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".into()).await;
    assert_eq!((st, v["accepted"].as_u64()), (200, Some(1)));
    assert_eq!(v["registered"].as_u64(), Some(1));
    assert_eq!(f.seen.lock().len(), 1);
}

#[tokio::test]
async fn expired_tokens_are_refused_and_fresh_ones_work() {
    let f = fixture(Limits::default()).await;
    let device = "a7".repeat(32);
    let old = WakeRequest { token: sealed_gen(&f, &device, "", 1, unix_now() - 10), kind: "msg".into(), e2e: String::new() };
    assert_eq!(f.bridge.wake(IP, &old).await, (StatusCode::GONE, "expired"));
    assert!(f.seen.lock().is_empty(), "APNs must not be contacted for an expired token");
    // the device itself is fine: a refreshed copy (same generation) works
    let fresh = WakeRequest { token: sealed_gen(&f, &device, "", 1, unix_now() + TOKEN_TTL_SECS), kind: "msg".into(), e2e: String::new() };
    assert_eq!(f.bridge.wake(IP, &fresh).await, (StatusCode::ACCEPTED, "ok"));
    // tokens from older apps (no expiry, no generation) keep working
    let legacy = WakeRequest { token: sealed(&f, &"a8".repeat(32), "", TOPIC), kind: "msg".into(), e2e: String::new() };
    assert_eq!(f.bridge.wake(IP, &legacy).await.0, StatusCode::ACCEPTED);
    assert_eq!(f.bridge.stats.lock().expired, 1);
}

#[tokio::test]
async fn re_registering_revokes_older_tokens_and_survives_restart() {
    let dir = std::env::temp_dir().join(format!("lumora-push-gen-{}", rand::random::<u64>()));
    std::fs::create_dir_all(&dir).unwrap();
    let gen_file = dir.join("generations.txt");
    let mut f = fixture(Limits::default()).await;
    let apns = ApnsClient::new(ApnsConfig {
        production_url: "http://127.0.0.1:9".into(),
        sandbox_url: "http://127.0.0.1:9".into(),
        key_id: String::new(),
        team_id: String::new(),
        key_pkcs8: None,
        dry_run_log: Some(dir.join("dry.log")),
    })
    .unwrap();
    let cfg = |kp: &KeyPair| BridgeConfig { keypair: kp.clone(), topics: vec![TOPIC.into()], limits: Limits::default(), dead_file: None, gen_file: Some(gen_file.clone()), trust_proxy: false };
    f.bridge = Bridge::new(cfg(&f.keypair), apns);
    let (device, voip) = ("c1".repeat(32), "c2".repeat(32));
    let exp = unix_now() + TOKEN_TTL_SECS;
    let old_tok = sealed_gen(&f, &device, &voip, 1000, exp);
    let wake = |t: &str, kind: &str| WakeRequest { token: t.into(), kind: kind.into(), e2e: String::new() };
    assert_eq!(f.bridge.wake(IP, &wake(&old_tok, "msg")).await, (StatusCode::ACCEPTED, "ok"));
    // the phone re-registers (generation 2000) and tells the bridge
    let new_tok = sealed_gen(&f, &device, &voip, 2000, exp);
    assert_eq!(f.bridge.register(IP, &RegisterRequest { token: new_tok.clone() }), (StatusCode::ACCEPTED, "ok"));
    // every copy of the old token is now refused — message and call wakes alike
    assert_eq!(f.bridge.wake(IP, &wake(&old_tok, "msg")).await, (StatusCode::GONE, "revoked"));
    assert_eq!(f.bridge.wake(IP, &wake(&old_tok, "call")).await, (StatusCode::GONE, "revoked"));
    // a legacy (generation-less) token of the same device is superseded too
    assert_eq!(f.bridge.wake(IP, &wake(&sealed(&f, &device, "", TOPIC), "msg")).await.1, "revoked");
    assert_eq!(f.bridge.wake(IP, &wake(&new_tok, "msg")).await, (StatusCode::ACCEPTED, "ok"));
    // replaying an old token at /register changes nothing
    assert_eq!(f.bridge.register(IP, &RegisterRequest { token: old_tok.clone() }).1, "revoked");
    assert_eq!(f.bridge.wake(IP, &wake(&new_tok, "call")).await.0, StatusCode::ACCEPTED);

    // unregister = a newer generation that is already expired: revokes everything
    let unreg = sealed_gen(&f, &device, &voip, 3000, 1);
    assert_eq!(f.bridge.register(IP, &RegisterRequest { token: unreg }), (StatusCode::GONE, "expired"));
    assert_eq!(f.bridge.wake(IP, &wake(&new_tok, "msg")).await.1, "revoked");

    // a restarted bridge still remembers
    let apns2 = ApnsClient::new(ApnsConfig {
        production_url: "http://127.0.0.1:9".into(),
        sandbox_url: "http://127.0.0.1:9".into(),
        key_id: String::new(),
        team_id: String::new(),
        key_pkcs8: None,
        dry_run_log: Some(dir.join("dry.log")),
    })
    .unwrap();
    let b2 = Bridge::new(cfg(&f.keypair), apns2);
    assert_eq!(b2.wake(IP, &wake(&new_tok, "msg")).await.1, "revoked");
    let newest = sealed_gen(&f, &device, "", 4000, exp);
    assert_eq!(b2.wake(IP, &wake(&newest, "msg")).await, (StatusCode::ACCEPTED, "ok"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn call_wakes_are_capped_per_minute_per_hour_and_per_sender() {
    let exp = unix_now() + TOKEN_TTL_SECS;
    let call = |t: &str| WakeRequest { token: t.into(), kind: "call".into(), e2e: String::new() };
    let other_ip = |i: u8| IpAddr::V4(Ipv4Addr::new(10, 0, 0, i));

    // defaults: one sender gets 2 rings, then must wait; other senders share the device's 3
    let f = fixture(Limits::default()).await;
    let tok = sealed_gen(&f, &"d1".repeat(32), &"d2".repeat(32), 1, exp);
    assert_eq!(f.bridge.wake(IP, &call(&tok)).await.0, StatusCode::ACCEPTED);
    assert_eq!(f.bridge.wake(IP, &call(&tok)).await.0, StatusCode::ACCEPTED);
    assert_eq!(f.bridge.wake(IP, &call(&tok)).await, (StatusCode::TOO_MANY_REQUESTS, "rate_limited"));
    assert_eq!(f.bridge.wake(other_ip(1), &call(&tok)).await.0, StatusCode::ACCEPTED);
    assert_eq!(f.bridge.wake(other_ip(2), &call(&tok)).await.0, StatusCode::TOO_MANY_REQUESTS, "device minute budget");
    // message wakes have their own budget
    let msg = WakeRequest { token: tok.clone(), kind: "msg".into(), e2e: String::new() };
    assert_eq!(f.bridge.wake(other_ip(2), &msg).await.0, StatusCode::ACCEPTED);
    assert!(Limits::default().call_hour.burst <= 20.0 && Limits::default().call.every_secs >= 20.0);

    // the hourly cap holds even when the short-term bucket would allow more
    let limits = Limits {
        call: Rate { burst: 100.0, every_secs: 0.001 },
        call_sender: Rate { burst: 100.0, every_secs: 0.001 },
        call_hour: Rate { burst: 4.0, every_secs: 1000.0 },
        ..Limits::default()
    };
    let f = fixture(limits).await;
    let tok = sealed_gen(&f, &"e1".repeat(32), &"e2".repeat(32), 1, exp);
    for i in 0..4 {
        assert_eq!(f.bridge.wake(other_ip(i), &call(&tok)).await.0, StatusCode::ACCEPTED, "{i}");
    }
    assert_eq!(f.bridge.wake(other_ip(9), &call(&tok)).await.0, StatusCode::TOO_MANY_REQUESTS);
    // a refused ring took nothing from the other buckets
    assert_eq!(f.seen.lock().len(), 4);
}
