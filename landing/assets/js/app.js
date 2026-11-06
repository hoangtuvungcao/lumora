/* Lumora landing — i18n, theme, OS detection, release rendering. No dependencies. */
(function () {
  "use strict";

  /* ------------------------------------------------------------------
   * RELEASES — inline fallback only. Source of truth: /releases.json (fetched at load).
   * The block between the markers is copied from releases.json by build_pages.py /
   * update_releases.py; never edit it by hand. "{version}" in baseUrl/notesUrl/file is
   * replaced with the release version. A file is linked only when "available": true.
   * ------------------------------------------------------------------ */
  var RELEASES = /*RELEASES-BEGIN*/{"version":"1.0.0","date":"2026-11-06","repo":"hoangtuvungcao/get_lumora","baseUrl":"https://github.com/hoangtuvungcao/get_lumora/releases/download/v{version}/","notesUrl":"https://github.com/hoangtuvungcao/get_lumora/releases/tag/v{version}","checksums":{"file":"SHA256SUMS","signature":"SHA256SUMS.sigstore.json"},"platforms":{"windows":{"name":"Windows","icon":"os-windows","simple":{"vi":"Máy tính Windows 10 trở lên","en":"Windows 10 or later"},"requirements":{"vi":"Windows 10 / 11, 64-bit (x64)","en":"Windows 10 / 11, 64-bit (x64)"},"files":[{"id":"win-exe","label":{"vi":"Trình cài đặt","en":"Installer"},"ext":".exe","arch":"x64","file":"Lumora-v{version}-windows-x86_64-setup.exe","primary":true,"available":false},{"id":"win-zip","label":{"vi":"Bản không cần cài (.zip)","en":"Portable, no install (.zip)"},"ext":".zip","arch":"x64","file":"Lumora-v{version}-windows-x86_64-portable.zip","available":false}]},"macos":{"name":"macOS","icon":"os-apple","simple":{"vi":"Máy Mac (macOS 11 trở lên)","en":"Mac (macOS 11 or later)"},"requirements":{"vi":"macOS 11+ · Universal (Apple Silicon & Intel)","en":"macOS 11+ · Universal (Apple Silicon & Intel)"},"files":[{"id":"mac-dmg","label":{"vi":"Trình cài đặt","en":"Installer"},"ext":".dmg","arch":"Universal","file":"Lumora-v{version}-macos-universal.dmg","primary":true,"signed":false,"note":{"vi":"Chưa được Apple ký số: lần đầu mở, bấm \"Vẫn mở\" trong Cài đặt hệ thống › Quyền riêng tư & Bảo mật.","en":"Not yet signed by Apple: the first time, click \"Open Anyway\" in System Settings › Privacy & Security."},"available":false}]},"linux":{"name":"Linux","icon":"os-linux","simple":{"vi":"Ubuntu 24.04, Debian 13, Fedora 40 trở lên","en":"Ubuntu 24.04, Debian 13, Fedora 40 or later"},"requirements":{"vi":"x86_64 · glibc 2.39+ (Ubuntu 24.04, Debian 13, Fedora 40 trở lên) · X11 hoặc Wayland","en":"x86_64 · glibc 2.39+ (Ubuntu 24.04, Debian 13, Fedora 40 or later) · X11 or Wayland"},"files":[{"id":"linux-appimage","label":{"vi":"AppImage (mọi bản Linux)","en":"AppImage (any distro)"},"ext":".AppImage","arch":"x86_64","file":"Lumora-v{version}-linux-x86_64.AppImage","primary":true,"available":false},{"id":"linux-deb","label":{"vi":"Gói Debian / Ubuntu","en":"Debian / Ubuntu package"},"ext":".deb","arch":"amd64","file":"Lumora-v{version}-linux-amd64.deb","available":false},{"id":"linux-tar","label":{"vi":"Bản nén (.tar.gz)","en":"Archive (.tar.gz)"},"ext":".tar.gz","arch":"x86_64","file":"Lumora-v{version}-linux-x86_64.tar.gz","available":false}]},"android":{"name":"Android","icon":"os-android","simple":{"vi":"Điện thoại, máy tính bảng Android 8 trở lên","en":"Android 8 or later phones and tablets"},"requirements":{"vi":"Android 8.0+ · arm64-v8a (hầu hết điện thoại), armeabi-v7a (máy cũ), x86_64","en":"Android 8.0+ · arm64-v8a (most phones), armeabi-v7a (older phones), x86_64"},"files":[{"id":"android-arm64","label":{"vi":"Hầu hết điện thoại (arm64)","en":"Most phones (arm64)"},"ext":".apk","arch":"arm64-v8a","file":"Lumora-v{version}-android-arm64-v8a.apk","primary":true,"available":false},{"id":"android-universal","label":{"vi":"Mọi điện thoại (lớn hơn)","en":"Any phone (larger)"},"ext":".apk","arch":"universal","file":"Lumora-v{version}-android-universal.apk","alt":true,"available":false},{"id":"android-armv7","label":{"vi":"Điện thoại đời cũ (32-bit)","en":"Older phones (32-bit)"},"ext":".apk","arch":"armeabi-v7a","file":"Lumora-v{version}-android-armeabi-v7a.apk","available":false},{"id":"android-x86_64","label":{"vi":"Máy tính bảng / máy ảo x86","en":"x86 tablets / emulators"},"ext":".apk","arch":"x86_64","file":"Lumora-v{version}-android-x86_64.apk","available":false}]}},"comingSoon":{"ios":{"name":"iPhone / iPad","icon":"os-apple","note":{"vi":"Sắp ra mắt","en":"Coming soon"}}},"tools":{"botRunner":{"name":"Lumora Bot Runner","label":{"vi":"Lumora Bot Runner","en":"Lumora Bot Runner"},"description":{"vi":"Chương trình nhỏ chạy trên máy tính của bạn, giúp đoạn mã bot kết nối vào Lumora.","en":"A small program that connects your bot code to Lumora."},"files":[{"id":"runner-windows","label":{"vi":"Windows","en":"Windows"},"arch":"x86_64","file":"Lumora-bot-runner-v{version}-windows-x86_64.exe","available":false},{"id":"runner-linux","label":{"vi":"Linux","en":"Linux"},"arch":"x86_64","file":"Lumora-bot-runner-v{version}-linux-x86_64","available":false},{"id":"runner-macos","label":{"vi":"macOS","en":"macOS"},"arch":"Universal","file":"Lumora-bot-runner-v{version}-macos-universal","available":false}]}}}/*RELEASES-END*/;
  var ORDER = ["windows", "macos", "linux", "android"];

  /* English strings. Vietnamese is the default and is read from the HTML itself. */
  var EN = {
    "a11y.skip": "Skip to content", "a11y.nav": "Main", "a11y.lang": "Chuyển sang tiếng Việt",
    "a11y.theme": "Toggle light/dark theme", "a11y.menu": "Open menu",
    "nav.features": "Features", "nav.who": "Who it's for", "nav.privacy": "Privacy", "nav.faq": "FAQ",
    "nav.download": "Download", "nav.langCode": "VI", "nav.dev": "Developers",
    "more.title": "And lots more", "more.os": "Works on Windows, macOS, Linux and Android. iPhone/iPad version coming soon.", "more.dev": "Are you a developer? Build your own bot →",
    "m1.t": "Stickers, GIFs & memes", "m1.d": "Make your own sticker packs and share animated GIFs and memes with the whole group.",
    "m2.t": "Find people by @name·code", "m2.d": "Find friends by an easy-to-remember username, plus a personal code so nobody can impersonate them.",
    "m3.t": "Bots & BotFather", "m3.d": "Weather, reminders, shop bots and more. Create your own bot right in the app with BotFather, no server to rent.",
    "m4.t": "Delete for me or for everyone", "m4.d": "Sent something by mistake? Take it back from everyone's device with one tap.",
    "m5.t": "Group admin tools", "m5.d": "Slow mode, announcement channels and \"seen by\" keep even big groups tidy.",
    "m6.t": "24-hour stories", "m6.d": "Share moments from your day. They disappear after 24 hours.",
    "m7.t": "Live location", "m7.d": "Let family see where you are on your way home, only for as long as you choose.",
    "m8.t": "Voice messages", "m8.d": "Don't feel like typing? Hold the button, talk, and it's sent.",
    "m9.t": "Public & private groups", "m9.d": "Private groups can't be found and are joined by invite link only. Public groups can be found by @name, and each has its own code, so nobody can pass off a look-alike.",
    "m10.t": "App lock & chat lock", "m10.d": "Set a PIN for the whole app or for individual chats. Notifications never show the content.",
    "m11.t": "Storage saver", "m11.d": "Cleans up old files automatically and never stores the same file twice, so your device stays light.",
    "m12.t": "Everything is free", "m12.d": "Every feature, for everyone. No paid plans, no ads.",
    "m13.t": "Use it on several devices", "m13.d": "Link your phone and computer with one QR scan, then bring your chat history over to the new device.",
    "m14.t": "Checklists & reminders", "m14.d": "Make a shopping list for the whole family, and set reminders that ring on everyone's device at the right time.",
    "m15.t": "Polls & scheduled messages", "m15.d": "Create a poll so the group settles on a plan fast. Write a message now and let Lumora send it later.",
    "m16.t": "Disappearing messages, no history", "m16.d": "Make messages delete themselves after the time you choose, or chat without keeping any history.",
    "m17.t": "Security code check", "m17.d": "Compare the safety number in person or on a video call to make sure nobody is listening in between.",
    "m18.t": "Video calls with beautify", "m18.d": "Smooth skin with a little light and warmth during calls, and a brighter picture in dim rooms.",
    "m19.t": "Photo editing", "m19.d": "Crop, rotate, draw, add text, stickers and filters, and hide sensitive details before sending. GPS location is removed automatically.",
    "m20.t": "File previews", "m20.d": "View PDFs, CSV sheets, text and Markdown right in the app, with a first-page preview of PDFs before you download.",
    "hero.badge": "Free forever · No ads",
    "hero.title": "Direct.<br><span class=\"grad-text\">Private. Yours.</span>",
    "hero.lead": "Chat, video call, send files and help your family fix their computer from afar, all in one app. No sign-up, no phone number. Only you and the people you talk to can read your messages.",
    "hero.cta": "Download for free", "hero.secondary": "See features",
    "mock.chats": "Chats", "mock.search": "Search chats", "mock.all": "All", "mock.unread": "Unread",
    "mock.personal": "Personal", "mock.groups": "Groups", "mock.communities": "Communities", "mock.yourStory": "Your story",
    "mock.botfather": "Create and manage your bots", "mock.archived": "Archived", "mock.archivedSub": "1 chat",
    "mock.pinned": "Pinned", "mock.recent": "Recent", "mock.saved": "Saved messages", "mock.yesterday": "Yesterday",
    "mock.savedSub": "Class reunion in Da Lat in November, book rooms early", "mock.ngocSub": "You: Coffee tomorrow?",
    "mock.project": "Lumora project 🚀", "mock.projectSub": "Anh: @Lan Phuong can you check the new design?",
    "mock.weather": "Weather Bot", "mock.weatherSub": "🌤️ Hanoi today: 24–31°C", "mock.family": "Family 🏡",
    "mock.familySub": "Hà: OK, get 2 boxes", "mock.online": "Online", "mock.active": "Active now", "mock.e2e": "End-to-end encrypted",
    "mock.today": "Today", "mock.m1": "Here's the Q3 summary sheet, could you take a look?", "mock.fileMeta": "801 KB · Downloaded",
    "mock.m3": "Got it, thanks! Here are the beach photos from yesterday 🏖️", "mock.m5": "So pretty! Let's video call the whole family tonight 😍",
    "mock.input": "Type a message…", "mock.friends": "Friends", "mock.remoteTab": "Remote", "mock.settings": "Settings",
    "mock.callFrom": "Hà is video calling", "mock.callSub": "Incoming video call…",
    "strip.1": "Free forever", "strip.2": "No sign-up needed", "strip.3": "No ads, no tracking", "strip.4": "Computers & phones",
    "features.overline": "Features",
    "features.title": "One app,<br><span class=\"grad-text\">every way to connect</span>",
    "features.lead": "No need to install five different apps. Lumora brings messaging, calls, file sharing and remote help together, simple enough for anyone to use.",
    "f3.t": "Help family fix their computer remotely", "f3.d": "See and control your parents' or friends' computer as if you were sitting next to them: install apps, fix the printer, change settings. Only with their permission, and they can stop at any time.",
    "f1.t": "Messages & groups", "f1.d": "Chat one-on-one, or create groups for family, class or community, with separate channels for each topic.",
    "f2.t": "Voice & video calls", "f2.d": "Clear calls with less lag. Share your screen during a call with one tap.",
    "f4.t": "Send files of any size", "f4.d": "Videos, original-quality photos, documents tens of GB in size, never compressed. Lost your connection halfway? Lumora picks up where it left off.",
    "f5.t": "Truly private", "f5.d": "Talk privately: only you and the person you're talking to can read it. Not even we can see it.",
    "f6.t": "No sign-up", "f6.d": "No phone number, no email, no password to remember. Install it and start right away.",
    "who.overline": "Who it's for", "who.title": "Everyone uses it differently,<br><span class=\"grad-text\">and it just fits</span>",
    "who1.tag": "Families", "who1.q": "\"When my parents' computer acts up, I open Lumora and fix it right away. No trip home needed.\"",
    "who1.d": "Video calls every evening, crisp photos, and kids far away can still help grandparents set up their phone or computer.",
    "who2.tag": "Study groups", "who2.q": "\"Our class has a channel for every subject, and we call each other every night before exams.\"",
    "who2.d": "Share lectures and large lesson videos without limits. Share your screen to explain things to each other.",
    "who3.tag": "Shops & small businesses", "who3.q": "\"We send quotes and product photos to customers and staff, with no monthly fees at all.\"",
    "who3.d": "Keep team chats private, fix the checkout computer remotely, and keep conversations on your own devices.",
    "who4.tag": "Gamers", "who4.q": "\"Our squad has its own voice channel, and voice stays smooth the whole match.\"",
    "who4.d": "Build your own community with voice channels, voice chat with low lag, and share your screen to show off your best plays.",
    "chip.remote": "Remote help", "chip.video": "Video calls", "chip.photos": "Photo sharing", "chip.groups": "Groups & channels",
    "chip.screen": "Screen sharing", "chip.files": "Large files", "chip.private": "Private", "chip.free": "Free", "chip.voice": "Voice channels",
    "how.overline": "Getting started", "how.title": "Three steps, under a minute",
    "s1.t": "Download and install", "s1.d": "Free on computers and Android phones. Installs like any other app.",
    "s2.t": "Add friends and family", "s2.d": "Send an invite by message, or scan the code on each other's screen with your phone.",
    "s3.t": "Start connecting", "s3.d": "Chat, call, send files or help each other with computers. Everything stays between you and them.",
    "pr.overline": "Private by default", "pr.title": "Your business, <span class=\"grad-text\">only you know it</span>",
    "pr.lead": "Lumora is built so nobody can snoop on your conversations, not even us. No data collection, no ads, no selling your data.",
    "pr1.t": "Only you and the recipient can read it", "pr1.d": "Messages, calls and files are protected on your device before they're sent.",
    "pr2.t": "No phone number, no email", "pr2.d": "No central server stores your messages, and the content is always end-to-end encrypted.",
    "pr3.t": "Your data stays on your device", "pr3.d": "Your chat history is encrypted and kept on your own device, not in somebody's \"cloud\".",
    "pr4.t": "You're always in control", "pr4.d": "Remote help only starts when you agree, unless you yourself have set an unattended access password or chosen to always allow your own device. You can stop it with one button.",
    "dl.overline": "Download", "dl.title": "Free on <span class=\"grad-text\">all your devices</span>",
    "dl.lead": "Pick the device you're using. We've already highlighted the best match.",
    "dl.note": "iPhone/iPad version: coming soon.", "dl.more": "More options and installation help",
    "faq.overline": "FAQ", "faq.title": "Frequently asked questions",
    "q1": "Is Lumora really free?", "a1": "Yes. Lumora is free forever, with no ads and no hidden paid plans. You don't need a card or a sign-up.",
    "q2": "Do I need to create an account?", "a2": "No. Just install the app, choose a display name and start. No phone number or email needed.",
    "q3": "Can anyone, including Lumora, read my messages?", "a3": "No. Your messages, calls and files are protected on your device before they're sent, and only the recipient's device can open them. We have no way to see the content.",
    "q4": "How do I help my parents fix their computer remotely?", "a4": "Both of you install Lumora and add each other, then you send a remote control request. When your parents tap \"Allow control\" (or \"Allow view only\"), you'll see their screen and can help. They can stop at any time.",
    "q5": "What if I lose or change my phone?", "a5": "If your old phone still works, link the new one from it in Settings › Devices: your contacts and chat history move across. If the phone is lost, only your recovery phrase can bring back your identity; since there are no accounts, nobody can restore it for you. Write the phrase down on paper, keep it somewhere safe, and also create a password-protected backup file in Settings, stored somewhere other than your phone.",
    "q6": "How do I install it on an Android phone?", "a6": "Tap \"Download\" on your phone, open the downloaded file and choose \"Install\". The first time, your phone may ask whether to allow installing apps from your browser. Choose \"Allow\".",
    "q7": "My computer shows a warning when I open the app. What should I do?", "a7": "Only download Lumora from this site or the official release page on GitHub (get_lumora). Installers are digitally signed when possible; an unsigned build may make Windows or macOS show a warning. Before opening it, always check the SHA-256 checksum and the signature on the release page: compare the file's checksum with the SHA256SUMS file (see \"Technical details\" on the Download page). If it doesn't match, delete the file and download it again.",
    "cta.badge": "Free forever", "cta.title": "Stay close to the people you love, in the most private way.",
    "cta.lead": "Installs in a minute. No sign-up, no waiting.", "cta.btn": "Download Lumora for free", "cta.other": "See other devices",
    "footer.tag": "Direct. Private. Yours.", "footer.privacy": "Privacy policy", "footer.terms": "Terms of use", "footer.made": "Made in Vietnam, for everyone.",
    "nf.title": "Page not found", "nf.lead": "This link doesn't exist or has moved.", "nf.home": "Back to home",
    /* download page */
    "dp.title": "Download Lumora", "dp.lead": "Free, no sign-up. Pick your device below.",
    "dp.howto": "How to install",
    "dp.w1": "Open the Setup file you downloaded.", "dp.w2": "If Windows shows \"Windows protected your PC\", check the SHA-256 checksum first (see Technical details), then click \"More info\" → \"Run anyway\".", "dp.w3": "Click \"Install\", then open Lumora from the Start menu.",
    "dp.m1": "Open the .dmg file and drag Lumora into the Applications folder.", "dp.m2": "The first time, if macOS says it can't verify the developer: open System Settings › Privacy & Security, scroll down and click \"Open Anyway\".", "dp.m3": "Open Lumora from Launchpad.",
    "dp.l1": "AppImage: right-click the file → Properties → allow running as a program, then double-click it.", "dp.l2": "Debian / Ubuntu: open the .deb in your software installer, or run sudo apt install ./<file>.deb.", "dp.l3": "After installing the .deb, open Lumora from your app list.",
    "dp.a1": "Tap \"Download\" on your phone. It fits most phones (arm64).", "dp.a2": "Open the file and choose \"Install\". If asked, allow installing from your browser.", "dp.a3": "If it says the app isn't compatible, download \"Any phone\" right below the Download button instead.",
    "dp.tech": "Technical details", "dp.techSub": "Checksums, architectures, package formats and system notes.",
    "dp.released": "Released", "dp.thPlatform": "Platform", "dp.thFile": "File", "dp.thArch": "Architecture", "dp.thSha": "File checksum",
    "dp.req": "System requirements", "dp.verify": "File checksum",
    "dp.notes": "System notes",
    "dp.tools": "Lumora Bot Runner (for bot makers)", "dp.toolsLead": "A small program that runs on your computer and connects your bot code to Lumora. Install it once; your bot runs whenever the computer is on. Regular users don't need it.",
    "dp.toolsMore": "How to install it and run a bot →",
    "dp.verifyLead": "Use it to check that a downloaded file hasn't been modified. Run the command below and compare the result with the code in the table; if they differ, don't install the file.",
    "dp.n1": "Linux: make the AppImage executable (chmod +x) or install the .deb with apt. On Wayland, the system asks for screen-sharing permission when remote help starts: pick a screen and click \"Share\".",
    "dp.n2": "macOS: for remote control, allow Screen Recording and Accessibility in System Settings → Privacy & Security.",
    "dp.n3": "Windows: for silent installs on many computers, run the Setup file with /VERYSILENT /SUPPRESSMSGBOXES. The .zip needs no installation: unzip it and run lumora.exe.",
    "dp.n4": "Linux: the .deb lists the libraries it needs, so apt installs them for you. The .tar.gz is for advanced users: unpack it and run ./lumora.",
    "dp.sums": "Every release also has SHA256SUMS (the checksums of all files) and SHA256SUMS.sigstore.json (a digital signature proving the list was made by Lumora's official build). To check everything at once, put them next to your download and run:",
    "dp.relPage": "Open the release page on GitHub"
  };

  /* Pages may add their own English strings (e.g. /developers/) via window.LUMORA_I18N. */
  if (window.LUMORA_I18N) Object.keys(window.LUMORA_I18N).forEach(function (k) { EN[k] = window.LUMORA_I18N[k]; });

  var DYN = {
    vi: { downloadFor: "Tải về cho {os}", other: "Thiết bị khác", recommended: "Phù hợp với máy bạn", download: "Tải về",
      pending: "công bố khi phát hành", free: "Miễn phí", version: "Phiên bản",
      soon: "Sắp ra mắt", soonFor: "Sắp ra mắt cho {os}", soonNote: "Bản cài đặt đang được hoàn thiện", noIos: "Bản cho iPhone/iPad sắp ra mắt. Trong lúc chờ, hãy xem các thiết bị khác.", alt: "Không chắc? Tải bản {label}" },
    en: { downloadFor: "Download for {os}", other: "Other devices", recommended: "Best for your device", download: "Download",
      pending: "published at release", free: "Free", version: "Version",
      soon: "Coming soon", soonFor: "Coming soon for {os}", soonNote: "The installer is almost ready", noIos: "The iPhone/iPad version is coming soon. Meanwhile, see other devices.", alt: "Not sure? Get {label}" }
  };

  var doc = document, root = doc.documentElement;
  var lang = "vi";
  var VI = {}, VI_HTML = {}, VI_ATTR = {}, META = [];
  var store = {
    get: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
  };
  function $(s, c) { return (c || doc).querySelector(s); }
  function $$(s, c) { return Array.prototype.slice.call((c || doc).querySelectorAll(s)); }
  function el(tag, cls, text) { var e = doc.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
  function icon(id, cls) {
    var ns = "http://www.w3.org/2000/svg", s = doc.createElementNS(ns, "svg"), u = doc.createElementNS(ns, "use");
    s.setAttribute("class", "ic" + (cls ? " " + cls : "")); s.setAttribute("aria-hidden", "true"); s.setAttribute("focusable", "false");
    u.setAttribute("href", "/assets/img/icons.svg#" + id); s.appendChild(u); return s;
  }
  function L(v) { return v && typeof v === "object" ? (v[lang] || v.vi || "") : (v || ""); }
  function d(k) { return DYN[lang][k]; }

  /* ---------------- i18n ---------------- */
  function capture() {
    $$("[data-i18n]").forEach(function (n) { VI[n.getAttribute("data-i18n")] = n.textContent; });
    $$("[data-i18n-html]").forEach(function (n) { VI_HTML[n.getAttribute("data-i18n-html")] = n.innerHTML; });
    $$("[data-i18n-attr]").forEach(function (n) {
      n.getAttribute("data-i18n-attr").split(";").forEach(function (p) { var kv = p.split(":"); VI_ATTR[kv[1]] = n.getAttribute(kv[0]); });
    });
    VI.__title = doc.title;
    var md = $('meta[name="description"]'); VI.__desc = md ? md.content : "";
    var en = {
      'meta[property="og:title"]': "Lumora — Direct. Private. Yours.",
      'meta[property="og:description"]': "Chat, video calls, send files and help family fix their computer remotely. Free, no sign-up, only you and the recipient can read it.",
      'meta[property="og:image:alt"]': "Lumora — Direct. Private. Yours.",
      'meta[property="og:locale"]': "en_US", 'meta[property="og:locale:alternate"]': "vi_VN",
      'meta[name="twitter:title"]': "Lumora — Direct. Private. Yours.",
      'meta[name="twitter:description"]': "Chat, video calls, send files and help family fix their computer remotely. Free, no sign-up."
    };
    Object.keys(en).forEach(function (sel) { var n = $(sel); if (n) META.push([sel, n.getAttribute("content"), en[sel]]); });
  }
  function applyLang(l) {
    lang = l === "en" ? "en" : "vi";
    var en = lang === "en";
    $$("[data-i18n]").forEach(function (n) { var k = n.getAttribute("data-i18n"), v = en ? EN[k] : VI[k]; if (v != null) n.textContent = v; });
    $$("[data-i18n-html]").forEach(function (n) {
      var k = n.getAttribute("data-i18n-html"), v = en ? EN[k] : VI_HTML[k];
      if (v != null) n.innerHTML = v; /* trusted static strings only */
    });
    $$("[data-i18n-attr]").forEach(function (n) {
      n.getAttribute("data-i18n-attr").split(";").forEach(function (p) {
        var kv = p.split(":"), v = en ? EN[kv[1]] : VI_ATTR[kv[1]]; if (v != null) n.setAttribute(kv[0], v);
      });
    });
    root.lang = lang;
    var page = root.getAttribute("data-page");
    var titles = { download: "Download — Lumora", "404": "404 — Lumora", developers: "Developers — Build a Lumora bot", api: "API reference — Lumora developers", privacy: "Privacy policy — Lumora", terms: "Terms of use — Lumora" };
    doc.title = en ? (root.getAttribute("data-title-en") || titles[page] || "Lumora — Direct. Private. Yours.") : VI.__title;
    var md = $('meta[name="description"]');
    if (md && en && root.getAttribute("data-desc-en")) md.content = root.getAttribute("data-desc-en");
    else if (md && EN["meta.desc"] && en) md.content = EN["meta.desc"];
    else if (md) md.content = en ? "Lumora: chat, video calls, send files of any size and help family fix their computer remotely. Free, no sign-up, only you and the recipient can read it. Windows, Mac, Linux and Android." : VI.__desc;
    META.forEach(function (m) { var n = $(m[0]); if (n) n.setAttribute("content", en ? m[2] : m[1]); });
    renderReleases();
  }

  /* ---------------- theme ---------------- */
  function effectiveTheme() {
    var t = root.getAttribute("data-theme"); if (t) return t;
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }
  function setTheme(t) {
    root.setAttribute("data-theme", t); store.set("lumora-theme", t);
    $$('meta[name="theme-color"]').forEach(function (n) { n.setAttribute("content", t === "dark" ? "#0F1020" : "#FBF8F4"); });
  }

  /* ---------------- OS detection ---------------- */
  function detectOS() {
    var ua = navigator.userAgent || "", p = "";
    try { p = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || ""; } catch (e) {}
    var s = (p + " " + ua).toLowerCase();
    if (/android/.test(s)) return "android";
    if (/iphone|ipad|ipod/.test(s) || (/mac/.test(s) && navigator.maxTouchPoints > 1)) return "ios";
    if (/win/.test(s)) return "windows";
    if (/mac/.test(s)) return "macos";
    if (/linux|x11|cros|ubuntu|fedora/.test(s)) return "linux";
    return null;
  }
  var OS = detectOS();

  /* ---------------- releases ---------------- */
  function tpl(s) { return String(s || "").replace(/\{version\}/g, RELEASES.version); }
  function fileName(f) { return tpl(f.file); }
  function fileUrl(f) { return f.url || (tpl(RELEASES.baseUrl) + fileName(f)); }
  function altFile(p) { var fs = p.files || []; for (var i = 0; i < fs.length; i++) if (fs[i].alt && isAvail(fs[i])) return fs[i]; return null; }
  /* Only files explicitly marked "available": true are linked; everything else shows "Coming soon". */
  function isAvail(f) { return !!(f && f.available === true && (f.url || f.file)); }
  function hasSha(f) { return f.sha256 && /^[a-f0-9]{64}$/i.test(f.sha256); }
  function primaryFile(p) { var fs = p.files || []; for (var i = 0; i < fs.length; i++) if (fs[i].primary) return fs[i]; return fs[0]; }
  function findFile(id) {
    var hit = null;
    ORDER.forEach(function (k) { var p = RELEASES.platforms[k]; (p && p.files || []).forEach(function (f) { if (f.id === id) hit = f; }); });
    return hit;
  }
  function soonBtn(cls) {
    var s = el("span", "btn is-disabled " + cls); s.setAttribute("aria-disabled", "true");
    s.appendChild(icon("sparkles")); s.appendChild(el("span", null, d("soon"))); return s;
  }

  function renderCards(grid) {
    grid.textContent = "";
    var anchors = grid.hasAttribute("data-anchors");
    ORDER.forEach(function (key) {
      var p = RELEASES.platforms[key]; if (!p) return;
      var f = primaryFile(p); if (!f) return;
      var ok = isAvail(f), rec = key === OS;
      var card = el("article", "glass dl-card" + (rec ? " is-recommended" : "") + (ok ? "" : " is-soon"));
      if (anchors) card.id = key;
      if (rec) card.appendChild(el("span", "dl-card__badge", d("recommended")));
      var os = el("span", "dl-card__os"); os.appendChild(icon(p.icon)); card.appendChild(os);
      card.appendChild(el("h3", null, p.name));
      card.appendChild(el("p", "dl-card__req", L(p.simple || p.requirements)));
      if (ok) {
        var a = el("a", "btn dl-card__btn " + (rec ? "btn--primary" : "btn--glass"));
        a.href = fileUrl(f); a.setAttribute("download", "");
        a.appendChild(icon("download")); a.appendChild(el("span", null, d("download")));
        card.appendChild(a);
        card.appendChild(el("p", "dl-card__ver", d("free") + " · " + d("version") + " " + RELEASES.version + (f.size ? " · " + f.size : "")));
        var alt = altFile(p);
        if (alt) {
          var b = el("a", "dl-card__alt", d("alt").replace("{label}", L(alt.label)));
          b.href = fileUrl(alt); b.setAttribute("download", ""); card.appendChild(b);
        }
      } else {
        card.appendChild(soonBtn("dl-card__btn btn--glass"));
        card.appendChild(el("p", "dl-card__ver", d("free") + " · " + d("soonNote")));
      }
      grid.appendChild(card);
    });
  }

  /* One table row per file. Unavailable files are listed as plain text (no link, no checksum). */
  function fileRow(first, f) {
    var ok = isAvail(f), tr = el("tr", ok ? null : "is-soon");
    tr.appendChild(el("td", null, first));
    var td = el("td");
    if (ok) { var a = el("a", null, fileName(f)); a.href = fileUrl(f); a.setAttribute("download", ""); td.appendChild(a); }
    else td.appendChild(el("span", "dl-file-name", fileName(f)));
    var bits = [L(f.label), ok ? (f.size || "") : d("soon")].filter(Boolean);
    td.appendChild(el("div", "dl-file-size", bits.join(" · ")));
    if (f.note && f.signed !== true) td.appendChild(el("div", "dl-file-size dl-file-note", L(f.note)));
    tr.appendChild(td);
    tr.appendChild(el("td", null, f.arch || ""));
    var tds = el("td", "dl-sha");
    if (ok && hasSha(f)) tds.appendChild(el("code", null, f.sha256)); else tds.appendChild(el("span", "muted", ok ? d("pending") : "—"));
    tr.appendChild(tds);
    return tr;
  }
  /* Label each cell with its column header (used by the stacked mobile layout) and hide the
     checksum column when no file in the table can be downloaded yet. */
  function finishTable(tbody, anyAvail) {
    var table = tbody.closest ? tbody.closest("table") : null; if (!table) return;
    table.classList.toggle("no-sha", !anyAvail);
    var heads = $$("thead th", table).map(function (th) { return th.textContent; });
    $$("tr", tbody).forEach(function (tr) {
      Array.prototype.forEach.call(tr.children, function (td, i) { if (heads[i]) td.setAttribute("data-label", heads[i]); });
    });
  }

  function renderTable(tbody) {
    tbody.textContent = "";
    var any = false;
    ORDER.forEach(function (key) {
      var p = RELEASES.platforms[key]; if (!p) return;
      (p.files || []).forEach(function (f) { if (isAvail(f)) any = true; tbody.appendChild(fileRow(p.name, f)); });
    });
    finishTable(tbody, any);
  }

  function renderTools(tbody) {
    tbody.textContent = "";
    var tools = RELEASES.tools || {}, any = false;
    Object.keys(tools).forEach(function (key) {
      (tools[key].files || []).forEach(function (f) { if (isAvail(f)) any = true; tbody.appendChild(fileRow(L(f.label), f)); });
    });
    finishTable(tbody, any);
  }

  function renderReq(list) {
    list.textContent = "";
    ORDER.forEach(function (key) {
      var p = RELEASES.platforms[key]; if (!p) return;
      var li = el("li"); li.appendChild(el("b", null, p.name + ": ")); li.appendChild(doc.createTextNode(L(p.requirements))); list.appendChild(li);
    });
    var cs = RELEASES.comingSoon || {};
    Object.keys(cs).forEach(function (k) {
      var li = el("li"); li.appendChild(el("b", null, cs[k].name + ": ")); li.appendChild(doc.createTextNode(L(cs[k].note))); list.appendChild(li);
    });
  }

  /* Checksum instructions: show only the commands for files that can actually be downloaded. */
  function renderVerify() {
    var any = false;
    $$("[data-verify]").forEach(function (box) {
      var ok = isAvail(findFile(box.getAttribute("data-verify")));
      box.hidden = !ok; if (ok) any = true;
    });
    var block = $("#verify-block"); if (block) block.hidden = !any;
  }

  /* Primary download buttons (hero + closing CTA): a direct file only when it is really available,
     "Coming soon for {os}" while it is not, and the download page when the OS is unknown. */
  function setDlButton(btn, label, defKey) {
    var p = OS && RELEASES.platforms[OS];
    var f = p ? primaryFile(p) : null, ok = isAvail(f);
    btn.classList.remove("is-disabled"); btn.removeAttribute("aria-disabled");
    var use = $("use", btn); if (use) use.setAttribute("href", "/assets/img/icons.svg#" + (p && !ok ? "sparkles" : "download"));
    if (p && ok) {
      label.textContent = d("downloadFor").replace("{os}", p.name);
      btn.href = fileUrl(f); btn.setAttribute("download", "");
    } else if (p) {
      label.textContent = d("soonFor").replace("{os}", p.name);
      btn.removeAttribute("href"); btn.removeAttribute("download");
      btn.classList.add("is-disabled"); btn.setAttribute("aria-disabled", "true");
    } else {
      label.textContent = lang === "en" ? EN[defKey] : (VI[defKey] || label.textContent);
      btn.href = "/download/"; btn.removeAttribute("download");
    }
  }

  function renderHero() {
    var btn = $("#primary-dl"), label = $("#primary-dl-label"), meta = $("#primary-dl-meta");
    var cbtn = $("#cta-dl"), clabel = $("#cta-dl-label");
    if (cbtn && clabel) setDlButton(cbtn, clabel, "cta.btn");
    var p = OS && RELEASES.platforms[OS];
    var f = p ? primaryFile(p) : null, ok = isAvail(f);
    if (btn && label) {
      setDlButton(btn, label, "hero.cta");
      if (meta) {
        if (p) {
          meta.textContent = d("free") + " · " + L(p.simple) + " · ";
          var a = el("a", null, d("other")); a.href = "/download/"; meta.appendChild(a);
        } else meta.textContent = OS === "ios" ? d("noIos") : "";
      }
    }
    $$(".js-dl-link").forEach(function (a) {
      if (p && ok) { a.href = fileUrl(f); a.setAttribute("download", ""); } else { a.href = "/download/"; a.removeAttribute("download"); }
    });
  }

  function renderReleases() {
    $$(".js-version").forEach(function (n) { n.textContent = "v" + RELEASES.version; });
    $$(".js-date").forEach(function (n) {
      var dt = new Date(RELEASES.date + "T00:00:00");
      n.textContent = isNaN(dt) ? RELEASES.date : dt.toLocaleDateString(lang === "en" ? "en-GB" : "vi-VN", { day: "numeric", month: "long", year: "numeric" });
    });
    $$("[data-file]").forEach(function (n) { var f = findFile(n.getAttribute("data-file")); if (f) n.textContent = fileName(f); });
    $$(".js-tag").forEach(function (n) { n.textContent = "v" + RELEASES.version; });
    $$(".js-release-link").forEach(function (a) { if (RELEASES.notesUrl) a.href = tpl(RELEASES.notesUrl); });
    var grid = $("#dl-grid"); if (grid) renderCards(grid);
    var tb = $("#dl-table"); if (tb) renderTable(tb);
    var rq = $("#dl-req"); if (rq) renderReq(rq);
    var tl = $("#dl-tools"); if (tl) renderTools(tl);
    renderVerify();
    renderHero();
  }

  function loadReleases() {
    if (!window.fetch) return;
    fetch("/releases.json", { cache: "no-cache" })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
      .then(function (j) { if (j && j.platforms && j.version) { RELEASES = j; renderReleases(); } })
      .catch(function () { /* keep inline fallback */ });
  }

  function reveal() {
    var items = $$(".reveal");
    if (!("IntersectionObserver" in window) || (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches)) {
      items.forEach(function (n) { n.classList.add("is-in"); }); return;
    }
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add("is-in"); io.unobserve(e.target); } });
    }, { rootMargin: "0px 0px -6% 0px", threshold: 0.06 });
    items.forEach(function (n) { io.observe(n); });
  }

  /* ---------------- init ---------------- */
  function init() {
    capture();
    var q = /[?&]lang=(en|vi)\b/.exec(location.search);
    applyLang(q ? q[1] : (store.get("lumora-lang") === "en" ? "en" : "vi"));
    root.removeAttribute("data-lang-pending"); /* content was hidden by theme-init.js until English is applied */

    var lt = $("#lang-toggle");
    if (lt) lt.addEventListener("click", function () {
      var next = lang === "en" ? "vi" : "en"; store.set("lumora-lang", next); applyLang(next);
      if (q && history.replaceState) { history.replaceState(null, "", location.pathname + location.hash); q = null; }
    });
    var tt = $("#theme-toggle");
    if (tt) tt.addEventListener("click", function () { setTheme(effectiveTheme() === "dark" ? "light" : "dark"); });

    var nav = $(".nav"), menu = $("#menu-toggle"), links = $("#nav-links");
    var onScroll = function () { if (nav) nav.classList.toggle("is-scrolled", window.scrollY > 8); };
    window.addEventListener("scroll", onScroll, { passive: true }); onScroll();
    if (menu && links) {
      var close = function () { links.classList.remove("is-open"); menu.setAttribute("aria-expanded", "false"); };
      menu.addEventListener("click", function () {
        var open = !links.classList.contains("is-open");
        links.classList.toggle("is-open", open); menu.setAttribute("aria-expanded", String(open));
      });
      links.addEventListener("click", function (e) { if (e.target.closest("a")) close(); });
      doc.addEventListener("keydown", function (e) { if (e.key === "Escape") close(); });
    }
    if (location.hash === "#tech" || location.hash === "#bot-runner" || location.hash === "#verify") {
      var t = $("#tech");
      if (t) { t.open = true; var target = $(location.hash); if (target && target.scrollIntoView) setTimeout(function () { target.scrollIntoView(); }, 0); }
    }
    $$(".js-year").forEach(function (n) { n.textContent = String(new Date().getFullYear()); });
    loadReleases();
    reveal();
  }
  if (doc.readyState === "loading") doc.addEventListener("DOMContentLoaded", init); else init();
})();
