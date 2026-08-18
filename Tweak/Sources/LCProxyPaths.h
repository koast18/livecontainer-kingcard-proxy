#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString * _Nullable LCProxySharedRootFromDylibPath(NSString *dylibPath);
NSString *LCProxySharedRootDirectory(void);
NSString *LCProxyDataDirectory(void);
NSString * _Nullable LCProxySharedDataDirectory(void);
NSArray<NSString *> *LCProxyAllDataDirectories(void);

NS_ASSUME_NONNULL_END
