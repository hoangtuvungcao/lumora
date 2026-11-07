// Animated emoji (Noto Animated Emoji, (c) Google, CC BY 4.0).
//
// ~120 popular emoji ship as gzipped Lottie in assets/emoji_anim/ (see
// tool/fetch_animated_emoji.py). Nothing is fetched at runtime and nothing is
// sent over the network: both sides of a chat render the animation from their
// own bundled copy, keyed by the emoji's codepoints.
//
// Battery rules: an animation plays once when it appears (or on tap / hover),
// never while off-screen, at most [AnimatedEmojiLibrary.maxConcurrent] at a
// time; parsed compositions are kept in a small LRU cache; everything falls
// back to the static glyph when the user turned animations off or the OS asks
// for reduced motion.

import 'dart:io' show gzip;
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';

import '../../state/settings.dart';
import 'animated_emoji_set.dart';
import 'emoji_catalog.dart';

abstract final class AnimatedEmojiLibrary {
  /// Animations allowed to run at the same time.
  static const maxConcurrent = 6;

  /// Parsed compositions kept in memory.
  static const cacheSize = 24;

  static final _cache = <String, Future<LottieComposition?>>{}; // insertion-ordered: LRU
  static int _playing = 0;

  /// For tests / diagnostics.
  static int get playing => _playing;

  /// Asset key for [emoji] (codepoints in hex without FE0F), or null when
  /// there is no bundled animation (skin-toned variants use the static glyph).
  static String? keyOf(String emoji) {
    final k = emoji.runes.where((r) => r != 0xFE0F).map((r) => r.toRadixString(16)).join('_');
    return kAnimatedEmojiKeys.contains(k) ? k : null;
  }

  static bool has(String emoji) => keyOf(emoji) != null;

  /// Already parsed (no async gap before the first frame).
  static LottieComposition? cached(String key) => _ready[key];
  static final _ready = <String, LottieComposition>{};

  /// Loads (and caches) the composition for [key]. Parsing runs on a
  /// background isolate so a chat full of big emoji doesn't jank.
  static Future<LottieComposition?> load(String key) {
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit; // most recently used
      return hit;
    }
    final f = _decode(key);
    _cache[key] = f;
    while (_cache.length > cacheSize) {
      final old = _cache.keys.first;
      _cache.remove(old);
      _ready.remove(old);
    }
    return f;
  }

  static Future<LottieComposition?> _decode(String key) async {
    try {
      final data = await rootBundle.load('assets/emoji_anim/$key.json.gz');
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      LottieComposition c;
      try {
        c = await Isolate.run(() => LottieComposition.parseJsonBytes(gzip.decode(bytes)));
      } catch (_) {
        c = LottieComposition.parseJsonBytes(gzip.decode(bytes));
      }
      if (_cache.containsKey(key)) _ready[key] = c;
      return c;
    } catch (_) {
      return null;
    }
  }

  static bool _acquire() {
    if (_playing >= maxConcurrent) return false;
    _playing++;
    return true;
  }

  static void _release() {
    if (_playing > 0) _playing--;
  }

  /// Drops the cache (tests).
  static void reset() {
    _cache.clear();
    _ready.clear();
    _playing = 0;
  }
}

/// Animations are on in Settings and the OS doesn't ask for reduced motion.
bool animatedEmojiEnabled(BuildContext context) {
  final on = context.select<Settings, bool>((s) => s.animatedEmoji);
  return on && !MediaQuery.disableAnimationsOf(context);
}

/// Replays an [AnimatedEmoji] from the outside (hover, press, reaction added).
class EmojiPlayer extends ChangeNotifier {
  void play() => notifyListeners();
}

/// An emoji drawn at [size]: animated when a Noto animation is bundled for
/// it and animations are enabled, otherwise the static glyph.
class AnimatedEmoji extends StatefulWidget {
  const AnimatedEmoji(this.emoji, {super.key, required this.size, this.autoplay = false, this.loop = false, this.replayOnTap = false, this.player});

