// The PIN hash and wrong-PIN counters live in the core's encrypted database
// (`ui_secret_get/set`), not in the plain settings file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/app_lock.dart';
import 'package:lumora/state/settings.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('lumora-lock-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Map<String, dynamic>> fileJson(File f) async {
    // settings save asynchronously
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
  }

  test('old settings file: PIN secrets move into the core and leave the file', () async {
    final f = File('${tmp.path}/ui_settings.json');
    final hash = AppLock.hashPin('2468', iterations: 10);
    await f.writeAsString(jsonEncode({'pin_hash': hash, 'pin_len': 4, 'pin_fails': 2}));
    final st = await Settings.load(f);
    expect(st.legacyPinSecrets, isTrue);
    final api = MockLumoraApi(timers: false);
    final lock = AppLock(st, api: api);
    expect(lock.locked, isTrue, reason: 'locked from the very start');
    expect(lock.ready, isTrue, reason: 'legacy hash usable before the core runs');

    await lock.loadSecrets();
    final stored = jsonDecode((await api.uiSecretGet(AppLock.secretKey))!) as Map<String, dynamic>;
    expect(stored['hash'], hash);
    expect(stored['fails'], 2);
    final j = await fileJson(f);
    expect(j.containsKey('pin_hash'), isFalse);
    expect(j.containsKey('pin_fails'), isFalse);
    expect(j['pin_set'], isTrue);

    // wrong try → counter saved in the core; right PIN unlocks
    expect(await lock.tryUnlock('0000'), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(jsonDecode((await api.uiSecretGet(AppLock.secretKey))!)['fails'], 3);
    expect(await lock.tryUnlock('2468'), isTrue);
    lock.detach();
  });

  test('next start: lock covers the UI, PIN is read from the core', () async {
    final f = File('${tmp.path}/ui_settings.json');
    final api = MockLumoraApi(timers: false);
    final hash = AppLock.hashPin('1357', iterations: 10);
    await api.uiSecretSet(AppLock.secretKey, jsonEncode({'hash': hash, 'fails': 0, 'until': 0, 'level': 0}));
    await f.writeAsString(jsonEncode({'pin_set': true, 'pin_len': 4}));
    final st = await Settings.load(f);
    final lock = AppLock(st, api: api);
    expect(lock.locked, isTrue);
    expect(lock.ready, isFalse);
    // typed before the core answered: refused, but not counted as wrong
    expect(await lock.tryUnlock('1357'), isFalse);
    expect(st.pinFails, 0);
    await lock.loadSecrets();
    expect(lock.ready, isTrue);
    expect(await lock.tryUnlock('1357'), isTrue);

    // removing the PIN removes the secret too
    lock.removePin();
    await Future<void>.delayed(Duration.zero);
    expect(await api.uiSecretGet(AppLock.secretKey), isNull);
    expect((await fileJson(f))['pin_set'], isFalse);
    lock.detach();
  });

  test('core keys must start with ui.', () async {
    final api = MockLumoraApi(timers: false);
    expect(() => api.uiSecretSet('pin', 'x'), throwsA(anything));
  });
}
