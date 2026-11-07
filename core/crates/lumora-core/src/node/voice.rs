//! Community voice channels as drop-in rooms (Discord-style).
//!
//! A voice channel `g:<gid>#<channel>` is a room. Joining never rings anyone: this device
//! announces itself to the community (`Ext VOICE_PRESENCE`) and opens media to whoever is
//! already there. Media reuses the group-call machinery (`remote::Call` + media_pipe): the
//! room is a `Call` with `room = true` whose id is derived from the conversation, so every
//! participant's datagrams name the same call.
//!
//! Presence is per account (one of my devices in a room at a time — joining on another
//! device moves me there; the newest `since` wins). It reaches every member device,
//! including members not in the room, so the channel list shows who is there. Entries are
//! refreshed by heartbeats and expire after [`presence_ttl`] (crash, network loss).

use super::remote::Call;
use super::{parse_conv, ConvRef, Node};
use crate::group::Gid;
use crate::identity::PeerId;
use crate::proto;
use crate::util::now_ms;
use anyhow::Result;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Presence without a heartbeat for this long is dropped.
const PRESENCE_TTL: Duration = Duration::from_secs(45);
/// Accounts dialed when presence changes (beyond that only live connections hear it).
const MAX_MEMBERS_DIALED: usize = 64;
/// A device we could not reach is not dialed again for presence before this.
const UNREACHABLE_BACKOFF: Duration = Duration::from_secs(120);
/// A `since` this far ahead of our clock is refused (it would pin the entry forever).
const MAX_FUTURE_MS: u64 = 10 * 60_000;

/// Presence TTL (test knob `LUMORA_VOICE_TTL_MS`, debug builds only).
pub(crate) fn presence_ttl() -> Duration {
    let env = if cfg!(debug_assertions) { std::env::var("LUMORA_VOICE_TTL_MS").ok() } else { None };
    env.and_then(|v| v.parse::<u64>().ok()).filter(|ms| *ms >= 2000).map(Duration::from_millis).unwrap_or(PRESENCE_TTL)
}

/// Heartbeat period: a few beats fit in one TTL, so one lost beat never drops anyone.
pub(crate) fn heartbeat() -> Duration {
    presence_ttl() / 4
}

/// The call id of a room: the same on every participant (their datagrams name it).
pub(crate) fn room_call_id(conv: &str) -> [u8; 16] {
    let k = blake3::derive_key("lumora voice room v1", conv.as_bytes());
    let mut id = [0u8; 16];
    id.copy_from_slice(&k[..16]);
    id
}

/// `Ext VOICE_PRESENCE`: the sender's device is (`here`) / is no longer in room `conv`.
/// `since` identifies the join (ms): the newest join of an account wins.
#[derive(Serialize, Deserialize, Default, Clone, Debug)]
pub(crate) struct VoicePresence {
    #[serde(default)]
    pub conv: String,
    #[serde(default)]
    pub here: bool,
    #[serde(default)]
    pub since: u64,
    #[serde(default)]
    pub muted: bool,
}

/// `Ext CALL_SPEAKING`: the sender started / stopped talking in call `call_id`.
#[derive(Serialize, Deserialize, Default, Clone, Debug)]
pub(crate) struct CallSpeaking {
    #[serde(with = "serde_bytes", default)]
    pub call_id: Vec<u8>,
    #[serde(default)]
    pub on: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Entry {
    pub device: PeerId,
    pub since: u64,
    pub muted: bool,
    pub seen: Instant,
}

/// Outcome of a "here" announcement.
#[derive(Default, Debug, PartialEq)]
pub(crate) struct Here {
    /// Older than what we know for the account: ignored.
    pub stale: bool,
    /// The room's participants or mute states changed.
    pub changed: bool,
    /// A new join (not a heartbeat of a known one).
    pub joined: bool,
    /// The account's previous device in this room (moved to another device).
    pub replaced: Option<PeerId>,
    /// The account was in another room before: (room, device).
    pub moved_from: Option<(String, PeerId)>,
}

/// Who is in which room (per account). Pure state: the node feeds it messages and time.
#[derive(Default)]
pub(crate) struct Presence {
    rooms: HashMap<String, HashMap<PeerId, Entry>>,
}

impl Presence {
    fn find(&self, acct: &PeerId) -> Option<(String, Entry)> {
        self.rooms.iter().find_map(|(c, m)| m.get(acct).map(|e| (c.clone(), e.clone())))
    }

