//! Camera pictures pushed by the host app (Android CameraX, iOS/macOS
//! AVFoundation, Windows Media Foundation) → upright I420 [`Frame`]s.
//!
//! The platforms deliver 4:2:0 YUV in their native layout (I420, NV12, NV21 or
//! Android's YUV_420_888 with arbitrary strides), in sensor orientation. One
//! pass here rotates the picture upright, de-interleaves the chroma and maps
//! full-range ("JPEG") luma/chroma to the video range the encoder and decoders
//! assume — no RGB round trip. When the encoder cannot keep up,
//! [`CameraAdapt`] asks for a 480p picture instead of 720p, which
//! [`yuv420_to_frame`] produces with a bilinear downscale.

use std::time::{Duration, Instant};

use crate::{Frame, PixelFormat};

/// One 4:2:0 picture as delivered by the platform. `u`/`v` may overlap
/// (semi-planar NV12/NV21: `uv_step == 2`, `v == u + 1` or the reverse).
#[derive(Clone, Copy)]
pub struct YuvPlanes<'a> {
    pub width: usize,
    pub height: usize,
    pub y: &'a [u8],
    pub y_stride: usize,
    pub u: &'a [u8],
    pub u_stride: usize,
    pub v: &'a [u8],
    pub v_stride: usize,
    /// Distance in bytes between two chroma samples of a row (1 planar, 2 semi-planar).
    pub uv_step: usize,
}

impl YuvPlanes<'_> {
    /// Minimum lengths of the three planes for the declared geometry.
    pub fn required(width: usize, height: usize, y_stride: usize, u_stride: usize, v_stride: usize, uv_step: usize) -> (usize, usize, usize) {
        let (cw, ch) = (width.div_ceil(2), height.div_ceil(2));
        let y = y_stride * (height - 1) + width;
        let u = u_stride * (ch - 1) + (cw - 1) * uv_step + 1;
        let v = v_stride * (ch - 1) + (cw - 1) * uv_step + 1;
        (y, u, v)
    }

    fn check(&self) -> anyhow::Result<()> {
        if self.width < 16 || self.height < 16 || self.width > 4096 || self.height > 4096 {
            anyhow::bail!("camera picture size {}x{} out of range", self.width, self.height);
        }
        if self.uv_step == 0 || self.uv_step > 4 || self.y_stride < self.width || self.u_stride == 0 || self.v_stride == 0 {
            anyhow::bail!("bad camera plane strides");
        }
        let (y, u, v) = Self::required(self.width, self.height, self.y_stride, self.u_stride, self.v_stride, self.uv_step);
        if self.y.len() < y || self.u.len() < u || self.v.len() < v {
            anyhow::bail!("camera planes too small");
        }
        Ok(())
    }
}

/// Full range (0..255) → video range (Y 16..235, C 16..240).
fn range_luts(full: bool) -> ([u8; 256], [u8; 256]) {
    let mut y = [0u8; 256];
    let mut c = [0u8; 256];
    for i in 0..256 {
        if full {
            y[i] = (16 + (i as u32 * 219 + 127) / 255) as u8;
            c[i] = (128 + ((i as i32 - 128) * 224 + if i >= 128 { 127 } else { -127 }) / 255) as u8;
        } else {
            y[i] = i as u8;
            c[i] = i as u8;
        }
    }
    (y, c)
}

