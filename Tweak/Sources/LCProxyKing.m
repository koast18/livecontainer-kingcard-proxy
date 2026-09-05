#import "LCProxyKing.h"
#import "KPKIngCore.h"
#import "KPKQueenCore.h"
#import "LCProxyPaths.h"
#import "LCProxyConfig.h"
#import "LCProxyKingClient.h"
#import "lcproxy_bridge.h"
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <stdlib.h>
#import <unistd.h>

// 周期必须 <= LCProxyKingRefreshLeadTime(2min)，否则续期窗口内可能一次触发都轮不到；
// 且代理池 TTL 仅 ~9.5min，过长的固定网格会在每次续期后错位出死区。
static const NSTimeInterval LCProxyKingRefreshInterval = 2 * 60;
static const NSTimeInterval LCProxyKingRefreshLeeway = 30;
static const NSTimeInterval LCProxyKingRefreshLeadTime = 2 * 60;
static const NSTimeInterval LCProxyKingRefreshLeaseTTL = 75;
static const NSTimeInterval LCProxyKingRefreshLeaseHeartbeatInterval = 20;
static const NSTimeInterval LCProxyKingPBProxyBootstrapSetupAllowance = 2;

static int LCProxyKingRefreshHook(void *ctx) {
    LCProxyKing *king = (__bridge LCProxyKing *)ctx;
    // 被动刷新是由实际转发失败触发的，不能信任本地缓存的 tokenExpireEpoch：
    // 服务器宣称的有效期可能比真实有效期更长，普通 refreshCredentials 会误以为
    // 凭证仍新鲜而继续复用已失效的 Q-Token。这里强制重新取号。
    return [king refreshCredentialsForce] ? 0 : -1;
}

static void LCProxyKingLog(const char *line) {
    if (line) NSLog(@"[LCProxyKing] %s", line);
}

static NSString *LCProxyKingNow(void) {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss";
    });
    return [fmt stringFromDate:[NSDate date]];
}

static BOOL LCProxyKingHexStringValid(NSString *s) {
    if (s.length != 32) return NO;
    NSCharacterSet *cs = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
    return [s rangeOfCharacterFromSet:cs].location == NSNotFound;
}

typedef NS_ENUM(NSInteger, LCProxyKingCommitResult) {
    LCProxyKingCommitResultLockUnavailable,
    LCProxyKingCommitResultNotCommitted,
    LCProxyKingCommitResultWroteState,
    LCProxyKingCommitResultPeerState,
    LCProxyKingCommitResultFenced,
    LCProxyKingCommitResultPersistenceFailed,
};

typedef NS_ENUM(NSInteger, LCProxyKingLeaseResult) {
    LCProxyKingLeaseResultLockUnavailable,
    LCProxyKingLeaseResultFreshState,
    LCProxyKingLeaseResultHeldByPeer,
    LCProxyKingLeaseResultAcquired,
    LCProxyKingLeaseResultPersistenceFailed,
};

@interface LCProxyKing ()
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, strong) NSLock *lifecycleLock;
@property (nonatomic, assign) void *forwarderPtr;
@property (nonatomic, copy) NSString *lastRefresh;
@property (nonatomic, copy) NSString *lastSource;
@property (nonatomic, copy) NSString *lastError;
@property (nonatomic, copy) NSString *lastDiagnostics;
@property (nonatomic, assign) BOOL lastRefreshSuccess;
@property (nonatomic, strong) dispatch_source_t refreshTimer;
@property (nonatomic, assign) BOOL refreshing;
@property (nonatomic, assign) BOOL lockRetryScheduled;
@property (nonatomic, copy) NSString *lastSettingsSignature;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *refreshLog;
@property (nonatomic, assign) BOOL lastHealthCheckOk;
@property (nonatomic, assign) NSTimeInterval lastHealthCheckAt;
@property (nonatomic, assign) BOOL routePublished;
@property (nonatomic, assign) int publishedForwarderPort;
@property (nonatomic, copy) NSString *refreshOwnerID;
@property (nonatomic, strong) dispatch_source_t refreshLeaseHeartbeat;
@property (nonatomic, assign) uint64_t refreshLeaseHeartbeatGeneration;
@property (nonatomic, assign) BOOL refreshLeaseValid;
- (void)startRefreshTimer;
- (void)stopRefreshTimer;
- (void)scheduleRefreshRetryAfter:(NSTimeInterval)delay;
- (BOOL)stateHasFreshCredentials:(NSDictionary *)state;
- (BOOL)stateHasFreshCredentials:(NSDictionary *)state matchingSettings:(NSDictionary *)settings;
- (NSArray<NSString *> *)validatedProxyPool:(id)value;
- (NSString *)credentialInputSignatureForSettings:(NSDictionary *)settings;
- (NSMutableDictionary *)canonicalState;
- (NSMutableDictionary *)newestFallbackState;
- (BOOL)saveState:(NSMutableDictionary *)state error:(NSError **)outError;
- (LCProxyKingLeaseResult)acquireRefreshLeaseWithForce:(BOOL)force
                                                settings:(NSDictionary *)settings
                                                   state:(NSMutableDictionary **)outState
                                           baseUpdatedAt:(double *)outBaseUpdatedAt
                                              generation:(uint64_t *)outGeneration;
- (BOOL)renewRefreshLeaseForOwnerID:(NSString *)ownerID
                          generation:(uint64_t)generation
                       baseUpdatedAt:(double)baseUpdatedAt;
- (void)startRefreshLeaseHeartbeatForOwnerID:(NSString *)ownerID
                                   generation:(uint64_t)generation
                                baseUpdatedAt:(double)baseUpdatedAt;
- (BOOL)renewActiveRefreshLeaseForOwnerID:(NSString *)ownerID
                                generation:(uint64_t)generation
                             baseUpdatedAt:(double)baseUpdatedAt;
- (BOOL)stopRefreshLeaseHeartbeat;
- (LCProxyKingCommitResult)commitRefreshState:(NSMutableDictionary *)state
                                baseUpdatedAt:(double)baseUpdatedAt
                                       ownerID:(NSString *)ownerID
                                    generation:(uint64_t)generation
                                   allowWrite:(BOOL)allowWrite;
- (void)clearForwarderKingState;
@end

@implementation LCProxyKing

+ (instancetype)shared {
    static LCProxyKing *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[LCProxyKing alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _lifecycleLock = [[NSLock alloc] init];
        _refreshLog = [[NSMutableArray alloc] init];
        _lastHealthCheckOk = NO;
        _lastHealthCheckAt = 0;
        _routePublished = NO;
        _publishedForwarderPort = 0;
        _refreshOwnerID = [NSUUID UUID].UUIDString;
        _refreshLeaseValid = YES;
        kp_set_debug_logger(LCProxyKingLog);
    }
    return self;
}

- (kp_forwarder *)forwarder {
    return (kp_forwarder *)self.forwarderPtr;
}

- (void)setForwarder:(kp_forwarder *)fw {
    self.forwarderPtr = fw;
}

- (BOOL)isRunning {
    return self.forwarder != NULL && kp_forwarder_is_running(self.forwarder) == 1;
}

- (void)applyConfig:(NSDictionary *)settings {
    NSString *effectiveMode = [[LCProxyConfig shared] effectiveProxyModeForSettings:settings];
    [self applyConfig:settings effectiveMode:effectiveMode forceRestart:NO];
}

- (void)forceRestartForwarderWithSettings:(NSDictionary *)settings effectiveMode:(NSString *)effectiveMode {
    [self applyConfig:settings effectiveMode:effectiveMode forceRestart:YES];
}

