#import "LCProxyConfig.h"
#import "LCProxyPaths.h"
#import "lcproxy_bridge.h"
#import "LCProxyKing.h"
#import "KPKIngCore.h"
#import <Network/Network.h>
#include "webkit_proxy.h"
#include "async_proxy.h"

static NSString *const LCProxySettingsFile = @"settings.json";
static NSString *const LCProxyConfFile = @"proxychains.conf";
static const NSTimeInterval LCProxyNetworkMonitorInterval = 2.0;
static const NSTimeInterval LCProxyNetworkMonitorMaxAge = 10.0;
static const NSTimeInterval LCProxyPostRecoveryHealthDelay = 1.0;

static nw_path_monitor_t g_networkMonitor;

@interface LCProxyConfig ()
@property (nonatomic, strong) dispatch_source_t networkTimer;
@property (nonatomic, strong) dispatch_queue_t runtimeQueue;
@property (nonatomic, assign) int lastAppliedShouldDirect;
@property (nonatomic, copy) NSString *lastAppliedRuntimeSignature;
@property (nonatomic, copy) NSString *lastAppliedEffectiveMode;
@property (nonatomic, assign) int lastAppliedForwarderPort;
@property (nonatomic, copy) NSString *lifecycleState;
@property (nonatomic, assign) NSUInteger networkGeneration;
@property (nonatomic, assign) BOOL hasLastPathState;
@property (nonatomic, assign) int lastPathState;
@property (nonatomic, assign) int lastPathEffectiveDirect;
@property (nonatomic, assign) NSTimeInterval lastPathUpdateAt;
- (void)checkNetworkAndApplyIfNeeded;
- (void)handleNetworkPath:(nw_path_t)path;
- (NSString *)runtimeSignatureForSettings:(NSDictionary *)settings effectiveMode:(NSString *)effectiveMode;
- (void)enqueueRuntimeApplyForceRecovery:(BOOL)forceRecovery reason:(NSString *)reason;
- (void)startNetworkMonitorOnRuntimeQueue;
- (void)createPathMonitorOnQueue:(dispatch_queue_t)queue;
- (void)restartNetworkMonitorOnRuntimeQueue;
- (void)schedulePostRecoveryHealthCheck;
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

- (instancetype)init {
    self = [super init];
    if (self) {
        _runtimeQueue = dispatch_queue_create("com.liveproxy.runtime", DISPATCH_QUEUE_SERIAL);
        _lifecycleState = @"active";
        _lastAppliedShouldDirect = -1;
        _lastPathState = -1;
        _lastPathEffectiveDirect = -1;
        _lastAppliedForwarderPort = 0;
        _networkGeneration = 0;
    }
    return self;
}

- (NSString *)dataDirectory { return LCProxyDataDirectory(); }
- (NSString *)settingsPath { return [self.dataDirectory stringByAppendingPathComponent:LCProxySettingsFile]; }
- (NSString *)proxychainsConfPath { return [self.dataDirectory stringByAppendingPathComponent:LCProxyConfFile]; }

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
        NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:LCProxySettingsFile]];
        if (!data) continue;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([obj isKindOfClass:[NSDictionary class]]) {
            raw = obj;
            break;
        }
    }
    if (!raw) return [self defaults];
    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:[self defaults]];
    for (NSString *key in [self.defaults allKeys]) {
        if (raw[key]) merged[key] = raw[key];
    }
    return merged;
}

- (BOOL)saveSettings:(NSDictionary *)settings {
    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:[self defaults]];
    for (NSString *key in [self.defaults allKeys]) {
        if (settings[key]) merged[key] = settings[key];
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
        if (!data || ![data writeToFile:[dir stringByAppendingPathComponent:LCProxySettingsFile] options:NSDataWritingAtomic error:&err]) {
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
        lcproxy_network_should_direct()) {
        return @"direct";
    }
    return mode;
}

