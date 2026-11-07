// 24 h stories (friends only): avatar row, full-screen viewer, composer.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/peer_avatar.dart';
import 'story_audience.dart';
import 'wallpaper.dart';

const _storyBgs = ['aurora', 'sunset', 'ocean', 'mint', 'sakura', 'lavender'];

class StoriesRow extends StatelessWidget {
  const StoriesRow({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final me = context.select<SessionStore, String>((x) => x.me?.peer ?? '');
    final store = context.watch<StoryStore>();
    final groups = store.byAuthor(me);
    final mine = store.mine(me);
    final contacts = context.read<ContactsStore>();
    return SizedBox(
      height: 92,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        children: [
          _StoryAvatar(
            peer: me,
            label: s('your_story'),
            ring: mine.isEmpty ? null : false,
            add: mine.isEmpty,
            onTap: () => mine.isEmpty ? showStoryComposer(context) : openStories(context, [MapEntry(me, mine)], 0),
            onLongPress: () => showStoryComposer(context),
          ),
          for (var i = 0; i < groups.length; i++)
            _StoryAvatar(
              peer: groups[i].key,
              label: contacts.nameOf(groups[i].key).split(' ').last,
              ring: groups[i].value.any((x) => !x.seen),
              onTap: () => openStories(context, groups, i),
            ),
        ],
      ),
    );
  }
}

class _StoryAvatar extends StatelessWidget {
  const _StoryAvatar({required this.peer, required this.label, required this.ring, required this.onTap, this.add = false, this.onLongPress});
  final String peer;
  final String label;

  /// true = unseen (gradient), false = seen (grey), null = none.
  final bool? ring;
  final bool add;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: 68,
        child: Column(children: [
          const SizedBox(height: 4),
          Stack(clipBehavior: Clip.none, children: [
            Container(
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: ring == true ? const SweepGradient(colors: [LC.primary, LC.accent, Color(0xFFEC4899), LC.primary]) : null,
                color: ring == false ? context.lc.muted.withValues(alpha: 0.4) : Colors.transparent,
              ),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(shape: BoxShape.circle, color: context.lc.surface),
                child: PeerAvatar(peer: peer, size: 50, presence: false),
              ),
            ),
            if (add)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(color: LC.primary, shape: BoxShape.circle, border: Border.all(color: context.lc.surface, width: 2)),
                  child: const Icon(AppIcons.add, color: Colors.white, size: 18),
                ),
              ),
          ]),
          const SizedBox(height: 4),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall?.copyWith(fontSize: 11.5)),
        ]),
      ),
    );
  }
}

Future<void> openStories(BuildContext context, List<MapEntry<String, List<Story>>> groups, int index) {
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.black,
    transitionDuration: Motion.normal,
    pageBuilder: (_, _, _) => StoryViewer(groups: groups, initial: index),
    transitionsBuilder: (_, a, _, c) => FadeTransition(opacity: a, child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(a), child: c)),
  ));
}

class StoryViewer extends StatefulWidget {
  const StoryViewer({super.key, required this.groups, required this.initial});
  final List<MapEntry<String, List<Story>>> groups;
  final int initial;
  @override
  State<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends State<StoryViewer> with SingleTickerProviderStateMixin {
  late int _g = widget.initial;
  int _i = 0;
  late final AnimationController _progress = AnimationController(vsync: this, duration: const Duration(seconds: 6))
    ..addStatusListener((st) {
      if (st == AnimationStatus.completed) _next();
    });
  final _reply = TextEditingController();
  Uint8List? _image;

  List<Story> get _stories => widget.groups[_g].value;
  Story get _story => _stories[_i];

  @override
  void initState() {
    super.initState();
    _i = _stories.indexWhere((s) => !s.seen).clamp(0, _stories.length - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _show();
    });
  }

  @override
  void dispose() {
    _progress.dispose();
    _reply.dispose();
    super.dispose();
  }

  Future<void> _show() async {
    final st = _story;
    context.read<StoryStore>().seen(st.id);
    _image = null;
    _progress.reset();
    if (st.hasImage) {
      final img = await context.read<StoryStore>().image(st.id);
      if (!mounted || _story.id != st.id) return;
      setState(() => _image = img);
    } else {
      setState(() {});
    }
    _progress.forward();
  }

