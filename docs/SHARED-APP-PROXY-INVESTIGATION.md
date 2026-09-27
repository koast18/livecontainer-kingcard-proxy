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

### 2.11 v0.5.68：上游 connect 超时名不副实 → 槽位耗尽 → "一慢就全拒"

**真机数据（v0.5.67，共享 App `com.ld.TakeBrowser`，pid 96747）把所有其它可能性都排除干净了：**

| 字段 | 值 | 结论 |
|---|---|---|
| `chainPortMatches` / `chainProxyPort` = `forwarderPort` | `1` / `64179` = `64179` | 链端口正确 → §2.10 的缺口已修复 |
| `liveHttpPool` / `liveHttpsPool` | `4` / `4` | 池**非空** |
| `statPoolEmpty` | `0` | 无"清空型"故障 |
| `statRefreshCalls` | **`2`**（历史基线 1341） | 取号风暴彻底消失 |
| `lastRefreshSuccess` / `lastError` | `true` / `""` | 无错误 |
| `swallowedExceptions` | `[]` | 本 tweak 未出错 |
| `heartbeatChainRepairCount` | `0` | 自愈未被触发 |
| **`activeForwarderClients`** | **`64`** | ← **就是这里** |

`KP_FORWARDER_MAX_CLIENTS` 恰好是 **64**，而 `statHttpsConnects` 仅 **66**：
**64 个客户端槽位被占满且不释放 → 转发器对一切新连接回 503。**

**根因：`SO_SNDTIMEO` / `SO_RCVTIMEO` 不约束 `connect()`。**

`kp_connect_host` 原本这样"设置超时"：

```c
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
```

但这两个选项**只约束 `send`/`recv`，不约束 `connect`**（POSIX/BSD 语义）。阻塞 socket 上的
`connect` 会一直等到内核 TCP 握手超时（实测可达 **~75 秒**）。于是：

- 单个上游节点最坏占住 client 线程 **~75s**（而非预期的 10s）；
- 一次转发要试 4 个节点 → 最坏 **~300s**；
- 而槽位上限只有 **64**。

上游一慢，槽位立刻被"正在等待 connect"的线程占满，转发器从"慢"**退化为"对一切新连接回
503"** —— 也就是"完全无法上网"，而 `running` / `listenFdValid` / 凭证池 / 链端口在
`/api/status` 里**全部正常**，只有 `activeForwarderClients` 停在 64。

这同时解释了 `statRefreshCalls` 只有 2 的疑点：若连接是"试完 4 个节点后失败"，每次都会触发
刷新回调，应接近 66 次；只有 2 次说明线程**卡在池循环内部**（connect / recv 的长等待里），
根本没走到刷新那一步。

**修复。**

1. **新增 `kp_connect_with_timeout()`**：非阻塞 `connect` + `poll` + `SO_ERROR` 判定，
   完成后恢复阻塞模式（其余代码依赖阻塞 `send`/`recv` + `SO_RCVTIMEO` 的既有语义）。
   取不到原 fd 标志或 `F_SETFL` 失败时**退回阻塞 connect**，不引入新的失败模式。
   效果：单节点耗时上限从 ~75s 降到名义值 10s，槽位周转快约 7 倍。
2. **新增 `stat_client_rejections`** 并暴露为 `king.statClientRejections` —— 槽位耗尽此前
   在 status 里几乎不可见（只有 `activeForwarderClients` 停在 64 一条线索）。

> 仍待真机确认：本修复解决"一慢就全拒"的退化，但 `lastHealthCheckOk: false` 说明
> **单次探测也无法通过转发器** → 上游数据面（`116.130.x.x:8091` 集群）本身是否可用仍需
> 验证。注意最新一次取号返回 `bProxy=0`（此前多为 `1`）；该字段目前只记录、不参与决策。
> 另：`trafficLogTail` 里最后一次成功转发是约 27 小时前，且 `trafficLogging: false`，
> 因此**目前没有任何"私有 App 此刻正常"的直接证据**，同网 A/B 对照仍需补做。

