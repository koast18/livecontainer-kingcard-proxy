#import "LCProxyPaths.h"
#import <dlfcn.h>
#import <objc/message.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>

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

NSString *LCProxyGuestDataDirectory(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (!paths.count) return nil;
    return [paths[0] stringByAppendingPathComponent:@"LCProxy"];
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
    SEL selector = sel_registerName("appGroupID");
    if (!cls || ![cls respondsToSelector:selector]) return nil;
    NSString *groupID = ((NSString *(*)(id, SEL))objc_msgSend)(cls, selector);
    if (![groupID isKindOfClass:[NSString class]] || groupID.length == 0) return nil;
    NSURL *groupURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupID];
    if (!groupURL) return nil;
    return [[groupURL URLByAppendingPathComponent:@"LiveContainer/LCProxy"] path];
}

NSString *LCProxyCanonicalDataDirectory(void) {
    NSString *shared = LCProxySharedDataDirectory();
    return shared.length ? shared : LCProxyDataDirectory();
}

NSArray<NSString *> *LCProxyAllDataDirectories(void) {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSString *primary = LCProxyCanonicalDataDirectory();
    if (primary.length) [dirs addObject:primary];
    NSString *dylibLocal = LCProxyDataDirectory();
    if (dylibLocal.length && ![dirs containsObject:dylibLocal]) [dirs addObject:dylibLocal];
    NSString *guest = LCProxyGuestDataDirectory();
    if (guest.length && ![dirs containsObject:guest]) [dirs addObject:guest];
    NSString *shared = LCProxySharedDataDirectory();
    if (shared.length && ![dirs containsObject:shared]) [dirs addObject:shared];
    NSString *launchPrivate = LCProxyLaunchPrivateDataDirectory();
    if (launchPrivate.length && ![dirs containsObject:launchPrivate]) [dirs addObject:launchPrivate];
    // Legacy copies are only migration fallbacks, but keep their iteration
    // order deterministic for callers that inspect them concurrently.
    return [dirs sortedArrayUsingSelector:@selector(compare:)];
}

// ---------------------------------------------------------------------------
// 崩溃加固：兜住并记录 ObjC 异常
// ---------------------------------------------------------------------------

// 只保留最近若干条：这是诊断信息，不需要无限增长（也就不会占内存）。
#define LC_PROXY_SWALLOWED_MAX 8
static NSMutableArray<NSString *> *g_lcSwallowed;   // 新→旧
static NSLock *g_lcSwallowedLock;

void LCProxyRecordSwallowedException(NSString *context, NSException *e) {
    NSString *name = e.name ?: @"(nil)";
    NSString *reason = e.reason ?: @"";
    if (reason.length > 300) reason = [reason substringToIndex:300];
    NSString *entry = [NSString stringWithFormat:@"%.0f %@: %@: %@",
                       [[NSDate date] timeIntervalSince1970],
                       context ?: @"?",
                       name,
                       reason];

    // 进程内记录：用独立锁，避免与任何既有锁发生顺序问题（本函数可能在任何
    // 上下文被调用，包括已持有其他锁的路径 —— 所以绝不调用任何可能回头的代码）。
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_lcSwallowed = [NSMutableArray array];
        g_lcSwallowedLock = [[NSLock alloc] init];
    });
    [g_lcSwallowedLock lock];
    [g_lcSwallowed insertObject:entry atIndex:0];
    while (g_lcSwallowed.count > LC_PROXY_SWALLOWED_MAX) {
        [g_lcSwallowed removeLastObject];
    }
    [g_lcSwallowedLock unlock];

    // 共享日志：让任何 LiveContainer 实例的控制台都能看到（共享 App 的现场尤其如此）。
    // 纯诊断，任何失败都必须静默 —— 本函数本身就在处理异常，绝不能再次抛出。
    @try {
        NSString *dir = LCProxyCanonicalDataDirectory();
        if (!dir.length) return;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [dir stringByAppendingPathComponent:@"kingcard-refresh.log"];
        NSDictionary *record = @{
            @"ts": @([[NSDate date] timeIntervalSince1970]),
            @"pid": @(getpid()),
            @"ok": @NO,
            @"src": @"exception",
            @"ms": @0,
            @"msg": entry,
        };
        if (![NSJSONSerialization isValidJSONObject:record]) return;
        NSData *line = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
        if (!line.length) return;
        NSMutableData *payload = [line mutableCopy];
        [payload appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd < 0) return;
        ssize_t ignored = write(fd, payload.bytes, payload.length);
        (void)ignored;
        close(fd);
    } @catch (__unused NSException *ignored) {
        // 兜底中的兜底：记录失败绝不能再抛。
    }
}

NSArray<NSString *> *LCProxySwallowedExceptions(void) {
    if (!g_lcSwallowed) return @[];
    [g_lcSwallowedLock lock];
    NSArray<NSString *> *copy = [g_lcSwallowed copy];
    [g_lcSwallowedLock unlock];
    return copy;
}
