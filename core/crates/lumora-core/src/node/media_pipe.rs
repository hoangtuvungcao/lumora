//! Media plumbing between `lumora-media` and the network.
//!
//! * Video: capture → VP8/VP9 (bundled libvpx) or H.264 (OS hardware codec), chosen per
//!   call from both sides' codec caps (`Ext VIDEO_CAPS`, sent with the call invite/answer
//!   and the remote-control request — no extra round trip) → one QUIC uni-stream per
//!   frame with a per-peer send window (`SendWindow`: a few frames until acknowledged;
//!   the encoder skips frames while it is full, stale streams are reset, a dropped
//!   frame forces a keyframe and lowers the bitrate — latency never builds up in QUIC's
//!   buffers). The stream header carries the format id, so a sender can switch
//!   (hardware H.264 failed → VP8) on any keyframe, and a frame sequence number: the
//!   receiver drops stale/reordered frames and, after any gap, waits for (and asks for)
//!   a keyframe instead of decoding garbage (`lumora_media::FrameSync`).
//! * Input: QUIC datagrams (lowest latency), injected on the host.
//! * Audio: 20 ms Opus frames as datagrams, per-peer adaptive jitter buffer + PLC.

use super::remote::{Call, Role, Session};
use super::*;
use bytes::Bytes;
use lumora_media::{CaptureOptions, DisplayInfo, Frame, InputEvent, MouseButton, PixelFormat, VideoFormat};
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU32, Ordering};

const MAX_FRAME_BYTES: usize = 8 * 1024 * 1024;

/// Frames per peer between "stream opened" and "peer acknowledged all of it": at
/// least 2, more only to cover the path's base round trip at the stream's frame
/// rate (so a long RTT doesn't cap the frame rate), at most [`MAX_IN_FLIGHT`]. A
/// new frame never queues behind more than that: the encoder skips frames while a
/// peer's window is full (no broken reference chain, lower frame rate, and the
/// bitrate controller backs off), and a frame produced anyway is dropped (the peer
/// then resyncs on a keyframe) instead of piling up in QUIC's 32 MB send buffer.
const MIN_IN_FLIGHT: usize = 2;
const MAX_IN_FLIGHT: usize = 8;
/// A delta frame not acknowledged after this long is reset (the peer resyncs on a
/// keyframe); keyframes get [`STALE_KEY`] (a slow link needs time for a big one).
const STALE_DELTA: Duration = Duration::from_millis(1500);
const STALE_KEY: Duration = Duration::from_secs(5);
/// Minimum time between two keyframes forced by requests/drops (a periodic or
/// size-change keyframe doesn't count). Many requests → one keyframe.
const KEYFRAME_EVERY: Duration = Duration::from_millis(300);
/// Frames waiting for the decoder thread of one stream.
const DEC_QUEUE: usize = 4;

type DecoderKey = ([u8; 16], PeerId, bool);
type DecoderMap = HashMap<DecoderKey, (u32, Arc<DecQueue>)>;
/// (session or call id, camera?) — a call can carry a camera and a screen stream.
type SlotKey = ([u8; 16], bool);

enum PlayerSlot {
    /// the speaker is being opened on another thread (packets are dropped meanwhile)
    Opening,
    Ready(Arc<lumora_media::audio::AudioPlayer>),
}

#[derive(Default)]
pub struct MediaState {
    /// incoming video: (session, from, camera) → (local stream id, decoder thread input)
    decoders: Mutex<DecoderMap>,
    /// outgoing video keyframe flags by (session/call id, camera)
    keyframes: Mutex<HashMap<SlotKey, Arc<AtomicBool>>>,
    players: Mutex<HashMap<PeerId, PlayerSlot>>,
    /// last time opening the speaker failed (don't retry on every packet)
    player_failed: Mutex<Option<std::time::Instant>>,
    /// stop flags of call camera / screen senders by (call id, camera)
    screen_stop: Mutex<HashMap<SlotKey, Arc<AtomicBool>>>,
    pub(crate) last_switch: Mutex<Option<std::time::Instant>>,
    /// video codec capabilities announced by each device (`Ext VIDEO_CAPS`); a device
    /// without an entry is an older build: H.264 only
    peer_caps: Mutex<HashMap<PeerId, lumora_media::Caps>>,
}

impl MediaState {
    /// Drop decoders/streams/players belonging to a finished session or call.
    pub fn cleanup(&self, id: &[u8; 16], peers: &[PeerId]) -> Vec<u32> {
        let mut streams = vec![];
        self.decoders.lock().retain(|(sid, _, _), (st, q)| {
            if sid == id {
                streams.push(*st);
                q.close();
                false
            } else {
                true
            }
        });
        {
            let mut k = self.keyframes.lock();
            k.remove(&(*id, false));
            k.remove(&(*id, true));
        }
        {
            let mut stops = self.screen_stop.lock();
            for cam in [false, true] {
                if let Some(s) = stops.remove(&(*id, cam)) {
                    s.store(true, Ordering::SeqCst);
                }
            }
        }
        let gone: Vec<PlayerSlot> = {
            let mut ps = self.players.lock();
            peers.iter().filter_map(|p| ps.remove(p)).collect()
        };
        drop(gone); // (closing a speaker joins its thread: never under the lock)
        streams
    }

    /// `peer` left call `id` (the call goes on): drop its decoders and speaker.
    /// Returns its (local stream id, camera?) pairs.
    pub fn remove_peer(&self, id: &[u8; 16], peer: &PeerId) -> Vec<(u32, bool)> {
        let mut streams = vec![];
        self.decoders.lock().retain(|(sid, from, cam), (st, q)| {
            if sid == id && from == peer {
                streams.push((*st, *cam));
                q.close();
                false
            } else {
                true
            }
        });
        let gone = self.players.lock().remove(peer);
        drop(gone);
        streams
    }

    /// A keyframe request for `stream` (0 = every stream we send to the requester,
    /// else [`keyframe_tag`]) concerning the sessions/calls in `ids` — the ones the
    /// requester is an authorised participant of (checked by the caller). The
    /// encoder honours flags at most every [`KEYFRAME_EVERY`].
    pub fn request_keyframe(&self, ids: &[[u8; 16]], stream: u32) {
        let k = self.keyframes.lock();
        for id in ids {
            for cam in [false, true] {
                if stream == 0 || stream == keyframe_tag(id, cam) {
                    if let Some(f) = k.get(&(*id, cam)) {
                        f.store(true, Ordering::SeqCst);
                    }
                }
            }
        }
    }
}

/// The `stream` of a `KeyframeRequest` naming one outgoing stream: high bit set,
/// bit 30 = camera, the rest from the session/call id. (Stream ids are local to
/// each device, so the receiver can't name the sender's; 0 still means "every
/// stream you send me", which older hosts expect.)
pub(crate) fn keyframe_tag(session: &[u8; 16], camera: bool) -> u32 {
    0x8000_0000 | ((camera as u32) << 30) | (u32::from_be_bytes([session[0], session[1], session[2], session[3]]) & 0x3fff_ffff)
}

/// Stable id of a sender for the decoder's per-peer H.264 health
/// (`VideoDecoder::set_source`).
fn source_id(p: &PeerId) -> u64 {
    u64::from_be_bytes(p.0[..8].try_into().unwrap_or_default())
}

/// Media stream header (after the stream kind byte): session[16] flags[1] w[4] h[4] x[8].
/// flags: bit 0 keyframe, bit 1 camera, bits 2-3 format (0 = H.264 — all older builds,
/// 1 = VP8, 2 = VP9; older receivers ignore these bits), bit 4 = `x` holds the frame
/// sequence number (u32, +1 per frame the sender's encoder produced, so a gap means a
/// lost frame) and the sender's millisecond clock (u32). Older senders put a
/// microsecond timestamp in `x`, which receivers never used.
pub(crate) const HDR_LEN: usize = 33;
const FLAG_SEQ: u8 = 0x10;

#[allow(clippy::too_many_arguments)]
fn header(session: &[u8; 16], key: bool, camera: bool, format: VideoFormat, w: u32, h: u32, seq: u32, ts_ms: u32) -> Vec<u8> {
    let mut v = Vec::with_capacity(1 + HDR_LEN);
    v.push(proto::STREAM_MEDIA);
    v.extend_from_slice(session);
    v.push(key as u8 | ((camera as u8) << 1) | ((format.wire_id() & 3) << 2) | FLAG_SEQ);
    v.extend_from_slice(&w.to_be_bytes());
    v.extend_from_slice(&h.to_be_bytes());
    v.extend_from_slice(&seq.to_be_bytes());
    v.extend_from_slice(&ts_ms.to_be_bytes());
    v
}

/// Parsed media stream header.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct MediaHeader {
    pub session: [u8; 16],
    pub key: bool,
    pub camera: bool,
    /// `None`: a format from the future
    pub format: Option<VideoFormat>,
    /// `None`: an older sender
    pub seq: Option<u32>,
    pub ts_ms: Option<u32>,
}

