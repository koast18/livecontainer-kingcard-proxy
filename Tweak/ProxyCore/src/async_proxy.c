#include "async_proxy.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "../vendor/proxychains-ng/src/core.h"
#include "lcproxy_bridge.h"

extern proxy_data proxychains_pd[];
extern unsigned int proxychains_proxy_count;
extern chain_type proxychains_ct;
extern unsigned int proxychains_max_chain;

#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

static void disable_sigpipe(int fd) {
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#else
    (void)fd;
#endif
}

typedef struct {
    int peer_fd;               /* local TCP peer used by the relay thread */
    ip_type target_ip;
    unsigned short target_port; /* host byte order */
} async_connect_job;

static int write_all(int fd, const void *buf, size_t len) {
    const char *p = buf;
    while (len > 0) {
        ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static void pump_bidirectional(int up, int peer) {
    char buf[16384];
    struct pollfd pfds[2];
    int up_open = 1;
    int peer_open = 1;

    disable_sigpipe(up);
    disable_sigpipe(peer);

    while (up_open || peer_open) {
        pfds[0].fd = up_open ? up : -1;
        pfds[0].events = POLLIN;
        pfds[0].revents = 0;
        pfds[1].fd = peer_open ? peer : -1;
        pfds[1].events = POLLIN;
        pfds[1].revents = 0;

        int n = poll(pfds, 2, -1);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (n == 0) continue;

        if (up_open && (pfds[0].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t r = recv(up, buf, sizeof(buf), 0);
            if (r > 0) {
                if (write_all(peer, buf, (size_t)r) != 0) {
                    up_open = 0;
                    peer_open = 0;
                    break;
                }
            } else {
                up_open = 0;
                shutdown(peer, SHUT_WR);
            }
        }

        if (peer_open && (pfds[1].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t r = recv(peer, buf, sizeof(buf), 0);
            if (r > 0) {
                if (write_all(up, buf, (size_t)r) != 0) {
                    up_open = 0;
                    peer_open = 0;
                    break;
                }
            } else {
                peer_open = 0;
                shutdown(up, SHUT_WR);
            }
        }
    }

    shutdown(up, SHUT_RDWR);
    shutdown(peer, SHUT_RDWR);
}

static void *relay_worker(void *arg) {
    async_connect_job *job = arg;
    int up = -1;

    up = socket(job->target_ip.is_v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0);
    if (up >= 0) {
        /* The relay thread is allowed to block; keep the proxychains hooks from
         * turning this internal connect into another async relay. */
        lcproxy_socket_set_bypass(1);
        int rc = connect_proxy_chain(
            up, job->target_ip, htons(job->target_port),
            proxychains_pd, proxychains_proxy_count, proxychains_ct,
            proxychains_max_chain);
        lcproxy_socket_set_bypass(0);

        if (rc == SUCCESS) {
            pump_bidirectional(up, job->peer_fd);
        }
    }

    if (up >= 0) close(up);
    close(job->peer_fd);
    free(job);
    return NULL;
}

/* Create a loopback TCP pair:
 *   - the app's existing `sock` is connected to a local listener;
 *   - the accepted side is returned as the relay peer fd.
 *
 * This keeps the app-facing descriptor a real TCP socket, so Dart/Flutter
 * socket options, getsockname/getpeername and TLS stacks behave like a normal
 * Internet socket instead of seeing an AF_UNIX socketpair.
 */
static int make_local_tcp_pair(int sock, int v6, int orig_flags, int *peer_fd) {
    int listen_fd = -1;
    int accepted = -1;
    struct sockaddr_storage ss;
    socklen_t slen = sizeof(ss);
    memset(&ss, 0, sizeof(ss));

    listen_fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) return -1;

    if (v6) {
        struct sockaddr_in6 *a6 = (struct sockaddr_in6 *)&ss;
        a6->sin6_family = AF_INET6;
        a6->sin6_addr = in6addr_loopback;
        a6->sin6_port = 0;
    } else {
        struct sockaddr_in *a4 = (struct sockaddr_in *)&ss;
        a4->sin_family = AF_INET;
        a4->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        a4->sin_port = 0;
    }

    if (bind(listen_fd, (struct sockaddr *)&ss, slen) != 0 ||
        listen(listen_fd, 1) != 0) {
        close(listen_fd);
        return -1;
    }

    slen = sizeof(ss);
    if (getsockname(listen_fd, (struct sockaddr *)&ss, &slen) != 0) {
        close(listen_fd);
        return -1;
    }

    /* Temporarily make the app socket blocking only for the local loopback
     * connect; this is a local operation and should complete immediately. */
    int save_flags = fcntl(sock, F_GETFL, 0);
    if (save_flags < 0) {
        close(listen_fd);
        return -1;
    }
    fcntl(sock, F_SETFL, save_flags & ~O_NONBLOCK);
    int rc = true_connect(sock, (struct sockaddr *)&ss, slen);
    fcntl(sock, F_SETFL, orig_flags >= 0 ? orig_flags : save_flags);
    if (rc != 0) {
        close(listen_fd);
        return -1;
    }

    accepted = accept(listen_fd, NULL, NULL);
    close(listen_fd);
    if (accepted < 0) return -1;

    *peer_fd = accepted;
    return 0;
}

int lcproxy_async_connect_start(int sock, ip_type target_ip,
                                unsigned short target_port, int orig_flags) {
    int peer_fd = -1;
    if (make_local_tcp_pair(sock, target_ip.is_v6, orig_flags, &peer_fd) != 0) {
        return -1;
    }

    async_connect_job *job = calloc(1, sizeof(*job));
    if (!job) {
        close(peer_fd);
        return -1;
    }

    job->peer_fd = peer_fd;
    job->target_ip = target_ip;
    job->target_port = target_port;

    pthread_t thread;
    if (pthread_create(&thread, NULL, relay_worker, job) != 0) {
        free(job);
        close(peer_fd);
        return -1;
    }
    pthread_detach(thread);

    /* The caller's fd is now a connected loopback TCP socket. Return
     * EINPROGRESS so Dart/Flutter wait for POLLOUT just like a normal
     * non-blocking connect. */
    return 0;
}
