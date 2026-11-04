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

config = Path('Tweak/Sources/LCProxyConfig.m').read_text(encoding='utf-8')
control = Path('Tweak/Sources/LCProxyControl.m').read_text(encoding='utf-8')
king = Path('Tweak/Sources/LCProxyKing.m').read_text(encoding='utf-8')
king_h = Path('Tweak/Sources/LCProxyKing.h').read_text(encoding='utf-8')
core = Path('Tweak/Sources/KPKIngCore.c').read_text(encoding='utf-8')
server = Path('Tweak/Sources/LCProxyServer.m').read_text(encoding='utf-8')
lib = Path('Tweak/ProxyCore/vendor/proxychains-ng/src/libproxychains.c').read_text(encoding='utf-8')
webkit = Path('Tweak/ProxyCore/src/webkit_proxy.m').read_text(encoding='utf-8')
override_c = Path('Tweak/ProxyCore/src/proxy_override.c').read_text(encoding='utf-8')

# Foreground applyToRuntime must avoid unnecessary reloads.
assert 'runtimeSignatureForSettings' in config, 'missing runtime signature method'
assert 'lastAppliedRuntimeSignature' in config, 'missing last applied signature state'
assert 'lastAppliedForwarderPort' in config, 'missing last applied forwarder port state'
assert 'needsRuntimeReload' in config, 'missing needsRuntimeReload decision'
assert 'lcproxy_control_set_proxy_override' in config, 'missing per-process proxy override hookup'
assert 'g_lcLifecycleObservers' in control, 'lifecycle observer tokens are not retained'
# 两个通知族都必须订阅。
#
# LiveContainer 的 LiveProcess.appex（`*.liveprocess://`，由 xpc_main 承载，
# `UIApplicationMain` 在 LiveProcess/main.m 里被整体替换）**不会**投递 `UIApplication*`
# 生命周期通知 —— 它只投递 `NSExtensionHost*`。而共享 App 在 multitask 下正是被交给
# 这类实例运行的（LiveContainerSwiftUI/Models/LCAppModel.swift 的 `uiIsShared` 分支）。
# 只订阅一个族 ⇒ 在那类进程里「回前台恢复/切后台清理」一次都不会触发。
# 参照：LiveContainer 自己的 LiveContainer/Tweaks/Dead10ccFix.m 按 isLiveProcess 切换。
for _n in ('UIApplicationDidBecomeActiveNotification',
           'UIApplicationWillEnterForegroundNotification',
           'UIApplicationDidEnterBackgroundNotification',
           'NSExtensionHostDidBecomeActiveNotification',
           'NSExtensionHostWillEnterForegroundNotification',
           'NSExtensionHostDidEnterBackgroundNotification'):
    assert _n in control, f'lifecycle notification not observed: {_n}'
# 投递队列必须与主队列无关：appex 进程的主队列排空时机不可依赖。
assert 'addObserverForName:name object:nil queue:nil' in control, \
    'lifecycle observers must not depend on the main queue being drained'

# 控制台端口不得静默失败（否则 /api/selfcheck 测的是别的进程）。
assert 'GCDWebServerOption_Port: @0' in server, \
    'console must fall back to an ephemeral port instead of staying headless'
assert 'recordConsoleEndpoint' in server, 'console endpoint is not recorded for cross-process discovery'
assert 'LCProxyHostProcessType' in server and 'LCProxyHostProcessType' in control, \
    'host process type is not exposed'
paths_h = Path('Tweak/Sources/LCProxyPaths.h').read_text(encoding='utf-8')
paths_m = Path('Tweak/Sources/LCProxyPaths.m').read_text(encoding='utf-8')
assert 'LCProxyHostProcessType' in paths_h and 'LCProxyHostProcessType' in paths_m, \
    'missing LCProxyHostProcessType implementation'
assert 'LP_HOME_PATH' in paths_m, \
    'host process type must be detected via LP_HOME_PATH (set only by LiveProcess/main.m)'

