#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Fetch Queen proxy endpoints via the *old WUP* route used by QQ Browser.

This is the path called by QueenInfoProviderImpl.updateIPList():
    WUP serverName = "proxyip"
    WUP funcName   = "getIPListByRouter"
    request body   = MTT.RouteIPListReq

Compared with PBProxy GetIPListByRouter, this route is what the app actually
uses for queen_http/queen_https refresh, and it accepts the full set of
network matching fields (APN / subtype / extra info / MCCMNC / card type).

Typical usage:
    python fetch_queen_proxy_oldwup.py \
        --phone 13075020119 \
        --mccmnc 46001 --apn 3gnet \
        --type-name MOBILE --subtype 0 --extra-info uninet --card-type 1

The script fetches a GUID if needed, builds the encrypted old-WUP request,
sends it to qbwup.qq.com:8080, decrypts/parses RouteIPListRsp and saves
queen_http / queen_https to JSON.
"""
import argparse
import gzip
import json
import os
import struct
import sys
import time
from pathlib import Path

try:
    import requests
except ImportError as exc:
    raise SystemExit("Missing dependency. Run: pip install requests pycryptodome") from exc

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE))
import fetch_q_token as fqt  # noqa: E402

DEFAULT_SERVER = "http://qbwup.qq.com:8080/"
OUTPUT_JSON = "queen_proxy_oldwup_result.json"


# ---------------------------------------------------------------------------
# JCE builders (MTT.UserBase / MTT.RouteIPListReq)
# ---------------------------------------------------------------------------
def jh(t, tag):
    return fqt.jce_head(t, tag)


def js(v, tag):
    return fqt.jce_str(v, tag)


def ji(v, tag):
    return fqt.jce_int(v, tag)


def jb(v, tag):
    return fqt.jce_bytes(v, tag)


def jbool(v, tag):
    return jh(12, tag) if not v else jh(0, tag) + b"\x01"


def jshort(v, tag):
    return jh(1, tag) + v.to_bytes(2, "big", signed=True)


def jlist_ints(vals, tag):
    return jh(9, tag) + ji(len(vals), 0) + b"".join(ji(v, 0) for v in vals)


def jlist_strs(vals, tag):
    return jh(9, tag) + ji(len(vals), 0) + b"".join(js(v, 0) for v in vals)


def jstruct(tag, fields):
    return jh(10, tag) + fields + jh(11, 0)


def build_user_base(guid: str, qua2: str, apn: str) -> bytes:
    """Approximates IConfigService.buildUserBase(3) + sAPN assignment."""
    fields = b"".join([
        js("", 0),                         # sIMEI
        jb(bytes.fromhex(guid), 1),        # sGUID
        js(qua2, 2),                       # sQUA (QUA2 used as approximation)
        js("", 3),                         # sLC
        js("", 4),                         # sCellphone
        js("", 5),                         # sUin
        js("", 6),                         # sCellid
        ji(2, 7),                          # iServerVer
        jbool(True, 8),                    # bSave
        js("", 9),                         # sChannel
        js("", 10),                        # sLAC
        js("", 11),                        # sUA
        ji(200, 12),                       # iLanguageType
        jshort(0, 13),                     # iMCC
        jshort(0, 14),                     # iMNC
        js(apn, 15),                       # sAPN
        js("", 16),                        # sCellNumber
        jb(b"\x00", 17),                   # sMac
        jh(9, 19) + ji(0, 0),              # vWifiMacs (empty)
        jb(b"\x00", 20),                   # vLBSKeyData
        js("", 21),                        # sVenderId
        js("", 22),                        # sAdId
        js("", 23),                        # sFirstChannel
    ])
    return jstruct(0, fields)


def build_route_ip_list_req(guid, qua2, apn, type_name, subtype, extra_info,
                            mccmnc, card_type, iptypes=(15, 16)):
    fields = b"".join([
        build_user_base(guid, qua2, apn),
        jlist_ints(list(iptypes), 1),
        js(type_name, 2),
        ji(subtype, 3),
        js(extra_info, 4),
        js(mccmnc, 5),
        ji(card_type, 6),
        jlist_strs([mccmnc], 7),
    ])
    return jstruct(0, fields)


# ---------------------------------------------------------------------------
# Generic JCE reader (supports nested struct/list/map)
# ---------------------------------------------------------------------------
def read_head(data, i):
    b0 = data[i]
    i += 1
    typ = b0 & 0x0F
    tag = (b0 >> 4) & 0x0F
    if tag == 15:
        tag = data[i]
        i += 1
    return typ, tag, i


def read_any(data, i):
    typ, tag, i = read_head(data, i)

    if typ == 12:                     # zero
        return tag, 0, i
    if typ == 0:                      # byte
        return tag, int.from_bytes(data[i:i + 1], "big", signed=True), i + 1
    if typ == 1:                      # short
        return tag, int.from_bytes(data[i:i + 2], "big", signed=True), i + 2
    if typ == 2:                      # int
        return tag, int.from_bytes(data[i:i + 4], "big", signed=True), i + 4
    if typ == 3:                      # long
        return tag, int.from_bytes(data[i:i + 8], "big", signed=True), i + 8
    if typ == 6:                      # string1
        n = data[i]
        i += 1
        return tag, data[i:i + n].decode("utf-8", "replace"), i + n
    if typ == 7:                      # string4
        n = int.from_bytes(data[i:i + 4], "big")
        i += 4
        return tag, data[i:i + n].decode("utf-8", "replace"), i + n
    if typ == 8:                      # map
        _, size, i = read_any(data, i)
        out = {}
        for _ in range(size):
            _, k, i = read_any(data, i)
            _, v, i = read_any(data, i)
            out[k] = v
        return tag, out, i
    if typ == 9:                      # list
        _, size, i = read_any(data, i)
        out = []
        for _ in range(size):
            _, v, i = read_any(data, i)
            out.append(v)
        return tag, out, i
    if typ == 13:                     # bytes
        _, _, i = read_head(data, i)  # skip dummy writeHead(0,0)
        _, n, i = read_any(data, i)
        return tag, data[i:i + n], i + n
    if typ == 10:                     # struct
        fields = {}
        while True:
            t2, tag2, i2 = read_head(data, i)
            if t2 == 11:              # struct end
                return tag, fields, i2
            _, value, i2 = read_any(data, i)
            fields[tag2] = value
            i = i2
    raise ValueError(f"Unsupported JCE type {typ} at offset {i}")


# ---------------------------------------------------------------------------
# Old-WUP encrypted request / response parsing
# ---------------------------------------------------------------------------
def build_oldwup_envelope(guid, qua2, route_bytes, mode):
    req_id = 0
    body0 = fqt.build_wup_request("proxyip", "getIPListByRouter",
                                  "req", "MTT.RouteIPListReq", route_bytes, req_id)
    body_to_encrypt = gzip.compress(body0, 9)

    aes_key = os.urandom(16)
    iv_hex = os.urandom(8).hex() if mode == 2 else None
    enc_body = fqt.aes_encrypt(body_to_encrypt, aes_key, iv_hex)
    rsa_key = fqt.rsa_encrypt_key(aes_key, mode)

    query = [
        f"encrypt={'17' if mode == 2 else '12'}",
        "qbkey=" + rsa_key.hex(),
        "len=1024",
        "id=" + fqt.KEY_ID.hex(),
        "v=3",
    ]
    if mode == 2:
        query.append("iv=" + iv_hex)

    headers = {
        "Content-Type": "application/multipart-formdata",
        "User-Agent": "MQQBrowser",
        "Accept": "*/*",
        "Accept-Encoding": "identity",
        "Connection": "Close",
        "Q-GUID": fqt.aes_encrypt(bytes.fromhex(guid), aes_key, iv_hex).hex().upper(),
        "Q-UA2": qua2,
        "Common-Header": fqt.build_common_header(guid),
        "QQ-S-ZIP": "gzip",
        "Traceid": str(int(time.time() * 1000)),
    }
    return body0, enc_body, "&".join(query), headers, aes_key, iv_hex


def send_oldwup(server, guid, qua2, route_bytes, mode, timeout):
    body0, enc_body, query, headers, aes_key, iv_hex = build_oldwup_envelope(
        guid, qua2, route_bytes, mode)
    resp = requests.post(server.rstrip("/") + "/?" + query,
                         data=enc_body, headers=headers, timeout=timeout)
    data = resp.content
    plain = None
    enc_flag = resp.headers.get("QQ-S-Encrypt", "").strip().lower()
    if enc_flag in ("12", "17") or (resp.status_code == 200 and len(data) > 16):
        try:
            plain = fqt.aes_decrypt(data, aes_key, iv_hex if mode == 2 else None)
        except Exception:
            plain = None
    if resp.headers.get("QQ-S-ZIP", "").strip().lower() == "gzip":
        source = plain if plain is not None else data
        try:
            plain = gzip.decompress(source)
        except Exception:
            pass
    return resp, plain


def read_fields(data, i):
    """Read a top-level JCE field sequence (no STRUCT_BEGIN/END wrapper)."""
    fields = {}
    while i < len(data):
        tag, value, i = read_any(data, i)
        fields[tag] = value
    return fields


def parse_route_ip_list_rsp(plain):
    if len(plain) < 4:
        raise ValueError("response too short")
    total = struct.unpack(">I", plain[:4])[0]
    if total != len(plain):
        raise ValueError(f"WUP length mismatch: header {total}, actual {len(plain)}")

    packet = read_fields(plain[4:], 0)
    sbuf = packet.get(7)
    if not isinstance(sbuf, (bytes, bytearray)) or not sbuf:
        raise ValueError("WUP response has no sBuffer")

    _, outer, _ = read_any(bytes(sbuf), 0)
    if not isinstance(outer, dict) or "rsp" not in outer:
        raise ValueError(f"WUP response map does not contain 'rsp': {outer!r}")

    rsp_map = outer["rsp"]
    if not isinstance(rsp_map, dict) or "MTT.RouteIPListRsp" not in rsp_map:
        raise ValueError(f"WUP response map does not contain 'MTT.RouteIPListRsp': {rsp_map!r}")

    raw = rsp_map["MTT.RouteIPListRsp"]
    _, fields, _ = read_any(raw, 0)
    if not isinstance(fields, dict):
        fields = read_fields(raw, 0)

    infos = []
    for v in fields.get(0, []) if isinstance(fields.get(0), list) else []:
        if isinstance(v, dict):
            infos.append({
                "eIPType": v.get(0),
                "vIPList": v.get(1) or [],
                "iTotalPollNum": v.get(2),
                "iLifePeriod": v.get(3),
            })

    queen_http, queen_https = [], []
    for info in infos:
        iptype = info.get("eIPType")
        servers = list(info.get("vIPList") or [])
        if iptype == 15:
            queen_http.extend(servers)
        elif iptype == 16:
            queen_https.extend(servers)

    return {
        "sApn": fields.get(1),
        "bProxy": fields.get(2),
        "sTypeName": fields.get(3),
        "iSubType": fields.get(4),
        "sExtraInfo": fields.get(5),
        "sMCCMNC": fields.get(6),
        "vIPInfos": infos,
        "queen_http": queen_http,
        "queen_https": queen_https,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Fetch Queen proxy endpoints via old WUP proxyip/getIPListByRouter")
    parser.add_argument("--guid", default=None, help="32-hex Q-GUID; if omitted, fetch via PBProxy GetGuid")
    parser.add_argument("--qua2", default=None, help="Q-UA2 string; if omitted, auto-generate")
    parser.add_argument("--apn", default="UNKNOW", help="UserBase.sAPN, e.g. 3gnet / uninet / wonet")
    parser.add_argument("--type-name", default="UNKNOW", help="RouteIPListReq.sTypeName, e.g. MOBILE")
    parser.add_argument("--subtype", type=int, default=0, help="RouteIPListReq.iSubType: 0=mobile,1=wifi,-1=unknown")
    parser.add_argument("--extra-info", default="UNKNOW", help="RouteIPListReq.sExtraInfo, e.g. uninet / 3gwap")
    parser.add_argument("--mccmnc", default="NULLNULL", help="RouteIPListReq.sMCCMNC, e.g. 46001")
    parser.add_argument("--card-type", type=int, default=1, help="RouteIPListReq.iCardType: 1=Queen enabled, 0=not")
    parser.add_argument("--server", default=DEFAULT_SERVER, help="old WUP endpoint")
    parser.add_argument("--mode", type=int, choices=(1, 2), default=0, help="encrypt mode; default tries both")
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--output", default=OUTPUT_JSON, help="result JSON path")
    args = parser.parse_args()

    qua2 = args.qua2 or fqt.generate_qua2()
    print(f"[*] Q-UA2: {qua2}")

    if args.guid:
        guid = args.guid.replace("-", "")
        if len(guid) != 32:
            raise SystemExit("--guid must be 32 hex characters")
        try:
            bytes.fromhex(guid)
        except ValueError as exc:
            raise SystemExit("--guid must be hex") from exc
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

    route_bytes = build_route_ip_list_req(
        guid, qua2,
        apn=args.apn,
        type_name=args.type_name,
        subtype=args.subtype,
        extra_info=args.extra_info,
        mccmnc=args.mccmnc,
        card_type=args.card_type,
        iptypes=(15, 16),
    )
    print(f"[*] RouteIPListReq bytes: {len(route_bytes)}")

    modes = [args.mode] if args.mode else (1, 2)
    last_error = None
    for mode in modes:
        try:
            print(f"[*] trying encrypt mode {mode} -> {args.server}")
            resp, plain = send_oldwup(args.server, guid, qua2, route_bytes, mode, args.timeout)
            print(f"[*] HTTP {resp.status_code}, plain_len={len(plain) if plain else 0}")
            if resp.status_code != 200 or plain is None:
                last_error = f"HTTP {resp.status_code}, plain_len={len(plain) if plain else 0}"
                continue
            rsp = parse_route_ip_list_rsp(plain)
            result = {
                "guid": guid,
                "qua2": qua2,
                "request": {
                    "sTypeName": args.type_name,
                    "iSubType": args.subtype,
                    "sExtraInfo": args.extra_info,
                    "sMCCMNC": args.mccmnc,
                    "iCardType": args.card_type,
                    "sAPN": args.apn,
                },
                "response": rsp,
                "mode": mode,
                "server": args.server,
            }
            Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2),
                                         encoding="utf-8")
            print(json.dumps(result, ensure_ascii=False, indent=2))
            print(f"[*] saved to {args.output}")
            print(f"[*] queen_http  : {rsp['queen_http']}")
            print(f"[*] queen_https : {rsp['queen_https']}")
            return 0
        except Exception as exc:
            last_error = repr(exc)
            print(f"[!] mode {mode} failed: {exc!r}", file=sys.stderr)

    print(f"[!] old WUP proxyip request failed. last error: {last_error}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
