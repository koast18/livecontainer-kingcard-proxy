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
static const NSUInteger LCProxyMaxRecoveryRetries = 3;

NSString *const LCProxyForwarderUnavailableNotification = @"LCProxyForwarderUnavailableNotification";

static nw_path_monitor_t g_networkMonitor;

@interface LCProxyConfig ()
@property (nonatomic, strong) dispatch_source_t networkTimer;
@property (nonatomic, strong) dispatch_queue_t runtimeQueue;
@property (nonatomic, assign) int lastAppliedShouldDirect;
@property (nonatomic, copy) NSString *lastAppliedRuntimeSignature;
@property (nonatomic, copy) NSString *lastAppliedEffectiveMode;
@property (nonatomic, copy) NSString *lastAppliedConfigPath;
@property (nonatomic, assign) int lastAppliedForwarderPort;
@property (nonatomic, copy) NSString *lifecycleState;
@property (nonatomic, assign) NSUInteger networkGeneration;
@property (nonatomic, assign) BOOL hasLastPathState;
@property (nonatomic, assign) int lastPathState;
@property (nonatomic, assign) int lastPathEffectiveDirect;
@property (nonatomic, assign) NSTimeInterval lastPathUpdateAt;
// 前台恢复自愈：恢复后的健康检查失败时再补一轮强制恢复（有上限，
// 防止上游真不可用时无限重启转发器）。
@property (nonatomic, assign) NSUInteger recoveryRetryCount;
@property (nonatomic, assign) NSTimeInterval lastForegroundingAt;
// 王卡转发器缺失时的持续重启状态：fail-closed 丢包期间按退避不断尝试重建，
// 并在进入该状态时通知用户（绝不直连——直连会消耗通用流量）。
@property (nonatomic, assign) BOOL forwarderUnavailable;
@property (nonatomic, assign) NSUInteger forwarderRetryCount;
@property (nonatomic, assign) BOOL forwarderRetryScheduled;
- (void)checkNetworkAndApplyIfNeeded;
- (void)handleNetworkPath:(nw_path_t)path;
- (NSString *)runtimeSignatureForSettings:(NSDictionary *)settings effectiveMode:(NSString *)effectiveMode;
- (void)enqueueRuntimeApplyForceRecovery:(BOOL)forceRecovery reason:(NSString *)reason;
- (void)startNetworkMonitorOnRuntimeQueue;
- (void)createPathMonitorOnQueue:(dispatch_queue_t)queue;
- (void)restartNetworkMonitorOnRuntimeQueue;
- (void)schedulePostRecoveryHealthCheck;
- (void)noteForwarderAvailability:(BOOL)available;
- (void)scheduleForwarderRecoveryRetry;
- (void)resetRecoveryBudgets;
- (NSDictionary *)mergedSettingsFrom:(NSDictionary *)settings;
- (NSDictionary *)settingsInDirectory:(NSString *)directory;
- (NSDictionary *)newestFallbackSettings;
- (BOOL)synchronizeSettings:(NSDictionary *)settings;
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

- (NSString *)dataDirectory { return LCProxyCanonicalDataDirectory(); }
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
    // The App Group is the authority when it exists. A launch-private copy is
    // only a one-time migration source; otherwise a newer stale private write
    // can silently roll a shared app back to an obsolete proxy route.
    NSDictionary *raw = [self settingsInDirectory:self.dataDirectory];
    if (raw) return [self mergedSettingsFrom:raw];

    raw = [self newestFallbackSettings];
    if (!raw) return [self defaults];
    NSDictionary *merged = [self mergedSettingsFrom:raw];
    // Do not run with a fallback selected but no canonical file: the C
    // constructor must converge on the same path before any route is enabled.
    if (![self synchronizeSettings:merged]) return [self defaults];
    return merged;
}

- (NSDictionary *)settingsInDirectory:(NSString *)directory {
    if (!directory.length) return nil;
    NSString *path = [directory stringByAppendingPathComponent:LCProxySettingsFile];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

- (NSDictionary *)newestFallbackSettings {
    NSDictionary *raw = nil;
    NSDate *rawDate = nil;
    for (NSString *dir in LCProxyAllDataDirectories()) {
        if ([dir isEqualToString:self.dataDirectory]) continue;
        NSString *path = [dir stringByAppendingPathComponent:LCProxySettingsFile];
        NSDate *mtime = nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            mtime = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil].fileModificationDate;
        }
        if (!mtime) continue;
        NSDictionary *obj = [self settingsInDirectory:dir];
        if (!obj) continue;
        if (!rawDate || [mtime compare:rawDate] == NSOrderedDescending) {
            raw = obj;
            rawDate = mtime;
        }
    }
    return raw;
}

- (NSDictionary *)mergedSettingsFrom:(NSDictionary *)settings {
    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:[self defaults]];
    for (NSString *key in [self.defaults allKeys]) {
        if (settings[key]) merged[key] = settings[key];
    }
    return merged;
}