pub(crate) fn parse_header(h: &[u8; HDR_LEN]) -> MediaHeader {
    let f = h[16];
    let seq_present = f & FLAG_SEQ != 0;
    MediaHeader {
        session: h[..16].try_into().unwrap_or_default(),
        key: f & 1 == 1,
        camera: f & 2 == 2,
        format: VideoFormat::from_wire((f >> 2) & 3),
        seq: seq_present.then(|| u32::from_be_bytes([h[25], h[26], h[27], h[28]])),
        ts_ms: seq_present.then(|| u32::from_be_bytes([h[29], h[30], h[31], h[32]])),
    }
}

fn now_ms32() -> u32 {
    (lumora_media::now_us() / 1000) as u32
}

// ------------------------------------------------------------------ codec negotiation

/// Start probing the OS H.264 codec (cached per device/OS build in the data dir).
/// Called at startup so calls never wait for it.
pub fn warm_up(node: &Arc<Node>) {
    lumora_media::codec::start_probe(Some(&node.cfg.data_dir));
}

/// Our codec caps for `dev` as an `Ext` (v3 peers only; older peers can't decode it).
/// H.264 decoding is left out for a peer whose streams broke our OS decoder.
fn caps_msg(dev: &PeerId) -> PeerMsg {
    proto::ext(proto::ext::VIDEO_CAPS, &lumora_media::codec::local_caps_for(source_id(dev)))
}

/// Announce our codecs to `pc` right before an invite/answer/request on the same
/// ordered control stream, so the other side knows them the moment it needs them.
pub(crate) fn send_caps(node: &Arc<Node>, pc: &Arc<PeerConn>) {
    warm_up(node);
    if pc.proto.load(Ordering::Relaxed) >= proto::PROTO_V3 || node.dev_speaks_v3(&pc.peer) {
        let _ = pc.ctl.try_send(caps_msg(&pc.peer));
    }
}

/// Same as [`send_caps`], to a device by id (no dialing).
pub(crate) fn send_caps_to(node: &Arc<Node>, dev: &PeerId) {
    warm_up(node);
    node.send_now_dev(dev, caps_msg(dev));
}

/// `Ext VIDEO_CAPS` from a device.
pub(crate) fn on_video_caps(node: &Arc<Node>, pc: &Arc<PeerConn>, body: &[u8]) -> Result<()> {
    let mut caps: lumora_media::Caps = proto::ext_body(body)?;
    for v in [&mut caps.enc, &mut caps.dec, &mut caps.hw_enc, &mut caps.hw_dec] {
        v.truncate(16);
    }
    node.remote.media.peer_caps.lock().insert(pc.peer, caps);
    Ok(())
}

/// The format to send to `peers` right now (`None`: an older peer needs H.264 and this
/// device has none).
fn send_format(node: &Arc<Node>, peers: &[PeerId], screen: bool) -> Option<VideoFormat> {
    let caps = node.remote.media.peer_caps.lock();
    let pc: Vec<Option<lumora_media::Caps>> = peers.iter().map(|p| caps.get(p).cloned()).collect();
    drop(caps);
    lumora_media::codec::choose_format(&lumora_media::codec::local_caps(), &pc, screen)
}

/// Every peer decodes VP8 (no older builds) → safe fallback when H.264 fails.
fn vp8_fallback(node: &Arc<Node>, peers: &[PeerId]) -> Option<VideoFormat> {
    let caps = node.remote.media.peer_caps.lock();
    peers.iter().all(|p| caps.get(p).is_some_and(|c| c.dec.contains(&VideoFormat::Vp8))).then_some(VideoFormat::Vp8)
}

// ------------------------------------------------------------------ send side

/// One frame stream on its way to a peer.
struct Flight {
    key: bool,
    started: std::time::Instant,
    done: Arc<AtomicBool>,
    /// fire (or drop) to reset the stream: a newer keyframe made it stale
    cancel: Option<tokio::sync::oneshot::Sender<()>>,
}

impl Flight {
    fn reset(&mut self) {
        if let Some(c) = self.cancel.take() {
            let _ = c.send(());
        }
    }

    fn stale(&self, now: std::time::Instant) -> bool {
        now.duration_since(self.started) >= if self.key { STALE_KEY } else { STALE_DELTA }
    }
}

/// What to do with a new frame for one peer.
#[derive(Debug, PartialEq)]
enum Offer {
    Send,
    /// dropped: the window is full (count it, ask the encoder for a keyframe)
    Drop,
    /// a delta for a peer that waits for a keyframe anyway
    Skip,
}

/// Per-peer send window (backpressure).
struct SendWindow {
    flights: Vec<Flight>,
    /// a frame was dropped: deltas are useless to this peer until the next keyframe
    need_key: bool,
    /// frames allowed in flight (see [`MIN_IN_FLIGHT`])
    limit: usize,
    base_rtt: Option<Duration>,
}

impl Default for SendWindow {
    fn default() -> Self {
        Self { flights: Vec::new(), need_key: false, limit: MIN_IN_FLIGHT, base_rtt: None }
    }
}

impl SendWindow {
    /// Size the window to the path's lowest RTT seen and the frame rate.
    fn set_rtt(&mut self, rtt: Duration, fps: u32) {
        if rtt.is_zero() {
            return;
        }
        let base = self.base_rtt.map_or(rtt, |b| b.min(rtt));
        self.base_rtt = Some(base);
        let per_rtt = (base.as_secs_f64() * fps.max(1) as f64).ceil() as usize;
        self.limit = (per_rtt + MIN_IN_FLIGHT).clamp(MIN_IN_FLIGHT, MAX_IN_FLIGHT);
    }

    fn prune(&mut self, now: std::time::Instant) {
        for f in self.flights.iter_mut().filter(|f| f.stale(now) && !f.done.load(Ordering::SeqCst)) {
            // never acknowledged in time: give up on it, the peer resyncs on a keyframe
            f.reset();
            self.need_key = true;
        }
        self.flights.retain(|f| f.cancel.is_some() && !f.done.load(Ordering::SeqCst));
    }

    /// Room for one more frame? (Stale flights don't count: they get reset.)
    fn has_room(&self, now: std::time::Instant) -> bool {
        self.flights.iter().filter(|f| !f.done.load(Ordering::SeqCst) && !f.stale(now)).count() < self.limit
    }

    fn offer(&mut self, key: bool) -> Offer {
        self.prune(std::time::Instant::now());
        if !key && self.need_key {
            return Offer::Skip;
        }
        if key && self.flights.len() >= self.limit {
            // a keyframe makes every older delta useless: reset those streams. An
            // older keyframe in flight is kept (it may be the peer's only way back).
            for f in self.flights.iter_mut().filter(|f| !f.key) {
                f.reset();
            }
            self.flights.retain(|f| f.key);
        }
        if self.flights.len() < self.limit {
            if key {
                self.need_key = false;
            }
            return Offer::Send;
        }
        self.need_key = true;
        Offer::Drop
    }
}

/// The send windows of one video sender's peers, shared by the network task and the
/// encoder thread (which skips frames while any window is full).
#[derive(Default)]
struct SendGate {
    peers: Mutex<HashMap<PeerId, SendWindow>>,
}

impl SendGate {
    fn has_room(&self) -> bool {
        let now = std::time::Instant::now();
        self.peers.lock().values().all(|w| w.has_room(now))
    }
}

/// Write one frame on its own uni stream and wait until the peer acknowledged all
/// of it (QUIC buffers up to the 32 MB send window, so "written" means nothing for
/// latency). `cancel` resets the stream.
fn spawn_flight(conn: quinn::Connection, hdr: Vec<u8>, data: Bytes, key: bool) -> Flight {
    let done = Arc::new(AtomicBool::new(false));
    let (ctx, mut crx) = tokio::sync::oneshot::channel::<()>();
    let d2 = done.clone();
    tokio::spawn(async move {
        let opened = tokio::select! {
            s = conn.open_uni() => s.ok(),
            _ = &mut crx => None,
        };
        if let Some(mut s) = opened {
            let _ = s.set_priority(if key { 2 } else { 1 });
            let written = tokio::select! {
                r = async {
                    s.write_all(&hdr).await?;
                    s.write_all(&data).await?;
                    anyhow::Ok(())
                } => Some(r.is_ok()),
                _ = &mut crx => None,
            };
            match written {
                Some(true) => {
                    let _ = s.finish();
                    let acked = s.stopped();
                    tokio::select! {
                        _ = acked => {}
                        _ = &mut crx => { let _ = s.reset(0u32.into()); }
                    }
                }
                Some(false) => {}
                None => {
                    let _ = s.reset(0u32.into());
                }
            }
        }
        d2.store(true, Ordering::SeqCst);
    });
    Flight { key, started: std::time::Instant::now(), done, cancel: Some(ctx) }
}

