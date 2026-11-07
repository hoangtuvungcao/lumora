import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/app_lock.dart';
import '../../state/moderation.dart';
import '../../state/stores.dart';
import '../../state/community.dart';
import '../lock/app_lock_screen.dart' show LockedChatGate, toggleChatLock;
import 'delete_dialogs.dart';
import 'report_dialogs.dart';
import '../theme.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/common.dart';
import '../flows.dart';
import '../profile/profile_screen.dart';
import '../widgets/typing_dots.dart';
import 'attachments.dart';
import 'chat_info.dart';
import '../settings/blocked_screen.dart';
import '../groups/group_safety.dart';
import '../calls/group_call.dart' show GroupCallBanner;
import '../groups/community/community_gate.dart';
import 'forward_sheet.dart';
import 'wallpaper.dart';
import 'composer.dart';
import 'message_bubble.dart';

class ChatView extends StatefulWidget {
  const ChatView({super.key, required this.conv, this.embedded = false, this.bare = false, this.channelName, this.spaceName});
  final String conv;

  /// Desktop content pane (no route of its own).
  final bool embedded;

  /// Compact panel (remote session chat): no header, pinned bar or info
  /// side panel; the host widget draws its own header.
  final bool bare;

  /// Set when showing a server text channel.
  final String? channelName;
  final String? spaceName;

  @override
  State<ChatView> createState() => _ChatViewState();
}

sealed class _Entry {}

class _MsgEntry extends _Entry {
  _MsgEntry(this.m, this.first, this.last, [this.album]);
  final List<Message>? album;
  final Message m;
  final bool first;
  final bool last;
}

class _DayEntry extends _Entry {
  _DayEntry(this.day);
  final DateTime day;
}

class _HeadEntry extends _Entry {}

class _ChatViewState extends State<ChatView> {
  final _scroll = ScrollController();
  final _composer = ComposerController();
  late final ConvThread _thread;
  bool _showFab = false;
  int _newWhileAway = 0;
  int _lastCount = 0;
  String? _highlight;
  final _highlightKey = GlobalKey();
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;
  bool _dragging = false;
  int _pinIndex = 0;

  void _toggleSelect(Message m) => setState(() => _selected.contains(m.id) ? _selected.remove(m.id) : _selected.add(m.id));

  Future<void> _forward(List<Message> all) async {
    final s = S.read(context);
    final chat = context.read<ChatStore>();
    // self-destructing messages are never forwarded
    final msgs = all.where((m) => !m.selfDestructs && !m.deleted).toList();
    if (msgs.isEmpty) {
      toast(context, s('ttl_no_forward'));
      return;
    }
    final to = await pickForwardTarget(context, title: s('forward_to'));
    if (to == null) return;
    for (final m in msgs) {
      await chat.forward(m, to.conv, hideSender: to.hideSender);
    }
    if (mounted) {
      setState(_selected.clear);
      toast(context, s('forwarded_n', {'n': msgs.length}));
    }
  }

  Future<void> _save(Message m) async {
    final s = S.read(context);
    await context.read<ChatStore>().forward(m, 's:me');
    if (mounted) toast(context, s('saved_to_saved'));
  }

  Future<void> _dropFiles(List<String> paths) => showSendFiles(context, conv: widget.conv, paths: paths, onSent: _toBottom);

  late final NavStore _nav;
  late final ChatStore _chats;
  bool _convSeen = false, _closing = false;

