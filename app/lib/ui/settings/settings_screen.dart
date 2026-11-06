import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../widgets/app_icons.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/api_factory.dart' show kForceMock;
import '../../core/version.dart';
import '../../core/mock_api.dart';
import '../../l10n/strings.dart';
import '../../platform/android_bridge.dart';
import 'background_sheet.dart';
import '../../platform/tones.dart';
import '../../state/app_lock.dart';
import '../../state/settings.dart';
import '../../state/stores.dart';
import '../files/files_screen.dart';
import '../lock/app_lock_screen.dart';
import '../onboarding/forgot_passphrase.dart' show AsideDataGroup;
import 'backup_file.dart';
import '../devices/my_devices.dart';
import 'blocked_screen.dart';
import 'profile_editor.dart';
import 'security_checkup.dart';
import 'storage_screen.dart';
import '../profile/profile_screen.dart';
import '../network/network_screen.dart';
import '../bots/botfather.dart';
import '../calls/call_effects.dart' show BeautySettingsRow;
import '../theme.dart';
import '../widgets/peer_avatar.dart';
import '../widgets/common.dart';
import '../widgets/logo.dart';
import '../../platform/apple_services.dart';
import 'video_codec_info.dart';
import '../widgets/core_events.dart';

enum SettingsPage { profile, devices, appearance, privacy, bots, remote, storage, security, language, advanced, about }

const _tints = {
  SettingsPage.profile: Color(0xFF6C5CE7),
  SettingsPage.devices: Color(0xFF14B8A6),
  SettingsPage.appearance: Color(0xFFEC4899),
  SettingsPage.privacy: Color(0xFF22C55E),
  SettingsPage.bots: Color(0xFF0EA5E9),
  SettingsPage.remote: Color(0xFF3B82F6),
  SettingsPage.storage: Color(0xFFF59E0B),
  SettingsPage.security: Color(0xFFEF4444),
  SettingsPage.language: Color(0xFF0EA5E9),
  SettingsPage.advanced: Color(0xFF64748B),
  SettingsPage.about: Color(0xFF00C2D1),
};

