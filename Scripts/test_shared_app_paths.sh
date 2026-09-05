#!/bin/bash
# Static regression guards for the shared-app data-directory fix.
#
# LiveContainer launches shared apps with the tweak root inside the app group
# (<AppGroup>/LiveContainer/Tweaks), so the dylib's path-derived primary data
# directory equals the app-group shared directory and the directory list
# collapses to a single entry. If settings.json is missing or stale there, the
# guest used to fall back to defaults (custom 127.0.0.1:8080, a dead local
# port) — the banner still shows but every connection is refused. This test
# pins the invariants that fix and keep that scenario convergent:
#   1. the launch-private LC data dir (LC_HOME_PATH) is part of the list;
#   2. the list is canonically sorted so cross-process state locks cannot
#      acquire the same lock files in opposite orders;
#   3. settings loads pick the newest copy across directories.
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

paths = Path('Tweak/Sources/LCProxyPaths.m').read_text(encoding='utf-8')
config = Path('Tweak/Sources/LCProxyConfig.m').read_text(encoding='utf-8')
king = Path('Tweak/Sources/LCProxyKing.m').read_text(encoding='utf-8')
common = Path('Tweak/ProxyCore/vendor/proxychains-ng/src/common.c').read_text(encoding='utf-8')
core = Path('Tweak/ProxyCore/vendor/proxychains-ng/src/libproxychains.c').read_text(encoding='utf-8')
updater = Path('ConsoleApp/AutoUpdater.m').read_text(encoding='utf-8')

# 共享 App 的 primary 与 AppGroup 数据目录相同；目录列表必须额外包含启动方
# LiveContainer 的私有数据目录（LC_HOME_PATH），否则共享目录缺 settings.json
# 时会退到 custom 127.0.0.1:8080 的死默认值 —— 横幅照常显示但所有连接被拒。
assert 'LC_HOME_PATH' in paths, 'no LC_HOME_PATH fallback for shared-app guests'
assert 'LCProxyLaunchPrivateDataDirectory' in paths, 'missing launch-private data dir helper'
assert re.search(r'launchPrivate\.length', paths), \
    'AllDataDirectories does not append the launch-private dir'

# Fallback discovery stays deterministic, while live settings/state use the
# canonical App Group directory as their only write target.
assert re.search(r'sortedArrayUsingSelector:@selector\(compare:\)', paths), \
    'legacy fallback directory order is not deterministic'
assert 'LCProxyCanonicalDataDirectory' in paths, \
    'shared App Group path is not exposed as canonical storage'

# settings 的 canonical 副本一旦有效，私有副本不得按 mtime 覆盖它；只有 canonical
# 缺失/损坏时才能从 fallback 迁移。
assert 'settingsInDirectory:self.dataDirectory' in config, 'load does not read canonical settings first'
assert 'newestFallbackSettings' in config, 'load has no migration fallback for legacy private settings'
assert 'if (raw) return [self mergedSettingsFrom:raw];' in config, \
    'private settings can override a valid canonical configuration'
assert 'synchronizeSettings:merged' in config, 'selected shared-app settings are not converged before reload'
assert 'isEqualToData:data' in config, 'settings synchronization rewrites identical files and churns mtimes'
assert 'isEqualToString:conf' in config, 'proxychains config synchronization rewrites identical files and churns mtimes'

# proxychains C 初始化早于 Objective-C 配置恢复，必须在 canonical 文件缺失时
# 才使用 LC_HOME_PATH 私有副本；Foundation 解析出 App Group canonical path 后，
# C 层必须锁定该绝对路径，不能再从私有 dylib 路径错误推导配置位置。
assert 'build_launch_private_config_path' in common, 'C config resolver has no launch-private fallback'
assert 'LC_HOME_PATH' in common, 'C config resolver does not read the launch container path'
assert 'if(has_primary)\n\t\tselected = primary_path;\n\telse if(has_private)' in common, \
    'C config resolver lets private config override canonical config'