- (void)applyConfig:(NSDictionary *)settings effectiveMode:(NSString *)effectiveMode forceRestart:(BOOL)forceRestart {
    // 转发器生命周期（stop/free/new/start/install）必须整体串行化，否则多个线程
    // 同时走到“重建转发器”分支会互相竞争，导致闪退。不能用 self.lock 包住 stop，
    // 因为 stop 要等 client 线程退出，client 线程失败时可能等 self.lock 做取号刷新。
    [self.lifecycleLock lock];
    @try {
    BOOL shouldRun = [effectiveMode isEqualToString:@"kingcard"] && [settings[@"proxyEnabled"] boolValue];
    NSString *signature = [self settingsSignature:settings];
    kp_forwarder *oldForwarder = NULL;
    kp_forwarder *newForwarder = NULL;

    [self.lock lock];
    BOOL alreadyRunning = !forceRestart && shouldRun && self.forwarder != NULL && kp_forwarder_is_running(self.forwarder) == 1;
    if (alreadyRunning) {
        [self.lock unlock];
        BOOL settingsChanged = ![signature isEqualToString:self.lastSettingsSignature];
        if (settingsChanged) self.lastSettingsSignature = signature;
        // 不要无条件重启定时器：applyToRuntime 会因前后台切换/网络变化被频繁调用，
        // 每次都 stop+新建 会把 5 分钟→2 分钟的刷新节奏不断清零，永远凑不满一个周期。
        [self loadCachedStateIntoForwarder];
        return;
    }

    [self stopRefreshTimer];

    if (!shouldRun) {
        oldForwarder = self.forwarder;
        self.forwarder = NULL;
        self.lastSettingsSignature = nil;
        [self.lock unlock];
        // 不要在持有 self.lock 时 stop/free：kp_forwarder_stop 会等待所有 client
        // 线程退出，而 client 线程失败重试时可能正在等待 self.lock 做取号刷新，
        // 持锁等待会形成死锁。
        if (oldForwarder) {
            kp_forwarder_stop(oldForwarder);
            kp_forwarder_free(oldForwarder);
        }
        return;
    }

    // shouldRun 但当前没有 running 的转发器：先摘除旧引用并释放锁，再安全 stop/free。
    oldForwarder = self.forwarder;
    self.forwarder = NULL;
    self.lastSettingsSignature = signature;
    [self.lock unlock];

    if (oldForwarder) {
        kp_forwarder_stop(oldForwarder);
        kp_forwarder_free(oldForwarder);
    }

    newForwarder = kp_forwarder_new("127.0.0.1", 0, "", 0);
    if (!newForwarder) {
        [self.lock lock];
        self.lastError = @"转发器启动失败";
        self.lastRefreshSuccess = NO;
        [self.lock unlock];
        return;
    }
    kp_forwarder_set_refresh_hook(newForwarder, LCProxyKingRefreshHook, (__bridge void *)self);
    if (kp_forwarder_start(newForwarder) != 0) {
        kp_forwarder_free(newForwarder);
        [self.lock lock];
        self.lastError = @"转发器启动失败";
        self.lastRefreshSuccess = NO;
        [self.lock unlock];
        return;
    }

    [self.lock lock];
    // 创建/启动新转发器期间锁已释放，可能已有另一次 applyConfig 改动了模式。
    // 只有当前仍然应该运行、且还没有安装新转发器时，才把 newForwarder 装上。
    if (self.forwarder == NULL && [self.lastSettingsSignature isEqualToString:signature]) {
        self.forwarder = newForwarder;
        [self.lock unlock];
        [self loadCachedStateIntoForwarder];
        return;
    }

    [self.lock unlock];
    kp_forwarder_stop(newForwarder);
    kp_forwarder_free(newForwarder);
    } @finally {
        [self.lifecycleLock unlock];
    }
}

- (void)beginRoutePublication {
    [self.lock lock];
    self.routePublished = NO;
    self.publishedForwarderPort = 0;
    [self.lock unlock];
}

- (void)publishRouteForSettings:(NSDictionary *)settings proxyActive:(BOOL)proxyActive {
    NSString *effectiveMode = [[LCProxyConfig shared] effectiveProxyModeForSettings:settings];
    BOOL isKingRoute = proxyActive && [effectiveMode isEqualToString:@"kingcard"];
    int port = 0;
    BOOL published = NO;
    [self.lock lock];
    kp_forwarder *fw = self.forwarder;
    port = fw ? kp_forwarder_port(fw) : 0;
    published = isKingRoute && port > 0 && kp_forwarder_listen_fd_valid(fw) == 1;
    self.routePublished = published;
    self.publishedForwarderPort = published ? port : 0;
    [self.lock unlock];

    if (!published) {
        [self stopRefreshTimer];
        return;
    }
    [self loadCachedStateIntoForwarder];
    [self startRefreshTimer];
    if (![self hasFreshCachedState]) [self refreshCredentialsAsync];
}

- (NSString *)settingsSignature:(NSDictionary *)settings {
    NSArray<NSString *> *keys = @[
        @"proxyEnabled", @"proxyMode", @"kingAutoDirectOnNonCellular",
        @"kingGuidOverride", @"kingTokenOverride", @"kingKeyOverride",
        @"kingPhone", @"kingQType", @"kingApn", @"kingTypeName",
        @"kingSubtype", @"kingExtraInfo", @"kingMccmnc", @"kingCardType"
    ];
    NSMutableString *signature = [NSMutableString string];
    for (NSString *key in keys) {
        id value = settings[key];
        if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) {
            [signature appendFormat:@"%@=%@|", key, value];
        } else if ([value isKindOfClass:[NSNull class]]) {
            [signature appendFormat:@"%@=null|", key];
        } else {
            [signature appendFormat:@"%@=|", key];
        }
    }
    return signature;
}

- (void)refreshCredentialsAsync {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self refreshCredentials];
    });
}

// 锁竞争快速重试：另一个实例（往往是首次安装后长达几十秒的首次取号）持有
// 状态锁时，本实例的刷新会失败。若只等 2 分钟周期定时器，期间所有请求都会
// 拿不到凭证而 502 —— 用户看到“第二个 App 直接网络错误”。5 秒后重试一次，
// 兜住绝大多数“对方即将释放锁”的场景。
- (void)scheduleRefreshRetryAfterLockContention {
    [self scheduleRefreshRetryAfter:5.0];
}

- (void)scheduleRefreshRetryAfter:(NSTimeInterval)delay {
    [self.lock lock];
    BOOL alreadyScheduled = self.lockRetryScheduled;
    if (!alreadyScheduled) self.lockRetryScheduled = YES;
    [self.lock unlock];
    if (alreadyScheduled) return;
    delay = MAX(1.0, MIN(delay, 30.0));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.lock lock];
        self.lockRetryScheduled = NO;
        [self.lock unlock];
        [self refreshCredentials];
    });
}

- (void)startRefreshTimer {
    [self stopRefreshTimer];

    NSTimeInterval interval = LCProxyKingRefreshInterval;
    NSDictionary *state = [self loadState];
    double now = [[NSDate date] timeIntervalSince1970];
    BOOL hasExpiry = NO;
    double earliestExpiry = 0;
    NSNumber *tokenExpireEpoch = [state[@"tokenExpireEpoch"] isKindOfClass:[NSNumber class]] ? state[@"tokenExpireEpoch"] : nil;
    NSNumber *proxyExpireEpoch = [state[@"proxyExpireEpoch"] isKindOfClass:[NSNumber class]] ? state[@"proxyExpireEpoch"] : nil;
    if (tokenExpireEpoch) {
        hasExpiry = YES;
        earliestExpiry = tokenExpireEpoch.doubleValue;
    }
    if (proxyExpireEpoch && (!hasExpiry || proxyExpireEpoch.doubleValue < earliestExpiry)) {
        hasExpiry = YES;
        earliestExpiry = proxyExpireEpoch.doubleValue;
    }
    if (hasExpiry) {
        NSTimeInterval next = earliestExpiry - now - LCProxyKingRefreshLeadTime;
        if (next > 1.0 && next < interval) {
            interval = next;
        }
    }

    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                              (uint64_t)(LCProxyKingRefreshInterval * NSEC_PER_SEC),
                              (uint64_t)(LCProxyKingRefreshLeeway * NSEC_PER_SEC));
    __weak LCProxyKing *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf refreshCredentials];
    });
    dispatch_resume(timer);
    self.refreshTimer = timer;
}

- (void)stopRefreshTimer {
    if (self.refreshTimer) {
        dispatch_source_cancel(self.refreshTimer);
        self.refreshTimer = nil;
    }
}

- (void)loadCachedStateIntoForwarder {
    NSMutableDictionary *state = [self loadState];
    // A fallback is useful only to seed missing/corrupt canonical storage. Do
    // not put a private-only credential set into a running forwarder unless
    // that migration has completed and been read back successfully.
    if (![self canonicalState] && state.count) {
        NSArray<NSNumber *> *fds = [self acquireStateLocks];
        if (fds.count == 0) {
            [self clearForwarderKingState];
            return;
        }
        @try {
            NSMutableDictionary *canonical = [self canonicalState];
            if (canonical) {
                state = canonical;
            } else if (![self saveState:state error:nil]) {
                [self clearForwarderKingState];
                return;
            }
        } @finally {
            [self releaseStateLocks:fds];
        }
    }
    // 无条件恢复历史取号日志：即便凭证尚不完整提前 return，控制台也能读到历史记录。
    NSArray *savedLog = [state[@"refreshLog"] isKindOfClass:[NSArray class]] ? state[@"refreshLog"] : nil;
    if (savedLog.count) {
        [self.lock lock];
        if (self.refreshLog.count == 0) {
            [self.refreshLog addObjectsFromArray:savedLog];
            while (self.refreshLog.count > LCProxyKingRefreshLogMax) {
                [self.refreshLog removeLastObject];
            }
        }
        [self.lock unlock];
    }
    NSDictionary *settings = [self settingsSnapshot];
    if (![self stateHasFreshCredentials:state matchingSettings:settings]) {
        [self clearForwarderKingState];
        return;
    }
    NSString *guid = [state[@"guid"] isKindOfClass:[NSString class]] ? state[@"guid"] : nil;
    NSString *token = [state[@"token"] isKindOfClass:[NSString class]] ? state[@"token"] : nil;
    NSString *qkey = [state[@"key"] isKindOfClass:[NSString class]] ? state[@"key"] : nil;
    NSString *qua2 = [state[@"qua2"] isKindOfClass:[NSString class]] ? state[@"qua2"] : nil;
    NSArray *queenHttp = [self validatedProxyPool:state[@"queen_http"]];
    NSArray *queenHttps = [self validatedProxyPool:state[@"queen_https"]];
    NSString *qtype = [state[@"qtype"] isKindOfClass:[NSString class]] && [state[@"qtype"] length]
        ? state[@"qtype"] : @"httpcom";

    [self.lock lock];
    if (self.forwarder) {
        NSInteger nhttp = MIN(queenHttp.count, 32);
        NSInteger nhttps = MIN(queenHttps.count, 32);
        const char **httpArr = nhttp > 0 ? (const char **)calloc((size_t)nhttp, sizeof(char *)) : NULL;
        const char **httpsArr = nhttps > 0 ? (const char **)calloc((size_t)nhttps, sizeof(char *)) : NULL;
        for (NSInteger i = 0; i < nhttp; i++) httpArr[i] = [queenHttp[(NSUInteger)i] UTF8String];
        for (NSInteger i = 0; i < nhttps; i++) httpsArr[i] = [queenHttps[(NSUInteger)i] UTF8String];
        kp_forwarder_set_king_state(self.forwarder,
                                    guid.UTF8String, qua2.UTF8String,
                                    token.UTF8String, qkey.UTF8String,
                                    qtype.UTF8String,
                                    httpArr, (size_t)nhttp,
                                    httpsArr, (size_t)nhttps);
        if (httpArr) free(httpArr);
        if (httpsArr) free(httpsArr);
        if (self.routePublished) {
            self.lastRefreshSuccess = YES;
            self.lastRefresh = LCProxyKingNow();
            self.lastError = @"";
        }
    }
    [self.lock unlock];
}

