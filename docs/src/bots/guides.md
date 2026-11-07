# Hướng dẫn | Guides

<!-- Bilingual source for /developers/guides/ (format: see quickstart.md). Every snippet uses
     only the SDK API; the full bots in sdk/examples/ are tested end to end. -->

<!-- section: commands -->
## Lệnh | Commands

<!-- vi -->
Lệnh là tin bắt đầu bằng `/`. Mô tả của lệnh hiện trong menu lệnh của ứng dụng (gõ `/`) và trong `/help`, SDK tự tạo `/help` nếu bạn không viết. Phần chữ sau lệnh nằm trong `ctx.args`.

`chats="private"` chỉ nhận lệnh trong tin nhắn riêng, `chats="group"` chỉ trong nhóm. Trong nhóm, người dùng có thể gõ `/lenh@tenbot`; lệnh gửi cho bot khác (`/lenh@botkhac`) được bỏ qua.
<!-- en -->
Commands are messages starting with `/`. Their descriptions appear in the app's command menu (type `/`) and in `/help`, which the SDK writes for you unless you define it. The text after the command is in `ctx.args`.

`chats="private"` only accepts the command in direct chats, `chats="group"` only in groups. In groups people may type `/command@yourbot`; commands meant for another bot (`/command@otherbot`) are ignored.
<!-- all -->
```python
@bot.command("start", "Bắt đầu")
def start(ctx):
    ctx.reply("Chào bạn! Gõ /price <tên món> để xem giá.")

@bot.command("price", "Xem giá: /price cà phê", chats="private")
def price(ctx):
    item = ctx.args.strip().lower() or "cà phê"
    ctx.reply(f"{item}: 25.000đ")
```
```js
bot.command("start", "Bắt đầu", (ctx) => ctx.reply("Chào bạn! Gõ /price <tên món> để xem giá."));

bot.command("price", "Xem giá: /price cà phê", (ctx) => {
  const item = ctx.args.trim().toLowerCase() || "cà phê";
  return ctx.reply(`${item}: 25.000đ`);
}, { chats: "private" });
```

<!-- section: text -->
## Tin nhắn và bộ lọc | Messages and filters

<!-- vi -->
- `on_text(regex)` / `onText(regex)`: tin chữ khớp biểu thức; kết quả khớp nằm trong `ctx.match`.
- `on_message`: mọi tin chữ không phải lệnh. Thêm `kinds=[...]` để nhận loại khác: `"file"`, `"voice"`, `"sticker"`, `"location"`, `"contact"`, `"poll"`, `"checklist"`, `"reminder"` (`None`/`null` = tất cả).
- Bộ lọc cụ thể (regex, dữ liệu nút, đuôi tệp) chạy trước và **chỉ hàm khớp đầu tiên chạy**; các hàm "nhận tất cả" chỉ chạy khi không bộ lọc nào khớp.
- Tin của cùng một cuộc trò chuyện được xử lý lần lượt theo thứ tự; các cuộc trò chuyện khác nhau chạy song song.
<!-- en -->
- `on_text(regex)` / `onText(regex)`: text messages matching a regular expression; the match is in `ctx.match`.
- `on_message`: every text message that is not a command. Add `kinds=[...]` for other kinds: `"file"`, `"voice"`, `"sticker"`, `"location"`, `"contact"`, `"poll"`, `"checklist"`, `"reminder"` (`None`/`null` = all).
- Specific filters (regex, button data, file extension) run first and **only the first match runs**; catch-all handlers run only when no specific filter matched.
- Messages of one conversation are handled one at a time, in order; different conversations run in parallel.
<!-- all -->
```python
@bot.on_text(r"(?i)\b(giờ mở cửa|opening hours)\b")
def hours(ctx):
    ctx.reply("7:00–22:00 mỗi ngày")

@bot.on_message(kinds=["location"])
def where(ctx):
    ctx.reply(f"📍 {ctx.body['lat']:.4f}, {ctx.body['lon']:.4f}")

@bot.on_message                      # mọi tin chữ khác / every other text
def fallback(ctx):
    ctx.reply("Mình chưa hiểu, gõ /help nhé.")
```
```js
bot.onText(/\b(giờ mở cửa|opening hours)\b/i, (ctx) => ctx.reply("7:00–22:00 mỗi ngày"));

bot.onMessage({ kinds: ["location"] }, (ctx) =>
  ctx.reply(`📍 ${ctx.body.lat.toFixed(4)}, ${ctx.body.lon.toFixed(4)}`));

bot.onMessage((ctx) => ctx.reply("Mình chưa hiểu, gõ /help nhé."));   // mọi tin chữ khác
```

<!-- section: buttons -->
## Nút bấm | Buttons

<!-- vi -->
Gắn nút dưới tin nhắn: mỗi hàng là một danh sách, tối đa 8 hàng × 8 nút, chữ và dữ liệu mỗi nút tối đa 64 ký tự. Nút có `url` mở trang web; nút có `data` gửi về bot một *callback*.

- `on_callback(data="mua:*")`: dữ liệu bắt đầu bằng `mua:`; `pattern=` để dùng regex.
- `ctx.edit("…")` sửa ngay tin nhắn chứa nút (tiện cho menu, bình chọn, phân trang).
- Trong nhóm, `ctx.reply` trả lời ngay trong nhóm đó.
<!-- en -->
Attach buttons under a message: each row is a list, at most 8 rows × 8 buttons, text and data up to 64 characters each. A button with a `url` opens a web page; a button with `data` sends the bot a *callback*.

- `on_callback(data="buy:*")`: data starting with `buy:`; use `pattern=` for a regex.
- `ctx.edit("…")` updates the message that holds the button (handy for menus, votes, paging).
- In a group, `ctx.reply` answers in that group.
<!-- all -->
```python
from lumora_bot import Button

@bot.command("menu", "Thực đơn")
def menu(ctx):
    ctx.reply("Hôm nay có gì?", buttons=[
        [Button("☕ Cà phê 25k", data="buy:cafe"), Button("🧋 Trà sữa 30k", data="buy:tea")],
        [Button("🌐 Trang web", url="https://getlumora.pages.dev")],
    ])

@bot.on_callback(data="buy:*")
def buy(ctx):
    item = ctx.data.split(":", 1)[1]
    ctx.edit(f"✅ Đã nhận đơn: {item}")
```
```js
import { Bot, Button } from "lumora-bot";

bot.command("menu", "Thực đơn", (ctx) => ctx.reply("Hôm nay có gì?", [
  [Button("☕ Cà phê 25k", "buy:cafe"), Button("🧋 Trà sữa 30k", "buy:tea")],
  [Button("🌐 Trang web", { url: "https://getlumora.pages.dev" })],
]));

bot.onCallback({ data: "buy:*" }, (ctx) => ctx.edit(`✅ Đã nhận đơn: ${ctx.data.split(":")[1]}`));
```

