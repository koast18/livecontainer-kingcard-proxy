# 开源 iOS 网络应用兼容性调研报告

> 调研日期：2026-08-20  
> 目标：在 GitHub 上调研至少 10 个开源、成熟、star 数较高的 iOS 网络应用，判断本项目的 dylib + proxychains + 异步 connect 方案是否能与这些应用兼容，并达到“任意 App 走 HTTP/王卡代理且不卡动画”的预定目标。

## 1. 结论摘要

- 大多数使用 `URLSession` / `WebKit` 的 iOS 应用与本项目兼容度最高：
  - 我们的 fishhook 能拦截 `connect` / `connectx`
  - WKWebView 通过 `WKWebsiteDataStore.proxyConfigurations` 支持代理
  - HTTP/HTTPS TCP 流量可以稳定走 HTTP CONNECT 代理
- 使用 `dart:io` 的 Flutter 应用（如 PiliPlus）需要异步 connect 的本地回环 TCP 修复，`v0.5.20` 已解决。
- 使用自定义 TCP socket / MTProto / BitTorrent 的应用兼容性中等：
  - 多数 TCP 连接可被 proxychains 接管
  - 但 UDP/QUIC 需要 `block_non_tcp` 或可能绕过代理
- 使用 Tor 的应用存在“双重代理”风险，需要额外配置本地回环排除或专用 bypass。
- 总体判断：本项目的预定工作目标对这些主流开源 iOS 网络应用基本成立，但需要按应用网络栈做分级适配。

## 2. 调研对象

以下 star 数来自 GitHub API（2026-08-20）。

| # | 应用 | 仓库 | Star | 语言/技术 | 主要网络栈 |
|---|---|---|---|---|---|
| 1 | PiliPlus | bggRGjQaUbCoE/PiliPlus | ~17254 | Flutter/Dart | dart:io、dio、WebSocket |
| 2 | Firefox for iOS | mozilla-mobile/firefox-ios | ~13026 | Swift | URLSession、WKWebView、MPTCP |
| 3 | Signal iOS | signalapp/Signal-iOS | ~12200 | Swift | URLSession、WebSocket、自定义 socket |
| 4 | NetNewsWire | Ranchero-Software/NetNewsWire | ~10302 | Swift | URLSession |
| 5 | Telegram iOS | TelegramMessenger/Telegram-iOS | ~8868 | Swift/ObjC | MTProto、BSD socket、URLSession |
| 6 | WordPress iOS | wordpress-mobile/WordPress-iOS | ~3908 | Swift | URLSession、Alamofire 生态 |
| 7 | Wikipedia iOS | wikimedia/wikipedia-ios | ~3436 | Swift | URLSession、WKWebView |
| 8 | iTorrent | XITRIX/iTorrent | ~3211 | Swift | 原生 TCP/UDP socket、BitTorrent 协议 |
| 9 | Onion Browser | OnionBrowser/OnionBrowser | ~2653 | Swift | WKWebView、Tor、本地代理 |
| 10 | Nextcloud iOS | nextcloud/ios | ~2481 | Swift | URLSession |
| 11 | Element iOS | element-hq/element-ios | ~1840 | Swift | URLSession、WebSocket |
| 12 | Brave iOS | brave/brave-ios | ~1725 | Swift | URLSession、WKWebView |

## 3. 各应用详细分析

### 3.1 PiliPlus（Flutter Bilibili 客户端）

- 网络栈：`dart:io` 的 `HttpClient` / `dio`，默认 HTTP/1.1，可开启 HTTP/2；弹幕使用 WebSocket。
- 兼容性：高（v0.5.20 起）。
- 说明：PiliPlus 是发现并验证异步 connect 问题的关键应用。`v0.5.19` 使用 AF_UNIX socketpair 导致 Dart socket 语义异常；`v0.5.20` 改为本地回环 TCP 后，Dart 的 `getsockname/getpeername` 和 TCP option 语义恢复正常。
- 风险：若启用 HTTP/3/QUIC，UDP 会绕过代理，需要 `block_non_tcp`。

### 3.2 Firefox for iOS

- 网络栈：大量 `URLSession`，内嵌 `WKWebView` 加载网页，还支持 MPTCP。
- 兼容性：高。
- 说明：普通 HTTP/HTTPS 请求走 URLSession，会被 `connect`/`connectx` 钩子接管；网页加载走 WKWebView，本项目已实现 `WKWebsiteDataStore.proxyConfigurations`。
- 风险：Firefox 的 MPTCP 或部分网络框架路径可能使用 `connectx` 的特殊参数，我们的 `connectx` 钩子目前只处理简单场景。

### 3.3 Signal iOS

- 网络栈：`URLSession` 做 REST/媒体，WebSocket 做实时消息，部分底层 socket。
- 兼容性：高。
- 说明：URLSession 流量可代理；WebSocket 基于 TCP，也能被 proxychains 接管。
- 风险：Signal 有证书固定，但本项目不 MITM，只做 CONNECT 隧道，所以不受影响。

### 3.4 NetNewsWire

- 网络栈：以 `URLSession` 为主。
- 兼容性：高。
- 说明：RSS 抓取、图片加载均为标准 HTTPS，走 HTTP 代理顺畅。
- 风险：低。

