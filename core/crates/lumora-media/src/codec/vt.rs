//! Apple VideoToolbox H.264 backend (macOS + iOS), raw FFI.
//!
//! * Encoder: `VTCompressionSession`, real-time, constrained baseline (falls
//!   back to baseline on older OS versions), no frame reordering, ABR with a
//!   1-second data-rate cap of 1.5x, periodic IDR, keyframe on demand. NV12
//!   pixel buffers from the session's pool; the AVCC output is converted to
//!   Annex-B with SPS/PPS in front of every keyframe.
//! * Decoder: `VTDecompressionSession` created from the SPS/PPS of the first
//!   IDR (re-created when they change), synchronous decode into NV12, planes
//!   copied into an owned buffer.
//!
//! Only symbols that exist since macOS 10.9 / iOS 8 are linked; newer
//! constants (constrained-baseline profile) are passed by their string value,
//! so the binary still loads on older systems (Rust has no weak linking).

#![allow(non_upper_case_globals, non_snake_case)]

use std::collections::VecDeque;
use std::ffi::c_void;
use std::ptr::{null, null_mut};

use core_foundation_sys::array::{kCFTypeArrayCallBacks, CFArrayCreate, CFArrayGetCount, CFArrayGetValueAtIndex, CFArrayRef};
use core_foundation_sys::base::{kCFAllocatorDefault, Boolean, CFAllocatorRef, CFIndex, CFRelease, CFTypeRef};
use core_foundation_sys::dictionary::{
    kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks, CFDictionaryCreateMutable, CFDictionaryGetValue, CFDictionaryRef,
    CFDictionarySetValue, CFMutableDictionaryRef,
};
use core_foundation_sys::number::{kCFBooleanFalse, kCFBooleanTrue, kCFNumberFloat64Type, kCFNumberSInt32Type, CFBooleanGetValue, CFBooleanRef, CFNumberCreate};
use core_foundation_sys::string::{kCFStringEncodingUTF8, CFStringCreateWithBytes, CFStringRef};
use parking_lot::Mutex;

use super::annexb::{self, nal_type, nals, NAL_PPS, NAL_SPS};
use super::{check_decode_dims, check_h264_au, decode_dims_ok, DecBackend, EncBackend, EncParams, YuvView};
use crate::color::I420Buf;

type OSStatus = i32;
type OSType = u32;
type CVReturn = i32;
type CMVideoCodecType = u32;
type CMItemCount = CFIndex;
type VTEncodeInfoFlags = u32;
type VTDecodeInfoFlags = u32;
type VTDecodeFrameFlags = u32;
type CVOptionFlags = u64;

type VTCompressionSessionRef = *mut c_void;
type VTDecompressionSessionRef = *mut c_void;
type CMSampleBufferRef = *mut c_void;
type CMBlockBufferRef = *mut c_void;
type CMFormatDescriptionRef = *mut c_void;
type CVPixelBufferRef = *mut c_void;
type CVPixelBufferPoolRef = *mut c_void;

/// `CMTime` (CMTime.h): 24 bytes, `{ int64 value; int32 timescale; uint32 flags; int64 epoch; }`.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
struct CMTime {
    value: i64,
    timescale: i32,
    flags: u32,
    epoch: i64,
}

const kCMTimeFlags_Valid: u32 = 1;
const CM_TIME_INVALID: CMTime = CMTime { value: 0, timescale: 0, flags: 0, epoch: 0 };

fn cm_time_us(us: i64) -> CMTime {
    CMTime { value: us, timescale: 1_000_000, flags: kCMTimeFlags_Valid, epoch: 0 }
}

/// `CMVideoDimensions`.
#[repr(C)]
#[derive(Clone, Copy)]
struct CMVideoDimensions {
    width: i32,
    height: i32,
}

type VTCompressionOutputCallback =
    extern "C" fn(output_ref_con: *mut c_void, source_frame_ref_con: *mut c_void, status: OSStatus, info_flags: VTEncodeInfoFlags, sample_buffer: CMSampleBufferRef);

type VTDecompressionOutputCallback = extern "C" fn(
    output_ref_con: *mut c_void,
    source_frame_ref_con: *mut c_void,
    status: OSStatus,
    info_flags: VTDecodeInfoFlags,
    image_buffer: CVPixelBufferRef,
    pts: CMTime,
    duration: CMTime,
);

#[repr(C)]
struct VTDecompressionOutputCallbackRecord {
    callback: VTDecompressionOutputCallback,
    ref_con: *mut c_void,
}

const kCMVideoCodecType_H264: CMVideoCodecType = u32::from_be_bytes(*b"avc1");
/// 'y420' — three planes Y, Cb, Cr.
const kCVPixelFormatType_420YpCbCr8Planar: OSType = u32::from_be_bytes(*b"y420");
/// '420v' — NV12, video range (what H.264 assumes without VUI).
const kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: OSType = u32::from_be_bytes(*b"420v");
/// '420f' — NV12, full range.
const kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: OSType = u32::from_be_bytes(*b"420f");
const kCVPixelBufferLock_ReadOnly: CVOptionFlags = 1;
const kCMBlockBufferAssureMemoryNowFlag: u32 = 1;
const kVTEncodeInfo_FrameDropped: u32 = 1 << 1;
const kVTInvalidSessionErr: OSStatus = -12903;