  /// The chat was deleted (here, on another of my devices, or "for both" by the other
  /// side): don't leave the user inside it — close the page / clear the desktop pane.
  void _onChats() {
    if (_chats.convs.containsKey(widget.conv)) {
      _convSeen = true;
      return;
    }
    if (!_convSeen || _closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.embedded && !widget.bare) {
        // Close this chat's own page — not just the top route: its info page
        // (or a dialog) may be on top of it, and they go with it.
        final route = ModalRoute.of(context);
        if (route == null || !route.isActive) return;
        final navigator = Navigator.of(context);
        navigator.popUntil((r) => r == route || r.isFirst);
        if (route.isCurrent && !route.isFirst) navigator.pop();
      } else if (_nav.conv == widget.conv) {
        _nav.openConv(null);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _nav = context.read<NavStore>()..chatShown(widget.conv);
    _chats = context.read<ChatStore>()..addListener(_onChats);
    _convSeen = _chats.convs.containsKey(widget.conv);
    _thread = context.read<ChatStore>().thread(widget.conv);
    _thread.loadInitial().then((_) {
      if (mounted) _lastCount = _thread.messages.length;
    });
    context.read<ChatStore>().loadRetention(widget.conv);
    context.read<ChatStore>().loadPinned(widget.conv);
    if (widget.conv.startsWith('g:')) {
      // removed from it while this app was closed: read-only (the `group`
      // event says so live)
      final gid = widget.conv.substring(2).split('#').first;
      context.read<LumoraApi>().groupInfo(gid).then((g) => _chats.onGroup(gid, member: g.myRole != 'none')).catchError((_) {});
      // who has read what so far (kept across restarts by the core)
      _chats.loadGroupReads(widget.conv);
    }
    context.read<ChatStore>().loadWallpaper(widget.conv);
    _thread.addListener(_onThread);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ChatStore>().markRead(widget.conv);
    });
  }

  @override
  void dispose() {
    // A phone chat page that is closed must stop reading new messages.
    _nav.chatHidden(widget.conv, pushed: !widget.embedded && !widget.bare);
    _chats.removeListener(_onChats);
    _thread.removeListener(_onThread);
    _scroll.dispose();
    _composer.dispose();
    super.dispose();
  }

  void _onThread() {
    final n = _thread.messages.length;
    if (n > _lastCount && _showFab && _thread.messages.isNotEmpty && !_thread.messages.last.mine) {
      setState(() => _newWhileAway += n - _lastCount);
    }
    _lastCount = n;
  }

  void _onScroll() {
    final p = _scroll.position;
    // reverse: true → maxScrollExtent is the top (oldest).
    if (p.pixels > p.maxScrollExtent - 600 && _thread.hasMore && !_thread.loadingOlder) {
      _thread.loadOlder();
    }
    final show = p.pixels > 500;
    if (show != _showFab) {
      setState(() {
        _showFab = show;
        if (!show) _newWhileAway = 0;
      });
    }
  }

  void _toBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0, duration: Motion.slow, curve: Motion.curve);
  }

  void _jumpTo(String id, List<_Entry> entries) {
    final idx = entries.indexWhere((e) => e is _MsgEntry && e.m.id == id);
    if (idx < 0) return;
    setState(() => _highlight = id);
    _scroll.animateTo((idx * 58.0).clamp(0, _scroll.position.maxScrollExtent), duration: Motion.slow, curve: Motion.curve).then((_) {
      final ctx = _highlightKey.currentContext;
      if (ctx != null && ctx.mounted) Scrollable.ensureVisible(ctx, alignment: 0.4, duration: Motion.normal);
    });
    Future<void>.delayed(const Duration(milliseconds: 1600), () {
      if (mounted && _highlight == id) setState(() => _highlight = null);
    });
  }

  static bool _isPhoto(Message m) => m.isFile && !m.deleted && (FileRef.parse(m.body)?.isImage ?? false);

  /// Group members whose messages I hide (Settings › Privacy › Hidden members).
  Set<String> _hidden = const {};

  List<_Entry> _entries(List<Message> all, bool hasMore) {
    // Collapse runs of photos (same author, ≤60 s apart) into albums.
    final msgs = <Message>[];
    final albums = <String, List<Message>>{};
    for (final m in all) {
      if (_hidden.isNotEmpty && !m.mine && _hidden.contains(m.author)) continue;
      if (msgs.isNotEmpty && _isPhoto(m)) {
        final prev = msgs.last;
        if (_isPhoto(prev) && prev.author == m.author && (m.ts - prev.ts).abs() < 60000 && m.replyTo == null) {
          (albums[prev.id] ??= [prev]).add(m);
          continue;
        }
      }
      msgs.add(m);
    }
    final out = <_Entry>[];
    bool sameGroup(Message a, Message b) =>
        a.author == b.author &&
        !a.isSystem &&
        !b.isSystem &&
        (a.ts - b.ts).abs() < 5 * 60000 &&
        DateUtils.isSameDay(DateTime.fromMillisecondsSinceEpoch(a.ts), DateTime.fromMillisecondsSinceEpoch(b.ts));
    for (var i = msgs.length - 1; i >= 0; i--) {
      final m = msgs[i];
      final newer = i + 1 < msgs.length ? msgs[i + 1] : null;
      final older = i > 0 ? msgs[i - 1] : null;
      out.add(_MsgEntry(m, older == null || !sameGroup(m, older), newer == null || !sameGroup(m, newer), albums[m.id]));
      final d = DateTime.fromMillisecondsSinceEpoch(m.ts);
      if (older == null || !DateUtils.isSameDay(d, DateTime.fromMillisecondsSinceEpoch(older.ts))) {
        out.add(_DayEntry(d));
      }
    }
    out.add(_HeadEntry());
    return out;
  }

  @override
  Widget build(BuildContext context) {
    // Locked chat (Locked folder not opened yet): nothing of it is shown.
    if (context.select<AppLock, bool>((l) => l.isChatHidden(widget.conv))) {
      return LockedChatGate(onBack: widget.embedded || widget.bare ? null : () => Navigator.of(context).maybePop());
    }
    final desktop = isDesktop(context);
    final info = !widget.bare && desktop && context.select<NavStore, bool>((n) => n.infoPanel) && widget.channelName == null;
    final s = S.of(context);
    final body = Column(
      children: [
        if (!widget.bare || _selecting)
          AnimatedSwitcher(
            duration: Motion.fast,
            child: _selecting
                ? _SelectionBar(
                    key: const ValueKey('sel'),
                    count: _selected.length,
                    onCancel: () => setState(_selected.clear),
                    onForward: () => _forward(_thread.messages.where((m) => _selected.contains(m.id)).toList()),
                    onCopy: () {
                      final text = _thread.messages.where((m) => _selected.contains(m.id)).map(copyableText).whereType<String>().join('\n');
                      copyText(context, text);
                      setState(_selected.clear);
                    },
                  )
                : _ChatHeader(key: const ValueKey('hdr'), conv: widget.conv, channelName: widget.channelName, embedded: widget.embedded),
          ),
        // a plain group call that didn't ring me: "Join"
        if (!widget.bare && widget.conv.startsWith('g:')) GroupCallBanner(conv: widget.conv),
        if (!widget.bare)
          _PinnedBar(
            conv: widget.conv,
            index: _pinIndex,
            onTap: (m, count) {
              _jumpTo(m.id, _entries(_thread.messages, _thread.hasMore));
              setState(() => _pinIndex = (_pinIndex + 1) % (count == 0 ? 1 : count));
            },
          ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: DropTarget(
                  onDragEntered: (_) => setState(() => _dragging = true),
                  onDragExited: (_) => setState(() => _dragging = false),
                  onDragDone: (d) {
                    setState(() => _dragging = false);
                    _dropFiles(d.files.map((f) => f.path).toList());
                  },
                  child: Selector<ChatStore, String?>(
                    selector: (_, c) => c.wallpaperOf(widget.conv),
                    builder: (context, wp, child) => ChatWallpaper(value: wp, child: child!),
                    child: _buildList(context),
                  ),
                ),
              ),
              if (_dragging)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      margin: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: LC.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(Radii.lg),
                        border: Border.all(color: LC.primary, width: 2),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(AppIcons.upload, size: 48, color: LC.primary),
                            const SizedBox(height: 8),
                            Text(s('drop_to_send'), style: context.tt.titleMedium),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                right: 16,
                bottom: 12,
                child: AnimatedScale(
                  scale: _showFab ? 1 : 0,
                  duration: Motion.normal,
                  curve: Motion.curve,
                  child: Badge(
                    isLabelVisible: _newWhileAway > 0,
                    label: Text('$_newWhileAway'),
                    backgroundColor: LC.primary,
                    child: FloatingActionButton.small(
                      heroTag: null,
                      onPressed: _toBottom,
                      backgroundColor: context.lc.surface2,
                      foregroundColor: context.lc.text,
                      elevation: 2,
                      tooltip: S.of(context)('scroll_bottom'),
                      child: const Icon(AppIcons.chevronsDown),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        _TypingBar(conv: widget.conv),
        if (widget.conv.startsWith('g:')) GroupFloodBanner(conv: widget.conv),
        BridgedHint(conv: widget.conv),
        _RemovedGroupGate(
          conv: widget.conv,
          child: BlockedChatGate(
          conv: widget.conv,
          child: _BotStartOr(
            conv: widget.conv,
            thread: _thread,
            child: CommunityComposerGate(conv: widget.conv, child: Composer(conv: widget.conv, controller: _composer, onSent: _toBottom)),
          ),
        ),
        ),
      ],
    );
    final content = Row(
      children: [
        Expanded(child: body),
        AnimatedSize(
          duration: Motion.normal,
          curve: Motion.curve,
          alignment: Alignment.centerLeft,
          child: info
              ? Container(
                  width: 320,
                  decoration: BoxDecoration(
                    color: context.lc.surface,
                    border: Border(left: BorderSide(color: context.lc.divider)),
                  ),
                  child: ChatInfoPanel(conv: widget.conv, embedded: true),
                )
              : const SizedBox(height: double.infinity),
        ),
      ],
    );
    if (widget.embedded || widget.bare) return Material(color: context.lc.bg, child: content);
    return Scaffold(body: SafeArea(child: content));
  }

  Widget _buildList(BuildContext context) {
    final me = context.select<SessionStore, String>((s) => s.me?.peer ?? '');
    final isGroup = widget.conv.startsWith('g:');
    _hidden = isGroup ? context.select<ModerationStore, Set<String>>((x) => x.hiddenMembers) : const {};
    return ListenableBuilder(
      // (groups: my permissions — pin — can change while the chat is open)
      listenable: isGroup ? Listenable.merge([_thread, CommunityStore.of(context.read<LumoraApi>())]) : _thread,
      builder: (context, _) {
        if (!_thread.loaded) return const _Skeleton();
        final entries = _entries(_thread.messages, _thread.hasMore);
        final actions = BubbleActions(
          onReply: _composer.reply,
          onEdit: _composer.edit,
          onDelete: (m) => askDeleteMessage(context, widget.conv, m, moderator: canModerateMessages(context, widget.conv)),
          onReport: isGroup
              ? (m) => reportGroupContent(context,
                  gid: widget.conv.substring(2).split('#').first, peer: m.author, name: context.read<ContactsStore>().nameOf(m.author), message: m)
              : null,
          onReact: (m, e) => context.read<ChatStore>().toggleReaction(widget.conv, m, e, me),
          onJumpTo: (id) => _jumpTo(id, entries),
          onForward: (m) => _forward([m]),
          onPin: (m) => context.read<ChatStore>().togglePin(widget.conv, m),
          onSave: _save,
          onSelect: _toggleSelect,
          onVote: (m, i) => context.read<ChatStore>().vote(widget.conv, m, i, me),
          selecting: _selecting,
          canPin: !isGroup || convCan(context, widget.conv, Perm.pin),
        );
        return Scrollbar(
          controller: _scroll,
          child: ListView.builder(
            controller: _scroll,
            reverse: true,
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final e = entries[i];
              switch (e) {
                case _DayEntry():
                  return _DaySeparator(day: e.day);
                case _HeadEntry():
                  return _thread.hasMore
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2))),
                        )
                      : _E2EBanner(isGroup: isGroup, channel: widget.channelName);
                case _MsgEntry():
                  final hl = _highlight == e.m.id;
                  return RepaintBoundary(
                    key: hl ? _highlightKey : ValueKey(e.m.id),
                    child: MessageTile(
                      message: e.m,
                      isGroup: isGroup,
                      firstInGroup: e.first,
                      lastInGroup: e.last,
                      actions: actions,
                      myPeer: me,
                      reply: _thread.byId(e.m.replyTo),
                      highlight: hl,
                      selected: _selected.contains(e.m.id),
                      album: e.album,
                    ),
                  );
              }
            },
          ),
        );
      },
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({super.key, required this.conv, required this.embedded, this.channelName});
  final String conv;
  final String? channelName;
  final bool embedded;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) => _build(context, box.maxWidth < 460));

  Widget _build(BuildContext context, bool narrow) {
    final s = S.of(context);
    final c = context.select<ChatStore, Conversation?>((ch) => ch.convs[conv]);
    final peer = conv.startsWith('d:') ? conv.substring(2) : null;
    final contact = peer == null ? null : context.select<ContactsStore, Contact?>((x) => x[peer]);
    final title = channelName != null ? channelName! : (conv == 's:me' ? s('saved_messages') : (c?.title.isNotEmpty == true ? c!.title : (contact?.displayName ?? (peer != null ? context.read<ContactsStore>().nameOf(peer) : (c?.title ?? '')))));
    final desktop = isDesktop(context);

    Widget subtitle;
    if (conv == 's:me') {
      subtitle = Text(s('saved_messages_hint'));
    } else if (channelName != null) {
      subtitle = ChannelTopic(conv: conv, fallback: s('channel_e2e'));
    } else if (contact != null && contact.isBot) {
      final owner = contact.bot!.owner;
      subtitle = Row(
        children: [
          Flexible(
            child: Text(owner != null ? s('bot_of', {'name': context.read<ContactsStore>().nameOf(owner)}) : s('bot_account'),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      );
    } else if (contact != null) {
      subtitle = ValueListenableBuilder<Map<String, Set<String>>>(
        valueListenable: context.read<ChatStore>().typing,
        builder: (context, t, _) {
          if (t[conv]?.isNotEmpty ?? false) {
            return Text(s('typing'), style: const TextStyle(color: LC.accent));
          }
          return Row(
            children: [
              if (contact.online) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(color: LC.success, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              Flexible(child: Text(contact.online ? s('active_now') : s.lastSeen(contact.lastSeen, DateTime.now()), overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              Tooltip(
                message: s('e2e_short'),
                child: const Icon(AppIcons.lock, size: 12, color: LC.success),
              ),
              if (desktop) ...[
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    s('e2e_short'),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: LC.success),
                  ),
                ),
              ],
            ],
          );
        },
      );
    } else {
      subtitle = Row(
        children: [
          const Icon(AppIcons.lock, size: 12, color: LC.success),
          const SizedBox(width: 4),
          // a direct chat with someone not in my contacts is not a group
          Flexible(child: Text(s(peer != null ? 'e2e_short' : 'group_e2e'))),
        ],
      );
    }

    void openInfo() {
      if (desktop) {
        context.read<NavStore>().toggleInfo();
      } else {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: SafeArea(child: ChatInfoPanel(conv: conv)),
            ),
          ),
        );
      }
    }

    return PaneHeader(
      onBack: embedded ? null : () => Navigator.of(context).maybePop(),
      leading: channelName != null
          ? Icon(AppIcons.channel, color: context.lc.muted)
          : (conv == 's:me'
                ? const SavedAvatar(size: 38)
                : (peer != null
                      ? InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => openProfile(context, peer),
                          child: PeerAvatar(peer: peer, fallbackName: title, size: 38),
                        )
                      : GroupAvatar(gid: conv.substring(2).split('#').first, name: title, size: 38))),
      title: InkWell(
        onTap: channelName == null ? (peer != null ? () => openProfile(context, peer) : openInfo) : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
            RetentionBadge(conv: conv),
          ],
        ),
      ),
      subtitle: subtitle,
      actions: [
        if (channelName == null && conv != 's:me' && !narrow) ...[
          ToolButton(icon: AppIcons.call, tooltip: s('voice_call'), onPressed: () => Flows.call(context, conv)),
          ToolButton(icon: AppIcons.video, tooltip: s('video_call'), onPressed: () => Flows.call(context, conv, video: true)),
        ],
        PopupMenuButton<String>(
          tooltip: s('more'),
          icon: Icon(AppIcons.moreVertical, color: context.lc.muted),
          onSelected: (v) async {
            final chat = context.read<ChatStore>();
            switch (v) {
              case 'voice':
                Flows.call(context, conv);
              case 'videocall':
                Flows.call(context, conv, video: true);
              case 'control':
                Flows.requestControl(context, peer!);
              case 'screen':
                Flows.shareScreen(context, conv);
              case 'file':
                Flows.sendFile(context, conv);
              case 'location':
                Flows.shareLocation(context, conv);
              case 'wallpaper':
                showWallpaperPicker(context, conv);
              case 'nickname':
                if (contact == null) return;
                final contacts = context.read<ContactsStore>();
                final a = await promptText(context, title: s('set_nickname'), initial: contact.alias ?? contact.name, action: s('save'));
                if (a != null) contacts.rename(contact.peer, a);
              case 'scheduled':
                showScheduled(context, conv: conv);
              case 'lockchat':
                toggleChatLock(context, conv);
              case 'archive':
                chat.setFlag(conv, 'archived', !(c?.archived ?? false));
              case 'mute':
                pickMute(context, conv);
              case 'clear':
                askClearChat(context, conv, deleteChat: false);
              case 'delchat':
                askClearChat(context, conv, deleteChat: true);
              case 'report':
                if (peer != null) {
                  reportContact(context, peer: peer, name: title, conv: conv);
                } else if (conv.startsWith('g:')) {
                  reportGroup(context, gid: conv.substring(2).split('#').first, name: title);
                }
            }
          },
          itemBuilder: (_) => [
            // Phones: no room for the call buttons in the header — same calls here.
            if (channelName == null && conv != 's:me' && narrow) ...[
              _menuItem('voice', AppIcons.call, s('voice_call')),
              _menuItem('videocall', AppIcons.video, s('video_call')),
              if (peer == null) const PopupMenuDivider(),
            ],
            if (peer != null) ...[
              _menuItem('control', AppIcons.remote, s('request_control')),
              _menuItem('screen', AppIcons.screenShare, s('share_screen')),
              _menuItem('file', AppIcons.attach, s('send_file')),
              _menuItem('location', AppIcons.location, s('location')),
              const PopupMenuDivider(),
            ],
            PopupMenuItem(value: 'wallpaper', child: Text(s('wallpaper'))),
            if (contact != null) PopupMenuItem(value: 'nickname', child: Text(s('set_nickname'))),
            PopupMenuItem(value: 'scheduled', child: Text(s('scheduled_messages'))),
            if (c != null && !c.isSaved) PopupMenuItem(value: 'mute', child: Text(c.muted ? s('unmute') : s('mute'))),
            if (c != null && !c.isSaved) PopupMenuItem(value: 'archive', child: Text(c.archived ? s('unarchive') : s('archive'))),
            if (conv != 's:me' && channelName == null)
              PopupMenuItem(value: 'lockchat', child: Text(context.read<AppLock>().isChatLocked(conv) ? s('chat_unlock') : s('chat_lock'))),
            const PopupMenuDivider(),
            _menuItem('clear', AppIcons.eraser, s('clear_history')),
            _menuItem('delchat', AppIcons.delete, s('delete_chat')),
            if ((peer != null && contact?.status != ContactStatus.blocked) || (conv.startsWith('g:') && channelName == null))
              _menuItem('report', AppIcons.report, peer != null ? s('report') : s('report_group')),
          ],
        ),
        if (channelName == null && conv != 's:me' && desktop && !narrow)
          ToolButton(
            icon: AppIcons.info,
            tooltip: s('conversation_info'),
            active: desktop && context.select<NavStore, bool>((n) => n.infoPanel),
            onPressed: openInfo,
          ),
      ],
    );
  }
}

