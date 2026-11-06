import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';
import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/outgoing.dart';
import '../../l10n/strings.dart';
import '../../state/settings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'attachments.dart';
import 'stickers.dart';
import 'rich_bubbles.dart';
import 'message_bubble.dart' show canEditMessage;
import 'task_sheets.dart';
import 'emoji_picker.dart';
import 'forward_sheet.dart';
import '../widgets/peer_avatar.dart';
import '../../core/text_fold.dart';

/// Makes the voice-note recorder (tests swap in a fake).
@visibleForTesting
AudioRecorder Function() composerRecorderFactory = AudioRecorder.new;

/// A random UUID v4 (idempotency key of one message being sent).
String newClientId() {
  final r = math.Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Composer state shared with the chat view (reply / edit targets).
class ComposerController extends ChangeNotifier {
  Message? replyTo;
  Message? editing;
  final text = TextEditingController();
  final focus = FocusNode();

  /// Idempotency key of the send that failed / timed out, kept with its
  /// text: sending that same text again reuses it, so the core returns the
  /// first message instead of a duplicate. Any change of text starts afresh.
  String? _retryClientId;
  String? _retryText;

  /// The `client_id` for sending [text] now (reused on a retry of the same text).
  String clientIdFor(String text) {
    if (_retryClientId != null && _retryText == text) return _retryClientId!;
    _retryText = null;
    _retryClientId = null;
    return newClientId();
  }

  /// Remembers [id] for a retry of [text] (the send failed or timed out).
  void keepForRetry(String text, String id) {
    _retryText = text;
    _retryClientId = id;
  }

  void sendSucceeded() {
    _retryText = null;
    _retryClientId = null;
  }

  void reply(Message m) {
    editing = null;
    replyTo = m;
    notifyListeners();
    focus.requestFocus();
  }

  /// What was being typed before an edit started; put back when the edit
  /// ends (sent or cancelled) so a draft is never lost.
  TextEditingValue? _draftBeforeEdit;

  void edit(Message m) {
    if (!canEditMessage(m)) return;
    replyTo = null;
    // Keep the draft (only the first time: editing A then B keeps the real draft).
    _draftBeforeEdit ??= text.value;
    editing = m;
    text.text = m.body;
    text.selection = TextSelection.collapsed(offset: text.text.length);
    notifyListeners();
    focus.requestFocus();
  }

  /// Leaves reply/edit mode; an edit puts the earlier draft back.
  void clearTarget() {
    if (editing != null) {
      text.value = _draftBeforeEdit ?? TextEditingValue.empty;
      _draftBeforeEdit = null;
    }
    replyTo = null;
    editing = null;
    notifyListeners();
  }

  @override
  void dispose() {
    text.dispose();
    focus.dispose();
    super.dispose();
  }
}

class Composer extends StatefulWidget {
  const Composer({super.key, required this.conv, required this.controller, required this.onSent});
  final String conv;
  final ComposerController controller;
  final VoidCallback onSent;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> with WidgetsBindingObserver {
  bool _emoji = false;
  bool _hasText = false;
  Timer? _typingOff;
  DateTime _lastTypingSent = DateTime(0);
  late final ChatStore _chat = context.read<ChatStore>();

  ComposerController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    final draft = _chat.drafts[widget.conv];
    if (draft != null && draft.isNotEmpty) c.text.text = draft;
    _hasText = c.text.text.trim().isNotEmpty;
    c.text.addListener(_onText);
    c.addListener(_rebuild);
    c.focus.onKeyEvent = _onKey;
    WidgetsBinding.instance.addObserver(this);
  }

  /// The app left the screen while recording: stop the microphone right
  /// away (never record in the background) and drop the clip.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden || state == AppLifecycleState.detached) {
      if (_recording || _recStarting) _stopRecording(send: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recTimer?.cancel();
    _ampSub?.cancel();
    // Leaving the chat (back, another chat) always stops the microphone.
    final rec = _rec, path = _recPath;
    _rec = null;
    if (rec != null) {
      unawaited(() async {
        try {
          await rec.stop();
        } catch (_) {}
        rec.dispose();
        await discardOutgoing(path);
      }());
    }
    c.text.removeListener(_onText);
    c.removeListener(_rebuild);
    _typingOff?.cancel();
    // Leaving while editing keeps the draft that was there before the edit.
    _chat.drafts[widget.conv] = c.editing == null ? c.text.text : (c._draftBeforeEdit?.text ?? '');
    super.dispose();
  }

  void _rebuild() => setState(() {});

  // ------------------------------------------------------------ voice
  final _micKey = GlobalKey(debugLabel: 'mic');
  AudioRecorder? _rec;
  bool _recording = false;
  bool _recLocked = false;
  bool _recCancel = false;
  Duration _recElapsed = Duration.zero;
  DateTime? _recStart;
  Timer? _recTimer;
  final List<double> _amps = [];
  StreamSubscription<Amplitude>? _ampSub;
  String? _recPath;

  /// A start is in progress (permission prompt, opening the microphone).
  bool _recStarting = false;

  /// The finger is still on the mic button (phones: hold to record).
  bool _holding = false;

  Future<void> _startRecording({bool hold = false}) async {
    if (_recording || _recStarting) return; // no double start
    _recStarting = true;
    final remote = context.read<RemoteStore>();
    AudioRecorder? rec;
    try {
      rec = composerRecorderFactory();
      if (!await rec.hasPermission()) {
        remote.onErrorCode('mic_unavailable');
        rec.dispose();
        return;
      }
      // App storage, not temp: the core serves the sent note from this path.
      final path = await outgoingPath('voice', 'm4a');
      if (!mounted) {
        rec.dispose();
        return;
      }
      _recPath = path;
      await rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 48000, numChannels: 1), path: path);
      if (!mounted || (hold && !_holding)) {
        // Released (or left) before the microphone opened: nothing to keep.
        _rec = rec;
        await _stopRecording(send: false);
        return;
      }
      _rec = rec;
      _amps.clear();
      _ampSub = rec.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((a) => _amps.add(a.current));
      HapticFeedback.mediumImpact();
      setState(() {
        _recording = true;
        _recLocked = false;
        _recCancel = false;
        _recStart = DateTime.now();
        _recElapsed = Duration.zero;
      });
      _recTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted) setState(() => _recElapsed = DateTime.now().difference(_recStart!));
      });
    } catch (_) {
      rec?.dispose();
      remote.onErrorCode('mic_unavailable');
    } finally {
      _recStarting = false;
    }
  }

  /// 32 amplitudes 0..255 from dBFS samples.
  List<int> _wave() {
    if (_amps.isEmpty) return List.filled(32, 40);
    final out = <int>[];
    for (var i = 0; i < 32; i++) {
      final a = _amps[(i * _amps.length / 32).floor().clamp(0, _amps.length - 1)];
      out.add(((a + 60).clamp(0, 60) / 60 * 255).round());
    }
    return out;
  }

  Future<void> _stopRecording({required bool send}) async {
    final rec = _rec;
    final api = context.read<LumoraApi>();
    _recTimer?.cancel();
    await _ampSub?.cancel();
    final dur = _recStart == null ? Duration.zero : DateTime.now().difference(_recStart!);
    _recStart = null;
    _holding = false;
    if (mounted) setState(() => _recording = false);
    _rec = null;
    final planned = _recPath;
    _recPath = null;
    if (rec == null) return;
    String? path;
    try {
      path = await rec.stop();
    } catch (_) {}
    rec.dispose();
    path ??= planned;
    if (!send || path == null || dur < const Duration(milliseconds: 600)) {
      await discardOutgoing(path); // cancelled / too short: don't leave it behind
      return;
    }
    try {
      final m = await api.sendVoice(widget.conv, path, dur.inMilliseconds, _wave());
      _chat.thread(widget.conv).add(m);
      widget.onSent();
    } catch (e) {
      await discardOutgoing(path);
      if (mounted) toastError(context, e, prefix: '${S.read(context)('send_failed')}: ');
    }
  }

  // ------------------------------------------------------------ mentions
  List<GroupMember> _members = const [];
  List<String> _groupBots = const [];

  /// Bot commands available here: the bot's own commands in a 1-1 chat,
  /// `group_commands` of the group's bots in groups.
  List<(String, String, String?)> _botCommands() {
    final contacts = context.read<ContactsStore>();
    final out = <(String, String, String?)>[];
    if (widget.conv.startsWith('d:')) {
      final b = contacts[widget.conv.substring(2)]?.bot;
      for (final c in b?.commands ?? const <BotCommand>[]) {
        out.add((c.command, c.description, null));
      }
    } else {
      for (final p in _groupBots) {
        final b = contacts[p]?.bot;
        for (final c in b?.groupCommands ?? const <BotCommand>[]) {
          out.add((c.command, c.description, contacts.nameOf(p)));
        }
      }
    }
    final q = c.text.text.substring(1).toLowerCase();
    return out.where((x) => x.$1.toLowerCase().startsWith(q)).take(8).toList();
  }

  bool get _showCommands => c.text.text.startsWith('/') && !c.text.text.contains(' ') && _botCommands().isNotEmpty;
  final Map<String, String> _mentionNames = {}; // display name -> peer
  String? _mentionQuery;

  bool get _isGroup => widget.conv.startsWith('g:');

  Future<void> _loadMembers() async {
    if (!_isGroup || _members.isNotEmpty) return;
    try {
      final gid = widget.conv.substring(2).split('#').first;
      final g = await context.read<LumoraApi>().groupInfo(gid);
      if (mounted) {
        setState(() {
          _members = g.members;
          _groupBots = g.bots.map((b) => b.$1).toList();
        });
      }
    } catch (_) {}
  }

  static final _mentionRe = RegExp(r'@([\p{L}\p{N}_]*)$', unicode: true);

  void _updateMention() {
    if (!_isGroup) return;
    final sel = c.text.selection;
    final upto = sel.isValid ? c.text.text.substring(0, sel.baseOffset.clamp(0, c.text.text.length)) : c.text.text;
    final m = _mentionRe.firstMatch(upto);
    final q = m?.group(1);
    if (q != _mentionQuery) {
      setState(() => _mentionQuery = q);
      if (q != null) _loadMembers();
    }
  }

  void _insertMention(String name, String? peer) {
    final t = c.text;
    final sel = t.selection.isValid ? t.selection.baseOffset : t.text.length;
    final upto = t.text.substring(0, sel);
    final m = _mentionRe.firstMatch(upto);
    if (m == null) return;
    final insert = '@$name ';
    final next = t.text.replaceRange(m.start, sel, insert);
    t.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: m.start + insert.length),
    );
    _mentionNames[name] = peer ?? '*';
    setState(() => _mentionQuery = null);
    c.focus.requestFocus();
  }

  bool _selActive = false;

  /// Wraps the selection with a formatting marker (desktop toolbar).
  void _wrap(String l, [String? r]) {
    final t = c.text;
    final sel = t.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    final inner = t.text.substring(sel.start, sel.end);
    final repl = '$l$inner${r ?? l}';
    t.value = TextEditingValue(
      text: t.text.replaceRange(sel.start, sel.end, repl),
      selection: TextSelection(baseOffset: sel.start, extentOffset: sel.start + repl.length),
    );
    c.focus.requestFocus();
  }

  void _onText() {
    if (c.text.text.startsWith('/')) {
      _loadMembers();
      setState(() {});
    }
    final sa = c.text.selection.isValid && !c.text.selection.isCollapsed;
    if (sa != _selActive) setState(() => _selActive = sa);
    _updateMention();
    final has = c.text.text.trim().isNotEmpty;
    if (has != _hasText) setState(() => _hasText = has);
    // The saved draft is never the message being edited.
    _chat.drafts[widget.conv] = c.editing == null ? c.text.text : (c._draftBeforeEdit?.text ?? '');
    if (!context.read<Settings>().typingIndicators || !has) return;
    final api = context.read<LumoraApi>();
    final now = DateTime.now();
    if (now.difference(_lastTypingSent) > const Duration(seconds: 3)) {
      _lastTypingSent = now;
      api.typing(widget.conv, true).catchError((_) {});
    }
    _typingOff?.cancel();
    _typingOff = Timer(const Duration(seconds: 4), () {
      _lastTypingSent = DateTime(0);
      api.typing(widget.conv, false).catchError((_) {});
    });
  }

  /// Desktop: Enter sends, Shift+Enter inserts a newline. Esc cancels reply/edit.
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (_mentionQuery != null && (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.tab)) {
      final opts = _mentionOptions();
      if (opts.isNotEmpty) {
        _insertMention(opts.first.$1, opts.first.$2);
        return KeyEventResult.handled;
      }
    }
    if (e.logicalKey == LogicalKeyboardKey.escape && _mentionQuery != null) {
      setState(() => _mentionQuery = null);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape && (c.replyTo != null || c.editing != null)) {
      c.clearTarget();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.keyV && HardwareKeyboard.instance.isControlPressed) {
      clipboardFilePaths().then((paths) {
        if (paths.isNotEmpty && mounted) showSendFiles(context, conv: widget.conv, paths: paths, onSent: widget.onSent);
      });
    }
    final enter = e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (enter && isDesktop(context) && !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _send({bool silent = false}) async {
    final text = c.text.text.trim();
    if (text.isEmpty) return;
    final editing = c.editing;
    final reply = c.replyTo;
    final typed = c.text.value;
    final mentionNames = Map<String, String>.of(_mentionNames);
    // Same text as a send that failed / timed out → same id: the core then
    // returns that first message instead of sending a second copy.
    final clientId = editing == null ? c.clientIdFor(text) : null;
    c.text.clear();
    c.clearTarget();
    // Keep typing after sending (desktop: Enter or the send button).
    if (isDesktop(context)) c.focus.requestFocus();
    _typingOff?.cancel();
    _lastTypingSent = DateTime(0);
    try {
      if (editing != null) {
        await _chat.edit(widget.conv, editing.id, text);
      } else {
        final peers = <String>[];
        var all = false;
        _mentionNames.forEach((name, peer) {
          if (!text.contains('@$name')) return;
          peer == '*' ? all = true : peers.add(peer);
        });
        _mentionNames.clear();
        await _chat.send(widget.conv, text, replyTo: reply?.id, mentions: peers, mentionAll: all, silent: silent, clientId: clientId);
        c.sendSucceeded();
        widget.onSent();
      }
    } catch (e) {
      if (clientId != null) c.keepForRetry(text, clientId);
      // Nothing typed is lost: put the text (and the reply/edit target) back
      // unless the user has already started something new.
      if (editing != null) {
        if (c.editing == null) {
          c.edit(editing);
          c.text.value = typed;
        }
      } else if (c.text.text.trim().isEmpty && c.editing == null) {
        c.text.value = typed;
        _mentionNames.addAll(mentionNames);
        if (reply != null && c.replyTo == null) c.reply(reply);
      }
      if (!mounted) return;
      // A timed-out send may still go out; sending it again is safe (same
      // client id: never a second copy).
      final timedOut = e is ApiException && e.message == 'timeout';
      if (timedOut) {
        toast(context, S.read(context)('send_maybe_sent'));
      } else {
        toastError(context, e, prefix: '${S.read(context)('send_failed')}: ');
      }
    }
  }

  List<(String, String?)> _mentionOptions() {
    final q = foldText(_mentionQuery ?? '');
    final me = context.read<SessionStore>().me?.peer;
    final contacts = context.read<ContactsStore>();
    final out = <(String, String?)>[];
    if ('all'.startsWith(q) || 'moi'.startsWith(q)) out.add(('all', null));
    for (final m in _members) {
      if (m.peer == me) continue;
      final name = contacts[m.peer]?.displayName ?? m.name;
      if (q.isEmpty || foldText(name).contains(q)) out.add((name, m.peer));
    }
    return out.take(6).toList();
  }

  Future<void> _attachMenu() async {
    final s = S.read(context);
    final items = <(String, IconData, String, List<Color>)>[
      ('media', AppIcons.gallery, s('att_media'), const [Color(0xFF6C5CE7), Color(0xFFA855F7)]),
      ('file', AppIcons.fileText, s('att_file'), const [Color(0xFF3B82F6), Color(0xFF00C2D1)]),
      ('location', AppIcons.location, s('location'), const [Color(0xFF22C55E), Color(0xFF14B8A6)]),
      ('contact', AppIcons.contactCard, s('share_contact'), const [Color(0xFFF59E0B), Color(0xFFF97316)]),
      ('poll', AppIcons.poll, s('poll'), const [Color(0xFFEC4899), Color(0xFFF43F5E)]),
      ('checklist', AppIcons.tasks, s('checklist'), const [Color(0xFF22C55E), Color(0xFF14B8A6)]),
      ('reminder', AppIcons.reminder, s('reminder'), const [Color(0xFFF59E0B), Color(0xFFF97316)]),
      ('voice', AppIcons.mic, s('att_voice'), const [Color(0xFFEF4444), Color(0xFFF97316)]),
      ('camera', AppIcons.camera, s('att_camera'), const [Color(0xFF0EA5E9), Color(0xFF6366F1)]),
      ('meme', AppIcons.meme, s('att_meme'), const [Color(0xFFF43F5E), Color(0xFFF59E0B)]),
      ('scheduled', AppIcons.schedule, s('att_schedule'), const [Color(0xFF64748B), Color(0xFF94A3B8)]),
    ];
    final r = await showModalBottomSheet<String>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            mainAxisSpacing: 12,
            crossAxisSpacing: 8,
            // a little taller on small phones (icon + one line of text)
            childAspectRatio: MediaQuery.sizeOf(ctx).width < 360 ? 0.74 : 0.82,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final it in items)
                InkWell(
                  borderRadius: BorderRadius.circular(Radii.md),
                  onTap: () => Navigator.pop(ctx, it.$1),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconTile(it.$2, color: it.$4.first, size: IconTileSize.lg),
                      const SizedBox(height: 6),
                      Text(
                        it.$3,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: ctx.tt.bodySmall?.copyWith(color: ctx.lc.text),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (r) {
      case 'media':
        _attach(type: FileType.media);
      case 'camera':
        _attach(type: FileType.image);
      case 'file':
        _attach();
      case 'poll':
        _createPoll();
      case 'checklist':
        if (await showChecklistComposer(context, widget.conv)) widget.onSent();
      case 'reminder':
        if (await showReminderComposer(context, widget.conv)) widget.onSent();
      case 'location':
        showSendLocation(context, widget.conv);
      case 'contact':
        showSendContact(context, widget.conv);
      case 'voice':
        _startRecording();
      case 'meme':
        final path = await showMemeMaker(context);
        if (path != null && mounted) await context.read<FilesStore>().send(widget.conv, path);
      case 'scheduled':
        showScheduled(context, conv: widget.conv);
    }
  }

  Future<void> _createPoll() async {
    final r = await showDialog<(String, List<String>)>(context: context, builder: (_) => const _PollDialog());
    if (r == null) return;
    try {
      await _chat.sendPoll(widget.conv, r.$1, r.$2);
      widget.onSent();
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  /// Long-press / right-click on Send: "Gửi không âm báo" or "Hẹn giờ gửi".
  Future<void> _sendOptions(Offset at) async {
    final s = S.read(context);
    HapticFeedback.mediumImpact();
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final r = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
      items: [
        PopupMenuItem(
          value: 'silent',
          child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: const Icon(AppIcons.mute, size: 20), title: Text(s('send_silent')), subtitle: Text(s('send_silent_hint'))),
        ),
        PopupMenuItem(
          value: 'schedule',
          child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: const Icon(AppIcons.schedule, size: 20), title: Text(s('schedule_send'))),
        ),
      ],
    );
    if (!mounted) return;
    switch (r) {
      case 'silent':
        await _send(silent: true);
      case 'schedule':
        await _scheduleSend();
    }
  }

  Future<void> _scheduleSend() async {
    final s = S.read(context);
    final text = c.text.text.trim();
    if (text.isEmpty) return;
    final at = await pickScheduleTime(context);
    if (at == null) return;
    try {
      await _chat.schedule(widget.conv, text, at);
      c.text.clear();
      if (mounted) toast(context, s('scheduled_toast', {'t': '${s.dayLabel(at, DateTime.now())} ${s.hhmm(at)}'}));
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  Future<void> _attach({FileType type = FileType.any, List<String>? exts}) async {
    final s = S.read(context);
    try {
      final r = await FilePicker.pickFiles(
        type: type,
        allowedExtensions: exts,
        // iPhone: hand over "Most Compatible" JPEG instead of HEIC, so Windows/Linux
        // receivers can open it (Android/desktop HEIC is converted in the photo editor).
        darwinOptions: const DarwinOptions(assetRepresentationMode: DarwinAssetRepresentationMode.compatible),
      );
      final paths = [for (final f in r) ?f.path];
      if (!mounted) return;
      await showSendFiles(context, conv: widget.conv, paths: paths, onSent: widget.onSent);
    } catch (e) {
      if (mounted) toastError(context, e, prefix: '${s('send_failed')}: ');
    }
  }

  Widget _emojiPicker(double height) => EmojiPicker(
    onPick: _insertEmoji,
    height: height,
    onSticker: (st) {
      _chat.send(widget.conv, st);
      widget.onSent();
    },
    onCustomSticker: (st) async {
      try {
        final m = await context.read<LumoraApi>().sendSticker(widget.conv, st.hash);
        _chat.thread(widget.conv).add(m);
        widget.onSent();
      } catch (e) {
        if (!mounted) return;
        toastError(context, e);
      }
    },
    onGif: () => _attach(type: FileType.custom, exts: const ['gif', 'webp']),
  );

  void _insertEmoji(String e) {
    final t = c.text;
    final sel = t.selection.isValid ? t.selection : TextSelection.collapsed(offset: t.text.length);
    final next = t.text.replaceRange(sel.start, sel.end, e);
    t.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: sel.start + e.length),
    );
  }

  Future<void> _pickTtl() async {
    final s = S.read(context);
    const opts = [0, 30000, 300000, 3600000, 86400000, 604800000];
    final cur = _chat.ttlByConv[widget.conv] ?? 0;
    final r = await showModalBottomSheet<int>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Text(s('self_destruct'), style: ctx.tt.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(s('self_destruct_hint'), style: ctx.tt.bodySmall),
            ),
            for (final o in opts)
              ListTile(
                leading: Icon(o == 0 ? AppIcons.timerOff : AppIcons.timer),
                title: Text(o == 30000 ? s('ttl_sec', {'n': 30}) : s.ttlLabel(o)),
                trailing: o == cur ? const Icon(AppIcons.check, color: LC.primary) : null,
                onTap: () => Navigator.pop(ctx, o),
              ),
          ],
        ),
      ),
    );
    if (r != null) _chat.setTtl(widget.conv, r);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final lc = context.lc;
    final ttl = context.select<ChatStore, int>((ch) => ch.ttlByConv[widget.conv] ?? 0);
    final target = c.editing ?? c.replyTo;
    final contacts = context.read<ContactsStore>();
    return Material(
      color: lc.bg,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: Motion.fast,
              curve: Motion.curve,
              child: _showCommands
                  ? Container(
                      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                      decoration: BoxDecoration(
                        color: lc.surface,
                        borderRadius: BorderRadius.circular(Radii.md),
                        border: Border.all(color: lc.divider),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final cmd in _botCommands())
                            ListTile(
                              dense: true,
                              leading: const Icon(AppIcons.slashCommand, size: 18, color: LC.accent),
                              title: Text('/${cmd.$1}', style: const TextStyle(fontWeight: FontWeight.w700)),
                              subtitle: Text(cmd.$3 == null ? cmd.$2 : '${cmd.$2} · ${cmd.$3}', maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: () {
                                c.text.text = '/${cmd.$1}';
                                _send();
                              },
                            ),
                        ],
                      ),
                    )
                  : _mentionQuery == null
                  ? const SizedBox(width: double.infinity)
                  : Builder(
                      builder: (context) {
                        final opts = _mentionOptions();
                        if (opts.isEmpty) return const SizedBox(width: double.infinity);
                        return Container(
                          margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                          decoration: BoxDecoration(
                            color: lc.surface,
                            borderRadius: BorderRadius.circular(Radii.md),
                            border: Border.all(color: lc.divider),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(s('mention_members').toUpperCase(), style: context.tt.labelSmall),
                                ),
                              ),
                              for (final o in opts)
                                ListTile(
                                  dense: true,
                                  leading: o.$2 == null
                                      ? const CircleAvatar(
                                          radius: 14,
                                          backgroundColor: LC.warning,
                                          child: Icon(AppIcons.announce, size: 16, color: Colors.white),
                                        )
                                      : PeerAvatar(peer: o.$2!, size: 28),
                                  title: Text(o.$2 == null ? '@all' : o.$1, style: const TextStyle(fontWeight: FontWeight.w600)),
                                  subtitle: o.$2 == null ? Text(s('mention_all_hint')) : null,
                                  onTap: () => _insertMention(o.$1, o.$2),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            AnimatedSize(
              duration: Motion.normal,
              curve: Motion.curve,
              child: target == null
                  ? const SizedBox(width: double.infinity)
                  : Container(
                      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                      decoration: BoxDecoration(
                        color: lc.surface,
                        borderRadius: BorderRadius.circular(Radii.md),
                        border: Border(left: BorderSide(color: c.editing != null ? LC.warning : LC.accent, width: 3)),
                      ),
                      child: Row(
                        children: [
                          Icon(c.editing != null ? AppIcons.edit : AppIcons.reply, size: 18, color: c.editing != null ? LC.warning : LC.accent),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  c.editing != null ? s('editing_message') : s('replying_to', {'name': target.mine ? s('you') : contacts.nameOf(target.author)}),
                                  style: context.tt.labelMedium?.copyWith(color: c.editing != null ? LC.warning : LC.accent, fontWeight: FontWeight.w600),
                                ),
                                if (target.isFile || target.kind == 'checklist' || target.kind == 'reminder')
                                  PreviewLine(
                                    target.isFile
                                        ? '📎 ${FileRef.parse(target.body)?.name ?? ''}'
                                        : target.kind == 'checklist'
                                        ? '☑️ ${ChecklistData.parse(target)?.title ?? ''}'
                                        : '⏰ ${ReminderData.parse(target)?.title ?? ''}',
                                    style: context.tt.bodySmall,
                                  )
                                else
                                  Text(target.body, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall),
                              ],
                            ),
                          ),
                          IconButton(onPressed: c.clearTarget, icon: const Icon(AppIcons.close, size: 18), tooltip: s('cancel')),
                        ],
                      ),
                    ),
            ),
            AnimatedSize(
              duration: Motion.fast,
              child: _selActive && isDesktop(context)
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(60, 6, 12, 0),
                      child: Row(
                        children: [
                          for (final (icon, tip, l, r) in <(IconData, String, String, String?)>[
                            (AppIcons.bold, s('fmt_bold'), '**', null),
                            (AppIcons.italic, s('fmt_italic'), '_', null),
                            (AppIcons.strikethrough, s('fmt_strike'), '~~', null),
                            (AppIcons.code, s('fmt_code'), '`', null),
                            (AppIcons.codeBlock, s('fmt_block'), '```\n', '\n```'),
                            (AppIcons.hide, s('fmt_spoiler'), '||', null),
                          ])
                            ToolButton(icon: icon, tooltip: tip, size: 17, onPressed: () => _wrap(l, r)),
                        ],
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // The text row stays mounted under the recording bar, and the
                  // mic button below is the same widget throughout, so releasing
                  // / sliding / locking keep working while recording.
                  Expanded(
                    child: Stack(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _RoundIcon(icon: AppIcons.add, tooltip: s('attach'), onTap: _attachMenu),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(color: lc.surface2, borderRadius: BorderRadius.circular(22)),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: c.text,
                                        focusNode: c.focus,
                                        minLines: 1,
                                        maxLines: 6,
                                        textCapitalization: TextCapitalization.sentences,
                                        keyboardType: TextInputType.multiline,
                                        style: const TextStyle(fontSize: 14.5, height: 1.35),
                                        decoration: InputDecoration(
                                          hintText: s('message_hint'),
                                          filled: false,
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          contentPadding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
                                        ),
                                      ),
                                    ),
                                    _InlineIcon(
                                      icon: ttl > 0 ? AppIcons.timer : AppIcons.timer,
                                      color: ttl > 0 ? LC.warning : null,
                                      tooltip: ttl > 0 ? '${s('self_destruct')}: ${s.ttlLabel(ttl)}' : s('self_destruct'),
                                      onTap: _pickTtl,
                                    ),
                                    // Desktop: floating panel above the button; phones: inline panel below.
                                    EmojiPopoverAnchor(
                                      open: _emoji && isDesktop(context),
                                      onClose: () => setState(() => _emoji = false),
                                      builder: (_) => _emojiPicker(EmojiPopoverAnchor.size.height),
                                      child: _InlineIcon(
                                        icon: _emoji && !isDesktop(context) ? AppIcons.keyboard : AppIcons.emoji,
                                        color: _emoji ? LC.primary : null,
                                        tooltip: s('emoji'),
                                        onTap: () {
                                          setState(() => _emoji = !_emoji);
                                          if (!_emoji || isDesktop(context)) c.focus.requestFocus();
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (_recording)
                          Positioned.fill(
                            child: _RecordingBar(
                              elapsed: _recElapsed,
                              locked: _recLocked || isDesktop(context),
                              cancelHint: _recCancel,
                              onCancel: () => _stopRecording(send: false),
                              onSend: () => _stopRecording(send: true),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  AnimatedSwitcher(
                    key: _micKey,
                    duration: Motion.fast,
                    transitionBuilder: (w, a) => ScaleTransition(scale: a, child: w),
                    child: _hasText && !_recording
                        ? GestureDetector(
                            key: const ValueKey('send'),
                            onLongPressStart: c.editing == null ? (d) => _sendOptions(d.globalPosition) : null,
                            onSecondaryTapDown: c.editing == null ? (d) => _sendOptions(d.globalPosition) : null,
                            child: _SendButton(onTap: _send, edit: c.editing != null),
                          )
                        : GestureDetector(
                            key: const ValueKey('mic'),
                            onLongPressStart: (_) {
                              if (_recording) return; // locked: the bar has send / delete
                              _holding = true;
                              _startRecording(hold: true);
                            },
                            onLongPressMoveUpdate: (d) {
                              if (!_recording) return;
                              final cancel = d.offsetFromOrigin.dx < -90;
                              if (cancel != _recCancel) setState(() => _recCancel = cancel);
                              if (d.offsetFromOrigin.dy < -70 && !_recLocked) setState(() => _recLocked = true);
                            },
                            onLongPressEnd: (_) {
                              _holding = false;
                              if (!_recording || _recLocked) return;
                              _stopRecording(send: !_recCancel);
                            },
                            onLongPressCancel: () => _holding = false,
                            child: _RoundIcon(
                              icon: AppIcons.mic,
                              holdTarget: true,
                              color: _recording ? LC.danger : null,
                              tooltip: _recording ? s('recording') : (isDesktop(context) ? s('voice_click_hint') : s('voice_hold_hint')),
                              onTap: () {
                                if (_recording) return;
                                isDesktop(context) ? _startRecording() : toast(context, s('voice_hold_hint'));
                              },
                            ),
                          ),
                  ),
                ],
              ),
            ),
            AnimatedSize(
              duration: Motion.normal,
              curve: Motion.curve,
              child: _emoji && !isDesktop(context)
                  ? Container(
                      decoration: BoxDecoration(
                        color: lc.surface,
                        border: Border(top: BorderSide(color: lc.divider)),
                      ),
                      child: _emojiPicker(320),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.tooltip, required this.onTap, this.color, this.holdTarget = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  /// Hold-to-record button: a long press must reach the recorder, not open
  /// the tooltip (mouse hover still shows it).
  final bool holdTarget;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    triggerMode: holdTarget ? TooltipTriggerMode.manual : null,
    child: Material(
      color: color ?? context.lc.surface2,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 44, height: 44, child: Icon(icon, color: color == null ? context.lc.muted : Colors.white, size: 23)),
      ),
    ),
  );
}

class _InlineIcon extends StatelessWidget {
  const _InlineIcon({required this.icon, required this.tooltip, required this.onTap, this.color});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(11),
        child: Icon(icon, size: 22, color: color ?? context.lc.muted),
      ),
    ),
  );
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.onTap, required this.edit});
  final VoidCallback onTap;
  final bool edit;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: S.of(context)(edit ? 'save' : 'send'),
    child: DecoratedBox(
      decoration: const BoxDecoration(gradient: LC.gradient, shape: BoxShape.circle),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 44, height: 44, child: Icon(edit ? AppIcons.check : AppIcons.send, color: Colors.white, size: 21)),
        ),
      ),
    ),
  );
}

