//! Low-latency video encode/decode behind one API, whatever the codec.
//!
//! [`VideoEncoder`] encodes in the [`VideoFormat`] chosen for the call
//! ([`crate::codec::choose_format`]): H.264 through the OS codec (MediaCodec,
//! Media Foundation, VideoToolbox) or VP8/VP9 through the bundled libvpx. When
//! the H.264 backend fails it switches to the fallback format (VP8, kept warm)
//! on the very same frame, as a keyframe — every [`EncodedFrame`] says its
//! format, and [`VideoDecoder::decode_as`] picks the decoder from it.
//! H.264 is Annex-B constrained baseline with SPS/PPS on every keyframe.

use std::time::{Duration, Instant};

use anyhow::Context;
use bytes::Bytes;
use serde::{Deserialize, Serialize};

use crate::codec::annexb::{has_idr, ParamSets};
use crate::codec::{self, CodecKind, DecBackend, EncBackend, EncParams, VideoFormat};
use crate::color::{i420_to_rgba, rgb32_to_i420, I420Buf, I420};
use crate::{Frame, PixelFormat};

/// Largest picture we encode (H.264 level 5.1/5.2); bigger frames are downscaled 2:1.
const MAX_LONG: usize = 3840;
const MAX_SHORT: usize = 2160;

/// One encoded frame (H.264: an Annex-B access unit; VP8/VP9: one frame).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EncodedFrame {
    pub data: Bytes,
    pub keyframe: bool,
    pub w: u32,
    pub h: u32,
    /// Bitstream format of `data` (older serialisations: H.264).
    #[serde(default = "h264")]
    pub codec: VideoFormat,
}

fn h264() -> VideoFormat {
    VideoFormat::H264
}

/// What kind of content is being encoded (tunes the encoder).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ContentHint {
    /// Camera-like tuning, except for OpenH264 which uses its screen-content
    /// tools up to 1280x720.
    #[default]
    Auto,
    /// Screen content (text, UI): sharper text, fewer dropped frames.
    Screen,
    /// Camera / motion.
    Motion,
}

/// Advanced encoder settings for [`VideoEncoder::with_config`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EncoderConfig {
    pub fps: u32,
    pub bitrate_kbps: u32,
    pub content: ContentHint,
    /// Encoder threads (0 = automatic; software encoders only).
    pub threads: u32,
    /// Periodic keyframe interval in seconds (0 = only on demand).
    pub keyframe_interval_s: u32,
    /// Format to encode (default VP8 — every build has it).
    #[serde(default = "vp8")]
    pub format: VideoFormat,
    /// Format to switch to if `format` fails (default VP8; `None` = never switch).
    #[serde(default = "some_vp8")]
    pub fallback: Option<VideoFormat>,
}

fn vp8() -> VideoFormat {
    VideoFormat::Vp8
}
fn some_vp8() -> Option<VideoFormat> {
    Some(VideoFormat::Vp8)
}

impl Default for EncoderConfig {
    fn default() -> Self {
        Self {
            fps: 30,
            bitrate_kbps: 4000,
            content: ContentHint::Auto,
            threads: 0,
            keyframe_interval_s: 2,
            format: VideoFormat::Vp8,
            fallback: Some(VideoFormat::Vp8),
        }
    }
}

/// A backend that errors this many times in a row is dropped for the next one.
const MAX_BACKEND_ERRORS: u32 = 3;
/// After no backend could be opened for a size, wait this long before retrying.
const REOPEN_DELAY: Duration = Duration::from_secs(1);

struct ActiveEnc {
    kind: CodecKind,
    format: VideoFormat,
    dims: (usize, usize),
    b: Box<dyn EncBackend>,
    frames: u64,
    /// consecutive calls without output (a stalled hardware encoder)
    empty: u32,
}

/// An OS/hardware encoder that produces nothing for this many frames in a row
/// (~1.5 s at 30 fps) is treated as broken → fallback format.
const MAX_EMPTY_FRAMES: u32 = 45;

/// Video encoder. Accepts frames of any size; the stream is re-initialised
/// (with a keyframe) when the size changes. Odd dimensions are cropped by one
/// pixel; frames larger than 3840x2160 are downscaled 2:1.
pub struct VideoEncoder {
    active: Option<ActiveEnc>,
    /// pre-initialised fallback encoder (warm standby while H.264 runs)
    standby: Option<ActiveEnc>,
    want: VideoFormat,
    fps: u32,
    bitrate_kbps: u32,
    cfg: EncoderConfig,
    yuv: I420Buf,
    scratch: Vec<u8>,
    params: ParamSets,
    /// (format, backend) pairs that failed at run time in this encoder
    failed: Vec<(VideoFormat, CodecKind)>,
    errors: u32,
    retry_at: Option<((usize, usize), VideoFormat, Instant)>,
}

impl VideoEncoder {
    /// Create a VP8 encoder (see [`VideoEncoder::with_config`] for other
    /// formats). `w`/`h` are the expected dimensions (validated only — the
    /// real size is taken from each frame).
    pub fn new(w: u32, h: u32, fps: u32, bitrate_kbps: u32) -> anyhow::Result<Self> {
        if w == 0 || h == 0 {
            anyhow::bail!("invalid encoder size {w}x{h}");
        }
        Self::with_config(EncoderConfig { fps, bitrate_kbps, ..Default::default() })
    }

    /// Create an encoder with explicit settings. Never opens a codec yet
    /// (that happens on the first frame, when the size is known).
    pub fn with_config(cfg: EncoderConfig) -> anyhow::Result<Self> {
        if codec::candidates(cfg.format).is_empty() && cfg.fallback.is_none_or(|f| codec::candidates(f).is_empty()) {
            anyhow::bail!("no {} encoder on this device", cfg.format.name());
        }
        Ok(Self {
            active: None,
            standby: None,
            want: cfg.format,
            fps: cfg.fps.clamp(1, 240),
            bitrate_kbps: cfg.bitrate_kbps.clamp(50, 200_000),
            cfg,
            yuv: I420Buf::default(),
            scratch: Vec::new(),
            params: ParamSets::default(),
            failed: Vec::new(),
            errors: 0,
            retry_at: None,
        })
    }

    /// Format and backend producing frames right now (`None` before the first frame).
    pub fn backend(&self) -> Option<(VideoFormat, CodecKind)> {
        self.active.as_ref().map(|a| (a.format, a.kind))
    }