const _icons = {
  SettingsPage.profile: AppIcons.profile,
  SettingsPage.devices: AppIcons.devices,
  SettingsPage.appearance: AppIcons.palette,
  SettingsPage.privacy: AppIcons.hide,
  SettingsPage.bots: AppIcons.bot,
  SettingsPage.remote: AppIcons.remote,
  SettingsPage.storage: AppIcons.database,
  SettingsPage.security: AppIcons.shieldCheck,
  SettingsPage.language: AppIcons.language,
  SettingsPage.advanced: AppIcons.sliders,
  SettingsPage.about: AppIcons.info,
};

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.initial = SettingsPage.profile});
  final SettingsPage initial;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsPage _page = widget.initial;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final desktop = isDesktop(context);
    if (!desktop) {
      return Material(
        color: context.lc.bg,
        child: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 24), children: [
          Padding(padding: const EdgeInsets.fromLTRB(4, 6, 4, 12), child: Text(s('settings'), style: context.tt.titleLarge)),
          const _ProfileHeader(),
          const SizedBox(height: 12),
          LCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: [
              ListTile(
                leading: const IconTile(AppIcons.transfers, color: Color(0xFF8B5CF6), size: IconTileSize.sm),
                title: Text(s('files')),
                trailing: const Icon(AppIcons.chevronRight, size: 18),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const FilesScreen())),
              ),
              for (final p in SettingsPage.values.skip(1))
                ListTile(
                  leading: IconTile(_icons[p]!, color: _tints[p]!, size: IconTileSize.sm),
                  title: Text(s('settings_${p.name}')),
                  trailing: const Icon(AppIcons.chevronRight, size: 18),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => Scaffold(body: SafeArea(child: SettingsSubPage(page: p))),
                  )),
                ),
            ]),
          ),
        ]),
      );
    }
    return Material(
      color: context.lc.bg,
      child: Row(children: [
        Container(
          width: 248,
          decoration: BoxDecoration(color: context.lc.surface, border: Border(right: BorderSide(color: context.lc.divider))),
          child: ListView(padding: const EdgeInsets.fromLTRB(10, 16, 10, 16), children: [
            Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 12), child: Text(s('settings'), style: context.tt.titleLarge)),
            for (final p in SettingsPage.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: ListTile(
                  dense: true,
                  selected: _page == p,
                  selectedTileColor: LC.primary.withValues(alpha: 0.14),
                  selectedColor: context.lc.text,
                  leading: IconTile(_icons[p]!, color: _tints[p]!, size: IconTileSize.sm),
                  title: Text(s('settings_${p.name}'), style: TextStyle(fontWeight: _page == p ? FontWeight.w600 : FontWeight.w500, fontSize: 14)),
                  onTap: () => setState(() => _page = p),
                ),
              ),
          ]),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: Motion.fast,
            child: Column(key: ValueKey(_page), children: [
              PaneHeader(leading: Icon(_icons[_page], color: LC.primary), title: Text(s('settings_${_page.name}'))),
              Expanded(child: _SettingsBody(page: _page)),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// One settings page with its header (mobile navigation target).
class SettingsSubPage extends StatelessWidget {
  const SettingsSubPage({super.key, required this.page});
  final SettingsPage page;
  @override
  Widget build(BuildContext context) => Column(children: [
        PaneHeader(title: Text(S.of(context)('settings_${page.name}'))),
        Expanded(child: _SettingsBody(page: page)),
      ]);
}

class _SettingsBody extends StatelessWidget {
  const _SettingsBody({required this.page});
  final SettingsPage page;
  @override
  Widget build(BuildContext context) {
    final child = switch (page) {
      SettingsPage.profile => const _Profile(),
      SettingsPage.devices => const MyDevicesPage(),
      SettingsPage.appearance => const _Appearance(),
      SettingsPage.privacy => const _Privacy(),
      SettingsPage.bots => MyBotsPage(onCreate: () {
          final nav = context.read<NavStore>();
          if (isDesktop(context)) {
            nav.openConv(kBotFatherConv);
          } else {
            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BotFatherChat()));
          }
        }),
      SettingsPage.remote => const _RemoteSettings(),
      SettingsPage.storage => const StorageSettings(),
      SettingsPage.security => const _Security(),
      SettingsPage.language => const _Language(),
      SettingsPage.advanced => const _Advanced(),
      SettingsPage.about => const _About(),
    };
    return ListView(padding: const EdgeInsets.all(20), children: [
      Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: child)),
    ]);
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children, this.title});
  final String? title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null) SectionLabel(title!, padding: const EdgeInsets.fromLTRB(4, 8, 4, 8)),
        LCard(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Column(children: children)),
        const SizedBox(height: 16),
      ]);
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader();
  @override
  Widget build(BuildContext context) {
    final me = context.select<SessionStore, Me?>((x) => x.me);
    return LCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.lg),
        onTap: () => openProfile(context, me?.peer ?? ''),
        child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [
        PeerAvatar(peer: me?.peer ?? '', size: 56),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(me?.name ?? '', style: context.tt.titleMedium),
            const SizedBox(height: 2),
            Text('ID ${me?.shortId ?? ''}', style: context.tt.bodySmall),
          ]),
        ),
        IconButton(tooltip: S.of(context)('copy'), onPressed: () => copyText(context, me?.shortId ?? ''), icon: const Icon(AppIcons.copy)),
      ])),
      ),
    );
  }
}

class _Profile extends StatelessWidget {
  const _Profile();
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final me = context.select<SessionStore, Me?>((x) => x.me);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const LCard(padding: EdgeInsets.all(20), child: ProfileEditor(inline: true)),
      const SizedBox(height: 16),
      _Group(children: [
        ListTile(
          leading: const RowIcon(AppIcons.channel),
          title: Text(s('short_id')),
          subtitle: Text(me?.shortId ?? ''),
          trailing: const Icon(AppIcons.copy, size: 18),
          onTap: () => copyText(context, me?.shortId ?? ''),
        ),
        ListTile(
          leading: const RowIcon(AppIcons.key),
          title: Text(s('long_id')),
          subtitle: Text(me?.peer ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          trailing: const Icon(AppIcons.copy, size: 18),
          onTap: () => copyText(context, me?.peer ?? ''),
        ),
      ]),
    ]);
  }
}

