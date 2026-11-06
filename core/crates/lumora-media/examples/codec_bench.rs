//! Offline encoder benchmark on a synthetic "screen" (text-like noise blocks +
//! scrolling). cargo run --release -p lumora-media --example codec_bench
//! FORMAT=vp8|vp9|h264 (h264 needs an OS codec or --features openh264-source),
//! SIZE=1920x1080 (default), CONTENT=screen|motion|auto.
use std::time::Instant;
use lumora_media::{color, Frame, PixelFormat, VideoDecoder, VideoEncoder};

fn main() -> anyhow::Result<()> {
    let (w, h) = std::env::var("SIZE")
        .ok()
        .and_then(|s| s.split_once('x').and_then(|(a, b)| Some((a.parse().ok()?, b.parse().ok()?))))
        .unwrap_or((1920u32, 1080u32));
    let format = std::env::var("FORMAT").ok().and_then(|f| lumora_media::VideoFormat::parse(&f)).unwrap_or(lumora_media::VideoFormat::Vp8);
    println!("{} {w}x{h}", format.name());
    let mut base = vec![0u8; (w * h * 4) as usize];
    let mut seed = 12345u32;
    for (i, px) in base.chunks_exact_mut(4).enumerate() {
        let (x, y) = (i as u32 % w, i as u32 / w);
        seed = seed.wrapping_mul(1103515245).wrapping_add(12345);
        let text = (y % 20) < 12 && (x % 400) < 300 && (seed >> 16).is_multiple_of(3);
        let v = if text { 30 } else { 235 };
        px.copy_from_slice(&[v, v, v.saturating_sub(10), 255]);
    }
    let camera = std::env::var("PATTERN").is_ok_and(|p| p == "camera");
    let frames: Vec<Frame> = (0..60)
        .map(|t| {
            if camera {
                // camera-like: smooth shading, a moving "head", mild sensor noise
                let mut d = vec![0u8; (w * h * 4) as usize];
                let mut seed = 777u32 ^ t;
                let (cx, cy, r) = ((w / 2 + t * 3) as i32, (h / 2) as i32, (h / 4) as i32);
                for (i, px) in d.chunks_exact_mut(4).enumerate() {
                    let (x, y) = ((i as u32 % w) as i32, (i as u32 / w) as i32);
                    seed = seed.wrapping_mul(1103515245).wrapping_add(12345);
                    let n = ((seed >> 16) % 7) as i32 - 3;
                    let inside = (x - cx).pow(2) + (y - cy).pow(2) < r * r;
                    let base = if inside { 190 } else { 60 + (y * 80 / h as i32) };
                    let v = (base + n).clamp(0, 255) as u8;
                    px.copy_from_slice(&[v / 2, v.saturating_sub(20), v, 255]);
                }
                // camera frames reach the encoder as I420 (see camera_in)
                let mut yuv = color::I420Buf::default();
                color::rgb32_to_i420(&d, (w * 4) as usize, PixelFormat::Bgra, w as usize, h as usize, &mut yuv).unwrap();
                let mut p = yuv.y.clone();
                p.extend_from_slice(&yuv.u);
                p.extend_from_slice(&yuv.v);
                return Frame { width: w, height: h, stride: w, format: PixelFormat::I420, data: p.into(), ts_us: t as u64 * 33_333 };
            }
            // scroll by 4 rows per frame
            let off = ((t * 4) % h) as usize * (w * 4) as usize;
            let mut d = base[off..].to_vec();
            d.extend_from_slice(&base[..off]);
            Frame { width: w, height: h, stride: w * 4, format: PixelFormat::Bgra, data: d.into(), ts_us: t as u64 * 33_333 }
        })
        .collect();
    let mut buf = color::I420Buf::default();
    let t = Instant::now();
    for f in frames.iter().filter(|f| f.format != PixelFormat::I420) {
        color::rgb32_to_i420(&f.data, f.stride as usize, f.format, w as usize, h as usize, &mut buf)?;
    }
    println!("BGRA->I420 1080p: {:.2} ms/frame", t.elapsed().as_secs_f64() * 1000.0 / frames.len() as f64);
    let mut rgba = Vec::new();
    let t = Instant::now();
    for _ in 0..20 {
        if buf.width > 0 {
            color::i420_to_rgba(&buf.as_ref(), &mut rgba)?;
        }
    }
    println!("I420->RGBA 1080p: {:.2} ms/frame", t.elapsed().as_secs_f64() * 1000.0 / 20.0);
    for (name, static_screen) in [("scrolling", false), ("static", true)] {
        let content = match std::env::var("CONTENT").as_deref() {
            Ok("screen") => lumora_media::ContentHint::Screen,
            Ok("motion") => lumora_media::ContentHint::Motion,
            _ => lumora_media::ContentHint::Auto,
        };
        let mut enc = VideoEncoder::with_config(lumora_media::EncoderConfig { fps: 30, content, format, fallback: None,
            bitrate_kbps: std::env::var("KBPS").ok().and_then(|v| v.parse().ok()).unwrap_or(4000),
            threads: std::env::var("THREADS").ok().and_then(|v| v.parse().ok()).unwrap_or(0), ..Default::default() })?;
        let mut dec = VideoDecoder::new()?;
        let (mut te, mut td, mut bytes, mut n) = (0f64, 0f64, 0usize, 0usize);
        let (mut psnr, mut np) = (0f64, 0usize);
        for (i, f) in frames.iter().enumerate() {
            let f = if static_screen { &frames[0] } else { f };
            let t = Instant::now();
            let e = enc.encode(f, i == 0)?;
            if i > 0 { te += t.elapsed().as_secs_f64(); }
            if let Some(e) = e {
                bytes += e.data.len();
                n += 1;
                let t = Instant::now();
                let out = dec.decode_as(e.codec, &e.data)?;
                td += t.elapsed().as_secs_f64();
                if let Some(out) = out.filter(|_| i % 10 == 5) {
                    let mut src = f.data.to_vec();
                    if f.format == PixelFormat::I420 {
                        let y = &f.data[..(w * h) as usize];
                        let (cw, ch) = ((w as usize).div_ceil(2), (h as usize).div_ceil(2));
                        let u = &f.data[(w * h) as usize..(w * h) as usize + cw * ch];
                        let v = &f.data[(w * h) as usize + cw * ch..];
                        let img = color::I420 { width: w as usize, height: h as usize, y, u, v, y_stride: w as usize, uv_stride: cw };
                        color::i420_to_rgba(&img, &mut src)?;
                    } else {
                        color::swap_rb_inplace(&mut src); // BGRA source → RGBA like the decoder
                    }
                    psnr += color::psnr_rgb(&src, &out.data);
                    np += 1;
                }
            }
        }
        if let Some((f, k)) = enc.backend() {
            print!("[{} {}] ", f.name(), k.label());
        }
        println!("{name}: encode {:.2} ms/frame (excl. IDR), decode {:.2} ms, {} frames out, {:.0} kbps @30fps, PSNR {:.1} dB",
            te * 1000.0 / 59.0, td * 1000.0 / n.max(1) as f64, n, bytes as f64 * 8.0 / 2.0 / 1000.0, psnr / np.max(1) as f64);
    }
    Ok(())
}
