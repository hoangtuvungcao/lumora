// Application state. Each domain has its own ChangeNotifier so widgets only
// rebuild for what they display (use `context.select` / Selector).

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../core/api.dart';
import '../core/file_preview.dart';
import '../core/preview_builder.dart';
import '../platform/apple_audio.dart';
import '../platform/apple_services.dart';
import '../platform/mic_permission.dart';
import '../core/file_safety.dart';
import 'group_flood.dart';

// ---------------------------------------------------------------- session

enum SessionPhase { loading, onboarding, locked, ready, error }

class SessionStore extends ChangeNotifier {
  SessionStore(this.api);
  final LumoraApi api;

  SessionPhase phase = SessionPhase.loading;
  Me? me;
  String? error;
  Profile profile = const Profile();
  Uint8List? avatarBytes;
  Uint8List? coverBytes;

  Future<void> saveCover(Uint8List? jpg) async {
    final b64 = jpg == null ? null : base64Encode(jpg);
    await api.setCover(b64);
    profile = profile.copyWith(cover: b64);
    coverBytes = jpg;
    notifyListeners();
  }

  Future<void> loadProfile() async {
    try {
      profile = await api.profile();
      avatarBytes = _decodeB64(profile.avatar);
      coverBytes = _decodeB64(profile.cover);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setUsername(String username) async {
    final r = await api.setUsername(username);
    me = me?.copyWith(username: r['username']?.toString(), handle: r['handle']?.toString());
    notifyListeners();
  }

  Future<void> setStatus(String status) async {
    profile = profile.copyWith(status: status);
    notifyListeners();
    await api.setProfile(status: status);
  }

  Future<void> saveProfile({String? name, String? bio, Uint8List? avatar}) async {
    final b64 = avatar == null ? null : base64Encode(avatar);
    await api.setProfile(name: name, bio: bio, avatar: b64);
    profile = profile.copyWith(name: name, bio: bio, avatar: b64);
    if (avatar != null) avatarBytes = avatar;
    if (name != null) me = me?.copyWith(name: name);
    notifyListeners();
  }

  Future<void> start(Map<String, dynamic> config, {bool enter = true}) async {
    error = null;
    await api.start(config);
    me = await api.me();
    loadProfile();
    if (enter) phase = SessionPhase.ready;
    notifyListeners();
  }

  void setPhase(SessionPhase p, {String? err}) {
    phase = p;
    error = err;
    notifyListeners();
  }

  /// Re-reads `me` (e.g. after the passphrase protection changed).
  Future<void> reloadMe() async {
    me = await api.me();
    notifyListeners();
  }

  Future<void> rename(String name) async {
    await api.setName(name);
    me = me?.copyWith(name: name);
    notifyListeners();
  }
}

Uint8List? _decodeB64(String? s) {
  if (s == null || s.isEmpty) return null;
  try {
    return base64Decode(s.contains(',') ? s.substring(s.indexOf(',') + 1) : s);
  } catch (_) {
    return null;
  }
}

/// Lazily fetched contact avatars (bytes are decoded at display size).
class AvatarStore extends ChangeNotifier {
  AvatarStore(this.api);
  final LumoraApi api;
  final Map<String, Uint8List?> _cache = {};
  final Set<String> _pending = {};

  Uint8List? of(String peer, {bool hasAvatar = true}) {
    if (_cache.containsKey(peer)) return _cache[peer];
    if (hasAvatar && !_pending.contains(peer)) {
      _pending.add(peer);
      api.contactAvatar(peer).then((b64) {
        _cache[peer] = _decodeB64(b64);
        _pending.remove(peer);
        if (_cache[peer] != null) notifyListeners();
      }).catchError((_) {
        _cache[peer] = null;
        _pending.remove(peer);
      });
    }
    return null;
  }

  /// Contact profile cover (key `c:<peer>`).
  Uint8List? cover(String peer) {
    final key = 'c:$peer';
    if (_cache.containsKey(key)) return _cache[key];
    if (!_pending.contains(key)) {
      _pending.add(key);
      api.contactCover(peer).then((b64) {
        _cache[key] = _decodeB64(b64);
        _pending.remove(key);
        if (_cache[key] != null) notifyListeners();
      }).catchError((_) {
        _cache[key] = null;
        _pending.remove(key);
      });
    }
    return null;
  }

  /// Group/community avatar (key `g:<gid>`).
  Uint8List? group(String gid) {
    final key = 'g:$gid';
    if (_cache.containsKey(key)) return _cache[key];
    if (!_pending.contains(key)) {
      _pending.add(key);
      api.groupAvatar(gid).then((b64) {
        _cache[key] = _decodeB64(b64);
        _pending.remove(key);
        if (_cache[key] != null) notifyListeners();
      }).catchError((_) {
        _cache[key] = null;
        _pending.remove(key);
      });
    }
    return null;
  }

  /// The group changed (`group` event): a cached avatar (or a cached "none")
  /// is fetched again — the old picture stays until the new one is here.
  void refreshGroup(String gid, {bool? hasAvatar}) {
    final key = 'g:$gid';
    if (!_cache.containsKey(key)) return; // never shown: fetched when needed
    if (hasAvatar == false) {
      if (_cache[key] != null) {
        _cache[key] = null;
        notifyListeners();
      }
      return;
    }
    if (!_pending.add(key)) return;
    api.groupAvatar(gid).then((b64) {
      _pending.remove(key);
      final bytes = _decodeB64(b64);
      if (!_sameBytes(_cache[key], bytes)) {
        _cache[key] = bytes;
        notifyListeners();
      }
    }).catchError((_) {
      _pending.remove(key);
    });
  }

  /// A contact removed their avatar.
  void cleared(String peer) {
    if (_cache[peer] == null) return;
    _cache[peer] = null;
    notifyListeners();
  }

  static bool _sameBytes(Uint8List? a, Uint8List? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void setGroup(String gid, Uint8List bytes) {
    _cache['g:$gid'] = bytes;
    notifyListeners();
  }

  void invalidate(String peer) {
    _cache.remove(peer);
    notifyListeners();
  }
}

// --------------------------------------------------------------- contacts

class ContactsStore extends ChangeNotifier {
  ContactsStore(this.api);
  final LumoraApi api;

  final Map<String, Contact> byPeer = {};
  List<Contact>? _sorted;

  Future<void> load() async {
    final list = await api.contacts();
    byPeer
      ..clear()
      ..addEntries(list.map((c) => MapEntry(c.peer, c)));
    _changed();
  }

  void _changed() {
    _sorted = null;
    notifyListeners();
  }

  Contact? operator [](String peer) => byPeer[peer];

  static final _peerRe = RegExp(r'^[a-z2-7]{52}$');

  /// Display name for a peer id; non-id strings (e.g. `forwarded_from`
  /// names from the core) are returned unchanged.
  String nameOf(String peer, {String? me, String? meName}) {
    if (peer == me) return meName ?? 'Bạn';
    final c = byPeer[peer];
    if (c != null && c.displayName.isNotEmpty) return c.displayName;
    final known = PeerNames.known[peer]; // a group member the core named
    if (known != null) return known;
    return _peerRe.hasMatch(peer) ? '${peer.substring(0, 8)}…' : peer;
  }

  List<Contact> get all {
    return _sorted ??= byPeer.values.toList()
      ..sort((a, b) {
        if (a.online != b.online) return a.online ? -1 : 1;
        return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
      });
  }

  List<Contact> get friends => all.where((c) => c.status == ContactStatus.friend).toList();
  List<Contact> get incoming => all.where((c) => c.status == ContactStatus.received).toList();
  List<Contact> get outgoing => all.where((c) => c.status == ContactStatus.sent).toList();
  List<Contact> get blocked => all.where((c) => c.status == ContactStatus.blocked).toList();
  int get pendingCount => byPeer.values.where((c) => c.status == ContactStatus.received).length;

  void onContact(Map<String, dynamic> j) {
    final c = Contact.fromJson(j);
    if (c.status == ContactStatus.none) {
      byPeer.remove(c.peer);
    } else {
      final old = byPeer[c.peer];
      byPeer[c.peer] = old == null ? c : c.copyWith(online: j.containsKey('online') ? c.online : old.online, path: c.path ?? old.path);
    }
    _changed();
  }

  void onPresence(Map<String, dynamic> j) {
    final peer = j['peer']?.toString();
    final c = byPeer[peer];
    if (c == null) return;
    final online = j['online'] == true;
    byPeer[c.peer] = Contact(
      peer: c.peer,
      shortId: c.shortId,
      name: c.name,
      alias: c.alias,
      status: c.status,
      added: c.added,
      lastSeen: online ? c.lastSeen : DateTime.now().millisecondsSinceEpoch,
      verified: c.verified,
      relays: c.relays,
      online: online,
      path: online ? j['path']?.toString() : null,
      note: c.note,
      bio: c.bio,
      presence: j['status']?.toString() ?? j['presence']?.toString() ?? c.presence,
      hasAvatar: c.hasAvatar,
    );
    _changed();
  }

  void onFriendRequest(Map<String, dynamic> j) {
    final peer = j['peer']?.toString() ?? '';
    final old = byPeer[peer];
    byPeer[peer] = Contact(
      peer: peer,
      shortId: old?.shortId ?? '',
      name: j['name']?.toString() ?? old?.name ?? '?',
      status: ContactStatus.received,
      online: old?.online ?? true,
      note: j['note']?.toString(),
      added: DateTime.now().millisecondsSinceEpoch,
    );
    _changed();
  }

  Future<String> add(String id, {String? note}) async {
    final peer = await api.addContact(id, note: note);
    return peer;
  }

  Future<void> accept(String peer) async {
    await api.acceptContact(peer);
    final c = byPeer[peer];
    if (c != null) byPeer[peer] = c.copyWith(status: ContactStatus.friend);
    _changed();
  }

  Future<void> remove(String peer) async {
    await api.removeContact(peer);
    byPeer.remove(peer);
    _changed();
  }

  Future<void> block(String peer) async {
    await api.blockContact(peer);
    final c = byPeer[peer];
    if (c != null) byPeer[peer] = c.copyWith(status: ContactStatus.blocked);
    _changed();
  }

  /// They can message and call again; the old chat stays. Not re-added as a friend.
  Future<void> unblock(String peer) async {
    await api.unblockContact(peer);
    final c = byPeer[peer];
    if (c != null) byPeer[peer] = c.copyWith(status: ContactStatus.none);
    _changed();
  }

  Future<void> rename(String peer, String alias) async {
    await api.renameContact(peer, alias);
    final c = byPeer[peer];
    if (c != null) byPeer[peer] = c.copyWith(alias: alias);
    _changed();
  }

  Future<void> setVerified(String peer, bool v) async {
    await api.markVerified(peer, v);
    final c = byPeer[peer];
    if (c != null) byPeer[peer] = c.copyWith(verified: v);
    _changed();
  }
}

// ------------------------------------------------------------------- chat

/// Removes formatting markers for previews (**b** _i_ ~~s~~ `c` ||spoiler||).
String stripFormatting(String t) => t
    .replaceAllMapped(RegExp(r'\|\|(.+?)\|\|'), (_) => '▒▒▒')
    .replaceAll(RegExp(r'```|\*\*|~~|`'), '')
    .replaceAllMapped(RegExp(r'(^|\s)_(.+?)_(?=\s|$)'), (m) => '${m[1]}${m[2]}');

/// File message body: `{file_id, name, size, mime, hash, thumb, width, height}`.
class FileRef {
  const FileRef(this.id, this.name, this.size, {this.mime = '', this.thumb, this.width = 0, this.height = 0, this.preview});
  final String id;
  final String name;
  final int size;
  final String mime;
  final Uint8List? thumb;
  final int width;
  final int height;

  /// Sender-made preview of a PDF / text file (`body.preview`), shown before download.
  final FilePreview? preview;

  bool get isImage => mime.startsWith('image/') || _ext(name, const ['png', 'jpg', 'jpeg', 'webp', 'gif', 'heic', 'bmp']);
  bool get isVideo => mime.startsWith('video/') || _ext(name, const ['mp4', 'mov', 'mkv', 'webm', 'avi']);
  double get aspect => width > 0 && height > 0 ? width / height : (isImage ? 4 / 3 : 16 / 9);

  static bool _ext(String n, List<String> exts) {
    final i = n.lastIndexOf('.');
    return i >= 0 && exts.contains(n.substring(i + 1).toLowerCase());
  }

  static final Map<String, FileRef?> _cache = {};

  /// Parses (and memoises: thumbnails are decoded once) a file message body.
  static FileRef? parse(String body) {
    final hit = _cache[body];
    if (hit != null || _cache.containsKey(body)) return hit;
    FileRef? r;
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        Uint8List? thumb;
        final t = j['thumb'];
        if (t is String && t.isNotEmpty) {
          try {
            thumb = base64Decode(t.contains(',') ? t.substring(t.indexOf(',') + 1) : t);
          } catch (_) {}
          // Thumbnails come from the sender: refuse oversized ones and
          // "decompression bombs" (tiny file, gigantic declared picture).
          if (thumb != null && (thumb.length > 256 * 1024 || !isSafeImageBytes(thumb))) thumb = null;
        }
        r = FileRef(
          j['file_id']?.toString() ?? j['id']?.toString() ?? '',
          // no direction overrides / invisible characters hiding the real type
          safeDisplayName(j['name']?.toString() ?? 'file'),
          (j['size'] as num?)?.toInt() ?? 0,
          mime: j['mime']?.toString() ?? '',
          thumb: thumb,
          width: (j['width'] as num?)?.toInt() ?? 0,
          height: (j['height'] as num?)?.toInt() ?? 0,
          preview: FilePreview.fromJson(j['preview']),
        );
      }
    } catch (_) {}
    if (_cache.length > 400) _cache.clear();
    _cache[body] = r;
    return r;
  }
}

/// Structured system message body: `{code, args, text}`.
class SystemText {
  const SystemText(this.code, this.args, this.text);
  final String code;
  final Map<String, String> args;
  final String text;
  static SystemText? parse(String body) {
    if (!body.startsWith('{')) return null;
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final a = <String, String>{};
        if (j['args'] is Map) (j['args'] as Map).forEach((k, v) => a[k.toString()] = v.toString());
        return SystemText(j['code']?.toString() ?? '', a, j['text']?.toString() ?? '');
      }
    } catch (_) {}
    return null;
  }
}

