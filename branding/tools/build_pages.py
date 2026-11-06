#!/usr/bin/env python3
"""Build the secondary landing pages from landing/index.html's header/footer.

Generates (static, committed output — the site itself has no build step):
  landing/download/index.html
  landing/404.html
  landing/open/index.html              (fallback for shared links /add/, /join/, /remote/ — see _redirects)
  landing/developers/**                (developer docs, see dev_pages.py: overview, quickstart, guides,
                                        SDK reference, examples, production, SDK files and packages)
  landing/developers/api/index.html    (rendered from docs/src/dev/api-public.md)
  landing/privacy/, landing/terms/     (legal_content.py) + assets/js/legal.js
  landing/sitemap.xml                  (every indexable page)
  landing/assets/js/app.js             (only the inline releases fallback, from releases.json)

Requires: pip install markdown
Usage:    python3 branding/tools/build_pages.py
"""
import html
import re
import subprocess
import sys
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parents[2]
L = ROOT / "landing"
SDK = ROOT / "sdk"
# Public, curated reference (no network internals). The full internal contract stays in api.md.
API_MD = ROOT / "docs" / "src" / "dev" / "api-public.md"

src = (L / "index.html").read_text(encoding="utf-8")
HEAD = src[: src.index('<main id="main">')]
FOOT = src[src.index("</main>"):]


def I(name, cls="ic"):
    return f'<svg class="{cls}" aria-hidden="true" focusable="false"><use href="/assets/img/icons.svg#{name}"/></svg>'


def head_for(page, path, title_vi, desc_vi, og_title=None, dev_js=False, noindex=False, page_js=None):
    h = HEAD.replace('<html lang="vi">', f'<html lang="vi" data-page="{page}">')
    h = h.replace("<title>Lumora — Kết nối trực tiếp. Riêng tư theo cách của bạn.</title>", f"<title>{title_vi}</title>")
    h = re.sub(r'<meta name="description" content="[^"]*">', f'<meta name="description" content="{html.escape(desc_vi)}">', h)
    url = f"https://getlumora.pages.dev{path}"
    if noindex:
        h = h.replace('<link rel="canonical" href="https://getlumora.pages.dev/">\n', '<meta name="robots" content="noindex">\n')
    else:
        h = h.replace('<link rel="canonical" href="https://getlumora.pages.dev/">', f'<link rel="canonical" href="{url}">')
    h = h.replace('<meta property="og:url" content="https://getlumora.pages.dev/">', f'<meta property="og:url" content="{url}">')
    if og_title:
        h = re.sub(r'<meta property="og:title" content="[^"]*">', f'<meta property="og:title" content="{og_title}">', h)
        h = re.sub(r'<meta name="twitter:title" content="[^"]*">', f'<meta name="twitter:title" content="{og_title}">', h)
        h = re.sub(r'<meta property="og:description" content="[^"]*">', f'<meta property="og:description" content="{html.escape(desc_vi)}">', h)
        h = re.sub(r'<meta name="twitter:description" content="[^"]*">', f'<meta name="twitter:description" content="{html.escape(desc_vi)}">', h)
    if dev_js:
        page_js = "dev.js"
    if page_js:
        h = h.replace('<script src="/assets/js/app.js" defer></script>',
                      f'<script src="/assets/js/{page_js}" defer></script>\n<script src="/assets/js/app.js" defer></script>')
    return h


def code(text, lang):
    return f'<pre class="code"><code data-lang="{lang}">{html.escape(text.rstrip())}</code></pre>'


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


