#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCProxyConfig : NSObject

+ (instancetype)shared;

- (NSDictionary *)load;
- (BOOL)saveSettings:(NSDictionary *)settings;
- (void)applyToRuntime;
- (void)requestRuntimeApplyAsync;
- (void)requestForegroundRecoveryAsync;
- (void)notifyDidEnterBackground;
- (void)notifyWillEnterForeground;
- (void)notifyDidBecomeActive;

- (NSString *)effectiveProxyModeForSettings:(NSDictionary *)settings;
- (NSString *)proxychainsConfPath;
- (NSString *)settingsPath;
- (void)startNetworkMonitor;

/// Current lifecycle state: active / foregrounding / background.
- (NSString *)lifecycleState;
/// Incremented every time a foreground/network recovery rebuilds the runtime.
- (NSUInteger)networkGeneration;
/// Diagnostic snapshot for the web console.
- (NSDictionary *)runtimeDiagnostics;

@end

NS_ASSUME_NONNULL_END