# KingCard forwarder should use an ephemeral port and expose it.
assert 'kp_forwarder_new("127.0.0.1", 0' in king, 'KingCard forwarder does not use ephemeral port'
assert 'localForwarderPort' in king, 'missing localForwarderPort implementation'
assert 'kp_forwarder_port(self.forwarder) : 0' in king, 'status should read port without recursive lock'
assert 'localForwarderPort' in king_h, 'missing localForwarderPort declaration'
# kp_forwarder_start must record the actual bound port after bind/listen.
assert 'getsockname(fd' in core, 'kp_forwarder_start does not query bound port'
assert 'fw->listen_port = ntohs' in core, 'kp_forwarder_start does not save actual port'

# Proxy-test must use the per-process forwarder port, not the old fixed 18080.
assert 'localForwarderPort' in server, 'proxy test still uses hardcoded 18080'
assert 'upstreamPort = 18080;' not in server, 'proxy test hardcodes 18080'

# C core must apply the override after config reload.
assert 'lcproxy_control_apply_proxy_override(proxychains_pd, proxychains_proxy_count)' in lib, \
    'reload_config does not apply per-process override'

# WKWebView proxy must honor the override too.
assert 'lcproxy_control_get_proxy_override' in webkit, 'webkit proxy does not honor override'

# Override module must exist with set/get/apply.
assert 'void lcproxy_control_set_proxy_override' in override_c
assert 'int lcproxy_control_get_proxy_override' in override_c
assert 'void lcproxy_control_apply_proxy_override' in override_c

# Fail-closed network monitoring.
assert 'lcproxy_network_monitor_update' in config, 'missing network monitor update call'
assert 'lcproxy_async_close_all' in config, 'foreground recovery does not close async relays'
assert 'notifyWillEnterForeground' in control, 'missing WillEnterForeground observer'
assert 'notifyDidEnterBackground' in control, 'missing DidEnterBackground observer'
assert 'performHealthCheck' in king, 'missing post-recovery health check'
assert 'kp_forwarder_shutdown_clients' in core, 'missing forwarder client shutdown'
assert 'kp_forwarder_listen_fd_valid' in core, 'missing listen fd health'
assert 'poll_timeout_ms' in core, 'forwarder pump still uses infinite poll'
assert 'lcproxy_control_copy_proxy_chain' in lib, 'missing chain snapshot API'
assert 'lcproxy_network_should_direct' in config, 'effective mode does not use fail-closed direct decision'
assert 'nw_path_monitor_create' in config, 'missing NWPathMonitor integration'
assert 'handleNetworkPath' in config, 'missing path handler'
assert 'writeProxychainsConf:s toDirectory:self.dataDirectory' in config, 'does not regenerate canonical conf on effective mode change'
assert 'lcproxy_network_monitor_update' in lib, 'missing network monitor update implementation'
assert 'lcproxy_network_should_direct' in lib, 'missing network direct decision implementation'
assert 'lc_direct_track_close_all' in lib, 'missing direct socket kill switch'
assert 'lc_direct_track_add_if_remote' in lib, 'missing direct socket tracking'
assert 'lc_direct_track_remove' in lib, 'missing direct socket untrack on close'
assert 'lc_direct_track_remove_range' in lib, 'missing direct socket untrack on close_range'

# Foreground recovery must self-heal instead of getting stuck:
assert 'lastForegroundingAt' in config, 'foregrounding dedup has no staleness escape'
assert 'recoveryRetryCount' in config, 'post-recovery health check does not retry failed recoveries'
assert 'LCProxyMaxRecoveryRetries' in config, 'health check retry is unbounded or missing'
# Forwarder-down must fail CLOSED: drop traffic, notify the user, keep restarting.
# Never fail open to direct — direct bypasses the kingcard tunnel and burns
# metered (通用) data.
assert 'forwarderUnavailable' in config, 'missing forwarder-down detection'
assert 'scheduleForwarderRecoveryRetry' in config, 'no persistent forwarder restart retry'
assert 'LCProxyForwarderUnavailableNotification' in config, 'forwarder-down does not notify the user'
assert 'LCProxyForwarderUnavailableNotification' in control, 'no user-visible banner for forwarder-down'
assert 'proxyActive = NO' not in config, 'kingcard mode must never fail open to direct when the forwarder is down'
assert 'BOOL configReady = lcproxy_control_set_config_path' in config, \
    'canonical config write and C-path pinning are not treated as one readiness gate'