- (NSArray<NSString *> *)validatedProxyPool:(id)value {
    if (![value isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSString *> *valid = [NSMutableArray array];
    NSCharacterSet *invalidHost = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"] invertedSet];
    for (id item in (NSArray *)value) {
        if (![item isKindOfClass:[NSString class]]) continue;
        NSString *proxy = (NSString *)item;
        NSString *host = nil;
        NSString *portText = nil;
        if ([proxy hasPrefix:@"["]) {
            NSRange close = [proxy rangeOfString:@"]:"];
            if (close.location != NSNotFound) {
                host = [proxy substringWithRange:NSMakeRange(1, close.location - 1)];
                portText = [proxy substringFromIndex:close.location + close.length];
            }
        } else {
            NSRange colon = [proxy rangeOfString:@":" options:NSBackwardsSearch];
            if (colon.location != NSNotFound &&
                [proxy rangeOfString:@":" options:0 range:NSMakeRange(0, colon.location)].location == NSNotFound) {
                host = [proxy substringToIndex:colon.location];
                portText = [proxy substringFromIndex:colon.location + 1];
            }
        }
        if (!host.length || !portText.length || host.length > 253 ||
            [host rangeOfCharacterFromSet:invalidHost].location != NSNotFound) continue;
        NSScanner *scanner = [NSScanner scannerWithString:portText];
        NSInteger port = 0;
        if (![scanner scanInteger:&port] || !scanner.isAtEnd || port < 1 || port > 65535) continue;
        if (![valid containsObject:proxy]) [valid addObject:proxy];
    }
    return valid;
}

- (NSString *)credentialInputSignatureForSettings:(NSDictionary *)settings {
    NSArray<NSString *> *keys = @[
        @"kingGuidOverride", @"kingTokenOverride", @"kingKeyOverride", @"kingPhone",
        @"kingQType", @"kingApn", @"kingTypeName", @"kingSubtype", @"kingExtraInfo",
        @"kingMccmnc", @"kingCardType"
    ];
    NSMutableString *signature = [NSMutableString string];
    for (NSString *key in keys) {
        id value = settings[key];
        [signature appendFormat:@"%@=%@|", key, [value isKindOfClass:[NSNull class]] ? @"null" : (value ?: @"")];
    }
    return signature;
}

- (BOOL)stateHasFreshCredentials:(NSDictionary *)state matchingSettings:(NSDictionary *)settings {
    NSNumber *invalidatingGeneration = [state[@"refreshInvalidatingGeneration"] isKindOfClass:[NSNumber class]]
        ? state[@"refreshInvalidatingGeneration"] : nil;
    // A forced refresh invalidates the prior credential generation before it
    // starts network work. A peer must not reactivate that stale generation.
    if (invalidatingGeneration.unsignedLongLongValue != 0) return NO;
    NSString *guid = [state[@"guid"] isKindOfClass:[NSString class]] ? state[@"guid"] : nil;
    NSString *token = [state[@"token"] isKindOfClass:[NSString class]] ? state[@"token"] : nil;
    NSString *qkey = [state[@"key"] isKindOfClass:[NSString class]] ? state[@"key"] : nil;
    NSString *qua2 = [state[@"qua2"] isKindOfClass:[NSString class]] ? state[@"qua2"] : nil;
    NSArray *queenHttp = [state[@"queen_http"] isKindOfClass:[NSArray class]] ? state[@"queen_http"] : nil;
    NSArray *queenHttps = [state[@"queen_https"] isKindOfClass:[NSArray class]] ? state[@"queen_https"] : nil;
    NSString *inputSignature = [state[@"credentialInputSignature"] isKindOfClass:[NSString class]] ? state[@"credentialInputSignature"] : nil;
    if (!LCProxyKingHexStringValid(guid) || !token.length || !qkey.length || !qua2.length) return NO;
    if (![inputSignature isEqualToString:[self credentialInputSignatureForSettings:settings]]) return NO;
    NSArray *validHttp = [self validatedProxyPool:queenHttp];
    NSArray *validHttps = [self validatedProxyPool:queenHttps];
    if (!queenHttp.count || !queenHttps.count || validHttp.count != queenHttp.count || validHttps.count != queenHttps.count) return NO;

    double now = [[NSDate date] timeIntervalSince1970];
    NSNumber *tokenExpireEpoch = [state[@"tokenExpireEpoch"] isKindOfClass:[NSNumber class]] ? state[@"tokenExpireEpoch"] : nil;
    NSNumber *proxyExpireEpoch = [state[@"proxyExpireEpoch"] isKindOfClass:[NSNumber class]] ? state[@"proxyExpireEpoch"] : nil;
    if (!tokenExpireEpoch || tokenExpireEpoch.doubleValue <= now + LCProxyKingRefreshLeadTime) return NO;
    if (!proxyExpireEpoch || proxyExpireEpoch.doubleValue <= now + LCProxyKingRefreshLeadTime) return NO;
    return YES;
}

- (BOOL)stateHasFreshCredentials:(NSDictionary *)state {
    return [self stateHasFreshCredentials:state matchingSettings:[self settingsSnapshot]];
}

- (BOOL)hasFreshCachedState {
    return [self stateHasFreshCredentials:[self loadState]];
}

- (BOOL)isReady {
    [self.lock lock];
    BOOL running = self.forwarder != NULL && kp_forwarder_is_running(self.forwarder) == 1;
    BOOL success = self.lastRefreshSuccess;
    BOOL refreshing = self.refreshing;
    BOOL published = self.routePublished;
    [self.lock unlock];
    return published && running && success && !refreshing &&
           [self stateHasFreshCredentials:[self loadState]];
}

- (int)localForwarderPort {
    [self.lock lock];
    int port = self.forwarder ? kp_forwarder_port(self.forwarder) : 0;
    [self.lock unlock];
    return port;
}

- (BOOL)ensureCredentialsReadyWithTimeout:(NSTimeInterval)maxWait {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:maxWait];
    while ([[NSDate date] timeIntervalSinceDate:deadline] < 0) {
        [self.lock lock];
        BOOL refreshing = self.refreshing;
        BOOL running = self.forwarder != NULL && kp_forwarder_is_running(self.forwarder) == 1;
        BOOL success = self.lastRefreshSuccess;
        BOOL published = self.routePublished;
        [self.lock unlock];

        if (published && running && success && !refreshing &&
            [self stateHasFreshCredentials:[self loadState]]) return YES;

        if (published && !refreshing) {
            BOOL ok = [self refreshCredentials];
            if (ok) return YES;
        }
        [NSThread sleepForTimeInterval:0.25];
    }
    return [self isReady];
}

// ---------------------------------------------------------------------------
// 状态持久化与同步取号辅助
// ---------------------------------------------------------------------------
// All active state lives in one canonical App Group location. Private paths
// remain migration inputs only, so they must never receive a state write or a
// lock that could make their stale contents authoritative again.
- (NSArray<NSString *> *)stateLockPaths {
    NSString *directory = LCProxyCanonicalDataDirectory();
    if (!directory.length) return @[];
    return @[[directory stringByAppendingPathComponent:@"kingcard-state.lock"]];
}

- (NSArray<NSNumber *> *)acquireStateLocks {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
    NSMutableArray<NSNumber *> *fds = [NSMutableArray array];
    for (NSString *path in [self stateLockPaths]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        int fd = open(path.UTF8String, O_CREAT | O_RDWR, 0644);
        if (fd < 0) {
            [self releaseStateLocks:fds];
            return @[];
        }
        struct flock fl = {0};
        fl.l_type = F_WRLCK;
        fl.l_whence = SEEK_SET;
        BOOL locked = NO;
        while (YES) {
            if (fcntl(fd, F_SETLK, &fl) == 0) {
                locked = YES;
                break;
            }
            int err = errno;
            if (err != EACCES && err != EAGAIN) break;
            if ([[NSDate date] timeIntervalSinceDate:deadline] >= 0) break;
            [NSThread sleepForTimeInterval:0.1];
        }
        if (!locked) {
            close(fd);
            [self releaseStateLocks:fds];
            return @[];
        }
        [fds addObject:@(fd)];
    }
    return fds;
}

- (void)releaseStateLocks:(NSArray<NSNumber *> *)fds {
    for (NSNumber *n in fds) {
        int fd = n.intValue;
        if (fd < 0) continue;
        struct flock fl = {0};
        fl.l_type = F_UNLCK;
        fl.l_whence = SEEK_SET;
        (void)fcntl(fd, F_SETLK, &fl);
        close(fd);
    }
}

 - (NSMutableDictionary *)stateInDirectory:(NSString *)directory {
    if (!directory.length) return nil;
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"kingcard-state.json"]];
    if (!data) return nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [decoded isKindOfClass:[NSDictionary class]] ? [decoded mutableCopy] : nil;
}

