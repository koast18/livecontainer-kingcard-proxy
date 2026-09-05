#import "LCProxyPaths.h"
#import <dlfcn.h>
#import <objc/message.h>
#include <stdlib.h>

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

// LiveContainer 在进入 guest 前把自身沙盒家目录写入 LC_HOME_PATH（LCBootstrap），
// 随后 guest 的 HOME 才被切到 guest 数据目录。共享 App 的 dylib 从 App Group 的
// Tweaks 加载，primary 与 App Group 数据目录相同；一旦共享目录里没有
// settings.json（旧安装从未写入、或副本陈旧），guest 不能退到 custom
// 127.0.0.1:8080 的死默认值（所有连接被拒），必须还能回落到启动它的
// LiveContainer 私有数据目录 —— 私有 App 正是从那里正常工作的。
static NSString * _Nullable LCProxyLaunchPrivateDataDirectory(void) {
    const char *home = getenv("LC_HOME_PATH");
    if (!home || !home[0]) return nil;
    NSString *root = [NSString stringWithUTF8String:home];
    if (![root length]) return nil;
    // 私有 Tweaks 位于 <home>/Documents/Tweaks，对应数据目录为
    // <home>/Documents/LCProxy。
    if (![[root lastPathComponent] isEqualToString:@"Documents"]) {
        root = [root stringByAppendingPathComponent:@"Documents"];
    }
    return [root stringByAppendingPathComponent:@"LCProxy"];
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
    NSString *launchPrivate = LCProxyLaunchPrivateDataDirectory();
    if (launchPrivate.length && ![dirs containsObject:launchPrivate]) [dirs addObject:launchPrivate];
    // 王卡状态锁按本列表顺序锁全部目录。不同进程的 primary 不同（私有 App
    // 是 LC 私有目录、共享 App 是 AppGroup 目录），若按 primary 优先的插入
    // 顺序返回，私有进程会以 [LC私有, AppGroup] 抢锁、共享进程以
    // [AppGroup, LC私有] 抢锁 —— 顺序相反，可能互等成环。这里按路径排序，
    // 所有进程看到的全局锁序一致。
    return [dirs sortedArrayUsingSelector:@selector(compare:)];
}