### 3.5 Telegram iOS

- 网络栈：Telegram 使用自有 MTProto 协议，底层大量直接 socket；部分业务也使用 URLSession。
- 兼容性：中高。
- 说明：MTProto 的 TCP 连接如果走 BSD `connect`，可被 proxychains 接管；HTTP CONNECT 代理可以转发任意 TCP。
- 风险：Telegram 有自定义网络层、连接迁移和 MTProxy 逻辑，可能需要真机验证；UDP 部分会绕过。

### 3.6 WordPress iOS

- 网络栈：`URLSession`，历史上也使用 Alamofire 封装。
- 兼容性：高。
- 说明：标准 HTTPS API，代理友好。
- 风险：低。

### 3.7 Wikipedia iOS

- 网络栈：`URLSession` + `WKWebView`。
- 兼容性：高。
- 说明：API 请求和网页浏览都可覆盖。
- 风险：低。

### 3.8 iTorrent

- 网络栈：BitTorrent 使用原生 TCP/UDP socket，包含 tracker、DHT、peer 连接。
- 兼容性：中低。
- 说明：
  - TCP peer 连接理论上可走 HTTP CONNECT；
  - 但 BitTorrent 大量使用 UDP tracker / DHT / uTP，这些 UDP 流量会绕过 HTTP 代理；
  - 如果开启 `block_non_tcp`，UDP 会被丢弃，可能严重降低 BT 可用性。
- 结论：适合作为“TCP 可代理、UDP 需特殊处理”的边界案例。

### 3.9 Onion Browser

- 网络栈：基于 Tor，使用 WKWebView，并让 App 流量走本地 Tor SOCKS/HTTP 代理。
- 兼容性：低/需专门适配。
- 说明：
  - 本地 Tor 代理监听在 loopback，已被 `localnet` 排除，不会递归代理；
  - 但 Tor 进程自身连接 Tor 节点时如果也走我们 proxychains，会造成双重代理或连接失败；
  - 需要给 Tor 相关进程/连接加 bypass。
- 结论：不推荐作为默认测试目标，除非增加 Tor 排除规则。

### 3.10 Nextcloud iOS

- 网络栈：`URLSession`。
- 兼容性：高。
- 说明：文件上传下载、API 请求都是标准 HTTPS，代理友好。
- 风险：低。

### 3.11 Element iOS

- 网络栈：Matrix SDK，主要使用 `URLSession` + WebSocket。
- 兼容性：高。
- 说明：REST 和实时事件流都能被 TCP 代理覆盖。
- 风险：低。

### 3.12 Brave iOS

- 网络栈：与 Firefox iOS 类似，`URLSession` + `WKWebView`。
- 兼容性：高。
- 说明：适合验证浏览器类 App 的 WKWebView 代理能力。
- 风险：低。

## 4. 兼容性分级

| 级别 | 应用 | 说明 |
|---|---|---|
| 高 | Firefox、Signal、NetNewsWire、WordPress、Wikipedia、Nextcloud、Element、Brave | 标准 URLSession/WebKit，代理覆盖好 |
| 中高 | Telegram、PiliPlus | 自定义 socket / Flutter dart:io，需要异步 connect 修复，TCP 可代理 |
| 中低 | iTorrent | TCP 可代理，但 UDP/DHT 会绕过或需要 block_non_tcp |
| 低/需适配 | Onion Browser | Tor 自身流量需要专门 bypass，否则可能双重代理 |

## 5. 与本项目预定目标的匹配度

本项目预定目标：

1. 让 LiveContainer 内任意 App 的 TCP 流量走用户配置的 HTTP/王卡代理；
2. 避免代理握手阻塞 Flutter/Dart 等非阻塞网络栈导致动画卡顿；
3. 提供本地 Web 控制台、流量统计、WKWebView 代理支持。

调研结论：

- 目标 1：对大多数 URLSession/WebKit 应用成立。
- 目标 2：对 PiliPlus 这类 Dart/Flutter 应用，`v0.5.20` 的本地回环 TCP 异步 relay 已解决。
- 目标 3：Firefox、Brave、Wikipedia、Onion Browser 等 WKWebView 应用可通过现有 WKWebView proxy 配置覆盖。
- 边界：UDP/QUIC、BitTorrent DHT、Tor 等场景需要额外策略。

## 6. 后续建议

- 优先用以下应用做真机兼容矩阵：
  - PiliPlus（Flutter/dart:io）
  - Firefox iOS / Brave iOS（URLSession + WKWebView）
  - Nextcloud / WordPress（标准 URLSession）
  - Telegram（自定义 socket 高复杂度）
- 对 iTorrent 只验证 TCP peer 下载，明确 UDP 限制。
- 对 Onion Browser 增加 bypass 规则后再验证。
- 可在 CI 中增加“网络栈静态识别”脚本，扫描目标 App 源码中的 URLSession/WebKit/Socket/Flutter 使用情况，形成自动兼容性报告。

## 7. 参考

- GitHub 仓库地址见第 2 节表格。
- 本项目代码：
  - `Tweak/ProxyCore/vendor/proxychains-ng/src/libproxychains.c`
  - `Tweak/ProxyCore/src/async_proxy.c`
  - `Tweak/ProxyCore/src/webkit_proxy.m`
