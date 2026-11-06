// File summary: send the bot a .txt or .csv file and get a short summary back,
// plus a summary file whose preview shows the result before anyone downloads it.
//
// Run:  LUMORA_BOT_TOKEN=lumora_bot_... node file-summary-bot.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const { Bot } = await import("lumora-bot").catch(() => import("../js/lumora-bot.mjs"));

const bot = new Bot({
  name: "File Summary",
  dataDir: process.env.BOT_DIR || "./file-summary",
  about: "Gửi tệp .txt/.csv để nhận tóm tắt / Send a .txt or .csv file for a summary",
});
const MAX_BYTES = 5 * 1024 * 1024;

function summarizeText(text) {
  const words = text.toLowerCase().match(/[\p{L}\p{N}_]+/gu) || [];
  const counts = new Map();
  for (const w of words) if (w.length > 3) counts.set(w, (counts.get(w) || 0) + 1);
  const top = [...counts].sort((a, b) => b[1] - a[1]).slice(0, 5);
  const lines = (text.match(/\n/g) || []).length + (text && !text.endsWith("\n") ? 1 : 0);
  return `Dòng / Lines: ${lines}\nTừ / Words: ${words.length}\nKý tự / Characters: ${[...text].length}\n`
    + `Hay gặp / Top words: ${top.map(([w, n]) => `${w} (${n})`).join(", ") || "-"}`;
}

/** Minimal CSV parser (quotes, commas, newlines in quotes). */
function parseCsv(text) {
  const rows = [];
  let row = [], cell = "", q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"' && text[i + 1] === '"') { cell += '"'; i++; } else if (c === '"') q = false; else cell += c;
    } else if (c === '"') q = true;
    else if (c === ",") { row.push(cell); cell = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(cell); rows.push(row); row = []; cell = "";
    } else cell += c;
  }
  if (cell || row.length) { row.push(cell); rows.push(row); }
  return rows;
}

function summarizeCsv(text) {
  const rows = parseCsv(text);
  if (!rows.length) return "Tệp trống. / Empty file.";
  const [head, ...data] = rows;
  const out = [`Hàng / Rows: ${data.length} · Cột / Columns: ${head.length}`];
  head.forEach((name, i) => {
    const nums = data.map((r) => Number(String(r[i] ?? "").replace(/,/g, ""))).filter((n, k) => data[k][i] !== undefined && data[k][i] !== "" && Number.isFinite(n));
    if (nums.length && nums.length >= data.length / 2) {
      const avg = nums.reduce((a, b) => a + b, 0) / nums.length;
      out.push(`• ${name}: min ${Math.min(...nums)} · max ${Math.max(...nums)} · avg ${avg.toFixed(2)}`);
    } else {
      out.push(`• ${name}: ${new Set(data.filter((r) => i < r.length).map((r) => r[i])).size} giá trị khác nhau / distinct values`);
    }
  });
  return out.join("\n");
}

bot.command("start", "Bắt đầu / Start", (ctx) =>
  ctx.reply("Gửi cho mình một tệp .txt hoặc .csv (≤ 5 MB). / Send me a .txt or .csv file (≤ 5 MB)."));

bot.onFile({ extensions: ["txt", "csv"] }, async (ctx) => {
  const f = ctx.file;
  if (f.size > MAX_BYTES) return ctx.reply("Tệp lớn quá (tối đa 5 MB). / File too large (max 5 MB).");
  if (f.preview?.text) bot.log.info(`preview of ${f.name}: ${JSON.stringify(f.preview.text.slice(0, 60))}`);
  await ctx.typing();
  const path = await ctx.download({ timeoutMs: 120000 });
  const text = readFileSync(path, "utf8");
  const summary = f.name.toLowerCase().endsWith(".csv") ? summarizeCsv(text) : summarizeText(text);
  await ctx.reply(`📄 ${f.name}\n${summary}`, { reply: true });
  const out = join(tmpdir(), `summary-${f.file_id.slice(0, 8)}.txt`);
  writeFileSync(out, `Summary of ${f.name}\n\n${summary}\n`);
  await ctx.replyFile(out, { preview: { kind: "text", text: summary, lines: summary.split("\n").length } });
});

bot.onFile((ctx) => ctx.reply("Mình chỉ đọc được .txt và .csv. / I can only read .txt and .csv files."));

await bot.run();
