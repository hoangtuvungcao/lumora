import 'dart:async';

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/app_lock.dart';
import '../../state/settings.dart';
import '../../state/stores.dart';
import '../chats/chat_view.dart';
import '../friends/add_friend.dart';
import '../groups/create_group.dart';
import '../groups/group_safety.dart';
import '../groups/invite.dart';
import '../network/network_screen.dart';
import '../theme.dart';
import '../flows.dart';
import '../widgets/common.dart';
import '../widgets/peer_avatar.dart';

class _Item {
  _Item({required this.section, required this.title, this.subtitle, required this.leading, required this.run, this.shortcut, this.verified = false});
  final String section;

  /// Public group listing proven to come from the group's own admin.
  final bool verified;
  final String title;
  final String? subtitle;
  final Widget leading;
  final VoidCallback run;
  final String? shortcut;
}

/// Ctrl+K: quick switcher + command palette + message search.
Future<void> showCommandPalette(BuildContext context, {String? initial}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (_) => Align(
      alignment: const Alignment(0, -0.55),
      child: Material(type: MaterialType.transparency, child: CommandPalette(initial: initial)),
    ),
  );
}

class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key, this.initial});
  final String? initial;
  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  late final _q = TextEditingController(text: widget.initial);

  @override
  void initState() {
    super.initState();
    if ((widget.initial ?? '').isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _onChanged(_q.text));
  }

  final _scroll = ScrollController();
  int _sel = 0;
  List<Message> _found = const [];
  List<Map<String, dynamic>> _people = const [];
  List<Map<String, dynamic>> _groups = const [];
  Timer? _debounce;

  @override
  void dispose() {
    _q.dispose();
    _scroll.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() => _sel = 0);
    _debounce?.cancel();
    if (v.trim().length < 2) {
      setState(() => _found = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 260), () async {
      final api = context.read<LumoraApi>();
      final q = v.trim();
      try {
        final r = await api.search(q);
        if (mounted) setState(() => _found = r.take(8).toList());
      } catch (_) {}
      // Global directory: people by @username, public groups.
      try {
        final p = await api.resolveUsername(q.replaceAll('@', ''));
        if (mounted) setState(() => _people = p.take(6).toList());
      } catch (_) {}
      try {
        final g = await api.searchGroups(q.replaceAll('@', ''));
        if (mounted) setState(() => _groups = g.take(6).toList());
      } catch (_) {}
    });
  }

  void _openConv(String id) {
    final nav = context.read<NavStore>();
    final navigator = Navigator.of(context);
    navigator.pop();
    nav.openConv(id);
    if (!isDesktop(context)) navigator.push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: id)));
  }

  List<_Item> _items(S s) {
    final q = _q.text.trim().toLowerCase();
    final chat = context.read<ChatStore>();
    final contacts = context.read<ContactsStore>();
    final settings = context.read<Settings>();
    // Locked chats stay out of search until their folder is opened.
    final lock = context.read<AppLock>();
    final nav = context.read<NavStore>();
    final root = Navigator.of(context);
    void close(VoidCallback f) {
      root.pop();
      f();
    }

    final ctx = context;
    final commands = <_Item>[
      _Item(section: s('commands'), title: s('new_group'), leading: const Icon(AppIcons.people), run: () => close(() => showCreateGroup(ctx))),
      _Item(section: s('commands'), title: s('create_space'), leading: const Icon(AppIcons.community), run: () => close(() => showCreateGroup(ctx, community: true))),
      _Item(section: s('commands'), title: s('join_by_link'), leading: const Icon(AppIcons.explore), run: () => close(() => showJoinByLink(ctx))),
      _Item(section: s('commands'), title: s('add_friend'), leading: const Icon(AppIcons.addFriend), run: () => close(() => showAddFriend(ctx))),
      _Item(section: s('commands'), title: s('saved_messages'), leading: const Icon(AppIcons.bookmark), run: () => _openConv('s:me')),
      _Item(section: s('commands'), title: s('remote'), leading: const Icon(AppIcons.remote), run: () => close(() => nav.go(Section.remote))),
      _Item(section: s('commands'), title: s('files'), leading: const Icon(AppIcons.transfers), run: () => close(() => nav.go(Section.files))),
      _Item(section: s('commands'), title: s('settings'), leading: const Icon(AppIcons.settings), shortcut: 'Ctrl+,', run: () => close(() => nav.go(Section.settings))),
      _Item(section: s('commands'), title: s('diagnostics'), leading: const Icon(AppIcons.shieldPlus), run: () => close(() => openDiagnostics(ctx))),
      _Item(
        section: s('commands'),
        title: s('toggle_theme'),
        leading: const Icon(AppIcons.moon),
        shortcut: 'Ctrl+Shift+L',
        run: () => close(() => settings.update((x) => x.themeMode = x.themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light)),
      ),
      _Item(
        section: s('commands'),
        title: s('switch_language'),
        leading: const Icon(AppIcons.language),
        run: () => close(() => settings.update((x) => x.locale = x.locale == 'vi' ? 'en' : 'vi')),
      ),
    ].where((i) => q.isEmpty || i.title.toLowerCase().contains(q)).toList();

    final convs = chat.sorted
        .where((c) => !lock.isChatHidden(c.id))
        .where((c) => q.isEmpty ? true : (c.isSaved ? s('saved_messages') : c.title).toLowerCase().contains(q))
        .take(q.isEmpty ? 5 : 8)
        .map((c) => _Item(
              section: s('chats'),
              title: c.isSaved ? s('saved_messages') : c.title,
              subtitle: s.preview(c.lastText),
              leading: c.isSaved
                  ? const SavedAvatar(size: 32)
                  : (c.peer != null ? PeerAvatar(peer: c.peer!, fallbackName: c.title, size: 32) : GroupAvatar(gid: c.gid ?? c.id, name: c.title, size: 32)),
              run: () => _openConv(c.id),
            ));
    final people = q.isEmpty
        ? const <_Item>[]
        : contacts.friends
            .where((c) => c.displayName.toLowerCase().contains(q) || c.shortId.replaceAll(' ', '').contains(q.replaceAll(' ', '')))
            .where((c) => !chat.convs.containsKey('d:${c.peer}'))
            .take(5)
            .map((c) => _Item(
                  section: s('friends'),
                  title: c.displayName,
                  subtitle: 'ID ${c.shortId}',
                  leading: PeerAvatar(peer: c.peer, size: 32),
                  run: () => _openConv(chat.ensureDirect(c)),
                ));
    // Natural commands: "gọi Minh Anh", "video Bảo", "điều khiển máy Bảo",
    // "nhắn Linh", "gửi file cho Hà" (VI + EN keywords).
    final actions = <_Item>[];
    const verbs = <String, List<String>>{
      'call': ['gọi ', 'goi ', 'call '],
      'video': ['video ', 'gọi video ', 'facetime '],
      'remote': ['điều khiển máy ', 'điều khiển ', 'dieu khien ', 'remote ', 'control '],
      'chat': ['nhắn ', 'nhan ', 'chat ', 'message '],
      'file': ['gửi file cho ', 'gửi file ', 'send file to ', 'send file '],
    };
    String? verb;
    var who = q;
    for (final e in verbs.entries) {
      for (final v in e.value) {
        if (q.startsWith(v) && (verb == null || v.length > who.length)) {
          verb = e.key;
          who = q.substring(v.length).trim();
        }
      }
    }
    final targets = contacts.friends.where((c) => who.isNotEmpty && c.displayName.toLowerCase().contains(who)).take(4).toList();
    for (final c in targets) {
      final conv = 'd:${c.peer}';
      final all = <(String, IconData, String, VoidCallback)>[
        ('call', AppIcons.call, s('cmd_call', {'name': c.displayName}), () => close(() => Flows.call(ctx, conv))),
        ('video', AppIcons.video, s('cmd_video', {'name': c.displayName}), () => close(() => Flows.call(ctx, conv, video: true))),
        ('remote', AppIcons.remote, s('cmd_remote', {'name': c.displayName}), () => close(() => Flows.requestControl(ctx, c.peer))),
        ('file', AppIcons.attach, s('cmd_file', {'name': c.displayName}), () => close(() => Flows.sendFile(ctx, conv))),
        ('chat', AppIcons.chat, s('cmd_chat', {'name': c.displayName}), () => _openConv(chat.ensureDirect(c))),
      ];
      for (final a in all) {
        if (verb == null || verb == a.$1) {
          actions.add(_Item(section: s('actions'), title: a.$3, leading: Icon(a.$2), run: a.$4));
        }
      }
    }
    if (Flows.isDeepLink(_q.text)) {
      actions.insert(0, _Item(section: s('actions'), title: s('open_link'), subtitle: _q.text.trim(), leading: const Icon(AppIcons.link), run: () => close(() => Flows.openDeepLink(ctx, _q.text))));
    }
    final files = q.length < 2
        ? const <_Item>[]
        : context.read<FilesStore>().sorted.where((f) => !lock.isChatHidden(f.conv) && f.name.toLowerCase().contains(q)).take(5).map((f) => _Item(
              section: s('files'),
              title: f.name,
              subtitle: s.bytes(f.size),
              leading: const Icon(AppIcons.file),
              run: () => f.conv.isNotEmpty ? _openConv(f.conv) : close(() => nav.go(Section.files)),
            ));
    final settingsHits = q.length < 2
        ? const <_Item>[]
        : [
            for (final k in ['settings_profile', 'settings_appearance', 'settings_privacy', 'settings_remote', 'settings_storage', 'settings_security', 'settings_language', 'settings_advanced', 'wallpaper', 'diagnostics'])
              if (s(k).toLowerCase().contains(q))
                _Item(section: s('settings'), title: s(k), leading: const Icon(AppIcons.settings), run: () => close(() => nav.go(k == 'diagnostics' ? Section.network : Section.settings))),
          ];
    final msgs = _found.where((m) => !lock.isChatHidden(m.conv)).map((m) => _Item(
          section: s('messages'),
          title: stripFormatting(m.body),
          subtitle: chat.convs[m.conv]?.title ?? '',
          leading: const Icon(AppIcons.chat),
          run: () => _openConv(m.conv),
        ));
    final dirPeople = _people.where((p) => p['contact'] != true).map((p) => _Item(
          section: s('people_global'),
          title: p['name']?.toString() ?? '',
          subtitle: p['handle']?.toString() ?? '',
          leading: Avatar(name: p['name']?.toString() ?? '?', seed: p['peer']?.toString(), size: 32),
          run: () => close(() async {
            try {
              await contacts.add(p['peer'].toString());
              if (ctx.mounted) toast(ctx, s('request_sent_toast'));
            } catch (e) {
              if (ctx.mounted) toastError(ctx, e);
            }
          }),
          shortcut: s('add_friend'),
        ));
    final pubGroups = _groups.map((g) => _Item(
          section: s('public_groups'),
          title: g['title']?.toString() ?? g['name']?.toString() ?? '',
          verified: g['verified'] == true,
          subtitle: [
            g['handle'] ?? '',
            s('n_members', {'n': g['members'] ?? 0}),
            if (g['verified'] != true) s('group_unverified'),
          ].where((x) => '$x'.isNotEmpty).join(' · '),
          leading: Avatar(name: g['title']?.toString() ?? '?', seed: g['gid']?.toString(), size: 32, group: true),
          shortcut: s('join'),
          run: () => close(() async {
            try {
              await ctx.read<LumoraApi>().joinPublic(g['gid'].toString(), g['admin'].toString());
              if (ctx.mounted) toast(ctx, s('join_requested'));
            } catch (e) {
              if (ctx.mounted) toastError(ctx, e);
            }
          }),
        ));
    return [...actions, ...convs, ...people, ...dirPeople, ...pubGroups, ...msgs, ...files, ...settingsHits, ...commands];
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final items = _items(s);
    if (_sel >= items.length) _sel = items.isEmpty ? 0 : items.length - 1;
    final width = MediaQuery.sizeOf(context).width;
    return Container(
      width: width < 640 ? width - 24 : 600,
      constraints: const BoxConstraints(maxHeight: 520),
      decoration: BoxDecoration(
        color: context.lc.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: context.lc.divider),
        boxShadow: kNoShadows ? null : const [BoxShadow(color: Colors.black45, blurRadius: 40, offset: Offset(0, 18))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Focus(
          onKeyEvent: (n, e) {
            if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
            if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
              setState(() => _sel = (_sel + 1).clamp(0, items.length - 1));
              return KeyEventResult.handled;
            }
            if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
              setState(() => _sel = (_sel - 1).clamp(0, items.length - 1));
              return KeyEventResult.handled;
            }
            if (e.logicalKey == LogicalKeyboardKey.enter && items.isNotEmpty) {
              items[_sel].run();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: TextField(
            controller: _q,
            autofocus: true,
            onChanged: _onChanged,
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              hintText: s('palette_hint'),
              prefixIcon: const Icon(AppIcons.search),
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 18),
              suffixIcon: Padding(
                padding: const EdgeInsets.all(12),
                child: Pill('Esc', color: context.lc.muted),
              ),
            ),
          ),
        ),
        Divider(height: 1, color: context.lc.divider),
        Flexible(
          child: items.isEmpty
              ? Padding(padding: const EdgeInsets.all(28), child: Text(s('no_results'), style: context.tt.bodySmall))
              : ListView.builder(
                  controller: _scroll,
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final it = items[i];
                    final header = i == 0 || items[i - 1].section != it.section;
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                      if (header) SectionLabel(it.section, padding: const EdgeInsets.fromLTRB(16, 10, 16, 4)),
                      MouseRegion(
                        onEnter: (_) => setState(() => _sel = i),
                        child: Material(
                          color: i == _sel ? LC.primary.withValues(alpha: 0.14) : Colors.transparent,
                          child: InkWell(
                            onTap: it.run,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: Row(children: [
                                SizedBox(width: 32, child: IconTheme(data: IconThemeData(color: context.lc.muted, size: 20), child: it.leading)),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Row(children: [
                                      Flexible(child: Text(it.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500))),
                                      if (it.verified) ...[const SizedBox(width: 4), const VerifiedGroupMark()],
                                    ]),
                                    if (it.subtitle != null && it.subtitle!.isNotEmpty)
                                      Text(it.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall),
                                  ]),
                                ),
                                if (it.shortcut != null) Pill(it.shortcut!, color: context.lc.muted),
                                if (i == _sel) ...[const SizedBox(width: 8), Icon(AppIcons.enterKey, size: 16, color: context.lc.muted)],
                              ]),
                            ),
                          ),
                        ),
                      ),
                    ]);
                  },
                ),
        ),
      ]),
    );
  }
}

