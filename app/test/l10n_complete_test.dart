// Every UI string has a real Vietnamese and a real English text: nothing
// empty, nothing copied across untranslated, no Vietnamese inside English
// and no plain English left in the Vietnamese column. The wording also keeps
// one term per concept (thiết bị chính / main device, Xoá, khoá, Khoảnh
// khắc / Moments, tệp / file, bạn bè / friends, Tìm theo ID / Find by ID…),
// never names another app, and lib/ui keeps its Vietnamese text in l10n.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumora/l10n/strings.dart';
import 'package:lumora/l10n/strings_data.dart';

/// Letters only Vietnamese uses (shared Latin accents such as é or à are
/// left out so "café" stays valid English).
final _viOnly = RegExp(
    '[ăĂđĐơƠưƯảẢạẠằẰắẮẳẲẵẴặẶầẦấẤẩẨẫẪậẬẻẺẽẼẹẸềỀếẾểỂễỄệỆỉỈĩĨịỊỏỎọỌồỒốỐổỔỗỖộỘờỜớỚởỞỡỠợỢủỦũŨụỤừỪứỨửỬữỮựỰỳỲỷỶỹỸỵỴýÝ]');
final _anyAccent = RegExp('[à-ỹÀ-Ỹ]');

/// Small English words that never appear in a Vietnamese sentence.
const _enWords = {
  'the', 'a', 'an', 'and', 'or', 'of', 'to', 'for', 'with', 'your', 'you', 'is', 'are', 'this', 'that', 'it',
  'be', 'can', 'will', 'not', 'on', 'in', 'from', 'by', 'at', 'as', 'all', 'any', 'new', 'no', 'off', 'more',
};

/// Names and loanwords both languages write the same way.
const _sameInBoth = {
  'lumora', 'id', 'pin', 'qr', 'gif', 'bot', 'bots', 'studio', 'wi-fi', 'video', 'camera', 'micro', 'mic', 'h.264',
  'vp8', 'vp9', 'ok', 'email', 'sticker', 'emoji', 'png', 'jpeg', 'webp', 'heic', 'usb', 'bios', 'uefi', 'wake',
  'lan', 'iphone', 'ipad', 'android', 'windows', 'macos', 'linux', 'ctrl+v', 'tab', 'enter', 'openstreetmap',
};

/// Keys whose text is a sample, not words (e.g. the recovery code pattern).
const _samples = {'restore_hint'};

Iterable<String> _words(String s) => RegExp(r'[A-Za-z][A-Za-z0-9.+\-]*')
    .allMatches(s.replaceAll(RegExp(r'\{[^}]*\}'), ''))
    .map((m) => m.group(0)!.toLowerCase());

List<String> problemsOf(String key, List<String> pair) {
  if (pair.length != 2) return ['needs exactly [vi, en], has ${pair.length} values'];
  final [vi, en] = pair;
  final out = <String>[];
  if (vi.trim().isEmpty) out.add('Vietnamese is empty');
  if (en.trim().isEmpty) out.add('English is empty');
  if (vi == en && _anyAccent.hasMatch(vi)) out.add('English is a copy of the Vietnamese');
  if (_viOnly.hasMatch(en)) out.add('English contains Vietnamese letters');
  if (!_anyAccent.hasMatch(vi) && !_samples.contains(key)) {
    final ws = _words(vi).toList();
    if (ws.any(_enWords.contains)) {
      out.add('Vietnamese looks like English');
    } else if (vi == en && ws.any((w) => !_sameInBoth.contains(w))) {
      out.add('Vietnamese is the untranslated English');
    }
  }
  return out;
}

/// Letters that may come right before or after a whole word.
const _letter = 'A-Za-zà-ỹÀ-Ỹ';

/// Old spellings or competing terms, Vietnamese column.
final _viBanned = <String, RegExp>{
  '"thiết bị chính", not "máy chính"': RegExp('máy chính', caseSensitive: false),
  '"Xoá"/"xoá", not "Xóa"': RegExp('[Xx]óa'),
  '"khoá"/"Khoá", not "khóa"': RegExp('[Kk]hóa'),
  'new-style tone marks (hoá, huỷ…), not hóa/hủy': RegExp('(?:[óòỏõọ][ae]|[úùủũụ]y)(?![$_letter])'),
  '"Chỉ kết nối trực tiếp", not "P2P thuần"': RegExp('P2P thuần', caseSensitive: false),
  '"tệp", not "file"': RegExp('(?<![$_letter{_.])files?(?![$_letter}_])', caseSensitive: false),
  '"Khoảnh khắc", not "story"': RegExp('(?<![$_letter{_])stor(?:y|ies)(?![$_letter}_])', caseSensitive: false),
  '"bạn bè", not "danh bạ"': RegExp('danh bạ', caseSensitive: false),
  '"trưởng nhóm"/"Chủ cộng đồng", not "chủ nhóm"': RegExp('chủ nhóm', caseSensitive: false),
  '"Tìm theo ID", not "Danh sách công khai"': RegExp('danh sách công khai', caseSensitive: false),
};

/// Competing terms, English column.
final _enBanned = <String, RegExp>{
  '"main device", not "primary device"': RegExp(r'\b(?:primary|master) device', caseSensitive: false),
  '"Moments", not "stories"': RegExp(r'(?<![{_])\bstor(?:y|ies)\b(?![}_])', caseSensitive: false),
  '"friends", not "contacts"': RegExp(r'\bcontacts\b', caseSensitive: false),
  '"Find by ID", not "Public directory"': RegExp('public directory', caseSensitive: false),
  '"Direct connections only", not "pure P2P"': RegExp('(?:pure|only) P2P|P2P only', caseSensitive: false),
};

