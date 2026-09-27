# 真机验证清单（v0.5.67）

> 目的：用**最少的操作**判定"共享 App 无法联网"是否已修好，并在**未修好时一次就区分出方向**。
> 在此之前的所有自动检查（静态断言、C 单元测试、dylib 编译）均已在 CI 通过；本清单覆盖
> **只有在真机上才能确认**的部分。

---

## 0. 为什么必须先清空 Tweaks 目录

LiveContainer 的 TweakLoader 会加载 Tweaks 目录里的**每一个** dylib 文件。

实测出现过：`dylib-loads.log` 里**同一个 pid 先后加载了 `LCProxyControl-0.5.57.dylib`
与 `LCProxyControl-0.5.56.dylib`**。

两份共存有两种后果，且都不需要在你的代码里做任何"让位"处理（v0.5.65 曾试图让位，
**已撤回** —— 因为每一份 dylib 有自己独立的一套 C 层全局变量，让位的那份不设置
override，其生效的 `connect` hook 就会回落到无人监听的占位端口 18080，**把"能用但浪费"
变成"彻底断网"**）：

- 两个 ObjC 单例 → 两个转发器、两个心跳、两个本地 Web 服务；
- 版本混杂时行为不可预测。

**所以升级时必须手动清空。** 这一步同时也是"加载期 entitlement/codesign 报错导致闪退"
的最可能来源。

---

## 1. 升级步骤（严格按序）

1. **LiveContainer 本体 → Tweaks 页 → 删除所有 `LCProxyControl-*.dylib`**（不管版本）。
2. 打开 **LiveProxy 控制台** → 自动下载 `0.5.67`。
3. 在控制台里 **签名** dylib。
4. **完全关闭控制台，再重新打开一次**（这一步把已签名副本复制进 App Group，并让新版本生效）。
5. 回到 Tweaks 页，**确认只剩一个 `LCProxyControl-0.5.67.dylib`**，且是你刚签的那个。
   - 若仍有多个：重复步骤 1。
6. 重启**共享 App**（本次被测：`com.ld.TakeBrowser`）。

> 更新源（国内需走镜像）：
> `https://gh-proxy.com/https://raw.githubusercontent.com/koast18/livecontainer-kingcard-proxy/master/AltStore/altstore-source.json`

---

## 2. 采集数据（一次即可）

在**共享 App 正在前台运行**时，用同一台设备上的浏览器打开：

```
http://127.0.0.1:19092/api/status
```

> 若打不开：先在控制台里打开一次，确认本地服务在监听；端口以控制台显示为准。
>
> **最省事的做法：把整个 JSON 复制回来即可**，不必自己挑字段。

### 字段的**准确路径**（已逐项核对源码，勿凭印象找）

字段分两层，**不在同一个对象里**：

| 字段 | 路径 | 说明 |
|---|---|---|
| `chainPortMatches` | **顶层** `chainPortMatches` | 链里生效端口 == 转发器端口 |
| `chainProxyPort` | **顶层** `chainProxyPort` | 链里实际生效的端口 |
| `forwarderPort` | **顶层** `forwarderPort` | 转发器实际监听端口 |
| `swallowedExceptions` | **顶层** `swallowedExceptions` | 被兜住的异常（非空=我们的代码出过错） |
| `kingRefreshLogShared` | **顶层** `kingRefreshLogShared` | 跨进程取号历史（最近 30 行） |
| `statRefreshCalls` | **`king` 内** `king.statRefreshCalls` | 取号调用次数 |
| `statPoolEmpty` | **`king` 内** `king.statPoolEmpty` | 连接到达时池为空的累计次数 |
| `liveHttpPool` / `liveHttpsPool` | **`king` 内** `king.liveHttpPool` | **此刻**池内节点数 |
| `heartbeatChainRepairCount` | **`king` 内** `king.heartbeatChainRepairCount` | 心跳修复链端口的次数 |
| `lastError` | **`king` 内** `king.lastError` | 最近一次错误 |

---

## 3. 判读表（这是本清单的核心）

