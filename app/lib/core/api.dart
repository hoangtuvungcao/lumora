// Lumora core API contract (see docs/src/dev/api.md).
//
// The UI talks to the Rust core exclusively through [LumoraApi]: JSON
// requests (`request`), pushed JSON events (`events`) and raw RGBA video
// frames (`frame`). Typed models below are parsed from the documented JSON
// shapes and are tolerant to missing fields so that the UI keeps working
// while the core evolves.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import '../platform/apple_audio.dart';
import '../platform/apple_services.dart';
import 'file_preview.dart';
import 'file_safety.dart';

/// Thrown when the core answers `{"ok": false, "error", "code"?, "detail"?}`.
///
/// [message] is plain, localized text for the user. [code] is a stable key
/// (`err.wrong_passphrase`, `internal`, …) and [detail] holds technical
/// information that must only appear under "Technical details".
class ApiException implements Exception {
  ApiException(this.message, {this.cmd, this.code, this.detail}) {
    if (detail != null && detail!.isNotEmpty) last = this;
    if (code != null && code!.startsWith('err.')) lastCoded = this;
  }

  /// From a core error object (`{"error", "code", "detail"}`).
  factory ApiException.fromJson(Map j, {String? cmd}) => ApiException(
        (j['error'] ?? 'internal').toString(),
        cmd: cmd,
        code: j['code']?.toString(),
        detail: j['detail']?.toString(),
      );

  final String message;
  final String? cmd;
  final String? code;
  final String? detail;

  /// The most recent exception that carried technical details, so a toast
  /// showing its [message] can offer a "Technical details" action.
  static ApiException? last;

  /// The most recent exception with a user-facing code (`err.*`), so a toast
  /// showing its [message] can use the app's own wording for that code.
  static ApiException? lastCoded;

  /// The `err.*` code of a [message] shown just now, if any.
  static String? codeFor(String message) {
    final l = lastCoded;
    return l != null && l.message == message ? l.code : null;
  }

  /// Technical details for a [message] shown just now, if any.
  static String? detailFor(String message) {
    final l = last;
    if (l == null || l.message != message) return null;
    final cmd = l.cmd == null ? '' : '${l.cmd}: ';
    return '$cmd${l.code == null ? '' : '[${l.code}] '}${l.detail}';
  }

  @override
  String toString() => message;
}

/// A decoded RGBA frame copied out of the core (`lumora_frame`).
class FrameData {
  const FrameData(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;
}

abstract class LumoraApi {
  /// True for the in-memory demo implementation.
  bool get isMock;

  /// Starts the node with a config map (see "Config" in api.md).
  /// Throws [ApiException] on failure (e.g. wrong passphrase).
  Future<void> start(Map<String, dynamic> config);

  /// Sends `{"cmd": cmd, ...args}` and returns the `data` field
  /// (a `Map`, a `List` or `null`). Throws [ApiException] when `ok == false`.
  Future<dynamic> request(String cmd, [Map<String, dynamic> args = const {}]);

  /// Pushed events: `{"event": name, ...payload}` (payload may also be nested
  /// under `data`; use [ApiEvent.parse]).
  Stream<Map<String, dynamic>> get events;

  /// Latest decoded RGBA frame for a media stream, or null if none is new.
  Future<FrameData?> frame(int stream);

  Future<void> stop();

  /// `lumora_needs_passphrase(data_dir)`: 1 = locked identity, 0 = identity
  /// without passphrase, -1 = no identity yet (onboarding). Null if unknown.
  Future<int?> needsPassphrase(String dataDir) async => null;

  /// `lumora_phrase_matches(data_dir, phrase)`: does a recovery phrase belong to
  /// the locked identity in [dataDir]? true / false; null = can't tell (older
  /// data, invalid phrase or older core).
  Future<bool?> phraseMatches(String dataDir, String phrase) async => null;

  // ---------------------------------------------------------------------
  // Typed convenience wrappers.
  // ---------------------------------------------------------------------

  Future<Me> me() async => Me.fromJson(_map(await request('me')));
  Future<void> setName(String name) => request('set_name', {'name': name});
  /// Only on the main device; a linked device gets `err.phrase_on_primary`.
  Future<String> recoveryPhrase() async =>
      _map(await request('recovery_phrase'))['phrase'] as String? ?? '';

  /// Does [phrase] belong to this account? Works on linked devices too (the
  /// core derives the account from the phrase). Null = older core without
  /// `phrase_check` (callers fall back to comparing on the main device).
  Future<bool?> phraseCheck(String phrase) async {
    try {
      return _map(await request('phrase_check', {'phrase': phrase}))['matches'] == true;
    } on ApiException catch (e) {
      if (e.message.startsWith('unknown command') || e.code == 'err.unknown_command') return null;
      rethrow;
    }
  }

  /// Is [passphrase] this device's data password? (re-confirm before
  /// showing secrets). Throws `err.wrong_passphrase` when it isn't.
  Future<bool> checkPassphrase(String passphrase) async =>
      _map(await request('check_passphrase', {'passphrase': passphrase}))['ok'] == true;

  // ------------------------------------------------- my devices (multi-device)
  // docs/src/dev/multi-device.md §8. Linking: the device that already uses the
  // account shows a QR + 12-digit code (`link_invite`); the new device, started
  // with `link_pending: true`, scans it (`link_scan`); the existing device then
  // approves (`link_approve`). Events: `link_request {device, name, kind, os,
  // path}` (on the existing device), `link_state {state, reason?, code?, device?}`
  // (awaiting_approval | approved | restart | code_rotated | failed | cancelled),
  // `devices`, `contact_devices {peer, devices}`, `history_sync {messages,
  // convs_done, convs_total, done}`, `device_revoked {device, wipe, by_self?}`.
  // On `link_state: restart` the implementation stops and starts the core again
  // (same config, `link_pending: false`) and then emits `core_restarted {reason}`.

  /// This account's devices (`primary`, `this`, `online`, `last_seen`…).
  Future<DeviceList> devices() async => DeviceList.fromJson(_map(await request('devices')));

  /// Rename a device (main device only, else `err.primary_only`).
  Future<DeviceList> deviceRename(String device, String name) async =>
      DeviceList.fromJson(_map(await request('device_rename', {'device': device, 'name': name})));

  /// Sign another device out of the account (main device only). [wipeMedia]
  /// also deletes the photos and files downloaded on it.
  Future<DeviceList> deviceRevoke(String device, {bool wipeMedia = false}) async =>
      DeviceList.fromJson(_map(await request('device_revoke', {'device': device, 'wipe_media': wipeMedia})));

  /// Main device: own devices missing from the account's list (the account was
  /// restored here with the recovery phrase) that asked to be listed again
  /// (`device_relist_request {device, name, kind, short_id}`).
  Future<List<RelistRequest>> deviceRelistRequests() async {
    final v = await request('device_relist_requests');
    return v is List ? [for (final x in v) if (x is Map) RelistRequest.fromJson(x.cast<String, dynamic>())] : const [];
  }

  /// The user's answer: [approve] lists the device again; otherwise it is
  /// signed out of the account (and wiped).
  Future<DeviceList> deviceRelist(String device, {required bool approve}) async =>
      DeviceList.fromJson(_map(await request('device_relist', {'device': device, 'approve': approve})));

  /// A linked device signs itself out; `device_revoked {by_self: true}` follows.
  /// Returns whether the main device could be told right away.
  /// [primaryOk]: the main device may sign out too (the user confirmed they kept the recovery
  /// phrase); without it the core refuses with `err.primary_logout`.
  /// [passphrase]: required when the install is password-protected (else `err.wrong_passphrase`).
  /// [wipe] ("Delete account"): the downloaded files go too (a linked device also asks the main
  /// device to revoke it with a media wipe).
  Future<bool> deviceLogout({bool primaryOk = false, String? passphrase, bool wipe = false}) async => _b(
      _map(await request('device_logout', {if (primaryOk) 'primary_ok': true, 'passphrase': ?passphrase, if (wipe) 'wipe': true})),
      'notified');

  /// Make this linked device the main one (needs the 24-word recovery phrase);
  /// `link_state {state: restart, reason: promoted}` follows. Errors:
  /// `err.phrase_mismatch`, `err.bad_phrase`, `err.already_primary`.
  /// [passphrase]: the one this install is protected with (`me.protection == "passphrase"`).
  Future<void> devicePromote(String phrase, {String? passphrase}) =>
      request('device_promote', {'phrase': phrase, if (passphrase != null && passphrase.isNotEmpty) 'passphrase': passphrase});

  /// A friend's devices (with the security code of each).
  Future<List<DeviceInfo>> contactDevices(String peer) async =>
      _list(await request('contact_devices', {'peer': peer})).map(DeviceInfo.fromJson).toList();

  /// Existing device: open a link invite (QR + 12-digit code, valid 10 minutes).
  Future<LinkOffer> linkInvite() async => LinkOffer.fromJson(_map(await request('link_invite')));

  /// New device (core started with `link_pending: true`): use the scanned QR
  /// or the typed code → the device that will approve, `state: awaiting_approval`.
  Future<LinkRequest> linkScan({String? qr, String? code}) async =>
      LinkRequest.fromJson(_map(await request('link_scan', {'qr': ?qr, 'code': ?code})));

  /// Existing device: let the new device in. [history]: none | 1m | 6m | all.
  Future<DeviceList> linkApprove(String device, {String history = '6m'}) async =>
      DeviceList.fromJson(_map(await request('link_approve', {'device': device, 'history': history})));

  Future<void> linkReject(String device) => request('link_reject', {'device': device});

  /// Closes the open invite (existing device) or stops waiting (new device).
  Future<void> linkCancel() => request('link_cancel');

  /// History copy progress on a newly linked device.
  Future<HistoryStatus> historyStatus() async => HistoryStatus.fromJson(_map(await request('history_status')));

  /// Stops the core but keeps [events] open, so [start] can run again in the
  /// same app session (a device that was signed out goes back to the welcome
  /// screen). The mock keeps its data.
  Future<void> halt() async {}

  /// Stops the core and starts it again with the last config plus [overrides].
  /// `core_restarted {reason}` is emitted once it is back.
  Future<void> restart({Map<String, dynamic> overrides = const {}, String reason = ''}) async {}

  Future<NetStatus> netStatus() async =>
      NetStatus.fromJson(_map(await request('net_status')));

  Future<List<Contact>> contacts() async =>
      _list(await request('contacts')).map(Contact.fromJson).toList();
  Future<String> addContact(String id, {String? note}) async =>
      _map(await request('add_contact', {'target': id, 'note': ?note}))['peer']
          as String? ??
      '';
  Future<List<Map<String, dynamic>>> lookup(String shortId) async =>
      _list(await request('lookup', {'short_id': shortId}));
  Future<void> acceptContact(String peer) =>
      request('accept_contact', {'peer': peer});
  Future<void> removeContact(String peer) =>
      request('remove_contact', {'peer': peer});
  /// Lets a blocked person reach you again (they are not re-added as a friend).
  Future<void> unblockContact(String peer) => request('unblock_contact', {'peer': peer});

  /// Per-contact protection: `{forward_secrecy, verified}`.
  Future<Map<String, dynamic>> securityStatus(String peer) async => _map(await request('security_status', {'peer': peer}));
  Future<void> blockContact(String peer) =>
      request('block_contact', {'peer': peer});
  Future<void> renameContact(String peer, String alias) =>
      request('rename_contact', {'peer': peer, 'alias': alias});
  Future<String> safetyNumber(String peer) async =>
      _map(await request('verify_contact', {'peer': peer}))['safety_number']
          as String? ??
      '';
  Future<void> markVerified(String peer, bool verified) =>
      request('mark_verified', {'peer': peer, 'verified': verified});

  Future<List<Conversation>> conversations() async =>
      _list(await request('conversations')).map(Conversation.fromJson).toList();
  Future<List<Message>> messages(String conv, {int? before, int limit = 50}) async =>
      _list(await request('messages', {
        'conv': conv,
        'before': ?before,
        'limit': limit,
      })).map(Message.fromJson).toList();
  Future<Message> sendText(String conv, String text,
          {String? replyTo, int? ttlMs, bool silent = false}) async =>
      Message.fromJson(_map(await request('send_text', {
        'conv': conv,
        'text': text,
        'reply_to': ?replyTo,
        'ttl_ms': ?ttlMs,
        if (silent) 'silent': true,
      })));
  Future<void> editMessage(String conv, String id, String text) =>
      request('edit_message', {'conv': conv, 'msg_id': id, 'text': text});
  Future<void> deleteMessage(String conv, String id) =>
      request('delete_message', {'conv': conv, 'msg_id': id});
  Future<void> react(String conv, String id, String emoji, bool on) =>
      request('react', {'conv': conv, 'msg_id': id, 'emoji': emoji, 'on': on});
  Future<void> markRead(String conv) => request('mark_read', {'conv': conv});
  Future<void> typing(String conv, bool on) =>
      request('typing', {'conv': conv, 'on': on});
  Future<void> convFlag(String conv, String flag, bool value) =>
      request('conv_flag', {'conv': conv, 'flag': flag, 'value': value});
  Future<void> deleteConversation(String conv) =>
      request('delete_conversation', {'conv': conv});
  // ---------------------------------------------------------------- v1.1

  Future<Profile> profile() async => Profile.fromJson(_map(await request('profile')));
  Future<void> setProfile({String? name, String? bio, String? status, String? avatar}) => request('set_profile', {
        'name': ?name,
        'bio': ?bio,
        'status': ?status,
        'avatar': ?avatar,
      });
  Future<void> setCover(String? cover) => request('set_cover', {'cover': cover});
  Future<String?> contactCover(String peer) async =>
      _map(await request('contact_cover', {'peer': peer}))['cover'] as String?;
  Future<String?> contactAvatar(String peer) async =>
      _map(await request('contact_avatar', {'peer': peer}))['avatar'] as String?;

