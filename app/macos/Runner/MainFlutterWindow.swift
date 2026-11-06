import Cocoa
import FlutterMacOS
import ImageIO

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    LumoraStorage.excludeDataFromBackup()  // before Flutter or the core touch it
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    LumoraMedia.register(messenger: flutterViewController.engine.binaryMessenger)
    LumoraCamera.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// Lumora's data folder (identity keys, database, received files) stays out of
/// Time Machine and other backups that honour the exclusion flag: restoring it
/// on another Mac would clone the identity. path_provider's
/// getApplicationSupportDirectory (lib/main.dart) is
/// ~/Library/Application Support/<bundle id> (inside the sandbox container when
/// sandboxed). Re-applied at every launch.
enum LumoraStorage {
  static func excludeDataFromBackup() {
    let fm = FileManager.default
    guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
      let bundleId = Bundle.main.bundleIdentifier
    else { return }
    var url = base.appendingPathComponent(bundleId, isDirectory: true)
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

/// `lumora/media.heicToJpeg`: HEIC/HEIF (iPhone photos) → JPEG through
/// ImageIO, for the chat viewer and the photo editor (lib/ui/media_editor/heic.dart).
enum LumoraMedia {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "lumora/media", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "heicToJpeg" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any]
      let path = args?["path"] as? String ?? ""
      let maxSide = args?["maxSide"] as? Int ?? 0
      DispatchQueue.global(qos: .userInitiated).async {
        let jpeg = jpegData(path: path, maxSide: maxSide)
        DispatchQueue.main.async { result(jpeg.map { FlutterStandardTypedData(bytes: $0) }) }
      }
    }
  }

  /// Orientation applied, no metadata copied (no GPS). nil if unreadable.
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