# ---------------------------------------------------------------- download
def build_download():
    main = f'''<main id="main">
  <section class="page-head">
    <div class="container">
      <p class="badge-gold">{I("sparkles", "ic ic--sm")}<span data-i18n="hero.badge">Miễn phí trọn đời · Không quảng cáo</span></p>
      <h1 class="hero__title" data-i18n="dp.title">Tải Lumora</h1>
      <p data-i18n="dp.lead">Miễn phí, không cần đăng ký. Chọn thiết bị của bạn bên dưới.</p>
    </div>
  </section>

  <section class="section section--tight">
    <div class="container">
      <div class="dl-grid" id="dl-grid" data-anchors>
        <noscript><p>JavaScript is required to list files. See /releases.json.</p></noscript>
      </div>
      <p class="dl-note" data-i18n="dl.note">iPhone/iPad: có bản cài thủ công cho người dùng nâng cao (xem Tất cả bản tải).</p>

      <h2 class="sub-h" id="all" data-i18n="dp.all">Tất cả bản tải</h2>
      <p class="sub-p" data-i18n="dp.allLead">Mỗi thiết bị có vài dạng tệp. Không chắc thì chọn bản có nhãn "Khuyên dùng".</p>
      <div class="dl-all" id="dl-all"></div>

      <h2 class="sub-h" data-i18n="dp.howto">Cách cài đặt</h2>
      <div class="howto">
        <div class="glass"><h3>{I("os-windows")}Windows</h3><ol><li data-i18n="dp.w1">Mở tệp Setup vừa tải về.</li><li data-i18n="dp.w2">Nếu Windows hiện "Windows đã bảo vệ PC của bạn", hãy kiểm tra mã SHA-256 trước (xem phần Thông tin cho người rành kỹ thuật), rồi bấm "Thông tin thêm" → "Vẫn chạy".</li><li data-i18n="dp.w3">Bấm "Cài đặt", rồi mở Lumora từ menu Start.</li></ol></div>
        <div class="glass"><h3>{I("os-apple")}macOS</h3><ol><li data-i18n="dp.m1">Mở tệp .dmg và kéo Lumora vào thư mục Applications.</li><li data-i18n="dp.m2">Lần đầu mở, nếu macOS báo không thể kiểm tra nhà phát triển: vào Cài đặt hệ thống › Quyền riêng tư &amp; Bảo mật, kéo xuống và bấm "Vẫn mở".</li><li data-i18n="dp.m3">Mở Lumora từ Launchpad.</li></ol></div>
        <div class="glass"><h3>{I("os-linux")}Linux</h3><ol><li data-i18n="dp.l1">AppImage: nhấp chuột phải vào tệp → Thuộc tính → cho phép chạy như chương trình, rồi nhấp đúp để mở.</li><li data-i18n="dp.l2">Debian / Ubuntu: mở tệp .deb bằng trình cài phần mềm, hoặc chạy sudo apt install ./&lt;tên-tệp&gt;.deb.</li><li data-i18n="dp.l3">Sau khi cài gói .deb, mở Lumora từ danh sách ứng dụng.</li></ol></div>
        <div class="glass"><h3>{I("os-android")}Android</h3><ol><li data-i18n="dp.a1">Bấm "Tải về" trên điện thoại. Bản này cài được trên mọi điện thoại và máy tính bảng Android.</li><li data-i18n="dp.a2">Mở tệp và chọn "Cài đặt". Nếu được hỏi, hãy cho phép cài từ trình duyệt.</li><li data-i18n="dp.a3">Muốn tải nhẹ hơn? Chọn "bản nhẹ cho máy 64-bit đời mới" ngay dưới nút Tải về. Nếu bản nhẹ báo "gói không hợp lệ", hãy quay lại bản Mọi điện thoại Android.</li></ol></div>
      </div>

      <details class="glass tech" id="tech">
        <summary>{I("sparkles")}<span><span data-i18n="dp.tech">Thông tin cho người rành kỹ thuật</span><small data-i18n="dp.techSub">Mã kiểm tra, kiến trúc, định dạng gói và ghi chú hệ thống.</small></span></summary>
        <div class="tech__body">
          <p class="sub-p"><b class="js-version">—</b> · <span data-i18n="dp.released">Phát hành</span> <span class="js-date"></span></p>
          <div class="table-wrap table-wrap--dl">
            <table class="table table--dl">
              <thead><tr><th data-i18n="dp.thPlatform">Nền tảng</th><th data-i18n="dp.thFile">Tệp</th><th data-i18n="dp.thArch">Kiến trúc</th><th data-i18n="dp.thSha">Mã kiểm tra tệp</th></tr></thead>
              <tbody id="dl-table"></tbody>
            </table>
          </div>
          <h3 data-i18n="dp.req">Yêu cầu hệ thống</h3>
          <ul class="tech__notes" id="dl-req"></ul>
          <div id="verify-block">
          <h3 id="verify" data-i18n="dp.verify">Mã kiểm tra tệp</h3>
          <p class="sub-p" data-i18n="dp.verifyLead">Dùng để kiểm tra tệp tải về không bị sửa. Chạy lệnh dưới đây rồi so sánh kết quả với mã trong bảng; nếu khác nhau, đừng cài tệp đó.</p>
          <div class="verify">
            <div data-verify="win-exe"><h4>{I("os-windows")}PowerShell</h4><pre><code>Get-FileHash .\\<span data-file="win-exe">Lumora-Setup.exe</span> -Algorithm SHA256</code></pre></div>
            <div data-verify="mac-dmg"><h4>{I("os-apple")}macOS</h4><pre><code>shasum -a 256 <span data-file="mac-dmg">Lumora.dmg</span></code></pre></div>
            <div data-verify="linux-appimage"><h4>{I("os-linux")}Linux</h4><pre><code>sha256sum <span data-file="linux-appimage">Lumora.AppImage</span></code></pre></div>
          </div>
          <div class="sums">
            <p class="sub-p" data-i18n="dp.sums">Mỗi bản phát hành còn có tệp SHA256SUMS (mã kiểm tra của mọi tệp) và SHA256SUMS.sigstore.json (chữ ký số chứng minh danh sách do quy trình build chính thức của Lumora tạo ra). Để kiểm tra tất cả cùng lúc, đặt hai tệp này cạnh tệp đã tải rồi chạy:</p>
            <pre><code>sha256sum -c SHA256SUMS --ignore-missing
cosign verify-blob --bundle SHA256SUMS.sigstore.json \\
  --certificate-identity "https://github.com/hoangtuvungcao/lumora/.github/workflows/build.yml@refs/tags/<span class="js-tag">v1.0.0</span>" \\
  --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS</code></pre>
            <p class="sub-p"><a class="js-release-link" href="https://github.com/hoangtuvungcao/get_lumora/releases" target="_blank" rel="noopener" data-i18n="dp.relPage">Mở trang phát hành trên GitHub</a></p>
          </div>
          </div>
          <h3 id="bot-runner" data-i18n="dp.tools">Lumora Bot Runner (dành cho người tạo bot)</h3>
          <p class="sub-p" data-i18n="dp.toolsLead">Chương trình nhỏ chạy trên máy tính của bạn, giúp đoạn mã bot kết nối vào Lumora. Cài một lần; bot chạy khi máy bật. Người dùng bình thường không cần tệp này.</p>
          <p class="sub-p"><a href="/developers/quickstart/#run" data-i18n="dp.toolsMore">Hướng dẫn cài đặt và chạy bot →</a></p>
          <div class="table-wrap table-wrap--dl">
            <table class="table table--dl">
              <thead><tr><th data-i18n="dp.thPlatform">Nền tảng</th><th data-i18n="dp.thFile">Tệp</th><th data-i18n="dp.thArch">Kiến trúc</th><th data-i18n="dp.thSha">Mã kiểm tra tệp</th></tr></thead>
              <tbody id="dl-tools"></tbody>
            </table>
          </div>
          <h3 data-i18n="dp.notes">Ghi chú hệ thống</h3>
          <ul class="tech__notes">
            <li data-i18n="dp.n1">Linux: cấp quyền chạy cho AppImage (chmod +x) hoặc cài gói .deb bằng apt. Trên Wayland, hệ thống sẽ hỏi quyền chia sẻ màn hình khi bắt đầu hỗ trợ từ xa: hãy chọn màn hình và bấm "Chia sẻ".</li>
            <li data-i18n="dp.n2">macOS: để điều khiển từ xa, cấp quyền "Ghi màn hình" và "Trợ năng" trong Cài đặt hệ thống → Quyền riêng tư &amp; Bảo mật.</li>
            <li data-i18n="dp.n3">Windows: để cài im lặng trên nhiều máy, chạy tệp Setup với /VERYSILENT /SUPPRESSMSGBOXES. Bản .zip không cần cài: giải nén rồi chạy lumora.exe.</li>
            <li data-i18n="dp.n4">Linux: gói .deb ghi sẵn các thư viện cần thiết nên apt tự cài giúp bạn. Bản .tar.gz dành cho người rành kỹ thuật: giải nén rồi chạy ./lumora.</li>
          </ul>
        </div>
      </details>
    </div>
  </section>
'''
    write(L / "download" / "index.html",
          head_for("download", "/download/", "Tải về — Lumora",
                   "Tải Lumora miễn phí cho Windows, Mac, Linux và Android. Không cần đăng ký.",
                   og_title="Tải Lumora miễn phí") + main + FOOT)


