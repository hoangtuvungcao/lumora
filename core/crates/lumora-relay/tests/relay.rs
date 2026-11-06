//! End-to-end tests: real server on 127.0.0.1:0, real WebSocket clients.

use ed25519_dalek::{Signer, SigningKey};
use futures::{SinkExt, StreamExt};
use lumora_relay::relay_proto::*;
use lumora_relay::Config;
use std::net::SocketAddr;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_tungstenite::tungstenite::Message;

type Ws = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

fn test_cfg() -> Config {
    Config { listen: "127.0.0.1:0".parse().unwrap(), stun_port: 0, ..Config::default() }
}

fn key() -> SigningKey {
    SigningKey::generate(&mut rand::rngs::OsRng)
}

fn pk(k: &SigningKey) -> [u8; 32] {
    k.verifying_key().to_bytes()
}

async fn raw_connect(addr: SocketAddr) -> Ws {
    let (ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}/ws")).await.unwrap();
    ws
}

async fn send(ws: &mut Ws, f: Vec<u8>) {
    ws.send(Message::Binary(f.into())).await.unwrap();
}

/// Next binary frame, or None on close/timeout.
async fn recv(ws: &mut Ws, wait: Duration) -> Option<Vec<u8>> {
    let fut = async {
        loop {
            match ws.next().await {
                Some(Ok(Message::Binary(b))) => return Some(b.to_vec()),
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => return None,
                _ => continue,
            }
        }
    };
    tokio::time::timeout(wait, fut).await.ok().flatten()
}

async fn hello(ws: &mut Ws, k: &SigningKey, ts: u64) {
    let p = pk(k);
    let sig = k.sign(&hello_message(&p, ts)).to_bytes();
    send(ws, encode_hello(&p, ts, &sig)).await;
}

/// Connect + HELLO + expect WELCOME.
async fn connect(addr: SocketAddr, k: &SigningKey) -> Ws {
    let mut ws = raw_connect(addr).await;
    hello(&mut ws, k, now_ms()).await;
    let w = recv(&mut ws, Duration::from_secs(5)).await.expect("welcome");
    assert_eq!(w[0], T_WELCOME, "got {:?}", String::from_utf8_lossy(&w[1..]));
    assert!(String::from_utf8_lossy(&w[1..]).starts_with("127.0.0.1:"));
    ws
}