class _Appearance extends StatelessWidget {
  const _Appearance();
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = context.watch<Settings>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _Group(title: s('theme'), children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: SegmentedButton<ThemeMode>(
            segments: [
              ButtonSegment(value: ThemeMode.system, icon: const Icon(AppIcons.themeAuto, size: 18), label: Text(s('theme_system'))),
              ButtonSegment(value: ThemeMode.dark, icon: const Icon(AppIcons.moon, size: 18), label: Text(s('theme_dark'))),
              ButtonSegment(value: ThemeMode.light, icon: const Icon(AppIcons.sun, size: 18), label: Text(s('theme_light'))),
            ],
            selected: {st.themeMode},
            onSelectionChanged: (v) => st.update((x) => x.themeMode = v.first),
          ),
        ),
      ]),
      _Group(title: s('density'), children: [
        SwitchRow(icon: AppIcons.density, title: s('compact_mode'), subtitle: s('compact_mode_hint'), value: st.compact, onChanged: (v) => st.update((x) => x.compact = v)),
      ]),
      _Group(title: s('font_size'), children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            const Text('A', style: TextStyle(fontSize: 13)),
            Expanded(
              child: Slider(
                value: st.textScale,
                min: 0.85,
                max: 1.3,
                divisions: 9,
                label: '${(st.textScale * 100).round()}%',
                onChanged: (v) => st.update((x) => x.textScale = v),
              ),
            ),
            const Text('A', style: TextStyle(fontSize: 20)),
          ]),
        ),
      ]),
      _Group(title: s('chats'), children: [
        SwitchRow(
          icon: AppIcons.emoji,
          title: s('animated_emoji'),
          subtitle: s('animated_emoji_hint'),
          value: st.animatedEmoji,
          onChanged: (v) => st.update((x) => x.animatedEmoji = v),
        ),
      ]),
    ]);
  }
}

class _Privacy extends StatelessWidget {
  const _Privacy();
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = context.watch<Settings>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const _AppLockGroup(),
      const IpPrivacyCard(),
      const _FindByIdGroup(),
      _Group(title: s('messages'), children: [
        SwitchRow(icon: AppIcons.checkDouble, title: s('read_receipts'), subtitle: s('read_receipts_hint'), value: st.readReceipts, onChanged: (v) => st.update((x) => x.readReceipts = v)),
        SwitchRow(icon: AppIcons.more, title: s('typing_indicators'), subtitle: s('typing_indicators_hint'), value: st.typingIndicators, onChanged: (v) => st.update((x) => x.typingIndicators = v)),
        SwitchRow(icon: AppIcons.link, title: s('link_previews'), subtitle: s('link_previews_hint'), value: st.linkPreviews, onChanged: (v) => st.update((x) => x.linkPreviews = v)),
      ]),
      const _Group(children: [BlockedRow(), BlockedGroupsRow(), HiddenMembersRow()]),
      _Group(title: s('discovery'), children: [
        SwitchRow(icon: AppIcons.lan, title: s('lan_discovery'), subtitle: s('lan_discovery_hint'), value: st.lanDiscovery, onChanged: (v) => st.update((x) => x.lanDiscovery = v)),
        SwitchRow(icon: AppIcons.package, title: s('store_forward'), subtitle: s('store_forward_hint'), value: st.storeForward, onChanged: (v) => st.update((x) => x.storeForward = v)),
        SwitchRow(icon: AppIcons.peerToPeer, title: s('help_friends'), subtitle: s('help_friends_hint'), value: st.helpFriends, onChanged: (v) => st.update((x) => x.helpFriends = v)),
      ]),
      _Group(title: s('calls'), children: [
        SwitchRow(icon: AppIcons.voice, title: s('echo_cancel'), subtitle: s('echo_cancel_hint'), value: st.echoCancel, onChanged: (v) => st.update((x) => x.echoCancel = v)),
        SwitchRow(icon: AppIcons.voiceWave, title: s('noise_suppression'), subtitle: s('noise_suppression_hint'), value: st.noiseSuppression, onChanged: (v) => st.update((x) => x.noiseSuppression = v)),
        const BeautySettingsRow(),
        SwitchRow(icon: AppIcons.sun, title: s('lowlight'), subtitle: s('lowlight_hint'), value: st.videoLowlight, onChanged: (v) => st.update((x) => x.videoLowlight = v)),
        SwitchRow(icon: AppIcons.mirror, title: s('mirror_send'), subtitle: s('mirror_send_hint'), value: st.videoMirrorSend, onChanged: (v) => st.update((x) => x.videoMirrorSend = v)),
      ]),
      const NotificationSettingsGroup(),
    ]);
  }
}

