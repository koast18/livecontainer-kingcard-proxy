#import "LCProxyKing.h"
#import "KPKIngCore.h"
#import "KPKQueenCore.h"
#import "LCProxyPaths.h"
#import "LCProxySharedLog.h"
#import "LCProxyConfig.h"
#import "LCProxyKingClient.h"
#import "Version.h"
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
// 被动刷新（转发失败触发）的最小间隔。见 requestBackgroundRefresh。
// 正常续期由 2 分钟主动定时器负责（提前 LCProxyKingRefreshLeadTime 续期），本路径只在
// "凭证提前失效 / 池内节点全挂"时兜底，因此 20s 足够及时，且把上游压力限制在 ≤3 次/分。
static const NSTimeInterval LCProxyKingMinRefreshInterval = 20.0;

// C 层回调：在**转发失败**时被调用（此前它已试完池内所有代理节点）。
//
// 必须同时满足三条硬约束，否则会变成灾难：
//
// ① **零阻塞** —— 本回调跑在 C 层 client 线程上（kp_forwarder_refresh →
//    fw->refresh_fn），而 kp_forwarder_refresh_retry 对每个失败请求最多重试 3 次、
//    client 线程上限 KP_FORWARDER_MAX_CLIENTS=64。任何阻塞式等待都会被放大：
//    20s × 3 次 × 最多 64 线程足以让进程被系统直接杀掉（实测：打开共享 App 即闪退）。
//
// ② **必须返回 -1，不能返回 0** —— C 层把 0 解释为"刷新成功，立刻用新凭证重试"：
//    kp_forwarder_refresh_retry 返回 0 后 kp_handle_client 会 `goto https_retry`
//    再跑**整整一轮**池内代理尝试（最多 4 个节点 × 每次 10s 连接 + 10s 接收）。
//    而我们的取号是**异步**的，那一轮时凭证池根本没变化，纯属浪费，最坏能占住
//    client 线程数十秒。返回 -1 表示"本次重试到此为止"：C 层最多做一次 500ms 退避
//    就回 502，代价可控且可预期。
//
// ③ **强限频** —— C 层把"连接失败"一律当成"凭证问题"，而共享 App 高并发下失败是
//    成批出现的；不加限制时每个失败连接都要一次取号（实测 1341 次、45 秒内 30 次
//    完整取号），把 client 线程全占满。限频统一在 requestBackgroundRefresh 内完成。
//
// 因此这里只做一件事：投递一个限频的异步刷新信号，然后立刻返回 -1。
// 当前这次连接会拿到 502，换来的是不雪崩、不闪退、也不浪费一整轮代理尝试；
// 真正的取号在后台队列完成，新凭证装入转发器后，后续连接自然恢复。
static int LCProxyKingRefreshHook(void *ctx) {
    LCProxyKing *king = (__bridge LCProxyKing *)ctx;
    [king requestBackgroundRefresh];
    return -1;
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
// 独立存活心跳：见 startLivenessHeartbeat / heartbeatTick。
@property (nonatomic, strong) dispatch_source_t livenessTimer;
@property (nonatomic, strong) dispatch_queue_t heartbeatQueue;
@property (nonatomic, assign) NSUInteger heartbeatHealCount;
@property (nonatomic, assign) NSUInteger heartbeatRepinCount;
// 链端口自愈：见 heartbeatTick 里"链里真正生效的端口必须等于转发器端口"的说明。
@property (nonatomic, assign) NSUInteger heartbeatChainRepairCount;
@property (nonatomic, assign) NSTimeInterval lastChainRepairRequestAt;
@property (nonatomic, assign) NSTimeInterval lastHeartbeatAt;
// 上次向共享日志写状态快照的时间；见 appendSharedStatusSnapshot。
@property (nonatomic, assign) NSTimeInterval lastSharedSnapshotAt;
@property (nonatomic, assign) void *forwarderPtr;
@property (nonatomic, strong) NSMutableDictionary *cachedCredentialState;
@property (nonatomic, strong) NSLock *cacheLock;
@property (nonatomic, copy) NSString *resolvedCredentialLogPath;
@property (nonatomic, assign) BOOL desiredForwarderRunning;
@property (nonatomic, assign) NSUInteger forwarderDiscardCount;
@property (nonatomic, assign) NSUInteger refreshArbitrationLossStreak;
@property (nonatomic, copy) NSString *lastForwarderLifecycle;
// 生命周期通知的限频时间戳；见 notifyForwarderLifecycle:。
@property (nonatomic, assign) NSTimeInterval lastLifecycleNotifyAt;
@property (nonatomic, copy) NSString *lastRefresh;
@property (nonatomic, copy) NSString *lastSource;
@property (nonatomic, copy) NSString *lastError;
@property (nonatomic, copy) NSString *lastDiagnostics;
@property (nonatomic, assign) BOOL lastRefreshSuccess;
@property (nonatomic, strong) dispatch_source_t refreshTimer;
@property (nonatomic, assign) BOOL refreshing;
// 用户通过控制台触发"重置凭证"时置位：本次刷新必须领全新身份，并忽略缓存状态。
// 见 resetSharedCredentialsAndRefresh。
@property (nonatomic, assign) BOOL newIdentityRequested;
// 上一次真正开始取号的时间戳。用于给被动刷新限频（见 requestBackgroundRefresh）。
@property (nonatomic, assign) NSTimeInterval lastRefreshStartedAt;
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
// leadTime = 0 表示"此刻是否仍可用"（装载缓存/判断能否继续服务时必须用这个）；
// leadTime = LCProxyKingRefreshLeadTime 表示"是否需要现在续期"（前瞻性判断）。
- (BOOL)stateHasFreshCredentials:(NSDictionary *)state
                matchingSettings:(NSDictionary *)settings
                        leadTime:(NSTimeInterval)leadTime;
- (NSArray<NSString *> *)validatedProxyPool:(id)value;
- (NSString *)credentialInputSignatureForSettings:(NSDictionary *)settings;
- (void)clearForwarderKingState;
- (void)requestBackgroundRefresh;
- (void)retireForwarder:(kp_forwarder *)fw;
- (void)healMissingForwarderDirectly;
- (void)startLivenessHeartbeat;
- (void)heartbeatTick;

// 把本进程的**紧凑状态快照**追加到 App Group 共享日志，供任何进程的控制台查看。
//
// 为什么必须这么做：/api/status 只能由抢到 19092 端口的那个进程提供，其他进程
// "保持无头" —— 于是**另一个进程的内部状态根本读不到**。排查"私有正常 / 共享不正常"
// 这种**跨进程对比**问题时，这等于瞎了一只眼：我此前从未拿到过一份私有进程的数据。
// 共享日志是唯一出路（与 kingRefreshLogShared / dylibLoadsTail 同一思路）。
- (void)appendSharedStatusSnapshot;
- (NSString *)credentialLogPath;
- (void)appendCredentialRecord:(NSDictionary *)record;
- (NSMutableDictionary *)newestValidRecordFromLog;
- (void)trimCredentialLogIfNeeded;
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
        _heartbeatQueue = dispatch_queue_create("com.liveproxy.king.heartbeat", DISPATCH_QUEUE_SERIAL);
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
        [self startLivenessHeartbeat];
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
// 因此有两条硬约束：
//   ① 绝不能在持有 self.lock 时同步发通知（observer 会回到 applyConfig）；
//   ② 必须限频 —— 若转发器持续无法启动，notify→apply→notify 会形成紧循环烧 CPU
//      （实测过 applyConfig 在无旧实例时会立刻重试，而重试又失败）。
// 限频下限取 5s，与看门狗的重试节奏一致。lastForwarderLifecycle 仍每次更新，
// 诊断信息不受限频影响。所有调用点都在 applyConfig 内、由 lifecycleLock 串行化，
// 因此 lastLifecycleNotifyAt 无需额外加锁。
static const NSTimeInterval LCProxyKingLifecycleNotifyMinInterval = 5.0;

- (void)notifyForwarderLifecycle:(NSString *)reason {
    self.lastForwarderLifecycle = reason ?: @"";
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - self.lastLifecycleNotifyAt < LCProxyKingLifecycleNotifyMinInterval) return;
    self.lastLifecycleNotifyAt = now;
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
    // 复用健康转发器：**即便 forceRestart 为真**，只要现有转发器仍在运行且监听 fd
    // 有效，就没有必要 teardown。
    //
    // forceRestart 的原始用途是清掉挂起/切网后残留的陈旧半开连接，而这一点已由
    // applyRuntimeSnapshot 在调用本方法**之前**完成的 lcproxy_async_close_all() +
    // shutdownActiveClients() 实现，与转发器对象本身无关。
    //
    // 而每次不必要的 teardown 都要走 kp_forwarder_stop → pthread_join（等 client
    // 线程退出，它们可能正卡在同步取号的网络等待里）。这条路径一旦不能及时返回，
    // 持有 lifecycleLock 的 runtime apply 就会被堵住，进而把整个串行 runtimeQueue
    // 连同 override 更新一起永久卡死——实测形态即 forwarderPort=0 而
    // proxyOverridePort 恒等于旧值、desiredForwarderRunning=true、
    // forwarderDiscardCount=0、lastForwarderLifecycle=""。
    //
    // 因此把"是否复用"的判据从"是否要求重启"改成"现役转发器是否真的健康"：
    // 健康就复用（并就地重装凭证），不健康才重建。这既消除了绝大部分 teardown
    // 窗口，也让每次切前后台/切网都不再中断转发。
    BOOL healthyRunning = shouldRun && self.forwarder != NULL &&
                          kp_forwarder_is_running(self.forwarder) == 1 &&
                          kp_forwarder_is_listening(self.forwarder) == 1;
    BOOL alreadyRunning = healthyRunning;
    if (alreadyRunning) {
        kp_forwarder *fw = self.forwarder;
        [self.lock unlock];
        BOOL settingsChanged = ![signature isEqualToString:self.lastSettingsSignature];
        if (settingsChanged) self.lastSettingsSignature = signature;
        // forceRestart 想清掉"挂起/切网后残留的陈旧半开连接"这一意图，在复用路径上
        // 通过 shutdown 现存 client/上游 fd 实现即可（只取 client_lock，与
        // lifecycleLock 的加锁顺序一致）；重建转发器对象并不是达成该意图的必要条件。
        if (forceRestart && fw) {
            kp_forwarder_shutdown_clients(fw);
        }
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
    //
    // v0.5.54 曾把这里改成"先启动新的、再原子替换、最后异步回收旧的"，以消除重建
    // 期间 self.forwarder 为 NULL 造成的 override 悬空窗口。但该改动与"签名 dylib 后
    // 控制台一打开就黑屏"同时出现，故整段撤回至本版本（0.5.53 的顺序，控制台已验证
    // 可用）。若将来重新引入，必须先拿到崩溃/卡死日志确认不是它引起的。
    oldForwarder = self.forwarder;
    self.forwarder = NULL;
    self.lastSettingsSignature = signature;
    self.desiredForwarderRunning = YES;
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

    [self.lock lock];
    // 创建/启动新转发器期间锁已释放，可能已有另一次 applyConfig 先装上了自己的
    // 转发器——只有那种情况才允许丢弃本次成果。设置略有出入是可接受的：下一次
    // applyConfig 会走 alreadyRunning 分支收敛签名并重新装载凭证。
    if (self.forwarder == NULL && self.desiredForwarderRunning) {
        self.forwarder = newForwarder;
        [self.lock unlock];
        [self loadCachedStateIntoForwarder];
        return;
    }

    self.forwarderDiscardCount++;
    [self.lock unlock];
    kp_forwarder_stop(newForwarder);
    kp_forwarder_free(newForwarder);
    [self notifyForwarderLifecycle:@"rebuild-discarded"];
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
//
// ⚠️ 注意：applyConfig 的重建顺序改动（0.5.54 的"先启动新的、再原子替换、最后异步
// 回收"）已于 0.5.56 撤回，因为它与"签名 dylib 后控制台一打开就黑屏"同时出现。
// 但本***回收***方法本身保留并被 healMissingForwarderDirectly 使用（紧急自愈时旧
// 转发器只弃用、不做任何可能阻塞的等待）。重新启用"重建顺序"改动前必须先拿到
// 崩溃/卡死日志确认病因。
- (void)retireForwarder:(kp_forwarder *)fw {
    if (!fw) return;
    dispatch_async(self.forwarderReaperQueue, ^{
        kp_forwarder_stop(fw);
        // stop 未完成时 kp_forwarder_free 会按契约故意泄漏（不 free），不会 UAF。
        kp_forwarder_free(fw);
    });
}

// 独立存活心跳。这是整套自愈机制里**唯一不依赖任何可能被堵住的队列/锁**的一环：
//   · 不经过 LCProxyConfig 的串行 runtimeQueue（它可能被卡住的 applyRuntimeSnapshot
//     永久占住）；
//   · 不取 lifecycleLock（同上）；
//   · 不依赖刷新定时器（applyConfig 一开头就会 stopRefreshTimer，卡死时它不会复活）。
//
// 每 LCProxyKingLivenessInterval 秒检查一次"王卡已启用时，已发布的 per-process
// proxy override 是否真的指向一个在监听的本地转发器"，不一致就**就地**修复：
//   · 转发器缺失/未监听  → 重建转发器并钉住新端口
//   · 转发器在跑但 override 指向别处 → 重新钉住 override 并让 C 层重解析配置
//
// 后者正是实测故障的核心形态：override 恒等于旧端口 53464，而该端口上已无监听者，
// 于是所有连接被拒 → "彻底无法联网"。
- (void)startLivenessHeartbeat {
    if (self.livenessTimer) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.heartbeatQueue);
    if (!timer) return;
    uint64_t interval = (uint64_t)(LCProxyKingLivenessInterval * NSEC_PER_SEC);
    // 首次延迟一个周期，避免与构造期的 applyToRuntime 抢跑。
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval,
                              (uint64_t)(1 * NSEC_PER_SEC));
    __weak LCProxyKing *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf heartbeatTick];
    });
    dispatch_resume(timer);
    self.livenessTimer = timer;
}

