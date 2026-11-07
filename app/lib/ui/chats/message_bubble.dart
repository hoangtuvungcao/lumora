import 'dart:convert';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/common.dart';
import '../../core/links.dart';
import '../flows.dart';
import '../profile/profile_screen.dart';
import 'attachments.dart';
import 'rich_bubbles.dart';
import 'stickers.dart';
import 'animated_emoji.dart';
import 'emoji_data.dart';
import 'emoji_picker.dart';

/// Checklist / reminder messages (structured, not editable as text).
bool _isTask(Message m) => m.kind == 'checklist' || m.kind == 'reminder';

/// How long after sending a message may still be edited (the core refuses
/// later edits, on send and on receive).
const kEditWindow = Duration(hours: 48);

/// Only plain text messages can be edited: the body of a voice note,
/// location, contact card, sticker or call record is data, and replacing it
/// with typed text would destroy the message. Only my own, within 48 hours
/// of its (signed) time.
bool canEditMessage(Message m, {DateTime? now}) =>
    m.mine &&
    !m.deleted &&
    m.kind == 'text' &&
    !m.isFile &&
    !m.isPoll &&
    (now ?? DateTime.now()).millisecondsSinceEpoch - m.ts <= kEditWindow.inMilliseconds;

/// The placeholder of a message deleted for everyone: recalled by its
/// author, or removed by a group admin.
String deletedMessageText(S s, Message m) => m.removedByAdmin ? s('msg_removed_by_admin') : s('msg_recalled_by_author');

/// What "Copy" puts on the clipboard: the words a person sees, never the
/// message's JSON. Null = nothing sensible to copy.
String? copyableText(Message m) {
  if (m.selfDestructs || m.deleted) return null; // (no copies of a self-destructing message)
  switch (m.kind) {
    case 'text':
      return m.isFile || m.isPoll ? null : m.body;
    case 'location':
      final l = LocationData.parse(m.body);
      if (l == null) return null;
      final at = '${l.lat.toStringAsFixed(6)}, ${l.lon.toStringAsFixed(6)}';
      return l.label.trim().isEmpty ? at : '${l.label.trim()} ($at)';
    case 'contact':
      final c = ContactCard.parse(m.body);
      if (c == null) return null;
      return c.shortId.isEmpty ? c.name : '${c.name} (${c.shortId})';
    default:
      return null;
  }
}

/// Callbacks the chat view provides to each bubble.
class BubbleActions {
  const BubbleActions({
    required this.onReply,
    required this.onEdit,
    required this.onDelete,
    required this.onReact,
    required this.onJumpTo,
    required this.onForward,
    required this.onPin,
    required this.onSave,
    required this.onSelect,
    required this.onVote,
    this.onReport,
    this.selecting = false,
    this.canPin = true,
  });

  /// Pin / unpin is offered (groups: the `pin` permission).
  final bool canPin;

  /// Group messages of others: report to the group's admins (null: not offered).
  final void Function(Message m)? onReport;
  final void Function(Message m) onForward;
  final void Function(Message m) onPin;
  final void Function(Message m) onSave;
  final void Function(Message m) onSelect;
  final void Function(Message m, int option) onVote;
  final bool selecting;
  final void Function(Message m) onReply;
  final void Function(Message m) onEdit;
  final void Function(Message m) onDelete;
  final void Function(Message m, String emoji) onReact;
  final void Function(String id) onJumpTo;
}

class MessageTile extends StatefulWidget {
  const MessageTile({
    super.key,
    required this.message,
    required this.isGroup,
    required this.firstInGroup,
    required this.lastInGroup,
    required this.actions,
    required this.myPeer,
    this.reply,
    this.highlight = false,
    this.selected = false,
    this.album,
  });

  /// Consecutive photos rendered as one album bubble.
  final List<Message>? album;
  final bool selected;
  final Message message;
  final bool isGroup;
  final bool firstInGroup;
  final bool lastInGroup;
  final BubbleActions actions;
  final String myPeer;
  final Message? reply;
  final bool highlight;

  @override
  State<MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<MessageTile> {
  bool _hover = false;
  double _drag = 0;

  /// Reaction counts last built, and a per-emoji token bumped whenever one
  /// is added (so its chip animates once - not when scrolled into view).
  Map<String, int>? _seenReactions;
  final Map<String, int> _bumps = {};

  int _reactionBump(String emoji, int count) {
    final seen = _seenReactions ??= {for (final e in m.reactions.entries) e.key: e.value.length};
    final before = seen[emoji];
    if (before == null || count > before) _bumps[emoji] = (_bumps[emoji] ?? 0) + 1;
    seen[emoji] = count;
    return _bumps[emoji] ?? 0;
  }

  Message get m => widget.message;

  @override
  Widget build(BuildContext context) {
    if (m.isSystem) return _SystemLine(message: m);
    final desktop = isDesktop(context);
    final mine = m.mine;
    final showAvatar = widget.isGroup && !mine;
    final width = MediaQuery.sizeOf(context).width;
    final maxW = desktop ? (width * 0.5).clamp(280.0, 560.0) : width * 0.78;

    Widget bubble = _Bubble(
      message: m,
      reply: widget.reply,
      first: widget.firstInGroup,
      last: widget.lastInGroup,
      showName: widget.isGroup && !mine && widget.firstInGroup,
      maxWidth: maxW,
      onJumpTo: widget.actions.onJumpTo,
      onVote: (i) => widget.actions.onVote(m, i),
      myPeer: widget.myPeer,
      album: widget.album,
    );

    final reactions = m.reactions.isEmpty || m.deleted
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Wrap(spacing: 4, runSpacing: 4, children: [
              for (final e in m.reactions.entries)
                _ReactionChip(
                  emoji: e.key,
                  count: e.value.length,
                  mine: e.value.contains(widget.myPeer),
                  bump: _reactionBump(e.key, e.value.length),
                  onTap: () => widget.actions.onReact(m, e.key),
                ),
            ]),
          );

    Widget column = Column(
      crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [bubble, if (!m.deleted && messageButtons(m).isNotEmpty) _InlineButtons(message: m), ?reactions],
    );

    // Hover actions (desktop).
    final hoverBar = desktop && !m.deleted
        ? AnimatedOpacity(
            duration: Motion.fast,
            opacity: _hover ? 1 : 0,
            child: IgnorePointer(ignoring: !_hover, child: _HoverBar(message: m, actions: widget.actions, onMore: _openMenu)),
          )
        : null;

    Widget row = Row(
      mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (showAvatar)
          SizedBox(
            width: 40,
            child: widget.lastInGroup
                ? Align(
                    alignment: Alignment.bottomLeft,
                    child: GestureDetector(
                      onTap: () => openProfile(context, m.author),
                      child: PeerAvatar(peer: m.author, fallbackName: _authorName(context), size: 30, presence: false),
                    ),
                  )
                : null,
          ),
        if (mine && hoverBar != null) ...[hoverBar, const SizedBox(width: 6)],
        Flexible(child: column),
        if (!mine && hoverBar != null) ...[const SizedBox(width: 6), hoverBar],
      ],
    );

