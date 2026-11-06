//! Android MediaCodec H.264 backend (NDK `libmediandk`, no Java/JNI needed).
//!
//! Encoder: `video/avc`, constrained baseline (falls back to baseline), CBR
//! (falls back to VBR), no B-frames, realtime priority / low latency, ByteBuffer
//! input in NV12 (falls back to I420) laid out exactly as the codec describes it
//! (`image-data` MediaImage2 → `stride`/`slice-height` → width/height).
//! Keyframes on request via `request-sync`, live bitrate via `video-bitrate`.
//! SPS/PPS from the codec-config buffer are prepended to every keyframe.
//!
//! Decoder: configured on the first keyframe from its SPS/PPS (`csd-0`/`csd-1`),
//! re-created at once when the picture size changes, and at most every
//! [`REBUILD_MIN_INTERVAL`] for other SPS changes (the in-band SPS/PPS reach the
//! codec anyway); low-latency mode, output read from ByteBuffers using the
//! layout of the output format. Peer streams above the decode size cap are
//! rejected before the codec is configured.
//!
//! Both run MediaCodec in synchronous mode: queue one access unit / picture,
//! then wait a few milliseconds for the output. The decoder never blocks for
//! long: a picture that is not ready yet is returned by a later call.
//!
//! The codec name tells hardware from software (`c2.android.*`,
//! `OMX.google.*` and `*.sw.*` are Google's software codecs, which ship with
//! Android and are covered by the platform licence too).

use std::collections::VecDeque;
use std::ffi::{c_char, c_void, CStr};
use std::ptr::null_mut;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use super::annexb::{nal_type, nals, sps_dimensions, ParamSets, NAL_IDR, NAL_PPS, NAL_SPS};
use super::{check_decode_dims, check_h264_au, decode_dims_ok, DecBackend, EncBackend, EncParams, YuvView};
use crate::color::I420Buf;

// ------------------------------------------------------------------ NDK FFI

#[repr(C)]
struct AMediaCodec {
    _p: [u8; 0],
}
#[repr(C)]
struct AMediaFormat {
    _p: [u8; 0],
}
#[repr(C)]
#[derive(Default)]
struct AMediaCodecBufferInfo {
    offset: i32,
    size: i32,
    presentation_time_us: i64,
    flags: u32,
}

type MediaStatus = i32;
const AMEDIA_OK: MediaStatus = 0;

#[link(name = "mediandk")]
extern "C" {
    fn AMediaCodec_createEncoderByType(mime: *const c_char) -> *mut AMediaCodec;
    fn AMediaCodec_createDecoderByType(mime: *const c_char) -> *mut AMediaCodec;
    fn AMediaCodec_configure(c: *mut AMediaCodec, f: *const AMediaFormat, surface: *mut c_void, crypto: *mut c_void, flags: u32) -> MediaStatus;
    fn AMediaCodec_start(c: *mut AMediaCodec) -> MediaStatus;
    fn AMediaCodec_stop(c: *mut AMediaCodec) -> MediaStatus;
    fn AMediaCodec_delete(c: *mut AMediaCodec) -> MediaStatus;
    fn AMediaCodec_dequeueInputBuffer(c: *mut AMediaCodec, timeout_us: i64) -> isize;
    fn AMediaCodec_getInputBuffer(c: *mut AMediaCodec, idx: usize, out_size: *mut usize) -> *mut u8;
    fn AMediaCodec_queueInputBuffer(c: *mut AMediaCodec, idx: usize, offset: libc::off_t, size: usize, time_us: u64, flags: u32) -> MediaStatus;
    fn AMediaCodec_dequeueOutputBuffer(c: *mut AMediaCodec, info: *mut AMediaCodecBufferInfo, timeout_us: i64) -> isize;
    fn AMediaCodec_getOutputBuffer(c: *mut AMediaCodec, idx: usize, out_size: *mut usize) -> *mut u8;
    fn AMediaCodec_releaseOutputBuffer(c: *mut AMediaCodec, idx: usize, render: bool) -> MediaStatus;
    fn AMediaCodec_getOutputFormat(c: *mut AMediaCodec) -> *mut AMediaFormat;
    // API 26 (minSdk of the app)
    fn AMediaCodec_setParameters(c: *mut AMediaCodec, params: *const AMediaFormat) -> MediaStatus;

    fn AMediaFormat_new() -> *mut AMediaFormat;
    fn AMediaFormat_delete(f: *mut AMediaFormat) -> MediaStatus;
    fn AMediaFormat_setInt32(f: *mut AMediaFormat, name: *const c_char, v: i32);
    fn AMediaFormat_setString(f: *mut AMediaFormat, name: *const c_char, v: *const c_char);
    fn AMediaFormat_setBuffer(f: *mut AMediaFormat, name: *const c_char, data: *const c_void, size: usize);
    fn AMediaFormat_getInt32(f: *mut AMediaFormat, name: *const c_char, out: *mut i32) -> bool;
    fn AMediaFormat_getBuffer(f: *mut AMediaFormat, name: *const c_char, data: *mut *mut c_void, size: *mut usize) -> bool;
}

const CONFIGURE_FLAG_ENCODE: u32 = 1;
const INFO_TRY_AGAIN_LATER: isize = -1;
const INFO_OUTPUT_FORMAT_CHANGED: isize = -2;
const INFO_OUTPUT_BUFFERS_CHANGED: isize = -3;
const BUFFER_FLAG_KEY_FRAME: u32 = 1;
const BUFFER_FLAG_CODEC_CONFIG: u32 = 2;
const BUFFER_FLAG_END_OF_STREAM: u32 = 4;

const COLOR_YUV420_PLANAR: i32 = 19;
const COLOR_YUV420_SEMIPLANAR: i32 = 21;
const COLOR_YUV420_FLEXIBLE: i32 = 0x7F42_0888;

const PROFILE_BASELINE: i32 = 1;
const PROFILE_CONSTRAINED_BASELINE: i32 = 0x1_0000;
const BITRATE_MODE_VBR: i32 = 1;
const BITRATE_MODE_CBR: i32 = 2;

const MIME_AVC: &CStr = c"video/avc";

/// API 28+ entry points, looked up at run time (the app supports API 26).
struct Late {
    get_input_format: Option<unsafe extern "C" fn(*mut AMediaCodec) -> *mut AMediaFormat>,
    get_name: Option<unsafe extern "C" fn(*mut AMediaCodec, *mut *mut c_char) -> MediaStatus>,
    release_name: Option<unsafe extern "C" fn(*mut AMediaCodec, *mut c_char)>,
}

