//! Camera-effects benchmark (single core, the encoder thread's budget).
//!
//! ```sh
//! cargo run --release -p lumora-media --no-default-features --example fx_bench
//! ```
//! Prints median / p95 time per frame for each beauty level at 480p, 720p and
//! 1080p with the adaptive fallback disabled (worst case: full quality).

use std::time::Instant;

use lumora_media::color::I420Buf;
use lumora_media::video_fx::{FxSettings, VideoFx};

/// Face-like test picture: skin ellipse with noise on a grey background.
fn picture(w: usize, h: usize) -> I420Buf {
    let mut b = I420Buf::new(w, h);
    let mut seed = 0x1234_5678_9abc_def0u64;
    let mut rnd = || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        ((seed >> 40) as f32 / (1u64 << 24) as f32 - 0.5) * 24.0
    };
    let (cx, cy, rx, ry) = (w as f32 * 0.5, h as f32 * 0.5, w as f32 * 0.18, h as f32 * 0.38);
    for y in 0..h {
        for x in 0..w {
            let d = ((x as f32 - cx) / rx).powi(2) + ((y as f32 - cy) / ry).powi(2);
            let base = if d < 1.0 { 160.0 } else { 110.0 };
            b.y[y * w + x] = (base + rnd()).clamp(16.0, 235.0) as u8;
        }
    }
    let cw = w.div_ceil(2);
    for y in 0..h.div_ceil(2) {
        for x in 0..cw {
            let d = ((2 * x) as f32 - cx).powi(2) / (rx * rx) + ((2 * y) as f32 - cy).powi(2) / (ry * ry);
            let skin = d < 1.0;
            b.u[y * cw + x] = if skin { 108 } else { 128 };
            b.v[y * cw + x] = if skin { 152 } else { 128 };
        }
    }
    b
}

fn main() {
    let iters = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(300usize);
    println!("{:<10} {:<22} {:>9} {:>9} {:>9}", "size", "effect", "median", "p95", "factor");
    for (name, w, h) in [("480p", 640usize, 480usize), ("480p-wide", 854, 480), ("720p", 1280, 720), ("1080p", 1920, 1080)] {
        let src = picture(w, h);
        for (label, s) in [
            ("tăng sáng (dark)", FxSettings { beauty: 0, lowlight: true, mirror: false }),
            ("lật hình", FxSettings { beauty: 0, lowlight: false, mirror: true }),
            ("làm đẹp Nhẹ", FxSettings { beauty: 1, lowlight: false, mirror: false }),
            ("làm đẹp Vừa", FxSettings { beauty: 2, lowlight: false, mirror: false }),
            ("làm đẹp Mạnh", FxSettings { beauty: 3, lowlight: false, mirror: false }),
            ("Vừa + sáng + lật", FxSettings { beauty: 2, lowlight: true, mirror: true }),
        ] {
            let mut fx = VideoFx::new();
            fx.set_adaptive(false);
            let mut img = src.clone();
            if label.contains("dark") || label.contains("sáng +") {
                // make the scene dark so the boost (and its LUT pass) is active
                for p in img.y.iter_mut() {
                    *p = 16 + (*p - 16) / 4;
                }
            }
            let base = img.clone();
            let mut times = Vec::with_capacity(iters);
            for i in 0..iters + 30 {
                img.y.copy_from_slice(&base.y);
                img.u.copy_from_slice(&base.u);
                img.v.copy_from_slice(&base.v);
                let t = Instant::now();
                fx.process(&mut img, &s);
                if i >= 30 {
                    times.push(t.elapsed().as_secs_f64() * 1e3);
                }
            }
            times.sort_by(|a, b| a.partial_cmp(b).unwrap());
            let med = times[times.len() / 2];
            let p95 = times[times.len() * 95 / 100];
            println!("{name:<10} {label:<22} {med:>7.3}ms {p95:>7.3}ms {:>9}", fx.internal_factor());
        }
    }
}