    /// `device` of `acct` is in `conv` since `since` (a join or a heartbeat).
    pub fn here(&mut self, conv: &str, acct: PeerId, device: PeerId, since: u64, muted: bool, now: Instant) -> Here {
        let mut out = Here::default();
        if let Some((c, e)) = self.find(&acct) {
            if c == conv && e.device == device && e.since == since {
                // heartbeat (or a mute change) of the join we know
                let m = self.rooms.get_mut(conv).and_then(|r| r.get_mut(&acct)).expect("found above");
                out.changed = m.muted != muted;
                m.muted = muted;
                m.seen = now;
                return out;
            }
            // the newest join wins; equal times: the larger device key (same answer everywhere)
            if since < e.since || (since == e.since && device.0 < e.device.0) {
                out.stale = true;
                return out;
            }
            if let Some(r) = self.rooms.get_mut(&c) {
                r.remove(&acct);
                if r.is_empty() {
                    self.rooms.remove(&c);
                }
            }
            if c != conv {
                out.moved_from = Some((c, e.device));
            } else if e.device != device {
                out.replaced = Some(e.device);
            }
        }
        self.rooms.entry(conv.to_string()).or_default().insert(acct, Entry { device, since, muted, seen: now });
        out.changed = true;
        out.joined = true;
        out
    }

    /// `device` of `acct` left `conv` (its join `since`); only that join is removed.
    pub fn gone(&mut self, conv: &str, acct: &PeerId, device: &PeerId, since: u64) -> bool {
        let Some(r) = self.rooms.get_mut(conv) else { return false };
        let hit = r.get(acct).is_some_and(|e| e.device == *device && e.since <= since);
        if hit {
            r.remove(acct);
            if r.is_empty() {
                self.rooms.remove(conv);
            }
        }
        hit
    }

    /// Drop entries without a heartbeat for `ttl` (never `keep`, this device: it is
    /// there as long as it says so). Returns (room, account, device) of each.
    pub fn expire(&mut self, now: Instant, ttl: Duration, keep: &PeerId) -> Vec<(String, PeerId, PeerId)> {
        let mut out = vec![];
        for (c, r) in self.rooms.iter_mut() {
            r.retain(|a, e| {
                let live = e.device == *keep || now.saturating_duration_since(e.seen) < ttl;
                if !live {
                    out.push((c.clone(), *a, e.device));
                }
                live
            });
        }
        self.rooms.retain(|_, r| !r.is_empty());
        out
    }

    /// A room's participants, first to join first.
    pub fn participants(&self, conv: &str) -> Vec<(PeerId, Entry)> {
        let mut v: Vec<(PeerId, Entry)> = self.rooms.get(conv).map(|r| r.iter().map(|(a, e)| (*a, e.clone())).collect()).unwrap_or_default();
        v.sort_by(|a, b| a.1.since.cmp(&b.1.since).then(a.0 .0.cmp(&b.0 .0)));
        v
    }

    /// Every room with someone in it whose id starts with `prefix`.
    #[cfg(test)]
    pub fn rooms_of(&self, prefix: &str) -> Vec<String> {
        self.rooms.keys().filter(|c| c.starts_with(prefix)).cloned().collect()
    }
}

/// Voice activity on the sender's own (cleaned) microphone frames: opens above
/// `OPEN_DB`, closes after `HOLD` quiet frames (20 ms each).
#[derive(Default)]
#[cfg_attr(not(feature = "media"), allow(dead_code))]
pub(crate) struct Vad {
    open: bool,
    hold: u32,
}

#[cfg_attr(not(feature = "media"), allow(dead_code))]
impl Vad {
    const OPEN_DB: f32 = -42.0;
    const HOLD: u32 = 15;

    pub fn level_db(pcm: &[i16]) -> f32 {
        if pcm.is_empty() {
            return -120.0;
        }
        let sum: f64 = pcm.iter().map(|&s| (s as f64) * (s as f64)).sum();
        let rms = (sum / pcm.len() as f64).sqrt() / 32768.0;
        if rms > 0.0 {
            20.0 * rms.log10() as f32
        } else {
            -120.0
        }
    }

