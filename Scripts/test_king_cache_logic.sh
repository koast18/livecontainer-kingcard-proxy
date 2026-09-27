#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN=python3
else
    PYTHON_BIN=python
fi
"$PYTHON_BIN" - <<'PY'
from pathlib import Path
import re

king = Path('Tweak/Sources/LCProxyKing.m').read_text(encoding='utf-8')
control = Path('Tweak/Sources/LCProxyControl.m').read_text(encoding='utf-8')
config = Path('Tweak/Sources/LCProxyConfig.m').read_text(encoding='utf-8')
core = Path('Tweak/Sources/KPKIngCore.c').read_text(encoding='utf-8')
client = Path('Tweak/Sources/LCProxyKingClient.m').read_text(encoding='utf-8')

# Preemptive refresh lead time must exist.
assert 'LCProxyKingRefreshLeadTime = 2 * 60;' in king, \
    'missing LCProxyKingRefreshLeadTime constant'

# `hasFreshCachedState` must gate the startup/foreground refresh decision.
assert 'lcproxy_stats_is_cellular' not in king, 'LCProxyKing must not use the old cellular stats judge'
assert 'effectiveProxyModeForSettings' in king, 'LCProxyKing must use effective mode'
assert 'hasFreshCachedState' in king, 'missing hasFreshCachedState'
assert re.search(r'if\s*\(!\s*\[self\s+hasFreshCachedState\]\s*\)', king), \
    'applyConfig does not skip refresh when fresh cache exists'

# Background refresh helper must exist so startup/foreground refreshes do not block.
assert 'refreshCredentialsAsync' in king, 'missing refreshCredentialsAsync'

# Timer must schedule based on the earliest token/proxy expiry.
assert 'earliestExpiry' in king, 'missing preemptive timer scheduling'

# ---------------------------------------------------------------------------
# 凭证存取 = 进程内缓存 + 追加式共享日志。**没有跨进程锁、没有租约、没有围栏**。
# Q-Token 有效期 2 小时、代理池 8 小时，跨进程仲裁换不来任何东西，只会在多
# LiveContainer 场景下制造持续断网。这里固化"简单方案"的全部不变量。
# ---------------------------------------------------------------------------

# The whole arbitration machinery must be gone, not just bypassed.
for gone in (
    'acquireStateLocks', 'releaseStateLocks', 'stateLockPaths', 'stateInDirectory',
    'acquireRefreshLeaseWithForce', 'renewRefreshLeaseForOwnerID',
    'startRefreshLeaseHeartbeatForOwnerID', 'renewActiveRefreshLeaseForOwnerID',
    'stopRefreshLeaseHeartbeat', 'commitRefreshState', 'LCProxyKingCommitResult',
    'LCProxyKingLeaseResult', 'refreshLeaseOwner', 'refreshLeaseGeneration',
    'refreshLeaseExpiresAt', 'refreshLeaseHeartbeat', 'refreshLeaseValid',
    'refreshInvalidatingGeneration', 'baseUpdatedAt', 'baseUpdatedAt:baseUpdatedAt',
    'scheduleRefreshRetryAfterLockContention', 'kingcard-state.json',
    'kingcard-state.lock', 'LCProxyKingRefreshLeaseTTL', 'canonicalState',
    'newestFallbackState', 'saveState:',
):
    assert gone not in king, f'arbitration machinery still present: {gone}'

# The append-only credential log is the only cross-process artifact.
assert 'NSString *const LCProxyForwarderLifecycleChangedNotification =' in king, \
    'forwarder lifecycle notification has no definition (linker error)'
# 生命周期通知必须限频：转发器持续无法启动时 notify→apply→notify 会形成紧循环烧 CPU
# （observer 会立刻重跑 runtime apply，而 applyConfig 在无旧实例时会马上重试）。
assert 'LCProxyKingLifecycleNotifyMinInterval' in king, \
    'forwarder lifecycle notification is not rate limited (notify/apply spin risk)'
assert re.search(r'if \(now - self\.lastLifecycleNotifyAt < LCProxyKingLifecycleNotifyMinInterval\) return;', king), \
    'lifecycle notification rate-limit check is missing'
assert 'kingcard-credentials.log' in king, 'missing append-only credential log path'
assert 'O_WRONLY | O_APPEND | O_CREAT' in king, 'credential log writes are not append-only'
assert 'appendCredentialRecord:' in king, 'missing append-only record writer'
assert 'newestValidRecordFromLog' in king, 'missing newest-valid-record reader'
assert 'LCProxyKingCredentialLogMaxLines = 64;' in king, 'credential log is not size capped'
assert 'trimCredentialLogIfNeeded' in king, 'credential log is never trimmed'
# A corrupted or truncated line must be skipped, never fatal.
assert 'if (![NSJSONSerialization isValidJSONObject:stored]) return;' in king, \
    'unserializable record aborts instead of falling back to memory'
assert re.search(r'if \(!\[obj isKindOfClass:\[NSDictionary class\]\]\) continue;', king), \
    'a corrupt log line is not skipped'
# A refreshLog (UI-only history) must not bloat every persisted record.
assert 'removeObjectForKey:@"refreshLog"' in king, 'UI refresh log is persisted per record'