#[link(name = "VideoToolbox", kind = "framework")]
extern "C" {
    static kVTCompressionPropertyKey_RealTime: CFStringRef;
    static kVTCompressionPropertyKey_ProfileLevel: CFStringRef;
    static kVTCompressionPropertyKey_AllowFrameReordering: CFStringRef;
    static kVTCompressionPropertyKey_AverageBitRate: CFStringRef;
    static kVTCompressionPropertyKey_DataRateLimits: CFStringRef;
    static kVTCompressionPropertyKey_MaxKeyFrameInterval: CFStringRef;
    static kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: CFStringRef;
    static kVTCompressionPropertyKey_ExpectedFrameRate: CFStringRef;
    static kVTProfileLevel_H264_Baseline_AutoLevel: CFStringRef;
    static kVTEncodeFrameOptionKey_ForceKeyFrame: CFStringRef;
    #[cfg(target_os = "macos")]
    static kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder: CFStringRef;
    #[cfg(target_os = "macos")]
    static kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: CFStringRef;
    #[cfg(target_os = "macos")]
    static kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder: CFStringRef;

    fn VTCompressionSessionCreate(
        allocator: CFAllocatorRef,
        width: i32,
        height: i32,
        codec_type: CMVideoCodecType,
        encoder_specification: CFDictionaryRef,
        source_image_buffer_attributes: CFDictionaryRef,
        compressed_data_allocator: CFAllocatorRef,
        output_callback: VTCompressionOutputCallback,
        output_callback_ref_con: *mut c_void,
        session_out: *mut VTCompressionSessionRef,
    ) -> OSStatus;
    fn VTSessionSetProperty(session: CFTypeRef, key: CFStringRef, value: CFTypeRef) -> OSStatus;
    #[cfg(target_os = "macos")]
    fn VTSessionCopyProperty(session: CFTypeRef, key: CFStringRef, allocator: CFAllocatorRef, value_out: *mut c_void) -> OSStatus;
    fn VTCompressionSessionPrepareToEncodeFrames(session: VTCompressionSessionRef) -> OSStatus;
    fn VTCompressionSessionGetPixelBufferPool(session: VTCompressionSessionRef) -> CVPixelBufferPoolRef;
    fn VTCompressionSessionEncodeFrame(
        session: VTCompressionSessionRef,
        image_buffer: CVPixelBufferRef,
        pts: CMTime,
        duration: CMTime,
        frame_properties: CFDictionaryRef,
        source_frame_ref_con: *mut c_void,
        info_flags_out: *mut VTEncodeInfoFlags,
    ) -> OSStatus;
    fn VTCompressionSessionCompleteFrames(session: VTCompressionSessionRef, complete_until: CMTime) -> OSStatus;
    fn VTCompressionSessionInvalidate(session: VTCompressionSessionRef);

    fn VTDecompressionSessionCreate(
        allocator: CFAllocatorRef,
        format: CMFormatDescriptionRef,
        decoder_specification: CFDictionaryRef,
        destination_image_buffer_attributes: CFDictionaryRef,
        output_callback: *const VTDecompressionOutputCallbackRecord,
        session_out: *mut VTDecompressionSessionRef,
    ) -> OSStatus;
    fn VTDecompressionSessionDecodeFrame(
        session: VTDecompressionSessionRef,
        sample_buffer: CMSampleBufferRef,
        flags: VTDecodeFrameFlags,
        source_frame_ref_con: *mut c_void,
        info_flags_out: *mut VTDecodeInfoFlags,
    ) -> OSStatus;
    fn VTDecompressionSessionWaitForAsynchronousFrames(session: VTDecompressionSessionRef) -> OSStatus;
    fn VTDecompressionSessionInvalidate(session: VTDecompressionSessionRef);
}

#[link(name = "CoreMedia", kind = "framework")]
extern "C" {
    static kCMSampleAttachmentKey_NotSync: CFStringRef;

    fn CMSampleBufferGetDataBuffer(sbuf: CMSampleBufferRef) -> CMBlockBufferRef;
    fn CMSampleBufferGetFormatDescription(sbuf: CMSampleBufferRef) -> CMFormatDescriptionRef;
    fn CMSampleBufferGetSampleAttachmentsArray(sbuf: CMSampleBufferRef, create_if_necessary: Boolean) -> CFArrayRef;
    fn CMBlockBufferGetDataLength(bb: CMBlockBufferRef) -> usize;
    fn CMBlockBufferCopyDataBytes(bb: CMBlockBufferRef, offset: usize, length: usize, destination: *mut c_void) -> OSStatus;
    fn CMBlockBufferCreateWithMemoryBlock(
        structure_allocator: CFAllocatorRef,
        memory_block: *mut c_void,
        block_length: usize,
        block_allocator: CFAllocatorRef,
        custom_block_source: *const c_void,
        offset_to_data: usize,
        data_length: usize,
        flags: u32,
        block_buffer_out: *mut CMBlockBufferRef,
    ) -> OSStatus;
    fn CMBlockBufferReplaceDataBytes(source: *const c_void, destination: CMBlockBufferRef, offset_into_destination: usize, data_length: usize) -> OSStatus;
    fn CMSampleBufferCreateReady(
        allocator: CFAllocatorRef,
        data_buffer: CMBlockBufferRef,
        format_description: CMFormatDescriptionRef,
        num_samples: CMItemCount,
        num_sample_timing_entries: CMItemCount,
        sample_timing_array: *const c_void,
        num_sample_size_entries: CMItemCount,
        sample_size_array: *const usize,
        sample_buffer_out: *mut CMSampleBufferRef,
    ) -> OSStatus;
    fn CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        desc: CMFormatDescriptionRef,
        index: usize,
        parameter_set_pointer_out: *mut *const u8,
        parameter_set_size_out: *mut usize,
        parameter_set_count_out: *mut usize,
        nal_unit_header_length_out: *mut i32,
    ) -> OSStatus;
    fn CMVideoFormatDescriptionCreateFromH264ParameterSets(
        allocator: CFAllocatorRef,
        parameter_set_count: usize,
        parameter_set_pointers: *const *const u8,
        parameter_set_sizes: *const usize,
        nal_unit_header_length: i32,
        format_description_out: *mut CMFormatDescriptionRef,
    ) -> OSStatus;
    fn CMVideoFormatDescriptionGetDimensions(desc: CMFormatDescriptionRef) -> CMVideoDimensions;
}