  /// Rich send with @mentions (preferred over [sendText]).
  /// [clientId]: idempotency key (1–64 chars). Retrying with the same id
  /// returns the first message instead of sending a duplicate (core keeps
  /// it 24 h) — reuse it when the user retries a failed / timed-out send.
  Future<Message> sendMessage(String conv, String text,
          {String? replyTo, int? ttlMs, List<String>? mentions, bool mentionAll = false, bool silent = false, String? clientId}) async =>
      Message.fromJson(_map(await request('send_message', {
        'conv': conv,
        'text': text,
        'client_id': ?clientId,
        'reply_to': ?replyTo,
        'ttl_ms': ?ttlMs,
        if (mentions != null && mentions.isNotEmpty) 'mentions': mentions,
        if (mentionAll) 'mention_all': true,
        if (silent) 'silent': true,
      })));
  Future<void> forwardMessage(String msgId, String toConv, {bool hideSender = false}) =>
      request('forward_message', {'msg_id': msgId, 'to_conv': toConv, if (hideSender) 'hide_sender': true});
  Future<void> pinMessage(String conv, String msgId, bool on) =>
      request('pin_message', {'conv': conv, 'msg_id': msgId, 'on': on});
  Future<List<Message>> pinnedMessages(String conv) async =>
      _list(await request('pinned_messages', {'conv': conv})).map(Message.fromJson).toList();
  Future<Message> sendPoll(String conv, String question, List<String> options) async =>
      Message.fromJson(_map(await request('send_poll', {'conv': conv, 'question': question, 'options': options})));
  Future<void> vote(String conv, String msgId, int option) =>
      request('vote', {'conv': conv, 'msg_id': msgId, 'option': option});

  // ---------------------------------------------- checklists / reminders

  /// "Danh sách việc": a titled list of to-dos anyone in the chat can tick.
  Future<Message> sendChecklist(String conv, String title, List<String> items, {bool silent = false}) async =>
      Message.fromJson(_map(await request('send_checklist', {'conv': conv, 'title': title, 'items': items, if (silent) 'silent': true})));
  Future<void> checklistToggle(String conv, String msgId, int item, bool done) =>
      request('checklist_toggle', {'conv': conv, 'msg_id': msgId, 'item': item, 'done': done});

  /// Only the person who sent the list can add items.
  Future<void> checklistAdd(String conv, String msgId, List<String> items) =>
      request('checklist_add', {'conv': conv, 'msg_id': msgId, 'items': items});

  /// "Nhắc hẹn": every device in the chat gets a `reminder_due` event at [atMs].
  Future<Message> sendReminder(String conv, String title, int atMs, {String? note, bool silent = false}) async =>
      Message.fromJson(_map(await request('send_reminder', {
        'conv': conv,
        'title': title,
        'at_ms': atMs,
        if (note != null && note.isNotEmpty) 'note': note,
        if (silent) 'silent': true,
      })));
  Future<void> reminderCancel(String conv, String msgId) => request('reminder_cancel', {'conv': conv, 'msg_id': msgId});
  Future<void> reminderSeen(String conv, String msgId) => request('reminder_seen', {'conv': conv, 'msg_id': msgId});

  /// Wake-on-LAN for a recent remote device: `{sent, helpers}`.
  Future<Map<String, dynamic>> remoteWake(String peer) async => _map(await request('remote_wake', {'peer': peer}));
  Future<String> scheduleMessage(String conv, String text, int at) async =>
      _map(await request('schedule_message', {'conv': conv, 'text': text, 'at': at}))['sched_id']?.toString() ?? '';
  Future<List<ScheduledMessage>> scheduledMessages() async =>
      _list(await request('scheduled_messages')).map(ScheduledMessage.fromJson).toList();
  Future<void> cancelScheduled(String schedId) => request('cancel_scheduled', {'sched_id': schedId});

  Future<String> createCommunity(String name, List<String> members) async =>
      _map(await request('create_group', {'name': name, 'members': members, 'kind': 1}))['conv'] as String? ?? '';
  Future<void> groupChannel(String gid, String name, {bool voice = false, bool remove = false, String? category, String? topic}) =>
      request('group_channel', {'gid': gid, 'name': name, 'voice': voice, 'remove': remove, 'category': ?category, 'topic': ?topic});

  // ---- Community 2.0: roles, permissions, channel settings, timeouts.

  /// The community's roles, highest first (`@everyone` last).
  Future<List<GroupRole>> groupRoles(String gid) async => _list(await request('group_roles', {'gid': gid})).map(GroupRole.fromJson).toList();

  /// Creates a role when [id] is null, else updates it. Returns its id.
  Future<String> groupRoleSet(String gid, {String? id, required String name, required String color, required List<String> perms, int? position}) async =>
      _map(await request('group_role_set', {'gid': gid, 'id': ?id, 'name': name, 'color': color, 'perms': perms, 'position': ?position}))['id']?.toString() ?? id ?? '';
  Future<void> groupRoleDelete(String gid, String id) => request('group_role_delete', {'gid': gid, 'id': id});

  /// Sets [peer]'s custom roles (built-in `admin` / `everyone` are not listed here).
  Future<void> groupMemberRoles(String gid, String peer, List<String> roles) => request('group_member_roles', {'gid': gid, 'peer': peer, 'roles': roles});

  /// Changes the channel called [name]; only the fields passed change.
  Future<void> groupChannelUpdate(String gid, String name,
          {String? newName, String? topic, String? category, int? position, bool? private, List<String>? allowRoles, bool? announce}) =>
      request('group_channel_update', {
        'gid': gid,
        'name': name,
        'new_name': ?newName,
        'topic': ?topic,
        'category': ?category,
        'position': ?position,
        'private': ?private,
        'allow_roles': ?allowRoles,
        'announce': ?announce,
      });

  /// Mutes [peer] in the community until [untilMs] (epoch ms); 0 lifts it.
  Future<void> groupTimeout(String gid, String peer, int untilMs) => request('group_timeout', {'gid': gid, 'peer': peer, 'until_ms': untilMs});
  Future<String> createInvite(String gid, {int hours = 24}) async =>
      _map(await request('create_invite', {'gid': gid, 'hours': hours}))['link'] as String? ?? '';

  /// A new invite link (needs `invite`), with its id for [groupRevokeInvite].
  Future<InviteLink> createInviteLink(String gid, {int hours = 24}) async {
    final m = _map(await request('create_invite', {'gid': gid, 'hours': hours}));
    return InviteLink.fromJson({'created': DateTime.now().millisecondsSinceEpoch, ...m});
  }

  /// The live invite links I created for [gid].
  Future<List<InviteLink>> groupInviteLinks(String gid) async =>
      _list(await request('group_invite_links', {'gid': gid})).map(InviteLink.fromJson).toList();

  /// Revokes invite link [id]; no id: every link made so far, by anyone
  /// (needs `invite`). Joining with a revoked link fails (`err.invite_revoked`).
  Future<void> groupRevokeInvite(String gid, {String? id}) => request('group_revoke_invite', {'gid': gid, 'id': ?id});

  /// Owner only: [peer] becomes the owner, I become an admin.
  Future<void> groupTransferOwner(String gid, String peer) => request('group_transfer_owner', {'gid': gid, 'peer': peer});

  /// "Approve new members": turns down [peer]'s join request (approve = [groupAdd]).
  Future<void> groupJoinDeny(String gid, String peer) => request('group_join_deny', {'gid': gid, 'peer': peer});

  /// Invitations to groups waiting for my answer ("who can add me").
  Future<List<GroupInvite>> groupInvites() async => _list(await request('group_invites')).map(GroupInvite.fromJson).toList();

  /// Accepts / declines the invitation to [gid]; accepted → the group's conversation.
  Future<String?> groupInviteAnswer(String gid, bool accept) async {
    final r = await request('group_invite_answer', {'gid': gid, 'accept': accept});
    return r is Map ? r['conv']?.toString() : null;
  }
  Future<InviteInfo> inspectInvite(String link) async =>
      InviteInfo.fromJson(_map(await request('inspect_invite', {'link': link})));
  /// The joined group's conversation (`g:<gid>`; the core may only send the
  /// gid while the join is still pending).
  Future<String> joinInvite(String link) async => (await joinInviteResult(link)).conv;

  /// Joins by link. The real core only sends the request (`pending: true`): the group
  /// arrives later (`group` event), or `group_join_denied {gid, reason, code}` says no.
  Future<JoinResult> joinInviteResult(String link) async {
    final m = _map(await request('join_invite', {'link': link}));
    final gid = m['gid'] as String? ?? '';
    var conv = m['conv'] as String? ?? '';
    if (conv.isEmpty && gid.isNotEmpty) conv = 'g:$gid';
    return JoinResult(conv: conv, gid: gid, name: m['name']?.toString() ?? '', pending: m['pending'] == true);
  }

  Future<void> remoteDisplay(String session, int index) =>
      request('remote_display', {'session': session, 'index': index});
  Future<void> remoteClipboard(String session, String text) =>
      request('remote_clipboard', {'session': session, 'text': text});
  Future<void> remoteTrust(String peer, bool trusted) =>
      request('remote_trust', {'peer': peer, 'trusted': trusted});

  /// Wallpaper value: preset id, `color:#RRGGBB` or `image:<b64>|blur=8|dim=0.3`.
  Future<void> setWallpaper(String conv, String? wallpaper) =>
      request('set_wallpaper', {'conv': conv, 'wallpaper': wallpaper});
  Future<String?> getWallpaper(String conv) async =>
      _map(await request('get_wallpaper', {'conv': conv}))['wallpaper'] as String?;
  /// [cover]: base64 JPEG (≤ 300 KB decoded), `""` removes it. Only the
  /// fields passed change.
  Future<void> groupMeta(String gid, {String? avatar, String? description, String? cover}) =>
      request('group_meta', {'gid': gid, 'avatar': ?avatar, 'description': ?description, 'cover': ?cover});
  Future<String?> groupAvatar(String gid) async =>
      _map(await request('group_avatar', {'gid': gid}))['avatar'] as String?;

  /// The group's / community's cover (base64 JPEG), null when it has none.
  Future<String?> groupCover(String gid) async =>
      _map(await request('group_cover', {'gid': gid}))['cover'] as String?;

  // ------------------------------------------------------- all-in-one

  Future<Message> sendLocation(String conv, double lat, double lon, {double? accuracyM, String? label, int liveMinutes = 0}) async =>
      Message.fromJson(_map(await request('send_location', {
        'conv': conv,
        'lat': lat,
        'lon': lon,
        'accuracy_m': ?accuracyM,
        'label': ?label,
        'live_minutes': liveMinutes,
      })));
  Future<void> updateLiveLocation(String conv, String msgId, double lat, double lon, {double? accuracyM, bool stop = false}) =>
      request('update_live_location', {'conv': conv, 'msg_id': msgId, 'lat': lat, 'lon': lon, 'accuracy_m': ?accuracyM, 'stop': stop});
  Future<Message> sendVoice(String conv, String path, int durationMs, List<int> wave) async =>
      Message.fromJson(_map(await request('send_voice', {'conv': conv, 'path': path, 'duration_ms': durationMs, 'wave': wave})));
  Future<Message> sendContact(String conv, String peer) async =>
      Message.fromJson(_map(await request('send_contact', {'conv': conv, 'peer': peer})));

  /// [audience]: `friends` (every friend not on my hidden list) or `close` (close friends only).
  Future<String> postStory({String? text, String? imagePath, String? bg, String? audience}) async =>
      _map(await request('post_story', {'text': ?text, 'image_path': ?imagePath, 'bg': ?bg, 'audience': ?audience}))['id']?.toString() ?? '';
  Future<List<Story>> stories() async => _list(await request('stories')).map(Story.fromJson).toList();
  Future<String?> storyImage(String id) async => _map(await request('story_image', {'story_id': id}))['image'] as String?;
  Future<void> storySeen(String id) => request('story_seen', {'story_id': id});
  /// Take my story down (here, on my devices and at friends'); `story_removed {id}` follows.
  Future<void> storyDelete(String id) => request('story_delete', {'story_id': id});
  /// My stories, newest first, including the ones past their 24 h (`active` = still shown).
  Future<List<Story>> storyArchive(String me) async =>
      _list(await request('story_archive')).map((j) => Story.fromJson({...j, 'author': me, 'seen': true})).toList();
  /// Who saw my story, oldest first: `[{peer, ts}]` (an older core sends bare peer ids).
  Future<List<StoryView>> storyViewers(String id) async {
    final v = await request('story_viewers', {'story_id': id});
    if (v is! List) return const [];
    return [
      for (final x in v)
        if (x is String && x.isNotEmpty) StoryView(x) else if (x is Map && '${x['peer'] ?? ''}'.isNotEmpty) StoryView('${x['peer']}', ts: _i(x, 'ts'), name: _s(x, 'name')),
    ];
  }

  /// smooth | balanced | sharp | saver
  Future<void> remoteQuality(String session, String preset) => request('remote_quality', {'session': session, 'preset': preset});

  // ---------------------------------------------------------- phase 3

  Future<Map<String, dynamic>> setUsername(String username) async => _map(await request('set_username', {'username': username}));
  Future<List<Map<String, dynamic>>> resolveUsername(String handle) async => _list(await request('resolve_username', {'handle': handle}));
  Future<List<Map<String, dynamic>>> searchGroups(String q) async => _list(await request('search_groups', {'q': q}));
  Future<void> joinPublic(String gid, String via) => request('join_public', {'gid': gid, 'via': via});
  Future<void> groupVisibility(String gid, {required bool public, String handle = ''}) =>
      request('group_visibility', {'gid': gid, 'public': public, 'handle': handle});
  /// Switch an older group to the Community 2.0 rules (admins; refused with
  /// `err.group_upgrade_blocked` while a member's app is older).
  Future<void> groupUpgradeRules(String gid) => request('group_upgrade_rules', {'gid': gid});

  Future<void> groupSettings(String gid, {int? slowModeS, bool? adminsOnly, bool? approveJoins}) =>
      request('group_settings', {'gid': gid, 'slow_mode_s': ?slowModeS, 'admins_only': ?adminsOnly, 'approve_joins': ?approveJoins});
  Future<void> groupBan(String gid, String peer, bool ban) => request('group_ban', {'gid': gid, 'peer': peer, 'ban': ban});
  Future<void> groupPurgeMember(String gid, String peer) => request('group_purge_member', {'gid': gid, 'peer': peer});
  Future<void> groupClearHistory(String gid) => request('group_clear_history', {'gid': gid});

  // ---- reports (no server: they go to the group's owner and admins)

  /// Reports a group message ([msgId]) or member ([peer]) to the group's owner
  /// and admins. [reason]: spam | harassment | adult | other. [hide]: also hide
  /// the member's messages on all my devices. Returns how many admins get it.
  Future<int> groupReport(String gid, {String? msgId, String? peer, required String reason, String note = '', bool hide = false}) async =>
      (_map(await request('group_report', {'gid': gid, 'msg_id': ?msgId, 'peer': ?peer, 'reason': reason, 'note': note, 'hide': hide}))['sent_to'] as num?)?.toInt() ?? 0;

  /// Admin: reports waiting on this device (newest first).
  Future<List<GroupReport>> groupReports() async => _list(await request('group_reports')).map(GroupReport.fromJson).toList();