    /// Feed one frame (`None`: muted / no frame); returns whether the user is talking.
    pub fn step(&mut self, pcm: Option<&[i16]>) -> bool {
        match pcm {
            Some(p) if Self::level_db(p) >= Self::OPEN_DB => {
                self.open = true;
                self.hold = Self::HOLD;
            }
            Some(_) if self.hold > 0 => self.hold -= 1,
            _ => {
                self.open = false;
                self.hold = 0;
            }
        }
        self.open
    }
}

/// This device's room.
#[derive(Clone, Debug)]
pub(crate) struct MyRoom {
    pub conv: String,
    pub call_id: [u8; 16],
    pub since: u64,
}

#[derive(Default)]
pub(crate) struct VoiceState {
    pub(crate) presence: Mutex<Presence>,
    pub(crate) mine: Mutex<Option<MyRoom>>,
    last_since: Mutex<u64>,
    unreachable: Mutex<HashMap<PeerId, Instant>>,
    started: AtomicBool,
}

impl Node {
    /// `conv` is a voice channel of a community I'm in: its gid.
    pub(crate) fn voice_channel(&self, conv: &str) -> Option<Gid> {
        let ConvRef::Group(g, ch) = parse_conv(conv).ok()? else { return None };
        if ch.is_empty() {
            return None;
        }
        let groups = self.groups.read();
        let st = groups.get(&g)?;
        // (a dissolved community has no rooms: mine is left on the next tick)
        (st.kind == 1 && st.is_member(&self.me) && !st.dissolved() && st.channels.iter().any(|c| c.voice && c.name == ch)).then_some(g)
    }

    fn my_room(&self) -> Option<MyRoom> {
        self.voice.mine.lock().clone()
    }

    fn room_call(&self) -> Option<Arc<Call>> {
        let id = self.my_room()?.call_id;
        self.remote.calls.lock().get(&id).cloned()
    }

    /// Join voice channel `conv`: never rings anyone. Leaves the room I was in.
    pub async fn voice_join(self: &Arc<Self>, conv: &str) -> Result<Value> {
        let gid = self.voice_channel(conv).ok_or_else(|| crate::i18n::user_err("err.not_voice_channel"))?;
        // Community 2.0: connect_voice, not timed out, a channel I can see
        if let (Some(g), Ok(ConvRef::Group(_, ch))) = (self.groups.read().get(&gid).cloned(), parse_conv(conv)) {
            let role = g.role(&self.me).unwrap_or(crate::group::Role::Member);
            let ok = role >= crate::group::Role::Admin
                || (g.has(&self.me, crate::community::perm::CONNECT_VOICE) && g.timeout_until(&self.me) <= now_ms() && g.can_see(&self.me, &ch));
            anyhow::ensure!(ok, crate::i18n::user_err("err.no_permission"));
        }
        if let Some(m) = self.my_room() {
            if m.conv == conv && self.remote.calls.lock().contains_key(&m.call_id) {
                return Ok(json!({"call_id": hex::encode(m.call_id), "conv": conv}));
            }
            // one room at a time: switching leaves the old one first
            self.end_call(&m.call_id, false);
        }
        let now = Instant::now();
        let id = room_call_id(conv);
        let c = Arc::new(Call {
            id,
            conv: conv.to_string(),
            peers: Mutex::new(vec![]),
            video: false,
            state: Mutex::new("active".into()),
            mic: AtomicBool::new(true),
            cam: AtomicBool::new(false),
            screen: AtomicBool::new(false),
            started: now,
            answered: Mutex::new(Some(now)),
            stop: Arc::new(AtomicBool::new(false)),
            incoming_from: None,
            media_started: AtomicBool::new(false),
            invited: Mutex::new(vec![]),
            room: true,
            speaking: Mutex::new(vec![]),
        });
        {
            // checked and taken under one lock: two joins at once can't both start a call
            // (the loser's would keep the microphone with nobody able to end it)
            let mut calls = self.remote.calls.lock();
            anyhow::ensure!(calls.is_empty(), crate::i18n::user_err("err.in_other_call"));
            calls.insert(id, c.clone());
        }
        let (r, since) = {
            let mut pr = self.voice.presence.lock();
            // newer than my account's current join everywhere, even if another of my devices'
            // clock runs ahead: otherwise "the newest join wins" would pick the old one
            let theirs = pr.find(&self.me).map(|(_, e)| e.since + 1).unwrap_or(0);
            let since = {
                let mut l = self.voice.last_since.lock();
                *l = now_ms().max(*l + 1).max(theirs);
                *l
            };
            let r = pr.here(conv, self.me, self.device, since, false, now);
            let peers: Vec<PeerId> = pr.participants(conv).into_iter().filter(|(a, _)| *a != self.me).map(|(_, e)| e.device).collect();
            *c.peers.lock() = peers;
            (r, since)
        };
        *self.voice.mine.lock() = Some(MyRoom { conv: conv.to_string(), call_id: id, since });
        #[cfg(feature = "media")]
        super::media_pipe::start_call_media(self, &c);
        self.emit_call(&c);
        if let Some((old, _)) = &r.moved_from {
            self.emit_voice(old);
        }
        self.emit_voice(conv);
        self.voice_announce(conv, true, since, false, true);
        Ok(json!({"call_id": hex::encode(id), "conv": conv}))
    }

