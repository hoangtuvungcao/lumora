//! Audio smoke test: capture 1 s from the default microphone, Opus-encode it,
//! and run the speaker with a jitter buffer fed with encoded *silence*
//! (nothing audible is played). cargo run -p lumora-media --example audio_test
use std::time::{Duration, Instant};

use lumora_media::audio::{list_devices, AudioCapture, AudioPlayer, OpusEncoder, FRAME_SAMPLES};

fn main() -> anyhow::Result<()> {
    for d in list_devices().iter().filter(|d| d.default) {
        println!("default device: {} (in={}, out={})", d.name, d.input, d.output);
    }
    let cap = AudioCapture::start(None)?;
    let mut enc = OpusEncoder::new(24_000)?;
    let (mut frames, mut bytes, mut peak) = (0usize, 0usize, 0i16);
    let t = Instant::now();
    while t.elapsed() < Duration::from_secs(1) {
        if let Some(f) = cap.next_frame(Duration::from_millis(200))? {
            peak = peak.max(f.iter().map(|s| s.saturating_abs()).max().unwrap_or(0));
            bytes += enc.encode(&f)?.len();
            frames += 1;
        }
    }
    println!("mic: {frames} frames of {FRAME_SAMPLES} samples in 1 s, peak {peak}, opus {:.1} kbps", bytes as f64 * 8.0 / 1000.0);
    drop(cap);

    let player = AudioPlayer::start(None)?;
    let silence = vec![0i16; FRAME_SAMPLES];
    for seq in 0..50u16 {
        player.push_packet(seq, enc.encode(&silence)?);
        std::thread::sleep(Duration::from_millis(20));
    }
    println!("player jitter stats: {}", serde_json::to_string(&player.stats())?);
    Ok(())
}
