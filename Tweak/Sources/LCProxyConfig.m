#import "LCProxyConfig.h"
#import "LCProxyPaths.h"
#import "lcproxy_bridge.h"
#import "LCProxyKing.h"
#import "KPKIngCore.h"
#include "webkit_proxy.h"

static NSString *const LCProxySettingsFile = @"settings.json";
static NSString *const LCProxyConfFile = @"proxychains.conf";
static const NSTimeInterval LCProxyNetworkMonitorInterval = 2.0;

@interface LCProxyConfig ()
@property (nonatomic, strong) dispatch_source_t networkTimer;
@property (nonatomic, assign) int lastAppliedCellular;
@property (nonatomic, copy) NSString *lastAppliedRuntimeSignature;
@property (nonatomic, assign) int lastAppliedForwarderPort;
- (void)checkNetworkAndApplyIfNeeded;
- (NSString *)runtimeSignatureForSettings:(NSDictionary *)settings;
@end

@implementation LCProxyConfig

+ (instancetype)shared {
    static LCProxyConfig *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[LCProxyConfig alloc] init];
    });
    return instance;
}

- (NSString *)dataDirectory {
    return LCProxyDataDirectory();
}

- (NSString *)settingsPath {
    return [self.dataDirectory stringByAppendingPathComponent:LCProxySettingsFile];
}

- (NSString *)proxychainsConfPath {
    return [self.dataDirectory stringByAppendingPathComponent:LCProxyConfFile];
}

- (NSDictionary *)defaults {
    return @{
        @"proxyEnabled": @YES,
        @"blockNonTcp": @NO,
        @"debugLogging": @NO,
        @"showProxyBanner": @YES,
        @"proxyMode": @"custom",
        @"proxyType": @"http",
        @"proxyHost": @"127.0.0.1",
        @"proxyPort": @8080,
        @"kingUpstreamHost": @"157.148.54.212",
        @"kingUpstreamPort": @8091,
        @"kingRefreshURL": @"http://kc.iikira.com/kingcard",
        @"kingAutoDirectOnNonCellular": @NO,
        @"kingGuidOverride": [NSNull null],
        @"kingTokenOverride": [NSNull null],
        @"kingKeyOverride": [NSNull null],
        @"kingPhone": @"18812341234",
        @"kingQType": @"httpcom",
        @"kingApn": @"UNKNOW",
        @"kingTypeName": @"UNKNOW",
        @"kingSubtype": @0,
        @"kingExtraInfo": @"UNKNOW",
        @"kingMccmnc": @"NULLNULL",
        @"kingCardType": @1,
    };
}

- (NSDictionary *)load {
    NSDictionary *raw = nil;
    for (NSString *dir in LCProxyAllDataDirectories()) {
        NSString *path = [dir stringByAppendingPathComponent:LCProxySettingsFile];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([obj isKindOfClass:[NSDictionary class]]) {
            raw = obj;
            break;
        }
    }
    if (!raw) return [self defaults];
    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:[self defaults]];
    for (NSString *key in [self defaults]) {
        id v = raw[key];
        if (v) merged[key] = v;
    }
    return merged;
}

- (BOOL)saveSettings:(NSDictionary *)settings {
    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:[self defaults]];
    for (NSString *key in [self defaults]) {
        id v = settings[key];
        if (v) merged[key] = v;
    }
    BOOL ok = YES;
    for (NSString *dir in LCProxyAllDataDirectories()) {
        NSError *err = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES attributes:nil error:&err]) {
            ok = NO;
            continue;
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:merged options:NSJSONWritingPrettyPrinted error:&err];
        if (!data || ![data writeToFile:[dir stringByAppendingPathComponent:@"settings.json"] options:NSDataWritingAtomic error:&err]) {
            ok = NO;
            continue;
        }
        if (![self writeProxychainsConf:merged toDirectory:dir]) ok = NO;
    }
    return ok;
}

