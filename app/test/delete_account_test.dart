// Settings › Security › "Xoá tài khoản" with the mock core: the main device signs every other
// device out with a media wipe and then itself; a linked device only deletes its own copy and
// names the main device; a wrong password leaves everything as it was.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/ui/devices/my_devices.dart' show signOutHere;
import 'package:lumora/ui/devices/signed_out.dart';
import 'package:lumora/ui/onboarding/onboarding_screen.dart';
import 'package:lumora/ui/settings/delete_account.dart';
import 'package:lumora/ui/settings/settings_screen.dart';

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

Future<AppServices> _services(WidgetTester t, {String? pass, bool linked = false}) async {
  final sv = await makeServices(t, start: false);
  if (linked) _mock(sv).debugMakeLinkedDevice();
  await t.runAsync(() => sv.unlock(pass));
  await t.runAsync(() => sv.devices.load());
  return sv;
}

Future<void> _openDialog(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SettingsSubPage(page: SettingsPage.security)), overlays: false));
  await settle(t);
  final row = find.byKey(const ValueKey('delete_account'));
  await t.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
  await t.tap(row);
  await _flush(t);
  expect(find.byType(DeleteAccountDialog), findsOneWidget);
}

Future<void> _confirm(WidgetTester t, {String? pass}) async {
  if (pass != null) {
    await t.enterText(find.descendant(of: find.byType(DeleteAccountDialog), matching: find.byType(TextField)), pass);
    await settle(t, frames: 2);
  }
  await t.tap(find.byKey(const ValueKey('da_understand')));
  await settle(t, frames: 2);
  await t.tap(find.byKey(const ValueKey('da_confirm')));
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
  await _flush(t);
}