class _TypingBar extends StatelessWidget {
  const _TypingBar({required this.conv});
  final String conv;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ValueListenableBuilder<Map<String, Set<String>>>(
      valueListenable: context.read<ChatStore>().typing,
      builder: (context, t, _) {
        final who = t[conv];
        final on = who != null && who.isNotEmpty;
        final contacts = context.read<ContactsStore>();
        String label = '';
        if (on) {
          final names = who.map((p) => contacts.nameOf(p).split(' ').last).toList();
          label = names.length == 1 ? s('typing_named', {'name': names.first}) : s('typing_many', {'n': names.length});
        }
        return AnimatedSize(
          duration: Motion.normal,
          curve: Motion.curve,
          child: on
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
                  child: Row(
                    children: [
                      const TypingDots(size: 5),
                      const SizedBox(width: 8),
                      Text(label, style: context.tt.bodySmall?.copyWith(color: LC.accent)),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity),
        );
      },
    );
  }
}

/// Linked device, direct chat with a friend whose Lumora is too old for several
/// devices: a quiet line above the composer — "Gửi qua thiết bị chính của bạn".
class BridgedHint extends StatelessWidget {
  const BridgedHint({super.key, required this.conv});
  final String conv;

  @override
  Widget build(BuildContext context) {
    final peer = conv.startsWith('d:') ? conv.substring(2) : null;
    final c = context.select<ContactsStore, Contact?>((x) => peer == null ? null : x[peer]);
    final on = c != null && c.bridged && !c.isBot;
    final s = S.of(context);
    return AnimatedSize(
      duration: Motion.normal,
      curve: Motion.curve,
      child: !on
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
              child: Center(
                child: Tooltip(
                  message: s('dv_bridged_more', {'name': c.displayName}),
                  triggerMode: TooltipTriggerMode.tap,
                  showDuration: const Duration(seconds: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(AppIcons.devices, size: 14, color: context.lc.muted),
                    const SizedBox(width: 6),
                    Flexible(child: Text(s('dv_bridged_hint'), style: context.tt.bodySmall?.copyWith(fontSize: 12))),
                    const SizedBox(width: 4),
                    Icon(AppIcons.info, size: 13, color: context.lc.muted.withValues(alpha: 0.8)),
                  ]),
                ),
              ),
            ),
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.day});
  final DateTime day;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 6),
      child: Center(child: DateChip(label: s.dayLabel(day, DateTime.now()))),
    );
  }
}

