# Architecture decision records

| # | Decision | Why |
|---|---|---|
| 1 | Rust core + Flutter UI (RustDesk-style) | one high-performance core for all OSes; Flutter renders smoothly on desktop + Android; no webview (WebKitGTK video is poor on Linux) |
| 2 | QUIC (quinn) instead of WebRTC | full control over NAT traversal (spraying, prediction, relay tunnelling), streams + datagrams, connection migration |
| 3 | Identity-pinned TLS certificates | removes trust in signaling/relays |
| 4 | Nostr + Mainline DHT for signaling/directory | free, long-lived, many independent operators; no server to maintain |
| 5 | SQLCipher | mature, audited page-level encryption with SQL convenience |
| 6 | Signed op-log groups with epoch keys | serverless convergence; MLS planned later |
| 7 | Video: bundled libvpx VP8/VP9 everywhere + H.264 only from the OS (MediaCodec, VideoToolbox, Media Foundation), negotiated per call (2026-11; replaces source-built OpenH264) | no H.264 implementation of our own is shipped and nothing is downloaded at run time (patent licensing; works for decades offline); hardware H.264 when both ends have it (battery), VP8/VP9 otherwise; see [Video codecs](video-codecs.md) |
| 8 | Multi-device: the account key stays on the main device; every device has its own key and a root-signed certificate (2026-11) | old peers keep dialing and pinning the account key (the main device), so no flag day; a stolen linked device can be revoked without changing the account; recovery phrase = main device |
| 9 | Device signatures ride in the existing `sig: Vec<u8>` fields (170-byte "DevSig" with the certificate inside) (2026-11) | no wire struct gains a field (old decoders reject extra array elements); old verifiers reject the longer signature cleanly; members can verify a device they haven't heard of yet |
| 10 | One new `PeerMsg::Ext { kind, body }` variant with map-encoded bodies, only sent to devices that announced protocol ≥ 3 (2026-11) | an old reader stops at an unknown variant, so there is exactly one gated variant; new fields inside bodies stay optional forever |
| 11 | Group anti-entropy heads and key rotation keyed by the signing *device* (2026-11) | two devices of one account post concurrently without leaving gaps, and only the device that signed a removal rotates the key |
| 12 | Linking direction: the main device shows the QR / 12-digit code, the new device scans (both directions are supported by the core) (2026-11) | matches what users expect from "add a device" on the device they already trust; the same proofs (QR secret bound to the TLS exporter, SPAKE2 for the code) run with dialer and responder swapped |
| 13 | Olm ratchet encryption happens when a message is written to a connection, not when it is queued (2026-11) | re-sends always use the current chain in stream order, so a burst or a re-send can't overrun the receiver's 40-key skip window; a receiver that can't decrypt hands the sender a fresh one-time key (unsolicited `OlmKeys`, understood by every version) and the unacknowledged messages are re-encrypted with the new session |
| 14 | Inbound rate limit slows trusted senders down (back-pressure on their stream) instead of dropping (2026-11) | dropping an already-decrypted message after the outer ack lost it for good; strangers are still dropped (unacknowledged) |
| 15 | Linked devices reach friends on old apps through the main device (`Ext PROXY`, re-signed with the same ids) (2026-11) | old apps only accept account-key signatures; same ids mean newer apps that got both copies keep one |

Add a row for every significant change (date + reason).
