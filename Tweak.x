// LiquidGlassBar 1.5.0 — Thanh tab bar Liquid Glass mượt mà 60/120fps
// Tương thích bộ chọn ứng dụng tích hợp sẵn (enabledApps) + AltList + GPU Layer thuần.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const LGB_DOMAIN = @"com.vn.liquidglassbar";
static NSString *const LGB_PREFS_NOTIFICATION = @"com.vn.liquidglassbar/prefsChanged";
static NSString *const LGB_ROOTLESS_PLIST = @"/var/jb/var/mobile/Library/Preferences/com.vn.liquidglassbar.plist";
static NSString *const LGB_ROOTFUL_PLIST  = @"/var/mobile/Library/Preferences/com.vn.liquidglassbar.plist";

static NSString *LGBLogFilePath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *base = dirs.firstObject;
        path = base ? [base stringByAppendingPathComponent:@"LiquidGlassBar.log"]
                    : @"/var/mobile/Documents/LiquidGlassBar.log";
    });
    return path;
}

static const NSInteger LGB_BG_TAG = 712001;
static const NSInteger LGB_INDICATOR_TAG = 712002;
static const NSInteger LGB_TINT_COLOR_TAG = 712012;

static BOOL gTweakActivated = NO;
static BOOL pEnabled = YES;
static BOOL pDragEnabled = YES;
static BOOL pHaptics = YES;
static BOOL pDebug = NO;
static CGFloat pGlassAlpha = 0.85;
static CGFloat pBlobAlpha = 0.95;
static CGFloat pBlobWidthPct = 100.0;
static CGFloat pBlobHeightPct = 100.0;
static CGFloat pPillInset = 8.0;
static CGFloat pSpringPct = 55.0;
static CGFloat pStretchPct = 60.0;
static NSString *pSelectedColorHex = @"#0084FF";
static NSString *pGlassTintHex = @"#FFFFFF";

// ------------------------------------------------------------------ log (chạy nền)
static void LGBLog(NSString *fmt, ...) {
    if (!pDebug) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    static dispatch_queue_t logQueue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logQueue = dispatch_queue_create("com.vn.liquidglassbar.log", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(logQueue, ^{
        @try {
            NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                              [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                             dateStyle:NSDateFormatterNoStyle
                                                             timeStyle:NSDateFormatterMediumStyle],
                              msg];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LGBLogFilePath()];
            if (!fh) {
                [line writeToFile:LGBLogFilePath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
            } else {
                [fh seekToEndOfFile];
                [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
        } @catch (__unused NSException *e) {}
    });
}

// ------------------------------------------------------------------ prefs & AppList
static NSDictionary *LGBReadPlistDict(void) {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:LGB_ROOTLESS_PLIST];
    if (!dict) {
        dict = [NSDictionary dictionaryWithContentsOfFile:LGB_ROOTFUL_PLIST];
    }
    return dict;
}

static id LGBGetPref(NSString *key, id def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)LGB_DOMAIN);
    id obj = (__bridge_transfer id)v;
    if (obj) return obj;
    NSDictionary *dict = LGBReadPlistDict();
    id fileVal = dict[key];
    return fileVal ?: def;
}

static BOOL LGBCheckEnabledAppsObject(id enabledAppsObj, NSString *bundleID) {
    if (!enabledAppsObj) return NO;
    if ([enabledAppsObj isKindOfClass:[NSArray class]]) {
        return [(NSArray *)enabledAppsObj containsObject:bundleID];
    }
    if ([enabledAppsObj isKindOfClass:[NSDictionary class]]) {
        id flag = ((NSDictionary *)enabledAppsObj)[bundleID];
        return [flag respondsToSelector:@selector(boolValue)] ? [flag boolValue] : NO;
    }
    return NO;
}

static BOOL LGBIsAppEnabled(NSString *bundleID) {
    if (!bundleID || bundleID.length == 0) return NO;
    CFPreferencesAppSynchronize((__bridge CFStringRef)LGB_DOMAIN);

    // 1. Kiểm tra danh sách enabledApps từ bộ chọn ứng dụng tích hợp sẵn
    CFPropertyListRef cfApps = CFPreferencesCopyAppValue(CFSTR("enabledApps"),
                                                         (__bridge CFStringRef)LGB_DOMAIN);
    id appsObj = (__bridge_transfer id)cfApps;
    if (LGBCheckEnabledAppsObject(appsObj, bundleID)) {
        return YES;
    }

    // 2. Kiểm tra khoá AppEnabled-<bundleID> (tương thích ngược)
    NSString *appKey = [@"AppEnabled-" stringByAppendingString:bundleID];
    CFPropertyListRef cfFlag = CFPreferencesCopyAppValue((__bridge CFStringRef)appKey,
                                                         (__bridge CFStringRef)LGB_DOMAIN);
    id flagObj = (__bridge_transfer id)cfFlag;
    if (flagObj != nil && [flagObj respondsToSelector:@selector(boolValue)] && [flagObj boolValue]) {
        return YES;
    }

    // 3. Dự phòng đọc trực tiếp file plist rootless/rootful
    NSDictionary *dict = LGBReadPlistDict();
    if (dict) {
        if (LGBCheckEnabledAppsObject(dict[@"enabledApps"], bundleID)) {
            return YES;
        }
        id fileVal = dict[appKey];
        if (fileVal != nil && [fileVal respondsToSelector:@selector(boolValue)] && [fileVal boolValue]) {
            return YES;
        }
    }
    return NO;
}

static void LGBDiagWrite(NSString *key, id value) {
    if (value) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)value,
                                 (__bridge CFStringRef)LGB_DOMAIN);
    } else {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL,
                                 (__bridge CFStringRef)LGB_DOMAIN);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)LGB_DOMAIN);
}

static NSString *LGBNowString(void) {
    return [NSDateFormatter localizedStringFromDate:[NSDate date]
                                          dateStyle:NSDateFormatterShortStyle
                                          timeStyle:NSDateFormatterMediumStyle];
}

