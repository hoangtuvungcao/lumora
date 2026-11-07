// Community 2.0 in the mock core: roles + permissions, channel settings
// (topic, category, order, private, announcement-only) and timeouts.
//
// The state lives in the group maps the mock already keeps:
//   g['roles']    [{id, name, color, perms, position, builtin}]
//   member maps   + 'roles' [custom ids], 'timeout_until' (epoch ms)
//   channel maps  + 'topic', 'category', 'position', 'private', 'allow_roles', 'announce'
// (a community's channels are both in g['channels'] and in its `_spaces`
// entry; changes go to both).
//
// Rules (the Rust core follows the same):
// - owner: every permission; members with role "admin": every permission too
//   (manage_community included), unless a plain group gives them `admin:<peer>` rights;
//   everyone else: @everyone's perms ∪ their custom roles' perms.
// - built-in roles: `everyone` (position 0) and `admin` (always the highest).
//   Custom roles sit between them, positions renumbered 1..n after each change.
// - channel `position` is global across the community (dense 0..n-1), categories
//   show in the order of their first channel, uncategorised channels first.
// - private channel: seen by owner/admins and members holding a role in
//   allow_roles (`everyone` in allow_roles = all). `spaces` and `group_info`
//   list only the channels I can see.
// - announce channel: posting needs manage_messages or a role in allow_roles
//   (owner/admins always).
// - timed-out members can't post or join voice; owner/admins can't be timed
//   out, kicked or banned by non-owners.
//
// Groups 2.0 (pending-v108): ownership transfer (the owner can't leave while
// others remain: `err.owner_must_transfer`), invite links with ids and revoke
// (`err.invite_revoked`), "approve new members" + join requests, re-adding a
// member an admin removed is admin-only (`err.removed_admin_only`), group
// invitations waiting for my answer, and plain group calls that ring only the
// picked members (everyone else gets `call` state "available").
// Mock-only keys in the group map start with `_m` and never leave cmInfo.

part of 'mock_api.dart';

/// "Not mine": [MockCommunity.cmHandle] leaves the command to the main mock.
const Object _cmNo = Object();

extension MockCommunity on MockLumoraApi {
  static const _everyone = 'everyone';
  static const _admin = 'admin';
  static final _revokedX = Expando<Set<String>>();
  static final _pendingX = Expando<List<Map<String, dynamic>>>();

  /// Revoked invite links (any group).
  Set<String> get _cmRevoked => _revokedX[this] ??= <String>{};

  static final _ringX = Expando<List<List<String>>>();

  /// Tests: who each plain-group `call_start` rang, oldest first.
  List<List<String>> get ringLog => _ringX[this] ??= <List<String>>[];

  /// Invitations to groups waiting for my answer (`group_invites`).
  List<Map<String, dynamic>> get _cmPendingInvites => _pendingX[this] ??= <Map<String, dynamic>>[];

  bool _cmIsCommunity(Map g) => g['kind'] == 1;

  List<Map<String, dynamic>> _cmRoles(Map<String, dynamic> g) {
    var roles = (g['roles'] as List?)?.cast<Map<String, dynamic>>();
    if (roles == null) {
      roles = [
        {'id': _admin, 'name': 'Quản trị viên', 'color': kAdminRoleColor, 'perms': List<String>.of(Perm.admin), 'position': 1, 'builtin': true},
        {'id': _everyone, 'name': '@everyone', 'color': kDefaultRoleColor, 'perms': List<String>.of(Perm.everyoneFor(community: _cmIsCommunity(g))), 'position': 0, 'builtin': true},
      ];
      g['roles'] = roles;
    }
    return roles;
  }

  /// Custom roles renumbered 1..n in their current order, admin on top.
  void _cmNormalizeRoles(Map<String, dynamic> g) {
    final roles = _cmRoles(g);
    final custom = roles.where((r) => r['builtin'] != true).toList()..sort((a, b) => (a['position'] as int).compareTo(b['position'] as int));
    for (var i = 0; i < custom.length; i++) {
      custom[i]['position'] = i + 1;
    }
    for (final r in roles) {
      if (r['id'] == _admin) r['position'] = custom.length + 1;
      if (r['id'] == _everyone) r['position'] = 0;
    }
    roles.sort((a, b) => (b['position'] as int).compareTo(a['position'] as int));
  }

  Map<String, dynamic>? _cmMember(Map g, String peer) =>
      (g['members'] as List).cast<Map<String, dynamic>>().where((m) => m['peer'] == peer).firstOrNull;

  /// owner | admin | member | none (mine follows `my_role`, which tests change).
  String _cmRoleOf(Map g, String peer) {
    final m = _cmMember(g, peer);
    if (peer == myPeer && g['my_role'] is String) return g['my_role'] as String;
    return m == null ? 'none' : (m['role'] as String? ?? 'member');
  }

