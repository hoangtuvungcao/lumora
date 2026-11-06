//! Video codec backends behind [`crate::VideoEncoder`] / [`crate::VideoDecoder`].
//!
//! Nothing is downloaded at run time and Lumora ships no H.264 implementation of
//! its own (patent licensing). Every build bundles libvpx (VP8/VP9, BSD licence
//! + royalty-free patent grant); H.264 is used only where the OS provides it:
//!
//! | platform | H.264 (OS / hardware)            | always available     |
//! |----------|----------------------------------|----------------------|
//! | Android  | MediaCodec (NDK)                 | libvpx VP8 / VP9     |
//! | Windows  | Media Foundation MFTs            | libvpx VP8 / VP9     |
//! | macOS    | VideoToolbox                     | libvpx VP8 / VP9     |
//! | iOS      | VideoToolbox                     | libvpx VP8 / VP9     |
//! | Linux    | — (VA-API not implemented yet)   | libvpx VP8 / VP9     |
//!
//! A source-built OpenH264 exists behind the non-default `openh264-source`
//! feature for tests/dev only; release builds never contain it.
//!
//! Which format a sender uses is decided per call/session from both sides'
//! [`Caps`] (exchanged with the call invite/answer and the remote-control
//! request, see [`choose_format`]); every video frame carries its format id, so
//! a sender can switch (e.g. hardware H.264 failed → VP8) on any keyframe.
//! H.264 is Annex-B constrained baseline, no B-frames; all formats use keyframe
//! on demand + a periodic keyframe and CBR driven by the caller's AIMD bitrate.

pub mod annexb;
mod vpx;

#[cfg(feature = "openh264-source")]
mod openh264;

#[cfg(target_os = "android")]
mod mediacodec;
#[cfg(target_os = "linux")]
mod vaapi;
#[cfg(windows)]
mod mf;
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod vt;

use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};

use crate::color::I420Buf;
use crate::video::ContentHint;

/// Bitstream format. The discriminant is the wire id in the media stream
/// header (2 bits): 0 = H.264 — what every older Lumora build sends.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
#[repr(u8)]
pub enum VideoFormat {
    H264 = 0,
    Vp8 = 1,
    Vp9 = 2,
}

impl VideoFormat {
    pub fn wire_id(self) -> u8 {
        self as u8
    }

    pub fn from_wire(id: u8) -> Option<Self> {
        match id {
            0 => Some(Self::H264),
            1 => Some(Self::Vp8),
            2 => Some(Self::Vp9),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::H264 => "h264",
            Self::Vp8 => "vp8",
            Self::Vp9 => "vp9",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "h264" | "avc" => Some(Self::H264),
            "vp8" => Some(Self::Vp8),
            "vp9" => Some(Self::Vp9),
            _ => None,
        }
    }
}

/// Which implementation encodes / decodes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CodecKind {
    /// Android MediaCodec (usually the hardware block of the SoC).
    MediaCodec,
    /// Windows Media Foundation transform.
    MediaFoundation,
    /// Apple VideoToolbox (hardware).
    VideoToolbox,
    /// Linux VA-API (Intel/AMD GPU), libva loaded at run time.
    VaApi,
    /// Bundled libvpx (VP8/VP9, software).
    Libvpx,
    /// OpenH264 compiled from source — tests/dev builds only.
    OpenH264Source,
}

impl CodecKind {
    pub fn label(self) -> &'static str {
        match self {
            CodecKind::MediaCodec => "MediaCodec",
            CodecKind::MediaFoundation => "Media Foundation",
            CodecKind::VideoToolbox => "VideoToolbox",
            CodecKind::VaApi => "VA-API",
            CodecKind::Libvpx => "libvpx",
            CodecKind::OpenH264Source => "OpenH264 (dev build)",
        }
    }

    /// Provided by the operating system (covered by the OS vendor's licence).
    pub fn is_os(self) -> bool {
        matches!(self, CodecKind::MediaCodec | CodecKind::MediaFoundation | CodecKind::VideoToolbox | CodecKind::VaApi)
    }
}

/// The OS H.264 codec of this platform, if any.
pub fn os_kind() -> Option<CodecKind> {
    if cfg!(target_os = "android") {
        Some(CodecKind::MediaCodec)
    } else if cfg!(windows) {
        Some(CodecKind::MediaFoundation)
    } else if cfg!(any(target_os = "macos", target_os = "ios")) {
        Some(CodecKind::VideoToolbox)
    } else if cfg!(target_os = "linux") {
        Some(CodecKind::VaApi)
    } else {
        None
    }
}