fn late() -> &'static Late {
    static L: OnceLock<Late> = OnceLock::new();
    L.get_or_init(|| {
        // SAFETY: dlopen/dlsym with NUL-terminated names; the library stays loaded
        // (it is also linked), and the symbols have the documented signatures.
        unsafe {
            let h = libc::dlopen(c"libmediandk.so".as_ptr(), libc::RTLD_NOW);
            let sym = |n: &CStr| if h.is_null() { null_mut() } else { libc::dlsym(h, n.as_ptr()) };
            let gif = sym(c"AMediaCodec_getInputFormat");
            let gn = sym(c"AMediaCodec_getName");
            let rn = sym(c"AMediaCodec_releaseName");
            Late {
                get_input_format: (!gif.is_null()).then(|| std::mem::transmute::<*mut c_void, unsafe extern "C" fn(*mut AMediaCodec) -> *mut AMediaFormat>(gif)),
                get_name: (!gn.is_null()).then(|| std::mem::transmute::<*mut c_void, unsafe extern "C" fn(*mut AMediaCodec, *mut *mut c_char) -> MediaStatus>(gn)),
                release_name: (!rn.is_null()).then(|| std::mem::transmute::<*mut c_void, unsafe extern "C" fn(*mut AMediaCodec, *mut c_char)>(rn)),
            }
        }
    })
}

/// Owned `AMediaFormat`.
struct Format(*mut AMediaFormat);

impl Format {
    fn new() -> anyhow::Result<Self> {
        // SAFETY: plain constructor.
        let f = unsafe { AMediaFormat_new() };
        anyhow::ensure!(!f.is_null(), "AMediaFormat_new failed");
        Ok(Self(f))
    }
    fn int(&self, k: &CStr, v: i32) -> &Self {
        // SAFETY: valid format and NUL-terminated key.
        unsafe { AMediaFormat_setInt32(self.0, k.as_ptr(), v) };
        self
    }
    fn string(&self, k: &CStr, v: &CStr) -> &Self {
        // SAFETY: as above; the value is copied.
        unsafe { AMediaFormat_setString(self.0, k.as_ptr(), v.as_ptr()) };
        self
    }
    fn buffer(&self, k: &CStr, v: &[u8]) -> &Self {
        // SAFETY: as above; the bytes are copied.
        unsafe { AMediaFormat_setBuffer(self.0, k.as_ptr(), v.as_ptr().cast(), v.len()) };
        self
    }
    fn get_int(&self, k: &CStr) -> Option<i32> {
        let mut v = 0;
        // SAFETY: valid format, key and out-pointer.
        unsafe { AMediaFormat_getInt32(self.0, k.as_ptr(), &mut v) }.then_some(v)
    }
    fn get_buffer(&self, k: &CStr) -> Option<Vec<u8>> {
        let mut p: *mut c_void = null_mut();
        let mut n = 0usize;
        // SAFETY: the returned pointer is owned by the format and valid while it lives;
        // we copy it immediately.
        unsafe {
            if !AMediaFormat_getBuffer(self.0, k.as_ptr(), &mut p, &mut n) || p.is_null() {
                return None;
            }
            Some(std::slice::from_raw_parts(p as *const u8, n).to_vec())
        }
    }
}

impl Drop for Format {
    fn drop(&mut self) {
        // SAFETY: created by AMediaFormat_new / returned to us as owned by the codec API.
        unsafe { AMediaFormat_delete(self.0) };
    }
}

/// Owned `AMediaCodec` (stopped and deleted on drop).
struct Codec {
    ptr: *mut AMediaCodec,
    started: bool,
}

impl Codec {
    fn create(encoder: bool) -> anyhow::Result<Self> {
        // SAFETY: NUL-terminated MIME type.
        let ptr = unsafe { if encoder { AMediaCodec_createEncoderByType(MIME_AVC.as_ptr()) } else { AMediaCodec_createDecoderByType(MIME_AVC.as_ptr()) } };
        anyhow::ensure!(!ptr.is_null(), "no MediaCodec H.264 {} on this device", if encoder { "encoder" } else { "decoder" });
        Ok(Self { ptr, started: false })
    }

    fn configure_start(&mut self, f: &Format, encoder: bool) -> anyhow::Result<()> {
        // SAFETY: live codec and format; no surface / crypto.
        let r = unsafe { AMediaCodec_configure(self.ptr, f.0, null_mut(), null_mut(), if encoder { CONFIGURE_FLAG_ENCODE } else { 0 }) };
        anyhow::ensure!(r == AMEDIA_OK, "configure failed ({r})");
        // SAFETY: configured codec.
        let r = unsafe { AMediaCodec_start(self.ptr) };
        anyhow::ensure!(r == AMEDIA_OK, "start failed ({r})");
        self.started = true;
        Ok(())
    }

    fn name(&self) -> String {
        let l = late();
        let (Some(get), Some(rel)) = (l.get_name, l.release_name) else { return String::new() };
        let mut p: *mut c_char = null_mut();
        // SAFETY: API 28 getName/releaseName pair on a live codec.
        unsafe {
            if get(self.ptr, &mut p) != AMEDIA_OK || p.is_null() {
                return String::new();
            }
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            rel(self.ptr, p);
            s
        }
    }

    fn set_params(&self, f: &Format) -> bool {
        // SAFETY: live codec and format.
        unsafe { AMediaCodec_setParameters(self.ptr, f.0) == AMEDIA_OK }
    }

    fn output_format(&self) -> Option<Format> {
        // SAFETY: live codec; returns an owned format (deleted by `Format`).
        let f = unsafe { AMediaCodec_getOutputFormat(self.ptr) };
        (!f.is_null()).then_some(Format(f))
    }

    fn input_format(&self) -> Option<Format> {
        let g = late().get_input_format?;
        // SAFETY: live, started codec; returns an owned format.
        let f = unsafe { g(self.ptr) };
        (!f.is_null()).then_some(Format(f))
    }

