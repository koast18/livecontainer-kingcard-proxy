#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCProxyStats : NSObject

+ (instancetype)shared;
- (void)start;
- (void)flushNow;
- (NSDictionary *)aggregate;

@end

NS_ASSUME_NONNULL_END
