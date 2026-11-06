#!/usr/bin/env python3
"""Lumora brand asset generator.

Generates every logo SVG (from parametric geometry) and the full raster
icon set (PNG / ICO / ICNS / Android / Linux / web) into branding/.

Requirements:  pip install cairosvg fonttools pillow
Usage:         python3 branding/tools/build_brand.py
"""
from __future__ import annotations

import io
import math
import os
import shutil
from pathlib import Path

import cairosvg
# pyrefly: ignore[missing-import]
from fontTools.pens.svgPathPen import SVGPathPen
# pyrefly: ignore[missing-import]
from fontTools.pens.transformPen import TransformPen
# pyrefly: ignore[missing-import]
from fontTools.ttLib import TTFont
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
LOGO = ROOT / "logo"
ICONS = ROOT / "icons"
FONTS = ROOT / "fonts"

VIOLET = "#6C5CE7"
CYAN = "#00C2D1"
INK = "#14162B"       # light-theme text
PAPER = "#E8EAF6"     # dark-theme text
DARK_BG = "#0F1020"


def fmt(v: float) -> str:
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


# --------------------------------------------------------------------------
# Mark geometry (64 x 64 grid).
#   Two "peers" - the stem and the foot of an L - separated by a thin
#   radial cut that points straight at a four-point spark (the light that
#   connects them).  The small optical variant drops the cut and enlarges
#   the spark so it survives 16-24 px.
# --------------------------------------------------------------------------
def spark(cx: float, cy: float, r: float, k: float = 0.16) -> str:
    a = r * k
    return (
        f"M{fmt(cx)} {fmt(cy - r)}"
        f"C{fmt(cx + a)} {fmt(cy - a)} {fmt(cx + a)} {fmt(cy - a)} {fmt(cx + r)} {fmt(cy)}"
        f"C{fmt(cx + a)} {fmt(cy + a)} {fmt(cx + a)} {fmt(cy + a)} {fmt(cx)} {fmt(cy + r)}"
        f"C{fmt(cx - a)} {fmt(cy + a)} {fmt(cx - a)} {fmt(cy + a)} {fmt(cx - r)} {fmt(cy)}"
        f"C{fmt(cx - a)} {fmt(cy - a)} {fmt(cx - a)} {fmt(cy - a)} {fmt(cx)} {fmt(cy - r)}Z"
    )


def mark_paths(small: bool = False) -> list[str]:
    # Centre-line: x = cx-R from y=top down to cy, quarter arc radius R,
    # then horizontal to x=right at y = cy+R.  Stroke width sw.
    if small:
        sw, top, right, cx, cy, R, gap, st, sr = 13.5, 10, 50.5, 30.5, 36.5, 15, 0, 10.5, 14
    else:
        sw, top, right, cx, cy, R, gap, st, sr = 12, 11, 49.5, 30.5, 37, 16, 3.6, 10, 12.5
    h = sw / 2
    ri, ro, x0 = R - h, R + h, cx - R
    yb = cy + R
    s2 = math.sqrt(2)
    sx, sy = cx + st / s2, cy - st / s2
    if gap <= 0:
        L = (
            f"M{fmt(x0 + h)} {fmt(top)}V{fmt(cy)}A{fmt(ri)} {fmt(ri)} 0 0 0 {fmt(cx)} {fmt(yb - h)}"
            f"H{fmt(right)}A{fmt(h)} {fmt(h)} 0 0 1 {fmt(right)} {fmt(yb + h)}H{fmt(cx)}"
            f"A{fmt(ro)} {fmt(ro)} 0 0 1 {fmt(x0 - h)} {fmt(cy)}V{fmt(top)}"
            f"A{fmt(h)} {fmt(h)} 0 0 1 {fmt(x0 + h)} {fmt(top)}Z"
        )
        return [L, spark(sx, sy, sr, 0.24)]
    n = (1 / s2, 1 / s2)
    d = (-1 / s2, 1 / s2)

    def cut(o: float, r: float):
        t = math.sqrt(r * r - o * o)
        return (cx + o * n[0] + t * d[0], cy + o * n[1] + t * d[1])

    a, b = cut(-gap / 2, ri), cut(-gap / 2, ro)
    stem = (
        f"M{fmt(x0 + h)} {fmt(top)}V{fmt(cy)}A{fmt(ri)} {fmt(ri)} 0 0 0 {fmt(a[0])} {fmt(a[1])}"
        f"L{fmt(b[0])} {fmt(b[1])}A{fmt(ro)} {fmt(ro)} 0 0 1 {fmt(x0 - h)} {fmt(cy)}V{fmt(top)}"
        f"A{fmt(h)} {fmt(h)} 0 0 1 {fmt(x0 + h)} {fmt(top)}Z"
    )
    c, e = cut(gap / 2, ri), cut(gap / 2, ro)
    foot = (
        f"M{fmt(c[0])} {fmt(c[1])}A{fmt(ri)} {fmt(ri)} 0 0 0 {fmt(cx)} {fmt(yb - h)}H{fmt(right)}"
        f"A{fmt(h)} {fmt(h)} 0 0 1 {fmt(right)} {fmt(yb + h)}H{fmt(cx)}"
        f"A{fmt(ro)} {fmt(ro)} 0 0 1 {fmt(e[0])} {fmt(e[1])}Z"
    )
    return [stem, foot, spark(sx, sy, sr)]


