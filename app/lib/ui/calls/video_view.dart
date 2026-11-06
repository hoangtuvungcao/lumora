import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';

/// Renders RGBA frames from `api.frame(stream)` into a [RawImage].
///
/// Polls once per display frame (vsync), never overlaps requests, skips
/// decoding while a previous decode is in flight, and pauses entirely when
/// the app is hidden/paused.
class VideoView extends StatefulWidget {
  const VideoView({super.key, required this.stream, this.fit = BoxFit.cover, this.placeholder, this.maxFps = 60, this.onSize, this.onFrame, this.flipX = false});
  final int stream;

  /// Mirror the picture horizontally (not the placeholder): self-view on the back camera.
  final bool flipX;
  final BoxFit fit;
  final Widget? placeholder;
  final int maxFps;
  final void Function(Size size)? onSize;

  /// Called for every decoded frame (FPS counters).
  final VoidCallback? onFrame;

  @override
  State<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<VideoView> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker = createTicker(_onTick);
  ui.Image? _image;
  bool _busy = false;
  Duration _last = Duration.zero;
  late final LumoraApi _api = context.read<LumoraApi>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (visible && !_ticker.isActive) {
      // A restarted ticker counts from zero again: without this reset the
      // frame-rate gate below would hold forever after the app comes back.
      _last = Duration.zero;
      _ticker.start();
    } else if (!visible && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    final minGap = Duration(microseconds: 1000000 ~/ widget.maxFps);
    if (_busy || elapsed - _last < minGap) return;
    _last = elapsed;
    _busy = true;
    _api.frame(widget.stream).then((f) {
      if (f == null || !mounted) {
        _busy = false;
        return;
      }
      ui.decodeImageFromPixels(f.rgba, f.width, f.height, ui.PixelFormat.rgba8888, (img) {
        _busy = false;
        if (!mounted) {
          img.dispose();
          return;
        }
        final old = _image;
        if (old == null || old.width != img.width || old.height != img.height) {
          widget.onSize?.call(Size(img.width.toDouble(), img.height.toDouble()));
        }
        widget.onFrame?.call();
        setState(() => _image = img);
        old?.dispose();
      });
    }).catchError((Object _) {
      _busy = false;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) return widget.placeholder ?? const SizedBox.expand();
    final raw = RawImage(image: img, fit: widget.fit, filterQuality: FilterQuality.medium, width: double.infinity, height: double.infinity);
    return RepaintBoundary(child: widget.flipX ? Transform.flip(flipX: true, child: raw) : raw);
  }
}

/// Ticks once a second while mounted (call timers).
class ElapsedText extends StatefulWidget {
  const ElapsedText({super.key, required this.since, required this.format, this.style});
  final int since;
  final String Function(Duration) format;
  final TextStyle? style;
  @override
  State<ElapsedText> createState() => _ElapsedTextState();
}

class _ElapsedTextState extends State<ElapsedText> {
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(widget.since));
    return Text(widget.format(d.isNegative ? Duration.zero : d), style: widget.style);
  }
}