### 2.10 v0.5.67：代理链端口陈旧导致「status 全绿却完全连不上」+ 心跳自愈

> **真机验证请直接照做 [`docs/REAL-DEVICE-VERIFICATION.md`](./REAL-DEVICE-VERIFICATION.md)**
> —— 那里有精确到 JSON 层级的字段路径、逐步升级流程与"一次定位方向"的判读表。
> 该清单里的字段名与层级已由 `Scripts/test_king_cache_logic.sh` 的守卫断言与源码保持同步。

**这是本轮定位到的、能解释"私有正常 / 共享失效"这一类症状的结构性缺陷。**

**机制。** `lcproxy_control_apply_proxy_override()`（把 per-process override 真正**覆盖到
代理链第一跳**）**只在 `lcproxy_control_reload_config()` 内部被调用**。而
`needsRuntimeReload` 在稳态下为假（签名未变、端口未变、路径未变），因此：

> **override 只在首次 apply 时被烘焙进代理链，之后再也没有任何机制校验
> "链里真正生效的端口"是否等于当前转发器端口。**

于是只要发生一次不匹配 —— 重载失败、链被清空（`reload_config` 会先把
`proxychains_proxy_count` 清零再重解析）、apply 被丢弃、C 构造函数在 ObjC 之前跑完 ——
链就会停在**别处**：

- conf 里的**占位端口 `127.0.0.1:18080`**（无人监听，刻意 fail-closed）→ **所有连接被拒**；
- 或链为空 → `lc_proxy_config_missing()` 为真 → `send`/`write` 对 direct-tracked socket
  直接返回 `ECONNREFUSED`。

而 `/api/status` 里 `proxyOverridePort`、`forwarderPort`、`running`、`listenFdValid`
**全部正常** —— 因为它们读的是"我们想用哪个端口"，**不是链里真正生效的端口**；
`lastError` 也为空。这正是"每个指标都健康，却完全无法联网"的成因，也解释了为什么此前
怎么查都只有"转发器健康 + 取号成功 + 转发不出去"这种矛盾现象。

**修复（自愈式，不依赖 ObjC 侧记账）：**

1. C 层新增 `lcproxy_control_get_applied_override_port()` —— 记录**真正被烘焙进链**的端口。
   所有提前返回路径（`pd == NULL`、`proxy_count == 0`、override 无效、`inet_pton` 失败）
   都**必须把它清零**，否则"已生效"的假象会把故障永久掩盖。
2. `LCProxyConfig` 在每次 apply 时比较它与当前转发器端口，不一致即 `chainPortStale`
   → 强制 `needsRuntimeReload` → 重载并重新烘焙。
3. **存活心跳每 5 秒校验一次链端口**并限频（`LCProxyKingChainRepairMinInterval = 20s`）
   请求 `requestRuntimeApplyAsync` 自愈 —— 否则故障只能靠"碰巧来一次前台/切网事件
   触发 apply"才可能恢复。同时`/api/status` 暴露 `chainProxyPort` / `chainPortMatches` /
   `heartbeatChainRepairCount`，让这类故障**一眼可见**。

副作用是正向的：若 conf 曾缺失/不可读（链为空 → `applied = 0`），心跳会每 20 秒重试一次
apply；apply 会重写 conf 并重载，**从而自动修复"配置文件缺失"这一类共享 App 故障**。

**验证。** C 侧逻辑由 `Scripts/test_proxy_override.sh` 真实执行（CI 在 macOS 上跑）；
本次为其新增了 10 余条断言，覆盖：占位端口 18080 必须被 override 覆盖、空链/NULL 链/
非法 IP 必须把 applied 清零、重新 apply 后 applied 必须更新。本地已用
`python -m ziglang cc -target x86_64-linux-gnu`（与 CI 相同的编译参数）确认测试与源码
**干净编译**；运行时断言由 CI 执行。

### 2.9 v0.5.66：崩溃加固（关键入口兜住 ObjC 异常）+ 暴露 swallowedExceptions

**动机。** 用户报告"打开共享 App 就闪退，说是没有 entitlement"。经核对：

