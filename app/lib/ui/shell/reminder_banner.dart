// In-app banner for reminders that just went off (`reminder_due`), plus a
// best-effort desktop system notification. Android notifications are posted
// by AndroidBridge.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/settings.dart';
import '../../state/stores.dart';
import '../chats/chat_view.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../../state/app_lock.dart';

/// Root navigator, so overlays above it (this banner) can open a chat.
final appNavigatorKey = GlobalKey<NavigatorState>();

/// Desktop system notification (Linux: notify-send, macOS: osascript).
Future<void> desktopNotify(String title, String body) async {
  if (kIsWeb) return;
  try {
    if (Platform.isLinux) {
      await Process.run('notify-send', ['-a', 'Lumora', '-u', 'critical', '-i', 'alarm-symbolic', title, body]);
    } else if (Platform.isMacOS) {
      String q(String x) => x.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      await Process.run('osascript', ['-e', 'display notification "${q(body)}" with title "${q(title)}" sound name "Glass"']);
    }
  } catch (_) {
    // No notification service: the in-app banner still shows.
  }
}

class ReminderBannerLayer extends StatefulWidget {
  const ReminderBannerLayer({super.key});
  @override
  State<ReminderBannerLayer> createState() => _ReminderBannerLayerState();
}

class _ReminderBannerLayerState extends State<ReminderBannerLayer> {
  late final ChatStore _chat = context.read<ChatStore>();
  final Set<String> _notified = {};
  final Map<String, Timer> _expiry = {};

  @override
  void initState() {
    super.initState();
    _chat.dueReminders.addListener(_onDue);
  }

  @override
  void dispose() {
    _chat.dueReminders.removeListener(_onDue);
    for (final t in _expiry.values) {
      t.cancel();
    }
    super.dispose();
  }

  void _onDue() {
    final settings = context.read<Settings>();
    for (final d in _chat.dueReminders.value) {
      final id = d['msg_id']?.toString() ?? '';
      if (!_notified.add(id)) continue;
      // Banners stay a while (it's an alarm), then tuck into the notification centre.
      _expiry[id] = Timer(const Duration(minutes: 3), () => _chat.dismissReminder(id));
      final isAndroid = !kIsWeb && Platform.isAndroid;
      if (!isAndroid && !kIsWeb && !Platform.isIOS && settings.notifications) {
        final s = settings.locale == 'en' ? S.en : S.vn;
        final title = d['title'] == null ? s('reminder') : '${s('reminder')}: ${d['title']}';
        final note = d['note']?.toString() ?? '';
        final hide = settings.hideNotificationContent || settings.lockedChats.contains(d['conv']?.toString());
        unawaited(desktopNotify(hide ? 'Lumora' : title, hide ? s('reminder_notice_private') : (note.isNotEmpty ? note : s('reminder_its_time'))));
      }
    }
  }

  void _dismiss(String id) {
    _expiry.remove(id)?.cancel();
    _chat.dismissReminder(id);
  }

  void _open(Map<String, dynamic> d) {
    final conv = d['conv']?.toString();
    _dismiss(d['msg_id']?.toString() ?? '');
    if (conv == null) return;
    context.read<NavStore>().openConv(conv);
    if (!isDesktop(context)) {
      appNavigatorKey.currentState?.push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: conv)));
    }
  }

  Future<void> _seen(Map<String, dynamic> d) async {
    final conv = d['conv']?.toString();
    final id = d['msg_id']?.toString() ?? '';
    _dismiss(id);
    if (conv == null) return;
    try {
      await context.read<LumoraApi>().reminderSeen(conv, id);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Map<String, dynamic>>>(
      valueListenable: _chat.dueReminders,
      builder: (context, list, _) {
        final d = list.isEmpty ? null : list.last;
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
                child: d == null
                    ? const SizedBox.shrink(key: ValueKey('none'))
                    : _Banner(
                        key: ValueKey(d['msg_id']),
                        data: d,
                        more: list.length - 1,
                        onOpen: () => _open(d),
                        onSeen: () => _seen(d),
                        onClose: () => _dismiss(d['msg_id']?.toString() ?? ''),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Banner extends StatefulWidget {
  const _Banner({super.key, required this.data, required this.more, required this.onOpen, required this.onSeen, required this.onClose});
  final Map<String, dynamic> data;
  final int more;
  final VoidCallback onOpen;
  final VoidCallback onSeen;
  final VoidCallback onClose;
  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> with SingleTickerProviderStateMixin {
  late final AnimationController _ring = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void initState() {
    super.initState();
    // Ring for a few seconds, then rest.
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) _ring.stop();
    });
  }

  @override
  void dispose() {
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final lc = context.lc;
    final d = widget.data;
    final at = (d['at_ms'] as num?)?.toInt() ?? 0;
    final conv = d['conv']?.toString() ?? '';
    // Reminder from a locked chat: no title, note or chat name until opened.
    final hidden = context.select<AppLock, bool>((l) => l.isChatHidden(conv));
    final title0 = context.select<ChatStore, String?>((c) => c.convs[conv]?.title);
    final chatTitle = hidden ? null : title0;
    final late = d['late'] == true;
    final title = hidden ? s('reminder_notice_private') : d['title']?.toString() ?? '';
    final note = hidden ? '' : d['note']?.toString() ?? '';
    final sub = [
      if (at > 0) s.hhmm(DateTime.fromMillisecondsSinceEpoch(at)),
      if (late) s('reminder_late'),
      ?chatTitle,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Material(
          color: lc.surface,
          elevation: kNoShadows ? 0 : 10,
          shadowColor: Colors.black.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onOpen,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: LC.warning.withValues(alpha: 0.45)),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [LC.warning.withValues(alpha: 0.12), lc.surface],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 10),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AnimatedBuilder(
                  animation: _ring,
                  builder: (_, child) {
                    final t = _ring.value;
                    final angle = _ring.isAnimating ? 0.22 * (t < 0.5 ? (t * 4 - 1) : (3 - t * 4)) : 0.0;
                    return Transform.rotate(angle: angle, child: child);
                  },
                  child: const IconTile(AppIcons.reminder, color: LC.warning),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      Text(s('reminder_its_time'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: LC.warning)),
                      if (widget.more > 0) ...[
                        const SizedBox(width: 6),
                        Pill('+${widget.more}', color: LC.warning),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: lc.text)),
                    if (note.isNotEmpty) Text(note, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: lc.text.withValues(alpha: 0.85))),
                    if (sub.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: lc.muted)),
                    ],
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          backgroundColor: LC.warning.withValues(alpha: 0.18),
                          foregroundColor: lc.text,
                        ),
                        onPressed: widget.onSeen,
                        icon: const Icon(AppIcons.check, size: 16),
                        label: Text(s('rem_seen')),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        onPressed: widget.onOpen,
                        child: Text(s('reminder_open_chat')),
                      ),
                    ]),
                  ]),
                ),
                IconButton(
                  tooltip: S.of(context)('close'),
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                  icon: Icon(AppIcons.close, size: 18, color: lc.muted),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
