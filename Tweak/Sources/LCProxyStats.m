#import "LCProxyStats.h"
#import "LCProxyPaths.h"
#import "lcproxy_bridge.h"
#import <objc/runtime.h>

@implementation LCProxyStats

+ (instancetype)shared {
    static LCProxyStats *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[LCProxyStats alloc] init];
    });
    return instance;
}

- (NSString *)statsDirectory {
    return [LCProxyDataDirectory() stringByAppendingPathComponent:@"stats"];
}

- (NSString *)currentBundleId {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    NSMutableString *safe = [NSMutableString string];
    for (NSUInteger i = 0; i < bid.length; i++) {
        unichar c = [bid characterAtIndex:i];
        if ([allowed characterIsMember:c]) [safe appendFormat:@"%C", c];
        else [safe appendString:@"_"];
    }
    return safe.length ? safe : @"unknown";
}

- (NSString *)currentStatsPath {
    return [self.statsDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", self.currentBundleId]];
}

- (void)start {
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        [self flushNow];
    });
    dispatch_resume(timer);
    // keep timer retained by associated object? static dictionary not needed in ObjC; use dispatch_source_t property.
    objc_setAssociatedObject(self, @selector(start), timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)flushNow {
    NSDictionary *snapshot = [self snapshotForCurrentProcess];
    if (!snapshot) return;
    NSError *err = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:self.statsDirectory
                                  withIntermediateDirectories:YES attributes:nil error:&err]) {
        return;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted error:&err];
    if (data) {
        [data writeToFile:self.currentStatsPath options:NSDataWritingAtomic error:&err];
    }
}

- (NSDictionary *)snapshotForCurrentProcess {
    int count = lcproxy_stats_bucket_count();
    NSMutableArray *buckets = [NSMutableArray arrayWithCapacity:count];
    for (int i = 0; i < count; i++) {
        int64_t start = 0;
        uint64_t up = 0, down = 0;
        if (lcproxy_stats_get_bucket(i, &start, &up, &down)) {
            [buckets addObject:@{
                @"start": @(start),
                @"upload": @(up),
                @"download": @(down),
            }];
        }
    }
    int64_t cstart = 0;
    uint64_t cup = 0, cdown = 0;
    lcproxy_stats_get_current(&cstart, &cup, &cdown);
    return @{
        @"bundleId": self.currentBundleId,
        @"updatedAt": @([[NSDate date] timeIntervalSince1970]),
        @"buckets": buckets,
        @"current": @{@"start": @(cstart), @"upload": @(cup), @"download": @(cdown)},
        @"totalUpload": @(lcproxy_stats_total_upload()),
        @"totalDownload": @(lcproxy_stats_total_download()),
    };
}

- (NSDictionary *)aggregate {
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.statsDirectory error:nil];
    NSMutableDictionary *byBucket = [NSMutableDictionary dictionary];
    uint64_t totalUp = 0, totalDown = 0;
    NSMutableArray *apps = [NSMutableArray array];
    for (NSString *file in files) {
        if (![file hasSuffix:@".json"]) continue;
        NSString *path = [self.statsDirectory stringByAppendingPathComponent:file];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *dict = obj;
        NSString *bundle = dict[@"bundleId"] ?: file;
        uint64_t appUp = [dict[@"totalUpload"] unsignedLongLongValue];
        uint64_t appDown = [dict[@"totalDownload"] unsignedLongLongValue];
        totalUp += appUp;
        totalDown += appDown;
        [apps addObject:@{@"bundleId": bundle, @"totalUpload": @(appUp), @"totalDownload": @(appDown)}];
        for (NSDictionary *b in dict[@"buckets"] ?: @[]) {
            NSNumber *startNum = b[@"start"];
            if (!startNum) continue;
            NSNumber *upNum = b[@"upload"] ?: @0;
            NSNumber *downNum = b[@"download"] ?: @0;
            NSMutableDictionary *agg = byBucket[startNum];
            if (!agg) {
                agg = [NSMutableDictionary dictionaryWithDictionary:@{@"start": startNum, @"upload": @0, @"download": @0}];
                byBucket[startNum] = agg;
            }
            agg[@"upload"] = @([agg[@"upload"] unsignedLongLongValue] + [upNum unsignedLongLongValue]);
            agg[@"download"] = @([agg[@"download"] unsignedLongLongValue] + [downNum unsignedLongLongValue]);
        }
        NSDictionary *cur = dict[@"current"];
        if ([cur isKindOfClass:[NSDictionary class]]) {
            NSNumber *startNum = cur[@"start"];
            if (startNum) {
                NSNumber *upNum = cur[@"upload"] ?: @0;
                NSNumber *downNum = cur[@"download"] ?: @0;
                NSMutableDictionary *agg = byBucket[startNum];
                if (!agg) {
                    agg = [NSMutableDictionary dictionaryWithDictionary:@{@"start": startNum, @"upload": @0, @"download": @0}];
                    byBucket[startNum] = agg;
                }
                agg[@"upload"] = @([agg[@"upload"] unsignedLongLongValue] + [upNum unsignedLongLongValue]);
                agg[@"download"] = @([agg[@"download"] unsignedLongLongValue] + [downNum unsignedLongLongValue]);
            }
        }
    }
    NSArray *buckets = [[byBucket allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"start"] compare:b[@"start"]];
    }];
    return @{
        @"cellular": @(lcproxy_stats_is_cellular() != 0),
        @"totalUpload": @(totalUp),
        @"totalDownload": @(totalDown),
        @"buckets": buckets,
        @"apps": apps,
        @"bucketSeconds": @600,
    };
}

@end