# 取号历史必须跨进程可见：共享 App 进程的内部状态此前完全不可见（App Group 在
# 文件应用里看不到，而 console 只能读到自己的进程）。追加到 canonical 目录的
# kingcard-refresh.log 后，任意实例的控制台都能读到全部进程的取号历史。
assert 'kingcard-refresh.log' in king, 'missing cross-process refresh log'
assert 'appendSharedRefreshLogEntry:' in king, 'refresh log entries are not shared across processes'
assert 'LCProxyKingSharedRefreshLogMaxLines' in king, 'shared refresh log is not size capped'
assert 'trimAppendLogAtPath:' in king, 'append-only logs are never trimmed'
assert '[self appendSharedRefreshLogEntry:entry];' in king, \
    'pushRefreshLog does not publish to the cross-process refresh log'
server = Path('Tweak/Sources/LCProxyServer.m').read_text(encoding='utf-8')
assert 'kingRefreshLogShared' in server and 'trafficLogTail' in server, \
    '/api/status does not expose the cross-process refresh/traffic logs'
assert 'tailOfAppGroupLog:' in server, 'no shared-log tail reader in the console server'
# "共享 App 到底加载了哪个版本的 dylib" 必须有据可查：App Group 在文件应用里
# 看不到，而每个进程的状态只反映自己。加载事实写入共享日志后，任意控制台都能
# 确认修复是否真的生效。
assert 'LCProxyRecordDylibLoad' in control and 'dylib-loads.log' in control, \
    'dylib load is not recorded to the shared App Group log'
assert 'dylibLoadsTail' in server, '/api/status does not expose dylib load records'

# ⚠️ 构造器**不得**加"重复映像就让位"的守卫。
#
# LiveContainer 的 TweakLoader 会加载 Tweaks 目录里的每一个 dylib，升级期新旧两份
# 确实可能共存（实测同一 pid 先后加载了 0.5.57 与 0.5.56）。但**让位比重复更危险**：
# 每一份 dylib 都有自己独立的一套 C 层全局变量（proxychains 链、per-process override
# 端口、fishhook 后的 connect）。两份的 C 构造函数都会各自执行（不受 ObjC 层控制），
# 后加载者通常赢下 connect 的符号解析；若让位的那份不执行
# lcproxy_control_set_proxy_override，它生效的 hook 就会回落到 conf 里的占位端口
# 127.0.0.1:18080（无人监听）→ **全部连接被拒**，把"能用但浪费"变成"彻底断网"。
assert 'NSClassFromString(@"LCProxyConfig")' not in control, \
    'a duplicate-image bail-out guard is back (risks a hard offline: override never set)'
assert 'registeredConfig' not in control, \
    'a duplicate-image bail-out guard is back (risks a hard offline: override never set)'
# 移除守卫后，构造器首行副作用必须仍然是"记录加载事实"。
_ctor = control[control.index('static void LCProxyControlConstructor(void) {'):]
assert _ctor.index('LCProxyRecordDylibLoad();') < _ctor.index('[[LCProxyConfig shared] load]'), \
    'the constructor no longer records the dylib load before applying settings'

# Persistence is best-effort: if the log is unwritable the process must keep
# working purely in memory rather than failing closed for a write problem.
store_start = king.index('- (NSString *)credentialLogPath {')
store_end = king.index('- (NSMutableDictionary *)newestValidRecordFromLog {', store_start)
store = king[store_start:store_end]
assert 'resolved = [local stringByAppendingPathComponent:@"kingcard-credentials.log"];' in store, \
    'credential log must fall back to the dylib-derived directory'
assert 'if (!local.length) return nil;' in store, \
    'unwritable credential storage must degrade to in-memory operation'
assert 'open(path.fileSystemRepresentation' in store, 'append must use a raw O_APPEND write'
assert 'close(fd);' in store, 'append leaves the log file descriptor open'

# Deadlock regression guard: self.lock critical sections must never call into
# cacheLock-protected helpers. v0.5.47's console-save hang was exactly this:
# status held self.lock while loadState (newly cache-backed) re-took it.
_lock_depth = 0
_lock_start = None
_forbidden = ('[self loadState]', '[self credentialLogPath]', '[self appendCredentialRecord:',
              '[self newestValidRecordFromLog]', '[self trimCredentialLogIfNeeded]',
              '[self trimAppendLogAtPath:', '[self appendSharedRefreshLogEntry:')
for _i, _line in enumerate(king.split('\n'), 1):
    if '[self.lock lock]' in _line:
        _lock_depth += 1
        if _lock_depth == 1:
            _lock_start = _i
    if '[self.lock unlock]' in _line and _lock_depth > 0:
        _lock_depth -= 1
        if _lock_depth == 0:
            _lock_start = None
    if _lock_depth > 0 and _lock_start is not None:
        for _f in _forbidden:
            assert _f not in _line, \
                f'lock-order deadlock risk at line {_i} (self.lock section from {_lock_start}): {_f}'

# loadState prefers the in-process cache and only reads the log as a seed.
load_start = king.index('- (NSMutableDictionary *)loadState {')
load_end = king.index('// ---------------------------------------------------------------------------', load_start)
load = king[load_start:load_end]
assert 'self.cachedCredentialState' in load and 'newestValidRecordFromLog' in load, \
    'loadState does not prefer the in-process cache over the shared log'

# Failure must not clear still-valid credentials: a lost race or a transient
# write error must never escalate into a total outage.
fin_start = king.index('- (BOOL)finishRefreshWithState:')
fin_end = king.index('- (BOOL)performHealthCheck {', fin_start)
fin = king[fin_start:fin_end]
assert 'appendCredentialRecord:state' in fin, 'successful refresh is not persisted'
assert re.search(r'if \(success\) \{', fin), 'finishRefresh does not branch on success'
clear_at = fin.index('clearForwarderKingState')
guard_at = fin.index('stateHasFreshCredentials:[self loadState]')
assert guard_at < clear_at, \
    'a failed refresh clears the forwarder without checking for still-valid credentials'
