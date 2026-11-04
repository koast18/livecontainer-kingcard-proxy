# 未解决问题交接文档：共享 App 王卡断网 / 长时间后台后断网

> **读者**：接手的外部模型或工程师（下称"你"）。
> **作者**：历次排查的沉淀（本项目 316 个提交，版本号从 v0.1.0 走到 v0.5.81）。
> **仓库**：`C:\Users\koast18\work\livecontainer-kingcard-proxy`（origin = `koast18/livecontainer-kingcard-proxy`）
> **基线**：`HEAD = 99cb94d`（v0.5.80）+ 一份**未提交**的 v0.5.81 工作区改动（见 §15）
> **本文档写作时间**：2026-11-04（北京时间）
> **本文行号**均基于上述基线；工作区改动会略微移动行号，请以函数名定位而不是死记行号。

---

## 0. TL;DR —— 你现在最该做的事

问题的核心特征是：**每个可观测指标都"正常"，却完全连不上。**

历史上已经有 **30 多次**"看起来合理、实际错误"的推测性修复（含 2 次把情况改得更糟、3 次完整撤回）。
因此本文档的第一条纪律是：

> **先测量，再改代码。任何没有现场数据支撑的改动，都不要提交。**

你现在应该做的是（顺序不要颠倒）：

0. ⚠️ **先读 §0.1**：`/api/status` 自 v0.5.75 起因**嵌套 NSLock 自死锁**而永不返回 —— 所有诊断端点基本全死。
   不修它，你拿不到任何真机数据（用户也无法手动导出 App Group 日志）。
1. 读 §3 确认你要解决的问题的**准确定义**（A：共享 App 断网；B：长时间后台后断网）。
2. 读 §9 的假设清单（H1–H6），这些是**尚未验证**的候选根因；H1 是目前最有解释力的。
3. 读 §11 的取证协议，让用户在**同一网络**下做一次 A/B（私有 App vs 共享 App）取证，把 JSON 回传。
4. 只有拿到 §10 里那几个决定性的字段之后，才动代码；动代码时严格遵守 §12 的不变量。

---

## 0.0 ✅ v0.5.81 已落地的修复（代码级证明 + 宿主测试；**仍需真机确认**）

> 下面每一条都是"代码里可以直接证明的缺陷"，不是推测。真机现场仍按 §11 取证确认。

| # | 缺陷（证据） | 对应问题 | 修法 | 守卫/测试 |
|---|---|---|---|---|
| 1 | **H0**：`status` 持 `self.lock` 时再次 `[self.lock lock]`（NSLock 不可重入）→ 控制台每 5s 轮询一次即**永久自锁**，进而心跳/续期/重建全部停摆 → 凭证过期后必断网 | A + B | 锁内 retain 快照 → 锁外探测 → release；同法改了 `applyConfig`/`publishRouteForSettings`/`selfCheck`/`syncFetchGuid`（后者原来**未 retain 也 release**，会扣掉别人的引用让 stop 提前 free） | `test_foreground_reload_logic.sh`：解析每个方法的持锁区，禁止嵌套加锁、禁止持锁探测、禁止持锁调用会再取锁的方法；对 HEAD 版本会失败 |
| 2 | **accept 循环看不见失效的监听 socket**：`kp_forwarder_run` 对 `poll` 的 `POLLERR/POLLHUP/POLLNVAL` 和 `accept` 的**任何**失败都 `continue` → socket 被回收后 100% CPU 空转、`running` 恒为 1 → `isRunning`/`listen_fd_valid` 永远"健康" | B | 新增 `listener_error`：错误 revents / 致命 errno 判死并退出循环；资源类 errno（EMFILE/ENFILE/ENOBUFS/ENOMEM）只退避不判死；`ECONNABORTED` 连续 64 次才判死。`kp_forwarder_is_running`/`listen_fd_valid`/`probe_local` 都据此报告；`running` 与 stop/free/retain 语义**不变** | `test_forwarder_stop.c::test_dead_listener_detected`：`dup2` 把监听 fd 换成非 socket；旧核心 `running=1 err=0`（失败），新核心约 0.5s 内判死且 stop 正常 |
| 3 | **H2**：心跳用只看内存标志的 `isRunning` | B | 心跳改为锁外 retain + 真探活；连续 2 次失败（或 `listener_error≠0` 立即）→ 自愈 | 同上静态守卫 |
| 4 | **自愈形同虚设**：`healMissingForwarderDirectly` 在 `self.forwarder != NULL` 时直接丢弃新建实例 → 对"对象还在、监听已死"永远修不好 | B | 新增 `healForwarderDirectlyReplacing:suspect`：锁内只替换"缺失的或就是被判死的那一个"，旧实例交回收队列异步 stop/free；同时把 `publishedForwarderPort` 跟到新端口（否则 `syncFetchGuid` 去连死端口） | `test_king_cache_logic.sh` |
| 5 | **H3/B3**：挂起期间 dispatch 定时器（mach 时间）不走，恢复后续期最多再等 120s，而凭证可能早已过期 | B3 | 心跳比较墙钟间隔（>15s 即视为刚从挂起恢复）→ 立即**非强制**刷新（缓存仍新鲜则只是本地命中，不发网络请求）。**不依赖生命周期通知**，所以对 LiveProcess（H1）同样有效 | 静态守卫 |
| 6 | 锁外读转发器未 retain（可 UAF）：`performHealthCheck`（探活最长约 5s）、`appendSharedStatusSnapshot`（读统计） | 稳定性 | 都改为 retain/release | 静态守卫 |

新增诊断字段：`king.listenerError`、快照 `listenerError`（0 正常；>0 errno；-1 poll ERR/HUP/NVAL；-2 连续 ECONNABORTED）；
共享日志新 `src`：`heartbeat-resume`（检测到挂起恢复）、`heartbeat-heal` 文案含"监听已失效"。

**真机确认时看**：`listenerError`、`heartbeatHealCount` 是否在后台/熄屏恢复后增长、`kingcard-refresh.log` 中是否出现 `heartbeat-resume` 后紧跟取号成功。

---

## 0.1 🚨 先修这个：`/api/status` 自 v0.5.75 起**死锁**（**v0.5.81 已修**，见 §0.0）

> 如果你只读一段，就读这段。这个 bug 让 **v0.5.75–v0.5.80 的全部诊断端点在真机上永远不返回**，
> 很可能就是“用户反复报断网、我却只能靠猜”的直接原因。

**位置**：`Tweak/Sources/LCProxyKing.m` 的 `status`（基线行号 1956–2060）。

```objc
- (NSDictionary *)status {
    ...
    [self.lock lock];                 // ← 行 1966：外层已持锁
    NSMutableDictionary *d = ...
    d[@"listenFdValid"] = ...;
    {
        [self.lock lock];             // ← 行 1976：同一把 NSLock **再次上锁**
        kp_forwarder *fwForProbe = self.forwarder;
        [self.lock unlock];           // ← 行 1978：只解开内层这一次（但内层根本进不来）
        d[@"listenProbeOk"] = ...;
    }
    ...
    [self.lock unlock];               // ← 行 ~2059
}
```

`_lock = [[NSLock alloc] init]`（`LCProxyKing.m:176`）—— **NSLock 不可重入**。
同一线程第二次 `lock` 会**永久阻塞**（不是抛异常，也不会有任何日志）。

**后果（逐条展开）**：

1. `/api/status`、`/api/diag`、`GET /api/config`、`POST /api/config`、`POST /api/king/refresh`
   全部经过 `LCProxyServer.m:166` 的 `d[@"king"] = [[LCProxyKing shared] status]` → **全部挂死不返回**。
2. 控制台的 `loadStatus()/loadDiag()/saveConfig()` 全部 `await` 不到结果：
   界面上大部分字段永远停在 `…`，保存提示不出现（但 `saveSettings` + `applyToRuntime`
   在挂死**之前**已经执行 → 用户会感觉“保存似乎有用、读取不正常”—— **与用户反馈完全吻合**）。
3. 每次轮询（5s）都会新增一个**永久阻塞**的 GCDWebServer 处理线程 → 线程缓慢泄漏。
4. **唯一幸存**：`GET /api/selfcheck`（`LCProxyServer.m:492-501` 自己拼字典，
   不经过 `status`）—— 它是目前**唯一**能拿到真实数据的端点。
5. 自 v0.5.71 起的跨进程快照（`kingcard-status.log`）由**心跳**写，不经过 `status`，**没受影响**。
6. 🚨 **连带灾难**：死锁线程**永久持有 `self.lock`**，而 `heartbeatTick`（`LCProxyKing.m:437`）、
   `applyConfig`（`:252`）、`refreshCredentialsWithForce`（`:1498` 起）、`loadCachedStateIntoForwarder`
   都要取这把锁。于是：**只要用户打开过一次控制台（或其 App 内的 19092 页面）**，那个进程里：
   - 存活心跳停摆（不再发现“转发器缺失 / override 失配 / 链端口陈旧 / 路由未发布”）；
   - 2 分钟主动续期与“连接失败 → 被动刷新”全部停摆；
   - 转发器重建/回收停摆。
   短期内还能用旧凭证继续转发（client 线程不需要这把锁），**等到 `Q-Token`（默认 7200s）
   或代理池过期，就必定断网** —— 而且恰好是“所有字段都正常却连不上”（字段根本就不可能再更新）。
   这与问题 B（“用了一段时间 / 长时间后台之后断网”）的形态**高度吐合**。

**引入者**：`090e911`（v0.5.75，“修复后台/熄屏永久断网”）。那段代码本意是“读 `self.forwarder` 要加锁”，
但**外层锁已经持有**，于是变成自死锁。静态守卫没抓住它（守卫检查的是“锁序/不得在 lock 区内调用 loadState”，
不是“同一把锁嵌套”）。

**修复（一行）**：删掉内层 `[self.lock lock] / [self.lock unlock]`，直接读 `self.forwarder`
（外层锁已保护），并且**不要在持锁区做网络探测**（`kp_forwarder_is_listening` 是一次 loopback connect，
应先取出 `fw` 引用、解锁后再探测——这是既有 `selfCheck` 的写法，照抄即可）。

**上机验证方法（30 秒）**：

```bash
# 在 App 内用浏览器/控制台访问，若 30 秒无任何响应 = 死锁成立
curl -m 30 -sS http://127.0.0.1:19092/api/status -o /dev/null -w '%{http_code} %{time_total}\n'
curl -m 30 -sS http://127.0.0.1:19092/api/diag   -o /dev/null -w '%{http_code} %{time_total}\n'
curl -m 60 -sS http://127.0.0.1:19092/api/selfcheck | head -c 400   # 这一个应该能返回
```