<!-- section: groups -->
## Nhóm và chế độ riêng tư | Groups and privacy mode

<!-- vi -->
Bot không tự vào nhóm và không tự nhắn cho ai: **quản trị viên nhóm** thêm bot (Thông tin nhóm → Bot → thêm @tenbot). Khi thêm, quản trị viên chọn một trong hai chế độ:

| | Chế độ riêng tư (mặc định) | Cho phép đọc mọi tin |
|---|---|---|
| Bot thấy | lệnh `/…`, tin nhắc @bot, tin trả lời bot | mọi tin trong nhóm |
| Gửi tin, nút bấm, danh sách việc, nhắc hẹn | có | có |
| Sửa, xoá, ghim, thả cảm xúc trong nhóm | không | có |
| Biết thành viên mới (`on_new_member`) | không | có |
| Việc của quản trị viên (cấm, chế độ chậm, xoá tin) | không | có, khi bot là quản trị viên |

Lưu ý hiện tại:

- Chọn chế độ **ngay lúc thêm bot**. Đổi chế độ sau đó chưa có tác dụng với bot đã ở trong nhóm.
- Ở chế độ riêng tư, người vào nhóm *sau* khi bot được thêm chưa dùng được lệnh của bot. Nhóm có thành viên mới thường xuyên nên dùng chế độ "đọc mọi tin".
- Nhóm bật chế độ chậm áp dụng cả cho bot (trừ khi bot là quản trị viên): lỗi `err.slow_mode`.

`bot.group_access(conv)` cho biết bot đang có quyền gì trong một nhóm. Có thể tắt hẳn việc vào nhóm bằng `Bot(allow_groups=False)`.
<!-- en -->
Bots never join groups or message people on their own: a **group admin** adds the bot (Group info → Bots → add @yourbot). While adding it, the admin picks one of two modes:

| | Privacy mode (default) | Read all messages |
|---|---|---|
| The bot sees | `/commands`, messages that @mention it, replies to it | every message |
| Send messages, buttons, checklists, reminders | yes | yes |
| Edit, delete, pin, react in the group | no | yes |
| Hears about new members (`on_new_member`) | no | yes |
| Admin actions (ban, slow mode, purge) | no | yes, when the bot is an admin |

Current limitations:

- Pick the mode **when adding the bot**. Changing it later has no effect on a bot that is already in the group.
- In privacy mode, people who join *after* the bot was added can't use its commands yet. Groups that often get new members should use "Read all messages".
- A group's slow mode applies to the bot too (unless it is an admin): error `err.slow_mode`.

`bot.group_access(conv)` tells you what the bot may do in a group. Turn groups off entirely with `Bot(allow_groups=False)`.
<!-- all -->
```python
@bot.on_added_to_group
def hello(ctx):
    access = bot.group_access(ctx.conv)            # {"read_all": bool, "admin": bool}
    ctx.reply("Xin chào nhóm! Gõ /rules để xem nội quy.")

@bot.on_new_member                                 # cần "đọc mọi tin" / needs "read all"
def welcome(ctx):
    ctx.reply("👋 Chào mừng bạn mới!", mentions=[ctx.sender], silent=True)

@bot.command("rules", "Nội quy", chats="group")
def rules(ctx):
    ctx.reply("1. Tôn trọng nhau  2. Không spam")
```
```js
bot.onAddedToGroup(async (ctx) => {
  const access = await bot.groupAccess(ctx.conv);  // { readAll, admin }
  await ctx.reply("Xin chào nhóm! Gõ /rules để xem nội quy.");
});

bot.onNewMember((ctx) => ctx.reply("👋 Chào mừng bạn mới!", { mentions: [ctx.sender], silent: true }));

bot.command("rules", "Nội quy", (ctx) => ctx.reply("1. Tôn trọng nhau  2. Không spam"), { chats: "group" });
```

<!-- section: roles -->
## Quản trị viên và vai trò | Admins and roles

<!-- vi -->
Có hai loại quyền, đừng nhầm:

- **Quản trị viên của bot** (`Bot(admins=[...])`): người điều hành bot, ghi bằng `@tên·mã` hoặc mã người dùng. Dùng được lệnh `admin_only=True` (lệnh này được ẩn khỏi menu) và mọi vai trò. Kiểm tra bằng `ctx.is_admin`.
- **Vai trò của bot** (`bot.roles`): nhãn tuỳ ý như `"mod"`, `"vip"`, lưu trong bộ nhớ của bot. Dùng `role="mod"` trên lệnh hoặc `ctx.has_role("mod")`.
- **Quản trị viên nhóm**: quyền trong một nhóm cụ thể, kiểm tra bằng `ctx.is_group_admin` (JS: `await ctx.isGroupAdmin()`).

Việc quản trị nhóm (`group_ban`, `group_remove`, `set_slow_mode`, `group_settings`, `group_purge_member`, xoá tin của người khác) chỉ làm được khi bot là quản trị viên nhóm và có quyền đọc mọi tin; nếu không sẽ có lỗi `err.admin_only` hoặc `err.group_syncing`.
<!-- en -->
There are two kinds of permission; don't mix them up:

- **Bot admins** (`Bot(admins=[...])`): the people who run the bot, given as `@name·tag` or user ids. They may use `admin_only=True` commands (hidden from the menu) and pass every role check. Check with `ctx.is_admin`.
- **Bot roles** (`bot.roles`): any labels such as `"mod"` or `"vip"`, saved in the bot's storage. Use `role="mod"` on a command or `ctx.has_role("mod")`.
- **Group admins**: rights inside one group, checked with `ctx.is_group_admin` (JS: `await ctx.isGroupAdmin()`).

