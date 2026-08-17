# Queen/King 免流代理协议说明（逆向验证版）

## 1. 角色与链路

```text
QQ浏览器
  │
  ├─ 1) PBProxy GetGuid ───────────────────────────► pbprx.qq.com
  │     得到 Q-GUID（16 字节设备 GUID）
  │
  ├─ 2) old-WUP TokenInfoReq ──────────────────────► qbwup.qq.com:8080
  │     请求 httpWupToken/getTokenInfo
  │     得到 Q-Token(sToken) 与 Q-Key(sKey)
  │
  ├─ 3) PBProxy GetIPListByRouter ─────────────────► pbprx.qq.com
  │     请求 iptype 15/16
  │     得到 queen_http(HTTPDOWN) 与 queen_https(HTTPSTUNNEL) 的 ip:port 池
  │
  └─ 4) 业务请求经 Queen 代理出网
         HTTP  ──► queen_http  代理（默认 8090）
         HTTPS ──► queen_https 代理（默认 8091，CONNECT 隧道）
```

> 说明：App 实际拉取 Queen 池子走旧 WUP `proxyip/getIPListByRouter`。
> 本包中 `fetch_queen_proxy_oldwup.py` 实现了该路径，可携带完整网络参数；
> `fetch_proxy_and_wup_servers.py` 则使用 PBProxy `GetIPListByRouter`，也能拿到
> 15/16 类型代理池。集成项目建议优先使用旧 WUP 脚本，并用真实网络参数请求，
> 避免拿到与当前网络不匹配的通用池。

---

## 2. 获取 Q-GUID / Q-Token / Q-Key

### 2.1 Q-GUID

- 通过 PBProxy `trpc.mtt.guid.guid/GetGuid` 获取服务器下发的 16 字节 GUID。
- 也可以本地生成 16 字节随机 GUID。
- **大小写敏感**：后续 Token 请求和代理认证必须使用同一字符串，保持一致。

### 2.2 Q-Token / Q-Key

旧 WUP 加密请求：

```text
URL      : http://qbwup.qq.com:8080/  (或其他 wup 镜像)
servant  : httpWupToken
func     : getTokenInfo
请求体    : MTT.TokenInfoReq { sGuid, sQua2, sPhoneNum }
```

响应字段：

| JCE tag | 字段 | 说明 |
|---|---|---|
| 0 | `rspCode` | 0 表示成功 |
| 1 | `sToken` | Q-Token，96 字符十六进制 |
| 2 | `iExpireTime` | 过期时间，单位秒 |
| 3 | `sKey` | Q-Key，通常是 16 字符 ASCII 字符串 |

### 2.3 获取代理端点（PBProxy 路径）

```text
URL      : https://pbprx.qq.com/
servant  : trpc.mtt.ipinfo.Ipinfo
func     : /trpc.mtt.ipinfo.Ipinfo/GetIPListByRouter
请求体    : 4 字节大端长度前缀 + PbProxy.PbRequest
```

`GetIPListByRouterRequest` 关键字段：

```text
UserInfo { 1: guid, 3: qua2 }
iptype_vec = [15, 16]
RemoteNetworkInfo {
  1: type_name   # MOBILE / WIFI / UNKNOW
  2: subtype     # 0=mobile, 1=wifi, -1=unknown
  3: extra_info  # uninet / 3gnet / 3gwap / uniwap / UNKNOW
  4: mccmnc      # 如 46001，未知为 NULLNULL
  5: cardtype    # 王卡可用=1，否则=0
}
```

响应中 `iptype` 与通道映射：

| iptype | 常量 | 通道 | 典型端口 |
|---|---|---|---|
| 15 | HTTPDOWN | queen_http | 8090 |
| 16 | HTTPSTUNNEL | queen_https | 8091 |
| 1 | WUPPROXY | 旧 WUP HTTP | 8080 |
| 25 | WUPPROXYNEW | 旧 WUP HTTP 新池 | 8080 |

---

## 3. 代理认证请求头（核心）

### 3.1 HTTP 请求走 queen_http（分头模式）

```http
GET http://目标URL HTTP/1.1
Host: 目标host
Q-GUID: <32位GUID>
Q-UA2: <QUA2_V3>
Q-Token: <sToken>
Q-Type: httpcom
Q-Key: <Q-Key 计算值，小写 hex>
Q-RequestId: <System.currentTimeMillis()>
User-Agent: MQQBrowser
Accept: */*
```

