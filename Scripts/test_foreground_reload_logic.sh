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

print('foreground reload / shared-app forwarder static checks OK')
PY
