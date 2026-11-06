//! Colour-space conversion between packed 32-bit RGB (BGRA/RGBA) and planar I420.
//!
//! Uses BT.601 limited ("TV") range with 8-bit fixed-point coefficients, which is
//! what H.264 decoders assume when the bitstream carries no VUI colour description.
//! The loops are written row-by-row over slices without bounds checks in the hot
//! path so LLVM can vectorise them.

use crate::PixelFormat;

/// A borrowed I420 (YUV 4:2:0 planar) image.
#[derive(Debug, Clone, Copy)]
pub struct I420<'a> {
    pub width: usize,
    pub height: usize,
    pub y: &'a [u8],
    pub u: &'a [u8],
    pub v: &'a [u8],
    pub y_stride: usize,
    pub uv_stride: usize,
}

/// Owned I420 buffer (tightly packed planes).
#[derive(Debug, Clone, Default)]
pub struct I420Buf {
    pub width: usize,
    pub height: usize,
    pub y: Vec<u8>,
    pub u: Vec<u8>,
    pub v: Vec<u8>,
}

impl I420Buf {
    pub fn new(width: usize, height: usize) -> Self {
        let cw = width.div_ceil(2);
        let ch = height.div_ceil(2);
        Self { width, height, y: vec![0; width * height], u: vec![128; cw * ch], v: vec![128; cw * ch] }
    }

    pub fn resize(&mut self, width: usize, height: usize) {
        if self.width != width || self.height != height {
            *self = Self::new(width, height);
        }
    }

    pub fn as_ref(&self) -> I420<'_> {
        I420 {
            width: self.width,
            height: self.height,
            y: &self.y,
            u: &self.u,
            v: &self.v,
            y_stride: self.width,
            uv_stride: self.width.div_ceil(2),
        }
    }
}

