import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/settings.dart';

bool _fontsLoaded = false;

/// Loads Be Vietnam Pro, Material Icons and (if present) Noto Color Emoji so
/// screenshots render real glyphs instead of boxes.
Future<void> loadFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    var any = false;
    for (final p in paths) {
      final f = File(p);
      if (f.existsSync()) {
        loader.addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer)));
        any = true;
      }
    }
    if (any) await loader.load();
  }

  await load('BeVietnamPro', [
    'assets/fonts/BeVietnamPro-Regular.ttf',
    'assets/fonts/BeVietnamPro-Medium.ttf',
    'assets/fonts/BeVietnamPro-SemiBold.ttf',
    'assets/fonts/BeVietnamPro-Bold.ttf',
  ]);
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? _guessFlutterRoot();
  await load('MaterialIcons', ['$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
  // Phosphor icon fonts from the pub cache (package font family names).
  try {
    final cfg = jsonDecode(File('.dart_tool/package_config.json').readAsStringSync()) as Map<String, dynamic>;
    for (final p in (cfg['packages'] as List).cast<Map<String, dynamic>>()) {
      if (p['name'] == 'phosphor_flutter') {
        var root = Uri.parse(p['rootUri'] as String);
        if (!root.isAbsolute) root = Uri.file('${Directory.current.path}/.dart_tool/').resolveUri(root);
        final dir = root.toFilePath();
        for (final (family, file) in [
          ('Regular', 'Phosphor'),
          ('Fill', 'Phosphor-Fill'),
          ('Duotone', 'Phosphor-Duotone'),
          ('Bold', 'Phosphor-Bold'),
        ]) {
          await load('packages/phosphor_flutter/Phosphor$family', ['$dir/lib/fonts/$file.ttf']);
        }
      }
    }
  } catch (_) {}
  // The colour emoji font the desktop builds bundle (COLRv1), else the system one.
  final bundledEmoji = File('assets/desktop/NotoColorEmoji-COLRv1.ttf');
  await load('NotoColorEmoji', [bundledEmoji.existsSync() ? bundledEmoji.path : '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf']);
  // Monospace fallback used for codes/ids.
  await load('monospace', ['/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf']);
  // Code font of the file viewers / previews (full Vietnamese coverage).
  await load('Noto Sans Mono', ['/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf', '/usr/share/fonts/truetype/noto/NotoSansMono-Bold.ttf']);
}

String _guessFlutterRoot() {
  final exe = File(Platform.resolvedExecutable).absolute.path;
  final i = exe.indexOf('/bin/cache/');
  return i > 0 ? exe.substring(0, i) : '';
}

/// Fresh services backed by a deterministic, timer-free mock.
Future<AppServices> makeServices(WidgetTester tester, {String locale = 'vi', ThemeMode theme = ThemeMode.dark, bool start = true, MockLumoraApi? api}) async {
  api ??= MockLumoraApi(timers: false);
  final settings = Settings()
    ..locale = locale
    ..themeMode = theme
    ..onboarded = true;
  final sv = AppServices(api: api, settings: settings, dataDir: '/tmp/lumora-test');
  if (start) {
    await tester.runAsync(() => sv.unlock(null));
  }
  return sv;
}

void setSize(WidgetTester tester, Size logical, {double dpr = 1}) {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = logical * dpr;
}

void resetSize(WidgetTester tester) {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

/// Pumps a few frames to let async loads (mock API) complete without
/// waiting for never-ending animations to settle.
Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
