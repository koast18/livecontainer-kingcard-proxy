#import "LCProxyNetworkInfo.h"
#import <objc/message.h>

// 刻意**不**导入 <CoreTelephony/CoreTelephony.h>：
//   · 本单元完全通过 NSClassFromString + respondsToSelector + objc_msgSend 动态访问
//     CTCarrier/CTTelephonyNetworkInfo，不使用任何 CoreTelephony 的类型或符号；
//   · 该头文件在 iOS SDK 里的路径并不稳定，导入它会让编译（以及不同 SDK 版本）变脆。
// 运行时依赖由 build_ios.sh 的 -weak_framework CoreTelephony 保证：
// 框架可用时被映射（类查得到），不可用时安静退化 —— 这正是"宁可退化也不崩宿主"的意图。

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