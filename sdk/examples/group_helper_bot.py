"""Group helper: welcome message, rules button, automatic slow mode on spam,
admin-only moderation commands.

Add the bot to a group (group info → Bots → add @yourbot), turn on "Let the bot read all
messages" and make it an admin so it can see new members and moderate.

Run:  LUMORA_BOT_TOKEN=lumora_bot_... python3 group_helper_bot.py
"""
import collections
import os
import sys
import time

try:
    # pyrefly: ignore[missing-import]
    from lumora_bot import Bot, Button, LumoraError
except ImportError:  # running from the sdk/ folder without "pip install"
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "python"))
    # pyrefly: ignore[missing-import]
    from lumora_bot import Bot, Button, LumoraError

bot = Bot("Group Helper", data_dir=os.environ.get("BOT_DIR", "./group-helper"),
          about="Chào thành viên mới, nội quy, chống spam / Welcome, rules, anti-spam")

RULES = ("📜 Nội quy / Rules\n"
         "1. Tôn trọng mọi người / Be kind\n"
         "2. Không spam, không quảng cáo / No spam or ads\n"
         "3. Đúng chủ đề / Stay on topic")
SPAM_MSGS, SPAM_WINDOW = 6, 10      # 6 messages in 10 s from one person = spam
SLOW_SECONDS, SLOW_FOR = 30, 300    # then 30 s slow mode for 5 minutes
recent = collections.defaultdict(collections.deque)   # (group, user) -> message times


def rules_for(conv):
    return bot.storage.get("rules", {}).get(conv, RULES)


@bot.on_added_to_group
def hello_group(ctx):
    ctx.reply("Xin chào! Gõ /rules để xem nội quy. / Hi! Type /rules for the rules.",
              buttons=[[Button("📜 Nội quy / Rules", data="rules")]])


@bot.on_new_member
def welcome(ctx):
    # a mention notifies the newcomer (the bot may not know their name yet)
    ctx.reply("👋 Chào mừng bạn mới! Đọc nội quy trước nhé. / Welcome! Please read the rules.",
              buttons=[[Button("📜 Nội quy / Rules", data="rules")]], mentions=[ctx.sender], silent=True)


@bot.on_callback(data="rules")
@bot.command("rules", "Nội quy nhóm / Group rules", chats="group")
def rules(ctx):
    ctx.reply(rules_for(ctx.conv))


def group_admin(fn):
    """Only group admins (or the bot's own admins) may use the command."""
    def wrapper(ctx):
        if not (ctx.is_group_admin or ctx.is_admin):
            return ctx.reply("⛔ Chỉ quản trị viên nhóm. / Group admins only.")
        try:
            return fn(ctx)
        except LumoraError as e:
            if e.code in ("err.admin_only", "err.no_perm_remove", "err.group_syncing"):
                return ctx.reply("Hãy cho bot quyền quản trị và quyền đọc mọi tin. / Make the bot an admin with full access.")
            raise
    wrapper.__name__ = fn.__name__
    return wrapper


def target_of(ctx):
    """The member a moderation command is about: first @mention, else the replied-to message's author."""
    mentions = (ctx.event.get("meta") or {}).get("mentions") or []
    if mentions:
        return mentions[0]
    if ctx.reply_to:
        for m in bot.messages(ctx.conv, limit=200):
            if m["id"] == ctx.reply_to:
                return m["author"]
    return None


@bot.command("setrules", "Đổi nội quy / Change the rules", chats="group", hidden=True)
@group_admin
def set_rules(ctx):
    bot.storage.update_key("rules", lambda r: dict(r or {}, **{ctx.conv: ctx.args or RULES}), {})
    ctx.reply("✅ Đã lưu nội quy. / Rules saved.")


@bot.command("slowmode", "Chế độ chậm: /slowmode 30 (0 = tắt) / Slow mode", chats="group", hidden=True)
@group_admin
def slowmode(ctx):
    seconds = int(ctx.args or "0")
    bot.set_slow_mode(ctx.conv, seconds)
    ctx.reply(f"🐢 Chế độ chậm / Slow mode: {seconds}s" if seconds else "Đã tắt chế độ chậm. / Slow mode off.")


@bot.command("ban", "Cấm thành viên (trả lời tin của họ) / Ban (reply to them)", chats="group", hidden=True)
@group_admin
def ban(ctx):
    who = target_of(ctx)
    if not who:
        return ctx.reply("Trả lời một tin của người cần cấm rồi gõ /ban. / Reply to their message with /ban.")
    bot.group_ban(ctx.conv, who)
    ctx.reply(f"🚫 Đã cấm / Banned {bot.name_of(who)}.")


@bot.command("purge", "Xoá mọi tin của một người / Delete all their messages", chats="group", hidden=True)
@group_admin
def purge(ctx):
    who = target_of(ctx)
    if not who:
        return ctx.reply("Trả lời một tin của người đó rồi gõ /purge. / Reply to their message with /purge.")
    bot.group_purge_member(ctx.conv, who)
    ctx.reply("🧹 Đã xoá. / Deleted.", silent=True)


@bot.on_message(chats="group", kinds=None)
def anti_spam(ctx):
    now = time.time()
    q = recent[(ctx.conv, ctx.sender)]
    q.append(now)
    while q and now - q[0] > SPAM_WINDOW:
        q.popleft()
    if len(q) < SPAM_MSGS or ctx.is_group_admin:
        return
    q.clear()
    try:
        bot.set_slow_mode(ctx.conv, SLOW_SECONDS)
    except LumoraError as e:   # not an admin here: just warn
        bot.log.info("cannot slow down %s: %s", ctx.conv, e.code)
        return ctx.reply("⚠️ Chậm lại một chút nhé! / Please slow down!", silent=True)
    ctx.reply(f"🐢 Nhiều tin quá, bật chế độ chậm {SLOW_SECONDS}s trong 5 phút. / Slow mode on for 5 minutes.", silent=True)
    bot.after(SLOW_FOR, lambda: bot.set_slow_mode(ctx.conv, 0))


if __name__ == "__main__":
    bot.run()