**注意**：修好这个**不会**修好断网；它只让后续取证变为可能。
但它会改变“证据来源”：在 0.5.75–0.5.80 上，**任何引用 `/api/status` 字段的结论都无来源**。

---

## 1. 环境与工具注意事项（先读这一节，能省你几个小时）

### 1.1 这是一台 Windows 机器（Git Bash）

- 工作目录：`C:/Users/koast18/work/livecontainer-kingcard-proxy`
- **没有 macOS / Xcode**：`Scripts/build_ios.sh` 与所有需要 Xcode 的步骤**在这台机器上跑不了**。
- **没有连着的 iPhone**：真机数据只能由用户手工回传（§11）。不要假装能连设备。
- Git Bash 自带的是 **MinGW gcc**（`/c/MinGW/bin/gcc`），**缺 POSIX 头**（`netinet/in.h`），
  编译这些 C 测试会直接 `fatal error`；`python -m ziglang` 也**未安装**。

✅ **可用的办法：WSL 里跑（已实测通过）**

```bash
# WSL 发行版 Ubuntu-24.04 已存在，内含 gcc 13 / python3
wsl -d Ubuntu-24.04 -- bash -lc '
  cd /mnt/c/Users/koast18/work/livecontainer-kingcard-proxy &&
  find Scripts -name "*.sh" -exec sed -i "s/\r$//" {} + &&   # ★ 不转 LF 会报 set: pipefail: invalid option name
  bash Scripts/run_all_tests.sh'
```

- `Scripts/test_proxy_override.sh` 已在 WSL 实跑通过（`proxy override tests OK`）；其余脚本未逐个验证。
- 把 `Scripts/*.sh` 从 CRLF 转成 LF **不会**让 git 看到内容变化（仓库 `core.autocrlf=true`，`git diff` 为空）。
- 需要 xcrun 的步骤会自动跳过；纯静态守卫（grep 断言）在 Git Bash 里就能跑：

```bash
bash Scripts/test_king_cache_logic.sh
bash Scripts/test_foreground_reload_logic.sh
bash Scripts/test_shared_app_paths.sh
```

若确实想在本机编译 C（不推荐）：`pip install ziglang`，然后按 `Scripts/test_proxy_override.sh` 里的
`-DGN_*` 参数用 `python -m ziglang cc -target x86_64-linux-gnu` 编。

### 1.2 用 `gh` 访问 GitHub：先自检，再决定走不走代理 `192.168.2.100:7893`

用户说明的代理是 **HTTP 代理**（不是 SOCKS）：`192.168.2.100:7893`。

⚠️ **实测记录（2026-11-04 21:00 +0800，本机）**：

| 路径 | 结果 |
|---|---|
| `gh api user` **直连** | ✅ 成功（`koast18`，已登录，scopes: gist/read:org/repo/workflow） |
| `curl -x http://192.168.2.100:7893 https://api.github.com` | ❌ `CONNECT` 返 `200 Connection established` 后 **TLS 握手失败**（重试 2 次仍失败） |
| `192.168.2.100:7891`（同时开着，可能是 socks） | ❌ socks5 尝试被对端关闭 |
| `192.168.2.100:7890 / 7897` | 端口未开 |

结论：**先跑自检，不要默认设代理**（设了反而会把本来能用的直连弄坏）。

```bash
# 自检（不设任何代理）
gh api user --jq .login

# 若直连失败，再试代理（Git Bash）：
export HTTP_PROXY=http://192.168.2.100:7893
export HTTPS_PROXY=http://192.168.2.100:7893
export ALL_PROXY=http://192.168.2.100:7893
# ★ 必须排除本机与内网，否则代理会把 127.0.0.1 / 192.168.x.x 的流量也转走（诊断端点全废）
export NO_PROXY=127.0.0.1,localhost,::1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12
gh api user --jq .login
```

只对单条命令用代理（不改全局环境，更安全）：

```bash
HTTPS_PROXY=http://192.168.2.100:7893 gh api repos/LiveContainer/LiveContainer/commits?per_page=5
git -c http.proxy=http://192.168.2.100:7893 fetch origin
curl -x http://192.168.2.100:7893 -sSI https://api.github.com | head -1
```

注意事项：

- **不要把 token 打印到聊天里**。永远不要执行 `gh auth token`。
- `gh` 已登录（keyring），无需交互登录；若某次失效，让用户自己 `gh auth login`，不要试图带着 token 跑命令。
- 本项目自己的远程仓库也是 GitHub，`git push/pull/fetch` 同样受上面网络状况影响。
- `raw.githubusercontent.com` 即使能通也不适合当下载源；项目已约定用镜像（见 §14）。

### 1.3 上游 LiveContainer 源码已经在本地（不用 gh 也能读）

```
C:\Users\koast18\work\LiveContainer-src   # origin = https://github.com/LiveContainer/LiveContainer.git
HEAD = 4dbe0f9 "Update litehook: add arm64e_x1 dsc suffix"
```

**这是排查"共享 App"的核心资料**。必须读的上游文件：

| 文件 | 为什么要读 |
|---|---|
| `LiveContainerSwiftUI/Models/LCAppModel.swift`（`uiIsShared`，约 250–310 行） | 共享 App 在 multitask 下会被交给**另一个** LiveContainer 实例（`LCLaunchExtensionScheme` / `getContainerUsingLCScheme`） |
| `LiveContainer/LCBootstrap.m`（`isSharedBundle`，33/295/347/429/525/859 行） | 共享与私有的**全部**分支差异（tweak 目录、guest HOME、hookDlopen、数据目录） |
| `LiveContainer/LCBootstrap.m:672` | `isLiveProcess = [lcAppUrlScheme isEqualToString:@"liveprocess"]` |
| `LiveProcess/main.m:59` | `setenv("LP_HOME_PATH", getenv("HOME"), 1)` —— 只有 appex 宿主才设置 |
| `LiveContainer/Tweaks/Dead10ccFix.m:37-44` | 上游自己就是按 `isLiveProcess` 在 **`NSExtensionHost*`** 与 **`UIApplication*`** 两个通知族之间切换 |
| `TweakLoader/TweakLoader.m:41,126` | TweakLoader 会加载目录里**每一个** `.dylib`，只跳过 `.disabled` |

用 `gh` 的价值在于：确认上游**是否有更新的提交**改变了上述行为（尤其 `uiIsShared` 的启动路径、
`isLiveProcess` 的判定、TweakLoader 的加载规则），以及是否有相关 issue：

```bash
HTTPS_PROXY=http://192.168.2.100:7893 gh api 'repos/LiveContainer/LiveContainer/commits?per_page=10' \
  --jq '.[] | "\(.sha[0:7]) \(.commit.author.date) \(.commit.message|split("\n")[0])"'
HTTPS_PROXY=http://192.168.2.100:7893 gh search issues --repo LiveContainer/LiveContainer "liveprocess background"
HTTPS_PROXY=http://192.168.2.100:7893 gh api 'repos/LiveContainer/LiveContainer/contents/LiveProcess/main.m' --jq .sha
```

### 1.4 其他必须知道的约定

- 用户用**中文**反馈，习惯直接给现象（"断网了""闪退了""读不到配置"），并且会**准确指出我的错误**。
  历史上每次用户纠正都是对的 —— 不要急于反驳，先去核对。
- 用户明确要求过："**不要再做推测性修改，先拿数据**"（见提交 `d783649`）。
- 不要擅自改版本号、发版、推 tag、改 AltStore 源（这些会影响真机升级链路）。
- 不要把 `127.0.0.1:18080` 当 bug（见 §12 不变量 2）。

---

## 2. 一句话背景

这是一套 **LiveContainer（iOS 上的"容器里的容器"）** 插件：

- `LiveProxyConsole`（一个 IPA）：本地控制台，`WKWebView` 打开 `http://127.0.0.1:19092`；
- `LCProxyControl-<ver>.dylib`：注入到 LiveContainer 内的**任意 guest App**，做两件事：
  1. 用 **proxychains（fishhook 掉 connect/connectx/sendto…）** 把该进程的 TCP 流量导到本地转发器；
  2. 用**王卡（联通"王卡免流"）Queen/King 协议**从运营商换 `Q-GUID / Q-Token / Q-Key` 和一池
     `queen_http` / `queen_https` 代理节点，本地转发器再用这些凭证把 TCP 转发到运营商节点。
- 核心不变量：**绝不直连**（fail-closed），因为直连会消耗用户通用流量。

---

## 3. 要解决的问题的准确定义

### 3.1 问题 A：App 设为"共享 App"后，tweak 看起来没有代理成功 → 直接断网

用户原话（多轮，汇总）：

> "任何 app 在 livecontainer 中切换为共享 app 时，这个 tweak 看起来就无法正确地代理它的网络了，表现为**直接断网**。"
>
> "私有 App 能用、共享 App 不能用。"（反复出现，是本项目最长寿的症状）
>
> "横幅还显示王卡代理，但完全上不了网。"
>
> "打开**共享 App 就闪退**，说是没有 entitlement。"（另一条线，见 §6.5）

**判定标准（务必区分，这是历史上误诊的主要来源）**：

| 现象 | 含义 |
|---|---|
| 连接被**立即拒绝**（RST / ECONNREFUSED） | 转发链路问题：override 指向了没人监听的端口，或转发器没起来（A1 类） |
| 转发器回 **502** | 转发器在跑，但**无可用凭证/代理池**，或上游拒绝（A2 类） |
| 一直转圈/超时 | 上游隧道黑洞、半开连接（A3 类） |
| 域名解析失败 | 路由未发布 / 链为空（A4 类） |

历史实测里 A1、A2、A3、A4 **都出现过**，而且可以同时出现 —— 这正是"每次修好一个点又冒出另一个点"的原因。

### 3.2 问题 B：App 长时间在后台（或熄屏）之后，也会断网

用户原话（两轮）：

> "切换到后台或熄屏后**都断网了**。"（提交 `d8cebed` 引述）
>
> "偶尔**很长时间**应用在后台之后，也会出现的断网问题。"（本次请求）

**注意这里有三个强度不同的场景，历史上被混为一谈，你必须分开取证**：

