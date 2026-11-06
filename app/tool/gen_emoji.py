#!/usr/bin/env python3
"""Generates the emoji picker data from authoritative sources.

Inputs (download once, offline afterwards):
  * Unicode emoji-test.txt (Emoji 15.1): the full, ordered, fully-qualified list
    with the official groups.          https://www.unicode.org/Public/emoji/15.1/emoji-test.txt
  * emojibase-data (en/data.json, en/shortcodes/emojibase.json): English tags
    and shortcodes (MIT).              npm pack emojibase-data@15
  * CLDR 45 annotations for Vietnamese (annotations + annotationsDerived):
    official Vietnamese names and keywords (Unicode license).
                                       github.com/unicode-org/cldr-json, cldr-annotations-*-full/*/vi
  * tool/emoji_vi_keywords.py: curated everyday Vietnamese terms (teencode, food, Tết...).

Outputs:
  * lib/ui/chats/emoji_data.dart      - groups (emoji per Unicode group, tone flags)
  * lib/ui/chats/emoji_keywords.dart  - names (en/vi) + diacritic-free search index

Usage:
  python3 tool/gen_emoji.py --emoji-test emoji-test.txt --emojibase <pkg dir> \
      --cldr-vi annotations.json --cldr-vi-derived annotationsDerived.json
"""
import argparse
import json
import os
import re
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from emoji_vi_keywords import VI_KEYWORDS  # noqa: E402

GROUPS = [
    # (emoji-test group, l10n key)
    ('Smileys & Emotion', 'emoji_smileys'),
    ('People & Body', 'emoji_people'),
    ('Animals & Nature', 'emoji_animals'),
    ('Food & Drink', 'emoji_food'),
    ('Travel & Places', 'emoji_travel'),
    ('Activities', 'emoji_activity'),
    ('Objects', 'emoji_objects'),
    ('Symbols', 'emoji_symbols'),
    ('Flags', 'emoji_flags'),
]
TONES = [0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF]
FE0F = 0xFE0F
QUICK_REACTIONS = ['👍', '❤️', '😂', '😮', '😢', '🙏', '🔥']


def strip_fe0f(s):
    return ''.join(c for c in s if ord(c) != FE0F)


def fold(s):
    """Lowercase, no diacritics (đ -> d), ASCII letters/digits separated by single spaces."""
    s = s.replace('đ', 'd').replace('Đ', 'D')
    s = unicodedata.normalize('NFD', s)
    s = ''.join(c for c in s if unicodedata.category(c) != 'Mn').lower()
    s = re.sub(r'[^a-z0-9]+', ' ', s)
    return s.strip()


def apply_tone(base_cps, spots, tone):
    """Inserts [tone] after each spot index of [base_cps], dropping an FE0F right after it."""
    out = []
    i = 0
    while i < len(base_cps):
        out.append(base_cps[i])
        if i in spots:
            out.append(tone)
            if i + 1 < len(base_cps) and base_cps[i + 1] == FE0F:
                i += 1
        i += 1
    return out


def parse_emoji_test(path):
    groups = {g: [] for g, _ in GROUPS}
    names, versions = {}, {}
    toned = {}  # base (no FE0F) -> list of fully-qualified tone variants (cps)
    group = None
    for line in open(path, encoding='utf-8'):
        if line.startswith('# group:'):
            group = line.split(':', 1)[1].strip()
            continue
        if line.startswith('#') or ';' not in line:
            continue
        cps_s, rest = line.split(';', 1)
        status = rest.split('#', 1)[0].strip()
        if status != 'fully-qualified':
            continue
        cps = [int(c, 16) for c in cps_s.split()]
        comment = rest.split('#', 1)[1].strip()  # "😀 E1.0 grinning face"
        m = re.match(r'\S+\s+E(\d+\.\d+)\s+(.*)', comment)
        ver, name = m.group(1), m.group(2)
        e = ''.join(map(chr, cps))
        if group == 'Component' or group not in groups:
            continue
        if any(c in TONES for c in cps):
            base = ''.join(chr(c) for c in cps if c not in TONES and c != FE0F)
            toned.setdefault(base, []).append(cps)
            continue
        groups[group].append(e)
        names[e] = name
        versions[e] = ver
    return groups, names, versions, toned