def grad_def(gid: str, x1, y1, x2, y2) -> str:
    return (
        f'<linearGradient id="{gid}" x1="{fmt(x1)}" y1="{fmt(y1)}" x2="{fmt(x2)}" y2="{fmt(y2)}" '
        f'gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="{VIOLET}"/>'
        f'<stop offset="1" stop-color="{CYAN}"/></linearGradient>'
    )


def mark_group(fill: str, x: float = 0, y: float = 0, scale: float = 1, small: bool = False) -> str:
    paths = "".join(f'<path d="{p}"/>' for p in mark_paths(small))
    tf = ""
    if x or y or scale != 1:
        tf = f' transform="translate({fmt(x)} {fmt(y)}) scale({fmt(scale)})"'
    return f'<g fill="{fill}"{tf}>{paths}</g>'


def svg(w, h, body, title="Lumora") -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {fmt(w)} {fmt(h)}" '
        f'width="{fmt(w)}" height="{fmt(h)}" role="img" aria-label="{title}">'
        f"<title>{title}</title>{body}</svg>\n"
    )


def mark_svg(kind: str = "gradient", small: bool = False) -> str:
    if kind == "gradient":
        return svg(64, 64, f"<defs>{grad_def('lm-g', 8, 6, 56, 58)}</defs>" + mark_group("url(#lm-g)", small=small))
    color = INK if kind == "on-light" else "#FFFFFF"
    return svg(64, 64, mark_group(color, small=small))


