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
    LumoraLinks.register(messenger: flutterViewController.engine.binaryMessenger)
    // lumora:// links (CFBundleURLTypes): the "get URL" Apple Event, registered
    // here (before the app finishes launching) so a link that launched Lumora
    // is not lost.
    NSAppleEventManager.shared().setEventHandler(
      self, andSelector: #selector(handleGetURL(_:withReply:)),
      forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))

    super.awakeFromNib()
  }

  @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
    guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
      let url = URL(string: s)
    else { return }
    LumoraLinks.open(url)
    NSApp.activate(ignoringOtherApps: true)
  }
}

/// `lumora/links` (lib/platform/desktop_links.dart): `lumora://add|join|remote/…`
/// opened from another app. `ready` returns the links that came before Dart
/// listened; later ones are sent as `open`. Device-link codes
/// (`lumora://link/…`) are never taken from outside the app.
enum LumoraLinks {
  private static var channel: FlutterMethodChannel?
  private static var ready = false
  private static var queued: [String] = []

  static func register(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "lumora/links", binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      guard call.method == "ready" else {
        result(FlutterMethodNotImplemented)
        return
      }
      ready = true
      let links = queued
      queued = []
      result(links)
    }
    channel = ch
  }

  /// True when the URL is a Lumora link (taken), false otherwise.
  @discardableResult
  static func open(_ url: URL) -> Bool {
    let link = url.absoluteString
    guard url.scheme?.lowercased() == "lumora", link.count <= 4200,
      let host = url.host?.lowercased(), ["add", "join", "remote"].contains(host)
    else { return false }
    if ready, let ch = channel {
      ch.invokeMethod("open", arguments: link)
    } else {
      queued.append(link)
    }
    return true
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
