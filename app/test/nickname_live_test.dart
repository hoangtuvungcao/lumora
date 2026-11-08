// A nickname I set shows at once on the messages already on screen (group chat sender
// labels), not only after the chat is opened again.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/ui/chats/chat_view.dart';

import 'helpers.dart';

Future<void> _flush(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await settle(t);
}

void main() {
  setUpAll(loadFonts);

  testWidgets('group chat: renaming a friend relabels their messages on screen', (t) async {
    setSize(t, const Size(500, 900));
    final sv = await makeServices(t);
    final g = sv.chat.sorted.firstWhere((c) => c.isGroup).id;
    sv.nav.openConv(g);
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: ChatView(conv: g))));
    await _flush(t);
    await _flush(t);
    // a friend whose name labels one of the messages on screen
    final friend = sv.contacts.friends.firstWhere((c) => find.text(c.displayName).evaluate().isNotEmpty);
    await t.runAsync(() => sv.contacts.rename(friend.peer, 'Biệt Danh Mới'));
    await _flush(t);
    expect(find.text('Biệt Danh Mới'), findsWidgets);
    expect(find.text(friend.name), findsNothing, reason: 'the old name is gone from the open chat');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(t);
  });
}
