#import "LCProxyServer.h"
#import "LCProxyConfig.h"
#import "LCProxyStats.h"
#import "LCProxyPaths.h"
#import "ConsoleHTML.h"
#import "lcproxy_bridge.h"
#import "LCProxyKing.h"
#import "LCProxyDiagnosis.h"
#import "LCProxyNetworkInfo.h"
#import "KPKIngCore.h"
#import "Version.h"
#include "webkit_proxy.h"
#include "async_proxy.h"
#include <arpa/inet.h>
#include <unistd.h>
#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerRequest.h"

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

- (NSString *)currentBundleId {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    return bid;
}

- (int)proxyOverridePort {
    char host[256];
    int port = 0;
    if (lcproxy_control_get_proxy_override(host, sizeof(host), &port)) return port;
    return 0;
}

// 端口**实际烘焙进代理链**的那一个。与 proxyOverridePort（"想要用的端口"）不同：
// 前者才是真正决定连接去哪里的值。两者不一致 = 连接会打到别处（例如无人监听的占位
// 端口 18080），表现为"彻底无法联网"而 status 里每项看起来都正常。
- (int)chainProxyPort {
    return lcproxy_control_get_applied_override_port();
}

// 读取 App Group canonical 目录下某个日志文件的末尾若干行。这些文件由所有
// LiveContainer 实例共同以 O_APPEND 追加，所以从**任何一个**进程的控制台都能看到
// 其他进程（尤其是共享 App 进程）的活动 —— 共享 App 的进程内诊断此前完全不可见，
// 这是排查"共享 App 无法联网"的关键入口。
- (NSArray<NSString *> *)tailOfAppGroupLog:(NSString *)name maxLines:(NSUInteger)maxLines {
    NSString *dir = LCProxyCanonicalDataDirectory();
    if (!dir.length || !name.length) return @[];
    NSString *path = [dir stringByAppendingPathComponent:name];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return @[];
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *l in lines) {
        if (l.length) [kept addObject:l];
    }
    if (kept.count <= maxLines) return kept;
    return [kept subarrayWithRange:NSMakeRange(kept.count - maxLines, maxLines)];
}