static void LGBLoadPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)LGB_DOMAIN);
    pEnabled          = [LGBGetPref(@"enabled", @YES) boolValue];
    pDragEnabled      = [LGBGetPref(@"dragEnabled", @YES) boolValue];
    pHaptics          = [LGBGetPref(@"haptics", @YES) boolValue];
    pDebug            = [LGBGetPref(@"debug", @NO) boolValue];
    pGlassAlpha       = [LGBGetPref(@"glassAlpha", @0.85) doubleValue];
    pBlobAlpha        = [LGBGetPref(@"blobAlpha", @0.95) doubleValue];
    pBlobWidthPct     = [LGBGetPref(@"blobWidthPct", @100.0) doubleValue];
    pBlobHeightPct    = [LGBGetPref(@"blobHeightPct", @100.0) doubleValue];
    pPillInset        = [LGBGetPref(@"pillInset", @8.0) doubleValue];
    if (pBlobWidthPct < 50 || pBlobWidthPct > 150) pBlobWidthPct = 100.0;
    if (pBlobHeightPct < 40 || pBlobHeightPct > 150) pBlobHeightPct = 100.0;
    if (pPillInset < 0 || pPillInset > 30) pPillInset = 8.0;
    pSpringPct        = [LGBGetPref(@"springPct", @55.0) doubleValue];
    pStretchPct       = [LGBGetPref(@"stretchPct", @60.0) doubleValue];
    if (pSpringPct < 0 || pSpringPct > 100) pSpringPct = 55.0;
    if (pStretchPct < 0 || pStretchPct > 100) pStretchPct = 60.0;
    pSelectedColorHex = LGBGetPref(@"selectedColorHex", @"#0084FF");
    pGlassTintHex     = LGBGetPref(@"glassTintHex", @"#FFFFFF");
    if (![pSelectedColorHex isKindOfClass:[NSString class]]) pSelectedColorHex = @"#0084FF";
    if (![pGlassTintHex isKindOfClass:[NSString class]]) pGlassTintHex = @"#FFFFFF";
}

static UIColor *LGBColorFromHex(NSString *hexStr, UIColor *fallback) {
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

static UIColor *LGBSelectedColor(void) {
    return LGBColorFromHex(pSelectedColorHex, [UIColor colorWithRed:0.0 green:0.52 blue:1.0 alpha:1.0]);
}

static UIColor *LGBGlassTintColor(void) {
    return LGBColorFromHex(pGlassTintHex, [UIColor whiteColor]);
}

static BOOL LGBLooksLikeBadge(UIView *v) {
    if (v.bounds.size.width <= 0 || v.bounds.size.width > 30 || v.bounds.size.height > 30) return NO;
    UIColor *bg = v.backgroundColor;
    if (!bg) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![bg getRed:&r green:&g blue:&b alpha:&a]) return NO;
    if (a < 0.5) return NO;
    return (r > 0.75 && g < 0.45 && b < 0.45 && v.layer.cornerRadius >= v.bounds.size.height * 0.35);
}

// ------------------------------------------------------------------ GPU Glass Blob View
@interface LGBLiquidBlobView : UIView
@property (nonatomic, strong) CAGradientLayer *bodyGradient;
@property (nonatomic, strong) CAGradientLayer *topSpecular;
@property (nonatomic, strong) CAShapeLayer *rimLayer;
@property (nonatomic, strong) CAGradientLayer *rimGradient;
- (void)applyTintColor:(UIColor *)color alpha:(CGFloat)alpha;
@end

@implementation LGBLiquidBlobView

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

        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.20;
        self.layer.shadowRadius = 6.0;
        self.layer.shadowOffset = CGSizeMake(0, 2);
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
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:b cornerRadius:r].CGPath;

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

// ------------------------------------------------------------------ manager
@interface LGBManager : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UITabBar *tabBar;
@property (nonatomic, weak) UIView *customBar;
@property (nonatomic, strong) NSArray<UIView *> *customItems;
@property (nonatomic, assign) NSInteger customSelectedIndex;
@property (nonatomic, assign) NSInteger previewIndex;
@property (nonatomic, assign) BOOL dragEngaged;
@property (nonatomic, assign) BOOL isAnimatingIndicator;
@property (nonatomic, assign) NSUInteger animationGeneration;
@property (nonatomic, assign) CGSize lastStyledBarSize;
@property (nonatomic, assign) CGFloat dragStartX;
@property (nonatomic, assign) CGFloat lastDragX;
@property (nonatomic, assign) CGFloat smoothedVelocityX;
@property (nonatomic, assign) CGFloat dragSettledCenterX;
@property (nonatomic, weak) UIView *dragBlob;
@property (nonatomic, strong) UIImpactFeedbackGenerator *hapticGen;
@property (nonatomic, strong) NSTimer *scanTimer;
@property (nonatomic, assign) NSInteger scanCount;
@property (nonatomic, copy) NSString *diagState;
@property (nonatomic, assign) BOOL dumpedBottomHierarchy;
+ (instancetype)shared;
- (void)start;
- (void)stopAndCleanup;
- (void)writeDiagState:(NSString *)state;
- (void)reloadPrefs;
- (void)styleTabBar:(UITabBar *)bar;
- (void)styleCustomBar:(UIView *)bar items:(NSArray<UIView *> *)items force:(BOOL)force;
- (void)tabBarSelectionChanged:(UITabBar *)bar;
- (void)tabBarSelectionChangedCustom;
- (void)handlePan:(UILongPressGestureRecognizer *)pan;
- (void)customItemTapped:(UIControl *)sender;
- (void)customItemGestureTapped:(UITapGestureRecognizer *)tap;
- (void)triggerTapGestureOnView:(UIView *)item;
- (void)scanTick:(NSTimer *)timer;
- (UIView *)pillBackgroundInBar:(UIView *)bar frame:(CGRect)frame belowItems:(NSArray<UIView *> *)items;
- (LGBLiquidBlobView *)indicatorInBar:(UIView *)bar belowItems:(NSArray<UIView *> *)items;
- (NSInteger)glassInsertIndexInBar:(UIView *)bar items:(NSArray<UIView *> *)items;
- (void)placeGlassViewsInBar:(UIView *)bar belowItems:(NSArray<UIView *> *)items;
- (void)refreshIndicator:(UIView *)ind;
- (CGRect)pillFrameForBar:(UIView *)bar;
- (CGRect)indicatorFrameForItemFrame:(CGRect)itemFrame limitRect:(CGRect)limit;
- (CGRect)contentRectForItem:(UIView *)item inBar:(UIView *)bar;
- (CGRect)targetFrameForIndex:(NSInteger)idx bar:(UIView *)bar items:(NSArray<UIView *> *)items;
- (CGFloat)springDamping;
- (void)animateIndicatorToIndex:(NSInteger)idx bar:(UIView *)bar items:(NSArray<UIView *> *)items completion:(void (^)(void))completion;
- (void)attachPanToBar:(UIView *)bar;
- (void)hapticTick;
- (NSArray<UIView *> *)tabBarButtons:(UITabBar *)bar;
- (NSInteger)nearestIndex:(CGFloat)x centers:(NSArray<NSNumber *> *)centers;
- (void)finishDragToIndex:(NSInteger)idx bar:(UIView *)bar isTabBar:(BOOL)isTab;
- (void)selectTabBarIndex:(NSInteger)idx bar:(UITabBar *)bar;
- (void)selectCustomIndex:(NSInteger)idx;
- (void)applyCustomSelectionVisual;
- (void)tintTree:(UIView *)v color:(UIColor *)color selected:(BOOL)selected;
- (UIWindow *)activeWindow;
- (void)appDidBecomeActive:(NSNotification *)note;
- (BOOL)viewLooksLikeTabItem:(UIView *)v;
- (void)dumpBottomHierarchy:(UIWindow *)win;
- (void)dumpView:(UIView *)v window:(UIWindow *)win depth:(NSInteger)depth into:(NSMutableString *)out lines:(NSInteger *)lines;
- (BOOL)subtree:(UIView *)v hasIconOrLabelAtDepth:(NSInteger)depth;
- (void)collectCandidatesInView:(UIView *)v window:(UIWindow *)win depth:(NSInteger)depth best:(UIView **)best bestScore:(NSInteger *)bestScore bestItems:(NSArray<UIView *> **)bestItems;
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other;
@end

