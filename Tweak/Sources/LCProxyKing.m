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

NSString *const LCProxyForwarderLifecycleChangedNotification = @"LCProxyForwarderLifecycleChangedNotification";

@interface LCProxyKing ()
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, strong) NSLock *lifecycleLock;
// 退役转发器的异步回收队列（串行）。kp_forwarder_stop 可能等待最长 10s、
// kp_forwarder_free 内部还会再等一轮，绝不能阻塞 runtime apply 路径。
@property (nonatomic, strong) dispatch_queue_t forwarderReaperQueue;
@property (nonatomic, assign) void *forwarderPtr;
@property (nonatomic, strong) NSMutableDictionary *cachedCredentialState;
@property (nonatomic, strong) NSLock *cacheLock;
@property (nonatomic, copy) NSString *resolvedCredentialLogPath;
@property (nonatomic, assign) BOOL desiredForwarderRunning;
@property (nonatomic, assign) NSUInteger forwarderDiscardCount;
@property (nonatomic, assign) NSUInteger refreshArbitrationLossStreak;
@property (nonatomic, copy) NSString *lastForwarderLifecycle;
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
- (void)startRefreshTimer;
- (void)stopRefreshTimer;
- (void)scheduleRefreshRetryAfter:(NSTimeInterval)delay;
- (BOOL)stateHasFreshCredentials:(NSDictionary *)state;
- (BOOL)stateHasFreshCredentials:(NSDictionary *)state matchingSettings:(NSDictionary *)settings;
- (NSArray<NSString *> *)validatedProxyPool:(id)value;
- (NSString *)credentialInputSignatureForSettings:(NSDictionary *)settings;
- (void)clearForwarderKingState;
- (void)retireForwarder:(kp_forwarder *)fw;
- (NSString *)credentialLogPath;
- (void)appendCredentialRecord:(NSDictionary *)record;
- (NSMutableDictionary *)newestValidRecordFromLog;
- (void)trimCredentialLogIfNeeded;
- (void)trimAppendLogAtPath:(NSString *)path maxLines:(NSUInteger)maxLines;
- (void)appendSharedRefreshLogEntry:(NSDictionary *)entry;
- (void)notifyForwarderLifecycle:(NSString *)reason;
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
        _forwarderReaperQueue = dispatch_queue_create("com.liveproxy.king.forwarder-reaper", DISPATCH_QUEUE_SERIAL);
        _cacheLock = [[NSLock alloc] init];
        _refreshLog = [[NSMutableArray alloc] init];
        _lastHealthCheckOk = NO;
        _lastHealthCheckAt = 0;
        _routePublished = NO;
        _publishedForwarderPort = 0;
        _desiredForwarderRunning = NO;
        _forwarderDiscardCount = 0;
        _refreshArbitrationLossStreak = 0;
        _refreshOwnerID = [NSUUID UUID].UUIDString;
        _cachedCredentialState = [[NSMutableDictionary alloc] init];
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