def app_icon_svg(size=1024, radius_ratio=0.2237, inset=0.0, small=False, shape="squircle", highlight=True) -> str:
    """Rounded-square (or circle) gradient tile with a white mark.

    inset: transparent padding ratio (macOS grid uses 100/1024).
    The mark is kept inside the central ~62% (safe zone)."""
    p = size * inset
    s = size - 2 * p
    r = s * radius_ratio
    if shape == "circle":
        tile = f'<circle cx="{fmt(size/2)}" cy="{fmt(size/2)}" r="{fmt(s/2)}" fill="url(#ai-g)"/>'
        clip = f'<circle cx="{fmt(size/2)}" cy="{fmt(size/2)}" r="{fmt(s/2)}"/>'
    else:
        tile = f'<rect x="{fmt(p)}" y="{fmt(p)}" width="{fmt(s)}" height="{fmt(s)}" rx="{fmt(r)}" fill="url(#ai-g)"/>'
        clip = f'<rect x="{fmt(p)}" y="{fmt(p)}" width="{fmt(s)}" height="{fmt(s)}" rx="{fmt(r)}"/>'
    mark_frac = 0.74 if small else 0.62
    ms = s * mark_frac / 64 * 64  # mark box edge in px
    sc = ms / 64
    mx = p + (s - ms) / 2
    defs = grad_def("ai-g", p, p, p + s, p + s)
    extra = ""
    if highlight and not small:
        defs += (
            f'<radialGradient id="ai-h" cx="{fmt(p + s*0.28)}" cy="{fmt(p + s*0.12)}" r="{fmt(s*0.85)}" '
            'gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#fff" stop-opacity=".16"/>'
            '<stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>'
            f'<clipPath id="ai-c">{clip}</clipPath>'
        )
        extra = f'<g clip-path="url(#ai-c)"><rect x="{fmt(p)}" y="{fmt(p)}" width="{fmt(s)}" height="{fmt(s)}" fill="url(#ai-h)"/></g>'
    return svg(size, size, f"<defs>{defs}</defs>{tile}{extra}" + mark_group("#FFFFFF", mx, mx, sc, small=small))


def adaptive_foreground_svg(mono_color="#FFFFFF") -> str:
    # 108dp canvas, 66dp safe circle centred.  Mark box 54dp -> its glyph
    # bounding box (47x54 of 64 units -> ~40x46dp, diagonal ~61dp) sits
    # inside the 66dp safe zone.
    ms = 54
    sc = ms / 64
    o = (108 - ms) / 2
    return svg(108, 108, mark_group(mono_color, o, o, sc), "Lumora adaptive icon foreground")


def adaptive_background_svg() -> str:
    return svg(108, 108, f"<defs>{grad_def('ab-g', 0, 0, 108, 108)}</defs><rect width=\"108\" height=\"108\" fill=\"url(#ab-g)\"/>",
               "Lumora adaptive icon background")


# --------------------------------------------------------------------------
# Wordmark: "Lumora" set in Be Vietnam Pro SemiBold, converted to paths.
# --------------------------------------------------------------------------
def text_paths(text: str, font_path: Path, size: float, tracking: float = -0.02):
    font = TTFont(str(font_path))
    upm = font["head"].unitsPerEm
    cmap = font.getBestCmap()
    gs = font.getGlyphSet()
    hmtx = font["hmtx"]
    scale = size / upm
    x = 0.0
    out = []
    for ch in text:
        gname = cmap[ord(ch)]
        pen = SVGPathPen(gs, ntos=lambda v: fmt(v))
        tpen = TransformPen(pen, (scale, 0, 0, -scale, x, 0))
        gs[gname].draw(tpen)
        out.append(pen.getCommands())
        x += hmtx[gname][0] * scale + tracking * size
    width = x - tracking * size
    cap = font["OS/2"].sCapHeight * scale
    return " ".join(out), width, cap


def wordmark_svg(color: str) -> tuple[str, float, float]:
    d, w, cap = text_paths("Lumora", FONTS / "BeVietnamPro-SemiBold.ttf", 100, -0.025)
    pad = 2
    H = 100 * 1.0  # baseline at cap + pad
    body = f'<path fill="{color}" transform="translate({pad} {fmt(cap + pad)})" d="{d}"/>'
    return svg(w + 2 * pad, cap + 2 * pad + 2, body), w, cap


