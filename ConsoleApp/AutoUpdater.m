#import "AutoUpdater.h"
#import <stdlib.h>
#import <stdarg.h>
#import <objc/message.h>

static BOOL gDownloadedNew = NO;
static NSMutableString *gDiag = nil;

@implementation AutoUpdater

+ (NSString *)repo {
    NSString *repo = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"LCProxyUpdateRepo"];
    return repo.length ? repo : @"koast18/livecontainer-kingcard-proxy";
}

+ (void)diag:(NSString *)fmt, ... {
    if (!gDiag) gDiag = [NSMutableString string];
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    [gDiag appendFormat:@"%@\n", s];
}

+ (NSString *)diagnostics {
    return gDiag ?: @"";
}

+ (void)reset {
    gDiag = nil;
    gDownloadedNew = NO;
}

+ (BOOL)downloadedAnything {
    return gDownloadedNew;
}

+ (NSString *)lcRootDirectory {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *candidates = [NSMutableArray array];
    const char *home = getenv("LC_HOME_PATH");
    if (home && home[0]) {
        NSString *h = [NSString stringWithUTF8String:home];
        [candidates addObject:h];
        [candidates addObject:[h stringByAppendingPathComponent:@"Documents"]];
    }
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count) [candidates addObject:paths[0]];
    for (NSString *c in candidates) {
        if (!c.length) continue;
        NSString *probe = [c stringByAppendingPathComponent:@"Tweaks"];
        NSError *err = nil;
        if ([fm createDirectoryAtPath:probe withIntermediateDirectories:YES attributes:nil error:&err]) {
            [self diag:@"[路径] 可写共享根: %@", c];
            return c;
        }
        [self diag:@"[路径] 候选不可写 %@: %@", c, err.localizedDescription ?: @"?"];
    }
    return nil;
}

+ (NSData *)fetchURL:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 60;
    [req setValue:@"LiveProxyConsole/1.0" forHTTPHeaderField:@"User-Agent"];
    NSHTTPURLResponse *resp = nil;
    NSError *err = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
    if (err) {
        [self diag:@"[请求] %@ 错误: %@ (%ld)", urlString, err.localizedDescription ?: @"?", (long)err.code];
        return nil;
    }
    if (resp.statusCode == 200 && data) {
        [self diag:@"[请求] %@ HTTP 200 %ld bytes", urlString, (long)data.length];
        return data;
    }
    [self diag:@"[请求] %@ HTTP %ld", urlString, (long)resp.statusCode];
    return nil;
}