    /// Dequeue an input buffer and let `fill` write it; returns bytes queued.
    fn queue_input(&self, timeout: Duration, pts_us: u64, fill: impl FnOnce(&mut [u8]) -> anyhow::Result<usize>) -> anyhow::Result<bool> {
        // SAFETY: live codec.
        let idx = unsafe { AMediaCodec_dequeueInputBuffer(self.ptr, timeout.as_micros() as i64) };
        if idx < 0 {
            return Ok(false);
        }
        let mut cap = 0usize;
        // SAFETY: index from dequeueInputBuffer; the buffer is ours until queued.
        let p = unsafe { AMediaCodec_getInputBuffer(self.ptr, idx as usize, &mut cap) };
        let n = if p.is_null() {
            Err(anyhow::anyhow!("no input buffer"))
        } else {
            // SAFETY: `cap` bytes at `p` belong to this input buffer.
            fill(unsafe { std::slice::from_raw_parts_mut(p, cap) })
        };
        // Always hand the buffer back (empty on error) so the codec does not stall.
        let size = *n.as_ref().unwrap_or(&0);
        // SAFETY: same index, size within capacity.
        let r = unsafe { AMediaCodec_queueInputBuffer(self.ptr, idx as usize, 0, size.min(cap), pts_us, 0) };
        n?;
        anyhow::ensure!(r == AMEDIA_OK, "queueInputBuffer failed ({r})");
        Ok(true)
    }

    /// Dequeue one output buffer. `Ok(None)` = nothing within `timeout`;
    /// `Ok(Some(Out::Format))` = the output format changed.
    fn dequeue_output(&self, timeout: Duration, mut take: impl FnMut(&[u8], u32)) -> anyhow::Result<Option<Out>> {
        let mut info = AMediaCodecBufferInfo::default();
        // SAFETY: live codec, valid out-pointer.
        let idx = unsafe { AMediaCodec_dequeueOutputBuffer(self.ptr, &mut info, timeout.as_micros() as i64) };
        match idx {
            INFO_TRY_AGAIN_LATER => Ok(None),
            INFO_OUTPUT_FORMAT_CHANGED => Ok(Some(Out::Format)),
            INFO_OUTPUT_BUFFERS_CHANGED => Ok(Some(Out::Other)),
            i if i < 0 => Ok(Some(Out::Other)), // other info codes: ignore
            i => {
                let mut cap = 0usize;
                // SAFETY: index from dequeueOutputBuffer.
                let p = unsafe { AMediaCodec_getOutputBuffer(self.ptr, i as usize, &mut cap) };
                let (off, size) = (info.offset.max(0) as usize, info.size.max(0) as usize);
                if !p.is_null() && size > 0 && off.saturating_add(size) <= cap {
                    // SAFETY: [off, off+size) lies inside the codec's buffer, valid until release.
                    take(unsafe { std::slice::from_raw_parts(p.add(off), size) }, info.flags);
                }
                // SAFETY: release the buffer we dequeued (no rendering).
                unsafe { AMediaCodec_releaseOutputBuffer(self.ptr, i as usize, false) };
                Ok(Some(Out::Buffer))
            }
        }
    }
}

enum Out {
    Buffer,
    Format,
    Other,
}

impl Drop for Codec {
    fn drop(&mut self) {
        // SAFETY: owned codec, stopped (if started) and deleted exactly once.
        unsafe {
            if self.started {
                AMediaCodec_stop(self.ptr);
            }
            AMediaCodec_delete(self.ptr);
        }
    }
}

fn is_software(name: &str) -> bool {
    name.starts_with("c2.android.") || name.starts_with("OMX.google.") || name.contains(".sw.") || name.ends_with(".sw")
}

// ------------------------------------------------------------------ YUV layout

#[derive(Debug, Clone, Copy, PartialEq)]
struct Plane {
    off: usize,
    col: usize,
    row: usize,
}

/// Where the Y/U/V samples of a picture live in a ByteBuffer.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Layout {
    y: Plane,
    u: Plane,
    v: Plane,
    /// nominal frame size (stride * slice-height * 3/2)
    size: usize,
}

impl Layout {
    /// Parse a MediaImage2 (`image-data`) blob: type, numPlanes, width, height,
    /// bitDepth, bitDepthAllocated, then 4 × {offset, colInc, rowInc, hSub, vSub}.
    fn from_media_image(b: &[u8]) -> Option<Self> {
        if b.len() < 24 + 3 * 20 {
            return None;
        }
        let u = |i: usize| u32::from_ne_bytes(b[i * 4..i * 4 + 4].try_into().unwrap_or_default());
        let i = |k: usize| i32::from_ne_bytes(b[k * 4..k * 4 + 4].try_into().unwrap_or_default());
        // type 1 = YUV, 3 planes, 8-bit
        if u(0) != 1 || u(1) != 3 || u(4) != 8 {
            return None;
        }
        let plane = |p: usize| {
            let base = 6 + p * 5;
            let (off, col, row) = (u(base), i(base + 1), i(base + 2));
            (col > 0 && row > 0).then_some(Plane { off: off as usize, col: col as usize, row: row as usize })
        };
        let (y, uu, v) = (plane(0)?, plane(1)?, plane(2)?);
        if uu.col != v.col || uu.row != v.row || y.col != 1 {
            return None;
        }
        let h = u(3) as usize;
        Some(Self { y, u: uu, v, size: y.row * h * 3 / 2 })
    }

    /// Classic layout from a colour format + stride/slice-height.
    fn from_color(color: i32, stride: usize, slice: usize) -> Option<Self> {
        let y = Plane { off: 0, col: 1, row: stride };
        // checked: the values come from the codec's format (usize is 32-bit on armv7)
        let c0 = stride.checked_mul(slice)?;
        let size = c0.checked_add(c0 / 2)?;
        match color {
            COLOR_YUV420_PLANAR => {
                let cs = stride.div_ceil(2);
                let v_off = cs.checked_mul(slice.div_ceil(2))?.checked_add(c0)?;
                Some(Self { y, u: Plane { off: c0, col: 1, row: cs }, v: Plane { off: v_off, col: 1, row: cs }, size })
            }
            // flexible without image-data: semi-planar is what (nearly) every codec uses
            COLOR_YUV420_SEMIPLANAR | COLOR_YUV420_FLEXIBLE => {
                Some(Self { y, u: Plane { off: c0, col: 2, row: stride }, v: Plane { off: c0 + 1, col: 2, row: stride }, size })
            }
            _ => None,
        }
    }

    /// Bytes needed to hold a `w`x`h` picture at this layout.
    fn extent(&self, w: usize, h: usize) -> usize {
        // saturating: an absurd layout just never fits a buffer
        let end = |p: &Plane, cols: usize, rows: usize| {
            p.off.saturating_add((rows - 1).saturating_mul(p.row)).saturating_add((cols - 1).saturating_mul(p.col)).saturating_add(1)
        };
        let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
        end(&self.y, w, h).max(end(&self.u, cw, ch)).max(end(&self.v, cw, ch))
    }
}

