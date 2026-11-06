//! Real-time camera effects for video calls: **beauty** ("Làm đẹp"), automatic
//! **low-light boost** ("Tăng sáng") and **mirroring** ("Lật hình").
//!
//! Everything runs on the *sender*, on the I420 picture right before it goes
//! into the H.264 encoder, so the other side sees the result without needing
//! the feature. Pure Rust, no ML, no extra dependencies, no per-frame
//! allocation (all scratch buffers live in [`VideoFx`] and are only resized
//! when the geometry or the internal quality level changes).
//!
//! ## Beauty (skin smoothing)
//!
//! A *fast guided filter* (He & Sun, 2015) on luma, self-guided (`I = p = Y`):
//!
//! 1. Downsample `Y` and `Y²` by block averaging (factor `f`, 5 at 720p) — the
//!    `Y²` mean keeps the variance *inside* each block, so thin details such as
//!    eyelashes, brows and hair strands still register as "edges" even though
//!    they vanish in the small picture.
//! 2. At low resolution, with O(1)-per-pixel box filters of radius `r`:
//!    `var = box(Y²) − box(Y)²`, `a = var / (var + ε)`, `b = (1 − a)·box(Y)`,
//!    then `ā = box(a)`, `b̄ = box(b)`. Where the window holds an edge
//!    (`var ≫ ε`) `a → 1` and the pixel is kept; on smooth skin `a → 0` and the
//!    pixel is replaced by its local mean (blemishes and sensor noise go away).
//! 3. A soft YCbCr skin-tone mask (box-filtered so it never has hard borders)
//!    and the level's strength are folded into the coefficients:
//!    `A = 1 − w·(1 − ā)`, `B = w·b̄ + …`, so the final full-resolution pass is a
//!    single `out = lut[A·Y + B]` with `A`,`B` bilinearly upsampled — one
//!    multiply-add per pixel plus the tone curve.
//!
//! The tone curve (a 256-entry LUT) adds a slight brightness lift and a gentle
//! S-shaped contrast; a chroma LUT adds a little warmth and saturation.
//!
//! ## Low-light boost
//!
//! Mean luma is measured on the *input* (so the effect never feeds back into
//! itself). Below ~38 % a gamma with a shadow toe (`((x+k)^γ − k^γ)/…`, which
//! bounds the slope — and thus noise gain — near black) brightens the picture.
//! `γ` follows its target with an exponential moving average, a per-frame step
//! limit and a dead band, so it neither flickers nor pumps.
//!
//! ## Mirror
//!
//! Row reversal of all three planes. The local preview is mirrored by the
//! caller (see [`preview_rgba`]); mirroring the *sent* picture is an option,
//! off by default so text held up to the camera reads correctly on the other
//! side.
//!
//! ## Real-time budget
//!
//! [`VideoFx::process`] times itself. If the moving average exceeds the budget
//! (derived from the frame rate) it coarsens the internal guided-filter grid
//! (×2, ×4) and finally falls back to tone-only (no smoothing); when there is
//! lots of headroom again it steps back up, with back-off to avoid oscillating.

use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::time::Instant;

use serde::{Deserialize, Serialize};

use crate::color::I420Buf;

/// Settings-store keys (values: ASCII `"0"`..`"3"`, `"0"`/`"1"`).
pub const KEY_BEAUTY: &str = "video.beauty";
pub const KEY_LOWLIGHT: &str = "video.lowlight";
pub const KEY_MIRROR_SEND: &str = "video.mirror_send";

/// Highest beauty level ("Mạnh").
pub const MAX_BEAUTY: u8 = 3;

/// Effect settings for one camera stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct FxSettings {
    /// 0 = off, 1 = Nhẹ (light), 2 = Vừa (medium), 3 = Mạnh (strong).
    pub beauty: u8,
    /// Automatic low-light boost.
    pub lowlight: bool,
    /// Mirror the picture that is *sent* (the local preview is always mirrored).
    pub mirror: bool,
}

impl Default for FxSettings {
    fn default() -> Self {
        Self { beauty: 0, lowlight: true, mirror: false }
    }
}

impl FxSettings {
    /// Read from a key/value store (`get` returns the raw stored bytes).
    /// Missing or malformed values fall back to the defaults.
    pub fn from_kv(get: impl Fn(&str) -> Option<Vec<u8>>) -> Self {
        let d = Self::default();
        let num = |k: &str| get(k).and_then(|v| std::str::from_utf8(&v).ok()?.trim().parse::<u8>().ok());
        let flag = |k: &str, def: bool| get(k).map(|v| v.as_slice() != b"0" && !v.is_empty()).unwrap_or(def);
        Self {
            beauty: num(KEY_BEAUTY).map(|b| b.min(MAX_BEAUTY)).unwrap_or(d.beauty),
            lowlight: flag(KEY_LOWLIGHT, d.lowlight),
            mirror: flag(KEY_MIRROR_SEND, d.mirror),
        }
    }