/// Messages of one conversation, loaded lazily and paginated.
class ConvThread extends ChangeNotifier {
  ConvThread(this.api, this.conv);
  final LumoraApi api;
  final String conv;

  final List<Message> messages = [];
  final Map<String, int> _index = {};
  bool loaded = false;
  bool loadingOlder = false;
  bool hasMore = true;
  static const pageSize = 40;

  void _reindex() {
    _index.clear();
    for (var i = 0; i < messages.length; i++) {
      _index[messages[i].id] = i;
    }
  }

  Message? byId(String? id) {
    if (id == null) return null;
    final i = _index[id];
    return i == null ? null : messages[i];
  }

  Future<void> loadInitial() async {
    if (loaded) return;
    final list = await api.messages(conv, limit: pageSize);
    messages
      ..clear()
      ..addAll(list);
    hasMore = list.length >= pageSize;
    loaded = true;
    _reindex();
    notifyListeners();
  }

  /// Messages were imported underneath this thread without `message` events
  /// (history copied to a newly linked device): read the newest page again
  /// (at least as many as shown) so older ones can be scrolled to.
  Future<void> reloadAfterImport() async {
    if (!loaded || loadingOlder) return;
    final n = math.max(pageSize, messages.length);
    final list = await api.messages(conv, limit: n);
    messages
      ..clear()
      ..addAll(list);
    hasMore = list.length >= n;
    _reindex();
    notifyListeners();
  }

  Future<void> loadOlder() async {
    if (loadingOlder || !hasMore || messages.isEmpty) return;
    loadingOlder = true;
    notifyListeners();
    try {
      final list = await api.messages(conv, before: messages.first.hlc, limit: pageSize);
      final fresh = list.where((m) => !_index.containsKey(m.id)).toList();
      messages.insertAll(0, fresh);
      hasMore = list.length >= pageSize;
      _reindex();
    } finally {
      loadingOlder = false;
      notifyListeners();
    }
  }

  void add(Message m) {
    if (_index.containsKey(m.id)) {
      messages[_index[m.id]!] = m;
    } else {
      messages.add(m);
      if (messages.length > 1 && messages[messages.length - 2].hlc > m.hlc && m.hlc != 0) {
        messages.sort((a, b) => a.hlc.compareTo(b.hlc));
        _reindex();
      } else {
        _index[m.id] = messages.length - 1;
      }
    }
    notifyListeners();
  }

  void update(Map<String, dynamic> u) {
    final i = _index[u['id']];
    if (i == null) return;
    messages[i] = messages[i].applyUpdate(u);
    notifyListeners();
  }

  void removeExpired(int now) {
    final before = messages.length;
    messages.removeWhere((m) => m.expires != null && m.expires! <= now);
    if (messages.length != before) {
      _reindex();
      notifyListeners();
    }
  }
}

enum ChatFilter { all, unread, direct, groups, communities }

class ChatStore extends ChangeNotifier {
  ChatStore(this.api);
  final LumoraApi api;

  final Map<String, Conversation> convs = {};
  final Map<String, ConvThread> _threads = {};
  final Map<String, String> drafts = {};
  final Map<String, int> ttlByConv = {};

  /// conv -> wallpaper value (null = default). `default` key holds the global one.
  final Map<String, String?> wallpapers = {};

  Future<void> loadWallpaper(String conv) async {
    try {
      if (!wallpapers.containsKey('default')) wallpapers['default'] = await api.getWallpaper('default');
      final w = await api.getWallpaper(conv);
      wallpapers[conv] = w;
      notifyListeners();
    } catch (_) {}
  }

  String? wallpaperOf(String conv) => wallpapers[conv] ?? wallpapers['default'];

  Future<void> setWallpaper(String conv, String? value, {bool all = false}) async {
    if (all) {
      wallpapers['default'] = value;
      wallpapers.updateAll((k, v) => k == 'default' ? value : null);
      await api.setWallpaper('default', value);
    } else {
      wallpapers[conv] = value;
      await api.setWallpaper(conv, value);
    }
    notifyListeners();
  }

  /// conv -> history retention mode (forever | session | 24h | 7d | 30d).
  final Map<String, String> retention = {};

  Future<void> loadRetention(String conv) async {
    try {
      final m = await api.getRetention(conv);
      if (retention[conv] != m) {
        retention[conv] = m;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> setRetention(String conv, String mode) async {
    retention[conv] = mode;
    notifyListeners();
    await api.setRetention(conv, mode);
  }

  /// conv -> "messages held back in this group" notice (`group_flood`).
  final floods = FloodNotices();

  /// conv -> peers currently typing.
  final ValueNotifier<Map<String, Set<String>>> typing = ValueNotifier({});
  final Map<String, Timer> _typingExpiry = {};
  Timer? _expiryTimer;
  List<Conversation>? _sorted;

  Future<void> load() async {
    final list = await api.conversations();
    convs
      ..clear()
      ..addEntries(list.map((c) => MapEntry(c.id, c)));
    _sorted = null;
    notifyListeners();
    _fillPreviews();
    _expiryTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final t in _threads.values) {
        t.removeExpired(now);
      }
    });
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    for (final t in _typingExpiry.values) {
      t.cancel();
    }
    super.dispose();
  }

  ConvThread thread(String conv) => _threads.putIfAbsent(conv, () => ConvThread(api, conv));

  /// History was copied in (newly linked device): open threads read it.
  Future<void> reloadThreadsAfterImport() async {
    for (final t in List.of(_threads.values)) {
      await t.reloadAfterImport().catchError((_) {});
    }
  }

  /// Saved messages, then pinned, then by recency.
  List<Conversation> get sorted => _sorted ??= convs.values.toList()
    ..sort((a, b) {
      if (a.isSaved != b.isSaved) return a.isSaved ? -1 : 1;
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.lastTs.compareTo(a.lastTs);
    });

  /// Chats in the PIN-locked folder (set by [AppServices]). They never count
  /// in [totalUnread] (nav badge): the number would reveal their activity.
  Iterable<String> Function() lockedConvs = () => const [];

  int get totalUnread {
    final locked = lockedConvs().toSet();
    return convs.values.where((c) => !c.muted && !c.archived && !c.id.contains('#') && !locked.contains(c.id)).fold(0, (a, c) => a + c.unread);
  }