void main() {
  setUpAll(loadFonts);

  testWidgets('main device: every other device is revoked with a wipe, then this one signs out', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await _services(t, pass: 'mk-lan');
    final m = _mock(sv);
    final others = [for (final d in sv.devices.list!.devices) if (!d.isThis) d.device];
    expect(others, hasLength(2));
    await _openDialog(t, sv);
    expect(find.text('Xoá tài khoản?'), findsOneWidget);
    expect(find.text('Không thể hoàn tác.'), findsOneWidget);
    expect(find.textContaining('vẫn còn trên thiết bị của người nhận'), findsOneWidget);
    expect(find.textContaining('24 từ khôi phục'), findsOneWidget);
    expect(find.textContaining('2 thiết bị đã liên kết'), findsOneWidget);
    // nothing happens before "I understand" is ticked
    await t.enterText(find.descendant(of: find.byType(DeleteAccountDialog), matching: find.byType(TextField)), 'mk-lan');
    await settle(t, frames: 2);
    expect(t.widget<FilledButton>(find.byKey(const ValueKey('da_confirm'))).onPressed, isNull);
    await _confirm(t);
    expect([for (final r in m.revokedDevices) r['device']], unorderedEquals(others));
    expect(m.revokedDevices.every((r) => r['wipe'] == true), isTrue, reason: 'linked devices wiped');
    expect(m.lastLogout, isNotNull);
    expect(m.lastLogout!['primary'], isTrue);
    expect(m.lastLogout!['wipe'], isTrue);
    expect(m.lastLogout!['others'], isEmpty, reason: 'the others were signed out before this one');
    // the signed-out notice, then the welcome screen
    expect(sv.devices.signedOut?.wipe, isTrue);
    await t.pumpWidget(LumoraApp(services: sv, overlays: false));
    await _flush(t);
    expect(find.byType(DeviceSignedOutScreen), findsOneWidget);
    expect(find.textContaining('Tài khoản đã được xoá khỏi thiết bị này'), findsOneWidget);
    await t.tap(find.text('Bắt đầu lại'));
    await settle(t);
    expect(find.byType(OnboardingScreen), findsOneWidget);
    await _done(t, sv);
  });

  testWidgets('linked device: only this device signs out; the main device is named', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await _services(t, linked: true);
    final m = _mock(sv);
    expect(sv.devices.isPrimary, isFalse);
    await _openDialog(t, sv);
    expect(find.text('Xoá dữ liệu trên thiết bị này?'), findsOneWidget);
    expect(find.textContaining('Chỉ xoá bản sao trên thiết bị này'), findsOneWidget);
    expect(find.text('Muốn xoá toàn bộ tài khoản, hãy làm trên thiết bị chính: Điện thoại của Lan.'), findsOneWidget);
    await _confirm(t);
    expect(m.revokedDevices, isEmpty, reason: 'a linked device revokes nobody');
    expect(m.lastLogout!['primary'], isFalse);
    expect(m.lastLogout!['wipe'], isTrue);
    expect(m.lastLogout!['others'], hasLength(2));
    expect(sv.devices.signedOut?.bySelf, isTrue);
    await _done(t, sv);
  });

  testWidgets('wrong password keeps every device and the account', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await _services(t, pass: 'mk-lan');
    final m = _mock(sv);
    await _openDialog(t, sv);
    await _confirm(t, pass: 'sai-mat-khau');
    expect(find.byType(DeleteAccountDialog), findsOneWidget, reason: 'dialog stays open');
    expect(find.textContaining('mật khẩu', findRichText: true), findsWidgets);
    expect(m.revokedDevices, isEmpty);
    expect(m.lastLogout, isNull);
    expect(sv.devices.signedOut, isNull);
    expect(sv.devices.list!.devices, hasLength(3));
    await _done(t, sv);
  });

  testWidgets('English copy', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await makeServices(t, locale: 'en');
    await t.runAsync(() => sv.devices.load());
    await _openDialog(t, sv);
    expect(find.text('Delete your account?'), findsOneWidget);
    expect(find.text('This can’t be undone.'), findsOneWidget);
    expect(find.text('Delete account'), findsWidgets);
    await _done(t, sv);
  });

  testWidgets('busy delete: a tap outside does not close it; a late error shows in it', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await _services(t, pass: 'mk-lan');
    final m = _mock(sv);
    final hold = m.debugHold['check_passphrase'] = Completer<void>();
    await _openDialog(t, sv);
    await _confirm(t, pass: 'sai-mat-khau');
    await t.tapAt(const Offset(8, 8)); // the barrier
    await settle(t);
    expect(find.byType(DeleteAccountDialog), findsOneWidget, reason: 'no dismissing while busy');
    hold.complete();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await _flush(t);
    expect(t.takeException(), isNull);
    expect(find.byType(DeleteAccountDialog), findsOneWidget);
    expect(find.textContaining('mật khẩu', findRichText: true), findsWidgets);
    expect(m.revokedDevices, isEmpty);
    // idle again: the barrier closes it
    await t.tapAt(const Offset(8, 8));
    await settle(t);
    expect(find.byType(DeleteAccountDialog), findsNothing);
    await _done(t, sv);
  });

  testWidgets('busy sign-out: a tap outside does not close it; a late error shows in it', (t) async {
    setSize(t, const Size(1440, 900));
    final sv = await _services(t, pass: 'mk-lan');
    final m = _mock(sv);
    final hold = m.debugHold['device_logout'] = Completer<void>();
    await t.pumpWidget(LumoraApp(
      services: sv,
      overlays: false,
      home: Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => signOutHere(c), child: const Text('go')))),
    ));
    await settle(t);
    await t.tap(find.text('go'));
    await _flush(t);
    expect(find.byType(AlertDialog), findsOneWidget);
    await t.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'sai-mat-khau');
    await settle(t, frames: 2);
    await t.tap(find.widgetWithText(FilledButton, 'Đăng xuất'));
    await settle(t, frames: 2);
    await t.tapAt(const Offset(8, 8));
    await settle(t);
    expect(find.byType(AlertDialog), findsOneWidget, reason: 'no dismissing while busy');
    hold.complete();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await _flush(t);
    expect(t.takeException(), isNull);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(sv.devices.signedOut, isNull);
    await _done(t, sv);
  });
}
