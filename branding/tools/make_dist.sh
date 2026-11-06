#!/usr/bin/env bash
# Copy landing/ into dist/landing, leaving out files that must not be published:
# notes for maintainers (README*, *.md, downloads/README.txt) and brand source files
# the site never references. Deploy the result, not landing/ itself:
#
#   bash branding/tools/make_dist.sh
#   npx wrangler pages deploy dist/landing --project-name getlumora
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/landing"
OUT="$ROOT/dist/landing"

# Start from an empty output folder every time (only ever this one fixed path).
if [ -d "$OUT" ]; then
  find "$OUT" -mindepth 1 -delete
fi
mkdir -p "$OUT"

# Copy with tar so the exclusions stay in one readable list.
tar -C "$SRC" \
  --exclude='README*' \
  --exclude='*.md' \
  --exclude='./downloads' \
  --exclude='./assets/img/og-image.svg' \
  --exclude='./assets/img/lumora-mark.svg' \
  --exclude='.DS_Store' \
  -cf - . | tar -C "$OUT" -xf -

# Fail loudly if something internal slipped through.
leaks="$(cd "$OUT" && find . \( -iname 'README*' -o -name '*.md' -o -path './downloads*' \) -print)"
if [ -n "$leaks" ]; then
  echo "make_dist: internal files would be published:" >&2
  echo "$leaks" >&2
  exit 1
fi

# New deploys must never mix new pages with old cached CSS/JS.
python3 "$ROOT/branding/tools/version_assets.py" "$OUT"

count="$(find "$OUT" -type f | wc -l)"
size="$(du -sh "$OUT" | cut -f1)"
echo "dist ready: $OUT ($count files, $size)"
