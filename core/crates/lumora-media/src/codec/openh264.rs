//! OpenH264 compiled from source — DEV/TEST BUILDS ONLY (`openh264-source`
//! feature): gives Linux test machines an H.264 path (H.264 → VP8 switch,
//! older-peer interop). Release builds never contain it (patent licensing).
//!
//! Encoder configuration: constrained-baseline profile (CAVLC, no B-frames),
//! bitrate rate-control with frame skipping, screen-content usage type,
//! IDR on demand plus a periodic IDR every ~2 s, and N fixed slices encoded
//! on N threads (OpenH264 only parallelises across slices).
//!
//! The encoder talks to `openh264-sys2` directly because the `openh264`
//! wrapper does not expose slice/thread configuration.

use std::os::raw::c_int;
use std::ptr::null_mut;

use anyhow::anyhow;
use openh264::decoder::{Decoder as OhDecoder, DecoderConfig};
use openh264::formats::YUVSource;
use openh264_sys2::{
    DynamicAPI, ISVCEncoder, CAMERA_VIDEO_REAL_TIME, SEncParamExt, SFrameBSInfo, SSourcePicture, API, CONSTANT_ID, LOW_COMPLEXITY,
    PRO_BASELINE, RC_BITRATE_MODE, SCREEN_CONTENT_REAL_TIME, SM_FIXEDSLCNUM_SLICE, videoFormatI420,
    videoFrameTypeI, videoFrameTypeIDR, videoFrameTypeInvalid, videoFrameTypeSkip,
};

use super::{check_decode_dims, check_h264_au, DecBackend, EncBackend, EncParams, YuvView};
use crate::color::I420Buf;
use crate::video::ContentHint;

#[cfg(feature = "openh264-source")]
pub(crate) fn source_api() -> DynamicAPI {
    DynamicAPI::from_source()
}

/// Owned OpenH264 encoder instance.
struct RawEncoder {
    api: DynamicAPI,
    ptr: *mut ISVCEncoder,
    initialised: bool,
}

// SAFETY: an OpenH264 encoder instance may be used from any thread as long as
// calls are not concurrent; the backend requires `&mut self` for all calls.
unsafe impl Send for RawEncoder {}

macro_rules! vcall {
    ($self:expr, $f:ident $(, $arg:expr)*) => {{
        // SAFETY: `ptr` is a live encoder created by WelsCreateSVCEncoder; the
        // vtable entry exists for every OpenH264 build.
        let vt = unsafe { &**$self.ptr };
        match vt.$f {
            Some(f) => unsafe { f($self.ptr $(, $arg)*) },
            None => -1,
        }
    }};
}

impl RawEncoder {
    fn new(api: DynamicAPI) -> anyhow::Result<Self> {
        let mut ptr: *mut ISVCEncoder = null_mut();
        // SAFETY: out-pointer to a local.
        let r = unsafe { api.WelsCreateSVCEncoder(&mut ptr) };
        if r != 0 || ptr.is_null() {
            anyhow::bail!("WelsCreateSVCEncoder failed ({r})");
        }
        Ok(Self { api, ptr, initialised: false })
    }

    fn init(&mut self, p: &SEncParamExt) -> anyhow::Result<()> {
        if self.initialised {
            vcall!(self, Uninitialize);
            self.initialised = false;
        }
        let r = vcall!(self, InitializeExt, p);
        if r != 0 {
            anyhow::bail!("OpenH264 InitializeExt failed ({r}) for {}x{}", p.iPicWidth, p.iPicHeight);
        }
        self.initialised = true;
        Ok(())
    }
}

impl Drop for RawEncoder {
    fn drop(&mut self) {
        if self.initialised {
            vcall!(self, Uninitialize);
        }
        // SAFETY: pointer came from WelsCreateSVCEncoder and is destroyed once.
        unsafe { self.api.WelsDestroySVCEncoder(self.ptr) };
    }
}

fn encoder_threads(requested: u32) -> usize {
    if requested > 0 {
        return requested.clamp(1, 16) as usize;
    }
    std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2).clamp(1, 4)
}

pub(crate) struct Encoder {
    raw: RawEncoder,
    bitrate_kbps: u32,
    bs: Box<SFrameBSInfo>,
}

// SAFETY: `bs` only holds pointers into the encoder's own output buffers
// (owned by `raw`, which is Send); they are read on the thread that encodes.
unsafe impl Send for Encoder {}