# ---------------------------------------------------------------- 404
def build_404():
    main = '''<main id="main">
  <section class="page-head page-404">
    <div class="container">
      <p class="overline">404</p>
      <h1 data-i18n="nf.title">Không tìm thấy trang</h1>
      <p data-i18n="nf.lead">Đường dẫn này không tồn tại hoặc đã được chuyển đi.</p>
      <p class="nf-actions"><a class="btn btn--primary" href="/" data-i18n="nf.home">Về trang chủ</a> <a class="btn btn--glass" href="/download/" data-i18n="nav.download">Tải về</a></p>
    </div>
  </section>
'''
    write(L / "404.html", head_for("404", "/404", "404 — Lumora", "Không tìm thấy trang.", noindex=True) + main + FOOT)


# ---------------------------------------------------------------- open (shared links)
def build_open():
    """Fallback page for Lumora QR codes / shared links (/add/…, /join/…, /remote/…).

    _redirects rewrites those paths here (status 200, the address bar keeps the link).
    Static only: assets/js/open.js reads the link from the address in the browser,
    shows the matching text, points "Open with Lumora" at lumora://… and the download
    button comes from app.js (releases.json, with its built-in fallback). The page
    renders the same whether or not the link is valid."""
    def kinds(tag, cls, key_base, texts):
        out = []
        for kind, vi in texts:
            hidden = "" if kind == "other" else " hidden"
            out.append(f'<{tag} class="{cls} js-kind" data-kind="{kind}" data-i18n="{key_base}.{kind}"{hidden}>{vi}</{tag}>')
        return "\n      ".join(out)
    titles = kinds("h1", "hero__title", "op.title", [
        ("add", "Lời mời kết bạn trên Lumora"), ("join", "Lời mời vào nhóm Lumora"),
        ("remote", "Hỗ trợ máy tính từ xa"), ("other", "Mở trong Lumora")])
    leads = kinds("p", "op-lead", "op.lead", [
        ("add", "Một người bạn muốn kết bạn với bạn trên Lumora. Mở bằng Lumora để xem và gửi lời mời kết bạn."),
        ("join", "Bạn được mời vào một nhóm trên Lumora. Mở bằng Lumora để xem nhóm rồi bấm Tham gia."),
        ("remote", "Mở bằng Lumora để kết nối tới máy này. Bạn vẫn cần mật khẩu tạm thời do người bên kia đọc cho bạn."),
        ("other", "Liên kết này dành cho ứng dụng Lumora.")])
    main = f'''<main id="main">
  <section class="page-head">
    <div class="container">
      <p class="badge-gold">{I("sparkles", "ic ic--sm")}<span data-i18n="hero.badge">Miễn phí trọn đời · Không quảng cáo</span></p>
      {titles}
      {leads}
    </div>
  </section>

  <section class="section section--tight">
    <div class="container container--narrow">
      <div class="glass op-card">
        <div class="op-id" id="op-id" hidden>
          <p class="overline" data-i18n="op.idLabel">ID Lumora</p>
          <p class="op-id__value" id="op-id-value"></p>
          <p class="sub-p js-kind" data-kind="add" data-i18n="op.idHint.add" hidden>Không mở được? Trong Lumora, chọn Thêm bạn và nhập ID này.</p>
          <p class="sub-p js-kind" data-kind="remote" data-i18n="op.idHint.remote" hidden>Không mở được? Trong Lumora, mở Điều khiển từ xa và nhập ID này.</p>
        </div>
        <p class="op-broken" id="op-broken" data-i18n="op.broken" hidden>Liên kết này có vẻ chưa đầy đủ. Hãy nhờ người gửi chia sẻ lại.</p>
        <div class="hero__cta op-cta">
          <a class="btn btn--primary btn--xl" id="op-open" href="/download/">
            {I("arrow-right")}<span data-i18n="op.open">Mở bằng Lumora</span>
          </a>
          <a class="btn btn--glass btn--xl" id="primary-dl" href="/download/">
            {I("download")}<span id="primary-dl-label" data-i18n="op.get">Tải Lumora miễn phí</span>
          </a>
        </div>
        <p class="hero__meta" id="primary-dl-meta" aria-live="polite"></p>
      </div>

      <div class="glass op-steps">
        <h2 class="sub-h" data-i18n="op.stepsTitle">Chưa có Lumora?</h2>
        <ol>
          <li data-i18n="op.step1">Tải và cài Lumora. Miễn phí, không cần đăng ký.</li>
          <li data-i18n="op.step2">Quay lại trang này và bấm “Mở bằng Lumora”, hoặc quét lại mã QR bằng Lumora.</li>
        </ol>
        <p class="sub-p"><a class="link-strong" href="/download/"><span data-i18n="op.other">Xem bản cho thiết bị khác</span>{I("arrow-right", "ic ic--sm")}</a></p>
      </div>
    </div>
  </section>
'''
    head = head_for("open", "/open/", "Mở trong Lumora", "Mở liên kết này bằng ứng dụng Lumora, hoặc tải Lumora miễn phí.",
                    noindex=True, page_js="open.js")
    head = head.replace('data-page="open"', 'data-page="open" data-title-en="Open in Lumora" '
                        'data-desc-en="Open this link with the Lumora app, or get Lumora for free."', 1)
    write(L / "open" / "index.html", head + main + FOOT)


