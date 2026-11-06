//! Linux VA-API H.264 (Intel / AMD GPUs): hardware encode + decode.
//!
//! libva (`libva.so.2`, `libva-drm.so.2`) is loaded at run time with
//! `libloading`, never linked, so builds run on machines without it — every
//! missing library/symbol/entrypoint is a clean error and the caller falls
//! back to VP8/VP9. A DRM render node (`/dev/dri/renderD128…`) is opened per
//! codec instance; nodes whose driver lacks the needed entrypoint are skipped
//! (e.g. an NVIDIA dGPU next to an Intel iGPU).
//!
//! Encoder: real-time CBR, constrained baseline (main/high without B-frames
//! if that is all the driver offers), one slice, IDR on demand + periodic,
//! POC type 0, one reference frame; SPS/PPS/slice headers come from the driver
//! (if a driver needs packed headers we write SPS/PPS ourselves). Output is
//! Annex-B.
//!
//! Decoder: the application side of VA-API H.264 decoding — SPS/PPS/slice
//! header parsing, POC (types 0 and 2), reference list construction with
//! modifications, sliding-window + MMCO reference marking, weighted
//! prediction tables, scaling matrices — for progressive streams without
//! B-frames (baseline / constrained baseline / main / high, CAVLC or CABAC,
//! any number of slices). Anything else is an error so the wrapper falls back.

#[path = "vaapi_sys.rs"]
#[allow(clippy::all, clippy::pedantic, non_camel_case_types, non_upper_case_globals, non_snake_case, dead_code, unused_imports, unsafe_op_in_unsafe_fn)]
mod sys;

use std::ffi::{c_char, c_int, c_uint, c_void, CStr};
use std::os::fd::AsRawFd;
use std::ptr::{null, null_mut};
use std::sync::OnceLock;

use anyhow::{anyhow, bail, Context};

use super::annexb::{nal_type, nals, MAX_SPS_MBS};
use super::{check_decode_dims, DecBackend, EncBackend, EncParams, YuvView};
use crate::color::I420Buf;
use sys::*;

// ------------------------------------------------------------------ libva loader

type VADisplay = *mut c_void;

#[allow(non_snake_case)]
struct Api {
    vaGetDisplayDRM: unsafe extern "C" fn(c_int) -> VADisplay,
    vaInitialize: unsafe extern "C" fn(VADisplay, *mut c_int, *mut c_int) -> VAStatus,
    vaTerminate: unsafe extern "C" fn(VADisplay) -> VAStatus,
    vaErrorStr: unsafe extern "C" fn(VAStatus) -> *const c_char,
    vaMaxNumEntrypoints: unsafe extern "C" fn(VADisplay) -> c_int,
    vaQueryConfigEntrypoints: unsafe extern "C" fn(VADisplay, VAProfile, *mut VAEntrypoint, *mut c_int) -> VAStatus,
    vaGetConfigAttributes: unsafe extern "C" fn(VADisplay, VAProfile, VAEntrypoint, *mut VAConfigAttrib, c_int) -> VAStatus,
    vaCreateConfig: unsafe extern "C" fn(VADisplay, VAProfile, VAEntrypoint, *mut VAConfigAttrib, c_int, *mut VAConfigID) -> VAStatus,
    vaDestroyConfig: unsafe extern "C" fn(VADisplay, VAConfigID) -> VAStatus,
    vaCreateSurfaces: unsafe extern "C" fn(VADisplay, c_uint, c_uint, c_uint, *mut VASurfaceID, c_uint, *mut c_void, c_uint) -> VAStatus,
    vaDestroySurfaces: unsafe extern "C" fn(VADisplay, *mut VASurfaceID, c_int) -> VAStatus,
    vaCreateContext: unsafe extern "C" fn(VADisplay, VAConfigID, c_int, c_int, c_int, *mut VASurfaceID, c_int, *mut VAContextID) -> VAStatus,
    vaDestroyContext: unsafe extern "C" fn(VADisplay, VAContextID) -> VAStatus,
    vaCreateBuffer: unsafe extern "C" fn(VADisplay, VAContextID, VABufferType, c_uint, c_uint, *mut c_void, *mut VABufferID) -> VAStatus,
    vaDestroyBuffer: unsafe extern "C" fn(VADisplay, VABufferID) -> VAStatus,
    vaMapBuffer: unsafe extern "C" fn(VADisplay, VABufferID, *mut *mut c_void) -> VAStatus,
    vaUnmapBuffer: unsafe extern "C" fn(VADisplay, VABufferID) -> VAStatus,
    vaBeginPicture: unsafe extern "C" fn(VADisplay, VAContextID, VASurfaceID) -> VAStatus,
    vaRenderPicture: unsafe extern "C" fn(VADisplay, VAContextID, *mut VABufferID, c_int) -> VAStatus,
    vaEndPicture: unsafe extern "C" fn(VADisplay, VAContextID) -> VAStatus,
    vaSyncSurface: unsafe extern "C" fn(VADisplay, VASurfaceID) -> VAStatus,
    vaDeriveImage: unsafe extern "C" fn(VADisplay, VASurfaceID, *mut VAImage) -> VAStatus,
    vaCreateImage: unsafe extern "C" fn(VADisplay, *mut VAImageFormat, c_int, c_int, *mut VAImage) -> VAStatus,
    vaDestroyImage: unsafe extern "C" fn(VADisplay, VAImageID) -> VAStatus,
    vaPutImage: unsafe extern "C" fn(VADisplay, VASurfaceID, VAImageID, c_int, c_int, c_uint, c_uint, c_int, c_int, c_uint, c_uint) -> VAStatus,
    vaGetImage: unsafe extern "C" fn(VADisplay, VASurfaceID, c_int, c_int, c_uint, c_uint, VAImageID) -> VAStatus,
    vaSetInfoCallback: Option<unsafe extern "C" fn(VADisplay, *mut c_void, *mut c_void) -> *mut c_void>,
    _libs: (libloading::Library, libloading::Library),
}

fn api() -> anyhow::Result<&'static Api> {
    static API: OnceLock<Result<Api, String>> = OnceLock::new();
    API.get_or_init(|| load().map_err(|e| format!("{e:#}"))).as_ref().map_err(|e| anyhow!("{e}"))
}

fn load() -> anyhow::Result<Api> {
    // SAFETY: loading the system libva; its initialisers are well behaved.
    let va = unsafe { libloading::Library::new("libva.so.2") }.context("libva.so.2 not installed")?;
    // SAFETY: as above.
    let drm = unsafe { libloading::Library::new("libva-drm.so.2") }.context("libva-drm.so.2 not installed")?;
    macro_rules! sym {
        ($lib:expr, $name:literal) => {{
            // SAFETY: the field's type is the documented C prototype of the symbol.
            let s = unsafe { $lib.get(concat!($name, "\0").as_bytes()) }.with_context(|| format!("libva lacks {}", $name))?;
            *s
        }};
    }
    // SAFETY: optional symbol (libva >= 2.3), same prototype as declared.
    let info_cb = unsafe { va.get(b"vaSetInfoCallback\0") }.ok().map(|s| *s);
    Ok(Api {
        vaGetDisplayDRM: sym!(drm, "vaGetDisplayDRM"),
        vaInitialize: sym!(va, "vaInitialize"),
        vaTerminate: sym!(va, "vaTerminate"),
        vaErrorStr: sym!(va, "vaErrorStr"),
        vaMaxNumEntrypoints: sym!(va, "vaMaxNumEntrypoints"),
        vaQueryConfigEntrypoints: sym!(va, "vaQueryConfigEntrypoints"),
        vaGetConfigAttributes: sym!(va, "vaGetConfigAttributes"),
        vaCreateConfig: sym!(va, "vaCreateConfig"),
        vaDestroyConfig: sym!(va, "vaDestroyConfig"),
        vaCreateSurfaces: sym!(va, "vaCreateSurfaces"),
        vaDestroySurfaces: sym!(va, "vaDestroySurfaces"),
        vaCreateContext: sym!(va, "vaCreateContext"),
        vaDestroyContext: sym!(va, "vaDestroyContext"),
        vaCreateBuffer: sym!(va, "vaCreateBuffer"),
        vaDestroyBuffer: sym!(va, "vaDestroyBuffer"),
        vaMapBuffer: sym!(va, "vaMapBuffer"),
        vaUnmapBuffer: sym!(va, "vaUnmapBuffer"),
        vaBeginPicture: sym!(va, "vaBeginPicture"),
        vaRenderPicture: sym!(va, "vaRenderPicture"),
        vaEndPicture: sym!(va, "vaEndPicture"),
        vaSyncSurface: sym!(va, "vaSyncSurface"),
        vaDeriveImage: sym!(va, "vaDeriveImage"),
        vaCreateImage: sym!(va, "vaCreateImage"),
        vaDestroyImage: sym!(va, "vaDestroyImage"),
        vaPutImage: sym!(va, "vaPutImage"),
        vaGetImage: sym!(va, "vaGetImage"),
        vaSetInfoCallback: info_cb,
        _libs: (va, drm),
    })
}

/// One initialised VA display on a DRM render node.
struct Display {
    api: &'static Api,
    dpy: VADisplay,
    _fd: std::fs::File,
    node: String,
}

// SAFETY: a VADisplay may be used from any thread; each codec instance owns
// its own display and only touches it through `&mut self` methods.
unsafe impl Send for Display {}

impl Drop for Display {
    fn drop(&mut self) {
        // SAFETY: initialised in `open_display`, terminated once.
        unsafe { (self.api.vaTerminate)(self.dpy) };
    }
}

impl Display {
    fn check(&self, st: VAStatus, what: &str) -> anyhow::Result<()> {
        if st == VA_STATUS_SUCCESS as VAStatus {
            return Ok(());
        }
        // SAFETY: vaErrorStr returns a static string.
        let msg = unsafe { CStr::from_ptr((self.api.vaErrorStr)(st)) }.to_string_lossy().into_owned();
        bail!("VA-API {what} failed: {msg} ({st})")
    }

    fn entrypoints(&self, profile: VAProfile) -> Vec<VAEntrypoint> {
        // SAFETY: buffer sized with vaMaxNumEntrypoints.
        unsafe {
            let max = (self.api.vaMaxNumEntrypoints)(self.dpy).clamp(0, 64);
            let mut v = vec![0 as VAEntrypoint; max as usize];
            let mut n = 0;
            if (self.api.vaQueryConfigEntrypoints)(self.dpy, profile, v.as_mut_ptr(), &mut n) != 0 {
                return vec![];
            }
            v.truncate(n.clamp(0, max) as usize);
            v
        }
    }

    fn attrib(&self, profile: VAProfile, ep: VAEntrypoint, t: VAConfigAttribType) -> u32 {
        let mut a = VAConfigAttrib { type_: t, value: 0 };
        // SAFETY: one attribute struct.
        let st = unsafe { (self.api.vaGetConfigAttributes)(self.dpy, profile, ep, &mut a, 1) };
        if st != 0 {
            VA_ATTRIB_NOT_SUPPORTED
        } else {
            a.value
        }
    }

    fn create_buffer<T>(&self, ctx: VAContextID, t: VABufferType, data: &T) -> anyhow::Result<VABufferID> {
        self.create_buffer_raw(ctx, t, (data as *const T).cast(), std::mem::size_of::<T>())
    }

    fn create_buffer_raw(&self, ctx: VAContextID, t: VABufferType, data: *const c_void, size: usize) -> anyhow::Result<VABufferID> {
        let mut id = VA_INVALID_ID;
        // SAFETY: libva copies `size` bytes from `data` (or allocates when null).
        let st = unsafe { (self.api.vaCreateBuffer)(self.dpy, ctx, t, size as c_uint, 1, data as *mut c_void, &mut id) };
        self.check(st, "vaCreateBuffer")?;
        Ok(id)
    }

    fn destroy_buffers(&self, ids: &mut Vec<VABufferID>) {
        for id in ids.drain(..) {
            // SAFETY: buffers created on this display, destroyed once.
            unsafe { (self.api.vaDestroyBuffer)(self.dpy, id) };
        }
    }

    fn render(&self, ctx: VAContextID, target: VASurfaceID, bufs: &mut [VABufferID]) -> anyhow::Result<()> {
        // SAFETY: valid context/surface/buffers of this display.
        unsafe {
            self.check((self.api.vaBeginPicture)(self.dpy, ctx, target), "vaBeginPicture")?;
            let st = (self.api.vaRenderPicture)(self.dpy, ctx, bufs.as_mut_ptr(), bufs.len() as c_int);
            let end = (self.api.vaEndPicture)(self.dpy, ctx);
            self.check(st, "vaRenderPicture")?;
            self.check(end, "vaEndPicture")?;
            self.check((self.api.vaSyncSurface)(self.dpy, target), "vaSyncSurface")
        }
    }

    fn create_surfaces(&self, w: u32, h: u32, n: usize) -> anyhow::Result<Vec<VASurfaceID>> {
        let mut v = vec![VA_INVALID_SURFACE; n];
        // SAFETY: output array of n surfaces.
        let st = unsafe { (self.api.vaCreateSurfaces)(self.dpy, VA_RT_FORMAT_YUV420, w, h, v.as_mut_ptr(), n as c_uint, null_mut(), 0) };
        self.check(st, "vaCreateSurfaces")?;
        Ok(v)
    }

    fn destroy_surfaces(&self, v: &mut Vec<VASurfaceID>) {
        if !v.is_empty() {
            // SAFETY: surfaces created on this display.
            unsafe { (self.api.vaDestroySurfaces)(self.dpy, v.as_mut_ptr(), v.len() as c_int) };
            v.clear();
        }
    }

