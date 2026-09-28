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
// WebKit 代理配置实际生效的转发器端口。必须独立跟踪：见 applyRuntimeSnapshot 里
// 的说明——它不能依赖 needsRuntimeReload。
@property (nonatomic, assign) int lastWebkitAppliedPort;
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
// 上次保存的结果（供 /api/diag）：写进了哪些目录、字节数、错误、能否读回。
@property (nonatomic, assign) NSTimeInterval lastSaveAt;
@property (nonatomic, assign) NSUInteger lastSaveBytes;
@property (nonatomic, copy) NSString *lastSaveError;
@property (nonatomic, copy) NSArray *lastSavePerDirectory;
@property (nonatomic, assign) NSUInteger forwarderRetryCount;
@property (nonatomic, assign) BOOL forwarderRetryScheduled;
- (void)checkNetworkAndApplyIfNeeded;
- (void)handleNetworkPath:(nw_path_t)path;
- (NSString *)runtimeSignatureForSettings:(NSDictionary *)settings effectiveMode:(NSString *)effectiveMode;
- (void)enqueueRuntimeApplyForceRecovery:(BOOL)forceRecovery reason:(NSString *)reason;
/// 实际实现；公开入口 applyRuntimeSnapshot:... 只负责 @try/@catch 崩溃加固。
- (void)applyRuntimeSnapshotUnsafe:(NSDictionary *)s effectiveMode:(NSString *)effectiveMode forceRecovery:(BOOL)forceRecovery;
- (void)startNetworkMonitorOnRuntimeQueue;
- (void)createPathMonitorOnQueue:(dispatch_queue_t)queue;
- (void)restartNetworkMonitorOnRuntimeQueue;
- (void)schedulePostRecoveryHealthCheck;
- (void)noteForwarderAvailability:(BOOL)available;
- (void)scheduleForwarderRecoveryRetry;
// 记录/读取"上次保存写进了哪些目录"；见 synchronizeSettings。
- (void)noteSaveDiagnostics:(NSArray *)perDir bytes:(NSUInteger)bytes error:(NSString *)error;
- (void)resetRecoveryBudgets;
- (NSDictionary *)mergedSettingsFrom:(NSDictionary *)settings;
// settingsInDirectory: 已在公开头文件声明（诊断与迁移共用）。
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
        @"trafficLogging": @YES,
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
    if (!data) {
        [self noteSaveDiagnostics:@[] bytes:0 error:[NSString stringWithFormat:@"序列化失败: %@", err.localizedDescription ?: @"?"]];
        return NO;
    }
    BOOL wroteAny = NO;
    NSMutableArray *perDir = [NSMutableArray array];
    for (NSString *dir in LCProxyAllDataDirectories()) {
        if (!dir.length) continue;
        NSString *dirResult = @"?";
        NSError *dirErr = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES attributes:nil error:&dirErr]) {
            dirResult = [NSString stringWithFormat:@"不可创建目录: %@", dirErr.localizedDescription ?: @"?"];
            [perDir addObject:@{ @"dir": dir, @"result": dirResult }];
            continue;
        }
        NSString *settingsPath = [dir stringByAppendingPathComponent:LCProxySettingsFile];
        NSData *existing = [NSData dataWithContentsOfFile:settingsPath];
        if ([existing isEqualToData:data]) {
            wroteAny = YES;
            dirResult = @"内容已一致";
        } else if ([data writeToFile:settingsPath options:NSDataWritingAtomic error:&dirErr]) {
            wroteAny = YES;
            dirResult = @"已写入";
        } else {
            dirResult = [NSString stringWithFormat:@"写入失败: %@", dirErr.localizedDescription ?: @"?"];
        }
        // 回读校验：写入成功不等于"下次读取能得到同样内容"（权限/沙箱/符号链接都可能作梗）。
        NSDictionary *readBack = [self settingsInDirectory:dir];
        BOOL verified = readBack && readBack.count > 0;
        [perDir addObject:@{ @"dir": dir, @"result": dirResult, @"readBackOK": @(verified) }];
        if (!verified) wroteAny = NO;

        if ([self writeProxychainsConf:settings toDirectory:dir]) {
            wroteAny = YES;
        }
    }
    [self noteSaveDiagnostics:perDir bytes:data.length error:nil];
    return wroteAny;
}

