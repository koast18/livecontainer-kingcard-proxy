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

# Cache reads must search both primary and shared LiveContainer data dirs.
assert 'LCProxyAllDataDirectories' in king, 'loadState does not search shared dirs'

# Multi-LiveContainer state convergence:
# - the cross-process lock must cover every directory the state file is written to
assert 'stateLockPaths' in king, 'state lock does not cover all state directories'
assert 'acquireStateLocks' in king, 'missing multi-directory state lock acquisition'
assert 'releaseStateLocks' in king, 'missing multi-directory state lock release'
assert '- (int)acquireStateLock ' not in king, 'old single-directory state lock still present'
# - loadState must pick the freshest copy, not blindly prefer primary
assert 'bestUpdatedAt' in king, 'loadState does not converge on the freshest state copy'
assert 'updatedAt' in king, 'saveState does not stamp updatedAt for freshness comparison'
# - lock contention must retry quickly instead of waiting for the 2-min timer
assert 'scheduleRefreshRetryAfterLockContention' in king, 'no fast retry when the state lock is held by another instance'
# - latency probing must be capped so the state lock is not held for tens of seconds
assert 'KP_LATENCY_PROBE_MAX' in king, 'sequential latency probing is not capped'

# Foreground activation should not force a synchronous refresh on the main thread.
assert 'refreshCredentials' not in control, 'foreground notification still forces refresh'

print('king cache/refresh logic static checks OK')
PY
