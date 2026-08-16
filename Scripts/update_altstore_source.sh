#!/bin/bash
# Regenerate AltStore/altstore-source.json from version.txt.
# Usage: ./Scripts/update_altstore_source.sh [owner/repo]
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${1:-koast18/livecontainer-kingcard-proxy}"
VER="$(cat version.txt | tr -d ' \r\n')"
TAG="v${VER}"
cat > AltStore/altstore-source.json <<JSON
{
  "name": "LCProxy 源",
  "identifier": "com.lcproxy.source",
  "sourceURL": "https://raw.githubusercontent.com/${REPO}/master/AltStore/altstore-source.json",
  "apps": [
    {
      "name": "LCProxy 控制台",
      "bundleIdentifier": "com.lcproxy.console",
      "developerName": "koast18",
      "version": "${VER}",
      "versionDate": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
      "versionDescription": "LCProxy 控制台：LiveContainer 任意 App HTTP 代理开关、非 TCP 丢弃、10 分钟粒度蜂窝流量统计。首次打开自动下载 dylib。",
      "downloadURL": "https://github.com/${REPO}/releases/download/${TAG}/LCProxyConsole-${VER}.ipa",
      "localizedDescription": "LiveContainer 内任意 App 走 HTTP 代理的控制台 IPA。依赖 LCProxyControl dylib（自动下载到 LiveContainer Tweaks 目录），支持代理开关、丢弃非 TCP、蜂窝网络上传/下载流量统计（10 分钟时段）。",
      "iconURL": "https://raw.githubusercontent.com/${REPO}/master/AltStore/icon.png",
      "tintColor": "2E7D32",
      "size": 17758,
      "versions": [
        {
          "version": "${VER}",
          "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
          "downloadURL": "https://github.com/${REPO}/releases/download/${TAG}/LCProxyConsole-${VER}.ipa",
          "localizedDescription": "更新版本 ${VER}"
        }
      ]
    }
  ],
  "news": []
}
JSON
echo "Updated AltStore/altstore-source.json for ${VER}"
