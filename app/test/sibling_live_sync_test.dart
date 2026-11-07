// Multi-device: what changes on another device of the same account shows here
// at once, without restarting the app or reopening the screen — sticker packs,
// the Bot Studio chat and bots, privacy switches, wallpapers, mute timers,
// history policy, storage policy, my profile (name, cover), a friend's
// nickname, the device list — and local search ignores case and diacritics.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/bots/botfather.dart';
import 'package:lumora/ui/chats/forward_sheet.dart';
import 'package:lumora/ui/chats/stickers.dart';
import 'package:lumora/ui/devices/my_devices.dart';
import 'package:lumora/ui/friends/friends_screen.dart';
import 'package:lumora/ui/settings/profile_editor.dart';
import 'package:lumora/ui/settings/settings_screen.dart';
import 'package:lumora/ui/widgets/common.dart' show SwitchRow;

import 'helpers.dart';

/// Core events reach EventHub in the real-async zone; debounced reloads run
/// on real or fake time — both are let through.
Future<void> _flush(WidgetTester t) async {
  for (var i = 0; i < 3; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 250));
  }
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 350)));
  for (var i = 0; i < 3; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await t.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

Future<void> _show(WidgetTester t, AppServices sv, Widget page) async {
  await t.pumpWidget(LumoraApp(services: sv, home: Scaffold(body: page), overlays: false));
  await _flush(t);
}

MockLumoraApi _mock(AppServices sv) => sv.api as MockLumoraApi;

bool _switchOf(WidgetTester t, String title) =>
    t.widget<Switch>(find.descendant(of: find.ancestor(of: find.text(title), matching: find.byType(SwitchRow)), matching: find.byType(Switch))).value;

void main() {
  setUpAll(loadFonts);

  group('synced from another device, live', () {
    testWidgets('sticker picker reloads on `stickers`; a missing sticker image shows once it arrives', (t) async {
      setSize(t, const Size(900, 700));
      final sv = await makeServices(t, locale: 'en');
      final mock = _mock(sv);
      mock.missingStickersForTest.add('st_beach');
      await _show(t, sv, Column(children: [
        const SizedBox(width: 160, height: 160, child: StickerImage(hash: 'st_beach', size: 150)),
        Expanded(child: StickerPanel(onSend: (_) {})),
      ]));
      expect(find.text('Made on the phone'), findsNothing);
      expect(find.descendant(of: find.byType(StickerImage).first, matching: find.byType(Image)), findsNothing, reason: 'not here yet');

      // a pack made on another device, and the sticker image copied over
      await t.runAsync(() => mock.request('sticker_pack_create', {'name': 'Made on the phone'}));
      mock.missingStickersForTest.clear();
      mock.emitForTest('stickers');
      await _flush(t);
      expect(find.text('Made on the phone'), findsOneWidget);
      expect(find.descendant(of: find.byType(StickerImage).first, matching: find.byType(Image)), findsOneWidget);
      await _done(t, sv);
    });

    testWidgets('Bot Studio: chat lines and bots made on another device show in the open chat', (t) async {
      setSize(t, const Size(900, 900));
      final sv = await makeServices(t, locale: 'en');
      final mock = _mock(sv);
      await _show(t, sv, const BotFatherChat(embedded: true));
      expect(find.text('/newbot'), findsWidgets); // (the chip)

      await t.runAsync(() => mock.request('botfather_append', {
            'entries': [
              {'mine': true, 'text': 'typed on the phone', 'ts': 1},
              {'mine': false, 'text': 'answered on the phone', 'ts': 2},
            ],
          }));
      mock.emitForTest('settings', {'key': 'privacy.botfather_chat'});
      await _flush(t);
      expect(find.text('typed on the phone'), findsOneWidget);
      expect(find.text('answered on the phone'), findsOneWidget);

      // cleared on the phone
      await t.runAsync(() => mock.request('botfather_clear'));
      mock.emitForTest('settings', {'key': 'privacy.botfather_chat'});
      await _flush(t);
      expect(find.text('typed on the phone'), findsNothing);
      await _done(t, sv);
    });

    testWidgets('My bots: a bot made / deleted on another device', (t) async {
      setSize(t, const Size(900, 900));
      final sv = await makeServices(t, locale: 'en');
      final mock = _mock(sv);
      await _show(t, sv, SingleChildScrollView(child: MyBotsPage(onCreate: () {})));
      expect(find.text('Phone Bot'), findsNothing);

      await t.runAsync(() => mock.request('bot_create', {'name': 'Phone Bot', 'username': 'phone_bot'}));
      mock.emitForTest('settings', {'key': 'botfather.bots'});
      await _flush(t);
      expect(find.text('Phone Bot'), findsOneWidget);

      await t.runAsync(() => mock.request('bot_delete', {'username': 'phone_bot'}));
      mock.emitForTest('settings', {'key': 'botfather.bots'});
      await _flush(t);
      expect(find.text('Phone Bot'), findsNothing);
      await _done(t, sv);
    });

    testWidgets('privacy switches follow the account (and are not pushed back)', (t) async {
      setSize(t, const Size(1200, 1600));
      final sv = await makeServices(t, locale: 'en');
      final mock = _mock(sv);
      await _show(t, sv, const SettingsSubPage(page: SettingsPage.privacy));
      expect(_switchOf(t, 'Show read receipts'), isTrue);
      expect(_switchOf(t, 'Let strangers find me by ID'), isTrue);

      await t.runAsync(() => mock.request('settings_set', {'read_receipts': false, 'typing': false, 'discoverable_by_id': false}));
      mock.emitForTest('settings', {'key': 'privacy.read_receipts'});
      mock.emitForTest('settings', {'key': 'privacy.typing'});
      mock.emitForTest('settings', {'key': 'privacy.discoverable'});
      await _flush(t);
      expect(sv.settings.readReceipts, isFalse);
      expect(sv.settings.typingIndicators, isFalse);
      expect(_switchOf(t, 'Show read receipts'), isFalse);
      expect(_switchOf(t, 'Let strangers find me by ID'), isFalse);
      final core = (await t.runAsync(() => sv.api.settingsGet()))!;
      expect(core['read_receipts'], isFalse, reason: "this device's old value never overwrites the account's");
      expect(core['typing'], isFalse);
      await _done(t, sv);
    });

    testWidgets('wallpaper, history policy and mute of a chat follow', (t) async {
      final sv = await makeServices(t, locale: 'en');
      final mock = _mock(sv);
      await _flush(t);
      final conv = sv.chat.convs.values.firstWhere((c) => c.id.startsWith('d:') && !c.muted).id;
      await t.runAsync(() => sv.chat.loadWallpaper(conv));
      await t.runAsync(() => sv.chat.loadRetention(conv));
      expect(sv.chat.wallpaperOf(conv), isNull);
      // a mention count this app keeps itself survives the refresh
      final c0 = sv.chat.convs[conv]!;
      sv.chat.onConversation({'id': conv, 'kind': 0, 'title': c0.title, 'last_ts': c0.lastTs, 'unread': 2, 'last_text': c0.lastText, 'mentions': 1});

      await t.runAsync(() => mock.request('set_wallpaper', {'conv': conv, 'wallpaper': 'color:#112233'}));
      mock.emitForTest('settings', {'key': 'wallpaper.$conv'});
      await t.runAsync(() => mock.request('set_retention', {'conv': conv, 'mode': '7d'}));
      mock.emitForTest('settings', {'key': 'retention.$conv'});
      mock.muteFromOtherDevice(conv, DateTime.now().millisecondsSinceEpoch + 3600000);
      await _flush(t);
      expect(sv.chat.wallpaperOf(conv), 'color:#112233');
      expect(sv.chat.retention[conv], '7d');
      expect(sv.chat.convs[conv]!.muted, isTrue);
      expect(sv.chat.convs[conv]!.mentions, 1);

      // the default wallpaper (all chats) changed there too
      await t.runAsync(() => mock.request('set_wallpaper', {'conv': conv, 'wallpaper': null}));
      await t.runAsync(() => mock.request('set_wallpaper', {'conv': 'default', 'wallpaper': 'aurora'}));
      mock.emitForTest('settings', {'key': 'wallpaper.$conv'});
      mock.emitForTest('settings', {'key': 'wallpaper.default'});
      mock.muteFromOtherDevice(conv, 0);
      await _flush(t);
      expect(sv.chat.wallpaperOf(conv), 'aurora');
      expect(sv.chat.convs[conv]!.muted, isFalse);
      await _done(t, sv);
    });

    testWidgets('storage policy follows', (t) async {
      final sv = await makeServices(t, locale: 'en');
      final mock = _mock(sv);
      await _flush(t);
      await t.runAsync(() => sv.net.loadStorage());
      final before = StoragePolicy.fromJson((sv.net.storage!['policy'] as Map).cast<String, dynamic>());
      final days = before.mediaDays == 7 ? 30 : 7;
      await t.runAsync(() => mock.request('set_storage_policy', {'media_days': days}));
      mock.emitForTest('settings', {'key': 'storage.policy'});
      await _flush(t);
      expect(StoragePolicy.fromJson((sv.net.storage!['policy'] as Map).cast<String, dynamic>()).mediaDays, days);
      await _done(t, sv);
    });

    testWidgets('my name, bio and cover changed on another device', (t) async {
      setSize(t, const Size(900, 1200));
      final sv = await makeServices(t, locale: 'en');
      final mock = _mock(sv);
      await _show(t, sv, const SingleChildScrollView(child: ProfileEditor(inline: true)));
      final coverBefore = sv.session.coverBytes;
      expect(find.widgetWithText(TextField, 'Minh from the phone'), findsNothing);

      await t.runAsync(() => mock.request('set_profile', {'name': 'Minh from the phone', 'bio': 'bio from the phone'}));
      await t.runAsync(() => mock.request('set_cover', {'cover': 'AQIDBA=='}));
      mock.emitForTest('profile', {'key': 'profile.name', 'name': 'Minh from the phone'});
      mock.emitForTest('profile', {'key': 'profile.cover'});
      await _flush(t);
      expect(sv.session.me?.name, 'Minh from the phone');
      expect(sv.session.coverBytes, isNot(coverBefore));
      expect(sv.session.coverBytes, [1, 2, 3, 4]);
      // the open editor shows it (nothing was being typed there)
      expect(find.widgetWithText(TextField, 'Minh from the phone'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'bio from the phone'), findsOneWidget);
      await _done(t, sv);
    });

    testWidgets("a friend's nickname set on another device: contacts and the chat title", (t) async {
      final sv = await makeServices(t, locale: 'en');
      final mock = _mock(sv);
      await _flush(t);
      final peer = sv.contacts.byPeer.values.firstWhere((c) => c.name == 'Nguyễn Minh Anh').peer;
      sv.chat.ensureDirect(sv.contacts[peer]!);
      await t.runAsync(() => mock.request('rename_contact', {'peer': peer, 'alias': 'Anh Minh (công ty)'}));
      await _flush(t);
      expect(sv.contacts.nameOf(peer), 'Anh Minh (công ty)');
      expect(sv.chat.convs['d:$peer']!.title, 'Anh Minh (công ty)');
      await _done(t, sv);
    });

    testWidgets('device list: live on `devices`, loaded on state_synced', (t) async {
      setSize(t, const Size(1200, 1200));
      final sv = await makeServices(t, locale: 'en');
      final mock = _mock(sv);
      await _show(t, sv, const SingleChildScrollView(child: MyDevicesPage()));
      final list = sv.devices.list!;
      final n = list.devices.length;
      mock.emitForTest('devices', {
        'account': list.account,
        'device': list.device,
        'primary': list.primary,
        'version': list.version + 1,
        'devices': [
          for (final d in list.devices) {'device': d.device, 'name': d.name, 'kind': d.kind, 'primary': d.primary, 'this': d.isThis, 'os': d.os},
          {'device': 'newphone', 'name': 'Phone linked elsewhere', 'kind': 1, 'os': 'android', 'added': 1, 'last_seen': 1},
        ],
      });
      await _flush(t);
      expect(sv.devices.list!.devices.length, n + 1);
      expect(find.text('Phone linked elsewhere'), findsOneWidget);

      // a newly linked device: the list is read again once the account state is in
      sv.devices.reset();
      mock.emitForTest('link_state', {'state': 'state_synced'});
      await _flush(t);
      expect(sv.devices.list?.devices.length, n);
      await _done(t, sv);
    });
  });

  group('search ignores case and diacritics', () {
    testWidgets('chat list filter, friends, forward sheet, message search', (t) async {
      setSize(t, const Size(900, 1200));
      final sv = await makeServices(t, locale: 'en');
      await _flush(t);
      sv.chat.onConversation({'id': 'g:foldtest', 'kind': 1, 'title': 'Tiếng Việt Đẹp', 'last_ts': DateTime.now().millisecondsSinceEpoch, 'unread': 0, 'last_text': ''});
      for (final q in ['tieng viet', 'TIENG', 'dep', 'Tiếng Việt', 'tiếng việt']) {
        expect(sv.chat.filtered(ChatFilter.all, q).map((c) => c.id), contains('g:foldtest'), reason: q);
      }
      expect(sv.chat.filtered(ChatFilter.all, 'tieng anh').map((c) => c.id), isNot(contains('g:foldtest')));

      // friends screen
      await _show(t, sv, const FriendsScreen());
      await t.enterText(find.byType(TextField).first, 'dang mai');
      await _flush(t);
      expect(find.text('Đặng Mai Linh'), findsOneWidget);
      expect(find.text('Nguyễn Minh Anh'), findsNothing);

      // forward sheet
      await _show(t, sv, Builder(builder: (c) => TextButton(onPressed: () => pickConversation(c, title: 'Forward'), child: const Text('open picker'))));
      await t.tap(find.text('open picker'));
      await _flush(t);
      await t.enterText(find.byType(TextField).first, 'tieng viet dep');
      await _flush(t);
      expect(find.text('Tiếng Việt Đẹp'), findsOneWidget);

      // message search: the query goes to the core unchanged (it folds)
      final some = sv.chat.convs.values.firstWhere((c) => c.id.startsWith('d:')).id;
      await t.runAsync(() => sv.api.request('send_text', {'conv': some, 'text': 'Học Tiếng Việt mỗi ngày'}));
      final found = (await t.runAsync(() => sv.api.search('tieng viet moi ngay')))!;
      expect(found.map((m) => m.body), contains('Học Tiếng Việt mỗi ngày'));
      await _done(t, sv);
    });
  });
}
