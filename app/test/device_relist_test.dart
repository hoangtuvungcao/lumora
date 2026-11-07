// After a restore with the recovery phrase, an old device of the account asks
// to be listed again (`device_relist_request`): the main device asks the user,
// and only an explicit "Allow" lists it; "Not mine" signs it out. A dismissed
// prompt keeps the request in My devices.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/ui/devices/my_devices.dart';

import 'helpers.dart';

Future<void> _flush(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await settle(t);
}

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

const _dev1 = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _dev2 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  setUpAll(loadFonts);

  testWidgets('an old device asking to rejoin is listed only when the user allows it', (t) async {
    setSize(t, const Size(500, 900));
    final sv = await makeServices(t);
    final api = sv.api as MockLumoraApi;
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SizedBox())));
    await settle(t);
    await t.runAsync(() => sv.devices.load());
    final before = sv.devices.list!.devices.length;

    api.simulateRelistRequest(_dev1, name: 'Điện thoại của Lan', kind: 1);
    await _flush(t);
    expect(find.text('Một thiết bị muốn quay lại tài khoản'), findsOneWidget);
    expect(find.textContaining('Điện thoại của Lan'), findsOneWidget);
    expect(sv.devices.list!.devices.any((d) => d.device == _dev1), isFalse, reason: 'never listed before the user allows it');
    await t.tap(find.text('Cho phép'));
    await _flush(t);
    expect(sv.devices.list!.devices.any((d) => d.device == _dev1), isTrue);
    expect(sv.devices.list!.devices.length, before + 1);
    expect(sv.devices.relist, isEmpty);
    expect(find.text('Đã cho Điện thoại của Lan quay lại tài khoản'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));

    // "Not mine": signed out (with a wipe), never listed
    api.simulateRelistRequest(_dev2, name: 'Máy lạ', kind: 3);
    await _flush(t);
    await t.tap(find.text('Không phải của tôi — đăng xuất'));
    await _flush(t);
    expect(sv.devices.list!.devices.any((d) => d.device == _dev2), isFalse);
    expect(sv.devices.list!.revoked.any((d) => d.device == _dev2), isTrue);
    expect(find.text('Đã đăng xuất Máy lạ'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    await _done(t, sv);
  });

  testWidgets('a dismissed request waits in My devices; English prompt', (t) async {
    setSize(t, const Size(500, 1200));
    final sv = await makeServices(t, locale: 'en');
    final api = sv.api as MockLumoraApi;
    await t.pumpWidget(LumoraApp(services: sv, home: const Scaffold(body: SingleChildScrollView(child: MyDevicesPage()))));
    await _flush(t);
    await t.runAsync(() => sv.devices.load());
    await _flush(t);
    api.simulateRelistRequest(_dev1, name: 'Old laptop', kind: 3);
    await _flush(t);
    expect(find.text('A device wants to rejoin your account'), findsOneWidget);
    expect(find.textContaining('“Old laptop”'), findsOneWidget);
    // dismissed (tap outside): still pending, shown in My devices
    await t.tapAt(const Offset(10, 10));
    await _flush(t);
    expect(find.text('A device wants to rejoin your account'), findsNothing);
    expect(find.text('DEVICES ASKING TO REJOIN'), findsOneWidget);
    expect(find.byKey(const ValueKey('relist-$_dev1')), findsOneWidget);
    expect(sv.devices.list!.devices.any((d) => d.device == _dev1), isFalse);
    // from there: allow
    await t.tap(find.byKey(const ValueKey('relist-$_dev1')));
    await _flush(t);
    await t.tap(find.text('Allow'));
    await _flush(t);
    expect(sv.devices.list!.devices.any((d) => d.device == _dev1), isTrue);
    expect(find.text('DEVICES ASKING TO REJOIN'), findsNothing);
    await t.pump(const Duration(seconds: 5));
    await _done(t, sv);
  });
}
