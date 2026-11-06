# Lumora Photo Sync

Đồng bộ ảnh giữa các thiết bị **không cần máy chủ** — dữ liệu đi thẳng từ máy này sang máy kia, được mã hoá đầu cuối.

## Tính năng

- Quét thư mục ảnh và bỏ qua ảnh **đã có** (so sánh mã băm)
- Tiếp tục gửi khi mất kết nối
- Hỗ trợ `.jpg`, `.png`, `.heic`

## Cài đặt

```bash
pip install lumora-sync
lumora-sync --album "~/Pictures/Đà Lạt 2026"
```

## Cấu hình

| Tuỳ chọn | Mặc định | Ý nghĩa |
|---|---|---|
| `chunk` | 256 KB | Kích thước mỗi lần đọc |
| `retry` | 5 | Số lần thử lại |
| `verify` | bật | Kiểm tra mã băm sau khi nhận |

> **Lưu ý:** ảnh gốc không bao giờ bị xoá, kể cả khi đồng bộ lỗi.

![Sơ đồ](https://example.com/diagram.png)

Xem thêm tại [trang dự án](https://lumora.app/sync).
