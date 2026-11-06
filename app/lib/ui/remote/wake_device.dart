// "Đánh thức máy" (Wake-on-LAN) for recent remote devices that are switched
// off or asleep. The core remembers what it needs from the last session and
// sends the wake-up signal on this network (and asks a friend's device on
// that network, when one is online).

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Small "Đánh thức" button for a `remote_recent` entry. Renders nothing when
/// the device can't be woken (no wake-up info yet) or is already online.
class WakeDeviceButton extends StatelessWidget {
  const WakeDeviceButton({super.key, required this.entry});
  final Map<String, dynamic> entry;

  @override
  Widget build(BuildContext context) {
    final peer = entry['peer']?.toString() ?? '';
    final macs = entry['macs'];
    if (peer.isEmpty || macs is! List || macs.isEmpty) return const SizedBox.shrink();
    final online = context.select<ContactsStore, bool>((c) => c[peer]?.online ?? false);
    if (online) return const SizedBox.shrink();
    final s = S.of(context);
    return IconButton(
      tooltip: s('wake_device'),
      visualDensity: VisualDensity.compact,
      onPressed: () => showWakeDevice(context, peer: peer, name: entry['name']?.toString() ?? ''),
      icon: const Icon(AppIcons.power, size: 17, color: LC.success),
    );
  }
}

Future<void> showWakeDevice(BuildContext context, {required String peer, required String name}) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (_) => _WakeSheet(peer: peer, name: name),
    );

class _WakeSheet extends StatefulWidget {
  const _WakeSheet({required this.peer, required this.name});
  final String peer;
  final String name;
  @override
  State<_WakeSheet> createState() => _WakeSheetState();
}

class _WakeSheetState extends State<_WakeSheet> {
  bool _busy = false;
  bool _sent = false;

  Future<void> _wake() async {
    final s = S.read(context);
    setState(() => _busy = true);
    try {
      final r = await context.read<LumoraApi>().remoteWake(widget.peer);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _sent = true;
      });
      final helpers = (r['helpers'] as num?)?.toInt() ?? 0;
      toast(context, helpers > 0 ? s('wake_sent_helpers', {'n': helpers}) : s('wake_sent'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final lc = context.lc;
    final name = widget.name.isEmpty ? s('wake_this_computer') : widget.name;
    Widget step(int n, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: LC.primary.withValues(alpha: 0.14), shape: BoxShape.circle),
              child: Text('$n', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: LC.primary)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: context.tt.bodyMedium?.copyWith(height: 1.4))),
          ]),
        );
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const IconTile(AppIcons.power, color: LC.success),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s('wake_title', {'name': name}), style: context.tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text(s('wake_subtitle'), style: context.tt.bodySmall),
              ]),
            ),
          ]),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: LC.warning.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(Radii.md)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(AppIcons.info, size: 18, color: LC.warning),
              const SizedBox(width: 10),
              Expanded(child: Text(s('wake_need_setting'), style: context.tt.bodyMedium?.copyWith(height: 1.4))),
            ]),
          ),
          const SizedBox(height: 6),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 4),
              leading: Icon(AppIcons.guide, color: lc.muted, size: 20),
              title: Text(s('wake_how'), style: const TextStyle(fontWeight: FontWeight.w600)),
              children: [
                step(1, s('wake_step_bios')),
                step(2, s('wake_step_windows')),
                step(3, s('wake_step_fast_startup')),
                step(4, s('wake_step_network')),
              ],
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _wake,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(_sent ? AppIcons.retry : AppIcons.power, size: 18),
            label: Text(_sent ? s('wake_again') : s('wake_device')),
          ),
          if (_sent) ...[
            const SizedBox(height: 10),
            Row(children: [
              Icon(AppIcons.hourglass, size: 14, color: lc.muted),
              const SizedBox(width: 6),
              Expanded(child: Text(s('wake_wait'), style: context.tt.bodySmall)),
            ]),
          ],
        ]),
      ),
    );
  }
}