- (NSString *)effectiveProxyModeForSettings:(NSDictionary *)settings {
    NSString *mode = [settings[@"proxyMode"] isKindOfClass:[NSString class]] ? settings[@"proxyMode"] : @"custom";
    if ([mode isEqualToString:@"kingcard"] &&
        [settings[@"kingAutoDirectOnNonCellular"] boolValue] &&
        !lcproxy_stats_is_cellular()) {
        return @"direct";
    }
    return mode;
}

- (BOOL)writeProxychainsConf:(NSDictionary *)settings {
    return [self writeProxychainsConf:settings toDirectory:self.dataDirectory];
}

- (BOOL)writeProxychainsConf:(NSDictionary *)settings toDirectory:(NSString *)dir {
    NSString *effectiveMode = [self effectiveProxyModeForSettings:settings];
    NSString *type = @"http";
    NSString *host = @"127.0.0.1";
    NSInteger port = 8080;
    if ([effectiveMode isEqualToString:@"kingcard"]) {
        // Local KingCard forwarder: handles token fetch + Q-GUID/Q-Token headers.
        host = @"127.0.0.1";
        port = 18080;
    } else if ([effectiveMode isEqualToString:@"custom"]) {
        type = [settings[@"proxyType"] isKindOfClass:[NSString class]] ? settings[@"proxyType"] : @"http";
        host = [settings[@"proxyHost"] isKindOfClass:[NSString class]] && [settings[@"proxyHost"] length] ? settings[@"proxyHost"] : @"127.0.0.1";
        port = [settings[@"proxyPort"] respondsToSelector:@selector(integerValue)] ? [settings[@"proxyPort"] integerValue] : 8080;
        if (port <= 0 || port > 65535) port = 8080;
    }
    NSMutableString *conf = [NSMutableString string];
    [conf appendString:@"# LiveContainer ProxyChains configuration\n"];
    [conf appendString:@"# Generated by LiveProxyControl. Edit from the console app.\n"];
    [conf appendString:@"strict_chain\n"];
    if (![effectiveMode isEqualToString:@"direct"]) {
        [conf appendString:@"# Proxy DNS through the HTTP proxy (keeps DNS inside the tunnel).\n"];
        [conf appendString:@"proxy_dns\n"];
    }
    [conf appendString:@"tcp_read_time_out 15000\n"];
    [conf appendString:@"tcp_connect_time_out 8000\n"];
    if ([settings[@"blockNonTcp"] boolValue]) {
        [conf appendString:@"# Drop non-TCP traffic (UDP/QUIC/ICMP/raw sockets).\n"];
        [conf appendString:@"block_non_tcp\n"];
    }
    [conf appendString:@"# Exclude loopback and common LAN ranges so local services keep working.\n"];
    [conf appendString:@"localnet 127.0.0.0/255.0.0.0\n"];
    [conf appendString:@"localnet ::1/128\n"];
    [conf appendString:@"localnet 192.168.0.0/255.255.0.0\n"];
    [conf appendString:@"localnet 10.0.0.0/255.0.0.0\n"];
    if ([effectiveMode isEqualToString:@"direct"]) {
        [conf appendString:@"# Direct mode: no upstream proxy, proxychains core will bypass traffic.\n"];
    } else {
        [conf appendString:@"[ProxyList]\n"];
        [conf appendFormat:@"%@ %@ %ld\n", type, host, (long)port];
    }
    NSError *err = nil;
    return [conf writeToFile:[dir stringByAppendingPathComponent:@"proxychains.conf"] atomically:YES encoding:NSUTF8StringEncoding error:&err];
}

