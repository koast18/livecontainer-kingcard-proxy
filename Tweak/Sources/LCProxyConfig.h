#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 王卡模式下转发器未能运行时发出（进入该状态时触发一次；恢复后再次故障会重新触发）。
/// userInfo: message = 面向用户的提示文案。此时进程保持 fail-closed：连接被丢弃，
/// 绝不直连（直连会消耗通用流量）。
extern NSString *const LCProxyForwarderUnavailableNotification;

@interface LCProxyConfig : NSObject

+ (instancetype)shared;

- (NSDictionary *)load;
- (BOOL)saveSettings:(NSDictionary *)settings;
- (void)applyToRuntime;
- (void)requestRuntimeApplyAsync;
- (void)requestForegroundRecoveryAsync;
- (void)notifyDidEnterBackground;
- (void)notifyWillEnterForeground;
- (void)notifyDidBecomeActive;

- (NSString *)effectiveProxyModeForSettings:(NSDictionary *)settings;
- (NSString *)proxychainsConfPath;
- (NSString *)settingsPath;
- (void)startNetworkMonitor;

/// Current lifecycle state: active / foregrounding / background.
- (NSString *)lifecycleState;
/// Incremented every time a foreground/network recovery rebuilds the runtime.
- (NSUInteger)networkGeneration;
/// Diagnostic snapshot for the web console.
- (NSDictionary *)runtimeDiagnostics;

@end

NS_ASSUME_NONNULL_END