    /// The key/value pairs that [`FxSettings::from_kv`] reads back.
    pub fn to_kv(&self) -> [(&'static str, Vec<u8>); 3] {
        let b = |v: bool| if v { b"1".to_vec() } else { b"0".to_vec() };
        [
            (KEY_BEAUTY, self.beauty.min(MAX_BEAUTY).to_string().into_bytes()),
            (KEY_LOWLIGHT, b(self.lowlight)),
            (KEY_MIRROR_SEND, b(self.mirror)),
        ]
    }
}

/// Lock-free live controls: written by the settings side, read by the encoder
/// thread once per frame (mid-call changes apply on the next frame).
#[derive(Debug)]
pub struct FxControls {
    beauty: AtomicU8,
    lowlight: AtomicBool,
    mirror: AtomicBool,
}

impl Default for FxControls {
    fn default() -> Self {
        Self::new(FxSettings::default())
    }
}

impl FxControls {
    pub fn new(s: FxSettings) -> Self {
        Self { beauty: AtomicU8::new(s.beauty.min(MAX_BEAUTY)), lowlight: AtomicBool::new(s.lowlight), mirror: AtomicBool::new(s.mirror) }
    }
    pub fn store(&self, s: FxSettings) {
        self.beauty.store(s.beauty.min(MAX_BEAUTY), Ordering::Relaxed);
        self.lowlight.store(s.lowlight, Ordering::Relaxed);
        self.mirror.store(s.mirror, Ordering::Relaxed);
    }
    pub fn load(&self) -> FxSettings {
        FxSettings {
            beauty: self.beauty.load(Ordering::Relaxed),
            lowlight: self.lowlight.load(Ordering::Relaxed),
            mirror: self.mirror.load(Ordering::Relaxed),
        }
    }
}

/// Per-level beauty parameters.
#[derive(Debug, Clone, Copy)]
struct Level {
    /// Blend weight of the smoothed luma on skin.
    strength: f32,
    /// Guided-filter ε as a luma standard deviation (variance below σ² is smoothed).
    sigma: f32,
    /// Window radius as a fraction of the picture height.
    radius: f32,
    /// Fraction of `strength` applied outside the skin mask (gentle denoise).
    background: f32,
    /// Brightness lift at mid-grey (fraction of the luma range).
    lift: f32,
    /// S-curve amount (0 = linear).
    contrast: f32,
    /// Warmth: added to Cr (and half subtracted from Cb), in code values.
    warmth: f32,
    /// Chroma saturation factor.
    saturation: f32,
}

const LEVELS: [Level; 3] = [
    // Nhẹ: keeps skin texture — reads as "good camera", not as a filter.
    Level { strength: 0.55, sigma: 7.0, radius: 0.008, background: 0.12, lift: 0.022, contrast: 0.04, warmth: 1.2, saturation: 1.02 },
    // Vừa
    Level { strength: 0.75, sigma: 10.0, radius: 0.012, background: 0.18, lift: 0.035, contrast: 0.06, warmth: 2.0, saturation: 1.03 },
    // Mạnh
    Level { strength: 0.90, sigma: 14.0, radius: 0.016, background: 0.22, lift: 0.05, contrast: 0.08, warmth: 3.0, saturation: 1.04 },
];

// Low-light boost tuning (luma normalised to 0..1 over the 16..235 range).
/// Scenes darker than this are brightened towards it.
const LL_TARGET: f32 = 0.38;
/// Strongest gamma (lower = brighter).
pub const LL_MIN_GAMMA: f32 = 0.5;
/// Shadow toe: bounds the curve's slope at black (max gain ≈ 3.4 at γ = 0.5).
const LL_TOE: f32 = 0.03;
/// EMA coefficient per frame (~0.5 s time constant at 30 fps).
const LL_ALPHA: f32 = 0.07;
/// Largest gamma change per frame.
pub const LL_MAX_STEP: f32 = 0.012;
/// Target changes smaller than this are ignored (no micro-pumping).
const LL_DEADBAND: f32 = 0.012;

/// Internal quality levels for the adaptive fallback.
const Q_TONE_ONLY: u8 = 3;

/// Camera effect processor. Create one per camera stream and call
/// [`VideoFx::process`] on every I420 frame before encoding.
pub struct VideoFx {
    // adaptive budget
    budget_us: f32,
    adaptive: bool,
    quality: u8,
    ema_us: f32,
    frames_at_quality: u32,
    upgrade_holdoff: u32,
    upgraded: bool,
    last_us: f32,

    // geometry of the current low-resolution grid
    w: usize,
    h: usize,
    level: u8,
    factor: usize,
    radius: usize,
    lw: usize,
    lh: usize,

    // scratch (reused across frames)
    col_s: Vec<u16>,
    col_q: Vec<u32>,
    s: Vec<f32>,
    q: Vec<f32>,
    mask: Vec<f32>,
    m1: Vec<f32>,
    m2: Vec<f32>,
    ca: Vec<f32>,
    cb: Vec<f32>,
    tmp: Vec<f32>,
    acc: Vec<f32>,
    inv_x: Vec<f32>,
    inv_y: Vec<f32>,
    /// Two horizontally upsampled low-res rows of A and B (ring, `2 × w`).
    up_a: Vec<f32>,
    up_b: Vec<f32>,
    up_tag: [usize; 2],
    /// One full-resolution row before the tone curve.
    line: Vec<u8>,
    wk: Vec<f32>,

    // tone curves
    lut_y: [u8; 256],
    /// Chroma as fixed point (Q8): `c' = 128 + ((c − 128)·sat + shift) >> 8`.
    chroma_u: (i32, i32),
    chroma_v: (i32, i32),
    lut_key: Option<(u8, u32)>,
    tone_identity: bool,
    chroma_identity: bool,

    // low-light state
    gamma: f32,
    gamma_init: bool,
    mean_ema: f32,
}

impl Default for VideoFx {
    fn default() -> Self {
        Self::new()
    }
}

impl VideoFx {
    pub fn new() -> Self {
        let id: [u8; 256] = std::array::from_fn(|i| i as u8);
        Self {
            budget_us: 6000.0,
            adaptive: true,
            quality: 0,
            ema_us: 0.0,
            frames_at_quality: 0,
            upgrade_holdoff: 150,
            upgraded: false,
            last_us: 0.0,
            w: 0,
            h: 0,
            level: 0,
            factor: 0,
            radius: 0,
            lw: 0,
            lh: 0,
            col_s: Vec::new(),
            col_q: Vec::new(),
            s: Vec::new(),
            q: Vec::new(),
            mask: Vec::new(),
            m1: Vec::new(),
            m2: Vec::new(),
            ca: Vec::new(),
            cb: Vec::new(),
            tmp: Vec::new(),
            acc: Vec::new(),
            inv_x: Vec::new(),
            inv_y: Vec::new(),
            up_a: Vec::new(),
            up_b: Vec::new(),
            up_tag: [usize::MAX; 2],
            line: Vec::new(),
            wk: Vec::new(),
            lut_y: id,
            chroma_u: (256, 0),
            chroma_v: (256, 0),
            lut_key: None,
            tone_identity: true,
            chroma_identity: true,
            gamma: 1.0,
            gamma_init: false,
            mean_ema: 0.0,
        }
    }

    /// Derive the processing budget from the stream's frame rate: about a fifth
    /// of the frame interval (the encoder needs the rest), 2.5–6 ms.
    pub fn set_frame_rate(&mut self, fps: u32) {
        let interval = 1e6 / fps.clamp(1, 240) as f32;
        self.budget_us = (interval * 0.18).clamp(2500.0, 6000.0);
    }

    /// Explicit per-frame budget in microseconds.
    pub fn set_budget_us(&mut self, us: f32) {
        self.budget_us = us.max(1.0);
    }

    /// Enable/disable the automatic quality fallback (on by default).
    pub fn set_adaptive(&mut self, on: bool) {
        self.adaptive = on;
        if !on {
            self.set_quality(0);
        }
    }

    /// 0 = full quality … 3 = tone-only (no smoothing).
    pub fn quality(&self) -> u8 {
        self.quality
    }

    /// Guided-filter downsampling factor in use (0 before the first beauty frame).
    pub fn internal_factor(&self) -> usize {
        self.factor
    }

    /// Duration of the last [`VideoFx::process`] call, in microseconds.
    pub fn last_us(&self) -> f32 {
        self.last_us
    }

    /// Current low-light gamma (1.0 = no boost).
    pub fn lowlight_gamma(&self) -> f32 {
        self.gamma
    }

