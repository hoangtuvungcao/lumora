import Accelerate
import CoreMedia
import CoreVideo
import QuartzCore
import ReplayKit
import UIKit

/// ReplayKit Broadcast Upload Extension: the user starts it from the system picker
/// ("Start Broadcast" → Lumora). Runs in its own process with a ~50 MB memory cap, so it
/// only downscales each frame (long side ≤ 960 px, ≤ 15 fps) with vImage, straight into
/// the App Group shared-memory ring (Shared/lumora_ring.h). The Lumora app reads the ring
/// and sends the frames over its existing encrypted connection (LumoraScreenShare.swift).
final class SampleHandler: RPBroadcastSampleHandler {
  private var ring: OpaquePointer?
  private var lastFrame: CFTimeInterval = 0
  private let minInterval: CFTimeInterval = 1.0 / 15.0
  private let maxSide = 960
  private var info = vImage_YpCbCrToARGB()
  private var infoFullRange: Bool?
  private var lumaScratch: UnsafeMutableRawPointer?
  private var chromaScratch: UnsafeMutableRawPointer?

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    guard let path = LumoraShared.screenRingPath, let r = lumora_ring_open(path, 1) else {
      finishBroadcastWithError(
        NSError(domain: "vn.lumora.broadcast", code: 1, userInfo: [NSLocalizedDescriptionKey: "Lumora: shared storage unavailable"]))
      return
    }
    ring = r
    lumaScratch = malloc(maxSide * maxSide)
    chromaScratch = malloc(maxSide * maxSide / 2 + maxSide)
    let b = UIScreen.main.nativeBounds
    lumora_ring_set_state(r, 1 /* LIVE */, UInt32(b.width), UInt32(b.height), Float(UIScreen.main.nativeScale))
    LumoraShared.post(LumoraShared.screenStart)
  }

  override func broadcastFinished() {
    if let r = ring {
      lumora_ring_set_state(r, 0 /* STOPPED */, 0, 0, 1)
      lumora_ring_close(r)
    }
    ring = nil
    free(lumaScratch)
    free(chromaScratch)
    lumaScratch = nil
    chromaScratch = nil
    LumoraShared.post(LumoraShared.screenStop)
  }

  override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
    guard sampleBufferType == .video, let r = ring, let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let now = CACurrentMediaTime()
    if now - lastFrame < minInterval { return }
    lastFrame = now
    autoreleasepool {
      CVPixelBufferLockBaseAddress(px, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
      let sw = CVPixelBufferGetWidth(px)
      let sh = CVPixelBufferGetHeight(px)
      guard sw > 1, sh > 1 else { return }
      let k = min(1.0, Double(maxSide) / Double(max(sw, sh)))
      let dw = max(2, Int(Double(sw) * k) & ~1)
      let dh = max(2, Int(Double(sh) * k) & ~1)
      let stride = dw * 4
      guard let dst = lumora_ring_begin(r, UInt32(dw), UInt32(dh), UInt32(stride), 1 /* BGRA */) else { return }
      var out = vImage_Buffer(data: dst, height: vImagePixelCount(dh), width: vImagePixelCount(dw), rowBytes: stride)
      let ok: Bool
      switch CVPixelBufferGetPixelFormatType(px) {
      case kCVPixelFormatType_32BGRA:
        var src = vImage_Buffer(
          data: CVPixelBufferGetBaseAddress(px), height: vImagePixelCount(sh), width: vImagePixelCount(sw),
          rowBytes: CVPixelBufferGetBytesPerRow(px))
        ok = vImageScale_ARGB8888(&src, &out, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
      case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        ok = nv12(px, sw, sh, &out, dw, dh, fullRange: true)
      case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        ok = nv12(px, sw, sh, &out, dw, dh, fullRange: false)
      default:
        ok = false
      }
      if ok {
        lumora_ring_commit(r, UInt64(now * 1_000_000))
        LumoraShared.post(LumoraShared.screenFrame)
      } else {
        lumora_ring_abort(r)
      }
    }
  }

  /// NV12 → BGRA with the downscale done on the planes first (small scratch buffers).
  private func nv12(_ px: CVPixelBuffer, _ sw: Int, _ sh: Int, _ out: inout vImage_Buffer, _ dw: Int, _ dh: Int, fullRange: Bool) -> Bool {
    guard let luma = lumaScratch, let chroma = chromaScratch,
      let y = CVPixelBufferGetBaseAddressOfPlane(px, 0), let c = CVPixelBufferGetBaseAddressOfPlane(px, 1)
    else { return false }
    if infoFullRange != fullRange {
      var range =
        fullRange
        ? vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255, YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
        : vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
      guard
        vImageConvert_YpCbCrToARGB_GenerateConversion(
          kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &range, &info, kvImage420Yp8_CbCr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
          == kvImageNoError
      else { return false }
      infoFullRange = fullRange
    }
    var srcY = vImage_Buffer(
      data: y, height: vImagePixelCount(sh), width: vImagePixelCount(sw), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(px, 0))
    var srcC = vImage_Buffer(
      data: c, height: vImagePixelCount(sh / 2), width: vImagePixelCount(sw / 2), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(px, 1))
    var dY = vImage_Buffer(data: luma, height: vImagePixelCount(dh), width: vImagePixelCount(dw), rowBytes: dw)
    var dC = vImage_Buffer(data: chroma, height: vImagePixelCount(dh / 2), width: vImagePixelCount(dw / 2), rowBytes: dw)
    guard vImageScale_Planar8(&srcY, &dY, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
      vImageScale_CbCr8(&srcC, &dC, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    else { return false }
    // ARGB → BGRA byte order for the core
    let permute: [UInt8] = [3, 2, 1, 0]
    return vImageConvert_420Yp8_CbCr8ToARGB8888(&dY, &dC, &out, &info, permute, 255, vImage_Flags(kvImageNoFlags)) == kvImageNoError
  }
}