/// Encoded frames → every peer, with backpressure ([`SendWindow`]). A drop asks the
/// encoder for a keyframe and counts in `drops` (read by the bitrate controller).
#[allow(clippy::too_many_arguments)]
async fn fan_out(
    mut rx: mpsc::Receiver<lumora_media::EncodedFrame>,
    targets: impl Fn() -> Vec<(PeerId, quinn::Connection)>,
    gate: Arc<SendGate>,
    stop: Arc<AtomicBool>,
    session: [u8; 16],
    camera: bool,
    fps: u32,
    keyframe: Arc<AtomicBool>,
    drops: Arc<AtomicU32>,
) {
    // Starts at this process's millisecond clock (sends ≤ 1 frame per ms): a sender
    // restarted for the same session/call (display switch, camera off → on) always
    // continues *after* its predecessor, so the receiver never takes its frames
    // for stale ones.
    let mut seq = now_ms32();
    while let Some(ef) = rx.recv().await {
        if stop.load(Ordering::Relaxed) {
            break;
        }
        let hdr = header(&session, ef.keyframe, camera, ef.codec, ef.w, ef.h, seq, now_ms32());
        seq = seq.wrapping_add(1);
        let targets = targets();
        let mut windows = gate.peers.lock();
        windows.retain(|p, _| targets.iter().any(|(t, _)| t == p));
        for (p, conn) in targets {
            let w = windows.entry(p).or_default();
            w.set_rtt(conn.rtt(), fps);
            match w.offer(ef.keyframe) {
                Offer::Send => w.flights.push(spawn_flight(conn, hdr.clone(), ef.data.clone(), ef.keyframe)),
                Offer::Drop => {
                    drops.fetch_add(1, Ordering::Relaxed);
                    keyframe.store(true, Ordering::SeqCst);
                }
                Offer::Skip => keyframe.store(true, Ordering::SeqCst),
            }
        }
    }
    for w in gate.peers.lock().values_mut() {
        for f in &mut w.flights {
            f.reset();
        }
    }
}

/// Spawn capture+encode on a thread and fan frames out to `peers`.
#[allow(clippy::too_many_arguments)]
fn start_video_sender(
    node: &Arc<Node>,
    session: [u8; 16],
    _display: u32,
    peers: Arc<dyn Fn() -> Vec<PeerId> + Send + Sync>,
    stop: Arc<AtomicBool>,
    keyframe: Arc<AtomicBool>,
    bitrate: Arc<AtomicU32>,
    cap: Box<dyn lumora_media::Capturer>,
    fps: u32,
    camera: bool,
) {
    let slot: SlotKey = (session, camera);
    node.remote.media.keyframes.lock().insert(slot, keyframe.clone());
    let (tx, rx) = mpsc::channel::<lumora_media::EncodedFrame>(3);
    // frames dropped by the send windows or skipped because a window was full
    // (backpressure), read by the bitrate controller
    let drops = Arc::new(AtomicU32::new(0));
    let gate = Arc::new(SendGate::default());
    // Adaptive bitrate (AIMD): start at 60% of the cap, back off on loss / RTT spikes /
    // frames the network couldn't take, probe upwards when the path is clean. Keeps
    // latency low on Wi-Fi/4G.
    let target = Arc::new(AtomicU32::new((bitrate.load(Ordering::Relaxed) * 6 / 10).max(800)));
    {
        let node = node.clone();
        let peers = peers.clone();
        let stop = stop.clone();
        let cap = bitrate.clone();
        let target = target.clone();
        let drops = drops.clone();
        tokio::spawn(async move {
            let mut base_rtt = u128::MAX;
            let mut last: HashMap<PeerId, (u64, u64)> = HashMap::new();
            let mut tick = 0u32;
            let mut last_cut: Option<std::time::Instant> = None;
            while !stop.load(Ordering::Relaxed) {
                tokio::time::sleep(Duration::from_millis(250)).await;
                tick = tick.wrapping_add(1);
                let capv = cap.load(Ordering::Relaxed);
                let cur = target.load(Ordering::Relaxed);
                // the network is behind (frames dropped): cut right away, at most every 500 ms
                if drops.swap(0, Ordering::Relaxed) > 0 {
                    if last_cut.is_none_or(|t| t.elapsed() >= Duration::from_millis(500)) {
                        last_cut = Some(std::time::Instant::now());
                        target.store(((cur as f64 * 0.7) as u32).clamp(400, capv.max(400)), Ordering::Relaxed);
                    }
                    continue;
                }
                if !tick.is_multiple_of(4) {
                    continue;
                }
                let mut worst_loss = 0.0f64;
                let mut worst_rtt = 0u128;
                for p in peers() {
                    let Some(pc) = node.peer(&p) else { continue };
                    let st = pc.conn.stats();
                    let (sent, lost) = (st.path.sent_packets, st.path.lost_packets);
                    let (ps, pl) = last.insert(p, (sent, lost)).unwrap_or((sent, lost));
                    let ds = sent.saturating_sub(ps).max(1);
                    worst_loss = worst_loss.max(lost.saturating_sub(pl) as f64 / ds as f64);
                    worst_rtt = worst_rtt.max(st.path.rtt.as_millis());
                }
                if worst_rtt > 0 {
                    base_rtt = base_rtt.min(worst_rtt);
                }
                let congested = worst_loss > 0.03 || (base_rtt != u128::MAX && worst_rtt > base_rtt * 2 + 40);
                // no probing for 2 s after the network dropped frames
                let calm = last_cut.is_none_or(|t| t.elapsed() >= Duration::from_secs(2));
                let next = if congested {
                    (cur as f64 * 0.7) as u32
                } else if calm {
                    cur + (capv / 20).max(150)
                } else {
                    cur
                };
                target.store(next.clamp(400, capv.max(400)), Ordering::Relaxed);
            }
        });
    }
    // encoder thread
    let stop2 = stop.clone();
    let kf = keyframe.clone();
    let br = target.clone();
    // camera: effects before encoding + the local self-view (processed frames)
    let mut fx = camera.then(|| CameraFx::new(node, session, fps));
    let node_enc = node.clone();
    let peers_enc = peers.clone();
    let gate_enc = gate.clone();
    let drops_enc = drops.clone();
    std::thread::Builder::new()
        .name("lumora-video-enc".into())
        .spawn(move || {
            let mut cap = cap;
            let mut enc: Option<lumora_media::VideoEncoder> = None;
            let mut size = (0u32, 0u32);
            let mut cur_br = 0u32;
            // negotiated format, re-checked a few times a second (group members join/leave)
            let mut fmt: Option<VideoFormat> = None;
            let mut fmt_checked: Option<std::time::Instant> = None;
            let mut noted = false;
            let mut cur_fb: Option<VideoFormat> = None;
            // screen: the last frame encoded, to skip unchanged ones (idle desktop ≈ 0 CPU)
            let mut prev: Option<(Frame, std::time::Instant)> = None;
            // last keyframe sent: requests/drops force at most one every KEYFRAME_EVERY
            let mut last_key: Option<std::time::Instant> = None;
            while !stop2.load(Ordering::Relaxed) {
                let f = match cap.next_frame(Duration::from_millis(200)) {
                    Ok(Some(f)) => f,
                    Ok(None) => continue,
                    Err(e) => {
                        tracing::warn!("capture ended: {e:#}");
                        break;
                    }
                };
                if fmt_checked.is_none_or(|t| t.elapsed() >= Duration::from_millis(250)) {
                    fmt_checked = Some(std::time::Instant::now());
                    let ps = peers_enc();
                    let want = send_format(&node_enc, &ps, !camera);
                    if want.is_none() && !ps.is_empty() && !noted {
                        // an older peer that only takes H.264, and this device has no H.264
                        noted = true;
                        node_enc.emit("video_note", json!({"session": hex::encode(session), "reason": "peer_needs_update", "camera": camera}));
                    }
                    if want != fmt {
                        fmt = want;
                        match (fmt, enc.as_mut()) {
                            (Some(f), Some(e)) => e.set_format(f),
                            (None, _) => enc = None,
                            _ => {}
                        }
                    }
                    // an older peer joined (no VP8 fallback any more) or left: rebuild
                    let fb = vp8_fallback(&node_enc, &ps);
                    if fb != cur_fb {
                        cur_fb = fb;
                        enc = None;
                    }
                }
                let Some(format) = fmt else { continue };
                if enc.is_none() || size != (f.width, f.height) {
                    size = (f.width, f.height);
                    cur_br = br.load(Ordering::Relaxed);
                    let cfg = lumora_media::EncoderConfig {
                        fps,
                        bitrate_kbps: cur_br,
                        content: if camera { lumora_media::ContentHint::Motion } else { lumora_media::ContentHint::Screen },
                        format,
                        fallback: cur_fb,
                        ..Default::default()
                    };
                    enc = lumora_media::VideoEncoder::with_config(cfg).ok();
                    kf.store(true, Ordering::SeqCst);
                    last_key = None;
                }
                let Some(e) = enc.as_mut() else { continue };
                if !camera && !kf.load(Ordering::Relaxed) {
                    if let Some((p, at)) = &prev {
                        if at.elapsed() < Duration::from_secs(2) && f.same_pixels(p) {
                            continue; // nothing changed on screen: don't encode or send
                        }
                    }
                }
                // a peer's send window is full: skip this frame (lower frame rate, the
                // reference chain stays intact) instead of queueing latency
                if !gate_enc.has_room() {
                    drops_enc.fetch_add(1, Ordering::Relaxed);
                    continue;
                }
                if !camera {
                    prev = Some((f.clone(), std::time::Instant::now()));
                }
                let want = br.load(Ordering::Relaxed);
                if want != cur_br {
                    e.set_bitrate(want);
                    cur_br = want;
                }
                // keyframe requests (any number of peers) and drops: at most one forced
                // keyframe per KEYFRAME_EVERY; a pending request waits, it isn't lost
                let force = last_key.is_none_or(|t| t.elapsed() >= KEYFRAME_EVERY) && kf.swap(false, Ordering::SeqCst);
                let res = match fx.as_mut() {
                    Some(fx) => {
                        fx.refresh();
                        e.encode_with(&f, force, |yuv| fx.apply(yuv))
                    }
                    None => e.encode(&f, force),
                };
                match res {
                    Ok(Some(ef)) => {
                        if ef.keyframe {
                            last_key = Some(std::time::Instant::now());
                        }
                        if tx.try_send(ef).is_err() {
                            // network task is behind: drop this frame and resync with a keyframe
                            kf.store(true, Ordering::SeqCst);
                        }
                    }
                    Ok(None) => {}
                    Err(err) => tracing::debug!("encode: {err:#}"),
                }
            }
        })
        .ok();
    // network fan-out
    let node = node.clone();
    tokio::spawn(async move {
        let weak = Arc::downgrade(&node);
        let targets = move || -> Vec<(PeerId, quinn::Connection)> {
            let Some(node) = weak.upgrade() else { return vec![] };
            peers().into_iter().filter_map(|p| node.peer(&p).map(|pc| (p, pc.conn.clone()))).collect()
        };
        fan_out(rx, targets, gate, stop, session, camera, fps, keyframe.clone(), drops).await;
        // only our own flag: a restarted sender (display switch) may have replaced it
        let mut k = node.remote.media.keyframes.lock();
        if k.get(&slot).is_some_and(|f| Arc::ptr_eq(f, &keyframe)) {
            k.remove(&slot);
        }
    });
}

