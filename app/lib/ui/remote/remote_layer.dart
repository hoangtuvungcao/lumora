import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import 'dart:async';

import '../calls/video_view.dart';
import '../theme.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/common.dart';
import '../flows.dart';
import 'keymap.dart';
import 'remote_chat.dart';

/// Global remote-desktop layer: incoming request dialog, viewer screen and
/// the host-side "being controlled" banner.
class RemoteLayer extends StatelessWidget {
  const RemoteLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final hasReq = context.select<RemoteStore, bool>((r) => r.request != null);
    final viewer = context.select<RemoteStore, bool>((r) => r.viewer != null);
    final err = context.select<RemoteStore, String?>((r) => r.errorCode);
    final ended = context.select<RemoteStore, String?>((r) => r.endedPeer);
    final ready = context.select<SessionStore, bool>((s) => s.phase == SessionPhase.ready);
    if (!ready) return const SizedBox.shrink();
    return Positioned.fill(
      child: Stack(children: [
        if (viewer) const Positioned.fill(child: LayerHost(key: ValueKey('viewer'), child: RemoteViewerScreen())),
        if (ended != null && !viewer) Positioned(bottom: 24, left: 0, right: 0, child: Center(child: _AfterSession(peer: ended))),
        if (hasReq) const Positioned.fill(child: LayerHost(key: ValueKey('request'), child: RemoteRequestDialog())),
        if (err != null) const Positioned.fill(child: LayerHost(key: ValueKey('err'), child: CapabilityErrorDialog())),
      ]),
    );
  }
}

// Remembered between rebuilds of the dialog.
bool _trust = false;

class _TrustBox extends StatefulWidget {
  const _TrustBox({required this.onChanged});
  final ValueChanged<bool> onChanged;
  @override
  State<_TrustBox> createState() => _TrustBoxState();
}

class _TrustBoxState extends State<_TrustBox> {
  bool _v = false;
  @override
  void initState() {
    super.initState();
    _trust = false;
  }

  @override
  Widget build(BuildContext context) => CheckboxListTile(
        value: _v,
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(S.of(context)('always_allow_device')),
        onChanged: (v) {
          setState(() => _v = v ?? false);
          widget.onChanged(_v);
        },
      );
}

