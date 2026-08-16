#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCProxyServer : NSObject

+ (instancetype)shared;
- (BOOL)start;
- (BOOL)isRunning;
- (int)port;

@end

NS_ASSUME_NONNULL_END