  /// Some locked chat has unread messages (a neutral dot on the folder).
  bool get lockedUnread {
    final locked = lockedConvs().toSet();
    return locked.isNotEmpty && convs.values.any((c) => c.unread > 0 && locked.contains(c.id));
  }

  int get archivedCount => convs.values.where((c) => c.archived).length;
  int get archivedUnread => convs.values.where((c) => c.archived).fold(0, (a, c) => a + c.unread);

  /// Community conversations (from `spaces`), shown in the Communities folder.
  Set<String> communityConvs = const {};

  void setCommunityConvs(Set<String> v) {
    communityConvs = v;
    _sorted = null;
    notifyListeners();
  }

  List<Conversation> filtered(ChatFilter f, String q, {bool archived = false}) {
    final ql = q.trim().toLowerCase();
    return sorted.where((c) {
      if (c.id.contains('#')) return false; // channel conversations live in spaces
      final community = c.isCommunity || communityConvs.contains(c.id);
      if (c.archived != archived && ql.isEmpty) return false;
      if (f == ChatFilter.direct && (c.isGroup || c.isSaved)) return false;
      if (f == ChatFilter.groups && (!c.isGroup || community)) return false;
      if (f == ChatFilter.communities && !community) return false;
      if (f == ChatFilter.unread && c.unread == 0) return false;
      if (ql.isNotEmpty && !c.title.toLowerCase().contains(ql) && !c.lastText.toLowerCase().contains(ql)) return false;
      return true;
    }).toList();
  }

  void _conv(Conversation c) {
    convs[c.id] = c;
    _sorted = null;
    notifyListeners();
  }

  void onConversation(Map<String, dynamic> j) {
    var c = Conversation.fromJson(j);
    final old = convs[c.id];
    // Core may omit previews; keep what we derived from message events.
    if (old != null && c.lastText.isEmpty && c.lastTs <= old.lastTs) {
      c = c.copyWith(lastText: old.lastText, lastMine: old.lastMine, lastTs: old.lastTs);
    } else if (old != null && !j.containsKey('last_mine') && c.lastText == old.lastText) {
      c = c.copyWith(lastMine: old.lastMine); // same last message: who wrote it is known here
    }
    // The core's conversation rows carry no `mentions` (it sends `mention` events, then
    // the row): keep the count until the chat is read.
    if (old != null && !j.containsKey('mentions') && c.unread > 0 && old.mentions > 0) c = c.copyWith(mentions: old.mentions);
    _conv(c);
  }

  /// Fills empty previews from the latest message (real core leaves
  /// `last_text` empty for some conversations).
  Future<void> _fillPreviews() async {
    for (final c in convs.values.where((c) => c.lastText.isEmpty).toList()) {
      try {
        final l = await api.messages(c.id, limit: 1);
        if (l.isEmpty) continue;
        final cur = convs[c.id];
        if (cur != null && cur.lastText.isEmpty) convs[c.id] = cur.copyWith(lastText: _previewOf(l.last), lastMine: l.last.mine, lastTs: l.last.ts);
      } catch (_) {}
    }
    _sorted = null;
    notifyListeners();
  }

  void onMessage(Map<String, dynamic> j, {required String myPeer, String? openConv}) {
    final m = Message.fromJson(j);
    if (_threads.containsKey(m.conv)) _threads[m.conv]!.add(m);
    // Clear typing for the author.
    _setTyping(m.conv, m.author, false);
    final c = convs[m.conv];
    if (c != null && m.ts >= c.lastTs) {
      _conv(c.copyWith(lastTs: m.ts, lastText: _previewOf(m), lastMine: m.mine));
    }
    if (openConv == m.conv && !m.mine) api.markRead(m.conv);
  }

  String _previewOf(Message m) {
    if (m.isSystem) return SystemText.parse(m.body)?.text ?? m.body;
    if (m.kind == 'location') return '📍 ${LocationData.parse(m.body)?.label ?? ''}';
    if (m.kind == 'voice') return '🎤';
    if (m.kind == 'call') return '📞';
    if (m.kind == 'contact') return '👤 ${ContactCard.parse(m.body)?.name ?? ''}';
    if (m.isPoll) return '📊 ${PollData.parse(m)?.question ?? ''}';
    if (m.kind == 'checklist') return '☑️ ${ChecklistData.parse(m)?.title ?? ''}';
    if (m.kind == 'reminder') return '⏰ ${ReminderData.parse(m)?.title ?? ''}';
    if (m.isFile) return '📎 ${FileRef.parse(m.body)?.name ?? ''}';
    return m.body; // "You:" is added from `lastMine` by the list
  }

  void onMessageUpdate(Map<String, dynamic> j) {
    final conv = j['conv']?.toString() ?? '';
    final t = _threads[conv];
    // `removed`: purged (deleted for me here or on another of my devices, expired):
    // it leaves the chat at once instead of lingering until the next reload.
    if (j['removed'] == true) {
      if (t != null) {
        final before = t.messages.length;
        t.messages.removeWhere((m) => m.id == j['id']);
        if (t.messages.length != before) {
          t._reindex();
          t.notifyListeners();
        }
      }
      _refreshPreview(conv);
      _unpin(conv, j['id']);
      return;
    }
    t?.update(j);
    if (j['deleted'] == true) {
      _refreshPreview(conv);
      _unpin(conv, j['id']);
    } else if (j.containsKey('pinned')) {
      _syncPin(conv, j['id']?.toString() ?? '', j['pinned'] == true);
    } else {
      // an edited pinned message: the bar shows its new text
      final list = pinned[conv];
      final m = t?.byId(j['id']?.toString() ?? '');
      final i = list == null || m == null ? -1 : list.indexWhere((x) => x.id == m.id);
      if (i >= 0) {
        pinned[conv] = List<Message>.of(list!)..[i] = m!;
        notifyListeners();
      }
    }
  }

  /// A deleted / purged message leaves the pinned bar too.
  void _unpin(String conv, Object? id) {
    final list = pinned[conv];
    if (list == null || !list.any((m) => m.id == id)) return;
    pinned[conv] = list.where((m) => m.id != id).toList();
    notifyListeners();
  }

  /// Pinned / unpinned elsewhere (another member, my other device): the bar follows.
  void _syncPin(String conv, String id, bool on) {
    final list = pinned[conv];
    if (list == null) return; // not shown yet: loaded fresh when the chat opens
    if (!on) {
      _unpin(conv, id);
      return;
    }
    if (list.any((m) => m.id == id)) return;
    final m = _threads[conv]?.byId(id);
    if (m != null) {
      pinned[conv] = [...list, m];
      notifyListeners();
    } else {
      loadPinned(conv); // not in the loaded part of the chat: ask the core
    }
  }

  /// Group chats I was removed from (kicked / banned): kept, read-only.
  final Set<String> removedGroups = {};

  /// Whether `conv` (a group chat or one of its channels) is read-only for me.
  bool removedFrom(String conv) => conv.startsWith('g:') && removedGroups.contains(conv.split('#').first);

  /// `group` event: the title follows a rename; membership is known.
  void onGroup(String gid, {String? name, bool? member}) {
    final conv = 'g:$gid';
    var changed = false;
    final c = convs[conv];
    if (c != null && name != null && name.isNotEmpty && c.title != name) {
      convs[conv] = c.copyWith(title: name);
      _sorted = null;
      changed = true;
    }
    if (member == true) changed |= removedGroups.remove(conv);
    if (member == false && convs.containsKey(conv)) changed |= removedGroups.add(conv);
    if (changed) notifyListeners();
  }

  /// I'm out of a group: `left` (by me, maybe on another device) → its chats
  /// go; kicked → the chat stays, read-only, with the core's notice line.
  void onGroupRemoved(String conv, {required bool left}) {
    if (left) {
      for (final id in convs.keys.where((k) => k == conv || k.startsWith('$conv#')).toList()) {
        onConversationRemoved(id);
      }
      onConversationRemoved(conv);
      removedGroups.remove(conv);
      return;
    }
    if (removedGroups.add(conv)) notifyListeners();
  }

  /// The chat was deleted (by me on another device, or "for both" by the other side).
  void onConversationRemoved(String conv) {
    pinned.remove(conv);
    if (convs.remove(conv) == null && !_threads.containsKey(conv)) return;
    _threads.remove(conv);
    _sorted = null;
    notifyListeners();
  }

  /// Its history was cleared (elsewhere): empty the open thread and the preview.
  void onHistoryCleared(String conv) {
    if (pinned[conv]?.isNotEmpty ?? false) loadPinned(conv); // cleared pins go with it
    final t = _threads[conv];
    if (t != null) {
      t.messages.clear();
      t._reindex();
      t.notifyListeners();
    }
    final c = convs[conv];
    if (c != null) _conv(c.copyWith(lastText: '', unread: 0));
  }

  /// The list preview follows the newest message still shown.
  void _refreshPreview(String conv) {
    final c = convs[conv];
    final t = _threads[conv];
    if (c == null || t == null) return;
    final live = t.messages.where((m) => !m.deleted).toList();
    if (live.isEmpty) {
      if (c.lastText.isNotEmpty) _conv(c.copyWith(lastText: ''));
      return;
    }
    final m = live.last;
    final text = _previewOf(m);
    if (text != c.lastText) _conv(c.copyWith(lastText: text, lastMine: m.mine, lastTs: m.ts));
  }

  void onTyping(Map<String, dynamic> j) =>
      _setTyping(j['conv']?.toString() ?? '', j['peer']?.toString() ?? '', j['on'] == true);

  void _setTyping(String conv, String peer, bool on) {
    final cur = typing.value;
    final set = cur[conv] ?? const <String>{};
    if (on == set.contains(peer)) {
      if (on) _armTypingExpiry(conv, peer);
      return;
    }
    final next = Map<String, Set<String>>.of(cur);
    final s = Set<String>.of(set);
    on ? s.add(peer) : s.remove(peer);
    if (s.isEmpty) {
      next.remove(conv);
    } else {
      next[conv] = s;
    }
    typing.value = next;
    if (on) _armTypingExpiry(conv, peer);
  }

  void _armTypingExpiry(String conv, String peer) {
    final k = '$conv|$peer';
    _typingExpiry[k]?.cancel();
    _typingExpiry[k] = Timer(const Duration(seconds: 7), () => _setTyping(conv, peer, false));
  }