  void _next() {
    if (_i < _stories.length - 1) {
      _i++;
    } else if (_g < widget.groups.length - 1) {
      _g++;
      _i = 0;
    } else {
      Navigator.pop(context);
      return;
    }
    _show();
  }

  void _prev() {
    if (_i > 0) {
      _i--;
    } else if (_g > 0) {
      _g--;
      _i = _stories.length - 1;
    }
    _show();
  }

  Future<void> _delete() async {
    _progress.stop();
    final st = _story;
    final ok = await confirmStoryDelete(context);
    if (!mounted) return;
    if (!ok) {
      _progress.forward();
      return;
    }
    try {
      await context.read<StoryStore>().delete(st.id);
      if (!mounted) return;
      toast(context, S.read(context)('story_deleted'));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) toastError(context, e);
      _progress.forward();
    }
  }

  Future<void> _sendReply() async {
    final text = _reply.text.trim();
    if (text.isEmpty) return;
    final chat = context.read<ChatStore>();
    final contact = context.read<ContactsStore>()[widget.groups[_g].key];
    if (contact == null) return;
    final conv = chat.ensureDirect(contact);
    await chat.send(conv, '${S.read(context)('story_reply_prefix')}: $text');
    _reply.clear();
    if (mounted) toast(context, S.read(context)('reply_sent'));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = _story;
    final me = context.read<SessionStore>().me?.peer;
    final mine = st.author == me;
    final name = mine ? s('you') : context.read<ContactsStore>().nameOf(st.author);
    final ago = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(st.created));
    final width = MediaQuery.sizeOf(context).width;
    final content = Stack(fit: StackFit.expand, children: [
      if (st.hasImage && _image != null)
        Image.memory(_image!, fit: BoxFit.cover, gaplessPlayback: true)
      else
        WallpaperBackground(spec: WallpaperSpec.parse(st.bg ?? 'aurora') ?? WallpaperSpec.parse('aurora')!),
      if (st.text.isNotEmpty)
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              st.text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: st.hasImage ? 22 : 30,
                fontWeight: FontWeight.w700,
                height: 1.3,
                shadows: const [Shadow(color: Colors.black54, blurRadius: 12)],
              ),
            ),
          ),
        ),
      // Tap zones.
      Row(children: [
        Expanded(child: GestureDetector(onTap: _prev, onLongPressStart: (_) => _progress.stop(), onLongPressEnd: (_) => _progress.forward())),
        Expanded(flex: 2, child: GestureDetector(onTap: _next, onLongPressStart: (_) => _progress.stop(), onLongPressEnd: (_) => _progress.forward())),
      ]),
      // Header.
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 24),
          decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.black54, Colors.transparent])),
          child: SafeArea(
            bottom: false,
            child: Column(children: [
              Row(children: [
                for (var k = 0; k < _stories.length; k++)
                  Expanded(
                    child: Container(
                      height: 3,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(color: Colors.white30, borderRadius: BorderRadius.circular(2)),
                      alignment: Alignment.centerLeft,
                      child: k < _i
                          ? Container(color: Colors.white)
                          : (k == _i
                              ? AnimatedBuilder(
                                  animation: _progress,
                                  builder: (_, _) => FractionallySizedBox(widthFactor: _progress.value, child: Container(color: Colors.white)),
                                )
                              : null),
                    ),
                  ),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                PeerAvatar(peer: st.author, size: 36, presence: false),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                    Text(ago.inHours > 0 ? s('hours_ago', {'n': ago.inHours}) : s('minutes_ago', {'n': ago.inMinutes}),
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ]),
                ),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(AppIcons.close, color: Colors.white), tooltip: s('close')),
              ]),
            ]),
          ),
        ),
      ),
      // Footer.
      Positioned(
        left: 12,
        right: 12,
        bottom: 12,
        child: SafeArea(
          top: false,
          child: mine
              ? Row(children: [
                  // live: `story_view` events raise the count while it is open
                  Builder(builder: (context) {
                    final views = context.select<StoryStore, int>((x) => x.stories.where((e) => e.id == st.id).firstOrNull?.views ?? st.views);
                    return InkWell(
                      key: const ValueKey('story_views'),
                      borderRadius: BorderRadius.circular(20),
                      onTap: () async {
                        _progress.stop();
                        await showStoryViewers(context, st.id);
                        if (mounted) _progress.forward();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(AppIcons.show, color: Colors.white70, size: 18),
                          const SizedBox(width: 6),
                          Text(s('n_views', {'n': views}), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                          const Icon(AppIcons.chevronRight, color: Colors.white70, size: 16),
                        ]),
                      ),
                    );
                  }),
                  const Spacer(),
                  IconButton(
                    tooltip: s('story_archive'),
                    onPressed: () async {
                      _progress.stop();
                      await showStoryArchive(context);
                      if (mounted) _progress.forward();
                    },
                    icon: const Icon(AppIcons.archive, color: Colors.white),
                  ),
                  IconButton(tooltip: s('story_delete'), onPressed: _delete, icon: const Icon(AppIcons.delete, color: Colors.white)),
                ])
              : Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _reply,
                      onTap: _progress.stop,
                      onSubmitted: (_) => _sendReply(),
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: s('reply_story'),
                        hintStyle: const TextStyle(color: Colors.white70),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.14),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: const BorderSide(color: Colors.white24)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  for (final e in ['❤️', '😂', '🔥'])
                    InkWell(
                      onTap: () {
                        _reply.text = e;
                        _sendReply();
                      },
                      child: Padding(padding: const EdgeInsets.all(4), child: Text(e, style: const TextStyle(fontSize: 24))),
                    ),
                ]),
        ),
      ),
    ]);
    return Scaffold(
      backgroundColor: Colors.black,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): _next,
          const SingleActivator(LogicalKeyboardKey.arrowLeft): _prev,
          const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context),
        },
        child: Focus(
          autofocus: true,
          child: Center(
            child: _StoryFrame(child: ClipRRect(borderRadius: BorderRadius.circular(width > 700 ? Radii.lg : 0), child: content)),
          ),
        ),
      ),
    );
  }
}