@implementation LGBManager

+ (instancetype)shared {
    static LGBManager *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[LGBManager alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _customSelectedIndex = 0;
        _previewIndex = -1;
        _hapticGen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    }
    return self;
}

- (void)writeDiagState:(NSString *)state {
    if (!state || [state isEqualToString:self.diagState]) return;
    self.diagState = state;
    LGBDiagWrite(@"diag_barState", state);
}

- (void)start {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
    LGBDiagWrite(@"diag_lastLoadAt", LGBNowString());
    LGBDiagWrite(@"diag_process", bid);
    [self writeDiagState:[NSString stringWithFormat:@"Da nap vao %@, dang quet thanh bar...", bid]];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [self.scanTimer invalidate];
    self.scanTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                      target:self
                                                    selector:@selector(scanTick:)
                                                    userInfo:nil
                                                     repeats:YES];
    [self scanTick:nil];
}

- (void)stopAndCleanup {
    [self.scanTimer invalidate];
    self.scanTimer = nil;
    if (self.tabBar) {
        [[self.tabBar viewWithTag:LGB_BG_TAG] removeFromSuperview];
        [[self.tabBar viewWithTag:LGB_INDICATOR_TAG] removeFromSuperview];
    }
    if (self.customBar) {
        [[self.customBar viewWithTag:LGB_BG_TAG] removeFromSuperview];
        [[self.customBar viewWithTag:LGB_INDICATOR_TAG] removeFromSuperview];
    }
}

- (void)reloadPrefs {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (!LGBIsAppEnabled(bid)) {
        [self stopAndCleanup];
        return;
    }
    LGBLoadPrefs();
    self.lastStyledBarSize = CGSizeZero;
    if (!pEnabled) {
        [self stopAndCleanup];
        return;
    }
    if (!self.scanTimer) {
        [self start];
        return;
    }
    if (self.tabBar) [self styleTabBar:self.tabBar];
    if (self.customBar) [self styleCustomBar:self.customBar items:self.customItems force:YES];
}

// ---------------------------------------------------------- tiện ích chung
- (NSInteger)glassInsertIndexInBar:(UIView *)bar items:(NSArray<UIView *> *)items {
    for (UIView *item in items) {
        if (item.superview == bar) return (NSInteger)[bar.subviews indexOfObject:item];
    }
    return 0;
}

- (void)placeGlassViewsInBar:(UIView *)bar belowItems:(NSArray<UIView *> *)items {
    if (!bar || items.count == 0) return;
    UIView *pill = [bar viewWithTag:LGB_BG_TAG];
    UIView *ind = [bar viewWithTag:LGB_INDICATOR_TAG];
    if (pill && pill.superview != bar) pill = nil;
    if (ind && ind.superview != bar) ind = nil;
    if (!pill && !ind) return;
    UIView *firstItem = nil;
    for (UIView *item in items) {
        if (item.superview == bar) { firstItem = item; break; }
    }
    if (!firstItem) return;
    NSInteger firstIdx = (NSInteger)[bar.subviews indexOfObject:firstItem];
    NSInteger pillIdx = pill ? (NSInteger)[bar.subviews indexOfObject:pill] : NSNotFound;
    NSInteger indIdx = ind ? (NSInteger)[bar.subviews indexOfObject:ind] : NSNotFound;
    BOOL pillOK = (pillIdx != NSNotFound && pillIdx < firstIdx && (firstIdx - pillIdx) <= 2);
    BOOL indOK = (!ind || indIdx == pillIdx + 1 || (pillIdx == NSNotFound && indIdx == firstIdx - 1));
    if (pillOK && indOK) return;
    if (pill) [pill removeFromSuperview];
    if (ind) [ind removeFromSuperview];
    firstIdx = (NSInteger)[bar.subviews indexOfObject:firstItem];
    if (pill) [bar insertSubview:pill atIndex:firstIdx];
    if (ind) [bar insertSubview:ind atIndex:firstIdx + (pill ? 1 : 0)];
}

- (CGRect)pillFrameForBar:(UIView *)bar {
    CGFloat bottomInset = 0;
    UIWindow *win = bar.window;
    if (win && CGRectGetMaxY([bar convertRect:bar.bounds toView:win]) >= win.bounds.size.height - 1.0) {
        bottomInset = win.safeAreaInsets.bottom;
    }
    CGFloat contentH = bar.bounds.size.height - bottomInset;
    CGFloat pillH = contentH - 8.0;
    if (pillH < 30.0) pillH = MAX(26.0, contentH - 4.0);
    CGFloat inset = MIN(MAX(pPillInset, 0.0), bar.bounds.size.width / 4.0);
    return CGRectMake(inset, (contentH - pillH) / 2.0,
                      bar.bounds.size.width - inset * 2.0, pillH);
}

