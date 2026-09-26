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
              '[self newestValidRecordFromLog]', '[self trimCredentialLogIfNeeded]')
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

# Foreground activation should not force a synchronous refresh on the main thread.
assert 'refreshCredentials' not in control, 'foreground notification still forces refresh'

print('king cache/refresh logic static checks OK')
PY