Group admin actions (`group_ban`, `group_remove`, `set_slow_mode`, `group_settings`, `group_purge_member`, deleting other people's messages) only work when the bot is a group admin with "Read all messages"; otherwise you get `err.admin_only` or `err.group_syncing`.
<!-- all -->
```python
bot = Bot(admins=["@chu_shop·k7q2xz"])

@bot.command("addmod", "Cấp quyền mod", admin_only=True)
def addmod(ctx):
    found = bot.resolve_username(ctx.args.strip())      # "@ten·ma"
    if len(found) != 1:
        return ctx.reply("Không tìm thấy người này.")
    bot.roles.grant(found[0]["peer"], "mod")
    ctx.reply("Đã cấp quyền mod.")

@bot.command("slow", "Bật chế độ chậm 30 giây", chats="group", hidden=True)
def slow(ctx):
    if not (ctx.is_group_admin or ctx.has_role("mod")):
        return ctx.reply("⛔ Chỉ quản trị viên.")
    bot.set_slow_mode(ctx.conv, 30)
    ctx.reply("🐢 Đã bật chế độ chậm 30 giây.")
```
```js
const bot = new Bot({ admins: ["@chu_shop·k7q2xz"] });

bot.command("addmod", "Cấp quyền mod", async (ctx) => {
  const found = await bot.resolveUsername(ctx.args.trim());
  if (found.length !== 1) return ctx.reply("Không tìm thấy người này.");
  bot.roles.grant(found[0].peer, "mod");
  return ctx.reply("Đã cấp quyền mod.");
}, { adminOnly: true });

bot.command("slow", "Bật chế độ chậm 30 giây", async (ctx) => {
  if (!((await ctx.isGroupAdmin()) || ctx.hasRole("mod"))) return ctx.reply("⛔ Chỉ quản trị viên.");
  await bot.setSlowMode(ctx.conv, 30);
  return ctx.reply("🐢 Đã bật chế độ chậm 30 giây.");
}, { chats: "group", hidden: true });
```

<!-- section: storage -->
## Lưu trữ | Storage

<!-- vi -->
`bot.storage` là một bộ nhớ khoá → giá trị, tự lưu ra tệp `bot-storage.json` trong thư mục dữ liệu mỗi khi bạn gán một khoá. Giá trị phải chuyển được sang JSON (số, chữ, danh sách, đối tượng). Python và JavaScript dùng chung định dạng tệp.

Nếu sửa một giá trị lồng bên trong (thêm vào danh sách), hãy dùng `update_key` (an toàn khi nhiều tin đến cùng lúc) hoặc gọi `save()` sau khi sửa. Cần nhiều dữ liệu hơn (hàng chục nghìn bản ghi)? Dùng cơ sở dữ liệu riêng như SQLite trong cùng thư mục.
<!-- en -->
`bot.storage` is a key → value store saved to `bot-storage.json` in the data folder whenever you set a key. Values must be JSON-friendly (numbers, strings, lists, objects). Python and JavaScript share the same file format.

When you change a nested value (append to a list), use `update_key` (safe when many messages arrive at once) or call `save()` afterwards. Need more (tens of thousands of records)? Use your own database such as SQLite in the same folder.
<!-- all -->
```python
@bot.on_callback(data="buy:*")
def order(ctx):
    bot.storage.update_key("orders", lambda orders: (orders or []) + [{"who": ctx.sender, "item": ctx.data[4:]}], [])
    visits = bot.storage.update_key("visits", lambda n: n + 1, 0)
    ctx.reply(f"Đã nhận đơn #{visits}")

subscribers = bot.storage.get("subscribers", [])
```
```js
bot.onCallback({ data: "buy:*" }, (ctx) => {
  bot.storage.updateKey("orders", (orders) => [...(orders || []), { who: ctx.sender, item: ctx.data.slice(4) }], []);
  const visits = bot.storage.updateKey("visits", (n) => n + 1, 0);
  return ctx.reply(`Đã nhận đơn #${visits}`);
});

const subscribers = bot.storage.get("subscribers", []);
```

<!-- section: files -->
## Tệp và xem trước | Files and previews

<!-- vi -->
- **Nhận tệp:** `on_file(extensions=["txt", "csv"])`. `ctx.file` có `name`, `size`, `mime` và `preview` (vài dòng đầu của tệp chữ, số trang PDF…) **trước khi tải**. `ctx.download()` tải về và trả lại đường dẫn.
- Tệp nhỏ từ người dùng được tải tự động (tin riêng ≤ 25 MB, nhóm ≤ 2 MB); `ctx.download()` dùng được cho mọi cỡ. Tệp nằm trong `<thư mục dữ liệu>/downloads` (đổi bằng `downloads_dir=`).
- **Gửi tệp:** `ctx.reply_file(path)` / `bot.send_file(conv, path)`. Tệp chữ tự có xem trước. Tự đặt xem trước bằng `preview="…"` (tối đa 4 KB chữ) hoặc `thumb="anh.jpg"` (JPEG/PNG/WebP ≤ 64 KB).
- Chỉ đọc tệp bạn tin là an toàn: kiểm tra cỡ tệp, đừng chạy tệp người khác gửi.
<!-- en -->
- **Receiving:** `on_file(extensions=["txt", "csv"])`. `ctx.file` has `name`, `size`, `mime` and a `preview` (first lines of a text file, PDF page count…) **before downloading**. `ctx.download()` fetches it and returns the path.
- Small files from users download automatically (direct chats ≤ 25 MB, groups ≤ 2 MB); `ctx.download()` works for any size. Files go to `<data folder>/downloads` (change with `downloads_dir=`).
- **Sending:** `ctx.reply_file(path)` / `bot.send_file(conv, path)`. Text files get a preview automatically. Set your own with `preview="…"` (up to 4 KB of text) or `thumb="image.jpg"` (JPEG/PNG/WebP ≤ 64 KB).
- Treat received files as untrusted: check the size and never execute them.
<!-- all -->
```python
@bot.on_file(extensions=["txt", "csv"])
def count_lines(ctx):
    if ctx.file["size"] > 5_000_000:
        return ctx.reply("Tệp lớn quá (tối đa 5 MB).")
    path = ctx.download(timeout=120)
    with open(path, encoding="utf-8", errors="replace") as f:
        n = sum(1 for _ in f)
    ctx.reply(f"{ctx.file['name']}: {n} dòng", reply=True)

@bot.command("report", "Gửi báo cáo")
def report(ctx):
    ctx.reply_file("report.csv", preview="Doanh thu tuần: 12.500.000đ\nĐơn hàng: 143")
```
```js
import { readFile } from "node:fs/promises";

bot.onFile({ extensions: ["txt", "csv"] }, async (ctx) => {
  if (ctx.file.size > 5_000_000) return ctx.reply("Tệp lớn quá (tối đa 5 MB).");
  const path = await ctx.download({ timeoutMs: 120_000 });
  const lines = (await readFile(path, "utf8")).split("\n").length;
  return ctx.reply(`${ctx.file.name}: ${lines} dòng`, { reply: true });
});

bot.command("report", "Gửi báo cáo", (ctx) =>
  ctx.replyFile("report.csv", { preview: "Doanh thu tuần: 12.500.000đ\nĐơn hàng: 143" }));
```

<!-- section: checklists -->
## Danh sách việc | Checklists

<!-- vi -->
Danh sách việc là một tin nhắn có ô đánh dấu; ai trong cuộc trò chuyện cũng tích được. Tối đa 100 mục, mỗi mục 200 ký tự. Bot nhận thay đổi qua `on_checklist`: `ctx.checklist` là trạng thái đầy đủ (`items`, `done`, `total`), `ctx.changes` là những gì vừa đổi và ai đổi. Thay đổi do chính bot làm không được báo lại.

`checklist_add` thêm mục vào danh sách do bot gửi; `checklist_toggle` để bot tự tích một mục; `bot.checklist(conv, msg_id)` đọc trạng thái hiện tại.
<!-- en -->
A checklist is a message with tick boxes that anyone in the chat can tick. Up to 100 items of 200 characters. The bot hears about changes through `on_checklist`: `ctx.checklist` is the full state (`items`, `done`, `total`), `ctx.changes` says what just changed and who did it. Changes made by the bot itself are not reported back.

`checklist_add` adds items to a list the bot sent; `checklist_toggle` lets the bot tick an item; `bot.checklist(conv, msg_id)` reads the current state.
<!-- all -->
```python
@bot.command("todo", "Tạo danh sách việc: /todo Phát hành: viết ghi chú; đóng gói")
def todo(ctx):
    title, _, rest = ctx.args.partition(":")
    ctx.reply_checklist(title.strip() or "Việc cần làm", [i.strip() for i in rest.split(";") if i.strip()])