# ---------------------------------------------------------------- developers (see dev_pages.py)
import dev_pages


# ---------------------------------------------------------------- API reference
def build_api():
    md = API_MD.read_text(encoding="utf-8")
    body = markdown.markdown(md, extensions=["tables", "fenced_code", "toc"], extension_configs={"toc": {"permalink": False}})
    # fenced code → highlighter languages; tables → scroll wrappers
    body = body.replace("\\|", "|")  # escaped pipes inside table code spans
    body = body.replace('<code class="language-json">', '<code data-lang="json">')
    body = re.sub(r"<pre><code(?![^>]*data-lang)>", '<pre><code data-lang="json">', body)
    body = body.replace("<pre><code", '<pre class="code"><code')
    body = body.replace("<table>", '<div class="table-wrap"><table class="table table--api">').replace("</table>", "</table></div>")
    body = re.sub(r"<h1[^>]*>.*?</h1>", "", body, count=1)
    toc = "".join(
        f'<li class="toc--{lvl}"><a href="#{hid}">{re.sub("<[^>]+>", "", txt)}</a></li>'
        for lvl, hid, txt in re.findall(r'<h([23]) id="([^"]+)">(.*?)</h\1>', body)
    )
    bi = dev_pages.bi
    main = f'''<main id="main">
  <section class="page-head page-head--left page-head--docs">
    <div class="container">
      {dev_pages.subnav("api")}
      <p class="badge-gold">{I("book-open", "ic ic--sm")}{bi("Tài liệu tham chiếu", "Reference")}</p>
      <h1 class="hero__title">{bi("Tài liệu JSON API", "JSON API reference")}</h1>
      <p class="lead-p">{bi("Các lệnh và sự kiện mà bot (qua bot.call) và ứng dụng tích hợp có thể dùng. Mỗi yêu cầu là một dòng JSON; phản hồi và sự kiện cũng là các dòng JSON.",
                            "Commands and events available to bots (through bot.call) and app integrations. Each request is one JSON line; responses and events are JSON lines too.")}</p>
      <p class="muted small">{bi("Nội dung tham chiếu được viết bằng tiếng Anh.", "The reference itself is written in English.")}</p>
    </div>
  </section>
  <section class="section section--tight">
    <div class="container api-layout">
      <nav class="api-toc glass" aria-label="Table of contents"><p class="overline">{bi("Trên trang này", "On this page")}</p><ul>{toc}</ul></nav>
      <article class="prose" lang="en">
{body}
      </article>
    </div>
  </section>
'''
    head = head_for("api", "/developers/api/", "Tài liệu JSON API — Lumora",
                    "Tài liệu tham chiếu Lumora JSON API: lệnh, sự kiện và cấu trúc dữ liệu cho bot và ứng dụng.",
                    og_title="Lumora JSON API reference", dev_js=True)
    head = head.replace('data-page="api"', 'data-page="api" data-title-en="JSON API reference — Lumora" '
                        'data-desc-en="Lumora JSON API reference: commands, events and data shapes for bots and app integrations."', 1)
    write(L / "developers" / "api" / "index.html", head + main + FOOT)


