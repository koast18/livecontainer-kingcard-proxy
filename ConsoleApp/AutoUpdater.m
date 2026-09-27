#import "AutoUpdater.h"
#import <stdlib.h>
#import <stdarg.h>
#import <objc/message.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <mach-o/loader.h>

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
        // LC_HOME_PATH names the container root. Private-app tweaks are only
        // loaded from <LC_HOME_PATH>/Documents/Tweaks, never from its root.
        if (![[h lastPathComponent] isEqualToString:@"Documents"]) {
            h = [h stringByAppendingPathComponent:@"Documents"];
        }
        [candidates addObject:h];
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

+ (NSString *)updateTag {
    NSString *tag = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"LCProxyUpdateTag"];
    return tag.length ? tag : nil;
}

+ (NSData *)apiRelease {
    NSString *tag = [self updateTag];
    NSString *path = tag ? [NSString stringWithFormat:@"releases/tags/%@", tag] : @"releases/latest";
    NSArray *urls = @[
        [NSString stringWithFormat:@"https://gh-proxy.com/https://api.github.com/repos/%@/%@", self.repo, path],
        [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@", self.repo, path],
    ];
    for (NSString *u in urls) {
        NSData *d = [self fetchURL:u];
        if (d) return d;
    }
    return nil;
}

+ (NSString *)latestDylibAssetName {
    NSData *data = [self apiRelease];
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
    NSData *data = [self apiRelease];
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

// 列出目录里所有 LCProxyControl 相关文件（**含** .dylib 与 .dylib.disabled）。
//
// 旧的清理函数只匹配 ".dylib" 后缀，因此 .dylib.disabled 永远不会被回收 —— 而新版
// 恰恰要以 .disabled 形式暂存，所以必须同时覆盖两种后缀。
+ (NSArray<NSString *> *)lcProxyControlFilesIn:(NSString *)dir {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *f in files) {
        if ([f hasPrefix:@"LCProxyControl-"] &&
            ([f hasSuffix:@".dylib"] || [f hasSuffix:@".dylib.disabled"])) {
            [out addObject:f];
        }
    }
    return out;
}

static BOOL LCProxyIsDisabledName(NSString *name) {
    return [name hasSuffix:@".disabled"];
}

// 从 "LCProxyControl-0.5.72.dylib[.disabled]" 取出 "0.5.72"，用于挑最新版本。
static NSString *LCProxyVersionFromName(NSString *name) {
    NSString *s = name;
    if ([s hasSuffix:@".disabled"]) s = [s substringToIndex:s.length - @".disabled".length];
    if (![s hasSuffix:@".dylib"]) return @"";
    s = [s substringToIndex:s.length - @".dylib".length];
    NSRange dash = [s rangeOfString:@"-" options:NSBackwardsSearch];
    return dash.location == NSNotFound ? @"" : [s substringFromIndex:dash.location + 1];
}

// ★ 核心不变量：目录里**最多只能有一个已启用（非 .disabled）的 LCProxyControl-*.dylib**。
//
// 为什么这是硬要求：LiveContainer 的 TweakLoader 会加载 Tweaks 目录里的**每一个** dylib
// 文件。若新旧两份同时存在（升级过程中极易发生），同一个进程里会进入两个 LCProxyControl
// 映像 —— 同名 ObjC 类被注册两次、另一份的实现与实例变量被交叉使用，表现为
// **打开任何 App 都闪退**。实测出现过（dylib-loads.log 里同一个 pid 先后加载了 0.5.57
// 与 0.5.56）。
//
// 同时必须避免另一个极端：如果为了"只留一个"就把旧版删掉、而新版还没签名，用户就会
// 在签名之前彻底失去可用 dylib。两个目标靠 **.disabled 暂存** 同时满足：
//   · TweakLoader 跳过以 .disabled 结尾的文件（不会被加载 → 不会冲突）；
//   · LiveContainer 的签名页仍然会给 .disabled 文件签名（它先剥掉 .disabled 再判 .dylib）。
// 因此把新版下载成 "<资产名>.disabled"，用户签名它、旧版继续生效，两边都不受损；
// 下次打开控制台时本方法把它改名为正式名并删掉旧版，完成切换。
//
// 返回目录中"当前启用"的 dylib 文件名（可能为 nil）。
+ (NSString *)enforceSingleActiveDylibIn:(NSString *)dir desiredAsset:(NSString *)asset {
    if (!dir.length || !asset.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *desiredActive = asset;
    NSString *desiredStaged = [asset stringByAppendingString:@".disabled"];

    // 0) 兼容旧版控制台留下的"未签名新版"：把它转为 .disabled 暂存。
    //    旧逻辑会把它当作正常文件留在目录里 —— 它既不能加载（未签名），又和旧版共存，
    //    用户一签名就变成"两份都已签名"从而闪退。这里就地纠正。
    {
        NSString *p = [dir stringByAppendingPathComponent:desiredActive];
        if ([fm fileExistsAtPath:p] && !LCProxyCodeSignatureValid(p)) {
            NSString *sp = [dir stringByAppendingPathComponent:desiredStaged];
            [fm removeItemAtPath:sp error:nil];
            if ([fm moveItemAtPath:p toPath:sp error:nil]) {
                [self diag:@"[暂存] 未签名的新版已转为 %@（不会被加载，等待签名）", desiredStaged];
            }
        }
    }

    NSArray<NSString *> *files = [self lcProxyControlFilesIn:dir];

    // 1) 暂存的新版若已被签名 → 激活它（改名去掉 .disabled）。
    {
        BOOL stagedExists = [files containsObject:desiredStaged];
        if (stagedExists &&
            LCProxyCodeSignatureValid([dir stringByAppendingPathComponent:desiredStaged])) {
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:desiredActive] error:nil];
            if ([fm moveItemAtPath:[dir stringByAppendingPathComponent:desiredStaged]
                            toPath:[dir stringByAppendingPathComponent:desiredActive] error:nil]) {
                [self diag:@"[启用] 已签名的新版生效：%@", desiredActive];
            }
            files = [self lcProxyControlFilesIn:dir];
        }
    }

    // 2) 选出唯一保留的"已启用"文件：优先目标版本，否则取最新的**已签名**版本。
    NSString *keepActive = nil;
    {
        NSString *p = [dir stringByAppendingPathComponent:desiredActive];
        if ([fm fileExistsAtPath:p] && LCProxyCodeSignatureValid(p)) {
            keepActive = desiredActive;
        } else {
            NSString *bestVer = nil;
            for (NSString *f in files) {
                if (LCProxyIsDisabledName(f)) continue;
                NSString *full = [dir stringByAppendingPathComponent:f];
                if (!LCProxyCodeSignatureValid(full)) continue;
                NSString *v = LCProxyVersionFromName(f);
                if (!bestVer || [v compare:bestVer options:NSNumericSearch] == NSOrderedDescending) {
                    bestVer = v;
                    keepActive = f;
                }
            }
        }
    }

    // 3) 删除其余一切：其它已启用文件、以及除"待签名暂存"之外的所有暂存文件。
    //    这一步同时修掉历史遗留（目录里已经躺着多份已签名 dylib 的情况）。
    for (NSString *f in files) {
        if ([f isEqualToString:keepActive]) continue;
        if ([f isEqualToString:desiredStaged]) continue;   // 等用户签名
        if (!keepActive && LCProxyIsDisabledName(f)) continue; // 没有任何可用版本时保留暂存
        NSString *full = [dir stringByAppendingPathComponent:f];
        if ([fm removeItemAtPath:full error:nil]) {
            [self diag:@"[清理] %@", f];
        }
    }

    if (!keepActive) {
        [self diag:@"[警告] 目录中暂无已启用的 dylib；请签名 %@ 后重开本控制台。", desiredStaged];
    }
    return keepActive;
}

