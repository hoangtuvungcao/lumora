// Microphone permission for calls on Android.
//
// The core opens the microphone itself (AAudio through cpal), so no Flutter
// plugin asks for RECORD_AUDIO on its behalf: without this, a call placed or
// answered before any voice message was recorded goes out silent (AAudio
// returns AAUDIO_ERROR_INTERNAL, "recording not allowed").
//
// Other platforms: iOS asks through AppleAudio, desktops need no runtime
// permission (macOS prompts on first use) — always "granted" here.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class MicPermission {
  static const _ch = MethodChannel('lumora/camera');

  /// Only Android asks here; elsewhere callers skip [ensure] (and its async gap).
  static bool get needed => !kIsWeb && Platform.isAndroid;

  /// True when the microphone may be used (asks once if needed). Never
  /// throws; a prompt nobody answers gives up after a minute.
  static Future<bool> ensure() async {
    if (!needed) return true;
    try {
      final r = await _ch.invokeMethod<String>('requestMic').timeout(const Duration(seconds: 60));
      return r == 'granted';
    } catch (_) {
      return true; // no bridge (tests) or an old native side: let the core try
    }
  }
}