#[link(name = "CoreVideo", kind = "framework")]
extern "C" {
    static kCVPixelBufferPixelFormatTypeKey: CFStringRef;
    static kCVPixelBufferWidthKey: CFStringRef;
    static kCVPixelBufferHeightKey: CFStringRef;
    static kCVPixelBufferIOSurfacePropertiesKey: CFStringRef;

    fn CVPixelBufferPoolCreatePixelBuffer(allocator: CFAllocatorRef, pool: CVPixelBufferPoolRef, out: *mut CVPixelBufferRef) -> CVReturn;
    fn CVPixelBufferCreate(allocator: CFAllocatorRef, width: usize, height: usize, format: OSType, attributes: CFDictionaryRef, out: *mut CVPixelBufferRef) -> CVReturn;
    fn CVPixelBufferLockBaseAddress(pb: CVPixelBufferRef, flags: CVOptionFlags) -> CVReturn;
    fn CVPixelBufferUnlockBaseAddress(pb: CVPixelBufferRef, flags: CVOptionFlags) -> CVReturn;
    fn CVPixelBufferGetPixelFormatType(pb: CVPixelBufferRef) -> OSType;
    fn CVPixelBufferGetWidth(pb: CVPixelBufferRef) -> usize;
    fn CVPixelBufferGetHeight(pb: CVPixelBufferRef) -> usize;
    fn CVPixelBufferGetPlaneCount(pb: CVPixelBufferRef) -> usize;
    fn CVPixelBufferGetBaseAddressOfPlane(pb: CVPixelBufferRef, plane: usize) -> *mut c_void;
    fn CVPixelBufferGetBytesPerRowOfPlane(pb: CVPixelBufferRef, plane: usize) -> usize;
    fn CVPixelBufferGetHeightOfPlane(pb: CVPixelBufferRef, plane: usize) -> usize;
}

// ------------------------------------------------------------------ CF helpers

/// Owned CF object (Create rule): released on drop.
struct Cf(CFTypeRef);

impl Cf {
    fn ptr(&self) -> CFTypeRef {
        self.0
    }
}

impl Drop for Cf {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: we own one reference (Create/Copy rule).
            unsafe { CFRelease(self.0) };
        }
    }
}

fn cf_i32(v: i32) -> Cf {
    // SAFETY: pointer to a local of the declared number type.
    Cf(unsafe { CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, (&raw const v).cast()) }.cast())
}

fn cf_f64(v: f64) -> Cf {
    // SAFETY: as above.
    Cf(unsafe { CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, (&raw const v).cast()) }.cast())
}

fn cf_bool(v: bool) -> CFTypeRef {
    // SAFETY: immortal constants.
    unsafe { if v { kCFBooleanTrue } else { kCFBooleanFalse } }.cast()
}

fn cf_str(s: &str) -> Cf {
    // SAFETY: valid UTF-8 bytes with their length.
    Cf(unsafe { CFStringCreateWithBytes(kCFAllocatorDefault, s.as_ptr(), s.len() as CFIndex, kCFStringEncodingUTF8, 0) }.cast())
}

fn cf_dict() -> Cf {
    // SAFETY: standard CF type callbacks (keys/values retained by the dictionary).
    Cf(unsafe { CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) }.cast())
}

fn dict_set(d: &Cf, key: CFStringRef, value: CFTypeRef) {
    if !d.0.is_null() && !key.is_null() && !value.is_null() {
        // SAFETY: mutable dictionary we created; CF retains key and value.
        unsafe { CFDictionarySetValue(d.0 as CFMutableDictionaryRef, key.cast(), value) };
    }
}

fn check(st: OSStatus, what: &str) -> anyhow::Result<()> {
    if st != 0 {
        anyhow::bail!("{what} failed (OSStatus {st})");
    }
    Ok(())
}

fn set_prop(session: *mut c_void, key: CFStringRef, value: CFTypeRef) -> OSStatus {
    // SAFETY: live session, CF key/value.
    unsafe { VTSessionSetProperty(session.cast_const(), key, value) }
}

#[cfg(target_os = "macos")]
fn copy_bool_prop(session: *mut c_void, key: CFStringRef) -> Option<bool> {
    let mut out: CFTypeRef = null();
    // SAFETY: out-pointer to a CFTypeRef; we release the copied value.
    let st = unsafe { VTSessionCopyProperty(session.cast_const(), key, kCFAllocatorDefault, (&raw mut out).cast()) };
    if st != 0 || out.is_null() {
        return None;
    }
    let owned = Cf(out);
    // SAFETY: the property is documented as a CFBoolean.
    Some(unsafe { CFBooleanGetValue(owned.ptr() as CFBooleanRef) })
}

// ------------------------------------------------------------------ encoder

#[derive(Default)]
struct EncOut {
    frames: VecDeque<(Vec<u8>, bool)>,
    error: Option<OSStatus>,
}

/// Called by VideoToolbox (possibly on its own thread) for every encoded frame.
extern "C" fn enc_callback(ref_con: *mut c_void, _src: *mut c_void, status: OSStatus, flags: VTEncodeInfoFlags, sbuf: CMSampleBufferRef) {
    if ref_con.is_null() {
        return;
    }
    // SAFETY: ref_con is the `Box<Mutex<EncOut>>` owned by the Encoder, which
    // invalidates the session (no more callbacks) before freeing it.
    let out = unsafe { &*(ref_con as *const Mutex<EncOut>) };
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if status != 0 {
            out.lock().error = Some(status);
            return;
        }
        if sbuf.is_null() || flags & kVTEncodeInfo_FrameDropped != 0 {
            return;
        }
        match unsafe { sample_to_annexb(sbuf) } {
            Ok(f) => out.lock().frames.push_back(f),
            Err(e) => {
                tracing::debug!("VideoToolbox output: {e:#}");
                out.lock().error = Some(-1);
            }
        }
    }));
    if r.is_err() {
        out.lock().error = Some(-1);
    }
}

