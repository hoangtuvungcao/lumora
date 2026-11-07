import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/app_lock.dart';
import '../../state/settings.dart';
import '../../state/stores.dart';
import '../lock/app_lock_screen.dart';
import '../friends/add_friend.dart';
import '../shell/notifications.dart';
import '../shell/palette.dart';
import '../flows.dart';
import 'delete_dialogs.dart';
import '../bots/botfather.dart';
import '../theme.dart';
import 'stories.dart';
import '../calls/group_call.dart' show GroupCallMark;
import '../groups/group_invites_ui.dart' show GroupInvitesBanner;
import '../settings/friend_recovery.dart' show RecoveryBanner;
import '../widgets/peer_avatar.dart';
import '../widgets/common.dart';
import '../widgets/logo.dart';
import '../widgets/typing_dots.dart';
import '../../core/text_fold.dart';

class ChatListPane extends StatefulWidget {
  const ChatListPane({super.key, required this.onOpen, this.mobile = false});
  final ValueChanged<String> onOpen;
  final bool mobile;

  @override
  State<ChatListPane> createState() => _ChatListPaneState();
}

class _ChatListPaneState extends State<ChatListPane> {
  final _search = TextEditingController();
  ChatFilter _filter = ChatFilter.all;
  String _q = '';
  bool _archived = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final chat = context.watch<ChatStore>();
    // Locked chats live in their own folder (opened with the PIN).
    final lockedIds = context.select<Settings, List<String>>((x) => x.lockedChats);
    final chatsOpen = context.select<AppLock, bool>((l) => l.chatsOpen);
    final all = chat.filtered(_filter, _q, archived: _archived);
    final list = lockedIds.isEmpty ? all : all.where((c) => !lockedIds.contains(c.id)).toList();
    final lockedList = lockedIds.isEmpty || _archived ? const <Conversation>[] : chat.sorted.where((c) => lockedIds.contains(c.id)).toList();
    final extra = chatsOpen && _q.isEmpty ? lockedList : const <Conversation>[];
    final archivedCount = chat.archivedCount;
    final pinnedCount = list.where((c) => c.pinned).length;
    return Material(
      color: widget.mobile ? context.lc.bg : context.lc.surface,
      child: Column(children: [
        if (_archived)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 8, 6),
            child: Row(children: [
              IconButton(onPressed: () => setState(() => _archived = false), icon: const Icon(AppIcons.back), tooltip: s('back')),
              Text(s('archived'), style: context.tt.titleLarge),
            ]),
          )
        else
          _Header(mobile: widget.mobile),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: TextField(
            controller: _search,
            onChanged: (v) => setState(() => _q = v),
            onSubmitted: (v) => v.trim().isEmpty ? null : showCommandPalette(context, initial: v.trim()),
            decoration: InputDecoration(
              hintText: s('search_chats'),
              prefixIcon: const Icon(AppIcons.search, size: 20),
              prefixIconConstraints: const BoxConstraints(minWidth: 40),
              suffixIcon: _q.isEmpty
                  ? null
                  : IconButton(
                      tooltip: S.of(context)('clear'),
                      icon: const Icon(AppIcons.close, size: 18),
                      onPressed: () => setState(() {
                        _search.clear();
                        _q = '';
                      }),
                    ),
            ),
          ),
        ),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final f in ChatFilter.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(s('filter_${f.name}')),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        if (!_archived && _q.isEmpty) const StoriesRow(),
        if (!_archived && _q.isEmpty) const GroupInvitesBanner(),
        if (!_archived && _q.isEmpty) const RecoveryBanner(),
        if (_q.isEmpty && lockedList.isNotEmpty) LockedChatsFolder(count: lockedList.length, unread: lockedList.any((c) => c.unread > 0)),
        if (!_archived && (_filter == ChatFilter.all || _filter == ChatFilter.direct) && (_q.isEmpty || foldContains(S.of(context)('bf_name'), _q)))
          _BotFatherTile(onTap: () => widget.onOpen(kBotFatherConv), mobile: widget.mobile),
        if (!_archived && archivedCount > 0 && _q.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ListTile(
              dense: true,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: context.lc.surface2, shape: BoxShape.circle),
                child: Icon(AppIcons.archive, color: context.lc.muted, size: 20),
              ),
              title: Text(s('archived'), style: context.tt.titleSmall),
              subtitle: Text(s('n_chats', {'n': archivedCount}), style: context.tt.bodySmall),
              trailing: CountBadge(chat.archivedUnread, muted: true),
              onTap: () => setState(() => _archived = true),
            ),
          ),
        Expanded(
          child: list.isEmpty && extra.isEmpty
              ? EmptyState(
                  icon: _q.isEmpty ? AppIcons.community : AppIcons.searchEmpty,
                  title: _q.isEmpty ? s('no_chats') : s('no_results'),
                  subtitle: _q.isEmpty ? s('no_chats_hint') : null,
                  action: _q.isEmpty
                      ? Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                          FilledButton.icon(onPressed: () => showAddFriend(context), icon: const Icon(AppIcons.addFriend, size: 18), label: Text(s('add_friend'))),
                          OutlinedButton.icon(onPressed: () => Flows.showCreateMenu(context), icon: const Icon(AppIcons.add, size: 18), label: Text(s('create_new'))),
                        ])
                      : FilledButton.tonalIcon(
                          onPressed: () => showCommandPalette(context, initial: _q),
                          icon: const Icon(AppIcons.search, size: 18),
                          label: Text(s('search_everywhere')),
                        ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: extra.length + (extra.isEmpty ? 0 : 1) + list.length + (pinnedCount > 0 && pinnedCount < list.length ? 2 : 0),
                  itemBuilder: (context, i) {
                    if (extra.isNotEmpty) {
                      // Opened "Locked" folder: its chats first, then a divider.
                      if (i < extra.length) return ConversationTile(conv: extra[i], onTap: widget.onOpen, highlightSelected: !widget.mobile);
                      if (i == extra.length) return Divider(indent: 20, endIndent: 20, height: 14, color: context.lc.divider);
                      i -= extra.length + 1;
                    }
                    if (pinnedCount > 0 && pinnedCount < list.length) {
                      if (i == 0) return SectionLabel(s('pinned'), padding: const EdgeInsets.fromLTRB(20, 4, 16, 4));
                      if (i == pinnedCount + 1) return SectionLabel(s('recent'), padding: const EdgeInsets.fromLTRB(20, 10, 16, 4));
                      final idx = i <= pinnedCount ? i - 1 : i - 2;
                      return ConversationTile(conv: list[idx], onTap: widget.onOpen, highlightSelected: !widget.mobile);
                    }
                    return ConversationTile(conv: list[i], onTap: widget.onOpen, highlightSelected: !widget.mobile);
                  },
                ),
        ),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.mobile});
  final bool mobile;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    // a narrow window (split screen, small desktop window): no logo, the title shrinks
    final narrow = MediaQuery.sizeOf(context).width < 300;
    return Padding(
      padding: EdgeInsets.fromLTRB(mobile ? 16 : 16, mobile ? 10 : 14, 8, 6),
      child: Row(children: [
        if (mobile && !narrow) ...[const LumoraLogo(size: 30), const SizedBox(width: 10)],
        Expanded(child: Text(s('chats'), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleLarge)),
        const NetStatusDot(),
        if (!mobile) ToolButton(icon: AppIcons.quickSwitcher, tooltip: '${s('quick_switcher')} (Ctrl+K)', onPressed: () => showCommandPalette(context)),
        if (mobile) ToolButton(icon: AppIcons.search, tooltip: s('quick_switcher'), onPressed: () => showCommandPalette(context)),
        const NotificationBell(),
        Builder(
          builder: (context) => ToolButton(
            icon: AppIcons.compose,
            tooltip: s('create_new'),
            onPressed: () {
              final box = context.findRenderObject() as RenderBox?;
              Flows.showCreateMenu(context, at: box?.localToGlobal(box.size.bottomLeft(Offset.zero)));
            },
          ),
        ),
      ]),
    );
  }
}