    fn create_nv12_image(&self, w: u32, h: u32) -> anyhow::Result<VAImage> {
        // SAFETY: plain C structs, zero is a valid starting value.
        let mut fmt: VAImageFormat = unsafe { std::mem::zeroed() };
        fmt.fourcc = VA_FOURCC_NV12;
        fmt.byte_order = 1; // VA_LSB_FIRST
        fmt.bits_per_pixel = 12;
        let mut img: VAImage = unsafe { std::mem::zeroed() };
        // SAFETY: valid out-pointer.
        let st = unsafe { (self.api.vaCreateImage)(self.dpy, &mut fmt, w as c_int, h as c_int, &mut img) };
        self.check(st, "vaCreateImage")?;
        Ok(img)
    }
}

/// Open the first render node whose driver offers `ok(display)`.
fn open_display(ok: impl Fn(&Display) -> bool) -> anyhow::Result<Display> {
    let api = api()?;
    let mut nodes: Vec<String> = std::fs::read_dir("/dev/dri")
        .map(|d| d.filter_map(|e| e.ok()).map(|e| e.path().to_string_lossy().into_owned()).filter(|p| p.contains("renderD")).collect())
        .unwrap_or_default();
    nodes.sort();
    if let Ok(n) = std::env::var("LUMORA_VAAPI_DEVICE") {
        nodes = vec![n];
    }
    let mut errs = Vec::new();
    for node in nodes {
        let Ok(fd) = std::fs::OpenOptions::new().read(true).write(true).open(&node) else { continue };
        // SAFETY: fd stays open for the display's lifetime (owned by Display).
        let dpy = unsafe { (api.vaGetDisplayDRM)(fd.as_raw_fd()) };
        if dpy.is_null() {
            continue;
        }
        if let Some(cb) = api.vaSetInfoCallback {
            // SAFETY: NULL callback silences libva's info messages on stderr.
            unsafe { cb(dpy, null_mut(), null_mut()) };
        }
        let (mut maj, mut min) = (0, 0);
        // SAFETY: valid display and out-pointers.
        let st = unsafe { (api.vaInitialize)(dpy, &mut maj, &mut min) };
        if st != 0 {
            // SAFETY: display from vaGetDisplayDRM; terminate even if init failed.
            unsafe { (api.vaTerminate)(dpy) };
            errs.push(format!("{node}: vaInitialize {st}"));
            continue;
        }
        let d = Display { api, dpy, _fd: fd, node: node.clone() };
        if ok(&d) {
            return Ok(d);
        }
        errs.push(format!("{node}: no H.264 support"));
    }
    if errs.is_empty() {
        bail!("no VA-API render node");
    }
    bail!("no usable VA-API device ({})", errs.join("; "))
}

// ------------------------------------------------------------------ bitstream helpers

/// Remove emulation-prevention bytes.
fn unescape(nal: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(nal.len());
    let mut zeros = 0;
    for &b in nal {
        if zeros >= 2 && b == 3 {
            zeros = 0;
            continue;
        }
        zeros = if b == 0 { zeros + 1 } else { 0 };
        out.push(b);
    }
    out
}

struct Br<'a> {
    d: &'a [u8],
    pos: usize,
}

impl Br<'_> {
    fn u1(&mut self) -> anyhow::Result<u32> {
        let byte = *self.d.get(self.pos / 8).ok_or_else(|| anyhow!("H.264 header truncated"))?;
        let b = (byte >> (7 - (self.pos % 8))) & 1;
        self.pos += 1;
        Ok(b as u32)
    }
    fn flag(&mut self) -> anyhow::Result<bool> {
        Ok(self.u1()? == 1)
    }
    fn u(&mut self, n: u32) -> anyhow::Result<u32> {
        let mut v = 0u32;
        for _ in 0..n {
            v = (v << 1) | self.u1()?;
        }
        Ok(v)
    }
    fn ue(&mut self) -> anyhow::Result<u32> {
        let mut zeros = 0;
        while self.u1()? == 0 {
            zeros += 1;
            if zeros > 31 {
                bail!("bad Exp-Golomb code");
            }
        }
        Ok(((1u64 << zeros) - 1 + self.u(zeros)? as u64).min(u32::MAX as u64) as u32)
    }
    fn se(&mut self) -> anyhow::Result<i32> {
        let k = self.ue()? as i64;
        let v = if k % 2 == 1 { (k + 1) / 2 } else { -(k / 2) };
        i32::try_from(v).map_err(|_| anyhow!("Exp-Golomb value out of range"))
    }
    /// ue(v) that must be `<= max` (peer data: checked before any arithmetic).
    fn ue_max(&mut self, max: u32, what: &str) -> anyhow::Result<u32> {
        let v = self.ue()?;
        anyhow::ensure!(v <= max, "bad {what} ({v})");
        Ok(v)
    }
    /// se(v) that must lie in `lo..=hi`.
    fn se_in(&mut self, lo: i32, hi: i32, what: &str) -> anyhow::Result<i32> {
        let v = self.se()?;
        anyhow::ensure!((lo..=hi).contains(&v), "bad {what} ({v})");
        Ok(v)
    }
    /// More data before the rbsp_stop_one_bit?
    fn more_rbsp_data(&self) -> bool {
        let Some(last) = self.d.iter().rposition(|&b| b != 0) else { return false };
        let stop = last * 8 + 7 - self.d[last].trailing_zeros() as usize;
        self.pos < stop
    }
}

/// Exp-Golomb / fixed-length bit writer (for SPS/PPS when a driver wants packed headers).
#[derive(Default)]
struct Bw {
    out: Vec<u8>,
    cur: u8,
    n: u32,
}

impl Bw {
    fn u(&mut self, bits: u32, v: u32) {
        for i in (0..bits).rev() {
            self.cur = (self.cur << 1) | ((v >> i) & 1) as u8;
            self.n += 1;
            if self.n == 8 {
                self.out.push(self.cur);
                self.cur = 0;
                self.n = 0;
            }
        }
    }
    fn ue(&mut self, v: u32) {
        let x = v as u64 + 1;
        let len = 64 - x.leading_zeros();
        self.u(len - 1, 0);
        for i in (0..len).rev() {
            self.u(1, ((x >> i) & 1) as u32);
        }
    }
    fn se(&mut self, v: i32) {
        self.ue(if v > 0 { (2 * v - 1) as u32 } else { (-2 * v) as u32 });
    }
    /// rbsp_trailing_bits, then escape into an Annex-B NAL with `header`.
    fn finish_nal(mut self, header: u8) -> Vec<u8> {
        self.u(1, 1);
        while self.n != 0 {
            self.u(1, 0);
        }
        let mut nal = vec![0, 0, 0, 1, header];
        let mut zeros = 0;
        for b in self.out {
            if zeros >= 2 && b <= 3 {
                nal.push(3);
                zeros = 0;
            }
            zeros = if b == 0 { zeros + 1 } else { 0 };
            nal.push(b);
        }
        nal
    }
}

fn status_ok(st: VAStatus) -> bool {
    st == VA_STATUS_SUCCESS as VAStatus
}

fn invalid_pic() -> VAPictureH264 {
    // SAFETY: POD struct.
    let mut p: VAPictureH264 = unsafe { std::mem::zeroed() };
    p.picture_id = VA_INVALID_SURFACE;
    p.flags = VA_PICTURE_H264_INVALID;
    p
}

/// Smallest level that fits the picture size and macroblock rate.
fn level_for(w_mbs: u32, h_mbs: u32, fps: u32) -> u8 {
    let fs = w_mbs * h_mbs;
    let mbps = fs * fps.max(1);
    // (level_idc, MaxMBPS, MaxFS)
    const T: [(u8, u32, u32); 12] = [
        (30, 40_500, 1_620),
        (31, 108_000, 3_600),
        (32, 216_000, 5_120),
        (40, 245_760, 8_192),
        (41, 245_760, 8_192),
        (42, 522_240, 8_704),
        (50, 589_824, 22_080),
        (51, 983_040, 36_864),
        (52, 2_073_600, 36_864),
        (60, 4_177_920, 139_264),
        (61, 8_355_840, 139_264),
        (62, 16_711_680, 139_264),
    ];
    T.iter().find(|(_, m, f)| mbps <= *m && fs <= *f).map(|t| t.0).unwrap_or(62)
}

// ------------------------------------------------------------------ encoder

const ENC_PROFILES: [VAProfile; 3] = [VAProfileH264ConstrainedBaseline, VAProfileH264Main, VAProfileH264High];

fn enc_entrypoint(d: &Display) -> Option<(VAProfile, VAEntrypoint)> {
    for p in ENC_PROFILES {
        let eps = d.entrypoints(p);
        for ep in [VAEntrypointEncSlice, VAEntrypointEncSliceLP] {
            if eps.contains(&ep) && d.attrib(p, ep, VAConfigAttribRateControl) & VA_RC_CBR != 0 {
                return Some((p, ep));
            }
        }
    }
    None
}

pub(crate) struct Encoder {
    d: Display,
    profile: VAProfile,
    config: VAConfigID,
    ctx: VAContextID,
    input: Vec<VASurfaceID>,
    recon: Vec<VASurfaceID>,
    coded: VABufferID,
    /// upload path: derived image of the input surface, else a separate image + vaPutImage
    put_image: Option<VAImage>,
    w: u32,
    h: u32,
    w_mbs: u32,
    h_mbs: u32,
    fps: u32,
    kbps: u32,
    gop: u32,
    level: u8,
    cabac: bool,
    packed: u32,
    frames: u64,
    since_idr: u32,
    idr_id: u16,
    cur: usize,
    have_ref: bool,
    rc_dirty: bool,
    bufs: Vec<VABufferID>,
}

// SAFETY: all VA handles belong to `d`, which is Send; accessed via &mut self only.
unsafe impl Send for Encoder {}

impl Encoder {
    pub fn new(p: &EncParams) -> anyhow::Result<Self> {
        anyhow::ensure!(p.w >= 16 && p.h >= 16 && p.w <= 4096 && p.h <= 4096 && p.w.is_multiple_of(2) && p.h.is_multiple_of(2), "unsupported size {}x{}", p.w, p.h);
        let d = open_display(|d| enc_entrypoint(d).is_some())?;
        let (profile, ep) = enc_entrypoint(&d).ok_or_else(|| anyhow!("no H.264 encoder"))?;
        let packed_cap = d.attrib(profile, ep, VAConfigAttribEncPackedHeaders);
        let mut attrs = vec![
            VAConfigAttrib { type_: VAConfigAttribRTFormat, value: VA_RT_FORMAT_YUV420 },
            VAConfigAttrib { type_: VAConfigAttribRateControl, value: VA_RC_CBR },
        ];
        // Ask for packed SPS/PPS only when the driver cannot write them itself
        // (iHD and Mesa emit their own when we don't).
        let packed = 0;
        if packed_cap != VA_ATTRIB_NOT_SUPPORTED {
            attrs.push(VAConfigAttrib { type_: VAConfigAttribEncPackedHeaders, value: packed });
        }
        let mut config = VA_INVALID_ID;
        // SAFETY: attribute array valid for the call.
        let st = unsafe { (d.api.vaCreateConfig)(d.dpy, profile, ep, attrs.as_mut_ptr(), attrs.len() as c_int, &mut config) };
        d.check(st, "vaCreateConfig (encode)")?;
        let (w, h) = (p.w as u32, p.h as u32);
        let (w_mbs, h_mbs) = (w.div_ceil(16), h.div_ceil(16));
        let mut e = Self {
            d,
            profile,
            config,
            ctx: VA_INVALID_ID,
            input: vec![],
            recon: vec![],
            coded: VA_INVALID_ID,
            put_image: None,
            w,
            h,
            w_mbs,
            h_mbs,
            fps: p.fps.clamp(1, 240),
            kbps: p.bitrate_kbps.max(50),
            gop: if p.keyframe_interval_s == 0 { 0 } else { p.fps.clamp(1, 240) * p.keyframe_interval_s },
            level: level_for(w_mbs, h_mbs, p.fps.clamp(1, 240)),
            cabac: profile != VAProfileH264ConstrainedBaseline,
            packed,
            frames: 0,
            since_idr: 0,
            idr_id: 0,
            cur: 0,
            have_ref: false,
            rc_dirty: true,
            bufs: vec![],
        };
        e.input = e.d.create_surfaces(w_mbs * 16, h_mbs * 16, 1)?;
        e.recon = e.d.create_surfaces(w_mbs * 16, h_mbs * 16, 2)?;
        let mut targets = e.recon.clone();
        targets.extend(&e.input);
        // SAFETY: render target array valid for the call.
        let st = unsafe {
            (e.d.api.vaCreateContext)(e.d.dpy, e.config, (w_mbs * 16) as c_int, (h_mbs * 16) as c_int, 1 /* VA_PROGRESSIVE */, targets.as_mut_ptr(), targets.len() as c_int, &mut e.ctx)
        };
        e.d.check(st, "vaCreateContext (encode)")?;
        let coded_size = (w_mbs * h_mbs * 400).max(1 << 20) as usize;
        e.coded = e.d.create_buffer_raw(e.ctx, VAEncCodedBufferType, null(), coded_size)?;
        tracing::debug!("VA-API H.264 encoder on {} (profile {profile}, entrypoint {ep}, level {}, packed-header caps {packed_cap:#x})", e.d.node, e.level);
        if std::env::var_os("LUMORA_VAAPI_TRACE").is_some() {
            eprintln!("vaapi enc on {} profile {profile} ep {ep} level {} packed caps {packed_cap:#x}", e.d.node, e.level);
        }
        Ok(e)
    }

