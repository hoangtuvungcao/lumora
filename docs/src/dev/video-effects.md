# Video effects (beauty, low light, mirror)

Camera effects run **on the sender, before encoding** (VP8/VP9 or H.264), so the other side sees the
result without needing the feature or a newer version. Code:
`core/crates/lumora-media/src/video_fx.rs` (pure Rust, no ML, no new
dependencies), wired in `lumora-core/src/node/media_pipe.rs` (`CameraFx`).

## Where frames flow

```text
V4L2 webcam (Linux, YUYV → RGBA)  ─┐
lumora_push_camera_yuv (app:       ├─► Capturer ─► encoder thread ─► VideoEncoder::encode_with
  Android/iOS/Windows/macOS: NV12/  │                                    │ RGBA/BGRA → I420 (BT.601),
  YUV_420_888, rotated upright in   │                                    │ or I420 as is (camera_in)
  lumora_media::camera_in → I420)  ─┘
                                                                         │ pre(&mut I420)  ◄── VideoFx::process
                                                                         │                 └─ preview_rgba → self-view stream
                                                                         ▼
                                                   VP8/VP9 (bundled libvpx) or OS H.264 → QUIC
```

The effects work on the I420 picture the encoder already produces, so there is
no extra colour conversion. The same thread then publishes a half-size RGBA
copy of the *processed* picture as the local self-view (`video_stream` with
our own peer id, `local: true`): what you see is what is sent, mirrored like a
mirror.

## Settings

| key (`settings_set`) | store key | default | meaning |
| --- | --- | --- | --- |
| `video_beauty` | `video.beauty` | `0` | 0 off, 1 Nhẹ, 2 Vừa, 3 Mạnh |
| `video_lowlight` | `video.lowlight` | `true` | automatic low-light boost |
| `video_mirror_send` | `video.mirror_send` | `false` | mirror the **sent** picture (the self-view is always mirrored) |

`settings_set` bumps an atomic generation counter; the encoder thread re-reads
the settings on the next frame, so changes apply mid-call (like
`echo_cancel` / `noise_suppression`).

## Algorithms

**Beauty** — a fast guided filter (He & Sun 2015) on luma, self-guided:

1. Block-average `Y` *and* `Y²` to a ~256-px-wide grid (factor 3 at 480p, 5 at
   720p). Averaging `Y²` keeps the variance *inside* each block, so eyelashes,
   brows and hair strands still count as edges although they disappear in the
   small picture.
2. With O(1)-per-pixel box filters: `var = box(Y²) − box(Y)²`,
   `a = var/(var+ε)`, `b = (1−a)·box(Y)`, then `ā = box(a)`, `b̄ = box(b)`.
3. A soft YCbCr skin ellipse (box-filtered, so no hard borders) and the level's
   strength are folded in: `A = 1 − w(1−ā)`, `B = w·b̄ + 128(1−A)`; the
   background gets only a small fraction of the strength (mild denoise).
4. Full resolution: `Y' = lut[A·Y + B]` with `A`, `B` bilinearly upsampled
   (each low-res row is upsampled once into a two-row ring, so the per-pixel
   loop is a contiguous, auto-vectorised lerp + multiply-add; the tone curve is
   a separate table pass).

The tone curve adds a small lift at mid-grey and a gentle smoothstep contrast;
chroma gets a little warmth (+Cr, −Cb/2) and saturation, in fixed point.

| level | ε (σ) | radius (of height) | strength on skin | lift | warmth |
| --- | --- | --- | --- | --- | --- |
| Nhẹ | 7 | 0.8 % | 0.55 | 2.2 % | +1.2 |
| Vừa | 10 | 1.2 % | 0.75 | 3.5 % | +2.0 |
| Mạnh | 14 | 1.6 % | 0.90 | 5 % | +3.0 |

Nhẹ deliberately leaves most skin texture (noise variance −52 % in the unit
test) so it reads as "a better camera", not as a filter.

**Low light** — mean luma of the *input* (no feedback loop), smoothed with an
EMA. Below 38 % of the range, a gamma with a shadow toe
(`((x+k)^γ − k^γ)/((1+k)^γ − k^γ)`, k = 0.03) lifts it towards 38 %; the toe
bounds the slope at black (≤ 3.4×, so shadow noise is not amplified without
limit), `γ ≥ 0.5`. `γ` moves with an EMA, a dead band and at most 0.012 per
frame, so the picture neither flickers nor pumps; it eases out when the light
comes back.

**Mirror** — row reversal of all three planes (off by default so text held up
to the camera reads correctly for the other side).

