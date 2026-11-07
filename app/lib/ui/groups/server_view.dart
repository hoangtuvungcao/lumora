// "Spaces" (servers): text + voice channels.

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../chats/chat_view.dart';
import 'community/community_channels.dart';
import 'community/community_gate.dart' show PermGate, convCan;
import 'community/community_common.dart';
import 'community/community_members.dart';
import 'community/community_settings.dart';
import 'create_group.dart';
import 'group_cover.dart';
import 'group_membership.dart' show leaveGroupFlow;
import 'invite.dart';
import '../theme.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/common.dart';

Space? _currentSpace(BuildContext context) {
  final id = context.select<NavStore, String?>((n) => n.spaceId);
  final spaces = context.select<SpacesStore, List<Space>>((s) => s.spaces);
  for (final s in spaces) {
    if (s.id == id) return s;
  }
  return spaces.isEmpty ? null : spaces.first;
}

/// Middle column on desktop: channel list of the selected space.
class SpaceChannelsPane extends StatelessWidget {
  const SpaceChannelsPane({super.key});

  @override
  Widget build(BuildContext context) {
    final sp = _currentSpace(context);
    if (sp == null) return const SizedBox.shrink();
    final selected = context.select<NavStore, String?>((n) => n.channelConv) ?? sp.channels.firstWhere((c) => !c.voice, orElse: () => sp.channels.first).conv;
    return ChannelList(
      space: sp,
      selected: selected,
      onOpen: (c) => context.read<NavStore>().openChannel(sp.id, c.conv),
    );
  }
}

class ChannelList extends StatefulWidget {
  const ChannelList({super.key, required this.space, required this.onOpen, this.selected, this.showBack = false, this.voiceBar = true});
  final Space space;
  final String? selected;
  final ValueChanged<Channel> onOpen;
  final bool showBack;

  /// The "Voice connected" bar at the foot (phones show the voice stage instead).
  final bool voiceBar;

  @override
  State<ChannelList> createState() => _ChannelListState();
}

class _ChannelListState extends State<ChannelList> {
  /// Collapsed categories (the selected channel and my voice room stay shown).
  final Set<String> _collapsed = {};

  Space get space => widget.space;
  String? get selected => widget.selected;
  ValueChanged<Channel> get onOpen => widget.onOpen;
  bool get showBack => widget.showBack;
  bool get voiceBar => widget.voiceBar;

  void _menu(Channel c, [Offset? at]) => showChannelMenu(context, space.id, c, at: at);

  Widget _channel(Channel c) {
    final tile = c.voice ? _VoiceChannel(channel: c) : _TextChannel(channel: c, selected: c.conv == selected, onTap: () => onOpen(c));
    return GestureDetector(
      key: ValueKey('channel_${c.conv}'),
      behavior: HitTestBehavior.translucent,
      onLongPress: () => _menu(c),
      onSecondaryTapUp: (d) => _menu(c, d.globalPosition),
      child: tile,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final cats = channelSections(space.channels);
    final joined = context.select<SpacesStore, String?>((x) => x.joinedVoice);
    final joinedName = voiceBar ? space.channels.where((c) => c.conv == joined).map((c) => c.name).firstOrNull : null;
    return Material(
      color: Colors.transparent,
      child: Column(children: [
        const _VoiceMovedToast(),
        if (space.hasCover)
          _CoverHeader(space: space, showBack: showBack)
        else
        Container(
          height: 60,
          padding: EdgeInsets.only(left: showBack ? 4 : 16, right: 8),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.lc.divider))),
          child: Row(children: [
            if (showBack) IconButton(tooltip: S.of(context)('back'), onPressed: () => Navigator.maybePop(context), icon: const Icon(AppIcons.back)),
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.sm),
                onTap: () => showSpaceSettings(context, space),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(space.name, style: context.tt.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(s('n_members', {'n': space.members}), style: context.tt.bodySmall),
                ]),
              ),
            ),
            PermGate(
              conv: 'g:${space.id}',
              perm: Perm.invite,
              child: ToolButton(key: const ValueKey('space_invite'), icon: AppIcons.addFriend, tooltip: s('invite'), onPressed: () => showInvite(context, gid: space.id, name: space.name)),
            ),
            ToolButton(
              key: const ValueKey('space_settings'),
              icon: AppIcons.settings,
              tooltip: s('space_settings'),
              onPressed: () => showSpaceSettings(context, space),
            ),
          ]),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.only(bottom: 12), children: [
            for (final (cat, list) in cats) ...[
              _CategoryHeader(
                label: cat.isEmpty ? s('channels') : cat,
                collapsed: _collapsed.contains(cat),
                onTap: () => setState(() => _collapsed.contains(cat) ? _collapsed.remove(cat) : _collapsed.add(cat)),
              ),
              for (final c in list)
                if (!_collapsed.contains(cat) || c.conv == selected || c.conv == joined) _channel(c),
            ],
          ]),
        ),
        AnimatedSize(
          duration: Motion.normal,
          curve: Motion.curve,
          child: joinedName == null
              ? const SizedBox(width: double.infinity)
              : Container(
                  padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: context.lc.divider))),
                  child: Row(children: [
                    const Icon(AppIcons.voice, color: LC.success, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(s('voice_connected'), style: context.tt.labelLarge?.copyWith(color: LC.success, fontWeight: FontWeight.w700)),
                        Text(joinedName, style: context.tt.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                    ToolButton(
                      key: const ValueKey('voice_disconnect'),
                      icon: AppIcons.hangUp,
                      tooltip: s('disconnect'),
                      color: LC.danger,
                      onPressed: () => leaveVoiceChannel(context),
                    ),
                  ]),
                ),
        ),
      ]),
    );
  }
}