- (BOOL)writeProxychainsConf:(NSDictionary *)settings {
    return [self writeProxychainsConf:settings toDirectory:self.dataDirectory];
}

- (BOOL)writeProxychainsConf:(NSDictionary *)settings toDirectory:(NSString *)dir {
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *effectiveMode = [self effectiveProxyModeForSettings:settings];
    NSString *type = @"http";
    NSString *host = @"127.0.0.1";
    NSInteger port = 8080;
    if ([effectiveMode isEqualToString:@"kingcard"]) {
        // Local KingCard forwarder placeholder. The C core replaces the first
        // hop with the per-process override after reading this file.
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
    return [conf writeToFile:[dir stringByAppendingPathComponent:LCProxyConfFile]
                  atomically:YES encoding:NSUTF8StringEncoding error:&err];
}

- (NSString *)runtimeSignatureForSettings:(NSDictionary *)settings effectiveMode:(NSString *)effectiveMode {
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
    [signature appendFormat:@"effective=%@|", effectiveMode ?: @""];
    return signature;
}

// ---------------------------------------------------------------------------
// Runtime apply / foreground recovery
// ---------------------------------------------------------------------------

- (void)applyToRuntime {
    // Synchronous for callers that need the runtime to be applied before they
    // proceed (launch constructor, console save). The serial queue keeps this
    // ordered against foreground/network recovery runs.
    dispatch_sync(self.runtimeQueue, ^{
        @autoreleasepool {
            NSDictionary *settings = [self load];
            NSString *effectiveMode = [self effectiveProxyModeForSettings:settings];
            [self applyRuntimeSnapshot:settings effectiveMode:effectiveMode forceRecovery:NO];
        }
    });
}

- (void)requestRuntimeApplyAsync {
    [self enqueueRuntimeApplyForceRecovery:NO reason:@"request"];
}

- (void)requestForegroundRecoveryAsync {
    dispatch_async(self.runtimeQueue, ^{
        if ([self.lifecycleState isEqualToString:@"foregrounding"]) return;
        self.lifecycleState = @"foregrounding";
        [self enqueueRuntimeApplyForceRecovery:YES reason:@"foreground"];
    });
}

- (void)notifyWillEnterForeground {
    [self requestForegroundRecoveryAsync];
}

- (void)notifyDidEnterBackground {
    dispatch_async(self.runtimeQueue, ^{
        self.lifecycleState = @"background";
    });
}

- (void)notifyDidBecomeActive {
    dispatch_async(self.runtimeQueue, ^{
        BOOL wasForegrounding = [self.lifecycleState isEqualToString:@"foregrounding"];
        BOOL wasBackground = [self.lifecycleState isEqualToString:@"background"];
        self.lifecycleState = @"active";
        if (wasBackground) {
            // WillEnterForeground may have been missed during a fast resume.
            // Rebuild the network resources instead of reusing stale ones.
            [self enqueueRuntimeApplyForceRecovery:YES reason:@"active recovery"];
        } else if (!wasForegrounding) {
            // Cold start.
            [self enqueueRuntimeApplyForceRecovery:NO reason:@"active apply"];
        }
    });
}

- (NSString *)lifecycleState {
    @synchronized(self) {
        return _lifecycleState ?: @"active";
    }
}

- (NSUInteger)networkGeneration {
    @synchronized(self) {
        return _networkGeneration;
    }
}

- (NSDictionary *)runtimeDiagnostics {
    @synchronized(self) {
        return @{
            @"lifecycleState": _lifecycleState ?: @"active",
            @"networkGeneration": @(_networkGeneration),
            @"lastAppliedShouldDirect": @(_lastAppliedShouldDirect),
            @"lastAppliedEffectiveMode": _lastAppliedEffectiveMode ?: @"",
            @"lastAppliedForwarderPort": @(_lastAppliedForwarderPort),
            @"hasLastPathState": @(_hasLastPathState),
            @"lastPathState": @(_lastPathState),
            @"lastPathEffectiveDirect": @(_lastPathEffectiveDirect),
            @"lastPathUpdateAt": @(_lastPathUpdateAt),
        };
    }
}

- (void)enqueueRuntimeApplyForceRecovery:(BOOL)forceRecovery reason:(NSString *)reason {
    dispatch_async(self.runtimeQueue, ^{
        @autoreleasepool {
            NSDictionary *settings = [self load];
            NSString *effectiveMode = [self effectiveProxyModeForSettings:settings];
            if (forceRecovery) {
                self.networkGeneration++;
            }
            [self applyRuntimeSnapshot:settings effectiveMode:effectiveMode forceRecovery:forceRecovery];
            (void)reason;
        }
    });
}

- (void)applyRuntimeSnapshot:(NSDictionary *)s effectiveMode:(NSString *)effectiveMode forceRecovery:(BOOL)forceRecovery {
    NSString *signature = [self runtimeSignatureForSettings:s effectiveMode:effectiveMode];
    BOOL settingsChanged = !self.lastAppliedRuntimeSignature || ![signature isEqualToString:self.lastAppliedRuntimeSignature];

    LCProxyKing *king = [LCProxyKing shared];

    if (forceRecovery) {
        // Kill every old-generation relay before rebuilding the forwarder.
        lcproxy_async_close_all();
        [king shutdownActiveClients];
        [king forceRestartForwarderWithSettings:s effectiveMode:effectiveMode];
    } else {
        [king applyConfig:s];
    }


    int desiredForwarderPort = [effectiveMode isEqualToString:@"kingcard"] ? [king localForwarderPort] : 0;
    BOOL forwarderPortChanged = self.lastAppliedForwarderPort != desiredForwarderPort;
    if (desiredForwarderPort > 0) {
        lcproxy_control_set_proxy_override("127.0.0.1", desiredForwarderPort);
    } else {
        lcproxy_control_set_proxy_override(NULL, 0);
    }

    BOOL enabled = [s[@"proxyEnabled"] boolValue];
    BOOL proxyActive = enabled && ![effectiveMode isEqualToString:@"direct"];
    BOOL block = [s[@"blockNonTcp"] boolValue] && proxyActive;
    kp_set_debug_enabled([s[@"debugLogging"] boolValue] ? 1 : 0);

    BOOL needsRuntimeReload = forceRecovery || settingsChanged || forwarderPortChanged;

    // Always regenerate the shared conf. In auto-direct mode the on-disk conf
    // must match the effective mode before reload, otherwise a Wi-Fi -> cellular
    // transition can leave proxy_count at zero while proxychains is enabled.
    for (NSString *dir in LCProxyAllDataDirectories()) {
        [self writeProxychainsConf:s toDirectory:dir];
    }

    lcproxy_control_set_enabled(proxyActive ? 1 : 0);
    lcproxy_control_set_block_non_tcp(block ? 1 : 0);

    if (needsRuntimeReload) {
        lcproxy_control_reload_config();
        self.lastAppliedRuntimeSignature = signature;
        self.lastAppliedForwarderPort = desiredForwarderPort;
        self.lastAppliedEffectiveMode = effectiveMode;
        dispatch_async(dispatch_get_main_queue(), ^{
            livecontainer_reload_webkit_proxy();
        });
    } else {
        self.lastAppliedRuntimeSignature = signature;
        self.lastAppliedForwarderPort = desiredForwarderPort;
        self.lastAppliedEffectiveMode = effectiveMode;
    }

    self.lastAppliedShouldDirect = lcproxy_network_should_direct() ? 1 : 0;

    if (forceRecovery) {
        [self schedulePostRecoveryHealthCheck];
    }
}

- (void)schedulePostRecoveryHealthCheck {
    NSString *mode = self.lastAppliedEffectiveMode ?: @"";
    int port = self.lastAppliedForwarderPort;
    if (![mode isEqualToString:@"kingcard"] || port <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LCProxyPostRecoveryHealthDelay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [[LCProxyKing shared] performHealthCheck];
    });
}

