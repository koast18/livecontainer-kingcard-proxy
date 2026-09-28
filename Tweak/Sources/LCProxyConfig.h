#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 王卡模式下转发器未能运行时发出（进入该状态时触发一次；恢复后再次故障会重新触发）。
/// userInfo: message = 面向用户的提示文案。此时进程保持 fail-closed：连接被丢弃，
/// 绝不直连（直连会消耗通用流量）。
extern NSString *const LCProxyForwarderUnavailableNotification;

/// Posted by LCProxyKing whenever the local KingCard forwarder instance is
/// created, replaced, stopped, or discarded. The previously published proxy
/// override keeps pointing at the old ephemeral port, so observers MUST re-run
/// the runtime apply pass; otherwise every TCP connect is refused against a dead
/// loopback port while the UI still reports KingCard mode as active.
/// userInfo: reason = lifecycle transition ("create-failed", "start-failed",
/// "rebuild-discarded").
extern NSString *const LCProxyForwarderLifecycleChangedNotification;

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

/// 配置读写**全链路**诊断：把"读了哪些目录、每个目录里文件长什么样、最终用了哪一份、
/// 为什么、以及上次保存写成功了哪些目录"逐项摊开。
///
/// 为什么需要它：用户报告"控制台读配置不正常，但保存似乎有用" —— 这种**读写不对称**只能靠
/// 把每一步摊开才能定位（是 App Group 取不到？文件在但解析失败？还是保存只写进了非权威目录？）。
/// 此前的状态字典只有 settingsPath / settingsExists 两个字段，无法区分这些情况。
///
/// 只读、无副作用；不做任何补偿性写入（诊断绝不能改变被诊断的状态）。
- (NSDictionary *)configDiagnostics;

/// 供事务性接口使用：在指定目录里读取并解析 settings.json（nil 表示不存在/不可解析）。
/// 诊断与迁移路径共用同一实现，避免"诊断看到的"与"实际用的"不一致。
- (nullable NSDictionary *)settingsInDirectory:(NSString *)directory;

@end

NS_ASSUME_NONNULL_END
