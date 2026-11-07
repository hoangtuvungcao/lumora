// Community members: search, role chips, assign roles, timeout, kick, ban;
// the member sheet (profile card with role chips); bots and their roles.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/api.dart';
import '../../../l10n/strings.dart';
import '../../../state/community.dart';
import '../../../state/stores.dart';
import '../../profile/profile_screen.dart';
import '../../theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/common.dart';
import '../../widgets/peer_avatar.dart';
import '../group_info.dart' show showAddBotDialog;
import '../group_membership.dart' show transferOwnership;
import 'community_common.dart';

/// I may moderate [m] (kick / ban / timeout): not me, never the owner, admins
/// only when I'm the owner.
bool canModerate(GroupInfo g, GroupMember m, String me) =>
    m.peer != me && m.role != 'owner' && (m.role != 'admin' || g.myRole == 'owner');

Future<void> _run(BuildContext context, String gid, Future<void> Function(LumoraApi api) f) async {
  try {
    await CommunityStore.of(context.read<LumoraApi>()).change(gid, f);
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

/// Pick [peer]'s custom roles (and, for the owner, the built-in admin role).
Future<void> pickMemberRoles(BuildContext context, GroupInfo g, String peer, {required String name, bool bot = false}) async {
  final s = S.read(context);
  final m = g.member(peer);
  final custom = g.customRoles;
  final chosen = <String>{...(bot ? (g.botRoles[peer] ?? const []) : (m?.roles ?? const []))};
  var admin = m?.role == 'admin';
  final canAdmin = !bot && m != null && g.myRole == 'owner' && m.role != 'owner';
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(s('cm_assign_roles'), style: c.tt.titleMedium),
            ),
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(name, style: c.tt.bodySmall)),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                if (canAdmin)
                  CheckboxListTile(
                    key: const ValueKey('cm_pick_admin'),
                    value: admin,
                    onChanged: (v) => set(() => admin = v ?? false),
                    secondary: const Icon(AppIcons.shield, color: LC.primary),
                    title: Text(s('role_admin'), style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(s('cm_role_admin_hint'), maxLines: 2),
                  ),
                for (final r in custom)
                  CheckboxListTile(
                    key: ValueKey('cm_pick_role_${r.id}'),
                    value: chosen.contains(r.id),
                    onChanged: (v) => set(() => v == true ? chosen.add(r.id) : chosen.remove(r.id)),
                    secondary: Container(width: 14, height: 14, decoration: BoxDecoration(color: roleColor(r), shape: BoxShape.circle)),
                    title: Text(r.name, style: TextStyle(color: roleColor(r), fontWeight: FontWeight.w600)),
                  ),
                if (custom.isEmpty && !canAdmin)
                  Padding(padding: const EdgeInsets.all(20), child: Text(s('cm_none_custom_roles'), textAlign: TextAlign.center, style: c.tt.bodySmall)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton(key: const ValueKey('cm_pick_save'), onPressed: () => Navigator.pop(c, true), child: Text(s('save'))),
            ),
          ]),
        ),
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  await _run(context, g.gid, (api) async {
    if (canAdmin && admin != (m.role == 'admin')) await api.groupSetRole(g.gid, peer, admin ? 'admin' : 'member');
    // (a plain group's per-admin rights role stays)
    final keep = [for (final id in (bot ? (g.botRoles[peer] ?? const <String>[]) : (m?.roles ?? const <String>[]))) if (id.startsWith('admin:')) id];
    await api.groupMemberRoles(g.gid, peer, [...keep, for (final r in custom) if (chosen.contains(r.id)) r.id]);
  });
}

