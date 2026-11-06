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
| Sửa, xóa, ghim, thả cảm xúc trong nhóm | không | có |
| Biết thành viên mới (`on_new_member`) | không | có |
| Việc của quản trị viên (cấm, chế độ chậm, xóa tin) | không | có, khi bot là quản trị viên |

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
- **Vai trò của bot** (`bot.roles`): nhãn tùy ý như `"mod"`, `"vip"`, lưu trong bộ nhớ của bot. Dùng `role="mod"` trên lệnh hoặc `ctx.has_role("mod")`.
- **Quản trị viên nhóm**: quyền trong một nhóm cụ thể, kiểm tra bằng `ctx.is_group_admin` (JS: `await ctx.isGroupAdmin()`).

Việc quản trị nhóm (`group_ban`, `group_remove`, `set_slow_mode`, `group_settings`, `group_purge_member`, xóa tin của người khác) chỉ làm được khi bot là quản trị viên nhóm và có quyền đọc mọi tin; nếu không sẽ có lỗi `err.admin_only` hoặc `err.group_syncing`.
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
`bot.storage` là một bộ nhớ khóa → giá trị, tự lưu ra tệp `bot-storage.json` trong thư mục dữ liệu mỗi khi bạn gán một khóa. Giá trị phải chuyển được sang JSON (số, chữ, danh sách, đối tượng). Python và JavaScript dùng chung định dạng tệp.

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

`ctx.reminder` có `title`, `note`, `at_ms`, `mine` (bot tạo) và `late` (bot đang tắt đúng giờ nhắc nên báo trễ). Bot phải đang chạy để nhận `on_reminder_due`; nhắc trễ quá 24 giờ bị bỏ qua. `reminder_cancel` hủy lời nhắc do bot tạo, `reminders()` liệt kê lời nhắc sắp tới.
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
Mọi hàm gửi đều nhận `silent=True` (gửi không âm báo). Ngoài tin chữ, bot gửi được bình chọn, sticker, vị trí (cả vị trí trực tiếp), danh thiếp và tin nhắn thoại; bot cũng nhắc tên (`mentions=[peer]`), trả lời (`reply_to`), chuyển tiếp, sửa, xóa, ghim và thả cảm xúc.
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

SDK tự giãn tốc độ cho mọi tin gửi đi: tối đa 15 tin/giây tổng cộng, mỗi cuộc trò chuyện 5 tin liền rồi 1 tin/giây. Gửi cho 1.000 người mất khoảng 70 giây; hàm vẫn chạy trong khi bot tiếp tục trả lời tin khác. Dùng `silent=True` cho tin không gấp và tôn trọng người muốn hủy nhận tin.
<!-- en -->
Bots can only message people who **messaged the bot first** (`bot.users()`) and groups the bot is in. `broadcast` sends to every user; `every(seconds)`, `daily("HH:MM")` and `after(seconds)` run jobs on a schedule (in the local time of the computer running the bot).

The SDK paces every outgoing message: at most 15 messages/s overall and, per chat, 5 in a row then 1/s. Sending to 1,000 users takes about 70 seconds while the bot keeps answering other chats. Use `silent=True` for anything that is not urgent and respect people who unsubscribe.
<!-- all -->
```python
@bot.command("subscribe", "Nhận bản tin sáng")
def subscribe(ctx):
    bot.storage.update_key("subs", lambda s: sorted(set(s or []) | {ctx.sender}), [])
    ctx.reply("Đã đăng ký. Gõ /unsubscribe để hủy.")

@bot.command("unsubscribe", "Hủy bản tin")
def unsubscribe(ctx):
    bot.storage.update_key("subs", lambda s: [p for p in (s or []) if p != ctx.sender], [])
    ctx.reply("Đã hủy.")

@bot.daily("07:30")
def morning():
    sent = bot.broadcast("☀️ Chào buổi sáng! Hôm nay giảm 10%.", users=bot.storage.get("subs", []), silent=True)
    bot.log.info("morning news sent to %d users", sent)
```
```js
bot.command("subscribe", "Nhận bản tin sáng", (ctx) => {
  bot.storage.updateKey("subs", (s) => [...new Set([...(s || []), ctx.sender])], []);
  return ctx.reply("Đã đăng ký. Gõ /unsubscribe để hủy.");
});

bot.command("unsubscribe", "Hủy bản tin", (ctx) => {
  bot.storage.updateKey("subs", (s) => (s || []).filter((p) => p !== ctx.sender), []);
  return ctx.reply("Đã hủy.");
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
## Python bất đồng bộ (tùy chọn) | Async Python (optional)

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
