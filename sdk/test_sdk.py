#!/usr/bin/env python3
"""Tests both SDKs against real nodes: /start → buttons → press → callback reply; RSS of bots.
Full feature coverage of both SDKs (end to end): sdk/tests/test_features.py."""
import os, sys, subprocess, tempfile, time, json, shutil
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "core", "tests"))
# pyrefly: ignore[missing-import]
from e2e import Node, wait_until
BIN = os.environ.get("LUMORAD", os.path.join(ROOT, "core", "target", "debug", "lumorad"))
env = dict(os.environ, LUMORAD=BIN)

def rss(pid):
    for l in open(f"/proc/{pid}/status"):
        if l.startswith("VmRSS"):
            return int(l.split()[1]) // 1024
    return 0

def check(user, bot_peer, start_text, press_data, expect_reply):
    user.call("add_contact", target=bot_peer)
    wait_until(lambda: any(c["peer"] == bot_peer and c["status"] == 3 for c in user.call("contacts")), 30, "bot auto-accepts")
    wait_until(lambda: any(c["peer"] == bot_peer and c.get("bot") for c in user.call("contacts")), 20, "bot profile (commands)")
    conv = f"d:{bot_peer}"
    user.call("send_text", conv=conv, text=start_text)
    def with_buttons():
        for m in user.call("messages", conv=conv):
            if not m["mine"] and (m.get("meta") or {}).get("buttons"):
                return m
    m = wait_until(with_buttons, 20, "reply with buttons")
    user.call("press_button", msg_id=m["id"], data=press_data)
    wait_until(lambda: any(not x["mine"] and expect_reply in (x["body"].get("text") or "") for x in user.call("messages", conv=conv)), 20, "callback reply")
    cmds = [c for c in user.call("contacts") if c["peer"] == bot_peer][0]["bot"]["commands"]
    return cmds

tmp = tempfile.mkdtemp(prefix="lumora-sdk-")
procs = []
ok = True
try:
    py = subprocess.Popen([sys.executable, "-u", os.path.join(HERE, "examples", "weather_bot.py")], env=dict(env, BOT_DIR=os.path.join(tmp, "pybot")),
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    procs.append(py)
    js = subprocess.Popen(["node", os.path.join(HERE, "examples", "echo-bot.mjs")], env=dict(env, BOT_DIR=os.path.join(tmp, "jsbot")),
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    procs.append(js)
    def online_line(p):
        line = p.stdout.readline()
        assert "online" in line, line
        return line.split("(")[-1].rstrip(")\n ")
    py_peer, js_peer = online_line(py), online_line(js)
    os.makedirs(os.path.join(tmp, "user"))
    U = Node("Người dùng", BIN, os.path.join(tmp, "user"), ["--no-nostr"])
    try:
        t0 = time.time()
        cmds = check(U, py_peer, "/start", "hcm", "TP.HCM")
        print(f"Python SDK: /start → buttons → callback ({time.time()-t0:.1f}s), commands={cmds}")
        t0 = time.time()
        cmds = check(U, js_peer, "/start", "like", "Bạn đã bấm: like")
        print(f"JS SDK: /start → buttons → callback ({time.time()-t0:.1f}s), commands={cmds}")
        # Bot Studio: the user creates a child bot in the app, a dev runs it with the token
        O = Node("Chủ bot", BIN, os.path.join(tmp, "owner"), ["--no-nostr"]) if os.makedirs(os.path.join(tmp, "owner")) is None else None
        try:
            made = O.call("bot_create", name="Shop Bot", username="shop_bot")
            assert made["token"].startswith("lumora_bot_") and made["handle"].startswith("@shop_bot·")
            fb = subprocess.Popen([sys.executable, "-u", "-c",
                "import sys;sys.path.insert(0,%r);from lumora_bot import Bot\n"
                "b=Bot(data_dir=%r)\n@b.command('start','Bắt đầu')\ndef s(c): c.reply('Shop xin chào', buttons=[[('Mua','buy')]])\n"
                "@b.on_callback\ndef cb(c): c.reply('Đã đặt hàng: '+c.data)\nb.run()" % (os.path.join(HERE, "python"), os.path.join(tmp, "childbot"))],
                env=dict(env, LUMORA_BOT_TOKEN=made["token"]), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            procs.append(fb)
            line = fb.stdout.readline()
            assert "@shop_bot·" in line, line
            check(U, made["peer"], "/start", "buy", "Đã đặt hàng: buy")
            owner_seen = [c for c in U.call("contacts") if c["peer"] == made["peer"]][0]["bot"]["owner"]
            assert owner_seen == O.me["peer"], owner_seen
            print(f"Bot Studio: child bot @shop_bot runs from its token; users see verified owner")
            again = O.call("bot_revoke", username="shop_bot")
            assert again["handle"] == made["handle"] and again["peer"] != made["peer"], "revoke must keep handle, change key"
            print("Bot Studio: token revoked → new key, same @handle")
        finally:
            O.stop()
        # bot process RSS (lumorad children)
        out = subprocess.run(["pgrep", "-f", "--", f"--data {tmp}/"], capture_output=True, text=True).stdout.split()
        mem = [rss(int(p)) for p in out]
        print(f"RAM per bot node: {mem} MB")
    finally:
        U.stop()
except Exception as e:
    ok = False
    print("x", e)
finally:
    for p in procs:
        p.terminate()
    time.sleep(1)
    shutil.rmtree(tmp, ignore_errors=True)
sys.exit(0 if ok else 1)
