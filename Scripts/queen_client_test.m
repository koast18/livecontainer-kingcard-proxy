#import <Foundation/Foundation.h>
#import "LCProxyKingClient.h"

// Stub for proxychains bridge, only used by KPKQueenCore -> KPSocketHookShim.
void lcproxy_socket_set_bypass(int on) {
    (void)on;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *phone = (argc > 1 && strlen(argv[1]) > 0) ? [NSString stringWithUTF8String:argv[1]] : @"18812341234";
        __block NSString *guid = nil;
        __block NSString *token = nil;
        __block NSString *qkey = nil;
        __block NSArray *http = nil;
        __block NSArray *https = nil;
        __block NSString *errorText = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        NSString *qua2 = [LCProxyKingClient generateQua2WithModel:@"" width:1080 height:1920 os:@"10" api:33];
        NSLog(@"[test] qua2=%@", qua2);

        [LCProxyKingClient fetchGuidFromServerWithQua2:qua2 timeout:20 completion:^(NSString * _Nullable g, NSError * _Nullable e) {
            if (!g) {
                errorText = [NSString stringWithFormat:@"guid failed: %@", e.localizedDescription ?: @"unknown"];
                dispatch_semaphore_signal(sem);
                return;
            }
            guid = g;
            NSLog(@"[test] guid=%@", g);

            [LCProxyKingClient fetchTokenWithGuid:g qua2:qua2 phone:phone timeout:20 completion:^(NSDictionary * _Nullable info, NSError * _Nullable e2) {
                if (!info) {
                    errorText = [NSString stringWithFormat:@"token failed: %@", e2.localizedDescription ?: @"unknown"];
                    dispatch_semaphore_signal(sem);
                    return;
                }
                token = info[@"token"];
                qkey = info[@"qkey"];
                NSLog(@"[test] token_len=%lu qkey=%@", (unsigned long)token.length, qkey);

                NSDictionary *params = @{
                    @"apn": @"UNKNOW",
                    @"typeName": @"UNKNOW",
                    @"subtype": @0,
                    @"extraInfo": @"UNKNOW",
                    @"mccmnc": @"NULLNULL",
                    @"cardType": @1,
                };
                [LCProxyKingClient fetchQueenProxiesWithGuid:g qua2:qua2 params:params timeout:20 completion:^(NSDictionary * _Nullable pinfo, NSError * _Nullable e3) {
                    if (!pinfo) {
                        errorText = [NSString stringWithFormat:@"proxy failed: %@", e3.localizedDescription ?: @"unknown"];
                    } else {
                        http = pinfo[@"queen_http"];
                        https = pinfo[@"queen_https"];
                        NSLog(@"[test] queen_http=%@", http);
                        NSLog(@"[test] queen_https=%@", https);
                    }
                    dispatch_semaphore_signal(sem);
                }];
            }];
        }];

        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 75LL * NSEC_PER_SEC));

        if (errorText) {
            NSLog(@"[test] FAILED %@", errorText);
            return 1;
        }
        if (!token.length || !qkey.length || (!http.count && !https.count)) {
            NSLog(@"[test] FAILED incomplete token/proxies");
            return 1;
        }
        NSLog(@"[test] PASS");
        return 0;
    }
}