// 记录上次保存的结果，供 /api/diag 展示"保存到底写进了哪里、能否读回"。
// 用户报告的"保存似乎有用但读取不正常"正需要这组数据来判断。
//
// 注意：LCProxyConfig **没有**自己的锁（它的写入都在串行 runtimeQueue 上，读取是只读快照）。
// 这里用 @synchronized(self) 保护这几个字段的赋值，避免与读取方（诊断）交错时看到半更新的
// 组合；不做任何可能回头的调用，因此不会引入锁序问题。
- (void)noteSaveDiagnostics:(NSArray *)perDir bytes:(NSUInteger)bytes error:(NSString *)error {
    @synchronized (self) {
        self.lastSaveAt = [[NSDate date] timeIntervalSince1970];
        self.lastSaveBytes = bytes;
        self.lastSaveError = error ?: @"";
        self.lastSavePerDirectory = perDir ?: @[];
    }
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
    BOOL wroteAny = NO;
    for (NSString *dir in LCProxyAllDataDirectories()) {
        if ([self writeProxychainsConf:settings toDirectory:dir]) wroteAny = YES;
    }
    return wroteAny;
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

// ---------------------------------------------------------------------------
// 配置读写**全链路**诊断
// ---------------------------------------------------------------------------
//
// 用户报告："控制台读配置不正常，但保存似乎有用" —— 这种**读写不对称**无法靠
// settingsPath/settingsExists 两个字段判断。这里把每一步摊开：
//   · 权威目录（canonical）是哪个、它可写吗？
//   · 每个候选目录里 settings.json / proxychains.conf 是否存在、大小、修改时间、
//     能否解析、解析出多少键、关键键（proxyMode）是什么？
//   · 最终 load 用的是哪一份、为什么（权威命中 / 回退到最新 / 落到默认值）？
//   · 上次保存分别写进了哪些目录、能否读回？
// 只读、不写 —— 诊断绝不能改变被诊断的状态。
- (NSDictionary *)configDiagnostics {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *canonical = self.dataDirectory;
    NSArray<NSString *> *dirs = LCProxyAllDataDirectories();

    NSMutableArray *perDir = [NSMutableArray array];
    for (NSString *dir in dirs) {
        if (!dir.length) continue;
        NSMutableDictionary *e = [NSMutableDictionary dictionary];
        e[@"dir"] = dir;
        e[@"isCanonical"] = @([dir isEqualToString:canonical]);
        e[@"writable"] = @([fm isWritableFileAtPath:dir]);

        NSString *sp = [dir stringByAppendingPathComponent:LCProxySettingsFile];
        BOOL settingsExists = [fm fileExistsAtPath:sp];
        e[@"settingsExists"] = @(settingsExists);
        if (settingsExists) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:sp error:nil];
            e[@"settingsSize"] = attrs[NSFileSize] ?: @0;
            NSDate *mtime = attrs[NSFileModificationDate];
            e[@"settingsMtime"] = mtime ? @(mtime.timeIntervalSince1970) : @0;
            // 能否真的读出来并解析成字典 —— "文件存在"不等于"读得到"。
            NSDictionary *obj = [self settingsInDirectory:dir];
            e[@"settingsReadable"] = @(obj != nil);
            if (obj) {
                e[@"settingsKeyCount"] = @(obj.count);
                id mode = obj[@"proxyMode"];
                e[@"settingsProxyMode"] = [mode isKindOfClass:[NSString class]] ? mode : @"";
            }
        }
        NSString *cp = [dir stringByAppendingPathComponent:LCProxyConfFile];
        e[@"confExists"] = @([fm fileExistsAtPath:cp]);
        [perDir addObject:e];
    }

    // 复现 load 的决策过程（只读，不做任何补偿性写入）。
    NSDictionary *canonicalRaw = [self settingsInDirectory:canonical];
    NSDictionary *fallbackRaw = [self newestFallbackSettings];
    NSString *source = @"defaults";
    NSMutableArray *trail = [NSMutableArray array];
    if (canonicalRaw) {
        source = @"canonical";
        [trail addObject:@"权威目录存在 settings.json，直接使用它"];
    } else if (fallbackRaw) {
        source = @"fallback(mtime-newest)";
        [trail addObject:@"权威目录没有 settings.json，回退到修改时间最新的其它目录副本"];
    } else {
        [trail addObject:@"任何目录都没有可解析的 settings.json → 使用内置默认值（王卡模式下这是致命混淆点）"];
    }

    NSDictionary *effectiveSettings = [self load];
    // 上次保存结果与写入方用同一把 @synchronized 读取，避免看到半更新的组合。
    NSTimeInterval saveAt; NSUInteger saveBytes; NSString *saveErr; NSArray *savePerDir;
    @synchronized (self) {
        saveAt = self.lastSaveAt;
        saveBytes = self.lastSaveBytes;
        saveErr = self.lastSaveError ?: @"";
        savePerDir = self.lastSavePerDirectory ?: @[];
    }
    NSDictionary *result = @{
        @"canonicalDirectory": canonical ?: @"",
        @"settingsPath": [self settingsPath] ?: @"",
        @"confPath": [self proxychainsConfPath] ?: @"",
        @"source": source,
        @"trail": trail,
        @"directories": perDir,
        @"effectiveProxyMode": [effectiveSettings[@"proxyMode"] isKindOfClass:[NSString class]]
                                ? effectiveSettings[@"proxyMode"] : @"",
        @"effectiveKingTypeName": [effectiveSettings[@"kingTypeName"] isKindOfClass:[NSString class]]
                                ? effectiveSettings[@"kingTypeName"] : @"",
        @"effectiveMccmnc": [effectiveSettings[@"kingMccmnc"] isKindOfClass:[NSString class]]
                                ? effectiveSettings[@"kingMccmnc"] : @"",
        @"lastSaveAt": @(saveAt),
        @"lastSaveBytes": @(saveBytes),
        @"lastSaveError": saveErr,
        @"lastSavePerDirectory": savePerDir,
    };
    return result;
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
    // 崩溃加固：本方法会在构造器路径（applyToRuntime → dispatch_sync）、主线程通知回调、
    // 以及串行 runtimeQueue 上运行。ObjC 异常一旦穿透 dispatch_sync / GCD 边界就会终止
    // 进程；构造器路径上更是 dylib 初始化阶段崩溃 = "一打开就闪退"。
    //
    // 注入式 tweak 的最高优先级是"绝不弄崩宿主"：这一步失败只是代理不生效
    // （fail-closed，绝不直连），而进程必须活着。
    @try {
        [self applyRuntimeSnapshotUnsafe:s effectiveMode:effectiveMode forceRecovery:forceRecovery];
    } @catch (NSException *e) {
        NSLog(@"[LCProxy] applyRuntimeSnapshot exception (swallowed): %@: %@", e.name, e.reason);
        LCProxyRecordSwallowedException(@"applyRuntimeSnapshot", e);
    }
}

