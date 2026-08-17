# Queen/King 免流代理集成包

本目录是从 QQ 浏览器逆向工程中沉淀下来、已经过实网验证的 Queen（腾讯王卡）免流代理获取与连接验证脚本集合。可供集成项目直接调用或改造。

## 已验证的核心能力

1. 获取 `Q-GUID`：通过 PBProxy `GetGuid`，或本地生成合法 GUID。
2. 获取 `Q-Token` / `Q-Key`：通过旧 WUP `httpWupToken/getTokenInfo` 加密请求。
3. 获取 Queen 代理端点：
   - 旧 WUP 路径 `proxyip/getIPListByRouter`（App 实际使用，支持完整网络匹配参数）
   - PBProxy 路径 `trpc.mtt.ipinfo.Ipinfo/GetIPListByRouter`
4. 连接代理并验证出网 IP：支持 HTTP 代理（queen_http）和 HTTPS CONNECT 隧道（queen_https），默认使用 `ip.3322.net` 回显 IP 做验证。

## 目录结构

```text
queen_proxy_kit/
├── fetch_q_token.py                  # 获取 Q-GUID / Q-Token / Q-Key
├── fetch_proxy_and_wup_servers.py    # PBProxy 获取 queen_http / queen_https 代理池
├── fetch_queen_proxy_oldwup.py       # 旧 WUP proxyip/getIPListByRouter 获取代理池（App 真实路径）
├── verify_queen_proxy.py             # 一站式：获取凭据 -> 获取代理 -> 连接验证
├── docs/
│   ├── protocol.md                   # 协议细节、请求头、Q-Key 算法、网络匹配等
│   └── usage.md                      # 每个脚本的使用方法与集成示例
├── sample/
│   └── proxy_and_wup_servers.sample.json
└── requirements.txt
```

## 依赖安装

```bash
pip install -r requirements.txt
```

## 快速开始

### 1. 获取 Q-Token / Q-Key

```bash
python fetch_q_token.py --phone 13075020119
```

输出末尾有 `JSON={...}`，其中 `q_token` 和 `q_key` 就是后续代理认证需要的凭据。

### 2. 获取代理池

PBProxy 路径：

```bash
python fetch_proxy_and_wup_servers.py <Q-GUID> <Q-UA2>
```

旧 WUP 路径（App 实际使用的 `proxyip/getIPListByRouter`，可携带完整网络匹配参数）：

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

或直接使用 `verify_queen_proxy.py` 自动刷新。

### 3. 验证代理是否可用

有已知凭据时（推荐，避免重复取号）：

```bash
python verify_queen_proxy.py \
  --guid <32位Q-GUID> \
  --token <Q-Token> \
  --qkey <Q-Key> \
  --try-all
```

全自动方式（会重新获取 GUID 和 Token）：

```bash
python verify_queen_proxy.py --phone 13075020119 --try-all
```

## 重要提醒

- `Q-GUID` 大小写敏感：取 Token 时用什么大小写，代理头里就传什么大小写。
- Token 与 GUID 绑定：传 `--token/--qkey` 时必须同时传 `--guid`。
- HTTP 代理和 HTTPS 代理是**不同的 ip:port 列表**，不要混用。
- 如果目标是联通王卡免流计费，务必用真实网络参数刷新代理池，见 `docs/protocol.md` 和 `docs/usage.md`。
