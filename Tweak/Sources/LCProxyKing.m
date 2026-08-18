#import "LCProxyKing.h"
#import "KPKIngCore.h"
#import "KPKQueenCore.h"
#import "LCProxyPaths.h"
#import "LCProxyKingClient.h"
#import "lcproxy_bridge.h"
#import <stdlib.h>

static const NSTimeInterval LCProxyKingRefreshInterval = 5 * 60;
static const NSTimeInterval LCProxyKingRefreshLeeway = 30;

static int LCProxyKingRefreshHook(void *ctx) {
    LCProxyKing *king = (__bridge LCProxyKing *)ctx;
    return [king refreshCredentials] ? 0 : -1;
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
@property (nonatomic, assign) void *forwarderPtr;
@property (nonatomic, copy) NSString *lastRefresh;
@property (nonatomic, copy) NSString *lastSource;
@property (nonatomic, copy) NSString *lastError;
@property (nonatomic, copy) NSString *lastDiagnostics;
@property (nonatomic, assign) BOOL lastRefreshSuccess;
@property (nonatomic, strong) dispatch_source_t refreshTimer;
@property (nonatomic, assign) BOOL refreshing;
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
    NSString *mode = [settings[@"proxyMode"] isKindOfClass:[NSString class]] ? settings[@"proxyMode"] : @"custom";
    BOOL shouldRun = [mode isEqualToString:@"kingcard"] && [settings[@"proxyEnabled"] boolValue];
    if (shouldRun && [settings[@"kingAutoDirectOnNonCellular"] boolValue] && !lcproxy_stats_is_cellular()) {
        shouldRun = NO;
    }
    [self.lock lock];
    if (!shouldRun) {
        [self stopRefreshTimer];
        if (self.forwarder) {
            kp_forwarder_stop(self.forwarder);
            kp_forwarder_free(self.forwarder);
            self.forwarder = NULL;
        }
        [self.lock unlock];
        return;
    }
    if (self.forwarder) {
        kp_forwarder_stop(self.forwarder);
        kp_forwarder_free(self.forwarder);
        self.forwarder = NULL;
    }
    [self stopRefreshTimer];
    kp_forwarder *fw = kp_forwarder_new("127.0.0.1", 18080, "", 0);
    if (fw) {
        kp_forwarder_set_refresh_hook(fw, LCProxyKingRefreshHook, (__bridge void *)self);
        if (kp_forwarder_start(fw) == 0) {
            self.forwarder = fw;
            [self.lock unlock];
            [self loadCachedStateIntoForwarder];
            [self startRefreshTimer];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self refreshCredentials];
            });
            return;
        }
        kp_forwarder_free(fw);
    }
    self.lastError = @"转发器启动失败";
    self.lastRefreshSuccess = NO;
    [self.lock unlock];
}

- (void)startRefreshTimer {
    [self stopRefreshTimer];
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LCProxyKingRefreshInterval * NSEC_PER_SEC)),
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

- (BOOL)isReady {
    [self.lock lock];
    BOOL running = self.forwarder != NULL && kp_forwarder_is_running(self.forwarder) == 1;
    BOOL success = self.lastRefreshSuccess;
    BOOL refreshing = self.refreshing;
    [self.lock unlock];
    return running && success && !refreshing;
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
- (NSString *)statePath {
    return [LCProxyDataDirectory() stringByAppendingPathComponent:@"kingcard-state.json"];
}

- (NSMutableDictionary *)loadState {
    NSData *data = [NSData dataWithContentsOfFile:self.statePath];
    if (!data) return [NSMutableDictionary dictionary];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? [obj mutableCopy] : [NSMutableDictionary dictionary];
}

- (void)saveState:(NSDictionary *)state {
    for (NSString *dir in LCProxyAllDataDirectories()) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
        if (data) [data writeToFile:[dir stringByAppendingPathComponent:@"kingcard-state.json"] atomically:YES];
    }
}

