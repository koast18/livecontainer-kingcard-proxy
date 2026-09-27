#include "proxy_override.h"
#include "core.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static char lc_proxy_override_host[256];
static int lc_proxy_override_port = 0;
static int lc_proxy_override_valid = 0;
static pthread_mutex_t lc_proxy_override_mutex = PTHREAD_MUTEX_INITIALIZER;

// **真正被烘焙进代理链**的端口（由 lcproxy_control_apply_proxy_override 写入）。
//
// 为什么必须单独记录：lc_proxy_override_port 只表示"我们希望用哪个端口"，而实际生效的
// 是第一跳代理链里的 pd[0].port。两者可能不一致 ——
//   · apply_proxy_override 在 proxy_count==0 时会**静默返回**（链为空，override 没生效）；
//   · config reload 失败时链会停在 conf 里的占位端口 127.0.0.1:18080（无人监听）；
//   · reload 只在 needsRuntimeReload 为真时发生，稳态下不会重跑。
// 一旦不一致且无人察觉，所有连接都会打到没人监听的端口 → "彻底无法联网"，而
// /api/status 里的 proxyOverridePort 依然显示"正确"的值（它读的是 override 变量）。
//
// 记录该值后，ObjC 层可以据此**自愈**：只要它与当前转发器端口不一致就重载配置。
// 0 表示"当前链里没有生效的 override"。
static int lc_proxy_override_applied_port = 0;

void lcproxy_control_set_proxy_override(const char *host, int port) {
    pthread_mutex_lock(&lc_proxy_override_mutex);
    if (!host || !host[0] || port <= 0 || port > 65535) {
        lc_proxy_override_valid = 0;
        lc_proxy_override_host[0] = '\0';
        lc_proxy_override_port = 0;
        pthread_mutex_unlock(&lc_proxy_override_mutex);
        return;
    }
    snprintf(lc_proxy_override_host, sizeof(lc_proxy_override_host), "%s", host);
    lc_proxy_override_port = port;
    lc_proxy_override_valid = 1;
    pthread_mutex_unlock(&lc_proxy_override_mutex);
}

int lcproxy_control_get_proxy_override(char *host, size_t hostlen, int *port) {
    pthread_mutex_lock(&lc_proxy_override_mutex);
    int valid = lc_proxy_override_valid;
    if (valid && host && hostlen > 0) {
        snprintf(host, hostlen, "%s", lc_proxy_override_host);
    }
    if (valid && port) *port = lc_proxy_override_port;
    pthread_mutex_unlock(&lc_proxy_override_mutex);
    return valid;
}

void lcproxy_control_apply_proxy_override(void *proxy_list, unsigned int proxy_count) {
    proxy_data *pd = (proxy_data *)proxy_list;
    char host[256];
    int port = 0;

    // 任何提前返回都必须把"链里实际生效的端口"清零 —— 否则 ObjC 层会误以为 override
    // 已经生效，自愈检查就永远不会触发（这正是"status 正常但连不上"的成因）。
    if (!pd || proxy_count == 0) {
        pthread_mutex_lock(&lc_proxy_override_mutex);
        lc_proxy_override_applied_port = 0;
        pthread_mutex_unlock(&lc_proxy_override_mutex);
        return;
    }
    if (!lcproxy_control_get_proxy_override(host, sizeof(host), &port)) {
        pthread_mutex_lock(&lc_proxy_override_mutex);
        lc_proxy_override_applied_port = 0;
        pthread_mutex_unlock(&lc_proxy_override_mutex);
        return;
    }

    memset(&pd[0].ip, 0, sizeof(pd[0].ip));
    pd[0].ip.is_v6 = !!strchr(host, ':');
    if (pd[0].ip.is_v6) {
        if (inet_pton(AF_INET6, host, pd[0].ip.addr.v6) != 1) {
            pthread_mutex_lock(&lc_proxy_override_mutex);
            lc_proxy_override_applied_port = 0;
            pthread_mutex_unlock(&lc_proxy_override_mutex);
            return;
        }
    } else {
        if (inet_pton(AF_INET, host, pd[0].ip.addr.v4.octet) != 1) {
            pthread_mutex_lock(&lc_proxy_override_mutex);
            lc_proxy_override_applied_port = 0;
            pthread_mutex_unlock(&lc_proxy_override_mutex);
            return;
        }
    }
    pd[0].port = htons((unsigned short)port);
    pd[0].ps = PLAY_STATE;

    pthread_mutex_lock(&lc_proxy_override_mutex);
    lc_proxy_override_applied_port = port;
    pthread_mutex_unlock(&lc_proxy_override_mutex);
}

int lcproxy_control_get_applied_override_port(void) {
    pthread_mutex_lock(&lc_proxy_override_mutex);
    int port = lc_proxy_override_applied_port;
    pthread_mutex_unlock(&lc_proxy_override_mutex);
    return port;
}