  /// Admin: handled (dismissed / acted on) — gone on all my devices.
  Future<void> groupReportDone(List<String> ids) => request('group_report_done', {'ids': ids});

  /// Report a whole group: leave it and block it on all my devices.
  Future<List<BlockedGroup>> groupBlock(String gid, {String name = ''}) async =>
      _list(await request('group_block', {'gid': gid, 'name': name})).map(BlockedGroup.fromJson).toList();
  Future<List<BlockedGroup>> groupUnblock(String gid) async => _list(await request('group_unblock', {'gid': gid})).map(BlockedGroup.fromJson).toList();
  Future<List<BlockedGroup>> blockedGroups() async => _list(await request('blocked_groups')).map(BlockedGroup.fromJson).toList();

  /// Members whose group messages I hide (account setting, synced).
  Future<List<String>> hiddenMembers() async => ((await request('hidden_members') as List?) ?? const []).map((e) => '$e').toList();
  Future<List<String>> setMemberHidden(String peer, bool hidden) async =>
      ((await request('set_member_hidden', {'peer': peer, 'hidden': hidden}) as List?) ?? const []).map((e) => '$e').toList();
  /// Every member's read mark in a group chat (kept by the core across
  /// restarts): member -> read up to (hlc).
  Future<Map<String, int>> groupReads(String conv) async {
    final v = await request('group_reads', {'conv': conv});
    if (v is! Map) return const {};
    return {for (final e in v.entries) if (e.value is num) '${e.key}': (e.value as num).toInt()};
  }

  Future<List<String>> seenBy(String msgId) async {
    final v = await request('seen_by', {'msg_id': msgId});
    return v is List ? v.map((e) => e is Map ? (e['peer']?.toString() ?? '') : e.toString()).where((e) => e.isNotEmpty).toList() : const [];
  }

  Future<void> deleteMessageFor(String conv, String msgId, {required bool forEveryone}) =>
      request('delete_message', {'conv': conv, 'msg_id': msgId, 'for_everyone': forEveryone});
  Future<void> clearHistory(String conv, {bool forEveryone = false}) => request('clear_history', {'conv': conv, 'for_everyone': forEveryone});
  Future<void> deleteConversationFor(String conv, {bool forEveryone = false}) =>
      request('delete_conversation', {'conv': conv, 'for_everyone': forEveryone});
  Future<Map<String, dynamic>> mute(String conv, int until) async => _map(await request('mute', {'conv': conv, 'until': until}));

  Future<List<Map<String, dynamic>>> remoteRecent() async => _list(await request('remote_recent'));
  Future<void> remoteRecentRemove([String? peer]) => request('remote_recent_remove', {'peer': ?peer});
  Future<void> remotePower(String session, String action) => request('remote_power', {'session': session, 'action': action});
  Future<void> remoteAllowPower(bool allow) => request('remote_allow_power', {'allow': allow});

  Future<List<StickerPack>> stickerPacks() async => _list(await request('sticker_packs')).map(StickerPack.fromJson).toList();
  Future<String> stickerPackCreate(String name) async => _map(await request('sticker_pack_create', {'name': name}))['id']?.toString() ?? '';
  Future<void> stickerPackDelete(String pack) => request('sticker_pack_delete', {'pack': pack});
  Future<Map<String, dynamic>> stickerAdd(String pack, String path, {String emoji = ''}) async =>
      _map(await request('sticker_add', {'pack': pack, 'path': path, 'emoji': emoji}));
  Future<void> stickerRemove(String pack, String hash) => request('sticker_remove', {'pack': pack, 'hash': hash});
  Future<void> stickerSave(String hash, String pack) => request('sticker_save', {'hash': hash, 'pack': pack});
  Future<(String mime, String data)> stickerGet(String hash) async {
    final m = _map(await request('sticker_get', {'hash': hash}));
    return (m['mime']?.toString() ?? '', m['data']?.toString() ?? '');
  }

  Future<Message> sendSticker(String conv, String hash) async => Message.fromJson(_map(await request('send_sticker', {'conv': conv, 'hash': hash})));
  Future<void> stickerPackExport(String pack, String path) => request('sticker_pack_export', {'pack': pack, 'path': path});
  Future<void> stickerPackImport(String path) => request('sticker_pack_import', {'path': path});

  Future<void> pressButton(String msgId, String data) => request('press_button', {'msg_id': msgId, 'data': data});
  Future<String> groupAddBot(String gid, String target, {bool readAll = false}) async =>
      _map(await request('group_add_bot', {'gid': gid, 'target': target, 'read_all': readAll}))['peer']?.toString() ?? '';
  Future<void> groupBotPolicy(String gid, String peer, bool readAll) => request('group_bot_policy', {'gid': gid, 'peer': peer, 'read_all': readAll});

  Future<BotAccount> botCreate(String name, String username) async =>
      BotAccount.fromJson(_map(await request('bot_create', {'name': name, 'username': username})));
  Future<List<BotAccount>> botList() async => _list(await request('bot_list')).map(BotAccount.fromJson).toList();
  Future<String> botToken(String username) async => _map(await request('bot_token', {'username': username}))['token']?.toString() ?? '';
  Future<BotAccount> botRevoke(String username) async => BotAccount.fromJson(_map(await request('bot_revoke', {'username': username})));
  Future<void> botDelete(String username) => request('bot_delete', {'username': username});

  Future<void> settingsSet(Map<String, dynamic> values) => request('settings_set', values);

  /// Locked chats: an account setting kept (and synced to the account's other
  /// devices) by the core. Null when no device has saved a list yet.
  Future<List<String>?> lockedChatsGet() async {
    final m = _map(await request('locked_chats_get'));
    if (m['set'] != true) return null;
    return ((m['chats'] as List?) ?? const []).map((e) => '$e').toList();
  }

  Future<void> lockedChatsSet(List<String> chats) => request('locked_chats_set', {'chats': chats});

  /// The Bot Studio conversation (synced to the account's devices, last 200
  /// lines; tokens are never kept in it).
  Future<List<Map<String, dynamic>>> botfatherHistory() async =>
      ((_map(await request('botfather_history'))['entries'] as List?) ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  Future<void> botfatherAppend(List<Map<String, dynamic>> entries) => request('botfather_append', {'entries': entries});
  Future<void> botfatherClear() => request('botfather_clear');

  /// Small encrypted key-value store inside the core's database (keys start
  /// with "ui.", values up to 4 KB). Only available once the core is running.
  Future<String?> uiSecretGet(String key) async {
    final v = await request('ui_secret_get', {'key': key});
    return v is String ? v : null;
  }

  /// Stores [value] under [key]; null removes it.
  Future<void> uiSecretSet(String key, String? value) => request('ui_secret_set', {'key': key, 'value': value});
  Future<void> changePassphrase(String old, String next) =>
      request('change_passphrase', {'old': old, 'new': next});

  Future<void> setLang(String lang) => request('set_lang', {'lang': lang});

  /// Message history retention: forever | session (no history) | 24h | 7d | 30d.
  Future<void> setRetention(String conv, String mode) => request('set_retention', {'conv': conv, 'mode': mode});
  Future<String> getRetention(String conv) async =>
      _map(await request('get_retention', {'conv': conv}))['mode'] as String? ?? 'forever';

  Future<List<Message>> search(String q) async =>
      _list(await request('search', {'q': q})).map(Message.fromJson).toList();

  Future<String> createGroup(String name, List<String> members) async =>
      _map(await request('create_group', {'name': name, 'members': members}))[
              'conv']
          as String? ??
      '';
  Future<GroupInfo> groupInfo(String gid) async =>
      GroupInfo.fromJson(_map(await request('group_info', {'gid': gid})));
  Future<void> groupAdd(String gid, String peer) =>
      request('group_add', {'gid': gid, 'peer': peer});
  Future<void> groupRemove(String gid, String peer) =>
      request('group_remove', {'gid': gid, 'peer': peer});
  Future<void> groupSetRole(String gid, String peer, String role) =>
      request('group_set_role', {'gid': gid, 'peer': peer, 'role': role});
  Future<void> groupRename(String gid, String name) =>
      request('group_rename', {'gid': gid, 'name': name});
  Future<void> groupLeave(String gid) => request('group_leave', {'gid': gid});

  /// Owner only: deletes the group / community for every member.
  Future<void> groupDissolve(String gid) => request('group_dissolve', {'gid': gid});

  /// Spaces ("servers") with text and voice channels. NOT in api.md v1 — a UI-side proposal
  /// (`spaces` command). Returns an empty list if the core doesn't know it.
  Future<List<Space>> spaces() async {
    try {
      return _list(await request('spaces')).map(Space.fromJson).toList();
    } on ApiException {
      return const [];
    }
  }

  /// Joins (silent drop-in room: nobody is rung) or leaves a community voice
  /// channel. Joining returns the room's call id (its media is a `call` with
  /// `room: true`).
  Future<String?> voiceJoin(String channelConv, bool join) async {
    final r = await request(join ? 'voice_join' : 'voice_leave', {'conv': channelConv});
    return r is Map ? r['call_id']?.toString() : null;
  }

  /// [preview]: app-made preview (PDF first page, text snippet) carried with
  /// the file message so receivers see it before downloading.
  Future<FileItem> sendFile(String conv, String path, {LocalPreview? preview}) async => FileItem.fromJson(_map(await request('send_file', {
        'conv': conv,
        'path': path,
        if (preview?.image != null) 'thumb_b64': base64Encode(preview!.image!),
        if ((preview?.width ?? 0) > 0) 'width': preview!.width,
        if ((preview?.height ?? 0) > 0) 'height': preview!.height,
        if (preview?.preview != null) 'preview': preview!.preview!.toJson(),
      })));
  Future<void> acceptFile(String fileId, {String? dir}) =>
      request('accept_file', {'file_id': fileId, 'dir': ?dir});
  Future<void> cancelFile(String fileId) =>
      request('cancel_file', {'file_id': fileId});
  Future<List<FileItem>> files() async =>
      _list(await request('files')).map(FileItem.fromJson).toList();

  /// [ring]: in a plain group, the members whose phones ring (everyone
  /// else sees a "Join" banner; null/empty rings nobody).
  Future<String> callStart(String conv, {bool video = false, List<String>? ring}) async {
    await AppleAudio.startCall(video: video); // iOS: microphone needs play-and-record first
    return _map(await request('call_start', {'conv': conv, 'video': video, 'ring': ?ring}))['call_id']
            as String? ??
        '';
  }

  /// [video]: the call is a video call (iOS: video audio mode + speaker).
  Future<void> callAnswer(String callId, bool accept, {bool video = false}) async {
    if (accept) {
      await AppleAudio.startCall(video: video);
    } else {
      AppleServices.instance.endedLocally(callId); // CallKit: a proper "declined"
    }
    try {
      await request('call_answer', {'call_id': callId, 'accept': accept});
    } catch (_) {
      if (accept) await AppleAudio.endCall(); // not answered after all
      rethrow;
    }
  }

  Future<void> callEnd(String callId) async {
    AppleServices.instance.endedLocally(callId);
    await request('call_end', {'call_id': callId});
    await AppleAudio.endCall();
  }
  Future<void> callSet(String callId, {bool? mic, bool? cam, bool? screen}) =>
      request('call_set', {
        'call_id': callId,
        'mic': ?mic,
        'cam': ?cam,
        'screen': ?screen,
      });

  Future<RemoteStatus> remoteStatus() async =>
      RemoteStatus.fromJson(_map(await request('remote_status')));
  Future<void> remoteSet({String? password, bool? unattended, bool? allowControl, bool? allowIncoming}) =>
      request('remote_set', {
        'password': ?password,
        'unattended': ?unattended,
        'allow_control': ?allowControl,
        'allow_incoming': ?allowIncoming,
      });
  /// A new temporary remote password, made by the core (the old one stops working).
  Future<String> remoteNewPassword() async => _map(await request('remote_new_password'))['password'] as String? ?? '';
  /// [device]: which of the target account's devices (required when it has
  /// several that can be controlled: the error `err.choose_device` lists them
  /// in `detail`, see [RemoteDeviceChoice.parse]).
  Future<String> remoteConnect(String id, String password, {bool viewOnly = false, String? device}) async =>
      _map(await request('remote_connect',
              {'target': id, 'password': password, 'view_only': viewOnly, 'device': ?device}))['session']
          as String? ??
      '';
  Future<void> remoteRespond(String session, {required bool accept, required bool control}) =>
      request('remote_respond', {'session': session, 'accept': accept, 'control': control});
  Future<void> remoteInput(String session, Map<String, dynamic> ev) =>
      request('remote_input', {'session': session, 'ev': ev});
  Future<void> remoteEnd(String session) => request('remote_end', {'session': session});

  Future<Diagnostics> diagnostics() async =>
      Diagnostics.fromJson(_map(await request('diagnostics')));
  Future<Map<String, dynamic>> storageStats() async => _map(await request('storage_stats'));

  /// Housekeeping (expired messages, temporary data, database compaction).
  Future<Map<String, dynamic>> maintain() async => _map(await request('maintain'));

  /// `{max_cache, media_days, community_days, auto_download}` (bytes / days, 0 = no limit / never).
  Future<StoragePolicy> storagePolicy() async => StoragePolicy.fromJson(_map(await request('storage_policy')));

  /// Saves the given fields and applies the policy right away. Returns the full policy.
  Future<StoragePolicy> setStoragePolicy(Map<String, int> values) async =>
      StoragePolicy.fromJson(_map(await request('set_storage_policy', values)));

  /// Changes auto-download limits: `{wifi?: {photo?, video?, file?}, cell?: {…}}` (bytes,
  /// 0 = off, [kAutoDownloadAlways] = always). Returns the full policy.
  Future<StoragePolicy> setAutoDownload(Map<String, Map<String, int>> values) async =>
      StoragePolicy.fromJson(_map(await request('set_storage_policy', {'auto_download': values})));

  /// The device's network as the app sees it — `wifi`, `cell` (mobile data) or `roaming`
  /// (roaming / a metered Wi-Fi): the core uses that network's auto-download limits and,
  /// off Wi-Fi, avoids costly connection upgrades.
  Future<void> setNetworkHint({required String network, bool lowBattery = false}) =>
      request('set_network_hint', {'network': network, 'metered': network != 'wifi', 'low_battery': lowBattery});

  /// Removes downloaded media (messages stay; files can be downloaded again).
  /// [conv] null = every conversation. Returns `{freed_bytes, removed_files, cache_bytes}`.
  Future<Map<String, dynamic>> clearMedia({String? conv}) async => _map(await request('clear_media', {'conv': conv ?? '*'}));

  /// Writes an encrypted backup (account + history) to [path]. [passphrase] is
  /// the current device passphrase when the account is protected by one.
  Future<Map<String, dynamic>> exportBackup(String path, String password, {String? passphrase}) async =>
      _map(await request('export_backup', {'path': path, 'password': password, 'passphrase': ?passphrase}));

  /// Values the core keeps for `settings_set` keys.
  Future<Map<String, dynamic>> settingsGet() async => _map(await request('settings_get'));

  /// Recovery from friends after a restore with the recovery phrase:
  /// `{recovering, offers: [{peer, name, messages, groups, since, verified, state, received, at}]}`.
  Future<Map<String, dynamic>> recoveryOffers() async => _map(await request('recovery_offers'));
  Future<Map<String, dynamic>> recoveryAccept(String peer) async => _map(await request('recovery_accept', {'peer': peer}));
  Future<Map<String, dynamic>> recoveryDecline(String peer) async => _map(await request('recovery_decline', {'peer': peer}));
  Future<Map<String, dynamic>> recoveryDismiss() async => _map(await request('recovery_dismiss'));
}

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};
List<Map<String, dynamic>> _list(dynamic v) => v is List
    ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
    : <Map<String, dynamic>>[];

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

String _s(Map j, String k, [String d = '']) {
  final v = j[k];
  return v == null ? d : v.toString();
}

String? _so(Map j, String k) {
  return j[k]?.toString();
}

int _i(Map j, String k, [int d = 0]) {
  final v = j[k];
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? d;
  return d;
}

bool _b(Map j, String k, [bool d = false]) {
  final v = j[k];
  if (v is bool) return v;
  if (v is num) return v != 0;
  return d;
}

List<String> _ls(Map j, String k) =>
    (j[k] is List) ? (j[k] as List).map((e) => e.toString()).toList() : <String>[];

/// Real core sends structured bodies (`{text}` for text, `{question,options}`
/// for polls, file/location objects…). Text bodies are flattened to the
/// plain string; everything else is kept as JSON for typed parsers.
String _bodyString(String kind, Object? body) {
  if (body == null) return '';
  if (body is String) return body;
  if (body is Map) {
    final t = body['text'];
    if ((kind == 'text' || kind == 'sticker') && t is String && !body.containsKey('code')) return t;
    return jsonEncode(body);
  }
  return body.toString();
}

// ---------------------------------------------------------------------------
// Event envelope
// ---------------------------------------------------------------------------

class ApiEvent {
  const ApiEvent(this.name, this.data);
  final String name;
  final Map<String, dynamic> data;

