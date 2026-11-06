// Lightweight map-based localisation (Vietnamese first, English second).
// Usage: `final s = S.of(context); Text(s('chats'))`, with `{name}` params:
// `s('typing_one', {'name': 'An'})`.

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../state/settings.dart';
import 'strings_data.dart';

class S {
  const S(this.vi);
  final bool vi;

  static const vn = S(true);
  static const en = S(false);

  static S of(BuildContext context) =>
      context.select<Settings, String>((s) => s.locale) == 'en' ? en : vn;

  /// Non-listening variant for callbacks.
  static S read(BuildContext context) => context.read<Settings>().locale == 'en' ? en : vn;

  String call(String key, [Map<String, Object?> params = const {}]) {
    // Singular form: `key_one` is used when {n} == 1 (if it exists).
    if (params['n'] == 1 && kStrings.containsKey('${key}_one')) key = '${key}_one';
    final pair = kStrings[key];
    assert(pair != null, 'Missing string: $key');
    var v = pair == null ? key : pair[vi ? 0 : 1];
    if (params.isNotEmpty) {
      params.forEach((k, p) => v = v.replaceAll('{$k}', '$p'));
    }
    return v;
  }

  /// Translation if [key] exists, otherwise [fallback] (e.g. core-provided text).
  String orElse(String key, String fallback) {
    final pair = kStrings[key];
    return pair == null ? fallback : pair[vi ? 0 : 1];
  }

  // ------------------------------------------------------------ core previews

  /// Stable machine tokens for non-text messages, as written by the core
  /// (`Body::preview`) and by the app's own stores. The UI draws each kind
  /// with an icon (see `PreviewLine`); plain-text sinks such as system
  /// notifications use [preview], which never contains emoji.
  static const _tokens = {
    '🖼️ Photo': PreviewKind.photo,
    '🎬 Video': PreviewKind.video,
    '🎤 Voice message': PreviewKind.voice,
    '🎤': PreviewKind.voice,
    '📍 Live location': PreviewKind.liveLocation,
    '📍 Location': PreviewKind.location,
    '📞 Call': PreviewKind.call,
    '📞': PreviewKind.call,
    '📹 Call': PreviewKind.videoCall,
    '📞 Missed call': PreviewKind.missedCall,
    '📹 Missed call': PreviewKind.missedVideoCall,
  };

  /// `<token> <detail>` forms (app stores + mock) and the core's localized
  /// `<Word>: <detail>` forms, in both languages.
  static const _prefixed = [
    ('📍 ', PreviewKind.location),
    ('📎 ', PreviewKind.file),
    ('📷 ', PreviewKind.file),
    ('👤 ', PreviewKind.contact),
    ('📊 ', PreviewKind.poll),
    ('☑️ ', PreviewKind.checklist),
    ('⏰ ', PreviewKind.reminder),
    ('🎤 ', PreviewKind.voice),
    ('File: ', PreviewKind.file),
    ('Tệp: ', PreviewKind.file),
    ('Contact: ', PreviewKind.contact),
    ('Danh thiếp: ', PreviewKind.contact),
    ('Poll: ', PreviewKind.poll),
    ('Bình chọn: ', PreviewKind.poll),
    ('Checklist: ', PreviewKind.checklist),
    ('Danh sách việc: ', PreviewKind.checklist),
    ('Reminder: ', PreviewKind.reminder),
    ('Nhắc hẹn: ', PreviewKind.reminder),
  ];

  /// Word used for each kind ("Ảnh", "Cuộc gọi nhỡ", …).
  String previewWord(PreviewKind k) => call(switch (k) {
        PreviewKind.photo => 'pv_photo',
        PreviewKind.video => 'video',
        PreviewKind.voice => 'voice_message',
        PreviewKind.liveLocation => 'live_location',
        PreviewKind.location => 'location',
        PreviewKind.call => 'call_voice_done',
        PreviewKind.videoCall => 'call_video_done',
        PreviewKind.missedCall => 'call_missed_voice',
        PreviewKind.missedVideoCall => 'call_missed_video',
        PreviewKind.sticker => 'pv_sticker',
        PreviewKind.file => 'att_file',
        PreviewKind.contact => 'share_contact',
        PreviewKind.poll => 'poll',
        PreviewKind.checklist => 'checklist',
        PreviewKind.reminder => 'reminder',
      });