- (UIView *)pillBackgroundInBar:(UIView *)bar frame:(CGRect)frame belowItems:(NSArray<UIView *> *)items {
    UIView *existing = [bar viewWithTag:LGB_BG_TAG];
    if (existing) {
        if (!CGRectEqualToRect(existing.frame, frame)) {
            existing.frame = frame;
        }
        UIVisualEffectView *fx = nil;
        for (UIView *sub in existing.subviews) {
            if ([sub isKindOfClass:[UIVisualEffectView class]]) { fx = (UIVisualEffectView *)sub; break; }
        }
        if (fx) {
            fx.layer.cornerRadius = frame.size.height / 2.0;
            fx.alpha = pGlassAlpha;
            for (UIView *sub in fx.contentView.subviews) {
                if (sub.tag == LGB_TINT_COLOR_TAG) {
                    sub.backgroundColor = [LGBGlassTintColor() colorWithAlphaComponent:0.14];
                    sub.frame = fx.bounds;
                }
            }
        }
        [self placeGlassViewsInBar:bar belowItems:items];
        return existing;
    }
    UIView *holder = [[UIView alloc] initWithFrame:frame];
    holder.tag = LGB_BG_TAG;
    holder.userInteractionEnabled = NO;
    holder.backgroundColor = [UIColor clearColor];

    UIVisualEffectView *fx = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
    fx.frame = holder.bounds;
    fx.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    fx.layer.cornerRadius = frame.size.height / 2.0;
    fx.layer.masksToBounds = YES;
    fx.layer.borderWidth = 0.85;
    fx.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.38].CGColor;
    fx.alpha = pGlassAlpha;

    UIView *tint = [[UIView alloc] initWithFrame:fx.bounds];
    tint.tag = LGB_TINT_COLOR_TAG;
    tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tint.backgroundColor = [LGBGlassTintColor() colorWithAlphaComponent:0.14];
    tint.userInteractionEnabled = NO;
    [fx.contentView addSubview:tint];
    [holder addSubview:fx];

    NSInteger idx = [self glassInsertIndexInBar:bar items:items];
    [bar insertSubview:holder atIndex:idx];
    return holder;
}

- (void)refreshIndicator:(UIView *)ind {
    if ([ind isKindOfClass:[LGBLiquidBlobView class]]) {
        [(LGBLiquidBlobView *)ind applyTintColor:LGBSelectedColor() alpha:pBlobAlpha];
        [ind setNeedsLayout];
    }
}

- (LGBLiquidBlobView *)indicatorInBar:(UIView *)bar belowItems:(NSArray<UIView *> *)items {
    UIView *existing = [bar viewWithTag:LGB_INDICATOR_TAG];
    if ([existing isKindOfClass:[LGBLiquidBlobView class]]) {
        if (self.previewIndex < 0 && !self.isAnimatingIndicator) {
            [self placeGlassViewsInBar:bar belowItems:items];
        }
        return (LGBLiquidBlobView *)existing;
    }
    if (existing) [existing removeFromSuperview];

    LGBLiquidBlobView *ind = [[LGBLiquidBlobView alloc] initWithFrame:CGRectZero];
    ind.tag = LGB_INDICATOR_TAG;
    [ind applyTintColor:LGBSelectedColor() alpha:pBlobAlpha];

    NSInteger idx = [self glassInsertIndexInBar:bar items:items];
    [bar insertSubview:ind atIndex:idx];
    [self placeGlassViewsInBar:bar belowItems:items];
    return ind;
}

- (CGRect)indicatorFrameForItemFrame:(CGRect)itemFrame limitRect:(CGRect)limit {
    CGFloat w = itemFrame.size.width * (pBlobWidthPct / 100.0);
    CGFloat h = itemFrame.size.height * (pBlobHeightPct / 100.0);
    w = MIN(MAX(w, 40.0), MAX(40.0, limit.size.width - 6.0));
    h = MIN(MAX(h, 26.0), MAX(26.0, limit.size.height - 4.0));
    CGFloat cx = CGRectGetMidX(itemFrame);
    CGFloat minCx = CGRectGetMinX(limit) + w / 2.0 + 3.0;
    CGFloat maxCx = CGRectGetMaxX(limit) - w / 2.0 - 3.0;
    cx = (maxCx >= minCx) ? MIN(MAX(cx, minCx), maxCx) : CGRectGetMidX(limit);
    CGFloat cy = CGRectGetMidY(itemFrame);
    CGFloat minCy = CGRectGetMinY(limit) + h / 2.0 + 2.0;
    CGFloat maxCy = CGRectGetMaxY(limit) - h / 2.0 - 2.0;
    cy = (maxCy >= minCy) ? MIN(MAX(cy, minCy), maxCy) : CGRectGetMidY(limit);
    return CGRectMake(cx - w / 2.0, cy - h / 2.0, w, h);
}

- (CGRect)contentRectForItem:(UIView *)item inBar:(UIView *)bar {
    CGRect r = item.frame;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:item];
    while (stack.count > 0) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if (v != item) {
            BOOL skip = LGBLooksLikeBadge(v);
            if (!skip) {
                UIColor *bg = v.backgroundColor;
                CGFloat rr = 0, gg = 0, bb = 0, aa = 0;
                if (bg && [bg getRed:&rr green:&gg blue:&bb alpha:&aa] && aa >= 0.5 &&
                    rr > 0.75 && gg < 0.45 && bb < 0.45 &&
                    v.bounds.size.height <= 32 && v.bounds.size.width <= 52) {
                    skip = YES;
                }
            }
            if (skip) continue;
            BOOL isIconOrLabel = [v isKindOfClass:[UIImageView class]] ||
                                 [v isKindOfClass:[UILabel class]] ||
                                 [NSStringFromClass([v class]) containsString:@"Label"];
            if (isIconOrLabel) {
                r = CGRectUnion(r, [v convertRect:v.bounds toView:bar]);
            }
        }
        for (UIView *sub in v.subviews) {
            if (sub.tag != LGB_BG_TAG && sub.tag != LGB_INDICATOR_TAG) [stack addObject:sub];
        }
    }
    for (UIView *sub in bar.subviews) {
        if (![sub isKindOfClass:[UILabel class]]) continue;
        if ([sub isDescendantOfView:item]) continue;
        CGRect lf = sub.frame;
        CGFloat lcx = CGRectGetMidX(lf);
        if (lcx >= CGRectGetMinX(item.frame) - 8 && lcx <= CGRectGetMaxX(item.frame) + 8 &&
            CGRectGetMinY(lf) >= CGRectGetMinY(item.frame) - 6) {
            r = CGRectUnion(r, lf);
        }
    }
    return r;
}

