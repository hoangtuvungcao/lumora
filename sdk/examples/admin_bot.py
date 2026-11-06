"""Ví dụ bot có phân quyền admin, vai trò, lưu trữ và gửi hàng loạt."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))
# pyrefly: ignore[missing-import]
from lumora_bot import Bot

ADMINS = [a for a in os.environ.get("BOT_ADMINS", "").split(",") if a]
bot = Bot("Cửa hàng Bot", data_dir=os.environ.get("BOT_DIR", "./shop-bot"), admins=ADMINS, about="Đặt hàng & khuyến mãi")

@bot.command("start", "Bắt đầu")
def start(ctx):
    n = bot.storage.get("visits", 0) + 1
    bot.storage["visits"] = n
    ctx.reply(f"Chào bạn! Bạn là khách thứ {n}", buttons=[[("Xem hàng", "menu")]])

@bot.command("promo", "Gửi khuyến mãi cho mọi người", admin_only=True)
def promo(ctx):
    sent = bot.broadcast(ctx.args or "Giảm 20% hôm nay!")
    ctx.reply(f"Đã gửi cho {sent} người.")

@bot.command("addmod", "Cấp quyền mod", admin_only=True)
def addmod(ctx):
    bot.roles.grant(ctx.args.strip(), "mod")
    ctx.reply("Đã cấp quyền mod.")

@bot.command("stats", "Thống kê", role="mod")
def stats(ctx):
    ctx.reply(f"Lượt truy cập: {bot.storage.get('visits', 0)} — người dùng: {len(bot.users())}")

@bot.on_callback
def on_btn(ctx):
    if ctx.data == "menu":
        ctx.reply("Cà phê 25k\nTrà sữa 30k")

if __name__ == "__main__":
    bot.run()
