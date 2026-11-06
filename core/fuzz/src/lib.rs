//! Fuzz entry points for everything in Lumora that parses bytes an attacker controls.
//!
//! Each `pub fn <target>(data: &[u8])` is one libFuzzer target (`fuzz_targets/<target>.rs`)
//! and is also driven on stable Rust by `tests/fuzz_stable.rs` (stored regressions + a
//! seeded random/mutation run), so CI catches regressions without nightly.
//!
//! The functions panic only on a real bug: a parser panic, a broken round trip, or an
//! invariant the receiver relies on (sanitised previews, deterministic group folding…).
//! Signatures can't be forged by a fuzzer, so the harness signs with fixed test keys where
//! a code path is only reachable with a valid signature (group ops, invites, bot tokens).
//!
//! ```text
//! cd core/fuzz
//! cargo +nightly fuzz run peer_frame -s none -- -max_total_time=600 -dict=dict/lumora.dict
//! cargo test --release                       # stable: regressions + random inputs
//! ```

use data_encoding::BASE32_NOPAD;
use lumora_core::devices::{self, DeviceCert, LinkQr, SignedDeviceList, Signer};
use lumora_core::file_preview::{self, FilePreview};
use lumora_core::group::{self, GroupOp, GroupState, Payload, Role, Signed};
use lumora_core::identity::{Identity, PeerId};
use lumora_core::net::{nostr, relay_proto, stun};
use lumora_core::proto::{self, Body, ChatMsg, MsgAction, PeerMsg, Signal, SyncBatch};
use lumora_core::store::sync::SyncItem;
use serde_json::{json, Value};
use std::sync::OnceLock;

fn rt() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap())
}

/// Fixed test identities (never real keys).
fn ident(i: u8) -> Identity {
    Identity::from_secret(&[i.wrapping_add(1); 32])
}

// ------------------------------------------------------------------ 1. control stream

fn walk_msg(m: &PeerMsg, depth: usize) {
    assert!(depth < 4096, "absurd nesting survived decoding");
    match m {
        PeerMsg::Chat(c) => walk_chat(c),
        PeerMsg::Wrapped { inner, .. } => walk_msg(inner, depth + 1),
        _ => {}
    }
}

fn walk_chat(c: &ChatMsg) {
    let _ = c.body.kind();
    let _ = c.body.preview();
    let _ = c.body.to_json();
    let b = c.signing_bytes(b"conv");
    let _ = devices::verify_by(&c.author, &b, &c.sig);
    if let Body::File { thumb, .. } = &c.body {
        let _ = file_preview::split_thumb(thumb);
    }
}

/// `proto::read_frame` / `read_frame_lenient` / `read_sync_frame` and every wire enum
/// a peer can send on the control stream.
pub fn peer_frame(data: &[u8]) {
    // what the node uses for every received PeerMsg (depth-capped: deep nesting used to
    // overflow the stack — regressions/peer_frame/deep-wrapped-*)
    if let Ok(m) = proto::decode_peer_msg(data) {
        walk_msg(&m, 0);
        // what we accept we must be able to re-encode (relaying, Wrapped acks, signing bytes)
        let enc: Vec<u8> = rmp_serde::to_vec(&m).expect("decoded PeerMsg must re-encode");
        let back = proto::from_slice_capped::<PeerMsg>(&enc).expect("re-encoded PeerMsg must decode");
        assert_eq!(rmp_serde::to_vec(&back).unwrap(), enc, "PeerMsg encoding is not stable");
    }
    let _ = proto::from_slice_capped::<Signal>(data);
    let _ = proto::from_slice_capped::<Body>(data);
    let _ = proto::from_slice_capped::<MsgAction>(data);
    let _ = proto::ext_body::<SyncBatch>(data);
    // remote-control input events (datagram INPUT / PeerMsg::RemoteInput)
    let _ = proto::from_slice_capped::<Value>(data);
    if let Some(item) = SyncItem::decode(data) {
        let _ = item.encode();
    }
    // the framed readers (length prefix + body), several frames back to back
    rt().block_on(async {
        let mut r = data;
        for _ in 0..4 {
            if proto::read_frame_lenient(&mut r).await.is_err() {
                break;
            }
        }
        let mut r = data;
        let _ = proto::read_frame(&mut r).await;
        let mut r = data;
        for _ in 0..4 {
            match proto::read_sync_frame(&mut r).await {
                Ok(Some(b)) => {
                    for it in &b.items {
                        let _ = SyncItem::decode(it);
                    }
                }
                _ => break,
            }
        }
    });
}

