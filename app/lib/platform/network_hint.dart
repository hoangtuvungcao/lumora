// Tells the core which network the phone is on — Wi-Fi, mobile data, or roaming / a
// metered Wi-Fi (a hotspot): automatic downloads then follow the matching limits
// (Settings › Storage & data), and the core avoids costly connection upgrades off Wi-Fi.

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../core/api.dart';
import 'android_bridge.dart';

/// Mobile data with no Wi-Fi / Ethernet next to it counts as metered (a phone keeps a
/// mobile link up while on Wi-Fi; traffic then goes over Wi-Fi).
bool isMeteredNetwork(List<ConnectivityResult> r) =>
    r.contains(ConnectivityResult.mobile) && !r.contains(ConnectivityResult.wifi) && !r.contains(ConnectivityResult.ethernet);

/// The auto-download class of the current network: `wifi`, `cell` or `roaming`, or null
/// when offline (keep the last one). [info] is Android's view of the active network
/// (`{online, wifi, cell, roaming, metered}`), when available: it knows about roaming and
/// metered Wi-Fi, which the plain connectivity list doesn't.
String? networkClass(List<ConnectivityResult> r, [Map<String, Object?>? info]) {
  if (info != null && info['online'] == true) {
    if (info['roaming'] == true) return 'roaming';
    if (info['wifi'] == true) return info['metered'] == true ? 'roaming' : 'wifi';
    if (info['cell'] == true) return 'cell';
    return info['metered'] == true ? 'cell' : 'wifi';
  }
  if (r.isEmpty || (r.length == 1 && r.first == ConnectivityResult.none)) return null;
  return isMeteredNetwork(r) ? 'cell' : 'wifi';
}

class NetworkHint {
  NetworkHint(this.api, {Connectivity? connectivity, bool? enabled, Future<Map<String, Object?>?> Function()? info})
      : _conn = connectivity,
        _info = info ?? AndroidBridge.networkInfo,
        _enabled = enabled ?? (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  final LumoraApi api;
  final Connectivity? _conn;
  final Future<Map<String, Object?>?> Function() _info;
  final bool _enabled;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  String? _sent;

  /// Last network class sent to the core (null = nothing sent yet: Wi-Fi limits).
  String? get network => _sent;

  /// Whether the last state sent counts as metered (mobile data or roaming).
  bool? get metered => _sent == null ? null : _sent != 'wifi';

  /// Sends the current network now and every change after (phones only: a desktop's
  /// network is treated as Wi-Fi).
  Future<void> start() async {
    if (!_enabled || _sub != null) return;
    final c = _conn ?? Connectivity();
    try {
      _sub = c.onConnectivityChanged.listen((r) => unawaited(_apply(r)), onError: (_) {});
      await _apply(await c.checkConnectivity());
    } catch (e) {
      // plugin missing (tests, unusual platforms): stay on the Wi-Fi limits
      debugPrint('Lumora: network type unknown: $e');
    }
  }

  /// The core restarted (new session): its hint starts on Wi-Fi again.
  Future<void> resend() async {
    final n = _sent;
    _sent = null;
    if (n != null && n != 'wifi') await _send(n);
  }

  Future<void> _apply(List<ConnectivityResult> r) async {
    Map<String, Object?>? info;
    try {
      info = await _info();
    } catch (_) {}
    final n = networkClass(r, info);
    // offline: keep the last state (nothing downloads anyway)
    if (n == null) return;
    await _send(n);
  }

  Future<void> _send(String network) async {
    if (_sent == network) return;
    try {
      await api.setNetworkHint(network: network);
      _sent = network;
    } catch (_) {}
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