// ---------------------------------------------------------------------------
// Network path monitoring
// ---------------------------------------------------------------------------

- (void)startNetworkMonitor {
    dispatch_async(self.runtimeQueue, ^{
        [self startNetworkMonitorOnRuntimeQueue];
    });
}

- (void)startNetworkMonitorOnRuntimeQueue {
    if (self.networkTimer) return;

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
    self.networkTimer = timer;

    [self createPathMonitorOnQueue:q];
}

- (void)createPathMonitorOnQueue:(dispatch_queue_t)queue {
    if (g_networkMonitor) return;
    g_networkMonitor = nw_path_monitor_create();
    if (!g_networkMonitor) return;
    __weak LCProxyConfig *weakSelf = self;
    nw_path_monitor_set_update_handler(g_networkMonitor, ^(nw_path_t path) {
        __strong LCProxyConfig *strongSelf = weakSelf;
        if (strongSelf) [strongSelf handleNetworkPath:path];
    });
    nw_path_monitor_set_queue(g_networkMonitor, queue);
    nw_path_monitor_start(g_networkMonitor);
}

- (void)restartNetworkMonitorOnRuntimeQueue {
    if (g_networkMonitor) {
        nw_path_monitor_cancel(g_networkMonitor);
        g_networkMonitor = NULL;
    }
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    [self createPathMonitorOnQueue:q];
}