// ------------------------------------------------------------------ 2. signed things

/// Group envelopes (decrypt → decode `Signed` → verify), device certificates / DevSig,
/// signed device lists, link QR codes, sealed signalling envelopes.
pub fn chat_group(data: &[u8]) {
    let gid = [7u8; 16];
    let key = [9u8; 32];
    // a member who has the key can put anything inside the AEAD: decode + verify must hold up
    let mut env = 0u64.to_le_bytes().to_vec();
    env.extend(lumora_core::crypto::aead_encrypt(&key, data, &gid));
    let _ = group::open_envelope(&key, &gid, &env);
    let _ = group::open_envelope(&key, &gid, data);
    let _ = group::envelope_epoch(data);
    if let Ok(s) = proto::from_slice_capped::<Signed>(data) {
        let _ = s.verify();
        let _ = s.signer_device();
    }
    // signatures: 64-byte account sig or DevSig (cert + device sig)
    let author = ident(0).peer_id();
    let _ = devices::verify_by(&author, b"msg", data);
    let _ = devices::devsig_cert(&author, data);
    let _ = devices::signer_device(&author, data);
    if let Ok(c) = DeviceCert::decode(data) {
        let _ = c.verify();
        let _ = DeviceCert::from_san(&c.to_san());
    }
    let text = String::from_utf8_lossy(data);
    let _ = DeviceCert::from_san(&text);
    if let Ok(l) = SignedDeviceList::decode(data) {
        let _ = l.validate();
        let _ = l.digest();
    }
    let _ = LinkQr::parse(&text);
    let _ = LinkQr::parse(&format!("lumora://link/{}", BASE32_NOPAD.encode(data).to_lowercase()));
    let _ = devices::parse_code(&text);
    // signalling: sealed to us by anyone
    let me = ident(1);
    if let Ok(sealed) = lumora_core::crypto::seal_to(&ident(2), &me.peer_id(), data) {
        let (_, _, body) = lumora_core::crypto::open_sealed(&me, &sealed).expect("own seal must open");
        assert_eq!(body, data);
        let _ = proto::from_slice_capped::<Signal>(&body);
    }
    let _ = lumora_core::crypto::open_sealed(&me, data);
}

// ------------------------------------------------------------------ 3. group op folding

struct U<'a>(arbitrary::Unstructured<'a>);
impl U<'_> {
    fn u8(&mut self) -> u8 {
        self.0.arbitrary().unwrap_or(0)
    }
    fn u32(&mut self) -> u32 {
        self.0.arbitrary().unwrap_or(0)
    }
    fn hlc(&mut self) -> u64 {
        // small clock values collide often (concurrent ops = the interesting case)
        (self.u8() % 16) as u64
    }
    fn s(&mut self) -> String {
        let n = (self.u8() % 8) as usize;
        (0..n).map(|_| (b'a' + self.u8() % 26) as char).collect()
    }
}

fn sign_op(signer: &Signer, id: [u8; 16], gid: group::Gid, hlc: u64, payload: Payload) -> Signed {
    // same bytes as `Signed::bytes` (private); `verify()` below proves they still match
    let author = signer.account();
    let mut v = b"lumora-group-v1".to_vec();
    v.extend_from_slice(&id);
    v.extend_from_slice(&gid);
    v.extend_from_slice(&author.0);
    v.extend_from_slice(&hlc.to_le_bytes());
    v.extend(rmp_serde::to_vec(&payload).unwrap());
    let sig = signer.sign(&v);
    Signed { id, gid, author, hlc, payload, sig }
}

fn summary(s: &GroupState) -> String {
    format!(
        "{:?}|{}|{}|{:?}|{}|{:?}|{:?}|{}|{}|{:?}|{}|{}|{:?}|{:?}|{}|{}",
        s.owner.0, s.name, s.kind, s.members, s.epoch,
        s.channels.iter().map(|c| format!("{c:?}")).collect::<Vec<_>>(),
        s.left, s.public, s.handle, s.bots, s.slow_mode_s, s.admins_only, s.banned, s.key_commits,
        s.description, s.avatar.len()
    )
}

