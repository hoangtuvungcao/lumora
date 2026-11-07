"""Text of the /privacy/ and /terms/ pages: (Vietnamese, English) pairs.

Used by build_pages.py, which writes the Vietnamese into the HTML and the English into
landing/assets/js/legal.js. Keep the language plain and only promise what the app really
does. The privacy page names the public services the app talks to (Nostr, STUN, DHT, UPnP,
OpenStreetMap) on purpose: transparency beats the "no jargon" rule there (check_dist.py
allows those words on /privacy/ only).

Paragraphs are (vi, en) tuples; {"li": [(vi, en), ...]} renders a bullet list; [text](url)
renders a link (https only).
"""

COMMON = {
    "lg.badge": ("Minh bạch, dễ hiểu", "Clear and simple"),
    "lg.updated": ("Cập nhật lần cuối: 6 tháng 11 năm 2026", "Last updated: 6 November 2026"),
}

PRIVACY = {
    "prefix": "pv",
    "icon": "shield",
    "title": ("Chính sách quyền riêng tư", "Privacy policy"),
    "lead": (
        "Nói ngắn gọn: chúng tôi không thu thập dữ liệu của bạn. Trang này giải thích rõ điều đó nghĩa là gì.",
        "In short: we don't collect your data. This page explains exactly what that means.",
    ),
    "desc": (
        "Lumora không cần tài khoản, không thu thập dữ liệu. Tin nhắn được mã hoá đầu cuối và lưu trên thiết bị của bạn.",
        "Lumora needs no account and collects no data. Messages are end-to-end encrypted and stored on your device.",
    ),
    "summary": [
        ("Không cần tài khoản, số điện thoại hay email.", "No account, phone number or email needed."),
        ("Chỉ bạn và người nhận đọc được tin nhắn.", "Only you and the recipient can read your messages."),
        ("Lịch sử trò chuyện nằm trên thiết bị của bạn, được mã hoá.", "Your chat history stays on your device, encrypted."),
        ("Người lạ không thấy được địa chỉ IP của bạn.", "Strangers can't see your IP address."),
        ("Không quảng cáo, không theo dõi, không bán dữ liệu.", "No ads, no tracking, no selling of data."),
    ],
    "sections": [
        {"id": "account", "t": ("Không có tài khoản", "No accounts"), "p": [
            ("Lumora không có hệ thống tài khoản. Bạn không cần số điện thoại, email hay mật khẩu để dùng, nên chúng tôi không biết bạn là ai và không giữ hồ sơ nào về bạn.",
             "Lumora has no account system. You don't need a phone number, email or password to use it, so we don't know who you are and keep no records about you."),
        ]},
        {"id": "messages", "t": ("Tin nhắn, cuộc gọi và tệp", "Messages, calls and files"), "p": [
            ("Tin nhắn, cuộc gọi và tệp được mã hoá đầu cuối ngay trên thiết bị của bạn trước khi gửi đi. Chỉ thiết bị của người nhận mở ra được. Chúng tôi không đọc, không lưu và không có cách nào xem nội dung.",
             "Messages, calls and files are end-to-end encrypted on your device before they're sent. Only the recipient's device can open them. We don't read them, don't store them and have no way to see their content."),
            ("Những gì bạn gửi đi sẽ nằm trên thiết bị của người nhận. Tính năng \"xoá cho mọi người\" sẽ xoá tin nhắn trên thiết bị của họ, nhưng không thể ngăn việc ai đó đã chụp màn hình hay lưu lại trước đó.",
             "What you send ends up on the recipient's device. \"Delete for everyone\" removes it from their device, but it can't undo a screenshot or a copy they made before."),
        ]},
        {"id": "device", "t": ("Dữ liệu nằm trên thiết bị của bạn", "Your data stays on your device"), "p": [
            ("Lịch sử trò chuyện và danh sách bạn bè được lưu trên chính thiết bị của bạn, trong một cơ sở dữ liệu được mã hoá. Không có máy chủ trung tâm hay \"đám mây\" nào giữ tin nhắn của bạn, nên chúng tôi cũng không có bản sao để khôi phục hộ bạn.",
             "Your chat history and friends list are stored on your own device, in an encrypted database. No central server or \"cloud\" keeps your messages, so we have no copy to restore for you either."),
            ("Ảnh, video và tệp bạn nhận được lưu thành tệp bình thường (không mã hoá) để bạn mở bằng ứng dụng khác. Trên máy tính, chúng nằm trong thư mục Tải xuống/Lumora (Downloads/Lumora) và vẫn còn đó khi bạn gỡ ứng dụng, nên hãy tự xoá nếu không cần nữa. Trên Android, chúng nằm trong thư mục riêng của Lumora và bị xoá cùng ứng dụng, nên hãy lưu ra ngoài những tệp bạn muốn giữ.",
             "Photos, videos and files you receive are saved as normal (unencrypted) files so you can open them with other apps. On computers they go to the Downloads/Lumora folder and stay there when you uninstall the app, so delete them yourself if you no longer need them. On Android they are kept in Lumora's own folder and are deleted with the app, so save the files you want to keep somewhere else."),
            ("Vì vậy, hãy chép lại cụm từ khôi phục và tạo tệp sao lưu có mật khẩu trong phần Cài đặt, rồi cất ở nơi an toàn.",
             "That's why you should write down your recovery phrase, create a password-protected backup file in Settings, and keep both somewhere safe."),
        ]},
        {"id": "direct", "t": ("Ai có thể thấy địa chỉ IP của bạn", "Who can see your IP address"), "p": [
            ("Tin nhắn và cuộc gọi đi thẳng giữa các thiết bị, nên những người bạn kết nối trực tiếp có thể thấy địa chỉ IP của bạn, giống như cuộc gọi trực tiếp trong các ứng dụng khác. Từ địa chỉ này chỉ đoán được khu vực gần đúng (tỉnh/thành phố, nhà mạng), không ra số nhà hay danh tính của bạn. Những người có thể thấy là:",
             "Messages and calls go straight between devices, so the people you connect with directly can see your IP address, as with direct calls in other apps. The address only reveals an approximate area (city, internet provider), not your street address or identity. The people who can see it are:"),
            {"li": [
                ("bạn bè của bạn và các thiết bị của chính bạn;", "your friends and your own devices;"),
                ("thành viên các nhóm riêng tư bạn đang tham gia; trong nhóm công khai, chỉ trưởng nhóm và quản trị viên;", "members of private groups you are in; in public groups, only the group owner and admins;"),
                ("bot bạn dùng;", "bots you use;"),
                ("người mà chính bạn tìm đến trước, ví dụ khi bạn gửi lời mời kết bạn;", "people you contact first yourself, for example when you send a friend request;"),
                ("người xem hoặc điều khiển máy của bạn từ xa, sau khi bạn đồng ý (hoặc khi bạn đã bật truy cập bằng mật khẩu hay \"Luôn cho phép thiết bị này\").",
                 "someone viewing or controlling your computer remotely, after you accept (or when you have turned on password access or \"Always allow this device\")."),
            ]},
            ("Người lạ không lấy được địa chỉ IP của bạn qua Lumora. Lời mời kết bạn của họ vẫn đến được với bạn, nhưng theo đường gián tiếp và được mã hoá (qua các máy chủ Nostr công cộng nói ở mục dưới). Thiết bị của bạn không cho họ biết địa chỉ và không gửi gì cho họ cho đến khi bạn đồng ý.",
             "Strangers can't get your IP address from Lumora. Their friend requests still reach you, but indirectly and encrypted (through the public Nostr relays described below). Your device doesn't tell them your address and sends them nothing until you accept."),
            ("Thông tin công khai giúp người khác tìm thấy bạn không chứa địa chỉ IP. Địa chỉ để kết nối với bạn được mã hoá riêng, và chỉ bạn bè của bạn mở ra được.",
             "The public information that lets people find you contains no IP address. The address used to reach you is encrypted separately, and only your friends can open it."),
            ("Trong cùng mạng Wi-Fi hay mạng nội bộ, các thiết bị khác thấy có một thiết bị Lumora và địa chỉ của nó trong mạng đó, nhưng không biết đó là bạn: dấu hiệu nhận ra thiết bị đổi mỗi ngày, và chỉ người đã quen bạn mới nhận ra. Bạn có thể tắt \"Tìm bạn bè trong cùng mạng Wi-Fi\" ở Cài đặt › Quyền riêng tư.",
             "On the same Wi-Fi or local network, other devices can see that a Lumora device is there and its address on that network, but not that it is you: its identifying sign changes every day, and only people who already know you recognise it. You can turn off \"Find friends on the same Wi-Fi\" in Settings › Privacy."),
            ("Lumora không chia sẻ loại địa chỉ được tạo từ phần cứng của thiết bị (loại có thể dùng để nhận ra thiết bị về lâu dài), và ưu tiên dùng địa chỉ tạm thời.",
             "Lumora never shares the kind of address that is built from your device's hardware (which could identify the device over time), and prefers temporary addresses."),
        ]},
        {"id": "services", "t": ("Dịch vụ công cộng mà ứng dụng dùng", "Public services the app uses"), "p": [
            ("Lumora không có máy chủ riêng để chuyển hay lưu tin nhắn. Để các thiết bị tìm thấy nhau và kết nối thẳng, ứng dụng dùng một số dịch vụ công cộng do bên thứ ba vận hành. Các dịch vụ này có thể thấy địa chỉ IP của bạn và thời điểm kết nối, nhưng không bao giờ thấy nội dung tin nhắn, cuộc gọi hay tệp:",
             "Lumora has no server of its own that carries or stores messages. To let devices find each other and connect directly, the app uses some public services run by third parties. These services may see your IP address and when you connect, but never the content of your messages, calls or files:"),
            {"li": [
                ("Máy chủ Nostr công cộng: giúp các thiết bị tìm thấy nhau bằng ID 9 số hoặc @tên, và chuyển các tín hiệu kết nối, lời mời kết bạn đã được mã hoá. Tắt được bằng \"Danh sách công khai\".",
                 "Public Nostr relays: help devices find each other by 9-digit ID or @username, and pass along encrypted connection signals and friend requests. Can be turned off with \"Public directory\"."),
                ("Máy chủ STUN của Google, Cloudflare và Nextcloud: cho thiết bị biết địa chỉ công cộng của chính nó để kết nối thẳng. Luôn được dùng.",
                 "STUN servers run by Google, Cloudflare and Nextcloud: tell your device its own public address so it can connect directly. Always used."),
                ("Mạng BitTorrent DHT: giúp bạn bè tìm lại bạn khi Internet không ổn định; thông tin để kết nối được mã hoá và chỉ bạn bè mở được. Tắt được bằng \"Tìm bạn qua các thiết bị khác\".",
                 "The BitTorrent DHT: helps friends find you again when the Internet is unreliable; the information used to reach you is encrypted and only friends can open it. Can be turned off with \"Find friends via other devices\"."),
                ("Modem Wi-Fi (router) nhà bạn, qua UPnP: được nhờ mở đường để bạn bè kết nối thẳng. Việc này chỉ diễn ra trong mạng nhà bạn. Tắt được bằng \"Tự mở đường qua modem Wi-Fi\".",
                 "Your Wi-Fi router, via UPnP: asked to open a path so friends can connect directly. This only happens inside your home network. Can be turned off with \"Open a path via the Wi-Fi router\"."),
                ("Bản đồ OpenStreetMap: chỉ khi bạn mở bản đồ của một vị trí được chia sẻ, ứng dụng tải ảnh bản đồ từ OpenStreetMap; máy chủ bản đồ thấy địa chỉ IP của bạn và khu vực bạn đang xem.",
                 "OpenStreetMap: only when you open the map of a shared location, the app loads map images from OpenStreetMap; the map server sees your IP address and the area you are viewing."),
            ]},
            ("Ba tuỳ chọn \"Danh sách công khai\", \"Tìm bạn qua các thiết bị khác\" và \"Tự mở đường qua modem Wi-Fi\" nằm ở Cài đặt › Nâng cao › Mạng. Tắt chúng có thể làm việc tìm nhau và kết nối chậm hơn hoặc khó hơn.",
             "The three options \"Public directory\", \"Find friends via other devices\" and \"Open a path via the Wi-Fi router\" are in Settings › Advanced › Network. Turning them off can make finding each other and connecting slower or harder."),
        ]},
        {"id": "friends-help", "t": ("Bạn bè giúp nhau kết nối", "Friends help each other connect"), "p": [
            ("Khi hai người bạn của bạn không kết nối thẳng được với nhau (ví dụ do mạng công ty hay nhà mạng chặn), thiết bị của bạn có thể chuyển tiếp dữ liệu giữa họ, và bạn bè cũng có thể giúp bạn như vậy. Việc này bật sẵn, chỉ diễn ra giữa những người là bạn bè của nhau, giới hạn khoảng 1 MB/giây cho mỗi người và tối đa 16 người bạn. Nội dung vẫn được mã hoá đầu cuối: người chuyển tiếp không đọc được gì. Bạn có thể tắt \"Giúp bạn bè kết nối\" ở Cài đặt › Quyền riêng tư.",
             "When two of your friends can't connect to each other directly (for example because a company or mobile network blocks it), your device may pass data between them, and your friends may do the same for you. This is on by default, only happens between people who are friends, and is limited to about 1 MB/s per friend and at most 16 friends. The content stays end-to-end encrypted: the friend passing it along can't read any of it. You can turn off \"Help friends connect\" in Settings › Privacy."),
            ("Khi người nhận đang ngoại tuyến, bạn bè chung có thể giữ hộ tin nhắn đã khoá cho đến khi họ trực tuyến. Bạn có thể tắt \"Gửi qua bạn bè khi ngoại tuyến\" ở Cài đặt › Quyền riêng tư.",
             "When the recipient is offline, mutual friends may hold your locked messages until they come online. You can turn off \"Deliver via friends when offline\" in Settings › Privacy."),
        ]},
        {"id": "public", "t": ("Những gì là công khai", "What is public"), "p": [
            ("Nếu bạn chọn đặt @tên người dùng, hoặc tạo nhóm công khai, thì @tên đó cùng tên hiển thị (với nhóm là tên và mô tả nhóm) sẽ có trong danh sách công khai để người khác tìm thấy bạn. Việc này hoàn toàn tuỳ chọn, và bạn có thể bỏ @tên bất cứ lúc nào.",
             "If you choose to set an @username, or create a public group, that @username and your display name (for a group: its name and description) appear in a public directory so others can find you. This is entirely optional, and you can remove your @username at any time."),
            ("ID 9 số của bạn cũng có trong danh sách công khai để người khác tìm và gửi lời mời kết bạn. Nếu không muốn, hãy tắt \"Cho người lạ tìm thấy tôi bằng ID\" trong Cài đặt › Quyền riêng tư: bạn bè vẫn liên lạc được, còn người khác cần mã QR hoặc đường dẫn của bạn (hoặc @tên, nếu bạn đã đặt).",
             "Your 9-digit ID is also listed in the public directory so others can find you and send a friend request. If you'd rather not, turn off \"Let strangers find me by ID\" in Settings › Privacy: friends still reach you, and others need your QR code or link (or your @username, if you set one)."),
            ("Tin nhắn trong nhóm công khai được mã hoá như mọi tin nhắn khác, nhưng ai tham gia nhóm cũng đọc được.",
             "Messages in a public group are encrypted like any other message, but everyone who joins the group can read them."),
        ]},
        {"id": "remote", "t": ("Hỗ trợ từ xa", "Remote help"), "p": [
            ("Người khác chỉ xem hoặc điều khiển được máy của bạn sau khi bạn bấm đồng ý, và bạn có thể dừng bất cứ lúc nào bằng một nút. Ngoại lệ duy nhất là khi chính bạn đã bật \"Truy cập không giám sát\" với mật khẩu, hoặc chọn \"Luôn cho phép thiết bị này\"; chỉ nên dùng hai tuỳ chọn này cho thiết bị của chính bạn. Phiên hỗ trợ được mã hoá như tin nhắn; chúng tôi không xem được.",
             "Someone can only see or control your computer after you accept, and you can stop at any time with one button. The only exception is when you yourself have turned on \"Unattended access\" with a password, or chosen \"Always allow this device\"; only use these two options for your own devices. Remote help sessions are encrypted like your messages; we can't see them."),
        ]},
        {"id": "bots", "t": ("Bot", "Bots"), "p": [
            ("Bot do người khác tạo và chạy trên máy của họ. Những gì bạn gửi cho một bot sẽ đến người vận hành bot đó, nên hãy cân nhắc trước khi gửi thông tin cá nhân.",
             "Bots are made by other people and run on their computers. Whatever you send to a bot reaches the person who runs it, so think twice before sharing personal information."),
        ]},
        {"id": "website", "t": ("Trang web này", "This website"), "p": [
            ("Trang web không dùng cookie, không có công cụ theo dõi hay quảng cáo. Trang chỉ ghi nhớ vài lựa chọn ngay trong trình duyệt của bạn: ngôn ngữ, giao diện sáng/tối, và trên các trang Nhà phát triển là ngôn ngữ lập trình bạn chọn cho ví dụ (lumora-lang, lumora-theme, lumora-dev-tab). Bạn có thể xoá chúng bất cứ lúc nào bằng cách xoá dữ liệu trang web trong trình duyệt.",
             "This website uses no cookies, trackers or ads. It only remembers a few choices inside your own browser: your language, light/dark theme, and on the Developers pages the programming language you picked for examples (lumora-lang, lumora-theme, lumora-dev-tab). You can remove them at any time by clearing the site's data in your browser."),
            ("Như mọi trang web, nhà cung cấp dịch vụ lưu trữ trang có thể ghi lại thông tin kỹ thuật cơ bản của lượt truy cập (ví dụ địa chỉ IP) để vận hành và chống tấn công. Tệp cài đặt được tải trực tiếp từ trang phát hành chính thức trên GitHub, nên GitHub cũng thấy địa chỉ IP của bạn khi bạn tải về. Chúng tôi không dùng thông tin đó để theo dõi bạn.",
             "Like any website, our hosting provider may log basic technical details of each visit (such as the IP address) to run the site and block attacks. Installers are downloaded directly from the official release page on GitHub, so GitHub also sees your IP address when you download. We don't use that information to track you."),
        ]},
        {"id": "changes", "t": ("Thay đổi và liên hệ", "Changes and contact"), "p": [
            ("Nếu chính sách này thay đổi, chúng tôi sẽ cập nhật trang này và ghi rõ ngày cập nhật ở đầu trang.",
             "If this policy changes, we'll update this page and show the date of the change at the top."),
            ("Câu hỏi và góp ý: hãy gửi qua mục Issues trên [trang phát hành chính thức trên GitHub](https://github.com/hoangtuvungcao/get_lumora/issues).",
             "Questions and feedback: please use Issues on the [official release page on GitHub](https://github.com/hoangtuvungcao/get_lumora/issues)."),
        ]},
    ],
}