assert 'scheduleRefreshRetryAfter:15.0' in fin, 'a failed refresh does not retry with backoff'

# Cached-credential validity must not depend on any cross-process marker.
fresh_start = king.index('- (BOOL)stateHasFreshCredentials:(NSDictionary *)state matchingSettings:')
fresh_end = king.index('- (BOOL)stateHasFreshCredentials:(NSDictionary *)state {', fresh_start)
freshness = king[fresh_start:fresh_end]
for key in ('@"guid"', '@"qua2"', '@"token"', '@"key"', '@"queen_http"', '@"queen_https"',
            '@"tokenExpireEpoch"', '@"proxyExpireEpoch"', '@"credentialInputSignature"'):
    assert key in freshness, f'freshness check ignores {key}'
assert 'refreshInvalidatingGeneration' not in freshness, \
    'freshness still consults a removed cross-process poison flag'

# Fail-closed routing is unchanged: no credentials means drop, never direct.
assert 'kp_forwarder_clear_king_state' in king, 'stale forwarder state is not cleared'

# ⚠️ 强制刷新**不得**先清空正在服务的凭证。
# 原先断言的是 "if (force) [self clearForwarderKingState];" —— 那条断言把**错误行为**
# 固化了。清空会让取号所需的网络往返（实测 1.1~2.1s）期间转发器没有任何凭证，一批本
# 可成功的连接随之失败，而每个失败又触发新的强制刷新（再次清空）→ 自我维持的雪崩：
# 转发器健康、取号次次成功，却什么都转发不出去（实测 forwarderPort/listenFdValid
# 正常、refreshLog 全为 ok:true、lastRefreshSuccess 却恒为 false、refreshCalls=1341）。
# 共享 App 并发高，最先且最重地踩中；私有 App 并发低，通常波及不到。
assert 'if (force) [self clearForwarderKingState];' not in king, \
    'a forced refresh still clears live credentials before fetching replacements (avalanche)'

# 被动刷新（C 层转发失败回调）必须 **零阻塞 + 限频 + 异步**，且**返回 -1**。
# 回调跑在 C 层 client 线程上（kp_forwarder_refresh），而 kp_forwarder_refresh_retry
# 对每个失败请求最多重试 3 次、client 线程上限 64 —— 任何阻塞式等待都会被放大成
# "20s × 3 × 64 线程"，足以让进程被系统杀掉（实测：打开共享 App 即闪退）。
# 同时 C 层把"连接失败"一律当成"凭证问题"，共享 App 高并发下失败成批出现，
# 不加限频就会打出取号风暴（实测 1341 次取号 / 45 秒内 30 次完整取号）。
#
# 返回值必须是 -1（不是 0）：C 层把 0 解释为"刷新成功，立刻用新凭证重试"，
# kp_forwarder_refresh_retry 返回 0 后 kp_handle_client 会 goto https_retry 再跑
# **整整一轮**池内代理尝试（最多 4 节点 × (10s 连接 + 10s 接收)）。我们的取号是异步的，
# 那一轮时凭证池并未变化，纯属浪费，最坏占住 client 线程数十秒。
assert 'LCProxyKingMinRefreshInterval' in king, 'passive refresh is not rate limited'
_hook = king[king.index('static int LCProxyKingRefreshHook'):king.index('static void LCProxyKingLog')]
assert 'requestBackgroundRefresh' in _hook, \
    'the C refresh hook does not delegate to the non-blocking async path'
assert 'return -1;' in _hook, \
    'the C refresh hook returns 0, which makes the C layer re-run a whole extra proxy round'
assert 'return 0;' not in _hook, \
    'the C refresh hook must not claim success (that triggers a guaranteed-wasted retry round)'
assert 'refreshCredentials' not in _hook, \
    'the C refresh hook performs the refresh inline (blocks a client thread)'

# 回调恒返回 -1 之后，C 层的重试循环永远不可能成功，必须只尝试一次。
# 原为 (3,500)/(2,300)：多试一次就让 client 线程多占一个退避周期（最多 1000ms），
# 高并发下直接加剧线程占用（这正是闪退的资源来源）。
assert re.findall(r'kp_forwarder_refresh_retry\(fw, (\d+), (\d+)\)', core) == [('1', '0')] * 3, \
    'a kp_forwarder_refresh_retry call site still retries an always-failing async hook'
for _old in ('kp_forwarder_refresh_retry(fw, 3, 500)', 'kp_forwarder_refresh_retry(fw, 2, 300)'):
    assert _old not in core, f'wasted synchronous retry loop still present: {_old}'
_rbr = king[king.index('- (void)requestBackgroundRefresh {'):]
_rbr = _rbr[:_rbr.index('\n}\n') + 3]
assert 'NSThread sleepForTimeInterval' not in _rbr, \
    'requestBackgroundRefresh blocks the calling thread'
assert 'dispatch_async' in _rbr, 'requestBackgroundRefresh does not run the fetch off-thread'
assert 'self.lastRefreshStartedAt' in _rbr and 'tooSoon' in _rbr, \
    'requestBackgroundRefresh is not rate limited'
assert 'self.lastRefreshStartedAt = [[NSDate date] timeIntervalSince1970];' in king, \
    'the refresh start timestamp is never recorded (rate limit would never trigger)'
