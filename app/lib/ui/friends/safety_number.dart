import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/common.dart';

void openSafetyNumber(BuildContext context, Contact c) {
  if (isDesktop(context)) {
    showDialog<void>(context: context, builder: (_) => Dialog(child: SizedBox(width: 480, child: SafetyNumberView(contact: c))));
  } else {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(body: SafeArea(child: SingleChildScrollView(child: SafetyNumberView(contact: c)))),
    ));
  }
}

/// Safety number: 12 groups of 5 digits, compare out-of-band.
class SafetyNumberView extends StatefulWidget {
  const SafetyNumberView({super.key, required this.contact});
  final Contact contact;
  @override
  State<SafetyNumberView> createState() => _SafetyNumberViewState();
}

class _SafetyNumberViewState extends State<SafetyNumberView> {
  String? _number;

  @override
  void initState() {
    super.initState();
    context.read<LumoraApi>().safetyNumber(widget.contact.peer).then((v) {
      if (mounted) setState(() => _number = v);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final verified = context.select<ContactsStore, bool>((x) => x[widget.contact.peer]?.verified ?? false);
    final groups = (_number ?? '').split(RegExp(r'\s+')).where((g) => g.isNotEmpty).toList();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PaneHeader(title: Text(s('safety_number')), onBack: () => Navigator.of(context).maybePop()),
      Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            PeerAvatar(peer: widget.contact.peer, size: 44, presence: false),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.contact.displayName, style: context.tt.titleMedium),
                const SizedBox(height: 2),
                verified
                    ? Pill(s('verified'), color: LC.success, icon: AppIcons.shieldCheck)
                    : Pill(s('not_verified'), color: LC.warning, icon: AppIcons.shield),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          Text(s('safety_hint', {'name': widget.contact.displayName}), style: context.tt.bodySmall?.copyWith(height: 1.5)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: context.lc.surface2, borderRadius: BorderRadius.circular(Radii.lg)),
            child: _number == null
                ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
                : GridView.count(
                    crossAxisCount: 4,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: 2.4,
                    children: [
                      for (final g in groups)
                        Center(
                          child: Text(g,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.5,
                                fontFeatures: [FontFeature.tabularFigures()],
                              )),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: _number == null ? null : () => copyText(context, _number!),
            icon: const Icon(AppIcons.copy, size: 17),
            label: Text(s('copy')),
          ),
          const SizedBox(height: 8),
          verified
              ? OutlinedButton(
                  onPressed: () => context.read<ContactsStore>().setVerified(widget.contact.peer, false),
                  child: Text(s('clear_verification')),
                )
              : GradientButton(
                  label: s('mark_verified'),
                  icon: AppIcons.shieldCheck,
                  expand: true,
                  onPressed: () => context.read<ContactsStore>().setVerified(widget.contact.peer, true),
                ),
        ]),
      ),
    ]);
  }
}