struct lc_code_signature_command {
    uint32_t cmd;
    uint32_t cmdsize;
    uint32_t dataoff;
    uint32_t datasize;
};

static BOOL LCProxyCodeSignatureValid(NSString *path) {
    if (!path.length) return NO;
    int fd = open(path.UTF8String, O_RDONLY);
    if (fd < 0) return NO;

    struct mach_header_64 header;
    if (read(fd, &header, sizeof(header)) != (ssize_t)sizeof(header) || header.magic != MH_MAGIC_64) {
        close(fd);
        return NO;
    }

    struct lc_code_signature_command cs = {0};
    BOOL found = NO;
    off_t off = (off_t)sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header.ncmds && i < 64; i++) {
        struct load_command lc = {0};
        if (lseek(fd, off, SEEK_SET) == -1) break;
        if (read(fd, &lc, sizeof(lc)) != (ssize_t)sizeof(lc)) break;
        if (lc.cmd == LC_CODE_SIGNATURE && lc.cmdsize >= sizeof(cs)) {
            if (lseek(fd, off, SEEK_SET) != -1 && read(fd, &cs, sizeof(cs)) == (ssize_t)sizeof(cs)) {
                found = YES;
            }
            break;
        }
        off += lc.cmdsize;
    }

    if (!found || cs.dataoff == 0 || cs.datasize == 0) {
        close(fd);
        return NO;
    }

    fsignatures_t siginfo;
    memset(&siginfo, 0, sizeof(siginfo));
    siginfo.fs_file_start = 0;
    siginfo.fs_blob_start = (void *)(long)cs.dataoff;
    siginfo.fs_blob_size = cs.datasize;
    if (fcntl(fd, F_ADDFILESIGS_RETURN, &siginfo) == -1) {
        close(fd);
        return NO;
    }

    char messageBuffer[512];
    messageBuffer[0] = '\0';
    fchecklv_t checkInfo;
    memset(&checkInfo, 0, sizeof(checkInfo));
    checkInfo.lv_error_message_size = sizeof(messageBuffer);
    checkInfo.lv_error_message = messageBuffer;
    checkInfo.lv_file_start = 0;
    int checkResult = fcntl(fd, F_CHECK_LV, &checkInfo);
    close(fd);
    return checkResult == 0;
}