/// Convert an encoded `CMSampleBuffer` (AVCC) to an Annex-B access unit.
///
/// # Safety
/// `sbuf` must be a valid sample buffer (borrowed for the call).
unsafe fn sample_to_annexb(sbuf: CMSampleBufferRef) -> anyhow::Result<(Vec<u8>, bool)> {
    // keyframe = no NotSync attachment (or NotSync == false)
    let mut key = true;
    let atts = CMSampleBufferGetSampleAttachmentsArray(sbuf, 0);
    if !atts.is_null() && CFArrayGetCount(atts) > 0 {
        let d = CFArrayGetValueAtIndex(atts, 0) as CFDictionaryRef;
        if !d.is_null() {
            let v = CFDictionaryGetValue(d, kCMSampleAttachmentKey_NotSync.cast());
            if !v.is_null() && CFBooleanGetValue(v as CFBooleanRef) {
                key = false;
            }
        }
    }
    let fmt = CMSampleBufferGetFormatDescription(sbuf);
    let mut nal_len = 4i32;
    let mut out = Vec::new();
    if !fmt.is_null() {
        let mut count = 0usize;
        let (mut p, mut n) = (null(), 0usize);
        let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &mut p, &mut n, &mut count, &mut nal_len);
        if st == 0 && key {
            for i in 0..count.min(8) {
                let (mut p, mut n) = (null(), 0usize);
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &mut p, &mut n, null_mut(), null_mut()) == 0 && !p.is_null() && n > 0 {
                    out.extend_from_slice(&[0, 0, 0, 1]);
                    out.extend_from_slice(std::slice::from_raw_parts(p, n));
                }
            }
        }
    }
    anyhow::ensure!(matches!(nal_len, 1 | 2 | 4), "unexpected NAL length size {nal_len}");
    let bb = CMSampleBufferGetDataBuffer(sbuf);
    anyhow::ensure!(!bb.is_null(), "sample buffer without data");
    let len = CMBlockBufferGetDataLength(bb);
    anyhow::ensure!(len > 0 && len < 64 << 20, "bad encoded size {len}");
    let mut avcc = vec![0u8; len];
    check(CMBlockBufferCopyDataBytes(bb, 0, len, avcc.as_mut_ptr().cast()), "CMBlockBufferCopyDataBytes")?;
    annexb::avcc_to_annexb(&avcc, nal_len as usize, &mut out)?;
    Ok((out, key))
}

/// Average bitrate + a 1-second cap of 1.5x on `session` (no-op when null).
fn apply_bitrate(session: VTCompressionSessionRef, kbps: u32) {
    if session.is_null() {
        return;
    }
    let bps = (kbps as i64 * 1000).clamp(50_000, i32::MAX as i64) as i32;
    let cap_bytes = cf_f64(bps as f64 * 1.5 / 8.0);
    let one_s = cf_f64(1.0);
    let vals: [CFTypeRef; 2] = [cap_bytes.ptr(), one_s.ptr()];
    // SAFETY: two valid CFNumbers; the array retains them.
    let arr = Cf(unsafe { CFArrayCreate(kCFAllocatorDefault, vals.as_ptr().cast(), 2, &kCFTypeArrayCallBacks) }.cast());
    // SAFETY: linked constants, live session.
    unsafe {
        let r1 = set_prop(session, kVTCompressionPropertyKey_AverageBitRate, cf_i32(bps).ptr());
        let r2 = set_prop(session, kVTCompressionPropertyKey_DataRateLimits, arr.ptr());
        if r1 != 0 || r2 != 0 {
            tracing::debug!("VideoToolbox bitrate {bps}: {r1}/{r2}");
        }
    }
}

pub(crate) struct Encoder {
    /// null after a failed (re)build: every use is guarded, `encode` rebuilds
    /// or returns an error (the generic layer then switches to its fallback)
    session: VTCompressionSessionRef,
    out: Box<Mutex<EncOut>>,
    p: EncParams,
    bitrate_kbps: u32,
    last_pts: i64,
    hardware: bool,
}

// SAFETY: a VTCompressionSession may be driven from any thread; the encoder
// is only used through `&mut self` (one caller at a time), and the callback
// state is behind a Mutex.
unsafe impl Send for Encoder {}

impl Encoder {
    pub fn new(p: &EncParams) -> anyhow::Result<Self> {
        let out = Box::new(Mutex::new(EncOut::default()));
        let mut e = Self { session: null_mut(), out, p: p.clone(), bitrate_kbps: p.bitrate_kbps, last_pts: -1, hardware: true };
        e.create()?;
        Ok(e)
    }