@bot.on_checklist
def progress(ctx):
    who = bot.name_of(ctx.changes[-1]["by"])
    if ctx.checklist["done"] == ctx.checklist["total"]:
        ctx.reply(f"🎉 {ctx.checklist['title']}: xong hết! (mục cuối do {who})")
```
```js
bot.command("todo", "Tạo danh sách việc: /todo Phát hành: viết ghi chú; đóng gói", (ctx) => {
  const [title, rest = ""] = ctx.args.split(":");
  return ctx.replyChecklist(title.trim() || "Việc cần làm", rest.split(";").map((s) => s.trim()).filter(Boolean));
});

bot.onChecklist(async (ctx) => {
  const who = await bot.nameOf(ctx.changes.at(-1).by);
  if (ctx.checklist.done === ctx.checklist.total)
    await ctx.reply(`🎉 ${ctx.checklist.title}: xong hết! (mục cuối do ${who})`);
});
```

<!-- section: reminders -->
## Nhắc hẹn | Reminders

<!-- vi -->
`send_reminder` gửi một lời nhắc; đến giờ, ứng dụng của mọi người trong cuộc trò chuyện báo nhắc và bot nhận `on_reminder_due`. Thời gian có thể là `datetime`, `timedelta` (từ bây giờ) hoặc mili-giây; JavaScript dùng `Date`, mili-giây hoặc `{ inMs }`. Thời gian phải ở tương lai (nếu không: lỗi `err.reminder_past`).

`ctx.reminder` có `title`, `note`, `at_ms`, `mine` (bot tạo) và `late` (bot đang tắt đúng giờ nhắc nên báo trễ). Bot phải đang chạy để nhận `on_reminder_due`; nhắc trễ quá 24 giờ bị bỏ qua. `reminder_cancel` huỷ lời nhắc do bot tạo, `reminders()` liệt kê lời nhắc sắp tới.
<!-- en -->
`send_reminder` sends a reminder; when it is due, everyone's app in the chat raises it and the bot gets `on_reminder_due`. The time can be a `datetime`, a `timedelta` (from now) or epoch milliseconds; JavaScript takes a `Date`, milliseconds or `{ inMs }`. It must be in the future (otherwise `err.reminder_past`).

`ctx.reminder` has `title`, `note`, `at_ms`, `mine` (the bot made it) and `late` (the bot was off at the due time and is catching up). The bot must be running to get `on_reminder_due`; reminders more than 24 hours late are skipped. `reminder_cancel` cancels one the bot made, `reminders()` lists upcoming ones.
<!-- all -->
```python
import datetime as dt

@bot.command("hop", "Nhắc họp sau 30 phút")
def meeting(ctx):
    ctx.reply_reminder("Họp nhóm", dt.timedelta(minutes=30), note="Phòng 2 · mang laptop")

@bot.on_reminder_due
def due(ctx):
    if ctx.reminder["mine"]:
        ctx.reply(f"⏰ Đến giờ: {ctx.reminder['title']}")
```
```js
bot.command("hop", "Nhắc họp sau 30 phút", (ctx) =>
  ctx.replyReminder("Họp nhóm", { inMs: 30 * 60_000 }, { note: "Phòng 2 · mang laptop" }));

bot.onReminderDue((ctx) => {
  if (ctx.reminder.mine) return ctx.reply(`⏰ Đến giờ: ${ctx.reminder.title}`);
});
```

<!-- section: more -->
## Các loại tin khác | More message types

<!-- vi -->
Mọi hàm gửi đều nhận `silent=True` (gửi không âm báo). Ngoài tin chữ, bot gửi được bình chọn, sticker, vị trí (cả vị trí trực tiếp), danh thiếp và tin nhắn thoại; bot cũng nhắc tên (`mentions=[peer]`), trả lời (`reply_to`), chuyển tiếp, sửa, xoá, ghim và thả cảm xúc.
<!-- en -->
Every send accepts `silent=True` (no sound or notification). Besides text, bots can send polls, stickers, locations (including live location), contact cards and voice messages; they can also mention people (`mentions=[peer]`), reply (`reply_to`), forward, edit, delete, pin and react.
<!-- all -->
```python
m = bot.send(conv, "Bảo trì lúc 22:00", silent=True)
bot.pin_message(conv, m["id"])
bot.send_poll(conv, "Ăn trưa ở đâu?", ["Phở", "Cơm tấm", "Bún chả"])
bot.send_location(conv, 21.0285, 105.8542, "Hồ Gươm")
bot.send_contact(conv, bot.me["peer"])
bot.send(conv, "Ai trực hôm nay?", mentions=[user_peer], reply_to=msg_id)
bot.react(conv, msg_id, "👍")
bot.edit_message(conv, m["id"], "Bảo trì lúc 23:00")
bot.forward_message(m["id"], other_conv)
```
```js
const m = await bot.send(conv, "Bảo trì lúc 22:00", { silent: true });
await bot.pinMessage(conv, m.id);
await bot.sendPoll(conv, "Ăn trưa ở đâu?", ["Phở", "Cơm tấm", "Bún chả"]);
await bot.sendLocation(conv, 21.0285, 105.8542, "Hồ Gươm");
await bot.sendContact(conv, bot.me.peer);
await bot.send(conv, "Ai trực hôm nay?", { mentions: [userPeer], replyTo: msgId });
await bot.react(conv, msgId, "👍");
await bot.editMessage(conv, m.id, "Bảo trì lúc 23:00");
await bot.forwardMessage(m.id, otherConv);
```

<!-- section: broadcasts -->
## Gửi theo lịch và giới hạn tốc độ | Scheduled broadcasts and rate limits

<!-- vi -->
Bot chỉ nhắn được cho người **đã nhắn bot trước** (danh sách `bot.users()`) và cho nhóm có bot. `broadcast` gửi cho tất cả người dùng; `every(giây)`, `daily("HH:MM")` và `after(giây)` chạy việc theo lịch (theo giờ máy chạy bot).

SDK tự giãn tốc độ cho mọi tin gửi đi: tối đa 15 tin/giây tổng cộng, mỗi cuộc trò chuyện 5 tin liền rồi 1 tin/giây. Gửi cho 1.000 người mất khoảng 70 giây; hàm vẫn chạy trong khi bot tiếp tục trả lời tin khác. Dùng `silent=True` cho tin không gấp và tôn trọng người muốn huỷ nhận tin.
<!-- en -->
Bots can only message people who **messaged the bot first** (`bot.users()`) and groups the bot is in. `broadcast` sends to every user; `every(seconds)`, `daily("HH:MM")` and `after(seconds)` run jobs on a schedule (in the local time of the computer running the bot).

The SDK paces every outgoing message: at most 15 messages/s overall and, per chat, 5 in a row then 1/s. Sending to 1,000 users takes about 70 seconds while the bot keeps answering other chats. Use `silent=True` for anything that is not urgent and respect people who unsubscribe.
<!-- all -->
```python
@bot.command("subscribe", "Nhận bản tin sáng")
def subscribe(ctx):
    bot.storage.update_key("subs", lambda s: sorted(set(s or []) | {ctx.sender}), [])
    ctx.reply("Đã đăng ký. Gõ /unsubscribe để huỷ.")

