// Invitations to groups waiting for my answer: Settings › Privacy "who can
// add me to groups" lets only friends (or nobody) add me directly; everyone
// else's invitation waits here (`group_invites`, events `group_invite` when
// one arrives and `group_invites` when the list changed — answered here or
// on another of my devices). One per LumoraApi.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api.dart';

class GroupInvitesStore extends ChangeNotifier {
  GroupInvitesStore._(this.api) {
    _sub = api.events.listen(_onEvent);
  }

  static final _byApi = Expando<GroupInvitesStore>();

  /// The store of [api] (made on first use).
  static GroupInvitesStore of(LumoraApi api) => _byApi[api] ??= GroupInvitesStore._(api);

  final LumoraApi api;
  StreamSubscription<Map<String, dynamic>>? _sub;
  List<GroupInvite> invites = const [];
  Timer? _reload;

  /// Join requests I sent by link that wait for the group (gid → group name).
  final Map<String, String> pendingJoins = {};

  /// The last join that was turned down (shown until dismissed).
  JoinDenial? denied;

  /// I asked to join [gid] by link: waiting until the group arrives or says no.
  void joinRequested(String gid, String name) {
    if (gid.isEmpty) return;
    pendingJoins[gid] = name;
    if (denied?.gid == gid) denied = null;
    notifyListeners();
  }

  void dismissDenied() {
    denied = null;
    notifyListeners();
  }

  Future<void> load() async {
    try {
      invites = await api.groupInvites();
    } on ApiException catch (e) {
      // an older core without invitations: nothing waits
      if (e.code != 'err.unknown_command' && !e.message.startsWith('unknown command')) rethrow;
      invites = const [];
    }
    notifyListeners();
  }

  void _onEvent(Map<String, dynamic> raw) {
    final e = ApiEvent.parse(raw);
    if (e.name == 'group_join_denied') {
      final gid = e.data['gid']?.toString() ?? '';
      final name = pendingJoins.remove(gid) ?? '';
      denied = JoinDenial(gid: gid, name: name, reason: e.data['reason']?.toString() ?? 'denied', text: e.data['text']?.toString() ?? '');
      notifyListeners();
      return;
    }
    if (e.name == 'group' && pendingJoins.isNotEmpty) {
      // the group arrived: the request was approved
      final gid = e.data['gid']?.toString() ?? '';
      final role = e.data['my_role']?.toString();
      if (pendingJoins.containsKey(gid) && role != null && role != 'none') {
        pendingJoins.remove(gid);
        notifyListeners();
      }
      return;
    }
    if (e.name == 'group_invite') {
      final i = GroupInvite.fromJson(e.data);
      if (i.gid.isEmpty) return;
      invites = [i, ...invites.where((x) => x.gid != i.gid)];
      notifyListeners();
    } else if (e.name == 'group_invites') {
      _reload?.cancel();
      _reload = Timer(const Duration(milliseconds: 150), () => load().catchError((_) {}));
    }
  }

  /// Accept / decline [i]; accepted → the group's conversation id.
  Future<String?> answer(GroupInvite i, bool accept) async {
    final conv = await api.groupInviteAnswer(i.gid, accept);
    invites = invites.where((x) => x.gid != i.gid).toList();
    notifyListeners();
    return conv;
  }

  @override
  void dispose() {
    _reload?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}

/// `group_join_denied {gid, reason: revoked|removed|denied, code, text}`.
class JoinDenial {
  const JoinDenial({required this.gid, required this.name, required this.reason, this.text = ''});
  final String gid;
  final String name;
  final String reason;
  final String text;

  /// l10n key for the message.
  String get key => switch (reason) {
        'revoked' => 'jd_revoked',
        'removed' => 'jd_removed',
        _ => 'jd_denied',
      };
}