- (NSMutableDictionary *)canonicalState {
    return [self stateInDirectory:LCProxyCanonicalDataDirectory()];
}

- (NSMutableDictionary *)newestFallbackState {
    NSMutableDictionary *best = nil;
    NSDate *bestDate = nil;
    NSString *canonicalDirectory = LCProxyCanonicalDataDirectory();
    for (NSString *directory in LCProxyAllDataDirectories()) {
        if ([directory isEqualToString:canonicalDirectory]) continue;
        NSString *path = [directory stringByAppendingPathComponent:@"kingcard-state.json"];
        NSDate *mtime = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil].fileModificationDate;
        NSMutableDictionary *candidate = [self stateInDirectory:directory];
        if (!candidate || !mtime) continue;
        if (!bestDate || [mtime compare:bestDate] == NSOrderedDescending) {
            best = candidate;
            bestDate = mtime;
        }
    }
    return best;
}

// A valid canonical file always wins. Migration fallbacks are read only when
// canonical storage is absent or corrupt, then the next locked refresh writes
// the selected fallback to canonical storage.
- (NSMutableDictionary *)loadState {
    return [self canonicalState] ?: [self newestFallbackState] ?: [NSMutableDictionary dictionary];
}

- (BOOL)saveState:(NSMutableDictionary *)state error:(NSError **)outError {
    if (!state) return NO;
    state[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]);
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:&error];
    NSString *directory = LCProxyCanonicalDataDirectory();
    NSString *path = [directory stringByAppendingPathComponent:@"kingcard-state.json"];
    if (!data || !directory.length ||
        ![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        if (outError) *outError = error;
        return NO;
    }
    NSData *written = [NSData dataWithContentsOfFile:path options:0 error:&error];
    id decoded = written ? [NSJSONSerialization JSONObjectWithData:written options:0 error:&error] : nil;
    BOOL intact = [decoded isKindOfClass:[NSDictionary class]] && [(NSDictionary *)decoded isEqualToDictionary:state];
    if (!intact && !error) {
        error = [NSError errorWithDomain:@"LCProxyKing" code:-30 userInfo:@{
            NSLocalizedDescriptionKey: @"王卡状态写入后完整性校验失败",
        }];
    }
    if (outError) *outError = error;
    return intact;
}

- (LCProxyKingLeaseResult)acquireRefreshLeaseWithForce:(BOOL)force
                                                settings:(NSDictionary *)settings
                                                   state:(NSMutableDictionary **)outState
                                           baseUpdatedAt:(double *)outBaseUpdatedAt
                                              generation:(uint64_t *)outGeneration {
    NSArray<NSNumber *> *fds = [self acquireStateLocks];
    if (fds.count == 0) return LCProxyKingLeaseResultLockUnavailable;
    @try {
        NSMutableDictionary *latest = [self canonicalState] ?: [self newestFallbackState] ?: [NSMutableDictionary dictionary];
        NSNumber *updatedAt = [latest[@"updatedAt"] isKindOfClass:[NSNumber class]] ? latest[@"updatedAt"] : nil;
        double baseUpdatedAt = updatedAt.doubleValue;
        if (!force && [self stateHasFreshCredentials:latest matchingSettings:settings]) {
            // Canonical storage may have been missing while a fresh legacy cache
            // existed. Migrate it before declaring the route ready.
            if (![self canonicalState] && ![self saveState:latest error:nil]) {
                return LCProxyKingLeaseResultPersistenceFailed;
            }
            if (outState) *outState = latest;
            if (outBaseUpdatedAt) *outBaseUpdatedAt = baseUpdatedAt;
            return LCProxyKingLeaseResultFreshState;
        }

        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        NSString *leaseOwner = [latest[@"refreshLeaseOwner"] isKindOfClass:[NSString class]] ? latest[@"refreshLeaseOwner"] : nil;
        NSNumber *leaseExpiresAt = [latest[@"refreshLeaseExpiresAt"] isKindOfClass:[NSNumber class]] ? latest[@"refreshLeaseExpiresAt"] : nil;
        if (leaseOwner.length && ![leaseOwner isEqualToString:self.refreshOwnerID] && leaseExpiresAt.doubleValue > now) {
            if (outState) *outState = latest;
            return LCProxyKingLeaseResultHeldByPeer;
        }

        NSNumber *storedGeneration = [latest[@"refreshGeneration"] isKindOfClass:[NSNumber class]] ? latest[@"refreshGeneration"] : @0;
        NSNumber *leaseGeneration = [latest[@"refreshLeaseGeneration"] isKindOfClass:[NSNumber class]] ? latest[@"refreshLeaseGeneration"] : @0;
        uint64_t generation = MAX(storedGeneration.unsignedLongLongValue, leaseGeneration.unsignedLongLongValue) + 1;
        if (generation == 0) generation = 1;
        latest[@"refreshLeaseOwner"] = self.refreshOwnerID;
        latest[@"refreshLeaseGeneration"] = @(generation);
        latest[@"refreshLeaseBaseUpdatedAt"] = @(baseUpdatedAt);
        latest[@"refreshLeaseExpiresAt"] = @(now + LCProxyKingRefreshLeaseTTL);
        if (force) {
            latest[@"refreshInvalidatingGeneration"] = @(generation);
        }
        if (![self saveState:latest error:nil]) return LCProxyKingLeaseResultPersistenceFailed;
        if (outState) *outState = latest;
        if (outBaseUpdatedAt) *outBaseUpdatedAt = baseUpdatedAt;
        if (outGeneration) *outGeneration = generation;
        return LCProxyKingLeaseResultAcquired;
    } @finally {
        [self releaseStateLocks:fds];
    }
}

- (BOOL)renewRefreshLeaseForOwnerID:(NSString *)ownerID
                          generation:(uint64_t)generation
                       baseUpdatedAt:(double)baseUpdatedAt {
    NSArray<NSNumber *> *fds = [self acquireStateLocks];
    if (fds.count == 0) return NO;
    @try {
        NSMutableDictionary *latest = [self canonicalState];
        NSString *leaseOwner = [latest[@"refreshLeaseOwner"] isKindOfClass:[NSString class]] ? latest[@"refreshLeaseOwner"] : nil;
        NSNumber *leaseGeneration = [latest[@"refreshLeaseGeneration"] isKindOfClass:[NSNumber class]] ? latest[@"refreshLeaseGeneration"] : nil;
        NSNumber *leaseBase = [latest[@"refreshLeaseBaseUpdatedAt"] isKindOfClass:[NSNumber class]] ? latest[@"refreshLeaseBaseUpdatedAt"] : nil;
        if (![leaseOwner isEqualToString:ownerID] ||
            leaseGeneration.unsignedLongLongValue != generation ||
            leaseBase.doubleValue != baseUpdatedAt) {
            return NO;
        }
        latest[@"refreshLeaseExpiresAt"] = @([[NSDate date] timeIntervalSince1970] + LCProxyKingRefreshLeaseTTL);
        return [self saveState:latest error:nil];
    } @finally {
        [self releaseStateLocks:fds];
    }
}

- (void)invalidateActiveRefreshLeaseForGeneration:(uint64_t)generation {
    BOOL active = NO;
    [self.lock lock];
    if (self.refreshing && self.refreshLeaseHeartbeatGeneration == generation) {
        self.refreshLeaseValid = NO;
        active = YES;
    }
    [self.lock unlock];
    if (active) [self clearForwarderKingState];
}

- (BOOL)renewActiveRefreshLeaseForOwnerID:(NSString *)ownerID
                                generation:(uint64_t)generation
                             baseUpdatedAt:(double)baseUpdatedAt {
    BOOL renewed = [self renewRefreshLeaseForOwnerID:ownerID generation:generation baseUpdatedAt:baseUpdatedAt];
    if (!renewed) [self invalidateActiveRefreshLeaseForGeneration:generation];
    return renewed;
}

- (void)startRefreshLeaseHeartbeatForOwnerID:(NSString *)ownerID
                                   generation:(uint64_t)generation
                                baseUpdatedAt:(double)baseUpdatedAt {
    dispatch_source_t heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    dispatch_source_set_timer(heartbeat,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LCProxyKingRefreshLeaseHeartbeatInterval * NSEC_PER_SEC)),
                              (uint64_t)(LCProxyKingRefreshLeaseHeartbeatInterval * NSEC_PER_SEC),
                              (uint64_t)(NSEC_PER_SEC));
    __weak LCProxyKing *weakSelf = self;
    dispatch_source_set_event_handler(heartbeat, ^{
        LCProxyKing *strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf renewActiveRefreshLeaseForOwnerID:ownerID generation:generation baseUpdatedAt:baseUpdatedAt];
        }
    });
    [self.lock lock];
    dispatch_source_t oldHeartbeat = self.refreshLeaseHeartbeat;
    self.refreshLeaseHeartbeat = heartbeat;
    self.refreshLeaseHeartbeatGeneration = generation;
    self.refreshLeaseValid = YES;
    [self.lock unlock];
    if (oldHeartbeat) dispatch_source_cancel(oldHeartbeat);
    dispatch_resume(heartbeat);
}

