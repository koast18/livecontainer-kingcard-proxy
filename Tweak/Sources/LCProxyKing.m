#import "LCProxyKing.h"
#import "KPKIngCore.h"
#import "KPKQueenCore.h"
#import "LCProxyPaths.h"
#import "LCProxyConfig.h"
#import "LCProxyKingClient.h"
#import "lcproxy_bridge.h"
#import <errno.h>
#import <fcntl.h>
#import <stdlib.h>
#import <unistd.h>

// 周期必须 <= LCProxyKingRefreshLeadTime(2min)，否则续期窗口内可能一次触发都轮不到；
// 且代理池 TTL 仅 ~9.5min，过长的固定网格会在每次续期后错位出死区。
static const NSTimeInterval LCProxyKingRefreshInterval = 2 * 60;
static const NSTimeInterval LCProxyKingRefreshLeeway = 30;
static const NSTimeInterval LCProxyKingRefreshLeadTime = 2 * 60;

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
- (void)startRefreshTimer;
- (void)stopRefreshTimer;
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
        if (settingsChanged || self.refreshTimer == nil) {
            [self startRefreshTimer];
        }
        [self loadCachedStateIntoForwarder];
        if (settingsChanged || ![self hasFreshCachedState]) {
            [self refreshCredentialsAsync];
        }
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
        [self startRefreshTimer];
        if (![self hasFreshCachedState]) {
            [self refreshCredentialsAsync];
        }
        return;
    }

    [self.lock unlock];
    kp_forwarder_stop(newForwarder);
    kp_forwarder_free(newForwarder);
    } @finally {
        [self.lifecycleLock unlock];
    }
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
    [self.lock lock];
    BOOL alreadyScheduled = self.lockRetryScheduled;
    if (!alreadyScheduled) self.lockRetryScheduled = YES;
    [self.lock unlock];
    if (alreadyScheduled) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
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
    NSString *guid = [state[@"guid"] isKindOfClass:[NSString class]] ? state[@"guid"] : nil;
    NSString *token = [state[@"token"] isKindOfClass:[NSString class]] ? state[@"token"] : nil;
    NSString *qkey = [state[@"key"] isKindOfClass:[NSString class]] ? state[@"key"] : nil;
    NSString *qua2 = [state[@"qua2"] isKindOfClass:[NSString class]] ? state[@"qua2"] : nil;
    NSArray *queenHttp = [state[@"queen_http"] isKindOfClass:[NSArray class]] ? state[@"queen_http"] : nil;
    NSArray *queenHttps = [state[@"queen_https"] isKindOfClass:[NSArray class]] ? state[@"queen_https"] : nil;
    if (!guid.length || !token.length || !qkey.length || !qua2.length) return;
    if (!queenHttp.count && !queenHttps.count) return;

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
                                    "httpcom",
                                    httpArr, (size_t)nhttp,
                                    httpsArr, (size_t)nhttps);
        if (httpArr) free(httpArr);
        if (httpsArr) free(httpsArr);
        self.lastRefreshSuccess = YES;
        self.lastRefresh = LCProxyKingNow();
        self.lastError = @"";
    }
    [self.lock unlock];
}

- (BOOL)hasFreshCachedState {
    NSDictionary *state = [self loadState];
    NSString *guid = [state[@"guid"] isKindOfClass:[NSString class]] ? state[@"guid"] : nil;
    NSString *token = [state[@"token"] isKindOfClass:[NSString class]] ? state[@"token"] : nil;
    NSString *qkey = [state[@"key"] isKindOfClass:[NSString class]] ? state[@"key"] : nil;
    NSString *qua2 = [state[@"qua2"] isKindOfClass:[NSString class]] ? state[@"qua2"] : nil;
    NSArray *queenHttp = [state[@"queen_http"] isKindOfClass:[NSArray class]] ? state[@"queen_http"] : nil;
    NSArray *queenHttps = [state[@"queen_https"] isKindOfClass:[NSArray class]] ? state[@"queen_https"] : nil;
    if (!guid.length || !token.length || !qkey.length || !qua2.length) return NO;
    if (!queenHttp.count || !queenHttps.count) return NO;

    double now = [[NSDate date] timeIntervalSince1970];
    NSNumber *tokenExpireEpoch = [state[@"tokenExpireEpoch"] isKindOfClass:[NSNumber class]] ? state[@"tokenExpireEpoch"] : nil;
    NSNumber *proxyExpireEpoch = [state[@"proxyExpireEpoch"] isKindOfClass:[NSNumber class]] ? state[@"proxyExpireEpoch"] : nil;
    if (!tokenExpireEpoch || tokenExpireEpoch.doubleValue <= now + LCProxyKingRefreshLeadTime) return NO;
    if (!proxyExpireEpoch) {
        // Legacy cache without an explicit proxy TTL. As long as the token is
        // still valid and proxy lists are present, use the cached pools and let
        // the periodic/on-demand refresh replace them if they become unusable.
        return YES;
    }
    if (proxyExpireEpoch.doubleValue <= now + LCProxyKingRefreshLeadTime) return NO;
    return YES;
}

