#!/bin/bash
# 安装 git pre-push 钩子：本地检查不通过就拒绝推送。
#
# 为什么需要：CI 跑得比本地慢得多，而本地能跑的检查已经覆盖了大部分失败原因
# （静态守卫、锁序、括号平衡、真 bash 守卫）。此前出现过"本地检查已失败却仍然推送"，
# 结果是 CI 变红 + 需要强制移动 tag —— 一次往返的时间成本远高于本地跑一遍。
#
# 用法：bash Scripts/install_hooks.sh
set -euo pipefail
cd "$(dirname "$0")/.."

HOOK=".git/hooks/pre-push"
mkdir -p .git/hooks
cat > "$HOOK" <<'HOOK_BODY'
#!/bin/bash
# 自动生成（Scripts/install_hooks.sh）。本地检查不通过则拒绝推送。
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
if [ -f ../precheck.py ]; then
    PRECHECK=../precheck.py
elif [ -f precheck.py ]; then
    PRECHECK=precheck.py
else
    echo "pre-push: precheck.py 未找到，跳过本地检查" >&2
    exit 0
fi
echo "pre-push: 运行本地检查（失败将拒绝推送）…" >&2
if ! python "$PRECHECK" >/tmp/lcproxy-precheck.log 2>&1; then
    echo "" >&2
    echo "pre-push 被拒绝：本地检查未通过。" >&2
    tail -n 30 /tmp/lcproxy-precheck.log >&2
    echo "" >&2
    echo "完整日志：/tmp/lcproxy-precheck.log" >&2
    exit 1
fi
echo "pre-push: 本地检查通过" >&2
HOOK_BODY
chmod +x "$HOOK"
echo "installed: $HOOK"