- 本 tweak **没有任何 entitlement 查询代码**（全树只有一处 `NSClassFromString(@"LCSharedUtils")`），
  因此那条 entitlement 报错来自 LiveContainer 本身或其签名流程，不是本 dylib 主动查询的结果；
- 但"闪退"这件事本身必须从我们的角度彻底排除 —— 本 tweak 是**注入到第三方 App** 里的，
  **最高优先级是"绝不弄崩宿主"**。

**风险点。** 构造器运行在 **dylib 初始化阶段（dyld）**：此处抛出的 ObjC 异常无法被任何人
接住，会直接终止进程 —— 症状正是"一打开就闪退"，而且发生在任何日志/控制台起来之前，
用户看不到任何解释。`applyRuntimeSnapshot:` 同样危险：它跑在构造器路径
（`applyToRuntime` → `dispatch_sync`）、主线程通知回调与串行 `runtimeQueue` 上，异常一旦
穿透 GCD 边界就会终止进程。

**改动。**

1. `LCProxyControlConstructor` 整体包在 `@try/@catch` 中；
2. `applyRuntimeSnapshot:` 拆成"加固外壳 + `applyRuntimeSnapshotUnsafe:` 实现"，外壳
   只负责 `@try/@catch`；
3. 新增 `LCProxyRecordSwallowedException()` / `LCProxySwallowedExceptions()`：把被兜住的
   异常**同时**写入进程内环形缓冲（上限 8 条，独立 `NSLock`，绝不回头调用可能持锁的
   代码）和 App Group 共享日志（`src=exception`）；
4. `/api/status` 新增 **`swallowedExceptions`** —— **非空即说明我们的代码确实出过错**
   （但宿主 App 仍活着）。这是判断"闪退是否由本 tweak 造成"的唯一直接证据，且用户无需
   读取设备日志即可看到。

**设计原则（新增）**：tweak 里的异常处理不是"容错"，而是**安全边界**。这一步失败只是
代理不生效（fail-closed，绝不直连、不消耗通用流量），而进程必须活着。

**同时核对了路径与其它潜在清空点（结论：均无问题）**：

- 共享 App 的 dylib 位于 `<AppGroup>/LiveContainer/Tweaks`，`LCProxySharedRootFromDylibPath`
  反推出 `<AppGroup>/LiveContainer/LCProxy`，与 `LCProxySharedDataDirectory()` 结果一致
  → **用户最初的"路径不同"假设可以排除**；
- `credentialInputSignature` 只包含 `settings.json` 字段（所有进程读同一份），**不含进程
  相关信息**，因此不会"拒绝别的进程写的有效凭证"；
- 空代理池会返回 `success:NO`（`KPKIngCore`/`LCProxyKing` 第 1488-1491 行），因此
  **不存在"取号报 ok:true 但池是空的"**；
- 凭证日志有轮转（`LCProxyKingCredentialLogMaxLines = 64`），不会无限增长；
- 全树只有 3 处清空点（`loadCachedStateIntoForwarder`、`finishRefreshWithState` 失败分支、
  方法定义），且前两处已于 v0.5.65 改为 `leadTime:0`。

### 2.8 v0.5.65：修正 leadTime 语义混用（提前清空代理池）+ 撤回重复映像守卫 + 实时池大小

**(a) leadTime 语义混用 —— 与 §2.5 同族的"提前清空"。**

`stateHasFreshCredentials:` 原本把两个不同的问题混成一个判断：

| 问题 | 正确语义 |
|---|---|
| 是否需要**现在就去续期**？ | 前瞻性：要求凭证在未来 `LCProxyKingRefreshLeadTime`(2 分钟)内仍有效 |
| 这批凭证**此刻还能不能用**？ | 时点性：只要求"现在没过期"（`leadTime = 0`） |

原实现一律用 2 分钟余量，于是三个"时点性"调用点被误判：

1. **`loadState`** —— 从追加日志里挑**最新的可用记录**。在凭证有效期的最后 2 分钟里，
   最新记录被跳过；更旧的记录过期更早、同样被跳过 → 返回 `nil`。
   **每个凭证周期都会出现这样一次** 2 分钟窗口。