    // Swipe-to-reply (mobile).
    if (widget.actions.selecting) {
      // Selection mode: no gestures besides toggle (added below).
    } else if (!desktop && !m.deleted) {
      row = GestureDetector(
        onHorizontalDragUpdate: (d) => setState(() => _drag = (_drag + d.delta.dx).clamp(0.0, 80.0)),
        onHorizontalDragEnd: (_) {
          if (_drag > 56) {
            HapticFeedback.lightImpact();
            widget.actions.onReply(m);
          }
          setState(() => _drag = 0);
        },
        onLongPress: _openSheet,
        child: Stack(alignment: Alignment.centerLeft, children: [
          Opacity(
            opacity: (_drag / 56).clamp(0.0, 1.0),
            child: const Padding(padding: EdgeInsets.only(left: 8), child: Icon(AppIcons.reply, color: LC.accent)),
          ),
          AnimatedContainer(
            duration: _drag == 0 ? Motion.normal : Duration.zero,
            curve: Motion.curve,
            transform: Matrix4.translationValues(_drag, 0, 0),
            child: row,
          ),
        ]),
      );
    } else if (desktop) {
      row = MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(onSecondaryTapDown: (d) => _openMenu(d.globalPosition), child: row),
      );
    }

    if (widget.actions.selecting) {
      row = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.actions.onSelect(m),
        child: Row(children: [
          AnimatedContainer(
            duration: Motion.fast,
            width: 22,
            height: 22,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.selected ? LC.primary : Colors.transparent,
              border: Border.all(color: widget.selected ? LC.primary : context.lc.muted, width: 2),
            ),
            child: widget.selected ? const Icon(AppIcons.check, size: 14, color: Colors.white) : null,
          ),
          Expanded(child: IgnorePointer(child: row)),
        ]),
      );
    }

    return AnimatedContainer(
      duration: Motion.slow,
      color: widget.highlight || widget.selected ? LC.primary.withValues(alpha: 0.14) : Colors.transparent,
      padding: EdgeInsets.only(left: 12, right: 12, top: widget.firstInGroup ? 8 : 1.5, bottom: 1.5),
      child: row,
    );
  }

  String _authorName(BuildContext context) => context.read<ContactsStore>().nameOf(m.author);

  List<(String, IconData, String)> _items(S s) => [
        ('reply', AppIcons.reply, s('reply')),
        if (!m.selfDestructs) ('forward', AppIcons.forward, s('forward')),
        if (widget.actions.canPin) (m.pinned ? 'unpin' : 'pin', m.pinned ? AppIcons.unpin : AppIcons.pin, m.pinned ? s('unpin_message') : s('pin_message')),
        if (copyableText(m) != null) ('copy', AppIcons.copy, s('copy_text')),
        if (m.conv != 's:me' && !m.selfDestructs) ('save', AppIcons.saveMessage, s('save_message')),
        if (m.kind == 'sticker' && !m.mine && stickerHashOf(m) != null) ('save_sticker', AppIcons.sticker, s('save_to_pack')),
        if (widget.isGroup && m.mine) ('seen', AppIcons.checkDouble, s('seen_by')),
        ('select', AppIcons.checkCircle, s('select')),
        if (canEditMessage(m)) ('edit', AppIcons.edit, s('edit')),
        if (widget.isGroup && !m.mine && m.kind != 'system' && widget.actions.onReport != null) ('report', AppIcons.report, s('report')),
        ('delete', AppIcons.delete, s('delete')),
      ];

  void _do(String? r) {
    switch (r) {
      case 'forward':
        widget.actions.onForward(m);
      case 'pin' || 'unpin':
        widget.actions.onPin(m);
      case 'save':
        widget.actions.onSave(m);
      case 'select':
        widget.actions.onSelect(m);
      case 'save_sticker':
        saveStickerToPack(context, stickerHashOf(m)!);
      case 'seen':
        showSeenBy(context, m);
      case 'reply':
        widget.actions.onReply(m);
      case 'copy':
        final t = copyableText(m);
        if (t != null) copyText(context, t);
      case 'edit':
        widget.actions.onEdit(m);
      case 'delete':
        widget.actions.onDelete(m);
      case 'report':
        widget.actions.onReport?.call(m);
    }
  }

  Future<void> _openMenu(Offset pos) async {
    final s = S.read(context);
    final r = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        PopupMenuItem<String>(
          height: 44,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final e in kQuickReactions.take(6))
              QuickReactionButton(
                emoji: e,
                size: 26,
                padding: const EdgeInsets.all(3),
                onTap: () {
                  Navigator.pop(context);
                  widget.actions.onReact(m, e);
                },
              ),
            _MoreReactions(onTap: () async {
              Navigator.pop(context);
              final e = await pickEmoji(context);
              if (e != null) widget.actions.onReact(m, e);
            }),
          ]),
        ),
        const PopupMenuDivider(),
        for (final it in _items(s))
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
    _do(r);
  }

  Future<void> _openSheet() async {
    if (m.deleted) return;
    HapticFeedback.selectionClick();
    final s = S.read(context);
    final r = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              for (final e in kQuickReactions)
                Expanded(
                  child: Center(
                    child: QuickReactionButton(
                      emoji: e,
                      size: 32,
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                      onTap: () => Navigator.pop(c, 'r:$e'),
                    ),
                  ),
                ),
              IconButton.filledTonal(tooltip: s('react'), onPressed: () => Navigator.pop(c, 'more'), icon: const Icon(AppIcons.add)),
            ]),
          ),
          const Divider(),
          for (final it in _items(s))
            ListTile(
              leading: Icon(it.$2, color: it.$1 == 'delete' ? LC.danger : null),
              title: Text(it.$3, style: it.$1 == 'delete' ? const TextStyle(color: LC.danger) : null),
              onTap: () => Navigator.pop(c, it.$1),
            ),
        ])),
      ),
    );
    if (!mounted) return;
    if (r == 'more') {
      final e = await pickEmoji(context);
      if (e != null) widget.actions.onReact(m, e);
    } else if (r != null && r.startsWith('r:')) {
      widget.actions.onReact(m, r.substring(2));
    } else {
      _do(r);
    }
  }
}

