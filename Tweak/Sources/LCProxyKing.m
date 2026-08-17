#import "LCProxyKing.h"
#import "KPKIngCore.h"
#import "LCProxyPaths.h"

static int LCProxyKingRefreshHook(void *ctx) {
    LCProxyKing *king = (__bridge LCProxyKing *)ctx;
    return [king refreshCredentials] ? 0 : -1;
}

static void LCProxyKingLog(const char *line) {
    if (line) NSLog(@"[LCProxyKing] %s", line);
}

@interface LCProxyKing ()
@property (nonatomic, strong) NSLock *lock;
@property (nonatomic, assign) void *forwarderPtr;
@property (nonatomic, copy) NSString *lastRefresh;
@property (nonatomic, copy) NSString *lastSource;
@property (nonatomic, copy) NSString *lastError;
@property (nonatomic, copy) NSString *lastDiagnostics;
@property (nonatomic, assign) BOOL lastRefreshSuccess;
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
    // 只要选择了王卡代理就启动转发器，避免浏览器启动时转发器还没就绪。
    BOOL shouldRun = [mode isEqualToString:@"kingcard"];
    [self.lock lock];
    if (!shouldRun) {
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
    NSString *host = [settings[@"kingUpstreamHost"] isKindOfClass:[NSString class]] && [settings[@"kingUpstreamHost"] length] ? settings[@"kingUpstreamHost"] : @"157.148.54.212";
    NSInteger port = [settings[@"kingUpstreamPort"] respondsToSelector:@selector(integerValue)] ? [settings[@"kingUpstreamPort"] integerValue] : 8091;
    if (port <= 0 || port > 65535) port = 8091;
    kp_forwarder *fw = kp_forwarder_new("127.0.0.1", 18080, host.UTF8String, (int)port);
    if (fw) {
        kp_forwarder_set_refresh_hook(fw, LCProxyKingRefreshHook, (__bridge void *)self);
        if (kp_forwarder_start(fw) == 0) {
            self.forwarder = fw;
            [self.lock unlock];
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

- (NSString *)guidOverrideFrom:(NSDictionary *)settings {
    id v = settings[@"kingGuidOverride"];
    return [v isKindOfClass:[NSString class]] && [v length] ? v : nil;
}

- (NSString *)tokenOverrideFrom:(NSDictionary *)settings {
    id v = settings[@"kingTokenOverride"];
    return [v isKindOfClass:[NSString class]] && [v length] ? v : nil;
}

- (BOOL)refreshCredentials {
    NSDictionary *settings = [self settingsSnapshot];
    NSString *refreshURL = [settings[@"kingRefreshURL"] isKindOfClass:[NSString class]] && [settings[@"kingRefreshURL"] length] ? settings[@"kingRefreshURL"] : @"http://kc.iikira.com/kingcard";
    NSString *host = [settings[@"kingUpstreamHost"] isKindOfClass:[NSString class]] && [settings[@"kingUpstreamHost"] length] ? settings[@"kingUpstreamHost"] : @"157.148.54.212";
    NSInteger port = [settings[@"kingUpstreamPort"] respondsToSelector:@selector(integerValue)] ? [settings[@"kingUpstreamPort"] integerValue] : 8091;
    if (port <= 0 || port > 65535) port = 8091;

    NSString *guidHint = [self guidOverrideFrom:settings] ?: @"";
    NSString *tokenHint = [self tokenOverrideFrom:settings] ?: @"";
    char guid[128] = {0};
    char token[128] = {0};
    kp_fetch_diag diag;
    kp_fetch_diag_init(&diag);
    char source[16] = {0};

    int rc = kp_fetch_guid_token_best(refreshURL.UTF8String,
                                      host.UTF8String, (int)port,
                                      guidHint.length ? guidHint.UTF8String : "",
                                      tokenHint.length ? tokenHint.UTF8String : "",
                                      3, 300, 10000,
                                      guid, sizeof(guid), token, sizeof(token),
                                      &diag, source, sizeof(source));
    char dbgbuf[4096];
    kp_debug_recent(dbgbuf, sizeof(dbgbuf));
    self.lastDiagnostics = [NSString stringWithUTF8String:dbgbuf] ?: @"";
    if (rc != 0) {
        [self.lock lock];
        self.lastRefreshSuccess = NO;
        self.lastSource = @"";
        self.lastRefresh = [self nowString];
        self.lastError = [NSString stringWithFormat:@"取号失败 rc=%d %s", rc, diag.body_head];
        [self.lock unlock];
        return NO;
    }

    // 经上游激活（失败不阻断取号结果；转发器仍会尝试用凭证连接）
    char login_host[256];
    if (kp_build_login_host(guid, token, login_host, sizeof(login_host)) == 0) {
        char diag_status[160] = {0};
        kp_login_via_proxy(host.UTF8String, (int)port, login_host, guid, token, 8000, diag_status, sizeof(diag_status));
    }

    [self.lock lock];
    if (self.forwarder) {
        kp_forwarder_set_creds(self.forwarder, guid, token);
    }
    self.lastRefreshSuccess = YES;
    self.lastSource = [NSString stringWithUTF8String:source] ?: @"";
    self.lastRefresh = [self nowString];
    self.lastError = @"";
    [self.lock unlock];
    return YES;
}

- (NSDictionary *)settingsSnapshot {
    NSString *path = [LCProxyDataDirectory() stringByAppendingPathComponent:@"settings.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
}

- (NSString *)nowString {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss";
    });
    return [fmt stringFromDate:[NSDate date]];
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
    NSString *guid = @"";
    if (self.forwarder) {
        // forwarder doesn't expose getter; keep status without raw creds
    }
    d[@"guidMasked"] = guid;
    [self.lock unlock];
    return d;
}

@end
