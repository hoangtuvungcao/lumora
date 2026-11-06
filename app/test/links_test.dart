// Lumora QR codes and links (lib/core/links.dart): the parser, the shared
// https form in every share UI, the routing of links from outside the app
// (waiting for onboarding / unlock / the app lock) and the in-app scanner.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/links.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/devices/qr_scan.dart' show lumoraQrScanner;
import 'package:lumora/ui/flows.dart';
import 'package:lumora/ui/friends/add_friend.dart';
import 'package:lumora/ui/groups/invite.dart';
import 'package:lumora/ui/profile/profile_screen.dart' show showShareProfile;
import 'package:lumora/ui/shell/home_shell.dart';

import 'helpers.dart';

const _peer = 'abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrst';

class _Spy extends MockLumoraApi {
  _Spy() : super(timers: false);
  final adds = <String>[];
  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) {
    if (cmd == 'add_contact') adds.add('${args['target']}');
    return super.request(cmd, args);
  }
}

Future<AppServices> _app(WidgetTester t, {_Spy? api, bool start = true}) async {
  await loadFonts();
  setSize(t, const Size(1440, 900));
  final sv = await makeServices(t, api: api ?? _Spy(), start: start);
  sv.settings.showTour = false;
  if (!start) sv.session.setPhase(SessionPhase.onboarding);
  await t.pumpWidget(LumoraApp(services: sv));
  await settle(t);
  return sv;
}

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
  sv.dispose();
  resetSize(t);
  pendingDeepLink.value = null;
}

BuildContext _ctx(WidgetTester t) => t.element(find.byType(HomeShell));

/// A text field currently holding [text] (not just showing it as a hint).
Finder _holding(String text) => find.byWidgetPredicate((w) => w is TextField && w.controller?.text == text);

String _field(WidgetTester t) => t.widget<TextField>(find.descendant(of: find.byType(AddFriendForm), matching: find.byType(TextField)).first).controller!.text;

