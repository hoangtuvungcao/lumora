import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/links.dart';
import '../ui/flows.dart' show pendingDeepLink;

/// Lumora links handed over by the OS, on the `lumora/links` channel.
///
/// Android: `https://getlumora.pages.dev/{add,join,remote}/…` (verified App
/// Links) and `lumora://{add,join,remote}/…` — MainActivity keeps the link of
/// the launch intent until Dart calls `ready`, later ones (onNewIntent) come as
/// `open`. iOS / macOS: the `lumora://` URL scheme (CFBundleURLTypes), same
/// protocol (AppDelegate / MainFlutterWindow `LumoraLinks`).
///
/// Windows and Linux (`lumora://`, URL protocol / x-scheme-handler):
/// Lumora runs once per data folder there. A second launch (a clicked invite
/// link, the desktop entry, a shortcut) hands its link to the running instance
/// and exits: Windows via WM_COPYDATA (windows/runner/lumora_links.cpp), Linux
/// via the D-Bus "open-link" action (linux/runner/my_application.cc). The
/// runner forwards it here on the `lumora/links` channel and we put it into
/// [pendingDeepLink], exactly like a link given on the command line at start.
///
/// Links that arrive before Dart listens are kept natively and returned by
/// `ready`. Every link goes through [acceptIncomingLink]: device-link codes
/// are never taken from outside the app.
class DesktopLinks {
  DesktopLinks._();

  static const channel = MethodChannel('lumora/links');

  /// Tests: pretend to run on a desktop with a native links channel.
  @visibleForTesting
  static bool? debugSupported;

  static bool get supported => debugSupported ?? (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isAndroid || Platform.isIOS || Platform.isMacOS));

  static bool _started = false;

  /// Starts listening. Call once from main() after runApp.
  static Future<void> init() async {
    if (_started || !supported) return;
    _started = true;
    channel.setMethodCallHandler(_onCall);
    try {
      final queued = await channel.invokeListMethod<String>('ready');
      for (final link in queued ?? const <String>[]) {
        _open(link);
      }
    } on MissingPluginException {
      // A runner without the channel (older build, tests): links from argv only.
    } catch (e) {
      debugPrint('desktop links: $e');
    }
  }

  static Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'open') _open(call.arguments?.toString());
    return null;
  }

  static void _open(String? link) {
    final ok = acceptIncomingLink(link);
    if (ok == null) return;
    pendingDeepLink.value = ok; // the home shell consumes and clears it
  }

  @visibleForTesting
  static void debugReset() {
    _started = false;
    channel.setMethodCallHandler(null);
  }
}
