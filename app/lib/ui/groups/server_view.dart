// Discord-like "spaces" (servers): text + voice channels.

import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../l10n/strings.dart';
import '../../state/stores.dart';
import '../chats/chat_view.dart';
import 'create_group.dart';
import 'invite.dart';
import '../theme.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/common.dart';
import '../profile/profile_screen.dart';

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

class ChannelList extends StatelessWidget {
  const ChannelList({super.key, required this.space, required this.onOpen, this.selected, this.showBack = false});
  final Space space;
  final String? selected;
  final ValueChanged<Channel> onOpen;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final cats = <String, List<Channel>>{};
    for (final c in space.channels) {
      (cats[c.category] ??= []).add(c);
    }
    final joined = context.select<SpacesStore, String?>((x) => x.joinedVoice);
    final joinedName = space.channels.where((c) => c.conv == joined).map((c) => c.name).firstOrNull;
    return Material(
      color: Colors.transparent,
      child: Column(children: [
        Container(
          height: 60,
          padding: EdgeInsets.only(left: showBack ? 4 : 16, right: 8),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.lc.divider))),
          child: Row(children: [
            if (showBack) IconButton(tooltip: S.of(context)('back'), onPressed: () => Navigator.maybePop(context), icon: const Icon(AppIcons.back)),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(space.name, style: context.tt.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(s('n_members', {'n': space.members}), style: context.tt.bodySmall),
              ]),
            ),
            ToolButton(icon: AppIcons.addFriend, tooltip: s('invite'), onPressed: () => showInvite(context, gid: space.id, name: space.name)),
          ]),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.only(bottom: 12), children: [
            for (final e in cats.entries) ...[
              SectionLabel(e.key.isEmpty ? s('channels') : e.key, padding: const EdgeInsets.fromLTRB(16, 18, 12, 4)),
              for (final c in e.value)
                c.voice ? _VoiceChannel(channel: c) : _TextChannel(channel: c, selected: c.conv == selected, onTap: () => onOpen(c)),
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
                      icon: AppIcons.hangUp,
                      tooltip: s('disconnect'),
                      color: LC.danger,
                      onPressed: () {
                        final calls = context.read<CallStore>();
                        if (calls.call?.conv == joined) calls.hangup();
                        context.read<SpacesStore>().toggleVoice(joined!, context.read<SessionStore>().me?.peer ?? '');
                      },
                    ),
                  ]),
                ),
        ),
      ]),
    );
  }
}

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
              Icon(AppIcons.channel, size: 19, color: selected || unread ? context.lc.text : context.lc.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected || unread ? context.lc.text : context.lc.muted,
                      fontWeight: selected || unread ? FontWeight.w600 : FontWeight.w500,
                    )),
              ),
              if (unread) CountBadge(channel.unread),
            ]),
          ),
        ),
      ),
    );
  }
}

class _VoiceChannel extends StatelessWidget {
  const _VoiceChannel({required this.channel});
  final Channel channel;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final parts = context.select<SpacesStore, List<String>>((x) => List.of(x.voice[channel.conv] ?? const []));
    final joined = context.select<SpacesStore, bool>((x) => x.joinedVoice == channel.conv);
    final me = context.read<SessionStore>().me;
    final contacts = context.read<ContactsStore>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Tooltip(
          message: joined ? s('leave_voice') : s('join_voice'),
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.sm),
            hoverColor: context.lc.hover,
            onTap: () {
              final calls = context.read<CallStore>();
              context.read<SpacesStore>().toggleVoice(channel.conv, me?.peer ?? '');
              if (joined) {
                if (calls.call?.conv == channel.conv) calls.hangup();
              } else {
                calls.start(channel.conv, minimized: true).catchError((_) {});
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(children: [
                Icon(AppIcons.speaker, size: 19, color: joined ? LC.success : context.lc.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: joined ? LC.success : context.lc.muted, fontWeight: FontWeight.w500)),
                ),
                if (parts.isNotEmpty) Text('${parts.length}', style: context.tt.bodySmall),
              ]),
            ),
          ),
        ),
        for (final p in parts)
          Padding(
            padding: const EdgeInsets.fromLTRB(36, 2, 8, 4),
            child: Row(children: [
              PeerAvatar(peer: p, size: 24, presence: false, ringColor: p.hashCode.isEven ? LC.success : null),
              const SizedBox(width: 8),
              Expanded(
                child: Text(p == me?.peer ? (me?.name ?? '') : contacts.nameOf(p),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tt.bodySmall?.copyWith(color: context.lc.text)),
              ),
              if (p.hashCode % 3 == 0) Icon(AppIcons.micOff, size: 14, color: context.lc.muted),
            ]),
          ),
      ]),
    );
  }
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
          // Discord-style: voice stays connected above the text channel.
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
          child: _MemberList(conv: ch.conv),
        ),
    ]);
  }
}

class _MemberList extends StatefulWidget {
  const _MemberList({required this.conv});
  final String conv;
  @override
  State<_MemberList> createState() => _MemberListState();
}

