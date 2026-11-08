#!/usr/bin/env python3
"""Builds the bundled 3D sticker pack from Microsoft's Fluent Emoji (3D style).

Source: https://github.com/microsoft/fluentui-emoji, MIT license (attribution in
Settings > About > Open-source licenses). Development time only: the app never fetches
anything; a sticker sent from this pack travels inside the message like any custom sticker.

Usage: python3 tool/fetch_fluent_stickers.py --cache DIR [--animated-mb 5]
The most-used stickers (the curated list of fetch_animated_emoji.py, in order) are replaced
by Microsoft's animated version (github.com/microsoft/fluentui-emoji-animated, MIT) as an
animated WebP, 128 px, ~8 fps, until --animated-mb is spent.
Writes app/assets/stickers3d/<key>.webp (160 px) and lib/ui/chats/builtin_stickers.dart.
<key> is the emoji's lowercase hex codepoints without U+FE0F, joined by '_'.
"""
import argparse
import io
import json
import os
import sys
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

from PIL import Image

REPO = 'https://raw.githubusercontent.com/microsoft/fluentui-emoji/main/'
TREE = 'https://api.github.com/repos/microsoft/fluentui-emoji/git/trees/main?recursive=1'
# what people send as stickers; objects, places, symbols and flags stay emoji
GROUPS = ('Smileys & Emotion', 'People & Body', 'Animals & Nature', 'Food & Drink', 'Activities')
SIZE = 160
QUALITY = 80
ANIM_REPO = 'https://media.githubusercontent.com/media/microsoft/fluentui-emoji-animated/main/'
ANIM_TREE = 'https://api.github.com/repos/microsoft/fluentui-emoji-animated/git/trees/main?recursive=1'
ANIM_SIZE, ANIM_STEP, ANIM_QUALITY = 128, 3, 55


def animated_webp(apng):
    from PIL import ImageSequence
    im = Image.open(io.BytesIO(apng))
    frames, durs = [], []
    for i, f in enumerate(ImageSequence.Iterator(im)):
        if i % ANIM_STEP:
            continue
        g = f.convert('RGBA')
        g.thumbnail((ANIM_SIZE, ANIM_SIZE), Image.LANCZOS)
        frames.append(g)
        durs.append(int(f.info.get('duration') or 33) * ANIM_STEP)
    buf = io.BytesIO()
    frames[0].save(buf, 'WEBP', save_all=True, append_images=frames[1:], duration=durs, loop=0, quality=ANIM_QUALITY, method=6)
    return buf.getvalue()


def fetch(url, cache_path):
    if cache_path and os.path.exists(cache_path):
        return open(cache_path, 'rb').read()
    with urllib.request.urlopen(url, timeout=60) as r:
        data = r.read()
    if cache_path:
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        open(cache_path, 'wb').write(data)
    return data