    fn create(&mut self) -> anyhow::Result<()> {
        self.destroy();
        let p = &self.p;
        anyhow::ensure!(p.w >= 16 && p.h >= 16 && p.w <= 8192 && p.h <= 8192, "unsupported size {}x{}", p.w, p.h);
        let spec = cf_dict();
        #[cfg(target_os = "macos")]
        // SAFETY: linked constant.
        dict_set(&spec, unsafe { kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder }, cf_bool(true));
        let attrs = cf_dict();
        let (fmt, w, h) = (cf_i32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange as i32), cf_i32(p.w as i32), cf_i32(p.h as i32));
        let iosurf = cf_dict();
        // SAFETY: linked constants.
        unsafe {
            dict_set(&attrs, kCVPixelBufferPixelFormatTypeKey, fmt.ptr());
            dict_set(&attrs, kCVPixelBufferWidthKey, w.ptr());
            dict_set(&attrs, kCVPixelBufferHeightKey, h.ptr());
            dict_set(&attrs, kCVPixelBufferIOSurfacePropertiesKey, iosurf.ptr());
        }
        let mut s: VTCompressionSessionRef = null_mut();
        let refcon = (&*self.out as *const Mutex<EncOut>).cast_mut().cast();
        // SAFETY: all arguments valid; refcon outlives the session (see Drop).
        let st = unsafe {
            VTCompressionSessionCreate(
                kCFAllocatorDefault,
                p.w as i32,
                p.h as i32,
                kCMVideoCodecType_H264,
                spec.ptr().cast(),
                attrs.ptr().cast(),
                kCFAllocatorDefault,
                enc_callback,
                refcon,
                &mut s,
            )
        };
        check(st, "VTCompressionSessionCreate")?;
        anyhow::ensure!(!s.is_null(), "VTCompressionSessionCreate returned no session");
        // `self.session` is only set once the session is fully set up: a failure
        // below leaves it null (never half-configured) and frees `s`
        if let Err(e) = self.configure(s) {
            // SAFETY: our own session, not stored anywhere; Invalidate stops callbacks.
            unsafe {
                VTCompressionSessionInvalidate(s);
                CFRelease(s.cast_const());
            }
            return Err(e);
        }
        self.session = s;
        Ok(())
    }

    /// Session properties of a freshly created session `s`.
    fn configure(&mut self, s: VTCompressionSessionRef) -> anyhow::Result<()> {
        let p = &self.p;
        // SAFETY: linked constants, live session.
        unsafe {
            set_prop(s, kVTCompressionPropertyKey_RealTime, cf_bool(true));
            set_prop(s, kVTCompressionPropertyKey_AllowFrameReordering, cf_bool(false));
            // Constrained baseline needs macOS 12 / iOS 15; its constant is passed
            // by value so older systems still load us — they get plain baseline.
            let cbp = cf_str("H264_ConstrainedBaseline_AutoLevel");
            if set_prop(s, kVTCompressionPropertyKey_ProfileLevel, cbp.ptr()) != 0 {
                check(set_prop(s, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel.cast()), "set baseline profile")?;
            }
            let fps = p.fps.max(1);
            let gop = fps.saturating_mul(p.keyframe_interval_s);
            if gop > 0 {
                set_prop(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, cf_i32(gop.min(i32::MAX as u32) as i32).ptr());
                set_prop(s, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, cf_f64(p.keyframe_interval_s as f64).ptr());
            }
            set_prop(s, kVTCompressionPropertyKey_ExpectedFrameRate, cf_i32(fps as i32).ptr());
        }
        apply_bitrate(s, self.bitrate_kbps);
        #[cfg(target_os = "macos")]
        {
            // SAFETY: linked constant.
            self.hardware = copy_bool_prop(s, unsafe { kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder }).unwrap_or(false);
        }
        // SAFETY: live session.
        let st = unsafe { VTCompressionSessionPrepareToEncodeFrames(s) };
        if st != 0 {
            tracing::debug!("VTCompressionSessionPrepareToEncodeFrames: {st}");
        }
        Ok(())
    }

    fn destroy(&mut self) {
        if !self.session.is_null() {
            // SAFETY: Invalidate stops callbacks; then drop our reference.
            unsafe {
                VTCompressionSessionInvalidate(self.session);
                CFRelease(self.session.cast_const());
            }
            self.session = null_mut();
        }
    }

    /// Get an NV12/I420 pixel buffer and copy `pic` into it.
    fn fill_buffer(&self, pic: &I420Buf) -> anyhow::Result<Cf> {
        anyhow::ensure!(!self.session.is_null(), "VideoToolbox encoder has no session");
        let (w, h) = (pic.width, pic.height);
        let mut pb: CVPixelBufferRef = null_mut();
        // SAFETY: live session; pool may be null (then allocate ourselves).
        let pool = unsafe { VTCompressionSessionGetPixelBufferPool(self.session) };
        let st = if pool.is_null() { -1 } else { unsafe { CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &mut pb) } };
        if st != 0 || pb.is_null() {
            // SAFETY: out-pointer to a local.
            let st = unsafe { CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, null(), &mut pb) };
            check(st, "CVPixelBufferCreate")?;
        }
        let pb = Cf(pb.cast_const());
        let buf = pb.ptr() as CVPixelBufferRef;
        // SAFETY: we own `buf`; all writes stay within plane height × bytes-per-row.
        unsafe {
            check(CVPixelBufferLockBaseAddress(buf, 0), "CVPixelBufferLockBaseAddress")?;
            let r = copy_into(buf, pic);
            CVPixelBufferUnlockBaseAddress(buf, 0);
            r?;
        }
        Ok(pb)
    }
}