class _HoverBar extends StatelessWidget {
  const _HoverBar({required this.message, required this.actions, required this.onMore});
  final Message message;
  final BubbleActions actions;
  final void Function(Offset) onMore;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: context.lc.surface,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: context.lc.divider),
        boxShadow: kNoShadows ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final e in kQuickReactions.take(3))
          QuickReactionButton(
            emoji: e,
            size: 20,
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
            onTap: () => actions.onReact(message, e),
          ),
        _Mini(icon: AppIcons.add, tip: s('react'), onTap: () async {
          final e = await pickEmoji(context);
          if (e != null) actions.onReact(message, e);
        }),
        _Mini(icon: AppIcons.reply, tip: s('reply'), onTap: () => actions.onReply(message)),
        Builder(
          builder: (c) => _Mini(
            icon: AppIcons.more,
            tip: s('more'),
            onTap: () {
              final box = c.findRenderObject() as RenderBox;
              onMore(box.localToGlobal(box.size.bottomLeft(Offset.zero)));
            },
          ),
        ),
      ]),
    );
  }
}

class _Mini extends StatelessWidget {
  const _Mini({required this.icon, required this.tip, required this.onTap});
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(padding: const EdgeInsets.all(5), child: Icon(icon, size: 17, color: context.lc.muted)),
        ),
      );
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.first,
    required this.last,
    required this.showName,
    required this.maxWidth,
    required this.onJumpTo,
    required this.onVote,
    required this.myPeer,
    this.reply,
    this.album,
  });
  final List<Message>? album;
  final void Function(int) onVote;
  final String myPeer;
  final Message message;
  final Message? reply;
  final bool first;
  final bool last;
  final bool showName;
  final double maxWidth;
  final void Function(String id) onJumpTo;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final m = message;
    final mine = m.mine;
    final lc = context.lc;
    const r = Radius.circular(18);
    const rs = Radius.circular(5);
    final radius = BorderRadius.only(
      topLeft: !mine && !first ? rs : r,
      bottomLeft: !mine ? (last ? const Radius.circular(4) : rs) : r,
      topRight: mine && !first ? rs : r,
      bottomRight: mine ? (last ? const Radius.circular(4) : rs) : r,
    );
    final fg = mine ? Colors.white : lc.text;
    final metaColor = mine ? Colors.white.withValues(alpha: 0.75) : lc.muted;
    final time = s.hhmm(DateTime.fromMillisecondsSinceEpoch(m.ts));

    final meta = Row(mainAxisSize: MainAxisSize.min, children: [
      if (m.expires != null) ...[Icon(AppIcons.timer, size: 12, color: metaColor), const SizedBox(width: 3)],
      if (m.edited && !m.deleted) ...[Text(s('edited'), style: TextStyle(fontSize: 11, color: metaColor)), const SizedBox(width: 4)],
      if (m.silent && !m.deleted) ...[
        Tooltip(message: s('sent_silently'), child: Icon(AppIcons.mute, size: 11, color: metaColor)),
        const SizedBox(width: 3),
      ],
      Text(time, style: TextStyle(fontSize: 11, color: metaColor, fontFeatures: const [FontFeature.tabularFigures()])),
      if (mine) ...[const SizedBox(width: 3), _Ticks(status: m.status, color: metaColor, conv: m.conv, hlc: m.hlc)],
    ]);

    Widget content;
    var media = false;
    final ref = m.isFile ? FileRef.parse(m.body) : null;
    // 1-3 emoji and nothing else: big (animated when available), no bubble.
    final jumbo = !m.deleted && !m.isFile && m.kind != 'sticker' && !m.isPoll && !_isTask(m) && reply == null && m.replyTo == null && m.forwardedFrom == null && m.restoredFrom == null
        ? jumboEmojis(m.body)
        : null;
    if (m.deleted) {
      content = Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(AppIcons.block, size: 15, color: metaColor),
        const SizedBox(width: 6),
        Flexible(child: Text(deletedMessageText(s, m), style: TextStyle(color: metaColor, fontStyle: FontStyle.italic))),
        const SizedBox(width: 8),
        meta,
      ]);
    } else if (m.kind == 'location') {
      media = true;
      content = LocationBubble(message: m, overlay: _GlassMeta(child: _whiteMeta(context, m, s, time)));
    } else if (m.kind == 'voice') {
      content = VoiceBubble(message: m, overlay: meta);
    } else if (m.kind == 'contact') {
      content = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        ContactCardBubble(message: m),
        const SizedBox(height: 4),
        meta,
      ]);
    } else if (m.isPoll) {
      content = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        PollView(message: m, myPeer: myPeer, onVote: onVote),
        const SizedBox(height: 4),
        meta,
      ]);
    } else if (m.kind == 'checklist') {
      content = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        ChecklistBubble(message: m, myPeer: myPeer),
        const SizedBox(height: 4),
        meta,
      ]);
    } else if (m.kind == 'reminder') {
      content = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        ReminderBubble(message: m, myPeer: myPeer),
        const SizedBox(height: 4),
        meta,
      ]);
    } else if (m.isFile && album != null && album!.length > 1) {
      media = true;
      final whiteMeta = _whiteMeta(context, m, s, time);
      content = ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AlbumGrid(
          items: [for (final a in album!) (a, FileRef.parse(a.body) ?? const FileRef('', '', 0))],
          overlay: whiteMeta,
          onOpen: (x) => openMediaViewer(context, conv: m.conv, initialId: x.id),
        ),
      );
    } else if (m.isFile && (ref?.isImage ?? false)) {
      media = true;
      content = ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ImageBubble(
          message: m,
          ref: ref!,
          overlay: _whiteMeta(context, m, s, time),
          onOpen: () => openMediaViewer(context, conv: m.conv, initialId: m.id),
        ),
      );
    } else if (m.isFile && (ref?.isVideo ?? false)) {
      media = true;
      content = ClipRRect(borderRadius: BorderRadius.circular(14), child: VideoCard(message: m, ref: ref!, overlay: _whiteMeta(context, m, s, time)));
    } else if (m.isFile) {
      content = Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        FileCard(message: m, ref: ref ?? FileRef('', 'file', 0)),
        const SizedBox(height: 4),
        meta,
      ]);
    } else {
      final emojiOnly = jumbo == null && _isEmojiOnly(m.body);
      content = Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 8,
        children: [
          emojiOnly
              ? Text(m.body, style: const TextStyle(fontSize: 34, height: 1.15))
              : RichMessageText(text: m.body, color: fg, mine: mine, mentionsMe: m.mentions.contains(myPeer) || m.mentionAll),
          Padding(padding: const EdgeInsets.only(top: 4), child: meta),
        ],
      );
    }

    if (jumbo != null) {
      return Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (showName)
          Text(context.read<ContactsStore>().nameOf(m.author), style: TextStyle(color: _authorColor(m.author), fontWeight: FontWeight.w600, fontSize: 13)),
        JumboEmoji(emojis: jumbo),
        Padding(padding: const EdgeInsets.only(top: 2), child: _GlassMeta(child: _whiteMeta(context, m, s, time))),
      ]);
    }
    if (m.kind == 'sticker' && !m.deleted) {
      // Stickers render without a bubble.
      return Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (showName)
          Text(context.read<ContactsStore>().nameOf(m.author), style: TextStyle(color: _authorColor(m.author), fontWeight: FontWeight.w600, fontSize: 13)),
        StickerBubble(message: m, overlay: _GlassMeta(child: _whiteMeta(context, m, s, time))),
      ]);
    }
    final authorColor = _authorColor(m.author);
    final showTail = last && !m.isPoll && !_isTask(m);
    final tailColor = mine ? const Color(0xFF5A4BD8) : lc.bubbleIn;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Stack(clipBehavior: Clip.none, children: [
        if (showTail)
          Positioned(
            bottom: 0,
            left: mine ? null : -6,
            right: mine ? -6 : null,
            child: CustomPaint(size: const Size(12, 14), painter: _TailPainter(color: tailColor, mine: mine)),
          ),
        Container(
        padding: media ? const EdgeInsets.all(3) : EdgeInsets.fromLTRB(m.isFile ? 6 : 12, m.isFile ? 6 : 8, m.isFile ? 8 : 12, 7),
        decoration: BoxDecoration(
          gradient: mine ? const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [LC.primary, Color(0xFF5A4BD8)]) : null,
          color: mine ? null : lc.bubbleIn,
          borderRadius: radius,
          border: mine ? null : Border.all(color: lc.divider.withValues(alpha: Theme.of(context).brightness == Brightness.light ? 1 : 0)),
          boxShadow: !kNoShadows && Theme.of(context).brightness == Brightness.light
              ? [BoxShadow(color: const Color(0xFF14162B).withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 1))]
              : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (showName)
            Padding(
              padding: EdgeInsets.only(bottom: 2, left: m.isFile ? 6 : 0),
              child: GestureDetector(
                onTap: () => openProfile(context, m.author),
                child: Text(context.read<ContactsStore>().nameOf(m.author),
                  style: TextStyle(color: authorColor, fontWeight: FontWeight.w600, fontSize: 13)),)
            ),
          if (m.forwardedFrom != null)
            Padding(
              padding: EdgeInsets.only(bottom: 4, left: m.isFile ? 6 : 0),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(AppIcons.forward, size: 14, color: mine ? Colors.white70 : LC.accent),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    s('forwarded_from', {'name': context.read<ContactsStore>().nameOf(m.forwardedFrom!)}),
                    style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: mine ? Colors.white70 : LC.accent),
                  ),
                ),
              ]),
            ),
          if (m.restoredFrom != null)
            Padding(
              key: ValueKey('restored_from_${m.id}'),
              padding: EdgeInsets.only(bottom: 4, left: m.isFile ? 6 : 0),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(AppIcons.history, size: 14, color: mine ? Colors.white70 : context.lc.muted),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    s(m.restoredUnverified ? 'rc_restored_unverified' : 'rc_restored_from', {
                      'name': () {
                        final c = m.restoredPeer == null ? null : context.read<ContactsStore>()[m.restoredPeer!];
                        return c != null && c.displayName.isNotEmpty ? c.displayName : m.restoredFrom!;
                      }(),
                    }),
                    style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: mine ? Colors.white70 : context.lc.muted),
                  ),
                ),
              ]),
            ),
          if (m.pinned)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Icon(AppIcons.pinned, size: 12, color: mine ? Colors.white70 : context.lc.muted),
            ),
          if (reply != null || m.replyTo != null)
            _ReplyQuote(reply: reply, mine: mine, onTap: () => onJumpTo(m.replyTo!)),
          content,
        ]),
      ),
      ]),
    );
  }

  Widget _whiteMeta(BuildContext context, Message m, S s, String time) => Row(mainAxisSize: MainAxisSize.min, children: [
        if (m.edited) ...[Text(s('edited'), style: const TextStyle(fontSize: 11, color: Colors.white)), const SizedBox(width: 4)],
        Text(time, style: const TextStyle(fontSize: 11, color: Colors.white)),
        if (m.mine) ...[const SizedBox(width: 3), _Ticks(status: m.status, color: Colors.white, conv: m.conv, hlc: m.hlc)],
      ]);

  static bool _isEmojiOnly(String t) {
    final s = t.trim();
    if (s.isEmpty || s.runes.length > 8) return false;
    return s.runes.every((r) => r > 0x2000 || r == 0x200d || r == 0xfe0f || r == 0x20);
  }

  static Color _authorColor(String peer) {
    const colors = [Color(0xFF8B7CFF), Color(0xFF00C2D1), Color(0xFFF59E0B), Color(0xFFEC4899), Color(0xFF22C55E), Color(0xFF3B82F6)];
    return colors[peer.codeUnits.fold<int>(0, (a, c) => a + c) % colors.length];
  }
}