- (void)heartbeatTick {
    self.lastHeartbeatAt = [[NSDate date] timeIntervalSince1970];

    // 周期性把状态快照写进共享日志（让其他进程的控制台也能看到本进程）。
    // 放在最前面：即使转发器缺失、后面提前 return，本进程的状态也必须可见 ——
    // 恰恰是"出问题的进程"最需要被看到。
    {
        NSTimeInterval now = self.lastHeartbeatAt;
        if (now - self.lastSharedSnapshotAt >= LCProxyKingSharedSnapshotMinInterval) {
            self.lastSharedSnapshotAt = now;
            [self appendSharedStatusSnapshot];
        }
    }

    // 只读内存状态，**不做任何磁盘/配置读取** —— 本方法每 5 秒跑一次，必须足够省。
    // desiredForwarderRunning 由 applyConfig 在王卡模式启用时置位，语义与
    // "王卡已启用" 等价，因此无需每 5 秒重新解析 settings.json。
    [self.lock lock];
    BOOL shouldRun = self.desiredForwarderRunning;
    [self.lock unlock];
    if (!shouldRun) return;

    int port = [self localForwarderPort];
    if (port <= 0 || ![self isRunning]) {
        self.heartbeatHealCount++;
        [self appendSharedRefreshLogEntry:@{
            @"ok": @NO,
            @"src": @"heartbeat-heal",
            @"ms": @0,
            @"msg": [NSString stringWithFormat:@"转发器缺失，心跳触发直接自愈 (port=%d)", port],
        }];
        [self healMissingForwarderDirectly];
        return;
    }

    // 转发器在跑：确认 override 真的指向它。
    char host[256];
    int overridePort = 0;
    int hasOverride = lcproxy_control_get_proxy_override(host, sizeof(host), &overridePort);
    if (!hasOverride || overridePort != port) {
        self.heartbeatRepinCount++;
        lcproxy_control_set_proxy_override("127.0.0.1", port);
        lcproxy_control_reload_config();
        [self appendSharedRefreshLogEntry:@{
            @"ok": @YES,
            @"src": @"heartbeat-repin",
            @"ms": @0,
            @"msg": [NSString stringWithFormat:@"override %d -> %d（转发器实际端口）", overridePort, port],
        }];
        NSLog(@"[LCProxyKing] heartbeat repinned override %d -> %d", overridePort, port);
    }

    // 心跳不催取号，但**必须**校验"链里真正生效的端口"。
    //
    // 先说为什么不催取号：心跳只做它独有、别人做不到的事（发现转发器缺失/override 失配/
    // 链端口失配并就地修好）。凭证续期已由两条路径覆盖 —— 2 分钟主动定时器，以及
    // "连接失败 → C 层回调 → requestBackgroundRefresh（限频 20s、走 force 分支）"。
    // 而 requestBackgroundRefresh 会**绕过缓存命中判断**，若心跳调用它，稳态下就变成
    // 每 20 秒一次完整网络取号（3 次/分、180 次/小时），纯属无谓。
    //
    // 为什么这条检查不可省：lcproxy_control_apply_proxy_override 只在
    // lcproxy_control_reload_config 内部被调用，而重载只在 needsRuntimeReload 为真时发生。
    // 稳态下它不再重跑，于是链里烘焙的端口**再也没有人校验**。一旦它与当前转发器端口
    // 不一致（重载失败、链被清空、apply 被丢弃），所有连接都会打到别处（例如 conf 里
    // 无人监听的占位端口 18080）→ 彻底无法联网，而 /api/status 里 proxyOverridePort
    // 依然显示"正确"，lastError 为空，完全看不出问题。
    //
    // 之前该故障只能靠"碰巧来一次前台/切网事件触发 apply"才可能恢复。现在改成每 5 秒
    // 主动校验并请求一次重载，形成自愈闭环。
    //
    // 限频：requestRuntimeApplyAsync 会重写多份配置文件，绝不能每 5 秒来一次。
    int chainPort = lcproxy_control_get_applied_override_port();
    [self.lock lock];
    BOOL routeOk = self.routePublished;
    [self.lock unlock];
    // ★ 路由"未发布"同样必须自愈 —— 这是后台/熄屏后整体断网的成因。
    //
    // applyRuntimeSnapshot 开头会 beginRoutePublication（routePublished=NO），结尾只在
    // `configReady && (!proxyActive || config_valid)` 成立时才 publishRouteForSettings 把它
    // 置回 YES。若这个条件不成立，routePublished 就**停在 NO 且没有任何自愈路径**：
    //   · syncFetchGuid 直接失败（错误串就是实测日志里的"王卡本地路由尚未发布"）；
    //   · 而 publishRouteForSettings 的失败分支还会 stopRefreshTimer，主动续期也停了；
    //   · 0.5.62 起心跳又不再催促取号 —— 于是一次后台切换就能把进程锁死在断网状态。
    // 这里补上兜底：转发器健康却没发布路由 → 请求一次 apply（限频），把它救回来。
    if (!routeOk || chainPort != port) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - self.lastChainRepairRequestAt >= LCProxyKingChainRepairMinInterval) {
            self.lastChainRepairRequestAt = now;
            self.heartbeatChainRepairCount++;
            [self appendSharedRefreshLogEntry:@{
                @"ok": @NO,
                @"src": @"heartbeat-chain-repair",
                @"ms": @0,
                @"msg": [NSString stringWithFormat:@"路由自检失败（routePublished=%d，链端口 %d，转发器 %d），请求重载配置",
                         routeOk ? 1 : 0, chainPort, port],
            }];
            NSLog(@"[LCProxyKing] heartbeat: routePublished=%d chainPort=%d forwarder=%d, requesting runtime apply",
                  routeOk ? 1 : 0, chainPort, port);
            [[LCProxyConfig shared] requestRuntimeApplyAsync];
        }
    }
}

