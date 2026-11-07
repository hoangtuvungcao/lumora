// Message rules (owner decision 2026-11-07): forwarding never leaks a private
// nickname and can hide the sender, 1-1 "delete for everyone" is the author's
// only, edits close after 48 h, self-destructing messages are never copied.
// The core enforces all of it; these tests cover what the app offers.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/app.dart';
import 'package:lumora/core/api.dart';
import 'package:lumora/core/mock_api.dart';
import 'package:lumora/ui/chats/delete_dialogs.dart';
import 'package:lumora/ui/chats/forward_sheet.dart';
import 'package:lumora/ui/chats/message_bubble.dart';

import 'helpers.dart';

Future<void> _done(WidgetTester t, AppServices sv) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 100));
  sv.dispose();
  resetSize(t);
}

Future<void> _flush(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
  await settle(t);
}

final _now = DateTime.now().millisecondsSinceEpoch;

Message _m({
  String id = 'm1',
  String conv = 'd:peer',
  bool mine = false,
  String author = 'peer',
  String text = 'xin chào',
  int? ts,
  int? expires,
  bool deleted = false,
  String? deletedBy,
}) =>
    Message.fromJson({
      'id': id,
      'conv': conv,
      'author': author,
      'mine': mine,
      'kind': 'text',
      'body': deleted ? '' : text,
      'ts': ts ?? _now,
      'expires': ?expires,
      'deleted': deleted,
      'deleted_by': ?deletedBy,
    });

BubbleActions _noActions() => BubbleActions(
      onReply: (_) {},
      onEdit: (_) {},
      onDelete: (_) {},
      onReact: (_, _) {},
      onJumpTo: (_) {},
      onForward: (_) {},
      onPin: (_) {},
      onSave: (_) {},
      onSelect: (_) {},
      onVote: (_, _) {},
    );

Future<void> _tile(WidgetTester t, AppServices sv, Message m, {bool group = false}) async {
  setSize(t, const Size(420, 900));
  await t.pumpWidget(LumoraApp(
    services: sv,
    overlays: false,
    home: Scaffold(
      body: ListView(children: [
        MessageTile(message: m, isGroup: group, firstInGroup: true, lastInGroup: true, actions: _noActions(), myPeer: 'me'),
      ]),
    ),
  ));
  await settle(t);
}

/// Long-press the bubble (phone layout): the action sheet.
Future<void> _openSheet(WidgetTester t, String text) async {
  await t.longPress(find.text(text));
  await settle(t);
}