    /// Copy the tightly packed I420 picture into the NV12 input surface.
    fn upload(&mut self, pic: &I420Buf) -> anyhow::Result<()> {
        let api = self.d.api;
        let surf = self.input[0];
        let (w, h) = (self.w as usize, self.h as usize);
        // first try writing straight into the surface (no extra copy)
        let mut img: VAImage = unsafe { std::mem::zeroed() };
        let derived = self.put_image.is_none() && status_ok(unsafe { (api.vaDeriveImage)(self.d.dpy, surf, &mut img) });
        if derived && img.format.fourcc != VA_FOURCC_NV12 {
            // SAFETY: image derived just above.
            unsafe { (api.vaDestroyImage)(self.d.dpy, img.image_id) };
            self.put_image = Some(self.d.create_nv12_image(self.w_mbs * 16, self.h_mbs * 16)?);
            return self.upload(pic);
        }
        if !derived {
            if self.put_image.is_none() {
                self.put_image = Some(self.d.create_nv12_image(self.w_mbs * 16, self.h_mbs * 16)?);
            }
            img = *self.put_image.as_ref().expect("image");
        }
        let mut p: *mut c_void = null_mut();
        // SAFETY: mapping the image buffer of this display.
        self.d.check(unsafe { (api.vaMapBuffer)(self.d.dpy, img.buf, &mut p) }, "vaMapBuffer (upload)")?;
        let ok = (|| -> anyhow::Result<()> {
            let size = img.data_size as usize;
            // SAFETY: the mapped buffer is `data_size` bytes long.
            let buf = unsafe { std::slice::from_raw_parts_mut(p as *mut u8, size) };
            let (yp, yo) = (img.pitches[0] as usize, img.offsets[0] as usize);
            let (cp, co) = (img.pitches[1] as usize, img.offsets[1] as usize);
            anyhow::ensure!(yo + yp * (h - 1) + w <= size && co + cp * (h / 2 - 1) + w <= size, "VA image too small");
            for r in 0..h {
                buf[yo + r * yp..yo + r * yp + w].copy_from_slice(&pic.y[r * w..(r + 1) * w]);
            }
            let cw = w / 2;
            for r in 0..h / 2 {
                let dst = &mut buf[co + r * cp..co + r * cp + w];
                let (u, v) = (&pic.u[r * cw..(r + 1) * cw], &pic.v[r * cw..(r + 1) * cw]);
                for (i, pair) in dst.chunks_exact_mut(2).enumerate() {
                    pair[0] = u[i];
                    pair[1] = v[i];
                }
            }
            Ok(())
        })();
        // SAFETY: mapped above.
        unsafe { (api.vaUnmapBuffer)(self.d.dpy, img.buf) };
        if derived {
            // SAFETY: derived image destroyed after use.
            unsafe { (api.vaDestroyImage)(self.d.dpy, img.image_id) };
        } else {
            let (aw, ah) = (self.w_mbs * 16, self.h_mbs * 16);
            // SAFETY: valid surface and image.
            let st = unsafe { (api.vaPutImage)(self.d.dpy, surf, img.image_id, 0, 0, aw, ah, 0, 0, aw, ah) };
            self.d.check(st, "vaPutImage")?;
        }
        ok
    }

    fn misc<T>(&mut self, t: VAEncMiscParameterType, v: &T) -> anyhow::Result<()> {
        let mut raw = vec![0u8; 4 + std::mem::size_of::<T>()];
        raw[..4].copy_from_slice(&t.to_ne_bytes());
        // SAFETY: copying a POD struct's bytes.
        unsafe { std::ptr::copy_nonoverlapping((v as *const T).cast::<u8>(), raw[4..].as_mut_ptr(), std::mem::size_of::<T>()) };
        let id = self.d.create_buffer_raw(self.ctx, VAEncMiscParameterBufferType, raw.as_ptr().cast(), raw.len())?;
        self.bufs.push(id);
        Ok(())
    }

    fn seq_params(&self) -> VAEncSequenceParameterBufferH264 {
        // SAFETY: POD struct.
        let mut s: VAEncSequenceParameterBufferH264 = unsafe { std::mem::zeroed() };
        s.seq_parameter_set_id = 0;
        s.level_idc = self.level;
        s.intra_period = if self.gop == 0 { 0 } else { self.gop };
        s.intra_idr_period = s.intra_period;
        s.ip_period = 1;
        s.bits_per_second = self.kbps.saturating_mul(1000);
        s.max_num_ref_frames = 1;
        s.picture_width_in_mbs = self.w_mbs as u16;
        s.picture_height_in_mbs = self.h_mbs as u16;
        // SAFETY: writing bitfields of a POD union member.
        unsafe {
            let b = &mut s.seq_fields.bits;
            b.set_chroma_format_idc(1);
            b.set_frame_mbs_only_flag(1);
            b.set_direct_8x8_inference_flag(1);
            b.set_log2_max_frame_num_minus4(4);
            b.set_pic_order_cnt_type(0);
            b.set_log2_max_pic_order_cnt_lsb_minus4(4);
        }
        let (cw, ch) = (self.w_mbs * 16 - self.w, self.h_mbs * 16 - self.h);
        if cw > 0 || ch > 0 {
            s.frame_cropping_flag = 1;
            s.frame_crop_right_offset = cw / 2;
            s.frame_crop_bottom_offset = ch / 2;
        }
        s.vui_parameters_present_flag = 1;
        // SAFETY: as above.
        unsafe {
            let v = &mut s.vui_fields.bits;
            v.set_timing_info_present_flag(1);
            v.set_bitstream_restriction_flag(1);
            v.set_log2_max_mv_length_horizontal(15);
            v.set_log2_max_mv_length_vertical(15);
        }
        s.num_units_in_tick = 1;
        s.time_scale = self.fps * 2;
        s
    }

    /// SPS + PPS written by us (only for drivers that want packed headers).
    fn packed_sps_pps(&self) -> (Vec<u8>, Vec<u8>) {
        let profile_idc: u32 = if self.profile == VAProfileH264High {
            100
        } else if self.profile == VAProfileH264Main {
            77
        } else {
            66
        };
        let mut b = Bw::default();
        b.u(8, profile_idc);
        b.u(8, if profile_idc == 66 { 0xc0 } else { 0x40 }); // constraint_set0/1 (CB), set1 for main
        b.u(8, self.level as u32);
        b.ue(0);
        if profile_idc == 100 {
            b.ue(1); // chroma_format_idc
            b.ue(0);
            b.ue(0);
            b.u(1, 0);
            b.u(1, 0); // no scaling matrices
        }
        b.ue(4); // log2_max_frame_num_minus4
        b.ue(0); // poc type 0
        b.ue(4);
        b.ue(1); // max_num_ref_frames
        b.u(1, 0);
        b.ue(self.w_mbs - 1);
        b.ue(self.h_mbs - 1);
        b.u(1, 1); // frame_mbs_only
        b.u(1, 1); // direct_8x8
        let (cw, ch) = (self.w_mbs * 16 - self.w, self.h_mbs * 16 - self.h);
        if cw > 0 || ch > 0 {
            b.u(1, 1);
            b.ue(0);
            b.ue(cw / 2);
            b.ue(0);
            b.ue(ch / 2);
        } else {
            b.u(1, 0);
        }
        b.u(1, 0); // no VUI
        let sps = b.finish_nal(0x67);
        let mut b = Bw::default();
        b.ue(0);
        b.ue(0);
        b.u(1, self.cabac as u32);
        b.u(1, 0);
        b.ue(0); // slice groups
        b.ue(0);
        b.ue(0);
        b.u(1, 0);
        b.u(2, 0);
        b.se(0); // pic_init_qp_minus26
        b.se(0);
        b.se(0);
        b.u(1, 1); // deblocking control present
        b.u(1, 0);
        b.u(1, 0);
        let pps = b.finish_nal(0x68);
        (sps, pps)
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        let d = &self.d;
        d.destroy_buffers(&mut self.bufs);
        // SAFETY: objects of this display, each destroyed once.
        unsafe {
            if self.coded != VA_INVALID_ID {
                (d.api.vaDestroyBuffer)(d.dpy, self.coded);
            }
            if let Some(img) = self.put_image.take() {
                (d.api.vaDestroyImage)(d.dpy, img.image_id);
            }
            if self.ctx != VA_INVALID_ID {
                (d.api.vaDestroyContext)(d.dpy, self.ctx);
            }
        }
        let (mut a, mut b) = (std::mem::take(&mut self.input), std::mem::take(&mut self.recon));
        d.destroy_surfaces(&mut a);
        d.destroy_surfaces(&mut b);
        // SAFETY: config of this display.
        unsafe { (d.api.vaDestroyConfig)(d.dpy, self.config) };
    }
}

impl EncBackend for Encoder {
    fn hardware(&self) -> bool {
        true
    }

    fn set_bitrate(&mut self, kbps: u32) {
        let kbps = kbps.max(50);
        if kbps != self.kbps {
            self.kbps = kbps;
            self.rc_dirty = true;
        }
    }

    fn encode(&mut self, pic: &mut I420Buf, _ts_us: u64, force_keyframe: bool) -> anyhow::Result<Option<(Vec<u8>, bool)>> {
        anyhow::ensure!(pic.width as u32 == self.w && pic.height as u32 == self.h, "picture size changed without a new encoder");
        self.upload(pic)?;
        let idr = force_keyframe || !self.have_ref || (self.gop > 0 && self.since_idr >= self.gop);
        if idr {
            self.since_idr = 0;
            self.idr_id = self.idr_id.wrapping_add(1);
            self.rc_dirty = true;
        }
        let frame_num = self.since_idr % 256;
        let poc = (self.since_idr * 2) % 256;
        let recon = self.recon[self.cur];
        let refp = self.recon[1 - self.cur];
        let res = (|| -> anyhow::Result<Vec<u8>> {
            let mut packed_nals = Vec::new();
            if idr {
                let s = self.seq_params();
                let id = self.d.create_buffer(self.ctx, VAEncSequenceParameterBufferType, &s)?;
                self.bufs.push(id);
                if self.packed & VA_ENC_PACKED_HEADER_SEQUENCE != 0 {
                    let (sps, pps) = self.packed_sps_pps();
                    packed_nals.extend_from_slice(&sps);
                    packed_nals.extend_from_slice(&pps);
                }
            }
            if self.rc_dirty {
                self.rc_dirty = false;
                let bps = self.kbps.saturating_mul(1000);
                // SAFETY: POD structs.
                let mut rc: VAEncMiscParameterRateControl = unsafe { std::mem::zeroed() };
                rc.bits_per_second = bps;
                rc.target_percentage = 100;
                rc.window_size = 1000;
                rc.min_qp = 10;
                rc.max_qp = 51;
                // SAFETY: bitfield of a POD union.
                unsafe { rc.rc_flags.bits.set_reset(1) };
                self.misc(VAEncMiscParameterTypeRateControl, &rc)?;
                let mut hrd: VAEncMiscParameterHRD = unsafe { std::mem::zeroed() };
                hrd.buffer_size = bps;
                hrd.initial_buffer_fullness = bps / 2;
                self.misc(VAEncMiscParameterTypeHRD, &hrd)?;
                let mut fr: VAEncMiscParameterFrameRate = unsafe { std::mem::zeroed() };
                fr.framerate = self.fps | (1 << 16);
                self.misc(VAEncMiscParameterTypeFrameRate, &fr)?;
            }
            // SAFETY: POD structs.
            let mut pp: VAEncPictureParameterBufferH264 = unsafe { std::mem::zeroed() };
            pp.CurrPic = invalid_pic();
            pp.CurrPic.picture_id = recon;
            pp.CurrPic.frame_idx = frame_num;
            pp.CurrPic.flags = 0;
            pp.CurrPic.TopFieldOrderCnt = poc as i32;
            pp.CurrPic.BottomFieldOrderCnt = poc as i32;
            for r in pp.ReferenceFrames.iter_mut() {
                *r = invalid_pic();
            }
            let mut refpic = invalid_pic();
            if !idr {
                refpic.picture_id = refp;
                refpic.frame_idx = (frame_num + 255) % 256;
                refpic.flags = VA_PICTURE_H264_SHORT_TERM_REFERENCE;
                refpic.TopFieldOrderCnt = ((self.since_idr - 1) * 2 % 256) as i32;
                refpic.BottomFieldOrderCnt = refpic.TopFieldOrderCnt;
                pp.ReferenceFrames[0] = refpic;
            }
            pp.coded_buf = self.coded;
            pp.frame_num = frame_num as u16;
            pp.pic_init_qp = 26;
            // SAFETY: bitfields of a POD union.
            unsafe {
                let b = &mut pp.pic_fields.bits;
                b.set_idr_pic_flag(idr as u32);
                b.set_reference_pic_flag(1);
                b.set_entropy_coding_mode_flag(self.cabac as u32);
                b.set_deblocking_filter_control_present_flag(1);
            }
            let id = self.d.create_buffer(self.ctx, VAEncPictureParameterBufferType, &pp)?;
            self.bufs.push(id);
            let mut sp: VAEncSliceParameterBufferH264 = unsafe { std::mem::zeroed() };
            sp.macroblock_address = 0;
            sp.num_macroblocks = self.w_mbs * self.h_mbs;
            sp.macroblock_info = VA_INVALID_ID;
            sp.slice_type = if idr { 2 } else { 0 };
            sp.idr_pic_id = self.idr_id;
            sp.pic_order_cnt_lsb = poc as u16;
            for r in sp.RefPicList0.iter_mut().chain(sp.RefPicList1.iter_mut()) {
                *r = invalid_pic();
            }
            if !idr {
                sp.RefPicList0[0] = refpic;
            }
            let id = self.d.create_buffer(self.ctx, VAEncSliceParameterBufferType, &sp)?;
            self.bufs.push(id);
            let mut ids = std::mem::take(&mut self.bufs);
            let r = self.d.render(self.ctx, self.input[0], &mut ids);
            self.d.destroy_buffers(&mut ids);
            r?;
            // collect the coded segments
            let mut out = packed_nals;
            let mut p: *mut c_void = null_mut();
            // SAFETY: coded buffer of this context; segments valid while mapped.
            unsafe {
                self.d.check((self.d.api.vaMapBuffer)(self.d.dpy, self.coded, &mut p), "vaMapBuffer (coded)")?;
                let mut seg = p as *const VACodedBufferSegment;
                let mut guard = 0;
                while !seg.is_null() && guard < 64 {
                    let s = &*seg;
                    if !s.buf.is_null() && s.size > 0 {
                        out.extend_from_slice(std::slice::from_raw_parts(s.buf as *const u8, s.size as usize));
                    }
                    seg = s.next as *const VACodedBufferSegment;
                    guard += 1;
                }
                (self.d.api.vaUnmapBuffer)(self.d.dpy, self.coded);
            }
            Ok(out)
        })();
        let mut leftover = std::mem::take(&mut self.bufs);
        self.d.destroy_buffers(&mut leftover);
        let mut data = res?;
        // Drivers that support packed headers (iHD) leave SPS/PPS to the
        // application: add ours (they describe exactly the parameters above).
        if idr && !data.is_empty() && !nals(&data).any(|n| nal_type(n) == 7) {
            let (sps, pps) = self.packed_sps_pps();
            let mut full = Vec::with_capacity(sps.len() + pps.len() + data.len());
            full.extend_from_slice(&sps);
            full.extend_from_slice(&pps);
            full.extend_from_slice(&data);
            data = full;
        }
        if std::env::var_os("LUMORA_VAAPI_TRACE").is_some() {
            eprintln!("vaapi enc frame {} idr={idr} nals={:?} bytes={}", self.frames, nals(&data).map(|n| (nal_type(n), n.len())).collect::<Vec<_>>(), data.len());
        }
        self.frames += 1;
        self.since_idr += 1;
        self.cur = 1 - self.cur;
        self.have_ref = true;
        if data.is_empty() {
            return Ok(None);
        }
        Ok(Some((data, idr)))
    }
}

