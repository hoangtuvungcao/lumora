// Regression (Android, password-protected install): Lumora was signed out of
// its account while in the background (e.g. another device became the main
// device). On the next launch the lock screen asked for the password, the
// core then finished the sign-out and made a brand-new account under that
// password — friends, chats and settings looked gone. Now the launch shows
// the sign-out notice instead, and the unlock path can never create an
// account (`open_existing`).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/settings.dart';
import 'package:lumora/state/stores.dart';

class _RecordingApi extends MockLumoraApi {
  _RecordingApi() : super(timers: false);
  final starts = <Map<String, dynamic>>[];

  /// Pretend to be the real core so file-system code paths run.
  bool fsMode = false;
  @override
  bool get isMock => !fsMode && super.isMock;
  @override
  Future<void> start(Map<String, dynamic> config) {
    starts.add(Map.of(config));
    return super.start(config);
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('lumora-signed-out-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  AppServices services(_RecordingApi api, {bool passphrase = true}) => AppServices(
        api: api,
        settings: Settings()
          ..onboarded = true
          ..hasPassphrase = passphrase,
        dataDir: '${tmp.path}/core',
      );

  testWidgets('a sign-out pending at launch shows the notice, not the password prompt', (t) async {
    Directory('${tmp.path}/core').createSync();
    File('${tmp.path}/core/device_reset.json').writeAsStringSync('{"wipe_media":false,"by_self":false,"keep":true}');
    final api = _RecordingApi();
    final sv = services(api);
    await t.runAsync(sv.boot);
    expect(sv.devices.signedOut, isNotNull);
    expect(sv.devices.signedOut!.kept, isTrue);
    expect(sv.session.phase, SessionPhase.onboarding);
    expect(api.starts, isEmpty, reason: 'the core must not be started (it would finish the sign-out)');
    // the marker and the account's files are left for the core to keep aside
    expect(File('${tmp.path}/core/device_reset.json').existsSync(), isTrue);
  });

  test('pendingSignOut reads the core marker', () {
    expect(AppServices.pendingSignOut(''), isNull);
    expect(AppServices.pendingSignOut(tmp.path), isNull);
    File('${tmp.path}/device_reset.json').writeAsStringSync('{"wipe_media":true,"by_self":true}');
    final out = AppServices.pendingSignOut(tmp.path)!;
    expect(out.bySelf, isTrue);
    expect(out.wipe, isTrue);
    expect(out.kept, isFalse);
    File('${tmp.path}/device_reset.json').writeAsStringSync('garbage');
    final damaged = AppServices.pendingSignOut(tmp.path);
    expect(damaged, isNotNull, reason: 'a damaged marker still means "signed out"');
    expect(damaged!.kept, isTrue, reason: 'and the core keeps the data aside then');
  });

  testWidgets('unlocking opens the existing account only; creating one does not', (t) async {
    final api = _RecordingApi();
    final sv = services(api, passphrase: false);
    await t.runAsync(sv.boot);
    expect(sv.session.phase, SessionPhase.ready);
    expect(api.starts.single['open_existing'], isTrue);

    final api2 = _RecordingApi();
    final sv2 = AppServices(api: api2, settings: Settings(), dataDir: '');
    await t.runAsync(() => sv2.createIdentity(name: 'An'));
    expect(api2.starts.single.containsKey('open_existing'), isFalse);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('the account kept aside when a new one is made is listed to open again', (t) async {
    Directory('${tmp.path}/core').createSync();
    Directory('${tmp.path}/core.signed-out-1700000000').createSync();
    final api = _RecordingApi()..fsMode = true;
    final sv = AppServices(api: api, settings: Settings(), dataDir: '${tmp.path}/core');
    await t.runAsync(() => sv.createIdentity(name: 'An'));
    api.fsMode = false;
    expect(sv.settings.asideData, ['${tmp.path}/core.signed-out-1700000000']);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pumpWidget(const SizedBox());
  });
}