async fn open_capture(node: &Arc<Node>, display: u32, fps: u32, source: lumora_media::CaptureSource) -> Result<Box<dyn lumora_media::Capturer>> {
    // separate restore tokens: "remember my screen" vs "remember my window choice"
    let key = if source == lumora_media::CaptureSource::Monitor { "media.restore_token" } else { "media.restore_token.share" };
    let token = node.store.kv_get(key).and_then(|v| String::from_utf8(v).ok());
    let (cap, new_token) = tokio::task::spawn_blocking(move || {
        lumora_media::open_capturer(display, CaptureOptions { fps, cursor: true, restore_token: token, source })
    })
    .await??;
    if let Some(t) = new_token {
        let _ = node.store.kv_set(key, t.as_bytes());
    }
    Ok(cap)
}

/// Host side of a remote-desktop session. Returns (width, height, displays).
pub async fn start_host(node: &Arc<Node>, s: &Arc<Session>) -> Result<(u32, u32, Vec<(u32, u32, String)>)> {
    let display = s.display.load(Ordering::SeqCst);
    let cap = open_capture(node, display, 60, lumora_media::CaptureSource::Monitor).await?;
    let displays = cap.displays();
    let d = displays.iter().find(|d| d.index == display).or(displays.first()).cloned().unwrap_or_default();
    let peer = s.peer;
    start_video_sender(
        node,
        s.id,
        display,
        Arc::new(move || vec![peer]),
        s.stop.clone(),
        s.keyframe.clone(),
        s.bitrate.clone(),
        cap,
        60,
        false,
    );
    *node.remote.host_display.lock() = Some(d.clone());
    Ok((d.width, d.height, displays.iter().map(|x| (x.width, x.height, x.name.clone())).collect()))
}

pub fn restart_host(node: &Arc<Node>, s: &Arc<Session>) {
    // at most one display switch per second
    {
        let mut last = node.remote.media.last_switch.lock();
        if last.map(|t| t.elapsed() < Duration::from_secs(1)).unwrap_or(false) {
            return;
        }
        *last = Some(std::time::Instant::now());
    }
    s.stop.store(true, Ordering::SeqCst);
    let node = node.clone();
    let s = s.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let ns = Arc::new(Session::new(s.id, s.peer, Role::Host, s.view_only, s.stream));
        ns.accepted.store(true, Ordering::SeqCst);
        ns.control.store(s.control.load(Ordering::SeqCst), Ordering::SeqCst);
        ns.display.store(s.display.load(Ordering::SeqCst), Ordering::SeqCst);
        {
            // only replace the exact session we stopped, and only if it hasn't ended meanwhile
            let mut map = node.remote.sessions.lock();
            match map.get(&s.id) {
                Some(cur) if Arc::ptr_eq(cur, &s) && !s.ended.load(Ordering::SeqCst) => {
                    map.insert(s.id, ns.clone());
                }
                _ => return,
            }
        }
        if let Err(e) = start_host(&node, &ns).await {
            tracing::warn!("display switch failed: {e:#}");
        }
    });
}

// ------------------------------------------------------------------ receive side

/// One received frame on its way to the decoder thread.
struct Inbound {
    format: VideoFormat,
    seq: Option<u32>,
    key: bool,
    data: Vec<u8>,
}

/// Input of one decoder thread: a small queue that never drops a keyframe — when
/// it is full, a keyframe replaces the (older, now useless) frames queued before
/// it and a delta frame is dropped (the decoder then waits for a keyframe).
#[derive(Default)]
struct DecQueue {
    q: Mutex<VecDeque<Inbound>>,
    cv: parking_lot::Condvar,
    /// a frame was dropped here since the decoder thread last looked
    lost: AtomicBool,
    closed: AtomicBool,
}

impl DecQueue {
    fn push(&self, f: Inbound) {
        let mut q = self.q.lock();
        if q.len() >= DEC_QUEUE {
            if f.key {
                // only frames after this keyframe (reordered) are still useful
                q.retain(|x| matches!((x.seq, f.seq), (Some(a), Some(b)) if (a.wrapping_sub(b) as i32) > 0));
                while q.len() >= DEC_QUEUE {
                    q.pop_front();
                }
            } else {
                self.lost.store(true, Ordering::SeqCst);
                return;
            }
        }
        q.push_back(f);
        drop(q);
        self.cv.notify_one();
    }

    /// Next frame; `None` at `until` (or after a spurious wake-up).
    fn pop(&self, until: std::time::Instant) -> Option<Inbound> {
        let mut q = self.q.lock();
        if q.is_empty() && !self.closed.load(Ordering::SeqCst) {
            let _ = self.cv.wait_until(&mut q, until);
        }
        q.pop_front()
    }

    fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        let _g = self.q.lock();
        self.cv.notify_all();
    }
}

/// How a receive stream is shown.
#[derive(Clone, Copy)]
enum StreamKind {
    /// remote-desktop viewer: the session's stream id
    Viewer(u32),
    /// call participant: a stream id is allocated (and announced) on first use
    Call,
}

/// The decoder of (session, from, camera), created on first use — atomically: the
/// stream id is allocated and announced exactly once, however many frame streams
/// arrive at the same time.
fn decoder_for(node: &Arc<Node>, session: [u8; 16], from: PeerId, camera: bool, kind: StreamKind) -> (u32, Arc<DecQueue>) {
    let (local_stream, q) = {
        let mut map = node.remote.media.decoders.lock();
        if let Some((st, q)) = map.get(&(session, from, camera)) {
            return (*st, q.clone());
        }
        let st = match kind {
            StreamKind::Viewer(st) => st,
            StreamKind::Call => node.remote.alloc_stream(),
        };
        let q = Arc::new(DecQueue::default());
        map.insert((session, from, camera), (st, q.clone()));
        (st, q)
    };
    if matches!(kind, StreamKind::Call) {
        node.emit("video_stream", json!({
            "call_id": hex::encode(session), "peer": from.to_base32(), "stream": local_stream,
            "kind": if camera { "camera" } else { "screen" },
        }));
    }
    // which stream a keyframe request names (remote sessions: 0, what every host understands)
    let kf_stream = match kind {
        StreamKind::Viewer(_) => 0,
        StreamKind::Call => keyframe_tag(&session, camera),
    };
    let weak = Arc::downgrade(node);
    let created = std::time::Instant::now();
    let input = q.clone();
    std::thread::Builder::new()
        .name("lumora-video-dec".into())
        .spawn(move || {
            let Ok(mut dec) = lumora_media::VideoDecoder::new() else { return };
            dec.set_source(source_id(&from));
            let mut first = true;
            let mut caps = lumora_media::codec::local_caps_for(source_id(&from));
            let mut last: Option<(VideoFormat, std::time::Instant)> = None;
            let mut sync: lumora_media::FrameSync<Inbound> = lumora_media::FrameSync::new();
            while !input.closed.load(Ordering::SeqCst) {
                // wake up for held frames, and every second while waiting for a keyframe
                let mut until = std::time::Instant::now() + Duration::from_secs(1);
                if let Some(d) = sync.deadline() {
                    until = until.min(d);
                }
                let item = input.pop(until);
                let Some(node) = weak.upgrade() else { return };
                if input.lost.swap(false, Ordering::SeqCst) {
                    sync.lost();
                }
                let now = std::time::Instant::now();
                let ready = match item {
                    Some(f) => {
                        let (seq, key) = (f.seq, f.key);
                        sync.push(seq, key, f, now)
                    }
                    None => {
                        sync.poll(now);
                        vec![]
                    }
                };
                for f in ready {
                    match dec.decode_as(f.format, &f.data) {
                        Ok(Some(fr)) => {
                            if first {
                                first = false;
                                let backend = dec.backend().map(|(_, k)| k.label()).unwrap_or_default();
                                node.emit("video_first_frame", json!({
                                    "session": hex::encode(session), "peer": from.to_base32(), "camera": camera, "stream": local_stream,
                                    "codec": f.format.name(), "backend": backend, "hw": dec.is_hardware(),
                                    "ms": created.elapsed().as_millis() as u64,
                                }));
                            }
                            if let Some((prev, at)) = last.filter(|(p, _)| *p != f.format) {
                                // the sender switched formats (e.g. hardware H.264 failed → VP8)
                                node.emit("video_codec_switch", json!({
                                    "session": hex::encode(session), "peer": from.to_base32(), "camera": camera,
                                    "from": prev.name(), "to": f.format.name(), "gap_ms": at.elapsed().as_millis() as u64,
                                }));
                            }
                            last = Some((f.format, std::time::Instant::now()));
                            node.remote.put_frame(local_stream, fr.width, fr.height, rgba_tight(&fr));
                        }
                        Ok(None) => {}
                        Err(e) => {
                            tracing::debug!("video decode ({}): {e:#}", f.format.name());
                            sync.lost();
                            // our H.264 decoder may have been marked broken for this
                            // sender: tell it (it switches to VP8 on its next frame)
                            let now = lumora_media::codec::local_caps_for(source_id(&from));
                            if now != caps {
                                caps = now;
                                send_caps_to(&node, &from);
                            }
                        }
                    }
                }
                if sync.want_keyframe(std::time::Instant::now()) {
                    node.send_now_dev(&from, PeerMsg::KeyframeRequest { stream: kf_stream });
                }
            }
        })
        .ok();
    (local_stream, q)
}

