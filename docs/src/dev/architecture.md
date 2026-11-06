# Architecture overview

```
┌────────────── Flutter app (UI only) ──────────────┐
│ screens · state · i18n (vi/en) · video rendering  │
└───────────────▲───────────────────────────────────┘
                │ dart:ffi  (JSON requests, events, RGBA frames)
┌───────────────┴────────── lumora-ffi ─────────────┐
│ lumora-core                                        │
│  identity  ─ Ed25519 device key, 9-digit verifiable ID, recovery phrase
│  keystore  ─ Argon2id passphrase or OS keychain wraps identity + DB key
│  store     ─ SQLCipher DB (AES-256 + HMAC pages, secure_delete, retention)
│  net       ─ QUIC (quinn) on one "magic" UDP socket:
│              STUN client+server · LAN multicast · UPnP · Mainline DHT
│              Nostr signaling + ID directory · hole punching ·
│              port prediction · birthday spraying · relay tunnel
│  node      ─ connections, friends, DM chat, groups (signed op-log,
│              epoch keys), files (resumable, BLAKE3), calls, remote desktop
│ lumora-media ─ screen capture (PipeWire/X11/DXGI/SCK), video: libvpx VP8/VP9 + OS H.264,
│              input injection (uinput/XTest/SendInput/CGEvent), Opus audio
└────────────────────────────────────────────────────┘
```

## Key principles
1. **The device is the account.** A key pair generated locally; nothing to register.
2. **Every path is end-to-end encrypted.** QUIC/TLS 1.3 is pinned to the peer's identity key, so even a
   compromised signaling channel or relay only sees ciphertext and cannot impersonate anyone.
3. **No required infrastructure.** Discovery and signaling use long-lived public networks (BitTorrent
   Mainline DHT, many independent Nostr relays, public STUN), LAN multicast, and peers helping each other.
   Optional self-hosted relays only bridge the rare networks where no direct path exists.
4. **Bounded resources.** Every queue, cache and table has a cap (see [performance](performance.md)).

## Connection lifecycle
1. `connect(peer)`: LAN fast path → sealed *Offer* through all signaling channels + cached addresses.
2. Peer answers with its candidates and dials back at the same time (simultaneous open = hole punch).
3. Paths race: direct candidates, port prediction, birthday spraying (one side symmetric), relay (delayed).
4. First QUIC handshake wins; duplicates are closed deterministically (better path wins, tie → smaller key).
5. On connect: outbox flush, store-and-forward mail, group anti-entropy sync.
6. Relayed peers are re-tried for a direct path every 30 s and switched over seamlessly.

## Groups
Signed membership op-log folded deterministically on every member (owner > admin > member, earliest op wins),
content encrypted with an epoch key that rotates when someone leaves or is removed; any member gossips and
back-fills envelopes for offline members (per-author HLC heads).
