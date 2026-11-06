// First onboarding step: language, theme and text size (applied live,
// saved before the core starts).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/settings.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/onboarding/appearance_step.dart';
import 'package:lumora/ui/onboarding/onboarding_screen.dart';

import 'helpers.dart';

/// Fresh app on the onboarding screen (no identity yet).
Future<AppServices> _open(WidgetTester tester, Settings settings, {Size size = const Size(1440, 900)}) async {
  setSize(tester, size, dpr: size.width < 600 ? 2 : 1);
  final sv = AppServices(api: MockLumoraApi(timers: false), settings: settings, dataDir: '/tmp/lumora-onb-test');
  await tester.pumpWidget(LumoraApp(services: sv, overlays: false));
  await tester.runAsync(sv.boot);
  await settle(tester);
  return sv;
}

Future<void> _done(WidgetTester tester, AppServices sv) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  sv.dispose();
  resetSize(tester);
}

Brightness _brightness(WidgetTester tester) => Theme.of(tester.element(find.byType(OnboardingAppearance))).brightness;

/// Lets the settings file write (real IO) finish: waits until [file]
/// holds [want] (bounded, so a missing write still fails the test).
Future<void> _waitForFile(WidgetTester tester, File file, List<String> want) async {
  for (var i = 0; i < 100; i++) {
    final text = await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return file.existsSync() ? file.readAsStringSync() : '';
    });
    await tester.pump();
    if (want.every((w) => text!.contains(w))) return;
  }
}

