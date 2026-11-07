// Invitations to groups that wait for my answer (Settings › Privacy "who can
// add me to groups"): a compact banner at the top of the chat list, and the
// list with Join / Decline.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/group_invites.dart';
import '../../state/stores.dart';
import '../flows.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/peer_avatar.dart';
import 'community/community_common.dart' show timeLabel;

/// "Group invites (n)" — only while some wait.
class GroupInvitesBanner extends StatelessWidget {
  const GroupInvitesBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final store = GroupInvitesStore.of(context.read<LumoraApi>());
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final n = store.invites.length;
        final s = S.of(context);
        final extra = <Widget>[
          if (store.denied != null) _JoinDeniedCard(store: store, d: store.denied!),
          for (final e in store.pendingJoins.entries) _JoinPendingCard(name: e.value, gid: e.key),
        ];
        if (n == 0) return extra.isEmpty ? const SizedBox.shrink() : Column(mainAxisSize: MainAxisSize.min, children: extra);
        final banner = Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: Material(
            color: LC.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(Radii.md),
            child: ListTile(
              key: const ValueKey('group_invites_banner'),
              dense: true,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(gradient: LinearGradient(colors: [LC.primary, LC.accent.withValues(alpha: 0.9)]), shape: BoxShape.circle),
                child: const Icon(AppIcons.addFriend, color: Colors.white, size: 20),
              ),
              title: Text(s('gi_banner', {'n': n}), style: context.tt.titleSmall),
              subtitle: Text(s('gi_banner_hint'), style: context.tt.bodySmall),
              trailing: const Icon(AppIcons.chevronRight, size: 18),
              onTap: () => showGroupInvites(context),
            ),
          ),
        );
        return extra.isEmpty ? banner : Column(mainAxisSize: MainAxisSize.min, children: [...extra, banner]);
      },
    );
  }
}

/// "Waiting for an admin to let you into “X”" — a join request sent by link.
class _JoinPendingCard extends StatelessWidget {
  const _JoinPendingCard({required this.name, required this.gid});
  final String name;
  final String gid;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Material(
        color: LC.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.md),
        child: ListTile(
          key: ValueKey('join_pending_$gid'),
          dense: true,
          leading: const Icon(AppIcons.clock, color: LC.accent),
          title: Text(name.isEmpty ? s('jd_pending_unnamed') : s('jd_pending', {'name': name}), style: context.tt.titleSmall),
          subtitle: Text(s('jd_pending_hint'), style: context.tt.bodySmall),
        ),
      ),
    );
  }
}

/// The join request was turned down (link revoked, removed earlier, or declined).
class _JoinDeniedCard extends StatelessWidget {
  const _JoinDeniedCard({required this.store, required this.d});
  final GroupInvitesStore store;
  final JoinDenial d;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Material(
        color: LC.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.md),
        child: ListTile(
          key: const ValueKey('join_denied_banner'),
          dense: true,
          leading: const Icon(AppIcons.block, color: LC.danger),
          title: Text(d.name.isEmpty ? s('jd_title') : s('jd_title_named', {'name': d.name}), style: context.tt.titleSmall),
          subtitle: Text(s(d.key), style: context.tt.bodySmall),
          trailing: IconButton(
            key: const ValueKey('join_denied_dismiss'),
            tooltip: s('close'),
            icon: const Icon(AppIcons.close, size: 18),
            onPressed: store.dismissDenied,
          ),
        ),
      ),
    );
  }
}

Future<void> showGroupInvites(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => const _InvitesSheet(),
    );

class _InvitesSheet extends StatefulWidget {
  const _InvitesSheet();
  @override
  State<_InvitesSheet> createState() => _InvitesSheetState();
}

class _InvitesSheetState extends State<_InvitesSheet> {
  final Set<String> _busy = {};

  Future<void> _answer(GroupInvite i, bool accept) async {
    final s = S.read(context);
    final api = context.read<LumoraApi>();
    final store = GroupInvitesStore.of(api);
    final chat = context.read<ChatStore>();
    final spaces = context.read<SpacesStore>();
    setState(() => _busy.add(i.gid));
    try {
      final conv = await store.answer(i, accept);
      if (!mounted) return;
      if (accept) {
        toast(context, s('gi_joined', {'name': i.name}));
        await chat.load().catchError((_) {});
        if (i.community) await spaces.load().catchError((_) {});
        if (store.invites.isEmpty && mounted) {
          Navigator.pop(context);
          if (conv != null && conv.isNotEmpty && !i.community && context.mounted) Flows.openConv(context, conv);
        }
      } else {
        toast(context, s('gi_declined'));
        if (store.invites.isEmpty) Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => _busy.remove(i.gid));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final store = GroupInvitesStore.of(context.read<LumoraApi>());
    final contacts = context.watch<ContactsStore>();
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
          child: Column(key: const ValueKey('group_invites_sheet'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 4), child: Text(s('gi_title'), style: context.tt.titleMedium)),
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 10), child: Text(s('gi_hint'), style: context.tt.bodySmall)),
            if (store.invites.isEmpty)
              Padding(padding: const EdgeInsets.all(24), child: Center(child: Text(s('gi_empty'), style: context.tt.bodySmall))),
            Flexible(
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), children: [
                for (final i in store.invites)
                  Padding(
                    key: ValueKey('group_invite_${i.gid}'),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: LCard(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          GroupAvatar(gid: i.gid, name: i.name, size: 46),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Flexible(child: Text(i.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleSmall)),
                                if (i.community) ...[const SizedBox(width: 6), Pill(s('gi_community'), color: LC.accent)],
                              ]),
                              const SizedBox(height: 2),
                              Text(
                                s('gi_by', {'name': contacts[i.by]?.displayName ?? (i.byName.isEmpty ? '?' : i.byName), 'n': i.members}),
                                maxLines: 2,
                                style: context.tt.bodySmall,
                              ),
                              if (i.at > 0) Text(timeLabel(i.at), style: context.tt.bodySmall?.copyWith(color: context.lc.muted)),
                            ]),
                          ),
                        ]),
                        const SizedBox(height: 10),
                        Row(children: [
                          Expanded(
                            child: OutlinedButton(
                              key: ValueKey('group_invite_decline_${i.gid}'),
                              onPressed: _busy.contains(i.gid) ? null : () => _answer(i, false),
                              child: Text(s('gi_decline')),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              key: ValueKey('group_invite_accept_${i.gid}'),
                              onPressed: _busy.contains(i.gid) ? null : () => _answer(i, true),
                              child: Text(s('gi_accept')),
                            ),
                          ),
                        ]),
                      ]),
                    ),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
