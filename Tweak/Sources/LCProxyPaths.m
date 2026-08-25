#import "LCProxyPaths.h"
#import <dlfcn.h>
#import <objc/message.h>

NSString * _Nullable LCProxySharedRootFromDylibPath(NSString *dylibPath) {
    if (!dylibPath.length) return nil;
    NSString *dir = [dylibPath stringByDeletingLastPathComponent];
    NSString *base = [dir lastPathComponent];
    if ([base hasSuffix:@".framework"] || [base hasSuffix:@".app"]) {
        dir = [dir stringByDeletingLastPathComponent];
    }
    if ([[dir lastPathComponent] isEqualToString:@"Tweaks"]) {
        return [dir stringByDeletingLastPathComponent];
    }
    // dylib 可能位于 Tweaks 的子文件夹中（LiveContainer 共享 App 模式）。
    NSString *cur = dir;
    while (cur.length && ![[cur lastPathComponent] isEqualToString:@"Tweaks"]) {
        cur = [cur stringByDeletingLastPathComponent];
    }
    if (cur.length && [[cur lastPathComponent] isEqualToString:@"Tweaks"]) {
        return [cur stringByDeletingLastPathComponent];
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

NSString *LCProxyDylibPath(void) {
    Dl_info info;
    if (dladdr((const void *)&LCProxySharedRootDirectory, &info) &&
        info.dli_fname && info.dli_fname[0]) {
        return [NSString stringWithUTF8String:info.dli_fname] ?: @"";
    }
    return @"";
}

NSString * _Nullable LCProxySharedDataDirectory(void) {
    Class cls = NSClassFromString(@"LCSharedUtils");
    if (!cls) return nil;
    NSString *groupID = ((NSString *(*)(id, SEL))objc_msgSend)(cls, sel_registerName("appGroupID"));
    if (![groupID isKindOfClass:[NSString class]] || groupID.length == 0) return nil;
    NSURL *groupURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (!groupURL) return nil;
    return [[groupURL URLByAppendingPathComponent:@"LiveContainer/LCProxy"] path];
}

NSArray<NSString *> *LCProxyAllDataDirectories(void) {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSString *primary = LCProxyDataDirectory();
    if (primary.length) [dirs addObject:primary];
    NSString *shared = LCProxySharedDataDirectory();
    if (shared.length && ![dirs containsObject:shared]) [dirs addObject:shared];
    return dirs;
}