// 紧急自愈：绕过 LCProxyConfig 的串行 runtimeQueue，直接重建转发器并就地钉住
// proxychains 的 per-process override。
//
// 只在"王卡已启用但转发器缺失"时使用。它存在的唯一理由是：applyRuntimeSnapshot
// 全程持有 lifecycleLock 且跑在 runtimeQueue（串行）上，只要它在 applyConfig 里被
// 任何无界等待卡住，整条常规 apply 路径就永久失效 —— 看门狗发出的
// requestRuntimeApplyAsync 会排在被堵队列后面，永远轮不到，系统无法自愈。
// 本方法因此在被堵队列之外完成"新建转发器 + 更新 override + 重载 C 配置"，
// 从而无论 applyConfig 因何卡住都能恢复联网。
//
// 安全性：
//  · 仅在 !isRunning 时调用，正常运行路径完全不受影响；
//  · 旧转发器**不做任何可能阻塞的等待**，直接弃用并交给回收队列（0.5.57 起 accept
//    循环有界等待，其线程 ≤500ms 自行退出，故回收不会长期占住队列）；
//  · 重复调用安全：开头复查 isRunning，已被别人修好就直接返回。
- (void)healMissingForwarderDirectly {
    if ([self isRunning]) return;

    kp_forwarder *fw = kp_forwarder_new("127.0.0.1", 0, "", 0);
    if (!fw) return;
    kp_forwarder_set_refresh_hook(fw, LCProxyKingRefreshHook, (__bridge void *)self);
    if (kp_forwarder_start(fw) != 0) {
        kp_forwarder_free(fw);
        return;
    }
    int port = kp_forwarder_port(fw);
    if (port <= 0) {
        kp_forwarder_stop(fw);
        kp_forwarder_free(fw);
        return;
    }

    [self.lock lock];
    if (self.forwarder != NULL) {
        // 期间已有别人装上转发器：丢弃本次成果，避免两个实例并存。
        [self.lock unlock];
        [self retireForwarder:fw];
        return;
    }
    kp_forwarder *old = self.forwarder;
    self.forwarder = fw;
    self.desiredForwarderRunning = YES;
    [self.lock unlock];

    [self retireForwarder:old];

    // 直接钉住 override 并让 C 层按新端口重解析配置 —— 不等 runtimeQueue。
    lcproxy_control_set_proxy_override("127.0.0.1", port);
    lcproxy_control_reload_config();
    [self loadCachedStateIntoForwarder];

    [self.lock lock];
    self.lastError = @"";
    self.lastRefresh = LCProxyKingNow();
    [self.lock unlock];
    NSLog(@"[LCProxyKing] emergency heal: forwarder rebuilt on port %d", port);
    [self appendSharedRefreshLogEntry:@{
        @"ok": @YES,
        @"src": @"emergency-heal",
        @"ms": @0,
        @"msg": [NSString stringWithFormat:@"绕过 runtimeQueue 直接重建转发器 port=%d", port],
    }];
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
    published = isKingRoute && port > 0 && kp_forwarder_is_listening(fw) == 1;
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

// 用户可触发：丢弃共享凭证库里的缓存状态，重新领一整套全新凭证。
//
// 动机：凭证库位于 App Group，被所有进程共享。若最新那条记录对运营商已失效（或被某个
// 进程写坏），则每个读它的进程都会拿坏凭证去连、被运营商零字节关闭 —— 而自己重新领一套
// 的进程却正常。这正好能造成"私有正常、共享不正常"。该动作把 newIdentityRequested 置位
// 并立即强制刷新，刷新完成后新记录成为日志里最新的一条，其他进程也会随之用上。
- (void)resetSharedCredentialsAndRefresh {
    [self.lock lock];
    self.newIdentityRequested = YES;
    [self.lock unlock];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self refreshCredentialsForce];
    });
}