def key_of(glyph):
    return '_'.join('%x' % ord(c) for c in glyph if ord(c) != 0xFE0F)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--cache', required=True, help='download cache directory')
    ap.add_argument('--animated-mb', type=float, default=5.0, help='size budget of the animated stickers')
    a = ap.parse_args()
    here = os.path.dirname(os.path.abspath(__file__))
    app = os.path.dirname(here)
    out = os.path.join(app, 'assets', 'stickers3d')
    os.makedirs(out, exist_ok=True)

    tree = json.loads(fetch(TREE, os.path.join(a.cache, 'tree.json')))
    paths = {x['path'] for x in tree['tree']}
    folders = sorted({p.split('/')[1] for p in paths if p.startswith('assets/') and p.count('/') >= 2})

    def one(folder):
        meta_path = 'assets/%s/metadata.json' % folder
        if meta_path not in paths:
            return None
        meta = json.loads(fetch(REPO + urllib.parse.quote(meta_path), os.path.join(a.cache, 'meta', folder + '.json')))
        if meta.get('group') not in GROUPS:
            return None
        # skin-toned ones keep their default (yellow) look under Default/
        cands = [p for p in paths if p.startswith('assets/%s/' % folder) and p.endswith('_3d.png') and '/3D/' in p]
        cands += [p for p in paths if p.startswith('assets/%s/Default/3D/' % folder) and p.endswith('.png')]
        if not cands:
            return None
        png = fetch(REPO + urllib.parse.quote(sorted(cands, key=len)[0]), os.path.join(a.cache, 'png', folder + '.png'))
        img = Image.open(io.BytesIO(png)).convert('RGBA')
        img.thumbnail((SIZE, SIZE), Image.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, 'WEBP', quality=QUALITY, method=6)
        glyph = meta.get('glyph', '')
        k = key_of(glyph)
        if not k:
            return None
        open(os.path.join(out, k + '.webp'), 'wb').write(buf.getvalue())
        words = [meta.get('cldr', '')] + list(meta.get('keywords', []))
        words = [w.replace('|', ' ').strip().lower() for w in words if w and w.strip()]
        return (GROUPS.index(meta['group']), k, glyph, words, len(buf.getvalue()), folder)

    with ThreadPoolExecutor(12) as ex:
        rows = [r for r in ex.map(one, folders) if r]
    rows.sort(key=lambda r: (r[0], r[1]))
    seen, uniq = set(), []
    for r in rows:
        if r[1] not in seen:
            seen.add(r[1])
            uniq.append(r)
    # the most-used ones animated, within the budget
    sys.path.insert(0, here)
    from fetch_animated_emoji import CURATED, key_of as anim_key
    by_key = {r[1]: r for r in uniq}
    atree = json.loads(fetch(ANIM_TREE, os.path.join(a.cache, 'anim_tree.json')))
    apaths = {x['path'] for x in atree['tree'] if x['path'].endswith('_animated.png') and x['path'].count('/') == 3}
    animated, budget = set(), a.animated_mb * 1e6
    sizes = {r[1]: r[4] for r in uniq}
    for e in CURATED:
        r = by_key.get(anim_key(e))
        if not r or r[1] in animated:
            continue
        cands = [p for p in apaths if p.split('/')[1] == r[5]]
        if not cands:
            continue
        data = animated_webp(fetch(ANIM_REPO + urllib.parse.quote(cands[0]), os.path.join(a.cache, 'apng', r[5] + '.png')))
        if budget - len(data) < 0:
            break
        budget -= len(data)
        open(os.path.join(out, r[1] + '.webp'), 'wb').write(data)
        animated.add(r[1])
        sizes[r[1]] = len(data)
    print('%d animated (%.2f MB)' % (len(animated), sum(sizes[k] for k in animated) / 1e6))
    total = sum(sizes.values())
    dart = os.path.join(app, 'lib', 'ui', 'chats', 'builtin_stickers.dart')
    with open(dart, 'w', encoding='utf-8') as f:
        f.write('// GENERATED by tool/fetch_fluent_stickers.py - do not edit.\n')
        f.write('// Fluent Emoji 3D (c) Microsoft, MIT license. %d stickers, %d bytes.\n\n' % (len(uniq), total))
        f.write('/// Groups, in [kBuiltinStickerData] order.\n')
        f.write('const kBuiltinStickerGroups = <String>[%s];\n\n' % ', '.join("'%s'" % g for g in GROUPS))
        f.write('/// Animated (WebP) ones, the most used.\n')
        f.write('const kBuiltinStickerAnimated = <String>{%s};\n\n' % ', '.join("'%s'" % k for k in sorted(animated)))
        f.write('/// One line per sticker: group index | asset key | emoji | English words (comma separated).\n')
        f.write("/// The image is `assets/stickers3d/<key>.webp`.\n")
        f.write("const kBuiltinStickerData = '''\n")
        for g, k, glyph, words, _, _ in uniq:
            f.write('%d|%s|%s|%s\n' % (g, k, glyph, ','.join(w.replace("'", '') for w in words)))
        f.write("''';\n")
    print('%d stickers, %.2f MB' % (len(uniq), total / 1e6))


if __name__ == '__main__':
    sys.exit(main())
