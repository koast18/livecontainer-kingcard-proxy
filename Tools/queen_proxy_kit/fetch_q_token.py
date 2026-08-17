#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Reverse-engineered QQ Browser WUP TokenInfoReq client.

Sends the old-WUP JCE request:
    servant = httpWupToken
    func    = getTokenInfo
    request = MTT.TokenInfoReq { sGuid, sQua2, sPhoneNum }

and parses the decrypted TokenInfoRsp to print:
    Q-Token (sToken), Q-Key (sKey), expire time (seconds), rspCode.
"""
import argparse
import base64
import gzip
import json
import os
import random
import re
import struct
import sys
import time
from pathlib import Path

try:
    import requests
    import urllib3
    from Crypto.Cipher import AES, DES3, PKCS1_OAEP
    from Crypto.PublicKey import RSA
    from Crypto.Util.Padding import pad, unpad
except ImportError as exc:
    raise SystemExit(
        "Missing dependency. Run: pip install requests pycryptodome"
    ) from exc

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ---------------------------------------------------------------------------
# Constants recovered from the APK / decompiled Java
# ---------------------------------------------------------------------------
PUB_B64 = (
    "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCzazICPQD9Tuky2L9Nl88S6WI2QQAUirJ"
    "znzLq923Q5mV6DHJTLYgG4hx44+0ViPgwMHzHiMn4sfK5+ZdsukjPXEG0Wm+YHqCK0IECHE"
    "7dN3TXhyBspm4YlZBJUCKbMBlO0jYPywUSPmQQ9nazll0/o1JOephdDs1ixszWS92WnQIDA"
    "QAB"
)
KEY_ID = bytes(
    b & 0xFF
    for b in (-90, -112, -43, -11, 75, 67, -54, 83, 90, -14, 102, -61, 24, 7, 105, -57)
)
COMM_KEY = b"mvLBiZsiTbGwrfJB"

DEFAULT_URLS = [
    "http://qbwup.qq.com:8080/",
    "http://wup.imtt.qq.com:8080/",
    "http://iwup.mtt.qq.com/",
    "http://xg-qbwup.qq.com/",
]

PB_PROXY_URL = "https://pbprx.qq.com/"
GUID_SERVANT = "trpc.mtt.guid.guid"
GUID_FUNC = "/trpc.mtt.guid.guid/GetGuid"

SERVANT = "httpWupToken"
FUNC = "getTokenInfo"
REQ_KEY = "req"    # HiAnalyticsConstant.Direction.REQUEST
REQ_TYPE = "MTT.TokenInfoReq"
RSP_KEY = "rsp"    # HiAnalyticsConstant.Direction.RESPONSE
RSP_TYPE = "MTT.TokenInfoRsp"


# ---------------------------------------------------------------------------
# Protobuf primitives (for Common-Header)
# ---------------------------------------------------------------------------
def pb_varint(value: int) -> bytes:
    if value < 0:
        value &= (1 << 64) - 1
    out = bytearray()
    while True:
        b = value & 0x7F
        value >>= 7
        if value:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def pb_tag(field: int, wire: int) -> bytes:
    return pb_varint((field << 3) | wire)


def pb_len(field: int, payload: bytes) -> bytes:
    return pb_tag(field, 2) + pb_varint(len(payload)) + payload


def pb_var(field: int, value: int) -> bytes:
    return pb_tag(field, 0) + pb_varint(value)


def pb_common_header(guid: str, qimei: str = "", qimei36: str = "") -> bytes:
    data = pb_len(1, guid.encode())
    if qimei:
        data += pb_len(2, qimei.encode())
    if qimei36:
        data += pb_len(3, qimei36.encode())
    return data


def build_common_header(guid: str, qimei: str = "", qimei36: str = "") -> str:
    plain = pb_common_header(guid, qimei, qimei36)
    encrypted = AES.new(COMM_KEY, AES.MODE_CBC, iv=COMM_KEY).encrypt(pad(plain, 16))
    # CommHeaderOuterClass.EncryptMsg:
    #   field 1 encrypt_type = E_ENCRYPT_AES_CBC_PKCS7_128 = 2
    #   field 2 msg_type     = MSG_COMM_HEADER = 1
    #   field 3 msg          = encrypted comm header
    msg = pb_var(1, 2) + pb_var(2, 1) + pb_len(3, encrypted)
    return msg.hex().upper()


# ---------------------------------------------------------------------------
# JCE (Taf) primitives
# ---------------------------------------------------------------------------
def jce_head(type_byte: int, tag: int) -> bytes:
    # Java JceOutputStream.writeHead(byte type, int tag):
    #     tag < 15   -> put((byte)(type | (tag << 4)));
    #     tag < 256  -> put((byte)(type | 0xF0)); put((byte) tag);
    # so TAG is the high nibble and TYPE is the low nibble.
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


def jce_int(value: int, tag: int) -> bytes:
    if -32768 <= value <= 32767:
        if -128 <= value <= 127:
            if value == 0:
                return jce_head(12, tag)
            return jce_head(0, tag) + bytes([value & 0xFF])
        return jce_head(1, tag) + value.to_bytes(2, "big", signed=True)
    return jce_head(2, tag) + value.to_bytes(4, "big", signed=True)


def jce_bytes(data: bytes, tag: int) -> bytes:
    # Java: writeHead(13,tag), writeHead(0,0), write(len,0), bytes
    return jce_head(13, tag) + jce_head(0, 0) + jce_int(len(data), 0) + data


def jce_map(mapping: dict, tag: int) -> bytes:
    out = jce_head(8, tag) + jce_int(len(mapping), 0)
    for key, value in mapping.items():
        out += jce_str(key, 0)
        if isinstance(value, dict):
            out += jce_map(value, 1)
        elif isinstance(value, bytes):
            out += jce_bytes(value, 1)
        else:
            out += jce_str(value, 1)
    return out


def token_info_req(guid: str, qua2: str, phone: str) -> bytes:
    # Java OldUniAttribute.objectToByte(TokenInfoReq) calls
    # JceOutputStream.write(jceStruct, 0): struct header type 10, tag 0,
    # then the fields, then struct-end type 11, tag 0.
    return (
        jce_head(10, 0)
        + jce_str(guid, 0)
        + jce_str(qua2, 1)
        + jce_str(phone, 2)
        + jce_head(11, 0)
    )


def build_wup_request(
    servant: str,
    func: str,
    param_key: str,
    param_type: str,
    param_bytes: bytes,
    req_id: int,
) -> bytes:
    inner = jce_map({param_key: {param_type: param_bytes}}, 0)
    packet = (
        jce_int(2, 1)       # iVersion
        + jce_int(0, 2)     # cPacketType
        + jce_int(0, 3)     # iMessageType
        + jce_int(req_id, 4)
        + jce_str(servant, 5)
        + jce_str(func, 6)
        + jce_bytes(inner, 7)
        + jce_int(0, 8)     # iTimeout
        + jce_map({}, 9)    # context
        + jce_map({}, 10)   # status
    )
    return struct.pack(">I", len(packet) + 4) + packet


# ---------------------------------------------------------------------------
# JCE parser (only needed for the response)
# ---------------------------------------------------------------------------
def jce_read_head(data: bytes, i: int):
    b0 = data[i]
    i += 1
    typ = b0 & 0x0F          # low nibble = JCE type
    tag = (b0 >> 4) & 0x0F   # high nibble = JCE tag
    if tag == 15:
        tag = data[i]
        i += 1
    return typ, tag, i


def jce_read(data: bytes, i: int):
    typ, tag, i = jce_read_head(data, i)

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
    if typ in (6, 7):                 # string
        if typ == 6:
            n = data[i]
            i += 1
        else:
            n = int.from_bytes(data[i:i + 4], "big")
            i += 4
        return tag, data[i:i + n].decode("utf-8", "replace"), i + n
    if typ == 13:                     # byte[]
        # skip the dummy writeHead(0,0) byte
        _, _, i = jce_read_head(data, i)
        _, n, i = jce_read(data, i)
        return tag, data[i:i + n], i + n
    if typ == 8:                      # map
        _, size, i = jce_read(data, i)
        result = {}
        for _ in range(size):
            _, key, i = jce_read(data, i)
            _, value, i = jce_read(data, i)
            result[key] = value
        return tag, result, i
    if typ == 9:                      # list/array
        _, size, i = jce_read(data, i)
        result = []
        for _ in range(size):
            _, value, i = jce_read(data, i)
            result.append(value)
        return tag, result, i

    raise ValueError(f"Unsupported JCE type {typ} at offset {i}")


def parse_jce_struct(data: bytes) -> dict:
    fields = {}
    i = 0
    while i < len(data):
        tag, value, i = jce_read(data, i)
        fields[tag] = value
    return fields


def unwrap_jce_struct(data: bytes) -> bytes:
    """JCE struct values are stored as type-10 struct + fields + type-11 end."""
    if len(data) >= 2 and (data[0] & 0x0F) == 10 and (data[-1] & 0x0F) == 11:
        return data[1:-1]
    return data


def parse_wup_response(plain: bytes) -> dict:
    if len(plain) < 4:
        raise ValueError("WUP response too short")
    total = struct.unpack(">I", plain[:4])[0]
    if total != len(plain):
        raise ValueError(f"WUP length mismatch: header {total}, actual {len(plain)}")
    packet = parse_jce_struct(plain[4:])
    s_buffer = packet.get(7)
    if not isinstance(s_buffer, bytes) or not s_buffer:
        raise ValueError("WUP response has no sBuffer")
    _, outer, _ = jce_read(s_buffer, 0)
    if not isinstance(outer, dict) or RSP_KEY not in outer:
        raise ValueError(f"WUP response map does not contain '{RSP_KEY}'")
    type_map = outer[RSP_KEY]
    if not isinstance(type_map, dict) or RSP_TYPE not in type_map:
        raise ValueError(f"WUP response map does not contain '{RSP_TYPE}'")
    rsp_bytes = type_map[RSP_TYPE]
    return parse_jce_struct(unwrap_jce_struct(rsp_bytes))


# ---------------------------------------------------------------------------
# AES / RSA envelope
# ---------------------------------------------------------------------------
def rsa_encrypt_key(aes_key: bytes, mode: int) -> bytes:
    pub = RSA.import_key(base64.b64decode(PUB_B64))
    if mode == 2:
        return PKCS1_OAEP.new(pub).encrypt(aes_key)
    # mode 1: RSA/ECB/NoPadding
    size = pub.size_in_bytes()
    if len(aes_key) < size:
        aes_key = b"\x00" * (size - len(aes_key)) + aes_key
    m = int.from_bytes(aes_key, "big")
    c = pow(m, pub.e, pub.n)
    return c.to_bytes(size, "big")


def aes_encrypt(data: bytes, key: bytes, iv_hex: str = None) -> bytes:
    if iv_hex:
        iv = iv_hex.encode()
        return AES.new(key, AES.MODE_CBC, iv=iv).encrypt(pad(data, 16))
    return AES.new(key, AES.MODE_ECB).encrypt(pad(data, 16))


def aes_decrypt(data: bytes, key: bytes, iv_hex: str = None) -> bytes:
    if iv_hex:
        iv = iv_hex.encode()
        return unpad(AES.new(key, AES.MODE_CBC, iv=iv).decrypt(data), 16)
    return unpad(AES.new(key, AES.MODE_ECB).decrypt(data), 16)


# ---------------------------------------------------------------------------
# Request / response orchestration
# ---------------------------------------------------------------------------
def build_request_envelope(guid, qua2, phone, mode, qimei="", qimei36="", gzip_body=True):
    req_id = 0  # WUPTaskClient.b() starts from 0; keep the old-WUP request id small
    body0 = build_wup_request(
        SERVANT, FUNC, REQ_KEY, REQ_TYPE,
        token_info_req(guid, qua2, phone), req_id,
    )

    # The real app gzips the old-WUP HTTP body before AES encryption and
    # announces it with "QQ-S-ZIP: gzip".
    if gzip_body:
        body_to_encrypt = gzip.compress(body0, 9)
        req_zip = "gzip"
    else:
        body_to_encrypt = body0
        req_zip = None

    aes_key = os.urandom(16)
    iv_hex = os.urandom(8).hex() if mode == 2 else None

    enc_body = aes_encrypt(body_to_encrypt, aes_key, iv_hex)
    enc_guid = aes_encrypt(bytes.fromhex(guid), aes_key, iv_hex)
    rsa_key = rsa_encrypt_key(aes_key, mode)

    query = [
        f"encrypt={'17' if mode == 2 else '12'}",
        "qbkey=" + rsa_key.hex(),
        "len=1024",
        "id=" + KEY_ID.hex(),
        "v=3",
    ]
    if mode == 2:
        query.append("iv=" + iv_hex)
    query_string = "&".join(query)

    headers = {
        "Content-Type": "application/multipart-formdata",
        "User-Agent": "MQQBrowser",
        "Accept": "*/*",
        "Accept-Encoding": "identity",
        "Connection": "Close",
        "Q-GUID": enc_guid.hex().upper(),
        "Q-UA2": qua2,
        "Common-Header": build_common_header(guid, qimei, qimei36),
        "Traceid": str(int(time.time() * 1000)),
    }
    if req_zip:
        headers["QQ-S-ZIP"] = req_zip
    if qimei:
        headers["Q-QIMEI"] = qimei
    if qimei36:
        headers["QIMEI36"] = qimei36

    return body0, body_to_encrypt, enc_body, query_string, headers, aes_key, iv_hex


def make_proxies(template: str = None):
    """Build a requests proxies dict; {account} is replaced with a random egress account."""
    if not template:
        return None
    account = "a" + str(random.randint(10**8, 10**9 - 1))
    url = template.replace("{account}", account).replace("<account>", account)
    return {"http": url, "https": url}


def try_one_endpoint(url, enc_body, query_string, headers, aes_key, iv_hex, mode, timeout,
                     proxy_template=None):
    full_url = url
    if not full_url.endswith("/"):
        full_url += "/"
    full_url += "?" + query_string
    resp = requests.post(full_url, data=enc_body, headers=headers, timeout=timeout,
                         proxies=make_proxies(proxy_template))
    data = resp.content

    # The body is AES encrypted when QQ-S-Encrypt is 12/17.
    enc_flag = resp.headers.get("QQ-S-Encrypt", "").strip().lower()
    plain = None
    if enc_flag in ("12", "17") or (resp.status_code == 200 and len(data) > 16):
        try:
            plain = aes_decrypt(data, aes_key, iv_hex if mode == 2 else None)
        except Exception:
            plain = None

    # In the app, gzip decompression happens after AES decryption.
    if resp.headers.get("QQ-S-ZIP", "").strip().lower() == "gzip":
        source = plain if plain is not None else data
        try:
            plain = gzip.decompress(source)
        except Exception:
            pass

    return resp, data, plain


def load_server_urls() -> list:
    urls = list(DEFAULT_URLS)
    # If a previous proxy/wup server dump exists, add its old-WUP IPs too.
    for path in ("proxy_and_wup_servers.json", "queen_proxy_result.json"):
        p = Path(path)
        if not p.exists():
            continue
        try:
            obj = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        for key in ("old_wup_http", "old_wup_http_new"):
            for item in obj.get(key, []):
                if isinstance(item, str) and ":" in item:
                    urls.append("http://" + item + "/")
    # de-duplicate preserving order
    seen = set()
    out = []
    for u in urls:
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out


# ---------------------------------------------------------------------------
# Local generation of GUID / QUA2 based on decompiled code
# ---------------------------------------------------------------------------
# g.D: 24-byte 3DES key used to derive GUID validation.
GUID_3DES_KEY = bytes([
    99, 215, 144, 99, 60, 14, 47, 195,
    70, 239, 133, 55, 66, 31, 157, 74,
    70, 61, 88, 243, 138, 149, 236, 132,
])


def generate_guid_hex() -> str:
    """Generate a locally-valid GUID/validation pair.

    The app validates GUID via:
        guid == DESede_decrypt(D, validation)
    so choosing a random guid and computing validation = DESede_encrypt(D, guid)
    produces a self-consistent GUID. TokenInfoReq only needs the 16-byte GUID.
    """
    guid = os.urandom(16)
    while all(b == 0 for b in guid):
        guid = os.urandom(16)
    # Not sent in TokenInfoReq, but keep the pair valid if needed elsewhere.
    DES3.new(GUID_3DES_KEY, DES3.MODE_ECB).encrypt(guid)
    return guid.hex().upper()


def generate_qua2(model: str = "", width: int = 1080, height: int = 1920,
                  os_release: str = "10", api: int = 33) -> str:
    """Rebuild the QUA2_V3 string from qbinfo/f.java + qb.info.BuildConfig."""
    clean_model = re.sub(r"[ /_&|\\]", "", model)
    mo = " " + clean_model + " "
    parts = [
        "QV=3",
        "PL=ADR",
        "PR=QB",
        "PP=com.tencent.mtt",
        "PPVN=19.9.0.0047",
        # qbinfo/f.java: if COVC is empty -> CO=SYS; d.o (COVC) defaults to ""
        # so without a real TBS-core-version bundle value, CO is SYS.
        "CO=SYS",
        "PB=GE",
        "VE=GA",
        "DE=PHONE",
        "CHID=0",
        "LCID=25681",
        "MO=" + mo,
        f"RL={width}*{height}",
        "OS=" + os_release,
        "API=" + str(api),
        "DS=64",
        "RT=64",
        "REF=qb_0",
        "TM=01",
    ]
    return "&".join(parts)


# ---------------------------------------------------------------------------
# Fetch a real server-issued GUID through PBProxy GetGuid
# ---------------------------------------------------------------------------
def read_pb_varint(data: bytes, i: int):
    val = 0
    shift = 0
    while True:
        b = data[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not (b & 0x80):
            return val, i
        shift += 7


def parse_pb_fields(data: bytes) -> dict:
    fields = {}
    i = 0
    while i < len(data):
        key, i = read_pb_varint(data, i)
        field, wire = key >> 3, key & 7
        if wire == 0:
            val, i = read_pb_varint(data, i)
            fields.setdefault(field, []).append(("varint", val))
        elif wire == 2:
            ln, i = read_pb_varint(data, i)
            val = data[i:i + ln]
            i += ln
            fields.setdefault(field, []).append(("bytes", val))
        else:
            raise ValueError(f"unsupported protobuf wire type {wire}")
    return fields


def get_pb_bytes(fields: dict, field: int) -> bytes:
    for wire, val in fields.get(field, []):
        if wire == "bytes":
            return val
    return b""


def get_pb_varint(fields: dict, field: int):
    for wire, val in fields.get(field, []):
        if wire == "varint":
            return val
    return None


def build_get_guid_request(qua2: str) -> bytes:
    # GetGuidReq:
    #   1 qimei36
    #   2 qua2
    #   3 DeviceInfo { 1 ad_id, 2 vender_id, 3 qimei36_token }
    #   4 UserStat { 1 triger_type, 2 user_status }
    #   5 validation
    device_info = pb_len(1, b"") + pb_len(2, b"") + pb_len(3, b"")
    user_stat = pb_var(1, 3) + pb_var(2, 1)
    req = (
        pb_len(1, b"")
        + pb_len(2, qua2.encode())
        + pb_len(3, device_info)
        + pb_len(4, user_stat)
        + pb_len(5, b"")
    )
    # Pbproxy.PbRequest:
    #   1 request_id, 2 servant_name, 3 func_name, 4 buffer
    msg = (
        pb_var(1, random.randint(1, 100000))
        + pb_len(2, GUID_SERVANT.encode())
        + pb_len(3, GUID_FUNC.encode())
        + pb_len(4, req)
    )
    return struct.pack(">I", len(msg) + 4) + msg


def fetch_guid_from_server(qua2: str, timeout: float = 15.0, proxy_template: str = None) -> str:
    body = build_get_guid_request(qua2)
    headers = {
        "Host": "pbprx.qq.com",
        "Content-Type": "application/multipart-formdata",
        "User-Agent": "MQQBrowser",
        "Accept": "*/*",
        "Connection": "Close",
        "PB": "1",
        "Q-GUID": "00000000000000000000000000000000",
        "Q-UA2": qua2,
        "Traceid": str(int(time.time() * 1000)),
    }
    resp = requests.post(PB_PROXY_URL, data=body, headers=headers,
                         timeout=timeout, verify=False,
                         proxies=make_proxies(proxy_template))
    if resp.status_code != 200:
        raise RuntimeError(f"GetGuid HTTP {resp.status_code}: {resp.content[:200]!r}")
    raw = resp.content  # requests already decodes Content-Encoding: gzip
    if len(raw) < 4:
        raise RuntimeError("GetGuid response too short")
    total = struct.unpack(">I", raw[:4])[0]
    pb = parse_pb_fields(raw[4:4 + total])
    inner = get_pb_bytes(pb, 4)
    if not inner:
        raise RuntimeError("GetGuid response has no inner GetGuidRsp")
    rsp = parse_pb_fields(inner)
    header = get_pb_bytes(rsp, 1)
    if header:
        header_fields = parse_pb_fields(header)
        ret = get_pb_varint(header_fields, 1)
        if ret is not None and ret != 0:
            raise RuntimeError(f"GetGuid ret={ret}")
    guid = get_pb_bytes(rsp, 2)
    if len(guid) != 16:
        raise RuntimeError(f"GetGuid returned invalid guid length {len(guid)}")
    return guid.hex().upper()


def main():
    parser = argparse.ArgumentParser(description="Fetch QQ Browser Q-Token via WUP TokenInfoReq")
    parser.add_argument("--guid", default=None, help="32-hex device GUID; if omitted, fetch one via PBProxy GetGuid")
    parser.add_argument("--qua2", default=None, help="Q-UA2 string; if omitted, auto-generate from decompiled QUA builder")
    parser.add_argument("--phone", default="18812341234", help="SIM phone number used by KingCard/TencentSim (sPhoneNum)")
    parser.add_argument("--model", default="", help="device model used when auto-generating QUA2")
    parser.add_argument("--width", type=int, default=1080, help="screen width used when auto-generating QUA2")
    parser.add_argument("--height", type=int, default=1920, help="screen height used when auto-generating QUA2")
    parser.add_argument("--os", default="10", help="Android version string used when auto-generating QUA2")
    parser.add_argument("--api", type=int, default=33, help="Android API level used when auto-generating QUA2")
    parser.add_argument("--qimei", default="", help="QIMEI (16 hex) if the device has one")
    parser.add_argument("--qimei36", default="", help="QIMEI36 if the device has one")
    parser.add_argument("--server", action="append", help="extra WUP endpoint URL; may be repeated")
    parser.add_argument("--proxy", default=None,
                        help="HTTP proxy URL template; use {account} for rotating egress IP, "
                             "e.g. http://AI.{account}:proxypassoracle@192.168.2.167:22600")
    parser.add_argument("--mode", type=int, choices=(1, 2), default=0,
                        help="encryption mode: 1=ECB/encrypt=12, 2=CBC/encrypt=17; default tries both")
    parser.add_argument("--no-gzip", action="store_true",
                        help="do not gzip the old-WUP request body before AES encryption")
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--max-attempts", type=int, default=50,
                        help="number of rotating-proxy attempts before giving up (default 50)")
    args = parser.parse_args()

    if args.qua2:
        qua2 = args.qua2
    else:
        qua2 = generate_qua2(args.model, args.width, args.height, args.os, args.api)
        print("[*] auto-generated QUA2:", qua2)

    if args.guid:
        guid = args.guid.lower().replace("-", "")
        if len(guid) != 32:
            raise SystemExit("--guid must be 32 hex characters (16 bytes)")
        try:
            bytes.fromhex(guid)
        except ValueError as exc:
            raise SystemExit("--guid must be hex") from exc
    else:
        guid = None
        for guid_attempt in range(1, 6):
            try:
                guid = fetch_guid_from_server(qua2, timeout=max(args.timeout, 15), proxy_template=args.proxy)
                print("[*] fetched server GUID:", guid)
                break
            except Exception as exc:
                print(f"[!] GetGuid attempt {guid_attempt} failed ({exc!r})")
        if not guid:
            print("[!] GetGuid failed, falling back to locally-generated GUID")
            guid = generate_guid_hex()
            print("[*] auto-generated GUID:", guid)

    if args.server:
        urls = list(args.server)
    else:
        urls = load_server_urls()
    if not urls:
        raise SystemExit("No WUP endpoints available")

    modes = [args.mode] if args.mode else (1, 2)
    last_error = None

    for attempt in range(1, args.max_attempts + 1):
        print(f"\n[*] attempt {attempt}/{args.max_attempts}")
        for mode in modes:
            body0, body_to_encrypt, enc_body, query_string, headers, aes_key, iv_hex = build_request_envelope(
                guid, qua2, args.phone, mode, args.qimei, args.qimei36,
                gzip_body=not args.no_gzip,
            )
            print(f"[*] trying encrypt mode {mode} ({'CBC/17' if mode == 2 else 'ECB/12'}), "
                  f"plain WUP len={len(body0)}, {'gzip len=' + str(len(body_to_encrypt)) + ', ' if args.no_gzip is False else ''}"
                  f"encrypted len={len(enc_body)}")
            for url in urls:
                try:
                    resp, data, plain = try_one_endpoint(
                        url, enc_body, query_string, headers, aes_key, iv_hex, mode, args.timeout,
                        proxy_template=args.proxy,
                    )
                    print(f"    {url} -> HTTP {resp.status_code}, body_len={len(data)}")
                    if resp.status_code != 200:
                        last_error = f"HTTP {resp.status_code}: {data[:200]!r}"
                        continue
                    if plain is None:
                        last_error = "response could not be AES-decrypted (maybe wrong mode/endpoint)"
                        continue

                    try:
                        rsp = parse_wup_response(plain)
                    except Exception as exc:
                        last_error = f"response parse failed: {exc}"
                        print("    decrypted hex:", plain.hex()[:300])
                        continue

                    print("[+] TokenInfoRsp parsed:")
                    print("    rspCode    =", rsp.get(0))
                    print("    Q-Token    =", rsp.get(1))
                    print("    expireTime =", rsp.get(2))
                    print("    Q-Key      =", rsp.get(3))
                    print("    HTTP tk    =", resp.headers.get("tk"))
                    print("    HTTP maxage=", resp.headers.get("maxage"))

                    if rsp.get(0) == 0 and rsp.get(1):
                        # Emit machine-readable JSON as the final line.
                        out = {
                            "q_token": rsp.get(1),
                            "q_key": rsp.get(3),
                            "expire_seconds": rsp.get(2),
                            "rsp_code": rsp.get(0),
                            "mode": mode,
                            "url": url,
                            "http_tk": resp.headers.get("tk"),
                            "http_maxage": resp.headers.get("maxage"),
                            "attempt": attempt,
                        }
                        print("JSON=" + json.dumps(out, ensure_ascii=False))
                        return 0
                    last_error = f"rspCode={rsp.get(0)}, token={rsp.get(1)!r}"
                except Exception as exc:
                    last_error = f"{url}: {exc!r}"
                    print(f"    {url} EXC {exc!r}")

    print("\n[!] failed to obtain a valid Q-Token after all attempts")
    if last_error:
        print("    last error:", last_error)
    return 1


if __name__ == "__main__":
    sys.exit(main())