    /// Leave voice channel `conv` (nothing to do when I'm not in it).
    pub fn voice_leave(self: &Arc<Self>, conv: &str) {
        if let Some(m) = self.my_room().filter(|m| m.conv == conv) {
            self.end_call(&m.call_id, false);
        }
    }

    /// Room call `c` ended here (left, hung up, moved to another device): tell everyone.
    pub(crate) fn voice_left(self: &Arc<Self>, c: &Call) {
        let mine = {
            let mut m = self.voice.mine.lock();
            if m.as_ref().is_some_and(|m| m.call_id == c.id) {
                m.take()
            } else {
                None
            }
        };
        let Some(m) = mine else { return };
        self.voice.presence.lock().gone(&m.conv, &self.me, &self.device, m.since);
        self.voice_announce(&m.conv, false, m.since, false, true);
        self.emit_voice(&m.conv);
    }

    /// My microphone state changed in the room.
    pub(crate) fn voice_muted(self: &Arc<Self>, c: &Call) {
        let Some(m) = self.my_room().filter(|m| m.call_id == c.id) else { return };
        let muted = !c.mic.load(Ordering::Relaxed);
        let changed = self.voice.presence.lock().here(&m.conv, self.me, self.device, m.since, muted, Instant::now()).changed;
        self.voice_announce(&m.conv, true, m.since, muted, false);
        if changed {
            self.emit_voice(&m.conv);
        }
    }

    /// Send my presence for `conv` to the community's devices: live connections, and —
    /// with `dial` — the others too (a few accounts, never an unreachable one again soon).
    fn voice_announce(self: &Arc<Self>, conv: &str, here: bool, since: u64, muted: bool, dial: bool) {
        let Ok(ConvRef::Group(gid, _)) = parse_conv(conv) else { return };
        let msg = proto::ext(proto::ext::VOICE_PRESENCE, &VoicePresence { conv: conv.to_string(), here, since, muted });
        let members = self.group_members(&gid);
        let mut sent: Vec<PeerId> = vec![];
        for pc in self.connected_peers() {
            if members.contains(&pc.account) && pc.peer != self.device && !sent.contains(&pc.peer) {
                self.send_now_dev(&pc.peer, msg.clone());
                sent.push(pc.peer);
            }
        }
        if !dial {
            return;
        }
        let now = Instant::now();
        self.voice.unreachable.lock().retain(|_, t| now.saturating_duration_since(*t) < UNREACHABLE_BACKOFF);
        for acct in members.into_iter().take(MAX_MEMBERS_DIALED) {
            for dev in self.delivery_targets(&acct) {
                if dev == self.device || sent.contains(&dev) || self.voice.unreachable.lock().contains_key(&dev) {
                    continue;
                }
                // IP privacy: dialing sends my addresses — only to devices that may learn them
                // (friends, private-group co-members, community admins…). Ordinary members
                // of a public community see me once they connect to me themselves (the live
                // connections above) — joining a room never dials strangers.
                if !self.may_reveal_addrs(&dev) {
                    continue;
                }
                sent.push(dev);
                let (node, msg) = (self.clone(), msg.clone());
                tokio::spawn(async move {
                    match tokio::time::timeout(Duration::from_secs(25), node.connect(dev)).await {
                        Ok(Ok(_)) => {
                            node.send_now_dev(&dev, msg);
                        }
                        _ => {
                            node.voice.unreachable.lock().insert(dev, Instant::now());
                        }
                    }
                });
            }
        }
    }

