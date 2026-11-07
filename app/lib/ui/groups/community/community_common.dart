// Shared pieces of Community 2.0: role colours and chips, permission copy,
// a builder over the live community info, time labels.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/api.dart';
import '../../../l10n/strings.dart';
import '../../../state/community.dart';
import '../../theme.dart';

/// Lumora's role colour palette: bright tones on the first row, deep tones on
/// the second, then teal and the neutral default (readable on light and dark).
const kRolePalette = [
  '#6C5CE7', '#00C2D1', '#22C55E', '#F59E0B', '#EF4444', '#EC4899', '#0EA5E9', '#A855F7',
  '#4C3FC4', '#0891A0', '#15803D', '#B45309', '#B91C1C', '#BE185D', '#0369A1', '#7E22CE',
  '#14B8A6', kDefaultRoleColor,
];

Color roleColor(GroupRole r) => Color(r.argb);

/// `#RRGGBB` → colour.
Color hexColor(String hex) => Color(GroupRole(id: '', name: '', color: hex).argb);

String permLabel(S s, String perm) => s('cm_perm_$perm');
String permHint(S s, String perm) => s('cm_perm_${perm}_hint');

/// Display name of a role (`@everyone` / the built-in admin role are localised).
String roleName(S s, GroupRole r) => r.isEveryone ? '@everyone' : (r.isAdmin ? s('role_admin') : r.name);

/// A member's fixed role (owner | admin | member): the owner of a community is
/// "Chủ cộng đồng", of a plain group "Trưởng nhóm".
String memberRoleLabel(S s, String role, {bool community = false}) =>
    s(community && role == 'owner' ? 'role_owner_community' : 'role_$role');

/// The colour of [m]'s name: their highest role's (the owner and admins hold
/// the built-in admin role); null = the default text colour.
Color? memberColor(GroupInfo g, GroupMember m) {
  final top = g.topRole(m);
  if (top != null) return roleColor(top);
  if (m.role == 'owner') return LC.warning;
  if (m.role == 'admin') return LC.accent;
  return null;
}

/// `HH:mm` today, else `dd/MM HH:mm`.
String timeLabel(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  return t.year == now.year && t.month == now.month && t.day == now.day ? hm : '${two(t.day)}/${two(t.month)} $hm';
}

/// Rebuilds with community [gid]'s live info (null while it loads).
class CommunityBuilder extends StatelessWidget {
  const CommunityBuilder({super.key, required this.gid, required this.builder});
  final String gid;
  final Widget Function(BuildContext context, GroupInfo? info) builder;

  @override
  Widget build(BuildContext context) {
    final store = CommunityStore.of(context.read<LumoraApi>());
    return ListenableBuilder(listenable: store, builder: (context, _) => builder(context, store.info(gid)));
  }
}

/// A small coloured role pill: dot + name.
class RoleChip extends StatelessWidget {
  const RoleChip({super.key, required this.role, this.onRemove, this.dense = false});
  final GroupRole role;
  final VoidCallback? onRemove;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = roleColor(role);
    return Container(
      key: ValueKey('role_chip_${role.id}'),
      padding: EdgeInsets.fromLTRB(dense ? 6 : 8, dense ? 2 : 4, onRemove == null ? (dense ? 8 : 10) : 4, dense ? 2 : 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withValues(alpha: 0.45)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: dense ? 8 : 10, height: dense ? 8 : 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        SizedBox(width: dense ? 4 : 6),
        Flexible(
          child: Text(roleName(S.of(context), role),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: (dense ? context.tt.labelSmall : context.tt.labelMedium)?.copyWith(fontWeight: FontWeight.w600)),
        ),
        if (onRemove != null)
          InkWell(
            customBorder: const CircleBorder(),
            onTap: onRemove,
            child: Padding(padding: const EdgeInsets.all(2), child: Icon(Icons.close, size: 14, color: context.lc.muted)),
          ),
      ]),
    );
  }
}
