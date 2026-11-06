import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Three bouncing dots.
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, this.color, this.size = 5});
  final Color? color;
  final double size;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? LC.accent;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = (_c.value - i * 0.16) % 1.0;
            final y = math.max(0.0, math.sin(t * math.pi * 2)) * widget.size * 0.6;
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.size * 0.22),
              child: Transform.translate(
                offset: Offset(0, -y),
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.55 + 0.45 * (y / (widget.size * 0.6 + 0.001))), shape: BoxShape.circle),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
