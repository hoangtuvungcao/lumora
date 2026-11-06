// The approval step on the existing device: a new device used the link code
// and asks to join the account. The user allows it (choosing how much older
// history to copy) or declines.

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/secure_input.dart';
import 'device_ui.dart';

/// History windows offered when approving (`link_approve {history}`).
const kLinkHistoryChoices = ['none', '1m', '6m', 'all'];

/// Route name of the approval sheet (closed from outside when the request ends).
const kLinkApprovalRoute = 'link-approval';

/// Shows the approval sheet; returns the chosen history window, or null when
/// the user declined (or dismissed it).
Future<String?> showLinkApproval(BuildContext context, LinkRequest req) {
  if (isDesktop(context)) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      routeSettings: const RouteSettings(name: kLinkApprovalRoute),
      builder: (c) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(padding: const EdgeInsets.fromLTRB(28, 28, 28, 24), child: LinkApprovalCard(request: req)),
        ),
      ),
    );
  }
  return showModalBottomSheet<String>(
    context: context,
    routeSettings: const RouteSettings(name: kLinkApprovalRoute),
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    useSafeArea: true,
    builder: (c) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
      child: LinkApprovalCard(request: req),
    ),
  );
}

/// The approval card's content (also used directly by tests/screenshots).
class LinkApprovalCard extends StatefulWidget {
  const LinkApprovalCard({super.key, required this.request, this.onResult});
  final LinkRequest request;

  /// Called with the history window (allow) or null (decline). Defaults to
  /// popping the enclosing route with that value.
  final ValueChanged<String?>? onResult;

  @override
  State<LinkApprovalCard> createState() => _LinkApprovalCardState();
}

class _LinkApprovalCardState extends State<LinkApprovalCard> {
  String _history = '6m';

  void _done(String? v) => widget.onResult != null ? widget.onResult!(v) : Navigator.of(context).pop(v);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final r = widget.request;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final os = deviceOsName(r.os);
    final name = r.name.trim().isEmpty ? deviceKindName(s, r.kind) : r.name.trim();
    final kind = [deviceKindName(s, r.kind), if (os.isNotEmpty) os].join(' · ');
    final near = r.path == 'lan';
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(
        s('dv_approve_title'),
        textAlign: TextAlign.center,
        style: context.tt.titleLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.3, fontSize: 20),
      ),
      const SizedBox(height: 18),
      // The device asking to join.
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: dark ? context.lc.surface2.withValues(alpha: 0.7) : const Color(0xFFF4F5FB),
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(color: context.lc.divider),
        ),
        child: Row(children: [
          DeviceGlyph(kind: r.kind, size: IconTileSize.lg),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(kind, style: context.tt.bodySmall?.copyWith(fontSize: 13)),
              const SizedBox(height: 6),
              Row(children: [
                Icon(near ? AppIcons.router : AppIcons.globe, size: 14, color: near ? LC.success : context.lc.muted),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    s(near ? 'dv_approve_near' : 'dv_approve_internet'),
                    style: context.tt.bodySmall?.copyWith(fontSize: 12.5, color: near ? LC.success : context.lc.muted, fontWeight: FontWeight.w500),
                  ),
                ),
              ]),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 18),
      SecureLabel(s('dv_history_label')),
      _HistoryChoice(value: _history, onChanged: (v) => setState(() => _history = v)),
      const SizedBox(height: 8),
      AnimatedSwitcher(
        duration: Motion.fast,
        child: Text(
          s('dv_history_hint_$_history'),
          key: ValueKey(_history),
          style: context.tt.bodySmall?.copyWith(fontSize: 12.5),
        ),
      ),
      const SizedBox(height: 16),
      SecureNote(s('dv_approve_warn'), icon: AppIcons.shieldWarning, color: LC.warning),
      const SizedBox(height: 22),
      Row(children: [
        Expanded(
          flex: 2,
          child: SizedBox(
            height: 52,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: () => _done(null),
              child: Text(s('dv_deny'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 3,
          child: SecurePrimaryButton(label: s('dv_allow'), icon: AppIcons.checkCircle, onPressed: () => _done(_history)),
        ),
      ]),
    ]);
  }
}

/// None / 1 month / 6 months / All as one segmented pill.
class _HistoryChoice extends StatelessWidget {
  const _HistoryChoice({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final index = kLinkHistoryChoices.indexOf(value);
    return Container(
      height: 46,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: context.lc.surface2, borderRadius: BorderRadius.circular(14)),
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth / kLinkHistoryChoices.length;
        return Stack(children: [
          AnimatedPositioned(
            duration: Motion.normal,
            curve: Motion.curve,
            left: w * index,
            top: 0,
            bottom: 0,
            width: w,
            child: Container(
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF2E3360) : Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: dark ? const Color(0xFF3A4078) : context.lc.divider),
              ),
            ),
          ),
          Row(children: [
            for (final o in kLinkHistoryChoices)
              Expanded(
                child: Semantics(
                  selected: o == value,
                  button: true,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => onChanged(o),
                    child: Center(
                      child: Text(
                        s('dv_history_$o'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: o == value ? context.lc.text : context.lc.muted,
                        ),
                      ),
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
