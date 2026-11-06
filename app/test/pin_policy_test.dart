// PIN policy: secure AND fair.
//
// * Only a submitted PIN counts; reopening the app never adds a try.
// * The same wrong PIN counts once (like iOS).
// * Waits: tries 1–5 none, then 30 s, 1 min, 5 min, 15 min, then 1 h each;
//   after 50 different wrong PINs only the recovery phrase unlocks.
// * A wait keeps running while the app is closed; a clock moved back can't
//   stretch it past the policy; "Forgot PIN" works during a wait.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/l10n/strings.dart';
import 'package:lumora/state/app_lock.dart';
import 'package:lumora/state/settings.dart';

/// Keeps every `ui.pin` value written, to replay "the app died right here".
class _SnapApi extends MockLumoraApi {
  _SnapApi() : super(timers: false);
  final writes = <String>[];
  @override
  Future<void> uiSecretSet(String key, String? value) {
    if (key == AppLock.secretKey && value != null) writes.add(value);
    return super.uiSecretSet(key, value);
  }

  /// The record saved just before the check of the last try started.
  Map<String, dynamic> get beforeCheck =>
      jsonDecode(writes.lastWhere((w) => (jsonDecode(w) as Map)['pending'] != null)) as Map<String, dynamic>;
}

void main() {
  late DateTime now;
  late Duration up;
  late _SnapApi api;
  late Settings st;
  late AppLock lock;

  /// A fresh app process on the same data (new settings object, new uptime).
  Future<void> restart() async {
    lock.detach();
    up = Duration.zero;
    st = Settings()..pinSet = true;
    lock = AppLock(st, api: api, clock: () => now, uptime: () => up);
    await lock.loadSecrets();
  }

  setUp(() async {
    now = DateTime(2026, 1, 1, 12);
    up = Duration.zero;
    api = _SnapApi();
    st = Settings();
    lock = AppLock(st, api: api, clock: () => now, uptime: () => up);
    await lock.loadSecrets();
    await lock.setPin('2468');
  });
  tearDown(() => lock.detach());

  Future<Map<String, dynamic>> record() async => jsonDecode((await api.uiSecretGet(AppLock.secretKey))!) as Map<String, dynamic>;

  Future<void> wrong(int n, {int from = 0}) async {
    for (var i = 0; i < n; i++) {
      expect(await lock.tryUnlock('${1000 + from + i}'), isFalse);
    }
  }

  test('reopening the app without submitting counts nothing and keeps what was counted', () async {
    await wrong(2);
    for (var i = 0; i < 3; i++) {
      await restart();
    }
    expect(st.pinFails, 2);
    expect((await record())['fails'], 2);
    expect(await lock.tryUnlock('2468'), isTrue);
    expect((await record())['fails'], 0);
  });

  test('the same wrong PIN entered again counts only once (and survives a restart)', () async {
    for (var i = 0; i < 4; i++) {
      expect(await lock.tryUnlock('0000'), isFalse);
    }
    expect(st.pinFails, 1);
    await restart();
    expect(await lock.tryUnlock('0000'), isFalse);
    expect(st.pinFails, 1);
    expect(jsonEncode(await record()).contains('0000'), isFalse, reason: 'wrong PINs are stored only as salted hashes');
  });

  test('schedule: 5 free tries, then 30 s, 1 min, 5 min, 15 min, then 1 h; 50 different wrong PINs → phrase only', () async {
    await wrong(4);
    expect(lock.waitSeconds, 0);
    final waits = <int>[];
    for (var i = 4; i < 11; i++) {
      await wrong(1, from: i);
      waits.add(lock.waitSeconds);
      up += Duration(seconds: lock.waitSeconds + 1);
      now = now.add(Duration(seconds: lock.waitSeconds + 1));
    }
    expect(waits, [30, 60, 300, 900, 3600, 3600, 3600]);
    for (var i = 11; i < 50; i++) {
      await wrong(1, from: i);
      up += const Duration(hours: 2);
      now = now.add(const Duration(hours: 2));
    }
    expect(lock.exhausted, isTrue);
    expect(await lock.tryUnlock('2468'), isFalse, reason: 'after 50 different wrong PINs only the recovery phrase helps');
  });

  test('a wait keeps running while the app is closed', () async {
    await wrong(5);
    expect(lock.waitSeconds, 30);
    now = now.add(const Duration(seconds: 10));
    await restart();
    expect(lock.waitSeconds, inInclusiveRange(19, 20));
    // a clock moved forward after the restart can't end it early
    now = now.add(const Duration(days: 1));
    expect(lock.waitSeconds, greaterThan(0));
    up += const Duration(seconds: 21);
    expect(lock.waitSeconds, 0);
    expect(await lock.tryUnlock('2468'), isTrue);
  });

  test('a clock set back does not lengthen the wait beyond the policy', () async {
    await wrong(5);
    now = now.subtract(const Duration(days: 30));
    await restart();
    expect(lock.waitSeconds, inInclusiveRange(1, 30));
  });

  test('"Forgot PIN" works during a wait and removes the PIN at once; nothing is wiped', () async {
    lock.setChatLocked('d:SECRET', true);
    await wrong(7);
    expect(lock.waitSeconds, greaterThan(0));
    lock.removePin(); // recovery phrase checked by the dialog
    expect(lock.waitSeconds, 0);
    expect(lock.hasPin, isFalse);
    expect(lock.locked, isFalse);
    expect(st.pinFails, 0);
  });

  test('app killed while the RIGHT PIN was being checked: the try is not counted twice and clears on unlock', () async {
    await wrong(1);
    expect(await lock.tryUnlock('2468'), isTrue);
    final crashed = api.beforeCheck; // what the core held while the PIN was checked
    expect(crashed['fails'], 2, reason: 'counted before the check (no free guess by killing the app)');
    // "restart" from the crashed state
    await api.uiSecretSet(AppLock.secretKey, jsonEncode(crashed));
    await restart();
    expect(st.pinFails, 2);
    expect(await lock.tryUnlock('2468'), isTrue);
    expect((await record())['fails'], 0);
    // a wrong PIN pending at the crash is not counted again when retyped
    await wrong(1, from: 50);
    expect(await lock.tryUnlock('7777'), isFalse);
    final crashed2 = api.beforeCheck;
    await api.uiSecretSet(AppLock.secretKey, jsonEncode(crashed2));
    await restart();
    expect(st.pinFails, 2);
    expect(await lock.tryUnlock('7777'), isFalse);
    expect(st.pinFails, 2);
  });

  test('counters of the old "rounds of 5" format carry over (nothing lost, nothing added)', () async {
    await api.uiSecretSet(AppLock.secretKey, jsonEncode({'hash': AppLock.hashPin('2468'), 'fails': 2, 'level': 1, 'until': 0, 'on': true}));
    await restart();
    expect(st.pinFails, 7);
    expect(lock.waitSeconds, 0, reason: 'no wait invented by the upgrade');
  });

  test('friendly texts', () {
    expect(S.vn('pin_wrong_again'), 'Sai mã PIN. Bạn còn thử được tiếp');
    expect(S.en('pin_wrong_again'), 'Wrong PIN. You can try again');
    expect(S.vn('pin_wait_phrase', {'t': '4:59'}), 'Thử lại sau 4:59 — hoặc dùng cụm từ khôi phục');
    expect(S.en('pin_wait_phrase', {'t': '4:59'}), 'Try again in 4:59 — or use your recovery phrase');
  });
}