- (BOOL)stopRefreshLeaseHeartbeat {
    [self.lock lock];
    dispatch_source_t heartbeat = self.refreshLeaseHeartbeat;
    BOOL valid = self.refreshLeaseValid;
    self.refreshLeaseHeartbeat = nil;
    self.refreshLeaseHeartbeatGeneration = 0;
    self.refreshLeaseValid = YES;
    [self.lock unlock];
    if (heartbeat) dispatch_source_cancel(heartbeat);
    return valid;
}

- (LCProxyKingCommitResult)commitRefreshState:(NSMutableDictionary *)state
                                baseUpdatedAt:(double)baseUpdatedAt
                                      ownerID:(NSString *)ownerID
                                   generation:(uint64_t)generation
                                   allowWrite:(BOOL)allowWrite {
    NSArray<NSNumber *> *fds = [self acquireStateLocks];
    if (fds.count == 0) return LCProxyKingCommitResultLockUnavailable;
    @try {
        NSMutableDictionary *latest = [self canonicalState];
        NSString *leaseOwner = [latest[@"refreshLeaseOwner"] isKindOfClass:[NSString class]] ? latest[@"refreshLeaseOwner"] : nil;
        NSNumber *leaseGeneration = [latest[@"refreshLeaseGeneration"] isKindOfClass:[NSNumber class]] ? latest[@"refreshLeaseGeneration"] : nil;
        NSNumber *leaseBase = [latest[@"refreshLeaseBaseUpdatedAt"] isKindOfClass:[NSNumber class]] ? latest[@"refreshLeaseBaseUpdatedAt"] : nil;
        if (![leaseOwner isEqualToString:ownerID] || leaseGeneration.unsignedLongLongValue != generation ||
            leaseBase.doubleValue != baseUpdatedAt) {
            return [self stateHasFreshCredentials:latest] ? LCProxyKingCommitResultPeerState : LCProxyKingCommitResultFenced;
        }

        NSMutableDictionary *committed = allowWrite ? [state mutableCopy] : [latest mutableCopy];
        if (!allowWrite) {
            // A failed refresh invalidates the control plane: no process may
            // resurrect the previous route from persistent state.
            for (NSString *key in @[
                @"guid", @"qua2", @"token", @"key", @"qtype",
                @"queen_http", @"queen_https", @"tokenExpireEpoch",
                @"proxyExpireEpoch", @"credentialInputSignature"
            ]) {
                [committed removeObjectForKey:key];
            }
        }
        [committed removeObjectForKey:@"refreshLeaseOwner"];
        [committed removeObjectForKey:@"refreshLeaseGeneration"];
        [committed removeObjectForKey:@"refreshLeaseBaseUpdatedAt"];
        [committed removeObjectForKey:@"refreshLeaseExpiresAt"];
        [committed removeObjectForKey:@"refreshInvalidatingGeneration"];
        committed[@"refreshGeneration"] = @(generation);
        if (![self saveState:committed error:nil]) return LCProxyKingCommitResultPersistenceFailed;
        return allowWrite ? LCProxyKingCommitResultWroteState : LCProxyKingCommitResultNotCommitted;
    } @finally {
        [self releaseStateLocks:fds];
    }
}

- (void)clearForwarderKingState {
    [self.lock lock];
    if (self.forwarder) kp_forwarder_clear_king_state(self.forwarder);
    self.lastRefreshSuccess = NO;
    [self.lock unlock];
}

- (NSDictionary *)settingsSnapshot {
    return [[LCProxyConfig shared] load];
}

- (NSString *)syncFetchGuid:(NSString *)qua2 timeout:(NSTimeInterval)timeout error:(NSError **)outErr {
    NSTimeInterval requestTimeout = MIN(MAX(timeout, 1.0), 15.0);
    NSTimeInterval requestWindow = requestTimeout + 10.0;
    NSTimeInterval permitLifetime = requestWindow + LCProxyKingPBProxyBootstrapSetupAllowance;
    [self.lock lock];
    kp_forwarder *forwarder = self.forwarder;
    int port = self.publishedForwarderPort;
    BOOL routePublished = self.routePublished && forwarder != NULL &&
                          kp_forwarder_listen_fd_valid(forwarder) == 1;
    if (routePublished) {
        routePublished = kp_forwarder_retain(forwarder) == 0;
    }
    NSString *bootstrapPassword = [NSUUID UUID].UUIDString;
    NSString *bootstrapCredential = [NSString stringWithFormat:@"lcproxy-bootstrap:%@", bootstrapPassword];
    NSString *bootstrapAuthorization = [NSString stringWithFormat:@"Basic %@",
        [[bootstrapCredential dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]];
    uint64_t bootstrapLease = 0;
    if (routePublished) {
        bootstrapLease = kp_forwarder_grant_pbproxy_bootstrap(forwarder, bootstrapAuthorization.UTF8String,
            (int)ceil(permitLifetime * 1000.0));
        routePublished = bootstrapLease != 0;
    }
    [self.lock unlock];
    if (!routePublished) {
        if (forwarder) kp_forwarder_release(forwarder);
        if (outErr) *outErr = [NSError errorWithDomain:@"LCProxyKing" code:-20
            userInfo:@{NSLocalizedDescriptionKey: @"王卡本地路由尚未发布"}];
        return nil;
    }
    NSLock *completionLock = [[NSLock alloc] init];
    __block NSString *completedGuid = nil;
    __block NSError *completedError = nil;
    __block BOOL requestClosed = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [LCProxyKingClient fetchGuidFromServerWithQua2:qua2
                                                        throughLocalProxyPort:port
                                                     bootstrapProxyPassword:bootstrapPassword
                                                                      timeout:requestTimeout
                                                                   completion:^(NSString * _Nullable g, NSError * _Nullable e) {
        [completionLock lock];
        if (requestClosed) {
            [completionLock unlock];
            return;
        }
        completedGuid = g;
        completedError = e;
        [completionLock unlock];
        dispatch_semaphore_signal(sem);
    }];
    if (!task) {
        kp_forwarder_revoke_pbproxy_bootstrap(forwarder, bootstrapLease);
        kp_forwarder_release(forwarder);
        if (outErr) *outErr = [NSError errorWithDomain:@"LCProxyKing" code:-21
            userInfo:@{NSLocalizedDescriptionKey: @"PBProxy GetGuid 请求未启动"}];
        return nil;
    }
    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(requestWindow * NSEC_PER_SEC)));
    NSString *guid = nil;
    NSError *err = nil;
    [completionLock lock];
    requestClosed = YES;
    if (waitResult != 0) {
        err = [NSError errorWithDomain:@"LCProxyKing" code:-21
            userInfo:@{NSLocalizedDescriptionKey: @"PBProxy GetGuid 请求超时"}];
    } else {
        guid = completedGuid;
        err = completedError;
    }
    [completionLock unlock];
    if (waitResult != 0) [task cancel];
    kp_forwarder_revoke_pbproxy_bootstrap(forwarder, bootstrapLease);
    kp_forwarder_release(forwarder);
    if (outErr) *outErr = err;
    return guid;
}

- (NSDictionary *)syncFetchToken:(NSString *)guid qua2:(NSString *)qua2 phone:(NSString *)phone timeout:(NSTimeInterval)timeout error:(NSError **)outErr {
    __block NSDictionary *info = nil;
    __block NSError *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [LCProxyKingClient fetchTokenWithGuid:guid qua2:qua2 phone:phone timeout:timeout completion:^(NSDictionary * _Nullable i, NSError * _Nullable e) {
        info = i;
        err = e;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 10.0) * NSEC_PER_SEC)));
    if (outErr) *outErr = err;
    return info;
}

- (NSDictionary *)syncFetchProxies:(NSString *)guid qua2:(NSString *)qua2 params:(NSDictionary *)params timeout:(NSTimeInterval)timeout error:(NSError **)outErr {
    __block NSDictionary *info = nil;
    __block NSError *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [LCProxyKingClient fetchQueenProxiesWithGuid:guid qua2:qua2 params:params timeout:timeout completion:^(NSDictionary * _Nullable i, NSError * _Nullable e) {
        info = i;
        err = e;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 10.0) * NSEC_PER_SEC)));
    if (outErr) *outErr = err;
    return info;
}

- (int)tcpConnectMsForProxy:(NSString *)proxy {
    NSArray *parts = [proxy componentsSeparatedByString:@":"];
    if (parts.count != 2) return -1;
    int port = [parts[1] intValue];
    if (port <= 0 || port > 65535) return -1;
    return kpq_tcp_connect_ms([parts[0] UTF8String], port, 800);
}

// 代理池按 TCP 连通延迟排序。逐个 800ms 探测是串行的；刷新在探测前已经释放
// 跨进程状态锁，避免池子大时阻塞其他 LiveContainer 实例。只探测前几个节点，
// 其余按服务端原顺序排在已探测节点之后（故障转移仍然可用）。
static const NSUInteger KP_LATENCY_PROBE_MAX = 8;