def lockup_svg(text_color: str, mark_kind: str = "gradient") -> str:
    # Mark height M; cap height = 0.5 M; gap = 0.30 M.
    M = 64
    d, w, cap = text_paths("Lumora", FONTS / "BeVietnamPro-SemiBold.ttf", 100, -0.025)
    target_cap = M * 0.52
    k = target_cap / cap
    # glyph ends at x=55.5 inside the 64 box; gap = 0.2 M from the glyph
    tx = 55.5 + M * 0.2
    # mark glyph spans y 5..59 within its 64 box -> optical centre 32
    baseline = 32 + target_cap / 2
    W = tx + w * k + 2
    if mark_kind == "gradient":
        defs = f"<defs>{grad_def('lk-g', 8, 6, 56, 58)}</defs>"
        mg = mark_group("url(#lk-g)")
    else:
        defs = ""
        mg = mark_group(text_color)
    body = defs + mg + f'<path fill="{text_color}" transform="translate({fmt(tx)} {fmt(baseline)}) scale({k:.4f})" d="{d}"/>'
    # trim the mark's left side-bearing so the lockup aligns flush-left
    return svg(W - 6.5, 64, f'<g transform="translate(-6.5 0)">{body}</g>')


# --------------------------------------------------------------------------
def render(svg_text: str, size: int, out: Path | None = None, bg=None) -> Image.Image:
    png = cairosvg.svg2png(bytestring=svg_text.encode(), output_width=size, output_height=size)
    im = Image.open(io.BytesIO(png)).convert("RGBA")
    if bg:
        base = Image.new("RGBA", im.size, bg)
        base.alpha_composite(im)
        im = base
    if out:
        out.parent.mkdir(parents=True, exist_ok=True)
        im.save(out, optimize=True)
    return im


