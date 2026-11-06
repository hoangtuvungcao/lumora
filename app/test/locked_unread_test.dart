// Security audit follow-up: the unread count must not reveal activity in
// locked chats; the "Locked" folder shows a neutral dot instead.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/ui/lock/app_lock_screen.dart';
import 'package:lumora/ui/theme.dart';
import 'package:provider/provider.dart';

import 'helpers.dart';

void main() {
  testWidgets('locked chats are left out of the unread badge; the folder shows a dot', (tester) async {
    final sv = await makeServices(tester);
    final chat = sv.chat;
    chat.convs
      ..clear()
      ..['d:OPEN'] = const Conversation(id: 'd:OPEN', kind: ConvKind.direct, title: 'Open', unread: 2)
      ..['d:SECRET'] = const Conversation(id: 'd:SECRET', kind: ConvKind.direct, title: 'Secret', unread: 5);
    expect(chat.totalUnread, 7);
    sv.appLock.setPin('2580', appLock: false); // hash finishes on the next pump
    await tester.pump();
    sv.appLock.setChatLocked('d:SECRET', true);
    expect(chat.totalUnread, 2, reason: 'unread count reveals activity in a locked chat');
    expect(chat.lockedUnread, isTrue);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: sv.appLock),
        ChangeNotifierProvider.value(value: sv.settings),
      ],
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: LockedChatsFolder(count: 1, unread: true))),
    ));
    expect(find.byKey(const ValueKey('locked-unread-dot')), findsOneWidget);
    expect(find.text('5'), findsNothing, reason: 'no number on the folder');
    await tester.pump(const Duration(seconds: 3));
    sv.dispose();
  });
}
