import AVFoundation
import CallKit
import Flutter
import PushKit
import UIKit
import UserNotifications

/// Opt-in wake-ups through the publisher's push bridge (docs/src/ops/push.md):
/// * APNs device token (alert pushes, shown/decrypted by the Notification Service Extension)
/// * PushKit VoIP token → incoming calls ring through CallKit even when Lumora is closed.
/// Tokens go to Dart ("tokens"), which asks the core to seal them to the bridge key and
/// share them with friends. Nothing here talks to the network.
final class LumoraPush: NSObject, PKPushRegistryDelegate, CXProviderDelegate {
  static let shared = LumoraPush()

  private let enabledKey = "lumora.push.enabled"
  private var channel: FlutterMethodChannel?
  private var registry: PKPushRegistry?
  private var apns: String?
  private var voip: String?
  private var pendingToDart: [(String, [String: Any])] = []

  /// A call CallKit is showing. Main thread only (PushKit, CallKit and Flutter all
  /// deliver on the main queue).
  private struct Ring {
    /// Lumora call id (hex); "" while unknown (the push could not be opened) until the
    /// core rings for it (`coreIncoming`).
    var id: String
    let video: Bool
    var answered = false
    var timeout: DispatchWorkItem?
  }
  private var calls: [UUID: Ring] = [:]
  private let callController = CXCallController()

  /// The caller gives up after 45 s; if Dart never says how the call ended (the invite
  /// never arrived, the core did not start) the ring stops here anyway.
  static let ringTimeout: TimeInterval = 50
  /// A push sealed longer ago than this is for a call that is over (late delivery).
  static let stalePush: TimeInterval = 180

  /// A CallKit call was answered and is not over: CallKit owns the audio session.
  var ownsAudioSession: Bool { calls.values.contains { $0.answered } }
  /// That call is a video call (CallKit has no "answer audio only").
  var answeredVideo: Bool { calls.values.contains { $0.answered && $0.video } }

  private lazy var provider: CXProvider = {
    let c = CXProviderConfiguration(localizedName: "Lumora")
    c.supportsVideo = true
    c.maximumCallGroups = 1
    c.maximumCallsPerCallGroup = 1
    c.supportedHandleTypes = [.generic]
    c.includesCallsInRecents = false  // privacy: no call history outside Lumora
    let p = CXProvider(configuration: c)
    p.setDelegate(self, queue: nil)
    return p
  }()

  private var enabled: Bool {
    get { UserDefaults.standard.bool(forKey: enabledKey) }
    set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
  }

  private var sandbox: Bool {
    #if DEBUG
      return true
    #else
      return false
    #endif
  }

  static func register(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "vn.lumora/push", binaryMessenger: messenger)
    shared.channel = ch
    ch.setMethodCallHandler { call, result in
      let a = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "enable":
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
          DispatchQueue.main.async {
            shared.enabled = granted
            if granted { shared.startRegistrations() }
            result(granted)
          }
        }
      case "disable":
        shared.enabled = false
        UIApplication.shared.unregisterForRemoteNotifications()
        shared.registry?.desiredPushTypes = []
        shared.apns = nil
        shared.voip = nil
        result(nil)
      case "refresh":  // Dart is ready: resend tokens and anything CallKit queued meanwhile
        shared.flushToDart()
        shared.sendTokensIfReady()
        result(nil)
      case "setHideContent":
        LumoraShared.defaults?.set(a["hide"] as? Bool ?? false, forKey: "hide_content")
        result(nil)
      case "setLockedConvs":  // locked chats: their calls ring as "Incoming call", no name
        LumoraShared.setLockedConvs(a["convs"] as? [String] ?? [])
        result(nil)
      case "callEnded":  // the core ended a call CallKit is showing (see AppleServices.onCallEvent)
        let id = a["call_id"] as? String ?? ""
        if let uuid = shared.uuid(for: id) {
          let reason = a["reason"] as? String ?? "remote"
          if reason == "local" {
            shared.endLocally(uuid)
          } else {
            shared.end(uuid, reason: LumoraPush.endedReason(reason))
          }
        }
        result(nil)
      case "coreIncoming":  // the core rings for call_id: is CallKit already showing it?
        result(shared.bind(callId: a["call_id"] as? String ?? ""))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Call from didFinishLaunching: PushKit must have a delegate before iOS hands over a VoIP push.
  func onLaunch() {
    if enabled { startRegistrations() }
  }

