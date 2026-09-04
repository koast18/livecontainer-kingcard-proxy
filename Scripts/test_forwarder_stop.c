//
//  test_forwarder_stop.c
//  宿主侧转发器回归测试（Linux/macOS 均可编译运行）。
//
//  复现真机故障 1：App 退后台/熄屏一段时间后回前台，整个 App 无网，
//  只能划掉后台重进。
//  根因链：
//    a) HTTP body 流式转发线程在收到 200 响应头后阻塞在上游 recv 上；
//       挂起期间上游连接已半开（NAT/无线状态丢失），对端永不回包也永不 FIN；
//    b) kp_forwarder_stop 只 shutdown 客户端 fd，阻塞在上游 recv 的线程
//       无法被唤醒，stop 的无限 cond_wait 永远等不到 active_clients 归零；
//    c) stop 持有转发器生命周期锁 → 前台恢复/网络恢复全部卡死，
//       转发器无法重建 → 所有连接指向已关闭的旧端口 → ECONNREFUSED。
//
//  本测试构造“上游先回 200 响应头、之后永久静默”的半开连接，断言：
//    1) 阻塞中的转发线程能被 kp_forwarder_stop 在有限时间内唤醒并退出；
//    2) stop 返回 0（无僵尸线程），free 不挂起；
//    3) 空闲转发器的 stop 立即返回。
//  旧实现会永久挂起本测试进程（CI 以超时判失败）。
//

#include "KPKIngCore.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static int test_failed = 0;

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

// ---- 测试替身：KPKIngCore 依赖的宿主符号 ----

// KPKCrypto（CommonCrypto）在宿主测试中不可链接；Q-Key 计算与停止语义无关。
int kpk_build_qkey_header(const char *guid, const char *domain, const char *url,
                          const char *request_id, const char *qkey,
                          char *out, size_t out_cap) {
    (void)guid; (void)domain; (void)url; (void)request_id; (void)qkey;
    if (!out || out_cap < 8) return -1;
    snprintf(out, out_cap, "stubqkey");
    return 0;
}

static int g_refresh_hook_calls = 0;
static int stub_refresh_hook(void *ctx) {
    (void)ctx;
    g_refresh_hook_calls++;
    return -1;  // 取号失败，避免测试依赖外网
}

// ---- 静默上游：accept → 读请求 → 回 200 响应头 → 永久静默 ----

typedef struct {
    int listen_fd;
    int port;
    int conn_fd;
} silent_upstream;

static void *silent_upstream_thread(void *arg) {
    silent_upstream *su = arg;
    int c = accept(su->listen_fd, NULL, NULL);
    if (c < 0) return NULL;
    su->conn_fd = c;
    char buf[2048];
    // 读完请求头（转发器一次性发完整请求）
    ssize_t r = recv(c, buf, sizeof(buf) - 1, 0);
    (void)r;
    static const char resp[] =
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 1000000\r\n"
        "\r\n";
    ssize_t w = send(c, resp, strlen(resp), 0);
    (void)w;
    // 永久静默：不 close、不再发送 —— 模拟挂起后对端消失的半开连接
    for (;;) {
        struct timespec ts = {60, 0};
        nanosleep(&ts, NULL);
    }
    return NULL;
}

static int silent_upstream_start(silent_upstream *su) {
    su->conn_fd = -1;
    su->listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (su->listen_fd < 0) return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(su->listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(su->listen_fd, 4) != 0) {
        close(su->listen_fd);
        return -1;
    }
    struct sockaddr_in bound;
    socklen_t blen = sizeof(bound);
    getsockname(su->listen_fd, (struct sockaddr *)&bound, &blen);
    su->port = ntohs(bound.sin_port);

    pthread_t t;
    if (pthread_create(&t, NULL, silent_upstream_thread, su) != 0) {
        close(su->listen_fd);
        return -1;
    }
    pthread_detach(t);
    return 0;
}