/// Copy a tightly packed plane (`cols`x`rows`) into a buffer at layout `p`.
fn write_plane(dst: &mut [u8], p: &Plane, src: &[u8], cols: usize, rows: usize) {
    for r in 0..rows {
        let s = &src[r * cols..(r + 1) * cols];
        let base = p.off + r * p.row;
        if p.col == 1 {
            dst[base..base + cols].copy_from_slice(s);
        } else {
            for (c, &b) in s.iter().enumerate() {
                dst[base + c * p.col] = b;
            }
        }
    }
}

/// Write `pic` into an encoder input buffer; returns the byte count to queue.
fn fill_input(buf: &mut [u8], layout: &Layout, pic: &I420Buf) -> anyhow::Result<usize> {
    let (w, h) = (pic.width, pic.height);
    let need = layout.extent(w, h);
    anyhow::ensure!(need <= buf.len(), "input buffer too small ({} < {need})", buf.len());
    write_plane(buf, &layout.y, &pic.y, w, h);
    write_plane(buf, &layout.u, &pic.u, w / 2, h / 2);
    write_plane(buf, &layout.v, &pic.v, w / 2, h / 2);
    Ok(layout.size.max(need).min(buf.len()))
}

fn format_layout(f: &Format, w: usize, h: usize, fallback_color: i32) -> Option<Layout> {
    if let Some(l) = f.get_buffer(c"image-data").and_then(|b| Layout::from_media_image(&b)) {
        return Some(l);
    }
    let stride = f.get_int(c"stride").filter(|&s| s as usize >= w).map(|s| s as usize).unwrap_or(w);
    let slice = f.get_int(c"slice-height").filter(|&s| s as usize >= h).map(|s| s as usize).unwrap_or(h);
    let color = f.get_int(c"color-format").unwrap_or(fallback_color);
    Layout::from_color(color, stride, slice)
}

// ------------------------------------------------------------------ encoder

pub(crate) struct Encoder {
    codec: Codec,
    hw: bool,
    w: usize,
    h: usize,
    layout: Layout,
    params: ParamSets,
    pending: VecDeque<(Vec<u8>, bool)>,
    last_pts: u64,
}

// SAFETY: an AMediaCodec may be driven from any thread as long as calls are not
// concurrent; every method here takes `&mut self`.
unsafe impl Send for Encoder {}

impl Encoder {
    pub fn new(p: &EncParams) -> anyhow::Result<Self> {
        let (w, h) = (p.w, p.h);
        anyhow::ensure!(w >= 16 && h >= 16 && w % 2 == 0 && h % 2 == 0, "bad encoder size {w}x{h}");
        let mut errs = Vec::new();
        for color in [COLOR_YUV420_SEMIPLANAR, COLOR_YUV420_PLANAR] {
            for profile in [Some(PROFILE_CONSTRAINED_BASELINE), Some(PROFILE_BASELINE), None] {
                for mode in [BITRATE_MODE_CBR, BITRATE_MODE_VBR] {
                    match Self::try_open(p, color, profile, mode) {
                        Ok(e) => return Ok(e),
                        Err(e) => errs.push(format!("{e:#}")),
                    }
                }
            }
        }
        errs.dedup();
        anyhow::bail!("MediaCodec H.264 encoder unavailable for {w}x{h}: {}", errs.join("; "))
    }

    fn try_open(p: &EncParams, color: i32, profile: Option<i32>, mode: i32) -> anyhow::Result<Self> {
        let (w, h) = (p.w, p.h);
        let mut codec = Codec::create(true)?;
        let f = Format::new()?;
        f.string(c"mime", MIME_AVC)
            .int(c"width", w as i32)
            .int(c"height", h as i32)
            .int(c"color-format", color)
            .int(c"bitrate", (p.bitrate_kbps as i32).saturating_mul(1000))
            .int(c"bitrate-mode", mode)
            .int(c"frame-rate", p.fps.clamp(1, 240) as i32)
            .int(c"i-frame-interval", if p.keyframe_interval_s == 0 { 3600 } else { p.keyframe_interval_s as i32 })
            .int(c"priority", 0) // realtime
            .int(c"latency", 1)
            // (no "prepend-sps-pps-to-idr-frames": Codec2's AVC encoder rejects the whole
            // configuration with it; SPS/PPS are prepended here instead)
            .int(c"max-bframes", 0);
        if let Some(pr) = profile {
            f.int(c"profile", pr);
            // level 3.1 covers 720p30, 4.1/5.1 bigger pictures (0x200 = 3.1, 0x1000 = 4.1, 0x4000 = 5.1)
            let mbs = w.div_ceil(16) * h.div_ceil(16);
            f.int(c"level", if mbs <= 3600 { 0x200 } else if mbs <= 8192 { 0x1000 } else { 0x4000 });
        }
        codec.configure_start(&f, true).map_err(|e| anyhow::anyhow!("{e} (color {color}, profile {profile:?}, mode {mode})"))?;
        let layout = codec
            .input_format()
            .and_then(|f| format_layout(&f, w, h, color))
            .or_else(|| Layout::from_color(color, w, h))
            .ok_or_else(|| anyhow::anyhow!("unknown input layout"))?;
        let name = codec.name();
        tracing::debug!("MediaCodec encoder {name:?} {w}x{h} color={color} profile={profile:?} mode={mode} layout={layout:?}");
        Ok(Self { hw: !is_software(&name), codec, w, h, layout, params: ParamSets::default(), pending: VecDeque::new(), last_pts: 0 })
    }

    fn drain(&mut self, wait: Duration) -> anyhow::Result<()> {
        let deadline = Instant::now() + wait;
        loop {
            let timeout = if self.pending.is_empty() { deadline.saturating_duration_since(Instant::now()) } else { Duration::ZERO };
            let mut got: Option<(Vec<u8>, u32)> = None;
            let r = self.codec.dequeue_output(timeout, |data, flags| got = Some((data.to_vec(), flags)))?;
            match r {
                None => {
                    if !self.pending.is_empty() || Instant::now() >= deadline {
                        return Ok(());
                    }
                }
                Some(Out::Buffer) => {
                    if let Some((data, flags)) = got {
                        if flags & BUFFER_FLAG_CODEC_CONFIG != 0 {
                            self.params.learn(&data);
                        } else if flags & BUFFER_FLAG_END_OF_STREAM == 0 {
                            let key = flags & BUFFER_FLAG_KEY_FRAME != 0 || nals(&data).any(|n| nal_type(n) == NAL_IDR);
                            let data = if key { self.params.complete_keyframe(data) } else { data };
                            if self.pending.len() >= 8 {
                                // way behind: drop the backlog and restart from a keyframe
                                self.pending.clear();
                                self.request_keyframe();
                            }
                            self.pending.push_back((data, key));
                        }
                    }
                }
                Some(_) => {}
            }
        }
    }

