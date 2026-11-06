// A send that timed out (or failed) and is sent again by the user carries
// the same `client_id`, so it can never become two messages; "You:" in the
// chat list comes from the core's `last_mine` from the first load.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/chats/composer.dart';

import 'helpers.dart';

/// The first send reaches the core but the answer never comes back in time.
class _SlowSpy extends MockLumoraApi {
  _SlowSpy() : super(timers: false);
  final ids = <String?>[];
  bool timeoutOnce = true;
  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) async {
    if (cmd != 'send_message') return super.request(cmd, args);
    ids.add(args['client_id'] as String?);
    final r = await super.request(cmd, args);
    if (timeoutOnce) {
      timeoutOnce = false;
      throw ApiException('timeout', cmd: cmd);
    }
    return r;
  }
}

void main() {
  test('client ids: UUID v4, reused only for a retry of the same text', () {
    final c = ComposerController();
    final a = c.clientIdFor('xin chào');
    expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(a), isTrue);
    c.keepForRetry('xin chào', a);
    expect(c.clientIdFor('xin chào'), a, reason: 'retry of the failed send');
    c.keepForRetry('xin chào', a);
    expect(c.clientIdFor('xin chào nhé'), isNot(a), reason: 'edited text is a new message');
    final b = c.clientIdFor('x');
    c.sendSucceeded();
    expect(c.clientIdFor('x'), isNot(b));
    c.dispose();
  });

  testWidgets('a timed-out send retried by the user is not duplicated', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final api = _SlowSpy();
    final sv = await makeServices(t, api: api);
    await t.pumpWidget(LumoraApp(services: sv));
    await settle(t);
    final conv = sv.chat.sorted.firstWhere((c) => !c.isGroup && !c.isSaved).id;
    sv.nav.openConv(conv);
    Navigator.of(t.element(find.byType(Scaffold).first)).push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: conv)));
    await settle(t);
    final before = (await t.runAsync(() => api.messages(conv, limit: 500)))!.length;

    Future<void> real() async {
      for (var i = 0; i < 4; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    await t.enterText(find.byType(TextField).last, 'Chuyển khoản xong rồi nhé');
    await settle(t, frames: 4); // send button animates in
    await t.tap(find.byTooltip('Gửi'));
    await real();
    // timed out: the text is back in the box and the user sends it again
    await real();
    expect(find.textContaining('không bị gửi hai lần'), findsOneWidget, reason: 'says a retry is safe');
    final field = t.widget<TextField>(find.byType(TextField).last);
    expect(field.controller!.text, 'Chuyển khoản xong rồi nhé', reason: 'text is back after the timeout (ids so far: ${api.ids})');
    // the notice sits over the composer for a moment
    await t.pump(const Duration(seconds: 6));
    await settle(t, frames: 4);
    await t.tap(find.byTooltip('Gửi'));
    await real();

    expect(api.ids.length, 2);
    expect(api.ids[0], isNotNull);
    expect(api.ids[1], api.ids[0], reason: 'the retry reuses the first id');
    final after = (await t.runAsync(() => api.messages(conv, limit: 500)))!;
    expect(after.length, before + 1, reason: 'one message, not two');
    expect(sv.chat.thread(conv).messages.where((m) => m.body == 'Chuyển khoản xong rồi nhé').length, 1);

    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(t);
  });

  testWidgets('"You:" follows last_mine from the first load', (t) async {
    final api = MockLumoraApi(timers: false);
    final sv = await makeServices(t, api: api);
    var checked = 0;
    for (final c in sv.chat.convs.values.where((c) => !c.id.contains('#')).toList()) {
      final msgs = await t.runAsync(() => api.messages(c.id, limit: 1));
      if (msgs == null || msgs.isEmpty || c.lastText.isEmpty) continue;
      // where the preview is the last message itself, the flag says who wrote it
      if (msgs.last.kind == 'text' && msgs.last.body == c.lastText) expect(c.lastMine, msgs.last.mine, reason: c.id);
      if (c.lastMine) checked++;
    }
    expect(checked, greaterThan(0), reason: 'the demo has chats whose last message is mine');
    // the parser reads the core's field
    expect(Conversation.fromJson({'id': 'd:x', 'last_text': 'hi', 'last_mine': true}).lastMine, isTrue);
    expect(Conversation.fromJson({'id': 'd:x', 'last_text': 'Bạn: hi'}).lastMine, isFalse);
    sv.dispose();
  });
}
