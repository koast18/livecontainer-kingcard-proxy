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

    if (!pd || proxy_count == 0)
        return;
    if (!lcproxy_control_get_proxy_override(host, sizeof(host), &port))
        return;

    memset(&pd[0].ip, 0, sizeof(pd[0].ip));
    pd[0].ip.is_v6 = !!strchr(host, ':');
    if (pd[0].ip.is_v6) {
        if (inet_pton(AF_INET6, host, pd[0].ip.addr.v6) != 1)
            return;
    } else {
        if (inet_pton(AF_INET, host, pd[0].ip.addr.v4.octet) != 1)
            return;
    }
    pd[0].port = htons((unsigned short)port);
    pd[0].ps = PLAY_STATE;
}
