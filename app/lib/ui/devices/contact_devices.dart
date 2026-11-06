// Contact info: "N thiết bị" (only when a friend uses two or more devices),
// each with its own security code to compare in person.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/devices_store.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import 'device_ui.dart';

class ContactDevicesTile extends StatefulWidget {
  const ContactDevicesTile({super.key, required this.peer, this.initiallyExpanded = false});
  final String peer;
  final bool initiallyExpanded;

  @override
  State<ContactDevicesTile> createState() => _ContactDevicesTileState();
}

class _ContactDevicesTileState extends State<ContactDevicesTile> {
  late bool _open = widget.initiallyExpanded;
  String? _shown;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<DevicesStore>().loadContact(widget.peer).catchError((_) => const <DeviceInfo>[]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final devices = context.select<DevicesStore, List<DeviceInfo>?>((d) => d.contactDevices[widget.peer]);
    if (devices == null || devices.length < 2) return const SizedBox.shrink();
    final names = devices.map((d) => deviceTitle(s, d)).join(', ');
    final now = DateTime.now();
    return Column(children: [
      ListTile(
        leading: const RowIcon(AppIcons.devices),
        title: Text(s('dv_contact_n', {'n': devices.length})),
        subtitle: Text(_open ? s('dv_contact_hint') : names, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: AnimatedRotation(turns: _open ? 0.25 : 0, duration: Motion.normal, child: const Icon(AppIcons.chevronRight, size: 18)),
        onTap: () => setState(() => _open = !_open),
      ),
      AnimatedSize(
        duration: Motion.normal,
        curve: Motion.curve,
        alignment: Alignment.topCenter,
        child: !_open
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Column(children: [
                  for (final d in devices)
                    _DeviceCode(
                      device: d,
                      now: now,
                      expanded: _shown == d.device,
                      onTap: () => setState(() => _shown = _shown == d.device ? null : d.device),
                    ),
                ]),
              ),
      ),
    ]);
  }
}

class _DeviceCode extends StatelessWidget {
  const _DeviceCode({required this.device, required this.now, required this.expanded, required this.onTap});
  final DeviceInfo device;
  final DateTime now;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final d = device;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final groups = d.safety.trim().split(RegExp(r'\s+')).where((g) => g.isNotEmpty).toList();
    final online = d.online;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: dark ? context.lc.surface2.withValues(alpha: 0.55) : const Color(0xFFF5F6FB),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: groups.isEmpty ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
            child: Row(children: [
              DeviceGlyph(kind: d.kind, online: online, size: IconTileSize.sm),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(deviceTitle(s, d), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                    if (d.primary) ...[const SizedBox(width: 6), Icon(AppIcons.owner, size: 13, color: dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309))],
                  ]),
                  Text(
                    online ? s('dv_active_now') : deviceActivity(s, d, now),
                    style: context.tt.bodySmall?.copyWith(fontSize: 12, color: online ? LC.success : null),
                  ),
                ]),
              ),
              if (groups.isNotEmpty) ...[
                Text(s('dv_security_code'), style: context.tt.bodySmall?.copyWith(fontSize: 12, color: LC.primary, fontWeight: FontWeight.w600)),
                const SizedBox(width: 4),
                AnimatedRotation(turns: expanded ? 0.5 : 0, duration: Motion.normal, child: const Icon(AppIcons.chevronDown, size: 16, color: LC.primary)),
              ],
            ]),
          ),
        ),
        AnimatedSize(
          duration: Motion.normal,
          curve: Motion.curve,
          alignment: Alignment.topCenter,
          child: !expanded
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(color: context.lc.surface, borderRadius: BorderRadius.circular(Radii.sm), border: Border.all(color: context.lc.divider)),
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 14,
                        runSpacing: 6,
                        children: [
                          for (final g in groups)
                            Text(g,
                                style: TextStyle(
                                  fontFamily: kFontFamily,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1.5,
                                  color: context.lc.text,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                )),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: Text(s('dv_contact_compare'), style: context.tt.bodySmall?.copyWith(fontSize: 12, height: 1.4))),
                      IconButton(
                        tooltip: s('copy'),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => copyText(context, d.safety),
                        icon: Icon(AppIcons.copy, size: 16, color: context.lc.muted),
                      ),
                    ]),
                  ]),
                ),
        ),
      ]),
    );
  }
}