- (void)handleNetworkPath:(nw_path_t)path {
    nw_path_status_t status = nw_path_get_status(path);
    BOOL satisfied = (status == nw_path_status_satisfied);
    BOOL cellular = nw_path_uses_interface_type(path, nw_interface_type_cellular);
    int state = (satisfied ? 1 : 0) | (cellular ? 2 : 0);
    int direct = (satisfied && !cellular) ? 1 : 0;

    dispatch_async(self.runtimeQueue, ^{
        BOOL changed = !self.hasLastPathState ||
                       self.lastPathState != state ||
                       self.lastPathEffectiveDirect != direct;
        self.hasLastPathState = YES;
        self.lastPathState = state;
        self.lastPathEffectiveDirect = direct;
        self.lastPathUpdateAt = [[NSDate date] timeIntervalSince1970];

        // Fail-closed: only allow direct when the active path is known to be
        // satisfied and non-cellular.
        lcproxy_network_monitor_update(satisfied ? 1 : 0, direct ? 1 : 0);

        if (changed) {
            [self enqueueRuntimeApplyForceRecovery:YES reason:@"NWPath changed"];
        }
    });
}

- (void)checkNetworkAndApplyIfNeeded {
    dispatch_async(self.runtimeQueue, ^{
        NSDictionary *settings = [self load];
        NSString *mode = [settings[@"proxyMode"] isKindOfClass:[NSString class]] ? settings[@"proxyMode"] : @"custom";
        if (![mode isEqualToString:@"kingcard"] || ![settings[@"kingAutoDirectOnNonCellular"] boolValue]) {
            self.lastAppliedShouldDirect = -1;
            return;
        }

        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (self.lastPathUpdateAt == 0 || now - self.lastPathUpdateAt > LCProxyNetworkMonitorMaxAge) {
            // NWPathMonitor can stop delivering callbacks after a suspend/resume
            // cycle. Recreate it here instead of trusting a stale cache.
            [self restartNetworkMonitorOnRuntimeQueue];
        }

        int shouldDirect = lcproxy_network_should_direct() ? 1 : 0;
        if (shouldDirect != self.lastAppliedShouldDirect) {
            [self enqueueRuntimeApplyForceRecovery:YES reason:@"network timer fallback"];
        }
    });
}

@end