    fn request_keyframe(&self) {
        if let Ok(f) = Format::new() {
            f.int(c"request-sync", 0);
            if !self.codec.set_params(&f) {
                tracing::debug!("MediaCodec: request-sync rejected");
            }
        }
    }
}

impl EncBackend for Encoder {
    fn encode(&mut self, pic: &mut I420Buf, ts_us: u64, force_keyframe: bool) -> anyhow::Result<Option<(Vec<u8>, bool)>> {
        anyhow::ensure!(pic.width == self.w && pic.height == self.h, "picture size changed");
        if force_keyframe {
            self.request_keyframe();
        }
        // strictly increasing timestamps (some encoders drop repeats)
        let pts = ts_us.max(self.last_pts + 1);
        self.last_pts = pts;
        let layout = self.layout;
        let mut queued = self.codec.queue_input(Duration::from_millis(5), pts, |b| fill_input(b, &layout, pic))?;
        if !queued {
            // codec busy: collect what is ready, then try once more
            self.drain(Duration::from_millis(10))?;
            queued = self.codec.queue_input(Duration::from_millis(10), pts, |b| fill_input(b, &layout, pic))?;
        }
        if !queued && force_keyframe {
            self.request_keyframe();
        }
        self.drain(Duration::from_millis(if queued { 30 } else { 0 }))?;
        Ok(self.pending.pop_front())
    }

    fn set_bitrate(&mut self, kbps: u32) {
        if let Ok(f) = Format::new() {
            f.int(c"video-bitrate", (kbps as i32).saturating_mul(1000));
            if !self.codec.set_params(&f) {
                tracing::debug!("MediaCodec: bitrate change to {kbps} kbps rejected");
            }
        }
    }

    fn hardware(&self) -> bool {
        self.hw
    }
}

// ------------------------------------------------------------------ decoder

/// Geometry of decoded pictures in the output ByteBuffers.
#[derive(Debug, Clone, Copy)]
struct OutGeom {
    layout: Layout,
    /// visible rectangle
    left: usize,
    top: usize,
    w: usize,
    h: usize,
}

/// Re-create the decoder for an SPS change at most this often (a change of
/// the picture size always re-creates it at once).
const REBUILD_MIN_INTERVAL: Duration = Duration::from_millis(500);
/// How long `decode` waits for a free input buffer / a decoded picture. Short:
/// a picture not ready yet comes out of a later call (the caller treats
/// `Ok(None)` as "need more data"), so the receive path never stalls.
const DEC_INPUT_WAIT: Duration = Duration::from_millis(2);
const DEC_OUTPUT_WAIT: Duration = Duration::from_millis(4);
/// Only when every input buffer is taken (the codec is behind) does `decode`
/// wait longer — dropping the access unit would break the reference chain —
/// and never more than this, taking finished pictures out meanwhile.
const DEC_BACKPRESSURE_MAX: Duration = Duration::from_millis(30);

pub(crate) struct Decoder {
    codec: Option<Codec>,
    hw: bool,
    sps: Vec<u8>,
    pps: Vec<u8>,
    dims: (usize, usize),
    /// when the codec was last (re)configured, successfully or not
    configured_at: Option<Instant>,
    geom: Option<OutGeom>,
    out: Vec<u8>,
    have_frame: bool,
    pts: u64,
    color_req: bool,
}

// SAFETY: see `Encoder`.
unsafe impl Send for Decoder {}

impl Decoder {
    pub fn new() -> anyhow::Result<Self> {
        // Fail early (→ next backend) if the device has no AVC decoder at all.
        let probe = Codec::create(false)?;
        let hw = !is_software(&probe.name());
        drop(probe);
        Ok(Self {
            codec: None,
            hw,
            sps: Vec::new(),
            pps: Vec::new(),
            dims: (0, 0),
            configured_at: None,
            geom: None,
            out: Vec::new(),
            have_frame: false,
            pts: 0,
            color_req: true,
        })
    }

    fn configure(&mut self) -> anyhow::Result<()> {
        self.codec = None;
        self.geom = None;
        self.have_frame = false;
        self.configured_at = Some(Instant::now());
        let (w, h) = sps_dimensions(&self.sps)?;
        // the size cap, before the codec allocates anything for this stream
        check_decode_dims(w as usize, h as usize)?;
        let with_sc = |n: &[u8]| [&[0u8, 0, 0, 1][..], n].concat();
        let mut last = None;
        // ask for NV12 output first (avoids vendor-tiled formats); then the default
        for req_color in [self.color_req, false] {
            let mut codec = Codec::create(false)?;
            let f = Format::new()?;
            f.string(c"mime", MIME_AVC)
                .int(c"width", w as i32)
                .int(c"height", h as i32)
                .int(c"low-latency", 1)
                .int(c"priority", 0)
                .buffer(c"csd-0", &with_sc(&self.sps))
                .buffer(c"csd-1", &with_sc(&self.pps));
            if req_color {
                f.int(c"color-format", COLOR_YUV420_SEMIPLANAR);
            }
            match codec.configure_start(&f, false) {
                Ok(()) => {
                    let name = codec.name();
                    tracing::debug!("MediaCodec decoder {name:?} {w}x{h} (nv12 requested: {req_color})");
                    self.hw = !is_software(&name);
                    self.dims = (w as usize, h as usize);
                    self.color_req = req_color;
                    self.codec = Some(codec);
                    return Ok(());
                }
                Err(e) => last = Some(e),
            }
        }
        Err(last.unwrap_or_else(|| anyhow::anyhow!("configure failed")))
    }

