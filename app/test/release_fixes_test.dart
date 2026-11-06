// Regression tests for bugs found by the 1.0 release gate (Android emulator run):
// the caller's call clock never started, and phones had no call buttons in a chat.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/chats/chat_info.dart';
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

  // Core events reach the stores in the real-async zone (see helpers / makeServices).
  Future<void> flush(WidgetTester t) async {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await settle(t);
  }

  testWidgets('a message deleted elsewhere (removed) leaves the open chat at once', (t) async {
    final sv = await makeServices(t);
    final conv = _direct(sv);
    await _openChat(t, sv, conv, 900);
    final th = sv.chat.thread(conv);
    expect(th.messages, isNotEmpty);
    final victim = th.messages.last;
    (sv.api as MockLumoraApi).emitForTest('message_update', {'conv': conv, 'id': victim.id, 'removed': true});
    await flush(t);
    expect(th.messages.any((m) => m.id == victim.id), isFalse);
    await _done(t, sv);
  });

  testWidgets('"delete for both" removes the message from my screen at once', (t) async {
    final sv = await makeServices(t);
    final conv = _direct(sv);
    await _openChat(t, sv, conv, 900);
    final th = sv.chat.thread(conv);
    final mine = th.messages.lastWhere((m) => m.mine);
    await t.runAsync(() => sv.chat.deleteFor(conv, mine.id, forEveryone: true));
    await flush(t);
    expect(th.messages.any((m) => m.id == mine.id), isFalse);
    await _done(t, sv);
  });

  testWidgets('phone: a chat deleted elsewhere closes its page; history cleared empties it', (t) async {
    final sv = await makeServices(t);
    final convs = sv.chat.convs.values.where((c) => c.id.startsWith('d:') && !c.isSaved).map((c) => c.id).take(2).toList();
    setSize(t, const Size(400, 800));
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Builder(builder: (ctx) {
      return Scaffold(body: Center(child: TextButton(
        onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: convs[0]))),
        child: const Text('open'))));
    })));
    await settle(t);
    await t.tap(find.text('open'));
    await settle(t);
    expect(find.byType(ChatView), findsOneWidget);
    // cleared on another device: the open thread empties, the page stays
    (sv.api as MockLumoraApi).emitForTest('history_cleared', {'conv': convs[0]});
    await flush(t);
    expect(sv.chat.thread(convs[0]).messages, isEmpty);
    expect(find.byType(ChatView), findsOneWidget);
    // its info page is on top (the user was looking at it)
    Navigator.of(t.element(find.byType(ChatView))).push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: ChatInfoPanel(conv: convs[0]))));
    await settle(t);
    expect(find.byType(ChatInfoPanel), findsOneWidget);
    // deleted for both by the other side: back to the list, the chat is gone —
    // the chat page itself closes, not just the info page on top of it
    (sv.api as MockLumoraApi).emitForTest('conversation_removed', {'conv': convs[0]});
    await flush(t);
    expect(find.byType(ChatInfoPanel), findsNothing);
    expect(find.byType(ChatView, skipOffstage: false), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(sv.chat.convs.containsKey(convs[0]), isFalse);
    await _done(t, sv);
  });
}
