import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../chats/attachments.dart' show transferPercent;
import '../chats/chat_view.dart';
import '../flows.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/peer_avatar.dart';

/// Counts the partner's messages that arrive while the session chat panel
/// is closed (badge on the Chat button).
class RemoteChatUnread extends ChangeNotifier {
  RemoteChatUnread(this.chat);
  final ChatStore chat;

  ConvThread? _thread;
  String? _conv;
  final Set<String> _seen = {};
  int _since = 0;
  int count = 0;
  bool _open = false;

  /// Follows the direct conversation with [peer] (idempotent).
  void bind(String peer) {
    final conv = peer.isEmpty ? null : 'd:$peer';
    if (conv == _conv) return;
    _thread?.removeListener(_onThread);
    _conv = conv;
    _thread = null;
    _seen.clear();
    count = 0;
    if (conv == null) return;
    final t = chat.thread(conv);
    _thread = t;
    _since = DateTime.now().millisecondsSinceEpoch - 2000;
    _seen.addAll(t.messages.map((m) => m.id));
    t.addListener(_onThread);
    if (!t.loaded) t.loadInitial().catchError((_) {});
  }

  void _onThread() {
    final t = _thread;
    if (t == null) return;
    var added = 0;
    for (final m in t.messages) {
      if (_seen.add(m.id) && !_open && !m.mine && !m.isSystem && m.ts >= _since) added++;
    }
    if (added > 0) {
      count += added;
      notifyListeners();
    }
  }

  set open(bool v) {
    _open = v;
    if (v && count > 0) {
      count = 0;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _thread?.removeListener(_onThread);
    super.dispose();
  }
}

/// Chat button with an unread badge (remote toolbar / host banner).
class ChatBadge extends StatelessWidget {
  const ChatBadge({super.key, required this.unread, required this.child});
  final RemoteChatUnread unread;
  final Widget child;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: unread,
        builder: (context, _) => Badge(
          isLabelVisible: unread.count > 0,
          label: Text(unread.count > 99 ? '99+' : '${unread.count}'),
          backgroundColor: LC.danger,
          offset: const Offset(2, -2),
          child: child,
        ),
      );
}

/// Compact chat with the session partner: header (send file, close),
/// running transfers, and the regular message list + composer.
class RemoteChatPanel extends StatelessWidget {
  const RemoteChatPanel({super.key, required this.peer, required this.onClose, this.fallbackName = ''});
  final String peer;
  final String fallbackName;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final conv = 'd:$peer';
    final name = peer.isEmpty ? fallbackName : context.select<ContactsStore, String>((c) => c.nameOf(peer));
    final header = Container(
      height: 60,
      padding: const EdgeInsets.fromLTRB(14, 0, 6, 0),
      decoration: BoxDecoration(color: context.lc.surface, border: Border(bottom: BorderSide(color: context.lc.divider))),
      child: Row(children: [
        if (peer.isNotEmpty) PeerAvatar(peer: peer, fallbackName: name, size: 36) else const Icon(AppIcons.chat, color: LC.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name.isEmpty ? s('chat') : name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            Text(s('remote_chat_sub'), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall),
          ]),
        ),
        ToolButton(icon: AppIcons.attach, tooltip: s('send_file'), onPressed: peer.isEmpty ? null : () => Flows.sendFile(context, conv)),
        ToolButton(icon: AppIcons.close, tooltip: s('close'), onPressed: onClose),
      ]),
    );
    return Material(
      color: context.lc.bg,
      child: Column(children: [
        header,
        if (peer.isEmpty)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.4)),
                  const SizedBox(height: 14),
                  Text(s('remote_chat_wait'), textAlign: TextAlign.center, style: TextStyle(color: context.lc.muted, height: 1.45)),
                ]),
              ),
            ),
          )
        else ...[
          _Transfers(conv: conv),
          // Lay the chat out for the panel's own (phone-like) width, not the screen's.
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => MediaQuery(
                data: MediaQuery.of(context).copyWith(size: Size(box.maxWidth, box.maxHeight)),
                child: ChatView(key: ValueKey(conv), conv: conv, bare: true),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

/// Outgoing files to the partner that are still on their way.
class _Transfers extends StatelessWidget {
  const _Transfers({required this.conv});
  final String conv;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final files = context.watch<FilesStore>().byId.values.where((f) => f.conv == conv && !f.incoming && f.active).toList()
      ..sort((a, b) => b.created.compareTo(a.created));
    if (files.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(color: context.lc.surface, border: Border(bottom: BorderSide(color: context.lc.divider))),
      child: Column(children: [
        for (final f in files.take(3))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              const IconTile(AppIcons.fileUpload, size: IconTileSize.sm),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text(s('remote_sending', {'name': f.name}),
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall?.copyWith(color: context.lc.text, fontWeight: FontWeight.w500)),
                    ),
                    const SizedBox(width: 8),
                    Text(f.state == FileState.transferring && f.progress > 0 ? '${transferPercent(f)}%' : s('file_starting'),
                        style: context.tt.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                  ]),
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      minHeight: 4,
                      value: f.state == FileState.transferring && f.progress > 0 ? transferPercent(f) / 100 : null,
                      backgroundColor: context.lc.surface2,
                      color: LC.primary,
                    ),
                  ),
                ]),
              ),
              IconButton(
                tooltip: s('cancel'),
                visualDensity: VisualDensity.compact,
                onPressed: () => context.read<FilesStore>().cancel(f.id).catchError((_) {}),
                icon: Icon(AppIcons.close, size: 16, color: context.lc.muted),
              ),
            ]),
          ),
      ]),
    );
  }
}

/// Tiny "Synced" chip that appears for ~1.5 s after copy & paste crossed.
class ClipboardSyncedChip extends StatefulWidget {
  const ClipboardSyncedChip({super.key, required this.pulse, this.compact = false});
  final ValueNotifier<int> pulse;

  /// Icon only (narrow toolbars).
  final bool compact;
  @override
  State<ClipboardSyncedChip> createState() => _ClipboardSyncedChipState();
}

class _ClipboardSyncedChipState extends State<ClipboardSyncedChip> {
  bool _show = false;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    widget.pulse.addListener(_onPulse);
  }

  @override
  void dispose() {
    widget.pulse.removeListener(_onPulse);
    super.dispose();
  }

  void _onPulse() {
    final g = ++_gen;
    setState(() => _show = true);
    Future<void>.delayed(const Duration(milliseconds: 1500), () {
      if (mounted && g == _gen) setState(() => _show = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = S.of(context)('clipboard_synced');
    if (widget.compact) {
      // Tiny transient badge (no layout width on narrow toolbars).
      return IgnorePointer(
        child: AnimatedScale(
          duration: Motion.normal,
          curve: Motion.curve,
          scale: _show ? 1 : 0,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(color: LC.success, shape: BoxShape.circle, border: Border.all(color: const Color(0xFF171A2E), width: 1.5)),
            child: Icon(AppIcons.check, size: 9, color: Colors.white, semanticLabel: label),
          ),
        ),
      );
    }
    return AnimatedSize(
      duration: Motion.normal,
      curve: Motion.curve,
      child: !_show
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: LC.success.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(AppIcons.clipboardDone, size: 13, color: LC.success),
                  const SizedBox(width: 4),
                  Text(label, style: const TextStyle(color: LC.success, fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
    );
  }
}