| # | 字段 | 期望 | 不符合时的含义 |
|---|---|---|---|
| 1 | **`chainPortMatches`** | `true` | **false → 连接被发到别处**（链停在无人监听的占位端口 18080 或链为空）。这正是 v0.5.67 修的那一类。请连同 `chainProxyPort`、`forwarderPort` 一起报回。 |
| 2 | **`liveHttpsPool`**（或 `liveHttpPool`） | `>= 1` | **0 → 完全没有可用凭证/代理池**（凭证被清空或从未装载）—— 第二类方向，去查凭证获取。 |
| 3 | **`swallowedExceptions`** | `[]`（空） | **非空 → 本 tweak 的代码出过错**（但宿主 App 仍活着，v0.5.66 的加固生效）。请把内容一并报回。 |
| 4 | **`statRefreshCalls`** | 几分钟内只涨几次~几十次 | **仍然暴涨（数百上千）→ 还存在第二个取号风暴触发源**。历史基线：**1341**。 |
| 5 | **`heartbeatChainRepairCount`** | `0` 或很小 | **> 0 → 自愈确实救回来过**，说明故障真实发生过（这是有价值的证据，不是坏事）。 |
| 6 | **`chainProxyPort`** vs **`forwarderPort`** | 两者相等 | 不等即第 1 条为 false 的具体数值。 |

### 组合判读（一次定位方向）

| `chainPortMatches` | `liveHttpsPool` | 结论 |
|---|---|---|
| `true` | `>= 1` | 链路与凭证都就绪 → 若仍不通，问题在**上游/协议层**（节点被拒、Q-Token 失效）。请报回 `king.lastError` 与顶层 `kingRefreshLogShared`。 |
| `false` | 任意 | **链指向错误**（本次修复目标）。若已是 0.5.67 仍为 false，说明还有第三个改写链的路径，请报回全部数值。 |
| 任意 | `0` | **凭证/池为空**（第二类）。请报回顶层 `kingRefreshLogShared`，看取号到底停在哪一步。 |

---

## 4. 若仍然闪退

请提供**报错原文**（截图或手抄的英文原文）。

已有信息：报错中疑似含 entitlement / "pick" 字样。核对结果：本 tweak 全树
**没有任何 entitlement 查询代码**（只有一处 `NSClassFromString(@"LCSharedUtils")`），
因此该报错来自 LiveContainer 本身或其签名流程，**不是本 dylib 主动查询的结果**；
而且 v0.5.66 起构造器与配置应用路径都已用 `@try/@catch` 兜住，
**本 tweak 不会再弄崩宿主**。

**准确的英文原文**能立刻区分是"签名/加载期失败"还是"运行期崩溃"。

---

## 5. 已知仍需真机确认的假设

以下假设无法在本机验证，是本次交付的残余风险（诚实记录）：

1. **`chainPortStale` 自愈真的生效**。逻辑与 C 层端口记账已由单元测试覆盖，但
   "心跳触发 → 重载 → 链端口更新"这一整条链只在真机可观测。判定字段：第 1、5 条。
2. **`leadTime` 语义修正（v0.5.65）覆盖的窗口是否就是实际踩中的窗口**。理论上
   凭证有效期最后 2 分钟会误清池；真机上是否确由它造成，未验证。
3. **"私有正常 / 共享失效"是否完全由并发度差异解释**。已排除路径差异、签名差异、
   override 差异；并发度是目前唯一能同时解释两者的变量，但**未在同网络下做 A/B 对照**
   （同一 Wi-Fi 下私有与共享各跑一次）。若能顺手做这个对照，价值很高。
4. **两份 dylib 共存是否曾直接导致闪退**。已确认共存事实存在（同 pid 两次加载记录），
   但未取得崩溃日志。清空 Tweaks 后若闪退消失，即可反证。

---

## 6. 本轮（v0.5.60–v0.5.67）累计改动速览

| 版本 | 改动 | 针对 |
|---|---|---|
| 0.5.60 | 强制刷新**不再先清空**在用凭证 | 取号成功却转发不出去的雪崩根因 |
| 0.5.61 | 被动刷新回调改为**零阻塞 + 限频 + 异步**；健康检查失败不再杀掉全部在飞连接 | 闪退 + 取号风暴 |
| 0.5.62 | 回调返回 `-1`（避免 C 层空跑一整轮代理）；间隔 20s；心跳不催取号 | 省资源、稳态零被动取号 |
| 0.5.63 | 删掉恒失败的重试循环；新增防重复加载守卫 | 省 client 线程（**该守卫已于 0.5.65 撤回**） |
| 0.5.64 | 新增 `statPoolEmpty` 诊断 | 让"池为空"可判定 |
| 0.5.65 | 修正 `leadTime` 语义混用（**提前清空代理池**）；撤回重复映像守卫；新增实时池大小 | 第二处提前清空点 |
| 0.5.66 | 关键入口**兜住 ObjC 异常**；暴露 `swallowedExceptions` | 确保本 tweak 绝不弄崩宿主 |
| 0.5.67 | **代理链端口陈旧自愈** + `chainProxyPort` / `chainPortMatches` | "status 全绿却完全连不上"的结构性缺口 |

取号量目标：**1341 次 → 稳态 0 次、异常时 ≤3 次/分**。