// ------------------------------------------------------------------ decoder: parameter sets

const DEFAULT_4X4_INTRA: [u8; 16] = [6, 13, 13, 20, 20, 20, 28, 28, 28, 28, 32, 32, 32, 37, 37, 42];
const DEFAULT_4X4_INTER: [u8; 16] = [10, 14, 14, 20, 20, 20, 24, 24, 24, 24, 27, 27, 27, 30, 30, 34];
const DEFAULT_8X8_INTRA: [u8; 64] = [
    6, 10, 10, 13, 11, 13, 16, 16, 16, 16, 18, 18, 18, 18, 18, 23, 23, 23, 23, 23, 23, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27, 27, 27, 27, 29, 29, 29,
    29, 29, 29, 29, 31, 31, 31, 31, 31, 31, 33, 33, 33, 33, 33, 36, 36, 36, 36, 38, 38, 38, 40, 40, 42,
];
const DEFAULT_8X8_INTER: [u8; 64] = [
    9, 13, 13, 15, 13, 15, 17, 17, 17, 17, 19, 19, 19, 19, 19, 21, 21, 21, 21, 21, 21, 22, 22, 22, 22, 22, 22, 22, 24, 24, 24, 24, 24, 24, 24, 24, 25, 25, 25,
    25, 25, 25, 25, 27, 27, 27, 27, 27, 27, 28, 28, 28, 28, 28, 30, 30, 30, 30, 32, 32, 32, 33, 33, 35,
];

/// Raster position of the n-th coefficient in frame zig-zag scan.
const ZIGZAG_4X4: [u8; 16] = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15];
const ZIGZAG_8X8: [u8; 64] = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
];

#[derive(Clone, Copy)]
struct Scaling {
    l4: [[u8; 16]; 6],
    l8: [[u8; 64]; 6],
}

impl Scaling {
    fn flat() -> Self {
        Scaling { l4: [[16; 16]; 6], l8: [[16; 64]; 6] }
    }
}

/// Parse `n` scaling lists with the fall-back rule (A for SPS: defaults;
/// B for PPS: the SPS lists `fb`).
fn parse_scaling(r: &mut Br, n8: usize, fb: Option<&Scaling>) -> anyhow::Result<Scaling> {
    let mut s = Scaling::flat();
    for i in 0..6 + n8 {
        let present = r.flag()?;
        let (size, def): (usize, &[u8]) = if i < 6 {
            (16, if i < 3 { &DEFAULT_4X4_INTRA } else { &DEFAULT_4X4_INTER })
        } else {
            (64, if (i - 6) % 2 == 0 { &DEFAULT_8X8_INTRA } else { &DEFAULT_8X8_INTER })
        };
        let mut list = [0u8; 64];
        if present {
            let (mut last, mut next) = (8i32, 8i32);
            let mut use_default = false;
            for (j, slot) in list.iter_mut().enumerate().take(size) {
                if next != 0 {
                    next = (last + r.se_in(-128, 127, "delta_scale")? + 256) % 256;
                    use_default = j == 0 && next == 0;
                }
                *slot = if next == 0 { last as u8 } else { next as u8 };
                last = *slot as i32;
            }
            if use_default {
                list[..size].copy_from_slice(def);
            }
        } else {
            // fall-back
            match (i, fb) {
                (0 | 3, None) => list[..16].copy_from_slice(def),
                (0 | 3, Some(f)) => list[..16].copy_from_slice(&f.l4[i]),
                (1 | 2 | 4 | 5, _) => list[..16].copy_from_slice(&s.l4[i - 1]),
                (6 | 7, None) => list[..64].copy_from_slice(def),
                (6 | 7, Some(f)) => list[..64].copy_from_slice(&f.l8[i - 6]),
                (_, _) => list[..64].copy_from_slice(&s.l8[i - 8]),
            }
        }
        if i < 6 {
            s.l4[i].copy_from_slice(&list[..16]);
        } else {
            s.l8[i - 6].copy_from_slice(&list[..64]);
        }
    }
    Ok(s)
}

#[derive(Clone)]
struct Sps {
    raw: Vec<u8>,
    level_idc: u32,
    chroma_format_idc: u32,
    separate_colour_plane: bool,
    bit_depth_luma_m8: u32,
    bit_depth_chroma_m8: u32,
    scaling: Option<Scaling>,
    log2_max_frame_num: u32,
    poc_type: u32,
    log2_max_poc_lsb: u32,
    delta_pic_order_always_zero: bool,
    num_ref_frames: u32,
    gaps_allowed: bool,
    w_mbs: u32,
    h_mbs: u32,
    frame_mbs_only: bool,
    direct_8x8: bool,
    crop: (u32, u32, u32, u32),
}

fn parse_sps(nal: &[u8]) -> anyhow::Result<(u32, Sps)> {
    let rb = unescape(&nal[1..]);
    let mut r = Br { d: &rb, pos: 0 };
    let profile_idc = r.u(8)?;
    r.u(8)?;
    let level_idc = r.u(8)?;
    let id = r.ue_max(31, "SPS id")?;
    let (mut chroma, mut sep, mut bdl, mut bdc, mut scaling) = (1, false, 0, 0, None);
    if matches!(profile_idc, 100 | 110 | 122 | 244 | 44 | 83 | 86 | 118 | 128 | 138 | 139 | 134 | 135) {
        chroma = r.ue_max(3, "chroma_format_idc")?;
        if chroma == 3 {
            sep = r.flag()?;
        }
        bdl = r.ue_max(6, "bit_depth_luma")?;
        bdc = r.ue_max(6, "bit_depth_chroma")?;
        r.flag()?; // qpprime_y_zero_transform_bypass
        if r.flag()? {
            scaling = Some(parse_scaling(&mut r, if chroma == 3 { 6 } else { 2 }, None)?);
        }
    }
    let log2_max_frame_num = r.ue_max(12, "log2_max_frame_num")? + 4;
    let poc_type = r.ue_max(2, "pic_order_cnt_type")?;
    let (mut log2_max_poc_lsb, mut dpoaz) = (0, false);
    match poc_type {
        0 => log2_max_poc_lsb = r.ue_max(12, "log2_max_pic_order_cnt_lsb")? + 4,
        1 => {
            dpoaz = r.flag()?;
            r.se()?;
            r.se()?;
            let n = r.ue_max(255, "num_ref_frames_in_pic_order_cnt_cycle")?;
            for _ in 0..n {
                r.se()?;
            }
        }
        _ => {}
    }
    let num_ref_frames = r.ue_max(16, "max_num_ref_frames")?;
    let gaps_allowed = r.flag()?;
    // ≤ 512 macroblocks each way (checked before any arithmetic)
    let w_mbs = r.ue_max(MAX_SPS_MBS - 1, "pic_width_in_mbs")? + 1;
    let h_map = r.ue_max(MAX_SPS_MBS - 1, "pic_height_in_map_units")? + 1;
    let frame_mbs_only = r.flag()?;
    if !frame_mbs_only {
        r.flag()?;
    }
    let direct_8x8 = r.flag()?;
    let h_mbs = if frame_mbs_only { h_map } else { h_map * 2 };
    anyhow::ensure!(h_mbs <= MAX_SPS_MBS, "picture too large");
    let (aw, ah) = (w_mbs * 16, h_mbs * 16);
    let mut crop = (0, 0, 0, 0);
    if r.flag()? {
        crop = (r.ue()?, r.ue()?, r.ue()?, r.ue()?);
        // crop units are 2 luma samples (4:2:0, progressive — all we decode);
        // u64 so hostile values cannot overflow
        let (cl, cr, ct, cb) = (crop.0 as u64, crop.1 as u64, crop.2 as u64, crop.3 as u64);
        anyhow::ensure!(2 * (cl + cr) < aw as u64 && 2 * (ct + cb) < ah as u64, "SPS cropping larger than the picture");
    }
    // the decode size cap, on the allocated (coded) size
    check_decode_dims(aw as usize, ah as usize)?;
    Ok((
        id,
        Sps {
            raw: nal.to_vec(),
            level_idc,
            chroma_format_idc: chroma,
            separate_colour_plane: sep,
            bit_depth_luma_m8: bdl,
            bit_depth_chroma_m8: bdc,
            scaling,
            log2_max_frame_num,
            poc_type,
            log2_max_poc_lsb,
            delta_pic_order_always_zero: dpoaz,
            num_ref_frames,
            gaps_allowed,
            w_mbs,
            h_mbs,
            frame_mbs_only,
            direct_8x8,
            crop,
        },
    ))
}

#[derive(Clone)]
struct Pps {
    sps_id: u32,
    entropy: bool,
    bottom_field_pic_order_present: bool,
    num_ref_idx_l0_default_m1: u32,
    weighted_pred: bool,
    weighted_bipred_idc: u32,
    pic_init_qp_m26: i32,
    pic_init_qs_m26: i32,
    chroma_qp_index_offset: i32,
    deblocking_ctrl: bool,
    constrained_intra: bool,
    redundant_pic_cnt_present: bool,
    transform_8x8: bool,
    scaling: Option<Scaling>,
    second_chroma_qp_index_offset: i32,
}

fn parse_pps(nal: &[u8], spss: &[Option<Sps>]) -> anyhow::Result<(u32, Pps)> {
    let rb = unescape(&nal[1..]);
    let mut r = Br { d: &rb, pos: 0 };
    let id = r.ue()?;
    let sps_id = r.ue()?;
    anyhow::ensure!(id < 256 && sps_id < 32, "bad PPS ids");
    let entropy = r.flag()?;
    let bfpo = r.flag()?;
    let slice_groups = r.ue()?;
    anyhow::ensure!(slice_groups == 0, "slice groups (FMO) are not supported");
    let l0 = r.ue()?;
    let l1 = r.ue()?;
    anyhow::ensure!(l0 < 32 && l1 < 32, "bad PPS ref counts");
    let weighted_pred = r.flag()?;
    let wbi = r.u(2)?;
    let qp = r.se_in(-26 - 6 * 6, 25, "pic_init_qp_minus26")?;
    let qs = r.se_in(-26, 25, "pic_init_qs_minus26")?;
    let cqo = r.se_in(-12, 12, "chroma_qp_index_offset")?;
    let dfc = r.flag()?;
    let ci = r.flag()?;
    let rpc = r.flag()?;
    let (mut t8, mut scaling, mut scqo) = (false, None, cqo);
    if r.more_rbsp_data() {
        t8 = r.flag()?;
        if r.flag()? {
            let sps = spss.get(sps_id as usize).and_then(|s| s.as_ref());
            let chroma3 = sps.map(|s| s.chroma_format_idc == 3).unwrap_or(false);
            // fall-back rule B uses the SPS lists (or rule A when the SPS has none)
            let fb = sps.and_then(|s| s.scaling);
            scaling = Some(parse_scaling(&mut r, if t8 { if chroma3 { 6 } else { 2 } } else { 0 }, fb.as_ref())?);
        }
        scqo = r.se_in(-12, 12, "second_chroma_qp_index_offset")?;
    }
    Ok((
        id,
        Pps {
            sps_id,
            entropy,
            bottom_field_pic_order_present: bfpo,
            num_ref_idx_l0_default_m1: l0,
            weighted_pred,
            weighted_bipred_idc: wbi,
            pic_init_qp_m26: qp,
            pic_init_qs_m26: qs,
            chroma_qp_index_offset: cqo,
            deblocking_ctrl: dfc,
            constrained_intra: ci,
            redundant_pic_cnt_present: rpc,
            transform_8x8: t8,
            scaling,
            second_chroma_qp_index_offset: scqo,
        },
    ))
}

#[derive(Clone, Copy, Debug)]
enum Mmco {
    UnmarkShort(u32),
    UnmarkLong(u32),
    ShortToLong(u32, u32),
    MaxLong(u32),
    All,
    CurrentLong(u32),
}

#[derive(Default)]
struct Weights {
    luma_denom: u32,
    chroma_denom: u32,
    luma_flag: bool,
    chroma_flag: bool,
    luma: Vec<(i32, i32)>,
    chroma: Vec<[(i32, i32); 2]>,
}

