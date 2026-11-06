//! Voice pipeline: capture → noise gate → Opus → network → jitter buffer →
//! Opus (with FEC/PLC) → playback.
//!
//! Format on the wire and between components: **48 kHz, mono, 20 ms frames
//! (960 samples of i16)**.
//!
//! Echo cancellation: no WebRTC AEC is linked (the Debian/Ubuntu
//! `libwebrtc-audio-processing` package is the old 0.3 API and the Rust crate
//! needs a source build with meson). On Linux the recommended setup is
//! PipeWire's `echo-cancel` module (`libpipewire-module-echo-cancel`), which
//! Lumora transparently benefits from when it is the default source/sink;
//! macOS/Windows/Android provide voice-processing input natively. Here we only
//! apply a noise gate ([`NoiseGate`]) to suppress background hiss and
//! residual echo tails between words.
//!
//! Background noise ("Lọc tiếng ồn"): RNNoise via the pure-Rust `nnnoiseless`
//! ([`NoiseSuppressor`]) runs on the mic after echo cancellation (`audio` feature).

use std::collections::BTreeMap;

use bytes::Bytes;
use serde::{Deserialize, Serialize};

pub const SAMPLE_RATE: u32 = 48_000;
pub const FRAME_MS: u32 = 20;
pub const FRAME_SAMPLES: usize = (SAMPLE_RATE / 1000 * FRAME_MS) as usize; // 960

/// One 20 ms mono frame.
pub type PcmFrame = Vec<i16>;

// ---------------------------------------------------------------------------
// Noise suppression (RNNoise)
// ---------------------------------------------------------------------------

/// "Lọc tiếng ồn": RNNoise (pure-Rust `nnnoiseless`) removes fans, keyboard clicks, traffic…
/// It works on 480-sample (10 ms @ 48 kHz) chunks, so one 20 ms frame = 2 chunks.
#[cfg(feature = "audio")]
pub struct NoiseSuppressor {
    st: Box<nnnoiseless::DenoiseState<'static>>,
    inp: [f32; nnnoiseless::DenoiseState::FRAME_SIZE],
    out: [f32; nnnoiseless::DenoiseState::FRAME_SIZE],
}

#[cfg(feature = "audio")]
impl Default for NoiseSuppressor {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(feature = "audio")]
impl NoiseSuppressor {
    pub const CHUNK: usize = nnnoiseless::DenoiseState::FRAME_SIZE;

    pub fn new() -> Self {
        Self { st: nnnoiseless::DenoiseState::new(), inp: [0.0; Self::CHUNK], out: [0.0; Self::CHUNK] }
    }

    /// Denoise `pcm` in place (length a multiple of 480; a trailing partial chunk is left as is).
    /// Returns the highest voice probability (0–1) seen in the frame.
    pub fn process(&mut self, pcm: &mut [i16]) -> f32 {
        let mut vad = 0f32;
        for chunk in pcm.chunks_exact_mut(Self::CHUNK) {
            // RNNoise expects samples in the i16 range, as f32
            for (d, s) in self.inp.iter_mut().zip(chunk.iter()) {
                *d = *s as f32;
            }
            vad = vad.max(self.st.process_frame(&mut self.out, &self.inp));
            for (d, s) in chunk.iter_mut().zip(self.out.iter()) {
                *d = s.round().clamp(-32768.0, 32767.0) as i16;
            }
        }
        vad
    }
}

// ---------------------------------------------------------------------------
// Noise gate
// ---------------------------------------------------------------------------

/// RMS noise gate with hysteresis, hold time and smooth gain ramps.
#[derive(Debug, Clone)]
pub struct NoiseGate {
    /// Gate opens above this level (dBFS).
    pub open_db: f32,
    /// Gate closes below this level (dBFS).
    pub close_db: f32,
    /// Frames to keep the gate open after the level drops.
    pub hold_frames: u32,
    /// Attenuation applied when closed (linear, 0 = mute).
    pub floor: f32,
    open: bool,
    hold: u32,
    gain: f32,
}

impl Default for NoiseGate {
    fn default() -> Self {
        Self { open_db: -45.0, close_db: -52.0, hold_frames: 10, floor: 0.05, open: false, hold: 0, gain: 0.05 }
    }
}

impl NoiseGate {
    pub fn is_open(&self) -> bool {
        self.open
    }

    /// Process a frame in place.
    pub fn process(&mut self, pcm: &mut [i16]) {
        if pcm.is_empty() {
            return;
        }
        let sum: f64 = pcm.iter().map(|&s| (s as f64) * (s as f64)).sum();
        let rms = (sum / pcm.len() as f64).sqrt() / 32768.0;
        let db = if rms > 0.0 { 20.0 * rms.log10() as f32 } else { -120.0 };
        if db >= self.open_db {
            self.open = true;
            self.hold = self.hold_frames;
        } else if db < self.close_db {
            if self.hold > 0 {
                self.hold -= 1;
            } else {
                self.open = false;
            }
        }
        let target = if self.open { 1.0 } else { self.floor };
        // Linear ramp across the frame to avoid clicks.
        let start = self.gain;
        let n = pcm.len() as f32;
        for (i, s) in pcm.iter_mut().enumerate() {
            let g = start + (target - start) * (i as f32 + 1.0) / n;
            *s = (*s as f32 * g).round().clamp(-32768.0, 32767.0) as i16;
        }
        self.gain = target;
    }
}

// ---------------------------------------------------------------------------
// Jitter buffer
// ---------------------------------------------------------------------------

