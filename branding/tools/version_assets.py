#!/usr/bin/env python3
"""Cache-busting for dist/: append ?v=<content hash> to every /assets/{css,js,img} reference
in HTML/CSS/JS, so a new deploy never mixes new pages with old cached styles or scripts.
Assets are processed leaves-first (images → css → js → html) so each hash covers the
already-rewritten file."""
import hashlib, re, sys
from pathlib import Path

root = Path(sys.argv[1])
REF = re.compile(r'(/assets/(?:css|js|img)/[A-Za-z0-9_./-]+\.(?:css|js|svg|png|webp|jpg|ico|json))(\?v=[0-9a-f]+)?')
hashes = {}

def h(rel):
    if rel not in hashes:
        p = root / rel.lstrip("/")
        hashes[rel] = hashlib.sha256(p.read_bytes()).hexdigest()[:10] if p.is_file() else None
    return hashes[rel]

def rewrite(p):
    s = p.read_text(encoding="utf-8")
    out = REF.sub(lambda m: m.group(1) + (f"?v={h(m.group(1))}" if h(m.group(1)) else ""), s)
    if out != s:
        p.write_text(out, encoding="utf-8")

for pattern in ("assets/img/**/*.svg", "assets/css/**/*.css", "assets/js/**/*.js", "**/*.html"):
    for p in sorted(root.glob(pattern)):
        rewrite(p)
        hashes.pop("/" + str(p.relative_to(root)), None)  # rehash after rewrite
print(f"versioned {sum(1 for v in hashes.values() if v)} asset references")
