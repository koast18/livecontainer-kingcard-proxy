#!/bin/bash
# Build LCProxyConsole.ipa (control app, WKWebView -> 127.0.0.1:19092).
# No signing: LiveContainer signs on import.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN=15.0
ARCH=arm64
APP="build/LCProxyConsole.app"

mkdir -p build
rm -rf "$APP"
mkdir -p "$APP"

echo ">> compile ConsoleApp"
clang -target ${ARCH}-apple-ios${MIN} -isysroot "$SDK" \
  -fobjc-arc -O2 -DNDEBUG \
  -Wall -Wextra -Wno-unused-parameter \
  -I "$ROOT/ConsoleApp" \
  -framework UIKit -framework WebKit -framework Foundation -framework CoreGraphics \
  "$ROOT/ConsoleApp/main.m" \
  "$ROOT/ConsoleApp/AppDelegate.m" \
  "$ROOT/ConsoleApp/ViewController.m" \
  "$ROOT/ConsoleApp/AutoUpdater.m" \
  -o "$APP/LCProxyConsole"

echo ">> assemble .app"
cp "$ROOT/ConsoleApp/Info.plist" "$APP/Info.plist"
VER="$(cat "$ROOT/version.txt" | tr -d ' \r\n')"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$APP/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VER" "$APP/Info.plist" || true
printf 'APPL????' > "$APP/PkgInfo"
file "$APP/LCProxyConsole"

echo ">> package .ipa"
cd build
rm -rf Payload
mkdir -p Payload
cp -R LCProxyConsole.app Payload/
rm -f LCProxyConsole.ipa
zip -qry LCProxyConsole.ipa Payload
cp LCProxyConsole.ipa "LCProxyConsole-${VER}.ipa"
cd "$ROOT"
echo ">> done: build/LCProxyConsole.ipa"
ls -la build/LCProxyConsole.ipa build/LCProxyConsole-*.ipa