# ---------------------------------------------------------------- sitemap
SITE = "https://getlumora.pages.dev"
# Content date of the published pages (bump when the pages change meaningfully).
LASTMOD = "2026-11-06"


def build_sitemap():
    """Every indexable page: index.html files without a noindex robots tag."""
    urls = []
    for f in sorted(L.rglob("index.html")):
        rel = f.relative_to(L).parent.as_posix()
        if rel.startswith(("downloads", "assets")):
            continue
        if 'name="robots" content="noindex"' in f.read_text(encoding="utf-8"):
            continue
        urls.append("/" if rel == "." else f"/{rel}/")
    urls.sort(key=lambda u: (u != "/", u.count("/"), u))
    body = "".join(f"  <url><loc>{SITE}{u}</loc><lastmod>{LASTMOD}</lastmod></url>\n" for u in urls)
    write(L / "sitemap.xml", '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + body + "</urlset>\n")


# ---------------------------------------------------------------- privacy / terms
# Single source for the VI page text and its EN translation (written to assets/js/legal.js).
from legal_content import PAGES as LEGAL_PAGES, COMMON as LEGAL_COMMON


LINK = re.compile(r"\[([^\]]+)\]\((https://[^)\s]+)\)")


def legal_html(s):
    """Escape, then turn [text](https://…) into a link that opens in a new tab."""
    return LINK.sub(lambda m: f'<a href="{m.group(2)}" target="_blank" rel="noopener">{m.group(1)}</a>', html.escape(s))


def legal_text(tag, key, pair, en):
    """One translatable element: plain text via data-i18n, or (with links) HTML via data-i18n-html."""
    if LINK.search(pair[0]) or LINK.search(pair[1]):
        en[key] = legal_html(pair[1])
        return f'<{tag} data-i18n-html="{key}">{legal_html(pair[0])}</{tag}>'
    en[key] = pair[1]
    return f'<{tag} data-i18n="{key}">{html.escape(pair[0])}</{tag}>'


def build_legal():
    en = {k: v[1] for k, v in LEGAL_COMMON.items()}
    for slug, pg in LEGAL_PAGES.items():
        pre = pg["prefix"]
        en[f"{pre}.title"] = pg["title"][1]
        en[f"{pre}.lead"] = pg["lead"][1]
        en[f"{pre}.meta"] = pg["desc"][1]
        parts = []
        for si, sec in enumerate(pg["sections"], 1):
            k = f"{pre}.s{si}"
            en[k + ".t"] = sec["t"][1]
            parts.append(f'<h2 id="{sec["id"]}" data-i18n="{k}.t">{html.escape(sec["t"][0])}</h2>')
            for pi, para in enumerate(sec["p"], 1):
                if isinstance(para, dict):  # {"li": [(vi, en), ...]}
                    items = []
                    for ii, item in enumerate(para["li"], 1):
                        key = f"{k}.p{pi}.i{ii}"
                        items.append(legal_text("li", key, item, en))
                    parts.append("<ul>" + "".join(items) + "</ul>")
                else:
                    parts.append(legal_text("p", f"{k}.p{pi}", para, en))
        summary = []
        for i, item in enumerate(pg["summary"], 1):
            en[f"{pre}.sum{i}"] = item[1]
            summary.append(f'<li class="glass"><span class="tick">{I("check", "ic ic--sm")}</span><span data-i18n="{pre}.sum{i}">{html.escape(item[0])}</span></li>')
        other = "terms" if slug == "privacy" else "privacy"
        other_key = "footer.terms" if slug == "privacy" else "footer.privacy"
        other_vi = "Điều khoản sử dụng" if slug == "privacy" else "Chính sách quyền riêng tư"
        main = f'''<main id="main">
  <section class="page-head">
    <div class="container">
      <p class="badge-gold">{I(pg["icon"], "ic ic--sm")}<span data-i18n="lg.badge">{LEGAL_COMMON["lg.badge"][0]}</span></p>
      <h1 class="hero__title" data-i18n="{pre}.title">{html.escape(pg["title"][0])}</h1>
      <p data-i18n="{pre}.lead">{html.escape(pg["lead"][0])}</p>
      <p class="muted small" data-i18n="lg.updated">{LEGAL_COMMON["lg.updated"][0]}</p>
    </div>
  </section>
  <section class="section section--tight">
    <div class="container container--narrow">
      <ul class="rules legal-summary">{"".join(summary)}</ul>
      <article class="prose legal">
{chr(10).join(parts)}
      </article>
      <p class="legal-other"><a class="link-strong" href="/{other}/"><span data-i18n="{other_key}">{other_vi}</span>{I("arrow-right", "ic ic--sm")}</a></p>
    </div>
  </section>
'''
        write(L / slug / "index.html",
              head_for(slug, f"/{slug}/", f"{pg['title'][0]} — Lumora", pg["desc"][0],
                       og_title=f"{pg['title'][0]} — Lumora", page_js="legal.js") + main + FOOT)

    import json
    js = ("/* Lumora privacy/terms pages: English strings. GENERATED by branding/tools/build_pages.py\n"
          "   from branding/tools/legal_content.py; edit that file instead. Loads before app.js. */\n"
          "(function () {\n  \"use strict\";\n  var page = document.documentElement.getAttribute(\"data-page\");\n"
          f"  var EN = {json.dumps(en, ensure_ascii=False, indent=2)};\n"
          "  EN[\"meta.desc\"] = page === \"terms\" ? EN[\"tm.meta\"] : EN[\"pv.meta\"];\n"
          "  window.LUMORA_I18N = EN;\n})();\n")
    write(L / "assets" / "js" / "legal.js", js)


if __name__ == "__main__":
    build_download()
    build_404()
    build_open()
    subprocess.run([sys.executable, str(ROOT / "sdk" / "tools" / "gen_reference.py")], check=True)
    dev_pages.build(head_for, FOOT, I, code)
    build_api()
    build_legal()
    build_sitemap()
    from update_releases import sync_fallback
    sync_fallback()  # app.js inline fallback = landing/releases.json
    print("pages built")