- (void)applyRuntimeSnapshotUnsafe:(NSDictionary *)s effectiveMode:(NSString *)effectiveMode forceRecovery:(BOOL)forceRecovery {
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

    // WebKit 的代理配置必须跟着转发器端口走，而且**不能挂在 needsRuntimeReload 上**：
    // 首次应用时若 canonical conf 写入失败（configReady == NO），needsRuntimeReload
    // 为假、下面那次 reload 不会发生，WebKit 就会一直停在启动时按 conf 装上的占位
    // 端口 127.0.0.1:18080（无人监听）。后果是原生 socket 经 override 走转发器一切
    // 正常，但 WKWebView（浏览器类 App 的几乎全部流量）网页加载全部失败 —— 表现为
    // "彻底无法联网"，且与线协议层无关、极难从转发器日志看出。
    // 这里独立跟踪端口并在变化时无条件重载，属于 fail-closed 安全操作：转发器没起来
    // 时端口为 0，重载会回退到 conf 的占位端口，绝不会退化为直连。
    if (self.lastWebkitAppliedPort != desiredForwarderPort) {
        self.lastWebkitAppliedPort = desiredForwarderPort;
        dispatch_async(dispatch_get_main_queue(), ^{
            livecontainer_reload_webkit_proxy();
        });
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

    // 按连接流量日志：默认开启，文件有滚动上限（约 2 MiB）。路径固定在本 App
    // 数据目录，开启时才会真正创建/追加。
    BOOL trafficLogging = [s[@"trafficLogging"] boolValue];
    kp_traffic_log_set_enabled(trafficLogging ? 1 : 0);
    if (trafficLogging) {
        NSString *dir = [self dataDirectory];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *trafficPath = [dir stringByAppendingPathComponent:@"traffic.log"];
        kp_traffic_log_set_path([trafficPath fileSystemRepresentation]);
    } else {
        kp_traffic_log_set_path(NULL);
    }

    // Always regenerate the canonical conf. In auto-direct mode the on-disk conf
    // transition can leave proxy_count at zero while proxychains is enabled.
    NSString *configPath = self.proxychainsConfPath;
    BOOL configPathChanged = !self.lastAppliedConfigPath ||
                             ![configPath isEqualToString:self.lastAppliedConfigPath];
    BOOL configWritten = [self writeProxychainsConf:s toDirectory:self.dataDirectory];
    // Also keep writable copies in every other data directory (private, guest
    // container, etc.) so a shared app can still find a valid config if the
    // canonical App Group copy is missing or not visible to the current process.
    for (NSString *dir in LCProxyAllDataDirectories()) {
        if ([dir isEqualToString:self.dataDirectory]) continue;
        [self writeProxychainsConf:s toDirectory:dir];
    }

    // C code cannot derive an App Group container from a private dylib path.
    // Pin it to the Foundation-resolved canonical file; an unwritable/missing
    // canonical file must stay closed instead of reviving a private fallback.
    BOOL wasConfigValid = lcproxy_control_get_config_valid();
    BOOL configReady = lcproxy_control_set_config_path(configPath.fileSystemRepresentation) && configWritten;
    if (!configReady) {
        lcproxy_control_set_config_valid(0);
    }

    // 端口**实际烘焙进代理链**的那一个（0 = 链里没有生效的 override）。
    // 与 desiredForwarderPort 比较即可发现"链指向别处"的静默故障。
    int appliedChainPort = lcproxy_control_get_applied_override_port();
    BOOL chainPortStale = (proxyActive || desiredForwarderPort > 0) &&
                          appliedChainPort != desiredForwarderPort;

    // Never reparse a stale file after a canonical write failed. A later
    // successful write must reload even when settings and port are unchanged.
    BOOL needsRuntimeReload = configReady && (forceRecovery || settingsChanged ||
                                              forwarderPortChanged || configPathChanged ||
                                              chainPortStale ||
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
            // 补救方式是**刷新凭证**，而不是强恢复。
            //
            // 理由：本方法只在 lastAppliedForwarderPort > 0（转发器在监听）时才被安排，
            // 而 performHealthCheck 的前置检查是 running && port > 0 && listen_fd_valid；
            // 因此探测失败时转发器**对象是健康的**，失败的是经它发往上游的 CONNECT 探测
            // （kp_probe_generate204 经本地转发器向 www.gstatic.com:80 发 CONNECT 再取
            // /generate_204），即上游/凭证问题。
            //
            // 而强恢复会执行 lcproxy_async_close_all() + shutdownActiveClients，把
            // **所有在飞连接**一起杀掉。于是一次（可能是偶发的）探测失败就变成一批用户
            // 可见的断连，这些失败又各自触发 C 层的取号重试 —— 与"强制刷新清空凭证"
            // 构成同一类正反馈雪崩。共享 App 并发高（实测 37 个并发客户端），最先踩中。
            //
            // 刷新凭证既针对真正的病因，又完全不打断正在服务的连接。
            // 走限频异步入口：健康检查可能因上游抖动被反复触发，绝不能让它变成风暴。
            [[LCProxyKing shared] requestBackgroundRefresh];
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
