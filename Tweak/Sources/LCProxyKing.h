#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted whenever the local KingCard forwarder instance is created, replaced,
/// stopped, or discarded. The previously published proxy override keeps pointing
/// at the old ephemeral port, so observers MUST re-run the runtime apply pass;
/// otherwise every TCP connect is refused against a dead loopback port while the
/// UI still reports KingCard mode as active.
extern NSString *const LCProxyForwarderLifecycleChangedNotification;

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
- (BOOL)isReady;
- (int)localForwarderPort;
- (BOOL)ensureCredentialsReadyWithTimeout:(NSTimeInterval)maxWait;
- (NSDictionary *)forwarderStats;
- (NSDictionary *)status;

@end

NS_ASSUME_NONNULL_END
