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

    lcproxy_control_set_proxy_override("127.0.0.1", 23456);
    assert(lcproxy_control_get_proxy_override(host, sizeof(host), &port) == 1);
    assert(strcmp(host, "127.0.0.1") == 0);
    assert(port == 23456);

    lcproxy_control_apply_proxy_override(pd, 1);
    assert(pd[0].port == htons(23456));
    assert(pd[0].ip.is_v6 == 0);
    struct in_addr loop;
    inet_pton(AF_INET, "127.0.0.1", &loop);
    assert(memcmp(&pd[0].ip.addr.v4, &loop, sizeof(loop)) == 0);
    assert(pd[0].pt == HTTP_TYPE);
    assert(pd[1].port == htons(443));

    lcproxy_control_apply_proxy_override(pd, 0);
    lcproxy_control_set_proxy_override(NULL, 0);
    assert(lcproxy_control_get_proxy_override(host, sizeof(host), &port) == 0);

    puts("proxy override tests OK");
    return 0;
}