/// The channel list's header when the community has a cover: the picture
/// as a banner, name and actions on a dark scrim at its foot.
class _CoverHeader extends StatelessWidget {
  const _CoverHeader({required this.space, required this.showBack});
  final Space space;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    const shadow = [Shadow(color: Color(0x99000000), blurRadius: 8)];
    return SizedBox(
      key: const ValueKey('space_cover'),
      height: 132,
      child: Stack(fit: StackFit.expand, children: [
        GroupCoverImage(gid: space.id, hasCover: space.hasCover, rev: space.coverRev),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x40000000), Color(0x00000000), Color(0xB3000000)],
              stops: [0, 0.35, 1],
            ),
          ),
        ),
        if (showBack)
          Positioned(
            left: 4,
            top: 4,
            child: IconButton(
              tooltip: s('back'),
              onPressed: () => Navigator.maybePop(context),
              icon: const Icon(AppIcons.back, color: Colors.white, shadows: shadow),
            ),
          ),
        Positioned(
          left: 16,
          right: 8,
          bottom: 8,
          child: Row(children: [
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.sm),
                onTap: () => showSpaceSettings(context, space),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(space.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.tt.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w700, shadows: shadow)),
                  Text(s('n_members', {'n': space.members}), style: context.tt.bodySmall?.copyWith(color: Colors.white.withValues(alpha: 0.85), shadows: shadow)),
                ]),
              ),
            ),
            PermGate(
              conv: 'g:${space.id}',
              perm: Perm.invite,
              child: ToolButton(
                  key: const ValueKey('space_invite'), icon: AppIcons.addFriend, tooltip: s('invite'), color: Colors.white, onPressed: () => showInvite(context, gid: space.id, name: space.name)),
            ),
            ToolButton(
              key: const ValueKey('space_settings'),
              icon: AppIcons.settings,
              tooltip: s('space_settings'),
              color: Colors.white,
              onPressed: () => showSpaceSettings(context, space),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// A collapsible category header of the channel list.
class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({required this.label, required this.collapsed, required this.onTap});
  final String label;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('category_$label'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 18, 12, 4),
        child: Row(children: [
          AnimatedRotation(
            turns: collapsed ? -0.25 : 0,
            duration: Motion.fast,
            child: Icon(AppIcons.chevronDown, size: 14, color: context.lc.muted),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.tt.labelSmall?.copyWith(color: context.lc.muted, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
          ),
        ]),
      ),
    );
  }
}

/// Lock (private) / megaphone (announcement) after a channel's name.
List<Widget> _channelBadges(BuildContext context, Channel c) => [
      // (a text announcement channel has the megaphone as its icon already)
      if (c.announce && c.voice) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(AppIcons.announce, size: 14, color: context.lc.muted)),
      if (c.private) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(AppIcons.lock, key: ValueKey('private_${c.conv}'), size: 13, color: context.lc.muted)),
    ];