| 场景 | 期望行为 | 已知风险 |
|---|---|---|
| B1 后台几十秒～几分钟，回前台 | 回前台立刻恢复（重建转发器 / 重发路由） | 恢复事件是否被投递；监听 socket 是否失效；"健康"判据是否够强 |
| B2 熄屏（可能几小时） | 同上 | 同上 + 进程可能被挂起（socket/timer 全部停摆） |
| B3 后台**很久**（> Q-Token 有效期 7200s，或 > 代理池 `expireEpoch`） | 回前台必须**重新取号**并重发路由 | 挂起期间 2 分钟续期定时器**不跑**；恢复后若取号/续期路径没被触发 → 旧凭证过期 → fail-closed → **断网，而且所有"运行状态"字段仍然正常** |

B3 是本次请求新强调的部分，**在历史修复里没有专门为它设计过**（§9 H3）。

### 3.3 用户历次反馈清单（原话/现象 → 当时怎么理解的 → 落点）

这张表是把散落在提交信息、文档、对话里的用户反馈汇总起来，防止遗漏或误归类。

| # | 用户反馈（原话/现象） | 当时理解 | 现在看是否已解决 |
|---|---|---|---|
| 1 | “任何 app 切换为共享 app 时…无法正确代理…表现为**直接断网**” | 配置路径/转发器/override 问题 | 部分修（§5.1/5.2），**仍复现** |
| 2 | “私有 App 能用、共享 App 不能用” | 以为是路径/签名/并发度差异 | 路径已排除；并发度未验证；**仍是主要未解现象** |
| 3 | 切后台/熄屏后“**都断网了**” | 监听 socket 失效 + 路由未发布 | 0.5.74/0.5.75 修了两处，**但 v0.5.75 又引入死锁（§0.1）** |
| 4 | “**很长时间**在后台之后，也会出现断网” | 之前只当 B1/B2 处理 | ❌ **未专门处理**（B3 / H3） |
| 5 | 打开共享 App 就闪退 + entitlement 报错 | 怀疑本 tweak 查了 entitlement | 已排除（§6.5）；真因是新旧 dylib 共存（0.5.72 修） |
| 6 | “打开控制台本身，配置读取似乎不正常，但保存似乎有用” | 配置读写链路问题 | 0.5.76 做了全链路诊断 —— **但诊断端点自 0.5.75 就死锁了（§0.1）**，这才是真正原因 |
| 7 | “从**共享 App 的浏览器**打开 19092 也看不到配置” | 共享 App 路径/权限问题 | 19092 被别的进程占着→静默 headless（0.5.81 修）+ 死锁（§0.1） |
| 8 | “**并没有多个 App 同时运行**” | 推翻了"多进程各自重领 GUID"的解释 | 解释已撤回（§6.6），**不要再拿它当结论** |
| 9 | “先在浏览器里测一下 / 不要在代码里猜” | 要求先测量 | 已建 `/api/diag`、`/api/selfcheck`、`statusTail`（但被 §0.1 拖累） |
| 10 | “Alook / Speedtest 大流量约 10 秒就闪退” | 线程/栈资源耗尽 | 另一条线（`docs/ALOOK-SPEEDTEST-CRASH-RESEARCH.md`），与本问题正交 |

> 注：表中 #1 #2 #3 #4 是同一个现象的四个侧面，不要当四个独立问题去修。
> 尤其不要为了让 #1“看起来好了”而牺牲不变量（如改为直连）。

---

## 4. 架构速览

### 4.1 流量链路（王卡模式）

```
guest App 进程
  connect()/connectx()  ──[fishhook]──►  lc_proxy_config（proxychains 链）
                                           │  第一跳被 per-process override 改写成
                                           │  127.0.0.1:<ephemeral forwarder port>
                                           ▼
                                   本地转发器 kp_forwarder
                                   （每进程一个临时端口；18080 只是 conf 占位符）
                                           │  用凭证 Q-GUID/Q-UA2/Q-Token/Q-Key 构造
                                           │  HTTP 分头 或 HTTPS CONNECT 合并头
                                           ▼
                                   运营商节点 116.130.x.x:8091 (queen_http/queen_https)
                                           │
                                           ▼
                                        目标站点
```

关键点：**"链里实际生效的端口"（chainPort）** 与 **"我们想用的端口"（overridePort）** 是两件事。
历史上最致命的故障就是两者不一致，而 `/api/status` 曾经只显示后者（见 §5.1 v0.5.67）。

### 4.2 关键组件

| 文件 | 职责 | 规模 |
|---|---|---|
| `Tweak/Sources/LCProxyControl.m` | dylib 构造器：加载即生效、弹横幅、**订阅生命周期通知** | 268 行 |
| `Tweak/Sources/LCProxyConfig.m` | 配置读写、`applyRuntimeSnapshot`（唯一 runtime apply 入口）、NWPathMonitor、WKWebView 代理 | 903 行 |
| `Tweak/Sources/LCProxyKing.m` | 王卡状态机：取号、凭证日志、转发器生命周期、存活心跳、健康自愈、`/api/status` 的 king 段 | 2069 行 |
| `Tweak/Sources/KPKIngCore.c` | 本地转发器（C）：`kp_forwarder_*`、上游连接、CONNECT 构造、统计、自检 | 3132 行 |
| `Tweak/ProxyCore/src/proxy_override.c` | per-process override + `lcproxy_control_get_applied_override_port()`（**真正烘焙进链的端口**） | — |
| `Tweak/Sources/LCProxyPaths.m` | 数据目录解析（共享/私有/canonical）、**宿主进程形态** `LCProxyHostProcessType()` | 192 行 |
| `Tweak/Sources/LCProxyServer.m` | 本地 HTTP 控制台（默认 19092，**被占用时退到临时端口**） | 613 行 |
| `Tweak/Sources/LCProxyDiagnosis.m` | 把状态翻译成 OK/WARN/BAD 结论（纯函数，CI 可跑） | 275 行 |
| `Tweak/Sources/LCProxySharedLog.m` | 跨进程追加式日志（O_APPEND，失败静默） | 43 行 |
| `ConsoleApp/AutoUpdater.m` | dylib 下载/签名/单实例收敛（`.disabled` 暂存） | — |
| `Resources/console.html` → `Tweak/Sources/ConsoleHTML.h` | 控制台 UI（改 html 后要跑 `Scripts/gen_console_asset.js` 重新生成头文件） | — |

### 4.3 共享 vs 私有的真实差异（已逐行核对上游源码，**这部分不用再查**）

| 位置 | 私有 App | 共享 App |
|---|---|---|
| `LCBootstrap.m:347` tweak 目录 | `<LC_HOME>/Documents/Tweaks` | `<AppGroup>/LiveContainer/Tweaks` |
| `LCBootstrap.m:429` guest HOME | `<LC_HOME>/Documents/Data/Application/<uuid>` | `<AppGroup>/LiveContainer/Data/Application/<uuid>` |
| `LCBootstrap.m:525` `hookDlopen` | 可启用 | **强制关闭** |
| `LCBootstrap.m:859` `LCLoadTweaksToSelf` | 私有 Tweaks | App Group Tweaks |
| 启动方式（`LCAppModel.swift:274`） | 本实例直接拉起 | multitask 时交给**另一个空闲 LC 实例**（常常是 `LiveProcess.appex`） |

前三项**已被实测 + 代码核对双重排除**为"路径类"根因（§7.1 / §7.2）。
真正的差异是后两项：**谁承载这个进程**，以及**进程生命周期事件怎么到达**（这就是 H1）。

---

## 5. 修复史（按主题，含证据；这是你最重要的"已知地形图"）

> 完整长版在 `docs/SHARED-APP-PROXY-INVESTIGATION.md`（v0.5.46–v0.5.70，662 行）。
> `docs/REAL-DEVICE-VERIFICATION.md` 是 v0.5.67 时代的真机验证清单。
> 本节把两处 + 之后的版本合并成"按主题"的表格，便于你判断"哪些已经修过了"。

### 5.1 路径 / 配置 / override

| 版本 | 根因 | 证据 | 修法 | 保留 |
|---|---|---|---|---|
| 0.5.21 (`2bcaa1a`) | 所有进程抢同一个 `127.0.0.1:18080`，一个进程被挂起会拖死别人 | 多 LC 实例切换即短时断网 | 转发器改**每进程临时端口**；新增 C 层 per-process override；只在签名/端口真变时 reload | ✅ |
| 0.5.37 (`1cc3b71`) | 共享启动时 `LCProxyAllDataDirectories` 去重后只剩一个 AppGroup 目录；该目录配置陈旧 → 退到 `127.0.0.1:8080` 死默认值 | "横幅正常、连接全被拒" 只在共享 App 复现 | 目录列表回落 `LC_HOME_PATH`；按路径全局排序（否则两进程反向抢锁）；多份 settings 按 mtime 取最新 | ✅ |
| 0.5.67 (`29035c7`) | **override 只在 `reload_config` 内部烘焙**，稳态下再无任何机制校验"链里生效端口 == 转发器端口" → 链停在占位端口 18080 或为空，而 status 全绿 | `chainProxyPort=53464`、转发器在另一个端口；`lastError` 为空 | C 层记录 `applied_override_port`（所有提前返回路径必须清零）；apply 时比对；心跳每 5s 校验、限频 20s 自愈 | ✅ |
| 0.5.81（**未提交**） | 19092 被别的进程占用时**静默 headless** → 打开控制台看到的永远是**抢到端口的那个进程**，历次排查反复拿错现场 | 用户："从共享 App 的浏览器打开 19092 也读不到配置" | 19092 占用时退到临时端口，并写 `console-port-<pid>.json` | ⏳ |

### 5.2 转发器生命周期（"彻底断网且永不恢复"家族）

