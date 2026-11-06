// Renders every main screen with the mock API at desktop (1440x900) and
// mobile (390x844 @2x) sizes in dark + light themes and writes PNGs to
// app/screenshots/. Run: flutter test test/screenshots_test.dart
//
// Optional: SHOT_FILTER=chat flutter test ... to render a subset.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/chats/attachments.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/chats/stories.dart';
import 'package:lumora/ui/chats/wallpaper.dart';
import 'package:lumora/ui/groups/invite.dart';
import 'package:lumora/ui/settings/profile_editor.dart';
import 'package:lumora/ui/shell/notifications.dart';
import 'package:lumora/ui/shell/palette.dart';
import 'package:lumora/ui/flows.dart';
import 'package:lumora/ui/bots/botfather.dart';
import 'package:lumora/ui/chats/delete_dialogs.dart';
import 'package:lumora/ui/groups/group_info.dart';
import 'package:lumora/ui/profile/profile_screen.dart';
import 'package:lumora/ui/files/files_screen.dart';
import 'package:lumora/ui/friends/add_friend.dart';
import 'package:lumora/ui/friends/safety_number.dart';
import 'package:lumora/ui/groups/create_group.dart';
import 'package:lumora/ui/network/network_screen.dart';
import 'package:lumora/ui/widgets/app_icons.dart';
import 'package:lumora/ui/viewers/preview_card.dart';
import 'package:lumora/ui/lock/app_lock_screen.dart';
import 'package:lumora/ui/onboarding/lock_screen.dart';
import 'package:lumora/ui/remote/remote_layer.dart';
import 'package:lumora/ui/onboarding/onboarding_screen.dart';
import 'package:lumora/ui/settings/backup_file.dart';
import 'package:lumora/ui/settings/blocked_screen.dart';
import 'package:lumora/ui/settings/settings_screen.dart';
import 'package:lumora/ui/settings/security_checkup.dart' show showPassphraseDialog;
import 'package:lumora/ui/widgets/secure_input.dart';
import 'package:lumora/ui/widgets/recovery_phrase.dart';
import 'package:lumora/core/mock_api.dart' show kMockRecoveryPhrase;
import 'package:lumora/ui/shell/home_shell.dart';
import 'package:lumora/ui/startup_error.dart';
import 'package:lumora/l10n/strings.dart';

import 'helpers.dart';

typedef Setup = Future<Widget?> Function(WidgetTester t, AppServices sv, bool desktop);
typedef After = Future<void> Function(WidgetTester t, AppServices sv, bool desktop);

class Shot {
  const Shot(this.name, this.setup, {this.after, this.mobile = true, this.desktop = true, this.video = false});
  final bool video;
  final String name;
  final Setup setup;
  final After? after;
  final bool mobile;
  final bool desktop;
}

String _dm(AppServices sv, int i) => sv.chat.sorted.where((c) => !c.isGroup).elementAt(i).id;
String _group(AppServices sv) => sv.chat.sorted.firstWhere((c) => c.isGroup).id;
Contact _friend(AppServices sv, int i) => sv.contacts.friends[i];

Widget _mobilePage(Widget child) => Scaffold(body: SafeArea(child: child));

void _activeCall(AppServices sv, {required bool group, bool video = true}) {
  final peers = sv.contacts.friends.map((c) => c.peer).toList();
  sv.calls.onCall({
    'call_id': 'c1',
    'conv': group ? _group(sv) : 'd:${peers[0]}',
    'peer': peers[0],
    'state': 'active',
    'video': video,
    'participants': group ? peers.take(5).toList() : [peers[0]],
    'started_at': DateTime.now().millisecondsSinceEpoch - 754000,
    'speaking': group ? [peers[1]] : [],
    'quality': 3,
  });
}

