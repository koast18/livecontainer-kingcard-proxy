#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fetch Queen proxy IPs and old-WUP server IPs from Tencent PBProxy.

This is the real live method used by QQ Browser:
  https://pbprx.qq.com/  -> trpc.mtt.ipinfo.Ipinfo/GetIPListByRouter
"""
import json
import random
import struct
import sys
from pathlib import Path

import requests

URL = "https://pbprx.qq.com/"
SERVANT = "trpc.mtt.ipinfo.Ipinfo"
FUNC = "/trpc.mtt.ipinfo.Ipinfo/GetIPListByRouter"
# 1=WUPPROXY(old WUP HTTP), 15=HTTPDOWN(queen_http), 16=HTTPSTUNNEL(queen_https), 25=WUPPROXYNEW
IP_TYPES = [1, 15, 16, 25]


def pv(v):
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def pt(f, w):
    return pv((f << 3) | w)


def pl(f, p):
    return pt(f, 2) + pv(len(p)) + p


def ps(f, s):
    return pl(f, s.encode())


def pv2(f, v):
    return pt(f, 0) + pv(v)


def rv(data, i):
    val = 0
    shift = 0
    while True:
        b = data[i]; i += 1
        val |= (b & 0x7F) << shift
        if not (b & 0x80):
            return val, i
        shift += 7


def fields(data):
    out = {}
    i = 0
    while i < len(data):
        k, i = rv(data, i)
        f, w = k >> 3, k & 7
        if w == 0:
            v, i = rv(data, i)
            out.setdefault(f, []).append(("v", v))
        elif w == 2:
            ln, i = rv(data, i)
            out.setdefault(f, []).append(("b", data[i:i + ln]))
            i += ln
    return out


def gb(fs, f):
    for w, v in fs.get(f, []):
        if w == "b":
            return v
    return None


def gv(fs, f):
    for w, v in fs.get(f, []):
        if w == "v":
            return v
    return None


def build_request(guid, qua2, card_type=1):
    user = ps(1, guid) + ps(3, qua2)
    net = (ps(1, "UNKNOW") + pv2(2, 0) + ps(3, "UNKNOW")
           + ps(4, "NULLNULL") + pv2(5, card_type))
    return pl(2, user) + pl(4, b"".join(pv(t) for t in IP_TYPES)) + pl(5, net)


def main():
    guid = sys.argv[1] if len(sys.argv) > 1 else "00112233445566778899aabbccddeeff"
    qua2 = sys.argv[2] if len(sys.argv) > 2 else "QB9.4.0.123"

    inner = build_request(guid, qua2)
    msg = (pv2(1, random.randint(1, 100000)) + ps(2, SERVANT)
           + ps(3, FUNC) + pl(4, inner))
    body = struct.pack(">I", len(msg) + 4) + msg

    headers = {
        "Host": "pbprx.qq.com",
        "Content-Type": "application/multipart-formdata",
        "User-Agent": "MQQBrowser",
        "Accept": "*/*",
        "PB": "1",
        "Q-GUID": guid,
        "Q-UA2": qua2,
        "Traceid": str(random.randint(10**15, 10**16)),
    }

    print(f"[*] POST {URL} requesting types {IP_TYPES}")
    resp = requests.post(URL, data=body, headers=headers, timeout=15, verify=False)
    if resp.status_code != 200:
        print("[!] HTTP", resp.status_code, resp.content[:300])
        return 2

    raw = resp.content
    total = struct.unpack(">I", raw[:4])[0]
    pb = raw[4:4 + total]
    fs = fields(pb)
    inner_rsp = gb(fs, 4)
    ifs = fields(inner_rsp)

    queen_http, queen_https, old_wup, old_wup_new = [], [], [], []
    all_infos = []
    for _, val in ifs.get(2, []):
        jf = fields(val)
        ipt = gv(jf, 1)
        servers = []
        for _, s in jf.get(2, []):
            servers.append(s.decode())
        all_infos.append({"iptype": ipt, "servers": servers})
        if ipt == 15:
            queen_http.extend(servers)
        elif ipt == 16:
            queen_https.extend(servers)
        elif ipt == 1:
            old_wup.extend(servers)
        elif ipt == 25:
            old_wup_new.extend(servers)

    result = {
        "queen_http": queen_http,
        "queen_https": queen_https,
        "old_wup_http": old_wup,
        "old_wup_http_new": old_wup_new,
        "all": all_infos,
    }
    Path("proxy_and_wup_servers.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")

    print(json.dumps(result, ensure_ascii=False, indent=2))
    print("[*] saved proxy_and_wup_servers.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