# 任何地方都不得再出现阻塞式等待取号结果的循环（0.5.60 的闪退来源）。
assert 'LCProxyKingRefreshCoalesceTimeout' not in king, \
    'the blocking coalesce wait is back (crashes the app under load)'
assert re.search(r'if \(self\.refreshing\) \{\s*\[self\.lock unlock\];', king), \
    'an in-flight refresh no longer short-circuits cheaply'

# 清空仍然必须存在（无凭证时 fail-closed），只是不再发生在强制刷新的开头。
assert king.count('[self clearForwarderKingState]') >= 2, \
    'clearForwarderKingState was removed entirely (no fail-closed path left)'

# ⚠️ leadTime 的两种语义必须分开，混用会造成"提前清空"这一类自伤。
#
# LCProxyKingRefreshLeadTime(2 分钟) 是**前瞻性**判断："是否该现在续期"。
# 而"这批凭证此刻还能不能用"必须是 leadTime:0 —— 距过期还有 1 分钟的凭证现在完全
# 可用；若按 2 分钟余量判为不可用，就会在**每个凭证有效期的最后 2 分钟**里清空代理池
# （loadState 挑不到记录 → 装载缓存时清空），把"即将降级"变成"立刻全断"。
# 转发器 fail-closed 绝不直连，所以继续用旧凭证最坏只是被上游拒绝。
assert 'leadTime:(NSTimeInterval)leadTime' in king, \
    'stateHasFreshCredentials has no leadTime parameter (prospective vs usable conflated)'
# 三处"此刻是否可用"的调用点必须显式传 0。
assert king.count('matchingSettings:settings leadTime:0') >= 2, \
    'loadState/loadCachedStateIntoForwarder do not use leadTime:0 (premature pool clearing)'
assert 'matchingSettings:[self settingsSnapshot]\n                                       leadTime:0' in king, \
    'the refresh-failure path does not use leadTime:0 (one failed fetch can still kill a live pool)'
# 前瞻性调用点必须保留默认余量（不得被改成 0，否则永远不会提前续期）。
assert re.search(r'if \(!force && state\.count && \[self stateHasFreshCredentials:state matchingSettings:settings\]\)', king), \
    'the refresh cache-hit fast path lost its prospective (lead-time) check'

# 决定性诊断计数器：连接到达时代理池为空的次数。
# 这是区分两类"完全无法联网"的唯一可靠指标：
#   高 → 完全没有可用凭证/池（凭证被清空或从未装载）——曾由强制刷新开头清空导致，
#        其特征是 stat_refresh_calls / stat_https_connects ≈ 重试次数（池为空时
#        for 循环体一次都不执行、直接落到刷新）；
#   为 0 而连接仍失败 → 池内有节点但都被拒（上游/凭证失效），是另一类问题。
assert 'stat_pool_empty' in core, 'the pool-empty diagnostic counter is missing'
assert core.count('kp_stat_increment(&fw->stat_pool_empty)') == 2, \
    'pool-empty is not counted on both the HTTP and HTTPS connection paths'
assert 'uint64_t pool_empty;' in Path('Tweak/Sources/KPKIngCore.h').read_text(encoding='utf-8'), \
    'pool_empty is not exposed in kp_forwarder_stats'
assert 'stats->pool_empty = __atomic_load_n(&fw->stat_pool_empty' in core, \
    'pool_empty is not populated by kp_forwarder_get_stats'
assert 'd[@"statPoolEmpty"]' in king, '/api/status does not expose statPoolEmpty'
# 实时池大小：直接回答"现在池子是不是空的"，比累计计数器更直观。
assert 'int live_http_pool;' in Path('Tweak/Sources/KPKIngCore.h').read_text(encoding='utf-8'), \
    'live pool size is not exposed in kp_forwarder_stats'
assert re.search(r'pthread_mutex_lock\(&fw->cred_mutex\);\s*stats->live_http_pool = fw->http_pool\.count;', core), \
    'live pool size is not read under cred_mutex'
assert 'd[@"liveHttpPool"]' in king and 'd[@"liveHttpsPool"]' in king, \
    '/api/status does not expose the live pool size'

# Latency probing must stay capped so a refresh cannot stall for tens of seconds.
assert 'KP_LATENCY_PROBE_MAX' in king, 'sequential latency probing is not capped'
latency_sort_start = king.index('- (NSArray<NSString *> *)proxiesSortedByLatency:')
latency_sort_end = king.index('- (NSString *)localRandomGuid', latency_sort_start)
latency_sort = king[latency_sort_start:latency_sort_end]
assert latency_sort.count('tcpConnectMsForProxy:proxy') == 1, \
    'latency sort probes a proxy more than once'

# Credential bootstrap must not be gated on route publication.
refresh_start = king.index('- (BOOL)refreshCredentialsWithForce:')
assert 'if (!self.routePublished) {' not in king[refresh_start:king.index('- (BOOL)finishRefreshWithState:')], \
    'credential bootstrap is blocked before route publication'

# 自愈看门狗：applyConfig 的重建分支会先 stopRefreshTimer，若重建失败或被并发丢弃，
# 进程就既没有转发器也没有任何定时器/事件再触发 apply —— override 永久指向死端口
# （"彻底无法联网且永不恢复"）。refreshCredentials 必须在转发器缺失时主动请求重建
# 并安排一次有界重试。
refresh = king[refresh_start:king.index('- (BOOL)finishRefreshWithState:', refresh_start)]
assert '[self isRunning]' in refresh and 'requestRuntimeApplyAsync' in refresh, \
    'refreshCredentials does not rebuild a missing forwarder (no self-heal watchdog)'
