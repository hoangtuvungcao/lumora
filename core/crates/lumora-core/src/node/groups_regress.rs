//! Regression tests from the pre-release review of the messaging/data layer: group epoch
//! convergence, untrusted clocks, out-of-order keys, slow mode on late history, and the
//! moderation / retention / quota fixes around them.
use super::*;
use crate::devices::Signer;
use crate::group::{key_commit, KeyUpdate};
use crate::identity::Identity;
use crate::proto::ChatMsg;
use rand::SeedableRng;

async fn quiet_node(dir: &std::path::Path) -> Arc<Node> {
    Node::start(NodeConfig {
        data_dir: dir.join("data"),
        downloads_dir: Some(dir.join("dl")),
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

fn gid_of(v: &Value) -> Gid {
    hex::decode(v["gid"].as_str().unwrap()).unwrap().try_into().unwrap()
}

/// envelopes authored by `n` (its device) whose payload matches `f`
fn my_envs(n: &Node, gid: &Gid, key: &[u8; 32], f: impl Fn(&Payload) -> bool) -> Vec<Vec<u8>> {
    n.store
        .group_log_since(gid, &n.device, 0, 10_000)
        .into_iter()
        .filter(|e| group::open_envelope(key, gid, e).map(|s| f(&s.payload)).unwrap_or(false))
        .collect()
}

/// Two admins rotate the key concurrently (e.g. one removes X while the other's member
/// leaves, or one of them was offline). Before the fix every member kept whichever Rekey
/// it saw first (the other was dropped as "older epoch") and the group split for good.
#[tokio::test(flavor = "multi_thread")]
async fn concurrent_rekeys_split_the_group() {
    let t1 = tempfile::tempdir().unwrap();
    let t2 = tempfile::tempdir().unwrap();
    let n = quiet_node(t1.path()).await; // owner
    let c = quiet_node(t2.path()).await; // plain member
    let bob = Identity::generate(); // admin
    let bs = Signer::primary(&bob);
    let v = n.create_group("G", vec![bob.peer_id(), c.me], 0).await.unwrap();
    let gid = gid_of(&v);
    n.group_set_role(gid, bob.peer_id(), true).await.unwrap();
    let k0 = n.store.group_key_get(&gid, 0).unwrap();
    // give c the same state (as its Welcome would)
    let st = n.groups.read().get(&gid).cloned().unwrap();
    c.store.group_key_put(&gid, 0, &k0).unwrap();
    c.store.group_save(&st.gid, &rmp_serde::to_vec(&st).unwrap()).unwrap();
    c.groups.write().insert(st.gid, st.clone());

    // bob rotates first (lower hlc)
    let kb: [u8; 32] = crate::crypto::random_bytes();
    let bob_rekey = Signed::new(&bs, gid, n.hlc.tick(), Payload::Op(GroupOp::Rekey { epoch: 1, commit: key_commit(&gid, 1, &kb) }));
    let bob_env = group::seal_envelope(&k0, 0, &bob_rekey).unwrap();
    // the owner rotates concurrently (before seeing bob's)
    n.rotate_key(gid).await.unwrap();
    let kn = n.store.group_key_get(&gid, 1).unwrap();
    let n_env = my_envs(&n, &gid, &k0, |p| matches!(p, Payload::Op(GroupOp::Rekey { .. }))).pop().unwrap();

    // owner receives bob's Rekey + KeyUpdate
    n.on_group_envelope(None, gid, bob_env.clone(), false).await.unwrap();
    let ku = rmp_serde::to_vec(&KeyUpdate { gid, epoch: 1, key: kb }).unwrap();
    n.on_group_key(bob.peer_id(), &crate::crypto::seal_to(&bob, &n.device, &ku).unwrap()).unwrap();
    // c receives bob's first, then the owner's (and the owner's key, which lost)
    c.on_group_envelope(None, gid, bob_env, false).await.unwrap();
    c.on_group_envelope(None, gid, n_env, false).await.unwrap();
    c.on_group_key(bob.peer_id(), &crate::crypto::seal_to(&bob, &c.device, &ku).unwrap()).unwrap();
    let kun = rmp_serde::to_vec(&KeyUpdate { gid, epoch: 1, key: kn }).unwrap();
    c.on_group_key(n.device, &crate::crypto::seal_to(&n.id, &c.device, &kun).unwrap()).unwrap();

    let n_st = n.groups.read().get(&gid).cloned().unwrap();
    let c_st = c.groups.read().get(&gid).cloned().unwrap();
    let n_commit = n_st.key_commits.get(&1).copied();
    let c_commit = c_st.key_commits.get(&1).copied();
    assert_eq!(n_commit, c_commit, "members disagree on the epoch-1 key forever");
    assert_eq!(n_commit, Some(key_commit(&gid, 1, &kb)), "the lowest (hlc, author) Rekey wins");
    assert_eq!((n_st.epoch, c_st.epoch), (1, 1));
    // the owner switched to the winning key, kept its own (lost) one for reading
    assert_eq!(n.store.group_key_get(&gid, 1), Some(kb));
    assert!(n.store.group_keys_all(&gid, 1).contains(&kn));
    assert_eq!(c.store.group_key_get(&gid, 1), Some(kb));
    // the owner's next message is readable by c
    let sent = n.send_text(&format!("g:{}", hex::encode(gid)), "hello", None, None).await.unwrap();
    let msg_env = my_envs(&n, &gid, &kb, |p| matches!(p, Payload::Msg { .. })).pop().unwrap();
    c.on_group_envelope(None, gid, msg_env, false).await.unwrap();
    let id: [u8; 16] = hex::decode(sent["id"].as_str().unwrap()).unwrap().try_into().unwrap();
    assert!(c.store.message(&id).is_some(), "c can't read the owner's message");
    // ...and so is one the owner sent under its losing key before it learned (c got that key)
    let s = Signed::new(&n.signer, gid, n.hlc.tick(), Payload::Op(GroupOp::Rename { name: "x".into() }));
    let late = group::seal_envelope(&kn, 1, &s).unwrap();
    c.on_group_envelope(None, gid, late, false).await.unwrap();
    assert_eq!(c.groups.read().get(&gid).unwrap().name, "x", "content under a losing key is still readable");
    n.shutdown();
    c.shutdown();
}

/// Anyone who can send us a DM (a stranger) pushed our HLC ~24 h ahead; every group op we
/// signed then exceeded the members' 10-minute future skew and was dropped by them, while
/// we applied it locally.
#[tokio::test(flavor = "multi_thread")]
async fn stranger_dm_skews_hlc_and_breaks_group_ops() {
    let t1 = tempfile::tempdir().unwrap();
    let t2 = tempfile::tempdir().unwrap();
    let n = quiet_node(t1.path()).await;
    let c = quiet_node(t2.path()).await;
    let bob = Identity::generate();
    let v = n.create_group("G", vec![bob.peer_id(), c.me], 0).await.unwrap();
    let gid = gid_of(&v);
    let k0 = n.store.group_key_get(&gid, 0).unwrap();
    let st = n.groups.read().get(&gid).cloned().unwrap();
    c.store.group_key_put(&gid, 0, &k0).unwrap();
    c.store.group_save(&st.gid, &rmp_serde::to_vec(&st).unwrap()).unwrap();
    c.groups.write().insert(st.gid, st.clone());

    let mallory = Identity::generate();
    let mut m = ChatMsg {
        id: crate::crypto::random_bytes(),
        author: mallory.peer_id(),
        hlc: (crate::util::now_ms() + 23 * 3_600_000) << 8,
        body: Body::Text { text: "hi".into() },
        reply_to: None,
        ttl_ms: None,
        meta: MsgMeta::default(),
        sig: vec![],
    };
    m.sig = mallory.sign(&m.signing_bytes(&super::super::chat::dm_scope(&n.me, &mallory.peer_id()))).to_vec();
    let mid = m.id;
    n.on_direct_chat_offline(mallory.peer_id(), mallory.peer_id(), m).await.unwrap();
    let ahead = crate::util::hlc_to_ms(n.hlc.tick()).saturating_sub(crate::util::now_ms());
    assert!(ahead <= crate::util::MAX_CLOCK_SKEW_MS + 1000, "clock dragged {ahead} ms ahead");
    // the message keeps its own date, but can't pin the chat to the top / read marks
    let conv = direct_conv(&mallory.peer_id());
    assert!(n.store.message(&mid).is_some());
    let cv = n.store.conversations().unwrap().into_iter().find(|c| c.id == conv).unwrap();
    assert!(cv.last_ts as u64 <= crate::util::now_ms() + crate::util::MAX_CLOCK_SKEW_MS + 1000, "chat pinned to the future");
    n.store.conv_mark_read(&conv).unwrap();
    let read_upto: i64 = n.store.sync_export(crate::store::sync::K_CONV, conv.as_bytes()).map(|i| match i {
        crate::store::sync::SyncItem::Conv(r) => r.read_upto,
        _ => 0,
    }).unwrap();
    assert!((read_upto as u64) <= crate::util::clamp_hlc_now(), "read position moved into the future");

    n.group_remove(gid, bob.peer_id()).await.unwrap();
    let envs = my_envs(&n, &gid, &k0, |p| matches!(p, Payload::Op(GroupOp::Remove { .. })));
    for e in envs {
        c.on_group_envelope(None, gid, e, false).await.unwrap();
    }
    let n_has = n.groups.read().get(&gid).unwrap().is_member(&bob.peer_id());
    let c_has = c.groups.read().get(&gid).unwrap().is_member(&bob.peer_id());
    assert_eq!(n_has, c_has, "remove applied locally but dropped by members");
    assert!(!c_has);
    n.shutdown();
    c.shutdown();
}

fn member_msg(who: &Identity, gid: Gid, key: &[u8; 32], hlc: u64, text: &str) -> (Vec<u8>, [u8; 16]) {
    member_msg_in(who, gid, key, hlc, text, "")
}

fn member_msg_in(who: &Identity, gid: Gid, key: &[u8; 32], hlc: u64, text: &str, channel: &str) -> (Vec<u8>, [u8; 16]) {
    let mut m = ChatMsg {
        id: crate::crypto::random_bytes(),
        author: who.peer_id(),
        hlc,
        body: Body::Text { text: text.into() },
        reply_to: None,
        ttl_ms: None,
        meta: MsgMeta::default(),
        sig: vec![],
    };
    m.sig = who.sign(&m.signing_bytes(&group_scope(&gid, channel))).to_vec();
    let id = m.id;
    let s = Signed::new(&Signer::primary(who), gid, hlc, Payload::Msg { channel: channel.into(), msg: Box::new(m) });
    (group::seal_envelope(key, 0, &s).unwrap(), id)
}

fn member_action(who: &Identity, gid: Gid, key: &[u8; 32], hlc: u64, target_author: PeerId, action: MsgAction) -> Vec<u8> {
    let s = Signed::new(&Signer::primary(who), gid, hlc, Payload::Action { channel: String::new(), target_author, action });
    group::seal_envelope(key, 0, &s).unwrap()
}

/// Slow mode was judged against the newest stored message of the author, not the previous
/// one in creation order: a legit older message arriving after a newer one was dropped.
#[tokio::test(flavor = "multi_thread")]
async fn slow_mode_drops_out_of_order_history() {
    let t1 = tempfile::tempdir().unwrap();
    let n = quiet_node(t1.path()).await;
    let bob = Identity::generate();
    let v = n.create_group("G", vec![bob.peer_id()], 0).await.unwrap();
    let gid = gid_of(&v);
    n.group_settings(gid, Some(30), None).await.unwrap();
    let k0 = n.store.group_key_get(&gid, 0).unwrap();
    let now = crate::util::now_ms();
    let (e1, id1) = member_msg(&bob, gid, &k0, (now + 1_000) << 8, "first");
    let (e2, id2) = member_msg(&bob, gid, &k0, (now + 61_000) << 8, "second, a minute later");
    n.on_group_envelope(None, gid, e2, false).await.unwrap();
    n.on_group_envelope(None, gid, e1, false).await.unwrap();
    assert!(n.store.message(&id2).is_some());
    assert!(n.store.message(&id1).is_some(), "legit message lost because it arrived late");
    // a real violation (10 s after the first) is still dropped, in either order
    let (e3, id3) = member_msg(&bob, gid, &k0, (now + 11_000) << 8, "too soon");
    n.on_group_envelope(None, gid, e3, false).await.unwrap();
    assert!(n.store.message(&id3).is_none());
    // history written before slow mode was switched on is judged by the rules of then
    let (e0, id0) = member_msg(&bob, gid, &k0, (now - 120_000) << 8, "before slow mode");
    let (e0b, id0b) = member_msg(&bob, gid, &k0, (now - 119_000) << 8, "right after");
    n.on_group_envelope(None, gid, e0, false).await.unwrap();
    n.on_group_envelope(None, gid, e0b, false).await.unwrap();
    assert!(n.store.message(&id0).is_some() && n.store.message(&id0b).is_some());
    n.shutdown();
}

/// A member offline during two rotations by different admins: the second admin's KeyUpdate
/// can arrive before the first Rekey (different senders' outboxes). It was acked and
/// dropped (epoch != st.epoch + 1), so the member never got the epoch-2 key.
#[tokio::test(flavor = "multi_thread")]
async fn out_of_order_key_updates_are_lost_for_good() {
    let t1 = tempfile::tempdir().unwrap();
    let n = quiet_node(t1.path()).await;
    let alice = Identity::generate();
    let bob = Identity::generate();
    let (a, b) = (Signer::primary(&alice), Signer::primary(&bob));
    let now = crate::util::now_ms() << 8;
    let (st, _create) = group::create(&a, now, "G", vec![n.me, bob.peer_id()], 0).unwrap();
    let gid = st.gid;
    let k0: [u8; 32] = crate::crypto::random_bytes();
    n.store.group_key_put(&gid, 0, &k0).unwrap();
    n.store.group_save(&gid, &rmp_serde::to_vec(&st).unwrap()).unwrap();
    n.groups.write().insert(gid, st.clone());
    // alice promotes bob
    let promo = Signed::new(&a, gid, now + 10, Payload::Op(GroupOp::SetRole { peer: bob.peer_id(), role: crate::group::Role::Admin }));
    n.on_group_envelope(None, gid, group::seal_envelope(&k0, 0, &promo).unwrap(), false).await.unwrap();
    // alice rotates to 1, then bob rotates to 2
    let (k1, k2): ([u8; 32], [u8; 32]) = (crate::crypto::random_bytes(), crate::crypto::random_bytes());
    let r1 = Signed::new(&a, gid, now + 20, Payload::Op(GroupOp::Rekey { epoch: 1, commit: key_commit(&gid, 1, &k1) }));
    let r2 = Signed::new(&b, gid, now + 30, Payload::Op(GroupOp::Rekey { epoch: 2, commit: key_commit(&gid, 2, &k2) }));
    let e1 = group::seal_envelope(&k0, 0, &r1).unwrap();
    let e2 = group::seal_envelope(&k1, 1, &r2).unwrap();
    let ku = |e: u64, k: [u8; 32]| rmp_serde::to_vec(&KeyUpdate { gid, epoch: e, key: k }).unwrap();
    // bob's outbox flushes first
    n.on_group_envelope(None, gid, e2, false).await.unwrap();
    n.on_group_key(bob.peer_id(), &crate::crypto::seal_to(&bob, &n.device, &ku(2, k2)).unwrap()).unwrap();
    // junk from a member can't push the real key out (per-sender cap), and is refused
    // unacknowledged once that member's share is used up
    let mallory_junk = (0..40).filter(|_| {
        let j: [u8; 32] = crate::crypto::random_bytes();
        n.on_group_key(bob.peer_id(), &crate::crypto::seal_to(&bob, &n.device, &ku(3, j)).unwrap()).is_err()
    });
    assert!(mallory_junk.count() > 0, "pending keys must be bounded per sender");
    // then alice's
    n.on_group_envelope(None, gid, e1, false).await.unwrap();
    n.on_group_key(alice.peer_id(), &crate::crypto::seal_to(&alice, &n.device, &ku(1, k1)).unwrap()).unwrap();
    for _ in 0..30 {
        if n.groups.read().get(&gid).map(|g| g.epoch) == Some(2) && n.store.group_key_get(&gid, 2).is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let st = n.groups.read().get(&gid).cloned().unwrap();
    assert_eq!(st.epoch, 2);
    assert!(n.store.group_key_get(&gid, st.epoch).is_some(), "member is at an epoch it has no key for (KeyUpdate was acked and dropped)");
    assert_eq!(n.store.group_key_get(&gid, 2), Some(k2));
    n.shutdown();
}

/// Deliver everything the nodes queued for each other (outboxes): in order per (sender,
/// receiver) — like the real transport — with the pairs interleaved at random. Returns
/// how many messages moved.
async fn pump(nodes: &[Arc<Node>], rng: &mut rand::rngs::StdRng) -> usize {
    use rand::Rng;
    let mut queues: Vec<(usize, usize, std::collections::VecDeque<PeerMsg>)> = vec![];
    for (i, from) in nodes.iter().enumerate() {
        for (j, to) in nodes.iter().enumerate() {
            if i == j {
                continue;
            }
            let mut q = std::collections::VecDeque::new();
            for (_, id, payload) in from.store.outbox_page(&to.device, 0, 100_000).unwrap() {
                from.store.outbox_remove(&id, &to.device).unwrap();
                if let Ok(PeerMsg::Wrapped { inner, .. }) = rmp_serde::from_slice::<PeerMsg>(&payload) {
                    q.push_back(*inner);
                }
            }
            if !q.is_empty() {
                queues.push((i, j, q));
            }
        }
    }
    let mut n = 0;
    while !queues.is_empty() {
        let k = rng.gen_range(0..queues.len());
        let (i, j) = (queues[k].0, queues[k].1);
        let m = queues[k].2.pop_front().unwrap();
        if queues[k].2.is_empty() {
            queues.swap_remove(k);
        }
        n += 1;
        let (from, to) = (&nodes[i], &nodes[j]);
        let r = match m {
            PeerMsg::Group { gid, env } => to.on_group_envelope(None, gid, env, false).await,
            PeerMsg::GroupKey { sealed } => to.on_group_key(from.device, &sealed),
            PeerMsg::GroupWelcome { sealed } => to.on_group_welcome(from.device, &sealed).await,
            PeerMsg::Ext { kind: proto::ext::GROUP_KEY_REQUEST, body } => to.on_group_key_request(from.me, &body).await,
            _ => Ok(()),
        };
        if let Err(e) = r {
            tracing::debug!("pump: {e:#}");
        }
    }
    n
}

/// Friends who said hello (v3) to each other.
fn befriend(nodes: &[Arc<Node>]) {
    for a in nodes {
        for b in nodes {
            if a.me != b.me {
                a.store.upsert_contact(&b.me, Some("x"), Some(3)).unwrap();
                a.record_peer_proto(&b.device, proto::PROTO_V3);
            }
        }
    }
}

async fn settle(nodes: &[Arc<Node>], rng: &mut rand::rngs::StdRng) {
    // until nothing moved for a while: rotations and key requests are spawned and wait a
    // moment (KEY_WAIT) before they queue anything
    let start = Instant::now();
    let mut last = Instant::now();
    while start.elapsed() < Duration::from_secs(20) && last.elapsed() < KEY_WAIT * 3 {
        tokio::time::sleep(Duration::from_millis(50)).await;
        if pump(nodes, rng).await > 0 {
            last = Instant::now();
        }
    }
}

/// Four members, two admins removing / rotating concurrently with the owner's own
/// changes, every message delivered in a different random order: everyone converges to
/// the same members, epoch, commitments and key, the removed member doesn't hold the key
/// everyone ends up using, and all members read each other.
#[tokio::test(flavor = "multi_thread")]
async fn concurrent_admin_ops_converge_in_any_order() {
    for seed in [7u64, 1234] {
        let mut rng = rand::rngs::StdRng::seed_from_u64(seed);
        let dirs: Vec<tempfile::TempDir> = (0..5).map(|_| tempfile::tempdir().unwrap()).collect();
        let mut nodes = vec![];
        for d in &dirs {
            nodes.push(quiet_node(d.path()).await);
        }
        befriend(&nodes);
        let (o, a, b, c, x) = (nodes[0].clone(), nodes[1].clone(), nodes[2].clone(), nodes[3].clone(), nodes[4].clone());
        let v = o.create_group("Nhóm", vec![a.me, b.me, c.me, x.me], 0).await.unwrap();
        let gid = gid_of(&v);
        o.group_set_role(gid, a.me, true).await.unwrap();
        o.group_set_role(gid, b.me, true).await.unwrap();
        settle(&nodes, &mut rng).await;
        for n in &nodes {
            assert_eq!(n.groups.read().get(&gid).map(|g| g.members.len()), Some(5), "setup");
        }
        // concurrently, nobody hearing from anyone: A removes X (and rotates), B rotates,
        // the owner renames and changes settings, C writes
        a.group_remove(gid, x.me).await.unwrap();
        b.rotate_key(gid).await.unwrap();
        o.group_rename(gid, "Nhóm mới").await.unwrap();
        o.group_settings(gid, None, Some(false)).await.unwrap();
        c.send_text(&format!("g:{}", hex::encode(gid)), "đang bận", None, None).await.unwrap();
        settle(&nodes, &mut rng).await;

        let members = [&o, &a, &b, &c];
        let st0 = o.groups.read().get(&gid).cloned().unwrap();
        assert!(!st0.is_member(&x.me), "removal lost");
        assert!(st0.rekey_due().is_none(), "a rotation is still due");
        assert_eq!(st0.name, "Nhóm mới");
        let key = o.store.group_key_get(&gid, st0.epoch).expect("owner has the current key");
        for n in members {
            let st = n.groups.read().get(&gid).cloned().unwrap();
            assert_eq!(st.members, st0.members, "seed {seed}: members differ");
            assert_eq!(st.epoch, st0.epoch, "seed {seed}: epochs differ");
            assert_eq!(st.key_commits, st0.key_commits, "seed {seed}: commitments differ");
            assert_eq!(st.name, st0.name);
            assert_eq!(n.store.group_key_get(&gid, st.epoch), Some(key), "seed {seed}: keys differ");
        }
        assert!(!x.store.group_keys_all(&gid, st0.epoch).contains(&key), "seed {seed}: the removed member has the current key");
        // everyone reads everyone
        let mut ids = vec![];
        for (i, n) in members.iter().enumerate() {
            let r = n.send_text(&format!("g:{}", hex::encode(gid)), &format!("xin chào {i}"), None, None).await.unwrap();
            ids.push(hex::decode(r["id"].as_str().unwrap()).unwrap());
        }
        settle(&nodes, &mut rng).await;
        for n in members {
            for id in &ids {
                assert!(n.store.message(id).is_some(), "seed {seed}: a member can't read another's message");
            }
        }
        for id in &ids {
            assert!(x.store.message(id).is_none(), "seed {seed}: the removed member reads new messages");
        }
        for n in &nodes {
            n.shutdown();
        }
    }
}

/// A plain member's op the group's rules reject is refused (no welcome, no key sent).
#[tokio::test(flavor = "multi_thread")]
async fn rejected_ops_are_refused_not_published() {
    let tmp = tempfile::tempdir().unwrap();
    let n = quiet_node(tmp.path()).await;
    let owner = Identity::generate();
    let os = Signer::primary(&owner);
    let now = crate::util::now_ms() << 8;
    let spammer = Identity::generate().peer_id();
    let (st, _) = group::create(&os, now, "G", vec![n.me, spammer], 0).unwrap();
    let gid = st.gid;
    let k0: [u8; 32] = crate::crypto::random_bytes();
    n.store.group_key_put(&gid, 0, &k0).unwrap();
    n.save_group(&st).unwrap();
    let ban = Signed::new(&os, gid, now + 5, Payload::Op(GroupOp::Ban { peer: spammer }));
    n.on_group_envelope(None, gid, group::seal_envelope(&k0, 0, &ban).unwrap(), false).await.unwrap();
    assert!(n.groups.read().get(&gid).unwrap().banned.contains(&spammer));
    let e = n.group_add(gid, spammer).await.unwrap_err();
    assert_eq!(crate::i18n::find_user_err(&e).map(|u| u.key), Some("err.group_op_rejected"));
    assert!(n.store.outbox_page(&spammer, 0, 100).unwrap().is_empty(), "welcome/key sent to a banned peer");
    assert!(!n.groups.read().get(&gid).unwrap().is_member(&spammer));
    let e = n.group_add_bot(gid, spammer, true).await.unwrap_err();
    assert!(crate::i18n::find_user_err(&e).is_some());
    assert!(n.store.outbox_page(&spammer, 0, 100).unwrap().is_empty());
    n.shutdown();
}

/// Moderation: undeclared channels, deletes arriving before their message, clears that
/// cover every channel and can't reach into the future, and what the log keeps.
#[tokio::test(flavor = "multi_thread")]
async fn moderation_holds_in_any_order() {
    let tmp = tempfile::tempdir().unwrap();
    let n = quiet_node(tmp.path()).await;
    let bob = Identity::generate();
    let v = n.create_group("G", vec![bob.peer_id()], 0).await.unwrap();
    let gid = gid_of(&v);
    let k0 = n.store.group_key_get(&gid, 0).unwrap();
    let now = crate::util::now_ms() - 60_000;
    // a channel the group never declared
    let (e, id) = member_msg_in(&bob, gid, &k0, now << 8, "hidden", "secret");
    n.on_group_envelope(None, gid, e, false).await.unwrap();
    assert!(n.store.message(&id).is_none(), "message in an undeclared channel stored");
    // the owner (this node) deleting bob's message before it arrived here: remembered
    let (e, id) = member_msg(&bob, gid, &k0, (now + 1) << 8, "spam");
    let s = Signed::new(&n.signer, gid, n.hlc.tick(), Payload::Action { channel: String::new(), target_author: bob.peer_id(), action: MsgAction::Delete { target: id } });
    n.on_group_envelope(None, gid, group::seal_envelope(&k0, 0, &s).unwrap(), false).await.unwrap();
    n.on_group_envelope(None, gid, e, false).await.unwrap();
    let m = n.store.message(&id).unwrap();
    assert!(m.deleted, "a moderator's delete that came first was lost");
    // its envelope is not kept for anyone else
    assert!(my_envs_all(&n, &gid, &k0).iter().all(|s| !matches!(&s.payload, Payload::Msg { msg, .. } if msg.id == id)));
    // an edit by the author that came first is applied too
    let (e, id2) = member_msg(&bob, gid, &k0, (now + 2) << 8, "typo");
    n.on_group_envelope(None, gid, member_action(&bob, gid, &k0, (now + 3) << 8, bob.peer_id(), MsgAction::Edit { target: id2, text: "fixed".into() }), false).await.unwrap();
    n.on_group_envelope(None, gid, e, false).await.unwrap();
    assert_eq!(n.store.message(&id2).unwrap().body["text"], "fixed");
    // a member forging a clear "forever" (u64::MAX): admins only, and capped at its time
    n.on_group_envelope(None, gid, member_action(&bob, gid, &k0, (now + 4) << 8, bob.peer_id(), MsgAction::ClearHistory { upto_hlc: u64::MAX, delete_chat: false }), false).await.unwrap();
    assert!(n.store.message(&id2).is_some(), "a member cleared the group");
    let s = Signed::new(&n.signer, gid, n.hlc.tick(), Payload::Action { channel: String::new(), target_author: n.me, action: MsgAction::ClearHistory { upto_hlc: u64::MAX, delete_chat: false } });
    n.on_group_envelope(None, gid, group::seal_envelope(&k0, 0, &s).unwrap(), false).await.unwrap();
    assert!(n.store.message(&id2).is_none(), "admin clear not applied");
    let (e, id3) = member_msg(&bob, gid, &k0, n.hlc.tick() + (1000 << 8), "after the clear");
    n.on_group_envelope(None, gid, e, false).await.unwrap();
    assert!(n.store.message(&id3).is_some(), "a clear up to u64::MAX blocked the chat forever");
    // cleared content is not re-served from the log
    assert!(my_envs_all(&n, &gid, &k0).iter().all(|s| !matches!(&s.payload, Payload::Msg { msg, .. } if msg.id == id2)));
    // late history below the clear stays cleared
    let (e, id4) = member_msg(&bob, gid, &k0, (now + 5) << 8, "late, before the clear");
    n.on_group_envelope(None, gid, e, false).await.unwrap();
    assert!(n.store.message(&id4).is_none(), "cleared history came back");
    n.shutdown();
}

fn my_envs_all(n: &Node, gid: &Gid, key: &[u8; 32]) -> Vec<Signed> {
    n.store
        .group_log_heads(gid)
        .into_iter()
        .flat_map(|(a, _)| n.store.group_log_since(gid, &a, 0, 100_000))
        .filter_map(|e| group::open_envelope(key, gid, &e).ok())
        .collect()
}

/// Content dated across many past days can't multiply the per-day quotas: what arrives
/// in a day is bounded too.
#[tokio::test(flavor = "multi_thread")]
async fn backdated_content_is_bounded_by_arrival() {
    let tmp = tempfile::tempdir().unwrap();
    let n = quiet_node(tmp.path()).await;
    let bob = Identity::generate();
    let now = crate::util::now_ms();
    let (st, _) = group::create(&n.signer, (now - 70 * 86_400_000) << 8, "G", vec![bob.peer_id()], 0).unwrap();
    let gid = st.gid;
    let k0: [u8; 32] = crate::crypto::random_bytes();
    n.store.group_key_put(&gid, 0, &k0).unwrap();
    n.save_group(&st).unwrap();
    let big = "x".repeat(30 * 1024);
    let mut ok = 0;
    // one big message per past day, 60 days: each day's creation quota is fresh
    for d in 1..=60u64 {
        let (e, id) = member_msg(&bob, gid, &k0, (now - d * 86_400_000) << 8, &big);
        n.on_group_envelope(None, gid, e, false).await.unwrap();
        ok += n.store.message(&id).is_some() as u64;
    }
    let cap = RCV_QUOTA_FACTOR * AUTHOR_DAY_BYTES / (30 * 1024);
    assert!(ok < 60 && ok <= cap + 1, "backdating multiplied the daily quota: {ok}");
    n.shutdown();
}

/// Group key recovery: a member at an epoch without its key asks, an admin answers.
#[tokio::test(flavor = "multi_thread")]
async fn missing_key_is_requested_and_served() {
    let (t1, t2) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (o, m) = (quiet_node(t1.path()).await, quiet_node(t2.path()).await);
    let nodes = [o.clone(), m.clone()];
    befriend(&nodes);
    let mut rng = rand::rngs::StdRng::seed_from_u64(3);
    let v = o.create_group("G", vec![m.me], 0).await.unwrap();
    let gid = gid_of(&v);
    settle(&nodes, &mut rng).await;
    o.rotate_key(gid).await.unwrap();
    // the KeyUpdate to m is lost (e.g. acked by a device that was then wiped)
    for (_, id, p) in o.store.outbox_page(&m.device, 0, 1000).unwrap() {
        if matches!(rmp_serde::from_slice::<PeerMsg>(&p), Ok(PeerMsg::Wrapped { inner, .. }) if matches!(*inner, PeerMsg::GroupKey { .. })) {
            o.store.outbox_remove(&id, &m.device).unwrap();
        }
    }
    settle(&nodes, &mut rng).await;
    assert_eq!(m.groups.read().get(&gid).unwrap().epoch, 1);
    assert_eq!(m.store.group_key_get(&gid, 1), o.store.group_key_get(&gid, 1), "the key was not recovered");
    // an outsider asking gets nothing
    let req = rmp_serde::to_vec_named(&GroupKeyRequestMsg { gid: gid.to_vec(), epoch: 1 }).unwrap();
    let stranger = Identity::generate().peer_id();
    o.on_group_key_request(stranger, &req).await.unwrap();
    assert!(o.store.outbox_page(&stranger, 0, 10).unwrap().is_empty());
    o.shutdown();
    m.shutdown();
}

/// Superseded pictures are not part of a Welcome (44 avatar changes made it exceed the
/// 4 MB frame); members can't change it over and over; folds are incremental.
#[tokio::test(flavor = "multi_thread")]
async fn welcome_stays_small_and_meta_is_rate_limited() {
    let tmp = tempfile::tempdir().unwrap();
    let n = quiet_node(tmp.path()).await;
    let bob = Identity::generate();
    let v = n.create_group("G", vec![bob.peer_id()], 0).await.unwrap();
    let gid = gid_of(&v);
    let pic = data_encoding::BASE64.encode(&vec![7u8; 90 * 1024]);
    for _ in 0..60 {
        n.group_meta(gid, Some(&pic), Some("mô tả")).await.unwrap();
    }
    let st = n.groups.read().get(&gid).cloned().unwrap();
    let w = rmp_serde::to_vec(&Welcome { gid, ops: st.compact_ops(), epoch: st.epoch, key: [0; 32] }).unwrap();
    assert!(w.len() < 200 * 1024, "welcome {} bytes", w.len());
    assert_eq!(GroupState::fold(gid, st.compact_ops()).unwrap().avatar, st.avatar);
    // a plain member: one picture change per 10 minutes
    let k0 = n.store.group_key_get(&gid, 0).unwrap();
    let t = n.hlc.tick();
    for i in 0..5u64 {
        let s = Signed::new(&Signer::primary(&bob), gid, t + i * (60_000 << 8), Payload::Op(GroupOp::Meta { avatar: vec![i as u8; 10], description: String::new() }));
        n.on_group_envelope(None, gid, group::seal_envelope(&k0, 0, &s).unwrap(), false).await.unwrap();
    }
    let metas = n.groups.read().get(&gid).unwrap().ops.iter().filter(|o| o.author == bob.peer_id()).count();
    assert_eq!(metas, 1, "member meta changes not rate limited");
    n.shutdown();
}

/// Disappearing / retention-expired file messages take Lumora's downloaded copy with
/// them; "delete for me" too; a pending forward keeps its source.
#[tokio::test(flavor = "multi_thread")]
async fn expired_and_deleted_files_are_forgotten() {
    let tmp = tempfile::tempdir().unwrap();
    let n = quiet_node(tmp.path()).await;
    let bob = Identity::generate().peer_id();
    let conv = direct_conv(&bob);
    n.store.ensure_conv(&conv, 0, "Bob").unwrap();
    let dl = n.downloads_dir();
    std::fs::create_dir_all(&dl).unwrap();
    let file = |i: u8, expires: Option<i64>| {
        let p = dl.join(format!("f{i}.bin"));
        std::fs::write(&p, b"data").unwrap();
        let row = crate::store::FileRow {
            id: hex::encode([i; 16]),
            conv: conv.clone(),
            peer: bob.to_base32(),
            name: format!("f{i}.bin"),
            size: 4,
            hash: hex::encode([i; 32]),
            path: p.to_string_lossy().into(),
            direction: 1,
            state: 2,
            progress: 4,
            created: 1,
        };
        n.store.file_put(&row).unwrap();
        n.store.insert_message(&[i + 100; 16], &conv, &bob, (crate::util::now_ms() - 10_000) << 8, "file", &json!({"file_id": hex::encode([i; 16])}), 2, None, expires).unwrap();
        p
    };
    let expired = file(1, Some(crate::util::now_ms() as i64 - 1));
    let kept = file(2, None);
    n.store.maintain().unwrap();
    n.file_gc();
    assert!(!expired.exists(), "an expired message's download stayed on disk");
    assert!(n.store.file_get(&[1; 16]).is_none());
    assert!(kept.exists());
    n.delete_for_me(&conv, &[102; 16]).unwrap();
    assert!(!kept.exists(), "delete for me left the downloaded file");
    // a forward still pending (outgoing, offered) keeps the file it points at
    let src = dl.join("src.bin");
    std::fs::write(&src, b"x").unwrap();
    for (i, dir, state) in [(5u8, 1, 2), (6u8, 0, 0)] {
        let mut r = n.store.file_get(&[1; 16]).unwrap_or(crate::store::FileRow {
            id: String::new(),
            conv: conv.clone(),
            peer: bob.to_base32(),
            name: "s".into(),
            size: 1,
            hash: hex::encode([0; 32]),
            path: String::new(),
            direction: 0,
            state: 0,
            progress: 0,
            created: 1,
        });
        r.id = hex::encode([i; 16]);
        r.path = src.to_string_lossy().into();
        r.direction = dir;
        r.state = state;
        n.store.file_put(&r).unwrap();
    }
    assert_eq!(n.store.path_refcount(&src.to_string_lossy()), 2, "a pending forward doesn't count");
    n.shutdown();
}

/// Reminders from others: absurd dates aren't scheduled, one sender can't fill the list.
#[tokio::test(flavor = "multi_thread")]
async fn reminder_flood_is_bounded() {
    let tmp = tempfile::tempdir().unwrap();
    let n = quiet_node(tmp.path()).await;
    let bob = Identity::generate().peer_id();
    let now = crate::util::now_ms();
    let mk = |at_ms: u64| ChatMsg {
        id: crate::crypto::random_bytes(),
        author: bob,
        hlc: now << 8,
        body: Body::Reminder { title: "t".into(), at_ms, note: String::new() },
        reply_to: None,
        ttl_ms: None,
        meta: MsgMeta::default(),
        sig: vec![],
    };
    n.track_reminder("d:x", &mk(now + 5 * 365 * 86_400_000));
    assert!(n.reminders_raw().is_empty(), "a reminder 5 years ahead was scheduled");
    for i in 0..200u64 {
        let m = mk(now + 3_600_000 + i);
        n.store.ensure_conv("d:x", 0, "x").unwrap();
        n.store.insert_message(&m.id, "d:x", &bob, m.hlc, "reminder", &m.body.to_json(), 2, None, None).unwrap();
        n.track_reminder("d:x", &m);
    }
    assert!(n.reminders_raw().len() <= 50, "one sender filled the reminder list: {}", n.reminders_raw().len());
    // clearing the chat untracks them
    n.clear_local("d:x", crate::util::clamp_hlc_now(), false).unwrap();
    assert!(n.reminders_raw().is_empty());
    n.shutdown();
}

/// A scheduled message that can't be sent stays (failed) and the user is told.
#[tokio::test(flavor = "multi_thread")]
async fn failed_scheduled_message_is_kept_and_reported() {
    let tmp = tempfile::tempdir().unwrap();
    let n = quiet_node(tmp.path()).await;
    let mut ev = n.subscribe();
    let blocked = Identity::generate().peer_id();
    n.store.upsert_contact(&blocked, Some("b"), Some(4)).unwrap();
    let conv = direct_conv(&blocked);
    n.store.ensure_conv(&conv, 0, "b").unwrap();
    n.schedule_text(&conv, "hẹn giờ", crate::util::now_ms() + 1_000).unwrap();
    let mut failed = None;
    for _ in 0..100 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        while let Ok(e) = ev.try_recv() {
            if e["event"] == "scheduled_failed" {
                failed = Some(e);
            }
        }
        if failed.is_some() {
            break;
        }
    }
    assert!(failed.is_some(), "no scheduled_failed event");
    let list = n.scheduled();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].state, "failed");
    let msgs = n.store.messages(&conv, None, 10).unwrap();
    assert!(msgs.iter().any(|m| m.kind == "system" && m.body["code"] == "sys.scheduled_failed"), "no notice in the chat");
    n.shutdown();
}

/// Sends with an app `client_id` are idempotent (a retry — even a concurrent one —
/// returns the first message), and the chat list says whose the last message is.
#[tokio::test(flavor = "multi_thread")]
async fn send_client_id_is_idempotent_and_last_mine_is_reported() {
    let tmp = tempfile::tempdir().unwrap();
    let n = quiet_node(tmp.path()).await;
    let conv = "s:me";
    let req = json!({"cmd": "send_text", "conv": conv, "text": "một lần thôi", "client_id": "app-123"});
    let (r1, r2) = tokio::join!(crate::api::handle(&n, &req), crate::api::handle(&n, &req));
    let r3 = crate::api::handle(&n, &req).await;
    assert_eq!(r1["ok"], true, "{r1}");
    assert_eq!(r1["data"]["id"], r2["data"]["id"]);
    assert_eq!(r1["data"]["id"], r3["data"]["id"]);
    assert_eq!(n.store.messages(conv, None, 50).unwrap().len(), 1, "duplicate message created");
    // another client_id (or none) is a new message; too long an id is refused
    let r4 = crate::api::handle(&n, &json!({"cmd": "send_text", "conv": conv, "text": "khác", "client_id": "app-124"})).await;
    assert_ne!(r4["data"]["id"], r1["data"]["id"]);
    crate::api::handle(&n, &json!({"cmd": "send_text", "conv": conv, "text": "không id"})).await;
    assert_eq!(n.store.messages(conv, None, 50).unwrap().len(), 3);
    let long = crate::api::handle(&n, &json!({"cmd": "send_text", "conv": conv, "text": "x", "client_id": "x".repeat(65)})).await;
    assert_eq!(long["ok"], false);
    // last_mine
    let list = crate::api::handle(&n, &json!({"cmd": "conversations"})).await;
    let row = list["data"].as_array().unwrap().iter().find(|c| c["id"] == conv).unwrap().clone();
    assert_eq!(row["last_mine"], true, "{row}");
    let bob = Identity::generate();
    let dconv = direct_conv(&bob.peer_id());
    n.store.ensure_conv(&dconv, 0, "Bob").unwrap();
    n.store.insert_message(&[1; 16], &dconv, &bob.peer_id(), n.hlc.tick(), "text", &json!({"text": "hi"}), 2, None, None).unwrap();
    let mine = |n: &Node, c: &str| n.conversations().unwrap().into_iter().find(|x| x.id == c).unwrap().last_mine;
    assert!(!mine(&n, &dconv));
    n.store.insert_message(&[2; 16], &dconv, &n.me, n.hlc.tick(), "text", &json!({"text": "chào"}), 1, None, None).unwrap();
    assert!(mine(&n, &dconv));
    n.store.insert_message(&[3; 16], &dconv, &n.me, n.hlc.tick(), "system", &json!({"text": "sys"}), 2, None, None).unwrap();
    assert!(!mine(&n, &dconv), "a system line counts as mine");
    n.shutdown();
}
