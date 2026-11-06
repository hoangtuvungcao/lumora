// Password / PIN / recovery-phrase widgets (lib/ui/widgets/secure_input.dart):
// strength estimate, phrase paste handling, and every secure screen laid out
// on a 320 dp phone without overflow.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart' show kMockRecoveryPhrase;
import 'package:lumora/ui/lock/app_lock_screen.dart';
import 'package:lumora/ui/onboarding/forgot_passphrase.dart';
import 'package:lumora/ui/onboarding/lock_screen.dart';
import 'package:lumora/ui/onboarding/onboarding_screen.dart';
import 'package:lumora/ui/settings/backup_file.dart';
import 'package:lumora/ui/settings/security_checkup.dart';
import 'package:lumora/ui/shell/home_shell.dart';
import 'package:lumora/ui/widgets/secure_input.dart';

import 'helpers.dart';

void main() {
  group('password strength', () {
    test('common and patterned passwords score lowest', () {
      for (final pw in ['password', '12345678', 'qwerty123', 'aaaaaaaa', 'matkhau123']) {
        expect(estimatePasswordStrength(pw).score, lessThanOrEqualTo(1), reason: pw);
      }
    });
    test('short passwords ask for more characters', () {
      final r = estimatePasswordStrength('abc', minLength: 8, policy: true);
      expect(r.hint, 'sec_hint_min');
      expect(r.params['n'], 8);
    });
    test('several unrelated words are strong', () {
      expect(estimatePasswordStrength('mây tím ăn phở sáng nay').score, greaterThanOrEqualTo(3));
      expect(estimatePasswordStrength('Tr0ng-Xanh!Biec_2x9').score, greaterThanOrEqualTo(3));
    });
    test('policy caps the meter', () {
      expect(estimatePasswordStrength('iloveyou2026', policy: true).score, 0);
    });
  });

  testWidgets('recovery phrase: paste, per-word check, checksum, legacy code', (tester) async {
    final ctl = TextEditingController();
    final sv = await makeServices(tester);
    await tester.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: SingleChildScrollView(child: RecoveryPhraseInput(controller: ctl)))));
    await settle(tester, frames: 2);
    Finder box(int i) => find.descendant(of: find.byType(RecoveryPhraseInput), matching: find.byType(TextField)).at(i);
    expect(find.byType(TextField), findsNWidgets(24));

    // A numbered list, upper case, new lines and 4-letter starts are all fine.
    final words = kMockRecoveryPhrase.split(' ');
    final messy = [for (final (i, w) in words.indexed) '${i + 1}. ${i.isEven ? w.toUpperCase() : w.substring(0, math.min(4, w.length))}'].join('\n');
    await tester.enterText(box(0), messy);
    await settle(tester, frames: 2);
    expect(ctl.text, kMockRecoveryPhrase);
    expect(RecoveryPhraseInput.isReady(ctl.text), isTrue);
    expect(find.text('Đủ 24 từ và đúng cụm từ'), findsOneWidget);

    // Two words swapped: every word is known, the checksum is not.
    final swapped = [...words];
    swapped[2] = words[3];
    swapped[3] = words[2];
    await tester.enterText(box(0), swapped.join(' '));
    await settle(tester, frames: 2);
    expect(find.text('Có một từ bị ghi sai. Hãy kiểm tra lại từng từ.'), findsOneWidget);
    expect(RecoveryPhraseInput.isReady(ctl.text), isFalse);

    // An unknown word turns red and is named by its position.
    final unknown = [...words]..[6] = 'lumora';
    await tester.enterText(box(0), unknown.join(' '));
    await settle(tester, frames: 2);
    expect(find.textContaining('Từ số 7 không có trong danh sách'), findsOneWidget);

    // An older-style code switches to the single legacy field.
    await tester.enterText(box(0), 'AEBAG-BAFAY-dqqci-kbmga-2dqpc-airee-yucul-bogaz-dinry-hi6d4-qpbum-e');
    await settle(tester, frames: 4);
    expect(find.text('Mã dạng cũ'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(ctl.text, 'AEBAG-BAFAY-dqqci-kbmga-2dqpc-airee-yucul-bogaz-dinry-hi6d4-qpbum-e');
    expect(RecoveryPhraseInput.isReady(ctl.text), isTrue);
    await tester.tap(find.text('Nhập 24 từ'));
    await settle(tester, frames: 4);
    expect(find.byType(TextField), findsNWidgets(24));
    expect(ctl.text, isEmpty);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    sv.dispose();
  });

  testWidgets('recovery phrase: suggestions after 2 letters, Tab / Enter / tap picks', (tester) async {
    setSize(tester, const Size(1440, 900));
    final ctl = TextEditingController();
    final sv = await makeServices(tester);
    await tester.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: SingleChildScrollView(child: RecoveryPhraseInput(controller: ctl)))));
    await settle(tester, frames: 2);
    Finder box(int i) => find.descendant(of: find.byType(RecoveryPhraseInput), matching: find.byType(TextField)).at(i);
    EditableText edit(int i) => tester.widget<EditableText>(find.descendant(of: box(i), matching: find.byType(EditableText)));

    await tester.enterText(box(0), 'a');
    await settle(tester, frames: 2);
    expect(find.text('abandon'), findsNothing, reason: 'no suggestions after one letter');
    await tester.enterText(box(0), 'ab');
    await settle(tester, frames: 2);
    for (final w in ['abandon', 'ability', 'able', 'about']) {
      expect(find.text(w), findsOneWidget);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await settle(tester, frames: 2);
    expect(edit(0).controller.text, 'abandon');
    expect(edit(1).focusNode.hasFocus, isTrue);

    await tester.enterText(box(1), 'zo');
    await settle(tester, frames: 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester, frames: 2);
    expect(edit(1).controller.text, 'zone');

    await tester.enterText(box(2), 'wint');
    await settle(tester, frames: 2);
    await tester.tap(find.text('winter'));
    await settle(tester, frames: 2);
    expect(edit(2).controller.text, 'winter');
    expect(ctl.text, 'abandon zone winter');

    // A whole word that no other word starts with moves on by itself.
    await tester.enterText(box(3), 'zebra');
    await settle(tester, frames: 2);
    expect(edit(4).focusNode.hasFocus, isTrue);

    // Leaving a 4-letter start completes it.
    await tester.enterText(box(4), 'hams');
    await tester.enterText(box(5), 'x');
    await settle(tester, frames: 2);
    expect(edit(4).controller.text, 'hamster');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    sv.dispose();
    resetSize(tester);
  });

  group('secure screens fit a 320 dp phone', () {
    Future<AppServices> open(WidgetTester tester, {Widget? home}) async {
      setSize(tester, const Size(320, 568), dpr: 2);
      final sv = await makeServices(tester);
      await tester.pumpWidget(LumoraApp(services: sv, home: home));
      await settle(tester);
      return sv;
    }

    Future<void> close(WidgetTester tester, AppServices sv) async {
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 100));
      sv.dispose();
      resetSize(tester);
    }

    testWidgets('data password', (tester) async {
      final sv = await open(tester, home: const LockScreen());
      await tester.enterText(find.byType(TextField), 'sai mật khẩu');
      await settle(tester, frames: 2);
      await close(tester, sv);
    });

    testWidgets('forgot password: options, phrase, file', (tester) async {
      final sv = await open(tester, home: const LockScreen());
      showForgotPassphrase(tester.element(find.byType(LockScreen)));
      await settle(tester, frames: 4);
      await tester.tap(find.text('Cụm từ khôi phục'));
      await settle(tester, frames: 4);
      await tester.enterText(find.descendant(of: find.byType(RecoveryPhraseInput), matching: find.byType(TextField)).first, 'abandon ability zzzz ');
      await settle(tester, frames: 2);
      expect(find.textContaining('Từ số 3'), findsOneWidget, reason: 'per-word check');
      await tester.tap(find.byTooltip('Quay lại'));
      await settle(tester, frames: 4);
      await tester.tap(find.text('Tệp sao lưu'));
      await settle(tester, frames: 4);
      await close(tester, sv);
    });

    testWidgets('app lock, wrong PIN and set-PIN', (tester) async {
      setSize(tester, const Size(320, 568), dpr: 2);
      final sv = await makeServices(tester);
      sv.appLock.setPin('2580');
      await tester.pumpWidget(LumoraApp(services: sv, home: const PinLockScreen()));
      await settle(tester);
      for (final d in ['1', '1', '1', '1']) {
        await tester.tap(find.text(d));
      }
      await settle(tester, frames: 3);
      expect(find.textContaining('Sai mã PIN. Bạn còn thử được tiếp'), findsOneWidget);
      await close(tester, sv);
    });

    testWidgets('set PIN prompt and passphrase / backup dialogs', (tester) async {
      final sv = await open(tester);
      final ctx = tester.element(find.byType(HomeShell));
      askNewPin(ctx);
      await settle(tester, frames: 4);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.byType(PinPad))).pop();
      await settle(tester, frames: 4);
      showPassphraseDialog(ctx);
      await settle(tester, frames: 4);
      final fields = find.descendant(of: find.byType(PasswordField), matching: find.byType(TextField));
      await tester.enterText(fields.at(0), 'trangsang');
      await tester.enterText(fields.at(1), 'trangsa');
      await settle(tester, frames: 2);
      expect(find.text('Hai lần nhập chưa khớp'), findsOneWidget);
      Navigator.of(tester.element(find.byType(PasswordField).first)).pop();
      await settle(tester, frames: 4);
      showBackupDialog(ctx, previewFilled: true);
      await settle(tester, frames: 4);
      await close(tester, sv);
    });

    testWidgets('onboarding restore (phrase and file)', (tester) async {
      final sv = await open(tester, home: const OnboardingScreen(initialStep: 4));
      await tester.enterText(find.descendant(of: find.byType(RecoveryPhraseInput), matching: find.byType(TextField)).first, 'abandon ability ab');
      await settle(tester, frames: 2);
      await tester.tap(find.text('Tệp sao lưu'));
      await settle(tester, frames: 4);
      await close(tester, sv);
    });
  });
}