void main() {
  setUpAll(loadFonts);

  group('unit', () {
    test('edit only my own text, within 48 h', () {
      final now = DateTime.now();
      expect(canEditMessage(_m(mine: true, author: 'me')), isTrue);
      expect(canEditMessage(_m(mine: true, author: 'me', ts: now.subtract(const Duration(hours: 47)).millisecondsSinceEpoch)), isTrue);
      expect(canEditMessage(_m(mine: true, author: 'me', ts: now.subtract(const Duration(hours: 49)).millisecondsSinceEpoch)), isFalse);
      expect(canEditMessage(_m()), isFalse, reason: 'not mine');
      expect(canEditMessage(_m(mine: true, author: 'me', deleted: true, deletedBy: 'me')), isFalse);
    });

    test('self-destructing messages: nothing to copy', () {
      expect(copyableText(_m()), 'xin chào');
      expect(copyableText(_m(expires: _now + 60000)), isNull);
      expect(_m(expires: _now + 60000).selfDestructs, isTrue);
    });

    test('who deleted it', () {
      expect(_m(deleted: true, deletedBy: 'peer').removedByAdmin, isFalse);
      expect(_m(deleted: true, deletedBy: 'admin').removedByAdmin, isTrue);
      expect(_m(deleted: true).removedByAdmin, isFalse, reason: 'older records: the author');
      final u = _m().applyUpdate({'deleted': true, 'body': '', 'deleted_by': 'admin'});
      expect(u.deleted && u.removedByAdmin, isTrue);
    });
  });

  testWidgets('self-destructing message: no Forward / Copy / Save', (t) async {
    final sv = await makeServices(t);
    await _tile(t, sv, _m(text: 'tin thường'));
    await _openSheet(t, 'tin thường');
    expect(find.text('Chuyển tiếp'), findsOneWidget);
    expect(find.text('Sao chép văn bản'), findsOneWidget);
    expect(find.text('Lưu tin nhắn'), findsOneWidget);
    await t.tapAt(const Offset(10, 10));
    await settle(t);

    await _tile(t, sv, _m(id: 'm2', text: 'tin tự huỷ', expires: _now + 60000));
    await _openSheet(t, 'tin tự huỷ');
    expect(find.text('Trả lời'), findsOneWidget, reason: 'the sheet is open');
    expect(find.text('Chuyển tiếp'), findsNothing);
    expect(find.text('Sao chép văn bản'), findsNothing);
    expect(find.text('Lưu tin nhắn'), findsNothing);
    await t.tapAt(const Offset(10, 10));
    await _done(t, sv);
  });

  testWidgets('Edit is offered for 48 hours only', (t) async {
    final sv = await makeServices(t);
    await _tile(t, sv, _m(mine: true, author: 'me', text: 'mới gửi'));
    await _openSheet(t, 'mới gửi');
    expect(find.text('Chỉnh sửa'), findsOneWidget);
    await t.tapAt(const Offset(10, 10));
    await settle(t);
    final old = DateTime.now().subtract(const Duration(hours: 49)).millisecondsSinceEpoch;
    await _tile(t, sv, _m(id: 'm2', mine: true, author: 'me', text: 'gửi hôm kia', ts: old));
    await _openSheet(t, 'gửi hôm kia');
    expect(find.text('Trả lời'), findsOneWidget);
    expect(find.text('Chỉnh sửa'), findsNothing);
    await t.tapAt(const Offset(10, 10));
    await _done(t, sv);
  });

  testWidgets('deleted: "recalled" by the author, "removed by an admin" otherwise', (t) async {
    final sv = await makeServices(t);
    await _tile(t, sv, _m(deleted: true, deletedBy: 'peer'));
    expect(find.text('Tin nhắn đã được thu hồi'), findsOneWidget);
    await _tile(t, sv, _m(id: 'g1', conv: 'g:abc', deleted: true, deletedBy: 'admin'), group: true);
    expect(find.text('Tin nhắn đã bị quản trị viên xoá'), findsOneWidget);
    expect(find.text('Tin nhắn đã được thu hồi'), findsNothing);
    sv.settings.locale = 'en';
    await _tile(t, sv, _m(id: 'g2', conv: 'g:abc', deleted: true, deletedBy: 'admin'), group: true);
    expect(find.text('Removed by an admin'), findsOneWidget);
    await _done(t, sv);
  });

  testWidgets('1-1 delete: "for both sides" only on my own messages; "only for me" always', (t) async {
    final sv = await makeServices(t);
    setSize(t, const Size(420, 900));
    late BuildContext ctx;
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }))));
    await settle(t);
    Future<void> check(Message m, {required bool both, bool moderator = false}) async {
      askDeleteMessage(ctx, m.conv, m, moderator: moderator);
      await settle(t);
      expect(find.text('Chỉ mình tôi'), findsOneWidget);
      final label = m.conv.startsWith('g:') ? 'Xoá với mọi người' : 'Xoá cho cả hai bên';
      if (m.conv.startsWith('d:')) expect(find.text(label), both ? findsOneWidget : findsNothing, reason: '${m.conv} mine=${m.mine}');
      await t.tap(find.text('Huỷ'));
      await settle(t);
    }

    await check(_m(), both: false);
    await check(_m(mine: true, author: 'me'), both: true);
    await _done(t, sv);
  });

  testWidgets('forward sheet: "Hide sender name" → the copy says nothing about the author', (t) async {
    final api = MockLumoraApi(timers: false);
    final sv = await makeServices(t, api: api);
    setSize(t, const Size(420, 900));
    // a message from a friend, to forward
    final src = sv.chat.convs.values.firstWhere((c) => c.id.startsWith('d:'));
    final dst = sv.chat.convs.values.firstWhere((c) => c.id.startsWith('d:') && c.id != src.id);
    await t.runAsync(() => sv.chat.thread(src.id).loadInitial());
    await t.runAsync(() => sv.chat.thread(dst.id).loadInitial());
    final m = sv.chat.thread(src.id).messages.lastWhere((m) => m.kind == 'text' && !m.deleted && !m.selfDestructs);

    late BuildContext ctx;
    await t.pumpWidget(LumoraApp(services: sv, overlays: false, home: Scaffold(body: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }))));
    await settle(t);
    ForwardPick? pick;
    pickForwardTarget(ctx, title: 'Chuyển tiếp tới…').then((v) => pick = v);
    await settle(t);
    expect(find.text('Ẩn tên người gửi'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('fwd_hide_sender')));
    await settle(t);
    await t.tap(find.text(dst.title).last);
    await settle(t);
    expect(pick?.conv, dst.id);
    expect(pick?.hideSender, isTrue);

    await t.runAsync(() => sv.chat.forward(m, pick!.conv, hideSender: pick!.hideSender));
    await _flush(t);
    final copy = sv.chat.thread(dst.id).messages.last;
    expect(copy.body, m.body);
    expect(copy.forwardedFrom, isNull);
    // without the option the copy names the author
    await t.runAsync(() => sv.chat.forward(m, dst.id));
    await _flush(t);
    expect(sv.chat.thread(dst.id).messages.last.forwardedFrom, isNotNull);
    await _done(t, sv);
  });
}