/// Backends that can handle `format`, in preference order.
pub(crate) fn candidates(format: VideoFormat) -> Vec<CodecKind> {
    match format {
        VideoFormat::Vp8 | VideoFormat::Vp9 => vec![CodecKind::Libvpx],
        VideoFormat::H264 => {
            let mut v = Vec::new();
            if let Some(k) = os_kind().filter(|_| !no_os_h264()) {
                v.push(k);
            }
            if cfg!(feature = "openh264-source") {
                v.push(CodecKind::OpenH264Source);
            }
            v
        }
    }
}

/// Try `open` for each candidate in order (skipping `skip`); first success wins.
pub(crate) fn open_first<T>(
    cands: &[CodecKind],
    skip: &[CodecKind],
    mut open: impl FnMut(CodecKind) -> anyhow::Result<T>,
) -> anyhow::Result<(CodecKind, T)> {
    let mut errs = Vec::new();
    for &k in cands.iter().filter(|k| !skip.contains(k)) {
        match open(k) {
            Ok(t) => return Ok((k, t)),
            Err(e) => errs.push(format!("{}: {e:#}", k.label())),
        }
    }
    if errs.is_empty() {
        anyhow::bail!("no codec available");
    }
    anyhow::bail!("no codec available ({})", errs.join("; "))
}

/// Encoder settings handed to a backend (dimensions already even).
#[derive(Debug, Clone)]
pub(crate) struct EncParams {
    pub w: usize,
    pub h: usize,
    pub fps: u32,
    pub bitrate_kbps: u32,
    pub content: ContentHint,
    pub threads: u32,
    pub keyframe_interval_s: u32,
}

/// One encoder instance for a fixed picture size.
pub(crate) trait EncBackend: Send {
    /// Encode an I420 picture of exactly `EncParams::w`x`h` (tightly packed).
    /// Returns one access unit (Annex-B for H.264) and whether it is a keyframe,
    /// or `None` if the rate controller skipped the frame / output not ready.
    fn encode(&mut self, pic: &mut I420Buf, ts_us: u64, force_keyframe: bool) -> anyhow::Result<Option<(Vec<u8>, bool)>>;
    fn set_bitrate(&mut self, kbps: u32);
    fn hardware(&self) -> bool;
}

/// A decoded picture borrowed from a backend. Chroma samples are `uv_step`
/// bytes apart (1 = planar I420, 2 = interleaved NV12 — `u`/`v` then point at
/// the first U/V byte).
pub(crate) struct YuvView<'a> {
    pub w: usize,
    pub h: usize,
    pub y: &'a [u8],
    pub y_stride: usize,
    pub u: &'a [u8],
    pub v: &'a [u8],
    pub uv_stride: usize,
    pub uv_step: usize,
}

/// One decoder instance.
pub(crate) trait DecBackend: Send {
    fn decode(&mut self, au: &[u8]) -> anyhow::Result<Option<YuvView<'_>>>;
    fn hardware(&self) -> bool;
}

pub(crate) fn open_encoder(kind: CodecKind, format: VideoFormat, p: &EncParams) -> anyhow::Result<Box<dyn EncBackend>> {
    if format != VideoFormat::H264 {
        anyhow::ensure!(kind == CodecKind::Libvpx, "{} cannot encode {}", kind.label(), format.name());
        return Ok(Box::new(vpx::Encoder::new(format, p)?));
    }
    match kind {
        #[cfg(feature = "openh264-source")]
        CodecKind::OpenH264Source => Ok(Box::new(openh264::Encoder::new(openh264::source_api(), p)?)),
        #[cfg(target_os = "android")]
        CodecKind::MediaCodec => Ok(Box::new(mediacodec::Encoder::new(p)?)),
        #[cfg(windows)]
        CodecKind::MediaFoundation => Ok(Box::new(mf::Encoder::new(p)?)),
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        CodecKind::VideoToolbox => Ok(Box::new(vt::Encoder::new(p)?)),
        #[cfg(target_os = "linux")]
        CodecKind::VaApi => Ok(Box::new(vaapi::Encoder::new(p)?)),
        k => anyhow::bail!("{} cannot encode H.264 on this platform", k.label()),
    }
}

// ------------------------------------------------------------------ decode size cap