/// Settings › Notifications: system notifications, their content, and the
/// call ringtone / message sound / vibration (state/sound_alerts.dart).
class NotificationSettingsGroup extends StatelessWidget {
  const NotificationSettingsGroup({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = context.watch<Settings>();
    return _Group(title: s('notifications'), children: [
      SwitchRow(icon: AppIcons.bell, title: s('notifications'), subtitle: s('notifications_hint'), value: st.notifications, onChanged: (v) => st.update((x) => x.notifications = v)),
      SwitchRow(
        icon: AppIcons.message,
        title: s('notify_preview'),
        subtitle: st.appLock ? s('notify_preview_locked') : s('notify_preview_hint'),
        value: !st.hideNotificationContent,
        onChanged: st.appLock || !st.notifications ? null : (v) => st.update((x) => x.notifyPreview = v),
      ),
      SwitchRow(icon: AppIcons.callIncoming, title: s('call_ringtone'), subtitle: s('call_ringtone_hint'), value: st.callRingtone, onChanged: (v) => st.update((x) => x.callRingtone = v)),
      SwitchRow(
        icon: AppIcons.speaker,
        title: s('message_sound'),
        subtitle: s('message_sound_hint'),
        value: st.notifications && st.messageSound,
        onChanged: !st.notifications ? null : (v) => st.update((x) => x.messageSound = v),
      ),
      SwitchRow(
        icon: AppIcons.reminder,
        title: s('reminder_sound'),
        subtitle: s('reminder_sound_hint'),
        value: st.notifications && st.reminderSound,
        onChanged: !st.notifications ? null : (v) => st.update((x) => x.reminderSound = v),
      ),
      if (TonePlayer.canVibrate)
        SwitchRow(icon: AppIcons.mobile, title: s('vibrate'), subtitle: s('vibrate_hint'), value: st.vibrate, onChanged: (v) => st.update((x) => x.vibrate = v)),
      if (AndroidBridge.isAndroid || debugShowAndroidNotificationRows) ...[
        SwitchRow(
          icon: AppIcons.chat,
          title: s('chat_bubbles'),
          subtitle: s('chat_bubbles_hint'),
          value: st.notifications && st.chatBubbles,
          onChanged: !st.notifications ? null : (v) => st.update((x) => x.chatBubbles = v),
        ),
        InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: () => showBackgroundSheet(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Row(children: [
              RowIcon(AppIcons.power, size: 20, color: context.lc.muted),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s('bg_row'), style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(s('bg_row_hint'), style: context.tt.bodySmall),
                ]),
              ),
              Icon(AppIcons.chevronRight, size: 18, color: context.lc.muted),
              const SizedBox(width: 8),
            ]),
          ),
        ),
      ],
      if (AppleServices.isIOS) ...[
        if (AppleServices.pushAvailable)
          SwitchRow(
            icon: AppIcons.bellRinging,
            title: s('instant_push'),
            subtitle: s('instant_push_hint'),
            value: st.instantPush,
            onChanged: !st.notifications
                ? null
                : (v) async {
                    var on = false;
                    if (v) {
                      on = await AppleServices.instance.enablePush(); // false if the user declines
                    } else {
                      await AppleServices.instance.disablePush();
                    }
                    st.update((x) => x.instantPush = on);
                  },
          ),
        _IosDeliveryNote(push: AppleServices.pushAvailable && st.instantPush),
      ],
    ]);
  }
}

/// Settings › Privacy: who can see your IP address — in plain words, no network terms.
/// People you connect with directly (friends, people you sent a request to, group
/// members, bots you use, a remote-control partner you accept) see it; strangers don't.
class IpPrivacyCard extends StatelessWidget {
  const IpPrivacyCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    const green = Color(0xFF22C55E);
    Widget who(IconData icon, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            IconTile(icon, color: green, size: IconTileSize.sm, circle: true),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500))),
            const Icon(AppIcons.check, size: 16, color: green),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(color: green.withValues(alpha: dark ? 0.28 : 0.22)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [green.withValues(alpha: dark ? 0.10 : 0.07), context.lc.surface, context.lc.surface],
            stops: const [0, 0.55, 1],
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const IconTile(AppIcons.shieldCheck, color: green),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s('ip_who_title'), style: context.tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(s('ip_who_sub'), style: context.tt.bodySmall?.copyWith(height: 1.4)),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          who(AppIcons.friends, s('ip_who_friends')),
          who(AppIcons.people, s('ip_who_groups')),
          who(AppIcons.bot, s('ip_who_bots')),
          who(AppIcons.remote, s('ip_who_remote')),
          Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Divider(height: 1, color: context.lc.divider)),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            IconTile(AppIcons.user, color: context.lc.muted, size: IconTileSize.sm, circle: true),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s('ip_who_strangers'), style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(s('ip_who_strangers_sub'), style: context.tt.bodySmall?.copyWith(height: 1.4)),
              ]),
            ),
            const SizedBox(width: 8),
            Padding(padding: const EdgeInsets.only(top: 2), child: Icon(AppIcons.block, size: 16, color: context.lc.muted)),
          ]),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(AppIcons.lan, size: 15, color: context.lc.muted)),
            const SizedBox(width: 8),
            Expanded(child: Text(s('ip_who_lan'), style: context.tt.bodySmall?.copyWith(fontSize: 12, height: 1.4))),
          ]),
        ]),
      ),
    );
  }
}

