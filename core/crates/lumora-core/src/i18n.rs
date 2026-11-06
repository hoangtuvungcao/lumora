//! User-facing strings produced by the core (errors, system messages) in English and
//! Vietnamese. The UI language is pushed by the app (`set_lang`), default English.
//! System messages are also stored as `{code, args}` so each viewer's UI can render
//! them in its own language.

use std::sync::atomic::{AtomicU8, Ordering};

static LANG: AtomicU8 = AtomicU8::new(0); // 0 = en, 1 = vi

pub fn set_lang(code: &str) {
    LANG.store(if code.to_lowercase().starts_with("vi") { 1 } else { 0 }, Ordering::Relaxed);
}

pub fn lang() -> &'static str {
    if LANG.load(Ordering::Relaxed) == 1 {
        "vi"
    } else {
        "en"
    }
}

const TABLE: &[(&str, &str, &str)] = &[
    // key, en, vi — plain words only: no network/crypto/system terms in user-visible text.
    // ---- general
    ("err.generic", "Something went wrong. Please try again.", "Có lỗi xảy ra. Vui lòng thử lại."),
    ("err.start_failed", "Lumora couldn't start. Please restart the app.", "Lumora chưa khởi động được. Hãy mở lại ứng dụng."),
    ("err.already_running", "Lumora is already open on this device. Close the other window first.", "Lumora đang mở ở một cửa sổ khác trên máy này. Hãy đóng cửa sổ đó trước."),
    ("err.net_start", "Lumora couldn't go online. Check your internet connection and open the app again.", "Lumora chưa kết nối được. Hãy kiểm tra Internet rồi mở lại ứng dụng."),
    ("err.data_unreadable", "Lumora can't open its data folder. Check that the folder still exists and you have access to it.", "Lumora không mở được thư mục dữ liệu. Hãy kiểm tra thư mục còn tồn tại và bạn có quyền truy cập."),
    ("err.data_corrupt", "Your saved data looks damaged and can't be opened. You can restore it from a backup or your recovery phrase.", "Dữ liệu đã lưu có vẻ bị hỏng nên không mở được. Bạn có thể khôi phục từ bản sao lưu hoặc cụm từ khôi phục."),
    ("err.device_key_missing", "This device can no longer unlock your data. Restore your account from a backup or your recovery phrase.", "Máy này không còn mở khóa được dữ liệu của bạn. Hãy khôi phục tài khoản từ bản sao lưu hoặc cụm từ khôi phục."),
    ("err.keychain_unavailable", "The system keychain is not ready yet, so your data cannot be unlocked right now. Wait a moment, then open Lumora again.", "Kho khóa của hệ thống chưa sẵn sàng nên chưa mở khóa được dữ liệu. Hãy đợi một lát rồi mở lại Lumora."),
    ("err.passphrase_required", "Enter your password to unlock Lumora.", "Hãy nhập mật khẩu để mở khóa Lumora."),
    ("err.wrong_passphrase", "Wrong password. Please try again.", "Sai mật khẩu. Vui lòng thử lại."),
    ("err.account_exists", "This device already has an account. Remove it before restoring another one.", "Máy này đã có tài khoản. Hãy xóa tài khoản đó trước khi khôi phục tài khoản khác."),
    ("err.bad_recovery_phrase", "That recovery phrase isn't right. Check each word and try again.", "Cụm từ khôi phục chưa đúng. Hãy kiểm tra từng từ rồi thử lại."),
    ("err.phrase_checksum", "One of the words is wrong. Please check each word.", "Có một từ bị ghi sai. Hãy kiểm tra lại từng từ."),
    ("err.phrase_word", "Word {n} isn't on the recovery word list. Check its spelling.", "Từ số {n} không có trong danh sách. Hãy kiểm tra chính tả."),
    ("err.phrase_count", "The recovery phrase has {t} words — you entered {n}.", "Cụm từ khôi phục có {t} từ — bạn mới nhập {n} từ."),
    ("err.backup_pw_short", "The backup password needs at least 8 characters.", "Mật khẩu sao lưu cần ít nhất 8 ký tự."),
    ("err.not_backup", "This file isn't a Lumora backup.", "File này không phải bản sao lưu của Lumora."),
    ("err.wrong_backup_password", "Wrong backup password.", "Sai mật khẩu sao lưu."),
    ("err.backup_corrupt", "This backup file is damaged and can't be restored.", "File sao lưu bị hỏng nên không khôi phục được."),
    // ---- people & IDs
    ("err.id_not_found", "No one with ID {sid} was found. Check the number, or ask them to open Lumora.", "Không tìm thấy ai có ID {sid}. Hãy kiểm tra lại số, hoặc nhờ người đó mở Lumora."),
    ("err.id_ambiguous", "ID {sid} matches more than one person. Ask them for their full ID or @username.", "ID {sid} trùng với nhiều người. Hãy hỏi họ ID đầy đủ hoặc @tên người dùng."),
    ("err.invalid_id", "That ID doesn't look right. Check it and try again.", "ID này chưa đúng. Hãy kiểm tra rồi thử lại."),
    ("err.username_not_found", "No one called {name} was found.", "Không tìm thấy ai tên {name}."),
    ("err.username_ambiguous", "Several people are called {name}. Use the full name with its tag, like @name·abc123.", "Có nhiều người tên {name}. Hãy dùng tên đầy đủ kèm mã, ví dụ @ten·abc123."),
    ("err.username_invalid", "Usernames use 3–24 characters: lowercase letters, numbers and _ (not at the start).", "Tên người dùng gồm 3–24 ký tự: chữ thường, số và dấu _ (không đứng đầu)."),
    ("err.lookup_off", "Finding people by ID is turned off in Settings.", "Tính năng tìm người theo ID đang tắt trong Cài đặt."),
    ("err.own_id", "This is your own ID.", "Đây là ID của chính bạn."),
    ("err.blocked", "You've blocked this person. Unblock them to send messages.", "Bạn đã chặn người này. Hãy bỏ chặn để nhắn tin."),
    ("err.peer_offline", "Can't reach this person right now — they may be offline. Please try again later.", "Chưa liên lạc được với người này — có thể họ đang ngoại tuyến. Hãy thử lại sau."),
    ("err.connection_lost", "The connection was interrupted. Please try again.", "Kết nối bị gián đoạn. Vui lòng thử lại."),
    ("err.no_faster_path", "Couldn't find a faster connection right now. Your current connection still works.", "Chưa tìm được kết nối nhanh hơn. Kết nối hiện tại vẫn dùng bình thường."),
    // ---- messages
    ("err.empty_message", "The message is empty.", "Tin nhắn đang trống."),
    ("err.message_too_long", "The message is too long. Try splitting it into several messages.", "Tin nhắn quá dài. Hãy chia thành nhiều tin."),
    ("err.message_too_large", "This message is too large to send. Try sending less at once.", "Tin nhắn quá lớn để gửi. Hãy gửi ít nội dung hơn mỗi lần."),
    ("err.message_not_found", "This message no longer exists.", "Tin nhắn này không còn nữa."),
    ("err.cannot_forward", "This kind of message can't be forwarded.", "Không thể chuyển tiếp loại tin nhắn này."),
    ("err.cannot_edit", "Only text messages can be edited.", "Chỉ có thể sửa tin nhắn văn bản."),
    ("err.group_op_rejected", "This change isn't allowed in this group.", "Thay đổi này không được phép trong nhóm."),
    ("err.own_button", "You can't press buttons on your own message.", "Bạn không thể bấm nút trên tin nhắn của chính mình."),
    ("err.poll_options", "A poll needs 2 to 10 options.", "Bình chọn cần từ 2 đến 10 lựa chọn."),
    ("err.too_many_scheduled", "You already have {max} scheduled messages. Remove some first.", "Bạn đã có {max} tin hẹn giờ. Hãy xóa bớt trước."),
    // ---- one-line previews / plain-text copies (no emoji: the app draws its own icons)
    ("pv.file", "File: {name}", "Tệp: {name}"),
    ("pv.contact", "Contact: {name}", "Danh thiếp: {name}"),
    ("pv.poll", "Poll: {question}", "Bình chọn: {question}"),
    ("pv.checklist", "Checklist: {title}", "Danh sách việc: {title}"),
    ("pv.reminder", "Reminder: {title}", "Nhắc hẹn: {title}"),
    ("pv.reminder_at", "At {time}", "Lúc {time}"),
    ("err.checklist_title", "Give the list a title.", "Hãy đặt tên cho danh sách."),
    ("err.checklist_items", "A list needs 1 to {max} items.", "Danh sách cần từ 1 đến {max} việc."),
    ("err.checklist_owner_only", "Only the person who made this list can add items.", "Chỉ người tạo danh sách mới thêm được việc."),
    ("err.checklist_item_missing", "This item is no longer on the list.", "Việc này không còn trong danh sách."),
    ("err.reminder_title", "Give the reminder a title.", "Hãy đặt tên cho nhắc hẹn."),
    ("err.reminder_past", "Pick a time in the future.", "Hãy chọn một thời điểm trong tương lai."),
    ("err.reminder_owner_only", "Only the person who set this reminder can cancel it.", "Chỉ người tạo nhắc hẹn mới hủy được."),
    ("err.wake_no_info", "This computer can't be woken up from here yet. Connect to it once while it's on, then try again.", "Chưa thể đánh thức máy này từ đây. Hãy kết nối tới máy một lần khi máy đang bật, rồi thử lại."),
    ("err.wake_failed", "Couldn't send the wake-up signal. Check that this device is connected to a network.", "Chưa gửi được tín hiệu đánh thức. Hãy kiểm tra thiết bị này đang kết nối mạng."),
    ("err.bad_location", "That location isn't valid.", "Vị trí này không hợp lệ."),
    ("err.not_your_location", "You can only update a location you are sharing.", "Bạn chỉ cập nhật được vị trí do chính mình chia sẻ."),
    ("err.voice_too_long", "This voice message is too long.", "Tin nhắn thoại quá dài."),
    ("err.story_empty", "Add some text or a photo to your story.", "Hãy thêm chữ hoặc ảnh cho tin của bạn."),
    ("err.story_limit", "You already have {max} stories up. Delete one before adding another.", "Bạn đang có {max} tin. Hãy xóa bớt một tin trước khi đăng thêm."),
    // ---- files & images
    ("err.file_unreadable", "Can't open this file. It may have been moved or deleted.", "Không mở được file này. Có thể file đã bị chuyển hoặc xóa."),
    ("err.file_unwritable", "Can't save the file there. Choose another folder.", "Không lưu được file vào đó. Hãy chọn thư mục khác."),
    ("err.folder_unwritable", "Can't save to that folder. Choose another one in Settings.", "Không lưu được vào thư mục đó. Hãy chọn thư mục khác trong Cài đặt."),
    ("err.not_a_file", "Please choose a file, not a folder.", "Hãy chọn một file, không phải thư mục."),
    ("err.file_not_found", "This file is no longer available.", "File này không còn nữa."),
    ("err.not_incoming_file", "This file was sent by you, so there is nothing to download.", "File này do bạn gửi nên không cần tải về."),
    ("err.disk_full", "Your device is almost full. Free up some space to receive this file.", "Bộ nhớ máy sắp đầy. Hãy giải phóng dung lượng để nhận file."),
    ("err.image_too_large", "This image is too large (max {max}). Choose a smaller one.", "Ảnh quá lớn (tối đa {max}). Hãy chọn ảnh nhỏ hơn."),
    ("err.image_unreadable", "Can't open this image. Try another one.", "Không mở được ảnh này. Hãy thử ảnh khác."),
    // ---- stickers
    ("err.sticker_format", "Stickers must be PNG, WebP, GIF or JPEG images.", "Nhãn dán phải là ảnh PNG, WebP, GIF hoặc JPEG."),
    ("err.sticker_too_large", "This image is too large for a sticker. Choose a smaller one.", "Ảnh quá lớn để làm nhãn dán. Hãy chọn ảnh nhỏ hơn."),
    ("err.sticker_not_found", "This sticker is no longer available.", "Nhãn dán này không còn nữa."),
    ("err.pack_not_found", "This sticker pack no longer exists.", "Bộ nhãn dán này không còn nữa."),
    ("err.pack_full", "A sticker pack holds at most {max} stickers.", "Mỗi bộ nhãn dán chứa tối đa {max} nhãn."),
    ("err.not_sticker_pack", "This file isn't a Lumora sticker pack.", "File này không phải bộ nhãn dán của Lumora."),
    // ---- groups
    ("err.group_not_found", "This group no longer exists.", "Nhóm này không còn nữa."),
    ("err.group_name_empty", "Please enter a group name.", "Hãy nhập tên nhóm."),
    ("err.group_syncing", "This group is still getting ready. Please try again in a moment.", "Nhóm đang được chuẩn bị. Hãy thử lại sau giây lát."),
    ("err.not_member", "You are no longer a member of this group.", "Bạn không còn là thành viên của nhóm này."),
    ("err.already_member", "This person is already in the group.", "Người này đã ở trong nhóm."),
    ("err.admin_only_add", "Only admins can add people to this group.", "Chỉ quản trị viên mới thêm được người vào nhóm này."),
    ("err.admin_only", "Only group admins can do this.", "Chỉ quản trị viên nhóm mới làm được việc này."),
    ("err.no_perm_remove", "Only admins can remove people from this group.", "Chỉ quản trị viên mới xóa được người khỏi nhóm này."),
    ("err.owner_only_role", "Only the group owner can change roles.", "Chỉ chủ nhóm mới đổi được vai trò."),
    ("err.admins_only_post", "Only admins can post in this group.", "Chỉ quản trị viên mới đăng được trong nhóm này."),
    ("err.slow_mode", "This group has slow mode on. You can post again in {s} s.", "Nhóm đang bật chế độ chậm. Bạn có thể gửi lại sau {s} giây."),
    ("err.group_too_fast", "You're sending messages too quickly in this group. Wait a minute, then try again.", "Bạn đang gửi tin quá nhanh trong nhóm này. Hãy chờ một phút rồi gửi tiếp."),
    ("err.group_quota_you", "You've sent a lot to this group today. Please try again tomorrow.", "Hôm nay bạn đã gửi rất nhiều vào nhóm này. Hãy thử lại vào ngày mai."),
    ("err.group_quota", "This group has received too much today. Please try again tomorrow.", "Hôm nay nhóm đã nhận quá nhiều tin. Hãy thử lại vào ngày mai."),
    ("group.flood_admin", "{name} is sending too many messages, so some were hidden. Turn on slow mode ({s} s between messages)?", "{name} đang gửi quá nhiều tin nên một số tin đã bị ẩn. Bật chế độ chậm ({s} giây giữa hai tin)?"),
    ("group.flood_member", "{name} is sending too many messages, so some were hidden.", "{name} đang gửi quá nhiều tin nên một số tin đã bị ẩn."),
    ("group.quota_full", "This group received too much today, so some new messages were hidden.", "Hôm nay nhóm nhận quá nhiều tin nên một số tin mới đã bị ẩn."),
    ("err.invite_invalid", "This invite link isn't valid. Ask for a new one.", "Liên kết mời không hợp lệ. Hãy xin một liên kết mới."),
    ("err.invite_expired", "This invite link has expired. Ask for a new one.", "Liên kết mời đã hết hạn. Hãy xin một liên kết mới."),
    ("err.group_blocked", "You blocked this group. Unblock it in Settings › Privacy to join again.", "Bạn đã chặn nhóm này. Hãy bỏ chặn trong Cài đặt › Quyền riêng tư để tham gia lại."),
    ("err.report_target", "This can't be reported.", "Không thể báo cáo nội dung này."),
    ("err.report_reason", "Please choose a reason.", "Hãy chọn một lý do."),
    ("err.report_no_admins", "This group has no other admin to send the report to.", "Nhóm này không có quản trị viên nào khác để nhận báo cáo."),
    ("err.name_empty", "Please enter a name.", "Hãy nhập tên."),
    ("err.channel_empty", "Please enter a channel name.", "Hãy nhập tên kênh."),
    // ---- bots
    ("err.bot_cannot_start", "Bots can only reply to people who message them first.", "Bot chỉ trả lời được người đã nhắn cho bot trước."),
    ("err.bot_username_suffix", "A bot's username must end with \"bot\" (for example shop_bot).", "Tên người dùng của bot phải kết thúc bằng \"bot\" (ví dụ shop_bot)."),
    ("err.bot_limit", "You can have at most {max} bots.", "Bạn chỉ có thể tạo tối đa {max} bot."),
    ("err.bot_exists", "You already have a bot with this username.", "Bạn đã có bot với tên người dùng này."),
    ("err.bot_not_found", "Bot not found.", "Không tìm thấy bot."),
    ("err.bad_bot_token", "This bot code isn't valid. Copy it again from BotFather.", "Mã bot không hợp lệ. Hãy sao chép lại từ BotFather."),
    ("err.bot_token_mismatch", "This bot code belongs to a different bot. Use a new data folder for it.", "Mã bot này thuộc về một bot khác. Hãy dùng thư mục dữ liệu mới cho bot."),
    // ---- my devices (multi-device)
    ("err.restore_data_exists", "This device already has Lumora data. Restore into a fresh install, or open the existing data.", "Máy này đã có dữ liệu Lumora. Hãy khôi phục trên bản cài mới, hoặc mở dữ liệu đang có."),
    ("err.phrase_on_primary", "The recovery phrase is only shown on your main device.", "Cụm từ khôi phục chỉ hiển thị trên thiết bị chính của bạn."),
    ("err.primary_only", "Only your main device can do this.", "Chỉ thiết bị chính của bạn mới làm được việc này."),
    ("err.link_on_primary", "Link new devices from your main device.", "Hãy liên kết thiết bị mới từ thiết bị chính của bạn."),
    ("err.link_not_fresh", "This device already has chats. Only a new, empty device can be linked to another account.", "Thiết bị này đã có dữ liệu trò chuyện. Chỉ thiết bị mới, chưa có dữ liệu mới liên kết được với tài khoản khác."),
    ("err.link_code_invalid", "That link code isn't right. Check it and try again.", "Mã liên kết chưa đúng. Hãy kiểm tra rồi thử lại."),
    ("err.link_code_expired", "This link code has expired. Show a new one on the new device.", "Mã liên kết đã hết hạn. Hãy tạo mã mới trên thiết bị mới."),
    ("err.link_code_wrong", "The code didn't match. Check the code on the new device and try again.", "Mã không khớp. Hãy kiểm tra mã trên thiết bị mới rồi thử lại."),
    ("err.link_not_found", "Couldn't find the new device. Keep it open on the linking screen, nearby or online.", "Không tìm thấy thiết bị mới. Hãy giữ thiết bị đó mở ở màn hình liên kết, ở gần hoặc có Internet."),
    ("err.link_failed", "Linking didn't finish. Please try again.", "Liên kết chưa hoàn tất. Vui lòng thử lại."),
    ("err.link_already", "This device is already linked to your account.", "Thiết bị này đã được liên kết với tài khoản của bạn."),
    ("err.too_many_devices", "You can link at most {max} devices. Remove one first.", "Bạn chỉ liên kết được tối đa {max} thiết bị. Hãy gỡ bớt một thiết bị trước."),
    ("err.bot_single_device", "Bots run on a single device.", "Bot chỉ chạy trên một thiết bị."),
    ("err.bot_join_public", "Bots can't join groups by themselves. A group admin can add the bot.", "Bot không tự vào nhóm được. Quản trị viên nhóm có thể thêm bot."),
    ("err.file_on_other_device", "This file is on your other device. Open Lumora there to get it.", "File này đang ở thiết bị khác của bạn. Hãy mở Lumora trên thiết bị đó để tải về."),
    ("err.peer_needs_update", "This friend uses an older Lumora that can't read messages from this device yet. Send it from your main device, or ask them to update.", "Người này dùng Lumora phiên bản cũ nên chưa đọc được tin gửi từ thiết bị này. Hãy gửi từ thiết bị chính, hoặc nhờ họ cập nhật."),
    ("err.device_not_found", "This device isn't part of your account any more.", "Thiết bị này không còn thuộc tài khoản của bạn."),
    ("err.cannot_revoke_self", "This is your main device. To stop using it, make another device the main one first.", "Đây là thiết bị chính. Muốn thôi dùng máy này, hãy đặt một thiết bị khác làm thiết bị chính trước."),
    ("err.primary_logout", "This is your main device and can't be signed out. Make another device the main one first.", "Đây là thiết bị chính nên không đăng xuất được. Hãy đặt một thiết bị khác làm thiết bị chính trước."),
    ("err.already_primary", "This is already your main device.", "Đây đã là thiết bị chính của bạn."),
    ("err.bad_phrase", "That recovery phrase isn't right. Please check each word.", "Cụm từ khôi phục chưa đúng. Hãy kiểm tra lại từng từ."),
    ("err.phrase_mismatch", "This recovery phrase belongs to a different account.", "Cụm từ khôi phục này thuộc về một tài khoản khác."),
    ("err.choose_device", "This person has several devices. Choose which one to connect to.", "Người này có nhiều thiết bị. Hãy chọn thiết bị muốn kết nối."),
    // ---- remote control
    ("err.fixed_pw_len", "A fixed password needs at least 8 characters.", "Mật khẩu cố định cần ít nhất 8 ký tự."),
    ("err.remote_disabled", "The other device isn't accepting remote control right now, or is paused after too many wrong passwords. Try again later.", "Máy bên kia đang không nhận điều khiển, hoặc đang tạm khóa do nhập sai mật khẩu nhiều lần. Hãy thử lại sau."),
    ("err.wrong_password", "Wrong password. Check the password shown on the other device.", "Sai mật khẩu. Hãy kiểm tra mật khẩu hiển thị trên máy bên kia."),
    ("err.self_control", "You can't control your own device.", "Bạn không thể điều khiển chính máy của mình."),
    ("err.no_session", "This session has ended.", "Phiên này đã kết thúc."),
    ("err.partner_declined", "The other person declined.", "Người bên kia đã từ chối."),
    ("err.capture_failed", "The other device couldn't share its screen. They may need to allow screen sharing.", "Máy bên kia chưa chia sẻ được màn hình. Có thể họ cần cho phép chia sẻ màn hình."),
    ("err.view_only", "This session is view-only.", "Phiên này chỉ được xem."),
    ("err.power_not_allowed", "The other device doesn't allow restart or sign-out.", "Máy bên kia không cho phép khởi động lại hoặc đăng xuất."),
    ("err.power_failed", "The other device couldn't do this.", "Máy bên kia không thực hiện được thao tác này."),
    ("err.input_unavailable", "Mouse and keyboard control isn't available on this device yet. Open Diagnostics to allow it.", "Chưa điều khiển được chuột và bàn phím trên máy này. Mở mục Chẩn đoán để cho phép."),
    ("err.capture_unavailable", "Screen sharing isn't available. Allow Lumora to share your screen and try again.", "Chưa chia sẻ được màn hình. Hãy cho phép Lumora chia sẻ màn hình rồi thử lại."),
    // ---- calls
    ("err.in_other_call", "You are already in another call.", "Bạn đang trong một cuộc gọi khác."),
    ("err.call_ended", "The call has ended.", "Cuộc gọi đã kết thúc."),
    ("err.cannot_call_saved", "You can't call Saved Messages.", "Không thể gọi trong Tin nhắn đã lưu."),
    ("err.mic_unavailable", "Can't use the microphone. Check that Lumora is allowed to use it and no other app is holding it.", "Không dùng được micro. Hãy kiểm tra Lumora đã được cấp quyền và không có ứng dụng khác đang dùng micro."),
    ("err.camera_unavailable", "Can't use the camera. Check that Lumora is allowed to use it and no other app is holding it.", "Không dùng được camera. Hãy kiểm tra Lumora đã được cấp quyền và không có ứng dụng khác đang dùng camera."),
    // system messages (code → template)
    ("sys.group_created", "{actor} created the group “{name}”", "{actor} đã tạo nhóm “{name}”"),
    ("sys.member_added", "{actor} added {peer}", "{actor} đã thêm {peer}"),
    ("sys.member_removed", "{actor} removed {peer} from the group", "{actor} đã xóa {peer} khỏi nhóm"),
    ("sys.member_banned", "{actor} banned {peer}", "{actor} đã cấm {peer} khỏi nhóm"),
    ("sys.member_left", "{actor} left the group", "{actor} đã rời nhóm"),
    ("sys.group_renamed", "{actor} renamed the group to “{name}”", "{actor} đã đổi tên nhóm thành “{name}”"),
    ("sys.role_admin", "{actor} made {peer} an admin", "{actor} đã đặt {peer} làm quản trị viên"),
    ("sys.role_member", "{actor} made {peer} a member", "{actor} đã đặt {peer} làm thành viên"),
    ("sys.you_removed", "You are no longer a member of this group", "Bạn không còn là thành viên của nhóm này"),
    ("sys.scheduled_failed", "A scheduled message could not be sent: “{text}” ({error})", "Không gửi được tin hẹn giờ: “{text}” ({error})"),
    ("sys.call_missed_busy", "Missed call from {name} (you were in another call)", "Cuộc gọi nhỡ từ {name} (bạn đang trong cuộc gọi khác)"),
    ("sys.you_added", "{actor} added you to “{name}”", "{actor} đã thêm bạn vào nhóm “{name}”"),
    ("sys.contact_device_added", "{name} added a new device. Their security code changed.", "{name} vừa thêm một thiết bị mới. Mã bảo mật đã thay đổi."),
    ("ch.general", "general", "chung"),
    ("ch.voice", "Voice lounge", "Phòng thoại"),
];

