//! Before/after pictures for the camera effects.
//!
//! ```sh
//! cargo run --release -p lumora-media --no-default-features --example fx_shots -- in.png out_dir
//! ```
//! Writes `before.png`, `beauty1..3.png`, `lowlight.png` and `beauty2_lowlight.png`
//! (each after enough frames for the low-light boost to settle).

use lumora_media::color::{i420_to_rgba, rgb32_to_i420, I420Buf};
use lumora_media::video_fx::{FxSettings, VideoFx};
use lumora_media::PixelFormat;

fn load(path: &str) -> (Vec<u8>, usize, usize) {
    let dec = png::Decoder::new(std::io::BufReader::new(std::fs::File::open(path).expect("open input")));
    let mut r = dec.read_info().expect("png header");
    let mut buf = vec![0; r.output_buffer_size().expect("size")];
    let info = r.next_frame(&mut buf).expect("png data");
    let (w, h) = (info.width as usize, info.height as usize);
    let rgba = match info.color_type {
        png::ColorType::Rgba => buf[..w * h * 4].to_vec(),
        png::ColorType::Rgb => buf[..w * h * 3].chunks_exact(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
        t => panic!("unsupported PNG colour type {t:?}"),
    };
    (rgba, w, h)
}

fn save(path: &str, img: &I420Buf) {
    let mut rgba = Vec::new();
    i420_to_rgba(&img.as_ref(), &mut rgba).unwrap();
    let f = std::fs::File::create(path).expect("create output");
    let mut e = png::Encoder::new(std::io::BufWriter::new(f), img.width as u32, img.height as u32);
    e.set_color(png::ColorType::Rgba);
    e.set_depth(png::BitDepth::Eight);
    e.write_header().unwrap().write_image_data(&rgba).unwrap();
    println!("wrote {path}");
}

fn main() {
    let mut args = std::env::args().skip(1);
    let input = args.next().expect("usage: fx_shots in.png out_dir");
    let out = args.next().unwrap_or_else(|| ".".into());
    let (rgba, w, h) = load(&input);
    let (w, h) = (w & !1, h & !1);
    let mut src = I420Buf::default();
    rgb32_to_i420(&rgba, (rgba.len() / h.max(1)).max(w * 4), PixelFormat::Rgba, w, h, &mut src).unwrap();
    save(&format!("{out}/before.png"), &src);
    for (name, s) in [
        ("beauty1", FxSettings { beauty: 1, lowlight: false, mirror: false }),
        ("beauty2", FxSettings { beauty: 2, lowlight: false, mirror: false }),
        ("beauty3", FxSettings { beauty: 3, lowlight: false, mirror: false }),
        ("lowlight", FxSettings { beauty: 0, lowlight: true, mirror: false }),
        ("beauty2_lowlight", FxSettings { beauty: 2, lowlight: true, mirror: false }),
    ] {
        let mut fx = VideoFx::new();
        fx.set_adaptive(false);
        let mut img = src.clone();
        for _ in 0..120 {
            img = src.clone();
            fx.process(&mut img, &s);
        }
        println!("{name}: {:.2} ms, gamma {:.3}", fx.last_us() / 1000.0, fx.lowlight_gamma());
        save(&format!("{out}/{name}.png"), &img);
    }
}