class _PollDialog extends StatefulWidget {
  const _PollDialog();
  @override
  State<_PollDialog> createState() => _PollDialogState();
}

class _PollDialogState extends State<_PollDialog> {
  final _q = TextEditingController();
  final List<TextEditingController> _opts = [TextEditingController(), TextEditingController()];

  @override
  void dispose() {
    _q.dispose();
    for (final o in _opts) {
      o.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final valid = _q.text.trim().isNotEmpty && _opts.where((o) => o.text.trim().isNotEmpty).length >= 2;
    return AlertDialog(
      title: Text(s('create_poll')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _q,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: s('poll_question')),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < _opts.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: _opts[i],
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: s('poll_option_n', {'n': i + 1}),
                      suffixIcon: _opts.length > 2 ? IconButton(tooltip: S.of(context)('remove'), icon: const Icon(AppIcons.close, size: 18), onPressed: () => setState(() => _opts.removeAt(i).dispose())) : null,
                    ),
                  ),
                ),
              if (_opts.length < 10)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(onPressed: () => setState(() => _opts.add(TextEditingController())), icon: const Icon(AppIcons.add), label: Text(s('add_option'))),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s('cancel'))),
        FilledButton(onPressed: valid ? () => Navigator.pop(context, (_q.text.trim(), _opts.map((o) => o.text.trim()).where((t) => t.isNotEmpty).toList())) : null, child: Text(s('send'))),
      ],
    );
  }
}

