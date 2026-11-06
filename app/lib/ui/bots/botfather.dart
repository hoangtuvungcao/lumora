// Built-in "BotFather" pseudo-chat: guided bot creation and management
// (bot_create / bot_list / bot_token / bot_revoke / bot_delete).

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/core_events.dart';

const kBotFatherConv = 'bot:father';
const kDevDocsUrl = 'https://getlumora.pages.dev/developers/';

/// Gradient robot avatar for BotFather.
class BotFatherAvatar extends StatelessWidget {
  const BotFatherAvatar({super.key, this.size = 40});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF0EA5E9), Color(0xFF6C5CE7)]),
        ),
        child: Icon(AppIcons.bot, color: Colors.white, size: size * 0.52),
      );
}

class BotBadge extends StatelessWidget {
  const BotBadge({super.key});
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(color: LC.accent.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(5)),
        child: const Text('BOT', style: TextStyle(color: LC.accent, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
      );
}

enum _Step { idle, askName, askUsername }

/// One line of the BotFather chat. [kind] says which card goes with a reply
/// ('docs', 'token' for [user]'s bot, 'bots' = my bots); [token] is only
/// held in memory for the reply that created it (never saved).
class _Msg {
  _Msg(this.mine, this.text, {this.kind = '', this.user = '', this.token});
  final bool mine;
  final String text;
  final String kind;
  final String user;
  final String? token;

  Map<String, dynamic> toJson() => {
        'mine': mine,
        'text': text,
        'ts': DateTime.now().millisecondsSinceEpoch,
        if (kind.isNotEmpty) 'kind': kind,
        if (user.isNotEmpty) 'u': user,
      };

  static _Msg fromJson(Map<String, dynamic> j) =>
      _Msg(j['mine'] == true, j['text']?.toString() ?? '', kind: j['kind']?.toString() ?? '', user: j['u']?.toString() ?? '');
}

class BotFatherChat extends StatefulWidget {
  const BotFatherChat({super.key, this.embedded = false});
  final bool embedded;
  @override
  State<BotFatherChat> createState() => _BotFatherChatState();
}

class _BotFatherChatState extends State<BotFatherChat> {
  /// The conversation: kept by the core (synced to the account's devices,
  /// last 200 lines), so it is still here after leaving the chat or a restart.
  final List<_Msg> _msgs = [];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  _Step _step = _Step.idle;
  String _name = '';
  bool _busy = false;
  late final LumoraApi _api = context.read<LumoraApi>();

  /// Saves run one after another (the core appends in that order).
  Future<void> _saving = Future.value();

  /// The chat went on on another of my devices: shown here at once.
  CoreEventWatch? _synced;

  @override
  void initState() {
    super.initState();
    _load();
    _synced = CoreEventWatch.settings(_api, const {'privacy.botfather_chat'}, _reloadSynced);
  }

  /// Takes the core's copy of the chat (lines added or cleared on another
  /// device). A token shown here stays with its reply (never saved).
  Future<void> _reloadSynced() async {
    await _saving; // (my own lines first)
    List<Map<String, dynamic>> saved;
    try {
      saved = await _api.botfatherHistory();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final tokens = {for (final m in _msgs) if (m.kind == 'token' && m.token != null) m.user: m.token};
    final atEnd = !_scroll.hasClients || _scroll.position.pixels >= _scroll.position.maxScrollExtent - 24;
    setState(() {
      _msgs
        ..clear()
        ..addAll(saved.map(_Msg.fromJson).map((m) => m.kind == 'token' && tokens.containsKey(m.user) ? _Msg(m.mine, m.text, kind: m.kind, user: m.user, token: tokens.remove(m.user)) : m));
    });
    if (atEnd) _toEnd();
  }

  Future<void> _load() async {
    List<Map<String, dynamic>> saved;
    try {
      saved = await _api.botfatherHistory();
    } catch (_) {
      return; // older core: this visit only
    }
    if (!mounted || saved.isEmpty) return;
    // (lines typed while it was loading stay after the saved ones)
    setState(() => _msgs.insertAll(0, saved.map(_Msg.fromJson)));
    _toEnd(jump: true);
  }

  @override
  void dispose() {
    _synced?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _add(_Msg m) {
    setState(() => _msgs.add(m));
    _toEnd();
    final api = _api;
    _saving = _saving.then((_) => api.botfatherAppend([m.toJson()])).catchError((_) {});
  }

  void _bot(String text, {String kind = '', String user = '', String? token}) => _add(_Msg(false, text, kind: kind, user: user, token: token));

  void _me(String text) => _add(_Msg(true, text));

  void _toEnd({bool jump = false}) => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final end = _scroll.position.maxScrollExtent;
        jump ? _scroll.jumpTo(end) : _scroll.animateTo(end, duration: Motion.normal, curve: Motion.curve);
      });

