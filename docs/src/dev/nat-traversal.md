# NAT traversal

All techniques run **in parallel**; the first QUIC handshake to complete wins.

| Situation | Technique | Implementation |
|---|---|---|
| Same LAN | multicast announce `239.255.76.77:47777` + Bonjour `_lumora._udp` → direct LAN dial; host candidates are also sent in every offer | `net/discovery.rs` |
| IPv6 both sides | global IPv6 candidates, simultaneous open (punches through stateful v6 firewalls) | `refresh_info` |
| Router supports UPnP-IGD | map our UDP port | `discovery::upnp_map` |
| Cone NAT (EIM), CGNAT with EIM, hairpinning NAT | STUN reflexive address + simultaneous QUIC dial (+ probe pre-punch) | `Transport::punch`, `dial_direct` |
| Symmetric, sequential ports | detect delta from ≥2 STUN servers, dial predicted ports | `NatKind::HardSequential` |
| Symmetric ↔ cone | birthday spraying: 256 sockets on the hard side, ~4000 probes from the easy side (~98% success) | `spray_from_hard/easy` |
| Hard ↔ hard, a mutual friend on an easy NAT | the friend relays (QUIC/TLS end to end, friend sees ciphertext, 1 MB/s cap) | `node/peer_relay.rs` |
| UDP blocked / hard ↔ hard random | QUIC tunnelled through a relay over WebSocket/TLS 443 (still E2E TLS) | `relay_client.rs` |

Every node is also a **STUN server** for its peers (binding requests on the main port are answered), so
connectivity checks keep working even if all public STUN servers disappear.

Signaling channels (all sealed, all redundant): Nostr relays (5 by default, any can fail), configured relays,
peer relays, LAN, and Mainline DHT lookup of the peer's encrypted record (addresses + relays) when no answer
arrives.

The UDP port is kept stable across restarts so friends' cached addresses stay valid → reconnects are often
instant without any signaling at all.

## NAT lab

`sudo python3 nat-lab/run.py --mode all` builds every network below with Linux namespaces, iptables,
ip6tables and tc, runs two (or three) real `lumorad` nodes in it and records the path, the connect time
(median of 3), the RTT, chat delivery both ways and a 5 MB file transfer (SHA-256 checked).
`--quick` is the CI subset (8 cases × {full, no-relay}, 1 trial, no file: 16 jobs in ~70 s). See `nat-lab/README.md` for every option.

Emulated NATs (RFC 4787 terms):

| lab name | mapping | filtering | typical device |
|---|---|---|---|
| `fullcone` | endpoint-independent | endpoint-independent | old routers, DMZ |
| `addrcone` | endpoint-independent | address-dependent | some routers |
| `portcone` | endpoint-independent | address + port dependent | **most home routers** |
| `symseq` | per destination, ports +1 | address + port dependent | older enterprise gear, some CGNAT |
| `symrand` | per destination, random ports | address + port dependent | **4G, many CGNATs** |
| `cgnat-eim/X`, `cgnat-sym/X` | home NAT X behind a carrier NAT (100.64/10) | | FTTH with CGNAT, 4G |
| `v6+X` | v4 NAT X **plus** global IPv6 behind a stateful firewall | inbound only after outbound | dual-stack ISPs |
| `udpblock` | — all outbound UDP dropped | | corporate / school |

Modes: **full** = 2 STUN servers + relay; **no-stun** = no STUN (the relay-observed IP + our port is used as a
guess); **no-relay** = relay carries only sealed signaling, never data ("P2P only"); **lan-only** = no server
at all. Path labels: `lan`, `direct` (public IPv4, incl. hairpin), `v6`, `peer-relay`, `relay`, `none`.

## Measured matrix (2026-11-06, debug build, one laptop)

Each cell: path · median time from `connect` to the final path (3 fresh runs, strangers, first contact).
Inside the lab there is no wire latency, so times show the *protocol* cost: ~30 ms for a plain punch,
100–900 ms when birthday spraying is needed, 4.0 s when the relay is only tried after `relay_delay`.