/// Signed group op logs from four test identities: folding must never panic, must be
/// order-independent (every member converges) and must keep its own invariants.
pub fn group_fold(data: &[u8]) {
    let mut u = U(arbitrary::Unstructured::new(data));
    let ids: Vec<Identity> = (0..4).map(ident).collect();
    let signers: Vec<Signer> = ids.iter().map(Signer::primary).collect();
    let peers: Vec<PeerId> = ids.iter().map(|i| i.peer_id()).collect();
    let peer = |u: &mut U| peers[(u.u8() % 4) as usize];
    let mut create_id = [0u8; 16];
    create_id[0] = u.u8();
    let gid = group::derive_gid(&peers[0], &create_id);
    let members: Vec<PeerId> = (0..u.u8() % 4).map(|_| peer(&mut u)).collect();
    let kind = u.u8() % 3;
    let mut ops = vec![sign_op(&signers[0], create_id, gid, 1, Payload::Op(GroupOp::Create { name: u.s(), members, kind }))];
    let n = (u.u8() % 24) as usize;
    for i in 0..n {
        let who = (u.u8() % 4) as usize;
        let op = match u.u8() % 15 {
            0 => GroupOp::Add { peer: peer(&mut u) },
            1 => GroupOp::Remove { peer: peer(&mut u) },
            2 => GroupOp::SetRole { peer: peer(&mut u), role: [Role::Member, Role::Admin, Role::Owner][(u.u8() % 3) as usize] },
            3 => GroupOp::Rename { name: u.s() },
            4 => GroupOp::Leave,
            5 => GroupOp::Rekey { epoch: (u.u8() % 6) as u64, commit: [u.u8(); 32] },
            6 => GroupOp::Channel { name: u.s(), voice: u.u8() & 1 == 1, remove: u.u8() & 1 == 1 },
            7 => GroupOp::Visibility { public: u.u8() & 1 == 1, handle: u.s() },
            8 => GroupOp::AddBot { peer: peer(&mut u), read_all: u.u8() & 1 == 1 },
            9 => GroupOp::SetBotPolicy { peer: peer(&mut u), read_all: u.u8() & 1 == 1 },
            10 => GroupOp::Ban { peer: peer(&mut u) },
            11 => GroupOp::Unban { peer: peer(&mut u) },
            12 => GroupOp::Settings { slow_mode_s: u.u32() % 100, admins_only: u.u8() & 1 == 1 },
            13 => GroupOp::Meta { avatar: vec![0; (u.u8() % 4) as usize], description: u.s() },
            _ => GroupOp::Create { name: u.s(), members: vec![peer(&mut u)], kind: 0 },
        };
        let mut id = [0u8; 16];
        id[0] = i as u8 + 1;
        id[1] = u.u8();
        let gid_used = if u.u8() == 255 { [0u8; 16] } else { gid };
        ops.push(sign_op(&signers[who], id, gid_used, u.hlc(), Payload::Op(op)));
    }
    for o in &ops {
        assert!(o.verify(), "harness signing bytes drifted from Signed::bytes");
    }
    let a = GroupState::fold(gid, ops.clone());
    let mut rev = ops.clone();
    rev.reverse();
    let b = GroupState::fold(gid, rev);
    let mut rot = ops.clone();
    if !rot.is_empty() {
        let k = (u.u8() as usize) % rot.len();
        rot.rotate_left(k);
    }
    let mut dup = ops.clone();
    dup.extend(ops.iter().take(3).cloned());
    let c = GroupState::fold(gid, rot);
    let d = GroupState::fold(gid, dup);
    match (&a, &b, &c, &d) {
        (Ok(a), Ok(b), Ok(c), Ok(d)) => {
            let sa = summary(a);
            assert_eq!(sa, summary(b), "fold depends on op order");
            assert_eq!(sa, summary(c), "fold depends on op order");
            assert_eq!(sa, summary(d), "fold depends on duplicates");
            assert!(a.members.is_empty() || a.members.get(&a.owner) == Some(&Role::Owner), "owner is not a member with the Owner role: {sa}");
            assert!(a.members.values().filter(|r| **r == Role::Owner).count() <= 1, "two owners: {sa}");
            for p in &a.banned {
                assert!(!a.members.contains_key(p), "banned peer is still a member: {sa}");
            }
        }
        (Err(_), Err(_), Err(_), Err(_)) => {}
        _ => panic!("fold succeeds or fails depending on op order"),
    }
}