- (NSDictionary *)settingsSnapshot {
    NSString *path = [LCProxyDataDirectory() stringByAppendingPathComponent:@"settings.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
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

- (NSArray<NSString *> *)proxiesSortedByLatency:(NSArray<NSString *> *)proxies {
    if (proxies.count <= 1) return proxies;
    NSMutableArray<NSString *> *items = [proxies mutableCopy];
    [items sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        int msA = [self tcpConnectMsForProxy:a];
        int msB = [self tcpConnectMsForProxy:b];
        if (msA < 0) msA = INT32_MAX;
        if (msB < 0) msB = INT32_MAX;
        if (msA < msB) return NSOrderedAscending;
        if (msA > msB) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return items;
}

- (NSString *)localRandomGuid {
    uint8_t bytes[16];
    arc4random_buf(bytes, sizeof(bytes));
    NSMutableString *s = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [s appendFormat:@"%02X", bytes[i]];
    return s;
}

// ---------------------------------------------------------------------------
// 新版 Queen/King 刷新流程：
//   GUID（PBProxy GetGuid，失败本地生成） -> Q-Token/Q-Key（旧 WUP TokenInfoReq）
//   -> queen_http / queen_https（旧 WUP proxyip/getIPListByRouter）
//   -> 写入 kp_forwarder
// ---------------------------------------------------------------------------
- (BOOL)refreshCredentials {
    [self.lock lock];
    if (self.refreshing) {
        [self.lock unlock];
        return NO;
    }
    self.refreshing = YES;
    [self.lock unlock];

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
    if (!guid) {
        NSError *guidErr = nil;
        guid = [self syncFetchGuid:qua2 timeout:timeout error:&guidErr];
        if (!guid) {
            guid = [self localRandomGuid];
            self.lastSource = @"guid-local";
        } else {
            self.lastSource = @"guid-pbprx";
        }
        state[@"guid"] = guid;
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
        if (storedToken.length && storedKey.length && tokenExpireEpoch && tokenExpireEpoch.doubleValue > nowEpoch + 60.0) {
            token = storedToken;
            qkey = storedKey;
        } else {
            NSError *tokErr = nil;
            NSDictionary *tokInfo = [self syncFetchToken:guid qua2:qua2 phone:phone timeout:timeout error:&tokErr];
            if (!tokInfo) {
                [self finishRefreshWithState:state success:NO error:[NSString stringWithFormat:@"Q-Token 获取失败: %@", tokErr.localizedDescription ?: @"unknown"]];
                return NO;
            }
            token = tokInfo[@"token"];
            qkey = tokInfo[@"qkey"];
            state[@"token"] = token;
            state[@"key"] = qkey;
            NSNumber *expire = tokInfo[@"expire_seconds"];
            if ([expire isKindOfClass:[NSNumber class]] && expire.integerValue > 0) {
                state[@"tokenExpireEpoch"] = @(nowEpoch + expire.doubleValue);
            } else {
                state[@"tokenExpireEpoch"] = @(nowEpoch + 7200.0);
            }
            self.lastSource = [NSString stringWithFormat:@"token-%@", tokInfo[@"mode"] ?: @"?"];
        }
    }
    if (!token.length || !qkey.length) {
        [self finishRefreshWithState:state success:NO error:@"Q-Token/Q-Key 为空"];
        return NO;
    }

    // queen_http / queen_https
    NSArray *queenHttp = [state[@"queen_http"] isKindOfClass:[NSArray class]] ? state[@"queen_http"] : nil;
    NSArray *queenHttps = [state[@"queen_https"] isKindOfClass:[NSArray class]] ? state[@"queen_https"] : nil;
    NSNumber *proxyExpireEpoch = [state[@"proxyExpireEpoch"] isKindOfClass:[NSNumber class]] ? state[@"proxyExpireEpoch"] : nil;
    double nowEpoch2 = [[NSDate date] timeIntervalSince1970];
    if (!queenHttp.count || !queenHttps.count || !proxyExpireEpoch || proxyExpireEpoch.doubleValue <= nowEpoch2 + 30.0) {
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
            [self finishRefreshWithState:state success:NO error:[NSString stringWithFormat:@"Queen 代理池获取失败: %@", proxyErr.localizedDescription ?: @"unknown"]];
            return NO;
        }
        queenHttp = [self proxiesSortedByLatency:proxyInfo[@"queen_http"]];
        queenHttps = [self proxiesSortedByLatency:proxyInfo[@"queen_https"]];
        state[@"queen_http"] = queenHttp ?: @[];
        state[@"queen_https"] = queenHttps ?: @[];
        double proxyLife = 600.0;
        if ([proxyInfo[@"lifePeriod"] isKindOfClass:[NSNumber class]] && [proxyInfo[@"lifePeriod"] doubleValue] > 0) {
            proxyLife = [proxyInfo[@"lifePeriod"] doubleValue];
        }
        if (proxyLife < 60.0) proxyLife = 60.0;
        state[@"proxyExpireEpoch"] = @(nowEpoch2 + proxyLife - 30.0);
        self.lastSource = [NSString stringWithFormat:@"proxy-oldwup-%@", proxyInfo[@"mode"] ?: @"?"];
    }

    if (!queenHttp.count && !queenHttps.count) {
        [self finishRefreshWithState:state success:NO error:@"Queen 代理池为空"];
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
    [self.lock unlock];

    [self saveState:state];
    self.refreshing = NO;
    return YES;
}

- (void)finishRefreshWithState:(NSDictionary *)state success:(BOOL)success error:(NSString *)error {
    [self saveState:state];
    [self.lock lock];
    self.refreshing = NO;
    self.lastRefreshSuccess = success;
    self.lastRefresh = LCProxyKingNow();
    self.lastError = error ?: @"";
    [self.lock unlock];
}

- (NSDictionary *)status {
    [self.lock lock];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"running"] = @([self isRunning]);
    d[@"lastRefreshSuccess"] = @(self.lastRefreshSuccess);
    d[@"lastRefresh"] = self.lastRefresh ?: @"";
    d[@"lastSource"] = self.lastSource ?: @"";
    d[@"lastError"] = self.lastError ?: @"";
    d[@"lastDiagnostics"] = self.lastDiagnostics ?: @"";
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