- (NSDictionary *)configPayload {
    NSDictionary *cfg = [[LCProxyConfig shared] load];
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:cfg];
    d[@"cellular"] = @(lcproxy_stats_is_cellular() != 0);
    d[@"effectiveMode"] = [[LCProxyConfig shared] effectiveProxyModeForSettings:cfg];
    d[@"proxyCount"] = @(lcproxy_control_get_proxy_count());
    d[@"serverPort"] = @(self.port);
    d[@"version"] = [NSString stringWithUTF8String:KPTWEAK_VERSION];
    d[@"dylibVersion"] = [NSString stringWithUTF8String:KPTWEAK_VERSION];
    d[@"gitCommit"] = [NSString stringWithUTF8String:KPTWEAK_GIT_COMMIT];
    d[@"pid"] = @(getpid());
    d[@"bundleId"] = [self currentBundleId];
    d[@"dylibPath"] = LCProxyDylibPath();
    // 崩溃加固：被兜住的 ObjC 异常。非空说明我们的代码出过错（但宿主 App 仍活着）。
    // 这是"是否由本 tweak 导致闪退"的唯一直接证据。
    d[@"swallowedExceptions"] = LCProxySwallowedExceptions() ?: @[];
    d[@"dataDirectory"] = LCProxyDataDirectory();
    d[@"forwarderPort"] = @([[LCProxyKing shared] localForwarderPort]);
    d[@"proxyOverridePort"] = @([self proxyOverridePort]);
    // 链里**实际生效**的端口。它必须等于 forwarderPort；不等就是"连接被发到别处"，
    // 这是"status 全绿却完全连不上"的直接证据（此前无法从 status 看出）。
    d[@"chainProxyPort"] = @([self chainProxyPort]);
    d[@"chainPortMatches"] = @([self chainProxyPort] == [[LCProxyKing shared] localForwarderPort]);
    d[@"asyncRelayCount"] = @(lcproxy_async_active_count());
    d[@"proxychainsConfPath"] = [[LCProxyConfig shared] proxychainsConfPath];
    d[@"proxychainsConfExists"] = @([[NSFileManager defaultManager] fileExistsAtPath:[[LCProxyConfig shared] proxychainsConfPath]]);
    d[@"settingsPath"] = [[LCProxyConfig shared] settingsPath];
    d[@"settingsExists"] = @([[NSFileManager defaultManager] fileExistsAtPath:[[LCProxyConfig shared] settingsPath]]);
    d[@"home"] = NSHomeDirectory();
    const char *lcHome = getenv("LC_HOME_PATH");
    d[@"lcHomePath"] = lcHome ? @(lcHome) : @"";
    d[@"guestDataDirectory"] = LCProxyGuestDataDirectory() ?: @"";
    d[@"sharedDataDirectory"] = LCProxySharedDataDirectory() ?: @"";
    d[@"canonicalDataDirectory"] = LCProxyCanonicalDataDirectory();
    // 运行时可探测到的网络参数。服务端按这些字段挑选代理池；若它们是占位值
    // （UNKNOW/NULLNULL），拿到的就是"通用池"，可能不在王卡免流白名单内。
    // 暴露出来便于核对"实际会上报什么"。
    {
        BOOL satisfied = lcproxy_network_is_known() != 0;
        BOOL cellular = lcproxy_stats_is_cellular() != 0;
        d[@"networkDetected"] = @{
            @"typeName": LCProxyNetworkTypeName(cellular),
            @"subtype": @(LCProxyNetworkSubtype(cellular, satisfied)),
            @"mccmnc": LCProxyNetworkMccMnc(),
            @"cellular": @(cellular),
            @"pathSatisfied": @(satisfied),
        };
    }
    d[@"dataDirectories"] = LCProxyAllDataDirectories();
    d[@"trafficLogPath"] = [LCProxyDataDirectory() stringByAppendingPathComponent:@"traffic.log"];
    d[@"king"] = [[LCProxyKing shared] status];
    // 跨进程诊断：这两个文件位于 App Group canonical 目录，所有实例共同追加。
    // 打开任意一个 App 的控制台即可看到全部进程（含共享 App）的取号历史与
    // 按连接转发结果，无需再靠文件应用/受限于 App Group 不可见。
    d[@"kingRefreshLogShared"] = [self tailOfAppGroupLog:@"kingcard-refresh.log" maxLines:30];
    // 每个进程定期写入的紧凑状态快照（新增）。
    //
    // 为什么需要它：/api/status 只能由抢到本端口的进程提供，其他进程"保持无头"，因此
    // **别的进程的内部状态读不到**。要判断"私有正常 / 共享不正常"，就必须能同时看到
    // 两边的现场 —— 否则只能靠推断。这里按 pid/bundle 汇总，含各自的 upstreamDiag 摘要。
    d[@"statusTail"] = [self tailOfAppGroupLog:@"kingcard-status.log" maxLines:24];
    d[@"trafficLogTail"] = [self tailOfAppGroupLog:@"traffic.log" maxLines:60];
    // 每个进程加载 dylib 的事实（时间/pid/版本/路径/bundle）。用于确认共享 App
    // 到底加载了哪个版本 —— 这是"修复是否真的生效"的唯一可靠依据。
    d[@"dylibLoadsTail"] = [self tailOfAppGroupLog:@"dylib-loads.log" maxLines:20];
    NSDictionary *runtimeDiag = [[LCProxyConfig shared] runtimeDiagnostics];
    if ([runtimeDiag isKindOfClass:[NSDictionary class]]) {
        d[@"runtime"] = runtimeDiag;
    }
    NSDictionary *stats = [[LCProxyStats shared] aggregate];
    d[@"kingAggregate"] = stats[@"forwarder"] ?: @{};
    return d;
}

#pragma mark - Proxy exit IP test

- (NSString *)extractIPFromString:(NSString *)text {
    if (!text.length) return nil;
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n,;"];
    NSArray *tokens = [text componentsSeparatedByCharactersInSet:separators];
    for (NSString *token in tokens) {
        NSString *t = [token stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"[]:"]];
        if (!t.length) continue;
        struct in_addr addr4;
        struct in6_addr addr6;
        if (inet_pton(AF_INET, t.UTF8String, &addr4) == 1) return t;
        if (inet_pton(AF_INET6, t.UTF8String, &addr6) == 1) return t;
    }
    return nil;
}

- (NSString *)plainTextFromHTML:(NSString *)html {
    if (!html.length) return @"";
    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:&err];
    NSString *s = err ? html : [re stringByReplacingMatchesInString:html options:0 range:NSMakeRange(0, html.length) withTemplate:@" "];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return s ?: @"";
}

