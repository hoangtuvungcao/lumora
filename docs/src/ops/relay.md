# Relays

Lumora is serverless-first. A relay is an **optional last resort**. It forwards
traffic between two nodes that cannot reach each other directly, and it carries
signaling (call offers, sealed messages) for peers that are offline or unreachable.
Anyone can run one. A node can use several relays at the same time (`NetConfig.relays`).

## When the app uses a relay

1. Direct paths are tried first: LAN discovery, UPnP, STUN hole punching, DHT/Nostr
   rendezvous.
2. The relay is used for DATA only if no direct path works within `relay_delay_ms`
   (default **3500 ms**, `NetConfig` in `lumora-core/src/net/mod.rs`). The node keeps
   trying direct paths and moves off the relay when one succeeds.
3. SIGNAL frames (sealed envelopes) may go through a relay at any time. They are small
   and rare.

## What a relay sees and what it does not

| Sees | Does not see |
|---|---|
| The public keys of connected nodes (HELLO is signed) | Message, call, file or screen content |
| Which key sends frames to which key, with sizes and timing | Contacts, names, chat metadata inside envelopes |
| The client IP address | Session keys: QUIC/TLS and sealed envelopes are end-to-end |

A relay cannot forge traffic, because payloads are authenticated end to end. It can
drop or delay frames, and peers then fall back to other paths or relays. Signals stored
in the mailbox stay encrypted.

## Protocol

