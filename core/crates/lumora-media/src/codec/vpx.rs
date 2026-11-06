//! VP8 / VP9 through the bundled libvpx (BSD licence + royalty-free patent
//! grant) — the codec every Lumora build always has.
//!
//! Real-time settings in the spirit of WebRTC: one pass, CBR with frame
//! dropping, no lag (no look-ahead / alt-ref), keyframe on request plus a
//! periodic one, error-resilient VP8, cyclic-refresh AQ + row-mt for VP9, and
//! screen-content tuning for screen sharing.

use std::ffi::c_int;
use std::mem::MaybeUninit;
use std::ptr::{null, null_mut};

use lumora_vpx_sys as sys;

use super::{DecBackend, EncBackend, EncParams, VideoFormat, YuvView};
use crate::color::I420Buf;
use crate::video::ContentHint;

fn check(ctx: *mut sys::vpx_codec_ctx_t, r: sys::vpx_codec_err_t, what: &str) -> anyhow::Result<()> {
    if r == sys::vpx_codec_err_t_VPX_CODEC_OK {
        return Ok(());
    }
    // SAFETY: libvpx returns static NUL-terminated strings (or NULL).
    let msg = unsafe {
        let s = sys::vpx_codec_err_to_string(r);
        let detail = if ctx.is_null() { null() } else { sys::vpx_codec_error_detail(ctx) };
        let mut m = if s.is_null() { format!("error {r}") } else { std::ffi::CStr::from_ptr(s).to_string_lossy().into_owned() };
        if !detail.is_null() {
            m.push_str(": ");
            m.push_str(&std::ffi::CStr::from_ptr(detail).to_string_lossy());
        }
        m
    };
    anyhow::bail!("libvpx {what} failed: {msg}")
}

fn threads_for(w: usize, h: usize, requested: u32) -> u32 {
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2) as u32;
    let by_size = match w * h {
        p if p >= 1920 * 1080 => 4,
        p if p >= 1280 * 720 => 3,
        p if p >= 640 * 360 => 2,
        _ => 1,
    };
    let t = if requested > 0 { requested } else { by_size };
    t.clamp(1, cores.clamp(1, 8))
}

/// `LUMORA_VPX_SPEED` (benchmarks/tuning): libvpx cpu-used for every encoder.
fn speed_override() -> Option<i32> {
    std::env::var("LUMORA_VPX_SPEED").ok()?.trim().parse().ok()
}

/// VP8 real-time cpu-used (−16..16; higher = faster, lower quality).
fn vp8_speed(pixels: usize, screen: bool) -> i32 {
    let mobile = cfg!(any(target_os = "android", target_os = "ios"));
    match (pixels, screen) {
        _ if mobile => -12,
        (p, _) if p >= 1920 * 1080 => -10,
        (p, true) if p >= 1280 * 720 => -8,
        _ => -6,
    }
}

pub(crate) struct Encoder {
    ctx: Box<sys::vpx_codec_ctx_t>,
    cfg: Box<sys::vpx_codec_enc_cfg_t>,
    img: Box<sys::vpx_image_t>,
    vp9: bool,
    pts: i64,
    last_ts_ms: Option<i64>,
}

// SAFETY: a libvpx encoder context may be used from any thread as long as calls
// are not concurrent; every method takes `&mut self`.
unsafe impl Send for Encoder {}

macro_rules! ctl {
    ($ctx:expr, $id:expr, $val:expr) => {{
        // SAFETY: integer controls take an `int` vararg.
        let r = unsafe { sys::vpx_codec_control_($ctx, $id as c_int, $val as c_int) };
        if r != sys::vpx_codec_err_t_VPX_CODEC_OK {
            tracing::debug!("libvpx control {} = {} rejected ({r})", $id, $val);
        }
    }};
}