class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.reply, required this.mine, required this.onTap});
  final Message? reply;
  final bool mine;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final r = reply;
    final name = r == null ? '' : (r.mine ? s('you') : context.read<ContactsStore>().nameOf(r.author));
    final text = r == null
        ? s('original_unavailable')
        : (r.deleted
            ? deletedMessageText(s, r)
            : (r.isFile
                ? '📎 ${FileRef.parse(r.body)?.name ?? ''}'
                : r.kind == 'checklist'
                    ? '☑️ ${ChecklistData.parse(r)?.title ?? ''}'
                    : r.kind == 'reminder'
                        ? '⏰ ${ReminderData.parse(r)?.title ?? ''}'
                        : r.body));
    final token = r != null && !r.deleted && (r.isFile || r.kind == 'checklist' || r.kind == 'reminder');
    final bar = mine ? Colors.white : LC.accent;
    return GestureDetector(
      onTap: r == null ? null : onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
        decoration: BoxDecoration(
          color: mine ? Colors.white.withValues(alpha: 0.14) : LC.accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: bar, width: 3)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (name.isNotEmpty)
            Text(name, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: mine ? Colors.white : LC.accent)),
          if (token)
            PreviewLine(text,
                maxLines: 2,
                iconColor: mine ? Colors.white.withValues(alpha: 0.85) : null,
                style: TextStyle(fontSize: 13, color: mine ? Colors.white.withValues(alpha: 0.85) : context.lc.muted))
          else
            Text(text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: mine ? Colors.white.withValues(alpha: 0.85) : context.lc.muted)),
        ]),
      ),
    );
  }
}

