import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../settings/blocked_screen.dart';
import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../chats/chat_view.dart';
import '../theme.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/common.dart';
import '../profile/profile_screen.dart';
import 'add_friend.dart';
import 'safety_number.dart';

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});
  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  int _tab = 0; // 0 all, 1 requests, 2 blocked
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final store = context.watch<ContactsStore>();
    final desktop = isDesktop(context);
    final pending = store.incoming.length + store.outgoing.length;
    bool match(Contact c) => _q.isEmpty || c.displayName.toLowerCase().contains(_q) || c.shortId.replaceAll(' ', '').contains(_q.replaceAll(' ', ''));

    final List<Widget> slivers;
    switch (_tab) {
      case 1:
        final inc = store.incoming.where(match).toList();
        final out = store.outgoing.where(match).toList();
        slivers = [
          if (inc.isEmpty && out.isEmpty)
            SliverFillRemaining(hasScrollBody: false, child: EmptyState(icon: AppIcons.envelopeOpen, title: s('no_requests'))),
          if (inc.isNotEmpty) _label('${s('incoming_requests')} — ${inc.length}'),
          if (inc.isNotEmpty) _list(inc, (c) => _RequestTile(contact: c, incoming: true)),
          if (out.isNotEmpty) _label('${s('outgoing_requests')} — ${out.length}'),
          if (out.isNotEmpty) _list(out, (c) => _RequestTile(contact: c, incoming: false)),
        ];
      case 2:
        final b = store.blocked.where(match).toList();
        slivers = [
          if (b.isEmpty) SliverFillRemaining(hasScrollBody: false, child: EmptyState(icon: AppIcons.block, title: s('no_blocked'))),
          if (b.isNotEmpty) _label('${s('blocked')} — ${b.length}'),
          if (b.isNotEmpty) _list(b, (c) => _BlockedTile(contact: c)),
        ];
      default:
        final f = store.friends.where(match).toList();
        final on = f.where((c) => c.online).toList();
        final off = f.where((c) => !c.online).toList();
        slivers = [
          if (f.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: AppIcons.friends,
                title: s('no_friends'),
                subtitle: s('no_friends_hint'),
                action: GradientButton(label: s('add_friend'), icon: AppIcons.addFriend, onPressed: () => showAddFriend(context)),
              ),
            ),
          if (on.isNotEmpty) _label('${s('online')} — ${on.length}'),
          if (on.isNotEmpty) _list(on, (c) => FriendTile(contact: c)),
          if (off.isNotEmpty) _label('${s('offline')} — ${off.length}'),
          if (off.isNotEmpty) _list(off, (c) => FriendTile(contact: c)),
        ];
    }

    final main = Column(children: [
      Container(
        height: 60,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.lc.divider))),
        child: Row(children: [
          Icon(AppIcons.friends, color: context.lc.muted),
          const SizedBox(width: 10),
          Text(s('friends'), style: context.tt.titleMedium),
          const SizedBox(width: 16),
          if (desktop) ...[
            _TabChip(label: s('all'), selected: _tab == 0, onTap: () => setState(() => _tab = 0)),
            _TabChip(label: s('requests'), selected: _tab == 1, badge: store.pendingCount, onTap: () => setState(() => _tab = 1)),
            _TabChip(label: s('blocked'), selected: _tab == 2, onTap: () => setState(() => _tab = 2)),
          ],
          const Spacer(),
          if (desktop)
            FilledButton.icon(
              onPressed: () => showAddFriend(context),
              icon: const Icon(AppIcons.addFriend, size: 18),
              label: Text(s('add_friend')),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
            )
          else
            ToolButton(icon: AppIcons.addFriend, tooltip: s('add_friend'), onPressed: () => showAddFriend(context)),
        ]),
      ),
      if (!desktop)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 0, label: Text(s('all'))),
              ButtonSegment(value: 1, label: Text(pending > 0 ? '${s('requests')} ($pending)' : s('requests'))),
              ButtonSegment(value: 2, label: Text(s('blocked'))),
            ],
            selected: {_tab},
            onSelectionChanged: (v) => setState(() => _tab = v.first),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: TextField(
          onChanged: (v) => setState(() => _q = v.toLowerCase().trim()),
          decoration: InputDecoration(hintText: s('search_friends'), prefixIcon: const Icon(AppIcons.search, size: 20)),
        ),
      ),
      Expanded(child: CustomScrollView(slivers: [...slivers, const SliverToBoxAdapter(child: SizedBox(height: 16))])),
    ]);

    if (!desktop) return Material(color: context.lc.bg, child: main);
    return Material(
      color: context.lc.bg,
      child: Row(children: [
        Expanded(child: main),
        Container(
          width: 340,
          decoration: BoxDecoration(color: context.lc.surface, border: Border(left: BorderSide(color: context.lc.divider))),
          child: const SingleChildScrollView(padding: EdgeInsets.all(20), child: MyIdCard()),
        ),
      ]),
    );
  }

  Widget _label(String t) => SliverToBoxAdapter(child: SectionLabel(t, padding: const EdgeInsets.fromLTRB(20, 16, 16, 6)));

  Widget _list(List<Contact> l, Widget Function(Contact) b) => SliverList.builder(itemCount: l.length, itemBuilder: (_, i) => b(l[i]));
}

