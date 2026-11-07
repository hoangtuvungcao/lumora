// Community channels: create (text / voice, category, topic), edit (name,
// topic, category, private + allowed roles, announcement-only), reorder,
// delete. Also the channel menu of the channel list (long-press / right-click).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/api.dart';
import '../../../l10n/strings.dart';
import '../../../state/community.dart';
import '../../../state/stores.dart';
import '../../theme.dart';
import '../../widgets/app_icons.dart';
import '../../widgets/common.dart';
import 'community_common.dart';

/// [chans] grouped for display: uncategorised first, then each category in the
/// order of its first channel; channels by `position` (then list order).
List<(String, List<Channel>)> channelSections(List<Channel> chans) {
  final indexed = [for (var i = 0; i < chans.length; i++) (i, chans[i])]..sort((a, b) => a.$2.position != b.$2.position ? a.$2.position.compareTo(b.$2.position) : a.$1.compareTo(b.$1));
  final out = <String, List<Channel>>{'': []};
  for (final (_, c) in indexed) {
    (out[c.category.trim()] ??= []).add(c);
  }
  return [
    for (final e in out.entries)
      if (e.value.isNotEmpty) (e.key, e.value),
  ];
}

/// After a channel change: the info and the channel list (`spaces`) at once.
Future<bool> _change(BuildContext context, String gid, Future<void> Function(LumoraApi api) f) async {
  final spaces = context.read<SpacesStore>();
  try {
    await CommunityStore.of(context.read<LumoraApi>()).change(gid, f);
    await spaces.load().catchError((_) {});
    return true;
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return false;
  }
}

String _normName(String v) => v.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '-');

/// New channel: type, name, category, topic.
Future<void> createChannel(BuildContext context, String gid, {String? category}) async {
  final s = S.read(context);
  final g = CommunityStore.of(context.read<LumoraApi>()).info(gid);
  final cats = {
    for (final c in g?.channels ?? const <Channel>[])
      if (c.category.trim().isNotEmpty) c.category.trim(),
  }.toList();
  var voice = false;
  final name = TextEditingController();
  final topic = TextEditingController();
  final cat = TextEditingController(text: category ?? '');
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text(s('add_channel')),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: false, icon: const Icon(AppIcons.channel, size: 18), label: Text(s('text_channel'))),
                    ButtonSegment(value: true, icon: const Icon(AppIcons.speaker, size: 18), label: Text(s('voice_channel'))),
                  ],
                  selected: {voice},
                  onSelectionChanged: (v) => set(() => voice = v.first),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('cm_new_channel_name'),
                  controller: name,
                  autofocus: true,
                  decoration: InputDecoration(labelText: s('channel_name')),
                ),
                const SizedBox(height: 10),
                _CategoryField(controller: cat, existing: cats),
                if (!voice) ...[
                  const SizedBox(height: 10),
                  TextField(
                    key: const ValueKey('cm_new_channel_topic'),
                    controller: topic,
                    decoration: InputDecoration(labelText: s('cm_channel_topic'), helperText: s('cm_channel_topic_hint')),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(s('cancel'))),
          FilledButton(key: const ValueKey('cm_new_channel_ok'), onPressed: () => Navigator.pop(c, true), child: Text(s('add'))),
        ],
      ),
    ),
  );
  final n = _normName(name.text), t = topic.text.trim(), k = cat.text.trim();
  name.dispose();
  topic.dispose();
  cat.dispose();
  if (ok != true || n.isEmpty || !context.mounted) return;
  await _change(context, gid, (api) => api.groupChannel(gid, n, voice: voice, category: k, topic: voice ? null : t));
}

/// Category: free text with the existing categories one tap away.
class _CategoryField extends StatefulWidget {
  const _CategoryField({required this.controller, required this.existing});
  final TextEditingController controller;
  final List<String> existing;
  @override
  State<_CategoryField> createState() => _CategoryFieldState();
}

