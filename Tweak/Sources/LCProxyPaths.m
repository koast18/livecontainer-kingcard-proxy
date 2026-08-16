#import "LCProxyPaths.h"
#import <dlfcn.h>

NSString * _Nullable LCProxySharedRootFromDylibPath(NSString *dylibPath) {
    if (!dylibPath.length) return nil;
    NSString *dir = [dylibPath stringByDeletingLastPathComponent];
    NSString *base = [dir lastPathComponent];
    if ([base hasSuffix:@".framework"] || [base hasSuffix:@".app"]) {
        dir = [dir stringByDeletingLastPathComponent];
    }
    if ([[dir lastPathComponent] isEqualToString:@"Tweaks"]) {
        dir = [dir stringByDeletingLastPathComponent];
    }
    return dir.length ? dir : nil;
}

NSString *LCProxySharedRootDirectory(void) {
    Dl_info info;
    if (dladdr((const void *)&LCProxySharedRootDirectory, &info) &&
        info.dli_fname && info.dli_fname[0]) {
        NSString *root = LCProxySharedRootFromDylibPath([NSString stringWithUTF8String:info.dli_fname]);
        if (root.length) return root;
    }
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.count ? paths[0] : NSHomeDirectory();
}

NSString *LCProxyDataDirectory(void) {
    return [LCProxySharedRootDirectory() stringByAppendingPathComponent:@"LCProxy"];
}
