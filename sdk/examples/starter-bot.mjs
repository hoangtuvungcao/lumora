// Starter bot: commands, inline buttons, callbacks, editing a message, echo.
//
// Run:  LUMORA_BOT_TOKEN=lumora_bot_... node starter-bot.mjs
//       (without a token it starts a test bot named "Starter Bot")
const { Bot, Button } = await import("lumora-bot").catch(() => import("../js/lumora-bot.mjs"));

const bot = new Bot({
  name: "Starter Bot",
  dataDir: process.env.BOT_DIR || "./starter-bot",
  about: "Ví dụ: nút bấm và trả lời tin nhắn / Example: buttons and echo",
});

bot.command("start", "Bắt đầu / Start", (ctx) =>
  ctx.reply(`Chào ${ctx.senderName} 👋 Bấm thử nhé / Try a button:`, [
    [Button("👍 Thích / Like", "vote:up"), Button("👎", "vote:down")],
    [Button("🔢 Đếm / Count: 0", "count:0")],
  ]));

// every button whose data starts with "vote:"
bot.onCallback({ data: "vote:*" }, (ctx) =>
  ctx.edit("Cảm ơn! / Thanks! " + (ctx.data === "vote:up" ? "👍" : "👎")));

bot.onCallback({ pattern: /^count:(\d+)$/ }, (ctx) => {
  const n = Number(ctx.match[1]) + 1;
  return ctx.reply(`Đếm / Count: ${n}`, [[Button(`🔢 +1 (${n})`, `count:${n}`)]]);
});

bot.onMessage((ctx) => ctx.reply(`Bạn nói / You said: ${ctx.text}`, { reply: true }));

await bot.run();
