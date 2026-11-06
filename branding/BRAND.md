# Lumora — Brand Guidelines

> **Lumora** = *lumen* (ánh sáng) + *aura* — "ánh sáng kết nối".
> **VI:** Kết nối trực tiếp. Riêng tư tuyệt đối.
> **EN:** Direct. Private. Yours.

Lumora is a serverless, peer-to-peer app for end-to-end encrypted chat, calls, file transfer and remote desktop. The brand should feel **calm, trustworthy and technically confident**: no hype, no fear-mongering, no lock icons everywhere.

Machine-readable values live in [`tokens.json`](tokens.json). This document explains how to use them. Every asset can be regenerated with `python3 branding/tools/build_brand.py` (needs `cairosvg fonttools pillow`).

---

## 1. Logo

### 1.1 The mark

The mark is an **"L" split into two peers**: the stem and the foot are separate shapes, divided by a thin diagonal cut. The cut points straight at a **four-point spark**, which stands for the light that connects them. Two devices, one direct line, nothing in between.

| File | Use |
|---|---|
| `logo/lumora-mark.svg` | Default mark, gradient, transparent background |
| `logo/lumora-mark-small.svg` | Optical variant for ≤ 32 px (no cut, heavier spark) |
| `logo/lumora-mark-mono-dark.svg` | Single colour `#14162B` for light backgrounds, print, engraving |
| `logo/lumora-mark-mono-light.svg` | White, for dark or photographic backgrounds |
| `logo/lumora-app-icon.svg` | App icon, full-bleed gradient tile, 1024 grid |
| `logo/lumora-app-icon-small.svg` | App icon optical variant for 16–32 px (favicon, tray) |
| `logo/lumora-app-icon-macos.svg` | macOS icon on Apple's grid (824 px tile + 100 px margin) |
| `logo/lumora-app-icon-foreground.svg` / `-background.svg` / `-monochrome.svg` | Android adaptive icon layers (108 dp, mark inside the 66 dp safe zone) |
| `logo/lumora-wordmark(-light/-dark).svg` | "Lumora" set in Be Vietnam Pro SemiBold, outlined to paths |
| `logo/lumora-lockup-horizontal(-light/-dark/-mono-*).svg` | Mark + wordmark |

"-light" means *for light backgrounds* (dark ink). "-dark" means *for dark backgrounds* (light ink).

### 1.2 Construction

- Grid: 64 × 64. Stroke 12, centre-line radius 16, round caps. Cut width 3.6, at 45°.
- Spark: four-point star, radius 12.5. Its centre sits on the cut's axis.
- The glyph's optical centre is (32, 32). Bounding box ≈ 47 × 54.
- Gradient: 135°, `#6C5CE7` → `#00C2D1`, from the top-left to the bottom-right of the glyph.
- App icon: the mark takes up 62 % of the tile edge (74 % in the small optical variant). Corner radius is 22.4 % of the edge.

### 1.3 Clear space and minimum size

- **Clear space:** keep at least **0.25 × the mark height** empty on every side. For the lockup, measure from the mark height.
- **Minimum size:** mark **16 px** (use `-small` below 32 px). Lockup **96 px** wide on screen, **24 mm** in print.
- In the lockup, the wordmark's cap height is 52 % of the mark height and the gap is 0.2 × the mark height. Do not rebuild the lockup by hand. Use the files.

### 1.4 Don't

- ✗ Recolour the gradient, reverse it, or use colours outside the palette.
- ✗ Stretch, skew, rotate or add outlines, bevels or drop shadows to the mark.
- ✗ Close the cut, or move the spark off the diagonal.
- ✗ Put the gradient mark on busy photos or on violet/cyan backgrounds. Use the mono version instead.
- ✗ Set "Lumora" in another typeface, or in all caps, as a logo.
- ✗ Put the mark inside another container shape (a circle or a shield). The only container is the app-icon tile.

---

## 2. Colour

| Token | Hex | RGB | Use |
|---|---|---|---|
| **Lumora Violet** | `#6C5CE7` | 108, 92, 231 | Primary actions, focus, brand |
| Violet 600 | `#5A4BD6` | 90, 75, 214 | Hover/pressed, links on light |
| Violet 300 | `#A29BFE` | 162, 155, 254 | Primary as text/icons on dark |
| **Aurora Cyan** | `#00C2D1` | 0, 194, 209 | Accent, highlights, online state |
| Cyan 700 | `#0E7C86` | 14, 124, 134 | Accent as text on light |
| Gradient | 135°, `#6C5CE7 → #00C2D1` | | Logo, hero accents, illustrations |
| Success | `#22C55E` | 34, 197, 94 | Connected, verified |
| Warning | `#F59E0B` | 245, 158, 11 | Relayed connection, attention |
| Danger | `#EF4444` | 239, 68, 68 | Destructive, key mismatch |

| Role | Light | Dark |
|---|---|---|
| Background | `#F7F8FC` | `#0F1020` |
| Surface | `#FFFFFF` | `#171A2E` |
| Surface 2 | `#EEF0F8` | `#1F2340` |
| Border | `#E1E4F0` | `#2A2F52` |
| Text | `#14162B` | `#E8EAF6` |
| Muted text | `#5B607D` | `#9AA0C3` |