fn rgba_tight(f: &Frame) -> Bytes {
    let row = f.width as usize * 4;
    let tight = f.stride as usize == row && f.format == PixelFormat::Rgba;
    if tight {
        return f.data.clone();
    }
    let mut out = Vec::with_capacity(row * f.height as usize);
    for y in 0..f.height as usize {
        let line = &f.data[y * f.stride as usize..y * f.stride as usize + row];
        if f.format == PixelFormat::Bgra {
            for px in line.chunks_exact(4) {
                out.extend_from_slice(&[px[2], px[1], px[0], 255]);
            }
        } else {
            out.extend_from_slice(line);
        }
    }
    Bytes::from(out)
}

pub async fn on_media_stream(node: &Arc<Node>, pc: &Arc<PeerConn>, mut recv: quinn::RecvStream) {
    let mut hdr = [0u8; HDR_LEN];
    if recv.read_exact(&mut hdr).await.is_err() {
        return;
    }
    let h = parse_header(&hdr);
    let Some(format) = h.format else {
        let _ = recv.stop(1u32.into()); // a format from the future: skip
        return;
    };
    let (session, camera) = (h.session, h.camera);
    // Which local stream renders this? remote session (viewer) or a call participant.
    let kind = {
        let sess = node.remote.sessions.lock().get(&session).cloned();
        match sess {
            Some(s) if s.role == Role::Viewer && s.peer == pc.peer => Some(StreamKind::Viewer(s.stream)),
            _ => {
                let in_call = node.remote.calls.lock().get(&session).map(|c| c.peers.lock().contains(&pc.peer)).unwrap_or(false);
                in_call.then_some(StreamKind::Call)
            }
        }
    };
    let Some(kind) = kind else {
        let _ = recv.stop(1u32.into()); // unauthorised: don't read the body
        return;
    };
    // (before the body arrives: concurrent first frames share one decoder/stream id)
    let (_, q) = decoder_for(node, session, pc.peer, camera, kind);
    let Ok(data) = recv.read_to_end(MAX_FRAME_BYTES).await else {
        // reset by the sender (stale) or lost: the sequence gap resyncs the decoder
        return;
    };
    q.push(Inbound { format, seq: h.seq, key: h.key, data });
}

/// Parse one input event from the viewer.
fn input_event(ev: &Value) -> Option<InputEvent> {
    Some(match ev["t"].as_str().unwrap_or("") {
        "move" => InputEvent::Move { x: ev["x"].as_f64().unwrap_or(0.0).clamp(0.0, 1.0), y: ev["y"].as_f64().unwrap_or(0.0).clamp(0.0, 1.0) },
        "button" => {
            let button = match ev["b"].as_str().unwrap_or("left") {
                "right" => MouseButton::Right,
                "middle" => MouseButton::Middle,
                "back" => MouseButton::Back,
                "forward" => MouseButton::Forward,
                _ => MouseButton::Left,
            };
            InputEvent::Button { button, down: ev["down"].as_bool().unwrap_or(false) }
        }
        "wheel" => InputEvent::Wheel { dx: ev["dx"].as_i64().unwrap_or(0).clamp(-1000, 1000) as i32, dy: ev["dy"].as_i64().unwrap_or(0).clamp(-1000, 1000) as i32 },
        "key" => InputEvent::Key { code: ev["code"].as_str().unwrap_or("").chars().take(64).collect(), down: ev["down"].as_bool().unwrap_or(false) },
        "text" => InputEvent::Text(ev["s"].as_str().unwrap_or("").chars().take(4096).collect()),
        _ => return None,
    })
}

/// Inject one input event for `session` if `from` is the authorised viewer. Never
/// blocks: events go to the session's injector thread (`InjectorWorker`), which
/// opens the injector once (a permission dialog may wait for the user) and, if that
/// fails, tells the host user and backs off instead of asking again per event.
pub fn handle_input(node: &Arc<Node>, from: &PeerId, session: [u8; 16], ev: &Value) {
    let Some(s) = node.remote.sessions.lock().get(&session).cloned() else { return };
    if s.role != Role::Host || s.peer != *from || !s.accepted.load(Ordering::Relaxed) || !s.control.load(Ordering::Relaxed) {
        return;
    }
    let Some(ev) = input_event(ev) else { return };
    let mut guard = s.injector.lock();
    if guard.is_none() {
        let disp: DisplayInfo = node.remote.host_display.lock().clone().unwrap_or_default();
        let weak = Arc::downgrade(node);
        let worker = lumora_media::InjectorWorker::for_display(disp, move |st| {
            let Some(node) = weak.upgrade() else { return };
            match st {
                lumora_media::InjectorStatus::Ready { backend } => {
                    tracing::info!("input injection ready ({backend})");
                }
                lumora_media::InjectorStatus::Unavailable { error, retry_in } => {
                    tracing::warn!("input injection unavailable: {error}");
                    node.emit("error", json!({
                        "message": crate::i18n::tr("err.input_unavailable"), "code": "input_unavailable", "detail": error,
                        "session": hex::encode(session), "retry_s": retry_in.as_secs(),
                    }));
                }
            }
        });
        match worker {
            Ok(w) => *guard = Some(w),
            Err(e) => {
                tracing::warn!("input thread: {e:#}");
                return;
            }
        }
    }
    if let Some(w) = guard.as_ref() {
        let _ = w.send(ev); // full queue: dropped (the injector is behind)
    }
}

pub fn on_datagram(node: &Arc<Node>, pc: &Arc<PeerConn>, d: Bytes) {
    if d.is_empty() {
        return;
    }
    match d[0] {
        proto::dgram::INPUT if d.len() > 17 => {
            let session: [u8; 16] = d[1..17].try_into().unwrap();
            if let Ok(ev) = proto::from_slice_capped::<Value>(&d[17..]) {
                handle_input(node, &pc.peer, session, &ev);
            }
        }
        proto::dgram::AUDIO if d.len() > 19 => {
            let call: [u8; 16] = d[1..17].try_into().unwrap();
            let in_call = node.remote.calls.lock().get(&call).map(|c| c.peers.lock().contains(&pc.peer) && *c.state.lock() == "active").unwrap_or(false);
            if !in_call {
                return;
            }
            let seq = u16::from_be_bytes([d[17], d[18]]);
            if let Some(p) = player_for(node, call, pc.peer) {
                p.push_packet(seq, d.slice(19..));
            }
        }
        _ => {}
    }
}

