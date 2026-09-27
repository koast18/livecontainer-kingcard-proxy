#!/bin/bash
# Static guards for the Alook/Speedtest high-download crash fixes.
#
# These are cheap source-level assertions that catch accidental regressions of
# the crash fixes:
#   v0.5.24:
#     - WKWebView nw_proxy_config is not released immediately on reload.
#     - KingCard forwarder caps concurrent clients.
#   v0.5.27:
#     - KingCard forwarder waits for client threads before freeing.
#   This branch:
#     - async_proxy relay threads are capped.
#     - WKWebView keeps multiple old nw_proxy_config generations.
#     - LCProxyKing does not stop/free the forwarder while holding self.lock.
set -euo pipefail
cd "$(dirname "$0")/.."

WEBKIT="Tweak/ProxyCore/src/webkit_proxy.m"
CORE="Tweak/Sources/KPKIngCore.c"
ASYNC="Tweak/ProxyCore/src/async_proxy.c"
KING="Tweak/Sources/LCProxyKing.m"

fail() {
    echo "Alook crash guard FAILED: $1" >&2
    exit 1
}

# --- nw_proxy_config lifecycle guard ---
grep -q "LC_WEBKIT_MAX_OLD_PROXY_CONFIGS" "$WEBKIT" \
    || fail "webkit_proxy.m no longer keeps multiple stale nw_proxy_config generations"
grep -q "lc_retire_current_proxy_config" "$WEBKIT" \
    || fail "webkit_proxy.m no longer defers nw_proxy_config release through a retirement queue"

# --- forwarder thread cap guard ---
grep -q "define KP_FORWARDER_MAX_CLIENTS 64" "$CORE" \
    || fail "KPKIngCore.c lost the 64-client forwarder cap"
grep -q "fw->active_clients >= KP_FORWARDER_MAX_CLIENTS" "$CORE" \
    || fail "KPKIngCore.c no longer rejects connections above the forwarder cap"

# --- forwarder stop waits for client threads before free guard ---
# kp_forwarder_stop must wake relay threads blocked on BOTH the client fd and
# the upstream fd (half-open upstreams after app suspend never deliver data),
# and it must never free (or block forever) while a client thread is alive:
# the wait is bounded by KP_FORWARDER_STOP_GRACE_MS and kp_forwarder_free
# leaks the forwarder as a zombie when threads outlive the grace period.
grep -q "client_cond" "$CORE" \
    || fail "KPKIngCore.c no longer has a client-exit condition variable"
grep -q "pthread_cond_timedwait(&fw->client_cond, &fw->client_lock" "$CORE" \
    || fail "KPKIngCore.c no longer bounds the stop wait in kp_forwarder_stop"
grep -q "fw->active_clients > 0" "$CORE" \
    || fail "KPKIngCore.c no longer waits on active_clients before freeing"
grep -q "define KP_FORWARDER_STOP_GRACE_MS" "$CORE" \
    || fail "KPKIngCore.c lost the stop grace deadline"
grep -q "kp_forwarder_shutdown_upstreams" "$CORE" \
    || fail "KPKIngCore.c no longer wakes relays blocked on upstream sockets"
grep -q "kp_forwarder_shutdown_upstreams_locked" "$CORE" \
    || fail "KPKIngCore.c lost the lock-held upstream wakeup helper"
grep -q "kp_forwarder_shutdown_upstreams_locked(fw);" "$CORE" \
    || fail "KPKIngCore.c kp_forwarder_stop no longer calls the upstream wakeup helper"
grep -q "kp_upstream_close" "$CORE" \
    || fail "KPKIngCore.c lost the close-under-registry-lock upstream helper"
grep -q "forwarder leaked intentionally" "$CORE" \
    || fail "KPKIngCore.c frees forwarders while client threads may still run"
grep -q "kp_relay_upstream_to_client" "$CORE" \
    || fail "KPKIngCore.c HTTP body relay no longer has an idle-timeout pump"

# --- async_proxy relay thread cap guard ---
grep -q "define LC_ASYNC_MAX_RELAY_THREADS 64" "$ASYNC" \
    || fail "async_proxy.c lost the relay thread cap"
grep -q "lc_async_relay_try_acquire" "$ASYNC" \
    || fail "async_proxy.c no longer bounds relay thread creation"

# --- LCProxyKing deadlock guard ---
grep -q "不要在持有 self.lock 时 stop/free" "$KING" \
    || fail "LCProxyKing.m lost the no-stop-under-lock comment/guard marker"

# --- LCProxyKing lifecycle serialization guard ---
grep -q "lifecycleLock" "$KING"     || fail "LCProxyKing.m lost the forwarder lifecycle serialization lock"
grep -q "@finally" "$KING"     || fail "LCProxyKing.m applyConfig no longer releases lifecycleLock on all exits"

# --- 崩溃加固：关键入口必须兜住 ObjC 异常 ---
#
# 本 tweak 注入到第三方 App 里，最高优先级是"绝不弄崩宿主"。构造器与配置应用路径一旦
# 抛出 ObjC 异常，异常会穿透 dylib 初始化（__attribute__((constructor))）或 GCD 边界
# 直接终止进程 —— 在构造器阶段就是"一打开就闪退"，且发生在任何日志起来之前。
CONTROL="Tweak/Sources/LCProxyControl.m"
CONFIG="Tweak/Sources/LCProxyConfig.m"
PATHS="Tweak/Sources/LCProxyPaths.m"
SERVER="Tweak/Sources/LCProxyServer.m"
grep -q "LCProxyRecordSwallowedException" "$PATHS" \
    || fail "LCProxyPaths.m lost the swallowed-exception recorder"
grep -q "@catch (NSException" "$CONTROL" \
    || fail "LCProxyControl.m constructor no longer swallows ObjC exceptions (crash on launch)"
