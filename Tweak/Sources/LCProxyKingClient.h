#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Queen/King 免流协议客户端：Q-GUID / Q-Token / Q-Key / queen_http / queen_https。
/// 移植自 reverse/queen_proxy_kit 的 Python 脚本。
@interface LCProxyKingClient : NSObject

+ (NSString *)generateQua2WithModel:(NSString *)model
                              width:(NSInteger)width
                             height:(NSInteger)height
                                os:(NSString *)osRelease
                                api:(NSInteger)api;

+ (void)fetchGuidFromServerWithQua2:(NSString *)qua2
                            timeout:(NSTimeInterval)timeout
                         completion:(void (^)(NSString * _Nullable guid, NSError * _Nullable error))completion;

/// 返回 @{@"token":..., @"qkey":..., @"expire_seconds":..., @"mode":..., @"url":...}
+ (void)fetchTokenWithGuid:(NSString *)guid
                      qua2:(NSString *)qua2
                     phone:(NSString *)phone
                   timeout:(NSTimeInterval)timeout
                completion:(void (^)(NSDictionary * _Nullable info, NSError * _Nullable error))completion;

/// 网络参数 params: apn / typeName / subtype / extraInfo / mccmnc / cardType
/// 返回 @{@"queen_http": NSArray<NSString*>, @"queen_https": NSArray<NSString*>, @"server":..., @"mode":...}
+ (void)fetchQueenProxiesWithGuid:(NSString *)guid
                             qua2:(NSString *)qua2
                           params:(NSDictionary *)params
                          timeout:(NSTimeInterval)timeout
                       completion:(void (^)(NSDictionary * _Nullable info, NSError * _Nullable error))completion;

/// 仅供宿主/测试对比二进制拼装，生产逻辑不使用。
+ (NSData *)debugTokenWupRequestWithGuid:(NSString *)guid qua2:(NSString *)qua2 phone:(NSString *)phone;
+ (NSData *)debugRouteIPListWupRequestWithGuid:(NSString *)guid qua2:(NSString *)qua2 params:(NSDictionary *)params;
+ (NSString *)debugCommonHeaderHexWithGuid:(NSString *)guid;

@end

NS_ASSUME_NONNULL_END