/// An error the end user is meant to read: an i18n key plus `{name}` arguments, rendered
/// in the current UI language when displayed. Works with `anyhow` (`?`, `bail!`,
/// `ensure!`, `.context()`); the API layer finds it anywhere in the error chain and
/// answers `{"error": <plain text>, "code": key}`. Anything else is reported as a
/// generic "something went wrong" with the raw text only in `detail`.
#[derive(Debug, Clone)]
pub struct UserError {
    pub key: &'static str,
    pub args: Vec<(&'static str, String)>,
    /// Optional technical cause, shown only under "Technical details".
    pub detail: Option<String>,
}

impl UserError {
    /// Add a `{name}` argument.
    pub fn with(mut self, name: &'static str, value: impl ToString) -> Self {
        self.args.push((name, value.to_string()));
        self
    }
    /// Attach a technical cause (kept out of the main message).
    pub fn detail(mut self, d: impl std::fmt::Display) -> Self {
        self.detail = Some(d.to_string());
        self
    }
    fn argv(&self) -> Vec<(&str, &str)> {
        self.args.iter().map(|(k, v)| (*k, v.as_str())).collect()
    }
    /// Text in the current UI language.
    pub fn message(&self) -> String {
        trf(self.key, &self.argv())
    }
    /// English text (logs, developer tools).
    pub fn message_en(&self) -> String {
        trf_en(self.key, &self.argv())
    }
}

impl std::fmt::Display for UserError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message())
    }
}

