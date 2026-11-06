// Small shared pieces for the device screens: kind icons and names, "active
// 2 h ago" wording, badges and the device glyph with its online dot.

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';

/// Icon for a device kind (1 phone, 2 tablet, 3 computer, 4 always-on).
IconData deviceKindIcon(int kind) => switch (kind) {
      DeviceKind.phone => AppIcons.mobile,
      DeviceKind.tablet => AppIcons.tablet,
      DeviceKind.desktop => AppIcons.laptop,
      DeviceKind.cli => AppIcons.server,
      _ => AppIcons.devices,
    };

/// Accent colour per kind (quiet, distinct tiles in a list).
Color deviceKindColor(int kind) => switch (kind) {
      DeviceKind.phone => const Color(0xFF6C5CE7),
      DeviceKind.tablet => const Color(0xFFEC4899),
      DeviceKind.desktop => const Color(0xFF0EA5E9),
      DeviceKind.cli => const Color(0xFF64748B),
      _ => LC.primary,
    };

String deviceKindName(S s, int kind) => s('dv_kind_${kind.clamp(0, 4)}');

/// "Windows", "macOS"… (empty when unknown).
String deviceOsName(String os) => switch (os.toLowerCase()) {
      'windows' => 'Windows',
      'macos' || 'mac' => 'macOS',
      'linux' => 'Linux',
      'android' => 'Android',
      'ios' => 'iOS',
      'ipados' => 'iPadOS',
      '' => '',
      _ => os,
    };

/// The device's name, or its kind when it has none.
String deviceTitle(S s, DeviceInfo d) => d.name.trim().isNotEmpty ? d.name.trim() : deviceKindName(s, d.kind);

/// "Đang hoạt động" / "Hoạt động 2 giờ trước".
String deviceActivity(S s, DeviceInfo d, DateTime now) {
  if (d.online || d.isThis) return s('dv_active_now');
  if (d.lastSeen <= 0) return s('dv_active_never');
  final diff = now.difference(DateTime.fromMillisecondsSinceEpoch(d.lastSeen));
  if (diff.inMinutes < 2) return s('dv_active_now');
  if (diff.inMinutes < 60) return s('dv_active_min', {'n': diff.inMinutes});
  if (diff.inHours < 24) return s('dv_active_hour', {'n': diff.inHours});
  return s('dv_active_day', {'n': diff.inDays});
}

/// Date as people say it: "12/10/2026" / "Oct 12, 2026".
String deviceDate(S s, int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return s.vi ? '${d.day}/${d.month}/${d.year}' : '${mo[d.month - 1]} ${d.day}, ${d.year}';
}

/// Formats a link code as `1234-5678-9012` (digits only in, groups out).
String formatLinkCode(String code) {
  final d = code.replaceAll(RegExp(r'\D'), '');
  if (d.length != 12) return code;
  return '${d.substring(0, 4)}-${d.substring(4, 8)}-${d.substring(8)}';
}

/// Device tile with the kind icon and, when [online], a green dot.
class DeviceGlyph extends StatelessWidget {
  const DeviceGlyph({super.key, required this.kind, this.online = false, this.size = IconTileSize.md});
  final int kind;
  final bool online;
  final IconTileSize size;

  @override
  Widget build(BuildContext context) {
    final dot = size == IconTileSize.lg ? 14.0 : 11.0;
    return SizedBox.square(
      dimension: size.box + 2,
      child: Stack(clipBehavior: Clip.none, children: [
        IconTile(deviceKindIcon(kind), color: deviceKindColor(kind), size: size),
        if (online)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                color: LC.success,
                shape: BoxShape.circle,
                border: Border.all(color: context.lc.surface, width: 2),
              ),
            ),
          ),
      ]),
    );
  }
}

/// "Thiết bị này" / "Thiết bị chính" badges.
class DeviceBadges extends StatelessWidget {
  const DeviceBadges({super.key, required this.device});
  final DeviceInfo device;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Wrap(spacing: 6, runSpacing: 4, children: [
      if (device.isThis) Pill(s('this_device'), color: dark ? const Color(0xFFA99BFF) : LC.primary),
      if (device.primary) Pill(s('dv_main'), color: dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309), icon: AppIcons.owner),
    ]);
  }
}

/// A short numbered step ("1  On the new device, open Lumora.").
class NumberedStep extends StatelessWidget {
  const NumberedStep({super.key, required this.n, required this.text});
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: LC.primary.withValues(alpha: dark ? 0.22 : 0.12), shape: BoxShape.circle),
          child: Text('$n', style: TextStyle(fontFamily: kFontFamily, fontSize: 12.5, fontWeight: FontWeight.w700, color: dark ? const Color(0xFFB4AAFF) : LC.primary)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(text, style: context.tt.bodyMedium?.copyWith(height: 1.45, fontSize: 14)),
          ),
        ),
      ]),
    );
  }
}

/// Plain sentence for a link / device error ([ApiException] code → copy).
String deviceError(S s, Object e) {
  if (e is ApiException) {
    final code = e.code ?? '';
    if (code.startsWith('err.')) {
      final key = 'err_${code.substring(4)}';
      final t = s.orElse(key, '');
      if (t.isNotEmpty) return t;
    }
    final m = e.message;
    if (RegExp(r'^[a-z_]+$').hasMatch(m)) return s.orElse('err_$m', s('err_internal'));
    return m;
  }
  return s('err_internal');
}
