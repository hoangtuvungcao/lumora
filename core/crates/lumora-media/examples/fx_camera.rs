//! Live check of the call pipeline with effects (Linux webcam):
//! V4L2 → `VideoEncoder::encode_with` (VideoFx + self-view preview) → H.264 →
//! `VideoDecoder`. Saves what the other side decodes and the local self-view.
//!
//! ```sh
//! cargo run --release -p lumora-media --features camera-v4l --example fx_camera -- out_dir [beauty] [mirror]
//! ```

use std::time::{Duration, Instant};

use lumora_media::video_fx::{preview_rgba, FxSettings, VideoFx};
use lumora_media::{VideoDecoder, VideoEncoder};

fn save(path: &str, w: usize, h: usize, rgba: &[u8]) {
    let f = std::fs::File::create(path).expect("create");
    let mut e = png::Encoder::new(std::io::BufWriter::new(f), w as u32, h as u32);
    e.set_color(png::ColorType::Rgba);
    e.set_depth(png::BitDepth::Eight);
    e.write_header().unwrap().write_image_data(&rgba[..w * h * 4]).unwrap();
    println!("wrote {path} ({w}x{h})");
}

fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let out = args.next().unwrap_or_else(|| ".".into());
    let beauty: u8 = args.next().and_then(|s| s.parse().ok()).unwrap_or(2);
    let mirror = args.next().map(|s| s == "1" || s == "mirror").unwrap_or(false);
    let s = FxSettings { beauty, lowlight: true, mirror };
    let mut cam = lumora_media::camera::open_camera(0, 1280, 720, 30)?;
    println!("camera {}x{}, effects {s:?}", cam.width, cam.height);
    let mut enc: Option<VideoEncoder> = None;
    let mut dec = VideoDecoder::new()?;
    let mut fx = VideoFx::new();
    fx.set_frame_rate(30);
    let mut preview = Vec::new();
    let mut psize = (0, 0);
    let (mut fx_ms, mut enc_ms, mut n) = (Vec::new(), 0.0, 0);
    let mut last = None;
    let t_start = Instant::now();
    while n < 90 {
        let Some(f) = cam.next_frame(Duration::from_secs(2))? else { continue };
        let e = match enc.as_mut() {
            Some(e) => e,
            None => enc.insert(VideoEncoder::new(f.width, f.height, 30, 2500)?),
        };
        let t = Instant::now();
        let r = e.encode_with(&f, n == 0, |yuv| {
            fx.process(yuv, &s);
            fx_ms.push(fx.last_us() / 1000.0);
            psize = preview_rgba(yuv, !s.mirror, 640, &mut preview);
        })?;
        enc_ms += t.elapsed().as_secs_f64() * 1e3;
        if let Some(ef) = r {
            if let Some(fr) = dec.decode(&ef.data)? {
                last = Some(fr);
            }
        }
        n += 1;
    }
    let secs = t_start.elapsed().as_secs_f64();
    fx_ms.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!(
        "{n} frames in {secs:.1} s ({:.1} fps): effects median {:.2} ms p95 {:.2} ms, effects+encode avg {:.2} ms, quality level {}, gamma {:.3}",
        n as f64 / secs,
        fx_ms[fx_ms.len() / 2],
        fx_ms[fx_ms.len() * 95 / 100],
        enc_ms / n as f64,
        fx.quality(),
        fx.lowlight_gamma()
    );
    let tag = format!("b{beauty}{}", if mirror { "_mirror" } else { "" });
    save(&format!("{out}/live_selfview_{tag}.png"), psize.0, psize.1, &preview);
    if let Some(fr) = last {
        save(&format!("{out}/live_remote_{tag}.png"), fr.width as usize, fr.height as usize, &fr.data);
    }
    Ok(())
}
