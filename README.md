# LCProxy Control for LiveContainer

依赖 [`ios-proxy-dylib`](https://github.com/xiaobright/dsh-anchored-standard)（实际使用其中的 `livecontainer-proxychains`）的 HTTP 代理能力，为 LiveContainer 内任意 App 提供一个控制用 IPA 和配套 dylib。

## 功能

- **代理开关**：随时启用/禁用 HTTP 代理，不修改 `proxychains.conf` 也能立即生效。
- **丢弃非 TCP**：开关 `block_non_tcp`，禁止 UDP/QUIC/ICMP/raw socket 绕过代理。
- **代理地址配置**：在控制台修改 `http host port`，保存后写回共享 `proxychains.conf`。
- **蜂窝流量统计**：
  - 按 10 分钟时段（bucket）记录上传/下载字节。
  - 只在检测到蜂窝网络（无 Wi-Fi）时累计。
  - 每个 App 进程独立落盘，控制台汇总所有 App。
- **本地 Web 控制台**：dylib 内嵌 HTTP 服务（`127.0.0.1:19092`），控制 IPA 用 WKWebView 打开。
- **首次自动安装 dylib**：控制 IPA 首次打开会从 GitHub Release 下载 `LCProxyControl-<version>.dylib` 到 LiveContainer 的 `Tweaks` 目录，签名后重启即可。

## 仓库结构

```
ConsoleApp/         控制 IPA（WKWebView → 127.0.0.1:19092，首次自动下载 dylib）
Tweak/Sources/      控制 dylib 的 ObjC 模块（配置、统计、Web 服务、共享路径）
Tweak/ProxyCore/    基于 ios-proxy-dylib 的 proxychains 核心 + 流量统计 hook
Tweak/Vendor/       GCDWebServer（Apache-2.0）
Resources/          控制台单文件 HTML
Scripts/            构建脚本
AltStore/           AltStore 源
.github/workflows/  GitHub Actions 构建发布
```

## 构建

需要 macOS + Xcode + Node.js：

```bash
./Scripts/build_all.sh
```

产物：

- `build/LCProxyControl.dylib` / `LCProxyControl-<version>.dylib`
- `build/LCProxyConsole.ipa` / `LCProxyConsole-<version>.ipa`

两个产物均**故意不签名**，由 LiveContainer 导入/签名时用你导入的证书处理。

## 使用

1. 将 `LCProxyConsole.ipa` 导入 LiveContainer 并打开。
2. 首次打开会自动下载 dylib 到 LiveContainer `Tweaks` 目录，按提示退出并重新打开。
3. 重新打开后进入控制台，配置代理地址并打开「启用代理」。
4. 被代理的 App 也需在 LiveContainer 中加载 `LCProxyControl.dylib`（通常配置为全部 App 注入）。

## AltStore 源

在 AltStore/SideStore 中添加：

```
https://raw.githubusercontent.com/koast18/livecontainer-kingcard-proxy/master/AltStore/altstore-source.json
```

该地址固定不变；更新版本时只需更新仓库中的 `AltStore/altstore-source.json` 并打新 tag，Actions 会自动构建并发布 Release 资产。

## 流量统计说明

- 统计基于 dylib hook 的 `send/recv/sendto/recvfrom/sendmsg/recvmsg/read/write`，只统计蜂窝网络下非 loopback 的 socket 流量。
- 10 分钟一个时段，保留最近 14 天。
- 每个进程把自身统计写入 `<LC Documents>/LCProxy/stats/<bundle>.json`，控制台汇总。
- 精确度足够日常查看；系统私有网络栈/WKWebView 子进程等无法 100% 覆盖，与 ios-proxy-dylib 的代理覆盖范围一致。

## License

GPLv2（proxychains-ng 与派生代码），GCDWebServer 为 Apache-2.0。
