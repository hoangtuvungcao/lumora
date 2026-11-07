// Plain group calls don't ring everyone:
//  * starting one asks who should ring (optional; nobody by default) —
//    everyone else sees a "Join" banner on the group's chat;
//  * a call that didn't ring me shows that banner here (state/group_calls.dart),
//    and a small call mark on the group's row in the chat list.
// Communities use voice channels (drop-in rooms) and direct chats ring as before.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/group_calls.dart';
import '../../state/stores.dart';
import '../theme.dart';
import '../widgets/app_icons.dart';
import '../widgets/common.dart';
import '../widgets/peer_avatar.dart';

/// [conv] is a plain group's chat (not a community, a channel or a voice room).
bool isPlainGroupConv(BuildContext context, String conv) {
  if (!conv.startsWith('g:') || conv.contains('#')) return false;
  if (context.read<ChatStore>().convs[conv]?.isCommunity ?? false) return false;
  final spaces = context.read<SpacesStore>();
  if (spaces.byId(conv.substring(2)) != null) return false;
  return !spaces.spaces.any((sp) => sp.channels.any((ch) => ch.conv == conv));
}

/// Starting a call in a plain group: who rings (null = cancelled, [] = nobody).
Future<List<String>?> pickGroupRing(BuildContext context, String conv, {bool video = false}) async {
  final api = context.read<LumoraApi>();
  final me = context.read<SessionStore>().me?.peer ?? '';
  GroupInfo? g;
  try {
    g = await api.groupInfo(conv.substring(2));
  } catch (_) {}
  if (!context.mounted) return null;
  final bots = {for (final b in g?.bots ?? const <(String, bool)>[]) b.$1};
  final members = [for (final m in g?.members ?? const <GroupMember>[]) if (m.peer != me && !bots.contains(m.peer)) m];
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 520),
    builder: (_) => _RingPicker(members: members, video: video),
  );
}

class _RingPicker extends StatefulWidget {
  const _RingPicker({required this.members, required this.video});
  final List<GroupMember> members;
  final bool video;
  @override
  State<_RingPicker> createState() => _RingPickerState();
}

