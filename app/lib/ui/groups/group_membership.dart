// Who runs and who joins a group (plain groups and communities):
//  * ownership: "Transfer ownership" for the owner, and leaving as the owner
//    first asks who takes over (the core refuses an owner's Leave while
//    others remain: `err.owner_must_transfer`);
//  * "Approve new members": the switch (manage_community) and the join
//    requests waiting for approval (invite).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/text_fold.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/peer_avatar.dart';
import 'community/community_common.dart' show timeLabel;

/// The members [g] can be handed to: everyone but me and the group's bots.
List<GroupMember> ownerCandidates(GroupInfo g, String me) {
  final bots = {for (final b in g.bots) b.$1};
  return [for (final m in g.members) if (m.peer != me && !bots.contains(m.peer) && m.role != 'none') m];
}

String _memberName(BuildContext context, GroupMember m) => context.read<ContactsStore>()[m.peer]?.displayName ?? m.name;

/// Owner → [peer] after a confirmation. True when done.
Future<bool> transferOwnership(BuildContext context, GroupInfo g, String peer, String name) async {
  final s = S.read(context);
  if (!await confirm(context, title: s('go_transfer_title', {'name': name}), body: s('go_transfer_body', {'name': name}), action: s('go_transfer_action'))) {
    return false;
  }
  if (!context.mounted) return false;
  try {
    await context.read<LumoraApi>().groupTransferOwner(g.gid, peer);
    if (context.mounted) toast(context, s('go_transferred', {'name': name}));
    return true;
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return false;
  }
}

/// The "choose a new owner" step of leaving: a member list; the button hands
/// the group over and leaves. The chosen member, or null (cancelled).
Future<GroupMember?> pickNewOwner(BuildContext context, GroupInfo g) {
  final me = context.read<SessionStore>().me?.peer ?? '';
  final members = ownerCandidates(g, me)
    ..sort((a, b) {
      // admins first: they already help run the group
      final r = (a.role == 'admin' ? 0 : 1).compareTo(b.role == 'admin' ? 0 : 1);
      return r != 0 ? r : _memberName(context, a).toLowerCase().compareTo(_memberName(context, b).toLowerCase());
    });
  return showModalBottomSheet<GroupMember>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (c) => _PickOwnerSheet(members: members),
  );
}

class _PickOwnerSheet extends StatefulWidget {
  const _PickOwnerSheet({required this.members});
  final List<GroupMember> members;
  @override
  State<_PickOwnerSheet> createState() => _PickOwnerSheetState();
}