grep -q "LCProxyRecordSwallowedException(@\"constructor\"" "$CONTROL" \
    || fail "LCProxyControl.m constructor does not record a swallowed exception"
grep -q "applyRuntimeSnapshotUnsafe" "$CONFIG" \
    || fail "LCProxyConfig.m lost the crash-hardened applyRuntimeSnapshot wrapper"
grep -q "LCProxyRecordSwallowedException(@\"applyRuntimeSnapshot\"" "$CONFIG" \
    || fail "LCProxyConfig.m applyRuntimeSnapshot does not record a swallowed exception"
grep -q "swallowedExceptions" "$SERVER" \
    || fail "/api/status no longer exposes swallowedExceptions"

# --- 上游 connect 必须真超时（否则"一慢就全拒"）---
#
# SO_SNDTIMEO / SO_RCVTIMEO 只约束 send/recv，**不约束 connect()**：阻塞 socket 上的
# connect 会等到内核 TCP 握手超时（可达 ~75s）。于是"10 秒超时"名不副实 —— 单节点最坏
# 占住 client 线程 ~75s，一次转发试 4 个节点最坏 ~300s，而 client 槽位上限只有 64。
# 上游一慢，槽位立刻被等待 connect 的线程占满，转发器从"慢"退化为"对一切新连接回 503"，
# 而 running / listenFdValid / 凭证池 / 链端口在 status 里全部正常 —— 实测形态就是
# activeForwarderClients 停在 64、statHttpRequests=0、完全无法上网。
grep -q "kp_connect_with_timeout" "$CORE" \
    || fail "KPKIngCore.c lost the real-timeout connect helper"
grep -q "O_NONBLOCK" "$CORE" \
    || fail "KPKIngCore.c upstream connect is blocking again (timeout not enforced)"
grep -q "SO_ERROR" "$CORE" \
    || fail "KPKIngCore.c non-blocking connect does not check SO_ERROR"
grep -q "kp_connect_with_timeout(fd, ai->ai_addr" "$CORE" \
    || fail "kp_connect_host no longer routes through the timeout-enforcing connect"
if grep -q "if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;" "$CORE"; then
    fail "KPKIngCore.c calls blocking connect() directly again (SO_SNDTIMEO cannot bound it)"
fi
# 槽位耗尽必须可观测：否则"一慢就全拒"在 status 里只剩 activeForwarderClients 一条线索。
grep -q "stat_client_rejections" "$CORE" \
    || fail "KPKIngCore.c no longer counts client-slot rejections"
grep -q "statClientRejections" "Tweak/Sources/LCProxyKing.m" \
    || fail "/api/status no longer exposes statClientRejections"

# --- 上游失败必须分步可诊断（否则只能盲猜"为什么连不上"）---
#
# 实测 statHttpsConnects(270) ≈ statRefreshCalls(267)：每个连接都走完"池内全部节点失败"
# 这条路，且 10 秒内失败 270 次说明失败很快。但"失败"有 5 个修法完全不同的出口
# （连接/发送/无响应/820-823/其它状态码），外加最隐蔽的一种 —— **隧道已建立(200)却
# 上游一个字节都不回**（客户端拿到 200、浏览器认为可用，TLS 握手永远完不成，而转发器
# 这边既无 errno 也无非 2xx）。必须各自计数并保留现场。
grep -q "stat_up_pick_fail" "$CORE" || fail "KPKIngCore.c lost counter: stat_up_pick_fail"
grep -q "stat_up_connect_fail" "$CORE" || fail "KPKIngCore.c lost counter: stat_up_connect_fail"
grep -q "stat_up_send_fail" "$CORE" || fail "KPKIngCore.c lost counter: stat_up_send_fail"
grep -q "stat_up_recv_fail" "$CORE" || fail "KPKIngCore.c lost counter: stat_up_recv_fail"
grep -q "stat_up_cred_code" "$CORE" || fail "KPKIngCore.c lost counter: stat_up_cred_code"
grep -q "stat_up_other_code" "$CORE" || fail "KPKIngCore.c lost counter: stat_up_other_code"
grep -q "stat_up_tunnel_no_data" "$CORE" || fail "KPKIngCore.c lost counter: stat_up_tunnel_no_data"
grep -q "stat_up_fake_ok" "$CORE" || fail "KPKIngCore.c lost counter: stat_up_fake_ok"grep -q "kp_record_upstream_failure" "$CORE" \
    || fail "KPKIngCore.c no longer records the last upstream failure context"
# 注意字段名：kp_forwarder_stats 里的字段**没有** stat_ 前缀（stat_ 前缀只用在
# struct kp_forwarder 的内部字段上）。这里曾写错名字导致 CI 红、而本地 runner 没抓到。
grep -q "up_tunnel_no_data" "Tweak/Sources/KPKIngCore.h" \
    || fail "kp_forwarder_stats no longer exposes the tunnel-no-data counter"
grep -q "up_connect_fail" "Tweak/Sources/KPKIngCore.h" \
    || fail "kp_forwarder_stats no longer exposes the upstream connect-failure counter"
grep -q "last_up_stage" "Tweak/Sources/KPKIngCore.h" \
    || fail "kp_forwarder_stats no longer exposes the last upstream failure stage"
grep -q "last_tunnel_client_to_up" "$CORE" \
    || fail "KPKIngCore.c no longer records last-tunnel byte counts"
grep -q "upstreamDiag" "Tweak/Sources/LCProxyKing.m" \
    || fail "/api/status no longer exposes upstreamDiag (back to guessing)"
grep -q "tunnelNoData" "Tweak/Sources/LCProxyKing.m" \
    || fail "upstreamDiag no longer reports tunnelNoData"

echo "Alook crash guard static checks OK"