static int connect_local(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((unsigned short)port);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int wait_for_upstream_conn(silent_upstream *su, double timeout_sec) {
    double deadline = now_sec() + timeout_sec;
    while (now_sec() < deadline) {
        if (su->conn_fd >= 0) return 0;
        usleep(20 * 1000);
    }
    return -1;
}

static kp_forwarder *forwarder_with_silent_upstream(silent_upstream *su) {
    kp_forwarder *fw = kp_forwarder_new("127.0.0.1", 0, "", 0);
    if (!fw) return NULL;
    kp_forwarder_set_refresh_hook(fw, stub_refresh_hook, NULL);

    char proxy_addr[64];
    snprintf(proxy_addr, sizeof(proxy_addr), "127.0.0.1:%d", su->port);
    const char *http_pool[] = { proxy_addr };
    const char *https_pool[] = { proxy_addr };
    kp_forwarder_set_king_state(fw,
                                "0123456789ABCDEF0123456789ABCDEF",
                                "QUA2_V3_stub",
                                "stubtoken0123456789stubtoken0123456789",
                                "stubqkey012345678",
                                "httpcom",
                                http_pool, 1,
                                https_pool, 1);
    if (kp_forwarder_start(fw) != 0) {
        kp_forwarder_free(fw);
        return NULL;
    }
    return fw;
}

// 核心场景：转发线程阻塞在半开上游 → stop 必须在有限时间内干净返回。
static void test_stop_wakes_blocked_relay(void) {
    printf("start test: stop wakes relay blocked on half-open upstream\n");
    silent_upstream su;
    if (silent_upstream_start(&su) != 0) {
        printf("FAIL: cannot start silent upstream\n");
        test_failed = 1;
        return;
    }

    kp_forwarder *fw = forwarder_with_silent_upstream(&su);
    if (!fw) {
        printf("FAIL: cannot start forwarder\n");
        test_failed = 1;
        return;
    }
    int port = kp_forwarder_port(fw);

    int client = connect_local(port);
    if (client < 0) {
        printf("FAIL: cannot connect to forwarder port %d\n", port);
        test_failed = 1;
        kp_forwarder_free(fw);
        return;
    }
    static const char req[] =
        "GET http://example.com/path HTTP/1.1\r\n"
        "Host: example.com\r\n"
        "\r\n";
    if (send(client, req, strlen(req), 0) <= 0) {
        printf("FAIL: cannot send request\n");
        test_failed = 1;
        close(client);
        kp_forwarder_free(fw);
        return;
    }

    // 等转发线程连上静默上游（未连上就 stop 的话测不到阻塞路径）
    if (wait_for_upstream_conn(&su, 5.0) != 0) {
        printf("FAIL: forwarder never connected to silent upstream\n");
        test_failed = 1;
        close(client);
        kp_forwarder_free(fw);
        return;
    }
    // 再等一小会儿，确保转发线程已收到 200 响应头并进入流式转发
    usleep(300 * 1000);

    double t0 = now_sec();
    int rc = kp_forwarder_stop(fw);
    double dt = now_sec() - t0;
    close(client);

    if (rc != 0) {
        printf("FAIL: kp_forwarder_stop returned %d (client threads stuck: "
               "upstream shutdown did not wake the blocked relay)\n", rc);
        test_failed = 1;
    } else if (dt > 5.0) {
        printf("FAIL: kp_forwarder_stop took %.2fs (expected immediate wake-up)\n", dt);
        test_failed = 1;
    } else {
        printf("blocked relay stopped cleanly in %.0fms OK\n", dt * 1000.0);
    }

    kp_forwarder_free(fw);
}

// 空闲转发器：stop 必须立即返回 0。
static void test_stop_idle_forwarder(void) {
    printf("start test: stop idle forwarder\n");
    kp_forwarder *fw = kp_forwarder_new("127.0.0.1", 0, "", 0);
    if (!fw || kp_forwarder_start(fw) != 0) {
        printf("FAIL: cannot start idle forwarder\n");
        test_failed = 1;
        return;
    }
    double t0 = now_sec();
    int rc = kp_forwarder_stop(fw);
    double dt = now_sec() - t0;
    if (rc != 0 || dt > 1.0) {
        printf("FAIL: idle stop rc=%d dt=%.2fs\n", rc, dt);
        test_failed = 1;
    } else {
        printf("idle forwarder stopped in %.0fms OK\n", dt * 1000.0);
    }
    kp_forwarder_free(fw);
}

int main(void) {
    kp_set_debug_logger(NULL);
    test_stop_idle_forwarder();
    test_stop_wakes_blocked_relay();
    if (test_failed) {
        printf("forwarder stop tests FAILED\n");
        return 1;
    }
    printf("all forwarder stop tests passed\n");
    return 0;
}
