// Blocked people: list with unblock (Settings › Privacy), the "Unblock"
// action used by profiles, and the banner that replaces the composer in a
// blocked chat.

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/moderation.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/peer_avatar.dart';

/// Confirms and unblocks [c]. Returns true when done.
Future<bool> unblockContact(BuildContext context, Contact c) async {
  final s = S.read(context);
  final store = context.read<ContactsStore>();
  final ok = await confirm(
    context,
    title: s('unblock_title', {'name': c.displayName}),
    body: s('unblock_body', {'name': c.displayName}),
    action: s('unblock'),
  );
  if (!ok || !context.mounted) return false;
  try {
    await store.unblock(c.peer);
    if (context.mounted) toast(context, s('unblocked', {'name': c.displayName}));
    return true;
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return false;
  }
}

/// Opens the blocked list (dialog on desktop, page on phones).
Future<void> openBlockedList(BuildContext context) {
  if (isDesktop(context)) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(clipBehavior: Clip.antiAlias, child: const SizedBox(width: 520, height: 560, child: BlockedList())),
    );
  }
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: SafeArea(child: BlockedList()))));
}

/// Settings › Privacy row: "Blocked people · N".
class BlockedRow extends StatelessWidget {
  const BlockedRow({super.key});
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final n = context.select<ContactsStore, int>((c) => c.blocked.length);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(AppIcons.block, size: 20, color: context.lc.muted),
      minLeadingWidth: 20,
      title: Text(s('blk_title'), style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
      subtitle: Text(n == 0 ? s('blk_none_short') : s('blk_count', {'n': n}), style: context.tt.bodySmall),
      trailing: const Icon(AppIcons.chevronRight, size: 18),
      onTap: () => openBlockedList(context),
    );
  }
}

class BlockedList extends StatelessWidget {
  const BlockedList({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final list = context.select<ContactsStore, List<Contact>>((c) => c.blocked);
    return Material(
      color: context.lc.bg,
      child: Column(children: [
        PaneHeader(
          title: Text(s('blk_title')),
          subtitle: list.isEmpty ? null : Text(s('blk_count', {'n': list.length})),
          onBack: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          child: list.isEmpty
              ? EmptyState(icon: AppIcons.shieldCheck, title: s('no_blocked'), subtitle: s('blk_list_hint'))
              : ListView(padding: const EdgeInsets.all(16), children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: LC.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(Radii.md)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Icon(AppIcons.info, size: 18, color: LC.primary),
                      const SizedBox(width: 10),
                      Expanded(child: Text(s('blk_list_hint'), style: context.tt.bodySmall?.copyWith(color: context.lc.text, height: 1.45))),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  LCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(children: [
                      for (final (i, c) in list.indexed) ...[
                        if (i > 0) Divider(height: 1, indent: 68, color: context.lc.divider),
                        _BlockedTile(contact: c),
                      ],
                    ]),
                  ),
                ]),
        ),
      ]),
    );
  }
}

class _BlockedTile extends StatelessWidget {
  const _BlockedTile({required this.contact});
  final Contact contact;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Opacity(opacity: 0.75, child: PeerAvatar(peer: contact.peer, fallbackName: contact.displayName, size: 42, presence: false)),
      title: Text(contact.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text('ID ${contact.shortId}', style: context.tt.bodySmall),
      trailing: OutlinedButton(
        style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
        onPressed: () => unblockContact(context, contact),
        child: Text(s('unblock')),
      ),
    );
  }
}

/// Replaces the composer of a direct chat with "You blocked X · Unblock".
class BlockedChatGate extends StatelessWidget {
  const BlockedChatGate({super.key, required this.conv, required this.child});
  final String conv;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final peer = conv.startsWith('d:') ? conv.substring(2) : null;
    final c = peer == null ? null : context.select<ContactsStore, Contact?>((x) => x[peer]);
    if (c == null || c.status != ContactStatus.blocked) return child;
    final s = S.of(context);
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        decoration: BoxDecoration(
          color: context.lc.surface,
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(color: context.lc.divider),
        ),
        child: Row(children: [
          const IconTile(AppIcons.block, color: LC.danger, circle: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(s('blk_banner', {'name': c.displayName}), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text(s('blk_banner_hint'), maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall),
            ]),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: () => unblockContact(context, c), child: Text(s('unblock'))),
        ]),
      ),
    );
  }
}

// ------------------------------------------------ blocked groups / hidden members
// (account settings: they apply on every device of the account)

