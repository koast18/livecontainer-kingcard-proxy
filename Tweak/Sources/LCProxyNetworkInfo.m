#import "LCProxyNetworkInfo.h"
#import <objc/message.h>

// CoreTelephony 以弱链接方式使用：在某些环境（无 SIM、模拟器、受限沙箱）下相关类可能
// 不存在或返回空，本单元必须在这种情形下安静退化，绝不能让宿主 App 崩溃。
#import <CoreTelephony/CoreTelephony.h>

NSString *LCProxyNetworkTypeName(BOOL cellularActive) {
    return cellularActive ? @"MOBILE" : @"WIFI";
}

NSInteger LCProxyNetworkSubtype(BOOL cellularActive, BOOL pathSatisfied) {
    if (!pathSatisfied) return -1;   // 网络不可用时按"未知"上报，与文档一致
    return cellularActive ? 0 : 1;
}

NSString *LCProxyNetworkMccMnc(void) {
    Class infoClass = NSClassFromString(@"CTTelephonyNetworkInfo");
    if (!infoClass) return @"NULLNULL";

    id info = nil;
    @try {
        info = [[infoClass alloc] init];
    } @catch (__unused NSException *e) {
        return @"NULLNULL";
    }
    if (!info) return @"NULLNULL";

    // 依次尝试若干代 API（新→旧），任何一个可用即可。
    NSArray<id> *carriers = nil;
    @try {
        SEL providersSel = NSSelectorFromString(@"serviceSubscriberCellularProviders");
        if ([info respondsToSelector:providersSel]) {
            NSDictionary *providers = ((id (*)(id, SEL))objc_msgSend)(info, providersSel);
            if ([providers isKindOfClass:[NSDictionary class]]) {
                carriers = providers.allValues;
            }
        }
        if (!carriers.count) {
            SEL legacySel = NSSelectorFromString(@"subscriberCellularProvider");
            if ([info respondsToSelector:legacySel]) {
                id carrier = ((id (*)(id, SEL))objc_msgSend)(info, legacySel);
                if (carrier) carriers = @[ carrier ];
            }
        }
    } @catch (__unused NSException *e) {
        return @"NULLNULL";
    }

    for (id carrier in carriers) {
        if (!carrier) continue;
        NSString *mcc = nil;
        NSString *mnc = nil;
        @try {
            SEL mccSel = NSSelectorFromString(@"mobileCountryCode");
            SEL mncSel = NSSelectorFromString(@"mobileNetworkCode");
            if ([carrier respondsToSelector:mccSel]) {
                mcc = ((id (*)(id, SEL))objc_msgSend)(carrier, mccSel);
            }
            if ([carrier respondsToSelector:mncSel]) {
                mnc = ((id (*)(id, SEL))objc_msgSend)(carrier, mncSel);
            }
        } @catch (__unused NSException *e) {
            continue;
        }
        if (![mcc isKindOfClass:[NSString class]] || !mcc.length) continue;
        if (![mnc isKindOfClass:[NSString class]] || !mnc.length) continue;
        // 只在两者都是纯数字时才拼接（避免把占位文本当 MCC/MNC 上报）。
        NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
        if ([mcc rangeOfCharacterFromSet:digits.invertedSet].location != NSNotFound) continue;
        if ([mnc rangeOfCharacterFromSet:digits.invertedSet].location != NSNotFound) continue;
        return [NSString stringWithFormat:@"%@%@", mcc, mnc];
    }
    return @"NULLNULL";
}