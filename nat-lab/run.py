#!/usr/bin/env python3
"""Lumora NAT lab — emulates real-world networks with Linux network namespaces, iptables, ip6tables
and tc, then checks which path (LAN / direct / IPv6 / peer relay / relay / none) two real lumorad
nodes end up on, how fast, and whether chat + a 5 MB file transfer work over it.

    sudo python3 nat-lab/run.py --mode all  [--bin core/target/debug/lumorad] [--relay-bin ...]
    sudo python3 nat-lab/run.py --quick                 # small CI subset (~3 min)
    sudo python3 nat-lab/run.py --list                  # show every case with its theory
    sudo python3 nat-lab/run.py --case pc-sr,v6-sym     # only some cases (all their modes)

Topology (one isolated "world" per worker, several worlds run in parallel with --jobs):

    host ── home router ─┐                                       ┌─ pub 198.18.<w>.10/.11
    host ── home router ─┼── l<w>br  (198.18.<w>.0/24 "Internet")──┤  STUN ×2 + relay
    host ── home ── CGNAT┘           (2001:db8:ff0<w>::/64 IPv6)  └─

NAT behaviours (RFC 4787 terms: mapping / filtering):
  fullcone   EIM / endpoint-independent filtering   MASQUERADE + DNAT of all inbound UDP
  addrcone   EIM / address-dependent filtering      MASQUERADE + xt_recent (inbound from IPs we sent to)
  portcone   EIM / address+port-dependent filtering MASQUERADE + conntrack  (most home routers)
  symseq     APDM, sequential ports (+1 per new mapping)  SNAT nth round-robin over a port pool
  symrand    APDM, random ports                     MASQUERADE --random-fully  (many CGNAT / 4G)
  udpblock   portcone + all outbound UDP dropped     (strict corporate / school networks)
  cgnat-X/Y  home NAT Y behind a carrier NAT X (eim | sym), 100.64.0.0/10 in between
  v6+Y       dual stack: v4 NAT Y + global IPv6 behind a stateful firewall (inbound only after outbound)

Everything is torn down at the end (namespaces l<w>-*, bridges l<w>br); all iptables rules live inside
the lab namespaces, so nothing is left behind on the host.
"""
import argparse, hashlib, json, os, queue, re, shlex, statistics, subprocess, sys, tempfile, threading, time, traceback
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORTS = {"A": 40001, "B": 40002, "C": 40003}
SEQ_BASE, SEQ_N = 20000, 1024
SITE_IDX = {"A": 1, "B": 2, "C": 3}
FILE_MB = 5

MODES = {
    "full": dict(stun=True, relay=True, relay_delay=4000, lan=False),
    "no-stun": dict(stun=False, relay=True, relay_delay=4000, lan=False),
    # relay still carries the (sealed) signaling, never data: "P2P only"
    "no-relay": dict(stun=True, relay=True, relay_delay=600000, lan=False),
    "no-stun-no-relay": dict(stun=False, relay=True, relay_delay=600000, lan=False),
    # no server at all: LAN discovery is the only way to find the peer
    "lan-only": dict(stun=False, relay=False, relay_delay=600000, lan=True),
}
STD = ["full", "no-stun", "no-relay", "no-stun-no-relay"]

