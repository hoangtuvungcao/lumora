// Test bot exercising the whole JavaScript SDK; driven by sdk/tests/test_features.py.
// Its twin is feature_bot.py: both must answer exactly the same way.
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Bot, Button, LumoraError } from "../js/lumora-bot.mjs";

const bot = new Bot({ name: "Feature Bot", dataDir: process.env.BOT_DIR, publicDirectory: false, about: "SDK test bot", lang: "en" });
let updates = 0;

bot.use(async (ctx, next) => {
  updates += 1;
  if (ctx.text === "/blocked-by-middleware") return;
  await next();
});

bot.command("start", "Start", (ctx) =>
  ctx.reply("MENU", [[Button("A", "pick:a"), Button("B", "pick:b")], [["Site", "https://getlumora.pages.dev"]]]));
bot.onCallback({ data: "pick:*" }, (ctx) => ctx.edit(`PICKED ${ctx.data}`));
bot.onCallback((ctx) => ctx.reply(`CB ${ctx.data}`));

bot.command("checklist", "Checklist", async (ctx) => {
  const m = await ctx.replyChecklist("Release", ["notes", "build"]);
  await bot.checklistAdd(ctx.conv, m.id, ["publish"]);
});
bot.onChecklist((ctx) => {
  const ch = ctx.changes.at(-1);
  const who = ch.by === ctx.sender ? "user" : "?";
  return ctx.reply(`CHECK ${ctx.checklist.done}/${ctx.checklist.total} ${ch.text} ${who}`);
});

bot.command("remind", "Reminder", (ctx) => ctx.replyReminder("Standup", Date.now() + 2500, { note: "room 2" }));
bot.onReminderDue((ctx) => { if (ctx.reminder.mine) return ctx.reply(`DUE ${ctx.reminder.title} ${ctx.reminder.note}`); });

bot.command("silent", "Silent", (ctx) => ctx.reply("SILENT", { silent: true }));

bot.command("kinds", "Other message kinds", async (ctx) => {
  await bot.sendPoll(ctx.conv, "Lunch?", ["Pho", "Rice"]);
  await bot.sendLocation(ctx.conv, 21.0285, 105.8542, "Hoan Kiem");
  await bot.sendContact(ctx.conv, bot.me.peer);
  const m = await ctx.reply("TO-EDIT");
  await bot.editMessage(ctx.conv, m.id, "EDITED");
  await bot.pinMessage(ctx.conv, m.id);
  await ctx.react("👍");
  await ctx.reply("MENTION", { mentions: [ctx.sender], reply: true });
  await bot.forwardMessage(m.id, ctx.conv);
});

bot.command("err", "Errors", async (ctx) => {
  const out = [];
  try { await bot.sendReminder(ctx.conv, "late", 1000); } catch (e) { if (e instanceof LumoraError) out.push(`${e.code}|${Boolean(e.message)}|${e.cmd}`); }
  try { await bot.call("recovery_phrase"); } catch (e) { out.push(e.code); }
  try { await bot.send(ctx.conv, "x", [[["t".repeat(70), "d"]]]); } catch (e) { out.push(e.code); }
  return ctx.reply("ERR " + out.join(" "));
});

bot.command("boom", "Handler error", () => { throw new TypeError("boom"); });
bot.onError((ctx, e) => ctx.reply(`ONERROR ${e.message}`));

bot.command("stats", "Stats", (ctx) => ctx.reply(`UPDATES ${updates > 3}`));
bot.command("job", "Job", (ctx) => { const conv = ctx.conv; bot.after(1, () => bot.send(conv, "JOB DONE")); });
bot.command("store", "Storage", (ctx) => ctx.reply(`STORED ${bot.storage.updateKey("n", (v) => (v || 0) + 1, 0)}`));

bot.onFile({ extensions: ["txt"] }, async (ctx) => {
  const path = await ctx.download({ timeoutMs: 60000 });
  const lines = (readFileSync(path, "utf8").match(/\n/g) || []).length;
  const hasPreview = Boolean(ctx.file.preview && ctx.file.preview.text);
  await ctx.reply(`FILE ${ctx.file.name} ${lines} ${hasPreview}`);
  const out = join(process.env.BOT_DIR, "summary.txt");
  writeFileSync(out, "summary\n");
  await ctx.replyFile(out, { preview: { kind: "text", text: "SUMMARY PREVIEW", lines: 1 } });
});
bot.onFile((ctx) => ctx.reply(`OTHER FILE ${ctx.file.name}`));

bot.onText(/^ping (\d+)$/, (ctx) => ctx.reply(`PONG ${ctx.match[1]}`));
bot.onMessage({ kinds: ["location"] }, (ctx) => ctx.reply(`LOC ${ctx.body.lat.toFixed(2)}`));
bot.onMessage((ctx) => ctx.reply(`ECHO ${ctx.text}`));

// ---- groups
bot.onAddedToGroup(async (ctx) => {
  const a = await bot.groupAccess(ctx.conv);
  await ctx.reply(`HELLO GROUP read_all=${a.readAll}`);
});
bot.onNewMember((ctx) => ctx.reply(`WELCOME ${ctx.member.peer.slice(0, 8)}`, { mentions: [ctx.sender] }));
bot.onMemberLeft((ctx) => ctx.reply(`BYE ${ctx.member.peer.slice(0, 8)}`));
bot.command("gping", "Group ping", (ctx) => ctx.reply("GPONG", [[Button("G", "g")]]), { chats: "group" });
bot.command("access", "Access", async (ctx) => {
  const a = await bot.groupAccess(ctx.conv);
  await ctx.reply(`ACCESS read_all=${a.readAll} admin=${a.admin} sender_admin=${await ctx.isGroupAdmin()}`);
}, { chats: "group" });
bot.command("slow", "Slow mode", async (ctx) => {
  await bot.setSlowMode(ctx.conv, Number(ctx.args || "0"));
  await ctx.reply(`SLOW ${(await bot.groupInfo(ctx.conv)).slow_mode_s}`);
}, { chats: "group" });
bot.command("ban", "Ban", async (ctx) => {
  const target = ctx.args.trim();
  await bot.groupBan(ctx.conv, target);
  await ctx.reply(`BANNED ${(await bot.groupInfo(ctx.conv)).banned.includes(target)}`);
}, { chats: "group" });
bot.command("purge", "Purge", async (ctx) => {
  await bot.groupPurgeMember(ctx.conv, ctx.args.trim());
  await ctx.reply("PURGED");
}, { chats: "group" });
bot.command("privateonly", "Private only", (ctx) => ctx.reply("PRIVATE OK"), { chats: "private" });

await bot.run();