- (NSArray<NSString *> *)proxiesSortedByLatency:(NSArray<NSString *> *)proxies {
    if (proxies.count <= 1) return proxies;
    NSUInteger probeCount = MIN(proxies.count, KP_LATENCY_PROBE_MAX);
    NSArray<NSString *> *head = [proxies subarrayWithRange:NSMakeRange(0, probeCount)];
    NSMutableArray<NSDictionary *> *measured = [NSMutableArray arrayWithCapacity:probeCount];
    for (NSString *proxy in head) {
        int latency = [self tcpConnectMsForProxy:proxy];
        [measured addObject:@{
            @"proxy": proxy,
            @"latency": @(latency < 0 ? NSIntegerMax : latency),
        }];
    }
    [measured sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger msA = [a[@"latency"] integerValue];
        NSInteger msB = [b[@"latency"] integerValue];
        if (msA < msB) return NSOrderedAscending;
        if (msA > msB) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSMutableArray<NSString *> *sortedHead = [NSMutableArray arrayWithCapacity:probeCount];
    for (NSDictionary *entry in measured) [sortedHead addObject:entry[@"proxy"]];
    if (proxies.count > probeCount) {
        NSArray<NSString *> *tail = [proxies subarrayWithRange:NSMakeRange(probeCount, proxies.count - probeCount)];
        return [sortedHead arrayByAddingObjectsFromArray:tail];
    }
    return sortedHead;
}

- (NSString *)localRandomGuid {
    uint8_t bytes[16];
    arc4random_buf(bytes, sizeof(bytes));
    NSMutableString *s = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [s appendFormat:@"%02X", bytes[i]];
    return s;
}

static const NSUInteger LCProxyKingRefreshLogMax = 20;

// 取号日志：内存环形缓冲（新→旧，最多 LCProxyKingRefreshLogMax 条）。成功刷新
// 会随完整状态提交到 kingcard-state.json；失败刷新只留在本进程，避免写入半成品状态。
- (void)pushRefreshLog:(BOOL)ok src:(NSString *)src ms:(double)ms msg:(NSString *)msg intoState:(NSMutableDictionary *)state {
    NSDictionary *entry = @{
        @"ts": @([[NSDate date] timeIntervalSince1970]),
        @"ok": @(ok),
        @"src": src ?: @"",
        @"ms": @(round(ms)),
        @"msg": msg ?: @"",
    };
    [self.lock lock];
    [self.refreshLog insertObject:entry atIndex:0];
    while (self.refreshLog.count > LCProxyKingRefreshLogMax) {
        [self.refreshLog removeLastObject];
    }
    NSArray *snapshot = [self.refreshLog copy];
    [self.lock unlock];
    if (state) state[@"refreshLog"] = snapshot;
}

// ---------------------------------------------------------------------------
// 新版 Queen/King 刷新流程：
//   GUID（PBProxy GetGuid，失败本地生成） -> Q-Token/Q-Key（旧 WUP TokenInfoReq）
//   -> queen_http / queen_https（旧 WUP proxyip/getIPListByRouter）
//   -> 写入 kp_forwarder
// ---------------------------------------------------------------------------
- (BOOL)refreshCredentials {
    return [self refreshCredentialsWithForce:NO];
}

- (BOOL)refreshCredentialsForce {
    return [self refreshCredentialsWithForce:YES];
}

- (BOOL)refreshCredentialsWithForce:(BOOL)force {
    [self.lock lock];
    // Credential bootstrap must be allowed before the local route is published;
    // routePublished only gates user traffic through the forwarder. Otherwise a
    // shared app whose forwarder is still starting can never acquire a GUID and
    // stays offline forever.
    if (self.refreshing) {
        [self.lock unlock];
        return NO;
    }
    self.refreshing = YES;
    [self.lock unlock];
    if (force) [self clearForwarderKingState];

    NSDictionary *settings = [self settingsSnapshot];
    NSMutableDictionary *state = nil;
    double baseUpdatedAt = 0;
    uint64_t generation = 0;
    LCProxyKingLeaseResult leaseResult = [self acquireRefreshLeaseWithForce:force
                                                                     settings:settings
                                                                        state:&state
                                                                baseUpdatedAt:&baseUpdatedAt
                                                                   generation:&generation];
    if (leaseResult == LCProxyKingLeaseResultLockUnavailable) {
        [self scheduleRefreshRetryAfterLockContention];
        [self clearForwarderKingState];
        [self.lock lock];
        self.refreshing = NO;
        self.lastRefreshSuccess = NO;
        self.lastRefresh = LCProxyKingNow();
        self.lastError = @"kingcard-state.json 正被其他实例锁定，稍后自动重试";
        [self.lock unlock];
        return NO;
    }
    if (leaseResult == LCProxyKingLeaseResultPersistenceFailed) {
        [self clearForwarderKingState];
        [self.lock lock];
        self.refreshing = NO;
        self.lastRefreshSuccess = NO;
        self.lastRefresh = LCProxyKingNow();
        self.lastError = @"王卡状态无法持久化，已停止转发";
        [self.lock unlock];
        return NO;
    }
    if (leaseResult == LCProxyKingLeaseResultFreshState) {
        [self loadCachedStateIntoForwarder];
        [self.lock lock];
        self.refreshing = NO;
        self.lastRefreshSuccess = YES;
        self.lastRefresh = LCProxyKingNow();
        self.lastSource = @"cache";
        self.lastError = @"";
        [self.lock unlock];
        return YES;
    }
    if (leaseResult == LCProxyKingLeaseResultHeldByPeer) {
        NSNumber *expiresAt = [state[@"refreshLeaseExpiresAt"] isKindOfClass:[NSNumber class]] ? state[@"refreshLeaseExpiresAt"] : nil;
        NSTimeInterval retryAfter = MAX(1.0, expiresAt.doubleValue - [[NSDate date] timeIntervalSince1970]);
        if ([self stateHasFreshCredentials:state matchingSettings:settings]) {
            [self loadCachedStateIntoForwarder];
        } else {
            [self clearForwarderKingState];
        }
        [self scheduleRefreshRetryAfter:retryAfter];
        [self.lock lock];
        self.refreshing = NO;
        self.lastRefreshSuccess = NO;
        self.lastRefresh = LCProxyKingNow();
        self.lastSource = @"refresh-peer";
        self.lastError = @"其他实例正在刷新王卡凭证，稍后自动重试";
        [self.lock unlock];
        return NO;
    }

    [self startRefreshLeaseHeartbeatForOwnerID:self.refreshOwnerID
                                    generation:generation
                                 baseUpdatedAt:baseUpdatedAt];

    NSDate *t0 = [NSDate date];
    NSMutableString *steps = [NSMutableString string];
    // 记录是否真的向上游发起了取号/取代理池请求；纯缓存命中时不写取号日志。
    BOOL actuallyFetchedUpstream = NO;

    NSString *source = @"";
    NSString *phone = [settings[@"kingPhone"] isKindOfClass:[NSString class]] && [settings[@"kingPhone"] length] ? settings[@"kingPhone"] : @"18812341234";
    NSString *qtype = [settings[@"kingQType"] isKindOfClass:[NSString class]] && [settings[@"kingQType"] length] ? settings[@"kingQType"] : @"httpcom";
    NSTimeInterval timeout = 15.0;

    // QUA2
    NSString *qua2 = [state[@"qua2"] isKindOfClass:[NSString class]] && [state[@"qua2"] length] ? state[@"qua2"] : nil;
    if (!qua2) {
        qua2 = [LCProxyKingClient generateQua2WithModel:@"" width:1080 height:1920 os:@"10" api:33];
        state[@"qua2"] = qua2;
    }

    // Q-GUID
    NSString *guidOverride = [settings[@"kingGuidOverride"] isKindOfClass:[NSString class]] && [settings[@"kingGuidOverride"] length] ? settings[@"kingGuidOverride"] : nil;
    if (guidOverride && !LCProxyKingHexStringValid(guidOverride)) {
        [steps appendString:@"GUID: 配置覆盖格式无效\n"];
        return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps baseUpdatedAt:baseUpdatedAt error:@"GUID 配置覆盖必须是 32 位十六进制字符串"];
    }
    NSString *inputSignature = [self credentialInputSignatureForSettings:settings];
    NSString *storedInputSignature = [state[@"credentialInputSignature"] isKindOfClass:[NSString class]]
        ? state[@"credentialInputSignature"] : nil;
    if (![storedInputSignature isEqualToString:inputSignature]) {
        // Tokens and Queen pools are tied to the GUID and request parameters.
        // Keep only the GUID/QUA2 candidates until their dependencies refresh.
        for (NSString *key in @[
            @"token", @"key", @"qtype", @"queen_http", @"queen_https",
            @"tokenExpireEpoch", @"proxyExpireEpoch"
        ]) {
            [state removeObjectForKey:key];
        }
    }
    NSString *guid = nil;
    if (guidOverride) {
        guid = guidOverride;
    } else {
        NSString *stored = [state[@"guid"] isKindOfClass:[NSString class]] ? state[@"guid"] : nil;
        if (LCProxyKingHexStringValid(stored)) guid = stored;
    }
    if (!guidOverride && (force || !guid)) {
        if (![self renewActiveRefreshLeaseForOwnerID:self.refreshOwnerID generation:generation baseUpdatedAt:baseUpdatedAt]) {
            return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps baseUpdatedAt:baseUpdatedAt error:@"王卡刷新租约续期失败"];
        }
        NSError *guidErr = nil;
        guid = [self syncFetchGuid:qua2 timeout:timeout error:&guidErr];
        if (!guid) {
            [steps appendFormat:@"GUID: PBProxy 失败 %@\n", guidErr.localizedDescription ?: @""];
            guid = [self localRandomGuid];
            source = @"guid-local";
            [steps appendFormat:@"GUID: 本地生成（服务器失败 %@）\n", guidErr.localizedDescription ?: @""];
        } else {
            source = @"guid-pbprx";
            actuallyFetchedUpstream = YES;
            [steps appendString:@"GUID: PBProxy 获取\n"];
        }
        state[@"guid"] = guid;
    } else {
        [steps appendString:guidOverride ? @"GUID: 使用配置覆盖\n" : @"GUID: 复用缓存\n"];
    }
    state[@"guid"] = guid;

    // Q-Token / Q-Key
    NSString *tokenOverride = [settings[@"kingTokenOverride"] isKindOfClass:[NSString class]] && [settings[@"kingTokenOverride"] length] ? settings[@"kingTokenOverride"] : nil;
    NSString *keyOverride = [settings[@"kingKeyOverride"] isKindOfClass:[NSString class]] && [settings[@"kingKeyOverride"] length] ? settings[@"kingKeyOverride"] : nil;
    NSString *token = nil;
    NSString *qkey = nil;
    if ((tokenOverride != nil) != (keyOverride != nil)) {
        [steps appendString:@"Q-Token/Q-Key: 配置覆盖必须同时提供\n"];
        return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps baseUpdatedAt:baseUpdatedAt error:@"Q-Token/Q-Key 配置覆盖不完整"];
    }
    if (tokenOverride && keyOverride) {
        token = tokenOverride;
        qkey = keyOverride;
        source = @"token-override";
        state[@"tokenExpireEpoch"] = @([[NSDate date] timeIntervalSince1970] + 24.0 * 60.0 * 60.0);
    } else {
        NSNumber *tokenExpireEpoch = [state[@"tokenExpireEpoch"] isKindOfClass:[NSNumber class]] ? state[@"tokenExpireEpoch"] : nil;
        NSString *storedToken = [state[@"token"] isKindOfClass:[NSString class]] ? state[@"token"] : nil;
        NSString *storedKey = [state[@"key"] isKindOfClass:[NSString class]] ? state[@"key"] : nil;
        double nowEpoch = [[NSDate date] timeIntervalSince1970];
        if (!force && !tokenOverride && !keyOverride && storedToken.length && storedKey.length && tokenExpireEpoch && tokenExpireEpoch.doubleValue > nowEpoch + LCProxyKingRefreshLeadTime) {
            token = storedToken;
            qkey = storedKey;
        } else {
            if (![self renewActiveRefreshLeaseForOwnerID:self.refreshOwnerID generation:generation baseUpdatedAt:baseUpdatedAt]) {
                return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps baseUpdatedAt:baseUpdatedAt error:@"王卡刷新租约续期失败"];
            }
            NSError *tokErr = nil;
            NSDictionary *tokInfo = [self syncFetchToken:guid qua2:qua2 phone:phone timeout:timeout error:&tokErr];
            if (!tokInfo) {
                [steps appendFormat:@"Q-Token: 失败 %@\n", tokErr.localizedDescription ?: @"unknown"];
                return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps baseUpdatedAt:baseUpdatedAt error:[NSString stringWithFormat:@"Q-Token 获取失败: %@", tokErr.localizedDescription ?: @"unknown"]];
            }
            actuallyFetchedUpstream = YES;
            token = tokenOverride ?: tokInfo[@"token"];
            qkey = keyOverride ?: tokInfo[@"qkey"];
            state[@"token"] = token;
            state[@"key"] = qkey;
            NSNumber *expire = tokInfo[@"expire_seconds"];
            // 服务器宣称的有效期可能偏长，Q-Token 实际会更早失效。
            // 按 80% 有效期设置本地过期时间，并至少保留 60 秒，提前触发主动刷新。
            double rawExpire = ([expire isKindOfClass:[NSNumber class]] && expire.integerValue > 0) ? expire.doubleValue : 7200.0;
            double effectiveExpire = rawExpire * 0.8;
            if (effectiveExpire < 60.0) effectiveExpire = 60.0;
            state[@"tokenExpireEpoch"] = @(nowEpoch + effectiveExpire);
            source = [NSString stringWithFormat:@"token-%@", tokInfo[@"mode"] ?: @"?"];
            NSNumber *expireSeconds = tokInfo[@"expire_seconds"];
            [steps appendFormat:@"Q-Token/Q-Key: %@\n有效期=%@s\n",
                tokInfo[@"mode"] ?: @"?",
                expireSeconds ?: @"?"];
        }
    }
    if (!token.length || !qkey.length) {
        [steps appendString:@"Q-Token/Q-Key: 为空\n"];
        return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps baseUpdatedAt:baseUpdatedAt error:@"Q-Token/Q-Key 为空"];
    }
    state[@"token"] = token;
    state[@"key"] = qkey;

    // queen_http / queen_https
    NSArray *queenHttp = [state[@"queen_http"] isKindOfClass:[NSArray class]] ? state[@"queen_http"] : nil;
    NSArray *queenHttps = [state[@"queen_https"] isKindOfClass:[NSArray class]] ? state[@"queen_https"] : nil;
    NSNumber *proxyExpireEpoch = [state[@"proxyExpireEpoch"] isKindOfClass:[NSNumber class]] ? state[@"proxyExpireEpoch"] : nil;
    double nowEpoch2 = [[NSDate date] timeIntervalSince1970];
    if (force || !queenHttp.count || !queenHttps.count || !proxyExpireEpoch || proxyExpireEpoch.doubleValue <= nowEpoch2 + LCProxyKingRefreshLeadTime) {
        NSDictionary *params = @{
            @"apn": [settings[@"kingApn"] isKindOfClass:[NSString class]] ? settings[@"kingApn"] : @"UNKNOW",
            @"typeName": [settings[@"kingTypeName"] isKindOfClass:[NSString class]] ? settings[@"kingTypeName"] : @"UNKNOW",
            @"subtype": [settings[@"kingSubtype"] isKindOfClass:[NSNumber class]] ? settings[@"kingSubtype"] : @0,
            @"extraInfo": [settings[@"kingExtraInfo"] isKindOfClass:[NSString class]] ? settings[@"kingExtraInfo"] : @"UNKNOW",
            @"mccmnc": [settings[@"kingMccmnc"] isKindOfClass:[NSString class]] ? settings[@"kingMccmnc"] : @"NULLNULL",
            @"cardType": [settings[@"kingCardType"] isKindOfClass:[NSNumber class]] ? settings[@"kingCardType"] : @1,
        };
        if (![self renewActiveRefreshLeaseForOwnerID:self.refreshOwnerID generation:generation baseUpdatedAt:baseUpdatedAt]) {
            return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps baseUpdatedAt:baseUpdatedAt error:@"王卡刷新租约续期失败"];
        }
        NSError *proxyErr = nil;
        NSDictionary *proxyInfo = [self syncFetchProxies:guid qua2:qua2 params:params timeout:timeout error:&proxyErr];
        if (!proxyInfo) {
            [steps appendFormat:@"代理池: 失败 %@\n", proxyErr.localizedDescription ?: @"unknown"];
            return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps baseUpdatedAt:baseUpdatedAt error:[NSString stringWithFormat:@"Queen 代理池获取失败: %@", proxyErr.localizedDescription ?: @"unknown"]];
        }
        actuallyFetchedUpstream = YES;
        if (![self renewActiveRefreshLeaseForOwnerID:self.refreshOwnerID generation:generation baseUpdatedAt:baseUpdatedAt]) {
            return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps baseUpdatedAt:baseUpdatedAt error:@"王卡刷新租约续期失败"];
        }
        queenHttp = [self proxiesSortedByLatency:[self validatedProxyPool:proxyInfo[@"queen_http"]]];
        queenHttps = [self proxiesSortedByLatency:[self validatedProxyPool:proxyInfo[@"queen_https"]]];
        state[@"queen_http"] = queenHttp ?: @[];
        state[@"queen_https"] = queenHttps ?: @[];
        // 服务端 iLifePeriod 单位为「小时」（反编译官方 App：m.java 中
        // System.currentTimeMillis() + iLifePeriod * 3600000）。不能当作秒，
        // 否则 8（=8小时）会被当成 8 秒导致代理池立即过期、疯狂重新取号。
        double proxyLifeHours = 1.0;
        if ([proxyInfo[@"lifePeriod"] isKindOfClass:[NSNumber class]] && [proxyInfo[@"lifePeriod"] doubleValue] > 0) {
            proxyLifeHours = [proxyInfo[@"lifePeriod"] doubleValue];
        }
        if (proxyLifeHours < 1.0) proxyLifeHours = 1.0;
        state[@"proxyExpireEpoch"] = @(nowEpoch2 + proxyLifeHours * 3600.0);
        source = [NSString stringWithFormat:@"proxy-oldwup-%@", proxyInfo[@"mode"] ?: @"?"];
        [steps appendFormat:@"代理池: http=%lu https=%lu lifePeriod=%.0fh server=%@\nsApn=%@ bProxy=%@\n",
            (unsigned long)queenHttp.count, (unsigned long)queenHttps.count,
            proxyLifeHours,
            proxyInfo[@"server"] ?: @"?",
            proxyInfo[@"sApn"] ?: @"?",
            proxyInfo[@"bProxy"] ?: @"?"];
        [steps appendFormat:@"  HTTP: %@\n", [queenHttp componentsJoinedByString:@", "]];
        [steps appendFormat:@"  HTTPS: %@\n", [queenHttps componentsJoinedByString:@", "]];
    }

    if (!queenHttp.count || !queenHttps.count) {
        [steps appendString:@"代理池: 为空\n"];
        return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps baseUpdatedAt:baseUpdatedAt error:@"Queen 代理池为空"];
    }

    [steps appendFormat:@"提交凭证: http=%lu https=%lu\n",
        (unsigned long)queenHttp.count, (unsigned long)queenHttps.count];
    // 只有真正请求了上游（或强制刷新）才记录取号日志；纯缓存命中不刷日志。
    if (force || actuallyFetchedUpstream) {
        [self pushRefreshLog:YES src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 msg:steps intoState:state];
    }
    state[@"qtype"] = qtype;
    state[@"credentialInputSignature"] = inputSignature;
    return [self finishRefreshWithState:state success:YES src:source
                                      ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:nil
                           baseUpdatedAt:baseUpdatedAt error:nil];
}

