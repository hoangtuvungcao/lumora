import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../state/settings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/peer_avatar.dart';
import 'video_view.dart';

/// Camera effects ("Hiệu ứng"): beautify level, low-light boost and mirroring
/// of the sent video. The core applies them on this device before encoding,
/// so the other side sees the result without needing the feature; changes
/// take effect on the next frame, mid-call.
Future<void> showCallEffects(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 440),
      builder: (_) => const SafeArea(child: CallEffectsPanel()),
    );

/// Compact panel: live self-preview (the processed frames from the core) and
/// the three controls.
class CallEffectsPanel extends StatelessWidget {
  const CallEffectsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = context.watch<Settings>();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const IconTile(AppIcons.effects, size: IconTileSize.sm),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s('call_effects'), style: context.tt.titleMedium),
              const SizedBox(height: 2),
              Text(s('call_effects_hint'), style: context.tt.bodySmall),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        const _SelfPreview(),
        const SizedBox(height: 16),
        Row(children: [
          RowIcon(AppIcons.effects, size: 20, color: context.lc.muted),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s('beauty'), style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(s('beauty_hint'), style: context.tt.bodySmall),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        BeautyLevelPicker(value: st.videoBeauty, onChanged: (v) => st.update((x) => x.videoBeauty = v)),
        const SizedBox(height: 8),
        SwitchRow(icon: AppIcons.sun, title: s('lowlight'), subtitle: s('lowlight_hint'), value: st.videoLowlight, onChanged: (v) => st.update((x) => x.videoLowlight = v)),
        SwitchRow(icon: AppIcons.mirror, title: s('mirror_send'), subtitle: s('mirror_send_hint'), value: st.videoMirrorSend, onChanged: (v) => st.update((x) => x.videoMirrorSend = v)),
      ]),
    );
  }
}

/// The local camera as the core processes it (always shown mirrored).
class _SelfPreview extends StatelessWidget {
  const _SelfPreview();

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final calls = context.watch<CallStore>();
    final beauty = context.select<Settings, int>((x) => x.videoBeauty);
    final me = context.read<SessionStore>().me;
    final call = calls.call;
    final camOn = call != null && call.video && calls.cam;
    final placeholder = ColoredBox(
      color: const Color(0xFF1F2340),
      child: Center(child: PeerAvatar(peer: me?.peer ?? '', fallbackName: me?.name, size: 56, presence: false)),
    );
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.lg),
        child: Stack(fit: StackFit.expand, children: [
          if (camOn)
            VideoView(stream: call.streams[me?.peer] ?? 0, maxFps: 30, placeholder: placeholder)
          else ...[
            placeholder,
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.tonalIcon(
                  onPressed: call != null && call.video ? () => calls.toggle(cam: true) : null,
                  icon: const Icon(AppIcons.video, size: 18),
                  label: Text(s('effects_preview_off')),
                ),
              ),
            ),
          ],
          if (camOn && beauty > 0) const Positioned(left: 10, top: 10, child: EffectsBadge()),
        ]),
      ),
    );
  }
}

/// Tắt / Nhẹ / Vừa / Mạnh pill selector.
class BeautyLevelPicker extends StatelessWidget {
  const BeautyLevelPicker({super.key, required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final labels = [s('beauty_off'), s('beauty_low'), s('beauty_mid'), s('beauty_high')];
    final index = value.clamp(0, 3);
    return Container(
      height: 42,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: context.lc.surface2, borderRadius: BorderRadius.circular(Radii.md)),
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth / labels.length;
        return Stack(children: [
          AnimatedPositioned(
            duration: Motion.normal,
            curve: Motion.curve,
            left: w * index,
            top: 0,
            bottom: 0,
            width: w,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: index == 0 ? (dark ? const Color(0xFF2E3360) : Colors.white) : LC.primary.withValues(alpha: dark ? 0.28 : 0.14),
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(color: index == 0 ? (dark ? const Color(0xFF3A4078) : context.lc.divider) : LC.primary.withValues(alpha: 0.45)),
              ),
            ),
          ),
          Row(children: [
            for (var i = 0; i < labels.length; i++)
              Expanded(
                child: Semantics(
                  selected: i == index,
                  button: true,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    onTap: () => onChanged(i),
                    child: Center(
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (i > 0) ...[
                          // 1–3 sparkles' worth of intensity as dots
                          for (var k = 0; k < i; k++)
                            Container(
                              width: 4,
                              height: 4,
                              margin: const EdgeInsets.only(right: 2),
                              decoration: BoxDecoration(shape: BoxShape.circle, color: i == index ? LC.primary : context.lc.muted.withValues(alpha: 0.6)),
                            ),
                          const SizedBox(width: 4),
                        ],
                        Flexible(
                          child: Text(
                            labels[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: kFontFamily,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: i == index ? context.lc.text : context.lc.muted,
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ]);
      }),
    );
  }
}

/// Small sparkle badge on the self-view while "Làm đẹp" is on.
class EffectsBadge extends StatelessWidget {
  const EffectsBadge({super.key, this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: S.of(context)('beauty_on_badge'),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
        ),
        child: Center(child: Icon(AppIcons.fill(AppIcons.effects), size: size * 0.58, color: const Color(0xFFFFD66B))),
      ),
    );
  }
}

/// Settings › Cuộc gọi: default beautify level (row + selector).
class BeautySettingsRow extends StatelessWidget {
  const BeautySettingsRow({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = context.watch<Settings>();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          RowIcon(AppIcons.effects, size: 20, color: context.lc.muted),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s('beauty'), style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(s('beauty_hint'), style: context.tt.bodySmall),
            ]),
          ),
        ]),
        const SizedBox(height: 10),
        BeautyLevelPicker(value: st.videoBeauty, onChanged: (v) => st.update((x) => x.videoBeauty = v)),
      ]),
    );
  }
}
