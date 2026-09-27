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

| 0.5.54 | **同步退役转发器把 runtime apply 卡死 20 秒**（数据形态高度吻合）：重建分支先 `self.forwarder = NULL` 摘除旧的，再**同步** `kp_forwarder_stop` + `kp_forwarder_free`（stop 等待 client 线程，而它们可能正卡在同步取号网络等待里；grace 上限 10s，free 内部还会再 stop 一轮）| `LCProxyKing.m applyConfig` | ① `self.forwarder` 已是 NULL → `forwarderPort=0` / `running=false`；② 旧监听 fd 已关闭但 ObjC 层上次发布的 override 仍指向它 → **所有连接被拒**；③ 期间任何新 apply（看门狗每 5s、前台恢复、NWPath）全部堵在 `lifecycleLock` 上排队 → **彻底无法联网且永不恢复**。实测形态：`forwarderPort=0` / `proxyOverridePort=<旧端口>` / `desiredForwarderRunning=true` / `forwarderDiscardCount=0` / `lastForwarderLifecycle=""`（信号发生在埋点之前）|
| 0.5.54 | ⚠️ **该修复已撤回（见 §2.1）**：把重建改成"先启动新的 → 原子替换 → 异步回收旧的" | `LCProxyKing.m applyConfig` | 与"签名 dylib 后控制台一打开就黑屏"同时出现；0.5.56 整段撤回至 0.5.53 的顺序 |
| 0.5.55 | 生命周期通知未限频：转发器持续启动失败时 `notify → apply → notify` 紧循环烧 CPU | `LCProxyKing.m notifyForwarderLifecycle:` | 加 5s 限频（保留）|
| 0.5.56 | 撤回 0.5.54 的重建顺序改动（见 §2.1）| `LCProxyKing.m applyConfig` | 修复"签名 dylib 后控制台一打开就黑屏" |
| 0.5.57 | **accept 循环无界阻塞 → `pthread_join` 永久挂起 → 整个 runtime apply 永久卡死**（永久断网的根因）| `KPKIngCore.c kp_forwarder_run` / `kp_forwarder_stop` | 见 §2.2 |
| 0.5.58 | 紧急自愈：绕过被堵死的 runtimeQueue 直接重建转发器并钉住 override | `LCProxyKing.m healMissingForwarderDirectly` | 无论 applyConfig 因何卡住都能恢复 |
| 0.5.59 | **健康转发器在强刷路径上被无谓 teardown**（每次都制造一次 `pthread_join` 阻塞窗口）；新增**独立存活心跳** | `LCProxyKing.m applyConfig` / `startLivenessHeartbeat` | 见 §2.3 |

### 2.3 v0.5.59：消除无谓 teardown + 独立存活心跳

**(a) 复用健康转发器。** 原 `alreadyRunning` 判据含 `!forceRestart`，而强刷路径
（`forceRestartForwarderWithSettings:`）覆盖了回前台、`didBecomeActive`、NWPath 变化、
健康检查失败等**所有**恢复入口。也就是说每次切前后台/切网都会 teardown 一次转发器，
每次 teardown 都要走 `kp_forwarder_stop → pthread_join`（等 client 线程退出，它们可能
正卡在同步取号的网络等待里）。这条路径一旦不能及时返回，就会堵住持有 `lifecycleLock`
的 runtime apply。

`forceRestart` 的原始意图是清掉挂起/切网后残留的陈旧半开连接 —— 这一点已由
`applyRuntimeSnapshot` 在调用前的 `lcproxy_async_close_all()` + `shutdownActiveClients()`
完成，**与转发器对象本身无关**。因此把判据从"是否要求重启"改为"现役转发器是否真的
健康"（`running == 1 && listen_fd_valid == 1`）：健康就复用并就地重装凭证、顺手
`kp_forwarder_shutdown_clients` 清掉旧连接；不健康才重建。这样每次切前后台/切网都不再
中断转发，也消除了绝大部分 teardown 窗口。