/// Time [m] out (5 min / 1 h / 1 day / 1 week), or lift a running timeout.
Future<void> timeoutMember(BuildContext context, GroupInfo g, GroupMember m, String name) async {
  final s = S.read(context);
  if (m.timedOut()) {
    await _run(context, g.gid, (api) => api.groupTimeout(g.gid, m.peer, 0));
    return;
  }
  const opts = [('cm_timeout_5m', Duration(minutes: 5)), ('cm_timeout_1h', Duration(hours: 1)), ('cm_timeout_1d', Duration(days: 1)), ('cm_timeout_1w', Duration(days: 7))];
  final d = await showDialog<Duration>(
    context: context,
    builder: (c) => SimpleDialog(
      title: Text(s('cm_timeout')),
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text(s('cm_timeout_for', {'name': name}), style: c.tt.bodySmall)),
        for (final (k, v) in opts)
          ListTile(
            key: ValueKey('cm_timeout_${v.inMinutes}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: const Icon(AppIcons.hourglass),
            title: Text(s(k)),
            onTap: () => Navigator.pop(c, v),
          ),
      ],
    ),
  );
  if (d == null || !context.mounted) return;
  final until = DateTime.now().add(d).millisecondsSinceEpoch;
  await _run(context, g.gid, (api) => api.groupTimeout(g.gid, m.peer, until));
}

Future<void> kickMember(BuildContext context, GroupInfo g, GroupMember m, String name) async {
  final s = S.read(context);
  if (!await confirm(context, title: s('cm_kick'), body: s('cm_kick_body', {'name': name}), action: s('cm_kick'), danger: true)) return;
  if (context.mounted) await _run(context, g.gid, (api) => api.groupRemove(g.gid, m.peer));
}

Future<void> banMember(BuildContext context, GroupInfo g, GroupMember m, String name) async {
  final s = S.read(context);
  if (!await confirm(context, title: s('cm_ban'), body: s('cm_ban_body', {'name': name}), action: s('ban'), danger: true)) return;
  if (context.mounted) await _run(context, g.gid, (api) => api.groupBan(g.gid, m.peer, true));
}

/// The moderation actions I may take on [m], as (id, icon, label, danger).
List<(String, IconData, String, bool)> memberActions(S s, GroupInfo g, GroupMember m, String me) => [
      if (g.can(Perm.manageRoles) && m.role != 'owner') ('roles', AppIcons.shield, s('cm_assign_roles'), false),
      if (canModerate(g, m, me) && g.can(Perm.timeout)) ('timeout', AppIcons.hourglass, m.timedOut() ? s('cm_timeout_lift') : s('cm_timeout'), false),
      if (canModerate(g, m, me) && g.can(Perm.kick)) ('kick', AppIcons.removeUser, s('cm_kick'), true),
      if (canModerate(g, m, me) && g.can(Perm.ban)) ('ban', AppIcons.block, s('cm_ban'), true),
      if (g.myRole == 'owner' && m.peer != me && m.role != 'owner') ('owner', AppIcons.owner, s('go_transfer_owner'), false),
    ];

Future<void> runMemberAction(BuildContext context, String action, GroupInfo g, GroupMember m, String name) => switch (action) {
      'roles' => pickMemberRoles(context, g, m.peer, name: name),
      'timeout' => timeoutMember(context, g, m, name),
      'kick' => kickMember(context, g, m, name),
      'ban' => banMember(context, g, m, name),
      'owner' => transferOwnership(context, g, m.peer, name).then((ok) {
          if (ok && context.mounted) CommunityStore.of(context.read<LumoraApi>()).load(g.gid);
        }),
      _ => Future<void>.value(),
    };