class _Ticks extends StatelessWidget {
  const _Ticks({required this.status, required this.color, this.conv = '', this.hlc = 0});
  final MessageStatus status;
  final Color color;
  final String conv;
  final int hlc;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    // groups: a member's read receipt (`group_read`) turns my message "read" live
    final group = conv.startsWith('g:') && hlc > 0 && (status == MessageStatus.sent || status == MessageStatus.delivered);
    final seen = context.select<ChatStore, bool>((c) => group && c.groupSeen(conv, hlc));
    final (icon, tip, c) = switch (seen ? MessageStatus.read : status) {
      MessageStatus.pending => (AppIcons.clock, s('status_pending'), color),
      MessageStatus.sent => (AppIcons.check, s('status_sent'), color),
      MessageStatus.delivered => (AppIcons.checkDouble, s('status_delivered'), color),
      MessageStatus.read => (AppIcons.checkDouble, s('status_read'), const Color(0xFF7DF3FF)),
      MessageStatus.failed => (AppIcons.error, s('status_failed'), LC.danger),
    };
    return Tooltip(message: tip, child: Icon(icon, size: 15, color: c));
  }
}

class _ReactionChip extends StatefulWidget {
  const _ReactionChip({required this.emoji, required this.count, required this.mine, required this.bump, required this.onTap});
  final String emoji;
  final int count;
  final bool mine;

  /// Changes when this reaction was just added: play the animation once.
  final int bump;
  final VoidCallback onTap;

  @override
  State<_ReactionChip> createState() => _ReactionChipState();
}

class _ReactionChipState extends State<_ReactionChip> {
  final _player = EmojiPlayer();

  @override
  void initState() {
    super.initState();
    if (widget.bump > 0) WidgetsBinding.instance.addPostFrameCallback((_) => _player.play());
  }