Future<void> showStoryComposer(BuildContext context) {
  return Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => const StoryComposer()));
}

class StoryComposer extends StatefulWidget {
  const StoryComposer({super.key});
  @override
  State<StoryComposer> createState() => _StoryComposerState();
}

class _StoryComposerState extends State<StoryComposer> {
  final _text = TextEditingController();
  String _bg = 'aurora';
  String? _imagePath;
  bool _busy = false;
  String _audience = kStoryFriends;

  @override
  void initState() {
    super.initState();
    final st = context.read<StoryStore>();
    if (!st.audienceLoaded) st.loadAudience();
  }

  Future<void> _pickAudience() async {
    final a = await showStoryAudienceSheet(context, _audience);
    if (a != null && mounted) setState(() => _audience = a);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    setState(() => _busy = true);
    try {
      await context.read<StoryStore>().post(text: _text.text.trim().isEmpty ? null : _text.text.trim(), imagePath: _imagePath, bg: _bg, audience: _audience);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) toastError(context, e);
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: _StoryFrame(
            child: Stack(fit: StackFit.expand, children: [
              WallpaperBackground(spec: WallpaperSpec.parse(_bg)!),
              if (_imagePath != null) Image(image: ResizeImage(FileImage(File(_imagePath!)), width: 1080), fit: BoxFit.cover),
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: TextField(
                    controller: _text,
                    onChanged: (_) => setState(() {}),
                    textAlign: TextAlign.center,
                    maxLines: 6,
                    minLines: 1,
                    style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700, shadows: [Shadow(color: Colors.black45, blurRadius: 10)]),
                    decoration: InputDecoration(
                      hintText: s('story_hint'),
                      hintStyle: const TextStyle(color: Colors.white60),
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Row(children: [
                  IconButton(tooltip: S.of(context)('close'), onPressed: () => Navigator.pop(context), icon: const Icon(AppIcons.close, color: Colors.white)),
                  Expanded(child: Text(s('new_story'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16))),
                  IconButton(tooltip: s('story_archive'), onPressed: () => showStoryArchive(context), icon: const Icon(AppIcons.archive, color: Colors.white)),
                  IconButton(
                    tooltip: s('choose_photo'),
                    onPressed: () async {
                      final f = await FilePicker.pickFile(type: FileType.image);
                      if (f?.path != null) setState(() => _imagePath = f!.path);
                    },
                    icon: const Icon(AppIcons.gallery, color: Colors.white),
                  ),
                ]),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 56,
                child: Align(alignment: Alignment.centerLeft, child: _AudienceChip(audience: _audience, onTap: _busy ? null : _pickAudience)),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Row(children: [
                  for (final b in _storyBgs)
                    GestureDetector(
                      onTap: () => setState(() => _bg = b),
                      child: Container(
                        width: 30,
                        height: 30,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: _bg == b ? 3 : 1)),
                        clipBehavior: Clip.antiAlias,
                        child: WallpaperBackground(spec: WallpaperSpec.parse(b)!),
                      ),
                    ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _busy || (_text.text.trim().isEmpty && _imagePath == null) ? null : _post,
                    icon: const Icon(AppIcons.send, size: 18),
                    label: Text(s('share_story')),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}


/// The story card: a 9:16 card on wide screens; the whole screen on phones, so
/// an open keyboard (reply / composer text) shortens it instead of narrowing it
/// and pushing the bottom row out of the screen.
class _StoryFrame extends StatelessWidget {
  const _StoryFrame({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      MediaQuery.sizeOf(context).width > 700 ? AspectRatio(aspectRatio: 9 / 16, child: child) : SizedBox.expand(child: child);
}

/// "Bạn bè ▾" / "Bạn thân ▾" over the composer: who the new Khoảnh khắc goes to.
class _AudienceChip extends StatelessWidget {
  const _AudienceChip({required this.audience, required this.onTap});
  final String audience;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final close = audience == kStoryClose;
    return Material(
      key: const ValueKey('story_audience_chip'),
      color: close ? LC.success.withValues(alpha: 0.85) : Colors.black.withValues(alpha: 0.35),
      shape: const StadiumBorder(side: BorderSide(color: Colors.white54)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(close ? AppIcons.sparkle : AppIcons.friends, color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Text(close ? s('mo_aud_close') : s('mo_aud_friends'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            const SizedBox(width: 2),
            const Icon(AppIcons.chevronDown, color: Colors.white, size: 16),
          ]),
        ),
      ),
    );
  }
}

Future<bool> confirmStoryDelete(BuildContext context) {
  final s = S.read(context);
  return confirm(context, title: s('story_delete_q'), body: s('story_delete_body'), action: s('delete'), danger: true);
}

Future<void> showStoryArchive(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => const StoryArchiveScreen()));

/// My stories, also after their 24 h (only on my side): open one, or delete it.
class StoryArchiveScreen extends StatefulWidget {
  const StoryArchiveScreen({super.key});
  @override
  State<StoryArchiveScreen> createState() => _StoryArchiveScreenState();
}

class _StoryArchiveScreenState extends State<StoryArchiveScreen> {
  List<Story>? _list;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final me = context.read<SessionStore>().me?.peer ?? '';
    try {
      final l = await context.read<StoryStore>().archive(me);
      if (mounted) setState(() => _list = l);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _delete(Story st) async {
    if (!await confirmStoryDelete(context) || !mounted) return;
    try {
      await context.read<StoryStore>().delete(st.id);
      if (!mounted) return;
      setState(() => _list = _list?.where((x) => x.id != st.id).toList());
      toast(context, S.read(context)('story_deleted'));
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final list = _list;
    final now = DateTime.now().millisecondsSinceEpoch;
    Widget body;
    if (_error != null) {
      body = Center(child: Text(errorMessage(s, _error!)));
    } else if (list == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (list.isEmpty) {
      body = EmptyState(icon: AppIcons.story, title: s('story_archive_empty'), subtitle: s('story_archive_hint'));
    } else {
      body = CustomScrollView(slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          sliver: SliverToBoxAdapter(child: Text(s('story_archive_hint'), style: context.tt.bodySmall?.copyWith(color: context.lc.muted))),
        ),
        SliverPadding(
          padding: const EdgeInsets.all(12),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 160, childAspectRatio: 9 / 16, mainAxisSpacing: 8, crossAxisSpacing: 8),
            delegate: SliverChildBuilderDelegate(childCount: list.length, (c, i) {
              final st = list[i];
              final live = now - st.created < 86400000;
              final day = DateTime.fromMillisecondsSinceEpoch(st.created);
              return _ArchiveTile(
                story: st,
                live: live,
                date: '${day.day}/${day.month}/${day.year}',
                onTap: () => openStories(context, [MapEntry(st.author, [st])], 0),
                onDelete: () => _delete(st),
              );
            }),
          ),
        ),
      ]);
    }
    return Scaffold(appBar: AppBar(title: Text(s('story_archive'))), body: body);
  }
}

class _ArchiveTile extends StatelessWidget {
  const _ArchiveTile({required this.story, required this.live, required this.date, required this.onTap, required this.onDelete});
  final Story story;
  final bool live;
  final String date;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.md),
      child: Material(
        color: Colors.black,
        child: InkWell(
          onTap: onTap,
          child: Stack(fit: StackFit.expand, children: [
            WallpaperBackground(spec: WallpaperSpec.parse(story.bg ?? 'aurora') ?? WallpaperSpec.parse('aurora')!),
            if (story.hasImage)
              FutureBuilder<Uint8List?>(
                future: context.read<StoryStore>().image(story.id),
                builder: (_, snap) => snap.data == null ? const SizedBox() : Image.memory(snap.data!, fit: BoxFit.cover, cacheWidth: 320),
              ),
            if (story.text.isNotEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(story.text, maxLines: 4, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, shadows: [Shadow(color: Colors.black54, blurRadius: 8)])),
                ),
              ),
            Positioned(
              left: 6,
              bottom: 6,
              child: Text(live ? s('story_active') : date,
                  style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600, shadows: [Shadow(color: Colors.black87, blurRadius: 6)])),
            ),
            Positioned(
              right: 0,
              top: 0,
              child: IconButton(
                tooltip: s('story_delete'),
                onPressed: onDelete,
                icon: const Icon(AppIcons.delete, color: Colors.white, size: 20, shadows: [Shadow(color: Colors.black87, blurRadius: 6)]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Who saw my story [id] and when (from the core; reloads as new views come in).
Future<void> showStoryViewers(BuildContext context, String id) => showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (_) => _StoryViewersSheet(id: id),
    );

class _StoryViewersSheet extends StatefulWidget {
  const _StoryViewersSheet({required this.id});
  final String id;
  @override
  State<_StoryViewersSheet> createState() => _StoryViewersSheetState();
}

class _StoryViewersSheetState extends State<_StoryViewersSheet> {
  List<StoryView>? _list;
  late final StoryStore _store = context.read<StoryStore>();

  @override
  void initState() {
    super.initState();
    _load();
    _store.viewTick.addListener(_load);
  }

  @override
  void dispose() {
    _store.viewTick.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final l = await _store.viewers(widget.id);
      if (mounted) setState(() => _list = l.reversed.toList()); // newest first
    } catch (_) {
      if (mounted) setState(() => _list ??= const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final contacts = context.watch<ContactsStore>();
    final list = _list;
    final now = DateTime.now();
    String when(int ts) {
      if (ts <= 0) return '';
      final ago = now.difference(DateTime.fromMillisecondsSinceEpoch(ts));
      if (ago.inMinutes < 1) return s('story_viewed_now');
      return ago.inHours > 0 ? s('hours_ago', {'n': ago.inHours}) : s('minutes_ago', {'n': ago.inMinutes});
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: Row(children: [
              Expanded(child: Text(s('story_viewers'), style: context.tt.titleMedium)),
              if (list != null) Text(s('n_views', {'n': list.length}), style: context.tt.bodySmall),
            ]),
          ),
          if (list == null)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else if (list.isEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Text(s('story_no_viewers'), textAlign: TextAlign.center, style: context.tt.bodySmall))
          else
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final v in list)
                  ListTile(
                    leading: PeerAvatar(peer: v.peer, size: 36, presence: false),
                    title: Text(contacts[v.peer] != null || v.name.isEmpty ? contacts.nameOf(v.peer) : v.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: v.ts > 0 ? Text(when(v.ts), style: context.tt.bodySmall) : null,
                  ),
              ]),
            ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}