class _PickOwnerSheetState extends State<_PickOwnerSheet> {
  GroupMember? _picked;
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final q = foldText(_q.trim());
    final list = widget.members.where((m) => q.isEmpty || foldText(_memberName(context, m)).contains(q)).toList();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Column(key: const ValueKey('go_pick_owner'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Row(children: [
              const Icon(AppIcons.owner, color: LC.warning, size: 22),
              const SizedBox(width: 10),
              Expanded(child: Text(s('go_pick_owner_title'), style: context.tt.titleMedium)),
            ]),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(20, 2, 20, 10), child: Text(s('go_pick_owner_hint'), style: context.tt.bodySmall)),
          if (widget.members.length > 7)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                onChanged: (v) => setState(() => _q = v),
                decoration: InputDecoration(prefixIcon: const Icon(AppIcons.search, size: 20), hintText: s('go_search'), isDense: true),
              ),
            ),
          Flexible(
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              for (final m in list)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Material(
                    color: _picked?.peer == m.peer ? LC.primary.withValues(alpha: 0.14) : Colors.transparent,
                    borderRadius: BorderRadius.circular(Radii.md),
                    child: ListTile(
                      key: ValueKey('go_pick_${m.peer}'),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
                      leading: PeerAvatar(peer: m.peer, fallbackName: m.name, size: 40),
                      title: Text(_memberName(context, m), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(s('role_${m.role}'), style: context.tt.bodySmall),
                      trailing: Icon(_picked?.peer == m.peer ? AppIcons.radioOn : AppIcons.radioOff, color: _picked?.peer == m.peer ? LC.primary : context.lc.muted),
                      onTap: () => setState(() => _picked = m),
                    ),
                  ),
                ),
            ]),
          ),
          if (_picked != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Text(s('go_leave_confirm', {'name': _memberName(context, _picked!)}), style: context.tt.bodySmall),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: Text(s('cancel')))),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton(
                  key: const ValueKey('go_pick_confirm'),
                  style: FilledButton.styleFrom(backgroundColor: LC.danger),
                  onPressed: _picked == null ? null : () => Navigator.pop(context, _picked),
                  child: Text(s('go_transfer_leave'), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Leave group / community [gid]. As its owner with other members, first the
/// "choose a new owner" step (transfer, then leave); otherwise the usual
/// confirmation ([title] / [body]). True when I left.
Future<bool> leaveGroupFlow(BuildContext context, String gid, {required String title, required String body, GroupInfo? info}) async {
  final s = S.read(context);
  final api = context.read<LumoraApi>();
  final me = context.read<SessionStore>().me?.peer ?? '';
  var g = info;
  if (g == null || g.myRole == 'owner') {
    try {
      g = await api.groupInfo(gid);
    } catch (_) {}
  }
  if (!context.mounted) return false;
  Future<bool> handOverAndLeave(GroupInfo g) async {
    final next = await pickNewOwner(context, g);
    if (next == null || !context.mounted) return false;
    try {
      await api.groupTransferOwner(gid, next.peer);
      await api.groupLeave(gid);
      return true;
    } catch (e) {
      if (context.mounted) toastError(context, e);
      return false;
    }
  }

  if (g != null && g.myRole == 'owner' && ownerCandidates(g, me).isNotEmpty) return handOverAndLeave(g);
  if (!await confirm(context, title: title, body: body, action: s('leave'), danger: true)) return false;
  if (!context.mounted) return false;
  try {
    await api.groupLeave(gid);
    return true;
  } on ApiException catch (e) {
    if (e.code == 'err.owner_must_transfer' && context.mounted) {
      // (someone joined meanwhile, or I became the owner on another device)
      try {
        final fresh = await api.groupInfo(gid);
        if (context.mounted) return handOverAndLeave(fresh);
      } catch (_) {}
    }
    if (context.mounted) toastError(context, e);
    return false;
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return false;
  }
}

/// "Approve new members" (owner / admins with manage_community).
class ApproveJoinsSwitch extends StatelessWidget {
  const ApproveJoinsSwitch({super.key, required this.info, required this.run});
  final GroupInfo info;
  final Future<void> Function(Future<void> Function(LumoraApi api) f) run;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return SwitchListTile(
      key: const ValueKey('approve_joins'),
      secondary: const Icon(AppIcons.shieldCheck),
      title: Text(s('aj_title')),
      subtitle: Text(s('aj_hint')),
      value: info.approveJoins,
      onChanged: (v) => run((api) => api.groupSettings(info.gid, approveJoins: v)),
    );
  }
}

/// An older group (1.0.7 rules): an admin switches it to Community 2.0 — roles,
/// permissions, private channels. Every member needs 1.0.8+ (the core refuses
/// with a clear message otherwise).
class RulesUpgradeTile extends StatelessWidget {
  const RulesUpgradeTile({super.key, required this.info, required this.run});
  final GroupInfo info;
  final Future<void> Function(Future<void> Function(LumoraApi api) f) run;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ListTile(
      key: const ValueKey('rules_upgrade'),
      leading: const Icon(AppIcons.shieldCheck),
      title: Text(s('ru_title')),
      subtitle: Text(s('ru_hint')),
      trailing: const Icon(AppIcons.chevronRight),
      // one way: members on older versions can no longer follow the group
      onTap: () async {
        if (!await confirm(context, title: s('ru_title'), body: s('ru_hint'), action: s('ru_action'))) return;
        await run((api) => api.groupUpgradeRules(info.gid));
      },
    );
  }
}

/// People waiting to join through an invite link: approve (group_add) or
/// decline (group_join_deny). For members holding `invite`.
class JoinRequestsSection extends StatelessWidget {
  const JoinRequestsSection({super.key, required this.info, required this.run});
  final GroupInfo info;
  final Future<void> Function(Future<void> Function(LumoraApi api) f) run;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final contacts = context.watch<ContactsStore>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionLabel(s('aj_requests', {'n': info.joinRequests.length}), padding: const EdgeInsets.fromLTRB(4, 20, 4, 6)),
      LCard(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [
          for (final r in info.joinRequests)
            Padding(
              key: ValueKey('join_request_${r.peer}'),
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(children: [
                PeerAvatar(peer: r.peer, fallbackName: r.name, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(contacts[r.peer]?.displayName ?? (r.name.isEmpty ? '?' : r.name),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (r.at > 0) Text(s('aj_asked', {'time': timeLabel(r.at)}), style: context.tt.bodySmall),
                  ]),
                ),
                TextButton(
                  key: ValueKey('join_deny_${r.peer}'),
                  onPressed: () => run((api) async {
                    await api.groupJoinDeny(info.gid, r.peer);
                    if (context.mounted) toast(context, s('aj_denied', {'name': r.name}));
                  }),
                  child: Text(s('aj_deny')),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  key: ValueKey('join_approve_${r.peer}'),
                  onPressed: () => run((api) async {
                    await api.groupAdd(info.gid, r.peer);
                    if (context.mounted) toast(context, s('aj_approved', {'name': r.name}));
                  }),
                  child: Text(s('aj_approve')),
                ),
              ]),
            ),
        ]),
      ),
    ]);
  }
}