impl Encoder {
    pub fn new(format: VideoFormat, p: &EncParams) -> anyhow::Result<Self> {
        let vp9 = match format {
            VideoFormat::Vp8 => false,
            VideoFormat::Vp9 => true,
            VideoFormat::H264 => anyhow::bail!("libvpx does not do H.264"),
        };
        anyhow::ensure!(p.w >= 16 && p.h >= 16 && p.w <= 4096 && p.h <= 4096, "unsupported size {}x{}", p.w, p.h);
        // SAFETY: plain C getters returning static interface tables.
        let iface = unsafe { if vp9 { sys::vpx_codec_vp9_cx() } else { sys::vpx_codec_vp8_cx() } };
        let mut cfg: Box<sys::vpx_codec_enc_cfg_t> = Box::new(unsafe { MaybeUninit::zeroed().assume_init() });
        // SAFETY: cfg is a valid out-pointer.
        check(null_mut(), unsafe { sys::vpx_codec_enc_config_default(iface, &mut *cfg, 0) }, "config")?;
        let threads = threads_for(p.w, p.h, p.threads);
        let screen = match p.content {
            ContentHint::Screen => true,
            ContentHint::Motion => false,
            ContentHint::Auto => false,
        };
        cfg.g_w = p.w as u32;
        cfg.g_h = p.h as u32;
        cfg.g_timebase = sys::vpx_rational { num: 1, den: 1000 }; // pts in ms
        cfg.g_threads = threads;
        cfg.g_lag_in_frames = 0;
        cfg.g_pass = sys::vpx_enc_pass_VPX_RC_ONE_PASS;
        cfg.g_error_resilient = if vp9 { 0 } else { sys::VPX_ERROR_RESILIENT_DEFAULT };
        cfg.rc_end_usage = sys::vpx_rc_mode_VPX_CBR;
        cfg.rc_target_bitrate = p.bitrate_kbps;
        cfg.rc_min_quantizer = if screen { 4 } else { 2 };
        cfg.rc_max_quantizer = if vp9 { 52 } else { 56 };
        cfg.rc_undershoot_pct = 50;
        cfg.rc_overshoot_pct = 50;
        cfg.rc_buf_initial_sz = 500;
        cfg.rc_buf_optimal_sz = 600;
        cfg.rc_buf_sz = 1000;
        cfg.rc_dropframe_thresh = if screen { 0 } else { 30 };
        cfg.rc_resize_allowed = 0;
        if p.keyframe_interval_s > 0 {
            cfg.kf_mode = sys::vpx_kf_mode_VPX_KF_AUTO;
            cfg.kf_min_dist = 0;
            cfg.kf_max_dist = p.fps.saturating_mul(p.keyframe_interval_s).max(1);
        } else {
            cfg.kf_mode = sys::vpx_kf_mode_VPX_KF_DISABLED;
        }
        let mut ctx: Box<sys::vpx_codec_ctx_t> = Box::new(unsafe { MaybeUninit::zeroed().assume_init() });
        // SAFETY: ctx/cfg are valid; the ABI version matches the vendored headers.
        let r = unsafe { sys::vpx_codec_enc_init_ver(&mut *ctx, iface, &*cfg, 0, sys::VPX_ENCODER_ABI_VERSION as c_int) };
        check(&mut *ctx, r, "encoder init")?;
        let c: *mut sys::vpx_codec_ctx_t = &mut *ctx;
        if vp9 {
            // speed 7..9 = real-time presets; faster for big screens
            ctl!(c, sys::vp8e_enc_control_id_VP8E_SET_CPUUSED, speed_override().unwrap_or(if p.w * p.h >= 1280 * 720 { 9 } else { 8 }));
            ctl!(c, sys::vp8e_enc_control_id_VP9E_SET_ROW_MT, 1);
            ctl!(c, sys::vp8e_enc_control_id_VP9E_SET_TILE_COLUMNS, (threads as f32).log2().ceil() as i32);
            ctl!(c, sys::vp8e_enc_control_id_VP9E_SET_AQ_MODE, 3); // cyclic refresh (real-time)
            ctl!(c, sys::vp8e_enc_control_id_VP9E_SET_NOISE_SENSITIVITY, 0);
            ctl!(c, sys::vp8e_enc_control_id_VP9E_SET_GF_CBR_BOOST_PCT, 0);
            if screen {
                ctl!(c, sys::vp8e_enc_control_id_VP9E_SET_TUNE_CONTENT, sys::vp9e_tune_content_VP9E_CONTENT_SCREEN);
            }
        } else {
            ctl!(c, sys::vp8e_enc_control_id_VP8E_SET_CPUUSED, speed_override().unwrap_or_else(|| vp8_speed(p.w * p.h, screen)));
            ctl!(c, sys::vp8e_enc_control_id_VP8E_SET_ENABLEAUTOALTREF, 0);
            ctl!(c, sys::vp8e_enc_control_id_VP8E_SET_NOISE_SENSITIVITY, 0);
            ctl!(c, sys::vp8e_enc_control_id_VP8E_SET_STATIC_THRESHOLD, 1);
            ctl!(c, sys::vp8e_enc_control_id_VP8E_SET_TOKEN_PARTITIONS, (threads as f32).log2().ceil().min(3.0) as i32);
            ctl!(c, sys::vp8e_enc_control_id_VP8E_SET_MAX_INTRA_BITRATE_PCT, 300);
            if screen {
                ctl!(c, sys::vp8e_enc_control_id_VP8E_SET_SCREEN_CONTENT_MODE, 1);
            }
        }
        let img: Box<sys::vpx_image_t> = Box::new(unsafe { MaybeUninit::zeroed().assume_init() });
        Ok(Self { ctx, cfg, img, vp9, pts: 0, last_ts_ms: None })
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        // SAFETY: initialised in `new`, destroyed once.
        unsafe { sys::vpx_codec_destroy(&mut *self.ctx) };
    }
}

