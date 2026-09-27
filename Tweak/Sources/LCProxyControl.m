#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "LCProxyConfig.h"
#import "LCProxyStats.h"
#import "LCProxyServer.h"
#import "LCProxyPaths.h"
#import "lcproxy_bridge.h"
#import "Version.h"
#include <fcntl.h>
#include <unistd.h>

static id<NSObject> g_lcDidBecomeActiveObserver;
static id<NSObject> g_lcDidEnterBackgroundObserver;
static id<NSObject> g_lcWillEnterForegroundObserver;
static id<NSObject> g_lcForwarderUnavailableObserver;
static id<NSObject> g_lcForwarderLifecycleObserver;

// 记录"本进程在什么时间、从哪个路径、加载了哪个版本的 dylib"到 App Group 共享日志。
// 这是排查"共享 App 是否真的加载了新 dylib"的唯一可靠依据：App Group 在文件应用里
// 看不到，而每个进程的 /api/status 只能反映它自己。控制台通过 dylibLoadsTail 读取
// 该文件，即可看到所有进程（含共享 App）的加载记录。
// O_APPEND 行级追加、无需加锁；任何失败都静默忽略（纯诊断，绝不能影响加载）。
static void LCProxyRecordDylibLoad(void) {
    NSString *dir = LCProxyCanonicalDataDirectory();
    if (!dir.length) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"dylib-loads.log"];
    NSDictionary *record = @{
        @"ts": @([[NSDate date] timeIntervalSince1970]),
        @"pid": @(getpid()),
        @"version": [NSString stringWithUTF8String:KPTWEAK_VERSION],
        @"dylib": LCProxyDylibPath() ?: @"",
        @"bundle": [[NSBundle mainBundle] bundleIdentifier] ?: @"",
    };
    NSData *line = [NSJSONSerialization isValidJSONObject:record]
        ? [NSJSONSerialization dataWithJSONObject:record options:0 error:nil] : nil;
    if (line.length) {
        NSMutableData *payload = [line mutableCopy];
        [payload appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) {
            ssize_t ignored = write(fd, payload.bytes, payload.length);
            (void)ignored;
            close(fd);
        }
    }
    // 每次 App 启动都会追加一行，必须裁剪，否则文件无限增长。
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return;
    NSArray<NSString *> *all = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *l in all) {
        if (l.length) [kept addObject:l];
    }
    if (kept.count <= 80) return;
    NSString *out = [[kept subarrayWithRange:NSMakeRange(kept.count - 40, 40)] componentsJoinedByString:@"\n"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// 王卡转发器不可用时的强提示（不受 showProxyBanner 开关约束）：
// 此刻进程保持 fail-closed 断网，必须让用户知道为什么没网、且不会偷跑直连流量。
static void LCProxyShowUnavailableBanner(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *hud = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        hud.windowLevel = UIWindowLevelStatusBar + 2;
        hud.userInteractionEnabled = NO;
        hud.backgroundColor = [UIColor clearColor];
        UILabel *label = [[UILabel alloc] init];
        label.text = text;
        label.font = [UIFont boldSystemFontOfSize:13];
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [[UIColor colorWithRed:0.78 green:0.25 blue:0.07 alpha:1] colorWithAlphaComponent:0.9];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        CGFloat width = MIN(hud.bounds.size.width - 32, 340);
        CGSize fit = [label sizeThatFits:CGSizeMake(width - 24, CGFLOAT_MAX)];
        label.layer.cornerRadius = 8;
        label.layer.masksToBounds = YES;
        CGFloat top = hud.bounds.size.height > 0 ? hud.bounds.size.height * 0.12 : 64;
        label.frame = CGRectMake((hud.bounds.size.width - width) / 2.0, top, width, fit.height + 20);
        [hud addSubview:label];
        hud.hidden = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            hud.hidden = YES;
        });
    });
}

static void LCProxyShowBanner(NSDictionary *settings) {
    if (![settings[@"showProxyBanner"] boolValue]) return;
    BOOL enabled = [settings[@"proxyEnabled"] boolValue];
    NSString *effectiveMode = [[LCProxyConfig shared] effectiveProxyModeForSettings:settings];
    NSString *text = nil;
    if (!enabled) {
        text = @"LiveProxy 已加载 · 代理未启用";
    } else if ([effectiveMode isEqualToString:@"kingcard"]) {
        text = @"LiveProxy 已加载 · 王卡代理";
    } else if ([effectiveMode isEqualToString:@"custom"]) {
        text = @"LiveProxy 已加载 · 自定义代理";
    } else {
        text = @"LiveProxy 已加载 · 直连";
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *hud = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        hud.windowLevel = UIWindowLevelStatusBar + 1;
        hud.userInteractionEnabled = NO;
        hud.backgroundColor = [UIColor clearColor];
        UILabel *label = [[UILabel alloc] init];
        label.text = text;
        label.font = [UIFont boldSystemFontOfSize:13];
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        CGFloat width = MIN(hud.bounds.size.width - 32, 320);
        CGFloat height = 32;
        label.frame = CGRectMake((hud.bounds.size.width - width) / 2.0,
                                 hud.bounds.size.height > 0 ? hud.bounds.size.height * 0.18 : 80,
                                 width, height);
        label.layer.cornerRadius = 8;
        label.layer.masksToBounds = YES;
        [hud addSubview:label];
        hud.hidden = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            hud.hidden = YES;
        });
    });
}