2. **`loadCachedStateIntoForwarder`** —— 拿到 `nil`/不新鲜就 `clearForwarderKingState`
   → **代理池被清空**。
3. **取号失败路径**（`finishRefreshWithState`）—— 一次取号失败就把"此刻仍有效"的凭证
   判为不可用并清空，即**一次网络抖动 = 立刻全断**。

三处合起来：距过期还有 1 分钟的凭证现在完全可用，却按"2 分钟内就要过期"被判为不可用而
清空，把"即将降级"变成"立刻全断"，要等下一次取号成功才恢复。转发器本身是 fail-closed
（绝不直连），所以继续用旧凭证最坏只是被上游拒绝，**不会**绕过王卡通道、不会消耗通用
流量 —— 提前清空严格更差。

修正：`stateHasFreshCredentials:matchingSettings:leadTime:` 显式区分两种语义；上述三个
时点性调用点传 `leadTime:0`；前瞻性调用点（`isReady`、`hasFreshCachedState`、
`ensureCredentialsReady`、续期快速路径）保留 2 分钟余量，因此"提前 2 分钟续期"的既有
行为完全不变。

**(b) 撤回 v0.5.63 的"重复映像守卫"（它比重复本身更危险）。**

每一份 dylib 都有**自己独立的一套 C 层全局变量**（proxychains 链、per-process override
端口、fishhook 后的 `connect`）。两份的 C 构造函数都会各自执行（不受 ObjC 层控制），且
后加载者通常赢下 `connect` 的符号解析。若让位的那份不执行
`lcproxy_control_set_proxy_override`，**它生效的 hook 就会回落到 conf 里的占位端口
`127.0.0.1:18080`（无人监听）→ 全部连接被拒** —— 把"能用但浪费"变成"彻底断网"。

两份都完整运行则自洽：各自的 hook 读各自的 override，指向各自重建的转发器；代价只是
多一个转发器/心跳/Web 服务与略高的取号频率。真正消除重复靠 `AutoUpdater` 未签名时不再
清空已签名副本（v0.5.49 起）+ 升级时手动清理旧 dylib，**不靠运行期让位**。

**(c) `/api/status` 新增实时池大小。** `liveHttpPool` / `liveHttpsPool` 直接回答
"**此刻**池子是不是空的"，比累计计数 `statPoolEmpty` 更直观 —— 池为 0 就是清空型故障
正在发生的直接证据。读取在 `cred_mutex` 下进行，锁序与既有代码一致
（`loadCachedStateIntoForwarder` 已是"持有 `self.lock` 时取 `cred_mutex`"）。

### 2.7 v0.5.63：删掉恒失败的重试循环 + 防重复加载

**(a) 删掉恒失败的重试循环。** 回调改为恒返回 -1（异步）之后，C 层的
`kp_forwarder_refresh_retry` 就**永远不可能成功**了，但三处调用点仍传
`(3, 500)` / `(2, 300)`：每次失败连接都要多调 2 次 hook、多睡最多 1000ms 才回 502。
这 1 秒是纯占 client 线程的，而 client 线程占用正是闪退的资源来源。现统一改为
`(1, 0)` —— 失败立刻回 502 释放线程，后台取号完成后后续连接自然恢复。

**(b) 防重复加载（构造器最先执行）。** LiveContainer 的 TweakLoader 会加载 Tweaks
目录里的**每一个** dylib 文件，而升级期间新旧两份 `LCProxyControl-*.dylib` 很容易共存。
实测出现过：`dylib-loads.log` 里**同一个 pid 先后加载了 0.5.57 与 0.5.56**。两个映像
同时进入进程的后果：

- 同一个 ObjC 类名被注册两次 → runtime 只能选其一，另一份的方法实现与实例变量被交叉
  使用 → **未定义行为 / 崩溃**（这是"打开共享 App 就闪退"的另一个可能来源）；
