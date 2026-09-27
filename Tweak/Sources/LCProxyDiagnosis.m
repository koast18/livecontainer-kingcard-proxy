#import "LCProxyDiagnosis.h"

// ---------------------------------------------------------------------------
// 纯函数式诊断：把状态字段翻译成结论。
//
// 设计约束（刻意保持）：
//   · 不取任何锁、不读文件、不发网络请求 —— 因此可以在任何线程安全调用；
//   · 只依赖传入的字典 —— 因此可以用构造出来的样例字典做单元测试；
//   · 每条结论都自带"该怎么看/下一步"，避免只有结论没有方向。
// ---------------------------------------------------------------------------

static NSNumber *LCProxyDiagNum(id container, NSString *key) {
    if (![container isKindOfClass:[NSDictionary class]]) return nil;
    id v = ((NSDictionary *)container)[key];
    return [v isKindOfClass:[NSNumber class]] ? v : nil;
}

static NSString *LCProxyDiagStr(id container, NSString *key) {
    if (![container isKindOfClass:[NSDictionary class]]) return @"";
    id v = ((NSDictionary *)container)[key];
    return [v isKindOfClass:[NSString class]] ? v : @"";
}

static long long LCProxyDiagLL(id container, NSString *key) {
    NSNumber *n = LCProxyDiagNum(container, key);
    return n ? n.longLongValue : 0;
}

static void LCProxyDiagAdd(NSMutableArray *out, LCProxyDiagLevel level, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *text = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [out addObject:@{ @"level": @(level), @"text": text ?: @"" }];
}

