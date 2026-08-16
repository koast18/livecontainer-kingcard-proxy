#include "KPSocketHook.h"
#include "lcproxy_bridge.h"

void kp_socket_set_bypass(int on) {
    lcproxy_socket_set_bypass(on);
}