class RemoteRequestDialog extends StatelessWidget {
  const RemoteRequestDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final r = context.select<RemoteStore, RemoteRequest?>((x) => x.request);
    if (r == null) return const SizedBox.shrink();
    final store = context.read<RemoteStore>();
    final contact = context.read<ContactsStore>()[r.peer];
    final verified = contact?.verified ?? false;
    // The requester picks their own name: a friend is shown under the name
    // *I* saved; a stranger gets a clear warning and their real ID, so
    // nobody can pose as "Mẹ" or "Lumora Support".
    final friend = contact != null && contact.status == ContactStatus.friend;
    final shownName = friend && contact.displayName.isNotEmpty ? contact.displayName : r.name;
    return Material(
      color: Colors.black.withValues(alpha: 0.5),
      child: Center(
        child: Container(
          width: 420,
          margin: const EdgeInsets.all(20),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: context.lc.surface,
            borderRadius: BorderRadius.circular(Radii.xl),
            boxShadow: kNoShadows ? null : const [BoxShadow(color: Colors.black38, blurRadius: 32, offset: Offset(0, 12))],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const IconTile(AppIcons.screenShare, color: LC.warning),
              const SizedBox(width: 14),
              Expanded(child: Text(s('remote_request_title'), style: context.tt.titleMedium)),
            ]),
            const SizedBox(height: 18),
            Row(children: [
              PeerAvatar(peer: r.peer, fallbackName: shownName, size: 44, presence: false),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(friend ? shownName : '"$shownName"', style: context.tt.titleSmall)),
                    if (verified) ...[const SizedBox(width: 4), const Icon(AppIcons.verifiedFill, size: 16, color: LC.accent)],
                  ]),
                  Text(r.viewOnly ? s('wants_view') : s('wants_control'), style: context.tt.bodySmall),
                  if (r.shortId.isNotEmpty) Text(s('remote_req_id', {'id': r.shortId}), style: context.tt.bodySmall?.copyWith(color: context.lc.muted)),
                ]),
              ),
            ]),
            if (!friend) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: LC.danger.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(Radii.md)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(AppIcons.warning, size: 18, color: LC.danger),
                  const SizedBox(width: 8),
                  Expanded(child: Text(s('remote_req_stranger'), style: context.tt.bodySmall?.copyWith(height: 1.45, color: context.lc.text))),
                ]),
              ),
            ],
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: LC.warning.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(Radii.md)),
              child: Text(s('remote_request_warning'), style: context.tt.bodySmall?.copyWith(height: 1.45, color: context.lc.text)),
            ),
            const SizedBox(height: 20),
            _TrustBox(onChanged: (v) => _trust = v),
            const SizedBox(height: 8),
            GradientButton(
              label: s('allow_control_btn'),
              icon: AppIcons.mouse,
              expand: true,
              onPressed: r.viewOnly ? null : () => store.respond(accept: true, control: true, trust: _trust),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => store.respond(accept: true, control: false, trust: _trust),
              icon: const Icon(AppIcons.show, size: 18),
              label: Text(s('view_only_btn')),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => store.respond(accept: false),
              style: TextButton.styleFrom(foregroundColor: LC.danger),
              child: Text(s('deny')),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Wraps the app: while someone controls this device, a red strip sits at
/// the very top (below the status bar) and pushes the app content down so it
/// never covers headers.
class HostBannerFrame extends StatefulWidget {
  const HostBannerFrame({super.key, required this.child});
  final Widget child;

  @override
  State<HostBannerFrame> createState() => _HostBannerFrameState();
}

class _HostBannerFrameState extends State<HostBannerFrame> {
  RemoteChatUnread? _u;
  RemoteChatUnread get _unread => _u ??= RemoteChatUnread(context.read<ChatStore>());
  bool _chat = false;

  @override
  void dispose() {
    _u?.dispose();
    super.dispose();
  }

  void _setChat(bool v) {
    setState(() => _chat = v);
    _unread.open = v;
  }

  @override
  Widget build(BuildContext context) {
    final host = context.select<RemoteStore, RemoteState?>((r) => r.host);
    final ready = context.select<SessionStore, bool>((s) => s.phase == SessionPhase.ready);
    // Keep the child at the same tree depth whether or not the banner shows,
    // so the app below never loses its state.
    final active = host != null && ready;
    if (active) {
      _unread.bind(host.peer);
    } else if (_chat) {
      WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _setChat(false) : null);
    }
    final width = MediaQuery.sizeOf(context).width;
    final panelW = width < 600 ? width : 380.0;
    return Column(children: [
      if (active) HostBanner(unread: _unread, chatOpen: _chat, onChat: () => _setChat(!_chat)),
      Expanded(
        child: Stack(children: [
          Positioned.fill(child: MediaQuery.removePadding(context: context, removeTop: active, child: widget.child)),
          if (active && _chat)
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: panelW,
              child: _PanelFrame(
                radius: panelW < width ? const BorderRadius.only(bottomLeft: Radius.circular(Radii.lg)) : BorderRadius.zero,
                child: LayerHost(
                  key: ValueKey('host-chat-${host.peer}'),
                  child: MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    child: RemoteChatPanel(peer: host.peer, onClose: () => _setChat(false)),
                  ),
                ),
              ),
            ),
        ]),
      ),
    ]);
  }
}

/// Drawer chrome for the session chat (shadow + rounded inner corners).
class _PanelFrame extends StatelessWidget {
  const _PanelFrame({required this.child, this.radius = BorderRadius.zero});
  final Widget child;
  final BorderRadius radius;
  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: kNoShadows ? null : const [BoxShadow(color: Colors.black45, blurRadius: 28, offset: Offset(-4, 0))],
      ),
      position: DecorationPosition.background,
      child: Container(
        foregroundDecoration: BoxDecoration(borderRadius: radius, border: Border.all(color: context.lc.divider)),
        child: ClipRRect(borderRadius: radius, child: child),
      ),
    );
  }
}