def write(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main():
    # ---- SVG logos ----
    write(LOGO / "lumora-mark.svg", mark_svg("gradient"))
    write(LOGO / "lumora-mark-small.svg", mark_svg("gradient", small=True))
    write(LOGO / "lumora-mark-mono-dark.svg", mark_svg("on-light"))   # dark ink, for light backgrounds
    write(LOGO / "lumora-mark-mono-light.svg", mark_svg("on-dark"))   # white, for dark backgrounds
    app = app_icon_svg()
    app_small = app_icon_svg(small=True)
    write(LOGO / "lumora-app-icon.svg", app)
    write(LOGO / "lumora-app-icon-small.svg", app_small)
    write(LOGO / "lumora-app-icon-macos.svg", app_icon_svg(inset=100 / 1024, radius_ratio=0.2237))
    write(LOGO / "lumora-app-icon-foreground.svg", adaptive_foreground_svg())
    write(LOGO / "lumora-app-icon-background.svg", adaptive_background_svg())
    write(LOGO / "lumora-app-icon-monochrome.svg", adaptive_foreground_svg("#000000"))
    wm_light, _, _ = wordmark_svg(INK)
    wm_dark, _, _ = wordmark_svg(PAPER)
    write(LOGO / "lumora-wordmark.svg", wm_light)
    write(LOGO / "lumora-wordmark-light.svg", wm_light)
    write(LOGO / "lumora-wordmark-dark.svg", wm_dark)
    write(LOGO / "lumora-lockup-horizontal.svg", lockup_svg(INK))
    write(LOGO / "lumora-lockup-horizontal-light.svg", lockup_svg(INK))
    write(LOGO / "lumora-lockup-horizontal-dark.svg", lockup_svg(PAPER))
    write(LOGO / "lumora-lockup-horizontal-mono-dark.svg", lockup_svg(INK, "mono"))
    write(LOGO / "lumora-lockup-horizontal-mono-light.svg", lockup_svg("#FFFFFF", "mono"))

    def icon(size: int) -> Image.Image:
        return render(app_small if size <= 32 else app, size)

    # ---- generic PNG set ----
    if ICONS.exists():
        shutil.rmtree(ICONS)
    for s in (16, 24, 32, 48, 64, 128, 256, 512, 1024):
        (ICONS / "png").mkdir(parents=True, exist_ok=True)
        icon(s).save(ICONS / "png" / f"lumora-{s}.png", optimize=True)
    for s in (64, 128, 256, 512, 1024):
        render(mark_svg("gradient"), s, ICONS / "png" / f"lumora-mark-{s}.png")

    # ---- Windows .ico ----
    win = ICONS / "windows"
    win.mkdir(parents=True, exist_ok=True)
    big = icon(256)
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    frames = [icon(s) for s in sizes]
    frames[-1].save(win / "lumora.ico", format="ICO", sizes=[(s, s) for s in sizes], append_images=frames[:-1])
    for s in (44, 150):  # MSIX / Store tiles
        icon(s).save(win / f"Square{s}x{s}Logo.png", optimize=True)

    # ---- macOS .icns (Apple grid: 824px tile in a 1024 canvas) ----
    mac = ICONS / "macos"
    mac.mkdir(parents=True, exist_ok=True)
    mac_svg = app_icon_svg(inset=100 / 1024)
    iconset = mac / "lumora.iconset"
    iconset.mkdir(exist_ok=True)
    for s in (16, 32, 128, 256, 512):
        render(mac_svg, s, iconset / f"icon_{s}x{s}.png")
        render(mac_svg, s * 2, iconset / f"icon_{s}x{s}@2x.png")
    render(mac_svg, 1024).save(mac / "lumora.icns", format="ICNS",
                               append_images=[render(mac_svg, s) for s in (16, 32, 64, 128, 256, 512)])

    # ---- Android ----
    andr = ICONS / "android"
    dens = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    circle_svg = app_icon_svg(shape="circle")
    fg, bgsvg, mono = adaptive_foreground_svg(), adaptive_background_svg(), adaptive_foreground_svg("#000000")
    for name, k in dens.items():
        dirp = andr / f"mipmap-{name}"
        s = int(48 * k)
        # legacy icons: 48dp with ~1dp padding per Material guidance
        pad_svg = app_icon_svg(inset=2 / 48, radius_ratio=0.2237)
        render(pad_svg, s, dirp / "ic_launcher.png")
        render(app_icon_svg(shape="circle", inset=2 / 48), s, dirp / "ic_launcher_round.png")
        a = int(108 * k)
        render(fg, a, dirp / "ic_launcher_foreground.png")
        render(bgsvg, a, dirp / "ic_launcher_background.png")
        render(mono, a, dirp / "ic_launcher_monochrome.png")
    anydpi = andr / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
           '    <background android:drawable="@mipmap/ic_launcher_background"/>\n'
           '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
           '    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>\n'
           '</adaptive-icon>\n')
    (anydpi / "ic_launcher.xml").write_text(xml)
    (anydpi / "ic_launcher_round.xml").write_text(xml)
    render(app, 512, andr / "playstore-icon-512.png")

    # ---- Linux hicolor ----
    lin = ICONS / "linux" / "hicolor"
    for s in (16, 22, 24, 32, 48, 64, 128, 256, 512):
        d = lin / f"{s}x{s}" / "apps"
        d.mkdir(parents=True, exist_ok=True)
        icon(s).save(d / "lumora.png", optimize=True)
    sc = lin / "scalable" / "apps"
    sc.mkdir(parents=True, exist_ok=True)
    (sc / "lumora.svg").write_text(app)

    # ---- Web ----
    web = ICONS / "web"
    web.mkdir(parents=True, exist_ok=True)
    fav = [icon(s) for s in (16, 32, 48)]
    fav[-1].save(web / "favicon.ico", format="ICO", sizes=[(16, 16), (32, 32), (48, 48)], append_images=fav[:-1])
    (web / "favicon.svg").write_text(app_small)
    # apple-touch-icon: opaque full-bleed square, iOS applies its own mask
    render(app_icon_svg(radius_ratio=0, highlight=True), 180, web / "apple-touch-icon.png")
    for s in (192, 512):
        render(app, s, web / f"icon-{s}.png")
        render(app_icon_svg(radius_ratio=0, inset=0), s, web / f"icon-maskable-{s}.png")
    print("done")


if __name__ == "__main__":
    main()
