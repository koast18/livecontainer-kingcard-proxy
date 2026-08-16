#!/bin/bash
# Build LiveProxyConsole.ipa (control app, WKWebView -> 127.0.0.1:19092).
# No signing: LiveContainer signs on import.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN=15.0
ARCH=arm64
APP="build/LiveProxyConsole.app"

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
  -o "$APP/LiveProxyConsole"

echo ">> assemble .app"
cp "$ROOT/ConsoleApp/Info.plist" "$APP/Info.plist"
VER="$(cat "$ROOT/version.txt" | tr -d ' \r\n')"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$APP/Info.plist" || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VER" "$APP/Info.plist" || true
printf 'APPL????' > "$APP/PkgInfo"
file "$APP/LiveProxyConsole"

echo ">> package .ipa"
cd build
rm -rf Payload
mkdir -p Payload
cp -R LiveProxyConsole.app Payload/
rm -f LiveProxyConsole.ipa
zip -qry LiveProxyConsole.ipa Payload
cp LiveProxyConsole.ipa "LiveProxyConsole-${VER}.ipa"
cd "$ROOT"
echo ">> done: build/LiveProxyConsole.ipa"
ls -la build/LiveProxyConsole.ipa build/LiveProxyConsole-*.ipa