class _E2EBanner extends StatelessWidget {
  const _E2EBanner({required this.isGroup, this.channel});
  final bool isGroup;
  final String? channel;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 440),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: LC.warning.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: LC.warning.withValues(alpha: 0.25)),
          ),
          child: Row(
            children: [
              const Icon(AppIcons.lock, size: 18, color: LC.warning),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  channel != null ? s('e2e_banner_channel', {'name': channel}) : s('e2e_banner'),
                  style: context.tt.bodySmall?.copyWith(color: context.lc.text.withValues(alpha: 0.85), height: 1.45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shimmer-free skeleton bubbles while the first page loads.
class _Skeleton extends StatelessWidget {
  const _Skeleton();
  @override
  Widget build(BuildContext context) {
    final c = context.lc.surface2;
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.all(16),
      itemCount: 8,
      itemBuilder: (_, i) => Align(
        alignment: i.isEven ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 5),
          width: 120.0 + (i * 37) % 160,
          height: 36,
          decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(18)),
        ),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({super.key, required this.count, required this.onCancel, required this.onForward, required this.onCopy});
  final int count;
  final VoidCallback onCancel;
  final VoidCallback onForward;
  final VoidCallback onCopy;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: LC.primary.withValues(alpha: 0.12),
        border: Border(bottom: BorderSide(color: context.lc.divider)),
      ),
      child: Row(
        children: [
          IconButton(onPressed: onCancel, icon: const Icon(AppIcons.close), tooltip: s('cancel')),
          const SizedBox(width: 8),
          Expanded(child: Text(s('n_selected', {'n': count}), style: context.tt.titleMedium)),
          ToolButton(icon: AppIcons.copy, tooltip: s('copy'), onPressed: onCopy),
          ToolButton(icon: AppIcons.forward, tooltip: s('forward'), onPressed: onForward),
        ],
      ),
    );
  }
}

