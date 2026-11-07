// Regression tests for core events the app ignored or mishandled (audit of
// 2026-11-06): leaving / being removed from a group, renames, pinned bar,
// calls answered elsewhere, avatars, a friend's linked device, call_peer,
// profile / scheduled_failed / storage_low.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/state/stores.dart';
import 'package:lumora/ui/chats/chat_view.dart';
import 'package:lumora/ui/chats/composer.dart';
import 'package:lumora/ui/groups/group_info.dart';
import 'package:lumora/platform/android_bridge.dart';
import 'package:lumora/ui/remote/remote_layer.dart';
import 'package:lumora/ui/shell/notifications.dart';
import 'package:lumora/ui/widgets/app_icons.dart';

import 'helpers.dart';

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

// Core events reach the stores in the real-async zone (see helpers / makeServices).
Future<void> _flush(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await settle(t);
}

MockLumoraApi _api(AppServices sv) => sv.api as MockLumoraApi;

String _group(AppServices sv) => sv.chat.convs.values.firstWhere((c) => c.id.startsWith('g:') && !c.isCommunity).id;

void main() {
  setUpAll(loadFonts);

  testWidgets('leaving a group: the chat goes and does not come back', (t) async {
    final sv = await makeServices(t);
    final conv = _group(sv);
    final gid = conv.substring(2);
    setSize(t, const Size(500, 1400));
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: GroupInfoView(gid: gid, embedded: true))));
    await settle(t);
    await t.scrollUntilVisible(find.text('Rời nhóm'), 300, scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('Rời nhóm'));
    await settle(t);
    await t.tap(find.text('Rời'));
    await _flush(t);
    expect(sv.chat.convs.containsKey(conv), isFalse);
    await t.runAsync(() => sv.chat.load());
    expect(sv.chat.convs.containsKey(conv), isFalse, reason: 'a reload must not bring the left group back');
    await _done(t, sv);
  });

  testWidgets('removed from a group (here or elsewhere): read-only chat; left elsewhere: chat closes', (t) async {
    final sv = await makeServices(t);
    final conv = _group(sv);
    final gid = conv.substring(2);
    setSize(t, const Size(900, 800));
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: ChatView(conv: conv, embedded: true))));
    await settle(t);
    expect(find.byType(Composer), findsOneWidget);
    _api(sv).emitForTest('group_removed', {'gid': gid, 'conv': conv, 'left': false});
    await _flush(t);
    expect(find.byType(Composer), findsNothing, reason: 'kicked: no more sending');
    expect(find.text('Bạn không còn là thành viên của nhóm này'), findsOneWidget);
    expect(sv.chat.convs.containsKey(conv), isTrue, reason: 'the history stays');
    // added back
    _api(sv).emitForTest('group', {'gid': gid, 'name': sv.chat.convs[conv]!.title, 'my_role': 'member'});
    await _flush(t);
    expect(find.byType(Composer), findsOneWidget);
    // left on my other device
    _api(sv).emitForTest('group_removed', {'gid': gid, 'conv': conv, 'left': true});
    await _flush(t);
    expect(sv.chat.convs.containsKey(conv), isFalse);
    await _done(t, sv);
  });

  testWidgets('group info follows `group` events (a kick removes the admin buttons)', (t) async {
    final sv = await makeServices(t);
    // a group I manage (admin buttons shown)
    GroupInfo? info;
    for (final c in sv.chat.convs.values.where((c) => c.id.startsWith('g:') && !c.isCommunity)) {
      final g = await t.runAsync(() => sv.api.groupInfo(c.gid!));
      if (g != null && g.canManage) {
        info = g;
        break;
      }
    }
    final gid = info!.gid;
    setSize(t, const Size(500, 1400));
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: GroupInfoView(gid: gid, embedded: true))));
    await settle(t);
    final st = t.state(find.byType(GroupInfoView));
    expect(find.byIcon(AppIcons.camera), findsOneWidget, reason: 'admin: can change the group photo');
    // the core removed me: group_info now says my_role none
    _api(sv).setGroupRoleForTest(gid, 'none');
    _api(sv).emitForTest('group', {'gid': gid, 'name': info.name, 'my_role': 'none'});
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
    await _flush(t);
    expect(st.mounted, isTrue);
    expect(find.byIcon(AppIcons.camera), findsNothing, reason: 'no admin buttons after a kick');
    await t.scrollUntilVisible(find.text('Bạn không còn là thành viên của nhóm này'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Rời nhóm'), findsNothing);
    await _done(t, sv);
  });

  testWidgets('a rename reaches the chat list / header', (t) async {
    final sv = await makeServices(t);
    final conv = _group(sv);
    _api(sv).emitForTest('group', {'gid': conv.substring(2), 'name': 'Tên mới', 'my_role': 'owner'});
    await _flush(t);
    expect(sv.chat.convs[conv]!.title, 'Tên mới');
    await _done(t, sv);
  });

  testWidgets('pinned bar follows pins, deletes and removals made elsewhere', (t) async {
    final sv = await makeServices(t);
    final conv = sv.chat.convs.values.firstWhere((c) => c.id.startsWith('d:') && !c.isSaved).id;
    setSize(t, const Size(900, 800));
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: ChatView(conv: conv, embedded: true))));
    await settle(t);
    final th = sv.chat.thread(conv);
    final a = th.messages.lastWhere((m) => !m.pinned && !m.isSystem);
    final b = th.messages.firstWhere((m) => !m.pinned && !m.isSystem && m.id != a.id);
    List<String> pins() => (sv.chat.pinned[conv] ?? const []).map((m) => m.id).toList();
    final before = pins().length;
    _api(sv).emitForTest('message_update', {'conv': conv, 'id': a.id, 'pinned': true});
    _api(sv).emitForTest('message_update', {'conv': conv, 'id': b.id, 'pinned': true});
    await _flush(t);
    expect(pins(), containsAll([a.id, b.id]));
    _api(sv).emitForTest('message_update', {'conv': conv, 'id': a.id, 'pinned': false});
    await _flush(t);
    expect(pins(), isNot(contains(a.id)));
    _api(sv).emitForTest('message_update', {'conv': conv, 'id': b.id, 'deleted': true});
    await _flush(t);
    expect(pins(), isNot(contains(b.id)), reason: 'a deleted message leaves the bar');
    _api(sv).emitForTest('message_update', {'conv': conv, 'id': a.id, 'pinned': true});
    await _flush(t);
    _api(sv).emitForTest('message_update', {'conv': conv, 'id': a.id, 'removed': true});
    await _flush(t);
    expect(pins(), isNot(contains(a.id)), reason: 'a purged message leaves the bar');
    expect(th.byId(a.id), isNull, reason: '`removed` still leaves the chat');
    expect(pins().length, before);
    await _done(t, sv);
  });

  testWidgets('declined on my other device: no missed-call notice', (t) async {
    final sv = await makeServices(t);
    final peer = sv.contacts.all.first.peer;
    Map<String, dynamic> ev(String state, [String? reason]) => {
          'call_id': 'c9', 'conv': 'd:$peer', 'state': state, 'video': false, 'from': peer,
          'participants': [{'peer': peer, 'account': peer, 'name': 'x'}],
          'reason': ?reason,
        };
    _api(sv).emitForTest('call', ev('incoming'));
    await _flush(t);
    _api(sv).emitForTest('call', ev('ended', 'declined_elsewhere'));
    await _flush(t);
    expect(sv.notices.items.where((n) => n.kind == NoticeKind.missedCall), isEmpty);
    // a real missed call still is one
    _api(sv).emitForTest('call', {...ev('incoming'), 'call_id': 'c10'});
    await _flush(t);
    _api(sv).emitForTest('call', {...ev('ended'), 'call_id': 'c10'});
    await _flush(t);
    expect(sv.notices.items.where((n) => n.kind == NoticeKind.missedCall), hasLength(1));
    await _done(t, sv);
  });

  testWidgets('avatars: a group change refetches a cached one; a removed avatar goes', (t) async {
    final sv = await makeServices(t);
    // a group I own: changing the picture needs manage_community ("change group info")
    final gid = sv.chat.convs.values.firstWhere((c) => c.id.startsWith('g:') && !c.isCommunity && c.title.startsWith('Dự án')).id.substring(2);
    // cached "no avatar" (before the group got one)
    sv.avatars.group(gid);
    await _flush(t);
    await t.runAsync(() => sv.api.groupMeta(gid, avatar: 'AQID'));
    await _flush(t);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    expect(sv.avatars.group(gid), Uint8List.fromList([1, 2, 3]), reason: 'a cached null must not stick');
    _api(sv).emitForTest('group', {'gid': gid, 'name': 'G', 'has_avatar': false, 'my_role': 'owner'});
    await _flush(t);
    expect(sv.avatars.group(gid), isNull);
    // a contact removes their avatar
    final peer = sv.contacts.all.first.peer;
    sv.avatars.invalidate(peer);
    sv.avatars.of(peer);
    await _flush(t);
    _api(sv).emitForTest('contact', {'peer': peer, 'has_avatar': false});
    await _flush(t);
    expect(sv.avatars.of(peer, hasAvatar: false), isNull);
    await _done(t, sv);
  });

  test('a friend on a linked device: their video, name and call_peer state', () {
    final calls = CallStore(MockLumoraApi(timers: false));
    const acct = 'friendaccount', dev = 'frienddevice';
    calls.onCall({
      'call_id': 'c1', 'conv': 'd:$acct', 'state': 'active', 'video': true, 'from': acct,
      'participants': [{'peer': dev, 'account': acct, 'name': 'Bình'}],
    });
    final c = calls.call!;
    expect(c.peer, acct);
    expect(c.accountOf(dev), acct);
    expect(c.names[dev], 'Bình');
    calls.onVideoStream({'call_id': 'c1', 'peer': dev, 'stream': 7, 'kind': 'camera'});
    expect(calls.call!.streamOf(acct), 7, reason: 'frames are keyed by the device');
    expect(calls.call!.accountOf(dev), acct, reason: 'kept across stream updates');
    // real mic / camera state (was a placeholder)
    expect(calls.peerMuted(dev), isFalse);
    calls.onCallPeer({'call_id': 'c1', 'peer': dev, 'mic': false, 'cam': true, 'screen': false});
    expect(calls.peerMuted(dev), isTrue);
    expect(calls.peerCamOff(dev), isFalse);
    calls.onCallPeer({'call_id': 'other', 'peer': dev, 'mic': true, 'cam': false, 'screen': false});
    expect(calls.peerMuted(dev), isTrue, reason: 'another call\'s state is ignored');
    calls.onCall({'call_id': 'c1', 'conv': 'd:$acct', 'state': 'ended'});
    expect(calls.peerMuted(dev), isFalse);
  });

  testWidgets('remote request from a friend\'s linked device: no stranger warning', (t) async {
    final sv = await makeServices(t);
    final friend = sv.contacts.all.firstWhere((c) => c.status == ContactStatus.friend);
    setSize(t, const Size(500, 900));
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: const Scaffold(body: RemoteRequestDialog())));
    _api(sv).emitForTest('remote_request', {'session': 's1', 'peer': 'anotherdevicekey', 'account': friend.peer, 'device': 'anotherdevicekey', 'name': 'x', 'ask': true});
    await _flush(t);
    expect(find.text(friend.displayName), findsWidgets);
    expect(find.textContaining('không có trong danh sách bạn bè'), findsNothing);
    expect(sv.notices.items.first.title, friend.displayName);
    // my own other device
    sv.remote.request = null;
    _api(sv).emitForTest('remote_request', {'session': 's2', 'peer': 'mine', 'account': 'mine', 'device': 'mydev2', 'own': true, 'name': 'Laptop'});
    await _flush(t);
    expect(find.textContaining('không có trong danh sách bạn bè'), findsNothing);
    // a stranger still gets the warning
    sv.remote.request = null;
    _api(sv).emitForTest('remote_request', {'session': 's3', 'peer': 'stranger', 'account': 'stranger', 'device': 'stranger', 'name': 'Mẹ'});
    await _flush(t);
    expect(find.textContaining('không có trong danh sách bạn bè'), findsOneWidget);
    await _done(t, sv);
  });

  testWidgets('scheduled_failed and storage_low reach the bell', (t) async {
    final sv = await makeServices(t);
    _api(sv).emitForTest('scheduled_failed', {'id': 1, 'conv': 'd:x', 'text': 'hẹn giờ', 'at': 0, 'error': 'blocked'});
    _api(sv).emitForTest('storage_low', {'message': 'Bộ nhớ đầy'});
    _api(sv).emitForTest('storage_low', {'message': 'Bộ nhớ đầy'});
    await _flush(t);
    expect(sv.notices.items.where((n) => n.kind == NoticeKind.scheduledFailed), hasLength(1));
    expect(sv.notices.items.where((n) => n.kind == NoticeKind.storageLow), hasLength(1), reason: 'said once, not every 10 minutes');
    await _done(t, sv);
  });

  // ------------------------------------------------------------ second audit

  testWidgets('@mention badge survives the conversation row that follows it', (t) async {
    final sv = await makeServices(t);
    final conv = _group(sv);
    final c = sv.chat.convs[conv]!;
    Map<String, dynamic> row(int unread) => {'id': conv, 'kind': 1, 'title': c.title, 'last_ts': c.lastTs, 'unread': unread, 'last_text': 'x'};
    _api(sv).emitForTest('mention', {'conv': conv, 'id': 'm1', 'author': sv.contacts.all.first.peer, 'text': '@me hi'});
    _api(sv).emitForTest('conversation', row(3));
    await _flush(t);
    expect(sv.chat.convs[conv]!.mentions, 1, reason: 'the row without `mentions` must not reset it');
    _api(sv).emitForTest('conversation', row(0));
    await _flush(t);
    expect(sv.chat.convs[conv]!.mentions, 0, reason: 'read: gone');
    expect(sv.notices.items.first.body, '@me hi', reason: 'the preview from the core');
    await _done(t, sv);
  });

  testWidgets('mention / file notices: not for the chat on screen, nor for a muted one', (t) async {
    final sv = await makeServices(t);
    final conv = _group(sv);
    sv.nav.openConv(conv);
    setSize(t, const Size(900, 800));
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: ChatView(conv: conv, embedded: true))));
    await settle(t);
    final peer = sv.contacts.all.first.peer;
    final before = sv.notices.items.length;
    _api(sv).emitForTest('mention', {'conv': conv, 'id': 'm1', 'author': peer, 'text': 'hi'});
    _api(sv).emitForTest('file', {'id': 'f1', 'conv': conv, 'peer': peer, 'name': 'a.pdf', 'direction': 1, 'state': 0});
    await _flush(t);
    expect(sv.notices.items.length, before, reason: 'reading that chat');
    final other = sv.chat.convs.values.firstWhere((c) => c.id.startsWith('d:') && !c.isSaved).id;
    sv.chat.onConversation({'id': other, 'kind': 0, 'title': 'x', 'muted': true});
    _api(sv).emitForTest('mention', {'conv': other, 'id': 'm2', 'author': peer, 'text': 'hi'});
    _api(sv).emitForTest('file', {'id': 'f2', 'conv': other, 'peer': peer, 'name': 'b.pdf', 'direction': 1, 'state': 0});
    await _flush(t);
    expect(sv.notices.items.length, before, reason: 'muted chat');
    await _done(t, sv);
  });

  test('group members who are not contacts: the name the core knows, not a short id', () {
    final contacts = ContactsStore(MockLumoraApi(timers: false));
    const peer = 'abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrst';
    final before = contacts.nameOf(peer);
    expect(before, endsWith('…'));
    Message.fromJson({'id': '1', 'conv': 'g:x', 'author': peer, 'author_name': 'Bình', 'kind': 'text', 'body': {'text': 'hi'}, 'hlc': 1});
    expect(contacts.nameOf(peer), 'Bình');
    GroupMember.fromJson({'peer': '${peer}x', 'name': 'An', 'role': 'member'});
    expect(contacts.nameOf('${peer}x'), 'An');
  });

  test('remote requests queue up; two viewers: one leaving keeps the banner', () {
    final r = RemoteStore(MockLumoraApi(timers: false));
    r.onRequest({'session': 'a', 'peer': 'p1', 'name': 'A'});
    r.onRequest({'session': 'b', 'peer': 'p2', 'name': 'B'});
    expect(r.request?.session, 'a', reason: 'the first one is not replaced');
    r.respond(accept: false);
    expect(r.request?.session, 'b', reason: 'then the next one');
    r.respond(accept: false);
    expect(r.request, isNull);
    // a queued request that timed out leaves the queue
    r.onRequest({'session': 'c', 'peer': 'p1', 'name': 'A'});
    r.onRequest({'session': 'd', 'peer': 'p2', 'name': 'B'});
    r.onState({'session': 'd', 'peer': 'p2', 'state': 'ended', 'role': 'host'});
    r.respond(accept: false);
    expect(r.request, isNull);
    // two viewers at once
    r.onState({'session': 'h1', 'peer': 'v1', 'state': 'active', 'role': 'host'});
    r.onState({'session': 'h2', 'peer': 'v2', 'state': 'active', 'role': 'host'});
    r.onState({'session': 'h2', 'peer': 'v2', 'state': 'ended', 'role': 'host'});
    expect(r.host?.session, 'h1', reason: 'v1 still controls this device');
    r.onState({'session': 'h1', 'peer': 'v1', 'state': 'ended', 'role': 'host'});
    expect(r.host, isNull);
  });

  testWidgets('friend-request notice: Accept only while the request is open', (t) async {
    final sv = await makeServices(t);
    final friend = sv.contacts.all.firstWhere((c) => c.status == ContactStatus.friend);
    sv.notices.add(Notice(kind: NoticeKind.friendRequest, title: friend.displayName, peer: friend.peer));
    setSize(t, const Size(500, 800));
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: const Scaffold(body: NotificationCentre())));
    await settle(t);
    expect(find.byTooltip('Chấp nhận'), findsNothing, reason: 'already a friend (accepted elsewhere)');
    sv.contacts.onContact({'peer': friend.peer, 'name': friend.displayName, 'status': 2});
    await settle(t);
    expect(find.byTooltip('Chấp nhận'), findsOneWidget);
    await _done(t, sv);
  });

  test('Android: call / read-elsewhere notifications are removed; group titles', () {
    expect(AndroidBridge.cancelKeysFor({'event': 'call', 'state': 'incoming'}), isEmpty);
    expect(AndroidBridge.cancelKeysFor({'event': 'call', 'state': 'ended', 'reason': 'answered_elsewhere'}), ['call']);
    expect(AndroidBridge.cancelKeysFor({'event': 'call', 'state': 'active'}), ['call']);
    // 1.0.8 review: a "Join" banner (or another call) ending leaves the ringing call's
    // notification alone; the ringing call's own end removes it
    expect(AndroidBridge.cancelKeysFor({'event': 'call', 'call_id': 'ring', 'state': 'incoming'}), isEmpty);
    expect(AndroidBridge.cancelKeysFor({'event': 'call', 'call_id': 'banner', 'state': 'available'}), isEmpty);
    expect(AndroidBridge.cancelKeysFor({'event': 'call', 'call_id': 'banner', 'state': 'ended'}), isEmpty);
    expect(AndroidBridge.cancelKeysFor({'event': 'call', 'call_id': 'ring', 'state': 'ended'}), ['call']);
    expect(AndroidBridge.cancelKeysFor({'event': 'conversation', 'id': 'd:x', 'unread': 0}), ['d:x']);
    expect(AndroidBridge.cancelKeysFor({'event': 'conversation', 'id': 'd:x', 'unread': 2}), isEmpty);
    final old = AndroidBridge.convTitle;
    AndroidBridge.convTitle = (c) => c == 'g:1' ? 'Nhóm A' : null;
    expect(AndroidBridge.messageTitle('g:1', 'Bình'), 'Nhóm A – Bình');
    expect(AndroidBridge.messageTitle('g:1', 'Lumora'), 'Nhóm A');
    expect(AndroidBridge.messageTitle('d:x', 'Bình'), 'Bình');
    AndroidBridge.convTitle = old;
  });

  testWidgets('busy: a call that rang during another call is a missed call here', (t) async {
    final sv = await makeServices(t);
    final peer = sv.contacts.all.first.peer;
    _api(sv).emitForTest('call', {'call_id': 'b1', 'conv': 'd:$peer', 'state': 'ended', 'reason': 'busy', 'from': peer, 'participants': []});
    await _flush(t);
    expect(sv.notices.items.where((n) => n.kind == NoticeKind.missedCall && n.peer == peer), hasLength(1));
    await _done(t, sv);
  });

  testWidgets('a friend\'s device list follows presence events', (t) async {
    final sv = await makeServices(t);
    final friend = sv.contacts.all.firstWhere((c) => c.status == ContactStatus.friend);
    sv.devices.contactDevices[friend.peer] = [const DeviceInfo(device: 'dev1', name: 'Phone'), const DeviceInfo(device: 'dev2', name: 'Laptop', online: true)];
    _api(sv).emitForTest('presence', {'peer': friend.peer, 'device': 'dev1', 'online': true, 'device_online': true});
    _api(sv).emitForTest('presence', {'peer': friend.peer, 'device': 'dev2', 'online': true, 'device_online': false});
    await _flush(t);
    final l = sv.devices.contactDevices[friend.peer]!;
    expect(l.firstWhere((d) => d.device == 'dev1').online, isTrue);
    expect(l.firstWhere((d) => d.device == 'dev2').online, isFalse);
    expect(l.firstWhere((d) => d.device == 'dev2').lastSeen, greaterThan(0));
    await _done(t, sv);
  });
}