impl std::error::Error for UserError {}

/// A user-facing error for catalog key `key` (see [`UserError`]).
pub fn user_err(key: &'static str) -> UserError {
    debug_assert!(TABLE.iter().any(|(k, _, _)| *k == key), "missing i18n key {key}");
    UserError { key, args: Vec::new(), detail: None }
}

/// The user-facing error inside an error chain, if any.
pub fn find_user_err(e: &anyhow::Error) -> Option<&UserError> {
    e.chain().find_map(|c| c.downcast_ref::<UserError>())
}

/// Keep `e` if it already carries a user-facing error, otherwise report it as `key`
/// with the raw cause as technical detail.
pub fn or_user(e: anyhow::Error, key: &'static str) -> anyhow::Error {
    if find_user_err(&e).is_some() {
        e
    } else {
        user_err(key).detail(format!("{e:#}")).into()
    }
}

/// `{"error", "code", "detail"?}` for an API/FFI error response.
pub fn error_fields(e: &anyhow::Error) -> serde_json::Map<String, serde_json::Value> {
    use serde_json::Value;
    let mut m = serde_json::Map::new();
    match find_user_err(e) {
        Some(u) => {
            m.insert("error".into(), Value::String(u.message()));
            m.insert("code".into(), Value::String(u.key.into()));
            if let Some(d) = &u.detail {
                m.insert("detail".into(), Value::String(d.clone()));
            }
        }
        None => {
            m.insert("error".into(), Value::String(tr("err.generic")));
            m.insert("code".into(), Value::String("internal".into()));
            m.insert("detail".into(), Value::String(format!("{e:#}")));
        }
    }
    m
}

