#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCProxyConfig : NSObject

+ (instancetype)shared;
- (NSDictionary *)load;
- (BOOL)saveSettings:(NSDictionary *)settings;
- (void)applyToRuntime;
- (NSString *)effectiveProxyModeForSettings:(NSDictionary *)settings;
- (void)startNetworkMonitor;
- (NSString *)proxychainsConfPath;
- (NSString *)settingsPath;

@end

NS_ASSUME_NONNULL_END
