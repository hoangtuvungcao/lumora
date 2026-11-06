// Group safety UI: the "verified" mark of public group listings and the
// banner shown in a group chat when a member's messages were held back.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/group_flood.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';

/// Small check badge next to a public group whose listing is signed by the
/// group's own admin (`search_groups` → `verified: true`).
class VerifiedGroupMark extends StatelessWidget {
  const VerifiedGroupMark({super.key, this.size = 15});
  final double size;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Semantics(
      label: s('group_verified'),
      child: ExcludeSemantics(
        child: Tooltip(
          message: '${s('group_verified')} · ${s('group_verified_hint')}',
          child: Icon(AppIcons.verifiedFill, size: size, color: LC.accent),
        ),
      ),
    );
  }
}

String _slowLabel(S s, int v) => v < 60 ? s('ttl_sec', {'n': v}) : (v < 3600 ? s('ttl_min', {'n': v ~/ 60}) : s('ttl_hour', {'n': v ~/ 3600}));

/// Banner above the composer of a group chat: someone's messages were held
/// back (`group_flood`). Admins get a one-tap slow-mode suggestion.
class GroupFloodBanner extends StatelessWidget {
  const GroupFloodBanner({super.key, required this.conv});
  final String conv;

  @override
  Widget build(BuildContext context) {
    final floods = context.read<ChatStore>().floods;
    return ValueListenableBuilder<Map<String, FloodNotice>>(
      valueListenable: floods,
      builder: (context, all, _) {
        final n = all[conv];
        return AnimatedSize(
          duration: Motion.normal,
          curve: Motion.curve,
          alignment: Alignment.bottomCenter,
          child: n == null ? const SizedBox(width: double.infinity) : _FloodCard(key: ValueKey(n), notice: n, onClose: () => floods.dismiss(conv)),
        );
      },
    );
  }
}

class _FloodCard extends StatefulWidget {
  const _FloodCard({super.key, required this.notice, required this.onClose});
  final FloodNotice notice;
  final VoidCallback onClose;

  @override
  State<_FloodCard> createState() => _FloodCardState();
}

class _FloodCardState extends State<_FloodCard> {
  bool _busy = false;

  Future<void> _slowDown() async {
    final n = widget.notice;
    final s = S.read(context);
    final api = context.read<LumoraApi>();
    final gid = n.gid.isNotEmpty ? n.gid : n.conv.substring(2).split('#').first;
    setState(() => _busy = true);
    try {
      await api.groupSettings(gid, slowModeS: n.suggestSlowModeS);
      if (!mounted) return;
      toast(context, s('flood_slow_done', {'t': _slowLabel(s, n.suggestSlowModeS)}));
      widget.onClose();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final n = widget.notice;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = n.text.isNotEmpty ? n.text : (n.reason == 'group_quota' ? s('flood_group_full') : s('flood_member', {'name': n.name}));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          decoration: BoxDecoration(
            color: Color.alphaBlend(LC.warning.withValues(alpha: dark ? 0.13 : 0.10), context.lc.surface),
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: LC.warning.withValues(alpha: dark ? 0.35 : 0.40)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(AppIcons.shieldWarning, size: 20, color: LC.warning),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(text, style: context.tt.bodyMedium?.copyWith(height: 1.4)),
                ),
                if (n.canSlowDown) ...[
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _slowDown,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
                    ),
                    icon: _busy
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(AppIcons.timer, size: 16),
                    label: Text('${s('flood_slow_on')} · ${_slowLabel(s, n.suggestSlowModeS)}'),
                  ),
                ],
              ]),
            ),
            IconButton(
              onPressed: widget.onClose,
              tooltip: s('close'),
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              color: context.lc.muted,
              icon: const Icon(AppIcons.close),
            ),
          ]),
        ),
      ),
    );
  }
}
