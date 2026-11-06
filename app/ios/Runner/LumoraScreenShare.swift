import Flutter
import ReplayKit
import UIKit

/// Receives the iPhone screen from the ReplayKit Broadcast Upload Extension
/// (LumoraBroadcast/SampleHandler.swift) and feeds it to the Rust core, which encodes and
/// sends it like any other screen (`lumora_media::open_capturer` → external frames on iOS).
///
/// Why a shared-memory ring and not the core inside the extension: the extension is a
/// separate process capped at ~50 MB; the core (QUIC, SQLCipher, H.264, tokio) plus its
/// connections would not fit reliably, and a second copy of the core would hold a second
/// identity/connection. The extension therefore only downscales frames (vImage, ≤ 960 px)
/// into `screen.ring` in the App Group; the app – kept alive by the active session's audio –
/// copies the newest frame out and hands it to the core.
final class LumoraScreenShare {
  static let shared = LumoraScreenShare()

  private let queue = DispatchQueue(label: "vn.lumora.screen")
  private var ring: OpaquePointer?
  private var buffer = [UInt8](repeating: 0, count: 960 * 960 * 4)  // LUMORA_RING_SLOT_BYTES
  private var lastSeq: UInt64 = 0
  private var observing = false

  static func register(messenger: FlutterBinaryMessenger) {
    shared.observe()
    let ch = FlutterMethodChannel(name: "vn.lumora/screen_broadcast", binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "showPicker":
        shared.showPicker()
        result(nil)
      case "status":
        result(["live": shared.ring != nil])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func observe() {
    guard !observing else { return }
    observing = true
    let center = CFNotificationCenterGetDarwinNotifyCenter()
    let me = Unmanaged.passUnretained(self).toOpaque()
    for name in [LumoraShared.screenStart, LumoraShared.screenFrame, LumoraShared.screenStop] {
      CFNotificationCenterAddObserver(
        center, me,
        { _, observer, name, _, _ in
          guard let observer, let name else { return }
          let s = Unmanaged<LumoraScreenShare>.fromOpaque(observer).takeUnretainedValue()
          s.onNote(name.rawValue as String)
        }, name as CFString, nil, .deliverImmediately)
    }
  }

  private func onNote(_ name: String) {
    queue.async { [self] in
      switch name {
      case LumoraShared.screenStart:
        openRing()
      case LumoraShared.screenFrame:
        if ring == nil { openRing() }
        pump()
      case LumoraShared.screenStop:
        lumora_clear_screen_frames()
        if let r = ring { lumora_ring_close(r) }
        ring = nil
      default:
        break
      }
    }
  }

  private func openRing() {
    guard ring == nil, let path = LumoraShared.screenRingPath else { return }
    ring = lumora_ring_open(path, 0)
    guard let r = ring else { return }
    var w: UInt32 = 0
    var h: UInt32 = 0
    var scale: Float = 1
    _ = lumora_ring_state(r, &w, &h, &scale)
    if w > 0, h > 0 { lumora_set_screen_display(w, h, scale) }
  }

  private func pump() {
    guard let r = ring else { return }
    var w: UInt32 = 0
    var h: UInt32 = 0
    var stride: UInt32 = 0
    var format: UInt32 = 0
    var ts: UInt64 = 0
    let n = buffer.withUnsafeMutableBufferPointer { b in
      lumora_ring_read(r, &lastSeq, b.baseAddress, b.count, &w, &h, &stride, &format, &ts)
    }
    guard n > 0 else { return }
    _ = buffer.withUnsafeBufferPointer { b in
      lumora_push_screen_frame(w, h, stride, format, b.baseAddress, Int(n))
    }
  }

  /// iOS only starts a system-wide broadcast from its own picker; tap it programmatically
  /// with Lumora's extension preselected.
  func showPicker() {
    DispatchQueue.main.async {
      let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
      picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "vn.lumora.lumora") + ".ScreenBroadcast"
      picker.showsMicrophoneButton = false
      picker.alpha = 0.01
      guard
        let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow) })
          .first ?? UIApplication.shared.windows.first
      else { return }
      window.addSubview(picker)
      for case let button as UIButton in picker.subviews {
        button.sendActions(for: .allTouchEvents)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { picker.removeFromSuperview() }
    }
  }
}
