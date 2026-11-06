// Screenshots of the video-codec UI: Settings › Nâng cao › Mã hoá video and
// the in-call note when an older Lumora can't take our video. Desktop
// (1440x900) and mobile (390x844 @2x), dark + light, into app/screenshots/.
// Run: flutter test test/video_codec_screenshots_test.dart  (SHOT_LANGS=vi,en)

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/ui/settings/settings_screen.dart';

import 'helpers.dart';

typedef Setup = Future<Widget?> Function(WidgetTester t, AppServices sv, bool desktop);

final shots = <(String, Setup)>[
  ('v01_advanced_codec', (t, sv, d) async {
    return Scaffold(body: SafeArea(child: d ? const SettingsScreen(initial: SettingsPage.advanced) : const SettingsSubPage(page: SettingsPage.advanced)));
  }),
  ('v02_call_peer_needs_update', (t, sv, d) async {
    final p = sv.contacts.friends.first.peer;
    sv.calls.onCall({'call_id': 'cv', 'conv': 'd:$p', 'peer': p, 'state': 'active', 'video': true, 'participants': [p], 'started_at': DateTime.now().millisecondsSinceEpoch});
    sv.calls.onVideoNote({'session': 'cv', 'reason': 'peer_needs_update', 'camera': true});
    return null;
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
  final langs = (Platform.environment['SHOT_LANGS'] ?? 'vi').split(',');
  setUpAll(loadFonts);
  for (final (shot, setup) in shots) {
    for (final desktop in [true, false]) {
      for (final theme in [ThemeMode.dark, ThemeMode.light]) {
        for (final lang in langs) {
          final name = '${shot}_${desktop ? 'desktop' : 'mobile'}_${theme.name}${lang == 'vi' ? '' : '_$lang'}';
          testWidgets(name, (tester) async {
            if (desktop) {
              setSize(tester, const Size(1440, 900));
            } else {
              setSize(tester, const Size(390, 844), dpr: 2);
            }
            final sv = await makeServices(tester, locale: lang, theme: theme);
            final home = await setup(tester, sv, desktop);
            final key = GlobalKey();
            await tester.pumpWidget(RepaintBoundary(key: key, child: LumoraApp(services: sv, home: home)));
            await settle(tester);
            for (var i = 0; i < 3; i++) {
              await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
              await tester.pump(const Duration(milliseconds: 40));
            }
            if (shot == 'v01_advanced_codec') {
              expect(find.text(lang == 'en' ? 'This device' : 'Thiết bị này'), findsOneWidget);
            } else {
              expect(sv.calls.videoNeedsPeerUpdate, isTrue);
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
