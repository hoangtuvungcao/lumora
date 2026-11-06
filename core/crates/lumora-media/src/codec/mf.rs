//! Windows Media Foundation H.264 backend (OS licence: the H.264 encoder and
//! decoder MFTs ship with Windows).
//!
//! Encoder: first a *hardware* encoder MFT (Intel Quick Sync, NVIDIA NVENC,
//! AMD AMF — asynchronous MFTs driven through their event queue, with a D3D11
//! device manager and NV12 GPU textures when the MFT is D3D11-aware; licensed
//! by the GPU vendor), else the synchronous Microsoft "H264 Encoder MFT" or a
//! vendor's sync MFT (software). Decoder: the synchronous Microsoft "H264
//! Decoder MFT" (`CLSID_CMSH264DecoderMFT`) or another sync one; without a D3D
//! device manager it runs in software. Windows "N" editions without the
//! Media Feature Pack have neither — the probe then reports no H.264 and calls
//! use the bundled VP8/VP9.
//!
//! Encoder: constrained-baseline profile, low-latency mode, CBR, no B-frames,
//! GOP = fps × keyframe interval, keyframe on request
//! (`CODECAPI_AVEncVideoForceKeyFrame`), bitrate changes on the fly
//! (`CODECAPI_AVEncCommonMeanBitRate`). Input is IYUV/I420 (no conversion) or
//! NV12. Output is Annex-B; SPS/PPS from the output type's sequence header are
//! prepended to keyframes that lack them.
//!
//! Decoder: low-latency mode, NV12 (or I420) output, pitch from `IMF2DBuffer`
//! / `MF_MT_DEFAULT_STRIDE`, cropped to `MF_MT_MINIMUM_DISPLAY_APERTURE` (or
//! the SPS size).

use std::collections::VecDeque;
use std::mem::ManuallyDrop;
use std::sync::OnceLock;

use windows::core::{Interface, GUID};
use windows::Win32::Foundation::HMODULE;
use windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_UNKNOWN};
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, ID3D11DeviceContext, ID3D11Multithread, ID3D11Texture2D, D3D11_BIND_RENDER_TARGET,
    D3D11_CPU_ACCESS_WRITE, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_CREATE_DEVICE_VIDEO_SUPPORT, D3D11_MAPPED_SUBRESOURCE,
    D3D11_MAP_WRITE, D3D11_SDK_VERSION, D3D11_TEXTURE2D_DESC, D3D11_USAGE_DEFAULT, D3D11_USAGE_STAGING,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_NV12, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::{CreateDXGIFactory1, IDXGIAdapter, IDXGIAdapter1, IDXGIFactory1};
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
use windows::Win32::System::Variant::VARIANT;

use super::annexb::{self, has_idr, nal_type, nals, NAL_SPS};
use super::{check_decode_dims, check_h264_au, DecBackend, EncBackend, EncParams, YuvView};
use crate::color::I420Buf;

// ------------------------------------------------------------------ setup

thread_local! {
    static COM_INIT: () = {
        // SAFETY: plain COM initialisation of the current thread (MTA). A thread
        // already in an STA returns RPC_E_CHANGED_MODE, which is fine: the H.264
        // MFTs are free-threaded ("Both").
        let _ = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    };
}

/// COM on this thread + `MFStartup` once per process.
fn startup() -> anyhow::Result<()> {
    COM_INIT.with(|_| {});
    static MF: OnceLock<Result<(), String>> = OnceLock::new();
    MF.get_or_init(|| {
        // SAFETY: MFStartup has no preconditions; never shut down (process-wide).
        unsafe { MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET) }.map_err(|e| format!("MFStartup failed: {e}"))
    })
    .clone()
    .map_err(|e| anyhow::anyhow!(e))
}

fn hr_is(e: &windows::core::Error, code: windows::core::HRESULT) -> bool {
    e.code() == code
}

/// Enumerate sync H.264 MFTs of `category` (best first). Async MFTs
/// (hardware encoders, which need the event model) are skipped.
fn enum_mfts(category: GUID, input: Option<GUID>, output: Option<GUID>) -> Vec<(IMFActivate, String)> {
    let inp = input.map(|s| MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: s });
    let out = output.map(|s| MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: s });
    let mut arr: *mut Option<IMFActivate> = std::ptr::null_mut();
    let mut n = 0u32;
    let flags = MFT_ENUM_FLAG(MFT_ENUM_FLAG_SYNCMFT.0 | MFT_ENUM_FLAG_LOCALMFT.0 | MFT_ENUM_FLAG_SORTANDFILTER.0);
    // SAFETY: out-pointers to locals; the array is CoTaskMem-allocated and
    // every element is an owned reference we take below.
    let r = unsafe {
        MFTEnumEx(category, flags, inp.as_ref().map(|p| p as *const _), out.as_ref().map(|p| p as *const _), &mut arr, &mut n)
    };
    let mut res = Vec::new();
    if r.is_err() || arr.is_null() {
        return res;
    }
    for i in 0..n as usize {
        // SAFETY: `i < n`; take ownership of each element exactly once.
        let Some(act) = (unsafe { std::ptr::read(arr.add(i)) }) else { continue };
        // SAFETY: attribute read on a live IMFActivate.
        if unsafe { act.GetUINT32(&MF_TRANSFORM_ASYNC) }.unwrap_or(0) != 0 {
            continue;
        }
        let name = friendly_name(&act);
        res.push((act, name));
    }
    // SAFETY: allocated by MFTEnumEx with CoTaskMemAlloc; elements were moved out.
    unsafe { CoTaskMemFree(Some(arr as *const _)) };
    res
}

/// An activated MFT's `IMFActivate`, shut down (`ShutdownObject`) when dropped:
/// when its setup fails, and when the codec that owns it is dropped. `None`
/// for an MFT created directly with `CoCreateInstance`.
struct Activation(Option<IMFActivate>);

impl Drop for Activation {
    fn drop(&mut self) {
        if let Some(a) = self.0.take() {
            // SAFETY: releases the object this activation created; harmless if
            // it is already gone.
            let _ = unsafe { a.ShutdownObject() };
        }
    }
}

/// Try each enumerated MFT, then the Microsoft one by CLSID; first `setup` that works wins.
/// `setup` owns the [`Activation`]: on failure it is dropped (MFT shut down), on
/// success the codec keeps it until it is dropped itself.
fn first_working<T>(
    cands: Vec<(IMFActivate, String)>,
    ms: (&GUID, &str),
    mut setup: impl FnMut(IMFTransform, &str, Activation) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let mut errs = Vec::new();
    let mut tried_ms = false;
    for (act, name) in cands {
        tried_ms |= name.starts_with("Microsoft");
        // SAFETY: activation of an enumerated MFT.
        match unsafe { act.ActivateObject::<IMFTransform>() } {
            Ok(t) => match setup(t, &name, Activation(Some(act))) {
                Ok(x) => return Ok(x),
                Err(e) => errs.push(format!("{name}: {e:#}")),
            },
            Err(e) => {
                // a half-activated object is released too
                drop(Activation(Some(act)));
                errs.push(format!("{name}: {e}"));
            }
        }
    }
    if !tried_ms {
        if let Ok(t) = create_ms(ms.0) {
            match setup(t, ms.1, Activation(None)) {
                Ok(x) => return Ok(x),
                Err(e) => errs.push(format!("{}: {e:#}", ms.1)),
            }
        }
    }
    if errs.is_empty() {
        anyhow::bail!("no Media Foundation H.264 MFT (Windows N without the Media Feature Pack?)");
    }
    anyhow::bail!("{}", errs.join("; "))
}

fn friendly_name(act: &IMFActivate) -> String {
    let mut buf = [0u16; 256];
    let mut len = 0u32;
    // SAFETY: buffer and length are locals of the declared size.
    if unsafe { act.GetString(&MFT_FRIENDLY_NAME_Attribute, &mut buf, Some(&mut len)) }.is_ok() {
        return String::from_utf16_lossy(&buf[..(len as usize).min(buf.len())]);
    }
    "H.264 MFT".into()
}

fn create_ms(clsid: &GUID) -> windows::core::Result<IMFTransform> {
    // SAFETY: standard in-process COM activation.
    unsafe { CoCreateInstance(clsid, None, CLSCTX_INPROC_SERVER) }
}

fn codec_api(t: &IMFTransform) -> Option<ICodecAPI> {
    t.cast::<ICodecAPI>().ok()
}