- 两份 `dispatch_once` 单例 → 两个转发器、两个存活心跳、两个本地 Web 服务。

构造器现在先做幂等检查：若运行期已注册的 `LCProxyConfig` 不是本映像的类，说明另一份已
生效，本映像整体让位（不记录加载、不注册观察者、不启服务、不建转发器）。用
`NSClassFromString` 返回 nil 时保持原行为，不改变现有正常路径。

> 操作提示：升级时请在 LiveContainer 的 Tweaks 页删除旧版 `LCProxyControl-*.dylib`，
> 确保目录里只留一份，避免依赖该守卫。

### 2.6 v0.5.61：把被动刷新改成「零阻塞 + 限频 + 异步」（最终形态）

v0.5.60 修对了"强制刷新不得清空在用凭证"，但**给并发刷新加了一个 20 秒阻塞等待**，
这是一次严重失误，直接导致「打开共享 App 就闪退」。

**为什么阻塞是致命的**：被动刷新回调 `LCProxyKingRefreshHook` 跑在 **C 层 client 线程**
上（`KPKIngCore.c: kp_forwarder_refresh → fw->refresh_fn`），而
`kp_forwarder_refresh_retry` 对**每个失败请求**最多重试 3 次、client 线程上限
`KP_FORWARDER_MAX_CLIENTS=64`。于是单次 20s 等待被放大成
**20s × 3 次 × 最多 64 线程** —— 线程与栈资源瞬间耗尽，进程被系统直接杀掉。

**最终设计（简单、稳健、省资源）**：把被动刷新收敛为一个**信号**，而不是一次调用：

| 环节 | 做法 |
|---|---|
| C 层回调 | 只投递信号，**永远返回 0**（含义：本轮重试到此为止，不要再重试） |
| 限频 | 距上次真正取号 < `LCProxyKingMinRefreshInterval`(60s) 或已有取号在飞 → 直接返回 |
| 执行 | 真正的取号 `dispatch_async` 到后台队列，**调用线程立即返回，永不阻塞** |
| 凭证 | 取号过程中**不清空**在用凭证；拿到新的再覆盖 |

效果：取号从"实测 1341 次 / 45 秒内 30 次"降到**最多 1 次/分钟**；client 线程不再被占住；
失败的连接照常返回 502（可接受），但不会雪崩、不会闪退。正常/过期场景仍由 2 分钟主动
定时器负责（提前 2 分钟续期），被动路径只是兜底。

**同时按"省资源"要求精简了存活心跳**：原先每 5 秒 `settingsSnapshot`（读一次
`settings.json`）判断"王卡是否启用"；现改为读内存里的 `desiredForwarderRunning`
（由 `applyConfig` 维护，语义等价），心跳因此**零磁盘 I/O**。

**v0.5.62 的三处进一步精简（同一目标：更简单、更省资源、恢复更快）**

1. **回调改为返回 -1（原为 0）**。C 层把 0 解释为"刷新成功，立刻用新凭证重试"，于是
   `kp_forwarder_refresh_retry` 返回 0 后 `kp_handle_client` 会 `goto https_retry`
   再跑**整整一轮**池内代理尝试（最多 4 节点 × (10s 连接 + 10s 接收)）。而取号是异步的，
   那一轮时凭证池并未变化，纯属浪费。返回 -1 表示"本次重试到此为止"，C 层最多做一次
   500ms 退避就回 502。
2. **被动刷新间隔 60s → 20s**：正常续期由 2 分钟定时器负责，被动路径只在"凭证提前失效 /
   池内节点全挂"时兜底，20s 让恢复更及时，同时把上游压力限制在 ≤3 次/分。
3. **心跳不再催取号**。心跳只做它独有的、别人做不到的事：在没有任何外部事件时发现
   "转发器缺失 / override 失配"并就地修好。凭证续期已由 2 分钟定时器与"连接失败回调
   （限频 20s）"完全覆盖；而 `requestBackgroundRefresh` 走 `force` 分支会**绕过缓存命中
   判断**，若心跳调用它，稳态下就变成每 20s 一次完整网络取号（3 次/分、180 次/小时），
   纯属无谓。移除后**稳态零被动取号**。