class HostBanner extends StatelessWidget {
  const HostBanner({super.key, this.unread, this.onChat, this.chatOpen = false});
  final RemoteChatUnread? unread;
  final VoidCallback? onChat;
  final bool chatOpen;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final host = context.select<RemoteStore, RemoteState?>((r) => r.host);
    if (host == null) {
      final err = context.select<RemoteStore, String?>((r) => r.hostError);
      if (err == null) return const SizedBox.shrink();
      return _HostFailedNotice(message: err == 'capture_failed' ? s('err_capture_failed_host') : err);
    }
    final contact = context.read<ContactsStore>()[host.peer];
    final announced = context.read<RemoteStore>().requestNames[host.peer];
    final name = (contact != null && contact.displayName.isNotEmpty)
        ? contact.displayName
        : ((announced != null && announced.isNotEmpty) ? announced : s('helper'));
    return Material(
      color: LC.danger,
      elevation: 4,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
          child: Row(children: [
            const Icon(AppIcons.screenShare, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(s('being_controlled', {'name': name}),
                  maxLines: 2, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            if (onChat != null && unread != null)
              ChatBadge(
                unread: unread!,
                child: Material(
                  color: Colors.white.withValues(alpha: chatOpen ? 0.32 : 0.18),
                  borderRadius: BorderRadius.circular(Radii.lg),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(Radii.lg),
                    onTap: onChat,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: MediaQuery.sizeOf(context).width < 600 ? 8 : 12, vertical: 6),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(AppIcons.chat, color: Colors.white, size: 18),
                        if (MediaQuery.sizeOf(context).width >= 600) ...[
                          const SizedBox(width: 6),
                          Text(s('chat'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                        ],
                      ]),
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 8),
            Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(Radii.lg),
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.lg),
                onTap: () => context.read<RemoteStore>().end(host.session),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(AppIcons.stop, color: LC.danger, size: 18),
                    const SizedBox(width: 4),
                    Text(s('stop'), style: const TextStyle(color: LC.danger, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The host session ended because it failed (not a red "being controlled"
/// banner any more): the plain reason, dismissible.
class _HostFailedNotice extends StatelessWidget {
  const _HostFailedNotice({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Material(
      color: context.lc.surface,
      elevation: 4,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
          child: Row(children: [
            const Icon(AppIcons.warning, color: LC.warning, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: context.lc.text))),
            IconButton(
              tooltip: s('close'),
              icon: const Icon(AppIcons.close, size: 18),
              onPressed: () => context.read<RemoteStore>().clearHostError(),
            ),
          ]),
        ),
      ),
    );
  }
}

class RemoteViewerScreen extends StatefulWidget {
  const RemoteViewerScreen({super.key});
  @override
  State<RemoteViewerScreen> createState() => _RemoteViewerScreenState();
}

class _RemoteViewerScreenState extends State<RemoteViewerScreen> {
  final _focus = FocusNode(debugLabel: 'remote');
  Size _remoteSize = const Size(1920, 1080);
  bool _toolbar = true;
  bool _focusMode = false;
  int _display = 0;
  String _quality = 'balanced';
  String _scale = 'fit'; // fit | original | stretch
  bool _stats = false;
  bool _chatOpen = false;
  int _frames = 0;
  int _fps = 0;
  Timer? _fpsTimer;
  Timer? _hideTimer;

  RemoteChatUnread? _u;
  RemoteChatUnread get _unread => _u ??= RemoteChatUnread(context.read<ChatStore>());

  void _setChat(bool v) {
    setState(() => _chatOpen = v);
    _unread.open = v;
    // Typing goes back to the remote screen once the chat closes.
    if (!v) _focus.requestFocus();
  }

  void _onFocus() {
    // Copy here, click the remote screen, paste there.
    if (_focus.hasFocus) _store.pushClipboardOnFocus();
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _fps = _frames;
        _frames = 0;
      });
    });
  }

  void _armAutoHide() {
    if (!_focusMode) return;
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _toolbar = false);
    });
  }
  DateTime _lastMove = DateTime(0);
  late final RemoteStore _store = context.read<RemoteStore>();
  late final LumoraApi _api = context.read<LumoraApi>();

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _u?.dispose();
    _fpsTimer?.cancel();
    _hideTimer?.cancel();
    if (_focusMode) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  String? get _session => _store.viewer?.session;
  bool get _canControl => !_store.viewOnly;

  void _send(Map<String, dynamic> ev) {
    final s = _session;
    if (s == null || !_canControl) return;
    _api.remoteInput(s, ev).catchError((_) {});
  }

  /// Image rect inside [box] with aspect-fit.
  Rect _fitRect(Size box) {
    if (_scale == 'stretch') return Offset.zero & box;
    if (_scale == 'original') {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final w = _remoteSize.width / dpr, h = _remoteSize.height / dpr;
      return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
    }
    final r = _remoteSize.width / _remoteSize.height;
    var w = box.width, h = box.width / r;
    if (h > box.height) {
      h = box.height;
      w = h * r;
    }
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  Offset? _norm(Offset local, Size box) {
    final rect = _fitRect(box);
    if (!rect.contains(local)) return null;
    return Offset((local.dx - rect.left) / rect.width, (local.dy - rect.top) / rect.height);
  }

  void _move(Offset local, Size box, {bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(_lastMove).inMilliseconds < 12) return;
    _lastMove = now;
    final p = _norm(local, box);
    if (p != null) _send({'t': 'move', 'x': double.parse(p.dx.toStringAsFixed(5)), 'y': double.parse(p.dy.toStringAsFixed(5))});
  }

  String _btn(int buttons) => buttons & kSecondaryMouseButton != 0 ? 'right' : (buttons & kMiddleMouseButton != 0 ? 'middle' : 'left');
  int _down = 0;

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (!_canControl) return KeyEventResult.ignored;
    final code = kW3cCodes[e.physicalKey];
    if (code != null) {
      if (e is KeyDownEvent || e is KeyRepeatEvent) _send({'t': 'key', 'code': code, 'down': true});
      if (e is KeyUpEvent) _send({'t': 'key', 'code': code, 'down': false});
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent && e.character != null && e.character!.isNotEmpty) {
      _send({'t': 'text', 's': e.character});
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _ctrlAltDel() {
    for (final c in ['ControlLeft', 'AltLeft', 'Delete']) {
      _send({'t': 'key', 'code': c, 'down': true});
    }
    for (final c in ['Delete', 'AltLeft', 'ControlLeft']) {
      _send({'t': 'key', 'code': c, 'down': false});
    }
  }

  /// Picks a file and sends it into the chat with the partner; the chat
  /// panel opens so the progress is visible.
  Future<void> _sendFile() async {
    final st = _store.viewer;
    if (st == null || st.peer.isEmpty) {
      toast(context, S.read(context)('remote_chat_wait'));
      return;
    }
    if (!_chatOpen) _setChat(true);
    await Flows.sendFile(context, 'd:${st.peer}');
  }

  void _toggleFocusMode() {
    setState(() {
      _focusMode = !_focusMode;
      _toolbar = true;
    });
    _armAutoHide();
    SystemChrome.setEnabledSystemUIMode(_focusMode ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = context.select<RemoteStore, RemoteState?>((r) => r.viewer);
    if (st == null) return const SizedBox.shrink();
    _unread.bind(st.peer);
    final name = st.peer.isEmpty ? (_store.viewerPeerName ?? '') : context.read<ContactsStore>().nameOf(st.peer);
    if (st.width > 0 && st.height > 0) _remoteSize = Size(st.width.toDouble(), st.height.toDouble());
    final connecting = st.phase == RemotePhase.connecting;

    final screen = LayoutBuilder(builder: (context, c) {
      final box = Size(c.maxWidth, c.maxHeight);
      return Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Listener(
          onPointerHover: (e) => _move(e.localPosition, box),
          onPointerMove: (e) => _move(e.localPosition, box),
          onPointerDown: (e) {
            _focus.requestFocus();
            _move(e.localPosition, box, force: true);
            _down = e.buttons;
            _send({'t': 'button', 'b': _btn(e.buttons), 'down': true});
          },
          onPointerUp: (e) {
            _send({'t': 'button', 'b': _btn(_down), 'down': false});
            _down = 0;
          },
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              _send({'t': 'wheel', 'dx': e.scrollDelta.dx.sign.toInt(), 'dy': (e.scrollDelta.dy.sign).toInt()});
            }
          },
          child: MouseRegion(
            cursor: _canControl ? SystemMouseCursors.precise : SystemMouseCursors.basic,
            child: connecting
                ? const SizedBox.expand()
                : Builder(builder: (context) {
                    final r = _fitRect(box);
                    return ClipRect(
                      child: Stack(children: [
                        Positioned.fromRect(
                          rect: r,
                          child: VideoView(
                            stream: st.stream,
                            fit: BoxFit.fill,
                            onSize: (sz) => _remoteSize = sz,
                            onFrame: () => _frames++,
                            placeholder: const Center(child: CircularProgressIndicator()),
                          ),
                        ),
                      ]),
                    );
                  }),
          ),
        ),
      );
    });

    return Material(
      color: Colors.black,
      child: Stack(children: [
        Positioned.fill(child: screen),
        if (connecting)
          Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(s('remote_connecting', {'name': name.isEmpty ? '…' : name}), style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 16),
              TextButton(onPressed: () => _store.end(st.session), child: Text(s('cancel'))),
            ]),
          ),
        if (_stats && !connecting)
          Positioned(
            left: 12,
            bottom: 12,
            child: Builder(builder: (context) {
              final rtt = context.select<NetStore, int?>((n) => n.net?.peers.where((p) => p.peer == st.peer).map((p) => p.rttMs).firstOrNull);
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(Radii.sm)),
                child: Text(
                  'FPS $_fps · ${rtt == null ? '–' : '$rtt ms'} · ${_remoteSize.width.round()}×${_remoteSize.height.round()} · ${s('rq_$_quality')}',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
                ),
              );
            }),
          ),
        // In-session chat drawer (below the toolbar on wide screens).
        Builder(builder: (context) {
          final w = MediaQuery.sizeOf(context).width;
          final narrow = w < 600;
          final panelW = narrow ? w : 380.0;
          // Always below the toolbar so "End" stays reachable.
          final top = MediaQuery.paddingOf(context).top + (_toolbar ? 62.0 : 0.0) + (narrow ? 0 : 2);
          return AnimatedPositioned(
            duration: Motion.normal,
            curve: Motion.curve,
            top: top,
            bottom: narrow ? 0 : 12,
            right: _chatOpen ? (narrow ? 0 : 12) : -(panelW + 40),
            width: panelW,
            child: _chatOpen
                ? _PanelFrame(
                    radius: narrow ? const BorderRadius.vertical(top: Radius.circular(Radii.lg)) : BorderRadius.circular(Radii.lg),
                    child: SafeArea(
                      left: false,
                      right: false,
                      top: false,
                      bottom: narrow,
                      child: RemoteChatPanel(peer: st.peer, fallbackName: name, onClose: () => _setChat(false)),
                    ),
                  )
                : const SizedBox.shrink(),
          );
        }),
        // Toolbar.
        AnimatedPositioned(
          duration: Motion.normal,
          curve: Motion.curve,
          top: _toolbar ? MediaQuery.paddingOf(context).top + 10 : -64 - MediaQuery.paddingOf(context).top,
          left: 8,
          right: 8,
          child: Center(child: _toolbarWidget(s, st, name)),
        ),
        if (!_toolbar)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 10,
            child: MouseRegion(
              onEnter: (_) {
                setState(() => _toolbar = true);
                _armAutoHide();
              },
              child: const SizedBox.expand(),
            ),
          ),
      ]),
    );
  }

  /// Manual fallback for copy & paste (automatic sync is the default).
  Future<void> _sendClipboard() async {
    final s = S.read(context);
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final text = d?.text ?? '';
    if (text.isEmpty) {
      if (mounted) toast(context, s('clipboard_empty'));
      return;
    }
    try {
      await _store.sendClipboardNow();
      if (mounted) toast(context, s('clipboard_sent'));
    } catch (_) {
      // Older partner without clipboard support: type it instead.
      _send({'t': 'text', 's': text});
    }
  }

  void _voiceCall(RemoteState st) {
    context.read<CallStore>().start('d:${st.peer}', minimized: true).catchError((_) {});
  }

  Future<void> _power(RemoteState st, String v) async {
    final s = S.read(context);
    if (v != 'lock' && !await confirm(context, title: s('power_$v'), body: s('power_${v}_body'), action: s('power_$v'), danger: true)) return;
    try {
      await _api.remotePower(st.session, v);
    } catch (e) {
      if (mounted) toast(context, e is ApiException ? e.message : s('power_not_allowed'));
    }
  }

  /// Narrow screens: every secondary action lives in one bottom sheet.
  Future<void> _moreSheet(RemoteState st) async {
    final s = S.read(context);
    Widget chips<T>(String title, List<(T, String)> opts, T value, void Function(T) onPick) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: context.tt.labelLarge),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final (v, label) in opts)
                ChoiceChip(label: Text(label), selected: v == value, onSelected: (_) => onPick(v)),
            ]),
          ]),
        );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => StatefulBuilder(builder: (c, setSheet) {
        void pick(VoidCallback f) {
          setState(f);
          setSheet(() {});
        }

        Widget item(IconData icon, String label, VoidCallback? onTap) => ListTile(
              leading: Icon(icon),
              title: Text(label),
              enabled: onTap != null,
              onTap: onTap == null
                  ? null
                  : () {
                      Navigator.pop(c);
                      onTap();
                    },
            );
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.8),
            child: ListView(shrinkWrap: true, children: [
              chips(s('displays'), [for (var i = 0; i < 2; i++) (i, s('display_n', {'n': i + 1}))], _display, (v) {
                pick(() => _display = v);
                _store.setDisplay(v);
              }),
              chips(s('quality'), [for (final q in ['smooth', 'balanced', 'sharp', 'saver']) (q, s('rq_$q'))], _quality, (v) {
                pick(() => _quality = v);
                _api.remoteQuality(st.session, v).catchError((_) {});
              }),
              chips(s('scale_mode'), [for (final m in ['fit', 'original', 'stretch']) (m, s('scale_$m'))], _scale, (v) => pick(() => _scale = v)),
              const Divider(height: 24),
              ListTile(
                leading: const Icon(AppIcons.chat),
                title: Text(s('chat')),
                trailing: _unread.count > 0 ? CountBadge(_unread.count) : null,
                onTap: () {
                  Navigator.pop(c);
                  _setChat(!_chatOpen);
                },
              ),
              item(AppIcons.fileUpload, s('send_file'), _sendFile),
              item(AppIcons.paste, s('sync_clipboard'), _sendClipboard),
              item(AppIcons.call, s('voice_call'), st.peer.isEmpty ? null : () => _voiceCall(st)),
              item(AppIcons.command, 'Ctrl+Alt+Del', _canControl ? _ctrlAltDel : null),
              SwitchListTile(
                secondary: const Icon(AppIcons.activity),
                title: Text(s('show_stats')),
                value: _stats,
                onChanged: (v) => pick(() => _stats = v),
              ),
              const Divider(height: 16),
              item(AppIcons.lock, s('power_lock'), _canControl ? () => _power(st, 'lock') : null),
              item(AppIcons.reset, s('power_restart'), _canControl ? () => _power(st, 'restart') : null),
              item(AppIcons.signOut, s('power_logout'), _canControl ? () => _power(st, 'logout') : null),
              const SizedBox(height: 8),
            ]),
          ),
        );
      }),
    );
  }

  Widget _toolbarWidget(S s, RemoteState st, String name) {
    final sep = Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 4), color: Colors.white24);
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 600;
    final tiny = width <= 400;
    final Widget end = tiny
        ? Tooltip(
            message: s('end'),
            child: IconButton.filled(
              tooltip: S.of(context)('stop'),
              onPressed: () => _store.end(st.session),
              icon: const Icon(AppIcons.close, size: 18),
              style: IconButton.styleFrom(backgroundColor: LC.danger, foregroundColor: Colors.white, minimumSize: const Size(44, 34), fixedSize: const Size(44, 34)),
            ),
          )
        : FilledButton.icon(
            onPressed: () => _store.end(st.session),
            icon: const Icon(AppIcons.close, size: 18),
            label: Text(s('end')),
            style: FilledButton.styleFrom(backgroundColor: LC.danger, minimumSize: const Size(0, 34), padding: const EdgeInsets.symmetric(horizontal: 12)),
          );
    final title = [
      const SizedBox(width: 6),
      // On narrow screens the "synced" signal is a tiny badge on the lock.
      compact
          ? Stack(clipBehavior: Clip.none, children: [
              const Icon(AppIcons.lock, size: 14, color: LC.success),
              Positioned(right: -7, top: -7, child: ClipboardSyncedChip(pulse: _store.clipboardPulse, compact: true)),
            ])
          : const Icon(AppIcons.lock, size: 14, color: LC.success),
      const SizedBox(width: 6),
      Flexible(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: compact ? 140 : 160),
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        ),
      ),
      if (_store.viewOnly && !compact) ...[const SizedBox(width: 8), Pill(s('view_only'), color: LC.warning)],
      const SizedBox(width: 4),
    ];
    final Widget row;
    if (compact) {
      row = Row(mainAxisSize: MainAxisSize.min, children: [
        ...title,
        sep,
        ChatBadge(unread: _unread, child: _tb(AppIcons.more, s('more'), () => _moreSheet(st), dense: tiny)),
        _tb(_focusMode ? AppIcons.exitFullscreen : AppIcons.fullscreen, s('fullscreen'), _toggleFocusMode, dense: tiny),
        const SizedBox(width: 4),
        end,
      ]);
    } else {
      row = Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              ...title.map((w) => w is Flexible ? w.child : w),
              ClipboardSyncedChip(pulse: _store.clipboardPulse),
              sep,
              PopupMenuButton<int>(
                tooltip: s('displays'),
                icon: const Icon(AppIcons.remote, size: 20, color: Colors.white),
                onSelected: (v) {
                  setState(() => _display = v);
                  _store.setDisplay(v);
                },
                itemBuilder: (_) => [
                  for (var i = 0; i < 2; i++)
                    CheckedPopupMenuItem(value: i, checked: _display == i, child: Text(s('display_n', {'n': i + 1}))),
                ],
              ),
              PopupMenuButton<String>(
                tooltip: s('quality'),
                icon: const Icon(AppIcons.quality, size: 20, color: Colors.white),
                onSelected: (v) {
                  setState(() => _quality = v);
                  _api.remoteQuality(st.session, v).catchError((_) {});
                },
                itemBuilder: (_) => [
                  for (final q in ['smooth', 'balanced', 'sharp', 'saver'])
                    CheckedPopupMenuItem(value: q, checked: _quality == q, child: Text(s('rq_$q'))),
                ],
              ),
              PopupMenuButton<String>(
                tooltip: s('scale_mode'),
                icon: const Icon(AppIcons.aspectRatio, size: 20, color: Colors.white),
                onSelected: (v) => setState(() => _scale = v),
                itemBuilder: (_) => [
                  for (final m in ['fit', 'original', 'stretch'])
                    CheckedPopupMenuItem(value: m, checked: _scale == m, child: Text(s('scale_$m'))),
                ],
              ),
              ChatBadge(
                unread: _unread,
                child: _tb(AppIcons.chat, s('chat'), () => _setChat(!_chatOpen), active: _chatOpen),
              ),
              _tb(AppIcons.fileUpload, s('send_file'), _sendFile),
              _tb(AppIcons.call, s('voice_call'), st.peer.isEmpty ? null : () => _voiceCall(st)),
              _tb(AppIcons.command, 'Ctrl+Alt+Del', _canControl ? _ctrlAltDel : null),
              PopupMenuButton<String>(
                tooltip: s('more'),
                icon: const Icon(AppIcons.more, size: 20, color: Colors.white),
                onSelected: (v) {
                  if (v == 'stats') {
                    setState(() => _stats = !_stats);
                    return;
                  }
                  if (v == 'clip') {
                    _sendClipboard();
                    return;
                  }
                  _power(st, v);
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'clip', child: Row(children: [const Icon(AppIcons.paste, size: 16), const SizedBox(width: 10), Text(s('sync_clipboard'))])),
                  CheckedPopupMenuItem(value: 'stats', checked: _stats, child: Text(s('show_stats'))),
                  const PopupMenuDivider(),
                  PopupMenuItem(enabled: _canControl, value: 'lock', child: Row(children: [const Icon(AppIcons.lock, size: 16), const SizedBox(width: 10), Text(s('power_lock'))])),
                  PopupMenuItem(enabled: _canControl, value: 'restart', child: Row(children: [const Icon(AppIcons.reset, size: 16), const SizedBox(width: 10), Text(s('power_restart'))])),
                  PopupMenuItem(enabled: _canControl, value: 'logout', child: Row(children: [const Icon(AppIcons.signOut, size: 16), const SizedBox(width: 10), Text(s('power_logout'))])),
                ],
              ),
              sep,
              _tb(_focusMode ? AppIcons.exitFullscreen : AppIcons.fullscreen, s('fullscreen'), _toggleFocusMode),
            ]),
          ),
        ),
        const SizedBox(width: 4),
        end,
      ]);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xEE171A2E),
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: Colors.white12),
        boxShadow: kNoShadows ? null : const [BoxShadow(color: Colors.black54, blurRadius: 16)],
      ),
      child: IconTheme(data: const IconThemeData(color: Colors.white), child: row),
    );
  }

  Widget _tb(IconData i, String tip, VoidCallback? onTap, {bool active = false, bool dense = false}) => IconButton(
        tooltip: tip,
        onPressed: onTap,
        icon: Icon(i, size: 20),
        color: Colors.white,
        disabledColor: Colors.white30,
        visualDensity: dense ? VisualDensity.compact : null,
        style: active ? IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.16)) : null,
      );
}


