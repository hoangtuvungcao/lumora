// Copy for recovery from friends after a restore with the recovery phrase
// (review list, banner, and Settings › Privacy "Help friends restore their
// history"). Spread into kStrings. key: [Tiếng Việt, English]

const Map<String, List<String>> kRecoveryStrings = {
  'rc_banner': ['Bạn bè muốn giúp bạn khôi phục lịch sử ({n})', 'Friends offer to restore your history ({n})'],
  'rc_banner_hint': ['Xem và chọn nhận lại từ ai', 'Review and choose whose to accept'],
  'rc_title': ['Khôi phục từ bạn bè', 'Restore from friends'],
  'rc_hint': [
    'Bạn vừa khôi phục tài khoản bằng cụm từ khôi phục. Bạn bè có thể gửi lại cuộc trò chuyện riêng với bạn trong 6 tháng gần đây và đưa bạn trở lại các nhóm chung. Tin nhắn đã xoá hoặc tự huỷ không bao giờ được gửi lại.',
    'You just restored your account with your recovery phrase. Friends can send back their own chat with you from the last 6 months and bring you back into the groups you share. Deleted or disappearing messages are never sent back.',
  ],
  'rc_detail': ['{n} tin nhắn · {g} nhóm chung', '{n} messages · {g} shared groups'],
  'rc_detail_one': ['{n} tin nhắn · {g} nhóm chung', '{n} message · {g} shared groups'],
  'rc_verified': ['Đã xác minh', 'Verified'],
  'rc_verified_hint': [
    'Người này giữ một tin nhắn do chính tài khoản của bạn ký trong cuộc trò chuyện của hai bạn.',
    'This person holds a message your own account signed in your chat together.',
  ],
  'rc_unverified': ['Chưa xác minh', 'Unverified'],
  'rc_unverified_hint': [
    'Người này không chứng minh được hai bạn từng trò chuyện. Nhận lại chỉ đưa về tin nhắn có nhãn "chưa xác minh" — họ không thành bạn bè và không đưa bạn vào nhóm nào. Hãy kết bạn lại nếu bạn biết họ.',
    'This person could not prove you ever chatted. Accepting only brings back messages marked "unverified" — they do not become your friend and cannot add you to any group. Add them again if you know them.',
  ],
  'rc_accept': ['Nhận lại', 'Accept'],
  'rc_decline': ['Từ chối', 'Decline'],
  'rc_receiving': ['Đang nhận… {n} tin nhắn', 'Receiving… {n} messages'],
  'rc_done': ['Đã khôi phục {n} tin nhắn', 'Restored {n} messages'],
  'rc_declined': ['Đã từ chối', 'Declined'],
  'rc_empty': [
    'Chưa có đề nghị nào. Khi bạn bè kết nối lại với bạn, đề nghị của họ sẽ hiện ở đây.',
    'No offers yet. When your friends connect with you again, their offers show up here.',
  ],
  'rc_dismiss': ['Không hỏi bạn bè nữa', 'Stop asking friends'],
  'rc_accepted_toast': ['Đang nhận lịch sử từ {name}', 'Receiving history from {name}'],
  'help_restore': ['Giúp bạn bè khôi phục lịch sử', 'Help friends restore their history'],
  'help_restore_hint': [
    'Khi một người bạn khôi phục tài khoản bằng cụm từ khôi phục, thiết bị của bạn gửi lại cuộc trò chuyện riêng của hai bạn trong 6 tháng gần đây (mã hoá đầu cuối) và đưa họ trở lại các nhóm chung. Tin nhắn đã xoá hoặc tự huỷ không bao giờ được gửi. Áp dụng trên mọi thiết bị của bạn.',
    'When a friend restores their account with their recovery phrase, your device sends back your own chat with them from the last 6 months (end-to-end encrypted) and brings them back into the groups you share. Deleted or disappearing messages are never sent. Applies on all your devices.',
  ],
  'rc_restored_from': ['Khôi phục từ {name}', 'Restored from {name}'],
  'rc_restored_unverified': ['Khôi phục từ {name} · chưa xác minh', 'Restored from {name} · unverified'],
  'sys.group_restored': ['Đã khôi phục nhóm', 'Group restored'],
};