struct Slice {
    first_mb: u32,
    slice_type: u32,
    pps_id: u32,
    frame_num: u32,
    idr: bool,
    nal_ref_idc: u32,
    poc_lsb: u32,
    delta_poc_bottom: i32,
    num_ref_l0_m1: u32,
    mods: Vec<(u32, u32)>,
    weights: Option<Weights>,
    long_term_ref: bool,
    mmcos: Vec<Mmco>,
    cabac_init_idc: u32,
    qp_delta: i32,
    disable_deblock: u32,
    alpha: i32,
    beta: i32,
    header_bits: usize,
}

fn parse_slice(nal: &[u8], spss: &[Option<Sps>], ppss: &[Option<Pps>]) -> anyhow::Result<Slice> {
    let nal_ref_idc = ((nal[0] >> 5) & 3) as u32;
    let idr = nal_type(nal) == 5;
    let rb = unescape(&nal[1..]);
    let mut r = Br { d: &rb, pos: 0 };
    let first_mb = r.ue()?;
    let slice_type = r.ue_max(9, "slice_type")? % 5;
    anyhow::ensure!(slice_type == 0 || slice_type == 2, "only I and P slices are supported (got type {slice_type})");
    let pps_id = r.ue()?;
    let pps = ppss.get(pps_id as usize).and_then(|p| p.as_ref()).ok_or_else(|| anyhow!("slice refers to unknown PPS {pps_id}"))?;
    let sps = spss.get(pps.sps_id as usize).and_then(|s| s.as_ref()).ok_or_else(|| anyhow!("PPS refers to unknown SPS"))?;
    anyhow::ensure!(first_mb < sps.w_mbs * sps.h_mbs, "first_mb_in_slice out of range");
    if sps.separate_colour_plane {
        r.u(2)?;
    }
    let frame_num = r.u(sps.log2_max_frame_num)?;
    let max_frame_num = 1u32 << sps.log2_max_frame_num;
    anyhow::ensure!(sps.frame_mbs_only, "interlaced streams are not supported");
    if idr {
        r.ue_max(65535, "idr_pic_id")?;
    }
    let (mut poc_lsb, mut dpb) = (0, 0);
    match sps.poc_type {
        0 => {
            poc_lsb = r.u(sps.log2_max_poc_lsb)?;
            if pps.bottom_field_pic_order_present {
                dpb = r.se()?;
            }
        }
        1 => bail!("pic_order_cnt_type 1 is not supported"),
        _ => {}
    }
    if pps.redundant_pic_cnt_present {
        r.ue_max(127, "redundant_pic_cnt")?;
    }
    let mut num_ref_l0_m1 = pps.num_ref_idx_l0_default_m1;
    let mut mods = vec![];
    let mut weights = None;
    if slice_type == 0 {
        if r.flag()? {
            num_ref_l0_m1 = r.ue()?;
            anyhow::ensure!(num_ref_l0_m1 < 32, "bad num_ref_idx");
        }
        if r.flag()? {
            loop {
                let idc = r.ue()?;
                if idc == 3 {
                    break;
                }
                anyhow::ensure!(idc <= 2 && mods.len() < 64, "bad ref_pic_list_modification");
                // abs_diff_pic_num_minus1 < MaxFrameNum, long_term_pic_num < 32
                let val = r.ue_max(if idc == 2 { 31 } else { max_frame_num - 1 }, "ref_pic_list_modification value")?;
                mods.push((idc, val));
            }
        }
        if pps.weighted_pred {
            let mut w = Weights { luma_denom: r.ue()?, ..Default::default() };
            if sps.chroma_format_idc != 0 {
                w.chroma_denom = r.ue()?;
            }
            anyhow::ensure!(w.luma_denom <= 7 && w.chroma_denom <= 7, "bad weight denominators");
            for _ in 0..=num_ref_l0_m1 {
                if r.flag()? {
                    w.luma_flag = true;
                    w.luma.push((r.se_in(-128, 127, "luma_weight")?, r.se_in(-128, 127, "luma_offset")?));
                } else {
                    w.luma.push((1 << w.luma_denom, 0));
                }
                if sps.chroma_format_idc != 0 && r.flag()? {
                    w.chroma_flag = true;
                    let mut c = [(0, 0); 2];
                    for v in c.iter_mut() {
                        *v = (r.se_in(-128, 127, "chroma_weight")?, r.se_in(-128, 127, "chroma_offset")?);
                    }
                    w.chroma.push(c);
                } else {
                    w.chroma.push([(1 << w.chroma_denom, 0); 2]);
                }
            }
            weights = Some(w);
        }
    }
    let (mut long_term_ref, mut mmcos) = (false, vec![]);
    if nal_ref_idc != 0 {
        if idr {
            r.flag()?; // no_output_of_prior_pics
            long_term_ref = r.flag()?;
        } else if r.flag()? {
            loop {
                let op = r.ue()?;
                anyhow::ensure!(mmcos.len() < 66, "too many MMCOs");
                let diff = |r: &mut Br| r.ue_max(max_frame_num - 1, "difference_of_pic_nums");
                let long = |r: &mut Br| r.ue_max(31, "long-term index");
                mmcos.push(match op {
                    0 => break,
                    1 => Mmco::UnmarkShort(diff(&mut r)?),
                    2 => Mmco::UnmarkLong(long(&mut r)?),
                    3 => {
                        let d = diff(&mut r)?;
                        Mmco::ShortToLong(d, long(&mut r)?)
                    }
                    4 => Mmco::MaxLong(r.ue_max(32, "max_long_term_frame_idx_plus1")?),
                    5 => Mmco::All,
                    6 => Mmco::CurrentLong(long(&mut r)?),
                    _ => bail!("bad MMCO"),
                });
            }
        }
    }
    let mut cabac_init_idc = 0;
    if pps.entropy && slice_type != 2 {
        cabac_init_idc = r.ue_max(2, "cabac_init_idc")?;
    }
    let qp_delta = r.se_in(-87, 87, "slice_qp_delta")?;
    anyhow::ensure!((-6 * sps.bit_depth_luma_m8 as i32..=51).contains(&(26 + pps.pic_init_qp_m26 + qp_delta)), "bad slice QP");
    let (mut disable_deblock, mut alpha, mut beta) = (0, 0, 0);
    if pps.deblocking_ctrl {
        disable_deblock = r.ue_max(2, "disable_deblocking_filter_idc")?;
        if disable_deblock != 1 {
            alpha = r.se_in(-6, 6, "slice_alpha_c0_offset_div2")?;
            beta = r.se_in(-6, 6, "slice_beta_offset_div2")?;
        }
    }
    Ok(Slice {
        first_mb,
        slice_type,
        pps_id,
        frame_num,
        idr,
        nal_ref_idc,
        poc_lsb,
        delta_poc_bottom: dpb,
        num_ref_l0_m1,
        mods,
        weights,
        long_term_ref,
        mmcos,
        cabac_init_idc,
        qp_delta,
        disable_deblock,
        alpha,
        beta,
        header_bits: 8 + r.pos,
    })
}

// ------------------------------------------------------------------ decoder

#[derive(Clone, Copy, Debug)]
struct RefPic {
    surface: VASurfaceID,
    frame_num: u32,
    /// LongTermFrameIdx when long-term
    long: Option<u32>,
    poc: i32,
}

impl RefPic {
    fn va(&self, frame_num_wrap: i64) -> VAPictureH264 {
        let mut p = invalid_pic();
        p.picture_id = self.surface;
        let _ = frame_num_wrap;
        p.frame_idx = self.long.unwrap_or(self.frame_num);
        p.flags = if self.long.is_some() { VA_PICTURE_H264_LONG_TERM_REFERENCE } else { VA_PICTURE_H264_SHORT_TERM_REFERENCE };
        p.TopFieldOrderCnt = self.poc;
        p.BottomFieldOrderCnt = self.poc;
        p
    }
}

pub(crate) struct Decoder {
    d: Display,
    profile: VAProfile,
    config: VAConfigID,
    ctx: VAContextID,
    surfaces: Vec<VASurfaceID>,
    /// (w_mbs, h_mbs, pool size) the context was made for
    dims: (u32, u32, usize),
    image: Option<VAImage>,
    spss: Vec<Option<Sps>>,
    ppss: Vec<Option<Pps>>,
    dpb: Vec<RefPic>,
    max_long_idx: Option<u32>,
    // POC state
    prev_poc_msb: i32,
    prev_poc_lsb: i32,
    prev_frame_num_offset: i64,
    prev_frame_num: u32,
    out: Vec<u8>,
}

// SAFETY: all VA handles belong to `d` (Send); used through `&mut self` only.
unsafe impl Send for Decoder {}

fn dec_profile(d: &Display) -> Option<VAProfile> {
    [VAProfileH264High, VAProfileH264Main, VAProfileH264ConstrainedBaseline].into_iter().find(|&p| d.entrypoints(p).contains(&VAEntrypointVLD))
}

impl Decoder {
    pub fn new() -> anyhow::Result<Self> {
        let d = open_display(|d| dec_profile(d).is_some())?;
        let profile = dec_profile(&d).ok_or_else(|| anyhow!("no H.264 decoder"))?;
        let mut attr = VAConfigAttrib { type_: VAConfigAttribRTFormat, value: VA_RT_FORMAT_YUV420 };
        let mut config = VA_INVALID_ID;
        // SAFETY: one attribute.
        let st = unsafe { (d.api.vaCreateConfig)(d.dpy, profile, VAEntrypointVLD, &mut attr, 1, &mut config) };
        d.check(st, "vaCreateConfig (decode)")?;
        tracing::debug!("VA-API H.264 decoder on {} (profile {profile})", d.node);
        Ok(Self {
            d,
            profile,
            config,
            ctx: VA_INVALID_ID,
            surfaces: vec![],
            dims: (0, 0, 0),
            image: None,
            spss: vec![None; 32],
            ppss: vec![None; 256],
            dpb: vec![],
            max_long_idx: None,
            prev_poc_msb: 0,
            prev_poc_lsb: 0,
            prev_frame_num_offset: 0,
            prev_frame_num: 0,
            out: vec![],
        })
    }

    fn teardown_context(&mut self) {
        // SAFETY: objects of this display, destroyed once.
        unsafe {
            if let Some(img) = self.image.take() {
                (self.d.api.vaDestroyImage)(self.d.dpy, img.image_id);
            }
            if self.ctx != VA_INVALID_ID {
                (self.d.api.vaDestroyContext)(self.d.dpy, self.ctx);
                self.ctx = VA_INVALID_ID;
            }
        }
        let mut s = std::mem::take(&mut self.surfaces);
        self.d.destroy_surfaces(&mut s);
        self.dpb.clear();
    }

    fn ensure_context(&mut self, sps: &Sps) -> anyhow::Result<()> {
        let pool = sps.num_ref_frames.max(1) as usize + 2;
        let want = (sps.w_mbs, sps.h_mbs, pool);
        if self.ctx != VA_INVALID_ID && self.dims.0 == want.0 && self.dims.1 == want.1 && self.dims.2 >= pool {
            return Ok(());
        }
        self.teardown_context();
        // parse_sps keeps w_mbs/h_mbs ≤ 512; the decode cap is checked again
        // right before allocating (defence in depth)
        anyhow::ensure!(sps.w_mbs <= MAX_SPS_MBS && sps.h_mbs <= MAX_SPS_MBS, "picture too large");
        let (w, h) = (sps.w_mbs * 16, sps.h_mbs * 16);
        check_decode_dims(w as usize, h as usize)?;
        self.surfaces = self.d.create_surfaces(w, h, pool)?;
        let mut targets = self.surfaces.clone();
        let mut ctx = VA_INVALID_ID;
        // SAFETY: render-target array valid for the call.
        let st = unsafe { (self.d.api.vaCreateContext)(self.d.dpy, self.config, w as c_int, h as c_int, 1, targets.as_mut_ptr(), targets.len() as c_int, &mut ctx) };
        self.d.check(st, "vaCreateContext (decode)")?;
        self.ctx = ctx;
        self.image = Some(self.d.create_nv12_image(w, h)?);
        self.dims = want;
        Ok(())
    }

    fn free_surface(&self) -> anyhow::Result<VASurfaceID> {
        self.surfaces.iter().copied().find(|s| !self.dpb.iter().any(|r| r.surface == *s)).ok_or_else(|| anyhow!("no free decode surface (DPB full)"))
    }

    /// Picture order count (8.2.1). Peer-controlled: computed in i64 and
    /// rejected when it leaves the i32 range (a conforming stream never does).
    fn compute_poc(&mut self, sps: &Sps, s: &Slice) -> anyhow::Result<i32> {
        let to_i32 = |v: i64| i32::try_from(v).map_err(|_| anyhow!("picture order count out of range"));
        match sps.poc_type {
            0 => {
                let (prev_msb, prev_lsb) = if s.idr { (0, 0) } else { (self.prev_poc_msb as i64, self.prev_poc_lsb as i64) };
                let max = 1i64 << sps.log2_max_poc_lsb;
                let lsb = s.poc_lsb as i64;
                let msb = if lsb < prev_lsb && prev_lsb - lsb >= max / 2 {
                    prev_msb + max
                } else if lsb > prev_lsb && lsb - prev_lsb > max / 2 {
                    prev_msb - max
                } else {
                    prev_msb
                };
                let top = msb + lsb;
                let poc = to_i32(top.min(top + s.delta_poc_bottom as i64))?;
                let (msb, lsb) = (to_i32(msb)?, to_i32(lsb)?);
                to_i32(top)?;
                if s.nal_ref_idc != 0 {
                    self.prev_poc_msb = msb;
                    self.prev_poc_lsb = lsb;
                }
                Ok(poc)
            }
            _ => {
                let max = 1i64 << sps.log2_max_frame_num;
                let offset = if s.idr {
                    0
                } else if self.prev_frame_num > s.frame_num {
                    self.prev_frame_num_offset.checked_add(max).ok_or_else(|| anyhow!("frame number offset out of range"))?
                } else {
                    self.prev_frame_num_offset
                };
                let t = if s.idr {
                    0
                } else {
                    let abs = offset.checked_add(s.frame_num as i64).and_then(|a| a.checked_mul(2)).ok_or_else(|| anyhow!("picture order count out of range"))?;
                    if s.nal_ref_idc == 0 {
                        abs - 1
                    } else {
                        abs
                    }
                };
                let t = to_i32(t)?;
                self.prev_frame_num_offset = offset;
                Ok(t)
            }
        }
    }