impl EncBackend for Encoder {
    fn set_bitrate(&mut self, kbps: u32) {
        if self.cfg.rc_target_bitrate == kbps {
            return;
        }
        self.cfg.rc_target_bitrate = kbps;
        // SAFETY: same cfg the encoder was created with, only the bitrate changed.
        let r = unsafe { sys::vpx_codec_enc_config_set(&mut *self.ctx, &*self.cfg) };
        if r != sys::vpx_codec_err_t_VPX_CODEC_OK {
            tracing::warn!("libvpx rejected bitrate {kbps} kbps ({r})");
        }
    }

    fn hardware(&self) -> bool {
        false
    }

    fn encode(&mut self, pic: &mut I420Buf, ts_us: u64, force_keyframe: bool) -> anyhow::Result<Option<(Vec<u8>, bool)>> {
        let (w, h) = (pic.width, pic.height);
        anyhow::ensure!(w as u32 == self.cfg.g_w && h as u32 == self.cfg.g_h, "picture size changed without a new encoder");
        let cw = w.div_ceil(2);
        let img = &mut *self.img;
        img.fmt = sys::vpx_img_fmt_VPX_IMG_FMT_I420;
        img.w = w as u32;
        img.h = h as u32;
        img.d_w = w as u32;
        img.d_h = h as u32;
        img.r_w = w as u32;
        img.r_h = h as u32;
        img.bit_depth = 8;
        img.x_chroma_shift = 1;
        img.y_chroma_shift = 1;
        img.bps = 12;
        img.planes = [pic.y.as_mut_ptr(), pic.u.as_mut_ptr(), pic.v.as_mut_ptr(), null_mut()];
        img.stride = [w as c_int, cw as c_int, cw as c_int, 0];
        // monotonic pts in ms (duplicate timestamps would confuse rate control)
        let ts_ms = (ts_us / 1000) as i64;
        let dur = match self.last_ts_ms {
            Some(prev) if ts_ms > prev => (ts_ms - prev).clamp(1, 1000),
            _ => 33,
        };
        self.last_ts_ms = Some(ts_ms);
        self.pts += dur;
        let flags = if force_keyframe { sys::VPX_EFLAG_FORCE_KF as sys::vpx_enc_frame_flags_t } else { 0 };
        // SAFETY: img points at `pic`'s planes for the duration of the call.
        let r = unsafe { sys::vpx_codec_encode(&mut *self.ctx, img, self.pts, dur as _, flags, sys::VPX_DL_REALTIME as _) };
        img.planes = [null_mut(); 4];
        check(&mut *self.ctx, r, "encode")?;
        let mut out: Option<(Vec<u8>, bool)> = None;
        let mut iter: sys::vpx_codec_iter_t = null();
        loop {
            // SAFETY: iterate packets owned by the encoder until NULL.
            let pkt = unsafe { sys::vpx_codec_get_cx_data(&mut *self.ctx, &mut iter) };
            if pkt.is_null() {
                break;
            }
            // SAFETY: non-null packet valid until the next encode call.
            let pkt = unsafe { &*pkt };
            if pkt.kind != sys::vpx_codec_cx_pkt_kind_VPX_CODEC_CX_FRAME_PKT {
                continue;
            }
            // SAFETY: frame packets use the `frame` union member.
            let f = unsafe { pkt.data.frame };
            if f.buf.is_null() || f.sz == 0 {
                continue;
            }
            let data = unsafe { std::slice::from_raw_parts(f.buf as *const u8, f.sz) };
            let key = (f.flags as u32 & sys::VPX_FRAME_IS_KEY) != 0;
            match out.as_mut() {
                // one frame per call in real-time mode; be safe if there are more
                Some((v, k)) => {
                    v.extend_from_slice(data);
                    *k |= key;
                }
                None => out = Some((data.to_vec(), key)),
            }
        }
        let _ = self.vp9;
        Ok(out)
    }
}

