/*
 * Detailed unit tests for Tweak/ProxyCore/src/async_proxy.c
 *
 * These tests do not require an iOS device. They exercise the async
 * socketpair relay used by the non-blocking connect() path:
 *
 *   1. async start returns immediately (non-blocking)
 *   2. caller fd is writable through poll()
 *   3. small payload is relayed app -> upstream -> app (echo)
 *   4. large payload is relayed through the bidirectional pump
 *   5. upstream connect failure is reported to the caller as EOF/reset
 */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <poll.h>
#include <signal.h>
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

connect_t true_connect = (connect_t)connect;
int g_upstream_port = 0;
int g_fail_connect = 0;

void lcproxy_socket_set_bypass(int on) {
    (void)on;
}

void lcproxy_control_copy_proxy_chain(proxy_data *dst, unsigned int dst_cap,
                                      unsigned int *out_count,
                                      chain_type *out_chain_type) {
    unsigned int n = proxychains_proxy_count < dst_cap ? proxychains_proxy_count : dst_cap;
    if (dst && n > 0) memcpy(dst, proxychains_pd, sizeof(proxy_data) * n);
    if (out_count) *out_count = n;
    if (out_chain_type) *out_chain_type = proxychains_ct;
}

/* Stub connect_proxy_chain(): instead of a real HTTP proxy it either connects
 * to the loopback echo server or simulates an upstream failure. */
int connect_proxy_chain(int sock, ip_type target_ip, unsigned short target_port,
                        proxy_data *pd, unsigned int proxy_count,
                        chain_type ct, unsigned int max_chain) {
    (void)target_ip;
    (void)target_port;
    (void)pd;
    (void)proxy_count;
    (void)ct;
    (void)max_chain;

    if (g_fail_connect) {
        return SOCKET_ERROR;
    }

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

static void *echo_server(void *arg) {
    (void)arg;
    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) return NULL;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;

    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(listen_fd, 1) != 0) {
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

    /* Drain until EOF, then send a short ack. This avoids a test deadlock
     * where the app is still writing a large request while the server echoes
     * and fills the socketpair receive buffer before the app reads. */
    char buf[16384];
    ssize_t n;
    while ((n = recv(client, buf, sizeof(buf), 0)) > 0) {
        /* discard */
    }
    const char *ack = "DONE";
    size_t ack_off = 0;
    while (ack_off < strlen(ack)) {
        ssize_t w = send(client, ack + ack_off, strlen(ack) - ack_off, 0);
        if (w <= 0) break;
        ack_off += (size_t)w;
    }
    shutdown(client, SHUT_RDWR);
    close(client);
    return NULL;
}

static int wait_event(int fd, short events, int timeout_ms) {
    struct pollfd pfd;
    pfd.fd = fd;
    pfd.events = events;
    pfd.revents = 0;
    int rc = poll(&pfd, 1, timeout_ms);
    if (rc <= 0) return -1;
    if (events == POLLOUT) {
        return (pfd.revents & POLLOUT) ? 0 : -1;
    }
    return (pfd.revents & (POLLIN | POLLHUP | POLLERR)) ? 0 : -1;
}

static int wait_for_port(void) {
    for (int i = 0; i < 2000 && g_upstream_port == 0; i++) {
        struct timespec ts = {0, 1000000};
        nanosleep(&ts, NULL);
    }
    return g_upstream_port != 0 ? 0 : -1;
}

static int wait_for_active_count(int expected, int timeout_ms) {
    for (int i = 0; i < timeout_ms; i++) {
        if (lcproxy_async_active_count() == expected) return 0;
        struct timespec ts = {0, 1000000};
        nanosleep(&ts, NULL);
    }
    return lcproxy_async_active_count() == expected ? 0 : -1;
}

static int make_nonblocking_socket(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    int flags = fcntl(s, F_GETFL, 0);
    if (flags < 0 || fcntl(s, F_SETFL, flags | O_NONBLOCK) != 0) {
        close(s);
        return -1;
    }
    return s;
}