assert 'scheduleRefreshRetryAfter:5.0' in refresh, \
    'watchdog does not schedule a bounded retry after requesting a rebuild'
# 看门狗必须有一条**不依赖 runtimeQueue** 的兜底自愈：applyRuntimeSnapshot 全程持有
# lifecycleLock 且跑在串行 runtimeQueue 上，只要它在 applyConfig 里被任何无界等待
# 卡住，常规 apply 路径（含看门狗发出的 requestRuntimeApplyAsync）就永久排队，
# 表现为"彻底断网且永不恢复"。直接自愈在被堵队列之外新建转发器并就地钉住 override。
assert 'healMissingForwarderDirectly' in refresh, \
    'watchdog has no fallback heal independent of the (possibly wedged) runtimeQueue'
assert 'lcproxy_control_set_proxy_override("127.0.0.1", port)' in king, \
    'direct heal does not pin the proxy override to the new forwarder port'
assert 'lcproxy_control_reload_config()' in king, \
    'direct heal does not make the C layer re-read the pinned override'
_heal = king[king.index('- (void)healMissingForwarderDirectly {'):]
assert 'if ([self isRunning]) return;' in _heal, \
    'direct heal lacks the already-healthy guard (would churn forwarders)'
assert 'kp_forwarder_stop(old' not in _heal and 'kp_forwarder_free(old' not in _heal, \
    'direct heal blocks on the old forwarder (defeats the purpose of bypassing the wedge)'

# 【已撤回】转发器重建顺序（0.5.54 引入、0.5.56 撤回）
#
# 0.5.54 曾把重建改成"先启动新的、再原子替换、最后异步回收旧的"，以消除重建期间
# self.forwarder 为 NULL、而 ObjC 层上次发布的 override 仍指向已关闭旧端口的窗口
# （实测形态：forwarderPort=0 / running=false / proxyOverridePort=<旧端口> /
# desiredForwarderRunning=true）。但该改动与"签名 dylib 后控制台一打开就黑屏"
# 同时出现，且 0.5.53 的控制台经实测可用，故整段撤回至 0.5.53 的顺序。
#
# 因此这里不再断言异步退役；保留一条护栏：重建路径必须仍然是"先摘除引用 →
# 再 stop/free → 最后新建"，即与 0.5.53 一致。重新启用异步退役前，必须先拿到
# 崩溃/卡死日志确认病因（见 docs/SHARED-APP-PROXY-INVESTIGATION.md）。
apply_start = king.index('- (void)applyConfig:(NSDictionary *)settings effectiveMode:')
apply_cfg = king[apply_start:king.index('// 异步回收退役的转发器', apply_start)]
assert 'kp_forwarder_start(newForwarder)' in apply_cfg, \
    'applyConfig no longer (re)starts a forwarder'
assert 'kp_forwarder_stop(oldForwarder)' in apply_cfg, \
    'applyConfig no longer retires the previous forwarder'
assert apply_cfg.index('self.forwarder = NULL') < apply_cfg.index('kp_forwarder_start(newForwarder)'), \
    'applyConfig no longer detaches the old forwarder before starting the new one (0.5.53 ordering)'

# 健康转发器必须在强刷路径上被复用，而不是每次都 teardown。
# 每次不必要的 teardown 都要走 kp_forwarder_stop → pthread_join（等 client 线程，
# 它们可能卡在同步取号的网络等待里），一旦不能及时返回就会堵住持有 lifecycleLock
# 的 runtime apply，进而永久卡死整个串行 runtimeQueue 与 override 更新 —— 实测形态
# 即 forwarderPort=0 / proxyOverridePort 恒等于旧值 / desiredForwarderRunning=true /
# forwarderDiscardCount=0 / lastForwarderLifecycle=""。
assert 'BOOL healthyRunning = shouldRun && self.forwarder != NULL' in apply_cfg, \
    'applyConfig does not gate reuse on the forwarder actually being healthy'
assert 'kp_forwarder_listen_fd_valid(self.forwarder) == 1' in apply_cfg, \
    'reuse does not verify the listen fd is still valid'
assert '!forceRestart' not in apply_cfg, \
    'a forced restart still tears down a healthy forwarder (unneeded teardown window)'
assert 'kp_forwarder_shutdown_clients(fw);' in apply_cfg, \
    'forced restart no longer clears stale client sockets on the reuse path'

# 独立存活心跳：唯一不依赖 runtimeQueue / lifecycleLock / 刷新定时器的自愈环节。
# 它直接修"王卡已启用但 override 指向一个已无监听的端口"这一实测形态。
assert 'LCProxyKingLivenessInterval' in king, 'missing forwarder liveness heartbeat interval'
assert 'startLivenessHeartbeat' in king, 'liveness heartbeat is never started'
assert '[self startLivenessHeartbeat];' in king[king.index('- (instancetype)init {'):], \
    'liveness heartbeat is not started from init'
_hb = king[king.index('- (void)heartbeatTick {'):king.index('// 紧急自愈：绕过', king.index('- (void)heartbeatTick {'))]
assert 'lcproxy_control_get_proxy_override' in _hb, \
    'heartbeat does not verify the published override port'
assert 'lcproxy_control_set_proxy_override("127.0.0.1", port)' in _hb, \
    'heartbeat does not repin the override to the live forwarder port'
assert 'healMissingForwarderDirectly' in _hb, \
    'heartbeat does not heal a missing forwarder'
