// Group helper: welcome message, rules button, automatic slow mode on spam,
// admin-only moderation commands.
//
// Add the bot to a group (group info → Bots → add @yourbot), turn on "Let the bot read all
// messages" and make it an admin so it can see new members and moderate.
//
// Run:  LUMORA_BOT_TOKEN=lumora_bot_... node group-helper-bot.mjs
const { Bot, Button, LumoraError } = await import("lumora-bot").catch(() => import("../js/lumora-bot.mjs"));

const bot = new Bot({
  name: "Group Helper",
  dataDir: process.env.BOT_DIR || "./group-helper",
  about: "Chào thành viên mới, nội quy, chống spam / Welcome, rules, anti-spam",
});

const RULES = "📜 Nội quy / Rules\n"
  + "1. Tôn trọng mọi người / Be kind\n"
  + "2. Không spam, không quảng cáo / No spam or ads\n"
  + "3. Đúng chủ đề / Stay on topic";
const SPAM_MSGS = 6, SPAM_WINDOW = 10;     // 6 messages in 10 s from one person = spam
const SLOW_SECONDS = 30, SLOW_FOR = 300;   // then 30 s slow mode for 5 minutes
const recent = new Map();                  // "group|user" -> message times (ms)

const rulesFor = (conv) => bot.storage.get("rules", {})[conv] ?? RULES;
const rulesButton = [[Button("📜 Nội quy / Rules", "rules")]];

bot.onAddedToGroup((ctx) =>
  ctx.reply("Xin chào! Gõ /rules để xem nội quy. / Hi! Type /rules for the rules.", rulesButton));

bot.onNewMember((ctx) =>
  // a mention notifies the newcomer (the bot may not know their name yet)
  ctx.reply("👋 Chào mừng bạn mới! Đọc nội quy trước nhé. / Welcome! Please read the rules.",
    { buttons: rulesButton, mentions: [ctx.sender], silent: true }));

const rules = (ctx) => ctx.reply(rulesFor(ctx.conv));
bot.onCallback({ data: "rules" }, rules);
bot.command("rules", "Nội quy nhóm / Group rules", rules, { chats: "group" });

/** Only group admins (or the bot's own admins) may use the command. */
const groupAdmin = (fn) => async (ctx) => {
  if (!(ctx.isAdmin || (await ctx.isGroupAdmin()))) return ctx.reply("⛔ Chỉ quản trị viên nhóm. / Group admins only.");
  try {
    return await fn(ctx);
  } catch (e) {
    if (e instanceof LumoraError && ["err.admin_only", "err.no_perm_remove", "err.group_syncing"].includes(e.code)) {
      return ctx.reply("Hãy cho bot quyền quản trị và quyền đọc mọi tin. / Make the bot an admin with full access.");
    }
    throw e;
  }
};

/** The member a moderation command is about: first @mention, else the replied-to message's author. */
async function targetOf(ctx) {
  const mentions = ctx.event.meta?.mentions || [];
  if (mentions.length) return mentions[0];
  if (ctx.replyTo) {
    const m = (await bot.messages(ctx.conv, { limit: 200 })).find((x) => x.id === ctx.replyTo);
    if (m) return m.author;
  }
  return null;
}

const groupOnly = { chats: "group", hidden: true };

bot.command("setrules", "Đổi nội quy / Change the rules", groupAdmin(async (ctx) => {
  bot.storage.updateKey("rules", (r) => ({ ...(r || {}), [ctx.conv]: ctx.args || RULES }), {});
  await ctx.reply("✅ Đã lưu nội quy. / Rules saved.");
}), groupOnly);

bot.command("slowmode", "Chế độ chậm: /slowmode 30 (0 = tắt) / Slow mode", groupAdmin(async (ctx) => {
  const seconds = parseInt(ctx.args || "0", 10) || 0;
  await bot.setSlowMode(ctx.conv, seconds);
  await ctx.reply(seconds ? `🐢 Chế độ chậm / Slow mode: ${seconds}s` : "Đã tắt chế độ chậm. / Slow mode off.");
}), groupOnly);

bot.command("ban", "Cấm thành viên (trả lời tin của họ) / Ban (reply to them)", groupAdmin(async (ctx) => {
  const who = await targetOf(ctx);
  if (!who) return ctx.reply("Trả lời một tin của người cần cấm rồi gõ /ban. / Reply to their message with /ban.");
  await bot.groupBan(ctx.conv, who);
  await ctx.reply(`🚫 Đã cấm / Banned ${await bot.nameOf(who)}.`);
}), groupOnly);

bot.command("purge", "Xóa mọi tin của một người / Delete all their messages", groupAdmin(async (ctx) => {
  const who = await targetOf(ctx);
  if (!who) return ctx.reply("Trả lời một tin của người đó rồi gõ /purge. / Reply to their message with /purge.");
  await bot.groupPurgeMember(ctx.conv, who);
  await ctx.reply("🧹 Đã xóa. / Deleted.", { silent: true });
}), groupOnly);

bot.onMessage({ chats: "group", kinds: null }, async (ctx) => {
  const now = Date.now();
  const key = `${ctx.conv}|${ctx.sender}`;
  const q = (recent.get(key) || []).filter((t) => now - t <= SPAM_WINDOW * 1000);
  q.push(now);
  recent.set(key, q);
  if (q.length < SPAM_MSGS || (await ctx.isGroupAdmin())) return;
  recent.delete(key);
  try {
    await bot.setSlowMode(ctx.conv, SLOW_SECONDS);
  } catch (e) {
    if (!(e instanceof LumoraError)) throw e;   // not an admin here: just warn
    bot.log.info(`cannot slow down ${ctx.conv}: ${e.code}`);
    return ctx.reply("⚠️ Chậm lại một chút nhé! / Please slow down!", { silent: true });
  }
  await ctx.reply(`🐢 Nhiều tin quá, bật chế độ chậm ${SLOW_SECONDS}s trong 5 phút. / Slow mode on for 5 minutes.`, { silent: true });
  bot.after(SLOW_FOR, () => bot.setSlowMode(ctx.conv, 0));
});

await bot.run();