fn set_codec(api: Option<&ICodecAPI>, key: &GUID, v: VARIANT) -> bool {
    match api {
        // SAFETY: valid GUID and VARIANT pointers for the duration of the call.
        Some(a) => unsafe { a.SetValue(key, &v) }.is_ok(),
        None => false,
    }
}

fn pack(hi: u32, lo: u32) -> u64 {
    ((hi as u64) << 32) | lo as u64
}

fn video_type(subtype: &GUID, w: u32, h: u32, fps: u32) -> windows::core::Result<IMFMediaType> {
    // SAFETY: COM calls on a freshly created media type.
    unsafe {
        let t = MFCreateMediaType()?;
        t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        t.SetGUID(&MF_MT_SUBTYPE, subtype)?;
        if w > 0 && h > 0 {
            t.SetUINT64(&MF_MT_FRAME_SIZE, pack(w, h))?;
        }
        if fps > 0 {
            t.SetUINT64(&MF_MT_FRAME_RATE, pack(fps, 1))?;
        }
        t.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
        t.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, pack(1, 1))?;
        Ok(t)
    }
}

fn sample_from(data: &[u8], ts_100ns: i64, dur_100ns: i64) -> anyhow::Result<IMFSample> {
    // SAFETY: the buffer is locked for exactly `data.len()` bytes and unlocked.
    unsafe {
        let buf = MFCreateMemoryBuffer(data.len().max(1) as u32)?;
        let mut p: *mut u8 = std::ptr::null_mut();
        buf.Lock(&mut p, None, None)?;
        std::ptr::copy_nonoverlapping(data.as_ptr(), p, data.len());
        buf.Unlock()?;
        buf.SetCurrentLength(data.len() as u32)?;
        let s = MFCreateSample()?;
        s.AddBuffer(&buf)?;
        s.SetSampleTime(ts_100ns)?;
        if dur_100ns > 0 {
            s.SetSampleDuration(dur_100ns)?;
        }
        Ok(s)
    }
}

/// Copy the whole (contiguous) payload of a sample into `out`.
fn sample_bytes(s: &IMFSample, out: &mut Vec<u8>) -> anyhow::Result<()> {
    // SAFETY: the buffer is locked while we copy `len` bytes from it.
    unsafe {
        let buf = s.ConvertToContiguousBuffer()?;
        let mut p: *mut u8 = std::ptr::null_mut();
        let mut len = 0u32;
        buf.Lock(&mut p, None, Some(&mut len))?;
        out.clear();
        if !p.is_null() {
            out.extend_from_slice(std::slice::from_raw_parts(p, len as usize));
        }
        buf.Unlock()?;
    }
    Ok(())
}

enum Out {
    Sample(IMFSample),
    NeedInput,
    StreamChange,
}

/// One `ProcessOutput` call; allocates the output sample if the MFT does not.
fn process_output(t: &IMFTransform, fallback_size: u32) -> anyhow::Result<Out> {
    // SAFETY: COM calls on a configured transform; ownership of the returned
    // sample/events is taken out of the ManuallyDrop fields exactly once.
    unsafe {
        let info = t.GetOutputStreamInfo(0)?;
        let provides = info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES.0) as u32 != 0;
        let mine = if provides {
            None
        } else {
            let size = info.cbSize.max(fallback_size).max(4096);
            let buf = if info.cbAlignment > 1 { MFCreateAlignedMemoryBuffer(size, info.cbAlignment - 1)? } else { MFCreateMemoryBuffer(size)? };
            let s = MFCreateSample()?;
            s.AddBuffer(&buf)?;
            Some(s)
        };
        let mut db = [MFT_OUTPUT_DATA_BUFFER { dwStreamID: 0, pSample: ManuallyDrop::new(mine), dwStatus: 0, pEvents: ManuallyDrop::new(None) }];
        let mut status = 0u32;
        let r = t.ProcessOutput(0, &mut db, &mut status);
        let sample = ManuallyDrop::take(&mut db[0].pSample);
        drop(ManuallyDrop::take(&mut db[0].pEvents));
        match r {
            Ok(()) => sample.map(Out::Sample).ok_or_else(|| anyhow::anyhow!("MFT returned no sample")),
            Err(e) if hr_is(&e, MF_E_TRANSFORM_NEED_MORE_INPUT) => Ok(Out::NeedInput),
            Err(e) if hr_is(&e, MF_E_TRANSFORM_STREAM_CHANGE) => Ok(Out::StreamChange),
            Err(e) => Err(anyhow::anyhow!("ProcessOutput failed: {e}")),
        }
    }
}

fn begin_streaming(t: &IMFTransform) {
    // SAFETY: notifications on a configured transform; failures are harmless.
    unsafe {
        let _ = t.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
        let _ = t.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    }
}

fn end_streaming(t: &IMFTransform) {
    // SAFETY: as above.
    unsafe {
        let _ = t.ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
        let _ = t.ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    }
}

// ------------------------------------------------------------------ encoder

/// Synchronous (software) encoder MFT — Microsoft's, or a vendor's sync one.
pub(crate) struct SwEncoder {
    t: IMFTransform,
    api: Option<ICodecAPI>,
    w: usize,
    h: usize,
    nv12: bool,
    fps: u32,
    /// Annex-B SPS+PPS from the output type (prepended to bare keyframes)
    seq_header: Vec<u8>,
    pending: VecDeque<(Vec<u8>, bool)>,
    frame: Vec<u8>,
    out: Vec<u8>,
    name: String,
    /// last: shuts the MFT down after `t` is released
    _act: Activation,
}

// SAFETY: the MFT and ICodecAPI are free-threaded COM objects created in the
// MTA (every thread that touches them joins the MTA via `startup`); all calls
// go through `&mut self`, so they are never concurrent.
unsafe impl Send for SwEncoder {}

impl SwEncoder {
    fn open(p: &EncParams) -> anyhow::Result<Self> {
        let cands = enum_mfts(MFT_CATEGORY_VIDEO_ENCODER, None, Some(MFVideoFormat_H264));
        first_working(cands, (&CMSH264EncoderMFT, "Microsoft H264 Encoder MFT"), |t, name, act| Self::configure(t, p, name, act))
            .map_err(|e| anyhow::anyhow!("Media Foundation H.264 encoder: {e:#}"))
    }

    fn configure(t: IMFTransform, p: &EncParams, name: &str, act: Activation) -> anyhow::Result<Self> {
        let (w, h) = (p.w as u32, p.h as u32);
        let fps = p.fps.clamp(1, 240);
        let bps = p.bitrate_kbps.saturating_mul(1000);
        let api = codec_api(&t);
        // Rate control etc. must be set before the media types on the MS encoder.
        set_codec(api.as_ref(), &CODECAPI_AVEncCommonRateControlMode, VARIANT::from(eAVEncCommonRateControlMode_CBR.0 as u32));
        set_codec(api.as_ref(), &CODECAPI_AVEncCommonMeanBitRate, VARIANT::from(bps));
        set_codec(api.as_ref(), &CODECAPI_AVLowLatencyMode, VARIANT::from(true));
        set_codec(api.as_ref(), &CODECAPI_AVEncMPVDefaultBPictureCount, VARIANT::from(0u32));
        let gop = fps.saturating_mul(p.keyframe_interval_s);
        // 0 = "encoder default"; use a very long GOP for "on demand only"
        set_codec(api.as_ref(), &CODECAPI_AVEncMPVGOPSize, VARIANT::from(if gop == 0 { 0xFFFF } else { gop }));
        // SAFETY: COM calls on the transform being configured.
        unsafe {
            let ot = video_type(&MFVideoFormat_H264, w, h, fps)?;
            ot.SetUINT32(&MF_MT_AVG_BITRATE, bps)?;
            // constrained baseline where supported, else baseline (both decodable everywhere)
            ot.SetUINT32(&MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_ConstrainedBase.0 as u32)?;
            if t.SetOutputType(0, &ot, 0).is_err() {
                ot.SetUINT32(&MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Base.0 as u32)?;
                t.SetOutputType(0, &ot, 0).map_err(|e| anyhow::anyhow!("output type rejected: {e}"))?;
            }
            let mut nv12 = None;
            for (sub, is_nv12) in [(MFVideoFormat_IYUV, false), (MFVideoFormat_I420, false), (MFVideoFormat_NV12, true)] {
                let it = video_type(&sub, w, h, fps)?;
                if t.SetInputType(0, &it, 0).is_ok() {
                    nv12 = Some(is_nv12);
                    break;
                }
            }
            let nv12 = nv12.ok_or_else(|| anyhow::anyhow!("no I420/NV12 input type accepted"))?;
            // some settings only stick after the types are set
            set_codec(api.as_ref(), &CODECAPI_AVLowLatencyMode, VARIANT::from(true));
            set_codec(api.as_ref(), &CODECAPI_AVEncMPVDefaultBPictureCount, VARIANT::from(0u32));
            let mut seq_header = Vec::new();
            if let Ok(cur) = t.GetOutputCurrentType(0) {
                if let Ok(n) = cur.GetBlobSize(&MF_MT_MPEG_SEQUENCE_HEADER) {
                    let mut b = vec![0u8; n as usize];
                    if cur.GetBlob(&MF_MT_MPEG_SEQUENCE_HEADER, &mut b, None).is_ok() {
                        seq_header = to_annexb(b);
                    }
                }
            }
            begin_streaming(&t);
            Ok(Self {
                t,
                api,
                w: p.w,
                h: p.h,
                nv12,
                fps,
                seq_header,
                pending: VecDeque::new(),
                frame: Vec::new(),
                out: Vec::new(),
                name: name.to_string(),
                _act: act,
            })
        }
    }

