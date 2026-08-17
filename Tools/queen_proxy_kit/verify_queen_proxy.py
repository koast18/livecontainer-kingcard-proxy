#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Fetch Queen/King-card proxy endpoints and verify them through an IP-echo site.

Credentials come from the existing scripts:
    fetch_q_token.py            -> Q-GUID / Q-Token / Q-Key (TokenInfoReq over old WUP)
    fetch_proxy_and_wup_servers.py -> queen_http / queen_https proxy endpoints
                                      (PBProxy GetIPListByRouter)

Proxy request-header details recovered from decompiled Java:

  queen_http (iptype=15, HTTPDOWN):
      For a plain HTTP request through the proxy, the app sends these
      headers *to the proxy* (absolute-form request):
        Q-GUID      = 32 hex device GUID
        Q-UA2       = QUA2_V3 string
        Q-Token     = sToken from TokenInfoRsp
        Q-Type      = resource type, e.g. "httpcom"
        Q-Key       = AES/ECB/PKCS7Padding(JCE(HttpInfoEncrypt), sKey bytes)
                      result as lowercase hex
        Q-RequestId = str(System.currentTimeMillis())
      Optional: Q-DnsIp, Q-Count, Q-QIMEI, QIMEI36

  queen_https (iptype=16, HTTPSTUNNEL):
      For an HTTPS request the app opens a CONNECT tunnel and sends one
      combined header on the CONNECT:
        Proxy-Authorization: Q-GUID|<guid>,Q-UA2|<qua2>,Q-Token|<token>,
                             Q-Key|<qkey>,Q-RequestId|<requestId>,
                             Q-Type|<qtype>[,Q-DnsIp|<ip>][,Q-Count|<n>]
      Inside the tunnel the target request carries ordinary headers only.

  HttpInfoEncrypt JCE layout (JceStruct.toByteArray = fields only,
  *no* STRUCT_BEGIN/STRUCT_END wrapper):
      tag0: sGuid
      tag1: sDomain   (target host, no port)
      tag2: sUrl      (full request URL)
      tag3: sRequestId
  AES key = sKey (Q-Key string) encoded as UTF-8 bytes.

  Proxy response codes:
      200  OK
      820  token failed
      821  token expired
      822  IP direct
      823  retry
      824  force direct
