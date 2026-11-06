import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../widgets/app_icons.dart';

/// Incoming-call screen: the call was picked up on another of my devices.
class AnsweredElsewhereNote extends StatelessWidget {
  const AnsweredElsewhereNote({super.key, required this.device});

  /// That device's name (may be empty).
  final String device;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final text = device.trim().isEmpty ? s('dv_answered_elsewhere') : s('dv_answered_on', {'device': device.trim()});
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(AppIcons.devices, color: Colors.white, size: 22),
          const SizedBox(width: 12),
          Flexible(
            child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }
}