- (BOOL)isReady {
    [self.lock lock];
    BOOL running = self.forwarder != NULL && kp_forwarder_is_running(self.forwarder) == 1;
    BOOL success = self.lastRefreshSuccess;
    BOOL refreshing = self.refreshing;
    [self.lock unlock];
    return running && success && !refreshing;
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
        [self.lock unlock];

        if (running && success && !refreshing) return YES;

        if (!refreshing) {
            NSDictionary *settings = [self settingsSnapshot];
            [self applyConfig:settings];
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
// 跨进程状态锁：kingcard-state.json 会写入 primary 与共享 AppGroup 两个目录，
// 多个 LiveContainer 实例（各自 primary 不同、共享同一 AppGroup）真正争用的是
// 共享副本。只锁 primary 时各进程各持一把不同的锁同时改写共享文件，
// “串行化”完全失效，取号/代理池刷新会基于旧副本互相覆盖（多实例只有先开的
// App 有网的现象之一）。这里按 LCProxyAllDataDirectories 的固定顺序锁全部
// 目录的 lock 文件：锁序一致且 primary 锁只有本实例进程会竞争，不会成环。
// fcntl 记录锁 + 有限等待；另一个实例刷新中途被 iOS 挂起时本进程 8 秒后放弃。
- (NSArray<NSString *> *)stateLockPaths {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *dir in LCProxyAllDataDirectories()) {
        NSString *p = [dir stringByAppendingPathComponent:@"kingcard-state.lock"];
        if (![paths containsObject:p]) [paths addObject:p];
    }
    return paths;
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

// 多实例状态收敛：primary 与共享目录各有一份 kingcard-state.json 时，
// 不能盲目优先 primary —— 那样第二个 LiveContainer 实例第一次从共享目录
// 播种后就会永远读自己的旧副本，别的实例刷新出的新 Q-Token/代理池它再也
// 看不见（多实例只有先开的 App 有网的现象之一）。这里按 updatedAt 选最新。
- (NSMutableDictionary *)loadState {
    NSMutableDictionary *best = nil;
    double bestUpdatedAt = -1.0;
    for (NSString *dir in LCProxyAllDataDirectories()) {
        NSString *path = [dir stringByAppendingPathComponent:@"kingcard-state.json"];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *d = [obj mutableCopy];
        NSNumber *updatedAt = [d[@"updatedAt"] isKindOfClass:[NSNumber class]] ? d[@"updatedAt"] : nil;
        double ts = updatedAt ? updatedAt.doubleValue : 0.0;
        if (!best || ts > bestUpdatedAt) {
            best = d;
            bestUpdatedAt = ts;
        }
    }
    return best ?: [NSMutableDictionary dictionary];
}

- (void)saveState:(NSMutableDictionary *)state {
    state[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]);
    for (NSString *dir in LCProxyAllDataDirectories()) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
        if (data) [data writeToFile:[dir stringByAppendingPathComponent:@"kingcard-state.json"] atomically:YES];
    }
}

- (NSDictionary *)settingsSnapshot {
    return [[LCProxyConfig shared] load];
}

- (NSString *)syncFetchGuid:(NSString *)qua2 timeout:(NSTimeInterval)timeout error:(NSError **)outErr {
    __block NSString *guid = nil;
    __block NSError *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [LCProxyKingClient fetchGuidFromServerWithQua2:qua2 timeout:timeout completion:^(NSString * _Nullable g, NSError * _Nullable e) {
        guid = g;
        err = e;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 10.0) * NSEC_PER_SEC)));
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

// 代理池按 TCP 连通延迟排序。逐个 800ms 探测是串行的，而且发生在持有跨进程
// 状态锁的刷新临界区内：池子大时一次排序能把锁占住几十秒，其他 LiveContainer
// 实例全部取号失败（表现为“只有最先打开的 App 有网”）。只探测前几个节点，
// 其余按服务端原顺序排在已探测节点之后（故障转移仍然可用）。
static const NSUInteger KP_LATENCY_PROBE_MAX = 8;