/// Friendly dialog for input_unavailable / capture_unavailable / mic_unavailable.
class CapabilityErrorDialog extends StatelessWidget {
  const CapabilityErrorDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final code = context.select<RemoteStore, String?>((r) => r.errorCode);
    if (code == null) return const SizedBox.shrink();
    final store = context.read<RemoteStore>();
    final icon = switch (code) {
      'mic_unavailable' => AppIcons.micOff,
      'capture_unavailable' => AppIcons.captureOff,
      _ => AppIcons.mouse,
    };
    return Material(
      color: Colors.black.withValues(alpha: 0.5),
      child: Center(
        child: Container(
          width: 420,
          margin: const EdgeInsets.all(20),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(color: context.lc.surface, borderRadius: BorderRadius.circular(Radii.xl)),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: IconTile(icon, color: LC.warning, size: IconTileSize.lg, circle: true)),
            const SizedBox(height: 16),
            Text(s('err_$code'), style: context.tt.titleMedium),
            const SizedBox(height: 8),
            Text(s('err_${code}_body'), style: context.tt.bodyMedium?.copyWith(color: context.lc.muted, height: 1.5)),
            const SizedBox(height: 20),
            GradientButton(
              label: s('open_diagnostics'),
              icon: AppIcons.shieldPlus,
              expand: true,
              onPressed: () {
                store.clearErrorCode();
                final nav = context.read<NavStore>();
                nav.go(Section.network);
              },
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: store.clearErrorCode, child: Text(s('close'))),
          ]),
        ),
      ),
    );
  }
}


/// Suggestions after a remote session ends: send a file or continue chatting.
class _AfterSession extends StatelessWidget {
  const _AfterSession({required this.peer});
  final String peer;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final store = context.read<RemoteStore>();
    final name = context.read<ContactsStore>().nameOf(peer);
    return Material(
      color: context.lc.surface,
      elevation: 8,
      borderRadius: BorderRadius.circular(Radii.lg),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(AppIcons.captureOn, color: LC.success, size: 20),
          const SizedBox(width: 10),
          Text(s('session_ended_with', {'name': name}), style: context.tt.bodyMedium),
          const SizedBox(width: 12),
          TextButton.icon(
            onPressed: () {
              store.clearEnded();
              Flows.sendFile(context, 'd:$peer');
            },
            icon: const Icon(AppIcons.attach, size: 16),
            label: Text(s('send_file')),
          ),
          TextButton.icon(
            onPressed: () {
              store.clearEnded();
              context.read<NavStore>().openConv('d:$peer');
            },
            icon: const Icon(AppIcons.chat, size: 16),
            label: Text(s('chat')),
          ),
          IconButton(onPressed: store.clearEnded, icon: const Icon(AppIcons.close, size: 16), tooltip: s('close')),
        ]),
      ),
    );
  }
}