| case | A ↔ B | expected | full | no-stun | no-relay | no-stun-no-relay |
|---|---|---|---|---|---|---|
| fc-fc | fullcone ↔ fullcone | direct | ✅ direct · 35 ms | ✅ direct · 48 ms | ✅ direct · 37 ms | ✅ direct · 40 ms |
| fc-sr | fullcone ↔ symrand | direct | ✅ direct · 36 ms | ✅ direct · 44 ms | ✅ direct · 44 ms | ✅ direct · 43 ms |
| ac-ac | addrcone ↔ addrcone | direct | ✅ direct · 39 ms | ✅ direct · 47 ms | ✅ direct · 45 ms | ✅ direct · 71 ms |
| ac-sr | addrcone ↔ symrand | direct | ✅ direct · 55 ms | ✅ direct · 40 ms | ✅ direct · 38 ms | ✅ direct · 37 ms |
| pc-pc | portcone ↔ portcone | direct | ✅ direct · 31 ms | ✅ direct · 40 ms | ✅ direct · 32 ms | ✅ direct · 35 ms |
| pc-sr | portcone ↔ symrand | direct | ✅ direct · 585 ms | ✅ direct · 135 ms | ✅ direct · 342 ms | ✅ direct · 378 ms |
| sr-pc | symrand ↔ portcone | direct | ✅ direct · 304 ms | ✅ direct · 103 ms | ✅ direct · 241 ms | ✅ direct · 204 ms |
| ss-pc | symseq ↔ portcone | direct | ✅ direct · 86 ms | ✅ direct · 810 ms | ✅ direct · 91 ms | ✅ direct · 210 ms |
| pc-ss | portcone ↔ symseq | direct | ✅ direct · 37 ms | ✅ direct · 479 ms | ✅ direct · 68 ms | ✅ direct · 717 ms |
| ss-fc | symseq ↔ fullcone | direct | ✅ direct · 96 ms | ✅ direct · 107 ms | ✅ direct · 93 ms | ✅ direct · 102 ms |
| ss-ss | symseq ↔ symseq | direct or relay | ⚠️ relay · 4.0 s | ⚠️ relay · 4.0 s | ⚠️ none | ⚠️ none |
| ss-sr | symseq ↔ symrand | relay | ✅ relay · 4.0 s | ✅ relay · 4.1 s | ✅ none | ✅ none |
| sr-fc | symrand ↔ fullcone | direct | ✅ direct · 103 ms | ✅ direct · 102 ms | ✅ direct · 102 ms | ✅ direct · 103 ms |
| sr-ac | symrand ↔ addrcone | direct | ✅ direct · 105 ms | ✅ direct · 102 ms | ✅ direct · 102 ms | ⚠️ direct 2/3 · 102 ms ¹ |
| sr-sr | symrand ↔ symrand | relay | ✅ relay · 7 ms | ✅ relay · 4.0 s | ✅ none | ✅ none |
| cge-pc | CGNAT-EIM+home ↔ portcone | direct | ✅ direct · 38 ms | ✅ direct · 43 ms | ✅ direct · 32 ms | ✅ direct · 41 ms |
| cge-cge | CGNAT-EIM+home ↔ CGNAT-EIM+home | direct | ✅ direct · 35 ms | ✅ direct · 43 ms | ✅ direct · 35 ms | ✅ direct · 38 ms |
| cgs-pc | CGNAT-sym+home ↔ portcone | direct | ✅ direct · 203 ms | ✅ direct · 709 ms | ✅ direct · 405 ms | ✅ direct · 913 ms |
| cgs-cge | CGNAT-sym+home ↔ CGNAT-EIM+home | direct | ✅ direct · 810 ms | ✅ direct · 102 ms | ✅ direct · 911 ms | ✅ direct · 206 ms |
| cgs-cgs | CGNAT-sym+home ↔ CGNAT-sym+home | relay | ✅ relay · 11 ms | ✅ relay · 4.0 s | ✅ none | ✅ none |
| samecg | two homes, same CGNAT, no hairpin | relay | ✅ relay · 4.0 s | ✅ relay · 4.0 s | ✅ none | ✅ none |
| samecg-hp | two homes, same CGNAT, hairpin | direct | ✅ direct · 32 ms | ✅ direct · 36 ms | ✅ direct · 32 ms | ✅ direct · 35 ms |
| samenat | same router, same LAN | lan | ✅ lan · 6 ms | ✅ lan · 29 ms | ✅ lan · 8 ms | ✅ lan · 30 ms |
| samenat-hp | same router + hairpin | lan | ✅ lan · 10 ms | ✅ lan · 29 ms | ✅ lan · 7 ms | ✅ lan · 36 ms |
| iso | same router, isolated segments (guest Wi-Fi) | relay | ✅ relay · 4.0 s | ✅ relay · 4.0 s | ✅ none | ✅ none |
| iso-hp | isolated segments, router hairpins | direct | ✅ direct · 31 ms | ✅ direct · 35 ms | ✅ direct · 34 ms | ✅ direct · 33 ms |
| v6-sym | v6 + symrand ↔ v6 + symrand | v6 | ✅ v6 · 41 ms | ✅ v6 · 36 ms | ✅ v6 · 32 ms | ✅ v6 · 37 ms |
| v6-pc | v6 + portcone ↔ v6 + portcone | v6 | ✅ v6 · 31 ms | ✅ v6 · 38 ms | ✅ v6 · 32 ms | ✅ v6 · 43 ms |
| v6-v4 | v6 + portcone ↔ portcone (v4 only) | direct | ✅ direct · 56 ms | ✅ direct · 57 ms | ✅ direct · 56 ms | ✅ direct · 55 ms |
| v6-v4sym | v6 + symrand ↔ portcone (v4 only) | direct | ✅ direct · 405 ms | ✅ direct · 1.4 s | ✅ direct · 609 ms | ✅ direct · 304 ms |
| ub-pc | udpblock ↔ portcone | relay | ✅ relay · 9 ms ² | ✅ relay · 4.0 s | ✅ none | ✅ none |
| ub-sr | udpblock ↔ symrand | relay | ✅ relay · 10 ms ² | ✅ relay · 4.0 s | ✅ none | ✅ none |