class _TextChannel extends StatelessWidget {
  const _TextChannel({required this.channel, required this.selected, required this.onTap});
  final Channel channel;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final unread = channel.unread > 0 && !selected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? LC.primary.withValues(alpha: 0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.sm),
          hoverColor: context.lc.hover,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(children: [
              Icon(channel.announce ? AppIcons.announce : AppIcons.channel,
                  key: channel.announce ? ValueKey('announce_${channel.conv}') : null, size: 19, color: selected || unread ? context.lc.text : context.lc.muted),
              const SizedBox(width: 8),
              Flexible(
                child: Text(channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected || unread ? context.lc.text : context.lc.muted,
                      fontWeight: selected || unread ? FontWeight.w600 : FontWeight.w500,
                    )),
              ),
              ..._channelBadges(context, channel),
              const Spacer(),
              if (unread) CountBadge(channel.unread),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Join voice channel `conv` (leaving the one I'm in first), or leave it when
/// I'm in it already. Never rings anyone; errors show as a toast.
Future<void> toggleVoiceChannel(BuildContext context, String conv) async {
  final spaces = context.read<SpacesStore>();
  if (spaces.joinedVoice == conv) return leaveVoiceChannel(context);
  final calls = context.read<CallStore>();
  try {
    final micOk = await calls.prepareRoom();
    final id = await spaces.joinVoice(conv);
    if (!micOk && id != null) await calls.api.callSet(id, mic: false);
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

/// Leave the voice channel I'm in (errors show as a toast).
Future<void> leaveVoiceChannel(BuildContext context) async {
  try {
    await context.read<SpacesStore>().leaveVoice();
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

/// Speaking / microphone-off state of `account` in voice channel `conv`:
/// talking from the room call (`CallState.speaking`) or the `voice` event,
/// muted from the presence everyone sees, the per-peer media state, and — for
/// me — my own microphone switch.
({bool speaking, bool muted}) voiceParticipantState(BuildContext context, String conv, String account) {
  final spaces = context.watch<SpacesStore>();
  final calls = context.watch<CallStore>();
  final me = context.read<SessionStore>().me?.peer;
  final call = calls.call;
  final inCall = call != null && call.conv == conv && call.phase == CallPhase.active;
  final mineHere = account == me && spaces.joinedVoice == conv;
  final muted = (mineHere && inCall && !calls.mic) ||
      (!mineHere && (spaces.voiceMuted[conv]?.contains(account) ?? false)) ||
      (!mineHere && inCall && calls.accountMuted(account));
  final speaking = !muted && ((inCall && call.speakingAccount(account)) || (spaces.voiceSpeaking[conv]?.contains(account) ?? false));
  return (speaking: speaking, muted: muted);
}

class _VoiceChannel extends StatelessWidget {
  const _VoiceChannel({required this.channel});
  final Channel channel;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final parts = context.select<SpacesStore, List<String>>((x) => List.of(x.voice[channel.conv] ?? channel.participants));
    final joined = context.select<SpacesStore, bool>((x) => x.joinedVoice == channel.conv);
    final me = context.read<SessionStore>().me;
    final contacts = context.read<ContactsStore>();
    return Padding(
      key: ValueKey('voice_channel_${channel.conv}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Tooltip(
          message: joined ? s('leave_voice') : s('join_voice'),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            hoverColor: context.lc.hover,
            onTap: () => toggleVoiceChannel(context, channel.conv),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(children: [
                Icon(AppIcons.speaker, size: 19, color: joined ? LC.success : context.lc.muted),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: joined ? LC.success : context.lc.muted, fontWeight: FontWeight.w500)),
                ),
                ..._channelBadges(context, channel),
                const Spacer(),
                if (parts.isNotEmpty) Text('${parts.length}', key: ValueKey('voice_count_${channel.conv}'), style: context.tt.bodySmall),
              ]),
            ),
          ),
        ),
        for (final p in parts) _VoiceParticipant(conv: channel.conv, peer: p, name: p == me?.peer ? (me?.name ?? '') : contacts.nameOf(p)),
      ]),
    );
  }
}