/// Largest picture a peer may make this device decode, either orientation:
/// 4096 on the long side, 2304 on the short side (covers 4K UHD/DCI and every
/// size our encoder sends, which caps at 3840x2160). A bigger stream is
/// rejected *before* any decoder allocates for it (a few bytes of VP8/H.264
/// header could otherwise ask for gigabytes of frame buffers).
pub const MAX_DECODE_LONG: usize = 4096;
pub const MAX_DECODE_SHORT: usize = 2304;

/// Is `w`x`h` a picture size we accept from a peer?
pub fn decode_dims_ok(w: usize, h: usize) -> bool {
    w > 0 && h > 0 && w.max(h) <= MAX_DECODE_LONG && w.min(h) <= MAX_DECODE_SHORT
}

/// [`decode_dims_ok`] as an error.
pub(crate) fn check_decode_dims(w: usize, h: usize) -> anyhow::Result<()> {
    anyhow::ensure!(decode_dims_ok(w, h), "picture size {w}x{h} exceeds the decode limit ({MAX_DECODE_LONG}x{MAX_DECODE_SHORT})");
    Ok(())
}

/// Check every SPS of an Annex-B access unit against the decode cap (an SPS we
/// cannot parse is rejected too). Call before handing peer data to any H.264
/// decoder; AUs without an SPS pass (the active SPS was checked when it came).
/// Size announced by a VP8/VP9 frame header, see [`vpx::frame_dims`].
pub(crate) fn vpx_frame_dims(format: VideoFormat, d: &[u8]) -> Option<(usize, usize)> {
    vpx::frame_dims(format, d)
}

pub(crate) fn check_h264_au(au: &[u8]) -> anyhow::Result<()> {
    for nal in annexb::nals(au) {
        if annexb::nal_type(nal) == 7 {
            let (w, h) = annexb::sps_dimensions(nal)?;
            check_decode_dims(w as usize, h as usize)?;
        }
    }
    Ok(())
}

pub(crate) fn open_decoder(kind: CodecKind, format: VideoFormat) -> anyhow::Result<Box<dyn DecBackend>> {
    if format != VideoFormat::H264 {
        anyhow::ensure!(kind == CodecKind::Libvpx, "{} cannot decode {}", kind.label(), format.name());
        return Ok(Box::new(vpx::Decoder::new(format)?));
    }
    match kind {
        #[cfg(feature = "openh264-source")]
        CodecKind::OpenH264Source => Ok(Box::new(openh264::Decoder::new(openh264::source_api())?)),
        #[cfg(target_os = "android")]
        CodecKind::MediaCodec => Ok(Box::new(mediacodec::Decoder::new()?)),
        #[cfg(windows)]
        CodecKind::MediaFoundation => Ok(Box::new(mf::Decoder::new()?)),
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        CodecKind::VideoToolbox => Ok(Box::new(vt::Decoder::new()?)),
        #[cfg(target_os = "linux")]
        CodecKind::VaApi => Ok(Box::new(vaapi::Decoder::new()?)),
        k => anyhow::bail!("{} cannot decode H.264 on this platform", k.label()),
    }
}

// ------------------------------------------------------------------ capabilities

/// What this device can encode / decode, exchanged with peers (map-encoded).
/// `hw_*` lists formats done in hardware. An empty/absent `Caps` (older peer)
/// means "H.264 only".
/// Lists are read leniently: a format this build doesn't know (a newer peer's
/// "av1", or any other entry) is skipped instead of rejecting the whole `Caps`
/// (which would make the peer look like an H.264-only legacy build).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Caps {
    #[serde(default, deserialize_with = "known_formats")]
    pub enc: Vec<VideoFormat>,
    #[serde(default, deserialize_with = "known_formats")]
    pub dec: Vec<VideoFormat>,
    #[serde(default, deserialize_with = "known_formats")]
    pub hw_enc: Vec<VideoFormat>,
    #[serde(default, deserialize_with = "known_formats")]
    pub hw_dec: Vec<VideoFormat>,
}

/// One entry of a peer's format list: a known format or anything else.
#[derive(Deserialize)]
#[serde(untagged)]
enum WireFormat {
    Known(VideoFormat),
    Other(serde::de::IgnoredAny),
}

fn known_formats<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Vec<VideoFormat>, D::Error> {
    let v: Vec<WireFormat> = Vec::deserialize(d)?;
    let mut out: Vec<VideoFormat> = Vec::with_capacity(v.len().min(16));
    for e in v {
        if let WireFormat::Known(f) = e {
            if !out.contains(&f) {
                out.push(f);
            }
        }
    }
    Ok(out)
}

