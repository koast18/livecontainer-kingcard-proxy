#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "LCProxyConfig.h"
#import "LCProxyStats.h"
#import "LCProxyServer.h"
#import "LCProxyPaths.h"
#import "lcproxy_bridge.h"

static id<NSObject> g_lcDidBecomeActiveObserver;
static id<NSObject> g_lcDidEnterBackgroundObserver;
static id<NSObject> g_lcWillEnterForegroundObserver;
static id<NSObject> g_lcForwarderUnavailableObserver;

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

        // Persist this process's cellular traffic in 10-minute buckets.
        [[LCProxyStats shared] start];
        [[LCProxyStats shared] flushNow];

        // Start the loopback web console. If another guest app already owns the
        // port, this instance stays headless but still records stats.
        BOOL web = [[LCProxyServer shared] start];
        NSLog(@"[LCProxy] control loaded, data=%@ web=%d", LCProxyDataDirectory(), web);
    }
}