pub(crate) struct Decoder {
    ctx: Box<sys::vpx_codec_ctx_t>,
    format: VideoFormat,
}

// SAFETY: as for the encoder — exclusive access through `&mut self`.
unsafe impl Send for Decoder {}

impl Decoder {
    pub fn new(format: VideoFormat) -> anyhow::Result<Self> {
        // SAFETY: static interface tables.
        let iface = unsafe {
            match format {
                VideoFormat::Vp8 => sys::vpx_codec_vp8_dx(),
                VideoFormat::Vp9 => sys::vpx_codec_vp9_dx(),
                VideoFormat::H264 => anyhow::bail!("libvpx does not do H.264"),
            }
        };
        let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2) as u32;
        let cfg = sys::vpx_codec_dec_cfg_t { threads: cores.clamp(1, 4), w: 0, h: 0 };
        let mut ctx: Box<sys::vpx_codec_ctx_t> = Box::new(unsafe { MaybeUninit::zeroed().assume_init() });
        // SAFETY: valid pointers; ABI version from the vendored headers.
        let r = unsafe { sys::vpx_codec_dec_init_ver(&mut *ctx, iface, &cfg, 0, sys::VPX_DECODER_ABI_VERSION as c_int) };
        check(&mut *ctx, r, "decoder init")?;
        Ok(Self { ctx, format })
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        // SAFETY: initialised in `new`, destroyed once.
        unsafe { sys::vpx_codec_destroy(&mut *self.ctx) };
    }
}

impl DecBackend for Decoder {
    fn hardware(&self) -> bool {
        false
    }

