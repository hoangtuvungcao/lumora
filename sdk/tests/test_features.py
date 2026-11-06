#!/usr/bin/env python3
"""End-to-end tests of both SDKs (Python and JavaScript) against real Lumora Bot Runner nodes.

    python3 sdk/tests/test_features.py                 # both SDKs
    python3 sdk/tests/test_features.py --only py       # or: --only js
    LUMORAD=/path/to/lumorad python3 sdk/tests/test_features.py

Static checks first (generated API references up to date, pacing maths, docs snippets and
examples compile, package versions), then for each SDK the same scenario against
sdk/tests/feature_bot.py / feature_bot.mjs, driven by real user nodes:

  direct chat: commands + menu, buttons + callback + edit, regex/catch-all/kind filters, middleware,
  chat filters, /help, checklists (+ add, on_checklist), reminders (on_reminder_due), silent,
  poll/location/contact/edit/pin/react/mention/reply/forward, errors (.code/.message/.cmd,
  blocked commands, bad buttons), on_error, jobs, storage, files (download, preview both ways)
  group with full access + admin: added, new member, member left, group-admin check, callbacks,
  slow mode, purge, ban;  group in privacy mode: commands + callbacks, plain text not seen
  runtime: automatic restart of Lumora Bot Runner, graceful SIGTERM shutdown.
"""
import argparse
import json
import os
import py_compile
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SDK = os.path.dirname(HERE)
ROOT = os.path.dirname(SDK)
sys.path.insert(0, os.path.join(ROOT, "core", "tests"))
sys.path.insert(0, os.path.join(SDK, "python"))
sys.dont_write_bytecode = True
# pyrefly: ignore[missing-import]
from e2e import Node, wait_until  # noqa: E402

RESULTS = []


def step(name, fn, *a):
    t = time.time()
    try:
        fn(*a)
        RESULTS.append((name, True, time.time() - t, ""))
        print(f"  ✅ {name} ({time.time() - t:.1f}s)", flush=True)
        return True
    except Exception as e:  # noqa: BLE001
        RESULTS.append((name, False, time.time() - t, f"{type(e).__name__}: {e}"))
        print(f"  ❌ {name}: {type(e).__name__}: {e}", flush=True)
        return False


# ----------------------------------------------------------------------------- static checks


def check_references():
    subprocess.run([sys.executable, os.path.join(SDK, "tools", "gen_reference.py"), "--check"], check=True, stdout=subprocess.DEVNULL)


def check_pacer():
    import lumora_bot
    p = lumora_bot._Pacer(15)
    delays = [round(p.reserve("chat"), 2) for _ in range(8)]
    assert delays[:5] == [0, 0, 0, 0, 0], delays           # burst of 5 per chat
    assert all(abs(d - e) < 0.05 for d, e in zip(delays[5:], [1, 2, 3])), delays   # then 1/s
    p = lumora_bot._Pacer(15)
    d = [p.reserve(f"c{i}") for i in range(45)]               # many chats: 15/s overall
    assert max(d[:15]) < 0.01 and 1.9 < d[44] < 2.1, d[44]