class _VoiceParticipant extends StatelessWidget {
  const _VoiceParticipant({required this.conv, required this.peer, required this.name});
  final String conv;
  final String peer;
  final String name;

  @override
  Widget build(BuildContext context) {
    final st = voiceParticipantState(context, conv, peer);
    return Padding(
      key: ValueKey('voice_participant_${conv}_$peer'),
      padding: const EdgeInsets.fromLTRB(36, 2, 8, 4),
      child: Row(children: [
        PeerAvatar(peer: peer, size: 24, presence: false, ringColor: st.speaking ? LC.success : null),
        const SizedBox(width: 8),
        Expanded(
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall?.copyWith(color: st.speaking ? LC.success : context.lc.text)),
        ),
        if (st.muted)
          Icon(AppIcons.micOff, key: ValueKey('voice_muted_${conv}_$peer'), size: 14, color: context.lc.muted, semanticLabel: S.of(context)('mic_off')),
      ]),
    );
  }
}

/// Says once that the voice room moved to another of my devices.
class _VoiceMovedToast extends StatefulWidget {
  const _VoiceMovedToast();
  @override
  State<_VoiceMovedToast> createState() => _VoiceMovedToastState();
}

class _VoiceMovedToastState extends State<_VoiceMovedToast> {
  late final SpacesStore _spaces;

  @override
  void initState() {
    super.initState();
    _spaces = context.read<SpacesStore>()..addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _spaces.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final name = _spaces.movedElsewhere;
    if (name == null || !mounted) return;
    _spaces.clearMoved();
    final s = S.read(context);
    showTopToast(context, name.isEmpty ? s('voice_moved_elsewhere') : s('voice_moved_to', {'device': name}));
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Content area for a space on desktop: channel chat + member list.
class SpaceContent extends StatelessWidget {
  const SpaceContent({super.key});

  @override
  Widget build(BuildContext context) {
    final sp = _currentSpace(context);
    final s = S.of(context);
    if (sp == null) return EmptyState(icon: AppIcons.community, title: s('no_spaces'));
    final sel = context.select<NavStore, String?>((n) => n.channelConv);
    final ch = sp.channels.firstWhere((c) => c.conv == sel && !c.voice, orElse: () => sp.channels.firstWhere((c) => !c.voice));
    final wide = MediaQuery.sizeOf(context).width >= 1280;
    final joined = context.select<SpacesStore, String?>((x) => x.joinedVoice);
    final voiceCh = sp.channels.where((c) => c.voice && c.conv == joined).firstOrNull;
    return Row(children: [
      Expanded(
        child: Column(children: [
          // Voice stays connected above the text channel.
          AnimatedSize(
            duration: Motion.normal,
            curve: Motion.curve,
            child: voiceCh == null ? const SizedBox(width: double.infinity) : _VoiceStage(channel: voiceCh),
          ),
          Expanded(child: ChatView(key: ValueKey(ch.conv), conv: ch.conv, embedded: true, channelName: ch.name, spaceName: sp.name)),
        ]),
      ),
      if (wide)
        Container(
          width: 248,
          decoration: BoxDecoration(color: context.lc.surface, border: Border(left: BorderSide(color: context.lc.divider))),
          child: _MemberList(gid: sp.id),
        ),
    ]);
  }
}

/// The community's members: online ones grouped by their highest role, then
/// those without a role, then everyone offline. Names in their role colour.
class _MemberList extends StatelessWidget {
  const _MemberList({required this.gid});
  final String gid;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final contacts = context.watch<ContactsStore>();
    final me = context.read<SessionStore>().me?.peer;
    return CommunityBuilder(
      gid: gid,
      builder: (context, g) {
        if (g == null) return const SizedBox.shrink();
        bool online(GroupMember m) => m.peer == me || (contacts[m.peer]?.online ?? m.online ?? false);
        String name(GroupMember m) => contacts[m.peer]?.displayName ?? m.name;
        int byName(GroupMember a, GroupMember b) => name(a).toLowerCase().compareTo(name(b).toLowerCase());
        final groups = <String, List<GroupMember>>{};
        final plain = <GroupMember>[], off = <GroupMember>[];
        for (final m in g.members) {
          if (!online(m)) {
            off.add(m);
          } else if (g.topRole(m) case final r?) {
            (groups[r.id] ??= []).add(m);
          } else {
            plain.add(m);
          }
        }
        Widget tile(GroupMember m, bool isOn) => InkWell(
              key: ValueKey('member_${m.peer}'),
              onTap: () => showMemberSheet(context, gid, m.peer),
              child: Opacity(
                opacity: isOn ? 1 : 0.5,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  child: Row(children: [
                    PeerAvatar(peer: m.peer, fallbackName: m.name, size: 32),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(name(m),
                          key: ValueKey('member_name_${m.peer}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w500, color: memberColor(g, m))),
                    ),
                    if (m.timedOut()) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(AppIcons.hourglass, size: 14, color: context.lc.muted)),
                    if (m.role == 'owner') const Icon(AppIcons.owner, size: 16, color: LC.warning),
                  ]),
                ),
              ),
            );
        Widget label(String t, int n) => SectionLabel('${t.toUpperCase()} — $n', padding: const EdgeInsets.fromLTRB(16, 14, 16, 6));
        return ListView(padding: const EdgeInsets.only(top: 4, bottom: 12), children: [
          for (final r in g.roles)
            if (groups[r.id] case final list?) ...[
              label(roleName(s, r), list.length),
              for (final m in list..sort(byName)) tile(m, true),
            ],
          if (plain.isNotEmpty) ...[
            label(s('online'), plain.length),
            for (final m in plain..sort(byName)) tile(m, true),
          ],
          if (off.isNotEmpty) ...[
            label(s('offline'), off.length),
            for (final m in off..sort(byName)) tile(m, false),
          ],
        ]);
      },
    );
  }
}