- (CGRect)targetFrameForIndex:(NSInteger)idx bar:(UIView *)bar items:(NSArray<UIView *> *)items {
    CGRect pill = [self pillFrameForBar:bar];
    CGRect content = [self contentRectForItem:items[idx] inBar:bar];
    return [self indicatorFrameForItemFrame:content limitRect:pill];
}

- (CGFloat)springDamping {
    return 1.0 - 0.52 * (pSpringPct / 100.0);
}

- (void)animateIndicatorToIndex:(NSInteger)idx bar:(UIView *)bar items:(NSArray<UIView *> *)items completion:(void (^)(void))completion {
    UIView *ind = [self indicatorInBar:bar belowItems:items];
    CGRect target = [self targetFrameForIndex:idx bar:bar items:items];
    CGFloat dx = CGRectGetMidX(target) - CGRectGetMidX(ind.frame);
    if (fabs(dx) < 0.5 && CGAffineTransformIsIdentity(ind.transform)) {
        ind.frame = target;
        [self refreshIndicator:ind];
        if (completion) completion();
        return;
    }
    self.isAnimatingIndicator = YES;
    self.animationGeneration++;
    NSUInteger gen = self.animationGeneration;

    [UIView animateWithDuration:0.42 delay:0
         usingSpringWithDamping:[self springDamping] initialSpringVelocity:0.70
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
                         ind.transform = CGAffineTransformMakeTranslation(dx, 0);
                     }
                     completion:^(BOOL finished) {
                         if (gen == self.animationGeneration) {
                             self.isAnimatingIndicator = NO;
                             if (finished && self.previewIndex < 0) {
                                 ind.frame = target;
                                 ind.transform = CGAffineTransformIdentity;
                                 [self refreshIndicator:ind];
                             }
                         }
                         if (completion) completion();
                     }];
}

- (void)attachPanToBar:(UIView *)bar {
    if (!pDragEnabled) return;
    for (UIGestureRecognizer *gr in bar.gestureRecognizers) {
        if ([gr isKindOfClass:[UILongPressGestureRecognizer class]] && gr.delegate == self) return;
    }
    UILongPressGestureRecognizer *pan = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    pan.minimumPressDuration = 0;
    pan.allowableMovement = CGFLOAT_MAX;
    pan.cancelsTouchesInView = NO;
    [bar addGestureRecognizer:pan];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)hapticTick {
    if (!pHaptics) return;
    [self.hapticGen impactOccurred];
    [self.hapticGen prepare];
}