def check_snippets():
    """Every code block of the bilingual docs compiles (Python) / parses (JavaScript)."""
    tmp = tempfile.mkdtemp(prefix="lumora-snip-")
    n = 0
    try:
        for f in ("quickstart.md", "guides.md", "production.md", "reference.md"):
            text = open(os.path.join(ROOT, "docs", "src", "bots", f), encoding="utf-8").read()
            for i, m in enumerate(re.finditer(r"^```(python|js)\n(.*?)^```", text, re.M | re.S)):
                lang, code = m.group(1), m.group(2)
                if lang == "python":
                    compile(code, f"{f}#{i}", "exec")
                else:
                    p = os.path.join(tmp, f"{f}-{i}.mjs")
                    with open(p, "w", encoding="utf-8") as fh:
                        fh.write(code)
                    r = subprocess.run(["node", "--check", p], capture_output=True, text=True)
                    assert r.returncode == 0, f"{f} block {i}: {r.stderr.strip()[:300]}"
                n += 1
        for f in os.listdir(os.path.join(SDK, "examples")) + ["../tests/feature_bot.py", "../tests/feature_bot.mjs"]:
            p = os.path.join(SDK, "examples", f)
            if f.endswith(".py"):
                py_compile.compile(p, cfile=os.path.join(tmp, "x.pyc"), doraise=True)
            elif f.endswith(".mjs"):
                subprocess.run(["node", "--check", p], check=True, capture_output=True)
            n += 1
        assert n > 30, n
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check_versions():
    import lumora_bot
    js = open(os.path.join(SDK, "js", "lumora-bot.mjs"), encoding="utf-8").read()
    pkg = json.load(open(os.path.join(SDK, "js", "package.json"), encoding="utf-8"))
    toml = open(os.path.join(SDK, "python", "pyproject.toml"), encoding="utf-8").read()
    vs = {lumora_bot.__version__, re.search(r'VERSION = "([^"]+)"', js).group(1), pkg["version"], re.search(r'^version = "([^"]+)"', toml, re.M).group(1)}
    assert len(vs) == 1, vs
    assert pkg["exports"]["."]["types"] == "./lumora-bot.d.ts" and os.path.exists(os.path.join(SDK, "js", "lumora-bot.d.ts"))
    dts = open(os.path.join(SDK, "js", "lumora-bot.d.ts"), encoding="utf-8").read()
    assert dts == open(os.path.join(SDK, "js", "lumora-bot.d.mts"), encoding="utf-8").read(), "lumora-bot.d.mts is stale (run sdk/tools/package.py)"
    for d in ("python", "js"):
        for f in ("LICENSE", "CHANGELOG.md"):
            assert open(os.path.join(SDK, d, f), encoding="utf-8").read() == open(os.path.join(SDK, f), encoding="utf-8").read(), f"{d}/{f} differs"


# ----------------------------------------------------------------------------- helpers


def text_of(m):
    b = m.get("body") or {}
    return b.get("text") if isinstance(b, dict) else None


def wait_msg(node, conv, pred, what, timeout=30):
    def f():
        for m in node.call("messages", conv=conv, limit=200):
            if pred(m):
                return m
    return wait_until(f, timeout, f"{node.name}: {what}")


def bot_text(node, conv, bot_peer, text, timeout=30, exact=True):
    return wait_msg(node, conv, lambda m: m["author"] == bot_peer and (text_of(m) == text if exact else (text in (text_of(m) or ""))),
                    f"bot says {text!r}", timeout)


def absent(node, conv, bot_peer, text, wait=4):
    time.sleep(wait)
    assert not any(m["author"] == bot_peer and text in (text_of(m) or "") for m in node.call("messages", conv=conv, limit=200)), f"unexpected {text!r}"


def befriend(a, b):
    a.call("add_contact", target=b.me["peer"])
    wait_until(lambda: any(c["peer"] == a.me["peer"] and c["status"] == 2 for c in b.call("contacts")), 30, "friend request")
    b.call("accept_contact", peer=a.me["peer"])
    wait_until(lambda: any(c["peer"] == b.me["peer"] and c["status"] == 3 for c in a.call("contacts")), 30, "friends")


def lumorad_pids(data_dir):
    out = subprocess.run(["pgrep", "-f", "--", f"--data {data_dir} "], capture_output=True, text=True).stdout.split()
    return [int(p) for p in out]


# ----------------------------------------------------------------------------- scenario