/// Mobile: list of spaces → channel list → chat.
class SpacesMobileScreen extends StatelessWidget {
  const SpacesMobileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final spaces = context.watch<SpacesStore>().spaces;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
        child: Row(children: [
          Expanded(child: Text(s('spaces'), style: context.tt.titleLarge)),
          ToolButton(icon: AppIcons.explore, tooltip: s('join_by_link'), onPressed: () => showJoinByLink(context)),
          ToolButton(icon: AppIcons.add, tooltip: s('create_space'), onPressed: () => showCreateGroup(context, community: true)),
        ]),
      ),
      Expanded(
        child: spaces.isEmpty
            ? EmptyState(icon: AppIcons.community, title: s('no_spaces'), subtitle: s('no_spaces_hint'))
            : ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: spaces.length,
                itemBuilder: (_, i) {
                  final sp = spaces[i];
                  final unread = sp.channels.fold(0, (a, c) => a + c.unread);
                  final voice = context.read<SpacesStore>().inVoice(sp);
                  void open() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _MobileChannels(space: sp)));
                  final tile = ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    leading: GroupAvatar(gid: sp.id, name: sp.name, size: 48),
                    title: Text(sp.name, style: context.tt.titleMedium),
                    subtitle: Text('${s('n_members', {'n': sp.members})}${voice > 0 ? ' · ${s('n_in_voice', {'n': voice})}' : ''}'),
                    trailing: CountBadge(unread),
                    onTap: open,
                    onLongPress: () => showSpaceMenu(context, sp),
                  );
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: LCard(
                      padding: EdgeInsets.zero,
                      child: !sp.hasCover
                          ? tile
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(Radii.lg),
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                // the cover as the card's banner
                                GestureDetector(
                                  key: ValueKey('space_card_cover_${sp.id}'),
                                  onTap: open,
                                  onLongPress: () => showSpaceMenu(context, sp),
                                  child: SizedBox(
                                    height: 92,
                                    width: double.infinity,
                                    child: Stack(fit: StackFit.expand, children: [
                                      GroupCoverImage(gid: sp.id, hasCover: sp.hasCover, rev: sp.coverRev),
                                      const DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0x33000000)]),
                                        ),
                                      ),
                                    ]),
                                  ),
                                ),
                                tile,
                              ]),
                            ),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}

class _MobileChannels extends StatefulWidget {
  const _MobileChannels({required this.space});
  final Space space;
  @override
  State<_MobileChannels> createState() => _MobileChannelsState();
}

