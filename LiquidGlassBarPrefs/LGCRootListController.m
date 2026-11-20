#import "LGCRootListController.h"
#import "LGCAppListController.h"

static NSString *const LGC_DOMAIN = @"com.vn.liquidglassbar";
static NSString *const LGC_PREFS_NOTIFICATION = @"com.vn.liquidglassbar/prefsChanged";
static NSString *const LGC_ROOTLESS_PLIST = @"/var/jb/var/mobile/Library/Preferences/com.vn.liquidglassbar.plist";

static UIColor *LGCColorFromHex(NSString *hexStr, UIColor *fallback) {
    if (![hexStr isKindOfClass:[NSString class]] || hexStr.length == 0) return fallback;
    NSString *clean = [[hexStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([clean hasPrefix:@"#"]) clean = [clean substringFromIndex:1];
    if ([clean hasPrefix:@"0X"]) clean = [clean substringFromIndex:2];
    if (clean.length != 6) return fallback;
    unsigned int rgbVal = 0;
    if (![[NSScanner scannerWithString:clean] scanHexInt:&rgbVal]) return fallback;
    return [UIColor colorWithRed:((rgbVal & 0xFF0000) >> 16) / 255.0
                           green:((rgbVal & 0x00FF00) >> 8) / 255.0
                            blue:(rgbVal & 0x0000FF) / 255.0
                           alpha:1.0];
}

static NSString *LGCHexFromColor(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0;
        if ([color getWhite:&w alpha:&a]) { r = g = b = w; }
    }
    return [NSString stringWithFormat:@"#%02X%02X%02X",
            (int)lround(r * 255.0), (int)lround(g * 255.0), (int)lround(b * 255.0)];
}

@interface LGCRootListController () <UIColorPickerViewControllerDelegate>
@property (nonatomic, copy) NSString *activeColorKey;
@property (nonatomic, copy) NSString *activeColorDefaultHex;
- (void)saveColor:(UIColor *)color postNotification:(BOOL)postNotification;
@end

@implementation LGCRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)LGC_PREFS_NOTIFICATION, NULL, NULL, YES);
}

- (void)openAppList:(id)sender {
    (void)sender;
    LGCAppListController *vc = [[LGCAppListController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openSelectedColorPicker:(id)sender {
    (void)sender;
    [self presentColorPickerForKey:@"selectedColorHex" defaultHex:@"#0084FF" title:@"Màu icon & kính khi chọn"];
}

- (void)openGlassTintColorPicker:(id)sender {
    (void)sender;
    [self presentColorPickerForKey:@"glassTintHex" defaultHex:@"#FFFFFF" title:@"Màu nhuộm nền kính"];
}

- (void)presentColorPickerForKey:(NSString *)prefKey defaultHex:(NSString *)defaultHex title:(NSString *)title {
    self.activeColorKey = prefKey;
    self.activeColorDefaultHex = defaultHex;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:LGC_DOMAIN];
    NSString *currentHex = [defaults stringForKey:prefKey] ?: defaultHex;
    UIColorPickerViewController *picker = [[UIColorPickerViewController alloc] init];
    picker.delegate = self;
    picker.supportsAlpha = NO;
    picker.selectedColor = LGCColorFromHex(currentHex, [UIColor blueColor]);
    picker.title = title;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)viewController {
    [self saveColor:viewController.selectedColor postNotification:NO];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    [self saveColor:viewController.selectedColor postNotification:YES];
    [self reloadSpecifiers];
}

- (void)showDiagnostics:(id)sender {
    (void)sender;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:LGC_DOMAIN];
    NSDictionary *dict = [defaults dictionaryRepresentation];
    NSDictionary *fileDict = [NSDictionary dictionaryWithContentsOfFile:LGC_ROOTLESS_PLIST];

    NSMutableSet<NSString *> *enabledApps = [NSMutableSet set];
    id arr1 = dict[@"enabledApps"];
    if ([arr1 isKindOfClass:[NSArray class]]) [enabledApps addObjectsFromArray:arr1];
    id arr2 = fileDict[@"enabledApps"];
    if ([arr2 isKindOfClass:[NSArray class]]) [enabledApps addObjectsFromArray:arr2];

    for (NSString *k in dict) {
        if ([k hasPrefix:@"AppEnabled-"] && [dict[k] boolValue]) {
            [enabledApps addObject:[k substringFromIndex:@"AppEnabled-".length]];
        }
    }
    for (NSString *k in fileDict) {
        if ([k hasPrefix:@"AppEnabled-"] && [fileDict[k] boolValue]) {
            [enabledApps addObject:[k substringFromIndex:@"AppEnabled-".length]];
        }
    }

    NSString *appsSummary = enabledApps.count > 0
        ? [[enabledApps allObjects] componentsJoinedByString:@", "]
        : @"(Chưa chọn ứng dụng nào trong mục Chọn ứng dụng áp dụng)";

    NSString *last = [defaults stringForKey:@"diag_lastLoadAt"];
    NSString *state = [defaults stringForKey:@"diag_barState"];
    NSNumber *scans = [defaults objectForKey:@"diag_scanCount"];

    NSString *msg = nil;
    if (!last) {
        msg = [NSString stringWithFormat:@"Ứng dụng đang bật: %@\n\nChưa ghi nhận lần nạp nào. Hãy vào 'Chọn ứng dụng áp dụng' tích chọn ứng dụng muốn dùng, sau đó mở ứng dụng đó lên.", appsSummary];
    } else {
        msg = [NSString stringWithFormat:@"Ứng dụng đang bật (%lu): %@\n\nLần nạp gần nhất: %@\nTrạng thái thanh bar: %@\nSố lần quét tìm bar: %@",
               (unsigned long)enabledApps.count, appsSummary, last, state ?: @"(chưa có)", scans ?: @0];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Trạng thái LiquidGlassBar"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetDefaults:(id)sender {
    (void)sender;
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Khôi phục mặc định?"
                                                                     message:@"Đặt lại toàn bộ thông số màu sắc, độ mờ và độ nảy về mặc định (giữ nguyên danh sách ứng dụng đã chọn)."
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Khôi phục" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:LGC_DOMAIN];
        NSArray<NSString *> *keys = @[
            @"enabled", @"dragEnabled", @"haptics", @"debug",
            @"glassAlpha", @"blobAlpha", @"blobWidthPct", @"blobHeightPct",
            @"pillInset", @"springPct", @"stretchPct",
            @"selectedColorHex", @"glassTintHex"
        ];
        for (NSString *k in keys) {
            [defaults removeObjectForKey:k];
        }
        [defaults synchronize];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)LGC_PREFS_NOTIFICATION, NULL, NULL, YES);
        [self reloadSpecifiers];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)saveColor:(UIColor *)color postNotification:(BOOL)postNotification {
    if (!self.activeColorKey || !color) return;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:LGC_DOMAIN];
    [defaults setObject:LGCHexFromColor(color) forKey:self.activeColorKey];
    [defaults synchronize];
    if (postNotification) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)LGC_PREFS_NOTIFICATION, NULL, NULL, YES);
    }
}

@end