- (BOOL)synchronizeSettings:(NSDictionary *)settings {
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:settings options:NSJSONWritingPrettyPrinted error:&err];
    if (!data) return NO;
    NSString *dir = self.dataDirectory;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:&err]) return NO;
    NSString *settingsPath = [dir stringByAppendingPathComponent:LCProxySettingsFile];
    NSData *existing = [NSData dataWithContentsOfFile:settingsPath];
    if (![existing isEqualToData:data] &&
        ![data writeToFile:settingsPath options:NSDataWritingAtomic error:&err]) return NO;
    return [self writeProxychainsConf:settings toDirectory:dir];
}

- (BOOL)saveSettings:(NSDictionary *)settings {
    return [self synchronizeSettings:[self mergedSettingsFrom:settings]];
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
    if (!dir.length || ![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                             withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
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
    BOOL blockNonTcp = [settings[@"blockNonTcp"] boolValue] ||
                       [effectiveMode isEqualToString:@"kingcard"];
    if (blockNonTcp) {
        [conf appendString:@"# Drop non-TCP traffic (required for KingCard; optional otherwise).\n"];
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
    NSString *path = [dir stringByAppendingPathComponent:LCProxyConfFile];
    NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if ([existing isEqualToString:conf]) return YES;
    NSError *err = nil;
    return [conf writeToFile:path
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
        // “foregrounding” 只用于去重 willEnterForeground+didBecomeActive 这对通知。
        // 若上一轮恢复卡住（老版本 stop 死锁时该状态会永远停在这里），
        // 15 秒后必须视为陈旧并允许新一轮恢复，否则状态机永久闭锁。
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if ([self.lifecycleState isEqualToString:@"foregrounding"] &&
            now - self.lastForegroundingAt < 15.0) return;
        self.lifecycleState = @"foregrounding";
        self.lastForegroundingAt = now;
        [self resetRecoveryBudgets];
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
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        // 陈旧的 foregrounding（上一轮恢复卡死）必须按 background 处理，
        // 否则 didBecomeActive 永远不会再触发恢复。
        BOOL wasForegrounding = [self.lifecycleState isEqualToString:@"foregrounding"] &&
                                (now - self.lastForegroundingAt < 15.0);
        BOOL wasBackground = [self.lifecycleState isEqualToString:@"background"] ||
                             ([self.lifecycleState isEqualToString:@"foregrounding"] && !wasForegrounding);
        self.lifecycleState = @"active";
        if (wasBackground) {
            // WillEnterForeground 可能被错过（快速恢复）；也可能是上一轮恢复
            // 卡死后的自愈入口。重建网络资源而不是复用陈旧资源。
            [self resetRecoveryBudgets];
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
            @"forwarderUnavailable": @(_forwarderUnavailable),
            @"forwarderRetryCount": @(_forwarderRetryCount),
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
    // A forwarder receives an ephemeral port before proxychains has installed
    // that port. Keep credential bootstrap closed until both layers agree.
    [king beginRoutePublication];

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
    // 王卡模式下转发器没起来（端口为 0）时必须 fail-closed：保持代理启用并清空
    // override，让链路指向 conf 的 18080 占位端口 —— 所有连接被立刻拒绝丢弃。
    // 绝不允许退化为直连：直连会绕过王卡通道、消耗通用流量。
    BOOL forwarderUnavailable = [effectiveMode isEqualToString:@"kingcard"] &&
                                enabled && desiredForwarderPort <= 0;
    // The forwarder only carries TCP. Keep UDP/QUIC blocked for every active
    // KingCard session, including while a failed forwarder is being rebuilt.
    BOOL block = proxyActive && ([s[@"blockNonTcp"] boolValue] ||
                                 [effectiveMode isEqualToString:@"kingcard"]);
    kp_set_debug_enabled([s[@"debugLogging"] boolValue] ? 1 : 0);

    // Always regenerate the canonical conf. In auto-direct mode the on-disk conf
    // must match the effective mode before reload, otherwise a Wi-Fi -> cellular
    // transition can leave proxy_count at zero while proxychains is enabled.
    NSString *configPath = self.proxychainsConfPath;
    BOOL configPathChanged = !self.lastAppliedConfigPath ||
                             ![configPath isEqualToString:self.lastAppliedConfigPath];
    BOOL configWritten = [self writeProxychainsConf:s toDirectory:self.dataDirectory];

    // C code cannot derive an App Group container from a private dylib path.
    // Pin it to the Foundation-resolved canonical file; an unwritable/missing
    // canonical file must stay closed instead of reviving a private fallback.
    BOOL wasConfigValid = lcproxy_control_get_config_valid();
    BOOL configReady = lcproxy_control_set_config_path(configPath.fileSystemRepresentation) && configWritten;
    if (!configReady) {
        lcproxy_control_set_config_valid(0);
    }

    // Never reparse a stale file after a canonical write failed. A later
    // successful write must reload even when settings and port are unchanged.
    BOOL needsRuntimeReload = configReady && (forceRecovery || settingsChanged ||
                                              forwarderPortChanged || configPathChanged ||
                                              (proxyActive && !wasConfigValid));

    lcproxy_control_set_enabled(proxyActive ? 1 : 0);
    lcproxy_control_set_block_non_tcp(block ? 1 : 0);

    if (needsRuntimeReload) {
        lcproxy_control_reload_config();
        // The parser resets file-derived state at each reload. Reapply the
        // effective runtime policy so KingCard never re-enables UDP/QUIC if a
        // config read fails or a stale file lacks block_non_tcp.
        lcproxy_control_set_block_non_tcp(block ? 1 : 0);
        self.lastAppliedRuntimeSignature = signature;
        self.lastAppliedConfigPath = configPath;
        self.lastAppliedForwarderPort = desiredForwarderPort;
        self.lastAppliedEffectiveMode = effectiveMode;
        dispatch_async(dispatch_get_main_queue(), ^{
            livecontainer_reload_webkit_proxy();
        });
    } else {
        self.lastAppliedRuntimeSignature = signature;
        self.lastAppliedConfigPath = configPath;
        self.lastAppliedForwarderPort = desiredForwarderPort;
        self.lastAppliedEffectiveMode = effectiveMode;
    }

    if (configReady && (!proxyActive || lcproxy_control_get_config_valid())) {
        [king publishRouteForSettings:s proxyActive:proxyActive];
    }

    self.lastAppliedShouldDirect = lcproxy_network_should_direct() ? 1 : 0;

    [self noteForwarderAvailability:!forwarderUnavailable];
    if (forwarderUnavailable) {
        // 持续尽力重建转发器（纯本地 bind，不碰上游），期间保持丢包。
        [self scheduleForwarderRecoveryRetry];
    }

    if (forceRecovery) {
        [self schedulePostRecoveryHealthCheck];
    }
}

- (void)schedulePostRecoveryHealthCheck {
    NSString *mode = self.lastAppliedEffectiveMode ?: @"";
    int port = self.lastAppliedForwarderPort;
    if (![mode isEqualToString:@"kingcard"] || port <= 0) return;
    // 转发器缺失（端口 0）由 scheduleForwarderRecoveryRetry 的持续重建负责，
    // 这里只处理“转发器在跑但不健康（凭证/上游）”的情况。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LCProxyPostRecoveryHealthDelay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL ok = [[LCProxyKing shared] performHealthCheck];
        if (ok) {
            dispatch_async(self.runtimeQueue, ^{
                self.recoveryRetryCount = 0;
            });
            return;
        }
        // 恢复后健康检查失败（凭证不可用/上游异常）：自动再补一轮强制恢复，
        // 有上限——上游真不可用时不无限重启，等下一个前台/网络事件重新计数。
        __block BOOL shouldRetry = NO;
        dispatch_sync(self.runtimeQueue, ^{
            if (self.recoveryRetryCount < LCProxyMaxRecoveryRetries) {
                self.recoveryRetryCount++;
                shouldRetry = YES;
            }
        });
        if (shouldRetry) {
            [self enqueueRuntimeApplyForceRecovery:YES reason:@"health check failed"];
        }
    });
}

// ---------------------------------------------------------------------------
// 转发器缺失：fail-closed + 用户提示 + 持续重建
// ---------------------------------------------------------------------------

// 仅在“可用 → 不可用”的跳变上提示一次；恢复后复位，再次故障会重新提示。
// 外部恢复事件（回前台/网络变化）会重置该状态，故障仍在时用户会再次看到提示。
- (void)noteForwarderAvailability:(BOOL)available {
    if (available) {
        if (self.forwarderUnavailable) {
            self.forwarderUnavailable = NO;
            self.forwarderRetryCount = 0;
        }
        return;
    }
    if (self.forwarderUnavailable) return;
    self.forwarderUnavailable = YES;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:LCProxyForwarderUnavailableNotification
                      object:nil
                    userInfo:@{
        @"message": @"王卡转发器不可用：已阻断联网以防直连消耗通用流量，正在自动恢复…",
    }];
}

// 转发器重启是纯本地操作（bind 127.0.0.1 临时端口，不请求上游），可以也应该
// 持续重试：1s 起按退避加大间隔，30s 后保持 60s 一杆，直到重建成功或用户/
// 系统事件再次触发恢复。期间连接全部被丢弃，绝不直连。
- (void)scheduleForwarderRecoveryRetry {
    if (self.forwarderRetryScheduled) return;
    self.forwarderRetryScheduled = YES;
    static const NSTimeInterval steps[] = {1.0, 2.0, 2.0, 4.0, 8.0, 15.0, 30.0};
    static const NSUInteger stepCount = sizeof(steps) / sizeof(steps[0]);
    NSTimeInterval delay = (self.forwarderRetryCount < stepCount)
                               ? steps[self.forwarderRetryCount]
                               : 60.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   self.runtimeQueue, ^{
        self.forwarderRetryScheduled = NO;
        self.forwarderRetryCount++;
        [self enqueueRuntimeApplyForceRecovery:YES reason:@"forwarder restart retry"];
    });
}

- (void)resetRecoveryBudgets {
    self.recoveryRetryCount = 0;
    self.forwarderRetryCount = 0;
    // 重置跳变标记：故障仍在时，本轮事件会再次向用户提示。
    self.forwarderUnavailable = NO;
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
            [self resetRecoveryBudgets];
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
