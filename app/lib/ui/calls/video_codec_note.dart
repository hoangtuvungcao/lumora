// Video-codec bits of the call screen: the "they need to update" note and the
// "Video: H.264 · phần cứng" line under the call-quality bars. Kept apart from
// call_layer.dart, which only places these widgets.

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';

String _codecName(String c) => switch (c) {
      'h264' => 'H.264',
      'vp8' => 'VP8',
      'vp9' => 'VP9',
      _ => c.toUpperCase(),
    };

/// "Video: VP8 · phần mềm" for the received video (from `video_first_frame`).
String videoCodecLine(S s, (String, String, bool) c) =>
    s('vc_line', {'codec': _codecName(c.$1), 'kind': s(c.$3 ? 'vc_hw' : 'vc_sw')});

/// Small inline note: the other person runs an older Lumora that only takes
/// H.264 and this device has none — no picture, the call keeps its sound.
class VideoPeerUpdateNote extends StatelessWidget {
  const VideoPeerUpdateNote({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 460),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(AppIcons.info, size: 18, color: LC.warning),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            s('vc_peer_update'),
            style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.35),
          ),
        ),
      ]),
    );
  }
}
