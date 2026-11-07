// Plain group calls that don't ring everyone: the core rings only the members
// the caller picked; everyone else gets a `call` event with state
// "available". Those calls are kept here (conv → call) so the group's chat
// and its row in the chat list can show a "Join" banner. Joining =
// `call_answer accept`; dismissing = `call_answer` decline (local only). The
// call's usual "ended" event removes it. One per LumoraApi.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api.dart';

class AvailableCalls extends ChangeNotifier {
  AvailableCalls._(this.api) {
    _sub = api.events.listen(_onEvent);
  }

  static final _byApi = Expando<AvailableCalls>();

  /// The store of [api] (made on first use).
  static AvailableCalls of(LumoraApi api) => _byApi[api] ??= AvailableCalls._(api);

  final LumoraApi api;
  StreamSubscription<Map<String, dynamic>>? _sub;
  final Map<String, CallState> _byConv = {};

  /// The call I may join in [conv] (a group chat), if any.
  CallState? forConv(String conv) => _byConv[conv];

  bool get isEmpty => _byConv.isEmpty;

  void _onEvent(Map<String, dynamic> raw) {
    final e = ApiEvent.parse(raw);
    if (e.name == 'call') {
      onCall(e.data);
    } else if (e.name == 'conversation_removed' || e.name == 'group_removed') {
      if (_byConv.remove(e.data['conv']?.toString() ?? '') != null) notifyListeners();
    }
  }

  @visibleForTesting
  void onCall(Map<String, dynamic> d) {
    final id = d['call_id']?.toString() ?? '';
    if (id.isEmpty) return;
    if (d['state'] == 'available') {
      final c = CallState.fromJson(d);
      if (c.conv.isEmpty) return;
      _byConv[c.conv] = c;
      notifyListeners();
      return;
    }
    // ended, or I'm in it now (answered here or on another device)
    final before = _byConv.length;
    _byConv.removeWhere((_, c) => c.callId == id);
    if (_byConv.length != before) notifyListeners();
  }

  /// "Dismiss": hidden here; the call goes on for the others.
  Future<void> dismiss(String conv) async {
    final c = _byConv.remove(conv);
    if (c == null) return;
    notifyListeners();
    try {
      await api.callAnswer(c.callId, false);
    } catch (_) {}
  }

  /// Forget [conv]'s call once I joined it (the core then sends "active").
  void joined(String conv) {
    if (_byConv.remove(conv) != null) notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
