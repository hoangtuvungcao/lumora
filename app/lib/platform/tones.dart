// Call ringtone, outgoing ringback and the message / @mention / reminder
// alerts on every platform.
//
// [TonePlayer] is what the app's sound logic (state/sound_alerts.dart) talks
// to; one implementation per platform family, picked by [TonePlayer.platform]:
//
//  * Android – everything native (MainActivity `lumora/service` → CallTones.kt):
//    the phone's own ringtone and notification sound (our own @mention and
//    reminder sounds, as their notification channels use), respecting the ringer
//    mode (silent / vibrate) and Do Not Disturb, plus vibration; the ringback
//    is our asset on the in-call (voice-communication) stream.
//  * iOS / macOS – our assets through just_audio (already a dependency, AVPlayer
//    underneath). It never activates or changes the audio session, so the
//    call's own session (apple_audio.dart, CallKit) is left alone; on iOS the
//    ringtone and ping follow the ring/silent switch like any non-call sound.
//    Vibration on iPhone: the system vibrate sound.
//  * Windows – winmm `PlaySoundW` (dart:ffi, no plugin): async, looping WAV.
//  * Linux – `paplay` / `pw-play` / `aplay` (PulseAudio / PipeWire / ALSA),
//    restarted for as long as the loop should play.
//
// The tones are Lumora's own (branding/tools/make_sounds.py): 16-bit PCM WAV
// in assets/sounds/, so every backend above plays them.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// One-shot alerts, each with its own sound.
enum Alert { message, mention, reminder }

/// Plays (or stops) the app's call and message sounds.
abstract class TonePlayer {
  /// Incoming call: loop the ringtone (and/or vibrate) until [stop].
  Future<void> ring({required bool sound, required bool vibrate});

  /// Outgoing call: loop the soft ringback until [stop].
  Future<void> ringback();

  /// Stops the ringtone / ringback (and the ring vibration).
  Future<void> stop();

  /// A new message / @mention / a reminder going off: its sound once and/or a
  /// short vibration.
  Future<void> alert(Alert kind, {required bool sound, required bool vibrate});

  /// The player for this platform (no-op where nothing can play).
  static TonePlayer platform() {
    if (kIsWeb) return const SilentTonePlayer();
    if (Platform.isAndroid) return AndroidTonePlayer();
    if (Platform.isIOS || Platform.isMacOS) return AssetTonePlayer(iphone: Platform.isIOS);
    if (Platform.isWindows) return WindowsTonePlayer();
    if (Platform.isLinux) return LinuxTonePlayer();
    return const SilentTonePlayer();
  }

  /// Phones vibrate (the "Rung" setting is shown there only).
  static bool get canVibrate => debugIsPhone ?? (!kIsWeb && (Platform.isAndroid || Platform.isIOS));

  /// Tests: pretend to be (or not be) a phone.
  @visibleForTesting
  static bool? debugIsPhone;
}

class Tones {
  static const ringtone = 'assets/sounds/ringtone.wav';
  static const ringback = 'assets/sounds/ringback.wav';
  static const message = 'assets/sounds/message.wav';
  static const mention = 'assets/sounds/mention.wav';
  static const reminder = 'assets/sounds/reminder.wav';

  static String of(Alert a) => switch (a) {
        Alert.message => message,
        Alert.mention => mention,
        Alert.reminder => reminder,
      };
}

class SilentTonePlayer implements TonePlayer {
  const SilentTonePlayer();
  @override
  Future<void> ring({required bool sound, required bool vibrate}) async {}
  @override
  Future<void> ringback() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> alert(Alert kind, {required bool sound, required bool vibrate}) async {}
}

// ------------------------------------------------------------------ Android

/// Android: CallTones.kt does the work (system ringtone / notification sound,
/// ringer mode, Do Not Disturb, vibration, the call notification's sound).
class AndroidTonePlayer implements TonePlayer {
  static const _ch = MethodChannel('lumora/service');

  Future<void> _call(String method, [Map<String, Object?>? args]) async {
    try {
      await _ch.invokeMethod<void>(method, args);
    } catch (e) {
      debugPrint('Lumora: tones.$method: $e');
    }
  }

