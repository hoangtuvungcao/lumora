# Video codecs

Lumora ships **no H.264 implementation of its own and downloads nothing at run
time** (patent licensing; calls must keep working offline for decades):

* **libvpx VP8/VP9** (BSD-3-Clause + Google's royalty-free patent grant) is
  vendored in `core/third_party/libvpx` (v1.17.0) and compiled into every build
  by `core/crates/lumora-vpx-sys` with the `cc` crate (no configure, make or
  perl, so it cross-compiles to MSVC, Android, iOS, …). On x86_64 libvpx's
  hand-written assembly is assembled with **nasm** (≥ 2.14, or yasm; `$NASM` or
  PATH) — 3× faster than the intrinsics alone. Without an assembler the build
  falls back to intrinsics with a warning; CI sets `LUMORA_VPX_REQUIRE_ASM=1`
  so a release can't silently ship the slow path. AArch64 uses NEON intrinsics.
* **H.264** is used only where the operating system provides it.
* A source-built OpenH264 exists behind the cargo feature `openh264-source`
  (`lumora-media`, `lumora-core`) **for tests/dev only**. CI fails if OpenH264
  shows up in any release dependency graph.

## Matrix

| Platform | H.264 encoder | H.264 decoder | always available |
|---|---|---|---|
| Android | MediaCodec via NDK (`codec/mediacodec.rs`), usually the SoC hardware | MediaCodec | libvpx VP8/VP9, NEON (arm64) / C (armv7) / asm (x86_64) |
| Windows | hardware async MFTs first (Intel Quick Sync, NVIDIA, AMD; D3D11 when the MFT wants it), else Microsoft's software MFT (`codec/mf.rs`) | MF decoder MFT (software) | libvpx + x86 asm |
| macOS | VideoToolbox (`codec/vt.rs`), hardware | VideoToolbox | libvpx (NEON / x86 asm) |
| iOS | VideoToolbox, hardware | VideoToolbox | libvpx (NEON) |
| Linux | VA-API (`codec/vaapi.rs`, libva opened at run time; Intel/AMD GPUs) | VA-API | libvpx + x86 asm |

## Choosing a format (`codec::choose_format`)

Every device announces `Caps { enc, dec, hw_enc, hw_dec }` in an `Ext VIDEO_CAPS`
(0x70, map-encoded) right **before** its call invite, its call answer and its
remote-control request, on the same ordered control stream — no extra round
trip. Each sender then picks, per call/session and re-checked 4×/s (group
members come and go):

1. **H.264** if this device encodes it in hardware and every receiver has an
   H.264 decoder (only OS/hardware ones exist in release builds);
2. else **VP9** for screen sharing when every receiver decodes it and the CPU
   has ≥ 8 threads (`LUMORA_VP9_SCREEN=0/1` overrides) — sharper text, ~1.5×
   the CPU of VP8, so 4-core machines keep 60 fps remote control on VP8;
3. else **VP8**;
4. a receiver that never sent caps is an older build: **H.264 only**. If this
   device has no H.264 encoder (Linux), no video is sent and the UI shows
   "họ cần cập nhật Lumora" (event `video_note`); audio is unaffected.

The media stream header carries the format in flag bits 2–3 (0 = H.264, what
older builds send; 1 = VP8; 2 = VP9), so the receiver picks the decoder per frame
(`VideoDecoder::decode_as`) and a sender may switch on any keyframe. Flag bit 4
says the last 8 header bytes hold the frame sequence number (u32) and the
sender's millisecond clock (u32); older receivers ignore both.

## Loss, reordering and backpressure

* **Sender** (`media_pipe::SendWindow`): each peer has a window of 2 frames
  (more only to cover the base RTT at the frame rate, at most 8) counted until
  the peer acknowledged the whole stream. While a window is full the encoder
  skips frames (the reference chain stays intact), a frame produced anyway is
  dropped and forces a keyframe, a keyframe resets older delta streams, and
  every drop/skip cuts the AIMD bitrate. Latency never piles up in QUIC's send
  buffer (test `latency_stays_bounded_on_a_throttled_link`: ~230 ms on a
  throttled 2 Mbit/s link vs. ~4 s without the window).
* **Receiver** (`lumora_media::FrameSync`): stale/duplicate frames are dropped,
  a frame that skips ahead waits up to 60 ms for the missing one, and after a
  real gap (or a decode error, or a delta dropped by the full decoder queue —
  keyframes are never dropped there) only a keyframe is decoded again. Keyframe
  requests are rate-limited (300 ms, repeated every 1 s while waiting) and name
  one stream (`media_pipe::keyframe_tag`); hosts honour them only from the
  session's viewer / the call's participants, and force at most one keyframe
  per 300 ms however many arrive.
* **Size cap:** peers can't make this device decode more than 4096 on the long
  side / 2304 on the short side (`codec::decode_dims_ok`), checked from the
  VP8/VP9 frame header or the H.264 SPS before any decoder allocates.

## Instant start

* **Probe at start-up** (`codec::start_probe`, called from `lumora_start`,
  `lumorad` and the `video_codec` request): encode + decode a few 320×240 frames
  with the OS H.264 codec on a background thread. The result is cached in
  `<data dir>/video_codecs.json`, keyed by OS, CPU, app version and OS build
  (Android fingerprint / Linux kernel release), so later starts use it at once
  and re-validate in the background. Calls never wait for a probe.
* **Warm standby:** while a hardware H.264 encoder runs, a VP8 encoder of the
  same size is kept initialised. If H.264 fails, that very frame is encoded with
  VP8 as a keyframe (`video::tests::h264_failure_switches_to_vp8_on_the_same_frame`).
* If a receiver's OS H.264 decoder keeps failing on keyframes it stops
  advertising H.264 (`mark_h264_broken`) and re-sends its caps; the sender
  switches to VP8 on its next frame.

Measured (`core/tests/video_e2e.py`, loopback, debug build, 2026-11-06):

| | answer → first decoded frame | switch gap |
|---|---|---|
| VP8 (OS H.264 switched off) | 37–63 ms | — |
| H.264, VA-API on both sides (Intel UHD) | 61 ms | — |
| H.264 fails → VP8 | — | 25–40 ms (about one frame interval at 30 fps) |

On the Android emulator (API 34, x86_64): MediaCodec H.264 → VP8 switch frame
encoded in 6 ms; VP8 first frame 21 ms after creating the encoder.

## Idle screens cost ~0

* X11: the capturer creates a DAMAGE object on the root window and only grabs
  when something was drawn or the pointer moved (plus one refresh every 2 s).
  Idle: 2 grabs in 3 s at 60 fps; busy terminal: ~40 fps (`capture::x11` test,
  Xephyr). This also fixed MIT-SHM, which was attached read-only and failed.
* Windows (DXGI) and Wayland (PipeWire) already deliver frames only on
  presents/damage; macOS polls.
* Every backend: the screen sender skips a frame whose pixels equal the
  previous one (pointer check, then one `memcmp`), unless a keyframe is due.
* VP8 uses a static threshold; VP9 screen tuning skips static blocks.

## Encoder settings

All formats: one access unit per `encode`, no B-frames / no look-ahead, keyframe
on demand + every 2 s, CBR driven by the AIMD bitrate in `media_pipe.rs`.

* VP8: real-time, `cpu-used` −6 below 720p, −8 for 720p screens, −10 from
  1080p, −12 on phones (`LUMORA_VPX_SPEED` overrides), threads by size (≤ 4) with
  token partitions, error-resilient, static threshold, frame dropping for
  camera, screen-content mode for screens.
* VP9: real-time speed 8 (< 720p) / 9, row-mt + tile columns by threads,
  cyclic-refresh AQ (mode 3), `tune-content=screen` for screens.
* H.264: constrained baseline Annex-B, SPS/PPS prepended to every IDR.

### Speed (release, `taskset -c 2-5` = 4 cores of an i5-13420H)

`cargo run --release -p lumora-media --example codec_bench` with `FORMAT`,
`SIZE`, `CONTENT=screen` (synthetic scrolling text, the hardest case; encode
time includes BGRA→I420) or `PATTERN=camera CONTENT=motion THREADS=1` (I420
input, one core):

| Encoder | 1080p screen | 1440p screen | 720p30 camera, 1 core |
|---|---|---|---|
| OpenH264 (old, now dev-only) | 8.9 ms, but rate control dropped half the frames | 8.9 ms, 7 of 60 frames kept | 2.3 ms (7 %) |
| VP8, intrinsics only (before) | 32.5 ms (31 fps) | 55.9 ms (18 fps) | 16.4 ms (49 %) |
| VP8 + asm + tuning (now) | **9.0 ms (111 fps)** | **14.3 ms (70 fps)** | **4.9 ms (14.6 %)** |
| VP9, intrinsics only (before) | 20.0 ms | 36.8 ms | 14.8 ms |
| VP9 + asm (now) | **13.1 ms (76 fps)**, PSNR 35 dB vs VP8 22 dB | **22.9 ms (44 fps)** | 5.2 ms (15.7 %) |
| VA-API H.264, Intel UHD (now) | 7.6 ms incl. conversion (4.4 ms from I420) | 15.5 ms (7.7 ms from I420) | 2.5 ms (CPU side) |

Decode at 1080p (incl. conversion to RGBA): VP8 ≈ 9–10 ms, VP9 ≈ 7.7 ms,
VA-API ≈ 3 ms + RGBA conversion. Windows hardware MFTs and VideoToolbox are
not measured here (no such machine).

## Size

Code + data of the static libvpx (before the linker drops unused parts):
x86_64 Linux 1.26 MB (more with the assembly), Windows 1.30 MB, Android arm64 1.21 MB, armv7 1.08 MB,
x86_64 1.40 MB. The source-built OpenH264 it replaces was 0.77 MB.

## Updating libvpx

```
git clone --depth 1 --branch vX.Y.Z https://chromium.googlesource.com/webm/libvpx /tmp/libvpx
python3 -I core/crates/lumora-vpx-sys/tools/gen_build.py /tmp/libvpx --vendor
```

then bump `VERSION` in the script, build every target — with nasm (variant
`x86_64-asm`) and without (`x86_64`; link errors there name functions that only
exist in `.asm`: add them to `X86_ASM_ONLY`) — and re-run the tests above. Regenerate the Rust bindings with `bindgen` if the public headers
changed (`core/crates/lumora-vpx-sys/src/lib.rs`).