    /// Read the output geometry after a format change. Sizes the codec reports
    /// are checked against the decode cap too (and all arithmetic is checked).
    fn read_geometry(&mut self) -> anyhow::Result<()> {
        let Some(f) = self.codec.as_ref().and_then(|c| c.output_format()) else { return Ok(()) };
        let (sw, sh) = self.dims;
        let dim = |k: &CStr, dflt: usize| f.get_int(k).map(|v| v.max(0) as usize).unwrap_or(dflt);
        let (fw, fh) = (dim(c"width", sw), dim(c"height", sh));
        check_decode_dims(fw, fh).map_err(|e| e.context("MediaCodec output format"))?;
        let (mut left, mut top, mut w, mut h) = (0, 0, sw.min(fw.max(1)), sh.min(fh.max(1)));
        if let (Some(l), Some(t), Some(r), Some(b)) = (f.get_int(c"crop-left"), f.get_int(c"crop-top"), f.get_int(c"crop-right"), f.get_int(c"crop-bottom")) {
            if l >= 0 && t >= 0 && r >= l && b >= t {
                let (cw, ch) = ((r as i64 - l as i64 + 1) as usize, (b as i64 - t as i64 + 1) as usize);
                anyhow::ensure!(decode_dims_ok(cw, ch) && l as usize <= fw && t as usize <= fh, "MediaCodec output crop {l},{t}..{r},{b} out of range");
                (left, top, w, h) = (l as usize, t as usize, cw, ch);
            }
        }
        // the layout must cover the whole buffer picture (incl. the crop offset)
        let layout = format_layout(&f, fw.max(left + w), fh.max(top + h), COLOR_YUV420_SEMIPLANAR);
        match layout {
            Some(layout) => self.geom = Some(OutGeom { layout, left: left & !1, top: top & !1, w, h }),
            None => {
                tracing::warn!("MediaCodec decoder: unsupported output colour format {:?}", f.get_int(c"color-format"));
                self.geom = None;
            }
        }
        Ok(())
    }

    /// Pull decoded pictures (keeping the newest in `self.out`): wait up to
    /// `wait` for the first one, then take whatever else is ready.
    fn drain_output(&mut self, wait: Duration) -> anyhow::Result<()> {
        let deadline = Instant::now() + wait;
        loop {
            let timeout = if self.have_frame { Duration::ZERO } else { deadline.saturating_duration_since(Instant::now()) };
            let codec = self.codec.as_ref().ok_or_else(|| anyhow::anyhow!("decoder gone"))?;
            let out = &mut self.out;
            let mut got = false;
            let r = codec.dequeue_output(timeout, |data, flags| {
                if flags & BUFFER_FLAG_CODEC_CONFIG == 0 {
                    out.clear();
                    out.extend_from_slice(data);
                    got = true;
                }
            })?;
            match r {
                None => {
                    if self.have_frame || Instant::now() >= deadline {
                        return Ok(());
                    }
                }
                Some(Out::Format) => {
                    // a picture taken before the change has the old geometry
                    self.have_frame = false;
                    self.read_geometry()?;
                }
                Some(Out::Buffer) => self.have_frame |= got,
                Some(Out::Other) => {}
            }
        }
    }

    fn view(&self) -> anyhow::Result<YuvView<'_>> {
        let g = self.geom.ok_or_else(|| anyhow::anyhow!("unsupported decoder output format"))?;
        let l = &g.layout;
        let (cw, ch) = (g.w.div_ceil(2), g.h.div_ceil(2));
        anyhow::ensure!(g.w > 0 && g.h > 0, "empty decoder output");
        // checked arithmetic: layout values come from the codec (32-bit usize on armv7)
        let start = |p: &Plane, row: usize, col: usize| row.checked_mul(p.row)?.checked_add(col.checked_mul(p.col)?)?.checked_add(p.off);
        let last = |o: usize, p: &Plane, cols: usize, rows: usize| (rows - 1).checked_mul(p.row)?.checked_add((cols - 1).checked_mul(p.col)?)?.checked_add(o);
        let n = self.out.len();
        let plane = |p: &Plane, row: usize, col: usize, cols: usize, rows: usize| -> Option<usize> {
            let o = start(p, row, col)?;
            (last(o, p, cols, rows)? < n).then_some(o)
        };
        let (Some(yo), Some(uo), Some(vo)) =
            (plane(&l.y, g.top, g.left, g.w, g.h), plane(&l.u, g.top / 2, g.left / 2, cw, ch), plane(&l.v, g.top / 2, g.left / 2, cw, ch))
        else {
            anyhow::bail!("decoded buffer smaller than its declared layout")
        };
        Ok(YuvView { w: g.w, h: g.h, y: &self.out[yo..], y_stride: l.y.row, u: &self.out[uo..], v: &self.out[vo..], uv_stride: l.u.row, uv_step: l.u.col })
    }
}