  Set<String> _cmPerms(Map<String, dynamic> g, String peer) {
    final m = _cmMember(g, peer);
    final role = _cmRoleOf(g, peer);
    if (m == null || role == 'none') return {};
    if (role == 'owner') return Perm.all.toSet();
    final mine = {_everyone, ...((m['roles'] as List?) ?? const []).cast<String>()};
    // an admin with a per-admin rights role (`admin:<peer>`) has those rights;
    // admins made before rights existed keep every admin permission
    if (role == 'admin' && !(mine.contains(Perm.adminRoleId(peer)) && _cmRoles(g).any((r) => r['id'] == Perm.adminRoleId(peer)))) {
      return Perm.legacyAdmin(community: _cmIsCommunity(g)).toSet();
    }
    return {
      for (final r in _cmRoles(g))
        if (mine.contains(r['id'])) ...(r['perms'] as List).cast<String>(),
    };
  }

  bool _cmAdminish(Map g, String peer) {
    final r = _cmRoleOf(g, peer);
    return r == 'owner' || r == 'admin';
  }

  bool _cmVisible(Map<String, dynamic> g, Map ch, String peer) {
    if (_cmAdminish(g, peer)) return true;
    if (!_cmPerms(g, peer).contains(Perm.viewChannel)) return false;
    if (ch['private'] != true) return true;
    final allow = ((ch['allow_roles'] as List?) ?? const []).cast<String>();
    final mine = ((_cmMember(g, peer)?['roles'] as List?) ?? const []).cast<String>();
    return allow.contains(_everyone) || mine.any(allow.contains);
  }

  /// Every map describing the community's channel [name] (group + space lists).
  List<Map<String, dynamic>> _cmChannelMaps(String gid, String name) => [
        for (final c in (_groups[gid]?['channels'] as List?) ?? const [])
          if (c['name'] == name) c as Map<String, dynamic>,
        for (final sp in _spaces.where((sp) => sp['id'] == gid))
          for (final c in (sp['channels'] as List))
            if (c['name'] == name) c as Map<String, dynamic>,
      ];

  /// The community's channels in display order: uncategorised first, then each
  /// category in the order of its first channel; inside, by `position`, then
  /// list order. A channel's `position` is its index in this order.
  List<Map<String, dynamic>> _cmSorted(List chans) {
    final list = [for (var i = 0; i < chans.length; i++) (i, chans[i] as Map<String, dynamic>)];
    list.sort((a, b) {
      final pa = a.$2['position'] as int? ?? a.$1, pb = b.$2['position'] as int? ?? b.$1;
      return pa != pb ? pa.compareTo(pb) : a.$1.compareTo(b.$1);
    });
    final byCat = <String, List<Map<String, dynamic>>>{'': []};
    for (final (_, c) in list) {
      (byCat['${c['category'] ?? ''}'.trim()] ??= []).add(c);
    }
    return [for (final l in byCat.values) ...l];
  }

  Map<String, dynamic> _cmChannelJson(Map<String, dynamic> c, int pos) => {
        ...c,
        'topic': c['topic'] ?? '',
        'category': c['category'] ?? '',
        'position': pos,
        'private': c['private'] ?? false,
        'allow_roles': List<String>.of(((c['allow_roles'] as List?) ?? const []).cast<String>()),
        'announce': c['announce'] ?? false,
      };

  /// group_info of a community, with roles, my_perms, member roles/timeouts
  /// and only the channels I can see.
  Map<String, dynamic> cmInfo(Map<String, dynamic> info) {
    final g = _groups[info['gid']];
    if (g == null) return info;
    _cmNormalizeRoles(g);
    final chans = _cmSorted((g['channels'] as List?) ?? const []);
    return {
      for (final e in info.entries)
        if (!e.key.startsWith('_m')) e.key: e.value,
      'approve_joins': g['_mApprove'] == true,
      'join_requests': [for (final r in ((g['_mRequests'] as List?) ?? const [])) Map<String, dynamic>.of(r as Map<String, dynamic>)],
      'roles': [for (final r in _cmRoles(g)) {...r, 'perms': List<String>.of((r['perms'] as List).cast<String>())}],
      'my_perms': (_cmPerms(g, myPeer).toList()..sort((a, b) => Perm.all.indexOf(a).compareTo(Perm.all.indexOf(b)))),
      'bots': [
        for (final b in ((info['bots'] as List?) ?? const []))
          if (b is Map) {...b, 'roles': List<String>.of(((b['roles'] as List?) ?? const []).cast<String>())} else b,
      ],
      'members': [
        for (final m in (info['members'] as List))
          {...(m as Map), 'roles': List<String>.of(((m['roles'] as List?) ?? const []).cast<String>()), 'timeout_until': m['timeout_until'] ?? 0},
      ],
      if (_cmIsCommunity(g))
        'channels': [
          for (var i = 0; i < chans.length; i++)
            if (_cmVisible(g, chans[i], myPeer)) _cmChannelJson(chans[i], i),
        ],
    };
  }

