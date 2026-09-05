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
- (BOOL)isReady;
- (int)localForwarderPort;
- (BOOL)ensureCredentialsReadyWithTimeout:(NSTimeInterval)maxWait;
- (NSDictionary *)forwarderStats;
- (NSDictionary *)status;

@end

NS_ASSUME_NONNULL_END