    /// PicNum of a short-term reference relative to the current frame_num.
    fn pic_num(r: &RefPic, cur_frame_num: u32, max_frame_num: u32) -> i64 {
        if r.frame_num > cur_frame_num {
            r.frame_num as i64 - max_frame_num as i64
        } else {
            r.frame_num as i64
        }
    }

    fn ref_list0(&self, s: &Slice, max_frame_num: u32) -> anyhow::Result<Vec<RefPic>> {
        let mut short: Vec<RefPic> = self.dpb.iter().filter(|r| r.long.is_none()).copied().collect();
        short.sort_by_key(|r| -Self::pic_num(r, s.frame_num, max_frame_num));
        let mut long: Vec<RefPic> = self.dpb.iter().filter(|r| r.long.is_some()).copied().collect();
        long.sort_by_key(|r| r.long);
        let mut list: Vec<RefPic> = short.into_iter().chain(long).collect();
        let n = s.num_ref_l0_m1 as usize + 1;
        // 8.2.4.3: modifications
        let curr = s.frame_num as i64;
        let max = max_frame_num as i64;
        let mut pred = curr;
        for (idx, &(idc, val)) in s.mods.iter().enumerate() {
            let pick = match idc {
                0 | 1 => {
                    let diff = val as i64 + 1;
                    let mut nowrap = if idc == 0 { pred - diff } else { pred + diff };
                    if nowrap < 0 {
                        nowrap += max;
                    } else if nowrap >= max {
                        nowrap -= max;
                    }
                    pred = nowrap;
                    let pn = if nowrap > curr { nowrap - max } else { nowrap };
                    self.dpb.iter().find(|r| r.long.is_none() && Self::pic_num(r, s.frame_num, max_frame_num) == pn).copied()
                }
                _ => self.dpb.iter().find(|r| r.long == Some(val)).copied(),
            };
            let Some(p) = pick else { bail!("reference list modification names a missing picture") };
            if idx > list.len() {
                break;
            }
            list.insert(idx, p);
            // remove the later duplicate of p
            let mut k = idx + 1;
            while k < list.len() {
                if list[k].surface == p.surface {
                    list.remove(k);
                } else {
                    k += 1;
                }
            }
        }
        list.truncate(n);
        anyhow::ensure!(!list.is_empty(), "P slice without any reference picture");
        Ok(list)
    }

    fn mark(&mut self, sps: &Sps, s: &Slice, cur: RefPic) {
        let max_frame_num = 1u32 << sps.log2_max_frame_num;
        let mut cur = cur;
        if s.idr {
            self.dpb.clear();
            if s.long_term_ref {
                cur.long = Some(0);
                self.max_long_idx = Some(0);
            } else {
                self.max_long_idx = None;
            }
        } else if !s.mmcos.is_empty() {
            for m in &s.mmcos {
                match *m {
                    Mmco::UnmarkShort(d) => {
                        let pn = s.frame_num as i64 - (d as i64 + 1);
                        self.dpb.retain(|r| !(r.long.is_none() && Self::pic_num(r, s.frame_num, max_frame_num) == pn));
                    }
                    Mmco::UnmarkLong(n) => self.dpb.retain(|r| r.long != Some(n)),
                    Mmco::ShortToLong(d, idx) => {
                        let pn = s.frame_num as i64 - (d as i64 + 1);
                        self.dpb.retain(|r| r.long != Some(idx) || Self::pic_num(r, s.frame_num, max_frame_num) == pn);
                        for r in self.dpb.iter_mut() {
                            if r.long.is_none() && Self::pic_num(r, s.frame_num, max_frame_num) == pn {
                                r.long = Some(idx);
                            }
                        }
                    }
                    Mmco::MaxLong(v) => {
                        self.max_long_idx = v.checked_sub(1);
                        let max = self.max_long_idx;
                        self.dpb.retain(|r| match (r.long, max) {
                            (Some(i), Some(m)) => i <= m,
                            (Some(_), None) => false,
                            _ => true,
                        });
                    }
                    Mmco::All => {
                        self.dpb.clear();
                        self.max_long_idx = None;
                        cur.frame_num = 0;
                        cur.poc = 0;
                        self.prev_poc_msb = 0;
                        self.prev_poc_lsb = 0;
                        self.prev_frame_num_offset = 0;
                    }
                    Mmco::CurrentLong(idx) => {
                        self.dpb.retain(|r| r.long != Some(idx));
                        cur.long = Some(idx);
                    }
                }
            }
        } else {
            // sliding window
            let max = sps.num_ref_frames.max(1) as usize;
            while self.dpb.len() >= max {
                let Some((i, _)) = self
                    .dpb
                    .iter()
                    .enumerate()
                    .filter(|(_, r)| r.long.is_none())
                    .min_by_key(|(_, r)| Self::pic_num(r, s.frame_num, max_frame_num))
                else {
                    break;
                };
                self.dpb.remove(i);
            }
        }
        // never more than the pool allows
        let max = (sps.num_ref_frames.max(1) as usize).min(self.surfaces.len().saturating_sub(1));
        while self.dpb.len() >= max {
            self.dpb.remove(0);
        }
        self.dpb.push(cur);
    }

    /// Decode the slices of one picture; returns the surface it went into.
    fn decode_picture(&mut self, slices: &[(&[u8], Slice)]) -> anyhow::Result<(VASurfaceID, Sps)> {
        let (_, first) = &slices[0];
        let pps = self.ppss[first.pps_id as usize].clone().ok_or_else(|| anyhow!("missing PPS"))?;
        let sps = self.spss[pps.sps_id as usize].clone().ok_or_else(|| anyhow!("missing SPS"))?;
        anyhow::ensure!(sps.chroma_format_idc == 1 && sps.bit_depth_luma_m8 == 0 && sps.bit_depth_chroma_m8 == 0, "only 8-bit 4:2:0 is supported");
        if first.idr {
            self.ensure_context(&sps)?;
        }
        anyhow::ensure!(self.ctx != VA_INVALID_ID && self.dims.0 == sps.w_mbs && self.dims.1 == sps.h_mbs, "waiting for a keyframe");
        let max_frame_num = 1u32 << sps.log2_max_frame_num;
        if first.idr {
            self.prev_frame_num_offset = 0;
        }
        let poc = self.compute_poc(&sps, first)?;
        let surface = self.free_surface()?;
        // picture parameters
        // SAFETY: POD structs.
        let mut pp: VAPictureParameterBufferH264 = unsafe { std::mem::zeroed() };
        pp.CurrPic = invalid_pic();
        pp.CurrPic.picture_id = surface;
        pp.CurrPic.frame_idx = first.frame_num;
        pp.CurrPic.flags = 0;
        pp.CurrPic.TopFieldOrderCnt = poc;
        pp.CurrPic.BottomFieldOrderCnt = poc;
        for (i, r) in pp.ReferenceFrames.iter_mut().enumerate() {
            *r = match self.dpb.get(i) {
                Some(rp) if !first.idr => rp.va(0),
                _ => invalid_pic(),
            };
        }
        pp.picture_width_in_mbs_minus1 = (sps.w_mbs - 1) as u16;
        pp.picture_height_in_mbs_minus1 = (sps.h_mbs - 1) as u16;
        pp.num_ref_frames = sps.num_ref_frames as u8;
        // SAFETY: bitfields of POD unions.
        unsafe {
            let b = &mut pp.seq_fields.bits;
            b.set_chroma_format_idc(sps.chroma_format_idc);
            b.set_residual_colour_transform_flag(sps.separate_colour_plane as u32);
            b.set_gaps_in_frame_num_value_allowed_flag(sps.gaps_allowed as u32);
            b.set_frame_mbs_only_flag(sps.frame_mbs_only as u32);
            b.set_mb_adaptive_frame_field_flag(0);
            b.set_direct_8x8_inference_flag(sps.direct_8x8 as u32);
            b.set_MinLumaBiPredSize8x8((sps.level_idc >= 31) as u32);
            b.set_log2_max_frame_num_minus4(sps.log2_max_frame_num - 4);
            b.set_pic_order_cnt_type(sps.poc_type);
            b.set_log2_max_pic_order_cnt_lsb_minus4(sps.log2_max_poc_lsb.saturating_sub(4));
            b.set_delta_pic_order_always_zero_flag(sps.delta_pic_order_always_zero as u32);
            let f = &mut pp.pic_fields.bits;
            f.set_entropy_coding_mode_flag(pps.entropy as u32);
            f.set_weighted_pred_flag(pps.weighted_pred as u32);
            f.set_weighted_bipred_idc(pps.weighted_bipred_idc);
            f.set_transform_8x8_mode_flag(pps.transform_8x8 as u32);
            f.set_field_pic_flag(0);
            f.set_constrained_intra_pred_flag(pps.constrained_intra as u32);
            f.set_pic_order_present_flag(pps.bottom_field_pic_order_present as u32);
            f.set_deblocking_filter_control_present_flag(pps.deblocking_ctrl as u32);
            f.set_redundant_pic_cnt_present_flag(pps.redundant_pic_cnt_present as u32);
            f.set_reference_pic_flag((first.nal_ref_idc != 0) as u32);
        }
        pp.pic_init_qp_minus26 = pps.pic_init_qp_m26 as i8;
        pp.pic_init_qs_minus26 = pps.pic_init_qs_m26 as i8;
        pp.chroma_qp_index_offset = pps.chroma_qp_index_offset as i8;
        pp.second_chroma_qp_index_offset = pps.second_chroma_qp_index_offset as i8;
        pp.frame_num = first.frame_num as u16;
        // scaling matrices: parsed in zig-zag (bitstream) order, VA wants raster
        // order (as GStreamer does; verified bit-exact with x264 cqm=jvt)
        let sc = pps.scaling.or(sps.scaling).unwrap_or_else(Scaling::flat);
        let mut iq: VAIQMatrixBufferH264 = unsafe { std::mem::zeroed() };
        for i in 0..6 {
            for (j, &z) in ZIGZAG_4X4.iter().enumerate() {
                iq.ScalingList4x4[i][z as usize] = sc.l4[i][j];
            }
        }
        for i in 0..2 {
            for (j, &z) in ZIGZAG_8X8.iter().enumerate() {
                iq.ScalingList8x8[i][z as usize] = sc.l8[i][j];
            }
        }
        let mut bufs = vec![];
        let res = (|| -> anyhow::Result<()> {
            bufs.push(self.d.create_buffer(self.ctx, VAPictureParameterBufferType, &pp)?);
            bufs.push(self.d.create_buffer(self.ctx, VAIQMatrixBufferType, &iq)?);
            for (nal, s) in slices {
                anyhow::ensure!(s.frame_num == first.frame_num, "slices of different pictures in one access unit");
                let mut sp: VASliceParameterBufferH264 = unsafe { std::mem::zeroed() };
                sp.slice_data_size = nal.len() as u32;
                sp.slice_data_offset = 0;
                sp.slice_data_flag = VA_SLICE_DATA_FLAG_ALL;
                sp.slice_data_bit_offset = s.header_bits.min(u16::MAX as usize) as u16;
                sp.first_mb_in_slice = s.first_mb as u16;
                sp.slice_type = s.slice_type as u8;
                sp.num_ref_idx_l0_active_minus1 = if s.slice_type == 0 { s.num_ref_l0_m1 as u8 } else { 0 };
                sp.cabac_init_idc = s.cabac_init_idc as u8;
                sp.slice_qp_delta = s.qp_delta as i8;
                sp.disable_deblocking_filter_idc = s.disable_deblock as u8;
                sp.slice_alpha_c0_offset_div2 = s.alpha as i8;
                sp.slice_beta_offset_div2 = s.beta as i8;
                for r in sp.RefPicList0.iter_mut().chain(sp.RefPicList1.iter_mut()) {
                    *r = invalid_pic();
                }
                if s.slice_type == 0 {
                    for (i, r) in self.ref_list0(s, max_frame_num)?.iter().enumerate().take(32) {
                        sp.RefPicList0[i] = r.va(0);
                    }
                    if let Some(w) = &s.weights {
                        sp.luma_log2_weight_denom = w.luma_denom as u8;
                        sp.chroma_log2_weight_denom = w.chroma_denom as u8;
                        sp.luma_weight_l0_flag = w.luma_flag as u8;
                        sp.chroma_weight_l0_flag = w.chroma_flag as u8;
                        for (i, (wt, off)) in w.luma.iter().enumerate().take(32) {
                            sp.luma_weight_l0[i] = *wt as i16;
                            sp.luma_offset_l0[i] = *off as i16;
                        }
                        for (i, c) in w.chroma.iter().enumerate().take(32) {
                            for (k, (wt, off)) in c.iter().enumerate() {
                                sp.chroma_weight_l0[i][k] = *wt as i16;
                                sp.chroma_offset_l0[i][k] = *off as i16;
                            }
                        }
                    }
                }
                bufs.push(self.d.create_buffer(self.ctx, VASliceParameterBufferType, &sp)?);
                bufs.push(self.d.create_buffer_raw(self.ctx, VASliceDataBufferType, nal.as_ptr().cast(), nal.len())?);
            }
            self.d.render(self.ctx, surface, &mut bufs)
        })();
        self.d.destroy_buffers(&mut bufs);
        res?;
        if sps.poc_type != 0 || first.nal_ref_idc != 0 {
            self.prev_frame_num = first.frame_num;
        }
        if first.nal_ref_idc != 0 {
            self.mark(&sps, first, RefPic { surface, frame_num: first.frame_num, long: None, poc });
        }
        Ok((surface, sps))
    }