@bot.command("unsubscribe", "Huỷ bản tin")
def unsubscribe(ctx):
    bot.storage.update_key("subs", lambda s: [p for p in (s or []) if p != ctx.sender], [])
    ctx.reply("Đã huỷ.")

@bot.daily("07:30")
def morning():
    sent = bot.broadcast("☀️ Chào buổi sáng! Hôm nay giảm 10%.", users=bot.storage.get("subs", []), silent=True)
    bot.log.info("morning news sent to %d users", sent)
```
```js
bot.command("subscribe", "Nhận bản tin sáng", (ctx) => {
  bot.storage.updateKey("subs", (s) => [...new Set([...(s || []), ctx.sender])], []);
  return ctx.reply("Đã đăng ký. Gõ /unsubscribe để huỷ.");
});

bot.command("unsubscribe", "Huỷ bản tin", (ctx) => {
  bot.storage.updateKey("subs", (s) => (s || []).filter((p) => p !== ctx.sender), []);
  return ctx.reply("Đã huỷ.");
});

bot.daily("07:30", async () => {
  const sent = await bot.broadcast("☀️ Chào buổi sáng! Hôm nay giảm 10%.", { users: bot.storage.get("subs", []), silent: true });
  bot.log.info("morning news sent", { sent });
});
```

<!-- section: errors -->
## Xử lý lỗi | Error handling

<!-- vi -->
Mọi lỗi từ Lumora là `LumoraError` với:

- `code`: mã ổn định để so sánh trong mã nguồn, ví dụ `err.slow_mode`;
- `message`: câu dễ hiểu theo ngôn ngữ của bot (`Bot(lang="vi"|"en")`), hiện được cho người dùng;
- `detail`: nguyên nhân kỹ thuật, chỉ ghi log.

Lỗi trong hàm xử lý không làm bot dừng: SDK ghi log rồi gọi `on_error`. `NotAllowedForBots` báo lệnh bot không được dùng; `RunnerStopped` và `LumoraTimeout` báo Lumora Bot Runner đang khởi động lại (SDK tự khởi động lại, thử lại sau vài giây là được). Bảng mã lỗi thường gặp có ở [tham chiếu SDK](https://getlumora.pages.dev/developers/reference/#errors).
<!-- en -->
Every error from Lumora is a `LumoraError` with:

- `code`: a stable key to compare in code, e.g. `err.slow_mode`;
- `message`: a plain sentence in the bot's language (`Bot(lang="vi"|"en")`), fine to show to users;
- `detail`: the technical cause, for logs only.

An error in a handler never stops the bot: the SDK logs it and calls `on_error`. `NotAllowedForBots` means the command is not available to bots; `RunnerStopped` and `LumoraTimeout` mean Lumora Bot Runner is restarting (the SDK restarts it; retry after a few seconds). Common codes are listed in the [SDK reference](https://getlumora.pages.dev/developers/reference/#errors).
<!-- all -->
```python
import datetime as dt
from lumora_bot import LumoraError

@bot.command("remind", "Nhắc việc")
def remind(ctx):
    try:
        ctx.reply_reminder("Gọi khách", dt.timedelta(minutes=int(ctx.args or 10)))
    except LumoraError as e:
        if e.code == "err.reminder_past":
            return ctx.reply("Hãy chọn thời gian ở tương lai.")
        raise                                    # để on_error xử lý / let on_error handle it

@bot.on_error
def report(ctx, err):
    bot.log.error("failed in %s: %s", ctx.kind, err)
    if ctx.conv:
        ctx.reply("😵 Có lỗi xảy ra, thử lại sau nhé.")
```
```js
import { LumoraError } from "lumora-bot";

bot.command("remind", "Nhắc việc", async (ctx) => {
  try {
    await ctx.replyReminder("Gọi khách", { inMs: Number(ctx.args || 10) * 60_000 });
  } catch (e) {
    if (e instanceof LumoraError && e.code === "err.reminder_past") return ctx.reply("Hãy chọn thời gian ở tương lai.");
    throw e;                                     // để onError xử lý / let onError handle it
  }
});

bot.onError((ctx, err) => {
  bot.log.error("handler failed", { kind: ctx.kind, code: err.code, detail: err.detail });
  if (ctx.conv) return ctx.reply("😵 Có lỗi xảy ra, thử lại sau nhé.");
});
```

<!-- section: middleware -->
## Middleware và log | Middleware and logging

<!-- vi -->
Middleware chạy quanh mọi cập nhật (lệnh, tin nhắn, nút bấm…): gọi `next()` để đi tiếp, không gọi là dừng. Hợp để chặn người dùng, giới hạn tần suất mỗi người, đo thời gian xử lý.

Log của SDK ra stderr. Đặt `LUMORA_BOT_LOG_FORMAT=json` để có log dạng JSON (mỗi dòng một sự kiện, kèm `event`, `code`, `conv`…), `LUMORA_BOT_LOG_LEVEL=DEBUG` để xem chi tiết. Log riêng của Lumora Bot Runner nằm ở `<thư mục dữ liệu>/runner.log`. Đừng ghi nội dung tin nhắn của người dùng vào log.
<!-- en -->
Middleware wraps every update (commands, messages, button presses…): call `next()` to continue, don't call it to stop. Good for blocking users, per-user rate limits, timing.

The SDK logs to stderr. Set `LUMORA_BOT_LOG_FORMAT=json` for JSON lines (one event per line with `event`, `code`, `conv`…) and `LUMORA_BOT_LOG_LEVEL=DEBUG` for details. Lumora Bot Runner's own log is in `<data folder>/runner.log`. Don't log the content of users' messages.
<!-- all -->
```python
import time

@bot.middleware
def guard(ctx, next):
    if ctx.sender in bot.storage.get("blocked", []):
        return                                   # dừng / stop here
    started = time.monotonic()
    result = next()
    bot.log.debug("%s handled in %.0f ms", ctx.kind, (time.monotonic() - started) * 1000)
    return result
