import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/api_factory.dart';
import 'core/links.dart';
import 'debug_driver.dart';
import 'platform/desktop_links.dart';
import 'ui/codec_licenses.dart';
import 'ui/emoji_font.dart';
import 'ui/flows.dart';
import 'ui/startup_error.dart';
import 'ui/widgets/common.dart' show LayerBack;
import 'state/settings.dart';

const _onboardEnv = String.fromEnvironment('LUMORA_ONBOARD');

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Android Back reaches the call / remote / lock layers before the app's Navigator.
  LayerBack.install();
  // Keep decoded-image memory bounded.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 64 << 20
    ..maximumSize = 300;
  // Colour emoji on desktops without a usable emoji font (non-blocking).
  unawaited(loadEmojiFallbackFont());
  registerEmojiLicenses();
  registerCodecLicenses();
  await _launch(args);
}

/// Starts the app, or shows a friendly error screen (with retry) when the
/// data folder or the core component is unavailable.
Future<void> _launch(List<String> args) async {
  String dataDir;
  try {
    dataDir = Platform.environment['LUMORA_DATA_DIR'] ?? (await getApplicationSupportDirectory()).path;
    Directory(dataDir).createSync(recursive: true);
  } catch (e) {
    runApp(StartupErrorApp(problem: StartupProblem.dataDir, detail: '$e', onRetry: () => _launch(args)));
    return;
  }

  final load = createApi();
  final api = load.api;
  if (api == null) {
    runApp(StartupErrorApp(problem: StartupProblem.core, detail: load.error ?? '', onRetry: () => _launch(args)));
    return;
  }
  final settingsFile = api.isMock ? null : File('$dataDir${Platform.pathSeparator}ui_settings.json');
  final firstRun = settingsFile == null || !settingsFile.existsSync();
  final settings = await Settings.load(settingsFile);
  if (firstRun) {
    // Language and theme follow the system until the welcome step; saved
    // right away so the next launch opens in the same look (no flash).
    // (The in-memory demo keeps its dark look so debug snapshots stay stable.)
    final theme = settings.themeMode;
    settings.adoptSystemDefaults(WidgetsBinding.instance.platformDispatcher.locale);
    if (settingsFile == null) settings.themeMode = theme;
    await settings.save();
  }
  if (api.isMock && _onboardEnv != '1') {
    // Demo mode: skip onboarding unless explicitly requested.
    settings.onboarded = true;
  }

  if (!kReleaseMode && Platform.environment['LUMORA_LAN_ONLY'] == '1') {
    settings
      ..nostr = false
      ..dht = false
      ..upnp = false;
  }

  final services = AppServices(api: api, settings: settings, dataDir: '$dataDir${Platform.pathSeparator}core');
  final snapDir = DebugDriver.snapshotDir;
  runApp(snapDir == null
      ? LumoraApp(services: services)
      : RepaintBoundary(key: snapshotKey, child: LumoraApp(services: services)));
  final link = args.map(acceptIncomingLink).nonNulls.firstOrNull;
  if (link != null) pendingDeepLink.value = link;
  // Links from the OS: other apps (Android / Apple), later launches (Windows / Linux).
  unawaited(DesktopLinks.init());
  await services.boot();
  if (snapDir != null) {
    await maybeAutoCreate(services);
    DebugDriver(services, snapDir).start();
  }
}
