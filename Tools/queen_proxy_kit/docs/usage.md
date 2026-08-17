# 使用说明与集成指南

## 1. 环境要求

- Python 3.8+
- 依赖：`pip install -r requirements.txt`
- 网络：需要能访问 `pbprx.qq.com`、`qbwup.qq.com` 和 Queen 代理池（国内网络）

## 2. 脚本说明

### 2.1 fetch_q_token.py — 获取凭据

```bash
python fetch_q_token.py --phone 13075020119
```

常用参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--phone` | 18812341234 | TokenInfoReq 里的手机号 |
| `--guid` | 自动获取 | 已有 GUID 时传入，32 位 hex |
| `--qua2` | 自动生成 | Q-UA2 字符串 |
| `--server` | 无 | 追加 WUP 端点 URL |
| `--mode` | 1,2 都试 | 加密模式：1=ECB/encrypt=12，2=CBC/encrypt=17 |
| `--timeout` | 10 | 请求超时秒数 |
| `--max-attempts` | 50 | 轮换代理尝试次数 |

成功时输出：

```text
[+] TokenInfoRsp parsed:
    Q-Token    = ...
    Q-Key      = ...
JSON={"q_token": "...", "q_key": "...", ...}
```

### 2.2 fetch_proxy_and_wup_servers.py — 获取代理池

```bash
python fetch_proxy_and_wup_servers.py <Q-GUID> <Q-UA2>
```

- 默认请求 iptype `[1, 15, 16, 25]`
- 结果写入 `proxy_and_wup_servers.json`

返回 JSON：

```json
{
  "queen_http": ["116.130.x.x:8090", ...],
  "queen_https": ["125.39.x.x:8091", ...],
  "old_wup_http": [...],
  "old_wup_http_new": [...]
}
```

### 2.3 fetch_queen_proxy_oldwup.py — 旧 WUP 路径获取代理池（App 真实路径）

```bash
python fetch_queen_proxy_oldwup.py \
  --guid <Q-GUID> \
  --mccmnc 46001 \
  --apn 3gnet \
  --type-name MOBILE \
  --subtype 0 \
  --extra-info uninet \
  --card-type 1
```

常用参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--guid` | 自动获取 | Q-GUID，32 位 hex |
| `--apn` | UNKNOW | UserBase.sAPN，手机当前 APN 名 |
| `--type-name` | UNKNOW | RouteIPListReq.sTypeName |
| `--subtype` | 0 | 0=mobile, 1=wifi, -1=unknown |
| `--extra-info` | UNKNOW | APN 附加信息小写，如 uninet/3gnet/3gwap |
| `--mccmnc` | NULLNULL | MCC+MNC，如 46001 |
| `--card-type` | 1 | 王卡可用=1，否则=0 |
| `--server` | http://qbwup.qq.com:8080/ | 旧 WUP 端点 |
| `--mode` | 1,2 都试 | 1=ECB/encrypt=12，2=CBC/encrypt=17 |
| `--output` | queen_proxy_oldwup_result.json | 结果 JSON |

输出包含 `response.queen_http` 与 `response.queen_https`。

### 2.4 verify_queen_proxy.py — 一站式验证

#### 方式 A：使用已有凭据（推荐）

```bash
python verify_queen_proxy.py \
  --guid 156DFD39C896CADEA5DFE8D8532888CB \
  --token <Q-Token> \
  --qkey <Q-Key> \
  --try-all
```

#### 方式 B：全自动

```bash
python verify_queen_proxy.py --phone 13075020119 --try-all
```

#### 方式 C：刷新代理池并带真实网络参数

```bash
python verify_queen_proxy.py \
  --phone 13075020119 \
  --refresh-proxy \
  --mccmnc 46001 \
  --apn-type MOBILE \
  --apn-subtype 0 \
  --apn-extra uninet \
  --card-type 1 \
  --try-all
```

#### 常用参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--guid` | 自动获取 | Q-GUID，32 位 hex |
| `--token` / `--qkey` | 自动获取 | 已有凭据时必须成对传 |
| `--phone` | 18812341234 | 全自动获取 Token 时的手机号 |
| `--proxy-json` | proxy_and_wup_servers.json | 代理池缓存文件 |
| `--refresh-proxy` | 否 | 强制重新拉取代理池 |
| `--url` | http://ip.3322.net/ | HTTP 验证 URL |
| `--https-url` | https://ip.3322.net/ | HTTPS 验证 URL |
| `--qtype` | httpcom | Q-Type 值 |
| `--mccmnc` | NULLNULL | 刷新代理池时上报的 MCCMNC |
| `--apn-type` | UNKNOW | 刷新代理池时上报的网络类型 |
| `--apn-subtype` | 0 | 刷新代理池时上报的子类型 |
| `--apn-extra` | UNKNOW | 刷新代理池时上报的 APN 附加信息 |
| `--card-type` | 1 | 刷新代理池时上报的王卡状态 |
| `--try-all` | 否 | 测试所有代理端点，否则只测第一个 |
| `--timeout` | 15 | 超时秒数 |
| `--save-json` | queen_proxy_verify_result.json | 验证结果文件 |

## 3. 集成建议

### 3.1 直接 import

三个脚本在同一目录，`verify_queen_proxy.py` 已经 `sys.path.insert` 了自身目录，因此：

```python
import fetch_q_token as fqt
import fetch_proxy_and_wup_servers as fp
import verify_queen_proxy as vqp
```

可复用函数：

- `fqt.fetch_guid_from_server(qua2)` → `guid`
- `fqt.build_request_envelope(...)` / `fqt.try_one_endpoint(...)` → 获取 Token
- `fp.build_request(guid, qua2)` → 代理池请求
- `vqp.build_qkey_header(guid, domain, url, request_id, qkey)` → Q-Key 头
- `vqp.build_queen_headers_http(...)` → HTTP 分头
- `vqp.build_queen_proxy_authorization(...)` → HTTPS Proxy-Authorization

### 3.2 最小集成流程

```python
import fetch_q_token as fqt
import verify_queen_proxy as vqp

qua2 = fqt.generate_qua2()
guid = fqt.fetch_guid_from_server(qua2)          # 或使用已持久化的 GUID

# 获取 Token / QKey（可缓存，注意过期时间）
body0, body_to_encrypt, enc_body, query, headers, key, iv = fqt.build_request_envelope(guid, qua2, phone, mode=1)
resp, data, plain = fqt.try_one_endpoint("http://qbwup.qq.com:8080/", enc_body, query, headers, key, iv, 1, 15)
rsp = fqt.parse_wup_response(plain)
token, qkey = rsp[1], rsp[3]

# 计算 Q-Key 请求头
request_id = str(int(time.time() * 1000))
qkey_header = vqp.build_qkey_header(guid, "ip.3322.net", "http://ip.3322.net/", request_id, qkey)
```

### 3.3 关键约定

- **GUID 持久化**：GUID 与 Token/Q-Key 绑定，集成项目不要每次重新生成。
- **Token 缓存**：Token 有过期时间（通常 7200 秒），失效后代理返回 821，需重新获取。
- **代理池缓存**：代理池有生命周期，失效后重新拉取。
- **网络参数**：真机上取 `MCCMNC`、APN 名、网络类型后传给刷新函数，保证池子匹配。
- **HTTPS 代理**：必须用 `urllib3.ProxyManager(proxy_url="http://<queen_https>", proxy_headers={"Proxy-Authorization": ...})` 这类 API，确保 `Proxy-Authorization` 加在 CONNECT 上。