  @override
  Future<void> ring({required bool sound, required bool vibrate}) => _call('ringStart', {'sound': sound, 'vibrate': vibrate});
  @override
  Future<void> ringback() => _call('ringbackStart', {'asset': Tones.ringback});
  @override
  Future<void> stop() => _call('ringStop');
  @override
  Future<void> alert(Alert kind, {required bool sound, required bool vibrate}) => _call('ping', {'kind': kind.name, 'sound': sound, 'vibrate': vibrate});
}

// ------------------------------------------------------------ iOS / macOS

class AssetTonePlayer implements TonePlayer {
  AssetTonePlayer({required this.iphone});
  final bool iphone;

  AudioPlayer? _loop;
  String? _loopAsset;
  final Map<Alert, AudioPlayer> _alerts = {};
  Timer? _buzz;

  // Never touch the audio session: during a call it belongs to the call
  // (apple_audio.dart / CallKit); otherwise the default one respects the
  // iPhone's silent switch.
  AudioPlayer _player() => AudioPlayer(handleAudioSessionActivation: false, handleInterruptions: false);

  Future<void> _startLoop(String asset) async {
    try {
      final p = _loop ??= _player();
      if (_loopAsset != asset) {
        await p.setAsset(asset);
        _loopAsset = asset;
      }
      await p.setLoopMode(LoopMode.one);
      await p.seek(Duration.zero);
      unawaited(p.play().catchError((Object _) {}));
    } catch (e) {
      debugPrint('Lumora: tone $asset: $e');
    }
  }

  @override
  Future<void> ring({required bool sound, required bool vibrate}) async {
    await stop();
    if (sound) await _startLoop(Tones.ringtone);
    if (vibrate && iphone) {
      HapticFeedback.vibrate();
      _buzz = Timer.periodic(const Duration(milliseconds: 2600), (_) => HapticFeedback.vibrate());
    }
  }

  @override
  Future<void> ringback() async {
    await stop();
    await _startLoop(Tones.ringback);
  }

  @override
  Future<void> stop() async {
    _buzz?.cancel();
    _buzz = null;
    try {
      await _loop?.pause();
    } catch (_) {}
  }

  @override
  Future<void> alert(Alert kind, {required bool sound, required bool vibrate}) async {
    if (vibrate && iphone) {
      HapticFeedback.vibrate();
      if (kind == Alert.reminder) Timer(const Duration(milliseconds: 900), HapticFeedback.vibrate);
    }
    if (!sound) return;
    try {
      final p = _alerts[kind] ??= _player();
      if (p.audioSource == null) await p.setAsset(Tones.of(kind));
      await p.seek(Duration.zero);
      unawaited(p.play().catchError((Object _) {}));
    } catch (e) {
      debugPrint('Lumora: ${kind.name} tone: $e');
    }
  }
}

// ------------------------------------------------------------ desktop files

/// Desktop players need a real file: the asset is written once to the temp dir.
class _AssetFiles {
  static final Map<String, Future<String?>> _paths = {};

  static Future<String?> path(String asset) => _paths[asset] ??= _write(asset);

  static Future<String?> _write(String asset) async {
    try {
      // A bundled build has the file next to the executable already.
      final exe = File(Platform.resolvedExecutable).parent.path;
      final bundled = File('$exe${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}${asset.replaceAll('/', Platform.pathSeparator)}');
      if (await bundled.exists()) return bundled.path;
      final data = await rootBundle.load(asset);
      final dir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}lumora_sounds');
      await dir.create(recursive: true);
      final f = File('${dir.path}${Platform.pathSeparator}${asset.split('/').last}');
      await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      return f.path;
    } catch (e) {
      debugPrint('Lumora: sound file $asset: $e');
      _paths.remove(asset);
      return null;
    }
  }
}

// ------------------------------------------------------------------ Windows

typedef _PlaySoundC = Int32 Function(Pointer<Utf16> sound, IntPtr module, Uint32 flags);
typedef _PlaySoundDart = int Function(Pointer<Utf16> sound, int module, int flags);

