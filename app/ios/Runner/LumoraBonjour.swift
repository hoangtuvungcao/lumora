import Flutter
import Foundation
import Network

/// Bonjour/DNS-SD for the iPhone: the same `_lumora._udp` service the desktop/Android core
/// advertises with mdns-sd. Uses the system's mDNSResponder, so it needs only
/// `NSLocalNetworkUsageDescription` + `NSBonjourServices` – not Apple's multicast entitlement.
///
/// * advertise: `DNSServiceRegister` (registers a record; does not bind the port, which the
///   Rust core's QUIC socket owns), instance name = the core's daily LAN hint, TXT v=1,id=hint
/// * browse: `NWBrowser`; each result is resolved to an address with a short-lived UDP
///   `NWConnection` (no packet is sent) and handed to the core with `lumora_lan_candidate`.
final class LumoraBonjour {
  static let shared = LumoraBonjour()

  private let queue = DispatchQueue(label: "vn.lumora.bonjour")
  private var browser: NWBrowser?
  private var registration: DNSServiceRef?
  private var resolving: [NWEndpoint: NWConnection] = [:]
  private var lastResolved: [NWEndpoint: Date] = [:]
  private var timer: DispatchSourceTimer?
  private var myName = ""
  private var serviceType = "_lumora._udp"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "vn.lumora/bonjour", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let a = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "start":
        let name = a["name"] as? String ?? ""
        let port = a["port"] as? Int ?? 0
        let enabled = a["enabled"] as? Bool ?? true
        if enabled, name.count == 16, port > 0, port < 65536 {
          shared.start(name: name, type: bonjourType(a["service"] as? String), port: UInt16(port))
        } else {
          shared.stop()
        }
        result(nil)
      case "stop":
        shared.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// "_lumora._udp.local." → "_lumora._udp"
  static func bonjourType(_ s: String?) -> String {
    var t = s ?? "_lumora._udp"
    if t.hasSuffix(".") { t.removeLast() }
    if t.hasSuffix(".local") { t.removeLast(6) }
    return t.isEmpty ? "_lumora._udp" : t
  }

  func start(name: String, type: String, port: UInt16) {
    queue.async { [self] in
      if name == myName, type == serviceType, browser != nil { return }
      stopLocked()
      myName = name
      serviceType = type
      advertise(name: name, type: type, port: port)
      let params = NWParameters()
      params.includePeerToPeer = false
      let b = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: params)
      b.browseResultsChangedHandler = { [weak self] results, _ in self?.handle(results) }
      b.stateUpdateHandler = { state in
        if case .failed(let e) = state { NSLog("Lumora Bonjour browse failed: \(e)") }
      }
      b.start(queue: queue)
      browser = b
      // the core forgets sightings after 2 minutes: re-resolve what is still visible
      let t = DispatchSource.makeTimerSource(queue: queue)
      t.schedule(deadline: .now() + 45, repeating: 45)
      t.setEventHandler { [weak self] in
        guard let self, let b = self.browser else { return }
        self.lastResolved.removeAll()
        self.handle(b.browseResults)
      }
      t.resume()
      timer = t
    }
  }

  func stop() { queue.async { [self] in stopLocked() } }

  private func stopLocked() {
    timer?.cancel()
    timer = nil
    browser?.cancel()
    browser = nil
    resolving.values.forEach { $0.cancel() }
    resolving.removeAll()
    lastResolved.removeAll()
    if let r = registration {
      DNSServiceRefDeallocate(r)
      registration = nil
    }
    myName = ""
  }

  private func advertise(name: String, type: String, port: UInt16) {
    var txt = [UInt8]()
    for kv in ["v=1", "id=\(name)"] {
      let b = Array(kv.utf8)
      txt.append(UInt8(b.count))
      txt.append(contentsOf: b)
    }
    var ref: DNSServiceRef?
    let err = txt.withUnsafeBytes { raw in
      DNSServiceRegister(&ref, 0, 0, name, type, nil, nil, port.bigEndian, UInt16(raw.count), raw.baseAddress, nil, nil)
    }
    guard err == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
      NSLog("Lumora Bonjour register failed: \(err)")
      return
    }
    DNSServiceSetDispatchQueue(ref, queue)
    registration = ref
  }

  private func handle(_ results: Set<NWBrowser.Result>) {
    for r in results {
      guard case .bonjour(let txt) = r.metadata, txt["v"] == "1", let id = txt["id"], id.count == 16, id != myName
      else { continue }
      if resolving[r.endpoint] != nil { continue }
      if let t = lastResolved[r.endpoint], Date().timeIntervalSince(t) < 40 { continue }
      let c = NWConnection(to: r.endpoint, using: .udp)
      resolving[r.endpoint] = c
      c.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          if case .hostPort(let host, let port)? = c.currentPath?.remoteEndpoint, let ip = Self.literal(host) {
            _ = lumora_lan_candidate(id, ip, port.rawValue)
          }
          self.lastResolved[r.endpoint] = Date()
          c.cancel()
        case .failed, .cancelled:
          self.resolving[r.endpoint] = nil
        default:
          break
        }
      }
      c.start(queue: queue)
      // never let a resolution hang around
      queue.asyncAfter(deadline: .now() + 5) { [weak self] in
        if let c2 = self?.resolving[r.endpoint], c2 === c { c.cancel() }
      }
    }
  }

  /// IP literal for the core; link-local IPv6 needs a scope the core does not track, skip it.
  private static func literal(_ host: NWEndpoint.Host) -> String? {
    switch host {
    case .ipv4(let a):
      return "\(a)"
    case .ipv6(let a):
      let s = "\(a)"
      if s.lowercased().hasPrefix("fe80") { return nil }
      return s.split(separator: "%").first.map(String.init)
    default:
      return nil
    }
  }
}