assert 'BOOL needsRuntimeReload = configReady &&' in config, \
    'a failed canonical config write can reparse stale proxy settings'
assert '(proxyActive && !wasConfigValid)' in config, \
    'a repaired canonical config does not force C runtime recovery after a failed write'
assert 'configReady && (!proxyActive || lcproxy_control_get_config_valid())' in config, \
    'King route publication can proceed before the canonical config is usable'
# Forwarder stop must not wedge on relays blocked on half-open upstream sockets.
assert 'kp_forwarder_shutdown_upstreams' in core, 'stop does not wake relays blocked on upstream sockets'
assert 'kp_forwarder_shutdown_upstreams_locked' in core, 'stop no longer shuts down upstreams from the same critical section'
assert 'KP_FORWARDER_STOP_GRACE_MS' in core, 'kp_forwarder_stop wait is unbounded'
assert 'pthread_cond_timedwait' in core, 'kp_forwarder_stop still uses an infinite cond wait'
assert 'kp_up_open' in core, 'forwarder upstream sockets are not registered for shutdown'
assert 'forwarder leaked intentionally' in core, 'kp_forwarder_free may free memory still used by client threads'
assert 'max_idle_sec' in core, 'HTTP body relay has no idle timeout'

# ---- 0.5.81: lock discipline + dead-listener detection + suspend-resume refresh ----
import re as _re

def _method_body(src, sig):
    # 跳过 @interface 里的前向声明（以 ';' 结束），只取真正的定义。
    i = src.find(sig)
    while i >= 0 and 0 <= src.find(';', i) < src.find('{', i):
        i = src.find(sig, i + 1)
    assert i >= 0, f'missing method {sig}'
    j = src.find('{', i)
    depth = 0
    for k in range(j, len(src)):
        if src[k] == '{': depth += 1
        elif src[k] == '}':
            depth -= 1
            if depth == 0: return src[j:k + 1]
    raise AssertionError(f'unterminated method {sig}')

def _strip_comments(code):
    code = _re.sub(r'/\*.*?\*/', '', code, flags=_re.S)
    return _re.sub(r'//[^\n]*', '', code)

def _locked_regions(body):
    """Text between each `[self.lock lock]` and the next `[self.lock unlock]`."""
    out = []
    pos = 0
    while True:
        a = body.find('[self.lock lock]', pos)
        if a < 0: return out
        b = body.find('[self.lock unlock]', a)
        assert b > a, 'unbalanced self.lock'
        out.append(body[a:b])
        pos = b

# H0: status 曾在持 self.lock 时调用持同一把锁的方法（NSLock 不可重入）→ 永久自锁。
# 所有持锁区内不得调用会取 self.lock 的方法，也不得做阻塞的真探活。
_relocking = ('isReady', 'localForwarderPort', 'activeClientCount', 'forwarderStats',
              'selfCheck', 'requestBackgroundRefresh', 'loadCachedStateIntoForwarder',
              'hasFreshCachedState', 'loadState', 'credentialLogPath')
