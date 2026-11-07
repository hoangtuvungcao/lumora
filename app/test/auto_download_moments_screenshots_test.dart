// Screenshots of the automatic-download settings (Wi-Fi / mobile data / roaming) and the
// Khoảnh khắc audience screens (composer sheet, hide-from picker, Settings › Privacy rows)
// at desktop (1440x900) and mobile (390x844 @2x) sizes in dark + light, written to
// app/screenshots/. Run: flutter test test/auto_download_moments_screenshots_test.dart
// Optional: SHOT_FILTER=m02 / SHOT_THEME=dark / SHOT_LANGS=vi,en.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/ui/chats/stories.dart';
import 'package:lumora/ui/settings/settings_screen.dart';

import 'helpers.dart';

typedef Setup = Future<Widget?> Function(WidgetTester t, AppServices sv, bool desktop);
typedef After = Future<void> Function(WidgetTester t, AppServices sv, bool desktop);

class Shot {
  const Shot(this.name, this.setup, {this.after});
  final String name;
  final Setup setup;
  final After? after;
}

Widget _settings(bool desktop, SettingsPage page) =>
    Scaffold(body: SafeArea(child: desktop ? SettingsScreen(initial: page) : SettingsSubPage(page: page)));

Future<void> _flush(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
  await settle(t, frames: 8);
}

Future<void> _show(WidgetTester t, Finder f) async {
  await _flush(t);
  await t.ensureVisible(f);
  await settle(t, frames: 4);
  // a little room above the section
  await t.drag(find.byType(Scrollable).last, const Offset(0, 120));
  await settle(t, frames: 6);
}

final shots = <Shot>[
  Shot('m01_auto_download_wifi', (t, sv, d) async => _settings(d, SettingsPage.storage),
      after: (t, sv, d) => _show(t, find.byKey(const ValueKey('auto_network')))),
  Shot('m02_auto_download_roaming', (t, sv, d) async => _settings(d, SettingsPage.storage), after: (t, sv, d) async {
    await _show(t, find.byKey(const ValueKey('auto_network')));
    await t.tap(find.descendant(of: find.byKey(const ValueKey('auto_network')), matching: find.byType(Text)).last);
    await settle(t, frames: 6);
  }),
  Shot('m03_moments_privacy', (t, sv, d) async {
    await t.runAsync(() => sv.stories.setAudience(hidden: [sv.contacts.friends[1].peer], close: [sv.contacts.friends[0].peer, sv.contacts.friends[2].peer]));
    return _settings(d, SettingsPage.privacy);
  }, after: (t, sv, d) => _show(t, find.byKey(const ValueKey('story_hidden_row')))),
  Shot('m04_story_audience_sheet', (t, sv, d) async {
    await t.runAsync(() => sv.stories.setAudience(hidden: [sv.contacts.friends[1].peer], close: [sv.contacts.friends[0].peer]));
    return const StoryComposer();
  }, after: (t, sv, d) async {
    await _flush(t);
    await t.tap(find.byKey(const ValueKey('story_audience_chip')));
    await settle(t, frames: 8);
  }),
  Shot('m05_hide_from_picker', (t, sv, d) async {
    await t.runAsync(() => sv.stories.setAudience(hidden: [sv.contacts.friends[1].peer]));
    return _settings(d, SettingsPage.privacy);
  }, after: (t, sv, d) async {
    await _show(t, find.byKey(const ValueKey('story_hidden_row')));
    await t.tap(find.byKey(const ValueKey('story_hidden_row')));
    await settle(t, frames: 8);
  }),
];

Future<void> _capture(WidgetTester tester, GlobalKey key, String path) async {
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final f = File(path);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  final filter = Platform.environment['SHOT_FILTER'];
  final themeFilter = Platform.environment['SHOT_THEME'];
  final langs = (Platform.environment['SHOT_LANGS'] ?? 'vi').split(',');

  setUpAll(loadFonts);

  for (final shot in shots) {
    if (filter != null && !shot.name.contains(filter)) continue;
    for (final desktop in [true, false]) {
      for (final theme in [ThemeMode.dark, ThemeMode.light]) {
        if (themeFilter != null && theme.name != themeFilter) continue;
        for (final lang in langs) {
          final name = '${shot.name}_${desktop ? 'desktop' : 'mobile'}_${theme.name}${lang == 'vi' ? '' : '_$lang'}';
          testWidgets(name, (tester) async {
            if (desktop) {
              setSize(tester, const Size(1440, 900));
            } else {
              setSize(tester, const Size(390, 844), dpr: 2);
            }
            final sv = await makeServices(tester, locale: lang, theme: theme);
            final home = await shot.setup(tester, sv, desktop);
            final key = GlobalKey();
            await tester.pumpWidget(RepaintBoundary(key: key, child: LumoraApp(services: sv, home: home)));
            await settle(tester);
            if (shot.after != null) {
              await shot.after!(tester, sv, desktop);
              await settle(tester, frames: 6);
            }
            for (var i = 0; i < 2; i++) {
              await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
              await tester.pump(const Duration(milliseconds: 40));
            }
            await _capture(tester, key, 'screenshots/$name.png');
            await tester.pumpWidget(const SizedBox());
            await tester.pump(const Duration(seconds: 100));
            sv.dispose();
            resetSize(tester);
          });
        }
      }
    }
  }
}