TERMS = {
    "prefix": "tm",
    "icon": "book-open",
    "title": ("Điều khoản sử dụng", "Terms of use"),
    "lead": (
        "Những điều cần biết khi dùng Lumora, viết ngắn gọn và dễ hiểu.",
        "What you should know when using Lumora, kept short and simple.",
    ),
    "desc": (
        "Điều khoản sử dụng Lumora: dùng đúng mục đích, tôn trọng người khác và tự giữ bản sao lưu của mình.",
        "Lumora terms of use: use it lawfully, respect others and keep your own backup.",
    ),
    "summary": [
        ("Lumora miễn phí cho mọi người; bộ công cụ tạo bot dùng giấy phép MIT.", "Lumora is free for everyone; the bot SDK is MIT-licensed."),
        ("Dùng đúng pháp luật và tôn trọng người khác.", "Use it lawfully and respect others."),
        ("Chỉ hỗ trợ từ xa khi người kia đồng ý.", "Only use remote help with the other person's consent."),
        ("Bạn tự giữ cụm từ khôi phục và bản sao lưu.", "You keep your own recovery phrase and backup."),
    ],
    "sections": [
        {"id": "accept", "t": ("Đồng ý với điều khoản", "Agreeing to these terms"), "p": [
            ("Khi tải về và sử dụng Lumora, bạn đồng ý với các điều khoản dưới đây. Nếu không đồng ý, vui lòng không sử dụng ứng dụng.",
             "By downloading and using Lumora you agree to the terms below. If you don't agree, please don't use the app."),
        ]},
        {"id": "free", "t": ("Miễn phí", "Free of charge"), "p": [
            ("Lumora miễn phí, không quảng cáo và không có gói trả phí. Bạn không phải nhập thẻ hay thông tin thanh toán nào.",
             "Lumora is free, with no ads and no paid plans. You never have to enter a card or any payment details."),
        ]},
        {"id": "license", "t": ("Giấy phép", "License"), "p": [
            ("Ứng dụng Lumora là phần mềm miễn phí nhưng không phải mã nguồn mở. Việc sử dụng ứng dụng tuân theo Giấy phép sử dụng phần mềm (EULA), là tệp LICENSE.md đi kèm mỗi bản phát hành trên [trang phát hành chính thức trên GitHub](https://github.com/hoangtuvungcao/get_lumora/releases). Trang này tóm tắt những điểm chính; nếu có điểm nào khác nhau, EULA được áp dụng.",
             "The Lumora app is free software, but it is not open source. Using the app is governed by the End-User License Agreement (EULA), the LICENSE.md file published with every release on the [official release page on GitHub](https://github.com/hoangtuvungcao/get_lumora/releases). This page summarises the main points; where they differ, the EULA applies."),
            ("Bộ công cụ tạo bot (SDK) trên trang Nhà phát triển dùng giấy phép MIT: bạn được tự do dùng, sửa và phân phối lại nó, kể cả cho mục đích thương mại.",
             "The bot SDK on the Developers pages is released under the MIT license: you may use, modify and redistribute it freely, including commercially."),
            ("Chỉ tải Lumora từ trang web này hoặc trang phát hành chính thức trên GitHub (get_lumora). Bản do nơi khác cung cấp có thể đã bị sửa đổi.",
             "Only download Lumora from this website or the official release page on GitHub (get_lumora). Copies from anywhere else may have been tampered with."),
        ]},
        {"id": "use", "t": ("Sử dụng đúng mục đích", "Acceptable use"), "p": [
            ("Không dùng Lumora để làm điều trái pháp luật, quấy rối, đe doạ, lừa đảo, gửi tin rác, phát tán phần mềm độc hại hoặc nội dung xâm hại trẻ em. Hãy tuân thủ pháp luật nơi bạn sống.",
             "Don't use Lumora to break the law, harass, threaten, scam, send spam, spread malware or share content that harms children. Follow the laws where you live."),
            ("Không đặt @tên hoặc tên nhóm để giả mạo người hay tổ chức khác, hoặc gây hiểu lầm.",
             "Don't pick an @username or group name that impersonates another person or organisation, or that misleads people."),
        ]},
        {"id": "remote", "t": ("Hỗ trợ từ xa", "Remote help"), "p": [
            ("Chỉ xem hoặc điều khiển máy của người khác khi họ đồng ý. Truy cập không giám sát bằng mật khẩu chỉ dành cho thiết bị của chính bạn hoặc thiết bị bạn được chủ sở hữu cho phép. Bạn chịu trách nhiệm về những gì mình làm trên máy đó.",
             "Only view or control someone else's computer with their consent. Unattended password access is only for your own devices, or devices whose owner allowed it. You're responsible for what you do on it."),
            ("Hãy cảnh giác với lừa đảo: đừng cho người lạ điều khiển máy của bạn. Lumora không bao giờ chủ động liên hệ để xin điều khiển máy của bạn.",
             "Watch out for scams: never let a stranger control your computer. Lumora will never contact you asking to control your computer."),
        ]},
        {"id": "content", "t": ("Nội dung của bạn", "Your content"), "p": [
            ("Bạn sở hữu và chịu trách nhiệm về những gì mình gửi. Vì chúng tôi không xem được nội dung trò chuyện, bạn có thể tự bảo vệ mình bằng cách chặn người khác, rời nhóm, và quản trị viên nhóm có thể xoá thành viên.",
             "You own and are responsible for what you send. Because we can't see your conversations, you stay in control: you can block people and leave groups, and group admins can remove members."),
        ]},
        {"id": "bots", "t": ("Bot", "Bots"), "p": [
            ("Người tạo bot chịu trách nhiệm về bot của mình: tuân theo quy tắc cho bot, không gửi tin rác và giữ kín thông tin người dùng gửi cho bot.",
             "Bot makers are responsible for their bots: follow the bot rules, don't send spam, and keep what users send to the bot private."),
        ]},
        {"id": "backup", "t": ("Bản sao lưu của bạn", "Your backup"), "p": [
            ("Vì không có tài khoản, chúng tôi không thể lấy lại dữ liệu hay cụm từ khôi phục khi bạn làm mất. Hãy tự sao lưu và cất giữ cẩn thận.",
             "Because there are no accounts, we can't recover your data or recovery phrase if you lose them. Keep your own backup somewhere safe."),
        ]},
        {"id": "warranty", "t": ("Giới hạn trách nhiệm", "No warranty"), "p": [
            ("Lumora được cung cấp nguyên trạng. Chúng tôi cố gắng để ứng dụng ổn định và an toàn, nhưng không thể cam kết không bao giờ có lỗi. Trong phạm vi pháp luật cho phép, chúng tôi không chịu trách nhiệm cho thiệt hại phát sinh từ việc sử dụng ứng dụng.",
             "Lumora is provided as is. We work hard to keep it stable and safe, but we can't promise it will never have bugs. To the extent the law allows, we aren't liable for damage that results from using the app."),
        ]},
        {"id": "changes", "t": ("Thay đổi và liên hệ", "Changes and contact"), "p": [
            ("Khi điều khoản thay đổi, chúng tôi sẽ cập nhật trang này và ghi rõ ngày cập nhật ở đầu trang.",
             "When these terms change, we'll update this page and show the date of the change at the top."),
            ("Câu hỏi và góp ý: hãy gửi qua mục Issues trên [trang phát hành chính thức trên GitHub](https://github.com/hoangtuvungcao/get_lumora/issues).",
             "Questions and feedback: please use Issues on the [official release page on GitHub](https://github.com/hoangtuvungcao/get_lumora/issues)."),
        ]},
    ],
}