  /// `spaces`: channels I can see, in order, with their settings.
  List<Map<String, dynamic>> cmSpaces(List<Map<String, dynamic>> spaces) => [
        for (final sp in spaces)
          () {
            final g = _groups[sp['id']];
            if (g == null || !_cmIsCommunity(g)) return sp;
            final chans = _cmSorted(sp['channels'] as List);
            return {
              ...sp,
              'channels': [
                for (var i = 0; i < chans.length; i++)
                  if (_cmVisible(g, chans[i], myPeer)) _cmChannelJson(chans[i], i),
              ],
            };
          }(),
      ];

  Map<String, dynamic> _cmGroup(Map<String, dynamic> args, String cmd) {
    final g = _groups[args['gid']];
    if (g == null) throw ApiException('Không tìm thấy nhóm', cmd: cmd, code: 'err.group_not_found');
    return g;
  }

  void _cmNeed(Map<String, dynamic> g, String perm, String cmd) {
    if (!_cmPerms(g, myPeer).contains(perm)) throw ApiException('Bạn không có quyền làm việc này', cmd: cmd, code: 'err.no_permission');
  }

  /// The target may be moderated by me: never the owner; admins only by the owner.
  void _cmCanModerate(Map<String, dynamic> g, String peer, String cmd) {
    final t = _cmMember(g, peer);
    if (t == null) throw ApiException('Không phải thành viên', cmd: cmd, code: 'err.not_member');
    final mine = _cmRoleOf(g, myPeer);
    final theirs = _cmRoleOf(g, peer);
    if (peer == myPeer || theirs == 'owner' || (theirs == 'admin' && mine != 'owner')) {
      throw ApiException('Bạn không có quyền làm việc này', cmd: cmd, code: 'err.no_permission');
    }
  }

  void _cmChanged(Map<String, dynamic> g) {
    _emit('group', cmInfo({'has_cover': false, 'cover_rev': '', ...g, 'members': (g['members'] as List).map((m) => Map.of(m as Map)).toList()}));
  }

  /// The community whose channel conversation is [conv].
  (Map<String, dynamic>, Map<String, dynamic>)? _cmChannelOf(String conv) {
    for (final sp in _spaces) {
      final g = _groups[sp['id']];
      if (g == null || !_cmIsCommunity(g)) continue;
      for (final c in (sp['channels'] as List)) {
        if (c['conv'] == conv) return (g, c as Map<String, dynamic>);
      }
    }
    return null;
  }