impl Caps {
    /// What an older Lumora build (no caps exchange) handles: H.264 in and out.
    pub fn legacy() -> Self {
        Caps { enc: vec![VideoFormat::H264], dec: vec![VideoFormat::H264], hw_enc: vec![], hw_dec: vec![] }
    }
}

/// Result of probing the OS H.264 codec.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct H264Probe {
    pub enc: bool,
    pub dec: bool,
    pub enc_hw: bool,
    pub dec_hw: bool,
    /// milliseconds the probe took (diagnostics)
    #[serde(default)]
    pub ms: u32,
}

struct ProbeState {
    result: Option<H264Probe>,
    from_cache: bool,
    running: bool,
}

static PROBE: Mutex<ProbeState> = Mutex::new(ProbeState { result: None, from_cache: false, running: false });

/// Key of the probe cache: the result is reused while the OS build and the app
/// version stay the same (a driver/OS update re-probes).
fn device_key() -> String {
    format!("{}-{}-{}-{}", std::env::consts::OS, std::env::consts::ARCH, env!("CARGO_PKG_VERSION"), os_build())
}

fn os_build() -> String {
    #[cfg(target_os = "android")]
    {
        let mut buf = [0u8; 92];
        // SAFETY: PROP_VALUE_MAX is 92 bytes including NUL.
        let n = unsafe { libc::__system_property_get(c"ro.build.fingerprint".as_ptr(), buf.as_mut_ptr().cast()) };
        return String::from_utf8_lossy(&buf[..n.max(0) as usize]).into_owned();
    }
    #[cfg(target_os = "linux")]
    {
        return std::fs::read_to_string("/proc/sys/kernel/osrelease").unwrap_or_default().trim().to_string();
    }
    #[allow(unreachable_code)]
    String::new()
}

fn cache_file(dir: &Path) -> PathBuf {
    dir.join("video_codecs.json")
}

/// Probe the OS H.264 codec in the background (once per process). With a cache
/// directory, a previous result for this device/OS build is used immediately
/// and re-validated in the background; the new result is written back.
pub fn start_probe(cache_dir: Option<&Path>) {
    {
        let mut st = PROBE.lock();
        if st.running || (st.result.is_some() && !st.from_cache) {
            return;
        }
        if st.result.is_none() {
            if let Some(dir) = cache_dir {
                if let Some(r) = read_cache(dir) {
                    st.result = Some(r);
                    st.from_cache = true;
                }
            }
        }
        st.running = true;
    }
    let dir = cache_dir.map(Path::to_path_buf);
    let spawned = std::thread::Builder::new().name("lumora-codec-probe".into()).spawn(move || {
        let r = probe_now();
        if let Some(d) = dir.as_deref() {
            write_cache(d, &r);
        }
        let mut st = PROBE.lock();
        st.result = Some(r);
        st.from_cache = false;
        st.running = false;
    });
    if spawned.is_err() {
        PROBE.lock().running = false;
    }
}

fn read_cache(dir: &Path) -> Option<H264Probe> {
    let v: serde_json::Value = serde_json::from_slice(&std::fs::read(cache_file(dir)).ok()?).ok()?;
    if v.get("key")?.as_str()? != device_key() {
        return None;
    }
    serde_json::from_value(v.get("h264")?.clone()).ok()
}

fn write_cache(dir: &Path, r: &H264Probe) {
    let _ = std::fs::create_dir_all(dir);
    let v = serde_json::json!({"key": device_key(), "h264": r});
    let tmp = dir.join("video_codecs.json.tmp");
    if std::fs::write(&tmp, v.to_string()).is_ok() {
        let _ = std::fs::rename(&tmp, cache_file(dir));
    }
}