/// Copy a tightly packed I420 picture into a locked NV12 or I420 pixel buffer.
///
/// # Safety
/// `buf` must be locked for writing.
unsafe fn copy_into(buf: CVPixelBufferRef, pic: &I420Buf) -> anyhow::Result<()> {
    let (w, h) = (pic.width, pic.height);
    let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
    let fmt = CVPixelBufferGetPixelFormatType(buf);
    let planes = CVPixelBufferGetPlaneCount(buf);
    let plane = |i: usize, rows: usize, row_bytes: usize| -> anyhow::Result<(*mut u8, usize)> {
        let base = CVPixelBufferGetBaseAddressOfPlane(buf, i) as *mut u8;
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(buf, i);
        let ph = CVPixelBufferGetHeightOfPlane(buf, i);
        anyhow::ensure!(!base.is_null() && bpr >= row_bytes && ph >= rows, "pixel buffer plane {i} too small");
        Ok((base, bpr))
    };
    let (yb, ys) = plane(0, h, w)?;
    for r in 0..h {
        std::ptr::copy_nonoverlapping(pic.y.as_ptr().add(r * w), yb.add(r * ys), w);
    }
    match (fmt, planes) {
        (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange | kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 2) => {
            let (uvb, uvs) = plane(1, ch, cw * 2)?;
            for r in 0..ch {
                let row = std::slice::from_raw_parts_mut(uvb.add(r * uvs), cw * 2);
                let (u, v) = (&pic.u[r * cw..(r + 1) * cw], &pic.v[r * cw..(r + 1) * cw]);
                for (c, px) in row.chunks_exact_mut(2).enumerate() {
                    px[0] = u[c];
                    px[1] = v[c];
                }
            }
        }
        (kCVPixelFormatType_420YpCbCr8Planar, 3) => {
            for (i, src) in [(1, &pic.u), (2, &pic.v)] {
                let (b, s) = plane(i, ch, cw)?;
                for r in 0..ch {
                    std::ptr::copy_nonoverlapping(src.as_ptr().add(r * cw), b.add(r * s), cw);
                }
            }
        }
        _ => anyhow::bail!("unexpected pixel buffer format {fmt:#x} ({planes} planes)"),
    }
    Ok(())
}

impl Drop for Encoder {
    fn drop(&mut self) {
        self.destroy();
    }
}

impl EncBackend for Encoder {
    fn encode(&mut self, pic: &mut I420Buf, ts_us: u64, force_keyframe: bool) -> anyhow::Result<Option<(Vec<u8>, bool)>> {
        anyhow::ensure!(pic.width == self.p.w && pic.height == self.p.h, "picture size changed");
        // VideoToolbox wants strictly increasing timestamps.
        let pts = (ts_us.min(i64::MAX as u64) as i64).max(self.last_pts.saturating_add(1));
        self.last_pts = pts;
        if self.session.is_null() {
            // an earlier rebuild failed: try again; still failing → an error
            // (never a call on a null session)
            self.create().map_err(|e| e.context("VideoToolbox encoder session rebuild failed"))?;
        }
        let mut retried = false;
        loop {
            let pb = self.fill_buffer(pic)?;
            let props = if force_keyframe {
                let d = cf_dict();
                // SAFETY: linked constant.
                dict_set(&d, unsafe { kVTEncodeFrameOptionKey_ForceKeyFrame }, cf_bool(true));
                Some(d)
            } else {
                None
            };
            let mut flags = 0;
            // SAFETY: live session and pixel buffer; frame properties optional.
            let st = unsafe {
                VTCompressionSessionEncodeFrame(
                    self.session,
                    pb.ptr() as CVPixelBufferRef,
                    cm_time_us(pts),
                    CM_TIME_INVALID,
                    props.as_ref().map(|d| d.ptr().cast()).unwrap_or(null()),
                    null_mut(),
                    &mut flags,
                )
            };
            if st == kVTInvalidSessionErr && !retried {
                // e.g. iOS app returned from background: rebuild the session once
                retried = true;
                // on failure the session stays null and this returns the error
                self.create().map_err(|e| e.context("VideoToolbox encoder session rebuild failed"))?;
                continue;
            }
            check(st, "VTCompressionSessionEncodeFrame")?;
            // SAFETY: live session; flushes so the callback ran before we return.
            check(unsafe { VTCompressionSessionCompleteFrames(self.session, CM_TIME_INVALID) }, "VTCompressionSessionCompleteFrames")?;
            break;
        }
        let mut o = self.out.lock();
        if let Some(e) = o.error.take() {
            o.frames.clear();
            anyhow::bail!("VideoToolbox encode failed (OSStatus {e})");
        }
        Ok(o.frames.pop_front())
    }

    fn set_bitrate(&mut self, kbps: u32) {
        if kbps != self.bitrate_kbps {
            self.bitrate_kbps = kbps;
            apply_bitrate(self.session, kbps);
        }
    }

    fn hardware(&self) -> bool {
        self.hardware
    }
}

// ------------------------------------------------------------------ decoder

#[derive(Default)]
struct DecOut {
    /// tightly packed NV12 (Y w*h, then interleaved UV cw*2 per row) or I420
    data: Vec<u8>,
    w: usize,
    h: usize,
    planar: bool,
    produced: bool,
    error: Option<OSStatus>,
}

extern "C" fn dec_callback(ref_con: *mut c_void, _src: *mut c_void, status: OSStatus, _flags: VTDecodeInfoFlags, img: CVPixelBufferRef, _pts: CMTime, _dur: CMTime) {
    if ref_con.is_null() {
        return;
    }
    // SAFETY: ref_con is the decoder's `Box<Mutex<DecOut>>`, alive until the
    // session is invalidated.
    let out = unsafe { &*(ref_con as *const Mutex<DecOut>) };
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut o = out.lock();
        if status != 0 || img.is_null() {
            o.error = Some(if status != 0 { status } else { -1 });
            return;
        }
        // SAFETY: valid image buffer for the duration of the callback.
        match unsafe { copy_out(img, &mut o) } {
            Ok(()) => o.produced = true,
            Err(e) => {
                tracing::debug!("VideoToolbox decode output: {e:#}");
                o.error = Some(-1);
            }
        }
    }));
    if r.is_err() {
        out.lock().error = Some(-1);
    }
}

