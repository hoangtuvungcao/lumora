// Team tasks: checklists, reminders and a daily stand-up message.
//
//   /todo Release 1.2: write notes; build; publish     → a checklist anyone can tick
//   /remind 30m Stand-up call                          → a reminder for everyone in the chat
//   /remind 2026-12-01 09:00 Pay the rent | bank app   → at a date/time, with a note
//   /tasks                                             → open checklists in this chat
//   /standup on|off                                    → daily 09:00 stand-up checklist
//
// Run:  LUMORA_BOT_TOKEN=lumora_bot_... node team-tasks-bot.mjs
const { Bot, LumoraError } = await import("lumora-bot").catch(() => import("../js/lumora-bot.mjs"));

const bot = new Bot({
  name: "Team Tasks",
  dataDir: process.env.BOT_DIR || "./team-tasks",
  about: "Danh sách việc và nhắc hẹn cho nhóm / Checklists and reminders for teams",
});

const UNITS = { s: 1, m: 60, h: 3600, d: 86400 };
const pad = (n) => String(n).padStart(2, "0");
const fmt = (d) => `${pad(d.getDate())}/${pad(d.getMonth() + 1)} ${pad(d.getHours())}:${pad(d.getMinutes())}`;

/** '30m Title', '2h Title', '2026-12-01 09:00 Title' or '09:00 Title' → [Date, rest]. */
function parseWhen(text) {
  let m = /^(\d+)([smhd])\s+(.+)$/s.exec(text);
  if (m) return [new Date(Date.now() + Number(m[1]) * UNITS[m[2]] * 1000), m[3]];
  m = /^(\d{4})-(\d{2})-(\d{2})\s+(\d{1,2}):(\d{2})\s+(.+)$/s.exec(text);
  if (m) return [new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]), m[6]];
  m = /^(\d{1,2}):(\d{2})\s+(.+)$/s.exec(text);
  if (m) {
    const at = new Date();
    at.setHours(+m[1], +m[2], 0, 0);
    if (at <= new Date()) at.setDate(at.getDate() + 1);
    return [at, m[3]];
  }
  return [null, text];
}

const remember = (msgId, conv) => bot.storage.updateKey("open", (o) => ({ ...(o || {}), [msgId]: conv }), {});

bot.command("todo", "Tạo danh sách việc / New checklist: /todo Title: a; b; c", async (ctx) => {
  const i = ctx.args.indexOf(":");
  const title = (i >= 0 ? ctx.args.slice(0, i) : ctx.args).trim();
  const items = (i >= 0 ? ctx.args.slice(i + 1) : "").split(";").map((s) => s.trim()).filter(Boolean);
  if (!title || !items.length) return ctx.reply("Cách dùng / Usage: /todo Tiêu đề: việc 1; việc 2; việc 3");
  const m = await ctx.replyChecklist(title, items);
  remember(m.id, ctx.conv);
});

bot.command("remind", "Nhắc hẹn / Reminder: /remind 30m Title | note", async (ctx) => {
  const [at, rest] = parseWhen(ctx.args.trim());
  if (!at) return ctx.reply("Cách dùng / Usage: /remind 30m Họp | ghi chú   ·   /remind 2026-12-01 09:00 Trả tiền nhà");
  const [title, ...note] = rest.split("|");
  try {
    await ctx.replyReminder(title.trim(), at, { note: note.join("|").trim() });
  } catch (e) {
    if (e instanceof LumoraError) return ctx.reply(`⚠️ ${e.message}`);   // e.g. err.reminder_past
    throw e;
  }
  await ctx.reply(`⏰ OK: ${fmt(at)}`, { silent: true });
});

bot.command("tasks", "Việc còn mở / Open checklists", async (ctx) => {
  const lines = [];
  for (const [mid, conv] of Object.entries(bot.storage.get("open", {}))) {
    if (conv !== ctx.conv) continue;
    const cl = await bot.checklist(conv, mid);
    if (cl && cl.done < cl.total) {
      const left = cl.items.filter((i) => !i.done).map((i) => i.text).join(", ");
      lines.push(`☐ ${cl.title} (${cl.done}/${cl.total}): ${left}`);
    }
  }
  await ctx.reply(lines.join("\n") || "🎉 Không còn việc nào. / Nothing open.");
});

bot.onChecklist(async (ctx) => {
  const cl = ctx.checklist;
  for (const ch of ctx.changes) {
    if (ch.done) bot.log.info(`${await bot.nameOf(ch.by)} ticked ${JSON.stringify(ch.text)}`);
  }
  if (cl.total && cl.done === cl.total) {
    bot.storage.updateKey("open", (o) => Object.fromEntries(Object.entries(o || {}).filter(([k]) => k !== cl.msg_id)), {});
    await ctx.reply(`🎉 Xong hết / All done: ${cl.title}`);
  }
});

bot.onReminderDue((ctx) => {
  const r = ctx.reminder;
  if (!r.mine) return ctx.reply(`⏰ ${r.title}`, { silent: true });   // a user's own reminder sent to the bot
  return ctx.reply(`⏰ Đến giờ / Time: ${r.title}` + (r.note ? `\n${r.note}` : ""));
});

bot.command("standup", "Stand-up 09:00 hằng ngày / Daily stand-up: on|off", (ctx) => {
  const on = ctx.args.trim().toLowerCase() !== "off";
  bot.storage.updateKey("standup", (s) => (on ? [...new Set([...(s || []), ctx.conv])].sort() : (s || []).filter((c) => c !== ctx.conv)), []);
  return ctx.reply(on ? "✅ Stand-up lúc 09:00 mỗi ngày. / Daily at 09:00." : "Đã tắt. / Off.");
});

bot.daily("09:00", async function morning() {
  const d = new Date();
  for (const conv of bot.storage.get("standup", [])) {
    try {
      const m = await bot.sendChecklist(conv, `Stand-up ${pad(d.getDate())}/${pad(d.getMonth() + 1)}`,
        ["Hôm qua / Yesterday", "Hôm nay / Today", "Vướng mắc / Blockers"], { silent: true });
      remember(m.id, conv);
    } catch (e) {
      if (!(e instanceof LumoraError)) throw e;
      bot.log.warn(`stand-up for ${conv} failed: ${e.code}`);
    }
  }
});

await bot.run();
