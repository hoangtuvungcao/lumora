# NAT lab

Reproduces real-world networks on one Linux machine (network namespaces + iptables/ip6tables + tc) and
checks which path two real `lumorad` nodes end up using, how fast, and whether chat and a 5 MB file
transfer work over it.

```bash
cd core && cargo build -p lumora-cli --features media && cargo build -p lumora-relay
sudo python3 nat-lab/run.py --mode all            # 43 cases, 145 jobs (~25 min with 3 parallel worlds)
sudo python3 nat-lab/run.py --quick               # CI subset: 8 cases × {full, no-relay}, 1 trial (~70 s)
sudo python3 nat-lab/run.py --case pc-sr,v6-      # some cases (id or prefix), all their modes
sudo python3 nat-lab/run.py --list                # every case with the theory behind its expectation
```

Options: `--bin/--relay-bin` (binaries), `--mode` (one mode or `all`), `--trials N` (default 3; the
table shows the median), `--jobs N` (parallel isolated worlds, default 3), `--idle S` (keep-alive case,
default 180 s), `--no-file`, `--logs DIR`, `--json FILE`. Exit code 0 = every case behaved as expected.

## Emulated networks

| name | mapping / filtering (RFC 4787) | how | real-world equivalent |
|---|---|---|---|
| `fullcone` | EIM / endpoint-independent | `MASQUERADE` + DNAT of all inbound UDP | some old routers, DMZ |
| `addrcone` | EIM / address-dependent | `MASQUERADE` + `xt_recent` on peer IPs | some routers / firewalls |
| `portcone` | EIM / address+port-dependent | `MASQUERADE` + conntrack | **most home routers** |
| `symseq` | per-destination, sequential ports (+1) | `SNAT` round-robin (`statistic --mode nth`) over a port pool | older enterprise / some CGNAT |
| `symrand` | per-destination, random ports | `MASQUERADE --random-fully` | **4G / many CGNAT** |
| `udpblock` | — | portcone + drop all outbound UDP | strict corporate / school |
| `cgnat-eim/X`, `cgnat-sym/X` | home NAT X behind a carrier NAT (100.64/10) | two chained routers | FTTH with CGNAT, 4G |
| `v6+X` | v4 NAT X + global IPv6 behind a stateful firewall | `ip6tables` ESTABLISHED-only inbound | dual-stack ISPs (Viettel, VNPT, FPT) |

Special topologies: `samenat` (two hosts on one router), `samenat-iso` (two isolated segments of one
router, e.g. guest Wi-Fi), `samecgnat` (two homes behind the same carrier NAT); each with/without
hairpinning. Impairments (`tc netem` on one access link, both directions): 5 % loss, +300 ms RTT,
1 Mbit/s, all combined. Scenarios: 30 s NAT UDP timeout with 3 min idle + external-port rebinding on
each side; friend peer relay when the server relay dies; 10 attempts of two-sided birthday spraying.

## Modes

| mode | STUN | relay |
|---|---|---|
| `full` | 2 servers | signaling + data (after 4 s, or at once when hopeless) |
| `no-stun` | none (relay-observed IP + local port as a guess) | signaling + data |
| `no-relay` | 2 servers | signaling only ("P2P only") |
| `no-stun-no-relay` | none | signaling only |
| `lan-only` | none | none — LAN discovery only |

Path labels: `lan` (private address), `direct` (public IPv4, incl. hairpin), `v6`, `relay` (server),
`peer-relay` (a mutual friend), `none`.

Paste the printed Markdown table into `docs/src/dev/nat-traversal.md` when it changes. Everything is
torn down at the end (`l<N>-*` namespaces, `l<N>br` bridges); all firewall rules live inside the lab
namespaces, nothing is left on the host. Logs (one folder per case/mode/trial with each node's log)
and `results.json` stay in the log directory.