def tone_spots(base, variants):
    """Spot indices that reproduce every uniform-tone variant, or None."""
    bcps = [ord(c) for c in base]
    uniform = {}
    for v in variants:
        ts = {c for c in v if c in TONES}
        if len(ts) == 1:
            uniform[ts.pop()] = v
    if len(uniform) != 5:
        return None
    v1 = uniform[TONES[0]]
    # Walk the variant against the base to find where the modifiers go.
    spots, bi = [], 0
    for c in v1:
        if c in TONES:
            spots.append(bi - 1)
            continue
        while bi < len(bcps) and bcps[bi] != c:
            bi += 1  # skip FE0F dropped in the variant
        bi += 1
    for t in TONES:
        if apply_tone(bcps, set(spots), t) != uniform[t]:
            return None
    return spots


def dart_str(s):
    return "'" + s.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$').replace('\n', '\\n') + "'"


def dart_block(s):
    """Multi-line literal: one entry per line, kept readable in diffs."""
    body = s.replace('\\', '\\\\').replace("'''", "\\'\\'\\'").replace('$', '\\$')
    return "'''\n" + body + "'''"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--emoji-test', required=True)
    ap.add_argument('--emojibase', required=True, help='unpacked emojibase-data package dir')
    ap.add_argument('--cldr-vi', required=True)
    ap.add_argument('--cldr-vi-derived', required=True)
    a = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    app = os.path.dirname(here)

    groups, names, versions, toned = parse_emoji_test(a.emoji_test)
    version = '15.1'
    for line in open(a.emoji_test, encoding='utf-8'):
        if line.startswith('# Version:'):
            version = line.split(':', 1)[1].strip()
            break

    # ---------------------------------------------------------------- tones
    tone_ok, tone_exc, tone_bad = set(), {}, []
    for e in [x for g in groups.values() for x in g]:
        key = strip_fe0f(e)
        if key not in toned:
            continue
        spots = tone_spots(e, toned[key])
        if spots is None:
            tone_bad.append(e)
            continue
        tone_ok.add(e)
        if spots != [0]:
            tone_exc[e] = spots

    flat = [x for g, _ in GROUPS for x in groups[g]]

    # ---------------------------------------------------------------- keywords
    eb = json.load(open(os.path.join(a.emojibase, 'en', 'data.json'), encoding='utf-8'))
    eb_sc = json.load(open(os.path.join(a.emojibase, 'en', 'shortcodes', 'emojibase.json'), encoding='utf-8'))
    en_tags = {}
    for x in eb:
        k = strip_fe0f(x['emoji'])
        tags = list(x.get('tags', []))
        sc = eb_sc.get(x['hexcode'])
        if sc:
            tags += sc if isinstance(sc, list) else [sc]
        en_tags[k] = tags

    cldr = {}
    for path, root in ((a.cldr_vi, 'annotations'), (a.cldr_vi_derived, 'annotationsDerived')):
        data = json.load(open(path, encoding='utf-8'))[root]['annotations']
        for k, v in data.items():
            cldr.setdefault(strip_fe0f(k), v)

    curated = {}  # emoji key -> [(phrase for the index, rank)]
    unknown = []
    flat_keys = {strip_fe0f(e) for e in flat}
    for phrase, emojis in VI_KEYWORDS.items():
        orig = ' '.join(re.sub(r'\(.*?\)', '', phrase).lower().split())
        p = fold(orig)
        # Keep the spelling with diacritics when it differs, so "cười" (laugh)
        # and "cưới" (wedding) can be told apart when typed with marks.
        if orig != p and re.fullmatch(r'[^|,=.]+', orig):
            p = p + '=' + orig
        for rank, e in enumerate(emojis.split()):
            k = strip_fe0f(e)
            if k not in flat_keys:
                unknown.append(e)
                continue
            lst = curated.setdefault(k, [])
            if all(x[0] != p for x in lst):
                lst.append((p, rank))
    if unknown:
        print('curated emoji not in the set:', ' '.join(sorted(set(unknown))), file=sys.stderr)

    names_en, names_vi, index = [], [], []
    for e in flat:
        k = strip_fe0f(e)
        en = names[e]
        c = cldr.get(k, {})
        vi = (c.get('tts') or [en])[0]
        names_en.append(en)
        names_vi.append(vi)
        cur = ','.join('%s.%d' % (p, r) for p, r in curated.get(k, []))
        name_words = []
        for w in (fold(en) + ' ' + fold(vi)).split():
            if w not in name_words:
                name_words.append(w)
        kw = []
        for t in en_tags.get(k, []) + c.get('default', []):
            for w in fold(t).split():
                if w not in kw and w not in name_words:
                    kw.append(w)
        index.append('%s|%s|%s' % (cur, ' '.join(name_words), ' '.join(kw)))

    # Fold table for the Dart side (query normalisation).
    src, dst = [], []
    for cp in list(range(0xC0, 0x250)) + list(range(0x1E00, 0x1F00)):
        ch = chr(cp)
        f = fold(ch)
        if len(f) == 1 and ch.lower() == ch and f != ch:
            src.append(ch)
            dst.append(f)

    # ---------------------------------------------------------------- write
    out_data = os.path.join(app, 'lib', 'ui', 'chats', 'emoji_data.dart')
    with open(out_data, 'w', encoding='utf-8') as f:
        f.write('// GENERATED by tool/gen_emoji.py from Unicode emoji-test.txt (Emoji %s) - do not edit.\n' % version)
        f.write('// %d emoji (fully-qualified, skin tones folded into their base), %d take skin tones.\n\n' % (len(flat), len(tone_ok)))
        f.write("const kEmojiUnicodeVersion = '%s';\n\n" % version)
        f.write('const kEmojiCount = %d;\n\n' % len(flat))
        f.write('/// Unicode emoji groups in their official order: (l10n key, entries).\n')
        f.write('/// Entries are separated by spaces; a trailing `+` marks an emoji that takes\n')
        f.write('/// skin tones. Parsed lazily by `EmojiCatalog` the first time it is needed.\n')
        f.write('const kEmojiGroupData = <(String, String)>[\n')
        for g, key in GROUPS:
            raw = ' '.join(x + ('+' if x in tone_ok else '') for x in groups[g])
            f.write('  (%s, %s),\n' % (dart_str(key), dart_str(raw)))
        f.write('];\n\n')
        f.write('/// Where the skin-tone modifier goes, for emoji where it is not simply\n')
        f.write('/// after the first codepoint (multi-person sequences). Indices are\n')
        f.write('/// codepoint positions in the base emoji.\n')
        f.write('const kEmojiToneSpots = <String, List<int>>{\n')
        for e, spots in tone_exc.items():
            f.write('  %s: %s,\n' % (dart_str(e), '[' + ', '.join(map(str, spots)) + ']'))
        f.write('};\n\n')
        f.write('/// Reactions offered first (quick bar).\n')
        f.write('const kQuickReactions = [%s];\n' % ', '.join(dart_str(x) for x in QUICK_REACTIONS))

    out_kw = os.path.join(app, 'lib', 'ui', 'chats', 'emoji_keywords.dart')
    with open(out_kw, 'w', encoding='utf-8') as f:
        f.write('// GENERATED by tool/gen_emoji.py - do not edit.\n')
        f.write('// Names: Unicode (en) and CLDR 45 (vi). Keywords: emojibase tags + shortcodes (en),\n')
        f.write('// CLDR 45 annotations (vi), curated Vietnamese terms (tool/emoji_vi_keywords.py).\n')
        f.write('// One line per emoji, in kEmojiGroupData order.\n\n')
        f.write('/// English names.\n')
        f.write('const kEmojiNamesEn = %s;\n\n' % dart_block('\n'.join(names_en)))
        f.write('/// Vietnamese names.\n')
        f.write('const kEmojiNamesVi = %s;\n\n' % dart_block('\n'.join(names_vi)))
        f.write('/// Search index, diacritics folded: `curated phrases (folded[=original].rank,...)|name words|keywords`.\n')
        f.write('const kEmojiSearchIndex = %s;\n\n' % dart_block('\n'.join(index)))
        f.write('/// Lowercase letters with diacritics -> plain ASCII letter (same index).\n')
        f.write('const kFoldFrom = %s;\n' % dart_str(''.join(src)))
        f.write('const kFoldTo = %s;\n' % dart_str(''.join(dst)))

    print('Emoji %s: %d emoji, %d with skin tones (%d multi-spot, %d skipped: %s)' % (
        version, len(flat), len(tone_ok), len(tone_exc), len(tone_bad), ' '.join(tone_bad)))
    print('curated vi: %d emoji, %d phrases' % (len(curated), len(VI_KEYWORDS)))
    for g, key in GROUPS:
        print('  %-18s %4d' % (g, len(groups[g])))
    print('sizes: data %d B, keywords %d B' % (os.path.getsize(out_data), os.path.getsize(out_kw)))


if __name__ == '__main__':
    main()
