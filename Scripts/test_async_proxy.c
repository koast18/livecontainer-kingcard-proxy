/*
 * Unit test for Tweak/ProxyCore/src/async_proxy.c
 *
 * It does not require an iOS device. It verifies the async socketpair relay:
 *  - lcproxy_async_connect_start() returns immediately even in non-blocking mode
 *  - the caller's fd is usable with poll()
 *  - data written by the "app" is relayed through the background proxy
 *    connection and echoed back.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "../Tweak/ProxyCore/src/async_proxy.h"
#include "../Tweak/ProxyCore/vendor/proxychains-ng/src/core.h"

/* ---- globals expected by async_proxy.c ---- */
proxy_data proxychains_pd[512];
unsigned int proxychains_proxy_count = 1;
chain_type proxychains_ct = STRICT_TYPE;
unsigned int proxychains_max_chain = 1;

void lcproxy_socket_set_bypass(int on) {
    (void)on;
}

/* Stub connect_proxy_chain(): instead of a real HTTP proxy it connects to the
 * loopback "upstream" server used by this test. This is enough to exercise the
 * async relay state machine. */
int connect_proxy_chain(int sock, ip_type target_ip, unsigned short target_port,
                        proxy_data *pd, unsigned int proxy_count,
                        chain_type ct, unsigned int max_chain) {
    (void)target_ip;
    (void)target_port;
    (void)pd;
    (void)proxy_count;
    (void)ct;
    (void)max_chain;

    extern int g_upstream_port;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)g_upstream_port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        return SOCKET_ERROR;
    }
    return SUCCESS;
}

int g_upstream_port;

static void *upstream_server(void *arg) {
    (void)arg;
    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) return NULL;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;

    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(listen_fd);
        return NULL;
    }
    if (listen(listen_fd, 1) != 0) {
        close(listen_fd);
        return NULL;
    }

    socklen_t alen = sizeof(addr);
    if (getsockname(listen_fd, (struct sockaddr *)&addr, &alen) != 0) {
        close(listen_fd);
        return NULL;
    }
    g_upstream_port = ntohs(addr.sin_port);

    int client = accept(listen_fd, NULL, NULL);
    close(listen_fd);
    if (client < 0) return NULL;

    /* Echo one message back. */
    char buf[1024];
    ssize_t n = recv(client, buf, sizeof(buf), 0);
    if (n > 0) {
        send(client, buf, (size_t)n, 0);
    }
    shutdown(client, SHUT_RDWR);
    close(client);
    return NULL;
}

static int wait_writable(int fd, int timeout_ms) {
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = POLLOUT;
    pfd.revents = 0;
    int rc = poll(&pfd, 1, timeout_ms);
    return rc > 0 && (pfd.revents & (POLLOUT | POLLERR | POLLHUP)) ? 0 : -1;
}

static int wait_readable(int fd, int timeout_ms) {
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    int rc = poll(&pfd, 1, timeout_ms);
    return rc > 0 && (pfd.revents & (POLLIN | POLLERR | POLLHUP)) ? 0 : -1;
}

int main(void) {
    pthread_t server_thread;
    if (pthread_create(&server_thread, NULL, upstream_server, NULL) != 0) {
        fprintf(stderr, "failed to create upstream server\n");
        return 1;
    }

    /* Wait until the server has published its port. */
    while (g_upstream_port == 0) {
        struct timespec ts = {0, 1000000};
        nanosleep(&ts, NULL);
    }

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        perror("socket");
        return 1;
    }

    int flags = fcntl(sock, F_GETFL, 0);
    if (fcntl(sock, F_SETFL, flags | O_NONBLOCK) != 0) {
        perror("fcntl O_NONBLOCK");
        return 1;
    }

    ip_type target;
    memset(&target, 0, sizeof(target));
    target.is_v6 = 0;
    target.addr.v4.as_int = htonl(0x01020304u); /* 1.2.3.4, arbitrary */

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    int rc = lcproxy_async_connect_start(sock, target, 443, flags | O_NONBLOCK);
    clock_gettime(CLOCK_MONOTONIC, &end);

    if (rc != 0) {
        fprintf(stderr, "lcproxy_async_connect_start failed: %d\n", rc);
        return 1;
    }

    long long elapsed_ms =
        (long long)(end.tv_sec - start.tv_sec) * 1000 +
        (long long)(end.tv_nsec - start.tv_nsec) / 1000000;

    if (elapsed_ms > 500) {
        fprintf(stderr, "async start took too long: %lld ms\n", elapsed_ms);
        return 1;
    }
    printf("async start returned in %lld ms\n", elapsed_ms);

    if (wait_writable(sock, 2000) != 0) {
        fprintf(stderr, "socketpair is not writable\n");
        return 1;
    }

    const char *msg = "hello-async-proxy";
    ssize_t w = send(sock, msg, strlen(msg), 0);
    if (w != (ssize_t)strlen(msg)) {
        perror("send");
        return 1;
    }

    if (wait_readable(sock, 3000) != 0) {
        fprintf(stderr, "no echo received\n");
        return 1;
    }

    char buf[1024];
    ssize_t r = recv(sock, buf, sizeof(buf) - 1, 0);
    if (r <= 0) {
        perror("recv");
        return 1;
    }
    buf[r] = '\0';

    if (strcmp(buf, msg) != 0) {
        fprintf(stderr, "echo mismatch: got '%s'\n", buf);
        return 1;
    }

    printf("echo OK: %s\n", buf);
    close(sock);
    pthread_join(server_thread, NULL);
    return 0;
}