/// The speaker of `peer`, opened on a thread of its own on first use (opening an
/// audio device can block for seconds): the datagram loop never waits for it and
/// never holds the `players` lock across it; packets until then are dropped.
fn player_for(node: &Arc<Node>, call: [u8; 16], peer: PeerId) -> Option<Arc<lumora_media::audio::AudioPlayer>> {
    let media = &node.remote.media;
    {
        let mut ps = media.players.lock();
        match ps.get(&peer) {
            Some(PlayerSlot::Ready(p)) => return Some(p.clone()),
            Some(PlayerSlot::Opening) => return None,
            None => {}
        }
        if media.player_failed.lock().is_some_and(|t| t.elapsed() < Duration::from_secs(5)) {
            return None;
        }
        ps.insert(peer, PlayerSlot::Opening);
    }
    let weak = Arc::downgrade(node);
    let spawned = std::thread::Builder::new().name("lumora-audio-open".into()).spawn(move || {
        let r = lumora_media::audio::AudioPlayer::start(None);
        let Some(node) = weak.upgrade() else { return };
        let media = &node.remote.media;
        // still wanted? (the call may have ended or the peer left while opening)
        let wanted = node.remote.calls.lock().get(&call).is_some_and(|c| c.peers.lock().contains(&peer));
        let unused = {
            let mut ps = media.players.lock();
            let opening = matches!(ps.get(&peer), Some(PlayerSlot::Opening));
            match r {
                Ok(p) if opening && wanted => {
                    ps.insert(peer, PlayerSlot::Ready(Arc::new(p)));
                    None
                }
                Ok(p) => {
                    if opening {
                        ps.remove(&peer);
                    }
                    Some(p)
                }
                Err(e) => {
                    if opening {
                        ps.remove(&peer);
                    }
                    tracing::warn!("speaker unavailable: {e:#}");
                    *media.player_failed.lock() = Some(std::time::Instant::now());
                    None
                }
            }
        };
        drop(unused); // closing joins the audio thread: outside the lock
    });
    if spawned.is_err() {
        media.players.lock().remove(&peer);
    }
    None
}

// ------------------------------------------------------------------ calls

pub fn start_call_media(node: &Arc<Node>, c: &Arc<Call>) {
    if c.media_started.swap(true, Ordering::SeqCst) {
        return;
    }
    // unit tests never open this machine's microphone / camera
    if cfg!(test) {
        return;
    }
    if c.video && c.cam.load(Ordering::Relaxed) {
        toggle_call_camera(node, c, true);
    }
    let node = node.clone();
    let c = c.clone();
    std::thread::Builder::new()
        .name("lumora-audio-tx".into())
        .spawn(move || {
            let cap = match lumora_media::audio::AudioCapture::start(None) {
                Ok(c) => c,
                Err(e) => {
                    node.emit("error", json!({"message": crate::i18n::tr("err.mic_unavailable"), "code": "mic_unavailable", "detail": format!("{e:#}")}));
                    return;
                }
            };
            // echo cancellation (off e.g. with headphones) and noise suppression: on unless the
            // user turned them off; re-read every ~0.5 s so the switches work mid-call
            let apply_settings = |cap: &lumora_media::audio::AudioCapture| {
                let on = |k: &str| node.store.kv_get(k).map(|v| v != b"0").unwrap_or(true);
                cap.aec_enabled.store(on("audio.aec"), Ordering::Relaxed);
                cap.ns_enabled.store(on("audio.ns"), Ordering::Relaxed);
            };
            apply_settings(&cap);
            let Ok(mut enc) = lumora_media::audio::OpusEncoder::new(32_000) else { return };
            let _ = enc.set_expected_loss(10);
            let seq = AtomicU16::new(0);
            let mut ticks = 0u32;
            // who is talking: decided on the clean microphone signal, told to the others
            let mut vad = super::voice::Vad::default();
            let mut talking = false;
            while !c.stop.load(Ordering::Relaxed) {
                ticks = ticks.wrapping_add(1);
                if ticks.is_multiple_of(25) {
                    apply_settings(&cap);
                }
                let Ok(Some(frame)) = cap.next_frame(Duration::from_millis(100)) else { continue };
                let mic = c.mic.load(Ordering::Relaxed);
                if vad.step(mic.then_some(&frame[..])) != talking {
                    talking = !talking;
                    node.set_speaking(&c, node.device, talking);
                }
                if !mic {
                    continue;
                }
                let Ok(pkt) = enc.encode(&frame) else { continue };
                let s = seq.fetch_add(1, Ordering::Relaxed);
                let mut d = Vec::with_capacity(19 + pkt.len());
                d.push(proto::dgram::AUDIO);
                d.extend_from_slice(&c.id);
                d.extend_from_slice(&s.to_be_bytes());
                d.extend_from_slice(&pkt);
                let d = Bytes::from(d);
                for p in c.peers.lock().iter() {
                    if let Some(pc) = node.peer(p) {
                        let _ = pc.conn.send_datagram(d.clone());
                    }
                }
            }
            // call over: release speakers of its participants (closing joins their
            // threads: outside the lock)
            let gone: Vec<PlayerSlot> = {
                let mut ps = node.remote.media.players.lock();
                c.peers.lock().iter().filter_map(|p| ps.remove(p)).collect()
            };
            drop(gone);
        })
        .ok();
}

// ------------------------------------------------------------------ camera

/// Bumped by `settings_set` when a `video.*` key changes, so running camera
/// senders pick the new effect settings up on their next frame.
static CAMERA_FX_GEN: AtomicU32 = AtomicU32::new(0);

pub fn camera_fx_changed() {
    CAMERA_FX_GEN.fetch_add(1, Ordering::Relaxed);
}

/// Sender-side camera effects (beauty / low-light / mirror, see
/// `lumora_media::video_fx`) applied on the encoder thread right before H.264,
/// plus the local self-view: the *processed* picture, mirrored like a mirror
/// (unless the sent picture is mirrored already), published as this call's
/// stream for our own peer id.
struct CameraFx {
    node: std::sync::Weak<Node>,
    call: [u8; 16],
    fx: lumora_media::video_fx::VideoFx,
    settings: lumora_media::video_fx::FxSettings,
    seen_gen: u32,
    frames: u32,
    stream: u32,
    preview: Vec<u8>,
}

impl CameraFx {
    fn new(node: &Arc<Node>, call: [u8; 16], fps: u32) -> Self {
        let mut fx = lumora_media::video_fx::VideoFx::new();
        fx.set_frame_rate(fps);
        let stream = node.remote.alloc_stream();
        node.emit("video_stream", json!({"call_id": hex::encode(call), "peer": node.me.to_base32(), "stream": stream, "kind": "camera", "local": true}));
        let mut me = Self { node: Arc::downgrade(node), call, fx, settings: Default::default(), seen_gen: u32::MAX, frames: 0, stream, preview: Vec::new() };
        me.refresh();
        me
    }

    /// Re-read the settings when they changed (or every ~second, e.g. after a restore).
    fn refresh(&mut self) {
        let gen = CAMERA_FX_GEN.load(Ordering::Relaxed);
        self.frames = self.frames.wrapping_add(1);
        if gen == self.seen_gen && !self.frames.is_multiple_of(30) {
            return;
        }
        self.seen_gen = gen;
        if let Some(node) = self.node.upgrade() {
            self.settings = lumora_media::video_fx::FxSettings::from_kv(|k| node.store.kv_get(k));
        }
    }

    fn apply(&mut self, yuv: &mut lumora_media::color::I420Buf) {
        self.fx.process(yuv, &self.settings);
        let Some(node) = self.node.upgrade() else { return };
        let (w, h) = lumora_media::video_fx::preview_rgba(yuv, !self.settings.mirror, 640, &mut self.preview);
        if w > 0 {
            node.remote.put_frame(self.stream, w as u32, h as u32, Bytes::copy_from_slice(&self.preview));
        }
    }
}

impl Drop for CameraFx {
    fn drop(&mut self) {
        if let Some(node) = self.node.upgrade() {
            node.remote.frames.lock().remove(&self.stream);
            node.emit("video_stream", json!({"call_id": hex::encode(self.call), "peer": node.me.to_base32(), "stream": -1, "ended_stream": self.stream, "kind": "camera", "local": true}));
        }
    }
}

/// Frames pushed by the app (Flutter camera plugin on Android/Windows/macOS) via FFI.
static EXT_CAMERA: std::sync::Mutex<Option<std::sync::mpsc::SyncSender<Frame>>> = std::sync::Mutex::new(None);

/// Called by the FFI layer with frames from the platform camera.
/// Returns 0 = queued, 1 = dropped because the encoder is busy, 2 = no call wants
/// the camera (the FFI uses 1 vs 2 to adapt the resolution).
pub fn push_camera_frame(f: Frame) -> i32 {
    let Ok(g) = EXT_CAMERA.lock() else { return 2 };
    match g.as_ref().map(|tx| tx.try_send(f)) {
        Some(Ok(())) => 0,
        Some(Err(std::sync::mpsc::TrySendError::Full(_))) => 1,
        _ => 2,
    }
}

struct ExtCamera {
    rx: std::sync::mpsc::Receiver<Frame>,
}

impl lumora_media::Capturer for ExtCamera {
    fn displays(&self) -> Vec<DisplayInfo> {
        vec![]
    }
    fn next_frame(&mut self, timeout: Duration) -> anyhow::Result<Option<Frame>> {
        match self.rx.recv_timeout(timeout) {
            Ok(f) => Ok(Some(f)),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => Ok(None),
            Err(_) => anyhow::bail!("camera closed"),
        }
    }
}

#[cfg(target_os = "linux")]
struct V4lCamera(lumora_media::camera::Camera);

#[cfg(target_os = "linux")]
impl lumora_media::Capturer for V4lCamera {
    fn displays(&self) -> Vec<DisplayInfo> {
        vec![]
    }
    fn next_frame(&mut self, timeout: Duration) -> anyhow::Result<Option<Frame>> {
        self.0.next_frame(timeout)
    }
}