CONTACT = "trong20843@gmail.com"

CHILD_SAFETY = {
    "prefix": "cs",
    "icon": "shield",
    "title": ("Tiêu chuẩn an toàn trẻ em", "Child safety standards"),
    "lead": (
        "Lumora không dung thứ cho bất kỳ hình thức xâm hại hay bóc lột tình dục trẻ em nào (CSAE), kể cả tài liệu xâm hại tình dục trẻ em (CSAM).",
        "Lumora has zero tolerance for child sexual abuse and exploitation (CSAE), including child sexual abuse material (CSAM).",
    ),
    "desc": (
        "Cam kết của Lumora chống xâm hại và bóc lột trẻ em: cách báo cáo, chặn và liên hệ.",
        "Lumora's commitment against child sexual abuse and exploitation: how to report, block and reach us.",
    ),
    "summary": [
        ("Cấm tuyệt đối nội dung và hành vi xâm hại, bóc lột tình dục trẻ em.", "Content and conduct that sexually abuses or exploits children is strictly forbidden."),
        ("Báo cáo và chặn ngay trong ứng dụng, ở mọi cuộc trò chuyện.", "Report and block right in the app, in every conversation."),
        ("Quản trị viên nhóm và cộng đồng được xoá thành viên và cấm vĩnh viễn.", "Group and community admins can remove and permanently ban members."),
        ("Liên hệ trực tiếp: " + CONTACT, "Direct contact: " + CONTACT),
    ],
    "sections": [
        {"id": "policy", "t": ("Chính sách", "Policy"), "p": [
            ("Nghiêm cấm dùng Lumora để tạo, chia sẻ, tìm kiếm hay lưu trữ tài liệu xâm hại tình dục trẻ em; để dụ dỗ, tiếp cận (grooming), tống tiền tình dục hay buôn bán trẻ em; hoặc bất kỳ hành vi nào gây hại cho trẻ em. Vi phạm có thể dẫn tới việc bị chặn, bị cấm khỏi nhóm và cộng đồng, và được báo cho cơ quan chức năng.",
             "Using Lumora to create, share, seek or store child sexual abuse material; to groom, sexually extort or traffic children; or for any conduct that harms children is forbidden. Violations can lead to blocking, bans from groups and communities, and reports to the authorities."),
        ]},
        {"id": "report", "t": ("Cách báo cáo trong ứng dụng", "How to report in the app"), "p": [
            {"li": [
                ("Cuộc trò chuyện 1-1: mở menu ⋮ của cuộc trò chuyện → Báo cáo. Người đó bị chặn ngay; bạn có thể xoá luôn cuộc trò chuyện.",
                 "1-1 chat: open the chat's ⋮ menu → Report. The person is blocked at once; you can also delete the chat."),
                ("Nhóm và cộng đồng: nhấn giữ tin nhắn → Báo cáo, hoặc mở thông tin nhóm → Báo cáo. Báo cáo đến trưởng nhóm (hoặc chủ cộng đồng) và quản trị viên, những người có thể xoá tin nhắn, xoá thành viên và cấm vĩnh viễn.",
                 "Groups and communities: long-press the message → Report, or open the group info → Report. The report goes to the group or community owner and admins, who can delete messages, remove members and ban them for good."),
                ("Chặn một người bất kỳ lúc nào trong trang thông tin của họ.", "Block anyone at any time from their info page."),
            ]},
            ("Tin nhắn được mã hoá đầu cuối và truyền trực tiếp giữa các thiết bị, nên chúng tôi không đọc được nội dung. Nếu bạn gặp nội dung xâm hại trẻ em, hãy báo cáo trong ứng dụng, giữ bằng chứng trên thiết bị của bạn và báo ngay cho cơ quan chức năng.",
             "Messages are end-to-end encrypted and travel directly between devices, so we cannot read them. If you come across child abuse content, report it in the app, keep the evidence on your device and tell the authorities right away."),
        ]},
        {"id": "authorities", "t": ("Báo cho cơ quan chức năng", "Telling the authorities"), "p": [
            ("Tại Việt Nam: gọi Tổng đài quốc gia bảo vệ trẻ em 111 (miễn phí, 24/7) hoặc báo công an nơi gần nhất. Ở nước khác: liên hệ cảnh sát địa phương hoặc gửi báo cáo tới [NCMEC CyberTipline](https://report.cybertip.org/).",
             "In Vietnam: call the national child protection hotline 111 (free, 24/7) or the nearest police. Elsewhere: contact local police or report to the [NCMEC CyberTipline](https://report.cybertip.org/)."),
            ("Chúng tôi hợp tác với cơ quan chức năng trong phạm vi những gì chúng tôi có. Lumora không có máy chủ lưu tin nhắn hay danh tính người dùng.",
             "We cooperate with the authorities within what we hold. Lumora has no server that stores messages or user identities."),
        ]},
        {"id": "contact", "t": ("Liên hệ về an toàn trẻ em", "Child safety contact"), "p": [
            ("Người phụ trách: Nguyễn Văn Trọng — email " + CONTACT + ". Chúng tôi phản hồi các báo cáo về an toàn trẻ em trong thời gian sớm nhất.",
             "Point of contact: Nguyễn Văn Trọng — email " + CONTACT + ". We respond to child safety reports as quickly as we can."),
        ]},
    ],
}

