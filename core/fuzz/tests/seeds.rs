//! Writes a starting corpus of VALID inputs to `corpus/<target>/` (structure the fuzzer would
//! otherwise need a long time to discover). Run once before fuzzing:
//! `cargo test --release --test seeds -- --ignored`

use data_encoding::BASE32_NOPAD;
use lumora_core::devices::{DeviceCert, DeviceListBody, LinkQr, SignedDeviceList, Signer};
use lumora_core::file_preview::FilePreview;
use lumora_core::group;
use lumora_core::identity::{Identity, PeerId};
use lumora_core::net::{relay_proto, stun};
use lumora_core::proto::*;
use std::path::Path;

fn save(target: &str, items: Vec<Vec<u8>>) {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("corpus").join(target);
    std::fs::create_dir_all(&dir).unwrap();
    for (i, b) in items.into_iter().enumerate() {
        std::fs::write(dir.join(format!("seed-{i:03}")), b).unwrap();
    }
}

fn frame(m: &PeerMsg) -> Vec<u8> {
    let b = rmp_serde::to_vec(m).unwrap();
    let mut v = (b.len() as u32).to_be_bytes().to_vec();
    v.extend(b);
    v
}

#[test]
#[ignore]
fn write_seeds() {
    let a = Identity::from_secret(&[1; 32]);
    let p = a.peer_id();
    let chat = |body: Body| ChatMsg { id: [1; 16], author: p, hlc: 42, body, reply_to: Some([2; 16]), ttl_ms: Some(5), meta: MsgMeta { mentions: vec![p], mention_all: true, silent: true, forwarded_from: Some("x".into()), buttons: vec![] }, sig: vec![9; 64] };
    let bodies = vec![
        Body::Text { text: "chào".into() },
        Body::File { file_id: [3; 16], name: "a.txt".into(), size: 9, mime: "text/plain".into(), hash: [4; 32], thumb: FilePreview { kind: "text".into(), text: "hi".into(), pages: 1, lines: 2, img: vec![] }.encode(), width: 1, height: 2 },
        Body::Sticker { pack: "p".into(), id: "s".into(), hash: [5; 32], mime: "image/png".into(), data: b"\x89PNG\r\n\x1a\n".to_vec(), emoji: "😀".into(), animated: false },
        Body::Voice { file_id: [6; 16], duration_ms: 1000, size: 10, hash: [7; 32], wave: vec![1, 2, 3] },
        Body::Location { lat: 1.5, lon: 2.5, accuracy_m: 3.0, label: "l".into(), live_until: 9 },
        Body::Contact { peer: p, name: "n".into() },
        Body::Call { video: true, duration_s: 5, missed: false },
        Body::System { text: "s".into() },
        Body::Poll { question: "q".into(), options: vec!["a".into(), "b".into()] },
        Body::Checklist { title: "t".into(), items: vec![CheckItem { id: 1, text: "x".into() }] },
        Body::Reminder { title: "r".into(), at_ms: 5, note: "n".into() },
    ];
    let mut msgs: Vec<PeerMsg> = bodies.into_iter().map(|b| PeerMsg::Chat(chat(b))).collect();
    msgs.extend([
        PeerMsg::Hello { version: 3, name: "An".into(), app: "lumora/0.1.0".into(), os: "linux".into() },
        PeerMsg::Wrapped { id: [2; 16], inner: Box::new(PeerMsg::Ack { ids: vec![[3; 16]] }) },
        PeerMsg::Wrapped { id: [2; 16], inner: Box::new(PeerMsg::Wrapped { id: [2; 16], inner: Box::new(PeerMsg::Ping { t: 1 }) }) },
        PeerMsg::GroupSync { gid: [4; 16], heads: vec![(p, 5)] },
        PeerMsg::Action { id: [5; 16], author: p, hlc: 6, action: MsgAction::React { target: [6; 16], emoji: "👍".into(), on: true }, sig: vec![1; 64] },
        PeerMsg::Action { id: [5; 16], author: p, hlc: 6, action: MsgAction::ChecklistAdd { target: [6; 16], items: vec![CheckItem { id: 2, text: "y".into() }] }, sig: vec![1; 64] },
        PeerMsg::FriendRequest { name: "n".into(), note: "hi".into() },
        PeerMsg::ProfileV2 { name: "n".into(), bio: "b".into(), status: "s".into(), bot: None, username: "u".into(), avatar: vec![1], cover: vec![] },
        PeerMsg::StoreFor { to: p, id: [1; 16], sealed: vec![1, 2, 3] },
        PeerMsg::RemoteAccept { session: [1; 16], width: 1, height: 2, displays: vec![(1, 2, "d".into())], control: true },
        PeerMsg::Story { id: [1; 16], author: p, created: 1, text: "t".into(), image: vec![], bg: "#fff".into(), sig: vec![0; 64] },
        PeerMsg::WakeRequest { macs: vec![[1, 2, 3, 4, 5, 6]] },
        PeerMsg::Ext { kind: ext::DEVICE_LIST, body: vec![0x80] },
        PeerMsg::BotGroupMsg { gid: [1; 16], channel: "c".into(), msg: Box::new(chat(Body::Text { text: "t".into() })) },
    ]);
    let mut pf: Vec<Vec<u8>> = msgs.iter().map(|m| rmp_serde::to_vec(m).unwrap()).collect();
    pf.extend(msgs.iter().take(6).map(frame));
    pf.push(SyncBatch { items: vec![serde_bytes::ByteBuf::from(vec![1])], cursor: vec![1], done: true, phase: 1, convs_done: 1, convs_total: 2 }.encode_framed());
    save("peer_frame", pf);

    // signed things
    let s = Signer::primary(&a);
    let (st, op) = group::create(&s, 1, "g", vec![Identity::from_secret(&[2; 32]).peer_id()], 0).unwrap();
    let dev = Identity::from_secret(&[3; 32]);
    let cert = DeviceCert::issue(&a, dev.peer_id(), 1, 1);
    let list = SignedDeviceList::sign(&a, &DeviceListBody { v: 1, account: p, version: 1, devices: vec![lumora_core::devices::DeviceEntry { device: p, name: "pc".into(), kind: 2, caps: 1, added: 1 }], revoked: vec![] }).unwrap();
    let qr = LinkQr { v: 1, d: dev.peer_id(), s: vec![1; 32], a: vec!["1.2.3.4:5".parse().unwrap()], r: vec!["wss://r".into()], n: "n".into(), k: 1, e: 9 };
    let _ = st;
    save("chat_group", vec![rmp_serde::to_vec(&op).unwrap(), cert.encode(), list.encode(), qr.to_uri().into_bytes(), cert.to_san().into_bytes(), b"1234-5678-9012".to_vec()]);
    save("group_fold", vec![vec![0; 64], (0..=255u8).collect(), vec![3, 2, 1, 7, 0, 1, 1, 9, 2, 1, 1, 4, 0, 10, 2, 3, 1, 0, 2, 3, 4]]);

    save("file_preview", vec![
        FilePreview { kind: "pdf".into(), text: "Xin chào\nline".into(), pages: 3, lines: 2, img: vec![0xFF, 0xD8, 0xFF, 0] }.encode(),
        b"\xFF\xD8\xFF\xE0".to_vec(),
        "a\u{202E}b\r\n\tc".as_bytes().to_vec(),
        br#"{"kind":"code","text":"fn main(){}","pages":1,"lines":1}"#.to_vec(),
    ]);
    save("bot_token", vec![vec![7; 64], b"lumora_bot_aaaa".to_vec()]);
    save("invite", vec![vec![1; 40], b"lumora://join/aaaa".to_vec()]);
    let phrase = a.recovery_phrase();
    let mut rp = vec![[9u8; 32].to_vec(), phrase.clone().into_bytes(), phrase.to_uppercase().into_bytes()];
    rp.push(b"abcd-efgh-ijkl-mnop-qrst-uvwx-yz23-4567-abcd-efgh-ijkl-mnop".to_vec());
    save("recovery_phrase", rp);
    save("relay_proto", vec![relay_proto::encode_hello(&[1; 32], 5, &[2; 64]), relay_proto::encode_peer_frame(3, &[4; 32], b"payload")]);
    save("stun", vec![
        stun::binding_request(&[1; 12]),
        stun::binding_response(&[1; 12], "1.2.3.4:5678".parse().unwrap()),
        stun::binding_response(&[1; 12], "[2001:db8::1]:443".parse().unwrap()),
    ]);
    let pid = PeerId([7; 32]).to_base32();
    save("nostr", vec![
        format!(r#"["EVENT","s",{{"id":"00","pubkey":"aa","created_at":1,"kind":30078,"tags":[["d","lumora:user:abc"]],"content":"{{\"peer\":\"{pid}\",\"ts\":1,\"expires\":2,\"name\":\"abc\",\"sig\":\"00\"}}","sig":"00"}}]"#).into_bytes(),
    ]);
    let kp = lumora_push::KeyPair::from_secret([5; 32]);
    let reg = lumora_push::PushReg { bridge: "https://push.example".into(), token: vec![1, 2], notify: vec![3; 32], at: 1, ..Default::default() };
    save("push_bridge", vec![
        reg.encode(),
        lumora_push::seal_token(&kp.public, &lumora_push::DeviceToken { apns: "aa".into(), voip: "bb".into(), topic: "vn.lumora.lumora".into(), sandbox: true, ..Default::default() }),
        br#"{"token":"x","kind":"msg"}"#.to_vec(),
    ]);
    let api: Vec<(u8, &str)> = vec![
        (0, "{}"),
        (17, r#"{"peer":"$peer","text":"xin chào","reply_to":"00000000000000000000000000000000"}"#),
        (19, r#"{"peer":"$peer","question":"q","options":["a","b"]}"#),
        (56, r#"{"name":"g2","members":["$peer"]}"#),
        (57, r#"{"gid":"$gid"}"#),
        (15, r#"{"conv":"$conv","limit":50}"#),
        (15, r#"{"conv":"$gconv","limit":50}"#),
        (40, r#"{"gid":"$gid","hours":1}"#),
        (41, r#"{"link":"lumora://join/aaaa"}"#),
        (93, r#"{"key":"ui.x","value":"y"}"#),
    ];
    save("api_json", api.into_iter().map(|(c, j)| { let mut v = vec![c]; v.extend_from_slice(j.as_bytes()); v }).collect());
    let _ = BASE32_NOPAD;
}

trait Framed {
    fn encode_framed(&self) -> Vec<u8>;
}
impl Framed for SyncBatch {
    fn encode_framed(&self) -> Vec<u8> {
        let b = rmp_serde::to_vec_named(self).unwrap();
        let mut v = (b.len() as u32).to_be_bytes().to_vec();
        v.extend(b);
        v
    }
}