/// Pinned message bar under the header.
class _PinnedBar extends StatelessWidget {
  const _PinnedBar({required this.conv, required this.index, required this.onTap});
  final String conv;
  final int index;
  final void Function(Message m, int count) onTap;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final pins = context.select<ChatStore, List<Message>>((c) => c.pinned[conv] ?? const []);
    return AnimatedSize(
      duration: Motion.normal,
      curve: Motion.curve,
      child: pins.isEmpty
          ? const SizedBox(width: double.infinity)
          : Builder(
              builder: (context) {
                final m = pins[pins.length - 1 - (index % pins.length)];
                final text = m.isPoll
                    ? '📊 ${PollData.parse(m)?.question ?? ''}'
                    : (m.isFile
                          ? '📎 ${FileRef.parse(m.body)?.name ?? ''}'
                          : (m.isSystem ? systemText(context, m) : (m.kind == 'location' ? '📍 Location' : m.body)));
                final token = m.isPoll || m.isFile || (!m.isSystem && m.kind == 'location');
                return Material(
                  color: context.lc.surface,
                  child: InkWell(
                    onTap: () => onTap(m, pins.length),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: context.lc.divider)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 3,
                            height: 32,
                            decoration: BoxDecoration(color: LC.primary, borderRadius: BorderRadius.circular(2)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  pins.length > 1 ? s('pinned_n', {'i': (index % pins.length) + 1, 'n': pins.length}) : s('pinned_message'),
                                  style: context.tt.labelMedium?.copyWith(color: LC.primary, fontWeight: FontWeight.w700),
                                ),
                                if (token)
                                  PreviewLine(text, style: context.tt.bodySmall?.copyWith(color: context.lc.text))
                                else
                                  Text(
                                    text,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.tt.bodySmall?.copyWith(color: context.lc.text),
                                  ),
                              ],
                            ),
                          ),
                          ToolButton(icon: AppIcons.close, size: 18, tooltip: s('unpin_message'), onPressed: () => context.read<ChatStore>().togglePin(conv, m)),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

PopupMenuItem<String> _menuItem(String v, IconData icon, String label) => PopupMenuItem(
  value: v,
  child: Row(children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(label)]),
);

/// New chat with a bot: big "Start" button that sends /start.
class _BotStartOr extends StatelessWidget {
  const _BotStartOr({required this.conv, required this.thread, required this.child});
  final String conv;
  final ConvThread thread;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final peer = conv.startsWith('d:') ? conv.substring(2) : null;
    final bot = peer != null && context.select<ContactsStore, bool>((c) => c[peer]?.isBot ?? false);
    if (!bot) return child;
    return ListenableBuilder(
      listenable: thread,
      builder: (context, _) {
        if (!thread.loaded || thread.messages.isNotEmpty) return child;
        final s = S.of(context);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: GradientButton(
                label: s('bot_start'),
                icon: AppIcons.play,
                expand: true,
                onPressed: () => context.read<ChatStore>().send(conv, '/start'),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A group I was removed from: its history stays readable, the composer goes.
class _RemovedGroupGate extends StatelessWidget {
  const _RemovedGroupGate({required this.conv, required this.child});
  final String conv;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final removed = context.select<ChatStore, bool>((c) => c.removedFrom(conv));
    if (!removed) return child;
    final s = S.of(context);
    return SafeArea(
      top: false,
      child: Container(
        key: const ValueKey('group-removed'),
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: context.lc.surface,
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(color: context.lc.divider),
        ),
        child: Row(children: [
          const IconTile(AppIcons.signOut, color: LC.danger, circle: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(s('group_removed_banner'), maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text(s('group_removed_hint'), maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall),
            ]),
          ),
        ]),
      ),
    );
  }
}