/// What the playout clock gets every 20 ms.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JitterOut {
    /// The next packet, in order.
    Packet(Bytes),
    /// The expected packet is missing: run packet-loss concealment. If the
    /// following packet is already here it is supplied for Opus in-band FEC.
    Missing { next: Option<Bytes> },
    /// Still filling up (start or after a long gap): play silence.
    Buffering,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct JitterStats {
    pub received: u64,
    pub late: u64,
    pub lost: u64,
    /// Playout found the queue empty (nothing newer has arrived yet): PLC
    /// was played without skipping the expected packet.
    pub underruns: u64,
    pub dropped_overflow: u64,
    pub jitter_ms: f64,
    pub target_ms: u32,
    pub depth_frames: usize,
}

/// Adaptive jitter buffer for 20 ms audio packets with 16-bit sequence numbers.
///
/// The target delay follows an RFC 3550 inter-arrival jitter estimate:
/// `target = clamp(20 ms + 3·J, 20 ms, 120 ms)`. If the queue grows well past
/// the target (clock drift or a burst after a stall) old frames are dropped.
#[derive(Debug, Clone)]
pub struct JitterBuffer {
    packets: BTreeMap<u64, Bytes>,
    highest: Option<u64>,
    next: Option<u64>,
    started: bool,
    last_transit: Option<f64>,
    jitter_ms: f64,
    target_frames: usize,
    min_frames: usize,
    max_frames: usize,
    missing_run: u32,
    /// a packet far ahead of `highest`, followed only once a second one confirms it
    jump: Option<u64>,
    stats: JitterStats,
}

/// Packets further ahead than this (1 s) are a sequence jump: one stray packet
/// (corrupt, or sent by a misbehaving peer) must not make the buffer skip ahead
/// and then discard every real packet as "late" for minutes.
const MAX_SEQ_JUMP: u64 = 50;

impl Default for JitterBuffer {
    fn default() -> Self {
        Self::new(20, 120)
    }
}

impl JitterBuffer {
    pub fn new(min_ms: u32, max_ms: u32) -> Self {
        let min_frames = (min_ms / FRAME_MS).max(1) as usize;
        let max_frames = (max_ms / FRAME_MS).max(min_frames as u32) as usize;
        Self {
            packets: BTreeMap::new(),
            highest: None,
            next: None,
            started: false,
            last_transit: None,
            jitter_ms: 0.0,
            target_frames: min_frames,
            min_frames,
            max_frames,
            missing_run: 0,
            jump: None,
            stats: JitterStats::default(),
        }
    }

    fn unwrap_seq(&self, seq: u16) -> u64 {
        match self.highest {
            None => seq as u64 + (1 << 20), // headroom so early wraps never go negative
            Some(h) => {
                let diff = seq.wrapping_sub(h as u16) as i16 as i64;
                (h as i64 + diff).max(0) as u64
            }
        }
    }

    /// Insert a packet. `arrival_ms` is a local monotonic clock in ms.
    pub fn push(&mut self, seq: u16, payload: Bytes, arrival_ms: f64) {
        let mut ext = self.unwrap_seq(seq);
        self.stats.received += 1;
        if let Some(h) = self.highest {
            if ext > h + MAX_SEQ_JUMP {
                match self.jump {
                    // a second packet right after the first: the sender really jumped
                    // (restarted its stream): start over from here
                    Some(j) if ext > j && ext <= j + MAX_SEQ_JUMP => {
                        let stats = std::mem::take(&mut self.stats);
                        self.reset();
                        self.stats = stats;
                        ext = self.unwrap_seq(seq);
                    }
                    _ => {
                        self.jump = Some(ext);
                        self.stats.late += 1;
                        return;
                    }
                }
            } else {
                self.jump = None;
            }
        }
        if let Some(n) = self.next {
            if ext < n {
                self.stats.late += 1;
                return;
            }
        }
        // Inter-arrival jitter (RFC 3550 §A.8), using the 20 ms media clock.
        let transit = arrival_ms - ext as f64 * FRAME_MS as f64;
        if let Some(prev) = self.last_transit {
            let d = (transit - prev).abs();
            // Ignore absurd values (e.g. after a long pause).
            if d < 1000.0 {
                self.jitter_ms += (d - self.jitter_ms) / 16.0;
            }
        }
        self.last_transit = Some(transit);
        let target_ms = (FRAME_MS as f64 + 3.0 * self.jitter_ms).clamp(
            (self.min_frames as u32 * FRAME_MS) as f64,
            (self.max_frames as u32 * FRAME_MS) as f64,
        );
        self.target_frames = (target_ms / FRAME_MS as f64).ceil() as usize;

        self.highest = Some(self.highest.map_or(ext, |h| h.max(ext)));
        self.packets.insert(ext, payload);
        // Hard cap on memory.
        while self.packets.len() > self.max_frames * 4 {
            if let Some((&k, _)) = self.packets.iter().next() {
                self.packets.remove(&k);
                self.stats.dropped_overflow += 1;
            }
        }
    }

    /// Called by the playout clock every 20 ms.
    pub fn pop(&mut self) -> JitterOut {
        if !self.started {
            let Some((&first, _)) = self.packets.iter().next() else { return JitterOut::Buffering };
            let span = self.highest.map(|h| (h - first + 1) as usize).unwrap_or(0);
            if span < self.target_frames {
                return JitterOut::Buffering;
            }
            self.started = true;
            self.next = Some(first);
            self.missing_run = 0;
        }
        let mut next = self.next.unwrap_or(0);
        // Catch up if far behind the newest packet.
        if let Some(h) = self.highest {
            let depth = (h + 1).saturating_sub(next) as usize;
            if depth > self.target_frames + 3 {
                let new_next = h + 1 - self.target_frames as u64;
                let stale: Vec<u64> = self.packets.range(..new_next).map(|(&k, _)| k).collect();
                for k in stale {
                    self.packets.remove(&k);
                    self.stats.dropped_overflow += 1;
                }
                next = new_next;
            }
        }
        if let Some(p) = self.packets.remove(&next) {
            self.next = Some(next + 1);
            self.missing_run = 0;
            return JitterOut::Packet(p);
        }
        self.missing_run += 1;
        if self.packets.is_empty() {
            // Underrun: the packet is not lost, it just has not arrived yet
            // (e.g. the audio device pulled a burst at start-up). Conceal but
            // keep waiting for it; the catch-up above trims any added delay.
            self.stats.underruns += 1;
            if self.missing_run as usize > self.max_frames {
                self.started = false;
                self.next = None;
                self.highest = None;
                self.last_transit = None;
            } else {
                self.next = Some(next);
            }
            return JitterOut::Missing { next: None };
        }
        self.next = Some(next + 1);
        self.stats.lost += 1;
        let fec = self.packets.get(&(next + 1)).cloned();
        JitterOut::Missing { next: fec }
    }