- (NSString *)runtimeSignatureForSettings:(NSDictionary *)settings {
    NSArray<NSString *> *keys = @[
        @"proxyEnabled", @"proxyMode", @"proxyType", @"proxyHost", @"proxyPort",
        @"blockNonTcp", @"debugLogging", @"kingAutoDirectOnNonCellular",
        @"kingGuidOverride", @"kingTokenOverride", @"kingKeyOverride",
        @"kingPhone", @"kingQType", @"kingApn", @"kingTypeName", @"kingSubtype",
        @"kingExtraInfo", @"kingMccmnc", @"kingCardType"
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
    [signature appendFormat:@"effective=%@|", [self effectiveProxyModeForSettings:settings]];
    return signature;
}

- (void)applyToRuntime {
    NSDictionary *s = [self load];
    NSString *signature = [self runtimeSignatureForSettings:s];
    BOOL settingsChanged = !self.lastAppliedRuntimeSignature || ![signature isEqualToString:self.lastAppliedRuntimeSignature];

    // Start/refresh the KingCard forwarder before computing the per-process
    // override. Multiple LiveContainer processes each own an ephemeral port, so
    // they no longer contend for the fixed 127.0.0.1:18080 listener.
    [[LCProxyKing shared] applyConfig:s];

    NSString *effectiveMode = [self effectiveProxyModeForSettings:s];
    int desiredForwarderPort = 0;
    if ([effectiveMode isEqualToString:@"kingcard"]) {
        desiredForwarderPort = [[LCProxyKing shared] localForwarderPort];
    }
    BOOL forwarderPortChanged = self.lastAppliedForwarderPort != desiredForwarderPort;
    if (desiredForwarderPort > 0) {
        lcproxy_control_set_proxy_override("127.0.0.1", desiredForwarderPort);
    } else {
        lcproxy_control_set_proxy_override(NULL, 0);
    }

    BOOL enabled = [s[@"proxyEnabled"] boolValue];
    BOOL proxyActive = enabled && ![effectiveMode isEqualToString:@"direct"];
    BOOL block = [s[@"blockNonTcp"] boolValue] && proxyActive;
    BOOL debugLogging = [s[@"debugLogging"] boolValue];
    kp_set_debug_enabled(debugLogging ? 1 : 0);

    BOOL needsRuntimeReload = settingsChanged || forwarderPortChanged;
    if (needsRuntimeReload) {
        // Re-read our dedicated proxychains.conf so changes made through the
        // console take effect without restarting the whole process. The
        // per-process proxy override is applied by the C core after parsing.
        lcproxy_control_reload_config();
    }
    lcproxy_control_set_enabled(proxyActive ? 1 : 0);
    lcproxy_control_set_block_non_tcp(block ? 1 : 0);
    _lastAppliedCellular = lcproxy_stats_is_cellular() ? 1 : 0;
    if (needsRuntimeReload) {
        livecontainer_reload_webkit_proxy();
    }
    self.lastAppliedRuntimeSignature = signature;
    self.lastAppliedForwarderPort = desiredForwarderPort;
}

- (void)startNetworkMonitor {
    if (_networkTimer) return;
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LCProxyNetworkMonitorInterval * NSEC_PER_SEC)),
                              (uint64_t)(LCProxyNetworkMonitorInterval * NSEC_PER_SEC),
                              (uint64_t)(LCProxyNetworkMonitorInterval * NSEC_PER_SEC / 2));
    __weak LCProxyConfig *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf checkNetworkAndApplyIfNeeded];
    });
    dispatch_resume(timer);
    _networkTimer = timer;
}

- (void)checkNetworkAndApplyIfNeeded {
    NSDictionary *settings = [self load];
    NSString *mode = [settings[@"proxyMode"] isKindOfClass:[NSString class]] ? settings[@"proxyMode"] : @"custom";
    if (![mode isEqualToString:@"kingcard"] || ![settings[@"kingAutoDirectOnNonCellular"] boolValue]) {
        _lastAppliedCellular = -1;
        return;
    }
    int cellular = lcproxy_stats_is_cellular() ? 1 : 0;
    if (cellular != _lastAppliedCellular) {
        _lastAppliedCellular = cellular;
        [self applyToRuntime];
    }
}

@end