/// Copy a decoded NV12 / I420 pixel buffer into `o.data` (tightly packed).
///
/// # Safety
/// `img` must be a valid CVPixelBuffer.
unsafe fn copy_out(img: CVPixelBufferRef, o: &mut DecOut) -> anyhow::Result<()> {
    check(CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly), "lock decoded buffer")?;
    let r = (|| -> anyhow::Result<()> {
        let (w, h) = (CVPixelBufferGetWidth(img), CVPixelBufferGetHeight(img));
        anyhow::ensure!(decode_dims_ok(w, h), "bad decoded size {w}x{h}");
        let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
        let fmt = CVPixelBufferGetPixelFormatType(img);
        let planes = CVPixelBufferGetPlaneCount(img);
        let src = |i: usize, rows: usize, row_bytes: usize| -> anyhow::Result<(*const u8, usize)> {
            let b = CVPixelBufferGetBaseAddressOfPlane(img, i) as *const u8;
            let s = CVPixelBufferGetBytesPerRowOfPlane(img, i);
            anyhow::ensure!(!b.is_null() && s >= row_bytes && CVPixelBufferGetHeightOfPlane(img, i) >= rows, "decoded plane {i} too small");
            Ok((b, s))
        };
        let planar = match (fmt, planes) {
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange | kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 2) => false,
            (kCVPixelFormatType_420YpCbCr8Planar, 3) => true,
            _ => anyhow::bail!("unexpected decoded format {fmt:#x} ({planes} planes)"),
        };
        o.data.clear();
        o.data.reserve(w * h + cw * ch * 2);
        let (yb, ys) = src(0, h, w)?;
        for r in 0..h {
            o.data.extend_from_slice(std::slice::from_raw_parts(yb.add(r * ys), w));
        }
        if planar {
            for i in [1, 2] {
                let (b, s) = src(i, ch, cw)?;
                for r in 0..ch {
                    o.data.extend_from_slice(std::slice::from_raw_parts(b.add(r * s), cw));
                }
            }
        } else {
            let (b, s) = src(1, ch, cw * 2)?;
            for r in 0..ch {
                o.data.extend_from_slice(std::slice::from_raw_parts(b.add(r * s), cw * 2));
            }
        }
        (o.w, o.h, o.planar) = (w, h, planar);
        Ok(())
    })();
    CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
    r
}

pub(crate) struct Decoder {
    session: VTDecompressionSessionRef,
    format: Option<Cf>,
    sps: Vec<u8>,
    pps: Vec<u8>,
    out: Box<Mutex<DecOut>>,
    /// the last decoded picture, owned (the returned view borrows it)
    pic: DecOut,
    hardware: bool,
}

// SAFETY: as for the encoder — one caller at a time through `&mut self`,
// callback state behind a Mutex.
unsafe impl Send for Decoder {}

impl Decoder {
    pub fn new() -> anyhow::Result<Self> {
        Ok(Self {
            session: null_mut(),
            format: None,
            sps: Vec::new(),
            pps: Vec::new(),
            out: Box::new(Mutex::new(DecOut::default())),
            pic: DecOut::default(),
            hardware: true,
        })
    }

    fn destroy(&mut self) {
        if !self.session.is_null() {
            // SAFETY: Invalidate stops callbacks, then release our reference.
            unsafe {
                VTDecompressionSessionInvalidate(self.session);
                CFRelease(self.session.cast_const());
            }
            self.session = null_mut();
        }
        self.format = None;
    }

    fn create(&mut self, sps: Vec<u8>, pps: Vec<u8>) -> anyhow::Result<()> {
        self.destroy();
        let ptrs = [sps.as_ptr(), pps.as_ptr()];
        let sizes = [sps.len(), pps.len()];
        let mut fmt: CMFormatDescriptionRef = null_mut();
        // SAFETY: two parameter sets with their sizes; 4-byte AVCC lengths.
        let st = unsafe { CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, ptrs.as_ptr(), sizes.as_ptr(), 4, &mut fmt) };
        check(st, "CMVideoFormatDescriptionCreateFromH264ParameterSets")?;
        let fmt = Cf(fmt.cast_const());
        // SAFETY: valid format description.
        let dims = unsafe { CMVideoFormatDescriptionGetDimensions(fmt.ptr().cast_mut()) };
        anyhow::ensure!(dims.width > 0 && dims.height > 0, "bad stream size {}x{}", dims.width, dims.height);
        check_decode_dims(dims.width as usize, dims.height as usize)?;

        let attrs = cf_dict();
        let pf = cf_i32(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange as i32);
        // SAFETY: linked constant.
        dict_set(&attrs, unsafe { kCVPixelBufferPixelFormatTypeKey }, pf.ptr());
        let record = VTDecompressionOutputCallbackRecord { callback: dec_callback, ref_con: (&*self.out as *const Mutex<DecOut>).cast_mut().cast() };
        let mut s: VTDecompressionSessionRef = null_mut();
        // SAFETY: valid format/attributes; the record is copied by VT; ref_con
        // outlives the session (destroyed before `out` is dropped).
        let st = unsafe { VTDecompressionSessionCreate(kCFAllocatorDefault, fmt.ptr().cast_mut(), null(), attrs.ptr().cast(), &record, &mut s) };
        check(st, "VTDecompressionSessionCreate")?;
        anyhow::ensure!(!s.is_null(), "VTDecompressionSessionCreate returned no session");
        self.session = s;
        self.format = Some(fmt);
        #[cfg(target_os = "macos")]
        {
            // SAFETY: linked constant.
            self.hardware = copy_bool_prop(s, unsafe { kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder }).unwrap_or(false);
        }
        self.sps = sps;
        self.pps = pps;
        Ok(())
    }

    /// Decode one AVCC sample synchronously into `self.out`.
    fn decode_avcc(&mut self, avcc: &[u8]) -> anyhow::Result<OSStatus> {
        anyhow::ensure!(!self.session.is_null(), "VideoToolbox decoder has no session");
        let fmt = self.format.as_ref().map(|f| f.ptr().cast_mut()).ok_or_else(|| anyhow::anyhow!("no format"))?;
        let mut bb: CMBlockBufferRef = null_mut();
        // SAFETY: CoreMedia allocates the block (memory_block = NULL); we copy into it.
        unsafe {
            check(
                CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, null_mut(), avcc.len(), kCFAllocatorDefault, null(), 0, avcc.len(), kCMBlockBufferAssureMemoryNowFlag, &mut bb),
                "CMBlockBufferCreateWithMemoryBlock",
            )?;
        }
        let bb = Cf(bb.cast_const());
        // SAFETY: destination has exactly avcc.len() bytes.
        check(unsafe { CMBlockBufferReplaceDataBytes(avcc.as_ptr().cast(), bb.ptr().cast_mut(), 0, avcc.len()) }, "CMBlockBufferReplaceDataBytes")?;
        let size = avcc.len();
        let mut sb: CMSampleBufferRef = null_mut();
        // SAFETY: one sample of `size` bytes, no timing info.
        check(
            unsafe { CMSampleBufferCreateReady(kCFAllocatorDefault, bb.ptr().cast_mut(), fmt, 1, 0, null(), 1, &size, &mut sb) },
            "CMSampleBufferCreateReady",
        )?;
        let sb = Cf(sb.cast_const());
        {
            let mut o = self.out.lock();
            o.produced = false;
            o.error = None;
        }
        let mut flags = 0;
        // SAFETY: live session and sample; flags 0 = synchronous decode.
        let st = unsafe { VTDecompressionSessionDecodeFrame(self.session, sb.ptr().cast_mut(), 0, null_mut(), &mut flags) };
        if st == 0 {
            // SAFETY: live session.
            unsafe { VTDecompressionSessionWaitForAsynchronousFrames(self.session) };
        }
        Ok(st)
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        self.destroy();
    }
}

