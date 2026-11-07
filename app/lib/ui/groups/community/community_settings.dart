// Community settings: Overview · Roles · Members · Channels ·
// Bots. Each section shows only with the matching permission (`my_perms`).
// Phones: tabs. Desktop: a side list of sections.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/api.dart';
import '../../../l10n/strings.dart';
import '../../../state/community.dart';
import '../../theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/common.dart';
import '../group_info.dart';
import 'community_channels.dart';
import 'community_common.dart';
import 'community_members.dart';

enum CommunitySection { overview, roles, members, channels, bots }

/// The sections [g] lets me open.
List<CommunitySection> communitySections(GroupInfo? g) => [
      CommunitySection.overview,
      if (g != null && g.myRole != 'none') ...[
        if (g.can(Perm.manageRoles)) CommunitySection.roles,
        if (g.can(Perm.manageRoles) || g.can(Perm.kick) || g.can(Perm.ban) || g.can(Perm.timeout)) CommunitySection.members,
        if (g.can(Perm.manageChannels)) CommunitySection.channels,
        if (g.can(Perm.manageBots)) CommunitySection.bots,
      ],
    ];

Future<void> showCommunitySettings(BuildContext context, String gid, {CommunitySection? open}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CommunitySettingsScreen(gid: gid, initial: open)));

class CommunitySettingsScreen extends StatefulWidget {
  const CommunitySettingsScreen({super.key, required this.gid, this.initial});
  final String gid;
  final CommunitySection? initial;

  @override
  State<CommunitySettingsScreen> createState() => _CommunitySettingsScreenState();
}

class _CommunitySettingsScreenState extends State<CommunitySettingsScreen> {
  late CommunitySection _section = widget.initial ?? CommunitySection.overview;

  @override
  void initState() {
    super.initState();
    CommunityStore.of(context.read<LumoraApi>()).load(widget.gid);
  }

  (IconData, String) _meta(S s, CommunitySection x) => switch (x) {
        CommunitySection.overview => (AppIcons.info, s('cm_overview')),
        CommunitySection.roles => (AppIcons.shield, s('cm_roles')),
        CommunitySection.members => (AppIcons.people, s('cm_members')),
        CommunitySection.channels => (AppIcons.channel, s('cm_channels')),
        CommunitySection.bots => (AppIcons.bot, s('cm_bots')),
      };

  Widget _body(CommunitySection x) => switch (x) {
        CommunitySection.overview => GroupInfoView(gid: widget.gid, inSettings: true),
        CommunitySection.roles => RolesPane(gid: widget.gid),
        CommunitySection.members => MembersPane(gid: widget.gid),
        CommunitySection.channels => ChannelsPane(gid: widget.gid),
        CommunitySection.bots => BotsPane(gid: widget.gid),
      };

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return CommunityBuilder(
      gid: widget.gid,
      builder: (context, g) {
        final sections = communitySections(g);
        // (the asked-for section may only show once the info has loaded)
        final current = sections.contains(_section) ? _section : CommunitySection.overview;
        final wide = MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;
        if (wide) {
          return Scaffold(
            appBar: AppBar(title: Text(s('space_settings'))),
            body: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                width: 248,
                decoration: BoxDecoration(color: context.lc.surface, border: Border(right: BorderSide(color: context.lc.divider))),
                child: ListView(padding: const EdgeInsets.all(12), children: [
                  if (g != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                      child: Text(g.name.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.labelSmall?.copyWith(letterSpacing: 0.8, color: context.lc.muted, fontWeight: FontWeight.w700)),
                    ),
                  for (final x in sections)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Material(
                        color: x == current ? LC.primary.withValues(alpha: 0.16) : Colors.transparent,
                        borderRadius: BorderRadius.circular(Radii.sm),
                        child: ListTile(
                          key: ValueKey('cm_tab_${x.name}'),
                          dense: true,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
                          leading: Icon(_meta(s, x).$1, size: 20, color: x == current ? context.lc.text : context.lc.muted),
                          title: Text(_meta(s, x).$2, style: TextStyle(fontWeight: x == current ? FontWeight.w700 : FontWeight.w500)),
                          onTap: () => setState(() => _section = x),
                        ),
                      ),
                    ),
                ]),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820), child: KeyedSubtree(key: ValueKey(current), child: _body(current))),
                ),
              ),
            ]),
          );
        }
        return DefaultTabController(
          key: ValueKey(sections.map((x) => x.name).join(',')),
          length: sections.length,
          initialIndex: sections.indexOf(current),
          child: Scaffold(
            appBar: AppBar(
              title: Text(s('space_settings')),
              bottom: sections.length < 2
                  ? null
                  : TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      onTap: (i) => _section = sections[i],
                      tabs: [for (final x in sections) Tab(key: ValueKey('cm_tab_${x.name}'), text: _meta(s, x).$2)],
                    ),
            ),
            body: sections.length < 2 ? _body(CommunitySection.overview) : TabBarView(children: [for (final x in sections) _body(x)]),
          ),
        );
      },
    );
  }
}