/// Simple connection-quality indicator (no network internals exposed).
class NetStatusDot extends StatelessWidget {
  const NetStatusDot({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final q = context.select<NetStore, int>((n) => connectionQuality(n.net));
    final color = q >= 3 ? LC.success : (q >= 1 ? LC.warning : LC.danger);
    final label = q >= 3 ? s('conn_direct') : (q >= 1 ? s('conn_ok') : s('connecting'));
    return Tooltip(
      message: '$label · ${s('e2e_short')}',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: SignalBars(level: q, color: color),
      ),
    );
  }
}

String _natKey(String nat) => switch (nat) {
      'open' || 'none' => 'open',
      'easy' || 'cone' || 'full_cone' || 'restricted' || 'port_restricted' => 'easy',
      'symmetric' || 'hard' => 'symmetric',
      'blocked' || 'udp_blocked' => 'blocked',
      _ => 'unknown',
    };

String natKey(String nat) => _natKey(nat);

class ConversationTile extends StatelessWidget {
  const ConversationTile({super.key, required this.conv, required this.onTap, this.highlightSelected = true});
  final Conversation conv;
  final ValueChanged<String> onTap;
  final bool highlightSelected;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final selected = highlightSelected && context.select<NavStore, bool>((n) => n.conv == conv.id && n.section == Section.chats);
    final peer = conv.peer;
    final verified = peer != null && context.select<ContactsStore, bool>((c) => c[peer]?.verified ?? false);
    final unread = conv.unread > 0;
    final lc = context.lc;
    // someone not in my contacts (no name from the core): a short id, never a blank row
    final title = conv.title.isEmpty && peer != null ? context.read<ContactsStore>().nameOf(peer) : conv.title;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? LC.primary.withValues(alpha: 0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          hoverColor: lc.hover,
          onTap: () => onTap(conv.id),
          onLongPress: () => _menu(context, null),
          onSecondaryTapDown: (d) => _menu(context, d.globalPosition),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(children: [
              conv.isSaved
                  ? const SavedAvatar(size: 48)
                  : (peer != null ? PeerAvatar(peer: peer, fallbackName: title, size: 48) : GroupAvatar(gid: conv.gid ?? conv.id, name: conv.title, size: 48)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Row(children: [
                        Flexible(
                          child: Text(conv.isSaved ? s('saved_messages') : title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.tt.titleMedium?.copyWith(fontWeight: unread ? FontWeight.w700 : FontWeight.w600)),
                        ),
                        if (verified) ...[const SizedBox(width: 4), const Icon(AppIcons.verifiedFill, size: 15, color: LC.accent)],
                        if (peer != null && context.select<ContactsStore, bool>((c) => c[peer]?.isBot ?? false)) const BotBadge(),
                        if (conv.muted) ...[const SizedBox(width: 4), Icon(AppIcons.mute, size: 14, color: lc.muted)],
                        GroupCallMark(conv: conv.id),
                      ]),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      conv.lastTs == 0 ? '' : s.listTime(conv.lastTs, DateTime.now()),
                      style: context.tt.bodySmall?.copyWith(
                          color: unread && !conv.muted ? LC.accent : lc.muted, fontWeight: unread ? FontWeight.w600 : null),
                    ),
                  ]),
                  const SizedBox(height: 3),
                  Row(children: [
                    Expanded(child: _Preview(conv: conv)),
                    if (conv.pinned && !unread) Icon(AppIcons.pinned, size: 14, color: lc.muted),
                    if (conv.mentions > 0) ...[
                      const SizedBox(width: 6),
                      Container(
                        width: 20,
                        height: 20,
                        decoration: const BoxDecoration(color: LC.warning, shape: BoxShape.circle),
                        alignment: Alignment.center,
                        child: const Text('@', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12, height: 1)),
                      ),
                    ],
                    if (unread) ...[const SizedBox(width: 6), CountBadge(conv.unread, muted: conv.muted)],
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context, Offset? pos) async {
    final s = S.read(context);
    final chat = context.read<ChatStore>();
    final items = <(String, IconData, String)>[
      ('pin', conv.pinned ? AppIcons.unpin : AppIcons.pin, conv.pinned ? s('unpin') : s('pin')),
      ('mute', conv.muted ? AppIcons.bellRinging : AppIcons.mute, conv.muted ? s('unmute') : s('mute')),
      if (conv.unread > 0) ('read', AppIcons.markRead, s('mark_read')),
      if (!conv.isSaved) ('archive', conv.archived ? AppIcons.unarchive : AppIcons.archive, conv.archived ? s('unarchive') : s('archive')),
      if (!conv.isSaved)
        context.read<AppLock>().isChatLocked(conv.id)
            ? ('lockchat', AppIcons.unlock, s('chat_unlock'))
            : ('lockchat', AppIcons.lockKey, s('chat_lock')),
      ('delete', AppIcons.delete, s('delete_chat')),
    ];
    String? r;
    if (pos != null) {
      r = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
        items: [
          for (final it in items)
            PopupMenuItem(
              value: it.$1,
              child: Row(children: [
                Icon(it.$2, size: 18, color: it.$1 == 'delete' ? LC.danger : null),
                const SizedBox(width: 12),
                Text(it.$3, style: it.$1 == 'delete' ? const TextStyle(color: LC.danger) : null),
              ]),
            ),
        ],
      );
    } else {
      r = await showModalBottomSheet<String>(
        context: context,
        builder: (c) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final it in items)
              ListTile(
                leading: Icon(it.$2, color: it.$1 == 'delete' ? LC.danger : null),
                title: Text(it.$3, style: it.$1 == 'delete' ? const TextStyle(color: LC.danger) : null),
                onTap: () => Navigator.pop(c, it.$1),
              ),
          ]),
        ),
      );
    }
    if (!context.mounted) return;
    switch (r) {
      case 'pin':
        chat.setFlag(conv.id, 'pinned', !conv.pinned);
      case 'mute':
        pickMute(context, conv.id);
      case 'read':
        chat.markRead(conv.id);
      case 'archive':
        chat.setFlag(conv.id, 'archived', !conv.archived);
      case 'lockchat':
        toggleChatLock(context, conv.id);
      case 'delete':
        askClearChat(context, conv.id, deleteChat: true);
    }
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.conv});
  final Conversation conv;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final chat = context.read<ChatStore>();
    return ValueListenableBuilder<Map<String, Set<String>>>(
      valueListenable: chat.typing,
      builder: (context, typing, _) {
        final who = typing[conv.id];
        if (who != null && who.isNotEmpty) {
          final contacts = context.read<ContactsStore>();
          final label = conv.isGroup ? s('typing_named', {'name': contacts.nameOf(who.first).split(' ').last}) : s('typing');
          return Row(children: [
            const TypingDots(size: 4.5),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.tt.bodyMedium?.copyWith(color: LC.accent, fontStyle: FontStyle.italic, fontSize: 13.5)),
            ),
          ]);
        }
        final raw = stripFormatting(conv.lastText);
        final mine = conv.lastMine;
        return PreviewLine(
          raw,
          lead: mine ? '${s('you')}: ' : '',
          style: context.tt.bodyMedium?.copyWith(
            fontSize: 13.5,
            color: conv.unread > 0 ? context.lc.text : context.lc.muted,
            fontWeight: conv.unread > 0 ? FontWeight.w500 : null,
          ),
        );
      },
    );
  }
}


class _BotFatherTile extends StatelessWidget {
  const _BotFatherTile({required this.onTap, required this.mobile});
  final VoidCallback onTap;
  final bool mobile;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final selected = !mobile && context.select<NavStore, bool>((n) => n.conv == kBotFatherConv && n.section == Section.chats);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? LC.primary.withValues(alpha: 0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(children: [
              const BotFatherAvatar(size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(s('bf_name'), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleMedium)),
                    const BotBadge(),
                    const SizedBox(width: 4),
                    const Icon(AppIcons.verifiedFill, size: 15, color: LC.accent),
                    const Spacer(),
                    Icon(AppIcons.pinned, size: 14, color: context.lc.muted),
                  ]),
                  const SizedBox(height: 3),
                  Text(s('bf_subtitle'), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodyMedium?.copyWith(fontSize: 13.5, color: context.lc.muted)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
