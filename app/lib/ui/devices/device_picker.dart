// Remote control and multi-device: choose which of an account's computers to
// control, and show my other devices' IDs on the remote "ID card".

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/devices_store.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import 'device_ui.dart';

/// Runs [attempt] without a device; when the target account has several
/// computers (`err.choose_device`), asks which one and tries again with it.
/// Returns false when the user closed the picker.
Future<bool> connectChoosingDevice(BuildContext context, Future<void> Function(String? device) attempt) async {
  try {
    await attempt(null);
    return true;
  } catch (e) {
    final choices = RemoteDeviceChoice.parse(e);
    if (choices == null || choices.isEmpty || !context.mounted) rethrow;
    final device = await pickRemoteDevice(context, choices);
    if (device == null) return false;
    await attempt(device);
    return true;
  }
}

/// "Chọn thiết bị để điều khiển": returns the chosen device, or null.
Future<String?> pickRemoteDevice(BuildContext context, List<RemoteDeviceChoice> choices) {
  final body = RemoteDevicePicker(choices: choices);
  if (isDesktop(context)) {
    return showDialog<String>(
      context: context,
      builder: (c) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Padding(padding: const EdgeInsets.fromLTRB(24, 24, 24, 16), child: body)),
      ),
    );
  }
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (c) => Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 16), child: body),
  );
}

class RemoteDevicePicker extends StatelessWidget {
  const RemoteDevicePicker({super.key, required this.choices, this.onPick});
  final List<RemoteDeviceChoice> choices;
  final ValueChanged<String>? onPick;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const IconTile(AppIcons.remote, color: Color(0xFF3B82F6)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s('dv_pick_title'), style: context.tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(s('dv_pick_sub'), style: context.tt.bodySmall),
          ]),
        ),
      ]),
      const SizedBox(height: 16),
      Flexible(
        child: SingleChildScrollView(
          child: Column(children: [
            for (final c in choices)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: context.lc.surface2.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(Radii.md),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(Radii.md),
                    onTap: () => onPick != null ? onPick!(c.device) : Navigator.of(context).pop(c.device),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        DeviceGlyph(kind: c.kind),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(c.name.trim().isEmpty ? deviceKindName(s, c.kind) : c.name.trim(),
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                            if (c.shortId.isNotEmpty)
                              Text('ID ${c.shortId}', style: context.tt.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                          ]),
                        ),
                        Icon(AppIcons.chevronRight, size: 18, color: context.lc.muted),
                      ]),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(onPressed: () => Navigator.of(context).maybePop(), child: Text(s('cancel'))),
      ),
    ]);
  }
}

/// On the remote "ID card" (white on the brand gradient): my other devices
/// and their IDs, when I use more than one.
class MyDeviceIds extends StatefulWidget {
  const MyDeviceIds({super.key});
  @override
  State<MyDeviceIds> createState() => _MyDeviceIdsState();
}

class _MyDeviceIdsState extends State<MyDeviceIds> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && context.read<DevicesStore>().list == null) context.read<DevicesStore>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final list = context.select<DevicesStore, DeviceList?>((d) => d.list);
    final others = (list?.devices ?? const <DeviceInfo>[]).where((d) => !d.isThis && d.device != list?.device && d.shortId.isNotEmpty).toList();
    if (others.isEmpty) return const SizedBox.shrink();
    final label = TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 11.5, letterSpacing: 1, fontWeight: FontWeight.w600);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 10),
      Divider(color: Colors.white.withValues(alpha: 0.25)),
      const SizedBox(height: 6),
      Text(s('dv_my_ids').toUpperCase(), style: label),
      const SizedBox(height: 6),
      for (final d in others)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Icon(deviceKindIcon(d.kind), size: 17, color: Colors.white.withValues(alpha: 0.9)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(deviceTitle(s, d), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withValues(alpha: 0.92), fontSize: 14, fontWeight: FontWeight.w500)),
            ),
            const SizedBox(width: 10),
            Text(d.shortId, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 1, fontFeatures: [FontFeature.tabularFigures()])),
            const SizedBox(width: 2),
            IconButton(
              tooltip: s('copy_id'),
              visualDensity: VisualDensity.compact,
              onPressed: () => copyText(context, d.shortId),
              icon: Icon(AppIcons.copy, size: 16, color: Colors.white.withValues(alpha: 0.9)),
            ),
          ]),
        ),
    ]);
  }
}
