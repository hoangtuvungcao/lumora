// Blocked people: list with unblock (Settings › Privacy), the "Unblock"
// action used by profiles, and the banner that replaces the composer in a
// blocked chat.

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
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
