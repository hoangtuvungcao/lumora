//! `VideoFx::process` must not allocate once warmed up (it runs on the encoder
//! thread at 30–60 fps). Counts heap allocations made by this thread.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

use lumora_media::color::I420Buf;
use lumora_media::video_fx::{FxSettings, VideoFx};

struct Counting;

thread_local! {
    static ALLOCS: Cell<usize> = const { Cell::new(0) };
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let _ = ALLOCS.try_with(|c| c.set(c.get() + 1));
        System.alloc(l)
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        System.dealloc(p, l)
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        let _ = ALLOCS.try_with(|c| c.set(c.get() + 1));
        System.realloc(p, l, n)
    }
}

#[global_allocator]
static A: Counting = Counting;

fn allocs() -> usize {
    ALLOCS.with(|c| c.get())
}

#[test]
fn process_does_not_allocate_per_frame() {
    let (w, h) = (1280, 720);
    let mut src = I420Buf::new(w, h);
    for (i, p) in src.y.iter_mut().enumerate() {
        *p = 40 + (i * 2654435761 % 37) as u8; // dark-ish and noisy
    }
    src.u.fill(108);
    src.v.fill(152);
    let mut img = src.clone();
    let mut preview = Vec::new();
    let mut fx = VideoFx::new();
    fx.set_adaptive(false);
    for s in [
        FxSettings { beauty: 2, lowlight: true, mirror: true },
        FxSettings { beauty: 3, lowlight: false, mirror: false },
        FxSettings { beauty: 0, lowlight: true, mirror: true },
    ] {
        // warm-up: buffers for this level / the preview are created here
        fx.process(&mut img, &s);
        lumora_media::video_fx::preview_rgba(&img, true, 640, &mut preview);
        let before = allocs();
        for _ in 0..30 {
            img.y.copy_from_slice(&src.y);
            fx.process(&mut img, &s);
            lumora_media::video_fx::preview_rgba(&img, !s.mirror, 640, &mut preview);
        }
        assert_eq!(allocs() - before, 0, "allocated while processing {s:?}");
    }
}