LAN discovery with **no server of any kind** (`lan-only`): raw multicast alone → `lan` · 5 ms; Bonjour/DNS-SD
alone → `lan` · 5 ms (3/3 each). Detected NAT kinds matched the emulation in every run (`easy`,
`symmetric-sequential`, `symmetric-random`, `udp-blocked`; `unknown` without STUN).

¹ one run in 435: the connection *was* established but `connect` returned "can't reach" — see limit L5.
² was 4.0 s before fix F1 below (the blocked side was classified `unknown`, so the relay waited `relay_delay`).

### Data over the chosen path (full mode)

Chat delivery is measured with 50 ms polling (so "≈ 52 ms" means "within one poll"). RTT is QUIC's
smoothed RTT after the transfer.

| path | example cases | chat both ways | 5 MB file |
|---|---|---|---|
| lan / direct / v6 | samenat, pc-pc, pc-sr, v6-sym, cgs-pc | ✅ ≤ 55 ms | ✅ 0.3–0.5 s (80–157 Mbit/s, CPU-bound debug build) |
| relay (server) | sr-sr, cgs-cgs, ub-pc, iso | ✅ ≤ 55 ms | ✅ 0.8–1.0 s (40–53 Mbit/s, relay burst allowance) |
| peer relay (friend) | peer-relay | ✅ ≤ 55 ms | ✅ 3.3 s (12 Mbit/s = the 1 MB/s friend cap) |

### Impairments on A's access link (both directions, `tc netem`)