WebSocket binary frames at `/ws`, defined in
`core/crates/lumora-core/src/net/relay_proto.rs`: HELLO (Ed25519 over
`"lumora-relay-hello-v1" || pubkey || ts_ms`, ±5 min, replay-protected) → WELCOME
(observed address) → DATA / SIGNAL (`peer[32] payload`; the relay rewrites `peer` to
the sender's key) and GONE / ERROR. A node has one live session per relay; a new
connection replaces the old one.

## Options

| Option | Best for | Cost |
|---|---|---|
| VPS + Docker (`relay/vps`) | everything, including calls and remote desktop; adds STUN | about $4–6/month |
| VPS + systemd (static binary) | same, without Docker | same |
| Cloudflare Worker (`relay/cloudflare`) | signaling and chat, free | free tier; DATA capped per day |

### VPS with Docker (recommended)

```sh
git clone <repo> lumora && cd lumora/relay/vps
sudo ./install-vps.sh         # installs Docker, asks for a domain, starts relay + Caddy
```

The script prints `wss://<domain>/ws`; paste it into the app. Without a domain, accept
the suggested `<ip>.sslip.io`. Open TCP 80 and 443 and UDP 3478 (and UDP 443 for
HTTP/3). Caddy obtains the TLS certificate and proxies `wss://` to the relay on `:8443`.
STUN (UDP 3478) is published directly from the relay container.

Manual setup: `cp .env.example .env`, set `DOMAIN`, then `docker compose up -d --build`.
To update, run `git pull && docker compose up -d --build`. The mailbox is persisted in the
`relay-data` volume.

### VPS with systemd (no Docker)

```sh
cd core && cargo build --release -p lumora-relay
sudo install -m755 target/release/lumora-relay /usr/local/bin/
sudo install -m644 ../relay/vps/lumora-relay.service /etc/systemd/system/
sudo install -m644 ../relay/vps/lumora-relay.env.example /etc/default/lumora-relay
sudo systemctl daemon-reload && sudo systemctl enable --now lumora-relay
```

Put TLS in front of it in one of two ways:

- **Reverse proxy (Caddy).** Use a Caddyfile with `relay.example.com { reverse_proxy 127.0.0.1:8443 }`
  and set `LUMORA_RELAY_TRUST_PROXY=true`.
- **Native TLS.** Set `LUMORA_RELAY_LISTEN=0.0.0.0:443`, `LUMORA_RELAY_TLS_CERT` and
  `LUMORA_RELAY_TLS_KEY` (PEM, for example from certbot), and leave trust-proxy off. Restart
  the service after the certificate renews.

### Cloudflare Workers

`cd relay/cloudflare && npm install && npx wrangler deploy`. Details are in
`relay/cloudflare/README.md`. Free-plan budget: about **100k requests/day**, and incoming
Durable Object WebSocket messages count about **20 = 1 request**. That covers a lot of
signaling and chat but **not long video calls or remote desktop**. A hard daily DATA
cap (`DATA_BUDGET_BYTES`, default 200 MB) makes the Worker answer DATA with ERROR once the
cap is reached, so apps fall back to other paths instead of exhausting the account. The
Worker has no STUN responder.

## Flags (Rust relay)

Every flag also has an environment variable `LUMORA_RELAY_<FLAG>` (for example
`--max-clients` → `LUMORA_RELAY_MAX_CLIENTS`). Run `lumora-relay --help` for the full list.

| Flag | Default | Meaning |
|---|---|---|
| `--listen` | `0.0.0.0:8443` | HTTP(S) address; `/ws`, `/health` (JSON stats), `/` |
| `--tls-cert`, `--tls-key` | none | PEM files; enables native `wss://` (rustls) |
| `--trust-proxy` | false | use `CF-Connecting-IP` / right-most `X-Forwarded-For` for WELCOME |
| `--stun-port` | 3478 | STUN binding responder (UDP); `0` disables it |
| `--stun-bind` | `0.0.0.0` | STUN bind IP (`::` for dual-stack) |
| `--max-clients` | 10000 | authenticated sessions |
| `--bandwidth`, `--burst` | 2 MiB/s, 4 MiB | per-client DATA token bucket; excess is dropped |
| `--signal-rate` | 20 | SIGNAL frames/s per client (burst 2x); excess gets ERROR |
| `--max-frame` | 65536 | larger frames get ERROR |
| `--idle-timeout` | 90 s | clients ping every 20 s |
| `--hello-timeout` | 10 s | time allowed to send HELLO |
| `--allow` | none | private mode: file of allowed keys (hex or base32, `#` comments) |
| `--mailbox` | true | store SIGNAL for offline peers (`--mailbox false` disables) |
| `--mailbox-max-items` | 200 | per recipient |
| `--mailbox-max-item` | 65536 | bytes per stored signal |
| `--mailbox-ttl` | 604800 s | 7 days |
| `--mailbox-total` | 256 MiB | memory cap for all mailboxes |
| `--mailbox-file` | none | persist the mailbox (saved every minute and on SIGTERM) |
| `--queue` | 1024 | per-session send queue (frames) |
| `--log-json` | false | JSON logs; set the level with `RUST_LOG` |

Backpressure: when a receiver's queue is full, DATA is dropped (UDP semantics). A
client that cannot keep up with SIGNAL is disconnected, and its pending signals move
to the mailbox. Signals are never dropped silently.

## Sizing

- **Signaling-only relay**: 1 vCPU / 512 MB handles 10k idle clients easily (about 10 KB
  each, plus the mailbox).
- **Data relay**: bandwidth is the limit, not CPU. A relayed 720p call uses about
  1–2 Mbit/s each way, and remote desktop 2–8 Mbit/s. With a 1 Gbit/s port and the default
  2 MiB/s per-client cap, plan for 30–50 concurrent relayed sessions. Watch your provider's
  monthly traffic allowance.
- RAM: the mailbox is capped by `--mailbox-total` (256 MB by default). Set it lower on
  small machines.
- Watch `GET /health`: `clients`, `bytes_relayed`, `data_dropped`, `mailbox.bytes`.

## Security notes

- Only enable `--trust-proxy` when the port is reachable **only** from your proxy.
  Otherwise clients can set the address they are told they have. This affects only the
  client itself, but it is still misleading.
- Private relays: use `--allow` (or `ALLOW` on Cloudflare) to restrict use to your own
  devices and contacts.
- The relay keeps no logs of payloads. Session open and close events are logged with a
  short key prefix, and client IPs only at `debug` level.
- The Docker image runs as a non-root user (uid 10001). The systemd unit uses
  `DynamicUser` and strict sandboxing.
- Keep the relay updated. It never holds user keys, so a compromised relay can only
  observe metadata and drop traffic.