  /// Community commands; [_cmNo] for everything else. Also refuses posting
  /// in a channel I may not post in (announcement-only / timed out).
  dynamic cmHandle(String cmd, Map<String, dynamic> args) {
    if (cmd.startsWith('send_') && args['conv'] is String) {
      final conv = args['conv'] as String;
      final hit = _cmChannelOf(conv) ??
          (() {
            final g = conv.startsWith('g:') && !conv.contains('#') ? _groups[conv.substring(2)] : null;
            return g == null || _cmIsCommunity(g) ? null : (g, <String, dynamic>{'conv': conv});
          })();
      if (hit != null) {
        final (g0, _) = hit;
        if (cmd == 'send_file' && !_cmPerms(g0, myPeer).contains(Perm.sendMedia) && _cmMember(g0, myPeer) != null) {
          throw ApiException('Bạn không được gửi ảnh hay tệp ở đây', cmd: cmd, code: 'err.no_permission');
        }
        final (g, ch) = hit;
        final me = _cmMember(g, myPeer);
        if (me != null && !_cmAdminish(g, myPeer)) {
          if (((me['timeout_until'] as int?) ?? 0) > _now) throw ApiException('Bạn đang bị tạm cấm chat', cmd: cmd, code: 'err.timed_out');
          final perms = _cmPerms(g, myPeer);
          final allow = ((ch['allow_roles'] as List?) ?? const []).cast<String>();
          final mine = ((me['roles'] as List?) ?? const []).cast<String>();
          if (!perms.contains(Perm.sendMessages) ||
              (ch['announce'] == true && !perms.contains(Perm.manageMessages) && !allow.contains(_everyone) && !mine.any(allow.contains))) {
            throw ApiException('Chỉ quản trị viên được đăng trong kênh này', cmd: cmd, code: 'err.channel_readonly');
          }
        }
      }
      return _cmNo;
    }
    final g2 = groups2(cmd, args);
    if (!identical(g2, _cmNo)) return g2;
    switch (cmd) {
      case 'group_rename' || 'group_meta':
        // name, avatar, cover, description: `manage_community`
        final g = _groups[args['gid']];
        if (g != null && _cmMember(g, myPeer) != null && !_cmPerms(g, myPeer).contains(Perm.manageCommunity)) {
          throw ApiException('Chỉ quản trị viên được đổi thông tin nhóm', cmd: cmd, code: 'err.admin_only');
        }
        return _cmNo;
      case 'group_roles':
        final g = _cmGroup(args, cmd);
        _cmNormalizeRoles(g);
        return [for (final r in _cmRoles(g)) {...r, 'perms': List<String>.of((r['perms'] as List).cast<String>())}];
      case 'group_role_set':
        final g = _cmGroup(args, cmd);
        _cmNeed(g, Perm.manageRoles, cmd);
        final roles = _cmRoles(g);
        final perms = [for (final p in ((args['perms'] as List?) ?? const []).cast<String>()) if (Perm.all.contains(p)) p];
        var id = args['id'] as String?;
        Map<String, dynamic> role;
        // a plain group's per-admin rights role is created under its fixed id
        final fixed = id != null && id.startsWith('admin:') && !roles.any((r) => r['id'] == id) ? id : null;
        if (fixed != null) id = null;
        if (id == null) {
          final name = (args['name'] as String? ?? '').trim();
          if (name.isEmpty) throw ApiException('Hãy đặt tên vai trò', cmd: cmd, code: 'err.bad_name');
          role = {'id': fixed ?? 'r_${_hex(8)}', 'name': name, 'color': args['color'] ?? kDefaultRoleColor, 'perms': perms, 'position': 0, 'builtin': false};
          // new roles land just above @everyone unless a position is given
          roles.add(role);
        } else {
          role = roles.firstWhere((r) => r['id'] == id, orElse: () => throw ApiException('Không tìm thấy vai trò', cmd: cmd, code: 'err.role_not_found'));
          if (id == _admin) throw ApiException('Không sửa được vai trò này', cmd: cmd, code: 'err.builtin_role');
          if (id == _everyone) {
            // (communities: managing the community is never everyone's)
            role['perms'] = _cmIsCommunity(g) ? perms.where((p) => p != Perm.manageCommunity).toList() : perms;
            _cmChanged(g);
            return {'id': id};
          }
          final name = (args['name'] as String? ?? '').trim();
          if (name.isNotEmpty) role['name'] = name;
          if (args['color'] is String) role['color'] = args['color'];
          role['perms'] = perms;
        }
        final pos = args['position'];
        if (pos is int) {
          final custom = roles.where((r) => r['builtin'] != true && r != role).toList()..sort((a, b) => (a['position'] as int).compareTo(b['position'] as int));
          custom.insert((pos - 1).clamp(0, custom.length), role);
          for (var i = 0; i < custom.length; i++) {
            custom[i]['position'] = i + 1;
          }
        } else if (id == null) {
          for (final r in roles) {
            if (r['builtin'] != true && r != role) r['position'] = (r['position'] as int) + 1;
          }
          role['position'] = 1;
        }
        _cmNormalizeRoles(g);
        _cmChanged(g);
        return {'id': role['id']};
      case 'group_role_delete':
        final g = _cmGroup(args, cmd);
        _cmNeed(g, Perm.manageRoles, cmd);
        final id = args['id'];
        if (id == _admin || id == _everyone) throw ApiException('Không xoá được vai trò mặc định', cmd: cmd, code: 'err.builtin_role');
        _cmRoles(g).removeWhere((r) => r['id'] == id);
        for (final m in (g['members'] as List)) {
          (m['roles'] as List?)?.remove(id);
        }
        for (final c in (g['channels'] as List? ?? const [])) {
          (c['allow_roles'] as List?)?.remove(id);
        }
        _cmNormalizeRoles(g);
        _cmChanged(g);
        return null;
      case 'group_member_roles':
        final g = _cmGroup(args, cmd);
        _cmNeed(g, Perm.manageRoles, cmd);
        // a member, or a bot of the community (`bots[].roles`)
        final m = _cmMember(g, args['peer'] as String) ??
            ((g['bots'] as List?) ?? const []).cast<Map<String, dynamic>>().where((b) => b['peer'] == args['peer']).firstOrNull;
        if (m == null) throw ApiException('Không phải thành viên', cmd: cmd, code: 'err.not_member');
        final known = {for (final r in _cmRoles(g)) if (r['builtin'] != true) r['id']};
        m['roles'] = [for (final r in ((args['roles'] as List?) ?? const []).cast<String>()) if (known.contains(r)) r];
        _cmChanged(g);
        return null;
      case 'group_timeout':
        final g = _cmGroup(args, cmd);
        _cmNeed(g, Perm.timeout, cmd);
        _cmCanModerate(g, args['peer'] as String, cmd);
        _cmMember(g, args['peer'] as String)!['timeout_until'] = (args['until_ms'] as num?)?.toInt() ?? 0;
        _cmChanged(g);
        return null;
      case 'group_channel_update':
        final g = _cmGroup(args, cmd);
        _cmNeed(g, Perm.manageChannels, cmd);
        final gid = args['gid'] as String;
        final name = args['name'] as String;
        final maps = _cmChannelMaps(gid, name);
        if (maps.isEmpty) throw ApiException('Không tìm thấy kênh', cmd: cmd, code: 'err.channel_not_found');
        final newName = (args['new_name'] as String?)?.trim();
        if (newName != null && newName.isNotEmpty && newName != name) {
          if (_cmChannelMaps(gid, newName).isNotEmpty) throw ApiException('Đã có kênh tên này', cmd: cmd, code: 'err.channel_exists');
        }
        for (final c in maps) {
          // the conversation id stays: renaming keeps the history
          if (newName != null && newName.isNotEmpty) c['name'] = newName;
          for (final k in ['topic', 'category', 'private', 'announce']) {
            if (args[k] != null) c[k] = args[k];
          }
          if (args['allow_roles'] is List) c['allow_roles'] = List<String>.of((args['allow_roles'] as List).cast<String>());
        }
        final pos = args['position'];
        if (pos is int) {
          final current = newName != null && newName.isNotEmpty ? newName : name;
          for (final list in [g['channels'] as List?, ...[for (final sp in _spaces.where((sp) => sp['id'] == gid)) sp['channels'] as List]]) {
            if (list == null) continue;
            final sorted = _cmSorted(list);
            final me = sorted.where((c) => c['name'] == current).firstOrNull;
            if (me == null) continue;
            sorted.remove(me);
            sorted.insert(pos.clamp(0, sorted.length), me);
            for (var i = 0; i < sorted.length; i++) {
              sorted[i]['position'] = i;
            }
          }
        }
        _cmChanged(g);
        return null;
      case 'group_channel':
        final g = _groups[args['gid']];
        if (g == null || !_cmIsCommunity(g)) return _cmNo;
        _cmNeed(g, Perm.manageChannels, 'group_channel');
        if (args['remove'] != true && _cmChannelMaps(args['gid'] as String, args['name'] as String).isNotEmpty) {
          throw ApiException('Đã có kênh tên này', cmd: cmd, code: 'err.channel_exists');
        }
        return _cmNo;
      case 'voice_join':
        final hit = _cmChannelOf(args['conv']?.toString() ?? '');
        if (hit != null && !_cmAdminish(hit.$1, myPeer)) {
          final me = _cmMember(hit.$1, myPeer);
          if (me != null && (((me['timeout_until'] as int?) ?? 0) > _now || !_cmPerms(hit.$1, myPeer).contains(Perm.connectVoice))) {
            throw ApiException('Bạn không được vào kênh thoại này', cmd: cmd, code: 'err.no_permission');
          }
        }
        return _cmNo;
    }
    return _cmNo;
  }

