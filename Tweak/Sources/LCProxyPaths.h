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

#pragma mark - 宿主进程形态

/// 本进程属于 LiveContainer 的哪一种宿主形态：
///
/// - `@"liveprocess"`：LiveProcess.appex（URL scheme `*.liveprocess`）。由
///   `xpc_main` / `_xpc_objc_uimain` 承载，`UIApplicationMain` 在
///   `LiveProcess/main.m` 里被**整体替换**，因此 `UIApplication*` 生命周期通知
///   **不会**被投递 —— 对应的通知族是 `NSExtensionHost*`。
/// - `@"uiapp"`：LiveContainer 主 App 进程（普通 UIApplication 生命周期）。
///
/// 为什么必须区分：LiveContainer 把**共享 App** 在 multitask 场景下交给 free 的 LC
/// 实例（见 `LiveContainerSwiftUI/Models/LCAppModel.swift` 的 `uiIsShared` 分支），
/// 那个实例往往正是 `liveprocess`。tweak 若只订阅 `UIApplication*`，在这类进程里
/// 「回前台恢复 / 切后台清理」**一次都不会触发**，转发器与 override 只能停在陈旧
/// 状态上。LiveContainer 自己的 `LiveContainer/Tweaks/Dead10ccFix.m` 就是按
/// `isLiveProcess` 在两个通知族之间切换的。
NSString *LCProxyHostProcessType(void);

/// `LCProxyHostProcessType() == @"liveprocess"`。
BOOL LCProxyIsExtensionHostedProcess(void);

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