  private func startRegistrations() {
    UIApplication.shared.registerForRemoteNotifications()
    if registry == nil {
      let r = PKPushRegistry(queue: .main)
      r.delegate = self
      registry = r
    }
    registry?.desiredPushTypes = [.voIP]
    _ = provider
  }

  func didRegister(deviceToken: Data) {
    apns = deviceToken.map { String(format: "%02x", $0) }.joined()
    // give PushKit a moment so both tokens travel together
    DispatchQueue.main.asyncAfter(deadline: .now() + (voip == nil ? 2 : 0)) { self.sendTokensIfReady() }
  }

  private func sendTokensIfReady() {
    guard enabled, let apns, let key = LumoraShared.notifyKey(create: true) else { return }
    toDart(
      "tokens",
      [
        "apns": apns, "voip": voip ?? "", "sandbox": sandbox,
        "notify_key": key.publicKey.rawRepresentation.base64EncodedString(),
      ])
  }

  /// Deliver to Dart, or keep it until Dart's handler exists (app launched in the background).
  private func toDart(_ method: String, _ args: [String: Any]) {
    guard let ch = channel else {
      pendingToDart.append((method, args))
      return
    }
    ch.invokeMethod(method, arguments: args) { [weak self] r in
      if let o = r as? NSObject, o === FlutterMethodNotImplemented as NSObject {
        self?.pendingToDart.append((method, args))
      }
    }
  }

  private func flushToDart() {
    let items = pendingToDart
    pendingToDart.removeAll()
    for (m, a) in items { toDart(m, a) }
  }