    /// `Ext VOICE_PRESENCE` from `from` (device of `acct`).
    pub(crate) fn on_voice_presence(self: &Arc<Self>, from: PeerId, acct: PeerId, body: &[u8]) -> Result<()> {
        let m: VoicePresence = proto::ext_body(body)?;
        if from == self.device || m.since > now_ms() + MAX_FUTURE_MS || self.store.is_blocked(&acct) {
            return Ok(());
        }
        let Some(gid) = self.voice_channel(&m.conv) else { return Ok(()) };
        if !self.group_members(&gid).contains(&acct) {
            return Ok(());
        }
        // Community 2.0: timed out / no connect_voice / a channel it can't see → not in rooms
        if m.here {
            if let (Some(g), Ok(ConvRef::Group(_, ch))) = (self.groups.read().get(&gid).cloned(), parse_conv(&m.conv)) {
                let admin = g.role(&acct).unwrap_or(crate::group::Role::Member) >= crate::group::Role::Admin;
                if !admin && (!g.has(&acct, crate::community::perm::CONNECT_VOICE) || g.timeout_until(&acct) > now_ms() || !g.can_see(&acct, &ch)) {
                    return Ok(());
                }
            }
        }
        let mine = self.my_room();
        let in_my_room = mine.as_ref().is_some_and(|r| r.conv == m.conv);
        if !m.here {
            if self.voice.presence.lock().gone(&m.conv, &acct, &from, m.since) {
                if in_my_room {
                    self.room_drop_peer(&from);
                }
                self.emit_voice(&m.conv);
            }
            return Ok(());
        }
        let r = self.voice.presence.lock().here(&m.conv, acct, from, m.since, m.muted, Instant::now());
        if r.stale {
            return Ok(());
        }
        // another of my devices joined a room: this one leaves (one device in voice)
        let moved_here = r.replaced == Some(self.device) || r.moved_from.as_ref().is_some_and(|x| x.1 == self.device);
        if moved_here {
            if let Some(my) = &mine {
                let name = self.own_list().and_then(|b| b.devices.into_iter().find(|e| e.device == from)).map(|e| e.name).unwrap_or_default();
                self.emit("voice", json!({"conv": my.conv, "moved": true, "device": from.to_base32(), "device_name": name}));
                self.end_call(&my.call_id, false);
            }
        }
        if let Some((old, old_dev)) = &r.moved_from {
            if mine.as_ref().is_some_and(|x| x.conv == *old) && !moved_here {
                self.room_drop_peer(old_dev);
            }
            self.emit_voice(old);
        }
        if let Some(old) = r.replaced.filter(|_| in_my_room && !moved_here) {
            self.room_drop_peer(&old);
        }
        if in_my_room && !moved_here && acct != self.me {
            self.room_add_peer(from);
        }
        if r.changed {
            self.emit_voice(&m.conv);
        }
        Ok(())
    }

    /// A participant's device joins my room's media (it gets my presence straight back,
    /// so it adds me without waiting for a heartbeat).
    fn room_add_peer(self: &Arc<Self>, dev: PeerId) {
        let (Some(my), Some(c)) = (self.my_room(), self.room_call()) else { return };
        let added = {
            let mut p = c.peers.lock();
            !p.contains(&dev) && {
                p.push(dev);
                true
            }
        };
        if !added {
            return;
        }
        let muted = !c.mic.load(Ordering::Relaxed);
        self.send_now_dev(&dev, proto::ext(proto::ext::VOICE_PRESENCE, &VoicePresence { conv: my.conv.clone(), here: true, since: my.since, muted }));
        #[cfg(feature = "media")]
        super::media_pipe::send_caps_to(self, &dev);
        self.send_now_dev(
            &dev,
            proto::PeerMsg::CallState { call_id: c.id, mic: c.mic.load(Ordering::Relaxed), cam: c.cam.load(Ordering::Relaxed), screen: c.screen.load(Ordering::Relaxed) },
        );
        self.emit_call(&c);
    }

    /// A participant's device left my room's media (the room goes on, even empty).
    fn room_drop_peer(self: &Arc<Self>, dev: &PeerId) {
        let Some(c) = self.room_call() else { return };
        let was_in = {
            let mut p = c.peers.lock();
            let n = p.len();
            p.retain(|x| x != dev);
            p.len() != n
        };
        c.speaking.lock().retain(|x| x != dev);
        if was_in {
            self.call_peer_left(&c, dev);
            self.emit_call(&c);
        }
    }

    /// Participants of room `conv` (accounts, first to join first).
    pub fn voice_participants(&self, conv: &str) -> Vec<(PeerId, bool)> {
        self.voice.presence.lock().participants(conv).into_iter().map(|(a, e)| (a, e.muted)).collect()
    }