# ───────────────────────────── cases ─────────────────────────────
# expect: path class(es) with STUN + relay; "|" = any of them is fine (informational cases).
# In P2P-only modes "relay" becomes "none" automatically.
CASES = [
    # 1-3 cone flavours
    dict(id="fc-fc", a="fullcone", b="fullcone", expect="direct", theory="EIM+EIF both sides: any packet to the mapped port gets in."),
    dict(id="fc-sr", a="fullcone", b="symrand", expect="direct", theory="Full cone accepts the symmetric side's new mapping; no spray needed."),
    dict(id="ac-ac", a="addrcone", b="addrcone", expect="direct", theory="EIM+ADF: one probe to the peer IP opens the filter for all its ports."),
    dict(id="ac-sr", a="addrcone", b="symrand", expect="direct", theory="ADF only checks the IP, so the symmetric side's unpredictable port is accepted."),
    dict(id="pc-pc", a="portcone", b="portcone", expect="direct", quick=True, theory="EIM+APDF (typical home router): simultaneous open works because mapping is endpoint independent."),
    dict(id="pc-sr", a="portcone", b="symrand", expect="direct", quick=True, theory="APDF vs random APDM: needs the birthday attack (256 hard sockets × ~4000 easy probes ≈ 98%)."),
    dict(id="sr-pc", a="symrand", b="portcone", expect="direct", theory="Same as pc-sr, dialled from the symmetric side."),
    # 4 sequential symmetric
    dict(id="ss-pc", a="symseq", b="portcone", expect="direct", quick=True, theory="Sequential APDM: next ports are predictable (delta from 2 STUN servers) → port prediction."),
    dict(id="pc-ss", a="portcone", b="symseq", expect="direct", theory="Same, dialled from the cone side."),
    dict(id="ss-fc", a="symseq", b="fullcone", expect="direct", theory="Full cone accepts anything."),
    dict(id="ss-ss", a="symseq", b="symseq", expect="direct|relay", theory="Both predictable: prediction on both sides may line up; not guaranteed (informational)."),
    dict(id="ss-sr", a="symseq", b="symrand", expect="relay", theory="Random side is unpredictable and filters by port: needs a 1/65536 guess → relay."),
    # 5 symmetric random vs others
    dict(id="sr-fc", a="symrand", b="fullcone", expect="direct", theory="Full cone accepts the random mapping."),
    dict(id="sr-ac", a="symrand", b="addrcone", expect="direct", theory="Address-restricted cone accepts any port from a contacted IP."),
    dict(id="sr-sr", a="symrand", b="symrand", expect="relay", quick=True, theory="Random APDM + APDF on both sides: ~2^32 combinations → relay is the only way."),
    # 6 double NAT / CGNAT
    dict(id="cge-pc", a="cgnat-eim/portcone", b="portcone", expect="direct", theory="Home NAT behind an EIM CGNAT is still EIM end to end (ports preserved twice)."),
    dict(id="cge-cge", a="cgnat-eim/portcone", b="cgnat-eim/portcone", expect="direct", theory="Two EIM double NATs (different carriers)."),
    dict(id="cgs-pc", a="cgnat-sym/portcone", b="portcone", expect="direct", quick=True, theory="Typical 4G / FTTH CGNAT with random ports vs a home router → birthday spray."),
    dict(id="cgs-cge", a="cgnat-sym/portcone", b="cgnat-eim/portcone", expect="direct", theory="4G (random CGNAT) vs FTTH (EIM CGNAT): one hard side → birthday spray."),
    dict(id="cgs-cgs", a="cgnat-sym/portcone", b="cgnat-sym/portcone", expect="relay", theory="Two random CGNATs: hard ↔ hard."),
    dict(id="samecg", topo="samecgnat", a="portcone", b="portcone", expect="relay", theory="Two homes behind the SAME carrier NAT without hairpinning: the shared public IP is unusable, private IPs are in different homes."),
    dict(id="samecg-hp", topo="samecgnat", hairpin=True, a="portcone", b="portcone", expect="direct", theory="Same carrier NAT with hairpinning (RFC 6888 REQ-9): reflexive addresses work inside the CGNAT."),
    # 7 both behind the same NAT
    dict(id="samenat", topo="samenat", a="portcone", b="portcone", expect="lan", quick=True, theory="Same router, same LAN: host candidates are exchanged in the offer → LAN path."),
    dict(id="samenat-hp", topo="samenat", hairpin=True, a="portcone", b="portcone", expect="lan", theory="With hairpin the public path also works, but LAN candidates are preferred."),
    dict(id="iso", topo="samenat-iso", a="portcone", b="portcone", expect="relay", theory="Same router, isolated segments (guest Wi-Fi / AP isolation), no hairpin → no direct path."),
    dict(id="iso-hp", topo="samenat-iso", hairpin=True, a="portcone", b="portcone", expect="direct", theory="Isolated segments but the router hairpins → via the public address."),
    # 8 same LAN, discovery only (no server of any kind)
    dict(id="lan-mc", topo="samenat", a="portcone", b="portcone", expect="lan", modes=["lan-only"], flags=["--no-mdns"], theory="Raw multicast announcements (239.255.76.77) find the peer with no Internet servers."),
    dict(id="lan-mdns", topo="samenat", a="portcone", b="portcone", expect="lan", modes=["lan-only"], flags=["--no-lan-multicast"], theory="Bonjour/DNS-SD (_lumora._udp) alone finds the peer."),
    # 9 IPv6
    dict(id="v6-sym", a="v6+symrand", b="v6+symrand", expect="v6", quick=True, theory="v4 is hard↔hard, but global IPv6 behind stateful firewalls punches like a cone (no address translation)."),
    dict(id="v6-pc", a="v6+portcone", b="v6+portcone", expect="v6", theory="Both families work; IPv6 candidates are preferred."),
    dict(id="v6-v4", a="v6+portcone", b="portcone", expect="direct", theory="IPv6 on one side only: falls back to v4 hole punching."),
    dict(id="v6-v4sym", a="v6+symrand", b="portcone", expect="direct", theory="IPv6 on one side only + v4 symmetric: v4 birthday spray."),
    # 10 UDP blocked
    dict(id="ub-pc", a="udpblock", b="portcone", expect="relay", quick=True, theory="No UDP at all: only the relay over WebSocket/TCP (still E2E QUIC/TLS) works."),
    dict(id="ub-sr", a="udpblock", b="symrand", expect="relay", theory="Same with a symmetric peer."),
    # 11 impairments on a working path (A's access link, both directions)
    dict(id="imp-loss", a="portcone", b="portcone", expect="direct", modes=["full", "no-relay"], impair="loss 5%", theory="5% loss each way: QUIC retransmits; handshake may need a retry."),
    dict(id="imp-rtt", a="portcone", b="portcone", expect="direct", modes=["full", "no-relay"], impair="delay 150ms", theory="+300 ms RTT (satellite / bad 3G)."),
    dict(id="imp-1m", a="portcone", b="portcone", expect="direct", modes=["full", "no-relay"], impair="rate 1mbit limit 60", theory="1 Mbit/s with a ~0.7 s buffer: 5 MB should take ≈45 s."),
    dict(id="imp-all", a="portcone", b="portcone", expect="direct", modes=["full", "no-relay"], impair="delay 150ms loss 5% rate 1mbit limit 60", theory="All three at once."),
    dict(id="imp-sr", a="symrand", b="portcone", expect="direct", modes=["full", "no-relay"], impair="delay 150ms loss 5%", theory="Birthday spray through a lossy 300 ms link."),
    # 12 NAT mapping timeout + rebinding
    dict(id="keepalive", kind="keepalive", a="portcone", b="portcone", expect="direct", modes=["full", "no-relay"], theory="30 s UDP timeout: 10 s QUIC keep-alives keep the hole open; after the external port changes the path must come back."),
    # 13 friend peer relay + two-sided birthday
    dict(id="peer-relay", kind="peerrelay", a="symrand", b="symrand", c="portcone", expect="peer-relay", modes=["full"], theory="Hard↔hard with a mutual friend on an easy NAT: the friend relays (E2E encrypted), no server."),
    dict(id="peer-relay-live", kind="peerrelay", restart=False, a="symrand", b="symrand", c="portcone", expect="peer-relay", modes=["full"], theory="Same, but the friendships are made while already connected (no app restart): the friend must offer relaying as soon as it becomes a friend."),
    dict(id="bday-sr", a="symrand", b="symrand", expect="direct|none", modes=["no-stun-no-relay"], trials=10, nofile=True, theory="No STUN → both sides play both birthday roles; vs two random NATs success should be ~0."),
]


def expected(case, mode):
    e = case["expect"]
    if MODES[mode]["relay_delay"] >= 600000:
        e = "|".join(sorted(set("none" if x in ("relay", "peer-relay") else x for x in e.split("|"))))
    return e


# ───────────────────────────── shell helpers ─────────────────────────────
def sh(cmd, check=True, inp=None):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, input=inp)
    if check and r.returncode != 0:
        raise RuntimeError(f"{cmd}\n{r.stderr}")
    return r.stdout


def ns(n, cmd, check=True, inp=None):
    return sh(f"ip netns exec {n} sh -c {shlex.quote(cmd)}", check, inp)


