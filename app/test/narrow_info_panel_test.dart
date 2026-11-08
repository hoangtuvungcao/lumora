// Desktop, a narrow window with the chat's info panel open: the panel floats over the chat
// instead of squeezing it (messages one word per line, a broken composer).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/ui/chats/chat_info.dart';
import 'package:lumora/ui/chats/chat_view.dart';

import 'helpers.dart';

void main() {
  setUpAll(loadFonts);

  testWidgets('narrow window + info panel: the composer keeps its width', (t) async {
    setSize(t, const Size(960, 800)); // a desktop window, the chat column ~560 px wide (list on the left)
    final sv = await makeServices(t);
    final conv = sv.chat.sorted.firstWhere((c) => !c.isGroup && !c.isSaved).id;
    sv.nav.openConv(conv);
    sv.nav.toggleInfo(true);
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: Row(children: [const SizedBox(width: 400), Expanded(child: ChatView(conv: conv, embedded: true))]))));
    await settle(t);
    expect(find.byType(ChatInfoPanel), findsOneWidget);
    final field = t.getSize(find.byType(TextField).last);
    expect(field.width, greaterThan(300), reason: 'the composer is not squeezed by the panel');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(t);
  });
}