| 版本 | 根因 | 证据（实测形态） | 修法 | 保留 |
|---|---|---|---|---|
| 0.5.46 (`3a485d4`) | 并发 `applyConfig` 改写 `lastSettingsSignature`，刚 start 成功的转发器被 stop+free 丢弃，`self.forwarder=NULL`，而上次发布的 override 仍指旧端口 | `lastError=""`、连接全被拒 | 只在"确有别的转发器装上"或"切回直连"时才丢弃；新增生命周期通知 | ✅ |
| 0.5.51 (`15d4da2`) | 重建失败/被丢弃后既无转发器也无定时器 → 无人再触发 apply | `forwarderPort=0 / running=false`，override 仍指旧端口 | 加自愈看门狗（5s） | ✅ |
| 0.5.54 (`979c18b`) | 重建顺序"先摘旧 → 同步 stop/free → 再建新"；`stop` 要等 client 线程（可能卡在同步取号，最长 20s）→ `applyConfig` 持 `lifecycleLock` 卡死 → `runtimeQueue` 全堵 | `forwarderPort=0`、`proxyOverridePort` 恒为旧值、`discardCount=0`、`lifecycle=""` | 改为"先启动新的 → 原子替换 → 异步回收" | ❌ **0.5.56 撤回**（与控制台黑屏同时出现） |
| 0.5.57 (`fa676d8`) | Darwin 上对 listen socket `shutdown()` 返回 `ENOTCONN`、`close()` 也不唤醒 `accept()` → accept 线程永久阻塞 → `pthread_join` 永久阻塞 → 整条 apply 链死锁 | 同上 | `poll(listen_fd, 500ms)` 有界等待；改为**先 join 再 close** | ✅ |
| 0.5.58 (`7cd0971`) | 兜底：不依赖对"卡在哪"的判断 | — | `healMissingForwarderDirectly`：绕过 `runtimeQueue` 直接重建并钉住 override | ✅ |
| 0.5.59 (`4e6751c`) | 强刷路径（回前台/NWPath/健康检查）每次都 teardown 转发器 → 每次都进 `pthread_join` 窗口 | — | 复用"真健康"的转发器；新增**独立存活心跳**（不取 lifecycleLock、不过 runtimeQueue） | ✅ |
| 0.5.75 (`090e911`) | 0.5.59 的复用判据用了**弱检查** `listen_fd_valid()`（只看 fd 号 ≥0）；iOS 后台/熄屏会让 socket 失效但 fd 号不变 → 转发器**永不重建** | 回归由用户发现 | 新增 `kp_forwarder_is_listening()`（真去 connect），所有"复用/发布路由"决策点统一使用 | ✅（**但见 §9 H2：心跳仍在用弱判据**） |

### 5.3 凭证 / 上游（"取号成功却转发不出去"家族）

| 版本 | 根因 | 证据 | 修法 | 保留 |
|---|---|---|---|---|
| 0.5.39 → 0.5.40 (`604a9ca`) | 0.5.39 做了"刷新租约 + fail-closed 路由"重构，但**先启用 proxychains 路由再取号** → WUP 控制面请求被导进还是空的本地转发器 → 设备上永远取不到凭证 | 全量取号失败 | 整树回滚到 0.5.38 行为并重发为 0.5.40；失败树保留在 `backup/v0.5.39-failed` | ✅（回滚） |
| 0.5.42 测试构建 (`ec37444`) | 同一问题的正解：控制面 WUP 连接必须**绕过** socket hook | — | bypass + 允许"路由发布前取号" + 保留本地随机 GUID 引导回退 | ✅ |
| 0.5.42 测试构建 (`7879c03`) | 要求 http/https 两个池都非空才算成功，上游只回一个池时就判失败 | — | 恢复 0.5.38 行为：有一个非空池即可运行 | ✅ |
| 0.5.44 (`adb348f`) | 若**另一个** proxychains 类 dylib（实测 `LCTailscaleControl`）在我们之后加载，`lcproxy_socket_set_bypass` 只作用于我们自己那份 hook | 设备日志里 WUP 仍走 127.0.0.1 | 保存原始 libc `getaddrinfo/connect` 指针，WUP 直接用它们 | ✅ |
| 0.5.60 (`e8ec114`) | **强制刷新开头 `clearForwarderKingState`**：取号要 1–2s 网络往返，这 1–2s 内池为空 → 所有连接失败 → 每个失败又触发刷新 → **自我维持雪崩** | `statRefreshCalls=1341`（45 秒内 30 次完整取号）、`statHttpRequests=0`、`activeForwarderClients=37` | 不再先清空，先用旧凭证；合并并发刷新 | ✅ |
| 0.5.61 (`80a3345`) | 0.5.60 给并发刷新加了 20s 阻塞等待，而回调跑在 C 层 **client 线程**（上限 64、每请求重试 3 次）→ 20s×3×64 → 线程/栈耗尽 → **闪退** | "打开共享 App 就闪退" | 回调**只投递信号**、零阻塞、限频、异步，返回 0 | ✅ |
| 0.5.62 (`761b458`) | 回调返回 0 会让 C 层立刻用"没变化"的池再跑一整轮（4 节点 × 20s） | — | 返回 -1；被动间隔 20s；心跳不再催取号 | ✅ |
| 0.5.63 (`b4fbc95`) | 回调恒异步后，`kp_forwarder_refresh_retry(3,500)` 永远不可能成功，纯粹占线程 | — | 改为 `(1,0)`，失败立刻回 502 | ✅ |
| 0.5.65 (`afcb891`) | `leadTime` 语义混用：把"是否需要提前续期"的 2 分钟余量，用在"此刻还能不能用"的判断上 → 凭证最后 2 分钟被判不可用并**清空池**；一次取号失败也清空 | 每个凭证周期都会出现 2 分钟窗口 | 显式区分前瞻性/时点性，时点性传 `leadTime:0` | ✅ |
| 0.5.68 (`9bc1082`) | `SO_SNDTIMEO/SO_RCVTIMEO` **不约束 `connect()`** → 单节点最坏 ~75s，4 节点 ~300s，而 client 槽位只有 64 → 上游一慢就"对一切新连接回 503" | `activeForwarderClients=64`（= 上限）、`statHttpsConnects=66`、`statRefreshCalls=2` | `kp_connect_with_timeout()`（非阻塞 connect + poll + SO_ERROR）；新增 `statClientRejections` | ✅ |
| 0.5.70 (`7873d86`) | 强制刷新会**重领 GUID 身份**；多进程共享凭证日志 → 每次领新身份作废别人 | `recvFail=1224 / lastResp="" / credCode=0`（上游零字节关闭） | 只有服务端明确拒绝（820/821/823）才换身份 | ✅（**解释本身有争议，见 §6.6**） |
| 0.5.73 (`18508a5`) | 共享凭证库里最新一条若"有毒"，每个读它的进程都拿坏凭证去连 | 同上 | 一键重置凭证 `/api/king/reset-credentials`（一次性 `newIdentityRequested`） | ✅ |

### 5.4 后台 / 熄屏（问题 B 的既有修复）

| 版本 | 根因 | 修法 | 保留 |
|---|---|---|---|
| 0.5.31 (`bd075c8`) | ①`UIApplicationDidBecomeActiveNotification` 的 observer token **没被持有** → 回前台 handler 从未执行；②`kp_forwarder_is_listening()` 真检查只为处理"后台失效的监听 socket"而生 | 持有 token；加真监听探测 | ✅（**判据后来被弱化，0.5.75 才修回**） |
| 0.5.36 (`3b3f996`) | 后台/熄屏后整应用无网，只能划掉重进：HTTP body 流式线程卡在半开上游 `recv`（2xx 流式路径把收发超时清零）；`kp_forwarder_stop` 只 shutdown 客户端 fd，然后**无限** `pthread_cond_wait` | 登记上游 fd 并在 stop 时同时唤醒两侧；stop 有 grace 上限（超时按僵尸泄漏）；body 转发改 poll + 120s 空闲上限 | ✅ |
| 0.5.74 (`d8cebed`) | `applyRuntimeSnapshot` 开头 `beginRoutePublication()` 把 `routePublished=NO`，结尾只在特定条件成立时置回 YES，**失败分支还会 `stopRefreshTimer`** → 一次后台切换可把进程锁死在"路由未发布"，而 `syncFetchGuid` 因此失败，旧实现**回退到本地随机 GUID 并当成成功写进共享凭证库** → 运营商不认这个身份 → 零字节关闭 → 每个进程都被污染 | 删本地随机 GUID 回退（fail-closed）；记录 `guidSource` 并拒绝 `local` 记录；心跳补"路由未发布"自愈 | ⚠️ **0.5.75 部分撤回**（回退必须保留，否则冷启动取不到凭证），保留 `guidSource` 标注与心跳自愈 |
| 0.5.75 (`090e911`) | 见 §5.2 最后一行（弱判据回归） | — | ✅ |
| 0.5.81（**未提交**） | **假设**：共享 App 在 multitask 下跑在 `LiveProcess.appex`，其 `UIApplicationMain` 被 `LiveProcess/main.m` 整体替换 → `UIApplication*` 生命周期通知**根本不投递** → "回前台恢复"一次都不触发 | 同时订阅 `UIApplication*` 与 `NSExtensionHost*` 两个族；`hostProcessType` 暴露到 status/diag/selfcheck | ⏳ **未验证**（H1） |

### 5.5 安装 / 升级 / 多 dylib（"一打开就闪退"家族）

| 版本 | 根因 | 修法 | 保留 |
|---|---|---|---|
| 0.5.39 备份 `backup/v0.5.39-failed` | — | 失败分支保留 | — |
| 0.5.49 (`a3a55bd`) | 更新时若新版未签名，`cleanOldDylibs(keep:nil)` 把共享目录里的**已签名** dylib 删光 → 所有 App 同时失去代理 | 未签名时不再删 | ✅ |
| 0.5.50 (`0dc0ad7`) | 无法确认"共享 App 到底加载了哪个版本的 dylib" | 每个进程加载时写 `dylib-loads.log`；`/api/status.dylibLoadsTail` | ✅ |
| 0.5.63 → 0.5.65 | 0.5.63 加"重复映像让位守卫"，但让位那份额外一份 C 层全局变量不设 override → 生效的 hook 回落到 18080 → **把"能用但浪费"变成"彻底断网"** | 0.5.65 撤回该守卫 | ✅（已撤回） |
| 0.5.72 (`74c0ae1`) | 0.5.49 的"什么都不删"导致新旧两份 dylib 共存，TweakLoader 全加载 → 同名 ObjC 类注册两次 → **签名后打开任何 App 都闪退** | `enforceSingleActiveDylibIn:`：最多一个已启用；新版以 `.dylib.disabled` 暂存；枚举两种后缀 | ✅ |
| 0.5.66 (`c0d4dd7`) | 构造器/apply 里抛出的 ObjC 异常在 dyld 阶段会直接杀进程 | `@try/@catch` + `swallowedExceptions` 暴露 | ✅ |

### 5.6 观测能力演进（**这是本项目最有价值的部分，别绕过它**）

