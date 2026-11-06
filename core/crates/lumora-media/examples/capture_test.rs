//! End-to-end capture test on the current machine:
//! open the capturer (Wayland: a portal permission dialog may appear),
//! grab ~60 frames, H.264-encode them, report fps / latency / bitrate,
//! decode the last frame and save it as PNG.
//!
//! cargo run --release -p lumora-media --example capture_test [-- --frames 60 --fps 30 --kbps 4000]
//! Restore token is cached in target-shots/restore_token.txt so the dialog
//! appears only once.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use lumora_media::{CaptureOptions, VideoDecoder, VideoEncoder};

fn arg(name: &str, default: u32) -> u32 {
    let args: Vec<String> = std::env::args().collect();
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn main() {
    if let Err(e) = run() {
        eprintln!("capture_test FAILED: {e:#}");
        std::process::exit(1);
    }
}

fn run() -> anyhow::Result<()> {
    let frames_wanted = arg("--frames", 60) as usize;
    let fps = arg("--fps", 30);
    let kbps = arg("--kbps", 4000);
    let out_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target-shots");
    std::fs::create_dir_all(&out_dir)?;
    let token_file = out_dir.join("restore_token.txt");
    let restore_token = std::fs::read_to_string(&token_file).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
    println!("restore token cached: {}", restore_token.is_some());

    let t_open = Instant::now();
    let (mut cap, new_token) =
        lumora_media::open_capturer(0, CaptureOptions { fps, cursor: true, restore_token, ..Default::default() })?;
    println!("capturer opened in {:.2}s; displays: {}", t_open.elapsed().as_secs_f64(), serde_json::to_string(&cap.displays())?);
    if let Some(t) = &new_token {
        std::fs::write(&token_file, t)?;
        println!("new restore token saved");
    }

    // First frame (the compositor sends one as soon as the stream starts).
    let first = cap
        .next_frame(Duration::from_secs(10))?
        .ok_or_else(|| anyhow::anyhow!("no frame within 10 s after the stream started"))?;
    println!("first frame {}x{} stride {} {:?} after {:.2}s", first.width, first.height, first.stride, first.format, t_open.elapsed().as_secs_f64());

    let mut enc = VideoEncoder::new(first.width, first.height, fps, kbps)?;
    let mut dec = VideoDecoder::new()?;
    let mut total_bytes = 0usize;
    let mut encoded = 0usize;
    let mut keyframes = 0usize;
    let mut enc_time = Duration::ZERO;
    let mut dec_time = Duration::ZERO;
    let mut max_latency = Duration::ZERO;
    let mut sum_latency = Duration::ZERO;
    let mut last_decoded = None;
    let mut got = 0usize;
    let mut timeouts = 0usize;
    let start = Instant::now();
    let mut frame = Some(first);
    while got < frames_wanted && start.elapsed() < Duration::from_secs(60) {
        let f = match frame.take() {
            Some(f) => f,
            None => match cap.next_frame(Duration::from_millis(500))? {
                Some(f) => f,
                None => {
                    // Static screen: the compositor only sends damaged frames.
                    timeouts += 1;
                    continue;
                }
            },
        };
        got += 1;
        let t0 = Instant::now();
        let e = enc.encode(&f, got == 1)?;
        let te = t0.elapsed();
        enc_time += te;
        if let Some(e) = e {
            total_bytes += e.data.len();
            encoded += 1;
            keyframes += e.keyframe as usize;
            let t1 = Instant::now();
            if let Some(d) = dec.decode(&e.data)? {
                last_decoded = Some(d);
            }
            dec_time += t1.elapsed();
            // capture -> encoded+decoded latency (capture timestamp to now)
            let lat = Duration::from_micros(lumora_media::now_us().saturating_sub(f.ts_us));
            sum_latency += lat;
            max_latency = max_latency.max(lat);
        }
    }
    let secs = start.elapsed().as_secs_f64();
    println!("--- results ---");
    println!("frames captured: {got} in {secs:.2}s => {:.1} fps (requested {fps}); empty waits: {timeouts}", got as f64 / secs);
    println!("frames encoded: {encoded} (keyframes {keyframes}), avg encode {:.2} ms, avg decode {:.2} ms",
        enc_time.as_secs_f64() * 1000.0 / got.max(1) as f64, dec_time.as_secs_f64() * 1000.0 / encoded.max(1) as f64);
    println!("avg bitrate: {:.0} kbps (target {kbps}), avg frame {:.1} KB",
        total_bytes as f64 * 8.0 / secs / 1000.0, total_bytes as f64 / encoded.max(1) as f64 / 1024.0);
    println!("capture->decoded latency: avg {:.1} ms, max {:.1} ms",
        sum_latency.as_secs_f64() * 1000.0 / encoded.max(1) as f64, max_latency.as_secs_f64() * 1000.0);

    let d = last_decoded.ok_or_else(|| anyhow::anyhow!("no frame was decoded"))?;
    let path = out_dir.join("capture.png");
    let file = std::fs::File::create(&path)?;
    let mut pngenc = png::Encoder::new(std::io::BufWriter::new(file), d.width, d.height);
    pngenc.set_color(png::ColorType::Rgba);
    pngenc.set_depth(png::BitDepth::Eight);
    let mut w = pngenc.write_header()?;
    w.write_image_data(&d.data[..(d.width * d.height * 4) as usize])?;
    w.finish()?;
    println!("decoded last frame {}x{} written to {}", d.width, d.height, path.display());
    Ok(())
}
