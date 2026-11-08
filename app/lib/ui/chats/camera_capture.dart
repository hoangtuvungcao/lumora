// In-chat camera (Android / iOS): tap the shutter for a photo, hold it to
// record a short video, the way people expect from a messenger.
//
// The `camera` plugin runs the device camera (CameraX on Android, AVFoundation
// on iOS). The screen only returns what was captured: a photo goes on to the
// usual photo preview (caption, "Chỉnh sửa", location data stripped) and a
// video to the send sheet, so nothing is sent without one more tap.
//
// No permission / no camera / camera busy (e.g. a video call holds it): the
// same calm panel as the QR scanner, with "Open Settings" when it helps.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../devices/qr_scan.dart' show QrCameraIssue;
import '../theme.dart';
import '../widgets/app_icons.dart';

/// What the camera screen hands back.
sealed class CameraShot {
  const CameraShot();
}

/// A photo or a video file was captured.
class CapturedFile extends CameraShot {
  const CapturedFile(this.path, {required this.video});
  final String path;
  final bool video;
}

/// The gallery button: pick from the library instead.
class PickFromGallery extends CameraShot {
  const PickFromGallery();
}

typedef ChatCamera = Future<CameraShot?> Function(BuildContext context);

/// Phones only (desktop has no in-app camera for messages).
bool get chatCameraSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

Future<CameraShot?> openChatCamera(BuildContext context) => Navigator.of(context, rootNavigator: true).push<CameraShot>(
      PageRouteBuilder(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 240),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, _, _) => const ChatCameraScreen(),
        transitionsBuilder: (_, a, _, c) => FadeTransition(
          opacity: CurvedAnimation(parent: a, curve: Motion.curve),
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Motion.curve)),
            child: c,
          ),
        ),
      ),
    );

/// The composer's camera button / "Camera" in the attach menu. Null hides
/// them (desktop). Tests inject a fake.
ChatCamera? chatCamera = chatCameraSupported ? openChatCamera : null;

/// Longest hold-to-record video.
const kMaxCameraVideo = Duration(seconds: 60);

enum _Issue { denied, failed }

class ChatCameraScreen extends StatefulWidget {
  const ChatCameraScreen({super.key, this.debugPreview, this.debugRecording = false, this.debugDenied = false});

  /// Tests / screenshots: show this instead of a live camera.
  @visibleForTesting
  final Widget? debugPreview;

  /// Screenshots: the hold-to-record state (with [debugPreview]).
  @visibleForTesting
  final bool debugRecording;

  /// Screenshots: the "no permission" panel.
  @visibleForTesting
  final bool debugDenied;

  @override
  State<ChatCameraScreen> createState() => _ChatCameraScreenState();
}

