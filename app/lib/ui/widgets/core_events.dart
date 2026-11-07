// Screens that keep their own copy of something the account syncs between
// its devices (the Bot Studio chat, my bots, "find me by ID"…) reload it when
// the core says it changed on another device — without being reopened.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api.dart';

/// Calls [run] after core events that [match] (debounced: a burst of synced
/// changes reloads once). [cancel] it in `dispose`.
class CoreEventWatch {
  CoreEventWatch(LumoraApi api, this.match, this.run, {this.debounce = const Duration(milliseconds: 200)}) {
    _sub = api.events.listen((raw) {
      final e = ApiEvent.parse(raw);
      if (!match(e.name, e.data)) return;
      _timer?.cancel();
      _timer = Timer(debounce, run);
    });
  }

  /// A `settings` event for one of [keys] (an account setting changed on
  /// another device).
  CoreEventWatch.settings(LumoraApi api, Set<String> keys, VoidCallback run, {Duration debounce = const Duration(milliseconds: 200)})
      : this(api, (name, d) => name == 'settings' && keys.contains(d['key']?.toString()), run, debounce: debounce);

  final bool Function(String name, Map<String, dynamic> data) match;
  final VoidCallback run;
  final Duration debounce;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _timer;

  void cancel() {
    _timer?.cancel();
    _sub?.cancel();
  }
}