class _TabChip extends StatelessWidget {
  const _TabChip({required this.label, required this.selected, required this.onTap, this.badge = 0});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int badge;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Material(
          color: selected ? context.lc.surface2 : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: selected ? context.lc.text : context.lc.muted)),
                if (badge > 0) ...[const SizedBox(width: 6), CountBadge(badge)],
              ]),
            ),
          ),
        ),
      );
}

class FriendTile extends StatelessWidget {
  const FriendTile({super.key, required this.contact});
  final Contact contact;

  void _message(BuildContext context) {
    final conv = context.read<ChatStore>().ensureDirect(contact);
    context.read<NavStore>().openConv(conv);
    if (!isDesktop(context)) {
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: conv)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = contact;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        hoverColor: context.lc.hover,
        onTap: () => _message(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(children: [
            GestureDetector(onTap: () => openProfile(context, c.peer), child: PeerAvatar(peer: c.peer, size: 42)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(c.displayName, style: context.tt.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (c.verified) ...[const SizedBox(width: 4), const Icon(AppIcons.verifiedFill, size: 15, color: LC.accent)],
                ]),
                const SizedBox(height: 2),
                Text(
                  c.online ? s('active_now') : s.lastSeen(c.lastSeen, DateTime.now()),
                  style: context.tt.bodySmall,
                  maxLines: 1,
                ),
              ]),
            ),
            ToolButton(icon: AppIcons.chat, tooltip: s('message'), onPressed: () => _message(context)),
            ToolButton(
              icon: AppIcons.call,
              tooltip: s('voice_call'),
              onPressed: () => context.read<CallStore>().start(context.read<ChatStore>().ensureDirect(c)),
            ),
            PopupMenuButton<String>(
              tooltip: s('more'),
              icon: Icon(AppIcons.moreVertical, color: context.lc.muted),
              onSelected: (v) async {
                final store = context.read<ContactsStore>();
                switch (v) {
                  case 'profile':
                    openProfile(context, c.peer);
                  case 'verify':
                    openSafetyNumber(context, c);
                  case 'rename':
                    final a = await promptText(context, title: s('set_nickname'), initial: c.alias ?? c.name, action: s('save'));
                    if (a != null) store.rename(c.peer, a);
                  case 'copy':
                    if (context.mounted) copyText(context, c.shortId);
                  case 'remove':
                    if (context.mounted &&
                        await confirm(context, title: s('remove_friend'), body: s('remove_friend_body', {'name': c.displayName}), action: s('remove'), danger: true)) {
                      store.remove(c.peer);
                    }
                  case 'block':
                    if (context.mounted &&
                        await confirm(context, title: s('block_title', {'name': c.displayName}), body: s('block_body'), action: s('block'), danger: true)) {
                      store.block(c.peer);
                    }
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'profile', child: Text(s('view_profile'))),
                PopupMenuItem(value: 'verify', child: Text(s('verify_safety'))),
                PopupMenuItem(value: 'rename', child: Text(s('set_nickname'))),
                PopupMenuItem(value: 'copy', child: Text(s('copy_id'))),
                const PopupMenuDivider(),
                PopupMenuItem(value: 'remove', child: Text(s('remove_friend'), style: const TextStyle(color: LC.danger))),
                PopupMenuItem(value: 'block', child: Text(s('block'), style: const TextStyle(color: LC.danger))),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({required this.contact, required this.incoming});
  final Contact contact;
  final bool incoming;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final store = context.read<ContactsStore>();
    final c = contact;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: LCard(
        padding: const EdgeInsets.all(12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          PeerAvatar(peer: c.peer, size: 42, presence: false),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.displayName, style: context.tt.titleSmall),
              Text(incoming ? s('wants_to_be_friends') : s('request_sent'), style: context.tt.bodySmall),
              if (c.note != null && c.note!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: context.lc.surface2, borderRadius: BorderRadius.circular(Radii.sm)),
                  child: Text('“${c.note}”', style: context.tt.bodySmall?.copyWith(color: context.lc.text, fontStyle: FontStyle.italic)),
                ),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          if (incoming) ...[
            IconButton.filled(
              onPressed: () => store.accept(c.peer),
              icon: const Icon(AppIcons.check),
              tooltip: s('accept'),
              style: IconButton.styleFrom(backgroundColor: LC.success),
            ),
            const SizedBox(width: 6),
            IconButton.filledTonal(onPressed: () => store.remove(c.peer), icon: const Icon(AppIcons.close), tooltip: s('decline')),
          ] else
            TextButton(onPressed: () => store.remove(c.peer), child: Text(s('cancel'))),
        ]),
      ),
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
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      leading: Avatar(name: contact.displayName, seed: contact.peer, size: 40),
      title: Text(contact.displayName),
      subtitle: Text('ID ${contact.shortId}'),
      trailing: OutlinedButton(onPressed: () => unblockContact(context, contact), child: Text(s('unblock'))),
    );
  }
}