/// One plain sentence for an error (user message, or the generic one).
pub fn error_text(e: &anyhow::Error) -> String {
    find_user_err(e).map(|u| u.message()).unwrap_or_else(|| tr("err.generic"))
}

/// The catalog key equal to `s`, if `s` is one (e.g. a reason code sent by a peer).
pub fn known_key(s: &str) -> Option<&'static str> {
    TABLE.iter().find(|(k, _, _)| *k == s).map(|(k, _, _)| *k)
}

pub fn tr(key: &str) -> String {
    let vi = LANG.load(Ordering::Relaxed) == 1;
    TABLE
        .iter()
        .find(|(k, _, _)| *k == key)
        .map(|(_, en, v)| if vi { v.to_string() } else { en.to_string() })
        .unwrap_or_else(|| key.to_string())
}

/// Fill `{name}` placeholders in one pass over the template: substituted values are
/// never scanned again, so a value containing `{other}` (a group or user name) can't
/// inject another argument.
fn fill(template: &str, args: &[(&str, &str)]) -> String {
    let mut out = String::with_capacity(template.len() + 16);
    let mut rest = template;
    while let Some(i) = rest.find('{') {
        out.push_str(&rest[..i]);
        let after = &rest[i + 1..];
        match after.find('}').map(|j| (&after[..j], j)) {
            Some((name, j)) if args.iter().any(|(k, _)| *k == name) => {
                out.push_str(args.iter().find(|(k, _)| *k == name).map(|(_, v)| *v).unwrap_or(""));
                rest = &after[j + 1..];
            }
            _ => {
                out.push('{');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// Translate with `{name}` placeholders.
pub fn trf(key: &str, args: &[(&str, &str)]) -> String {
    fill(&tr(key), args)
}

/// English rendering regardless of current language (stable fallback stored in the DB).
pub fn trf_en(key: &str, args: &[(&str, &str)]) -> String {
    let s = TABLE.iter().find(|(k, _, _)| *k == key).map(|(_, en, _)| en.to_string()).unwrap_or_else(|| key.to_string());
    fill(&s, args)
}

/// The full catalog (for the UI to render stored system messages in any language).
pub fn catalog() -> serde_json::Value {
    let mut en = serde_json::Map::new();
    let mut vi = serde_json::Map::new();
    for (k, e, v) in TABLE {
        en.insert(k.to_string(), serde_json::Value::String(e.to_string()));
        vi.insert(k.to_string(), serde_json::Value::String(v.to_string()));
    }
    serde_json::json!({"en": en, "vi": vi})
}

#[cfg(test)]
mod tests {
    use super::*;
    /// A value that looks like a placeholder is inserted as-is, never substituted again.
    #[test]
    fn placeholders_are_filled_in_one_pass() {
        let t = fill("{actor} renamed the group to {name}", &[("actor", "{name}"), ("name", "X")]);
        assert_eq!(t, "{name} renamed the group to X");
        assert_eq!(fill("{a} {missing} {", &[("a", "1")]), "1 {missing} {");
        assert_eq!(fill("ước {a}", &[("a", "{a}{a}")]), "ước {a}{a}");
    }

    #[test]
    fn both_languages() {
        set_lang("vi");
        assert_eq!(trf("sys.member_left", &[("actor", "An")]), "An đã rời nhóm");
        set_lang("en");
        assert_eq!(trf("sys.member_left", &[("actor", "An")]), "An left the group");
        assert_eq!(trf_en("err.own_id", &[]), "This is your own ID.");
        assert!(TABLE.iter().all(|(_, e, v)| !e.is_empty() && !v.is_empty()));
        // keys are unique
        let mut keys: Vec<_> = TABLE.iter().map(|(k, _, _)| *k).collect();
        keys.sort();
        keys.dedup();
        assert_eq!(keys.len(), TABLE.len());
    }

    #[test]
    fn user_errors_survive_anyhow() {
        use anyhow::Context;
        fn fails() -> anyhow::Result<()> {
            anyhow::ensure!(1 + 1 == 3, user_err("err.slow_mode").with("s", 5));
            Ok(())
        }
        let e = fails().context("while sending").unwrap_err();
        let u = find_user_err(&e).expect("user error in chain");
        assert_eq!(u.key, "err.slow_mode");
        assert!(u.message_en().contains("5 s"));
        let f = error_fields(&e);
        assert_eq!(f["code"], "err.slow_mode");
        assert!(f.get("detail").is_none());
        // anything else is generic, raw text only in detail
        let raw = anyhow::anyhow!("QUIC handshake timed out");
        let f = error_fields(&raw);
        assert_eq!(f["code"], "internal");
        assert!(!f["error"].as_str().unwrap().contains("QUIC"));
        assert!(f["detail"].as_str().unwrap().contains("QUIC"));
        // or_user keeps the cause as detail
        let f = error_fields(&or_user(anyhow::anyhow!("all paths failed"), "err.peer_offline"));
        assert_eq!(f["code"], "err.peer_offline");
        assert!(f["detail"].as_str().unwrap().contains("all paths"));
    }
}