  /// Splits a one-line preview into an optional "Name: " prefix, the kind of
  /// non-text message (null for plain text) and its localized text.
  PreviewParts previewParts(String raw) {
    final hit = _parseToken(raw);
    if (hit != null) return hit;
    // Group rows: "An: 🖼️ Photo".
    final i = raw.indexOf(': ');
    if (i > 0 && i < 40) {
      final tail = _parseToken(raw.substring(i + 2));
      if (tail != null) return PreviewParts(raw.substring(0, i + 2), tail.kind, tail.text, detail: tail.detail);
    }
    return PreviewParts('', null, raw);
  }

  PreviewParts? _parseToken(String raw) {
    final k = _tokens[raw];
    if (k != null) return PreviewParts('', k, previewWord(k));
    // "<emoji> Sticker": the emoji is the sticker's own tag (user content).
    if (raw.endsWith(' Sticker') && raw.length <= 16) {
      final tag = raw.substring(0, raw.length - 8);
      return PreviewParts('', PreviewKind.sticker, '${previewWord(PreviewKind.sticker)} $tag', detail: tag);
    }
    for (final (p, kind) in _prefixed) {
      if (!raw.startsWith(p)) continue;
      final detail = raw.substring(p.length).trim();
      if (detail.isEmpty) return PreviewParts('', kind, previewWord(kind));
      return PreviewParts('', kind, detail, detail: detail);
    }
    return null;
  }

  /// Plain-text preview (no emoji) - chat list fallbacks, search, system
  /// notifications: "Ảnh", "An: Cuộc gọi thoại nhỡ", "Tệp: bao_cao.xlsx".
  String preview(String raw) {
    final p = previewParts(raw);
    if (p.kind == null) return raw;
    final word = previewWord(p.kind!);
    final body = p.detail == null || p.kind == PreviewKind.sticker ? p.text : '$word: ${p.detail}';
    return '${p.prefix}$body';
  }

  // ------------------------------------------------------------ formatting

  String bytes(int b) {
    if (b < 1024) return '$b B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var v = b / 1024;
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    final str = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '${vi ? str.replaceAll('.', ',') : str} ${units[i]}';
  }

  String speed(int bps) => '${bytes(bps)}/s';

  String hhmm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  static const _wdVi = ['Thứ 2', 'Thứ 3', 'Thứ 4', 'Thứ 5', 'Thứ 6', 'Thứ 7', 'CN'];
  static const _wdEn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _moEn = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// Short timestamp for chat list rows.
  String listTime(int ms, DateTime now) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return hhmm(d);
    if (diff == 1) return call('yesterday');
    if (diff < 7) return vi ? _wdVi[d.weekday - 1] : _wdEn[d.weekday - 1];
    return vi ? '${d.day}/${d.month}' : '${_moEn[d.month - 1]} ${d.day}';
  }

  /// Day separator label.
  String dayLabel(DateTime d, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return call('today');
    if (diff == 1) return call('yesterday');
    final wd = vi ? _wdVi[d.weekday - 1] : _wdEn[d.weekday - 1];
    return vi
        ? '$wd, ${d.day} tháng ${d.month}${d.year != now.year ? ', ${d.year}' : ''}'
        : '$wd, ${_moEn[d.month - 1]} ${d.day}${d.year != now.year ? ', ${d.year}' : ''}';
  }

  String lastSeen(int ms, DateTime now) {
    if (ms <= 0) return call('offline');
    final diff = now.difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inMinutes < 1) return call('seen_just_now');
    if (diff.inMinutes < 60) return call('seen_min', {'n': diff.inMinutes});
    if (diff.inHours < 24) return call('seen_hour', {'n': diff.inHours});
    return call('seen_day', {'n': diff.inDays});
  }

  String duration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$sec' : '$m:$sec';
  }

  String ttlLabel(int ms) {
    if (ms <= 0) return call('off');
    if (ms < 3600000) return call('ttl_min', {'n': ms ~/ 60000});
    if (ms < 86400000) return call('ttl_hour', {'n': ms ~/ 3600000});
    return call('ttl_day', {'n': ms ~/ 86400000});
  }
}

/// Kinds of non-text message previews (each has its own icon in the UI).
enum PreviewKind { photo, video, voice, liveLocation, location, call, videoCall, missedCall, missedVideoCall, sticker, file, contact, poll, checklist, reminder }

class PreviewParts {
  const PreviewParts(this.prefix, this.kind, this.text, {this.detail});

  /// "An: " in group rows, otherwise empty.
  final String prefix;
  final PreviewKind? kind;

  /// Localized text to show next to the icon.
  final String text;

  /// The message-specific part (file name, poll question…), if any.
  final String? detail;

  bool get missed => kind == PreviewKind.missedCall || kind == PreviewKind.missedVideoCall;
}