- (void)refreshCredentialsAsync {    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self refreshCredentials];
    });
}

// 被动刷新入口，由 C 层转发失败回调（LCProxyKingRefreshHook）触发。
//
// 特点：**零阻塞 + 限频 + 异步**。它是整套取号逻辑里唯一的"按需"入口，因此必须
// 足够克制 —— 否则一次网络抖动就会变成取号风暴（实测 1341 次取号、45 秒内 30 次
// 完整取号），把 client 线程耗尽并导致闪退。
//
//   · 已有取号在飞 → 直接返回，不排队、不等待、不阻塞调用线程。
//   · 距上次取号不足 LCProxyKingMinRefreshInterval → 直接返回。
//   · 允许时才把真正的取号丢到后台队列执行，调用线程立即返回。
//
// 真正的取号过程绝不会先清空在用凭证（见 refreshCredentialsWithForce:），
// 因此在它完成之前，转发仍可用旧凭证继续服务。
- (void)requestBackgroundRefresh {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    [self.lock lock];
    BOOL busy = self.refreshing;
    BOOL tooSoon = self.lastRefreshStartedAt > 0 &&
                   (now - self.lastRefreshStartedAt) < LCProxyKingMinRefreshInterval;
    [self.lock unlock];
    if (busy || tooSoon) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self refreshCredentialsForce];
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
    // leadTime:0 —— 只判"此刻是否还能用"。距过期还有 1 分钟的凭证现在完全可用，若按
    // 2 分钟余量判为不可用而清空代理池，就把"即将降级"变成"立刻全断"，且要等下一次取号
    // 成功才恢复。转发器 fail-closed 绝不直连，所以用旧凭证最坏只是被上游拒绝。
    if (![self stateHasFreshCredentials:state matchingSettings:settings leadTime:0]) {
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
    return [self stateHasFreshCredentials:state
                        matchingSettings:settings
                                leadTime:LCProxyKingRefreshLeadTime];
}

