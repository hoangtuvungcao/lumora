// Security audit follow-up: PIN key derivation and the wrong-PIN counter.
//
// * PBKDF2-HMAC-SHA512 with 210 000 rounds (OWASP), computed off the UI isolate.
// * Older, weaker records are re-hashed after the next successful unlock.
// * A try is counted (and saved in the core) BEFORE the PIN is checked, so
//   killing the app during the check can't give a free guess.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/app_lock.dart';
import 'package:lumora/state/settings.dart';

/// Records every `ui.pin` write, and can hold the next PIN check "forever"
/// (the app being killed in the middle of it).
class _RecordingApi extends MockLumoraApi {
  _RecordingApi() : super(timers: false);
  final writes = <Map<String, dynamic>>[];
  @override
  Future<void> uiSecretSet(String key, String? value) async {
    if (key == AppLock.secretKey && value != null) writes.add(jsonDecode(value) as Map<String, dynamic>);
    await super.uiSecretSet(key, value);
  }
}

void main() {
  test('new PIN hashes: PBKDF2-SHA512, 210k rounds, computed in a background isolate', () async {
    final saved = AppLock.kdfIterations;
    AppLock.kdfIterations = 210000;
    addTearDown(() => AppLock.kdfIterations = saved);
    // the UI isolate keeps ticking while the hash is computed
    var ticks = 0;
    final t = Timer.periodic(const Duration(milliseconds: 10), (_) => ticks++);
    final sw = Stopwatch()..start();
    final h = await AppLock.hashPinAsync('482915');
    final ms = sw.elapsedMilliseconds;
    t.cancel();
    // ignore: avoid_print
    print('PBKDF2-HMAC-SHA512 × 210000 in an isolate: $ms ms (UI ticks meanwhile: $ticks)');
    expect(h, startsWith('pbkdf2-sha512\$210000\$'));
    expect(ticks, greaterThan(ms ~/ 40), reason: 'the UI isolate was blocked');
    expect(await AppLock.checkPinAsync('482915', h), isTrue);
    expect(await AppLock.checkPinAsync('482916', h), isFalse);
  });

  test('an old 12k SHA-256 record still unlocks and is re-hashed with the current KDF', () async {
    final api = _RecordingApi();
    final legacy = AppLock.hashPin('1357', iterations: 12000, alg: 'pbkdf2-sha256');
    await api.uiSecretSet(AppLock.secretKey, jsonEncode({'hash': legacy, 'fails': 0, 'until': 0, 'level': 0, 'on': true}));
    final st = Settings()..pinSet = true;
    final lock = AppLock(st, api: api);
    await lock.loadSecrets();
    expect(await lock.tryUnlock('1357'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final stored = jsonDecode((await api.uiSecretGet(AppLock.secretKey))!)['hash'] as String;
    expect(stored, startsWith('pbkdf2-sha512\$${AppLock.kdfIterations}\$'));
    expect(AppLock.checkPin('1357', stored), isTrue);
    lock.detach();
  });

  test('a try is saved as wrong BEFORE the check, and cleared when the PIN was right', () async {
    final api = _RecordingApi();
    final st = Settings();
    final lock = AppLock(st, api: api);
    await lock.loadSecrets();
    await lock.setPin('2468');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    api.writes.clear();
    // Kill the app right after the check starts: the try must already be in the core.
    final pending = lock.tryUnlock('0000');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(api.writes, isNotEmpty, reason: 'nothing saved before the (slow) check');
    expect(api.writes.first['fails'], 1);
    expect(await pending, isFalse);
    expect(await lock.tryUnlock('2468'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(jsonDecode((await api.uiSecretGet(AppLock.secretKey))!)['fails'], 0);
    lock.detach();
  });

  test('busy flag while the PIN is checked', () async {
    final st = Settings();
    final lock = AppLock(st);
    await lock.setPin('2468');
    final seen = <bool>[];
    lock.addListener(() => seen.add(lock.verifying));
    expect(await lock.tryUnlock('2468'), isTrue);
    expect(seen, contains(true));
    expect(lock.verifying, isFalse);
    lock.detach();
  });
}