  /// Accepts `{"event":"x", ...}` or `{"event":"x","data":{...}}`.
  factory ApiEvent.parse(Map<String, dynamic> raw) {
    final name = (raw['event'] ?? raw['type'] ?? '').toString();
    final d = raw['data'];
    if (d is Map) return ApiEvent(name, d.cast<String, dynamic>());
    final copy = Map<String, dynamic>.of(raw)..remove('event');
    return ApiEvent(name, copy);
  }

  /// For list-shaped data payloads (unused by v1 events).
  dynamic get raw => data;
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

class Me {
  const Me({
    required this.peer,
    required this.shortId,
    required this.name,
    this.recoveryPhraseAvailable = false,
    this.safety = '',
    this.username,
    this.handle,
    this.protection = '',
    this.device = '',
    this.primary = true,
    this.deviceName = '',
    this.deviceCount = 1,
    this.linkPending = false,
  });

  /// Multi-device: [peer] is the account; [device] is this device's key.
  final String device;

  /// The main device (holds the recovery phrase, approves new devices).
  final bool primary;
  final String deviceName;
  final int deviceCount;

  /// Started to be linked into another account (onboarding "Liên kết thiết bị").
  final bool linkPending;
  final String? username;
  final String? handle;

  /// How local data is locked: "passphrase" | "device" ("" = unknown).
  final String protection;
  final String peer;
  final String shortId;
  final String name;
  final bool recoveryPhraseAvailable;
  final String safety;

  factory Me.fromJson(Map<String, dynamic> j) => Me(
        peer: _s(j, 'peer'),
        shortId: _s(j, 'short_id'),
        name: _s(j, 'name'),
        recoveryPhraseAvailable: _b(j, 'recovery_phrase_available'),
        safety: _s(j, 'safety'),
        username: _so(j, 'username'),
        handle: _so(j, 'handle'),
        protection: _s(j, 'protection'),
        device: _s(j, 'device'),
        primary: _b(j, 'primary', true),
        deviceName: _s(j, 'device_name'),
        deviceCount: _i(j, 'devices', 1),
        linkPending: _b(j, 'link_pending'),
      );

  Me copyWith({String? name, String? username, String? handle, String? protection}) => Me(
        device: device,
        primary: primary,
        deviceName: deviceName,
        deviceCount: deviceCount,
        linkPending: linkPending,
        protection: protection ?? this.protection,
        username: username ?? this.username,
        handle: handle ?? this.handle,
        peer: peer,
        shortId: shortId,
        name: name ?? this.name,
        recoveryPhraseAvailable: recoveryPhraseAvailable,
        safety: safety,
      );
}

/// Device kinds (`kind`).
abstract final class DeviceKind {
  static const phone = 1;
  static const tablet = 2;
  static const desktop = 3;
  static const cli = 4;
}

/// One device of an account (`devices`, `contact_devices`).
class DeviceInfo {
  const DeviceInfo({
    required this.device,
    this.name = '',
    this.kind = 0,
    this.caps = 0,
    this.primary = false,
    this.isThis = false,
    this.online = false,
    this.lastSeen = 0,
    this.added = 0,
    this.shortId = '',
    this.safety = '',
    this.os = '',
  });
  final String device;
  final String name;

  /// [DeviceKind]: 1 phone, 2 tablet, 3 desktop, 4 cli
  final int kind;

  /// bit 1 main device, 2 can be remote-controlled, 4 calls
  final int caps;
  final bool primary;
  final bool isThis;
  final bool online;
  final int lastSeen;
  final int added;

  /// "123 456 789" (remote control ID of this device)
  final String shortId;

  /// Security code of a friend's device ("12345 67890 …", `contact_devices`).
  final String safety;
  final String os;
  bool get remoteHost => caps & 2 != 0;

  DeviceInfo withPresence({required bool online, int? lastSeen}) => DeviceInfo(
        device: device,
        name: name,
        kind: kind,
        caps: caps,
        primary: primary,
        isThis: isThis,
        online: online,
        lastSeen: lastSeen ?? this.lastSeen,
        added: added,
        shortId: shortId,
        safety: safety,
        os: os,
      );

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
        device: _s(j, 'device'),
        name: _s(j, 'name'),
        kind: _i(j, 'kind'),
        caps: _i(j, 'caps'),
        primary: _b(j, 'primary'),
        isThis: _b(j, 'this'),
        online: _b(j, 'online'),
        lastSeen: _i(j, 'last_seen'),
        added: _i(j, 'added'),
        shortId: _s(j, 'short_id'),
        safety: _s(j, 'safety'),
        os: _s(j, 'os'),
      );
}

/// `devices`: the account's device list.
class DeviceList {
  const DeviceList({this.account = '', this.device = '', this.primary = true, this.version = 0, this.devices = const [], this.revoked = const []});
  final String account;

  /// This device.
  final String device;
  final bool primary;
  final int version;
  final List<DeviceInfo> devices;
  final List<DeviceInfo> revoked;

  DeviceInfo? get thisDevice => devices.where((d) => d.isThis || d.device == device).firstOrNull;
  DeviceInfo? get mainDevice => devices.where((d) => d.primary).firstOrNull;

  factory DeviceList.fromJson(Map<String, dynamic> j) => DeviceList(
        account: _s(j, 'account'),
        device: _s(j, 'device'),
        primary: _b(j, 'primary', true),
        version: _i(j, 'version'),
        devices: _list(j['devices']).map(DeviceInfo.fromJson).toList(),
        revoked: _list(j['revoked']).map(DeviceInfo.fromJson).toList(),
      );
}

/// `link_invite`: what the existing device shows to the new one.
class LinkOffer {
  const LinkOffer({required this.qr, required this.code, required this.expires, this.device = '', this.name = ''});

  /// `lumora://link/…` (encode as a QR code)
  final String qr;

  /// `1234-5678-9012`
  final String code;

  /// ms since epoch
  final int expires;
  final String device;
  final String name;

  LinkOffer withCode(String c) => LinkOffer(qr: qr, code: c, expires: expires, device: device, name: name);

  factory LinkOffer.fromJson(Map<String, dynamic> j) =>
      LinkOffer(qr: _s(j, 'qr'), code: _s(j, 'code'), expires: _i(j, 'expires'), device: _s(j, 'device'), name: _s(j, 'name'));
}

/// `link_request` (the new device asking to join, on the existing device) and
/// `link_scan`'s answer (the device that will approve, on the new device).
class LinkRequest {
  const LinkRequest({required this.device, this.name = '', this.kind = 0, this.os = '', this.path = '', this.state = ''});
  final String device;
  final String name;
  final int kind;
  final String os;

  /// lan | direct | relay
  final String path;

  /// `link_scan`: awaiting_approval
  final String state;

  factory LinkRequest.fromJson(Map<String, dynamic> j) => LinkRequest(
      device: _s(j, 'device'), name: _s(j, 'name'), kind: _i(j, 'kind'), os: _s(j, 'os'), path: _s(j, 'path'), state: _s(j, 'state'));
}

/// An own device asking to be listed again (`device_relist_request`).
class RelistRequest {
  const RelistRequest({required this.device, this.name = '', this.kind = 0, this.shortId = ''});
  final String device;
  final String name;
  final int kind;
  final String shortId;

  factory RelistRequest.fromJson(Map<String, dynamic> j) =>
      RelistRequest(device: _s(j, 'device'), name: _s(j, 'name'), kind: _i(j, 'kind'), shortId: _s(j, 'short_id'));
}

/// `history_status` / `history_sync` progress on a newly linked device.
class HistoryStatus {
  const HistoryStatus({this.active = false, this.done = true, this.stateDone = true, this.messages = 0, this.sinceMs = 0, this.convsDone = 0, this.convsTotal = 0});
  final bool active;
  final bool done;
  final bool stateDone;
  final int messages;

  /// Oldest message being copied (0 = everything / unknown).
  final int sinceMs;
  final int convsDone;
  final int convsTotal;

  /// 0…1, or null when the total isn't known yet.
  double? get fraction => convsTotal > 0 ? (convsDone / convsTotal).clamp(0.0, 1.0) : null;

  factory HistoryStatus.fromJson(Map<String, dynamic> j) => HistoryStatus(
        active: _b(j, 'active'),
        done: _b(j, 'done', true),
        stateDone: _b(j, 'state_done', true),
        messages: _i(j, 'messages'),
        sinceMs: _i(j, 'since_ms'),
        convsDone: _i(j, 'convs_done'),
        convsTotal: _i(j, 'convs_total'),
      );

  /// Applies a `history_sync` event.
  HistoryStatus update(Map<String, dynamic> j) {
    final finished = _b(j, 'done');
    return HistoryStatus(
      active: !finished,
      done: finished,
      stateDone: true,
      messages: j.containsKey('messages') ? _i(j, 'messages') : messages,
      sinceMs: sinceMs,
      convsDone: j.containsKey('convs_done') ? _i(j, 'convs_done') : convsDone,
      convsTotal: j.containsKey('convs_total') ? _i(j, 'convs_total') : convsTotal,
    );
  }
}

/// One entry of `err.choose_device`'s `detail` (`remote_connect` to an account
/// with several devices that can be controlled).
class RemoteDeviceChoice {
  const RemoteDeviceChoice({required this.device, this.name = '', this.kind = 0, this.shortId = ''});
  final String device;
  final String name;
  final int kind;
  final String shortId;

  /// The choices carried by an `err.choose_device` error, else null.
  static List<RemoteDeviceChoice>? parse(Object e) {
    if (e is! ApiException || e.code != 'err.choose_device') return null;
    try {
      final d = jsonDecode(e.detail ?? '');
      if (d is! List) return null;
      return [
        for (final x in d)
          if (x is Map)
            RemoteDeviceChoice(device: _s(x, 'device'), name: _s(x, 'name'), kind: _i(x, 'kind'), shortId: _s(x, 'short_id')),
      ];
    } catch (_) {
      return null;
    }
  }
}

/// "Always download" limit (1 PiB), the same value as the core's `AUTO_ALWAYS`.
const kAutoDownloadAlways = 1 << 50;

/// Auto-download limits on one kind of network (bytes; 0 = off).
class AutoLimits {
  const AutoLimits({required this.photo, required this.video, required this.voice, required this.file, required this.fileGroup});
  final int photo, video, voice, file, fileGroup;

  // defaults (as the core's): photos and voice messages everywhere, videos and files on Wi-Fi only
  static const wifi = AutoLimits(photo: 5 << 20, video: 50 << 20, voice: kAutoDownloadAlways, file: 25 << 20, fileGroup: 10 << 20);
  static const cell = AutoLimits(photo: 5 << 20, video: 0, voice: kAutoDownloadAlways, file: 0, fileGroup: 0);
  static const roaming = AutoLimits(photo: 1 << 20, video: 0, voice: 5 << 20, file: 0, fileGroup: 0);

  factory AutoLimits.fromJson(Map<String, dynamic>? j, AutoLimits d) => j == null
      ? d
      : AutoLimits(
          photo: _i(j, 'photo', d.photo),
          video: _i(j, 'video', d.video),
          voice: _i(j, 'voice', d.voice),
          file: _i(j, 'file', d.file),
          fileGroup: _i(j, 'file_group', d.fileGroup),
        );

  /// `photo` / `video` / `voice` / `file`.
  int operator [](String kind) => switch (kind) { 'photo' => photo, 'video' => video, 'voice' => voice, _ => file };
}

/// Per-network auto-download rules (Wi-Fi / mobile data / roaming or metered Wi-Fi).
class AutoDownload {
  const AutoDownload({this.wifi = AutoLimits.wifi, this.cell = AutoLimits.cell, this.roaming = AutoLimits.roaming});
  final AutoLimits wifi, cell, roaming;
  factory AutoDownload.fromJson(Map<String, dynamic>? j) => AutoDownload(
        wifi: AutoLimits.fromJson((j?['wifi'] as Map?)?.cast<String, dynamic>(), AutoLimits.wifi),
        cell: AutoLimits.fromJson((j?['cell'] as Map?)?.cast<String, dynamic>(), AutoLimits.cell),
        roaming: AutoLimits.fromJson((j?['roaming'] as Map?)?.cast<String, dynamic>(), AutoLimits.roaming),
      );
  AutoLimits of(String network) => switch (network) { 'cell' => cell, 'roaming' => roaming, _ => wifi };

