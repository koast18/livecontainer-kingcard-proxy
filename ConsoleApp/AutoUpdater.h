#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^KPAutoUpdateProgress)(NSString *stage, double fraction);

@interface AutoUpdater : NSObject

+ (nullable NSString *)runAutoUpdateWithProgress:(nullable KPAutoUpdateProgress)progress;
+ (BOOL)downloadedAnything;
+ (NSString *)diagnostics;

@end

NS_ASSUME_NONNULL_END
