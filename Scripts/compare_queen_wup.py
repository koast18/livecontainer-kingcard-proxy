#!/usr/bin/env python3
import sys
sys.path.insert(0, 'Tools/queen_proxy_kit')
import fetch_q_token as fqt
import fetch_queen_proxy_oldwup as oldwup

guid = '00112233445566778899aabbccddeeff'
qua2 = 'QV=3&PL=ADR&PR=QB&PP=com.tencent.mtt&PPVN=19.9.0.0047&CO=SYS&PB=GE&VE=GA&DE=PHONE&CHID=0&LCID=25681&MO=  &RL=1080*1920&OS=10&API=33&DS=64&RT=64&REF=qb_0&TM=01'
phone = '18812341234'

token_wup = fqt.build_wup_request(
    fqt.SERVANT, fqt.FUNC, fqt.REQ_KEY, fqt.REQ_TYPE,
    fqt.token_info_req(guid, qua2, phone), 0,
)
route_bytes = oldwup.build_route_ip_list_req(
    guid, qua2,
    apn='3gnet',
    type_name='MOBILE',
    subtype=0,
    extra_info='uninet',
    mccmnc='46001',
    card_type=1,
    iptypes=(15, 16),
)
route_wup = fqt.build_wup_request(
    'proxyip', 'getIPListByRouter', 'req', 'MTT.RouteIPListReq', route_bytes, 0,
)
common = fqt.build_common_header(guid)

print(f'TOKEN_WUP {token_wup.hex()}')
print(f'ROUTE_WUP {route_wup.hex()}')
print(f'COMMON_HEADER {common}')
