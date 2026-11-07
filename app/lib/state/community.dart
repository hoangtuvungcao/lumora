// Community 2.0: the group info (roles, my permissions, member roles and
// timeouts, channel settings) of the communities the UI is showing, kept
// fresh from the core's `group` events. One per LumoraApi.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api.dart';

class CommunityStore extends ChangeNotifier {
  CommunityStore._(this.api) {
    _sub = api.events.listen(_onEvent);
  }

  static final _byApi = Expando<CommunityStore>();

  /// The store of [api] (made on first use).
  static CommunityStore of(LumoraApi api) => _byApi[api] ??= CommunityStore._(api);

  final LumoraApi api;
  StreamSubscription<Map<String, dynamic>>? _sub;
  final Map<String, GroupInfo> _info = {};
  final Map<String, Future<GroupInfo?>> _loading = {};

  /// The cached info of community [gid]; starts loading it when unknown.
  GroupInfo? info(String gid) {
    if (gid.isEmpty) return null;
    final g = _info[gid];
    if (g == null) load(gid);
    return g;
  }

  /// Fetches [gid]'s info again (after a change made here, or on demand).
  Future<GroupInfo?> load(String gid) {
    final running = _loading[gid];
    if (running != null) return running;
    final f = () async {
      try {
        final g = await api.groupInfo(gid);
        _info[gid] = g;
        notifyListeners();
        return g;
      } catch (_) {
        return _info[gid];
      } finally {
        _loading.remove(gid);
      }
    }();
    _loading[gid] = f;
    return f;
  }

  /// Runs [f] then reloads [gid] at once (no waiting on the event).
  Future<void> change(String gid, Future<void> Function(LumoraApi api) f) async {
    await f(api);
    await load(gid);
  }

  void _onEvent(Map<String, dynamic> raw) {
    final e = ApiEvent.parse(raw);
    final gid = e.data['gid']?.toString() ?? '';
    if (gid.isEmpty || !_info.containsKey(gid)) return;
    if (e.name == 'group_removed') {
      _info.remove(gid);
      notifyListeners();
    } else if (e.name == 'group') {
      // the event carries the updated info; an older core sends less → refetch
      if (e.data['members'] is List && e.data['roles'] is List) {
        _info[gid] = GroupInfo.fromJson(e.data);
        notifyListeners();
      } else {
        load(gid);
      }
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
