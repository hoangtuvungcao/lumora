// Regression tests for bugs found by the 1.0 release gate (Android emulator run):
// the caller's call clock never started, and phones had no call buttons in a chat.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/chats/chat_view.dart';

import 'helpers.dart';

Future<void> _openChat(WidgetTester t, AppServices sv, String conv, double width) async {
  setSize(t, Size(width, 800));
  await t.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: ChatView(conv: conv, embedded: true)), overlays: false));
  await settle(t);
}

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

/// The chat header's ⋮ menu (the composer has its own "Thêm" button on wide layouts).
final _menu = find.byWidgetPredicate((w) => w is PopupMenuButton<String> && w.tooltip == 'Thêm');

String _direct(AppServices sv) => sv.chat.convs.values.firstWhere((c) => c.id.startsWith('d:') && !c.isSaved).id;

void main() {
  setUpAll(loadFonts);

  test('caller: the call clock starts at the first "active" event (core sends no started_at)', () {
    final calls = CallStore(MockLumoraApi(timers: false));
    Map<String, dynamic> ev(String state) => {'call_id': 'c1', 'conv': 'd:bob', 'state': state, 'video': false};
    calls.onCall(ev('ringing'));
    expect(calls.call?.startedAt, isNull, reason: 'still ringing: "Calling…"');
    calls.onCall(ev('active'));
    final started = calls.call?.startedAt;
    expect(started, isNotNull, reason: 'picked up: the timer must run');
    calls.onCall(ev('active'));
    expect(calls.call?.startedAt, started, reason: 'later events must not restart the clock');
  });

  testWidgets('phone width: voice/video call are in the ⋮ menu', (t) async {
    final sv = await makeServices(t);
    await _openChat(t, sv, _direct(sv), 400);
    expect(find.byTooltip('Gọi thoại'), findsNothing, reason: 'no header buttons below 460 dp');
    await t.tap(_menu);
    await settle(t);
    expect(find.text('Gọi thoại'), findsOneWidget);
    expect(find.text('Gọi video'), findsOneWidget);
    await _done(t, sv);
  });

  testWidgets('wide: call buttons in the header, not duplicated in the menu', (t) async {
    final sv = await makeServices(t);
    await _openChat(t, sv, _direct(sv), 900);
    expect(find.byTooltip('Gọi thoại'), findsOneWidget);
    expect(find.byTooltip('Gọi video'), findsOneWidget);
    await t.tap(_menu);
    await settle(t);
    expect(find.text('Gọi thoại'), findsNothing);
    await _done(t, sv);
  });
}
