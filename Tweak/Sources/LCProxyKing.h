#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCProxyKing : NSObject

+ (instancetype)shared;
- (void)applyConfig:(NSDictionary *)settings;
- (void)forceRestartForwarderWithSettings:(NSDictionary *)settings effectiveMode:(NSString *)effectiveMode;
/// Marks a runtime transition; refreshes stay fail-closed until publication finishes.
- (void)beginRoutePublication;
/// Called after the override, policy flags, and parsed C configuration agree.
- (void)publishRouteForSettings:(NSDictionary *)settings proxyActive:(BOOL)proxyActive;
- (void)shutdownActiveClients;
- (NSUInteger)activeClientCount;
- (BOOL)performHealthCheck;
- (BOOL)refreshCredentials;
- (BOOL)refreshCredentialsForce;
/// 请求一次后台强制取号：**零阻塞、限频（LCProxyKingMinRefreshInterval）、异步**。
/// 供"发现转发异常"的外部路径使用（例如健康检查失败）。它会立即返回，真正的取号在
/// 后台队列完成，因此绝不阻塞调用线程，也不会因被频繁调用而变成取号风暴。
- (void)requestBackgroundRefresh;
- (BOOL)isReady;
/// 丢弃缓存的凭证状态，重新领一套全新的 GUID + Q-Token + 代理池，并把结果写进共享日志。
///
/// 用途：凭证库在 App Group 里被所有进程共享。若其中最新那条记录对运营商已失效（或被
/// 某个进程写坏），则**每个**读它的进程都会拿着这份坏凭证去连、被运营商零字节关闭 ——
/// 而自己重新领一套的进程却正常。这恰好能造成"私有正常、共享不正常"。
/// 这是用户可主动触发的一次性动作，用来验证/修复该情形。
- (void)resetSharedCredentialsAndRefresh;
- (int)localForwarderPort;
- (BOOL)ensureCredentialsReadyWithTimeout:(NSTimeInterval)maxWait;
- (NSDictionary *)forwarderStats;
- (NSDictionary *)status;

@end

NS_ASSUME_NONNULL_END