// ---------------------------------------------------------- đường A: UITabBar
- (NSArray<UIView *> *)tabBarButtons:(UITabBar *)bar {
    NSMutableArray<UIView *> *out = [NSMutableArray array];
    for (UIView *sub in bar.subviews) {
        if ([NSStringFromClass([sub class]) isEqualToString:@"UITabBarButton"]) [out addObject:sub];
    }
    [out sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    return out;
}

- (void)styleTabBar:(UITabBar *)bar {
    if (!pEnabled || bar.bounds.size.width < 50) return;
    self.tabBar = bar;
    bar.backgroundImage = [[UIImage alloc] init];
    bar.shadowImage = [[UIImage alloc] init];
    bar.backgroundColor = [UIColor clearColor];
    bar.translucent = YES;
    bar.tintColor = LGBSelectedColor();
    if (@available(iOS 10.0, *)) {
        bar.unselectedItemTintColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    }

    CGRect pillFrame = [self pillFrameForBar:bar];
    NSArray<UIView *> *buttons = [self tabBarButtons:bar];
    [self pillBackgroundInBar:bar frame:pillFrame belowItems:buttons];

    if (buttons.count == 0 || bar.items.count == 0) return;
    NSInteger sel = bar.selectedItem ? (NSInteger)[bar.items indexOfObject:bar.selectedItem] : 0;
    if (sel == NSNotFound) sel = 0;
    if (sel >= (NSInteger)buttons.count) sel = (NSInteger)buttons.count - 1;
    UIView *ind = [self indicatorInBar:bar belowItems:buttons];
    CGRect target = [self targetFrameForIndex:sel bar:bar items:buttons];
    if (self.previewIndex < 0 && !self.isAnimatingIndicator) {
        ind.frame = target;
        ind.transform = CGAffineTransformIdentity;
    }
    [self refreshIndicator:ind];
    [self attachPanToBar:bar];
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"app";
    [self writeDiagState:[NSString stringWithFormat:@"%@: Da ap kinh UITabBar chuan (%lu muc)",
                          bid, (unsigned long)bar.items.count]];
}

- (void)tabBarSelectionChanged:(UITabBar *)bar {
    if (self.previewIndex >= 0) return;
    NSArray<UIView *> *buttons = [self tabBarButtons:bar];
    if (buttons.count == 0 || bar.items.count == 0 || !bar.selectedItem) return;
    NSInteger sel = (NSInteger)[bar.items indexOfObject:bar.selectedItem];
    if (sel == NSNotFound || sel >= (NSInteger)buttons.count) return;
    [self animateIndicatorToIndex:sel bar:bar items:buttons completion:nil];
}

- (void)selectTabBarIndex:(NSInteger)idx bar:(UITabBar *)bar {
    if (idx < 0 || idx >= (NSInteger)bar.items.count) return;
    UITabBarItem *item = bar.items[idx];
    id delegate = bar.delegate;
    if ([delegate isKindOfClass:[UITabBarController class]]) {
        ((UITabBarController *)delegate).selectedIndex = idx;
    } else {
        bar.selectedItem = item;
        if ([delegate respondsToSelector:@selector(tabBar:didSelectItem:)]) {
            [delegate tabBar:bar didSelectItem:item];
        }
    }
}

// ---------------------------------------------------------- đường B: bar tự chế (Messenger, Facebook, Telegram...)
- (void)tintTree:(UIView *)v color:(UIColor *)color selected:(BOOL)selected {
    if (v.tag == LGB_BG_TAG || v.tag == LGB_INDICATOR_TAG) return;
    if (LGBLooksLikeBadge(v)) return;
    if ([v isKindOfClass:[UIImageView class]]) {
        if (![v.tintColor isEqual:color]) {
            v.tintColor = color;
        }
        UIImage *img = ((UIImageView *)v).image;
        if (img && img.renderingMode == UIImageRenderingModeAlwaysOriginal) {
            ((UIImageView *)v).image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
    } else if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lab = (UILabel *)v;
        UIColor *bg = lab.backgroundColor;
        CGFloat rr = 0, gg = 0, bb = 0, aa = 0;
        BOOL hasBg = bg && [bg getRed:&rr green:&gg blue:&bb alpha:&aa] && aa >= 0.5;
        if (!hasBg && ![lab.textColor isEqual:color]) {
            lab.textColor = color;
        }
    }
    for (UIView *sub in v.subviews) [self tintTree:sub color:color selected:selected];
}

- (void)applyCustomSelectionVisual {
    if (!self.customBar || !self.customItems) return;
    UIColor *sel = LGBSelectedColor();
    UIColor *unsel = [UIColor colorWithWhite:0.62 alpha:1.0];
    NSInteger active = (self.previewIndex >= 0) ? self.previewIndex : self.customSelectedIndex;
    for (NSInteger i = 0; i < (NSInteger)self.customItems.count; i++) {
        [self tintTree:self.customItems[i] color:(i == active ? sel : unsel) selected:(i == active)];
    }
    UIView *ind = [self indicatorInBar:self.customBar belowItems:self.customItems];
    [self refreshIndicator:ind];
}

- (void)styleCustomBar:(UIView *)bar items:(NSArray<UIView *> *)items force:(BOOL)force {
    if (!pEnabled || !bar || items.count < 2) return;
    BOOL isNewBar = (self.customBar != bar);
    BOOL sizeChanged = !CGSizeEqualToSize(bar.bounds.size, self.lastStyledBarSize);
    if (!isNewBar && !sizeChanged && !force) return;

    self.customBar = bar;
    self.customItems = items;
    self.lastStyledBarSize = bar.bounds.size;
    if (self.customSelectedIndex >= (NSInteger)items.count) self.customSelectedIndex = 0;

    CGRect pillFrame = [self pillFrameForBar:bar];
    [self pillBackgroundInBar:bar frame:pillFrame belowItems:items];

    UIView *ind = [self indicatorInBar:bar belowItems:items];
    CGRect target = [self targetFrameForIndex:self.customSelectedIndex bar:bar items:items];
    if (self.previewIndex < 0 && !self.isAnimatingIndicator) {
        ind.frame = target;
        ind.transform = CGAffineTransformIdentity;
    }
    [self refreshIndicator:ind];
    [self applyCustomSelectionVisual];
    [self attachPanToBar:bar];

    if (isNewBar) {
        for (UIView *item in items) {
            UIControl *ctrl = [item isKindOfClass:[UIControl class]] ? (UIControl *)item : nil;
            if (!ctrl) {
                for (UIView *sub in item.subviews) {
                    if ([sub isKindOfClass:[UIControl class]]) { ctrl = (UIControl *)sub; break; }
                }
            }
            if (ctrl) {
                [ctrl addTarget:self action:@selector(customItemTapped:) forControlEvents:UIControlEventTouchUpInside];
            }
            BOOL hasOurTap = NO;
            for (UIGestureRecognizer *gr in item.gestureRecognizers) {
                if ([gr isKindOfClass:[UITapGestureRecognizer class]] && gr.delegate == self) {
                    hasOurTap = YES;
                    break;
                }
            }
            if (!hasOurTap) {
                UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(customItemGestureTapped:)];
                tap.delegate = self;
                tap.cancelsTouchesInView = NO;
                [item addGestureRecognizer:tap];
            }
        }
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"app";
        [self writeDiagState:[NSString stringWithFormat:@"%@: Da ap kinh bar tu che %@ (%lu muc)",
                              bid, NSStringFromClass([bar class]), (unsigned long)items.count]];
    }
}

- (void)customItemTapped:(UIControl *)sender {
    if (!self.customBar || !self.customItems) return;
    for (NSInteger i = 0; i < (NSInteger)self.customItems.count; i++) {
        UIView *item = self.customItems[i];
        if (sender == (UIControl *)item || [sender isDescendantOfView:item] || [item isDescendantOfView:sender]) {
            self.customSelectedIndex = i;
            [self tabBarSelectionChangedCustom];
            return;
        }
    }
}

- (void)customItemGestureTapped:(UITapGestureRecognizer *)tap {
    if (!self.customBar || !self.customItems || self.dragEngaged) return;
    UIView *tappedView = tap.view;
    if (!tappedView) return;
    for (NSInteger i = 0; i < (NSInteger)self.customItems.count; i++) {
        UIView *item = self.customItems[i];
        if (tappedView == item || [tappedView isDescendantOfView:item]) {
            if (self.customSelectedIndex != i) {
                self.customSelectedIndex = i;
                [self tabBarSelectionChangedCustom];
            }
            return;
        }
    }
}

- (void)triggerTapGestureOnView:(UIView *)item {
    if (!item) return;
    NSMutableArray<UIView *> *viewsToCheck = [NSMutableArray arrayWithObject:item];
    [viewsToCheck addObjectsFromArray:item.subviews];
    for (UIView *v in viewsToCheck) {
        for (UIGestureRecognizer *gr in v.gestureRecognizers) {
            if (gr.delegate == self) continue;
            if ([gr isKindOfClass:[UITapGestureRecognizer class]]) {
                @try {
                    NSArray *targets = [gr valueForKey:@"_targets"];
                    for (id pair in targets) {
                        id target = [pair valueForKey:@"_target"];
                        SEL action = NSSelectorFromString([[pair valueForKey:@"_action"] description]);
                        if (target && action && [target respondsToSelector:action]) {
                            ((void (*)(id, SEL, id))objc_msgSend)(target, action, gr);
                            return;
                        }
                    }
                } @catch (__unused NSException *e) {}
            }
        }
    }
}