"""
import argparse
import json
import re
import struct
import sys
import time
from pathlib import Path

try:
    import urllib3
    from Crypto.Cipher import AES
    from Crypto.Util.Padding import pad
except ImportError as exc:
    raise SystemExit("Missing dependency. Run: pip install urllib3 pycryptodome") from exc

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Import existing scripts (same directory).  They are used as libraries only.
BASE = Path(__file__).resolve().parent
try:
    sys.path.insert(0, str(BASE))
    import fetch_q_token as fqt
    import fetch_proxy_and_wup_servers as fp
except Exception as exc:  # pragma: no cover
    raise SystemExit(f"Could not import existing scripts fetch_q_token.py / "
                     f"fetch_proxy_and_wup_servers.py: {exc}") from exc

PROXY_JSON = BASE / "proxy_and_wup_servers.json"
RESULT_JSON = BASE / "queen_proxy_verify_result.json"

HTTP_VERIFY_URL = "http://ip.3322.net/"
HTTPS_VERIFY_URL = "https://ip.3322.net/"

# Queen proxy response codes from QBCode.HttpCode
PROXY_CODE_MSG = {
    200: "OK",
    820: "QUEEN_HTTP_TOKEN_FAILED",
    821: "QUEEN_HTTP_TOKEN_EXPIRED",
    822: "QUEEN_HTTP_IP_DIRECT",
    823: "QUEEN_HTTP_RETRY",
    824: "QUEEN_HTTP_FORCE_DIRECT",
}


# ---------------------------------------------------------------------------
# IP-list request helpers (RemoteNetworkInfo from serverconfig/d.java + h.java)
# ---------------------------------------------------------------------------
def build_get_ip_list_request(guid, qua2, type_name="UNKNOW", subtype=0,
                              extra_info="UNKNOW", mccmnc="NULLNULL",
                              card_type=1, iptypes=(15, 16)):
    """Build GetIPListByRouterRequest protobuf for PBProxy.

    The real app fills RemoteNetworkInfo from the current APN/network:
      type_name  = d.e(context)   e.g. "MOBILE" / "WIFI" / "UNKNOW"
      subtype    = d.d(context)   0 mobile, 1 wifi, -1 unknown
      extra_info = d.c(context)   e.g. "uninet" / "3gwap" / "UNKNOW"
      mccmnc     = d.f()+d.h()    e.g. "46001" or "NULLNULL"
      card_type  = QueenConfig.isQueenEnable() ? 1 : 0
    """
    user = fp.ps(1, guid) + fp.ps(3, qua2)
    net = (fp.ps(1, type_name)
           + fp.pv2(2, subtype)
           + fp.ps(3, extra_info)
           + fp.ps(4, mccmnc)
           + fp.pv2(5, card_type))
    return (fp.pl(2, user)
            + fp.pl(4, b"".join(fp.pv(t) for t in iptypes))
            + fp.pl(5, net))


# ---------------------------------------------------------------------------
# JCE helpers (same as fetch_q_token.py but repeated here for clarity)
# ---------------------------------------------------------------------------
def jce_head(type_byte: int, tag: int) -> bytes:
    if tag < 15:
        return bytes([((tag & 0x0F) << 4) | (type_byte & 0x0F)])
    if tag < 256:
        return bytes([0xF0 | (type_byte & 0x0F), tag & 0xFF])
    raise ValueError("JCE tag too large")


def jce_str(value: str, tag: int) -> bytes:
    data = value.encode("utf-8")
    if len(data) > 255:
        return jce_head(7, tag) + len(data).to_bytes(4, "big") + data
    return jce_head(6, tag) + bytes([len(data)]) + data


def build_http_info_encrypt(guid: str, domain: str, url: str, request_id: str) -> bytes:
    """JceStruct.toByteArray() for HttpInfoEncrypt: fields only, no wrapper."""
    return (
        jce_str(guid, 0)
        + jce_str(domain, 1)
        + jce_str(url, 2)
        + jce_str(request_id, 3)
    )


def build_qkey_header(guid: str, domain: str, url: str, request_id: str, qkey: str) -> str:
    plain = build_http_info_encrypt(guid, domain, url, request_id)
    return AES.new(qkey.encode("utf-8"), AES.MODE_ECB).encrypt(pad(plain, 16)).hex()


def build_queen_headers_http(guid, qua2, token, qkey, url, qtype, request_id=None,
                             dns_ip="", count=0, qimei="", qimei36=""):
    """Headers for a plain HTTP request sent through queen_http proxy."""
    host = urllib3.util.parse_url(url).host or ""
    request_id = request_id or str(int(time.time() * 1000))
    qkey_value = build_qkey_header(guid, host, url, request_id, qkey)
    headers = {
        "Q-GUID": guid,
        "Q-UA2": qua2,
        "Q-Token": token,
        "Q-Type": qtype,
        "Q-Key": qkey_value,
        "Q-RequestId": request_id,
        "User-Agent": "MQQBrowser",
        "Accept": "*/*",
    }
    if dns_ip:
        headers["Q-DnsIp"] = dns_ip
    if count > 0:
        headers["Q-Count"] = str(count)
    if qimei:
        headers["Q-QIMEI"] = qimei
    if qimei36:
        headers["QIMEI36"] = qimei36
    return headers, qkey_value, request_id


def build_queen_proxy_authorization(guid, qua2, token, qkey, url, qtype,
                                    request_id=None, dns_ip="", count=0,
                                    qimei="", qimei36=""):
    """Combined Proxy-Authorization header for queen_https CONNECT tunnel."""
    host = urllib3.util.parse_url(url).host or ""
    request_id = request_id or str(int(time.time() * 1000))
    qkey_value = build_qkey_header(guid, host, url, request_id, qkey)
    parts = [
        f"Q-GUID|{guid}",
        f"Q-UA2|{qua2}",
        f"Q-Token|{token}",
        f"Q-Key|{qkey_value}",
        f"Q-RequestId|{request_id}",
        f"Q-Type|{qtype}",
    ]
    if dns_ip:
        parts.append(f"Q-DnsIp|{dns_ip}")
    if count > 0:
        parts.append(f"Q-Count|{count}")
    if qimei:
        parts.append(f"Q-QIMEI|{qimei}")
    if qimei36:
        parts.append(f"QIMEI36|{qimei36}")
    return ",".join(parts), qkey_value, request_id


# ---------------------------------------------------------------------------
# Credential / proxy fetching (reuses the existing scripts)
# ---------------------------------------------------------------------------
def fetch_token_from_wup(guid, qua2, phone, mode=1, timeout=10.0):
    body0, body_to_encrypt, enc_body, query_string, headers, aes_key, iv_hex = \
        fqt.build_request_envelope(guid, qua2, phone, mode)
    for url in fqt.load_server_urls():
        try:
            resp, data, plain = fqt.try_one_endpoint(
                url, enc_body, query_string, headers, aes_key, iv_hex, mode, timeout
            )
            if resp.status_code != 200 or plain is None:
                continue
            rsp = fqt.parse_wup_response(plain)
            token = rsp.get(1)
            qkey = rsp.get(3)
            if rsp.get(0) == 0 and token and qkey is not None:
                return {
                    "token": token,
                    "qkey": qkey,
                    "expire_seconds": rsp.get(2),
                    "url": url,
                    "http_tk": resp.headers.get("tk"),
                    "http_maxage": resp.headers.get("maxage"),
                }
        except Exception as exc:
            print(f"    [!] {url}: {exc!r}", file=sys.stderr)
    return None


def get_credentials(args):
    """Return (guid, qua2, token, qkey).  Fetch missing parts with existing scripts."""
    qua2 = args.qua2 or fqt.generate_qua2()
    if args.qua2:
        print(f"[*] using Q-UA2: {qua2}")
    else:
        print(f"[*] auto-generated Q-UA2: {qua2}")

    if (args.token or args.qkey) and not args.guid:
        raise SystemExit("--guid is required when --token/--qkey are provided (token is bound to guid)")

    guid = args.guid
    if guid:
        guid = guid.replace("-", "")
        if len(guid) != 32:
            raise SystemExit("--guid must be 32 hex characters (16 bytes)")
        try:
            bytes.fromhex(guid)
        except ValueError as exc:
            raise SystemExit("--guid must be hex") from exc
        print(f"[*] using Q-GUID: {guid}")
    else:
        guid = None
        for attempt in range(1, 4):
            try:
                guid = fqt.fetch_guid_from_server(qua2, timeout=max(args.timeout, 10.0))
                print(f"[*] fetched server Q-GUID: {guid}")
                break
            except Exception as exc:
                print(f"[!] GetGuid attempt {attempt} failed: {exc!r}", file=sys.stderr)
        if not guid:
            raise SystemExit("Failed to fetch Q-GUID. Pass --guid to use a known one.")

    if args.token and args.qkey:
        token, qkey = args.token, args.qkey
        print("[*] using provided Q-Token / Q-Key")
        print(f"    Q-Token = {token[:16]}... ({len(token)} chars)")
        print(f"    Q-Key   = {qkey}")
    elif args.token or args.qkey:
        raise SystemExit("--token and --qkey must be provided together")
    else:
        print(f"[*] fetching Q-Token / Q-Key with phone={args.phone}")
        for mode in (1, 2):
            info = fetch_token_from_wup(guid, qua2, args.phone, mode=mode,
                                        timeout=args.timeout)
            if info:
                token, qkey = info["token"], info["qkey"]
                print(f"[+] fetched Q-Token from {info['url']} (mode={mode}, "
                      f"expire={info.get('expire_seconds')}s)")
                print(f"    Q-Token = {token[:16]}... ({len(token)} chars)")
                print(f"    Q-Key   = {qkey}")
                break
        else:
            raise SystemExit("Failed to fetch Q-Token / Q-Key. Pass --token and --qkey to use known ones.")

    return guid, qua2, token, qkey


def get_proxy_servers(args, guid, qua2):
    """Load queen_http / queen_https endpoints from JSON or fetch from PBProxy."""
    if args.refresh_proxy or not args.proxy_json.exists():
        print("[*] fetching Queen proxy endpoints from PBProxy GetIPListByRouter ...")
        inner = build_get_ip_list_request(
            guid, qua2,
            type_name=args.apn_type, subtype=args.apn_subtype,
            extra_info=args.apn_extra, mccmnc=args.mccmnc,
            card_type=args.card_type, iptypes=(15, 16),
        )
        msg = (fp.pv2(1, 1)
               + fp.ps(2, fp.SERVANT)
               + fp.ps(3, fp.FUNC)
               + fp.pl(4, inner))
        body = struct.pack(">I", len(msg) + 4) + msg
        headers = {
            "Host": "pbprx.qq.com",
            "Content-Type": "application/multipart-formdata",
            "User-Agent": "MQQBrowser",
            "Accept": "*/*",
            "PB": "1",
            "Q-GUID": guid,
            "Q-UA2": qua2,
            "Traceid": str(int(time.time() * 1000)),
        }
        resp = fp.requests.post(fp.URL, data=body, headers=headers,
                                timeout=args.timeout, verify=False)
        if resp.status_code != 200:
            raise SystemExit(f"PBProxy HTTP {resp.status_code}: {resp.content[:300]!r}")
        raw = resp.content
        total = struct.unpack(">I", raw[:4])[0]
        fs = fp.fields(raw[4:4 + total])
        inner_rsp = fp.gb(fs, 4)
        if inner_rsp is None:
            raise SystemExit("PBProxy reply has no inner response")
        ifs = fp.fields(inner_rsp)
        queen_http, queen_https = [], []
        for _, val in ifs.get(2, []):
            jf = fp.fields(val)
            ipt = fp.gv(jf, 1)
            servers = [s.decode("utf-8", "replace") for _, s in jf.get(2, [])]
            if ipt == 15:
                queen_http.extend(servers)
            elif ipt == 16:
                queen_https.extend(servers)
        data = {}
        if args.proxy_json.exists():
            try:
                data = json.loads(args.proxy_json.read_text(encoding="utf-8"))
            except Exception:
                data = {}
        data["queen_http"] = queen_http
        data["queen_https"] = queen_https
        args.proxy_json.write_text(json.dumps(data, ensure_ascii=False, indent=2),
                                   encoding="utf-8")
        print(f"[+] saved fresh proxy list to {args.proxy_json}")
    else:
        try:
            data = json.loads(args.proxy_json.read_text(encoding="utf-8"))
        except Exception as exc:
            raise SystemExit(f"Failed to parse {args.proxy_json}: {exc}") from exc
        print(f"[*] using proxy list from {args.proxy_json}")

    queen_http = data.get("queen_http", [])
    queen_https = data.get("queen_https", [])
    if not queen_http and not queen_https:
        raise SystemExit(f"No queen_http/queen_https entries found in {args.proxy_json}")
    print(f"    queen_http  ({len(queen_http)}): {queen_http}")
    print(f"    queen_https ({len(queen_https)}): {queen_https}")
    return queen_http, queen_https


# ---------------------------------------------------------------------------
# Verification helpers
# ---------------------------------------------------------------------------
def parse_ip_text(data: bytes, text: str = None) -> str:
    text = text if text is not None else data.decode("utf-8", "replace")
    m = re.search(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", text)
    return m.group(0) if m else ""


def verify_http_via_proxy(proxy, guid, qua2, token, qkey, url, qtype, timeout,
                          dns_ip="", count=0, qimei="", qimei36=""):
    headers, qkey_value, request_id = build_queen_headers_http(
        guid, qua2, token, qkey, url, qtype, dns_ip=dns_ip, count=count,
        qimei=qimei, qimei36=qimei36,
    )
    proxy_url = f"http://{proxy}"
    pm = urllib3.ProxyManager(proxy_url=proxy_url,
                              proxy_headers={},
                              timeout=urllib3.Timeout(connect=timeout, read=timeout),
                              retries=False)
    r = pm.request("GET", url, headers=headers)
    body = r.data
    text = body.decode("utf-8", "replace")
    return {
        "mode": "http",
        "proxy": proxy,
        "proxy_url": proxy_url,
        "url": url,
        "status": r.status,
        "status_msg": PROXY_CODE_MSG.get(r.status, ""),
        "headers_sent": headers,
        "response_headers": dict(r.headers),
        "body_head": text[:200],
        "ip": parse_ip_text(body, text),
        "qkey": qkey_value,
        "request_id": request_id,
    }


def verify_https_via_proxy(proxy, guid, qua2, token, qkey, url, qtype, timeout,
                           dns_ip="", count=0, qimei="", qimei36=""):
    proxy_auth, qkey_value, request_id = build_queen_proxy_authorization(
        guid, qua2, token, qkey, url, qtype, dns_ip=dns_ip, count=count,
        qimei=qimei, qimei36=qimei36,
    )
    proxy_url = f"http://{proxy}"
    pm = urllib3.ProxyManager(
        proxy_url=proxy_url,
        proxy_headers={"Proxy-Authorization": proxy_auth},
        timeout=urllib3.Timeout(connect=timeout, read=timeout),
        retries=False,
    )
    r = pm.request("GET", url, headers={"User-Agent": "MQQBrowser", "Accept": "*/*"})
    body = r.data
    text = body.decode("utf-8", "replace")
    return {
        "mode": "https",
        "proxy": proxy,
        "proxy_url": proxy_url,
        "url": url,
        "status": r.status,
        "status_msg": PROXY_CODE_MSG.get(r.status, ""),
        "proxy_authorization": proxy_auth,
        "response_headers": dict(r.headers),
        "body_head": text[:200],
        "ip": parse_ip_text(body, text),
        "qkey": qkey_value,
        "request_id": request_id,
    }


def verify_direct(url, timeout):
    pm = urllib3.PoolManager(timeout=urllib3.Timeout(connect=timeout, read=timeout),
                             retries=False)
    r = pm.request("GET", url, headers={"User-Agent": "MQQBrowser", "Accept": "*/*"})
    body = r.data
    text = body.decode("utf-8", "replace")
    return {
        "mode": "direct",
        "url": url,
        "status": r.status,
        "response_headers": dict(r.headers),
        "body_head": text[:200],
        "ip": parse_ip_text(body, text),
    }


def main():
    parser = argparse.ArgumentParser(
        description="Fetch Queen proxy endpoints and verify them through an IP-echo site.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--guid", default=None, help="32-hex Q-GUID; if omitted, fetch via PBProxy GetGuid")
    parser.add_argument("--qua2", default=None, help="Q-UA2 string; if omitted, auto-generate")
    parser.add_argument("--phone", default="18812341234", help="SIM phone number for TokenInfoReq")
    parser.add_argument("--token", default=None, help="existing Q-Token (must pair with --qkey)")
    parser.add_argument("--qkey", default=None, help="existing Q-Key from TokenInfoRsp (must pair with --token)")
    parser.add_argument("--proxy-json", default=str(PROXY_JSON),
                        help=f"cached proxy list JSON (default: {PROXY_JSON.name})")
    parser.add_argument("--refresh-proxy", action="store_true",
                        help="always re-fetch queen_http/queen_https from PBProxy")
    parser.add_argument("--url", default=HTTP_VERIFY_URL,
                        help=f"plain HTTP URL used for queen_http verification (default: {HTTP_VERIFY_URL})")
    parser.add_argument("--https-url", default=HTTPS_VERIFY_URL,
                        help=f"HTTPS URL used for queen_https CONNECT verification (default: {HTTPS_VERIFY_URL})")
    parser.add_argument("--qtype", default="httpcom",
                        help="Q-Type value sent to the proxy (default: httpcom)")
    parser.add_argument("--apn-type", default="UNKNOW",
                        help="RemoteNetworkInfo.type_name used when refreshing proxies "
                             "(default: UNKNOW; on a phone this is MOBILE/WIFI)")
    parser.add_argument("--apn-subtype", type=int, default=0,
                        help="RemoteNetworkInfo.subtype used when refreshing proxies "
                             "(default: 0; on Android 29+: 0=mobile, 1=wifi, -1=unknown)")
    parser.add_argument("--apn-extra", default="UNKNOW",
                        help="RemoteNetworkInfo.extra_info, e.g. uninet/3gwap/UNKNOW")
    parser.add_argument("--mccmnc", default="NULLNULL",
                        help="RemoteNetworkInfo.mccmnc, e.g. 46001 for China Unicom")
    parser.add_argument("--card-type", type=int, default=1,
                        help="RemoteNetworkInfo.cardtype: 1 when Queen enabled, else 0")
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--try-all", action="store_true",
                        help="test all delivered proxy endpoints instead of only the first")
    parser.add_argument("--dns-ip", default="", help="optional Q-DnsIp header value")
    parser.add_argument("--count", type=int, default=0, help="optional Q-Count header value")
    parser.add_argument("--qimei", default="", help="optional Q-QIMEI header value")
    parser.add_argument("--qimei36", default="", help="optional QIMEI36 header value")
    parser.add_argument("--save-json", default=str(RESULT_JSON),
                        help=f"save verification result JSON (default: {RESULT_JSON.name})")
    args = parser.parse_args()

    args.proxy_json = Path(args.proxy_json)

    print("=" * 70)
    print("Step 1: credentials (Q-GUID / Q-Token / Q-Key)")
    print("=" * 70)
    guid, qua2, token, qkey = get_credentials(args)

    print()
    print("=" * 70)
    print("Step 2: Queen proxy endpoints")
    print("=" * 70)
    queen_http, queen_https = get_proxy_servers(args, guid, qua2)

    results = {"direct": [], "http": [], "https": []}

    print()
    print("=" * 70)
    print("Step 3: direct baseline (no proxy)")
    print("=" * 70)
    for label, url in (("HTTP", args.url), ("HTTPS", args.https_url)):
        try:
            res = verify_direct(url, args.timeout)
            results["direct"].append(res)
            print(f"[*] direct {label} {url} -> HTTP {res['status']}, ip={res['ip'] or '-'}")
        except Exception as exc:
            print(f"[!] direct {label} failed: {exc!r}")
            results["direct"].append({"mode": "direct", "url": url, "error": repr(exc)})

    print()
    print("=" * 70)
    print("Step 4: verify through queen_http proxy (HTTP)")
    print("=" * 70)
    if not args.url.lower().startswith("http://"):
        print("[!] --url should be http:// for queen_http; skipping HTTP proxy test")
    elif not queen_http:
        print("[!] no queen_http endpoints")
    else:
        proxies_to_test = queen_http if args.try_all else queen_http[:1]
        for proxy in proxies_to_test:
            try:
                res = verify_http_via_proxy(
                    proxy, guid, qua2, token, qkey, args.url, args.qtype, args.timeout,
                    dns_ip=args.dns_ip, count=args.count,
                    qimei=args.qimei, qimei36=args.qimei36,
                )
                results["http"].append(res)
                print(f"[*] HTTP proxy {proxy} -> HTTP {res['status']} "
                      f"({res['status_msg'] or 'OK'}), ip={res['ip'] or '-'}")
                print(f"    Q-Key        = {res['qkey']}")
                print(f"    Q-RequestId  = {res['request_id']}")
                print(f"    response hdr = {res['response_headers']}")
                print(f"    body head    = {res['body_head'][:120]!r}")
            except Exception as exc:
                print(f"[!] HTTP proxy {proxy} failed: {exc!r}")
                results["http"].append({"mode": "http", "proxy": proxy, "url": args.url,
                                        "error": repr(exc)})

    print()
    print("=" * 70)
    print("Step 5: verify through queen_https proxy (CONNECT tunnel)")
    print("=" * 70)
    if not args.https_url.lower().startswith("https://"):
        print("[!] --https-url should be https:// for queen_https; skipping HTTPS proxy test")
    elif not queen_https:
        print("[!] no queen_https endpoints")
    else:
        proxies_to_test = queen_https if args.try_all else queen_https[:1]
        for proxy in proxies_to_test:
            try:
                res = verify_https_via_proxy(
                    proxy, guid, qua2, token, qkey, args.https_url, args.qtype, args.timeout,
                    dns_ip=args.dns_ip, count=args.count,
                    qimei=args.qimei, qimei36=args.qimei36,
                )
                results["https"].append(res)
                print(f"[*] HTTPS proxy {proxy} -> HTTP {res['status']} "
                      f"({res['status_msg'] or 'OK'}), ip={res['ip'] or '-'}")
                print(f"    Q-Key        = {res['qkey']}")
                print(f"    Q-RequestId  = {res['request_id']}")
                print(f"    Proxy-Authorization = {res['proxy_authorization'][:160]}...")
                print(f"    response hdr = {res['response_headers']}")
                print(f"    body head    = {res['body_head'][:120]!r}")
            except Exception as exc:
                print(f"[!] HTTPS proxy {proxy} failed: {exc!r}")
                results["https"].append({"mode": "https", "proxy": proxy,
                                         "url": args.https_url, "error": repr(exc)})

    out = {
        "guid": guid,
        "qua2": qua2,
        "queen_http_proxies": queen_http,
        "queen_https_proxies": queen_https,
        "results": results,
    }
    Path(args.save_json).write_text(json.dumps(out, ensure_ascii=False, indent=2),
                                    encoding="utf-8")
    print()
    print(f"[*] verification result saved to {args.save_json}")

    ok_http = any(r.get("status") == 200 for r in results["http"])
    ok_https = any(r.get("status") == 200 for r in results["https"])
    if ok_http or ok_https:
        print("[+] Queen proxy verification passed")
        return 0
    print("[!] Queen proxy verification failed")
    return 1


if __name__ == "__main__":
    sys.exit(main())