class _MemberListState extends State<_MemberList> {
  GroupInfo? _g;

  @override
  void initState() {
    super.initState();
    context.read<LumoraApi>().groupInfo(widget.conv.substring(2).split('#').first).then((g) {
      if (mounted) setState(() => _g = g);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final contacts = context.watch<ContactsStore>();
    final me = context.read<SessionStore>().me?.peer;
    final members = _g?.members ?? const <GroupMember>[];
    bool online(GroupMember m) => m.peer == me || (contacts[m.peer]?.online ?? false);
    final on = members.where(online).toList();
    final off = members.where((m) => !online(m)).toList();
    Widget tile(GroupMember m, bool isOn) => InkWell(
        onTap: m.peer == me ? null : () => openProfile(context, m.peer),
        child: Opacity(
          opacity: isOn ? 1 : 0.5,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Row(children: [
              PeerAvatar(peer: m.peer, fallbackName: m.name, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Text(contacts[m.peer]?.displayName ?? m.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w500, color: m.role == 'owner' ? LC.warning : (m.role == 'admin' ? LC.accent : null))),
              ),
              if (m.role == 'owner') const Icon(AppIcons.owner, size: 16, color: LC.warning),
            ]),
          ),
        ),
      );
    return ListView(padding: const EdgeInsets.only(top: 8), children: [
      SectionLabel('${s('online')} — ${on.length}', padding: const EdgeInsets.fromLTRB(16, 12, 16, 6)),
      for (final m in on) tile(m, true),
      SectionLabel('${s('offline')} — ${off.length}', padding: const EdgeInsets.fromLTRB(16, 16, 16, 6)),
      for (final m in off) tile(m, false),
    ]);
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
                  final voice = sp.channels.where((c) => c.voice).fold(0, (a, c) => a + c.participants.length);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: LCard(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        leading: GroupAvatar(gid: sp.id, name: sp.name, size: 48),
                        title: Text(sp.name, style: context.tt.titleMedium),
                        subtitle: Text('${s('n_members', {'n': sp.members})}${voice > 0 ? ' · ${s('n_in_voice', {'n': voice})}' : ''}'),
                        trailing: CountBadge(unread),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _MobileChannels(space: sp))),
                      ),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}

class _MobileChannels extends StatelessWidget {
  const _MobileChannels({required this.space});
  final Space space;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ChannelList(
          space: space,
          showBack: true,
          onOpen: (c) => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => ChatView(conv: c.conv, channelName: c.name, spaceName: space.name),
          )),
        ),
      ),
    );
  }
}


class _VoiceStage extends StatelessWidget {
  const _VoiceStage({required this.channel});
  final Channel channel;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final parts = context.select<SpacesStore, List<String>>((x) => List.of(x.voice[channel.conv] ?? const []));
    final speaking = context.select<CallStore, Set<String>>((c) => c.call?.conv == channel.conv ? c.call!.speaking : const {});
    final calls = context.watch<CallStore>();
    final me = context.read<SessionStore>().me?.peer ?? '';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [LC.success.withValues(alpha: 0.12), LC.accent.withValues(alpha: 0.06)]),
        border: Border(bottom: BorderSide(color: context.lc.divider)),
      ),
      child: Row(children: [
        const Icon(AppIcons.voice, color: LC.success),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(channel.name, style: context.tt.titleSmall),
          Text(s('n_in_voice', {'n': parts.length}), style: context.tt.bodySmall),
        ]),
        const SizedBox(width: 16),
        Expanded(
          child: SizedBox(
            height: 44,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final p in parts)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Tooltip(
                    message: context.read<ContactsStore>().nameOf(p, me: me, meName: s('you')),
                    child: AnimatedContainer(
                      duration: Motion.fast,
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: speaking.contains(p) ? LC.success : Colors.transparent, width: 2.5)),
                      child: PeerAvatar(peer: p, size: 36, presence: false),
                    ),
                  ),
                ),
            ]),
          ),
        ),
        ToolButton(
          icon: calls.mic ? AppIcons.mic : AppIcons.micOff,
          tooltip: calls.mic ? s('mute_mic') : s('unmute_mic'),
          active: !calls.mic,
          onPressed: () => calls.toggle(mic: !calls.mic),
        ),
        ToolButton(
          icon: AppIcons.screenShare,
          tooltip: s('share_screen'),
          active: calls.screen,
          onPressed: () => calls.toggle(screen: !calls.screen),
        ),
        const SizedBox(width: 4),
        FilledButton.icon(
          onPressed: () {
            if (calls.call?.conv == channel.conv) calls.hangup();
            context.read<SpacesStore>().toggleVoice(channel.conv, me);
          },
          style: FilledButton.styleFrom(backgroundColor: LC.danger, minimumSize: const Size(0, 36)),
          icon: const Icon(AppIcons.hangUp, size: 16),
          label: Text(s('disconnect')),
        ),
      ]),
    );
  }
}
