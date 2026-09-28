// LCProxyDiagnosis 的单元测试。
//
// 为什么值得单独测：诊断函数是**判断逻辑**，而本项目的多数误判恰恰发生在"读状态、下结论"
// 这一步（不是数据缺失，而是把数据读错）。它是纯函数（不取锁、不读文件、不发网络），因此
// 可以在 CI 的 macOS 上直接跑真实断言，而不必依赖真机。
//
// 每个用例都取自实际发生过的故障形态，因此这些断言同时也是"故障形态的回归锁"。

#import <Foundation/Foundation.h>
#import "LCProxyDiagnosis.h"

static int g_failures = 0;

static void expect_level(NSDictionary *payload, LCProxyDiagLevel want, const char *what) {
    NSDictionary *d = LCProxyDiagnose(payload);
    LCProxyDiagLevel got = (LCProxyDiagLevel)[d[@"level"] integerValue];
    if (got != want) {
        g_failures++;
        fprintf(stderr, "FAIL %s: level want=%ld got=%ld (%s)\n", what, (long)want, (long)got,
                [(d[@"summary"] ?: @"") UTF8String]);
    } else {
        printf("ok   %s\n", what);
    }
}

// 断言结论文本里出现某个关键词 —— 用于确认"给出的是对的那条结论"，而不只是级别对。
static void expect_text(NSDictionary *payload, NSString *needle, const char *what) {
    NSDictionary *d = LCProxyDiagnose(payload);
    BOOL found = NO;
    for (NSDictionary *item in d[@"verdict"]) {
        NSString *t = item[@"text"];
        if ([t isKindOfClass:[NSString class]] && [t containsString:needle]) { found = YES; break; }
    }
    if (!found) {
        g_failures++;
        fprintf(stderr, "FAIL %s: no verdict containing '%s'\n", what, needle.UTF8String);
        for (NSDictionary *item in d[@"verdict"]) {
            fprintf(stderr, "       got: %s\n", [item[@"text"] UTF8String]);
        }
    } else {
        printf("ok   %s\n", what);
    }
}

// 构造一个"一切正常"的基线，各用例只改需要坏掉的那一项。
static NSMutableDictionary *baseline(void) {
    return [@{
        @"proxyEnabled": @YES,
        @"effectiveMode": @"kingcard",
        @"chainProxyPort": @41234,
        @"swallowedExceptions": @[],
        @"king": [@{
            @"forwarderPort": @41234,
            @"running": @YES,
            @"listenFdValid": @1,
            @"listenProbeOk": @1,
            @"routePublished": @1,
            @"publishedForwarderPort": @41234,
            @"liveHttpPool": @4,
            @"liveHttpsPool": @4,
            @"guidSource": @"pbproxy",
            @"lastRefreshSuccess": @YES,
            @"lastError": @"",
            @"activeForwarderClients": @2,
            @"statClientRejections": @0,
            @"upstreamDiag": @{},
        } mutableCopy],
    } mutableCopy];
}

