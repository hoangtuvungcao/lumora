// Who sees my Khoảnh khắc: the audience picker of the composer ("Bạn bè" / "Bạn thân"),
// the "hide from" and close friends lists (Settings › Privacy) and their friend picker.
// The lists live in the core's synced settings, so all my devices agree.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/text_fold.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/peer_avatar.dart';
import 'stories.dart' show showStoryArchive;

/// Audience of a new Khoảnh khắc: every friend not hidden, or close friends only.
const kStoryFriends = 'friends';
const kStoryClose = 'close';

/// Friends still on [ids] (someone unfriended later is left out of counts and lists).
List<String> _friendsIn(BuildContext context, List<String> ids) {
  final friends = {for (final c in context.read<ContactsStore>().friends) c.peer};
  return ids.where(friends.contains).toList();
}

/// Bottom sheet of the composer: pick "Bạn bè" or "Bạn thân" (and edit both lists).
/// Returns the chosen audience, or null when dismissed.
Future<String?> showStoryAudienceSheet(BuildContext context, String current) => showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 480),
      builder: (_) => _AudienceSheet(current: current),
    );

class _AudienceSheet extends StatelessWidget {
  const _AudienceSheet({required this.current});
  final String current;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = context.watch<StoryStore>();
    context.watch<ContactsStore>();
    final hidden = _friendsIn(context, st.hidden).length;
    final close = _friendsIn(context, st.close).length;
    Widget option(String value, IconData icon, Color color, String title, String sub, {Widget? edit}) {
      final sel = current == value;
      return ListTile(
        key: ValueKey('audience_$value'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
        leading: CircleAvatar(radius: 20, backgroundColor: color.withValues(alpha: 0.14), child: Icon(icon, color: color, size: 20)),
        title: Text(title, style: context.tt.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text(sub, style: context.tt.bodySmall),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          ?edit,
          Icon(sel ? AppIcons.radioOn : AppIcons.radioOff, color: sel ? LC.primary : context.lc.muted, size: 22),
        ]),
        onTap: () async {
          // close friends picked with nobody on the list yet: choose them first
          if (value == kStoryClose && close == 0) {
            final ok = await editCloseFriends(context);
            if (!ok || !context.mounted || _friendsIn(context, context.read<StoryStore>().close).isEmpty) return;
          }
          if (context.mounted) Navigator.pop(context, value);
        },
      );
    }

    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 2),
          child: Text(s('mo_audience_title'), style: context.tt.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
          child: Text(s('mo_audience_hint'), style: context.tt.bodySmall),
        ),
        option(
          kStoryFriends,
          AppIcons.friends,
          LC.primary,
          s('mo_aud_friends'),
          hidden == 0 ? s('mo_aud_friends_all') : s('mo_aud_friends_except', {'n': hidden}),
        ),
        option(
          kStoryClose,
          AppIcons.sparkle,
          LC.success,
          s('mo_aud_close'),
          close == 0 ? s('mo_close_none') : s('mo_n_people', {'n': close}),
          edit: close == 0
              ? null
              : TextButton(key: const ValueKey('audience_edit_close'), onPressed: () => editCloseFriends(context), child: Text(s('edit'))),
        ),
        const Divider(height: 20),
        ListTile(
          key: const ValueKey('audience_hidden'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20),
          leading: Icon(AppIcons.hide, color: context.lc.muted),
          title: Text(s('mo_hide_from')),
          subtitle: Text(hidden == 0 ? s('mo_hidden_none') : s('mo_n_people', {'n': hidden}), style: context.tt.bodySmall),
          trailing: const Icon(AppIcons.chevronRight, size: 18),
          onTap: () => editHiddenFrom(context),
        ),
        const SizedBox(height: 8),
      ]),
    );
  }
}

/// Friend picker for the hidden list; true when saved.
Future<bool> editHiddenFrom(BuildContext context) async {
  final s = S.read(context);
  final st = context.read<StoryStore>();
  if (!st.audienceLoaded) await st.loadAudience();
  if (!context.mounted) return false;
  final picked = await pickFriends(context, title: s('mo_hide_from'), hint: s('mo_hide_from_hint'), selected: _friendsIn(context, st.hidden).toSet());
  if (picked == null || !context.mounted) return false;
  return _save(context, () => st.setAudience(hidden: picked));
}

/// Friend picker for the close friends list; true when saved.
Future<bool> editCloseFriends(BuildContext context) async {
  final s = S.read(context);
  final st = context.read<StoryStore>();
  if (!st.audienceLoaded) await st.loadAudience();
  if (!context.mounted) return false;
  final picked = await pickFriends(context, title: s('mo_close_friends'), hint: s('mo_close_friends_hint'), selected: _friendsIn(context, st.close).toSet());
  if (picked == null || !context.mounted) return false;
  return _save(context, () => st.setAudience(close: picked));
}