- (NSArray<NSString *> *)proxiesSortedByLatency:(NSArray<NSString *> *)proxies {
    if (proxies.count <= 1) return proxies;
    NSUInteger probeCount = MIN(proxies.count, KP_LATENCY_PROBE_MAX);
    NSArray<NSString *> *head = [proxies subarrayWithRange:NSMakeRange(0, probeCount)];
    NSMutableArray<NSString *> *sortedHead = [head mutableCopy];
    [sortedHead sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        int msA = [self tcpConnectMsForProxy:a];
        int msB = [self tcpConnectMsForProxy:b];
        if (msA < 0) msA = INT32_MAX;
        if (msB < 0) msB = INT32_MAX;
        if (msA < msB) return NSOrderedAscending;
        if (msA > msB) return NSOrderedDescending;
        return NSOrderedSame;
    }];
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

// 取号日志：内存环形缓冲（新→旧，最多 LCProxyKingRefreshLogMax 条），
// 同时写入 kingcard-state.json 的 refreshLog 键——控制台与 guest 进程共享该
// 文件，控制台因此能看到最近发生过的取号记录（含其他 App 触发的）。
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
    if (self.refreshing) {
        [self.lock unlock];
        return NO;
    }
    self.refreshing = YES;
    [self.lock unlock];

    NSArray<NSNumber *> *stateLockFds = [self acquireStateLocks];
    if (stateLockFds.count == 0) {
        [self scheduleRefreshRetryAfterLockContention];
        [self.lock lock];
        self.refreshing = NO;
        self.lastRefreshSuccess = NO;
        self.lastRefresh = LCProxyKingNow();
        self.lastError = @"kingcard-state.json 正被其他实例锁定，稍后自动重试";
        [self.lock unlock];
        return NO;
    }

    @try {
    NSDate *t0 = [NSDate date];
    NSMutableString *steps = [NSMutableString string];
    // 记录是否真的向上游发起了取号/取代理池请求；纯缓存命中时不写取号日志。
    BOOL actuallyFetchedUpstream = NO;

    NSDictionary *settings = [self settingsSnapshot];
    NSMutableDictionary *state = [self loadState];
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
    NSString *guid = nil;
    if (guidOverride) {
        guid = guidOverride;
    } else {
        NSString *stored = [state[@"guid"] isKindOfClass:[NSString class]] ? state[@"guid"] : nil;
        if (LCProxyKingHexStringValid(stored)) guid = stored;
    }
    if (force || !guid) {
        NSError *guidErr = nil;
        guid = [self syncFetchGuid:qua2 timeout:timeout error:&guidErr];
        if (!guid) {
            guid = [self localRandomGuid];
            self.lastSource = @"guid-local";
            [steps appendFormat:@"GUID: 本地生成（服务器失败 %@）\n", guidErr.localizedDescription ?: @""];
        } else {
            self.lastSource = @"guid-pbprx";
            actuallyFetchedUpstream = YES;
            [steps appendString:@"GUID: PBProxy 获取\n"];
        }
        state[@"guid"] = guid;
    } else {
        [steps appendString:@"GUID: 复用缓存\n"];
    }

    // Q-Token / Q-Key
    NSString *tokenOverride = [settings[@"kingTokenOverride"] isKindOfClass:[NSString class]] && [settings[@"kingTokenOverride"] length] ? settings[@"kingTokenOverride"] : nil;
    NSString *keyOverride = [settings[@"kingKeyOverride"] isKindOfClass:[NSString class]] && [settings[@"kingKeyOverride"] length] ? settings[@"kingKeyOverride"] : nil;
    NSString *token = nil;
    NSString *qkey = nil;
    if (tokenOverride && keyOverride) {
        token = tokenOverride;
        qkey = keyOverride;
        self.lastSource = @"token-override";
    } else {
        NSNumber *tokenExpireEpoch = [state[@"tokenExpireEpoch"] isKindOfClass:[NSNumber class]] ? state[@"tokenExpireEpoch"] : nil;
        NSString *storedToken = [state[@"token"] isKindOfClass:[NSString class]] ? state[@"token"] : nil;
        NSString *storedKey = [state[@"key"] isKindOfClass:[NSString class]] ? state[@"key"] : nil;
        double nowEpoch = [[NSDate date] timeIntervalSince1970];
        if (!force && storedToken.length && storedKey.length && tokenExpireEpoch && tokenExpireEpoch.doubleValue > nowEpoch + LCProxyKingRefreshLeadTime) {
            token = storedToken;
            qkey = storedKey;
        } else {
            NSError *tokErr = nil;
            NSDictionary *tokInfo = [self syncFetchToken:guid qua2:qua2 phone:phone timeout:timeout error:&tokErr];
            if (!tokInfo) {
                [steps appendFormat:@"Q-Token: 失败 %@\n", tokErr.localizedDescription ?: @"unknown"];
                [self finishRefreshWithState:state success:NO src:(self.lastSource ?: @"") ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps error:[NSString stringWithFormat:@"Q-Token 获取失败: %@", tokErr.localizedDescription ?: @"unknown"]];
                return NO;
            }
            actuallyFetchedUpstream = YES;
            token = tokInfo[@"token"];
            qkey = tokInfo[@"qkey"];
            state[@"token"] = token;
            state[@"key"] = qkey;
            NSNumber *expire = tokInfo[@"expire_seconds"];
            // 服务器宣称的有效期可能偏长，Q-Token 实际会更早失效。
            // 按 80% 有效期设置本地过期时间，并至少保留 60 秒，提前触发主动刷新。
            double rawExpire = ([expire isKindOfClass:[NSNumber class]] && expire.integerValue > 0) ? expire.doubleValue : 7200.0;
            double effectiveExpire = rawExpire * 0.8;
            if (effectiveExpire < 60.0) effectiveExpire = 60.0;
            state[@"tokenExpireEpoch"] = @(nowEpoch + effectiveExpire);
            self.lastSource = [NSString stringWithFormat:@"token-%@", tokInfo[@"mode"] ?: @"?"];
            NSNumber *expireSeconds = tokInfo[@"expire_seconds"];
            [steps appendFormat:@"Q-Token: %@\nQ-Key: %@\nQ-Token mode=%@ 有效期=%@s\n",
                token, qkey,
                tokInfo[@"mode"] ?: @"?",
                expireSeconds ?: @"?"];
        }
    }
    if (!token.length || !qkey.length) {
        [steps appendString:@"Q-Token/Q-Key: 为空\n"];
        [self finishRefreshWithState:state success:NO src:(self.lastSource ?: @"") ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps error:@"Q-Token/Q-Key 为空"];
        return NO;
    }

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
            [self finishRefreshWithState:state success:NO src:(self.lastSource ?: @"") ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps error:[NSString stringWithFormat:@"Queen 代理池获取失败: %@", proxyErr.localizedDescription ?: @"unknown"]];
            return NO;
        }
        actuallyFetchedUpstream = YES;
        queenHttp = [self proxiesSortedByLatency:proxyInfo[@"queen_http"]];
        queenHttps = [self proxiesSortedByLatency:proxyInfo[@"queen_https"]];
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
        self.lastSource = [NSString stringWithFormat:@"proxy-oldwup-%@", proxyInfo[@"mode"] ?: @"?"];
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
        [self finishRefreshWithState:state success:NO src:(self.lastSource ?: @"") ms:-[t0 timeIntervalSinceNow] * 1000.0 steps:steps error:@"Queen 代理池为空"];
        return NO;
    }

    // 写入转发器
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
    }
    self.lastRefreshSuccess = YES;
    self.lastRefresh = LCProxyKingNow();
    self.lastError = @"";
    // refreshing 标志必须在锁内复位：否则存在窗口期，其他线程持锁读到
    // refreshing==YES 却拿不到"刷新已完成"的事实，误拒新的刷新请求。
    // saveState 放在锁外，避免磁盘 IO 拖长临界区。
    self.refreshing = NO;
    [self.lock unlock];

    [steps appendFormat:@"写入转发器: http=%lu https=%lu\n",
        (unsigned long)queenHttp.count, (unsigned long)queenHttps.count];
    // 只有真正请求了上游（或强制刷新）才记录取号日志；纯缓存命中不刷日志。
    if (force || actuallyFetchedUpstream) {
        [self pushRefreshLog:YES src:(self.lastSource ?: @"") ms:-[t0 timeIntervalSinceNow] * 1000.0 msg:steps intoState:state];
    }
    [self saveState:state];
    return YES;
    } @finally {
        [self releaseStateLocks:stateLockFds];
    }
}

- (void)finishRefreshWithState:(NSMutableDictionary *)state success:(BOOL)success error:(NSString *)error {
    // 兼容包装：无步骤明细的失败路径，日志 msg 直接用错误文本。
    [self finishRefreshWithState:state success:success
                             src:(self.lastSource ?: @"") ms:0
                           steps:nil error:error];
}

- (void)finishRefreshWithState:(NSMutableDictionary *)state success:(BOOL)success
                           src:(NSString *)src ms:(double)ms
                         steps:(NSString *)steps error:(NSString *)error {
    [self pushRefreshLog:success src:src ms:ms
                     msg:(steps.length ? steps : (error ?: @"")) intoState:state];
    [self saveState:state];
    [self.lock lock];
    self.refreshing = NO;
    self.lastRefreshSuccess = success;
    self.lastRefresh = LCProxyKingNow();
    self.lastError = error ?: @"";
    [self.lock unlock];
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