// 只在“转发器消失且配置仍需要它”的路径上调用。observer 会重跑一次 runtime apply，
// 因此绝不能在持有 self.lock 时同步发通知（observer 会回到 applyConfig）。
- (void)notifyForwarderLifecycle:(NSString *)reason {
    self.lastForwarderLifecycle = reason ?: @"";
    NSString *payload = reason ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:LCProxyForwarderLifecycleChangedNotification
                                                            object:self
                                                          userInfo:@{@"reason": payload}];
    });
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
        self.desiredForwarderRunning = NO;
        [self.lock unlock];
        // 不能在持有 self.lock 时 stop/free（client 线程可能正等 self.lock 做取号），
        // 更不能在需要及时返回的路径上同步 stop/free —— 见 retireForwarder:。
        [self retireForwarder:oldForwarder];
        return;
    }

    // shouldRun 但当前没有 running 的转发器：重建。
    //
    // ★ 顺序至关重要：**先建好并启动新转发器，成功后再原子替换，最后异步回收旧的**。
    //
    // 旧实现是"先摘除旧引用（self.forwarder = NULL）→ 同步 stop/free 旧的 → 再建新的"，
    // 而 kp_forwarder_stop 要等 client 线程退出：它们可能正卡在同步取号 hook 的网络
    // 等待里（单次最长 15s），grace 上限 10s，随后的 kp_forwarder_free 内部还会再
    // stop 一次 → 单次重建最长阻塞 20s。这段时间里：
    //   · self.forwarder 已是 NULL（forwarderPort=0 / running=false）
    //   · 旧转发器的监听 fd 已关闭，但 ObjC 层上次发布的 override 仍指向那个端口
    //   · 任何新的 apply（看门狗每 5s、前台恢复、网络变化）都卡在 lifecycleLock 上排队
    // 结果就是"彻底无法联网且永不恢复"，且 forwarderDiscardCount/lastError 都无从体现。
    // 先启动新的再替换旧的可彻底消除该窗口：shouldRun 期间 self.forwarder 永不为 NULL，
    // 且 apply 路径不再等待旧转发器的 client 线程。
    // 先落定"应该运行"的意图与 settings 签名，再去锁外创建/启动新转发器。
    // applyConfig 全程持有 lifecycleLock，因此这两者不可能被并发改写。
    [self.lock lock];
    self.desiredForwarderRunning = YES;
    self.lastSettingsSignature = signature;
    [self.lock unlock];

    newForwarder = kp_forwarder_new("127.0.0.1", 0, "", 0);
    if (!newForwarder) {
        [self.lock lock];
        self.lastError = @"转发器启动失败";
        self.lastRefreshSuccess = NO;
        [self.lock unlock];
        [self notifyForwarderLifecycle:@"create-failed"];
        return;
    }
    kp_forwarder_set_refresh_hook(newForwarder, LCProxyKingRefreshHook, (__bridge void *)self);
    if (kp_forwarder_start(newForwarder) != 0) {
        kp_forwarder_free(newForwarder);
        [self.lock lock];
        self.lastError = @"转发器启动失败";
        self.lastRefreshSuccess = NO;
        [self.lock unlock];
        [self notifyForwarderLifecycle:@"start-failed"];
        return;
    }

    // 原子替换：新转发器立即生效，旧引用在同一临界区内摘除，不存在 NULL 窗口。
    [self.lock lock];
    oldForwarder = self.forwarder;
    self.forwarder = newForwarder;
    [self.lock unlock];

    // 旧转发器交给专用串行队列回收，绝不阻塞 apply 路径。
    [self retireForwarder:oldForwarder];
    [self loadCachedStateIntoForwarder];
    } @finally {
        [self.lifecycleLock unlock];
    }
}