  Future<void> _handle(String raw) async {
    final s = S.read(context);
    final api = _api;
    final text = raw.trim();
    if (text.isEmpty) return;
    _me(text);
    _input.clear();
    if (text == '/newbot') {
      _step = _Step.askName;
      _bot(s('bf_ask_name'));
      return;
    }
    if (text == '/mybots') {
      _step = _Step.idle;
      await _listBots();
      return;
    }
    if (text == '/help' || text == '/start') {
      _step = _Step.idle;
      _bot(s('bf_help'), kind: 'docs');
      return;
    }
    if (text == '/cancel') {
      _step = _Step.idle;
      _bot(s('bf_cancelled'));
      return;
    }
    switch (_step) {
      case _Step.askName:
        _name = text;
        _step = _Step.askUsername;
        _bot(s('bf_ask_username', {'name': text}));
      case _Step.askUsername:
        final u = text.replaceAll('@', '').toLowerCase();
        if (!u.endsWith('bot')) {
          _bot(s('bf_username_rule'));
          return;
        }
        setState(() => _busy = true);
        try {
          final b = await api.botCreate(_name, u);
          _step = _Step.idle;
          _bot(s('bf_created', {'name': b.name, 'handle': b.handle.isEmpty ? '@${b.username}' : b.handle}), kind: 'token', user: b.username, token: b.token ?? '');
        } catch (e) {
          _bot('${s('bf_error')} ${e is ApiException ? e.message : e}');
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      case _Step.idle:
        _bot(s('bf_unknown'));
    }
  }

  Future<void> _listBots() async {
    final s = S.read(context);
    try {
      final bots = await _api.botList();
      if (!mounted) return;
      if (bots.isEmpty) {
        _bot(s('bf_no_bots'));
        return;
      }
      _bot(s('bf_your_bots', {'n': bots.length}), kind: 'bots');
    } catch (e) {
      _bot('${s('bf_error')} $e');
    }
  }

  Widget _docsButton(S s) => Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => launchUrl(Uri.parse(kDevDocsUrl), mode: LaunchMode.externalApplication),
          icon: const Icon(AppIcons.guide, size: 16),
          label: Text(s('bf_docs')),
        ),
      );

  /// The card under a reply. A saved token reply shows the bot's current
  /// token (hidden; it may have been revoked since); only the newest
  /// "my bots" reply carries the live list.
  Widget? _cardOf(_Msg m, int i, S s) {
    switch (m.kind) {
      case 'docs':
        return _docsButton(s);
      case 'token':
        final t = m.token;
        if (t != null) return TokenCard(token: t);
        return m.user.isEmpty ? null : _SavedTokenCard(username: m.user);
      case 'bots':
        final newest = _msgs.lastIndexWhere((x) => x.kind == 'bots') == i;
        return newest ? _MyBotsList(key: ValueKey('bots$i')) : null;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final lc = context.lc;
    final chips = _step == _Step.idle ? ['/newbot', '/mybots', '/help'] : ['/cancel'];
    final body = Column(children: [
      PaneHeader(
        onBack: widget.embedded ? null : () => Navigator.of(context).maybePop(),
        leading: const BotFatherAvatar(size: 38),
        title: Row(mainAxisSize: MainAxisSize.min, children: [const Text('BotFather'), const BotBadge(), const SizedBox(width: 4), const Icon(AppIcons.verifiedFill, size: 16, color: LC.accent)]),
        subtitle: Text(s('bf_subtitle')),
      ),
      Expanded(
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.all(16),
          itemCount: _msgs.length + 1,
          itemBuilder: (context, i) {
            // the greeting always opens the chat (not saved)
            final m = i == 0 ? _Msg(false, s('bf_welcome')) : _msgs[i - 1];
            final child = i == 0 ? null : _cardOf(m, i - 1, s);
            return Align(
              alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 460),
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: BoxDecoration(
                  gradient: m.mine ? const LinearGradient(colors: [LC.primary, Color(0xFF5A4BD8)]) : null,
                  color: m.mine ? null : lc.bubbleIn,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  if (m.text.isNotEmpty) Text(m.text, style: TextStyle(color: m.mine ? Colors.white : lc.text, height: 1.4)),
                  if (child != null) ...[const SizedBox(height: 8), child],
                ]),
              ),
            );
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: Wrap(spacing: 6, children: [
          for (final c in chips) ActionChip(label: Text(c), onPressed: _busy ? null : () => _handle(c)),
        ]),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                enabled: !_busy,
                onSubmitted: _handle,
                decoration: InputDecoration(hintText: _step == _Step.askName ? s('bf_hint_name') : (_step == _Step.askUsername ? s('bf_hint_username') : s('bf_hint_cmd'))),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(tooltip: S.of(context)('send'), onPressed: _busy ? null : () => _handle(_input.text), icon: const Icon(AppIcons.send, size: 18)),
          ]),
        ),
      ),
    ]);
    return widget.embedded ? Material(color: lc.bg, child: body) : Scaffold(body: SafeArea(child: body));
  }
}

