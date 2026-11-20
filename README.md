# LiquidGlassBar v1.5.0 (Rootless + Bộ chọn ứng dụng tự chủ + GPU Liquid Glass)

## Cải tiến chính ở bản 1.5.0
- **Tự chủ hoàn toàn danh sách chọn ứng dụng (`LGCAppListController`)**: Không còn phụ thuộc thư viện AppList/libSparkAppList/AltList bên ngoài; tự lấy trực tiếp danh sách toàn bộ ứng dụng đã cài + ứng dụng hệ thống kèm icon thật và thanh tìm kiếm trên iOS 16.3.1 rootless.
- **Kích hoạt tức thì (Hot-Reload)**: Bật/tắt ứng dụng trong Cài đặt sẽ có tác dụng ngay lập tức kể cả với các ứng dụng đang chạy nền.
- **Hiệu ứng kính thuần GPU 60/120fps**: Cục kính `CAGradientLayer` + `CAShapeLayer` phản xạ ánh sáng mượt mà, hỗ trợ kéo trượt co giãn theo vận tốc tay.