DELETE_ACCOUNT = {
    "prefix": "da",
    "icon": "shield",
    "title": ("Xoá tài khoản Lumora", "Delete your Lumora account"),
    "lead": (
        "Tài khoản Lumora chỉ nằm trên thiết bị của bạn. Xoá nó ngay trong ứng dụng; chúng tôi không giữ bản sao nào.",
        "Your Lumora account lives only on your devices. Delete it right in the app; we keep no copy.",
    ),
    "desc": (
        "Cách xoá tài khoản Lumora và toàn bộ dữ liệu của bạn.",
        "How to delete your Lumora account and all your data.",
    ),
    "summary": [
        ("Xoá trong ứng dụng: Cài đặt → Bảo mật → Xoá tài khoản.", "In the app: Settings → Security → Delete account."),
        ("Xoá trên thiết bị chính sẽ đăng xuất và xoá dữ liệu trên mọi thiết bị đã liên kết.", "Deleting on the main device signs out and wipes every linked device."),
        ("Chúng tôi không có máy chủ lưu tài khoản, nên không còn gì để xoá thêm.", "We have no server holding accounts, so nothing else is left to delete."),
    ],
    "sections": [
        {"id": "steps", "t": ("Các bước", "Steps"), "p": [
            {"li": [
                ("Mở Lumora → Cài đặt → Bảo mật → Xoá tài khoản.", "Open Lumora → Settings → Security → Delete account."),
                ("Nhập mật khẩu tài khoản (nếu đã đặt) và xác nhận.", "Enter your account password (if you set one) and confirm."),
                ("Tin nhắn, bạn bè, nhóm, tệp đã tải và khoá mã hoá trên thiết bị này bị xoá; các thiết bị đã liên kết cũng bị đăng xuất và xoá dữ liệu.", "Messages, friends, groups, downloaded files and encryption keys on this device are deleted; linked devices are signed out and wiped too."),
                ("Gỡ ứng dụng nếu bạn muốn.", "Uninstall the app if you like."),
            ]},
        ]},
        {"id": "data", "t": ("Dữ liệu nào bị xoá", "What is deleted"), "p": [
            ("Toàn bộ dữ liệu của bạn chỉ nằm trên thiết bị của bạn, nên sau khi xoá thì không còn ở đâu nữa. Lưu ý: những tin nhắn bạn đã gửi vẫn còn trên thiết bị của người nhận, như với mọi ứng dụng nhắn tin. Nếu bạn còn giữ 24 từ khôi phục hoặc tệp sao lưu, hãy huỷ chúng để không ai khôi phục lại được tài khoản.",
             "All your data lives only on your devices, so once deleted it is gone. Note: messages you sent remain on the recipients' devices, as with any messaging app. If you still have your 24-word recovery phrase or a backup file, destroy them so nobody can restore the account."),
        ]},
        {"id": "help", "t": ("Cần hỗ trợ", "Need help"), "p": [
            ("Không mở được ứng dụng? Gỡ cài đặt ứng dụng sẽ xoá dữ liệu trên thiết bị đó. Mọi câu hỏi: " + CONTACT + ".",
             "Can't open the app? Uninstalling it deletes the data on that device. Any questions: " + CONTACT + "."),
        ]},
    ],
}

PAGES = {"privacy": PRIVACY, "terms": TERMS, "child-safety": CHILD_SAFETY, "delete-account": DELETE_ACCOUNT}