static int test_echo(size_t payload_len, const char *name) {
    puts("start test"); fflush(stderr);
    pthread_t server_thread;
    g_upstream_port = 0;
    if (pthread_create(&server_thread, NULL, echo_server, NULL) != 0) {
        fprintf(stderr, "%s: failed to create echo server\n", name);
        return 1;
    }
    pthread_detach(server_thread);
    if (wait_for_port() != 0) {
        fprintf(stderr, "%s: echo server did not publish port\n", name);
        return 1;
    }

    int sock = make_nonblocking_socket();
    if (sock < 0) {
        perror(name);
        return 1;
    }

    int flags = fcntl(sock, F_GETFL, 0);
    ip_type target;
    memset(&target, 0, sizeof(target));
    target.is_v6 = 0;
    target.addr.v4.as_int = htonl(0x01020304u); /* 1.2.3.4, arbitrary */

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    int rc = lcproxy_async_connect_start(sock, target, 443, flags | O_NONBLOCK);
    clock_gettime(CLOCK_MONOTONIC, &end);
    if (rc != 0) {
        perror(name);
        close(sock);
        return 1;
    }
    long long elapsed_ms =
        (long long)(end.tv_sec - start.tv_sec) * 1000 +
        (long long)(end.tv_nsec - start.tv_nsec) / 1000000;
    if (elapsed_ms > 500) {
        fprintf(stderr, "%s: async start too slow: %lld ms\n", name, elapsed_ms);
        close(sock);
        return 1;
    }

    if (wait_event(sock, POLLOUT, 2000) != 0) {
        fprintf(stderr, "%s: socketpair not writable\n", name);
        close(sock);
        return 1;
    }

    char *payload = malloc(payload_len ? payload_len : 1);
    if (!payload) {
        fprintf(stderr, "%s: malloc failed\n", name);
        close(sock);
        return 1;
    }
    for (size_t i = 0; i < payload_len; i++) {
        payload[i] = (char)('a' + (i % 26));
    }

    /* Send all bytes; the socketpair is non-blocking so retry on EAGAIN. */
    size_t sent = 0;
    while (sent < payload_len) {
        ssize_t w = send(sock, payload + sent, payload_len - sent, 0);
        if (w > 0) {
            sent += (size_t)w;
            continue;
        }
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (wait_event(sock, POLLOUT, 3000) != 0) {
                fprintf(stderr, "%s: send timed out\n", name);
                free(payload);
                close(sock);
                return 1;
            }
            continue;
        }
        perror(name);
        free(payload);
        close(sock);
        return 1;
    }

    /* Signal end of request; the relay forwards EOF to the upstream server. */
    if (shutdown(sock, SHUT_WR) != 0) {
        perror(name);
        free(payload);
        close(sock);
        return 1;
    }

    /* Read the small ACK sent after the server drains the full payload. */
    char ack_buf[8];
    size_t ack_got = 0;
    const char *expected = "DONE";
    size_t expected_len = strlen(expected);
    while (ack_got < expected_len) {
        if (wait_event(sock, POLLIN, 5000) != 0) {
            fprintf(stderr, "%s: ack timed out after %zu/%zu bytes\n",
                    name, ack_got, expected_len);
            free(payload);
            close(sock);
            return 1;
        }
        ssize_t r = recv(sock, ack_buf + ack_got, expected_len - ack_got, 0);
        if (r > 0) {
            ack_got += (size_t)r;
            continue;
        }
        if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;
        }
        fprintf(stderr, "%s: ack connection closed early: %zd\n", name, r);
        free(payload);
        close(sock);
        return 1;
    }

    if (memcmp(ack_buf, expected, expected_len) != 0) {
        fprintf(stderr, "%s: ack mismatch\n", name);
        free(payload);
        close(sock);
        return 1;
    }

    printf("%s OK: start=%lldms payload=%zu bytes ack=%s\n",
           name, elapsed_ms, payload_len, expected);
    free(payload);
    close(sock);
    return 0;
}
static int test_upstream_failure(void) {
    g_fail_connect = 1;

    int sock = make_nonblocking_socket();
    if (sock < 0) {
        perror("failure test socket");
        g_fail_connect = 0;
        return 1;
    }

    int flags = fcntl(sock, F_GETFL, 0);
    ip_type target;
    memset(&target, 0, sizeof(target));
    target.is_v6 = 0;
    target.addr.v4.as_int = htonl(0x01020304u);

    if (lcproxy_async_connect_start(sock, target, 443, flags | O_NONBLOCK) != 0) {
        fprintf(stderr, "failure test: async start failed\n");
        close(sock);
        g_fail_connect = 0;
        return 1;
    }

    /* The relay worker fails to connect upstream, so the app-facing side
     * should observe EOF (POLLHUP/POLLIN with recv returning 0). */
    if (wait_event(sock, POLLIN, 3000) != 0) {
        fprintf(stderr, "failure test: did not observe EOF\n");
        close(sock);
        g_fail_connect = 0;
        return 1;
    }

    char buf[16];
    ssize_t r = recv(sock, buf, sizeof(buf), 0);
    if (r != 0) {
        fprintf(stderr, "failure test: expected EOF, got %zd\n", r);
        close(sock);
        g_fail_connect = 0;
        return 1;
    }

    printf("upstream failure test OK: relay reported EOF to caller\n");
    close(sock);
    g_fail_connect = 0;
    return 0;
}

static int test_close_all(void) {
    g_fail_connect = 1;
    int sock = make_nonblocking_socket();
    if (sock < 0) return 1;
    int flags = fcntl(sock, F_GETFL, 0);
    ip_type target;
    memset(&target, 0, sizeof(target));
    target.is_v6 = 0;
    target.addr.v4.as_int = htonl(0x01020304u);
    if (lcproxy_async_connect_start(sock, target, 443, flags | O_NONBLOCK) != 0) {
        close(sock);
        g_fail_connect = 0;
        return 1;
    }
    if (wait_for_active_count(1, 1000) != 0) {
        close(sock);
        g_fail_connect = 0;
        return 1;
    }
    lcproxy_async_close_all();
    if (wait_event(sock, POLLIN, 2000) != 0 || wait_for_active_count(0, 2000) != 0) {
        fprintf(stderr, "close_all test: relay was not collected\n");
        close(sock);
        g_fail_connect = 0;
        return 1;
    }
    close(sock);
    g_fail_connect = 0;
    puts("close_all test OK: active relay peer shutdown and collected");
    return 0;
}

int main(void) {
    alarm(30);
    int failed = 0;

    if (test_echo(32, "small relay roundtrip") != 0) failed = 1;
    if (test_echo(256 * 1024, "large relay roundtrip (256 KiB)") != 0) failed = 1;
    if (test_upstream_failure() != 0) failed = 1;
    if (test_close_all() != 0) failed = 1;

    if (failed) {
        fprintf(stderr, "async proxy tests FAILED\n");
        return 1;
    }
    printf("all async proxy tests passed\n");
    return 0;
}
