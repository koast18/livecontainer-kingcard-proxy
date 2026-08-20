#include "async_proxy.h"

#include <errno.h>
#include <fcntl.h>
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
    int peer_fd;               /* socketpair peer used by the relay thread */
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

int lcproxy_async_connect_start(int sock, ip_type target_ip,
                                unsigned short target_port, int orig_flags) {
    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) {
        return -1;
    }

    /* Preserve the caller's non-blocking mode on the app-facing side. */
    if (orig_flags != 0) {
        fcntl(fds[0], F_SETFL, orig_flags);
    }

    async_connect_job *job = calloc(1, sizeof(*job));
    if (!job) {
        close(fds[0]);
        close(fds[1]);
        return -1;
    }

    job->peer_fd = fds[1];
    job->target_ip = target_ip;
    job->target_port = target_port;

    pthread_t thread;
    if (pthread_create(&thread, NULL, relay_worker, job) != 0) {
        free(job);
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    pthread_detach(thread);

    /* Replace the caller's fd before returning, so any subsequent
     * poll/select/kqueue registration sees the connected socketpair. */
    if (dup2(fds[0], sock) < 0) {
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    close(fds[0]);
    return 0;
}