    fn decode(&mut self, au: &[u8]) -> anyhow::Result<Option<YuvView<'_>>> {
        anyhow::ensure!(au.len() < u32::MAX as usize, "frame too large");
        // Peer data: refuse oversized pictures before libvpx allocates for them (the
        // VP8 decoder ignores CONFIG_SIZE_LIMIT; VP9's limit is 4096x4096).
        if let Some((w, h)) = frame_dims(self.format, au) {
            super::check_decode_dims(w, h)?;
        }
        // SAFETY: data pointer/len valid for the call.
        let r = unsafe { sys::vpx_codec_decode(&mut *self.ctx, au.as_ptr(), au.len() as u32, null_mut(), 0) };
        check(&mut *self.ctx, r, "decode")?;
        let mut iter: sys::vpx_codec_iter_t = null();
        let mut last: *mut sys::vpx_image_t = null_mut();
        loop {
            // SAFETY: images owned by the decoder, valid until the next decode.
            let img = unsafe { sys::vpx_codec_get_frame(&mut *self.ctx, &mut iter) };
            if img.is_null() {
                break;
            }
            last = img;
        }
        if last.is_null() {
            return Ok(None);
        }
        // SAFETY: non-null image from libvpx, borrowed until the next decode (`&mut self`).
        let img = unsafe { &*last };
        anyhow::ensure!(img.fmt == sys::vpx_img_fmt_VPX_IMG_FMT_I420 || img.fmt == sys::vpx_img_fmt_VPX_IMG_FMT_YV12, "unexpected libvpx output format {}", img.fmt);
        let (w, h) = (img.d_w as usize, img.d_h as usize);
        super::check_decode_dims(w, h)?;
        anyhow::ensure!(w > 0 && h > 0 && img.stride[0] > 0 && img.stride[1] > 0 && img.stride[2] > 0, "empty libvpx picture");
        let (ys, us, vs) = (img.stride[0] as usize, img.stride[1] as usize, img.stride[2] as usize);
        anyhow::ensure!(us == vs, "U/V strides differ");
        let ch = h.div_ceil(2);
        let (mut u, mut v) = (img.planes[1], img.planes[2]);
        if img.fmt == sys::vpx_img_fmt_VPX_IMG_FMT_YV12 {
            std::mem::swap(&mut u, &mut v);
        }
        // SAFETY: libvpx allocates `stride * rows` per plane.
        let (y, u, v) = unsafe {
            (std::slice::from_raw_parts(img.planes[0], ys * h), std::slice::from_raw_parts(u, us * ch), std::slice::from_raw_parts(v, vs * ch))
        };
        Ok(Some(YuvView { w, h, y, y_stride: ys, u, v, uv_stride: us, uv_step: 1 }))
    }
}

// ------------------------------------------------------------------ frame headers

/// Picture size a VP8/VP9 frame header announces (`None`: the frame keeps the
/// current size, or the header is too short to tell). Read before decoding so
/// a peer can't make libvpx allocate for an oversized picture.
pub(crate) fn frame_dims(format: VideoFormat, d: &[u8]) -> Option<(usize, usize)> {
    match format {
        // RFC 6386 §9.1: key frames carry 14-bit width/height after the start code;
        // inter frames can't change the size
        VideoFormat::Vp8 => {
            if d.len() < 10 || d[0] & 1 != 0 || d[3..6] != [0x9d, 0x01, 0x2a] {
                return None;
            }
            let w = u16::from_le_bytes([d[6], d[7]]) & 0x3fff;
            let h = u16::from_le_bytes([d[8], d[9]]) & 0x3fff;
            Some((w as usize, h as usize))
        }
        VideoFormat::Vp9 => vp9_dims(d),
        VideoFormat::H264 => None,
    }
}

struct Bits<'a> {
    d: &'a [u8],
    pos: usize,
}

impl Bits<'_> {
    fn bits(&mut self, n: u32) -> Option<u32> {
        let mut v = 0u32;
        for _ in 0..n {
            let b = self.d.get(self.pos / 8)?;
            v = (v << 1) | u32::from((b >> (7 - self.pos % 8)) & 1);
            self.pos += 1;
        }
        Some(v)
    }
}

