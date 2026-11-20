# LiquidGlassBar v1.4.0 (Rootless + AppList + GPU Liquid Glass)

## Cấu trúc thư mục
- `Makefile`, `control`, `LiquidGlassBar.plist`, `Tweak.x`
- `layout/Library/PreferenceLoader/Preferences/LiquidGlassBar.plist`
- `LiquidGlassBarPrefs/` (Toàn bộ mã nguồn trang Cài đặt & Xem trước trực tiếp)

## Yêu cầu trên máy (Sileo)
- **AltList** (`com.opa334.altlist`) — dùng để hiển thị danh sách chọn ứng dụng trong Cài đặt.
- **PreferenceLoader**

## Cách biên dịch ra file .deb (Theos)
```bash
cd LiquidGlassBar
make clean package
```
File `.deb` sẽ xuất ra tại thư mục `packages/`.