/// "Let strangers find me by ID": publishes (or not) the 9-digit ID in the public
/// directory. The value lives in the core (`settings_get/set discoverable_by_id`); an
/// older core without it hides the row.
class _FindByIdGroup extends StatefulWidget {
  const _FindByIdGroup();
  @override
  State<_FindByIdGroup> createState() => _FindByIdGroupState();
}

class _FindByIdGroupState extends State<_FindByIdGroup> {
  bool? _on;
  CoreEventWatch? _synced;

  @override
  void initState() {
    super.initState();
    _load();
    // switched on another of my devices (an account setting)
    _synced = CoreEventWatch.settings(context.read<LumoraApi>(), const {'privacy.discoverable'}, _load);
  }

  @override
  void dispose() {
    _synced?.cancel();
    super.dispose();
  }

  void _load() {
    context.read<LumoraApi>().settingsGet().then((v) {
      final on = v['discoverable_by_id'];
      if (mounted && on is bool) setState(() => _on = on);
    }).catchError((_) {});
  }

  Future<void> _set(bool v) async {
    final s = S.read(context);
    final api = context.read<LumoraApi>();
    setState(() => _on = v);
    try {
      await api.settingsSet({'discoverable_by_id': v});
    } catch (_) {
      if (!mounted) return;
      setState(() => _on = !v);
      toast(context, s('err_internal'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = _on;
    if (on == null) return const SizedBox.shrink();
    final s = S.of(context);
    final user = context.select<SessionStore, String?>((x) => x.me?.username)?.trim() ?? '';
    return _Group(title: s('find_me'), children: [
      SwitchRow(
        icon: AppIcons.search,
        title: s('find_by_id'),
        subtitle: on ? s('find_by_id_hint') : (user.isEmpty ? s('find_by_id_off_hint') : s('find_by_id_off_hint_user', {'user': user})),
        value: on,
        onChanged: _set,
      ),
    ]);
  }
}

/// iPhone: explains, in plain words, when messages arrive (no server = no push by default).
class _IosDeliveryNote extends StatelessWidget {
  const _IosDeliveryNote({required this.push});
  final bool push;
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(AppIcons.info, size: 18, color: context.lc.muted),
        const SizedBox(width: 10),
        Expanded(child: Text(s(push ? 'ios_delivery_push' : 'ios_delivery_open'), style: TextStyle(color: context.lc.muted, fontSize: 13, height: 1.35))),
      ]),
    );
  }
}

/// Shows the Android-only notification rows (bubbles, background) elsewhere (tests).
@visibleForTesting
bool debugShowAndroidNotificationRows = false;

/// Shows the Android-only screenshot switch on other platforms (screenshots/tests).
@visibleForTesting
bool debugShowScreenshotSwitch = false;

/// Settings › Privacy: app lock (PIN), auto-lock delay, screenshot block.
class _AppLockGroup extends StatelessWidget {
  const _AppLockGroup();

  Future<void> _toggle(BuildContext context, bool on) async {
    final s = S.read(context);
    final lock = context.read<AppLock>();
    if (on) {
      if (lock.hasPin) {
        // A PIN already guards locked chats: reuse it.
        if (!await askCurrentPin(context, title: s('app_lock')) || !context.mounted) return;
        lock.enableAppLock();
      } else {
        final pin = await askNewPin(context);
        if (pin == null || !context.mounted) return;
        try {
          await lock.setPin(pin);
        } catch (e) {
          if (context.mounted) toastError(context, e, fallbackKey: 'pin_save_failed');
          return;
        }
      }
      if (context.mounted) toast(context, s('app_lock_on'));
    } else {
      if (!await askCurrentPin(context, title: s('app_lock_turn_off')) || !context.mounted) return;
      lock.disableAppLock();
      toast(context, s('app_lock_off'));
    }
  }

