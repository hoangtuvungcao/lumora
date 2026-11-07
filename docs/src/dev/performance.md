# Performance & resource budget

Goal: an always-on messaging app that stays light for months of uptime.

| Area | Budget / technique |
|---|---|
| Idle CPU | event-driven tokio; no polling loops faster than 10 s (QUIC keep-alive 10 s, info refresh 60 s, reconnect sweep 120 s) |
| Memory (core) | SQLite page cache capped at 8 MB; prepared-statement cache 64; event channel 4096; file I/O streamed in 256 KB chunks (constant RAM for any file size); only the latest decoded video frame per stream is kept |
| Disk | WAL checkpoint+truncate and incremental vacuum every 10 min; journal size limit 8 MB; mailbox capped (2000 items × 64 KB / peer, 14 days); outbox 30 days; retention windows per chat |
| Network | BBR congestion control (better on Wi-Fi/4G), 32 MB windows for fast file transfer, file streams at lower priority than chat; per-frame video streams so stale frames are dropped instead of queued |
| Latency | direct paths preferred; relayed peers re-tried for direct every 30 s; delivery measured at ~1 ms on LAN in e2e tests |
| Large downloads | resumable from the partial file, verified with BLAKE3, free-space check before accepting, auto-accept only ≤ 25 MB from friends |
| UI (Flutter) | virtualised lists, images decoded at display size, image cache capped, video repaint boundaries, rendering paused when hidden |