    pub fn stats(&self) -> JitterStats {
        let mut s = self.stats.clone();
        s.jitter_ms = self.jitter_ms;
        s.target_ms = self.target_frames as u32 * FRAME_MS;
        s.depth_frames = self.packets.len();
        s
    }

    pub fn reset(&mut self) {
        *self = Self::new(self.min_frames as u32 * FRAME_MS, self.max_frames as u32 * FRAME_MS);
    }
}

// ---------------------------------------------------------------------------
// Resampling helpers
// ---------------------------------------------------------------------------

/// Streaming linear resampler (mono f32). Good enough for voice.
#[derive(Debug, Clone)]
pub struct LinearResampler {
    ratio: f64, // input rate / output rate
    pos: f64,
    last: f32,
}

impl LinearResampler {
    pub fn new(in_rate: u32, out_rate: u32) -> Self {
        Self { ratio: in_rate.max(1) as f64 / out_rate.max(1) as f64, pos: 0.0, last: 0.0 }
    }
    pub fn is_identity(&self) -> bool {
        (self.ratio - 1.0).abs() < 1e-9
    }
    pub fn process(&mut self, input: &[f32], out: &mut Vec<f32>) {
        if self.is_identity() {
            out.extend_from_slice(input);
            return;
        }
        // pos is relative to `last` (index -1) .. input
        while self.pos < input.len() as f64 {
            let i = self.pos.floor();
            let frac = (self.pos - i) as f32;
            let i = i as isize;
            let a = if i == 0 { self.last } else { input[(i - 1) as usize] };
            let b = input[i as usize];
            out.push(a + (b - a) * frac);
            self.pos += self.ratio;
        }
        self.pos -= input.len() as f64;
        if let Some(&l) = input.last() {
            self.last = l;
        }
    }
}

// ---------------------------------------------------------------------------
// Opus
// ---------------------------------------------------------------------------

#[cfg(feature = "audio")]
pub use codec::{OpusDecoder, OpusEncoder};

#[cfg(feature = "audio")]
mod codec {
    use super::*;
    use anyhow::anyhow;

    /// Opus voice encoder (48 kHz mono, 20 ms, VOIP mode, in-band FEC).
    pub struct OpusEncoder {
        enc: opus::Encoder,
        buf: Vec<u8>,
    }

    impl OpusEncoder {
        pub fn new(bitrate_bps: i32) -> anyhow::Result<Self> {
            let mut enc = opus::Encoder::new(SAMPLE_RATE, opus::Channels::Mono, opus::Application::Voip)
                .map_err(|e| anyhow!("cannot create Opus encoder: {e}"))?;
            enc.set_bitrate(opus::Bitrate::Bits(bitrate_bps.clamp(6_000, 128_000)))
                .map_err(|e| anyhow!("opus set_bitrate: {e}"))?;
            enc.set_inband_fec(true).map_err(|e| anyhow!("opus set_inband_fec: {e}"))?;
            enc.set_packet_loss_perc(10).map_err(|e| anyhow!("opus set_packet_loss_perc: {e}"))?;
            enc.set_vbr(true).map_err(|e| anyhow!("opus set_vbr: {e}"))?;
            Ok(Self { enc, buf: vec![0u8; 1500] })
        }

        pub fn set_bitrate(&mut self, bps: i32) -> anyhow::Result<()> {
            self.enc
                .set_bitrate(opus::Bitrate::Bits(bps.clamp(6_000, 128_000)))
                .map_err(|e| anyhow!("opus set_bitrate: {e}"))
        }

        /// Tell the encoder the observed loss rate so it sizes FEC accordingly.
        pub fn set_expected_loss(&mut self, percent: u8) -> anyhow::Result<()> {
            self.enc
                .set_packet_loss_perc(percent.min(100) as i32)
                .map_err(|e| anyhow!("opus set_packet_loss_perc: {e}"))
        }

        /// Encode exactly one 20 ms frame (960 samples).
        pub fn encode(&mut self, pcm: &[i16]) -> anyhow::Result<Bytes> {
            if pcm.len() != FRAME_SAMPLES {
                anyhow::bail!("Opus frame must be {FRAME_SAMPLES} samples, got {}", pcm.len());
            }
            let n = self.enc.encode(pcm, &mut self.buf).map_err(|e| anyhow!("opus encode: {e}"))?;
            Ok(Bytes::copy_from_slice(&self.buf[..n]))
        }
    }

    /// Opus decoder with packet-loss concealment and FEC recovery.
    pub struct OpusDecoder {
        dec: opus::Decoder,
    }

    impl OpusDecoder {
        pub fn new() -> anyhow::Result<Self> {
            let dec = opus::Decoder::new(SAMPLE_RATE, opus::Channels::Mono)
                .map_err(|e| anyhow!("cannot create Opus decoder: {e}"))?;
            Ok(Self { dec })
        }

        pub fn decode(&mut self, packet: &[u8]) -> anyhow::Result<PcmFrame> {
            let mut out = vec![0i16; FRAME_SAMPLES * 6]; // up to 120 ms packets
            let n = self.dec.decode(packet, &mut out, false).map_err(|e| anyhow!("opus decode: {e}"))?;
            out.truncate(n);
            Ok(out)
        }

