// Debug-only helpers enabled by environment variables (no effect otherwise,
// and always disabled in release builds):
//   LUMORA_SNAPSHOT_DIR  – save PNG snapshots of the window (RepaintBoundary)
//                          periodically, on interesting events and per tour
//                          step; also writes me.json (peer/short id) there.
//   LUMORA_TOUR=1        – walk through the main sections automatically.
//   LUMORA_AUTO_NAME     – create an identity with this name if none exists.
//   LUMORA_AUTO_ACCEPT=1 – accept friend requests automatically.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'app.dart';
import 'core/api.dart';
import 'state/stores.dart';

final snapshotKey = GlobalKey();

class DebugDriver {
  DebugDriver(this.sv, this.dir);
  final AppServices sv;
  final String dir;
  int _n = 0;
  Timer? _periodic;
  final _seenEvents = <String>{};

  static String? get snapshotDir => kReleaseMode ? null : Platform.environment['LUMORA_SNAPSHOT_DIR'];

  Future<void> snap(String label) async {
    final ctx = snapshotKey.currentContext;
    if (ctx == null) return;
    final ro = ctx.findRenderObject();
    if (ro is! RenderRepaintBoundary) return; // (debugNeedsPaint throws in release)
    try {
      final view = ui.PlatformDispatcher.instance.views.first;
      final img = await ro.toImage(pixelRatio: view.devicePixelRatio);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      if (png == null) return;
      _n++;
      final f = File('$dir/${_n.toString().padLeft(3, '0')}_$label.png');
      await f.writeAsBytes(png.buffer.asUint8List());
    } catch (e) {
      debugPrint('snapshot failed: $e');
    }
  }

  Future<void> start() async {
    Directory(dir).createSync(recursive: true);
    // Wait for the session.
    while (sv.session.me == null) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final me = sv.session.me!;
    var pw = '';
    try {
      pw = (await sv.api.remoteStatus()).password;
    } catch (_) {}
    File('$dir/me.json').writeAsStringSync(jsonEncode({'peer': me.peer, 'short_id': me.shortId, 'name': me.name, 'remote_password': pw}));

    if (!kReleaseMode && Platform.environment['LUMORA_AUTO_ACCEPT'] == '1') {
      sv.contacts.addListener(() {
        for (final c in sv.contacts.incoming) {
          if (_seenEvents.add('acc:${c.peer}')) {
            snap('friend_request');
            Future<void>.delayed(const Duration(seconds: 2), () => sv.contacts.accept(c.peer));
          }
        }
      });
    }
    // Event-triggered snapshots.
    sv.calls.addListener(() {
      final c = sv.calls.call;
      if (c != null && _seenEvents.add('call:${c.callId}:${c.phase.name}')) {
        Future<void>.delayed(const Duration(milliseconds: 900), () => snap('call_${c.phase.name}'));
      }
    });
    sv.remote.addListener(() {
      final r = sv.remote.request;
      if (r != null && _seenEvents.add('rr:${r.session}')) {
        Future<void>.delayed(const Duration(milliseconds: 900), () => snap('remote_request'));
      }
    });
    _periodic = Timer.periodic(const Duration(seconds: 6), (_) => snap('tick_${sv.nav.section.name}'));

    if (Platform.environment['LUMORA_TOUR'] == '1') unawaited(_tour());
  }

  Future<void> _step(String label, void Function() action, {int wait = 3}) async {
    action();
    await Future<void>.delayed(Duration(seconds: wait));
    await snap(label);
  }

  /// Waits for the peer to befriend us and send content, then visits screens.
  Future<void> _tour() async {
    final nav = sv.nav;
    final end = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(end) && !sv.chat.convs.values.any((c) => c.peer != null && c.lastTs > 0)) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await Future<void>.delayed(const Duration(seconds: 12)); // let messages/photos arrive
    final direct = sv.chat.sorted.where((c) => c.peer != null).toList();
    if (direct.isNotEmpty) await _step('chat_direct', () => nav.openConv(direct.first.id), wait: 4);
    await _step('chat_info', () => nav.toggleInfo(true));
    nav.toggleInfo(false);
    if (direct.isNotEmpty) {
      final peer = direct.first.peer!;
      // Escalation from chat: call → (peer declines) → request control.
      await _step('call_ringing', () => sv.calls.start(direct.first.id), wait: 2);
      await Future<void>.delayed(const Duration(seconds: 5));
      await sv.calls.hangup();
      await _step('request_control', () => sv.remote.connect(peer, '', peerName: sv.contacts.nameOf(peer)).catchError((_) {}), wait: 2);
      await Future<void>.delayed(const Duration(seconds: 6));
      await snap('after_control');
    }
    await _step('friends', () => nav.go(Section.friends));
    if (sv.spaces.spaces.isNotEmpty) {
      await _step('community', () => nav.go(Section.space, space: sv.spaces.spaces.first.id));
    }
    await _step('remote_home', () => nav.go(Section.remote));
    await _step('files', () => nav.go(Section.files));
    await _step('diagnostics', () => nav.go(Section.network), wait: 5);
    await _step('settings', () => nav.go(Section.settings));
    await _step('back_to_chats', () => nav.go(Section.chats));
  }

  void dispose() => _periodic?.cancel();
}

/// Creates an identity without UI when LUMORA_AUTO_NAME is set.
Future<bool> maybeAutoCreate(AppServices sv) async {
  if (kReleaseMode) return false;
  final name = Platform.environment['LUMORA_AUTO_NAME'];
  if (name == null || name.isEmpty || sv.session.phase != SessionPhase.onboarding) return false;
  await sv.createIdentity(name: name);
  return true;
}

/// Exposed for tests of the API surface only.
typedef ApiForDebug = LumoraApi;
