#import "LGCAppListController.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const LGC_APP_DOMAIN = @"com.vn.liquidglassbar";
static NSString *const LGC_APP_PREFS_NOTIFICATION = @"com.vn.liquidglassbar/prefsChanged";
static NSString *const LGC_APP_ROOTLESS_PLIST = @"/var/jb/var/mobile/Library/Preferences/com.vn.liquidglassbar.plist";
static NSString *const LGC_APP_ROOTFUL_PLIST  = @"/var/mobile/Library/Preferences/com.vn.liquidglassbar.plist";

@interface LGCAppInfo : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, assign) BOOL isSystem;
@property (nonatomic, strong) UIImage *icon;
@end

@implementation LGCAppInfo
@end

@interface LGCAppListController ()
@property (nonatomic, strong) NSArray<LGCAppInfo *> *userApps;
@property (nonatomic, strong) NSArray<LGCAppInfo *> *systemApps;
@property (nonatomic, strong) NSArray<LGCAppInfo *> *filteredApps;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedBundleIDs;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, assign) BOOL isSearching;
@end

@implementation LGCAppListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Chọn ứng dụng áp dụng";
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.rowHeight = 52.0;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Tìm tên ứng dụng hoặc Bundle ID...";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Bỏ chọn hết"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(clearAllSelection)];

    [self loadSavedSelection];
    [self loadInstalledApplications];
}

- (void)loadSavedSelection {
    self.selectedBundleIDs = [NSMutableSet set];
    CFPreferencesAppSynchronize((__bridge CFStringRef)LGC_APP_DOMAIN);

    CFPropertyListRef cfApps = CFPreferencesCopyAppValue(CFSTR("enabledApps"), (__bridge CFStringRef)LGC_APP_DOMAIN);
    id arr = (__bridge_transfer id)cfApps;
    if ([arr isKindOfClass:[NSArray class]]) {
        [self.selectedBundleIDs addObjectsFromArray:arr];
    }

    NSDictionary *fileDict = [NSDictionary dictionaryWithContentsOfFile:LGC_APP_ROOTLESS_PLIST];
    if (!fileDict) {
        fileDict = [NSDictionary dictionaryWithContentsOfFile:LGC_APP_ROOTFUL_PLIST];
    }
    if ([fileDict[@"enabledApps"] isKindOfClass:[NSArray class]]) {
        [self.selectedBundleIDs addObjectsFromArray:fileDict[@"enabledApps"]];
    }
    for (NSString *k in fileDict) {
        if ([k hasPrefix:@"AppEnabled-"] && [fileDict[k] boolValue]) {
            [self.selectedBundleIDs addObject:[k substringFromIndex:@"AppEnabled-".length]];
        }
    }
}

- (void)saveSelection {
    NSArray<NSString *> *sortedIDs = [[self.selectedBundleIDs allObjects] sortedArrayUsingSelector:@selector(compare:)];

    // 1. Lưu qua CFPreferences & NSUserDefaults
    CFPreferencesSetAppValue(CFSTR("enabledApps"), (__bridge CFPropertyListRef)sortedIDs, (__bridge CFStringRef)LGC_APP_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)LGC_APP_DOMAIN);

    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:LGC_APP_DOMAIN];
    [defaults setObject:sortedIDs forKey:@"enabledApps"];
    [defaults synchronize];

    // 2. Ghi trực tiếp xuống file plist rootless (đảm bảo app sandbox đọc được ngay lập tức)
    NSMutableDictionary *diskDict = [[NSDictionary dictionaryWithContentsOfFile:LGC_APP_ROOTLESS_PLIST] mutableCopy];
    if (!diskDict) {
        diskDict = [[defaults dictionaryRepresentation] mutableCopy] ?: [NSMutableDictionary dictionary];
    }
    diskDict[@"enabledApps"] = sortedIDs;
    [diskDict writeToFile:LGC_APP_ROOTLESS_PLIST atomically:YES];

    // 3. Bắn thông báo cập nhật tức thì tới các ứng dụng đang chạy
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)LGC_APP_PREFS_NOTIFICATION, NULL, NULL, YES);
}

- (void)clearAllSelection {
    [self.selectedBundleIDs removeAllObjects];
    [self saveSelection];
    [self.tableView reloadData];
}

