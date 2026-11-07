#!/usr/bin/env python3
"""HTTP Bot API end to end: a bot made in Bot Studio runs as `lumorad --http-api` (no SDK, no
stdio) and is driven only with curl / HTTP.

    python3 core/tests/bot_http_e2e.py [--bin core/target/debug/lumorad] [--keep]

Scenarios: auth (401), getMe, sendMessage → a friend receives it, getUpdates long polling
delivers the friend's message, callback_query, setWebhook → a local HTTP server gets the
update with the secret header, getUpdates refused while the webhook is set, a community
channel post (the "GitHub → bot → channel" case), the runner restarts without losing state.
"""
import argparse, http.server, json, os, shutil, signal, socket, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from e2e import Node, wait_until, step, RESULTS  # noqa: E402


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def curl(url, *args, timeout=60):
    """curl → (http status, parsed JSON)."""
    r = subprocess.run(["curl", "-sS", "--max-time", str(timeout), "-w", "\n%{http_code}", url, *args], capture_output=True, text=True, timeout=timeout + 5)
    assert r.returncode == 0, f"curl failed: {r.stderr}"
    body, _, code = r.stdout.rpartition("\n")
    return int(code), json.loads(body) if body.strip() else None


def texts(node, conv):
    return [(m["author"], (m.get("body") or {}).get("text", "")) for m in node.call("messages", conv=conv, limit=200)]


class Bot:
    """`lumorad --http-api` running a Bot Studio bot from its token (environment variable)."""

    def __init__(self, binary, data, token, port):
        self.binary, self.data, self.token, self.port = binary, data, token, port
        self.base = f"http://127.0.0.1:{port}/bot{token}"
        self.start()

    def start(self):
        lp = os.path.join(self.data, "runner.log")
        seen = os.path.getsize(lp) if os.path.exists(lp) else 0
        self.log = open(lp, "a")
        env = dict(os.environ, LUMORA_BOT_TOKEN=self.token)
        self.p = subprocess.Popen([self.binary, "--data", self.data, "--no-dht", "--no-upnp", "--no-nostr",
                                   "--http-api", f"127.0.0.1:{self.port}"],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=self.log, env=env)
        wait_until(lambda: "HTTP Bot API on" in open(lp, errors="replace").read()[seen:], 60, "runner listening")

    def stop(self):
        if self.p.poll() is None:
            self.p.send_signal(signal.SIGINT)
            try:
                self.p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.p.kill()
        self.log.close()

    def api(self, method, *args, **kw):
        code, v = curl(f"{self.base}/{method}", *args, **kw)
        assert code == 200 and v["ok"], f"{method}: {code} {v}"
        return v["result"]