// leadTime 的语义：要求凭证在**未来 leadTime 秒内**仍然有效。
//
// 两种用法必须区分开，混用会造成"提前清空"这一类自伤：
//   · leadTime = LCProxyKingRefreshLeadTime(2 分钟)：用于判断"是否需要现在就去续期"
//     （isReady、是否需要主动刷新），是**前瞻性**判断。
//   · leadTime = 0：用于判断"这批凭证**此刻**还能不能用"。装载缓存到转发器时必须用
//     这个 —— 距过期还有 1 分钟的凭证**此刻完全可用**，若按 2 分钟余量判为不可用而
//     清空代理池，就等于把"即将降级"变成"立刻全断"（且要等到下一次取号成功才恢复）。
//     转发器本身是 fail-closed（绝不直连），所以用旧凭证最坏只是被上游拒绝，不会
//     绕过王卡通道、不会消耗通用流量。
- (BOOL)stateHasFreshCredentials:(NSDictionary *)state
                matchingSettings:(NSDictionary *)settings
                        leadTime:(NSTimeInterval)leadTime {
    NSString *guid = [state[@"guid"] isKindOfClass:[NSString class]] ? state[@"guid"] : nil;
    NSString *token = [state[@"token"] isKindOfClass:[NSString class]] ? state[@"token"] : nil;
    NSString *qkey = [state[@"key"] isKindOfClass:[NSString class]] ? state[@"key"] : nil;
    NSString *qua2 = [state[@"qua2"] isKindOfClass:[NSString class]] ? state[@"qua2"] : nil;
    NSArray *queenHttp = [state[@"queen_http"] isKindOfClass:[NSArray class]] ? state[@"queen_http"] : nil;
    NSArray *queenHttps = [state[@"queen_https"] isKindOfClass:[NSArray class]] ? state[@"queen_https"] : nil;
    NSString *inputSignature = [state[@"credentialInputSignature"] isKindOfClass:[NSString class]] ? state[@"credentialInputSignature"] : nil;
    if (!LCProxyKingHexStringValid(guid) || !token.length || !qkey.length || !qua2.length) return NO;
    // 注意：**不要**因为 guidSource=local 就拒绝这条记录。
    // 本地 GUID 是启动引导阶段（路由尚未发布、PBProxy 必然失败）的既定回退，删掉它会让
    // 冷启动彻底取不到凭证 —— 那是 commit ec37444 明确修复过的问题。我曾在 v0.5.74 误加
    // 这条拒绝，已撤回。它只作为诊断字段暴露（见 status 的 guidSource）。
    if (![inputSignature isEqualToString:[self credentialInputSignatureForSettings:settings]]) return NO;
    NSArray *validHttp = [self validatedProxyPool:queenHttp];
    NSArray *validHttps = [self validatedProxyPool:queenHttps];
    if ((!queenHttp.count && !queenHttps.count) || validHttp.count != queenHttp.count || validHttps.count != queenHttps.count) return NO;

    double now = [[NSDate date] timeIntervalSince1970];
    NSNumber *tokenExpireEpoch = [state[@"tokenExpireEpoch"] isKindOfClass:[NSNumber class]] ? state[@"tokenExpireEpoch"] : nil;
    NSNumber *proxyExpireEpoch = [state[@"proxyExpireEpoch"] isKindOfClass:[NSNumber class]] ? state[@"proxyExpireEpoch"] : nil;
    if (!tokenExpireEpoch || tokenExpireEpoch.doubleValue <= now + leadTime) return NO;
    if (!proxyExpireEpoch || proxyExpireEpoch.doubleValue <= now + leadTime) return NO;
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
static const NSUInteger LCProxyKingSharedStatusLogMaxLines = 120;
// 存活心跳周期：见 startLivenessHeartbeat。
static const NSTimeInterval LCProxyKingLivenessInterval = 5.0;
// 向 App Group 共享日志写"本进程状态快照"的最小间隔。见 appendSharedStatusSnapshot。
static const NSTimeInterval LCProxyKingSharedSnapshotMinInterval = 30.0;
// 心跳请求"重载配置以修复代理链端口"的最小间隔。apply 会重写多份配置文件，
// 因此即使链端口持续不一致，也最多每 20 秒修一次。见 heartbeatTick。
static const NSTimeInterval LCProxyKingChainRepairMinInterval = 20.0;

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
    LCProxySharedLogTrim([self credentialLogPath], LCProxyKingCredentialLogMaxLines);
}

// 通用的"追加式日志裁剪"：超过上限就把后半段留下、前半段丢掉。写入失败静默忽略
// ——这些日志纯属诊断，任何 IO 问题都不能影响转发。
// 把一行紧凑的取号记录追加到 App Group 共享日志文件，让任何 LiveContainer 实例
// 的控制台都能看到本进程的取号历史 —— 共享 App 进程的内部状态此前完全不可见
// （文件应用看不到 App Group，console 又只能读到自己的进程）。
// 追加/裁剪的实现已抽到 LCProxySharedLog（见该文件关于"尽力而为"语义的说明）；
// 这里只负责把记录**规范化**成固定字段。
- (void)appendSharedRefreshLogEntry:(NSDictionary *)entry {
    NSString *dir = [[self credentialLogPath] stringByDeletingLastPathComponent];
    if (!dir.length) return;
    NSDictionary *compact = @{
        @"ts": [entry[@"ts"] isKindOfClass:[NSNumber class]] ? entry[@"ts"] : @([[NSDate date] timeIntervalSince1970]),
        @"pid": @(getpid()),
        @"ok": [entry[@"ok"] isKindOfClass:[NSNumber class]] ? entry[@"ok"] : @NO,
        @"src": [entry[@"src"] isKindOfClass:[NSString class]] ? entry[@"src"] : @"",
        @"ms": [entry[@"ms"] isKindOfClass:[NSNumber class]] ? entry[@"ms"] : @0,
        @"msg": [entry[@"msg"] isKindOfClass:[NSString class]] ? entry[@"msg"] : @"",
    };
    LCProxySharedLogAppendLine(dir, @"kingcard-refresh.log",
                               LCProxyKingSharedRefreshLogMaxLines, compact);
}

