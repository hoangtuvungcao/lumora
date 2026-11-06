"""Test bot exercising the whole Python SDK; driven by sdk/tests/test_features.py.
Its twin is feature_bot.mjs: both must answer exactly the same way."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "python"))
# pyrefly: ignore[missing-import]
from lumora_bot import Bot, Button, LumoraError  # noqa: E402

bot = Bot("Feature Bot", data_dir=os.environ["BOT_DIR"], public_directory=False, about="SDK test bot", lang="en")
seen = {"updates": 0}


@bot.middleware
def count(ctx, next):
    seen["updates"] += 1
    if ctx.text == "/blocked-by-middleware":
        return None
    return next()


@bot.command("start", "Start")
def start(ctx):
    ctx.reply("MENU", buttons=[[Button("A", data="pick:a"), Button("B", data="pick:b")], [("Site", "https://getlumora.pages.dev")]])


@bot.on_callback(data="pick:*")
def pick(ctx):
    ctx.edit(f"PICKED {ctx.data}")


@bot.on_callback
def other_callback(ctx):
    ctx.reply(f"CB {ctx.data}")


@bot.command("checklist", "Checklist")
def checklist(ctx):
    m = ctx.reply_checklist("Release", ["notes", "build"])
    bot.checklist_add(ctx.conv, m["id"], ["publish"])


@bot.on_checklist
def on_checklist(ctx):
    ch = ctx.changes[-1]
    who = "user" if ch.get("by") == ctx.sender else "?"
    ctx.reply(f"CHECK {ctx.checklist['done']}/{ctx.checklist['total']} {ch.get('text')} {who}")


@bot.command("remind", "Reminder")
def remind(ctx):
    ctx.reply_reminder("Standup", 2500 + __import__("time").time() * 1000, note="room 2")


@bot.on_reminder_due
def due(ctx):
    if ctx.reminder["mine"]:
        ctx.reply(f"DUE {ctx.reminder['title']} {ctx.reminder['note']}")


@bot.command("silent", "Silent")
def silent(ctx):
    ctx.reply("SILENT", silent=True)


@bot.command("kinds", "Other message kinds")
def kinds(ctx):
    bot.send_poll(ctx.conv, "Lunch?", ["Pho", "Rice"])
    bot.send_location(ctx.conv, 21.0285, 105.8542, "Hoan Kiem")
    bot.send_contact(ctx.conv, bot.me["peer"])
    m = ctx.reply("TO-EDIT")
    bot.edit_message(ctx.conv, m["id"], "EDITED")
    bot.pin_message(ctx.conv, m["id"])
    ctx.react("👍")
    ctx.reply("MENTION", mentions=[ctx.sender], reply=True)
    bot.forward_message(m["id"], ctx.conv)


@bot.command("err", "Errors")
def err(ctx):
    out = []
    try:
        bot.send_reminder(ctx.conv, "late", 1000)
    except LumoraError as e:
        out.append(f"{e.code}|{str(bool(e.message)).lower()}|{e.cmd}")
    try:
        bot.call("recovery_phrase")
    except LumoraError as e:
        out.append(e.code)
    try:
        bot.send(ctx.conv, "x", buttons=[[("t" * 70, "d")]])
    except LumoraError as e:
        out.append(e.code)
    ctx.reply("ERR " + " ".join(out))


@bot.command("boom", "Handler error")
def boom(ctx):
    raise ValueError("boom")


@bot.on_error
def on_error(ctx, e):
    ctx.reply(f"ONERROR {e}")


@bot.command("stats", "Stats")
def stats(ctx):
    ctx.reply(f"UPDATES {str(seen['updates'] > 3).lower()}")


@bot.command("job", "Job")
def job(ctx):
    conv = ctx.conv
    bot.after(1, lambda: bot.send(conv, "JOB DONE"))


@bot.command("store", "Storage")
def store(ctx):
    n = bot.storage.update_key("n", lambda v: (v or 0) + 1, 0)
    ctx.reply(f"STORED {n}")


@bot.on_file(extensions=["txt"])
def on_txt(ctx):
    path = ctx.download(timeout=60)
    with open(path, encoding="utf-8") as f:
        lines = f.read().count("\n")
    has_preview = bool(ctx.file.get("preview") and ctx.file["preview"].get("text"))
    ctx.reply(f"FILE {ctx.file['name']} {lines} {str(has_preview).lower()}")
    out = os.path.join(os.environ["BOT_DIR"], "summary.txt")
    with open(out, "w", encoding="utf-8") as f:
        f.write("summary\n")
    ctx.reply_file(out, preview={"kind": "text", "text": "SUMMARY PREVIEW", "lines": 1})


@bot.on_file
def on_other_file(ctx):
    ctx.reply(f"OTHER FILE {ctx.file['name']}")


@bot.on_text(r"^ping (\d+)$")
def ping(ctx):
    ctx.reply(f"PONG {ctx.match.group(1)}")


@bot.on_message(kinds=["location"])
def location(ctx):
    ctx.reply(f"LOC {ctx.body['lat']:.2f}")


@bot.on_message
def echo(ctx):
    ctx.reply(f"ECHO {ctx.text}")


# ---- groups
@bot.on_added_to_group
def added(ctx):
    a = bot.group_access(ctx.conv)
    ctx.reply(f"HELLO GROUP read_all={str(a['read_all']).lower()}")


@bot.on_new_member
def welcome(ctx):
    ctx.reply(f"WELCOME {ctx.member['peer'][:8]}", mentions=[ctx.sender])


@bot.on_member_left
def left(ctx):
    ctx.reply(f"BYE {ctx.member['peer'][:8]}")


@bot.command("gping", "Group ping", chats="group")
def gping(ctx):
    ctx.reply("GPONG", buttons=[[Button("G", data="g")]])


@bot.command("access", "Access", chats="group")
def access(ctx):
    a = bot.group_access(ctx.conv)
    ctx.reply(f"ACCESS read_all={str(a['read_all']).lower()} admin={str(a['admin']).lower()} sender_admin={str(ctx.is_group_admin).lower()}")


@bot.command("slow", "Slow mode", chats="group")
def slow(ctx):
    bot.set_slow_mode(ctx.conv, int(ctx.args or "0"))
    ctx.reply(f"SLOW {bot.group_info(ctx.conv)['slow_mode_s']}")


@bot.command("ban", "Ban", chats="group")
def ban(ctx):
    target = ctx.args.strip()
    bot.group_ban(ctx.conv, target)
    ctx.reply(f"BANNED {str(target in bot.group_info(ctx.conv)['banned']).lower()}")


@bot.command("purge", "Purge", chats="group")
def purge(ctx):
    bot.group_purge_member(ctx.conv, ctx.args.strip())
    ctx.reply("PURGED")


@bot.command("privateonly", "Private only", chats="private")
def private_only(ctx):
    ctx.reply("PRIVATE OK")


if __name__ == "__main__":
    bot.run()