impl Encoder {
    pub fn new(api: DynamicAPI, p: &EncParams) -> anyhow::Result<Self> {
        let mut e = Self { raw: RawEncoder::new(api)?, bitrate_kbps: p.bitrate_kbps, bs: Box::default() };
        let params = e.params(p)?;
        e.raw.init(&params)?;
        Ok(e)
    }

    fn params(&self, ep: &EncParams) -> anyhow::Result<SEncParamExt> {
        let (w, h) = (ep.w, ep.h);
        let mut p = SEncParamExt::default();
        let r = vcall!(self.raw, GetDefaultParams, &mut p);
        if r != 0 {
            anyhow::bail!("OpenH264 GetDefaultParams failed ({r})");
        }
        let bps = (ep.bitrate_kbps as c_int).saturating_mul(1000);
        let threads = encoder_threads(ep.threads);
        let screen = match ep.content {
            ContentHint::Screen => true,
            ContentHint::Motion => false,
            ContentHint::Auto => w * h <= 1280 * 720,
        };
        p.iUsageType = if screen { SCREEN_CONTENT_REAL_TIME } else { CAMERA_VIDEO_REAL_TIME };
        p.iPicWidth = w as c_int;
        p.iPicHeight = h as c_int;
        p.iTargetBitrate = bps;
        p.iMaxBitrate = bps.saturating_mul(3) / 2;
        p.iRCMode = RC_BITRATE_MODE;
        p.fMaxFrameRate = ep.fps as f32;
        p.iTemporalLayerNum = 1;
        p.iSpatialLayerNum = 1;
        p.iComplexityMode = LOW_COMPLEXITY;
        p.uiIntraPeriod = ep.fps.saturating_mul(ep.keyframe_interval_s);
        p.iNumRefFrame = 1;
        p.eSpsPpsIdStrategy = CONSTANT_ID;
        p.iEntropyCodingModeFlag = 0; // CAVLC (baseline)
        p.bEnableFrameSkip = true;
        p.bEnableLongTermReference = false;
        p.iMultipleThreadIdc = threads as u16 as _;
        p.iLoopFilterDisableIdc = 0;
        p.bEnableDenoise = false;
        p.bEnableBackgroundDetection = false;
        p.bEnableAdaptiveQuant = false;
        p.bEnableSceneChangeDetect = true;
        let l = &mut p.sSpatialLayers[0];
        l.iVideoWidth = w as c_int;
        l.iVideoHeight = h as c_int;
        l.fFrameRate = ep.fps as f32;
        l.iSpatialBitrate = bps;
        l.iMaxSpatialBitrate = bps.saturating_mul(3) / 2;
        l.uiProfileIdc = PRO_BASELINE;
        l.sSliceArgument.uiSliceMode = SM_FIXEDSLCNUM_SLICE;
        l.sSliceArgument.uiSliceNum = threads as _;
        Ok(p)
    }
}

impl EncBackend for Encoder {
    fn set_bitrate(&mut self, kbps: u32) {
        if kbps == self.bitrate_kbps {
            return;
        }
        self.bitrate_kbps = kbps;
        use openh264_sys2::{SBitrateInfo, ENCODER_OPTION_BITRATE, ENCODER_OPTION_MAX_BITRATE, SPATIAL_LAYER_ALL};
        let bps = (kbps as c_int).saturating_mul(1000);
        let mut max = SBitrateInfo { iLayer: SPATIAL_LAYER_ALL, iBitrate: bps.saturating_mul(3) / 2 };
        let mut tgt = SBitrateInfo { iLayer: SPATIAL_LAYER_ALL, iBitrate: bps };
        // Raise the ceiling first so the target is never above the max.
        let r1 = vcall!(self.raw, SetOption, ENCODER_OPTION_MAX_BITRATE, (&raw mut max).cast());
        let r2 = vcall!(self.raw, SetOption, ENCODER_OPTION_BITRATE, (&raw mut tgt).cast());
        if r1 != 0 || r2 != 0 {
            tracing::warn!("OpenH264 rejected bitrate change to {kbps} kbps ({r1}/{r2})");
        }
    }

    fn hardware(&self) -> bool {
        false
    }