def scenario(lang, binary, tmp, U, M, N):
    bot_dir = os.path.join(tmp, f"bot-{lang}")
    cmd = [sys.executable, "-u", os.path.join(HERE, "feature_bot.py")] if lang == "py" else ["node", os.path.join(HERE, "feature_bot.mjs")]
    log = open(os.path.join(tmp, f"bot-{lang}.log"), "w")
    proc = subprocess.Popen(cmd, env=dict(os.environ, LUMORAD=binary, BOT_DIR=bot_dir), stdout=subprocess.PIPE, stderr=log, text=True)
    st = {}
    try:
        line = proc.stdout.readline()
        assert "is online" in line, f"no online line: {line!r} (see {log.name})"
        bot = line.rsplit("(", 1)[-1].strip(" )\n")
        conv = f"d:{bot}"
        P = f"[{lang}] "

        def say(text, node=U, c=conv):
            node.call("send_text", conv=c, text=text)

        def t_start():
            U.call("add_contact", target=bot)
            wait_until(lambda: any(c["peer"] == bot and c["status"] == 3 and c.get("bot") for c in U.call("contacts")), 40, "bot accepted + profile")
            cmds = [c for c in U.call("contacts") if c["peer"] == bot][0]["bot"]["commands"]
            names = {c["command"] for c in cmds}
            assert {"start", "checklist", "privateonly"} <= names and "gping" not in names, names
            say("/start")
            m = bot_text(U, conv, bot, "MENU")
            rows = m["meta"]["buttons"]
            assert [b["data"] for b in rows[0]] == ["pick:a", "pick:b"] and rows[1][0]["url"].startswith("https://"), rows
            U.call("press_button", msg_id=m["id"], data="pick:a")
            wait_msg(U, conv, lambda x: x["id"] == m["id"] and text_of(x) == "PICKED pick:a" and x["edited"], "menu edited")
            U.call("press_button", msg_id=m["id"], data="zzz")
            bot_text(U, conv, bot, "CB zzz")
        step(P + "commands, menu, buttons, callback filters, ctx.edit", t_start)

        def t_filters():
            say("ping 42")
            bot_text(U, conv, bot, "PONG 42")
            say("hello there")
            bot_text(U, conv, bot, "ECHO hello there")
            say("/privateonly")
            bot_text(U, conv, bot, "PRIVATE OK")
            say("/help")
            h = bot_text(U, conv, bot, "/start — Start", exact=False)
            assert "/gping" not in text_of(h), text_of(h)
            say("/blocked-by-middleware")
            absent(U, conv, bot, "blocked-by-middleware")
            say("/stats")
            bot_text(U, conv, bot, "UPDATES true")
        step(P + "regex/catch-all filters, /help, chats filter, middleware", t_filters)

        def t_checklist():
            say("/checklist")
            m = wait_msg(U, conv, lambda x: x["author"] == bot and x["kind"] == "checklist" and len(x["body"]["items"]) == 3, "checklist with 3 items")
            assert m["body"]["title"] == "Release", m["body"]
            U.call("checklist_toggle", conv=conv, msg_id=m["id"], item=1, done=True)
            bot_text(U, conv, bot, "CHECK 1/3 notes user")
        step(P + "send_checklist + checklist_add + on_checklist", t_checklist)

        def t_reminder():
            say("/remind")
            m = wait_msg(U, conv, lambda x: x["author"] == bot and x["kind"] == "reminder", "reminder message")
            assert m["body"]["title"] == "Standup" and m["body"]["note"] == "room 2", m["body"]
            bot_text(U, conv, bot, "DUE Standup room 2", timeout=20)
        step(P + "send_reminder + on_reminder_due", t_reminder)

        def t_kinds():
            say("/silent")
            m = bot_text(U, conv, bot, "SILENT")
            assert m["silent"] is True, m
            say("/kinds")
            mine = wait_msg(U, conv, lambda x: x["mine"] and text_of(x) == "/kinds", "own /kinds")
            wait_msg(U, conv, lambda x: x["author"] == bot and x["kind"] == "poll" and x["body"]["options"] == ["Pho", "Rice"], "poll")
            wait_msg(U, conv, lambda x: x["author"] == bot and x["kind"] == "location" and x["body"]["label"] == "Hoan Kiem", "location")
            wait_msg(U, conv, lambda x: x["author"] == bot and x["kind"] == "contact" and x["body"]["peer"] == bot, "contact card")
            ed = wait_msg(U, conv, lambda x: x["author"] == bot and text_of(x) == "EDITED" and x["edited"] and x.get("pinned"), "edited + pinned")
            wait_msg(U, conv, lambda x: x["id"] == mine["id"] and bot in (x["reactions"].get("👍") or []), "reaction on user message")
            mt = bot_text(U, conv, bot, "MENTION")
            assert U.me["peer"] in mt["meta"]["mentions"] and mt["reply_to"] == mine["id"], mt
            wait_msg(U, conv, lambda x: x["author"] == bot and (x.get("meta") or {}).get("forwarded_from") and text_of(x) == "EDITED"
                     and x["id"] != ed["id"], "forwarded copy")
        step(P + "silent, poll, location, contact, edit, pin, react, mention, reply, forward", t_kinds)

        def t_errors():
            say("/err")
            bot_text(U, conv, bot, "ERR err.reminder_past|true|send_reminder sdk.not_for_bots sdk.bad_buttons")
            say("/boom")
            bot_text(U, conv, bot, "ONERROR boom")
        step(P + "LumoraError code/message/cmd, blocked commands, on_error", t_errors)

        def t_jobs_storage():
            say("/job")
            bot_text(U, conv, bot, "JOB DONE", timeout=15)
            say("/store")
            bot_text(U, conv, bot, "STORED 1")
            say("/store")
            bot_text(U, conv, bot, "STORED 2")
            st = json.load(open(os.path.join(bot_dir, "bot-storage.json"), encoding="utf-8"))
            assert st["n"] == 2, st
        step(P + "jobs (after) and storage", t_jobs_storage)

        def t_files():
            p = os.path.join(tmp, f"notes-{lang}.txt")
            with open(p, "w", encoding="utf-8") as f:
                f.write("one\ntwo\nthree\n")
            U.call("send_file", conv=conv, path=p)
            bot_text(U, conv, bot, f"FILE notes-{lang}.txt 3 true", timeout=40)
            fm = wait_msg(U, conv, lambda x: x["author"] == bot and x["kind"] == "file" and x["body"]["name"] == "summary.txt", "summary file", 40)
            assert fm["body"]["preview"]["text"] == "SUMMARY PREVIEW", fm["body"]
            assert os.path.exists(os.path.join(bot_dir, "downloads", f"notes-{lang}.txt")), os.listdir(os.path.join(bot_dir, "downloads"))
            b = os.path.join(tmp, f"data-{lang}.bin")
            with open(b, "wb") as f:
                f.write(os.urandom(2048))
            U.call("send_file", conv=conv, path=b)
            bot_text(U, conv, bot, f"OTHER FILE data-{lang}.bin", timeout=40)
            U.call("send_location", conv=conv, lat=21.0285, lon=105.8542, label="x")
            bot_text(U, conv, bot, "LOC 21.03")
        step(P + "on_file + download + reply_file preview, kinds filter", t_files)

        # ---- group with full access, bot is admin
        def t_group_full():
            g = U.call("create_group", name=f"Team {lang}", members=[M.me["peer"]])
            st["gid"], st["gconv"] = g["gid"], g["conv"]
            gconv = g["conv"]
            wait_until(lambda: any(x["gid"] == g["gid"] for x in M.call("groups")), 30, "member got the group")
            U.call("group_add_bot", gid=g["gid"], target=bot, read_all=True)
            bot_text(U, gconv, bot, "HELLO GROUP read_all=true", timeout=40)
            U.call("group_set_role", gid=g["gid"], peer=bot, role="admin")
            wait_until(lambda: next(m for m in U.call("group_info", gid=g["gid"])["members"] if m["peer"] == bot)["role"] == "admin", 20, "bot admin")
            time.sleep(2)
            say("/access", M, gconv)
            bot_text(M, gconv, bot, "ACCESS read_all=true admin=true sender_admin=false", timeout=40)
            say("/access", U, gconv)
            bot_text(U, gconv, bot, "ACCESS read_all=true admin=true sender_admin=true")
            say("/privateonly", U, gconv)
            absent(U, gconv, bot, "PRIVATE OK", wait=3)
            say("/gping", M, gconv)
            m = bot_text(M, gconv, bot, "GPONG")
            M.call("press_button", msg_id=m["id"], data="g")
            bot_text(M, gconv, bot, "CB g")
            U.call("group_add", gid=g["gid"], peer=N.me["peer"])
            w = bot_text(U, gconv, bot, f"WELCOME {N.me['peer'][:8]}", timeout=40)
            assert N.me["peer"] in w["meta"]["mentions"], w["meta"]
            say("/slow 15", U, gconv)
            bot_text(U, gconv, bot, "SLOW 15")
            assert U.call("group_info", gid=g["gid"])["slow_mode_s"] == 15
            say("/slow 0", U, gconv)
            bot_text(U, gconv, bot, "SLOW 0")
            wait_until(lambda: any(x["gid"] == g["gid"] for x in N.call("groups")), 30, "N joined")
            say("spam spam", N, gconv)
            wait_msg(U, gconv, lambda x: x["author"] == N.me["peer"] and text_of(x) == "spam spam", "N's message")
            say(f"/purge {N.me['peer']}", U, gconv)
            bot_text(U, gconv, bot, "PURGED")
            wait_until(lambda: not any(x["author"] == N.me["peer"] and text_of(x) == "spam spam" and not x["deleted"]
                                       for x in U.call("messages", conv=gconv, limit=200)), 30, "N's messages purged")
            say(f"/ban {N.me['peer']}", U, gconv)
            bot_text(U, gconv, bot, "BANNED true")
            bot_text(U, gconv, bot, f"BYE {N.me['peer'][:8]}", timeout=30)
        step(P + "group (full access, admin): added, access, callbacks, new member, slow mode, purge, ban, left", t_group_full)

        def t_group_privacy():
            g = U.call("create_group", name=f"Quiet {lang}", members=[M.me["peer"]])
            gconv = g["conv"]
            wait_until(lambda: any(x["gid"] == g["gid"] for x in M.call("groups")), 30, "member got group 2")
            U.call("group_add_bot", gid=g["gid"], target=bot, read_all=False)
            bot_text(U, gconv, bot, "HELLO GROUP read_all=false", timeout=40)
            time.sleep(1)
            say("/gping", M, gconv)
            m = bot_text(M, gconv, bot, "GPONG", timeout=40)
            M.call("press_button", msg_id=m["id"], data="g")
            bot_text(M, gconv, bot, "CB g")
            say("not for the bot", M, gconv)
            absent(M, gconv, bot, "ECHO not for the bot")
        step(P + "group (privacy mode): commands, callbacks, plain text not seen", t_group_privacy)

        def t_restart():
            pids = lumorad_pids(bot_dir)
            assert pids, "runner pid"
            for p in pids:
                os.kill(p, signal.SIGKILL)
            time.sleep(1)
            wait_until(lambda: lumorad_pids(bot_dir) and set(lumorad_pids(bot_dir)) != set(pids), 30, "runner restarted")
            # the user's side may keep the old connection to the killed runner for a while:
            # ask again until the restarted bot answers (the SDK side restarts within ~1 s)
            for i in range(4):
                say(f"ping {70 + i}")
                try:
                    bot_text(U, conv, bot, "PONG 7", timeout=20, exact=False)
                    break
                except TimeoutError:
                    if i == 3:
                        raise
        step(P + "automatic restart of Lumora Bot Runner", t_restart)

        def t_shutdown():
            proc.send_signal(signal.SIGTERM)
            code = proc.wait(timeout=20)
            assert code == 0, f"exit code {code}"
            time.sleep(1)
            assert not lumorad_pids(bot_dir), "runner left running"
            logtxt = open(log.name, encoding="utf-8").read()
            assert "stopped" in logtxt, logtxt[-500:]
        step(P + "graceful SIGTERM shutdown", t_shutdown)
    finally:
        if proc.poll() is None:
            proc.kill()
        for p in lumorad_pids(bot_dir):
            os.kill(p, signal.SIGKILL)
        log.close()