    /// Switch to another format from the next frame on (keyframe). Used when
    /// the negotiated format changes (e.g. someone joins a group call).
    pub fn set_format(&mut self, f: VideoFormat) {
        if f != self.want {
            self.want = f;
            self.failed.retain(|(ff, _)| *ff != f);
        }
    }

    /// The format asked for (the one in use may be the fallback).
    pub fn format(&self) -> VideoFormat {
        self.want
    }

    /// Change the target bitrate on the fly (no keyframe).
    pub fn set_bitrate(&mut self, kbps: u32) {
        let kbps = kbps.clamp(50, 200_000);
        if kbps == self.bitrate_kbps {
            return;
        }
        self.bitrate_kbps = kbps;
        for a in [self.active.as_mut(), self.standby.as_mut()].into_iter().flatten() {
            a.b.set_bitrate(kbps);
        }
    }

    pub fn bitrate_kbps(&self) -> u32 {
        self.bitrate_kbps
    }

    /// Encode one frame. Returns `Ok(None)` when the rate controller decided
    /// to skip the frame.
    pub fn encode(&mut self, f: &Frame, force_keyframe: bool) -> anyhow::Result<Option<EncodedFrame>> {
        self.encode_with(f, force_keyframe, |_| {})
    }

    /// Like [`VideoEncoder::encode`], but lets `pre` modify the I420 picture
    /// (even dimensions, tightly packed planes) right before it is encoded —
    /// camera effects ([`crate::video_fx`]) and the local self-view preview hook
    /// in here, on the encoder thread, with no extra colour conversion.
    pub fn encode_with(&mut self, f: &Frame, force_keyframe: bool, pre: impl FnOnce(&mut I420Buf)) -> anyhow::Result<Option<EncodedFrame>> {
        f.validate().context("invalid input frame")?;
        let (mut w, mut h) = (f.width as usize, f.height as usize);
        let (mut src, mut stride): (&[u8], usize) = (&f.data, f.stride as usize);

        if f.format == PixelFormat::I420 {
            // Camera frames from the app (already upright, see `camera_in`): copy
            // the planes, cropping to even dimensions. No colour conversion.
            if w.max(h) > MAX_LONG || w.min(h) > MAX_SHORT {
                anyhow::bail!("I420 frame too large: {w}x{h}");
            }
            let (ew, eh) = (w & !1, h & !1);
            if ew < 16 || eh < 16 {
                anyhow::bail!("frame too small to encode: {w}x{h} (minimum 16x16)");
            }
            let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
            let (ecw, ech) = (ew / 2, eh / 2);
            self.yuv.resize(ew, eh);
            let (ys, rest) = f.data.split_at(w * h);
            let (us, vs) = rest.split_at(cw * ch);
            for r in 0..eh {
                self.yuv.y[r * ew..(r + 1) * ew].copy_from_slice(&ys[r * w..r * w + ew]);
            }
            for r in 0..ech {
                self.yuv.u[r * ecw..(r + 1) * ecw].copy_from_slice(&us[r * cw..r * cw + ecw]);
                self.yuv.v[r * ecw..(r + 1) * ecw].copy_from_slice(&vs[r * cw..r * cw + ecw]);
            }
            return self.encode_i420(ew, eh, f.ts_us, force_keyframe, pre);
        }

        // Downscale 2:1 while above the codec limit.
        while w.max(h) > MAX_LONG || w.min(h) > MAX_SHORT {
            let (nw, nh) = (w / 2, h / 2);
            let mut out = vec![0u8; nw * nh * 4];
            downscale2x(src, stride, nw, nh, &mut out);
            self.scratch = out;
            src = &self.scratch;
            stride = nw * 4;
            w = nw;
            h = nh;
        }
        // H.264 4:2:0 needs even dimensions.
        let (ew, eh) = (w & !1, h & !1);
        if ew < 16 || eh < 16 {
            anyhow::bail!("frame too small to encode: {w}x{h} (minimum 16x16)");
        }
        rgb32_to_i420(src, stride, f.format, ew, eh, &mut self.yuv)?;
        self.encode_i420(ew, eh, f.ts_us, force_keyframe, pre)
    }

    fn params_for(&self, w: usize, h: usize) -> EncParams {
        EncParams {
            w,
            h,
            fps: self.fps,
            bitrate_kbps: self.bitrate_kbps,
            content: self.cfg.content,
            threads: self.cfg.threads,
            keyframe_interval_s: self.cfg.keyframe_interval_s,
        }
    }

    fn open(&mut self, format: VideoFormat, dims: (usize, usize)) -> anyhow::Result<ActiveEnc> {
        let p = self.params_for(dims.0, dims.1);
        let skip: Vec<CodecKind> = self.failed.iter().filter(|(f, _)| *f == format).map(|(_, k)| *k).collect();
        let (kind, b) = codec::open_first(&codec::candidates(format), &skip, |k| codec::open_encoder(k, format, &p))?;
        tracing::debug!("video encoder: {} {} ({}x{}, hw={})", format.name(), kind.label(), dims.0, dims.1, b.hardware());
        Ok(ActiveEnc { kind, format, dims, b, frames: 0, empty: 0 })
    }

    /// Format to use now: the wanted one unless all its backends failed here.
    fn current_format(&self) -> VideoFormat {
        let cands = codec::candidates(self.want);
        let usable = cands.iter().any(|k| !self.failed.contains(&(self.want, *k)));
        match (usable, self.cfg.fallback) {
            (false, Some(f)) => f,
            _ => self.want,
        }
    }

