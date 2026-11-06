"""Build landing/assets/img/icons.svg from Phosphor Icons (MIT, https://phosphoricons.com).

The site keeps its own short ids (chat, shield, os-windows...) and this table maps each one to a
Phosphor icon and weight. Only the icons listed here end up in the sprite.

    npm pack @phosphor-icons/core          # into any empty folder, then untar it
    python3 branding/tools/build_icons.py <path to the unpacked package/assets>

How the sprite works
--------------------
Every "duo" symbol carries two layers:
  * the Phosphor duotone fill layer, written without fill attributes, so it inherits `fill` and
    `fill-opacity` from the page. styles.css sets `.ic{fill:currentColor;fill-opacity:var(--duo,0)}`:
    small UI icons get the plain regular weight, and containers that set `--duo:.2` (feature tiles,
    trust strip, badges...) get the duotone look in the same accent colour;
  * the regular outline in a <g fill="currentColor" fill-opacity="1">, which always shows.
"bold" and "fill" symbols have the outline layer only. All viewBoxes are 0 0 256 256.
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "landing" / "assets" / "img" / "icons.svg"

# site id: (phosphor name, weight)
ICONS = {
    # navigation and buttons
    "globe": ("globe-simple", "duo"), "sun": ("sun", "duo"), "moon": ("moon", "duo"), "menu": ("list", "bold"),
    "download": ("download-simple", "bold"), "arrow-right": ("arrow-right", "bold"), "check": ("check", "bold"),
    "copy": ("copy", "duo"), "sparkles": ("sparkle", "duo"),
    # platforms (filled brand marks)
    "os-windows": ("windows-logo", "fill"), "os-apple": ("apple-logo", "fill"),
    "os-linux": ("linux-logo", "fill"), "os-android": ("android-logo", "fill"),
    # features
    "headset": ("headset", "duo"), "chat": ("chat-circle-dots", "duo"), "video": ("video-camera", "duo"),
    "file": ("file-arrow-up", "duo"), "shield": ("shield-check", "duo"), "user-off": ("user-circle-dashed", "duo"),
    "sticker": ("smiley-sticker", "duo"), "at": ("at", "duo"), "bot": ("robot", "duo"), "trash": ("trash", "duo"),
    "megaphone": ("megaphone", "duo"), "story": ("clock-countdown", "duo"), "pin": ("map-pin", "duo"),
    "mic": ("microphone", "duo"), "users": ("users-three", "duo"), "hdd": ("hard-drives", "duo"), "gift": ("gift", "duo"),
    "eye-off": ("eye-slash", "duo"), "devices": ("devices", "duo"),
    "home": ("house-line", "duo"), "book": ("graduation-cap", "duo"), "store": ("storefront", "duo"),
    "gamepad": ("game-controller", "duo"),
    # developers
    "code": ("code", "duo"), "terminal": ("terminal-window", "duo"), "book-open": ("book-open-text", "duo"),
    "cpu": ("cpu", "duo"), "key-off": ("lock-key", "duo"),
    # app mock (same names the app uses)
    "friends": ("users", "duo"), "plus": ("plus", "bold"), "compass": ("compass", "duo"), "monitor": ("monitor", "duo"),
    "transfer": ("arrows-down-up", "duo"), "settings": ("gear-six", "duo"), "bars": ("chart-bar", "duo"),
    "filter-lines": ("funnel-simple", "duo"), "search": ("magnifying-glass", "duo"), "bell": ("bell", "duo"),
    "edit": ("note-pencil", "duo"), "verified": ("seal-check", "fill"), "pushpin": ("push-pin", "duo"),
    "archive": ("archive", "duo"), "bookmark": ("bookmark-simple", "duo"), "lock": ("lock-simple", "duo"),
    "phone": ("phone", "duo"), "more-v": ("dots-three-vertical", "bold"), "info": ("info", "duo"),
    "sheet": ("table", "duo"), "download-tray": ("tray-arrow-down", "duo"), "checks": ("checks", "bold"),
    "timer": ("timer", "duo"), "smile": ("smiley", "duo"), "chats2": ("chats-circle", "duo"),
}

# Optical nudges in grid units (256 = icon size), measured with getBBox and checked by eye on a
# crosshair sheet. Phosphor centres most glyphs already; these few sit visibly off-centre in a tile.
# Glyphs with a light part on one side (antenna, shackle, lid, leaf) are moved only part of the way.
NUDGE = {
    "book-open": (0, -16), "shield": (0, -8), "check": (-4, -8), "megaphone": (-8, 0), "bot": (0, 8),
    "gift": (0, 8), "os-linux": (0, 8), "os-apple": (6, 8), "os-windows": (8, 0), "os-android": (0, 6),
    "monitor": (0, -8), "headset": (0, -8), "users": (0, -8), "book": (0, -6), "video": (-6, 0),
    "filter-lines": (0, -8), "trash": (0, 6), "timer": (0, 6), "pushpin": (-6, 6), "download": (0, 8),
    "lock": (0, 6), "key-off": (0, 6),
}

PATH = re.compile(r'<path d="([^"]+)"( opacity="0\.2")?/>')


def paths(file):
    svg = file.read_text(encoding="utf-8")
    assert 'viewBox="0 0 256 256"' in svg, file
    found = PATH.findall(svg)
    # every drawing element must be a plain <path d>; anything else would be dropped silently
    assert len(found) == svg.count("<path") and not re.search(r"<(circle|rect|line|polyline|polygon|ellipse)\b", svg), file
    return found


def symbol(sid, name, weight):
    if weight == "duo":
        found = paths(ASSETS / "duotone" / f"{name}-duotone.svg")
        duo = "".join(f'<path d="{d}"/>' for d, o in found if o)
        main = "".join(f'<path d="{d}"/>' for d, o in found if not o)
    else:
        sub = {"bold": "bold", "fill": "fill"}[weight]
        found = paths(ASSETS / sub / f"{name}-{sub}.svg")
        duo, main = "", "".join(f'<path d="{d}"/>' for d, _ in found)
    inner = f'{duo}<g fill="currentColor" fill-opacity="1">{main}</g>'
    if sid in NUDGE:
        inner = '<g transform="translate({} {})">{}</g>'.format(*NUDGE[sid], inner)
    return f'<symbol id="{sid}" viewBox="0 0 256 256">{inner}</symbol>'


if __name__ == "__main__":
    ASSETS = Path(sys.argv[1])
    body = "\n".join(symbol(sid, *v) for sid, v in ICONS.items())
    OUT.write_text(
        '<svg xmlns="http://www.w3.org/2000/svg">\n'
        "<!-- Icons: Phosphor Icons 2.1 (regular, duotone, bold, fill), MIT License,\n"
        "     Copyright (c) 2023 Phosphor Icons, https://github.com/phosphor-icons/core\n"
        "     Built by branding/tools/build_icons.py: 0 0 256 256 grid, currentColor.\n"
        "     Duotone layer = the first path(s) without attributes: it inherits fill and\n"
        "     fill-opacity from the page (see .ic in styles.css), so one symbol serves both the\n"
        "     regular and the duotone look. -->\n"
        f"{body}\n</svg>\n",
        encoding="utf-8",
    )
    ET.parse(OUT)  # a malformed sprite silently blanks every icon on the site
    print(f"{OUT}: {len(ICONS)} icons, {OUT.stat().st_size} bytes")
