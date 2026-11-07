// Copy for the password / PIN / recovery-phrase screens
// (lib/ui/widgets/secure_input.dart and the screens that use it).
// Kept in its own file and spread into kStrings. key: [Tiếng Việt, English]

const Map<String, List<String>> kSecureStrings = {
  // ------------------------------------------------------- password field
  'sec_show': ['Hiện mật khẩu', 'Show password'],
  'sec_hide': ['Ẩn mật khẩu', 'Hide password'],
  'sec_caps': ['Caps Lock đang bật', 'Caps Lock is on'],
  'sec_strength_0': ['Dễ đoán', 'Easy to guess'],
  'sec_strength_1': ['Còn yếu', 'Weak'],
  'sec_strength_2': ['Tạm ổn', 'Okay'],
  'sec_strength_3': ['Khá mạnh', 'Strong'],
  'sec_strength_4': ['Rất mạnh', 'Very strong'],
  'sec_strength_label': ['Độ mạnh mật khẩu: {v}', 'Password strength: {v}'],
  'sec_hint_min': ['Cần ít nhất {n} ký tự', 'Use at least {n} characters'],
  'sec_hint_longer': ['Thêm vài chữ nữa cho mạnh hơn', 'Add a few more letters to make it stronger'],
  'sec_hint_common': ['Nhiều người dùng mật khẩu này — hãy chọn cái riêng của bạn', 'Lots of people use this one — pick something of your own'],
  'sec_hint_sequence': ['Tránh dãy dễ đoán như 1234 hay abcd', 'Avoid easy runs like 1234 or abcd'],
  'sec_hint_repeat': ['Tránh lặp lại một ký tự nhiều lần', 'Avoid repeating the same character'],
  'sec_hint_year': ['Tránh dùng năm sinh hay ngày tháng', 'Avoid birth years and dates'],
  'sec_hint_words': ['Thử ghép vài từ không liên quan, như “mây tím ăn phở”', 'Try a few unrelated words, like “purple cloud eats soup”'],
  'sec_hint_great': ['Tuyệt — rất khó đoán', 'Great — very hard to guess'],
  'sec_match': ['Hai lần nhập đã khớp', 'Both entries match'],
  'sec_no_match': ['Hai lần nhập chưa khớp', 'The entries don’t match yet'],

  // ------------------------------------------------------------------ PIN
  'sec_pin_keyboard': ['Bạn cũng có thể gõ bằng bàn phím', 'You can also type on your keyboard'],
  'sec_pin_step': ['Bước {n}/2', 'Step {n} of 2'],
  'sec_pin_confirm': ['Xác nhận mã PIN', 'Confirm PIN'],
  'sec_pin_forgot_sub': ['Nhập cụm từ khôi phục để gỡ mã PIN. Tin nhắn vẫn còn nguyên.', 'Enter your recovery phrase to remove the PIN. Your messages stay as they are.'],
  'sec_locked_chat_sub': ['Cuộc trò chuyện này đang khoá. Nhập mã PIN để xem.', 'This chat is locked. Enter your PIN to see it.'],

  // -------------------------------------------------------- recovery phrase
  'sec_phrase_word': ['Từ số {n}', 'Word {n}'],
  'sec_phrase_paste': ['Dán', 'Paste'],
  'sec_phrase_clear': ['Xoá hết', 'Clear'],
  'sec_phrase_count': ['{n}/{t} từ', '{n}/{t} words'],
  'sec_phrase_unknown': ['Từ số {n} không có trong danh sách — kiểm tra chính tả nhé', 'Word {n} isn’t on the word list — check the spelling'],
  'sec_phrase_checksum': ['Có một từ bị ghi sai. Hãy kiểm tra lại từng từ.', 'One of the words is wrong. Please check each word.'],
  'sec_phrase_valid': ['Đủ 24 từ và đúng cụm từ', 'All 24 words in and the phrase checks out'],
  'sec_phrase_help': ['Gõ 2–3 chữ cái đầu rồi chọn từ gợi ý (Tab hoặc Enter). Có thể dán cả cụm.', 'Type the first 2–3 letters and pick a suggestion (Tab or Enter). You can paste the whole phrase.'],
  'sec_phrase_suggestions': ['Gợi ý cho từ số {n}', 'Suggestions for word {n}'],
  'sec_phrase_have_legacy': ['Có mã dạng cũ?', 'Have an older-style code?'],
  'sec_phrase_legacy': ['Mã dạng cũ', 'Older-style code'],
  'sec_phrase_legacy_note': ['Mã khôi phục từ phiên bản trước (các nhóm chữ và số, như “abcde-fgh2j-…”) vẫn dùng được cho đúng tài khoản đó.', 'A recovery code from an earlier version (groups of letters and digits, like “abcde-fgh2j-…”) still works for the same account.'],
  'sec_phrase_legacy_hint': ['Dán hoặc gõ nguyên mã', 'Paste or type the whole code'],
  'sec_phrase_legacy_ready': ['Mã đủ độ dài — sẽ được kiểm tra khi bạn tiếp tục', 'The code is complete — it’s checked when you continue'],
  'sec_phrase_legacy_count': ['{n}/56 ký tự', '{n}/56 characters'],
  'sec_phrase_use_words': ['Nhập 24 từ', 'Enter 24 words'],

  // ------------------------------------------- show & check the phrase
  'phrase_warning': ['Ai có các từ này sẽ vào được tài khoản của bạn. Hãy chép tay ra giấy, đừng chụp màn hình hay gửi cho ai.', 'Anyone with these words can get into your account. Write them on paper — don’t screenshot or send them to anyone.'],
  'phrase_copied': ['Đã sao chép cụm từ. Hãy dán vào nơi an toàn rồi xoá khỏi bộ nhớ tạm.', 'Phrase copied. Paste it somewhere safe, then clear your clipboard.'],
  'phrase_wrote_it': ['Tôi đã ghi lại', 'I’ve written it down'],
  'phrase_check_title': ['Kiểm tra lại', 'Check your copy'],
  'phrase_check_sub': ['Nhập 3 từ theo đúng số thứ tự trong cụm từ bạn vừa ghi.', 'Enter these 3 words from the phrase you just wrote down.'],
  'phrase_check_step': ['Bước {n}/2', 'Step {n} of 2'],
  'phrase_check_go': ['Kiểm tra', 'Check'],
  'phrase_check_wrong': ['Từ số {n} chưa khớp. Xem lại cụm từ rồi thử lại.', 'Word {n} doesn’t match. Look at the phrase again and retry.'],
  'phrase_check_ok': ['Chính xác! Cụm từ của bạn đã được ghi đúng.', 'Correct! Your copy of the phrase is right.'],
  'phrase_show_again': ['Xem lại cụm từ', 'Show the phrase again'],
  'phrase_later': ['Để sau', 'Later'],
  'phrase_done': ['Xong', 'Done'],

  // ------------------------------------------------------- startup lock
  'sec_locked_sub': ['Nhập mật khẩu để mở dữ liệu trên thiết bị này.', 'Enter your password to open your data on this device.'],
  'sec_password_hint': ['Mật khẩu của bạn', 'Your password'],

  // ------------------------------------------------- forgot data password
  'sec_fp_sub': ['Không ai đặt lại được mật khẩu này, kể cả Lumora. Bạn vẫn có cách vào lại:', 'Nobody can reset this password, not even Lumora. You can still get back in:'],
  'sec_fp_phrase': ['Cụm từ khôi phục', 'Recovery phrase'],
  'sec_fp_phrase_sub': ['Nhập các từ bạn đã ghi lại khi tạo tài khoản', 'Enter the words you wrote down when you signed up'],
  'sec_fp_file': ['Tệp sao lưu', 'Backup file'],
  'sec_fp_file_sub': ['Chọn tệp sao lưu và nhập mật khẩu của tệp', 'Pick your backup file and enter its password'],
  'sec_fp_retry': ['Thử lại', 'Try again'],
  'sec_fp_retry_sub': ['Có thể bạn sẽ nhớ ra — quay lại và nhập lần nữa', 'It may come back to you — go back and try once more'],
  'sec_fp_more': ['Tin nhắn cũ trên thiết bị này thì sao?', 'What happens to messages on this device?'],
  'sec_fp_phrase_title': ['Nhập cụm từ khôi phục', 'Enter your recovery phrase'],
  'sec_fp_phrase_head': ['Gõ 24 từ theo đúng thứ tự, hoặc dán cả cụm.', 'Type the 24 words in order, or paste the whole phrase.'],
  'sec_fp_file_title': ['Khôi phục từ tệp', 'Restore from a file'],

  // ------------------------------------------------- passphrase dialog
  'sec_pp_sub': ['Bạn sẽ nhập mật khẩu này mỗi lần mở Lumora trên thiết bị này.', 'You’ll enter it each time Lumora opens on this device.'],
  'sec_pp_note': ['Nếu quên, chỉ cụm từ khôi phục hoặc tệp sao lưu giúp bạn vào lại.', 'If you forget it, only your recovery phrase or a backup file can get you back in.'],
  'sec_pp_save': ['Lưu mật khẩu', 'Save passphrase'],

  // ------------------------------------------------------------- backup
  'sec_bk_sub': ['Một tệp được khoá bằng mật khẩu, dùng khi chuyển sang thiết bị mới.', 'A password-locked file for moving to a new device.'],

  // ------------------------------------------------------------ restore
  'sec_restore_sub': ['Chọn cách bạn đã cất giữ tài khoản.', 'Choose how you saved your account.'],
};
