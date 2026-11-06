"""Static checks over dist/landing: internal links/assets resolve, no TODO / emails / local paths,
no inline scripts/styles (CSP), no jargon or brand comparisons on public pages.

    bash branding/tools/make_dist.sh && python3 branding/tools/check_dist.py dist/landing

Exits 1 when a check fails (CI job "website")."""
import re, sys, json
from pathlib import Path
from html.parser import HTMLParser

D = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / 'dist' / 'landing')
errors = []

def resolve(url, base):
    url = url.split('#')[0].split('?')[0]
    if not url:
        return True
    if url.startswith('/'):
        p = D / url.lstrip('/')
    else:
        p = (base.parent / url)
    if p.is_dir() or url.endswith('/'):
        p = p / 'index.html'
    return p.exists()

class P(HTMLParser):
    def __init__(s, f):
        super().__init__(); s.f = f; s.ids = set(); s.refs = []; s.in_script = False
    def handle_starttag(s, tag, a):
        a = dict(a)
        if 'id' in a: s.ids.add(a['id'])
        if 'style' in a: errors.append(f'{s.f}: inline style attr on <{tag}>')
        for k in a:
            if k.startswith('on'): errors.append(f'{s.f}: inline handler {k}')
        if tag == 'script':
            if 'src' not in a: errors.append(f'{s.f}: inline <script>')
        if tag == 'style': errors.append(f'{s.f}: <style> element')
        for k in ('href', 'src'):
            v = a.get(k)
            if v: s.refs.append((tag, v))
        if tag == 'svg' and a.get('aria-hidden') != 'true' and 'aria-label' not in a and 'role' not in a:
            errors.append(f'{s.f}: svg without aria-hidden')

SPRITE = (D / 'assets/img/icons.svg').read_text(encoding='utf-8')
SPRITE_IDS = set(re.findall(r'<symbol id="([^"]+)"', SPRITE))
if '--' in re.sub(r'<!--|-->', '', ''.join(re.findall(r'<!--.*?-->', SPRITE, re.S))):
    errors.append('icons.svg: "--" inside an XML comment breaks the whole sprite')
for sym_bad in [s for s in re.findall(r'<symbol [^>]*>', SPRITE) if 'viewBox="0 0 256 256"' not in s]:
    errors.append(f'icons.svg: unexpected viewBox {sym_bad}')
if (D / 'assets/img/icons.svg').stat().st_size > 60_000: errors.append('icons.svg: over 60 KB')

# The only external site public pages may link to: the official binaries-only release repo.
OFFICIAL_EXTERNAL = ('https://github.com/hoangtuvungcao/get_lumora/',)

pages = {}
for f in sorted(D.rglob('*.html')):
    p = P(f.relative_to(D)); p.feed(f.read_text(encoding='utf-8')); pages[f] = p

for f, p in pages.items():
    for tag, v in p.refs:
        if re.match(r'^(https?:|mailto:|data:)', v):
            if 'getlumora.pages.dev' in v:
                path = re.sub(r'^https://getlumora\.pages\.dev', '', v)
                if not resolve(path, f): errors.append(f'{p.f}: absolute link to missing {v}')
            elif tag == 'a' and not v.startswith(OFFICIAL_EXTERNAL):
                errors.append(f'{p.f}: external link {v}')
            continue
        target = v.split('#')[0]
        if not resolve(v, f):
            errors.append(f'{p.f}: broken {tag} {v}')
        elif '#' in v and target in ('', ) :
            frag = v.split('#', 1)[1]
            if frag and frag not in p.ids: errors.append(f'{p.f}: missing anchor #{frag}')
        elif '#' in v and not v.startswith('/assets/'):
            frag = v.split('#', 1)[1]
            tp = D / target.lstrip('/')
            if tp.is_dir() or target.endswith('/'): tp = tp / 'index.html'
            other = pages.get(tp)
            # ids rendered by JS on /download/ (platform cards)
            js_ids = {'windows', 'macos', 'linux', 'android'}
            if other and frag and frag not in other.ids and frag not in js_ids:
                errors.append(f'{p.f}: missing anchor {v}')
        if v.startswith('/assets/img/icons.svg') and '#' in v:  # also matches the versioned icons.svg?v=...#id
            sym = v.split('#')[1]
            if sym not in SPRITE_IDS: errors.append(f'{p.f}: missing icon {sym}')

# icons picked at runtime: icon("id") / "...#" + "id" in JS, "icon" fields in releases.json
for js in (D / 'assets/js').glob('*.js'):
    src = js.read_text(encoding='utf-8')
    ids = set(re.findall(r'\bicon\("([a-z0-9-]+)"', src))
    m = re.search(r'icons\.svg[^"]*#"\s*\+\s*\(([^;]*)\)', src)
    if m: ids |= set(re.findall(r'"([a-z0-9-]+)"', m.group(1)))
    for sym in ids - SPRITE_IDS: errors.append(f'{js.name}: missing icon {sym}')
for sym in set(re.findall(r'"icon":\s*"([a-z0-9-]+)"', (D / 'releases.json').read_text())) - SPRITE_IDS:
    errors.append(f'releases.json: missing icon {sym}')

# CSS url()s
css = (D / 'assets/css/styles.css').read_text(encoding='utf-8')
for u in re.findall(r'url\(([^)]+)\)', css):
    u = u.strip('"\'')
    if not u.startswith('data:') and not resolve(u, D / 'assets/css/styles.css'): errors.append(f'css: missing {u}')
