import AVFoundation
import Flutter
import ImageIO
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Before Flutter or the core touch it: the identity and database stay on this device.
    LumoraStorage.excludeDataFromBackup()
    GeneratedPluginRegistrant.register(with: self)
    if let r = self.registrar(forPlugin: "LumoraAudioSession") {
      LumoraAudioSession.register(messenger: r.messenger())
    }
    if let r = self.registrar(forPlugin: "LumoraBonjour") {
      LumoraBonjour.register(messenger: r.messenger())
    }
    if let r = self.registrar(forPlugin: "LumoraPush") {
      LumoraPush.register(messenger: r.messenger())
    }
    if let r = self.registrar(forPlugin: "LumoraScreenShare") {
      LumoraScreenShare.register(messenger: r.messenger())
    }
    if let r = self.registrar(forPlugin: "LumoraCamera") {
      LumoraCamera.register(messenger: r.messenger())
    }
    // PushKit needs its delegate before iOS delivers a VoIP push to a just-launched app.
    LumoraPush.shared.onLaunch()
    if let r = self.registrar(forPlugin: "LumoraPhotos") {
      LumoraPhotos.register(messenger: r.messenger())
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    LumoraPush.shared.didRegister(deviceToken: deviceToken)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }
}

/// Lumora's data folder (identity keys, database, received files) never goes into
/// iCloud / iTunes backups: a restored backup on another phone would clone the
/// identity, and the keys must not leave the device. path_provider's
/// getApplicationSupportDirectory (lib/main.dart) is Library/Application Support on
/// iOS; excluding the folder excludes everything in it. Re-applied at every launch
/// (the flag is per item and is lost if the folder is ever recreated).
enum LumoraStorage {
  static func excludeDataFromBackup() {
    let fm = FileManager.default
    guard var url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    do {
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try url.setResourceValues(values)
    } catch {
      NSLog("Lumora: could not exclude %@ from backups: %@", url.path, error.localizedDescription)
    }
  }
}

/// Call audio session (see lib/platform/apple_audio.dart). The Rust core records and
/// plays through RemoteIO itself; iOS only lets it record once the session is
/// play-and-record. `.voiceChat` / `.videoChat` turn on Apple's voice processing
/// (echo cancellation, gain control); voice calls use the earpiece, video calls the
/// loudspeaker (headphones, Bluetooth and CarPlay always win).
///
/// For a call answered through CallKit (LumoraPush), CallKit activates and deactivates
/// the session itself: we only set the category before it does
/// (`callKitAnswered`) and fix mode and route once it is active (`callKitActivated`).
/// Activating it ourselves there would fail on the lock screen.
enum LumoraAudioSession {
  private static var video = false
  private static var callKitActive = false

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "vn.lumora/audio_session", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let session = AVAudioSession.sharedInstance()
      do {
        switch call.method {
        case "startCall":
          let video = ((call.arguments as? [String: Any])?["video"] as? Bool) ?? false
          LumoraAudioSession.video = video || LumoraPush.shared.answeredVideo
          try LumoraAudioSession.configure()
          if LumoraPush.shared.ownsAudioSession {
            if LumoraAudioSession.callKitActive { LumoraAudioSession.applyRoute() }  // else callKitActivated() does it
          } else {
            try session.setActive(true)
            LumoraAudioSession.applyRoute()
          }
          result(nil)
        case "endCall":
          // A CallKit call deactivates the session when it ends (callKitDeactivated).
          if !LumoraPush.shared.ownsAudioSession && !LumoraAudioSession.callKitActive {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
          }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "audio_session", message: error.localizedDescription, details: nil))
      }
    }
  }

  private static func configure() throws {
    var options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP]
    if video { options.insert(.defaultToSpeaker) }
    try AVAudioSession.sharedInstance().setCategory(
      .playAndRecord, mode: video ? .videoChat : .voiceChat, options: options)
  }

  /// Video: loudspeaker instead of the earpiece (only when the earpiece is the route,
  /// so headphones and Bluetooth keep the sound). Voice: no override (earpiece/headset).
  private static func applyRoute() {
    let session = AVAudioSession.sharedInstance()
    if video {
      if session.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {
        try? session.overrideOutputAudioPort(.speaker)
      }
    } else {
      try? session.overrideOutputAudioPort(.none)
    }
  }

  /// CallKit "Answer": category + mode before CallKit activates the session.
  static func callKitAnswered(video v: Bool) {
    video = v
    try? configure()
  }

  /// CallKit activated the session; CallKit may have reset the mode, so set it again.
  static func callKitActivated() {
    callKitActive = true
    try? configure()
    applyRoute()
  }

  static func callKitDeactivated() {
    callKitActive = false
  }
}

/// "Lưu về máy" for photos (lib/ui/media_editor/photo_io.dart): adds a new
/// asset to the Photos library with add-only access
/// (NSPhotoLibraryAddUsageDescription), never reading the user's library.
enum LumoraPhotos {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "lumora/media", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      if call.method == "heicToJpeg" {
        let args = call.arguments as? [String: Any]
        let path = args?["path"] as? String ?? ""
        let maxSide = args?["maxSide"] as? Int ?? 0
        DispatchQueue.global(qos: .userInitiated).async {
          let jpeg = LumoraPhotos.jpegData(path: path, maxSide: maxSide)
          DispatchQueue.main.async { result(jpeg.map { FlutterStandardTypedData(bytes: $0) }) }
        }
        return
      }
      guard call.method == "saveToGallery",
        let args = call.arguments as? [String: Any],
        let data = (args["bytes"] as? FlutterStandardTypedData)?.data
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      let name = args["name"] as? String
      let save = {
        var localId: String?
        PHPhotoLibrary.shared().performChanges({
          let request = PHAssetCreationRequest.forAsset()
          let options = PHAssetResourceCreationOptions()
          options.originalFilename = name
          request.addResource(with: .photo, data: data, options: options)
          localId = request.placeholderForCreatedAsset?.localIdentifier
        }) { ok, error in
          DispatchQueue.main.async {
            if ok {
              result(localId ?? "photos")
            } else {
              result(FlutterError(code: "save_failed", message: error?.localizedDescription ?? "Photos refused the image", details: nil))
            }
          }
        }
      }
      let denied = {
        DispatchQueue.main.async {
          result(FlutterError(code: "denied", message: "Photos access was not allowed", details: nil))
        }
      }
      if #available(iOS 14, *) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
          if status == .authorized || status == .limited { save() } else { denied() }
        }
      } else {
        PHPhotoLibrary.requestAuthorization { status in
          if status == .authorized { save() } else { denied() }
        }
      }
    }
  }

  /// Any ImageIO-readable photo (HEIC included) → JPEG q0.92 with the
  /// orientation applied and no metadata (no GPS). nil if unreadable.
  static func jpegData(path: String, maxSide: Int) -> Data? {
    guard !path.isEmpty,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
    else { return nil }
    var side = maxSide
    if side <= 0,
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let w = props[kCGImagePropertyPixelWidth] as? Int,
      let h = props[kCGImagePropertyPixelHeight] as? Int
    {
      side = max(w, h)
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(side, 1),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    return CGImageDestinationFinalize(dest) ? data as Data : nil
  }
}
