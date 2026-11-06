"""Team tasks: checklists, reminders and a daily stand-up message.

  /todo Release 1.2: write notes; build; publish     → a checklist anyone can tick
  /remind 30m Stand-up call                          → a reminder for everyone in the chat
  /remind 2026-12-01 09:00 Pay the rent | bank app   → at a date/time, with a note
  /tasks                                             → open checklists in this chat
  /standup on|off                                    → daily 09:00 stand-up checklist

Run:  LUMORA_BOT_TOKEN=lumora_bot_... python3 team_tasks_bot.py
"""
import datetime as dt
import os
import re
import sys

try:
    # pyrefly: ignore[missing-import]
    from lumora_bot import Bot, LumoraError
except ImportError:  # running from the sdk/ folder without "pip install"
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "python"))
    # pyrefly: ignore[missing-import]
    from lumora_bot import Bot, LumoraError

bot = Bot("Team Tasks", data_dir=os.environ.get("BOT_DIR", "./team-tasks"),
          about="Danh sách việc và nhắc hẹn cho nhóm / Checklists and reminders for teams")

UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400}


def parse_when(text):
    """'30m Title', '2h Title', '2026-12-01 09:00 Title' or '09:00 Title' → (datetime, rest)."""
    m = re.match(r"^(\d+)([smhd])\s+(.+)$", text)
    if m:
        return dt.datetime.now() + dt.timedelta(seconds=int(m.group(1)) * UNITS[m.group(2)]), m.group(3)
    m = re.match(r"^(\d{4}-\d{2}-\d{2})\s+(\d{1,2}:\d{2})\s+(.+)$", text)
    if m:
        return dt.datetime.strptime(f"{m.group(1)} {m.group(2)}", "%Y-%m-%d %H:%M"), m.group(3)
    m = re.match(r"^(\d{1,2}):(\d{2})\s+(.+)$", text)
    if m:
        at = dt.datetime.now().replace(hour=int(m.group(1)), minute=int(m.group(2)), second=0, microsecond=0)
        return (at if at > dt.datetime.now() else at + dt.timedelta(days=1)), m.group(3)
    return None, text


@bot.command("todo", "Tạo danh sách việc / New checklist: /todo Title: a; b; c")
def todo(ctx):
    title, _, rest = ctx.args.partition(":")
    items = [i.strip() for i in rest.split(";") if i.strip()]
    if not title.strip() or not items:
        return ctx.reply("Cách dùng / Usage: /todo Tiêu đề: việc 1; việc 2; việc 3")
    m = ctx.reply_checklist(title.strip(), items)
    bot.storage.update_key("open", lambda o: dict(o or {}, **{m["id"]: ctx.conv}), {})


@bot.command("remind", "Nhắc hẹn / Reminder: /remind 30m Title | note")
def remind(ctx):
    at, rest = parse_when(ctx.args.strip())
    if at is None:
        return ctx.reply("Cách dùng / Usage: /remind 30m Họp | ghi chú   ·   /remind 2026-12-01 09:00 Trả tiền nhà")
    title, _, note = rest.partition("|")
    try:
        ctx.reply_reminder(title.strip(), at, note=note.strip())
    except LumoraError as e:            # e.g. err.reminder_past
        return ctx.reply(f"⚠️ {e.message}")
    ctx.reply(f"⏰ OK: {at:%d/%m %H:%M}", silent=True)


@bot.command("tasks", "Việc còn mở / Open checklists")
def tasks(ctx):
    lines = []
    for mid, conv in bot.storage.get("open", {}).items():
        if conv != ctx.conv:
            continue
        cl = bot.checklist(conv, mid)
        if cl and cl["done"] < cl["total"]:
            todo_left = ", ".join(i["text"] for i in cl["items"] if not i["done"])
            lines.append(f"☐ {cl['title']} ({cl['done']}/{cl['total']}): {todo_left}")
    ctx.reply("\n".join(lines) or "🎉 Không còn việc nào. / Nothing open.")


@bot.on_checklist
def progress(ctx):
    cl = ctx.checklist
    for ch in ctx.changes:
        if ch.get("done"):
            bot.log.info("%s ticked %r", bot.name_of(ch["by"]), ch["text"])
    if cl["total"] and cl["done"] == cl["total"]:
        bot.storage.update_key("open", lambda o: {k: v for k, v in (o or {}).items() if k != cl["msg_id"]}, {})
        ctx.reply(f"🎉 Xong hết / All done: {cl['title']}")


@bot.on_reminder_due
def due(ctx):
    r = ctx.reminder
    if not r["mine"]:          # a user's own reminder sent to the bot: just acknowledge it
        return ctx.reply(f"⏰ {r['title']}", silent=True)
    ctx.reply(f"⏰ Đến giờ / Time: {r['title']}" + (f"\n{r['note']}" if r["note"] else ""))


@bot.command("standup", "Stand-up 09:00 hằng ngày / Daily stand-up: on|off")
def standup(ctx):
    on = ctx.args.strip().lower() != "off"
    bot.storage.update_key("standup", lambda s: sorted(set(s or []) | {ctx.conv}) if on else [c for c in (s or []) if c != ctx.conv], [])
    ctx.reply("✅ Stand-up lúc 09:00 mỗi ngày. / Daily at 09:00." if on else "Đã tắt. / Off.")


@bot.daily("09:00")
def morning():
    for conv in bot.storage.get("standup", []):
        try:
            m = bot.send_checklist(conv, f"Stand-up {dt.date.today():%d/%m}", ["Hôm qua / Yesterday", "Hôm nay / Today", "Vướng mắc / Blockers"], silent=True)
            bot.storage.update_key("open", lambda o: dict(o or {}, **{m["id"]: conv}), {})
        except LumoraError as e:
            bot.log.warning("stand-up for %s failed: %s", conv, e.code)


if __name__ == "__main__":
    bot.run()
