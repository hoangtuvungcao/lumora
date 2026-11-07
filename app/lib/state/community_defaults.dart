// "Default history retention for communities" (Settings › Privacy): applied
// to a community's channels when I create or join it. Channels of a joined
// community arrive a little later (the core learns them from members), so
// the community stays "pending" for a while and each new channel conversation
// of it gets the default as it shows up — once, never over a choice made in
// the chat's own settings.

import 'dart:async';

import '../core/api.dart';
import 'settings.dart';

class CommunityDefaults {
  CommunityDefaults(this.api, this.settings, {this.window = const Duration(minutes: 10)});
  final LumoraApi api;
  final Settings settings;

  /// How long after creating / joining new channels still get the default.
  final Duration window;

  /// gid -> until when its new channels get the default.
  final Map<String, DateTime> _pending = {};

  /// Conversations already given the default (each only once).
  final Set<String> _done = {};

  static const modes = ['forever', 'session', '24h', '7d', '30d'];

  String get _mode => modes.contains(settings.communityRetention) ? settings.communityRetention : 'forever';

  /// I created or joined the community whose main conversation is [conv]
  /// (`g:<gid>`); [channels]: the channel conversations known right now.
  Future<void> adopt(String conv, {Iterable<String> channels = const []}) async {
    final gid = _gid(conv);
    if (gid.isEmpty || _mode == 'forever') return;
    _pending[gid] = DateTime.now().add(window);
    await Future.wait([_apply(conv), for (final c in channels) _apply(c)]);
  }

  /// EventHub listener: a new channel of a pending community.
  void onEvent(String name, Map<String, dynamic> d) {
    if (name != 'conversation' || _pending.isEmpty) return;
    final conv = d['id']?.toString() ?? '';
    final gid = _gid(conv);
    final until = _pending[gid];
    if (until == null) return;
    if (DateTime.now().isAfter(until)) {
      _pending.remove(gid);
      return;
    }
    unawaited(_apply(conv));
  }

  Future<void> _apply(String conv) async {
    if (conv.isEmpty || !_done.add(conv)) return;
    try {
      // never over a retention already chosen for this chat
      if (await api.getRetention(conv) != 'forever') return;
      await api.setRetention(conv, _mode);
    } catch (_) {
      _done.remove(conv);
    }
  }

  static String _gid(String conv) => conv.startsWith('g:') ? conv.substring(2).split('#').first : '';
}