// =================================================================== roles

/// Roles: the built-in admin role on top, custom roles (drag to reorder),
/// `@everyone` at the foot.
class RolesPane extends StatelessWidget {
  const RolesPane({super.key, required this.gid});
  final String gid;

  Future<void> _reorder(BuildContext context, GroupInfo g, List<GroupRole> custom, int from, int to) async {
    if (to > from) to -= 1;
    if (to == from) return;
    final r = custom[from];
    // shown highest first: index i of n ↔ position n - i
    final pos = custom.length - to;
    try {
      await CommunityStore.of(context.read<LumoraApi>())
          .change(gid, (api) => api.groupRoleSet(gid, id: r.id, name: r.name, color: r.color, perms: r.perms, position: pos));
    } catch (e) {
      if (context.mounted) toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return CommunityBuilder(
      gid: gid,
      builder: (context, g) {
        if (g == null) return const Center(child: CircularProgressIndicator());
        final custom = g.customRoles;
        final admin = g.roles.where((r) => r.isAdmin).firstOrNull;
        final everyone = g.roles.where((r) => r.isEveryone).firstOrNull;
        int count(GroupRole r) => g.members.where((m) => g.rolesOf(m).any((x) => x.id == r.id)).length;
        Widget tile(GroupRole r, {Widget? handle, VoidCallback? onTap, String? subtitle}) => Padding(
              key: ValueKey('role_row_${r.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
              child: Material(
                color: context.lc.surface,
                borderRadius: BorderRadius.circular(Radii.md),
                child: ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md), side: BorderSide(color: context.lc.divider)),
                  leading: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(color: roleColor(r).withValues(alpha: 0.18), shape: BoxShape.circle),
                    child: Icon(r.isEveryone ? AppIcons.people : (r.isAdmin ? AppIcons.shield : AppIcons.user), size: 18, color: roleColor(r)),
                  ),
                  title: Text(roleName(s, r), style: TextStyle(fontWeight: FontWeight.w600, color: r.isEveryone ? null : roleColor(r))),
                  subtitle: Text(subtitle ?? s('cm_role_n_members', {'n': count(r)}), maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (r.builtin) Padding(padding: const EdgeInsets.only(right: 4), child: Pill(s('cm_builtin'), color: context.lc.muted)),
                    if (onTap != null) Icon(AppIcons.chevronRight, size: 18, color: context.lc.muted),
                    ?handle,
                  ]),
                  onTap: onTap,
                ),
              ),
            );
        return ReorderableListView.builder(
          padding: const EdgeInsets.only(bottom: 24),
          buildDefaultDragHandles: false,
          header: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(children: [
                Expanded(child: Text(s('cm_roles_hint'), style: context.tt.bodySmall)),
                const SizedBox(width: 12),
                FilledButton.icon(
                  key: const ValueKey('cm_new_role'),
                  onPressed: () => openRoleEditor(context, gid, null),
                  icon: const Icon(AppIcons.add, size: 18),
                  label: Text(s('cm_new_role')),
                ),
              ]),
            ),
            if (admin != null) tile(admin, subtitle: s('cm_role_admin_hint')),
            if (custom.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Text(s('cm_none_custom_roles'), textAlign: TextAlign.center, style: context.tt.bodySmall),
              ),
          ]),
          footer: everyone == null ? null : tile(everyone, subtitle: s('cm_role_everyone_hint'), onTap: () => openRoleEditor(context, gid, everyone)),
          itemCount: custom.length,
          onReorder: (a, b) => _reorder(context, g, custom, a, b),
          itemBuilder: (context, i) => KeyedSubtree(
            key: ValueKey('role_${custom[i].id}'),
            child: tile(
              custom[i],
              onTap: () => openRoleEditor(context, gid, custom[i]),
              handle: ReorderableDragStartListener(
                index: i,
                child: Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.drag_indicator, key: ValueKey('role_drag_${custom[i].id}'), color: context.lc.muted)),
              ),
            ),
          ),
        );
      },
    );
  }
}

Future<void> openRoleEditor(BuildContext context, String gid, GroupRole? role) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RoleEditorPage(gid: gid, role: role)));

/// Create / edit a role: name, colour, permissions; delete.
class RoleEditorPage extends StatefulWidget {
  const RoleEditorPage({super.key, required this.gid, this.role});
  final String gid;
  final GroupRole? role;

  @override
  State<RoleEditorPage> createState() => _RoleEditorPageState();
}