- (void)loadInstalledApplications {
    NSMutableArray<LGCAppInfo *> *users = [NSMutableArray array];
    NSMutableArray<LGCAppInfo *> *systems = [NSMutableArray array];

    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defSel = NSSelectorFromString(@"defaultWorkspace");
    if (wsClass && [wsClass respondsToSelector:defSel]) {
        id ws = ((id (*)(id, SEL))objc_msgSend)(wsClass, defSel);
        SEL allSel = NSSelectorFromString(@"allInstalledApplications");
        if (![ws respondsToSelector:allSel]) {
            allSel = NSSelectorFromString(@"allApplications");
        }
        if (ws && [ws respondsToSelector:allSel]) {
            NSArray *proxies = ((id (*)(id, SEL))objc_msgSend)(ws, allSel);
            SEL bidSel = NSSelectorFromString(@"applicationIdentifier");
            SEL nameSel = NSSelectorFromString(@"localizedName");
            SEL typeSel = NSSelectorFromString(@"applicationType");
            SEL tagsSel = NSSelectorFromString(@"appTags");
            SEL iconSel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
            CGFloat scale = [UIScreen mainScreen].scale;

            for (id proxy in proxies) {
                if (![proxy respondsToSelector:bidSel]) continue;
                NSString *bid = ((id (*)(id, SEL))objc_msgSend)(proxy, bidSel);
                if (![bid isKindOfClass:[NSString class]] || bid.length == 0) continue;
                if ([bid isEqualToString:@"com.apple.springboard"] ||
                    [bid isEqualToString:@"com.apple.Preferences"]) {
                    continue;
                }

                NSString *appType = [proxy respondsToSelector:typeSel]
                    ? ((id (*)(id, SEL))objc_msgSend)(proxy, typeSel) : @"User";
                BOOL isSys = [appType isKindOfClass:[NSString class]] && [appType isEqualToString:@"System"];

                if (isSys && [proxy respondsToSelector:tagsSel]) {
                    NSArray *tags = ((id (*)(id, SEL))objc_msgSend)(proxy, tagsSel);
                    if ([tags isKindOfClass:[NSArray class]] && [tags containsObject:@"hidden"]) {
                        continue;
                    }
                }

                NSString *name = [proxy respondsToSelector:nameSel]
                    ? ((id (*)(id, SEL))objc_msgSend)(proxy, nameSel) : nil;
                if (![name isKindOfClass:[NSString class]] || name.length == 0) {
                    name = bid;
                }

                UIImage *icon = nil;
                if ([UIImage respondsToSelector:iconSel]) {
                    icon = ((UIImage *(*)(id, SEL, NSString *, int, CGFloat))objc_msgSend)([UIImage class], iconSel, bid, 0, scale);
                }

                LGCAppInfo *info = [[LGCAppInfo alloc] init];
                info.name = name;
                info.bundleID = bid;
                info.isSystem = isSys;
                info.icon = icon;

                if (isSys) [systems addObject:info];
                else [users addObject:info];
            }
        }
    }

    NSComparator sortByName = ^NSComparisonResult(LGCAppInfo *a, LGCAppInfo *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    };
    [users sortUsingComparator:sortByName];
    [systems sortUsingComparator:sortByName];

    self.userApps = users;
    self.systemApps = systems;
    [self.tableView reloadData];
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0) {
        self.isSearching = NO;
        self.filteredApps = nil;
    } else {
        self.isSearching = YES;
        NSMutableArray<LGCAppInfo *> *matches = [NSMutableArray array];
        for (LGCAppInfo *app in self.userApps) {
            if ([app.name localizedCaseInsensitiveContainsString:query] ||
                [app.bundleID localizedCaseInsensitiveContainsString:query]) {
                [matches addObject:app];
            }
        }
        for (LGCAppInfo *app in self.systemApps) {
            if ([app.name localizedCaseInsensitiveContainsString:query] ||
                [app.bundleID localizedCaseInsensitiveContainsString:query]) {
                [matches addObject:app];
            }
        }
        self.filteredApps = matches;
    }
    [self.tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    if (self.isSearching) return 1;
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (self.isSearching) {
        return [NSString stringWithFormat:@"Kết quả tìm kiếm (%lu)", (unsigned long)self.filteredApps.count];
    }
    if (section == 0) {
        return [NSString stringWithFormat:@"Ứng dụng đã cài (%lu)", (unsigned long)self.userApps.count];
    }
    return [NSString stringWithFormat:@"Ứng dụng hệ thống (%lu)", (unsigned long)self.systemApps.count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (self.isSearching) return self.filteredApps.count;
    return (section == 0) ? self.userApps.count : self.systemApps.count;
}

- (LGCAppInfo *)appInfoAtIndexPath:(NSIndexPath *)indexPath {
    if (self.isSearching) return self.filteredApps[indexPath.row];
    return (indexPath.section == 0) ? self.userApps[indexPath.row] : self.systemApps[indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"LGCAppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
    }
    LGCAppInfo *app = [self appInfoAtIndexPath:indexPath];
    cell.textLabel.text = app.name;
    cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
    cell.detailTextLabel.text = app.bundleID;
    cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.imageView.image = app.icon;
    cell.imageView.layer.cornerRadius = 6.5;
    cell.imageView.layer.masksToBounds = YES;

    BOOL checked = [self.selectedBundleIDs containsObject:app.bundleID];
    cell.accessoryType = checked ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    LGCAppInfo *app = [self appInfoAtIndexPath:indexPath];
    if ([self.selectedBundleIDs containsObject:app.bundleID]) {
        [self.selectedBundleIDs removeObject:app.bundleID];
    } else {
        [self.selectedBundleIDs addObject:app.bundleID];
    }
    [self saveSelection];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

@end