**这轮确立的设计原则**（后续改动都要遵守）：

- 凡是运行在 C 层线程 / client 线程上的回调，一律**只投递信号，不做事**；所有 I/O、
  锁等待、网络往返都必须发生在自己的后台队列上。违反这条的代价不是慢，而是把整个
  进程拖死。
- 回调的**返回值也有代价**：返回"成功"会让 C 层再跑一整轮代理尝试，必须按最坏情况估算。
- 周期任务（心跳/定时器）必须**只读内存、不催发网络**，否则稳态下就是持续的后台负载。

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

#### 2.5.1 已验证的完整因果链（含一处此前的误读更正）

对 v0.5.59 的实测数据做算术核对后，整条链**逐环节可验证**：

`kp_forwarder_clear_king_state` 会把 `http_pool` / `https_pool` 的计数置为 **0**
（`KPKIngCore.c:2471-2472`）。而 v0.5.59 的 `refreshCredentialsWithForce:` 开头有一行
`if (force) [self clearForwarderKingState];`（已确认存在于 `v0.5.59` tag，当前 master
为 0 处）。于是：

1. 任何一次强制刷新 → **代理池立即变空**（此时取号还要 1~2 秒网络往返）；
2. 连接到达 → `https_pool_count = fw->https_pool.count` 读到 **0** →
   `for (attempt = 0; attempt < 0; ...)` **循环体一次都不执行** → 直接落到
   `kp_forwarder_refresh_retry(fw, 3, 500)` → **3 次 hook 调用**；
3. 这解释了实测的那个比值：`statRefreshCalls(1341) ÷ statHttpsConnects(477) ≈ 2.8 ≈ 3`；
4. 而旧版 hook 内部是**同步强制取号**，它又会清空一次池 → 37 个并发连接使清空窗口
   几乎连续覆盖 → **任何连接都找不到可用代理 → 永远无法联网**；
5. `lastRefreshSuccess:false`、`lastHealthCheckOk:false`（探测同样遇到空池）、
   `statHttpRequests:0` 全部由此解释。

**误读更正**：`trafficLogTail` 里只有十几小时前的旧记录，我一度当成"连接全部失败"的
证据。实际上实测快照中 **`trafficLogging:false`** —— 该开关关闭时 `kp_traffic_log`
直接返回，**根本不会写任何新记录**。因此空日志不是失败证据，请勿据此判断。

**如何一眼区分两类"无法联网"**（v0.5.64 起提供 `statPoolEmpty`）：

| `statPoolEmpty` | 含义 |
|---|---|
| 高（且 `statRefreshCalls / statHttpsConnects ≈ 重试次数`）| **完全没有可用凭证/池** —— 即本条这一类（凭证被清空/从未装载）|
| 0，但连接仍失败 | 池内有节点但都被拒 → 上游或凭证失效，是**另一类**问题 |

其中"池为空时 for 循环体不执行"这一步是 C 层的既有结构；v0.5.60 移除了强制刷新开头的
清空，使池不再被无谓清空；v0.5.64 补上该计数器，让这一类问题下次可被直接确认。

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
8. **运行在 C 层 / client 线程上的回调只投递信号，绝不做事。** 被动刷新回调
   `LCProxyKingRefreshHook` 跑在 client 线程上，且 `kp_forwarder_refresh_retry` 会对
   每个失败请求重试最多 3 次、client 线程上限 64 —— 任何阻塞或耗时操作都会被放大
   数十倍，直接把进程拖死（0.5.60 的闪退即由此而来）。回调必须：零阻塞、限频
   （`LCProxyKingMinRefreshInterval`）、异步执行，并返回 0 让 C 层停止重试。
9. **绝不为了取新凭证而先清空在用凭证。** 取号需要 1~2 秒网络往返，清空会让这段时间
   内所有连接一起失败，失败又触发新的取号 → 正反馈雪崩（0.5.60 的根因）。正确做法是
   "先用旧的继续服务，拿到新的再覆盖"。

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
