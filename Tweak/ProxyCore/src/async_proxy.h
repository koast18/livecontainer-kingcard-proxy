#ifndef LCPROXY_ASYNC_PROXY_H
#define LCPROXY_ASYNC_PROXY_H

#include "../vendor/proxychains-ng/src/ip_type.h"

/*
 * Start an asynchronous proxied TCP connection for a non-blocking socket.
 *
 * This replaces `sock` with the app-facing end of a local socketpair and starts
 * a relay thread which performs the real proxy CONNECT handshake in the
 * background. The caller should return -1/EINPROGRESS immediately, exactly like
 * a normal non-blocking connect().
 *
 * Returns 0 on success, -1 on setup failure (caller may fall back to the
 * legacy synchronous path).
 */
int lcproxy_async_connect_start(int sock, ip_type target_ip,
                                unsigned short target_port, int orig_flags);

/* Shutdown every active relay peer without closing its descriptor. The relay
 * worker remains the sole close() owner, preventing shutdown/close fd reuse
 * races while lifecycle recovery is in progress. */
void lcproxy_async_close_all(void);

/* Number of relay peers currently owned by workers. */
int lcproxy_async_active_count(void);

#endif /* LCPROXY_ASYNC_PROXY_H */