| 版本 | 新增 | 为什么关键 |
|---|---|---|
| 0.5.50 | `dylib-loads.log` + `dylibLoadsTail` | 唯一能确认"共享 App 是否真的加载了新 dylib"的手段 |
| 0.5.69 (`1acc3c3`) | `king.upstreamDiag` 分步计数（connect/send/recv、EOF/RST/timeout、状态码、响应原文） | 把"连不上"拆成可判定的阶段 |
| 0.5.71 (`09b2fcb`) | `kingcard-status.log` + `statusTail`（每 30s 每进程快照，含 upstreamDiag 摘要） | 终于能**跨进程**对比（此前 `/api/status` 只反映抢到 19092 的那个进程） |
| 0.5.73 | `/api/king/reset-credentials` | 给用户一个"一步验证共享凭证库是否有毒"的动作 |
| 0.5.76 (`fc99e09`) | `/api/diag`（verdict + 配置链路 + 网络 + 转发器 + 池 + 上游 + 环境） | 把状态翻译成结论，减少推断 |
| 0.5.80 (`d783649`) | `/api/selfcheck`（**在当进程里真发一次 CONNECT**）+ 私有/共享自动对比 | 直接回答"这个进程此刻能不能转发"，不再靠累计计数 |

---

## 6. 已撤回 / 已被证伪的结论（**不要重复这些错误**）

### 6.1 0.5.52：把 WKWebView 代理安装延后到主队列（撤回）
占位端口 18080 无人监听是**刻意的 fail-closed**。延后安装会让 WebKit 在启动窗口内**没有任何代理配置 → 退化为直连**，违反核心不变量。0.5.53 完整撤回，改为"独立跟踪已应用端口、变化时无条件重载"。

### 6.2 0.5.54：转发器重建顺序改成"先建新的再退役旧的"（撤回）
与"签名 dylib 后控制台一打开就黑屏"同时出现。已确认 0.5.53 的控制台可用（console 进程 pid 90508，`/api/status` 可读），因此嫌疑集中在唯一行为改动上。**重新启用前必须先拿到崩溃/卡死日志**。

### 6.3 0.5.63：重复映像"运行期让位"守卫（撤回）
见 §5.5。**正确做法是安装期收敛（0.5.72），不是运行期让位。**

### 6.4 0.5.74：删掉"本地随机 GUID 引导回退"（部分撤回）
`ec37444` 明确记录：取号可能发生在路由发布之前，而 `PBProxy GetGuid` 本身要走转发器的引导隧道，该窗口内必然失败 —— 直接判失败就会"一个凭证都拿不到"。0.5.75 恢复回退，但保留 `guidSource=local` 标注（诊断可见），并用心跳自愈修"路由未发布"这个真原因。

### 6.5 "打开共享 App 闪退是 entitlement 问题"（不是我们的代码）
全树**没有任何 entitlement 查询代码**（只有一处 `NSClassFromString(@"LCSharedUtils")`）。0.5.66 起构造器与 apply 路径都已 `@try/@catch` 兜住。**那条 entitlement 报错来自 LiveContainer 本身或其签名流程**。真正原因是 §5.5 的 dylib 共存。

### 6.6 "多个进程并发刷新各自重领 GUID，互相作废身份"（用户明确纠正过）
用户指出："**并没有多个 App 同时运行**，私有 App 正常而共享 App 不正常" —— 该机制要求**并发刷新**，前提不成立。
代码侧的改动（只有服务端 820/821/823 才换身份）本身是"严格减少变更"，保留；但**这个解释不能作为结论**。
⚠️ 之后 0.5.70 又把它当成结论写进文档 —— 这是本项目的典型失败模式：**同一个未验证解释被反复复活**。

### 6.7 "私有正常/共享失效由并发度差异解释"（未验证）
0.5.60 的证据（37 并发客户端触发雪崩）只能解释**那一轮**的故障；没有同网络 A/B 对照，不能证明它是共享 App 的**结构性**差异。

---

## 7. 已排除项（这些**不用再查**）

### 7.1 配置路径
`LCProxyPaths.m` / `LCProxySharedDataDirectory()` / dylib 路径反推三者一致，canonical 都是 `<AppGroup>/LiveContainer/LCProxy`。**实测**：共享 App 里 `settingsExists=true`、`proxychainsConfExists=true`、`proxyCount=1`。

### 7.2 App Group 解析
上游 guest 内对 `containerURLForSecurityApplicationGroupIdentifier:` 的 swizzle 对 LC 自己的 group 返回真实 App Group 根，两进程一致。

### 7.3 请求构造
`Q-GUID / Q-UA2 / Q-Token / Q-Key / Q-Type / Q-RequestId` + host/port —— **没有任何一项与进程相关**；构造器有边界检查、用线程安全快照。私有与共享进程发出的字节在构造层面相同（`18508a5` 静态核完）。

### 7.4 上游数据面是否可用
同一节点 `116.130.228.112:8091` 曾回 `200` 成功 → 不是"节点全挂"。

### 7.5 转发器释放契约 / accept 循环 / 上游绕过 hook
`kp_forwarder_free` 内部已判 `stop()!=0` 就故意泄漏；`kp_connect_host` 在 `getaddrinfo` **之前**设 bypass（线程局部）；`proxy_override.c` 实现正确。

### 7.6 其他
- 空代理池会返回 `success:NO`（不存在"取号 ok 但池空"的假象）—— 但仍存在"池被清空"（已修）。
- 凭证日志有轮转（64 行），不会无限增长。
- 全树只有 3 处清空点，其中 2 处已于 0.5.65 改为 `leadTime:0`。

---

## 8. 两种"无法联网"的判定指纹（务必背下来）

| 指纹 | 指向 |
|---|---|
| 连接**被拒**（客户端看到 ECONNREFUSED/RST），`chainProxyPort != forwarderPort` 或 = 18080 | A1 链路/override（§5.1） |
| 转发器回 **502**，`liveHttpsPool=0`，`statPoolEmpty` 高，`statRefreshCalls/statHttpsConnects ≈ 3` | A2 凭证/池被清空或从未装载（§5.3） |
| `activeForwarderClients=64`、`statClientRejections` 增长 | A2' 槽位耗尽（connect 超时名不副实，§5.3 v0.5.68） |
| `upstreamDiag`: connectFail=0、sendFail=0、recvFail 大、`lastResp=""`、`credCode=0` | A3 上游零字节关闭（凭证身份不被承认 / 节点拒绝） |
| `routePublished=0`，或 `lastError="王卡本地路由尚未发布"` | A4 路由未发布（§5.4 v0.5.74） |
| `port>0 && running=1`，但 `listenProbeOk=0` | B 监听 socket 失效（后台/熄屏） |
| 一切正常但连不上，且**没有任何日志新增**（心跳快照时间戳不前进） | B' **进程被挂起 / 生命周期事件没投递**（H1/H3！） |

> 最后一行是历史上最容易漏掉的：如果进程被挂起，**5 秒心跳和 2 分钟续期定时器都不会跑**，
> 于是"状态全绿"可能只是**几小时前的快照**。永远先看 `ts` 字段。

---

## 9. 当前未验证的假设（按优先级；每条都给出“可检验预测”）

### H0（代码已证明，**v0.5.81 已修**，只待上机确认）控制台访问 → King 自锁 → 心跳/续期停摆 → 数小时后断网

见 §0.1 第 6 条。这是目前**唯一能同时解释 A 与 B**、而且**无需任何推测**的机制：

**预测**：
1. 断网那个进程的 `king.heartbeatHealCount`/`heartbeatRepinCount` 从某时刻起**完全不变**；
2. `king.lastHeartbeatAt` 与当前时间差很大（该字段在 `status` 里，得先修死锁才能读到）；
3. 该进程 `kingcard-refresh.log` 在打开控制台之后**再无新行**；
4. **可逆验证**：不打开控制台、只用 App，故障不再出现（或延迟到牌子过期后）。

**修复**：§0.1 的一行。修完之后把“控制台访问”从故障诱因里彻底移除，再重测 A/B。

### H1（最高优先，根因候选）共享 App 跑在 `LiveProcess.appex`，`UIApplication*` 生命周期通知不投递

**依据（代码级，非实测）**：
- `LCAppModel.swift:274` —— multitask 下共享 App 被交给"空闲 LC 实例"（`LCLaunchExtensionScheme`）；
- `LCBootstrap.m:672` —— `isLiveProcess = (urlScheme == "liveprocess")`；
- `LiveProcess/main.m` —— 用 `xpc_main` 承载，`UIApplicationMain` 被整体替换；
- `Dead10ccFix.m:37-44` —— 上游自己就是因为这个才按 `isLiveProcess` 改用 `NSExtensionHost*` 通知；
- 本 tweak 在 0.5.81 之前**只订阅 `UIApplication*`**。

**预测（若 H1 成立）**：
1. 共享 App 进程的 `/api/status` 里 `hostProcessType == "liveprocess"`、`isExtensionHosted == true`；
2. 切换前后台时，该进程的 `kingcard-status.log` 快照**持续每 30s 出现**（说明进程没被挂起），
   但 `/api/status` 的 `runtime.lifecycleState` 与 `forwarderPort` **不变**（说明 handler 没跑）；
   ⚠️ 注意：快照本身**不含** `lifecycleState`，必须看 `/api/status`（或 `/api/diag` 里自己的那份）；
3. 同一个 App 设为私有后 `hostProcessType == "uiapp"`，回前台能恢复。

**若成立的最小修复**：已写在未提交的 0.5.81 里（双通知族订阅）。**但必须先用 §10 的字段确认宿主形态**，
否则又是一次推测性修改。

### H2（**v0.5.81 已修**，并在 C 层补了 accept 循环判死，见 §0.0 #2–#4）心跳对"转发器是否真的在监听"用了弱判据

**代码级发现（请复核）**：
- `LCProxyKing.m:229` `isRunning` = `forwarder != NULL && kp_forwarder_is_running(...)` —— **只看内存标志**；
- `heartbeatTick`（`LCProxyKing.m:423`）用 `[self isRunning]` 决定是否进"转发器缺失"分支；
- 而"复用/发布路由"的决策（`LCProxyKing.m:271-272`、`605`）用的是更强的 `kp_forwarder_is_listening()`。

**推论**：若监听 socket 在后台失效、但 `running` 与端口号仍是旧值，且 `routePublished` 仍是 YES
（没有新的 apply 去重算它），**心跳什么都不会做** → 永久断网，直到某个前台/切网事件触发 apply。
如果 H1 同时成立（事件根本不投递），就变成"永久断网且无法自愈"。

**预测**：故障现场会呈现 `forwarderPort>0 / running=1 / routePublished=1 / chainPort==forwarderPort`，
但 `listenProbeOk=0`，且 `heartbeatHealCount` **不增长**。

**最小修复**：心跳第一段改用 `kp_forwarder_is_listening()`（真探测），失败就 `healMissingForwarderDirectly`
或 `requestRuntimeApplyAsync`。**注意**：心跳每 5s 跑一次，真探测是一次 loopback connect（微秒级，可接受），
但必须限频/只在异常时探测，避免变成新的负担。