# JS absolute paths
for js in (D / 'assets/js').glob('*.js'):
    for u in re.findall(r'"(/[a-z][^"#?{ ]*)', js.read_text(encoding='utf-8')):
        if u.endswith('/downloads/'): continue
        if not resolve(u, js): errors.append(f'{js.name}: missing {u}')
# manifest
for ic in json.loads((D / 'site.webmanifest').read_text())['icons']:
    if not resolve(ic['src'], D / 'site.webmanifest'): errors.append(f'manifest: missing {ic["src"]}')
# releases: no download links unless available + url/file
rel = json.loads((D / 'releases.json').read_text())
for pl in list(rel['platforms'].values()) + list(rel['tools'].values()):
    for fl in pl['files']:
        if fl.get('available') and not (fl.get('url') or (D / 'downloads' / fl['file']).exists()):
            if not fl.get('url'): errors.append(f'releases: {fl["id"]} available but no hosted file')

# text checks
bad = [
    (r'TODO', 'TODO'), (r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}', 'email'), (r'/home/', 'local path'),
    (r'lumora\.app', 'old domain'),
]
public_bad = [r'P2P', r'\brelay', r'\bNAT\b', r'\bSTUN\b', r'khoá công khai|khóa công khai|public key|key pair', r'\bNostr', r'\bDHT\b',
              r'\bQUIC\b', r'\bUPnP\b', r'Telegram', r'Discord', r'Zalo', r'WhatsApp', r'Messenger', r'TeamViewer', r'AnyDesk',
              r'cứ yên tâm', r'Vẫn chạy', r'Run anyway', r'right-click → Open', r'chuột phải → Mở',
              r'recovery_phrase', r'export_backup', r'remote_status', r'remote_set\b', r'remote_new_password']
# Pages that must name things the rest of the site avoids:
#  * the privacy policy lists the public services the app talks to (transparency);
#  * the download page tells people how to open an installer the OS doesn't recognise yet,
#    always after checking the SHA-256 (see FAQ q7).
ALLOW = {
    'privacy/': {r'\brelay', r'\bSTUN\b', r'\bNostr', r'\bDHT\b', r'\bUPnP\b'},
    'assets/js/legal.js': {r'\brelay', r'\bSTUN\b', r'\bNostr', r'\bDHT\b', r'\bUPnP\b'},
    'download/': {r'Vẫn chạy'},
    'assets/js/app.js': {r'Run anyway'},
}
for f in sorted(D.rglob('*')):
    if f.suffix not in ('.html', '.js', '.json', '.txt', '.xml', '.webmanifest', '.css', '') or f.is_dir(): continue
    if 'sdk' in f.parts or f.name == 'OFL.txt': continue
    t = f.read_text(encoding='utf-8', errors='ignore')
    for pat, name in bad:
        for m in re.finditer(pat, t):
            if name == 'email' and re.search(r'\.(svg|png|woff2|js|py)$', m.group(0)): continue
            if name == 'email' and m.group(0).startswith('@'): continue
            errors.append(f'{f.relative_to(D)}: {name}: {m.group(0)}')
    rel = f.relative_to(D).as_posix()
    for pat in public_bad:
        if any(rel.startswith(pre) and pat in pats for pre, pats in ALLOW.items()):
            continue
        for m in re.finditer(pat, t):
            ctx = t[max(0, m.start() - 30): m.end() + 30].replace('\n', ' ')
            if pat == r'P2P' and 'p2p_only' in ctx.lower(): continue
            errors.append(f'{f.relative_to(D)}: jargon/brand "{m.group(0)}" …{ctx}…')
for f in D.rglob('*'):
    if re.match(r'(?i)readme', f.name) or f.suffix == '.md': errors.append(f'internal file published: {f}')

# The privacy policy tells people which switch turns a feature off ("…" ở/in Cài đặt / Settings):
# every quoted name must be a real label in the app (VI in the page, EN in legal.js), and the
# features that are on by default must name their switch.
STRINGS = Path(__file__).resolve().parents[2] / 'app' / 'lib' / 'l10n' / 'strings_data.dart'
if STRINGS.exists():
    labels = STRINGS.read_text(encoding='utf-8')
    priv = (D / 'privacy' / 'index.html').read_text(encoding='utf-8').replace('&quot;', '"')
    legal = (D / 'assets' / 'js' / 'legal.js').read_text(encoding='utf-8').replace('\\"', '"')
    named = set()
    for src, pat in ((priv, r'"([^"<>]{3,60})"(?=[^"<>]{0,90}?(?:Cài đặt|›))'),
                     (legal, r'"([^"<>]{3,60})"(?=[^"<>]{0,90}?(?:Settings|›))')):
        for m in re.finditer(pat, src):
            name = m.group(1)
            named.add(name)
            if f"'{name}'" not in labels:
                errors.append(f'privacy: names setting "{name}" that is not an app label')
    for must in ('Giúp bạn bè kết nối', 'Help friends connect', 'Gửi qua bạn bè khi ngoại tuyến', 'Tìm bạn trong cùng mạng Wi-Fi'):
        if must not in named:
            errors.append(f'privacy: does not say how to turn off "{must}"')

print('\n'.join(errors) if errors else 'ALL CHECKS PASSED')
print(len(pages), 'html pages checked')
sys.exit(1 if errors else 0)