# 心跳不得取 lifecycleLock、也不得依赖 runtimeQueue（否则它自己就会被卡住的 apply
# 堵死，失去兜底意义）。
assert 'lifecycleLock' not in _hb, \
    'heartbeat takes lifecycleLock, so a wedged apply would block the safety net too'
assert 'runtimeQueue' not in _hb, \
    'heartbeat depends on the serial runtimeQueue it is meant to bypass'
# 心跳每 5s 跑一次，必须足够省：只读内存状态，不做磁盘/配置读取，且**不催取号**。
# 心跳只负责它独有的价值（发现转发器缺失/override 失配并就地修复）。凭证续期已由
# 2 分钟主动定时器与"连接失败回调（限频 20s）"覆盖；而 requestBackgroundRefresh 走
# force 分支会绕过缓存命中判断，若心跳调用它，稳态下就变成每 20s 一次完整网络取号。
assert 'hasFreshCachedState' not in _hb, \
    'heartbeat reads settings/credential state from disk every 5 seconds'
assert 'settingsSnapshot' not in _hb, \
    'heartbeat re-parses settings on every tick'
assert 'desiredForwarderRunning' in _hb, \
    'heartbeat does not use the in-memory kingcard-enabled flag'
assert '[self requestBackgroundRefresh]' not in _hb, \
    'heartbeat prods a forced (cache-bypassing) network refresh every tick'
# 但心跳**必须**校验"链里真正生效的端口"并限频自愈。
#
# apply_proxy_override 只在 reload_config 内部被调用，而重载只在 needsRuntimeReload 为真时
# 发生；稳态下它不再重跑，于是链里烘焙的端口**再也没人校验**。一旦它与转发器端口不一致
# （重载失败、链被清空、apply 被丢弃），所有连接都会打到别处（如 conf 里无人监听的占位
# 端口 18080）→ 彻底无法联网，而 status 里 proxyOverridePort 依然"正确"、lastError 为空。
assert 'lcproxy_control_get_applied_override_port' in _hb, \
    'heartbeat does not verify the port actually baked into the proxy chain'
assert 'LCProxyKingChainRepairMinInterval' in _hb, \
    'heartbeat chain repair is not rate limited (would rewrite conf files every tick)'
assert 'requestRuntimeApplyAsync' in _hb, \
    'heartbeat does not request the runtime apply that repairs a stale chain port'

# Explicit credentials always override remote refreshes, including forced ones.
assert '!guidOverride && (force || !guid)' in king, \
    'forced refresh can overwrite kingGuidOverride'
assert 'token = tokenOverride ?: tokInfo[@"token"]' in king, \
    'remote token can overwrite kingTokenOverride'
assert 'qkey = keyOverride ?: tokInfo[@"qkey"]' in king, \
    'remote key can overwrite kingKeyOverride'
assert '(tokenOverride != nil) != (keyOverride != nil)' in king, \
    'partial token/key overrides can be silently supplemented by the network'
assert 'GUID 配置覆盖必须是 32 位十六进制字符串' in king, \
    'invalid GUID override can reach the network instead of failing closed'
assert 'storedInputSignature' in king and 'proxyExpireEpoch' in king, \
    'changed credential inputs can retain a previous GUID-dependent proxy state'
assert 'state[@"guid"] = guid;' in king and 'state[@"token"] = token;' in king and 'state[@"key"] = qkey;' in king, \
    'configured overrides are not persisted into the committed snapshot'

# PBProxy GetGuid starts before Queen credentials exist. The forwarder may open
# exactly one direct TLS tunnel so the URLSession request cannot loop into its
# empty proxy pool; arbitrary CONNECT targets must remain on the Queen path.
assert 'static int kp_is_pbproxy_bootstrap_target' in core, \
    'missing limited PBProxy cold-start tunnel gate'
assert re.search(r'port == 443 && strcasecmp\(host, "pbprx\.qq\.com"\) == 0', core), \
    'PBProxy bootstrap route is not restricted to pbprx.qq.com:443'
bootstrap_gate = core.index('int bootstrap_target = kp_is_pbproxy_bootstrap_target')
queen_pool = core.index('int https_pool_count = 0', bootstrap_gate)
assert bootstrap_gate < queen_pool, 'PBProxy bootstrap still enters the Queen pool first'
assert 'bootstrap_direct ? 10000 : 8000' in core, \
    'PBProxy direct connection does not use the existing bypass socket path'
assert 'kp_request_has_proxy_authorization' in core, \
    'PBProxy bootstrap permit is not bound to a proxy-authenticated request'
assert '407 Proxy Authentication Required' in core, \
    'PBProxy bootstrap does not challenge unauthenticated CONNECT attempts'
assert 'pbproxy_bootstrap_authorization' in core, \
    'PBProxy bootstrap authorization nonce is not retained with the lease'
assert 'NSURLAuthenticationMethodHTTPProxy' not in client, \
    'PBProxy client uses a nonexistent proxy-authentication method constant'
assert 'protectionSpace.isProxy' in client and 'NSURLAuthenticationMethodHTTPBasic' in client, \
    'PBProxy client does not answer the local proxy Basic-authentication challenge'
guid_start = king.index('- (NSString *)syncFetchGuid:')
guid_end = king.index('- (NSDictionary *)syncFetchToken:', guid_start)
guid_fetch = king[guid_start:guid_end]
assert 'requestWindow = requestTimeout + 10.0' in guid_fetch and \
       'permitLifetime = requestWindow + LCProxyKingPBProxyBootstrapSetupAllowance' in guid_fetch, \
    'PBProxy permit does not cover the complete controlled request window'
