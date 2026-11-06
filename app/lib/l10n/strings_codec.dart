// Copy for video codecs: the in-call notes, the call-quality tooltip and
// Settings › Nâng cao › Mã hoá video. Spread into kStrings. key: [Tiếng Việt, English]

const Map<String, List<String>> kCodecStrings = {
  'vc_title': ['Mã hoá video', 'Video encoding'],
  'vc_hw': ['phần cứng', 'hardware'],
  'vc_sw': ['phần mềm', 'software'],
  // "Video: H.264 · phần cứng" / "Video: VP8 · phần mềm"
  'vc_line': ['Video: {codec} · {kind}', 'Video: {codec} · {kind}'],
  'vc_this_device': ['Thiết bị này', 'This device'],
  'vc_caps_hw': ['H.264 bằng phần cứng của máy, kèm VP8/VP9', 'H.264 on this device\'s hardware, plus VP8/VP9'],
  'vc_caps_os': ['H.264 của hệ điều hành, kèm VP8/VP9', 'H.264 from the operating system, plus VP8/VP9'],
  'vc_caps_vpx': ['VP8/VP9 (có sẵn trong Lumora)', 'VP8/VP9 (built into Lumora)'],
  'vc_checking': ['Đang kiểm tra…', 'Checking…'],
  'vc_last_call': ['Cuộc gọi gần nhất', 'Last call'],
  'vc_send': ['Gửi', 'Sending'],
  'vc_receive': ['Nhận', 'Receiving'],
  'vc_hint': [
    'Lumora tự chọn: dùng phần cứng của máy khi cả hai bên đều có, nếu không thì dùng VP8/VP9 có sẵn. Không cần tải thêm gì.',
    'Lumora chooses for you: the device\'s hardware when both sides have it, otherwise the built-in VP8/VP9. Nothing to download.',
  ],
  // in-call note: the other person runs an older Lumora that only takes H.264
  'vc_peer_update': [
    'Không gửi được hình cho người này: họ cần cập nhật Lumora. Cuộc gọi vẫn có tiếng.',
    'Can\'t send video to this person: they need to update Lumora. The call keeps its sound.',
  ],
};