#[inline(always)]
fn rgb_to_y(r: i32, g: i32, b: i32) -> u8 {
    (((66 * r + 129 * g + 25 * b + 128) >> 8) + 16) as u8
}
#[inline(always)]
fn rgb_to_u(r: i32, g: i32, b: i32) -> u8 {
    (((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128) as u8
}
#[inline(always)]
fn rgb_to_v(r: i32, g: i32, b: i32) -> u8 {
    (((112 * r - 94 * g - 18 * b + 128) >> 8) + 128) as u8
}

/// Convert packed 32-bit RGB to I420. `width`/`height` is the region to convert
/// (may be smaller than the source, e.g. cropped to even dimensions).
///
/// Returns an error if the source buffer is too small.
pub fn rgb32_to_i420(
    src: &[u8],
    stride: usize,
    format: PixelFormat,
    width: usize,
    height: usize,
    dst: &mut I420Buf,
) -> anyhow::Result<()> {
    if width == 0 || height == 0 {
        anyhow::bail!("cannot convert an empty image ({width}x{height})");
    }
    if stride < width * 4 || src.len() < stride * (height - 1) + width * 4 {
        anyhow::bail!(
            "source buffer too small: {} bytes for {width}x{height} with stride {stride}",
            src.len()
        );
    }
    dst.resize(width, height);
    let (ri, bi) = match format {
        PixelFormat::Bgra => (2usize, 0usize),
        PixelFormat::Rgba => (0, 2),
        PixelFormat::I420 => anyhow::bail!("rgb32_to_i420: source is already I420"),
    };
    let cw = width.div_ceil(2);
    let ch = height.div_ceil(2);

    // Luma.
    for row in 0..height {
        let s = &src[row * stride..row * stride + width * 4];
        let d = &mut dst.y[row * width..(row + 1) * width];
        for (px, out) in s.chunks_exact(4).zip(d.iter_mut()) {
            *out = rgb_to_y(px[ri] as i32, px[1] as i32, px[bi] as i32);
        }
    }

    // Chroma: average each 2x2 block.
    for cy in 0..ch {
        let r0 = cy * 2;
        let r1 = (r0 + 1).min(height - 1);
        let s0 = &src[r0 * stride..r0 * stride + width * 4];
        let s1 = &src[r1 * stride..r1 * stride + width * 4];
        let du = &mut dst.u[cy * cw..(cy + 1) * cw];
        let dv = &mut dst.v[cy * cw..(cy + 1) * cw];
        for cx in 0..cw {
            let x0 = cx * 2 * 4;
            let x1 = ((cx * 2 + 1).min(width - 1)) * 4;
            let r = s0[x0 + ri] as i32 + s0[x1 + ri] as i32 + s1[x0 + ri] as i32 + s1[x1 + ri] as i32;
            let g = s0[x0 + 1] as i32 + s0[x1 + 1] as i32 + s1[x0 + 1] as i32 + s1[x1 + 1] as i32;
            let b = s0[x0 + bi] as i32 + s0[x1 + bi] as i32 + s1[x0 + bi] as i32 + s1[x1 + bi] as i32;
            let (r, g, b) = ((r + 2) >> 2, (g + 2) >> 2, (b + 2) >> 2);
            du[cx] = rgb_to_u(r, g, b);
            dv[cx] = rgb_to_v(r, g, b);
        }
    }
    Ok(())
}

#[inline(always)]
fn clamp(v: i32) -> u8 {
    v.clamp(0, 255) as u8
}

/// Convert an I420 image to tightly packed RGBA (alpha = 255).
pub fn i420_to_rgba(src: &I420<'_>, out: &mut Vec<u8>) -> anyhow::Result<()> {
    let (w, h) = (src.width, src.height);
    if w == 0 || h == 0 {
        anyhow::bail!("cannot convert an empty image ({w}x{h})");
    }
    let ch = h.div_ceil(2);
    let cw = w.div_ceil(2);
    if src.y.len() < src.y_stride * (h - 1) + w
        || src.u.len() < src.uv_stride * (ch - 1) + cw
        || src.v.len() < src.uv_stride * (ch - 1) + cw
    {
        anyhow::bail!("I420 planes too small for {w}x{h}");
    }
    out.clear();
    out.resize(w * h * 4, 0);
    for row in 0..h {
        let yrow = &src.y[row * src.y_stride..row * src.y_stride + w];
        let urow = &src.u[(row / 2) * src.uv_stride..(row / 2) * src.uv_stride + cw];
        let vrow = &src.v[(row / 2) * src.uv_stride..(row / 2) * src.uv_stride + cw];
        let orow = &mut out[row * w * 4..(row + 1) * w * 4];
        // Two luma samples share one chroma pair: compute chroma terms once.
        for ((pair, ys), (&u, &v)) in orow.chunks_mut(8).zip(yrow.chunks(2)).zip(urow.iter().zip(vrow.iter())) {
            let d = u as i32 - 128;
            let e = v as i32 - 128;
            let (rv, gv, bv) = (409 * e + 128, -100 * d - 208 * e + 128, 516 * d + 128);
            for (px, &yy) in pair.chunks_exact_mut(4).zip(ys.iter()) {
                let c = 298 * (yy as i32 - 16);
                px[0] = clamp((c + rv) >> 8);
                px[1] = clamp((c + gv) >> 8);
                px[2] = clamp((c + bv) >> 8);
                px[3] = 255;
            }
        }
    }
    Ok(())
}

/// Swap BGRA <-> RGBA in place (tightly packed or strided rows of `width` pixels).
pub fn swap_rb_inplace(data: &mut [u8]) {
    for px in data.chunks_exact_mut(4) {
        px.swap(0, 2);
    }
}

/// Peak signal-to-noise ratio between two equally sized RGB(A) buffers, comparing
/// only the first three channels of every pixel. Returns `f64::INFINITY` when equal.
pub fn psnr_rgb(a: &[u8], b: &[u8]) -> f64 {
    let mut se = 0f64;
    let mut n = 0usize;
    for (pa, pb) in a.chunks_exact(4).zip(b.chunks_exact(4)) {
        for c in 0..3 {
            let d = pa[c] as f64 - pb[c] as f64;
            se += d * d;
            n += 1;
        }
    }
    if n == 0 || se == 0.0 {
        return f64::INFINITY;
    }
    let mse = se / n as f64;
    10.0 * (255.0f64 * 255.0 / mse).log10()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(w: usize, h: usize, rgba: [u8; 4]) -> Vec<u8> {
        rgba.iter().copied().cycle().take(w * h * 4).collect()
    }

    #[test]
    fn known_colours_bt601() {
        // (R,G,B) -> expected (Y,U,V), limited range BT.601.
        let cases = [
            ([0u8, 0, 0], (16u8, 128u8, 128u8)),
            ([255, 255, 255], (235, 128, 128)),
            ([255, 0, 0], (82, 90, 240)),
            ([0, 255, 0], (145, 54, 34)),
            ([0, 0, 255], (41, 240, 110)),
        ];
        for (rgb, (ey, eu, ev)) in cases {
            let src = solid(4, 4, [rgb[0], rgb[1], rgb[2], 255]);
            let mut buf = I420Buf::default();
            rgb32_to_i420(&src, 16, PixelFormat::Rgba, 4, 4, &mut buf).unwrap();
            assert!((buf.y[0] as i32 - ey as i32).abs() <= 1, "Y for {rgb:?}: {}", buf.y[0]);
            assert!((buf.u[0] as i32 - eu as i32).abs() <= 1, "U for {rgb:?}: {}", buf.u[0]);
            assert!((buf.v[0] as i32 - ev as i32).abs() <= 1, "V for {rgb:?}: {}", buf.v[0]);
        }
    }

    #[test]
    fn bgra_and_rgba_agree() {
        let rgba = solid(6, 2, [200, 100, 50, 255]);
        let bgra = solid(6, 2, [50, 100, 200, 255]);
        let mut a = I420Buf::default();
        let mut b = I420Buf::default();
        rgb32_to_i420(&rgba, 24, PixelFormat::Rgba, 6, 2, &mut a).unwrap();
        rgb32_to_i420(&bgra, 24, PixelFormat::Bgra, 6, 2, &mut b).unwrap();
        assert_eq!(a.y, b.y);
        assert_eq!(a.u, b.u);
        assert_eq!(a.v, b.v);
    }

    #[test]
    fn roundtrip_is_close() {
        let (w, h) = (64usize, 48usize);
        let mut src = vec![0u8; w * h * 4];
        for y in 0..h {
            for x in 0..w {
                let p = &mut src[(y * w + x) * 4..][..4];
                // Smooth gradients (chroma subsampling is lossy on sharp edges).
                p[0] = (x * 4) as u8;
                p[1] = (y * 5) as u8;
                p[2] = 128;
                p[3] = 255;
            }
        }
        let mut buf = I420Buf::default();
        rgb32_to_i420(&src, w * 4, PixelFormat::Rgba, w, h, &mut buf).unwrap();
        let mut out = Vec::new();
        i420_to_rgba(&buf.as_ref(), &mut out).unwrap();
        let p = psnr_rgb(&src, &out);
        assert!(p > 38.0, "colour roundtrip PSNR too low: {p}");
    }

    #[test]
    fn odd_dimensions_and_stride() {
        let (w, h, stride) = (5usize, 3usize, 32usize);
        let src = vec![77u8; stride * h];
        let mut buf = I420Buf::default();
        rgb32_to_i420(&src, stride, PixelFormat::Bgra, w, h, &mut buf).unwrap();
        assert_eq!(buf.u.len(), 3 * 2);
        let mut out = Vec::new();
        i420_to_rgba(&buf.as_ref(), &mut out).unwrap();
        assert_eq!(out.len(), w * h * 4);
    }

    #[test]
    fn too_small_buffer_is_an_error() {
        let mut buf = I420Buf::default();
        assert!(rgb32_to_i420(&[0u8; 10], 16, PixelFormat::Bgra, 4, 4, &mut buf).is_err());
        assert!(rgb32_to_i420(&[], 0, PixelFormat::Bgra, 0, 0, &mut buf).is_err());
    }
}
