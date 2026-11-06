// Group flood notices: the core emits `group_flood` when a member's messages
// in a group were held back (too fast / too much today / group full). The
// open group chat shows the latest one as a banner; admins may get a
// slow-mode suggestion.

import 'package:flutter/foundation.dart';

/// One `group_flood` event (see docs/src/dev/api.md).
@immutable
class FloodNotice {
  const FloodNotice({
    required this.gid,
    required this.conv,
    required this.author,
    required this.name,
    required this.reason,
    required this.admin,
    required this.suggestSlowModeS,
    required this.text,
  });

  factory FloodNotice.fromJson(Map<String, dynamic> d) {
    final gid = d['gid']?.toString() ?? '';
    final conv = d['conv']?.toString() ?? '';
    return FloodNotice(
      gid: gid,
      conv: conv.isNotEmpty ? conv : 'g:$gid',
      author: d['author']?.toString() ?? '',
      name: d['name']?.toString() ?? '',
      reason: d['reason']?.toString() ?? 'rate',
      admin: d['admin'] == true,
      suggestSlowModeS: (d['suggest_slow_mode_s'] as num?)?.toInt() ?? 0,
      text: d['text']?.toString() ?? '',
    );
  }

  final String gid;
  final String conv;
  final String author;
  final String name;

  /// `rate` | `author_quota` | `group_quota`.
  final String reason;
  final bool admin;

  /// Seconds between messages to suggest (admins, `rate` only); 0 = none.
  final int suggestSlowModeS;

  /// Already localised by the core.
  final String text;

  bool get canSlowDown => admin && suggestSlowModeS > 0;
  String get _key => '$conv|$author|$reason';
}

/// conv -> the flood notice to show in that chat (null/absent = none).
class FloodNotices extends ValueNotifier<Map<String, FloodNotice>> {
  FloodNotices({DateTime Function()? clock}) : _clock = clock ?? DateTime.now, super(const {});

  /// The core already throttles to once per 10 min per author; this guards
  /// against repeats from several devices / core restarts as well.
  static const repeatWindow = Duration(minutes: 10);

  final DateTime Function() _clock;
  final Map<String, DateTime> _seen = {};

  void onEvent(Map<String, dynamic> d) {
    final n = FloodNotice.fromJson(d);
    if (n.gid.isEmpty && !n.conv.startsWith('g:')) return;
    final now = _clock();
    final last = _seen[n._key];
    if (last != null && now.difference(last) < repeatWindow) return;
    _seen.removeWhere((_, t) => now.difference(t) >= repeatWindow);
    _seen[n._key] = now;
    value = {...value, n.conv: n};
  }

  FloodNotice? of(String conv) => value[conv];

  void dismiss(String conv) {
    if (!value.containsKey(conv)) return;
    value = {...value}..remove(conv);
  }
}
