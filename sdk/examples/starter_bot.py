"""Starter bot: commands, inline buttons, callbacks, editing a message, echo.

Run:  LUMORA_BOT_TOKEN=lumora_bot_... python3 starter_bot.py
      (without a token it starts a test bot named "Starter Bot")
"""
import os
import sys

try:
    # pyrefly: ignore[missing-import]
    from lumora_bot import Bot, Button
except ImportError:  # running from the sdk/ folder without "pip install"
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "python"))
    # pyrefly: ignore[missing-import]
    from lumora_bot import Bot, Button

bot = Bot("Starter Bot", data_dir=os.environ.get("BOT_DIR", "./starter-bot"),
          about="Ví dụ: nút bấm và trả lời tin nhắn / Example: buttons and echo")


@bot.command("start", "Bắt đầu / Start")
def start(ctx):
    ctx.reply(f"Chào {ctx.sender_name} 👋 Bấm thử nhé / Try a button:", buttons=[
        [Button("👍 Thích / Like", data="vote:up"), Button("👎", data="vote:down")],
        [Button("🔢 Đếm / Count: 0", data="count:0")],
    ])


@bot.on_callback(data="vote:*")              # every button whose data starts with "vote:"
def vote(ctx):
    ctx.edit("Cảm ơn! / Thanks! " + ("👍" if ctx.data == "vote:up" else "👎"))


@bot.on_callback(pattern=r"^count:(\d+)$")
def count(ctx):
    n = int(ctx.match.group(1)) + 1
    ctx.reply(f"Đếm / Count: {n}", buttons=[[Button(f"🔢 +1 ({n})", data=f"count:{n}")]])


@bot.on_message
def echo(ctx):
    ctx.reply(f"Bạn nói / You said: {ctx.text}", reply=True)


if __name__ == "__main__":
    bot.run()
