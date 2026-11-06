// Recovery phrase helpers shared by the entry widget, the "check again" step
// and Forgot PIN. Mirrors core/crates/lumora-core/src/bip39.rs:
//
//  * a phrase is the 32-byte account secret as 24 English BIP39 words
//    (256 bits + 8-bit SHA-256 checksum, no PBKDF2 step);
//  * phrases written by older versions are 12 base32 groups ("abcde-fghij-…")
//    of the same secret, and still restore the same account.
//
// Nothing here logs or stores what is typed.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'bip39_wordlist.dart';

/// Number of words in a recovery phrase.
const kPhraseWords = 24;

/// The official English list (2048 words, sorted).
final List<String> bip39Words = List.unmodifiable(bip39EnglishRaw.split(RegExp(r'\s+')).where((w) => w.isNotEmpty));

final _letters = RegExp(r'^[a-z]+$');
final _b32 = RegExp(r'^[a-z2-7]+$');
final _numbering = RegExp(r'^\d+[.):]?');
final _splitter = RegExp(r'[\s,;\-–—_/|]+');

int _lowerBound(String t) {
  var lo = 0, hi = bip39Words.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (bip39Words[mid].compareTo(t) < 0) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// Index of [token] (any case): the exact word, or a prefix of at least four
/// letters (unique in the English list, as BIP39 promises). Null if unknown.
int? bip39Index(String token) {
  final t = token.trim().toLowerCase();
  if (t.isEmpty || !_letters.hasMatch(t)) return null;
  final i = _lowerBound(t);
  if (i < bip39Words.length && bip39Words[i] == t) return i;
  if (t.length < 4 || i >= bip39Words.length || !bip39Words[i].startsWith(t)) return null;
  if (i + 1 < bip39Words.length && bip39Words[i + 1].startsWith(t)) return null;
  return i;
}

/// The full word for [token] (expands a 4-letter prefix), or null.
String? bip39Word(String token) {
  final i = bip39Index(token);
  return i == null ? null : bip39Words[i];
}

/// Could [token] still become a word (it is a prefix of one)?
bool bip39IsPrefix(String token) {
  final t = token.trim().toLowerCase();
  if (t.isEmpty) return true;
  final i = _lowerBound(t);
  return i < bip39Words.length && bip39Words[i].startsWith(t);
}

/// Up to [max] words starting with [prefix] (needs 2+ letters).
List<String> bip39Suggest(String prefix, {int max = 4}) {
  final t = prefix.trim().toLowerCase();
  if (t.length < 2 || !_letters.hasMatch(t)) return const [];
  final out = <String>[];
  for (var i = _lowerBound(t); i < bip39Words.length && out.length < max && bip39Words[i].startsWith(t); i++) {
    out.add(bip39Words[i]);
  }
  return out;
}

/// The words of a typed / pasted phrase: lower-cased, split on spaces, new
/// lines, commas or dashes, list numbering ("1.", "7)") dropped.
List<String> phraseTokens(String text) => [
      for (final t in text.toLowerCase().split(_splitter))
        if (t.replaceFirst(_numbering, '').isNotEmpty) t.replaceFirst(_numbering, ''),
    ];

/// Does [text] look like a phrase from an older version (base32 groups)?
bool looksLikeLegacyPhrase(String text) {
  final lower = text.trim().toLowerCase();
  final alnum = lower.replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (alnum.length == 56 && _b32.hasMatch(alnum)) return true;
  final groups = lower.split(RegExp(r'[\s\-]+')).where((g) => g.isNotEmpty).toList();
  final short = groups.length >= 10 && groups.length <= 13 && groups.every((g) => g.length <= 5 && _b32.hasMatch(g));
  return short && (lower.contains('-') || groups.any((g) => g.contains(RegExp(r'[2-7]'))));
}

/// Is [text] a whole older-style code (56 base32 characters)? Its check
/// digits are verified by the core.
bool legacyPhraseComplete(String text) {
  if (!looksLikeLegacyPhrase(text)) return false;
  final alnum = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return alnum.length == 56 && _b32.hasMatch(alnum);
}

/// Result of checking 24 words.
enum PhraseProblem { none, count, word, checksum }

class PhraseCheck {
  const PhraseCheck(this.problem, [this.position = 0]);
  final PhraseProblem problem;

  /// 1-based position of the unknown word ([PhraseProblem.word]).
  final int position;
  bool get ok => problem == PhraseProblem.none;
}

Uint8List? _decodeWords(List<String> words) {
  if (words.length != kPhraseWords) return null;
  final bits = Uint8List(33);
  for (var i = 0; i < words.length; i++) {
    final idx = bip39Index(words[i]);
    if (idx == null) return null;
    for (var k = 0; k < 11; k++) {
      if ((idx >> (10 - k)) & 1 == 1) {
        final b = i * 11 + k;
        bits[b >> 3] |= 1 << (7 - (b & 7));
      }
    }
  }
  final entropy = Uint8List.fromList(bits.sublist(0, 32));
  if (sha256.convert(entropy).bytes[0] != bits[32]) return null;
  return entropy;
}

/// Checks a list of words: count, each word, then the checksum.
PhraseCheck checkPhraseWords(List<String> words) {
  for (var i = 0; i < words.length && i < kPhraseWords; i++) {
    if (bip39Index(words[i]) == null) return PhraseCheck(PhraseProblem.word, i + 1);
  }
  if (words.length != kPhraseWords) return const PhraseCheck(PhraseProblem.count);
  return _decodeWords(words) == null ? const PhraseCheck(PhraseProblem.checksum) : const PhraseCheck(PhraseProblem.none);
}

/// 32 bytes → 24 words (used by tests and the mock core).
String encodePhrase(List<int> entropy) {
  assert(entropy.length == 32);
  final bits = Uint8List(33)..setAll(0, entropy);
  bits[32] = sha256.convert(entropy).bytes[0];
  final out = <String>[];
  for (var i = 0; i < kPhraseWords; i++) {
    var v = 0;
    for (var b = i * 11; b < i * 11 + 11; b++) {
      v = (v << 1) | ((bits[b >> 3] >> (7 - (b & 7))) & 1);
    }
    out.add(bip39Words[v]);
  }
  return out.join(' ');
}

Uint8List? _decodeBase32(String s) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  final out = <int>[];
  var buf = 0, n = 0;
  for (final ch in s.split('')) {
    final v = alphabet.indexOf(ch);
    if (v < 0) return null;
    buf = (buf << 5) | v;
    n += 5;
    if (n >= 8) {
      n -= 8;
      out.add((buf >> n) & 0xff);
    }
  }
  return Uint8List.fromList(out);
}

/// The account secret in [text], from either format, as a comparable string
/// (Forgot PIN compares what was typed with the account's own phrase). The
/// legacy check digits are not verified here: comparing with the real
/// secret does that. Null when [text] is neither format.
String? phraseSecretKey(String text) {
  Uint8List? secret;
  if (looksLikeLegacyPhrase(text)) {
    final alnum = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final data = _decodeBase32(alnum);
    if (data != null && data.length == 35) secret = data.sublist(0, 32);
  } else {
    secret = _decodeWords(phraseTokens(text));
  }
  if (secret == null) return null;
  return sha256.convert([...'lumora phrase compare'.codeUnits, ...secret]).toString();
}
