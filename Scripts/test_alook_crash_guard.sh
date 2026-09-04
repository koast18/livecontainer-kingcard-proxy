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
grep -q "while (fw->active_clients > 0)" "$CORE" \
    || fail "KPKIngCore.c no longer waits on active_clients before freeing"
grep -q "define KP_FORWARDER_STOP_GRACE_MS" "$CORE" \
    || fail "KPKIngCore.c lost the stop grace deadline"
grep -q "kp_forwarder_shutdown_upstreams" "$CORE" \
    || fail "KPKIngCore.c no longer wakes relays blocked on upstream sockets"
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

echo "Alook crash guard static checks OK"