Future<bool> _save(BuildContext context, Future<void> Function() save) async {
  try {
    await save(); // (the counts on screen change at once: no toast over the sheet)
    return true;
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return false;
  }
}

/// Multi-select of friends, [selected] ticked at first. Returns the new selection
/// (possibly empty), or null when cancelled.
Future<List<String>?> pickFriends(BuildContext context, {required String title, String? hint, Set<String> selected = const {}}) {
  final page = _FriendPicker(title: title, hint: hint, selected: selected);
  if (isDesktop(context)) {
    return showDialog<List<String>>(context: context, builder: (_) => Dialog(clipBehavior: Clip.antiAlias, child: SizedBox(width: 440, height: 600, child: page)));
  }
  return Navigator.of(context, rootNavigator: true).push<List<String>>(
    MaterialPageRoute(builder: (_) => Scaffold(body: SafeArea(child: page))),
  );
}

class _FriendPicker extends StatefulWidget {
  const _FriendPicker({required this.title, required this.selected, this.hint});
  final String title;
  final String? hint;
  final Set<String> selected;
  @override
  State<_FriendPicker> createState() => _FriendPickerState();
}

class _FriendPickerState extends State<_FriendPicker> {
  late final _sel = {...widget.selected};
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final all = context.watch<ContactsStore>().friends..sort((a, b) => foldText(a.displayName).compareTo(foldText(b.displayName)));
    final friends = all.where((c) => _q.isEmpty || foldText(c.displayName).contains(_q)).toList();
    return Material(
      color: context.lc.bg,
      child: Column(children: [
        PaneHeader(
          title: Text(widget.title),
          subtitle: Text(s('mo_n_selected', {'n': _sel.length})),
          onBack: () => Navigator.pop(context),
          actions: [
            if (_sel.isNotEmpty)
              TextButton(key: const ValueKey('picker_clear'), onPressed: () => setState(_sel.clear), child: Text(s('mo_clear_all'))),
          ],
        ),
        if (widget.hint != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Text(widget.hint!, style: context.tt.bodySmall),
          ),
        if (all.length > 6)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: TextField(
              onChanged: (v) => setState(() => _q = foldText(v.trim())),
              decoration: InputDecoration(hintText: s('search_friends'), prefixIcon: const Icon(AppIcons.search, size: 20)),
            ),
          ),
        Expanded(
          child: all.isEmpty
              ? EmptyState(icon: AppIcons.friends, title: s('mo_no_friends'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: friends.length,
                  itemBuilder: (_, i) {
                    final c = friends[i];
                    final sel = _sel.contains(c.peer);
                    return CheckboxListTile(
                      key: ValueKey('pick_${c.peer}'),
                      value: sel,
                      onChanged: (_) => setState(() => sel ? _sel.remove(c.peer) : _sel.add(c.peer)),
                      secondary: PeerAvatar(peer: c.peer, size: 38, presence: false),
                      title: Text(c.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
                      activeColor: LC.primary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: GradientButton(
            key: const ValueKey('picker_done'),
            label: s('save'),
            expand: true,
            onPressed: () => Navigator.pop(context, _sel.toList()),
          ),
        ),
      ]),
    );
  }
}

/// Settings › Privacy › "Khoảnh khắc của bạn": the hidden list and close friends.
class StoryPrivacyRows extends StatefulWidget {
  const StoryPrivacyRows({super.key});
  @override
  State<StoryPrivacyRows> createState() => _StoryPrivacyRowsState();
}

class _StoryPrivacyRowsState extends State<StoryPrivacyRows> {
  @override
  void initState() {
    super.initState();
    final st = context.read<StoryStore>();
    if (!st.audienceLoaded) st.loadAudience();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = context.watch<StoryStore>();
    context.watch<ContactsStore>();
    final hidden = _friendsIn(context, st.hidden).length;
    final close = _friendsIn(context, st.close).length;
    Widget row(Key key, IconData icon, String title, String sub, VoidCallback onTap) => ListTile(
          key: key,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: RowIcon(icon),
          title: Text(title, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
          subtitle: Text(sub, style: context.tt.bodySmall),
          trailing: const Icon(AppIcons.chevronRight, size: 18),
          onTap: onTap,
        );
    return Column(children: [
      row(const ValueKey('story_hidden_row'), AppIcons.hide, s('mo_hide_from'),
          hidden == 0 ? s('mo_hidden_none') : s('mo_n_people', {'n': hidden}), () => editHiddenFrom(context)),
      row(const ValueKey('story_close_row'), AppIcons.sparkle, s('mo_close_friends'),
          close == 0 ? s('mo_close_none') : s('mo_n_people', {'n': close}), () => editCloseFriends(context)),
      row(const ValueKey('story_archive_row'), AppIcons.archive, s('story_archive'), s('mo_archive_sub'), () => showStoryArchive(context)),
    ]);
  }
}