assert 'lcproxy_control_set_config_path' in common, \
    'C config resolver cannot receive Foundation-resolved canonical path'
assert 'lcproxy_control_set_config_path(configPath.fileSystemRepresentation)' in config, \
    'runtime does not pin C parsing to the canonical App Group config'
assert 'runtime_path > 0 && get_file_stat(pbuf, NULL) ? pbuf : NULL' in common, \
    'missing managed canonical config can fall back to a private config'
assert 'lc_proxy_config_missing' in core, 'missing managed config has no shared fail-closed gate'
assert core.count('lc_proxy_config_missing()') >= 7, 'not all DNS/socket paths use the fail-closed config gate'
assert re.search(r'if\(lc_proxy_config_missing\(\)\)\s*\{\s*errno = ECONNREFUSED;\s*return -1;', core), \
    'missing proxy config is not explicitly fail-closed for stream connections'

# An active proxy must not hand `connectx` calls with unsupported extensions
# back to the real syscall: doing so would silently bypass KingCard/custom
# proxying. Explicit direct/disabled and thread-bypass paths remain above this
# rejection gate in the hook.
connectx_start = core.index('HOOKFUNC(int, connectx')
connectx_end = core.index('#endif', connectx_start)
connectx = core[connectx_start:connectx_end]
unsupported_start = connectx.index('if(!endpoints || !endpoints->sae_dstaddr ||')
unsupported = connectx[unsupported_start:]
assert 'errno = EOPNOTSUPP;' in unsupported and 'return -1;' in unsupported, \
    'unsupported connectx parameters are not fail-closed'
assert 'return true_connectx' not in unsupported, \
    'unsupported connectx parameters still bypass the proxy'

# KingCard has no UDP/QUIC transport. Its effective proxied mode must force the
# C hook and generated config to block non-TCP traffic even when the optional
# user toggle is off; only explicit effective direct mode may permit it.
assert 'BOOL blockNonTcp = [settings[@"blockNonTcp"] boolValue] ||' in config, \
    'generated KingCard config does not force block_non_tcp'
assert '[effectiveMode isEqualToString:@"kingcard"]' in config, \
    'KingCard mode is not included in non-TCP block policy'
assert 'BOOL block = proxyActive && ([s[@"blockNonTcp"] boolValue] ||' in config, \
    'runtime KingCard policy does not force block_non_tcp'
assert 'lcproxy_control_reload_config();\n        // The parser resets' in config and \
       'lcproxy_control_set_block_non_tcp(block ? 1 : 0);' in config, \
    'runtime KingCard policy is not reapplied after C parser reset'

# 控制台的私有 dylib 安装位置必须是 <LC_HOME_PATH>/Documents/Tweaks；根目录
# 虽可创建但 LiveContainer 不扫描，转换为共享 App 后会表现为控制台没加载 dylib。
assert 'lastPathComponent] isEqualToString:@"Documents"' in updater, \
    'console updater does not normalize LC_HOME_PATH to Documents'
assert '[candidates addObject:h];\n        [candidates addObject:[h stringByAppendingPathComponent:@"Documents"]];' not in updater, \
    'console updater still probes the non-loadable LC_HOME_PATH/Tweaks location'
assert '[cls respondsToSelector:selector]' in paths, \
    'App Group path helper can call an unavailable LCSharedUtils selector'
assert '[lcSharedUtils respondsToSelector:sel]' in updater, \
    'console updater can call an unavailable LCSharedUtils selector'

# 王卡状态只锁定并写入 canonical App Group 文件；私有目录仅用于受锁迁移。
assert 'LCProxyCanonicalDataDirectory' in king, 'King state is not canonicalized'
assert 'return @[[directory stringByAppendingPathComponent:@"kingcard-state.lock"]];' in king, \
    'King state lock covers migration copies instead of the single canonical state'
assert 'saveState:(NSMutableDictionary *)state error:' in king, 'King state write does not report failure'
print('test_shared_app_paths: OK')
PY