+ (NSString *)normalTweaksDirectory {
    NSString *root = [self lcRootDirectory];
    return root ? [root stringByAppendingPathComponent:@"Tweaks"] : nil;
}

+ (NSString *)sharedTweaksDirectory {
    Class lcSharedUtils = NSClassFromString(@"LCSharedUtils");
    if (!lcSharedUtils) return nil;
    SEL sel = NSSelectorFromString(@"appGroupID");
    if (![lcSharedUtils respondsToSelector:sel]) return nil;
    NSString *groupID = ((NSString *(*)(id, SEL))objc_msgSend)(lcSharedUtils, sel);
    if (![groupID isKindOfClass:[NSString class]] || groupID.length == 0) return nil;
    NSURL *groupURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (!groupURL) return nil;
    return [[groupURL URLByAppendingPathComponent:@"LiveContainer/Tweaks"] path];
}

+ (NSString *)runAutoUpdateWithProgress:(KPAutoUpdateProgress)progress {
    [self reset];
    void (^stage)(NSString *, double) = ^(NSString *s, double f) {
        if (progress) progress(s, f);
    };
    stage(@"定位 LiveContainer Tweaks 目录…", -1);
    NSString *normalTweaks = [self normalTweaksDirectory];
    NSString *sharedTweaks = [self sharedTweaksDirectory];
    if (!normalTweaks) {
        NSString *msg = @"无法定位 LiveContainer Tweaks 目录（LC_HOME_PATH 不可写）。";
        [self diag:msg];
        return [self diagnostics];
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:normalTweaks withIntermediateDirectories:YES attributes:nil error:nil];
    [self diag:@"[目录] 普通 Tweaks: %@", normalTweaks];
    if (sharedTweaks) {
        [[NSFileManager defaultManager] createDirectoryAtPath:sharedTweaks withIntermediateDirectories:YES attributes:nil error:nil];
        [self diag:@"[目录] 共享 App Tweaks: %@", sharedTweaks];
    }

    stage(@"检查最新版本…", -1);
    NSString *asset = [self latestDylibAssetName];
    if (!asset) {
        [self diag:@"未找到可下载的 dylib 资产（请检查 Release 是否已构建）。"];
        return [self diagnostics];
    }

    // ★ 新版必须下载为 "<资产名>.disabled"，而不是直接落到正式名。
    //
    // 直接落正式名会让"新版"与"旧版"在 Tweaks 目录里共存 —— TweakLoader 会加载每一个
    // dylib，于是同名 ObjC 类被注册两次 → 打开任何 App 都闪退。而 .disabled 结尾会被
    // TweakLoader 跳过，同时 LiveContainer 的签名页仍会给它签名（先剥 .disabled 再判
    // .dylib），所以用户照常签名即可，旧版在此期间继续可用。
    NSString *normalDst = [normalTweaks stringByAppendingPathComponent:asset];
    NSString *normalStaged = [normalDst stringByAppendingString:@".disabled"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:normalDst] &&
        ![[NSFileManager defaultManager] fileExistsAtPath:normalStaged]) {
        stage([NSString stringWithFormat:@"下载 %@…", asset], -1);
        if (![self downloadAsset:asset toDirectory:normalTweaks]) {
            [self diag:@"下载失败。"];
            return [self diagnostics];
        }
        // 下载器落的是正式名；立刻转为 .disabled 暂存，避免与旧版共存。
        if ([[NSFileManager defaultManager] fileExistsAtPath:normalDst]) {
            [[NSFileManager defaultManager] removeItemAtPath:normalStaged error:nil];
            if ([[NSFileManager defaultManager] moveItemAtPath:normalDst toPath:normalStaged error:nil]) {
                [self diag:@"[暂存] 新版已下载为 %@（不会被加载，等待签名）", normalStaged.lastPathComponent];
            }
        }
        gDownloadedNew = YES;
    } else {
        [self diag:@"普通 Tweaks 已存在：%@", asset];
    }

    // ★ 先让私有目录满足"最多一个已启用 dylib"的不变量，并以它的结果为准决定共享目录。
    // 历史遗留：目录里可能已经躺着多份已签名 dylib —— 那正是"签名后打开任何 App 都闪退"
    // 的原因。这一步就地修掉它，用户不需要手动删除任何文件。
    NSString *normalActive = [self enforceSingleActiveDylibIn:normalTweaks desiredAsset:asset];
    BOOL normalSigned = normalActive.length > 0 &&
        LCProxyCodeSignatureValid([normalTweaks stringByAppendingPathComponent:normalActive]);

    if (normalSigned) {
        [self diag:@"[签名] 当前启用：%@", normalActive];
        if (![normalActive isEqualToString:asset]) {
            [self diag:@"[提示] 新版 %@ 尚未签名，当前仍在使用 %@。请在 LiveContainer 的 Tweaks 页签名后重开本控制台。", asset, normalActive];
        }
    } else {
        [self diag:@"[签名] %@ 尚未签名（已暂存为 .disabled，不会被加载）。请在 LiveContainer 的 Tweaks 页签名后重新打开本控制台。", asset];
    }

    // 共享目录：只复制**已签名的当前启用版本**，并同样收敛到"最多一个已启用"。
    if (sharedTweaks) {
        if (normalSigned) {
            NSString *sharedDst = [sharedTweaks stringByAppendingPathComponent:normalActive];
            BOOL sharedSigned = [[NSFileManager defaultManager] fileExistsAtPath:sharedDst] &&
                LCProxyCodeSignatureValid(sharedDst);
            if (!sharedSigned) {
                NSError *err = nil;
                [[NSFileManager defaultManager] removeItemAtPath:sharedDst error:nil];
                if ([[NSFileManager defaultManager] copyItemAtPath:[normalTweaks stringByAppendingPathComponent:normalActive]
                                                            toPath:sharedDst error:&err]) {
                    [self diag:@"[复制] 已签名 dylib -> 共享 App: %@", sharedDst];
                    // 复制到共享目录是给其它 guest App 用的，不影响控制台进程自身的 dylib
                    // 注入；不要置 gDownloadedNew，否则用户签名后还要重复打开两次。
                } else {
                    [self diag:@"[复制] 到共享 App 失败: %@", err.localizedDescription ?: @"?"];
                }
            } else {
                [self diag:@"共享 App 已有已签名 dylib：%@", normalActive];
            }
        }
        // 无论私有侧是否已签名，共享目录都必须收敛到"最多一个已启用"，
        // 否则共享 App 同样会因为两份同名映像而闪退。
        [self enforceSingleActiveDylibIn:sharedTweaks
                             desiredAsset:(normalSigned ? normalActive : asset)];
    }

    if (!normalSigned) {
        [self diag:@"请完成 dylib 签名后重新打开本控制台。"];
    }
    return [self diagnostics];
}

@end