/// A saved "bot created" reply: the bot's current token, hidden (nothing
/// when the bot is gone).
class _SavedTokenCard extends StatefulWidget {
  const _SavedTokenCard({required this.username});
  final String username;
  @override
  State<_SavedTokenCard> createState() => _SavedTokenCardState();
}

class _SavedTokenCardState extends State<_SavedTokenCard> {
  late Future<String> _token = _fetch();
  CoreEventWatch? _bots;

  Future<String> _fetch() => context.read<LumoraApi>().botToken(widget.username).catchError((_) => '');

  @override
  void initState() {
    super.initState();
    // revoked / deleted on another of my devices: the card follows
    _bots = CoreEventWatch.settings(context.read<LumoraApi>(), const {'botfather.bots'}, () {
      if (mounted) setState(() => _token = _fetch());
    });
  }

  @override
  void dispose() {
    _bots?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
        future: _token,
        builder: (_, snap) => (snap.data ?? '').isEmpty ? const SizedBox.shrink() : TokenCard(token: snap.data!, hidden: true),
      );
}

/// "My bots" reply: the current list with its actions.
class _MyBotsList extends StatefulWidget {
  const _MyBotsList({super.key});
  @override
  State<_MyBotsList> createState() => _MyBotsListState();
}

class _MyBotsListState extends State<_MyBotsList> {
  List<BotAccount> _bots = const [];
  CoreEventWatch? _synced;

  @override
  void initState() {
    super.initState();
    _load();
    // a bot made / deleted on another of my devices
    _synced = CoreEventWatch.settings(context.read<LumoraApi>(), const {'botfather.bots'}, _load);
  }

  @override
  void dispose() {
    _synced?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final b = await context.read<LumoraApi>().botList();
      if (mounted) setState(() => _bots = b);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [for (final b in _bots) BotCard(key: ValueKey(b.username), bot: b, onChanged: _load)]);
}

/// Token card with copy + "keep it secret" warning + docs link.
class TokenCard extends StatefulWidget {
  const TokenCard({super.key, required this.token, this.hidden = false});
  final String token;
  final bool hidden;
  @override
  State<TokenCard> createState() => _TokenCardState();
}

class _TokenCardState extends State<TokenCard> {
  late bool _hidden = widget.hidden;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final t = widget.token;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: context.lc.surface2, borderRadius: BorderRadius.circular(Radii.md), border: Border.all(color: LC.warning.withValues(alpha: 0.4))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Icon(AppIcons.key, size: 16, color: LC.warning),
          const SizedBox(width: 6),
          Text(s('bf_token'), style: context.tt.labelLarge),
          const Spacer(),
          IconButton(
            tooltip: _hidden ? s('show') : s('hide'),
            onPressed: () => setState(() => _hidden = !_hidden),
            icon: Icon(_hidden ? AppIcons.show : AppIcons.hide, size: 16),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(tooltip: s('copy'), onPressed: () => copyText(context, t), icon: const Icon(AppIcons.copy, size: 16), visualDensity: VisualDensity.compact),
        ]),
        SelectableText(
          _hidden ? '•' * 32 : t,
          maxLines: 3,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(AppIcons.shieldWarning, size: 15, color: LC.warning),
          const SizedBox(width: 6),
          Expanded(child: Text(s('bf_keep_secret'), style: context.tt.bodySmall?.copyWith(color: context.lc.text))),
        ]),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => launchUrl(Uri.parse(kDevDocsUrl), mode: LaunchMode.externalApplication),
            icon: const Icon(AppIcons.guide, size: 15),
            label: Text(s('bf_docs')),
          ),
        ),
      ]),
    );
  }
}

