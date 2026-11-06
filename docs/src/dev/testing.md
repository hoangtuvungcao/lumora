# Testing

| Suite | Command | Covers |
|---|---|---|
| Core unit tests | `cargo test -p lumora-core` | crypto seal/open, keystore, SQLCipher (no plaintext on disk), STUN codec, HLC, group op-log convergence & permissions, protocol fuzz, i18n |
| Relay | `cargo test -p lumora-relay` | forwarding, mailbox, auth, replay, rate limits, STUN |
| Media | `cargo test -p lumora-media` | colour conversion, VP8/VP9 round-trip PSNR + format switch, codec negotiation matrix, probe cache, first-frame latency, key mapping, jitter buffer |
| Media, dev H.264 | `cargo test -p lumora-media --features openh264-source --lib -- codec video` | H.264 path (source-built OpenH264, **dev/test only**) and the H.264 → VP8 switch on the same frame |
| Video calls E2E | `python3 core/tests/video_e2e.py --h264-bin <lumorad built with --features lumora-core/openh264-source>` | synthetic camera (`LUMORA_TEST_CAMERA=1`): VP8 call, answer → first decoded frame (< 1.5 s on CI), H.264 + forced failure → VP8 switch gap (the older-peer steps run only with `--legacy <binary>`; no legacy binary is kept since 2026-11-06) |
| End-to-end | `python3 core/tests/e2e.py` | 3 real nodes: discovery, friends, chat + receipts, edit/react/delete, 12 MB file, groups + key rotation, offline queue, encryption at rest |
| E2E over relay | `python3 core/tests/e2e.py --relay ws://127.0.0.1:8443/ws --relay-only` | forces the relay path |
| Multi-device E2E | `python3 core/tests/multidevice_e2e.py` | one account on up to 4 devices + a friend with 2 devices: link by QR / by code (wrong codes, rotation), fan-out, self-sync (sent messages, read state, pins, profile), offline catch-up, history window + resumable transfer + file from the other device, groups with multi-device members (one rotation per removal), remote-control password v2 |
| IP privacy E2E | `python3 core/tests/ip_privacy_e2e.py --bin <debug lumorad> --relay-bin <lumora-relay>` | strangers never learn your IP: a stranger's offer gets no addresses and no packet (a UDP listener stands in for the stranger's advertised address via `LUMORA_TEST_EXTRA_ADDRS`, debug builds only), no contact row, relay-only path; friend request still arrives (also by mail while offline), direct only after accepting; remote-control probing with a wrong password reveals nothing; LAN announcements carry no public key |
| NAT lab | `sudo python3 nat-lab/run.py --mode all` (CI: `--quick`) | 43 cases × up to 4 modes in network namespaces: full/address/port-restricted cone, sequential + random symmetric, double NAT / CGNAT, same NAT ± hairpin, LAN discovery, IPv6 firewalls, UDP blocked, loss/latency/bandwidth, NAT timeout + rebinding, friend peer relay — path, connect time, chat, 5 MB file |
| Flutter | `cd app && flutter test` | widget + screenshot tests |
| Fuzz regressions (stable) | `cd core/fuzz && cargo test --release` | replays `core/fuzz/regressions/*` + seeded random/mutation search over all 12 fuzz targets |
| Fuzzing (nightly) | `cd core/fuzz && cargo +nightly fuzz run <target> -s none -- -max_total_time=600 -dict=dict/lumora.dict` | libFuzzer; see below |
| Scale (multi-user) | `python3 core/tests/scale.py --n 24 --per 10` | N real nodes in one group, everyone sends, everyone must receive everything; reports RSS/CPU |

## Latest results (2026-11-05, debug build, one laptop)

| Test | Result |
|---|---|
| Core / media / relay unit tests | 21 / 27 / 13 passed |
| E2E (17 scenarios) | 3 consecutive full passes; LAN delivery 2–4 ms; 12 MB file 16–24 MB/s |
| NAT lab (2026-11-06) | 143/145 as expected; known gaps: friend peer relay not offered without reconnect, 1 `connect` race in 435 runs, sequential↔sequential via relay — see [NAT traversal](nat-traversal.md) |
| Scale 12 nodes × 5 msgs | 720 deliveries in 0.5 s, 30 MB RSS/node, 0 outbox left |
| Scale 24 nodes × 10 msgs | 5 760 deliveries in 5.6 s, 32 MB RSS/node, ~1 s CPU/node, 0 outbox left |
| Packet loss on LAN path | 0 % (after disabling QUIC bit greasing) |

## Fuzzing

`core/fuzz` is a separate crate (excluded from the workspace, own lockfile) with one target per parser that
sees attacker-controlled bytes: `peer_frame` (control stream frames, every `PeerMsg`/`Signal`/`SyncBatch`/
`SyncItem`), `chat_group` (group envelopes, `Signed`, DevSig/device certs, device lists, link QR, sealed
signalling), `group_fold` (validly signed op logs: no panic, order-independent result, one owner, banned ≠
member), `file_preview`, `bot_token`, `invite`, `recovery_phrase` (BIP39 + legacy), `relay_proto`, `stun`,
`nostr`, `push_bridge` and `api_json` (the JSON dispatcher against a real node with networking off; commands
that touch caller-chosen paths, devices or the network are excluded).

```bash
cd core/fuzz
cargo test --release --test seeds -- --ignored     # write a starting corpus of valid inputs
cargo +nightly fuzz run peer_frame -s none corpus/peer_frame -- -max_total_time=600 -dict=dict/lumora.dict
```

A crash input goes into `regressions/<target>/` once fixed, so the stable test keeps replaying it in CI.