    /// Run `pre` on `self.yuv` (`ew`x`eh`, even) and encode it.
    fn encode_i420(&mut self, ew: usize, eh: usize, ts_us: u64, force_keyframe: bool, pre: impl FnOnce(&mut I420Buf)) -> anyhow::Result<Option<EncodedFrame>> {
        pre(&mut self.yuv);
        let mut force = force_keyframe;
        // at most one switch per frame: primary fails → fallback encodes this frame
        for _attempt in 0..2 {
            let format = self.current_format();
            let dims = (ew, eh);
            let fresh = !matches!(&self.active, Some(a) if a.format == format && a.dims == dims);
            if fresh {
                if let Some((d, f, at)) = self.retry_at {
                    if d == dims && f == format && Instant::now() < at {
                        anyhow::bail!("no {} encoder available (waiting before retrying)", format.name());
                    }
                }
                // a warm standby of the right format/size takes over instantly
                let warm = self.standby.take().filter(|s| s.format == format && s.dims == dims);
                let a = match warm {
                    Some(a) => a,
                    None => match self.open(format, dims) {
                        Ok(a) => a,
                        Err(e) => {
                            self.retry_at = Some((dims, format, Instant::now() + REOPEN_DELAY));
                            if format != self.cfg.fallback.unwrap_or(format) {
                                self.failed.extend(codec::candidates(format).into_iter().map(|k| (format, k)));
                                continue;
                            }
                            return Err(e);
                        }
                    },
                };
                codec::note_active(true, a.format, a.kind, a.b.hardware());
                self.active = Some(a);
                self.retry_at = None;
                self.errors = 0;
                force = true;
                // keep the fallback warm while a hardware/OS codec runs
                if let Some(fb) = self.cfg.fallback.filter(|f| *f != format) {
                    if self.standby.as_ref().is_none_or(|s| s.format != fb || s.dims != dims) {
                        self.standby = self.open(fb, dims).ok();
                    }
                } else {
                    self.standby = None;
                }
            }
            let Some(a) = self.active.as_mut() else { anyhow::bail!("no encoder") };
            let forced_fail = a.format == VideoFormat::H264 && a.frames >= 3 && codec::forced_os_failure();
            let mut res = if forced_fail { Err(anyhow::anyhow!("forced H.264 failure (test)")) } else { a.b.encode(&mut self.yuv, ts_us, force) };
            if let Ok(out) = &res {
                a.empty = if out.is_some() { 0 } else { a.empty + 1 };
                if a.empty >= MAX_EMPTY_FRAMES && a.kind.is_os() {
                    res = Err(anyhow::anyhow!("{} produced no output for {} frames", a.kind.label(), a.empty));
                }
            }
            match res {
                Ok(out) => {
                    a.frames += 1;
                    self.errors = 0;
                    let Some((data, keyframe)) = out else { return Ok(None) };
                    let format = a.format;
                    let data = if keyframe && format == VideoFormat::H264 { self.params.complete_keyframe(data) } else { data };
                    return Ok(Some(EncodedFrame { data: Bytes::from(data), keyframe, w: ew as u32, h: eh as u32, codec: format }));
                }
                Err(e) => {
                    self.errors += 1;
                    let (fmt, kind) = (a.format, a.kind);
                    let switch = self.cfg.fallback.is_some_and(|f| f != fmt);
                    if self.errors >= MAX_BACKEND_ERRORS || (switch && fmt == VideoFormat::H264) {
                        tracing::warn!("video encoder {} {} failed, switching: {e:#}", fmt.name(), kind.label());
                        self.failed.push((fmt, kind));
                        if switch {
                            // no sequential retries through other H.264 backends: the
                            // warm fallback takes this very frame
                            self.failed.extend(codec::candidates(fmt).into_iter().map(|k| (fmt, k)));
                        }
                        self.active = None;
                        self.errors = 0;
                        if switch {
                            force = true;
                            continue; // encode this very frame with the fallback
                        }
                    }
                    return Err(e);
                }
            }
        }
        anyhow::bail!("no encoder could encode this frame")
    }
}

/// Box-filter 2:1 downscale of a 32-bit image (channel order preserved).
fn downscale2x(src: &[u8], stride: usize, nw: usize, nh: usize, out: &mut [u8]) {
    for y in 0..nh {
        let r0 = &src[(2 * y) * stride..];
        let r1 = &src[(2 * y + 1) * stride..];
        for x in 0..nw {
            for c in 0..4 {
                let s = r0[8 * x + c] as u16 + r0[8 * x + 4 + c] as u16 + r1[8 * x + c] as u16 + r1[8 * x + 4 + c] as u16;
                out[(y * nw + x) * 4 + c] = ((s + 2) >> 2) as u8;
            }
        }
    }
}

/// Is `data` a keyframe of `format`? (Decoders wait for one after a switch.)
pub fn is_keyframe(format: VideoFormat, data: &[u8]) -> bool {
    match format {
        VideoFormat::H264 => has_idr(data),
        // VP8 frame tag: bit 0 = 0 for key frames (RFC 6386 §9.1)
        VideoFormat::Vp8 => data.len() >= 10 && data[0] & 1 == 0 && data[3..6] == [0x9d, 0x01, 0x2a],
        VideoFormat::Vp9 => vp9_keyframe(data),
    }
}

fn vp9_keyframe(d: &[u8]) -> bool {
    // uncompressed header: frame_marker(2) profile_low(1) profile_high(1) [reserved(1) if profile 3]
    // show_existing_frame(1) frame_type(1: 0 = key)
    let bit = |i: usize| d.get(i / 8).map(|b| (b >> (7 - i % 8)) & 1).unwrap_or(1);
    if d.is_empty() || (d[0] >> 6) != 2 {
        return false;
    }
    let profile = bit(2) | (bit(3) << 1);
    let mut i = 4 + usize::from(profile == 3);
    if bit(i) == 1 {
        return false; // show_existing_frame
    }
    i += 1;
    bit(i) == 0
}

/// Guess the format of a frame without a header (H.264 Annex-B starts with a
/// start code; otherwise VP8). Prefer [`VideoDecoder::decode_as`].
pub fn sniff_format(data: &[u8]) -> VideoFormat {
    if data.starts_with(&[0, 0, 0, 1]) || data.starts_with(&[0, 0, 1]) {
        VideoFormat::H264
    } else {
        VideoFormat::Vp8
    }
}

struct ActiveDec {
    kind: CodecKind,
    b: Box<dyn DecBackend>,
    key_errors: u32,
    need_key: bool,
}

/// Video decoder producing RGBA frames. Creating it never fails; decoders
/// are opened per format on first use, so a sender can switch formats on any
/// keyframe.
pub struct VideoDecoder {
    active: [Option<ActiveDec>; 3],
    failed: Vec<(VideoFormat, CodecKind)>,
    retry_at: [Option<Instant>; 3],
    last: Option<VideoFormat>,
    rgba: Vec<u8>,
    planar: I420Buf,
    /// who sends this stream (see [`VideoDecoder::set_source`])
    source: u64,
}

impl VideoDecoder {
    pub fn new() -> anyhow::Result<Self> {
        Ok(Self { active: [None, None, None], failed: Vec::new(), retry_at: [None; 3], last: None, rgba: Vec::new(), planar: I420Buf::default(), source: 0 })
    }

