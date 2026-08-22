#!/bin/bash
# Static guards for the Alook/Speedtest high-download crash fixes.
#
# These are cheap source-level assertions that catch accidental regressions of
# the two crash fixes already merged in v0.5.24 / v0.5.27:
#   1. WKWebView nw_proxy_config is not released immediately on reload.
#   2. KingCard forwarder caps concurrent clients and waits for client threads
#      before freeing the forwarder.
set -euo pipefail
cd "$(dirname "$0")/.."

WEBKIT="Tweak/ProxyCore/src/webkit_proxy.m"
CORE="Tweak/Sources/KPKIngCore.c"

fail() {
    echo "Alook crash guard FAILED: $1" >&2
    exit 1
}

# --- nw_proxy_config lifecycle guard ---
grep -q "g_lc_proxy_config_old" "$WEBKIT" \
    || fail "webkit_proxy.m no longer keeps a stale nw_proxy_config generation"
grep -q "nw_release(g_lc_proxy_config_old)" "$WEBKIT" \
    || fail "webkit_proxy.m no longer defers nw_proxy_config release"

# --- forwarder thread cap guard ---
grep -q "define KP_FORWARDER_MAX_CLIENTS 64" "$CORE" \
    || fail "KPKIngCore.c lost the 64-client forwarder cap"
grep -q "fw->active_clients >= KP_FORWARDER_MAX_CLIENTS" "$CORE" \
    || fail "KPKIngCore.c no longer rejects connections above the forwarder cap"

# --- forwarder stop waits for client threads before free guard ---
grep -q "client_cond" "$CORE" \
    || fail "KPKIngCore.c no longer has a client-exit condition variable"
grep -q "pthread_cond_wait(&fw->client_cond, &fw->client_lock)" "$CORE" \
    || fail "KPKIngCore.c no longer waits for active clients in kp_forwarder_stop"
grep -q "while (fw->active_clients > 0)" "$CORE" \
    || fail "KPKIngCore.c no longer waits on active_clients before freeing"

echo "Alook crash guard static checks OK"