class _MobileChannelsState extends State<_MobileChannels> {
  late final SpacesStore _spaces;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _spaces = context.read<SpacesStore>()..addListener(_onSpaces);
  }

  @override
  void dispose() {
    _spaces.removeListener(_onSpaces);
    super.dispose();
  }

  /// Left / deleted (here or elsewhere): close this page and what's on top of it.
  void _onSpaces() {
    if (_closing || _spaces.byId(widget.space.id) != null) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      final navigator = Navigator.of(context);
      navigator.popUntil((r) => r == route || r.isFirst);
      if (route.isCurrent && !route.isFirst) navigator.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    // the live copy: a new cover / name shows at once
    final space = context.select<SpacesStore, Space?>((x) => x.byId(widget.space.id)) ?? widget.space;
    final joined = context.select<SpacesStore, String?>((x) => x.joinedVoice);
    final voiceCh = space.channels.where((c) => c.voice && c.conv == joined).firstOrNull;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ChannelList(
              space: space,
              showBack: true,
              voiceBar: false,
              onOpen: (c) => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => ChatView(conv: c.conv, channelName: c.name, spaceName: space.name),
              )),
            ),
          ),
          // the room I'm in: who is there, mic, leave (tap: the full call screen)
          AnimatedSize(
            duration: Motion.normal,
            curve: Motion.curve,
            child: voiceCh == null ? const SizedBox(width: double.infinity) : _VoiceStage(channel: voiceCh, compact: true),
          ),
        ]),
      ),
    );
  }
}


class _VoiceStage extends StatelessWidget {
  const _VoiceStage({required this.channel, this.compact = false});
  final Channel channel;

  /// Phones: two rows (people under the controls) and the call screen on tap.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final parts = context.select<SpacesStore, List<String>>((x) => List.of(x.voice[channel.conv] ?? channel.participants));
    final calls = context.watch<CallStore>();
    final inRoom = calls.call?.conv == channel.conv;
    final me = context.read<SessionStore>().me?.peer ?? '';
    final contacts = context.read<ContactsStore>();
    final avatars = SizedBox(
      height: 44,
      child: ListView(scrollDirection: Axis.horizontal, children: [
        for (final p in parts) _StageAvatar(key: ValueKey('voice_stage_$p'), conv: channel.conv, peer: p, name: contacts.nameOf(p, me: me, meName: s('you'))),
      ]),
    );
    final mic = ToolButton(
      key: const ValueKey('voice_stage_mic'),
      icon: calls.mic ? AppIcons.mic : AppIcons.micOff,
      tooltip: calls.mic ? s('mute_mic') : s('unmute_mic'),
      active: !calls.mic,
      onPressed: inRoom ? () => calls.toggle(mic: !calls.mic) : null,
    );
    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(channel.name, style: context.tt.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
      Text(s('n_in_voice', {'n': parts.length}), key: const ValueKey('voice_stage_count'), style: context.tt.bodySmall),
    ]);
    final decoration = BoxDecoration(
      gradient: LinearGradient(colors: [LC.success.withValues(alpha: 0.12), LC.accent.withValues(alpha: 0.06)]),
      border: Border(
        bottom: compact ? BorderSide.none : BorderSide(color: context.lc.divider),
        top: compact ? BorderSide(color: context.lc.divider) : BorderSide.none,
      ),
    );
    if (compact) {
      return InkWell(
        key: const ValueKey('voice_stage'),
        onTap: inRoom ? () => calls.setMinimized(false) : null,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          decoration: decoration,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Icon(AppIcons.voice, color: LC.success),
              const SizedBox(width: 10),
              Expanded(child: title),
              mic,
              ToolButton(
                key: const ValueKey('voice_stage_leave'),
                icon: AppIcons.hangUp,
                tooltip: s('disconnect'),
                color: LC.danger,
                onPressed: () => leaveVoiceChannel(context),
              ),
            ]),
            if (parts.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: avatars),
          ]),
        ),
      );
    }
    return Container(
      key: const ValueKey('voice_stage'),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: decoration,
      child: Row(children: [
        const Icon(AppIcons.voice, color: LC.success),
        const SizedBox(width: 10),
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 200), child: title),
        const SizedBox(width: 16),
        Expanded(child: avatars),
        mic,
        ToolButton(
          icon: AppIcons.screenShare,
          tooltip: s('share_screen'),
          active: calls.screen,
          onPressed: inRoom ? () => calls.toggle(screen: !calls.screen) : null,
        ),
        const SizedBox(width: 4),
        FilledButton.icon(
          key: const ValueKey('voice_stage_leave'),
          onPressed: () => leaveVoiceChannel(context),
          style: FilledButton.styleFrom(backgroundColor: LC.danger, minimumSize: const Size(0, 36)),
          icon: const Icon(AppIcons.hangUp, size: 16),
          label: Text(s('disconnect')),
        ),
      ]),
    );
  }
}