  Future<void> _change(BuildContext context) async {
    final s = S.read(context);
    final lock = context.read<AppLock>();
    if (!await askCurrentPin(context, title: s('change_pin')) || !context.mounted) return;
    final pin = await askNewPin(context);
    if (pin == null || !context.mounted) return;
    try {
      await lock.setPin(pin, appLock: null);
    } catch (e) {
      if (context.mounted) toastError(context, e, fallbackKey: 'pin_save_failed');
      return;
    }
    if (context.mounted) toast(context, s('pin_changed'));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = context.watch<Settings>();
    final android = AndroidBridge.isAndroid || debugShowScreenshotSwitch;
    return _Group(title: s('app_lock'), children: [
      SwitchRow(icon: AppIcons.lockKey, title: s('app_lock'), subtitle: s('app_lock_hint'), value: st.appLock, onChanged: (v) => _toggle(context, v)),
      if (st.appLock)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 2, right: 14), child: Icon(AppIcons.timer, size: 20, color: context.lc.muted)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s('auto_lock'), style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(s('auto_lock_hint'), style: context.tt.bodySmall),
                const SizedBox(height: 4),
                DropdownButton<int>(
                  value: const [0, 60, 300, 3600].contains(st.autoLockSec) ? st.autoLockSec : 0,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  borderRadius: BorderRadius.circular(Radii.md),
                  style: context.tt.bodyMedium?.copyWith(color: LC.primary, fontWeight: FontWeight.w600),
                  items: [for (final v in const [0, 60, 300, 3600]) DropdownMenuItem(value: v, child: Text(s('auto_lock_$v')))],
                  onChanged: (v) => st.update((x) => x.autoLockSec = v ?? 0),
                ),
              ]),
            ),
          ]),
        ),
      if (st.appLock && AppLock.isDesktopPlatform)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 2, right: 14), child: Icon(AppIcons.lock, size: 20, color: context.lc.muted)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s('idle_lock'), style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(s('idle_lock_hint'), style: context.tt.bodySmall),
                const SizedBox(height: 4),
                Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  DropdownButton<int>(
                    value: const [0, 5, 15, 30].contains(st.idleLockMin) ? st.idleLockMin : 15,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    borderRadius: BorderRadius.circular(Radii.md),
                    style: context.tt.bodyMedium?.copyWith(color: LC.primary, fontWeight: FontWeight.w600),
                    items: [
                      for (final v in const [0, 5, 15, 30])
                        DropdownMenuItem(value: v, child: Text(v == 0 ? s('idle_lock_off') : s('idle_lock_min', {'n': v}))),
                    ],
                    onChanged: (v) => st.update((x) => x.idleLockMin = v ?? 15),
                  ),
                  TextButton.icon(
                    onPressed: () => context.read<AppLock>().lockNow(),
                    icon: const Icon(AppIcons.lock, size: 16),
                    label: Text(s('lock_now')),
                  ),
                ]),
              ]),
            ),
          ]),
        ),
      if (st.hasPin)
        InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: () => _change(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
            child: Row(children: [
              Icon(AppIcons.key, size: 20, color: context.lc.muted),
              const SizedBox(width: 14),
              Expanded(child: Text(s('change_pin'), style: context.tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500))),
              Icon(AppIcons.chevronRight, size: 18, color: context.lc.muted),
              const SizedBox(width: 8),
            ]),
          ),
        ),
      if (android)
        SwitchRow(
          icon: AppIcons.hide,
          title: s('block_screenshots'),
          subtitle: s('block_screenshots_hint'),
          value: st.blockScreenshots,
          onChanged: (v) => st.update((x) => x.blockScreenshots = v),
        ),
    ]);
  }
}

