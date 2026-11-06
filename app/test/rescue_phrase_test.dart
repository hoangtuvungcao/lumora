// Security audit: "Forgot password" must not accept a recovery phrase that
// belongs to a different account (it would silently replace the locked one).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/data_rescue.dart';
import 'package:lumora/state/settings.dart';
import 'package:lumora/state/stores.dart';

class _OtherAccountApi extends MockLumoraApi {
  _OtherAccountApi() : super(timers: false);
  bool? answer = false;
  @override
  Future<bool?> phraseMatches(String dataDir, String phrase) async => answer;
}

void main() {
  testWidgets('forgot password: a phrase of another account is refused, old data untouched', (tester) async {
    final api = _OtherAccountApi();
    final settings = Settings()
      ..locale = 'vi'
      ..themeMode = ThemeMode.dark
      ..onboarded = true
      ..hasPassphrase = true;
    final sv = AppServices(api: api, settings: settings, dataDir: '/tmp/lumora-test');
    final rescue = DataRescue(sv);
    final phrase = (await tester.runAsync(() => api.recoveryPhrase()))!;
    Object? err;
    await tester.runAsync(() => rescue.restoreFresh(phrase: phrase).catchError((Object e) => err = e));
    expect(DataRescue.errorCode(err!), 'rescue_wrong_phrase');
    expect(rescue.aside, isEmpty, reason: 'nothing may be set aside');
    expect(sv.session.phase, isNot(SessionPhase.ready));

    // a phrase that can't be checked (older data) still works as before
    api.answer = null;
    await tester.runAsync(() => rescue.restoreFresh(phrase: phrase));
    expect(sv.session.phase, SessionPhase.ready);
    await tester.pump(const Duration(seconds: 3));
    sv.dispose();
  });
}