    /// Identify the sender of this stream (any stable id, e.g. derived from the
    /// peer id). A sender whose keyframes break the OS H.264 decoder only stops
    /// H.264 towards *that* sender ([`codec::local_caps_for`]); the device-wide
    /// caps drop H.264 only when streams from two different senders failed, so
    /// one peer can't switch this device's hardware decoder off for everyone.
    pub fn set_source(&mut self, source: u64) {
        self.source = source;
    }

    /// Format/backend of the last decoded frame.
    pub fn backend(&self) -> Option<(VideoFormat, CodecKind)> {
        let f = self.last?;
        self.active[f as usize].as_ref().map(|a| (f, a.kind))
    }

    /// Is the last decoded frame's decoder hardware-accelerated?
    pub fn is_hardware(&self) -> bool {
        self.last.and_then(|f| self.active[f as usize].as_ref()).is_some_and(|a| a.b.hardware())
    }

    /// Decode a frame whose format is guessed (H.264 Annex-B or VP8).
    pub fn decode(&mut self, data: &[u8]) -> anyhow::Result<Option<Frame>> {
        self.decode_as(sniff_format(data), data)
    }

    /// Decode one frame of `format`. Returns `Ok(None)` if the decoder needs
    /// more data. After a decoder (re)start, non-key frames return an error so
    /// the caller asks the sender for a keyframe.
    pub fn decode_as(&mut self, format: VideoFormat, data: &[u8]) -> anyhow::Result<Option<Frame>> {
        if data.is_empty() {
            return Ok(None);
        }
        let key = is_keyframe(format, data);
        // Peer data: reject oversized pictures before any decoder allocates for them
        // (VP8/VP9 frame header, H.264 SPS). Not a decoder failure: nothing is counted.
        match format {
            VideoFormat::H264 => codec::check_h264_au(data)?,
            _ => {
                if let Some((w, h)) = codec::vpx_frame_dims(format, data) {
                    codec::check_decode_dims(w, h)?;
                }
            }
        }
        let slot = format as usize;
        if self.active[slot].is_none() {
            if self.retry_at[slot].is_some_and(|t| Instant::now() < t) {
                anyhow::bail!("no {} decoder", format.name());
            }
            let skip: Vec<CodecKind> = self.failed.iter().filter(|(f, _)| *f == format).map(|(_, k)| *k).collect();
            match codec::open_first(&codec::candidates(format), &skip, |k| codec::open_decoder(k, format)) {
                Ok((kind, b)) => {
                    tracing::debug!("video decoder: {} {} (hw={})", format.name(), kind.label(), b.hardware());
                    self.active[slot] = Some(ActiveDec { kind, b, key_errors: 0, need_key: true });
                    self.retry_at[slot] = None;
                }
                Err(e) => {
                    self.retry_at[slot] = Some(Instant::now() + REOPEN_DELAY);
                    return Err(e.context(format!("no {} decoder", format.name())));
                }
            }
        }
        let Some(a) = self.active[slot].as_mut() else { return Ok(None) };
        if a.need_key {
            if !key {
                anyhow::bail!("waiting for a keyframe");
            }
            a.need_key = false;
        }
        let view = match a.b.decode(data) {
            Ok(Some(v)) => {
                a.key_errors = 0;
                v
            }
            Ok(None) => return Ok(None),
            Err(e) => {
                if key {
                    a.key_errors += 1;
                    if a.key_errors >= MAX_BACKEND_ERRORS {
                        tracing::warn!("video decoder {} {} cannot decode keyframes, switching: {e:#}", format.name(), a.kind.label());
                        if format == VideoFormat::H264 && a.kind.is_os() {
                            codec::note_h264_failure(self.source);
                        }
                        self.failed.push((format, a.kind));
                        self.active[slot] = None;
                    }
                }
                return Err(e);
            }
        };
        let (w, h) = (view.w, view.h);
        if w == 0 || h == 0 {
            anyhow::bail!("decoder returned an empty picture");
        }
        codec::check_decode_dims(w, h)?;
        if view.uv_step == 1 {
            let img = I420 { width: w, height: h, y: view.y, u: view.u, v: view.v, y_stride: view.y_stride, uv_stride: view.uv_stride };
            i420_to_rgba(&img, &mut self.rgba)?;
        } else {
            // interleaved chroma (NV12): split into planes first
            let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
            let step = view.uv_step;
            let need = view.uv_stride * (ch - 1) + (cw - 1) * step + 1;
            if view.u.len() < need || view.v.len() < need {
                anyhow::bail!("decoder chroma plane too small for {w}x{h}");
            }
            self.planar.resize(w, h);
            for r in 0..ch {
                let urow = &view.u[r * view.uv_stride..];
                let vrow = &view.v[r * view.uv_stride..];
                for c in 0..cw {
                    self.planar.u[r * cw + c] = urow[c * step];
                    self.planar.v[r * cw + c] = vrow[c * step];
                }
            }
            let img = I420 { width: w, height: h, y: view.y, u: &self.planar.u, v: &self.planar.v, y_stride: view.y_stride, uv_stride: cw };
            i420_to_rgba(&img, &mut self.rgba)?;
        }
        let (kind, hw) = (a.kind, a.b.hardware());
        if self.last != Some(format) {
            self.last = Some(format);
            codec::note_active(false, format, kind, hw);
        }
        Ok(Some(Frame {
            width: w as u32,
            height: h as u32,
            stride: (w * 4) as u32,
            format: PixelFormat::Rgba,
            data: Bytes::copy_from_slice(&self.rgba),
            ts_us: crate::now_us(),
        }))
    }
}

// ------------------------------------------------------------------ receive order

/// Receiver-side guard for one sender's video stream. Frames travel on separate
/// QUIC streams, so they can arrive out of order, and the network or a full
/// decoder queue can lose some. VP8/VP9/H.264 decoders mostly don't notice a
/// missing reference frame: they keep decoding into garbage. With the sender's
/// frame sequence number (media header, see lumora-core `media_pipe`):
///
/// * frames older than the last decoded one are dropped;
/// * a frame that skips ahead is held briefly ([`FrameSync::HOLD`], at most
///   [`FrameSync::MAX_HELD`]) for the missing one;
/// * a real gap (or [`FrameSync::lost`]) drops every delta frame until the next
///   keyframe, and [`FrameSync::want_keyframe`] says when to ask the sender for
///   one (rate-limited).
///
/// Senders without sequence numbers (`seq: None`, older builds) get arrival
/// order, but still resync on a keyframe after [`FrameSync::lost`].
pub struct FrameSync<T> {
    last: Option<u32>,
    need_key: bool,
    held: Vec<(u32, T)>,
    held_since: Option<Instant>,
    last_request: Option<Instant>,
    requests: u32,
}

