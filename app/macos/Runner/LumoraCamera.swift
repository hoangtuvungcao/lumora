// Native camera capture for video calls (iOS + macOS), channel "lumora/camera".
//
// THIS FILE EXISTS TWICE and the copies must stay byte-identical (CI runs `cmp`):
//   app/ios/Runner/LumoraCamera.swift
//   app/macos/Runner/LumoraCamera.swift
// Platform differences live behind #if os(iOS) / #if os(macOS).
//
// Frames never touch Dart: AVCaptureVideoDataOutput delivers NV12 (420YpCbCr8BiPlanar)
// buffers that go, without a copy, to the Rust core through lumora_push_camera_yuv. The core
// rotates them upright, converts to I420 and encodes. The connection is never rotated or
// mirrored here: rotation is free in the core, and mirroring is a core / Dart-preview concern.
//
// iOS: lumora_push_camera_yuv comes from the static core (Runner-Bridging-Header.h).
// macOS: the core is liblumora_ffi.dylib loaded by Dart, so the symbol is found with dlsym.

import AVFoundation
import Foundation

#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import Cocoa
  import FlutterMacOS
#endif

final class LumoraCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  static let shared = LumoraCamera()

  #if os(macOS)
    /// C signature of lumora_push_camera_yuv.
    private typealias PushYUV = @convention(c) (
      UInt32, UInt32,
      UnsafePointer<UInt8>?, UInt32,
      UnsafePointer<UInt8>?, UInt32,
      UnsafePointer<UInt8>?, UInt32,
      UInt32, UInt32
    ) -> Int32
    /// Set once on the session queue before the first session starts, never cleared.
    private var pushYUV: PushYUV?
  #endif

  private var channel: FlutterMethodChannel?  // main thread
  private let sessionQueue = DispatchQueue(label: "vn.lumora.camera.session")
  private let frameQueue = DispatchQueue(label: "vn.lumora.camera.frames", qos: .userInteractive)

  // Session state, sessionQueue only.
  private var session: AVCaptureSession?
  private var input: AVCaptureDeviceInput?
  private var output: AVCaptureVideoDataOutput?
  private var observers: [NSObjectProtocol] = []
  private var wantSize = 1280
  private var wantFps = 30
  private var resetRetried = false

  // Read by the frame queue for every frame.
  private let lock = NSLock()
  private var frontActive = true
  private var orientationRaw = 1  // UIDeviceOrientation.portrait

  #if os(iOS)
    private var orientationObserver: NSObjectProtocol?  // main thread
  #endif

  static func register(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "lumora/camera", binaryMessenger: messenger)
    shared.channel = ch
    ch.setMethodCallHandler { call, result in
      shared.handle(call, result)
    }
  }

  // MARK: - Method channel (main thread)

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "supported":
      sessionQueue.async {
        let any = !LumoraCamera.devices().isEmpty
        DispatchQueue.main.async { result(any) }
      }
    case "permission":
      result(LumoraCamera.permission())
    case "request":
      AVCaptureDevice.requestAccess(for: .video) { _ in
        DispatchQueue.main.async { result(LumoraCamera.permission()) }
      }
    case "start":
      start(args, result)
    case "stop":
      #if os(iOS)
        endOrientation()
      #endif
      sessionQueue.async {
        self.teardown()
        DispatchQueue.main.async { result(nil) }
      }
    case "switch":
      sessionQueue.async {
        let reply = self.switchCamera()
        DispatchQueue.main.async { result(reply) }
      }
    case "openSettings":
      openSettings(result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func permission() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return "granted"
    case .notDetermined: return "undetermined"
    // Neither iOS nor macOS shows the prompt again: only Settings can change it.
    case .denied, .restricted: return "blocked"
    @unknown default: return "blocked"
    }
  }

  private func start(_ args: [String: Any], _ result: @escaping FlutterResult) {
    let facing = (args["facing"] as? String) == "back" ? "back" : "front"
    let lib = args["lib"] as? String
    let width = args["width"] as? Int ?? 1280
    let height = args["height"] as? Int ?? 720
    let fps = args["fps"] as? Int ?? 30
    let run = {
      #if os(iOS)
        self.beginOrientation()
      #endif
      self.sessionQueue.async {
        let reply = self.configure(facing: facing, lib: lib, size: max(width, height), fps: fps)
        DispatchQueue.main.async {
          #if os(iOS)
            if (reply["ok"] as? Bool) != true { self.endOrientation() }
          #endif
          result(reply)
        }
      }
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      run()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          if granted { run() } else { result(self.failure("permission")) }
        }
      }
    default:
      result(failure("permission"))
    }
  }

  private func openSettings(_ result: @escaping FlutterResult) {
    #if os(iOS)
      guard let url = URL(string: UIApplication.openSettingsURLString) else {
        result(false)
        return
      }
      UIApplication.shared.open(url, options: [:]) { ok in result(ok) }
    #else
      guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else {
        result(false)
        return
      }
      result(NSWorkspace.shared.open(url))
    #endif
  }

  private func failure(_ code: String, _ cameras: Int = 0) -> [String: Any] {
    return ["ok": false, "error": code, "facing": isFront() ? "front" : "back", "cameras": cameras]
  }

  private func success(_ cameras: Int) -> [String: Any] {
    let side = input.map { LumoraCamera.facing(of: $0.device) } ?? (isFront() ? "front" : "back")
    return ["ok": true, "facing": side, "cameras": cameras]
  }

  // MARK: - Session (sessionQueue)

  private func configure(facing: String, lib: String?, size: Int, fps: Int) -> [String: Any] {
    #if os(macOS)
      if pushYUV == nil { pushYUV = LumoraCamera.resolvePush(lib: lib) }
      if pushYUV == nil { return failure("failed") }
    #endif
    let all = LumoraCamera.devices()
    guard !all.isEmpty else { return failure("no_camera") }
    wantSize = size
    wantFps = fps

    // Already capturing (e.g. a second call): keep the session, just honour `facing`.
    if let s = session, s.isRunning, let cur = input?.device {
      if LumoraCamera.facing(of: cur) != facing,
        let next = LumoraCamera.pick(facing: facing, in: all), next.uniqueID != cur.uniqueID
      {
        _ = replaceInput(with: next)
      }
      return success(all.count)
    }

    teardown()
    guard let device = LumoraCamera.pick(facing: facing, in: all) else { return failure("no_camera", all.count) }
    let devInput: AVCaptureDeviceInput
    do {
      devInput = try AVCaptureDeviceInput(device: device)
    } catch {
      return failure(LumoraCamera.errorCode(error as NSError), all.count)
    }

    let out = AVCaptureVideoDataOutput()
    let full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    let video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let formats = out.availableVideoPixelFormatTypes
    let pixelFormat = formats.contains(full) || !formats.contains(video) ? full : video
    out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
    out.alwaysDiscardsLateVideoFrames = true
    out.setSampleBufferDelegate(self, queue: frameQueue)

    let s = AVCaptureSession()
    s.beginConfiguration()
    guard s.canAddInput(devInput) else {
      s.commitConfiguration()
      return failure("busy", all.count)
    }
    s.addInput(devInput)
    applyPreset(s)
    guard s.canAddOutput(out) else {
      s.removeInput(devInput)
      s.commitConfiguration()
      return failure("failed", all.count)
    }
    s.addOutput(out)
    #if os(iOS)
      // iPad Stage Manager / Split View: keep the camera while another app is in front.
      if #available(iOS 16.0, *), s.isMultitaskingCameraAccessSupported {
        s.isMultitaskingCameraAccessEnabled = true
      }
    #endif
    s.commitConfiguration()

    session = s
    input = devInput
    output = out
    resetRetried = false
    fixConnection(out)
    // After commit: adding the input / setting the preset resets the frame durations.
    setFrameRate(device)
    setFront(LumoraCamera.facing(of: device) == "front")
    observe(s)

    s.startRunning()
    #if os(iOS)
      // Interrupted right away (e.g. another app holds the camera): the session resumes by
      // itself when the interruption ends, and Dart already got onError("interrupted").
      let running = s.isRunning || s.isInterrupted
    #else
      let running = s.isRunning
    #endif
    guard running else {
      teardown()
      return failure("busy", all.count)
    }
    return success(all.count)
  }

  /// Stops the session and releases the device (camera light off). Idempotent.
  private func teardown() {
    for o in observers { NotificationCenter.default.removeObserver(o) }
    observers.removeAll()
    guard let s = session else { return }
    s.stopRunning()
    s.beginConfiguration()
    for i in s.inputs { s.removeInput(i) }
    for o in s.outputs { s.removeOutput(o) }
    s.commitConfiguration()
    output?.setSampleBufferDelegate(nil, queue: nil)
    session = nil
    input = nil
    output = nil
  }

  private func switchCamera() -> [String: Any] {
    let all = LumoraCamera.devices()
    guard session != nil, let cur = input?.device else {
      return ["facing": isFront() ? "front" : "back", "cameras": all.count]
    }
    #if os(iOS)
      let next = LumoraCamera.pick(facing: LumoraCamera.facing(of: cur) == "front" ? "back" : "front", in: all)
    #else
      // macOS: cycle through every camera (built-in, USB, Continuity Camera).
      let i = all.firstIndex(where: { $0.uniqueID == cur.uniqueID }) ?? -1
      let next: AVCaptureDevice? = all.isEmpty ? nil : all[(i + 1) % all.count]
    #endif
    if let next = next, next.uniqueID != cur.uniqueID {
      _ = replaceInput(with: next)
    }
    let now = input?.device ?? cur
    return ["facing": LumoraCamera.facing(of: now), "cameras": all.count]
  }

  /// Swaps the camera of the running session; keeps the old one if the new one fails.
  private func replaceInput(with device: AVCaptureDevice) -> Bool {
    guard let s = session, let old = input else { return false }
    let new: AVCaptureDeviceInput
    do {
      new = try AVCaptureDeviceInput(device: device)
    } catch {
      return false
    }
    s.beginConfiguration()
    s.removeInput(old)
    var swapped = false
    if s.canAddInput(new) {
      s.addInput(new)
      swapped = true
    } else if s.canAddInput(old) {
      s.addInput(old)
    }
    applyPreset(s)
    s.commitConfiguration()
    if swapped { input = new }
    if let out = output { fixConnection(out) }
    if let d = input?.device {
      setFrameRate(d)
      setFront(LumoraCamera.facing(of: d) == "front")
    }
    return swapped
  }

  private func applyPreset(_ s: AVCaptureSession) {
    let presets: [AVCaptureSession.Preset] =
      wantSize >= 1280 ? [.hd1280x720, .vga640x480, .high] : [.vga640x480, .hd1280x720, .high]
    for p in presets where s.canSetSessionPreset(p) {
      if s.sessionPreset != p { s.sessionPreset = p }
      return
    }
  }

  /// Raw sensor orientation, never mirrored (see the header).
  private func fixConnection(_ out: AVCaptureVideoDataOutput) {
    guard let c = out.connection(with: .video), c.isVideoMirroringSupported else { return }
    c.automaticallyAdjustsVideoMirroring = false
    c.isVideoMirrored = false
  }

  /// Fixed frame rate when the active format allows it (clamped to the format's exact range;
  /// an out-of-range value would raise an Objective-C exception).
  private func setFrameRate(_ device: AVCaptureDevice) {
    guard wantFps > 0 else { return }
    let want = Double(wantFps)
    guard
      let range = device.activeFormat.videoSupportedFrameRateRanges.first(where: {
        $0.minFrameRate <= want + 0.5 && want - 0.5 <= $0.maxFrameRate
      })
    else { return }
    var d = CMTime(value: 1, timescale: CMTimeScale(wantFps))
    d = CMTimeMaximum(d, range.minFrameDuration)
    d = CMTimeMinimum(d, range.maxFrameDuration)
    do {
      try device.lockForConfiguration()
      device.activeVideoMinFrameDuration = d
      device.activeVideoMaxFrameDuration = d
      device.unlockForConfiguration()
    } catch {}
  }

  /// Every usable camera; on macOS built-in first.
  private static func devices() -> [AVCaptureDevice] {
    var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
    #if os(macOS)
      // USB webcams and Continuity Camera (an iPhone) are "external".
      if #available(macOS 14.0, *) {
        types.append(.external)
      } else {
        types.append(.externalUnknown)
      }
    #endif
    let found = AVCaptureDevice.DiscoverySession(
      deviceTypes: types, mediaType: .video, position: .unspecified
    ).devices
    if found.isEmpty, let d = AVCaptureDevice.default(for: .video) { return [d] }
    #if os(macOS)
      return found.filter { $0.deviceType == .builtInWideAngleCamera }
        + found.filter { $0.deviceType != .builtInWideAngleCamera }
    #else
      return found
    #endif
  }

  private static func pick(facing: String, in all: [AVCaptureDevice]) -> AVCaptureDevice? {
    return all.first(where: { LumoraCamera.facing(of: $0) == facing }) ?? all.first
  }

  /// iOS: the camera's side. macOS: the built-in camera is "front", any other is "back".
  private static func facing(of d: AVCaptureDevice) -> String {
    #if os(iOS)
      return d.position == .back ? "back" : "front"
    #else
      return d.deviceType == .builtInWideAngleCamera ? "front" : "back"
    #endif
  }

  /// AVFoundation error codes (raw values: some AVError cases are platform-limited).
  private static func errorCode(_ e: NSError) -> String {
    switch e.code {
    case -11852: return "permission"  // applicationIsNotAuthorizedToUseDevice
    case -11804, -11815: return "busy"  // deviceAlreadyUsedByAnotherSession, deviceInUseByAnotherApplication
    case -11814: return "no_camera"  // deviceNotConnected
    default: return "failed"
    }
  }

  // MARK: - Session events

  // Names as strings: they are the constants' values and compile against every SDK
  // (newer SDKs moved the Swift names, e.g. AVCaptureSession.runtimeErrorNotification).
  private static let runtimeError = Notification.Name("AVCaptureSessionRuntimeErrorNotification")
  private static let wasInterrupted = Notification.Name("AVCaptureSessionWasInterruptedNotification")
  private static let interruptionEnded = Notification.Name("AVCaptureSessionInterruptionEndedNotification")
  private static let deviceDisconnected = Notification.Name("AVCaptureDeviceWasDisconnectedNotification")

  private func observe(_ s: AVCaptureSession) {
    let nc = NotificationCenter.default
    observers.append(
      nc.addObserver(forName: LumoraCamera.runtimeError, object: s, queue: nil) { [weak self] note in
        let err = note.userInfo?["AVCaptureSessionErrorKey"] as? NSError
        self?.sessionQueue.async { self?.onRuntimeError(err, s) }
      })
    observers.append(
      nc.addObserver(forName: LumoraCamera.deviceDisconnected, object: nil, queue: nil) { [weak self] note in
        guard let gone = (note.object as? AVCaptureDevice)?.uniqueID else { return }
        self?.sessionQueue.async {
          guard let self = self, self.session === s, self.input?.device.uniqueID == gone else { return }
          self.report("disconnected", "camera disconnected")
        }
      })
    #if os(iOS)
      observers.append(
        nc.addObserver(forName: LumoraCamera.wasInterrupted, object: s, queue: nil) { [weak self] note in
          let reason = note.userInfo?["AVCaptureSessionInterruptionReasonKey"] as? Int ?? 0
          let message: String
          switch reason {  // AVCaptureSession.InterruptionReason raw values
          case 1: message = "videoDeviceNotAvailableInBackground"
          case 2: message = "audioDeviceInUseByAnotherClient"
          case 3: message = "videoDeviceInUseByAnotherClient"
          case 4: message = "videoDeviceNotAvailableWithMultipleForegroundApps"
          case 5: message = "videoDeviceNotAvailableDueToSystemPressure"
          default: message = "interrupted (\(reason))"
          }
          self?.report("interrupted", message)
        })
      observers.append(
        nc.addObserver(forName: LumoraCamera.interruptionEnded, object: s, queue: nil) { [weak self] _ in
          DispatchQueue.main.async {
            self?.channel?.invokeMethod("onInterruptionEnded", arguments: [String: Any]())
          }
        })
    #endif
  }

  private func onRuntimeError(_ err: NSError?, _ s: AVCaptureSession) {
    guard session === s else { return }
    // mediaServicesWereReset (-11819): the media server restarted; restarting the same
    // session is Apple's documented recovery. Once per start.
    if err?.code == -11819, !resetRetried {
      resetRetried = true
      s.startRunning()
      if s.isRunning { return }
    }
    let code = err.map { LumoraCamera.errorCode($0) == "permission" ? "permission" : "failed" } ?? "failed"
    report(code, err?.localizedDescription ?? "capture session error")
  }

  private func report(_ code: String, _ message: String) {
    DispatchQueue.main.async {
      self.channel?.invokeMethod("onError", arguments: ["code": code, "message": message])
    }
  }

  // MARK: - Orientation

  private func setFront(_ front: Bool) {
    lock.lock()
    frontActive = front
    lock.unlock()
  }

  private func isFront() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return frontActive
  }

  /// Clockwise degrees that make the buffer upright (as WebRTC's RTCCameraVideoCapturer).
  /// iOS buffers come in the sensor's landscape orientation; macOS ones are already upright.
  private func rotation() -> UInt32 {
    #if os(iOS)
      lock.lock()
      let o = orientationRaw
      let front = frontActive
      lock.unlock()
      switch UIDeviceOrientation(rawValue: o) {
      case .portraitUpsideDown?: return 270
      case .landscapeLeft?: return front ? 180 : 0
      case .landscapeRight?: return front ? 0 : 180
      default: return 90  // portrait
      }
    #else
      return 0
    #endif
  }

  #if os(iOS)
    /// Physical device orientation (not the UI's: the app may be locked to portrait).
    private func beginOrientation() {
      guard orientationObserver == nil else { return }
      let device = UIDevice.current
      device.beginGeneratingDeviceOrientationNotifications()
      if !setOrientation(device.orientation) {
        // Unknown / face up at start: derive it from the interface orientation.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        switch scene?.interfaceOrientation {
        case .portraitUpsideDown?: _ = setOrientation(.portraitUpsideDown)
        // UIInterfaceOrientation.landscapeLeft == UIDeviceOrientation.landscapeRight.
        case .landscapeLeft?: _ = setOrientation(.landscapeRight)
        case .landscapeRight?: _ = setOrientation(.landscapeLeft)
        case .portrait?: _ = setOrientation(.portrait)
        default: break  // keep the last valid value
        }
      }
      orientationObserver = NotificationCenter.default.addObserver(
        forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        _ = self?.setOrientation(UIDevice.current.orientation)
      }
    }

    private func endOrientation() {
      guard let o = orientationObserver else { return }
      NotificationCenter.default.removeObserver(o)
      orientationObserver = nil
      UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    /// Ignores faceUp / faceDown / unknown (keeps the last valid value).
    @discardableResult
    private func setOrientation(_ o: UIDeviceOrientation) -> Bool {
      switch o {
      case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
        lock.lock()
        orientationRaw = o.rawValue
        lock.unlock()
        return true
      default:
        return false
      }
    }
  #endif

  #if os(macOS)
    /// lumora_push_camera_yuv from the core dylib Dart loaded (`lib`), else from any loaded
    /// image, else from the app bundle's Frameworks folder.
    private static func resolvePush(lib: String?) -> PushYUV? {
      let name = "lumora_push_camera_yuv"
      var paths: [String] = []
      if let lib = lib, !lib.isEmpty { paths.append(lib) }
      for path in paths {
        if let h = dlopen(path, RTLD_NOW), let sym = dlsym(h, name) {
          return unsafeBitCast(sym, to: PushYUV.self)
        }
      }
      // RTLD_DEFAULT is ((void *)-2), a macro Swift cannot import.
      if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
        return unsafeBitCast(sym, to: PushYUV.self)
      }
      if let dir = Bundle.main.privateFrameworksPath,
        let h = dlopen(dir + "/liblumora_ffi.dylib", RTLD_NOW), let sym = dlsym(h, name)
      {
        return unsafeBitCast(sym, to: PushYUV.self)
      }
      return nil
    }
  #endif

  // MARK: - Frames (frameQueue)

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let format = CVPixelBufferGetPixelFormatType(pb)
    guard
      format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      CVPixelBufferGetPlaneCount(pb) >= 2
    else { return }
    #if os(macOS)
      guard let push = pushYUV else { return }
    #endif
    // 0x10000 = LUMORA_CAMERA_FULL_RANGE: the core maps 0..255 levels to video range.
    let rot = rotation() | (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 0x10000 : 0)
    guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return }
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
      let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)
    else { return }
    let w = UInt32(CVPixelBufferGetWidthOfPlane(pb, 0))
    let h = UInt32(CVPixelBufferGetHeightOfPlane(pb, 0))
    let yStride = UInt32(CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
    let uvStride = UInt32(CVPixelBufferGetBytesPerRowOfPlane(pb, 1))
    let y = UnsafePointer<UInt8>(yBase.assumingMemoryBound(to: UInt8.self))
    let uv = UnsafePointer<UInt8>(uvBase.assumingMemoryBound(to: UInt8.self))
    // NV12: U = CbCr base, V = base + 1, 2 bytes per chroma pixel.
    #if os(iOS)
      _ = lumora_push_camera_yuv(w, h, y, yStride, uv, uvStride, uv + 1, uvStride, 2, rot)
    #else
      _ = push(w, h, y, yStride, uv, uvStride, uv + 1, uvStride, 2, rot)
    #endif
  }
}
