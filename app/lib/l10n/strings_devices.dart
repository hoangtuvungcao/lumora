// Copy for "My devices", linking a new device, the approval sheet, the new
// device's link and history screens, and friends' devices
// (lib/ui/devices/). Kept in its own file and spread into kStrings.
// key: [Tiếng Việt, English]. Plain words only: no "key", "certificate",
// "peer", "protocol" or "relay".

const Map<String, List<String>> kDeviceStrings = {
  // ----------------------------------------------------------- my devices
  'settings_devices': ['Thiết bị của tôi', 'My devices'],
  'dv_summary': ['Bạn đang dùng Lumora trên {n} thiết bị', 'You use Lumora on {n} devices'],
  'dv_summary_one': ['Bạn đang dùng Lumora trên 1 thiết bị', 'You use Lumora on 1 device'],
  'dv_summary_sub': [
    'Tin nhắn, cuộc gọi và danh bạ giống nhau trên mọi thiết bị của bạn, và vẫn đi thẳng giữa các thiết bị, được mã hoá.',
    'Messages, calls and contacts are the same on all your devices, and still travel directly between them, encrypted.'
  ],
  'dv_link_new': ['Liên kết thiết bị mới', 'Link a new device'],
  'dv_linked_note': ['Thiết bị mới được liên kết từ thiết bị chính của bạn ({name}).', 'New devices are linked from your main device ({name}).'],
  'dv_linked_note_generic': ['Thiết bị mới được liên kết từ thiết bị chính của bạn.', 'New devices are linked from your main device.'],
  'dv_main': ['Thiết bị chính', 'Main device'],
  'dv_list_title': ['Thiết bị', 'Devices'],
  'dv_active_now': ['Đang hoạt động', 'Active now'],
  'dv_active_min': ['Hoạt động {n} phút trước', 'Active {n} min ago'],
  'dv_active_hour': ['Hoạt động {n} giờ trước', 'Active {n} h ago'],
  'dv_active_day': ['Hoạt động {n} ngày trước', 'Active {n} days ago'],
  'dv_active_day_one': ['Hoạt động hôm qua', 'Active yesterday'],
  'dv_active_never': ['Chưa hoạt động', 'Not active yet'],
  'dv_added': ['Thêm ngày {date}', 'Added {date}'],
  'dv_added_label': ['Ngày thêm', 'Added'],
  'dv_last_active': ['Hoạt động gần nhất', 'Last active'],
  'dv_kind_0': ['Thiết bị', 'Device'],
  'dv_kind_1': ['Điện thoại', 'Phone'],
  'dv_kind_2': ['Máy tính bảng', 'Tablet'],
  'dv_kind_3': ['Máy tính', 'Computer'],
  'dv_kind_4': ['Máy chạy nền', 'Always-on computer'],
  'dv_remote_id': ['ID điều khiển từ xa', 'Remote control ID'],
  'dv_rename': ['Đổi tên', 'Rename'],
  'dv_rename_title': ['Đổi tên thiết bị', 'Rename device'],
  'dv_rename_hint': ['Ví dụ: Laptop ở nhà', 'e.g. Home laptop'],
  'dv_renamed': ['Đã đổi tên thiết bị', 'Device renamed'],
  'dv_signout_device': ['Đăng xuất thiết bị này', 'Sign out this device'],
  'dv_signout_title': ['Đăng xuất “{name}”?', 'Sign out “{name}”?'],
  'dv_signout_body': [
    'Thiết bị đó sẽ không nhận tin nhắn hay cuộc gọi của bạn nữa. Tin nhắn trên đó sẽ được xoá khi nó kết nối lại.',
    'That device will stop getting your messages and calls. The messages on it are deleted the next time it connects.'
  ],
  'dv_signout_wipe': ['Xoá cả ảnh và tệp đã tải trên thiết bị đó', 'Also delete downloaded photos and files on it'],
  'dv_signout_action': ['Đăng xuất', 'Sign out'],
  'dv_logout_main_title': ['Đăng xuất khỏi máy này?', 'Sign out on this device?'],
  'dv_logout_main_body': [
    'Tài khoản, tin nhắn và cài đặt sẽ bị xoá khỏi máy này để người khác có thể đăng nhập tài khoản của họ. Các thiết bị đã liên kết vẫn dùng tiếp được. Lumora không có máy chủ giữ tài khoản, nên muốn đăng nhập lại trên máy này bạn cần 24 từ khôi phục, tệp sao lưu, hoặc liên kết từ một máy khác đang đăng nhập.',
    'Your account, messages and settings are removed from this device so someone else can sign in with theirs. Linked devices keep working. Lumora has no server holding your account, so signing back in here needs your 24-word recovery phrase, a backup file, or a link from another signed-in device.',
  ],
  'dv_logout_main_show': ['Xem 24 từ khôi phục', 'Show recovery phrase'],
  'dv_logout_password': ['Mật khẩu tài khoản', 'Account password'],
  'sign_out': ['Đăng xuất', 'Sign out'],
  'sign_out_hint': ['Xoá tài khoản khỏi máy này để đăng nhập tài khoản khác', 'Remove your account from this device to sign in with another'],
  'dv_signed_out_done': ['Đã đăng xuất {name}', '{name} was signed out'],
  'dv_logout_self_title': ['Đăng xuất Lumora trên thiết bị này?', 'Sign out of Lumora on this device?'],
  'dv_logout_self_body': [
    'Tin nhắn trên thiết bị này sẽ được xoá. Tài khoản và tin nhắn vẫn còn nguyên trên các thiết bị khác của bạn.',
    'Messages on this device will be deleted. Your account and messages stay on your other devices.'
  ],
  'dv_make_main': ['Đặt làm thiết bị chính', 'Make this the main device'],
  'dv_make_main_hint': ['Cần cụm từ khôi phục 24 từ', 'Needs your 24-word recovery phrase'],
  'dv_promote_sub': ['Nhập cụm từ khôi phục 24 từ của tài khoản để xác nhận.', 'Enter your account’s 24-word recovery phrase to confirm.'],
  'dv_promote_note': [
    'Thiết bị chính hiện tại ({name}) sẽ được đăng xuất. Từ nay, bạn liên kết thiết bị mới và xem cụm từ khôi phục trên thiết bị này.',
    'Your current main device ({name}) will be signed out. From then on, you link new devices and see your recovery phrase on this device.'
  ],
  'dv_promote_note_generic': [
    'Thiết bị chính hiện tại sẽ được đăng xuất. Từ nay, bạn liên kết thiết bị mới và xem cụm từ khôi phục trên thiết bị này.',
    'Your current main device will be signed out. From then on, you link new devices and see your recovery phrase on this device.'
  ],
  'dv_promoted': ['Thiết bị này giờ là thiết bị chính', 'This is now your main device'],
  'dv_switching': ['Đang chuyển thiết bị chính…', 'Switching your main device…'],
  'dv_lost_title': ['Mất một thiết bị?', 'Lost a device?'],
  'dv_lost_body': [
    'Hãy đăng xuất nó ở đây. Thiết bị đó sẽ không nhận được tin nhắn mới nữa.',
    'Sign it out here. It won’t get any new messages.'
  ],
  'dv_history_row': ['Đang chép tin nhắn cũ… {n} tin', 'Copying older messages… {n}'],

  // ------------------------------------------- link a new device (existing)
  'dv_link_sub': ['Dùng tài khoản này trên một điện thoại, máy tính bảng hoặc máy tính khác.', 'Use this account on another phone, tablet or computer.'],
  'dv_link_qr': ['Mã QR', 'QR code'],
  'dv_link_code': ['Mã 12 số', '12-digit code'],
  'dv_link_expires': ['Mã hết hạn sau {t}', 'Code expires in {t}'],
  'dv_link_expired': ['Mã đã hết hạn', 'This code has expired'],
  'dv_link_expired_sub': ['Tạo mã mới để tiếp tục liên kết.', 'Get a new code to keep linking.'],
  'dv_link_new_code': ['Tạo mã mới', 'Get a new code'],
  'dv_link_step1': ['Trên thiết bị mới, mở Lumora.', 'On the new device, open Lumora.'],
  'dv_link_step2': ['Chọn “Tôi đã có tài khoản Lumora trên thiết bị khác”.', 'Choose “I already use Lumora on another device”.'],
  'dv_link_step3_qr': ['Quét mã QR này, rồi xác nhận tại đây.', 'Scan this QR code, then confirm here.'],
  'dv_link_step3_code': ['Nhập mã 12 số này, rồi xác nhận tại đây.', 'Type this 12-digit code, then confirm here.'],
  'dv_link_own_only': [
    'Chỉ liên kết thiết bị của chính bạn. Thiết bị được liên kết sẽ xem được tin nhắn và gọi điện bằng tài khoản của bạn.',
    'Only link devices that are yours. A linked device can read your messages and make calls as you.'
  ],
  'dv_link_code_rotated': ['Mã bị nhập sai nhiều lần nên đã được đổi để giữ an toàn. Hãy dùng mã mới.', 'The code was typed wrong several times, so it was changed to keep you safe. Use the new one.'],
  'dv_link_failed': ['Không liên kết được. Hãy thử lại.', 'Couldn’t link the device. Please try again.'],
  'dv_try_again': ['Thử lại', 'Try again'],
  'dv_link_done_title': ['Đã liên kết {name}', '{name} is linked'],
  'dv_link_done_sub': ['Tin nhắn cũ đang được chép sang. Hãy để Lumora mở trên thiết bị này một lúc.', 'Older messages are being copied over. Keep Lumora open on this device for a little while.'],
  'dv_link_done_none': ['Thiết bị mới sẽ nhận tin nhắn từ bây giờ.', 'The new device gets messages from now on.'],
  'dv_copy_code': ['Sao chép mã', 'Copy code'],
  'dv_link_open_on_new': [
    'Mã này dùng trên thiết bị mới: mở Lumora trên đó và chọn “Tôi đã có tài khoản Lumora trên thiết bị khác”.',
    'Use this code on the new device: open Lumora there and choose “I already use Lumora on another device”.'
  ],

  // ---------------------------------------------------------- approval
  'dv_approve_title': ['Cho phép thiết bị này dùng tài khoản của bạn?', 'Let this device use your account?'],
  'dv_approve_near': ['Đang ở cùng mạng với bạn', 'On the same network as you'],
  'dv_approve_internet': ['Kết nối qua Internet', 'Connecting over the Internet'],
  'dv_approve_warn': [
    'Chỉ cho phép nếu bạn vừa nhập mã trên thiết bị của chính mình. Thiết bị này sẽ xem được tin nhắn và gọi điện bằng tài khoản của bạn.',
    'Only allow this if you just used the code on your own device. It will be able to read your messages and make calls as you.'
  ],
  'dv_history_label': ['Chép tin nhắn cũ sang thiết bị mới', 'Copy older messages to the new device'],
  'dv_history_none': ['Không', 'None'],
  'dv_history_1m': ['1 tháng', '1 month'],
  'dv_history_6m': ['6 tháng', '6 months'],
  'dv_history_all': ['Tất cả', 'All'],
  'dv_history_hint_none': ['Thiết bị mới chỉ nhận tin nhắn từ bây giờ.', 'The new device only gets messages from now on.'],
  'dv_history_hint_1m': ['Chép tin nhắn của 1 tháng gần đây.', 'Copies messages from the last month.'],
  'dv_history_hint_6m': ['Chép tin nhắn của 6 tháng gần đây.', 'Copies messages from the last 6 months.'],
  'dv_history_hint_all': ['Chép toàn bộ tin nhắn. Có thể mất một lúc.', 'Copies every message. This can take a while.'],
  'dv_allow': ['Cho phép', 'Allow'],
  'dv_deny': ['Từ chối', 'Decline'],
  'dv_denied': ['Đã từ chối thiết bị này', 'Device declined'],

  // ------------------------------------------------------- new device
  'dv_have_account': ['Tôi đã có tài khoản Lumora trên thiết bị khác', 'I already use Lumora on another device'],
  'dv_join_title': ['Liên kết với tài khoản của bạn', 'Link to your account'],
  'dv_join_sub': [
    'Trên thiết bị đang dùng Lumora, mở Cài đặt › Thiết bị của tôi › Liên kết thiết bị mới.',
    'On the device that already has Lumora, open Settings › My devices › Link a new device.'
  ],
  'dv_join_scan': ['Quét mã QR', 'Scan the QR code'],
  'dv_join_scan_hint': ['Hướng camera vào mã QR trên thiết bị kia', 'Point the camera at the QR code on the other device'],
  'dv_join_or_code': ['Hoặc nhập mã 12 số', 'Or type the 12-digit code'],
  'dv_join_code_label': ['Mã 12 số trên thiết bị kia', 'The 12-digit code'],
  'dv_join_paste': ['Dán mã', 'Paste code'],
  'dv_join_paste_none': ['Không tìm thấy mã liên kết trong nội dung đã sao chép.', 'No link code found in what you copied.'],
  'dv_join_connect': ['Liên kết', 'Link'],
  'dv_join_checking': ['Đang tìm thiết bị kia…', 'Looking for your other device…'],
  'dv_join_wait_title': ['Hãy xác nhận trên {name}', 'Confirm on {name}'],
  'dv_join_wait_title_generic': ['Hãy xác nhận trên thiết bị kia', 'Confirm on your other device'],
  'dv_join_wait_sub': ['Mở Lumora trên thiết bị đó và chọn “Cho phép”.', 'Open Lumora on that device and choose “Allow”.'],
  'dv_join_waiting': ['Đang chờ xác nhận…', 'Waiting for confirmation…'],
  'dv_join_approved_title': ['Đã được cho phép', 'You’re in'],
  'dv_join_approved_sub': ['Đang chuẩn bị tài khoản trên thiết bị này…', 'Setting up your account on this device…'],
  'dv_join_failed_title': ['Chưa liên kết được', 'Not linked yet'],
  'dv_join_failed_declined': ['Yêu cầu đã bị từ chối trên thiết bị kia.', 'The request was declined on the other device.'],
  'dv_join_failed_cancelled': ['Yêu cầu liên kết đã bị huỷ.', 'The link request was cancelled.'],
  'dv_join_failed_expired': ['Mã đã hết hạn. Hãy tạo mã mới trên thiết bị kia.', 'The code has expired. Get a new code on the other device.'],
  'dv_join_camera_off': ['Không mở được camera. Bạn có thể nhập mã 12 số.', 'Couldn’t open the camera. You can type the 12-digit code instead.'],
  // camera QR scanner (phones)
  'qr_scan_title': ['Quét mã QR trên thiết bị kia', 'Scan the QR code on your other device'],
  'qr_scan_hint': ['Đặt mã QR vào trong khung', 'Fit the QR code inside the frame'],
  'qr_scan_not_link': ['Đây không phải mã liên kết Lumora', 'That isn’t a Lumora link code'],
  'qr_scan_torch': ['Đèn pin', 'Flashlight'],
  'qr_scan_type_code': ['Nhập mã 12 số', 'Type the 12-digit code'],
  'qr_cam_denied_title': ['Lumora cần dùng camera để quét mã', 'Lumora needs the camera to scan the code'],
  'qr_cam_denied_sub': [
    'Hãy cho phép Lumora dùng camera trong Cài đặt của máy, hoặc nhập mã 12 số thay cho việc quét.',
    'Allow Lumora to use the camera in your phone’s Settings, or type the 12-digit code instead.'
  ],
  'qr_cam_open_settings': ['Mở Cài đặt', 'Open Settings'],
  'qr_cam_failed_title': ['Không mở được camera', 'Couldn’t open the camera'],
  'qr_cam_failed_sub': [
    'Có thể ứng dụng khác đang dùng camera. Bạn vẫn có thể nhập mã 12 số.',
    'Another app may be using it. You can still type the 12-digit code.'
  ],
  'err_link_code_invalid': ['Đây không phải mã liên kết. Hãy kiểm tra 12 chữ số trên thiết bị kia.', 'That isn’t a link code. Check the 12 digits on the other device.'],
  'err_link_code_expired': ['Mã đã hết hạn. Hãy tạo mã mới trên thiết bị kia.', 'The code has expired. Get a new code on the other device.'],
  'err_link_code_wrong': ['Mã chưa đúng. Hãy kiểm tra lại trên thiết bị kia.', 'That code isn’t right. Check it again on the other device.'],
  'err_link_not_found': ['Chưa tìm thấy thiết bị kia. Hãy để Lumora mở trên đó rồi thử lại.', 'Couldn’t find your other device. Keep Lumora open on it and try again.'],
  'err_link_failed': ['Không liên kết được. Hãy thử lại.', 'Couldn’t link the device. Please try again.'],
  'err_phrase_mismatch': ['Cụm từ này thuộc về một tài khoản khác.', 'This phrase belongs to a different account.'],
  'err_bad_phrase': ['Cụm từ khôi phục chưa đúng. Hãy kiểm tra từng từ.', 'The recovery phrase isn’t right. Check each word.'],
  'dv_promote_pass': ['Mật khẩu mở Lumora trên thiết bị này', 'The passphrase you use to open Lumora here'],
  'dv_promote_pass_hint': ['Mật khẩu của bạn', 'Your passphrase'],
  'err_wrong_passphrase': ['Mật khẩu chưa đúng. Hãy thử lại.', 'That passphrase isn’t right. Please try again.'],
  'err_passphrase_required': ['Hãy nhập mật khẩu mở Lumora trên thiết bị này.', 'Enter the passphrase you use to open Lumora here.'],
  'err_already_primary': ['Thiết bị này đã là thiết bị chính.', 'This is already your main device.'],
  'err_primary_only': ['Chỉ làm được việc này trên thiết bị chính.', 'This can only be done on your main device.'],

  // ---------------------------------------------------- history copy
  'dv_hist_title': ['Đang chép tin nhắn cũ…', 'Copying your older messages…'],
  'dv_hist_count': ['{n} tin nhắn', '{n} messages'],
  'dv_hist_count_one': ['1 tin nhắn', '1 message'],
  'dv_hist_convs': ['{done}/{total} cuộc trò chuyện', '{done} of {total} chats'],
  'dv_hist_since': ['Từ {date} đến nay', 'From {date} until now'],
  'dv_hist_sub': [
    'Bạn có thể dùng Lumora ngay — việc chép vẫn tiếp tục ở chế độ nền. Hãy để Lumora mở trên thiết bị kia cho đến khi xong.',
    'You can start using Lumora now — copying goes on in the background. Keep Lumora open on your other device until it’s done.'
  ],
  'dv_hist_use_now': ['Dùng ngay', 'Start using Lumora'],
  'dv_hist_done_title': ['Đã chép xong', 'All done'],
  'dv_hist_done_sub': ['Tin nhắn cũ đã có trên thiết bị này.', 'Your older messages are on this device now.'],
  'dv_hist_start': ['Bắt đầu', 'Get started'],

  // ------------------------------------------------------- signed out
  'dv_out_title': ['Thiết bị này đã được đăng xuất khỏi tài khoản', 'This device was signed out of your account'],
  'dv_out_remote': [
    'Thiết bị này đã được đăng xuất từ thiết bị chính của bạn. Tin nhắn của tài khoản đã được xoá khỏi đây.',
    'It was signed out from your main device. The account’s messages have been removed from it.'
  ],
  'dv_out_wipe': ['Ảnh và tệp đã tải cũng đã được xoá.', 'Downloaded photos and files were removed too.'],
  'dv_out_self': [
    'Bạn đã đăng xuất Lumora trên thiết bị này. Tài khoản vẫn còn trên các thiết bị khác của bạn.',
    'You signed out of Lumora on this device. Your account is still on your other devices.'
  ],
  'dv_out_hint': ['Bạn có thể liên kết lại thiết bị này hoặc tạo tài khoản mới bất cứ lúc nào.', 'You can link this device again or create a new account any time.'],
  'dv_out_auto': [
    'Thiết bị chính của bạn đã đăng xuất máy này, hoặc một thiết bị khác vừa trở thành thiết bị chính của tài khoản.',
    'Your main device signed this one out, or another device just became your account’s main device.'
  ],
  'dv_out_kept': [
    'Tin nhắn và dữ liệu cũ trên máy này không bị xoá: Lumora cất riêng chúng khi bạn bắt đầu lại, để có thể mở lại sau.',
    'Your old messages and data on this device are not deleted: Lumora keeps them aside when you start over, so they can be opened again later.'
  ],
  'dv_out_continue': ['Bắt đầu lại', 'Start over'],

  // -------------------------------------------------- friends' devices
  'dv_contact_n': ['{n} thiết bị', '{n} devices'],
  'dv_contact_hint': ['Mỗi thiết bị có mã bảo mật riêng', 'Each device has its own security code'],
  'dv_security_code': ['Mã bảo mật', 'Security code'],
  'dv_contact_compare': [
    'So sánh mã này với mã hiện trên thiết bị đó để chắc chắn đúng là bạn ấy.',
    'Compare this code with the one shown on that device to be sure it’s really them.'
  ],

  // linked device, friend on an older Lumora (messages go via the main device)
  'dv_bridged_hint': ['Gửi qua thiết bị chính của bạn', 'Sent through your main device'],
  'dv_bridged_more': [
    '{name} đang dùng phiên bản Lumora cũ, nên tin nhắn từ thiết bị này đi qua thiết bị chính của bạn. Tin vẫn được mã hoá.',
    '{name} uses an older version of Lumora, so messages from this device go through your main device. They stay encrypted.'
  ],

  // ------------------------------------------------------ calls, remote
  'dv_answered_on': ['Đã trả lời trên {device}', 'Answered on {device}'],
  'dv_answered_elsewhere': ['Đã trả lời trên thiết bị khác', 'Answered on another device'],
  'dv_pick_title': ['Chọn thiết bị để điều khiển', 'Choose a device to control'],
  'dv_pick_sub': ['Tài khoản này dùng Lumora trên nhiều máy.', 'This account uses Lumora on several devices.'],
  'dv_my_ids': ['Các thiết bị khác của bạn', 'Your other devices'],
};
