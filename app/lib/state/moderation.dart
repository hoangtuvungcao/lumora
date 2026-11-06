// Reports ("Báo cáo") without a server: a group message / member is reported
// to the group's owner and admins; a whole group is left and blocked; members
// can be hidden. Blocked groups and hidden members are account settings the
// core syncs to every device (`settings` event); reports an admin handles on
// one device disappear on the others (`group_report_handled`).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api.dart';

class ModerationStore extends ChangeNotifier {
  ModerationStore(this.api);
  final LumoraApi api;

  List<BlockedGroup> blockedGroups = const [];
  Set<String> hiddenMembers = const {};

  /// Reports waiting on this (admin) device, newest first.
  final List<GroupReport> reports = [];

  /// A new report arrived (the bell shows it).
  void Function(GroupReport r)? onReport;

  /// Reports handled here or on another of my devices (the bell drops them).
  void Function(Set<String> ids)? onHandled;

  /// A group got blocked (here or on another device): its chat goes away.
  void Function(String gid)? onGroupBlocked;

  bool isGroupBlocked(String gid) => blockedGroups.any((b) => b.gid == gid);
  bool isHidden(String peer) => hiddenMembers.contains(peer);

  Future<void> load() async {
    await Future.wait<void>([
      loadBlocked(),
      loadHidden(),
      _loadReports(),
    ]);
  }

  Future<void> loadBlocked() async {
    try {
      _setBlocked(await api.blockedGroups());
    } catch (_) {}
  }

  Future<void> loadHidden() async {
    try {
      hiddenMembers = (await api.hiddenMembers()).toSet();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _loadReports() async {
    try {
      final list = await api.groupReports();
      final known = reports.map((r) => r.id).toSet();
      final now = list.map((r) => r.id).toSet();
      // handled elsewhere while we weren't looking
      final gone = known.difference(now);
      reports
        ..clear()
        ..addAll(list);
      for (final r in list) {
        if (!known.contains(r.id)) onReport?.call(r);
      }
      if (gone.isNotEmpty) onHandled?.call(gone);
      notifyListeners();
    } catch (_) {}
  }

  void _setBlocked(List<BlockedGroup> list) {
    final before = blockedGroups.map((b) => b.gid).toSet();
    blockedGroups = List.unmodifiable(list);
    for (final b in list) {
      if (!before.contains(b.gid)) onGroupBlocked?.call(b.gid);
    }
    notifyListeners();
  }

  /// Report a message ([msgId]) or a member ([peer]) to the group's admins.
  Future<int> report(String gid, {String? msgId, String? peer, required String reason, String note = '', bool hide = false}) async {
    final n = await api.groupReport(gid, msgId: msgId, peer: peer, reason: reason, note: note, hide: hide);
    if (hide && peer != null) hiddenMembers = {...hiddenMembers, peer};
    if (hide) unawaited(loadHidden());
    notifyListeners();
    return n;
  }

  Future<void> setHidden(String peer, bool hidden) async {
    hiddenMembers = (await api.setMemberHidden(peer, hidden)).toSet();
    notifyListeners();
  }

  /// Report a whole group: leave it and block it everywhere.
  Future<void> blockGroup(String gid, {String name = ''}) async => _setBlocked(await api.groupBlock(gid, name: name));

  Future<void> unblockGroup(String gid) async => _setBlocked(await api.groupUnblock(gid));

  /// Admin: done with [id] (dismissed, or acted on) — on all my devices.
  Future<void> handled(String id) async {
    await api.groupReportDone([id]);
    _drop({id});
  }

  void _drop(Set<String> ids) {
    reports.removeWhere((r) => ids.contains(r.id));
    onHandled?.call(ids);
    notifyListeners();
  }

  /// EventHub listener.
  void onEvent(String name, Map<String, dynamic> d) {
    switch (name) {
      case 'settings':
        final key = d['key']?.toString();
        if (key == 'privacy.blocked_groups') unawaited(loadBlocked());
        if (key == 'privacy.hidden_members') unawaited(loadHidden());
      case 'group_report':
        final r = GroupReport.fromJson(d);
        if (r.id.isEmpty || reports.any((x) => x.id == r.id)) return;
        reports.insert(0, r);
        onReport?.call(r);
        notifyListeners();
      case 'group_report_handled':
        final ids = ((d['ids'] as List?) ?? const []).map((e) => '$e').toSet();
        if (ids.isNotEmpty) _drop(ids);
    }
  }

  GroupReport? byId(String id) {
    for (final r in reports) {
      if (r.id == id) return r;
    }
    return null;
  }
}
