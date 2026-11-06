# Lumora — landing site

This is the static homepage and download page for Lumora: plain HTML, CSS and vanilla JS. There is **no build step and there are no external requests** (fonts, icons and scripts are self-hosted).

```
landing/
├── index.html            homepage — plain-language copy (hero + product mock, features, use cases, 3 steps, privacy, downloads, FAQ)
├── download/index.html   download page: simple cards + install steps; checksums/architectures/system notes live in the collapsed "Technical details" panel (/download/#tech opens it)
├── 404.html
├── developers/index.html      bot guide (Python + JS quick start, buttons/callbacks, commands, files, resources)
├── developers/api/index.html  JSON API reference rendered from docs/src/dev/api-public.md (curated, no internals)
├── developers/sdk/            downloadable copies of sdk/python/lumora_bot.py, sdk/js/lumora-bot.mjs, sdk/examples/*
├── privacy/index.html, terms/index.html   plain-language privacy policy and terms (text: branding/tools/legal_content.py)
├── releases.json         ← release data (filled by branding/tools/update_releases.py)
├── downloads/            unused (binaries are GitHub release assets; never published by make_dist.sh)
├── assets/css/styles.css
├── assets/js/theme-init.js  (blocking, tiny: applies saved theme before paint)
├── assets/js/app.js         (i18n VI/EN, theme toggle, OS detection, release rendering)
├── assets/js/dev.js         (developer pages only: EN strings, tiny syntax highlighter, copy buttons, tabs; loads before app.js)
├── assets/js/legal.js       (privacy/terms pages only: EN strings, generated; loads before app.js)
├── assets/img/           icons.svg sprite (Phosphor Icons, MIT; built by branding/tools/build_icons.py), og-image.png, PWA icons (og-image.svg / lumora-mark.svg are sources, not published)
├── assets/fonts/         Be Vietnam Pro woff2 (Latin + Vietnamese subset) + OFL.txt
├── _headers              security headers (strict CSP, HSTS…) + cache rules (Cloudflare Pages / Netlify syntax)
├── _redirects            /tai-ve → /download/, optional /downloads/* → external host
├── favicon.ico, favicon.svg, apple-touch-icon.png, site.webmanifest, robots.txt, sitemap.xml

```

The homepage is about 87 KB uncompressed (HTML, CSS and JS; plus a 40 KB / 12 KB gzipped icon sprite), and about 107 KB of fonts.

Content rule: the homepage uses no technical jargon. Technical details (hashes, architectures, package formats, Linux/Wayland notes) belong only in the download page's Technical details panel. The site never describes network internals.

## Local preview

```bash
bash branding/tools/make_dist.sh            # builds dist/landing (what gets deployed)
cd dist/landing && python3 -m http.server 8080
# open http://localhost:8080  (add ?lang=en to force English)
```
Use an HTTP server rather than `file://`. The SVG sprite and `releases.json` need same-origin HTTP.

## Deploy: Cloudflare Pages

Always deploy the cleaned copy, never `landing/` itself (it contains this README and other notes):
```bash
bash branding/tools/make_dist.sh
npx wrangler pages deploy dist/landing --project-name getlumora
```
`make_dist.sh` copies `landing/` to `dist/landing` without `README*`, `*.md`, `downloads/` and the unused brand source SVGs, and fails if any of them slips through.
If you connect the Git repo in the Cloudflare dashboard instead, use **Framework: None**, **Build command: `bash branding/tools/make_dist.sh`** and **Output directory: `dist/landing`**.
`_headers` and `_redirects` are applied automatically. QA screenshots live outside the site in `branding/screenshots-landing/`.

**Authentication.** Wrangler needs either `npx wrangler login` (opens a browser, once per machine) or, for CI, the environment variables `CLOUDFLARE_API_TOKEN` (a token with the *Cloudflare Pages: Edit* permission) and `CLOUDFLARE_ACCOUNT_ID`. The site lives at https://getlumora.pages.dev (project `getlumora`). A custom domain can be added in the dashboard under Pages → getlumora → Custom domains.

**Caching.** Only `/assets/fonts/*` is cached as immutable. CSS, JS and images keep their names between deploys, so they get `max-age=3600, must-revalidate`; HTML uses the Pages default (always revalidated). Cloudflare merges every matching `_headers` rule, so don't add a long-lived rule for a parent folder such as `/assets/*`.

## Deploy: any VPS (nginx / Caddy)

Build `dist/landing` with `make_dist.sh` and copy it (`rsync -a --delete dist/landing/ server:/var/www/lumora/`). Then copy the headers from `_headers`, because nginx and Caddy don't read that file.

**Caddy**
```
example.com {
  root * /var/www/lumora
  file_server
  try_files {path} {path}/ =404
  handle_errors { rewrite * /404.html
                  file_server }
  header {
    Content-Security-Policy "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests"
    Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    X-Content-Type-Options nosniff
    X-Frame-Options DENY
    Referrer-Policy strict-origin-when-cross-origin
    Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
  }
  @fonts path /assets/fonts/*
  header @fonts Cache-Control "public, max-age=31536000, immutable"
  @assets path /assets/css/* /assets/js/* /assets/img/*
  header @assets Cache-Control "public, max-age=3600, must-revalidate"
  header /releases.json Cache-Control "no-cache"
  redir /tai-ve /download/ 301
}
```