class _RecordingBar extends StatefulWidget {
  const _RecordingBar({required this.elapsed, required this.locked, required this.cancelHint, required this.onCancel, required this.onSend});
  final Duration elapsed;
  final bool locked;
  final bool cancelHint;
  final VoidCallback onCancel;
  final VoidCallback onSend;
  @override
  State<_RecordingBar> createState() => _RecordingBarState();
}

class _RecordingBarState extends State<_RecordingBar> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    // Covers the text row (same place), on the composer's background so the
    // icons below don't show through the rounded corners.
    return ColoredBox(
      color: context.lc.bg,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          height: 44,
          padding: const EdgeInsetsDirectional.only(start: 12, end: 2),
          decoration: BoxDecoration(color: context.lc.surface2, borderRadius: BorderRadius.circular(22)),
          child: Row(
            children: [
              FadeTransition(
                opacity: _blink,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(color: LC.danger, shape: BoxShape.circle),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                s.duration(widget.elapsed),
                style: const TextStyle(fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: widget.locked
                    ? Text(s('recording'), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall)
                    : Row(
                        children: [
                          Icon(AppIcons.chevronLeft, size: 18, color: widget.cancelHint ? LC.danger : context.lc.muted),
                          Flexible(
                            child: Text(
                              widget.cancelHint ? s('release_to_cancel') : s('slide_to_cancel'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: widget.cancelHint ? LC.danger : context.lc.muted),
                            ),
                          ),
                        ],
                      ),
              ),
              // Always there (also while holding): if the release is ever missed,
              // the recording can still be sent or thrown away by tapping.
              IconButton(
                key: const ValueKey('voice_cancel'),
                visualDensity: VisualDensity.compact,
                onPressed: widget.onCancel,
                icon: const Icon(AppIcons.delete, color: LC.danger, size: 20),
                tooltip: s('voice_discard'),
              ),
              IconButton.filled(key: const ValueKey('voice_send'), visualDensity: VisualDensity.compact, onPressed: widget.onSend, icon: const Icon(AppIcons.send, size: 17), tooltip: s('voice_send')),
            ],
          ),
        ),
      ),
    );
  }
}