/// Synthetic 640x480 camera (moving gradient, 30 fps) for headless tests:
/// `LUMORA_TEST_CAMERA=1`.
struct TestCamera {
    t: u32,
    next: std::time::Instant,
}

impl lumora_media::Capturer for TestCamera {
    fn displays(&self) -> Vec<DisplayInfo> {
        vec![]
    }
    fn next_frame(&mut self, _timeout: Duration) -> anyhow::Result<Option<Frame>> {
        let now = std::time::Instant::now();
        if now < self.next {
            std::thread::sleep(self.next - now);
        }
        self.next += Duration::from_millis(33);
        let (w, h) = (640u32, 480u32);
        let mut d = vec![0u8; (w * h * 4) as usize];
        for (i, px) in d.chunks_exact_mut(4).enumerate() {
            let (x, y) = (i as u32 % w, i as u32 / w);
            px.copy_from_slice(&[((x + self.t * 4) % 256) as u8, (y % 256) as u8, (((x / 40) ^ (y / 40)) * 37 % 256) as u8, 255]);
        }
        self.t += 1;
        Ok(Some(Frame { width: w, height: h, stride: w * 4, format: PixelFormat::Rgba, data: d.into(), ts_us: lumora_media::now_us() }))
    }
}

fn open_camera_source(node: &Arc<Node>) -> Result<Box<dyn lumora_media::Capturer>> {
    if std::env::var("LUMORA_TEST_CAMERA").is_ok_and(|v| v == "1") {
        return Ok(Box::new(TestCamera { t: 0, next: std::time::Instant::now() }));
    }
    // Prefer frames from the app if it provides them (mobile / Windows / macOS)…
    let external = node.store.kv_get("media.external_camera").map(|v| v == b"1").unwrap_or(!cfg!(target_os = "linux"));
    if !external {
        #[cfg(target_os = "linux")]
        {
            if let Ok(cam) = lumora_media::camera::open_camera(0, 1280, 720, 30) {
                return Ok(Box::new(V4lCamera(cam)));
            }
        }
    }
    let (tx, rx) = std::sync::mpsc::sync_channel(2);
    *EXT_CAMERA.lock().map_err(|_| anyhow!("camera lock"))? = Some(tx);
    node.emit("camera_needed", json!({"width": 1280, "height": 720, "fps": 30}));
    Ok(Box::new(ExtCamera { rx }))
}

pub fn toggle_call_camera(node: &Arc<Node>, c: &Arc<Call>, on: bool) {
    let cam_key: SlotKey = (c.id, true);
    let mut stops = node.remote.media.screen_stop.lock();
    if let Some(s) = stops.remove(&cam_key) {
        s.store(true, Ordering::SeqCst);
        if let Ok(mut g) = EXT_CAMERA.lock() {
            *g = None;
        }
        node.emit("camera_released", json!({}));
    }
    if !on {
        return;
    }
    let stop = Arc::new(AtomicBool::new(false));
    stops.insert(cam_key, stop.clone());
    drop(stops);
    match open_camera_source(node) {
        Ok(cap) => {
            let c2 = c.clone();
            let combined = Arc::new(AtomicBool::new(false));
            let comb = combined.clone();
            let (s1, s2) = (c.stop.clone(), stop.clone());
            tokio::spawn(async move {
                while !s1.load(Ordering::Relaxed) && !s2.load(Ordering::Relaxed) {
                    tokio::time::sleep(Duration::from_millis(200)).await;
                }
                comb.store(true, Ordering::SeqCst);
            });
            start_video_sender(node, c.id, 0, Arc::new(move || c2.peers.lock().clone()), combined, Arc::new(AtomicBool::new(true)), Arc::new(AtomicU32::new(1500)), cap, 30, true);
        }
        Err(e) => {
            c.cam.store(false, Ordering::SeqCst);
            node.emit("error", json!({"message": crate::i18n::tr("err.camera_unavailable"), "code": "camera_unavailable", "detail": format!("{e:#}")}));
            node.emit_call(c);
        }
    }
}