  Future<void> markRead(String conv) async {
    final c = convs[conv];
    if (c != null && (c.unread > 0 || c.mentions > 0)) _conv(c.copyWith(unread: 0, mentions: 0));
    try {
      await api.markRead(conv);
    } catch (_) {}
  }

  /// [clientId]: see [LumoraApi.sendMessage] — the same id on a retry never
  /// sends the message twice.
  Future<Message> send(String conv, String text, {String? replyTo, List<String>? mentions, bool mentionAll = false, bool silent = false, String? clientId}) async {
    final ttl = ttlByConv[conv];
    final m = await api.sendMessage(conv, text,
        replyTo: replyTo, ttlMs: (ttl ?? 0) > 0 ? ttl : null, mentions: mentions, mentionAll: mentionAll, silent: silent, clientId: clientId);
    thread(conv).add(m);
    final c = convs[conv];
    if (c != null) _conv(c.copyWith(lastTs: m.ts, lastText: text, lastMine: true));
    drafts.remove(conv);
    return m;
  }

  Future<void> edit(String conv, String id, String text) async {
    await api.editMessage(conv, id, text);
    thread(conv).update({'id': id, 'body': text, 'edited': true});
  }

  Future<void> deleteFor(String conv, String id, {required bool forEveryone}) async {
    await api.deleteMessageFor(conv, id, forEveryone: forEveryone);
    final t = thread(conv);
    // Gone from my screen at once either way; the others see "message was unsent".
    {
      t.messages.removeWhere((m) => m.id == id);
      t._reindex();
      t.notifyListeners();
    }
    _refreshPreview(conv);
  }

  Future<void> clearHistory(String conv, {bool forEveryone = false}) async {
    await api.clearHistory(conv, forEveryone: forEveryone);
    final t = thread(conv);
    t.messages.clear();
    t._reindex();
    t.notifyListeners();
    final c = convs[conv];
    if (c != null) _conv(c.copyWith(lastText: '', unread: 0));
  }

  Future<void> deleteConversationFor(String conv, {bool forEveryone = false}) async {
    await api.deleteConversationFor(conv, forEveryone: forEveryone);
    convs.remove(conv);
    _threads.remove(conv);
    _sorted = null;
    notifyListeners();
  }

  /// until: ms timestamp (0 = unmute).
  Future<void> muteUntil(String conv, int until) async {
    final c = convs[conv];
    if (c != null) _conv(c.copyWith(muted: until > 0));
    await api.mute(conv, until);
  }

  Future<void> delete(String conv, String id) async {
    await api.deleteMessage(conv, id);
    thread(conv).update({'id': id, 'deleted': true, 'body': ''});
  }

  Future<void> toggleReaction(String conv, Message m, String emoji, String me) async {
    final on = !(m.reactions[emoji]?.contains(me) ?? false);
    final r = Map<String, List<String>>.of(m.reactions.map((k, v) => MapEntry(k, List<String>.of(v))));
    final l = r[emoji] ?? <String>[];
    l.remove(me);
    if (on) l.add(me);
    if (l.isEmpty) {
      r.remove(emoji);
    } else {
      r[emoji] = l;
    }
    thread(conv).update({'id': m.id, 'reactions': r});
    await api.react(conv, m.id, emoji, on);
  }

  // ------------------------------------------------ pins / polls / forward

  final Map<String, List<Message>> pinned = {};