    /// The luma tone curve currently applied (identity when inactive).
    pub fn luma_lut(&self) -> &[u8; 256] {
        &self.lut_y
    }

    /// Whether `process` would change anything for these settings right now.
    pub fn is_active(&self, s: &FxSettings) -> bool {
        s.beauty > 0 || s.mirror || (s.lowlight && self.gamma < 0.999)
    }

    /// Apply the effects in place. Never allocates once the buffers for this
    /// geometry/level exist.
    pub fn process(&mut self, img: &mut I420Buf, s: &FxSettings) {
        if img.width == 0 || img.height == 0 || img.y.len() < img.width * img.height {
            return;
        }
        let t0 = Instant::now();
        let level = s.beauty.min(MAX_BEAUTY);
        let smoothing = level > 0 && self.quality < Q_TONE_ONLY;

        // 1. Mean luma of the *input* (before any effect) for the low-light boost.
        let mut mean_y = None;
        if smoothing {
            self.ensure_geometry(img.width, img.height, level);
            mean_y = Some(self.downsample(img));
        }
        if s.lowlight {
            let m = mean_y.unwrap_or_else(|| mean_luma(img));
            self.update_gamma(m);
        } else {
            self.gamma = 1.0;
            self.gamma_init = false;
        }
        self.build_luts(level, self.gamma);

        // 2. Luma: smoothing + tone curve in one pass (or the tone curve alone).
        if smoothing {
            self.guided_coefficients(img, level);
            self.apply_luma(img);
        } else if !self.tone_identity {
            let lut = &self.lut_y;
            for p in img.y.iter_mut() {
                *p = lut[*p as usize];
            }
        }
        // 3. Chroma: warmth / saturation.
        if !self.chroma_identity {
            chroma_affine(&mut img.u, self.chroma_u);
            chroma_affine(&mut img.v, self.chroma_v);
        }
        // 4. Mirror the sent picture.
        if s.mirror {
            mirror_i420(img);
        }

        let us = t0.elapsed().as_secs_f32() * 1e6;
        self.last_us = us;
        if level > 0 {
            self.account(us);
        }
    }

    // ------------------------------------------------------------ adaptive quality

    fn set_quality(&mut self, q: u8) {
        if q != self.quality {
            self.quality = q;
            self.w = 0; // force a new grid
            self.ema_us = 0.0;
            self.frames_at_quality = 0;
        }
    }

    fn account(&mut self, us: f32) {
        self.ema_us = if self.ema_us == 0.0 { us } else { self.ema_us * 0.9 + us * 0.1 };
        self.frames_at_quality = self.frames_at_quality.saturating_add(1);
        if !self.adaptive {
            return;
        }
        if self.ema_us > self.budget_us && self.quality < Q_TONE_ONLY && self.frames_at_quality >= 6 {
            // Stepped up and failed again soon after: wait longer next time.
            if self.upgraded && self.frames_at_quality < 2 * self.upgrade_holdoff {
                self.upgrade_holdoff = (self.upgrade_holdoff * 2).min(30 * 60);
            }
            self.upgraded = false;
            tracing::debug!("video fx over budget ({:.0} µs > {:.0} µs): quality {} -> {}", self.ema_us, self.budget_us, self.quality, self.quality + 1);
            self.set_quality(self.quality + 1);
        } else if self.ema_us < self.budget_us * 0.3 && self.quality > 0 && self.frames_at_quality >= self.upgrade_holdoff {
            self.set_quality(self.quality - 1);
            self.upgraded = true;
        }
    }

    // ------------------------------------------------------------ guided filter

    fn ensure_geometry(&mut self, w: usize, h: usize, level: u8) {
        if self.w == w && self.h == h && self.level == level {
            return;
        }
        let p = LEVELS[level as usize - 1];
        // ~256 px wide internal grid at full quality; ×2 / ×4 coarser on fallback.
        let base = ((w as f32 / 256.0).round() as usize).clamp(1, 8);
        let factor = (base << self.quality.min(2)).clamp(1, 32).min(w.min(h).max(1));
        let lw = w.div_ceil(factor);
        let lh = h.div_ceil(factor);
        let radius = ((p.radius * h as f32) / factor as f32).round().clamp(1.0, 16.0) as usize;

        self.w = w;
        self.h = h;
        self.level = level;
        self.factor = factor;
        self.radius = radius;
        self.lw = lw;
        self.lh = lh;
        let n = lw * lh;
        for v in [&mut self.s, &mut self.q, &mut self.mask, &mut self.m1, &mut self.m2, &mut self.ca, &mut self.cb, &mut self.tmp] {
            v.clear();
            v.resize(n, 0.0);
        }
        self.col_s.clear();
        self.col_s.resize(w, 0);
        self.col_q.clear();
        self.col_q.resize(w, 0);
        self.acc.clear();
        self.acc.resize(lw, 0.0);
        self.up_a.clear();
        self.up_a.resize(2 * w, 0.0);
        self.up_b.clear();
        self.up_b.resize(2 * w, 0.0);
        self.line.clear();
        self.line.resize(w, 0);
        self.inv_x.clear();
        self.inv_x.extend((0..lw).map(|x| 1.0 / (((x + radius).min(lw - 1) - x.saturating_sub(radius) + 1) as f32)));
        self.inv_y.clear();
        self.inv_y.extend((0..lh).map(|y| 1.0 / (((y + radius).min(lh - 1) - y.saturating_sub(radius) + 1) as f32)));
        let half = (factor as f32 - 1.0) / 2.0;
        let s0 = half.ceil();
        self.wk.clear();
        self.wk.extend((0..factor).map(|k| (s0 + k as f32 - half) / factor as f32));
    }

    /// Block-average `Y` and `Y²` into the low-res grid (centred on 128 to keep
    /// f32 sums precise). Returns the mean luma of the whole picture.
    fn downsample(&mut self, img: &I420Buf) -> f32 {
        let (w, h, f, lw) = (self.w, self.h, self.factor, self.lw);
        let mut total = 0u64;
        for (ly, (srow, qrow)) in self.s.chunks_exact_mut(lw).zip(self.q.chunks_exact_mut(lw)).enumerate() {
            let y0 = ly * f;
            let y1 = (y0 + f).min(h);
            self.col_s.fill(0);
            self.col_q.fill(0);
            for y in y0..y1 {
                let row = &img.y[y * w..(y + 1) * w];
                for (cs, &p) in self.col_s.iter_mut().zip(row) {
                    *cs += p as u16; // ≤ 32 rows × 255 fits
                }
                for (cq, &p) in self.col_q.iter_mut().zip(row) {
                    // 255² fits in u16: lets SSE2 use 16-bit multiplies
                    *cq += (p as u16 * p as u16) as u32;
                }
            }
            let rows = (y1 - y0) as f32;
            for ((cs, cq), (so, qo)) in self.col_s.chunks(f).zip(self.col_q.chunks(f)).zip(srow.iter_mut().zip(qrow.iter_mut())) {
                let ss: u32 = cs.iter().map(|&v| v as u32).sum();
                let qq: u32 = cq.iter().sum();
                total += ss as u64;
                let inv = 1.0 / (rows * cs.len() as f32);
                let m = ss as f32 * inv;
                let m2 = qq as f32 * inv;
                // E[(Y-128)] and E[(Y-128)²]
                *so = m - 128.0;
                *qo = m2 - 256.0 * m + 16384.0;
            }
        }
        total as f32 / (w * h) as f32
    }

