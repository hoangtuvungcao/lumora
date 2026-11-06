# Push bridge for iPhone (optional) / Máy chủ đẩy cho iPhone (tùy chọn)

## Nói ngắn gọn

Lumora không có máy chủ. Trên iPhone, Apple tạm dừng mọi app chạy nền sau vài giây, và **cách duy nhất** để
đánh thức một app đang đóng là dịch vụ đẩy của Apple (APNs) – chỉ người **phát hành** app (có khóa của Apple)
mới gửi được.

`lumora-push` là một chương trình nhỏ, mã nguồn mở, **không bắt buộc**:

* Nó chỉ nhận một "mã thiết bị" **đã mã hóa** và gửi tới iPhone câu *"Bạn có tin nhắn mới"* hoặc làm iPhone
  **đổ chuông** khi có cuộc gọi.
* Nó **không thấy nội dung tin nhắn, không biết ai nhắn cho ai**, không lưu danh bạ, không cần tài khoản.
* Tên người gửi và đoạn đầu tin nhắn (nếu người dùng cho hiện) được **mã hóa đầu-cuối** – chỉ iPhone nhận mới
  mở được.
* Người dùng phải **tự bật** *Cài đặt › Thông báo › Thông báo tức thì*. Không bật, hoặc bản app không có máy chủ
  đẩy, thì Lumora vẫn chạy bình thường: tin nhắn về khi mở app.

Ai chạy nó? **Người phát hành bản iPhone** (người có tài khoản Apple Developer và khóa APNs). Ai tự build Lumora
với tài khoản Apple của mình thì tự chạy một bản cho app của mình.

## In plain words

iOS suspends background apps within seconds; only Apple's push service can wake a closed app, and only the
**publisher** of that app can use it. `lumora-push` is a tiny, optional, open-source bridge:

* It receives an **encrypted** device token and sends a content-free *"New message"* push, or a VoIP push that
  makes the phone **ring** for a call.
* It **never sees message content or who talks to whom**, keeps no contacts, has no accounts.
* The sender's name and a short preview travel **end-to-end encrypted** to the phone's notification extension.
* Users opt in (*Settings › Notifications › Instant notifications*). Without it Lumora works as before:
  messages arrive when the app is opened.

---

## How it works

```
iPhone (Lumora)                     friend's device (any platform)              lumora-push            Apple APNs
 ├─ APNs + VoIP tokens ─seal─▶ PushReg{bridge URL, sealed token, notify key}
 │      (to the bridge's public key)   │ kept per friend, sent only to "+push1" peers
 │                                     │
 │   offline …        message queued ──┤── POST /wake {token, kind, e2e} ─────▶ open token ──▶ alert / voip
 │                                     │   (once per burst)                     rate limit
 ◀───────────────────── push: loc-key "PUSH_NEW_MESSAGE" + opaque e2e ─────────────────────────────┘
 └─ Notification Service Extension: decrypts e2e (name + preview) on the phone; app opens → messages flow P2P
```

| The bridge sees | The bridge never sees |
|---|---|
| a device token (after opening the sealed blob), the app's bundle id, msg/call, the sender's IP (for rate limiting, in memory) | message text, sender or recipient identity, contacts, groups, the preview (sealed to the phone) |

Formats (crate `lumora-push`, `src/lib.rs`):

* **Sealed token** = `eph_pub(32) ‖ ChaCha20-Poly1305(key = BLAKE3-derive("lumora-push token v1", X25519(eph, bridge) ‖ eph_pub ‖ bridge_pub), nonce 0)`; fresh ephemeral key each time, so two seals of the same token are unlinkable.
* **Preview blob** = `eph_pub(32) ‖ nonce(12) ‖ ciphertext ‖ tag(16)`, key = HKDF-SHA256(X25519, salt = eph_pub ‖ recipient_pub, info = "lumora-push notify v1") – exactly what CryptoKit opens.
* `POST /wake` `{"token": base64, "kind": "msg"|"call", "e2e": base64?}` → `202` sent · `410` device unregistered (sender drops the registration) · `429` rate limited · `400`/`403` bad request / other app.

Limits (defaults): per device 6 message wakes burst then 1 per 20 s, 3 call wakes then 1 per 10 s; per client IP
60 burst then 1 per second. Senders already coalesce: one wake per peer per 60 s while it stays offline.

## Run it

You need, from the Apple Developer account that publishes the iPhone app:

1. An **APNs auth key** (`.p8`): App Store Connect › Users and Access › Integrations › Keys › *Apple Push
   Notifications service*. Note its **Key ID** and your **Team ID**.
2. The app's **bundle id** (default `vn.lumora.lumora`).
3. A server with a domain name (HTTPS is required by the app).

With Docker (from `relay/push/`):

```sh
cp ~/Downloads/AuthKey_ABCDE12345.p8 AuthKey.p8
cp lumora-push.env.example lumora-push.env
$EDITOR lumora-push.env            # key id, team id, bundle id
PUSH_DOMAIN=push.example.org docker compose up -d
docker compose exec push lumora-push --print-public-key     # → put into the app build
```

Without Docker:

```sh
cd core && cargo build --release -p lumora-push
./target/release/lumora-push --listen 127.0.0.1:8099 --state /var/lib/lumora-push \
  --apns-key AuthKey.p8 --apns-key-id ABCDE12345 --team-id TEAM123456 --topic vn.lumora.lumora
```

Put it behind any HTTPS reverse proxy (Caddy example in `docker-compose.yml`; pass `--trust-proxy` so rate limits
use the real client IP). The bridge key is created on first start in `--state` (`bridge.key`); **back it up** –
a new key invalidates every registration until phones register again.

Test without Apple: `--apns-log pushes.jsonl` writes would-be pushes to a file instead of sending them (this is
what `core/tests/apple_e2e.py` and CI use).

## Configure the app build

```sh
flutter build ios --release \
  --dart-define=LUMORA_PUSH_URL=https://push.example.org \
  --dart-define=LUMORA_PUSH_KEY=<output of --print-public-key>
# optional if your bundle id differs:  --dart-define=LUMORA_APP_TOPIC=com.example.lumora
```

Without these two defines the *Instant notifications* switch is not shown and nothing is ever sent to a bridge.
On developer.apple.com, the App ID needs the **Push Notifications** capability (and App Groups, see
[Apple platforms](../platforms/apple.md)). If you ship without a bridge, remove `voip` from
`UIBackgroundModes` in `app/ios/Runner/Info.plist`.

## Operations

* `GET /health` – counters (accepted, rate_limited, dead, failed, bad) and whether it is a dry run.
* `GET /pubkey` – the bridge public key and served topics.
* Logs never contain tokens. `dead-tokens.txt` in the state directory holds hashes of unregistered tokens.
* Resource use is tiny (one HTTP/2 connection to Apple, a few MB of RAM).