  // MARK: PKPushRegistryDelegate

  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    voip = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    sendTokensIfReady()
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    voip = nil
  }

  func pushRegistry(
    _ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    // Apple's rule: every VoIP push is reported to CallKit right away, or iOS kills the app
    // and eventually stops delivering VoIP pushes.
    let n = LumoraShared.notify(from: payload.dictionaryPayload)
    let id = n?.call ?? ""
    let video = n?.video ?? false
    let update = CXCallUpdate()
    // Hidden notification content, a locked chat or a push we cannot open: no name.
    let showName = !LumoraShared.hideContent && !LumoraShared.isLocked(conv: n?.conv, from: n?.from)
    let name = showName ? (n?.name ?? "") : ""
    update.localizedCallerName = name.isEmpty ? NSLocalizedString("PUSH_INCOMING_CALL", comment: "") : name
    update.remoteHandle = CXHandle(type: .generic, value: showName ? (n?.from ?? "lumora") : "lumora")
    update.hasVideo = video
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false

    // The same call pushed again: report it again (required), CallKit keeps one call.
    if !id.isEmpty, let existing = uuid(for: id) {
      provider.reportNewIncomingCall(with: existing, update: update) { _ in completion() }
      return
    }
    let stale = n?.t.map { Date().timeIntervalSince1970 - $0 / 1000 > LumoraPush.stalePush } ?? false
    let callUUID = UUID()
    calls[callUUID] = Ring(id: id, video: video)
    armTimeout(callUUID)
    provider.reportNewIncomingCall(with: callUUID, update: update) { [weak self] error in
      if error != nil {
        self?.forget(callUUID)  // Do Not Disturb, blocked, another call: nothing rings
      } else if stale {
        self?.end(callUUID, reason: .unanswered)
      }
      completion()
    }
    if !id.isEmpty && !stale { toDart("incomingCall", ["call_id": id, "from": n?.from ?? "", "video": video]) }
  }

  // MARK: CallKit bookkeeping

  private func uuid(for id: String) -> UUID? {
    id.isEmpty ? nil : calls.first(where: { $0.value.id == id })?.key
  }

  private func armTimeout(_ uuid: UUID) {
    let work = DispatchWorkItem { [weak self] in
      // Unanswered, or answered but the core never rang for it: stop ringing.
      guard let self, let r = self.calls[uuid], !r.answered || r.id.isEmpty else { return }
      self.end(uuid, reason: r.answered ? .failed : .unanswered)
    }
    calls[uuid]?.timeout?.cancel()
    calls[uuid]?.timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + LumoraPush.ringTimeout, execute: work)
  }

  /// Drops the ring without touching CallKit (it is already gone there).
  private func forget(_ uuid: UUID) {
    guard let r = calls.removeValue(forKey: uuid) else { return }
    r.timeout?.cancel()
    if !r.id.isEmpty { toDart("callGone", ["call_id": r.id]) }
  }

  /// The call ended outside CallKit's own UI (caller hung up, timeout, another device…).
  private func end(_ uuid: UUID, reason: CXCallEndedReason) {
    guard let r = calls.removeValue(forKey: uuid) else { return }
    r.timeout?.cancel()
    provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    if !r.id.isEmpty { toDart("callGone", ["call_id": r.id]) }
  }

  /// The user declined / hung up in Lumora's own screen: end it the way CallKit expects
  /// (an end action), without echoing it back to Dart.
  private func endLocally(_ uuid: UUID) {
    guard let r = calls.removeValue(forKey: uuid) else { return }
    r.timeout?.cancel()
    callController.request(CXTransaction(action: CXEndCallAction(call: uuid))) { [weak self] error in
      if error != nil {
        DispatchQueue.main.async { self?.provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded) }
      }
    }
  }

  /// The core rings for `id`. True if CallKit already shows it (also when a ring whose
  /// push could not be opened is adopted for it), so Dart ends it with the call.
  private func bind(callId id: String) -> Bool {
    if id.isEmpty { return false }
    if uuid(for: id) != nil { return true }
    guard let unnamed = calls.first(where: { $0.value.id.isEmpty })?.key, var r = calls[unnamed] else { return false }
    r.id = id
    calls[unnamed] = r
    if r.answered {
      r.timeout?.cancel()
      toDart("answerCall", ["call_id": id, "video": r.video])
    }
    return true
  }

  static func endedReason(_ s: String) -> CXCallEndedReason {
    switch s {
    case "unanswered": return .unanswered
    case "answered_elsewhere": return .answeredElsewhere
    case "declined_elsewhere": return .declinedElsewhere
    case "failed": return .failed
    default: return .remoteEnded
    }
  }

  // MARK: CXProviderDelegate

  func providerDidReset(_ provider: CXProvider) {
    let rings = calls
    calls.removeAll()
    for r in rings.values {
      r.timeout?.cancel()
      if !r.id.isEmpty { toDart("endCall", ["call_id": r.id, "answered": r.answered]) }
    }
    LumoraAudioSession.callKitDeactivated()
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    guard var r = calls[action.callUUID] else {
      action.fail()
      return
    }
    r.answered = true
    calls[action.callUUID] = r
    // Category and mode before CallKit activates the session (provider(_:didActivate:)).
    LumoraAudioSession.callKitAnswered(video: r.video)
    if !r.id.isEmpty {
      r.timeout?.cancel()
      toDart("answerCall", ["call_id": r.id, "video": r.video])
    }  // else: answered once the core names the call (bind), or failed by the timeout
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    // Declined on the ring screen or hung up from the system call UI.
    if let r = calls.removeValue(forKey: action.callUUID) {
      r.timeout?.cancel()
      if !r.id.isEmpty { toDart("endCall", ["call_id": r.id, "answered": r.answered]) }
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    if let r = calls[action.callUUID], !r.id.isEmpty {
      toDart("muteCall", ["call_id": r.id, "muted": action.isMuted])
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    LumoraAudioSession.callKitActivated()
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    LumoraAudioSession.callKitDeactivated()
  }
}