async fn http_get(addr: SocketAddr, path: &str) -> String {
    let mut s = tokio::net::TcpStream::connect(addr).await.unwrap();
    s.write_all(format!("GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
    let mut out = String::new();
    s.read_to_string(&mut out).await.unwrap();
    out
}

#[tokio::test]
async fn forwards_data_and_signal() {
    let relay = lumora_relay::start(test_cfg()).await.unwrap();
    let (ka, kb) = (key(), key());
    let mut a = connect(relay.addr, &ka).await;
    let mut b = connect(relay.addr, &kb).await;

    send(&mut a, encode_peer_frame(T_DATA, &pk(&kb), b"quic-datagram")).await;
    let f = recv(&mut b, Duration::from_secs(5)).await.unwrap();
    let (t, peer, payload) = decode_peer_frame(&f).unwrap();
    assert_eq!((t, peer, payload), (T_DATA, pk(&ka), &b"quic-datagram"[..]));

    send(&mut b, encode_peer_frame(T_SIGNAL, &pk(&ka), b"sealed")).await;
    let f = recv(&mut a, Duration::from_secs(5)).await.unwrap();
    let (t, peer, payload) = decode_peer_frame(&f).unwrap();
    assert_eq!((t, peer, payload), (T_SIGNAL, pk(&kb), &b"sealed"[..]));

    let h = http_get(relay.addr, "/health").await;
    assert!(h.contains("200 OK") && h.contains("\"clients\":2"), "{h}");
    assert!(http_get(relay.addr, "/").await.contains("Lumora relay"));
    relay.shutdown().await;
}

#[tokio::test]
async fn gone_for_absent_peer_is_rate_limited() {
    let relay = lumora_relay::start(test_cfg()).await.unwrap();
    let ka = key();
    let ghost = pk(&key());
    let mut a = connect(relay.addr, &ka).await;
    for _ in 0..5 {
        send(&mut a, encode_peer_frame(T_DATA, &ghost, b"x")).await;
    }
    let f = recv(&mut a, Duration::from_secs(5)).await.unwrap();
    assert_eq!(f[0], T_GONE);
    assert_eq!(&f[1..33], &ghost);
    assert!(recv(&mut a, Duration::from_millis(300)).await.is_none(), "only one GONE per second");
    relay.shutdown().await;
}

#[tokio::test]
async fn mailbox_delivers_on_reconnect() {
    let relay = lumora_relay::start(test_cfg()).await.unwrap();
    let (ka, kb) = (key(), key());
    let mut a = connect(relay.addr, &ka).await;
    send(&mut a, encode_peer_frame(T_SIGNAL, &pk(&kb), b"offer-1")).await;
    send(&mut a, encode_peer_frame(T_SIGNAL, &pk(&kb), b"offer-2")).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let mut b = connect(relay.addr, &kb).await;
    for want in [&b"offer-1"[..], b"offer-2"] {
        let f = recv(&mut b, Duration::from_secs(5)).await.unwrap();
        let (t, peer, payload) = decode_peer_frame(&f).unwrap();
        assert_eq!((t, peer, payload), (T_SIGNAL, pk(&ka), want));
    }
    // delivered once only
    drop(b);
    tokio::time::sleep(Duration::from_millis(200)).await;
    let mut b = connect(relay.addr, &kb).await;
    assert!(recv(&mut b, Duration::from_millis(300)).await.is_none());
    relay.shutdown().await;
}

#[tokio::test]
async fn bad_hello_rejected() {
    let relay = lumora_relay::start(test_cfg()).await.unwrap();
    let k = key();
    // wrong signature
    let mut ws = raw_connect(relay.addr).await;
    let ts = now_ms();
    let sig = key().sign(&hello_message(&pk(&k), ts)).to_bytes();
    send(&mut ws, encode_hello(&pk(&k), ts, &sig)).await;
    let f = recv(&mut ws, Duration::from_secs(5)).await.unwrap();
    assert_eq!(f[0], T_ERROR);
    assert!(recv(&mut ws, Duration::from_secs(5)).await.is_none(), "connection closed");

    // stale timestamp
    let mut ws = raw_connect(relay.addr).await;
    hello(&mut ws, &k, now_ms() - 10 * 60 * 1000).await;
    assert_eq!(recv(&mut ws, Duration::from_secs(5)).await.unwrap()[0], T_ERROR);

    // replay of the same (pubkey, ts)
    let ts = now_ms();
    let mut ws = raw_connect(relay.addr).await;
    hello(&mut ws, &k, ts).await;
    assert_eq!(recv(&mut ws, Duration::from_secs(5)).await.unwrap()[0], T_WELCOME);
    let mut ws2 = raw_connect(relay.addr).await;
    hello(&mut ws2, &k, ts).await;
    let f = recv(&mut ws2, Duration::from_secs(5)).await.unwrap();
    assert_eq!(f[0], T_ERROR);
    assert_eq!(&f[1..], b"replayed HELLO");

    // data before HELLO
    let mut ws = raw_connect(relay.addr).await;
    send(&mut ws, encode_peer_frame(T_DATA, &pk(&k), b"x")).await;
    assert_eq!(recv(&mut ws, Duration::from_secs(5)).await.unwrap()[0], T_ERROR);
    relay.shutdown().await;
}

#[tokio::test]
async fn new_connection_replaces_old() {
    let relay = lumora_relay::start(test_cfg()).await.unwrap();
    let (ka, kb) = (key(), key());
    let mut a1 = connect(relay.addr, &ka).await;
    tokio::time::sleep(Duration::from_millis(5)).await; // distinct HELLO timestamp
    let mut a2 = connect(relay.addr, &ka).await;
    let f = recv(&mut a1, Duration::from_secs(5)).await.unwrap();
    assert_eq!(f[0], T_ERROR);
    assert!(recv(&mut a1, Duration::from_secs(5)).await.is_none());
    let mut b = connect(relay.addr, &kb).await;
    send(&mut b, encode_peer_frame(T_DATA, &pk(&ka), b"hi")).await;
    let f = recv(&mut a2, Duration::from_secs(5)).await.unwrap();
    assert_eq!(&f[33..], b"hi");
    relay.shutdown().await;
}

#[tokio::test]
async fn rate_limit_drops_data() {
    let cfg = Config { bandwidth: 2000, burst: 2000, max_frame: 1024, ..test_cfg() };
    let relay = lumora_relay::start(cfg).await.unwrap();
    let (ka, kb) = (key(), key());
    let mut a = connect(relay.addr, &ka).await;
    let mut b = connect(relay.addr, &kb).await;
    let payload = vec![0u8; 467]; // 500-byte frames
    for _ in 0..50 {
        send(&mut a, encode_peer_frame(T_DATA, &pk(&kb), &payload)).await;
    }
    let mut got = 0;
    while recv(&mut b, Duration::from_millis(500)).await.is_some() {
        got += 1;
    }
    assert!((3..=8).contains(&got), "got {got} of 50 frames");
    // oversized frames are refused with ERROR, not forwarded
    send(&mut a, encode_peer_frame(T_DATA, &pk(&kb), &vec![0u8; 1500])).await;
    assert_eq!(recv(&mut a, Duration::from_secs(5)).await.unwrap()[0], T_ERROR);
    relay.shutdown().await;
}

#[tokio::test]
async fn signal_rate_limit_reports_error() {
    let cfg = Config { signal_rate: 2.0, ..test_cfg() };
    let relay = lumora_relay::start(cfg).await.unwrap();
    let (ka, kb) = (key(), key());
    let mut a = connect(relay.addr, &ka).await;
    let mut b = connect(relay.addr, &kb).await;
    for _ in 0..10 {
        send(&mut a, encode_peer_frame(T_SIGNAL, &pk(&kb), b"s")).await;
    }
    let f = recv(&mut a, Duration::from_secs(5)).await.unwrap();
    assert_eq!(f[0], T_ERROR);
    let mut got = 0;
    while recv(&mut b, Duration::from_millis(300)).await.is_some() {
        got += 1;
    }
    assert!((4..=5).contains(&got), "got {got}");
    relay.shutdown().await;
}

#[tokio::test]
async fn private_mode_allow_list() {
    let (ka, kb) = (key(), key());
    let path = std::env::temp_dir().join(format!("lumora-allow-{}", std::process::id()));
    std::fs::write(&path, format!("# allowed\n{}\n", hex::encode(pk(&ka)))).unwrap();
    let relay = lumora_relay::start(Config { allow: Some(path.clone()), ..test_cfg() }).await.unwrap();
    let _a = connect(relay.addr, &ka).await;
    let mut b = raw_connect(relay.addr).await;
    hello(&mut b, &kb, now_ms()).await;
    let f = recv(&mut b, Duration::from_secs(5)).await.unwrap();
    assert_eq!(f[0], T_ERROR);
    relay.shutdown().await;
    let _ = std::fs::remove_file(path);
}

#[tokio::test]
async fn stun_binding_response() {
    let port = std::net::UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let relay = lumora_relay::start(Config { stun_port: port, stun_bind: [127, 0, 0, 1].into(), ..test_cfg() }).await.unwrap();
    let stun = relay.stun_addr.unwrap();
    let sock = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let me = sock.local_addr().unwrap();
    let tx = [7u8; 12];
    let mut req = vec![0, 1, 0, 0, 0x21, 0x12, 0xA4, 0x42];
    req.extend_from_slice(&tx);
    sock.send_to(&req, stun).await.unwrap();
    let mut buf = [0u8; 256];
    let (n, _) = tokio::time::timeout(Duration::from_secs(5), sock.recv_from(&mut buf)).await.unwrap().unwrap();
    let r = &buf[..n];
    assert_eq!(&r[0..2], &[0x01, 0x01]);
    assert_eq!(&r[8..20], &tx);
    assert_eq!(&r[20..22], &[0x00, 0x20]); // XOR-MAPPED-ADDRESS
    let port = u16::from_be_bytes([r[26], r[27]]) ^ 0x2112;
    let ip = u32::from_be_bytes([r[28], r[29], r[30], r[31]]) ^ 0x2112_A442;
    assert_eq!(SocketAddr::from((std::net::Ipv4Addr::from(ip), port)), me);
    relay.shutdown().await;
}