/// Other apps' names (and imitations) never reach users.
final _brands = RegExp(r'telegram|discord|zalo|bot ?father|whats ?app|viber|wechat|messenger|imessage|skype',
    caseSensitive: false);

List<String> wordingOf(List<String> pair) {
  if (pair.length != 2) return const [];
  final [vi, en] = pair;
  return [
    for (final e in _viBanned.entries)
      if (e.value.hasMatch(vi)) 'Vietnamese should use ${e.key}',
    for (final e in _enBanned.entries)
      if (e.value.hasMatch(en)) 'English should use ${e.key}',
    if (_brands.hasMatch(vi) || _brands.hasMatch(en)) 'names another app (use Xưởng Bot / Bot Studio, or say it plainly)',
  ];
}

/// Files in lib/ui allowed to carry Vietnamese literals, and why.
const _uiAllowFiles = {
  'emoji_keywords.dart', // Vietnamese search keywords for emoji, never shown as text
  'palette.dart', // typed-command prefixes the search box understands ("gọi …", "gửi tệp …")
};

/// Literals allowed anywhere: a language's own name stays in that language.
const _uiAllowLiterals = {"'Tiếng Việt'"};

final _literal = RegExp(r"'(?:[^'\\\n]|\\.)*'" '|' r'"(?:[^"\\\n]|\\.)*"');

/// Vietnamese text hard-coded in lib/ui instead of going through l10n.
List<String> hardCodedVietnamese() {
  final out = <String>[];
  final files = Directory('lib/ui').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
  for (final f in files) {
    if (_uiAllowFiles.contains(f.uri.pathSegments.last)) continue;
    final lines = f.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('//')) continue;
      for (final m in _literal.allMatches(line)) {
        final before = line.substring(0, m.start);
        final comment = before.indexOf('//');
        if (comment >= 0 && "'".allMatches(before.substring(0, comment)).length.isEven) continue;
        if (_uiAllowLiterals.contains(m.group(0))) continue;
        if (_viOnly.hasMatch(m.group(0)!)) out.add('${f.path}:${i + 1}: ${m.group(0)}');
      }
    }
  }
  return out;
}

void main() {
  test('every string has a real Vietnamese and English text', () {
    final problems = [
      for (final e in kStrings.entries)
        for (final p in problemsOf(e.key, e.value)) '${e.key}: $p  ${e.value}',
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('one term per concept, no other app names', () {
    final problems = [
      for (final e in kStrings.entries)
        for (final p in wordingOf(e.value)) '${e.key}: $p  ${e.value}',
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('no Vietnamese text hard-coded in lib/ui', () {
    final found = hardCodedVietnamese();
    expect(found, isEmpty, reason: 'Move these into lib/l10n:\n${found.join('\n')}');
  });

  test('the wording checker catches what it should', () {
    expect(wordingOf(['Đặt làm máy chính', 'Make main device']), isNotEmpty);
    expect(wordingOf(['Xóa tin nhắn', 'Delete message']), isNotEmpty);
    expect(wordingOf(['Mở khóa', 'Unlock']), isNotEmpty);
    expect(wordingOf(['Mã hóa đầu cuối', 'End-to-end encrypted']), isNotEmpty);
    expect(wordingOf(['Chỉ P2P thuần', 'Direct connections only']), isNotEmpty);
    expect(wordingOf(['Gửi file', 'Send file']), isNotEmpty);
    expect(wordingOf(['Đăng story', 'Post a moment']), isNotEmpty);
    expect(wordingOf(['Khoảnh khắc mới', 'New story']), isNotEmpty);
    expect(wordingOf(['Mở Telegram', 'Open Telegram']), isNotEmpty);
    expect(wordingOf(['Đặt làm thiết bị chính', 'Make primary device']), isNotEmpty);
    expect(wordingOf(['Đã gửi {file}', 'Sent {file}']), isEmpty);
    expect(wordingOf(['Xoá tệp đã tải', 'Delete downloaded files']), isEmpty);
    expect(wordingOf(['Mở khoá · mã hoá · huỷ · tuỳ chọn', 'Unlock · encrypt · cancel']), isEmpty);
    expect(wordingOf(['Xưởng Bot', 'Bot Studio']), isEmpty);
  });

  test('the checker catches what it should', () {
    expect(problemsOf('x', ['Gửi tệp', 'Gửi tệp']), contains('English is a copy of the Vietnamese'));
    expect(problemsOf('x', ['Gửi tệp', 'Gửi tệp đi']), contains('English contains Vietnamese letters'));
    expect(problemsOf('x', ['Send the file', 'Send the file']), contains('Vietnamese looks like English'));
    expect(problemsOf('x', ['Upload', 'Upload']), contains('Vietnamese is the untranslated English'));
    expect(problemsOf('x', ['', 'Send']), contains('Vietnamese is empty'));
    expect(problemsOf('x', ['Video', 'Video']), isEmpty);
    expect(problemsOf('x', ['Ví dụ: Quán cà phê quen', 'e.g. Our usual café']), isEmpty);
  });

  test('counts read like numbers: "1.284 thành viên" / "1,284 members"', () {
    expect(S.vn('n_members', {'n': 1284}), '1.284 thành viên');
    expect(S.en('n_members', {'n': 1284}), '1,284 members');
    expect(S.vn('rc_detail', {'n': 1240000, 'g': 2}), '1.240.000 tin nhắn · 2 nhóm chung');
    expect(S.vn('n_members', {'n': 999}), '999 thành viên');
    expect(S.en('n_members', {'n': 1}), '1 member');
  });
}
