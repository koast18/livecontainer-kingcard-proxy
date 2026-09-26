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
assert 'if (force) [self clearForwarderKingState];' in king, \
    'a forced refresh leaves stale credentials in its forwarder'

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

# 转发器退役必须异步，且重建必须先启动新的再替换旧的。
# kp_forwarder_stop 要等 client 线程退出（它们可能卡在同步取号 hook 的网络等待里，
# 单次最长 15s；grace 上限 10s），kp_forwarder_free 内部还会再 stop 一轮 —— 在
# runtime apply 路径上同步 stop/free 一个**正在运行**的转发器会把 apply 卡住最长
# 20s：期间 self.forwarder 已是 NULL、旧监听 fd 已关闭，而 ObjC 层上次发布的
# override 仍指向旧端口（所有连接被拒），后续 apply 还全部堵在 lifecycleLock 上排队。
# 实测形态正是 forwarderPort=0 / running=false / proxyOverridePort=<旧端口> /
# desiredForwarderRunning=true / forwarderDiscardCount=0 / lastForwarderLifecycle=""。
apply_start = king.index('- (void)applyConfig:(NSDictionary *)settings effectiveMode:')
# 只取 applyConfig 自身的方法体（到紧随其后的 retireForwarder: 定义之前），
# 否则会把异步回收方法里的 kp_forwarder_stop 误算进来。
apply_cfg = king[apply_start:king.index('// 异步回收退役的转发器', apply_start)]
assert 'kp_forwarder_stop(' not in apply_cfg, \
    'applyConfig still synchronously stops a running forwarder (up to 20s block on the apply path)'
assert 'dispatch_async(self.forwarderReaperQueue' in king, \
    'forwarder retirement is not asynchronous'
assert king.count('[self retireForwarder:') >= 2, \
    'not all forwarder retirement paths are asynchronous'
_reaper = king[king.index('- (void)retireForwarder:(kp_forwarder *)fw {'):]
_reaper = _reaper[:_reaper.index('\n}\n') + 3]
assert 'lifecycleLock' not in _reaper, \
    'retirement re-acquires lifecycleLock, which would re-block the runtime apply path'
assert 'kp_forwarder_start(newForwarder)' in apply_cfg, \
    'the replacement forwarder is not started before the old one is retired'
_rebuild = apply_cfg[apply_cfg.index('kp_forwarder_start(newForwarder)'):]
assert '[self retireForwarder:' in _rebuild, \
    'the old forwarder is not retired after the replacement is already running'
assert 'self.forwarder = NULL' not in _rebuild, \
    'self.forwarder is still nulled during a rebuild (stale-override outage window)'

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

# Foreground activation should not force a synchronous refresh on the main thread.
assert 'refreshCredentials' not in control, 'foreground notification still forces refresh'

print('king cache/refresh logic static checks OK')
PY
