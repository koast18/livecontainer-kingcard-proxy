#!/bin/bash
# Build LCProxyControl.dylib (iOS 15+ arm64). Requires macOS + Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="build/LCProxyControl.dylib"
VER="$(cat "$ROOT/version.txt" | tr -d ' \r\n' )"
OBJDIR="build/obj"

# Generate a single source of truth for version reporting.  This keeps the
# dylib version and the AltStore source version in sync instead of relying on
# the manually maintained hardcoded fallback in Version.h.
GIT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
mkdir -p "$ROOT/Tweak/Sources"
cat > "$ROOT/Tweak/Sources/Version.h" <<VERSION_HEREDOC
#ifndef LCProxy_Version_h
#define LCProxy_Version_h
#define KPTWEAK_VERSION "${VER}"
#define KPTWEAK_UA "LCProxy/${VER}"
#define KPTWEAK_GIT_COMMIT "${GIT_COMMIT}"
#endif
VERSION_HEREDOC

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN=15.0
ARCH=arm64

mkdir -p build
rm -rf "$OBJDIR"
mkdir -p "$OBJDIR"

# Generate embedded console HTML
node Scripts/gen_console_asset.js Resources/console.html Tweak/Sources/ConsoleHTML.h

SRCS="$(find Tweak/ProxyCore/vendor/proxychains-ng/src -maxdepth 1 -name '*.c' ! -name 'main.c' | sort) \
Tweak/ProxyCore/fishhook/fishhook.c \
Tweak/ProxyCore/src/webkit_proxy.m Tweak/ProxyCore/src/async_proxy.c Tweak/ProxyCore/src/proxy_override.c \
$(find Tweak/Sources -name '*.m' -o -name '*.c' | sort) \
$(find Tweak/Vendor/GCDWebServer -name '*.m' | sort)"

CFLAGS="-target ${ARCH}-apple-ios${MIN} -isysroot ${SDK} \
  -fobjc-arc -O2 -DNDEBUG \
  -D_GNU_SOURCE -D_DARWIN_C_SOURCE -DIS_MAC=1 -DMONTEREY_HOOKING -DSUPER_SECURE \
  -DGN_NODELEN_T=socklen_t -DGN_SERVLEN_T=socklen_t -DGN_FLAGS_T=int -DHAVE_CLOCK_GETTIME \
  -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
  -I${ROOT}/Tweak/Sources \
  -I${ROOT}/Tweak/ProxyCore/src \
  -I${ROOT}/Tweak/ProxyCore/vendor/proxychains-ng/src \
  -I${ROOT}/Tweak/ProxyCore/fishhook \
  -I${ROOT}/Tweak/Vendor/GCDWebServer \
  -I${ROOT}/Tweak/Vendor/GCDWebServer/Core \
  -I${ROOT}/Tweak/Vendor/GCDWebServer/Requests \
  -I${ROOT}/Tweak/Vendor/GCDWebServer/Responses"

OBJS=""
for f in $SRCS; do
  base="$(basename "${f%.*}")_$(echo "$f" | cksum | awk '{print $1}')"
  o="$OBJDIR/${base}.o"
  echo ">> compile $f"
  EXTRA=""
  if [[ "$f" == *webkit_proxy.m ]]; then EXTRA="-fno-objc-arc"; fi
  clang $CFLAGS $EXTRA -c "$f" -o "$o"
  OBJS="$OBJS $o"
done

echo ">> link $OUT"
clang -dynamiclib -arch $ARCH -mios-version-min=$MIN -isysroot "$SDK" \
  -fobjc-arc -O2 \
  $OBJS \
  -framework Foundation \
  -framework UIKit \
  -framework WebKit \
  -weak_framework Network \
  -framework SystemConfiguration \
  -framework CFNetwork \
  -framework Security \
  -framework CoreServices \
  -lz \
  -o "$OUT"

cp "$OUT" "build/LCProxyControl-${VER}.dylib"
echo ">> done: $OUT"
file "$OUT"
ls -lh build/LCProxyControl-*.dylib
