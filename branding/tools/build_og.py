#!/usr/bin/env python3
"""Render the 1200x630 Open Graph image (SVG + PNG) for the landing page.

Text is outlined with fontTools so the output does not depend on installed fonts.
Usage: python3 branding/tools/build_og.py
"""
import sys
from pathlib import Path

import cairosvg

sys.path.insert(0, str(Path(__file__).parent))
from build_brand import FONTS, app_icon_svg, fmt, grad_def, mark_group, text_paths  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "landing" / "assets" / "img"


def text(s, weight, size, x, y, color, tracking=-0.02):
    d, w, _ = text_paths(s, FONTS / f"BeVietnamPro-{weight}.ttf", size, tracking)
    return f'<path fill="{color}" transform="translate({fmt(x)} {fmt(y)})" d="{d}"/>', w


def chip(label, x, y):
    t, w = text(label, "Medium", 22, 0, 0, "#E8EAF6", 0)
    pw = w + 40
    return (f'<g transform="translate({fmt(x)} {fmt(y)})"><rect width="{fmt(pw)}" height="48" rx="24" '
            f'fill="#1F2340" stroke="#2A2F52"/><g transform="translate(20 31)">{t}</g></g>'), pw


def main():
    W, H = 1200, 630
    icon = app_icon_svg(size=1024)
    inner = icon[icon.index(">", icon.index("<svg")) + 1: icon.rindex("</svg>")]
    inner = inner.replace("<title>Lumora</title>", "")
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">',
        '<defs><radialGradient id="g1" cx="0.85" cy="0.1" r="0.7"><stop offset="0" stop-color="#00C2D1" stop-opacity=".28"/>'
        '<stop offset="1" stop-color="#00C2D1" stop-opacity="0"/></radialGradient>'
        '<radialGradient id="g2" cx="0.1" cy="0.95" r="0.7"><stop offset="0" stop-color="#6C5CE7" stop-opacity=".38"/>'
        '<stop offset="1" stop-color="#6C5CE7" stop-opacity="0"/></radialGradient>'
        '<linearGradient id="tg" x1="0" x2="1"><stop offset="0" stop-color="#A29BFE"/><stop offset="1" stop-color="#00C2D1"/></linearGradient>'
        '<pattern id="dots" width="28" height="28" patternUnits="userSpaceOnUse"><circle cx="2" cy="2" r="1.2" fill="#fff" fill-opacity=".05"/></pattern></defs>',
        f'<rect width="{W}" height="{H}" fill="#0F1020"/><rect width="{W}" height="{H}" fill="url(#dots)"/>',
        f'<rect width="{W}" height="{H}" fill="url(#g1)"/><rect width="{W}" height="{H}" fill="url(#g2)"/>',
        f'<g transform="translate(80 84) scale({112/1024:.5f})">{inner}</g>',
    ]
    parts.append(f'<defs>{grad_def("og-m", 8, 6, 56, 58)}</defs><g opacity=".9">' + mark_group("url(#og-m)", 800, 70, 6.2) + '</g>')
    t, _ = text("Lumora", "Bold", 64, 216, 162, "#E8EAF6", -0.02)
    parts.append(t)
    t, _ = text("Kết nối trực tiếp.", "Bold", 76, 80, 330, "#E8EAF6", -0.03)
    parts.append(t)
    t, _ = text("Riêng tư theo cách của bạn.", "Bold", 54, 80, 404, "url(#tg)", -0.03)
    parts.append(t)
    t, _ = text("Direct. Private. Yours.", "Medium", 28, 80, 482, "#9AA0C3", 0)
    parts.append(t)
    x = 80
    for lab in ("Nhắn tin & nhóm", "Gọi video", "Hỗ trợ từ xa", "Gửi file lớn", "Miễn phí trọn đời"):
        c, w = chip(lab, x, 528)
        parts.append(c)
        x += w + 12
    parts.append("</svg>")
    svg = "".join(parts)
    # gradient fill for the text path uses objectBoundingBox -> fine per path
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    (OUT_DIR / "og-image.svg").write_text(svg, encoding="utf-8")
    cairosvg.svg2png(bytestring=svg.encode(), write_to=str(OUT_DIR / "og-image.png"), output_width=W, output_height=H)
    print("og done")


if __name__ == "__main__":
    main()