    fn guided_coefficients(&mut self, img: &I420Buf, level: u8) {
        let p = LEVELS[level as usize - 1];
        let (lw, lh, f, r) = (self.lw, self.lh, self.factor, self.radius);
        let eps = p.sigma * p.sigma;

        // Skin mask from chroma sampled at each low-res cell centre.
        let cw = img.width.div_ceil(2);
        let chh = img.height.div_ceil(2);
        if img.u.len() >= cw * chh && img.v.len() >= cw * chh {
            for (ly, (mrow, srow)) in self.mask.chunks_exact_mut(lw).zip(self.s.chunks_exact(lw)).enumerate() {
                let cy = ((ly * f + f / 2) / 2).min(chh - 1);
                let urow = &img.u[cy * cw..(cy + 1) * cw];
                let vrow = &img.v[cy * cw..(cy + 1) * cw];
                for (lx, (m, &sy)) in mrow.iter_mut().zip(srow).enumerate() {
                    let cx = ((lx * f + f / 2) / 2).min(cw - 1);
                    *m = skin_weight(sy + 128.0, urow[cx] as f32, vrow[cx] as f32);
                }
            }
        } else {
            self.mask.fill(1.0);
        }

        let bx = |src: &[f32], dst: &mut [f32], tmp: &mut [f32], acc: &mut [f32], ix: &[f32], iy: &[f32]| {
            box_mean(src, dst, lw, lh, r, tmp, acc, ix, iy)
        };
        // mean(I), mean(I²)
        bx(&self.s, &mut self.m1, &mut self.tmp, &mut self.acc, &self.inv_x, &self.inv_y);
        bx(&self.q, &mut self.m2, &mut self.tmp, &mut self.acc, &self.inv_x, &self.inv_y);
        // a, b (into s, q)
        for ((a, b), (&mi, &mii)) in self.s.iter_mut().zip(self.q.iter_mut()).zip(self.m1.iter().zip(self.m2.iter())) {
            let var = (mii - mi * mi).max(0.0);
            let aa = var / (var + eps);
            *a = aa;
            *b = mi * (1.0 - aa);
        }
        bx(&self.s, &mut self.ca, &mut self.tmp, &mut self.acc, &self.inv_x, &self.inv_y);
        bx(&self.q, &mut self.cb, &mut self.tmp, &mut self.acc, &self.inv_x, &self.inv_y);
        // soft mask
        bx(&self.mask, &mut self.m1, &mut self.tmp, &mut self.acc, &self.inv_x, &self.inv_y);

        // Fold strength + mask in: out = A·Y + B (Y uncentred).
        let (st, bg) = (p.strength, p.background);
        for ((a, b), &m) in self.ca.iter_mut().zip(self.cb.iter_mut()).zip(self.m1.iter()) {
            let wgt = st * (bg + (1.0 - bg) * m);
            let aa = 1.0 - wgt * (1.0 - *a);
            *b = wgt * *b + 128.0 * (1.0 - aa);
            *a = aa;
        }
    }

    /// Horizontally upsample low-res row `ly` of A and B into ring slot `slot`.
    fn upsample_row(&mut self, ly: usize, slot: usize) {
        let (w, f, lw) = (self.w, self.factor, self.lw);
        let s0 = ((f as f32 - 1.0) / 2.0).ceil() as usize;
        let src_a = &self.ca[ly * lw..(ly + 1) * lw];
        let src_b = &self.cb[ly * lw..(ly + 1) * lw];
        let da = &mut self.up_a[slot * w..(slot + 1) * w];
        let db = &mut self.up_b[slot * w..(slot + 1) * w];
        let lend = s0.min(w);
        da[..lend].fill(src_a[0]);
        db[..lend].fill(src_b[0]);
        for lx in 0..lw.saturating_sub(1) {
            let start = s0 + lx * f;
            if start >= w {
                break;
            }
            let end = (start + f).min(w);
            let (a0, a1) = (src_a[lx], src_a[lx + 1] - src_a[lx]);
            let (b0, b1) = (src_b[lx], src_b[lx + 1] - src_b[lx]);
            for ((pa, pb), &k) in da[start..end].iter_mut().zip(db[start..end].iter_mut()).zip(&self.wk) {
                *pa = a0 + a1 * k;
                *pb = b0 + b1 * k;
            }
        }
        let rstart = (s0 + lw.saturating_sub(1) * f).min(w);
        da[rstart..].fill(src_a[lw - 1]);
        db[rstart..].fill(src_b[lw - 1]);
        self.up_tag[slot] = ly;
    }

    /// Full-resolution pass: `lut[A·Y + B]` with `A`,`B` bilinearly upsampled.
    /// Low-res rows are upsampled horizontally once each (two-row ring), so the
    /// per-pixel loop is a contiguous, vectorisable lerp + multiply-add; the
    /// tone curve is a separate table pass.
    fn apply_luma(&mut self, img: &mut I420Buf) {
        let (w, h, f, lh) = (self.w, self.h, self.factor, self.lh);
        let half = (f as f32 - 1.0) / 2.0;
        self.up_tag = [usize::MAX; 2];
        for (y, row) in img.y.chunks_exact_mut(w).take(h).enumerate() {
            let u = ((y as f32 - half) / f as f32).max(0.0);
            let iy0 = (u as usize).min(lh - 1);
            let iy1 = (iy0 + 1).min(lh - 1);
            let fy = if iy0 == iy1 { 0.0 } else { u - iy0 as f32 };
            for ly in [iy0, iy1] {
                if self.up_tag[ly & 1] != ly {
                    self.upsample_row(ly, ly & 1);
                }
            }
            let (s0, s1) = (iy0 & 1, iy1 & 1);
            let a0 = &self.up_a[s0 * w..(s0 + 1) * w];
            let a1 = &self.up_a[s1 * w..(s1 + 1) * w];
            let b0 = &self.up_b[s0 * w..(s0 + 1) * w];
            let b1 = &self.up_b[s1 * w..(s1 + 1) * w];
            for (((o, &p), (&x0, &x1)), (&z0, &z1)) in
                self.line.iter_mut().zip(row.iter()).zip(a0.iter().zip(a1)).zip(b0.iter().zip(b1))
            {
                let a = x0 + (x1 - x0) * fy;
                let b = z0 + (z1 - z0) * fy;
                *o = round_u8(a * p as f32 + b);
            }
            let lut = &self.lut_y;
            for (p, &v) in row.iter_mut().zip(self.line.iter()) {
                *p = lut[v as usize];
            }
        }
    }