**(b) 独立存活心跳（`startLivenessHeartbeat`）。** 这是整套自愈里**唯一不依赖任何可能
被堵住的队列/锁**的一环：不经过 `LCProxyConfig` 的串行 `runtimeQueue`、不取
`lifecycleLock`、也不依赖刷新定时器（`applyConfig` 一开头就 `stopRefreshTimer`，卡死时
它不会复活）。每 5s 检查一次"王卡已启用时，已发布的 per-process override 是否真的指向
一个在监听的本地转发器"，不一致就**就地**修复：

| 心跳发现 | 动作 |
|---|---|
| 转发器缺失/未监听（`localForwarderPort <= 0`）| `healMissingForwarderDirectly`：绕过 runtimeQueue 重建并钉住新端口 |
| 转发器在跑但 `overridePort != forwarderPort` | 重新 `set_proxy_override` + `reload_config` |
| 转发器健康但凭证陈旧（`!hasFreshCachedState`）| 催促一次 `refreshCredentialsAsync`（内部有去重）|

第二种正是实测故障的核心形态：`proxyOverridePort` 恒等于旧端口 53464 而该端口已无监听，
所有连接被拒 → "彻底无法联网"。心跳的价值在于**它的正确性不依赖对"卡在哪里"的推断**。

心跳事件会写入 App Group 的 `kingcard-refresh.log`（`src=heartbeat-heal` /
`heartbeat-repin` / `emergency-heal`），因此一次复现即可从任意控制台看到自愈全过程。

### 2.5 v0.5.60：强制刷新清空凭证引发的正反馈雪崩（真正的"转发不出去"根因）

**这是最终定位到的根因。**

`applyConfig` 的存活心跳把转发器修健康之后（实测 `forwarderPort=58603`、
`running=true`、`listenFdValid=1`、`proxyOverridePort` 与之一致、
`heartbeatHealCount=0`），**故障依然存在**，只是形态变了 —— 数据给出了决定性线索：

| 观测 | 值 |
|---|---|
| 取号次数 | `statRefreshCalls=1341`；45 秒内 **30 次完整取号成功** |
| 取号结果 | refreshLog 全部 `ok:true`（GUID/Token/代理池都拿到了）|
| 却 | `lastRefreshSuccess=false`、`lastHealthCheckOk=false`、`statHttpRequests=0` |
| 并发 | `activeForwarderClients=37` |

**"取号次次成功却什么都转发不出去"** 指向一个自我维持的正反馈，而不是单点故障：

```
某个请求失败
  → C 层触发强制刷新（kp_forwarder_refresh_retry，每请求最多 3 次）
  → refreshCredentialsWithForce 开头执行 clearForwarderKingState
  → 取号需要 1.1~2.1s 网络往返，这期间转发器**没有任何凭证**
  → 其它 36 个并发请求因此也失败，每个又触发自己的强制刷新（再次清空）
  → 回到第一步，永不收敛
```

三个放大因子：

1. **`if (force) [self clearForwarderKingState];`** —— 强制刷新在拿到替代品**之前**就
   销毁了正在服务的凭证，把一次瞬时失败变成 1~2 秒的全量失败。
2. **C 层按请求重试** —— `kp_forwarder_refresh_retry(fw, 3, 500)`（每个失败请求 3 次）
   和 CONNECT 隧道无上游数据时的 `kp_forwarder_refresh_retry(fw, 2, 300)`。
3. **`if (self.refreshing) return NO;`** —— 并发刷新被当作"刷新失败"上报给 C 层，
   于是重试的每一次都放大成一次新的强制取号。

**为什么私有 App 正常、共享 App 失效**：这是**并发度**问题。共享 App 常被用于高并发
场景（实测 37 个并发客户端），雪崩阈值被跨过；私有 App 并发低，单次清空造成的附带
失败很少，形不成闭环。同一份代码、同一套路径解析，差别只在负载。

**修复**：

- **不再在强制刷新开始时清空凭证** —— 先用旧凭证继续服务，取到新凭证后覆盖。
  三个上游获取点都以 `force` 为强制条件，因此强制重新取号的语义不受影响。
  仅在旧凭证确实不可用时（`finishRefreshWithState` 的 freshness 检查）才清空，
  且那是最后手段。