### H3（**v0.5.81 已修**：心跳墙钟间隔检测，见 §0.0 #5）长时间挂起后凭证已过期，而没有任何路径去续期

**事实**：
- 周期续期 = 2 分钟定时器（`LCProxyKingRefreshInterval=120`，提前 `LeadTime=120` 续期）；
- `Q-Token` 默认有效期 **7200s**（`LCProxyKing.m:1754`），代理池用服务端 `expireEpoch`；
- 进程被 iOS 挂起时，`dispatch_source` 定时器**不跑**；
- 0.5.62 起心跳**刻意不催取号**（避免稳态 3 次/分）；自愈路径只修"转发器/路由/链端口"。

**预测**：长时间后台回前台后，`king.lastRefresh` 停在很久以前、`liveHttpsPool=0` 或池内节点已过期、
`tokenExpire/proxyExpire` 早于当前时间；而 `statRefreshCalls` 不增长（没有人触发取号）。

**若成立的最小修复**：在 `notifyWillEnterForeground` / `notifyDidBecomeActive` 的恢复路径上
**显式检查凭证新鲜度**（时点性判断 `leadTime:0`），不新鲜就 `refreshCredentialsAsync`（限频）；
而不是依赖"连接失败 → 被动刷新"这条必然伴随一次失败体验的路径。

### H4（中）"路由未发布"仍有窗口
0.5.75 已加心跳自愈（限频 20s），所以最坏 20s 内恢复。若现场看到 `routePublished=0` 持续更久，
说明 `requestRuntimeApplyAsync` 本身被堵（回到 §5.2 的死锁家族）。

### H5（中）控制台看到的不是"出问题的那个进程"
0.5.81 前，19092 被占用即静默 headless。历史上有多次"用户报共享 App 有问题 → 我看到的 status 全绿"，
很可能看得是**另一个进程**。已用临时端口 + `console-port-<pid>.json` 修，但要确认 `pid` / `hostProcessType`。

### H6（低，但会误导你）"共享 App"可能根本不是同一个进程模型
用户说的"共享 App"包含两种情形：**multitask 共享**（另一个 LC 实例承载）与 **单实例共享**。
`uiIsShared` 只描述 App 的存储/容器语义，不决定进程形态。**取证时必须记录进程形态**，不要用
"共享/私有"两个词概括。

---

## 10. 观测面（现在能拿到什么；这是你唯一的"眼睛"）

### 10.1 HTTP 端点（每进程一个；默认 19092，被占用时退到临时端口）

| 端点 | 作用 | v0.5.75–v0.5.80 现状 |
|---|---|---|
| `GET /api/status` | 大全集：本进程 dylib/端口/路径 + `king` 段（凭证、池、上游分步、心跳计数） | ❌ **死锁挂死**（§0.1） |
| `GET /api/diag` | 结论化：`verdict[]`（OK/WARN/BAD）+ `configDiag` + `networkDetected` + `king` + `endpoints.sandbox` + `statusTail` + `refreshLogShared` | ❌ 挂死（内部调用 status） |
| `GET /api/selfcheck` | **在当进程里真发一次 CONNECT**（最长 ~40s），逐步记录 connect/send/recv/EOF/RST/timeout/状态码/响应原文 | ✅ **可用（唯一）** |
| `GET /api/king/reset-credentials` | 丢弃缓存 state、强制重领身份（一次性） | ✅ 可用（不经过 status） |
| `GET /api/stats` | 蜂窝流量统计 | ✅ 可用 |
| `POST /api/config` | 保存并应用（写入发生在挂死之前，**响应不返回**） | ⚠️ 写生效、响应挂死 |

### 10.2 必须看的关键字段（准确路径，别凭印象找）

| 字段 | 路径 | 含义 |
|---|---|---|
| `pid` / `hostProcessType` / `isExtensionHosted` / `isSharedTweaks` | 顶层 | **你到底在看哪个进程**（0.5.81 起才有后三个） |
| `forwarderPort` | 顶层 | 转发器真实监听端口（0 = 没起来） |
| `chainProxyPort` / `chainPortMatches` | 顶层 | **链里真正生效**的端口 / 是否等于 forwarderPort |
| `swallowedExceptions` | 顶层 | 非空 = 我们的代码出过错（但宿主还活着） |
| `kingRefreshLogShared` | 顶层 | 跨进程取号历史（含 pid、src、耗时） |
| `dylibLoadsTail` | 顶层 | 跨进程 dylib 加载记录（版本/路径/pid） |
| `statusTail` | `/api/diag` 内 | 所有进程的 30s 快照（**带 ts**）—— ⚠️ 其中 `listenOk` 用的是**弱判据**（fd 号），不是真探活；真探活看 `king.listenProbeOk` |
| `king.running` / `listenFdValid` / `listenProbeOk` | `king` 内 | 内存标志 / 弱判据 / **真探活** |
| `king.routePublished` | `king` 内 | 路由是否已发布（A4 判据） |
| `king.liveHttpPool` / `liveHttpsPool` | `king` 内 | **此刻**池内节点数 |
| `king.guidSource` | `king` 内 | `local` = 本地随机引导身份（不可用于正常连接） |
| `king.statPoolEmpty` / `statRefreshCalls` / `statClientRejections` | `king` 内 | 清空型 / 取号风暴 / 槽位耗尽 |
| `king.heartbeatHealCount` / `heartbeatRepinCount` / `heartbeatChainRepairCount` | `king` 内 | 自愈是否真的救过（有价值，不是坏事） |
| `king.upstreamDiag.*` | `king` 内 | connect/send/recv 分步 + `lastResp` 原文 + `req` 结构快照 |
| `king.lastError` / `lastRefresh` | `king` 内 | 最近错误 / 最近取号时间（**B3 的核心判据**） |
| `runtime.lifecycleState` | `runtime` 内 | `active` / `foregrounding` / `background` —— **H1 的直接判据**（切前后台时它变不变） |
| `runtime.lastAppliedForwarderPort` | `runtime` 内 | 上一次 apply 时用的转发器端口（与 `forwarderPort` 不等 = apply 没跟上） |
| `runtime.forwarderUnavailable` / `forwarderRetryCount` | `runtime` 内 | 转发器不可用状态与重试次数 |
| `runtime.networkGeneration` | `runtime` 内 | NWPath 变化代数（切网是否被感知） |

### 10.3 共享日志文件（都在 canonical 目录 `<AppGroup>/LiveContainer/LCProxy/`）

| 文件 | 内容 | 轮转 |
|---|---|---|
| `kingcard-credentials.log` | 凭证追加日志（不含明文凭证细节以外的敏感项） | 64 行 |
| `kingcard-refresh.log` | 每次取号：`ok/src/ms/msg`，**含所有进程** | 200 行 |
| `kingcard-status.log` | 每进程 30s 状态快照 | 120 行 |
| `dylib-loads.log` | 每进程每次加载 dylib 的事实 | — |
| 流量日志（按连接） | `route/status/bytes`；**默认关闭**，关闭时不会写任何新记录（不要据此判断失败） | 2 MiB 滚动 |
| `console-port-<pid>.json` | 每个进程控制台的实际端口（0.5.81 起） | — |
| `settings.json` / `proxychains.conf` | 配置（多目录镜像，按 mtime 取最新） | — |

### 10.4 判读顺序（照抄即可）

1. `ts` 是否在前进？（不前进 = 进程被挂起或心跳死了 → 一切结论作废）
2. `pid/hostProcessType` 是不是出问题的那个进程？
3. `listenProbeOk` / `chainPortMatches` / `routePublished` 三个"链路"字段。
4. `liveHttpsPool` + `guidSource`（凭证层）。
5. `upstreamDiag`（上游层）。
6. `/api/selfcheck` 在同一进程里跑一次（**决定性证据**）。

---

## 11. 取证协议（请让用户按这个做，否则你得不到可用数据）

> 目标：用**最少操作**拿到"私有 vs 共享"的**同网络、同版本、同 App**对照。
> 历史教训：所有"私有正常/共享不正常"的结论都缺少这份对照数据。

### 11.0 前置：先修 §0.1 的死锁（否则你拿不到任何数据）

在 v0.5.75–v0.5.80 上：`/api/status`、`/api/diag` 挂死；App Group 的日志文件在「文件」App 里
**看不到**（用户无法手动导出）。因此**除了 `/api/selfcheck`，用户没有任何渠道把现场交给你**。

所以顺序是：

1. 先修死锁（§0.1，一行）→ 重新构建/签名/安装；
2. 再让用户做 §11.2 的 A/B 取证。

若暂时不能发版：只让用户跑 `/api/selfcheck`（私有/共享各一次），它能给出
`stage / connect / send / recv / code / resp` —— 这已经足以区分 A1/A2/A3，只是没有跨进程快照。

### 11.1 前置：版本必须是同一个
1. LiveContainer → Tweaks 页 → 删除**所有** `LCProxyControl-*.dylib`（不管版本）；
2. 打开 `LiveProxyConsole` → 下载新 dylib → 签名；
3. **完全关闭控制台，再打开一次**（这一步才把已签名副本复制进 App Group `Tweaks`）；
4. 确认只剩**一个** `LCProxyControl-<ver>.dylib`。

### 11.2 采集（同一 Wi-Fi，两次，间隔尽量短）
对**同一个 App**（历史用 `com.ld.TakeBrowser`，Alook 也可）：

- 轮次 1：设为**私有**，启动，等横幅出现，正常用 60 秒；
- 轮次 2：改为**共享**（multitask 场景），启动，等横幅出现，正常用 60 秒。

每轮各做三件事并回传：
1. 打开控制台 → 「诊断」卡片 → 复制整段文本（或直接 `GET /api/diag` 的 JSON）；
2. 点「运行自检」（`/api/selfcheck`）→ 复制结果；
3. `GET /api/status` → 复制整份 JSON（不必挑字段）。

### 11.3 针对问题 B 的额外取证
1. 记录**进后台的时刻**（本地时间）与**回前台的时刻**；
2. 回前台后**立刻**（10 秒内）取一次 `/api/diag` + `/api/status`；
3. 再等 60 秒取第二次（看是否自愈）；
4. 若仍然断网：点一次「立即刷新凭证」，再取第三次。

回传时务必包含 `statusTail` 里**该进程的多条 ts 快照**（这正是判断"挂起/事件未投递/凭证过期"的证据）。