    pub(crate) fn voice_json(&self, conv: &str) -> Value {
        let list = self.voice.presence.lock().participants(conv);
        let mine = self.my_room().filter(|m| m.conv == conv);
        let speaking: Vec<String> = match mine.as_ref().and_then(|m| self.remote.calls.lock().get(&m.call_id).cloned()) {
            Some(c) => c.speaking.lock().iter().map(|d| self.account_of(d).to_base32()).collect(),
            None => vec![],
        };
        json!({
            "conv": conv,
            "participants": list.iter().map(|(a, _)| a.to_base32()).collect::<Vec<_>>(),
            "muted": list.iter().filter(|(_, e)| e.muted).map(|(a, _)| a.to_base32()).collect::<Vec<_>>(),
            "devices": list.iter().map(|(a, e)| (a.to_base32(), json!(e.device.to_base32()))).collect::<serde_json::Map<_, _>>(),
            "speaking": speaking,
            "joined": mine.is_some(),
        })
    }

    pub(crate) fn emit_voice(&self, conv: &str) {
        self.emit("voice", self.voice_json(conv));
    }

    /// Someone in call `c` (my own device too) started / stopped talking.
    pub(crate) fn set_speaking(self: &Arc<Self>, c: &Call, dev: PeerId, on: bool) {
        let changed = {
            let mut s = c.speaking.lock();
            let has = s.contains(&dev);
            if on && !has {
                s.push(dev);
            } else if !on && has {
                s.retain(|x| *x != dev);
            }
            on != has
        };
        if !changed {
            return;
        }
        if dev == self.device {
            let m = proto::ext(proto::ext::CALL_SPEAKING, &CallSpeaking { call_id: c.id.to_vec(), on });
            for p in c.peers.lock().iter() {
                self.send_now_dev(p, m.clone());
            }
        }
        self.emit_call(c);
        if c.room {
            self.emit_voice(&c.conv);
        }
    }

    /// `Ext CALL_SPEAKING` from a device in one of my calls.
    pub(crate) fn on_call_speaking(self: &Arc<Self>, from: PeerId, body: &[u8]) -> Result<()> {
        let m: CallSpeaking = proto::ext_body(body)?;
        let Ok(id) = <[u8; 16]>::try_from(m.call_id.as_slice()) else { return Ok(()) };
        let Some(c) = self.remote.calls.lock().get(&id).cloned() else { return Ok(()) };
        if c.peers.lock().contains(&from) {
            self.set_speaking(&c, from, m.on);
        }
        Ok(())
    }

    /// Heartbeats (mine) and expiry (everyone else's), for the life of the node.
    pub(super) fn spawn_voice_loop(self: &Arc<Self>) {
        if self.voice.started.swap(true, Ordering::SeqCst) {
            return;
        }
        let weak = Arc::downgrade(self);
        tokio::spawn(async move {
            let mut last_beat = Instant::now();
            let mut beats = 0u32;
            loop {
                tokio::time::sleep(Duration::from_secs(1)).await;
                let Some(node) = weak.upgrade() else { return };
                if *node.shutdown.borrow() {
                    return;
                }
                node.voice_tick(&mut last_beat, &mut beats);
            }
        });
    }

