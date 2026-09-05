#include "KPSocketHook.h"
#include "lcproxy_bridge.h"
#include <netdb.h>
#include <sys/socket.h>

void kp_socket_set_bypass(int on) {
    lcproxy_socket_set_bypass(on);
}

#ifdef LC_PROXY_DIRECT_HELPERS_IN_SHIMM
// Host-test shims for the direct libc helpers. The real implementations live in
// libproxychains.c and are only linked into the iOS dylib.
int lcproxy_direct_getaddrinfo(const char *node, const char *service,
                               const struct addrinfo *hints,
                               struct addrinfo **res) {
    return getaddrinfo(node, service, hints, res);
}

void lcproxy_direct_freeaddrinfo(struct addrinfo *res) {
    freeaddrinfo(res);
}

int lcproxy_direct_connect(int sock, const struct sockaddr *addr, socklen_t len) {
    return connect(sock, addr, len);
}
#endif
