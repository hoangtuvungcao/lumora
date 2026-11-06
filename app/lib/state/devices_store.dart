// Multi-device state: this account's devices, friends' devices, the link
// flow events and the history copy on a newly linked device
// (docs/src/dev/multi-device.md §8).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api.dart';

/// What this device was told when it was signed out of the account.
class DeviceSignOut {
  const DeviceSignOut({this.bySelf = false, this.wipe = false, this.kept = false});
  final bool bySelf;
  final bool wipe;

  /// The old account's messages stay on this device, set aside (not deleted).
  final bool kept;
}

class DevicesStore extends ChangeNotifier {
  DevicesStore(this.api);
  final LumoraApi api;

  /// My devices (null until loaded).
  DeviceList? list;
  bool loading = false;
  String? error;

  /// Friends' devices, refreshed by `contact_devices` events.
  final Map<String, List<DeviceInfo>> contactDevices = {};

  /// History copy on a newly linked device.
  HistoryStatus history = const HistoryStatus();

  /// "Dùng ngay": the progress screen was dismissed (the copy goes on).
  bool historyDismissed = false;

  /// Set when this device was signed out of the account.
  DeviceSignOut? signedOut;

  /// A sign-out found at launch (the core's marker in the data folder): the
  /// notice is shown instead of the lock screen, so a password typed there can
  /// never start a new account in place of the old one.
  void markSignedOut(DeviceSignOut out) {
    signedOut = out;
    notifyListeners();
  }

  /// `link_state` / `link_request` events for the open link screen.
  final _link = StreamController<ApiEvent>.broadcast();
  Stream<ApiEvent> get linkEvents => _link.stream;

  bool get isPrimary => list?.primary ?? true;

  /// [peer] (a device or account id) is one of my own devices / my own account.
  bool isMine(String peer) =>
      peer.isNotEmpty && ((list?.devices.any((d) => d.device == peer) ?? false) || peer == (list?.account ?? ''));
  int get count => list?.devices.length ?? 1;

  /// History was being copied during this session (the screen then stays,
  /// showing "all done", until the user moves on).
  bool _sawActive = false;

  /// The progress screen shows while history is being copied, until dismissed.
  bool get showHistory => (history.active || _sawActive) && !historyDismissed;

  void _setHistory(HistoryStatus h) {
    history = h;
    if (h.active) _sawActive = true;
  }

  Future<void> load() async {
    loading = list == null;
    notifyListeners();
    try {
      list = await api.devices();
      error = null;
    } catch (e) {
      error = e is ApiException ? e.message : 'internal'; // shown as plain words
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> loadHistory() async {
    try {
      _setHistory(await api.historyStatus());
      notifyListeners();
    } catch (_) {}
  }

  Future<List<DeviceInfo>> loadContact(String peer) async {
    final d = await api.contactDevices(peer);
    contactDevices[peer] = d;
    notifyListeners();
    return d;
  }

  Future<void> rename(String device, String name) async {
    list = await api.deviceRename(device, name);
    notifyListeners();
  }

  Future<void> revoke(String device, {bool wipeMedia = false}) async {
    list = await api.deviceRevoke(device, wipeMedia: wipeMedia);
    notifyListeners();
  }

  void dismissHistory() {
    historyDismissed = true;
    notifyListeners();
  }

  /// Back to a fresh start (after this device was signed out).
  void reset() {
    list = null;
    contactDevices.clear();
    history = const HistoryStatus();
    historyDismissed = false;
    _sawActive = false;
    signedOut = null;
    notifyListeners();
  }

  void onEvent(String name, Map<String, dynamic> d) {
    switch (name) {
      case 'devices':
        if (d['devices'] is List) {
          list = DeviceList.fromJson(d);
          notifyListeners();
        } else {
          load();
        }
      case 'contact_devices':
        final peer = d['peer']?.toString() ?? '';
        final devs = d['devices'];
        if (peer.isEmpty) break;
        if (devs is List) {
          contactDevices[peer] = [for (final x in devs) if (x is Map) DeviceInfo.fromJson(x.cast<String, dynamic>())];
          notifyListeners();
        } else {
          loadContact(peer).catchError((_) => const <DeviceInfo>[]);
        }
      case 'presence':
        // a friend's device came / went: its dot in their device list (and the
        // remote device picker) follows without reopening it
        final peer = d['peer']?.toString() ?? '';
        final dev = d['device']?.toString() ?? '';
        final list = contactDevices[peer];
        if (list == null || dev.isEmpty) break;
        final i = list.indexWhere((x) => x.device == dev);
        if (i < 0) break;
        final on = d['device_online'] is bool ? d['device_online'] as bool : d.containsKey('remote_addr');
        if (list[i].online == on) break;
        contactDevices[peer] = List.of(list)..[i] = list[i].withPresence(online: on, lastSeen: DateTime.now().millisecondsSinceEpoch);
        notifyListeners();
      case 'history_sync':
        _setHistory(history.update(d));
        notifyListeners();
      case 'link_state' || 'link_request':
        _link.add(ApiEvent(name, d));
      case 'device_revoked':
        // (the core keeps the data aside unless a wipe was asked or I signed out here)
        signedOut = DeviceSignOut(bySelf: d['by_self'] == true, wipe: d['wipe'] == true, kept: d['by_self'] != true && d['wipe'] != true);
        notifyListeners();
    }
  }

  @override
  void dispose() {
    _link.close();
    super.dispose();
  }
}
