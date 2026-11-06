import UserNotifications

/// Runs for every Lumora alert push (`mutable-content: 1`) for up to ~30 s with ~24 MB of
/// memory. The push from the bridge only says "new message" (a localisation key); the
/// sender also attached its name and a short preview sealed to this device's notification
/// key (Keychain, shared with the app). We open it here with CryptoKit – the bridge and
/// Apple only ever see ciphertext – unless the user hid notification content or the
/// message belongs to a locked chat.
///
/// The messages themselves stay on the sender's device until Lumora opens and reconnects
/// (the P2P core is not started here: it would not fit the extension's memory budget).
final class NotificationService: UNNotificationServiceExtension {
  private var handler: ((UNNotificationContent) -> Void)?
  private var best: UNMutableNotificationContent?

  override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
    handler = contentHandler
    let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
    best = content
    let info = request.content.userInfo["lumora"] as? [String: Any]
    let isCall = (info?["k"] as? String) == "call"
    content.title = "Lumora"
    content.body = NSLocalizedString(isCall ? "PUSH_INCOMING_CALL" : "PUSH_NEW_MESSAGE", comment: "")
    // Hidden content or a locked chat: only "Lumora" + "New message" / "Incoming call".
    if !LumoraShared.hideContent, let n = LumoraShared.notify(from: request.content.userInfo),
      !LumoraShared.isLocked(conv: n.conv, from: n.from)
    {
      if let name = n.name, !name.isEmpty { content.title = name }
      if !isCall, let p = n.preview, !p.isEmpty { content.body = p }
      if let conv = n.conv, !conv.isEmpty { content.threadIdentifier = conv }
    }
    contentHandler(content)
    handler = nil
  }

  override func serviceExtensionTimeWillExpire() {
    if let h = handler, let b = best { h(b) }
    handler = nil
  }
}