/// Encode a few frames with the OS H.264 codec and decode them with it.
fn probe_now() -> H264Probe {
    let t = Instant::now();
    let mut r = H264Probe::default();
    let Some(kind) = os_kind() else { return r };
    if forced_os_failure() || no_os_h264() {
        return r;
    }
    let p = EncParams { w: 320, h: 240, fps: 30, bitrate_kbps: 500, content: ContentHint::Motion, threads: 1, keyframe_interval_s: 2 };
    let mut aus = Vec::new();
    match open_encoder(kind, VideoFormat::H264, &p) {
        Ok(mut enc) => {
            r.enc_hw = enc.hardware();
            let mut pic = I420Buf::new(320, 240);
            for (i, px) in pic.y.iter_mut().enumerate() {
                *px = (i % 320) as u8;
            }
            for t in 0..6u64 {
                match enc.encode(&mut pic, t * 33_333, t == 0) {
                    Ok(Some((au, _))) => aus.push(au),
                    Ok(None) => {}
                    Err(e) => {
                        tracing::info!("{} H.264 encoder probe failed: {e:#}", kind.label());
                        break;
                    }
                }
            }
            r.enc = !aus.is_empty() && annexb::has_idr(&aus[0]);
        }
        Err(e) => tracing::info!("{} H.264 encoder unavailable: {e:#}", kind.label()),
    }
    // decoder: feed what we encoded (or nothing — then only "can open" is known)
    match open_decoder(kind, VideoFormat::H264) {
        Ok(mut dec) => {
            r.dec_hw = dec.hardware();
            if aus.is_empty() {
                r.dec = false;
            } else {
                for au in &aus {
                    if let Ok(Some(_)) = dec.decode(au) {
                        r.dec = true;
                        break;
                    }
                }
            }
        }
        Err(e) => tracing::info!("{} H.264 decoder unavailable: {e:#}", kind.label()),
    }
    r.ms = t.elapsed().as_millis().min(u32::MAX as u128) as u32;
    tracing::info!("video codec probe: {:?}", r);
    r
}

/// Last probe result (`None` while the first probe on this device runs).
pub fn h264_probe() -> Option<H264Probe> {
    PROBE.lock().result
}

