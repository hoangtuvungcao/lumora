// In-memory mock of the Lumora core used for UI development, demos and
// screenshot tests. Realistic Vietnamese sample data plus simulated
// replies, typing, presence, file progress, calls and remote sessions.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, ZLibEncoder;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart' show rootBundle;
import 'dart:math' as math;
import 'dart:typed_data';

import 'api.dart';
import 'bip39.dart' show phraseSecretKey;
import 'mock_file_previews.dart';
import 'mock_media.dart';


/// The mock account's recovery phrase: secret 0x01…0x20 as 24 BIP39 words
/// (the same golden vector as core/crates/lumora-core/src/identity.rs).
const kMockRecoveryPhrase =
    'absurd avoid scissors anxiety gather lottery category door army half long cage bachelor another expect people blade school educate curtain scrub monitor lady beyond';

class MockLumoraApi extends LumoraApi {
  /// [autoDemo] schedules an incoming call / remote request / friend request
  /// a while after start (for live demos). [now] pins the clock for
  /// deterministic screenshots. [timers] = false disables all periodic
  /// simulation (tests).
  MockLumoraApi({this.autoDemo = false, DateTime? now, this.timers = true})
      : _fixedNow = now {
    _seed();
  }

  final bool autoDemo;
  final bool timers;
  final DateTime? _fixedNow;

  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _rand = math.Random(7);
  final List<Timer> _timers = [];
  bool _started = false;
  int _seq = 0;

  int get _now => (_fixedNow ?? DateTime.now()).millisecondsSinceEpoch;

  @override
  bool get isMock => true;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  // ------------------------------------------------------------------ data
  late Map<String, dynamic> _me;
  String _passphrase = '';
  final Map<String, Map<String, dynamic>> _contacts = {};
  final Map<String, Map<String, dynamic>> _convs = {};
  final Map<String, List<Map<String, dynamic>>> _msgs = {};
  final Map<String, Map<String, dynamic>> _groups = {};
  final List<Map<String, dynamic>> _spaces = [];
  final Map<String, Map<String, dynamic>> _files = {};
  Map<String, dynamic> _remote = {};
  final Map<String, Map<String, dynamic>> _calls = {};
  final Map<String, Map<String, dynamic>> _remoteSessions = {};
  final Map<int, int> _frameTick = {};
  final Map<String, Timer> _typingTimers = {};
  final Map<String, String> _retention = {};

  /// `settings_set` values (core-side preferences), like the real key/value store.
  final Map<String, dynamic> _coreSettings = {
    'read_receipts': true, 'typing': true, 'store_forward': true, 'echo_cancel': true, 'noise_suppression': true, 'lan': true,
    'video_beauty': 0, 'video_lowlight': true, 'video_mirror_send': false,
    'relays': <String>[], 'relay_delay_ms': 3500, 'p2p_only': false, 'downloads_dir': '/home/lan/Downloads/Lumora',
    'discoverable_by_id': true, 'help_friends': true,
  };
  Map<String, int> _policy = {'max_cache': 5 << 30, 'media_days': 0, 'auto_direct': 25 << 20, 'auto_group': 2 << 20, 'community_days': 30};

  /// Downloaded media per conversation (bytes) and reclaimable database space.
  final Map<String, int> _media = {};
  int _dbBytes = 46 << 20;
  int _dbSlack = 9 << 20;
  Map<String, dynamic> _profile = {'name': '', 'bio': '', 'status': 'online', 'avatar': null};
  final Map<String, String> _avatars = {};
  final Map<String, Map<String, dynamic>> _scheduled = {};
  final Set<String> _trusted = {};
  final Map<String, String> _invites = {};
  final Map<String, String?> _wallpapers = {};
  final Map<String, String> _groupAvatars = {};
  final List<Map<String, dynamic>> _stories = [];
  final Map<String, Map<String, dynamic>> _bots = {};
  final List<Map<String, dynamic>> _packs = [];
  final List<Map<String, dynamic>> _recentRemote = [];
  // ignore: unused_field
  String _lang = 'vi';