- (void)selectCustomIndex:(NSInteger)idx {
    if (!self.customBar || idx < 0 || idx >= (NSInteger)self.customItems.count) return;
    self.customSelectedIndex = idx;
    UIView *item = self.customItems[idx];
    UIControl *ctrl = [item isKindOfClass:[UIControl class]] ? (UIControl *)item : nil;
    if (!ctrl) {
        for (UIView *sub in item.subviews) {
            if ([sub isKindOfClass:[UIControl class]]) { ctrl = (UIControl *)sub; break; }
        }
    }
    if (ctrl) {
        [ctrl sendActionsForControlEvents:UIControlEventTouchUpInside];
    } else {
        [self triggerTapGestureOnView:item];
    }
    [self applyCustomSelectionVisual];
}

// ---------------------------------------------------------- kéo trượt mượt mà
- (void)tabBarSelectionChangedCustom {
    if (!self.customBar || !self.customItems || self.previewIndex >= 0) return;
    [self animateIndicatorToIndex:self.customSelectedIndex bar:self.customBar items:self.customItems completion:nil];
    [self applyCustomSelectionVisual];
}

- (NSInteger)nearestIndex:(CGFloat)x centers:(NSArray<NSNumber *> *)centers {
    NSInteger best = 0;
    CGFloat bestDist = CGFLOAT_MAX;
    for (NSInteger i = 0; i < (NSInteger)centers.count; i++) {
        CGFloat d = fabs(x - centers[i].doubleValue);
        if (d < bestDist) { bestDist = d; best = i; }
    }
    return best;
}

- (void)handlePan:(UILongPressGestureRecognizer *)pan {
    if (!pEnabled || !pDragEnabled) return;
    UIView *bar = pan.view;
    if (!bar) return;
    BOOL isTab = [bar isKindOfClass:[UITabBar class]];
    NSArray<UIView *> *items = nil;
    if (isTab) items = [self tabBarButtons:(UITabBar *)bar];
    else if (bar == self.customBar) items = self.customItems;
    if (!items || items.count < 2) return;

    NSMutableArray<NSNumber *> *centers = [NSMutableArray array];
    for (UIView *it in items) [centers addObject:@(CGRectGetMidX(it.frame))];
    CGFloat x = [pan locationInView:bar].x;
    CGFloat minX = centers.firstObject.doubleValue;
    CGFloat maxX = centers.lastObject.doubleValue;
    CGFloat clampedX = MIN(MAX(x, minX), maxX);
    NSInteger nearIdx = [self nearestIndex:clampedX centers:centers];

    UIView *ind = [self indicatorInBar:bar belowItems:items];
    CGRect pill = [self pillFrameForBar:bar];

    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            self.dragEngaged = NO;
            self.dragBlob = nil;
            self.dragStartX = x;
            self.lastDragX = x;
            self.smoothedVelocityX = 0.0;
            if (pHaptics) [self.hapticGen prepare];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!self.dragEngaged) {
                if (fabs(x - self.dragStartX) < 4.0) return;
                if (ind.frame.size.width < 10) return;
                self.dragEngaged = YES;
                self.previewIndex = nearIdx;
                self.dragBlob = ind;
                self.dragSettledCenterX = CGRectGetMidX(ind.frame);
                [self hapticTick];
                if (!isTab) [self applyCustomSelectionVisual];
            }
            UIView *blob = self.dragBlob ?: ind;
            CGFloat tx = clampedX - self.dragSettledCenterX;
            CGFloat txMin = CGRectGetMinX(pill) + 3.0 - CGRectGetMinX(blob.frame);
            CGFloat txMax = CGRectGetMaxX(pill) - 3.0 - CGRectGetMaxX(blob.frame);
            tx = MIN(MAX(tx, txMin), txMax);

            CGFloat rawDx = x - self.lastDragX;
            self.lastDragX = x;
            self.smoothedVelocityX = self.smoothedVelocityX * 0.65 + rawDx * 0.35;

            CGFloat maxStretch = 0.28 * (pStretchPct / 100.0);
            CGFloat stretch = (maxStretch > 0.001)
                ? MIN(maxStretch, fabs(self.smoothedVelocityX) / 28.0 * maxStretch) : 0.0;
            CGFloat sx = 1.05 * (1.0 + stretch);
            CGFloat sy = 1.05 / (1.0 + stretch * 0.48);

            CGAffineTransform tr = CGAffineTransformMakeTranslation(tx, 0);
            tr = CGAffineTransformScale(tr, sx, sy);
            blob.transform = tr;

            if (nearIdx != self.previewIndex) {
                self.previewIndex = nearIdx;
                [self hapticTick];
                if (!isTab) [self applyCustomSelectionVisual];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            if (!self.dragEngaged) return;
            NSInteger target = nearIdx;
            self.dragEngaged = NO;
            self.dragBlob = nil;
            self.previewIndex = -1;
            self.smoothedVelocityX = 0.0;
            [self finishDragToIndex:target bar:bar isTabBar:isTab];
            break;
        }
        default:
            break;
    }
}

- (void)finishDragToIndex:(NSInteger)idx bar:(UIView *)bar isTabBar:(BOOL)isTab {
    NSArray<UIView *> *items = isTab ? [self tabBarButtons:(UITabBar *)bar] : self.customItems;
    if (!items || idx < 0 || idx >= (NSInteger)items.count) return;
    [self animateIndicatorToIndex:idx bar:bar items:items completion:^{
        if (isTab) [self selectTabBarIndex:idx bar:(UITabBar *)bar];
        else [self selectCustomIndex:idx];
    }];
}

// ---------------------------------------------------------- quét bar tự chế
- (void)appDidBecomeActive:(NSNotification *)note {
    (void)note;
    [self reloadPrefs];
    [self scanTick:nil];
}

- (UIWindow *)activeWindow {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) return w;
        }
        if (ws.windows.count > 0) return ws.windows.firstObject;
    }
    return nil;
}

- (void)dumpBottomHierarchy:(UIWindow *)win {
    if (self.dumpedBottomHierarchy || !win || !pDebug) return;
    self.dumpedBottomHierarchy = YES;
    NSMutableString *out = [NSMutableString stringWithString:@"--- Cay view vung day ---\n"];
    NSInteger lines = 0;
    [self dumpView:win window:win depth:0 into:out lines:&lines];
    LGBLog(@"%@", out);
}

