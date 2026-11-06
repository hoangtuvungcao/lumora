import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/ui/widgets/recovery_phrase.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/l10n/strings.dart';
import 'package:lumora/l10n/strings_data.dart';
import 'package:lumora/state/settings.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/shell/home_shell.dart';

import 'helpers.dart';

Future<void> _done(WidgetTester tester, AppServices sv) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  sv.dispose();
  resetSize(tester);
}

void main() {
  setUpAll(loadFonts);

  test('every string has VI and EN translations', () {
    for (final e in kStrings.entries) {
      expect(e.value.length, 2, reason: e.key);
      expect(e.value.every((v) => v.trim().isNotEmpty), isTrue, reason: e.key);
    }
    expect(S.en('chats'), 'Chats');
    expect(S.vn('chats'), 'Trò chuyện');
    expect(S.en('typing_named', {'name': 'An'}), 'An is typing…');
  });

  test('models parse api.md JSON shapes', () {
    final m = Message.fromJson({
      'id': 'a' * 32, 'conv': 'd:x', 'author': 'x', 'hlc': 5, 'ts': 1, 'kind': 'system',
      'body': {'code': 'sys.member_left', 'args': {'actor': 'x'}, 'text': 'x left'},
      'status': 2, 'reactions': {'👍': ['x']}, 'mine': false,
    });
    expect(m.status, MessageStatus.delivered);
    expect(SystemText.parse(m.body)!.code, 'sys.member_left');
    final f = FileItem.fromJson({'id': 'f', 'conv': 'd:x', 'peer': 'x', 'name': 'a.png', 'size': 100, 'direction': 1, 'state': 1, 'progress': 25});
    expect(f.incoming, isTrue);
    expect(f.fraction, 0.25);
    final n = NetStatus.fromJson({'nat': 'symmetric', 'upnp': false, 'relays': [{'url': 'wss://r', 'connected': true}], 'peers': [{'peer': 'p', 'path': 'direct', 'rtt_ms': 20}]});
    expect(n.online, isTrue);
    expect(n.peers.single.rttMs, 20);
  });

  test('mock API uses the v1 argument names', () async {
    final api = MockLumoraApi(timers: false);
    await api.start({});
    final conv = (await api.conversations()).first.id;
    final msg = await api.sendText(conv, 'hello');
    await api.editMessage(conv, msg.id, 'edited');
    final msgs = await api.messages(conv);
    expect(msgs.last.body, 'edited');
    expect(await api.addContact('123456789'), isNotEmpty);
    await api.setRetention(conv, 'session');
    expect(await api.getRetention(conv), 'session');
    await api.stop();
  });

  testWidgets('desktop: chat list → open conversation → send message', (tester) async {
    setSize(tester, const Size(1440, 900));
    final sv = await makeServices(tester);
    await tester.pumpWidget(LumoraApp(services: sv, overlays: false));
    await tester.pump();
    sv.session.setPhase(SessionPhase.ready);
    await settle(tester);

    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.text('Trò chuyện'), findsWidgets);
    expect(find.text('Gia đình 🏡'), findsOneWidget);

    // Filter: groups only.
    await tester.tap(find.text('Nhóm'));
    await settle(tester, frames: 3);
    expect(find.text('Nguyễn Minh Anh'), findsNothing);
    await tester.tap(find.text('Tất cả'));
    await settle(tester, frames: 3);

    await tester.tap(find.text('Trần Bảo Ngọc'));
    await settle(tester);
    expect(find.byType(ChatView), findsOneWidget);
    expect(find.text('Màu tím với xanh cyan hợp nhau ghê'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'Xin chào từ test');
    await settle(tester, frames: 4);
    await tester.tap(find.byTooltip('Gửi'));
    await settle(tester);
    expect(find.text('Xin chào từ test'), findsOneWidget);
    await _done(tester, sv);
  });

  testWidgets('friends: accept incoming request', (tester) async {
    setSize(tester, const Size(1440, 900));
    final sv = await makeServices(tester);
    sv.nav.go(Section.friends);
    await tester.pumpWidget(LumoraApp(services: sv, home: const HomeShell(), overlays: false));
    await settle(tester);
    expect(sv.contacts.pendingCount, 1);
    await tester.tap(find.textContaining('Lời mời').first);
    await settle(tester);
    expect(find.text('Ngô Thanh Tâm'), findsOneWidget);
    await tester.tap(find.byTooltip('Chấp nhận'));
    await settle(tester);
    expect(sv.contacts.pendingCount, 0);
    await _done(tester, sv);
  });

  testWidgets('remote request overlay: deny clears it', (tester) async {
    setSize(tester, const Size(1440, 900));
    final sv = await makeServices(tester);
    await tester.pumpWidget(LumoraApp(services: sv, home: const HomeShell()));
    final f = sv.contacts.friends.first;
    sv.remote.onRequest({'session': 's', 'peer': f.peer, 'name': f.name, 'view_only': false});
    await settle(tester);
    expect(find.text('Yêu cầu truy cập từ xa'), findsOneWidget);
    await tester.tap(find.text('Từ chối'));
    await settle(tester);
    expect(sv.remote.request, isNull);
    expect(find.text('Yêu cầu truy cập từ xa'), findsNothing);
    await _done(tester, sv);
  });

  testWidgets('incoming call overlay → accept → call screen', (tester) async {
    setSize(tester, const Size(1440, 900));
    final sv = await makeServices(tester);
    await tester.pumpWidget(LumoraApp(services: sv, home: const HomeShell()));
    final p = sv.contacts.friends.first.peer;
    sv.calls.onCall({'call_id': 'c', 'conv': 'd:$p', 'peer': p, 'state': 'incoming', 'video': false, 'participants': [p]});
    await settle(tester);
    expect(find.text('Cuộc gọi thoại đến'), findsOneWidget);
    await tester.tap(find.byTooltip('Chấp nhận'));
    await settle(tester);
    expect(sv.calls.call?.phase, CallPhase.active);
    expect(find.byTooltip('Kết thúc cuộc gọi'), findsOneWidget);
    await tester.tap(find.byTooltip('Kết thúc cuộc gọi'));
    await settle(tester);
    expect(sv.calls.call, isNull);
    await _done(tester, sv);
  });

  testWidgets('language switch to English updates UI', (tester) async {
    setSize(tester, const Size(390, 844), dpr: 2);
    final sv = await makeServices(tester);
    await tester.pumpWidget(LumoraApp(services: sv, home: const HomeShell(), overlays: false));
    await settle(tester);
    expect(find.text('Trò chuyện'), findsWidgets);
    sv.settings.update((s) => s.locale = 'en');
    await settle(tester);
    expect(find.text('Chats'), findsWidgets);
    expect(find.text('Trò chuyện'), findsNothing);
    await _done(tester, sv);
  });

  testWidgets('onboarding creates identity and shows recovery phrase', (tester) async {
    setSize(tester, const Size(1440, 900));
    final api = MockLumoraApi(timers: false);
    final sv = AppServices(api: api, settings: Settings()..locale = 'en', dataDir: '/tmp/x');
    await tester.pumpWidget(LumoraApp(services: sv, overlays: false));
    await tester.runAsync(sv.boot);
    await settle(tester);
    // Language & theme come first.
    expect(find.text('Welcome to Lumora'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await settle(tester);
    expect(find.text('Create new identity'), findsOneWidget);
    await tester.tap(find.text('Create new identity'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Lan');
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await settle(tester);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'blue river 2026');
    await tester.enterText(fields.at(1), 'blue river 2026');
    await tester.tap(find.text('Create new identity'));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await settle(tester);
    expect(find.text('Save your recovery phrase'), findsOneWidget);
    expect(sv.settings.phraseBackedUp, isFalse);
    await tester.tap(find.text('I’ve written it down'));
    await settle(tester);
    // "Check your copy": three words asked by position
    final words = (await tester.runAsync(() => api.recoveryPhrase()))!.split(' ');
    final asked = [
      for (final t in tester.widgetList<Text>(find.descendant(of: find.byType(PhraseVerify), matching: find.byType(Text))))
        if (RegExp(r'^Word (\d+)$').hasMatch(t.data ?? '')) int.parse(t.data!.substring(5)) - 1,
    ];
    expect(asked, hasLength(3));
    final boxes = find.descendant(of: find.byType(PhraseVerify), matching: find.byType(TextField));
    for (var i = 0; i < 3; i++) {
      await tester.enterText(boxes.at(i), words[asked[i]]);
    }
    await tester.pump();
    await tester.tap(find.text('Check'));
    await settle(tester, frames: 12);
    expect(sv.settings.phraseBackedUp, isTrue);
    expect(find.byType(HomeShell), findsOneWidget);
    expect(sv.settings.hasPassphrase, isTrue);
    expect(sv.session.me?.name, 'Lan');
    await _done(tester, sv);
  });
}