final shots = <Shot>[
  Shot('01_chats', (t, sv, d) async {
    if (d) sv.nav.openConv(sv.chat.sorted.firstWhere((c) => !c.isSaved).id);
    return null;
  }),
  Shot('02_chat_direct', (t, sv, d) async {
    final conv = sv.chat.sorted.firstWhere((c) => !c.isSaved).id;
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }),
  Shot('03_chat_emoji', (t, sv, d) async {
    final conv = _dm(sv, 1);
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, after: (t, sv, d) async {
    await t.tap(find.byTooltip(sv.settings.locale == 'en' ? 'Emoji' : 'Biểu tượng cảm xúc').first);
  }),
  Shot('04_chat_group_info', (t, sv, d) async {
    final conv = _group(sv);
    sv.nav.openConv(conv);
    sv.nav.toggleInfo(true);
    return d ? null : ChatView(conv: conv);
  }),
  Shot('05_space', (t, sv, d) async {
    sv.nav.go(Section.space, space: sv.spaces.spaces.first.id);
    sv.spaces.toggleVoice(sv.spaces.spaces.first.channels.firstWhere((c) => c.voice).conv, sv.session.me!.peer);
    return null;
  }),
  Shot('06_friends', (t, sv, d) async {
    sv.nav.go(Section.friends);
    return null;
  }),
  Shot('07_add_friend', (t, sv, d) async {
    sv.nav.go(Section.friends);
    return null;
  }, after: (t, sv, d) async {
    showAddFriend(t.element(find.byType(HomeShell)));
  }),
  Shot('08_safety_number', (t, sv, d) async {
    sv.nav.go(Section.friends);
    return null;
  }, after: (t, sv, d) async {
    openSafetyNumber(t.element(find.byType(HomeShell)), _friend(sv, 0));
  }),
  Shot('09_create_group', (t, sv, d) async => null, after: (t, sv, d) async {
    showCreateGroup(t.element(find.byType(HomeShell)));
  }),
  Shot('10_call_video', (t, sv, d) async {
    _activeCall(sv, group: false);
    return null;
  }, video: true),
  Shot('11_call_group', (t, sv, d) async {
    _activeCall(sv, group: true);
    return null;
  }, video: true),
  Shot('12_incoming_call', (t, sv, d) async {
    final p = _friend(sv, 0).peer;
    sv.calls.onCall({'call_id': 'c2', 'conv': 'd:$p', 'peer': p, 'state': 'incoming', 'video': true, 'participants': [p]});
    return null;
  }),
  Shot('13_remote_home', (t, sv, d) async {
    sv.nav.go(Section.remote);
    return null;
  }),
  Shot('14_remote_request', (t, sv, d) async {
    sv.nav.go(Section.remote);
    final f = _friend(sv, 3);
    sv.remote.onRequest({'session': 's1', 'peer': f.peer, 'name': f.name, 'view_only': false});
    return null;
  }),
  Shot('15_remote_viewer', (t, sv, d) async {
    sv.remote.onState({'session': 's2', 'peer': _friend(sv, 3).peer, 'state': 'active', 'role': 'viewer', 'width': 1920, 'height': 1080, 'stream': 100});
    return null;
  }, video: true),
  Shot('16_host_banner', (t, sv, d) async {
    sv.remote.onState({'session': 's3', 'peer': _friend(sv, 3).peer, 'state': 'active', 'role': 'host', 'width': 1920, 'height': 1080, 'stream': 0});
    sv.nav.openConv(sv.chat.sorted.firstWhere((c) => !c.isSaved).id);
    return null;
  }),
  Shot('17_files', (t, sv, d) async {
    sv.nav.go(Section.files);
    return d ? null : const FilesScreen();
  }),
  Shot('18_diagnostics', (t, sv, d) async {
    sv.nav.go(Section.network);
    return d ? null : _mobilePage(const NetworkScreen());
  }),
  Shot('19_settings', (t, sv, d) async {
    sv.nav.go(Section.settings);
    return null;
  }),
  Shot('20_settings_privacy', (t, sv, d) async {
    return Scaffold(body: SafeArea(child: d ? const SettingsScreen(initial: SettingsPage.privacy) : const _SettingsPageHost(SettingsPage.privacy)));
  }),
  Shot('21_settings_advanced', (t, sv, d) async {
    return Scaffold(body: SafeArea(child: d ? const SettingsScreen(initial: SettingsPage.advanced) : const _SettingsPageHost(SettingsPage.advanced)));
  }),
  Shot('22_settings_storage', (t, sv, d) async {
    return Scaffold(body: SafeArea(child: d ? const SettingsScreen(initial: SettingsPage.storage) : const _SettingsPageHost(SettingsPage.storage)));
  }),
  Shot('27_chat_photos_wallpaper', (t, sv, d) async {
    final conv = 'd:${sv.contacts.friends.firstWhere((c) => c.name == 'Phạm Thu Hà').peer}';
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, video: true),
  Shot('28_chat_group_poll', (t, sv, d) async {
    final conv = sv.chat.sorted.firstWhere((c) => c.title.startsWith('Dự án')).id;
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }),
  Shot('29_chat_location_voice', (t, sv, d) async {
    final conv = 'd:${sv.contacts.friends.firstWhere((c) => c.name == 'Trần Bảo Ngọc').peer}';
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }),
  Shot('30_profile_editor', (t, sv, d) async => null, after: (t, sv, d) async {
    showProfileEditor(t.element(find.byType(HomeShell)));
  }),
  Shot('31_wallpaper_picker', (t, sv, d) async {
    final conv = sv.chat.sorted.firstWhere((c) => !c.isSaved).id;
    sv.nav.openConv(conv);
    return null;
  }, after: (t, sv, d) async {
    showWallpaperPicker(t.element(find.byType(HomeShell)), sv.chat.sorted.firstWhere((c) => !c.isSaved).id);
  }),
  Shot('32_story_viewer', (t, sv, d) async => null, after: (t, sv, d) async {
    final me = sv.session.me!.peer;
    openStories(t.element(find.byType(HomeShell)), sv.stories.byAuthor(me), 0);
  }),
  Shot('33_command_palette', (t, sv, d) async => null, after: (t, sv, d) async {
    showCommandPalette(t.element(find.byType(HomeShell)));
  }),
  Shot('34_media_viewer', (t, sv, d) async {
    final conv = 'd:${sv.contacts.friends.firstWhere((c) => c.name == 'Phạm Thu Hà').peer}';
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, after: (t, sv, d) async {
    final conv = 'd:${sv.contacts.friends.firstWhere((c) => c.name == 'Phạm Thu Hà').peer}';
    final th = sv.chat.thread(conv);
    final m = th.messages.firstWhere((m) => m.isFile);
    openMediaViewer(t.element(find.byType(ChatView)), conv: conv, initialId: m.id);
  }, video: true),
  Shot('35_invite', (t, sv, d) async {
    sv.nav.openConv(sv.chat.sorted.firstWhere((c) => c.title.startsWith('Dự án')).id);
    return null;
  }, after: (t, sv, d) async {
    final gid = sv.chat.sorted.firstWhere((c) => c.title.startsWith('Dự án')).gid!;
    showInvite(t.element(find.byType(HomeShell)), gid: gid, name: 'Dự án Lumora 🚀');
  }),
  Shot('36_attach_menu', (t, sv, d) async {
    final conv = sv.chat.sorted.firstWhere((c) => !c.isSaved).id;
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, after: (t, sv, d) async {
    await t.tap(find.byTooltip(sv.settings.locale == 'en' ? 'Attach file' : 'Đính kèm tệp').first);
  }),
  Shot('37_message_menu', (t, sv, d) async {
    final conv = 'd:${sv.contacts.friends.firstWhere((c) => c.name == 'Trần Bảo Ngọc').peer}';
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, after: (t, sv, d) async {
    final target = find.text('Màu tím với xanh cyan hợp nhau ghê');
    if (d) {
      await t.tap(target, buttons: kSecondaryButton);
    } else {
      await t.longPress(target);
    }
  }),
  Shot('38_contact_hub', (t, sv, d) async => null, after: (t, sv, d) async {
    openProfile(t.element(find.byType(HomeShell)), sv.contacts.friends.firstWhere((c) => c.name == 'Phạm Thu Hà').peer);
  }, video: true),
  Shot('39_group_hub', (t, sv, d) async {
    final conv = sv.chat.sorted.firstWhere((c) => c.title.startsWith('Dự án')).id;
    sv.nav.openConv(conv);
    sv.nav.toggleInfo(true);
    return d ? null : Scaffold(body: SafeArea(child: GroupInfoView(gid: conv.substring(2))));
  }),
  Shot('40_create_menu', (t, sv, d) async => null, after: (t, sv, d) async {
    Flows.showCreateMenu(t.element(find.byType(HomeShell)), at: d ? const Offset(80, 290) : null);
  }),
  Shot('41_palette_command', (t, sv, d) async => null, after: (t, sv, d) async {
    showCommandPalette(t.element(find.byType(HomeShell)), initial: sv.settings.locale == 'en' ? 'call Minh' : 'gọi Minh');
  }),
  Shot('42_call_with_chat', (t, sv, d) async {
    _activeCall(sv, group: false);
    sv.calls.toggleChat();
    return null;
  }, video: true),
  Shot('43_voice_stage', (t, sv, d) async {
    sv.nav.go(Section.space, space: sv.spaces.spaces.first.id);
    sv.spaces.toggleVoice(sv.spaces.spaces.first.channels.firstWhere((c) => c.voice).conv, sv.session.me!.peer);
    return null;
  }, mobile: false),
  Shot('44_welcome_tour', (t, sv, d) async {
    sv.settings.showTour = true;
    return null;
  }),
  Shot('45_botfather', (t, sv, d) async {
    sv.nav.openConv(kBotFatherConv);
    return d ? null : const BotFatherChat();
  }, after: (t, sv, d) async {
    await t.enterText(find.byType(TextField).last, '/mybots');
    await t.testTextInput.receiveAction(TextInputAction.done);
  }, video: true),
  Shot('46_bot_chat', (t, sv, d) async {
    final bot = sv.contacts.byPeer.values.firstWhere((c) => c.isBot);
    final conv = 'd:${bot.peer}';
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, after: (t, sv, d) async {
    await t.enterText(find.byType(TextField).last, '/');
  }),
  Shot('47_formatting_sticker', (t, sv, d) async {
    final conv = 'd:${sv.contacts.friends.firstWhere((c) => c.name == 'Nguyễn Minh Anh').peer}';
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, video: true),
  Shot('48_delete_dialog', (t, sv, d) async {
    final conv = 'd:${sv.contacts.friends.firstWhere((c) => c.name == 'Trần Bảo Ngọc').peer}';
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, after: (t, sv, d) async {
    final conv = 'd:${sv.contacts.friends.firstWhere((c) => c.name == 'Trần Bảo Ngọc').peer}';
    final m = sv.chat.thread(conv).messages.lastWhere((m) => m.mine);
    askDeleteMessage(t.element(find.byType(ChatView)), conv, m);
  }),
  Shot('49_mute_picker', (t, sv, d) async => null, after: (t, sv, d) async {
    pickMute(t.element(find.byType(HomeShell)), sv.chat.sorted.firstWhere((c) => !c.isSaved).id);
  }),
  Shot('50_sticker_panel', (t, sv, d) async {
    final conv = sv.chat.sorted.firstWhere((c) => !c.isSaved).id;
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, after: (t, sv, d) async {
    await t.tap(find.byTooltip(sv.settings.locale == 'en' ? 'Emoji' : 'Biểu tượng cảm xúc').first);
    await t.pump(const Duration(milliseconds: 300));
    final st = find.byTooltip(sv.settings.locale == 'en' ? 'Stickers' : 'Nhãn dán').first;
    await t.ensureVisible(st);
    await t.pump(const Duration(milliseconds: 200));
    await t.tap(st);
  }, video: true),
  Shot('51_my_bots', (t, sv, d) async {
    return Scaffold(body: SafeArea(child: d ? const SettingsScreen(initial: SettingsPage.bots) : const _SettingsPageHost(SettingsPage.bots)));
  }),
  Shot('52_global_search', (t, sv, d) async => null, after: (t, sv, d) async {
    showCommandPalette(t.element(find.byType(HomeShell)), initial: 'flutter');
    await t.pump(const Duration(milliseconds: 400));
  }),
  Shot('53_group_admin', (t, sv, d) async {
    final conv = sv.chat.sorted.firstWhere((c) => c.title.startsWith('Dự án')).id;
    return Scaffold(body: SafeArea(child: GroupInfoView(gid: conv.substring(2))));
  }, after: (t, sv, d) async {
    final f = find.text(sv.settings.locale == 'en' ? 'GROUP ADMIN' : 'QUẢN TRỊ NHÓM');
    if (f.evaluate().isNotEmpty) await t.ensureVisible(f.first);
  }),
  Shot('54_remote_power', (t, sv, d) async {
    sv.remote.onState({'session': 's2', 'peer': sv.contacts.friends.first.peer, 'state': 'active', 'role': 'viewer', 'width': 1920, 'height': 1080, 'stream': 100});
    return null;
  }, after: (t, sv, d) async {
    await t.tap(find.byTooltip(sv.settings.locale == 'en' ? 'More' : 'Thêm').last);
  }, video: true, mobile: false),
  Shot('55_settings_security', (t, sv, d) async {
    return Scaffold(body: SafeArea(child: d ? const SettingsScreen(initial: SettingsPage.security) : const _SettingsPageHost(SettingsPage.security)));
  }),
  Shot('56_settings_about', (t, sv, d) async {
    return Scaffold(body: SafeArea(child: d ? const SettingsScreen(initial: SettingsPage.about) : const _SettingsPageHost(SettingsPage.about)));
  }),
  Shot('57_call_more', (t, sv, d) async {
    _activeCall(sv, group: false);
    return null;
  }, after: (t, sv, d) async {
    await t.tap(find.byTooltip(sv.settings.locale == 'en' ? 'More' : 'Thêm').last);
  }, video: true, desktop: false),
  // Camera effects ("Hiệu ứng"): desktop from the call bar, mobile via More.
  Shot('fx1_call_effects', (t, sv, d) async {
    sv.settings.update((x) => x.videoBeauty = 2);
    _activeCall(sv, group: false);
    return null;
  }, after: (t, sv, d) async {
    final en = sv.settings.locale == 'en';
    if (d) {
      await t.tap(find.byTooltip(en ? 'Camera effects' : 'Hiệu ứng camera').last);
    } else {
      await t.tap(find.byTooltip(en ? 'More' : 'Thêm').last);
      await settle(t, frames: 6);
      await t.tap(find.text(en ? 'Camera effects' : 'Hiệu ứng camera').last);
    }
  }, video: true),
  Shot('fx2_call_more_effects', (t, sv, d) async {
    sv.settings.update((x) => x.videoBeauty = 1);
    _activeCall(sv, group: false);
    return null;
  }, after: (t, sv, d) async {
    await t.tap(find.byTooltip(sv.settings.locale == 'en' ? 'More' : 'Thêm').last);
  }, video: true, desktop: false),
  Shot('fx3_settings_call_effects', (t, sv, d) async {
    sv.settings.update((x) => x.videoBeauty = 1);
    return Scaffold(body: SafeArea(child: d ? const SettingsScreen(initial: SettingsPage.privacy) : const _SettingsPageHost(SettingsPage.privacy)));
  }, after: (t, sv, d) async {
    final f = find.text(sv.settings.locale == 'en' ? 'Mirror my video' : 'Lật hình');
    await t.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).last);
    await t.drag(find.byType(Scrollable).last, const Offset(0, -200));
  }),
  Shot('58_remote_viewer_more', (t, sv, d) async {
    sv.remote.onState({'session': 's2', 'peer': _friend(sv, 3).peer, 'state': 'active', 'role': 'viewer', 'width': 1920, 'height': 1080, 'stream': 100});
    return null;
  }, after: (t, sv, d) async {
    await t.tap(find.byTooltip(sv.settings.locale == 'en' ? 'More' : 'Thêm').last);
  }, video: true, desktop: false),
  Shot('59_startup_error', (t, sv, d) async => StartupErrorScreen(
        s: sv.settings.locale == 'en' ? S.en : S.vn,
        problem: StartupProblem.core,
        detail: 'Invalid argument(s): Cannot load liblumora_ffi.so',
        onRetry: () async {},
      )),
  Shot('60_app_lock', (t, sv, d) async {
    sv.appLock.setPin('2580');
    return const PinLockScreen();
  }, after: (t, sv, d) async {
    await t.tap(find.text('1'));
    await t.tap(find.text('4'));
  }),
  Shot('61_settings_app_lock', (t, sv, d) async {
    debugShowScreenshotSwitch = true;
    sv.appLock.setPin('2580');
    sv.settings.autoLockSec = 60;
    return Scaffold(body: SafeArea(child: d ? const SettingsScreen(initial: SettingsPage.privacy) : const _SettingsPageHost(SettingsPage.privacy)));
  }),
  Shot('62_set_pin', (t, sv, d) async => null, after: (t, sv, d) async {
    askNewPin(t.element(find.byType(HomeShell)));
    await settle(t, frames: 4);
    for (final k in ['2', '5', '8']) {
      await t.tap(find.text(k).last);
    }
  }),
  Shot('63_remote_chat', (t, sv, d) async {
    final peer = sv.contacts.friends.firstWhere((c) => c.name == 'Trần Bảo Ngọc').peer;
    final conv = 'd:$peer';
    sv.remote.onState({'session': 's2', 'peer': peer, 'state': 'active', 'role': 'viewer', 'width': 1920, 'height': 1080, 'stream': 100});
    final now = DateTime.now().millisecondsSinceEpoch;
    final me = sv.session.me!.peer;
    var i = 0;
    void msg(String author, String text, int agoS) => sv.chat.onMessage({
          'id': 'e${i++}'.padRight(32, '0'), 'conv': conv, 'author': author, 'hlc': (now - agoS * 1000) * 16, 'ts': now - agoS * 1000,
          'kind': 'text', 'body': {'text': text}, 'status': 2, 'mine': author == me,
        }, myPeer: me);
    await t.runAsync(() => sv.chat.thread(conv).loadInitial());
    msg(peer, 'Mình mở sẵn máy rồi, bạn xem giúp lỗi máy in nhé 🙏', 140);
    msg(me, 'Ok, mình đang vào xem đây', 120);
    msg(peer, 'Mật khẩu Wi-Fi mình vừa chép, bạn dán thử nhé', 40);
    await t.runAsync(() async {
      await sv.files.send(conv, '/home/user/Drivers/Printer-driver-2026.zip');
      await Future<void>.delayed(const Duration(milliseconds: 50)); // mock events
    });
    final f = sv.files.byId.values.firstWhere((x) => x.conv == conv && !x.incoming);
    sv.files.onFile({'id': f.id, 'conv': conv, 'peer': peer, 'name': f.name, 'size': f.size, 'direction': 0, 'state': 1, 'progress': (f.size * 0.42).round(), 'created': now, 'speed_bps': 6200000});
    return null;
  }, after: (t, sv, d) async {
    if (d) {
      await t.tap(find.byTooltip(sv.settings.locale == 'en' ? 'Chat' : 'Trò chuyện').last);
    } else {
      await t.tap(find.byTooltip(sv.settings.locale == 'en' ? 'More' : 'Thêm').last);
      await settle(t, frames: 4);
      await t.tap(find.text(sv.settings.locale == 'en' ? 'Chat' : 'Trò chuyện').last);
    }
    await settle(t, frames: 4);
    sv.remote.clipboardPulse.value++;
  }, video: true),
  Shot('64_host_chat', (t, sv, d) async {
    sv.remote.onState({'session': 's3', 'peer': sv.contacts.friends.firstWhere((c) => c.name == 'Trần Bảo Ngọc').peer, 'state': 'active', 'role': 'host', 'width': 1920, 'height': 1080, 'stream': 0});
    sv.nav.openConv(sv.chat.sorted.firstWhere((c) => !c.isSaved).id);
    return null;
  }, after: (t, sv, d) async {
    await t.tap(find.descendant(of: find.byType(HostBanner), matching: find.byIcon(AppIcons.chat)));
  }),
  Shot('65_forgot_passphrase', (t, sv, d) async => const LockScreen(), after: (t, sv, d) async {
    await t.tap(find.text(sv.settings.locale == 'en' ? 'Forgot password?' : 'Quên mật khẩu?'));
  }),
  Shot('66_locked_chats', (t, sv, d) async {
    sv.appLock.setPin('2580', appLock: false);
    final ids = sv.chat.sorted.where((c) => !c.isSaved && !c.isGroup).map((c) => c.id).take(4).toList();
    sv.appLock.setChatLocked(ids[1], true);
    sv.appLock.setChatLocked(ids[3], true);
    return null;
  }),
  Shot('67_locked_chats_open', (t, sv, d) async {
    sv.appLock.setPin('2580', appLock: false);
    final ids = sv.chat.sorted.where((c) => !c.isSaved && !c.isGroup).map((c) => c.id).take(4).toList();
    sv.appLock.setChatLocked(ids[1], true);
    sv.appLock.setChatLocked(ids[3], true);
    sv.appLock.openLockedChats();
    return null;
  }),
  Shot('68_settings_security_aside', (t, sv, d) async {
    sv.settings.asideData = ['/tmp/lumora-test/core.locked-20261103-214500'];
    return Scaffold(body: SafeArea(child: d ? const SettingsScreen(initial: SettingsPage.security) : const _SettingsPageHost(SettingsPage.security)));
  }),
  // Emoji picker: search without diacritics, skin tones, hover preview, big animated emoji.
  Shot('90_emoji_search', (t, sv, d) async {
    final conv = _dm(sv, 1);
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, after: (t, sv, d) async {
    await _openEmoji(t, sv);
    await t.enterText(_emojiSearch(), 'cuoi');
  }),
  Shot('91_emoji_tones', (t, sv, d) async {
    final conv = _dm(sv, 1);
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, after: (t, sv, d) async {
    await _openEmoji(t, sv);
    await t.enterText(_emojiSearch(), 'vay tay');
    await settle(t, frames: 3);
    await t.longPress(find.text('👋').last);
  }),
  Shot('92_emoji_preview', (t, sv, d) async {
    sv.nav.openConv(_dm(sv, 1));
    return null;
  }, after: (t, sv, d) async {
    await _openEmoji(t, sv);
    final tab = find.byTooltip(sv.settings.locale == 'en' ? 'Food & drink' : 'Đồ ăn & thức uống');
    await t.tap(tab.first);
    await settle(t, frames: 6);
    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    await g.moveTo(t.getCenter(find.text('🍉').first));
  }, mobile: false),
  Shot('93_big_emoji', (t, sv, d) async {
    final peer = sv.contacts.friends.firstWhere((c) => c.name == 'Trần Bảo Ngọc').peer;
    final conv = 'd:$peer';
    final me = sv.session.me!.peer;
    final now = DateTime.now().millisecondsSinceEpoch;
    await t.runAsync(() => sv.chat.thread(conv).loadInitial());
    var i = 0;
    void msg(String author, String text, int agoS, [Map<String, List<String>> reactions = const {}]) => sv.chat.onMessage({
          'id': 'j${i++}'.padRight(32, '0'), 'conv': conv, 'author': author, 'hlc': (now - agoS * 1000) * 16, 'ts': now - agoS * 1000,
          'kind': 'text', 'body': {'text': text}, 'status': 2, 'mine': author == me, 'reactions': reactions,
        }, myPeer: me);
    msg(peer, 'Mình đậu phỏng vấn rồi!!! 🥳', 300);
    msg(me, '🎉🥳🎂', 280);
    msg(peer, '😂', 260, {'❤️': [me], '😂': [me, peer]});
    msg(me, 'Tối nay đi ăn mừng nhé, mình mời 🍜', 240);
    msg(peer, '❤️👍', 200);
    msg(me, '🔥', 120, {'👍': [peer]});
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, video: true),
  // First launch: language, theme and text size cards (applied live).
  Shot('22_onboarding_setup', (t, sv, d) async => const OnboardingScreen()),
  Shot('22b_onboarding_setup_keyboard', (t, sv, d) async => const OnboardingScreen(), mobile: false, after: (t, sv, d) async {
    // Tab to "Dark" (after the two language cards and "Light"), then →
    // moves the choice to "System", with a visible focus ring.
    for (var i = 0; i < 4; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
    }
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
  }),
  Shot('23_onboarding_welcome', (t, sv, d) async => const OnboardingScreen(initialStep: 0)),
  Shot('24_onboarding_passphrase', (t, sv, d) async => const OnboardingScreen(initialStep: 2)),
  Shot('25_onboarding_phrase', (t, sv, d) async => OnboardingScreen(initialStep: 3, previewPhrase: await t.runAsync(() => sv.api.recoveryPhrase()))),
  Shot('26_lock', (t, sv, d) async => const LockScreen()),
  // Storage, blocked people, backup file, security checkup.
  Shot('70_blocked_list', (t, sv, d) async {
    _blockFriend(sv, 2);
    return d ? const Scaffold(body: SafeArea(child: SettingsScreen(initial: SettingsPage.privacy))) : _mobilePage(const BlockedList());
  }, after: (t, sv, d) async {
    if (d) openBlockedList(t.element(find.byType(SettingsScreen)));
  }),
  Shot('71_backup_dialog', (t, sv, d) async {
    return Scaffold(body: SafeArea(child: d ? const SettingsScreen(initial: SettingsPage.security) : const _SettingsPageHost(SettingsPage.security)));
  }, after: (t, sv, d) async {
    showBackupDialog(t.element(find.byType(d ? SettingsScreen : _SettingsPageHost)), previewFilled: true);
  }),
  Shot('72_chat_blocked', (t, sv, d) async {
    final peer = _blockFriend(sv, 2);
    sv.nav.openConv('d:$peer');
    return d ? null : ChatView(conv: 'd:$peer');
  }),
  Shot('74_storage_policy', (t, sv, d) async {
    return Scaffold(body: SafeArea(child: d ? const SettingsScreen(initial: SettingsPage.storage) : const _SettingsPageHost(SettingsPage.storage)));
  }, after: (t, sv, d) async {
    await t.drag(find.byType(ListView).last, Offset(0, d ? -560 : -1250));
  }),
  Shot('73_onboarding_restore_file', (t, sv, d) async => const OnboardingScreen(
        initialStep: 4,
        restoreFromFile: true,
        previewBackupPath: '/home/lan/Documents/lumora-2026-11-05.lumora-backup',
      )),
  // Empty states (IconTile lg + title/subtitle).
  Shot('75_empty_blocked', (t, sv, d) async {
    for (final c in sv.contacts.blocked) {
      await t.runAsync(() => sv.contacts.unblock(c.peer));
    }
    return d ? const Scaffold(body: SafeArea(child: SettingsScreen(initial: SettingsPage.privacy))) : _mobilePage(const BlockedList());
  }, after: (t, sv, d) async {
    if (d) openBlockedList(t.element(find.byType(SettingsScreen)));
  }),
  Shot('76_empty_notifications', (t, sv, d) async {
    sv.notices.clear();
    return null;
  }, after: (t, sv, d) async {
    showNotificationCentre(t.element(find.byType(HomeShell)));
  }),
  // Password / PIN / recovery-phrase screens (lib/ui/widgets/secure_input.dart).
  Shot('90_pw_app_lock_wrong', (t, sv, d) async {
    sv.appLock.setPin('2580');
    return const PinLockScreen();
  }, after: (t, sv, d) async {
    for (final k in ['1', '1', '1', '1']) {
      await t.tap(find.text(k));
    }
    await settle(t, frames: 3);
  }),
  Shot('91_pw_app_lock_wait', (t, sv, d) async {
    sv.appLock.setPin('2580');
    sv.settings.pinLockLevel = 1;
    sv.settings.pinLockUntil = DateTime.now().millisecondsSinceEpoch + 28 * 1000;
    return const PinLockScreen();
  }),
  Shot('92_pw_forgot_pin', (t, sv, d) async {
    sv.appLock.setPin('2580');
    return const PinLockScreen();
  }, after: (t, sv, d) async {
    final forgot = find.text(sv.settings.locale == 'en' ? 'Forgot PIN?' : 'Quên mã PIN?');
    await t.ensureVisible(forgot);
    await t.pump();
    await t.tap(forgot);
    await settle(t, frames: 4);
    await t.enterText(find.descendant(of: find.byType(RecoveryPhraseInput), matching: find.byType(TextField)).first, _kShotPhrase.split(' ').take(7).join(' '));
  }),
  Shot('93_pw_forgot_phrase', (t, sv, d) async => const LockScreen(), after: (t, sv, d) async {
    await t.tap(find.text(sv.settings.locale == 'en' ? 'Forgot password?' : 'Quên mật khẩu?'));
    await settle(t, frames: 4);
    await t.tap(find.text(sv.settings.locale == 'en' ? 'Recovery phrase' : 'Cụm từ khôi phục'));
    await settle(t, frames: 4);
    await t.enterText(find.descendant(of: find.byType(RecoveryPhraseInput), matching: find.byType(TextField)).first, '${_kShotPhrase.split(' ').take(9).join(' ')} ');
  }),
  Shot('94_pw_passphrase_dialog', (t, sv, d) async {
    return Scaffold(body: SafeArea(child: d ? const SettingsScreen(initial: SettingsPage.security) : const _SettingsPageHost(SettingsPage.security)));
  }, after: (t, sv, d) async {
    showPassphraseDialog(t.element(find.byType(d ? SettingsScreen : _SettingsPageHost)));
    await settle(t, frames: 4);
    final fields = find.descendant(of: find.byType(PasswordField), matching: find.byType(TextField));
    await t.enterText(fields.at(0), 'trangsang');
    await t.enterText(fields.at(1), 'trangsa');
  }),
  Shot('95_pw_onboarding_restore_phrase', (t, sv, d) async => const OnboardingScreen(initialStep: 4), after: (t, sv, d) async {
    await t.enterText(find.descendant(of: find.byType(RecoveryPhraseInput), matching: find.byType(TextField)).first, _kShotPhrase);
    FocusManager.instance.primaryFocus?.unfocus();
  }),
  Shot('96_pw_locked_chats_prompt', (t, sv, d) async {
    sv.appLock.setPin('2580', appLock: false);
    final ids = sv.chat.sorted.where((c) => !c.isSaved && !c.isGroup).map((c) => c.id).take(4).toList();
    sv.appLock.setChatLocked(ids[1], true);
    return null;
  }, after: (t, sv, d) async {
    openLockedChats(t.element(find.byType(HomeShell)));
    await settle(t, frames: 4);
    await t.tap(find.text('2').last);
    await t.tap(find.text('5').last);
  }),
  Shot('97_pw_locked_chat_gate', (t, sv, d) async {
    sv.appLock.setPin('2580', appLock: false);
    final id = sv.chat.sorted.where((c) => !c.isSaved && !c.isGroup).map((c) => c.id).first;
    sv.appLock.setChatLocked(id, true);
    sv.nav.openConv(id);
    return d ? null : ChatView(conv: id);
  }),
  // Recovery phrase: show (3×8 / 2×12), entry with suggestions, "check your copy".
  Shot('99a_phrase_show', (t, sv, d) async => const OnboardingScreen(initialStep: 3, previewPhrase: _kShotPhrase)),
  Shot('99b_phrase_entry_suggest', (t, sv, d) async => const OnboardingScreen(initialStep: 4), after: (t, sv, d) async {
    // five good words and a misspelt sixth, then 'ca' typed in box 7
    await t.enterText(_phraseBox(0), '${_kShotPhrase.split(' ').take(5).join(' ')} cagx ');
    await settle(t, frames: 2);
    await t.enterText(_phraseBox(6), 'ca');
  }),
  Shot('99c_phrase_entry_checksum', (t, sv, d) async => const OnboardingScreen(initialStep: 4), after: (t, sv, d) async {
    final w = _kShotPhrase.split(' ');
    final t2 = w[2];
    w[2] = w[3];
    w[3] = t2;
    await t.enterText(_phraseBox(0), w.join(' '));
    await settle(t, frames: 2);
    FocusManager.instance.primaryFocus?.unfocus();
  }),
  Shot('99d_phrase_entry_legacy', (t, sv, d) async => const OnboardingScreen(initialStep: 4), after: (t, sv, d) async {
    await t.enterText(_phraseBox(0), _kShotLegacyPhrase);
    await settle(t, frames: 4);
    FocusManager.instance.primaryFocus?.unfocus();
  }),
  Shot('99e_phrase_check', (t, sv, d) async => const OnboardingScreen(initialStep: 5, previewPhrase: _kShotPhrase, previewCheckPositions: [2, 11, 19]), after: (t, sv, d) async {
    final f = find.descendant(of: find.byType(PhraseVerify), matching: find.byType(TextField));
    await t.enterText(f.at(0), 'scissors');
    await settle(t, frames: 2);
    await t.enterText(f.at(1), 'cag');
  }),
  Shot('99f_phrase_check_wrong', (t, sv, d) async => const OnboardingScreen(initialStep: 5, previewPhrase: _kShotPhrase, previewCheckPositions: [2, 11, 19]), after: (t, sv, d) async {
    final f = find.descendant(of: find.byType(PhraseVerify), matching: find.byType(TextField));
    await t.enterText(f.at(0), 'scissors');
    await t.enterText(f.at(1), 'cage');
    await t.enterText(f.at(2), 'door');
    await settle(t, frames: 2);
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t, frames: 2);
    await t.tap(find.byType(SecurePrimaryButton).first);
  }),
  Shot('99g_phrase_settings_dialog', (t, sv, d) async {
    return Scaffold(body: SafeArea(child: d ? const SettingsScreen(initial: SettingsPage.security) : const _SettingsPageHost(SettingsPage.security)));
  }, after: (t, sv, d) async {
    showSecureDialog<bool>(t.element(find.byType(d ? SettingsScreen : _SettingsPageHost)), builder: (_) => const RecoveryPhraseDialog(phrase: _kShotPhrase));
  }),
  // File previews before download (PDF first page, first lines of code/text).
  Shot('fv0_chat_file_previews', (t, sv, d) async {
    final conv = sv.chat.sorted.firstWhere((c) => c.title.contains('Hoàng Nam')).id;
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }),
  Shot('fv5_code_preview_sheet', (t, sv, d) async {
    final conv = sv.chat.sorted.firstWhere((c) => c.title.contains('Hoàng Nam')).id;
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, after: (t, sv, d) async {
    await _tapFilePreview(t, '.py');
  }),
  Shot('fv6_pdf_preview_sheet', (t, sv, d) async {
    final conv = sv.chat.sorted.firstWhere((c) => c.title.contains('Hoàng Nam')).id;
    sv.nav.openConv(conv);
    return d ? null : ChatView(conv: conv);
  }, after: (t, sv, d) async {
    await _tapFilePreview(t, '.pdf');
  }),
  Shot('98_pw_set_pin_confirm', (t, sv, d) async => null, after: (t, sv, d) async {
    askNewPin(t.element(find.byType(HomeShell)));
    await settle(t, frames: 4);
    for (final k in ['2', '5', '8', '0']) {
      await t.tap(find.text(k).last);
    }
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(t, frames: 4);
    await t.tap(find.text('2').last);
  }),
];

/// Scrolls the chat until the preview of the file ending in [ext] shows, then taps it.
Future<void> _tapFilePreview(WidgetTester t, String ext) async {
  final f = find.byWidgetPredicate((w) => w is FilePreviewPane && w.ref.name.endsWith(ext));
  final list = find.descendant(of: find.byType(ChatView), matching: find.byType(Scrollable)).first;
  await t.dragUntilVisible(f, list, const Offset(0, 200));
  await settle(t, frames: 3);
  await t.tap(f.last);
}

/// Recovery phrase in the core's format (24 BIP39 words) for screenshots.
const _kShotPhrase = kMockRecoveryPhrase;

/// The same account's phrase as printed by older versions (base32 groups).
const _kShotLegacyPhrase = 'aebag-bafay-dqqci-kbmga-2dqpc-airee-yucul-bogaz-dinry-hi6d4-qpbum-e';

Finder _phraseBox(int i) => find.descendant(of: find.byType(RecoveryPhraseInput), matching: find.byType(TextField)).at(i);

Future<void> _openEmoji(WidgetTester t, AppServices sv) async {
  await t.tap(find.byTooltip(sv.settings.locale == 'en' ? 'Emoji' : 'Biểu tượng cảm xúc').first);
  await settle(t, frames: 4);
}

Finder _emojiSearch() => find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').contains(RegExp('biểu tượng|emoji', caseSensitive: false)));

/// Marks a friend as blocked (UI only) and returns their peer id.
String _blockFriend(AppServices sv, int i) {
  final c = _friend(sv, i);
  sv.contacts.onContact({'peer': c.peer, 'short_id': c.shortId, 'name': c.name, 'status': 4, 'online': false, 'has_avatar': c.hasAvatar});
  return c.peer;
}

/// Mobile settings sub-page as it appears after tapping a row.
class _SettingsPageHost extends StatelessWidget {
  const _SettingsPageHost(this.page);
  final SettingsPage page;
  @override
  Widget build(BuildContext context) => SettingsSubPage(page: page);
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String path) async {
  await tester.runAsync(() async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: tester.view.devicePixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final f = File(path);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  final filter = Platform.environment['SHOT_FILTER'];
  final themeFilter = Platform.environment['SHOT_THEME'];
  final langs = (Platform.environment['SHOT_LANGS'] ?? 'vi').split(',');

  setUpAll(loadFonts);

  // Small phones (320 dp wide): screens that overflowed there, in both
  // languages. A layout overflow fails the test, so regressions are caught.
  const narrow = {
    '01_chats', '17_files', '27_chat_photos_wallpaper', '34_media_viewer', '36_attach_menu', '40_create_menu',
    '46_bot_chat', '72_chat_blocked', '92_pw_forgot_pin', '99d_phrase_entry_legacy', 'fx1_call_effects', '19_settings',
  };
  if (Platform.environment['SHOT_NARROW'] != '0') {
    for (final shot in shots) {
      if (!narrow.contains(shot.name) || !shot.mobile) continue;
      if (filter != null && !shot.name.contains(filter)) continue;
      for (final lang in const ['vi', 'en']) {
        final name = '${shot.name}_320_dark${lang == 'vi' ? '' : '_$lang'}';
        testWidgets(name, (tester) async {
          setSize(tester, const Size(320, 640), dpr: 2);
          final sv = await makeServices(tester, locale: lang, theme: ThemeMode.dark);
          final home = await shot.setup(tester, sv, false);
          final key = GlobalKey();
          await tester.pumpWidget(RepaintBoundary(key: key, child: LumoraApp(services: sv, home: home)));
          await settle(tester);
          if (shot.after != null) {
            await shot.after!(tester, sv, false);
            await settle(tester, frames: 6);
          }
          for (var i = 0; i < (shot.video ? 4 : 2); i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
            await tester.pump(const Duration(milliseconds: 40));
          }
          await _capture(tester, key, 'screenshots/narrow/$name.png');
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 100));
          sv.dispose();
          resetSize(tester);
        });
      }
    }
  }

  for (final shot in shots) {
    if (filter != null && !shot.name.contains(filter)) continue;
    for (final desktop in [true, false]) {
      if (desktop && !shot.desktop || !desktop && !shot.mobile) continue;
      for (final theme in [ThemeMode.dark, ThemeMode.light]) {
        if (themeFilter != null && theme.name != themeFilter) continue;
        for (final lang in langs) {
          final name = '${shot.name}_${desktop ? 'desktop' : 'mobile'}_${theme.name}${lang == 'vi' ? '' : '_$lang'}';
          testWidgets(name, (tester) async {
            if (desktop) {
              setSize(tester, const Size(1440, 900));
            } else {
              setSize(tester, const Size(390, 844), dpr: 2);
            }
            final sv = await makeServices(tester, locale: lang, theme: theme);
            final home = await shot.setup(tester, sv, desktop);
            final key = GlobalKey();
            await tester.pumpWidget(RepaintBoundary(key: key, child: LumoraApp(services: sv, home: home)));
            await settle(tester);
            if (shot.after != null) {
              await shot.after!(tester, sv, desktop);
              await settle(tester, frames: 6);
            }
            {
              // Let real-time image decodes (avatars, photos, video frames) complete.
              for (var i = 0; i < (shot.video ? 4 : 2); i++) {
                await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
                await tester.pump(const Duration(milliseconds: 40));
              }
            }
            await _capture(tester, key, 'screenshots/$name.png');
            await tester.pumpWidget(const SizedBox());
            await tester.pump(const Duration(seconds: 100)); // flush ring/expiry timers
            sv.dispose();
            resetSize(tester);
          });
        }
      }
    }
  }
}