**nginx**
```nginx
server {
  listen 443 ssl http2; server_name example.com;
  root /var/www/lumora; index index.html; error_page 404 /404.html;
  add_header Content-Security-Policy "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests" always;
  add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
  add_header X-Content-Type-Options nosniff always;
  add_header X-Frame-Options DENY always;
  add_header Referrer-Policy strict-origin-when-cross-origin always;
  add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;
  location / { try_files $uri $uri/ =404; }
  location /assets/fonts/ { add_header Cache-Control "public, max-age=31536000, immutable"; }
  location /assets/ { add_header Cache-Control "public, max-age=3600, must-revalidate"; }
  location = /releases.json { add_header Cache-Control "no-cache"; }
  location /downloads/ { add_header Content-Disposition attachment; }
  location = /tai-ve { return 301 /download/; }
}
```
(nginx: `add_header` inside a `location` replaces the server-level headers, so repeat the security headers there if you add any.)

## Publishing a new release

Releases are built by CI in the private repo and published (binaries only) to
**github.com/hoangtuvungcao/get_lumora** — see `docs/src/ops/release.md`. The site links straight
to those GitHub release assets.

1. Review and publish the draft release in `get_lumora`.
2. Fill `releases.json` from it (url, sha256 from the signed SHA256SUMS, size, `"available": true`):
   `python3 branding/tools/update_releases.py --tag vX.Y.Z` (add `--mac-signed` when the DMG is notarized;
   offline: `--sums SHA256SUMS --dir <folder with the files>`).
3. `python3 branding/tools/build_pages.py && bash branding/tools/make_dist.sh && python3 branding/tools/check_dist.py dist/landing`, then deploy.

`releases.json` format: `baseUrl`, `notesUrl` and each `file` may contain `{version}` (replaced with
`version`); file names are exactly the asset names the CI release job publishes
(`Lumora-v{version}-windows-x86_64-setup.exe`, …). A file may have an absolute `url` (written by
`update_releases.py`), a `note` (shown in the table), and `"alt": true` (offered as a small
"Not sure? Get …" link under the platform card — the Android universal APK). `comingSoon` lists
platforms without builds yet (iPhone/iPad). Each platform has a plain-language `simple` line (cards)
and a technical `requirements` line (Technical details).

Files without `"available": true` are never linked: their card and the hero button show a disabled "Sắp ra mắt" / "Coming soon" button, the table lists the file name as plain text, and the checksum column and checksum commands stay hidden until at least one file is available. Never mark a file available before it is actually uploaded (that would be a 404).
The inline `RELEASES` fallback in `assets/js/app.js` (between `RELEASES-BEGIN/END`) is a copy of
`releases.json` written by `build_pages.py` / `update_releases.py`; never edit it by hand.

## i18n

Vietnamese is the default and is written directly in the HTML, so it works for SEO and without JS. Every translatable node has `data-i18n="key"` (or `data-i18n-html` / `data-i18n-attr`). English strings live in the `EN` object in `assets/js/app.js`.
The language toggle saves the choice in `localStorage` (inside try/catch). It updates `<html lang>`, `<title>`, the meta description and OG/Twitter tags. `?lang=en` forces English.
To add a string, add `data-i18n="my.key"` in the HTML and `"my.key": "…"` in `EN`.

## Regenerating generated pages

`download/`, `404.html`, `developers/`, `developers/api/`, `privacy/`, `terms/` (and `assets/js/legal.js`) are generated from `index.html`'s header/footer. The bot guide's code samples are copied verbatim from `sdk/`, and the API page is rendered from `docs/src/dev/api-public.md` (a curated public subset of `api.md`; keep it free of internal/network/crypto terms). After changing the nav/footer in `index.html`, the SDK, or the API doc, run:
```bash
pip install markdown
python3 branding/tools/build_pages.py
```
The output is static HTML; the site still has no build step at deploy time.

## Regenerating brand assets

The icons and OG image come from `branding/tools/` (`pip install cairosvg fonttools pillow`):
```bash
python3 branding/tools/build_brand.py   # logos + icon sets
python3 branding/tools/build_og.py      # landing/assets/img/og-image.{svg,png}
cp branding/icons/web/{favicon.ico,favicon.svg,apple-touch-icon.png} landing/
```

The UI icon sprite `assets/img/icons.svg` is built from Phosphor Icons (MIT). Site ids (chat, shield,
os-windows…) map to Phosphor names and weights in the `ICONS` table of `build_icons.py`; add an icon
there, then rebuild from an unpacked `npm pack @phosphor-icons/core`:
```bash
python3 branding/tools/build_icons.py /path/to/package/assets
```
Icon styling lives in `styles.css`: `.ic` sizes (20/16/14 px), `--duo` turns on the 20 % duotone layer,
and tiles (`.feature__icon` 56/28, `.mini__icon`/`.who__icon` 44/24) take their colour from `--ac`
(`fi-violet|cyan|pink|gold`). A tile next to a title sits on the title's cap height.
