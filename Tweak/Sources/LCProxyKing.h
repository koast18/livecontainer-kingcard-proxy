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
- (int)localForwarderPort;
- (BOOL)ensureCredentialsReadyWithTimeout:(NSTimeInterval)maxWait;
- (NSDictionary *)forwarderStats;
- (NSDictionary *)status;

@end

NS_ASSUME_NONNULL_END