  /// Whether a received [kind] (`photo` / `video` / `voice` / `file`) of [size] bytes
  /// downloads by itself on [network] (the same rule as the core's).
  bool allows(String network, String kind, int size, {bool inGroup = false}) {
    final l = of(network);
    final limit = kind == 'file' && inGroup ? (l.fileGroup < l.file ? l.fileGroup : l.file) : l[kind];
    return limit > 0 && size <= limit;
  }
}

/// Disk policy of the core (`storage_policy`).
class StoragePolicy {
  const StoragePolicy({
    this.maxCache = 5 << 30,
    this.mediaDays = 0,
    this.autoDirect = 25 << 20,
    this.autoGroup = 2 << 20,
    this.communityDays = 30,
    this.autoDownload = const AutoDownload(),
  });

  /// What downloads by itself, per network and kind of media.
  final AutoDownload autoDownload;

  /// Max bytes of downloaded media (0 = unlimited).
  final int maxCache;

  /// Delete downloaded media older than this many days (0 = never).
  final int mediaDays;

  /// Legacy single auto-download limits (an older core decides with these).
  final int autoDirect;
  final int autoGroup;

  /// History window for communities in days (0 = forever).
  final int communityDays;

  factory StoragePolicy.fromJson(Map<String, dynamic> j) => StoragePolicy(
        maxCache: _i(j, 'max_cache', 5 << 30),
        mediaDays: _i(j, 'media_days'),
        autoDirect: _i(j, 'auto_direct', 25 << 20),
        autoGroup: _i(j, 'auto_group', 2 << 20),
        communityDays: _i(j, 'community_days', 30),
        autoDownload: AutoDownload.fromJson((j['auto_download'] as Map?)?.cast<String, dynamic>()),
      );

  Map<String, int> toJson() => {
        'max_cache': maxCache,
        'media_days': mediaDays,
        'auto_direct': autoDirect,
        'auto_group': autoGroup,
        'community_days': communityDays,
      };
}

enum ContactStatus { none, sent, received, friend, blocked }

class Contact {
  const Contact({
    required this.peer,
    required this.shortId,
    required this.name,
    this.alias,
    this.status = ContactStatus.friend,
    this.added = 0,
    this.lastSeen = 0,
    this.verified = false,
    this.relays = const [],
    this.online = false,
    this.path,
    this.note,
    this.bio = '',
    this.presence,
    this.hasAvatar = false,
    this.bot,
    this.username,
    this.handle,
    this.bridged = false,
  });

  /// Non-null for bot accounts.
  final BotInfo? bot;
  final String? username;
  final String? handle;
  bool get isBot => bot != null;
  final String bio;

  /// online | away | dnd | invisible/offline (null → derived from [online]).
  final String? presence;
  final bool hasAvatar;

  /// Effective presence for dots: online/away/dnd/offline.
  String get presenceKey {
    if (!online) return 'offline';
    final p = presence;
    if (p == 'away' || p == 'dnd') return p!;
    if (p == 'invisible' || p == 'offline') return 'offline';
    return 'online';
  }

  final String peer;
  final String shortId;
  final String name;
  final String? alias;
  final ContactStatus status;
  final int added;
  final int lastSeen;
  final bool verified;
  final List<String> relays;
  final bool online;

  /// From `presence` events: "direct" | "lan" | "relay".
  final String? path;

  /// From `friend_request` events.
  final String? note;

  /// This is a linked (not main) device and the friend's app is too old for several
  /// devices: what we send them goes through our main device.
  final bool bridged;

  String get displayName => (alias != null && alias!.isNotEmpty) ? alias! : name;

  factory Contact.fromJson(Map<String, dynamic> j) {
    final st = _i(j, 'status', 3);
    return Contact(
      peer: _s(j, 'peer'),
      shortId: _s(j, 'short_id'),
      name: _s(j, 'name', 'Unknown'),
      alias: _so(j, 'alias'),
      status: ContactStatus.values[st == 4 ? 4 : st.clamp(0, 3)],
      added: _i(j, 'added'),
      lastSeen: _i(j, 'last_seen'),
      verified: _b(j, 'verified'),
      relays: _ls(j, 'relays'),
      online: _b(j, 'online'),
      path: _so(j, 'path'),
      note: _so(j, 'note'),
      bio: _s(j, 'bio'),
      presence: _so(j, 'presence'),
      hasAvatar: _b(j, 'has_avatar'),
      bot: BotInfo.parse(j['bot']),
      username: _so(j, 'username'),
      handle: _so(j, 'handle'),
      bridged: _b(j, 'bridged'),
    );
  }

  Contact copyWith({
    String? name,
    String? alias,
    ContactStatus? status,
    bool? online,
    String? path,
    int? lastSeen,
    bool? verified,
    String? presence,
  }) =>
      Contact(
        bio: bio,
        presence: presence ?? this.presence,
        hasAvatar: hasAvatar,
        bot: bot,
        username: username,
        handle: handle,
        peer: peer,
        shortId: shortId,
        name: name ?? this.name,
        alias: alias ?? this.alias,
        status: status ?? this.status,
        added: added,
        lastSeen: lastSeen ?? this.lastSeen,
        verified: verified ?? this.verified,
        relays: relays,
        online: online ?? this.online,
        path: path ?? this.path,
        note: note,
        bridged: bridged,
      );
}

enum ConvKind { direct, group, community, saved }

class Conversation {
  const Conversation({
    required this.id,
    required this.kind,
    required this.title,
    this.lastTs = 0,
    this.unread = 0,
    this.muted = false,
    this.pinned = false,
    this.lastText = '',
    this.lastMine = false,
    this.archived = false,
    this.mentions = 0,
  });
  final bool archived;

  /// Unread @mentions of me.
  final int mentions;
  final String id;
  final ConvKind kind;
  final String title;
  final int lastTs;
  final int unread;
  final bool muted;
  final bool pinned;
  final String lastText;

  /// The last message is mine (the list shows "You:" from this flag only —
  /// never from the text, which anyone can start with "You:").
  final bool lastMine;

  bool get isGroup => kind == ConvKind.group || kind == ConvKind.community;
  bool get isCommunity => kind == ConvKind.community;
  bool get isSaved => id == 's:me' || kind == ConvKind.saved;

  /// Peer id for direct conversations (`d:<peer>`).
  String? get peer => id.startsWith('d:') ? id.substring(2) : null;

  /// Group id for group conversations (`g:<gid>`).
  String? get gid => id.startsWith('g:') ? id.substring(2) : null;

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
        id: _s(j, 'id'),
        kind: _s(j, 'id').startsWith('s:')
            ? ConvKind.saved
            : switch (_i(j, 'kind')) { 1 => (_b(j, 'community') ? ConvKind.community : ConvKind.group), 2 => ConvKind.community, _ => ConvKind.direct },
        title: _s(j, 'title'),
        lastTs: _i(j, 'last_ts'),
        unread: _i(j, 'unread'),
        muted: _b(j, 'muted'),
        pinned: _b(j, 'pinned'),
        lastText: _s(j, 'last_text'),
        lastMine: _b(j, 'last_mine'),
        archived: _b(j, 'archived'),
        mentions: _i(j, 'mentions'),
      );

  Conversation copyWith({
    String? title,
    int? lastTs,
    int? unread,
    bool? muted,
    bool? pinned,
    String? lastText,
    bool? lastMine,
    bool? archived,
    int? mentions,
  }) =>
      Conversation(
        archived: archived ?? this.archived,
        mentions: mentions ?? this.mentions,
        id: id,
        kind: kind,
        title: title ?? this.title,
        lastTs: lastTs ?? this.lastTs,
        unread: unread ?? this.unread,
        muted: muted ?? this.muted,
        pinned: pinned ?? this.pinned,
        lastText: lastText ?? this.lastText,
        lastMine: lastMine ?? this.lastMine,
      );
}

enum MessageStatus { pending, sent, delivered, read, failed }

MessageStatus _msgStatus(int v) => switch (v) {
      0 => MessageStatus.pending,
      1 => MessageStatus.sent,
      2 => MessageStatus.delivered,
      3 => MessageStatus.read,
      _ => MessageStatus.failed,
    };

/// `join_invite` answer: [pending] = asked, not in the group yet.
class JoinResult {
  const JoinResult({required this.conv, required this.gid, this.name = '', this.pending = false});
  final String conv;
  final String gid;
  final String name;
  final bool pending;
}

class Message {
  const Message({
    required this.id,
    required this.conv,
    required this.author,
    required this.ts,
    this.hlc = 0,
    this.kind = 'text',
    this.body = '',
    this.status = MessageStatus.sent,
    this.edited = false,
    this.deleted = false,
    this.replyTo,
    this.reactions = const {},
    this.expires,
    this.mine = false,
    this.pinned = false,
    this.meta = const {},
    this.rawVotes,
    this.fileInfo,
    this.state = const {},
  });

  /// Shared message state carried in `reactions` under `__…` keys
  /// (`__checks`, `__seen`, `__cancelled`; `__votes` is kept in [rawVotes]).
  final Map<String, dynamic> state;

  /// Sent with "Gửi không âm báo": never notify or play a sound for it.
  bool get silent => meta['silent'] == true;

  /// `file: {state, progress, size, path, direction}` carried by file messages.
  final Map<String, dynamic>? fileInfo;

  final bool pinned;

  /// Free-form metadata: forwarded_from, mentions, poll, …
  final Map<String, dynamic> meta;

  String? get forwardedFrom => meta['forwarded_from']?.toString();

  /// Handed back by this friend after a restore from the recovery phrase and not signed
  /// by me (core `meta.restored_from`): the bubble says "Restored from …".
  String? get restoredFrom {
    final v = meta['restored_from']?.toString();
    return v == null || v.isEmpty ? null : v;
  }

  String? get restoredPeer => meta['restored_peer']?.toString();

  /// Handed back as "mine" without my own signature (or from an unverified offer): the
  /// label says "unverified" (core `meta.restored_unverified`).
  bool get restoredUnverified => meta['restored_unverified'] == true;

  /// Deleted for everyone: by whom (the author recalled it, or a group admin /
  /// moderator removed it). Null for older records.
  String? get deletedBy => meta['deleted_by']?.toString();

  /// Deleted for everyone by someone other than its author (a group admin).
  bool get removedByAdmin => deleted && deletedBy != null && deletedBy!.isNotEmpty && deletedBy != author;

  /// Self-destructing (a timer): never forwarded, copied or saved.
  bool get selfDestructs => expires != null;
  bool get isPoll => kind == 'poll';
  List<String> get mentions =>
      (meta['mentions'] is List) ? (meta['mentions'] as List).map((e) => e.toString()).toList() : const [];
  bool get mentionAll => meta['mention_all'] == true;

  /// Poll votes: `reactions.__votes {peer: idx}` (also accepts meta.votes).
  Map<String, int> get votes {
    final out = <String, int>{};
    final v = rawVotes;
    if (v is Map) {
      v.forEach((k, idx) {
        if (idx is num) out[k.toString()] = idx.toInt();
      });
    }
    return out;
  }

  final Object? rawVotes;

  final String id;
  final String conv;
  final String author;
  final int hlc;
  final int ts;
  final String kind;

  /// For text: the text. For file messages: JSON-ish file id / name (see
  /// [fileId]); kept as raw string per api.md.
  final String body;
  final MessageStatus status;
  final bool edited;
  final bool deleted;
  final String? replyTo;
  final Map<String, List<String>> reactions;
  final int? expires;
  final bool mine;

  bool get isFile => kind == 'file';
  bool get isSystem => kind == 'system' || kind == 'call';

  factory Message.fromJson(Map<String, dynamic> j) {
    if (j['author_name'] is String) PeerNames.learn(j['author']?.toString() ?? '', j['author_name'] as String);
    final r = <String, List<String>>{};
    final st = <String, dynamic>{};
    final rj = j['reactions'];
    Object? votes;
    if (rj is Map) {
      rj.forEach((k, v) {
        if (k == '__votes') {
          votes = v;
        } else if (k.toString().startsWith('__')) {
          st[k.toString()] = v;
        } else if (v is List && v.isNotEmpty) {
          r[k.toString()] = v.map((e) => e.toString()).toList();
        }
      });
    }
    final metaJ = j['meta'];
    final meta = metaJ is Map ? Map<String, dynamic>.of(metaJ.cast<String, dynamic>()) : <String, dynamic>{};
    if (j['silent'] == true) meta['silent'] = true;
    if (j['deleted_by'] is String) meta['deleted_by'] = j['deleted_by'];
    votes ??= meta['votes'];
    final body = j['body'];
    return Message(
      id: _s(j, 'id'),
      conv: _s(j, 'conv'),
      author: _s(j, 'author'),
      hlc: _i(j, 'hlc'),
      ts: _i(j, 'ts'),
      kind: _s(j, 'kind', 'text'),
      body: _bodyString(_s(j, 'kind', 'text'), body),
      status: _msgStatus(_i(j, 'status', 1)),
      edited: _b(j, 'edited'),
      deleted: _b(j, 'deleted'),
      replyTo: _so(j, 'reply_to'),
      reactions: r,
      expires: j['expires'] == null ? null : _i(j, 'expires'),
      mine: _b(j, 'mine'),
      pinned: _b(j, 'pinned'),
      meta: meta,
      rawVotes: votes,
      fileInfo: j['file'] is Map ? (j['file'] as Map).cast<String, dynamic>() : null,
      state: st,
    );
  }

  /// Applies a `message_update` payload.
  Message applyUpdate(Map<String, dynamic> u) {
    Map<String, List<String>>? r;
    Map<String, dynamic>? st;
    Object? votes = rawVotes;
    if (u['reactions'] is Map) {
      r = {};
      st = {};
      (u['reactions'] as Map).forEach((k, v) {
        if (k == '__votes') {
          votes = v;
        } else if (k.toString().startsWith('__')) {
          st![k.toString()] = v;
        } else if (v is List && v.isNotEmpty) {
          r![k.toString()] = v.map((e) => e.toString()).toList();
        }
      });
    }
    return Message(
      id: id,
      conv: conv,
      author: author,
      hlc: hlc,
      ts: ts,
      kind: kind,
      body: u.containsKey('body') ? _bodyString(kind, u['body']) : body,
      status: u.containsKey('status') ? _msgStatus(_i(u, 'status')) : status,
      edited: u.containsKey('edited') ? _b(u, 'edited') : edited,
      deleted: u.containsKey('deleted') ? _b(u, 'deleted') : deleted,
      replyTo: replyTo,
      reactions: r ?? reactions,
      expires: expires,
      mine: mine,
      pinned: u.containsKey('pinned') ? _b(u, 'pinned') : pinned,
      meta: u['deleted_by'] is String
          ? {...(u['meta'] is Map ? (u['meta'] as Map).cast<String, dynamic>() : meta), 'deleted_by': u['deleted_by']}
          : (u['meta'] is Map ? (u['meta'] as Map).cast<String, dynamic>() : meta),
      rawVotes: votes,
      fileInfo: u['file'] is Map ? (u['file'] as Map).cast<String, dynamic>() : fileInfo,
      state: st ?? state,
    );
  }
}