    fn fill_frame(&mut self, pic: &I420Buf) {
        let (w, h) = (self.w, self.h);
        let (cw, ch) = (w / 2, h / 2);
        self.frame.clear();
        self.frame.reserve(w * h * 3 / 2);
        self.frame.extend_from_slice(&pic.y[..w * h]);
        if self.nv12 {
            for r in 0..ch {
                let (u, v) = (&pic.u[r * cw..(r + 1) * cw], &pic.v[r * cw..(r + 1) * cw]);
                for c in 0..cw {
                    self.frame.push(u[c]);
                    self.frame.push(v[c]);
                }
            }
        } else {
            self.frame.extend_from_slice(&pic.u[..cw * ch]);
            self.frame.extend_from_slice(&pic.v[..cw * ch]);
        }
    }

    fn drain(&mut self) -> anyhow::Result<()> {
        loop {
            match process_output(&self.t, (self.w * self.h) as u32)? {
                Out::NeedInput => return Ok(()),
                Out::StreamChange => {
                    // SAFETY: re-select the first available output type.
                    unsafe {
                        let ot = self.t.GetOutputAvailableType(0, 0)?;
                        self.t.SetOutputType(0, &ot, 0)?;
                    }
                }
                Out::Sample(s) => {
                    sample_bytes(&s, &mut self.out)?;
                    if self.out.is_empty() {
                        continue;
                    }
                    let data = to_annexb(std::mem::take(&mut self.out));
                    // SAFETY: attribute read on a live sample.
                    let clean = unsafe { s.GetUINT32(&MFSampleExtension_CleanPoint) }.unwrap_or(0) != 0;
                    let key = has_idr(&data) || (clean && !nals(&data).any(|n| matches!(nal_type(n), 1)));
                    let data = if key { self.with_headers(data) } else { data };
                    self.pending.push_back((data, key));
                }
            }
        }
    }

    fn with_headers(&mut self, data: Vec<u8>) -> Vec<u8> {
        with_headers(&mut self.seq_header, data)
    }
}

/// Keyframes must carry SPS/PPS: remember in-band ones (in `seq_header`),
/// prepend the last known ones (or the output type's sequence header) otherwise.
fn with_headers(seq_header: &mut Vec<u8>, data: Vec<u8>) -> Vec<u8> {
    {
        let inband: Vec<u8> = nals(&data).filter(|n| matches!(nal_type(n), 7 | 8)).flat_map(|n| [&[0u8, 0, 0, 1][..], n].concat()).collect();
        if nals(&inband).any(|n| nal_type(n) == NAL_SPS) {
            *seq_header = inband;
            return data;
        }
        if seq_header.is_empty() {
            return data;
        }
        let mut out = Vec::with_capacity(seq_header.len() + data.len());
        out.extend_from_slice(seq_header);
        out.extend_from_slice(&data);
        out
    }
}

/// Annex-B as is; AVCC (4-byte lengths) converted.
fn to_annexb(b: Vec<u8>) -> Vec<u8> {
    if b.starts_with(&[0, 0, 1]) || b.starts_with(&[0, 0, 0, 1]) {
        return b;
    }
    let mut out = Vec::with_capacity(b.len() + 16);
    match annexb::avcc_to_annexb(&b, 4, &mut out) {
        Ok(()) => out,
        Err(_) => b,
    }
}

impl EncBackend for SwEncoder {
    fn encode(&mut self, pic: &mut I420Buf, ts_us: u64, force_keyframe: bool) -> anyhow::Result<Option<(Vec<u8>, bool)>> {
        startup()?;
        if pic.width != self.w || pic.height != self.h {
            anyhow::bail!("picture is {}x{}, encoder was opened for {}x{}", pic.width, pic.height, self.w, self.h);
        }
        if force_keyframe {
            set_codec(self.api.as_ref(), &CODECAPI_AVEncVideoForceKeyFrame, VARIANT::from(1u32));
        }
        self.fill_frame(pic);
        let sample = sample_from(&self.frame, (ts_us * 10) as i64, 10_000_000 / self.fps as i64)?;
        // SAFETY: COM call on a configured transform.
        match unsafe { self.t.ProcessInput(0, &sample, 0) } {
            Ok(()) => {}
            Err(e) if hr_is(&e, MF_E_NOTACCEPTING) => {
                self.drain()?;
                // SAFETY: as above.
                unsafe { self.t.ProcessInput(0, &sample, 0) }.map_err(|e| anyhow::anyhow!("{}: ProcessInput failed: {e}", self.name))?;
            }
            Err(e) => anyhow::bail!("{}: ProcessInput failed: {e}", self.name),
        }
        self.drain()?;
        Ok(self.pending.pop_front())
    }

    fn set_bitrate(&mut self, kbps: u32) {
        if !set_codec(self.api.as_ref(), &CODECAPI_AVEncCommonMeanBitRate, VARIANT::from(kbps.saturating_mul(1000))) {
            tracing::debug!("{}: bitrate change to {kbps} kbps rejected", self.name);
        }
    }

    fn hardware(&self) -> bool {
        false
    }
}

impl Drop for SwEncoder {
    fn drop(&mut self) {
        end_streaming(&self.t);
    }
}

// ------------------------------------------------------------------ hardware (async) encoder

/// Hardware H.264 encoder MFTs (Intel Quick Sync, NVIDIA NVENC, AMD AMF),
/// best first. These are asynchronous MFTs (event model).
fn enum_hw_encoders() -> Vec<(IMFActivate, String)> {
    let inp = MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: MFVideoFormat_NV12 };
    let out = MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: MFVideoFormat_H264 };
    let mut arr: *mut Option<IMFActivate> = std::ptr::null_mut();
    let mut n = 0u32;
    let flags = MFT_ENUM_FLAG(MFT_ENUM_FLAG_HARDWARE.0 | MFT_ENUM_FLAG_ASYNCMFT.0 | MFT_ENUM_FLAG_SORTANDFILTER.0);
    // SAFETY: as in `enum_mfts`.
    let r = unsafe { MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, flags, Some(&inp), Some(&out), &mut arr, &mut n) };
    let mut res = Vec::new();
    if r.is_err() || arr.is_null() {
        return res;
    }
    for i in 0..n as usize {
        // SAFETY: `i < n`; each element is taken exactly once.
        if let Some(act) = unsafe { std::ptr::read(arr.add(i)) } {
            let name = friendly_name(&act);
            res.push((act, name));
        }
    }
    // SAFETY: CoTaskMem array from MFTEnumEx; elements moved out above.
    unsafe { CoTaskMemFree(Some(arr as *const _)) };
    res
}

/// D3D11 device on the encoder's adapter + DXGI device manager, for MFTs that
/// want GPU textures as input.
struct D3d {
    device: ID3D11Device,
    ctx: ID3D11DeviceContext,
    manager: IMFDXGIDeviceManager,
    /// staging (CPU write) texture + a small ring of GPU textures the encoder reads
    staging: ID3D11Texture2D,
    ring: Vec<ID3D11Texture2D>,
    next: usize,
}