class Hook(http.server.BaseHTTPRequestHandler):
    got = []

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        Hook.got.append((dict(self.headers), json.loads(self.rfile.read(n))))
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, "target", "debug", "lumorad"))
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    if not shutil.which("curl"):
        print("curl is required")
        return 2
    tmp = tempfile.mkdtemp(prefix="lumora-bothttp-")
    print(f"data: {tmp}")
    for d in ("owner", "friend", "bot"):
        os.makedirs(os.path.join(tmp, d))
    extra = ["--no-nostr"]
    O = Node("Chủ bot", a.bin, os.path.join(tmp, "owner"), extra)
    F = Node("Bạn", a.bin, os.path.join(tmp, "friend"), extra)
    bot = None
    hook_srv = None
    st = {}
    try:
        @step("Bot Studio: bot_create → token; runner starts with --http-api")
        def _():
            made = O.call("bot_create", name="HTTP Bot", username="http_bot")
            assert made["token"].startswith("lumora_bot_"), made
            st["token"], st["peer"] = made["token"], made["peer"]
            nonlocal bot
            bot = Bot(a.bin, os.path.join(tmp, "bot"), made["token"], free_port())
        _()

        @step("auth: wrong token → 401, getMe with the token")
        def _():
            code, v = curl(f"http://127.0.0.1:{bot.port}/botlumora_bot_wrong/getMe")
            assert code == 401 and v == {"ok": False, "error_code": 401, "description": "Unauthorized"}, (code, v)
            me = bot.api("getMe")
            assert me["id"] == st["peer"] and me["is_bot"] and me["username"] == "http_bot" and me["first_name"] == "HTTP Bot", me
        _()

        @step("the friend adds the bot (auto-accepted)")
        def _():
            F.call("add_contact", target=st["peer"])
            wait_until(lambda: any(c["peer"] == st["peer"] and c["status"] == 3 for c in F.call("contacts")), 60, "bot accepts")
        _()

        @step("curl sendMessage (form fields, MarkdownV2, button) → the friend receives it")
        def _():
            chat = "d:" + F.me["peer"]
            m = bot.api("sendMessage", "-d", f"chat_id={chat}", "--data-urlencode", "text=*Build #42* passed ✅",
                        "-d", "parse_mode=MarkdownV2", "--data-urlencode",
                        'reply_markup={"inline_keyboard":[[{"text":"Chi tiết","callback_data":"details"}]]}')
            assert m["chat"]["id"] == chat and len(m["message_id"]) == 32, m
            st["mid"] = m["message_id"]
            wait_until(lambda: (st["peer"], "**Build #42** passed ✅") in texts(F, "d:" + st["peer"]), 60, "friend got the bot's message")
        _()

        @step("getUpdates long poll delivers the friend's message; offset confirms")
        def _():
            out = {}
            t = threading.Thread(target=lambda: out.update(r=bot.api("getUpdates", "-G", "-d", "timeout=30", timeout=40)))
            t.start()
            time.sleep(0.5)
            F.call("send_text", conv="d:" + st["peer"], text="/status please")
            t.join(45)
            ups = out["r"]
            assert len(ups) == 1 and ups[0]["message"]["text"] == "/status please", ups
            msg = ups[0]["message"]
            assert msg["from"]["id"] == F.me["peer"] and msg["from"]["first_name"] == "Bạn" and msg["chat"]["type"] == "private", msg
            assert msg["entities"][0]["type"] == "bot_command", msg
            st["offset"] = ups[0]["update_id"] + 1
            assert bot.api("getUpdates", "-d", f"offset={st['offset']}") == []
        _()

        @step("button press → callback_query; answerCallbackQuery")
        def _():
            F.call("press_button", msg_id=st["mid"], data="details")
            def cb():
                for u in bot.api("getUpdates", "-d", f"offset={st['offset']}", "-d", "timeout=5", timeout=15):
                    if "callback_query" in u:
                        return u
            u = wait_until(cb, 30, "callback_query")
            q = u["callback_query"]
            assert q["data"] == "details" and q["message"]["message_id"] == st["mid"] and q["from"]["id"] == F.me["peer"], q
            assert bot.api("answerCallbackQuery", "-d", f"callback_query_id={q['id']}") is True
            st["offset"] = u["update_id"] + 1
            bot.api("getUpdates", "-d", f"offset={st['offset']}")
        _()

        @step("setWebhook → updates are POSTed with the secret header; getUpdates refused meanwhile")
        def _():
            nonlocal hook_srv
            hook_srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Hook)
            threading.Thread(target=hook_srv.serve_forever, daemon=True).start()
            url = f"http://127.0.0.1:{hook_srv.server_address[1]}/lumora"
            assert bot.api("setWebhook", "-H", "Content-Type: application/json",
                           "-d", json.dumps({"url": url, "secret_token": "e2e_SECRET-1"})) is True
            code, v = curl(f"{bot.base}/getUpdates")
            assert code == 409 and not v["ok"], (code, v)
            F.call("send_text", conv="d:" + st["peer"], text="via webhook")
            got = wait_until(lambda: [g for g in Hook.got if g[1].get("message", {}).get("text") == "via webhook"], 30, "webhook POST")
            headers, upd = got[0]
            assert headers.get("X-Lumora-Bot-Secret") == "e2e_SECRET-1", headers
            info = bot.api("getWebhookInfo")
            assert info["url"] == url, info
            wait_until(lambda: bot.api("getWebhookInfo")["pending_update_count"] == 0, 10, "webhook queue drained")
        _()

        @step("the runner restarts: webhook kept, update ids keep increasing")
        def _():
            last = max(g[1]["update_id"] for g in Hook.got)
            bot.stop()
            bot.start()
            assert bot.api("getWebhookInfo")["url"].endswith("/lumora")
            # the restarted runner reconnects to the friend by itself
            F.call("send_text", conv="d:" + st["peer"], text="after restart")
            got = wait_until(lambda: [g for g in Hook.got if g[1].get("message", {}).get("text") == "after restart"], 60, "webhook after restart")
            assert got[0][1]["update_id"] > last, (got[0][1]["update_id"], last)
            assert bot.api("deleteWebhook") is True
            bot.api("getUpdates")  # usable again
        _()

        @step("community channel: an external service posts through the bot (GitHub → bot → #channel)")
        def _():
            O.call("add_contact", target=F.me["peer"])
            wait_until(lambda: any(c["peer"] == O.me["peer"] and c["status"] == 2 for c in F.call("contacts")), 60, "friend request arrives")
            F.call("accept_contact", peer=O.me["peer"])
            wait_until(lambda: any(c["peer"] == F.me["peer"] and c["status"] == 3 for c in O.call("contacts")), 60, "owner ↔ friend")
            g = O.call("create_group", name="Dự án Lumora", members=[F.me["peer"]], kind=1)
            gid = g["gid"]
            O.call("add_contact", target=st["peer"])
            wait_until(lambda: any(c["peer"] == st["peer"] and c["status"] == 3 for c in O.call("contacts")), 60, "owner ↔ bot")
            wait_until(lambda: any(x["gid"] == gid for x in F.call("groups")), 40, "friend got the community")
            O.call("group_add_bot", gid=gid, target=st["peer"], read_all=False)
            chans = O.call("group_info", gid=gid).get("channels") or []
            conv = chans[0]["conv"] if chans else g["conv"]
            # the bot learns it was added (getChat works once the group reached it)
            wait_until(lambda: curl(f"{bot.base}/getChat", "-d", f"chat_id={conv}")[0] == 200, 60, "bot joined the community")
            m = bot.api("sendMessage", "-H", "Content-Type: application/json", "-d",
                        json.dumps({"chat_id": conv, "text": "<b>[lumora/core]</b> 1 new commit: <code>fix: relay</code>", "parse_mode": "HTML"}))
            assert m["chat"]["type"] == "supergroup", m
            want = (st["peer"], "**[lumora/core]** 1 new commit: `fix: relay`")
            wait_until(lambda: want in texts(F, conv), 60, "friend sees the post in the channel")
        _()
    except Exception:
        pass
    finally:
        if bot:
            bot.stop()
        if hook_srv:
            hook_srv.shutdown()
        O.stop()
        F.stop()
        if not a.keep:
            shutil.rmtree(tmp, ignore_errors=True)
    failed = [r for r in RESULTS if not r[1]]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} passed")
    return 1 if failed or not RESULTS else 0


if __name__ == "__main__":
    sys.exit(main())