- (BOOL)finishRefreshWithState:(NSMutableDictionary *)state success:(BOOL)success
                           src:(NSString *)src ms:(double)ms
                         steps:(NSString *)steps baseUpdatedAt:(double)baseUpdatedAt
                          error:(NSString *)error {
    if (![self stopRefreshLeaseHeartbeat]) {
        success = NO;
        error = @"王卡刷新租约续期失败";
    }
    if (steps.length) {
        [self pushRefreshLog:success src:src ms:ms msg:steps intoState:state];
    }
    NSString *leaseOwner = [state[@"refreshLeaseOwner"] isKindOfClass:[NSString class]]
        ? state[@"refreshLeaseOwner"] : self.refreshOwnerID;
    NSNumber *leaseGeneration = [state[@"refreshLeaseGeneration"] isKindOfClass:[NSNumber class]]
        ? state[@"refreshLeaseGeneration"] : @0;
    LCProxyKingCommitResult commitResult = [self commitRefreshState:state
                                                       baseUpdatedAt:baseUpdatedAt
                                                             ownerID:leaseOwner
                                                          generation:leaseGeneration.unsignedLongLongValue
                                                          allowWrite:success];
    BOOL peerCompletedRefresh = commitResult == LCProxyKingCommitResultPeerState;
    BOOL refreshAvailable = (success && commitResult == LCProxyKingCommitResultWroteState) || peerCompletedRefresh;
    if (commitResult == LCProxyKingCommitResultLockUnavailable ||
        commitResult == LCProxyKingCommitResultFenced) {
        [self scheduleRefreshRetryAfterLockContention];
    }
    if (refreshAvailable) {
        // Reload the winner from disk so this forwarder and concurrent guests
        // use the same credentials after cross-process arbitration.
        [self loadCachedStateIntoForwarder];
    } else {
        [self clearForwarderKingState];
    }
    [self.lock lock];
    self.refreshing = NO;
    self.lastRefreshSuccess = refreshAvailable;
    self.lastRefresh = LCProxyKingNow();
    self.lastSource = peerCompletedRefresh ? @"cache-peer" : (src ?: @"");
    self.lastError = refreshAvailable ? @"" : (commitResult == LCProxyKingCommitResultLockUnavailable
        ? @"kingcard-state.json 正被其他实例锁定，稍后自动重试"
        : (commitResult == LCProxyKingCommitResultPersistenceFailed
            ? @"王卡状态无法持久化，已停止转发"
            : (commitResult == LCProxyKingCommitResultFenced
                ? @"王卡刷新租约已失效，已停止转发"
                : (error ?: @""))));
    [self.lock unlock];
    return refreshAvailable;
}