impl D3d {
    /// Device on the adapter with `luid` (the MFT's GPU), else the default one.
    fn new(luid: Option<u64>, w: u32, h: u32) -> anyhow::Result<Self> {
        // SAFETY: plain D3D11/DXGI object creation; out-pointers are locals.
        unsafe {
            let mut adapter: Option<IDXGIAdapter1> = None;
            if let Some(luid) = luid {
                if let Ok(f) = CreateDXGIFactory1::<IDXGIFactory1>() {
                    let mut i = 0;
                    while let Ok(a) = f.EnumAdapters1(i) {
                        if let Ok(d) = a.GetDesc1() {
                            let l = ((d.AdapterLuid.HighPart as u32 as u64) << 32) | d.AdapterLuid.LowPart as u64;
                            if l == luid {
                                adapter = Some(a);
                                break;
                            }
                        }
                        i += 1;
                    }
                }
            }
            let mut device: Option<ID3D11Device> = None;
            let mut ctx: Option<ID3D11DeviceContext> = None;
            let driver = if adapter.is_some() { D3D_DRIVER_TYPE_UNKNOWN } else { D3D_DRIVER_TYPE_HARDWARE };
            let adapter: Option<IDXGIAdapter> = adapter.and_then(|a| a.cast().ok());
            D3D11CreateDevice(
                adapter.as_ref(),
                driver,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                None,
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut ctx),
            )?;
            let device = device.ok_or_else(|| anyhow::anyhow!("no D3D11 device"))?;
            let ctx = ctx.ok_or_else(|| anyhow::anyhow!("no D3D11 context"))?;
            // the MFT uses the device from its own threads
            if let Ok(mt) = ctx.cast::<ID3D11Multithread>() {
                let _ = mt.SetMultithreadProtected(true);
            }
            let mut token = 0u32;
            let mut mgr: Option<IMFDXGIDeviceManager> = None;
            MFCreateDXGIDeviceManager(&mut token, &mut mgr)?;
            let manager = mgr.ok_or_else(|| anyhow::anyhow!("no DXGI device manager"))?;
            manager.ResetDevice(&device, token)?;
            let tex = |usage, bind: u32, cpu: u32| -> anyhow::Result<ID3D11Texture2D> {
                let desc = D3D11_TEXTURE2D_DESC {
                    Width: w,
                    Height: h,
                    MipLevels: 1,
                    ArraySize: 1,
                    Format: DXGI_FORMAT_NV12,
                    SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                    Usage: usage,
                    BindFlags: bind,
                    CPUAccessFlags: cpu,
                    MiscFlags: 0,
                };
                let mut t: Option<ID3D11Texture2D> = None;
                device.CreateTexture2D(&desc, None, Some(&mut t))?;
                t.ok_or_else(|| anyhow::anyhow!("CreateTexture2D returned nothing"))
            };
            let staging = tex(D3D11_USAGE_STAGING, 0, D3D11_CPU_ACCESS_WRITE.0 as u32)?;
            let mut ring = Vec::new();
            for _ in 0..4 {
                ring.push(tex(D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET.0 as u32, 0)?);
            }
            Ok(Self { device, ctx, manager, staging, ring, next: 0 })
        }
    }

    /// Upload an NV12 frame (`w`x`h`, tightly packed) into the next ring texture
    /// and wrap it in a sample.
    fn sample(&mut self, nv12: &[u8], w: usize, h: usize) -> anyhow::Result<IMFSample> {
        // SAFETY: the staging texture is mapped for writing `pitch * (h + h/2)`
        // bytes (NV12: the UV plane follows the Y plane at `pitch * h`), unmapped,
        // then copied on the GPU.
        unsafe {
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            self.ctx.Map(&self.staging, 0, D3D11_MAP_WRITE, 0, Some(&mut m))?;
            let pitch = m.RowPitch as usize;
            let dst = m.pData as *mut u8;
            for r in 0..h {
                std::ptr::copy_nonoverlapping(nv12.as_ptr().add(r * w), dst.add(r * pitch), w);
            }
            for r in 0..h / 2 {
                std::ptr::copy_nonoverlapping(nv12.as_ptr().add(w * h + r * w), dst.add(pitch * h + r * pitch), w);
            }
            self.ctx.Unmap(&self.staging, 0);
            let tex = self.ring[self.next].clone();
            self.next = (self.next + 1) % self.ring.len();
            self.ctx.CopyResource(&tex, &self.staging);
            let buf = MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, &tex, 0, false)?;
            if let Ok(b2) = buf.cast::<IMF2DBuffer>() {
                if let Ok(len) = b2.GetContiguousLength() {
                    let _ = buf.SetCurrentLength(len);
                }
            }
            let s = MFCreateSample()?;
            s.AddBuffer(&buf)?;
            let _ = &self.device;
            Ok(s)
        }
    }
}

/// Asynchronous hardware encoder MFT.
pub(crate) struct HwEncoder {
    act: IMFActivate,
    t: IMFTransform,
    events: IMFMediaEventGenerator,
    api: Option<ICodecAPI>,
    d3d: Option<D3d>,
    w: usize,
    h: usize,
    fps: u32,
    seq_header: Vec<u8>,
    pending: VecDeque<(Vec<u8>, bool)>,
    /// METransformNeedInput events not yet answered with ProcessInput
    credits: u32,
    /// a keyframe asked for while the encoder could not take the frame
    force_pending: bool,
    frame: Vec<u8>,
    out: Vec<u8>,
    name: String,
}

// SAFETY: hardware MFTs are free-threaded and raise their events on their own
// worker threads; we only call into them through `&mut self` from a thread in
// the MTA (`startup`), never concurrently. The D3D11 device is multithread
// protected and its immediate context is only used under `&mut self`.
unsafe impl Send for HwEncoder {}

/// How long `encode` waits for the encoder to accept input / produce output.
const HW_INPUT_WAIT_MS: u64 = 40;
/// Encoded frames kept waiting for `encode` to return them; beyond that the
/// non-key ones are dropped (and a keyframe requested).
const HW_MAX_BACKLOG: usize = 8;

impl HwEncoder {
    fn open(p: &EncParams) -> anyhow::Result<Self> {
        let cands = enum_hw_encoders();
        if cands.is_empty() {
            anyhow::bail!("no hardware H.264 encoder MFT");
        }
        let mut errs = Vec::new();
        for (act, name) in cands {
            match Self::try_one(&act, p, &name) {
                Ok(e) => return Ok(e),
                Err(e) => {
                    // SAFETY: release the activated object so the next one can start.
                    let _ = unsafe { act.ShutdownObject() };
                    errs.push(format!("{name}: {e:#}"));
                }
            }
        }
        anyhow::bail!("{}", errs.join("; "))
    }