    // ------------------------------------------------------------ low light + tone

    fn update_gamma(&mut self, mean_y: f32) {
        if !self.gamma_init {
            // First frame: start from "no boost" and ease in (no sudden jump).
            self.gamma = 1.0;
            self.mean_ema = mean_y;
            self.gamma_init = true;
        }
        // Smooth the measurement first (sensor noise, auto-exposure hunting)…
        self.mean_ema += (mean_y - self.mean_ema) * 0.15;
        let m = ((self.mean_ema - 16.0) / 219.0).clamp(0.002, 1.0);
        let target = if m >= LL_TARGET { 1.0 } else { (LL_TARGET.ln() / m.ln()).clamp(LL_MIN_GAMMA, 1.0) };
        // …then the response: dead band + EMA + per-frame step limit.
        let diff = target - self.gamma;
        if diff.abs() > LL_DEADBAND || target == 1.0 {
            let step = (diff * LL_ALPHA).clamp(-LL_MAX_STEP, LL_MAX_STEP);
            // Keep moving at a minimum pace so we actually reach the band.
            let step = if step.abs() < 0.0008 { diff.clamp(-0.0008, 0.0008) } else { step };
            self.gamma = (self.gamma + step).clamp(LL_MIN_GAMMA, 1.0);
        }
    }

