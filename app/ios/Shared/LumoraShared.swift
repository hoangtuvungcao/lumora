import CryptoKit
import Foundation
import Security

/// Code shared by the Lumora app and its extensions (Notification Service, Screen Broadcast).
enum LumoraShared {
  /// App Group container shared by the app and both extensions.
  static let appGroup = "group.vn.lumora.lumora"

  static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
  static var containerURL: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
  }
  /// Shared-memory frame ring (Shared/lumora_ring.h) written by the broadcast extension.
  static var screenRingPath: String? { containerURL?.appendingPathComponent("screen.ring").path }

  // Darwin notifications between the broadcast extension and the app.
  static let screenStart = "vn.lumora.screen.start"
  static let screenFrame = "vn.lumora.screen.frame"
  static let screenStop = "vn.lumora.screen.stop"

  static func post(_ name: String) {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
  }

  /// "Show content in notifications" (Settings › Notifications), written by the app.
  static var hideContent: Bool { defaults?.bool(forKey: "hide_content") ?? false }

  // MARK: - locked chats

  /// Locked chats (Settings › Privacy › Lock chats) as salted SHA-256 hashes, so the
  /// shared defaults do not list who the user hides. Written by the app
  /// (`setLockedConvs`), read here before Dart runs (PushKit, notification extension).
  static func setLockedConvs(_ convs: [String]) {
    let hashes = Array(Set(convs.filter { !$0.isEmpty }.map(lockHash))).sorted()
    if hashes.isEmpty {
      defaults?.removeObject(forKey: "locked_convs")
    } else {
      defaults?.set(hashes, forKey: "locked_convs")
    }
  }

  /// True if the push's conversation is a locked chat: its name and preview must not
  /// show outside the app. Without a conv (old senders) the sender's direct chat counts.
  static func isLocked(conv: String?, from: String?) -> Bool {
    guard let list = defaults?.stringArray(forKey: "locked_convs"), !list.isEmpty else { return false }
    var key = conv ?? ""
    if key.isEmpty, let f = from, !f.isEmpty { key = "d:" + f }
    return !key.isEmpty && list.contains(lockHash(key))
  }

  private static func lockHash(_ conv: String) -> String {
    SHA256.hash(data: Data(("lumora-locked-chat:" + conv).utf8)).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - notification key (X25519)

  /// Keychain access group shared with the notification extension
  /// (`$(AppIdentifierPrefix)vn.lumora.lumora.shared`, resolved in Info.plist).
  private static var keychainGroup: String? {
    guard let g = Bundle.main.object(forInfoDictionaryKey: "LumoraKeychainGroup") as? String,
      !g.isEmpty, !g.hasPrefix("$(")
    else { return nil }
    return g
  }

  private static func keyQuery() -> [String: Any] {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "vn.lumora.lumora.notify",
      kSecAttrAccount as String: "x25519",
    ]
    if let g = keychainGroup { q[kSecAttrAccessGroup as String] = g }
    return q
  }

  /// The private key senders seal notification previews to. Never leaves this device.
  static func notifyKey(create: Bool) -> Curve25519.KeyAgreement.PrivateKey? {
    var q = keyQuery()
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
      let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: d)
    {
      return k
    }
    guard create else { return nil }
    let k = Curve25519.KeyAgreement.PrivateKey()
    var add = keyQuery()
    add[kSecValueData as String] = k.rawRepresentation
    // readable by the extension while the phone is locked (after the first unlock)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemDelete(keyQuery() as CFDictionary)
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
    return k
  }

  // MARK: - opening what lumora_push::seal_notify sealed

  struct Notify: Decodable {
    let k: String
    let from: String
    let name: String?
    let preview: String?
    let conv: String?
    let call: String?
    let video: Bool?
    /// Unix milliseconds when the sender sealed it.
    let t: Double?
  }

  /// `eph_pub(32) || nonce(12) || ciphertext || tag(16)`;
  /// key = HKDF-SHA256(X25519(secret, eph), salt: eph || my_pub, info: "lumora-push notify v1").
  static func openNotify(_ blob: Data, key: Curve25519.KeyAgreement.PrivateKey) -> Notify? {
    let bytes = [UInt8](blob)
    guard bytes.count >= 32 + 12 + 16, bytes.count <= 2048,
      let eph = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(bytes[0..<32])),
      let shared = try? key.sharedSecretFromKeyAgreement(with: eph)
    else { return nil }
    let salt = Data(bytes[0..<32]) + key.publicKey.rawRepresentation
    let sym = shared.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: salt, sharedInfo: Data("lumora-push notify v1".utf8), outputByteCount: 32)
    guard let box = try? ChaChaPoly.SealedBox(combined: Data(bytes[32...])),
      let plain = try? ChaChaPoly.open(box, using: sym)
    else { return nil }
    return try? JSONDecoder().decode(Notify.self, from: plain)
  }

  /// Decrypt the `lumora.e2e` field of a push payload, if this device can.
  static func notify(from userInfo: [AnyHashable: Any]) -> Notify? {
    guard let info = userInfo["lumora"] as? [String: Any], let e2e = info["e2e"] as? String,
      let blob = Data(base64Encoded: e2e), let key = notifyKey(create: false)
    else { return nil }
    return openNotify(blob, key: key)
  }
}