assert 'timeout:requestTimeout' in guid_fetch and 'requestWindow * NSEC_PER_SEC' in guid_fetch, \
    'PBProxy task and caller wait do not share a bounded request deadline'
assert 'completionLock' in guid_fetch and 'requestClosed = YES;' in guid_fetch and 'if (requestClosed)' in guid_fetch, \
    'a late PBProxy completion can race with permit revocation after the request deadline'
smoke_test = Path('Scripts/queen_client_test.m').read_text(encoding='utf-8')
assert 'bootstrapProxyPassword:' in smoke_test, \
    'Queen client smoke test no longer matches the credential-bound GetGuid API'
assert 'case 820:' in core and 'case 821:' in core and 'case 823:' in core, \
    'Queen credential-refresh codes (820/821/823) no longer trigger a refresh path'
assert 'code == 822 || code == 824' in core, \
    'Queen 822/824 server-directed direct fallback was removed'
assert core.count('kp_forwarder_record_direct_host(fw, host);') == 3, \
    'direct-path log calls changed (expect HTTP+CONNECT fallback + PBProxy bootstrap)'

# accept 循环必须**有界等待**，不能无限期阻塞在 accept() 上。
# Darwin 下对监听 socket 的 shutdown() 返回 ENOTCONN、close() 也不唤醒 accept，
# 于是一旦没有新连接到来，kp_forwarder_stop 里的 pthread_join 会永久阻塞。而它是在
# applyRuntimeSnapshot → applyConfig 持有 lifecycleLock 时被调用的，后果是：
#   self.forwarder 已被置 NULL（forwarderPort=0 / running=false），上次发布的
#   proxy override 永远停在旧端口（所有连接被拒），且 runtimeQueue 上后续每一次
#   apply（看门狗每 5s / 前台恢复 / NWPath）全部堵死 → 彻底断网且永不恢复。
# 实测形态：forwarderPort=0 / proxyOverridePort=<旧端口，从不更新> /
# desiredForwarderRunning=true / forwarderDiscardCount=0 / lastForwarderLifecycle=""。
assert 'define KP_FORWARDER_ACCEPT_POLL_MS' in core, \
    'accept loop has no bounded wait (unbounded pthread_join can wedge applyConfig forever)'
_run_start = core.index('static void *kp_forwarder_run(void *arg) {')
# kp_forwarder_run 之后的下一个顶层定义是 kp_forwarder_new（kp_client_thread 在其之前）。
_run = core[_run_start:core.index('kp_forwarder *kp_forwarder_new(', _run_start)]
assert 'poll(&pfd, 1, KP_FORWARDER_ACCEPT_POLL_MS)' in _run, \
    'accept loop does not wait on the listen fd with a bounded poll timeout'
assert _run.index('poll(&pfd, 1, KP_FORWARDER_ACCEPT_POLL_MS)') < _run.index('accept(listen_fd'), \
    'accept() is called before the bounded poll wait'
# stop 必须"先 join 再 close"：不能在 accept 线程仍可能 poll/accept 该 fd 时就关掉它。
_stop_start = core.index('int kp_forwarder_stop(kp_forwarder *fw) {')
_stop = core[_stop_start:core.index('void kp_forwarder_free', _stop_start)]
assert _stop.index('pthread_join(fw->thread, NULL)') < _stop.index('KP_CLOSESOCK(listen_fd_to_close)'), \
    'listen fd is closed before the accept thread is joined'

# WebKit 代理安装必须是同步的、fail-closed 的：livecontainer_install_webkit_proxy 由
# C 构造函数调用，此时 ObjC 层还没设置 per-process override，KingCard 模式下只能拿到
# conf 里的占位端口 127.0.0.1:18080（无人监听）。绝不能为了"避免指向死端口"而跳过或
# 延后安装——那会让 WebKit 在启动窗口内退化为**直连**，消耗通用流量。
webkit = Path('Tweak/ProxyCore/src/webkit_proxy.m').read_text(encoding='utf-8')
_inst = webkit[webkit.index('void livecontainer_install_webkit_proxy(void)'):]
assert 'lc_apply_proxy_to_store(defaultStore);' in _inst, \
    'defaultDataStore is not configured at install time (startup window would go direct)'
assert 'dispatch_async' not in _inst, \
    'install must stay synchronous: deferring it lets WebKit go direct before the override exists'
assert 'fail-closed' in _inst, 'the fail-closed rationale at the install site was removed'

# 端口跟踪重载：WebKit 的配置必须跟着转发器端口走，且不能依赖 needsRuntimeReload。
# 首次应用时若 canonical conf 写入失败（configReady == NO），needsRuntimeReload 为假，
# WebKit 会一直停在占位端口——原生 socket 走 override 正常，但 WKWebView 网页全部
# 加载失败，正是"浏览器类 App 无法联网"的形态。
assert 'lastWebkitAppliedPort' in config, \
    'WebKit proxy config is not tracked against the live forwarder port'
assert re.search(r'if \(self\.lastWebkitAppliedPort != desiredForwarderPort\)[\s\S]{0,400}?'
                 r'livecontainer_reload_webkit_proxy\(\)', config), \
    'WebKit proxy is not reloaded unconditionally when the forwarder port changes'

# 自愈：链里**实际生效**的端口若与当前转发器端口不一致，必须触发一次重载。
# 这是"status 全绿却完全连不上"（连接被发到无人监听的占位端口）的唯一自动修复路径。
assert 'lcproxy_control_get_applied_override_port' in config, \
    'LCProxyConfig never compares the applied chain port against the forwarder port'
