#import "LGCPreviewCell.h"
#import <QuartzCore/QuartzCore.h>

static NSString *const LGC_DOMAIN = @"com.vn.liquidglassbar";
static NSString *const LGC_PREFS_NOTIFICATION = @"com.vn.liquidglassbar/prefsChanged";

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

@interface LGCPreviewBlobView : UIView
@property (nonatomic, strong) CAGradientLayer *bodyGradient;
@property (nonatomic, strong) CAGradientLayer *topSpecular;
@property (nonatomic, strong) CAShapeLayer *rimLayer;
@property (nonatomic, strong) CAGradientLayer *rimGradient;
- (void)applyTintColor:(UIColor *)color alpha:(CGFloat)alpha;
@end

@implementation LGCPreviewBlobView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];

        self.bodyGradient = [CAGradientLayer layer];
        self.bodyGradient.startPoint = CGPointMake(0.5, 0.0);
        self.bodyGradient.endPoint = CGPointMake(0.5, 1.0);
        self.bodyGradient.masksToBounds = YES;
        [self.layer addSublayer:self.bodyGradient];

        self.topSpecular = [CAGradientLayer layer];
        self.topSpecular.startPoint = CGPointMake(0.25, 0.0);
        self.topSpecular.endPoint = CGPointMake(0.75, 1.0);
        self.topSpecular.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.46].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.10].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor
        ];
        self.topSpecular.locations = @[@0.0, @0.45, @1.0];
        self.topSpecular.masksToBounds = YES;
        [self.layer addSublayer:self.topSpecular];

        self.rimGradient = [CAGradientLayer layer];
        self.rimGradient.startPoint = CGPointMake(0.5, 0.0);
        self.rimGradient.endPoint = CGPointMake(0.5, 1.0);
        self.rimGradient.colors = @[
            (id)[UIColor colorWithWhite:1.0 alpha:0.88].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.20].CGColor,
            (id)[UIColor colorWithWhite:1.0 alpha:0.58].CGColor
        ];
        self.rimGradient.locations = @[@0.0, @0.55, @1.0];

        self.rimLayer = [CAShapeLayer layer];
        self.rimLayer.fillColor = [UIColor clearColor].CGColor;
        self.rimLayer.strokeColor = [UIColor whiteColor].CGColor;
        self.rimLayer.lineWidth = 1.25;
        self.rimGradient.mask = self.rimLayer;
        [self.layer addSublayer:self.rimGradient];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    if (b.size.width <= 0 || b.size.height <= 0) return;
    CGFloat r = b.size.height / 2.0;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.bodyGradient.frame = b;
    self.bodyGradient.cornerRadius = r;
    CGRect specRect = CGRectMake(2.0, 1.0, MAX(0, b.size.width - 4.0), b.size.height * 0.56);
    self.topSpecular.frame = specRect;
    self.topSpecular.cornerRadius = MAX(1.0, r - 1.0);
    self.rimGradient.frame = b;
    CGRect insetRect = CGRectInset(b, 0.625, 0.625);
    self.rimLayer.frame = b;
    self.rimLayer.path = [UIBezierPath bezierPathWithRoundedRect:insetRect cornerRadius:MAX(1.0, r - 0.625)].CGPath;
    [CATransaction commit];
}

- (void)applyTintColor:(UIColor *)color alpha:(CGFloat)alpha {
    self.alpha = alpha;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.bodyGradient.colors = @[
        (id)[color colorWithAlphaComponent:0.28].CGColor,
        (id)[color colorWithAlphaComponent:0.16].CGColor,
        (id)[UIColor colorWithWhite:1.0 alpha:0.12].CGColor
    ];
    self.bodyGradient.locations = @[@0.0, @0.65, @1.0];
    [CATransaction commit];
}

@end

@interface LGCPreviewCell ()
@property (nonatomic, strong) UIView *stageView;
@property (nonatomic, strong) UIView *circleA;
@property (nonatomic, strong) UIView *circleB;
@property (nonatomic, strong) NSArray<UIView *> *fakeRows;
@property (nonatomic, strong) UIVisualEffectView *pillFx;
@property (nonatomic, strong) UIView *pillTint;
@property (nonatomic, strong) LGCPreviewBlobView *blobView;
@property (nonatomic, strong) NSArray<UIImageView *> *iconViews;
@property (nonatomic, strong) NSArray<UILabel *> *labelViews;
@property (nonatomic, copy) NSString *lastHash;
@end