def teardown_all():
    for line in sh("ip netns list", check=False).splitlines():
        n = line.split()[0]
        if re.match(r"^l\d*-", n):
            sh(f"ip netns del {n}", check=False)
    for line in sh("ip -o link show", check=False).splitlines():
        name = line.split(":")[1].strip().split("@")[0]
        if re.match(r"^l\d*(br|p\d+)$", name) or name == "br-lpub" or name.startswith("l-"):
            sh(f"ip link del {name}", check=False)


# ───────────────────────────── topology ─────────────────────────────
class World:
    """One isolated Internet: a bridge, a pub namespace (2 STUN + relay) and the sites of one case."""

    def __init__(self, w, relay_bin, logdir):
        self.w, self.relay_bin, self.logdir = w, relay_bin, logdir
        self.br = f"l{w}br"
        self.npub = 0
        self.npubip = 0
        self.sites = []      # namespaces of the current case
        self.v6nets = []     # (prefix, via) routes every v6 pub-attached ns needs
        self.v6pub = []      # namespaces on the public segment with IPv6
        self.relays = []
        # every world has its own public addresses: the root conntrack (br_netfilter) sees all bridges
        self.n4, self.n6 = f"198.18.{w}", f"2001:db8:{0xff00 + w:x}"
        self.relay_url = f"ws://{self.n4}.10:8443/ws"
        self.stun = f"{self.n4}.10:3478,{self.n4}.11:3478"
        sh(f"ip link add {self.br} type bridge && ip link set {self.br} up")
        self.pub = self.mkns("pub", case=False)
        self.attach_pub(self.pub, "eth0", f"{self.n4}.10", f"{self.n6}::10")
        ns(self.pub, f"ip addr add {self.n4}.11/24 dev eth0")
        self.start_relays()

    def start_relays(self):
        log = open(os.path.join(self.logdir, f"relay-w{self.w}.log"), "a")
        for ip, port in ((f"{self.n4}.10", 8443), (f"{self.n4}.11", 8444)):
            self.relays.append(subprocess.Popen(
                ["ip", "netns", "exec", self.pub, self.relay_bin, "--listen", f"{ip}:{port}", "--stun-port", "3478", "--stun-bind", ip],
                stdout=log, stderr=subprocess.STDOUT))
        time.sleep(0.8)

    def stop_relays(self):
        for r in self.relays:
            r.terminate()
            try:
                r.wait(5)
            except Exception:
                r.kill()
        self.relays = []

    def name(self, s):
        return f"l{self.w}-{s}"

    def mkns(self, s, case=True):
        n = self.name(s)
        sh(f"ip netns add {n}")
        ns(n, "ip link set lo up; sysctl -qw net.ipv6.conf.all.accept_dad=0 net.ipv6.conf.default.accept_dad=0")
        if case:
            self.sites.append(n)
        return n

    def attach_pub(self, n, ifname, ip, ip6=None):
        self.npub += 1
        rootif = f"l{self.w}p{self.npub}"
        sh(f"ip link add {rootif} type veth peer name {ifname} netns {n}")
        sh(f"ip link set {rootif} master {self.br} up")
        ns(n, f"ip addr add {ip}/24 dev {ifname} && ip link set {ifname} up")
        if ip6:
            ns(n, f"ip -6 addr add {ip6}/64 dev {ifname} nodad")
            self.v6pub.append(n)

    def pub_ip(self):
        self.npubip += 1
        return f"{self.n4}.{20 + self.npubip}", f"{self.n6}::{20 + self.npubip:x}"

    def clear(self):
        for n in self.sites:
            sh(f"ip netns pids {n} | xargs -r kill -9", check=False)
            sh(f"ip netns del {n}", check=False)
        self.sites = []
        self.v6nets = []
        self.v6pub = [self.pub]
        ns(self.pub, "ip -6 route flush proto static", check=False)
        self.npubip = 0
        time.sleep(0.2)

    def finish_v6(self):
        for pfx, via, owner in self.v6nets:
            for n in self.v6pub:
                if n != owner:
                    ns(n, f"ip -6 route add {pfx} via {via} proto static", check=False)

    def close(self):
        self.stop_relays()
        self.clear()
        sh(f"ip netns del {self.pub}", check=False)
        sh(f"ip link del {self.br}", check=False)


class Host:
    def __init__(self, ns_, ifname, ip, router=None, rif=None):
        self.ns, self.ifname, self.ip, self.router, self.rif = ns_, ifname, ip, router, rif