+ (NSData *)apiLatestRelease {
    NSArray *urls = @[
        [NSString stringWithFormat:@"https://gh-proxy.com/https://api.github.com/repos/%@/releases/latest", self.repo],
        [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", self.repo],
    ];
    for (NSString *u in urls) {
        NSData *d = [self fetchURL:u];
        if (d) return d;
    }
    return nil;
}

+ (NSString *)latestDylibAssetName {
    NSData *data = [self apiLatestRelease];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *assets = obj[@"assets"];
    NSString *best = nil;
    NSArray *bestVer = nil;
    for (NSDictionary *a in assets) {
        NSString *name = a[@"name"];
        if (![name hasPrefix:@"LCProxyControl-"] || ![name hasSuffix:@".dylib"]) continue;
        NSString *ver = [name substringFromIndex:@"LCProxyControl-".length];
        ver = [ver substringToIndex:ver.length - 6];
        NSArray *parts = [ver componentsSeparatedByString:@"."];
        BOOL numeric = YES;
        for (NSString *p in parts) {
            if (p.intValue == 0 && ![p isEqualToString:@"0"]) numeric = NO;
        }
        if (!numeric) continue;
        if (!bestVer || [self versionArray:parts isNewerThan:bestVer]) {
            best = name;
            bestVer = parts;
        }
    }
    if (best) [self diag:@"[资产] 最新 dylib: %@", best];
    else [self diag:@"[资产] 未找到 LCProxyControl-*.dylib 资产"];
    return best;
}

+ (BOOL)versionArray:(NSArray *)a isNewerThan:(NSArray *)b {
    NSUInteger n = MAX(a.count, b.count);
    for (NSUInteger i = 0; i < n; i++) {
        int x = i < a.count ? [a[i] intValue] : 0;
        int y = i < b.count ? [b[i] intValue] : 0;
        if (x != y) return x > y;
    }
    return NO;
}

+ (NSString *)downloadURLForAsset:(NSString *)name {
    NSData *data = [self apiLatestRelease];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    for (NSDictionary *a in obj[@"assets"]) {
        if ([a[@"name"] isEqualToString:name]) {
            return a[@"browser_download_url"];
        }
    }
    return nil;
}

+ (BOOL)downloadAsset:(NSString *)name toDirectory:(NSString *)dir {
    NSString *browser = [self downloadURLForAsset:name];
    if (!browser) return NO;
    NSArray *urls = @[
        [NSString stringWithFormat:@"https://gh-proxy.com/%@", browser],
        browser,
    ];
    for (NSString *u in urls) {
        NSData *data = [self fetchURL:u];
        if (!data) continue;
        NSString *dst = [dir stringByAppendingPathComponent:name];
        NSError *err = nil;
        if ([data writeToFile:dst options:NSDataWritingAtomic error:&err]) {
            [self diag:@"[写入] %@", dst];
            return YES;
        }
        [self diag:@"[写入] 失败: %@", err.localizedDescription ?: @"?"];
    }
    return NO;
}

+ (void)cleanOldDylibsIn:(NSString *)dir keep:(NSString *)keep {
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *f in files) {
        if ([f hasPrefix:@"LCProxyControl-"] && [f hasSuffix:@".dylib"] && ![f isEqualToString:keep]) {
            [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
            [self diag:@"[清理] %@", f];
        }
    }
}

+ (NSArray<NSString *> *)tweakDirectories {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSString *root = [self lcRootDirectory];
    if (root) [dirs addObject:[root stringByAppendingPathComponent:@"Tweaks"]];

    // 共享 App 模式使用 App Group 下 LiveContainer/Tweaks 的子文件夹。
    // 根目录里的 dylib 可能不会被 LiveContainer 签名；放到子文件夹后，
    // 用户在共享 App 设置里选择该文件夹即可触发签名。
    Class lcSharedUtils = NSClassFromString(@"LCSharedUtils");
    if (lcSharedUtils) {
        SEL sel = NSSelectorFromString(@"appGroupID");
        NSString *groupID = ((NSString *(*)(id, SEL))objc_msgSend)(lcSharedUtils, sel);
        if ([groupID isKindOfClass:[NSString class]] && groupID.length) {
            NSURL *groupURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupID];
            if (groupURL) {
                NSString *sharedRoot = [[groupURL URLByAppendingPathComponent:@"LiveContainer/Tweaks"] path];
                [dirs addObject:[sharedRoot stringByAppendingPathComponent:@"LCProxyControl"]];
                // 清理共享根目录里未签名的旧 dylib，避免 TweakLoader 直接加载报签名错误。
                [self cleanOldDylibsIn:sharedRoot keep:nil];
            }
        }
    }

    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *d in dirs) {
        if (d.length && ![out containsObject:d]) [out addObject:d];
    }
    return out;
}

+ (NSString *)runAutoUpdateWithProgress:(KPAutoUpdateProgress)progress {
    [self reset];
    void (^stage)(NSString *, double) = ^(NSString *s, double f) {
        if (progress) progress(s, f);
    };
    stage(@"定位 LiveContainer Tweaks 目录…", -1);
    NSArray<NSString *> *tweakDirs = [self tweakDirectories];
    if (tweakDirs.count == 0) {
        NSString *msg = @"无法定位 LiveContainer Tweaks 目录（普通目录和共享 App 目录均不可写）。";
        [self diag:msg];
        return [self diagnostics];
    }
    for (NSString *dir in tweakDirs) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        [self diag:@"[目录] %@", dir];
    }

    stage(@"检查最新版本…", -1);
    NSString *asset = [self latestDylibAssetName];
    if (!asset) {
        [self diag:@"未找到可下载的 dylib 资产（请检查 Release 是否已构建）。"];
        return [self diagnostics];
    }

    NSString *firstDst = [tweakDirs[0] stringByAppendingPathComponent:asset];
    if (![[NSFileManager defaultManager] fileExistsAtPath:firstDst]) {
        stage([NSString stringWithFormat:@"下载 %@…", asset], -1);
        if (![self downloadAsset:asset toDirectory:tweakDirs[0]]) {
            [self diag:@"下载失败。"];
            return [self diagnostics];
        }
        gDownloadedNew = YES;
    } else {
        [self diag:@"已是最新：%@", asset];
    }

    // 复制到其它 Tweaks 目录（普通目录 + 共享 App 目录）。
    for (NSUInteger i = 1; i < tweakDirs.count; i++) {
        NSString *dst = [tweakDirs[i] stringByAppendingPathComponent:asset];
        NSError *err = nil;
        if (![[NSFileManager defaultManager] fileExistsAtPath:dst]) {
            if (![[NSFileManager defaultManager] copyItemAtPath:firstDst toPath:dst error:&err]) {
                [self diag:@"[复制] 到 %@ 失败: %@", dst, err.localizedDescription ?: @"?"];
            } else {
                [self diag:@"[复制] %@", dst];
                gDownloadedNew = YES;
            }
        }
    }

    for (NSString *dir in tweakDirs) {
        [self cleanOldDylibsIn:dir keep:asset];
    }
    return [self diagnostics];
}

@end
