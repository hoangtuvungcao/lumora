# Vận hành | Production

<!-- Bilingual source for /developers/production/ (format: see quickstart.md). -->

<!-- section: limits -->
## Giới hạn | Limits

<!-- vi -->
| Mục | Giới hạn |
|---|---|
| Tin nhắn chữ | 64 KB (UTF-8), dài hơn thì chia nhỏ |
| Nút bấm | 8 hàng × 8 nút; chữ và dữ liệu mỗi nút ≤ 64 ký tự |
| Tốc độ gửi (SDK tự giãn) | 15 tin/giây tổng; mỗi cuộc trò chuyện 5 tin liền rồi 1 tin/giây |
| Ứng dụng người nhận | nhận tối đa 20 tin/giây từ một người gửi; SDK luôn gửi chậm hơn mức này |
| Xem trước tệp | chữ ≤ 4 KB; ảnh JPEG/PNG/WebP ≤ 64 KB |
| Tự tải tệp nhận được | tin riêng ≤ 25 MB, nhóm ≤ 2 MB (lớn hơn: `download_file`) |
| Tin nhắn thoại | ≤ 32 MB |
| Danh sách việc | 1–100 mục, mỗi mục và tiêu đề ≤ 200 ký tự |
| Nhắc hẹn | tiêu đề ≤ 200, ghi chú ≤ 1.000 ký tự; trong vòng 10 năm; trễ quá 24 giờ thì bỏ qua |
| Bình chọn | 2–10 lựa chọn (≤ 100 ký tự), câu hỏi ≤ 300 ký tự |
| Tin hẹn giờ (`schedule_message`) | ≤ 500 tin đang chờ |
| Vị trí trực tiếp | ≤ 8 giờ |
| Giới thiệu bot (`about`) | ≤ 300 ký tự |
| Số bot mỗi tài khoản | 20 |
| @tên của bot | 3–24 ký tự `a–z 0–9 _`, kết thúc bằng `bot` |
| Tài nguyên | ≈ 30 MB RAM mỗi bot, gần 0 % CPU khi rảnh |

Không có hạn mức hay phí chung: mỗi bot chạy trên máy của bạn.
<!-- en -->
| What | Limit |
|---|---|
| Text message | 64 KB (UTF-8); split longer text |
| Buttons | 8 rows × 8 buttons; text and data ≤ 64 characters each |
| Send pace (paced by the SDK) | 15 messages/s overall; per chat 5 in a row, then 1/s |
| Receiving apps | accept up to 20 messages/s from one sender; the SDK always stays below that |
| File previews | text ≤ 4 KB; JPEG/PNG/WebP picture ≤ 64 KB |
| Automatic download of received files | direct chats ≤ 25 MB, groups ≤ 2 MB (bigger: `download_file`) |
| Voice messages | ≤ 32 MB |
| Checklists | 1–100 items; items and title ≤ 200 characters |
| Reminders | title ≤ 200, note ≤ 1,000 characters; within 10 years; skipped when more than 24 h late |
| Polls | 2–10 options (≤ 100 characters), question ≤ 300 characters |
| Scheduled messages (`schedule_message`) | ≤ 500 pending |
| Live location | ≤ 8 hours |
| Bot description (`about`) | ≤ 300 characters |
| Bots per account | 20 |
| Bot @username | 3–24 characters `a–z 0–9 _`, ending in `bot` |
| Resources | ≈ 30 MB RAM per bot, close to 0 % CPU when idle |

There is no central quota and no fee: each bot runs on your own computer.

<!-- section: security -->
## Bảo mật | Security