class _RemoteSettings extends StatelessWidget {
  const _RemoteSettings();
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = context.select<RemoteStore, RemoteStatus>((r) => r.status);
    final r = context.read<RemoteStore>();
    return _Group(children: [
      SwitchRow(icon: AppIcons.mouse, title: s('allow_control'), subtitle: s('allow_control_hint'), value: st.allowControl, onChanged: r.setAllowControl),
      SwitchRow(icon: AppIcons.lockKey, title: s('unattended'), subtitle: s('unattended_hint'), value: st.unattended, onChanged: r.setUnattended),
      Builder(builder: (context) {
        final prefs = context.watch<Settings>();
        return SwitchRow(
          icon: AppIcons.clipboard,
          title: s('clipboard_sync'),
          subtitle: s('clipboard_sync_hint'),
          value: prefs.remoteClipboard,
          onChanged: (v) => prefs.update((x) => x.remoteClipboard = v),
        );
      }),
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: const RowIcon(AppIcons.password),
        title: Text(s('new_password')),
        subtitle: Text(st.password, style: const TextStyle(fontFamily: 'monospace')),
        trailing: const Icon(AppIcons.refresh),
        onTap: r.refreshPassword,
      ),
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: const RowIcon(AppIcons.shieldPlus),
        title: Text(s('check_permissions')),
        trailing: const Icon(AppIcons.chevronRight, size: 18),
        onTap: () => openDiagnostics(context),
      ),
    ]);
  }
}

class _Security extends StatelessWidget {
  const _Security();
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final pass = hasPassphrase(context);
    final me = context.select<SessionStore, Me?>((x) => x.me);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SecurityCheckupCard(),
      const SizedBox(height: 16),
      const AsideDataGroup(),
      _Group(children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: const RowIcon(AppIcons.password),
          title: Text(pass ? s('change_passphrase') : s('set_passphrase')),
          subtitle: Text(pass ? s('passphrase_on') : s('passphrase_off')),
          trailing: const Icon(AppIcons.chevronRight, size: 18),
          onTap: () => showPassphraseDialog(context),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: const RowIcon(AppIcons.recoveryPhrase),
          title: Text(s('recovery_phrase')),
          subtitle: Text(s('recovery_phrase_hint')),
          trailing: const Icon(AppIcons.chevronRight, size: 18),
          onTap: () => showRecoveryPhraseDialog(context),
        ),
        const BackupRow(),
        if (me?.safety.isNotEmpty ?? false)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: const RowIcon(AppIcons.fingerprint),
            title: Text(s('safety_fingerprint')),
            subtitle: SelectableText(me!.safety, style: const TextStyle(fontFamily: 'monospace', letterSpacing: 1)),
          ),
      ]),
      _Group(title: s('devices'), children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: Icon(Platform.isAndroid || Platform.isIOS ? AppIcons.mobile : AppIcons.laptop, color: LC.success),
          title: Text(s('this_device')),
          subtitle: Text(s('active_now')),
          trailing: Pill(s('current'), color: LC.success),
        ),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: const RowIcon(AppIcons.signOut, color: LC.danger),
          title: Text(s('sign_out'), style: const TextStyle(color: LC.danger)),
          subtitle: Text(s('sign_out_hint')),
          onTap: () => signOutHere(context),
        ),
      ]),
    ]);
  }
}

class _Language extends StatelessWidget {
  const _Language();
  @override
  Widget build(BuildContext context) {
    final st = context.watch<Settings>();
    Widget opt(String code, String label, String flag) => ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: Text(flag, style: const TextStyle(fontSize: 22)),
          title: Text(label),
          trailing: st.locale == code ? const Icon(AppIcons.checkCircle, color: LC.primary) : const Icon(AppIcons.radioOff),
          onTap: () => st.update((x) => x.locale = code),
        );
    return _Group(children: [opt('vi', 'Tiếng Việt', '🇻🇳'), opt('en', 'English', '🇬🇧')]);
  }
}

