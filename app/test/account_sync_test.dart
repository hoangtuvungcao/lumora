// Account state that follows the user to every device: the BotFather chat
// (kept by the core, not just the open screen) and locked chats (an account
// setting: locked on the phone = hidden, without notification text, on the
// laptop too). The PIN itself stays per device.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/app_lock.dart';
import 'package:lumora/state/settings.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/bots/botfather.dart';

import 'helpers.dart';

Future<void> _flush(WidgetTester t) async {
  await t.pump(const Duration(milliseconds: 50)); // calls made from the test's (fake-time) zone
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await t.pump();
  await t.pump();
}

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

void main() {
  setUpAll(loadFonts);

  group('BotFather chat', () {
    testWidgets('the conversation is still there after leaving the chat', (t) async {
      final api = MockLumoraApi(timers: false);
      final sv = await makeServices(t, api: api);
      setSize(t, const Size(500, 900));
      Future<void> open() async {
        await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: BotFatherChat(embedded: true)), overlays: false));
        await settle(t);
        await _flush(t);
      }

      await open();
      await t.tap(find.widgetWithText(ActionChip, '/help'));
      await settle(t);
      await _flush(t);
      expect(find.textContaining('Bot là tài khoản do chương trình'), findsOneWidget);

      // leave, come back: the core kept it
      await t.pumpWidget(const SizedBox());
      await t.pump();
      await open();
      expect(find.text('/help'), findsWidgets);
      expect(find.textContaining('Bot là tài khoản do chương trình'), findsOneWidget);
      final saved = await t.runAsync(api.botfatherHistory);
      expect(saved!.map((e) => e['text']), containsAllInOrder(['/help', contains('Bot là tài khoản')]));
      expect(saved.last['kind'], 'docs');
      await _done(t, sv);
    });

    testWidgets('a created bot: the saved line keeps no token, the card shows the current one', (t) async {
      final api = MockLumoraApi(timers: false);
      final sv = await makeServices(t, api: api);
      setSize(t, const Size(500, 900));
      await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: BotFatherChat(embedded: true)), overlays: false));
      await settle(t);
      await t.tap(find.widgetWithText(ActionChip, '/newbot'));
      await settle(t);
      await t.enterText(find.byType(TextField), 'Shop');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await settle(t);
      await t.enterText(find.byType(TextField), 'shop_bot');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await settle(t);
      await _flush(t);
      final saved = (await t.runAsync(api.botfatherHistory))!;
      final created = saved.last;
      expect(created['kind'], 'token');
      expect(created['u'], 'shop_bot');
      expect(jsonEncode(saved), isNot(contains('lumora_bot_')), reason: 'tokens never go into the synced chat');

      // reopened: the token card is back (hidden), with the bot's current token
      await t.pumpWidget(const SizedBox());
      await t.pump();
      await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: BotFatherChat(embedded: true)), overlays: false));
      await settle(t);
      await _flush(t);
      await settle(t);
      expect(find.byType(TokenCard), findsOneWidget);
      expect(find.text('•' * 32), findsOneWidget);
      await _done(t, sv);
    });
  });

  group('locked chats follow the account', () {
    testWidgets('locked on another device: hidden here at once, notices without text', (t) async {
      final api = MockLumoraApi(timers: false);
      final sv = await makeServices(t, api: api);
      final conv = sv.chat.convs.values.firstWhere((c) => c.id.startsWith('d:') && !c.isSaved).id;
      expect(sv.appLock.isChatHidden(conv), isFalse);

      api.lockedChatsFromOtherDevice([conv]);
      await _flush(t);
      expect(sv.settings.lockedChats, contains(conv), reason: 'the cache follows the account setting');
      expect(sv.appLock.isChatHidden(conv), isTrue);

      api.emitForTest('mention', {'conv': conv, 'id': 'ab', 'author': 'x', 'text': 'secret plan', 'locked': true});
      await _flush(t);
      final n = sv.notices.items.first;
      expect(n.kind, NoticeKind.system);
      expect('${n.title} ${n.body}', isNot(contains('secret')));

      // unlocked on the other device
      api.lockedChatsFromOtherDevice([]);
      await _flush(t);
      expect(sv.appLock.isChatLocked(conv), isFalse);
      await _done(t, sv);
    });

    testWidgets('a message marked locked hides the chat before the list arrives', (t) async {
      final api = MockLumoraApi(timers: false);
      final sv = await makeServices(t, api: api);
      api.emitForTest('message', {'conv': 'd:FROMPHONE', 'id': 'aa', 'author': 'x', 'kind': 'text', 'body': {'text': 'hi'}, 'locked': true});
      await _flush(t);
      expect(sv.appLock.isChatHidden('d:FROMPHONE'), isTrue);
      await _done(t, sv);
    });

    testWidgets('locking here saves the account setting', (t) async {
      final api = MockLumoraApi(timers: false);
      final sv = await makeServices(t, api: api);
      sv.appLock.setChatLocked('d:MINE', true);
      await _flush(t);
      expect(await t.runAsync(api.lockedChatsGet), ['d:MINE']);
      sv.appLock.setChatLocked('d:MINE', false);
      await _flush(t);
      expect(await t.runAsync(api.lockedChatsGet), isEmpty, reason: '"nothing locked" is synced too');
      await _done(t, sv);
    });
  });

  group('migration', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('lumora-locks'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test("this device's list joins the account's once; the per-device copy goes", () async {
      final api = MockLumoraApi(timers: false);
      await api.uiSecretSet(AppLock.chatsKey, jsonEncode(['d:OLD']));
      api.lockedChatsFromOtherDevice(['g:PHONE']);
      final st = await Settings.load(File('${tmp.path}/ui_settings.json'));
      final lock = AppLock(st, api: api);
      await lock.loadSecrets();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(st.lockedChats.toSet(), {'d:OLD', 'g:PHONE'});
      expect((await api.lockedChatsGet())!.toSet(), {'d:OLD', 'g:PHONE'});
      expect(await api.uiSecretGet(AppLock.chatsKey), isNull);
      lock.detach();
    });

    test('a list only in the settings file (older version) moves into the account setting', () async {
      final api = MockLumoraApi(timers: false);
      final f = File('${tmp.path}/ui_settings.json');
      await f.writeAsString(jsonEncode({'locked_chats': ['d:FILE']}));
      final st = await Settings.load(f);
      final lock = AppLock(st, api: api);
      await lock.loadSecrets();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await api.lockedChatsGet(), ['d:FILE']);
      lock.detach();
    });

    test('once the account has a list, the settings file is only a cache', () async {
      final api = MockLumoraApi(timers: false);
      api.lockedChatsFromOtherDevice(['d:REAL']);
      final f = File('${tmp.path}/ui_settings.json');
      await f.writeAsString(jsonEncode({'locked_chats': ['d:EDITED']}));
      final st = await Settings.load(f);
      final lock = AppLock(st, api: api);
      await lock.loadSecrets();
      expect(st.lockedChats, ['d:REAL']);
      lock.detach();
    });
  });
}