impl DecBackend for Decoder {
    fn decode(&mut self, au: &[u8]) -> anyhow::Result<Option<YuvView<'_>>> {
        let (mut sps, mut pps) = (None, None);
        for n in nals(au) {
            match nal_type(n) {
                NAL_SPS => sps = Some(n),
                NAL_PPS => pps = Some(n),
                _ => {}
            }
        }
        // the size cap before the codec sees any SPS of this access unit
        check_h264_au(au)?;
        if let Some(p) = pps {
            self.pps = p.to_vec();
        }
        if let Some(s) = sps {
            if s != self.sps.as_slice() || self.codec.is_none() {
                let (w, h) = sps_dimensions(s)?;
                let resized = (w as usize, h as usize) != self.dims;
                let due = self.configured_at.is_none_or(|t| t.elapsed() >= REBUILD_MIN_INTERVAL);
                if resized || due {
                    self.sps = s.to_vec();
                    anyhow::ensure!(!self.pps.is_empty(), "keyframe without PPS");
                    self.configure()?;
                }
                // else: same size, rebuilt recently — the in-band SPS/PPS go to
                // the running codec (or, without one, wait for the next keyframe)
            }
        }
        anyhow::ensure!(self.codec.is_some(), "waiting for a keyframe (no SPS yet)");
        self.pts += 33_333;
        self.have_frame = false;
        let pts = self.pts;
        let fill = |buf: &mut [u8]| -> anyhow::Result<usize> {
            anyhow::ensure!(au.len() <= buf.len(), "access unit larger than the decoder input buffer");
            buf[..au.len()].copy_from_slice(au);
            Ok(au.len())
        };
        let mut queued = self.codec.as_ref().is_some_and(|c| c.queue_input(DEC_INPUT_WAIT, pts, fill).unwrap_or(false));
        let deadline = Instant::now() + DEC_BACKPRESSURE_MAX;
        while !queued && Instant::now() < deadline {
            // all input buffers busy: take finished pictures out (frees the
            // codec's output side), then retry
            self.drain_output(Duration::ZERO)?;
            let c = self.codec.as_ref().ok_or_else(|| anyhow::anyhow!("decoder gone"))?;
            let left = deadline.saturating_duration_since(Instant::now());
            queued = c.queue_input(left.min(Duration::from_millis(5)), pts, fill)?;
        }
        if !queued {
            anyhow::bail!("MediaCodec decoder input queue full");
        }
        // a short wait for this picture (the newest ready picture wins); if it
        // is not done yet, a later call returns it
        self.drain_output(DEC_OUTPUT_WAIT)?;
        if !self.have_frame {
            return Ok(None);
        }
        if self.geom.is_none() {
            self.read_geometry()?;
        }
        self.view().map(Some)
    }

    fn hardware(&self) -> bool {
        self.hw
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::video::ContentHint;

    #[test]
    fn layouts() {
        let l = Layout::from_color(COLOR_YUV420_SEMIPLANAR, 320, 240).unwrap();
        assert_eq!((l.u.off, l.u.col, l.v.off), (320 * 240, 2, 320 * 240 + 1));
        assert_eq!(l.extent(320, 240), 320 * 240 * 3 / 2);
        let p = Layout::from_color(COLOR_YUV420_PLANAR, 320, 240).unwrap();
        assert_eq!((p.u.off, p.u.row, p.v.off), (320 * 240, 160, 320 * 240 + 160 * 120));
        assert!(Layout::from_color(0x7FA3_0C04, 320, 240).is_none());
        // MediaImage2: YUV, 3 planes, 64x32, 8 bit; Y stride 64, NV12 chroma
        let mut b = Vec::new();
        for v in [1u32, 3, 64, 32, 8, 8] {
            b.extend_from_slice(&v.to_ne_bytes());
        }
        for (off, col, row) in [(0u32, 1i32, 64i32), (2048, 2, 64), (2049, 2, 64), (0, 0, 0)] {
            b.extend_from_slice(&off.to_ne_bytes());
            b.extend_from_slice(&col.to_ne_bytes());
            b.extend_from_slice(&row.to_ne_bytes());
            b.extend_from_slice(&2u32.to_ne_bytes());
            b.extend_from_slice(&2u32.to_ne_bytes());
        }
        let m = Layout::from_media_image(&b).unwrap();
        assert_eq!(m.v, Plane { off: 2049, col: 2, row: 64 });
        assert!(Layout::from_media_image(&b[..40]).is_none());
        assert!(is_software("c2.android.avc.encoder") && is_software("OMX.google.h264.decoder") && !is_software("c2.qti.avc.encoder"));
    }

    fn picture(w: usize, h: usize, t: usize) -> I420Buf {
        let mut p = I420Buf::new(w, h);
        for y in 0..h {
            for x in 0..w {
                let block = (x / 32 + y / 32 + t).is_multiple_of(5);
                p.y[y * w + x] = if block { 220 } else { (16 + (x * 200 / w)) as u8 };
            }
        }
        for y in 0..h / 2 {
            for x in 0..w / 2 {
                p.u[y * (w / 2) + x] = (64 + y * 128 / (h / 2)) as u8;
                p.v[y * (w / 2) + x] = (192 - x * 128 / (w / 2)) as u8;
            }
        }
        p
    }

    /// Real MediaCodec round trip (runs on a device / emulator only).
    #[test]
    fn mediacodec_roundtrip() {
        let (w, h) = (320usize, 240usize);
        let p = EncParams { w, h, fps: 30, bitrate_kbps: 1500, content: ContentHint::Motion, threads: 0, keyframe_interval_s: 2 };
        let mut enc = Encoder::new(&p).expect("MediaCodec encoder");
        let mut dec = Decoder::new().expect("MediaCodec decoder");
        eprintln!("encoder hw={} layout={:?}", enc.hw, enc.layout);
        let mut first_key = None;
        let mut decoded = 0;
        let mut last = None;
        let mut keys = 0;
        for t in 0..60usize {
            let mut pic = picture(w, h, t / 3);
            if t == 20 {
                enc.set_bitrate(800);
            }
            let force = t == 0 || t == 40;
            if let Some((au, key)) = enc.encode(&mut pic, (t as u64) * 33_333, force).unwrap() {
                if first_key.is_none() {
                    first_key = Some(key);
                    assert!(au.windows(4).any(|x| x == [0, 0, 0, 1] || x[..3] == [0, 0, 1]), "Annex-B start codes");
                    let kinds: Vec<u8> = nals(&au).map(nal_type).collect();
                    assert!(kinds.contains(&NAL_SPS) && kinds.contains(&NAL_PPS) && kinds.contains(&NAL_IDR), "{kinds:?}");
                    let sps = nals(&au).find(|n| nal_type(n) == NAL_SPS).unwrap();
                    assert_eq!(sps_dimensions(sps).unwrap(), (w as u32, h as u32));
                    eprintln!("SPS profile_idc={} constraint=0x{:02x} level={}", sps[1], sps[2], sps[3]);
                }
                if key {
                    keys += 1;
                }
                match dec.decode(&au) {
                    Ok(Some(v)) => {
                        assert_eq!((v.w, v.h), (w, h));
                        decoded += 1;
                        let mut planar = I420Buf::new(w, h);
                        for r in 0..h {
                            planar.y[r * w..(r + 1) * w].copy_from_slice(&v.y[r * v.y_stride..r * v.y_stride + w]);
                        }
                        for r in 0..h / 2 {
                            for c in 0..w / 2 {
                                planar.u[r * (w / 2) + c] = v.u[r * v.uv_stride + c * v.uv_step];
                                planar.v[r * (w / 2) + c] = v.v[r * v.uv_stride + c * v.uv_step];
                            }
                        }
                        last = Some((t, planar));
                    }
                    Ok(None) => {}
                    Err(e) => panic!("decode failed at {t}: {e:#}"),
                }
            }
        }
        assert_eq!(first_key, Some(true), "first output must be a keyframe");
        assert!(keys >= 2, "forced keyframe at t=40 missing (keys={keys})");
        assert!(decoded >= 40, "decoded only {decoded} pictures");
        let (_, pic) = last.unwrap();
        // compare luma with the source of the same content phase (allow 1 frame of latency)
        let psnr = |a: &[u8], b: &[u8]| {
            let se: f64 = a.iter().zip(b).map(|(&x, &y)| (x as f64 - y as f64).powi(2)).sum::<f64>() / a.len() as f64;
            10.0 * (255.0f64 * 255.0 / se.max(1e-9)).log10()
        };
        let best = (55..60).map(|t| psnr(&picture(w, h, t / 3).y, &pic.y)).fold(0.0, f64::max);
        eprintln!("decoded={decoded} keys={keys} luma PSNR={best:.1} dB");
        assert!(best > 28.0, "PSNR too low: {best:.1}");
        if let Ok(path) = std::env::var("LUMORA_PNG_OUT") {
            let mut rgba = Vec::new();
            crate::color::i420_to_rgba(&pic.as_ref(), &mut rgba).unwrap();
            let f = std::fs::File::create(&path).unwrap();
            let mut e = png::Encoder::new(std::io::BufWriter::new(f), w as u32, h as u32);
            e.set_color(png::ColorType::Rgba);
            e.set_depth(png::BitDepth::Eight);
            e.write_header().unwrap().write_image_data(&rgba).unwrap();
            eprintln!("wrote {path}");
        }
        // resolution change → decoder re-creates itself from the new SPS
        let p2 = EncParams { w: 640, h: 360, ..p };
        let mut enc2 = Encoder::new(&p2).unwrap();
        let mut ok = false;
        for t in 0..10 {
            if let Some((au, _)) = enc2.encode(&mut picture(640, 360, t), t as u64 * 33_333, t == 0).unwrap() {
                if let Ok(Some(v)) = dec.decode(&au) {
                    assert_eq!((v.w, v.h), (640, 360));
                    ok = true;
                }
            }
        }
        assert!(ok, "no picture after the resolution change");
    }

    /// Decoding never blocks long, an SPS change of the same size does not
    /// rebuild the codec more than every REBUILD_MIN_INTERVAL, and a peer SPS
    /// above the size cap is refused before the codec is configured.
    #[test]
    fn mediacodec_decoder_fast_cached_capped() {
        let (w, h) = (320usize, 240usize);
        let p = EncParams { w, h, fps: 30, bitrate_kbps: 1500, content: ContentHint::Motion, threads: 0, keyframe_interval_s: 2 };
        let mut enc = Encoder::new(&p).unwrap();
        let mut dec = Decoder::new().unwrap();
        // 8192x8192 baseline SPS (512x512 macroblocks) + a PPS
        let big = [0, 0, 0, 1, 0x67, 0x42, 0xc0, 0x33, 0xda, 0x00, 0x20, 0x00, 0x04, 0x01, 0x90, 0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80];
        assert!(dec.decode(&big).is_err());
        assert!(dec.codec.is_none() && dec.configured_at.is_none(), "configured for an oversized stream");
        let mut aus = vec![];
        for t in 0..30usize {
            if let Some((au, _)) = enc.encode(&mut picture(w, h, t), t as u64 * 33_333, t == 0).unwrap() {
                aus.push(au);
            }
        }
        let mut times = vec![];
        let mut pics = 0;
        for au in &aus {
            let t0 = Instant::now();
            let r = dec.decode(au).unwrap();
            times.push(t0.elapsed());
            pics += r.is_some() as usize;
        }
        times.sort();
        let (median, max) = (times[times.len() / 2], times[times.len() - 1]);
        eprintln!("decode: {pics} pictures from {} AUs, median {median:?}, max {max:?}", aus.len());
        // back-to-back AUs (no frame pacing): a lagging codec's pictures coalesce
        assert!(pics * 4 >= aus.len() * 3, "too few pictures: {pics}");
        assert!(median < Duration::from_millis(15), "decode blocks: median {median:?}");
        // the same keyframe with different SPS bytes (level), same size
        let first = dec.configured_at.unwrap();
        let mut key = aus[0].clone();
        let sps_at = key.windows(4).position(|x| x == [0, 0, 1, 0x67]).unwrap() + 3;
        key[sps_at + 3] = 30; // level_idc
        dec.decode(&key).unwrap();
        assert_eq!(dec.configured_at, Some(first), "rebuilt for a same-size SPS change right away");
        std::thread::sleep(REBUILD_MIN_INTERVAL);
        dec.decode(&key).unwrap();
        assert!(dec.configured_at.unwrap() > first, "SPS change never applied");
        let again = dec.configured_at;
        dec.decode(&key).unwrap();
        assert_eq!(dec.configured_at, again, "rebuilt for an unchanged SPS");
    }

    /// The public API with H.264 picks MediaCodec; a forced failure would switch to VP8.
    #[test]
    fn video_api_uses_mediacodec() {
        let cfg = crate::EncoderConfig { fps: 30, bitrate_kbps: 1000, format: crate::VideoFormat::H264, ..Default::default() };
        let mut enc = crate::VideoEncoder::with_config(cfg).unwrap();
        let mut dec = crate::VideoDecoder::new().unwrap();
        let mut got = false;
        for t in 0..20u32 {
            let mut d = vec![0u8; 320 * 240 * 4];
            for (i, px) in d.chunks_exact_mut(4).enumerate() {
                px.copy_from_slice(&[(i % 320) as u8, ((i / 320) + t as usize) as u8, 128, 255]);
            }
            let f = crate::Frame { width: 320, height: 240, stride: 320 * 4, format: crate::PixelFormat::Rgba, data: d.into(), ts_us: t as u64 * 33_333 };
            if let Some(e) = enc.encode(&f, t == 0).unwrap() {
                assert_eq!(e.codec, crate::VideoFormat::H264);
                if let Ok(Some(out)) = dec.decode_as(e.codec, &e.data) {
                    assert_eq!((out.width, out.height), (320, 240));
                    got = true;
                }
            }
        }
        let mc = super::super::CodecKind::MediaCodec;
        assert_eq!(enc.backend(), Some((crate::VideoFormat::H264, mc)));
        assert_eq!(dec.backend(), Some((crate::VideoFormat::H264, mc)));
        assert!(got);
        // the startup probe sees the same thing
        let p = super::super::wait_probe(std::time::Duration::from_secs(10)).unwrap();
        assert!(p.enc && p.dec, "{p:?}");
    }

    /// Decode a foreign Annex-B stream (e.g. multi-slice baseline from another
    /// encoder) given in `LUMORA_H264_IN`; access units are split at AUD NALs.
    #[test]
    fn decodes_foreign_stream() {
        let Ok(path) = std::env::var("LUMORA_H264_IN") else { return };
        let data = std::fs::read(path).unwrap();
        // split at AUD start codes
        let mut cuts = Vec::new();
        let mut i = 0;
        while i + 4 <= data.len() {
            if data[i..i + 3] == [0, 0, 1] && data[i + 3] & 0x1f == 9 {
                cuts.push(if i > 0 && data[i - 1] == 0 { i - 1 } else { i });
                i += 4;
            } else {
                i += 1;
            }
        }
        cuts.push(data.len());
        let mut dec = Decoder::new().unwrap();
        let (mut n, mut pics, mut dims) = (0, 0, (0, 0));
        for w in cuts.windows(2) {
            n += 1;
            if let Some(v) = dec.decode(&data[w[0]..w[1]]).unwrap() {
                pics += 1;
                dims = (v.w, v.h);
            }
        }
        eprintln!("foreign stream: {n} AUs, {pics} pictures, {dims:?}");
        assert!(pics >= n - 2, "decoded {pics} of {n}");
    }
}