assert re.search(r'chainPortStale[\s\S]{0,120}?appliedChainPort != desiredForwarderPort', config), \
    'the applied-chain-port staleness check is missing or miscomputed'
assert re.search(r'needsRuntimeReload = configReady && \([\s\S]{0,400}?chainPortStale', config), \
    'a stale chain port does not force a runtime reload'
assert 'd[@"chainProxyPort"]' in server and 'd[@"chainPortMatches"]' in server, \
    '/api/status does not expose the port actually baked into the proxy chain'
assert 'heartbeatChainRepairCount' in king, \
    'the heartbeat chain-repair counter is not exposed in status'

# 健康检查失败时**不得**做强制恢复（它会 lcproxy_async_close_all +
# shutdownActiveClients，把所有在飞连接一起杀掉），而应走限频异步的凭证刷新。
# 该路径只在转发器于监听（port>0）时被安排，探测失败必然是上游/凭证问题，与转发器
# 对象无关；杀掉全部连接会把一次偶发探测失败放大成成批断连，而这些断连又各自触发
# C 层取号重试 —— 与"强制刷新清空凭证"同类的正反馈雪崩。
_hc = config[config.index('- (void)schedulePostRecoveryHealthCheck {'):]
_hc = _hc[:_hc.index('\n}\n') + 3]
assert 'enqueueRuntimeApplyForceRecovery' not in _hc, \
    'health-check failure still triggers a force recovery that kills all live connections'
assert 'requestBackgroundRefresh' in _hc, \
    'health-check failure does not request a (rate-limited) credential refresh'
assert '[LCProxyKing shared] refreshCredentialsForce]' not in _hc, \
    'health-check failure bypasses the rate limit'

# Foreground activation should not force a synchronous refresh on the main thread.
assert 'refreshCredentials' not in control, 'foreground notification still forces refresh'

# 文档与代码同步：真机验证清单里提到的每个 status 字段都必须真实存在于源码中，
# 且层级（顶层 vs king 内）必须与文档标注一致。
#
# 为什么需要这条守卫：验证清单是用户唯一要照做的东西，一旦字段名或层级写错，
# 用户会白找一遍甚至报回错数据 —— 而"减少反复验证的工作量"正是本次交付的目标。
# 之前就写错过一次（把顶层字段写成 king 内），因此固化为断言。
_verify = Path('docs/REAL-DEVICE-VERIFICATION.md')
if _verify.exists():
    _doc = _verify.read_text(encoding='utf-8')
    # (字段, 是否在 king 内)
    _documented = [
        ('chainPortMatches', False),
        ('chainProxyPort', False),
        ('forwarderPort', False),
        ('swallowedExceptions', False),
        ('kingRefreshLogShared', False),
        ('statRefreshCalls', True),
        ('statPoolEmpty', True),
        ('liveHttpPool', True),
        ('liveHttpsPool', True),
        ('heartbeatChainRepairCount', True),
        ('lastError', True),
    ]
    for _field, _in_king in _documented:
        assert _field in _doc, f'verification doc no longer documents {_field}'
        assert f'd[@"{_field}"]' in server or f'd[@"{_field}"]' in king, \
            f'verification doc documents a status field that no longer exists: {_field}'
        # 层级必须与文档一致：顶层字段在 server 的 configPayload，king 内字段在 LCProxyKing.status
        _owner_src = server if not _in_king else king
        assert f'd[@"{_field}"]' in _owner_src, \
            f'{_field} is documented at the wrong nesting level'
    # 顶层与 king 内必须分别有文档小节，避免再次混淆层级。
    # 用容错正则：文档里可能带 Markdown 加粗（**顶层**）。
    assert re.search(r'顶层[^\n]{0,8}`chainPortMatches`', _doc), \
        'verification doc lost the explicit top-level path'
    assert re.search(r'`king` 内', _doc), \
        'verification doc lost the explicit king-nested path'

# ★ 重新申请 GUID 身份**不得**由 force 触发（共享 App 下会造成身份互相作废）。
#
# 凭证日志在 App Group 里被所有 LiveContainer 进程共享（0.5.47 起刻意去掉跨进程锁），
# 而共享 App 必然与启动它的 LiveContainer 进程、控制台等同时存在。若每次强制刷新都去
# 领新 GUID，且运营商对同一张 SIM 只保留一个有效身份，那么每个进程刷新都会作废其他进程
# （以及自己上一次）的身份 → 连接失败 → 又强制刷新 → 又换身份，形成自我维持的循环。
# 实测形态吻合：上游 TCP 连得上、请求发得出，然后一个字节都不回就关闭
# （recvFail 1224、lastResp 空），而 connectFail/sendFail 全为 0。
assert 'if (!guidOverride && (force || !guid))' not in king, \
    'a forced refresh mints a brand-new GUID identity again (cross-process invalidation loop)'
assert 'kp_forwarder_take_credential_rejection' in king, \
    'GUID re-minting is no longer gated on an explicit server credential rejection'
assert 'kp_forwarder_note_credential_rejection' in core, \
    'the C layer no longer signals 820/821/823 credential rejection to the ObjC layer'
assert 'kp_forwarder_take_credential_rejection' in Path('Tweak/Sources/KPKIngCore.h').read_text(encoding='utf-8'), \
    'the credential-rejection handshake is not declared in the C header'

print('king cache/refresh logic static checks OK')
PY