    fn encode(&mut self, yuv: &mut I420Buf, ts_us: u64, force: bool) -> anyhow::Result<Option<(Vec<u8>, bool)>> {
        let (ew, eh) = (yuv.width, yuv.height);
        if force {
            vcall!(self.raw, ForceIntraFrame, true);
        }
        let cw = ew.div_ceil(2);
        let pic = SSourcePicture {
            iColorFormat: videoFormatI420 as c_int,
            iStride: [ew as c_int, cw as c_int, cw as c_int, 0],
            pData: [yuv.y.as_mut_ptr(), yuv.u.as_mut_ptr(), yuv.v.as_mut_ptr(), null_mut()],
            iPicWidth: ew as c_int,
            iPicHeight: eh as c_int,
            uiTimeStamp: (ts_us / 1000) as _,
            bPsnrY: false,
            bPsnrU: false,
            bPsnrV: false,
        };
        let bs: *mut SFrameBSInfo = &mut *self.bs;
        let r = vcall!(self.raw, EncodeFrame, &pic, bs);
        if r != 0 {
            anyhow::bail!("H.264 encode failed (OpenH264 error {r})");
        }
        let info = &*self.bs;
        if info.eFrameType == videoFrameTypeSkip || info.eFrameType == videoFrameTypeInvalid {
            return Ok(None);
        }
        let mut data = Vec::with_capacity(info.iFrameSizeInBytes.max(0) as usize);
        for layer in info.sLayerInfo.iter().take(info.iLayerNum.clamp(0, 128) as usize) {
            if layer.pBsBuf.is_null() || layer.pNalLengthInByte.is_null() {
                continue;
            }
            // SAFETY: OpenH264 guarantees iNalCount entries and that the NALs are
            // stored contiguously in pBsBuf, valid until the next EncodeFrame.
            unsafe {
                let lens = std::slice::from_raw_parts(layer.pNalLengthInByte, layer.iNalCount.max(0) as usize);
                let total: usize = lens.iter().map(|&l| l.max(0) as usize).sum();
                data.extend_from_slice(std::slice::from_raw_parts(layer.pBsBuf, total));
            }
        }
        if data.is_empty() {
            return Ok(None);
        }
        Ok(Some((data, info.eFrameType == videoFrameTypeIDR || info.eFrameType == videoFrameTypeI)))
    }
}

pub(crate) struct Decoder {
    dec: OhDecoder,
}

impl Decoder {
    pub fn new(api: DynamicAPI) -> anyhow::Result<Self> {
        let dec = OhDecoder::with_api_config(api, DecoderConfig::new()).map_err(|e| anyhow!("failed to create OpenH264 decoder: {e}"))?;
        Ok(Self { dec })
    }
}

impl DecBackend for Decoder {
    fn hardware(&self) -> bool {
        false
    }

    fn decode(&mut self, au: &[u8]) -> anyhow::Result<Option<YuvView<'_>>> {
        // size cap before OpenH264 allocates for a new SPS
        check_h264_au(au)?;
        let yuv = match self.dec.decode(au) {
            Ok(Some(y)) => y,
            Ok(None) => return Ok(None),
            Err(e) => return Err(anyhow!("H.264 decode failed: {e}")),
        };
        let (w, h) = yuv.dimensions();
        check_decode_dims(w, h)?;
        let (ys, us, vs) = yuv.strides();
        if us != vs {
            anyhow::bail!("unsupported decoder output: U/V strides differ ({us} vs {vs})");
        }
        let raw = |s: &[u8]| (s.as_ptr(), s.len());
        let ((yp, yl), (up, ul), (vp, vl)) = (raw(yuv.y()), raw(yuv.u()), raw(yuv.v()));
        // SAFETY: the planes live in the decoder's own buffers, which stay valid
        // and unchanged until the next decode call — that needs `&mut self`,
        // which the returned view borrows.
        let (y, u, v) = unsafe { (std::slice::from_raw_parts(yp, yl), std::slice::from_raw_parts(up, ul), std::slice::from_raw_parts(vp, vl)) };
        Ok(Some(YuvView { w, h, y, y_stride: ys, u, v, uv_stride: us, uv_step: 1 }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A peer SPS above the decode cap is refused before OpenH264 allocates.
    #[test]
    fn openh264_rejects_oversized_sps() {
        let mut dec = Decoder::new(source_api()).unwrap();
        // baseline SPS 8192x8192 (512x512 macroblocks) + PPS
        let au = [0, 0, 0, 1, 0x67, 0x42, 0xc0, 0x33, 0xda, 0x00, 0x20, 0x00, 0x04, 0x01, 0x90, 0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80];
        let e = dec.decode(&au).err().expect("oversized SPS accepted");
        assert!(format!("{e:#}").contains("decode limit"), "{e:#}");
    }
}
