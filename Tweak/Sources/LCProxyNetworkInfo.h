#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 当前网络的真实参数，用于向运营商申请**与当前网络匹配**的代理池。
///
/// 为什么必须有：协议文档（Tools/queen_proxy_kit/docs/protocol.md §4）明确写着 ——
/// 服务端按请求里的 `RemoteNetworkInfo` 选择代理 IP；若不传真实网络信息，只能拿到
/// **通用池**，"可能不在联通王卡免流 IP 白名单内"。而实测现场里
/// `kingApn/kingTypeName/kingExtraInfo = UNKNOW`、`kingMccmnc = NULLNULL` ——
/// 即一直在申请通用池。这会让免流通道被上游拒绝（表现为拿到连接后零字节关闭）。
///
/// 可采集性：iOS 上拿不到 APN 字符串（无公开 API，Android 才有），因此 `extraInfo`
/// 保持调用方提供的值；但 **type_name / subtype / mccmnc 都可以准确采集**，
/// 而它们正是服务端挑选池子的主要依据。
///
/// 安全约束（本单元会被注入到第三方 App 里）：
///   · 绝不抛异常、绝不崩溃：所有框架调用都做 respondsToSelector 保护；
///   · 不取锁、不读文件、不发网络请求 —— 可在任何线程调用；
///   · CoreTelephony 不可用时返回 "UNKNOW" / "NULLNULL"，与既有默认值一致。

/// 形如 "MOBILE" / "WIFI" / "UNKNOW"。
/// @param cellularActive 当前路径是否走蜂窝（调用方从 NWPathMonitor 得到）。
NSString *LCProxyNetworkTypeName(BOOL cellularActive);

/// 0 = 蜂窝, 1 = Wi-Fi, -1 = 未知（与协议文档一致）。
NSInteger LCProxyNetworkSubtype(BOOL cellularActive, BOOL pathSatisfied);

/// 形如 "46001"；取不到时返回 "NULLNULL"（与既有默认值一致）。
/// 由运营商 MCC + MNC 拼接，例如中国联通 460 + 01。
NSString *LCProxyNetworkMccMnc(void);

NS_ASSUME_NONNULL_END