## Performance budget

`cargo run --release -p lumora-media --no-default-features --example fx_bench`
(one core, adaptive fallback off — the worst case). i5-13420H; the machine was
busy with parallel builds, so ranges are given (P-core moderately loaded →
P-core with a busy SMT sibling; E-core for a "slow device" view). Median per
frame:

| | Tăng sáng (dark) | Lật hình | Làm đẹp Vừa | Vừa + sáng + lật | Vừa on an E-core |
| --- | --- | --- | --- | --- | --- |
| 640×480 | 0.14–0.20 ms | 0.04 ms | 0.91–0.97 ms | 0.94–1.0 ms | 1.7 ms |
| 1280×720 | 0.41–0.60 ms | 0.10–0.14 ms | 1.6–2.7 ms | 1.7–3.0 ms | 3.3 ms |
| 1920×1080 | 0.93–1.5 ms | 0.25–0.36 ms | 2.7–4.3 ms | 3.4–3.7 ms | 5.2 ms |

Live webcam check (`--example fx_camera`, release, not pinned): effects median
3.0–3.5 ms at 720p while the CPU idles between frames (clocks down), H.264
encode ≈ 12 ms; quality level stayed at 0 (budget 6 ms at 30 fps).

Budget targets: ≤ 3 ms at 720p, ≤ 1.5 ms at 480p. No allocation per frame
(all scratch buffers live in `VideoFx`; a unit test checks their pointers and
capacities stay the same).

Quality fallback: `VideoFx` times itself (EMA). Above its budget (≈18 % of the
frame interval, 2.5–6 ms) it coarsens the guided-filter grid ×2, then ×4, then
drops to tone-only (no smoothing); with lots of headroom it steps back up after
a hold-off that doubles each time an upgrade fails again (no oscillation).

Before/after: `cargo run --release -p lumora-media --no-default-features
--example fx_shots -- in.png out_dir` writes `before.png`, `beauty1..3.png`,
`lowlight.png` and `beauty2_lowlight.png`.

## Later: background blur

Not implemented yet (no ML in the core today). Plan:

**Model.** MediaPipe *Selfie Segmentation* / *SelfieSegmenter* (MobileNetV3-style,
Apache-2.0): landscape variant 144×256 input, square 256×256; about 0.25 MB as a
float16 TFLite file (≈0.5 MB float32). Published latency is in the tens of
milliseconds on a phone CPU via TFLite (model card, Pixel-class device); on a
desktop x86 core with a good runtime expect a few ms per inference at 144×256.
Output: a person-probability mask at input resolution.

**Runtime options.**

| option | binary cost | notes |
| --- | --- | --- |
| [`tract`](https://github.com/sonos/tract) (pure Rust, ONNX/NNEF; convert the TFLite with `tf2onnx`) | ~2–4 MB | no native deps, works on every target we build; slower than ORT but fine at 144×256 |
| [`ort`](https://github.com/pykeio/ort) (ONNX Runtime) | ~15–25 MB native lib per platform | fastest on desktop; heavy for mobile and the desktop installers |
| platform APIs on mobile (Android ML Kit *Selfie segmentation*, iOS `VNGeneratePersonSegmentationRequest`) | 0 in the core | the app already owns the camera there: push a mask alongside each frame (`lumora_push_camera_frame` + mask plane) |

Recommendation: `tract` behind a cargo feature (`video-segment`) for desktop,
platform APIs on mobile; ship the model as an optional download so the default
installers do not grow.

**Pipeline (fits the existing `VideoFx` structure).**

1. Downscale `Y` (+chroma) to 144×256, run inference on a *separate* worker
   thread every 2nd frame; the encoder thread always uses the latest mask (one
   frame of latency is invisible), never waits.
2. Temporal EMA on the mask (kills edge shimmer), then refine it with the
   guided filter we already have, guided by full-res luma — this snaps the mask
   to hair and shoulder edges at O(1) per pixel.
3. Blur the background at 1/4 resolution (three box passes ≈ Gaussian, reuse
   `box_mean`), upsample, and composite `out = m·in + (1−m)·blur` on Y, U, V.
4. Cost estimate at 720p on one desktop core: blur + composite ≈ 0.8–1.2 ms on
   the encoder thread, inference 3–8 ms on the worker thread (≈ 10–25 % of one
   core at 15 inferences/s). Same adaptive fallback: drop to every 3rd/4th
   frame, then off, if the budget is exceeded.
5. Settings: `video.bg` (`off` / `blur`), later `image` (virtual background with
   a user picture, same compositing).