| profile | mode | path | connect | RTT | chat | 5 MB file |
|---|---|---|---|---|---|---|
| 5 % loss | full / no-relay | direct 3/3 | 40 / 35 ms | 0 ms | ✅ 54 ms | ✅ 0.5–1.3 s |
| +300 ms RTT | full / no-relay | direct 3/3 | 633 / 636 ms | 300 ms | ✅ 155–205 ms | ✅ 2.5–3.0 s (13–16 Mbit/s) |
| 1 Mbit/s (0.7 s buffer) | full / no-relay | direct 3/3 | 63 / 59 ms | 25 ms idle, up to 4.8 s right after the transfer | ✅ 53 ms | ✅ 47–83 s (0.5–0.8 Mbit/s) |
| all three | full / no-relay | direct 3/3 | 1.5 s / 664 ms | 315 ms | ✅ 205 ms (one 1.6 s) | ✅ 48–57 s (0.7–0.8 Mbit/s) |
| symrand ↔ portcone, 5 % loss + 300 ms | full / no-relay | direct 3/3 | 1.4 / 1.2 s | 300 ms | ✅ 155–205 ms (one 0.8 s) | ✅ 3.3 s |

### Keep-alive, NAT rebinding, friend relay, birthday odds

| scenario | result |
|---|---|
| NAT UDP timeout 30 s, 3 min idle | ✅ same connection after 182 s (10 s QUIC keep-alives), chat 52 ms — full and no-relay |
| A's external port changes mid-session | ⚠️ connection dies; message delivered after **56 s** (full: falls back to the **relay**, upgraded later) / **58 s** (no-relay: direct again) |
| then B's external port changes | ⚠️ full: already on relay, 53 ms; no-relay: **120 s** (waited for the 2-minute reconnect sweep) |
| symrand ↔ symrand + mutual friend C on a home router, server relay killed | ✅ A↔B back via **peer relay** after 60–65 s (≈ QUIC idle timeout), chat ✅, 5 MB in 3.3 s, no server involved |
| same, but the friendships were made while already connected (no restart) | ❌ no peer relay offered → none (limit L4) |
| symrand ↔ symrand, two-sided birthday spray only (no STUN, no relay data), 10 attempts | 0/10 direct — as theory predicts (≈ 2³² combinations) |

## In plain language

* **Home Wi-Fi to home Wi-Fi, 4G to home, FTTH behind a carrier NAT**: direct, typically in well under a
  second. Two phones on *random-port* 4G/CGNAT on both sides cannot connect directly over IPv4 (nobody
  can) — but if both have IPv6 (most Vietnamese 4G and FTTH plans do) they connect directly over IPv6.
* Otherwise the app uses a relay, **or a mutual friend whose network is friendly**, end-to-end encrypted
  either way, and keeps trying to upgrade to direct.
* Same Wi-Fi: found with no Internet at all, by multicast or Bonjour. Guest/isolated Wi-Fi: direct only if
  the router supports hairpinning, otherwise relay.
* No UDP at all (corporate firewalls): relay over TCP/443, now immediately.
* A slow or bad link (5 % loss, 300 ms, 1 Mbit/s) still connects, chats instantly and moves files at
  close to the link's speed.
* If the network changes the public port under a live call (CGNAT re-mapping, router reboot), the chat
  comes back by itself, but today that takes about a minute (see L2/L3).

## Fixes made

* **F1 — UDP-blocked detection (net/mod.rs, `no_v4_mapping_kind`).** When STUN servers were asked and none
  answered but a relay had seen our IP, `refresh_info` returned `Unknown` (the relay-guess branch came
  first), so `udp-blocked` was never reported: no "hopeless" shortcut, the relay waited `relay_delay`
  (4 s in the lab, 3.5 s default) and a two-sided spray was attempted into a network that drops UDP.
  Now: STUN asked + silence → `UdpBlocked`; no STUN configured/resolvable → `Unknown` (previously LAN-only
  nodes were mislabeled `udp-blocked`). Measured: ub-pc 4.0 s → 9 ms, ub-sr 4.0 s → 10 ms; unit test
  `net::tests::nat_kind_without_v4_mapping`.

## Fixes made (round 2, 2026-11-06)

* **L1 fixed** — `race_paths_opt` probes the peer's *predicted* ports first, in ascending order, before
  any other address (`predicted_ports`: 8 predictions, 32 when both sides are sequential); a sequential
  NAT also refreshes its reflexive ports when they are older than 10 s and skips the cached-address
  probe (every extra destination shifts its ports). Lab: ss-ss **direct** in `full` and `no-relay`.