/// Copy one plane rotated `R` degrees clockwise into `dst` (row length `dw`).
/// Works in 32x32 tiles so the transposing cases stay cache friendly.
#[allow(clippy::too_many_arguments)]
fn rotate_plane<const R: u32>(src: &[u8], stride: usize, step: usize, sw: usize, sh: usize, lut: &[u8; 256], dst: &mut [u8], dw: usize) {
    const T: usize = 32;
    if R == 0 && step == 1 {
        for y in 0..sh {
            let s = &src[y * stride..y * stride + sw];
            for (d, &p) in dst[y * dw..y * dw + sw].iter_mut().zip(s) {
                *d = lut[p as usize];
            }
        }
        return;
    }
    for ty in (0..sh).step_by(T) {
        for tx in (0..sw).step_by(T) {
            for sy in ty..(ty + T).min(sh) {
                let row = &src[sy * stride..];
                for sx in tx..(tx + T).min(sw) {
                    let p = lut[row[sx * step] as usize];
                    let (dx, dy) = match R {
                        90 => (sh - 1 - sy, sx),
                        180 => (sw - 1 - sx, sh - 1 - sy),
                        270 => (sy, sw - 1 - sx),
                        _ => (sx, sy),
                    };
                    dst[dy * dw + dx] = p;
                }
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn rotate_dispatch(rot: u32, src: &[u8], stride: usize, step: usize, sw: usize, sh: usize, lut: &[u8; 256], dst: &mut [u8], dw: usize) {
    match rot {
        90 => rotate_plane::<90>(src, stride, step, sw, sh, lut, dst, dw),
        180 => rotate_plane::<180>(src, stride, step, sw, sh, lut, dst, dw),
        270 => rotate_plane::<270>(src, stride, step, sw, sh, lut, dst, dw),
        _ => rotate_plane::<0>(src, stride, step, sw, sh, lut, dst, dw),
    }
}

/// Bilinear resize of a tightly packed plane (16.16 fixed point).
fn scale_plane(src: &[u8], sw: usize, sh: usize, dst: &mut [u8], dw: usize, dh: usize) {
    let fx = ((sw as u64) << 16) / dw as u64;
    let fy = ((sh as u64) << 16) / dh as u64;
    for y in 0..dh {
        let syf = ((y as u64 * 2 + 1) * fy / 2).saturating_sub(1 << 15);
        let y0 = ((syf >> 16) as usize).min(sh - 1);
        let y1 = (y0 + 1).min(sh - 1);
        let wy = (syf & 0xffff) as u32 >> 8;
        let (r0, r1) = (&src[y0 * sw..y0 * sw + sw], &src[y1 * sw..y1 * sw + sw]);
        for (x, d) in dst[y * dw..y * dw + dw].iter_mut().enumerate() {
            let sxf = ((x as u64 * 2 + 1) * fx / 2).saturating_sub(1 << 15);
            let x0 = ((sxf >> 16) as usize).min(sw - 1);
            let x1 = (x0 + 1).min(sw - 1);
            let wx = (sxf & 0xffff) as u32 >> 8;
            let top = r0[x0] as u32 * (256 - wx) + r0[x1] as u32 * wx;
            let bot = r1[x0] as u32 * (256 - wx) + r1[x1] as u32 * wx;
            *d = ((top * (256 - wy) + bot * wy + (1 << 15)) >> 16) as u8;
        }
    }
}

/// Convert one camera picture to an upright, video-range I420 [`Frame`].
///
/// `rotation`: clockwise degrees to make it upright (0/90/180/270; other
/// values are rounded down to a multiple of 90). `full_range`: the source uses
/// 0..255 levels (Android YUV_420_888, Apple `…FullRange`). `max_short`: if the
/// upright picture's short side is larger, it is downscaled to it (even sizes).
pub fn yuv420_to_frame(p: &YuvPlanes<'_>, rotation: u32, full_range: bool, max_short: usize, ts_us: u64) -> anyhow::Result<Frame> {
    p.check()?;
    let rot = (rotation / 90 % 4) * 90;
    // Even crop: 4:2:0 chroma pairs must line up after rotation.
    let (sw, sh) = (p.width & !1, p.height & !1);
    let (rw, rh) = if rot % 180 == 90 { (sh, sw) } else { (sw, sh) };
    let (yl, cl) = range_luts(full_range);

    let mut out = vec![0u8; rw * rh * 3 / 2];
    {
        let (ys, uv) = out.split_at_mut(rw * rh);
        let (us, vs) = uv.split_at_mut(rw * rh / 4);
        rotate_dispatch(rot, p.y, p.y_stride, 1, sw, sh, &yl, ys, rw);
        rotate_dispatch(rot, p.u, p.u_stride, p.uv_step, sw / 2, sh / 2, &cl, us, rw / 2);
        rotate_dispatch(rot, p.v, p.v_stride, p.uv_step, sw / 2, sh / 2, &cl, vs, rw / 2);
    }

    let short = rw.min(rh);
    let (mut w, mut h) = (rw, rh);
    if max_short >= 16 && short > max_short {
        let k = max_short as f64 / short as f64;
        let (dw, dh) = (((rw as f64 * k).round() as usize) & !1, ((rh as f64 * k).round() as usize) & !1);
        if dw >= 16 && dh >= 16 {
            let mut small = vec![0u8; dw * dh * 3 / 2];
            {
                let (sy, suv) = out.split_at(rw * rh);
                let (su, sv) = suv.split_at(rw * rh / 4);
                let (dy, duv) = small.split_at_mut(dw * dh);
                let (du, dv) = duv.split_at_mut(dw * dh / 4);
                scale_plane(sy, rw, rh, dy, dw, dh);
                scale_plane(su, rw / 2, rh / 2, du, dw / 2, dh / 2);
                scale_plane(sv, rw / 2, rh / 2, dv, dw / 2, dh / 2);
            }
            out = small;
            (w, h) = (dw, dh);
        }
    }
    Ok(Frame { width: w as u32, height: h as u32, stride: w as u32, format: PixelFormat::I420, data: out.into(), ts_us })
}

/// Picks the camera resolution from the encoder's back-pressure: 720p while
/// it keeps up, 480p when more than a third of the frames are dropped for two
/// seconds in a row. It tries 720p again after a quiet period that doubles
/// each time 720p turns out too heavy (20 s, 40 s, … up to 5 min).
pub struct CameraAdapt {
    window: Instant,
    sent: u32,
    dropped: u32,
    low: bool,
    clean_since: Instant,
    backoff: Duration,
}

impl Default for CameraAdapt {
    fn default() -> Self {
        Self::new()
    }
}

impl CameraAdapt {
    pub const HIGH: usize = 720;
    pub const LOW: usize = 480;

    pub fn new() -> Self {
        let now = Instant::now();
        Self { window: now, sent: 0, dropped: 0, low: false, clean_since: now, backoff: Duration::from_secs(20) }
    }

    /// Short side to produce for the next frame.
    pub fn max_short(&self) -> usize {
        if self.low {
            Self::LOW
        } else {
            Self::HIGH
        }
    }

    /// Record the result of one push (`busy`: the encoder dropped it).
    pub fn record(&mut self, busy: bool) {
        self.record_at(busy, Instant::now());
    }

    pub fn record_at(&mut self, busy: bool, now: Instant) {
        if busy {
            self.dropped += 1;
        } else {
            self.sent += 1;
        }
        if now.duration_since(self.window) < Duration::from_secs(2) {
            return;
        }
        let total = self.sent + self.dropped;
        let ratio = if total == 0 { 0.0 } else { self.dropped as f32 / total as f32 };
        if !self.low && total >= 20 && ratio > 0.34 {
            self.low = true;
            self.clean_since = now;
            tracing::info!("camera: encoder lagging ({:.0}% dropped), switching to 480p", ratio * 100.0);
        } else if self.low {
            if ratio > 0.1 {
                self.clean_since = now;
            } else if now.duration_since(self.clean_since) >= self.backoff {
                self.low = false;
                self.backoff = (self.backoff * 2).min(Duration::from_secs(300));
                tracing::info!("camera: trying 720p again");
            }
        }
        self.window = now;
        self.sent = 0;
        self.dropped = 0;
    }

    /// Forget the history (new call).
    pub fn reset(&mut self) {
        *self = Self::new();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn picture(w: usize, h: usize) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
        // Y = x + 4*y (mod 256) so every position is recognisable; NV12 chroma.
        let y: Vec<u8> = (0..w * h).map(|i| ((i % w) + 4 * (i / w)) as u8).collect();
        let mut uv = vec![0u8; w * h / 2];
        for cy in 0..h / 2 {
            for cx in 0..w / 2 {
                uv[cy * w + cx * 2] = (cx * 3) as u8;
                uv[cy * w + cx * 2 + 1] = (cy * 5) as u8;
            }
        }
        (y, uv.clone(), uv)
    }

    fn planes<'a>(w: usize, h: usize, y: &'a [u8], uv: &'a [u8]) -> YuvPlanes<'a> {
        YuvPlanes { width: w, height: h, y, y_stride: w, u: uv, u_stride: w, v: &uv[1..], v_stride: w, uv_step: 2 }
    }

    fn at(f: &Frame, x: usize, y: usize) -> u8 {
        f.data[y * f.width as usize + x]
    }

    #[test]
    fn rotations_keep_pixels_where_expected() {
        let (w, h) = (64, 32);
        let (y, uv, _) = picture(w, h);
        let p = planes(w, h, &y, &uv);
        let f0 = yuv420_to_frame(&p, 0, false, 0, 0).unwrap();
        assert_eq!((f0.width, f0.height), (64, 32));
        assert_eq!(at(&f0, 5, 3), y[3 * w + 5]);
        // 90° clockwise: source top-left ends up top-right.
        let f90 = yuv420_to_frame(&p, 90, false, 0, 0).unwrap();
        assert_eq!((f90.width, f90.height), (32, 64));
        assert_eq!(at(&f90, 31, 0), y[0]);
        assert_eq!(at(&f90, 0, 0), y[(h - 1) * w]);
        let f180 = yuv420_to_frame(&p, 180, false, 0, 0).unwrap();
        assert_eq!(at(&f180, 63, 31), y[0]);
        let f270 = yuv420_to_frame(&p, 270, false, 0, 0).unwrap();
        assert_eq!((f270.width, f270.height), (32, 64));
        assert_eq!(at(&f270, 0, 63), y[0]);
        // Chroma of NV12 de-interleaved: U plane follows Y.
        let u0 = &f0.data[w * h..];
        assert_eq!(u0[w / 2 + 7], 21); // cx=7 → 21
        let v0 = &f0.data[w * h + w * h / 4..];
        assert_eq!(v0[2 * (w / 2) + 7], 10); // cy=2 → 10
        // Validated by the encoder's checks.
        f90.validate().unwrap();
    }

    #[test]
    fn full_range_is_mapped_to_video_range() {
        let (w, h) = (16, 16);
        let y = vec![0u8; w * h];
        let mut uv = vec![255u8; w * h / 2];
        uv[0] = 0;
        let p = planes(w, h, &y, &uv);
        let f = yuv420_to_frame(&p, 0, true, 0, 0).unwrap();
        assert_eq!(f.data[0], 16);
        assert_eq!(f.data[w * h], 16); // U = 0 → 16
        assert_eq!(f.data[w * h + 1], 240); // U = 255 → 240
    }

    #[test]
    fn downscale_to_480p() {
        let (w, h) = (1280, 720);
        let (y, uv, _) = picture(w, h);
        let p = planes(w, h, &y, &uv);
        let f = yuv420_to_frame(&p, 90, false, 480, 0).unwrap();
        assert_eq!((f.width, f.height), (480, 852));
        f.validate().unwrap();
        let f = yuv420_to_frame(&p, 0, false, 720, 0).unwrap();
        assert_eq!((f.width, f.height), (1280, 720));
    }

    #[test]
    fn rejects_short_planes() {
        let y = vec![0u8; 100];
        let p = YuvPlanes { width: 64, height: 64, y: &y, y_stride: 64, u: &y, u_stride: 32, v: &y, v_stride: 32, uv_step: 1 };
        assert!(yuv420_to_frame(&p, 0, false, 0, 0).is_err());
    }

    #[test]
    fn adapt_drops_to_480_and_recovers() {
        let mut a = CameraAdapt::new();
        let t0 = Instant::now();
        for i in 0..60u64 {
            a.record_at(i % 2 == 0, t0 + Duration::from_millis(i * 34));
        }
        assert_eq!(a.max_short(), 480);
        let t1 = t0 + Duration::from_secs(3);
        for i in 0..(30 * 25) {
            a.record_at(false, t1 + Duration::from_millis(i * 33));
        }
        assert_eq!(a.max_short(), 720);
    }
}