class Router:
    """A NAT box. `up` = parent router (CGNAT) or None (public segment)."""

    def __init__(self, world, tag, kind, prefix, up=None, segs=1, v6=False, hairpin=False):
        self.world, self.kind, self.hairpin = world, kind, hairpin
        self.ns = world.mkns(tag)
        self.prefixes = [prefix] if segs == 1 else [".".join(prefix.split(".")[:2] + [str(s)]) for s in range(segs)]
        self.n = 0
        self.children = []   # (ip, port) behind us, for full-cone DNAT / hairpin
        self.v6 = v6
        ns(self.ns, "sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1")
        ns(self.ns, "sysctl -qw net.bridge.bridge-nf-call-iptables=0 net.bridge.bridge-nf-call-ip6tables=0", check=False)
        if up is None:
            self.wan_ip, wan6 = world.pub_ip()
            world.attach_pub(self.ns, "wan", self.wan_ip, wan6 if v6 else None)
            self.wan6 = wan6
        else:
            self.wan_ip, _ = up.attach(self.ns, "wan")
        for s, pfx in enumerate(self.prefixes):
            ns(self.ns, f"ip link add lan{s} type bridge && ip link set lan{s} up && ip addr add {pfx}.1/24 dev lan{s}")
        if v6:
            idx = len(world.v6nets) + 1
            self.v6pfx = f"2001:db8:{0x100 * world.w + idx:x}"
            ns(self.ns, f"ip -6 addr add {self.v6pfx}::1/64 dev lan0 nodad")
            world.v6nets.append((f"{self.v6pfx}::/64", self.wan6, self.ns))

    def attach(self, child, ifname, seg=0, v6=False):
        self.n += 1
        rif = f"p{self.n}"
        pfx = self.prefixes[seg]
        ip = f"{pfx}.{1 + self.n}"
        sh(f"ip -n {self.ns} link add {rif} type veth peer name {ifname} netns {child}")
        ns(self.ns, f"ip link set {rif} master lan{seg} up")
        ns(child, f"ip addr add {ip}/24 dev {ifname} && ip link set {ifname} up && ip route add default via {pfx}.1")
        if v6 and self.v6:
            ns(child, f"ip -6 addr add {self.v6pfx}::{1 + self.n:x}/64 dev {ifname} nodad && ip -6 route add default via {self.v6pfx}::1")
        return ip, rif

    def finalize(self, ports=()):
        """Install the NAT + firewall. `ports` = [(inside ip, port)] for hairpinning."""
        R, k, wan = self.ns, self.kind, self.wan_ip
        nat = ["*nat"]
        if k == "symseq":
            nat.append(":SEQ - [0:0]")
            nat.append("-A POSTROUTING -o wan -p udp -j SEQ")
            for j in range(SEQ_N):
                nat.append(f"-A SEQ -p udp -m statistic --mode nth --every {SEQ_N - j} --packet 0 -j SNAT --to-source {wan}:{SEQ_BASE + j}")  # 1st new flow → rule 0
        nat.append("-A POSTROUTING -o wan -j MASQUERADE" + (" --random-fully" if k == "symrand" else ""))
        inside = self.children[0][0] if self.children else None
        mangle = ["*mangle"]
        if k == "fullcone" and inside:
            nat.append(f"-A PREROUTING -i wan -p udp -j DNAT --to-destination {inside}")
        if k == "addrcone" and inside:
            mangle.append("-A FORWARD -o wan -p udp -m recent --name adf --rdest --set")
            nat.append(f"-A PREROUTING -i wan -p udp -m recent --name adf --rsource --rcheck --seconds 600 -j DNAT --to-destination {inside}")
        if self.hairpin:
            for ip, port in ports:
                nat.append(f"-A PREROUTING -i lan+ -d {wan} -p udp --dport {port} -j DNAT --to-destination {ip}")
            for pfx in self.prefixes:
                nat.append(f"-I POSTROUTING 1 -o lan+ -s {pfx}.0/24 -p udp -m conntrack --ctstate DNAT -j SNAT --to-source {wan}")
        flt = ["*filter"]
        if k == "udpblock":
            flt.append("-A FORWARD -i lan+ -p udp -j DROP")
        flt += ["-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT",
                "-A FORWARD -m conntrack --ctstate DNAT -j ACCEPT",
                "-A FORWARD -i wan -j DROP"]
        if len(self.prefixes) > 1:   # client isolation between segments
            flt += ["-A FORWARD -i lan0 -o lan1 -j DROP", "-A FORWARD -i lan1 -o lan0 -j DROP"]
        flt += ["-A INPUT -i wan -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT", "-A INPUT -i wan -j DROP"]
        ns(R, "iptables-restore", inp="\n".join(nat + ["COMMIT"] + mangle + ["COMMIT"] + flt + ["COMMIT"]) + "\n")
        if self.v6:   # stateful IPv6 firewall, no translation
            ns(R, "ip6tables-restore", inp="\n".join([
                "*filter",
                "-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT",
                "-A FORWARD -i wan -j DROP",
                "-A INPUT -i wan -p ipv6-icmp -j ACCEPT",
                "-A INPUT -i wan -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT",
                "-A INPUT -i wan -j DROP",
                "COMMIT"]) + "\n")

    def set_udp_timeout(self, s):
        ns(self.ns, f"sysctl -qw net.netfilter.nf_conntrack_udp_timeout={s} net.netfilter.nf_conntrack_udp_timeout_stream={s}")

    def rebind(self, lo):
        """Change the external port of every UDP flow: new mappings come from lo..lo+999 and
        all current mappings are dropped (address flap → MASQUERADE flushes its conntracks)."""
        ns(self.ns, f"iptables -t nat -I POSTROUTING 1 -o wan -p udp -j MASQUERADE --to-ports {lo}-{lo + 999}")
        ns(self.ns, f"ip addr del {self.wan_ip}/24 dev wan && ip addr add {self.wan_ip}/24 dev wan")


def parse_spec(spec):
    v6 = spec.startswith("v6+")
    return v6, spec[3:] if v6 else spec


def build(world, case, tags=("A", "B")):
    """Build the case's topology; returns {tag: Host} and the routers."""
    world.clear()
    topo = case.get("topo", "pair")
    hosts, routers = {}, []
    if topo == "pair":
        for t in tags:
            spec = case[t.lower()]
            v6, kind = parse_spec(spec)
            i = SITE_IDX[t]
            h = world.mkns(f"h{t}")
            if kind.startswith("cgnat-"):
                cg, home = kind[6:].split("/")
                cgr = Router(world, f"cg{t}", "symrand" if cg == "sym" else "portcone", f"100.64.{i}")
                r = Router(world, f"r{t}", home, f"10.{i}.0", up=cgr)
                cgr.children.append((r.wan_ip, PORTS[t]))
                routers += [cgr, r]
            else:
                r = Router(world, f"r{t}", kind, f"10.{i}.0", v6=v6)
                routers.append(r)
            ip, rif = r.attach(h, "eth0", v6=v6)
            r.children.append((ip, PORTS[t]))
            hosts[t] = Host(h, "eth0", ip, r, rif)
    elif topo in ("samenat", "samenat-iso"):
        iso = topo == "samenat-iso"
        r = Router(world, "r0", case["a"], "10.9.0", segs=2 if iso else 1, hairpin=case.get("hairpin", False))
        routers.append(r)
        for s, t in enumerate(tags):
            h = world.mkns(f"h{t}")
            ip, rif = r.attach(h, "eth0", seg=s if iso else 0)
            r.children.append((ip, PORTS[t]))
            hosts[t] = Host(h, "eth0", ip, r, rif)
    elif topo == "samecgnat":
        cg = Router(world, "cg0", "portcone", "100.64.9", hairpin=case.get("hairpin", False))
        routers.append(cg)
        for t in tags:
            i = SITE_IDX[t]
            r = Router(world, f"r{t}", case[t.lower()], f"10.{i}.0", up=cg)
            cg.children.append((r.wan_ip, PORTS[t]))
            h = world.mkns(f"h{t}")
            ip, rif = r.attach(h, "eth0")
            r.children.append((ip, PORTS[t]))
            routers.append(r)
            hosts[t] = Host(h, "eth0", ip, r, rif)
    for r in routers:
        r.finalize(r.children)
    world.finish_v6()
    if case.get("impair"):
        h = hosts["A"]
        ns(h.ns, f"tc qdisc add dev {h.ifname} root netem {case['impair']}")
        ns(h.router.ns, f"tc qdisc add dev {h.rif} root netem {case['impair']}")
    return hosts, routers