/// Locks the app now; without an app lock, says how to turn it on.
void lockNow(BuildContext context) {
  if (!context.read<AppLock>().lockNow()) toast(context, S.read(context)('lock_now_off'));
}

/// Global desktop shortcuts.
class AppShortcuts extends StatelessWidget {
  const AppShortcuts({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final nav = context.read<NavStore>();
    final settings = context.read<Settings>();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () => showCommandPalette(context),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => showCommandPalette(context),
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () => nav.go(Section.settings),
        // "Khoá ngay": lock the app right away (needs the app lock on).
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): () => lockNow(context),
        const SingleActivator(LogicalKeyboardKey.keyL, meta: true): () => lockNow(context),
        const SingleActivator(LogicalKeyboardKey.keyL, control: true, shift: true): () =>
            settings.update((x) => x.themeMode = x.themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light),
        const SingleActivator(LogicalKeyboardKey.digit1, alt: true): () => nav.go(Section.chats),
        const SingleActivator(LogicalKeyboardKey.digit2, alt: true): () => nav.go(Section.friends),
        const SingleActivator(LogicalKeyboardKey.digit3, alt: true): () => nav.go(Section.remote),
        const SingleActivator(LogicalKeyboardKey.digit4, alt: true): () => nav.go(Section.files),
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}