class _StageAvatar extends StatelessWidget {
  const _StageAvatar({super.key, required this.conv, required this.peer, required this.name});
  final String conv;
  final String peer;
  final String name;

  @override
  Widget build(BuildContext context) {
    final st = voiceParticipantState(context, conv, peer);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(
        message: name,
        child: Stack(clipBehavior: Clip.none, children: [
          AnimatedContainer(
            duration: Motion.fast,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: st.speaking ? LC.success : Colors.transparent, width: 2.5)),
            child: PeerAvatar(peer: peer, size: 36, presence: false),
          ),
          if (st.muted)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(color: context.lc.surface, shape: BoxShape.circle),
                child: Icon(AppIcons.micOff, size: 12, color: LC.danger, semanticLabel: S.of(context)('mic_off')),
              ),
            ),
        ]),
      ),
    );
  }
}


/// A community's picture, name, description, members and admin settings (the group info
/// screen: a community is a group with channels).
Future<void> showSpaceSettings(BuildContext context, Space space) => showCommunitySettings(context, space.id);


/// Long-press / right-click on a community: settings, invite, leave.
Future<void> showSpaceMenu(BuildContext context, Space space, {Offset? at}) async {
  final s = S.read(context);
  final items = [
    ('settings', AppIcons.settings, s('space_settings')),
    if (convCan(context, 'g:${space.id}', Perm.invite)) ('invite', AppIcons.addFriend, s('invite')),
    ('leave', AppIcons.signOut, s('leave_space')),
    if (space.isOwner) ('delete', AppIcons.delete, s('delete_space')),
  ];
  bool danger(String id) => id == 'leave' || id == 'delete';
  String? r;
  if (at != null) {
    r = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        for (final it in items)
          PopupMenuItem(
            value: it.$1,
            child: Row(children: [
              Icon(it.$2, size: 18, color: danger(it.$1) ? LC.danger : null),
              const SizedBox(width: 12),
              Text(it.$3, style: danger(it.$1) ? const TextStyle(color: LC.danger) : null),
            ]),
          ),
      ],
    );
  } else {
    r = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(space.name, style: c.tt.titleMedium)),
          for (final it in items)
            ListTile(
              key: ValueKey('space_menu_${it.$1}'),
              leading: Icon(it.$2, color: danger(it.$1) ? LC.danger : null),
              title: Text(it.$3, style: danger(it.$1) ? const TextStyle(color: LC.danger) : null),
              onTap: () => Navigator.pop(c, it.$1),
            ),
        ]),
      ),
    );
  }
  if (!context.mounted) return;
  switch (r) {
    case 'settings':
      await showSpaceSettings(context, space);
    case 'invite':
      await showInvite(context, gid: space.id, name: space.name);
    case 'leave':
      await leaveSpace(context, space);
    case 'delete':
      await dissolveGroup(context, gid: space.id, name: space.name, community: true);
  }
}

/// Leave a community (confirmed): it leaves the list at once; the core deletes its channels.
Future<void> leaveSpace(BuildContext context, Space space) async {
  final s = S.read(context);
  final spaces = context.read<SpacesStore>();
  final nav = context.read<NavStore>();
  // the owner first hands the community over (pick the new owner)
  if (!await leaveGroupFlow(context, space.id, title: s('leave_space'), body: s('leave_space_body', {'name': space.name}))) return;
  spaces.forget(space.id);
  if (nav.section == Section.space && nav.spaceId == space.id) nav.go(Section.chats);
  if (context.mounted) toast(context, s('left_space', {'name': space.name}));
}
