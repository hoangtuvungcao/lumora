// Multi-device screens with the mock core: linking on the existing device
// (invite → approval → done), My devices (rename, sign out, linked-device
// view), the new device's onboarding link flow through the restart and the
// history copy, the signed-out notice, calls answered elsewhere, the remote
// device picker and friends' devices.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/l10n/strings.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/chats/chat_info.dart';
import 'package:lumora/ui/devices/approve_sheet.dart';
import 'package:lumora/ui/devices/device_picker.dart';
import 'package:lumora/ui/devices/device_ui.dart';
import 'package:lumora/ui/devices/link_join.dart';
import 'package:lumora/ui/onboarding/onboarding_screen.dart';
import 'package:lumora/ui/settings/settings_screen.dart';
import 'package:lumora/ui/shell/home_shell.dart';

import 'helpers.dart';

MockLumoraApi _mock(AppServices sv) => sv.api as MockLumoraApi;

/// Lets core events through (some subscriptions live in a real-async zone).
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

Future<void> _pumpDevices(WidgetTester t, AppServices sv) async {
  await t.runAsync(() => sv.devices.load());
  await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SettingsSubPage(page: SettingsPage.devices)), overlays: false));
  await settle(t);
}

Finder _codeField() => find.descendant(of: find.byType(LinkCodeInput), matching: find.byType(TextField));