class _CategoryFieldState extends State<_CategoryField> {
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('cm_channel_category'),
          controller: widget.controller,
          textCapitalization: TextCapitalization.characters,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: s('cm_category'), hintText: s('cm_category_hint')),
        ),
        if (widget.existing.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(label: Text(s('cm_no_category')), selected: widget.controller.text.trim().isEmpty, onSelected: (_) => setState(() => widget.controller.text = '')),
              for (final c in widget.existing)
                ChoiceChip(key: ValueKey('cm_cat_$c'), label: Text(c), selected: widget.controller.text.trim() == c, onSelected: (_) => setState(() => widget.controller.text = c)),
            ],
          ),
        ],
      ],
    );
  }
}

Future<void> openChannelEditor(BuildContext context, String gid, String channelName) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ChannelEditorPage(gid: gid, channelName: channelName),
  ),
);

/// Delete channel [name] (confirmed).
Future<bool> deleteChannel(BuildContext context, String gid, Channel ch) async {
  final s = S.read(context);
  if (!await confirm(context, title: s('cm_delete_channel'), body: s('cm_delete_channel_body', {'name': ch.voice ? ch.name : '#${ch.name}'}), action: s('delete'), danger: true)) {
    return false;
  }
  if (!context.mounted) return false;
  return _change(context, gid, (api) => api.groupChannel(gid, ch.name, voice: ch.voice, remove: true));
}

/// Long-press / right-click on a channel: edit / delete (needs manage_channels).
Future<void> showChannelMenu(BuildContext context, String gid, Channel ch, {Offset? at}) async {
  final s = S.read(context);
  final store = CommunityStore.of(context.read<LumoraApi>());
  final g = store.info(gid) ?? await store.load(gid);
  if (g == null || !g.can(Perm.manageChannels) || !context.mounted) return;
  final items = [('edit', AppIcons.edit, s('cm_edit_channel')), ('delete', AppIcons.delete, s('cm_delete_channel'))];
  String? r;
  if (at != null) {
    r = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        for (final it in items)
          PopupMenuItem(
            key: ValueKey('channel_menu_${it.$1}'),
            value: it.$1,
            child: Row(
              children: [
                Icon(it.$2, size: 18, color: it.$1 == 'delete' ? LC.danger : null),
                const SizedBox(width: 12),
                Text(it.$3, style: it.$1 == 'delete' ? const TextStyle(color: LC.danger) : null),
              ],
            ),
          ),
      ],
    );
  } else {
    r = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(ch.voice ? AppIcons.speaker : AppIcons.channel),
              title: Text(ch.name, style: c.tt.titleMedium),
            ),
            for (final it in items)
              ListTile(
                key: ValueKey('channel_menu_${it.$1}'),
                leading: Icon(it.$2, color: it.$1 == 'delete' ? LC.danger : null),
                title: Text(it.$3, style: it.$1 == 'delete' ? const TextStyle(color: LC.danger) : null),
                onTap: () => Navigator.pop(c, it.$1),
              ),
          ],
        ),
      ),
    );
  }
  if (!context.mounted) return;
  if (r == 'edit') {
    await openChannelEditor(context, gid, ch.name);
  } else if (r == 'delete') {
    await deleteChannel(context, gid, ch);
  }
}

// =============================================================== editor

class ChannelEditorPage extends StatefulWidget {
  const ChannelEditorPage({super.key, required this.gid, required this.channelName});
  final String gid;
  final String channelName;
  @override
  State<ChannelEditorPage> createState() => _ChannelEditorPageState();
}

class _ChannelEditorPageState extends State<ChannelEditorPage> {
  final _name = TextEditingController();
  final _topic = TextEditingController();
  final _cat = TextEditingController();
  bool _private = false, _announce = false, _ready = false, _busy = false;
  final Set<String> _allow = {};
  Channel? _ch;

  @override
  void dispose() {
    _name.dispose();
    _topic.dispose();
    _cat.dispose();
    super.dispose();
  }

  void _init(Channel c) {
    if (_ready) return;
    _ready = true;
    _ch = c;
    _name.text = c.name;
    _topic.text = c.topic;
    _cat.text = c.category;
    _private = c.private;
    _announce = c.announce;
    _allow.addAll(c.allowRoles);
  }