// 异步回收退役的转发器。kp_forwarder_stop 必须等待 client 线程退出（它们可能卡在
// 同步取号 hook 的网络等待里，最长 15s；grace 上限 10s，kp_forwarder_free 内部还会
// 再 stop 一轮），因此在任何需要及时返回的路径上同步调用都会把整个 runtime apply
// 卡住：override 无法更新到新端口、后续 apply 在 lifecycleLock 上排队，表现为彻底
// 断网且不恢复（实测即 forwarderPort=0 而 proxyOverridePort 仍指向已关闭的旧端口）。
//
// 回收放到专用串行队列，且**不再获取 lifecycleLock**：退役的实例已从 self.forwarder
// 摘除，回收只操作这个局部指针，与在建的新实例互不相干；若在这里拿 lifecycleLock，
// 就会把最长 20s 的等待重新转嫁到 apply 路径上，等于没修。串行队列本身已保证同一
// 时刻只回收一个实例。
- (void)retireForwarder:(kp_forwarder *)fw {
    if (!fw) return;
    dispatch_async(self.forwarderReaperQueue, ^{
        kp_forwarder_stop(fw);
        // stop 未完成时 kp_forwarder_free 会按契约故意泄漏（不 free），不会 UAF。
        kp_forwarder_free(fw);
    });
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

// 取号失败后的退避重试：只影响本进程的重试节奏，与任何其他进程无关。
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
    if ((!queenHttp.count && !queenHttps.count) || validHttp.count != queenHttp.count || validHttps.count != queenHttps.count) return NO;

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
// 凭证存取：进程内缓存 + 追加式共享日志
// ---------------------------------------------------------------------------
// 设计原则：**没有跨进程锁、没有租约、没有围栏**。凭证有效期长达 2 小时
// （Q-Token）/ 8 小时（代理池），为"省几次取号请求"而引入复杂跨进程同步并不
// 值得 —— 那套机制在多 LiveContainer / 共享 App 场景下反而制造了持续断网。
//
// 每个进程维护自己的转发器与凭证。取号结果以**追加**方式写入一个日志文件，
// 每行一条 JSON（含取号时间 ts 与有效期）。追加本身无需加锁：即便两个进程同时
// 写入，文件里也只是多了一条记录，读取方永远取"最新且仍有效"的那条；损坏的行
// 直接跳过。跨 App 因此仍能复用未过期凭证（省一次取号），而任何一步失败都只是
// 退化为"自己重新取一个"，绝不会造成断网，更不会隐式直连。
//
// 进程内缓存 self.cachedCredentialState 是运行时的唯一权威；日志只在启动时
// 读取一次用于种子，并在每次取号成功后追加。

static const NSUInteger LCProxyKingCredentialLogMaxLines = 64;
static const NSUInteger LCProxyKingSharedRefreshLogMaxLines = 200;

- (NSString *)credentialLogPath {
    // 路径只取决于数据目录，解析一次即可缓存，避免每次都做目录创建 IO。
    [self.cacheLock lock];
    NSString *resolved = self.resolvedCredentialLogPath;
    [self.cacheLock unlock];
    if (resolved.length) return resolved;
    NSString *canonical = LCProxyCanonicalDataDirectory();
    if (canonical.length &&
        [[NSFileManager defaultManager] createDirectoryAtPath:canonical
                                  withIntermediateDirectories:YES attributes:nil error:nil]) {
        resolved = [canonical stringByAppendingPathComponent:@"kingcard-credentials.log"];
    } else {
        // canonical 不可写时退回 dylib 推导目录；再不行就返回 nil，纯内存运行。
        // 持久化失败绝不影响转发：本进程照常取号、照常装载凭证。
        NSString *local = LCProxyDataDirectory();
        if (!local.length) return nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:local
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        resolved = [local stringByAppendingPathComponent:@"kingcard-credentials.log"];
    }
    [self.cacheLock lock];
    self.resolvedCredentialLogPath = resolved;
    [self.cacheLock unlock];
    return resolved;
}

// 追加一行。单次 write() + O_APPEND 在行级别是原子的；即便与其他进程交错，
// 读取方也只是多看到一条记录，取最新有效的一条即可。
- (void)appendCredentialRecord:(NSDictionary *)record {
    if (!record.count) return;
    NSMutableDictionary *stored = [record mutableCopy];
    // refreshLog 是控制台 UI 用的历史记录，不落进凭证日志（否则每行都会带上
    // 整个历史，文件迅速膨胀）。它只存在于进程内缓存。
    [stored removeObjectForKey:@"refreshLog"];
    if (![NSJSONSerialization isValidJSONObject:stored]) return;
    NSData *line = [NSJSONSerialization dataWithJSONObject:stored options:0 error:nil];
    if (!line.length) return;
    // 缓存替换必须在锁内：调用方拿到的是副本，可放心原地修改。
    [self.cacheLock lock];
    self.cachedCredentialState = [record mutableCopy];
    [self.cacheLock unlock];
    NSString *path = [self credentialLogPath];
    if (!path.length) return;
    NSMutableData *payload = [line mutableCopy];
    [payload appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) return;   // 写不进去就用进程内缓存，绝不因此报错或断网
    ssize_t ignored = write(fd, payload.bytes, payload.length);
    (void)ignored;
    close(fd);
    [self trimCredentialLogIfNeeded];
}

- (void)trimCredentialLogIfNeeded {
    [self trimAppendLogAtPath:[self credentialLogPath] maxLines:LCProxyKingCredentialLogMaxLines];
}

// 通用的"追加式日志裁剪"：超过上限就把后半段留下、前半段丢掉。写入失败静默忽略
// ——这些日志纯属诊断，任何 IO 问题都不能影响转发。
- (void)trimAppendLogAtPath:(NSString *)path maxLines:(NSUInteger)maxLines {
    if (!path.length || maxLines == 0) return;
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return;
    NSArray<NSString *> *all = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *l in all) {
        if (l.length) [kept addObject:l];
    }
    if (kept.count <= maxLines) return;
    NSUInteger keep = MAX((NSUInteger)1, maxLines / 2);
    NSRange cut = NSMakeRange(kept.count - keep, keep);
    NSString *out = [[kept subarrayWithRange:cut] componentsJoinedByString:@"\n"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// 把一行紧凑的取号记录追加到 App Group 共享日志文件，让任何 LiveContainer 实例
// 的控制台都能看到本进程的取号历史 —— 共享 App 进程的内部状态此前完全不可见
// （文件应用看不到 App Group，console 又只能读到自己的进程）。与凭证日志同一
// 思路：O_APPEND 行级追加、无需加锁、任何失败静默忽略（纯诊断）。
- (void)appendSharedRefreshLogEntry:(NSDictionary *)entry {
    NSString *dir = [[self credentialLogPath] stringByDeletingLastPathComponent];
    if (!dir.length) return;
    NSString *path = [dir stringByAppendingPathComponent:@"kingcard-refresh.log"];
    NSDictionary *compact = @{
        @"ts": [entry[@"ts"] isKindOfClass:[NSNumber class]] ? entry[@"ts"] : @([[NSDate date] timeIntervalSince1970]),
        @"pid": @(getpid()),
        @"ok": [entry[@"ok"] isKindOfClass:[NSNumber class]] ? entry[@"ok"] : @NO,
        @"src": [entry[@"src"] isKindOfClass:[NSString class]] ? entry[@"src"] : @"",
        @"ms": [entry[@"ms"] isKindOfClass:[NSNumber class]] ? entry[@"ms"] : @0,
        @"msg": [entry[@"msg"] isKindOfClass:[NSString class]] ? entry[@"msg"] : @"",
    };
    if (![NSJSONSerialization isValidJSONObject:compact]) return;
    NSData *line = [NSJSONSerialization dataWithJSONObject:compact options:0 error:nil];
    if (!line.length) return;
    NSMutableData *payload = [line mutableCopy];
    [payload appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) return;
    ssize_t ignored = write(fd, payload.bytes, payload.length);
    (void)ignored;
    close(fd);
    [self trimAppendLogAtPath:path maxLines:LCProxyKingSharedRefreshLogMaxLines];
}

// 取"最新且仍有效"的一条。损坏行、过期行、与当前设置不匹配的行全部跳过；
// 一条都找不到就返回 nil，由调用方走重新取号。
- (NSMutableDictionary *)newestValidRecordFromLog {
    NSString *path = [self credentialLogPath];
    if (!path.length) return nil;
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return nil;
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSDictionary *settings = [self settingsSnapshot];
    NSMutableDictionary *best = nil;
    double bestTs = -1;
    for (NSString *l in lines) {
        if (!l.length) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:[l dataUsingEncoding:NSUTF8StringEncoding]
                                                 options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        double ts = [obj[@"ts"] isKindOfClass:[NSNumber class]] ? [obj[@"ts"] doubleValue] : -1;
        if (ts <= bestTs) continue;
        if (![self stateHasFreshCredentials:obj matchingSettings:settings]) continue;
        best = [obj mutableCopy];
        bestTs = ts;
    }
    return best;
}

- (NSMutableDictionary *)loadState {
    // 注意：这里只使用独立的 cacheLock，绝不碰 self.lock —— 本方法会在
    // status 等持有 self.lock 的上下文里被调用，NSLock 不可重入，否则死锁。
    [self.cacheLock lock];
    NSMutableDictionary *cached = self.cachedCredentialState;
    [self.cacheLock unlock];
    // 必须返回副本：调用方（refreshCredentialsWithForce 等）会原地增删键，
    // 不能与缓存共享同一个可变对象。
    if (cached.count) return [cached mutableCopy];
    NSMutableDictionary *fromLog = [self newestValidRecordFromLog];
    if (fromLog.count) {
        [self.cacheLock lock];
        self.cachedCredentialState = [fromLog mutableCopy];
        [self.cacheLock unlock];
        return fromLog;
    }
    return [NSMutableDictionary dictionary];
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

// 取号日志：内存环形缓冲（新→旧，最多 LCProxyKingRefreshLogMax 条）供本进程控制台
// 显示；同时把每条压缩后追加到 App Group 的 kingcard-refresh.log，让**其他**
// LiveContainer 实例的控制台也能看到本进程（例如共享 App）的取号历史。
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
    [self appendSharedRefreshLogEntry:entry];
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
    // 看门狗：王卡模式已启用但转发器缺失/监听失效时，就地请求一次重建。
    //
    // 必要性：applyConfig 的重建分支会先 stopRefreshTimer；若这次重建失败（bind
    // 失败）或在并发下被丢弃，进程就会**既没有可用转发器、也没有任何定时器或事件**
    // 再触发 apply —— ObjC 层最后发布的 override 仍指向已死的端口，表现为"彻底
    // 无法联网且永不恢复"，直到用户切后台/重启 App。这里用一条显式的 5 秒重试把
    // 它接上，保证一定有人来重新 apply。
    //
    // 死锁安全性：本方法可能由转发器 client 线程经 refresh hook 调用，但那时转发器
    // 必然在运行（isRunning 为真）→ 不会走重建分支；转发器不在运行时不存在 client
    // 线程。且重建走的是异步 requestRuntimeApplyAsync，调用线程不会被阻塞。
    if ([settings[@"proxyEnabled"] boolValue] &&
        [[[LCProxyConfig shared] effectiveProxyModeForSettings:settings] isEqualToString:@"kingcard"] &&
        ![self isRunning]) {
        [self.lock lock];
        self.refreshing = NO;
        self.lastRefreshSuccess = NO;
        self.lastRefresh = LCProxyKingNow();
        self.lastError = @"王卡转发器缺失，正在自动重建";
        [self.lock unlock];
        [[LCProxyConfig shared] requestRuntimeApplyAsync];
        [self scheduleRefreshRetryAfter:5.0];
        return NO;
    }

    NSMutableDictionary *state = [self loadState];
    if (!force && state.count && [self stateHasFreshCredentials:state matchingSettings:settings]) {
        // 缓存命中：无需取号。凭证有效期长达 2 小时，普通刷新只是确认仍然新鲜。
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
        return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps error:@"GUID 配置覆盖必须是 32 位十六进制字符串"];
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
        return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps error:@"Q-Token/Q-Key 配置覆盖不完整"];
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
            NSError *tokErr = nil;
            NSDictionary *tokInfo = [self syncFetchToken:guid qua2:qua2 phone:phone timeout:timeout error:&tokErr];
            if (!tokInfo) {
                [steps appendFormat:@"Q-Token: 失败 %@\n", tokErr.localizedDescription ?: @"unknown"];
                return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps error:[NSString stringWithFormat:@"Q-Token 获取失败: %@", tokErr.localizedDescription ?: @"unknown"]];
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
        return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps error:@"Q-Token/Q-Key 为空"];
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
        NSError *proxyErr = nil;
        NSDictionary *proxyInfo = [self syncFetchProxies:guid qua2:qua2 params:params timeout:timeout error:&proxyErr];
        if (!proxyInfo) {
            [steps appendFormat:@"代理池: 失败 %@\n", proxyErr.localizedDescription ?: @"unknown"];
            return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps error:[NSString stringWithFormat:@"Queen 代理池获取失败: %@", proxyErr.localizedDescription ?: @"unknown"]];
        }
        actuallyFetchedUpstream = YES;
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

    if (!queenHttp.count && !queenHttps.count) {
        [steps appendString:@"代理池: 为空\n"];
        return [self finishRefreshWithState:state success:NO src:source ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps error:@"Queen 代理池为空"];
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
                                      ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:nil error:nil];
}