// ------------------------------------------------------------------ 4. file previews

/// `file_preview` container parsing + sanitising (the text shown in the chat bubble).
pub fn file_preview(data: &[u8]) {
    let check = |p: &FilePreview| {
        assert!(p.text.len() <= file_preview::MAX_TEXT, "preview text over the cap");
        assert!(p.img.len() <= file_preview::MAX_IMG, "preview image over the cap");
        assert!(p.img.is_empty() || file_preview::is_image(&p.img));
        assert!(!p.text.chars().any(|c| (c.is_control() && c != '\n' && c != '\t') || matches!(c, '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{200E}' | '\u{200F}' | '\u{061C}' | '\u{FEFF}')),
            "dangerous character survived sanitising: {:?}", p.text);
        assert!(p.kind == "file" || (p.kind.len() <= 16 && p.kind.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_' || c == b'-')));
        // a sanitised preview round-trips (split_thumb moves the picture out: may be empty now)
        if p.is_empty() {
            return;
        }
        let back = FilePreview::decode(&p.encode()).expect("sanitised preview must re-decode");
        assert_eq!((back.kind.as_str(), back.text.as_str(), back.pages, back.lines), (p.kind.as_str(), p.text.as_str(), p.pages, p.lines));
    };
    let mut c = file_preview::MAGIC.to_vec();
    c.push(1);
    c.extend_from_slice(data);
    for b in [data, &c[..]] {
        if let Some(p) = FilePreview::decode(b) {
            check(&p);
        }
        let (img, p) = file_preview::split_thumb(b);
        assert!(img.len() <= file_preview::MAX_IMG);
        if let Some(p) = p {
            check(&p);
        }
    }
    let text = String::from_utf8_lossy(data);
    let max = data.first().map(|b| *b as usize * 7).unwrap_or(0);
    let t = file_preview::clean_text(&text, max);
    assert!(t.len() <= max);
    if let Some(s) = file_preview::snippet(data, file_preview::SNIPPET_BYTES) {
        assert!(s.len() <= file_preview::SNIPPET_BYTES);
    }
    let _ = file_preview::is_text_name(&text);
    if let Ok(v) = serde_json::from_slice::<Value>(data) {
        if let Some(p) = FilePreview::from_json(&v, data.to_vec()) {
            check(&p);
        }
    }
}

// ------------------------------------------------------------------ 5. bot tokens

#[derive(serde::Serialize)]
struct RawBotToken<'a> {
    v: u8,
    #[serde(with = "serde_bytes")]
    secret: &'a [u8],
    name: String,
    username: String,
    owner: PeerId,
    created: u64,
    #[serde(with = "serde_bytes")]
    owner_sig: Vec<u8>,
}

/// `BotToken::decode` on text, on raw MessagePack bodies, and on correctly owner-signed ones.
pub fn bot_token(data: &[u8]) {
    use lumora_core::node::botfather::{ownership_bytes, BotToken};
    let _ = BotToken::decode(&String::from_utf8_lossy(data));
    let _ = BotToken::decode(&format!("lumora_bot_{}", BASE32_NOPAD.encode(data).to_lowercase()));
    // a validly signed token with fuzzed fields
    let mut u = U(arbitrary::Unstructured::new(data));
    let owner = ident(0);
    let secret = [u.u8(); 32];
    let bot = Identity::from_secret(&secret).peer_id();
    let ulen = u.u8() as usize % 40;
    let username = String::from_utf8_lossy(u.0.bytes(ulen).unwrap_or_default()).into_owned();
    let created = u.u32() as u64;
    let raw = RawBotToken {
        v: u.u8(),
        secret: &secret,
        name: u.s(),
        owner: owner.peer_id(),
        owner_sig: owner.sign(&ownership_bytes(&bot, &username, created)).to_vec(),
        username,
        created,
    };
    let s = format!("lumora_bot_{}", BASE32_NOPAD.encode(&rmp_serde::to_vec(&raw).unwrap()).to_lowercase());
    let t = BotToken::decode(&s).expect("validly signed token must decode");
    assert_eq!(t.identity().peer_id(), bot);
    assert!(BotToken::decode(&t.encode()).is_ok());
}

// ------------------------------------------------------------------ 6. invite links

#[derive(serde::Serialize)]
struct RawInvite {
    gid: [u8; 16],
    inviter: PeerId,
    expires: u64,
    name: String,
    #[serde(with = "serde_bytes")]
    sig: Vec<u8>,
}

/// Group invite links (`lumora://join/…`): text, raw bodies, and validly signed ones.
pub fn invite(data: &[u8]) {
    use lumora_core::node::Node;
    let text = String::from_utf8_lossy(data);
    let _ = Node::fuzz_parse_invite(&text);
    let b32 = BASE32_NOPAD.encode(data).to_lowercase();
    let _ = Node::fuzz_parse_invite(&format!("lumora://join/{b32}"));
    let _ = Node::fuzz_parse_invite(&format!("https://lumora.app/join/{b32}"));
    let mut u = U(arbitrary::Unstructured::new(data));
    let me = ident(0);
    let gid = [u.u8(); 16];
    let expires = u.u32() as u64;
    let mut m = b"lumora-invite-v1".to_vec();
    m.extend_from_slice(&gid);
    m.extend_from_slice(&me.peer_id().0);
    m.extend_from_slice(&expires.to_le_bytes());
    let inv = RawInvite { gid, inviter: me.peer_id(), expires, name: u.s(), sig: me.sign(&m).to_vec() };
    let link = format!("  lumora://join/{}\n", BASE32_NOPAD.encode(&rmp_serde::to_vec(&inv).unwrap()).to_lowercase());
    assert!(Node::fuzz_parse_invite(&link), "validly signed invite rejected");
}

// ------------------------------------------------------------------ 7. recovery phrases

/// Recovery phrase parsing: 24 BIP39 words (prefixes, numbering, any case) and the legacy
/// base32 format. Any valid phrase must restore the same identity it came from.
pub fn recovery_phrase(data: &[u8]) {
    use lumora_core::bip39;
    let text = String::from_utf8_lossy(data);
    let _ = Identity::from_recovery_phrase(&text);
    let toks = bip39::tokens(&text);
    let _ = bip39::decode(&toks);
    for t in toks.iter().take(64) {
        let _ = bip39::lookup(t);
    }
    if data.len() >= 32 {
        let secret: [u8; 32] = data[..32].try_into().unwrap();
        let words = bip39::encode(&secret);
        assert_eq!(bip39::decode(&bip39::tokens(&words)).expect("own phrase must decode"), secret);
        // the user's typical noise: numbering, upper case, 4-letter prefixes, line breaks
        let noisy: String = words
            .split(' ')
            .enumerate()
            .map(|(i, w)| match data.get(32 + i).copied().unwrap_or(0) % 4 {
                0 => format!("{}. {w}\n", i + 1),
                1 => w.to_uppercase() + "  ",
                2 => w.chars().take(4).collect::<String>() + " ",
                _ => format!("{w}, "),
            })
            .collect();
        let id = Identity::from_secret(&secret);
        let back = Identity::from_recovery_phrase(&noisy).expect("noisy phrase must restore");
        assert_eq!(back.peer_id(), id.peer_id());
        let back = Identity::from_recovery_phrase(&id.recovery_phrase()).expect("own phrase must restore");
        assert_eq!(back.peer_id(), id.peer_id());
    }
}

// ------------------------------------------------------------------ 8. relay protocol

/// Relay wire frames (shared verbatim by the relay server): HELLO and peer frames.
pub fn relay_proto(data: &[u8]) {
    if let Some((pk, ts, sig)) = relay_proto::decode_hello(data) {
        assert_eq!(relay_proto::decode_hello(&relay_proto::encode_hello(&pk, ts, &sig)), Some((pk, ts, sig)));
    }
    if let Some((t, peer, payload)) = relay_proto::decode_peer_frame(data) {
        let enc = relay_proto::encode_peer_frame(t, &peer, payload);
        assert_eq!(relay_proto::decode_peer_frame(&enc), Some((t, peer, payload)));
    }
    let _ = relay_proto::hello_message(&[1; 32], data.len() as u64);
}

// ------------------------------------------------------------------ 9. STUN

/// STUN packets share the QUIC UDP port, so every datagram goes through these.
pub fn stun(data: &[u8]) {
    let _ = stun::is_stun(data);
    let _ = stun::is_binding_request(data);
    let _ = stun::parse_response(data);
    if data.len() >= 31 {
        let txid: [u8; 12] = data[..12].try_into().unwrap();
        let port = u16::from_le_bytes([data[12], data[13]]);
        let addr: std::net::SocketAddr = if data[14] & 1 == 0 {
            (std::net::Ipv4Addr::new(data[15], data[16], data[17], data[18]), port).into()
        } else {
            let o: [u8; 16] = data[15..31].try_into().unwrap();
            (std::net::Ipv6Addr::from(o), port).into()
        };
        let resp = stun::binding_response(&txid, addr);
        assert!(stun::is_stun(&resp));
        let (t, a) = stun::parse_response(&resp).expect("own binding response must parse");
        assert_eq!(t, txid);
        assert_eq!(a.port(), port);
        assert_eq!(stun::is_binding_request(&stun::binding_request(&txid)), Some(txid));
    }
}

// ------------------------------------------------------------------ 10. Nostr

/// Nostr relay messages: `["EVENT", sub, event]` → signature/PoW check → JSON content →
/// peer id + Ed25519 record signature (the same steps as the directory/username lookups).
pub fn nostr(data: &[u8]) {
    let text = String::from_utf8_lossy(data);
    let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    for ev in [&v[2], &v] {
        let (_ok, _bits) = nostr::fuzz_verify_event(ev);
        let content = ev["content"].as_str().unwrap_or("");
        let Ok(c) = serde_json::from_str::<Value>(content) else { continue };
        if let Some(ps) = c["peer"].as_str() {
            if let Ok(p) = PeerId::from_str_any(ps) {
                let _ = p.short_id();
                let _ = p.verify(content.as_bytes(), &hex::decode(c["sig"].as_str().unwrap_or("")).unwrap_or_default());
                let _ = nostr::handle_tag(&p);
            }
        }
        if let Some(n) = c["name"].as_str() {
            let _ = nostr::valid_username(n);
        }
    }
    let _ = PeerId::from_str_any(&text);
    let _ = nostr::valid_username(&text);
}

// ------------------------------------------------------------------ 11. push bridge

/// Push registrations gossiped by friends and the bridge's sealed token / notify formats.
pub fn push_bridge(data: &[u8]) {
    use lumora_push::*;
    if let Some(r) = PushReg::decode(data) {
        let _ = r.is_active();
        let _ = r.notify_key();
        let _ = bridge_url_allowed(&r.bridge);
        assert!(PushReg::decode(&r.encode()).is_some());
    }
    let kp = KeyPair::from_secret([5; 32]);
    let _ = open_token(&kp, data);
    let _ = open_notify(&kp, data);
    let _ = bridge_url_allowed(&String::from_utf8_lossy(data));
    let _ = unb64(&String::from_utf8_lossy(data));
    let _ = serde_json::from_slice::<WakeRequest>(data);
}

// ------------------------------------------------------------------ 12. JSON API

/// API commands the harness may run: local state only. Anything that reads or writes a
/// caller-chosen path, touches devices (camera/mic/screen/input/power) or the network for
/// real is left out (the fuzzer must not wreck the machine it runs on). So are the few that
/// destroy the fixture state every later input relies on (remove/block the contact, delete
/// the conversation, leave the group); messages deleted by an input are re-created.
pub const API_CMDS: &[&str] = &[
    "ping", "set_lang", "me", "set_name", "net_status", "push_status", "contacts", "accept_contact",     "unblock_contact", "rename_contact", "security_status", "verify_contact", "mark_verified",
    "conversations", "messages", "send_text", "send_message", "send_poll", "vote", "send_checklist", "checklist_toggle",
    "checklist_add", "send_reminder", "reminder_cancel", "reminder_seen", "reminders", "pin_message", "pinned_messages",
    "forward_message", "profile", "contact_cover", "contact_avatar", "create_invite", "inspect_invite", "schedule_message",
    "scheduled_messages", "cancel_scheduled", "send_sticker", "sticker_packs", "sticker_pack_create", "sticker_pack_delete",
    "sticker_remove", "sticker_get", "edit_message", "delete_message", "clear_history", "react", "mark_read", "typing",
    "conv_flag", "set_retention", "get_retention", "remote_recent", "remote_recent_remove", "search",
    "groups", "spaces", "create_group", "group_info", "group_add", "group_remove", "group_set_role", "group_rename",
    "group_channel", "send_location", "update_live_location", "send_contact", "stories", "story_seen", "story_viewers",
    "press_button", "bot_list", "set_bot", "group_visibility", "group_add_bot", "group_bot_policy", "group_ban",
    "group_settings", "seen_by", "mute", "group_purge_member", "group_clear_history", "group_meta", "files",
    "cancel_file", "pause_file", "remote_status", "ui_secret_get", "ui_secret_set", "settings_get", "storage_stats",
    "storage_policy", "get_wallpaper", "nonexistent_cmd",
];

mod api_args;

struct ApiNode {
    node: std::sync::Arc<lumora_core::node::Node>,
    friend: PeerId,
    gid: String,
    msg: parking_lot::Mutex<(String, String)>,
    _dir: tempfile::TempDir,
}

fn api_node() -> &'static ApiNode {
    static N: OnceLock<ApiNode> = OnceLock::new();
    N.get_or_init(|| {
        let dir = tempfile::tempdir().unwrap();
        let cfg = lumora_core::node::NodeConfig {
            data_dir: dir.path().join("node"),
            passphrase: Some("fuzz".into()),
            name: Some("fuzz".into()),
            enable_lan: false,
            lan_multicast: false,
            mdns: false,
            enable_upnp: false,
            enable_dht: false,
            enable_nostr: false,
            relays: Some(vec![]),
            nostr: Some(vec![]),
            stun: Some(vec![]),
            downloads_dir: Some(dir.path().join("dl")),
            ..Default::default()
        };
        let node = rt().block_on(lumora_core::node::Node::start(cfg)).expect("start fuzz node");
        let friend = ident(3).peer_id();
        let h = |v: Value| rt().block_on(lumora_core::api::handle(&node, &v));
        h(json!({"cmd": "add_contact", "target": friend.to_base32()}));
        let g = h(json!({"cmd": "create_group", "name": "g", "members": [friend.to_base32()]}));
        let gid = g["data"]["gid"].as_str().unwrap_or_default().to_string();
        let conv = format!("d:{}", friend.to_base32());
        let gconv = format!("g:{gid}");
        let first_id = |conv: &str| {
            h(json!({"cmd": "send_text", "conv": conv, "text": "hi"}));
            h(json!({"cmd": "send_poll", "conv": conv, "question": "q", "options": ["a", "b"]}));
            let m = h(json!({"cmd": "messages", "conv": conv}));
            m["data"].as_array().and_then(|a| a.first()).and_then(|m| m["id"].as_str()).unwrap_or_default().to_string()
        };
        let msg = first_id(&conv);
        let gmsg = first_id(&gconv);
        assert!(!gid.is_empty() && !msg.is_empty() && !gmsg.is_empty(), "fuzz node setup failed: gid={gid:?} msg={msg:?} gmsg={gmsg:?}");
        ApiNode { node, friend, gid, msg: parking_lot::Mutex::new((msg, gmsg)), _dir: dir }
    })
}

