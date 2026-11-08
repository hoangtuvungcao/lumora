# Hard networks: mail delivery and blind circuits

Lumora connects devices directly (LAN, IPv6, IPv4 hole punching, port prediction, birthday
spraying). Two devices that are **both** behind symmetric NATs with random ports — most
mobile networks, a phone's Wi-Fi hotspot — can't be connected that way: such a NAT gives
every destination a fresh random port, so neither side can guess where to send. (NAT lab:
two-sided birthday spraying between two `symrand` NATs succeeds 0/10.) Since 1.0.9 three
layers cover that case, without any server of ours.

| Layer | What it carries | Code | Test |
|---|---|---|---|
| Sealed mail in pieces | every message, including photo messages with their preview (> 12 KB) | `node/file_mail.rs` (`Ext MAIL_PART`) | `core/tests/mail_only_e2e.py` |
| Files by mail | photos, voice messages, files ≤ 8 MB | `node/file_mail.rs` (`Ext FILE_MAIL_REQ` / `FILE_MAIL_CHUNK`) | `core/tests/mail_only_e2e.py` |
| Blind two-hop circuits | calls, big files, everything a connection carries | `net/circuit.rs`, `node/mod.rs` (`race_paths`) | NAT lab case `circuit` |

## Mail

Signaling mail (Nostr live mail, relay mailboxes, a friend's peer relay) carries ≤ 12 KB per
signal. A bigger sealed mail is cut into ≤ 9 KB pieces, each sealed again to the recipient;
the recipient keeps them (≤ 8 unfinished mails per sender, 10 min) and opens the whole mail
as if it had come in one signal. A download that doesn't start streaming within a few
seconds is asked for by mail: the sender sends 8 KB chunks (12/s, ~100 KB/s), the receiver
writes them at their offset in the `.part` file, asks again for missing chunks after 12 s of
silence, gives up (paused) after 15 min, and checks the offer's BLAKE3 hash. A stream that
starts meanwhile wins; whichever finishes first places the file. Files over 8 MB wait for a
connection (a circuit, a direct path later) and resume where they stopped.

## Blind circuits

```text
  A ──udp──▶ R1 ──udp──▶ R2 ◀──udp── B        QUIC A⇄B end to end, over the circuit
```

* **Volunteers** turn on *Giúp mạng Lumora* (`help_network`, off by default; `lumorad
  --help-network`). On an easy NAT with a known public address they announce `IP:port` on the
  BitTorrent DHT under a fixed info-hash (every ~15 min). That is all they publish.
* **Building** (friends and own devices only, after direct paths had their chance: 1.5 s
  when both NATs are hard, else 7 s; the lower device id builds, the other one 6 s later if
  still nothing): A picks R1 and R2 on different networks and a random 64-bit token, sends B
  `Ext CIRCUIT_INVITE {token, R2}` by sealed mail, sends `OPEN token → R2` to R1. B sends
  `JOIN token` to R2 (repeated, then every 15 s as a keepalive). R1 asks R2 `PROBE token`;
  R2 answers `ACK` only if B joined that token; only then R1 says `READY` to A and forwards
  anything. A relay never sends to an address that didn't ask for that token — circuits can't
  be used to flood a third party.
* **What a relay learns:** R1 sees A's address and R2's; R2 sees B's and R1's. No relay sees
  both ends. No relay sees an identity: the payload is the end-to-end QUIC connection (TLS 1.3
  encrypts the certificates; SNI is the constant `lumora.peer`), the token is random per circuit.
* **Bounds:** ≤ 256 slots per relay, ≤ 8 per source IP, 4 MB/s per slot, idle slots expire
  after 90 s, unused circuit ends after 120 s. A device relays only while the setting is on.
* **Wire:** UDP on the node's main port, a side packet like STUN and punch probes:
  `"\0LMC" | type | token (u64 BE) | payload` — OPEN 1 (payload: next hop `4|ip|port` /
  `6|ip|port`), JOIN 2, PROBE 3, ACK 4, READY 5, DATA 6 (a QUIC datagram). The first byte is 0,
  so QUIC (fixed bit set) is never mistaken for it.
* **Inside the node** a circuit end is a virtual relay index ≥ `0xC000` in `RelayRouter`; the
  path watchdog treats it as down only when the circuit itself is gone.

NAT lab (`sudo python3 nat-lab/run.py --case circuit`): A and B `symrand`, friends; C and D
volunteers on full-cone NATs, strangers to both; no server relay for data. Connects over the
circuit in ~2 s (with STUN) / ~7 s (without), chat both ways, a 5 MB file at ~40 Mbit/s;
neither volunteer has A or B in its contacts.
