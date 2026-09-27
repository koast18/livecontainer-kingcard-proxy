#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString * _Nullable LCProxySharedRootFromDylibPath(NSString *dylibPath);
NSString *LCProxySharedRootDirectory(void);
NSString *LCProxyDylibPath(void);
NSString *LCProxyDataDirectory(void);
NSString *LCProxyGuestDataDirectory(void);
NSString * _Nullable LCProxySharedDataDirectory(void);
/// The only directory permitted to own active settings and KingCard state.
/// An App Group, when available, is authoritative over launch-private copies.
NSString *LCProxyCanonicalDataDirectory(void);
NSArray<NSString *> *LCProxyAllDataDirectories(void);

#pragma mark - 崩溃加固

/// 记录一次被兜住的 ObjC 异常。
///
/// 这是一个**注入式 tweak**，最高优先级是"绝不弄崩宿主 App"。构造器与配置应用路径
/// 一旦抛出 ObjC 异常，异常会穿透 `__attribute__((constructor))` 或 GCD 边界直接终止
/// 进程 —— 在构造器阶段就是"一打开就闪退"。因此关键入口全部用 @try/@catch 兜住：
/// 宁可这一步失效（fail-closed，绝不直连），也不能让 App 挂掉。
///
/// 记录会同时写入 App Group 共享日志，并由 /api/status 的 swallowedExceptions 暴露，
/// 这样即便用户拿不到设备日志，也能看到"我们的代码被兜住了什么"。
void LCProxyRecordSwallowedException(NSString *context, NSException * _Nullable e);

/// 最近若干次被兜住的异常（新→旧，紧凑字符串），供 /api/status 展示。
NSArray<NSString *> *LCProxySwallowedExceptions(void);

NS_ASSUME_NONNULL_END
