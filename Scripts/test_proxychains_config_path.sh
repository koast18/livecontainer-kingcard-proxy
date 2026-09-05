#!/bin/bash
# Exercise the C constructor's managed-config selection without Foundation.
set -euo pipefail
cd "$(dirname "$0")/.."

CC_BIN="${CC:-cc}"
TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/lcproxy-config-path.XXXXXX")"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

DL_LIB=()
if [ "$(uname -s)" != "Darwin" ]; then
    DL_LIB=(-ldl)
fi

mkdir -p "$TMPDIR_TEST/shared/Tweaks"
"$CC_BIN" -std=c99 -O0 -g -D_GNU_SOURCE \
  -ITweak/ProxyCore/vendor/proxychains-ng/src \
  Scripts/test_proxychains_config_path.c \
  Tweak/ProxyCore/vendor/proxychains-ng/src/common.c \
  -pthread \
  "${DL_LIB[@]}" \
  -o "$TMPDIR_TEST/shared/Tweaks/config_path_probe"

probe="$TMPDIR_TEST/shared/Tweaks/config_path_probe"
primary="$TMPDIR_TEST/shared/LCProxy/proxychains.conf"
private="$TMPDIR_TEST/private/Documents/LCProxy/proxychains.conf"
canonical="$TMPDIR_TEST/app-group/LiveContainer/LCProxy/proxychains.conf"

write_config() {
    mkdir -p "$(dirname "$1")"
    printf 'strict_chain\n[ProxyList]\nhttp 127.0.0.1 8080\n' > "$1"
}

# A shared-app dylib has no AppGroup config yet, so it must use the config
# already owned by the LiveContainer instance that launched it.
write_config "$private"
LC_HOME_PATH="$TMPDIR_TEST/private" "$probe" "$private"
echo "launch-private config fallback: OK"

# The App Group config is canonical. A private config is only a fallback when
# the canonical file does not exist; timestamp order must not roll a converted
# shared app back to a stale private route.
write_config "$primary"
touch -t 202609050001 "$primary"
touch -t 202609050002 "$private"
LC_HOME_PATH="$TMPDIR_TEST/private" "$probe" "$primary"
touch -t 202609050003 "$primary"
LC_HOME_PATH="$TMPDIR_TEST/private" "$probe" "$primary"
echo "canonical config selection: OK"

# A converted shared app may keep loading its signed private dylib. The
# Foundation layer must therefore pin C parsing to the App Group file rather
# than treating the dylib directory as canonical.
write_config "$canonical"
LC_HOME_PATH="$TMPDIR_TEST/private" "$probe" "$canonical" "$canonical"
echo "managed App Group config selection: OK"
rm -f "$canonical"
LC_HOME_PATH="$TMPDIR_TEST/private" "$probe" NONE "$canonical"
echo "missing managed App Group config remains fail-closed: OK"

# LiveContainer may provide LC_HOME_PATH as Documents already; do not append
# another Documents component and silently lose the private configuration.
rm -f "$primary"
LC_HOME_PATH="$TMPDIR_TEST/private/Documents" "$probe" "$private"
echo "Documents-root normalization: OK"

# No managed configuration is an explicit failure. The C core remains
# disabled/fail-closed; this resolver must never substitute a system config.
rm -f "$private"
LC_HOME_PATH="$TMPDIR_TEST/private" "$probe" NONE
echo "missing config remains fail-closed: OK"