class _RingPickerState extends State<_RingPicker> {
  final Set<String> _ring = {};

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final contacts = context.watch<ContactsStore>();
    final all = _ring.length == widget.members.length && widget.members.isNotEmpty;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Column(key: const ValueKey('group_ring_picker'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Row(children: [
              IconTile(widget.video ? AppIcons.video : AppIcons.call, circle: true),
              const SizedBox(width: 12),
              Expanded(child: Text(s(widget.video ? 'gc_pick_title_video' : 'gc_pick_title'), style: context.tt.titleMedium)),
            ]),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(20, 6, 20, 6), child: Text(s('gc_pick_hint'), style: context.tt.bodySmall)),
          if (widget.members.length > 1)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: TextButton(
                  onPressed: () => setState(() => all ? _ring.clear() : _ring.addAll(widget.members.map((m) => m.peer))),
                  child: Text(all ? s('mo_clear_all') : s('gc_select_all')),
                ),
              ),
            ),
          Flexible(
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              for (final m in widget.members)
                CheckboxListTile(
                  key: ValueKey('group_ring_${m.peer}'),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
                  value: _ring.contains(m.peer),
                  onChanged: (v) => setState(() => v == true ? _ring.add(m.peer) : _ring.remove(m.peer)),
                  secondary: PeerAvatar(peer: m.peer, fallbackName: m.name, size: 38),
                  title: Text(contacts[m.peer]?.displayName ?? m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('group_ring_quiet'),
                  onPressed: () => Navigator.pop(context, const <String>[]),
                  child: Text(s('gc_start_quiet'), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('group_ring_go'),
                  onPressed: _ring.isEmpty ? null : () => Navigator.pop(context, _ring.toList()),
                  icon: const Icon(AppIcons.bellRinging, size: 18),
                  label: Text(s('gc_ring_n', {'n': _ring.length}), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Starts a call in [conv]; a plain group first asks who should ring.
Future<void> startCallIn(BuildContext context, String conv, {bool video = false}) async {
  final calls = context.read<CallStore>();
  List<String>? ring;
  if (isPlainGroupConv(context, conv)) {
    ring = await pickGroupRing(context, conv, video: video);
    if (ring == null) return;
  }
  try {
    await calls.start(conv, video: video, ring: ring);
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

/// "{name} started a group call · Join" above a group's messages, while a
/// call that didn't ring me goes on there.
class GroupCallBanner extends StatelessWidget {
  const GroupCallBanner({super.key, required this.conv});
  final String conv;

  @override
  Widget build(BuildContext context) {
    final store = AvailableCalls.of(context.read<LumoraApi>());
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final c = store.forConv(conv);
        final inIt = context.select<CallStore, bool>((x) => c != null && x.call?.callId == c.callId);
        return AnimatedSize(
          duration: Motion.fast,
          alignment: Alignment.topCenter,
          child: c == null || inIt ? const SizedBox(width: double.infinity) : _Banner(call: c),
        );
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.call});
  final CallState call;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final contacts = context.watch<ContactsStore>();
    final from = call.peer;
    final name = call.names[from] ?? contacts.nameOf(from);
    final n = call.participants.length;
    return Padding(
      key: const ValueKey('group_call_banner'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [LC.success.withValues(alpha: 0.22), LC.accent.withValues(alpha: 0.14)]),
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(color: LC.success.withValues(alpha: 0.45)),
        ),
        // a phone: the Join button gets its own row so the caller's name stays readable
        child: LayoutBuilder(builder: (context, box) {
          final narrow = box.maxWidth < 440;
          final mark = Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(color: LC.success, shape: BoxShape.circle),
            child: Icon(call.video ? AppIcons.video : AppIcons.call, color: Colors.white, size: 20),
          );
          final text = Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s(call.video ? 'gc_available_video' : 'gc_available', {'name': name}),
                  maxLines: narrow ? 2 : 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
              if (n > 0) Text(s('gc_in_call', {'n': n}), maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall),
            ]),
          );
          final dismiss = IconButton(
            key: const ValueKey('group_call_dismiss'),
            tooltip: s('gc_dismiss'),
            icon: Icon(AppIcons.close, size: 18, color: context.lc.muted),
            onPressed: () => AvailableCalls.of(context.read<LumoraApi>()).dismiss(call.conv),
          );
          final join = FilledButton.icon(
            key: const ValueKey('group_call_join'),
            style: FilledButton.styleFrom(backgroundColor: LC.success, foregroundColor: Colors.white, visualDensity: VisualDensity.compact),
            onPressed: () {
              final calls = context.read<CallStore>();
              AvailableCalls.of(context.read<LumoraApi>()).joined(call.conv);
              calls.joinAvailable(call);
            },
            icon: Icon(call.video ? AppIcons.video : AppIcons.call, size: 16),
            label: Text(s('gc_join')),
          );
          if (!narrow) return Row(children: [mark, const SizedBox(width: 12), text, dismiss, join]);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [mark, const SizedBox(width: 12), text, dismiss]),
            const SizedBox(height: 8),
            join,
          ]);
        }),
      ),
    );
  }
}

/// A small green call mark on a group's row in the chat list while a call I
/// may join goes on there.
class GroupCallMark extends StatelessWidget {
  const GroupCallMark({super.key, required this.conv});
  final String conv;

  @override
  Widget build(BuildContext context) {
    if (!conv.startsWith('g:')) return const SizedBox.shrink();
    final store = AvailableCalls.of(context.read<LumoraApi>());
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final c = store.forConv(conv);
        if (c == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Tooltip(
            message: S.of(context)('gc_ongoing'),
            child: Container(
              key: ValueKey('group_call_mark_$conv'),
              padding: const EdgeInsets.all(3),
              decoration: const BoxDecoration(color: LC.success, shape: BoxShape.circle),
              child: Icon(c.video ? AppIcons.video : AppIcons.call, size: 11, color: Colors.white),
            ),
          ),
        );
      },
    );
  }
}
