// Showing the recovery phrase and "Check your copy": the phrase only counts
// as backed up once three words asked by position were typed back correctly.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart' show kMockRecoveryPhrase;
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/onboarding/onboarding_screen.dart';
import 'package:lumora/ui/settings/security_checkup.dart';
import 'package:lumora/ui/shell/home_shell.dart';
import 'package:lumora/ui/widgets/recovery_phrase.dart';
import 'package:lumora/ui/widgets/secure_input.dart';

import 'helpers.dart';

final _words = kMockRecoveryPhrase.split(' ');
Finder _checkBox(int i) => find.descendant(of: find.byType(PhraseVerify), matching: find.byType(TextField)).at(i);

void main() {
  test('three distinct random positions, in order', () {
    for (var i = 0; i < 50; i++) {
      final p = PhraseVerify.randomPositions(24);
      expect(p, hasLength(3));
      expect(p.toSet(), hasLength(3));
      expect(p, orderedEquals([...p]..sort()));
      expect(p.every((x) => x >= 0 && x < 24), isTrue);
    }
  });

  for (final size in [const Size(1440, 900), const Size(390, 844)]) {
    testWidgets('grid: ${size.width > 600 ? '3 × 8 on desktop' : '2 × 12 on phones'}, copy and warning', (tester) async {
      setSize(tester, size, dpr: size.width > 600 ? 1 : 2);
      final sv = await makeServices(tester, start: false);
      await tester.pumpWidget(LumoraApp(services: sv, home: const OnboardingScreen(initialStep: 3, previewPhrase: kMockRecoveryPhrase)));
      await settle(tester);
      expect(tester.takeException(), isNull);
      for (final w in _words.toSet()) {
        expect(find.text(w), findsWidgets);
      }
      // column-major: word 9 starts the second column, right of word 1
      final one = tester.getTopLeft(find.text(_words[0]));
      final cols = size.width > 600 ? 3 : 2;
      final rows = 24 ~/ cols;
      final nextCol = tester.getTopLeft(find.text(_words[rows]));
      expect(nextCol.dy, closeTo(one.dy, 2));
      expect(nextCol.dx, greaterThan(one.dx));
      expect(find.textContaining('Ai có các từ này sẽ vào được tài khoản của bạn'), findsOneWidget);
      expect(find.text('Sao chép'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      sv.dispose();
      resetSize(tester);
    });
  }

  testWidgets('onboarding: wrong word stays, right words mark the phrase as backed up', (tester) async {
    setSize(tester, const Size(1440, 900));
    final sv = await makeServices(tester, start: false);
    sv.settings
      ..phraseBackedUp = false
      ..onboarded = false;
    await tester.pumpWidget(LumoraApp(services: sv, home: const OnboardingScreen(initialStep: 3, previewPhrase: kMockRecoveryPhrase, previewCheckPositions: [2, 11, 19])));
    await settle(tester);
    await tester.ensureVisible(find.text('Tôi đã ghi lại'));
    await tester.tap(find.text('Tôi đã ghi lại'));
    await settle(tester, frames: 6);
    expect(find.text('Kiểm tra lại'), findsWidgets);
    expect(find.text('Từ số 3'), findsOneWidget);
    expect(find.text('Từ số 12'), findsOneWidget);
    expect(find.text('Từ số 20'), findsOneWidget);

    await tester.enterText(_checkBox(0), _words[2]);
    await tester.enterText(_checkBox(1), _words[11]);
    await tester.enterText(_checkBox(2), 'door');
    await settle(tester, frames: 2);
    await tester.ensureVisible(find.widgetWithText(SecurePrimaryButton, 'Kiểm tra'));
    await tester.tap(find.widgetWithText(SecurePrimaryButton, 'Kiểm tra'));
    await settle(tester, frames: 4);
    expect(find.textContaining('Từ số 20 chưa khớp'), findsOneWidget);
    expect(sv.settings.phraseBackedUp, isFalse);

    // 4-letter starts count as the word
    await tester.enterText(_checkBox(2), _words[19].substring(0, 4));
    await settle(tester, frames: 2);
    await tester.ensureVisible(find.widgetWithText(SecurePrimaryButton, 'Kiểm tra'));
    await tester.tap(find.widgetWithText(SecurePrimaryButton, 'Kiểm tra'));
    await settle(tester, frames: 12);
    expect(sv.settings.phraseBackedUp, isTrue);
    expect(sv.settings.onboarded, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    sv.dispose();
    resetSize(tester);
  });

  testWidgets('onboarding: "Later" finishes without marking the phrase as backed up', (tester) async {
    setSize(tester, const Size(1440, 900));
    final sv = await makeServices(tester, start: false);
    sv.settings
      ..phraseBackedUp = false
      ..onboarded = false;
    await tester.pumpWidget(LumoraApp(services: sv, home: const OnboardingScreen(initialStep: 5, previewPhrase: kMockRecoveryPhrase)));
    await settle(tester);
    await tester.tap(find.text('Để sau'));
    await settle(tester, frames: 4);
    expect(sv.settings.onboarded, isTrue);
    expect(sv.settings.phraseBackedUp, isFalse);
    expect(sv.session.phase, SessionPhase.ready);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    sv.dispose();
    resetSize(tester);
  });

  testWidgets('settings: "Write it down" shows the phrase, then the check marks it backed up', (tester) async {
    setSize(tester, const Size(1440, 900));
    final sv = await makeServices(tester);
    sv.settings.phraseBackedUp = false;
    await tester.pumpWidget(LumoraApp(services: sv));
    await settle(tester);
    final done = showRecoveryPhraseDialog(tester.element(find.byType(HomeShell)));
    await settle(tester, frames: 4);
    await tester.tap(find.text('Hiện'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester, frames: 6);
    expect(find.byType(PhraseGrid), findsOneWidget);
    await tester.ensureVisible(find.text('Tôi đã ghi lại'));
    await tester.tap(find.text('Tôi đã ghi lại'));
    await settle(tester, frames: 6);
    final verify = tester.widget<PhraseVerify>(find.byType(PhraseVerify));
    expect(verify.positions, isNull, reason: 'random positions in the real dialog');
    final asked = [
      for (final t in tester.widgetList<Text>(find.descendant(of: find.byType(PhraseVerify), matching: find.byType(Text))))
        if (RegExp(r'^Từ số (\d+)$').hasMatch(t.data ?? '')) int.parse(RegExp(r'\d+').firstMatch(t.data!)!.group(0)!) - 1,
    ];
    expect(asked, hasLength(3));
    for (var i = 0; i < 3; i++) {
      await tester.enterText(_checkBox(i), _words[asked[i]]);
    }
    await settle(tester, frames: 2);
    await tester.ensureVisible(find.widgetWithText(SecurePrimaryButton, 'Kiểm tra'));
    await tester.tap(find.widgetWithText(SecurePrimaryButton, 'Kiểm tra'));
    await settle(tester, frames: 14);
    await done;
    expect(sv.settings.phraseBackedUp, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 100));
    sv.dispose();
    resetSize(tester);
  });
}
