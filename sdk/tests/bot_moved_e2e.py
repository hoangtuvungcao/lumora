#!/usr/bin/env python3
"""A bot moved to a fresh data folder keeps its users and groups.

    python3 sdk/tests/bot_moved_e2e.py [--bin path/to/lumorad]

A user with two devices (main + linked) befriends a Bot Studio bot and adds it to a group
(the group's owner is not the bot's friend) while the bot runs from data folder A. The bot
is then started with the same token from an empty folder B — moved to another server, or
the same token run twice. Without help it knew nobody there: 1-1 messages were sealed for
the old folder's ratchet sessions and the group was unknown, so the bot stayed silent.

Now: whoever still holds the bot as a friend is one again (bot_readopt), the stuck ratchet
messages are re-sent with a fresh session, and the friend gives the shared groups back
(recovery flow, auto-accepted by the bot). Checked: replies in the 1-1 chat from both of
the user's devices and in the group from the user and from the owner.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SDK = os.path.dirname(HERE)
ROOT = os.path.dirname(SDK)
sys.path.insert(0, os.path.join(ROOT, "core", "tests"))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
# pyrefly: ignore[missing-import]
from e2e import Node, wait_until  # noqa: E402
# pyrefly: ignore[missing-import]
from test_features import text_of, wait_msg  # noqa: E402

BOT = r'''
import os, sys
sys.path.insert(0, os.environ["SDK_PY"])
from lumora_bot import Bot
bot = Bot(data_dir=os.environ["BOT_DIR"])

@bot.command("start", "Start")
def start(ctx):
    ctx.reply("HELLO " + ctx.sender_name)

@bot.command("ping", "Ping")
def ping(ctx):
    ctx.reply("PONG")

bot.run()
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.environ.get("LUMORAD") or os.path.join(ROOT, "core", "target", "debug", "lumorad"))
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="lumora-botmoved-")
    os.environ.setdefault("LUMORA_MDNS_SERVICE", f"_lbm{os.getpid() % 10000}._udp.local.")
    extra = ["--no-nostr"]
    bot_py = os.path.join(tmp, "bot.py")
    with open(bot_py, "w") as f:
        f.write(BOT)

    def start(name, more=()):
        d = os.path.join(tmp, name)
        os.makedirs(d, exist_ok=True)
        return Node(name, a.bin, d, extra + ["--downloads", os.path.join(d, "dl")] + list(more))

    def link(E, name):
        N = start(name, more=["--link-pending"])
        st = N.call("link_start", name=name)
        info = E.call("link_scan", qr=st["qr"], timeout=60)
        E.call("link_approve", device=info["device"], history="all")
        N.wait_event(lambda e: e["event"] == "link_state" and e["state"] == "restart", 20, "restart")
        wait_until(lambda: N.call("me")["account"] == E.me["account"], 40, "linked")
        N.me = N.call("me")
        return N

    def befriend(x, y):
        x.call("add_contact", target=y.me["peer"])
        wait_until(lambda: any(c["peer"] == x.me["peer"] and c["status"] == 2 for c in y.call("contacts")), 30, "request")
        y.call("accept_contact", peer=x.me["peer"])
        wait_until(lambda: any(c["peer"] == y.me["peer"] and c["status"] == 3 for c in x.call("contacts")), 30, "friends")

    token = None

    def start_bot(folder):
        env = dict(os.environ, LUMORAD=a.bin, BOT_DIR=os.path.join(tmp, folder), LUMORA_BOT_TOKEN=token,
                   SDK_PY=os.path.join(SDK, "python"))
        p = subprocess.Popen([sys.executable, "-u", bot_py], env=env, stdout=subprocess.PIPE,
                             stderr=open(os.path.join(tmp, f"{folder}.log"), "w"), text=True)
        line = p.stdout.readline()
        assert "is online" in line, f"bot did not start: {line!r} (see {tmp}/{folder}.log)"
        return p, line.rsplit("(", 1)[-1].strip(" )\n")

    results, procs, nodes = [], [], []
    try:
        E, O = start("E"), start("O")
        nodes += [E, O]
        D = link(E, "D")
        nodes.append(D)
        befriend(O, E)
        made = E.call("bot_create", name="Moved Bot", username="moved_bot")
        token = made.get("token") or E.call("bot_token", username="moved_bot")["token"]
        p, bot = start_bot("botA")
        procs.append(p)
        dm = f"d:{bot}"
        D.call("add_contact", target=bot)
        wait_until(lambda: any(c["peer"] == bot and c["status"] == 3 for c in D.call("contacts")), 40, "bot accepted")
        g = O.call("create_group", name="Team", members=[E.me["peer"]])
        gconv = g["conv"]
        wait_until(lambda: any(x["gid"] == g["gid"] for x in D.call("groups")), 40, "linked device got the group")
        O.call("group_set_role", gid=g["gid"], peer=E.me["peer"], role="admin")
        time.sleep(2)
        D.call("group_add_bot", gid=g["gid"], target=bot, read_all=True)

        def ask(node, conv, text, want, timeout=45):
            t0 = max([m["hlc"] for m in node.call("messages", conv=conv, limit=200)] or [0])
            node.call("send_text", conv=conv, text=text)
            wait_msg(node, conv, lambda m: m["author"] == bot and m["hlc"] > t0 and want in (text_of(m) or ""), f"bot says {want!r}", timeout)

        def check(label, *args):
            t = time.time()
            try:
                ask(*args)
                results.append((label, True))
                print(f"  ✅ {label} ({time.time() - t:.1f}s)", flush=True)
            except Exception as e:  # noqa: BLE001
                results.append((label, False))
                print(f"  ❌ {label}: {e}", flush=True)

        check("folder A: 1-1 /start", D, dm, "/start", "HELLO")
        check("folder A: group /ping", D, gconv, "/ping", "PONG")
        p.terminate()
        p.wait(15)
        p, again = start_bot("botB")
        procs.append(p)
        assert again == bot, (again, bot)
        check("fresh folder B: 1-1 /start from the linked device", D, dm, "/start", "HELLO")
        check("fresh folder B: 1-1 /start from the main device", E, dm, "/start", "HELLO")
        check("fresh folder B: group /ping from the user", D, gconv, "/ping", "PONG")
        check("fresh folder B: group /ping from the owner (not the bot's friend)", O, gconv, "/ping", "PONG")
    finally:
        for p in procs:
            p.terminate()
        for n in nodes:
            n.p.terminate()
        if not a.keep:
            shutil.rmtree(tmp, ignore_errors=True)
    ok = len(results) == 6 and all(r for _, r in results)
    print(f"{sum(r for _, r in results)}/6 passed", flush=True)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