- **合并并发刷新** —— `if (self.refreshing)` 不再 `return NO`，而是等待在飞的刷新结束
  （有界，`LCProxyKingRefreshCoalesceTimeout=20s`）并返回其**真实结果**。一次取号服务
  所有等待者，重试不再放大成风暴。等待只按 50ms 轮询 `self.lock`，不嵌套任何其他锁。

> 说明：v0.5.57/0.5.58/0.5.59 修的是"转发器对象消失/override 悬空/被无谓 teardown"，
> 都是真实缺陷且必须保留；但它们只是让转发器**对象**恢复健康，并未触及本条"凭证在
> 刷新期间被清空"的逻辑，因此单独修它们不足以恢复转发。本版本与它们叠加后才完整。

### 2.4 私有 App 正常、转共享后失效 —— 结构性差异排查结论

对照上游 `LiveContainer/LiveContainer@4dbe0f9` 逐处核对了 `isSharedBundle` 影响的
**全部**分支：

| 位置 | 私有 | 共享 |
|---|---|---|
| `LCBootstrap.m:347` tweak 目录 | `<LC_HOME>/Documents/Tweaks` | `<AppGroup>/LiveContainer/Tweaks` |
| `LCBootstrap.m:429-433` guest HOME | `<LC_HOME>/Documents/Data/Application/<uuid>` | `<AppGroup>/LiveContainer/Data/Application/<uuid>` |
| `LCBootstrap.m:525` `hookDlopen` | 可启用 | **强制关闭** |
| `LCBootstrap.m:859` `LCLoadTweaksToSelf` | 私有 Tweaks | App Group Tweaks |

实测数据证明这些差异**都不是**本次故障的原因：
- `dylibLoadsTail` 显示共享 App 进程确实从 App Group Tweaks 加载了当前版本 dylib；
- `settingsExists` / `proxychainsConfExists` 均为 true、`proxyCount == 1`，说明配置层
  在共享 App 里完全正常（canonical 目录与 console 完全一致）。

因此**共享 App 与私有 App 在本项目的数据目录解析上是一致的**（已由代码逐行核对 +
实测双重确认）。真正的差别是**进程生命周期**：共享 App 由 LiveContainer 经
`openApplication` 重新拉起宿主进程来启动，切换/恢复事件更频繁，因而更容易走进
"teardown 阻塞 → runtimeQueue 永久卡死"这条路径。§2.2/§2.3 的修复针对的正是这条路径，
与 App 是私有还是共享无关。

> 仍未排除的一个外部变量：实测快照中 `"cellular": 0`（当时在 Wi-Fi）。王卡免流本身是
> 蜂窝侧能力，`kingAutoDirectOnNonCellular: false` 时仍会走王卡转发器。若"私有正常"
> 与"共享失效"当初是在**不同网络**下观察的，请在同一网络下复测以排除该变量。

### 2.2 v0.5.57：accept 无界阻塞导致永久断网（真正的根因）

**机制**：`kp_forwarder_run` 原实现在循环里直接 `accept()` 阻塞等待，依赖
`kp_forwarder_stop` 里的 `shutdown()` + `close()` 把它唤醒。但 **Darwin 上对监听
socket 调用 `shutdown()` 返回 `ENOTCONN`，`close()` 也不会唤醒 `accept()`** ——
上游注释里"macOS 无副作用"说的正是这件事。于是当没有新连接到来时：

1. accept 线程永远阻塞在 `accept()`；
2. `kp_forwarder_stop` 的 `pthread_join(fw->thread, NULL)` **永久阻塞**；
3. 而 `kp_forwarder_stop` 是在 `applyRuntimeSnapshot → [king applyConfig:]` **持有
   `lifecycleLock`** 时被调用的，此时 `self.forwarder` 已被置 NULL；
4. `applyConfig` 永不返回 → `applyRuntimeSnapshot` 永不返回（override 永不更新）→
   `runtimeQueue`（串行）上后续**每一次** apply（看门狗每 5s、前台恢复、NWPath 变化）
   全部堵死。