  /// After `group_channel` added a channel: its place (last), category and topic.
  void cmChannelCreated(Map<String, dynamic> args) {
    if (args['remove'] == true) return;
    final gid = args['gid'] as String;
    final g = _groups[gid];
    if (g == null || !_cmIsCommunity(g)) return;
    for (final list in [g['channels'] as List?, ...[for (final sp in _spaces.where((sp) => sp['id'] == gid)) sp['channels'] as List]]) {
      if (list == null) continue;
      final sorted = _cmSorted(list);
      for (var i = 0; i < sorted.length; i++) {
        sorted[i]['position'] = i;
        if (sorted[i]['name'] == args['name']) {
          sorted[i]['category'] = args['category'] ?? sorted[i]['category'] ?? '';
          sorted[i]['topic'] = args['topic'] ?? '';
        }
      }
    }
  }

  /// Seeds roles, topics and a private channel for the demo communities
  /// (`_spaces` entries without a group of their own get one).
  /// [people]: owner first, then an admin, then members.
  void cmSeedSpaces(List<String> people) {
    for (final sp in _spaces) {
      if (_groups.containsKey(sp['id'])) continue;
      final chans = (sp['channels'] as List).cast<Map<String, dynamic>>();
      for (var i = 0; i < chans.length; i++) {
        chans[i]['position'] = i;
      }
      final g = <String, dynamic>{
        'gid': sp['id'], 'name': sp['name'], 'kind': 1, 'owner': people.first, 'epoch': 1, 'my_role': 'member',
        'members': [
          {'peer': people.first, 'name': _contacts[people.first]?['name'] ?? '', 'role': 'owner'},
          {'peer': myPeer, 'name': _me['name'], 'role': 'member'},
          for (var i = 1; i < people.length; i++) {'peer': people[i], 'name': _contacts[people[i]]?['name'] ?? '', 'role': i == 1 ? 'admin' : 'member'},
        ],
        // the same maps as the space's: one place to change them
        'channels': chans,
      };
      _groups[sp['id'] as String] = g;
      final roles = _cmRoles(g);
      if (sp['name'] == 'Hội Lập Trình Việt') {
        roles.addAll([
          {'id': 'r_mod', 'name': 'Điều hành viên', 'color': '#22C55E', 'perms': [...Perm.everyoneDefault, Perm.manageMessages, Perm.mentionEveryone, Perm.kick, Perm.timeout], 'position': 3, 'builtin': false},
          {'id': 'r_rust', 'name': 'Rustacean', 'color': '#F59E0B', 'perms': <String>[], 'position': 2, 'builtin': false},
          {'id': 'r_flutter', 'name': 'Flutter Dev', 'color': '#0EA5E9', 'perms': <String>[], 'position': 1, 'builtin': false},
        ]);
        final ms = (g['members'] as List).cast<Map<String, dynamic>>();
        void give(int i, List<String> r) {
          if (i < ms.length) ms[i]['roles'] = r;
        }

        give(1, ['r_rust']); // me
        give(3, ['r_mod', 'r_rust']);
        give(4, ['r_flutter']);
        give(5, ['r_rust']);
        for (final c in chans) {
          if (c['name'] == 'chào-mừng') c['topic'] = 'Đọc nội quy và giới thiệu bản thân nhé 👋';
          if (c['name'] == 'thông-báo') {
            c['topic'] = 'Tin chính thức từ ban điều hành';
            c['announce'] = true;
          }
          if (c['name'] == 'chung') c['topic'] = 'Trò chuyện mọi thứ về lập trình';
        }
        // a channel only moderators see (hidden from this member account)
        const conv = 'g:c0ffee00c0ffee00c0ffee00c0ffee00';
        chans.insert(2, {'id': 'c0ffee00c0ffee00c0ffee00c0ffee00', 'name': 'ban-điều-hành', 'kind': 'text', 'conv': conv, 'participants': <String>[], 'unread': 0,
          'category': 'THÔNG TIN', 'private': true, 'allow_roles': ['r_mod'], 'topic': 'Chỉ dành cho điều hành viên'});
        _msgs[conv] = [];
        for (var i = 0; i < chans.length; i++) {
          chans[i]['position'] = i;
        }
      }
      _cmNormalizeRoles(g);
    }
  }

