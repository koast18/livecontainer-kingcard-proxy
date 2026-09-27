#ifndef LCPROXY_PROXY_OVERRIDE_H
#define LCPROXY_PROXY_OVERRIDE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Per-process runtime HTTP proxy override.
 *
 * In LiveContainer shared-app mode several processes may share the same
 * proxychains.conf.  The KingCard local forwarder is now started on an
 * ephemeral loopback port so each process owns its own forwarder; this
 * override lets the shared config keep its default 127.0.0.1:18080 while the
 * in-memory proxy list (and WKWebView proxy) use the process-specific port.
 */
void lcproxy_control_set_proxy_override(const char *host, int port);
int  lcproxy_control_get_proxy_override(char *host, size_t hostlen, int *port);
void lcproxy_control_apply_proxy_override(void *proxy_list, unsigned int proxy_count);

/*
 * 端口**实际被烘焙进代理链**的那一个（0 = 当前链里没有生效的 override）。
 *
 * 与 lcproxy_control_get_proxy_override 的区别：后者是"我们想用哪个端口"，前者是
 * "链里真正生效的端口"。二者可能不一致（链为空时 apply 会跳过、reload 失败时链停在
 * conf 的占位端口 18080）。调用方据此自愈：不一致就重载配置。
 */
int  lcproxy_control_get_applied_override_port(void);

#ifdef __cplusplus
}
#endif

#endif /* LCPROXY_PROXY_OVERRIDE_H */
