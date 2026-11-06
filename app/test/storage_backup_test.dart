// Storage policy, media clean-up, unblock, backup file round trip and
// core settings reconciliation — all against the mock core.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/settings.dart';

import 'helpers.dart';

void main() {
  testWidgets('storage policy, clean-up and per-chat media removal', (tester) async {
    final sv = await makeServices(tester);
    await tester.runAsync(() async {
      final p = await sv.net.setStoragePolicy({'max_cache': 2 << 30, 'media_days': 30});
      expect(p.maxCache, 2 << 30);
      expect(p.mediaDays, 30);
      expect((await sv.api.storagePolicy()).mediaDays, 30);

      await sv.net.loadStorage();
      final conv = ((sv.net.storage!['by_conv'] as List).first as Map)['conv'] as String;
      final before = sv.net.storage!['media_bytes'] as int;
      final freed = await sv.net.clearMedia(conv: conv);
      expect(freed, greaterThan(0));
      expect(sv.net.storage!['media_bytes'], before - freed);

      expect(await sv.net.cleanUp(), greaterThan(0)); // reclaimable database space
      expect(await sv.net.clearMedia(), before - freed);
      expect(sv.net.storage!['media_bytes'], 0);
    });
    sv.dispose();
  });

  testWidgets('unblock puts a blocked person back to "not a friend"', (tester) async {
    final sv = await makeServices(tester);
    final blocked = sv.contacts.blocked.first;
    await tester.runAsync(() => sv.contacts.unblock(blocked.peer));
    expect(sv.contacts.blocked.where((c) => c.peer == blocked.peer), isEmpty);
    expect(sv.contacts[blocked.peer]?.status, ContactStatus.none);
    final fromCore = (await tester.runAsync(() => sv.api.contacts()))!.firstWhere((c) => c.peer == blocked.peer);
    expect(fromCore.status, ContactStatus.none);
    sv.dispose();
  });

  testWidgets('backup file: export, then restore through the start config', (tester) async {
    final dir = Directory.systemTemp.createTempSync('lumora-bk');
    final path = '${dir.path}/a.lumora-backup';
    final sv = await makeServices(tester);
    await tester.runAsync(() async {
      await expectLater(sv.api.exportBackup(path, '12345'), throwsA(isA<ApiException>()));
      await sv.api.exportBackup(path, 'mây-trôi-2026');
      expect(File(path).existsSync(), isTrue);
    });
    sv.dispose();

    // Wrong password: start fails, nothing is marked as onboarded.
    final api2 = MockLumoraApi(timers: false);
    final sv2 = AppServices(api: api2, settings: Settings()..locale = 'vi', dataDir: dir.path);
    await tester.runAsync(() async {
      await expectLater(sv2.createIdentity(name: '', restoreBackup: (path, 'sai-mat-khau')), throwsA(isA<ApiException>()));
    });
    expect(sv2.settings.onboarded, isFalse);
    sv2.dispose();

    final api3 = MockLumoraApi(timers: false);
    await tester.runAsync(() => api3.request('settings_set', {'echo_cancel': false, 'read_receipts': false}));
    final sv3 = AppServices(api: api3, settings: Settings()..locale = 'vi', dataDir: dir.path);
    await tester.runAsync(() => sv3.createIdentity(name: '', restoreBackup: (path, 'mây-trôi-2026')));
    expect(sv3.settings.onboarded, isTrue);
    // A backup file is not the recovery phrase: the reminder to write the
    // phrase down stays (review #4).
    expect(sv3.settings.phraseBackedUp, isFalse);
    // Restored preferences win over the fresh app's defaults.
    expect(sv3.settings.echoCancel, isFalse);
    expect(sv3.settings.readReceipts, isFalse);
    sv3.dispose();
    dir.deleteSync(recursive: true);
  });

  testWidgets('settings shown in the app reach the core (also after a restart)', (tester) async {
    final api = MockLumoraApi(timers: false);
    final settings = Settings()
      ..locale = 'vi'
      ..onboarded = true
      ..echoCancel = false
      ..typingIndicators = false;
    final sv = AppServices(api: api, settings: settings, dataDir: '/tmp/lumora-test');
    // The core still has its defaults: unlock must push what the app shows.
    await tester.runAsync(() => sv.unlock(null));
    var core = (await tester.runAsync(() => api.settingsGet()))!;
    expect(core['echo_cancel'], isFalse);
    expect(core['typing'], isFalse);

    // Live changes are pushed too.
    await tester.runAsync(() async {
      settings.update((s) => s.echoCancel = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    core = (await tester.runAsync(() => api.settingsGet()))!;
    expect(core['echo_cancel'], isTrue);
    sv.dispose();
  });
}