### 11.4 若用户只能给一句话
优先问这三个问题（它们能直接砍掉一半可能性）：
1. 断网时**横幅还在吗**？（还在 = 进程活着、配置在；不在 = 进程/构造器问题）
2. 是**立即报错**、**转圈**、还是**HTTP 502**？
3. 切一下后台再回前台，会不会自己好？（会 = 事件救得回来 → H1 之外的问题）

---

## 12. 不变量（**改代码前必读**；违反任意一条都会把故障放大）

1. **绝不直连。** 代理启用时任何失败路径都必须 fail-closed（丢包/拒绝），不得退化为直连。
2. **`127.0.0.1:18080` 是刻意占位端口**，不是 bug。指向它是安全的；**跳过安装代理配置反而危险**。
3. **`LCProxyKing.self.lock` 不可重入**：`loadState`/`credentialLogPath`/`appendCredentialRecord:`/
   `newestValidRecordFromLog`/`trimAppendLogAtPath:`/`appendSharedRefreshLogEntry:` 走独立 `cacheLock`，
   **绝不能在 `self.lock` 临界区内调用**（`Scripts/test_king_cache_logic.sh` 有双向锁序断言）。
4. **追加式日志不加锁**（`O_APPEND` 行级追加，跨进程安全）；读方取"最新且仍有效"的一条，损坏行跳过；
   任何 IO 失败静默忽略（纯诊断，绝不能影响转发）。
5. **王卡强制 `block_non_tcp`**：转发器只承载 TCP，必须丢 UDP/QUIC。
6. **`version.txt` 是唯一版本源**；`build_ios.sh` 会生成 `Tweak/Sources/Version.h`。
7. **绝不在 runtime apply 路径上同步销毁转发器**（stop 要等 client 线程，最长 ~20s）。
8. **跑在 C 层 / client 线程上的回调只投递信号**，零阻塞、限频、异步、返回 0 或 -1。
9. **绝不为了取新凭证而先清空在用凭证**（先用旧的继续服务，拿到新的再覆盖）。
10. **每个 Tweaks 目录最多一个已启用的 `LCProxyControl-*.dylib`**（其余用 `.dylib.disabled` 暂存）。
11. **不要在 `dispatch_sync` / 主队列上做网络 I/O**（自检、取号一律后台队列）。
12. **持锁区里不做网络探测 / 文件 IO**：`kp_forwarder_is_listening()` 等探活必须先取出引用、解锁后再调
    （client 线程可能正等 `self.lock` 取号，持锁做 IO 会把它们一起拖住）。
13. **同一方法内不得对同一把 `NSLock` 嵌套上锁**（不可重入，自死锁零日志）——见 §0.1。

---

## 13. 代码地图（改哪里去）

| 需求 | 位置 |
|---|---|
| 数据目录 / 宿主形态 | `LCProxyPaths.m: LCProxySharedRootFromDylibPath / LCProxyCanonicalDataDirectory / LCProxyAllDataDirectories / LCProxyHostProcessType` |
| 生命周期通知订阅 | `LCProxyControl.m: LCProxyObserveLifecycleNotifications`（0.5.81 工作区改动） |
| runtime apply / 恢复状态机 | `LCProxyConfig.m: applyToRuntime(348) / requestForegroundRecoveryAsync(365) / notifyWillEnterForeground(379) / notifyDidEnterBackground(383) / notifyDidBecomeActive(389) / applyRuntimeSnapshot(547) / applyRuntimeSnapshotUnsafe(562)` |
| 转发器复用/重建 | `LCProxyKing.m: applyConfig:effectiveMode:forceRestart:(241)`（复用判据 271-272） |
| 存活心跳 | `LCProxyKing.m: startLivenessHeartbeat(405) / heartbeatTick(423)` |
| 紧急自愈 | `LCProxyKing.m: healMissingForwarderDirectly(541)` |
| 路由发布 | `LCProxyKing.m: beginRoutePublication(590) / publishRouteForSettings:(597)` |
| 自检 | `LCProxyKing.m: selfCheck(650)` + `KPKIngCore.c: kp_forwarder_selfcheck(2884)` |
| 凭证刷新 | `LCProxyKing.m: refreshCredentialsWithForce:(1498)`、`syncFetchGuid(1256)`、`syncFetchToken(1332)`、`syncFetchProxies(1346)` |
| 凭证新鲜度 | `LCProxyKing.m: stateHasFreshCredentials:(921/937/965)` ← **leadTime 语义在此** |
| 凭证日志 | `LCProxyKing.m: 1040-1230` |
| 跨进程快照 | `LCProxyKing.m: appendSharedStatusSnapshot(1127)` |
| 转发器 C 实现 | `KPKIngCore.c: kp_forwarder_new(2676) / start(2786) / run / stop(2989) / free(3050) / is_listening(2866) / probe_local(2871) / shutdown_clients(2827)` |
| 上游连接/超时 | `KPKIngCore.c: kp_connect_with_timeout(557)`、`kp_connect_host` |
| override 记账 | `Tweak/ProxyCore/src/proxy_override.c: set(29) / apply(55) / get_applied_override_port(100)` |
| 控制台端点 | `LCProxyServer.m: configPayload(111) / status handler(391) / api/diag(405) / api/selfcheck(474) / POST api/config(504) / start(554)` |
| 结论翻译（可单测） | `LCProxyDiagnosis.m` + `Scripts/test_lcproxy_diagnosis.sh` |
| 安装/升级 | `ConsoleApp/AutoUpdater.m: enforceSingleActiveDylibIn / lcProxyControlFilesIn` |

---

## 14. 构建 / 测试 / 发布

```bash
# 纯静态守卫（grep 断言）—— Git Bash 直接跑
bash Scripts/test_king_cache_logic.sh        # 锁序 / 凭证状态机 / 自愈断言
bash Scripts/test_foreground_reload_logic.sh # 前后台恢复 + 共享 App
bash Scripts/test_shared_app_paths.sh        # 目录塌缩 / 单实例 dylib
bash Scripts/test_alook_crash_guard.sh       # 大流量/线程上限

# 需要真 C 编译器（override 记账 / stop-join 回归 / async relay）—— 在 WSL 里跑，见 §1.1
wsl -d Ubuntu-24.04 -- bash -lc '
  cd /mnt/c/Users/koast18/work/livecontainer-kingcard-proxy &&
  find Scripts -name "*.sh" -exec sed -i "s/\r$//" {} + &&
  bash Scripts/run_all_tests.sh'

# 改了 Resources/console.html 之后必须重新生成内嵌头文件（否则控制台看不到新 UI）
node Scripts/gen_console_asset.js

# 安装 pre-push 钩子（本地检查不过就拒绝推送）
bash Scripts/install_hooks.sh
```

> 注意：`Scripts/*.sh` 里有很多**静态守卫断言**（grep 源码里的函数名/注释标记）。
> 你改动源码或删除注释标记时，这些守卫会失败 —— 这是**故意的设计**，不要为了让测试变绿而改断言；
> 先确认断言本身是否还描述正确的不变量（历史上出现过“把 bug 当规范”的旧断言，见 0.5.72）。

发布链路（**不要在排查中顺手改**）：
`version.txt` → `Scripts/update_altstore_source.sh`（同时更新 `AltStore/altstore-source.json` 的 size）
→ tag → CI（`.github/workflows/build.yml`）。

国内下载源（用户升级 dylib 用；`raw.githubusercontent.com` 直连不通）：
```
https://gh-proxy.com/https://raw.githubusercontent.com/koast18/livecontainer-kingcard-proxy/master/AltStore/altstore-source.json
https://cdn.jsdelivr.net/gh/koast18/livecontainer-kingcard-proxy@master/AltStore/altstore-source.json
```

---

## 15. 当前工作区状态（**未提交的 v0.5.81**）

`git status`：9 个文件已修改，未提交。内容**只做"测量 + 生命周期订阅"，没有改转发逻辑**：

| 文件 | 改动要点 | 状态 |
|---|---|---|
| `version.txt` | 0.5.80 → 0.5.81 | — |
| `Tweak/Sources/LCProxyPaths.{h,m}` | 新增 `LCProxyHostProcessType()` / `LCProxyIsExtensionHostedProcess()`（判据 = `LP_HOME_PATH` 环境变量，只有 `LiveProcess.appex` 设置） | H1 的测量基础 |
| `Tweak/Sources/LCProxyControl.m` | 生命周期通知改为**同时订阅 `UIApplication*` 与 `NSExtensionHost*`** 两族；`queue:nil`（不用 mainQueue） | H1 的候选修复 |
| `Tweak/Sources/LCProxyServer.m` | ① `/api/status`、`/api/diag`、`/api/selfcheck` 暴露 `hostProcessType`/`isExtensionHosted`/`isSharedTweaks`；② **19092 被占用时退到临时端口**；③ 写 `console-port-<pid>.json` | H5 的修复 |
| `Tweak/Sources/LCProxyKing.m` | 30s 快照里加 `hostType` / `isExtensionHosted` | 跨进程对比 |
| `Resources/console.html` + `Tweak/Sources/ConsoleHTML.h` | 「关于」卡片显示"宿主进程形态" | — |
| `Scripts/test_foreground_reload_logic.sh` | 对应守卫断言 | — |

**之后追加（见 §0.0）**：`KPKIngCore.{c,h}`（accept 循环判死 + `kp_forwarder_listener_error`）、
`LCProxyKing.m`（锁纪律、心跳真探活 + 挂起检测、自愈可替换死监听器、retain 补齐）、
`Scripts/test_forwarder_stop.c`（死监听器回归测试）、两份静态守卫脚本。

**你接手时可以：**
- 保留这些改动（它们只增加可观测性与"多订阅一族通知"），但**必须先确认 H1**；
- 或先 `git stash` 掉，用 0.5.80 做基线取证再决定（**更符合"先测量"纪律**）。

工作区没有提交过任何"猜测性修复"，请保持这个状态。

---

## 16. 建议的下一步（按优先级）

**P0｜先解除“盲飞”状态（必做，且与根因无关）**
1. 修 `LCProxyKing.m` `status` 的嵌套锁（§0.1）——否则 `/api/status`、`/api/diag` 全部挂死，
   你无法从用户那里拿到任何现场数据。
2. 顺手补一条静态守卫：禁止同一方法内对 `self.lock` 嵌套上锁（可用 awk/python 扫
   `[self.lock lock]` 与 `[self.lock unlock]` 的平衡，像 §0.1 那样）。