**Accessibility (WCAG 2.1 AA). Ratios checked:**
- White on Violet `#6C5CE7`: 4.86:1. OK for buttons (use 600 on hover: 6.15:1).
- Violet on light bg: 4.58:1 (OK). Violet on dark bg is only 3.88:1, so **use Violet 300** for text on dark.
- Cyan on light bg is 2.18:1, so **never use cyan as text on light**. Use Cyan 700. Cyan on dark is 8.6:1 (OK).
- Gradient fills that carry white text fail at the cyan end. Use the gradient behind white **only for large display text or the logo**, and make primary buttons solid violet.
- Muted text: 5.8:1 (light) and 7.3:1 (dark).

Suggested ratio: ~70 % neutrals, 20 % violet, 10 % cyan/gradient.

**Marketing-only accents** (website, not app UI): warm ivory `#FBF8F4` as the light page background, Champagne `#E8C27A` used sparingly for "Miễn phí trọn đời" badges (on light use text `#7A5612`), and soft pink `#F472B6` only inside aurora gradients and gradient headlines.

**Marketing copy rule:** public pages speak to ordinary people (parents, students, small shops). Avoid jargon such as P2P, NAT, end-to-end, SHA-256, architecture names, Wayland or server talk. Say *"chỉ bạn và người nhận đọc được"*, not *"mã hóa đầu-cuối"*. Technical details belong only in the download page's collapsed "Technical details" section. Never describe network internals publicly.

---

## 3. Typography

**Be Vietnam Pro** (SIL OFL 1.1, `fonts/`). It was designed for Vietnamese, so stacked diacritics (ễ, ổ, ự) stay legible and keep their rhythm. Weights: 400 Regular, 500 Medium, 600 SemiBold, 700 Bold.
Fallback: `system-ui, -apple-system, "Segoe UI", Roboto, "Noto Sans", sans-serif`.

| Style | Size / line | Weight | Tracking |
|---|---|---|---|
| Display | 56 / 64 | 700 | −1.2 px |
| H1 | 40 / 48 | 700 | −0.8 px |
| H2 | 32 / 40 | 700 | −0.5 px |
| H3 | 24 / 32 | 600 | −0.2 px |
| Title | 18 / 26 | 600 | 0 |
| Body L | 18 / 28 | 400 | 0 |
| Body | 16 / 24 | 400 | 0 |
| Body S | 14 / 20 | 400 | 0 |
| Caption | 12 / 16 | 500 | +0.2 px |
| Overline | 12 / 16 | 600, uppercase | +1.2 px |

Rules: use sentence case for headings. Vietnamese needs generous line-height, so never set it below 1.2 for display text or 1.45 for body text. Monospace is for fingerprints, safety numbers and IDs only.

## 4. Layout and UI

- **Spacing:** 4-pt scale (4, 8, 12, 16, 20, 24, 32, 40, 48, 64, 80, 96).
- **Radii:** 8 (inputs, chips), 12 (buttons, list items), 16 (cards), 24 (sheets, hero panels), full (avatars, pills).
- **Motion:** 120 ms (hover/press), 200 ms (menus, toasts), 320 ms (dialogs, pages). Easing is standard `cubic-bezier(.2,0,0,1)`. Respect reduced-motion.
- **Icons:** line icons on a 24 px grid, **1.75 px stroke**, round caps and joins, `currentColor`. Use filled icons only for active or selected states.
- **Shadows:** keep them subtle in light mode. In dark mode, show elevation with surface colour rather than shadow.

## 5. Voice and tone

We are **the knowledgeable friend**, not the security lecturer. Be clear, warm and concrete.

| Do | Don't |
|---|---|
| Use short sentences and explain the benefit first. | Use jargon walls ("X25519 + XChaCha20…" in a headline). |
| Be honest about limits ("Đôi khi cần relay; relay không đọc được dữ liệu"). | Make absolute claims ("không thể bị hack"). |
| Say "bạn" (VI) and "you" (EN). | Say "quý khách" or "người dùng" when speaking to the reader. |
| Use technical detail in a second layer (FAQ, docs). | Use fear-based marketing. |

**Vietnamese:** natural and modern, not a word-for-word translation. Write "Tải về", not "Tải xuống ngay bây giờ!!!". Write full diacritics, always. Product terms: *mã hóa đầu-cuối*, *ngang hàng (P2P)*, *điều khiển từ xa*, *máy chủ chuyển tiếp (relay)*.

**English:** plain, confident and lowercase-friendly. "Direct. Private. Yours."

Examples:
- VI: "Tin nhắn đi thẳng từ máy bạn đến máy người nhận. Không ai ở giữa."
- EN: "Your messages go straight from your device to theirs. No one in between."

## 6. Asset inventory (rasters)

`icons/` is generated:
- `png/lumora-{16…1024}.png` (app icon) and `png/lumora-mark-{64…1024}.png`
- `windows/lumora.ico` (16, 20, 24, 32, 40, 48, 64, 128 and 256 px, PNG-compressed), plus `Square44x44Logo.png` and `Square150x150Logo.png`
- `macos/lumora.icns` and `macos/lumora.iconset/` (to rebuild on a Mac: `iconutil -c icns lumora.iconset`)
- `android/mipmap-{mdpi…xxxhdpi}/ic_launcher(.png, _round, _foreground, _background, _monochrome)`, `mipmap-anydpi-v26/*.xml`, `playstore-icon-512.png`
- `linux/hicolor/{16…512}/apps/lumora.png` and `scalable/apps/lumora.svg`. Install to `/usr/share/icons/hicolor/`.
- `web/favicon.ico`, `favicon.svg`, `apple-touch-icon.png` (180), `icon-192/512.png`, `icon-maskable-192/512.png`