void main() {
  setUpAll(loadFonts);

  test('first launch follows the system language and theme', () {
    expect((Settings()..adoptSystemDefaults(const Locale('vi', 'VN'))).locale, 'vi');
    expect((Settings()..adoptSystemDefaults(const Locale('en', 'US'))).locale, 'en');
    expect((Settings()..adoptSystemDefaults(const Locale('fr'))).locale, 'en');
    expect((Settings()..adoptSystemDefaults(const Locale('vi'))).themeMode, ThemeMode.system);
  });

  testWidgets('welcome step comes first; choosing English switches every string', (tester) async {
    final sv = await _open(tester, Settings()..adoptSystemDefaults(const Locale('vi')));
    expect(sv.session.phase, SessionPhase.onboarding);
    expect(find.text('Chào mừng đến với Lumora'), findsOneWidget);
    expect(find.text('Tiếp tục'), findsOneWidget);
    expect(find.text('Theo hệ thống'), findsOneWidget);

    await tester.tap(find.text('English'));
    await settle(tester);
    expect(sv.settings.locale, 'en');
    expect(find.text('Welcome to Lumora'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Chào mừng đến với Lumora'), findsNothing);

    // Continue → the intro, which keeps the small VI/EN switch.
    await tester.tap(find.text('Continue'));
    await settle(tester);
    expect(find.text('Create new identity'), findsOneWidget);
    expect(find.text('EN'), findsOneWidget);
    await _done(tester, sv);
  });

  testWidgets('choosing Dark applies ThemeMode.dark at once, Light switches back', (tester) async {
    final sv = await _open(tester, Settings()..adoptSystemDefaults(const Locale('en')));
    // Test platform is light: "System" shows the light theme.
    expect(_brightness(tester), Brightness.light);

    await tester.tap(find.text('Dark'));
    await settle(tester);
    expect(sv.settings.themeMode, ThemeMode.dark);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.dark);
    expect(_brightness(tester), Brightness.dark);

    await tester.tap(find.text('Light'));
    await settle(tester);
    expect(sv.settings.themeMode, ThemeMode.light);
    expect(_brightness(tester), Brightness.light);

    await tester.tap(find.text('Large'));
    await settle(tester);
    expect(sv.settings.textScale, 1.15);
    await _done(tester, sv);
  });

  testWidgets('keyboard: arrows move the choice, Enter continues', (tester) async {
    final sv = await _open(tester, Settings()..adoptSystemDefaults(const Locale('vi')));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab); // → "Tiếng Việt"
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(sv.settings.locale, 'en');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // wraps around
    await settle(tester);
    expect(sv.settings.locale, 'vi');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle(tester);
    expect(sv.settings.locale, 'en');

    // Tab leaves the row → "Light"; → "Dark".
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    expect(sv.settings.themeMode, ThemeMode.dark);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.text('Create new identity'), findsOneWidget);
    await _done(tester, sv);
  });

  testWidgets('cards are labelled for screen readers', (tester) async {
    final handle = tester.ensureSemantics();
    final sv = await _open(tester, Settings()..adoptSystemDefaults(const Locale('en')));
    expect(
      tester.getSemantics(find.bySemanticsLabel('English')),
      containsSemantics(label: 'English', isChecked: true, hasCheckedState: true, isInMutuallyExclusiveGroup: true, hasTapAction: true, isFocusable: true),
    );
    expect(tester.getSemantics(find.bySemanticsLabel('Tiếng Việt')), containsSemantics(isChecked: false, isInMutuallyExclusiveGroup: true));
    expect(
      tester.getSemantics(find.bySemanticsLabel('System')),
      containsSemantics(isChecked: true, hint: 'Follows your device’s light or dark setting'),
    );
    await _done(tester, sv);
    handle.dispose();
  });

  testWidgets('choices are saved before the core starts and survive a restart', (tester) async {
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('lumora-onb-')))!;
    final file = File('${dir.path}/ui_settings.json');
    final settings = (await tester.runAsync(() => Settings.load(file)))!..adoptSystemDefaults(const Locale('vi'));
    final sv = await _open(tester, settings);
    await tester.tap(find.text('English'));
    await settle(tester);
    await tester.tap(find.text('Dark'));
    await settle(tester);
    await _waitForFile(tester, file, ['"locale":"en"', '"theme":"dark"']);
    // Still on the first step: no identity, the core never started.
    expect(sv.session.phase, SessionPhase.onboarding);
    expect(sv.session.me, isNull);
    await _done(tester, sv);

    // Next launch: read before the first frame, so it opens in English + dark.
    final again = (await tester.runAsync(() => Settings.load(file)))!;
    expect(again.locale, 'en');
    expect(again.themeMode, ThemeMode.dark);
    final sv2 = AppServices(api: MockLumoraApi(timers: false), settings: again, dataDir: '/tmp/lumora-onb-test');
    setSize(tester, const Size(1440, 900));
    await tester.pumpWidget(LumoraApp(services: sv2, overlays: false, home: const OnboardingScreen()));
    expect(find.text('Welcome to Lumora'), findsOneWidget);
    expect(_brightness(tester), Brightness.dark);
    await _done(tester, sv2);
    await tester.runAsync(() => dir.delete(recursive: true));
  });

  for (final lang in ['vi', 'en']) {
    testWidgets('no overflow at 320 dp ($lang, largest text, both themes)', (tester) async {
      final sv = await _open(
        tester,
        Settings()
          ..locale = lang
          ..themeMode = ThemeMode.dark
          ..textScale = 1.15,
        size: const Size(320, 568),
      );
      expect(tester.takeException(), isNull);
      final light = find.text(lang == 'vi' ? 'Sáng' : 'Light');
      await tester.ensureVisible(light);
      await settle(tester, frames: 3);
      await tester.tap(light);
      await settle(tester);
      expect(tester.takeException(), isNull);
      // The whole step scrolls; the button is reachable.
      await tester.dragUntilVisible(find.text(lang == 'vi' ? 'Tiếp tục' : 'Continue'), find.byType(SingleChildScrollView).first, const Offset(0, -200));
      await tester.tap(find.text(lang == 'vi' ? 'Tiếp tục' : 'Continue'));
      await settle(tester);
      expect(find.text(lang == 'vi' ? 'Tạo danh tính mới' : 'Create new identity'), findsOneWidget);
      await _done(tester, sv);
    });
  }
}