/// A plausible value for an argument name (the fuzzer then overrides / mutates fields).
fn default_arg(key: &str, group: bool) -> Value {
    match key {
        "conv" | "to_conv" => json!(if group { "$gconv" } else { "$conv" }),
        "peer" | "target" | "author" | "device" => json!("$peer"),
        "gid" => json!("$gid"),
        "msg_id" | "reply_to" => json!(if group { "$gmsg" } else { "$msg" }),
        "members" | "mentions" => json!(["$peer"]),
        "options" | "items" => json!(["a", "b"]),
        "key" => json!("ui.k"),
        "role" => json!("admin"),
        "kind" | "mode" | "preset" => json!(0),
        "on" | "done" | "public" | "read_all" | "admins_only" | "silent" | "video" | "voice" | "remove" | "stop"
        | "accept" | "allow" | "verified" | "trusted" | "global" | "for_everyone" | "mention_all" | "auto_accept" => json!(true),
        "at" | "at_ms" | "hours" | "limit" | "option" | "index" | "item" | "ttl_ms" | "duration_ms" | "until" | "slow_mode_s"
        | "before" | "live_minutes" | "status" | "lat" | "lon" | "accuracy_m" | "flag" => json!(1),
        _ => json!("x"),
    }
}

/// Replace `$peer` / `$gid` / `$conv` / `$msg` … placeholders so the fuzzer reaches real state.
fn fill(v: &mut Value, n: &ApiNode) {
    match v {
        Value::String(s) => {
            *s = match s.as_str() {
                "$peer" => n.friend.to_base32(),
                "$gid" => n.gid.clone(),
                "$conv" => format!("d:{}", n.friend.to_base32()),
                "$gconv" => format!("g:{}", n.gid),
                "$msg" => n.msg.lock().0.clone(),
                "$gmsg" => n.msg.lock().1.clone(),
                "$me" => n.node.me.to_base32(),
                _ => return,
            }
        }
        Value::Array(a) => a.iter_mut().for_each(|x| fill(x, n)),
        Value::Object(o) => o.values_mut().for_each(|x| fill(x, n)),
        _ => {}
    }
}

