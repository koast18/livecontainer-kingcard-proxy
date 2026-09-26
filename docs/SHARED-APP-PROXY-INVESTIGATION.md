# 共享 App 无法走王卡代理 —— 排查与修复记录

> 适用版本：v0.5.46 – v0.5.53
> 症状：LiveContainer 把某个 App 设为**共享应用**后，该 App 弹出「王卡代理」横幅但彻底无法联网；关闭该 tweak 后恢复直连。

本文固化三轮代码审查的结论：哪些机制已核实**正确**（不必重查）、发现并修复了哪些缺陷、以及**必须保留的不变量**。

---

## 1. 已核实正确的机制（排除项）

排查时不必再从这些地方找原因：

| 机制 | 位置 | 结论 |
|---|---|---|
| 配置路径推导 | `Tweak/Sources/LCProxyPaths.m` | console 与共享 App 解析出的 canonical **一致**，都是 `<AppGroup>/LiveContainer/LCProxy`；dylib 推导路径也一致（截断 `/Tweaks` 之前的部分）。**配置不会被找错地方。** |
| App Group 解析 | `LCProxySharedDataDirectory` + 上游 guest 内的 `containerURLForSecurityApplicationGroupIdentifier:` swizzle | swizzle 对 LC 自己的 group 返回 `lcAppGroupPath`（真实 App Group 根），两进程一致 |
| 转发器启动 | `KPKIngCore.c:2485 kp_forwarder_start` | bind `127.0.0.1` + 临时端口，无失败路径 |
| 转发器释放契约 | `KPKIngCore.c:2616 kp_forwarder_free` | 内部已判断 `stop() != 0` 就**故意泄漏、绝不 free**，不存在 UAF |
| 接受循环 | `KPKIngCore.c:2309 kp_forwarder_run` | 只在 `running=0` 或 listen fd 失效时退出，不会自行死亡 |
| 上游连接绕过 hook | `KPKIngCore.c:541 kp_connect_host` | `kp_socket_set_bypass(1)` 在 `getaddrinfo` **之前**设置（线程局部），正确避开自我递归 |
| override 实现 | `Tweak/ProxyCore/src/proxy_override.c` | 正确；在 `lcproxy_control_reload_config()` 时应用 |
| `lastAppliedShouldDirect == -1` | `LCProxyConfig.m:694` | 只是「未启用自动直连」的标记，**不是**卡住的 apply |
| WebKit 安装时机 | `Tweak/ProxyCore/src/webkit_proxy.m` | C 构造函数里指向 conf 的占位端口是**刻意的 fail-closed**，不是 bug（见 §3） |

---

## 2. 发现并修复的缺陷

| 版本 | 缺陷 | 位置 | 后果 |
|---|---|---|---|
| 0.5.46 | **转发器重建竞态**：并发 `applyConfig` 改写 `lastSettingsSignature`，使刚 `start` 成功的转发器被 `stop+free` 丢弃，`self.forwarder` 保持 NULL | `LCProxyKing.m applyConfig` | ObjC 层上次发布的 override 仍指向旧端口 → 所有连接被拒、**`lastError` 却为空**（极难排查） |
| 0.5.46 | 仲裁失利误清凭证：`Fenced`/`LockUnavailable`/`PersistenceFailed` 也 `clearForwarderKingState()` | `LCProxyKing.m finishRefreshWithState:` | 把瞬时跨进程竞争放大成持续断网，并触发 ~1s 一圈的取号抖动 |
| 0.5.46 | 转发器消失后无人重算 override | 新增 `LCProxyForwarderLifecycleChangedNotification` | override 悬空 |
| 0.5.47 | **移除跨进程锁/租约/心跳/围栏/毒标记**（约 20KB），改为追加式凭证日志 | `LCProxyKing.m` 全体 | 该套机制在多 LiveContainer 下制造持续断网；Q-Token 有效期 7200s、代理池 8h，为省几次取号做跨进程仲裁并不值得 |
| 0.5.48 | **控制台死锁**：`status` 持 `self.lock` 时调用 `loadState`（后者新增了 `self.lock`），NSLock 不可重入 | `LCProxyKing.m status` | `/api/config` 保存响应永不返回 → 控制台所有开关「无法保存」 |
| 0.5.49 | **更新期清空已签名 dylib**：`cleanOldDylibsIn:sharedTweaks keep:(sharedSigned ? asset : nil)`，新版未签名时 `keep=nil` 删光共享目录 | `ConsoleApp/AutoUpdater.m` | 每次更新后共享 App 与私有 App **同时失去可用 dylib** |
| 0.5.50 | 新增 dylib 加载记录 | `LCProxyControl.m` + `LCProxyServer.m` | 见 §4，这是唯一能确认「新 dylib 是否真的加载」的手段 |
| 0.5.51 | **无自愈**：`applyConfig` 重建分支先 `stopRefreshTimer`；若重建失败/被丢弃，进程既无转发器也无定时器/事件再触发 apply | `LCProxyKing.m refreshCredentialsWithForce:` 加看门狗 | override 永久指向死端口 → 「彻底断网且永不恢复」，只能切后台/重启 |
| 0.5.53 | **WebKit 可能永远停在占位端口**：`livecontainer_reload_webkit_proxy()` 挂在 `needsRuntimeReload` 上 | `LCProxyConfig.m applyRuntimeSnapshot` | 首次应用若 canonical conf 写入失败（`configReady == NO`），reload 永不发生 → **原生 socket 正常但 `WKWebView` 网页全挂**（浏览器类 App 的几乎全部流量） |

### 0.5.52 是一次错误改动（已完整撤回）