static void LGCPreviewPrefsChanged(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object,
                                   CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    LGCPreviewCell *cell = (__bridge LGCPreviewCell *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [cell refreshPreview];
    });
}

@implementation LGCPreviewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        [self buildPreview];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge void *)self, LGCPreviewPrefsChanged,
            (__bridge CFStringRef)LGC_PREFS_NOTIFICATION, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }
    return self;
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge void *)self, (__bridge CFStringRef)LGC_PREFS_NOTIFICATION, NULL);
}

- (void)buildPreview {
    self.stageView = [[UIView alloc] initWithFrame:CGRectZero];
    self.stageView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];
    self.stageView.layer.cornerRadius = 20;
    self.stageView.layer.masksToBounds = YES;
    [self.contentView addSubview:self.stageView];

    self.circleA = [[UIView alloc] initWithFrame:CGRectZero];
    self.circleA.backgroundColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.15 alpha:0.9];
    [self.stageView addSubview:self.circleA];
    self.circleB = [[UIView alloc] initWithFrame:CGRectZero];
    self.circleB.backgroundColor = [UIColor colorWithRed:0.15 green:0.45 blue:1.0 alpha:0.9];
    [self.stageView addSubview:self.circleB];

    NSMutableArray<UIView *> *rows = [NSMutableArray array];
    for (NSInteger i = 0; i < 3; i++) {
        UIView *row = [[UIView alloc] initWithFrame:CGRectZero];
        row.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        row.layer.cornerRadius = 4.5;
        [self.stageView addSubview:row];
        [rows addObject:row];
    }
    self.fakeRows = rows;

    self.pillFx = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    self.pillFx.layer.masksToBounds = YES;
    self.pillFx.layer.borderWidth = 0.85;
    self.pillFx.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.38].CGColor;
    self.pillTint = [[UIView alloc] initWithFrame:CGRectZero];
    self.pillTint.userInteractionEnabled = NO;
    [self.pillFx.contentView addSubview:self.pillTint];
    [self.stageView addSubview:self.pillFx];

    self.blobView = [[LGCPreviewBlobView alloc] initWithFrame:CGRectZero];
    [self.stageView addSubview:self.blobView];

    NSArray<NSString *> *symbols = @[@"message.fill", @"person.2.fill", @"bell.fill", @"line.3.horizontal"];
    NSArray<NSString *> *names = @[@"Đoạn chat", @"Mọi người", @"Thông báo", @"Menu"];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:23 weight:UIImageSymbolWeightMedium];
    NSMutableArray<UIImageView *> *icons = [NSMutableArray array];
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    for (NSInteger i = 0; i < 4; i++) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbols[i] withConfiguration:cfg]];
        iv.contentMode = UIViewContentModeCenter;
        [self.stageView addSubview:iv];
        [icons addObject:iv];
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectZero];
        lab.text = names[i];
        lab.font = [UIFont systemFontOfSize:9.5];
        lab.textAlignment = NSTextAlignmentCenter;
        [self.stageView addSubview:lab];
        [labels addObject:lab];
    }
    self.iconViews = icons;
    self.labelViews = labels;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.contentView.bounds.size.width;
    CGFloat H = self.contentView.bounds.size.height;
    self.stageView.frame = CGRectMake(14, 8, W - 28, H - 16);
    [self refreshPreview];
}