void main() {
  group('LumoraLink.parse', () {
    test('add: https and lumora://, full ID with / without the 9-digit ID', () {
      final a = LumoraLink.parse('https://getlumora.pages.dev/add/$_peer?id=123456789')!;
      expect((a.kind, a.peer, a.shortId), (LinkKind.add, _peer, '123456789'));
      expect(a.https, 'https://getlumora.pages.dev/add/$_peer?id=123456789');
      expect(a.app, 'lumora://add/$_peer?id=123456789');
      expect(LumoraLink.parse('  HTTPS://GetLumora.pages.dev/add/${_peer.toUpperCase()}/  '), LumoraLink.parse('lumora://add/$_peer'));
      expect(LumoraLink.parse('https://www.getlumora.pages.dev/add/$_peer')!.peer, _peer);
      expect(LumoraLink.parse('lumora://add/$_peer')!.shortId, isNull);
      final byId = LumoraLink.parse('lumora://add/123%20456%20789')!;
      expect((byId.peer, byId.shortId), (null, '123456789'));
      expect(LumoraLink.parse('https://getlumora.pages.dev/add/123-456-789')!.https, 'https://getlumora.pages.dev/add/123456789');
    });

    test('join and remote', () {
      final j = LumoraLink.parse('https://getlumora.pages.dev/join/ABCDEF234567')!;
      expect((j.kind, j.token, j.app), (LinkKind.join, 'abcdef234567', 'lumora://join/abcdef234567'));
      expect(LumoraLink.parse('lumora://join/abcdef234567')!.https, 'https://getlumora.pages.dev/join/abcdef234567');
      final r = LumoraLink.parse('lumora://remote/123456789')!;
      expect((r.kind, r.shortId), (LinkKind.remote, '123456789'));
      expect(LumoraLink.parse('https://getlumora.pages.dev/remote/123-456-789')!.app, 'lumora://remote/123456789');
    });

    test('device-link codes are recognised (app form only)', () {
      expect(LumoraLink.parse('lumora://link/v1/abcdef')!.kind, LinkKind.device);
      expect(LumoraLink.parse('https://getlumora.pages.dev/link/v1/abcdef'), isNull);
      expect(LumoraLink.parse('lumora://link/'), isNull);
    });

    test('malformed links are rejected', () {
      for (final bad in [
        '',
        'hello',
        'lumora://add/',
        'lumora://add/short',
        'lumora://add/12345678', // 8 digits
        'lumora://add/$_peer?id=12345', // bad query id
        'lumora://add/123456789?id=987654321', // two different IDs
        'lumora://add/$_peer/extra',
        'lumora://foo/123456789',
        'lumora://join/ab', // too short
        'lumora://join/abc_def-ghij',
        'lumora://remote/12345',
        'lumora://remote/abcdefghi',
        'https://getlumora.pages.dev/',
        'https://getlumora.pages.dev/download/',
        'https://getlumora.pages.dev/remote/123456789/x',
        'https://getlumora.pages.dev.evil.example/add/$_peer',
        'https://evil.example/add/$_peer',
        'https://getlumora.pages.dev:8443/remote/123456789',
        'ftp://getlumora.pages.dev/remote/123456789',
        'lumora://remote/123456789 lumora://remote/987654321',
      ]) {
        expect(LumoraLink.parse(bad), isNull, reason: bad);
      }
    });

    test('find: a link inside text, sentence punctuation dropped', () {
      expect(LumoraLink.find('Kết bạn nhé: https://getlumora.pages.dev/remote/123456789.')!.shortId, '123456789');
      expect(LumoraLink.find('(lumora://join/abcdef234567)')!.token, 'abcdef234567');
      expect(LumoraLink.find('nothing here'), isNull);
      expect(LumoraLink.looksLikeLink('https://getlumora.pages.dev/add/x'), isTrue);
      expect(LumoraLink.looksLikeLink('https://example.com/add/x'), isFalse);
    });

    test('builders produce the shared https form', () {
      expect(LumoraLink.addLink(_peer, shortId: '123 456 789'), 'https://getlumora.pages.dev/add/$_peer?id=123456789');
      expect(LumoraLink.addLink(_peer), 'https://getlumora.pages.dev/add/$_peer');
      expect(LumoraLink.remoteLink('123 456 789'), 'https://getlumora.pages.dev/remote/123456789');
      expect(LumoraLink.shareInvite('lumora://join/abcdef234567'), 'https://getlumora.pages.dev/join/abcdef234567');
      expect(LumoraLink.shareInvite('something else'), 'something else');
      expect(Flows.addLink(_peer, shortId: '123456789'), startsWith('https://getlumora.pages.dev/add/'));
    });
  });

  group('links from outside the app', () {
    test('acceptIncomingLink: device codes and foreign links are dropped, broken Lumora links kept', () {
      expect(acceptIncomingLink('https://getlumora.pages.dev/add/$_peer'), 'https://getlumora.pages.dev/add/$_peer');
      expect(acceptIncomingLink(' lumora://remote/123456789 '), 'lumora://remote/123456789');
      expect(acceptIncomingLink('lumora://link/v1/abcdef'), isNull);
      expect(acceptIncomingLink('LUMORA://LINK/v1/abcdef'), isNull);
      expect(acceptIncomingLink('https://evil.example/add/$_peer'), isNull);
      expect(acceptIncomingLink('--verbose'), isNull);
      expect(acceptIncomingLink(null), isNull);
      expect(acceptIncomingLink('lumora://add/oops'), 'lumora://add/oops', reason: 'gets a friendly message');
      expect(acceptIncomingLink('https://getlumora.pages.dev/join/x'), 'https://getlumora.pages.dev/join/x');
    });

    test('canOpenPendingLink', () {
      expect(canOpenPendingLink(homeReady: true, lockShown: false), isTrue);
      expect(canOpenPendingLink(homeReady: true, lockShown: true), isFalse);
      expect(canOpenPendingLink(homeReady: false, lockShown: false), isFalse);
    });

    testWidgets('an add link waits for onboarding, then opens Add friend filled in; nothing is sent until the tap', (t) async {
      final api = _Spy();
      final sv = await _app(t, api: api, start: false);
      pendingDeepLink.value = 'https://getlumora.pages.dev/add/$_peer?id=123456789';
      await settle(t, frames: 3);
      expect(find.byType(AddFriendForm), findsNothing);
      expect(pendingDeepLink.value, isNotNull, reason: 'queued until the home screen');

      await t.runAsync(() => sv.unlock(null));
      await settle(t);
      expect(pendingDeepLink.value, isNull);
      expect(find.byType(AddFriendForm), findsOneWidget);
      expect(_field(t), _peer);
      expect(find.text('Từ mã QR hoặc liên kết. Kiểm tra rồi bấm “Gửi lời mời”.'), findsOneWidget);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(t, frames: 3);
      expect(api.adds, isEmpty, reason: 'never sent without the user tapping');

      await t.tap(find.text('Gửi lời mời'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(t);
      expect(api.adds, [_peer]);
      await _done(t, sv);
    });

    testWidgets('a remote link waits for the app lock, then opens Remote control with the ID', (t) async {
      final sv = await _app(t);
      sv.appLock.setPin('2580');
      sv.appLock.lock();
      await settle(t, frames: 3);
      pendingDeepLink.value = 'lumora://remote/123456789';
      await settle(t, frames: 3);
      expect(pendingDeepLink.value, isNotNull);
      for (final k in [LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit8, LogicalKeyboardKey.digit0]) {
        await t.sendKeyEvent(k);
      }
      await settle(t, frames: 4);
      expect(sv.appLock.locked, isFalse);
      expect(pendingDeepLink.value, isNull);
      expect(sv.nav.section, Section.remote);
      expect(_holding('123 456 789'), findsOneWidget);
      await _done(t, sv);
    });

    testWidgets('own link, broken link and a device-link code get a message', (t) async {
      final sv = await _app(t);
      final me = sv.session.me!;
      pendingDeepLink.value = LumoraLink.addLink(me.peer, shortId: me.shortId);
      await settle(t, frames: 3);
      expect(find.textContaining('Đây là mã của chính bạn'), findsOneWidget);
      expect(find.byType(AddFriendForm), findsNothing);

      pendingDeepLink.value = 'lumora://add/oops';
      await settle(t);
      expect(find.textContaining('Liên kết hoặc mã QR này không đúng'), findsOneWidget);

      await Flows.openDeepLink(_ctx(t), 'lumora://link/v1/abcdef');
      await settle(t);
      expect(find.textContaining('Đây là mã để liên kết thiết bị'), findsOneWidget);
      await _done(t, sv);
    });
  });

  group('in-app scanner', () {
    final scans = <String?>[];
    setUp(() {
      scans.clear();
      lumoraQrScanner = (_) async => scans.removeAt(0);
    });
    tearDown(() => lumoraQrScanner = null);

    testWidgets('Add friend: fills from a friend code, explains others, hands invites over', (t) async {
      final sv = await _app(t);
      showAddFriend(_ctx(t));
      await settle(t, frames: 4);
      expect(find.text('Quét mã QR'), findsOneWidget);

      scans.add('https://getlumora.pages.dev/add/$_peer?id=123456789');
      await t.tap(find.text('Quét mã QR'));
      await settle(t, frames: 3);
      expect(_field(t), _peer);

      scans.add('lumora://link/v1/abcdef');
      await t.tap(find.text('Quét mã QR'));
      await settle(t);
      expect(find.textContaining('Đây là mã để liên kết thiết bị'), findsOneWidget);

      scans.add('WIFI:S:home;P:secret;;');
      await t.tap(find.text('Quét mã QR'));
      await settle(t);
      expect(find.text('Đây không phải mã QR của Lumora'), findsOneWidget);

      scans.add(null); // closed
      await t.tap(find.text('Quét mã QR'));
      await settle(t, frames: 3);
      expect(find.byType(AddFriendForm), findsOneWidget);

      scans.add('lumora://join/${'a' * 30}');
      await t.tap(find.text('Quét mã QR'));
      await settle(t);
      expect(find.byType(AddFriendForm), findsNothing);
      expect(find.text('Tham gia bằng liên kết'), findsOneWidget, reason: 'the join preview opened instead');
      await _done(t, sv);
    });

    testWidgets('"+" menu scan: a remote code opens Remote control with the ID', (t) async {
      final sv = await _app(t);
      final ctx = _ctx(t);
      scans.add('https://getlumora.pages.dev/remote/987654321');
      await Flows.scanAndOpen(ctx);
      await settle(t);
      expect(sv.nav.section, Section.remote);
      expect(_holding('987 654 321'), findsOneWidget);
      // the Remote card has its own scan button too
      scans.add('lumora://remote/111222333');
      await t.tap(find.text('Quét mã QR').first);
      await settle(t, frames: 3);
      expect(_holding('111 222 333'), findsOneWidget);
      await _done(t, sv);
    });

    testWidgets('Join group: a scanned invite fills the field and is previewed', (t) async {
      final sv = await _app(t);
      showJoinByLink(_ctx(t));
      await settle(t, frames: 4);
      scans.add('https://getlumora.pages.dev/join/${'b' * 30}');
      await t.tap(find.text('Quét mã QR'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(t);
      expect(_holding('https://getlumora.pages.dev/join/${'b' * 30}'), findsOneWidget);
      expect(find.text('Cộng đồng Rust Việt Nam'), findsOneWidget, reason: 'the https link is inspected as the invite');
      await _done(t, sv);
    });
  });

  group('share UIs emit https links', () {
    testWidgets('My ID card, profile share, group invite and remote "Copy link"', (t) async {
      final copied = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
        if (c.method == 'Clipboard.setData') copied.add((c.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final sv = await _app(t);
      final me = sv.session.me!;
      final mine = LumoraLink.addLink(me.peer, shortId: me.shortId);
      expect(mine, 'https://getlumora.pages.dev/add/${me.peer}?id=${me.shortId.replaceAll(' ', '')}');

      showAddFriend(_ctx(t));
      await settle(t, frames: 4);
      await t.tap(find.text('Mã QR của tôi').first);
      await settle(t, frames: 4);
      expect(find.byKey(ValueKey('qr:$mine')), findsOneWidget);
      expect(find.text(me.shortId), findsWidgets, reason: 'the ID to type by hand is next to the QR');
      await t.tap(find.text('Sao chép liên kết'));
      await settle(t, frames: 2);
      expect(copied.last, mine);
      Navigator.of(_ctx(t)).pop();
      await settle(t, frames: 4);

      showShareProfile(_ctx(t), _peer, '123 456 789', 'Lan');
      await settle(t, frames: 4);
      expect(find.byKey(const ValueKey('qr:https://getlumora.pages.dev/add/$_peer?id=123456789')), findsOneWidget);
      Navigator.of(_ctx(t)).pop();
      await settle(t, frames: 4);

      showInvite(_ctx(t), gid: 'g' * 32, name: 'Nhóm');
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(t, frames: 4);
      final qr = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('qr:'));
      expect(qr, findsOneWidget);
      expect((t.widget(qr).key! as ValueKey<String>).value, startsWith('qr:https://getlumora.pages.dev/join/'));
      Navigator.of(_ctx(t)).pop();
      await settle(t, frames: 4);

      sv.nav.go(Section.remote);
      await settle(t, frames: 4);
      await t.tap(find.byTooltip('Sao chép liên kết'));
      await settle(t, frames: 2);
      expect(copied.last, startsWith('https://getlumora.pages.dev/remote/'));
      expect(LumoraLink.parse(copied.last)!.kind, LinkKind.remote);
      await _done(t, sv);
    });
  });
}