int main(void) {
    @autoreleasepool {
        // 基线：应当没有致命问题。
        expect_level(baseline(), LCProxyDiagLevelOk, "healthy baseline is OK");
        expect_text(baseline(), @"实测可接受连接", "healthy baseline reports the listen probe");

        // ① 后台/熄屏回归形态：listenProbeOk=0 而 listenFdValid 仍为 1。
        {
            NSMutableDictionary *p = baseline();
            NSMutableDictionary *k = [p[@"king"] mutableCopy];
            k[@"listenProbeOk"] = @0;
            k[@"listenFdValid"] = @1;   // 假象：只看 fd 号会以为还健康
            p[@"king"] = k;
            expect_level(p, LCProxyDiagLevelBad, "dead listen socket is BAD");
            expect_text(p, @"监听已失效", "dead listen socket is named explicitly");
        }

        // ② 代理链端口与转发器不一致（连接会被发到别处）。
        {
            NSMutableDictionary *p = baseline();
            p[@"chainProxyPort"] = @18080;   // 占位端口
            expect_level(p, LCProxyDiagLevelBad, "stale chain port is BAD");
            expect_text(p, @"不一致", "stale chain port is named");
        }

        // ③ 路由未发布（取号会失败、续期定时器被停）。
        {
            NSMutableDictionary *p = baseline();
            NSMutableDictionary *k = [p[@"king"] mutableCopy];
            k[@"routePublished"] = @0;
            p[@"king"] = k;
            expect_level(p, LCProxyDiagLevelBad, "unpublished route is BAD");
            expect_text(p, @"未发布", "unpublished route is named");
        }

        // ④ 上游零字节响应（实测最常见的"连不上"形态）。
        {
            NSMutableDictionary *p = baseline();
            NSMutableDictionary *k = [p[@"king"] mutableCopy];
            k[@"upstreamDiag"] = @{
                @"recvFail": @1224, @"recvEof": @1200, @"recvRst": @20, @"recvTimeout": @4,
                @"connectFail": @0, @"sendFail": @0,
                @"lastProxy": @"116.130.228.112:8091", @"lastStage": @"recv",
                @"req": @"CONNECT www.gstatic.com:80 HTTP/1.1 | authKeys: Q-GUID(32) Q-Token(24) | len=380",
            };
            p[@"king"] = k;
            expect_level(p, LCProxyDiagLevelBad, "zero-byte upstream is BAD");
            expect_text(p, @"零字节响应", "zero-byte upstream is named");
            expect_text(p, @"干净关闭=1200", "EOF/RST/timeout are broken out");
            expect_text(p, @"Q-Token(24)", "the request structure snapshot is surfaced");
        }

        // ⑤ 池为空。
        {
            NSMutableDictionary *p = baseline();
            NSMutableDictionary *k = [p[@"king"] mutableCopy];
            k[@"liveHttpPool"] = @0;
            k[@"liveHttpsPool"] = @0;
            p[@"king"] = k;
            expect_level(p, LCProxyDiagLevelBad, "empty proxy pool is BAD");
            expect_text(p, @"代理池为空", "empty pool is named");
        }

        // ⑥ 本地引导身份（运营商不认）——应为警告，而不是致命。
        {
            NSMutableDictionary *p = baseline();
            NSMutableDictionary *k = [p[@"king"] mutableCopy];
            k[@"guidSource"] = @"local";
            p[@"king"] = k;
            expect_level(p, LCProxyDiagLevelWarn, "local bootstrap identity is a WARN");
            expect_text(p, @"引导身份", "local bootstrap identity is explained");
        }

        // ⑦ 上游明确回凭证失效码。
        {
            NSMutableDictionary *p = baseline();
            NSMutableDictionary *k = [p[@"king"] mutableCopy];
            k[@"upstreamDiag"] = @{ @"credCode": @7 };
            p[@"king"] = k;
            expect_level(p, LCProxyDiagLevelBad, "credential rejection is BAD");
            expect_text(p, @"820/821/823", "credential rejection names the codes");
        }

        // ⑩ 配置文件读不到（回退到内置默认值）——"保存看似有用、读取却不对"的形态。
        {
            NSMutableDictionary *p = baseline();
            p[@"configDiag"] = @{
                @"source": @"defaults",
                @"canonicalDirectory": @"/AppGroup/LiveContainer/LCProxy",
                @"effectiveProxyMode": @"custom",
                @"trail": @[ @"任何目录都没有可解析的 settings.json → 使用内置默认值" ],
                @"directories": @[
                    @{ @"dir": @"/AppGroup/LiveContainer/LCProxy", @"isCanonical": @YES,
                       @"writable": @YES, @"settingsExists": @YES, @"settingsReadable": @NO,
                       @"confExists": @YES },
                ],
                @"lastSaveAt": @1, @"lastSaveBytes": @100, @"lastSaveError": @"",
                @"lastSavePerDirectory": @[ @{ @"dir": @"/x", @"result": @"写入失败: 权限不足",
                                              @"readBackOK": @NO } ],
            };
            expect_level(p, LCProxyDiagLevelBad, "unreadable config is BAD");
            expect_text(p, @"读不到可解析的 settings.json", "unreadable config is named");
            expect_text(p, @"读不回来", "save-vs-readback asymmetry is surfaced");
        }

        // ⑪ 权威目录缺失、回退到其它目录的最新副本（私有/共享可能看到不同副本）。
        {
            NSMutableDictionary *p = baseline();
            p[@"configDiag"] = @{
                @"source": @"fallback(mtime-newest)",
                @"canonicalDirectory": @"/AppGroup/LiveContainer/LCProxy",
                @"effectiveProxyMode": @"kingcard",
                @"trail": @[ @"权威目录没有 settings.json，回退到最新副本" ],
                @"directories": @[ @{ @"dir": @"/p", @"settingsReadable": @YES, @"writable": @YES } ],
                @"lastSavePerDirectory": @[],
            };
            expect_level(p, LCProxyDiagLevelWarn, "fallback config source is a WARN");
            expect_text(p, @"最新的副本", "fallback is explained (private/shared may differ)");
        }

        // ⑫ 生效配置里 proxyMode 不是 kingcard —— 界面显示与真正生效值不一致。
        {
            NSMutableDictionary *p = baseline();
            p[@"configDiag"] = @{
                @"source": @"canonical",
                @"canonicalDirectory": @"/AppGroup/LiveContainer/LCProxy",
                @"effectiveProxyMode": @"custom",
                @"trail": @[],
                @"directories": @[ @{ @"dir": @"/x", @"settingsReadable": @YES, @"writable": @YES } ],
                @"lastSavePerDirectory": @[ @{ @"dir": @"/x", @"readBackOK": @YES } ],
            };
            expect_level(p, LCProxyDiagLevelBad, "effective mode != kingcard is BAD");
            expect_text(p, @"而不是 kingcard", "the passed-over mode is named explicitly");
        }

        // ⑧ 空输入不得崩溃，且要明确说"拿不到数据"。
        expect_level(@{}, LCProxyDiagLevelWarn, "empty payload does not crash");
        expect_level(nil, LCProxyDiagLevelWarn, "nil payload does not crash");

        // ⑨ 非王卡模式应被点出来。
        {
            NSMutableDictionary *p = baseline();
            p[@"effectiveMode"] = @"direct";
            expect_level(p, LCProxyDiagLevelWarn, "non-kingcard mode is a WARN");
            expect_text(p, @"direct", "non-kingcard mode is named");
        }
    }

    if (g_failures) {
        fprintf(stderr, "\n%d assertion(s) failed\n", g_failures);
        return 1;
    }
    printf("\nLCProxyDiagnosis tests OK\n");
    return 0;
}