enum FileState { offered, transferring, done, failed, cancelled, paused }

class FileItem {
  const FileItem({
    required this.id,
    required this.conv,
    required this.peer,
    required this.name,
    required this.size,
    this.hash = '',
    this.path = '',
    this.incoming = false,
    this.state = FileState.offered,
    this.progress = 0,
    this.created = 0,
    this.speedBps,
  });
  final String id;
  final String conv;
  final String peer;
  final String name;
  final int size;
  final String hash;
  final String path;
  final bool incoming;
  final FileState state;
  final int progress;
  final int created;
  final int? speedBps;

  double get fraction => size <= 0 ? 0 : (progress / size).clamp(0.0, 1.0);
  bool get active => state == FileState.transferring || state == FileState.offered || state == FileState.paused;
  bool get isImage {
    final n = name.toLowerCase();
    return n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.webp') || n.endsWith('.gif') || n.endsWith('.heic') || n.endsWith('.heif');
  }

  factory FileItem.fromJson(Map<String, dynamic> j) => FileItem(
        id: _s(j, 'id'),
        conv: _s(j, 'conv'),
        peer: _s(j, 'peer'),
        name: safeDisplayName(_s(j, 'name', 'file')),
        size: _i(j, 'size'),
        hash: _s(j, 'hash'),
        path: _s(j, 'path'),
        incoming: _i(j, 'direction') == 1,
        state: FileState.values[_i(j, 'state').clamp(0, 5)],
        progress: _i(j, 'progress'),
        created: _i(j, 'created'),
        speedBps: j['speed_bps'] == null ? null : _i(j, 'speed_bps'),
      );

  FileItem copyWith({FileState? state, int? progress, int? speedBps}) => FileItem(
        id: id,
        conv: conv,
        peer: peer,
        name: name,
        size: size,
        hash: hash,
        path: path,
        incoming: incoming,
        state: state ?? this.state,
        progress: progress ?? this.progress,
        created: created,
        speedBps: speedBps ?? this.speedBps,
      );
}

class PeerPath {
  const PeerPath({required this.peer, required this.path, this.rttMs, this.remoteAddr});
  final String peer;
  final String path; // direct | lan | relay
  final int? rttMs;
  final String? remoteAddr;
  factory PeerPath.fromJson(Map<String, dynamic> j) => PeerPath(
        peer: _s(j, 'peer'),
        path: _s(j, 'path', 'relay'),
        rttMs: j['rtt_ms'] == null ? null : _i(j, 'rtt_ms'),
        remoteAddr: _so(j, 'remote_addr'),
      );
}

class Endpoint {
  const Endpoint(this.url, this.connected);
  final String url;
  final bool connected;
  factory Endpoint.fromJson(Map<String, dynamic> j) => Endpoint(_s(j, 'url'), _b(j, 'connected'));
}

class NetStatus {
  const NetStatus({
    this.nat = 'unknown',
    this.publicIp,
    this.port = 0,
    this.addrs = const [],
    this.upnp = false,
    this.relays = const [],
    this.nostr = const [],
    this.dht = false,
    this.lanPeers = 0,
    this.peers = const [],
  });
  final String nat;
  final String? publicIp;
  final int port;
  final List<String> addrs;
  final bool upnp;
  final List<Endpoint> relays;
  final List<Endpoint> nostr;
  final bool dht;
  final int lanPeers;
  final List<PeerPath> peers;

  bool get online =>
      relays.any((r) => r.connected) || nostr.any((n) => n.connected) || peers.isNotEmpty || dht;

  factory NetStatus.fromJson(Map<String, dynamic> j) {
    final upnp = j['upnp'];
    final dht = j['dht'];
    return NetStatus(
      nat: _s(j, 'nat', 'unknown'),
      publicIp: _so(j, 'public_ip'),
      port: _i(j, 'port'),
      addrs: _ls(j, 'addrs'),
      upnp: upnp is bool ? upnp : (upnp is Map ? _b(upnp, 'mapped', true) : upnp != null),
      relays: _list(j['relays']).map(Endpoint.fromJson).toList(),
      nostr: _list(j['nostr']).map(Endpoint.fromJson).toList(),
      dht: dht is bool ? dht : (dht is num ? dht > 0 : dht != null),
      lanPeers: j['lan_peers'] is List ? (j['lan_peers'] as List).length : _i(j, 'lan_peers'),
      peers: _list(j['peers']).map(PeerPath.fromJson).toList(),
    );
  }
}

/// Names the core told us for people who aren't contacts (group members:
/// `members[].name` of group info, `author_name` of group messages) — the
/// fallback of [ContactsStore.nameOf] before a short id.
class PeerNames {
  PeerNames._();
  static final Map<String, String> known = {};
  static void learn(String peer, String? name) {
    if (peer.isEmpty || name == null || name.isEmpty) return;
    if (known.length > 5000) known.clear();
    known[peer] = name;
  }
}

/// A report waiting for an admin (`group_report` event / `group_reports`).
class GroupReport {
  const GroupReport({
    required this.id,
    required this.gid,
    required this.conv,
    required this.groupName,
    this.msgId,
    this.excerpt = '',
    this.msgExists = false,
    required this.member,
    required this.memberName,
    this.memberInGroup = true,
    required this.reporter,
    required this.reporterName,
    required this.reason,
    this.note = '',
    required this.ts,
  });
  final String id;
  final String gid;
  final String conv;
  final String groupName;
  final String? msgId;

  /// The admin's own copy of the message text (empty: not text / not here).
  final String excerpt;
  final bool msgExists;
  final String member;
  final String memberName;
  final bool memberInGroup;
  final String reporter;
  final String reporterName;

  /// spam | harassment | adult | other
  final String reason;
  final String note;
  final int ts;

  factory GroupReport.fromJson(Map<String, dynamic> j) => GroupReport(
        id: _s(j, 'id'),
        gid: _s(j, 'gid'),
        conv: _s(j, 'conv', 'g:${_s(j, 'gid')}'),
        groupName: _s(j, 'group_name'),
        msgId: j['msg_id']?.toString(),
        excerpt: _s(j, 'excerpt'),
        msgExists: _b(j, 'msg_exists'),
        member: _s(j, 'member'),
        memberName: _s(j, 'member_name'),
        memberInGroup: j['member_in_group'] != false,
        reporter: _s(j, 'reporter'),
        reporterName: _s(j, 'reporter_name'),
        reason: _s(j, 'reason', 'other'),
        note: _s(j, 'note'),
        ts: _i(j, 'ts'),
      );
}

/// A group I reported / blocked (`privacy.blocked_groups`).
class BlockedGroup {
  const BlockedGroup({required this.gid, this.name = '', this.at = 0});
  final String gid;
  final String name;
  final int at;
  factory BlockedGroup.fromJson(Map<String, dynamic> j) => BlockedGroup(gid: _s(j, 'gid'), name: _s(j, 'name'), at: _i(j, 'at'));
}

/// Community permissions (`group_roles[].perms`, `group_info.my_perms`).
abstract final class Perm {
  static const viewChannel = 'view_channel';
  static const sendMessages = 'send_messages';
  static const manageMessages = 'manage_messages';
  static const mentionEveryone = 'mention_everyone';
  static const connectVoice = 'connect_voice';
  static const manageChannels = 'manage_channels';
  static const manageRoles = 'manage_roles';
  static const kick = 'kick';
  static const ban = 'ban';
  static const timeout = 'timeout';
  static const manageBots = 'manage_bots';
  static const manageCommunity = 'manage_community';

  /// Add people / create invite links.
  static const invite = 'invite';

  /// Pin / unpin messages.
  static const pin = 'pin';

  /// Send photos, videos and files (`send_file`; voice notes need only send_messages).
  static const sendMedia = 'send_media';

  /// Every permission, in the order the settings list them.
  static const all = [
    viewChannel, sendMessages, sendMedia, manageMessages, mentionEveryone, connectVoice, manageChannels,
    manageRoles, kick, ban, timeout, manageBots, invite, pin, manageCommunity,
  ];

  /// `@everyone`'s permissions in a new community (invite links are the admins'
  /// by default — a role may give `invite` to others).
  static const everyoneDefault = [viewChannel, sendMessages, sendMedia, connectVoice];

  /// `@everyone`'s permissions in a new plain group (members may pin, like before).
  static const everyoneGroupDefault = [viewChannel, sendMessages, sendMedia, connectVoice, pin];

  static List<String> everyoneFor({required bool community}) => community ? everyoneDefault : everyoneGroupDefault;

  /// Plain groups: the per-admin role of [peer] (its admin rights).
  static String adminRoleId(String peer) => 'admin:$peer';

  /// The admin rights a plain group shows as switches (ban + kick are one).
  static const adminRights = [manageCommunity, manageMessages, ban, invite, pin, manageRoles, timeout];

  /// The member permissions a plain group shows as switches.
  static const memberRights = [sendMessages, sendMedia, invite, pin, manageCommunity];

  /// An admin without an `admin:<peer>` rights role (made before rights
  /// existed): every permission, in communities and plain groups alike.
  static List<String> legacyAdmin({required bool community}) => all;

  /// The built-in `admin` role: every permission, `manage_community` included
  /// (owner decision 2026-11-07; dissolving stays owner-only).
  static const admin = all;
}

/// A community role (`group_roles`). Built-in: `everyone` and `admin`.
/// Neutral colour of `@everyone` and of roles without a colour (Lumora muted).
const kDefaultRoleColor = '#9AA0C3';

/// Colour of the built-in admin role and of per-admin roles (Lumora primary).
const kAdminRoleColor = '#6C5CE7';

class GroupRole {
  const GroupRole({required this.id, required this.name, this.color = kDefaultRoleColor, this.perms = const [], this.position = 0, this.builtin = false});
  static const everyoneId = 'everyone';
  static const adminId = 'admin';
  final String id;
  final String name;

  /// `#RRGGBB`.
  final String color;
  final List<String> perms;
  final int position;
  final bool builtin;
  bool get isEveryone => id == everyoneId;
  bool get isAdmin => id == adminId;

  /// A plain group's per-admin rights role (`admin:<peer>`): never shown as a role.
  bool get isAdminRights => id.startsWith('admin:');

  /// [color] as a Flutter colour value (0xAARRGGBB); grey when unreadable.
  int get argb {
    final h = color.replaceAll('#', '');
    final v = int.tryParse(h.length == 6 ? h : '', radix: 16);
    return v == null ? 0xFF9AA0C3 : 0xFF000000 | v;
  }

  factory GroupRole.fromJson(Map<String, dynamic> j) => GroupRole(
        id: _s(j, 'id'),
        name: _s(j, 'name'),
        color: _s(j, 'color', kDefaultRoleColor),
        perms: _ls(j, 'perms'),
        position: _i(j, 'position'),
        builtin: _b(j, 'builtin'),
      );
}

class GroupMember {
  const GroupMember({required this.peer, required this.name, this.role = 'member', this.roles = const [], this.timeoutUntil = 0, this.online});
  final String peer;
  final String name;
  final String role; // owner | admin | member

  /// Custom role ids (never `everyone` / `admin`: those follow from [role]).
  final List<String> roles;

  /// Timed out (may not post / talk) until this epoch ms; 0 = not.
  final int timeoutUntil;

  /// The core's presence hint, when it sends one.
  final bool? online;
  bool timedOut([int? nowMs]) => timeoutUntil > (nowMs ?? DateTime.now().millisecondsSinceEpoch);
  factory GroupMember.fromJson(Map<String, dynamic> j) {
    final m = GroupMember(
      peer: _s(j, 'peer'),
      name: _s(j, 'name'),
      role: _s(j, 'role', 'member'),
      roles: _ls(j, 'roles'),
      timeoutUntil: _i(j, 'timeout_until'),
      online: j['online'] is bool ? j['online'] as bool : null,
    );
    PeerNames.learn(m.peer, m.name);
    return m;
  }
}

class GroupInfo {
  const GroupInfo({
    required this.gid,
    required this.name,
    this.owner = '',
    this.members = const [],
    this.epoch = 0,
    this.myRole = 'member',
    this.community = false,
    this.channels = const [],
    this.description = '',
    this.hasAvatar = false,
    this.hasCover = false,
    this.coverRev = '',
    this.adminsOnly = false,
    this.slowModeS = 0,
    this.banned = const [],
    this.bots = const [],
    this.handle,
    this.roles = const [],
    this.botRoles = const {},
    List<String>? myPerms,
    this.approveJoins = false,
    this.joinRequests = const [],
    this.rulesV2 = true,
  }) : _myPerms = myPerms;

  /// The group follows the Community 2.0 rules (`rules_v2`); false: an older group
  /// an admin may upgrade ([LumoraApi.groupUpgradeRules]) once every member runs 1.0.8+.
  final bool rulesV2;

  /// "Approve new members": invite-link joins wait in [joinRequests].
  final bool approveJoins;
  final List<JoinRequest> joinRequests;

  /// Bot peer → its custom role ids (`bots[].roles`).
  final Map<String, List<String>> botRoles;
  final bool adminsOnly;

  /// Community roles, highest first (empty from an older core).
  final List<GroupRole> roles;
  final List<String>? _myPerms;

  /// My permissions here: `my_perms` from the core, else what my fixed role
  /// gives (owner and admins: all; member: @everyone's).
  List<String> get myPerms {
    final p = _myPerms;
    if (p != null) return p;
    return switch (myRole) {
      'owner' => Perm.all,
      'admin' => Perm.legacyAdmin(community: community),
      'none' => const [],
      _ => roles.where((r) => r.isEveryone).firstOrNull?.perms ?? Perm.everyoneFor(community: community),
    };
  }

  bool can(String perm) => myRole == 'owner' || myPerms.contains(perm);

  /// Owner or the built-in admin role (sees private channels, posts anywhere).
  bool get isAdminish => myRole == 'owner' || myRole == 'admin';

  GroupRole? roleById(String id) => roles.where((r) => r.id == id).firstOrNull;