  /// Tests: sets my own timeout in community [gid] (0 lifts it).
  void cmSetMyTimeoutForTest(String gid, int untilMs) {
    final g = _groups[gid];
    if (g == null) return;
    _cmMember(g, myPeer)?['timeout_until'] = untilMs;
    _cmChanged(g);
  }

  /// Tests: makes me a plain admin (someone else owns [gid]).
  void cmMakeMeAdminForTest(String gid) {
    final g = _groups[gid];
    if (g == null) return;
    final members = (g['members'] as List).cast<Map>();
    final other = members.firstWhere((m) => m['peer'] != myPeer);
    for (final m in members) {
      if (m['role'] == 'owner') m['role'] = 'admin';
    }
    other['role'] = 'owner';
    g['owner'] = other['peer'];
    g['my_role'] = 'admin';
    _cmMember(g, myPeer)?['role'] = 'admin';
    _cmChanged(g);
  }

  /// Tests: my custom roles in community [gid].
  void cmSetMyRolesForTest(String gid, List<String> roles) {
    final g = _groups[gid];
    if (g == null) return;
    _cmMember(g, myPeer)?['roles'] = List<String>.of(roles);
    _cmChanged(g);
  }

  // ------------------------------------------------------------ groups 2.0

  bool _cmPlainGroupConv(String conv) {
    if (!conv.startsWith('g:') || conv.contains('#')) return false;
    final g = _groups[conv.substring(2)];
    return g != null && !_cmIsCommunity(g) && !_spaces.any((sp) => (sp['channels'] as List).any((c) => c['conv'] == conv));
  }

  /// Members other than me and bots.
  Iterable<Map<String, dynamic>> _cmOthers(Map<String, dynamic> g) {
    final bots = {for (final b in ((g['bots'] as List?) ?? const [])) b is Map ? b['peer'] : b};
    return (g['members'] as List).cast<Map<String, dynamic>>().where((m) => m['peer'] != myPeer && !bots.contains(m['peer']));
  }

  void _cmNotice(String gid, String code, Map<String, String> args, String text) {
    final conv = 'g:$gid';
    final m = _mkMsg(conv, myPeer, '', _now, kind: 'system', mine: false)..['body'] = {'code': code, 'args': args, 'text': text};
    (_msgs[conv] ??= []).add(m);
    _emit('message', Map.of(m));
  }

  Map<String, dynamic> _cmInviteJson(Map<String, dynamic> l) => {'id': l['id'], 'link': l['link'], 'created': l['created'], 'expires': l['expires']};

