// Settings › Privacy (who can see your IP address, "find me by ID"), the phone QR
// scanner hook of the new device's link screen, making a passphrase-protected linked
// device the main one, the "sent through your main device" hint and the
// "added a new device" line in a friend's chat.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/devices/link_join.dart';
import 'package:lumora/ui/devices/my_devices.dart';
import 'package:lumora/ui/devices/qr_scan.dart';
import 'package:lumora/ui/onboarding/onboarding_screen.dart';
import 'package:lumora/ui/settings/settings_screen.dart';
import 'package:lumora/ui/widgets/common.dart' show SwitchRow;
import 'package:lumora/ui/widgets/secure_input.dart';

import 'helpers.dart';

MockLumoraApi _mock(AppServices sv) => sv.api as MockLumoraApi;

Future<void> _flush(WidgetTester t, {int frames = 4}) async {
  for (var i = 0; i < 2; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await settle(t, frames: frames);
  }
}

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

Finder _codeField() => find.descendant(of: find.byType(LinkCodeInput), matching: find.byType(TextField));

void main() {
  setUpAll(loadFonts);

  for (final lang in ['vi', 'en']) {
    testWidgets('privacy: who can see your IP, find me by ID ($lang)', (t) async {
      setSize(t, const Size(1440, 900));
      final sv = await makeServices(t, locale: lang);
      await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SettingsSubPage(page: SettingsPage.privacy)), overlays: false));
      await _flush(t);
      final vi = lang == 'vi';
      expect(find.byType(IpPrivacyCard), findsOneWidget);
      expect(find.text(vi ? 'Ai có thể thấy địa chỉ IP của bạn' : 'Who can see your IP address'), findsOneWidget);
      for (final w in vi
          ? ['Bạn bè, và người bạn gửi lời mời kết bạn', 'Thành viên trong nhóm bạn tham gia', 'Bot bạn dùng', 'Người bạn cho phép điều khiển máy tính từ xa', 'Người lạ thì không']
          : ['Friends, and people you send a friend request to', 'Members of groups you are in', 'Bots you use', 'Someone you let control your computer', "Strangers can't"]) {
        expect(find.text(w), findsOneWidget, reason: w);
      }
      // no network jargon in the explainer
      final card = find.byType(IpPrivacyCard);
      for (final jargon in ['relay', 'DHT', 'NAT', 'peer']) {
        expect(find.descendant(of: card, matching: find.textContaining(jargon)), findsNothing, reason: jargon);
      }

      final title = vi ? 'Cho người lạ tìm thấy tôi bằng ID' : 'Let strangers find me by ID';
      expect(find.text(title), findsOneWidget);
      expect(find.text(vi ? 'Ai biết ID 9 số của bạn đều có thể tìm thấy bạn' : 'Anyone with your 9-digit ID can find you'), findsOneWidget);
      final sw = find.descendant(of: find.ancestor(of: find.text(title), matching: find.byType(SwitchRow)), matching: find.byType(Switch));
      expect(t.widget<Switch>(sw).value, isTrue);

      await t.ensureVisible(find.text(title));
      await t.tap(find.text(title));
      await _flush(t);
      expect(t.widget<Switch>(sw).value, isFalse);
      final core = await t.runAsync(() => sv.api.settingsGet());
      expect(core!['discoverable_by_id'], isFalse);
      expect(find.textContaining(vi ? 'Bạn bè vẫn liên lạc được' : 'Friends still reach you'), findsOneWidget);

      await t.tap(find.text(title));
      await _flush(t);
      expect((await t.runAsync(() => sv.api.settingsGet()))!['discoverable_by_id'], isTrue);
      await _done(t, sv);
    });
  }

  group('new device: phone QR scanner hook', () {
    final saved = linkQrScanner;
    tearDown(() => linkQrScanner = saved);

    Future<AppServices> pumpJoin(WidgetTester t) async {
      setSize(t, const Size(390, 844), dpr: 2);
      final sv = await makeServices(t, start: false);
      await t.pumpWidget(LumoraApp(services: sv, home: const OnboardingScreen(initialStep: 7), overlays: false));
      await settle(t);
      return sv;
    }

    testWidgets('desktop-only builds (no scanner) keep the code and paste', (t) async {
      linkQrScanner = null;
      final sv = await pumpJoin(t);
      expect(find.text('Quét mã QR'), findsNothing);
      expect(find.text('Dán mã'), findsOneWidget);
      expect(find.byType(LinkCodeInput), findsOneWidget);
      await _done(t, sv);
    });

    testWidgets('a scanned link goes straight to "confirm on the other device"', (t) async {
      String? asked;
      linkQrScanner = (ctx) async {
        asked = 'yes';
        return 'lumora://link/v1/abcdef';
      };
      final sv = await pumpJoin(t);
      expect(find.text('Quét mã QR'), findsOneWidget);
      expect(find.text('Hoặc nhập mã 12 số'), findsOneWidget);
      expect(find.byType(LinkCodeInput), findsOneWidget, reason: 'the code stays as a fallback');
      await t.tap(find.text('Quét mã QR'));
      await _flush(t);
      expect(asked, 'yes');
      expect(find.text('Hãy xác nhận trên Điện thoại của Lan'), findsOneWidget);
      await _done(t, sv);
    });

    testWidgets('closed scanner, wrong QR, camera unavailable', (t) async {
      String? next;
      Object? fail;
      linkQrScanner = (ctx) async {
        if (fail != null) throw fail;
        return next;
      };
      final sv = await pumpJoin(t);
      // closed: nothing happens
      await t.tap(find.text('Quét mã QR'));
      await _flush(t);
      expect(find.byType(LinkCodeInput), findsOneWidget);
      expect(find.byType(SecureMessage), findsNothing);
      // something that isn't a link code
      next = 'https://example.com';
      await t.tap(find.text('Quét mã QR'));
      await _flush(t);
      expect(find.text('Đây không phải mã liên kết. Hãy kiểm tra 12 chữ số trên thiết bị kia.'), findsOneWidget);
      // the camera can't open: plain words, the code still works
      fail = StateError('camera');
      await t.tap(find.text('Quét mã QR'));
      await _flush(t);
      expect(find.text('Không mở được camera. Bạn có thể nhập mã 12 số.'), findsOneWidget);
      await t.enterText(_codeField(), '482103975512');
      await _flush(t);
      expect(find.text('Hãy xác nhận trên Điện thoại của Lan'), findsOneWidget);
      await _done(t, sv);
    });

    testWidgets('camera permission refused: what to do, in plain words', (t) async {
      setSize(t, const Size(390, 844), dpr: 2);
      final sv = await makeServices(t, start: false, theme: ThemeMode.light);
      await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: QrCameraIssue(denied: true)), overlays: false));
      await settle(t);
      expect(find.text('Lumora cần dùng camera để quét mã'), findsOneWidget);
      expect(find.text('Mở Cài đặt'), findsOneWidget);
      expect(find.text('Nhập mã 12 số'), findsOneWidget);
      await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: QrCameraIssue(denied: false)), overlays: false));
      await settle(t);
      expect(find.text('Không mở được camera'), findsOneWidget);
      expect(find.text('Mở Cài đặt'), findsNothing);
      await _done(t, sv);
    });
  });

  testWidgets('make main on a passphrase-protected linked device asks for the passphrase', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await makeServices(t);
    _mock(sv).debugMakeLinkedDevice();
    await t.runAsync(() async {
      await sv.api.request('change_passphrase', {'old': '', 'new': 'hoa-sen-2026'});
      await sv.session.reloadMe();
      await sv.devices.load();
    });
    expect(sv.session.me!.protection, 'passphrase');
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SettingsSubPage(page: SettingsPage.devices)), overlays: false));
    await settle(t);
    showPromoteDialog(t.element(find.byType(Scaffold).first));
    await settle(t);
    expect(find.text('Mật khẩu mở Lumora trên thiết bị này'), findsOneWidget);

    final phrase = find.descendant(of: find.byType(RecoveryPhraseInput), matching: find.byType(TextField)).first;
    await t.enterText(phrase, kMockRecoveryPhrase);
    await settle(t);
    final button = find.widgetWithText(SecurePrimaryButton, 'Đặt làm thiết bị chính');
    expect(t.widget<SecurePrimaryButton>(button).onPressed, isNull, reason: 'the passphrase is still missing');

    final pass = find.descendant(of: find.byType(PasswordField), matching: find.byType(TextField));
    await t.enterText(pass, 'sai-roi');
    await settle(t);
    await t.ensureVisible(button);
    await settle(t);
    await t.tap(button);
    await _flush(t);
    expect(find.text('Mật khẩu chưa đúng. Hãy thử lại.'), findsOneWidget);
    expect(_mock(sv).restarts, 0);

    await t.enterText(pass, 'hoa-sen-2026');
    await settle(t);
    await t.ensureVisible(button);
    await settle(t);
    await t.tap(button);
    await _flush(t, frames: 6);
    expect(_mock(sv).lastPromotePassphrase, 'hoa-sen-2026');
    expect(_mock(sv).restarts, 1);
    await _done(t, sv);
  });

  testWidgets('make main without a passphrase: no extra field', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await makeServices(t);
    _mock(sv).debugMakeLinkedDevice();
    await t.runAsync(() => sv.devices.load());
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SettingsSubPage(page: SettingsPage.devices)), overlays: false));
    await settle(t);
    showPromoteDialog(t.element(find.byType(Scaffold).first));
    await settle(t);
    expect(find.byType(PasswordField), findsNothing);
    await t.enterText(find.descendant(of: find.byType(RecoveryPhraseInput), matching: find.byType(TextField)).first, kMockRecoveryPhrase);
    await settle(t);
    await t.ensureVisible(find.widgetWithText(SecurePrimaryButton, 'Đặt làm thiết bị chính'));
    await settle(t);
    await t.tap(find.widgetWithText(SecurePrimaryButton, 'Đặt làm thiết bị chính'));
    await _flush(t, frames: 6);
    expect(_mock(sv).restarts, 1);
    expect(_mock(sv).lastPromotePassphrase, isNull);
    await _done(t, sv);
  });

  for (final lang in ['vi', 'en']) {
    testWidgets('friend chat: "sent through your main device" + "added a new device" ($lang)', (t) async {
      setSize(t, const Size(1440, 900));
      final sv = await makeServices(t, locale: lang);
      final friend = sv.contacts.friends.first;
      final conv = 'd:${friend.peer}';
      sv.nav.openConv(conv);
      await t.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: ChatView(conv: conv)), overlays: false));
      await _flush(t);
      final vi = lang == 'vi';
      final hint = vi ? 'Gửi qua thiết bị chính của bạn' : 'Sent through your main device';
      expect(find.text(hint), findsNothing);

      _mock(sv).simulateBridgedFriend(friend.peer);
      await _flush(t);
      expect(sv.contacts[friend.peer]!.bridged, isTrue);
      expect(find.text(hint), findsOneWidget);
      expect(find.byType(BridgedHint), findsOneWidget);

      _mock(sv).simulateContactDeviceAdded(friend.peer);
      await _flush(t);
      final name = friend.displayName;
      expect(
        find.text(vi ? '$name vừa thêm một thiết bị mới. Mã bảo mật đã thay đổi.' : '$name added a new device. Their security code changed.'),
        findsOneWidget,
      );

      _mock(sv).simulateBridgedFriend(friend.peer, bridged: false);
      await _flush(t);
      expect(find.text(hint), findsNothing);
      await _done(t, sv);
    });
  }
}
