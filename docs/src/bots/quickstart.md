# Bắt đầu nhanh | Quickstart

<!-- Bilingual source for /developers/quickstart/. Format: "<!-- section: id -->" starts a section
     whose first line is "## Tiếng Việt | English"; "<!-- vi -->", "<!-- en -->" and "<!-- all -->"
     mark the language of the lines that follow ("all" = shown in both, e.g. code).
     Rendered by branding/tools/dev_pages.py. -->

<!-- section: need -->
## Bạn cần gì | What you need

<!-- vi -->
Khoảng 5 phút và:

- Ứng dụng Lumora trên điện thoại hoặc máy tính (để tạo bot và trò chuyện thử).
- Một máy tính chạy bot: Windows, macOS, Linux hoặc Raspberry Pi, có **Python 3.8+** hoặc **Node.js 18+**.
- **Lumora Bot Runner**: chương trình nhỏ giúp đoạn mã bot kết nối vào Lumora. Tải ở [trang Tải về](https://getlumora.pages.dev/download/#bot-runner).
<!-- en -->
About 5 minutes and:

- The Lumora app on your phone or computer (to create the bot and chat with it).
- A computer to run the bot: Windows, macOS, Linux or a Raspberry Pi, with **Python 3.8+** or **Node.js 18+**.
- **Lumora Bot Runner**: a small program that connects your bot code to Lumora. Get it on the [Download page](https://getlumora.pages.dev/download/#bot-runner).

<!-- section: token -->
## 1. Lấy token từ Xưởng Bot | 1. Get a token from Bot Studio

<!-- vi -->
1. Mở Lumora, mở **Xưởng Bot** (ghim đầu danh sách chat, hoặc Cài đặt → Bot của tôi).
2. Gửi `/newbot`, đặt tên hiển thị (ví dụ *Cửa hàng Hoa Mai*).
3. Chọn @tên kết thúc bằng `bot`, ví dụ `hoamai_bot`.
4. Xưởng Bot gửi lại một **token** dạng `lumora_bot_…`. Chép token đó.

Mỗi tài khoản tạo được tối đa 20 bot. Token là chìa khoá của bot: đừng gửi cho ai và đừng đưa lên mạng. Nếu lỡ lộ: gửi `/mybots` trong Xưởng Bot, chọn bot rồi bấm **Thu hồi mã** để nhận token mới (xem [Bảo mật](https://getlumora.pages.dev/developers/production/#security)).
<!-- en -->
1. Open Lumora and open **Bot Studio** (pinned at the top of the chat list, or Settings → My bots).
2. Send `/newbot` and pick a display name (for example *Hoa Mai Shop*).
3. Pick an @username ending in `bot`, for example `hoamai_bot`.
4. Bot Studio replies with a **token** like `lumora_bot_…`. Copy it.

Each account can create up to 20 bots. The token is your bot's key: never share it or put it online. If it leaks: send `/mybots` in Bot Studio, pick the bot and tap **Revoke token** to get a new one (see [Security](https://getlumora.pages.dev/developers/production/#security)).

<!-- section: install -->
## 2. Cài SDK | 2. Install the SDK

<!-- vi -->
Chọn một cách. SDK chỉ là một tệp, không cần thư viện nào khác.
<!-- en -->
Pick one. The SDK is a single file with no dependencies.
<!-- all -->
```bash
# Python
pip install https://getlumora.pages.dev/developers/packages/lumora_bot-1.1.0-py3-none-any.whl
# JavaScript (Node.js)
npm install https://getlumora.pages.dev/developers/packages/lumora-bot-1.1.0.tgz
```
<!-- vi -->
Hoặc tải thẳng [lumora_bot.py](https://getlumora.pages.dev/developers/sdk/python/lumora_bot.py) / [lumora-bot.mjs](https://getlumora.pages.dev/developers/sdk/js/lumora-bot.mjs) và đặt cạnh tệp bot của bạn.
<!-- en -->
Or download [lumora_bot.py](https://getlumora.pages.dev/developers/sdk/python/lumora_bot.py) / [lumora-bot.mjs](https://getlumora.pages.dev/developers/sdk/js/lumora-bot.mjs) and put it next to your bot file.

<!-- section: code -->
## 3. Viết bot | 3. Write the bot

<!-- vi -->
Tạo tệp `bot.py` (hoặc `bot.mjs`):
<!-- en -->
Create `bot.py` (or `bot.mjs`):
<!-- all -->
```python
from lumora_bot import Bot

bot = Bot()          # đọc token từ LUMORA_BOT_TOKEN / reads the token from LUMORA_BOT_TOKEN

@bot.command("start", "Bắt đầu")
def start(ctx):
    ctx.reply(f"Xin chào {ctx.sender_name}! 👋", buttons=[[("Bấm thử", "hi")]])

@bot.on_callback(data="hi")
def pressed(ctx):
    ctx.edit("Bạn vừa bấm nút ✅")

@bot.on_message
def echo(ctx):
    ctx.reply(f"Bạn nói: {ctx.text}")

bot.run()
```
```js
import { Bot } from "lumora-bot";

const bot = new Bot();   // đọc token từ LUMORA_BOT_TOKEN / reads the token from LUMORA_BOT_TOKEN

bot.command("start", "Bắt đầu", (ctx) =>
  ctx.reply(`Xin chào ${ctx.senderName}! 👋`, [[{ text: "Bấm thử", data: "hi" }]]));

bot.onCallback({ data: "hi" }, (ctx) => ctx.edit("Bạn vừa bấm nút ✅"));

bot.onMessage((ctx) => ctx.reply(`Bạn nói: ${ctx.text}`));

await bot.run();
```

<!-- section: run -->
## 4. Chạy | 4. Run it

<!-- vi -->
Cho SDK biết token và nơi đặt Lumora Bot Runner, rồi chạy:
<!-- en -->
Tell the SDK the token and where Lumora Bot Runner is, then run:
<!-- all -->
```bash
# Linux / macOS
chmod +x ./lumora-bot-runner-linux-x86_64          # một lần / once
export LUMORA_BOT_TOKEN="lumora_bot_..."
export LUMORAD=./lumora-bot-runner-linux-x86_64
python3 bot.py                                     # hoặc / or: node bot.mjs
```
```bat
REM Windows (Command Prompt)
set LUMORA_BOT_TOKEN=lumora_bot_...
set LUMORAD=lumora-bot-runner-windows-x86_64.exe
python bot.py
```
<!-- vi -->
Khi thấy dòng này là bot đã sẵn sàng:
<!-- en -->
When you see this line, the bot is ready:
<!-- all -->
```text
🤖 @hoamai_bot·k7q2xz is online — ID 123 456 789  (…)
```

<!-- section: try -->
## 5. Nhắn thử | 5. Say hi

<!-- vi -->
Trong Lumora, tìm @tên của bot (hoặc mã 9 số ở trên), bấm **Nhắn tin** rồi gửi `/start`. Bot trả lời kèm một nút bấm; bấm thử để thấy tin nhắn được sửa ngay. Gõ `/` để thấy menu lệnh.

Dừng bot bằng Ctrl+C. Bot lưu mọi thứ trong thư mục dữ liệu (mặc định `./lumora-bot`); chạy lại là bot tiếp tục với cùng @tên và người dùng.
<!-- en -->
In Lumora, search for your bot's @username (or the 9-digit ID above), tap **Message** and send `/start`. The bot answers with a button; press it to see the message update in place. Type `/` to see the command menu.

Stop the bot with Ctrl+C. Everything is kept in the data folder (default `./lumora-bot`); start it again and it carries on with the same @username and users.

<!-- section: next -->
## Tiếp theo | Next steps

<!-- vi -->
- [Hướng dẫn theo tính năng](https://getlumora.pages.dev/developers/guides/): nút bấm, nhóm, quyền, lưu trữ, tệp, danh sách việc, nhắc hẹn, gửi hàng loạt, xử lý lỗi.
- [Ví dụ đầy đủ](https://getlumora.pages.dev/developers/examples/): bot quản lý nhóm, bot việc nhóm, bot tóm tắt tệp.
- [Vận hành](https://getlumora.pages.dev/developers/production/): chạy 24/7, bảo mật token, giới hạn và câu hỏi thường gặp.
- Không chạy được? Xem [Khắc phục sự cố](https://getlumora.pages.dev/developers/production/#troubleshooting).
<!-- en -->
- [Feature guides](https://getlumora.pages.dev/developers/guides/): buttons, groups, permissions, storage, files, checklists, reminders, broadcasts, error handling.
- [Full examples](https://getlumora.pages.dev/developers/examples/): a group helper, a team tasks bot, a file summary bot.
- [Production](https://getlumora.pages.dev/developers/production/): running 24/7, token security, limits and FAQ.
- Something wrong? See [Troubleshooting](https://getlumora.pages.dev/developers/production/#troubleshooting).