/// VP9 uncompressed header (spec §6.2): the size of key / intra-only frames and
/// of inter frames that set an explicit size (`frame_size_with_refs`).
fn vp9_dims(d: &[u8]) -> Option<(usize, usize)> {
    let mut r = Bits { d, pos: 0 };
    if r.bits(2)? != 2 {
        return None; // frame marker
    }
    let profile = r.bits(1)? | (r.bits(1)? << 1);
    if profile == 3 {
        r.bits(1)?;
    }
    if r.bits(1)? == 1 {
        return None; // show_existing_frame: no new size
    }
    let key = r.bits(1)? == 0;
    let show = r.bits(1)? == 1;
    let error_res = r.bits(1)? == 1;
    let color_config = |r: &mut Bits| -> Option<()> {
        if profile >= 2 {
            r.bits(1)?;
        }
        let cs = r.bits(3)?;
        if cs != 7 {
            r.bits(1)?;
            if profile == 1 || profile == 3 {
                r.bits(3)?;
            }
        } else if profile == 1 || profile == 3 {
            r.bits(1)?;
        }
        Some(())
    };
    let frame_size = |r: &mut Bits| -> Option<(usize, usize)> { Some((r.bits(16)? as usize + 1, r.bits(16)? as usize + 1)) };
    if key {
        if r.bits(24)? != 0x49_83_42 {
            return None;
        }
        color_config(&mut r)?;
        return frame_size(&mut r);
    }
    let intra_only = if show { false } else { r.bits(1)? == 1 };
    if !error_res {
        r.bits(2)?;
    }
    if intra_only {
        if r.bits(24)? != 0x49_83_42 {
            return None;
        }
        if profile > 0 {
            color_config(&mut r)?;
        }
        r.bits(8)?;
        return frame_size(&mut r);
    }
    r.bits(8)?; // refresh_frame_flags
    for _ in 0..3 {
        r.bits(4)?; // ref_frame_idx + sign bias
    }
    for _ in 0..3 {
        if r.bits(1)? == 1 {
            return None; // size taken from a reference frame (checked when it came)
        }
    }
    frame_size(&mut r)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vp8_and_vp9_header_sizes() {
        let mut vp8 = vec![0x10, 0x02, 0x00, 0x9d, 0x01, 0x2a];
        vp8.extend_from_slice(&6000u16.to_le_bytes());
        vp8.extend_from_slice(&(0xc000u16 | 6000).to_le_bytes()); // scale bits ignored
        assert_eq!(frame_dims(VideoFormat::Vp8, &vp8), Some((6000, 6000)));
        let mut inter = vp8.clone();
        inter[0] |= 1;
        assert_eq!(frame_dims(VideoFormat::Vp8, &inter), None);
        assert_eq!(frame_dims(VideoFormat::Vp8, &vp8[..9]), None);
        // VP9 profile 0 key frame: marker 10, profile 00, show_existing 0, key 0, show 1,
        // error_res 0, sync code, color_space 1 (3 bits), color_range 0, w-1, h-1
        let mut bits = String::from("10" ) + "00" + "0" + "0" + "1" + "0";
        bits += &format!("{:024b}", 0x49_83_42);
        bits += "001" ;
        bits += "0";
        bits += &format!("{:016b}{:016b}", 5999, 2159);
        while !bits.len().is_multiple_of(8) {
            bits.push('0');
        }
        let bytes: Vec<u8> = bits.as_bytes().chunks(8).map(|c| u8::from_str_radix(std::str::from_utf8(c).unwrap(), 2).unwrap()).collect();
        assert_eq!(frame_dims(VideoFormat::Vp9, &bytes), Some((6000, 2160)));
        assert!(frame_dims(VideoFormat::Vp9, &bytes[..5]).is_none());
        assert_eq!(frame_dims(VideoFormat::H264, &bytes), None);
    }
}