/// A member's card in a community: avatar, name in their role colour, role
/// chips, timeout, and what I may do (profile, roles, timeout, kick, ban).
Future<void> showMemberSheet(BuildContext context, String gid, String peer) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => CommunityBuilder(
        gid: gid,
        builder: (c, g) {
          final s = S.of(c);
          final m = g?.member(peer);
          if (g == null || m == null) return const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()));
          final me = c.read<SessionStore>().me?.peer ?? '';
          final name = peer == me ? (c.read<SessionStore>().me?.name ?? m.name) : (c.read<ContactsStore>()[peer]?.displayName ?? m.name);
          final roles = g.rolesOf(m).where((r) => m.role != 'owner' || !r.isAdmin).toList();
          final actions = memberActions(s, g, m, me);
          return SafeArea(
            child: SingleChildScrollView(
              key: const ValueKey('cm_member_sheet'),
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  PeerAvatar(peer: peer, fallbackName: m.name, size: 64),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Flexible(
                          child: Text(name,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: c.tt.titleLarge?.copyWith(color: memberColor(g, m), fontWeight: FontWeight.w700)),
                        ),
                        if (m.role == 'owner') const Padding(padding: EdgeInsets.only(left: 6), child: Icon(AppIcons.owner, size: 18, color: LC.warning)),
                      ]),
                      Text(memberRoleLabel(s, m.role, community: true), style: c.tt.bodySmall),
                    ]),
                  ),
                ]),
                if (m.timedOut()) ...[
                  const SizedBox(height: 12),
                  Pill(s('cm_timed_out_until_short', {'time': timeLabel(m.timeoutUntil)}), color: LC.warning, icon: AppIcons.hourglass),
                ],
                const SizedBox(height: 16),
                Text(s('cm_roles').toUpperCase(), style: c.tt.labelSmall?.copyWith(letterSpacing: 0.8, color: c.lc.muted, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (roles.isEmpty)
                  Text(s('cm_no_roles'), style: c.tt.bodySmall)
                else
                  Wrap(spacing: 6, runSpacing: 6, children: [for (final r in roles) RoleChip(role: r)]),
                const SizedBox(height: 16),
                if (peer != me)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(AppIcons.profile),
                    title: Text(s('cm_view_profile')),
                    onTap: () {
                      Navigator.pop(c);
                      openProfile(context, peer);
                    },
                  ),
                for (final a in actions)
                  ListTile(
                    key: ValueKey('cm_member_${a.$1}'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(a.$2, color: a.$4 ? LC.danger : null),
                    title: Text(a.$3, style: a.$4 ? const TextStyle(color: LC.danger) : null),
                    onTap: () async {
                      if (a.$1 == 'kick' || a.$1 == 'ban') Navigator.pop(c);
                      await runMemberAction(context, a.$1, g, m, name);
                    },
                  ),
              ]),
            ),
          );
        },
      ),
    );

// ================================================================ members

class MembersPane extends StatefulWidget {
  const MembersPane({super.key, required this.gid});
  final String gid;
  @override
  State<MembersPane> createState() => _MembersPaneState();
}