**为什么没有自愈**：5s 看门狗虽然一直在触发（它走 `refreshCredentials` 路径，不在
被堵的 `runtimeQueue` 上），但它触发的 `requestRuntimeApplyAsync` 同样排在被堵死的
队列后面，因此永远轮不到。

**实测形态完全吻合**（`forwarderPort=0` / `proxyOverridePort=53464` 从不更新 /
`desiredForwarderRunning=true` / `forwarderDiscardCount=0` /
`lastForwarderLifecycle=""` / `lastError` 被看门狗反复覆盖为空以外的固定值）。

**修复**：
- accept 前先用 `poll(listen_fd, POLLIN, KP_FORWARDER_ACCEPT_POLL_MS=500)` 做**有界
  等待**，超时即回到循环顶部重新检查 `running` / `listen_fd`；`join` 因此有界（≤500ms）；
- `kp_forwarder_stop` 改为 **先 `pthread_join`、再 `close`** 监听 fd（原来先 close，
  会关闭一个仍被 accept 线程 poll/accept 的 fd，属未定义行为）。

这样即使"唤醒"机制在某平台上失效，接受线程也会自行按时退出，`applyConfig` 不可能
再被永久卡住。

**未采取**：给 ObjC 层加"绕过被堵 runtimeQueue"的防御（例如把 apply 改成非串行或加
超时）。C 层修好后该场景不应再出现，而增加并发复杂度会重新引入竞态（0.5.54 的教训）。

### 2.1 v0.5.54 的重建顺序改动已撤回（v0.5.56）

0.5.54 把重建顺序改为"先在锁外创建并启动新转发器 → 再原子替换 → 最后交专用串行队列异步回收"，用以消除重建期间 `self.forwarder` 为 NULL、而上次发布的 override 仍指向已关闭旧端口的窗口（§2 中 0.5.54 那行的机制分析）。

**但它与"签名 dylib 之后控制台一打开就黑屏"同时出现。** 判断依据：

- 未签名时 LiveContainer 不加载 dylib，控制台正常；**签名后 dylib 真正加载，才黑屏** → 问题出在 dylib 加载/构造阶段；
- 设备实测数据表明 **0.5.53 的 dylib 在 console 进程（pid 90508）加载正常，且 `/api/status` 可读**（`serverPort: 19092`）→ 0.5.53 的控制台可用；
- 因此嫌疑集中在 0.5.54 唯一的行为改动上。

v0.5.56 **整段撤回**该改动，恢复 0.5.53 的顺序（`先摘除引用 → 同步 stop/free → 再新建`）。撤回后行为差异仅剩 `LCProxyKing.m` 的限频与死代码：`LCProxyConfig.m` / `LCProxyControl.m` / `LCProxyServer.m` / `webkit_proxy.m` / `ConsoleApp` 相对 0.5.53 **逐字节相同**。

`retireForwarder:` 与 `forwarderReaperQueue` 保留但**不再被调用**（保存这段分析），并在源码中标注了停用原因。

**重新启用前必须先拿到崩溃/卡死日志**（LiveContainer 的崩溃记录，或控制台可复现时的系统日志），确认黑屏病因不是它。注意：撤回同时也使 §2 中 0.5.54 那行描述的"200ms–20s 悬空 override 窗口"重新存在 —— 这是为恢复可用控制台而做的取舍；真正修好它需要在 C 层把 `kp_forwarder_stop` 拆成"快速关闭监听 fd"与"慢速排空 client 线程"两段。

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
7. **绝不在 runtime apply 路径上同步销毁转发器。** `kp_forwarder_stop` 要等 client 线程退出（它们可能阻塞在同步取号 hook 的网络等待里，单次最长 15s；grace 上限 10s），`kp_forwarder_free` 内部还会再 stop 一轮 —— 合计最长 20s。重建必须"先启动新的、再原子替换、最后异步回收"，退役回收不得重新获取 `lifecycleLock`。`Scripts/test_king_cache_logic.sh` 有对应断言守护。

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