  @override
  void didUpdateWidget(_ReactionChip old) {
    super.didUpdateWidget(old);
    if (widget.bump != old.bump) WidgetsBinding.instance.addPostFrameCallback((_) => _player.play());
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mine = widget.mine;
    return Material(
      color: mine ? LC.primary.withValues(alpha: 0.22) : context.lc.surface2,
      shape: StadiumBorder(side: BorderSide(color: mine ? LC.primary : context.lc.divider)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            AnimatedEmoji(widget.emoji, size: 20, player: _player),
            if (widget.count > 1) ...[
              const SizedBox(width: 3),
              Text('${widget.count}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.lc.text)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// "+" at the end of the quick-reaction row: opens the full emoji picker.
class _MoreReactions extends StatelessWidget {
  const _MoreReactions({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: S.of(context)('react'),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 30,
            height: 30,
            margin: const EdgeInsets.only(left: 4),
            decoration: BoxDecoration(color: context.lc.surface2, shape: BoxShape.circle),
            child: Icon(AppIcons.add, size: 16, color: context.lc.muted),
          ),
        ),
      );
}

class _SystemLine extends StatelessWidget {
  const _SystemLine({required this.message});
  final Message message;

  @override
  Widget build(BuildContext context) {
    final isCall = message.kind == 'call';
    final newDevice = !isCall && message.body.contains('"sys.contact_device_added"');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 24),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: (Theme.of(context).brightness == Brightness.dark ? const Color(0xFF0F1020) : Colors.white).withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(Radii.xl),
            border: Border.all(color: context.lc.divider.withValues(alpha: 0.5)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(isCall ? AppIcons.call : (newDevice ? AppIcons.devices : AppIcons.info), size: 14, color: isCall ? LC.success : context.lc.muted),
            const SizedBox(width: 6),
            Flexible(child: Text(systemText(context, message), style: context.tt.bodySmall, textAlign: TextAlign.center)),
            if (isCall && !message.mine) ...[
              const SizedBox(width: 8),
              InkWell(
                onTap: () => Flows.call(context, message.conv),
                child: Text(S.of(context)('call_back'), style: context.tt.bodySmall?.copyWith(color: LC.primary, fontWeight: FontWeight.w700)),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Renders a structured system message (`{code,args,text}`) via S strings.
String systemText(BuildContext context, Message m) {
  if (m.kind == 'call') {
    // Real core: body {duration_s, missed, video}.
    final s = S.of(context);
    try {
      final j = jsonDecode(m.body);
      if (j is Map) {
        final video = j['video'] == true;
        if (j['missed'] == true) return s(video ? 'call_missed_video' : 'call_missed_voice');
        final d = Duration(seconds: (j['duration_s'] as num?)?.toInt() ?? 0);
        return '${s(video ? 'call_video_done' : 'call_voice_done')} · ${s.duration(d)}';
      }
    } catch (_) {}
    return m.body;
  }
  final st = SystemText.parse(m.body);
  if (st == null) return m.body;
  final s = S.of(context);
  final contacts = context.read<ContactsStore>();
  final me = context.read<SessionStore>().me?.peer;
  String who(String? p) => p == null ? '' : (p == me ? s('you') : contacts.nameOf(p));
  const known = {
    'sys.group_created', 'sys.member_added', 'sys.member_removed', 'sys.member_left', 'sys.group_renamed',
    'sys.role_admin', 'sys.role_member', 'sys.you_removed', 'sys.you_added', 'sys.contact_device_added',
    'sys.call_missed_busy', 'sys.group_restored',
  };
  if (!known.contains(st.code)) return st.text.isNotEmpty ? st.text : m.body;
  if (st.code == 'sys.contact_device_added') {
    // the friend's current name (alias) when we know them, else the name the core stored
    final p = st.args['peer'];
    final c = p == null ? null : contacts[p];
    return s(st.code, {'name': c != null && c.displayName.isNotEmpty ? c.displayName : (st.args['name'] ?? '')});
  }
  if (st.code == 'sys.call_missed_busy') {
    // a direct chat: the caller is the friend in it — shown by their current name
    final p = st.args['peer'] ?? (m.conv.startsWith('d:') ? m.conv.substring(2) : null);
    final c = p == null ? null : contacts[p];
    return s(st.code, {'name': c != null && c.displayName.isNotEmpty ? c.displayName : (st.args['name'] ?? '')});
  }
  return s(st.code, {
    'actor': who(st.args['actor']),
    'peer': who(st.args['peer']),
    'name': st.args['name'] ?? '',
  });
}

// ------------------------------------------------------------ attachments

IconData fileIcon(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.jpg') || n.endsWith('.png') || n.endsWith('.jpeg') || n.endsWith('.webp') || n.endsWith('.gif')) return AppIcons.image;
  if (n.endsWith('.mp4') || n.endsWith('.mov') || n.endsWith('.mkv')) return AppIcons.film;
  if (n.endsWith('.mp3') || n.endsWith('.ogg') || n.endsWith('.wav') || n.endsWith('.m4a')) return AppIcons.music;
  if (n.endsWith('.pdf')) return AppIcons.fileText;
  if (n.endsWith('.zip') || n.endsWith('.rar') || n.endsWith('.7z') || n.endsWith('.tar') || n.endsWith('.gz')) return AppIcons.fileArchive;
  if (n.endsWith('.iso') || n.endsWith('.img')) return AppIcons.diskImage;
  if (n.endsWith('.xlsx') || n.endsWith('.csv') || n.endsWith('.xls')) return AppIcons.spreadsheet;
  if (n.endsWith('.doc') || n.endsWith('.docx') || n.endsWith('.txt') || n.endsWith('.md')) return AppIcons.fileText;
  if (n.endsWith('.fig') || n.endsWith('.sketch') || n.endsWith('.psd')) return AppIcons.draw;
  return AppIcons.file;
}

class _TailPainter extends CustomPainter {
  const _TailPainter({required this.color, required this.mine});
  final Color color;
  final bool mine;
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final p = Path();
    if (mine) {
      p.moveTo(0, 0);
      p.quadraticBezierTo(2, h * 0.8, w, h);
      p.lineTo(0, h);
    } else {
      p.moveTo(w, 0);
      p.quadraticBezierTo(w - 2, h * 0.8, 0, h);
      p.lineTo(w, h);
    }
    p.close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _TailPainter old) => old.color != color || old.mine != mine;
}

// **bold** _italic_ ~~strike~~ `code` ```block``` ||spoiler|| links @mentions
final _fmtRe = RegExp(
  r'```\n?([\s\S]+?)```|`([^`\n]+)`|\*\*(.+?)\*\*|~~(.+?)~~|\|\|(.+?)\|\||(?<![\p{L}\p{N}_])_(.+?)_(?![\p{L}\p{N}_])|(https?://[^\s]+|lumora://[^\s]+)|(@[\p{L}\p{N}_.·]+)',
  unicode: true,
);

/// Message text with rich formatting, tappable links, highlighted
/// @mentions, tap-to-reveal spoilers and a text-only link preview card.
class RichMessageText extends StatelessWidget {
  const RichMessageText({super.key, required this.text, required this.color, required this.mine, this.mentionsMe = false});
  final String text;
  final Color color;
  final bool mine;
  final bool mentionsMe;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(color: color, fontSize: 14.5, height: 1.38);
    final matches = _fmtRe.allMatches(text).toList();
    if (matches.isEmpty) return Text(text, style: base);
    final spans = <InlineSpan>[];
    var last = 0;
    String? firstUrl;
    final codeBg = mine ? Colors.white.withValues(alpha: 0.16) : context.lc.surface2;
    for (final mt in matches) {
      if (mt.start > last) spans.add(TextSpan(text: text.substring(last, mt.start)));
      if (mt.group(1) != null) {
        spans.add(WidgetSpan(
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: codeBg, borderRadius: BorderRadius.circular(8)),
            child: SelectableText(mt.group(1)!.trimRight(), style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: color, height: 1.4)),
          ),
        ));
      } else if (mt.group(2) != null) {
        spans.add(TextSpan(
          text: mt.group(2),
          style: TextStyle(fontFamily: 'monospace', fontSize: 13.5, backgroundColor: codeBg, color: mine ? Colors.white : LC.accent),
        ));
      } else if (mt.group(3) != null) {
        spans.add(TextSpan(text: mt.group(3), style: const TextStyle(fontWeight: FontWeight.w700)));
      } else if (mt.group(4) != null) {
        spans.add(TextSpan(text: mt.group(4), style: const TextStyle(decoration: TextDecoration.lineThrough)));
      } else if (mt.group(5) != null) {
        spans.add(WidgetSpan(alignment: PlaceholderAlignment.baseline, baseline: TextBaseline.alphabetic, child: _Spoiler(text: mt.group(5)!, style: base)));
      } else if (mt.group(6) != null) {
        spans.add(TextSpan(text: mt.group(6), style: const TextStyle(fontStyle: FontStyle.italic)));
      } else if (mt.group(7) != null) {
        final t = mt.group(7)!;
        firstUrl ??= t;
        spans.add(TextSpan(
          text: t,
          style: TextStyle(color: mine ? Colors.white : LC.accent, decoration: TextDecoration.underline, decorationColor: mine ? Colors.white70 : LC.accent),
        ));
      } else {
        final t = mt.group(8)!;
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: (mine ? Colors.white : (mentionsMe ? LC.warning : LC.accent)).withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(t, style: base.copyWith(fontWeight: FontWeight.w600, color: mine ? Colors.white : (mentionsMe ? LC.warning : LC.accent))),
          ),
        ));
      }
      last = mt.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    final rich = Text.rich(TextSpan(style: base, children: spans));
    if (firstUrl == null) return rich;
    final uri = Uri.tryParse(firstUrl);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      GestureDetector(onTap: () => openLink(context, firstUrl!), child: rich),
      if (uri != null && uri.host.isNotEmpty && (uri.isScheme('http') || uri.isScheme('https')))
        GestureDetector(
          onTap: () => openLink(context, firstUrl!),
          child: Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            decoration: BoxDecoration(
              color: mine ? Colors.white.withValues(alpha: 0.12) : LC.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border(left: BorderSide(color: mine ? Colors.white70 : LC.accent, width: 3)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(AppIcons.link, size: 16, color: mine ? Colors.white70 : LC.accent),
              const SizedBox(width: 6),
              Flexible(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(uri.host, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: mine ? Colors.white : context.lc.text)),
                  Text(uri.path.isEmpty ? '/' : uri.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: mine ? Colors.white70 : context.lc.muted)),
                ]),
              ),
            ]),
          ),
        ),
    ]);
  }
}

