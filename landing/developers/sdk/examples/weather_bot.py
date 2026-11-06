"""Ví dụ bot Lumora (Python): chào hỏi, nút bấm, trả lời lại tin nhắn."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))
# pyrefly: ignore[missing-import]
from lumora_bot import Bot

bot = Bot("Thời tiết Bot", data_dir=os.environ.get("BOT_DIR", "./weather-bot"),
          about="Xem thời tiết nhanh các thành phố Việt Nam")

WEATHER = {"hn": "Hà Nội: 24°C, có mây", "hcm": "TP.HCM: 32°C, nắng", "dn": "Đà Nẵng: 28°C, mưa rào"}

@bot.command("start", "Bắt đầu")
def start(ctx):
    ctx.reply("Xin chào! Bạn muốn xem thời tiết ở đâu?",
              buttons=[[("Hà Nội", "hn"), ("TP.HCM", "hcm"), ("Đà Nẵng", "dn")]])

@bot.on_callback
def on_city(ctx):
    ctx.reply(WEATHER.get(ctx.data, "Chưa có dữ liệu"))

@bot.on_message
def echo(ctx):
    ctx.reply(f"Gõ /start để bắt đầu. Bạn vừa nói: {ctx.text}")

if __name__ == "__main__":
    bot.run()