    /// Copy the cropped NV12 picture out of `surface` into `self.out`.
    fn read_back(&mut self, surface: VASurfaceID, sps: &Sps) -> anyhow::Result<(usize, usize)> {
        let img = *self.image.as_ref().ok_or_else(|| anyhow!("no image"))?;
        let (aw, ah) = (sps.w_mbs * 16, sps.h_mbs * 16);
        // SAFETY: valid surface/image of this display.
        let st = unsafe { (self.d.api.vaGetImage)(self.d.dpy, surface, 0, 0, aw, ah, img.image_id) };
        self.d.check(st, "vaGetImage")?;
        // crop in 2-sample units (4:2:0 progressive); checked (peer data)
        let (cl, cr, ct, cb) = (sps.crop.0 as usize, sps.crop.1 as usize, sps.crop.2 as usize, sps.crop.3 as usize);
        let crop = |a: usize, b: usize, full: u32| a.checked_add(b).and_then(|s| s.checked_mul(2)).and_then(|c| (full as usize).checked_sub(c));
        let (Some(w), Some(h), Some(x0), Some(y0)) = (crop(cl, cr, aw), crop(ct, cb, ah), cl.checked_mul(2), ct.checked_mul(2)) else {
            bail!("bad cropping")
        };
        anyhow::ensure!(w >= 2 && h >= 2, "bad cropping");
        let mut p: *mut c_void = null_mut();
        // SAFETY: map the image buffer.
        self.d.check(unsafe { (self.d.api.vaMapBuffer)(self.d.dpy, img.buf, &mut p) }, "vaMapBuffer (image)")?;
        let res = (|| -> anyhow::Result<()> {
            let size = img.data_size as usize;
            // SAFETY: mapped buffer of `data_size` bytes.
            let src = unsafe { std::slice::from_raw_parts(p as *const u8, size) };
            let (yp, yo, cp, co) = (img.pitches[0] as usize, img.offsets[0] as usize, img.pitches[1] as usize, img.offsets[1] as usize);
            let cw = w.div_ceil(2) * 2;
            let ch = h.div_ceil(2);
            // end of the last row read from a plane: off + (row0 + rows - 1) * pitch + x0 + cols
            let end = |off: usize, row0: usize, rows: usize, pitch: usize, cols: usize| {
                (row0 + rows - 1).checked_mul(pitch).and_then(|v| v.checked_add(off)).and_then(|v| v.checked_add(x0)).and_then(|v| v.checked_add(cols))
            };
            let fits = |e: Option<usize>| e.is_some_and(|e| e <= size);
            anyhow::ensure!(yp >= w && cp >= cw && fits(end(yo, y0, h, yp, w)) && fits(end(co, y0 / 2, ch, cp, cw)), "VA image too small");
            self.out.resize(w * h + cw * ch, 0);
            let (yd, cd) = self.out.split_at_mut(w * h);
            for r in 0..h {
                let s = yo + (y0 + r) * yp + x0;
                yd[r * w..(r + 1) * w].copy_from_slice(&src[s..s + w]);
            }
            for r in 0..ch {
                let s = co + (y0 / 2 + r) * cp + x0;
                cd[r * cw..(r + 1) * cw].copy_from_slice(&src[s..s + cw]);
            }
            Ok(())
        })();
        // SAFETY: mapped above.
        unsafe { (self.d.api.vaUnmapBuffer)(self.d.dpy, img.buf) };
        res?;
        Ok((w, h))
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        self.teardown_context();
        // SAFETY: config of this display, destroyed once.
        unsafe { (self.d.api.vaDestroyConfig)(self.d.dpy, self.config) };
    }
}

impl DecBackend for Decoder {
    fn hardware(&self) -> bool {
        true
    }