  static const _alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  String _peerId(String seed) {
    var h = 0x811c9dc5;
    for (final c in seed.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    final r = math.Random(h);
    return List.generate(52, (_) => _alphabet[r.nextInt(32)]).join();
  }

  String _hex(int n) => List.generate(n, (_) => _rand.nextInt(16).toRadixString(16)).join();

  String _shortId(int i) {
    final s = (100000000 + (i * 7919 * 104729) % 900000000).toString();
    return '${s.substring(0, 3)} ${s.substring(3, 6)} ${s.substring(6)}';
  }

  String get myPeer => _me['peer'] as String;

  // ---- multi-device demo state
  bool _isPrimary = true;
  bool _linkPending = false;

  /// Existing device: the open invite and the device asking to join.
  Map<String, dynamic>? _invite;
  Map<String, dynamic>? _pendingLink;

  /// New device: the device it is waiting on.
  Map<String, dynamic>? _linkTarget;
  Map<String, dynamic> _history = {'active': false, 'done': true, 'state_done': true, 'messages': 0, 'since_ms': 0};
  late String _thisDevice = myPeer;
  final List<Map<String, dynamic>> _revokedDevices = [];
  late final List<Map<String, dynamic>> _devices = [
    {'device': myPeer, 'name': 'Điện thoại của Lan', 'kind': 1, 'caps': 5, 'os': 'android', 'added': _now - 400 * 86400000, 'last_seen': _now, 'short_id': '482 913 076'},
    {'device': _peerId('lan-laptop'), 'name': 'Laptop văn phòng', 'kind': 3, 'caps': 6, 'os': 'windows', 'added': _now - 62 * 86400000, 'last_seen': _now - 4 * 60000, 'short_id': '715 204 389', 'online': true},
    {'device': _peerId('lan-ipad'), 'name': 'iPad', 'kind': 2, 'caps': 4, 'os': 'ios', 'added': _now - 20 * 86400000, 'last_seen': _now - 3 * 86400000, 'short_id': '306 558 112'},
  ];

  /// The main device of the account (the first one).
  String get _mainDevice => _devices.first['device'] as String;

  Map<String, dynamic> _devicesJson() => {
        'account': myPeer,
        'device': _thisDevice,
        'primary': _isPrimary,
        'version': _devices.length + _revokedDevices.length,
        'devices': [
          for (final d in _devices)
            {
              ...d,
              'primary': d['device'] == _mainDevice,
              'this': d['device'] == _thisDevice,
              'online': d['device'] == _thisDevice || d['online'] == true,
            },
        ],
        'revoked': [for (final d in _revokedDevices) {...d}],
      };

  void _requirePrimary(String cmd) {
    if (!_isPrimary) throw ApiException('Chỉ thiết bị chính mới làm được việc này.', cmd: cmd, code: 'err.primary_only');
  }

  // ---- multi-device demo hooks (tests, screenshots, the Demo settings)

  /// Existing device with an open invite: a new device asks to join.
  void simulateLinkRequest({String name = 'Laptop ở nhà', int kind = 3, String os = 'windows', String path = 'lan'}) {
    final req = {'device': _peerId('new-device-${_devices.length}'), 'name': name, 'kind': kind, 'os': os, 'path': path};
    _pendingLink = req;
    _emit('link_request', req);
  }

  /// Existing device: 3 wrong attempts → a fresh code.
  void simulateLinkCodeRotated() {
    final code = '7305-1926-4480';
    if (_invite != null) _invite!['code'] = code;
    _emit('link_state', {'state': 'code_rotated', 'code': code});
  }

  /// Either side: the link failed (`declined`, `cancelled`, `expired`, …).
  void simulateLinkFailed(String reason) {
    _linkTarget = null;
    _emit('link_state', {'state': 'failed', 'reason': reason});
  }

  /// New device: the main device approved → restart → history copy starts.
  void simulateLinkApproved() {
    final target = _linkTarget;
    _emit('link_state', {'state': 'approved', 'device': _thisDevice});
    _linkTarget = null;
    _linkPending = false;
    _isPrimary = false;
    final me = {
      'device': _thisDevice,
      'name': 'Máy tính này',
      'kind': 3,
      'caps': 6,
      'os': 'linux',
      'added': _now,
      'last_seen': _now,
      'short_id': '590 127 643',
    };
    // the account's other devices (the main one first)
    _devices
      ..removeWhere((d) => d['device'] == _thisDevice)
      ..add(me);
    if (target != null) _devices.first['name'] = target['name'];
    _history = {'active': true, 'done': false, 'state_done': true, 'messages': 0, 'since_ms': _now - 180 * 86400000, 'convs_done': 0, 'convs_total': 12};
    _emit('link_state', {'state': 'restart', 'reason': 'linked'});
    restart(overrides: const {'link_pending': false}, reason: 'linked');
  }

  /// New device: copied history (`history_sync`).
  void simulateHistorySync(int messages, {int convsDone = 0, int convsTotal = 12, bool done = false}) {
    _history = {..._history, 'active': !done, 'done': done, 'messages': messages, 'convs_done': convsDone, 'convs_total': convsTotal};
    _emit('history_sync', {'messages': messages, 'convs_done': convsDone, 'convs_total': convsTotal, 'done': done});
  }

  /// A member of group [conv] sent too much (`group_flood`); [admin] = this
  /// account manages the group (gets a slow-mode suggestion for `rate`).
  void simulateGroupFlood(String conv, {String reason = 'rate', bool admin = true, int? suggest}) {
    final gid = conv.substring(2).split('#').first;
    final g = _groups[gid];
    final author = ((g?['members'] as List?) ?? const []).map((m) => (m as Map)['peer']).firstWhere((p) => p != _me['peer'], orElse: () => _friend(1)) as String;
    final name = _contacts[author]?['name'] as String? ?? 'Ai đó';
    final s = suggest ?? (admin && reason == 'rate' ? 10 : 0);
    final text = reason == 'group_quota'
        ? 'Hôm nay nhóm đã nhận quá nhiều tin. Hãy thử lại vào ngày mai.'
        : (s > 0 ? '$name đang gửi quá nhiều tin nên một số tin đã bị ẩn. Bật chế độ chậm ($s giây giữa hai tin)?' : '$name đang gửi quá nhiều tin nên một số tin đã bị ẩn.');
    _emit('group_flood', {'gid': gid, 'conv': 'g:$gid', 'author': author, 'name': name, 'reason': reason, 'admin': admin, 'suggest_slow_mode_s': s, 'text': text});
  }

  // ------------------------------------------------------------ reports

  /// Reports waiting on this (admin) device (`group_reports`).
  final List<Map<String, dynamic>> _reports = [];
  final Set<String> _reportsDone = {};

  /// `privacy.blocked_groups` / `privacy.hidden_members` (synced settings).
  final List<Map<String, dynamic>> _blockedGroups = [];
  final List<String> _hiddenMembers = [];

  /// Reports this account sent (tests).
  final List<Map<String, dynamic>> sentReports = [];

  /// Public groups the directory knows (stable ids, so they can be blocked).
  late final List<Map<String, dynamic>> _directoryGroups = [
    {'gid': _hex(32), 'title': 'Flutter Việt Nam', 'about': 'Cộng đồng lập trình Flutter lớn nhất VN', 'members': 4120, 'handle': '@flutter_vn·a8d2k1', 'admin': _friend(1), 'verified': true},
    {'gid': _hex(32), 'title': 'Rust Việt Nam', 'about': 'Hỏi đáp Rust, async, tokio', 'members': 980, 'handle': '@rust_vn·m2k9q1', 'admin': _friend(2), 'verified': false},
  ];

  /// The group a (demo) invite link leads to: one stable id per link.
  final Map<String, String> _linkGids = {};
  String _inviteGid(String link) => _linkGids.putIfAbsent(link, () => _hex(32));

  static String _clip(String t, int n) => t.runes.length <= n ? t : String.fromCharCodes(t.runes.take(n));

  bool _groupBlocked(String gid) => _blockedGroups.any((b) => b['gid'] == gid);

  /// Tests / demo: a member reported a message (or a member) of group [gid]
  /// to this admin device (`group_report`). Returns the report id.
  String simulateGroupReport(String gid, {String? msgId, String? member, String reason = 'spam', String note = ''}) {
    final g = _groups[gid];
    final members = ((g?['members'] as List?) ?? const []).cast<Map>();
    final others = members.map((m) => m['peer'] as String).where((p) => p != myPeer).toList();
    final m = msgId == null ? null : _find('g:$gid', msgId);
    final target = member ?? (m?['author'] as String?) ?? (others.isNotEmpty ? others.first : _friend(1));
    final reporter = others.firstWhere((p) => p != target, orElse: () => _friend(2));
    String nameOf(String p) => (_contacts[p]?['name'] as String?) ?? (members.firstWhere((x) => x['peer'] == p, orElse: () => const {})['name'] as String?) ?? 'Ai đó';
    final r = <String, dynamic>{
      'id': _hex(32), 'gid': gid, 'conv': 'g:$gid', 'group_name': g?['name'] ?? '',
      'msg_id': msgId, 'excerpt': _clip(m == null || m['body'] is! String ? '' : m['body'] as String, 200), 'msg_exists': m != null && m['deleted'] != true,
      'member': target, 'member_name': nameOf(target), 'member_in_group': members.any((x) => x['peer'] == target),
      'reporter': reporter, 'reporter_name': nameOf(reporter), 'reason': reason, 'note': note, 'ts': _now,
    };
    _reports.insert(0, r);
    _emit('group_report', Map.of(r));
    return r['id'] as String;
  }

  /// Tests: the id of the seeded group whose name starts with [prefix].
  String debugGroupIdNamed(String prefix) => _groups.values.firstWhere((g) => '${g['name']}'.startsWith(prefix))['gid'] as String;

  /// Tests: another of my devices handled these reports (`Ext GROUP_REPORT_DONE`).
  void reportsHandledElsewhere(List<String> ids) {
    _reportsDone.addAll(ids);
    _reports.removeWhere((r) => ids.contains(r['id']));
    _emit('group_report_handled', {'ids': ids});
  }

  /// Tests: another of my devices blocked a group (synced setting + its Leave).
  void groupBlockedElsewhere(String gid, {String name = ''}) {
    if (!_groupBlocked(gid)) _blockedGroups.add({'gid': gid, 'name': name.isNotEmpty ? name : (_groups[gid]?['name'] ?? ''), 'at': _now});
    _forgetGroup(gid);
    _emit('settings', {'key': 'privacy.blocked_groups'});
  }

  /// Tests: "hide this member's messages" chosen on another of my devices.
  void memberHiddenElsewhere(String peer, {bool hidden = true}) {
    _hiddenMembers.remove(peer);
    if (hidden) _hiddenMembers.add(peer);
    _emit('settings', {'key': 'privacy.hidden_members'});
  }

  void _forgetGroup(String gid) {
    if (_groups.remove(gid) == null && !_convs.containsKey('g:$gid')) return;
    _convs.remove('g:$gid');
    _emit('conversation_removed', {'conv': 'g:$gid'});
    _emit('group_removed', {'gid': gid, 'conv': 'g:$gid', 'left': true});
  }

  /// Turns this demo account's device into a linked (not main) device.
  void debugMakeLinkedDevice() {
    _isPrimary = false;
    _thisDevice = _devices[1]['device'] as String;
  }

  /// Linked device: [peer]'s app is too old for several devices, so messages to them go
  /// through the main device (`contacts` / `contact` field `bridged`).
  void simulateBridgedFriend(String peer, {bool bridged = true}) {
    final c = _contacts[peer];
    if (c == null) return;
    c['bridged'] = bridged;
    _emit('contact', Map.of(c));
  }

  /// A friend's device list gained a device: the core's local system line
  /// (`sys.contact_device_added`) in the direct chat.
  void simulateContactDeviceAdded(String peer) {
    final conv = 'd:$peer';
    final name = '${_contacts[peer]?['name'] ?? ''}';
    final m = _mkMsg(conv, myPeer, '', _now, kind: 'system')
      ..['body'] = {'code': 'sys.contact_device_added', 'args': {'name': name, 'peer': peer}, 'text': '$name added a new device. Their security code changed.'};
    _msgs.putIfAbsent(conv, () => []).add(m);
    _emit('message', Map.of(m));
  }

  /// This device was signed out (from the main device, or by itself).
  void simulateDeviceRevoked({bool bySelf = false, bool wipe = false}) =>
      _emit('device_revoked', {'device': _thisDevice, 'wipe': wipe, if (bySelf) 'by_self': true});

  /// The `passphrase` of the last accepted `device_promote` (tests).
  String? lastPromotePassphrase;

  /// The `history` of the last `link_approve` (tests).
  String? lastApprovedHistory;

  /// The ringing call was picked up on another of my devices.
  void simulateCallAnsweredElsewhere({String device = 'Laptop văn phòng'}) {
    final c = _calls.values.where((c) => c['state'] == 'incoming').lastOrNull;
    if (c == null) return;
    c['state'] = 'ended';
    _emit('call', {...c, 'reason': 'answered_elsewhere', 'device_name': device});
  }

  /// Runs [f] a moment later (right away, in a microtask, without timers).
  void _soon(Duration d, void Function() f) => timers ? _later(d, f) : scheduleMicrotask(f);

  int _restarts = 0;

  /// How many times the demo core was "restarted" (tests).
  int get restarts => _restarts;

  @override
  Future<void> restart({Map<String, dynamic> overrides = const {}, String reason = ''}) async {
    _restarts++;
    if (overrides['link_pending'] == false) _linkPending = false;
    _emit('core_restarted', {'reason': reason});
  }

  @override
  Future<void> halt() async {}

  void _seed() {
    final now = _now;
    _me = {
      'peer': _peerId('me'),
      'short_id': '482 913 076',
      'name': 'Lan Phương',
      'recovery_phrase_available': true,
      'safety': '',
    };
    const people = [
      ['Nguyễn Minh Anh', true, 'direct'],
      ['Trần Bảo Ngọc', true, 'lan'],
      ['Lê Hoàng Nam', false, null],
      ['Phạm Thu Hà', true, 'relay'],
      ['Võ Quốc Huy', false, null],
      ['Đặng Mai Linh', true, 'direct'],
      ['Bùi Tuấn Kiệt', false, null],
      ['Hồ Gia Bảo', true, 'direct'],
    ];
    for (var i = 0; i < people.length; i++) {
      final p = people[i];
      final peer = _peerId(p[0] as String);
      _contacts[peer] = {
        'peer': peer,
        'short_id': _shortId(i + 3),
        'name': p[0],
        'alias': null,
        'status': 3,
        'added': now - (40 - i) * 86400000,
        'last_seen': now - (i + 1) * 37 * 60000,
        'verified': i == 0 || i == 1,
        'relays': ['wss://relay.lumora.vn/ws'],
        'online': p[1],
        'path': p[2],
        'presence': const ['online', 'away', null, 'dnd', null, 'online', null, 'online'][i],
        'bio': const ['Dev Flutter · thích cà phê ☕', 'Product designer 🎨', 'Backend Rust 🦀', 'Đi đâu cũng mang máy ảnh 📷', 'Fan bóng đá ⚽', 'QA lead', 'Gamer 🎮', 'Sinh viên CNTT'][i],
        'has_avatar': i == 1 || i == 3 || i == 5,
      };
    }
    // Pending requests + blocked.
    final tam = _peerId('Ngô Thanh Tâm');
    _contacts[tam] = {
      'peer': tam, 'short_id': _shortId(21), 'name': 'Ngô Thanh Tâm', 'status': 2,
      'added': now - 3600000, 'last_seen': 0, 'verified': false, 'relays': [], 'online': true,
      'note': 'Chào bạn, mình gặp nhau ở Vietnam Web Summit nè!',
    };
    final vy = _peerId('Đỗ Khánh Vy');
    _contacts[vy] = {
      'peer': vy, 'short_id': _shortId(22), 'name': 'Đỗ Khánh Vy', 'status': 1,
      'added': now - 7200000, 'last_seen': 0, 'verified': false, 'relays': [], 'online': false,
    };
    final spam = _peerId('Spam Bot');
    _contacts[spam] = {
      'peer': spam, 'short_id': _shortId(23), 'name': 'Quảng cáo 24h', 'status': 4,
      'added': now - 9 * 86400000, 'last_seen': 0, 'verified': false, 'relays': [], 'online': false,
    };

    final peers = _contacts.values.where((c) => c['status'] == 3).map((c) => c['peer'] as String).toList();
    String p(int i) => peers[i];

    // ------------------------------------------------------------ DMs
    final scripts = <int, List<List<dynamic>>>{
      0: [
        // [mine?, text, minutesAgo]
        [false, 'Ê Lan ơi, tối nay đi cà phê không? ☕', 60 * 26],
        [true, 'Ok luôn, mấy giờ?', 60 * 26 - 2],
        [false, '7h ở quán cũ nha', 60 * 26 - 3],
        [true, 'Chốt 👍', 60 * 26 - 3],
        [false, 'Hôm qua vui ghê, lần sau rủ thêm Bảo nữa', 60 * 5],
        [true, 'Ừ, để mình tạo group luôn', 60 * 5 - 1],
        [false, 'Mà dùng Lumora thấy sao rồi?', 30],
        [true, 'Gọi video nét lắm, còn nhờ được người khác điều khiển máy giúp nữa 😎', 28],
        [false, 'Đỉnh vậy! Có ai đọc trộm tin nhắn được không?', 27],
        [true, 'Không đâu, chỉ hai đứa mình đọc được thôi, kể cả Lumora cũng không.', 26],
        [false, 'Gửi link tải cho tao với nha 🙏', 4],
      ],
      1: [
        [false, 'Chị gửi em file thiết kế mới nhé', 60 * 3],
        [false, '{"file_id":"f_design","name":"Lumora_UI_v3.fig","size":48230400}', 60 * 3 - 1, 'file'],
        [true, 'Dạ em nhận rồi, đẹp quá chị ơi 😍', 60 * 2],
        [false, 'Màu tím với xanh cyan hợp nhau ghê', 60 * 2 - 1],
        [true, 'Gradient 135 độ đúng chuẩn brand luôn', 50],
      ],
      2: [
        [true, 'Nam ơi mai họp lúc mấy giờ?', 60 * 30],
        [false, '9h sáng nhé, phòng họp tầng 3', 60 * 29],
        [true, 'Ok cảm ơn anh', 60 * 29],
      ],
      3: [
        [false, 'Hà gửi ảnh chuyến đi Đà Lạt nè', 60 * 50],
        [false, '{"file_id":"f_dalat","name":"da_lat_2026.jpg","size":3480000}', 60 * 50, 'file'],
        [true, 'Đẹp quá trời 😍 lần sau rủ mình với', 60 * 49],
        [false, 'Ok lần sau đi chung nha!', 60 * 48],
      ],
      4: [
        [false, 'Bro, cuối tuần đá banh không?', 60 * 70],
        [true, 'Có chứ, sân cũ hả?', 60 * 69],
      ],
      5: [
        [false, 'Đã gọi thoại · 12 phút', 60 * 8, 'call'],
        [false, 'Cảm ơn Lan đã giúp mình cài máy nha 🙏', 60 * 7],
        [true, 'Không có gì đâu Linh 😄', 60 * 7],
      ],
      7: [
        [false, 'Anh ơi remote vào máy em xem lỗi giúp được không ạ?', 15],
        [true, 'Được, gửi anh ID với mật khẩu nhé', 14],
        [false, 'ID: 731 520 448 · mật khẩu: k7m2qp', 13],
      ],
    };

    scripts.forEach((idx, lines) {
      final conv = 'd:${p(idx)}';
      final list = <Map<String, dynamic>>[];
      // Long history for the first chat to exercise pagination.
      if (idx == 0) {
        const filler = [
          'Haha đúng rồi', 'Mai rảnh không?', 'Để tao xem lịch đã', 'Ok nha',
          'Gửi tao link với', 'Xem phim gì giờ?', 'Nghe bài này chưa 🎧', 'Nghe rồi, hay phết',
          'Kẹt xe quá 😩', 'Về tới nhà chưa?', 'Rồi nè', 'Ngủ ngon nha 🌙',
        ];
        for (var k = 0; k < 90; k++) {
          final ago = 60 * 24 * 9 - k * 120;
          list.add(_mkMsg(conv, k.isEven ? p(idx) : myPeer, filler[k % filler.length],
              now - ago * 60000, mine: k.isOdd, status: 3));
        }
      }
      for (final l in lines) {
        final mine = l[0] as bool;
        final m = _mkMsg(conv, mine ? myPeer : p(idx), l[1] as String,
            now - (l[2] as int) * 60000,
            mine: mine, status: 3, kind: l.length > 3 ? l[3] as String : 'text');
        list.add(m);
      }
      if (idx == 0) {
        // A reply + reactions + an edited message for visual variety.
        final target = list[list.length - 3];
        list[list.length - 2]['reply_to'] = target['id'];
        list[list.length - 3]['reactions'] = {'🔥': [p(idx)], '👍': [p(idx), myPeer]};
        list[list.length - 4]['edited'] = true;
        list.last['status'] = 2;
        list[list.length - 2]['status'] = 3;
      }
      _msgs[conv] = list;
      final last = list.last;
      _convs[conv] = {
        'id': conv,
        'kind': 0,
        'title': _contacts[p(idx)]!['name'],
        'last_ts': last['ts'],
        'unread': {0: 1, 1: 0, 3: 0, 7: 2}[idx] ?? 0,
        'muted': idx == 4,
        'pinned': idx == 0 || idx == 1,
        'last_text': _preview(last),
        'last_mine': last['mine'] == true,
      };
    });

    // ----------------------------------------------------------- groups
    void group(String name, List<int> members, List<List<dynamic>> lines, {int unread = 0, bool pinned = false, String myRole = 'owner'}) {
      final gid = _hex(32);
      final conv = 'g:$gid';
      _groups[gid] = {
        'gid': gid,
        'name': name,
        'owner': myRole == 'owner' ? myPeer : p(members.first),
        'epoch': 3,
        'my_role': myRole,
        'members': [
          {'peer': myPeer, 'name': _me['name'], 'role': myRole},
          for (final i in members)
            {'peer': p(i), 'name': _contacts[p(i)]!['name'], 'role': (myRole != 'owner' && i == members.first) ? 'owner' : (i == members.last ? 'admin' : 'member')},
        ],
      };
      final list = <Map<String, dynamic>>[];
      final creator = myRole == 'owner' ? myPeer : p(members.first);
      list.add(_mkMsg(conv, creator, '', now - 60 * 24 * 3 * 60000, kind: 'system', mine: false)
        ..['body'] = {'code': 'sys.group_created', 'args': {'actor': creator, 'name': name}, 'text': 'Group "$name" created'});
      list.add(_mkMsg(conv, creator, '', now - 60 * 24 * 3 * 60000 + 1000, kind: 'system', mine: false)
        ..['body'] = {'code': 'sys.member_added', 'args': {'actor': creator, 'peer': p(members.last)}, 'text': 'Member added'});
      for (final l in lines) {
        final who = l[0] as int;
        list.add(_mkMsg(conv, who < 0 ? myPeer : p(who), l[1] as String, now - (l[2] as int) * 60000, mine: who < 0, status: 3));
      }
      _msgs[conv] = list;
      _convs[conv] = {
        'id': conv, 'kind': 1, 'title': name, 'last_ts': list.last['ts'], 'unread': unread,
        'muted': false, 'pinned': pinned, 'last_text': _preview(list.last, group: true), 'last_mine': list.last['mine'] == true,
      };
    }

    group('Gia đình 🏡', [2, 3, 6], [
      [3, 'Cuối tuần cả nhà về quê ăn giỗ nhé', 60 * 6],
      [2, 'Dạ con nhớ rồi ạ', 60 * 5],
      [-1, 'Con đặt vé xe rồi nha mẹ', 60 * 5 - 3],
      [6, 'Nhớ mua bánh pía cho bà 😄', 45],
      [3, 'Ừ, mua 2 hộp nhé', 12],
    ], unread: 3, myRole: 'member');
    group('Dự án Lumora 🚀', [0, 1, 5, 7], [
      [0, 'Bản mới đã có, mọi người dùng thử giúp nhé', 60 * 4],
      [1, 'Gọi video ở nhà nét lắm luôn 🎉', 60 * 3],
      [5, 'Ra quán cà phê Wi-Fi yếu vẫn gọi được, chỉ hơi trễ chút', 60 * 2],
      [-1, 'Tuyệt, tuần sau mình thử chia sẻ màn hình cho cả nhóm', 90],
      [7, 'Để mình thử thêm trên điện thoại nữa', 20],
    ], unread: 5, pinned: false);

    // ----------------------------------------------------------- server
    final sid = _hex(16);
    final chans = <Map<String, dynamic>>[];
    void chan(String name, String kind, String cat, {int unread = 0, List<String> parts = const [], List<List<dynamic>> lines = const []}) {
      final gid = _hex(32);
      final conv = 'g:$gid';
      chans.add({'id': gid, 'name': name, 'kind': kind, 'conv': conv, 'participants': parts, 'unread': unread, 'category': cat});
      if (kind == 'text') {
        _msgs[conv] = [
          for (final l in lines)
            _mkMsg(conv, (l[0] as int) < 0 ? myPeer : p(l[0] as int), l[1] as String, now - (l[2] as int) * 60000, mine: (l[0] as int) < 0, status: 3),
        ];
        _groups[gid] = {
          'gid': gid, 'name': name, 'owner': p(1), 'epoch': 1, 'my_role': 'member',
          'members': [
            {'peer': p(1), 'name': _contacts[p(1)]!['name'], 'role': 'owner'},
            {'peer': myPeer, 'name': _me['name'], 'role': 'member'},
            for (final i in [0, 2, 3, 5, 7]) {'peer': p(i), 'name': _contacts[p(i)]!['name'], 'role': i == 0 ? 'admin' : 'member'},
          ],
        };
      }
    }

    chan('chào-mừng', 'text', 'THÔNG TIN', lines: [
      [1, 'Chào mừng mọi người đến với Hội Lập Trình Việt 👋 Đọc nội quy trước khi chat nhé!', 60 * 24 * 5],
    ]);
    chan('thông-báo', 'text', 'THÔNG TIN', unread: 1, lines: [
      [1, '📢 Meetup tháng 11 tổ chức tại TP.HCM, đăng ký trong kênh #sự-kiện', 60 * 20],
    ]);
    chan('chung', 'text', 'THẢO LUẬN', unread: 12, lines: [
      [0, 'Có ai dùng Rust cho backend production chưa?', 60 * 3],
      [5, 'Team mình dùng tokio + axum 2 năm rồi, ổn định lắm', 60 * 3 - 4],
      [2, 'Compile hơi lâu thôi 😅', 60 * 3 - 6],
      [-1, 'Dùng sccache với mold linker là đỡ nhiều', 60 * 2],
      [7, 'Mold xịn thật, link nhanh gấp 5 lần', 100],
      [0, 'Để tối thử', 40],
    ]);
    chan('flutter', 'text', 'THẢO LUẬN', lines: [
      [3, 'Impeller trên Android giờ mượt hẳn', 60 * 10],
      [-1, 'Desktop Linux cũng ổn rồi', 60 * 9],
    ]);
    chan('rust', 'text', 'THẢO LUẬN', lines: [
      [2, 'quinn hay webrtc-rs cho P2P?', 60 * 15],
    ]);
    chan('Phòng họp', 'voice', 'KÊNH THOẠI', parts: [p(0), p(5), p(7)]);
    chan('Chill & Code 🎧', 'voice', 'KÊNH THOẠI', parts: [p(1)]);
    chan('AFK', 'voice', 'KÊNH THOẠI');
    _spaces.add({'id': sid, 'name': 'Hội Lập Trình Việt', 'members': 1284, 'channels': chans});
    final sid2 = _hex(16);
    final chans2Start = chans.length;
    chan('chung', 'text', 'CHUNG', lines: [
      [6, 'Tối nay leo rank không ae?', 30],
    ]);
    chan('Leo rank', 'voice', 'CHUNG', parts: [p(6), p(4)]);
    _spaces.add({'id': sid2, 'name': 'Game Thủ Sài Gòn', 'members': 342, 'channels': chans.sublist(chans2Start)});
    chans.removeRange(chans2Start, chans.length);

    // ------------------------------------------------------------ files
    void file(String id, String conv, String peer, String name, int size, int dir, int state, double frac, {int? speed, int agoMin = 5}) {
      _files[id] = {
        'id': id, 'conv': conv, 'peer': peer, 'name': name, 'size': size, 'hash': _hex(64),
        'path': dir == 1 ? '~/Tải xuống/Lumora/$name' : '~/Tài liệu/$name',
        'direction': dir, 'state': state, 'progress': (size * frac).round(),
        'created': now - agoMin * 60000, 'speed_bps': speed,
      };
    }

    file('f_design', 'd:${p(1)}', p(1), 'Lumora_UI_v3.fig', 48230400, 1, 1, 0.62, speed: 5400000, agoMin: 180);
    file('f_dalat', 'd:${p(3)}', p(3), 'da_lat_2026.jpg', 3480000, 1, 2, 1, agoMin: 3000);
    file('f_video', 'd:${p(0)}', p(0), 'demo_remote_desktop.mp4', 734003200, 0, 1, 0.27, speed: 12800000, agoMin: 2);
    file('f_iso', 'd:${p(7)}', p(7), 'ubuntu-26.04-desktop-amd64.iso', 6234567890, 1, 5, 0.41, agoMin: 30);
    file('f_pdf', 'd:${p(2)}', p(2), 'Hop_dong_thue_nha.pdf', 1250000, 0, 2, 1, agoMin: 60 * 26);
    file('f_zip', 'd:${p(5)}', p(5), 'source_backup.zip', 98000000, 1, 3, 0.12, agoMin: 60 * 40);
    file('f_offer', 'd:${p(0)}', p(0), 'bao_cao_Q3.xlsx', 820000, 1, 0, 0, agoMin: 1);
    _msgs['d:${p(0)}']!.add(_mkMsg('d:${p(0)}', myPeer, '{"file_id":"f_video","name":"demo_remote_desktop.mp4","size":734003200}', now - 2 * 60000, mine: true, kind: 'file', status: 1));
    _msgs['d:${p(0)}']!.add(_mkMsg('d:${p(0)}', p(0), '{"file_id":"f_offer","name":"bao_cao_Q3.xlsx","size":820000}', now - 60000, kind: 'file'));
    _convs['d:${p(0)}']!['last_ts'] = now - 60000;
    _convs['d:${p(0)}']!['last_text'] = '📎 bao_cao_Q3.xlsx';
    _convs['d:${p(0)}']!['last_mine'] = false;
    _msgs['d:${p(0)}']!.sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));