- (void)refreshPreview {
    if (self.stageView.bounds.size.width < 50) return;
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:LGC_DOMAIN];
    NSString *selHex = [d stringForKey:@"selectedColorHex"] ?: @"#0084FF";
    NSString *tintHex = [d stringForKey:@"glassTintHex"] ?: @"#FFFFFF";
    CGFloat glassAlpha = [d objectForKey:@"glassAlpha"] ? (CGFloat)[d doubleForKey:@"glassAlpha"] : 0.85;
    CGFloat blobAlpha = [d objectForKey:@"blobAlpha"] ? (CGFloat)[d doubleForKey:@"blobAlpha"] : 0.95;
    CGFloat wPct = [d objectForKey:@"blobWidthPct"] ? (CGFloat)[d doubleForKey:@"blobWidthPct"] : 100.0;
    CGFloat hPct = [d objectForKey:@"blobHeightPct"] ? (CGFloat)[d doubleForKey:@"blobHeightPct"] : 100.0;
    CGFloat inset = [d objectForKey:@"pillInset"] ? (CGFloat)[d doubleForKey:@"pillInset"] : 8.0;

    NSString *hash = [NSString stringWithFormat:@"%@|%@|%.2f|%.2f|%.0f|%.0f|%.0f|%@",
                      selHex, tintHex, glassAlpha, blobAlpha, wPct, hPct, inset,
                      NSStringFromCGSize(self.stageView.bounds.size)];
    if ([hash isEqualToString:self.lastHash]) return;
    self.lastHash = hash;

    UIColor *selColor = LGCColorFromHex(selHex, [UIColor colorWithRed:0.0 green:0.52 blue:1.0 alpha:1.0]);
    UIColor *tintColor = LGCColorFromHex(tintHex, [UIColor whiteColor]);
    CGRect stage = self.stageView.bounds;

    self.circleA.frame = CGRectMake(stage.size.width * 0.02, stage.size.height - 95, 110, 110);
    self.circleA.layer.cornerRadius = 55;
    self.circleB.frame = CGRectMake(stage.size.width * 0.72, stage.size.height - 130, 90, 90);
    self.circleB.layer.cornerRadius = 45;
    CGFloat rowW[] = {0.55, 0.75, 0.4};
    for (NSInteger i = 0; i < 3; i++) {
        self.fakeRows[i].frame = CGRectMake(16, 12 + i * 17, stage.size.width * rowW[i], 9);
    }

    CGFloat pillH = 62;
    CGRect pill = CGRectMake(inset, stage.size.height - pillH - 10,
                             stage.size.width - inset * 2, pillH);
    self.pillFx.frame = pill;
    self.pillFx.layer.cornerRadius = pillH / 2.0;
    self.pillFx.alpha = glassAlpha;
    self.pillTint.frame = self.pillFx.bounds;
    self.pillTint.backgroundColor = [tintColor colorWithAlphaComponent:0.14];

    NSInteger n = 4;
    CGFloat slotW = pill.size.width / n;
    CGFloat contentH = 38;
    CGFloat contentY = CGRectGetMidY(pill) - contentH / 2.0;
    for (NSInteger i = 0; i < n; i++) {
        CGFloat cx = CGRectGetMinX(pill) + slotW * (i + 0.5);
        self.iconViews[i].frame = CGRectMake(cx - 14, contentY, 28, 23);
        self.labelViews[i].frame = CGRectMake(CGRectGetMinX(pill) + slotW * i, contentY + 26, slotW, 12);
        UIColor *c = (i == 0) ? selColor : [UIColor colorWithWhite:0.62 alpha:1.0];
        self.iconViews[i].tintColor = c;
        self.labelViews[i].textColor = c;
    }
    CGRect content0 = CGRectMake(CGRectGetMinX(pill) + 4, contentY, slotW - 8, contentH);
    CGFloat bw = MIN(MAX(content0.size.width * wPct / 100.0, 30.0), pill.size.width - 6);
    CGFloat bh = MIN(MAX(content0.size.height * hPct / 100.0, 24.0), pill.size.height - 4);
    CGFloat bcx = MIN(MAX(CGRectGetMidX(content0), CGRectGetMinX(pill) + bw / 2.0 + 3),
                      CGRectGetMaxX(pill) - bw / 2.0 - 3);
    CGFloat bcy = MIN(MAX(CGRectGetMidY(content0), CGRectGetMinY(pill) + bh / 2.0 + 2),
                      CGRectGetMaxY(pill) - bh / 2.0 - 2);
    CGRect blob = CGRectMake(bcx - bw / 2.0, bcy - bh / 2.0, bw, bh);
    self.blobView.frame = blob;
    [self.blobView applyTintColor:selColor alpha:blobAlpha];
    [self.blobView setNeedsLayout];
}

@end
