// Lazily parsed emoji catalog (Unicode 15.1, see tool/gen_emoji.py): groups,
// skin tones, names and a Vietnamese/English search that ignores diacritics.

import 'emoji_data.dart';
import 'emoji_keywords.dart';

/// One base emoji (no skin tone).
class Emoji {
  const Emoji(this.char, this.index, {this.tones = false});

  /// The fully-qualified base sequence.
  final String char;

  /// Position in the catalog (also the row in the name/keyword tables).
  final int index;

  /// Takes the five Fitzpatrick skin tones.
  final bool tones;

  /// [char] with skin tone [tone] (1..5, 0 = default yellow).
  String withTone(int tone) => tones && tone > 0 ? EmojiCatalog.applyTone(char, tone) : char;

  @override
  String toString() => char;
}

class EmojiGroup {
  const EmojiGroup(this.key, this.emojis);

  /// l10n key, e.g. `emoji_smileys`.
  final String key;
  final List<Emoji> emojis;
}

class _Entry {
  _Entry(this.phrases, this.originals, this.ranks, this.names, this.keywords);
  final List<String> phrases;

  /// The curated phrase with its diacritics (null when it has none).
  final List<String?> originals;
  final List<int> ranks;
  final List<String> names;
  final List<String> keywords;
}

class EmojiCatalog {
  EmojiCatalog._() {
    final sw = Stopwatch()..start();
    var i = 0;
    for (final (key, raw) in kEmojiGroupData) {
      final list = <Emoji>[];
      for (final tok in raw.split(' ')) {
        if (tok.isEmpty) continue;
        final tones = tok.endsWith('+');
        final e = Emoji(tones ? tok.substring(0, tok.length - 1) : tok, i++, tones: tones);
        list.add(e);
        all.add(e);
        _byKey[_keyOf(e.char)] = e;
      }
      groups.add(EmojiGroup(key, List.unmodifiable(list)));
    }
    parseMicros = sw.elapsedMicroseconds;
  }

  static EmojiCatalog? _instance;

  /// Parsed on first use (picker open, big-emoji check), then cached.
  static EmojiCatalog get instance => _instance ??= EmojiCatalog._();

  static bool get isLoaded => _instance != null;

  /// Time spent parsing the groups (for the perf test).
  int parseMicros = 0;

  final List<EmojiGroup> groups = [];
  final List<Emoji> all = [];
  final Map<String, Emoji> _byKey = {};

  List<String>? _namesEn;
  List<String>? _namesVi;
  List<_Entry>? _index;

  static const _tones = [0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF];

  static bool isToneModifier(int r) => r >= 0x1F3FB && r <= 0x1F3FF;

  /// Lookup key: no skin tones, no variation selector 16.
  static String _keyOf(String s) => String.fromCharCodes(s.runes.where((r) => r != 0xFE0F && !isToneModifier(r)));

  /// The base emoji for [s] (any skin tone / FE0F form), or null when [s] is
  /// not a single emoji.
  Emoji? lookup(String s) => _byKey[_keyOf(s)];

  /// True when [s] is exactly one emoji from the catalog.
  bool isEmoji(String s) => lookup(s) != null;

  /// The skin tone used in [s] (1..5), or 0.
  static int toneOf(String s) {
    for (final r in s.runes) {
      if (isToneModifier(r)) return r - 0x1F3FB + 1;
    }
    return 0;
  }

  /// Inserts the tone modifier where Unicode puts it (after the first person,
  /// or after each person in couples), dropping an FE0F right after it.
  static String applyTone(String base, int tone) {
    final cps = base.runes.toList();
    final spots = kEmojiToneSpots[base] ?? const [0];
    final out = <int>[];
    for (var i = 0; i < cps.length; i++) {
      out.add(cps[i]);
      if (spots.contains(i)) {
        out.add(_tones[tone - 1]);
        if (i + 1 < cps.length && cps[i + 1] == 0xFE0F) i++;
      }
    }
    return String.fromCharCodes(out);
  }

  /// Display name in Vietnamese (CLDR) or English (Unicode).
  String nameOf(Emoji e, {required bool vi}) {
    final names = vi ? (_namesVi ??= kEmojiNamesVi.split('\n')) : (_namesEn ??= kEmojiNamesEn.split('\n'));
    return e.index < names.length ? names[e.index] : '';
  }

  List<_Entry> get _entries => _index ??= [
    for (final line in kEmojiSearchIndex.split('\n'))
      () {
        final parts = line.split('|');
        final phrases = <String>[];
        final originals = <String?>[];
        final ranks = <int>[];
        if (parts[0].isNotEmpty) {
          for (final p in parts[0].split(',')) {
            final dot = p.lastIndexOf('.');
            final ph = p.substring(0, dot);
            final eq = ph.indexOf('=');
            phrases.add(eq < 0 ? ph : ph.substring(0, eq));
            originals.add(eq < 0 ? null : ph.substring(eq + 1));
            ranks.add(int.tryParse(p.substring(dot + 1)) ?? 0);
          }
        }
        List<String> words(String s) => s.isEmpty ? const [] : s.split(' ');
        return _Entry(phrases, originals, ranks, words(parts.length > 1 ? parts[1] : ''), words(parts.length > 2 ? parts[2] : ''));
      }(),
  ];