    fn build_luts(&mut self, level: u8, gamma: f32) {
        let gq = (gamma * 1000.0).round() as u32;
        if self.lut_key == Some((level, gq)) {
            return;
        }
        self.lut_key = Some((level, gq));
        let g = gq as f32 / 1000.0;
        let p = if level > 0 { Some(LEVELS[level as usize - 1]) } else { None };
        let boost = g < 0.999;
        let (k0, kn) = if boost { (LL_TOE.powf(g), (1.0 + LL_TOE).powf(g)) } else { (0.0, 1.0) };
        let mut identity = true;
        for i in 0..256 {
            let mut x = ((i as f32 - 16.0) / 219.0).clamp(0.0, 1.0);
            if boost {
                x = ((x + LL_TOE).powf(g) - k0) / (kn - k0);
            }
            if let Some(p) = p {
                x += p.lift * 4.0 * x * (1.0 - x);
                let s = x * x * (3.0 - 2.0 * x);
                x += p.contrast * (s - x);
            }
            let v = if boost || p.is_some() { (16.0 + 219.0 * x.clamp(0.0, 1.0)).round() as u8 } else { i as u8 };
            identity &= v == i as u8;
            self.lut_y[i] = v;
        }
        self.tone_identity = identity;

        let (sat, warm) = match p {
            Some(p) => (p.saturation, p.warmth),
            None => (1.0, 0.0),
        };
        // a brightened dark scene looks washed out: give chroma a little back
        let sat = sat * (1.0 + 0.2 * (1.0 - g));
        let sq = (sat * 256.0).round() as i32;
        self.chroma_u = (sq, (-warm * 0.5 * 256.0).round() as i32);
        self.chroma_v = (sq, (warm * 256.0).round() as i32);
        self.chroma_identity = sq == 256 && self.chroma_u.1 == 0 && self.chroma_v.1 == 0;
    }
}

/// Soft YCbCr (BT.601 limited range) skin-tone likelihood in 0..1. An ellipse
/// around the skin cluster (light to dark skin under typical white balance),
/// with a soft rim, ignoring very dark pixels (hair, shadows).
#[inline(always)]
fn skin_weight(y: f32, cb: f32, cr: f32) -> f32 {
    let db = (cb - 108.0) * (1.0 / 20.0);
    let dr = (cr - 152.0) * (1.0 / 17.0);
    let d2 = db * db + dr * dr;
    let c = ((1.8 - d2) * 1.25).clamp(0.0, 1.0);
    let l = ((y - 40.0) * (1.0 / 30.0)).clamp(0.0, 1.0);
    c * l
}

/// Clamped-window mean over a `(2r+1)²` box, O(1) per pixel: running sums
/// along rows (four rows interleaved so the dependency chains overlap), then
/// running column sums down the image (vectorised over x).
#[allow(clippy::too_many_arguments)]
fn box_mean(src: &[f32], dst: &mut [f32], w: usize, h: usize, r: usize, tmp: &mut [f32], acc: &mut [f32], inv_x: &[f32], inv_y: &[f32]) {
    let head = (r + 1).min(w);
    let mut y = 0;
    while y + 4 <= h {
        let rows: [&[f32]; 4] = std::array::from_fn(|k| &src[(y + k) * w..(y + k + 1) * w]);
        let mut sum = [0.0f32; 4];
        for k in 0..4 {
            sum[k] = rows[k][..head].iter().sum();
        }
        let out = &mut tmp[y * w..(y + 4) * w];
        for x in 0..w {
            for k in 0..4 {
                out[k * w + x] = sum[k];
            }
            let add = x + r + 1 < w;
            let sub = x >= r;
            for k in 0..4 {
                let a = if add { rows[k][x + r + 1] } else { 0.0 };
                let s = if sub { rows[k][x - r] } else { 0.0 };
                sum[k] += a - s;
            }
        }
        y += 4;
    }
    for y in y..h {
        let row = &src[y * w..(y + 1) * w];
        let out = &mut tmp[y * w..(y + 1) * w];
        let mut sum: f32 = row[..head].iter().sum();
        for x in 0..w {
            out[x] = sum;
            let a = if x + r + 1 < w { row[x + r + 1] } else { 0.0 };
            let s = if x >= r { row[x - r] } else { 0.0 };
            sum += a - s;
        }
    }
    acc.fill(0.0);
    for trow in tmp.chunks_exact(w).take(r + 1) {
        for (a, &t) in acc.iter_mut().zip(trow) {
            *a += t;
        }
    }
    for y in 0..h {
        let iy = inv_y[y];
        for ((d, &a), &ix) in dst[y * w..(y + 1) * w].iter_mut().zip(acc.iter()).zip(inv_x) {
            *d = a * ix * iy;
        }
        if y + r + 1 < h {
            for (a, &t) in acc.iter_mut().zip(&tmp[(y + r + 1) * w..(y + r + 2) * w]) {
                *a += t;
            }
        }
        if y >= r {
            for (a, &t) in acc.iter_mut().zip(&tmp[(y - r) * w..(y - r + 1) * w]) {
                *a -= t;
            }
        }
    }
}

/// Round to the nearest integer in 0..=255 without a (non-vectorisable,
/// NaN-checking) saturating cast: adding 1.5·2²³ puts the rounded integer in
/// the low mantissa bits.
#[inline(always)]
fn round_u8(v: f32) -> u8 {
    (v.clamp(0.0, 255.0) + 12_582_912.0).to_bits() as u8
}

/// `c' = 128 + ((c − 128)·k + shift) / 256`, clamped to the legal 16..240.
fn chroma_affine(plane: &mut [u8], (k, shift): (i32, i32)) {
    for p in plane.iter_mut() {
        let c = *p as i32 - 128;
        *p = (128 + ((c * k + shift + 128) >> 8)).clamp(16, 240) as u8;
    }
}

/// Mean luma from every 8th row (fast; enough for exposure decisions).
fn mean_luma(img: &I420Buf) -> f32 {
    let w = img.width;
    let mut sum = 0u64;
    let mut n = 0u64;
    for row in img.y.chunks_exact(w).take(img.height).step_by(8) {
        sum += row.iter().map(|&p| p as u32).sum::<u32>() as u64;
        n += w as u64;
    }
    if n == 0 {
        128.0
    } else {
        sum as f32 / n as f32
    }
}

/// Mirror an I420 picture horizontally, in place.
pub fn mirror_i420(img: &mut I420Buf) {
    let (w, h) = (img.width, img.height);
    let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
    for row in img.y.chunks_exact_mut(w).take(h) {
        row.reverse();
    }
    for plane in [&mut img.u, &mut img.v] {
        for row in plane.chunks_exact_mut(cw).take(ch) {
            row.reverse();
        }
    }
    // Odd width: chroma sample k covers luma 2k..2k+1, so after reversal the
    // half-pixel shift is unavoidable; harmless for camera content.
}

/// Convert a (processed) I420 picture into a tightly packed RGBA preview for
/// the local self-view: optionally mirrored, and halved (2×2 average) when
/// wider than `max_w`. Reuses `out`; returns the preview size.
pub fn preview_rgba(src: &I420Buf, mirror: bool, max_w: usize, out: &mut Vec<u8>) -> (usize, usize) {
    let (w, h) = (src.width, src.height);
    if w == 0 || h == 0 {
        out.clear();
        return (0, 0);
    }
    let step = if w > max_w.max(16) && w >= 2 && h >= 2 { 2 } else { 1 };
    let (ow, oh) = (w / step, h / step);
    let cw = w.div_ceil(2);
    out.resize(ow * oh * 4, 255);
    for (oy, orow) in out.chunks_exact_mut(ow * 4).enumerate() {
        let sy = oy * step;
        let y0 = &src.y[sy * w..sy * w + w];
        let y1 = if step == 2 { &src.y[(sy + 1) * w..(sy + 1) * w + w] } else { y0 };
        let cy = sy / 2;
        let ur = &src.u[cy * cw..cy * cw + cw];
        let vr = &src.v[cy * cw..cy * cw + cw];
        for ox in 0..ow {
            let sx = ox * step;
            let yy = if step == 2 {
                (y0[sx] as i32 + y0[sx + 1] as i32 + y1[sx] as i32 + y1[sx + 1] as i32 + 2) >> 2
            } else {
                y0[sx] as i32
            };
            let d = ur[sx / 2] as i32 - 128;
            let e = vr[sx / 2] as i32 - 128;
            let c = 298 * (yy - 16);
            let dx = if mirror { ow - 1 - ox } else { ox };
            let px = &mut orow[dx * 4..dx * 4 + 4];
            px[0] = ((c + 409 * e + 128) >> 8).clamp(0, 255) as u8;
            px[1] = ((c - 100 * d - 208 * e + 128) >> 8).clamp(0, 255) as u8;
            px[2] = ((c + 516 * d + 128) >> 8).clamp(0, 255) as u8;
            px[3] = 255;
        }
    }
    (ow, oh)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Deterministic Gaussian-ish noise (sum of 4 uniforms, xorshift).
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> f32 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            (self.0 >> 40) as f32 / (1u64 << 24) as f32
        }
        fn gauss(&mut self) -> f32 {
            // variance of a U(0,1) sum of 4 = 4/12 -> scale to unit variance
            (self.next() + self.next() + self.next() + self.next() - 2.0) * (3.0f32).sqrt()
        }
    }

    const SKIN_U: u8 = 110;
    const SKIN_V: u8 = 152;

    fn flat(w: usize, h: usize, y: u8, u: u8, v: u8) -> I420Buf {
        let mut b = I420Buf::new(w, h);
        b.y.fill(y);
        b.u.fill(u);
        b.v.fill(v);
        b
    }

    fn variance(v: impl Iterator<Item = f32>) -> f32 {
        let xs: Vec<f32> = v.collect();
        let m = xs.iter().sum::<f32>() / xs.len() as f32;
        xs.iter().map(|x| (x - m) * (x - m)).sum::<f32>() / xs.len() as f32
    }

    fn fx() -> VideoFx {
        let mut f = VideoFx::new();
        f.set_adaptive(false); // debug-build timings must not change quality
        f
    }

    #[test]
    fn noisy_flat_skin_is_smoothed_per_level() {
        let (w, h) = (640, 360);
        let mut rng = Rng(0x9E3779B97F4A7C15);
        let mut src = flat(w, h, 150, SKIN_U, SKIN_V);
        for p in src.y.iter_mut() {
            *p = (150.0 + 6.0 * rng.gauss()).round().clamp(0.0, 255.0) as u8;
        }
        // measure away from the borders
        let inner = |b: &I420Buf| {
            let mut v = Vec::new();
            for y in 40..h - 40 {
                for x in 40..w - 40 {
                    v.push(b.y[y * w + x] as f32);
                }
            }
            variance(v.into_iter())
        };
        let v0 = inner(&src);
        assert!((30.0..42.0).contains(&v0), "test noise variance {v0}");
        let mut last = 0.0;
        for (level, min_reduction) in [(1u8, 0.35f32), (2, 0.60), (3, 0.80)] {
            let mut img = src.clone();
            let mut f = fx();
            f.process(&mut img, &FxSettings { beauty: level, lowlight: false, mirror: false });
            let v1 = inner(&img);
            let red = 1.0 - v1 / v0;
            eprintln!("level {level}: variance {v0:.1} -> {v1:.1} ({:.0}% less)", red * 100.0);
            assert!(red >= min_reduction, "level {level}: only {:.0}% variance reduction", red * 100.0);
            assert!(red > last, "levels must smooth progressively more");
            last = red;
        }
    }

    #[test]
    fn step_edge_is_preserved() {
        let (w, h) = (640, 360);
        let mut src = flat(w, h, 60, SKIN_U, SKIN_V);
        let edge = 301; // odd, not aligned to the internal grid
        for row in src.y.chunks_exact_mut(w) {
            for p in row[edge..].iter_mut() {
                *p = 180;
            }
        }
        for level in 1..=3u8 {
            let mut img = src.clone();
            let mut f = fx();
            f.process(&mut img, &FxSettings { beauty: level, lowlight: false, mirror: false });
            let lut = *f.luma_lut();
            let (lo, hi) = (lut[60] as i32, lut[180] as i32);
            // A guided filter has (tiny) halos only: at most 3 % of the step height.
            let tol = ((hi - lo) as f32 * 0.03).ceil() as i32;
            let mut worst = 0;
            for y in (10..h - 10).step_by(7) {
                let row = &img.y[y * w..(y + 1) * w];
                // flat parts stay on the tone-mapped levels…
                for (x, &v) in row.iter().enumerate() {
                    let want = if x < edge { lo } else { hi };
                    let d = (v as i32 - want).abs();
                    let near = (x as i32 - edge as i32).abs() <= 1;
                    if !near {
                        worst = worst.max(d);
                    }
                    assert!(near || d <= tol, "level {level}: halo at x={x}: {v} vs {want}");
                }
                // …and the transition is still one pixel wide
                assert!((row[edge - 1] as i32 - lo).abs() <= 6 && (row[edge] as i32 - hi).abs() <= 6, "level {level}: edge blurred: {} {}", row[edge - 1], row[edge]);
            }
            eprintln!("level {level}: step {lo}->{hi}, worst halo {worst}, edge pixels {} {}", img.y[180 * w + edge - 1], img.y[180 * w + edge]);
        }
    }

    #[test]
    fn thin_dark_detail_survives() {
        // A 2-px dark line (eyelash / brow stroke) on skin keeps most of its contrast.
        let (w, h) = (640, 360);
        let mut src = flat(w, h, 170, SKIN_U, SKIN_V);
        for row in src.y.chunks_exact_mut(w) {
            row[321] = 90;
            row[322] = 90;
        }
        let mut f = fx();
        let mut img = src.clone();
        f.process(&mut img, &FxSettings { beauty: 2, lowlight: false, mirror: false });
        let lut = f.luma_lut();
        let before = lut[170] as i32 - lut[90] as i32;
        let row = &img.y[180 * w..181 * w];
        let after = row[300] as i32 - row[321].min(row[322]) as i32;
        assert!(after as f32 >= 0.8 * before as f32, "line contrast {before} -> {after}");
    }

    #[test]
    fn background_is_smoothed_less_than_skin() {
        let (w, h) = (640, 360);
        let mut rng = Rng(42);
        let make = |u: u8, v: u8, rng: &mut Rng| {
            let mut b = flat(w, h, 150, u, v);
            for p in b.y.iter_mut() {
                *p = (150.0 + 6.0 * rng.gauss()).round() as u8;
            }
            b
        };
        let skin = make(SKIN_U, SKIN_V, &mut rng);
        let wall = make(128, 128, &mut rng); // neutral grey wall
        let red = |src: &I420Buf| {
            let mut img = src.clone();
            fx().process(&mut img, &FxSettings { beauty: 2, lowlight: false, mirror: false });
            1.0 - variance(img.y.iter().map(|&p| p as f32)) / variance(src.y.iter().map(|&p| p as f32))
        };
        let (rs, rw) = (red(&skin), red(&wall));
        assert!(rs > rw + 0.3, "skin {rs:.2} vs wall {rw:.2}");
    }

    #[test]
    fn off_is_bit_exact() {
        let mut rng = Rng(7);
        let mut src = I420Buf::new(320, 240);
        for p in src.y.iter_mut().chain(src.u.iter_mut()).chain(src.v.iter_mut()) {
            *p = (rng.next() * 255.0) as u8;
        }
        // bright scene: low-light boost stays idle
        for p in src.y.iter_mut() {
            *p = (*p / 2).max(16) + 100;
        }
        let mut img = src.clone();
        let mut f = fx();
        for _ in 0..5 {
            img = src.clone();
            f.process(&mut img, &FxSettings { beauty: 0, lowlight: true, mirror: false });
        }
        assert_eq!(img.y, src.y);
        assert_eq!(img.u, src.u);
        assert_eq!(img.v, src.v);
    }

    #[test]
    fn lowlight_converges_clamps_and_does_not_flicker() {
        let (w, h) = (320, 240);
        let mut f = fx();
        let s = FxSettings { beauty: 0, lowlight: true, mirror: false };
        let mut rng = Rng(5);
        // A dark room whose brightness jitters ±3 levels frame to frame (sensor noise / AE).
        let mut gammas = Vec::new();
        for i in 0..400 {
            let base = 45.0 + 3.0 * rng.gauss() + if i % 2 == 0 { 2.0 } else { -2.0 };
            let mut img = flat(w, h, base as u8, 128, 128);
            f.process(&mut img, &s);
            gammas.push(f.lowlight_gamma());
        }
        // eases in, never jumps
        assert!(gammas[0] > 0.98, "first frame must not jump: {}", gammas[0]);
        for p in gammas.windows(2) {
            assert!((p[1] - p[0]).abs() <= LL_MAX_STEP + 1e-6, "gamma jumped {} -> {}", p[0], p[1]);
        }
        // settles: tiny range over the last 200 frames despite the jitter
        let tail = &gammas[200..];
        let (mn, mx) = tail.iter().fold((f32::MAX, f32::MIN), |(a, b), &g| (a.min(g), b.max(g)));
        assert!(mx - mn < 0.02, "gamma keeps moving: {mn}..{mx}");
        assert!(mx < 0.8, "dark scene should be boosted (gamma {mx})");
        // brightened, but the gain is bounded everywhere on the curve
        let lut = *f.luma_lut();
        assert!(lut[45] > 60, "mean not lifted: {}", lut[45]);
        for i in 16..235usize {
            let slope = lut[i + 1] as f32 - lut[i] as f32;
            assert!(slope <= 4.0, "curve too steep at {i}: {slope}");
            assert!(slope >= 0.0, "curve not monotonic at {i}");
        }

        // Pitch black: gamma stops at the clamp, gain bounded.
        let mut f = fx();
        for _ in 0..600 {
            let mut img = flat(w, h, 16, 128, 128);
            f.process(&mut img, &s);
        }
        assert!((f.lowlight_gamma() - LL_MIN_GAMMA).abs() < 0.02, "gamma {}", f.lowlight_gamma());
        let lut = *f.luma_lut();
        assert!((lut[20] as f32 - 16.0) / 4.0 <= 3.6, "shadow gain too high: lut[20] = {}", lut[20]);

        // Lights on: boost fades out smoothly back to identity.
        let mut prev = f.lowlight_gamma();
        for _ in 0..300 {
            let mut img = flat(w, h, 150, 128, 128);
            f.process(&mut img, &s);
            assert!(f.lowlight_gamma() - prev <= LL_MAX_STEP + 1e-6);
            prev = f.lowlight_gamma();
        }
        assert!(prev > 0.995, "boost did not release: {prev}");
        let mut img = flat(w, h, 150, 128, 128);
        f.process(&mut img, &s);
        assert!(img.y.iter().all(|&p| p == 150));
    }

    #[test]
    fn mirror_is_exact_and_involutive() {
        let (w, h) = (34, 20);
        let mut src = I420Buf::new(w, h);
        for (i, p) in src.y.iter_mut().enumerate() {
            *p = (i * 7 % 251) as u8;
        }
        for (i, p) in src.u.iter_mut().enumerate() {
            *p = (i * 3 % 241) as u8;
        }
        for (i, p) in src.v.iter_mut().enumerate() {
            *p = (i * 5 % 239) as u8;
        }
        let mut img = src.clone();
        let mut f = fx();
        f.process(&mut img, &FxSettings { beauty: 0, lowlight: false, mirror: true });
        let cw = w / 2;
        for y in 0..h {
            for x in 0..w {
                assert_eq!(img.y[y * w + x], src.y[y * w + (w - 1 - x)]);
            }
        }
        for y in 0..h / 2 {
            for x in 0..cw {
                assert_eq!(img.u[y * cw + x], src.u[y * cw + (cw - 1 - x)]);
                assert_eq!(img.v[y * cw + x], src.v[y * cw + (cw - 1 - x)]);
            }
        }
        f.process(&mut img, &FxSettings { beauty: 0, lowlight: false, mirror: true });
        assert_eq!(img.y, src.y);
        assert_eq!(img.u, src.u);

        // preview mirroring: left-bright picture shows bright on the right
        let mut p = flat(64, 32, 16, 128, 128);
        for row in p.y.chunks_exact_mut(64) {
            row[..8].fill(235);
        }
        let mut out = Vec::new();
        let (pw, ph) = preview_rgba(&p, true, 32, &mut out);
        assert_eq!((pw, ph), (32, 16));
        assert_eq!(out[(pw - 1) * 4], 255);
        assert_eq!(out[0], 0);
        let (pw, _) = preview_rgba(&p, false, 1000, &mut out);
        assert_eq!(pw, 64);
        assert_eq!(out[0], 255);
    }

    #[test]
    fn buffers_are_reused_across_frames() {
        let mut f = fx();
        let s = FxSettings { beauty: 2, lowlight: true, mirror: true };
        let mut img = flat(640, 480, 90, SKIN_U, SKIN_V);
        f.process(&mut img, &s);
        let fp = |f: &VideoFx| {
            [&f.s, &f.q, &f.mask, &f.m1, &f.m2, &f.ca, &f.cb, &f.tmp, &f.acc, &f.up_a, &f.up_b]
                .iter()
                .map(|v| (v.as_ptr() as usize, v.capacity()))
                .chain([(f.col_s.as_ptr() as usize, f.col_s.capacity())])
                .collect::<Vec<_>>()
        };
        let before = fp(&f);
        for i in 0..20u8 {
            img.y.fill(80 + i);
            f.process(&mut img, &s);
        }
        assert_eq!(before, fp(&f), "scratch buffers were reallocated");
    }

    #[test]
    fn adaptive_fallback_lowers_internal_resolution() {
        let mut f = VideoFx::new();
        f.set_budget_us(1.0); // impossible budget
        let s = FxSettings { beauty: 2, lowlight: false, mirror: false };
        let mut img = flat(1280, 720, 120, SKIN_U, SKIN_V);
        f.process(&mut img, &s);
        let f0 = f.internal_factor();
        let mut factors = vec![f0];
        for _ in 0..40 {
            f.process(&mut img, &s);
            factors.push(f.internal_factor());
        }
        assert_eq!(f.quality(), Q_TONE_ONLY, "should end in tone-only mode");
        assert!(factors.iter().any(|&x| x == f0 * 2) && factors.iter().any(|&x| x == f0 * 4), "{factors:?}");
        // still applies the tone curve in tone-only mode
        let mut img2 = flat(1280, 720, 120, SKIN_U, SKIN_V);
        f.process(&mut img2, &s);
        assert_ne!(img2.y[0], 120);
        // generous budget: climbs back (after the hold-off)
        f.set_budget_us(1e9);
        let mut small = flat(320, 180, 120, SKIN_U, SKIN_V);
        for _ in 0..600 {
            f.process(&mut small, &s);
        }
        assert_eq!(f.quality(), 0);
    }

    #[test]
    fn odd_and_tiny_sizes_do_not_panic() {
        for (w, h) in [(1, 1), (2, 2), (3, 5), (17, 9), (161, 97), (854, 480)] {
            for beauty in 0..=3 {
                let mut img = flat(w, h, 100, SKIN_U, SKIN_V);
                let mut f = fx();
                f.process(&mut img, &FxSettings { beauty, lowlight: true, mirror: true });
                let mut out = Vec::new();
                preview_rgba(&img, true, 64, &mut out);
            }
        }
    }

    #[test]
    fn settings_round_trip() {
        use std::collections::HashMap;
        let mut kv: HashMap<&str, Vec<u8>> = HashMap::new();
        assert_eq!(FxSettings::from_kv(|k| kv.get(k).cloned()), FxSettings::default());
        for s in [
            FxSettings { beauty: 3, lowlight: false, mirror: true },
            FxSettings { beauty: 1, lowlight: true, mirror: false },
            FxSettings { beauty: 0, lowlight: false, mirror: false },
        ] {
            for (k, v) in s.to_kv() {
                kv.insert(k, v);
            }
            assert_eq!(FxSettings::from_kv(|k| kv.get(k).cloned()), s);
            let c = FxControls::new(FxSettings::default());
            c.store(s);
            assert_eq!(c.load(), s);
        }
        kv.insert(KEY_BEAUTY, b"9".to_vec());
        assert_eq!(FxSettings::from_kv(|k| kv.get(k).cloned()).beauty, MAX_BEAUTY);
        kv.insert(KEY_BEAUTY, b"junk".to_vec());
        assert_eq!(FxSettings::from_kv(|k| kv.get(k).cloned()).beauty, 0);
        let j = serde_json::to_string(&FxSettings { beauty: 2, lowlight: true, mirror: false }).unwrap();
        assert_eq!(serde_json::from_str::<FxSettings>(&j).unwrap().beauty, 2);
    }
}