/// ||spoiler||: hidden behind a shimmer until tapped.
class _Spoiler extends StatefulWidget {
  const _Spoiler({required this.text, required this.style});
  final String text;
  final TextStyle style;
  @override
  State<_Spoiler> createState() => _SpoilerState();
}

class _SpoilerState extends State<_Spoiler> {
  bool _shown = false;
  @override
  Widget build(BuildContext context) {
    final color = widget.style.color ?? context.lc.text;
    final text = Text(widget.text, style: widget.style.copyWith(color: _shown ? color : Colors.transparent));
    return Semantics(
      button: !_shown,
      label: _shown ? null : S.of(context)('spoiler_tap'),
      child: GestureDetector(
        onTap: () => setState(() => _shown = !_shown),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Stack(children: [
            Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: text),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: Motion.normal,
                  opacity: _shown ? 0 : 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: CustomPaint(
                      painter: _SpoilerDots(color: color, seed: widget.text.hashCode),
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(AppIcons.hide, size: 12, color: color.withValues(alpha: 0.9)),
                              const SizedBox(width: 4),
                              Text(S.of(context)('spoiler_tap'),
                                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color.withValues(alpha: 0.9), fontStyle: FontStyle.normal)),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Speckled "noise" that hides spoiler text (deterministic per message).
class _SpoilerDots extends CustomPainter {
  _SpoilerDots({required this.color, required this.seed});
  final Color color;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = color.withValues(alpha: 0.14));
    var x = seed & 0x7fffffff;
    int next() => x = (x * 1103515245 + 12345) & 0x7fffffff;
    final p = Paint();
    final n = (size.width * size.height / 14).clamp(20, 900).toInt();
    for (var i = 0; i < n; i++) {
      final dx = next() % 1000 / 1000 * size.width;
      final dy = next() % 1000 / 1000 * size.height;
      p.color = color.withValues(alpha: 0.18 + (next() % 100) / 260);
      canvas.drawCircle(Offset(dx, dy), 0.6 + (next() % 10) / 12, p);
    }
  }

  @override
  bool shouldRepaint(_SpoilerDots old) => old.color != color || old.seed != seed;
}

/// Poll bubble with live percentages; tap an option to vote / change vote.
class PollView extends StatelessWidget {
  const PollView({super.key, required this.message, required this.myPeer, required this.onVote});
  final Message message;
  final String myPeer;
  final void Function(int) onVote;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final poll = PollData.parse(message);
    if (poll == null) return Text(message.body);
    final votes = message.votes;
    final total = votes.length;
    final mine = message.mine;
    final my = votes[myPeer];
    final fg = mine ? Colors.white : context.lc.text;
    final sub = mine ? Colors.white70 : context.lc.muted;
    return SizedBox(
      width: 280,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(AppIcons.poll, size: 16, color: sub),
          const SizedBox(width: 6),
          Text(s('poll'), style: TextStyle(fontSize: 12, color: sub, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 4),
        Text(poll.question, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 10),
        for (var i = 0; i < poll.options.length; i++)
          Builder(builder: (context) {
            final n = votes.values.where((v) => v == i).length;
            final frac = total == 0 ? 0.0 : n / total;
            final chosen = my == i;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => onVote(i),
                child: Stack(children: [
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: my == null ? 0 : frac),
                        duration: Motion.slow,
                        curve: Motion.curve,
                        builder: (_, v, _) => FractionallySizedBox(
                          widthFactor: v.clamp(0.0, 1.0),
                          child: Container(
                            decoration: BoxDecoration(
                              color: (mine ? Colors.white : LC.primary).withValues(alpha: chosen ? 0.32 : 0.16),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: chosen ? (mine ? Colors.white : LC.primary) : sub.withValues(alpha: 0.35)),
                    ),
                    child: Row(children: [
                      Icon(chosen ? AppIcons.checkCircle : AppIcons.radioOff, size: 18, color: chosen ? (mine ? Colors.white : LC.primary) : sub),
                      const SizedBox(width: 8),
                      Expanded(child: Text(poll.options[i], style: TextStyle(color: fg, fontSize: 14))),
                      if (my != null) Text('${(frac * 100).round()}%', style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 13)),
                    ]),
                  ),
                ]),
              ),
            );
          }),
        Text(total == 0 ? s('no_votes') : s('n_votes', {'n': total}), style: TextStyle(fontSize: 12, color: sub)),
      ]),
    );
  }
}

