# LiveProxy Control for LiveContainer

依赖 [`ios-proxy-dylib`](https://github.com/xiaobright/dsh-anchored-standard)（实际使用其中的 `livecontainer-proxychains`）的 HTTP 代理能力，为 LiveContainer 内任意 App 提供一个控制用 IPA 和配套 dylib。

## 功能

- **代理开关**：随时启用/禁用 HTTP 代理，不修改 `proxychains.conf` 也能立即生效。
- **丢弃非 TCP**：开关 `block_non_tcp`，禁止 UDP/QUIC/ICMP/raw socket 绕过代理。
- **代理地址配置**：在控制台修改 `http host port`，保存后写回共享 `proxychains.conf`。
- **上游模式**：支持“直连（无代理）”、“自定义代理”、“王卡代理”三种模式。
- **王卡代理**：王卡模式内置本地转发器：
  - 自动请求 `GUID,TOKEN`，优先经王卡代理隧道取号，失败后自动回退直连取号。
  - 转发 CONNECT 时自动附加 `Q-GUID` / `Q-Token` 头，并按参考订阅附带 `User-Agent`（okhttp/3.11.0 风格）提高免流识别成功率。
  - 取号失败或上游拒绝时自动刷新凭证并重试。
  - 每 10 分钟自动周期刷新凭证，避免 `Q-GUID` / `Q-Token` 过期。
  - 可选“非蜂窝网络自动直连”：开启后，当前网络为非蜂窝（Wi-Fi/其他）时自动切到直连，否则走王卡代理；关闭时始终走王卡代理。
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
- `build/LiveProxyConsole.ipa` / `LiveProxyConsole-<version>.ipa`

两个产物均**故意不签名**，由 LiveContainer 导入/签名时用你导入的证书处理。

## 使用

1. 将 `LiveProxyConsole.ipa` 导入 LiveContainer 并打开。
2. 首次打开会自动下载 dylib 到 LiveContainer `Tweaks` 目录，按提示退出并重新打开。
3. 重新打开后进入控制台：
   - 直连：选择“直连（无代理）”，打开「启用代理」后所有流量不经过上游代理。
   - 自定义代理：选择“自定义代理”，填写代理地址/端口，打开「启用代理」。
   - 王卡代理：选择“王卡代理”，可修改上游地址/端口与取号接口，打开「启用代理」；保存后会自动取号并每 10 分钟自动刷新。可在王卡设置中开启“非蜂窝网络自动直连”。
4. 被代理的 App 也需在 LiveContainer 中加载 `LCProxyControl.dylib`（通常配置为全部 App 注入）。

## AltStore 源

在 AltStore/SideStore 中添加：

```
https://raw.githubusercontent.com/koast18/livecontainer-kingcard-proxy/master/AltStore/altstore-source.json
```

该地址固定不变；更新版本时只需更新仓库中的 `AltStore/altstore-source.json` 并打新 tag，Actions 会自动构建并发布 Release 资产。

> 配置读取：dylib 只会读取自己管理的 `<LC Documents>/LCProxy/proxychains.conf`，不会扫描系统其他 `proxychains.conf`，避免配置互相干扰。

## 流量统计说明

- 统计基于 dylib hook 的 `send/recv/sendto/recvfrom/sendmsg/recvmsg/read/write`，只统计蜂窝网络下非 loopback 的 socket 流量。
- 10 分钟一个时段，保留最近 14 天。
- 每个进程把自身统计写入 `<LC Documents>/LCProxy/stats/<bundle>.json`，控制台汇总。
- 精确度足够日常查看；系统私有网络栈/WKWebView 子进程等无法 100% 覆盖，与 ios-proxy-dylib 的代理覆盖范围一致。

## License

GPLv2（proxychains-ng 与派生代码），GCDWebServer 为 Apache-2.0。
