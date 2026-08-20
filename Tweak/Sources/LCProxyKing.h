#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCProxyKing : NSObject

+ (instancetype)shared;
- (void)applyConfig:(NSDictionary *)settings;
- (BOOL)refreshCredentials;
- (BOOL)isReady;
- (int)localForwarderPort;
- (BOOL)ensureCredentialsReadyWithTimeout:(NSTimeInterval)maxWait;
- (NSDictionary *)forwarderStats;
- (NSDictionary *)status;

@end

NS_ASSUME_NONNULL_END