  /// Ownership, invite links, join approval, invitations, ringing in plain groups.
  dynamic groups2(String cmd, Map<String, dynamic> args) {
    switch (cmd) {
      case 'group_transfer_owner':
        final g = _cmGroup(args, cmd);
        if (_cmRoleOf(g, myPeer) != 'owner') throw ApiException('Chỉ trưởng nhóm làm được việc này', cmd: cmd, code: 'err.owner_only');
        final peer = args['peer'] as String? ?? '';
        final t = _cmMember(g, peer);
        if (t == null || peer == myPeer) throw ApiException('Không phải thành viên', cmd: cmd, code: 'err.not_member');
        t['role'] = 'owner';
        _cmMember(g, myPeer)?['role'] = 'admin';
        g['my_role'] = 'admin';
        g['owner'] = peer;
        _cmNotice(g['gid'] as String, 'sys.owner_changed', {'actor': myPeer, 'peer': peer}, 'Ownership transferred');
        _cmChanged(g);
        return null;
      case 'group_leave':
        final g = _groups[args['gid']];
        if (g != null && _cmRoleOf(g, myPeer) == 'owner' && _cmOthers(g).isNotEmpty) {
          throw ApiException('Hãy chọn trưởng nhóm mới trước khi rời nhóm', cmd: cmd, code: 'err.owner_must_transfer');
        }
        return _cmNo;
      case 'group_remove' || 'group_ban':
        // removed by an admin: only admins may add them back
        final g = _groups[args['gid']];
        if (g != null && _cmAdminish(g, myPeer) && (cmd == 'group_remove' || args['ban'] == true)) {
          ((g['_mRemoved'] ??= <String>[]) as List).add(args['peer']);
        }
        return _cmNo;
      case 'group_add':
        final g = _groups[args['gid']];
        if (g == null) return _cmNo;
        final peer = args['peer'];
        if (((g['_mRemoved'] as List?) ?? const []).contains(peer) && !_cmAdminish(g, myPeer)) {
          throw ApiException('Chỉ quản trị viên được thêm lại người này', cmd: cmd, code: 'err.removed_admin_only');
        }
        (g['_mRemoved'] as List?)?.remove(peer);
        final reqs = g['_mRequests'] as List?;
        final req = reqs?.where((r) => r['peer'] == peer).firstOrNull;
        if (req != null) {
          // an approved join request: they come in under the name they asked with
          reqs!.remove(req);
          (g['members'] as List).add({'peer': peer, 'name': _contacts[peer]?['name'] ?? req['name'], 'role': 'member'});
          g['epoch'] = (g['epoch'] as int) + 1;
          _cmChanged(g);
          return null;
        }
        return _cmNo;
      case 'group_join_deny':
        final g = _cmGroup(args, cmd);
        _cmNeed(g, Perm.invite, cmd);
        (g['_mRequests'] as List?)?.removeWhere((r) => r['peer'] == args['peer']);
        _cmChanged(g);
        return null;
      case 'group_settings':
        final g = _groups[args['gid']];
        if (g != null && args['approve_joins'] is bool) {
          _cmNeed(g, Perm.manageCommunity, cmd);
          g['_mApprove'] = args['approve_joins'];
          if (args['approve_joins'] != true) g['_mRequests'] = <Map<String, dynamic>>[];
          if (!args.containsKey('slow_mode_s') && !args.containsKey('admins_only')) {
            _cmChanged(g);
            return null;
          }
        }
        return _cmNo;
      case 'create_invite':
        final g = _groups[args['gid']];
        if (g == null) return _cmNo;
        if (_cmMember(g, myPeer) != null) _cmNeed(g, Perm.invite, cmd);
        final link = 'lumora://join/${_hex(24)}';
        _invites[link] = args['gid'] as String;
        final l = {'id': _hex(8), 'link': link, 'created': _now, 'expires': _now + ((args['hours'] as num?)?.toInt() ?? 24) * 3600000};
        ((g['_mLinks'] ??= <Map<String, dynamic>>[]) as List).add(l);
        return _cmInviteJson(l);
      case 'group_invite_links':
        final g = _cmGroup(args, cmd);
        return [
          for (final l in ((g['_mLinks'] as List?) ?? const []).cast<Map<String, dynamic>>())
            if (!_cmRevoked.contains(l['link']) && (l['expires'] as int) > _now) _cmInviteJson(l),
        ];
      case 'group_revoke_invite':
        final g = _cmGroup(args, cmd);
        _cmNeed(g, Perm.invite, cmd);
        final id = args['id'];
        for (final l in ((g['_mLinks'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
          if (id == null || l['id'] == id) _cmRevoked.add(l['link'] as String);
        }
        if (id == null) {
          for (final e in _invites.entries) {
            if (e.value == args['gid']) _cmRevoked.add(e.key);
          }
        }
        return null;
      case 'join_invite' || 'inspect_invite':
        final link = '${args['link']}'.trim();
        if (_cmRevoked.contains(link)) {
          if (cmd == 'inspect_invite') return {'name': '', 'valid': false, 'already_member': false};
          throw ApiException('Liên kết mời này đã bị thu hồi', cmd: cmd, code: 'err.invite_revoked');
        }
        return _cmNo;
      case 'group_invites':
        return [for (final i in _cmPendingInvites) Map<String, dynamic>.of(i)];
      case 'group_invite_answer':
        final i = _cmPendingInvites.where((x) => x['gid'] == args['gid']).firstOrNull;
        if (i == null) throw ApiException('Lời mời không còn nữa', cmd: cmd, code: 'err.group_not_found');
        _cmPendingInvites.remove(i);
        String? conv;
        if (args['accept'] == true) {
          final gid = i['gid'] as String;
          conv = 'g:$gid';
          _groups[gid] = {
            'gid': gid, 'name': i['name'], 'owner': i['by'], 'epoch': 1, 'my_role': 'member', 'kind': i['kind'] ?? 0,
            'members': [
              {'peer': i['by'], 'name': i['by_name'], 'role': 'owner'},
              {'peer': myPeer, 'name': _me['name'], 'role': 'member'},
            ],
          };
          _msgs[conv] = [
            _mkMsg(conv, i['by'] as String, '', _now, kind: 'system')
              ..['body'] = {'code': 'sys.you_added', 'args': {'actor': i['by'], 'name': i['name']}, 'text': 'You were added'},
          ];
          _convs[conv] = {'id': conv, 'kind': 1, 'title': i['name'], 'last_ts': _now, 'unread': 0, 'muted': false, 'pinned': false, 'last_text': ''};
          _emit('conversation', Map.of(_convs[conv]!));
        }
        _emit('group_invites', {});
        return conv == null ? null : {'conv': conv};
      case 'call_start':
        // plain groups: only the picked members ring; the rest see "Join"
        final conv = '${args['conv']}';
        if (!_cmPlainGroupConv(conv)) return _cmNo;
        final g = _groups[conv.substring(2)]!;
        final ring = ((args['ring'] as List?) ?? const []).map((e) => '$e').toSet();
        final parts = [for (final m in _cmOthers(g)) if (ring.contains(m['peer'])) m['peer'] as String];
        final id = 'c_${_hex(8)}';
        final call = {
          'call_id': id, 'conv': conv, 'peer': parts.isEmpty ? '' : parts.first, 'state': parts.isEmpty ? 'active' : 'ringing',
          'video': args['video'] == true, 'participants': parts,
          'streams': {for (var i = 0; i < parts.length; i++) parts[i]: i + 1, myPeer: 0},
          if (parts.isEmpty) 'started_at': _now,
        };
        _calls[id] = call;
        ringLog.add(parts);
        _later(const Duration(milliseconds: 50), () => _emit('call', Map.of(call)));
        if (parts.isNotEmpty) {
          _later(const Duration(milliseconds: 2200), () {
            if (_calls[id]?['state'] != 'ringing') return;
            call['state'] = 'active';
            call['started_at'] = _now;
            _emit('call', Map.of(call));
            _speakingLoop(id);
          });
        }
        return {'call_id': id};
      case 'call_answer':
        // dismissing an available group call is local: nothing is sent
        final c = _calls[args['call_id']];
        if (c != null && c['state'] == 'available' && args['accept'] != true) {
          _calls.remove(args['call_id']);
          return null;
        }
        return _cmNo;
    }
    return _cmNo;
  }

  /// Tests / demo: [peer] asks to join [gid] through an invite link (approval mode).
  void cmJoinRequestForTest(String gid, String peer, String name) {
    final g = _groups[gid];
    if (g == null) return;
    g['_mApprove'] = true;
    ((g['_mRequests'] ??= <Map<String, dynamic>>[]) as List).add({'peer': peer, 'name': name, 'at': _now});
    _cmChanged(g);
  }

  /// Tests / demo: an invitation to a group waits for my answer (`group_invite` event).
  Map<String, dynamic> cmGroupInviteForTest({required String name, required String by, String byName = '', int members = 3, int kind = 0}) {
    final i = {'gid': _hex(32), 'name': name, 'kind': kind, 'by': by, 'by_name': byName.isNotEmpty ? byName : (_contacts[by]?['name'] ?? ''), 'at': _now, 'members': members};
    _cmPendingInvites.add(i);
    _emit('group_invite', Map.of(i));
    return i;
  }

  /// Tests / demo: [from] started a call in plain group [conv] that doesn't ring me.
  String cmAvailableCallForTest(String conv, String from, {bool video = false}) {
    final id = 'c_${_hex(8)}';
    final call = {'call_id': id, 'conv': conv, 'peer': from, 'from': from, 'state': 'available', 'video': video, 'participants': [from], 'streams': {from: 1, myPeer: 0}};
    _calls[id] = call;
    _emit('call', Map.of(call));
    return id;
  }

  /// Tests: the available call [id] ended.
  void cmEndCallForTest(String id) {
    final c = _calls.remove(id);
    if (c != null) _emit('call', {...c, 'state': 'ended'});
  }

  /// Demo data (the app's mock mode, not tests): one invitation waiting and
  /// a join request in a group I own.
  void cmSeedGroups2(String inviter) {
    cmGroupInviteForTest(name: 'CLB Nhiếp ảnh Sài Gòn 📷', by: inviter, members: 18);
    final mine = _groups.values.where((g) => g['my_role'] == 'owner' && !_cmIsCommunity(g)).firstOrNull;
    if (mine != null) cmJoinRequestForTest(mine['gid'] as String, _hex(32), 'Đặng Thu Hà');
  }
}