# ───────────────────────────── lumorad driver ─────────────────────────────
class Node:
    def __init__(self, world, host, binary, data, name, mode, port, flags=()):
        m = MODES[mode]
        os.makedirs(data, exist_ok=True)
        args = ["ip", "netns", "exec", host.ns, binary, "--data", data, "--name", name, "--port", str(port),
                "--no-nostr", "--no-dht", "--no-upnp", "--stun", world.stun if m["stun"] else "",
                "--relay-delay", str(m["relay_delay"]), "--stdio"]
        if m["relay"]:
            args += ["--relay", world.relay_url]
        if not m["lan"]:
            args.append("--no-lan")
        args += list(flags)
        self.args, self.data = args, data
        self.log = open(os.path.join(data, "node.log"), "a")
        self.q = {}
        self.cv = threading.Condition()
        self.i = 0
        self._spawn()

    def _spawn(self):
        self.p = subprocess.Popen(self.args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, text=True, bufsize=1)
        threading.Thread(target=self._r, args=(self.p,), daemon=True).start()

    def _r(self, p):
        for line in p.stdout:
            try:
                v = json.loads(line)
            except Exception:
                continue
            if "id" in v and "event" not in v:
                with self.cv:
                    self.q[v["id"]] = v
                    self.cv.notify_all()

    def call(self, cmd, timeout=60, **kw):
        with self.cv:
            self.i += 1
            i = self.i
        kw.update(id=i, cmd=cmd)
        self.p.stdin.write(json.dumps(kw) + "\n")
        self.p.stdin.flush()
        end = time.time() + timeout
        with self.cv:
            while i not in self.q:
                if time.time() > end:
                    raise TimeoutError(cmd)
                self.cv.wait(0.5)
            r = self.q.pop(i)
        if not r["ok"]:
            raise RuntimeError(r["error"])
        return r["data"]

    def peer_status(self, peer):
        for p in self.call("net_status")["peers"]:
            if p["peer"] == peer:
                return p
        return None

    def stop(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()
            try:
                self.p.wait(3)
            except Exception:
                pass

    def restart(self):
        self.stop()
        self._spawn()


def classify(path, remote):
    """direct / v6 / lan / relay / peer-relay from a `connect` answer."""
    remote = remote or ""
    if path == "relay":
        m = re.match(r"\[fd4c:756d:([0-9a-f]+):", remote)
        return "peer-relay" if m and int(m.group(1), 16) >= 1000 else "relay"
    if path == "lan":
        return "lan"
    host = remote.rsplit(":", 1)[0].strip("[]")
    if ":" in host and not host.startswith("::ffff:"):
        return "v6"
    return "direct"


def wait_until(fn, timeout, step=0.1):
    end = time.time() + timeout
    while time.time() < end:
        try:
            v = fn()
            if v:
                return v
        except Exception:
            pass
        time.sleep(step)
    return None


def friends_first(X, Y, px, py, restart=True, timeout=60):
    """IP privacy: a stranger gets no address and no packet, so pairs become friends first —
    X's request travels as sealed signaling mail (or over a relay-only connection) — then both
    restart so the measured `connect` starts from nothing (cached addresses only)."""
    X.call("add_contact", target=py)
    wait_until(lambda: any(c["peer"] == px and c["status"] == 2 for c in Y.call("contacts")), timeout, 0.25)
    Y.call("accept_contact", peer=px)
    wait_until(lambda: any(c["peer"] == py and c["status"] == 3 for c in X.call("contacts")), timeout, 0.25)
    if restart:
        X.restart()
        Y.restart()
        X.call("me")
        Y.call("me")


def befriend(X, Y, px, py):
    X.call("add_contact", target=py)
    time.sleep(1.0)
    Y.call("accept_contact", peer=px)
    time.sleep(1.0)


def chat_test(S, R, ps, pr, text, timeout=60):
    """S sends to R; returns delivery latency in ms (None if not delivered)."""
    t0 = time.time()
    S.call("send_text", conv=f"d:{pr}", text=text)
    ok = wait_until(lambda: any(text in json.dumps(m, ensure_ascii=False) for m in R.call("messages", conv=f"d:{ps}", limit=20)), timeout, 0.05)
    return round((time.time() - t0) * 1000) if ok else None


def file_test(S, R, pr, data_dir, timeout=300):
    src = os.path.join(data_dir, "payload.bin")
    with open(src, "wb") as f:
        f.write(os.urandom(FILE_MB * 1024 * 1024))
    h = hashlib.sha256(open(src, "rb").read()).hexdigest()
    t0 = time.time()
    fid = S.call("send_file", conv=f"d:{pr}", path=src)["id"]
    r = wait_until(lambda: [x for x in R.call("files") if x["id"] == fid and x["state"] == 2], timeout, 0.25)
    dt = time.time() - t0
    os.unlink(src)
    if not r:
        return dict(ok=False, s=None, mbps=None)
    path = r[0]["path"]
    ok = hashlib.sha256(open(path, "rb").read()).hexdigest() == h
    try:
        os.unlink(path)
    except Exception:
        pass
    return dict(ok=ok, s=round(dt, 1), mbps=round(FILE_MB * 8 / dt, 1))


# ───────────────────────────── scenarios ─────────────────────────────
def trial_pair(world, case, mode, trial, do_file, cfg):
    hosts, routers = build(world, case)
    exp = expected(case, mode)
    d = os.path.join(cfg.logdir, f"{case['id']}.{mode}.{trial}")
    A = B = None
    res = dict(trial=trial)
    try:
        A = Node(world, hosts["A"], cfg.bin, os.path.join(d, "A"), "A", mode, PORTS["A"], case.get("flags", ()))
        B = Node(world, hosts["B"], cfg.bin, os.path.join(d, "B"), "B", mode, PORTS["B"], case.get("flags", ()))
        pa, pb = A.call("me")["peer"], B.call("me")["peer"]
        time.sleep(6.0 if MODES[mode]["lan"] else 2.5)   # relay hello + STUN (LAN: first announcements)
        friends_first(B, A, pb, pa)
        time.sleep(6.0 if MODES[mode]["lan"] else 2.5)
        res["natA"] = A.call("refresh_net")["nat"]
        res["natB"] = B.call("refresh_net")["nat"]
        t0 = time.time()
        try:
            r = B.call("connect", peer=pa, timeout=50)
        except Exception as e:
            res.update(path="none", err=str(e)[:160])
            return res
        res["t_connect"] = time.time() - t0
        res["first"] = classify(r["path"], r.get("remote_addr"))
        final = res["first"]
        res["t_final"] = res["t_connect"]
        wants_direct = any(x in exp for x in ("direct", "v6", "lan"))
        if final in ("relay", "peer-relay") and wants_direct:
            t1 = time.time()
            try:
                u = B.call("upgrade", peer=pa, timeout=45)
                if u["path"] != "relay":
                    st = B.peer_status(pa)
                    final = classify(st["path"], st["remote_addr"]) if st else "direct"
                    res["t_final"] = res["t_connect"] + (time.time() - t1)
            except Exception:
                pass
        res["path"] = final
        res["chat_ms"] = chat_test(B, A, pb, pa, f"xin chào qua NAT {trial}")
        res["chat_back_ms"] = chat_test(A, B, pa, pb, f"chào lại {trial}")
        if do_file:
            res["file"] = file_test(B, A, pa, d)
        st = B.peer_status(pa)
        res["rtt"] = st["rtt_ms"] if st else None
        if st and st["path"] != "relay":
            res["path"] = classify(st["path"], st["remote_addr"])
        return res
    finally:
        for n in (A, B):
            if n:
                n.stop()


def scenario_keepalive(world, case, mode, cfg):
    """30 s NAT UDP timeout: idle ≥ cfg.idle s, then rebinding on each side."""
    hosts, routers = build(world, case)
    for r in routers:
        r.set_udp_timeout(30)
    d = os.path.join(cfg.logdir, f"{case['id']}.{mode}")
    A = Node(world, hosts["A"], cfg.bin, os.path.join(d, "A"), "A", mode, PORTS["A"])
    B = Node(world, hosts["B"], cfg.bin, os.path.join(d, "B"), "B", mode, PORTS["B"])
    out = dict(trial=1)
    try:
        pa, pb = A.call("me")["peer"], B.call("me")["peer"]
        time.sleep(2.5)
        friends_first(B, A, pb, pa)
        time.sleep(2.5)
        out["natA"], out["natB"] = A.call("refresh_net")["nat"], B.call("refresh_net")["nat"]
        t0 = time.time()
        r = B.call("connect", peer=pa, timeout=50)
        out["t_connect"] = out["t_final"] = time.time() - t0
        out["first"] = classify(r["path"], r.get("remote_addr"))
        if out["first"] == "relay":
            try:
                B.call("upgrade", peer=pa, timeout=45)
            except Exception:
                pass
        st = B.peer_status(pa)
        out["path"] = classify(st["path"], st["remote_addr"]) if st else "none"
        sa = A.peer_status(pb)
        out["remotes"] = f"B sees {st and st['remote_addr']}, A sees {sa and sa['remote_addr']}"
        print(f"  [w{world.w}] keepalive/{mode}: connected {out['path']}, idling {cfg.idle}s …", flush=True)
        time.sleep(cfg.idle)
        st = B.peer_status(pa)
        out["idle_survived"] = bool(st and st["since_s"] >= cfg.idle)
        out["idle_since_s"] = st and st["since_s"]
        out["chat_ms"] = chat_test(B, A, pb, pa, "vẫn còn đây sau 3 phút")
        # rebinding: change the external port of A, then of B
        for side, R, S, ps, pr, lo in (("A", hosts["A"].router, A, pa, pb, 50000), ("B", hosts["B"].router, B, pb, pa, 52000)):
            before = B.peer_status(pa)
            before_since = before["since_s"] if before else 0
            t1 = time.time()
            R.rebind(lo)
            # the peer on the other side keeps talking; A→B message must arrive again
            txt = f"sau khi đổi cổng {side}"
            other, po = (B, pb) if S is A else (A, pa)
            ms = chat_test(S, other, ps, po, txt, timeout=150)
            stb = B.peer_status(pa)
            reconnected = bool(stb and stb["since_s"] < time.time() - t1 + 1)
            out[f"rebind_{side}"] = dict(
                delivered_ms=ms,
                how="new connection" if reconnected else "same connection (migrated)",
                path=classify(stb["path"], stb["remote_addr"]) if stb else "none",
                remote=stb and stb["remote_addr"])
            print(f"  [w{world.w}] keepalive/{mode}: rebind {side} → {out[f'rebind_{side}']}", flush=True)
        out["file"] = file_test(B, A, pa, d)
        st = B.peer_status(pa)
        out["rtt"] = st and st["rtt_ms"]
        return out
    finally:
        A.stop()
        B.stop()


def scenario_peer_relay(world, case, mode, cfg):
    """A, B hard (symmetric random); C a mutual friend on an easy NAT. Then the server relay dies."""
    hosts, routers = build(world, case, tags=("A", "B", "C"))
    d = os.path.join(cfg.logdir, f"{case['id']}.{mode}")
    N = {t: Node(world, hosts[t], cfg.bin, os.path.join(d, t), t, mode, PORTS[t]) for t in "ABC"}
    A, B, C = N["A"], N["B"], N["C"]
    out = dict(trial=1)
    try:
        P = {t: N[t].call("me")["peer"] for t in "ABC"}
        time.sleep(2.5)
        out["natA"], out["natB"] = A.call("refresh_net")["nat"], B.call("refresh_net")["nat"]
        C.call("refresh_net")
        for x, y in (("A", "C"), ("B", "C"), ("A", "B")):
            friends_first(N[x], N[y], P[x], P[y], restart=False)
        # relay offers are made when a connection to a *friend* comes up → restart once
        if case.get("restart", True):
            for t in "ABC":
                N[t].restart()
            for t in "ABC":
                N[t].call("me")
        def has_peer_relay(n):
            return any(r["url"].startswith("peer:") and r["connected"] for r in n.call("net_status")["relays"])
        t0 = time.time()
        okA = wait_until(lambda: has_peer_relay(A), 90, 0.5)
        okB = wait_until(lambda: has_peer_relay(B), 90, 0.5)
        out["peer_relay_ready_s"] = round(time.time() - t0, 1) if okA and okB else None
        out["first"] = "peer relay registered" if okA and okB else f"peer relay missing (A={bool(okA)}, B={bool(okB)})"
        # the server relay goes away
        world.stop_relays()
        t1 = time.time()
        def ab_path():
            st = B.peer_status(P["A"])
            return st
        # wait until A–B are connected again over something that is not the dead server relay
        r = None
        end = time.time() + 120
        while time.time() < end:
            try:
                r = B.call("connect", peer=P["A"], timeout=50)
                if classify(r["path"], r.get("remote_addr")) != "relay":
                    break
            except Exception:
                r = None
            time.sleep(1)
        out["t_connect"] = out["t_final"] = time.time() - t1
        out["path"] = classify(r["path"], r.get("remote_addr")) if r else "none"
        if out["path"] == "none":
            return out
        out["chat_ms"] = chat_test(B, A, P["B"], P["A"], "qua bạn chung")
        out["chat_back_ms"] = chat_test(A, B, P["A"], P["B"], "nhận rồi")
        out["file"] = file_test(B, A, P["A"], d)
        st = B.peer_status(P["A"])
        out["rtt"] = st and st["rtt_ms"]
        return out
    finally:
        for n in N.values():
            n.stop()
        if not world.relays:
            world.start_relays()


# ───────────────────────────── runner ─────────────────────────────
def run_job(world, case, mode, cfg):
    kind = case.get("kind", "pair")
    exp = expected(case, mode)
    try:
        if kind == "keepalive":
            trials = [scenario_keepalive(world, case, mode, cfg)]
        elif kind == "peerrelay":
            trials = [scenario_peer_relay(world, case, mode, cfg)]
        else:
            n = 1 if exp == "none" else case.get("trials", cfg.trials)
            trials = []
            for t in range(1, n + 1):
                do_file = t == 1 and not cfg.no_file and not case.get("nofile")
                trials.append(trial_pair(world, case, mode, t, do_file, cfg))
    except Exception as e:
        traceback.print_exc()
        trials = [dict(trial=1, path=f"ERROR {type(e).__name__}: {str(e)[:120]}")]
    paths = [t.get("path", "none") for t in trials]
    ok_n = sum(p in exp.split("|") for p in paths)
    row = dict(case=case["id"], a=case["a"], b=case["b"], topo=case.get("topo", "pair"), mode=mode, expect=exp,
               trials=trials, paths=paths, ok_n=ok_n, n=len(trials),
               ok=ok_n == len(trials) or (case.get("trials", 0) >= 5 and exp == "direct|none"))
    return row


def med(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def fmt_row(r):
    T = r["trials"]
    t0 = T[0]
    path = Counter(r["paths"]).most_common(1)[0][0]
    if len(set(r["paths"])) > 1:
        path = " / ".join(f"{p}×{c}" for p, c in Counter(r["paths"]).most_common())
    tc, tf = med([t.get("t_connect") for t in T]), med([t.get("t_final") for t in T])
    rtt = med([t.get("rtt") for t in T])
    chat = [t.get("chat_ms") for t in T if t.get("path", "none") != "none"]
    chat_s = "-" if not chat else (f"✅ {med(chat):.0f} ms" if all(c is not None for c in chat) else f"❌ {sum(c is not None for c in chat)}/{len(chat)}")
    f = next((t["file"] for t in T if t.get("file")), None)
    file_s = "-" if not f else (f"✅ {f['s']} s ({f['mbps']} Mbit/s)" if f["ok"] else "❌")
    ts = lambda x: f"{x * 1000:.0f} ms" if x < 1 else f"{x:.1f} s"
    time_s = "-" if tc is None else (ts(tc) if tf is None or abs(tf - tc) < 0.05 else f"{ts(tc)} → {ts(tf)}")
    ok = "✅" if r["ok"] else "❌"
    if r["n"] > 1:
        ok += f" {r['ok_n']}/{r['n']}"
    nat = f"{t0.get('natA', '?')} / {t0.get('natB', '?')}"
    return f"| {r['case']} | {r['a']} ↔ {r['b']} | {r['mode']} | {nat} | {path} | {r['expect']} | {time_s} | {rtt if rtt is not None else '-'} | {chat_s} | {file_s} | {ok} |"


def matrix(results):
    """Compact view: one row per case, one column per mode (path · median connect time)."""
    modes = [m for m in list(MODES) if any(r["mode"] == m for r in results)]
    rows = {}
    for r in results:
        rows.setdefault(r["case"], {})[r["mode"]] = r
    print("\n| case | A ↔ B | expected | " + " | ".join(modes) + " |")
    print("|---|---|---|" + "---|" * len(modes))
    for cid, by in rows.items():
        any_r = next(iter(by.values()))
        cells = []
        for m in modes:
            r = by.get(m)
            if not r:
                cells.append("")
                continue
            c = Counter(r["paths"])
            path = c.most_common(1)[0][0] if len(c) == 1 else " / ".join(f"{p}×{n}" for p, n in c.most_common())
            tc = med([t.get("t_final") for t in r["trials"]])
            t = "" if tc is None else (f" · {tc * 1000:.0f} ms" if tc < 1 else f" · {tc:.1f} s")
            cells.append(f"{'✅' if r['ok'] else '❌'} {path}{t}")
        exp = any_r["expect"] if len({r["expect"] for r in by.values()}) == 1 else CASE_BY_ID.get(cid, {}).get("expect", any_r["expect"])
        print(f"| {cid} | {any_r['a']} ↔ {any_r['b']} | {exp} | " + " | ".join(cells) + " |")


def report(results):
    print("\n| case | A ↔ B | mode | NAT detected A / B | path | expected | connect (→ direct) | RTT ms | chat | 5 MB file | ok |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for r in results:
        print(fmt_row(r))
    matrix(results)
    for r in results:
        if r["case"] in ("keepalive", "peer-relay", "peer-relay-live"):
            print(f"\n{r['case']} [{r['mode']}]: " + json.dumps({k: v for k, v in r["trials"][0].items() if k != "trial"}, ensure_ascii=False))
    bd = [r for r in results if r["case"].startswith("bday")]
    for r in bd:
        print(f"\n{r['case']} [{r['mode']}]: two-sided birthday spray succeeded {r['paths'].count('direct')}/{r['n']}")


CASE_BY_ID = {c["id"]: c for c in CASES}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", default=os.path.join(ROOT, "core/target/debug/lumorad"))
    ap.add_argument("--relay-bin", default=os.path.join(ROOT, "core/target/debug/lumora-relay"))
    ap.add_argument("--mode", default="all", choices=list(MODES) + ["all"])
    ap.add_argument("--case", default=None, help="comma-separated case ids (prefix match)")
    ap.add_argument("--only", type=int, default=None, help="run a single case by index")
    ap.add_argument("--quick", action="store_true", help="CI subset: quick cases, modes full + no-relay, 1 trial, no file")
    ap.add_argument("--trials", type=int, default=3, help="trials per case/mode (median connect time)")
    ap.add_argument("--jobs", type=int, default=3, help="parallel isolated worlds")
    ap.add_argument("--idle", type=int, default=180, help="idle seconds in the keepalive case")
    ap.add_argument("--no-file", action="store_true", help="skip the 5 MB file transfer")
    ap.add_argument("--logs", default=None, help="log directory (default: a new /tmp dir)")
    ap.add_argument("--json", default=None, help="also write raw results here")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--report", default=None, metavar="RESULTS_JSON", help="re-print the tables of an earlier run (no sudo)")
    cfg = ap.parse_args()
    if cfg.report:
        res = json.load(open(cfg.report))
        order = {(c["id"], m): i for i, (c, m) in enumerate((c, m) for c in CASES for m in c.get("modes", STD))}
        res.sort(key=lambda r: order.get((r["case"], r["mode"]), 999))
        report(res)
        return
    if cfg.list:
        for i, c in enumerate(CASES):
            print(f"{i:2d} {c['id']:11s} {c['a']:>20s} ↔ {c['b']:<20s} expect {c['expect']:12s} modes {','.join(c.get('modes', STD))}\n    {c['theory']}")
        return
    if os.geteuid() != 0:
        sys.exit("run with sudo (needs network namespaces)")
    for b in (cfg.bin, cfg.relay_bin):
        if not os.path.exists(b):
            sys.exit(f"missing binary {b}")
    cases = CASES
    if cfg.only is not None:
        cases = [CASES[cfg.only]]
    if cfg.case:
        keys = cfg.case.split(",")
        cases = [c for c in CASES if any(c["id"] == k or c["id"].startswith(k) for k in keys)]
    if cfg.quick:
        cases = [c for c in cases if c.get("quick")]
        cfg.trials, cfg.no_file = 1, True
    jobs = []
    for c in cases:
        for m in c.get("modes", STD):
            if cfg.quick and m not in ("full", "no-relay"):
                continue
            if cfg.mode != "all" and m != cfg.mode:
                continue
            jobs.append((c, m))
    cfg.logdir = cfg.logs or tempfile.mkdtemp(prefix="lumora-natlab-")
    os.makedirs(cfg.logdir, exist_ok=True)
    os.chmod(cfg.logdir, 0o777)
    print(f"{len(jobs)} jobs, {cfg.jobs} parallel worlds, logs: {cfg.logdir}", flush=True)
    teardown_all()
    # long scenarios first so they overlap with the many short ones
    jobs.sort(key=lambda j: 0 if j[0].get("kind") in ("keepalive", "peerrelay") or j[0].get("trials", 0) > 3 or j[0].get("impair") else 1)
    order = {(c["id"], m): i for i, (c, m) in enumerate((c, m) for c in CASES for m in c.get("modes", STD))}
    q = queue.Queue()
    for j in jobs:
        q.put(j)
    results, lock = [], threading.Lock()
    t_start = time.time()

    def worker(w):
        world = World(w, cfg.relay_bin, cfg.logdir)
        try:
            while True:
                try:
                    c, m = q.get_nowait()
                except queue.Empty:
                    return
                t = time.time()
                row = run_job(world, c, m, cfg)
                with lock:
                    results.append(row)
                    print(f"[{len(results)}/{len(jobs)} {time.time() - t_start:5.0f}s] w{w} {c['id']:11s} {m:17s} → {','.join(row['paths'])} "
                          f"(expect {row['expect']}) {'ok' if row['ok'] else 'FAIL'}  {time.time() - t:.0f}s", flush=True)
        finally:
            world.close()

    try:
        ths = [threading.Thread(target=worker, args=(w,)) for w in range(min(cfg.jobs, max(1, len(jobs))))]
        for t in ths:
            t.start()
            time.sleep(0.5)
        for t in ths:
            t.join()
    finally:
        teardown_all()
    results.sort(key=lambda r: order.get((r["case"], r["mode"]), 999))
    report(results)
    out = cfg.json or os.path.join(cfg.logdir, "results.json")
    with open(out, "w") as f:
        json.dump(results, f, indent=1, ensure_ascii=False)
    if os.environ.get("SUDO_UID"):   # logs readable by whoever ran sudo
        sh(f"chown -R {os.environ['SUDO_UID']}:{os.environ.get('SUDO_GID', os.environ['SUDO_UID'])} {shlex.quote(cfg.logdir)}", check=False)
        sh(f"chmod -R u+rwX {shlex.quote(cfg.logdir)}", check=False)
    bad = [r for r in results if not r["ok"]]
    print(f"\n{len(results) - len(bad)}/{len(results)} as expected · {time.time() - t_start:.0f}s · logs + results.json: {cfg.logdir}")
    sys.exit(0 if not bad else 1)


if __name__ == "__main__":
    main()
