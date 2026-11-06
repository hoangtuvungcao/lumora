// Friendly stand-in when a photo can't be decoded on this device (mostly
// HEIC from iPhones on Windows/Linux without a HEIF decoder): the sender's
// JPEG thumbnail if there is one, a short explanation and "Mở bằng ứng dụng
// khác".

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../chats/attachments.dart' show openFile;
import '../theme.dart';
import '../widgets/app_icons.dart';
import 'heic.dart';

/// Platform-specific tip for viewing HEIC natively.
String heicHint(S s) {
  if (Platform.isWindows) return s('pe_heic_hint_windows');
  if (Platform.isLinux) return s('pe_heic_hint_linux');
  return s('pe_heic_hint');
}

class PhotoDecodeFallback extends StatelessWidget {
  const PhotoDecodeFallback({super.key, required this.path, this.thumb});
  final String? path;
  final Uint8List? thumb;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final p = path;
    final heic = p != null && isHeicPath(p);
    return Stack(fit: StackFit.expand, children: [
      if (thumb != null) Image.memory(thumb!, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.medium),
      Center(
        child: Container(
          key: const ValueKey('photo-fallback'),
          constraints: const BoxConstraints(maxWidth: 420),
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(Radii.lg)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(AppIcons.imageBroken, color: Colors.white70, size: 36),
            const SizedBox(height: 10),
            Text(
              heic ? s('pe_heic_unsupported') : s('image_unreadable'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
            ),
            if (heic) ...[
              const SizedBox(height: 6),
              Text(heicHint(s), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.35)),
            ],
            if (p != null && !p.startsWith('asset:')) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(
                key: const ValueKey('open-with-other-app'),
                onPressed: () => openFile(context, p),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white38)),
                icon: const Icon(AppIcons.openExternal, size: 18),
                label: Text(s('pe_open_with')),
              ),
            ],
          ]),
        ),
      ),
    ]);
  }
}
