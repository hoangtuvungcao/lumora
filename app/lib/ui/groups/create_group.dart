import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/community_defaults.dart';
import '../../state/stores.dart';
import '../chats/chat_view.dart';
import '../theme.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/common.dart';
import '../../core/text_fold.dart';

Future<void> showCreateGroup(BuildContext context, {bool community = false}) async {
  final desktop = isDesktop(context);
  final nav = context.read<NavStore>();
  final navigator = Navigator.of(context);
  final Future<String?> pending = desktop
      ? showDialog<String>(
          context: context,
          builder: (_) => Dialog(child: SizedBox(width: 460, height: 640, child: CreateGroupForm(community: community))),
        )
      : navigator.push<String>(MaterialPageRoute(builder: (_) => Scaffold(body: SafeArea(child: CreateGroupForm(community: community)))));
  final conv = await pending;
  if (conv == null) return;
  nav.openConv(conv);
  if (!desktop) {
    navigator.push(MaterialPageRoute<void>(builder: (_) => ChatView(conv: conv)));
  }
}

/// Pick members from friends to add (returns peers) – also used by group info.
Future<List<String>?> pickMembers(BuildContext context, {Set<String> exclude = const {}}) {
  return showDialog<List<String>>(
    context: context,
    builder: (_) => Dialog(child: SizedBox(width: 440, height: 560, child: _MemberPicker(exclude: exclude))),
  );
}

class CreateGroupForm extends StatefulWidget {
  const CreateGroupForm({super.key, this.community = false});
  final bool community;
  @override
  State<CreateGroupForm> createState() => _CreateGroupFormState();
}

class _CreateGroupFormState extends State<CreateGroupForm> {
  final _name = TextEditingController();
  final _selected = <String>{};
  String _q = '';
  bool _busy = false;
  late bool _community = widget.community;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final api = context.read<LumoraApi>();
      final spaces = context.read<SpacesStore>();
      final defaults = context.read<CommunityDefaults>();
      final conv = _community
          ? await api.createCommunity(_name.text.trim(), _selected.toList())
          : await api.createGroup(_name.text.trim(), _selected.toList());
      if (_community) {
        await spaces.load();
        // "Default history retention for communities" (Settings › Privacy)
        final space = conv.length > 2 ? spaces.byId(conv.substring(2)) : null;
        await defaults.adopt(conv, channels: [for (final c in space?.channels ?? const <Channel>[]) c.conv]);
      }
      if (mounted) Navigator.pop(context, conv);
    } catch (e) {
      if (mounted) toastError(context, e);
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final friends = context.watch<ContactsStore>().friends.where((c) => _q.isEmpty || foldText(c.displayName).contains(_q)).toList();
    final contacts = context.read<ContactsStore>();
    final can = _name.text.trim().isNotEmpty && _selected.isNotEmpty && !_busy;
    return Column(children: [
      PaneHeader(title: Text(_community ? s('new_community') : s('new_group')), onBack: () => Navigator.pop(context)),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
        child: SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: false, icon: const Icon(AppIcons.friends, size: 18), label: Text(s('kind_group'))),
            ButtonSegment(value: true, icon: const Icon(AppIcons.community, size: 18), label: Text(s('kind_community'))),
          ],
          selected: {_community},
          onSelectionChanged: (v) => setState(() => _community = v.first),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: Text(_community ? s('community_hint') : s('group_hint'), style: context.tt.bodySmall),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(children: [
          Avatar(name: _name.text.isEmpty ? '#' : _name.text, size: 52, group: true),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _name,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(hintText: s('group_name_hint'), labelText: s('group_name')),
            ),
          ),
        ]),
      ),
      if (_selected.isNotEmpty)
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final p in _selected)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InputChip(
                    avatar: PeerAvatar(peer: p, size: 24, presence: false),
                    label: Text(contacts.nameOf(p).split(' ').last),
                    onDeleted: () => setState(() => _selected.remove(p)),
                  ),
                ),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: TextField(
          onChanged: (v) => setState(() => _q = foldText(v.trim())),
          decoration: InputDecoration(hintText: s('search_friends'), prefixIcon: const Icon(AppIcons.search, size: 20)),
        ),
      ),
      SectionLabel(s('members_selected', {'n': _selected.length})),
      Expanded(
        child: ListView.builder(
          itemCount: friends.length,
          itemBuilder: (_, i) {
            final c = friends[i];
            final sel = _selected.contains(c.peer);
            return CheckboxListTile(
              value: sel,
              onChanged: (_) => setState(() => sel ? _selected.remove(c.peer) : _selected.add(c.peer)),
              secondary: PeerAvatar(peer: c.peer, size: 38),
              title: Text(c.displayName),
              subtitle: Text(c.online ? s('online') : s.lastSeen(c.lastSeen, DateTime.now())),
              activeColor: LC.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
            );
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: GradientButton(
          label: _community ? s('create_community') : s('create_group'),
          icon: AppIcons.people,
          expand: true,
          busy: _busy,
          onPressed: can ? _create : null,
        ),
      ),
    ]);
  }
}

class _MemberPicker extends StatefulWidget {
  const _MemberPicker({required this.exclude});
  final Set<String> exclude;
  @override
  State<_MemberPicker> createState() => _MemberPickerState();
}

class _MemberPickerState extends State<_MemberPicker> {
  final _sel = <String>{};
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final friends = context.watch<ContactsStore>().friends.where((c) => !widget.exclude.contains(c.peer)).toList();
    return Column(children: [
      PaneHeader(title: Text(s('add_members')), onBack: () => Navigator.pop(context)),
      Expanded(
        child: friends.isEmpty
            ? EmptyState(icon: AppIcons.friends, title: s('no_more_friends'))
            : ListView.builder(
                itemCount: friends.length,
                itemBuilder: (_, i) {
                  final c = friends[i];
                  final sel = _sel.contains(c.peer);
                  return CheckboxListTile(
                    value: sel,
                    onChanged: (_) => setState(() => sel ? _sel.remove(c.peer) : _sel.add(c.peer)),
                    secondary: PeerAvatar(peer: c.peer, size: 36),
                    title: Text(c.displayName),
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: GradientButton(label: s('add'), expand: true, onPressed: _sel.isEmpty ? null : () => Navigator.pop(context, _sel.toList())),
      ),
    ]);
  }
}