  /// Roles a person picks from (no built-ins, no per-admin rights roles).
  List<GroupRole> get customRoles => roles.where((r) => !r.builtin && !r.isAdminRights).toList();

  /// Plain groups: [peer]'s admin rights (their `admin:<peer>` role), or every
  /// admin right when they were made admin before rights existed.
  Set<String> adminRightsOf(String peer) {
    final r = roleById(Perm.adminRoleId(peer));
    final m = member(peer);
    if (m?.role == 'owner') return Perm.all.toSet();
    if (r == null || !(m?.roles.contains(r.id) ?? false)) return Perm.legacyAdmin(community: community).toSet();
    return r.perms.toSet();
  }

  /// [m]'s roles, highest first: the built-in admin role when they hold it,
  /// then their custom roles (never `@everyone`).
  List<GroupRole> rolesOf(GroupMember m) {
    final ids = {if (m.role == 'admin' || m.role == 'owner') GroupRole.adminId, ...m.roles};
    return roles.where((r) => ids.contains(r.id) && !r.isEveryone && !r.isAdminRights).toList()..sort((a, b) => b.position.compareTo(a.position));
  }

  /// [m]'s highest role (null: only `@everyone`).
  GroupRole? topRole(GroupMember m) => rolesOf(m).firstOrNull;

  GroupMember? member(String peer) => members.where((m) => m.peer == peer).firstOrNull;

  /// I may post in [ch]: not timed out, `send_messages`, and in an announcement
  /// channel `manage_messages` or a role on its allow list (owner/admins always).
  bool canPostIn(Channel ch, String me) {
    if (isAdminish) return true;
    final mine = member(me);
    if (mine == null) return false;
    if (mine.timedOut()) return false;
    if (!can(Perm.sendMessages)) return false;
    if (adminsOnly) return false;
    if (ch.announce && !can(Perm.manageMessages) && !ch.allowRoles.contains(GroupRole.everyoneId) && !mine.roles.any(ch.allowRoles.contains)) return false;
    return true;
  }
  final int slowModeS;
  final List<String> banned;

  /// Bots in the group: peer + whether they may read every message.
  final List<(String peer, bool readAll)> bots;

  /// `@handle·tag` when the group is public.
  final String? handle;
  bool get isPublic => handle != null && handle!.isNotEmpty;
  final String description;
  final bool hasAvatar;
  final bool hasCover;

  /// Id of the latest cover change ("" = none): a new value → fetch it again.
  final String coverRev;
  final bool community;
  final List<Channel> channels;
  final String gid;
  final String name;
  final String owner;
  final List<GroupMember> members;
  final int epoch;
  final String myRole;
  bool get canManage => myRole == 'owner' || myRole == 'admin';

  factory GroupInfo.fromJson(Map<String, dynamic> j) => GroupInfo(
        gid: _s(j, 'gid'),
        name: _s(j, 'name'),
        owner: _s(j, 'owner'),
        members: _list(j['members']).map(GroupMember.fromJson).toList(),
        epoch: _i(j, 'epoch'),
        myRole: _s(j, 'my_role', 'member'),
        community: _i(j, 'kind') == 1 || _b(j, 'community'),
        description: _s(j, 'description'),
        hasAvatar: _b(j, 'has_avatar'),
        hasCover: _b(j, 'has_cover'),
        coverRev: _s(j, 'cover_rev'),
        adminsOnly: _b(j, 'admins_only'),
        slowModeS: _i(j, 'slow_mode_s'),
        banned: (j['banned'] as List? ?? const []).map((e) => e is Map ? (e['peer']?.toString() ?? '') : e.toString()).toList(),
        bots: [
          for (final b in (j['bots'] as List? ?? const []))
            if (b is Map) (b['peer']?.toString() ?? '', b['read_all'] == true) else (b.toString(), false),
        ],
        handle: _so(j, 'handle'),
        channels: _list(j['channels']).map(Channel.fromJson).toList(),
        roles: (_list(j['roles']).map(GroupRole.fromJson).toList()..sort((a, b) => b.position.compareTo(a.position))),
        myPerms: j['my_perms'] is List ? _ls(j, 'my_perms') : null,
        approveJoins: _b(j, 'approve_joins'),
        rulesV2: j['rules_v2'] != false,
        joinRequests: _list(j['join_requests']).map(JoinRequest.fromJson).toList(),
        botRoles: {
          for (final b in (j['bots'] as List? ?? const []))
            if (b is Map && b['roles'] is List) b['peer']?.toString() ?? '': [for (final r in b['roles'] as List) r.toString()],
        },
      );
}

/// Someone waiting to join through an invite link ("approve new members").
class JoinRequest {
  const JoinRequest({required this.peer, this.name = '', this.at = 0});
  final String peer;
  final String name;
  final int at;
  factory JoinRequest.fromJson(Map<String, dynamic> j) => JoinRequest(peer: _s(j, 'peer'), name: _s(j, 'name'), at: _i(j, 'at'));
}

/// One of my live invite links (`group_invite_links`).
class InviteLink {
  const InviteLink({required this.id, required this.link, this.created = 0, this.expires = 0});
  final String id;
  final String link;
  final int created;

  /// Epoch ms (0 = never).
  final int expires;
  factory InviteLink.fromJson(Map<String, dynamic> j) => InviteLink(id: _s(j, 'id'), link: _s(j, 'link'), created: _i(j, 'created'), expires: _i(j, 'expires'));
}

/// An invitation to a group waiting for my answer (`group_invites`).
class GroupInvite {
  const GroupInvite({required this.gid, required this.name, this.community = false, this.by = '', this.byName = '', this.at = 0, this.members = 0});
  final String gid;
  final String name;
  final bool community;
  final String by;
  final String byName;
  final int at;
  final int members;
  factory GroupInvite.fromJson(Map<String, dynamic> j) => GroupInvite(
        gid: _s(j, 'gid'),
        name: _s(j, 'name'),
        community: _i(j, 'kind') == 1,
        by: _s(j, 'by'),
        byName: _s(j, 'by_name'),
        at: _i(j, 'at'),
        members: _i(j, 'members'),
      );
}

class Channel {
  const Channel({
    required this.id,
    required this.name,
    required this.voice,
    required this.conv,
    this.participants = const [],
    this.muted = const [],
    this.unread = 0,
    this.category = '',
    this.topic = '',
    this.position = 0,
    this.private = false,
    this.allowRoles = const [],
    this.announce = false,
  });
  final String id;
  final String name;
  final bool voice;
  final String conv;

  /// Shown under the channel's name in its header.
  final String topic;

  /// Order inside its category (lower first).
  final int position;

  /// Only [allowRoles] (plus owner / admins) see it.
  final bool private;
  final List<String> allowRoles;

  /// Announcement channel: only `manage_messages` (or [allowRoles]) may post.
  final bool announce;

  /// Voice channel: who is in the room right now (accounts).
  final List<String> participants;

  /// Voice channel: participants with their microphone off.
  final List<String> muted;
  final int unread;
  final String category;
  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
        id: _s(j, 'id'),
        name: _s(j, 'name'),
        voice: _s(j, 'kind') == 'voice' || _b(j, 'voice'),
        conv: _s(j, 'conv'),
        participants: _ls(j, 'participants'),
        muted: _ls(j, 'muted'),
        unread: _i(j, 'unread'),
        category: _s(j, 'category'),
        topic: _s(j, 'topic'),
        position: _i(j, 'position'),
        private: _b(j, 'private'),
        allowRoles: _ls(j, 'allow_roles'),
        announce: _b(j, 'announce'),
      );
}

class Space {
  const Space({
    required this.id,
    required this.name,
    this.channels = const [],
    this.members = 0,
    this.hasCover = false,
    this.coverRev = '',
    this.myRole = 'member',
    this.owner = '',
  });
  final String id;
  final String name;
  final List<Channel> channels;
  final int members;
  final bool hasCover;

  /// Id of the latest cover change ("" = none).
  final String coverRev;

  /// `owner` | `admin` | `member`.
  final String myRole;
  final String owner;
  bool get isOwner => myRole == 'owner';
  bool get canManage => myRole == 'owner' || myRole == 'admin';
  factory Space.fromJson(Map<String, dynamic> j) => Space(
        id: _s(j, 'id'),
        name: _s(j, 'name'),
        channels: _list(j['channels']).map(Channel.fromJson).toList(),
        members: _i(j, 'members'),
        hasCover: _b(j, 'has_cover'),
        coverRev: _s(j, 'cover_rev'),
        myRole: _s(j, 'my_role', 'member'),
        owner: _s(j, 'owner'),
      );
}

enum CallPhase { ringing, incoming, active, ended }

class CallState {
  const CallState({
    required this.callId,
    required this.conv,
    required this.peer,
    required this.phase,
    this.video = false,
    this.participants = const [],
    this.streams = const {},
    this.startedAt,
    this.speaking = const {},
    this.quality = 3,
    this.accounts = const {},
    this.names = const {},
    this.room = false,
  });
  final String callId;
  final String conv;
  final String peer;
  final CallPhase phase;
  final bool video;
  final List<String> participants;

  /// peer -> media stream id (optional extension: `streams` map in `call`).
  final Map<String, int> streams;
  final int? startedAt;
  final Set<String> speaking;

  /// 0..3 bars (optional `quality` field in `call` event).
  final int quality;

  /// Participant (a device key) → its account: a friend on a linked device
  /// joins with that device's key, while contacts / the 1-1 `peer` use the
  /// account (`participants[].account`).
  final Map<String, String> accounts;

  /// Participant (device key) → the name the core knows (`participants[].name`).
  final Map<String, String> names;

  /// A community voice channel (drop-in room): never rings, goes on alone.
  final bool room;

  String accountOf(String participant) => accounts[participant] ?? participant;

  /// Whether `account` (or one of its devices) is talking right now.
  bool speakingAccount(String account) => speaking.contains(account) || speaking.any((p) => accountOf(p) == account);

  /// The camera stream of `account` (keyed by its account or by one of its devices).
  int? streamOf(String account) {
    final direct = streams[account];
    if (direct != null) return direct;
    for (final e in streams.entries) {
      if (accounts[e.key] == account) return e.value;
    }
    return null;
  }

  CallState copyWith({CallPhase? phase, List<String>? participants, Map<String, int>? streams, int? startedAt, Set<String>? speaking, int? quality, Map<String, String>? accounts, Map<String, String>? names}) => CallState(
        callId: callId,
        conv: conv,
        peer: peer,
        phase: phase ?? this.phase,
        video: video,
        participants: participants ?? this.participants,
        streams: streams ?? this.streams,
        startedAt: startedAt ?? this.startedAt,
        speaking: speaking ?? this.speaking,
        quality: quality ?? this.quality,
        accounts: accounts ?? this.accounts,
        names: names ?? this.names,
        room: room,
      );

  factory CallState.fromJson(Map<String, dynamic> j) {
    final st = _s(j, 'state', 'ringing');
    final streams = <String, int>{};
    if (j['streams'] is Map) {
      (j['streams'] as Map).forEach((k, v) {
        if (v is num) streams[k.toString()] = v.toInt();
      });
    }
    // Real core: `from` (caller, null when outgoing) and participants as
    // `[{peer, name}]`; older shape: `peer` + `participants: [peer]`.
    final conv = _s(j, 'conv');
    final parts = (j['participants'] is List)
        ? (j['participants'] as List).map((e) => e is Map ? (e['peer']?.toString() ?? '') : e.toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];
    final accounts = <String, String>{};
    final names = <String, String>{};
    if (j['participants'] is List) {
      for (final e in j['participants'] as List) {
        if (e is! Map) continue;
        final p = e['peer']?.toString() ?? '';
        if (p.isEmpty) continue;
        final a = e['account']?.toString() ?? '';
        if (a.isNotEmpty && a != p) accounts[p] = a;
        final n = e['name']?.toString() ?? '';
        if (n.isNotEmpty) names[p] = n;
      }
    }
    final peer = _so(j, 'peer') ?? _so(j, 'from') ?? (conv.startsWith('d:') ? conv.substring(2) : (parts.isNotEmpty ? parts.first : ''));
    if (parts.isEmpty && conv.startsWith('d:')) parts.add(conv.substring(2));
    return CallState(
      callId: _s(j, 'call_id'),
      conv: conv,
      peer: peer,
      phase: switch (st) {
        'incoming' => CallPhase.incoming,
        'active' || 'connected' => CallPhase.active,
        'ringing' || 'calling' || 'connecting' => CallPhase.ringing,
        _ => CallPhase.ended, // ended, missed, declined, cancelled, busy…
      },
      video: _b(j, 'video'),
      participants: parts,
      streams: streams,
      startedAt: j['started_at'] == null ? null : _i(j, 'started_at'),
      speaking: _ls(j, 'speaking').toSet(),
      quality: _i(j, 'quality', 3).clamp(0, 3),
      accounts: accounts,
      names: names,
      room: _b(j, 'room'),
    );
  }
}

class RemoteStatus {
  const RemoteStatus({
    this.myShortId = '',
    this.password = '',
    this.unattended = false,
    this.allowControl = true,
    this.wayland = const {},
    this.allowPower = false,
    this.allowIncoming = true,
  });
  final bool allowPower;

  /// Control requests reach this device at all (off: all refused).
  final bool allowIncoming;
  final String myShortId;
  final String password;
  final bool unattended;
  final bool allowControl;
  final Map<String, dynamic> wayland;

  factory RemoteStatus.fromJson(Map<String, dynamic> j) => RemoteStatus(
        myShortId: _s(j, 'my_short_id'),
        password: _s(j, 'password'),
        unattended: _b(j, 'unattended'),
        allowControl: _b(j, 'allow_control', true),
        allowPower: _b(j, 'allow_power'),
        allowIncoming: _b(j, 'allow_incoming', true),
        wayland: j['diagnostics'] is Map ? _map(j['diagnostics']) : _map(j['wayland']),
      );

  RemoteStatus copyWith({String? password, bool? unattended, bool? allowControl, bool? allowPower, bool? allowIncoming}) => RemoteStatus(
        allowPower: allowPower ?? this.allowPower,
        allowIncoming: allowIncoming ?? this.allowIncoming,
        myShortId: myShortId,
        password: password ?? this.password,
        unattended: unattended ?? this.unattended,
        allowControl: allowControl ?? this.allowControl,
        wayland: wayland,
      );
}

