import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS audio session for calls.
///
/// The Rust core plays and records call audio itself (cpal → RemoteIO), but
/// cpal does not choose an `AVAudioSession` category, and the iOS default
/// (SoloAmbient) cannot record. Before a call starts we switch to
/// play-and-record with Apple's voice processing (echo cancellation, earpiece
/// for voice, speaker for video); afterwards we release the session so music
/// from other apps can resume. Implemented in ios/Runner/AppDelegate.swift.
/// Android (MainActivity / CallAudio.kt, same channel): communication mode for the
/// call, earpiece for voice and loudspeaker for video, and the speaker button.
/// No-op on every other platform.
///
/// Pass the call's real `video` flag also when answering, so a video call
/// starts on the loudspeaker (`.videoChat`) and a voice call on the earpiece
/// (`.voiceChat`). For a call answered on the CallKit screen, CallKit activates
/// and releases the session itself; Swift then only sets the mode and route.
class AppleAudio {
  AppleAudio._();

  static const _channel = MethodChannel('vn.lumora/audio_session');

  /// Android: the sound moved to / away from the loudspeaker by itself (a headset
  /// plugged in, Bluetooth, the system) — the speaker button follows.
  static void listen(void Function(bool speaker) onSpeaker) {
    if (kIsWeb || !Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'speaker' && call.arguments is bool) onSpeaker(call.arguments as bool);
    });
  }
  static bool _active = false;

  static bool get _enabled => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

  static Future<void> startCall({required bool video}) async {
    if (!_enabled) return;
    try {
      await _channel.invokeMethod<void>('startCall', {'video': video});
      _active = true;
    } catch (e) {
      // The core still reports a clear "microphone unavailable" error if this failed.
      debugPrint('audio session (start): $e');
    }
  }

  static Future<void> endCall() async {
    if (!_enabled || !_active) return;
    _active = false;
    try {
      await _channel.invokeMethod<void>('endCall');
    } catch (e) {
      debugPrint('audio session (end): $e');
    }
  }

  /// The speaker button: loudspeaker on/off (off: earpiece, or the headset when one
  /// is connected). [unlessHeadset]: leave a headset / Bluetooth device in charge
  /// (the camera turning on). Returns whether the sound is on the loudspeaker now
  /// (null: unknown).
  static Future<bool?> setSpeaker(bool on, {bool unlessHeadset = false}) async {
    if (!_enabled) return null;
    try {
      return await _channel.invokeMethod<bool>('setSpeaker', {'on': on, 'unlessHeadset': unlessHeadset});
    } catch (e) {
      debugPrint('audio session (speaker): $e');
      return null;
    }
  }
}
