#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// App Group 共享诊断日志的追加与裁剪。
///
/// 为什么单独成文件：这些日志是**跨进程**的（任何 LiveContainer 实例的控制台都要能读到
/// 别的进程，包括共享 App 的现场），因此它们是"可观测性"这一职责，而不是凭证状态机的一部分。
/// 抽出来之后，`LCProxyKing` 不再需要知道文件路径、O_APPEND、JSON 序列化与裁剪策略。
///
/// 语义契约（刻意保持"尽力而为"）：
///   · 行级追加（`O_APPEND`），**不加任何锁** —— 多进程并发写只会多出一行，不会互相破坏；
///   · **任何失败都静默忽略** —— 这些日志纯属诊断，绝不能让写日志的问题影响转发；
///   · 损坏/无法解析的行由读取方跳过，写入方不做校验。
///
/// 全部函数都不抛异常、不返回错误，因此可以在任何线程调用（包括 C 层回调所在线程）。

/// 把 `record` 以一行紧凑 JSON 追加到 `directory/filename`。
///
/// @param directory 目标目录（通常是 `LCProxyCanonicalDataDirectory()`，即 App Group）。
/// @param filename  文件名，例如 `@"kingcard-refresh.log"`。
/// @param maxLines  追加后若超过该行数，则裁剪到约一半（0 表示不裁剪）。
/// @param record    必须可被 `NSJSONSerialization` 序列化；不可序列化时直接放弃。
/// @return 是否成功写入（调用方通常忽略）。
BOOL LCProxySharedLogAppendLine(NSString *directory, NSString *filename,
                                NSUInteger maxLines, NSDictionary *record);

/// 若 `path` 的行数超过 `maxLines`，保留**后半段**（约 `maxLines/2` 行）覆盖写回。
/// 用于给已经存在的大日志做瘦身；失败静默忽略。
void LCProxySharedLogTrim(NSString * _Nullable path, NSUInteger maxLines);

NS_ASSUME_NONNULL_END