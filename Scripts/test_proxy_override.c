#include "proxy_override.h"
#include "core.h"

#include <arpa/inet.h>
#include <assert.h>
#include <string.h>
#include <stdio.h>

int main(void) {
    proxy_data pd[2];
    memset(pd, 0, sizeof(pd));
    pd[0].pt = HTTP_TYPE;
    pd[0].ps = PLAY_STATE;
    pd[0].port = htons(80);
    inet_pton(AF_INET, "8.8.8.8", pd[0].ip.addr.v4.octet);
    pd[1].pt = HTTP_TYPE;
    pd[1].ps = PLAY_STATE;
    pd[1].port = htons(443);
    inet_pton(AF_INET, "1.1.1.1", pd[1].ip.addr.v4.octet);

    char host[256];
    int port = 0;
    assert(lcproxy_control_get_proxy_override(host, sizeof(host), &port) == 0);

    // 尚未 apply 过：链里没有生效的 override。
    assert(lcproxy_control_get_applied_override_port() == 0);

    lcproxy_control_set_proxy_override("127.0.0.1", 23456);
    assert(lcproxy_control_get_proxy_override(host, sizeof(host), &port) == 1);
    assert(strcmp(host, "127.0.0.1") == 0);
    assert(port == 23456);
    // 仅仅"设置"override 还不算生效 —— 只有烘焙进链才算。这一点是自愈检查的前提。
    assert(lcproxy_control_get_applied_override_port() == 0);

    lcproxy_control_apply_proxy_override(pd, 1);
    assert(pd[0].port == htons(23456));
    assert(pd[0].ip.is_v6 == 0);
    struct in_addr loop;
    inet_pton(AF_INET, "127.0.0.1", &loop);
    assert(memcmp(&pd[0].ip.addr.v4, &loop, sizeof(loop)) == 0);
    assert(pd[0].pt == HTTP_TYPE);
    assert(pd[1].port == htons(443));
    assert(lcproxy_control_get_applied_override_port() == 23456);

    // 核心 KingCard 机制：conf 里是无人监听的**占位端口 18080**，override 必须覆盖它。
    // 这条守卫的是"链真正指向转发器"，而不是"conf 看起来对"。
    memset(pd, 0, sizeof(pd));
    pd[0].pt = HTTP_TYPE;
    pd[0].ps = PLAY_STATE;
    pd[0].port = htons(18080);
    lcproxy_control_apply_proxy_override(pd, 1);
    assert(pd[0].port == htons(23456));
    assert(lcproxy_control_get_applied_override_port() == 23456);

    // 空链（conf 缺失/未解析出代理）：apply 会提前返回，必须把 applied 清零，
    // 否则 ObjC 层的自愈检查会误以为 override 已生效，故障就被永久掩盖。
    lcproxy_control_apply_proxy_override(pd, 0);
    assert(lcproxy_control_get_applied_override_port() == 0);

    // 非法 host（inet_pton 失败）同样必须清零，不能留下"已生效"的假象。
    lcproxy_control_set_proxy_override("not-an-ip", 23456);
    lcproxy_control_apply_proxy_override(pd, 1);
    assert(lcproxy_control_get_applied_override_port() == 0);

    // NULL 链不得崩溃。
    lcproxy_control_set_proxy_override("127.0.0.1", 23456);
    lcproxy_control_apply_proxy_override(NULL, 1);
    assert(lcproxy_control_get_applied_override_port() == 0);

    // 用一个新端口重新 apply：applied 必须更新（这就是自愈后应有的状态）。
    lcproxy_control_set_proxy_override("127.0.0.1", 34567);
    lcproxy_control_apply_proxy_override(pd, 1);
    assert(pd[0].port == htons(34567));
    assert(lcproxy_control_get_applied_override_port() == 34567);

    lcproxy_control_set_proxy_override(NULL, 0);
    assert(lcproxy_control_get_proxy_override(host, sizeof(host), &port) == 0);
    // override 已清空后再次 apply：链里不再有 override，applied 归零。
    lcproxy_control_apply_proxy_override(pd, 1);
    assert(lcproxy_control_get_applied_override_port() == 0);

    puts("proxy override tests OK");
    return 0;
}