  /// Builds the search index now (e.g. when the picker opens), so the first
  /// keystroke doesn't pay for it.
  void warmUpSearch() => _entries;

  static final Map<int, int> _fold = {for (var i = 0; i < kFoldFrom.length; i++) kFoldFrom.codeUnitAt(i): kFoldTo.codeUnitAt(i)};

  /// Lowercase ASCII words without diacritics: "Cười  TO!" -> "cuoi to".
  static String fold(String s) {
    final b = StringBuffer();
    var space = true;
    for (final r in s.toLowerCase().runes) {
      final c = _fold[r] ?? r;
      final alnum = (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39);
      if (alnum) {
        b.writeCharCode(c);
        space = false;
      } else if (!space) {
        b.write(' ');
        space = true;
      }
    }
    return b.toString().trimRight();
  }

  /// Emoji matching [query] (Vietnamese or English, with or without
  /// diacritics), best first. [usage] (emoji -> times used) boosts favourites.
  List<Emoji> search(String query, {Map<String, int> usage = const {}, int limit = 240}) {
    final q = fold(query);
    if (q.isEmpty) return const [];
    final tokens = q.split(' ');
    // Typed with diacritics ("cưới")? Then prefer phrases spelled the same
    // over ones that only match without marks ("cười").
    final qo = query.toLowerCase().trim().split(RegExp(r'\s+')).join(' ');
    final marked = qo.runes.any((r) => r > 0x7F) && qo.split(' ').length == tokens.length;
    final qoTokens = marked ? qo.split(' ') : const <String>[];
    final entries = _entries;
    final boost = <int, int>{};
    usage.forEach((k, n) {
      final e = lookup(k);
      if (e != null) boost[e.index] = (boost[e.index] ?? 0) + n;
    });
    final scored = <(Emoji, double)>[];
    for (var i = 0; i < all.length && i < entries.length; i++) {
      final en = entries[i];
      var score = 0.0;
      // Whole-query phrase match on the curated Vietnamese terms ("cam on").
      for (var p = 0; p < en.phrases.length; p++) {
        final ph = en.phrases[p];
        final rank = en.ranks[p];
        final orig = en.originals[p] ?? ph;
        final miss = marked && !orig.startsWith(qo) ? 40.0 : 0.0;
        if (ph == q) {
          final v = 100.0 - rank * 3 - miss;
          if (v > score) score = v;
        } else if (ph.startsWith(q) && (q.length >= 2 || tokens.length > 1)) {
          final v = 55.0 - rank * 3 - miss;
          if (v > score) score = v;
        }
      }
      var ok = true;
      for (var ti = 0; ti < tokens.length; ti++) {
        final t = tokens[ti];
        var best = 0.0;
        for (var p = 0; p < en.phrases.length; p++) {
          final ws = en.phrases[p].split(' ');
          final os = marked ? (en.originals[p] ?? en.phrases[p]).split(' ') : const <String>[];
          for (var wi = 0; wi < ws.length; wi++) {
            final w = ws[wi];
            // Same letters but different marks ("cuoi" in "cưới" vs "cười"): weaker.
            final f = marked && wi < os.length && !os[wi].startsWith(qoTokens[ti]) ? 0.5 : 1.0;
            if (w == t) {
              if (24 * f > best) best = 24 * f;
            } else if (w.startsWith(t)) {
              if (14 * f > best) best = 14 * f;
            }
          }
        }
        for (var w = 0; w < en.names.length; w++) {
          final word = en.names[w];
          if (word == t) {
            best = best < 16 + (w == 0 ? 4 : 0) ? 16.0 + (w == 0 ? 4 : 0) : best;
          } else if (word.startsWith(t)) {
            best = best < 10 ? 10 : best;
          }
        }
        if (best < 8) {
          for (final word in en.keywords) {
            if (word == t) {
              best = best < 8 ? 8 : best;
              break;
            } else if (word.startsWith(t)) {
              best = best < 5 ? 5 : best;
            }
          }
        }
        if (best == 0) {
          ok = false;
          break;
        }
        score += best;
      }
      if (!ok) continue;
      final used = (boost[i] ?? 0) * 3;
      score += used > 30 ? 30 : used;
      scored.add((all[i], score));
    }
    // Equal scores keep the catalog (Unicode) order.
    scored.sort((a, b) {
      final c = b.$2.compareTo(a.$2);
      return c != 0 ? c : a.$1.index.compareTo(b.$1.index);
    });
    return [for (final s in scored.take(limit)) s.$1];
  }
}
