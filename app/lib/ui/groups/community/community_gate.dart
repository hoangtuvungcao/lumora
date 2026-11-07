// Community channels inside the chat view: the topic under the header, who
// may post (announcement-only channels, timeouts) and moderator deletes.

import 'dart:async';

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

/// The group whose permissions apply in [conv]: a community channel's
/// community, a plain group's own id (`g:<gid>`); null for other chats.
String? permGid(BuildContext context, String conv) {
  final hit = context.read<SpacesStore>().channelOf(conv);
  if (hit != null) return hit.$1.id;
  if (!conv.startsWith('g:') || conv.contains('#')) return null;
  return conv.substring(2);
}

/// I hold [perm] in [conv] (true while unknown, and outside groups).
bool convCan(BuildContext context, String conv, String perm) {
  final gid = permGid(context, conv);
  if (gid == null) return true;
  final g = CommunityStore.of(context.read<LumoraApi>()).info(gid);
  return g == null || g.myRole == 'none' || g.can(perm);
}

/// Shows [child] only when I hold [perm] in [conv] (shown while unknown).
class PermGate extends StatelessWidget {
  const PermGate({super.key, required this.conv, required this.perm, required this.child});
  final String conv;
  final String perm;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (permGid(context, conv) == null) return child;
    return ListenableBuilder(
      listenable: CommunityStore.of(context.read<LumoraApi>()),
      builder: (context, _) => convCan(context, conv, perm) ? child : const SizedBox.shrink(),
    );
  }
}

/// I may delete other people's messages for everyone in channel [conv]
/// (`manage_messages`; owner / admins).
bool canModerateMessages(BuildContext context, String conv) {
  final hit = context.read<SpacesStore>().channelOf(conv);
  if (hit == null) return false;
  return CommunityStore.of(context.read<LumoraApi>()).info(hit.$1.id)?.can(Perm.manageMessages) ?? false;
}

/// The channel's topic (else [fallback]) under its name in the header.
class ChannelTopic extends StatelessWidget {
  const ChannelTopic({super.key, required this.conv, required this.fallback});
  final String conv;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final topic = context.select<SpacesStore, String>((x) => x.channelOf(conv)?.$2.topic ?? '');
    if (topic.isEmpty) return Text(fallback);
    return Text(topic, key: const ValueKey('channel_topic'), maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}

/// In a community channel, replaces the composer when I may not post: an
/// announcement-only channel ("Chỉ quản trị viên được đăng") or a timeout
/// ("Bạn bị tạm cấm chat đến HH:mm", the composer comes back on its own).
class CommunityComposerGate extends StatefulWidget {
  const CommunityComposerGate({super.key, required this.conv, required this.child});
  final String conv;
  final Widget child;

  @override
  State<CommunityComposerGate> createState() => _CommunityComposerGateState();
}

class _CommunityComposerGateState extends State<CommunityComposerGate> {
  Timer? _expiry;

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  void _armExpiry(int untilMs) {
    _expiry?.cancel();
    final left = untilMs - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) return;
    _expiry = Timer(Duration(milliseconds: left + 50), () {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final hit = context.select<SpacesStore, (Space, Channel)?>((x) => x.channelOf(widget.conv));
    if (hit != null && hit.$2.voice) return widget.child;
    // a community channel, else a plain group (`g:<gid>`)
    final gid = hit?.$1.id ?? (widget.conv.startsWith('g:') && !widget.conv.contains('#') ? widget.conv.substring(2) : null);
    if (gid == null) return widget.child;
    final me = context.select<SessionStore, String>((x) => x.me?.peer ?? '');
    return CommunityBuilder(
      gid: gid,
      builder: (context, g) {
        final mine = g?.member(me);
        if (g == null || mine == null) return widget.child;
        final ch = g.channels.where((c) => c.conv == widget.conv).firstOrNull ??
            (hit == null ? null : g.channels.where((c) => c.name == hit.$2.name).firstOrNull) ??
            hit?.$2 ??
            Channel(id: '', name: '', voice: false, conv: widget.conv);
        final s = S.of(context);
        if (!g.isAdminish && mine.timedOut()) {
          _armExpiry(mine.timeoutUntil);
          return _Banner(
            key: const ValueKey('cm_gate_timeout'),
            icon: AppIcons.hourglass,
            color: LC.warning,
            title: s('cm_timed_out', {'time': timeLabel(mine.timeoutUntil)}),
            hint: s('cm_timed_out_hint'),
          );
        }
        _expiry?.cancel();
        if (g.canPostIn(ch, me)) return widget.child;
        final announce = ch.announce || g.adminsOnly;
        return _Banner(
          key: const ValueKey('cm_gate_announce'),
          icon: announce ? AppIcons.announce : AppIcons.lock,
          color: LC.primary,
          title: announce ? s('cm_announce_only') : s('cm_no_send'),
          hint: announce ? s('cm_announce_only_hint') : null,
        );
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.icon, required this.color, required this.title, this.hint});
  final IconData icon;
  final Color color;
  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: context.lc.surface,
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(color: context.lc.divider),
        ),
        child: Row(children: [
          IconTile(icon, color: color, circle: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              if (hint != null) Text(hint!, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall),
            ]),
          ),
        ]),
      ),
    );
  }
}