/// winmm PlaySound: one sound at a time (a ping while a ring loops is skipped).
class WindowsTonePlayer implements TonePlayer {
  static const _async = 0x0001, _noDefault = 0x0002, _loop = 0x0008, _noStop = 0x0010, _filename = 0x00020000;

  _PlaySoundDart? _fn;
  bool _looping = false;
  int _gen = 0;

  /// File names for winmm, allocated once per file and never freed (winmm may
  /// still read one after PlaySound returned; there are only three).
  static final Map<String, Pointer<Utf16>> _names = {};

  _PlaySoundDart? get _playSound {
    try {
      return _fn ??= DynamicLibrary.open('winmm.dll').lookupFunction<_PlaySoundC, _PlaySoundDart>('PlaySoundW');
    } catch (e) {
      debugPrint('Lumora: winmm: $e');
      return null;
    }
  }

  void _play(String path, int flags) {
    final fn = _playSound;
    if (fn == null) return;
    fn(_names[path] ??= path.toNativeUtf16(), 0, flags | _filename | _async | _noDefault);
  }

  Future<void> _startLoop(String asset) async {
    final gen = ++_gen;
    final path = await _AssetFiles.path(asset);
    if (path == null || gen != _gen) return;
    _looping = true;
    _play(path, _loop);
  }

  @override
  Future<void> ring({required bool sound, required bool vibrate}) async {
    await stop();
    if (sound) await _startLoop(Tones.ringtone);
  }

  @override
  Future<void> ringback() async {
    await stop();
    await _startLoop(Tones.ringback);
  }

  @override
  Future<void> stop() async {
    _gen++;
    if (!_looping) return;
    _looping = false;
    final fn = _playSound;
    if (fn != null) fn(nullptr, 0, 0);
  }

  @override
  Future<void> alert(Alert kind, {required bool sound, required bool vibrate}) async {
    if (!sound || _looping) return;
    final path = await _AssetFiles.path(Tones.of(kind));
    if (path == null || _looping) return;
    _play(path, _noStop);
  }
}

// -------------------------------------------------------------------- Linux

class LinuxTonePlayer implements TonePlayer {
  int _gen = 0;
  Process? _proc;
  static Future<List<String>?>? _cmd;

  /// The first player found: PulseAudio/PipeWire's `paplay`, `pw-play`, ALSA's `aplay`.
  static Future<List<String>?> _command() => _cmd ??= () async {
        for (final c in const [
          ['paplay', '--client-name=Lumora'],
          ['pw-play'],
          ['aplay', '-q'],
        ]) {
          try {
            final r = await Process.run('which', [c.first]);
            if (r.exitCode == 0) return c;
          } catch (_) {}
        }
        debugPrint('Lumora: no audio player (paplay / pw-play / aplay) found');
        return null;
      }();

  Future<void> _startLoop(String asset) async {
    final gen = ++_gen;
    final path = await _AssetFiles.path(asset);
    final cmd = await _command();
    if (path == null || cmd == null) return;
    while (gen == _gen) {
      final started = DateTime.now();
      try {
        final p = await Process.start(cmd.first, [...cmd.skip(1), path]);
        if (gen != _gen) {
          p.kill();
          return;
        }
        _proc = p;
        await p.exitCode;
      } catch (_) {
        return;
      }
      // a player that fails at once (no sound server): don't spin
      if (DateTime.now().difference(started) < const Duration(milliseconds: 300)) return;
    }
  }

  @override
  Future<void> ring({required bool sound, required bool vibrate}) async {
    await stop();
    if (sound) unawaited(_startLoop(Tones.ringtone));
  }

  @override
  Future<void> ringback() async {
    await stop();
    unawaited(_startLoop(Tones.ringback));
  }

  @override
  Future<void> stop() async {
    _gen++;
    _proc?.kill();
    _proc = null;
  }

  @override
  Future<void> alert(Alert kind, {required bool sound, required bool vibrate}) async {
    if (!sound) return;
    final path = await _AssetFiles.path(Tones.of(kind));
    final cmd = await _command();
    if (path == null || cmd == null) return;
    try {
      await Process.start(cmd.first, [...cmd.skip(1), path], mode: ProcessStartMode.detached);
    } catch (_) {}
  }
}