impl DecBackend for Decoder {
    fn decode(&mut self, au: &[u8]) -> anyhow::Result<Option<YuvView<'_>>> {
        // the size cap before VideoToolbox sees (and allocates for) a new SPS
        check_h264_au(au)?;
        let (mut sps, mut pps) = (None, None);
        for n in nals(au) {
            match nal_type(n) {
                NAL_SPS => sps = Some(n),
                NAL_PPS => pps = Some(n),
                _ => {}
            }
        }
        if let (Some(s), Some(p)) = (sps, pps) {
            if self.session.is_null() || s != self.sps.as_slice() || p != self.pps.as_slice() {
                self.create(s.to_vec(), p.to_vec())?;
            }
        }
        if self.session.is_null() {
            anyhow::bail!("waiting for SPS/PPS");
        }
        let avcc = annexb::annexb_to_avcc_slices(au);
        if avcc.is_empty() {
            return Ok(None); // parameter sets only
        }
        let st = self.decode_avcc(&avcc)?;
        if st == kVTInvalidSessionErr {
            // session lost (iOS background): rebuilt on the next keyframe
            self.destroy();
            anyhow::bail!("VideoToolbox session invalidated");
        }
        check(st, "VTDecompressionSessionDecodeFrame")?;
        {
            let mut o = self.out.lock();
            if let Some(e) = o.error.take() {
                anyhow::bail!("VideoToolbox decode failed (OSStatus {e})");
            }
            if !o.produced {
                return Ok(None);
            }
            // swap buffers: the callback reuses the old allocation next time
            std::mem::swap(&mut self.pic.data, &mut o.data);
            (self.pic.w, self.pic.h, self.pic.planar) = (o.w, o.h, o.planar);
        }
        let (w, h) = (self.pic.w, self.pic.h);
        let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
        let d = &self.pic.data;
        anyhow::ensure!(d.len() >= w * h + cw * ch * 2, "decoded buffer too small");
        let (y, rest) = d.split_at(w * h);
        Ok(Some(if self.pic.planar {
            let (u, v) = rest.split_at(cw * ch);
            YuvView { w, h, y, y_stride: w, u, v, uv_stride: cw, uv_step: 1 }
        } else {
            YuvView { w, h, y, y_stride: w, u: rest, v: &rest[1..], uv_stride: cw * 2, uv_step: 2 }
        }))
    }

    fn hardware(&self) -> bool {
        self.hardware
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn picture(w: usize, h: usize, t: usize) -> I420Buf {
        let mut p = I420Buf::new(w, h);
        for r in 0..h {
            for c in 0..w {
                p.y[r * w + c] = ((c + r + t * 4) % 220 + 16) as u8;
            }
        }
        p
    }

    /// macOS/iOS CI only: encode → Annex-B → decode with VideoToolbox.
    #[test]
    fn videotoolbox_roundtrip() {
        let p = EncParams { w: 320, h: 240, fps: 30, bitrate_kbps: 800, content: Default::default(), threads: 0, keyframe_interval_s: 2 };
        let mut enc = Encoder::new(&p).expect("VideoToolbox encoder");
        let mut dec = Decoder::new().unwrap();
        let mut got = None;
        let mut first_key = None;
        for t in 0..10 {
            let mut pic = picture(320, 240, t);
            if let Some((au, key)) = enc.encode(&mut pic, t as u64 * 33_333, t == 0).unwrap() {
                first_key.get_or_insert(key);
                assert!(annexb::nals(&au).count() > 0, "Annex-B output");
                if key {
                    assert!(annexb::has_idr(&au));
                    assert!(annexb::nals(&au).any(|n| nal_type(n) == NAL_SPS), "keyframe carries SPS");
                }
                if let Some(v) = dec.decode(&au).unwrap() {
                    got = Some((v.w, v.h, v.uv_step));
                }
            }
        }
        assert_eq!(first_key, Some(true));
        let (w, h, _) = got.expect("decoded picture");
        assert_eq!((w, h), (320, 240));
        enc.set_bitrate(400);
        assert!(enc.encode(&mut picture(320, 240, 11), 11 * 33_333, true).is_ok());
    }
}