- (void)dumpView:(UIView *)v window:(UIWindow *)win depth:(NSInteger)depth into:(NSMutableString *)out lines:(NSInteger *)lines {
    if (*lines > 220) return;
    CGRect inWin = [v convertRect:v.bounds toView:win];
    if (CGRectGetMaxY(inWin) > win.bounds.size.height * 0.62 && v.bounds.size.width > 24) {
        (*lines)++;
        NSMutableString *pad = [NSMutableString string];
        for (NSInteger i = 0; i < depth; i++) [pad appendString:@"  "];
        [out appendFormat:@"%@%@ %@\n", pad, NSStringFromClass([v class]), NSStringFromCGRect(v.frame)];
    }
    if (depth < 14) {
        for (UIView *sub in v.subviews) {
            [self dumpView:sub window:win depth:depth + 1 into:out lines:lines];
        }
    }
}

- (BOOL)subtree:(UIView *)v hasIconOrLabelAtDepth:(NSInteger)depth {
    if ([v isKindOfClass:[UIImageView class]] || [v isKindOfClass:[UILabel class]]) return YES;
    if (depth >= 4) return NO;
    for (UIView *sub in v.subviews) {
        if ([self subtree:sub hasIconOrLabelAtDepth:depth + 1]) return YES;
    }
    return NO;
}

- (BOOL)viewLooksLikeTabItem:(UIView *)v {
    if ([v isKindOfClass:[UIControl class]]) return YES;
    if (v.gestureRecognizers.count > 0) return YES;
    return [self subtree:v hasIconOrLabelAtDepth:0];
}

- (void)collectCandidatesInView:(UIView *)v window:(UIWindow *)win depth:(NSInteger)depth
                           best:(UIView **)best bestScore:(NSInteger *)bestScore
                      bestItems:(NSArray<UIView *> **)bestItems {
    if (!v || depth > 14 || v.tag == LGB_BG_TAG || v.tag == LGB_INDICATOR_TAG) return;
    if ([v isKindOfClass:[UITabBar class]]) return;
    CGRect inWin = [v convertRect:v.bounds toView:win];
    CGFloat w = v.bounds.size.width, h = v.bounds.size.height;
    BOOL inBottom = CGRectGetMaxY(inWin) > win.bounds.size.height - 150.0;
    BOOL sizeOK = (h >= 40 && h <= 115 && w > win.bounds.size.width * 0.6);
    NSInteger rawCount = 0;
    for (UIView *sub in v.subviews) {
        if (sub.tag != LGB_BG_TAG && sub.tag != LGB_INDICATOR_TAG) rawCount++;
    }
    if (inBottom && sizeOK && rawCount >= 2 && rawCount <= 8) {
        NSMutableArray<UIView *> *items = [NSMutableArray array];
        for (UIView *sub in v.subviews) {
            if (sub.tag == LGB_BG_TAG || sub.tag == LGB_INDICATOR_TAG) continue;
            if (sub.bounds.size.width < 26 || sub.bounds.size.height < 20) continue;
            if (![self viewLooksLikeTabItem:sub]) continue;
            [items addObject:sub];
        }
        if (items.count >= 2 && items.count <= 7) {
            [items sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
                return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending : NSOrderedDescending;
            }];
            NSInteger score = 10;
            CGFloat firstW = items.firstObject.bounds.size.width;
            BOOL even = YES;
            for (UIView *it in items) {
                if (fabs(it.bounds.size.width - firstW) > firstW * 0.6 + 12) even = NO;
            }
            if (even) score += 5;
            if ([v isKindOfClass:[UIControl class]]) score -= 4;
            if (score > *bestScore) {
                *bestScore = score;
                *best = v;
                *bestItems = [items copy];
            }
        }
    }
    for (UIView *sub in v.subviews) {
        [self collectCandidatesInView:sub window:win depth:depth + 1 best:best bestScore:bestScore bestItems:bestItems];
    }
}

- (void)scanTick:(NSTimer *)timer {
    (void)timer;
    if (!pEnabled) return;
    if (self.previewIndex >= 0 || self.isAnimatingIndicator) return;

    self.scanCount++;
    if (self.scanCount % 10 == 1) {
        LGBDiagWrite(@"diag_scanCount", @(self.scanCount));
        if (!self.tabBar && !self.customBar) {
            [self writeDiagState:[NSString stringWithFormat:@"Da nap nhung CHUA thay thanh bar nao (da quet %ld lan)",
                                  (long)self.scanCount]];
        }
    }
    if (self.tabBar && self.tabBar.window) return;
    if (self.customBar && self.customBar.window) {
        [self styleCustomBar:self.customBar items:self.customItems force:NO];
        return;
    }
    UIWindow *win = [self activeWindow];
    if (!win) return;
    [self dumpBottomHierarchy:win];
    UIView *best = nil;
    NSInteger bestScore = -1;
    NSArray<UIView *> *bestItems = nil;
    [self collectCandidatesInView:win window:win depth:0 best:&best bestScore:&bestScore bestItems:&bestItems];
    if (best && bestItems) {
        [self styleCustomBar:best items:bestItems force:YES];
    }
}

@end

// ------------------------------------------------------------------ hooks
%group LiquidGlassBarHooks

%hook UITabBar
- (void)layoutSubviews {
    %orig;
    [[LGBManager shared] styleTabBar:self];
}
- (void)setSelectedItem:(UITabBarItem *)item {
    %orig;
    [[LGBManager shared] tabBarSelectionChanged:self];
}
%end

%end

// ------------------------------------------------------------------ ctor & kích hoạt động
static void LGBActivateIfNeeded(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid) return;
    if (!LGBIsAppEnabled(bid)) {
        if (gTweakActivated) {
            [[LGBManager shared] stopAndCleanup];
        }
        return;
    }
    LGBLoadPrefs();
    if (!gTweakActivated) {
        gTweakActivated = YES;
        %init(LiquidGlassBarHooks);
    }
    [[LGBManager shared] start];
}

static void LGBPrefsChanged(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object,
                            CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gTweakActivated) {
            LGBActivateIfNeeded();
        } else {
            [[LGBManager shared] reloadPrefs];
        }
    });
}

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid ||
            [bid isEqualToString:@"com.apple.springboard"] ||
            [bid isEqualToString:@"com.apple.Preferences"] ||
            [bid hasPrefix:@"com.apple.WebKit"]) {
            return;
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            LGBPrefsChanged, (__bridge CFStringRef)LGB_PREFS_NOTIFICATION, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        LGBActivateIfNeeded();
    }
}