class _RoleEditorPageState extends State<RoleEditorPage> {
  late final _name = TextEditingController(text: widget.role?.name ?? '');
  late String _color = widget.role?.color ?? kRolePalette[2];
  late final Set<String> _perms = {...(widget.role?.perms ?? Perm.everyoneDefault)};
  bool _busy = false;

  GroupRole? get _r => widget.role;
  bool get _everyone => _r?.isEveryone ?? false;
  bool get _readOnly => _r?.isAdmin ?? false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = S.read(context);
    final name = _name.text.trim();
    if (!_everyone && name.isEmpty) {
      toast(context, s('cm_role_name_needed'));
      return;
    }
    setState(() => _busy = true);
    try {
      final perms = [for (final p in Perm.all) if (_perms.contains(p)) p];
      await CommunityStore.of(context.read<LumoraApi>()).change(
          widget.gid, (api) => api.groupRoleSet(widget.gid, id: _r?.id, name: _everyone ? _r!.name : name, color: _everyone ? _r!.color : _color, perms: perms));
      if (!mounted) return;
      toast(context, s('cm_role_saved'));
      Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final s = S.read(context);
    final r = _r!;
    if (!await confirm(context, title: s('cm_delete_role'), body: s('cm_delete_role_body', {'name': r.name}), action: s('delete'), danger: true)) return;
    if (!mounted) return;
    try {
      await CommunityStore.of(context.read<LumoraApi>()).change(widget.gid, (api) => api.groupRoleDelete(widget.gid, r.id));
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final title = _r == null ? s('cm_new_role') : (_everyone ? s('cm_everyone_perms') : s('cm_edit_role'));
    final color = hexColor(_color);
    final perms = _everyone ? Perm.all.where((p) => p != Perm.manageCommunity) : Perm.all;
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (!_readOnly)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: FilledButton(
                  key: const ValueKey('cm_role_save'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: 18)),
                  onPressed: _busy ? null : _save,
                  child: Text(s('save')),
                ),
              ),
            ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
            if (!_everyone && !_readOnly) ...[
              // live preview: how a member with this role looks
              LCard(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  CircleAvatar(radius: 18, backgroundColor: color.withValues(alpha: 0.2), child: Icon(AppIcons.user, size: 18, color: color)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      ValueListenableBuilder(
                        valueListenable: _name,
                        builder: (context, v, _) => Text(v.text.trim().isEmpty ? s('cm_role_preview') : v.text.trim(),
                            key: const ValueKey('cm_role_preview'), style: context.tt.titleSmall?.copyWith(color: color, fontWeight: FontWeight.w700)),
                      ),
                      Text(s('cm_role_preview'), style: context.tt.bodySmall),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('cm_role_name'),
                controller: _name,
                autofocus: _r == null,
                textCapitalization: TextCapitalization.sentences,
                maxLength: 32,
                decoration: InputDecoration(labelText: s('cm_role_name')),
              ),
              SectionLabel(s('cm_role_color'), padding: const EdgeInsets.fromLTRB(4, 8, 4, 10)),
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (final c in kRolePalette)
                  Semantics(
                    button: true,
                    selected: c == _color,
                    label: c,
                    child: InkWell(
                      key: ValueKey('cm_color_$c'),
                      customBorder: const CircleBorder(),
                      onTap: () => setState(() => _color = c),
                      child: AnimatedContainer(
                        duration: Motion.fast,
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: hexColor(c),
                          shape: BoxShape.circle,
                          border: Border.all(color: c == _color ? context.lc.text : Colors.transparent, width: 3),
                        ),
                        child: c == _color ? const Icon(AppIcons.check, size: 18, color: Colors.white) : null,
                      ),
                    ),
                  ),
              ]),
              const SizedBox(height: 8),
            ],
            if (_readOnly) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(s('cm_role_admin_hint'), style: context.tt.bodySmall)),
            if (_everyone) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(s('cm_role_everyone_hint'), style: context.tt.bodySmall)),
            SectionLabel(s('cm_role_perms'), padding: const EdgeInsets.fromLTRB(4, 12, 4, 6)),
            LCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Column(children: [
                for (final p in perms)
                  SwitchRow(
                    key: ValueKey('cm_perm_$p'),
                    title: permLabel(s, p),
                    subtitle: permHint(s, p),
                    value: _perms.contains(p),
                    onChanged: _readOnly ? null : (v) => setState(() => v ? _perms.add(p) : _perms.remove(p)),
                  ),
              ]),
            ),
            if (_r != null && !_r!.builtin) ...[
              const SizedBox(height: 20),
              LCard(
                padding: const EdgeInsets.all(4),
                child: ListTile(
                  key: const ValueKey('cm_role_delete'),
                  leading: const Icon(AppIcons.delete, color: LC.danger),
                  title: Text(s('cm_delete_role'), style: const TextStyle(color: LC.danger, fontWeight: FontWeight.w600)),
                  onTap: _delete,
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
