// In-app banner for a friend request or a group invitation that just came in while the app
// is open (the system notification only shows in the background; the bell and the tab badge
// alone were easy to miss). It slides in at the top for a few seconds; the notice stays in
// the notification centre.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../groups/group_invites_ui.dart' show showGroupInvites;
import '../theme.dart';
import '../widgets/app_icons.dart';
import 'reminder_banner.dart' show appNavigatorKey;

class InviteBannerLayer extends StatefulWidget {
  const InviteBannerLayer({super.key});

  /// How long a banner stays (tests shorten it).
  static Duration shown = const Duration(seconds: 6);

  @override
  State<InviteBannerLayer> createState() => _InviteBannerLayerState();
}

class _InviteBannerLayerState extends State<InviteBannerLayer> {
  late final NotificationStore _notices = context.read<NotificationStore>();
  Notice? _current;
  Notice? _seen;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _seen = _notices.items.isEmpty ? null : _notices.items.first;
    _notices.addListener(_onNotices);
  }

  @override
  void dispose() {
    _notices.removeListener(_onNotices);
    _timer?.cancel();
    super.dispose();
  }

  void _onNotices() {
    final top = _notices.items.isEmpty ? null : _notices.items.first;
    if (top == null || identical(top, _seen)) return;
    _seen = top;
    if (top.read || (top.kind != NoticeKind.friendRequest && top.kind != NoticeKind.groupInvite)) return;
    _timer?.cancel();
    setState(() => _current = top);
    _timer = Timer(InviteBannerLayer.shown, _hide);
  }

  void _hide() {
    _timer?.cancel();
    if (mounted) setState(() => _current = null);
  }

  void _open(Notice n) {
    _hide();
    final nav = context.read<NavStore>();
    final root = appNavigatorKey.currentContext;
    // back to the home screen, then where the answer is given
    appNavigatorKey.currentState?.popUntil((r) => r.isFirst);
    if (n.kind == NoticeKind.friendRequest) {
      nav.go(Section.friends);
    } else {
      nav.go(Section.chats);
      if (root != null && root.mounted) showGroupInvites(root);
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = _current;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: Motion.slow,
            switchInCurve: Motion.curve,
            transitionBuilder: (w, a) => SlideTransition(
              position: Tween(begin: const Offset(0, -1.2), end: Offset.zero).animate(a),
              child: FadeTransition(opacity: a, child: w),
            ),
            child: n == null ? const SizedBox.shrink(key: ValueKey('none')) : _InviteBanner(key: ValueKey(n), notice: n, onOpen: () => _open(n), onClose: _hide),
          ),
        ),
      ),
    );
  }
}

class _InviteBanner extends StatelessWidget {
  const _InviteBanner({super.key, required this.notice, required this.onOpen, required this.onClose});
  final Notice notice;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final n = notice;
    final friend = n.kind == NoticeKind.friendRequest;
    final title = friend
        ? s('notice_friend', {'name': n.title})
        : (n.body.isEmpty ? s('notice_group_invite_plain', {'group': n.title}) : s('notice_group_invite', {'name': n.body, 'group': n.title}));
    final sub = friend ? n.body : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Material(
          key: const ValueKey('invite_banner'),
          elevation: 10,
          color: context.lc.surface,
          borderRadius: BorderRadius.circular(Radii.lg),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.lg),
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
              child: Row(children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(color: LC.primary.withValues(alpha: 0.14), shape: BoxShape.circle),
                  child: Icon(friend ? AppIcons.addFriend : AppIcons.people, size: 20, color: LC.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    if (sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: context.lc.muted, fontSize: 12.5)),
                  ]),
                ),
                TextButton(onPressed: onOpen, child: Text(s('fpv_view'))),
                // (no tooltip: this layer sits above the Navigator, there is no Overlay)
                Semantics(
                  button: true,
                  label: s('close'),
                  child: IconButton(
                    constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                    padding: EdgeInsets.zero,
                    icon: Icon(AppIcons.close, size: 18, color: context.lc.muted),
                    onPressed: onClose,
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