impl<T> Default for FrameSync<T> {
    fn default() -> Self {
        Self { last: None, need_key: true, held: Vec::new(), held_since: None, last_request: None, requests: 0 }
    }
}

/// `a` is after `b` in wrapping sequence order.
fn seq_after(a: u32, b: u32) -> bool {
    (a.wrapping_sub(b) as i32) > 0
}

impl<T> FrameSync<T> {
    /// How long a frame that skipped ahead waits for the missing one.
    pub const HOLD: Duration = Duration::from_millis(60);
    /// At most this many frames are held.
    pub const MAX_HELD: usize = 4;
    /// Minimum time between two keyframe requests; while still waiting, the
    /// request is repeated every [`FrameSync::REQUEST_REPEAT`].
    pub const REQUEST_EVERY: Duration = Duration::from_millis(300);
    pub const REQUEST_REPEAT: Duration = Duration::from_millis(1000);

    pub fn new() -> Self {
        Self::default()
    }

    /// Waiting for a keyframe (start, gap, loss or decode error)?
    pub fn needs_keyframe(&self) -> bool {
        self.need_key
    }

    /// A frame could not be used (dropped before reaching us, or the decoder
    /// failed on it): wait for the next keyframe.
    pub fn lost(&mut self) {
        self.need_key = true;
        self.held.clear();
        self.held_since = None;
    }

    /// One frame arrived; returns the frames to decode now, in order.
    pub fn push(&mut self, seq: Option<u32>, key: bool, item: T, now: Instant) -> Vec<T> {
        let mut out = Vec::new();
        let Some(s) = seq else {
            // older sender: arrival order, keyframe resync after a loss
            if key {
                self.need_key = false;
            }
            if !self.need_key {
                out.push(item);
            }
            return out;
        };
        if let Some(l) = self.last {
            if !seq_after(s, l) {
                return out; // stale or duplicate
            }
        }
        if key {
            // a keyframe supersedes everything before it
            self.held.retain(|(h, _)| seq_after(*h, s));
            self.need_key = false;
            self.last = Some(s);
            self.requests = 0;
            out.push(item);
            self.flush(&mut out);
            return out;
        }
        if self.need_key {
            return out; // undecodable until the next keyframe
        }
        let next = self.last.map(|l| l.wrapping_add(1));
        if next == Some(s) {
            self.last = Some(s);
            out.push(item);
            self.flush(&mut out);
            return out;
        }
        // skipped ahead: hold it for the missing frame(s)
        if !self.held.iter().any(|(h, _)| *h == s) {
            let at = self.held.iter().position(|(h, _)| seq_after(*h, s)).unwrap_or(self.held.len());
            self.held.insert(at, (s, item));
        }
        self.held_since.get_or_insert(now);
        if self.held.len() > Self::MAX_HELD {
            self.lost();
        }
        out
    }

    /// Release held frames that became consecutive.
    fn flush(&mut self, out: &mut Vec<T>) {
        while let (Some(l), Some((h, _))) = (self.last, self.held.first()) {
            if *h != l.wrapping_add(1) {
                break;
            }
            let (h, item) = self.held.remove(0);
            self.last = Some(h);
            out.push(item);
        }
        if self.held.is_empty() {
            self.held_since = None;
        }
    }

    /// Call when [`FrameSync::deadline`] passes: a missing frame that didn't come
    /// in time is lost.
    pub fn poll(&mut self, now: Instant) {
        if self.held_since.is_some_and(|t| now.duration_since(t) >= Self::HOLD) {
            self.lost();
        }
    }

    /// When [`FrameSync::poll`] should run next.
    pub fn deadline(&self) -> Option<Instant> {
        self.held_since.map(|t| t + Self::HOLD)
    }