可选：`Q-DnsIp`、`Q-Count`；旧版还可能带 `Q-QIMEI`、`QIMEI36`。

### 3.2 HTTPS 请求走 queen_https（CONNECT 合并头）

先建立隧道：

```http
CONNECT 目标host:443 HTTP/1.1
Host: 目标host:443
Proxy-Authorization: Q-GUID|<guid>,Q-UA2|<qua2>,Q-Token|<token>,Q-Key|<qkey>,Q-RequestId|<reqid>,Q-Type|<qtype>
```

隧道建立后，内层 HTTPS 请求只带普通头，不再带 Queen 认证头。

### 3.3 Q-Key 算法（最容易错）

`Q-Key` 头值不是 TokenInfoRsp 里的 `sKey` 本身，而是用它做 AES 密钥加密一个 JCE 结构：

```text
plaintext = JCE(HttpInfoEncrypt) 的字段序列化，注意：没有 STRUCT_BEGIN/STRUCT_END 包装
  tag0: sGuid       # 32 位 GUID
  tag1: sDomain     # 目标域名，不带端口
  tag2: sUrl        # 完整 URL
  tag3: sRequestId  # 与 Q-RequestId 头相同的毫秒时间戳字符串

AES 参数：
  算法 = AES/ECB/PKCS7Padding
  密钥 = sKey 字符串的 UTF-8 字节（不是 hex 解码）
输出 = 小写十六进制字符串
```

Python 实现：

```python
from Crypto.Cipher import AES
from Crypto.Util.Padding import pad

# 推荐直接复用 verify_queen_proxy.py 中已实现的函数：
#   jce_head / jce_str / build_http_info_encrypt / build_qkey_header
from verify_queen_proxy import build_qkey_header

qkey_value = build_qkey_header(
    guid=guid,                # Q-GUID
    domain=domain,            # 目标域名，不带端口
    url=full_url,             # 完整 URL
    request_id=request_id,    # 与 Q-RequestId 相同的毫秒时间戳字符串
    qkey=sKey,                # TokenInfoRsp.sKey
)
```

### 3.4 代理响应码

| 状态码 | 含义 |
|---|---|
| 200 | 成功 |
| 820 | token failed / 认证失败 |
| 821 | token expired |
| 822 | IP 直连 |
| 823 | retry |
| 824 | force direct |

---

## 4. 代理池与当前网络匹配（免流计费关键）

代理 IP 本身由服务端根据请求里的 `RemoteNetworkInfo` 选择。App 在手机上会传真实网络信息：

| 字段 | 手机上的来源 |
|---|---|
| `type_name` | `d.e(ctx)`：Android 29+ 为 `MOBILE`/`WIFI`/`UNKNOW` |
| `subtype` | `d.d(ctx)`：0=mobile, 1=wifi, -1=unknown |
| `extra_info` | 移动网络时取 APN 名小写，如 `uninet`/`3gnet`/`3gwap`；WiFi 为 `UNKNOW` |
| `mccmnc` | `d.f(ctx)+d.h(ctx)`，联通常见 `46001`/`46006`；未知为 `NULLNULL` |
| `cardtype` | 王卡可用时 1，否则 0 |

集成项目在真机上应采集上述值并传入，否则只能拿到通用池，可能不在联通王卡免流 IP 白名单内。

中国联通常见组合：

```text
--mccmnc 46001 --apn-type MOBILE --apn-subtype 0 --apn-extra uninet --card-type 1
```

`verify_queen_proxy.py` 已支持这些参数（`--refresh-proxy` 时生效）。

---

## 5. 已知陷阱

1. `Q-GUID` 大小写敏感，与取 Token 时保持一致。
2. `Q-Key` 的 AES 密钥是 `sKey` 字符串的 UTF-8 字节，不是 `sKey` 的 hex 解码。
3. HTTP 与 HTTPS 代理端口/池不同，不能混用。
4. HTTPS 认证头必须放在 CONNECT 的 `Proxy-Authorization` 上，不能放在内层请求。
5. 如果 Q-Key 算错但其他头正确，代理会返回 820；如果 Q-Key 不传，旧版 HTTP 路径可能放行，但新版 App 会传。
6. 缓存代理池可能过期或网络不匹配，关键业务建议 `--refresh-proxy` 并传真实网络参数。
