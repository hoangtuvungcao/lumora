# Lumora relay on Cloudflare (Workers + Durable Objects)

A zero-server relay that speaks the exact same protocol as the Rust `lumora-relay`
(`core/crates/lumora-core/src/net/relay_proto.rs`). It runs on the **free plan** and is
meant for **signaling and chat**. It is not a good fit for long calls or remote-desktop
sessions; use a VPS relay for those (see `docs/src/ops/relay.md`).

## Deploy

```sh
cd relay/cloudflare
npm install
npx wrangler login          # opens a browser once
npx wrangler deploy
```

Wrangler prints `https://lumora-relay.<your-subdomain>.workers.dev`. In the app, add
the relay as:

```
wss://lumora-relay.<your-subdomain>.workers.dev/ws
```

Check it at `https://…workers.dev/health`.

Custom domain: uncomment `routes` in `wrangler.toml` (the zone must be on your account).
Private relay: `npx wrangler secret put ALLOW` and paste the allowed keys (64-hex or
Lumora base32 peer ids), comma separated.

## How it works

- `/ws` is forwarded to one **hub** Durable Object (`HUB`, default `global`). It holds
  every socket through the WebSocket Hibernation API, so idle connections cost no
  duration. Peers must use the same hub to reach each other.
- HELLO is verified with `crypto.subtle.verify({name: "Ed25519"})`, with a ±5 min
  timestamp window and a replay table in DO SQLite. Sockets that send no HELLO within
  10 s are closed by an alarm.
- DATA and SIGNAL are forwarded with the peer field rewritten to the sender's key.
  DATA to an absent peer gets GONE, at most once per second per target.
- SIGNAL to an offline peer goes into a SQLite mailbox (200 items per peer, 64 KB each,
  7-day TTL, 64 MB total by default). It is delivered on the peer's next HELLO.
- **Daily DATA budget** (`DATA_BUDGET_BYTES`, 200 MB per UTC day by default). Once it
  is used up, DATA frames get `ERROR "daily relay data budget exhausted"` and the app
  falls back to other paths. Signals keep flowing.

## Free-tier limits (check current Cloudflare pricing)

- Workers Free: about **100,000 requests/day**. Each WebSocket connect counts.
- Durable Objects: incoming WebSocket messages are billed at about **20 messages = 1
  request**. One relayed QUIC datagram is one message, so a 1 Mbit/s video stream
  (about 100 datagrams/s) would use the daily allowance in minutes. Chat, presence
  and call setup use only a few messages per minute per peer.
- SQLite rows written are metered (100k/day on free). The relay writes rows only for
  HELLO (replay table), for stored signals and, at most every 10 s, for the budget
  counter.

## Configuration (`[vars]` in wrangler.toml)

| var | default | meaning |
|---|---|---|
| `HUB` | `global` | hub name (one Durable Object) |
| `LOCATION_HINT` | (none) | placement hint for the hub: `weur`, `enam`, `apac`, … |
| `MAX_CLIENTS` | 5000 | authenticated sockets per hub |
| `MAX_FRAME` | 65536 | max frame bytes |
| `SIGNAL_RATE` | 20 | SIGNAL frames/s per client (burst 2x) |
| `DATA_RATE` / `DATA_BURST` | 2 MiB/s / 4 MiB | per-client DATA token bucket |
| `DATA_BUDGET_BYTES` | 209715200 | daily DATA cap for the hub (0 = unlimited) |
| `MAILBOX` | true | store signals for offline peers |
| `MAILBOX_MAX_ITEMS` / `MAILBOX_MAX_ITEM` | 200 / 65536 | per-peer caps |
| `MAILBOX_TTL_SECS` | 604800 | 7 days |
| `MAILBOX_TOTAL_BYTES` | 67108864 | total mailbox cap |
| `ALLOW` | (empty) | private mode allow list (use a secret) |

Differences from the VPS relay: no STUN (Workers cannot serve UDP), and WELCOME
reports only the client IP (`CF-Connecting-IP`).

## Local test

```sh
npx wrangler dev --port 8787
RELAY_URL=ws://127.0.0.1:8787/ws node --experimental-websocket test/smoke.mjs   # Node 20
```

The same `test/smoke.mjs` also runs against the Rust relay
(`RELAY_URL=ws://127.0.0.1:8443/ws`).