def examples(lang, binary, tmp, U, M):
    """Each example bot comes online and does its main job."""
    files = {"py": ["starter_bot.py", "group_helper_bot.py", "team_tasks_bot.py", "file_summary_bot.py"],
             "js": ["starter-bot.mjs", "group-helper-bot.mjs", "team-tasks-bot.mjs", "file-summary-bot.mjs"]}[lang]
    for f in files:
        def run(f=f):
            d = os.path.join(tmp, f"ex-{f}")
            cmd = [sys.executable, "-u", os.path.join(SDK, "examples", f)] if f.endswith(".py") else ["node", os.path.join(SDK, "examples", f)]
            env = dict(os.environ, LUMORAD=binary, BOT_DIR=d)
            env.pop("LUMORA_BOT_TOKEN", None)
            log = open(d + ".log", "w")
            proc = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=log, text=True)
            try:
                line = proc.stdout.readline()
                assert "is online" in line, f"{line!r} (see {log.name})"
                bot = line.rsplit("(", 1)[-1].strip(" )\n")
                conv = f"d:{bot}"
                U.call("add_contact", target=bot)
                wait_until(lambda: any(c["peer"] == bot and c["status"] == 3 and c.get("bot") for c in U.call("contacts")), 60, "example accepted")
                if f.startswith("starter"):
                    U.call("send_text", conv=conv, text="/start")
                    m = bot_text(U, conv, bot, "Try a button", exact=False)
                    U.call("press_button", msg_id=m["id"], data="vote:up")
                    wait_msg(U, conv, lambda x: x["id"] == m["id"] and "Thanks" in (text_of(x) or ""), "vote edits the menu")
                    U.call("send_text", conv=conv, text="hi bot")
                    bot_text(U, conv, bot, "You said: hi bot", exact=False)
                elif f.startswith("group"):
                    g = U.call("create_group", name=f"Ex {f}", members=[M.me["peer"]])
                    wait_until(lambda: any(x["gid"] == g["gid"] for x in M.call("groups")), 30, "member in group")
                    U.call("group_add_bot", gid=g["gid"], target=bot, read_all=True)
                    bot_text(U, g["conv"], bot, "/rules", exact=False, timeout=40)
                    time.sleep(1)
                    U.call("send_text", conv=g["conv"], text="/rules")
                    bot_text(U, g["conv"], bot, "Rules", exact=False)
                    U.call("send_text", conv=g["conv"], text="/slowmode 10")
                    bot_text(U, g["conv"], bot, "admin", exact=False)   # bot is not an admin yet: friendly hint
                elif f.startswith("team"):
                    U.call("send_text", conv=conv, text="/todo Ship: notes; build")
                    cl = wait_msg(U, conv, lambda x: x["author"] == bot and x["kind"] == "checklist", "checklist")
                    assert [i["text"] for i in cl["body"]["items"]] == ["notes", "build"], cl["body"]
                    U.call("send_text", conv=conv, text="/remind 5m Call the client | number in CRM")
                    rm = wait_msg(U, conv, lambda x: x["author"] == bot and x["kind"] == "reminder", "reminder")
                    assert rm["body"]["note"] == "number in CRM", rm["body"]
                    for item in (1, 2):
                        U.call("checklist_toggle", conv=conv, msg_id=cl["id"], item=item, done=True)
                    bot_text(U, conv, bot, "All done: Ship", exact=False)
                else:
                    p = os.path.join(tmp, f"sales-{lang}.csv")
                    with open(p, "w", encoding="utf-8") as fh:
                        fh.write("item,qty,price\ncafe,2,25000\ntea,1,30000\ncafe,3,25000\n")
                    U.call("send_file", conv=conv, path=p)
                    r = bot_text(U, conv, bot, f"sales-{lang}.csv", exact=False, timeout=40)
                    assert "Rows: 3" in text_of(r) and "qty: min 1 · max 3" in text_of(r), text_of(r)
                    wait_msg(U, conv, lambda x: x["author"] == bot and x["kind"] == "file" and "Rows: 3" in ((x["body"].get("preview") or {}).get("text") or ""),
                             "summary file with preview", 40)
            finally:
                proc.send_signal(signal.SIGTERM)
                try:
                    proc.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    proc.kill()
                log.close()
        step(f"[{lang}] example {f}", run)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.environ.get("LUMORAD", os.path.join(ROOT, "core", "target", "debug", "lumorad")))
    ap.add_argument("--only", choices=["py", "js"])
    ap.add_argument("--keep", action="store_true", help="keep the temp folder (logs)")
    a = ap.parse_args()
    print("Static checks")
    step("API references generated from the sources are up to date", check_references)
    step("send pacing: burst 5 then 1/s per chat, 15/s overall", check_pacer)
    step("docs snippets, examples and test bots compile", check_snippets)
    step("same version everywhere, package metadata, LICENSE/CHANGELOG copies", check_versions)
    tmp = tempfile.mkdtemp(prefix="lumora-sdk-feat-")
    nodes = []
    try:
        def node(name):
            d = os.path.join(tmp, name)
            os.makedirs(d)
            n = Node(name, a.bin, d, ["--no-nostr"])
            nodes.append(n)
            return n
        U, M, N = node("Uyen"), node("Minh"), node("Nam")
        befriend(U, M)
        befriend(U, N)
        for lang in (["py", "js"] if not a.only else [a.only]):
            print(f"{'Python' if lang == 'py' else 'JavaScript'} SDK")
            scenario(lang, a.bin, tmp, U, M, N)
            examples(lang, a.bin, tmp, U, M)
    finally:
        for n in nodes:
            n.stop()
        if a.keep:
            print("logs in", tmp)
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    ok = sum(1 for r in RESULTS if r[1])
    print(f"\n{ok}/{len(RESULTS)} passed")
    for name, good, _, err in RESULTS:
        if not good:
            print(f"  FAILED {name}: {err}")
    sys.exit(0 if ok == len(RESULTS) else 1)


if __name__ == "__main__":
    main()