/// Block up to `max` for the probe (tests, CLI). Starts it if needed.
pub fn wait_probe(max: Duration) -> Option<H264Probe> {
    start_probe(None);
    let until = Instant::now() + max;
    loop {
        {
            let st = PROBE.lock();
            if st.result.is_some() && !st.running {
                return st.result;
            }
        }
        if Instant::now() >= until {
            return h264_probe();
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Senders whose streams the OS H.264 decoder could not decode (see
/// [`note_h264_failure`]); bounded.
static H264_DEC_FAILS: Mutex<Vec<u64>> = Mutex::new(Vec::new());

/// Streams from this many different senders must fail before the OS H.264
/// decoder counts as broken for everyone: a single (possibly hostile) peer
/// sending undecodable "keyframes" must not switch it off device-wide.
const H264_BROKEN_SOURCES: usize = 2;

/// The OS H.264 decoder failed on keyframes from `source` (an id of the sender):
/// stop advertising H.264 to that sender ([`local_caps_for`]) and, once two
/// different senders failed, to everyone ([`local_caps`]). Peers switch to VP8
/// when they get our updated caps.
pub fn note_h264_failure(source: u64) {
    let mut f = H264_DEC_FAILS.lock();
    if !f.contains(&source) {
        if f.len() >= 64 {
            f.remove(0);
        }
        f.push(source);
    }
}

fn h264_dec_broken(source: Option<u64>) -> bool {
    let f = H264_DEC_FAILS.lock();
    f.len() >= H264_BROKEN_SOURCES || source.is_some_and(|s| f.contains(&s))
}

/// This device's capabilities (instant: uses the cached probe).
pub fn local_caps() -> Caps {
    caps_with(None)
}

/// [`local_caps`] as announced to one sender (`source` as in
/// [`crate::VideoDecoder::set_source`]): without H.264 decoding if that sender's
/// streams broke our OS decoder.
pub fn local_caps_for(source: u64) -> Caps {
    caps_with(Some(source))
}

fn caps_with(source: Option<u64>) -> Caps {
    let mut c = Caps { enc: vec![VideoFormat::Vp8, VideoFormat::Vp9], dec: vec![VideoFormat::Vp8, VideoFormat::Vp9], hw_enc: vec![], hw_dec: vec![] };
    if let Some(p) = h264_probe() {
        if p.enc {
            c.enc.insert(0, VideoFormat::H264);
            if p.enc_hw {
                c.hw_enc.push(VideoFormat::H264);
            }
        }
        if p.dec && !h264_dec_broken(source) {
            c.dec.insert(0, VideoFormat::H264);
            if p.dec_hw {
                c.hw_dec.push(VideoFormat::H264);
            }
        }
    }
    if cfg!(feature = "openh264-source") {
        for v in [&mut c.enc, &mut c.dec] {
            if !v.contains(&VideoFormat::H264) {
                v.push(VideoFormat::H264);
            }
        }
    }
    // tests only: pretend the H.264 we have is hardware (exercises the H.264 path and
    // the H.264 → VP8 switch on machines without an OS codec)
    if std::env::var("LUMORA_TEST_H264_HW").is_ok_and(|v| v == "1") {
        if c.enc.contains(&VideoFormat::H264) && !c.hw_enc.contains(&VideoFormat::H264) {
            c.hw_enc.push(VideoFormat::H264);
        }
        if c.dec.contains(&VideoFormat::H264) && !c.hw_dec.contains(&VideoFormat::H264) {
            c.hw_dec.push(VideoFormat::H264);
        }
    }
    c
}

/// Pick the format a sender uses towards `peers` (`None` = an older peer, i.e.
/// H.264 only). Rules:
/// 1. H.264 when this device encodes it in hardware and every peer has an
///    H.264 decoder (always an OS/hardware one in release builds) — the
///    cheapest path for remote desktop at 60 fps and for phone batteries;
/// 2. otherwise VP9 for screen sharing if everyone decodes it (sharper text)…
/// 3. …else VP8, which every current build has;
/// 4. a peer without caps only takes H.264: use it if we can encode it at all,
///    else `None` (no video; the UI asks the other person to update).
pub fn choose_format(local: &Caps, peers: &[Option<Caps>], screen: bool) -> Option<VideoFormat> {
    let legacy = peers.iter().any(Option::is_none);
    if legacy {
        return local.enc.contains(&VideoFormat::H264).then_some(VideoFormat::H264);
    }
    let all = |f: VideoFormat, hw: bool| peers.iter().flatten().all(|c| if hw { c.hw_dec.contains(&f) } else { c.dec.contains(&f) });
    if local.hw_enc.contains(&VideoFormat::H264) && !peers.is_empty() && all(VideoFormat::H264, false) {
        return Some(VideoFormat::H264);
    }
    if screen && vp9_for_screen() && local.enc.contains(&VideoFormat::Vp9) && all(VideoFormat::Vp9, false) {
        return Some(VideoFormat::Vp9);
    }
    if local.enc.contains(&VideoFormat::Vp8) && all(VideoFormat::Vp8, false) {
        return Some(VideoFormat::Vp8);
    }
    if local.enc.contains(&VideoFormat::H264) && all(VideoFormat::H264, false) {
        return Some(VideoFormat::H264);
    }
    None
}

/// `LUMORA_NO_OS_H264=1`: ignore the OS/hardware H.264 codec (forces VP8/VP9;
/// benchmarks, tests, support).
pub(crate) fn no_os_h264() -> bool {
    std::env::var("LUMORA_NO_OS_H264").is_ok_and(|v| v == "1")
}

/// VP9 is only worth it for screen content when the CPU is fast enough.
fn vp9_for_screen() -> bool {
    static V: OnceLock<bool> = OnceLock::new();
    *V.get_or_init(|| match std::env::var("LUMORA_VP9_SCREEN").ok().as_deref() {
        Some("0") => false,
        Some("1") => true,
        // VP9 (much sharper text) costs ~1.5x VP8: only with CPU to spare, so a
        // 4-core machine keeps 60 fps remote desktop on VP8
        _ => std::thread::available_parallelism().map(|n| n.get() >= 8).unwrap_or(false),
    })
}

/// `LUMORA_FORCE_H264_FAIL=1` makes every OS H.264 encoder fail after its first
/// frames (tests of the switch to VP8).
pub(crate) fn forced_os_failure() -> bool {
    #[cfg(test)]
    if FORCE_FAIL_HERE.with(|c| c.get()) {
        return true;
    }
    std::env::var("LUMORA_FORCE_H264_FAIL").map(|v| v == "1").unwrap_or(false)
}

#[cfg(test)]
thread_local! {
    /// Per-test-thread version of `LUMORA_FORCE_H264_FAIL`.
    pub(crate) static FORCE_FAIL_HERE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

// ------------------------------------------------------------------ status

/// What is (or was last) in use, for the UI ("Mã hoá video: phần cứng H.264 / VP8").
#[derive(Debug, Clone, Copy, Serialize)]
pub struct ActiveCodec {
    pub format: VideoFormat,
    pub kind: CodecKind,
    pub label: &'static str,
    pub hardware: bool,
}

static ACTIVE_ENC: Mutex<Option<ActiveCodec>> = Mutex::new(None);
static ACTIVE_DEC: Mutex<Option<ActiveCodec>> = Mutex::new(None);

pub(crate) fn note_active(encoder: bool, format: VideoFormat, kind: CodecKind, hardware: bool) {
    let a = Some(ActiveCodec { format, kind, label: kind.label(), hardware });
    if encoder {
        *ACTIVE_ENC.lock() = a;
    } else {
        *ACTIVE_DEC.lock() = a;
    }
}

/// Everything the app shows about video codecs (call stats / Advanced).
pub fn status() -> serde_json::Value {
    serde_json::json!({
        "os_codec": os_kind().map(|k| k.label()),
        "h264": h264_probe(),
        "caps": local_caps(),
        "encoder": *ACTIVE_ENC.lock(),
        "decoder": *ACTIVE_DEC.lock(),
        "libvpx": "1.17.0",
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use VideoFormat::*;

    fn caps(enc: &[VideoFormat], dec: &[VideoFormat], hw_enc: &[VideoFormat], hw_dec: &[VideoFormat]) -> Caps {
        Caps { enc: enc.to_vec(), dec: dec.to_vec(), hw_enc: hw_enc.to_vec(), hw_dec: hw_dec.to_vec() }
    }

    #[test]
    fn negotiation_matrix() {
        let phone = caps(&[H264, Vp8, Vp9], &[H264, Vp8, Vp9], &[H264], &[H264]); // MediaCodec/VT
        let linux = caps(&[Vp8, Vp9], &[Vp8, Vp9], &[], &[]); // no VA-API
        let win_sw = caps(&[H264, Vp8, Vp9], &[H264, Vp8, Vp9], &[], &[]); // MF software
        let hw_missing = caps(&[Vp8, Vp9], &[Vp8, Vp9], &[], &[]); // probe failed
        // both new, both hardware → H.264
        assert_eq!(choose_format(&phone, &[Some(phone.clone())], false), Some(H264));
        // receiver without any H.264 decoder, or no hardware encoder here → VP8
        assert_eq!(choose_format(&phone, &[Some(linux.clone())], false), Some(Vp8));
        assert_eq!(choose_format(&linux, &[Some(phone.clone())], false), Some(Vp8));
        assert_eq!(choose_format(&win_sw, &[Some(win_sw.clone())], false), Some(Vp8));
        assert_eq!(choose_format(&hw_missing, &[Some(phone.clone())], false), Some(Vp8));
        // hardware encoder here, OS (software) H.264 decoder there → H.264
        assert_eq!(choose_format(&phone, &[Some(win_sw.clone())], true), Some(H264));
        // group: one member without HW H.264 decode → everyone gets VP8
        assert_eq!(choose_format(&phone, &[Some(phone.clone()), Some(linux.clone())], false), Some(Vp8));
        // legacy peer: H.264 if we can encode it at all, otherwise nothing
        assert_eq!(choose_format(&phone, &[None], false), Some(H264));
        assert_eq!(choose_format(&win_sw, &[None], false), Some(H264));
        assert_eq!(choose_format(&linux, &[None], false), None);
        assert_eq!(choose_format(&phone, &[Some(phone.clone()), None], false), Some(H264));
        // a peer that decodes nothing we encode → None
        assert_eq!(choose_format(&linux, &[Some(caps(&[], &[H264], &[], &[]))], false), None);
        // a receiver that only decodes VP8 gets VP8 even from a hardware H.264 sender
        assert_eq!(choose_format(&phone, &[Some(caps(&[H264], &[Vp8], &[], &[]))], false), Some(Vp8));
        // empty peer list (nobody joined yet) → VP8, never H.264 by accident
        assert_eq!(choose_format(&phone, &[], false), Some(Vp8));
    }

    #[test]
    fn caps_wire_compat() {
        let c = caps(&[H264, Vp8], &[Vp8], &[H264], &[]);
        let bytes = rmp_serde::to_vec_named(&c).unwrap();
        let back: Caps = rmp_serde::from_slice(&bytes).unwrap();
        assert_eq!(back, c);
        // a newer peer may add fields; an older body may lack some
        #[derive(Serialize)]
        struct Newer {
            enc: Vec<VideoFormat>,
            dec: Vec<VideoFormat>,
            av1_level: u8,
        }
        let n = rmp_serde::to_vec_named(&Newer { enc: vec![Vp8], dec: vec![Vp8, Vp9], av1_level: 3 }).unwrap();
        let back: Caps = rmp_serde::from_slice(&n).unwrap();
        assert_eq!(back.dec, vec![Vp8, Vp9]);
        assert!(back.hw_enc.is_empty());
        for f in [H264, Vp8, Vp9] {
            assert_eq!(VideoFormat::from_wire(f.wire_id()), Some(f));
            assert_eq!(VideoFormat::parse(f.name()), Some(f));
        }
        assert_eq!(VideoFormat::from_wire(3), None);
    }

    /// A newer peer announcing a format this build doesn't know ("av1") keeps
    /// its known formats (review finding: the whole Caps used to be rejected →
    /// the peer looked like a legacy H.264-only build).
    #[test]
    fn caps_with_future_format_keeps_known_ones() {
        #[derive(Serialize)]
        struct Future {
            enc: Vec<&'static str>,
            dec: Vec<serde_json::Value>,
            hw_dec: Vec<&'static str>,
        }
        let f = Future { enc: vec!["vp8", "av1"], dec: vec!["vp8".into(), "vp9".into(), "av1".into(), 7.into(), serde_json::json!({"x": 1})], hw_dec: vec!["av1"] };
        for b in [rmp_serde::to_vec_named(&f).unwrap(), rmp_serde::to_vec(&f).unwrap()] {
            let c: Caps = rmp_serde::from_slice(&b).expect("future caps parse");
            assert_eq!(c.enc, vec![Vp8]);
            assert_eq!(c.dec, vec![Vp8, Vp9]);
            assert!(c.hw_dec.is_empty() && c.hw_enc.is_empty());
            // and negotiation still picks VP8 with it, not "legacy → H.264"
            assert_eq!(choose_format(&caps(&[Vp8, Vp9], &[Vp8, Vp9], &[], &[]), &[Some(c)], false), Some(Vp8));
        }
    }

    /// One peer's broken "keyframes" only stop H.264 towards that peer; the
    /// device-wide caps drop it only after a second, different peer failed.
    #[test]
    fn h264_decoder_broken_per_peer_then_global() {
        let (a, b) = (0xA11CE_u64 << 20, 0xB0B_u64 << 20);
        note_h264_failure(a);
        note_h264_failure(a);
        assert!(h264_dec_broken(Some(a)));
        assert!(!h264_dec_broken(Some(b)) && !h264_dec_broken(None), "one peer must not break it for everyone");
        note_h264_failure(b);
        assert!(h264_dec_broken(None));
        H264_DEC_FAILS.lock().retain(|s| *s != a && *s != b);
        assert!(!h264_dec_broken(None));
    }

    #[test]
    fn selection_order_and_fallback() {
        use CodecKind::*;
        let order = [MediaCodec, OpenH264Source];
        let mut tried = Vec::new();
        let (k, _) = open_first(&order, &[], |k| {
            tried.push(k);
            if k == MediaCodec { anyhow::bail!("no hw") } else { Ok(()) }
        })
        .unwrap();
        assert_eq!(k, OpenH264Source);
        assert_eq!(tried, vec![MediaCodec, OpenH264Source]);
        let e = open_first(&order, &[OpenH264Source], |_| -> anyhow::Result<()> { anyhow::bail!("nope") }).unwrap_err();
        assert!(format!("{e:#}").contains("MediaCodec: nope"));
        assert!(open_first::<()>(&[], &[], |_| Ok(())).is_err());
        assert_eq!(candidates(Vp8), vec![Libvpx]);
        let h = candidates(H264);
        if cfg!(target_os = "linux") {
            assert_eq!(h[0], VaApi);
            assert_eq!(h.contains(&OpenH264Source), cfg!(feature = "openh264-source"));
        }
    }

    #[test]
    fn local_caps_always_have_vpx_and_cache_roundtrips() {
        let c = local_caps();
        assert!(c.enc.contains(&Vp8) && c.dec.contains(&Vp8) && c.dec.contains(&Vp9));
        let dir = std::env::temp_dir().join(format!("lumora-codec-cache-{}", std::process::id()));
        let r = H264Probe { enc: true, dec: true, enc_hw: true, dec_hw: false, ms: 12 };
        write_cache(&dir, &r);
        assert_eq!(read_cache(&dir), Some(r));
        // a different device/OS build must not reuse it
        std::fs::write(cache_file(&dir), serde_json::json!({"key": "other", "h264": r}).to_string()).unwrap();
        assert_eq!(read_cache(&dir), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
