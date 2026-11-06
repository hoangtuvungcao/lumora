// Ví dụ bot Lumora (JavaScript / Node.js ≥ 18)
import { Bot } from "../js/lumora-bot.mjs";

const bot = new Bot({ name: "Echo Bot", dataDir: process.env.BOT_DIR || "./echo-bot", about: "Nhắc lại mọi tin nhắn" });

bot.command("start", "Bắt đầu", (ctx) =>
  ctx.reply("Chào bạn Bấm thử nút nhé:", [[{ text: "Thích", data: "like" }, { text: "Trang chủ", url: "https://getlumora.pages.dev" }]])
);
bot.onCallback((ctx) => ctx.reply(`Cảm ơn! Bạn đã bấm: ${ctx.data}`));
bot.onMessage((ctx) => ctx.reply(`Bạn nói: ${ctx.text}`));

await bot.run();