0.5.52 曾把「给 `defaultDataStore` 装代理配置」延后到主队列，理由是避免指向占位端口 18080。
**这是错的**：占位端口无人监听，正是刻意的 fail-closed；延后安装会让 WebKit 在启动窗口内**没有任何代理配置 → 退化为直连**，违反本项目「绝不直连」的核心不变量。
0.5.53 已完整撤回（相对 0.5.52 之前只保留一段警告注释），改用 `lastWebkitAppliedPort` 独立跟踪端口、变化时无条件重载。

---

## 3. 必须保留的不变量

改动以下区域前务必先核对：

1. **绝不直连。** 代理启用时任何失败路径都必须 fail-closed（丢包/拒绝），不得退化为直连，否则消耗通用流量。
2. **`127.0.0.1:18080` 是王卡模式的占位端口**（`LCProxyConfig.m:226-230`），不是 bug。真实端口由 C 核心的 per-process override 在运行时替换。指向它是安全的；**跳过安装反而危险**。
3. **`LCProxyKing` 的 `self.lock` 不可重入**：`loadState` / `credentialLogPath` / `appendCredentialRecord:` / `newestValidRecordFromLog` / `trimAppendLogAtPath:` / `appendSharedRefreshLogEntry:` 使用独立的 `cacheLock`，**绝不能在 `self.lock` 临界区内调用**。`Scripts/test_king_cache_logic.sh` 有双向锁序断言守护（0.5.48 的死锁就是这里破的）。
4. **追加式日志不加锁**：`kingcard-credentials.log` / `kingcard-refresh.log` / `dylib-loads.log` 用 `O_APPEND` 行级追加，跨进程安全；读取方取「最新且仍有效」的一条，损坏行跳过；任何 IO 失败静默忽略（纯诊断，绝不能影响转发）。
5. **KingCard 强制 `block_non_tcp`**：转发器只承载 TCP，必须始终丢弃 UDP/QUIC。
6. `.github/workflows/` 的构建门禁：`build_ios.sh` 会从 `version.txt` 重新生成 `Tweak/Sources/Version.h`，改版本只需改 `version.txt`。

---

## 4. 仍未验证的关键假设

**共享 App 进程实际加载的是哪个版本的 dylib —— 这是所有推断的前置条件。**

排查中反复卡在这一点：App Group 在「文件」应用里看不到，而 `/api/status` 只反映调用它的那个进程，因此无法确认修复是否真的生效。

0.5.50 起，dylib 构造时会把加载事实写入 App Group 的 `dylib-loads.log`：

```json
{"ts":..., "pid":..., "version":"0.5.53", "dylib":"<AppGroup>/LiveContainer/Tweaks/LCProxyControl-0.5.53.dylib", "bundle":"..."}
```

控制台 `/api/status` 的 `dylibLoadsTail` 返回该文件末尾 20 条。判读：

| 现象 | 结论 |
|---|---|
| 打开共享 App 后**没有**新增记录 | dylib 根本没被加载 |
| 有记录但 `version` 是旧版 | 新 dylib 没进 App Group Tweaks（「签名 + 重开控制台」这步没完成）|
| `version` 是最新版 | 修复已生效，应转向凭证/上游层（看 `kingRefreshLogShared` / `trafficLogTail`）|

---

## 5. `/api/status` 诊断字段速查

`GET http://127.0.0.1:19092/api/status`（每个加载了 dylib 的进程都会监听该端口；同一时刻通常只有一个进程持有它）。

| 字段 | 含义 |
|---|---|
| `dylibVersion` / `dylibPath` | 本进程加载的 dylib 版本与路径 |
| `dylibLoadsTail` | **所有进程**的 dylib 加载记录（含共享 App）|
| `king.forwarderPort` / `running` / `listenFdValid` | 本地转发器状态；`0`/`false`/`0` 表示转发器不在运行 |
| `proxyOverridePort` | proxychains 当前实际指向的端口 |
| `king.lastError` | 空字符串 = 无报错；否则是具体原因 |
| `king.lastForwarderLifecycle` / `forwarderDiscardCount` | 转发器被丢弃的原因与次数 |
| `kingRefreshLogShared` | **所有进程**的取号历史（含 pid）|
| `trafficLogTail` | **所有进程**的按连接转发结果（`route` / `status` / 字节数）|
| `settingsExists` / `proxychainsConfExists` / `proxyCount` | 配置层是否正常 |
| `credentialLogPath` / `credentialCacheCount` | 追加式凭证日志路径与内存缓存条目数 |
| `dataDirectories` | 本进程搜索配置的目录集合 |

**失败类型判读**：转发器返回 `502 Bad Gateway` = 转发器在跑但无可用凭证或上游失败；端口**无人监听**（连接被拒）= 转发器没起来。启用「请求流量日志」后 `trafficLogTail` 能直接区分这两者。

---

## 6. 更新流程（国内网络注意）

`raw.githubusercontent.com` 在国内基本不可达，直接用它作源地址会一直看到旧版本（商店显示的是本地缓存）。请用镜像：

```
https://gh-proxy.com/https://raw.githubusercontent.com/koast18/livecontainer-kingcard-proxy/master/AltStore/altstore-source.json
```

```
https://cdn.jsdelivr.net/gh/koast18/livecontainer-kingcard-proxy@master/AltStore/altstore-source.json
```

更新顺序（缺一不可）：

1. 更新 **LiveProxyConsole** 到最新版
2. 打开 console → 自动下载 `LCProxyControl-<ver>.dylib`
3. LiveContainer → **Tweaks 页签名** 该 dylib
4. **再重开一次 console**（这一步才会把已签名副本复制到 App Group 的 `LiveContainer/Tweaks`，共享 App 才能加载）
5. 重启共享 App

> 0.5.49 起，第 2 步下载的未签名新版**不再**清空共享/私有目录里已有的已签名 dylib，因此中途中断也不会让 App 失去代理。