class _MembersPaneState extends State<MembersPane> {
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final me = context.select<SessionStore, String>((x) => x.me?.peer ?? '');
    final contacts = context.watch<ContactsStore>();
    return CommunityBuilder(
      gid: widget.gid,
      builder: (context, g) {
        if (g == null) return const Center(child: CircularProgressIndicator());
        String nameOf(GroupMember m) => m.peer == me ? '${m.name} (${s('you')})' : (contacts[m.peer]?.displayName ?? m.name);
        final q = _q.text.trim().toLowerCase();
        int rank(GroupMember m) => m.role == 'owner' ? 1 << 20 : (g.topRole(m)?.position ?? 0);
        final list = g.members.where((m) => q.isEmpty || nameOf(m).toLowerCase().contains(q) || g.rolesOf(m).any((r) => r.name.toLowerCase().contains(q))).toList()
          ..sort((a, b) {
            final r = rank(b).compareTo(rank(a));
            return r != 0 ? r : nameOf(a).toLowerCase().compareTo(nameOf(b).toLowerCase());
          });
        return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
          TextField(
            key: const ValueKey('cm_member_search'),
            controller: _q,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(prefixIcon: const Icon(AppIcons.search, size: 20), hintText: s('cm_search_members')),
          ),
          SectionLabel(s('members_count', {'n': g.members.length}), padding: const EdgeInsets.fromLTRB(4, 16, 4, 6)),
          if (list.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(s('cm_no_members_found'), style: context.tt.bodySmall))),
          for (final m in list)
            _MemberRow(key: ValueKey('cm_member_row_${m.peer}'), g: g, m: m, me: me, name: nameOf(m)),
        ]);
      },
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({super.key, required this.g, required this.m, required this.me, required this.name});
  final GroupInfo g;
  final GroupMember m;
  final String me;
  final String name;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    // the owner also holds the built-in admin role (name colour); the row says
    // "Community owner" instead of an admin chip
    final roles = g.rolesOf(m).where((r) => m.role != 'owner' || !r.isAdmin).toList();
    final actions = memberActions(s, g, m, me);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: context.lc.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: () => showMemberSheet(context, g.gid, m.peer),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              PeerAvatar(peer: m.peer, fallbackName: m.name, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: Text(name,
                          key: ValueKey('cm_member_name_${m.peer}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w600, color: memberColor(g, m))),
                    ),
                    if (m.role == 'owner') const Padding(padding: EdgeInsets.only(left: 6), child: Icon(AppIcons.owner, size: 16, color: LC.warning)),
                    if (m.timedOut())
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Tooltip(
                          message: s('cm_timed_out_until_short', {'time': timeLabel(m.timeoutUntil)}),
                          child: Icon(AppIcons.hourglass, key: ValueKey('cm_timed_out_${m.peer}'), size: 16, color: LC.warning),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 6),
                  if (roles.isEmpty)
                    Text(memberRoleLabel(s, m.role, community: true), style: context.tt.bodySmall)
                  else
                    Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      if (m.role == 'owner') Padding(padding: const EdgeInsets.only(right: 4), child: Text(memberRoleLabel(s, m.role, community: true), style: context.tt.bodySmall)),
                      for (final r in roles) RoleChip(role: r, dense: true),
                    ]),
                ]),
              ),
              if (actions.isNotEmpty)
                PopupMenuButton<String>(
                  key: ValueKey('cm_member_more_${m.peer}'),
                  tooltip: s('more'),
                  icon: Icon(AppIcons.moreVertical, color: context.lc.muted),
                  onSelected: (a) => runMemberAction(context, a, g, m, name),
                  itemBuilder: (_) => [
                    for (final a in actions)
                      PopupMenuItem(
                        value: a.$1,
                        child: Row(children: [
                          Icon(a.$2, size: 18, color: a.$4 ? LC.danger : null),
                          const SizedBox(width: 12),
                          Text(a.$3, style: a.$4 ? const TextStyle(color: LC.danger) : null),
                        ]),
                      ),
                  ],
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

// =================================================================== bots

class BotsPane extends StatelessWidget {
  const BotsPane({super.key, required this.gid});
  final String gid;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final contacts = context.watch<ContactsStore>();
    return CommunityBuilder(
      gid: gid,
      builder: (context, g) {
        if (g == null) return const Center(child: CircularProgressIndicator());
        return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
          Row(children: [
            Expanded(child: Text(s('cm_bots_hint'), style: context.tt.bodySmall)),
            const SizedBox(width: 12),
            FilledButton.icon(
              key: const ValueKey('cm_add_bot'),
              onPressed: () async {
                if (await showAddBotDialog(context, gid) && context.mounted) await CommunityStore.of(context.read<LumoraApi>()).load(gid);
              },
              icon: const Icon(AppIcons.bot, size: 18),
              label: Text(s('add_bot')),
            ),
          ]),
          const SizedBox(height: 12),
          if (g.bots.isEmpty) EmptyState(icon: AppIcons.bot, title: s('cm_no_bots')),
          for (final (peer, readAll) in g.bots)
            Padding(
              key: ValueKey('cm_bot_$peer'),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: LCard(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Avatar(name: contacts.nameOf(peer), seed: peer, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(contacts.nameOf(peer), style: const TextStyle(fontWeight: FontWeight.w600)),
                        Text(readAll ? s('bot_reads_all') : s('bot_reads_commands'), style: context.tt.bodySmall),
                      ]),
                    ),
                    Switch(value: readAll, onChanged: (v) => _run(context, gid, (api) => api.groupBotPolicy(gid, peer, v))),
                  ]),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    for (final id in g.botRoles[peer] ?? const <String>[])
                      if (g.roleById(id) case final r?) RoleChip(role: r, dense: true),
                    ActionChip(
                      key: ValueKey('cm_bot_roles_$peer'),
                      avatar: const Icon(AppIcons.shield, size: 16),
                      label: Text(s('cm_bot_roles')),
                      onPressed: () => pickMemberRoles(context, g, peer, name: contacts.nameOf(peer), bot: true),
                    ),
                  ]),
                ]),
              ),
            ),
        ]);
      },
    );
  }
}