void main() {
  setUpAll(loadFonts);

  test('device models parse the core JSON', () {
    final l = DeviceList.fromJson({
      'account': 'acc',
      'device': 'b',
      'primary': false,
      'version': 3,
      'devices': [
        {'device': 'a', 'name': 'Phone', 'kind': 1, 'primary': true, 'online': true, 'short_id': '123 456 789'},
        {'device': 'b', 'name': '', 'kind': 3, 'this': true, 'added': 5, 'last_seen': 6},
      ],
      'revoked': [
        {'device': 'c', 'name': 'Old'},
      ],
    });
    expect(l.primary, isFalse);
    expect(l.mainDevice!.device, 'a');
    expect(l.thisDevice!.device, 'b');
    expect(l.revoked.single.name, 'Old');
    expect(l.devices.first.shortId, '123 456 789');
    expect(deviceTitle(S.en, l.devices[1]), 'Computer');

    var h = HistoryStatus.fromJson({'active': true, 'done': false, 'messages': 10, 'since_ms': 99});
    h = h.update({'messages': 50, 'convs_done': 2, 'convs_total': 4, 'done': false});
    expect(h.active, isTrue);
    expect(h.fraction, 0.5);
    expect(h.sinceMs, 99);
    h = h.update({'done': true});
    expect(h.active, isFalse);
    expect(h.messages, 50);

    expect(formatLinkCode('123456789012'), '1234-5678-9012');
    final choices = RemoteDeviceChoice.parse(ApiException('x', code: 'err.choose_device', detail: '[{"device":"d1","name":"Laptop","kind":3,"short_id":"1 2 3"}]'));
    expect(choices!.single.name, 'Laptop');
    expect(RemoteDeviceChoice.parse(ApiException('x', code: 'err.other')), isNull);
    expect(deviceError(S.en, ApiException('raw', code: 'err.link_code_wrong')), contains('code isn’t right'));
  });

  testWidgets('link a new device: QR and code, approve with history, done', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await makeServices(t);
    await _pumpDevices(t, sv);
    expect(find.text('Điện thoại của Lan'), findsOneWidget);
    expect(find.text('Thiết bị chính'), findsOneWidget);

    await t.tap(find.text('Liên kết thiết bị mới'));
    await _flush(t);
    expect(find.textContaining('Mã hết hạn sau'), findsOneWidget);
    await t.tap(find.text('Mã 12 số'));
    await settle(t);
    expect(find.text('4821'), findsOneWidget);
    expect(find.text('5512'), findsOneWidget);

    // three wrong attempts on the new device → a fresh code
    _mock(sv).simulateLinkCodeRotated();
    await _flush(t);
    expect(find.text('7305'), findsOneWidget);
    expect(find.textContaining('đã được đổi'), findsOneWidget);

    _mock(sv).simulateLinkRequest();
    await _flush(t);
    expect(find.byType(LinkApprovalCard), findsOneWidget);
    expect(find.text('Laptop ở nhà'), findsOneWidget);
    expect(find.text('Đang ở cùng mạng với bạn'), findsOneWidget);
    await t.tap(find.text('Tất cả'));
    await settle(t, frames: 2);
    expect(find.text('Chép toàn bộ tin nhắn. Có thể mất một lúc.'), findsOneWidget);
    await t.tap(find.text('Cho phép'));
    await _flush(t);
    expect(_mock(sv).lastApprovedHistory, 'all');
    expect(find.text('Đã liên kết Laptop ở nhà'), findsOneWidget);
    expect(sv.devices.list!.devices, hasLength(4));
    await t.tap(find.text('Xong'));
    await settle(t);
    expect(find.text('Laptop ở nhà'), findsOneWidget); // now in the list
    await _done(t, sv);
  });

  testWidgets('declining keeps the invite open', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    await _pumpDevices(t, sv);
    await t.tap(find.text('Liên kết thiết bị mới'));
    await _flush(t);
    _mock(sv).simulateLinkRequest();
    await _flush(t);
    await t.tap(find.text('Từ chối'));
    await _flush(t);
    expect(find.byType(LinkApprovalCard), findsNothing);
    expect(find.text('Đã từ chối thiết bị này'), findsOneWidget);
    expect(find.text('Mã QR'), findsOneWidget);
    expect(sv.devices.list!.devices, hasLength(3));
    await _done(t, sv);
  });

  testWidgets('my devices: rename and sign out another device', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await makeServices(t);
    await _pumpDevices(t, sv);
    await t.tap(find.text('Laptop văn phòng'));
    await settle(t);
    expect(find.text('715 204 389'), findsOneWidget);
    await t.tap(find.text('Đổi tên'));
    await settle(t);
    await t.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'Laptop công ty');
    await t.tap(find.text('Lưu'));
    await _flush(t);
    expect(find.text('Laptop công ty'), findsWidgets);

    await t.tap(find.text('Đăng xuất thiết bị này'));
    await settle(t);
    expect(find.text('Đăng xuất “Laptop công ty”?'), findsOneWidget);
    await t.tap(find.byType(Checkbox));
    await settle(t, frames: 2);
    await t.tap(find.widgetWithText(FilledButton, 'Đăng xuất'));
    await _flush(t);
    expect(sv.devices.list!.devices, hasLength(2));
    expect(sv.devices.list!.revoked.single.name, 'Laptop công ty');
    expect(find.text('Đã đăng xuất Laptop công ty'), findsOneWidget);
    await _done(t, sv);
  });

  testWidgets('linked device: no linking here, make main, sign out', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await makeServices(t);
    _mock(sv).debugMakeLinkedDevice();
    await _pumpDevices(t, sv);
    expect(find.text('Liên kết thiết bị mới'), findsNothing);
    expect(find.textContaining('Thiết bị mới được liên kết từ thiết bị chính của bạn (Điện thoại của Lan)'), findsOneWidget);
    expect(find.text('Đặt làm thiết bị chính'), findsOneWidget);

    // the phrase must belong to this account
    final err = await t.runAsync(() async {
      try {
        await sv.api.devicePromote(List.filled(24, 'abandon').join(' '));
        return null;
      } on ApiException catch (e) {
        return e;
      }
    });
    expect(err?.code, 'err.phrase_mismatch');
    expect(deviceError(S.vn, ApiException('x', code: 'err.phrase_mismatch')), 'Cụm từ này thuộc về một tài khoản khác.');

    await t.tap(find.text('Đặt làm thiết bị chính'));
    await settle(t);
    expect(find.textContaining('Thiết bị chính hiện tại (Điện thoại của Lan) sẽ được đăng xuất'), findsOneWidget);
    await t.tap(find.byTooltip('Đóng'));
    await settle(t);

    // promote through the core: it restarts as the main device
    await t.runAsync(() => sv.api.devicePromote(kMockRecoveryPhrase));
    await _flush(t);
    expect(_mock(sv).restarts, 1);
    expect(sv.devices.isPrimary, isTrue);
    expect(find.text('Liên kết thiết bị mới'), findsOneWidget);
    await _done(t, sv);
  });

  testWidgets('new device: link from onboarding, restart, history, home', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t, start: false);
    sv.settings
      ..onboarded = false
      ..linkPending = true; // reopened mid-way: straight to the link step
    sv.session.setPhase(SessionPhase.onboarding);
    await t.pumpWidget(LumoraApp(services: sv, overlays: false));
    await settle(t);
    expect(find.text('Liên kết với tài khoản của bạn'), findsOneWidget);

    await t.enterText(_codeField(), '0000 0000 0000');
    await _flush(t);
    expect(find.text('Mã chưa đúng. Hãy kiểm tra lại trên thiết bị kia.'), findsOneWidget);
    expect(sv.linkCoreRunning, isTrue);

    await t.enterText(_codeField(), '');
    await t.enterText(_codeField(), '482103975512');
    await _flush(t);
    expect(find.text('Hãy xác nhận trên Điện thoại của Lan'), findsOneWidget);

    _mock(sv).simulateLinkApproved();
    await _flush(t, frames: 6);
    expect(_mock(sv).restarts, 1);
    expect(sv.session.phase, SessionPhase.ready);
    expect(sv.settings.onboarded, isTrue);
    expect(sv.settings.linkPending, isFalse);
    expect(sv.session.me!.primary, isFalse);
    expect(find.text('Đang chép tin nhắn cũ…'), findsOneWidget);

    _mock(sv).simulateHistorySync(420, convsDone: 3, convsTotal: 12);
    await _flush(t);
    expect(find.text('420 tin nhắn'), findsOneWidget);
    _mock(sv).simulateHistorySync(900, convsDone: 12, convsTotal: 12, done: true);
    await _flush(t);
    expect(find.text('Đã chép xong'), findsOneWidget);
    await t.tap(find.text('Bắt đầu'));
    await settle(t);
    expect(find.byType(HomeShell), findsOneWidget);
    await _done(t, sv);
  });

  testWidgets('new device: a pasted link is used as the QR code; back cancels', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await makeServices(t, start: false);
    sv.settings.onboarded = false;
    await t.pumpWidget(LumoraApp(services: sv, home: const OnboardingScreen(initialStep: 0), overlays: false));
    await settle(t);
    await t.tap(find.text('Tôi đã có tài khoản Lumora trên thiết bị khác'));
    await settle(t);
    await t.enterText(_codeField(), 'lumora://link/v1/abcdef');
    await _flush(t);
    expect(find.text('Hãy xác nhận trên Điện thoại của Lan'), findsOneWidget);
    await t.tap(find.text('Huỷ'));
    await _flush(t);
    expect(find.text('Liên kết với tài khoản của bạn'), findsOneWidget);
    await t.tap(find.text('Quay lại'));
    await _flush(t);
    expect(sv.linkCoreRunning, isFalse);
    expect(sv.settings.linkPending, isFalse);
    expect(find.text('Khôi phục tài khoản'), findsOneWidget);
    await _done(t, sv);
  });

  testWidgets('new device: declined on the other device → retry', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t, start: false);
    sv.settings.onboarded = false;
    await t.pumpWidget(LumoraApp(services: sv, home: const OnboardingScreen(initialStep: 7), overlays: false));
    await settle(t);
    await t.enterText(_codeField(), '482103975512');
    await _flush(t);
    _mock(sv).simulateLinkFailed('declined');
    await _flush(t);
    expect(find.text('Yêu cầu đã bị từ chối trên thiết bị kia.'), findsOneWidget);
    await t.tap(find.text('Thử lại'));
    await settle(t);
    expect(find.byType(LinkCodeInput), findsOneWidget);
    await _done(t, sv);
  });

  testWidgets('signed out: calm notice, then back to the welcome screen', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await makeServices(t);
    _mock(sv).debugMakeLinkedDevice();
    await t.pumpWidget(LumoraApp(services: sv, overlays: false));
    await settle(t);
    expect(find.byType(HomeShell), findsOneWidget);
    await t.runAsync(() => sv.api.deviceLogout());
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await _flush(t);
    expect(find.text('Thiết bị này đã được đăng xuất khỏi tài khoản'), findsOneWidget);
    expect(find.textContaining('Bạn đã đăng xuất Lumora trên thiết bị này'), findsOneWidget);
    expect(sv.settings.onboarded, isFalse);
    await t.tap(find.text('Bắt đầu lại'));
    await settle(t);
    expect(find.byType(OnboardingScreen), findsOneWidget);
    await _done(t, sv);
  });

  testWidgets('main device signs out from Settings (no recovery phrase needed); back to welcome', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await makeServices(t);
    await t.runAsync(() => sv.devices.load());
    expect(sv.devices.isPrimary, isTrue);
    await t.runAsync(() async {
      try {
        await sv.api.deviceLogout();
        fail('main device signed out without confirmation');
      } on ApiException catch (e) {
        expect(e.code, 'err.primary_logout');
      }
    });
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SettingsSubPage(page: SettingsPage.security)), overlays: false));
    await settle(t);
    await t.scrollUntilVisible(find.text('Đăng xuất'), 200, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('Đăng xuất'));
    await settle(t);
    expect(find.text('Đăng xuất khỏi thiết bị này?'), findsOneWidget);
    expect(find.textContaining('24 từ khôi phục'), findsWidgets);
    expect(find.byType(Checkbox), findsNothing, reason: 'no phrase quiz to sign out');
    await t.tap(find.widgetWithText(FilledButton, 'Đăng xuất'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await _flush(t);
    expect(sv.devices.signedOut, isNotNull);
    await _done(t, sv);
  });

  testWidgets('incoming call answered on another device: note, no missed call', (t) async {
    setSize(t, const Size(390, 844), dpr: 2);
    final sv = await makeServices(t);
    await t.pumpWidget(LumoraApp(services: sv, home: const HomeShell()));
    await settle(t);
    _mock(sv).simulateIncomingCall();
    await _flush(t);
    expect(sv.calls.incoming, isTrue);
    _mock(sv).simulateCallAnsweredElsewhere(device: 'Laptop');
    await _flush(t, frames: 2);
    expect(find.text('Đã trả lời trên Laptop'), findsOneWidget);
    // the note's timer lives where the event was handled (real time here)
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2600)));
    await settle(t, frames: 4);
    expect(sv.calls.call, isNull);
    expect(find.text('Đã trả lời trên Laptop'), findsNothing);
    expect(sv.notices.items.where((n) => n.kind == NoticeKind.missedCall), isEmpty);
    await _done(t, sv);
  });

  testWidgets('remote control: pick one of the account\'s computers', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await makeServices(t);
    Contact? friend;
    for (final f in sv.contacts.friends) {
      if ((await t.runAsync(() => sv.api.contactDevices(f.peer)))!.length == 3) {
        friend = f;
        break;
      }
    }
    await t.pumpWidget(LumoraApp(
      services: sv,
      overlays: false,
      home: Scaffold(
        body: Builder(
          builder: (c) => TextButton(
            onPressed: () => connectChoosingDevice(c, (d) => sv.remote.connect(friend!.shortId, 'secret', device: d)),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await settle(t);
    await t.tap(find.text('go'));
    await _flush(t);
    expect(find.text('Chọn thiết bị để điều khiển'), findsOneWidget);
    expect(find.text('Máy tính ở nhà'), findsOneWidget);
    await t.tap(find.text('Laptop'));
    await _flush(t);
    expect(sv.remote.viewer, isNotNull);
    await _done(t, sv);
  });

  testWidgets('contact info: devices with their security codes', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await makeServices(t);
    final counts = <String, int>{};
    for (final f in sv.contacts.friends) {
      counts[f.peer] = (await t.runAsync(() => sv.api.contactDevices(f.peer)))!.length;
    }
    final three = counts.entries.firstWhere((e) => e.value == 3).key;
    final one = counts.entries.firstWhere((e) => e.value == 1).key;
    final codes = (await t.runAsync(() => sv.api.contactDevices(three)))!;

    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: SizedBox(width: 420, child: ChatInfoPanel(conv: 'd:$three')))));
    await _flush(t);
    expect(find.text('3 thiết bị'), findsOneWidget);
    await t.tap(find.text('3 thiết bị'));
    await settle(t);
    expect(find.text('Máy tính ở nhà'), findsOneWidget);
    await t.tap(find.text('Mã bảo mật').first);
    await settle(t);
    expect(find.text(codes.first.safety.split(' ').first), findsOneWidget);

    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: SizedBox(width: 420, child: ChatInfoPanel(conv: 'd:$one')))));
    await _flush(t);
    expect(find.textContaining('thiết bị'), findsNothing);
    await _done(t, sv);
  });

  testWidgets('link code input: digits only, 12 max, auto-submit', (t) async {
    final ctl = TextEditingController();
    var done = 0;
    String? link;
    final sv = await makeServices(t, start: false);
    await t.pumpWidget(LumoraApp(
      services: sv,
      overlays: false,
      home: Scaffold(body: Padding(padding: const EdgeInsets.all(24), child: LinkCodeInput(controller: ctl, onCompleted: () => done++, onLink: (l) => link = l))),
    ));
    await t.enterText(_codeField(), '12a34-5678 9012 999');
    await t.pump();
    expect(ctl.text, '123456789012');
    expect(done, 1);
    await t.enterText(_codeField(), 'see lumora://link/v1/xyz ok');
    await t.pump();
    expect(link, 'lumora://link/v1/xyz');
    expect(ctl.text, '123456789012');
    await t.sendKeyEvent(LogicalKeyboardKey.backspace);
    await _done(t, sv);
  });
}