__attribute__((constructor))
static void LCProxyControlConstructor(void) {
    @autoreleasepool {
        // ① 防重复加载（必须最先做）。
        //
        // LiveContainer 的 TweakLoader 会加载 Tweaks 目录里的**每一个** dylib 文件，
        // 而升级过程中新旧两份 LCProxyControl-*.dylib 很容易共存（新版已下载、旧版
        // 尚未被清理）。此时两个映像会同时进入进程，后果是：
        //   · 同一个 ObjC 类名被注册两次 —— runtime 只能选其一，另一份的方法实现与
        //     实例变量被交叉使用 → **未定义行为 / 崩溃**；
        //   · 两份 dispatch_once 单例 → 两个转发器、两个存活心跳、两个本地 Web 服务。
        // 实测确实发生过：dylib-loads.log 里同一个 pid 先后加载了 0.5.57 与 0.5.56。
        //
        // 这里做一次幂等检查：若运行期已注册的 LCProxyConfig 不是本映像的类，说明另一份
        // 已经生效，本映像整体让位 —— 不记录加载、不注册观察者、不启服务、不建转发器。
        // 用 LCProxyConfig 作锚点是因为它在本文件已导入；NSClassFromString 返回 nil 时
        // 保持原行为（不改变现有正常路径）。
        Class registeredConfig = NSClassFromString(@"LCProxyConfig");
        if (registeredConfig && registeredConfig != [LCProxyConfig class]) {
            NSLog(@"[LCProxy] duplicate LCProxyControl image detected; skipping this copy "
                  @"(already loaded: %@)", NSStringFromClass(registeredConfig));
            return;
        }

        // ② 最优先记录加载事实：即便后面任何一步出问题，我们也知道这个进程在什么
        // 时间加载了哪个版本的 dylib。
        LCProxyRecordDylibLoad();
        // Apply persisted settings immediately. The proxychains C core is already
        // initialized by its own constructor; these calls update runtime flags.
        NSDictionary *initialSettings = [[LCProxyConfig shared] load];
        [[LCProxyConfig shared] applyToRuntime];
        LCProxyShowBanner(initialSettings);
        [[LCProxyConfig shared] startNetworkMonitor];

        g_lcDidBecomeActiveObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [[LCProxyConfig shared] notifyDidBecomeActive];
        }];

        g_lcWillEnterForegroundObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [[LCProxyConfig shared] notifyWillEnterForeground];
        }];

        g_lcDidEnterBackgroundObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [[LCProxyConfig shared] notifyDidEnterBackground];
        }];

        g_lcForwarderUnavailableObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:LCProxyForwarderUnavailableNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            NSString *msg = [note.userInfo[@"message"] isKindOfClass:[NSString class]] ? note.userInfo[@"message"] : nil;
            LCProxyShowUnavailableBanner(msg ?: @"王卡转发器不可用：已阻断联网，正在自动恢复…");
        }];

        // 转发器实例被创建/替换/丢弃时，先前发布的 proxy override 仍指向旧端口。
        // 必须立刻重跑一次 runtime apply：清掉陈旧 override，并让恢复流程重建转发
        // 器；否则所有连接都会被发往一个无人监听的回环端口——表现为“彻底断网，
        // 但横幅仍显示王卡代理”，且 lastError 为空、无任何报错。
        g_lcForwarderLifecycleObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:LCProxyForwarderLifecycleChangedNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            [[LCProxyConfig shared] requestRuntimeApplyAsync];
        }];

        // Persist this process's cellular traffic in 10-minute buckets.
        [[LCProxyStats shared] start];
        [[LCProxyStats shared] flushNow];

        // Start the loopback web console. If another guest app already owns the
        // port, this instance stays headless but still records stats.
        BOOL web = [[LCProxyServer shared] start];
        NSLog(@"[LCProxy] control loaded, data=%@ web=%d", LCProxyDataDirectory(), web);
    }
}