**P1｜测量**
1. 让用户按 §11 做 A/B 取证，回传 `/api/diag` + `/api/selfcheck` + `/api/status`（含 `statusTail`）。
2. 直接回答三个问题：共享进程的 `hostProcessType` 是什么？`listenProbeOk` 是多少？`lastRefresh` 距今多久？

**P2｜判定 H1**
- 若共享进程 `hostProcessType == "liveprocess"`：H1 成立，双通知族订阅是对的；接着验证"回前台恢复是否真的触发"
  （看 `lifecycleState` 变化 / `kingcard-refresh.log` 里是否出现 `src=foreground` 一类记录）。
- 若 `hostProcessType == "uiapp"`：H1 被证伪 → **立即放弃这条线**，转到 H2/H3。

**P3｜判定 H2（心跳弱判据）**
- 若现场出现 `running=1 & listenProbeOk=0 & heartbeatHealCount 不增长` → 改成真探测（§9 H2 的最小修复）。
- 注意保持"心跳每 5s 只读内存"的省资源约束：真探测只在**疑似异常**时做，或加最小间隔。

**P4｜判定 H3（长后台凭证过期）**
- 若 `lastRefresh` 很旧 + 池空/过期 + `statRefreshCalls` 不增长 → 在恢复路径上显式检查新鲜度并异步取号（限频）。
- 这里最容易犯的错：让心跳/恢复路径变成"稳态每 20s 一次完整取号"（0.5.62 就是为了修这个才把催促拿掉的）。

**P5｜若三条都被证伪**
- 回到"进程被挂起"这条最朴素的可能：确认 `statusTail` 的 `ts` 在故障期间是否前进。
- 若进程确实活着、所有字段都正常、自检却失败 → 问题在**上游/协议层**（节点、Q-Token、身份），
  用 `upstreamDiag.lastResp` 的原文和 `req` 快照继续查，而不是继续改本地转发器。

---

## 17. 陷阱清单（本项目已经踩过的；逐条对照避免重犯）

1. **"每个指标都正常" ≠ 健康**：`status` 里大部分字段读的是"我们想用什么"，不是"链里真正生效什么"。
   典型：`overridePort`（想用）vs `chainPort`（真生效）；`listenFdValid` / `statusTail.listenOk`（弱）vs `listenProbeOk`（真）。
2. **累计计数器不能证明"此刻"**：`statPoolEmpty`/`statRefreshCalls` 是历史累计；要看 `liveHttpsPool`、`selfcheck`。
3. **空日志不是失败证据**：`trafficLogging` 关闭时根本不写日志。
4. **不要在两份 dylib 共存的状态下排查**：一切行为都不可预测。
5. **不要用"共享/私有"两个词概括进程模型**：`uiIsShared`（存储语义）≠ 进程形态（H6）。
6. **不要在宿主的 dyld 阶段/主线程做重活**：异常会直接杀进程；网络 I/O 会冻 UI。
7. **不要把"看起来更安全"的改动当成无害**：0.5.52 的"延后安装代理"直接导致直连泄漏；
   0.5.63 的"让位守卫"直接导致彻底断网；0.5.74 的"删本地 GUID 回退"直接导致冷启动取不到凭证。
8. **一次只改一个变量，并且先写下"这个改动如果对，应该看到什么数字变化"**。
9. **用户是对的**：本项目的每一次用户纠正（0.5.72、0.5.75、0.5.71 的“并没有多进程并发”）都被证实。
10. **不要在已持锁的区段里再次 `lock`**：`NSLock` 不可重入，自死锁**无日志、无异常、无返回**，
    外部只能看到“端点不返回”。v0.5.75 就是这么把诊断能力全部弄丢的（§0.1）。
11. **指标不可能比采集它的代码更可靠**：诊断面板本身挂死时，不要解读“字段为空/为 0” —— 先确认端点能返回。
12. **不要在 App Group 不可见的前提下把日志当“用户能提供的东西”**：用户拿不到，只能通过 HTTP 端点或截图。

---

## 18. 参考

- `docs/SHARED-APP-PROXY-INVESTIGATION.md` —— 共享 App 长版排查记录（缺陷清单 / 不变量 / 诊断速查，v0.5.46–0.5.70）
- `docs/REAL-DEVICE-VERIFICATION.md` —— 真机验证清单（精确到 JSON 层级 + 判读表）
- `docs/TESTING.md`、`docs/RESEARCH-IOS-NETWORK-APPS.md`、`docs/ALOOK-SPEEDTEST-CRASH-RESEARCH.md`
- 关键提交（建议按序 `git show`）：
  - `2bcaa1a` 每进程临时端口 + override（0.5.21，地基）
  - `3b3f996` 后台无网 + 多实例状态收敛
  - `1cc3b71` 共享 App 数据目录塌缩（0.5.37）
  - `3a485d4` 转发器被丢弃 → override 悬空（0.5.46）
  - `fa676d8` accept 永久阻塞（0.5.57）
  - `7cd0971` / `4e6751c` 紧急自愈 + 复用健康转发器（0.5.58/59）
  - `e8ec114` 凭证雪崩（0.5.60）
  - `80a3345` 回调阻塞导致闪退（0.5.61）
  - `29035c7` 链端口陈旧（0.5.67）
  - `9bc1082` connect 超时名不副实（0.5.68）
  - `7873d86` 强制刷新不换身份（0.5.70）
  - `74c0ae1` 单活动 dylib（0.5.72）
  - `d8cebed` / `090e911` 后台/熄屏双修复 + 回归审计（0.5.74/75）
  - `09b2fcb` / `fc99e09` / `d783649` 跨进程可观测 → `/api/diag` → `/api/selfcheck`（0.5.71/76/80）
  - `090e911` ⚠️ **同时引入了 §0.1 的嵌套锁死锁**（0.5.75）—— 读它时请同时看 `LCProxyKing.m` 的 `status`

---

## 19. 共享 vs 私有：加载内容与路径的逐项源码核对（v0.5.81 之后补充）

> 结论先行：**数据/配置/凭证路径两边一致；真正不同的是"加载哪个 dylib 文件"和"宿主进程形态"。**
> 前者是唯一能让"私有正常、共享失效"**确定性**成立的机制，且一条日志即可判定。

| 环节 | 私有 App | 共享 App | 依据 | 是否影响转发 |
|---|---|---|---|---|
| Tweak 扫描目录 | `<LC_HOME>/Documents/Tweaks` | `<AppGroup>/LiveContainer/Tweaks` | `LCBootstrap.m:347`（`LC_GLOBAL_TWEAKS_FOLDER`）、`TweakLoader.m` | **是** |
| 该目录的 dylib 由谁放、谁签名 | 控制台下载 → 用户在 LC 签名 | **只有控制台 `AutoUpdater` 在"私有侧已签名"后复制过去**；LC 的 `signApp` 只签 `lcGroupTweakPath/<tweakFolder>` 子目录与私有根，**从不签 App Group Tweaks 根** | `LCAppModel.swift:437-459`、`AutoUpdater.m:runAutoUpdate` | **是** |
| settings / proxychains.conf | canonical `<AppGroup>/LiveContainer/LCProxy` | 同左 | `LCProxyConfig.dataDirectory`、`set_config_path` 钉死 C 层路径 | 否（两边相同） |
| 凭证日志 / 取号日志 / 状态快照 | canonical | 同左 | `credentialLogPath`、`appendShared*` | 否 |
| `LCProxyDataDirectory()`（由 dylib 路径反推） | `<LC_HOME>/Documents/LCProxy` | `<AppGroup>/LiveContainer/LCProxy` | `LCProxyPaths.m` | 否：只用于 stats / reset-stats / 显示 |
| `LC_HOME_PATH` 回落 | — | 仅在 canonical 无 settings 时一次性迁移 | `LCProxyConfig.load`、`common.c` | 否 |
| 请求构造 / 网络参数 | 进程无关 | 同左 | §7.3、`LCProxyNetworkInfo.m` | 否 |
| `hookDlopen` | 可开 | 强制关 | `LCBootstrap.m:525` | 否（不影响 TweakLoader 的 dlopen） |
| 宿主 | 主 App 进程 | multitask 下常为 `LiveProcess.appex`（`NSExtensionHost*` 通知） | `LCAppModel.swift:274`、`LiveProcess/main.m` | 是（v0.5.81 双订阅 + 墙钟心跳已覆盖） |
| `Dead10ccFix` | 不安装 | 安装：切后台时给持锁文件打 `can-suspend-locked`，让进程**被挂起而不是被杀** | `Dead10ccFix.m:37-44` | 是：共享 App 更常经历"长挂起→恢复"，正是 H2/H3 场景 |

### 19.1 唯一的"确定性"共享专属机制：App Group Tweaks 里是旧版 dylib

共享 App 加载的 dylib **不是用户刚签名的那个文件**，而是控制台复制过去的副本。只要发生下列任一情况，
私有 App 跑新版、共享 App 仍跑旧版（或没有 dylib）：

1. 签名新版后**没有再打开一次控制台**（复制只在控制台启动时的 `runAutoUpdate` 里发生）；
2. 控制台进程拿不到 `LCSharedUtils.appGroupID`（`sharedTweaksDirectory` 返回 nil → 直接跳过复制，仅写一行 diag）；
3. 旧版已签名副本仍在共享目录：`enforceSingleActiveDylibIn` 只在 `normalSigned` 为真时才把目标设为新版。

v0.5.75–v0.5.80 的 dylib 都带 §0.1 的 `status` 自死锁。**共享目录停在这些版本之一 + 控制台每 5s 轮询 `/api/status`**
（`console.html` 的 `setInterval(refresh, 5000)`），足以让共享 App 的 King 层永久锁死、心跳与续期停摆 → 最终断网；
而私有侧已是修好的版本 → 正常。这同时解释了 A（只坏共享）与 B（过一段时间才坏）。

**判定只需一条日志**：控制台 `/api/diag` 的 `dylibLoadsTail`，找共享 App 的 bundle 那一行：
`version` ≠ 私有那一行的 `version`，或 `dylib` 路径下的文件名版本更旧 → 成立。

### 19.2 CI 状态

v0.5.81（`6abb1a2` + 测试修正 `c5015e8`）已推到 `ci/v0.5.81-check` 分支，macOS CI **全绿**
（含 iOS dylib 编译/链接、`test_forwarder_stop` 的死监听器用例）。未合入 master、未打 tag、未改 AltStore 源。
修正点：`find_listen_fd` 原用 `SO_ACCEPTCONN`，Darwin 上 getsockopt 不可靠，改为"无 peer 的同端口 socket"。