  final String emoji;
  final double size;

  /// Play once when it first becomes visible.
  final bool autoplay;

  /// Keep looping while visible (only for a single preview at a time).
  final bool loop;

  /// Tapping replays it.
  final bool replayOnTap;

  /// External trigger.
  final EmojiPlayer? player;

  @override
  State<AnimatedEmoji> createState() => _AnimatedEmojiState();
}

class _AnimatedEmojiState extends State<AnimatedEmoji> with SingleTickerProviderStateMixin {
  LottieComposition? _comp;
  late final AnimationController _ctrl;
  String? _key;
  bool? _enabled;
  bool _slot = false;
  bool _wantPlay = false;
  bool _played = false;
  ScrollPosition? _scroll;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this)..addStatusListener(_onStatus);
    widget.player?.addListener(_play);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pos = Scrollable.maybeOf(context)?.position;
    if (pos != _scroll) {
      _scroll?.removeListener(_onScroll);
      _scroll = pos;
      _scroll?.addListener(_onScroll);
    }
  }

  @override
  void didUpdateWidget(AnimatedEmoji old) {
    super.didUpdateWidget(old);
    if (old.player != widget.player) {
      old.player?.removeListener(_play);
      widget.player?.addListener(_play);
    }
    if (old.emoji != widget.emoji) {
      _stop();
      _comp = null;
      _played = false;
      _key = null;
      _setup();
    }
  }

  void _setup() {
    final key = _enabled == true ? AnimatedEmojiLibrary.keyOf(widget.emoji) : null;
    if (key == _key) return;
    _key = key;
    if (key == null) {
      _stop();
      _comp = null;
      return;
    }
    _comp = AnimatedEmojiLibrary.cached(key);
    if (_comp == null) {
      AnimatedEmojiLibrary.load(key).then((c) {
        if (!mounted || _key != key || c == null) return;
        setState(() => _comp = c);
        _afterLoad();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _afterLoad());
    }
  }

  void _afterLoad() {
    if (!mounted || _comp == null) return;
    _ctrl.duration = _comp!.duration;
    if ((widget.autoplay && !_played) || widget.loop || _wantPlay) _play();
  }

  void _onStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed) {
      if (widget.loop && _visible()) {
        _ctrl.forward(from: 0);
      } else {
        _releaseSlot();
        if (mounted) setState(() {}); // back to the static glyph
      }
    }
  }

  void _play() {
    if (!mounted) return;
    if (_comp == null) {
      _wantPlay = _key != null; // play once loaded
      return;
    }
    _wantPlay = false;
    if (!_visible()) {
      _wantPlay = !_played; // play when scrolled into view
      return;
    }
    if (!_slot) {
      if (!AnimatedEmojiLibrary._acquire()) return; // too many running: stay still
      _slot = true;
    }
    _played = true;
    setState(() {}); // glyph -> animation
    _ctrl.forward(from: 0);
  }

  void _onScroll() {
    if (_comp == null) return;
    final vis = _visible();
    if (!vis && _ctrl.isAnimating) {
      _ctrl.stop();
      _releaseSlot();
      setState(() {});
    } else if (vis && (_wantPlay || (widget.loop && !_ctrl.isAnimating))) {
      _play();
    }
  }

  /// At least ~40% of the emoji is inside its scroll viewport and the window.
  bool _visible() {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return false;
    final r = MatrixUtils.transformRect(ro.getTransformTo(null), Offset.zero & ro.size);
    final view = View.maybeOf(context);
    var vis = view == null ? r : Offset.zero & (view.physicalSize / view.devicePixelRatio);
    final sro = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (sro is RenderBox && sro.attached && sro.hasSize) {
      vis = vis.intersect(MatrixUtils.transformRect(sro.getTransformTo(null), Offset.zero & sro.size));
    }
    final i = r.intersect(vis);
    return i.width > 0 && i.height > 0 && i.width * i.height >= 0.4 * r.width * r.height;
  }

  void _releaseSlot() {
    if (_slot) {
      _slot = false;
      AnimatedEmojiLibrary._release();
    }
  }

  void _stop() {
    _ctrl.stop();
    _ctrl.value = 0;
    _releaseSlot();
  }

  @override
  void dispose() {
    widget.player?.removeListener(_play);
    _scroll?.removeListener(_onScroll);
    _releaseSlot();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = animatedEmojiEnabled(context);
    if (enabled != _enabled) {
      _enabled = enabled;
      _setup();
    }
    final s = widget.size;
    final comp = _comp;
    // Idle: the font glyph (same Noto artwork; some animations start from an
    // empty frame, and a glyph costs nothing to repaint). Playing: Lottie.
    final Widget child = comp == null || !_ctrl.isAnimating
        ? Text(
            widget.emoji,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: s * 0.8, height: 1.15),
          )
        : Lottie(composition: comp, controller: _ctrl, width: s, height: s, fit: BoxFit.contain, addRepaintBoundary: true);
    final box = SizedBox(
      width: s,
      height: s,
      child: Center(child: child),
    );
    if (!widget.replayOnTap) return box;
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: _play, child: box);
  }
}