Future<void> _openPage(BuildContext context, Widget page) {
  if (isDesktop(context)) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(clipBehavior: Clip.antiAlias, child: SizedBox(width: 520, height: 560, child: page)),
    );
  }
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: SafeArea(child: page))));
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: Icon(icon, size: 20, color: context.lc.muted),
        minLeadingWidth: 20,
        title: Text(title, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
        subtitle: Text(subtitle, style: context.tt.bodySmall),
        trailing: const Icon(AppIcons.chevronRight, size: 18),
        onTap: onTap,
      );
}

/// Settings › Privacy row: "Blocked groups · N".
class BlockedGroupsRow extends StatelessWidget {
  const BlockedGroupsRow({super.key});
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final n = context.select<ModerationStore, int>((m) => m.blockedGroups.length);
    return _SettingsRow(
      icon: AppIcons.report,
      title: s('blocked_groups'),
      subtitle: n == 0 ? s('blocked_groups_none') : s('blocked_groups_count', {'n': n}),
      onTap: () => _openPage(context, const BlockedGroupsList()),
    );
  }
}

/// Settings › Privacy row: "Hidden members · N".
class HiddenMembersRow extends StatelessWidget {
  const HiddenMembersRow({super.key});
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final n = context.select<ModerationStore, int>((m) => m.hiddenMembers.length);
    return _SettingsRow(
      icon: AppIcons.hide,
      title: s('hidden_members'),
      subtitle: n == 0 ? s('hidden_members_none') : s('blk_count', {'n': n}),
      onTap: () => _openPage(context, const HiddenMembersList()),
    );
  }
}

class _ListPage extends StatelessWidget {
  const _ListPage({required this.title, required this.hint, required this.empty, required this.tiles});
  final String title;
  final String hint;
  final String empty;
  final List<Widget> tiles;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.lc.bg,
      child: Column(children: [
        PaneHeader(title: Text(title), onBack: () => Navigator.of(context).maybePop()),
        Expanded(
          child: tiles.isEmpty
              ? EmptyState(icon: AppIcons.shieldCheck, title: empty, subtitle: hint)
              : ListView(padding: const EdgeInsets.all(16), children: [
                  Text(hint, style: context.tt.bodySmall),
                  const SizedBox(height: 12),
                  LCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(children: [
                      for (final (i, t) in tiles.indexed) ...[
                        if (i > 0) Divider(height: 1, indent: 68, color: context.lc.divider),
                        t,
                      ],
                    ]),
                  ),
                ]),
        ),
      ]),
    );
  }
}

class BlockedGroupsList extends StatelessWidget {
  const BlockedGroupsList({super.key});
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final list = context.select<ModerationStore, List<BlockedGroup>>((m) => m.blockedGroups);
    return _ListPage(
      title: s('blocked_groups'),
      hint: s('blocked_groups_hint'),
      empty: s('blocked_groups_none'),
      tiles: [
        for (final g in list.reversed)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            leading: Opacity(opacity: 0.75, child: Avatar(name: g.name.isEmpty ? '?' : g.name, seed: g.gid, size: 42, group: true)),
            title: Text(g.name.isEmpty ? g.gid.substring(0, g.gid.length.clamp(0, 8)) : g.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            trailing: OutlinedButton(
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () async {
                try {
                  await context.read<ModerationStore>().unblockGroup(g.gid);
                  if (context.mounted) toast(context, s('group_unblocked', {'name': g.name}));
                } catch (e) {
                  if (context.mounted) toastError(context, e);
                }
              },
              child: Text(s('unblock')),
            ),
          ),
      ],
    );
  }
}

class HiddenMembersList extends StatelessWidget {
  const HiddenMembersList({super.key});
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final list = context.select<ModerationStore, Set<String>>((m) => m.hiddenMembers);
    final contacts = context.watch<ContactsStore>();
    return _ListPage(
      title: s('hidden_members'),
      hint: s('hidden_members_hint'),
      empty: s('hidden_members_none'),
      tiles: [
        for (final p in list)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            leading: PeerAvatar(peer: p, fallbackName: contacts.nameOf(p), size: 42, presence: false),
            title: Text(contacts.nameOf(p), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            trailing: OutlinedButton(
              style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => context.read<ModerationStore>().setHidden(p, false).catchError((Object e) {
                if (context.mounted) toastError(context, e);
              }),
              child: Text(s('show_again')),
            ),
          ),
      ],
    );
  }
}
