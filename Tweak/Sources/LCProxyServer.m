#import "LCProxyServer.h"
#import "LCProxyConfig.h"
#import "LCProxyStats.h"
#import "LCProxyPaths.h"
#import "ConsoleHTML.h"
#import "lcproxy_bridge.h"
#import "LCProxyKing.h"
#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerRequest.h"

static NSString *const LCProxyVersion = @"0.3.4";
static const NSUInteger LCProxyDefaultPort = 19092;

@interface LCProxyServer ()
@property (nonatomic, strong) GCDWebServer *server;
@end

@implementation LCProxyServer

+ (instancetype)shared {
    static LCProxyServer *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[LCProxyServer alloc] init];
    });
    return instance;
}

- (BOOL)isRunning {
    return _server != nil && _server.isRunning;
}

- (int)port {
    return (int)_server.port;
}

#pragma mark - JSON helpers

- (GCDWebServerResponse *)json:(id)obj {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    GCDWebServerDataResponse *resp = [GCDWebServerDataResponse responseWithData:data contentType:@"application/json; charset=utf-8"];
    return resp;
}

- (GCDWebServerResponse *)jsonError:(NSString *)msg statusCode:(NSInteger)code {
    GCDWebServerDataResponse *resp = [GCDWebServerDataResponse responseWithData:
        [NSJSONSerialization dataWithJSONObject:@{@"error": msg ?: @""} options:0 error:nil]
        contentType:@"application/json; charset=utf-8"];
    resp.statusCode = code;
    return resp;
}

- (NSDictionary *)jsonBody:(GCDWebServerRequest *)request {
    NSData *data = nil;
    if ([request isKindOfClass:[GCDWebServerDataRequest class]]) {
        data = [(GCDWebServerDataRequest *)request data];
    }
    if (!data) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
}

- (NSDictionary *)configPayload {
    NSDictionary *cfg = [[LCProxyConfig shared] load];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:cfg];
    d[@"cellular"] = @(lcproxy_stats_is_cellular() != 0);
    d[@"proxyCount"] = @(0); // proxychains core keeps this private; UI doesn't rely on it
    d[@"serverPort"] = @(self.port);
    d[@"version"] = LCProxyVersion;
    d[@"dataDirectory"] = LCProxyDataDirectory();
    d[@"king"] = [[LCProxyKing shared] status];
    return d;
}

#pragma mark - Start

- (BOOL)start {
    if (self.isRunning) return YES;
    GCDWebServer *server = [[GCDWebServer alloc] init];

    [server addDefaultHandlerForMethod:@"GET"
                         requestClass:[GCDWebServerRequest class]
                         processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [GCDWebServerDataResponse responseWithHTML:[NSString stringWithUTF8String:kLCProxyConsoleHTML]];
    }];

    [server addHandlerForMethod:@"GET" path:@"/api/status" requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [self json:[self configPayload]];
    }];

    [server addHandlerForMethod:@"GET" path:@"/api/stats" requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [self json:[[LCProxyStats shared] aggregate]];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/config" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSDictionary *body = [self jsonBody:request];
        NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:[[LCProxyConfig shared] load]];
        for (NSString *key in @[@"proxyEnabled", @"blockNonTcp", @"proxyMode", @"proxyType", @"proxyHost", @"proxyPort",
                                 @"kingUpstreamHost", @"kingUpstreamPort", @"kingRefreshURL",
                                 @"kingGuidOverride", @"kingTokenOverride"]) {
            if (body[key] != nil) merged[key] = body[key];
        }
        if (![[LCProxyConfig shared] saveSettings:merged]) {
            return [self jsonError:@"保存配置失败" statusCode:500];
        }
        [[LCProxyConfig shared] applyToRuntime];
        return [self json:[self configPayload]];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/king/refresh" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        BOOL ok = [[LCProxyKing shared] refreshCredentials];
        NSMutableDictionary *resp = [NSMutableDictionary dictionaryWithDictionary:[[LCProxyKing shared] status]];
        resp[@"ok"] = @(ok);
        return [self json:resp];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/reset-stats" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSString *dir = [LCProxyDataDirectory() stringByAppendingPathComponent:@"stats"];
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *f in files) {
            if ([f hasSuffix:@".json"]) {
                [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
            }
        }
        return [self json:@{@"ok": @YES}];
    }];

    NSError *err = nil;
    BOOL ok = [server startWithOptions:@{
        GCDWebServerOption_Port: @(LCProxyDefaultPort),
        GCDWebServerOption_BindToLocalhost: @YES,
        GCDWebServerOption_AutomaticallySuspendInBackground: @NO,
    } error:&err];
    if (!ok) {
        NSLog(@"[LCProxy] web server start failed: %@", err.localizedDescription ?: @"?");
        return NO;
    }
    _server = server;
    return YES;
}

@end