/// Settings → Advanced: network (relays editor for power users) + diagnostics.
class _Advanced extends StatelessWidget {
  const _Advanced();
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final st = context.watch<Settings>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LCard(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          const Icon(AppIcons.warning, color: LC.warning),
          const SizedBox(width: 12),
          Expanded(child: Text(s('advanced_warning'), style: context.tt.bodySmall?.copyWith(height: 1.45))),
        ]),
      ),
      const SizedBox(height: 16),
      _Group(title: s('diagnostics'), children: [
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: const RowIcon(AppIcons.shieldPlus),
          title: Text(s('open_diagnostics')),
          subtitle: Text(s('open_diagnostics_hint')),
          trailing: const Icon(AppIcons.chevronRight, size: 18),
          onTap: () => openDiagnostics(context),
        ),
      ]),
      _Group(title: s('vc_title'), children: const [VideoCodecInfo()]),
      _Group(title: s('network'), children: [
        SwitchRow(title: s('opt_auto_ports'), subtitle: s('upnp_hint'), value: st.upnp, onChanged: (v) => st.update((x) => x.upnp = v)),
        SwitchRow(title: s('opt_peer_search'), subtitle: s('dht_hint'), value: st.dht, onChanged: (v) => st.update((x) => x.dht = v)),
        SwitchRow(title: s('opt_directory'), subtitle: s('nostr_hint'), value: st.nostr, onChanged: (v) => st.update((x) => x.nostr = v)),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s('relay_delay'), style: const TextStyle(fontWeight: FontWeight.w500)),
                Text(s('relay_delay_hint'), style: context.tt.bodySmall),
              ]),
            ),
            Text('${(st.relayDelayMs / 1000).toStringAsFixed(1)} s', style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
        ),
        Slider(value: st.relayDelayMs.toDouble(), min: 0, max: 10000, divisions: 20, onChanged: (v) => st.update((x) => x.relayDelayMs = v.round())),
      ]),
      _Group(title: s('custom_relays'), children: [
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 4),
            childrenPadding: EdgeInsets.zero,
            leading: const RowIcon(AppIcons.code),
            title: Text(s('technical_details')),
            subtitle: Text(s('custom_relays_hint'), style: context.tt.bodySmall),
            children: [
              for (final r in st.relays)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: const RowIcon(AppIcons.server),
                  title: Text(r, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                  trailing: IconButton(
                    tooltip: s('remove'),
                    icon: const Icon(AppIcons.delete, color: LC.danger),
                    onPressed: () => st.update((x) => x.relays = x.relays.where((e) => e != r).toList()),
                  ),
                ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: const Icon(AppIcons.add, color: LC.primary),
                title: Text(s('add_relay'), style: const TextStyle(color: LC.primary, fontWeight: FontWeight.w600)),
                onTap: () async {
                  final v = (await promptText(context, title: s('add_relay'), hint: s('relay_address_hint'), action: s('add')))?.trim();
                  if (v == null || v.isEmpty) return;
                  if (!isValidBridgeUrl(v)) {
                    if (context.mounted) toast(context, s('invalid_relay'));
                    return;
                  }
                  if (st.relays.contains(v)) return;
                  st.update((x) => x.relays = [...x.relays, v]);
                },
              ),
            ],
          ),
        ),
      ]),
      Text(s('restart_to_apply'), style: context.tt.bodySmall),
    ]);
  }
}

class _About extends StatelessWidget {
  const _About();
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final api = context.read<LumoraApi>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LCard(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          const LumoraLogo(size: 64),
          const SizedBox(height: 12),
          Text('Lumora', style: context.tt.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('${s('version')} $kAppVersion', style: context.tt.bodySmall),
          const SizedBox(height: 12),
          Text(s('about_body'), textAlign: TextAlign.center, style: context.tt.bodyMedium?.copyWith(color: context.lc.muted, height: 1.5)),
        ]),
      ),
      const SizedBox(height: 16),
      _Group(children: [
        ListTile(
          leading: const RowIcon(AppIcons.fileText),
          title: Text(s('oss_licenses')),
          subtitle: Text(s('emoji_attribution'), style: TextStyle(fontSize: 12, color: context.lc.muted)),
          trailing: const Icon(AppIcons.chevronRight, size: 18),
          onTap: () => showLicensePage(context: context, applicationName: 'Lumora', applicationVersion: kAppVersion),
        ),
      ]),
      if (api is MockLumoraApi && (kDebugMode || kForceMock))
        _Group(title: s('demo_tools'), children: [
          ListTile(
            leading: const RowIcon(AppIcons.callIncoming),
            title: Text(s('demo_incoming_call')),
            onTap: () => api.simulateIncomingCall(),
          ),
          ListTile(
            leading: const RowIcon(AppIcons.screenShare),
            title: Text(s('demo_remote_request')),
            onTap: api.simulateRemoteRequest,
          ),
          ListTile(
            leading: const RowIcon(AppIcons.addFriend),
            title: Text(s('demo_friend_request')),
            onTap: api.simulateFriendRequest,
          ),
        ]),
    ]);
  }
}

/// Bridges must use an encrypted connection (`wss://`). Plain `ws://` is only
/// accepted for this computer itself in debug builds (local testing).
bool isValidBridgeUrl(String v) {
  final u = Uri.tryParse(v);
  if (u == null || u.host.isEmpty) return false;
  if (u.scheme == 'wss') return true;
  if (u.scheme == 'ws' && !kReleaseMode) return u.host == 'localhost' || u.host == '127.0.0.1' || u.host == '::1';
  return false;
}