    _retention['d:${p(7)}'] = 'session';
    _seedExtras(now, peers);
    _remote = {
      'my_short_id': _me['short_id'],
      'password': 'x7k2pq',
      'unattended': false,
      'allow_control': true,
      'macs': ['a4:bb:6d:10:4e:21'],
      'wayland': {'portal': true, 'pipewire': true},
    };
  }


  // ------------------------------------------------------------ v1.1 seed
  void _seedExtras(int now, List<String> peers) {
    _profile = {'name': _me['name'], 'bio': 'Xây dựng Lumora 🚀', 'status': 'online', 'avatar': null};
    for (final i in [1, 3, 5]) {
      _avatars[peers[i]] = base64Encode(_avatarPng(i));
    }
    // Saved messages.
    final saved = <Map<String, dynamic>>[
      _mkMsg('s:me', myPeer, 'Mật khẩu wifi nhà bà: luatrongnha2026', now - 3 * 86400000, mine: true),
      _mkMsg('s:me', myPeer, 'https://flutter.dev/docs — đọc lại phần Impeller', now - 2 * 86400000, mine: true),
    ];
    final fwd = _mkMsg('s:me', myPeer, 'Meetup tháng 11 tổ chức tại TP.HCM, đăng ký trong kênh #sự-kiện', now - 86400000, mine: true);
    fwd['meta'] = {'forwarded_from': peers[1]};
    saved.add(fwd);
    _msgs['s:me'] = saved;
    _convs['s:me'] = {
      'id': 's:me', 'kind': 0, 'title': 'Tin nhắn đã lưu', 'last_ts': fwd['ts'], 'unread': 0,
      'muted': false, 'pinned': true, 'last_text': fwd['body'],
    };
    // Archived chat.
    _convs['d:${peers[4]}']?['archived'] = true;
    // Poll + pinned + mention in "Dự án Lumora".
    final proj = _convs.values.firstWhere((c) => (c['title'] as String).startsWith('Dự án')); 
    final conv = proj['id'] as String;
    final poll = _mkMsg(conv, peers[1], jsonEncode({'question': 'Họp sprint review lúc nào?', 'options': ['Thứ 6, 14:00', 'Thứ 6, 16:00', 'Thứ 2 tuần sau']}),
        now - 50 * 60000, kind: 'poll');
    poll['reactions'] = {'__votes': {peers[0]: 0, peers[5]: 1, peers[7]: 0}};
    poll['meta'] = {'poll': jsonDecode(poll['body'] as String)};
    final list = _msgs[conv]!;
    list.insert(list.length - 2, poll);
    list[3]['pinned'] = true;
    final mention = _mkMsg(conv, peers[0], '@${_me['name']} xem giúp bản thiết kế mới nhé 🙏', now - 8 * 60000);
    mention['meta'] = {'mentions': [myPeer]};
    // A to-do list (2/5 done) and an upcoming reminder.
    final todo = _mkMsg(conv, peers[1], '', now - 40 * 60000, kind: 'checklist');
    todo['body'] = {
      'title': 'Chuẩn bị bản phát hành 1.2',
      'items': [
        {'id': 0, 'text': 'Chốt danh sách tính năng'},
        {'id': 1, 'text': 'Kiểm thử trên Android'},
        {'id': 2, 'text': 'Viết ghi chú phát hành'},
        {'id': 3, 'text': 'Chụp ảnh màn hình mới'},
        {'id': 4, 'text': 'Gửi bản thử cho nhóm'},
      ],
    };
    todo['reactions'] = <String, dynamic>{
      '__checks': {
        '0': {'done': true, 'by': peers[1], 'at': now - 35 * 60000},
        '1': {'done': true, 'by': myPeer, 'at': now - 20 * 60000},
      },
    };
    list.add(todo);
    final rem = _mkMsg(conv, peers[0], '', now - 15 * 60000, kind: 'reminder');
    rem['body'] = {'title': 'Họp sprint review', 'at_ms': now + 2 * 3600000 + 15 * 60000, 'note': 'Phòng họp online, nhớ mang bản demo'};
    rem['reactions'] = <String, dynamic>{'__seen': {peers[1]: now - 10 * 60000}};
    list.add(rem);
    list.add(mention);
    proj['last_ts'] = mention['ts'];
    proj['last_text'] = 'Anh: ${mention['body']}';
    proj['mentions'] = 1;
    proj['unread'] = (proj['unread'] as int) + 1;
    // Location (live), voice, contact card.
    final ma2 = 'd:${peers[0]}';
    final loc = _mkMsg(ma2, peers[0], '', now - 3 * 60000, kind: 'location');
    loc['body'] = {'lat': 10.7769, 'lon': 106.7009, 'accuracy_m': 12, 'label': 'Nhà thờ Đức Bà, Q.1, TP.HCM', 'live_until': now + 12 * 60000, 'updated': now - 20000};
    _msgs[ma2]!.add(loc);
    final ngoc = 'd:${peers[1]}';
    final vid = 'voice_${_hex(6)}';
    _files[vid] = {'id': vid, 'conv': ngoc, 'peer': peers[1], 'name': 'voice.m4a', 'size': 48200, 'hash': _hex(64), 'path': '', 'direction': 1, 'state': 2, 'progress': 48200, 'created': now - 40 * 60000};
    final voice = _mkMsg(ngoc, peers[1], '', now - 40 * 60000, kind: 'voice');
    voice['body'] = {'file_id': vid, 'name': 'voice.m4a', 'size': 48200, 'mime': 'audio/mp4', 'duration_ms': 14000,
      'wave': [12, 30, 55, 80, 120, 90, 60, 140, 180, 200, 160, 110, 70, 90, 130, 170, 210, 190, 150, 100, 60, 80, 120, 160, 140, 100, 70, 50, 40, 30, 20, 12]};
    voice['file'] = {'state': 2, 'progress': 48200, 'size': 48200, 'path': null, 'direction': 1};
    _msgs[ngoc]!.add(voice);
    final nam = 'd:${peers[2]}';
    final card = _mkMsg(nam, peers[2], '', now - 60 * 28 * 60000 + 5000, kind: 'contact');
    card['body'] = {'peer': peers[6], 'short_id': _contacts[peers[6]]!['short_id'], 'name': _contacts[peers[6]]!['name']};
    _msgs[nam]!.add(card);
    // Stories.
    const bgs = ['aurora', 'sunset', 'ocean', 'mint', 'sakura'];
    const texts = ['Chúc mọi người cuối tuần vui vẻ! 🌿', 'Hoàng hôn Đà Lạt 🌅', '', 'Code xong release 1.0 rồi 🚀', 'Cà phê sáng ☕'];
    for (var i = 0; i < 5; i++) {
      _stories.add({
        'id': 'st_$i', 'author': peers[[0, 3, 1, 5, 7][i]], 'created': now - (i + 1) * 47 * 60000, 'text': texts[i],
        'has_image': i == 1 || i == 2, 'bg': bgs[i], 'seen': i >= 3, 'views': 3 + i * 4,
      });
    }
    // Phase 3: username, a bot contact with commands & inline buttons,
    // sticker packs, recent remote devices.
    _me['username'] = 'lanphuong';
    _me['handle'] = '@lanphuong·m4x7qa';
    final botPeer = _peerId('weather_bot');
    _contacts[botPeer] = {
      'peer': botPeer, 'short_id': _shortId(41), 'name': 'Thời tiết Bot', 'status': 3, 'added': now - 86400000,
      'last_seen': now, 'verified': false, 'relays': [], 'online': true, 'username': 'weather_bot', 'handle': '@weather_bot·z5n7jy',
      'bio': 'Dự báo thời tiết cho 63 tỉnh thành 🌤️',
      'bot': {
        'owner': peers[0], 'about': 'Gõ /dubao để xem thời tiết hôm nay',
        'commands': [
          {'command': 'start', 'description': 'Bắt đầu'},
          {'command': 'dubao', 'description': 'Dự báo hôm nay'},
          {'command': 'tuan', 'description': 'Dự báo 7 ngày'},
          {'command': 'caidat', 'description': 'Chọn thành phố'},
        ],
        'group_commands': [
          {'command': 'dubao', 'description': 'Dự báo cho cả nhóm'},
        ],
      },
    };
    final bconv = 'd:$botPeer';
    final w1 = _mkMsg(bconv, myPeer, '/dubao', now - 9 * 60000, mine: true);
    final w2 = _mkMsg(bconv, botPeer, '🌤️ **Hà Nội** hôm nay: 24–31°C, có mây, _khả năng mưa 20%_.\nChất lượng không khí: `AQI 68` (trung bình).\n||Mẹo: mang theo ô nhé!||', now - 9 * 60000 + 1500);
    w2['meta'] = {'buttons': [
      [{'text': '📍 TP.HCM', 'data': 'city:hcm'}, {'text': '📍 Đà Nẵng', 'data': 'city:dn'}],
      [{'text': '📅 Cả tuần', 'data': 'week'}, {'text': '🌐 Mở web', 'url': 'https://getlumora.pages.dev/developers/'}],
    ]};
    _msgs[bconv] = [w1, w2];
    _convs[bconv] = {'id': bconv, 'kind': 0, 'title': 'Thời tiết Bot', 'last_ts': w2['ts'], 'unread': 1, 'muted': false, 'pinned': false, 'last_text': '🌤️ Hà Nội hôm nay: 24–31°C'};
    _bots['weather_bot'] = {'username': 'weather_bot', 'name': 'Thời tiết Bot', 'handle': '@weather_bot·z5n7jy', 'peer': botPeer, 'short_id': _shortId(41), 'created': now - 86400000, 'token': 'lumora_bot_${_hex(48)}'};
    _packs.add({'id': 'pk_vn', 'name': 'Việt Nam đẹp', 'created': now, 'stickers': [
      for (final k in ['dalat', 'beach', 'coffee', 'city']) {'hash': 'st_$k', 'emoji': const {'dalat': '🏔️', 'beach': '🏖️', 'coffee': '☕', 'city': '🌃'}[k], 'mime': 'image/jpeg', 'animated': false},
    ]});
    // A sticker and a formatted message in Minh Anh's chat.
    final stMsg = _mkMsg('d:${peers[0]}', peers[0], '', now - 6 * 60000, kind: 'sticker');
    stMsg['body'] = {'hash': 'st_coffee', 'emoji': '☕', 'mime': 'image/jpeg', 'pack': 'pk_vn', 'animated': false};
    _msgs['d:${peers[0]}']!.add(stMsg);
    _msgs['d:${peers[0]}']!.add(_mkMsg('d:${peers[0]}', peers[0], 'Nhớ **build bản mới** trước _thứ 6_ nhé, lệnh: `flutter build linux`\n||bí mật: có bánh sinh nhật 🎂||', now - 5 * 60000));
    _msgs['d:${peers[0]}']!.sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
    _recentRemote.addAll([
      {'peer': peers[7], 'name': _contacts[peers[7]]!['name'], 'short_id': _contacts[peers[7]]!['short_id'], 'last': now - 3600000, 'trusted': true, 'macs': ['3c:7c:3f:1a:22:9e']},
      // Switched off: can be woken up.
      {'peer': peers[6], 'name': _contacts[peers[6]]!['name'], 'short_id': _contacts[peers[6]]!['short_id'], 'last': now - 86400000, 'trusted': true, 'macs': ['d8:bb:c1:0a:7f:33']},
      {'peer': peers[1], 'name': _contacts[peers[1]]!['name'], 'short_id': _contacts[peers[1]]!['short_id'], 'last': now - 3 * 86400000, 'trusted': false},
    ]);
    // Wallpapers & group avatars/descriptions.
    _wallpapers['d:${peers[3]}'] = 'sakura';
    _wallpapers[conv] = 'doodle';
    final gid = conv.substring(2);
    _groups[gid]!['description'] = 'Nhóm phát triển Lumora · họp sprint thứ 6 hằng tuần';
    _groups[gid]!['has_avatar'] = true;
    _groupAvatars[gid] = base64Encode(_avatarPng(3));
    // Inline photos (thumb + full image from assets).
    final ha = 'd:${peers[3]}';
    final hl = _msgs[ha]!;
    hl.removeWhere((m) => m['kind'] == 'file');
    final base = now - 50 * 60 * 60000;
    hl.insert(1, _imgMsg(ha, peers[3], 'dalat', base + 1000));
    hl.insert(2, _imgMsg(ha, peers[3], 'beach', base + 2000));
    hl.insert(3, _imgMsg(ha, peers[3], 'coffee', base + 3000));
    hl.add(_imgMsg(ha, myPeer, 'city', now - 30 * 60000, mine: true));
    hl.add(_mkMsg(ha, peers[3], 'Ảnh đêm Sài Gòn đẹp ghê 😍', now - 28 * 60000));
    _convs[ha]!['last_ts'] = now - 28 * 60000;
    _convs[ha]!['last_text'] = 'Ảnh đêm Sài Gòn đẹp ghê 😍';
    final ma = 'd:${peers[0]}';
    _msgs[ma]!.add(_imgMsg(ma, myPeer, 'beach', now - 30000, mine: true, state: 1, frac: 0.42));
    final fam = _convs.values.firstWhere((c) => (c['title'] as String).startsWith('Gia đình'))['id'] as String;
    _msgs[fam]!.insert(_msgs[fam]!.length - 1, _imgMsg(fam, peers[6], 'coffee', now - 40 * 60000));
    // Files with sender-made previews (PDF first page, first lines of code/text),
    // shown before download.
    final nm = 'd:${peers[2]}';
    final pt = now - (27 * 60 + 52) * 60000;
    _msgs[nm]!.add(_mkMsg(nm, peers[2], 'Gửi em mấy file của dự án nhé 👇', pt));
    _msgs[nm]!.add(_previewFileMsg(nm, peers[2], 'md', pt + 20000));
    _msgs[nm]!.add(_previewFileMsg(nm, peers[2], 'csv', pt + 40000, state: 0));
    _msgs[nm]!.add(_previewFileMsg(nm, myPeer, 'txt', pt + 60000, mine: true));
    _msgs[nm]!.add(_mkMsg(nm, peers[2], 'Còn đây là báo cáo quý 3 với script đồng bộ ảnh, xem trước rồi tải cái nào cần nha', pt + 100000));
    _msgs[nm]!.add(_previewFileMsg(nm, peers[2], 'pdf', pt + 120000, state: 0));
    _msgs[nm]!.add(_previewFileMsg(nm, peers[2], 'py', pt + 140000, state: 0));
    _msgs[nm]!.sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
    // Scheduled.
    _scheduled['sch1'] = {'sched_id': 'sch1', 'conv': 'd:${peers[2]}', 'text': 'Chúc mừng sinh nhật anh Nam 🎂', 'at': now + 20 * 3600000};
  }

  Map<String, dynamic> _imgMsg(String conv, String author, String key, int ts, {bool mine = false, int state = 2, double frac = 1}) {
    final img = kMockImages[key]!;
    final id = 'img_${_hex(10)}';
    final size = 180000 + _rand.nextInt(900000);
    final path = 'asset:${img['asset']}';
    _files[id] = {
      'id': id, 'conv': conv, 'peer': mine ? (conv.startsWith('d:') ? conv.substring(2) : '') : author, 'name': '$key.jpg', 'size': size,
      'hash': _hex(64), 'path': state == 2 ? path : '', 'direction': mine ? 0 : 1, 'state': state,
      'progress': (size * frac).round(), 'created': ts, 'speed_bps': state == 1 ? 900000 : null,
    };
    final m = _mkMsg(conv, author, '', ts, mine: mine, kind: 'file', status: state == 2 ? 3 : 1);
    m['body'] = {
      'file_id': id, 'name': '$key.jpg', 'size': size, 'mime': 'image/jpeg', 'hash': _files[id]!['hash'],
      'thumb': img['thumb'], 'width': img['width'], 'height': img['height'],
    };
    m['file'] = {'state': state, 'progress': (size * frac).round(), 'size': size, 'path': state == 2 ? path : null, 'direction': mine ? 0 : 1};
    return m;
  }

  /// A file message with a sender-made preview (see [kMockFilePreviews]);
  /// `state` 0 = offered (not downloaded yet), 2 = on this device.
  Map<String, dynamic> _previewFileMsg(String conv, String author, String key, int ts, {bool mine = false, int state = 2}) {
    final d = kMockFilePreviews[key]!;
    final id = 'pv_${_hex(10)}';
    final size = d['size'] as int;
    final path = 'asset:${d['asset']}';
    final done = state == 2 || mine;
    _files[id] = {
      'id': id, 'conv': conv, 'peer': mine ? (conv.startsWith('d:') ? conv.substring(2) : '') : author, 'name': d['name'], 'size': size,
      'hash': _hex(64), 'path': done ? path : '', 'direction': mine ? 0 : 1, 'state': mine ? 2 : state,
      'progress': done ? size : 0, 'created': ts, 'preview': d['preview'],
    };
    final m = _mkMsg(conv, author, '', ts, mine: mine, kind: 'file', status: 3);
    m['body'] = {
      'file_id': id, 'name': d['name'], 'size': size, 'mime': key == 'pdf' ? 'application/pdf' : (key == 'txt' ? 'text/plain' : 'application/octet-stream'),
      'hash': _files[id]!['hash'], 'thumb': d['thumb'], 'width': d['width'] ?? 0, 'height': d['height'] ?? 0, 'preview': d['preview'],
    };
    m['file'] = {'state': mine ? 2 : state, 'progress': done ? size : 0, 'size': size, 'path': done ? path : null, 'direction': mine ? 0 : 1};
    return m;
  }

  /// Minimal PNG encoder for demo avatars (soft gradient + circle).
  List<int> _avatarPng(int seed) {
    const w = 64, h = 64;
    final pal = [
      [0xFF, 0x9A, 0x8B, 0x6C, 0x5C, 0xE7],
      [0x43, 0xE9, 0x7B, 0x38, 0xF9, 0xD7],
      [0xFA, 0xD9, 0x61, 0xF7, 0x6B, 0x1C],
      [0x00, 0xC2, 0xD1, 0x6C, 0x5C, 0xE7],
      [0xF7, 0x79, 0x7D, 0xFB, 0xD7, 0x86],
      [0x84, 0xFA, 0xB0, 0x8F, 0xD3, 0xF4],
    ][seed % 6];
    final raw = <int>[];
    for (var y = 0; y < h; y++) {
      raw.add(0);
      for (var x = 0; x < w; x++) {
        final t = (x + y) / (w + h);
        final dx = x - 32, dy = y - 26;
        final head = dx * dx + dy * dy < 13 * 13;
        final body = (x - 32) * (x - 32) / (22 * 22) + (y - 64) * (y - 64) / (20 * 20) < 1;
        final k = head || body ? 1.0 : 0.0;
        for (var c = 0; c < 3; c++) {
          final base = pal[c] * (1 - t) + pal[c + 3] * t;
          raw.add((base * (1 - 0.35 * k) + 255 * 0.35 * k).round().clamp(0, 255));
        }
        raw.add(255);
      }
    }
    List<int> chunk(String type, List<int> data) {
      final t = ascii.encode(type);
      final len = data.length;
      final crc = _crc32([...t, ...data]);
      return [len >> 24 & 255, len >> 16 & 255, len >> 8 & 255, len & 255, ...t, ...data, crc >> 24 & 255, crc >> 16 & 255, crc >> 8 & 255, crc & 255];
    }

    final ihdr = [0, 0, 0, w, 0, 0, 0, h, 8, 6, 0, 0, 0];
    return [
      137, 80, 78, 71, 13, 10, 26, 10,
      ...chunk('IHDR', ihdr),
      ...chunk('IDAT', ZLibEncoder().convert(raw)),
      ...chunk('IEND', const []),
    ];
  }

  static int _crc32(List<int> data) {
    var c = 0xffffffff;
    for (final b in data) {
      c ^= b;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
      }
    }
    return c ^ 0xffffffff;
  }

  Map<String, dynamic> _copyTo(String conv, Map<String, dynamic> src, {Map<String, dynamic>? meta}) {
    final m = _mkMsg(conv, myPeer, src['body'] is String ? src['body'] as String : jsonEncode(src['body']), _now, mine: true, status: 1, kind: src['kind'] as String);
    m['meta'] = meta ?? {};
    _msgs.putIfAbsent(conv, () => []).add(m);
    final c = _convs[conv];
    if (c != null) {
      c['last_ts'] = m['ts'];
      c['last_mine'] = m['mine'] == true;
      c['last_text'] = _preview(m);
      _emit('conversation', Map.of(c));
    }
    _emit('message', Map.of(m));
    return m;
  }

  Map<String, dynamic>? _findAny(String id) {
    for (final l in _msgs.values) {
      for (final m in l) {
        if (m['id'] == id) return m;
      }
    }
    return null;
  }

  Map<String, dynamic> _mkMsg(String conv, String author, String body, int ts,
      {bool mine = false, int status = 3, String kind = 'text'}) {
    _seq++;
    return {
      'id': _hex(32),
      'conv': conv,
      'author': author,
      'hlc': ts * 16 + (_seq % 16),
      'ts': ts,
      'kind': kind,
      'body': body,
      'status': mine ? status : 3,
      'edited': false,
      'deleted': false,
      'reply_to': null,
      'reactions': <String, List<String>>{},
      'expires': null,
      'mine': mine,
      'silent': false,
    };
  }

  String _preview(Map<String, dynamic> m, {bool group = false}) {
    if (m['body'] is Map && m['kind'] == 'file') {
      final mime = (m['body'] as Map)['mime']?.toString() ?? '';
      return mime.startsWith('image/') ? '🖼️ Photo' : (mime.startsWith('video/') ? '🎬 Video' : '📎 ${(m['body'] as Map)['name']}');
    }
    if (m['kind'] == 'location') return '📍 ${(m['body'] as Map)['label'] ?? ''}';
    if (m['kind'] == 'voice') return '🎤 Voice message';
    if (m['kind'] == 'contact') return '👤 ${(m['body'] as Map)['name']}';
    if (m['kind'] == 'checklist') return 'Danh sách việc: ${(m['body'] as Map)['title']}';
    if (m['kind'] == 'reminder') return 'Nhắc hẹn: ${(m['body'] as Map)['title']}';
    if (m['body'] is Map) return (m['body'] as Map)['text']?.toString() ?? '';
    if (m['kind'] == 'poll') return '📊 ${(m['meta']?['poll']?['question']) ?? ''}';
    var t = m['body'] as String;
    if (m['kind'] == 'file') {
      final n = RegExp(r'"name":"([^"]+)"').firstMatch(t)?.group(1) ?? 'tệp';
      t = '📎 $n';
    }
    if (m['mine'] == true) return t; // "You:" comes from `last_mine`, never from the text
    if (group && m['kind'] != 'system') {
      final a = _contacts[m['author']]?['name'] as String?;
      if (a != null) return '${a.split(' ').last}: $t';
    }
    return t;
  }

  // ------------------------------------------------------------- control

  /// The phrase an account was restored from (the demo keeps its data, but
  /// answers `phrase_check` like the restored account would).
  String? _restoredPhrase;

  void _emit(String event, Map<String, dynamic> data) {
    if (_events.isClosed) return;
    // like the core: messages of a locked chat (account setting) say so
    final locked = event == 'message' && (_lockedChats?.contains(data['conv']) ?? false);
    _events.add({'event': event, ...data, if (locked) 'locked': true});
  }

  void _later(Duration d, void Function() f) {
    if (!timers) return;
    _timers.add(Timer(d, f));
  }

  @override
  Future<void> start(Map<String, dynamic> config) async {
    final pass = config['passphrase'];
    if (_started && pass is String && _passphrase.isNotEmpty && pass != _passphrase) {
      throw ApiException('Sai mật khẩu', cmd: 'start', code: 'err.wrong_passphrase');
    }
    final restore = config['restore_backup'];
    if (!_started && restore is List && restore.length == 2) _checkBackup('${restore[0]}', '${restore[1]}');
    if (pass is String && pass.isNotEmpty && _passphrase.isEmpty) _passphrase = pass;
    if (config['name'] is String && (config['name'] as String).isNotEmpty) _me['name'] = config['name'];
    if (config['link_pending'] == true) _linkPending = true;
    final phrase = config['recovery_phrase'];
    if (phrase is String && phrase.trim().isNotEmpty) _restoredPhrase = phrase;
    if (_started) return;
    _started = true;
    _later(const Duration(milliseconds: 50), () => _emit('ready', {'peer': myPeer, 'short_id': _me['short_id']}));
    if (!timers) return;
    // File progress ticks.
    _timers.add(Timer.periodic(const Duration(milliseconds: 700), (_) => _tickFiles()));
    // Presence + typing churn.
    _timers.add(Timer.periodic(const Duration(seconds: 9), (_) => _randomPresence()));
    if (autoDemo) {
      _later(const Duration(seconds: 6), () => _typingBurst('d:${_friend(1)}', _friend(1)));
      _later(const Duration(seconds: 45), simulateIncomingCall);
      _later(const Duration(seconds: 90), simulateRemoteRequest);
    }
  }

  String _friend(int i) => _contacts.values.where((c) => c['status'] == 3).elementAt(i)['peer'] as String;

  /// Public demo hooks (used by the "Demo" section in Settings).
  /// Emits any core event (tests).
  void emitForTest(String event, [Map<String, dynamic> data = const {}]) => _emit(event, data);

  /// History copied in from another device (tests): `count` older messages land
  /// before the oldest one of [conv], without `message` events (like the core).
  void importHistoryForTest(String conv, int count) {
    final list = _msgs.putIfAbsent(conv, () => []);
    final oldest = list.isEmpty ? _now : list.map((m) => m['hlc'] as int).reduce(math.min);
    final peer = conv.startsWith('d:') ? conv.substring(2) : myPeer;
    final old = [
      for (var i = count; i > 0; i--) _mkMsg(conv, peer, 'old $i', _now, status: 2)..['hlc'] = oldest - i * 1000,
    ];
    list.insertAll(0, old);
  }

  /// My role in a group changes (tests); `none`: I'm no longer a member.
  void setGroupRoleForTest(String gid, String role) {
    final g = _groups[gid];
    if (g == null) return;
    g['my_role'] = role;
    if (role == 'none') (g['members'] as List).removeWhere((m) => m['peer'] == myPeer);
  }

  /// A friend's message arrives in [conv] (tests).
  void simulateIncomingMessage(String conv, String text) {
    final from = conv.startsWith('d:') ? conv.substring(2) : _friend(1);
    final m = _mkMsg(conv, from, text, _now);
    _msgs.putIfAbsent(conv, () => []).add(m);
    final c = _convs[conv];
    if (c != null) {
      c['last_ts'] = m['ts'];
      c['unread'] = (c['unread'] as int) + 1;
      _emit('conversation', Map.of(c));
    }
    _emit('message', Map.of(m));
  }

  void simulateIncomingCall({bool video = true}) {
    final peer = _friend(0);
    final id = 'c_${_hex(8)}';
    _calls[id] = {'call_id': id, 'conv': 'd:$peer', 'peer': peer, 'state': 'incoming', 'video': video, 'participants': [peer]};
    _emit('call', _calls[id]!);
  }

  /// Texts sent with `remote_clipboard` (tests).
  final List<String> clipboardSent = [];

  /// Registers a session (tests / screenshots set remote state directly).
  void debugAddRemoteSession(String session, String peer, {String role = 'viewer'}) =>
      _remoteSessions[session] = {'session': session, 'peer': peer, 'role': role};

  void simulateRemoteRequest() {
    final peer = _friend(7);
    final s = 'r_${_hex(8)}';
    _remoteSessions[s] = {'session': s, 'peer': peer, 'role': 'host'};
    _emit('remote_request', {'session': s, 'peer': peer, 'name': _contacts[peer]!['name'], 'view_only': false});
  }

  void simulateFriendRequest() {
    final peer = _peerId('Lý Hải Yến');
    _contacts[peer] = {
      'peer': peer, 'short_id': _shortId(31), 'name': 'Lý Hải Yến', 'status': 2,
      'added': _now, 'last_seen': 0, 'verified': false, 'relays': [], 'online': true,
    };
    _emit('friend_request', {'peer': peer, 'name': 'Lý Hải Yến', 'note': 'Kết bạn với mình nhé!'});
    _emit('contact', _contacts[peer]!);
  }

  void _tickFiles() {
    for (final f in _files.values) {
      if (f['state'] != 1) continue;
      final size = f['size'] as int;
      final speed = (f['speed_bps'] as int? ?? 4000000) * (0.85 + _rand.nextDouble() * 0.3);
      var prog = (f['progress'] as int) + (speed * 0.7).round();
      if (prog >= size) {
        prog = size;
        f['state'] = 2;
        f['speed_bps'] = null;
      } else {
        f['speed_bps'] = speed.round();
      }
      f['progress'] = prog;
      _emit('file', Map.of(f));
    }
  }

  void _randomPresence() {
    final friends = _contacts.values.where((c) => c['status'] == 3).toList();
    final c = friends[2 + _rand.nextInt(friends.length - 2)];
    c['online'] = !(c['online'] as bool);
    c['path'] = c['online'] == true ? ['direct', 'lan', 'relay'][_rand.nextInt(3)] : null;
    if (c['online'] == false) c['last_seen'] = _now;
    _emit('presence', {'peer': c['peer'], 'online': c['online'], 'path': c['path']});
  }

  void _typingBurst(String conv, String peer, {Duration d = const Duration(seconds: 3)}) {
    _emit('typing', {'conv': conv, 'peer': peer, 'on': true});
    _typingTimers[conv]?.cancel();
    _typingTimers[conv] = Timer(d, () => _emit('typing', {'conv': conv, 'peer': peer, 'on': false}));
  }

  static const _replies = [
    'Ok nha 👌',
    'Haha 😂',
    'Để mình xem đã',
    'Chuẩn luôn!',
    'Tuyệt vời 🎉',
    'Ừ, mai nói tiếp nhé',
    'Cảm ơn nha 🙏',
    'Nghe hợp lý đó',
    'Gửi mình thêm chi tiết với',
    'Đang bận chút, lát rep nhé',
  ];

  void _simulateReply(String conv, Map<String, dynamic> sent) {
    // Delivery / read receipts.
    _later(const Duration(milliseconds: 400), () {
      sent['status'] = 2;
      _emit('message_update', {'conv': conv, 'id': sent['id'], 'status': 2});
    });
    String? responder;
    if (conv.startsWith('d:')) {
      responder = conv.substring(2);
    } else {
      final g = _groups[conv.substring(2)];
      final ms = (g?['members'] as List?)?.where((m) => m['peer'] != myPeer).toList() ?? [];
      if (ms.isNotEmpty) responder = ms[_rand.nextInt(ms.length)]['peer'] as String;
    }
    if (responder == null || _contacts[responder]?['online'] != true && conv.startsWith('d:')) return;
    final r = responder;
    _later(const Duration(milliseconds: 1500), () {
      sent['status'] = 3;
      _emit('message_update', {'conv': conv, 'id': sent['id'], 'status': 3});
      _typingBurst(conv, r, d: const Duration(milliseconds: 2200));
    });
    _later(const Duration(milliseconds: 3800), () {
      final text = _replies[_rand.nextInt(_replies.length)];
      final m = _mkMsg(conv, r, text, _now);
      _msgs[conv]!.add(m);
      final c = _convs[conv];
      if (c != null) {
        c['last_ts'] = m['ts'];
        c['last_mine'] = m['mine'] == true;
        c['last_text'] = _preview(m, group: conv.startsWith('g:'));
        c['unread'] = (c['unread'] as int) + 1;
        _emit('conversation', Map.of(c));
      }
      _emit('message', Map.of(m));
    });
  }

  // ------------------------------------------------- checklists / reminders

  void _addOwn(String conv, Map<String, dynamic> m) {
    _msgs.putIfAbsent(conv, () => []).add(m);
    final c = _convs[conv];
    if (c != null) {
      c['last_ts'] = m['ts'];
      c['last_mine'] = m['mine'] == true;
      c['last_text'] = _preview(m);
      _emit('conversation', Map.of(c));
    }
  }

  String? _responder(String conv) {
    if (conv.startsWith('d:')) return _contacts[conv.substring(2)]?['online'] == true ? conv.substring(2) : null;
    final g = _groups[conv.substring(2).split('#').first];
    final ms = (g?['members'] as List?)?.where((m) => m['peer'] != myPeer).toList() ?? [];
    return ms.isEmpty ? null : ms[_rand.nextInt(ms.length)]['peer'] as String;
  }

  void _tick(String conv, Map<String, dynamic> m, int item, bool done, String by) {
    final r = Map<String, dynamic>.of((m['reactions'] as Map).cast<String, dynamic>());
    final checks = Map<String, dynamic>.of(((r['__checks'] as Map?) ?? {}).cast<String, dynamic>());
    checks['$item'] = {'done': done, 'by': by, 'at': _now};
    r['__checks'] = checks;
    m['reactions'] = r;
    _emit('message_update', {'conv': conv, 'id': m['id'], 'reactions': r});
  }

  void _simulateTick(String conv, Map<String, dynamic> m) {
    final r = _responder(conv);
    if (r == null) return;
    _later(const Duration(seconds: 3), () => _tick(conv, m, 0, true, r));
  }

  void _seen(String conv, Map<String, dynamic> m, String by) {
    final r = Map<String, dynamic>.of((m['reactions'] as Map).cast<String, dynamic>());
    final seen = Map<String, dynamic>.of(((r['__seen'] as Map?) ?? {}).cast<String, dynamic>());
    seen[by] = _now;
    r['__seen'] = seen;
    m['reactions'] = r;
    _emit('message_update', {'conv': conv, 'id': m['id'], 'reactions': r});
  }

  /// Fires `reminder_due` like the core scheduler (only for near reminders).
  void _armReminder(String conv, Map<String, dynamic> m) {
    final b = m['body'] as Map;
    final delay = (b['at_ms'] as int) - _now;
    if (delay > 6 * 3600000) return;
    _later(Duration(milliseconds: delay.clamp(0, 1 << 31)), () {
      final r = m['reactions'] as Map;
      if (r['__cancelled'] != null || m['deleted'] == true) return;
      _emit('reminder_due', {
        'conv': conv, 'msg_id': m['id'], 'title': b['title'], 'note': b['note'] ?? '',
        'at_ms': b['at_ms'], 'author': m['author'], 'late': false,
      });
    });
  }

  // ------------------------------------------------------------- frames

  @override
  Future<FrameData?> frame(int stream) async {
    final t = (_frameTick[stream] ?? 0) + 1;
    _frameTick[stream] = t;
    if (stream >= 100) return _desktopFrame(t);
    if (stream == 0) return _selfFrame(t);
    return _cameraFrame(stream, t);
  }

  /// Mock self-view (stream 0): a stylised face with sensor-like grain. The
  /// `video_beauty` / `video_lowlight` settings change it roughly the way the
  /// core's filters do (smoother skin, a little brighter and warmer), so the
  /// effects panel previews something meaningful without a camera.
  FrameData _selfFrame(int t) {
    const w = 192, h = 108;
    final px = Uint8List(w * h * 4);
    final level = ((_coreSettings['video_beauty'] as num?) ?? 0).toInt().clamp(0, 3);
    final boost = _coreSettings['video_lowlight'] == true ? 1.12 : 1.0;
    final smooth = const [0.0, 0.5, 0.75, 0.9][level];
    final lift = const [0.0, 5.0, 8.0, 11.0][level];
    final warm = const [0.0, 2.5, 4.0, 6.0][level];
    final rnd = math.Random(t);
    final cx = w * 0.5 + 2 * math.sin(t / 45), cy = h * 0.5;
    var i = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        // wall (teal, darker towards the edges) + a door light on the right
        double r = 64 + 18 * (1 - (x - w / 2).abs() / w), g = 92 + 18 * (1 - (x - w / 2).abs() / w), b = 90 + 14 * (1 - y / h);
        if (x > w * 0.84) {
          r = 210;
          g = 212;
          b = 200;
        }
        var skin = false;
        final fx = (x - cx) / 23, fy = (y - cy) / 30;
        final face = fx * fx + fy * fy;
        final hx = (x - cx) / 27, hy = (y - (cy - 9)) / 27;
        final sx = (x - cx) / 62, sy = (y - h * 1.12) / 30;
        if (sx * sx + sy * sy < 1) {
          r = 150;
          g = 152;
          b = 158; // shirt
        }
        if (face < 1) {
          skin = true;
          final shade = 1 - 0.18 * face;
          r = 206 * shade;
          g = 160 * shade;
          b = 134 * shade;
          final ex = (x - cx).abs() - 9, ey = y - (cy - 3);
          if (ex * ex / 9 + ey * ey / 2.2 < 1) {
            r = 44;
            g = 34;
            b = 34;
            skin = false;
          }
          final my = (y - (cy + 15)) / 2.2, mx = (x - cx) / 7;
          if (mx * mx + my * my < 1) {
            r = 168;
            g = 96;
            b = 92;
          }
        }
        if (hx * hx + hy * hy < 1 && y < cy - 12 + 4 * (x - cx).abs() / 23) {
          r = 38;
          g = 30;
          b = 27;
          skin = false;
        }
        final grain = (rnd.nextDouble() * 2 - 1) * 16 * (skin ? 1 - smooth : 1 - smooth * 0.15);
        if (skin) {
          r += lift + warm;
          g += lift;
          b += lift - warm * 0.6;
        }
        px[i++] = ((r + grain) * boost).clamp(0, 255).toInt();
        px[i++] = ((g + grain) * boost).clamp(0, 255).toInt();
        px[i++] = ((b + grain) * boost).clamp(0, 255).toInt();
        px[i++] = 255;
      }
    }
    return FrameData(w, h, px);
  }

  /// Animated gradient "camera" frame with a soft moving blob.
  FrameData _cameraFrame(int stream, int t) {
    const w = 160, h = 90;
    final px = Uint8List(w * h * 4);
    final hues = [
      [108, 92, 231, 0, 194, 209],
      [236, 72, 153, 245, 158, 11],
      [34, 197, 94, 0, 194, 209],
      [59, 130, 246, 108, 92, 231],
      [239, 68, 68, 168, 85, 247],
    ][stream % 5];
    final cx = w * (0.5 + 0.3 * math.sin(t / 25 + stream));
    final cy = h * (0.5 + 0.25 * math.cos(t / 31 + stream));
    var i = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final g = (x + y) / (w + h);
        final dx = x - cx, dy = y - cy;
        final blob = math.max(0.0, 1 - (dx * dx + dy * dy) / 900);
        px[i++] = (hues[0] * (1 - g) + hues[3] * g + 90 * blob).clamp(0, 255).toInt();
        px[i++] = (hues[1] * (1 - g) + hues[4] * g + 90 * blob).clamp(0, 255).toInt();
        px[i++] = (hues[2] * (1 - g) + hues[5] * g + 90 * blob).clamp(0, 255).toInt();
        px[i++] = 255;
      }
    }
    return FrameData(w, h, px);
  }

  /// Fake desktop: wallpaper, taskbar, a couple of windows, moving cursor.
  FrameData _desktopFrame(int t) {
    const w = 480, h = 270;
    final px = Uint8List(w * h * 4);
    final mx = (w * (0.5 + 0.35 * math.sin(t / 40))).toInt();
    final my = (h * (0.5 + 0.3 * math.cos(t / 53))).toInt();
    var i = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        int r, g, b;
        final gy = y / h;
        r = (40 + 60 * gy).toInt();
        g = (30 + 40 * (x / w)).toInt();
        b = (90 + 80 * (1 - gy)).toInt();
        // window 1
        if (x > 40 && x < 260 && y > 30 && y < 190) {
          if (y < 44) {
            r = 230; g = 232; b = 240;
          } else {
            r = 250; g = 250; b = 252;
            if (y > 56 && (y - 56) % 14 < 6 && x > 52 && x < 52 + 60 + ((((y - 56) ~/ 14) * 37) % 130)) {
              r = 200; g = 204; b = 220;
            }
          }
        }
        // window 2 (terminal)
        if (x > 220 && x < 440 && y > 80 && y < 230) {
          if (y < 94) {
            r = 60; g = 62; b = 80;
          } else {
            r = 22; g = 24; b = 34;
            if (y > 100 && (y - 100) % 12 < 5 && x > 230 && x < 230 + 30 + ((((y - 100) ~/ 12) * 53) % 150)) {
              r = 80; g = 220; b = 120;
            }
          }
        }
        // taskbar
        if (y > h - 18) {
          r = 18; g = 20; b = 32;
          if (x > w ~/ 2 - 50 && x < w ~/ 2 + 50 && (x ~/ 16).isEven && y > h - 14 && y < h - 4) {
            r = 108; g = 92; b = 231;
          }
        }
        // cursor
        final dx = x - mx, dy = y - my;
        if (dx >= 0 && dy >= 0 && dx < 8 && dy < 12 && dx <= dy) {
          r = 255; g = 255; b = 255;
        }
        px[i++] = r;
        px[i++] = g;
        px[i++] = b;
        px[i++] = 255;
      }
    }
    return FrameData(w, h, px);
  }

  // ------------------------------------------------------------ requests

  /// `ui_secret_get/set`: the core keeps these in its encrypted database.
  final Map<String, String> _uiSecrets = {};

  /// `locked_chats_get/set`: the account's locked chats (synced setting in the
  /// core); null until a device saved a list.
  List<String>? _lockedChats;

  /// Tests: another device of the account changed the locked chats (the core
  /// imports the synced value and tells the app).
  void lockedChatsFromOtherDevice(List<String> chats) {
    _lockedChats = List.of(chats);
    _emit('settings', {'key': 'privacy.locked_chats'});
  }

  /// `botfather_*`: the BotFather conversation (synced, last 200 lines).
  final List<Map<String, dynamic>> _botfatherChat = [];

  @override
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]) async {
    // Like the core: a `send_*` retried with the same `client_id` (within
    // 24 h) returns the first message instead of sending it again.
    final cid = args['client_id'];
    if (cmd.startsWith('send_') && cid is String && cid.isNotEmpty) {
      final key = '$cmd|$cid';
      final first = _sentByClient[key];
      if (first != null) {
        await Future<void>.delayed(Duration.zero);
        return Map<String, dynamic>.of(first);
      }
      final r = await _handle(cmd, args);
      if (r is Map<String, dynamic>) _sentByClient[key] = Map.of(r);
      return r;
    }
    return _handle(cmd, args);
  }

  /// `send_*` results by `cmd|client_id`.
  final Map<String, Map<String, dynamic>> _sentByClient = {};

  Future<dynamic> _handle(String cmd, Map<String, dynamic> args) async {
    // Tiny async gap so UI code paths behave like the real thing.
    await Future<void>.delayed(Duration.zero);
    switch (cmd) {
      case 'me':
        return {
          ..._me,
          'protection': _passphrase.isEmpty ? 'device' : 'passphrase',
          'account': myPeer,
          'device': _thisDevice,
          'primary': _linkPending ? true : _isPrimary,
          'device_name': _devices.firstWhere((d) => d['device'] == _thisDevice, orElse: () => const {'name': ''})['name'],
          'devices': _devices.length,
          'link_pending': _linkPending,
        };
      // ---------------------------------------------------- my devices (multi-device)
      case 'devices':
        return _devicesJson();
      case 'device_rename':
        _requirePrimary(cmd);
        final d = _devices.where((x) => x['device'] == args['device']);
        if (d.isEmpty) throw ApiException('Không tìm thấy thiết bị', cmd: cmd, code: 'err.generic');
        d.first['name'] = '${args['name']}'.trim();
        _emit('devices', _devicesJson());
        return _devicesJson();
      case 'device_revoke':
        _requirePrimary(cmd);
        final id = '${args['device']}';
        if (id == _thisDevice) throw ApiException('Không thể đăng xuất chính thiết bị này từ đây.', cmd: cmd, code: 'err.generic');
        final gone = _devices.where((x) => x['device'] == id).toList();
        if (gone.isEmpty) throw ApiException('Không tìm thấy thiết bị', cmd: cmd, code: 'err.generic');
        _devices.remove(gone.first);
        _revokedDevices.add({...gone.first, 'at': _now, 'wipe': args['wipe_media'] == true});
        _emit('devices', _devicesJson());
        return _devicesJson();
      case 'device_logout':
        if (_isPrimary) throw ApiException('Đây là thiết bị chính của tài khoản.', cmd: cmd, code: 'err.already_primary');
        _soon(const Duration(milliseconds: 400), () => simulateDeviceRevoked(bySelf: true));
        return {'notified': true};
      case 'device_promote':
        if (_isPrimary) throw ApiException('Thiết bị này đã là thiết bị chính.', cmd: cmd, code: 'err.already_primary');
        final words = '${args['phrase']}'.trim().split(RegExp(r'\s+'));
        if (words.length != 24) throw ApiException('Cụm từ khôi phục chưa đúng.', cmd: cmd, code: 'err.bad_phrase');
        if (words.join(' ') != kMockRecoveryPhrase) {
          throw ApiException('Cụm từ này thuộc về một tài khoản khác.', cmd: cmd, code: 'err.phrase_mismatch');
        }
        // the install's own passphrase re-wraps the database for the account key
        if (_passphrase.isNotEmpty && args['passphrase'] != _passphrase) {
          throw ApiException('Mật khẩu không đúng', cmd: cmd, code: 'err.wrong_passphrase');
        }
        lastPromotePassphrase = args['passphrase'] as String?;
        _soon(const Duration(milliseconds: 600), () {
          final me = _devices.firstWhere((d) => d['device'] == _thisDevice);
          final old = _devices.first;
          _devices
            ..remove(me)
            ..remove(old)
            ..insert(0, me);
          _revokedDevices.add({...old, 'at': _now, 'wipe': false});
          _isPrimary = true;
          _emit('link_state', {'state': 'restart', 'reason': 'promoted'});
          restart(overrides: const {'link_pending': false}, reason: 'promoted');
        });
        return <String, dynamic>{};
      case 'contact_devices':
        return _contactDevices('${args['peer']}');
      case 'link_invite':
        _requirePrimary(cmd);
        if (_linkPending) throw ApiException('Thiết bị này đang chờ được liên kết.', cmd: cmd, code: 'err.link_failed');
        _invite = {
          'qr': 'lumora://link/v1/${_hex(48)}',
          'code': '4821-0397-5512',
          'expires': _now + 600000,
          'device': _thisDevice,
          'name': _devices.firstWhere((d) => d['device'] == _thisDevice)['name'],
        };
        // demo: a new device scans it after a few seconds
        _later(const Duration(seconds: 5), () {
          if (_invite != null && _pendingLink == null) simulateLinkRequest();
        });
        return Map<String, dynamic>.of(_invite!);
      case 'link_scan':
        if (!_linkPending) throw ApiException('Thiết bị này đã thuộc một tài khoản.', cmd: cmd, code: 'err.link_failed');
        final qr = '${args['qr'] ?? ''}'.trim();
        final code = '${args['code'] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '');
        await Future<void>.delayed(Duration(milliseconds: timers ? 900 : 0));
        if (qr.isNotEmpty) {
          if (!qr.startsWith('lumora://link/')) throw ApiException('Đây không phải mã liên kết của Lumora.', cmd: cmd, code: 'err.link_code_invalid');
        } else {
          if (code.length != 12) throw ApiException('Mã cần đủ 12 chữ số.', cmd: cmd, code: 'err.link_code_invalid');
          if (code == '000000000000') throw ApiException('Mã chưa đúng. Hãy kiểm tra lại trên thiết bị kia.', cmd: cmd, code: 'err.link_code_wrong');
          if (code == '111111111111') throw ApiException('Mã đã hết hạn.', cmd: cmd, code: 'err.link_code_expired');
          if (code == '222222222222') throw ApiException('Không tìm thấy thiết bị kia.', cmd: cmd, code: 'err.link_not_found');
        }
        _linkTarget = {'device': _peerId('lan-phone-main'), 'name': 'Điện thoại của Lan', 'kind': 1, 'state': 'awaiting_approval'};
        _later(const Duration(seconds: 4), () {
          if (_linkTarget != null) simulateLinkApproved();
        });
        _later(const Duration(seconds: 5), () {
          for (var i = 1; i <= 6; i++) {
            _later(Duration(milliseconds: 900 * i), () => simulateHistorySync(i * 214, convsDone: i * 2, done: i == 6));
          }
        });
        return Map<String, dynamic>.of(_linkTarget!);
      case 'link_approve':
        _requirePrimary(cmd);
        final req = _pendingLink;
        if (req == null || req['device'] != args['device']) throw ApiException('Liên kết chưa hoàn tất. Vui lòng thử lại.', cmd: cmd, code: 'err.link_failed');
        _pendingLink = null;
        _invite = null;
        lastApprovedHistory = '${args['history']}';
        _devices.add({'device': req['device'], 'name': req['name'], 'kind': req['kind'], 'caps': 6, 'os': req['os'], 'added': _now, 'last_seen': _now, 'short_id': '590 127 643', 'online': true});
        _emit('link_state', {'state': 'approved', 'device': req['device']});
        _emit('devices', _devicesJson());
        return _devicesJson();
      case 'link_reject':
        _pendingLink = null;
        return null;
      case 'link_cancel':
        _invite = null;
        _pendingLink = null;
        _linkTarget = null;
        return null;
      case 'history_status':
        return Map<String, dynamic>.of(_history);
      case 'set_name':
        _me['name'] = args['name'];
        return null;
      case 'recovery_phrase':
        if (!_isPrimary) throw ApiException('Cụm từ khôi phục chỉ hiển thị trên thiết bị chính của bạn.', cmd: cmd, code: 'err.phrase_on_primary');
        return {
          // A valid 24-word BIP39 phrase (checksum included), like the core's.
          'phrase': kMockRecoveryPhrase,
        };
      case 'net_status':
        return _net();
      case 'contacts':
        return _contacts.values.map((c) => Map.of(c)).toList();
      case 'lookup':
        final sid = (args['short_id'] as String).replaceAll(' ', '');
        return _contacts.values
            .where((c) => (c['short_id'] as String).replaceAll(' ', '') == sid)
            .map((c) => {'peer': c['peer'], 'name': c['name']})
            .toList();
      case 'add_contact':
        final id = (args['target'] as String).replaceAll(' ', '');
        if (id.length != 9 && id.length != 52) throw ApiException('ID không hợp lệ', cmd: cmd);
        final peer = id.length == 52 ? id : _peerId('new$id');
        _contacts[peer] = {
          'peer': peer,
          'short_id': id.length == 9 ? '${id.substring(0, 3)} ${id.substring(3, 6)} ${id.substring(6)}' : _shortId(77),
          'name': 'Người dùng $id'.substring(0, math.min(20, 'Người dùng $id'.length)),
          'status': 1, 'added': _now, 'last_seen': 0, 'verified': false, 'relays': [], 'online': false,
        };
        _emit('contact', Map.of(_contacts[peer]!));
        return {'peer': peer};
      case 'accept_contact':
        final c = _contacts[args['peer']];
        if (c != null) {
          c['status'] = 3;
          _emit('contact', Map.of(c));
          final conv = 'd:${c['peer']}';
          _msgs.putIfAbsent(conv, () => []);
          _convs.putIfAbsent(conv, () => {
                'id': conv, 'kind': 0, 'title': c['name'], 'last_ts': _now, 'unread': 0,
                'muted': false, 'pinned': false, 'last_text': 'Các bạn đã là bạn bè 🎉',
              });
          _emit('conversation', Map.of(_convs[conv]!));
        }
        return null;
      case 'remove_contact':
        final c = _contacts.remove(args['peer']);
        if (c != null) _emit('contact', {...c, 'status': 0});
        return null;
      case 'unblock_contact':
        // Like the core: status back to 0, no event.
        _contacts[args['peer']]?['status'] = 0;
        return null;
      case 'security_status':
        final c = _contacts[args['peer']];
        return {'forward_secrecy': c?['online'] == true, 'verified': c?['verified'] == true};
      case 'block_contact':
        final c = _contacts[args['peer']];
        if (c != null) {
          c['status'] = 4;
          _emit('contact', Map.of(c));
        }
        return null;
      case 'rename_contact':
        final c = _contacts[args['peer']];
        if (c != null) {
          c['alias'] = args['alias'];
          _emit('contact', Map.of(c));
        }
        return null;
      case 'verify_contact':
        final r = math.Random((args['peer'] as String).hashCode ^ myPeer.hashCode);
        return {
          'safety_number': List.generate(12, (_) => r.nextInt(100000).toString().padLeft(5, '0')).join(' '),
        };
      case 'mark_verified':
        final c = _contacts[args['peer']];
        if (c != null) {
          c['verified'] = args['verified'] == true;
          _emit('contact', Map.of(c));
        }
        return null;
      case 'conversations':
        // Like the core: `last_mine` = the last message is mine.
        return _convs.values.map((c) {
          final last = _msgs[c['id']]?.lastOrNull;
          // (when the demo data set the preview by hand, its own flag counts)
          final fromLast = last != null && (c['last_text'] == _preview(last) || c['last_text'] == _preview(last, group: true));
          return {...c, 'last_mine': fromLast ? last['mine'] == true : c['last_mine'] == true};
        }).toList();
      case 'messages':
        final list = _msgs[args['conv']] ?? const [];
        final before = args['before'] as int?;
        final limit = (args['limit'] as int?) ?? 50;
        final filtered = before == null ? list : list.where((m) => (m['hlc'] as int) < before).toList();
        final start = math.max(0, filtered.length - limit);
        return filtered.sublist(start).map((m) => Map.of(m)).toList();
      case 'send_text':
        final conv = args['conv'] as String;
        final m = _mkMsg(conv, myPeer, args['text'] as String, _now, mine: true, status: 1);
        m['reply_to'] = args['reply_to'];
        if (args['ttl_ms'] != null) m['expires'] = _now + (args['ttl_ms'] as int);
        if (args['silent'] == true) m['silent'] = true;
        _msgs.putIfAbsent(conv, () => []).add(m);
        final c = _convs[conv];
        if (c != null) {
          c['last_ts'] = m['ts'];
          c['last_mine'] = m['mine'] == true;
          c['last_text'] = _preview(m);
          _emit('conversation', Map.of(c));
        }
        _simulateReply(conv, m);
        return Map.of(m);
      case 'edit_message':
        final m = _find(args['conv'], args['msg_id']);
        if (m != null) {
          m['body'] = args['text'];
          m['edited'] = true;
          _emit('message_update', {'conv': args['conv'], 'id': args['msg_id'], 'body': args['text'], 'edited': true});
        }
        return null;
      case 'delete_message':
        if (args['for_everyone'] == false) {
          _msgs[args['conv']]?.removeWhere((m) => m['id'] == args['msg_id']);
          return null;
        }
        final m = _find(args['conv'], args['msg_id']);
        if (m != null) {
          m['deleted'] = true;
          m['body'] = '';
          _emit('message_update', {'conv': args['conv'], 'id': args['msg_id'], 'deleted': true, 'body': ''});
        }
        return null;
      case 'react':
        final m = _find(args['conv'], args['msg_id']);
        if (m != null) {
          final r = (m['reactions'] as Map).cast<String, List<String>>();
          final e = args['emoji'] as String;
          final l = List<String>.of(r[e] ?? const []);
          l.remove(myPeer);
          if (args['on'] == true) l.add(myPeer);
          if (l.isEmpty) {
            r.remove(e);
          } else {
            r[e] = l;
          }
          m['reactions'] = r;
          _emit('message_update', {'conv': args['conv'], 'id': args['msg_id'], 'reactions': r});
        }
        return null;
      case 'mark_read':
        final c = _convs[args['conv']];
        if (c != null && c['unread'] != 0) {
          c['unread'] = 0;
          _emit('conversation', Map.of(c));
        }
        return null;
      case 'typing':
        return null;
      case 'profile':
        if (_profile['cover'] == null) {
          final data = await rootBundle.load('assets/mock/dalat.jpg');
          _profile['cover'] = base64Encode(data.buffer.asUint8List());
        }
        return Map.of(_profile);
      case 'set_profile':
        for (final k in ['name', 'bio', 'status', 'avatar']) {
          if (args.containsKey(k)) _profile[k] = args[k];
        }
        if (args['name'] is String) _me['name'] = args['name'];
        return null;
      case 'set_cover':
        _profile['cover'] = args['cover'];
        return null;
      case 'contact_cover':
        final idx = _contacts.keys.toList().indexOf(args['peer'] as String);
        if (idx < 0 || idx > 7) return {'cover': null};
        final key = const ['city', 'dalat', 'beach', 'dalat', 'coffee', 'beach', 'city', 'coffee'][idx];
        final data = await rootBundle.load('assets/mock/$key.jpg');
        return {'cover': base64Encode(data.buffer.asUint8List())};
      case 'contact_avatar':
        return {'avatar': _avatars[args['peer']]};
      case 'send_message':
        final conv = args['conv'] as String;
        final m = _mkMsg(conv, myPeer, args['text'] as String, _now, mine: true, status: 1);
        m['reply_to'] = args['reply_to'];
        if (args['ttl_ms'] != null) m['expires'] = _now + (args['ttl_ms'] as int);
        m['meta'] = {
          if (args['mentions'] != null) 'mentions': args['mentions'],
          if (args['mention_all'] == true) 'mention_all': true,
          if (args['silent'] == true) 'silent': true,
        };
        if (args['silent'] == true) m['silent'] = true;
        _msgs.putIfAbsent(conv, () => []).add(m);
        final c = _convs[conv];
        if (c != null) {
          c['last_ts'] = m['ts'];
          c['last_mine'] = m['mine'] == true;
          c['last_text'] = _preview(m);
          _emit('conversation', Map.of(c));
        }
        if (conv != 's:me') _simulateReply(conv, m);
        return Map.of(m);
      case 'forward_message':
        final src = _findAny(args['msg_id'] as String);
        if (src == null) throw ApiException('Không tìm thấy tin nhắn', cmd: cmd);
        _copyTo(args['to_conv'] as String, src, meta: {'forwarded_from': src['author']});
        return null;
      case 'pin_message':
        final m = _find(args['conv'], args['msg_id']);
        if (m != null) {
          m['pinned'] = args['on'] == true;
          _emit('message_update', {'conv': args['conv'], 'id': m['id'], 'pinned': m['pinned']});
        }
        return null;
      case 'pinned_messages':
        return (_msgs[args['conv']] ?? const []).where((m) => m['pinned'] == true).map((m) => Map.of(m)).toList();
      case 'send_poll':
        final conv = args['conv'] as String;
        final poll = {'question': args['question'], 'options': args['options']};
        final m = _mkMsg(conv, myPeer, jsonEncode(poll), _now, mine: true, status: 1, kind: 'poll');
        m['meta'] = {'poll': poll};
        m['reactions'] = {'__votes': <String, int>{}};
        _msgs.putIfAbsent(conv, () => []).add(m);
        return Map.of(m);
      case 'vote':
        final m = _find(args['conv'], args['msg_id']);
        if (m != null) {
          final r = Map<String, dynamic>.of((m['reactions'] as Map).cast<String, dynamic>());
          final votes = Map<String, dynamic>.of(((r['__votes'] as Map?) ?? {}).cast<String, dynamic>());
          if (args['option'] == null || args['option'] == -1) {
            votes.remove(myPeer);
          } else {
            votes[myPeer] = args['option'];
          }
          r['__votes'] = votes;
          m['reactions'] = r;
          _emit('message_update', {'conv': args['conv'], 'id': m['id'], 'reactions': r});
        }
        return null;
      case 'send_checklist':
        final conv = args['conv'] as String;
        final items = [for (final t in (args['items'] as List? ?? const [])) t.toString().trim()].where((t) => t.isNotEmpty).toList();
        if ((args['title']?.toString().trim() ?? '').isEmpty) throw ApiException('Hãy đặt tên cho danh sách', cmd: cmd);
        if (items.isEmpty) throw ApiException('Danh sách cần ít nhất một việc', cmd: cmd);
        final m = _mkMsg(conv, myPeer, '', _now, mine: true, status: 1, kind: 'checklist');
        m['body'] = {'title': args['title'].toString().trim(), 'items': [for (var i = 0; i < items.length; i++) {'id': i, 'text': items[i]}]};
        m['reactions'] = <String, dynamic>{'__checks': <String, dynamic>{}};
        if (args['silent'] == true) m['silent'] = true;
        _addOwn(conv, m);
        _simulateTick(conv, m);
        return Map.of(m);
      case 'checklist_toggle':
        final m = _find(args['conv'], args['msg_id']);
        if (m != null) _tick(args['conv'] as String, m, (args['item'] as num).toInt(), args['done'] == true, myPeer);
        return null;
      case 'checklist_add':
        final m = _find(args['conv'], args['msg_id']);
        if (m == null) throw ApiException('Không tìm thấy tin nhắn', cmd: cmd);
        if (m['mine'] != true) throw ApiException('Chỉ người tạo danh sách mới thêm được việc', cmd: cmd);
        final body = Map<String, dynamic>.of((m['body'] as Map).cast<String, dynamic>());
        final list = List<dynamic>.of(body['items'] as List);
        var next = list.fold<int>(0, (a, e) => math.max(a, ((e as Map)['id'] as num).toInt() + 1));
        for (final t in (args['items'] as List? ?? const [])) {
          if (t.toString().trim().isNotEmpty) list.add({'id': next++, 'text': t.toString().trim()});
        }
        body['items'] = list;
        m['body'] = body;
        _emit('message_update', {'conv': args['conv'], 'id': m['id'], 'body': body});
        return null;
      case 'send_reminder':
        final conv = args['conv'] as String;
        final at = (args['at_ms'] as num).toInt();
        if ((args['title']?.toString().trim() ?? '').isEmpty) throw ApiException('Hãy đặt tên cho nhắc hẹn', cmd: cmd);
        if (at < _now - 60000) throw ApiException('Thời gian nhắc đã qua, hãy chọn lại', cmd: cmd);
        final m = _mkMsg(conv, myPeer, '', _now, mine: true, status: 1, kind: 'reminder');
        m['body'] = {'title': args['title'].toString().trim(), 'at_ms': at, 'note': args['note']?.toString() ?? ''};
        m['reactions'] = <String, dynamic>{};
        if (args['silent'] == true) m['silent'] = true;
        _addOwn(conv, m);
        _armReminder(conv, m);
        // Someone in the chat glances at it.
        final r = _responder(conv);
        if (r != null) _later(const Duration(seconds: 3), () => _seen(conv, m, r));
        return Map.of(m);
      case 'reminder_cancel':
        final m = _find(args['conv'], args['msg_id']);
        if (m == null) throw ApiException('Không tìm thấy tin nhắn', cmd: cmd);
        if (m['mine'] != true) throw ApiException('Chỉ người tạo nhắc hẹn mới huỷ được', cmd: cmd);
        final r = Map<String, dynamic>.of((m['reactions'] as Map).cast<String, dynamic>());
        r['__cancelled'] = {'by': myPeer, 'at': _now};
        m['reactions'] = r;
        _emit('message_update', {'conv': args['conv'], 'id': m['id'], 'reactions': r});
        return null;
      case 'reminder_seen':
        final m = _find(args['conv'], args['msg_id']);
        if (m != null) _seen(args['conv'] as String, m, myPeer);
        return null;
      case 'remote_wake':
        final e = _recentRemote.where((x) => x['peer'] == args['peer']).firstOrNull;
        final macs = e?['macs'];
        if (macs is! List || macs.isEmpty) {
          throw ApiException('Chưa có thông tin để đánh thức máy này. Hãy kết nối tới máy một lần khi nó đang bật.', cmd: cmd);
        }
        return {'sent': macs.length * 2, 'helpers': 1};
      case 'schedule_message':
        final id = 'sch_${_hex(6)}';
        _scheduled[id] = {'sched_id': id, 'conv': args['conv'], 'text': args['text'], 'at': args['at']};
        final delay = (args['at'] as int) - _now;
        if (delay < 6 * 3600000) {
          _later(Duration(milliseconds: delay.clamp(0, 1 << 31)), () {
            final sc = _scheduled.remove(id);
            if (sc != null) {
              final m = _mkMsg(sc['conv'] as String, myPeer, sc['text'] as String, _now, mine: true, status: 1);
              _msgs.putIfAbsent(sc['conv'] as String, () => []).add(m);
              _emit('message', Map.of(m));
            }
          });
        }
        return {'sched_id': id};
      case 'scheduled_messages':
        return _scheduled.values.map((e) => Map.of(e)).toList();
      case 'cancel_scheduled':
        _scheduled.remove(args['sched_id']);
        return null;
      case 'group_channel':
        final g = _groups[args['gid']];
        if (g == null) throw ApiException('Không tìm thấy nhóm', cmd: cmd);
        final chans = (g['channels'] as List?) ?? [];
        if (args['remove'] == true) {
          chans.removeWhere((c) => c['name'] == args['name']);
        } else {
          chans.add({'id': _hex(8), 'name': args['name'], 'kind': args['voice'] == true ? 'voice' : 'text', 'conv': 'g:${args['gid']}#${args['name']}', 'participants': []});
        }
        g['channels'] = chans;
        _emit('group', g);
        return null;
      case 'create_invite':
        final link = 'lumora://join/${_hex(24)}';
        _invites[link] = args['gid'] as String;
        return {'link': link, 'expires': _now + ((args['hours'] as int?) ?? 24) * 3600000};
      case 'inspect_invite':
        final link = (args['link'] as String).trim();
        final gid = _invites[link];
        if (gid != null) return {'name': _groups[gid]?['name'] ?? '', 'valid': true, 'already_member': true, 'members': (_groups[gid]?['members'] as List?)?.length ?? 0};
        if (link.startsWith('lumora://join/') && link.length > 20) {
          final g = _inviteGid(link);
          return {'gid': g, 'name': 'Cộng đồng Rust Việt Nam', 'valid': true, 'already_member': false, 'members': 2150, 'kind': 1, 'blocked': _groupBlocked(g)};
        }
        return {'name': '', 'valid': false, 'already_member': false};
      case 'join_invite':
        final link = (args['link'] as String).trim();
        if (!link.startsWith('lumora://join/')) throw ApiException('Liên kết mời không hợp lệ', cmd: cmd);
        if (_groupBlocked(_invites[link] ?? _inviteGid(link))) {
          throw ApiException('Bạn đã chặn nhóm này. Hãy bỏ chặn trong Cài đặt › Quyền riêng tư để tham gia lại.', cmd: cmd, code: 'err.group_blocked');
        }
        final gid = _inviteGid(link);
        _groups[gid] = {'gid': gid, 'name': 'Cộng đồng Rust Việt Nam', 'owner': _friend(2), 'epoch': 1, 'my_role': 'member', 'kind': 1,
          'members': [{'peer': myPeer, 'name': _me['name'], 'role': 'member'}]};
        final conv = 'g:$gid';
        _msgs[conv] = [];
        _convs[conv] = {'id': conv, 'kind': 1, 'community': true, 'title': 'Cộng đồng Rust Việt Nam', 'last_ts': _now, 'unread': 0, 'muted': false, 'pinned': false, 'last_text': ''};
        _spaces.add({'id': gid, 'name': 'Cộng đồng Rust Việt Nam', 'members': 2150, 'channels': [
          {'id': 'c1', 'name': 'chung', 'kind': 'text', 'conv': conv, 'participants': [], 'unread': 0, 'category': ''},
          {'id': 'c2', 'name': 'Voice', 'kind': 'voice', 'conv': '$conv#voice', 'participants': [], 'unread': 0, 'category': ''},
        ]});
        _emit('conversation', Map.of(_convs[conv]!));
        return {'conv': conv, 'gid': gid};
      case 'remote_display':
        return null;
      case 'remote_clipboard':
        // Echo the text back as the partner's `clipboard` event so two-way
        // copy & paste can be exercised without a second device.
        final text = args['text'] as String? ?? '';
        clipboardSent.add(text);
        final peer = _remoteSessions[args['session']]?['peer'];
        if (peer != null) _emit('clipboard', {'peer': peer, 'text': text});
        return null;
      case 'remote_trust':
        args['trusted'] == true ? _trusted.add(args['peer'] as String) : _trusted.remove(args['peer']);
        return null;
      case 'settings_set':
        for (final k in _coreSettings.keys.toList()) {
          if (args.containsKey(k)) _coreSettings[k] = args[k];
        }
        return null;
      case 'settings_get':
        return Map.of(_coreSettings);
      case 'phrase_check':
        final key = phraseSecretKey('${args['phrase']}');
        return {'matches': key != null && key == phraseSecretKey(_restoredPhrase ?? kMockRecoveryPhrase)};
      case 'check_passphrase':
        if (_passphrase.isNotEmpty && args['passphrase'] != _passphrase) {
          throw ApiException('Sai mật khẩu', cmd: cmd, code: 'err.wrong_passphrase');
        }
        return {'ok': true};
      case 'ui_secret_get':
        final k = args['key'] as String;
        if (!k.startsWith('ui.')) throw ApiException('bad key', cmd: cmd);
        return _uiSecrets[k];
      case 'ui_secret_set':
        final k = args['key'] as String;
        final v = args['value'] as String?;
        if (!k.startsWith('ui.')) throw ApiException('bad key', cmd: cmd);
        if (v != null && v.length > 4096) throw ApiException('value too large', cmd: cmd);
        v == null ? _uiSecrets.remove(k) : _uiSecrets[k] = v;
        return null;
      // ------------------------------------------------------------ phase 3
      case 'set_username':
        final u = (args['username'] as String).toLowerCase();
        if (!RegExp(r'^[a-z][a-z0-9_]{3,31}$').hasMatch(u)) throw ApiException('Tên người dùng 4–32 ký tự: chữ thường, số, dấu _', cmd: cmd);
        _me['username'] = u;
        _me['handle'] = '@$u·${_hex(6)}';
        return {'username': u, 'handle': _me['handle']};
      case 'resolve_username':
        final h = (args['handle'] as String).replaceAll('@', '').split('·').first.toLowerCase();
        return [
          for (final c in _contacts.values)
            if ((c['username'] as String? ?? '').startsWith(h) && h.isNotEmpty) {'peer': c['peer'], 'name': c['name'], 'handle': c['handle'], 'contact': c['status'] == 3},
          if (h.startsWith('lan')) {'peer': _peerId('lan_hoang'), 'name': 'Lan Hoàng', 'handle': '@lanhoang·8fk2ma', 'contact': false},
        ];
      case 'search_groups':
        final q = (args['q'] as String).toLowerCase();
        final d = _directoryGroups;
        return [
          if ('flutter việt nam'.contains(q) || q.contains('flutter')) d[0],
          if ('rust'.contains(q) || q.contains('rust')) d[1],
        ].where((g) => !_groupBlocked(g['gid'] as String)).map(Map<String, dynamic>.of).toList();
      case 'join_public':
        if (_groupBlocked(args['gid'] as String)) throw ApiException('Bạn đã chặn nhóm này. Hãy bỏ chặn trong Cài đặt › Quyền riêng tư để tham gia lại.', cmd: cmd, code: 'err.group_blocked');
        return {'pending': true};
      case 'group_visibility':
        final g = _groups[args['gid']]!;
        g['handle'] = args['public'] == true ? '@${args['handle']}·${_hex(6)}' : null;
        return Map.of(g);
      case 'group_settings':
        final g = _groups[args['gid']]!;
        if (args.containsKey('slow_mode_s')) g['slow_mode_s'] = args['slow_mode_s'];
        if (args.containsKey('admins_only')) g['admins_only'] = args['admins_only'];
        return null;
      case 'group_ban':
        final g = _groups[args['gid']]!;
        final banned = List.of((g['banned'] as List?) ?? []);
        if (args['ban'] == true) {
          banned.add(args['peer']);
          (g['members'] as List).removeWhere((m) => m['peer'] == args['peer']);
        } else {
          banned.remove(args['peer']);
        }
        g['banned'] = banned;
        return null;
      case 'group_report':
        final gid = args['gid'] as String;
        final g = _groups[gid];
        if (g == null) throw ApiException('Không tìm thấy nhóm', cmd: cmd, code: 'err.group_not_found');
        if (!const ['spam', 'harassment', 'adult', 'other'].contains(args['reason'])) throw ApiException('Hãy chọn một lý do.', cmd: cmd, code: 'err.report_reason');
        var target = args['peer'] as String?;
        final mid = args['msg_id'] as String?;
        if (mid != null) target = _find('g:$gid', mid)?['author'] as String? ?? target;
        if (target == null || target == myPeer) throw ApiException('Không thể báo cáo nội dung này.', cmd: cmd, code: 'err.report_target');
        final admins = (g['members'] as List).cast<Map>().where((m) => (m['role'] == 'owner' || m['role'] == 'admin') && m['peer'] != myPeer && m['peer'] != target).length;
        if (admins == 0) throw ApiException('Nhóm này không có quản trị viên nào khác để nhận báo cáo.', cmd: cmd, code: 'err.report_no_admins');
        sentReports.add(Map.of(args));
        if (args['hide'] == true && !_hiddenMembers.contains(target)) _hiddenMembers.add(target);
        return {'id': _hex(32), 'sent_to': admins};
      case 'group_reports':
        return [for (final r in _reports) Map.of(r)];
      case 'group_report_done':
        final ids = [...((args['ids'] as List?) ?? const []).map((e) => '$e'), if (args['id'] != null) '${args['id']}'];
        _reportsDone.addAll(ids);
        _reports.removeWhere((r) => ids.contains(r['id']));
        _emit('group_report_handled', {'ids': ids});
        return null;
      case 'group_block':
        final gid = args['gid'] as String;
        if (!_groupBlocked(gid)) {
          _blockedGroups.add({'gid': gid, 'name': _groups[gid]?['name'] ?? args['name'] ?? '', 'at': _now});
        }
        _forgetGroup(gid);
        _emit('settings', {'key': 'privacy.blocked_groups'});
        return [for (final b in _blockedGroups) Map.of(b)];
      case 'group_unblock':
        _blockedGroups.removeWhere((b) => b['gid'] == args['gid']);
        _emit('settings', {'key': 'privacy.blocked_groups'});
        return [for (final b in _blockedGroups) Map.of(b)];
      case 'blocked_groups':
        return [for (final b in _blockedGroups) Map.of(b)];
      case 'hidden_members':
        return List.of(_hiddenMembers);
      case 'set_member_hidden':
        final p = args['peer'] as String;
        _hiddenMembers.remove(p);
        if (args['hidden'] != false) _hiddenMembers.add(p);
        _emit('settings', {'key': 'privacy.hidden_members'});
        return List.of(_hiddenMembers);
      case 'group_purge_member':
        _msgs['g:${args['gid']}']?.removeWhere((m) => m['author'] == args['peer']);
        return null;
      case 'group_clear_history':
        _msgs['g:${args['gid']}']?.clear();
        return null;
      case 'seen_by':
        return [for (final p in _contacts.values.where((c) => c['status'] == 3).take(3)) {'peer': p['peer'], 'ts': _now - 120000}];
      case 'mute':
        final c = _convs[args['conv']];
        final until = (args['until'] as int?) ?? 0;
        if (c != null) {
          c['muted'] = until > 0;
          c['mute_until'] = until;
          _emit('conversation', Map.of(c));
        }
        return {'muted': until > 0, 'until': until};
      case 'clear_history':
        _msgs[args['conv']]?.clear();
        return null;
      case 'remote_recent':
        return _recentRemote.map((e) => Map.of(e)).toList();
      case 'remote_recent_remove':
        if (args['peer'] == null) {
          _recentRemote.clear();
        } else {
          _recentRemote.removeWhere((e) => e['peer'] == args['peer']);
        }
        return null;
      case 'remote_power':
        return null;
      case 'remote_allow_power':
        _remote['allow_power'] = args['allow'] == true;
        return null;
      case 'sticker_packs':
        return _packs.map((p) => {...p, 'stickers': List.of(p['stickers'] as List)}).toList();
      case 'sticker_pack_create':
        final id = 'pk_${_hex(6)}';
        _packs.add({'id': id, 'name': args['name'], 'created': _now, 'stickers': []});
        return {'id': id, 'name': args['name']};
      case 'sticker_pack_delete':
        _packs.removeWhere((p) => p['id'] == args['pack']);
        return null;
      case 'sticker_add':
        final pk = _packs.firstWhere((p) => p['id'] == args['pack']);
        final h = 'file:${args['path']}';
        (pk['stickers'] as List).add({'hash': h, 'emoji': args['emoji'] ?? '', 'mime': 'image/png', 'animated': (args['path'] as String).endsWith('.gif')});
        return {'hash': h, 'mime': 'image/png', 'animated': false};
      case 'sticker_remove':
        for (final p in _packs) {
          if (p['id'] == args['pack']) (p['stickers'] as List).removeWhere((s) => s['hash'] == args['hash']);
        }
        return null;
      case 'sticker_save':
        final pk = _packs.firstWhere((p) => p['id'] == args['pack'], orElse: () => _packs.first);
        (pk['stickers'] as List).add({'hash': args['hash'], 'emoji': '', 'mime': 'image/jpeg', 'animated': false});
        return null;
      case 'sticker_get':
        final h = args['hash'] as String;
        if (h.startsWith('file:')) return {'mime': 'image/png', 'data': base64Encode(await File(h.substring(5)).readAsBytes())};
        final key = h.startsWith('st_') ? h.substring(3) : 'coffee';
        final data = await rootBundle.load('assets/mock/$key.jpg');
        return {'mime': 'image/jpeg', 'data': base64Encode(data.buffer.asUint8List())};
      case 'send_sticker':
        final conv = args['conv'] as String;
        final m = _mkMsg(conv, myPeer, '', _now, mine: true, status: 1, kind: 'sticker');
        m['body'] = {'hash': args['hash'], 'emoji': '', 'mime': 'image/jpeg', 'pack': 'custom', 'animated': false};
        _msgs.putIfAbsent(conv, () => []).add(m);
        return Map.of(m);
      case 'sticker_pack_export':
      case 'sticker_pack_import':
        return null;
      case 'press_button':
        final src = _findAny(args['msg_id'] as String);
        if (src != null) {
          final conv = src['conv'] as String;
          final reply = _mkMsg(conv, src['author'] as String, switch (args['data']) {
            'city:hcm' => '☀️ **TP.HCM**: 27–34°C, nắng nóng, chỉ số UV cao.',
            'city:dn' => '⛅ **Đà Nẵng**: 25–30°C, gió nhẹ.',
            _ => '📅 Cả tuần: nắng xen kẽ mưa rào vào chiều thứ 5.',
          }, _now);
          _later(const Duration(milliseconds: 600), () {
            _msgs[conv]!.add(reply);
            _emit('message', Map.of(reply));
          });
        }
        return null;
      case 'group_add_bot':
        final g = _groups[args['gid']]!;
        final peer = _contacts.values.firstWhere((c) => c['bot'] != null, orElse: () => _contacts.values.first)['peer'];
        g['bots'] = [...((g['bots'] as List?) ?? []), {'peer': peer, 'read_all': args['read_all'] == true}];
        return {'peer': peer};
      case 'group_bot_policy':
        final g = _groups[args['gid']]!;
        g['bots'] = [for (final b in (g['bots'] as List? ?? [])) b['peer'] == args['peer'] ? {...b, 'read_all': args['read_all']} : b];
        return null;
      case 'bot_create':
        final u = (args['username'] as String).toLowerCase().replaceAll('@', '');
        if (!u.endsWith('bot')) throw ApiException('Tên người dùng của bot phải kết thúc bằng "bot"', cmd: cmd);
        if (_bots.containsKey(u)) throw ApiException('Tên này đã được dùng', cmd: cmd);
        final b = {'username': u, 'name': args['name'], 'handle': '@$u·${_hex(6)}', 'peer': _peerId(u), 'short_id': _shortId(u.length + 50), 'created': _now, 'token': 'lumora_bot_${_hex(56)}'};
        _bots[u] = b;
        return Map.of(b);
      case 'locked_chats_get':
        return {'chats': List.of(_lockedChats ?? const <String>[]), 'set': _lockedChats != null};
      case 'locked_chats_set':
        final l = <String>[];
        for (final c in (args['chats'] as List)) {
          final v = '$c'.trim();
          if (v.isEmpty) throw ApiException('bad conversation id', cmd: cmd);
          if (!l.contains(v)) l.add(v);
        }
        _lockedChats = l;
        return {'chats': List.of(l)};
      case 'botfather_history':
        return {'entries': [for (final e in _botfatherChat) Map.of(e)]};
      case 'botfather_append':
        for (final e in (args['entries'] as List).whereType<Map>()) {
          final text = '${e['text'] ?? ''}'.replaceAll(RegExp(r'lumora_bot_[a-z0-9]+'), 'lumora_bot_…');
          final kind = '${e['kind'] ?? ''}';
          if (text.isEmpty && kind.isEmpty) continue;
          _botfatherChat.add({'mine': e['mine'] == true, 'text': text, 'ts': e['ts'] ?? _now, if (kind.isNotEmpty) 'kind': kind, if (e['u'] != null) 'u': '${e['u']}'});
        }
        if (_botfatherChat.length > 200) _botfatherChat.removeRange(0, _botfatherChat.length - 200);
        return {'entries': [for (final e in _botfatherChat) Map.of(e)]};
      case 'botfather_clear':
        _botfatherChat.clear();
        return null;
      case 'bot_list':
        return [for (final b in _bots.values) Map.of(b)..remove('token')];
      case 'bot_token':
        return {'token': _bots[args['username']]?['token']};
      case 'bot_revoke':
        final b = _bots[args['username']]!;
        b['token'] = 'lumora_bot_${_hex(56)}';
        return Map.of(b);
      case 'bot_delete':
        _bots.remove(args['username']);
        return null;
      case 'send_location':
        final conv = args['conv'] as String;
        final live = (args['live_minutes'] as int?) ?? 0;
        final m = _mkMsg(conv, myPeer, '', _now, mine: true, status: 1, kind: 'location');
        m['body'] = {'lat': args['lat'], 'lon': args['lon'], 'accuracy_m': args['accuracy_m'] ?? 0, 'label': args['label'] ?? '',
          'live_until': live > 0 ? _now + live * 60000 : 0, 'updated': _now};
        _msgs.putIfAbsent(conv, () => []).add(m);
        return Map.of(m);
      case 'update_live_location':
        final m = _find(args['conv'], args['msg_id']);
        if (m != null) {
          final b = Map<String, dynamic>.of((m['body'] as Map).cast<String, dynamic>());
          b['lat'] = args['lat'];
          b['lon'] = args['lon'];
          b['updated'] = _now;
          if (args['stop'] == true) {
            b['stopped'] = true;
            b['live_until'] = _now;
          }
          m['body'] = b;
          _emit('message_update', {'conv': args['conv'], 'id': m['id'], 'body': jsonEncode(b)});
        }
        return null;
      case 'send_voice':
        final conv = args['conv'] as String;
        final id = 'voice_${_hex(6)}';
        _files[id] = {'id': id, 'conv': conv, 'peer': '', 'name': 'voice.m4a', 'size': 30000, 'hash': _hex(64), 'path': args['path'], 'direction': 0, 'state': 2, 'progress': 30000, 'created': _now};
        final m = _mkMsg(conv, myPeer, '', _now, mine: true, status: 1, kind: 'voice');
        m['body'] = {'file_id': id, 'name': 'voice.m4a', 'size': 30000, 'mime': 'audio/mp4', 'duration_ms': args['duration_ms'], 'wave': args['wave']};
        m['file'] = {'state': 2, 'progress': 30000, 'size': 30000, 'path': args['path'], 'direction': 0};
        _msgs.putIfAbsent(conv, () => []).add(m);
        return Map.of(m);
      case 'send_contact':
        final conv = args['conv'] as String;
        final c = _contacts[args['peer']];
        final m = _mkMsg(conv, myPeer, '', _now, mine: true, status: 1, kind: 'contact');
        m['body'] = {'peer': args['peer'], 'short_id': c?['short_id'] ?? '', 'name': c?['name'] ?? ''};
        _msgs.putIfAbsent(conv, () => []).add(m);
        return Map.of(m);
      case 'post_story':
        final id = 'st_${_hex(6)}';
        _stories.insert(0, {'id': id, 'author': myPeer, 'created': _now, 'text': args['text'] ?? '', 'has_image': args['image_path'] != null, 'bg': args['bg'] ?? 'aurora', 'seen': true, 'views': 0, 'image_path': args['image_path']});
        _emit('story', Map.of(_stories.first));
        return {'id': id};
      case 'stories':
        return _stories.map((e) => Map.of(e)..remove('image_path')).toList();
      case 'story_image':
        final st = _stories.firstWhere((e) => e['id'] == args['story_id'], orElse: () => {});
        if (st['image_path'] is String) {
          try {
            return {'image': base64Encode(await File(st['image_path'] as String).readAsBytes())};
          } catch (_) {}
        }
        final key = st['id'] == 'st_1' ? 'dalat' : 'coffee';
        final data = await rootBundle.load('assets/mock/$key.jpg');
        return {'image': base64Encode(data.buffer.asUint8List())};
      case 'story_seen':
        for (final st in _stories) {
          if (st['id'] == args['story_id']) st['seen'] = true;
        }
        return null;
      case 'story_viewers':
        return [for (final p in _contacts.values.where((c) => c['status'] == 3).take(4)) {'peer': p['peer'], 'name': p['name'], 'ts': _now - 600000}];
      case 'remote_quality':
        return null;
      case 'set_wallpaper':
        _wallpapers[args['conv'] as String] = args['wallpaper'] as String?;
        return null;
      case 'get_wallpaper':
        return {'wallpaper': _wallpapers[args['conv']]};
      case 'group_meta':
        final g = _groups[args['gid']];
        if (g == null) throw ApiException('Không tìm thấy nhóm', cmd: cmd);
        if (args['description'] != null) g['description'] = args['description'];
        if (args['avatar'] != null) {
          _groupAvatars[args['gid'] as String] = args['avatar'] as String;
          g['has_avatar'] = true;
        }
        _emit('group', g);
        return null;
      case 'group_avatar':
        return {'avatar': _groupAvatars[args['gid']]};
      case 'change_passphrase':
        if (_passphrase.isNotEmpty && args['old'] != _passphrase) throw ApiException('Mật khẩu cũ không đúng', cmd: cmd);
        _passphrase = args['new'] as String? ?? '';
        return null;

      case 'set_lang':
        _lang = args['lang'] as String? ?? 'vi';
        return {'lang': _lang};
      case 'set_retention':
        _retention[args['conv'] as String] = args['mode'] as String;
        return null;
      case 'get_retention':
        return {'mode': _retention[args['conv']] ?? 'forever'};
      case 'conv_flag':
        final c = _convs[args['conv']];
        if (c != null) {
          c[args['flag'] as String] = args['value'];
          _emit('conversation', Map.of(c));
        }
        return null;
      case 'delete_conversation':
        _convs.remove(args['conv']);
        _msgs.remove(args['conv']);
        return null;
      case 'search':
        final q = (args['q'] as String).toLowerCase();
        return _msgs.values
            .expand((l) => l)
            .where((m) => m['kind'] == 'text' && m['body'] is String && (m['body'] as String).toLowerCase().contains(q))
            .take(50)
            .map((m) => Map.of(m))
            .toList();
      case 'create_group':
        final gid = _hex(32);
        final conv = 'g:$gid';
        final members = (args['members'] as List).cast<String>();
        _groups[gid] = {
          'gid': gid, 'name': args['name'], 'owner': myPeer, 'epoch': 1, 'my_role': 'owner',
          'members': [
            {'peer': myPeer, 'name': _me['name'], 'role': 'owner'},
            for (final p in members) {'peer': p, 'name': _contacts[p]?['name'] ?? '?', 'role': 'member'},
          ],
        };
        _msgs[conv] = [
          _mkMsg(conv, myPeer, '', _now, kind: 'system')
            ..['body'] = {'code': 'sys.group_created', 'args': {'actor': myPeer, 'name': args['name']}, 'text': 'Group created'},
        ];
        if (args['kind'] == 1) {
          _groups[gid]!['kind'] = 1;
          _groups[gid]!['channels'] = [
            {'id': 'c1', 'name': 'chung', 'kind': 'text', 'conv': conv},
            {'id': 'c2', 'name': 'Phòng thoại', 'kind': 'voice', 'conv': '$conv#voice'},
          ];
          _spaces.add({'id': gid, 'name': args['name'], 'members': members.length + 1, 'channels': [
            {'id': 'c1', 'name': 'chung', 'kind': 'text', 'conv': conv, 'participants': [], 'unread': 0, 'category': ''},
            {'id': 'c2', 'name': 'Phòng thoại', 'kind': 'voice', 'conv': '$conv#voice', 'participants': [], 'unread': 0, 'category': ''},
          ]});
        }
        _convs[conv] = {
          'id': conv, 'kind': 1, 'community': args['kind'] == 1, 'title': args['name'], 'last_ts': _now, 'unread': 0,
          'muted': false, 'pinned': false, 'last_text': '',
        };
        _emit('conversation', Map.of(_convs[conv]!));
        return {'gid': gid, 'conv': conv};
      case 'group_info':
        final g = _groups[args['gid']];
        if (g == null) throw ApiException('Không tìm thấy nhóm', cmd: cmd);
        return {...g, 'members': (g['members'] as List).map((m) => Map.of(m as Map)).toList()};
      case 'group_add':
        final g = _groups[args['gid']]!;
        (g['members'] as List).add({'peer': args['peer'], 'name': _contacts[args['peer']]?['name'] ?? '?', 'role': 'member'});
        g['epoch'] = (g['epoch'] as int) + 1;
        _emit('group', g);
        return null;
      case 'group_remove':
        final g = _groups[args['gid']]!;
        (g['members'] as List).removeWhere((m) => m['peer'] == args['peer']);
        g['epoch'] = (g['epoch'] as int) + 1;
        _emit('group', g);
        return null;
      case 'group_set_role':
        final g = _groups[args['gid']]!;
        for (final m in g['members'] as List) {
          if (m['peer'] == args['peer']) m['role'] = args['role'];
        }
        _emit('group', g);
        return null;
      case 'group_rename':
        final g = _groups[args['gid']]!;
        g['name'] = args['name'];
        final c = _convs['g:${args['gid']}'];
        if (c != null) {
          c['title'] = args['name'];
          _emit('conversation', Map.of(c));
        }
        _emit('group', g);
        return null;
      case 'group_leave':
        // like the core: my own Leave deletes the chat
        _groups.remove(args['gid']);
        _convs.remove('g:${args['gid']}');
        _emit('conversation_removed', {'conv': 'g:${args['gid']}'});
        _emit('group_removed', {'gid': args['gid'], 'conv': 'g:${args['gid']}', 'left': true});
        return null;
      case 'spaces':
        return _spaces;
      case 'voice_join':
      case 'voice_leave':
        for (final s in _spaces) {
          for (final c in s['channels'] as List) {
            final parts = (c['participants'] as List).cast<String>();
            parts.remove(myPeer);
            if (cmd == 'voice_join' && c['conv'] == args['conv']) parts.add(myPeer);
            c['participants'] = parts;
          }
        }
        return null;
      case 'send_file':
        final path = args['path'] as String;
        final name = path.split(RegExp(r'[/\\]')).last;
        final id = 'f_${_hex(8)}';
        final conv = args['conv'] as String;
        final size = 2000000 + _rand.nextInt(80000000);
        _files[id] = {
          'id': id, 'conv': conv, 'peer': conv.startsWith('d:') ? conv.substring(2) : '',
          'name': name, 'size': size, 'hash': _hex(64), 'path': path, 'direction': 0, 'state': 1,
          'progress': 0, 'created': _now, 'speed_bps': 6000000,
        };
        final m = _mkMsg(conv, myPeer, '', _now, mine: true, kind: 'file', status: 1);
        m['body'] = {
          'file_id': id, 'name': name, 'size': size,
          // app-made preview, as the core would carry it
          if (args['thumb_b64'] != null) 'thumb': args['thumb_b64'],
          if (args['width'] != null) 'width': args['width'],
          if (args['height'] != null) 'height': args['height'],
          if (args['preview'] != null) 'preview': args['preview'],
        };
        if (args['preview'] != null) _files[id]!['preview'] = args['preview'];
        _msgs.putIfAbsent(conv, () => []).add(m);
        _emit('message', Map.of(m));
        _emit('file', Map.of(_files[id]!));
        return Map.of(_files[id]!);
      case 'accept_file':
        final f = _files[args['file_id']];
        if (f != null) {
          f['state'] = 1;
          f['speed_bps'] = 7000000;
          _emit('file', Map.of(f));
        }
        return null;
      case 'cancel_file':
        final f = _files[args['file_id']];
        if (f != null) {
          f['state'] = 4;
          f['speed_bps'] = null;
          _emit('file', Map.of(f));
        }
        return null;
      case 'pause_file': // UI extension (not in api.md v1)
        final f = _files[args['file_id']];
        if (f != null) {
          f['state'] = f['state'] == 5 ? 1 : 5;
          f['speed_bps'] = f['state'] == 1 ? 5000000 : null;
          _emit('file', Map.of(f));
        }
        return null;
      case 'files':
        return _files.values.map((f) => Map.of(f)).toList();
      case 'call_start':
        final conv = args['conv'] as String;
        final id = 'c_${_hex(8)}';
        List<String> parts;
        if (conv.startsWith('d:')) {
          parts = [conv.substring(2)];
        } else if (conv.contains('#') || _spaces.any((sp) => (sp['channels'] as List).any((c) => c['conv'] == conv && c['kind'] == 'voice'))) {
          parts = [];
          for (final sp in _spaces) {
            for (final c in sp['channels'] as List) {
              if (c['conv'] == conv) parts = (c['participants'] as List).cast<String>().where((p) => p != myPeer).toList();
            }
          }
        } else {
          final g = _groups[conv.substring(2)];
          parts = ((g?['members'] as List?) ?? []).map((m) => m['peer'] as String).where((p) => p != myPeer).take(5).toList();
        }
        final call = {
          'call_id': id, 'conv': conv, 'peer': parts.isEmpty ? '' : parts.first, 'state': 'ringing',
          'video': args['video'] == true, 'participants': parts,
          'streams': {for (var i = 0; i < parts.length; i++) parts[i]: i + 1, myPeer: 0},
        };
        _calls[id] = call;
        _later(const Duration(milliseconds: 50), () => _emit('call', Map.of(call)));
        _later(const Duration(milliseconds: 2200), () {
          if (_calls[id]?['state'] != 'ringing') return;
          call['state'] = 'active';
          call['started_at'] = _now;
          _emit('call', Map.of(call));
          _speakingLoop(id);
          var i = 1;
          for (final p in parts) {
            if (call['video'] == true) _emit('video_stream', {'call_id': id, 'peer': p, 'stream': i});
            i++;
          }
        });
        return {'call_id': id};
      case 'call_answer':
        final call = _calls[args['call_id']];
        if (call != null) {
          call['state'] = args['accept'] == true ? 'active' : 'ended';
          call['started_at'] = _now;
          call['streams'] = {call['peer']: 1, myPeer: 0};
          _emit('call', Map.of(call));
          if (args['accept'] == true) _speakingLoop(args['call_id'] as String);
        }
        return null;
      case 'call_end':
        final call = _calls.remove(args['call_id']);
        if (call != null) _emit('call', {...call, 'state': 'ended'});
        return null;
      case 'call_set':
        return null;
      case 'remote_status':
        return Map.of(_remote);
      case 'remote_set':
        for (final k in ['password', 'unattended', 'allow_control']) {
          if (args.containsKey(k)) _remote[k] = args[k];
        }
        return null;
      case 'remote_connect':
        final pw = args['password'] as String? ?? '';
        final id = (args['target'] as String).replaceAll(' ', '');
        if (id.length < 9) throw ApiException('ID đối tác không hợp lệ', cmd: cmd);
        // an account with several computers: ask which one
        final owner = _contacts.values.where((c) => c['peer'] == id || '${c['short_id']}'.replaceAll(' ', '') == id).firstOrNull;
        if (owner != null && args['device'] == null) {
          final hosts = _contactDevices(owner['peer'] as String).where((d) => (d['caps'] as int) & 2 != 0).toList();
          if (hosts.length > 1) {
            throw ApiException('Tài khoản này có nhiều máy. Hãy chọn máy muốn điều khiển.',
                cmd: cmd,
                code: 'err.choose_device',
                detail: jsonEncode([for (final d in hosts) {'device': d['device'], 'name': d['name'], 'kind': d['kind'], 'short_id': d['short_id']}]));
          }
        }
        final s = 'r_${_hex(8)}';
        final peer = _friend(7);
        _remoteSessions[s] = {'session': s, 'peer': peer, 'role': 'viewer'};
        _later(const Duration(milliseconds: 30), () => _emit('remote_state', {'session': s, 'peer': peer, 'state': 'connecting', 'role': 'viewer', 'width': 0, 'height': 0, 'stream': 0}));
        _later(const Duration(milliseconds: 1400), () {
          if (pw.length < 4) {
            _emit('remote_state', {'session': s, 'peer': peer, 'state': 'denied', 'role': 'viewer'});
          } else {
            _emit('remote_state', {'session': s, 'peer': peer, 'state': 'active', 'role': 'viewer', 'width': 1920, 'height': 1080, 'stream': 100, 'control': args['view_only'] != true});
          }
        });
        return {'session': s};
      case 'remote_respond':
        final s = args['session'] as String;
        final sess = _remoteSessions[s];
        if (sess != null) {
          _emit('remote_state', {
            'session': s, 'peer': sess['peer'],
            'state': args['accept'] == true ? 'active' : 'ended',
            'role': 'host', 'width': 1920, 'height': 1080, 'stream': 0,
          });
        }
        return null;
      case 'remote_input':
        return null;
      case 'remote_end':
        final s = args['session'] as String;
        _remoteSessions.remove(s);
        _emit('remote_state', {'session': s, 'peer': '', 'state': 'ended', 'role': 'viewer'});
        return null;
      case 'diagnostics':
        return _diagnostics();
      case 'video_codec':
        return {
          'os_codec': 'MediaCodec',
          'h264': {'enc': true, 'dec': true, 'enc_hw': true, 'dec_hw': true, 'ms': 120},
          'caps': {'enc': ['h264', 'vp8', 'vp9'], 'dec': ['h264', 'vp8', 'vp9'], 'hw_enc': ['h264'], 'hw_dec': ['h264']},
          'encoder': {'format': 'h264', 'kind': 'media_codec', 'label': 'MediaCodec', 'hardware': true},
          'decoder': {'format': 'vp8', 'kind': 'libvpx', 'label': 'libvpx', 'hardware': false},
          'libvpx': '1.17.0',
        };
      case 'storage_stats':
        _seedMedia();
        final media = _media.values.fold<int>(0, (a, b) => a + b);
        final convs = [
          for (final c in _convs.values)
            {
              'conv': c['id'],
              'title': c['title'],
              'messages': _msgs[c['id']]?.length ?? 0,
              'message_bytes': (_msgs[c['id']]?.length ?? 0) * 2400,
              'media_bytes': _media[c['id']] ?? 0,
            }
        ]..sort((a, b) => (b['media_bytes'] as int).compareTo(a['media_bytes'] as int));
        return {
          ..._stats(),
          'db_bytes': _dbBytes,
          'media_bytes': media,
          // Not in the real core yet: free/total space of the data disk.
          'free_bytes': 870 << 20,
          'disk_bytes': 460 << 30,
          'low_disk': true,
          'policy': Map.of(_policy),
          'by_conv': convs,
        };
      case 'maintain':
        await Future<void>.delayed(const Duration(milliseconds: 600));
        _dbBytes -= _dbSlack;
        _dbSlack = 0;
        return _stats();
      case 'storage_policy':
        return Map.of(_policy);
      case 'set_storage_policy':
        _policy = {..._policy, for (final k in _policy.keys) if (args[k] is int) k: args[k] as int};
        return Map.of(_policy);
      case 'clear_media':
        _seedMedia();
        final conv = args['conv'] as String? ?? '*';
        var freed = 0, n = 0;
        for (final k in _media.keys.toList()) {
          if (conv != '*' && k != conv) continue;
          freed += _media[k]!;
          if (_media[k]! > 0) n++;
          _media[k] = 0;
        }
        return {'freed_bytes': freed, 'removed_files': n, 'cache_bytes': _media.values.fold<int>(0, (a, b) => a + b)};
      case 'export_backup':
        final pw = args['password'] as String? ?? '';
        if (pw.length < 6) throw ApiException('Mật khẩu sao lưu cần ít nhất 6 ký tự', cmd: cmd);
        if (_passphrase.isNotEmpty && args['passphrase'] != _passphrase) throw ApiException('Mật khẩu không đúng', cmd: cmd);
        final bytes = utf8.encode('LUMORABK1${_backupTag(pw)}');
        await File(args['path'] as String).writeAsBytes(bytes);
        return {'path': args['path'], 'bytes': bytes.length};
    }
    throw ApiException('Lệnh không hỗ trợ (mock): $cmd', cmd: cmd);
  }

  Map<String, dynamic> _stats() => {
        'messages': _msgs.values.fold<int>(0, (a, l) => a + l.length),
        'contacts': _contacts.values.where((c) => c['status'] == 3).length,
        'groups': _groups.length,
        'conversations': _convs.length,
        'files': _files.length,
        'outbox': 3,
      };

  void _seedMedia() {
    if (_media.isNotEmpty) return;
    var i = 0;
    for (final id in _convs.keys) {
      _media[id] = const [612, 284, 141, 77, 38, 12, 4, 0][i % 8] << 20;
      i++;
    }
  }

  /// Mock backup file: magic + a tag derived from the password.
  static String _backupTag(String pw) => sha256.convert(utf8.encode('lumora-mock:$pw')).toString();

  void _checkBackup(String path, String pw) {
    final f = File(path);
    if (!f.existsSync()) throw ApiException('Không đọc được tệp', cmd: 'start');
    final s = utf8.decode(f.readAsBytesSync(), allowMalformed: true);
    if (!s.startsWith('LUMORABK1')) throw ApiException('Đây không phải tệp sao lưu Lumora', cmd: 'start');
    if (s.substring(9) != _backupTag(pw)) throw ApiException('Mật khẩu sao lưu không đúng', cmd: 'start');
  }

  Map<String, dynamic>? _find(dynamic conv, dynamic id) {
    for (final m in _msgs[conv] ?? const <Map<String, dynamic>>[]) {
      if (m['id'] == id) return m;
    }
    return null;
  }

  void _speakingLoop(String callId) {
    if (!timers) return;
    late Timer t;
    t = Timer.periodic(const Duration(milliseconds: 900), (_) {
      final call = _calls[callId];
      if (call == null || call['state'] != 'active') {
        t.cancel();
        return;
      }
      final parts = (call['participants'] as List).cast<String>();
      call['speaking'] = parts.where((_) => _rand.nextDouble() < 0.35).toList();
      call['quality'] = _rand.nextDouble() < 0.85 ? 3 : 2;
      _emit('call', Map.of(call));
    });
    _timers.add(t);
  }

  Map<String, dynamic> _net() {
    final online = _contacts.values.where((c) => c['status'] == 3 && c['online'] == true);
    return {
      'nat': 'easy',
      'public_ip': '113.161.72.45',
      'port': 41641,
      'addrs': ['192.168.1.23:41641', '[2402:800:6314::1a2b]:41641', '113.161.72.45:41641'],
      'upnp': true,
      'relays': [
        {'url': 'wss://relay.lumora.vn/ws', 'connected': true},
        {'url': 'wss://relay.getlumora.pages.dev/ws', 'connected': true},
        {'url': 'wss://relay.example.org/ws', 'connected': false},
      ],
      'nostr': [
        {'url': 'wss://relay.damus.io', 'connected': true},
        {'url': 'wss://nos.lol', 'connected': true},
        {'url': 'wss://nostr.wine', 'connected': false},
      ],
      'dht': true,
      'lan_peers': 1,
      'peers': [
        for (final c in online)
          {
            'peer': c['peer'],
            'path': c['path'] ?? 'relay',
            'rtt_ms': switch (c['path']) { 'lan' => 2, 'direct' => 18 + (c['name'] as String).length, _ => 84 },
            'remote_addr': switch (c['path']) { 'lan' => '192.168.1.41:41641', 'direct' => '14.231.${(c['name'] as String).length}.9:5${(c['name'] as String).length}21', _ => 'relay.lumora.vn' },
          },
      ],
    };
  }

  /// A friend's devices: the first friend uses three, every other friend one
  /// or two (stable per friend).
  List<Map<String, dynamic>> _contactDevices(String peer) {
    final c = _contacts[peer];
    final idx = _contacts.keys.toList().indexOf(peer);
    final first = _contacts.values.where((c) => c['status'] == 3).firstOrNull?['peer'] == peer;
    final n = first ? 3 : (peer.codeUnits.fold<int>(0, (a, b) => a + b).isEven ? 2 : 1);
    String safety(String seed) {
      final r = math.Random(seed.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0x7fffffff));
      return List.generate(6, (_) => r.nextInt(100000).toString().padLeft(5, '0')).join(' ');
    }

    final online = c?['online'] == true;
    final all = [
      {'device': peer, 'name': 'Điện thoại', 'kind': 1, 'caps': 5, 'primary': true, 'online': online, 'last_seen': _now - 600000},
      {'device': _peerId('$peer-laptop'), 'name': 'Laptop', 'kind': 3, 'caps': 6, 'primary': false, 'online': first, 'last_seen': _now - 3600000},
      {'device': _peerId('$peer-desktop'), 'name': 'Máy tính ở nhà', 'kind': 3, 'caps': 6, 'primary': false, 'online': false, 'last_seen': _now - 2 * 86400000},
    ];
    return [
      for (final (i, d) in all.take(n).indexed) {...d, 'short_id': _shortId(40 + idx * 3 + i), 'safety': safety('${d['device']}')},
    ];
  }

  Map<String, dynamic> _diagnostics() => {
        'platform': 'linux',
        'session_type': 'wayland',
        'desktop': 'GNOME 48',
        'checks': [
          {'id': 'network', 'ok': true, 'title': 'Kết nối Internet', 'detail': 'Đã kết nối, khả năng kết nối trực tiếp: tốt.', 'fix_steps': []},
          {'id': 'portal_screencast', 'ok': true, 'title': 'Chia sẻ màn hình', 'detail': 'Hệ thống hỗ trợ chia sẻ màn hình.', 'fix_steps': []},
          {'id': 'pipewire', 'ok': true, 'title': 'Âm thanh & hình ảnh', 'detail': 'Dịch vụ âm thanh/hình ảnh đang chạy.', 'fix_steps': []},
          {
            'id': 'portal_remote_desktop',
            'ok': false,
            'title': 'Quyền điều khiển từ xa',
            'detail': 'Hệ thống cần bạn cho phép Lumora xem màn hình và điều khiển chuột/bàn phím.',
            'fix_steps': [
              'Mở Lumora > Truy cập từ xa > nhấn "Cấp quyền" và chọn "Chia sẻ" trong hộp thoại hệ thống.',
              'Đánh dấu "Ghi nhớ lựa chọn" để không phải hỏi lại cho các phiên sau.',
              'Nếu hộp thoại không hiện, khởi động lại portal:\n\$ systemctl --user restart xdg-desktop-portal',
            ],
          },
          {
            'id': 'uinput',
            'ok': false,
            'title': 'Điều khiển khi màn hình bị khoá',
            'detail': 'Cần cấp thêm một quyền để điều khiển được cả khi máy đang khoá.',
            'fix_steps': [
              'Thêm tài khoản vào nhóm input:\n\$ sudo usermod -aG input \$USER',
              'Tạo luật udev:\n\$ echo \'KERNEL=="uinput", GROUP="input", MODE="0660"\' | sudo tee /etc/udev/rules.d/99-lumora-uinput.rules',
              'Nạp lại luật:\n\$ sudo udevadm control --reload-rules && sudo udevadm trigger',
              'Đăng xuất rồi đăng nhập lại.',
            ],
          },
          {'id': 'audio', 'ok': true, 'title': 'Âm thanh', 'detail': 'PulseAudio/PipeWire: 1 camera, 2 micro.', 'fix_steps': []},
          {
            'id': 'udp',
            'ok': false,
            'title': 'Tường lửa đang chặn kết nối',
            'detail': 'Kết nối trực tiếp bị chặn nên có thể phải đi qua cầu nối (chậm hơn).',
            'fix_steps': [
              'Mở cổng bằng ufw:\n\$ sudo ufw allow 41641/udp',
              'Hoặc với firewalld:\n\$ sudo firewall-cmd --add-port=41641/udp --permanent && sudo firewall-cmd --reload',
            ],
          },
        ],
      };

  @override
  Future<void> stop() async {
    for (final t in _timers) {
      t.cancel();
    }
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    _timers.clear();
    await _events.close();
  }
}
