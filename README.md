# LiquidGlassBar v1.4.2 (Rootless + libSparkAppList + GPU Liquid Glass)

## Thay đổi ở bản 1.4.2
- Sử dụng `SparkAppListTableViewController` (`libSparkAppList`) trong `Root.plist` để hiển thị đầy đủ danh sách ứng dụng & thanh tìm kiếm trên iOS 16.3.1 rootless.
- Hỗ trợ đồng thời cả định dạng `enabledApps` (`libSparkAppList`) và `AppEnabled-<bundleID>` (`AltList`/`AppList`).
- Bổ sung nhận diện & kích hoạt cử chỉ chạm (`UITapGestureRecognizer`) cho các ứng dụng dùng thanh bar tự chế như Messenger.

## Biên dịch
```bash
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```
