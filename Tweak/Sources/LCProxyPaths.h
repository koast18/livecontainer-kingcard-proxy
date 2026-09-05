#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString * _Nullable LCProxySharedRootFromDylibPath(NSString *dylibPath);
NSString *LCProxySharedRootDirectory(void);
NSString *LCProxyDylibPath(void);
NSString *LCProxyDataDirectory(void);
NSString * _Nullable LCProxySharedDataDirectory(void);
/// The only directory permitted to own active settings and KingCard state.
/// An App Group, when available, is authoritative over launch-private copies.
NSString *LCProxyCanonicalDataDirectory(void);
NSArray<NSString *> *LCProxyAllDataDirectories(void);

NS_ASSUME_NONNULL_END
