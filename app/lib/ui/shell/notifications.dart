import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../chats/chat_view.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../flows.dart';

/// Bell button with unread badge; opens the notification centre.
class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key});
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final n = context.select<NotificationStore, int>((x) => x.unread);
    return Badge(
      isLabelVisible: n > 0,
      label: Text('$n'),
      backgroundColor: LC.danger,
      offset: const Offset(-4, 4),
      child: ToolButton(icon: n > 0 ? AppIcons.bellRinging : AppIcons.bell, tooltip: s('notifications'), onPressed: () => showNotificationCentre(context)),
    );
  }
}

Future<void> showNotificationCentre(BuildContext context) {
  final body = const NotificationCentre();
  if (isDesktop(context)) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black26,
      builder: (_) => const Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.only(left: 84, top: 56),
          child: Material(type: MaterialType.transparency, child: SizedBox(width: 380, height: 520, child: NotificationCentre())),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (c) => SizedBox(height: MediaQuery.sizeOf(c).height * 0.75, child: body));
}

class NotificationCentre extends StatelessWidget {
  const NotificationCentre({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final store = context.watch<NotificationStore>();
    final items = store.items;
    final desktop = isDesktop(context);
    return Container(
      decoration: desktop
          ? BoxDecoration(
              color: context.lc.surface,
              borderRadius: BorderRadius.circular(Radii.lg),
              border: Border.all(color: context.lc.divider),
              boxShadow: kNoShadows ? null : const [BoxShadow(color: Colors.black38, blurRadius: 28, offset: Offset(0, 12))],
            )
          : null,
      clipBehavior: desktop ? Clip.antiAlias : Clip.none,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(children: [
            Expanded(child: Text(s('notifications'), style: context.tt.titleMedium)),
            if (store.unread > 0) TextButton(onPressed: store.markAllRead, child: Text(s('mark_all_read'))),
            if (items.isNotEmpty) ToolButton(icon: AppIcons.clearAll, tooltip: s('clear_all'), onPressed: store.clear),
          ]),
        ),
        Divider(height: 1, color: context.lc.divider),
        Expanded(
          child: items.isEmpty
              ? EmptyState(icon: AppIcons.bell, title: s('no_notifications'), subtitle: s('no_notifications_hint'))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (_, i) => _NoticeTile(n: items[i]),
                ),
        ),
      ]),
    );
  }
}

class _NoticeTile extends StatelessWidget {
  const _NoticeTile({required this.n});
  final Notice n;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final (icon, color, label) = switch (n.kind) {
      NoticeKind.mention => (AppIcons.mention, LC.warning, s('notice_mention', {'name': n.title})),
      NoticeKind.friendRequest => (AppIcons.addFriend, LC.primary, s('notice_friend', {'name': n.title})),
      NoticeKind.missedCall => (AppIcons.callMissed, LC.danger, s('notice_missed', {'name': n.title})),
      NoticeKind.file => (AppIcons.file, LC.accent, s('notice_file', {'name': n.title})),
      NoticeKind.remote => (AppIcons.screenShare, LC.warning, s('notice_remote', {'name': n.title})),
      NoticeKind.system => (AppIcons.info, context.lc.muted, n.title),
      NoticeKind.reminder => (AppIcons.reminder, LC.warning, s('notice_reminder', {'title': n.title})),
    };
    return InkWell(
      onTap: () {
        n.read = true;
        context.read<NotificationStore>().markAllRead();
        final conv = n.conv;
        final navigator = Navigator.of(context);
        navigator.pop();
        final nav = context.read<NavStore>();
        if (conv != null) {
          nav.openConv(conv);
          if (!isDesktop(context)) navigator.push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: conv)));
        } else if (n.kind == NoticeKind.friendRequest) {
          nav.go(Section.friends);
        } else if (n.kind == NoticeKind.remote) {
          nav.go(Section.remote);
        }
      },
      child: Container(
        color: n.read ? null : LC.primary.withValues(alpha: 0.06),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconTile(icon, color: color, circle: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (n.body.isNotEmpty) PreviewLine(n.body, maxLines: 2, style: context.tt.bodySmall),
              const SizedBox(height: 2),
              Text(s.listTime(n.ts, DateTime.now()), style: context.tt.bodySmall?.copyWith(fontSize: 11)),
            ]),
          ),
          if (n.kind == NoticeKind.missedCall && n.conv != null) ...[
            _Act(icon: AppIcons.call, tip: s('call_back'), onTap: () {
              Navigator.of(context).pop();
              Flows.call(context, n.conv!);
            }),
            _Act(icon: AppIcons.chat, tip: s('message'), onTap: () {
              Navigator.of(context).pop();
              Flows.openConv(context, n.conv!);
            }),
          ],
          if (n.kind == NoticeKind.friendRequest && n.peer != null)
            _Act(icon: AppIcons.check, tip: s('accept'), onTap: () {
              context.read<ContactsStore>().accept(n.peer!);
              n.read = true;
              context.read<NotificationStore>().markAllRead();
            }),
          if (!n.read) Container(width: 8, height: 8, margin: const EdgeInsets.only(top: 6), decoration: const BoxDecoration(color: LC.primary, shape: BoxShape.circle)),
        ]),
      ),
    );
  }
}


class _Act extends StatelessWidget {
  const _Act({required this.icon, required this.tip, required this.onTap});
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4),
        child: IconButton.filledTonal(onPressed: onTap, tooltip: tip, icon: Icon(icon, size: 16), visualDensity: VisualDensity.compact),
      );
}