/// The emoji of a message that is only 1-3 emoji (whitespace allowed), or
/// null. Such messages render big.
List<String>? jumboEmojis(String text) {
  final s = text.trim();
  if (s.isEmpty || s.length > 64) return null;
  final out = <String>[];
  for (final g in s.characters) {
    if (g.trim().isEmpty) continue;
    if (out.length == 3) return null;
    // Text-style symbols (©, ®, digits) only count with an emoji presentation.
    if (!g.runes.any((r) => r >= 0x2190 || r == 0xFE0F)) return null;
    if (!EmojiCatalog.instance.isEmoji(g)) return null;
    out.add(g);
  }
  return out.isEmpty ? null : out;
}

/// Big emoji message: 1 → 112 px, 2 → 80 px, 3 → 64 px. Animated ones play
/// once when they appear and again on tap.
class JumboEmoji extends StatelessWidget {
  const JumboEmoji({super.key, required this.emojis});
  final List<String> emojis;

  static double sizeFor(int n) => switch (n) {
    1 => 112,
    2 => 80,
    _ => 64,
  };

  @override
  Widget build(BuildContext context) {
    final size = sizeFor(emojis.length);
    return Row(
      mainAxisSize: MainAxisSize.min,
      // keep moving while on screen (animated emoji); the slot limit and the
      // off-screen pause keep it cheap
      children: [for (final e in emojis) AnimatedEmoji(e, size: size, autoplay: true, loop: true, replayOnTap: true)],
    );
  }
}

/// A quick-reaction button that animates on hover (desktop) or press.
class QuickReactionButton extends StatefulWidget {
  const QuickReactionButton({super.key, required this.emoji, required this.size, required this.onTap, this.padding = EdgeInsets.zero});
  final String emoji;
  final double size;
  final VoidCallback onTap;
  final EdgeInsets padding;

  @override
  State<QuickReactionButton> createState() => _QuickReactionButtonState();
}

class _QuickReactionButtonState extends State<QuickReactionButton> {
  final _player = EmojiPlayer();
  bool _hot = false;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        setState(() => _hot = true);
        _player.play();
      },
      onExit: (_) => setState(() => _hot = false),
      child: Listener(
        onPointerDown: (_) => _player.play(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.onTap,
          child: Padding(
            padding: widget.padding,
            child: AnimatedScale(
              scale: _hot ? 1.15 : 1,
              duration: const Duration(milliseconds: 120),
              child: AnimatedEmoji(widget.emoji, size: widget.size, player: _player),
            ),
          ),
        ),
      ),
    );
  }
}