- (BOOL)performHealthCheck {
    [self.lifecycleLock lock];
    @try {
        [self.lock lock];
        kp_forwarder *fw = self.forwarder;
        int port = fw ? kp_forwarder_port(fw) : 0;
        [self.lock unlock];

        if (!fw || port <= 0 || kp_forwarder_listen_fd_valid(fw) != 1) {
            [self.lock lock];
            self.lastHealthCheckOk = NO;
            self.lastHealthCheckAt = [[NSDate date] timeIntervalSince1970];
            [self.lock unlock];
            return NO;
        }

        BOOL listenOk = kp_forwarder_probe_local(fw, 800) == 1;
        BOOL proxyOk = NO;
        if (listenOk) {
            // The local forwarder builds Queen headers from its own cached
            // credentials, so the probe credentials below can be arbitrary.
            proxyOk = kp_probe_generate204("127.0.0.1", port, "probe", "probe", 4000) == 1;
        }

        [self.lock lock];
        self.lastHealthCheckOk = listenOk && proxyOk;
        self.lastHealthCheckAt = [[NSDate date] timeIntervalSince1970];
        [self.lock unlock];
        return self.lastHealthCheckOk;
    } @finally {
        [self.lifecycleLock unlock];
    }
}

- (void)shutdownActiveClients {
    [self.lifecycleLock lock];
    @try {
        [self.lock lock];
        if (self.forwarder) kp_forwarder_shutdown_clients(self.forwarder);
        [self.lock unlock];
    } @finally {
        [self.lifecycleLock unlock];
    }
}

- (NSUInteger)activeClientCount {
    [self.lock lock];
    int count = self.forwarder ? kp_forwarder_active_clients(self.forwarder) : 0;
    [self.lock unlock];
    return count > 0 ? (NSUInteger)count : 0;
}

- (NSDictionary *)forwarderStats {
    [self.lock lock];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"httpRequests"] = @0;
    d[@"httpsConnects"] = @0;
    d[@"directFallbacks"] = @0;
    d[@"refreshCalls"] = @0;
    d[@"proxyErrors"] = @0;
    d[@"recentDirectHosts"] = @[];
    if (self.forwarder) {
        kp_forwarder_stats stats;
        kp_forwarder_get_stats(self.forwarder, &stats);
        d[@"httpRequests"] = @(stats.http_requests);
        d[@"httpsConnects"] = @(stats.https_connects);
        d[@"directFallbacks"] = @(stats.direct_fallbacks);
        d[@"refreshCalls"] = @(stats.refresh_calls);
        d[@"proxyErrors"] = @(stats.proxy_errors);
        NSMutableArray *hosts = [NSMutableArray array];
        int hostCount = kp_forwarder_direct_host_count(self.forwarder);
        for (int i = 0; i < hostCount && i < 16; i++) {
            char hostBuf[128];
            if (kp_forwarder_get_direct_host(self.forwarder, i, hostBuf, sizeof(hostBuf)) == 0) {
                [hosts addObject:[NSString stringWithUTF8String:hostBuf] ?: @""];
            }
        }
        d[@"recentDirectHosts"] = hosts;
    }
    [self.lock unlock];
    return d;
}

- (NSDictionary *)status {
    [self.lock lock];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"running"] = @([self isRunning]);
    d[@"forwarderPort"] = @(self.forwarder ? kp_forwarder_port(self.forwarder) : 0);
    d[@"activeForwarderClients"] = @(self.forwarder ? kp_forwarder_active_clients(self.forwarder) : 0);
    d[@"listenFdValid"] = @(self.forwarder ? kp_forwarder_listen_fd_valid(self.forwarder) : 0);
    d[@"lastHealthCheckOk"] = @(self.lastHealthCheckOk);
    d[@"lastHealthCheckAt"] = @(self.lastHealthCheckAt);
    d[@"lastRefreshSuccess"] = @(self.lastRefreshSuccess);
    d[@"lastRefresh"] = self.lastRefresh ?: @"";
    d[@"lastSource"] = self.lastSource ?: @"";
    d[@"lastError"] = self.lastError ?: @"";
    d[@"lastDiagnostics"] = self.lastDiagnostics ?: @"";
    d[@"refreshLog"] = [self.refreshLog copy];
    NSMutableDictionary *state = [self loadState];
    NSString *guid = [state[@"guid"] isKindOfClass:[NSString class]] ? state[@"guid"] : @"";
    if (guid.length > 12) {
        d[@"guidMasked"] = [NSString stringWithFormat:@"%@...%@", [guid substringToIndex:6], [guid substringFromIndex:guid.length - 6]];
    } else {
        d[@"guidMasked"] = guid;
    }
    d[@"queenHttpCount"] = @([state[@"queen_http"] count]);
    d[@"queenHttpsCount"] = @([state[@"queen_https"] count]);
    if (self.forwarder) {
        kp_forwarder_stats stats;
        kp_forwarder_get_stats(self.forwarder, &stats);
        d[@"statHttpRequests"] = @(stats.http_requests);
        d[@"statHttpsConnects"] = @(stats.https_connects);
        d[@"statDirectFallbacks"] = @(stats.direct_fallbacks);
        d[@"statRefreshCalls"] = @(stats.refresh_calls);
        d[@"statProxyErrors"] = @(stats.proxy_errors);

        NSMutableArray *directHosts = [NSMutableArray array];
        int hostCount = kp_forwarder_direct_host_count(self.forwarder);
        for (int i = 0; i < hostCount && i < 16; i++) {
            char hostBuf[128];
            if (kp_forwarder_get_direct_host(self.forwarder, i, hostBuf, sizeof(hostBuf)) == 0) {
                [directHosts addObject:[NSString stringWithUTF8String:hostBuf] ?: @""];
            }
        }
        d[@"recentDirectHosts"] = directHosts;
    }
    [self.lock unlock];
    return d;
}

@end
