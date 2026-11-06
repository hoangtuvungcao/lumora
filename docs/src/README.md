# Lumora

Lumora is a serverless, end-to-end encrypted communication app for **Windows, macOS, Linux, Android and iOS**
(iOS coming soon): chat (1-1, groups, communities with channels), voice/video calls, unlimited file transfer and
remote desktop support — with no accounts and no central server.

| Folder | What |
|---|---|
| `core/` | Rust workspace: `lumora-core` (identity, crypto, storage, transport, protocol), `lumora-media` (capture, codecs, input, audio), `lumora-ffi` (C ABI for the app), `lumora-cli` (`lumorad` headless node), `lumora-relay` (optional self-hosted relay, not shipped in releases) |
| `app/` | Flutter client (Windows, macOS, Linux, Android, iOS) |
| `landing/` | Static homepage + downloads (Cloudflare Pages / any static host) |
| `relay/` | Optional self-hosted relay deployment (VPS Docker, Cloudflare Worker); not part of the official builds |
| `branding/` | Logo, icons, brand guideline, design tokens |
| `docs/` | This book (`mdbook serve docs`) |

Updating docs: every page is plain Markdown under `docs/src/`; add a page and list it in `SUMMARY.md`.