class RemoteRequest {
  const RemoteRequest({required this.session, required this.peer, required this.name, this.viewOnly = false, this.ask = false, this.shortId = '', String? account, this.own = false})
      : account = account ?? peer;
  final String session;
  /// Friend asked without a password: the host decides (accept/deny).
  final bool ask;
  final String peer;
  /// The name the requester gave themselves (anyone can pick any name).
  final String name;
  final bool viewOnly;
  /// Short form of the requester's ID (cannot be faked).
  final String shortId;
  /// The requester's account (a friend may ask from a linked device whose key
  /// isn't their account); older cores send only `peer`.
  final String account;

  /// The request comes from another of my own devices.
  final bool own;
  factory RemoteRequest.fromJson(Map<String, dynamic> j) => RemoteRequest(
        session: _s(j, 'session'),
        peer: _s(j, 'peer'),
        account: _so(j, 'account') ?? _s(j, 'peer'),
        own: _b(j, 'own'),
        name: _s(j, 'name'),
        viewOnly: _b(j, 'view_only'),
        ask: _b(j, 'ask'),
        shortId: _s(j, 'short_id'),
      );
}

/// `failed`: the session could not start or broke (e.g. this device's screen
/// could not be captured); it is over, with a plain `reason`.
enum RemotePhase { connecting, active, ended, denied, failed }

class RemoteState {
  const RemoteState({
    required this.session,
    required this.peer,
    required this.phase,
    this.width = 0,
    this.height = 0,
    this.viewer = true,
    this.stream = 0,
    String? account,
  }) : account = account ?? peer;
  final String session;
  final String peer;

  /// The account behind `peer` (a device key for a friend's linked device).
  final String account;
  final RemotePhase phase;
  final int width;
  final int height;
  final bool viewer; // role == viewer
  final int stream;
  factory RemoteState.fromJson(Map<String, dynamic> j) {
    final st = _s(j, 'state', 'connecting');
    return RemoteState(
      session: _s(j, 'session'),
      peer: _s(j, 'peer'),
      phase: RemotePhase.values.firstWhere((p) => p.name == st, orElse: () => RemotePhase.connecting),
      width: _i(j, 'width'),
      height: _i(j, 'height'),
      viewer: _s(j, 'role', 'viewer') == 'viewer',
      stream: _i(j, 'stream'),
      account: _so(j, 'account'),
    );
  }
}

class DiagCheck {
  const DiagCheck({required this.id, required this.ok, required this.title, this.detail = '', this.fixSteps = const [], this.commands = const []});
  final String id;
  final bool ok;
  final String title;
  final String detail;
  final List<String> fixSteps;

  /// Terminal commands (shown only under "Technical details").
  final List<String> commands;
  factory DiagCheck.fromJson(Map<String, dynamic> j) => DiagCheck(
        id: _s(j, 'id'),
        ok: _b(j, 'ok'),
        title: _s(j, 'title'),
        detail: _s(j, 'detail'),
        fixSteps: _ls(j, 'fix_steps'),
        commands: _ls(j, 'commands'),
      );
}

class Diagnostics {
  const Diagnostics({this.platform = '', this.sessionType = '', this.desktop = '', this.checks = const []});
  final String platform;
  final String sessionType;
  final String desktop;
  final List<DiagCheck> checks;
  factory Diagnostics.fromJson(Map<String, dynamic> j) => Diagnostics(
        platform: _s(j, 'platform'),
        sessionType: _s(j, 'session_type'),
        desktop: _s(j, 'desktop'),
        checks: _list(j['checks']).map(DiagCheck.fromJson).toList(),
      );
}

class Profile {
  const Profile({this.name = '', this.bio = '', this.status = 'online', this.avatar, this.cover});
  final String? cover; // base64 JPEG 1280x720
  final String name;
  final String bio;
  final String status; // online | away | dnd | invisible
  final String? avatar; // base64
  factory Profile.fromJson(Map<String, dynamic> j) =>
      Profile(name: _s(j, 'name'), bio: _s(j, 'bio'), status: _s(j, 'status', 'online'), avatar: _so(j, 'avatar'), cover: _so(j, 'cover'));
  Profile copyWith({String? name, String? bio, String? status, String? avatar, bool clearAvatar = false, String? cover}) => Profile(
        cover: cover ?? this.cover,
        name: name ?? this.name,
        bio: bio ?? this.bio,
        status: status ?? this.status,
        avatar: clearAvatar ? null : (avatar ?? this.avatar),
      );
}

class ScheduledMessage {
  const ScheduledMessage({required this.id, required this.conv, required this.text, required this.at});
  final String id;
  final String conv;
  final String text;
  final int at;
  factory ScheduledMessage.fromJson(Map<String, dynamic> j) =>
      ScheduledMessage(id: _s(j, 'sched_id', _s(j, 'id')), conv: _s(j, 'conv'), text: _s(j, 'text'), at: _i(j, 'at'));
}

class InviteInfo {
  const InviteInfo({this.name = '', this.valid = false, this.alreadyMember = false, this.members = 0, this.community = false, this.blocked = false});
  final String name;

  /// A group I reported / blocked (on any of my devices): joining is refused.
  final bool blocked;
  final bool valid;
  final bool alreadyMember;
  final int members;
  final bool community;
  factory InviteInfo.fromJson(Map<String, dynamic> j) => InviteInfo(
        name: _s(j, 'name'),
        valid: _b(j, 'valid'),
        alreadyMember: _b(j, 'already_member'),
        members: _i(j, 'members'),
        community: _i(j, 'kind') == 1,
        blocked: _b(j, 'blocked'),
      );
}

/// Poll body: `{question, options[]}` (JSON in body).
class PollData {
  const PollData(this.question, this.options);
  final String question;
  final List<String> options;
  static PollData? parse(Message m) {
    try {
      final j = m.meta['poll'] is Map ? m.meta['poll'] as Map : jsonDecode(m.body);
      if (j is Map) {
        return PollData(j['question']?.toString() ?? '', (j['options'] as List? ?? const []).map((e) => e.toString()).toList());
      }
    } catch (_) {}
    return null;
  }
}

/// Checklist body: `{title, items: [{id, text}]}`; ticks live in
/// `reactions.__checks {"<id>": {done, by, at}}`.
class ChecklistItem {
  const ChecklistItem(this.id, this.text, {this.done = false, this.by, this.at = 0});
  final int id;
  final String text;
  final bool done;

  /// Who last ticked (or unticked) it, and when (ms).
  final String? by;
  final int at;
}

class ChecklistData {
  const ChecklistData(this.title, this.items);
  final String title;
  final List<ChecklistItem> items;
  int get doneCount => items.where((i) => i.done).length;

  static ChecklistData? parse(Message m) {
    try {
      final j = jsonDecode(m.body);
      if (j is! Map) return null;
      final checks = m.state['__checks'];
      final items = <ChecklistItem>[];
      for (final it in (j['items'] as List? ?? const [])) {
        if (it is! Map) continue;
        final id = (it['id'] as num?)?.toInt() ?? items.length;
        final c = checks is Map ? checks['$id'] : null;
        items.add(ChecklistItem(
          id,
          it['text']?.toString() ?? '',
          done: c is Map && c['done'] == true,
          by: c is Map ? c['by']?.toString() : null,
          at: c is Map ? (c['at'] as num?)?.toInt() ?? 0 : 0,
        ));
      }
      return ChecklistData(j['title']?.toString() ?? '', items);
    } catch (_) {
      return null;
    }
  }
}

/// Reminder body: `{title, at_ms, note}`; state in `reactions.__seen
/// {peer: ms}` and `reactions.__cancelled {by, at}`.
class ReminderData {
  const ReminderData(this.title, this.atMs, this.note, {this.seen = const {}, this.cancelledBy, this.cancelledAt = 0});
  final String title;
  final int atMs;
  final String note;
  final Map<String, int> seen;
  final String? cancelledBy;
  final int cancelledAt;
  bool get cancelled => cancelledAt > 0 || cancelledBy != null;
  DateTime get at => DateTime.fromMillisecondsSinceEpoch(atMs);

  static ReminderData? parse(Message m) {
    try {
      final j = jsonDecode(m.body);
      if (j is! Map) return null;
      final seen = <String, int>{};
      final sj = m.state['__seen'];
      if (sj is Map) {
        sj.forEach((k, v) => seen[k.toString()] = v is num ? v.toInt() : 0);
      }
      final c = m.state['__cancelled'];
      return ReminderData(
        j['title']?.toString() ?? '',
        (j['at_ms'] as num?)?.toInt() ?? 0,
        j['note']?.toString() ?? '',
        seen: seen,
        cancelledBy: c is Map ? c['by']?.toString() : null,
        cancelledAt: c is Map ? (c['at'] as num?)?.toInt() ?? 1 : (c is num ? c.toInt() : (c == true ? 1 : 0)),
      );
    } catch (_) {
      return null;
    }
  }
}

class Story {
  const Story({required this.id, required this.author, required this.created, this.text = '', this.hasImage = false, this.bg, this.seen = false, this.views = 0});
  final String id;
  final String author;
  final int created;
  final String text;
  final bool hasImage;
  final String? bg;
  final bool seen;
  final int views;
  factory Story.fromJson(Map<String, dynamic> j) => Story(
        id: _s(j, 'id'),
        author: _s(j, 'author'),
        created: _i(j, 'created'),
        text: _s(j, 'text'),
        hasImage: _b(j, 'has_image'),
        bg: _so(j, 'bg'),
        seen: _b(j, 'seen'),
        views: _i(j, 'views'),
      );
  Story markSeen() => Story(id: id, author: author, created: created, text: text, hasImage: hasImage, bg: bg, seen: true, views: views);
}

/// One person who saw my story ([ts]: when, ms; 0 = unknown).
class StoryView {
  const StoryView(this.peer, {this.ts = 0, this.name = ''});
  final String peer;
  final int ts;
  final String name;
}

/// Location body: {lat, lon, accuracy_m, label, live_until, updated}.
class LocationData {
  const LocationData(this.lat, this.lon, {this.accuracy = 0, this.label = '', this.liveUntil = 0, this.updated = 0, this.stopped = false});
  final double lat;
  final double lon;
  final double accuracy;
  final String label;
  final int liveUntil;
  final int updated;
  final bool stopped;
  bool isLive(int now) => liveUntil > now && !stopped;
  static LocationData? parse(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        return LocationData(
          (j['lat'] as num).toDouble(),
          (j['lon'] as num).toDouble(),
          accuracy: (j['accuracy_m'] as num?)?.toDouble() ?? 0,
          label: j['label']?.toString() ?? '',
          liveUntil: (j['live_until'] as num?)?.toInt() ?? 0,
          updated: (j['updated'] as num?)?.toInt() ?? 0,
          stopped: j['stopped'] == true,
        );
      }
    } catch (_) {}
    return null;
  }
}

/// Contact card body: {peer, short_id, name}.
class ContactCard {
  const ContactCard(this.peer, this.shortId, this.name);
  final String peer;
  final String shortId;
  final String name;
  static ContactCard? parse(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) return ContactCard(j['peer']?.toString() ?? '', j['short_id']?.toString() ?? '', j['name']?.toString() ?? '');
    } catch (_) {}
    return null;
  }
}

/// Voice body: file-like + {duration_ms, wave[32]}.
class VoiceData {
  const VoiceData(this.fileId, this.durationMs, this.wave);
  final String fileId;
  final int durationMs;
  final List<int> wave;
  static VoiceData? parse(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        return VoiceData(
          j['file_id']?.toString() ?? '',
          (j['duration_ms'] as num?)?.toInt() ?? 0,
          (j['wave'] as List? ?? const []).map((e) => (e as num).toInt()).toList(),
        );
      }
    } catch (_) {}
    return null;
  }
}

class BotCommand {
  const BotCommand(this.command, this.description);
  final String command;
  final String description;
}

/// `contact.bot` (JSON object or JSON string): owner (verified peer or
/// null), about, commands, group_commands.
class BotInfo {
  const BotInfo({this.owner, this.about = '', this.commands = const [], this.groupCommands = const []});
  final String? owner;
  final String about;
  final List<BotCommand> commands;
  final List<BotCommand> groupCommands;

  static BotInfo? parse(Object? v) {
    if (v == null) return null;
    Object? j = v;
    if (v is String) {
      if (v.isEmpty) return null;
      try {
        j = jsonDecode(v);
      } catch (_) {
        return null;
      }
    }
    if (j is! Map) return null;
    List<BotCommand> cmds(Object? l) => [
          for (final c in (l as List? ?? const []))
            if (c is Map) BotCommand(c['command']?.toString() ?? '', c['description']?.toString() ?? ''),
        ];
    return BotInfo(owner: j['owner']?.toString(), about: j['about']?.toString() ?? '', commands: cmds(j['commands']), groupCommands: cmds(j['group_commands']));
  }
}

/// A bot owned by me (Bot Studio).
class BotAccount {
  const BotAccount({required this.username, required this.name, this.handle = '', this.peer = '', this.shortId = '', this.token, this.created = 0});
  final String username;
  final String name;
  final String handle;
  final String peer;
  final String shortId;
  final String? token;
  final int created;
  factory BotAccount.fromJson(Map<String, dynamic> j) => BotAccount(
        username: _s(j, 'username'),
        name: _s(j, 'name'),
        handle: _s(j, 'handle'),
        peer: _s(j, 'peer'),
        shortId: _s(j, 'short_id'),
        token: _so(j, 'token'),
        created: _i(j, 'created'),
      );
}

class Sticker {
  const Sticker({required this.hash, this.emoji = '', this.mime = '', this.animated = false});
  final String hash;
  final String emoji;
  final String mime;
  final bool animated;
  factory Sticker.fromJson(Map<String, dynamic> j) =>
      Sticker(hash: _s(j, 'hash'), emoji: _s(j, 'emoji'), mime: _s(j, 'mime'), animated: _b(j, 'animated'));
}

class StickerPack {
  const StickerPack({required this.id, required this.name, this.stickers = const []});
  final String id;
  final String name;
  final List<Sticker> stickers;
  factory StickerPack.fromJson(Map<String, dynamic> j) =>
      StickerPack(id: _s(j, 'id'), name: _s(j, 'name'), stickers: _list(j['stickers']).map(Sticker.fromJson).toList());
}

/// Inline keyboard buttons from `meta.buttons` ([[{text, data?, url?}]]).
class InlineButton {
  const InlineButton(this.text, {this.data = '', this.url});
  final String text;
  final String data;
  final String? url;
}

List<List<InlineButton>> messageButtons(Message m) {
  final b = m.meta['buttons'];
  if (b is! List) return const [];
  return [
    for (final row in b)
      if (row is List)
        [
          for (final x in row)
            if (x is Map) InlineButton(x['text']?.toString() ?? '', data: x['data']?.toString() ?? '', url: x['url']?.toString()),
        ],
  ];
}