```
```js
bot.use(async (ctx, next) => {
  if (bot.storage.get("blocked", []).includes(ctx.sender)) return;   // dừng / stop here
  const started = Date.now();
  await next();
  bot.log.debug("handled", { kind: ctx.kind, ms: Date.now() - started });
});
```

<!-- section: async -->
## Python bất đồng bộ (tuỳ chọn) | Async Python (optional)

<!-- vi -->
SDK Python chạy đồng bộ trên một nhóm luồng nhỏ, vừa đơn giản vừa đủ nhanh cho đa số bot. Nếu bạn quen `asyncio`, hàm xử lý có thể là `async def`; trong đó dùng `await bot.aio.send(...)`, `await ctx.aio.reply(...)` hoặc `await bot.acall(...)`.
<!-- en -->
The Python SDK is synchronous on a small thread pool: simple, and fast enough for most bots. If you prefer `asyncio`, handlers may be `async def`; inside them use `await bot.aio.send(...)`, `await ctx.aio.reply(...)` or `await bot.acall(...)`.
<!-- all -->
```python
import aiohttp

@bot.command("weather", "Thời tiết")
async def weather(ctx):
    async with aiohttp.ClientSession() as s:
        async with s.get("https://wttr.in/Hanoi?format=3") as r:
            text = await r.text()
    await ctx.aio.reply(text)
```

<!-- section: http-api -->
## API HTTP cho bot | HTTP Bot API

<!-- vi -->
Không muốn dùng SDK? Lumora Bot Runner có sẵn một **API HTTP cho bot** theo kiểu Bot API quen thuộc (`/bot<TOKEN>/<phương thức>`, trả về JSON): ai từng viết bot chat qua HTTP sẽ thấy quen ngay, và các dịch vụ bên ngoài (GitHub, máy chủ, Google Sheets, cron…) có thể gửi tin vào chat, nhóm và kênh cộng đồng qua bot. Không có khái niệm "webhook" riêng: mọi thứ đều là **bot bạn tạo trong Xưởng Bot**, chạy bằng token của nó.

Bật bằng `--http-api`. Mặc định chỉ nghe trên máy này (`127.0.0.1`); token đặt trong biến môi trường `LUMORA_BOT_TOKEN`:
<!-- en -->
Don't want an SDK? Lumora Bot Runner includes an **HTTP Bot API** in the familiar Bot API style (`/bot<TOKEN>/<method>`, JSON answers): if you've written a chat bot over HTTP before you'll feel at home, and outside services (GitHub, servers, Google Sheets, cron…) can post into chats, groups and community channels through a bot. There is no separate "webhook" concept: it's all **the bot you made in Bot Studio**, run with its token.

Turn it on with `--http-api`. By default it only listens on this computer (`127.0.0.1`); the token goes in the `LUMORA_BOT_TOKEN` environment variable:
<!-- all -->
```bash
export LUMORA_BOT_TOKEN=lumora_bot_...
./lumora-bot-runner-linux-x86_64 --data ./hoamai-data --http-api 127.0.0.1:8081
```
```bat
set LUMORA_BOT_TOKEN=lumora_bot_...
lumora-bot-runner-windows-x86_64.exe --data hoamai-data --http-api 127.0.0.1:8081
```
<!-- vi -->
Gọi `http://127.0.0.1:8081/bot<TOKEN>/<phương thức>` bằng GET hoặc POST; tham số đặt trong chuỗi truy vấn, form (`application/x-www-form-urlencoded`), JSON hoặc `multipart/form-data` (để tải tệp lên). Kết quả luôn là `{"ok": true, "result": …}` hoặc `{"ok": false, "error_code": 400, "description": "Bad Request: …"}`, mã HTTP trùng `error_code` (401 sai token, 404 không có phương thức, 409 xung đột). Chỉ token của chính bot đang chạy được chấp nhận.

Có thể chạy cùng SDK: thêm `extra_args=["--http-api", "127.0.0.1:8081"]` (Python) hoặc `extraArgs: ["--http-api", "127.0.0.1:8081"]` (JavaScript) để mã bot và dịch vụ bên ngoài dùng chung một bot.

| Phương thức | Ghi chú |
|---|---|
| `getMe` | `id` là mã người dùng của bot, `username`, `lumora_handle` (`@tên·mã`) |
| `sendMessage` | `chat_id`, `text`, `parse_mode`, `reply_to_message_id` / `reply_parameters`, `disable_notification`, `reply_markup.inline_keyboard` |
| `sendPhoto`, `sendDocument` (`sendVideo`, `sendAudio`, `sendAnimation`) | tải lên bằng multipart, hoặc đường dẫn tuyệt đối trên máy chạy bot (`/srv/a.pdf`, `file:///srv/a.pdf`); `caption` thành tin chữ trả lời ngay dưới tệp |
| `editMessageText`, `deleteMessage`, `deleteMessages` | chỉ tin của chính bot (xoá: tin của người khác khi bot là quản trị viên nhóm) |
| `forwardMessage`, `pinChatMessage`, `unpinChatMessage`, `sendChatAction`, `sendPoll`, `sendLocation`, `getChat` | |
| `getUpdates` | long polling: `offset`, `limit`, `timeout` (tối đa 50 giây), `allowed_updates` |
| `setWebhook`, `deleteWebhook`, `getWebhookInfo` | `url`, `secret_token`, `allowed_updates`, `drop_pending_updates` |
| `answerCallbackQuery` | nhận và trả `true` (Lumora chưa hiện thông báo nhỏ khi bấm nút) |
| `setMyCommands`, `getMyCommands`, `deleteMyCommands` | menu lệnh của bot; `scope`: `default`, `all_private_chats`, `all_group_chats` |
| `getFile` | tải tệp người dùng gửi về máy chạy bot, rồi lấy tại `/file/bot<TOKEN>/<file_path>` |

**Cập nhật** (`Update`) gồm `message`, `edited_message` và `callback_query`. Chúng được giữ tối đa 24 giờ (1000 cập nhật) trong `bot_api.json` của thư mục dữ liệu, nên khởi động lại bot không làm mất. Nhận bằng `getUpdates` **hoặc** webhook, không dùng cả hai cùng lúc (khi đã đặt webhook, `getUpdates` trả lỗi 409).

**Webhook:** `setWebhook` cho Lumora Bot Runner gửi từng cập nhật (JSON, `POST`) tới URL của bạn, kèm tiêu đề `X-Lumora-Bot-Secret` nếu đặt `secret_token`. Trả mã 2xx là xong; lỗi hay quá 30 giây thì gửi lại sau 1, 2, 4… tối đa 60 giây, đúng thứ tự, cho tới khi được nhận. Câu trả lời của webhook cũng có thể là một lệnh gọi (`{"method": "sendMessage", "chat_id": …, "text": …}`).
<!-- en -->
Call `http://127.0.0.1:8081/bot<TOKEN>/<method>` with GET or POST; parameters go in the query string, a form (`application/x-www-form-urlencoded`), JSON or `multipart/form-data` (for uploads). Answers are always `{"ok": true, "result": …}` or `{"ok": false, "error_code": 400, "description": "Bad Request: …"}`, with the HTTP status equal to `error_code` (401 wrong token, 404 unknown method, 409 conflict). Only the running bot's own token is accepted.