NSDictionary *LCProxyDiagnose(NSDictionary *payload) {
    NSMutableArray *verdict = [NSMutableArray array];

    if (![payload isKindOfClass:[NSDictionary class]] || payload.count == 0) {
        LCProxyDiagAdd(verdict, LCProxyDiagLevelWarn, @"拿不到状态数据，无法判断。");
        return @{ @"level": @(LCProxyDiagLevelWarn), @"summary": @"状态数据缺失", @"verdict": verdict };
    }

    NSDictionary *king = [payload[@"king"] isKindOfClass:[NSDictionary class]] ? payload[@"king"] : @{};

    // ---- 模式与开关 ----
    BOOL enabled = [LCProxyDiagNum(payload, @"proxyEnabled") boolValue];
    NSString *mode = LCProxyDiagStr(payload, @"effectiveMode");
    if (!enabled) {
        LCProxyDiagAdd(verdict, LCProxyDiagLevelWarn, @"代理总开关是关闭的 —— 此时所有连接都不经代理。");
    }
    if (mode.length && ![mode isEqualToString:@"kingcard"]) {
        LCProxyDiagAdd(verdict, LCProxyDiagLevelWarn,
                       @"当前生效模式是「%@」而不是 kingcard；王卡免流逻辑不参与。", mode);
    }

    // ---- 转发器：运行 / 真监听 ----
    int port = (int)LCProxyDiagLL(king, @"forwarderPort");
    BOOL running = [LCProxyDiagNum(king, @"running") boolValue];
    long long listenFdValid = LCProxyDiagLL(king, @"listenFdValid");
    long long listenProbeOk = LCProxyDiagLL(king, @"listenProbeOk");

    if (!running || port <= 0) {
        LCProxyDiagAdd(verdict, LCProxyDiagLevelBad,
                       @"转发器没有在运行（port=%d）—— 这是 fail-closed，会直接丢包。", port);
    } else if (listenProbeOk != 1) {
        // 这两种字段放在一起是本项目最隐蔽的故障形态：进后台/熄屏会让监听 socket 失效，
        // 但 fd 号与 running 标志都还"正常"。
        LCProxyDiagAdd(verdict, LCProxyDiagLevelBad,
                       @"**监听已失效**：实际 connect 探测失败（listenProbeOk=0），"
                       @"而 listenFdValid=%lld 仍显示正常 —— 这是后台/熄屏后典型形态，"
                       @"需要重建转发器。", listenFdValid);
    } else {
        LCProxyDiagAdd(verdict, LCProxyDiagLevelOk, @"转发器在运行，且实测可接受连接（port=%d）。", port);
    }

    // ---- 代理链：真正生效的端口 ----
    long long chainPort = LCProxyDiagLL(payload, @"chainProxyPort");
    if (port > 0 && chainPort != port) {
        LCProxyDiagAdd(verdict, LCProxyDiagLevelBad,
                       @"代理链里实际生效的端口(%lld)与转发器端口(%d)不一致 —— "
                       @"连接会被发到别处（例如无人监听的占位端口）。", chainPort, port);
    }

    // ---- 路由发布 ----
    if ([king objectForKey:@"routePublished"]) {
        if (LCProxyDiagLL(king, @"routePublished") != 1) {
            LCProxyDiagAdd(verdict, LCProxyDiagLevelBad,
                           @"路由**未发布**：此时取号会直接失败并可能回退到本地假身份，"
                           @"同时主动续期定时器被停掉。");
        }
    }

    // ---- 凭证与身份 ----
    long long httpPool = LCProxyDiagLL(king, @"liveHttpPool");
    long long httpsPool = LCProxyDiagLL(king, @"liveHttpsPool");
    if (running && httpPool + httpsPool == 0) {
        LCProxyDiagAdd(verdict, LCProxyDiagLevelBad,
                       @"代理池为空（http=%lld https=%lld）—— 转发器找不到任何上游节点。",
                       httpPool, httpsPool);
    }
    NSString *guidSource = LCProxyDiagStr(king, @"guidSource");
    if ([guidSource isEqualToString:@"local"]) {
        LCProxyDiagAdd(verdict, LCProxyDiagLevelWarn,
                       @"当前用的是**本地生成的引导身份**（guidSource=local）。运营商并不认识它，"
                       @"带着它转发会被上游直接关闭；它只应在启动瞬间存在，"
                       @"若长期如此说明 PBProxy 取 GUID 一直失败（常见原因：路由未发布）。");
    }
    if (![king[@"lastRefreshSuccess"] isKindOfClass:[NSNumber class]] ||
        ![LCProxyDiagNum(king, @"lastRefreshSuccess") boolValue]) {
        NSString *err = LCProxyDiagStr(king, @"lastError");
        if (err.length) {
            LCProxyDiagAdd(verdict, LCProxyDiagLevelWarn, @"最近一次取号失败：%@", err);
        }
    }

    // ---- 上游：分步失败现场（最有用的一块）----
    NSDictionary *up = [king[@"upstreamDiag"] isKindOfClass:[NSDictionary class]] ? king[@"upstreamDiag"] : nil;
    if (up) {
        long long connectFail = LCProxyDiagLL(up, @"connectFail");
        long long sendFail = LCProxyDiagLL(up, @"sendFail");
        long long recvFail = LCProxyDiagLL(up, @"recvFail");
        long long recvEof = LCProxyDiagLL(up, @"recvEof");
        long long recvRst = LCProxyDiagLL(up, @"recvRst");
        long long recvTimeout = LCProxyDiagLL(up, @"recvTimeout");
        long long credCode = LCProxyDiagLL(up, @"credCode");
        long long otherCode = LCProxyDiagLL(up, @"otherCode");
        long long tunnelNoData = LCProxyDiagLL(up, @"tunnelNoData");
        long long fakeOk = LCProxyDiagLL(up, @"fakeOk");

        if (credCode > 0) {
            LCProxyDiagAdd(verdict, LCProxyDiagLevelBad,
                           @"上游明确回凭证失效码(820/821/823) %lld 次 —— 身份/令牌不被接受。", credCode);
        }
        if (tunnelNoData > 0) {
            LCProxyDiagAdd(verdict, LCProxyDiagLevelBad,
                           @"隧道已建立(200)但上游**一个字节都不回** %lld 次 —— "
                           @"拿到 200 后 TLS 握手永远完不成。", tunnelNoData);
        }
        if (recvFail > 0) {
            NSString *detail = [NSString stringWithFormat:@"其中 干净关闭=%lld 硬重置=%lld 读超时=%lld",
                                recvEof, recvRst, recvTimeout];
            LCProxyDiagAdd(verdict, LCProxyDiagLevelBad,
                           @"上游**零字节响应** %lld 次（%@）—— 请求发出去了但拿不到任何回应；"
                           @"对端若连状态码都不给，通常是身份不被接受或网络路径不被允许。",
                           recvFail, detail);
        }
        if (connectFail > 0) {
            LCProxyDiagAdd(verdict, LCProxyDiagLevelWarn, @"连不上上游节点 %lld 次（TCP 层就失败）。", connectFail);
        }
        if (sendFail > 0) {
            LCProxyDiagAdd(verdict, LCProxyDiagLevelWarn, @"向上游发送请求失败 %lld 次。", sendFail);
        }
        if (fakeOk > 0) {
            LCProxyDiagAdd(verdict, LCProxyDiagLevelWarn,
                           @"上游回 200 但随后是 HTTP 错误文本 %lld 次（伪成功，通常 token 失效）。", fakeOk);
        }
        if (otherCode > 0) {
            LCProxyDiagAdd(verdict, LCProxyDiagLevelWarn,
                           @"上游回了其它非 2xx 状态码 %lld 次（最近一次 code=%lld）。",
                           otherCode, LCProxyDiagLL(up, @"lastCode"));
        }
        NSString *req = LCProxyDiagStr(up, @"req");
        if (req.length) {
            LCProxyDiagAdd(verdict, LCProxyDiagLevelOk, @"最近一次实际发出的请求（结构快照）：%@", req);
        }
        NSString *lastProxy = LCProxyDiagStr(up, @"lastProxy");
        if (lastProxy.length) {
            LCProxyDiagAdd(verdict, LCProxyDiagLevelOk, @"最近一次失败的目标节点：%@（阶段 %@）",
                           lastProxy, LCProxyDiagStr(up, @"lastStage"));
        }
    }

    // ---- 并发槽位 ----
    long long rejections = LCProxyDiagLL(king, @"statClientRejections");
    long long clients = LCProxyDiagLL(king, @"activeForwarderClients");
    if (rejections > 0) {
        LCProxyDiagAdd(verdict, LCProxyDiagLevelWarn,
                       @"因并发槽位耗尽被回 503 共 %lld 次（当前活跃 %lld）。"
                       @"上游变慢时槽位会被长期占住，转发器会从「慢」退化为「全拒」。",
                       rejections, clients);
    }

    // ---- 宿主健康 ----
    NSArray *swallowed = [payload[@"swallowedExceptions"] isKindOfClass:[NSArray class]]
                       ? payload[@"swallowedExceptions"] : @[];
    if (swallowed.count) {
        LCProxyDiagAdd(verdict, LCProxyDiagLevelWarn,
                       @"本 tweak 抛过 %lu 次异常（已被兜住，宿主未崩）：%@",
                       (unsigned long)swallowed.count, swallowed.firstObject ?: @"");
    }

    // ---- 汇总 ----
    LCProxyDiagLevel worst = LCProxyDiagLevelOk;
    NSUInteger bad = 0, warn = 0;
    for (NSDictionary *item in verdict) {
        LCProxyDiagLevel lv = (LCProxyDiagLevel)[item[@"level"] integerValue];
        if (lv > worst) worst = lv;
        if (lv == LCProxyDiagLevelBad) bad++;
        else if (lv == LCProxyDiagLevelWarn) warn++;
    }
    NSString *summary;
    if (bad > 0) {
        summary = [NSString stringWithFormat:@"发现 %lu 项导致无法上网的问题（另有 %lu 项警告）。",
                   (unsigned long)bad, (unsigned long)warn];
    } else if (warn > 0) {
        summary = [NSString stringWithFormat:@"链路可用，但有 %lu 项警告需要留意。", (unsigned long)warn];
    } else {
        summary = @"未发现异常：转发器、代理链、凭证池与上游链路均正常。";
    }

    return @{ @"level": @(worst), @"summary": summary, @"verdict": verdict };
}