    /// Should the receiver ask the sender for a keyframe now? Rate-limited: at most
    /// every [`FrameSync::REQUEST_EVERY`], repeated every
    /// [`FrameSync::REQUEST_REPEAT`] while still waiting (a request can be lost).
    pub fn want_keyframe(&mut self, now: Instant) -> bool {
        if !self.need_key {
            return false;
        }
        let gap = if self.requests == 0 { Self::REQUEST_EVERY } else { Self::REQUEST_REPEAT };
        if self.last_request.is_some_and(|t| now.duration_since(t) < gap) {
            return false;
        }
        self.last_request = Some(now);
        self.requests = self.requests.saturating_add(1);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color::psnr_rgb;

    fn synthetic(w: u32, h: u32, t: u32) -> Frame {
        let mut d = vec![0u8; (w * h * 4) as usize];
        for y in 0..h {
            for x in 0..w {
                let i = ((y * w + x) * 4) as usize;
                // BGRA: smooth gradients + a moving block (screen-like content).
                let block = (x / 32 + y / 32 + t).is_multiple_of(7);
                d[i] = (x * 255 / w) as u8;
                d[i + 1] = (y * 255 / h) as u8;
                d[i + 2] = if block { 240 } else { 60 };
                d[i + 3] = 255;
            }
        }
        Frame { width: w, height: h, stride: w * 4, format: PixelFormat::Bgra, data: d.into(), ts_us: t as u64 * 33_333 }
    }

    fn to_rgba(f: &Frame) -> Vec<u8> {
        let mut v = f.data.to_vec();
        if f.format == PixelFormat::Bgra {
            crate::color::swap_rb_inplace(&mut v);
        }
        v
    }

    #[test]
    fn roundtrip_psnr() {
        let (w, h) = (320, 240);
        let mut enc = VideoEncoder::new(w, h, 30, 2000).unwrap();
        let mut dec = VideoDecoder::new().unwrap();
        let mut last = None;
        let mut first_key = false;
        for t in 0..10 {
            let f = synthetic(w, h, t);
            if let Some(e) = enc.encode(&f, t == 0).unwrap() {
                if t == 0 {
                    first_key = e.keyframe;
                }
                assert_eq!((e.w, e.h), (w, h));
                if let Some(out) = dec.decode(&e.data).unwrap() {
                    last = Some((f, out));
                }
            }
        }
        assert!(first_key, "first frame must be a keyframe");
        let (src, out) = last.expect("decoder produced no frame");
        assert_eq!((out.width, out.height), (w, h));
        let p = psnr_rgb(&to_rgba(&src), &out.data);
        assert!(p > 30.0, "PSNR too low: {p:.1} dB");
    }

    #[test]
    fn odd_size_and_resize_and_bitrate() {
        let mut enc = VideoEncoder::new(101, 77, 30, 500).unwrap();
        let mut dec = VideoDecoder::new().unwrap();
        let e = enc.encode(&synthetic(101, 77, 0), true).unwrap().unwrap();
        assert_eq!((e.w, e.h), (100, 76));
        assert!(dec.decode(&e.data).unwrap().is_some());
        enc.set_bitrate(1500);
        assert_eq!(enc.bitrate_kbps(), 1500);
        // Size change -> new IDR.
        let e = enc.encode(&synthetic(160, 120, 1), false).unwrap().unwrap();
        assert!(e.keyframe);
        let out = dec.decode(&e.data).unwrap().unwrap();
        assert_eq!((out.width, out.height), (160, 120));
    }

    #[test]
    fn i420_camera_frames_encode_without_conversion() {
        // Camera picture → upright I420 (camera_in) → encoder → decoder.
        let (w, h) = (96, 64);
        let y: Vec<u8> = (0..w * h).map(|i| ((i % w) * 2) as u8).collect();
        let uv = vec![128u8; w * h / 2];
        let p = crate::camera_in::YuvPlanes { width: w, height: h, y: &y, y_stride: w, u: &uv, u_stride: w, v: &uv[1..], v_stride: w, uv_step: 2 };
        let f = crate::camera_in::yuv420_to_frame(&p, 90, false, 0, 0).unwrap();
        let mut enc = VideoEncoder::new(64, 96, 30, 800).unwrap();
        let mut seen = None;
        let e = enc.encode_with(&f, true, |yuv| seen = Some((yuv.width, yuv.height, yuv.y[0]))).unwrap().unwrap();
        assert_eq!((e.w, e.h), (64, 96));
        assert_eq!(seen, Some((64, 96, y[(h - 1) * w])));
        let out = VideoDecoder::new().unwrap().decode(&e.data).unwrap().unwrap();
        assert_eq!((out.width, out.height), (64, 96));
        let short = Frame { width: 64, height: 64, stride: 64, format: PixelFormat::I420, data: vec![0; 64 * 64].into(), ts_us: 0 };
        assert!(enc.encode(&short, false).is_err());
    }

    fn camera_like(w: u32, h: u32, t: u32) -> Frame {
        let mut d = vec![0u8; (w * h * 4) as usize];
        for (i, px) in d.chunks_exact_mut(4).enumerate() {
            let (x, y) = (i as u32 % w, i as u32 / w);
            px.copy_from_slice(&[((x + t * 3) % 256) as u8, ((y + t) % 256) as u8, ((x ^ y) % 256) as u8, 255]);
        }
        Frame { width: w, height: h, stride: w * 4, format: PixelFormat::Rgba, data: d.into(), ts_us: t as u64 * 33_333 }
    }

    #[test]
    fn vp8_vp9_and_switching_formats_mid_stream() {
        let (w, h) = (320, 240);
        let mut enc = VideoEncoder::with_config(EncoderConfig { bitrate_kbps: 1500, ..Default::default() }).unwrap();
        let mut dec = VideoDecoder::new().unwrap();
        let mut seen = Vec::new();
        for t in 0..20 {
            if t == 10 {
                enc.set_format(VideoFormat::Vp9);
            }
            let f = synthetic(w, h, t);
            if let Some(e) = enc.encode(&f, t == 0).unwrap() {
                if t == 0 || t == 10 {
                    assert!(e.keyframe, "frame {t} must be a keyframe ({:?})", e.codec);
                    assert!(is_keyframe(e.codec, &e.data));
                }
                let out = dec.decode_as(e.codec, &e.data).unwrap().expect("libvpx decodes every frame");
                assert_eq!((out.width, out.height), (w, h));
                if t == 19 {
                    let p = psnr_rgb(&to_rgba(&f), &out.data);
                    assert!(p > 30.0, "VP9 PSNR too low: {p:.1} dB");
                }
                seen.push(e.codec);
            }
        }
        assert_eq!(seen.first(), Some(&VideoFormat::Vp8));
        assert_eq!(seen.last(), Some(&VideoFormat::Vp9));
        assert_eq!(enc.backend(), Some((VideoFormat::Vp9, CodecKind::Libvpx)));
        assert!(!is_keyframe(VideoFormat::Vp8, &[1, 0, 0]));
        // garbage in another format must not panic
        let _ = dec.decode_as(VideoFormat::Vp9, &[0x82, 0x49, 0x83, 0x42, 0x00]);
        let _ = dec.decode_as(VideoFormat::Vp8, &[0x00, 0x00, 0x00, 0x9d, 0x01, 0x2a, 0xff, 0xff, 0xff, 0xff]);
    }

    /// Encoder creation → first decoded picture, the codec part of "answer → first
    /// frame" (target < 1 s overall; bound loose for CI).
    #[test]
    fn first_frame_is_fast() {
        let format = if codec::local_caps().hw_enc.contains(&VideoFormat::H264) { VideoFormat::H264 } else { VideoFormat::Vp8 };
        let t0 = Instant::now();
        let mut enc = VideoEncoder::with_config(EncoderConfig { format, bitrate_kbps: 1200, ..Default::default() }).unwrap();
        let mut dec = VideoDecoder::new().unwrap();
        let mut ms = None;
        for t in 0..30 {
            if let Some(e) = enc.encode(&camera_like(640, 480, t), t == 0).unwrap() {
                if let Ok(Some(_)) = dec.decode_as(e.codec, &e.data) {
                    ms = Some(t0.elapsed().as_millis());
                    break;
                }
            }
        }
        let ms = ms.expect("no frame decoded");
        eprintln!("{} first frame after {ms} ms", format.name());
        assert!(ms < 1500, "first frame took {ms} ms");
    }

    /// Hardware/OS H.264 fails mid-stream → the warm VP8 encoder encodes that very
    /// frame as a keyframe (no gap). Needs an H.264 encoder (OS or dev build).
    #[test]
    fn h264_failure_switches_to_vp8_on_the_same_frame() {
        if codec::candidates(VideoFormat::H264).is_empty() {
            eprintln!("skipped: no H.264 encoder on this device/build");
            return;
        }
        let mut enc = VideoEncoder::with_config(EncoderConfig { format: VideoFormat::H264, bitrate_kbps: 1200, ..Default::default() }).unwrap();
        let mut dec = VideoDecoder::new().unwrap();
        let mut formats = Vec::new();
        let mut switch_ms = 0u128;
        for t in 0..12 {
            if t == 5 {
                codec::FORCE_FAIL_HERE.with(|c| c.set(true));
            }
            let t1 = Instant::now();
            let e = enc.encode(&camera_like(320, 240, t), t == 0).unwrap();
            if t == 5 {
                switch_ms = t1.elapsed().as_millis();
            }
            if let Some(e) = e {
                if t == 0 && e.codec != VideoFormat::H264 {
                    eprintln!("skipped: no working H.264 encoder here (got {})", e.codec.name());
                    return;
                }
                if formats.last() == Some(&VideoFormat::H264) && e.codec == VideoFormat::Vp8 {
                    assert!(e.keyframe, "the first VP8 frame after a switch is a keyframe");
                    assert!(dec.decode_as(e.codec, &e.data).unwrap().is_some(), "decodable right away");
                }
                formats.push(e.codec);
            }
        }
        codec::FORCE_FAIL_HERE.with(|c| c.set(false));
        let first_vp8 = formats.iter().position(|f| *f == VideoFormat::Vp8).expect("switched to VP8");
        assert!(formats[..first_vp8].iter().all(|f| *f == VideoFormat::H264), "{formats:?}");
        assert!(first_vp8 >= 3, "{formats:?}");
        eprintln!("switch frame encoded in {switch_ms} ms (warm VP8 standby)");
        assert!(switch_ms < 200, "switch took {switch_ms} ms");
        assert_eq!(enc.backend().map(|b| b.0), Some(VideoFormat::Vp8));
    }

    fn moving_blocks(w: u32, h: u32, t: u32) -> Frame {
        let mut d = vec![0u8; (w * h * 4) as usize];
        for (i, px) in d.chunks_exact_mut(4).enumerate() {
            let (x, y) = (i as u32 % w, i as u32 / w);
            let blk = ((x + t * 9) / 24 + y / 24).is_multiple_of(2);
            px.copy_from_slice(&[if blk { 230 } else { 20 }, (y % 256) as u8, (x % 256) as u8, 255]);
        }
        Frame { width: w, height: h, stride: w * 4, format: PixelFormat::Rgba, data: d.into(), ts_us: t as u64 * 33_333 }
    }

    /// Review regression (`dropped_vp8_delta_frame_is_not_detected`): libvpx decodes
    /// the frames after a missing delta frame without any error — into garbage. The
    /// sequence number makes the gap visible: the following deltas are not decoded,
    /// a keyframe is requested (rate-limited), and the picture after the keyframe is
    /// bit-identical to an intact decode.
    #[test]
    fn dropped_vp8_delta_frame_is_detected_and_resynced() {
        let (w, h) = (320u32, 240u32);
        let mut enc = VideoEncoder::with_config(EncoderConfig { fps: 30, bitrate_kbps: 1500, content: ContentHint::Motion, ..Default::default() }).unwrap();
        let mut dec = VideoDecoder::new().unwrap();
        let mut ref_dec = VideoDecoder::new().unwrap();
        let mut sync: FrameSync<EncodedFrame> = FrameSync::new();
        let now = Instant::now();
        let mut requests = Vec::new();
        let mut decoded_after_gap = Vec::new();
        let mut seq = 0u32;
        let mut force_key_at = None;
        for t in 0..30u32 {
            let force = t == 0 || force_key_at == Some(t);
            let Some(e) = enc.encode(&moving_blocks(w, h, t), force).unwrap() else { continue };
            let s = seq;
            seq += 1;
            let good = ref_dec.decode_as(VideoFormat::Vp8, &e.data).unwrap().unwrap();
            let at = now + Duration::from_millis(t as u64 * 33);
            if t == 5 {
                continue; // dropped on the way
            }
            for f in sync.push(Some(s), e.keyframe, e.clone(), at) {
                let out = dec.decode_as(VideoFormat::Vp8, &f.data).unwrap().unwrap();
                if t > 5 {
                    assert_eq!(out.data, good.data, "frame {t} must be intact (no decoding past a gap)");
                    decoded_after_gap.push((t, f.keyframe));
                }
            }
            if let Some(d) = sync.deadline() {
                sync.poll(d.max(at + Duration::from_millis(1)));
            }
            if sync.want_keyframe(at) {
                requests.push(t);
                force_key_at.get_or_insert(t + 3); // the request reaches the sender a bit later
            }
        }
        assert_eq!(requests.first(), Some(&6), "gap detected at the next frame: {requests:?}");
        assert!(requests.len() <= 2, "keyframe requests are rate-limited: {requests:?}");
        let first = decoded_after_gap.first().copied().expect("resynced");
        assert!(first.1, "the first frame decoded after the gap is the keyframe: {decoded_after_gap:?}");
        assert!(decoded_after_gap.len() >= 15, "{decoded_after_gap:?}");
    }

    #[test]
    fn frame_sync_orders_holds_and_times_out() {
        let t0 = Instant::now();
        let ms = |n: u64| t0 + Duration::from_millis(n);
        let mut s: FrameSync<u32> = FrameSync::new();
        // deltas before the first keyframe are useless
        assert!(s.push(Some(0), false, 0, ms(0)).is_empty());
        assert!(s.want_keyframe(ms(0)) && !s.want_keyframe(ms(100)));
        assert_eq!(s.push(Some(1), true, 1, ms(10)), vec![1]);
        // reordered: 3 before 2 → held, then both in order
        assert!(s.push(Some(3), false, 3, ms(20)).is_empty());
        assert_eq!(s.push(Some(2), false, 2, ms(25)), vec![2, 3]);
        // stale / duplicate frames are dropped
        assert!(s.push(Some(2), false, 2, ms(26)).is_empty());
        assert!(s.push(Some(1), true, 1, ms(26)).is_empty());
        // a gap that never fills → lost after HOLD, deltas skipped until a keyframe
        assert!(s.push(Some(5), false, 5, ms(30)).is_empty());
        assert_eq!(s.deadline(), Some(ms(30) + FrameSync::<u32>::HOLD));
        s.poll(ms(50));
        assert!(!s.needs_keyframe());
        s.poll(ms(95));
        assert!(s.needs_keyframe());
        assert!(s.push(Some(6), false, 6, ms(96)).is_empty());
        assert!(s.want_keyframe(ms(400)));
        assert!(!s.want_keyframe(ms(700)), "repeat only after REQUEST_REPEAT");
        assert!(s.want_keyframe(ms(1500)));
        assert_eq!(s.push(Some(9), true, 9, ms(1600)), vec![9]);
        assert!(!s.want_keyframe(ms(3000)));
        // a keyframe also ends a hold; too many held frames = loss
        for (i, n) in [11u32, 12, 13, 14, 15].iter().enumerate() {
            let _ = s.push(Some(*n), false, *n, ms(1700 + i as u64));
        }
        assert!(s.needs_keyframe());
        // wrapping sequence numbers
        let mut w: FrameSync<u32> = FrameSync::new();
        assert_eq!(w.push(Some(u32::MAX), true, 0, t0), vec![0]);
        assert_eq!(w.push(Some(0), false, 1, t0), vec![1]);
        assert!(w.push(Some(u32::MAX - 1), false, 2, t0).is_empty());
        // older senders without sequence numbers: arrival order, keyframe resync after a loss
        let mut o: FrameSync<u32> = FrameSync::new();
        assert!(o.push(None, false, 0, t0).is_empty());
        assert_eq!(o.push(None, true, 1, t0), vec![1]);
        assert_eq!(o.push(None, false, 2, t0), vec![2]);
        o.lost();
        assert!(o.push(None, false, 3, t0).is_empty());
        assert_eq!(o.push(None, true, 4, t0), vec![4]);
    }

    /// Review regression (`oversized_vp8_from_peer_is_decoded_without_cap`): a VP8
    /// keyframe announcing 6000x6000 (crafted header — a real one would take
    /// seconds to encode) is refused before libvpx allocates for it; VP8 and VP9
    /// keyframes from our own encoder pass, and their header sizes parse right.
    #[test]
    fn oversized_pictures_from_peers_are_refused_before_decoding() {
        let mut enc = VideoEncoder::with_config(EncoderConfig { bitrate_kbps: 800, ..Default::default() }).unwrap();
        let e = enc.encode(&synthetic(320, 240, 0), true).unwrap().unwrap();
        assert_eq!(codec::vpx_frame_dims(VideoFormat::Vp8, &e.data), Some((320, 240)));
        let mut big = e.data.to_vec();
        big[6..8].copy_from_slice(&6000u16.to_le_bytes());
        big[8..10].copy_from_slice(&6000u16.to_le_bytes());
        let mut dec = VideoDecoder::new().unwrap();
        let err = dec.decode_as(VideoFormat::Vp8, &big).unwrap_err();
        assert!(format!("{err:#}").contains("decode limit"), "{err:#}");
        // the decoder still works (nothing counted as a backend failure)
        assert!(dec.decode_as(VideoFormat::Vp8, &e.data).unwrap().is_some());
        // a landscape or portrait 4K picture is fine; 4097 or 2305 on the short side is not
        for (w, h, ok) in [(3840, 2160, true), (2160, 3840, true), (4096, 2304, true), (4097, 1000, false), (2305, 2305, false), (0, 10, false)] {
            assert_eq!(codec::decode_dims_ok(w, h), ok, "{w}x{h}");
        }
        let mut enc9 = VideoEncoder::with_config(EncoderConfig { format: VideoFormat::Vp9, bitrate_kbps: 800, ..Default::default() }).unwrap();
        let k = enc9.encode(&synthetic(320, 240, 0), true).unwrap().unwrap();
        assert_eq!(k.codec, VideoFormat::Vp9);
        assert_eq!(codec::vpx_frame_dims(VideoFormat::Vp9, &k.data), Some((320, 240)));
        // an H.264 SPS announcing 8192x8192 (512x512 macroblocks) is refused as well
        // (baseline SPS: profile 66, level 40, ids/log2 fields, 512 mbs each way)
        let mut bits = String::new();
        let ue = |b: &mut String, v: u32| {
            let n = 32 - (v + 1).leading_zeros();
            b.push_str(&"0".repeat(n as usize - 1));
            b.push_str(&format!("{:0w$b}", v + 1, w = n as usize));
        };
        bits += &format!("{:08b}{:08b}{:08b}", 66, 0, 40);
        ue(&mut bits, 0); // sps id
        ue(&mut bits, 0); // log2_max_frame_num - 4
        ue(&mut bits, 2); // poc type 2
        ue(&mut bits, 1); // max refs
        bits.push('0'); // gaps
        ue(&mut bits, 511); // width in mbs - 1
        ue(&mut bits, 511); // height in map units - 1
        bits += "1" ; // frame_mbs_only
        bits += "1"; // direct 8x8
        bits += "0"; // no cropping
        bits += "0"; // no VUI
        bits.push('1');
        while !bits.len().is_multiple_of(8) {
            bits.push('0');
        }
        let mut au = vec![0, 0, 0, 1, 0x67];
        au.extend(bits.as_bytes().chunks(8).map(|c| u8::from_str_radix(std::str::from_utf8(c).unwrap(), 2).unwrap()));
        let (sw, sh) = crate::codec::annexb::sps_dimensions(&au[4..]).expect("valid SPS");
        assert_eq!((sw, sh), (8192, 8192));
        let err = VideoDecoder::new().unwrap().decode_as(VideoFormat::H264, &au).unwrap_err();
        assert!(format!("{err:#}").contains("decode limit"), "{err:#}");
    }

    #[test]
    fn bad_input_is_error_not_panic() {
        let mut enc = VideoEncoder::new(64, 64, 30, 500).unwrap();
        let bad = Frame { width: 64, height: 64, stride: 256, format: PixelFormat::Rgba, data: vec![0; 100].into(), ts_us: 0 };
        assert!(enc.encode(&bad, false).is_err());
        let tiny = Frame { width: 4, height: 4, stride: 16, format: PixelFormat::Rgba, data: vec![0; 64].into(), ts_us: 0 };
        assert!(enc.encode(&tiny, false).is_err());
        let mut dec = VideoDecoder::new().unwrap();
        let _ = dec.decode(&[0, 0, 0, 1, 0x65, 1, 2, 3]); // garbage must not panic
        assert!(VideoEncoder::new(0, 0, 30, 100).is_err());
    }
}