It works alongside an SDK too: add `extra_args=["--http-api", "127.0.0.1:8081"]` (Python) or `extraArgs: ["--http-api", "127.0.0.1:8081"]` (JavaScript) so your bot code and outside services share one bot.

| Method | Notes |
|---|---|
| `getMe` | `id` is the bot's user id, plus `username` and `lumora_handle` (`@name·tag`) |
| `sendMessage` | `chat_id`, `text`, `parse_mode`, `reply_to_message_id` / `reply_parameters`, `disable_notification`, `reply_markup.inline_keyboard` |
| `sendPhoto`, `sendDocument` (`sendVideo`, `sendAudio`, `sendAnimation`) | multipart upload, or an absolute path on the bot's computer (`/srv/a.pdf`, `file:///srv/a.pdf`); `caption` becomes a text message replying right under the file |
| `editMessageText`, `deleteMessage`, `deleteMessages` | the bot's own messages (delete: others' too when the bot is a group admin) |
| `forwardMessage`, `pinChatMessage`, `unpinChatMessage`, `sendChatAction`, `sendPoll`, `sendLocation`, `getChat` | |
| `getUpdates` | long polling: `offset`, `limit`, `timeout` (up to 50 seconds), `allowed_updates` |
| `setWebhook`, `deleteWebhook`, `getWebhookInfo` | `url`, `secret_token`, `allowed_updates`, `drop_pending_updates` |
| `answerCallbackQuery` | accepted, returns `true` (Lumora shows no toast on button presses yet) |
| `setMyCommands`, `getMyCommands`, `deleteMyCommands` | the bot's command menu; `scope`: `default`, `all_private_chats`, `all_group_chats` |
| `getFile` | downloads a file a user sent to the bot's computer, then fetch it at `/file/bot<TOKEN>/<file_path>` |

**Updates** are `message`, `edited_message` and `callback_query`. They are kept up to 24 hours (1000 updates) in `bot_api.json` in the data folder, so a restart loses nothing. Receive them with `getUpdates` **or** a webhook, never both (once a webhook is set, `getUpdates` answers 409).

**Webhook:** `setWebhook` makes Lumora Bot Runner POST each update (JSON) to your URL, with an `X-Lumora-Bot-Secret` header when you set `secret_token`. A 2xx answer means done; errors or no answer within 30 seconds are retried after 1, 2, 4… up to 60 seconds, in order, until accepted. The webhook's answer may itself be a method call (`{"method": "sendMessage", "chat_id": …, "text": …}`).

<!-- section: http-ids -->
## Mã định danh, ghi chú và giới hạn | Ids, notes and limitations

<!-- vi -->
Mã của Lumora là **chuỗi**, không phải số:

- `chat_id` là mã cuộc trò chuyện: `d:<mã người dùng>` (chat riêng), `g:<mã nhóm>` (nhóm), `g:<mã nhóm>#<kênh>` (một kênh trong cộng đồng). Cũng nhận mã người dùng hoặc mã nhóm (32 ký tự hex) không có tiền tố. Cách lấy: từ `message.chat.id` của một cập nhật, hoặc `ctx.conv` trong SDK.
- `message_id` là mã tin nhắn Lumora (32 ký tự hex); `from.id` là mã người dùng. `chat.type` là `private`, `group` (nhóm) hoặc `supergroup` (cộng đồng và kênh của nó, kèm `lumora_channel`).
- `parse_mode`: Lumora hiển thị `**đậm**`, `_nghiêng_`, `~~gạch~~`, `` `mã` ``, khối ```` ``` ```` và `||ẩn||`. `MarkdownV2`, `Markdown` và `HTML` được đổi sang cách viết đó; gạch chân, trích dẫn và emoji tuỳ chỉnh thành chữ thường, liên kết có nhãn thành `nhãn (url)`. Không có `parse_mode` thì chữ giữ nguyên, nhưng ứng dụng Lumora vẫn hiển thị các dấu trên. Chưa hỗ trợ `entities`.
- Nút: chỉ `inline_keyboard` với `callback_data` hoặc `url` (tối đa 8×8, 64 ký tự). Bàn phím trả lời (`ReplyKeyboardMarkup`) bị bỏ qua; `editMessageText` không đổi nút.
- Tệp: không gửi được bằng URL; tệp đính kèm không có chú thích riêng (chú thích là tin trả lời ngay dưới, mã của nó ở `lumora_caption_message_id`). `getFile` tải tệp từ người gửi (qua mạng ngang hàng) nên có thể mất vài giây; ảnh thu nhỏ do Lumora tự tạo. Cập nhật có tệp kèm `photo`/`document`/`video`, `voice`, `location`, `contact`, `poll`, `sticker`; mọi loại khác (danh sách việc, nhắc hẹn…) có thêm `lumora: {kind, body}`.
- Không có: chế độ inline, thanh toán, `answerCallbackQuery` hiện thông báo, sự kiện thành viên (`chat_member`, `my_chat_member`), `channel_post`, tin của người khác bị xoá. Bot chỉ thấy tin nhóm theo chế độ riêng tư do quản trị viên nhóm chọn (xem [Nhóm](#groups)).
- Webhook chấp nhận cả `http://` (cho dịch vụ trên cùng máy hay mạng nội bộ) và gửi lần lượt từng cập nhật (`max_connections` chỉ để tương thích); không có `certificate` / `ip_address`.
- `getUpdates`: một yêu cầu mới làm yêu cầu cũ đang chờ kết thúc với lỗi 409 (mỗi lúc chỉ một nơi nhận).
<!-- en -->
Lumora ids are **strings**, not numbers:

