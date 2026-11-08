"""Bot kiểm tra / Test bot — xác nhận token Bot Studio hoạt động.

Chạy / Run:  python3 bots/test-bot/bot.py
Token đọc từ bots/test-bot/.env (không commit) hoặc biến môi trường LUMORA_BOT_TOKEN.
"""
import os
import sys
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
try:
    # pyrefly: ignore[missing-import]
    from lumora_bot import Bot, Button
except ImportError:  # chạy trong repo, chưa pip install
    sys.path.insert(0, os.path.join(ROOT, "sdk", "python"))
    # pyrefly: ignore[missing-import]
    from lumora_bot import Bot, Button

# nạp .env (KEY=VALUE) nếu có
env_file = os.path.join(HERE, ".env")
if os.path.exists(env_file):
    for line in open(env_file, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())

if not os.environ.get("LUMORAD"):
    local = os.path.join(ROOT, "core", "target-md", "debug", "lumorad")
    if os.path.exists(local):
        os.environ["LUMORAD"] = local

bot = Bot(data_dir=os.environ.get("BOT_DIR", os.path.join(HERE, "data")),
          about="Bot kiểm tra hoạt động / Health-check bot")
STARTED = time.time()


@bot.on_start
def online():
    print("✅ Bot đã online — mở app Lumora, thêm bot theo ID ở trên và gửi /start", flush=True)


@bot.command("start", "Bắt đầu / Start")
def start(ctx):
    ctx.reply(f"Chào {ctx.sender_name} 👋 Bot đang hoạt động! / The bot is working!", buttons=[
        [Button("🏓 Ping", data="ping"), Button("⏱ Uptime", data="uptime")],
    ])


@bot.command("ping", "Kiểm tra phản hồi / Check response")
def ping(ctx):
    ctx.reply("🏓 Pong!")


@bot.command("time", "Giờ máy chủ / Server time")
def now(ctx):
    ctx.reply("🕒 " + datetime.now().strftime("%H:%M:%S %d/%m/%Y"))


def _uptime() -> str:
    s = int(time.time() - STARTED)
    return f"⏱ Uptime: {s // 3600}h {s % 3600 // 60}m {s % 60}s"


@bot.on_callback(data="ping")
def cb_ping(ctx):
    ctx.edit("🏓 Pong! (từ nút / from button)")


@bot.on_callback(data="uptime")
def cb_uptime(ctx):
    ctx.edit(_uptime())


@bot.on_added_to_group
def added(ctx):
    print(f"➕ Đã vào nhóm {ctx.gid}", flush=True)
    ctx.reply("Xin chào nhóm 👋 Gõ /ping hoặc /start để kiểm tra bot.")


@bot.on_message(chats="private")     # trong nhóm chỉ trả lời lệnh, không nhắc lại mọi tin
def echo(ctx):
    ctx.reply(f"Bạn nói / You said: {ctx.text}", reply=True)


if __name__ == "__main__":
    bot.run()