- (NSDictionary *)proxyTestOne:(NSString *)urlString {
    NSDictionary *settings = [[LCProxyConfig shared] load];
    BOOL enabled = [settings[@"proxyEnabled"] boolValue];
    NSString *mode = [settings[@"proxyMode"] isKindOfClass:[NSString class]] ? settings[@"proxyMode"] : @"custom";
    NSString *effectiveMode = [[LCProxyConfig shared] effectiveProxyModeForSettings:settings];

    NSString *upstreamHost = nil;
    NSInteger upstreamPort = 0;
    BOOL direct = NO;
    if (enabled && [effectiveMode isEqualToString:@"direct"]) {
        direct = YES;
    } else if (enabled && [effectiveMode isEqualToString:@"kingcard"]) {
        upstreamHost = @"127.0.0.1";
        upstreamPort = [[LCProxyKing shared] localForwarderPort];
    } else if (enabled) {
        upstreamHost = [settings[@"proxyHost"] isKindOfClass:[NSString class]] && [settings[@"proxyHost"] length] ? settings[@"proxyHost"] : nil;
        upstreamPort = [settings[@"proxyPort"] respondsToSelector:@selector(integerValue)] ? [settings[@"proxyPort"] integerValue] : 0;
    }
    if (!direct && (!upstreamHost.length || (upstreamPort <= 0 && ![effectiveMode isEqualToString:@"kingcard"]))) {
        return @{@"url": urlString ?: @"", @"rc": @(-1), @"ip": @"", @"body": @"代理未启用或代理地址无效", @"ok": @NO};
    }

    // 王卡模式：确保转发器运行且凭证已加载。最多等 8 秒，避免测试接口被网络刷新阻塞。
    if (enabled && [mode isEqualToString:@"kingcard"] && ![effectiveMode isEqualToString:@"direct"]) {
        if (![[LCProxyKing shared] ensureCredentialsReadyWithTimeout:8.0]) {
            return @{@"url": urlString ?: @"", @"rc": @(-1), @"ip": @"", @"body": @"王卡凭证正在刷新或暂不可用，请稍后重试", @"ok": @NO, @"effectiveMode": effectiveMode};
        }
        upstreamPort = [[LCProxyKing shared] localForwarderPort];
        if (upstreamPort <= 0) {
            return @{@"url": urlString ?: @"", @"rc": @(-1), @"ip": @"", @"body": @"王卡转发器未就绪", @"ok": @NO, @"effectiveMode": effectiveMode};
        }
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url.host.length) {
        return @{@"url": urlString ?: @"", @"rc": @(-1), @"ip": @"", @"body": @"无效 URL", @"ok": @NO};
    }
    NSString *host = url.host;
    NSInteger port = url.port ? url.port.integerValue : 80;
    NSString *path = url.path.length ? url.path : @"/";
    if (url.query.length) path = [path stringByAppendingFormat:@"?%@", url.query];

    char body[2048] = {0};
    int rc;
    if (direct) {
        rc = kp_http_get_direct(host.UTF8String, (int)port, path.UTF8String,
                                6000, body, sizeof(body));
    } else {
        rc = kp_http_get_via_proxy(upstreamHost.UTF8String, (int)upstreamPort,
                                   host.UTF8String, (int)port, path.UTF8String,
                                   "", "", 6000,
                                   body, sizeof(body));
    }
    NSString *text = rc == 0 ? [NSString stringWithUTF8String:body] : nil;
    NSString *ip = [self extractIPFromString:text];
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    item[@"url"] = urlString ?: @"";
    item[@"rc"] = @(rc);
    item[@"ip"] = ip ?: @"";
    NSString *bodyText = [self plainTextFromHTML:text];
    item[@"body"] = bodyText.length > 120 ? [bodyText substringToIndex:120] : bodyText;
    item[@"ok"] = @(ip.length > 0);
    item[@"effectiveMode"] = effectiveMode;
    return item;
}