// 把本进程的紧凑状态快照追加到 App Group 共享日志 kingcard-status.log。
//
// 存在的唯一理由：/api/status 只能由抢到 19092 端口的进程提供，其余进程"保持无头" ——
// 于是**别的进程的内部状态根本读不到**。排查"私有正常 / 共享不正常"这类**跨进程对比**
// 问题时，这等于只有一只眼：此前始终拿不到一份私有进程的现场数据，只能靠推断。
//
// 记录内容刻意只含**判定所必需的字段**（端口/链端口、池大小、上游分步计数、最后一次
// 失败的现场与请求结构快照），不含任何凭证。同为 O_APPEND 行级追加、无锁、失败静默。
- (void)appendSharedStatusSnapshot {
    NSString *dir = [[self credentialLogPath] stringByDeletingLastPathComponent];
    if (!dir.length) return;

    [self.lock lock];
    int fwdPort = self.forwarder ? kp_forwarder_port(self.forwarder) : 0;
    BOOL running = self.forwarder != NULL && kp_forwarder_is_running(self.forwarder) == 1;
    BOOL listenOk = self.forwarder ? (kp_forwarder_listen_fd_valid(self.forwarder) == 1) : NO;
    kp_forwarder *fw = self.forwarder;
    BOOL ready = self.lastRefreshSuccess;
    NSString *err = self.lastError ?: @"";
    [self.lock unlock];

    char ovHost[64] = {0};
    int ovPort = 0;
    if (!lcproxy_control_get_proxy_override(ovHost, sizeof(ovHost), &ovPort)) ovPort = 0;

    kp_forwarder_stats stats;
    memset(&stats, 0, sizeof(stats));
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"ts"] = @([[NSDate date] timeIntervalSince1970]);
    d[@"pid"] = @(getpid());
    d[@"bundle"] = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    d[@"ver"] = [NSString stringWithUTF8String:KPTWEAK_VERSION];
    d[@"isSharedTweaks"] = @([LCProxyDylibPath() containsString:@"/LiveContainer/Tweaks/"]);
    d[@"home"] = NSHomeDirectory() ?: @"";
    d[@"port"] = @(fwdPort);
    d[@"chainPort"] = @(lcproxy_control_get_applied_override_port());
    d[@"overridePort"] = @(ovPort);
    d[@"running"] = @(running);
    d[@"listenOk"] = @(listenOk);
    d[@"ready"] = @(ready);
    d[@"vErr"] = err.length > 80 ? [err substringToIndex:80] : err;

    if (fw) {
        kp_forwarder_get_stats(fw, &stats);
        d[@"pool"] = @[@(stats.live_http_pool), @(stats.live_https_pool)];
        d[@"connects"] = @(stats.https_connects);
        d[@"reject"] = @(stats.client_rejections);
        d[@"poolEmpty"] = @(stats.pool_empty);
        d[@"clients"] = @([self activeClientCount]);
        d[@"up"] = @{
            @"connectFail": @(stats.up_connect_fail),
            @"sendFail": @(stats.up_send_fail),
            @"recvFail": @(stats.up_recv_fail),
            @"recvEof": @(stats.up_recv_eof),
            @"recvRst": @(stats.up_recv_rst),
            @"recvTimeout": @(stats.up_recv_timeout),
            @"credCode": @(stats.up_cred_code),
            @"otherCode": @(stats.up_other_code),
            @"tunnelNoData": @(stats.up_tunnel_no_data),
            @"fakeOk": @(stats.up_fake_ok),
            @"lastStage": [NSString stringWithUTF8String:stats.last_up_stage] ?: @"",
            @"lastProxy": [NSString stringWithUTF8String:stats.last_up_proxy] ?: @"",
            @"lastCode": @(stats.last_up_code),
            @"lastErrno": @(stats.last_up_errno),
            @"lastResp": [NSString stringWithUTF8String:stats.last_up_resp] ?: @"",
            @"req": [NSString stringWithUTF8String:stats.last_creq] ?: @"",
        };
    }

    LCProxySharedLogAppendLine(dir, @"kingcard-status.log",
                               LCProxyKingSharedStatusLogMaxLines, d);
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
        // leadTime:0 —— 这里要挑的是"**此刻仍然可用**的最新一条记录"，不是"是否该续期"。
        // 若用 2 分钟余量：凭证有效期的最后 2 分钟内，最新记录会被跳过；而更旧的记录
        // 过期更早、同样被跳过 → loadState 返回 nil → 装载缓存时清空代理池。每个凭证
        // 周期都会出现一次这样的"提前全断"窗口，且要等下一次取号成功才恢复。
        if (![self stateHasFreshCredentials:obj matchingSettings:settings leadTime:0]) continue;
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
                          kp_forwarder_is_listening(forwarder) == 1;
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
        // 合并并发刷新 —— **绝不阻塞调用方**。
        //
        // 本方法会被 C 层 client 线程经 refresh hook 调用
        // （KPKIngCore.c: kp_forwarder_refresh → fw->refresh_fn），而
        // kp_forwarder_refresh_retry 对每个失败请求最多重试 3 次，client 线程上限
        // KP_FORWARDER_MAX_CLIENTS=64。因此**任何阻塞式等待都会被急剧放大**：
        // 一次 20s 的等待 × 最多 64 个线程 × 每线程 3 次重试 = 大量线程长时间被占住，
        // 共享 App 高并发下足以让进程被系统直接杀掉（表现为一打开就闪退）。
        // v0.5.60 曾在此处实现 20s 阻塞等待，即为闪退来源，已彻底移除。
        //
        // 现在立即返回 YES（语义：已有刷新在飞，无需再试）：
        //   · hook 返回 0 → C 层不再重试该请求 → 取号风暴被掐断；
        //   · 零阻塞 → 不再有任何线程被占住；
        //   · 等待者不会拿到"失败"，因此不会各自放大成新的强制取号。
        // 在飞的刷新完成后会把新凭证装进转发器，后续连接自然恢复。
        return YES;
    }
    self.refreshing = YES;
    self.lastRefreshStartedAt = [[NSDate date] timeIntervalSince1970];
    [self.lock unlock];
    // ★ 强制刷新**不得**先清空正在服务的凭证。原实现在此处调用
    // clearForwarderKingState（已移除，勿再加回）：它会在取号所需的网络往返
    // （实测 1.1~2.1s）期间让转发器**没有任何凭证**，于是一批本来能成功的连接也一起
    // 失败，而每个失败又触发新的强制刷新（再次清空）→ 正反馈雪崩。
    // 实测形态完全吻合：转发器对象健康（running=true / listenFdValid=1 /
    // forwarderPort 与 proxyOverridePort 一致）、取号次次成功（refreshLog 全为
    // ok:true）、却什么都转发不出去，且 lastRefreshSuccess 因清空而恒为 false。
    // 共享 App 并发高，因此最先、最重地踩中它；私有 App 并发低，通常波及不到。
    //
    // 现在改为"先用旧凭证继续服务，取到新凭证后覆盖"。只有当旧凭证确实不可用时
    // （finishRefreshWithState 里的 freshness 检查）才清空，且那是最后手段。
    //
    // 注意：三个上游获取点都用 force 作为强制条件
    // （!guidOverride && (force || !guid)、token 缓存分支的 !force、代理池的
    // force || 过期），因此去掉清空**不影响**强制重新取号的语义。

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
        // 常规路径：请求一次 runtime apply（正常时由它重建并更新 override）。
        [[LCProxyConfig shared] requestRuntimeApplyAsync];
        // 兜底路径：**不依赖 LCProxyConfig 的串行 runtimeQueue**。
        // 之所以需要它：applyRuntimeSnapshot 全程持有 lifecycleLock，一旦它在
        // applyConfig 里被某个无界等待（例如旧转发器 stop 的 pthread_join）卡住，
        // runtimeQueue 上后续每一次 apply 都会永久排队。此时常规路径发出的
        // requestRuntimeApplyAsync 同样永远轮不到，看门狗每 5s 触发也救不回来 ——
        // 表现为"彻底断网且永不恢复"，且 override 永远停在旧端口。
        // 本方法在被堵的队列之外直接重建转发器并就地钉住 override，因此无论
        // applyConfig 因为什么原因卡住，系统都能自愈。
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self healMissingForwarderDirectly];
        });
        [self scheduleRefreshRetryAfter:5.0];
        return NO;
    }

    NSMutableDictionary *state = [self loadState];
    // 用户触发的"重置凭证"：丢弃一切缓存状态，本次必须重新领 GUID + Q-Token + 代理池。
    // 注意：steps 在下面才声明，所以这里只置标志，稍后再写日志。
    BOOL didResetCredentials = NO;
    {
        [self.lock lock];
        BOOL wantNew = self.newIdentityRequested;
        if (wantNew) self.newIdentityRequested = NO;   // 一次性
        [self.lock unlock];
        if (wantNew) {
            state = [NSMutableDictionary dictionary];
            force = YES;
            if (!settings) settings = [self settingsSnapshot];
            didResetCredentials = YES;
        }
    }
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
    if (didResetCredentials) {
        [steps appendString:@"重置: 用户触发，丢弃缓存凭证并重新领取\n"];
    }
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
    // ★ 是否重新向运营商申请 GUID 身份，**不能**由 force 决定。
    //
    // 原实现在 guidOverride 为空时，只要 force 为真或没有缓存 guid 就重新申请 ——
    // 于是一次连接失败触发的强制刷新就会去领一个全新身份。这在共享 App 场景下会形成
    // 自我维持的"身份互相作废"：
    //   · 凭证日志在 App Group 里被**所有** LiveContainer 进程共享（0.5.47 起刻意去掉了
    //     跨进程锁），而共享 App 必然与启动它的 LiveContainer 进程、控制台等同时存在；
    //   · 每个进程各自独立强制刷新、各自领一个新 GUID；
    //   · 若运营商对同一张 SIM 只保留一个有效身份，则每次领新身份都会**作废其他进程
    //     （以及自己上一次）的身份**；
    //   · 身份一失效，连接就失败 → 又触发强制刷新 → 又领新身份 → 循环。
    // 实测形态完全吻合：上游 TCP 连得上、请求发得出，然后**一个字节都不回就关闭**
    // （recvFail 1224 次、lastResp 为空），而 connectFail/sendFail 全为 0。
    //
    // 正确语义：**只有服务端明确说"凭证不行"（820/821/823，由 C 层置位）时才换身份**；
    // 没有身份时当然要申请。单纯"连接失败"不构成换身份的理由 —— 那多半正是别人换过
    // 身份造成的。
    BOOL credsRejected = NO;
    {
        // self.forwarder 在别处一律持锁访问；这里也照做，避免指针撕裂。
        [self.lock lock];
        kp_forwarder *fwForFlag = self.forwarder;
        [self.lock unlock];
        credsRejected = kp_forwarder_take_credential_rejection(fwForFlag) ? YES : NO;
    }
    if (credsRejected) {
        [steps appendString:@"身份: 服务端拒绝凭证(820/821/823)，重新申请 GUID\n"];
    }
    if (!guidOverride && (!guid || credsRejected)) {
        NSError *guidErr = nil;
        guid = [self syncFetchGuid:qua2 timeout:timeout error:&guidErr];
        if (!guid) {
            // ★ 保留本地 GUID 作为**启动引导回退** —— 这是刻意的，不要删除。
            //
            // 历史依据（commit ec37444 "…restore GUID fallback"）：取号可能发生在
            // **路由发布之前**，而 PBProxy GetGuid 本身要走转发器的引导隧道，因此在那个
            // 窗口里它必然失败。若此时直接判失败，就会"一个凭证都拿不到"（当年实测的
            // 症状）。所以这里生成一个本地 GUID 先走通 token/代理池的获取流程。
            //
            // ⚠️ 我曾在 v0.5.74 把这段回退删掉、并拒绝 guidSource=local 的记录，那是**错误的
            // 过度修正**，已撤回：它会让启动阶段彻底取不到凭证。
            //
            // 但仍然要把它**标记**出来（guidSource=local），并且把"路由未发布"这个真正的原因
            // 修掉（心跳自愈）。因为本地 GUID 运营商并不认识：带着它去转发时对端会直接关闭
            // 连接；而凭证库是跨进程共享的，所以它只应作为短暂引导，不应成为长期身份。
            [steps appendFormat:@"GUID: PBProxy 失败 %@\n", guidErr.localizedDescription ?: @""];
            guid = [self localRandomGuid];
            source = @"guid-local";
            [steps appendFormat:@"GUID: 本地生成（服务器失败 %@）\n", guidErr.localizedDescription ?: @""];
        } else {
            source = @"guid-pbprx";
            actuallyFetchedUpstream = YES;
            [steps appendString:@"GUID: PBProxy 获取\n"];
            state[@"guidSource"] = @"pbproxy";
        }
        state[@"guid"] = guid;
        if (!state[@"guidSource"]) state[@"guidSource"] = @"local";
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
                               matchingSettings:[self settingsSnapshot]
                                       leadTime:0]) {
        // 确实没有任何**此刻还能用**的凭证才清空转发器（fail-closed，但绝不直连）。
        //
        // leadTime:0 是必须的：取号失败本身不该导致断网 —— 只要手上凭证此刻仍有效，
        // 就继续用它服务，等下一次取号成功再换。若按 2 分钟余量判为"不可用"而清空，
        // 一次取号失败就会把可用状态打成全断（这正是 v0.5.60 那类正反馈的形态）。
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
        d[@"poolEmpty"] = @(stats.pool_empty);
        // 此刻转发器内实际的代理节点数：池为 0 就是"清空型"故障的直接证据。
        d[@"liveHttpPool"] = @(stats.live_http_pool);
        d[@"liveHttpsPool"] = @(stats.live_https_pool);
        d[@"clientRejections"] = @(stats.client_rejections);
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
    // 当前生效凭证的 GUID 来源：pbproxy（运营商下发，可用）/ local（启动引导回退，
    // 运营商不认，仅应短暂存在）/ 空（旧记录）。它能一眼区分"身份是假的"这类故障。
    // 必须在取 self.lock **之前**读（loadState 用 cacheLock，锁序不允许嵌套）。
    NSString *guidSourceText = [state[@"guidSource"] isKindOfClass:[NSString class]] ? state[@"guidSource"] : @"";
    [self.lock lock];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"running"] = @([self isRunning]);
    d[@"forwarderPort"] = @(self.forwarder ? kp_forwarder_port(self.forwarder) : 0);
    d[@"activeForwarderClients"] = @(self.forwarder ? kp_forwarder_active_clients(self.forwarder) : 0);
    d[@"listenFdValid"] = @(self.forwarder ? kp_forwarder_listen_fd_valid(self.forwarder) : 0);
    // ★ 真·监听检查：实际 connect 一次 listen_port。
    // listenFdValid 只看 fd 号 —— 后台/熄屏会让 socket 失效而 fd 依旧 >= 0，于是它恒为 1，
    // 这正是"切后台后永久断网"此前无法从 status 看出的原因。本字段才是真相。
    {
        [self.lock lock];
        kp_forwarder *fwForProbe = self.forwarder;
        [self.lock unlock];
        d[@"listenProbeOk"] = @(fwForProbe ? kp_forwarder_is_listening(fwForProbe) : 0);
    }
    d[@"lastHealthCheckOk"] = @(self.lastHealthCheckOk);
    d[@"lastHealthCheckAt"] = @(self.lastHealthCheckAt);
    d[@"lastRefreshSuccess"] = @(self.lastRefreshSuccess);
    d[@"lastRefresh"] = self.lastRefresh ?: @"";
    d[@"lastSource"] = self.lastSource ?: @"";
    d[@"lastError"] = self.lastError ?: @"";
    d[@"guidSource"] = guidSourceText;
    // 路由是否已发布：为 0 时 syncFetchGuid 会直接失败、主动续期定时器被停掉。
    // 这是"切后台/熄屏后整体断网"链路里的关键一环，此前没有暴露。
    d[@"routePublished"] = @(self.routePublished);
    d[@"publishedForwarderPort"] = @(self.publishedForwarderPort);
    d[@"lastDiagnostics"] = self.lastDiagnostics ?: @"";
    d[@"desiredForwarderRunning"] = @(self.desiredForwarderRunning);
    d[@"forwarderDiscardCount"] = @(self.forwarderDiscardCount);
    d[@"refreshArbitrationLossStreak"] = @(self.refreshArbitrationLossStreak);
    d[@"lastForwarderLifecycle"] = self.lastForwarderLifecycle ?: @"";
    d[@"heartbeatHealCount"] = @(self.heartbeatHealCount);
    d[@"heartbeatRepinCount"] = @(self.heartbeatRepinCount);
    d[@"heartbeatChainRepairCount"] = @(self.heartbeatChainRepairCount);
    d[@"lastHeartbeatAt"] = @(self.lastHeartbeatAt);
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
        // 决定性判据：连接到达时代理池为空的次数。
        d[@"statPoolEmpty"] = @(stats.pool_empty);
        // 此刻池内实际节点数（0 = 清空型故障正在发生）。
        d[@"liveHttpPool"] = @(stats.live_http_pool);
        d[@"liveHttpsPool"] = @(stats.live_https_pool);
        // 并发槽位耗尽被拒的次数：转发器"一慢就全拒"的直接证据。
        d[@"statClientRejections"] = @(stats.client_rejections);
        // 上游失败**分步**诊断：把"连接失败"拆成 5 条出口 + 最后一次失败的现场。
        // 没有它就只能盲猜"为什么连不上"（转发器这边既无 errno、也无非 2xx）。
        d[@"upstreamDiag"] = @{
            @"connectFail": @(stats.up_connect_fail),
            @"sendFail": @(stats.up_send_fail),
            @"recvFail": @(stats.up_recv_fail),
            @"credCode": @(stats.up_cred_code),
            @"otherCode": @(stats.up_other_code),
            @"tunnelNoData": @(stats.up_tunnel_no_data),
            @"fakeOk": @(stats.up_fake_ok),
            @"pickFail": @(stats.up_pick_fail),
            @"lastStage": [NSString stringWithUTF8String:stats.last_up_stage] ?: @"",
            @"lastProxy": [NSString stringWithUTF8String:stats.last_up_proxy] ?: @"",
            @"lastCode": @(stats.last_up_code),
            @"lastErrno": @(stats.last_up_errno),
            @"lastResp": [NSString stringWithUTF8String:stats.last_up_resp] ?: @"",
            @"lastTunnelClientToUp": @(stats.last_tunnel_client_to_up),
            @"lastTunnelUpToClient": @(stats.last_tunnel_up_to_client),
            @"lastTunnelMs": @(stats.last_tunnel_ms),
            // 零字节响应的三种成因：EOF(对端干净关闭) / RST(硬重置) / 超时。
            @"recvEof": @(stats.up_recv_eof),
            @"recvRst": @(stats.up_recv_rst),
            @"recvTimeout": @(stats.up_recv_timeout),
            // 我们实际发出的请求长什么样（结构快照，无凭证明文）。
            // 长度本身就是诊断：例如 Q-Token(0) 直接说明凭证是空的。
            @"lastRequest": [NSString stringWithUTF8String:stats.last_creq] ?: @"",
        };

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