pub fn toggle_call_screen(node: &Arc<Node>, c: &Arc<Call>, on: bool) {
    let key: SlotKey = (c.id, false);
    let mut stops = node.remote.media.screen_stop.lock();
    if let Some(s) = stops.remove(&key) {
        s.store(true, Ordering::SeqCst);
    }
    if !on {
        return;
    }
    let stop = Arc::new(AtomicBool::new(false));
    stops.insert(key, stop.clone());
    drop(stops);
    let node = node.clone();
    let c = c.clone();
    tokio::spawn(async move {
        match open_capture(&node, 0, 30, lumora_media::CaptureSource::Any).await {
            Ok(cap) => {
                let c2 = c.clone();
                let combined = Arc::new(AtomicBool::new(false));
                // stop when either the call or the screen share stops
                let comb = combined.clone();
                let (s1, s2) = (c.stop.clone(), stop.clone());
                tokio::spawn(async move {
                    while !s1.load(Ordering::Relaxed) && !s2.load(Ordering::Relaxed) {
                        tokio::time::sleep(Duration::from_millis(200)).await;
                    }
                    comb.store(true, Ordering::SeqCst);
                });
                start_video_sender(
                    &node,
                    c.id,
                    0,
                    Arc::new(move || c2.peers.lock().clone()),
                    combined,
                    Arc::new(AtomicBool::new(true)),
                    Arc::new(AtomicU32::new(3000)),
                    cap,
                    30,
                    false,
                );
            }
            Err(e) => {
                c.screen.store(false, Ordering::SeqCst);
                node.emit("error", json!({"message": crate::i18n::tr("err.capture_unavailable"), "code": "capture_unavailable", "detail": format!("{e:#}")}));
                node.emit_call(&c);
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn header_carries_sequence_and_stays_compatible() {
        let sid = [7u8; 16];
        let h = header(&sid, true, true, VideoFormat::Vp9, 1280, 720, 0xDEAD_BEEF, 12345);
        assert_eq!(h.len(), 1 + HDR_LEN);
        assert_eq!(h[0], proto::STREAM_MEDIA);
        let p = parse_header(h[1..].try_into().unwrap());
        assert_eq!(p, MediaHeader { session: sid, key: true, camera: true, format: Some(VideoFormat::Vp9), seq: Some(0xDEAD_BEEF), ts_ms: Some(12345) });
        // an older sender (no bit 4): no sequence number; an older receiver reads the
        // same session/flags/format bits as before
        let mut old = h[1..].to_vec();
        old[16] &= !FLAG_SEQ;
        let p = parse_header(old[..].try_into().unwrap());
        assert_eq!((p.seq, p.key, p.camera, p.format), (None, true, true, Some(VideoFormat::Vp9)));
        assert_eq!(h[17] & 1, 1);
        assert_eq!((h[17] >> 2) & 3, 2);
        // keyframe-request tags: distinct per stream kind, never 0 ("all streams")
        assert_ne!(keyframe_tag(&sid, true), keyframe_tag(&sid, false));
        assert_ne!(keyframe_tag(&[0; 16], false), 0);
    }

    fn flight(key: bool, done: bool) -> Flight {
        let (tx, _) = tokio::sync::oneshot::channel();
        Flight { key, started: Instant::now(), done: Arc::new(AtomicBool::new(done)), cancel: Some(tx) }
    }

    #[test]
    fn send_window_drops_resets_and_resyncs() {
        let mut w = SendWindow::default();
        assert_eq!(w.offer(true), Offer::Send);
        w.flights.push(flight(true, false));
        assert_eq!(w.offer(false), Offer::Send);
        w.flights.push(flight(false, false));
        // full: a delta is dropped, later deltas skipped until a keyframe
        assert_eq!(w.offer(false), Offer::Drop);
        assert_eq!(w.offer(false), Offer::Skip);
        // a keyframe resets the stale delta (the older keyframe stays) and goes out
        let (tx, mut rx) = tokio::sync::oneshot::channel();
        w.flights[1].cancel = Some(tx);
        assert_eq!(w.offer(true), Offer::Send);
        assert!(rx.try_recv().is_ok(), "stale delta stream reset");
        assert_eq!(w.flights.len(), 1);
        w.flights.push(flight(true, false));
        // two keyframes in flight: even a keyframe waits (dropped), deltas skipped
        assert_eq!(w.offer(true), Offer::Drop);
        assert_eq!(w.offer(false), Offer::Skip);
        // acknowledged streams free the window
        assert!(!w.has_room(Instant::now()));
        for f in &w.flights {
            f.done.store(true, Ordering::SeqCst);
        }
        assert!(w.has_room(Instant::now()));
        assert_eq!(w.offer(false), Offer::Skip, "still waiting for a keyframe");
        assert_eq!(w.offer(true), Offer::Send);
        assert_eq!(w.offer(false), Offer::Send);
        // a delta never acknowledged in time is reset and the peer resyncs
        let mut w = SendWindow::default();
        let (tx, mut rx) = tokio::sync::oneshot::channel();
        w.flights.push(Flight { key: false, started: Instant::now() - STALE_DELTA, done: Arc::new(AtomicBool::new(false)), cancel: Some(tx) });
        assert!(w.has_room(Instant::now()), "stale flights don't block the encoder");
        assert_eq!(w.offer(false), Offer::Skip);
        assert!(rx.try_recv().is_ok());
        // the window covers the base RTT at the frame rate (2..=8)
        let mut w = SendWindow::default();
        w.set_rtt(Duration::from_millis(5), 60);
        assert_eq!(w.limit, 3);
        w.set_rtt(Duration::from_millis(100), 60);
        assert_eq!(w.limit, 3, "the lowest RTT counts (a queue inflates the RTT)");
        let mut w = SendWindow::default();
        w.set_rtt(Duration::from_millis(80), 60);
        assert_eq!(w.limit, 7);
        w.set_rtt(Duration::from_millis(300), 60);
        assert_eq!(w.limit, 7);
        let mut w = SendWindow::default();
        w.set_rtt(Duration::from_millis(400), 60);
        assert_eq!(w.limit, MAX_IN_FLIGHT);
    }

    #[test]
    fn decoder_queue_never_drops_keyframes() {
        let q = DecQueue::default();
        let f = |seq: u32, key: bool| Inbound { format: VideoFormat::Vp8, seq: Some(seq), key, data: vec![seq as u8] };
        for s in 0..DEC_QUEUE as u32 {
            q.push(f(s, s == 0));
        }
        q.push(f(10, false));
        assert!(q.lost.swap(false, Ordering::SeqCst), "a delta is dropped when full");
        q.push(f(11, true));
        assert!(!q.lost.load(Ordering::SeqCst));
        let soon = Instant::now() + Duration::from_millis(5);
        let got: Vec<(u32, bool)> = std::iter::from_fn(|| q.pop(soon)).map(|x| (x.seq.unwrap(), x.key)).collect();
        assert_eq!(got, vec![(11, true)], "older frames make way for the keyframe");
        q.close();
        assert!(q.pop(Instant::now() + Duration::from_secs(5)).is_none());
    }

    /// UDP relay throttling one direction (a slow uplink with a router queue).
    async fn throttled_relay(server: std::net::SocketAddr, bytes_per_s: f64, queue_bytes: usize) -> std::net::SocketAddr {
        let sock = Arc::new(tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap());
        let addr = sock.local_addr().unwrap();
        let client: Arc<Mutex<Option<std::net::SocketAddr>>> = Arc::new(Mutex::new(None));
        let (qtx, mut qrx) = mpsc::unbounded_channel::<Vec<u8>>();
        let queued = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        // drain the bottleneck at `bytes_per_s`
        {
            let (sock, queued) = (sock.clone(), queued.clone());
            tokio::spawn(async move {
                let mut next = tokio::time::Instant::now();
                while let Some(p) = qrx.recv().await {
                    next = next.max(tokio::time::Instant::now()) + Duration::from_secs_f64(p.len() as f64 / bytes_per_s);
                    tokio::time::sleep_until(next).await;
                    queued.fetch_sub(p.len(), Ordering::SeqCst);
                    let _ = sock.send_to(&p, server).await;
                }
            });
        }
        tokio::spawn(async move {
            let mut buf = vec![0u8; 65536];
            while let Ok((n, from)) = sock.recv_from(&mut buf).await {
                if from == server {
                    let c = *client.lock();
                    if let Some(c) = c {
                        let _ = sock.send_to(&buf[..n], c).await;
                    }
                } else {
                    *client.lock() = Some(from);
                    if queued.load(Ordering::SeqCst) + n <= queue_bytes {
                        queued.fetch_add(n, Ordering::SeqCst);
                        let _ = qtx.send(buf[..n].to_vec());
                    } // else: tail drop
                }
            }
        });
        addr
    }

    /// Frames of a too-fast "encoder" (≈3.4 Mbit/s of 12 KB deltas, 40 KB keyframes
    /// on request) over a 2 Mbit/s link: returns (seq, latency ms, key) per frame
    /// received in `secs`. `windowed` = the real fan-out; otherwise every frame gets
    /// its own stream right away (the behaviour before the review fix).
    async fn run_link(windowed: bool, secs: u64) -> Vec<(u32, u32, bool)> {
        let (a, b) = (crate::identity::Identity::generate(), crate::identity::Identity::generate());
        let server = quinn::Endpoint::server(crate::tls::server_config(&b, None).unwrap(), "127.0.0.1:0".parse().unwrap()).unwrap();
        let relay = throttled_relay(server.local_addr().unwrap(), 250_000.0, 64 * 1024).await;
        let mut client = quinn::Endpoint::client("127.0.0.1:0".parse().unwrap()).unwrap();
        client.set_default_client_config(crate::tls::client_config(&a, None, Some(b.peer_id())).unwrap());
        let got: Arc<Mutex<Vec<(u32, u32, bool)>>> = Arc::default();
        {
            let got = got.clone();
            tokio::spawn(async move {
                let Some(inc) = server.accept().await else { return };
                let Ok(conn) = inc.await else { return };
                while let Ok(mut r) = conn.accept_uni().await {
                    let got = got.clone();
                    tokio::spawn(async move {
                        let mut h = [0u8; 1 + HDR_LEN];
                        if r.read_exact(&mut h).await.is_err() || r.read_to_end(1 << 20).await.is_err() {
                            return;
                        }
                        let p = parse_header(h[1..].try_into().unwrap());
                        got.lock().push((p.seq.unwrap(), now_ms32().wrapping_sub(p.ts_ms.unwrap()), p.key));
                    });
                }
            });
        }
        let conn = client.connect(relay, "lumora.peer").unwrap().await.unwrap();
        let peer = b.peer_id();
        let (tx, rx) = mpsc::channel::<lumora_media::EncodedFrame>(3);
        let stop = Arc::new(AtomicBool::new(false));
        let kf = Arc::new(AtomicBool::new(true));
        let drops = Arc::new(AtomicU32::new(0));
        let c2 = conn.clone();
        let gate = Arc::new(SendGate::default());
        let fan = if windowed {
            tokio::spawn(fan_out(rx, move || vec![(peer, c2.clone())], gate.clone(), stop.clone(), [1; 16], true, 30, kf.clone(), drops.clone()))
        } else {
            let mut rx = rx;
            tokio::spawn(async move {
                let mut seq = 0u32;
                while let Some(ef) = rx.recv().await {
                    let hdr = header(&[1; 16], ef.keyframe, true, ef.codec, ef.w, ef.h, seq, now_ms32());
                    seq += 1;
                    let (c, data) = (c2.clone(), ef.data.clone());
                    tokio::spawn(async move {
                        let Ok(mut s) = c.open_uni().await else { return };
                        if s.write_all(&hdr).await.is_ok() && s.write_all(&data).await.is_ok() {
                            let _ = s.finish();
                        }
                    });
                }
            })
        };
        // the encoder: 30 fps, keyframe when asked (at most every KEYFRAME_EVERY)
        let t0 = Instant::now();
        let mut last_key: Option<Instant> = None;
        let mut tick = tokio::time::interval(Duration::from_millis(33));
        while t0.elapsed() < Duration::from_secs(secs) {
            tick.tick().await;
            if windowed && !gate.has_room() {
                continue; // like the real encoder thread: skip while a window is full
            }
            let key = last_key.is_none_or(|t| t.elapsed() >= KEYFRAME_EVERY) && kf.swap(false, Ordering::SeqCst);
            if key {
                last_key = Some(Instant::now());
            }
            let ef = lumora_media::EncodedFrame { data: Bytes::from(vec![0x5a; if key { 40_000 } else { 12_000 }]), keyframe: key, w: 640, h: 480, codec: VideoFormat::Vp8 };
            let _ = tx.try_send(ef);
        }
        drop(tx);
        let _ = fan.await;
        let out = got.lock().clone();
        conn.close(0u32.into(), b"");
        out
    }

    /// Review finding #1: without backpressure frames piled up in QUIC's send buffer
    /// and latency grew by seconds; with the send window it stays bounded on a link
    /// slower than the encoder, and the receiver still gets a steady stream.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn latency_stays_bounded_on_a_throttled_link() {
        let got = run_link(true, 8).await;
        // the second half of what arrived (the link has been saturated for seconds)
        let late: Vec<u32> = got[got.len() / 2..].iter().map(|(_, l, _)| *l).collect();
        let mut sorted = late.clone();
        sorted.sort_unstable();
        let p95 = sorted.get(sorted.len() * 95 / 100).copied().unwrap_or(u32::MAX);
        let max = sorted.last().copied().unwrap_or(u32::MAX);
        eprintln!("windowed: {} frames received ({} deltas), second half p95 {p95} ms, max {max} ms", got.len(), got.iter().filter(|g| !g.2).count());
        assert!(got.len() >= 80, "frames keep flowing (≥10 fps on a link that fits ~20): {}", got.len());
        assert!(p95 < 900 && max < 1500, "latency bounded: p95 {p95} ms, max {max} ms");
        assert!(got.iter().any(|(_, _, k)| *k), "keyframes resync the receiver");

        // control: the old behaviour on the same link builds seconds of latency
        let old = run_link(false, 5).await;
        let worst = old.iter().map(|(_, l, _)| *l).max().unwrap_or(0);
        eprintln!("unwindowed: {} frames received, worst latency {worst} ms", old.len());
        assert!(worst > 1500, "the test link must expose the old queueing ({worst} ms)");
    }
}
