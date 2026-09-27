#import <Foundation/Foundation.h>
#include <stdarg.h>

NS_ASSUME_NONNULL_BEGIN

/// 诊断结论的严重级别。
typedef NS_ENUM(NSInteger, LCProxyDiagLevel) {
    LCProxyDiagLevelOk = 0,
    LCProxyDiagLevelWarn = 1,
    LCProxyDiagLevelBad = 2,
};

/// 把 `/api/status` 的原始数据翻译成**可读结论**。
///
/// 为什么单独成文件：这些"翻译规则"是纯粹的判断逻辑 —— 不读文件、不取锁、不碰网络、
/// 无副作用，因此可以独立演进与测试。此前它们散落在状态字典的二十来个字段里，只能靠人
/// （实际上是我）逐轮手工解读，这也是反复误判的直接原因。
///
/// 输入是 `/api/status`（或 `/api/status` 的子集）的字典；输出形如：
///
///     @{ @"level":   @(LCProxyDiagLevel)，取所有结论里最严重的一级
///        @"summary": @"…一句话…",
///        @"verdict": @[ @{@"level":@(n), @"text":@"…"}, … ] }
///
/// 传入无法识别的输入时返回一条 Warn（而不是崩溃或空数组），便于前端直接展示。
NSDictionary *LCProxyDiagnose(NSDictionary * _Nullable payload);

NS_ASSUME_NONNULL_END