- (NSDictionary *)proxyTestResult {
    NSDictionary *settings = [[LCProxyConfig shared] load];
    BOOL enabled = [settings[@"proxyEnabled"] boolValue];
    NSString *mode = [settings[@"proxyMode"] isKindOfClass:[NSString class]] ? settings[@"proxyMode"] : @"custom";
    NSString *effectiveMode = [[LCProxyConfig shared] effectiveProxyModeForSettings:settings];

    NSString *upstreamHost = nil;
    NSInteger upstreamPort = 0;
    BOOL direct = NO;
    if (enabled && [effectiveMode isEqualToString:@"direct"]) {
        direct = YES;
    } else if (enabled && [effectiveMode isEqualToString:@"kingcard"]) {
        upstreamHost = @"127.0.0.1";
        upstreamPort = [[LCProxyKing shared] localForwarderPort];
    } else if (enabled) {
        upstreamHost = [settings[@"proxyHost"] isKindOfClass:[NSString class]] && [settings[@"proxyHost"] length] ? settings[@"proxyHost"] : nil;
        upstreamPort = [settings[@"proxyPort"] respondsToSelector:@selector(integerValue)] ? [settings[@"proxyPort"] integerValue] : 0;
    }
    if (!direct && (!upstreamHost.length || (upstreamPort <= 0 && ![effectiveMode isEqualToString:@"kingcard"]))) {
        return @{@"ok": @NO, @"error": @"代理未启用或代理地址无效", @"results": @[]};
    }

    // 王卡模式：确保转发器运行且凭证已加载。最多等 8 秒，避免测试接口被网络刷新阻塞。
    if (enabled && [mode isEqualToString:@"kingcard"] && ![effectiveMode isEqualToString:@"direct"]) {
        if (![[LCProxyKing shared] ensureCredentialsReadyWithTimeout:8.0]) {
            return @{@"ok": @NO, @"error": @"王卡凭证正在刷新或暂不可用，请稍后重试", @"results": @[], @"mode": mode, @"effectiveMode": effectiveMode};
        }
        upstreamPort = [[LCProxyKing shared] localForwarderPort];
        if (upstreamPort <= 0) {
            return @{@"ok": @NO, @"error": @"王卡转发器未就绪", @"results": @[], @"mode": mode, @"effectiveMode": effectiveMode};
        }
    }

    NSArray<NSString *> *sources = @[
        @"http://ip.3322.net",
        @"http://ifconfig.me/ip",
        @"http://icanhazip.com",
        @"http://members.3322.org/dyndns/getip",
        @"http://ip-api.com/line/?fields=query",
        @"http://myip.ipip.net",
    ];

    NSMutableArray *results = [NSMutableArray array];
    NSString *firstIP = nil;
    NSString *firstSource = nil;
    for (NSString *urlString in sources) {
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url.host.length) continue;
        NSString *host = url.host;
        NSInteger port = url.port ? url.port.integerValue : 80;
        NSString *path = url.path.length ? url.path : @"/";
        if (url.query.length) path = [path stringByAppendingFormat:@"?%@", url.query];

        char body[2048] = {0};
        int rc;
        if (direct) {
            rc = kp_http_get_direct(host.UTF8String, (int)port, path.UTF8String,
                                    8000, body, sizeof(body));
        } else {
            rc = kp_http_get_via_proxy(upstreamHost.UTF8String, (int)upstreamPort,
                                       host.UTF8String, (int)port, path.UTF8String,
                                       "", "", 8000,
                                       body, sizeof(body));
        }
        NSString *text = rc == 0 ? [NSString stringWithUTF8String:body] : nil;
        NSString *ip = [self extractIPFromString:text];
        if (ip.length && !firstIP) {
            firstIP = ip;
            firstSource = urlString;
        }
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"url"] = urlString;
        item[@"rc"] = @(rc);
        item[@"ip"] = ip ?: @"";
        NSString *bodyText = [self plainTextFromHTML:text];
        item[@"body"] = bodyText.length > 120 ? [bodyText substringToIndex:120] : bodyText;
        [results addObject:item];
    }

    NSMutableDictionary *resp = [NSMutableDictionary dictionary];
    resp[@"results"] = results;
    resp[@"mode"] = mode;
    resp[@"effectiveMode"] = effectiveMode;
    if (firstIP.length) {
        resp[@"ok"] = @YES;
        resp[@"ip"] = firstIP;
        resp[@"source"] = firstSource ?: @"";
    } else {
        resp[@"ok"] = @NO;
        resp[@"error"] = @"所有 IP 源均失败，请检查代理/转发器";
        if ([mode isEqualToString:@"kingcard"]) {
            resp[@"king"] = [[LCProxyKing shared] status];
        }
    }
    return resp;
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

    [server addHandlerForMethod:@"GET" path:@"/api/status" requestClass:[GCDWebServerRequest class]                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [self json:[self configPayload]];
    }];

    [server addHandlerForMethod:@"GET" path:@"/api/stats" requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [self json:[[LCProxyStats shared] aggregate]];
    }];

    // 统一诊断入口：把 /api/status 的原始字段**翻译成结论**，并附上跨进程现场。
    //
    // 存在的理由：状态字典有二十多个字段，判断"为什么连不上"需要把它们组合起来看 ——
    // 这件事此前由我逐轮手工做，也是反复误判的直接来源。这个端点把同一套判断固化成代码：
    // 直接给出"哪里坏了 / 下一步看什么"，并附带所有进程的状态快照以便跨进程对比。
    [server addHandlerForMethod:@"GET" path:@"/api/diag" requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSDictionary *payload = [self configPayload];
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        [out addEntriesFromDictionary:LCProxyDiagnose(payload)];
        out[@"pid"] = payload[@"pid"] ?: @0;
        out[@"bundleId"] = payload[@"bundleId"] ?: @"";
        out[@"version"] = payload[@"version"] ?: @"";
        // 本进程关键现场（便于快速核对，不必再翻整个 status）。
        NSDictionary *king = [payload[@"king"] isKindOfClass:[NSDictionary class]] ? payload[@"king"] : @{};
        out[@"king"] = @{
            @"forwarderPort": king[@"forwarderPort"] ?: @0,
            @"chainProxyPort": payload[@"chainProxyPort"] ?: @0,
            @"listenFdValid": king[@"listenFdValid"] ?: @0,
            @"listenProbeOk": king[@"listenProbeOk"] ?: @0,
            @"routePublished": king[@"routePublished"] ?: @0,
            @"running": king[@"running"] ?: @0,
            @"liveHttpPool": king[@"liveHttpPool"] ?: @0,
            @"liveHttpsPool": king[@"liveHttpsPool"] ?: @0,
            @"guidSource": king[@"guidSource"] ?: @"",
            @"lastError": king[@"lastError"] ?: @"",
            @"upstreamDiag": king[@"upstreamDiag"] ?: @{},
        };
        // 所有进程的现场（含私有/共享对照）——这正是"私有正常、共享不正常"的判定依据。
        out[@"statusTail"] = [self tailOfAppGroupLog:@"kingcard-status.log" maxLines:24];
        return [self json:out];
    }];

    // 一键重置凭证：丢弃共享凭证库里的缓存状态，重新领一整套全新 GUID + Q-Token + 代理池。
    //
    // 用途：凭证库在 App Group，被所有进程共享。若最新那条记录对运营商已失效（或被某个
    // 进程写坏），则每个读它的进程都会拿坏凭证去连、被运营商零字节关闭 —— 而自己重新领
    // 一套的进程却正常。这正好能造成"私有正常、共享不正常"。
    [server addHandlerForMethod:@"GET" path:@"/api/king/reset-credentials" requestClass:[GCDWebServerRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        [[LCProxyKing shared] resetSharedCredentialsAndRefresh];
        return [self json:@{ @"ok": @YES, @"msg": @"已丢弃缓存凭证并开始重新领取；约 2~3 秒后再看 king.upstreamDiag 与 liveHttpsPool。" }];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/config" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSDictionary *body = [self jsonBody:request];
        NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:[[LCProxyConfig shared] load]];
        for (NSString *key in @[@"proxyEnabled", @"blockNonTcp", @"debugLogging", @"trafficLogging", @"showProxyBanner", @"proxyMode", @"proxyType", @"proxyHost", @"proxyPort",
                                 @"kingUpstreamHost", @"kingUpstreamPort", @"kingRefreshURL", @"kingAutoDirectOnNonCellular",
                                 @"kingGuidOverride", @"kingTokenOverride", @"kingKeyOverride", @"kingPhone", @"kingQType",
                                 @"kingApn", @"kingTypeName", @"kingSubtype", @"kingExtraInfo", @"kingMccmnc", @"kingCardType"]) {
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
        // 手动“立即刷新凭证”：强制真实请求上游，不走本地缓存。
        BOOL ok = [[LCProxyKing shared] refreshCredentialsForce];
        NSMutableDictionary *resp = [NSMutableDictionary dictionaryWithDictionary:[[LCProxyKing shared] status]];
        resp[@"ok"] = @(ok);
        return [self json:resp];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/proxy-test-one" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        NSDictionary *body = [self jsonBody:request];
        NSString *url = [body[@"url"] isKindOfClass:[NSString class]] ? body[@"url"] : @"";
        return [self json:[self proxyTestOne:url]];
    }];

    [server addHandlerForMethod:@"POST" path:@"/api/proxy-test" requestClass:[GCDWebServerDataRequest class]
                   processBlock:^GCDWebServerResponse *(GCDWebServerRequest *request) {
        return [self json:[self proxyTestResult]];
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