class _ChatCameraScreenState extends State<ChatCameraScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  List<CameraDescription> _cams = const [];
  int _camIndex = 0;
  CameraController? _c;
  bool _audio = true;
  _Issue? _issue;
  bool _starting = false;
  bool _busy = false; // taking a photo / finishing a video
  FlashMode _flash = FlashMode.off;

  // zoom
  double _minZoom = 1, _maxZoom = 1, _zoom = 1, _zoomAtStart = 1;

  // tap to focus
  Offset? _focusAt;
  Timer? _focusTimer;

  // hold to record
  bool _recording = false;
  final Stopwatch _recClock = Stopwatch();
  Timer? _recTimer;
  late final AnimationController _ring;

  bool get _debug => widget.debugPreview != null || widget.debugDenied;

  @override
  void initState() {
    super.initState();
    _ring = AnimationController(vsync: this, duration: kMaxCameraVideo);
    WidgetsBinding.instance.addObserver(this);
    if (widget.debugDenied) {
      _issue = _Issue.denied;
    } else if (_debug) {
      _recording = widget.debugRecording;
      if (_recording) {
        _ring.value = 0.3;
        _recClock.start();
      }
    } else {
      _start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusTimer?.cancel();
    _recTimer?.cancel();
    _ring.dispose();
    final c = _c;
    _c = null;
    c?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_debug) return;
    // The camera must be let go in the background (other apps, the OS).
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (_recording) _stopRecording(keep: false);
      final c = _c;
      if (c != null) {
        setState(() => _c = null);
        c.dispose();
      }
    } else if (state == AppLifecycleState.resumed && _c == null && !_starting) {
      _start();
    }
  }

  Future<void> _start() async {
    _starting = true;
    try {
      if (_cams.isEmpty) {
        _cams = await availableCameras();
        if (_cams.isEmpty) throw CameraException('NoCamera', null);
        // Start on the back camera.
        final back = _cams.indexWhere((d) => d.lensDirection == CameraLensDirection.back);
        _camIndex = back < 0 ? 0 : back;
      }
      await _open(_cams[_camIndex]);
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() => _issue = _isDenied(e.code) ? _Issue.denied : _Issue.failed);
    } catch (_) {
      if (mounted) setState(() => _issue = _Issue.failed);
    } finally {
      _starting = false;
    }
  }

  static bool _isDenied(String code) => code.startsWith('CameraAccess') || code == 'cameraPermission' || code == 'CameraPermissionsDenied';

  Future<void> _open(CameraDescription d) async {
    final c = CameraController(d, ResolutionPreset.veryHigh, enableAudio: _audio, imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : null);
    try {
      await c.initialize();
    } on CameraException catch (e) {
      await c.dispose();
      // Microphone refused: photos still work, videos are silent.
      if (_audio && e.code.startsWith('AudioAccess')) {
        _audio = false;
        return _open(d);
      }
      rethrow;
    }
    if (!mounted) {
      await c.dispose();
      return;
    }
    try {
      await c.setFlashMode(_flash);
    } catch (_) {
      _flash = FlashMode.off; // front cameras often have none
    }
    try {
      _minZoom = await c.getMinZoomLevel();
      _maxZoom = math.min(await c.getMaxZoomLevel(), 10);
    } catch (_) {
      _minZoom = _maxZoom = 1;
    }
    _zoom = _minZoom;
    setState(() {
      _c = c;
      _issue = null;
    });
  }

  Future<void> _flip() async {
    if (_cams.length < 2 || _busy || _recording) return;
    HapticFeedback.selectionClick();
    _camIndex = (_camIndex + 1) % _cams.length;
    final old = _c;
    setState(() => _c = null);
    await old?.dispose();
    try {
      await _open(_cams[_camIndex]);
    } catch (_) {
      if (mounted) setState(() => _issue = _Issue.failed);
    }
  }

  Future<void> _cycleFlash() async {
    final c = _c;
    if (c == null) return;
    final next = switch (_flash) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.always,
      _ => FlashMode.off,
    };
    try {
      await c.setFlashMode(next);
      setState(() => _flash = next);
    } catch (_) {
      if (mounted) setState(() => _flash = FlashMode.off);
    }
  }

  Future<void> _takePhoto() async {
    final c = _c;
    if (c == null || _busy || _recording || !c.value.isInitialized) return;
    HapticFeedback.lightImpact();
    setState(() => _busy = true);
    try {
      final f = await c.takePicture();
      if (mounted) Navigator.of(context).pop(CapturedFile(f.path, video: false));
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        _snack(S.read(context)('cam_shot_failed'));
      }
    }
  }

  Future<void> _startRecording() async {
    final c = _c;
    if (c == null || _busy || _recording || !c.value.isInitialized) return;
    HapticFeedback.mediumImpact();
    try {
      // Video uses the torch, not a flash.
      if (_flash == FlashMode.always) await c.setFlashMode(FlashMode.torch).catchError((_) {});
      await c.startVideoRecording();
    } catch (_) {
      if (mounted) _snack(S.read(context)('cam_shot_failed'));
      return;
    }
    if (!mounted) return;
    _recClock
      ..reset()
      ..start();
    _ring.forward(from: 0);
    _recTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      if (_recClock.elapsed >= kMaxCameraVideo) {
        _stopRecording(keep: true);
      } else {
        setState(() {});
      }
    });
    setState(() => _recording = true);
  }

  Future<void> _stopRecording({required bool keep}) async {
    final c = _c;
    if (!_recording || c == null) return;
    _recTimer?.cancel();
    _recTimer = null;
    _recClock.stop();
    _ring.stop();
    final tooShort = _recClock.elapsed < const Duration(milliseconds: 700);
    setState(() {
      _recording = false;
      _busy = true;
    });
    try {
      final f = await c.stopVideoRecording();
      if (_flash == FlashMode.always) await c.setFlashMode(FlashMode.always).catchError((_) {});
      if (!mounted) return;
      if (!keep) {
        setState(() => _busy = false);
        return;
      }
      if (tooShort) {
        // A quick press that tripped the hold: take a photo instead.
        File(f.path).delete().ignore();
        setState(() => _busy = false);
        return _takePhoto();
      }
      Navigator.of(context).pop(CapturedFile(f.path, video: true));
    } catch (_) {
      if (mounted) {
        setState(() => _busy = false);
        _snack(S.read(context)('cam_shot_failed'));
      }
    }
  }

  void _focus(TapUpDetails d, BoxConstraints box) {
    final c = _c;
    if (c == null || _recording) return;
    final p = Offset((d.localPosition.dx / box.maxWidth).clamp(0, 1), (d.localPosition.dy / box.maxHeight).clamp(0, 1));
    c.setFocusPoint(p).catchError((_) {});
    c.setExposurePoint(p).catchError((_) {});
    _focusTimer?.cancel();
    setState(() => _focusAt = d.localPosition);
    _focusTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _focusAt = null);
    });
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));

  String _elapsed() {
    final e = _recClock.elapsed;
    return '${e.inMinutes}:${(e.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    if (_issue != null) {
      return Scaffold(
        body: Stack(children: [
          QrCameraIssue(denied: _issue == _Issue.denied, backKey: 'cam_back_to_chat', backIcon: AppIcons.back, textPrefix: 'chatcam'),
          SafeArea(child: Padding(padding: const EdgeInsets.all(4), child: CloseButton(onPressed: () => Navigator.of(context).maybePop()))),
        ]),
      );
    }
    final c = _c;
    final ready = _debug || (c != null && c.value.isInitialized);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          // ---- preview (cover, tap to focus, pinch to zoom)
          LayoutBuilder(builder: (context, box) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _focus(d, box),
              onDoubleTap: _flip,
              onScaleStart: (_) => _zoomAtStart = _zoom,
              onScaleUpdate: (d) {
                if (c == null || _maxZoom <= _minZoom || d.pointerCount < 2) return;
                final z = (_zoomAtStart * d.scale).clamp(_minZoom, _maxZoom);
                if ((z - _zoom).abs() < 0.01) return;
                setState(() => _zoom = z);
                c.setZoomLevel(z).catchError((_) {});
              },
              child: Stack(fit: StackFit.expand, children: [
                if (ready) ClipRect(child: _debug ? widget.debugPreview! : _CoverPreview(controller: c!)),
                if (!ready) const Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white70))),
                if (_focusAt != null)
                  Positioned(
                    left: _focusAt!.dx - 34,
                    top: _focusAt!.dy - 34,
                    child: IgnorePointer(
                      child: TweenAnimationBuilder<double>(
                        key: ValueKey(_focusAt),
                        tween: Tween(begin: 1.3, end: 1),
                        duration: Motion.normal,
                        curve: Motion.curve,
                        builder: (_, v, _) => Transform.scale(
                          scale: v,
                          child: Container(
                            width: 68,
                            height: 68,
                            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 1.6)),
                          ),
                        ),
                      ),
                    ),
                  ),
              ]),
            );
          }),
          // ---- top bar
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: _Scrim(
              top: true,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 18),
                  child: Row(children: [
                    _GlassButton(icon: AppIcons.close, tooltip: s('close'), onTap: () => Navigator.of(context).maybePop()),
                    const Spacer(),
                    AnimatedOpacity(
                      opacity: _recording ? 1 : 0,
                      duration: Motion.fast,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: LC.danger, borderRadius: BorderRadius.circular(20)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
                          const SizedBox(width: 6),
                          Text(_elapsed(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
                        ]),
                      ),
                    ),
                    const Spacer(),
                    _GlassButton(
                      icon: switch (_flash) {
                        FlashMode.auto => AppIcons.flashAuto,
                        FlashMode.always || FlashMode.torch => AppIcons.flashOn,
                        _ => AppIcons.flashOff,
                      },
                      tooltip: s(switch (_flash) {
                        FlashMode.auto => 'cam_flash_auto',
                        FlashMode.always || FlashMode.torch => 'cam_flash_on',
                        _ => 'cam_flash_off',
                      }),
                      active: _flash != FlashMode.off,
                      onTap: _recording ? null : _cycleFlash,
                    ),
                  ]),
                ),
              ),
            ),
          ),
          // ---- bottom controls
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _Scrim(
              top: false,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 22, 28, 18),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (_maxZoom > _minZoom && _zoom > _minZoom + 0.05)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(14)),
                          child: Text('${(_zoom / _minZoom).toStringAsFixed(1)}×', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      AnimatedOpacity(
                        opacity: _recording ? 0 : 1,
                        duration: Motion.fast,
                        child: _GlassButton(
                          key: const ValueKey('cam_gallery'),
                          icon: AppIcons.gallery,
                          size: 52,
                          tooltip: s('att_media'),
                          onTap: _recording || _busy ? null : () => Navigator.of(context).pop(const PickFromGallery()),
                        ),
                      ),
                      _Shutter(
                        recording: _recording,
                        busy: _busy || !ready,
                        progress: _ring,
                        onTap: _takePhoto,
                        onHoldStart: _startRecording,
                        onHoldEnd: () => _stopRecording(keep: true),
                      ),
                      AnimatedOpacity(
                        opacity: _recording || (_cams.length < 2 && !_debug) ? 0 : 1,
                        duration: Motion.fast,
                        child: _GlassButton(
                          key: const ValueKey('cam_flip'),
                          icon: AppIcons.switchCamera,
                          size: 52,
                          tooltip: s('cam_switch'),
                          onTap: _recording || _busy ? null : _flip,
                        ),
                      ),
                    ]),
                    const SizedBox(height: 14),
                    Text(
                      s(_recording ? 'cam_release_to_send' : 'cam_hint'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 13, shadows: [Shadow(blurRadius: 6, color: Colors.black54)]),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// The camera picture scaled to fill the screen (cropped, never stretched).
class _CoverPreview extends StatelessWidget {
  const _CoverPreview({required this.controller});
  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final ps = controller.value.previewSize;
    if (ps == null) return CameraPreview(controller);
    // previewSize is in sensor (landscape) orientation.
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final w = portrait ? ps.height : ps.width;
    final h = portrait ? ps.width : ps.height;
    return FittedBox(fit: BoxFit.cover, child: SizedBox(width: w, height: h, child: CameraPreview(controller)));
  }
}