<!-- vi -->
- **Token là chìa khóa của bot.** Ai có token là điều khiển được bot. Đặt token trong biến môi trường `LUMORA_BOT_TOKEN` hoặc tệp môi trường chỉ chủ máy đọc được (`chmod 600`); đừng đưa vào mã nguồn, ảnh chụp màn hình hay kho mã công khai. SDK chuyển token cho Lumora Bot Runner qua biến môi trường, không qua dòng lệnh.
- **Lỡ lộ token:** trong Lumora, gửi `/mybots` cho BotFather, chọn bot, bấm **Thu hồi mã**. Token cũ ngừng hoạt động ngay; bot nhận khóa mới nên hãy chạy token mới với **thư mục dữ liệu mới**. @tên của bot giữ nguyên.
- **Thư mục dữ liệu** chứa danh tính, tin nhắn và `bot-storage.json` của bot. Chỉ cho tài khoản chạy bot đọc (`chmod 700`), sao lưu định kỳ, mỗi bot một thư mục và chỉ một tiến trình dùng nó.
- **Quản trị viên của bot:** ghi đầy đủ `@tên·mã` (phần mã gắn với tài khoản nên không giả mạo được) hoặc mã người dùng.
- **Dữ liệu người dùng:** tin nhắn được mã hóa đầu cuối giữa người dùng và bot, nhưng bot (và bạn) đọc được những gì gửi cho bot. Chỉ lưu thứ thật sự cần, không ghi nội dung tin nhắn vào log, cho người dùng cách hủy nhận tin.
- **Đầu vào không tin cậy:** kiểm tra `ctx.args`, cỡ tệp và loại tệp; không bao giờ chạy tệp người khác gửi.
- **Lệnh dành cho con người:** điều khiển máy từ xa, cụm từ khôi phục, sao lưu, mật khẩu và cuộc gọi bị SDK chặn (`NotAllowedForBots`).
- Chạy bot bằng một tài khoản hệ thống riêng, không dùng quyền quản trị (root/Administrator).
<!-- en -->
- **The token is your bot's key.** Whoever has it controls the bot. Keep it in the `LUMORA_BOT_TOKEN` environment variable or in an environment file only the owner can read (`chmod 600`); never put it in source code, screenshots or public repositories. The SDK hands the token to Lumora Bot Runner through the environment, never on the command line.
- **If the token leaks:** in Lumora, send `/mybots` to BotFather, pick the bot and tap **Revoke token**. The old token stops working at once; the bot gets a new key, so run the new token with a **new data folder**. The bot's @username stays the same.
- **The data folder** holds the bot's identity, messages and `bot-storage.json`. Make it readable only by the account running the bot (`chmod 700`), back it up, and use one folder per bot with only one process at a time.
- **Bot admins:** use the full `@name·tag` (the tag is bound to the account, so it can't be faked) or the user id.
- **User data:** messages are end-to-end encrypted between users and the bot, but the bot (and you) can read what is sent to it. Keep only what you need, don't log message content, and let people unsubscribe.
- **Untrusted input:** check `ctx.args`, file sizes and file types; never execute files people send.
- **Things only people may do:** remote control, the recovery phrase, backups, passwords and calls are blocked by the SDK (`NotAllowedForBots`).
- Run the bot under its own system account, never as root/Administrator.

<!-- section: deploy -->
## Chạy 24/7 | Running 24/7

<!-- vi -->
Bot chạy khi máy chạy bot đang bật: một máy ở nhà hay ở cửa hàng, hoặc một máy chủ ảo nhỏ nhất đều đủ. SDK tự khởi động lại Lumora Bot Runner nếu nó dừng bất ngờ, và tắt êm khi nhận SIGTERM hoặc Ctrl+C (chờ các hàm xử lý đang chạy xong, lưu dữ liệu rồi mới thoát).

### Linux: systemd

Đặt bot ở `/opt/lumora-bots/hoamai/`, Bot Runner ở `/opt/lumora-bots/bin/`, token trong `/etc/lumora-bots/hoamai.env` (`LUMORA_BOT_TOKEN=lumora_bot_...`, `chmod 600`):
<!-- en -->
A bot runs while its computer is on: an always-on computer at home or in a shop, or the smallest virtual server, is enough. The SDK restarts Lumora Bot Runner if it stops unexpectedly and shuts down cleanly on SIGTERM or Ctrl+C (running handlers finish, data is saved, then it exits).

### Linux: systemd

Put the bot in `/opt/lumora-bots/hoamai/`, Bot Runner in `/opt/lumora-bots/bin/`, and the token in `/etc/lumora-bots/hoamai.env` (`LUMORA_BOT_TOKEN=lumora_bot_...`, `chmod 600`):
<!-- all -->
```ini
# /etc/systemd/system/lumora-bot-hoamai.service
[Unit]
Description=Lumora bot @hoamai_bot
After=network-online.target
Wants=network-online.target

[Service]
User=lumora-bot
WorkingDirectory=/opt/lumora-bots/hoamai
EnvironmentFile=/etc/lumora-bots/hoamai.env
Environment=LUMORAD=/opt/lumora-bots/bin/lumora-bot-runner-linux-x86_64
Environment=LUMORA_BOT_LOG_FORMAT=json
ExecStart=/usr/bin/python3 bot.py
Restart=on-failure
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=30
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/lumora-bots/hoamai
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```
```bash
sudo useradd --system --home /opt/lumora-bots --shell /usr/sbin/nologin lumora-bot
sudo chown -R lumora-bot: /opt/lumora-bots/hoamai && sudo chmod 700 /opt/lumora-bots/hoamai
sudo systemctl daemon-reload && sudo systemctl enable --now lumora-bot-hoamai
journalctl -u lumora-bot-hoamai -f            # xem log / follow the logs
```
<!-- vi -->
Với bot JavaScript, đổi `ExecStart` thành `/usr/bin/node bot.mjs`.

### Docker

Thư mục dữ liệu phải nằm trong một volume để không mất danh tính và dữ liệu khi tạo lại container:
<!-- en -->
For a JavaScript bot, set `ExecStart=/usr/bin/node bot.mjs`.

### Docker

Keep the data folder in a volume so the identity and data survive re-creating the container:
<!-- all -->
```dockerfile
FROM python:3.12-slim
WORKDIR /bot
COPY lumora-bot-runner-linux-x86_64 /usr/local/bin/lumorad
RUN chmod +x /usr/local/bin/lumorad \
 && pip install --no-cache-dir https://getlumora.pages.dev/developers/packages/lumora_bot-1.1.0-py3-none-any.whl \
 && useradd --system --create-home bot && mkdir -p /bot/data && chown bot /bot/data
COPY bot.py .
USER bot
ENV LUMORAD=/usr/local/bin/lumorad LUMORA_BOT_LOG_FORMAT=json
VOLUME /bot/data
STOPSIGNAL SIGTERM
CMD ["python", "bot.py"]
```
```bash
# bot.py dùng / uses: Bot(data_dir="data")
docker build -t hoamai-bot .
docker run -d --name hoamai --restart unless-stopped \
  -e LUMORA_BOT_TOKEN -v hoamai-data:/bot/data hoamai-bot
docker logs -f hoamai
```
<!-- vi -->
Bot JavaScript: dùng `FROM node:20-slim`, cài bằng `npm install https://getlumora.pages.dev/developers/packages/lumora-bot-1.1.0.tgz` và `CMD ["node", "bot.mjs"]`. Muốn bot tìm thấy người dùng trong cùng mạng nội bộ, chạy container với `--network host` (Linux).

### Windows

Cách đơn giản: **Task Scheduler** → Create Task → *Run whether user is logged on or not*, trigger *At startup*, action `python.exe` với đối số `bot.py` và thư mục bắt đầu là thư mục của bot. Đặt `LUMORA_BOT_TOKEN` và `LUMORAD` trong *System Properties → Environment Variables* của tài khoản chạy bot.

Muốn chạy như một dịch vụ Windows, dùng một trình bao dịch vụ như NSSM:
<!-- en -->
JavaScript bots: use `FROM node:20-slim`, install with `npm install https://getlumora.pages.dev/developers/packages/lumora-bot-1.1.0.tgz` and `CMD ["node", "bot.mjs"]`. For the bot to find users on the same local network, run the container with `--network host` (Linux).

### Windows

The simple way: **Task Scheduler** → Create Task → *Run whether user is logged on or not*, trigger *At startup*, action `python.exe` with argument `bot.py` and "Start in" set to the bot's folder. Set `LUMORA_BOT_TOKEN` and `LUMORAD` under *System Properties → Environment Variables* for the account that runs the bot.

To run it as a Windows service, use a service wrapper such as NSSM:
<!-- all -->
```bat
nssm install HoaMaiBot "C:\Python312\python.exe" "C:\bots\hoamai\bot.py"
nssm set HoaMaiBot AppDirectory C:\bots\hoamai
nssm set HoaMaiBot AppEnvironmentExtra LUMORA_BOT_TOKEN=lumora_bot_... LUMORAD=C:\bots\lumora-bot-runner-windows-x86_64.exe
nssm set HoaMaiBot AppStopMethodConsole 15000
nssm start HoaMaiBot
```
<!-- vi -->
NSSM gửi Ctrl+C khi dừng dịch vụ nên bot vẫn tắt êm. Trên macOS, dùng `launchd` (một tệp `.plist` trong `~/Library/LaunchAgents` với `KeepAlive`).

### Biến môi trường
<!-- en -->
NSSM sends Ctrl+C when stopping the service, so the bot still shuts down cleanly. On macOS, use `launchd` (a `.plist` in `~/Library/LaunchAgents` with `KeepAlive`).

### Environment variables
<!-- all -->
| | |
|---|---|
| `LUMORA_BOT_TOKEN` | Token từ BotFather / BotFather token |
| `LUMORAD` | Đường dẫn Lumora Bot Runner / Path to Lumora Bot Runner |
| `LUMORA_BOT_LOG_FORMAT` | `json` = log dạng JSON / JSON logs |
| `LUMORA_BOT_LOG_LEVEL` | `DEBUG`, `INFO`, `WARNING`, `ERROR` |

<!-- section: operations -->
## Cập nhật, sao lưu, theo dõi | Updates, backups, monitoring

<!-- vi -->
- **Cập nhật SDK:** cài lại gói mới (`pip install -U …whl`, `npm install …tgz`) rồi khởi động lại bot. Mã bot viết cho bản 1.0 vẫn chạy với 1.1. Xem [nhật ký thay đổi](https://getlumora.pages.dev/developers/reference/#changelog).
- **Cập nhật Lumora Bot Runner:** dừng bot, thay tệp, chạy lại. Dữ liệu được giữ nguyên.
- **Sao lưu:** dừng bot (hoặc chấp nhận bản sao "đang chạy") rồi sao chép cả thư mục dữ liệu. Bot tạo bằng token có thể chạy lại từ token, nhưng lịch sử và `bot-storage.json` chỉ có trong thư mục.
- **Theo dõi:** đặt `LUMORA_BOT_LOG_FORMAT=json` và gom log bằng công cụ bạn quen dùng. Các sự kiện đáng cảnh báo: `runner_exit`, `restart_failed`, `restart_giveup`, `handler_error`. Log của Lumora Bot Runner ở `runner.log` trong thư mục dữ liệu (tự xoay vòng ở 10 MB).
<!-- en -->
- **Updating the SDK:** install the new package (`pip install -U …whl`, `npm install …tgz`) and restart the bot. Bots written for 1.0 run unchanged on 1.1. See the [changelog](https://getlumora.pages.dev/developers/reference/#changelog).
- **Updating Lumora Bot Runner:** stop the bot, replace the file, start again. Data is kept.
- **Backups:** stop the bot (or accept a "live" copy) and copy the whole data folder. A token bot can be started again from its token, but its history and `bot-storage.json` only live in the folder.
- **Monitoring:** set `LUMORA_BOT_LOG_FORMAT=json` and collect the logs with the tool you already use. Events worth an alert: `runner_exit`, `restart_failed`, `restart_giveup`, `handler_error`. Lumora Bot Runner's own log is `runner.log` in the data folder (rotated at 10 MB).

<!-- section: troubleshooting -->
## Khắc phục sự cố | Troubleshooting

<!-- vi -->
| Hiện tượng | Cách xử lý |
|---|---|
| `Lumora Bot Runner not found` (`sdk.runner_missing`) | Đặt `LUMORAD` trỏ đúng tệp Bot Runner; trên Linux/macOS chạy `chmod +x` cho tệp. macOS chặn tệp tải về: cho phép trong Cài đặt hệ thống → Quyền riêng tư & Bảo mật. |
| `Lumora Bot Runner could not start` (`sdk.runner_failed`) | Xem `runner.log` trong thư mục dữ liệu. Thường do một tiến trình khác đang dùng cùng thư mục, hoặc ổ đĩa đầy. |
| `err.bad_bot_token` | Token chép thiếu hoặc đã bị thu hồi. Lấy lại trong BotFather (`/mybots` → Mã bí mật). |
| `err.bot_token_mismatch` | Thư mục dữ liệu thuộc về bot khác (hoặc token cũ trước khi thu hồi). Dùng thư mục mới cho token này. |
| Không ai tìm thấy bot | Chờ một phút sau lần chạy đầu tiên; gửi cho người dùng mã 9 số hoặc `@tên·mã` đầy đủ. Đừng dùng `public_directory=False` khi chạy thật. |
| `err.bot_cannot_start` | Bot chỉ nhắn được cho người đã nhắn bot trước. Hãy để người dùng gửi `/start`. |
| Bot im lặng trong nhóm | Ở chế độ riêng tư bot chỉ thấy lệnh `/…`, tin nhắc @bot và tin trả lời bot. Thành viên vào nhóm sau khi bot được thêm cần chế độ "đọc mọi tin". Xem [Nhóm](https://getlumora.pages.dev/developers/guides/#groups). |
| `err.group_syncing` khi sửa, xóa, ghim hay quản trị trong nhóm | Bot đang ở chế độ riêng tư: các việc này cần quyền "đọc mọi tin" (và quyền quản trị viên cho việc quản trị). |
| `err.slow_mode` | Nhóm bật chế độ chậm; cho bot làm quản trị viên hoặc gửi ít tin hơn. |
| Gửi hàng loạt chậm | Đúng như thiết kế: 15 tin/giây để tin của bot không bị chặn như tin rác. 1.000 người ≈ 70 giây. |
| Nhắc hẹn không báo | Bot phải đang chạy đúng giờ nhắc (nếu tắt, bot nhận nhắc khi bật lại với `late=True`, trong vòng 24 giờ). Giờ dùng múi giờ của máy chạy bot. |
| Tệp không tải về | Tăng `timeout` của `ctx.download()`; kiểm tra dung lượng đĩa (`err.disk_full`) và quyền ghi thư mục `downloads`. |
| Bot trả lời hai lần | Có hai tiến trình chạy cùng bot. Mỗi bot chỉ chạy một tiến trình. |
<!-- en -->
| Symptom | What to do |
|---|---|
| `Lumora Bot Runner not found` (`sdk.runner_missing`) | Point `LUMORAD` at the Bot Runner file; on Linux/macOS run `chmod +x` on it. If macOS blocks the downloaded file, allow it in System Settings → Privacy & Security. |
| `Lumora Bot Runner could not start` (`sdk.runner_failed`) | Read `runner.log` in the data folder. Usually another process is using the same folder, or the disk is full. |
| `err.bad_bot_token` | The token was copied incompletely or has been revoked. Get it again in BotFather (`/mybots` → Secret token). |
| `err.bot_token_mismatch` | The data folder belongs to another bot (or to the old token before a revoke). Use a new folder for this token. |
| Nobody can find the bot | Wait a minute after the first start; give people the 9-digit ID or the full `@name·tag`. Don't use `public_directory=False` in production. |
| `err.bot_cannot_start` | Bots can only message people who messaged them first. Ask users to send `/start`. |
| The bot is silent in a group | In privacy mode it only sees `/commands`, messages that @mention it and replies to it. Members who joined after the bot was added need "Read all messages". See [Groups](https://getlumora.pages.dev/developers/guides/#groups). |
| `err.group_syncing` when editing, deleting, pinning or moderating in a group | The bot is in privacy mode: these need "Read all messages" (and admin rights for moderation). |
| `err.slow_mode` | The group has slow mode on; make the bot an admin or send fewer messages. |
| Broadcasts are slow | By design: 15 messages/s so the bot is never treated as spam. 1,000 users ≈ 70 seconds. |
| Reminders don't fire | The bot must be running at the due time (if it was off, it gets the reminder on start with `late=True`, within 24 hours). Times use the bot computer's time zone. |
| Files don't download | Raise the `timeout` of `ctx.download()`; check free disk space (`err.disk_full`) and that the `downloads` folder is writable. |
| The bot answers twice | Two processes are running the same bot. Run exactly one per bot. |

<!-- section: faq -->
## Câu hỏi thường gặp | FAQ

<!-- vi -->
**Có cần thuê máy chủ không?** Không bắt buộc. Bot chạy trên bất kỳ máy nào có Bot Runner; chỉ cần máy luôn bật nếu muốn bot trả lời cả ngày.

**Tắt máy thì sao?** Bot tạm ngừng. Tin nhắn gửi trong lúc đó sẽ đến khi bot chạy lại.

**Một máy chạy được bao nhiêu bot?** Mỗi bot khoảng 30 MB RAM; mỗi bot một thư mục dữ liệu và một tiến trình.

**Có thu phí hay giới hạn lượt gọi không?** Không. Giới hạn duy nhất là tốc độ gửi để tránh làm phiền người nhận.

**Đổi tên, mô tả, menu lệnh ở đâu?** Trong mã bot: `about=`, `bot.set_profile(name=…, bio=…, avatar=…)` và các lệnh bạn khai báo. Menu lệnh được cập nhật mỗi lần bot khởi động.

**Bot có tự vào nhóm được không?** Không. Chỉ quản trị viên nhóm thêm được bot. Bot tìm được nhóm công khai bằng `search_groups` nhưng không tự tham gia.

**Python hay JavaScript?** Hai SDK có cùng tính năng và cùng định dạng dữ liệu; chọn ngôn ngữ bạn quen. JavaScript có sẵn kiểu TypeScript.

**Gọi lệnh chưa có trong SDK?** Dùng `bot.call("tên_lệnh", …)` với mọi lệnh trong [tài liệu JSON API](https://getlumora.pages.dev/developers/api/).
<!-- en -->
**Do I need a server?** No. The bot runs on any computer with Bot Runner; you only need an always-on one if the bot should answer all day.

**What if the computer is off?** The bot pauses. Messages sent meanwhile arrive when the bot runs again.

**How many bots per computer?** About 30 MB RAM each; one data folder and one process per bot.

**Are there fees or call limits?** No. The only limit is the send pace that keeps the bot from flooding people.

**Where do I change the name, description or command menu?** In your code: `about=`, `bot.set_profile(name=…, bio=…, avatar=…)` and the commands you declare. The menu is updated every time the bot starts.

**Can a bot join groups by itself?** No. Only a group admin can add a bot. A bot can find public groups with `search_groups` but never joins on its own.

**Python or JavaScript?** Both SDKs have the same features and the same storage format; pick the one you know. JavaScript ships TypeScript types.

**A command the SDK doesn't wrap?** Use `bot.call("command_name", …)` with anything in the [JSON API reference](https://getlumora.pages.dev/developers/api/).
