"""File summary: send the bot a .txt or .csv file and get a short summary back,
plus a summary file whose preview shows the result before anyone downloads it.

Run:  LUMORA_BOT_TOKEN=lumora_bot_... python3 file_summary_bot.py
"""
import collections
import csv
import io
import os
import re
import sys
import tempfile

try:
    # pyrefly: ignore[missing-import]
    from lumora_bot import Bot
except ImportError:  # running from the sdk/ folder without "pip install"
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "python"))
    # pyrefly: ignore[missing-import]
    from lumora_bot import Bot

bot = Bot("File Summary", data_dir=os.environ.get("BOT_DIR", "./file-summary"),
          about="Gửi tệp .txt/.csv để nhận tóm tắt / Send a .txt or .csv file for a summary")
MAX_BYTES = 5 * 1024 * 1024


def summarize_text(text):
    words = re.findall(r"\w+", text.lower())
    top = collections.Counter(w for w in words if len(w) > 3).most_common(5)
    return (f"Dòng / Lines: {text.count(chr(10)) + (1 if text and not text.endswith(chr(10)) else 0)}\n"
            f"Từ / Words: {len(words)}\nKý tự / Characters: {len(text)}\n"
            f"Hay gặp / Top words: {', '.join(f'{w} ({n})' for w, n in top) or '-'}")


def summarize_csv(text):
    rows = list(csv.reader(io.StringIO(text)))
    if not rows:
        return "Tệp trống. / Empty file."
    head, data = rows[0], rows[1:]
    out = [f"Hàng / Rows: {len(data)} · Cột / Columns: {len(head)}"]
    for i, name in enumerate(head):
        nums = []
        for r in data:
            try:
                nums.append(float(r[i].replace(",", "")))
            except (IndexError, ValueError):
                pass
        if nums and len(nums) >= len(data) / 2:
            out.append(f"• {name}: min {min(nums):g} · max {max(nums):g} · avg {sum(nums) / len(nums):.2f}")
        else:
            distinct = len({r[i] for r in data if i < len(r)})
            out.append(f"• {name}: {distinct} giá trị khác nhau / distinct values")
    return "\n".join(out)


@bot.command("start", "Bắt đầu / Start")
def start(ctx):
    ctx.reply("Gửi cho mình một tệp .txt hoặc .csv (≤ 5 MB). / Send me a .txt or .csv file (≤ 5 MB).")


@bot.on_file(extensions=["txt", "csv"])
def summarize(ctx):
    f = ctx.file
    if f["size"] > MAX_BYTES:
        return ctx.reply("Tệp lớn quá (tối đa 5 MB). / File too large (max 5 MB).")
    if f.get("preview") and f["preview"].get("text"):
        bot.log.info("preview of %s: %r", f["name"], f["preview"]["text"][:60])
    ctx.typing()
    path = ctx.download(timeout=120)
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    summary = summarize_csv(text) if f["name"].lower().endswith(".csv") else summarize_text(text)
    ctx.reply(f"📄 {f['name']}\n{summary}", reply=True)
    out = os.path.join(tempfile.gettempdir(), f"summary-{f['file_id'][:8]}.txt")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(f"Summary of {f['name']}\n\n{summary}\n")
    ctx.reply_file(out, preview={"kind": "text", "text": summary, "lines": summary.count("\n") + 1})


@bot.on_file
def other_files(ctx):
    ctx.reply("Mình chỉ đọc được .txt và .csv. / I can only read .txt and .csv files.")


if __name__ == "__main__":
    bot.run()
