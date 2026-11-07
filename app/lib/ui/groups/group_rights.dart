// Plain groups (kind 0) on the community role engine:
// - admin rights: each admin has a role `admin:<peer>` holding their rights
//   (admins made before this keep every admin permission);
// - member permissions: the `@everyone` role's switches.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/community.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// What an admin role always carries besides its rights (posting like anyone).
const _adminBase = [Perm.viewChannel, Perm.sendMessages, Perm.sendMedia, Perm.connectVoice, Perm.mentionEveryone];

Future<bool> _sheet(
  BuildContext context, {
  required String title,
  required String hint,
  required List<String> rights,
  required Set<String> value,
  required String action,
  Set<String> locked = const {},
  String keyPrefix = 'gr_right',
}) async {
  final s = S.read(context);
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.85),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 4), child: Text(title, style: c.tt.titleMedium)),
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(hint, style: c.tt.bodySmall)),
            Flexible(
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
                for (final p in rights)
                  SwitchRow(
                    key: ValueKey('${keyPrefix}_$p'),
                    title: s('gr_right_$p'),
                    value: value.contains(p),
                    onChanged: locked.contains(p) ? null : (v) => set(() => v ? value.add(p) : value.remove(p)),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton(key: const ValueKey('gr_rights_save'), onPressed: () => Navigator.pop(c, true), child: Text(action)),
            ),
          ]),
        ),
      ),
    ),
  );
  return ok == true;
}

/// Promote [peer] to admin, or change an admin's rights.
Future<void> editAdminRights(BuildContext context, GroupInfo g, String peer, String name) async {
  final s = S.read(context);
  final m = g.member(peer);
  // admins and their rights roles (`admin:<peer>`) are the owner's alone (core: err.no_permission)
  if (m == null || g.myRole != 'owner') return;
  final promote = m.role != 'admin';
  // a new admin gets every right but adding admins
  final current = promote ? {...Perm.adminRights.where((p) => p != Perm.manageRoles)} : g.adminRightsOf(peer);
  final value = {for (final p in Perm.adminRights) if (current.contains(p)) p};
  // an admin hands out only the rights they hold themselves
  final mine = g.myRole == 'owner' ? Perm.all.toSet() : g.myPerms.toSet();
  final locked = {for (final p in Perm.adminRights) if (!mine.contains(p)) p};
  if (!await _sheet(context,
      title: s('gr_admin_rights'),
      hint: s('gr_admin_rights_hint', {'name': name}),
      rights: Perm.adminRights,
      value: value,
      locked: locked,
      action: promote ? s('gr_make_admin') : s('save'))) {
    return;
  }
  if (!context.mounted) return;
  final perms = [
    for (final p in Perm.all)
      if (_adminBase.contains(p) || value.contains(p) || (p == Perm.kick && value.contains(Perm.ban))) p,
  ];
  final id = Perm.adminRoleId(peer);
  try {
    await CommunityStore.of(context.read<LumoraApi>()).change(g.gid, (api) async {
      if (promote) await api.groupSetRole(g.gid, peer, 'admin');
      await api.groupRoleSet(g.gid, id: id, name: id, color: kAdminRoleColor, perms: perms);
      await api.groupMemberRoles(g.gid, peer, [...m.roles.where((r) => r != id), id]);
    });
    if (context.mounted) toast(context, s('gr_rights_saved'));
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

/// Take [peer]'s admin role (and their rights role) away.
Future<void> revokeAdmin(BuildContext context, GroupInfo g, String peer) async {
  if (g.myRole != 'owner') return;
  try {
    await CommunityStore.of(context.read<LumoraApi>()).change(g.gid, (api) async {
      await api.groupSetRole(g.gid, peer, 'member');
      if (g.roleById(Perm.adminRoleId(peer)) != null) await api.groupRoleDelete(g.gid, Perm.adminRoleId(peer));
    });
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

/// The `@everyone` switches: send messages, send media, add members, pin.
Future<void> editMemberPermissions(BuildContext context, GroupInfo g) async {
  final s = S.read(context);
  final everyone = g.roleById(GroupRole.everyoneId);
  final base = (everyone?.perms ?? Perm.everyoneFor(community: g.community)).toSet();
  final value = {for (final p in Perm.memberRights) if (base.contains(p)) p};
  if (!await _sheet(context,
      title: s('gr_member_perms'), hint: s('gr_member_perms_hint'), rights: Perm.memberRights, value: value, action: s('save'), keyPrefix: 'gr_member')) {
    return;
  }
  if (!context.mounted) return;
  final perms = [
    for (final p in Perm.all)
      if (Perm.memberRights.contains(p) ? value.contains(p) : base.contains(p)) p,
  ];
  try {
    await CommunityStore.of(context.read<LumoraApi>())
        .change(g.gid, (api) => api.groupRoleSet(g.gid, id: GroupRole.everyoneId, name: everyone?.name ?? '@everyone', color: everyone?.color ?? kDefaultRoleColor, perms: perms));
    if (context.mounted) toast(context, s('gr_rights_saved'));
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}
