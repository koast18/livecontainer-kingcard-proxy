#import "LCProxySharedLog.h"

#include <fcntl.h>
#include <unistd.h>

BOOL LCProxySharedLogAppendLine(NSString *directory, NSString *filename,
                                NSUInteger maxLines, NSDictionary *record) {
    if (!directory.length || !filename.length || !record.count) return NO;
    if (![NSJSONSerialization isValidJSONObject:record]) return NO;

    NSData *line = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (!line.length) return NO;

    NSString *path = [directory stringByAppendingPathComponent:filename];
    NSMutableData *payload = [line mutableCopy];
    [payload appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];

    // O_APPEND + 单次 write：多进程并发下每行仍然是原子的，无需加锁。
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) return NO;
    ssize_t ignored = write(fd, payload.bytes, payload.length);
    (void)ignored;
    close(fd);

    if (maxLines > 0) LCProxySharedLogTrim(path, maxLines);
    return YES;
}

void LCProxySharedLogTrim(NSString *path, NSUInteger maxLines) {
    if (!path.length || maxLines == 0) return;
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return;
    NSArray<NSString *> *all = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *l in all) {
        if (l.length) [kept addObject:l];
    }
    if (kept.count <= maxLines) return;
    // 保留后半段（越新越有用），一次砍到一半以减少裁剪频率。
    NSUInteger keep = MAX((NSUInteger)1, maxLines / 2);
    NSRange cut = NSMakeRange(kept.count - keep, keep);
    NSString *out = [[kept subarrayWithRange:cut] componentsJoinedByString:@"\n"];
    [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}