#import <Foundation/Foundation.h>
#import "LCProxyKingClient.h"

void lcproxy_socket_set_bypass(int on) {
    (void)on;
}

static NSString *Hex(NSData *d) {
    const uint8_t *b = d.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:d.length * 2];
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

int main(void) {
    @autoreleasepool {
        NSString *guid = @"00112233445566778899aabbccddeeff";
        NSString *qua2 = @"QV=3&PL=ADR&PR=QB&PP=com.tencent.mtt&PPVN=19.9.0.0047&CO=SYS&PB=GE&VE=GA&DE=PHONE&CHID=0&LCID=25681&MO=  &RL=1080*1920&OS=10&API=33&DS=64&RT=64&REF=qb_0&TM=01";
        NSString *phone = @"18812341234";
        NSDictionary *params = @{
            @"apn": @"3gnet",
            @"typeName": @"MOBILE",
            @"subtype": @0,
            @"extraInfo": @"uninet",
            @"mccmnc": @"46001",
            @"cardType": @1,
        };

        NSData *tokenWup = [LCProxyKingClient debugTokenWupRequestWithGuid:guid qua2:qua2 phone:phone];
        NSData *routeWup = [LCProxyKingClient debugRouteIPListWupRequestWithGuid:guid qua2:qua2 params:params];
        NSString *common = [LCProxyKingClient debugCommonHeaderHexWithGuid:guid];

        if (!tokenWup || !routeWup || !common) return 2;
        printf("TOKEN_WUP %s\n", Hex(tokenWup).UTF8String);
        printf("ROUTE_WUP %s\n", Hex(routeWup).UTF8String);
        printf("COMMON_HEADER %s\n", common.UTF8String);
        return 0;
    }
}