    fn try_one(act: &IMFActivate, p: &EncParams, name: &str) -> anyhow::Result<Self> {
        let (w, h) = (p.w as u32, p.h as u32);
        let fps = p.fps.clamp(1, 240);
        let bps = p.bitrate_kbps.saturating_mul(1000);
        // SAFETY: COM calls on the MFT being configured; every object is owned.
        unsafe {
            let luid = act.GetUINT64(&MFT_ENUM_ADAPTER_LUID).ok();
            let t: IMFTransform = act.ActivateObject()?;
            let attrs = t.GetAttributes()?;
            if attrs.GetUINT32(&MF_TRANSFORM_ASYNC).unwrap_or(0) == 0 {
                anyhow::bail!("not an asynchronous MFT");
            }
            attrs.SetUINT32(&MF_TRANSFORM_ASYNC_UNLOCK, 1)?;
            let _ = attrs.SetUINT32(&MF_LOW_LATENCY, 1);
            // GPU textures when the MFT is D3D11-aware (NVIDIA needs it, others like it)
            let mut d3d = None;
            if attrs.GetUINT32(&MF_SA_D3D11_AWARE).unwrap_or(0) != 0 {
                match D3d::new(luid, w, h) {
                    Ok(d) => {
                        if t.ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, d.manager.as_raw() as usize).is_ok() {
                            d3d = Some(d);
                        }
                    }
                    Err(e) => tracing::debug!("{name}: no D3D11 device ({e:#}), using system memory"),
                }
            }
            let api = codec_api(&t);
            set_codec(api.as_ref(), &CODECAPI_AVEncCommonRateControlMode, VARIANT::from(eAVEncCommonRateControlMode_CBR.0 as u32));
            set_codec(api.as_ref(), &CODECAPI_AVEncCommonMeanBitRate, VARIANT::from(bps));
            set_codec(api.as_ref(), &CODECAPI_AVLowLatencyMode, VARIANT::from(true));
            set_codec(api.as_ref(), &CODECAPI_AVEncMPVDefaultBPictureCount, VARIANT::from(0u32));
            let gop = fps.saturating_mul(p.keyframe_interval_s);
            set_codec(api.as_ref(), &CODECAPI_AVEncMPVGOPSize, VARIANT::from(if gop == 0 { 0xFFFF } else { gop }));
            // output type first (encoders), then NV12 input
            let ot = video_type(&MFVideoFormat_H264, w, h, fps)?;
            ot.SetUINT32(&MF_MT_AVG_BITRATE, bps)?;
            let mut ok = false;
            for prof in [eAVEncH264VProfile_ConstrainedBase, eAVEncH264VProfile_Base, eAVEncH264VProfile_Main] {
                ot.SetUINT32(&MF_MT_MPEG2_PROFILE, prof.0 as u32)?;
                if t.SetOutputType(0, &ot, 0).is_ok() {
                    ok = true;
                    break;
                }
            }
            anyhow::ensure!(ok, "no H.264 output type accepted");
            let it = video_type(&MFVideoFormat_NV12, w, h, fps)?;
            t.SetInputType(0, &it, 0).map_err(|e| anyhow::anyhow!("NV12 input rejected: {e}"))?;
            // some vendors only honour these after the types are set
            set_codec(api.as_ref(), &CODECAPI_AVLowLatencyMode, VARIANT::from(true));
            set_codec(api.as_ref(), &CODECAPI_AVEncMPVDefaultBPictureCount, VARIANT::from(0u32));
            let mut seq_header = Vec::new();
            if let Ok(cur) = t.GetOutputCurrentType(0) {
                if let Ok(n) = cur.GetBlobSize(&MF_MT_MPEG_SEQUENCE_HEADER) {
                    let mut b = vec![0u8; n as usize];
                    if cur.GetBlob(&MF_MT_MPEG_SEQUENCE_HEADER, &mut b, None).is_ok() {
                        seq_header = to_annexb(b);
                    }
                }
            }
            let events: IMFMediaEventGenerator = t.cast()?;
            begin_streaming(&t);
            Ok(Self {
                act: act.clone(),
                t,
                events,
                api,
                d3d,
                w: p.w,
                h: p.h,
                fps,
                seq_header,
                pending: VecDeque::new(),
                credits: 0,
                force_pending: false,
                frame: Vec::new(),
                out: Vec::new(),
                name: name.to_string(),
            })
        }
    }

    /// Handle every queued event without blocking. Returns whether any arrived.
    fn pump(&mut self) -> anyhow::Result<bool> {
        let mut any = false;
        loop {
            // SAFETY: non-blocking event query on the MFT's event queue.
            let ev = match unsafe { self.events.GetEvent(MF_EVENT_FLAG_NO_WAIT) } {
                Ok(ev) => ev,
                Err(e) if hr_is(&e, MF_E_NO_EVENTS_AVAILABLE) => return Ok(any),
                Err(e) => anyhow::bail!("{}: GetEvent failed: {e}", self.name),
            };
            any = true;
            // SAFETY: reading the type/status of a received event.
            let (kind, status) = unsafe { (ev.GetType().unwrap_or(0), ev.GetStatus().unwrap_or_default()) };
            if status.is_err() {
                anyhow::bail!("{}: encoder error {status:?}", self.name);
            }
            let kind = MF_EVENT_TYPE(kind as i32);
            if kind == METransformNeedInput {
                self.credits += 1;
            } else if kind == METransformHaveOutput {
                self.take_output()?;
            }
        }
    }

    fn take_output(&mut self) -> anyhow::Result<()> {
        match process_output(&self.t, (self.w * self.h) as u32)? {
            Out::NeedInput => {}
            Out::StreamChange => {
                // SAFETY: re-select the encoder's preferred output type.
                unsafe {
                    let ot = self.t.GetOutputAvailableType(0, 0)?;
                    self.t.SetOutputType(0, &ot, 0)?;
                    if let Ok(n) = ot.GetBlobSize(&MF_MT_MPEG_SEQUENCE_HEADER) {
                        let mut b = vec![0u8; n as usize];
                        if ot.GetBlob(&MF_MT_MPEG_SEQUENCE_HEADER, &mut b, None).is_ok() {
                            self.seq_header = to_annexb(b);
                        }
                    }
                }
            }
            Out::Sample(s) => {
                sample_bytes(&s, &mut self.out)?;
                if !self.out.is_empty() {
                    let data = to_annexb(std::mem::take(&mut self.out));
                    // SAFETY: attribute read on a live sample.
                    let clean = unsafe { s.GetUINT32(&MFSampleExtension_CleanPoint) }.unwrap_or(0) != 0;
                    let key = has_idr(&data) || (clean && !nals(&data).any(|n| nal_type(n) == 1));
                    let data = if key { with_headers(&mut self.seq_header, data) } else { data };
                    if self.pending.len() >= HW_MAX_BACKLOG {
                        // far behind: drop the backlog's non-key frames (keyframes
                        // stay: the receiver resyncs on them) and ask for a new
                        // keyframe, as frames after a dropped one no longer decode
                        self.pending.retain(|(_, k)| *k);
                        while self.pending.len() >= HW_MAX_BACKLOG {
                            self.pending.pop_front();
                        }
                        self.force_pending = true;
                    }
                    self.pending.push_back((data, key));
                }
            }
        }
        Ok(())
    }

    /// Pump events until `done` or `ms` elapse.
    fn wait(&mut self, ms: u64, done: impl Fn(&Self) -> bool) -> anyhow::Result<()> {
        let until = std::time::Instant::now() + std::time::Duration::from_millis(ms);
        loop {
            self.pump()?;
            if done(self) || std::time::Instant::now() >= until {
                return Ok(());
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
    }

    fn fill_nv12(&mut self, pic: &I420Buf) {
        let (w, h) = (self.w, self.h);
        let cw = w / 2;
        self.frame.clear();
        self.frame.reserve(w * h * 3 / 2);
        self.frame.extend_from_slice(&pic.y[..w * h]);
        for r in 0..h / 2 {
            let (u, v) = (&pic.u[r * cw..(r + 1) * cw], &pic.v[r * cw..(r + 1) * cw]);
            for c in 0..cw {
                self.frame.push(u[c]);
                self.frame.push(v[c]);
            }
        }
    }
}

impl EncBackend for HwEncoder {
    fn encode(&mut self, pic: &mut I420Buf, ts_us: u64, force_keyframe: bool) -> anyhow::Result<Option<(Vec<u8>, bool)>> {
        startup()?;
        if pic.width != self.w || pic.height != self.h {
            anyhow::bail!("picture is {}x{}, encoder was opened for {}x{}", pic.width, pic.height, self.w, self.h);
        }
        self.wait(HW_INPUT_WAIT_MS, |s| s.credits > 0)?;
        // after the wait: a backlog flush during it may have asked for a keyframe
        let force = force_keyframe || self.force_pending;
        if self.credits == 0 {
            // the GPU is busy: skip this frame rather than build latency
            self.force_pending = force;
            return Ok(self.pending.pop_front());
        }
        self.force_pending = false;
        if force {
            set_codec(self.api.as_ref(), &CODECAPI_AVEncVideoForceKeyFrame, VARIANT::from(1u32));
        }
        self.fill_nv12(pic);
        let sample = match self.d3d.as_mut() {
            Some(d) => d.sample(&self.frame, self.w, self.h)?,
            None => sample_from(&self.frame, 0, 0)?,
        };
        // SAFETY: COM calls on a live sample / configured transform.
        unsafe {
            sample.SetSampleTime((ts_us * 10) as i64)?;
            sample.SetSampleDuration(10_000_000 / self.fps as i64)?;
            self.t.ProcessInput(0, &sample, 0).map_err(|e| anyhow::anyhow!("{}: ProcessInput failed: {e}", self.name))?;
        }
        self.credits -= 1;
        // this frame's access unit usually follows within a few ms
        let want = self.pending.len() + 1;
        self.wait(1000 / self.fps.max(1) as u64 + 5, |s| s.pending.len() >= want)?;
        Ok(self.pending.pop_front())
    }

    fn set_bitrate(&mut self, kbps: u32) {
        if !set_codec(self.api.as_ref(), &CODECAPI_AVEncCommonMeanBitRate, VARIANT::from(kbps.saturating_mul(1000))) {
            tracing::debug!("{}: bitrate change to {kbps} kbps rejected", self.name);
        }
    }

    fn hardware(&self) -> bool {
        true
    }
}

impl Drop for HwEncoder {
    fn drop(&mut self) {
        end_streaming(&self.t);
        // SAFETY: shut the hardware MFT down (frees its GPU session), then the activation.
        unsafe {
            if let Ok(s) = self.t.cast::<IMFShutdown>() {
                let _ = s.Shutdown();
            }
            let _ = self.act.ShutdownObject();
        }
    }
}

/// H.264 encoder: a hardware MFT when the machine has one, else the
/// synchronous (software) one. `LUMORA_MF_NO_HW=1` forces software.
pub(crate) enum Encoder {
    Hw(HwEncoder),
    Sw(SwEncoder),
}

impl Encoder {
    pub fn new(p: &EncParams) -> anyhow::Result<Self> {
        startup()?;
        if p.w < 16 || p.h < 16 || !p.w.is_multiple_of(2) || !p.h.is_multiple_of(2) || p.w > 4096 || p.h > 2304 {
            anyhow::bail!("Media Foundation H.264 encoder does not support {}x{}", p.w, p.h);
        }
        if std::env::var("LUMORA_MF_NO_HW").map(|v| v != "1").unwrap_or(true) {
            match HwEncoder::open(p) {
                Ok(e) => {
                    tracing::info!("H.264 encoder: {} (hardware)", e.name);
                    return Ok(Encoder::Hw(e));
                }
                Err(e) => tracing::debug!("no hardware H.264 encoder: {e:#}"),
            }
        }
        SwEncoder::open(p).map(Encoder::Sw)
    }

    #[allow(dead_code)]
    pub fn name(&self) -> &str {
        match self {
            Encoder::Hw(e) => &e.name,
            Encoder::Sw(e) => &e.name,
        }
    }
}

impl EncBackend for Encoder {
    fn encode(&mut self, pic: &mut I420Buf, ts_us: u64, force_keyframe: bool) -> anyhow::Result<Option<(Vec<u8>, bool)>> {
        match self {
            Encoder::Hw(e) => e.encode(pic, ts_us, force_keyframe),
            Encoder::Sw(e) => e.encode(pic, ts_us, force_keyframe),
        }
    }

    fn set_bitrate(&mut self, kbps: u32) {
        match self {
            Encoder::Hw(e) => e.set_bitrate(kbps),
            Encoder::Sw(e) => e.set_bitrate(kbps),
        }
    }

    fn hardware(&self) -> bool {
        matches!(self, Encoder::Hw(_))
    }
}

// ------------------------------------------------------------------ decoder

pub(crate) struct Decoder {
    t: IMFTransform,
    name: String,
    out_type_set: bool,
    /// geometry of the current output type: NV12 or I420, allocated frame size
    /// (may be padded, e.g. 1920x1088), stride, display size
    nv12: bool,
    fw: usize,
    fh: usize,
    stride: usize,
    disp: Option<(usize, usize)>,
    sps_dims: Option<(usize, usize)>,
    /// the last picture with the geometry it was copied with (the output type
    /// may change again later in the same `drain`)
    pic: Picture,
    tmp: Vec<u8>,
    have: bool,
    /// last: shuts the MFT down after `t` is released
    _act: Activation,
}

/// A decoded picture (planes at `stride`) and its geometry.
#[derive(Default)]
struct Picture {
    buf: Vec<u8>,
    nv12: bool,
    fw: usize,
    fh: usize,
    stride: usize,
    disp: Option<(usize, usize)>,
}

/// Plane rows of a 4:2:0 picture `fh` lines high (Y + chroma).
fn rows_420(fh: usize) -> usize {
    fh + fh.div_ceil(2)
}

/// Copy `rows` lines at the buffer's own pitch out of a 2-D media buffer into
/// `out`; returns the pitch. `None` when the buffer cannot be read safely
/// (unknown extent, pitch ≤ 0 / below `width`, shorter than `pitch * rows`) —
/// the caller then uses the contiguous 1-D path, which checks its length too.
///
/// # Safety
/// `mb` must be a live media buffer that is not locked by anyone else.
unsafe fn copy_2d(mb: &IMFMediaBuffer, width: usize, rows: usize, out: &mut Vec<u8>) -> Option<usize> {
    let check = |pitch: i32, avail: usize| -> Option<(usize, usize)> {
        let pitch = usize::try_from(pitch).ok().filter(|&p| p > 0 && p >= width)?;
        let need = pitch.checked_mul(rows)?;
        (avail >= need).then_some((pitch, need))
    };
    // IMF2DBuffer2::Lock2DSize (Windows 8+) reports the locked buffer's extent
    if let Ok(b2) = mb.cast::<IMF2DBuffer2>() {
        let (mut p, mut pitch, mut start, mut len) = (std::ptr::null_mut(), 0i32, std::ptr::null_mut(), 0u32);
        if b2.Lock2DSize(MF2DBuffer_LockFlags_Read, &mut p, &mut pitch, &mut start, &mut len).is_ok() {
            let r = (|| {
                if p.is_null() || start.is_null() {
                    return None;
                }
                // bytes from scanline 0 to the end of the buffer
                let avail = (len as usize).checked_sub((p as usize).checked_sub(start as usize)?)?;
                let (pitch, need) = check(pitch, avail)?;
                out.clear();
                out.extend_from_slice(std::slice::from_raw_parts(p, need));
                Some(pitch)
            })();
            let _ = b2.Unlock2D();
            return r;
        }
    }
    // IMF2DBuffer::Lock2D has no length: bound the read by the buffer's current length
    let b2 = mb.cast::<IMF2DBuffer>().ok()?;
    let mut p: *mut u8 = std::ptr::null_mut();
    let mut pitch = 0i32;
    b2.Lock2D(&mut p, &mut pitch).ok()?;
    let r = (|| {
        if p.is_null() {
            return None;
        }
        let cur = mb.GetCurrentLength().ok()? as usize;
        let (pitch, need) = check(pitch, cur)?;
        out.clear();
        out.extend_from_slice(std::slice::from_raw_parts(p, need));
        Some(pitch)
    })();
    let _ = b2.Unlock2D();
    r
}

// SAFETY: see `Encoder`.
unsafe impl Send for Decoder {}

impl Decoder {
    pub fn new() -> anyhow::Result<Self> {
        startup()?;
        let cands = enum_mfts(MFT_CATEGORY_VIDEO_DECODER, Some(MFVideoFormat_H264), None);
        first_working(cands, (&CMSH264DecoderMFT, "Microsoft H264 Video Decoder MFT"), Self::configure)
            .map_err(|e| anyhow::anyhow!("Media Foundation H.264 decoder: {e:#}"))
    }

    fn configure(t: IMFTransform, name: &str, act: Activation) -> anyhow::Result<Self> {
        // SAFETY: COM calls on the transform being configured.
        unsafe {
            if let Ok(a) = t.GetAttributes() {
                let _ = a.SetUINT32(&MF_LOW_LATENCY, 1);
            }
            set_codec(codec_api(&t).as_ref(), &CODECAPI_AVLowLatencyMode, VARIANT::from(true));
            let it = video_type(&MFVideoFormat_H264, 0, 0, 0)?;
            t.SetInputType(0, &it, 0).map_err(|e| anyhow::anyhow!("H.264 input type rejected: {e}"))?;
        }
        let mut d = Self {
            t,
            name: name.to_string(),
            out_type_set: false,
            nv12: true,
            fw: 0,
            fh: 0,
            stride: 0,
            disp: None,
            sps_dims: None,
            pic: Picture::default(),
            tmp: Vec::new(),
            have: false,
            _act: act,
        };
        // Output types are usually only known after the first SPS.
        let _ = d.select_output();
        begin_streaming(&d.t);
        Ok(d)
    }

    /// Pick NV12 (preferred) or I420/IYUV output and read its geometry.
    fn select_output(&mut self) -> anyhow::Result<()> {
        // SAFETY: COM calls on a configured transform.
        unsafe {
            let mut chosen = None;
            for i in 0..64 {
                let Ok(ot) = self.t.GetOutputAvailableType(0, i) else { break };
                let sub = ot.GetGUID(&MF_MT_SUBTYPE).unwrap_or_default();
                let rank = if sub == MFVideoFormat_NV12 {
                    0
                } else if sub == MFVideoFormat_IYUV || sub == MFVideoFormat_I420 {
                    1
                } else {
                    continue;
                };
                if chosen.as_ref().is_none_or(|(r, _, _)| rank < *r) {
                    chosen = Some((rank, ot, sub == MFVideoFormat_NV12));
                }
            }
            let (_, ot, nv12) = chosen.ok_or_else(|| anyhow::anyhow!("decoder offers no NV12/I420 output"))?;
            self.t.SetOutputType(0, &ot, 0).map_err(|e| anyhow::anyhow!("output type rejected: {e}"))?;
            self.nv12 = nv12;
            self.out_type_set = true;
            let cur = self.t.GetOutputCurrentType(0).unwrap_or(ot);
            let fs = cur.GetUINT64(&MF_MT_FRAME_SIZE).unwrap_or(0);
            self.fw = (fs >> 32) as usize;
            self.fh = (fs & 0xffff_ffff) as usize;
            if self.fw != 0 || self.fh != 0 {
                // a size the decoder reports for peer data: same cap as the SPS
                check_decode_dims(self.fw, self.fh).map_err(|e| e.context(format!("{}: output type", self.name)))?;
            }
            let stride = cur.GetUINT32(&MF_MT_DEFAULT_STRIDE).map(|s| (s as i32).unsigned_abs() as usize).unwrap_or(0);
            self.stride = if stride >= self.fw { stride } else { self.fw };
            self.disp = None;
            let mut area = [0u8; std::mem::size_of::<MFVideoArea>()];
            if cur.GetBlob(&MF_MT_MINIMUM_DISPLAY_APERTURE, &mut area, None).is_ok() {
                // SAFETY: the blob is exactly one MFVideoArea.
                let a: MFVideoArea = std::ptr::read_unaligned(area.as_ptr().cast());
                if a.Area.cx > 0 && a.Area.cy > 0 && a.OffsetX.value == 0 && a.OffsetY.value == 0 {
                    self.disp = Some((a.Area.cx as usize, a.Area.cy as usize));
                }
            }
        }
        Ok(())
    }

    /// Copy the decoded picture out of `s` into `self.pic`, together with the
    /// geometry of the current output type.
    fn take_picture(&mut self, s: &IMFSample) -> anyhow::Result<()> {
        let (fw, fh) = (self.fw, self.fh);
        anyhow::ensure!(fw > 0 && fh > 0, "decoder output size unknown");
        check_decode_dims(fw, fh)?;
        let rows = rows_420(fh);
        // SAFETY: a live sample; `copy_2d` checks every read against the buffer's extent.
        let pitch = unsafe {
            let mb = s.ConvertToContiguousBuffer()?;
            copy_2d(&mb, fw, rows, &mut self.pic.buf)
        };
        let stride = match pitch {
            Some(p) => p,
            None => {
                // 1-D buffer: derive the stride from the length if needed
                sample_bytes(s, &mut self.tmp)?;
                let len = self.tmp.len();
                let mut stride = self.stride.max(fw);
                if stride.checked_mul(rows).is_none_or(|n| len < n) && len >= fw * rows {
                    stride = len / rows;
                }
                anyhow::ensure!(stride.checked_mul(rows).is_some_and(|n| len >= n), "{}: decoded buffer too small ({len} bytes for {fw}x{fh})", self.name);
                std::mem::swap(&mut self.pic.buf, &mut self.tmp);
                stride
            }
        };
        self.stride = stride;
        let p = &mut self.pic;
        (p.nv12, p.fw, p.fh, p.stride, p.disp) = (self.nv12, fw, fh, stride, self.disp);
        Ok(())
    }

    fn drain(&mut self) -> anyhow::Result<()> {
        loop {
            if !self.out_type_set {
                match self.select_output() {
                    Ok(()) => {}
                    Err(_) => return Ok(()), // needs more input first
                }
            }
            let fallback = (self.stride.max(self.fw) * (self.fh + self.fh.div_ceil(2))).max(1920 * 1088 * 3 / 2) as u32;
            match process_output(&self.t, fallback)? {
                Out::NeedInput => return Ok(()),
                Out::StreamChange => self.select_output()?,
                Out::Sample(s) => {
                    self.take_picture(&s)?;
                    self.have = true;
                }
            }
        }
    }
}

impl DecBackend for Decoder {
    fn decode(&mut self, au: &[u8]) -> anyhow::Result<Option<YuvView<'_>>> {
        startup()?;
        // the size cap before the MFT sees (and allocates for) a new SPS
        check_h264_au(au)?;
        if let Some(sps) = nals(au).find(|n| nal_type(n) == NAL_SPS) {
            if let Ok((w, h)) = annexb::sps_dimensions(sps) {
                self.sps_dims = Some((w as usize, h as usize));
            }
        }
        let sample = sample_from(au, 0, 0)?;
        // SAFETY: COM call on a configured transform.
        match unsafe { self.t.ProcessInput(0, &sample, 0) } {
            Ok(()) => {}
            Err(e) if hr_is(&e, MF_E_NOTACCEPTING) => {
                self.drain()?;
                // SAFETY: as above.
                unsafe { self.t.ProcessInput(0, &sample, 0) }.map_err(|e| anyhow::anyhow!("{}: ProcessInput failed: {e}", self.name))?;
            }
            Err(e) => anyhow::bail!("{}: H.264 decode failed: {e}", self.name),
        }
        self.have = false;
        self.drain()?;
        if !self.have {
            return Ok(None);
        }
        // the geometry the picture was copied with, not the current output type's
        let p = &self.pic;
        let (fw, fh, stride) = (p.fw, p.fh, p.stride);
        let (w, h) = p.disp.or(self.sps_dims).map(|(w, h)| (w.min(fw), h.min(fh))).unwrap_or((fw, fh));
        anyhow::ensure!(w > 0 && h > 0 && stride >= fw && p.buf.len() >= stride * rows_420(fh), "{}: inconsistent decoded picture", self.name);
        let (y, chroma) = p.buf.split_at(stride * fh);
        if p.nv12 {
            Ok(Some(YuvView { w, h, y, y_stride: stride, u: chroma, v: &chroma[1..], uv_stride: stride, uv_step: 2 }))
        } else {
            let cs = stride / 2;
            let (u, v) = chroma.split_at(cs * fh.div_ceil(2));
            Ok(Some(YuvView { w, h, y, y_stride: stride, u, v, uv_stride: cs, uv_step: 1 }))
        }
    }

    fn hardware(&self) -> bool {
        false
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        end_streaming(&self.t);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::video::ContentHint;

    fn params(w: usize, h: usize) -> EncParams {
        EncParams { w, h, fps: 30, bitrate_kbps: 800, content: ContentHint::Motion, threads: 0, keyframe_interval_s: 2 }
    }

    fn picture(w: usize, h: usize, t: usize) -> I420Buf {
        let mut p = I420Buf::new(w, h);
        for y in 0..h {
            for x in 0..w {
                p.y[y * w + x] = (((x + 2 * t) * 255 / w) as u8 / 2).wrapping_add((y * 100 / h) as u8);
            }
        }
        for (i, v) in p.u.iter_mut().enumerate() {
            *v = 100 + (i % 40) as u8;
        }
        p
    }

    /// Skip (with a message) only when this Windows has no H.264 MFTs at all.
    fn missing(e: &anyhow::Error) -> bool {
        let s = format!("{e:#}");
        if s.contains("no Media Foundation H.264 MFT") || s.contains("MFStartup failed") {
            eprintln!("SKIP: {s}");
            return true;
        }
        false
    }

    #[test]
    fn mf_roundtrip_keyframe_bitrate() {
        let (w, h) = (320, 240);
        let mut enc = match Encoder::new(&params(w, h)) {
            Ok(e) => e,
            Err(e) if missing(&e) => return,
            Err(e) => panic!("encoder: {e:#}"),
        };
        eprintln!("encoder: {} (hardware: {})", enc.name(), enc.hardware());
        let mut dec = match Decoder::new() {
            Ok(d) => d,
            Err(e) if missing(&e) => return,
            Err(e) => panic!("decoder: {e:#}"),
        };
        eprintln!("decoder: {}", dec.name);
        let mut aus = 0;
        let mut decoded = 0;
        let mut keys = Vec::new();
        let mut last_err = 0u64;
        for t in 0..30usize {
            if t == 10 {
                enc.set_bitrate(400);
            }
            let mut pic = picture(w, h, t);
            let force = t == 0 || t == 20;
            let Some((au, key)) = enc.encode(&mut pic, t as u64 * 33_333, force).expect("encode") else { continue };
            aus += 1;
            assert!(au.starts_with(&[0, 0, 0, 1]) || au.starts_with(&[0, 0, 1]), "not Annex-B");
            if key {
                keys.push(t);
                assert!(nals(&au).any(|n| nal_type(n) == NAL_SPS), "keyframe without SPS");
            }
            if let Some(v) = dec.decode(&au).expect("decode") {
                decoded += 1;
                assert_eq!((v.w, v.h), (w, h));
                let mut err = 0u64;
                for y in 0..h {
                    for x in 0..w {
                        err += (v.y[y * v.y_stride + x] as i64 - pic.y[y * w + x] as i64).unsigned_abs();
                    }
                }
                last_err = err / (w * h) as u64;
            }
        }
        eprintln!("aus={aus} decoded={decoded} keys={keys:?} mean |dY|={last_err}");
        assert!(aus >= 25, "too few access units: {aus}");
        assert!(decoded >= 20, "too few decoded pictures: {decoded}");
        assert!(keys.first() == Some(&0), "first frame must be a keyframe: {keys:?}");
        assert!(keys.iter().any(|&k| (20..23).contains(&k)), "forced keyframe missing: {keys:?}");
        assert!(last_err <= 6, "decoded picture too far off: mean |dY| = {last_err}");
    }

    /// Split an Annex-B stream into access units (a slice with
    /// first_mb_in_slice == 0, or SEI/SPS/PPS/AUD, after a slice starts one).
    fn access_units(stream: &[u8]) -> Vec<Vec<u8>> {
        let mut aus: Vec<Vec<u8>> = Vec::new();
        let mut cur = Vec::new();
        let mut had_vcl = false;
        for n in nals(stream) {
            let vcl = matches!(nal_type(n), 1 | 5);
            let first_slice = vcl && n.get(1).is_some_and(|b| b & 0x80 != 0);
            if had_vcl && (first_slice || matches!(nal_type(n), 6..=9)) {
                aus.push(std::mem::take(&mut cur));
                had_vcl = false;
            }
            cur.extend_from_slice(&[0, 0, 0, 1]);
            cur.extend_from_slice(n);
            had_vcl |= vcl;
        }
        if !cur.is_empty() {
            aus.push(cur);
        }
        aus
    }

    /// Decode a stream made by another encoder (e.g. x264 constrained
    /// baseline, or OpenH264 with 4 slices; 320x180 → padded to 192 rows) and
    /// compare with a reference decode.
    /// Set LUMORA_MF_TEST_H264 / LUMORA_MF_TEST_YUV (raw I420 of every frame).
    #[test]
    fn mf_decodes_reference_stream() {
        let (Some(h264), Some(yuv)) = (std::env::var_os("LUMORA_MF_TEST_H264"), std::env::var_os("LUMORA_MF_TEST_YUV")) else {
            eprintln!("SKIP: LUMORA_MF_TEST_H264 / LUMORA_MF_TEST_YUV not set");
            return;
        };
        let stream = std::fs::read(h264).unwrap();
        let reference = std::fs::read(yuv).unwrap();
        let (w, h) = (320usize, 180usize);
        let fsize = w * h * 3 / 2;
        let mut dec = match Decoder::new() {
            Ok(d) => d,
            Err(e) if missing(&e) => return,
            Err(e) => panic!("decoder: {e:#}"),
        };
        eprintln!("decoder: {}", dec.name);
        let mut out = 0usize;
        let mut worst = 0u64;
        for au in access_units(&stream) {
            let Some(v) = dec.decode(&au).expect("decode") else { continue };
            assert_eq!((v.w, v.h), (w, h), "display size (crop) wrong");
            let r = &reference[out * fsize..(out + 1) * fsize];
            let mut err = 0u64;
            for y in 0..h {
                for x in 0..w {
                    err += (v.y[y * v.y_stride + x] as i64 - r[y * w + x] as i64).unsigned_abs();
                }
            }
            // chroma: first U sample of each row
            for cy in 0..h / 2 {
                err += (v.u[cy * v.uv_stride] as i64 - r[w * h + cy * w / 2] as i64).unsigned_abs();
            }
            worst = worst.max(err / (w * h) as u64);
            out += 1;
        }
        eprintln!("decoded {out} of {} frames, worst mean |d| = {worst}", reference.len() / fsize);
        assert!(out + 2 >= reference.len() / fsize, "too few frames decoded: {out}");
        assert!(worst <= 1, "decoded pictures differ from the reference decode");
    }

    /// Hardware MFT at 1080p (real Windows with Intel/NVIDIA/AMD; skips elsewhere,
    /// e.g. under Wine): hardware()==true, forced keyframes, timing.
    #[test]
    fn mf_hardware_encoder_1080p() {
        startup().unwrap();
        let (w, h) = (1920, 1080);
        let mut enc = match HwEncoder::open(&EncParams { w, h, fps: 60, bitrate_kbps: 8000, content: ContentHint::Screen, threads: 0, keyframe_interval_s: 2 }) {
            Ok(e) => e,
            Err(e) => {
                eprintln!("SKIP: no hardware H.264 encoder MFT: {e:#}");
                return;
            }
        };
        eprintln!("hardware encoder: {} (D3D11 textures: {})", enc.name, enc.d3d.is_some());
        assert!(enc.hardware());
        let mut dec = Decoder::new().ok();
        let (mut aus, mut keys, mut decoded) = (0, Vec::new(), 0);
        let t0 = std::time::Instant::now();
        let n = 120usize;
        for t in 0..n {
            let mut pic = picture(w, h, t);
            let force = t == 0 || t == 60;
            if let Some((au, key)) = enc.encode(&mut pic, t as u64 * 16_667, force).expect("encode") {
                aus += 1;
                assert!(au.starts_with(&[0, 0, 0, 1]) || au.starts_with(&[0, 0, 1]), "not Annex-B");
                if key {
                    keys.push(t);
                    assert!(nals(&au).any(|n| nal_type(n) == NAL_SPS), "keyframe without SPS");
                }
                if let Some(d) = dec.as_mut() {
                    if let Ok(Some(v)) = d.decode(&au) {
                        assert_eq!((v.w, v.h), (w, h));
                        decoded += 1;
                    }
                }
            }
        }
        let ms = t0.elapsed().as_secs_f64() * 1000.0 / n as f64;
        eprintln!("1080p: {aus} access units, keys at {keys:?}, decoded {decoded}, {ms:.2} ms/frame (incl. colour packing + upload)");
        assert!(aus >= n * 9 / 10, "too many dropped frames: {aus}/{n}");
        assert_eq!(keys.first(), Some(&0), "first output must be a keyframe: {keys:?}");
        assert!(keys.iter().any(|&k| (60..64).contains(&k)), "forced keyframe missing: {keys:?}");
    }

    /// A peer SPS above the decode cap is refused before the MFT sees it.
    #[test]
    fn mf_rejects_oversized_sps() {
        let mut dec = match Decoder::new() {
            Ok(d) => d,
            Err(e) if missing(&e) => return,
            Err(e) => panic!("decoder: {e:#}"),
        };
        // baseline SPS, 8192x8192 (512x512 macroblocks), poc type 2
        let au = [0, 0, 0, 1, 0x67, 0x42, 0xc0, 0x33, 0xda, 0x00, 0x20, 0x00, 0x04, 0x01, 0x90];
        let (w, h) = annexb::sps_dimensions(&au[4..]).unwrap();
        assert!(w > 4096 && h > 2304, "{w}x{h}");
        assert!(dec.decode(&au).is_err());
    }

    #[test]
    fn mf_rejects_bad_sizes() {
        if let Err(e) = Encoder::new(&params(15, 240)) {
            assert!(format!("{e:#}").contains("does not support"));
        }
        assert!(Encoder::new(&params(321, 240)).is_err());
    }
}