* **L2 fixed** — (a) an offer from a peer we think is connected directly is a *repair request*: the old
  path is marked suspect on both sides (a new connection always replaces a suspect one, so both sides
  agree), our reflexive address is refreshed and we dial back; (b) a dead direct path invalidates the
  cached reflexive address; (c) a dropped friend is re-dialed after 2, 5, 10, 20, 40 s.
  Also: signals never block on one relay (a peer relay riding on the dead path stalled the answer and
  the dial-back until the idle timeout) and are never sent through the recipient's own peer relay.
* **L3 fixed** — path watchdog (`spawn_path_watchdog`): no datagram for 3 s on an active connection
  (messages in the last 2 min or a transfer) → ping; still nothing 2.5 s later → suspect + repair
  (idle connections: 12 s / 16 s, keep-alive stays 10 s). A connection through a relay that is gone
  (WebSocket closed, friend's peer relay dropped) is closed at once, and when a friend's connection
  dies its peer relay and the connections tunnelled through it are closed immediately.
* **L4 fixed** — becoming friends while connected sends `RelayOffer`, the friends-only DHT key and a
  full `Hello` (`on_became_friends`).
* **L5 fixed** — `connect` returns the surviving connection when its own attempt lost the race.
* **L6** — quinn already uses BBR (`tls.rs`); unchanged.

Lab after round 2 (`--mode all`, 3 trials, 2026-11-06): **143/145 as expected**; pairs become friends
first (strangers get no address — IP privacy), then both restart and the connect is measured.
ss-ss **direct** in `full` (12 ms) and `no-relay` (13 ms); NAT rebinding: A side 6.7 s, B side 6.8 s
(was 56 s / 58–120 s), new direct connection, both modes; peer-relay failover after the server relay
dies: **1.0 s** (was 60–65 s), also for friendships made while connected (was: no peer relay).
The two misses: `samenat-hp` no-stun / no-stun-no-relay took the hairpinned public path (direct) in
1 of 3 trials instead of the LAN path (the cached-address dial after the restart can win the race).

Round 3 (network review, 2026-11-06): the rebinding times above had regressed to **10.5 s (relay)** in
`full` and **31–42 s** in `no-relay` on the same tree (measured with the pre-review binary too), depending
on which side's watchdog fired first. Causes and fixes: (1) the answer-side dial for the peer's repair
offer held the dial lock for its whole 25 s deadline, so our own fresh offer waited behind it —
`connect_repair` no longer queues behind it; (2) the dead connection kept retransmitting on the old
5-tuple, and the repair dial from the same socket to the same address rode that NAT mapping, which the
peer can't learn — the watchdog now closes a silent direct path at once (it is dead for us anyway);
(3) predictions for a sequential NAT also cover the ports just *below* the reported ones (a flow mapped
right before the STUN probe). Signaling sockets are *probed* (ping, reconnect only without an answer
within 1 s) instead of all being reconnected; a relayed connection survives its relay WebSocket being
down for up to 10 s; failed relay → direct upgrades back off 30 s → 30 min (reset on a network change),
and spraying is skipped on a metered network / battery saver (`set_network_hint`). Keepalive case, 3
runs × 2 modes: rebinding **6.5–6.8 s** on both sides, both modes (one B-side rebinding landed on the
relay after 4.0 s in `full`). A relayed connection whose relay stays down past the grace period is
closed then (not at the idle timeout), and a peer relay is never opened over a server-relayed connection
(it would die with that relay — this made `peer-relay-live` flaky). Full lab after round 3: **145/145 as
expected**; rebinding 6.6–6.8 s both sides, both modes; peer-relay failover 31.5 s / 24.8 s (live).

## Known limits and proposed fixes

* **L1 — symmetric-sequential ↔ symmetric-sequential never punches** (ss-ss: relay / none).
  Root cause: `race_paths_opt` (node/mod.rs) punches `their.addrs` (reflexive ports, private addresses)
  *before* the predicted ports. On a sequential NAT every new destination consumes the next port, so A's
  probe to B's prediction `b+k` leaves from `a+k+2` while B's probe to `a+k` leaves from `b+k+2` — the
  pairs never mirror. If both sides send to the predicted ports **first, in ascending order**, A's k-th
  probe is `a+k → b+k` and B's is `b+k → a+k`, which match for every k. Prototype in the lab
  (python, same NATs): current order 0/5 two-way holes, predicted-first 5/5 (n = 8 and 32). Fix: in
  `race_paths_opt`, when `their.nat` is `HardSequential`, call `net.punch(&predicted, sid)` before any
  other packet to the peer (and list predicted candidates first in `dial_direct`); optionally sweep 32–256
  predictions when both sides are sequential. Sequential ↔ cone/full-cone already works (prediction + spray).
* **L2 — recovery after NAT rebinding takes ~1 min, sometimes 2.** (a) An offer from a peer we still think
  is directly connected is answered but ignored (`node/conn.rs`, `if relayed_only == Some(false) return`),
  so the side that noticed first punches alone and fails; only after *both* QUIC idle timeouts (40 s)
  does a reconnect work. Treat such an offer as a path-repair request (dial/punch back without relay;
  dedupe keeps the better connection). (b) Offers after a rebinding carry the **stale** reflexive address
  (`ensure_info` caches 90 s): refresh `net.refresh_info()` when a direct connection dies before
  re-dialing. (c) After a failed 2 s auto-reconnect the next try is the 120 s sweep: retry with backoff
  (2, 5, 10, 20 s) for friends that just dropped.
* **L3 — dead paths are noticed only after the 40 s QUIC idle timeout** (`tls.rs`: keep-alive 10 s, idle
  40 s). A watchdog that re-offers when nothing was acknowledged for ~2 keep-alive periods (keeping the old
  connection until a new one wins) would bring L2 and the relay-death failover below ~20 s. Also: when a
  relay WebSocket closes, connections tunnelled through it (remote address `fd4c:756d:<idx>::/48`) could
  be closed and re-dialed immediately instead of idling out (peer-relay scenario: 60–65 s → a few s).
* **L4 — a new friend is not offered as a peer relay until the next connection**: `maybe_offer_relay` runs
  only in `on_connected`, so becoming friends while connected (the normal flow: chat first, then accept)
  never sends `RelayOffer`. Call it from `accept_contact` / on `FriendAccept` for every connected device.
  (Minor: two friends also offer *each other* as relays, which is useless for reaching each other.)
* **L5 — `connect` can report failure although a connection exists**: when both sides' attempts complete
  at the same time (spray endpoint + plain dial), the duplicate that `connect` holds may be closed by the
  peer before `setup_conn` opens its control stream; the surviving duplicate is installed by the accept
  side, but the API returns "can't reach". In `connect_inner`, if `setup_conn` fails and `self.peer(&peer)`
  is now `Some`, return that.
* **L6 — 1 Mbit/s links reach 55–90 % of line rate** and RTT climbs to seconds behind a full buffer
  (loss-based Cubic fills the queue). A delay-based controller (quinn's BBR,
  `TransportConfig::congestion_controller_factory`) would keep chat latency low during transfers.
* **L7 — random ↔ random (and sequential ↔ random) over IPv4 cannot be punched** by anyone; relay or a
  friend relay is required (IPv6 avoids it).
* Without STUN (`no-stun`) the "hopeless" shortcut is impossible, so relay-only cases wait `relay_delay`.

Notes:
* Birthday spraying (256 sockets / up to 4k probes) also runs for a **stranger's first contact** — the
  lab measured `direct` before the two nodes became friends in every spray case. It is bounded by
  `SPRAY_SEM` (one spray at a time) and the 20-offers-per-minute limit for strangers; the old claim that
  it was reserved for friends was wrong.
* When only a relayed path exists, both sides retry for a direct path every 30 s (and on demand via
  the `upgrade` command); the connection switches seamlessly.
* QUIC bit greasing (RFC 9287) is disabled: the port is shared with STUN/probes, which are
  recognised by exact magic values only.