/// One of my bots with token / revoke / delete / rename help.
class BotCard extends StatefulWidget {
  const BotCard({super.key, required this.bot, required this.onChanged});
  final BotAccount bot;
  final VoidCallback onChanged;
  @override
  State<BotCard> createState() => _BotCardState();
}

class _BotCardState extends State<BotCard> {
  String? _token;

  Future<void> _showToken() async {
    final t = await context.read<LumoraApi>().botToken(widget.bot.username);
    if (mounted) setState(() => _token = t);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final b = widget.bot;
    final api = context.read<LumoraApi>();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: context.lc.surface2.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(Radii.md)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Avatar(name: b.name, seed: b.peer, size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Flexible(child: Text(b.name, style: context.tt.titleSmall)), const BotBadge()]),
              Text(b.handle.isEmpty ? '@${b.username}' : b.handle, style: context.tt.bodySmall),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          ActionChip(avatar: const Icon(AppIcons.key, size: 15), label: Text(s('bf_token')), onPressed: _showToken),
          ActionChip(
            avatar: const Icon(AppIcons.refresh, size: 15),
            label: Text(s('bf_revoke')),
            onPressed: () async {
              if (!await confirm(context, title: s('bf_revoke'), body: s('bf_revoke_body'), action: s('bf_revoke'), danger: true)) return;
              final nb = await api.botRevoke(b.username);
              if (mounted) setState(() => _token = nb.token);
            },
          ),
          ActionChip(
            avatar: const Icon(AppIcons.edit, size: 15),
            label: Text(s('bf_rename')),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (c) => AlertDialog(
                title: Text(s('bf_rename')),
                content: Text(s('bf_rename_body')),
                actions: [
                  TextButton(onPressed: () => launchUrl(Uri.parse(kDevDocsUrl), mode: LaunchMode.externalApplication), child: Text(s('bf_docs'))),
                  FilledButton(onPressed: () => Navigator.pop(c), child: Text(s('done'))),
                ],
              ),
            ),
          ),
          ActionChip(
            avatar: const Icon(AppIcons.delete, size: 15, color: LC.danger),
            label: Text(s('bf_delete'), style: const TextStyle(color: LC.danger)),
            onPressed: () async {
              if (!await confirm(context, title: s('bf_delete'), body: s('bf_delete_body', {'name': b.name}), action: s('delete'), danger: true)) return;
              await api.botDelete(b.username);
              widget.onChanged();
            },
          ),
        ]),
        if (_token != null) ...[const SizedBox(height: 8), TokenCard(token: _token!, hidden: true)],
      ]),
    );
  }
}

/// Settings → "Bot của tôi".
class MyBotsPage extends StatefulWidget {
  const MyBotsPage({super.key, required this.onCreate});
  final VoidCallback onCreate;
  @override
  State<MyBotsPage> createState() => _MyBotsPageState();
}

class _MyBotsPageState extends State<MyBotsPage> {
  List<BotAccount>? _bots;
  CoreEventWatch? _synced;

  @override
  void initState() {
    super.initState();
    _load();
    // a bot made / deleted on another of my devices
    _synced = CoreEventWatch.settings(context.read<LumoraApi>(), const {'botfather.bots'}, _load);
  }

  @override
  void dispose() {
    _synced?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final b = await context.read<LumoraApi>().botList();
      if (mounted) setState(() => _bots = b);
    } catch (_) {
      if (mounted) setState(() => _bots = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final bots = _bots;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LCard(
        child: Row(children: [
          const BotFatherAvatar(size: 44),
          const SizedBox(width: 12),
          Expanded(child: Text(s('my_bots_hint'), style: context.tt.bodyMedium)),
          const SizedBox(width: 8),
          FilledButton.icon(onPressed: widget.onCreate, icon: const Icon(AppIcons.add, size: 16), label: Text(s('create_bot'))),
        ]),
      ),
      const SizedBox(height: 16),
      if (bots == null) const Center(child: CircularProgressIndicator()),
      if (bots != null && bots.isEmpty) EmptyState(icon: AppIcons.bot, title: s('bf_no_bots')),
      if (bots != null) for (final b in bots) BotCard(key: ValueKey(b.username), bot: b, onChanged: _load),
    ]);
  }
}