/// The JSON command dispatcher (`api::handle`) with arbitrary arguments, against a real
/// node with networking disabled. Byte 0 picks the command, byte 1 the mode (bit 0: start
/// from a template of plausible arguments, bit 1: group instead of direct chat), the rest
/// is request JSON whose fields override the template.
pub fn api_json(data: &[u8]) {
    let _ = api_json_debug(data);
}

/// [`api_json`] returning (command, response) — used by `examples/api_stats.rs`.
pub fn api_json_debug(data: &[u8]) -> Option<(String, Value)> {
    let (&sel, rest) = data.split_first()?;
    let (&mode, rest) = rest.split_first().unwrap_or((&0, &[]));
    let n = api_node();
    let cmd = API_CMDS[sel as usize % API_CMDS.len()];
    let mut req = json!({});
    if mode & 1 == 0 {
        let keys = api_args::API_ARGS.iter().find(|(c, _)| *c == cmd).map(|(_, k)| *k).unwrap_or(&[]);
        for k in keys {
            req[*k] = default_arg(k, mode & 2 != 0);
        }
    }
    match serde_json::from_slice::<Value>(rest) {
        Ok(Value::Object(o)) => o.into_iter().for_each(|(k, v)| req[k] = v),
        Ok(other) => req["arg"] = other,
        Err(_) if !rest.is_empty() => req["text"] = json!(String::from_utf8_lossy(rest)),
        Err(_) => {}
    }
    fill(&mut req, n);
    req["cmd"] = json!(cmd);
    let resp = rt().block_on(async {
        tokio::time::timeout(std::time::Duration::from_secs(20), lumora_core::api::handle(&n.node, &req)).await
    });
    let resp = resp.unwrap_or_else(|_| panic!("api command hung: {req}"));
    assert!(resp["ok"].is_boolean(), "response without ok: {resp}");
    if matches!(cmd, "delete_message" | "clear_history" | "group_clear_history" | "group_purge_member" | "set_retention") {
        // put fresh messages back for the $msg / $gmsg placeholders
        let h = |v: Value| rt().block_on(lumora_core::api::handle(&n.node, &v));
        let mut ids = n.msg.lock();
        for (conv, slot) in [(format!("d:{}", n.friend.to_base32()), 0), (format!("g:{}", n.gid), 1)] {
            h(json!({"cmd": "send_poll", "conv": conv, "question": "q", "options": ["a", "b"]}));
            let m = h(json!({"cmd": "messages", "conv": conv}));
            if let Some(id) = m["data"].as_array().and_then(|a| a.last()).and_then(|m| m["id"].as_str()) {
                if slot == 0 { ids.0 = id.to_string() } else { ids.1 = id.to_string() }
            }
        }
    }
    Some((cmd.to_string(), resp))
}

/// All targets by name (used by the stable runner).
pub const TARGETS: &[(&str, fn(&[u8]))] = &[
    ("peer_frame", peer_frame),
    ("chat_group", chat_group),
    ("group_fold", group_fold),
    ("file_preview", file_preview),
    ("bot_token", bot_token),
    ("invite", invite),
    ("recovery_phrase", recovery_phrase),
    ("relay_proto", relay_proto),
    ("stun", stun),
    ("nostr", nostr),
    ("push_bridge", push_bridge),
    ("api_json", api_json),
];