        /// Conceal one lost frame. If the *following* packet is available its
        /// in-band FEC data is used to reconstruct the lost one.
        pub fn conceal(&mut self, next_packet: Option<&[u8]>) -> PcmFrame {
            let mut out = vec![0i16; FRAME_SAMPLES];
            let r = match next_packet {
                Some(p) => self.dec.decode(p, &mut out, true),
                None => self.dec.decode(&[], &mut out, false),
            };
            match r {
                Ok(n) => out.truncate(n.max(1)),
                Err(_) => out.fill(0),
            }
            out.resize(FRAME_SAMPLES, 0);
            out
        }

        /// Turn a jitter-buffer output into 20 ms of PCM.
        pub fn render(&mut self, j: JitterOut) -> PcmFrame {
            match j {
                JitterOut::Packet(p) => {
                    let mut v = self.decode(&p).unwrap_or_else(|_| self.conceal(None));
                    v.resize(FRAME_SAMPLES, 0);
                    v
                }
                JitterOut::Missing { next } => self.conceal(next.as_deref()),
                JitterOut::Buffering => vec![0; FRAME_SAMPLES],
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Device I/O (cpal)
// ---------------------------------------------------------------------------

#[cfg(feature = "audio")]
pub use device::{list_devices, AudioCapture, AudioDeviceInfo, AudioPlayer};

#[cfg(feature = "audio")]
mod device {
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::mpsc;
    use std::sync::Arc;
    use std::thread::JoinHandle;
    use std::time::{Duration, Instant};

    use anyhow::{anyhow, Context};
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
    use cpal::{FromSample, SampleFormat, SizedSample};
    use parking_lot::Mutex;

    use super::*;

    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct AudioDeviceInfo {
        pub id: String,
        pub name: String,
        pub input: bool,
        pub output: bool,
        pub default: bool,
    }

    /// Enumerate audio devices of the default host.
    pub fn list_devices() -> Vec<AudioDeviceInfo> {
        let host = cpal::default_host();
        let din = host.default_input_device().and_then(|d| d.id().ok()).map(|i| i.to_string());
        let dout = host.default_output_device().and_then(|d| d.id().ok()).map(|i| i.to_string());
        let mut v = Vec::new();
        if let Ok(devs) = host.devices() {
            for d in devs {
                let Ok(id) = d.id().map(|i| i.to_string()) else { continue };
                let name = d.description().map(|x| x.name().to_string()).unwrap_or_else(|_| id.clone());
                let (i, o) = (d.supports_input(), d.supports_output());
                let default = Some(&id) == din.as_ref() || Some(&id) == dout.as_ref();
                v.push(AudioDeviceInfo { id, name, input: i, output: o, default });
            }
        }
        v
    }

    fn find_device(host: &cpal::Host, id: Option<&str>, input: bool) -> anyhow::Result<cpal::Device> {
        if let Some(id) = id {
            let parsed = id.parse().map_err(|_| anyhow!("invalid audio device id {id:?}"))?;
            return host.device_by_id(&parsed).ok_or_else(|| anyhow!("audio device {id:?} not found"));
        }
        if input {
            host.default_input_device().ok_or_else(|| anyhow!("no microphone (default input device) found"))
        } else {
            host.default_output_device().ok_or_else(|| anyhow!("no speaker (default output device) found"))
        }
    }

    /// Microphone capture producing 48 kHz mono 20 ms frames.
    pub struct AudioCapture {
        rx: mpsc::Receiver<PcmFrame>,
        stop: Arc<AtomicBool>,
        thread: Option<JoinHandle<()>>,
        pub gate_enabled: Arc<AtomicBool>,
        /// Acoustic echo cancellation (on by default; turn off when using headphones).
        pub aec_enabled: Arc<AtomicBool>,
        aec: Mutex<Option<aec_rs::Aec>>,
        /// RNNoise noise suppression (on by default, toggled at runtime).
        pub ns_enabled: Arc<AtomicBool>,
        ns: Mutex<Option<NoiseSuppressor>>,
    }

    struct Framer {
        channels: usize,
        resampler: LinearResampler,
        mono: Vec<f32>,
        resampled: Vec<f32>,
        acc: Vec<i16>,
        gate: NoiseGate,
        gate_on: Arc<AtomicBool>,
        tx: mpsc::SyncSender<PcmFrame>,
    }

    impl Framer {
        fn push(&mut self, interleaved: impl Iterator<Item = f32>) {
            self.mono.clear();
            let ch = self.channels.max(1);
            let mut sum = 0.0;
            for (i, s) in interleaved.enumerate() {
                sum += s;
                if i % ch == ch - 1 {
                    self.mono.push(sum / ch as f32);
                    sum = 0.0;
                }
            }
            self.resampled.clear();
            self.resampler.process(&self.mono, &mut self.resampled);
            for &s in &self.resampled {
                self.acc.push((s * 32767.0).round().clamp(-32768.0, 32767.0) as i16);
                if self.acc.len() == FRAME_SAMPLES {
                    let mut f = std::mem::replace(&mut self.acc, Vec::with_capacity(FRAME_SAMPLES));
                    if self.gate_on.load(Ordering::Relaxed) {
                        self.gate.process(&mut f);
                    }
                    let _ = self.tx.try_send(f); // drop if the consumer stalls
                }
            }
        }
    }

    fn build_input<T>(dev: &cpal::Device, cfg: cpal::StreamConfig, mut framer: Framer) -> anyhow::Result<cpal::Stream>
    where
        T: SizedSample + Send + 'static,
        f32: FromSample<T>,
    {
        dev.build_input_stream::<T, _, _>(
            cfg,
            move |data: &[T], _| framer.push(data.iter().map(|&s| f32::from_sample_(s))),
            |e| tracing::warn!("audio input error: {e}"),
            None,
        )
        .map_err(|e| anyhow!("cannot open microphone stream: {e}"))
    }

    impl AudioCapture {
        /// Start capturing from `device_id` (or the default microphone).
        pub fn start(device_id: Option<&str>) -> anyhow::Result<Self> {
            let (tx, rx) = mpsc::sync_channel::<PcmFrame>(16);
            let (ready_tx, ready_rx) = mpsc::channel::<anyhow::Result<()>>();
            let stop = Arc::new(AtomicBool::new(false));
            let gate_enabled = Arc::new(AtomicBool::new(true));
            let (stop2, gate2) = (stop.clone(), gate_enabled.clone());
            let id = device_id.map(str::to_owned);
            // cpal streams are not Send on every platform: own it on a thread.
            let thread = std::thread::Builder::new()
                .name("lumora-audio-in".into())
                .spawn(move || {
                    let res = (|| -> anyhow::Result<cpal::Stream> {
                        let host = cpal::default_host();
                        let dev = find_device(&host, id.as_deref(), true)?;
                        let sup = dev.default_input_config().map_err(|e| anyhow!("microphone has no usable format: {e}"))?;
                        let fmt = sup.sample_format();
                        let cfg: cpal::StreamConfig = sup.config();
                        let framer = Framer {
                            channels: cfg.channels as usize,
                            resampler: LinearResampler::new(cfg.sample_rate, SAMPLE_RATE),
                            mono: Vec::new(),
                            resampled: Vec::new(),
                            acc: Vec::with_capacity(FRAME_SAMPLES),
                            gate: NoiseGate::default(),
                            gate_on: gate2,
                            tx,
                        };
                        let stream = match fmt {
                            SampleFormat::F32 => build_input::<f32>(&dev, cfg, framer)?,
                            SampleFormat::I16 => build_input::<i16>(&dev, cfg, framer)?,
                            SampleFormat::I32 => build_input::<i32>(&dev, cfg, framer)?,
                            SampleFormat::U16 => build_input::<u16>(&dev, cfg, framer)?,
                            SampleFormat::U8 => build_input::<u8>(&dev, cfg, framer)?,
                            SampleFormat::F64 => build_input::<f64>(&dev, cfg, framer)?,
                            other => anyhow::bail!("unsupported microphone sample format {other:?}"),
                        };
                        stream.play().map_err(|e| anyhow!("cannot start microphone: {e}"))?;
                        Ok(stream)
                    })();
                    match res {
                        Ok(stream) => {
                            let _ = ready_tx.send(Ok(()));
                            while !stop2.load(Ordering::Relaxed) {
                                std::thread::park_timeout(Duration::from_millis(200));
                            }
                            drop(stream);
                        }
                        Err(e) => {
                            let _ = ready_tx.send(Err(e));
                        }
                    }
                })
                .context("failed to spawn audio thread")?;
            match ready_rx.recv_timeout(Duration::from_secs(5)) {
                Ok(Ok(())) => Ok(Self {
                    rx,
                    stop,
                    thread: Some(thread),
                    gate_enabled,
                    aec_enabled: Arc::new(AtomicBool::new(true)),
                    aec: Mutex::new(None),
                    ns_enabled: Arc::new(AtomicBool::new(true)),
                    ns: Mutex::new(None),
                }),
                Ok(Err(e)) => {
                    let _ = thread.join();
                    Err(e)
                }
                Err(_) => {
                    stop.store(true, Ordering::Relaxed);
                    anyhow::bail!("timed out opening the microphone")
                }
            }
        }

        /// Next 20 ms frame, or `None` on timeout. Echo of what the speakers play is
        /// removed (speexdsp MDF echo canceller, 200 ms tail), then background noise
        /// (RNNoise), each unless disabled.
        pub fn next_frame(&self, timeout: Duration) -> anyhow::Result<Option<PcmFrame>> {
            match self.rx.recv_timeout(timeout) {
                Ok(f) => {
                    let mut out = self.cancel_echo(f);
                    if self.ns_enabled.load(Ordering::Relaxed) {
                        self.ns.lock().get_or_insert_with(NoiseSuppressor::new).process(&mut out);
                    } else {
                        // start fresh next time it's switched on
                        self.ns.lock().take();
                    }
                    Ok(Some(out))
                }
                Err(mpsc::RecvTimeoutError::Timeout) => Ok(None),
                Err(mpsc::RecvTimeoutError::Disconnected) => Err(anyhow!("microphone stream stopped")),
            }
        }
    }

    impl AudioCapture {
        fn cancel_echo(&self, f: PcmFrame) -> PcmFrame {
            if !self.aec_enabled.load(Ordering::Relaxed) {
                return f;
            }
            let Some(far) = far_end_frame(f.len()) else { return f };
            let mut aec = self.aec.lock();
            let a = aec.get_or_insert_with(|| {
                aec_rs::Aec::new(&aec_rs::AecConfig {
                    frame_size: f.len(),
                    filter_length: 48_000 / 5,
                    sample_rate: 48_000,
                    enable_preprocess: true,
                })
            });
            let mut out = vec![0i16; f.len()];
            a.cancel_echo(&f, &far, &mut out);
            out
        }
    }

    impl Drop for AudioCapture {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            if let Some(t) = self.thread.take() {
                t.thread().unpark();
                let _ = t.join();
            }
        }
    }

    /// Far-end reference for echo cancellation: what every active player just played
    /// (48 kHz mono, one queue per player; the mic path sums them frame by frame).
    static FAR_END: std::sync::LazyLock<Mutex<std::collections::HashMap<u64, VecDeque<Vec<i16>>>>> =
        std::sync::LazyLock::new(|| Mutex::new(std::collections::HashMap::new()));
    static NEXT_PLAYER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

    fn far_end_frame(n: usize) -> Option<Vec<i16>> {
        let mut m = FAR_END.lock();
        let mut acc: Option<Vec<i32>> = None;
        for q in m.values_mut() {
            if let Some(f) = q.pop_front() {
                let a = acc.get_or_insert_with(|| vec![0i32; n]);
                for (i, s) in f.iter().take(n).enumerate() {
                    a[i] += *s as i32;
                }
            }
        }
        m.retain(|_, q| !q.is_empty()); // players that stopped disappear from the map
        acc.map(|a| a.into_iter().map(|v| v.clamp(i16::MIN as i32, i16::MAX as i32) as i16).collect())
    }

    struct PlayState {
        player_id: u64,
        jb: JitterBuffer,
        dec: OpusDecoder,
        out: VecDeque<f32>,
        resampler: LinearResampler,
        tmp_in: Vec<f32>,
        tmp_out: Vec<f32>,
        volume: f32,
    }

    impl PlayState {
        fn refill(&mut self) {
            let j = self.jb.pop();
            let pcm = self.dec.render(j);
            {
                let mut m = FAR_END.lock();
                let q = m.entry(self.player_id).or_default();
                q.push_back(pcm.iter().map(|&s| (s as f32 * self.volume) as i16).collect());
                while q.len() > 25 {
                    q.pop_front(); // keep ≤ 500 ms of reference
                }
            }
            self.tmp_in.clear();
            self.tmp_in.extend(pcm.iter().map(|&s| s as f32 / 32768.0 * self.volume));
            self.tmp_out.clear();
            self.resampler.process(&self.tmp_in, &mut self.tmp_out);
            self.out.extend(self.tmp_out.iter().copied());
        }
    }

    /// Speaker output fed with Opus packets through an adaptive jitter buffer.
    /// The output device's callback is the playout clock: every 20 ms worth
    /// of samples it pulls one frame (packet, FEC/PLC, or silence).
    pub struct AudioPlayer {
        state: Arc<Mutex<PlayState>>,
        stop: Arc<AtomicBool>,
        thread: Option<JoinHandle<()>>,
        epoch: Instant,
    }

    fn build_output<T>(dev: &cpal::Device, cfg: cpal::StreamConfig, st: Arc<Mutex<PlayState>>) -> anyhow::Result<cpal::Stream>
    where
        T: SizedSample + FromSample<f32> + Send + 'static,
    {
        let ch = cfg.channels.max(1) as usize;
        dev.build_output_stream::<T, _, _>(
            cfg,
            move |data: &mut [T], _| {
                let mut s = st.lock();
                for frame in data.chunks_mut(ch) {
                    if s.out.is_empty() {
                        s.refill();
                    }
                    let v = s.out.pop_front().unwrap_or(0.0);
                    for x in frame.iter_mut() {
                        *x = T::from_sample_(v);
                    }
                }
            },
            |e| tracing::warn!("audio output error: {e}"),
            None,
        )
        .map_err(|e| anyhow!("cannot open speaker stream: {e}"))
    }

    impl AudioPlayer {
        pub fn start(device_id: Option<&str>) -> anyhow::Result<Self> {
            let (ready_tx, ready_rx) = mpsc::channel::<anyhow::Result<Arc<Mutex<PlayState>>>>();
            let stop = Arc::new(AtomicBool::new(false));
            let stop2 = stop.clone();
            let id = device_id.map(str::to_owned);
            let thread = std::thread::Builder::new()
                .name("lumora-audio-out".into())
                .spawn(move || {
                    let res = (|| -> anyhow::Result<(cpal::Stream, Arc<Mutex<PlayState>>)> {
                        let host = cpal::default_host();
                        let dev = find_device(&host, id.as_deref(), false)?;
                        let sup = dev.default_output_config().map_err(|e| anyhow!("speaker has no usable format: {e}"))?;
                        let fmt = sup.sample_format();
                        let cfg: cpal::StreamConfig = sup.config();
                        let st = Arc::new(Mutex::new(PlayState {
                            player_id: NEXT_PLAYER.fetch_add(1, Ordering::Relaxed),
                            jb: JitterBuffer::default(),
                            dec: OpusDecoder::new()?,
                            out: VecDeque::with_capacity(8192),
                            resampler: LinearResampler::new(SAMPLE_RATE, cfg.sample_rate),
                            tmp_in: Vec::new(),
                            tmp_out: Vec::new(),
                            volume: 1.0,
                        }));
                        let stream = match fmt {
                            SampleFormat::F32 => build_output::<f32>(&dev, cfg, st.clone())?,
                            SampleFormat::I16 => build_output::<i16>(&dev, cfg, st.clone())?,
                            SampleFormat::I32 => build_output::<i32>(&dev, cfg, st.clone())?,
                            SampleFormat::U16 => build_output::<u16>(&dev, cfg, st.clone())?,
                            SampleFormat::U8 => build_output::<u8>(&dev, cfg, st.clone())?,
                            SampleFormat::F64 => build_output::<f64>(&dev, cfg, st.clone())?,
                            other => anyhow::bail!("unsupported speaker sample format {other:?}"),
                        };
                        stream.play().map_err(|e| anyhow!("cannot start speaker: {e}"))?;
                        Ok((stream, st))
                    })();
                    match res {
                        Ok((stream, st)) => {
                            let _ = ready_tx.send(Ok(st));
                            while !stop2.load(Ordering::Relaxed) {
                                std::thread::park_timeout(Duration::from_millis(200));
                            }
                            drop(stream);
                        }
                        Err(e) => {
                            let _ = ready_tx.send(Err(e));
                        }
                    }
                })
                .context("failed to spawn audio thread")?;
            match ready_rx.recv_timeout(Duration::from_secs(5)) {
                Ok(Ok(state)) => Ok(Self { state, stop, thread: Some(thread), epoch: Instant::now() }),
                Ok(Err(e)) => {
                    let _ = thread.join();
                    Err(e)
                }
                Err(_) => {
                    stop.store(true, Ordering::Relaxed);
                    anyhow::bail!("timed out opening the speaker")
                }
            }
        }

        /// Feed one received Opus packet with its 16-bit sequence number.
        pub fn push_packet(&self, seq: u16, packet: Bytes) {
            let now = self.epoch.elapsed().as_secs_f64() * 1000.0;
            self.state.lock().jb.push(seq, packet, now);
        }

        pub fn set_volume(&self, v: f32) {
            self.state.lock().volume = v.clamp(0.0, 4.0);
        }

        pub fn stats(&self) -> JitterStats {
            self.state.lock().jb.stats()
        }

        /// Forget buffered audio (e.g. when the remote restarts its stream).
        pub fn reset(&self) {
            let mut s = self.state.lock();
            s.jb.reset();
            s.out.clear();
        }
    }

    impl Drop for AudioPlayer {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
            if let Some(t) = self.thread.take() {
                t.thread().unpark();
                let _ = t.join();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b(n: u8) -> Bytes {
        Bytes::from(vec![n])
    }

    /// Review scratch test `jitter_seq_jump_drops_real_audio`: one packet with a
    /// sequence number far ahead used to make the buffer skip there and then drop
    /// every real packet as late (~10 minutes of silence). A lone jump is ignored;
    /// a real restart of the sequence (two packets in a row) is followed.
    #[test]
    fn jitter_ignores_a_stray_far_ahead_packet() {
        let mut jb = JitterBuffer::default();
        let mut t = 0.0;
        let mut seq: u16 = 0;
        let (mut played, mut total) = (0, 0);
        for i in 0..400 {
            if i == 100 {
                jb.push(seq.wrapping_add(30000), Bytes::from_static(b"x"), t);
            }
            jb.push(seq, Bytes::from_static(b"a"), t);
            seq = seq.wrapping_add(1);
            t += 20.0;
            let out = jb.pop();
            if i >= 100 {
                total += 1;
                if matches!(out, JitterOut::Packet(ref p) if p.as_ref() == b"a") {
                    played += 1;
                }
            }
        }
        assert!(played >= total - 2, "played {played}/{total} real packets: {:?}", jb.stats());
        // the sender restarts its sequence: followed after the second packet
        let mut seq2: u16 = 20_000;
        let mut after = 0;
        for _ in 0..50 {
            jb.push(seq2, Bytes::from_static(b"b"), t);
            seq2 = seq2.wrapping_add(1);
            t += 20.0;
            if matches!(jb.pop(), JitterOut::Packet(ref p) if p.as_ref() == b"b") {
                after += 1;
            }
        }
        assert!(after >= 45, "restarted stream plays: {after}/50");
    }

    #[test]
    fn jitter_in_order() {
        let mut jb = JitterBuffer::new(20, 120);
        for i in 0..50u16 {
            jb.push(i, b(i as u8), i as f64 * 20.0);
            assert_eq!(jb.pop(), JitterOut::Packet(b(i as u8)));
        }
        assert_eq!(jb.stats().lost, 0);
    }

    #[test]
    fn jitter_reorders() {
        let mut jb = JitterBuffer::new(60, 120);
        // Arrive 0,2,1,3 — buffer must hand out 0,1,2,3.
        for (k, seq) in [0u16, 2, 1, 3].iter().enumerate() {
            jb.push(*seq, b(*seq as u8), k as f64 * 20.0);
        }
        for i in 0..4u8 {
            assert_eq!(jb.pop(), JitterOut::Packet(b(i)));
        }
    }

    #[test]
    fn jitter_loss_gives_missing_with_fec() {
        let mut jb = JitterBuffer::new(20, 120);
        jb.push(10, b(10), 0.0);
        jb.push(12, b(12), 40.0);
        jb.push(13, b(13), 60.0);
        assert_eq!(jb.pop(), JitterOut::Packet(b(10)));
        assert_eq!(jb.pop(), JitterOut::Missing { next: Some(b(12)) });
        assert_eq!(jb.pop(), JitterOut::Packet(b(12)));
        assert_eq!(jb.stats().lost, 1);
        // Late duplicate of an already played packet is discarded.
        jb.push(11, b(11), 70.0);
        assert_eq!(jb.stats().late, 1);
        assert_eq!(jb.pop(), JitterOut::Packet(b(13)));
    }

    #[test]
    fn jitter_underrun_does_not_skip() {
        let mut jb = JitterBuffer::new(20, 120);
        jb.push(0, b(0), 0.0);
        assert_eq!(jb.pop(), JitterOut::Packet(b(0)));
        // Device pulls faster than packets arrive: conceal, but wait for #1.
        assert_eq!(jb.pop(), JitterOut::Missing { next: None });
        assert_eq!(jb.pop(), JitterOut::Missing { next: None });
        jb.push(1, b(1), 60.0);
        assert_eq!(jb.pop(), JitterOut::Packet(b(1)));
        let s = jb.stats();
        assert_eq!((s.lost, s.late, s.underruns), (0, 0, 2));
    }

    #[test]
    fn jitter_sequence_wraps() {
        let mut jb = JitterBuffer::new(20, 120);
        let seqs = [65534u16, 65535, 0, 1];
        for (k, s) in seqs.iter().enumerate() {
            jb.push(*s, b(k as u8), k as f64 * 20.0);
        }
        for k in 0..4u8 {
            assert_eq!(jb.pop(), JitterOut::Packet(b(k)));
        }
    }

    #[test]
    fn jitter_adapts_target() {
        let mut jb = JitterBuffer::new(20, 120);
        assert_eq!(jb.stats().target_ms, 20);
        // Heavy jitter: alternate early/late by 30 ms.
        for i in 0..200u16 {
            let t = i as f64 * 20.0 + if i % 2 == 0 { 0.0 } else { 30.0 };
            jb.push(i, b(0), t);
            let _ = jb.pop();
        }
        let s = jb.stats();
        assert!(s.target_ms >= 80 && s.target_ms <= 120, "target {} ms jitter {:.1}", s.target_ms, s.jitter_ms);
    }

    #[test]
    fn jitter_buffering_then_overflow_catchup() {
        let mut jb = JitterBuffer::new(40, 120);
        assert_eq!(jb.pop(), JitterOut::Buffering);
        jb.push(0, b(0), 0.0);
        assert_eq!(jb.pop(), JitterOut::Buffering); // need 2 frames
        for i in 1..20u16 {
            jb.push(i, b(i as u8), 20.0 * i as f64);
        }
        // Way past target: first pop skips ahead close to the newest packet.
        match jb.pop() {
            JitterOut::Packet(p) => assert!(p[0] >= 15, "did not catch up: {}", p[0]),
            o => panic!("unexpected {o:?}"),
        }
    }

    #[test]
    fn noise_gate_attenuates_hiss_and_passes_voice() {
        let mut g = NoiseGate::default();
        let mut hiss: Vec<i16> = (0..FRAME_SAMPLES).map(|i| if i % 2 == 0 { 30 } else { -30 }).collect();
        for _ in 0..20 {
            g.process(&mut hiss);
        }
        assert!(!g.is_open());
        assert!(hiss.iter().all(|s| s.abs() <= 2));
        let mut voice: Vec<i16> =
            (0..FRAME_SAMPLES).map(|i| ((i as f32 * 0.05).sin() * 8000.0) as i16).collect();
        g.process(&mut voice);
        assert!(g.is_open());
    }

    #[test]
    fn resampler_rates() {
        let mut r = LinearResampler::new(44_100, 48_000);
        let mut out = Vec::new();
        for _ in 0..100 {
            r.process(&[0.5f32; 441], &mut out);
        }
        assert!((out.len() as i64 - 48_000).abs() <= 2, "{}", out.len());
    }

    /// Deterministic white noise in ±amp.
    #[cfg(feature = "audio")]
    fn noise(seed: &mut u32, n: usize, amp: f32) -> Vec<i16> {
        (0..n)
            .map(|_| {
                *seed ^= *seed << 13;
                *seed ^= *seed >> 17;
                *seed ^= *seed << 5;
                ((*seed as f32 / u32::MAX as f32) * 2.0 - 1.0) * amp
            })
            .map(|x| x as i16)
            .collect()
    }

    #[cfg(feature = "audio")]
    fn rms(x: &[i16]) -> f64 {
        (x.iter().map(|&s| (s as f64).powi(2)).sum::<f64>() / x.len().max(1) as f64).sqrt()
    }

    /// RNNoise removes steady background noise and its CPU cost per 20 ms frame is small.
    /// Run with `--nocapture` to see the measured cost.
    #[cfg(feature = "audio")]
    #[test]
    fn noise_suppression_removes_noise_and_is_cheap() {
        let mut ns = NoiseSuppressor::new();
        let mut seed = 0x1234_5678u32;
        let frames = 500; // 10 s of audio
        let mut in_rms = 0.0;
        let mut out_rms = 0.0;
        let mut lp = 0f32;
        let t0 = std::time::Instant::now();
        for i in 0..frames {
            // fan-like noise: low-passed white noise
            let mut f = noise(&mut seed, FRAME_SAMPLES, 3000.0);
            for s in f.iter_mut() {
                lp = lp * 0.9 + *s as f32 * 0.1;
                *s = (lp * 3.0) as i16;
            }
            let r_in = rms(&f);
            ns.process(&mut f);
            assert_eq!(f.len(), FRAME_SAMPLES);
            if i >= 50 {
                in_rms += r_in;
                out_rms += rms(&f);
            }
        }
        let dt = t0.elapsed();
        let per_frame_us = dt.as_secs_f64() * 1e6 / frames as f64;
        let cpu_pct = per_frame_us / (FRAME_MS as f64 * 1000.0) * 100.0;
        println!(
            "noise suppression: {per_frame_us:.0} µs per 20 ms frame = {cpu_pct:.2}% of one core; noise {:.0} → {:.0} RMS ({:.1} dB)",
            in_rms / (frames - 50) as f64,
            out_rms / (frames - 50) as f64,
            20.0 * (out_rms / in_rms).log10()
        );
        assert!(out_rms < in_rms * 0.5, "noise not reduced: {in_rms} → {out_rms}");
        // generous bound (debug builds, busy CI): must stay well under real time
        assert!(per_frame_us < 10_000.0, "too slow: {per_frame_us} µs/frame");
    }

    #[cfg(feature = "audio")]
    #[test]
    fn opus_roundtrip_and_plc() {
        let mut enc = OpusEncoder::new(32_000).unwrap();
        let mut dec = OpusDecoder::new().unwrap();
        let tone: Vec<i16> = (0..FRAME_SAMPLES).map(|i| ((i as f32 * 0.1).sin() * 10000.0) as i16).collect();
        let mut energy = 0f64;
        for _ in 0..5 {
            let p = enc.encode(&tone).unwrap();
            assert!(!p.is_empty() && p.len() < 400);
            let out = dec.decode(&p).unwrap();
            assert_eq!(out.len(), FRAME_SAMPLES);
            energy = out.iter().map(|&s| (s as f64).powi(2)).sum::<f64>();
        }
        assert!(energy > 1e9, "decoded tone is silent");
        let plc = dec.render(JitterOut::Missing { next: None });
        assert_eq!(plc.len(), FRAME_SAMPLES);
        assert!(enc.encode(&tone[..100]).is_err());
    }
}