    fn decode(&mut self, au: &[u8]) -> anyhow::Result<Option<YuvView<'_>>> {
        let _ = self.profile;
        let mut slices: Vec<(&[u8], Slice)> = vec![];
        let mut last: Option<(VASurfaceID, Sps)> = None;
        for nal in nals(au) {
            if nal.is_empty() {
                continue;
            }
            match nal_type(nal) {
                7 => {
                    let (id, sps) = parse_sps(nal)?;
                    let changed = self.spss[id as usize].as_ref().is_none_or(|old| old.raw != sps.raw);
                    if changed {
                        self.spss[id as usize] = Some(sps);
                    }
                }
                8 => {
                    let (id, pps) = parse_pps(nal, &self.spss)?;
                    self.ppss[id as usize] = Some(pps);
                }
                1 | 5 => {
                    let s = parse_slice(nal, &self.spss, &self.ppss)?;
                    if s.first_mb == 0 && !slices.is_empty() {
                        last = Some(self.decode_picture(&slices)?);
                        slices.clear();
                    }
                    slices.push((nal, s));
                }
                _ => {}
            }
        }
        if !slices.is_empty() {
            last = Some(self.decode_picture(&slices)?);
        }
        let Some((surface, sps)) = last else { return Ok(None) };
        let (w, h) = self.read_back(surface, &sps)?;
        let cw = w.div_ceil(2) * 2;
        let (y, c) = self.out.split_at(w * h);
        Ok(Some(YuvView { w, h, y, y_stride: w, u: c, v: &c[1..], uv_stride: cw, uv_step: 2 }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codec::{EncParams, VideoFormat};
    use crate::video::ContentHint;

    fn pattern(w: usize, h: usize, t: usize) -> I420Buf {
        let mut p = I420Buf::new(w, h);
        for y in 0..h {
            for x in 0..w {
                p.y[y * w + x] = (((x + t * 4) ^ (y + t)) % 200 + 20) as u8;
            }
        }
        for y in 0..h / 2 {
            for x in 0..w / 2 {
                p.u[y * (w / 2) + x] = (100 + (x + t) % 50) as u8;
                p.v[y * (w / 2) + x] = (140 - (y % 40)) as u8;
            }
        }
        p
    }

    fn psnr_y(a: &[u8], b: &[u8]) -> f64 {
        let mse = a.iter().zip(b).map(|(x, y)| ((*x as f64) - (*y as f64)).powi(2)).sum::<f64>() / a.len() as f64;
        if mse == 0.0 { 99.0 } else { 10.0 * (255.0 * 255.0 / mse).log10() }
    }

    fn params(w: usize, h: usize, kbps: u32) -> EncParams {
        EncParams { w, h, fps: 30, bitrate_kbps: kbps, content: ContentHint::Motion, threads: 0, keyframe_interval_s: 2 }
    }

    /// Encode with VA-API, decode with the VA-API decoder; sizes, PSNR,
    /// keyframes, bitrate change. Skips on machines without a VA-API H.264 GPU.
    /// SPS NAL (no start code) with the given raw syntax values; `extra`
    /// writes everything after pic_height_in_map_units_minus1.
    fn sps_nal(poc_lsb_m4: u32, w_m1: u32, h_m1: u32, extra: impl FnOnce(&mut Bw)) -> Vec<u8> {
        let mut b = Bw::default();
        b.u(8, 66);
        b.u(8, 0xc0);
        b.u(8, 30);
        b.ue(0); // id
        b.ue(0); // log2_max_frame_num - 4
        b.ue(0); // poc type 0
        b.ue(poc_lsb_m4);
        b.ue(1); // refs
        b.u(1, 0);
        b.ue(w_m1);
        b.ue(h_m1);
        extra(&mut b);
        b.finish_nal(0x67)[4..].to_vec()
    }

    fn progressive(crop: Option<[u32; 4]>) -> impl FnOnce(&mut Bw) {
        move |b: &mut Bw| {
            b.u(1, 1); // frame_mbs_only
            b.u(1, 1); // direct 8x8
            match crop {
                Some(c) => {
                    b.u(1, 1);
                    for v in c {
                        b.ue(v);
                    }
                }
                None => b.u(1, 0),
            }
            b.u(1, 0); // no VUI
        }
    }

    /// Hostile SPS/PPS/slice header values: errors, never an overflow panic
    /// (tests run with overflow checks) and never a picture above the cap.
    #[test]
    fn vaapi_parsers_reject_hostile_values() {
        const BIG: u32 = u32::MAX - 1; // largest Exp-Golomb value
        let ok = parse_sps(&sps_nal(12, 79, 44, progressive(Some([0, 0, 0, 0])))).unwrap().1;
        assert_eq!((ok.w_mbs, ok.h_mbs, ok.log2_max_poc_lsb), (80, 45, 16));
        // 4096x2304 is the cap; one macroblock more is rejected
        assert!(parse_sps(&sps_nal(0, 255, 143, progressive(None))).is_ok());
        assert!(parse_sps(&sps_nal(0, 256, 143, progressive(None))).is_err());
        assert!(parse_sps(&sps_nal(0, 143, 255, progressive(None))).is_ok()); // portrait 2304x4096
        assert!(parse_sps(&sps_nal(0, 143, 256, progressive(None))).is_err());
        for (w, h) in [(511, 511), (512, 10), (10, 512), (BIG, 10), (10, BIG), (1 << 20, 1 << 20)] {
            assert!(parse_sps(&sps_nal(0, w, h, progressive(None))).is_err(), "{w}x{h}");
        }
        // huge log2_max_poc_lsb / crop values / crop sum overflow / crop ≥ picture
        assert!(parse_sps(&sps_nal(BIG, 10, 10, progressive(None))).is_err());
        assert!(parse_sps(&sps_nal(13, 10, 10, progressive(None))).is_err());
        for c in [[BIG, BIG, 0, 0], [0, 0, BIG, BIG], [BIG, 0, 0, 0], [88, 0, 0, 0], [0, 0, 44, 44]] {
            assert!(parse_sps(&sps_nal(0, 10, 10, progressive(Some(c)))).is_err(), "crop {c:?}");
        }
        assert!(parse_sps(&sps_nal(0, 10, 10, progressive(Some([43, 44, 0, 0])))).is_ok());
        // interlaced: 2 * 300 map units is more than 512 MBs
        assert!(parse_sps(&sps_nal(0, 10, 299, |b: &mut Bw| {
            b.u(1, 0);
            b.u(1, 0);
            b.u(1, 1);
            b.u(1, 0);
            b.u(1, 0);
        }))
        .is_err());
        // huge ue in the other SPS fields
        let mut b = Bw::default();
        b.u(24, 0x42c01e);
        b.ue(BIG);
        assert!(parse_sps(&b.finish_nal(0x67)[4..]).is_err());
        for field in 0..4 {
            let mut b = Bw::default();
            b.u(24, 0x42c01e);
            b.ue(0);
            for f in 0..4 {
                b.ue(if f == field { BIG } else { 0 }); // log2_max_frame_num, poc type, poc lsb, refs
            }
            b.u(1, 0);
            b.ue(10);
            b.ue(10);
            progressive(None)(&mut b);
            assert!(parse_sps(&b.finish_nal(0x67)[4..]).is_err(), "field {field}");
        }
        // scaling list with a huge delta_scale (High profile)
        for delta in [BIG, BIG - 1, 256, 255] {
            let mut b = Bw::default();
            b.u(24, 0x640028);
            b.ue(0);
            b.ue(1);
            b.ue(0);
            b.ue(0);
            b.u(1, 0);
            b.u(1, 1); // seq_scaling_matrix_present
            b.u(1, 1); // list 0 present
            b.ue(delta);
            assert!(parse_sps(&b.finish_nal(0x67)[4..]).is_err(), "delta {delta}");
        }

        // PPS: QP / chroma offsets out of range
        let spss: Vec<Option<Sps>> = std::iter::once(Some(ok.clone())).chain(std::iter::repeat_n(None, 31)).collect();
        let pps = |qp: u32, cqo: u32| {
            let mut b = Bw::default();
            b.ue(0);
            b.ue(0);
            b.u(1, 0);
            b.u(1, 0);
            b.ue(0);
            b.ue(0);
            b.ue(0);
            b.u(1, 0);
            b.u(2, 0);
            b.ue(qp); // pic_init_qp_minus26 (se code number)
            b.ue(0);
            b.ue(cqo);
            b.u(1, 1);
            b.u(1, 0);
            b.u(1, 0);
            b.finish_nal(0x68)[4..].to_vec()
        };
        assert!(parse_pps(&pps(0, 0), &spss).is_ok());
        for (qp, cqo) in [(BIG, 0), (BIG - 1, 0), (200, 0), (0, BIG), (0, 25)] {
            assert!(parse_pps(&pps(qp, cqo), &spss).is_err(), "qp {qp} cqo {cqo}");
        }
        let ppss: Vec<Option<Pps>> = std::iter::once(Some(parse_pps(&pps(0, 0), &spss).unwrap().1)).chain(std::iter::repeat_n(None, 255)).collect();

        // slice header: first_mb beyond the picture, huge qp_delta, huge
        // reordering / MMCO values, huge redundant fields
        let slice = |first_mb: u32, qp_delta: u32| {
            let mut b = Bw::default();
            b.ue(first_mb);
            b.ue(7); // I slice
            b.ue(0); // pps
            b.u(4, 0); // frame_num
            b.ue(0); // idr_pic_id
            b.u(16, 0); // poc lsb
            b.u(1, 0);
            b.u(1, 0); // dec_ref_pic_marking
            b.ue(qp_delta);
            for _ in 0..3 {
                b.ue(0); // deblocking idc, alpha, beta
            }
            b.finish_nal(0x65)[4..].to_vec()
        };
        assert!(parse_slice(&slice(0, 0), &spss, &ppss).is_ok());
        for (mb, qpd) in [(80 * 45, 0), (BIG, 0), (0, BIG), (0, BIG - 1), (0, 200)] {
            assert!(parse_slice(&slice(mb, qpd), &spss, &ppss).is_err(), "mb {mb} qpd {qpd}");
        }
        let p_slice = |mod_val: u32, mmco_val: u32| {
            let mut b = Bw::default();
            b.ue(0);
            b.ue(5); // P slice
            b.ue(0);
            b.u(4, 1); // frame_num
            b.u(16, 2); // poc lsb
            b.u(1, 0); // num_ref_idx_override
            b.u(1, 1); // ref_pic_list_modification_flag
            b.ue(0);
            b.ue(mod_val);
            b.ue(3);
            b.u(1, 1); // adaptive_ref_pic_marking
            b.ue(1);
            b.ue(mmco_val);
            b.ue(0);
            for _ in 0..4 {
                b.ue(0); // qp delta, deblocking idc, alpha, beta
            }
            b.finish_nal(0x41)[4..].to_vec()
        };
        assert!(parse_slice(&p_slice(0, 0), &spss, &ppss).is_ok());
        for (m, k) in [(BIG, 0), (16, 0), (0, BIG), (0, 16)] {
            assert!(parse_slice(&p_slice(m, k), &spss, &ppss).is_err(), "mod {m} mmco {k}");
        }

        // pseudo-random garbage through every parser: no panic
        let mut x = 0x2545_f491_4f6c_dd1du64;
        for i in 0..20_000 {
            let len = 1 + (i % 40);
            let mut nal = Vec::with_capacity(len);
            for _ in 0..len {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                nal.push(x as u8);
            }
            nal[0] = [0x67, 0x68, 0x65, 0x41][i % 4];
            let _ = parse_sps(&nal);
            let _ = parse_pps(&nal, &spss);
            let _ = parse_slice(&nal, &spss, &ppss);
        }
    }

    /// POC arithmetic on hostile slice values: an error, not an i32 overflow.
    #[test]
    fn vaapi_poc_overflow_is_an_error() {
        let Ok(mut dec) = Decoder::new() else {
            eprintln!("SKIP: no VA-API decoder");
            return;
        };
        let sps = parse_sps(&sps_nal(12, 79, 44, progressive(None))).unwrap().1;
        let slice = |lsb: u32, dpb: i32, idr: bool| Slice {
            first_mb: 0,
            slice_type: 0,
            pps_id: 0,
            frame_num: 0,
            idr,
            nal_ref_idc: 1,
            poc_lsb: lsb,
            delta_poc_bottom: dpb,
            num_ref_l0_m1: 0,
            mods: vec![],
            weights: None,
            long_term_ref: false,
            mmcos: vec![],
            cabac_init_idc: 0,
            qp_delta: 0,
            disable_deblock: 0,
            alpha: 0,
            beta: 0,
            header_bits: 0,
        };
        assert_eq!(dec.compute_poc(&sps, &slice(4, 0, true)).unwrap(), 4);
        // bottom field POC below i32::MIN
        dec.prev_poc_msb = i32::MIN + 10;
        dec.prev_poc_lsb = 10;
        assert!(dec.compute_poc(&sps, &slice(10, -100, false)).is_err());
        // msb keeps growing on a wrapping lsb: stops with an error at the i32 limit
        dec.prev_poc_msb = i32::MAX - 65_535;
        dec.prev_poc_lsb = 65_000;
        assert!(dec.compute_poc(&sps, &slice(10, 0, false)).is_err());
        dec.prev_poc_msb = i32::MIN + 10;
        dec.prev_poc_lsb = 10;
        assert!(dec.compute_poc(&sps, &slice(65_000, 0, false)).is_err());
        // poc type 2: frame_num_offset growth
        let mut sps2 = sps.clone();
        sps2.poc_type = 2;
        dec.prev_frame_num = 15;
        dec.prev_frame_num_offset = i64::MAX - 3;
        assert!(dec.compute_poc(&sps2, &Slice { frame_num: 1, ..slice(0, 0, false) }).is_err());
        dec.prev_frame_num_offset = i32::MAX as i64;
        assert!(dec.compute_poc(&sps2, &Slice { frame_num: 1, ..slice(0, 0, false) }).is_err());
        // a hostile SPS through the public decode path: an error, nothing allocated
        let au = [&[0u8, 0, 0, 1][..], &sps_nal(0, 511, 511, progressive(None))].concat();
        assert!(dec.decode(&au).is_err());
        let au = [&[0u8, 0, 0, 1][..], &sps_nal(0, 10, 10, progressive(Some([BIG_CROP, BIG_CROP, 0, 0])))].concat();
        assert!(dec.decode(&au).is_err());
    }

    const BIG_CROP: u32 = u32::MAX - 1;

    #[test]
    fn vaapi_roundtrip() {
        let (w, h) = (320, 240);
        let mut enc = match Encoder::new(&params(w, h, 1500)) {
            Ok(e) => e,
            Err(e) => {
                eprintln!("skipped: {e:#}");
                return;
            }
        };
        let mut dec = Decoder::new().expect("decoder next to a working encoder");
        let mut stream = Vec::new();
        let (mut keys, mut decoded, mut best) = (0, 0, 0.0f64);
        for t in 0..60 {
            if t == 30 {
                enc.set_bitrate(600);
            }
            let mut pic = pattern(w, h, t);
            let src = pic.y.clone();
            let (au, key) = enc.encode(&mut pic, t as u64 * 33_333, t == 0 || t == 40).unwrap().expect("one AU per frame");
            if t == 0 {
                assert!(key && super::super::annexb::has_idr(&au));
                assert!(nals(&au).any(|n| nal_type(n) == 7), "IDR must carry an SPS");
            }
            if t == 40 {
                assert!(key, "forced keyframe");
            }
            keys += key as u32;
            stream.extend_from_slice(&au);
            if let Some(v) = dec.decode(&au).unwrap() {
                assert_eq!((v.w, v.h), (w, h));
                let mut y = vec![0u8; w * h];
                for r in 0..h {
                    y[r * w..(r + 1) * w].copy_from_slice(&v.y[r * v.y_stride..r * v.y_stride + w]);
                }
                let p = psnr_y(&src, &y);
                best = best.max(p);
                assert!(p > 30.0, "frame {t}: PSNR {p:.1} dB");
                decoded += 1;
            }
        }
        assert!(keys >= 2, "keys={keys}");
        assert_eq!(decoded, 60);
        // size change (not a multiple of 16 → SPS cropping) on the same decoder
        let (w2, h2) = (202, 150);
        let mut enc2 = Encoder::new(&params(w2, h2, 800)).unwrap();
        for t in 0..5 {
            let mut pic = pattern(w2, h2, t);
            let src = pic.y.clone();
            let (au, _) = enc2.encode(&mut pic, t as u64 * 33_333, t == 0).unwrap().unwrap();
            stream.extend_from_slice(&au);
            let v = dec.decode(&au).unwrap().expect("picture after resize");
            assert_eq!((v.w, v.h), (w2, h2));
            let mut y = vec![0u8; w2 * h2];
            for r in 0..h2 {
                y[r * w2..(r + 1) * w2].copy_from_slice(&v.y[r * v.y_stride..r * v.y_stride + w2]);
            }
            assert!(psnr_y(&src, &y) > 30.0);
        }
        // garbage must be an error, not a panic
        let _ = dec.decode(&[0, 0, 0, 1, 0x65, 0xff, 0x00, 0x13]);
        assert!(dec.decode(&[0, 0, 0, 1, 0x67, 0x42]).is_err());
        eprintln!("VA-API roundtrip ok: 60 frames, {} bytes, best PSNR {best:.1} dB", stream.len());
        if let Ok(p) = std::env::var("LUMORA_VAAPI_DUMP") {
            std::fs::write(p, &stream).unwrap();
        }
    }

    /// The public API on Linux picks VA-API for H.264.
    #[test]
    fn video_api_uses_vaapi() {
        if Encoder::new(&params(64, 64, 500)).is_err() {
            eprintln!("skipped: no VA-API encoder");
            return;
        }
        let cfg = crate::EncoderConfig { fps: 30, bitrate_kbps: 1000, format: VideoFormat::H264, ..Default::default() };
        let mut enc = crate::VideoEncoder::with_config(cfg).unwrap();
        let mut dec = crate::VideoDecoder::new().unwrap();
        let mut got = 0;
        for t in 0..10u32 {
            let mut d = vec![0u8; 320 * 240 * 4];
            for (i, px) in d.chunks_exact_mut(4).enumerate() {
                px.copy_from_slice(&[(i % 320) as u8, ((i / 320) as u32 + t) as u8, 128, 255]);
            }
            let f = crate::Frame { width: 320, height: 240, stride: 320 * 4, format: crate::PixelFormat::Rgba, data: d.into(), ts_us: t as u64 * 33_333 };
            let e = enc.encode(&f, t == 0).unwrap().unwrap();
            assert_eq!(e.codec, VideoFormat::H264);
            if let Ok(Some(out)) = dec.decode_as(e.codec, &e.data) {
                assert_eq!((out.width, out.height), (320, 240));
                got += 1;
            }
        }
        let va = crate::codec::CodecKind::VaApi;
        assert_eq!(enc.backend(), Some((VideoFormat::H264, va)));
        assert_eq!(dec.backend(), Some((VideoFormat::H264, va)));
        assert_eq!(got, 10);
    }

    /// Decode an external Annex-B stream (`LUMORA_H264_IN`, e.g. from ffmpeg/x264
    /// or OpenH264 with several slices) and compare with `LUMORA_H264_REF`
    /// (raw I420 of the same frames, e.g. `ffmpeg -i in.h264 -f rawvideo ref.yuv`).
    #[test]
    fn vaapi_decodes_foreign_stream() {
        let (Ok(inp), Ok(refp)) = (std::env::var("LUMORA_H264_IN"), std::env::var("LUMORA_H264_REF")) else { return };
        let data = std::fs::read(inp).unwrap();
        let reference = std::fs::read(refp).unwrap();
        let mut dec = Decoder::new().unwrap();
        // split into access units at AUD (9) or at each first slice of a picture
        let mut aus: Vec<Vec<u8>> = vec![];
        let mut cur = vec![];
        for n in nals(&data) {
            let t = nal_type(n);
            let new_pic = t == 9 || ((t == 1 || t == 5) && n.len() > 1 && n[1] & 0x80 != 0 && cur.iter().any(|x: &Vec<u8>| matches!(nal_type(x), 1 | 5)));
            let starts_params = (t == 7 || t == 8) && cur.iter().any(|x: &Vec<u8>| matches!(nal_type(x), 1 | 5));
            if (new_pic || starts_params) && !cur.is_empty() {
                aus.push(cur.iter().flat_map(|x: &Vec<u8>| [&[0u8, 0, 0, 1][..], &x[..]].concat()).collect());
                cur.clear();
            }
            cur.push(n.to_vec());
        }
        if !cur.is_empty() {
            aus.push(cur.iter().flat_map(|x: &Vec<u8>| [&[0u8, 0, 0, 1][..], &x[..]].concat()).collect());
        }
        let mut n = 0;
        let mut worst = 99.0f64;
        for au in &aus {
            if let Some(v) = dec.decode(au).unwrap() {
                let fs = v.w * v.h * 3 / 2;
                let r = &reference[n * fs..n * fs + v.w * v.h];
                let mut y = vec![0u8; v.w * v.h];
                for row in 0..v.h {
                    y[row * v.w..(row + 1) * v.w].copy_from_slice(&v.y[row * v.y_stride..row * v.y_stride + v.w]);
                }
                worst = worst.min(psnr_y(r, &y));
                n += 1;
            }
        }
        eprintln!("decoded {n} of {} access units, worst luma PSNR vs reference {worst:.1} dB", aus.len());
        assert!(n + 1 >= aus.len() && worst > 45.0, "n={n} worst={worst}");
    }

    /// Release-mode throughput: `cargo test --release -p lumora-media --lib vaapi_speed -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn vaapi_speed() {
        for (w, h, kbps) in [(1920usize, 1080usize, 8000u32), (2560, 1440, 12000)] {
            let Ok(mut enc) = Encoder::new(&EncParams { fps: 60, ..params(w, h, kbps) }) else {
                eprintln!("skipped: no VA-API encoder");
                return;
            };
            let pics: Vec<I420Buf> = (0..8).map(|t| pattern(w, h, t)).collect();
            let mut dec = Decoder::new().unwrap();
            let n = 120;
            let mut aus = vec![];
            let mut up = std::time::Duration::ZERO;
            let t0 = std::time::Instant::now();
            for i in 0..n {
                let mut p = pics[i % 8].clone();
                let t1 = std::time::Instant::now();
                enc.upload(&p).unwrap();
                up += t1.elapsed();
                aus.push(enc.encode(&mut p, i as u64 * 16_666, i == 0).unwrap().unwrap().0);
            }
            let enc_ms = t0.elapsed().as_secs_f64() * 1000.0 / n as f64;
            let up_ms = up.as_secs_f64() * 1000.0 / n as f64;
            let t0 = std::time::Instant::now();
            for au in &aus {
                dec.decode(au).unwrap().unwrap();
            }
            let dec_ms = t0.elapsed().as_secs_f64() * 1000.0 / n as f64;
            let kb: usize = aus.iter().map(|a| a.len()).sum::<usize>() / 1024;
            // encode() uploads again internally: subtract the measured upload once
            eprintln!(
                "{w}x{h}: encode {:.2} ms/frame incl. upload {:.2} ms ({:.0} fps), decode+readback {dec_ms:.2} ms ({:.0} fps), {kb} KiB for {n} frames",
                enc_ms - up_ms,
                up_ms,
                1000.0 / (enc_ms - up_ms),
                1000.0 / dec_ms
            );
        }
    }
}