/// Soft dark gradient behind the controls so they read on any picture.
class _Scrim extends StatelessWidget {
  const _Scrim({required this.top, required this.child});
  final bool top;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: top ? Alignment.topCenter : Alignment.bottomCenter,
            end: top ? Alignment.bottomCenter : Alignment.topCenter,
            colors: const [Color(0x99000000), Color(0x00000000)],
          ),
        ),
        child: child,
      );
}

class _GlassButton extends StatelessWidget {
  const _GlassButton({super.key, required this.icon, required this.tooltip, required this.onTap, this.size = 44, this.active = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final bool active;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          label: tooltip,
          child: Material(
            color: active ? Colors.white : Colors.black.withValues(alpha: 0.38),
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: SizedBox(width: size, height: size, child: Icon(icon, size: size * 0.46, color: active ? Colors.black : Colors.white)),
            ),
          ),
        ),
      );
}

/// Tap: photo. Hold: video (red, with a ring that fills up to the limit);
/// releasing sends it on to the preview.
class _Shutter extends StatelessWidget {
  const _Shutter({required this.recording, required this.busy, required this.progress, required this.onTap, required this.onHoldStart, required this.onHoldEnd});
  final bool recording;
  final bool busy;
  final Animation<double> progress;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Semantics(
      button: true,
      label: s('cam_take_photo'),
      hint: s('cam_hint'),
      child: GestureDetector(
        key: const ValueKey('cam_shutter'),
        onTap: busy || recording ? null : onTap,
        onLongPressStart: busy ? null : (_) => onHoldStart(),
        onLongPressEnd: (_) => onHoldEnd(),
        onLongPressCancel: onHoldEnd,
        child: SizedBox(
          width: 84,
          height: 84,
          child: Stack(alignment: Alignment.center, children: [
            AnimatedScale(
              scale: recording ? 1.12 : 1,
              duration: Motion.normal,
              curve: Motion.curve,
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
              ),
            ),
            if (recording)
              AnimatedBuilder(
                animation: progress,
                builder: (_, _) => SizedBox(
                  width: 90,
                  height: 90,
                  child: CircularProgressIndicator(value: progress.value, strokeWidth: 4, color: LC.danger, strokeCap: StrokeCap.round),
                ),
              ),
            AnimatedContainer(
              duration: Motion.normal,
              curve: Motion.curve,
              width: recording ? 30 : 64,
              height: recording ? 30 : 64,
              decoration: BoxDecoration(
                color: recording ? LC.danger : (busy ? Colors.white54 : Colors.white),
                borderRadius: BorderRadius.circular(recording ? 8 : 32),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