    fn voice_tick(self: &Arc<Self>, last_beat: &mut Instant, beats: &mut u32) {
        let now = Instant::now();
        let expired = self.voice.presence.lock().expire(now, presence_ttl(), &self.device);
        let mine = self.my_room();
        let mut convs: Vec<String> = vec![];
        for (conv, _, dev) in expired {
            if mine.as_ref().is_some_and(|m| m.conv == conv) {
                self.room_drop_peer(&dev);
            }
            if !convs.contains(&conv) {
                convs.push(conv);
            }
        }
        for c in convs {
            self.emit_voice(&c);
        }
        if now.saturating_duration_since(*last_beat) < heartbeat() {
            return;
        }
        *last_beat = now;
        *beats = beats.wrapping_add(1);
        let Some(m) = mine else { return };
        // removed from the community / channel deleted meanwhile: leave
        if self.voice_channel(&m.conv).is_none() {
            self.end_call(&m.call_id, false);
            return;
        }
        let muted = self.room_call().map(|c| !c.mic.load(Ordering::Relaxed)).unwrap_or(false);
        self.voice.presence.lock().here(&m.conv, self.me, self.device, m.since, muted, now);
        // every third beat also reaches members we have no connection to (yet)
        self.voice_announce(&m.conv, true, m.since, muted, beats.is_multiple_of(3));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Identity;

    fn pid() -> PeerId {
        Identity::generate().peer_id()
    }

    #[test]
    fn join_heartbeat_mute_and_leave() {
        let mut p = Presence::default();
        let (a, d) = (pid(), pid());
        let t0 = Instant::now();
        let r = p.here("g:aa#voice", a, d, 100, false, t0);
        assert!(r.changed && r.joined && !r.stale);
        // heartbeat: nothing changes
        assert_eq!(p.here("g:aa#voice", a, d, 100, false, t0), Here::default());
        // mute: changed, still not a join
        let r = p.here("g:aa#voice", a, d, 100, true, t0);
        assert!(r.changed && !r.joined);
        assert!(p.participants("g:aa#voice")[0].1.muted);
        // a "gone" for another join / device is ignored
        assert!(!p.gone("g:aa#voice", &a, &pid(), 100));
        assert!(!p.gone("g:aa#voice", &a, &d, 99));
        assert!(p.gone("g:aa#voice", &a, &d, 100));
        assert!(p.participants("g:aa#voice").is_empty());
    }

    #[test]
    fn one_device_per_account_newest_join_wins() {
        let mut p = Presence::default();
        let (a, d1, d2) = (pid(), pid(), pid());
        let t = Instant::now();
        p.here("g:aa#voice", a, d1, 100, false, t);
        // the same account joins on another device later: it replaces the first
        let r = p.here("g:aa#voice", a, d2, 200, false, t);
        assert_eq!(r.replaced, Some(d1));
        assert_eq!(p.participants("g:aa#voice").len(), 1);
        // a late heartbeat of the old join is stale
        assert!(p.here("g:aa#voice", a, d1, 100, false, t).stale);
        assert_eq!(p.participants("g:aa#voice")[0].1.device, d2);
        // the old device's "gone" doesn't remove the new one
        assert!(!p.gone("g:aa#voice", &a, &d1, 100));
        // moving to another room
        let r = p.here("g:aa#lounge", a, d1, 300, false, t);
        assert_eq!(r.moved_from, Some(("g:aa#voice".to_string(), d2)));
        assert!(p.participants("g:aa#voice").is_empty());
        assert_eq!(p.rooms_of("g:aa#"), vec!["g:aa#lounge".to_string()]);
    }

    #[test]
    fn equal_join_times_resolve_the_same_everywhere() {
        let (a, d1, d2) = (pid(), pid(), pid());
        let t = Instant::now();
        let mut x = Presence::default();
        x.here("r", a, d1, 5, false, t);
        x.here("r", a, d2, 5, false, t);
        let mut y = Presence::default();
        y.here("r", a, d2, 5, false, t);
        y.here("r", a, d1, 5, false, t);
        assert_eq!(x.participants("r")[0].1.device, y.participants("r")[0].1.device);
    }

    #[test]
    fn stale_presence_expires_but_never_mine() {
        let mut p = Presence::default();
        let (me, my_dev, b, bd, c, cd) = (pid(), pid(), pid(), pid(), pid(), pid());
        let t0 = Instant::now();
        let ttl = Duration::from_secs(30);
        p.here("r", me, my_dev, 1, false, t0);
        p.here("r", b, bd, 2, false, t0);
        p.here("r", c, cd, 3, false, t0);
        assert!(p.expire(t0 + Duration::from_secs(29), ttl, &my_dev).is_empty());
        // c's heartbeat keeps it
        p.here("r", c, cd, 3, false, t0 + Duration::from_secs(20));
        let gone = p.expire(t0 + Duration::from_secs(31), ttl, &my_dev);
        assert_eq!(gone, vec![("r".to_string(), b, bd)]);
        let left: Vec<PeerId> = p.participants("r").into_iter().map(|(a, _)| a).collect();
        assert_eq!(left, vec![me, c]);
        let gone = p.expire(t0 + Duration::from_secs(120), ttl, &my_dev);
        assert_eq!(gone, vec![("r".to_string(), c, cd)]);
        assert_eq!(p.participants("r").len(), 1);
    }

    #[test]
    fn heartbeat_fits_the_ttl_and_room_ids_are_shared() {
        assert!(heartbeat() * 3 < presence_ttl());
        assert_eq!(room_call_id("g:aa#voice"), room_call_id("g:aa#voice"));
        assert_ne!(room_call_id("g:aa#voice"), room_call_id("g:aa#lounge"));
    }

    #[test]
    fn vad_opens_on_speech_and_holds_briefly() {
        let mut v = Vad::default();
        let quiet = vec![10i16; 960];
        let loud: Vec<i16> = (0..960).map(|i| if i % 2 == 0 { 6000 } else { -6000 }).collect();
        assert!(!v.step(Some(&quiet)));
        assert!(v.step(Some(&loud)));
        for _ in 0..Vad::HOLD {
            assert!(v.step(Some(&quiet)));
        }
        assert!(!v.step(Some(&quiet)));
        assert!(v.step(Some(&loud)));
        // muted: closes at once
        assert!(!v.step(None));
    }

    async fn community(dir: &std::path::Path) -> (Arc<Node>, Gid) {
        let n = Node::start(super::super::NodeConfig {
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
        .unwrap();
        let v = n.create_group("Phòng", vec![], 1).await.unwrap();
        let gid: Gid = hex::decode(v["gid"].as_str().unwrap()).unwrap().try_into().unwrap();
        n.group_channel(gid, "loa", true, false).await.unwrap();
        n.group_channel(gid, "loa2", true, false).await.unwrap();
        (n, gid)
    }

    fn room(gid: &Gid, ch: &str) -> String {
        format!("g:{}#{ch}", hex::encode(gid))
    }

    /// V1: an invite / answer naming a room's call id never puts a device into the room.
    #[tokio::test]
    async fn room_calls_are_joined_through_presence_only() {
        let tmp = tempfile::tempdir().unwrap();
        let (n, gid) = community(tmp.path()).await;
        let conv = room(&gid, "loa");
        n.voice_join(&conv).await.unwrap();
        let c = n.remote.calls.lock().get(&room_call_id(&conv)).cloned().unwrap();
        assert!(c.room);
        // even a member of the community (here: my own account) can't be invited in
        let stranger = pid();
        assert!(!super::super::remote::call_may_join(&n, &c, &stranger, &n.me));
        assert!(!super::super::remote::call_may_join(&n, &c, &stranger, &stranger));
        assert!(c.peers.lock().is_empty());
        n.shutdown();
    }

    /// V2: a dissolved community has no voice rooms (can't be joined; mine is left).
    #[tokio::test]
    async fn dissolved_community_has_no_rooms() {
        let tmp = tempfile::tempdir().unwrap();
        let (n, gid) = community(tmp.path()).await;
        let conv = room(&gid, "loa");
        assert!(n.voice_channel(&conv).is_some());
        n.group_dissolve(gid).await.unwrap();
        assert!(n.voice_channel(&conv).is_none());
        assert!(n.voice_join(&conv).await.is_err());
        n.shutdown();
    }

    /// V3: my other device's clock runs ahead: my new join still wins (since > theirs).
    #[tokio::test]
    async fn my_join_beats_a_sibling_whose_clock_runs_ahead() {
        let tmp = tempfile::tempdir().unwrap();
        let (n, gid) = community(tmp.path()).await;
        let conv = room(&gid, "loa");
        let sib = pid();
        let ahead = now_ms() + 5 * 60_000;
        let body = rmp_serde::to_vec_named(&VoicePresence { conv: conv.clone(), here: true, since: ahead, muted: false }).unwrap();
        n.on_voice_presence(sib, n.me, &body).unwrap();
        assert_eq!(n.voice.presence.lock().find(&n.me).unwrap().1.device, sib);
        n.voice_join(&conv).await.unwrap();
        let (c, e) = n.voice.presence.lock().find(&n.me).unwrap();
        assert_eq!((c.as_str(), e.device), (conv.as_str(), n.device), "the sibling's older join won");
        assert!(e.since > ahead);
        assert_eq!(n.my_room().unwrap().since, e.since);
        n.shutdown();
    }

    /// V4: joins racing on several threads leave exactly one call, the one I'm in.
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn concurrent_joins_leave_one_call() {
        let tmp = tempfile::tempdir().unwrap();
        let (n, gid) = community(tmp.path()).await;
        for _ in 0..20 {
            let (a, b) = (room(&gid, "loa"), room(&gid, "loa2"));
            let (n1, n2) = (n.clone(), n.clone());
            let j1 = tokio::spawn(async move { n1.voice_join(&a).await });
            let j2 = tokio::spawn(async move { n2.voice_join(&b).await });
            let (r1, r2) = (j1.await.unwrap(), j2.await.unwrap());
            assert!(r1.is_ok() || r2.is_ok());
            let calls: Vec<[u8; 16]> = n.remote.calls.lock().keys().copied().collect();
            assert_eq!(calls.len(), 1, "orphaned call");
            assert_eq!(n.my_room().map(|m| m.call_id), Some(calls[0]));
            let m = n.my_room().unwrap();
            n.end_call(&m.call_id, false);
            assert!(n.remote.calls.lock().is_empty());
        }
        n.shutdown();
    }

}