for _sig in ('- (NSDictionary *)status', '- (void)heartbeatTick', '- (NSDictionary *)selfCheck',
             '- (void)publishRouteForSettings:', '- (void)applyConfig:(NSDictionary *)settings effectiveMode:',
             '- (NSString *)syncFetchGuid:', '- (void)healForwarderDirectlyReplacing:',
             '- (void)appendSharedStatusSnapshot', '- (BOOL)performHealthCheck'):
    for _r in _locked_regions(_strip_comments(_method_body(king, _sig))):
        assert '[self.lock lock]' not in _r[len('[self.lock lock]'):],             f'{_sig}: nested [self.lock lock] (NSLock is not reentrant -> permanent self-deadlock)'
        assert 'kp_forwarder_is_listening' not in _r and 'kp_forwarder_probe_local' not in _r, \
            f'{_sig}: blocking listen probe while holding self.lock'
        for _m in _relocking:
            assert f'self {_m}]' not in _r, f'{_sig}: calls {_m} while holding non-reentrant self.lock'

# 真探活必须在 retain 保护下进行，且只有 retain 成功才允许 release。
assert 'BOOL retained = self.routePublished && forwarder != NULL && kp_forwarder_retain(forwarder) == 0;' in king, \
    'syncFetchGuid must only release a forwarder it actually retained'
assert 'if (retained) kp_forwarder_release(forwarder);' in king, 'syncFetchGuid releases without retain'

# H2: 心跳必须用真探活，不能只看内存标志（挂起后 socket 失效但 running 仍为 1）。
_hb = _method_body(king, '- (void)heartbeatTick')
assert 'kp_forwarder_is_listening' in _hb, 'heartbeat still uses the weak isRunning check'
assert '[self isRunning]' not in _hb, 'heartbeat must not decide liveness from isRunning'
assert 'healForwarderDirectlyReplacing:suspect' in _hb, 'heartbeat heal cannot replace a forwarder whose listener died'
# 自愈必须能替换"对象在但监听死"的转发器，否则心跳判死后自愈直接丢弃新实例。
_heal = _method_body(king, '- (void)healForwarderDirectlyReplacing:')
assert 'self.forwarder != suspect' in _heal, 'heal discards its rebuild when the dead forwarder is still installed'
assert 'self.publishedForwarderPort = port' in _heal, 'heal leaves the published route on the dead port'
# H3: 挂起恢复后必须立即校验/续期凭证（续期定时器基于 mach 时间，挂起期间不走）。
assert 'resumedFromSuspend' in _hb and 'refreshCredentialsAsync' in _hb, \
    'heartbeat does not refresh credentials after a long suspend (B3)'
# 锁外读转发器内部状态必须 retain。
assert 'kp_forwarder_retain(fw) == 0' in _method_body(king, '- (BOOL)performHealthCheck'), \
    'performHealthCheck probes a forwarder it did not retain'
assert 'kp_forwarder_release(fw);' in _method_body(king, '- (void)appendSharedStatusSnapshot'), \
    'status snapshot reads forwarder stats without retain'

# C 层：accept 循环必须识别失效的监听 socket，不能无条件 continue 空转。
_run = core[core.find('static void *kp_forwarder_run('):]
_run = _run[:_run.find('\nkp_forwarder *kp_forwarder_new(')]
assert 'POLLNVAL' in _run and 'POLLERR' in _run and 'POLLHUP' in _run, 'accept loop ignores poll error revents'
assert 'kp_forwarder_mark_listener_dead' in _run, 'accept loop never marks a dead listener'
assert 'ECONNABORTED' in _run and 'EMFILE' in _run, 'accept loop does not classify accept errors'
assert 'int kp_forwarder_is_running(kp_forwarder *fw) { return kp_forwarder_serving(fw); }' in core, \
    'kp_forwarder_is_running does not reflect a dead listener'
assert 'if (!kp_forwarder_serving(fw) || fw->listen_port <= 0) return 0;' in core, \
    'probe_local can report a dead listener as alive via kernel backlog'
assert 'int kp_forwarder_listener_error(kp_forwarder *fw);' in Path('Tweak/Sources/KPKIngCore.h').read_text(encoding='utf-8')

print('foreground reload / shared-app forwarder static checks OK')
PY