Future<void> openLink(BuildContext context, String url) async {
  // a Lumora link (invite to a group, add a friend, …) opens right here, with
  // its own preview and button — never a browser round trip
  if (LumoraLink.find(url) != null) return Flows.openDeepLink(context, url);
  final s = S.read(context);
  final ok = await confirm(context, title: s('open_link'), body: url, action: s('open'));
  if (!ok) return;
  final uri = Uri.tryParse(url);
  if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
}

class _GlassMeta extends StatelessWidget {
  const _GlassMeta({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(10)),
        child: child,
      );
}


/// "Seen by" sheet for group messages (reloads when a member's read receipt
/// for this chat arrives while it is open).
Future<void> showSeenBy(BuildContext context, Message m) async {
  final api = context.read<LumoraApi>();
  List<String> peers = const [];
  try {
    peers = await api.seenBy(m.id);
  } catch (_) {}
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    constraints: const BoxConstraints(maxWidth: 480),
    builder: (c) => _SeenBySheet(message: m, initial: peers),
  );
}

class _SeenBySheet extends StatefulWidget {
  const _SeenBySheet({required this.message, required this.initial});
  final Message message;
  final List<String> initial;
  @override
  State<_SeenBySheet> createState() => _SeenBySheetState();
}

class _SeenBySheetState extends State<_SeenBySheet> {
  late List<String> _peers = widget.initial;
  late final ChatStore _chat = context.read<ChatStore>();
  late final LumoraApi _api = context.read<LumoraApi>();
  late final Map<String, int> _reads = Map.of(_chat.groupReads[widget.message.conv] ?? const {});

  @override
  void initState() {
    super.initState();
    _chat.groupReadTick.addListener(_changed);
  }

  @override
  void dispose() {
    _chat.groupReadTick.removeListener(_changed);
    super.dispose();
  }

  /// Only this chat's receipts reload the list.
  void _changed() {
    final now = _chat.groupReads[widget.message.conv] ?? const {};
    if (mapEquals(now, _reads)) return;
    _reads
      ..clear()
      ..addAll(now);
    _api.seenBy(widget.message.id).then((p) {
      if (mounted) setState(() => _peers = p);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final contacts = context.read<ContactsStore>();
    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8), child: Text(s('seen_by_n', {'n': _peers.length}), style: context.tt.titleMedium)),
        if (_peers.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text(s('nobody_seen'), textAlign: TextAlign.center, style: context.tt.bodySmall)),
        for (final p in _peers)
          ListTile(leading: PeerAvatar(peer: p, size: 36, presence: false), title: Text(contacts.nameOf(p))),
        const SizedBox(height: 8),
      ]),
    );
  }
}


/// Inline keyboard under bot messages: callback buttons and URL buttons.
class _InlineButtons extends StatelessWidget {
  const _InlineButtons({required this.message});
  final Message message;
  @override
  Widget build(BuildContext context) {
    final rows = messageButtons(message);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [
                for (final b in row)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Material(
                        color: context.lc.surface2.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(Radii.sm),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(Radii.sm),
                          onTap: () {
                            if (b.url != null && b.url!.isNotEmpty) {
                              openLink(context, b.url!);
                            } else {
                              context.read<LumoraApi>().pressButton(message.id, b.data).catchError((_) {});
                            }
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                              Flexible(child: Text(b.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                              if (b.url != null) ...[const SizedBox(width: 4), Icon(AppIcons.openExternal, size: 12, color: context.lc.muted)],
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
        ]),
      ),
    );
  }
}
