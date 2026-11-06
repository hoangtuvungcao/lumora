// Lumora brand mark (branding/logo/*.svg, copied to assets/logo/).
// Per BRAND.md: the mark sits on a transparent background; below 32 px the
// optical "-small" variant is used; the only allowed container is the app
// icon tile ([LumoraAppIcon]).

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme.dart';

class LumoraLogo extends StatelessWidget {
  const LumoraLogo({super.key, this.size = 40, this.mono = false});
  final double size;

  /// White single-colour mark for coloured/photographic backgrounds.
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final asset = mono
        ? 'assets/logo/lumora-mark-mono-light.svg'
        : (size < 32 ? 'assets/logo/lumora-mark-small.svg' : 'assets/logo/lumora-mark.svg');
    return RepaintBoundary(
      child: SvgPicture.asset(asset, width: size, height: size, semanticsLabel: 'Lumora'),
    );
  }
}

/// Full-bleed gradient app-icon tile.
class LumoraAppIcon extends StatelessWidget {
  const LumoraAppIcon({super.key, this.size = 64});
  final double size;
  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(child: SvgPicture.asset('assets/logo/lumora-app-icon.svg', width: size, height: size));
}

/// Logo + wordmark.
class LumoraWordmark extends StatelessWidget {
  const LumoraWordmark({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      LumoraLogo(size: size),
      SizedBox(width: size * 0.2),
      Text('Lumora',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: size * 0.66,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3,
            color: context.lc.text,
          )),
    ]);
  }
}

/// Onboarding hero: the app icon scales/fades in, then a soft halo breathes.
class AnimatedLogo extends StatefulWidget {
  const AnimatedLogo({super.key, this.size = 96});
  final double size;
  @override
  State<AnimatedLogo> createState() => _AnimatedLogoState();
}

class _AnimatedLogoState extends State<AnimatedLogo> with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
  late final AnimationController _halo = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));

  @override
  void initState() {
    super.initState();
    _intro.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) _halo.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _intro.dispose();
    _halo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final intro = CurvedAnimation(parent: _intro, curve: Curves.easeOutBack);
    return RepaintBoundary(
      child: SizedBox(
        width: s * 1.6,
        height: s * 1.6,
        child: AnimatedBuilder(
          animation: Listenable.merge([_intro, _halo]),
          builder: (context, child) => Stack(alignment: Alignment.center, children: [
            Opacity(
              opacity: (_intro.value * (0.35 + 0.25 * _halo.value)).clamp(0.0, 1.0),
              child: Container(
                width: s * (1.25 + 0.15 * _halo.value),
                height: s * (1.25 + 0.15 * _halo.value),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [LC.primary.withValues(alpha: 0.55), LC.accent.withValues(alpha: 0.0)]),
                ),
              ),
            ),
            Opacity(
              opacity: _intro.value.clamp(0.0, 1.0),
              child: Transform.scale(scale: 0.6 + 0.4 * intro.value, child: child),
            ),
          ]),
          child: LumoraAppIcon(size: s),
        ),
      ),
    );
  }
}