  Future<void> _save(GroupInfo g) async {
    final c = _ch!;
    final n = c.voice ? _name.text.trim() : _normName(_name.text);
    if (n.isEmpty) return;
    setState(() => _busy = true);
    final ok = await _change(
      context,
      widget.gid,
      (api) => api.groupChannelUpdate(
        widget.gid,
        c.name,
        newName: n != c.name ? n : null,
        topic: _topic.text.trim(),
        category: _cat.text.trim(),
        private: _private,
        announce: c.voice ? null : _announce,
        allowRoles: [
          for (final r in g.roles)
            if (_allow.contains(r.id)) r.id,
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      toast(context, S.read(context)('cm_saved'));
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return CommunityBuilder(
      gid: widget.gid,
      builder: (context, g) {
        final c = g?.channels.where((x) => x.name == (_ch?.name ?? widget.channelName)).firstOrNull;
        if (g == null || c == null) {
          return Scaffold(
            appBar: AppBar(title: Text(s('cm_edit_channel'))),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        _init(c);
        final cats = {
          for (final x in g.channels)
            if (x.category.trim().isNotEmpty) x.category.trim(),
        }.toList();
        final roles = g.roles.where((r) => !r.isAdmin).toList();
        return Scaffold(
          appBar: AppBar(
            title: Text(s('cm_edit_channel')),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Center(
                  child: FilledButton(
                    key: const ValueKey('cm_channel_save'),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: 18)),
                    onPressed: _busy ? null : () => _save(g),
                    child: Text(s('save')),
                  ),
                ),
              ),
            ],
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  TextField(
                    key: const ValueKey('cm_channel_name'),
                    controller: _name,
                    decoration: InputDecoration(labelText: s('channel_name'), prefixIcon: Icon(c.voice ? AppIcons.speaker : AppIcons.channel, size: 20)),
                  ),
                  if (!c.voice) ...[
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('cm_channel_topic'),
                      controller: _topic,
                      maxLines: 3,
                      minLines: 1,
                      maxLength: 200,
                      decoration: InputDecoration(labelText: s('cm_channel_topic'), helperText: s('cm_channel_topic_hint')),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _CategoryField(controller: _cat, existing: cats),
                  const SizedBox(height: 16),
                  LCard(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Column(
                      children: [
                        SwitchRow(
                          key: const ValueKey('cm_channel_private'),
                          icon: AppIcons.lock,
                          title: s('cm_private'),
                          subtitle: s('cm_private_hint'),
                          value: _private,
                          onChanged: (v) => setState(() => _private = v),
                        ),
                        if (!c.voice)
                          SwitchRow(
                            key: const ValueKey('cm_channel_announce'),
                            icon: AppIcons.announce,
                            title: s('cm_announce'),
                            subtitle: s('cm_announce_hint'),
                            value: _announce,
                            onChanged: (v) => setState(() => _announce = v),
                          ),
                      ],
                    ),
                  ),
                  AnimatedSize(
                    duration: Motion.normal,
                    curve: Motion.curve,
                    child: !(_private || _announce)
                        ? const SizedBox(width: double.infinity)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SectionLabel(s('cm_allowed_roles'), padding: const EdgeInsets.fromLTRB(4, 16, 4, 6)),
                              LCard(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: Column(
                                  children: [
                                    for (final r in roles)
                                      CheckboxListTile(
                                        key: ValueKey('cm_allow_${r.id}'),
                                        value: _allow.contains(r.id),
                                        onChanged: (v) => setState(() => v == true ? _allow.add(r.id) : _allow.remove(r.id)),
                                        secondary: Container(
                                          width: 14,
                                          height: 14,
                                          decoration: BoxDecoration(color: roleColor(r), shape: BoxShape.circle),
                                        ),
                                        title: Text(
                                          roleName(s, r),
                                          style: TextStyle(color: r.isEveryone ? null : roleColor(r), fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 20),
                  LCard(
                    padding: const EdgeInsets.all(4),
                    child: ListTile(
                      key: const ValueKey('cm_channel_delete'),
                      leading: const Icon(AppIcons.delete, color: LC.danger),
                      title: Text(
                        s('cm_delete_channel'),
                        style: const TextStyle(color: LC.danger, fontWeight: FontWeight.w600),
                      ),
                      onTap: () async {
                        final nav = Navigator.of(context);
                        if (await deleteChannel(context, widget.gid, c)) nav.maybePop();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ================================================================ pane

/// Settings › Channels: by category, drag (or arrows) to reorder inside a category.
class ChannelsPane extends StatelessWidget {
  const ChannelsPane({super.key, required this.gid});
  final String gid;

  /// Moves [ch] to [to] inside its category: the whole order is rebuilt and the
  /// channel's new global index is sent as its position.
  Future<void> _move(BuildContext context, List<Channel> all, List<Channel> cat, int from, int to) async {
    if (to < 0 || to >= cat.length || to == from) return;
    final ch = cat[from];
    final reordered = [...cat]..removeAt(from);
    reordered.insert(to, ch);
    final sections = channelSections(all);
    final order = [for (final (_, list) in sections) ...(list.first.category.trim() == ch.category.trim() ? reordered : list)];
    await _change(context, gid, (api) => api.groupChannelUpdate(gid, ch.name, position: order.indexOf(ch)));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return CommunityBuilder(
      gid: gid,
      builder: (context, g) {
        if (g == null) return const Center(child: CircularProgressIndicator());
        final sections = channelSections(g.channels);
        // phones: the drag handle only (room for the topic); wider: arrows too
        final arrows = MediaQuery.sizeOf(context).width >= 600;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(key: const ValueKey('cm_add_channel'), onPressed: () => createChannel(context, gid), icon: const Icon(AppIcons.add, size: 18), label: Text(s('add_channel'))),
            ),
            for (final (cat, list) in sections) ...[
              SectionLabel(
                cat.isEmpty ? s('cm_no_category').toUpperCase() : cat,
                padding: const EdgeInsets.fromLTRB(4, 18, 0, 6),
                trailing: IconButton(
                  tooltip: s('add_channel'),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(AppIcons.add, size: 18),
                  onPressed: () => createChannel(context, gid, category: cat),
                ),
              ),
              ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                onReorder: (a, b) => _move(context, g.channels, list, a, b > a ? b - 1 : b),
                children: [
                  for (var i = 0; i < list.length; i++)
                    Padding(
                      key: ValueKey('cm_channel_row_${list[i].name}'),
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Material(
                        color: context.lc.surface,
                        borderRadius: BorderRadius.circular(Radii.md),
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(Radii.md),
                            side: BorderSide(color: context.lc.divider),
                          ),
                          leading: Icon(list[i].voice ? AppIcons.speaker : AppIcons.channel, color: context.lc.muted),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  list[i].name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                              if (list[i].private)
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Icon(AppIcons.lock, size: 14, color: context.lc.muted),
                                ),
                              if (list[i].announce)
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Icon(AppIcons.announce, size: 14, color: context.lc.muted),
                                ),
                            ],
                          ),
                          subtitle: list[i].topic.isEmpty ? null : Text(list[i].topic, maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => openChannelEditor(context, gid, list[i].name),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (arrows) ...[
                                IconButton(
                                  key: ValueKey('cm_channel_up_${list[i].name}'),
                                  tooltip: s('cm_move_up'),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: i == 0 ? null : () => _move(context, g.channels, list, i, i - 1),
                                  icon: const Icon(Icons.keyboard_arrow_up),
                                ),
                                IconButton(
                                  key: ValueKey('cm_channel_down_${list[i].name}'),
                                  tooltip: s('cm_move_down'),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: i == list.length - 1 ? null : () => _move(context, g.channels, list, i, i + 1),
                                  icon: const Icon(Icons.keyboard_arrow_down),
                                ),
                              ],
                              ReorderableDragStartListener(
                                index: i,
                                child: Icon(Icons.drag_indicator, color: context.lc.muted),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}