  Future<void> loadPinned(String conv) async {
    try {
      pinned[conv] = await api.pinnedMessages(conv);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> togglePin(String conv, Message m) async {
    final on = !m.pinned;
    thread(conv).update({'id': m.id, 'pinned': on});
    final list = List<Message>.of(pinned[conv] ?? const []);
    list.removeWhere((x) => x.id == m.id);
    if (on) list.add(thread(conv).byId(m.id) ?? m);
    pinned[conv] = list;
    notifyListeners();
    await api.pinMessage(conv, m.id, on);
  }

  Future<void> forward(Message m, String toConv) async {
    await api.forwardMessage(m.id, toConv);
    if (_threads.containsKey(toConv)) {
      _threads[toConv]!.loaded = false;
      await _threads[toConv]!.loadInitial();
    }
  }

  Future<void> vote(String conv, Message m, int option, String me) async {
    final votes = Map<String, int>.of(m.votes);
    if (votes[me] == option) {
      votes.remove(me);
    } else {
      votes[me] = option;
    }
    thread(conv).update({'id': m.id, 'reactions': {...m.reactions, '__votes': votes}});
    await api.vote(conv, m.id, votes[me] ?? -1);
  }

  Future<void> sendPoll(String conv, String q, List<String> options) async {
    final m = await api.sendPoll(conv, q, options);
    thread(conv).add(m);
  }

  // ------------------------------------------------ checklists / reminders

  Future<void> sendChecklist(String conv, String title, List<String> items) async {
    final m = await api.sendChecklist(conv, title, items);
    thread(conv).add(m);
    final c = convs[conv];
    if (c != null) _conv(c.copyWith(lastTs: m.ts, lastText: _previewOf(m), lastMine: m.mine));
  }

  /// Ticks / unticks a checklist item (shown at once, then confirmed by the core).
  Future<void> toggleCheck(String conv, Message m, int item, bool done, String me) async {
    final checks = Map<String, dynamic>.of((m.state['__checks'] as Map?)?.cast<String, dynamic>() ?? const {});
    checks['$item'] = {'done': done, 'by': me, 'at': DateTime.now().millisecondsSinceEpoch};
    final r = <String, dynamic>{...m.reactions, ...m.state, '__checks': checks};
    if (m.rawVotes != null) r['__votes'] = m.rawVotes;
    thread(conv).update({'id': m.id, 'reactions': r});
    try {
      await api.checklistToggle(conv, m.id, item, done);
    } catch (e) {
      thread(conv).update({'id': m.id, 'reactions': {...m.reactions, ...m.state}});
      rethrow;
    }
  }

  Future<void> addChecklistItems(String conv, Message m, List<String> items) => api.checklistAdd(conv, m.id, items);

  Future<void> sendReminder(String conv, String title, DateTime at, String note) async {
    final m = await api.sendReminder(conv, title, at.millisecondsSinceEpoch, note: note);
    thread(conv).add(m);
    final c = convs[conv];
    if (c != null) _conv(c.copyWith(lastTs: m.ts, lastText: _previewOf(m), lastMine: m.mine));
  }

  Future<void> cancelReminder(String conv, Message m) => api.reminderCancel(conv, m.id);

  Future<void> markReminderSeen(String conv, Message m, String me) async {
    final seen = Map<String, dynamic>.of((m.state['__seen'] as Map?)?.cast<String, dynamic>() ?? const {});
    seen[me] = DateTime.now().millisecondsSinceEpoch;
    thread(conv).update({'id': m.id, 'reactions': {...m.reactions, ...m.state, '__seen': seen}});
    await api.reminderSeen(conv, m.id);
  }

  /// Reminders that just went off (`reminder_due`), newest last — the in-app banner shows them.
  final ValueNotifier<List<Map<String, dynamic>>> dueReminders = ValueNotifier(const []);

  void onReminderDue(Map<String, dynamic> d) {
    final id = d['msg_id']?.toString();
    final cur = dueReminders.value.where((x) => x['msg_id']?.toString() != id).toList();
    dueReminders.value = [...cur, d];
  }

  void dismissReminder(String msgId) =>
      dueReminders.value = dueReminders.value.where((x) => x['msg_id']?.toString() != msgId).toList();

  List<ScheduledMessage> scheduled = const [];
  Future<void> loadScheduled() async {
    try {
      scheduled = await api.scheduledMessages();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> schedule(String conv, String text, DateTime at) async {
    await api.scheduleMessage(conv, text, at.millisecondsSinceEpoch);
    await loadScheduled();
  }

  Future<void> cancelScheduled(String id) async {
    scheduled = scheduled.where((x) => x.id != id).toList();
    notifyListeners();
    await api.cancelScheduled(id);
  }

  Future<void> setFlag(String conv, String flag, bool value) async {
    final c = convs[conv];
    if (c != null) {
      _conv(switch (flag) {
        'pinned' => c.copyWith(pinned: value),
        'archived' => c.copyWith(archived: value),
        _ => c.copyWith(muted: value),
      });
    }
    await api.convFlag(conv, flag, value);
  }

  Future<void> deleteConversation(String conv) async {
    await api.deleteConversation(conv);
    convs.remove(conv);
    _threads.remove(conv);
    _sorted = null;
    notifyListeners();
  }

  void setTtl(String conv, int ms) {
    ttlByConv[conv] = ms;
    notifyListeners();
  }

  /// Ensures a direct conversation exists locally (e.g. "Message" from friends).
  String ensureDirect(Contact c) {
    final id = 'd:${c.peer}';
    convs.putIfAbsent(id, () => Conversation(id: id, kind: ConvKind.direct, title: c.displayName, lastTs: DateTime.now().millisecondsSinceEpoch));
    _sorted = null;
    notifyListeners();
    return id;
  }
}

// ------------------------------------------------------------------ files

class FilesStore extends ChangeNotifier {
  FilesStore(this.api);
  final LumoraApi api;
  final Map<String, FileItem> byId = {};

  Future<void> load() async {
    final l = await api.files();
    byId
      ..clear()
      ..addEntries(l.map((f) => MapEntry(f.id, f)));
    notifyListeners();
  }

  List<FileItem> get sorted => byId.values.toList()..sort((a, b) => b.created.compareTo(a.created));
  int get activeCount => byId.values.where((f) => f.state == FileState.transferring).length;

  void onFile(Map<String, dynamic> j) {
    final f = FileItem.fromJson(j);
    byId[f.id] = f;
    notifyListeners();
  }

  Future<void> accept(String id) => api.acceptFile(id);
  Future<void> cancel(String id) => api.cancelFile(id);

  /// Pause/resume is a UI extension (`pause_file`), optimistic.
  Future<void> togglePause(String id) async {
    final f = byId[id];
    if (f == null) return;
    try {
      await api.request('pause_file', {'file_id': id});
    } catch (_) {
      byId[id] = f.copyWith(state: f.state == FileState.paused ? FileState.transferring : FileState.paused);
      notifyListeners();
    }
  }

  Future<void> send(String conv, String path) async {
    // PDF first page / first lines of code, so receivers see it before downloading
    final pv = await buildFilePreview(path);
    final f = await api.sendFile(conv, path, preview: pv);
    byId[f.id] = f;
    notifyListeners();
  }
}

// ------------------------------------------------------------------ calls

class CallStore extends ChangeNotifier {
  CallStore(this.api);
  final LumoraApi api;

  CallState? call;
  bool mic = true;
  bool cam = true;
  bool screen = false;
  bool speaker = true;
  bool minimized = false;
  bool handRaised = false;

  /// peer → screen-share stream (video_stream kind "screen").
  final Map<String, int> screenStreams = {};

  /// Set by `camera_needed` / `camera_released` (cleared when the call ends):
  /// `CameraBridge` runs the native camera (Android, iOS, macOS, Windows),
  /// which pushes frames into the core via lumora_push_camera_yuv.
  final ValueNotifier<bool> cameraRequested = ValueNotifier(false);
  bool chatOpen = false;
  final List<(int, String)> bursts = [];
  int _burstId = 0;

  void toggleChat() {
    chatOpen = !chatOpen;
    notifyListeners();
  }

  /// Local floating reaction (also sent as a message by the caller).
  void burst(String emoji) {
    final id = ++_burstId;
    bursts.add((id, emoji));
    notifyListeners();
    Timer(const Duration(milliseconds: 2300), () {
      bursts.removeWhere((b) => b.$1 == id);
      notifyListeners();
    });
  }

  void toggleHand() {
    handRaised = !handRaised;
    notifyListeners();
  }
  String? endedReason;

  /// The incoming call was answered on another of my devices (its name, may
  /// be empty); the incoming screen says so for a moment, then closes.
  String? answeredElsewhere;

  bool get incoming => call?.phase == CallPhase.incoming;
  bool get inCall => call != null && (call!.phase == CallPhase.active || call!.phase == CallPhase.ringing);

  Timer? _ringTimeout;

  /// Called when an unanswered incoming call times out (missed-call notice).
  void Function(CallState c)? onMissed;

  void onCall(Map<String, dynamic> j) {
    final c = CallState.fromJson(j);
    if (c.phase == CallPhase.incoming) {
      if (call?.callId != c.callId) answeredElsewhere = null;
      // The core sends "ended" when the caller gives up; this is only a
      // safety net in case that event is lost.
      _ringTimeout?.cancel();
      _ringTimeout = Timer(const Duration(seconds: 90), () {
        if (call?.callId == c.callId && call?.phase == CallPhase.incoming) {
          call = null;
          notifyListeners();
          onMissed?.call(c);
        }
      });
    } else if (c.callId == call?.callId) {
      _ringTimeout?.cancel();
    }
    if (call != null && call!.callId != c.callId && c.phase == CallPhase.incoming && inCall) {
      // Busy: auto decline second incoming call.
      api.callAnswer(c.callId, false);
      return;
    }
    if (c.phase == CallPhase.ended && j['reason'] == 'answered_elsewhere' && call?.callId == c.callId && call?.phase == CallPhase.incoming) {
      // Picked up on another of my devices: say so briefly, then dismiss.
      _ringTimeout?.cancel();
      answeredElsewhere = j['device_name']?.toString() ?? '';
      notifyListeners();
      Timer(const Duration(milliseconds: 2400), () {
        if (call?.callId != c.callId) return;
        call = null;
        answeredElsewhere = null;
        notifyListeners();
      });
      return;
    }
    if (c.phase == CallPhase.ended) {
      if (call?.callId == c.callId) {
        call = null;
        minimized = false;
        screen = false;
        videoNeedsPeerUpdate = false;
        videoCodec = null;
        peerMedia.clear();
        cameraRequested.value = false; // the core sends no camera_released on hang-up
      }
    } else {
      final prev = call;
      if (prev != null && prev.callId != c.callId) peerMedia.clear();
      call = CallState(
        callId: c.callId,
        conv: c.conv,
        peer: c.peer,
        phase: c.phase,
        video: c.video,
        participants: c.participants,
        accounts: c.accounts,
        names: c.names,
        streams: c.streams.isEmpty && prev != null && prev.callId == c.callId ? prev.streams : c.streams,
        // The core's call events carry no `started_at`: the caller learns the
        // call was picked up from the first `active` event — start the clock
        // there (the answerer sets it in [answer]), else the caller's call
        // screen says "Calling…" for the whole call.
        startedAt: c.startedAt ?? prev?.startedAt ?? (c.phase == CallPhase.active ? DateTime.now().millisecondsSinceEpoch : null),
        speaking: c.speaking,
        quality: c.quality,
      );
      if (prev == null) {
        cam = c.video;
        mic = true;
      }
    }
    notifyListeners();
  }

  /// The core could not pick a video format for this call: an older Lumora on
  /// the other side only takes H.264 and this device has none. Voice goes on.
  bool videoNeedsPeerUpdate = false;

  /// Format/backend/hardware of the video we receive (first decoded frame),
  /// e.g. ('h264', 'MediaCodec', true) — shown under the call-quality bars.
  (String, String, bool)? videoCodec;

  void onVideoNote(Map<String, dynamic> j) {
    final c = call;
    if (c == null || j['session'] != c.callId) return;
    if (j['reason'] == 'peer_needs_update' && !videoNeedsPeerUpdate) {
      videoNeedsPeerUpdate = true;
      notifyListeners();
    }
  }

  void onVideoFirstFrame(Map<String, dynamic> j) {
    final c = call;
    if (c == null || j['session'] != c.callId || j['camera'] != true) return;
    videoCodec = (j['codec']?.toString() ?? '', j['backend']?.toString() ?? '', j['hw'] == true);
    notifyListeners();
  }

  void onVideoStream(Map<String, dynamic> j) {
    final c = call;
    if (c == null || (j['call_id'] != null && j['call_id'] != c.callId)) return;
    final peer = j['peer']?.toString() ?? '';
    final stream = (j['stream'] as num?)?.toInt();
    if (j['kind'] == 'screen') {
      // Screen shares are shown separately from camera tiles.
      if (stream == null || stream < 0) {
        screenStreams.remove(peer);
      } else {
        screenStreams[peer] = stream;
      }
      notifyListeners();
      return;
    }
    final streams = Map<String, int>.of(c.streams);
    if (stream == null || stream < 0) {
      // A restarted camera announces its new stream before the old one says
      // goodbye: only drop the stream that actually ended.
      final ended = (j['ended_stream'] as num?)?.toInt();
      if (ended != null && streams[peer] != ended) return;
      streams.remove(peer);
    } else {
      streams[peer] = stream;
    }
    call = c.copyWith(streams: streams);
    notifyListeners();
  }

  /// Each participant's own mic / camera / screen state (`call_peer`, keyed
  /// by the participant's device key as in `participants`).
  final Map<String, ({bool mic, bool cam, bool screen})> peerMedia = {};

  void onCallPeer(Map<String, dynamic> j) {
    final c = call;
    if (c == null || j['call_id'] != c.callId) return;
    final peer = j['peer']?.toString() ?? '';
    if (peer.isEmpty) return;
    peerMedia[peer] = (mic: j['mic'] != false, cam: j['cam'] != false, screen: j['screen'] == true);
    notifyListeners();
  }

  /// Whether `participant` has muted their microphone (unknown: not muted).
  bool peerMuted(String participant) => peerMedia[participant]?.mic == false;

  /// Whether `participant` turned their camera off (unknown: on).
  bool peerCamOff(String participant) => peerMedia[participant]?.cam == false;

  /// Voice-channel calls stay minimised (Discord-style panel).
  bool isVoiceChannel(String conv) => conv.contains('#');

  Future<void> start(String conv, {bool video = false, bool minimized = false}) async {
    // Android: RECORD_AUDIO first (the core opens the microphone itself).
    // Refused: the call still goes ahead, honestly muted.
    final micOk = !MicPermission.needed || await MicPermission.ensure();
    cam = video;
    mic = micOk;
    this.minimized = minimized || isVoiceChannel(conv);
    final id = await api.callStart(conv, video: video);
    call ??= CallState(callId: id, conv: conv, peer: conv.startsWith('d:') ? conv.substring(2) : '', phase: CallPhase.ringing, video: video);
    notifyListeners();
    if (!micOk) unawaited(api.callSet(id, mic: false).catchError((_) {}));
  }

  Future<void> answer(bool accept) async {
    _ringTimeout?.cancel();
    var c = call;
    if (c == null) return;
    var micOk = true;
    if (accept && MicPermission.needed) {
      micOk = await MicPermission.ensure();
      // The caller may have given up while the permission prompt was open.
      if (call?.callId != c.callId) return;
      c = call!;
      mic = micOk;
    }
    if (!accept) {
      call = null;
    } else {
      // Optimistic: the core confirms with a `call` event.
      call = CallState(
        callId: c.callId,
        conv: c.conv,
        peer: c.peer,
        phase: CallPhase.active,
        video: c.video,
        participants: c.participants,
        streams: c.streams,
        startedAt: DateTime.now().millisecondsSinceEpoch,
        accounts: c.accounts,
        names: c.names,
      );
    }
    notifyListeners();
    try {
      await api.callAnswer(c.callId, accept, video: c.video);
      if (accept && !micOk) unawaited(api.callSet(c.callId, mic: false).catchError((_) {}));
    } catch (e) {
      if (!accept) return; // declining: the call is gone for us either way
      // Not answered (call already over, network, microphone): back to the
      // ringing screen if it is still ringing, and say why.
      if (call?.callId == c.callId) call = c.phase == CallPhase.incoming || c.phase == CallPhase.ringing ? c : null;
      answerError = e;
      notifyListeners();
    }
  }

  /// Why the last "Answer" failed (shown once by the call screen).
  Object? answerError;
  void clearAnswerError() {
    answerError = null;
    notifyListeners();
  }

  Future<void> hangup() async {
    _ringTimeout?.cancel();
    screenStreams.clear();
    final c = call;
    call = null;
    minimized = false;
    screen = false;
    cameraRequested.value = false;
    notifyListeners();
    if (c != null) await api.callEnd(c.callId);
  }

  Future<void> toggle({bool? mic, bool? cam, bool? screen}) async {
    if (mic != null) this.mic = mic;
    if (cam != null) this.cam = cam;
    if (screen != null) this.screen = screen;
    notifyListeners();
    final c = call;
    if (c != null) await api.callSet(c.callId, mic: mic, cam: cam, screen: screen);
  }

  void setMinimized(bool v) {
    minimized = v;
    notifyListeners();
  }

  void toggleSpeaker() {
    speaker = !speaker;
    notifyListeners();
  }
}

// ----------------------------------------------------------------- remote

class RemoteStore extends ChangeNotifier {
  RemoteStore(this.api);
  final LumoraApi api;

  RemoteStatus status = const RemoteStatus();
  RemoteRequest? request;

  /// Requests waiting behind [request] (the core keeps up to 8 pending): each
  /// is answered in turn instead of the newest silently replacing the first.
  final List<RemoteRequest> queued = [];
  RemoteState? viewer;

  /// The newest active host session (the "being controlled" banner).
  RemoteState? host;

  /// Every active host session: two viewers may control this device at once.
  final Map<String, RemoteState> hosts = {};

  void _dropHost(String session) {
    hosts.remove(session);
    if (host?.session == session) host = hosts.isEmpty ? null : hosts.values.last;
  }
  String? viewerPeerName;

  /// Names announced in accepted requests (for people who aren't contacts).
  final Map<String, String> requestNames = {};
  String? lastError;
  bool viewOnly = false;

  Future<void> load() async {
    status = await api.remoteStatus();
    notifyListeners();
  }

  // ------------------------------------------------ copy & paste sync
  //
  // While a session is active, text copied on either side lands in the
  // other side's clipboard (like RustDesk / UltraViewer):
  //  * incoming `clipboard` events are written to the local clipboard;
  //  * the local clipboard is polled every 700 ms while the app is in front
  //    (Android forbids background reads) and changes are sent to every
  //    active session's partner;
  //  * [_lastSynced] remembers the text that just crossed so it is never
  //    echoed back (no ping-pong).

  /// User setting (Settings › Remote access).
  bool clipboardSync = true;

  /// Bumped after each sync, for the small "Synced" chip on the viewer.
  final ValueNotifier<int> clipboardPulse = ValueNotifier(0);

  static const int clipboardMax = 1 << 20;
  static const Duration clipboardPollEvery = Duration(milliseconds: 700);

  String? _lastSynced;
  String? _lastSeen;
  Timer? _clipTimer;
  bool _clipBusy = false;

  /// Text that last crossed between the two devices (tests / diagnostics).
  String? get lastSyncedClipboard => _lastSynced;

  /// Control rights of the active sessions (from `remote_state.control`).
  /// Clipboard sync belongs to control: a view-only session never shares
  /// the clipboard in either direction (the core refuses it too).
  bool _viewerControl = false;
  bool _hostControl = false;

  bool get _viewerActive => viewer != null && viewer!.phase == RemotePhase.active;
  bool get _viewerSync => _viewerActive && _viewerControl;
  bool get _hostSync => host != null && _hostControl;
  bool get _sessionActive => _viewerSync || _hostSync;

  void setClipboardSync(bool on) {
    if (clipboardSync == on) return;
    clipboardSync = on;
    _updateClipboardPoll();
  }

  void _updateClipboardPoll() {
    final want = clipboardSync && _sessionActive;
    if (want && _clipTimer == null) {
      _lastSeen = null; // first read only records the current text
      _clipTimer = Timer.periodic(clipboardPollEvery, (_) => pollClipboard());
    } else if (!want && _clipTimer != null) {
      _clipTimer!.cancel();
      _clipTimer = null;
      _lastSeen = null;
      _lastSynced = null;
    }
  }

  /// Phones only allow clipboard reads while the app is in front; desktop
  /// hosts are usually driven while Lumora sits in the background, so they
  /// keep polling.
  static bool get _inFront {
    final mobile = !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
    if (!mobile) return true;
    final st = SchedulerBinding.instance.lifecycleState;
    return st == null || st == AppLifecycleState.resumed;
  }

  /// One poll step (public for tests).
  Future<void> pollClipboard() async {
    if (_clipBusy || !clipboardSync || !_sessionActive || !_inFront) return;
    _clipBusy = true;
    try {
      final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (t == null || t.isEmpty) return;
      if (_lastSeen == null) {
        _lastSeen = t;
        return;
      }
      if (t == _lastSeen) return;
      _lastSeen = t;
      if (t == _lastSynced) return;
      await _pushClipboard(t);
    } catch (_) {
      // Clipboard unavailable (background / permission): try again later.
    } finally {
      _clipBusy = false;
    }
  }

  /// Viewer: the remote screen got focus → offer what was just copied here.
  Future<void> pushClipboardOnFocus() async {
    if (!clipboardSync || !_sessionActive) return;
    try {
      final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (t == null || t.isEmpty || t == _lastSynced) return;
      _lastSeen = t;
      await _pushClipboard(t);
    } catch (_) {}
  }

  Future<bool> _pushClipboard(String text) async {
    if (text.length > clipboardMax) return false;
    final sessions = <String>[if (_viewerSync) viewer!.session, if (_hostSync) host!.session];
    if (sessions.isEmpty) return false;
    _lastSynced = text;
    var ok = false;
    for (final s in sessions) {
      try {
        await api.remoteClipboard(s, text);
        ok = true;
      } catch (_) {}
    }
    if (ok) clipboardPulse.value++;
    return ok;
  }

  /// Core event `clipboard` {peer, text}: the partner copied something.
  Future<void> onClipboard(Map<String, dynamic> j) async {
    if (!clipboardSync) return;
    final peer = j['peer']?.toString() ?? '';
    final text = j['text']?.toString() ?? '';
    if (text.isEmpty || text.length > clipboardMax) return;
    final fromViewerPeer = _viewerSync && (viewer!.peer.isEmpty || viewer!.peer == peer);
    final fromHostPeer = _hostSync && host!.peer == peer;
    if (!fromViewerPeer && !fromHostPeer) return;
    if (text == _lastSynced && text == _lastSeen) return;
    _lastSynced = text;
    _lastSeen = text;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      clipboardPulse.value++;
    } catch (_) {}
  }

  /// Manual fallback ("Send copied text").
  Future<void> sendClipboardNow() async {
    final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (t == null || t.isEmpty) throw StateError('empty');
    _lastSeen = t;
    if (!await _pushClipboard(t)) throw StateError('not_sent');
  }

  void stopClipboardSync() {
    _clipTimer?.cancel();
    _clipTimer = null;
  }

  @override
  void notifyListeners() {
    _updateClipboardPoll();
    super.notifyListeners();
  }

  static String randomPassword() {
    const chars = 'abcdefghjkmnpqrstuvwxyz23456789';
    final r = math.Random.secure();
    return List.generate(8, (_) => chars[r.nextInt(chars.length)]).join();
  }

  Future<void> refreshPassword() async {
    final pw = randomPassword();
    status = status.copyWith(password: pw);
    notifyListeners();
    await api.remoteSet(password: pw);
  }

  Future<void> setUnattended(bool v) async {
    status = status.copyWith(unattended: v);
    notifyListeners();
    await api.remoteSet(unattended: v);
  }

  Future<void> setAllowPower(bool v) async {
    status = status.copyWith(allowPower: v);
    notifyListeners();
    await api.remoteAllowPower(v);
  }

  Future<void> setAllowControl(bool v) async {
    status = status.copyWith(allowControl: v);
    notifyListeners();
    await api.remoteSet(allowControl: v);
  }

  /// [device]: which of the target account's computers (see `err.choose_device`).
  Future<void> connect(String id, String password, {bool viewOnly = false, String? peerName, String? device}) async {
    lastError = null;
    this.viewOnly = viewOnly;
    viewerPeerName = peerName;
    final s = await api.remoteConnect(id, password, viewOnly: viewOnly, device: device);
    viewer = RemoteState(session: s, peer: id.length == 52 ? id : '', phase: RemotePhase.connecting);
    notifyListeners();
    // Fallback only: if the host never answers (offline / request lost), stop
    // waiting. Without a password the host is asked to accept, so allow
    // time for a person to respond.
    Timer(Duration(seconds: password.isEmpty ? 60 : 25), () {
      if (viewer?.session == s && viewer?.phase == RemotePhase.connecting) {
        lastError = 'timeout';
        end(s);
      }
    });
  }

  Future<void> respond({required bool accept, bool control = true, bool trust = false}) async {
    final r = request;
    if (r == null) return;
    request = queued.isEmpty ? null : queued.removeAt(0); // the next one waiting
    if (accept && r.name.isNotEmpty) {
      requestNames[r.peer] = r.name;
      requestNames[r.account] = r.name;
    }
    notifyListeners();
    await api.remoteRespond(r.session, accept: accept, control: control);
    if (accept && trust) await api.remoteTrust(r.peer, true);
  }

  int display = 0;
  Future<void> setDisplay(int index) async {
    display = index;
    notifyListeners();
    final s = viewer?.session;
    if (s != null) await api.remoteDisplay(s, index);
  }

  Future<void> sendClipboard(String text) async {
    final s = viewer?.session;
    if (s != null) await api.remoteClipboard(s, text);
  }

  /// Error code from core: input_unavailable | capture_unavailable | mic_unavailable.
  String? errorCode;
  void onErrorCode(String code) {
    errorCode = code;
    notifyListeners();
  }

  void clearErrorCode() {
    errorCode = null;
    notifyListeners();
  }

  Future<void> end(String session) async {
    if (viewer?.session == session) {
      if (viewer!.peer.isNotEmpty) {
        endedPeer = viewer!.peer;
        Timer(const Duration(seconds: 10), () {
          if (endedPeer != null) clearEnded();
        });
      }
      viewer = null;
    }
    _dropHost(session);
    notifyListeners();
    await api.remoteEnd(session);
  }

  void onRequest(Map<String, dynamic> j) {
    final r = RemoteRequest.fromJson(j);
    if (request == null || request!.session == r.session) {
      request = r;
    } else if (!queued.any((q) => q.session == r.session)) {
      queued.add(r);
    }
    notifyListeners();
  }

  /// Peer of the last viewer session that ended (for "Send file / Chat").
  String? endedPeer;
  void clearEnded() {
    endedPeer = null;
    notifyListeners();
  }

  /// Why this device's last host session failed (plain words), shown once
  /// instead of the "being controlled" banner.
  String? hostError;
  void clearHostError() {
    hostError = null;
    notifyListeners();
  }

  void onState(Map<String, dynamic> j) {
    final s = RemoteState.fromJson(j);
    final failed = s.phase == RemotePhase.failed;
    final ended = s.phase == RemotePhase.ended || s.phase == RemotePhase.denied || failed;
    if (failed && !s.viewer) {
      // e.g. screen capture failed: nobody is controlling this device any
      // more — no red banner, no clipboard polling, just the reason.
      final reason = j['reason']?.toString() ?? '';
      hostError = reason.isNotEmpty && (j['code']?.toString() ?? '').startsWith('err.') ? reason : 'capture_failed';
    }
    if (s.phase == RemotePhase.ended && s.viewer && viewer?.session == s.session) {
      endedPeer = viewer!.peer.isNotEmpty ? viewer!.peer : s.peer;
      Timer(const Duration(seconds: 10), () {
        if (endedPeer != null) clearEnded();
      });
    }
    if (!ended && s.phase == RemotePhase.active) {
      if (s.viewer) {
        if (viewer == null || viewer!.session == s.session) _viewerControl = j['control'] == true;
      } else {
        _hostControl = j['control'] == true;
      }
    }
    if (s.viewer) {
      if (viewer == null || viewer!.session == s.session) {
        if (s.phase == RemotePhase.denied || failed) {
          // the core sends a plain, localized reason with an `err.*` code
          final reason = j['reason']?.toString() ?? '';
          lastError = (j['code']?.toString() ?? '').startsWith('err.') && reason.isNotEmpty ? reason : 'denied';
        }
        viewer = ended ? null : s;
      }
    } else if (ended) {
      _dropHost(s.session); // another viewer may still be in control
    } else {
      hosts[s.session] = s;
      host = s;
    }
    if (ended) queued.removeWhere((r) => r.session == s.session);
    if (ended && request?.session == s.session) request = queued.isEmpty ? null : queued.removeAt(0);
    if (ended) _dropHost(s.session);
    notifyListeners();
  }

  void clearError() {
    lastError = null;
    notifyListeners();
  }
}

// ---------------------------------------------------------------- stories

class StoryStore extends ChangeNotifier {
  StoryStore(this.api);
  final LumoraApi api;
  List<Story> stories = const [];
  final Map<String, Uint8List?> images = {};

  Future<void> load() async {
    try {
      stories = await api.stories();
      notifyListeners();
    } catch (_) {}
  }

  /// author -> stories (oldest first), authors with unseen first.
  List<MapEntry<String, List<Story>>> byAuthor(String me) {
    final m = <String, List<Story>>{};
    for (final s in stories) {
      (m[s.author] ??= []).add(s);
    }
    for (final l in m.values) {
      l.sort((a, b) => a.created.compareTo(b.created));
    }
    final list = m.entries.where((e) => e.key != me).toList()
      ..sort((a, b) {
        final ua = a.value.any((s) => !s.seen), ub = b.value.any((s) => !s.seen);
        if (ua != ub) return ua ? -1 : 1;
        return b.value.last.created.compareTo(a.value.last.created);
      });
    return list;
  }

  List<Story> mine(String me) => stories.where((s) => s.author == me).toList()..sort((a, b) => a.created.compareTo(b.created));

  Future<Uint8List?> image(String id) async {
    if (images.containsKey(id)) return images[id];
    try {
      final b = _decodeB64(await api.storyImage(id));
      images[id] = b != null && isSafeImageBytes(b) ? b : null;
    } catch (_) {
      images[id] = null;
    }
    return images[id];
  }

  void seen(String id) {
    final i = stories.indexWhere((s) => s.id == id);
    if (i < 0 || stories[i].seen) return;
    stories = [...stories]..[i] = stories[i].markSeen();
    notifyListeners();
    api.storySeen(id).catchError((_) {});
  }

  Future<void> post({String? text, String? imagePath, String? bg}) async {
    await api.postStory(text: text, imagePath: imagePath, bg: bg);
    await load();
  }

  void onStory(Map<String, dynamic> j) {
    final s = Story.fromJson(j);
    stories = [...stories.where((x) => x.id != s.id), s];
    notifyListeners();
  }
}

// ---------------------------------------------------------- notifications

enum NoticeKind { mention, friendRequest, missedCall, file, remote, system, reminder, scheduledFailed, storageLow, report }

class Notice {
  Notice({required this.kind, required this.title, this.body = '', this.conv, this.peer, this.ref, int? ts})
      : ts = ts ?? DateTime.now().millisecondsSinceEpoch;
  final NoticeKind kind;
  final String title;
  final String body;
  final String? conv;
  final String? peer;

  /// What the notice is about when it can be handled elsewhere (report id).
  final String? ref;
  final int ts;
  bool read = false;
}

class NotificationStore extends ChangeNotifier {
  final List<Notice> items = [];
  int get unread => items.where((n) => !n.read).length;

  /// Rewrites a notice before it is listed (e.g. hides locked chats).
  Notice Function(Notice n)? filter;

  void add(Notice n) {
    n = filter?.call(n) ?? n;
    items.insert(0, n);
    if (items.length > 100) items.removeLast();
    notifyListeners();
  }

  /// Drops the notices about [refs] (e.g. reports handled on another device).
  void removeRefs(Set<String> refs) {
    final before = items.length;
    items.removeWhere((n) => n.ref != null && refs.contains(n.ref));
    if (items.length != before) notifyListeners();
  }

  void markAllRead() {
    for (final n in items) {
      n.read = true;
    }
    notifyListeners();
  }

  void clear() {
    items.clear();
    notifyListeners();
  }
}

// -------------------------------------------------------------------- net

class NetStore extends ChangeNotifier {
  NetStore(this.api);
  final LumoraApi api;

  NetStatus? net;
  Diagnostics? diagnostics;
  Map<String, dynamic>? storage;
  bool loadingDiag = false;

  Future<void> load() async {
    net = await api.netStatus();
    notifyListeners();
  }

  void onNet(Map<String, dynamic> j) {
    net = NetStatus.fromJson(j);
    notifyListeners();
  }

  Future<void> runDiagnostics() async {
    loadingDiag = true;
    notifyListeners();
    try {
      diagnostics = await api.diagnostics();
      net = await api.netStatus();
    } finally {
      loadingDiag = false;
      notifyListeners();
    }
  }

  Future<void> loadStorage() async {
    storage = await api.storageStats();
    notifyListeners();
  }

  Future<void> maintain() async {
    await api.maintain();
    await loadStorage();
  }

  /// Bytes Lumora uses on disk (database + downloaded media).
  static int usedBytes(Map<String, dynamic>? st) =>
      ((st?['db_bytes'] as num?)?.toInt() ?? 0) + ((st?['media_bytes'] as num?)?.toInt() ?? 0);

  /// "Clean up now": housekeeping + the media policy. Returns the bytes freed.
  Future<int> cleanUp() async {
    final before = usedBytes(storage ?? await api.storageStats());
    await api.maintain();
    try {
      // Re-saving the policy applies it (old / over-limit media is removed).
      final p = await api.storagePolicy();
      await api.setStoragePolicy(p.toJson());
    } catch (_) {}
    await loadStorage();
    final freed = before - usedBytes(storage);
    return freed < 0 ? 0 : freed;
  }

  /// Removes downloaded media ([conv] null = all chats). Returns the bytes freed.
  Future<int> clearMedia({String? conv}) async {
    final r = await api.clearMedia(conv: conv);
    await loadStorage();
    return (r['freed_bytes'] as num?)?.toInt() ?? 0;
  }

  Future<StoragePolicy> setStoragePolicy(Map<String, int> values) async {
    final p = await api.setStoragePolicy(values);
    final st = storage;
    if (st != null) storage = {...st, 'policy': p.toJson()};
    notifyListeners();
    // Applying a stricter policy may have freed space.
    loadStorage().catchError((_) {});
    return p;
  }
}

// ----------------------------------------------------------------- spaces

class SpacesStore extends ChangeNotifier {
  SpacesStore(this.api);
  final LumoraApi api;
  List<Space> spaces = const [];

  /// channel conv -> participants override after join/leave.
  final Map<String, List<String>> voice = {};
  String? joinedVoice;

  Future<void> load() async {
    spaces = await api.spaces();
    for (final s in spaces) {
      for (final c in s.channels) {
        if (c.voice) voice[c.conv] = List.of(c.participants);
      }
    }
    notifyListeners();
  }

  Space? byId(String? id) {
    for (final s in spaces) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> toggleVoice(String conv, String me) async {
    final joining = joinedVoice != conv;
    if (joinedVoice != null) voice[joinedVoice!]?.remove(me);
    joinedVoice = joining ? conv : null;
    if (joining) (voice[conv] ??= []).add(me);
    notifyListeners();
    try {
      await api.voiceJoin(conv, joining);
    } catch (_) {}
  }
}

// -------------------------------------------------------------- navigation

enum Section { chats, friends, space, remote, files, network, settings }

class NavStore extends ChangeNotifier {
  Section section = Section.chats;
  String? conv;
  String? spaceId;
  String? channelConv;
  bool infoPanel = false;

  void go(Section s, {String? space}) {
    section = s;
    if (space != null) spaceId = space;
    notifyListeners();
  }

  void openConv(String? id) {
    conv = id;
    if (id != null && section != Section.space) section = Section.chats;
    notifyListeners();
  }

  /// Chat views on screen right now (oldest first; a chat can be open twice).
  final List<String> _shown = [];

  /// Whether new messages may be marked read now (app in front, not locked,
  /// chat not hidden). Set by AppServices.
  bool Function(String conv) canRead = (_) => true;

  bool isShown(String conv) => _shown.contains(conv);

  /// A [ChatView] for [conv] was built.
  void chatShown(String conv) => _shown.add(conv);

  /// A [ChatView] for [conv] went away. [pushed]: it was its own page (phone
  /// layout), so leaving it also leaves the conversation: [conv] falls back
  /// to the chat still open below (if any), never to the one just closed.
  void chatHidden(String conv, {required bool pushed}) {
    final i = _shown.lastIndexOf(conv);
    if (i >= 0) _shown.removeAt(i);
    if (!pushed || this.conv != conv || _shown.contains(conv)) return;
    this.conv = _shown.isEmpty ? null : _shown.last;
    // Called from State.dispose (tree locked): notify once the frame is done.
    scheduleMicrotask(notifyListeners);
  }

  /// The conversation whose new messages count as read on arrival, or null.
  String? get readingConv {
    final open = section == Section.space ? channelConv : (section == Section.chats ? conv : null);
    if (open == null || !_shown.contains(open) || !canRead(open)) return null;
    return open;
  }

  void openChannel(String space, String conv) {
    section = Section.space;
    spaceId = space;
    channelConv = conv;
    notifyListeners();
  }

  void toggleInfo([bool? v]) {
    infoPanel = v ?? !infoPanel;
    notifyListeners();
  }
}

// --------------------------------------------------------------- event hub

/// Routes core events to the stores.
class EventHub {
  EventHub({
    required this.api,
    required this.session,
    required this.contacts,
    required this.chat,
    required this.files,
    required this.calls,
    required this.remote,
    required this.net,
    required this.spaces,
    required this.nav,
    required this.avatars,
    required this.notices,
    required this.stories,
  });

  final StoryStore stories;

  final AvatarStore avatars;
  final NotificationStore notices;

  final LumoraApi api;
  final SessionStore session;
  final ContactsStore contacts;
  final ChatStore chat;
  final FilesStore files;
  final CallStore calls;
  final RemoteStore remote;
  final NetStore net;
  final SpacesStore spaces;
  final NavStore nav;
  StreamSubscription<Map<String, dynamic>>? _sub;
  final errors = StreamController<String>.broadcast();

  /// Extra handlers that see every event (multi-device store, core restarts).
  final List<void Function(String name, Map<String, dynamic> data)> listeners = [];

  /// Extra stores loaded with the others (after unlock / a core restart).
  final List<Future<void> Function()> loaders = [];

  /// Members whose messages I hide: no mention notices from them either.
  bool Function(String peer)? isHiddenMember;

  void attach() {
    _sub ??= api.events.listen(_on);
  }

  Future<void> loadAll() async {
    await Future.wait<void>([
      contacts.load(),
      chat.load(),
      files.load(),
      remote.load().catchError((_) {}),
      net.load().catchError((_) {}),
      stories.load(),
      for (final l in loaders) l().catchError((_) {}),
      spaces.load().then((_) {
        chat.communityConvs = {
          for (final s in spaces.spaces)
            for (final c in s.channels) c.conv.split('#').first,
        };
      }).catchError((_) {}),
    ]);
  }

  void _on(Map<String, dynamic> raw) {
    final e = ApiEvent.parse(raw);
    final d = e.data;
    for (final l in List.of(listeners)) {
      l(e.name, d);
    }
    switch (e.name) {
      case 'ready':
        break;
      case 'net':
        net.onNet(d);
      case 'presence':
        contacts.onPresence(d);
      case 'contact':
        contacts.onContact(d);
        if (d['has_avatar'] == true) {
          avatars.invalidate(d['peer']?.toString() ?? '');
        } else if (d['has_avatar'] == false) {
          avatars.cleared(d['peer']?.toString() ?? ''); // removed: no stale picture
        }
      case 'friend_request':
        contacts.onFriendRequest(d);
        notices.add(Notice(kind: NoticeKind.friendRequest, title: d['name']?.toString() ?? '', body: d['note']?.toString() ?? '', peer: d['peer']?.toString()));
      case 'mention':
        final conv = d['conv']?.toString();
        final c = conv == null ? null : chat.convs[conv];
        // the chat on screen reads it: no badge, no bell
        if (conv != null && conv == nav.readingConv) break;
        if (c != null) chat.onConversation({'id': c.id, 'kind': c.isGroup ? 1 : 0, 'community': c.isCommunity, 'title': c.title, 'last_ts': c.lastTs, 'unread': c.unread, 'muted': c.muted, 'pinned': c.pinned, 'last_text': c.lastText, 'last_mine': c.lastMine, 'archived': c.archived, 'mentions': c.mentions + 1});
        if (c != null && c.muted) break;
        if (isHiddenMember?.call(d['author']?.toString() ?? '') ?? false) break;
        notices.add(Notice(
          kind: NoticeKind.mention,
          title: contacts.nameOf(d['author']?.toString() ?? d['peer']?.toString() ?? ''),
          body: d['text']?.toString() ?? d['body']?.toString() ?? '',
          conv: conv,
        ));
      case 'video_stream':
        calls.onVideoStream(d);
      case 'video_note':
        calls.onVideoNote(d);
      case 'video_first_frame':
        calls.onVideoFirstFrame(d);
      case 'camera_needed':
        calls.cameraRequested.value = true;
      case 'camera_released':
        calls.cameraRequested.value = false;
      case 'story':
        if (d.containsKey('created')) {
          stories.onStory(d);
        } else {
          stories.load(); // real core sends only {author, id}
        }
      case 'message':
        // Only a chat that is really on screen (app in front, not locked)
        // reads new messages; a chat left on a phone no longer does.
        chat.onMessage(d, myPeer: session.me?.peer ?? '', openConv: nav.readingConv);
      case 'message_update':
        chat.onMessageUpdate(d);
      case 'conversation_removed':
        chat.onConversationRemoved(d['conv']?.toString() ?? '');
      case 'history_cleared':
        chat.onHistoryCleared(d['conv']?.toString() ?? '');
      case 'reminder_due':
        chat.onReminderDue(d);
        notices.add(Notice(kind: NoticeKind.reminder, title: d['title']?.toString() ?? '', body: d['note']?.toString() ?? '', conv: d['conv']?.toString()));
      case 'conversation':
        chat.onConversation(d);
        if ((d['id']?.toString() ?? '').contains('#')) _reloadSpaces();
      case 'typing':
        chat.onTyping(d);
      case 'file':
        final known = files.byId.containsKey(d['id']);
        files.onFile(d);
        final fconv = d['conv']?.toString();
        final quiet = fconv != null && (fconv == nav.readingConv || (chat.convs[fconv]?.muted ?? false));
        if (!known && !quiet && d['direction'] == 1 && d['state'] == 0) {
          notices.add(Notice(kind: NoticeKind.file, title: contacts.nameOf(d['peer']?.toString() ?? ''), body: d['name']?.toString() ?? '', conv: d['conv']?.toString()));
        }
      case 'call':
        final prev = calls.call;
        calls.onCall(d);
        if (d['state'] == 'ended') AppleAudio.endCall(); // the other side hung up
        AppleServices.instance.onCallEvent(d);
        // (answered or declined on another of my devices: not missed)
        final elsewhere = d['reason'] == 'answered_elsewhere' || d['reason'] == 'declined_elsewhere';
        if (d['reason'] == 'busy' && d['state'] == 'ended') {
          // it rang while this device was in another call
          final from = d['from']?.toString() ?? '';
          notices.add(Notice(kind: NoticeKind.missedCall, title: contacts.nameOf(from), conv: d['conv']?.toString(), peer: from));
        }
        if (d['state'] == 'ended' && !elsewhere && prev?.phase == CallPhase.incoming && prev?.callId == d['call_id']) {
          notices.add(Notice(kind: NoticeKind.missedCall, title: contacts.nameOf(prev!.peer), conv: prev.conv, peer: prev.peer));
        }
      case 'remote_request':
        remote.onRequest(d);
        // a stranger's self-chosen name is quoted (it may imitate a friend)
        // (by account: a friend's — or my own — linked device has its own key)
        final rp = d['account']?.toString() ?? d['peer']?.toString() ?? '';
        final rc = contacts[rp];
        final known = d['own'] == true || (rc != null && rc.status == ContactStatus.friend);
        final rname = known && rc != null ? contacts.nameOf(rp) : (known ? '${d['name'] ?? ''}' : '"${d['name'] ?? ''}"');
        notices.add(Notice(kind: NoticeKind.remote, title: rname, peer: rp));
      case 'call_peer':
        calls.onCallPeer(d);
      case 'remote_state':
        remote.onState(d);
      case 'clipboard':
        remote.onClipboard(d);
      case 'group':
        _reloadSpaces();
        final gid = d['gid']?.toString() ?? '';
        if (d['members'] is List) {
          for (final m in d['members'] as List) {
            if (m is Map) PeerNames.learn(m['peer']?.toString() ?? '', m['name']?.toString());
          }
        }
        if (gid.isNotEmpty) {
          avatars.refreshGroup(gid, hasAvatar: d['has_avatar'] is bool ? d['has_avatar'] as bool : null);
          chat.onGroup(gid, name: d['name']?.toString(), member: d['my_role'] == null ? null : d['my_role'] != 'none');
        }
      case 'group_removed':
        final gconv = d['conv']?.toString() ?? (d['gid'] != null ? 'g:${d['gid']}' : '');
        if (gconv.isNotEmpty) chat.onGroupRemoved(gconv, left: d['left'] == true);
      case 'profile':
        // (name / bio / avatar: reloaded by AppServices._onDeviceEvent) — the
        // cached picture of my own avatar goes with it
        final mine = session.me?.peer;
        if (mine != null && (d['key']?.toString() ?? '').contains('avatar')) avatars.invalidate(mine);
      case 'scheduled_failed':
        // (the chat gets its own line from the core; this is the bell)
        notices.add(Notice(kind: NoticeKind.scheduledFailed, title: d['text']?.toString() ?? '', body: d['error']?.toString() ?? '', conv: d['conv']?.toString()));
      case 'storage_low':
        // (checked every 10 min while low: say it once in a while, not every time)
        final now = DateTime.now();
        if (_storageWarned == null || now.difference(_storageWarned!) > const Duration(hours: 6)) {
          _storageWarned = now;
          final msg = d['message']?.toString() ?? '';
          notices.add(Notice(kind: NoticeKind.storageLow, title: msg));
        }
      case 'group_flood':
        chat.floods.onEvent(d);
      case 'error':
        final code = d['code']?.toString();
        if (code == 'input_unavailable' || code == 'capture_unavailable' || code == 'mic_unavailable') {
          remote.onErrorCode(code!);
        } else {
          errors.add(d['message']?.toString() ?? 'error');
        }
    }
  }

  DateTime? _storageWarned;

  Timer? _spacesDebounce;
  void _reloadSpaces() {
    _spacesDebounce?.cancel();
    _spacesDebounce = Timer(const Duration(milliseconds: 600), () {
      spaces.load().then((_) {
        chat.setCommunityConvs({
          for (final s in spaces.spaces)
            for (final c in s.channels) c.conv.split('#').first,
        });
      }).catchError((_) {});
    });
  }

  void dispose() {
    _spacesDebounce?.cancel();
    _sub?.cancel();
    errors.close();
  }
}