- (BOOL)finishRefreshWithState:(NSMutableDictionary *)state
                       success:(BOOL)success
                           src:(NSString *)src
                            ms:(double)ms
                         steps:(NSString *)steps
                         error:(NSString *)error {
    // 成功：写进程内缓存并追加到共享日志（无锁，其他 App 启动时可直接复用）。
    // 失败：保留旧凭证继续服务。上游 820/821/823 会再次触发强制刷新；一次取号
    // 失败绝不至于清空凭证——那会把瞬时故障放大成持续断网。也绝不退化直连。
    state[@"ts"] = @([[NSDate date] timeIntervalSince1970]);
    if (steps.length) {
        [self pushRefreshLog:success src:src ms:ms msg:steps intoState:state];
    }
    if (success) {
        [self appendCredentialRecord:state];
        [self loadCachedStateIntoForwarder];
        [self startRefreshTimer];
    } else if (![self stateHasFreshCredentials:[self loadState]
                               matchingSettings:[self settingsSnapshot]]) {
        // 确实没有任何可用凭证才清空转发器（fail-closed，但绝不直连）。
        [self clearForwarderKingState];
        [self scheduleRefreshRetryAfter:15.0];
    }
    [self.lock lock];
    self.refreshing = NO;
    self.lastRefreshSuccess = success;
    self.lastRefresh = LCProxyKingNow();
    self.lastSource = src ?: @"";
    self.lastError = success ? @"" : (error ?: @"取号失败，稍后自动重试");
    [self.lock unlock];
    return success;
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
    // loadState / credentialLogPath 会做文件 IO 并使用独立的 cacheLock，
    // 绝不能在持有 self.lock 时调用（NSLock 不可重入，否则死锁——这正是
    // v0.5.47 首版导致控制台保存挂死的原因）。
    NSMutableDictionary *state = [self loadState];
    NSString *logPath = [self credentialLogPath] ?: @"";
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
    d[@"desiredForwarderRunning"] = @(self.desiredForwarderRunning);
    d[@"forwarderDiscardCount"] = @(self.forwarderDiscardCount);
    d[@"refreshArbitrationLossStreak"] = @(self.refreshArbitrationLossStreak);
    d[@"lastForwarderLifecycle"] = self.lastForwarderLifecycle ?: @"";
    d[@"credentialLogPath"] = logPath;
    d[@"credentialCacheCount"] = @(self.cachedCredentialState.count);
    d[@"refreshLog"] = [self.refreshLog copy];
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
