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

# A valid App Group state is authoritative. Private copies may only seed a
# missing/corrupt canonical file, never win simply because their mtime is newer.
assert 'LCProxyCanonicalDataDirectory' in king, 'King state has no canonical App Group path'
assert 'canonicalState' in king and 'newestFallbackState' in king, \
    'King state does not distinguish canonical storage from migration fallback'
assert 'return [self canonicalState] ?: [self newestFallbackState]' in king, \
    'King load order permits a fallback to override canonical state'
assert 'for (NSString *dir in LCProxyAllDataDirectories())' not in king[king.index('- (NSMutableDictionary *)loadState'):king.index('- (BOOL)saveState:', king.index('- (NSMutableDictionary *)loadState'))], \
    'King state still arbitrates all copies instead of preferring canonical'
assert 'NSDataWritingAtomic' in king and 'isEqualToDictionary:state' in king, \
    'state writes are not atomically verified before success is reported'

# A persistent fencing lease keeps synchronous network work outside the lock
# while ensuring only one instance can publish its result.
assert 'refreshLeaseOwner' in king and 'refreshLeaseGeneration' in king, \
    'King refresh lacks persistent owner/generation lease fields'
assert 'refreshLeaseBaseUpdatedAt' in king and 'refreshLeaseExpiresAt' in king, \
    'King refresh lease lacks fencing timestamp or TTL'
assert 'refreshInvalidatingGeneration' in king, \
    'forced refresh lacks a persistent invalidating generation marker'
assert 'acquireRefreshLeaseWithForce' in king, 'missing refresh lease acquisition'
assert 'renewRefreshLeaseForOwnerID' in king and 'startRefreshLeaseHeartbeatForOwnerID' in king, \
    'slow refreshes lack a persistent lease heartbeat'
assert 'LCProxyKingRefreshLeaseHeartbeatInterval = 20;' in king, \
    'refresh lease heartbeat does not renew before the 75-second lease can expire'
assert 'LCProxyKingCommitResultFenced' in king, 'expired lease results are not fenced'
assert 'LCProxyKingCommitResultPersistenceFailed' in king, 'state persistence failure is reported as success'
assert 'kp_forwarder_clear_king_state' in king, 'failed refresh does not clear stale forwarder state'
assert 'scheduleRefreshRetryAfterLockContention' in king, 'no fast retry when the state lock is held by another instance'
# - latency probing must be capped so the state lock is not held for tens of seconds
assert 'KP_LATENCY_PROBE_MAX' in king, 'sequential latency probing is not capped'
latency_sort_start = king.index('- (NSArray<NSString *> *)proxiesSortedByLatency:')
latency_sort_end = king.index('- (NSString *)localRandomGuid', latency_sort_start)
latency_sort = king[latency_sort_start:latency_sort_end]
assert latency_sort.count('tcpConnectMsForProxy:proxy') == 1, \
    'latency sort probes a proxy more than once'

# Cross-process locks are only an arbitration boundary: a peer must never be
# blocked behind the 15-second GUID/token/proxy requests or latency probes.
refresh_start = king.index('- (BOOL)refreshCredentialsWithForce:')
refresh_end = king.index('- (BOOL)finishRefreshWithState:', refresh_start)
refresh = king[refresh_start:refresh_end]
first_network_request = refresh.index('syncFetchGuid')
assert refresh.index('acquireRefreshLeaseWithForce') < first_network_request, \
    'refresh starts PBProxy work before persistently claiming its lease'
assert 'baseUpdatedAt' in refresh and 'generation' in refresh, \
    'refresh does not retain fencing timestamp and generation'
assert 'commitRefreshState:state' in king and 'generation:leaseGeneration.unsignedLongLongValue' in king, \
    'refresh does not reacquire state locks for its atomic commit'
assert 'LCProxyKingCommitResultPeerState' in king, \
    'a newer peer state cannot win refresh arbitration'
assert 'LCProxyKingCommitResultNotCommitted' in king, \
    'a failed refresh does not clear its persistent lease'
assert 'commitResult == LCProxyKingCommitResultFenced' in king and \
       'scheduleRefreshRetryAfterLockContention' in king, \
    'a fenced refresh does not retry after peer lease arbitration'
commit_start = king.index('- (LCProxyKingCommitResult)commitRefreshState:', king.index('@implementation LCProxyKing'))
commit_end = king.index('- (void)clearForwarderKingState', commit_start)
commit = king[commit_start:commit_end]
assert 'leaseExpiresAt.doubleValue <=' not in commit, \
    'an unchallenged owner is fenced solely because a slow refresh crossed its TTL'
assert 'removeObjectForKey:@"refreshInvalidatingGeneration"' in commit, \
    'a completed refresh leaves its invalidating generation permanently active'
freshness_start = king.index('- (BOOL)stateHasFreshCredentials:(NSDictionary *)state matchingSettings:')
freshness_end = king.index('- (BOOL)stateHasFreshCredentials:(NSDictionary *)state {', freshness_start)
freshness = king[freshness_start:freshness_end]
assert 'refreshInvalidatingGeneration' in freshness and 'return NO' in freshness, \
    'cached credentials remain usable while a forced refresh generation is in flight'
acquire_start = king.index('- (LCProxyKingLeaseResult)acquireRefreshLeaseWithForce:', king.index('@implementation LCProxyKing'))
acquire_end = king.index('- (BOOL)renewRefreshLeaseForOwnerID:', acquire_start)
acquire = king[acquire_start:acquire_end]
assert 'if (force)' in acquire and 'latest[@"refreshInvalidatingGeneration"] = @(generation);' in acquire, \
    'force refresh does not publish its invalidation marker atomically with the lease'
assert 'if (force) [self clearForwarderKingState];' in refresh, \
    'the instance starting a forced refresh leaves stale credentials in its forwarder'
assert 'renewActiveRefreshLeaseForOwnerID:self.refreshOwnerID' in refresh, \
    'network requests and latency probes do not explicitly renew their lease'
ready_start = king.index('- (BOOL)isReady {')
ready_end = king.index('- (int)localForwarderPort', ready_start)
ready = king[ready_start:ready_end]
assert 'stateHasFreshCredentials:[self loadState]' in ready, \
    'isReady ignores a peer\'s forced-refresh invalidation marker'
for key in ('@"guid"', '@"qua2"', '@"token"', '@"key"', '@"qtype"',
            '@"queen_http"', '@"queen_https"', '@"tokenExpireEpoch"',
            '@"proxyExpireEpoch"'):
    assert key in commit, \
        f'failed refresh leaves persistent {key} available for a stale reload'
network_refresh = refresh[refresh.index('if (!guidOverride && (force || !guid))'):]
assert 'self.lastSource =' not in network_refresh, \
    'network refresh writes status outside self.lock'
assert '- (NSString *)syncFetchGuid:' in king, 'missing synchronous GetGuid bridge'
assert 'guid = [self localRandomGuid];' in refresh, \
    'PBProxy GetGuid failure must fall back to local GUID so token/proxy refresh can continue'
assert 'if (!self.routePublished) {' not in refresh, \
    'credential bootstrap must not be blocked before route publication'

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
