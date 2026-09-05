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

# 共享 App 的 primary 与 AppGroup 数据目录相同；目录列表必须额外包含启动方
# LiveContainer 的私有数据目录（LC_HOME_PATH），否则共享目录缺 settings.json
# 时会退到 custom 127.0.0.1:8080 的死默认值 —— 横幅照常显示但所有连接被拒。
assert 'LC_HOME_PATH' in paths, 'no LC_HOME_PATH fallback for shared-app guests'
assert 'LCProxyLaunchPrivateDataDirectory' in paths, 'missing launch-private data dir helper'
assert re.search(r'launchPrivate\.length', paths), \
    'AllDataDirectories does not append the launch-private dir'

# 多进程按同一列表顺序锁全部数据目录；私有 App 进程（primary=LC 私有目录）与
# 共享 App 进程（primary=AppGroup 目录）的插入顺序天然相反，必须按路径全局
# 排序保证锁序一致，否则两个进程互以相反顺序抢同两把锁，可能互等成环。
assert re.search(r'sortedArrayUsingSelector:@selector\(compare:\)', paths), \
    'data directory list is not canonically sorted; state locks can invert across processes'

# settings 多副本（AppGroup 目录 / 启动方 LC 私有目录）时必须按 mtime 取最新，
# 防止共享目录里的陈旧副本盖掉刚在控制台保存的配置。
assert 'fileModificationDate' in config, 'load does not compare settings.json mtime across dirs'
assert re.search(r'NSOrderedDescending', config), 'load does not prefer the newest settings.json'

# 王卡状态锁必须继续覆盖全部数据目录（列表已包含共享 App 的回落目录）。
assert 'stateLockPaths' in king, 'state lock no longer covers all data dirs'
assert 'acquireStateLocks' in king, 'missing multi-directory state lock acquisition'
print('test_shared_app_paths: OK')
PY
