// Headless end-to-end check of lib/core/ffi_api.dart against the real core:
//   dart run tool/ffi_smoke.dart <liblumora_ffi.so> <lumorad> <tmpdir>
// Starts node A through FFI (the app's code path) and node B as a
// `lumorad --stdio` peer, then exercises friends, messages, polls, files,
// calls and remote requests over LAN, printing PASS/FAIL per step.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lumora/core/api.dart';
import 'package:lumora/core/ffi_api.dart';

class Peer {
  Peer(this.p) {
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      try {
        final j = jsonDecode(l) as Map<String, dynamic>;
        if (j.containsKey('event')) {
          events.add(j);
        } else {
          _pending.remove(j['id'])?.complete(j);
        }
      } catch (_) {}
    });
  }
  final Process p;
  final events = <Map<String, dynamic>>[];
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _id = 0;

  Future<Map<String, dynamic>> req(String cmd, [Map<String, dynamic> a = const {}]) {
    final id = ++_id;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    p.stdin.writeln(jsonEncode({'id': id, 'cmd': cmd, ...a}));
    return c.future.timeout(const Duration(seconds: 30));
  }

  Future<Map<String, dynamic>?> waitEvent(String name, {bool Function(Map<String, dynamic>)? where, int secs = 20}) async {
    final end = DateTime.now().add(Duration(seconds: secs));
    while (DateTime.now().isBefore(end)) {
      for (final e in List.of(events)) {
        if (e['event'] == name && (where == null || where(e))) {
          events.remove(e);
          return e;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return null;
  }
}

var failures = 0;
void check(String name, bool ok, [Object? detail]) {
  if (!ok) failures++;
  stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $name${detail == null ? '' : '  → ${detail.toString().substring(0, detail.toString().length.clamp(0, 240))}'}');
}

Future<void> main(List<String> args) async {
  final lib = args[0], lumorad = args[1], tmp = args[2];
  for (final d in ['$tmp/a', '$tmp/b']) {
    final dir = Directory(d);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
  final api = FfiLumoraApi.load(libPath: lib);
  final aEvents = <ApiEvent>[];
  api.events.listen((e) => aEvents.add(ApiEvent.parse(e)));
  Future<ApiEvent?> aWait(String name, {bool Function(ApiEvent)? where, int secs = 20}) async {
    final end = DateTime.now().add(Duration(seconds: secs));
    while (DateTime.now().isBefore(end)) {
      for (final e in List.of(aEvents)) {
        if (e.name == name && (where == null || where(e))) {
          aEvents.remove(e);
          return e;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return null;
  }

  await api.start({
    'data_dir': '$tmp/a',
    'name': 'Lumora UI',
    'enable_nostr': false,
    'enable_dht': false,
    'enable_upnp': false,
    'enable_lan': true,
    'log': 'warn',
  });
  final b = Peer(await Process.start(lumorad, ['--data', '$tmp/b', '--name', 'Bạn test', '--no-nostr', '--no-dht', '--no-upnp', '--stdio']));
  await Future<void>.delayed(const Duration(seconds: 3));

  final me = await api.me();
  check('me', me.peer.length == 52 && me.shortId.isNotEmpty, '${me.name} ${me.shortId}');
  final prof = await api.profile();
  check('profile', prof.name.isNotEmpty, prof.status);
  final net = await api.netStatus();
  check('net_status parses', true, 'nat=${net.nat} lan=${net.lanPeers}');
  final bme = (await b.req('me'))['data'] as Map<String, dynamic>;
  final bPeer = bme['peer'] as String;

  // Friends over LAN by 9-digit short id. LAN announcements carry only a daily hint that
  // strangers can't read (IP privacy), so a 9-digit ID resolves once the two devices are
  // connected — B dials A by its full ID first, as in core/tests/e2e.py.
  final bShort = bme['short_id'].toString();
  final dial = await b.req('connect', {'peer': me.peer, 'timeout': 40});
  check('B connects to A over LAN', dial['ok'] != false && dial['error'] == null, dial);
  await api.addContact(bShort.replaceAll(' ', ''), note: 'Xin chào từ UI'); // 9-digit id over LAN
  final fr = await b.waitEvent('friend_request');
  check('B receives friend_request', fr != null, fr);
  await b.req('accept_contact', {'peer': me.peer});
  final ce = await aWait('contact', where: (e) => Contact.fromJson(e.data).status == ContactStatus.friend);
  check('A contact event → friend', ce != null, ce?.data);
  final contacts = await api.contacts();
  check('contacts parse', contacts.any((c) => c.peer == bPeer && c.status == ContactStatus.friend), contacts.map((c) => '${c.name}:${c.status}').join(','));

  // Messages.
  final conv = 'd:$bPeer';
  final m = await api.sendMessage(conv, 'Xin chào 👋', mentions: [bPeer]);
  check('send_message → plain text body', m.body == 'Xin chào 👋', m.body);
  final bm = await b.waitEvent('message');
  check('B receives message', bm != null);
  await b.req('send_message', {'conv': 'd:${me.peer}', 'text': 'Chào bạn!'});
  final am = await aWait('message', where: (e) => e.data['mine'] != true);
  final incoming = am == null ? null : Message.fromJson(am.data);
  check('A message event → text', incoming?.body == 'Chào bạn!', incoming?.body);
  await api.react(conv, m.id, '❤️', true);
  final ru = await b.waitEvent('message_update', where: (e) => e.containsKey('reactions'));
  check('react reaches B', ru != null, ru);
  await api.editMessage(conv, m.id, 'Đã sửa');
  final eu = await b.waitEvent('message_update', where: (e) => e['edited'] == true);
  check('edit reaches B', eu != null, eu);
  final msgs = await api.messages(conv);
  check('messages parse', msgs.isNotEmpty && msgs.any((x) => x.body == 'Đã sửa'), msgs.map((x) => x.body).join(' | '));

  // Poll.
  final poll = await api.sendPoll(conv, 'Đi đâu?', ['Biển', 'Núi']);
  final pd = PollData.parse(poll);
  check('poll parses', pd?.options.length == 2, poll.body);
  final bp = await b.waitEvent('message', where: (e) => e['kind'] == 'poll');
  if (bp != null) await b.req('vote', {'conv': 'd:${me.peer}', 'msg_id': bp['id'], 'option': 1});
  final vu = await aWait('message_update', where: (e) => e.data['id'] == poll.id && e.data['reactions'] is Map, secs: 10);
  final votes = vu == null ? null : poll.applyUpdate(vu.data).votes;
  check('vote reaches A', votes != null && votes.isNotEmpty, vu?.data);

  // File (photo).
  final photo = '${Directory.current.path}/assets/mock/dalat.jpg';
  final f = await api.sendFile(conv, photo);
  check('send_file', f.name == 'dalat.jpg', f.state);
  final bf = await b.waitEvent('message', where: (e) => e['kind'] == 'file');
  final ref = bf == null ? null : Message.fromJson(bf);
  check('file message has thumb/size', ref != null && ref.body.contains('thumb'), ref?.body.substring(0, 60));
  final fev = await aWait('file', where: (e) => FileItem.fromJson(e.data).state == FileState.done, secs: 30);
  check('A file → done', fev != null, fev?.data['state']);
  final files = await api.files();
  check('files parse', files.isNotEmpty, files.map((x) => '${x.name}:${x.state}').join(','));

  // Location, contact card, saved, stories, spaces.
  final loc = await api.sendLocation(conv, 10.7769, 106.7009, label: 'Nhà thờ Đức Bà', liveMinutes: 15);
  check('location parses', LocationData.parse(loc.body)?.isLive(DateTime.now().millisecondsSinceEpoch) ?? false, loc.body);
  final card = await api.sendContact(conv, bPeer);
  check('contact card parses', ContactCard.parse(card.body)?.peer == bPeer, card.body);
  await api.forwardMessage(m.id, 's:me');
  final convs = await api.conversations();
  check('saved conv', convs.any((c) => c.isSaved), convs.map((c) => '${c.id.length > 6 ? c.id.substring(0, 6) : c.id}:${c.kind.name}').join(','));
  await api.postStory(text: 'Hello stories', bg: 'aurora');
  final st = await api.stories();
  check('stories', st.isNotEmpty, st.length);
  final gconv = await api.createCommunity('Cộng đồng test', [bPeer]);
  final sp = await api.spaces();
  check('create community + spaces', gconv.isNotEmpty && sp.isNotEmpty, sp.map((s) => '${s.name}:${s.channels.length}').join(','));
  final gi = await api.groupInfo(gconv.substring(2));
  check('group_info channels', gi.channels.isNotEmpty && gi.community, gi.channels.map((c) => c.name).join(','));
  final link = await api.createInvite(gi.gid);
  check('invite link', link.startsWith('lumora://join/'), link.substring(0, 30));
  await api.setWallpaper(conv, 'aurora');
  check('wallpaper roundtrip', await api.getWallpaper(conv) == 'aurora');

  // Call: B rings A.
  await b.req('call_start', {'conv': 'd:${me.peer}', 'video': false});
  final ic = await aWait('call', where: (e) => e.data['state'] == 'incoming');
  final call = ic == null ? null : CallState.fromJson(ic.data);
  check('incoming call parses', call != null && call.peer == bPeer && call.phase == CallPhase.incoming, ic?.data);
  if (call != null) {
    await api.callAnswer(call.callId, true);
    final ac = await aWait('call', where: (e) => e.data['state'] == 'active', secs: 15);
    check('call becomes active', ac != null, ac?.data);
    await api.callEnd(call.callId);
    final en = await b.waitEvent('call', where: (e) => e['state'] == 'ended', secs: 15);
    check('B sees call ended', en != null);
  }

  // Caller hangs up while still ringing → callee gets "ended".
  final c2 = (await b.req('call_start', {'conv': 'd:${me.peer}', 'video': false}))['data'];
  final ic2 = await aWait('call', where: (e) => e.data['state'] == 'incoming');
  check('second incoming call', ic2 != null);
  if (ic2 != null) {
    final cid = ic2.data['call_id'];
    await b.req('call_end', {'call_id': (c2 is Map ? c2['call_id'] : null) ?? cid});
    final en2 = await aWait('call', where: (e) => e.data['call_id'] == cid && e.data['state'] == 'ended', secs: 15);
    check('callee sees ended when caller cancels ringing', en2 != null, en2?.data);
  }

  // Remote: B asks to view A (A is host).
  final rs = await api.remoteStatus();
  check('remote_status', rs.password.isNotEmpty || rs.myShortId.isNotEmpty, rs.myShortId);
  await b.req('remote_connect', {'target': me.peer, 'password': rs.password, 'view_only': true});
  final rr = await aWait('remote_request', secs: 15);
  final rreq = rr == null ? null : RemoteRequest.fromJson(rr.data);
  check('A gets remote_request', rreq != null && rreq.peer == bPeer, rr?.data);
  if (rreq != null) {
    await api.remoteRespond(rreq.session, accept: false, control: false);
    final den = await b.waitEvent('remote_state', where: (e) => e['state'] == 'denied' || e['state'] == 'ended', secs: 15);
    check('B sees denied', den != null, den ?? b.events.where((e) => '${e['event']}'.contains('remote') || e['event'] == 'error').toList());
  }

  // Friend asks for control without a password → host is asked (ask:true).
  await b.req('remote_connect', {'target': me.peer, 'password': '', 'view_only': false});
  final ra = await aWait('remote_request', secs: 15);
  check('passwordless friend request → ask', ra != null && RemoteRequest.fromJson(ra.data).ask, ra?.data);
  if (ra != null) {
    await api.remoteRespond(RemoteRequest.fromJson(ra.data).session, accept: false, control: false);
    await b.waitEvent('remote_state', where: (e) => e['state'] == 'denied' || e['state'] == 'ended', secs: 15);
  }

  // Phase 3: usernames, bots, stickers, deletes, mute, group admin.
  final un = await api.setUsername('ui_smoke');
  check('set_username → handle', (un['handle']?.toString() ?? '').startsWith('@ui_smoke'), un);
  final bot = await api.botCreate('Smoke Bot', 'smoke_bot');
  check('bot_create → token', (bot.token ?? '').isNotEmpty && bot.username == 'smoke_bot', bot.handle);
  final bl = await api.botList();
  check('bot_list', bl.any((b) => b.username == 'smoke_bot'), bl.length);
  final rv = await api.botRevoke('smoke_bot');
  check('bot_revoke keeps username', rv.username == 'smoke_bot' && rv.token != bot.token);
  await api.botDelete('smoke_bot');
  check('bot_delete', !(await api.botList()).any((b) => b.username == 'smoke_bot'));
  final pk = await api.stickerPackCreate('Smoke');
  final stk = await api.stickerAdd(pk, photo, emoji: '🏔️');
  final packs = await api.stickerPacks();
  check('sticker pack + add', packs.any((p) => p.id == pk && p.stickers.isNotEmpty), stk['hash']);
  final sm = await api.sendSticker(conv, stk['hash'].toString());
  check('send_sticker', sm.kind == 'sticker', sm.body.substring(0, 40));
  final (mime, data) = await api.stickerGet(stk['hash'].toString());
  check('sticker_get', data.isNotEmpty, mime);
  final del = await api.sendMessage(conv, 'xoá tôi');
  await api.deleteMessageFor(conv, del.id, forEveryone: false);
  check('delete for me', !(await api.messages(conv)).any((x) => x.id == del.id));
  final mu = await api.mute(conv, DateTime.now().millisecondsSinceEpoch + 3600000);
  check('mute 1h', mu['muted'] == true, mu);
  await api.mute(conv, 0);
  final gi2 = await api.groupInfo(gconv.substring(2));
  await api.groupSettings(gi2.gid, slowModeS: 30, adminsOnly: false);
  await api.groupVisibility(gi2.gid, public: true, handle: 'smoke_group');
  final gi3 = await api.groupInfo(gi2.gid);
  check('group visibility public', gi3.isPublic, gi3.handle);
  final rec = await api.remoteRecent();
  check('remote_recent parses', true, rec.length);

  // Frame API (no stream active → null, must not crash).
  final fr0 = await api.frame(1);
  check('frame() safe without stream', fr0 == null || fr0.width > 0);

  final unknownEvents = aEvents.map((e) => e.name).toSet();
  stdout.writeln('A leftover events: $unknownEvents');
  stdout.writeln(failures == 0 ? 'ALL PASS' : '$failures FAILED');
  b.p.kill();
  await api.stop();
  if (Platform.environment.containsKey('LUMORA_REAL_CORE')) {
    if (failures > 0) throw StateError('$failures checks failed');
    return;
  }
  exit(failures == 0 ? 0 : 1);
}