- `chat_id` is the conversation id: `d:<user id>` (direct chat), `g:<group id>` (group), `g:<group id>#<channel>` (a channel of a community). A bare user id or group id (32 hex characters) works too. Get it from an update's `message.chat.id`, or `ctx.conv` in the SDKs.
- `message_id` is the Lumora message id (32 hex characters); `from.id` is the user id. `chat.type` is `private`, `group`, or `supergroup` (a community and its channels, with `lumora_channel`).
- `parse_mode`: Lumora draws `**bold**`, `_italic_`, `~~strike~~`, `` `code` ``, ```` ``` ```` blocks and `||spoiler||`. `MarkdownV2`, `Markdown` and `HTML` are translated to that; underline, quotes and custom emoji become plain text, labelled links become `label (url)`. Without `parse_mode` text is sent as is, but the Lumora app still draws those marks. `entities` are not supported yet.
- Buttons: only `inline_keyboard` with `callback_data` or `url` (max 8×8, 64 characters). Reply keyboards (`ReplyKeyboardMarkup`) are ignored; `editMessageText` keeps the buttons.
- Files: no sending by URL; attachments have no caption of their own (the caption is a reply right under the file, its id in `lumora_caption_message_id`). `getFile` fetches the file from the sender (peer to peer), so it may take a few seconds; thumbnails are made by Lumora. Updates carry `photo`/`document`/`video`, `voice`, `location`, `contact`, `poll`, `sticker`; every other kind (checklists, reminders…) also has `lumora: {kind, body}`.
- Not available: inline mode, payments, toasts from `answerCallbackQuery`, member updates (`chat_member`, `my_chat_member`), `channel_post`, deletions by others. In groups the bot sees what the group's privacy mode allows (see [Groups](#groups)).
- Webhooks accept `http://` too (for services on the same machine or LAN) and are sent one update at a time (`max_connections` is accepted for compatibility); there is no `certificate` / `ip_address`.
- `getUpdates`: a new request ends an older waiting one with a 409 (one consumer at a time).

<!-- section: http-examples -->
## Ví dụ HTTP: shell, GitHub, Python | HTTP examples: shell, GitHub, Python

<!-- vi -->
**Gửi tin từ một script shell** (cron, sao lưu xong, máy chủ báo lỗi…):
<!-- en -->
**Send a message from a shell script** (cron, a finished backup, a server alert…):
<!-- all -->
```bash
#!/bin/sh
# notify.sh "Sao lưu xong ✅"
API="http://127.0.0.1:8081/bot$LUMORA_BOT_TOKEN"
CHAT="g:3f9a1c0e8b7d4e2fa1b2c3d4e5f60718#alerts"
curl -sS "$API/sendMessage" \
  --data-urlencode "chat_id=$CHAT" \
  --data-urlencode "text=*$(hostname)*: $1" \
  -d parse_mode=MarkdownV2

# a file with a caption
curl -sS "$API/sendDocument" -F chat_id="$CHAT" -F document=@/var/log/backup.log -F caption="Nhật ký sao lưu"
```
<!-- vi -->
**GitHub → bot → kênh cộng đồng.** GitHub gửi webhook tới một chương trình nhỏ chạy cạnh bot; chương trình kiểm tra chữ ký `X-Hub-Signature-256` rồi gọi `sendMessage` vào kênh `#dev` của cộng đồng (thêm bot vào cộng đồng trước). Trong GitHub: *Settings → Webhooks → Add webhook*, URL là địa chỉ HTTPS trỏ tới cổng 9000 (qua proxy, xem [Vận hành](https://getlumora.pages.dev/developers/production/#http-api-security)), *Content type* `application/json`, *Secret* giống `GITHUB_SECRET`. Chỉ cần thư viện chuẩn của Python:
<!-- en -->
**GitHub → bot → community channel.** GitHub sends its webhook to a small program next to the bot; it checks the `X-Hub-Signature-256` signature and calls `sendMessage` into the community's `#dev` channel (add the bot to the community first). In GitHub: *Settings → Webhooks → Add webhook*, the URL is an HTTPS address that reaches port 9000 (through a proxy, see [Production](https://getlumora.pages.dev/developers/production/#http-api-security)), *Content type* `application/json`, *Secret* equal to `GITHUB_SECRET`. Python's standard library is enough:
<!-- all -->
```python
import hashlib, hmac, json, os, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

API = "http://127.0.0.1:8081/bot" + os.environ["LUMORA_BOT_TOKEN"]
CHAT = "g:3f9a1c0e8b7d4e2fa1b2c3d4e5f60718#dev"      # community channel
SECRET = os.environ["GITHUB_SECRET"].encode()

def send(text):
    req = urllib.request.Request(API + "/sendMessage", method="POST",
                                 data=json.dumps({"chat_id": CHAT, "text": text, "parse_mode": "HTML"}).encode(),
                                 headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=10).read()

class GitHub(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        sig = "sha256=" + hmac.new(SECRET, body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, self.headers.get("X-Hub-Signature-256", "")):
            self.send_response(401); self.end_headers(); return
        ev, p = self.headers.get("X-GitHub-Event"), json.loads(body)
        if ev == "push":
            lines = [f"• <code>{c['id'][:7]}</code> {c['message'].splitlines()[0]}" for c in p["commits"][:5]]
            send(f"<b>{p['repository']['full_name']}</b>: {len(p['commits'])} commit\n" + "\n".join(lines))
        elif ev == "pull_request" and p["action"] in ("opened", "closed"):
            pr = p["pull_request"]
            send(f"<b>PR #{pr['number']}</b> {p['action']}: {pr['title']}\n{pr['html_url']}")
        self.send_response(204); self.end_headers()

HTTPServer(("127.0.0.1", 9000), GitHub).serve_forever()
```
<!-- vi -->
Không cần máy chủ nhận? Trong GitHub Actions, một bước `curl` gọi thẳng `sendMessage` cũng được, nếu API của bot truy cập được qua HTTPS (token để trong *Secrets*).

**Bot Python bằng `requests` và `getUpdates`** (không cần SDK, chỉ HTTP thuần):
<!-- en -->
No receiver at all? A GitHub Actions step can `curl` `sendMessage` directly, as long as the bot's API is reachable over HTTPS (keep the token in *Secrets*).

**A Python bot with `requests` and `getUpdates`** (no SDK, plain HTTP):
<!-- all -->
```python
import os, requests

API = "http://127.0.0.1:8081/bot" + os.environ["LUMORA_BOT_TOKEN"]

def call(method, **params):
    r = requests.post(f"{API}/{method}", json=params, timeout=70).json()
    if not r["ok"]:
        raise RuntimeError(r["description"])
    return r["result"]

call("setMyCommands", commands=[{"command": "start", "description": "Bắt đầu"},
                                {"command": "time", "description": "Giờ máy chủ"}])
offset = 0
while True:
    for u in call("getUpdates", offset=offset, timeout=50):
        offset = u["update_id"] + 1
        if "callback_query" in u:
            q = u["callback_query"]
            call("answerCallbackQuery", callback_query_id=q["id"])
            call("sendMessage", chat_id=q["message"]["chat"]["id"], text=f"Bạn chọn: {q['data']}")
            continue
        m = u.get("message")
        if not m or "text" not in m:
            continue
        if m["text"].startswith("/start"):
            call("sendMessage", chat_id=m["chat"]["id"], text=f"Chào **{m['from']['first_name']}**!",
                 reply_markup={"inline_keyboard": [[{"text": "👍", "callback_data": "like"},
                                                    {"text": "👎", "callback_data": "dislike"}]]})
        elif m["text"].startswith("/time"):
            import datetime
            call("sendMessage", chat_id=m["chat"]["id"], text=str(datetime.datetime.now()),
                 reply_to_message_id=m["message_id"])
```
