/***************************************************************************
                          libproxychains.c  -  description
                             -------------------
    begin                : Tue May 14 2002
    copyright          :  netcreature (C) 2002
    email                 : netcreature@users.sourceforge.net
 ***************************************************************************/
 /*     GPL */
/***************************************************************************
 *                                                                         *
 *   This program is free software; you can redistribute it and/or modify  *
 *   it under the terms of the GNU General Public License as published by  *
 *   the Free Software Foundation; either version 2 of the License, or     *
 *   (at your option) any later version.                                   *
 *                                                                         *
 ***************************************************************************/

#undef _GNU_SOURCE
#define _GNU_SOURCE

#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <ctype.h>
#include <errno.h>
#include <assert.h>
#include <netdb.h>

#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <pthread.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <stdint.h>
#include <time.h>
#include <stdarg.h>


#include "core.h"
#include "common.h"
#include "rdns.h"
#include "fishhook.h"
#include "async_proxy.h"
#include "proxy_override.h"

#undef 		satosin
#define     satosin(x)      ((struct sockaddr_in *) &(x))
#define     SOCKADDR(x)     (satosin(x)->sin_addr.s_addr)
#define     SOCKADDR_2(x)     (satosin(x)->sin_addr)
#define     SOCKPORT(x)     (satosin(x)->sin_port)
#define     SOCKFAMILY(x)     (satosin(x)->sin_family)
#define     MAX_CHAIN 512
#define     LC_CONNECT_CHAIN_SNAPSHOT_MAX MAX_CHAIN

#ifdef IS_SOLARIS
#undef connect
int __xnet_connect(int sock, const struct sockaddr *addr, unsigned int len);
connect_t true___xnet_connect;
#endif

close_t true_close;
close_range_t true_close_range;
connect_t true_connect;
connectx_t true_connectx;
typedef int (*dup_t)(int);
typedef int (*dup2_t)(int, int);
typedef int (*fcntl_t)(int, int, ...);
dup_t true_dup;
dup2_t true_dup2;
fcntl_t true_fcntl;
#if defined(__linux__)
typedef int (*dup3_t)(int, int, int);
dup3_t true_dup3;
#endif
gethostbyname_t true_gethostbyname;
getaddrinfo_t true_getaddrinfo;
freeaddrinfo_t true_freeaddrinfo;
getnameinfo_t true_getnameinfo;
gethostbyaddr_t true_gethostbyaddr;
sendto_t true_sendto;
sendmsg_t true_sendmsg;
typedef ssize_t (*send_t)(int, const void *, size_t, int);
typedef ssize_t (*recv_t)(int, void *, size_t, int);
typedef ssize_t (*recvfrom_t)(int, void *, size_t, int, struct sockaddr *, socklen_t *);
typedef ssize_t (*recvmsg_t)(int, struct msghdr *, int);
typedef ssize_t (*read_t)(int, void *, size_t);
typedef ssize_t (*write_t)(int, const void *, size_t);
send_t true_send;
recv_t true_recv;
recvfrom_t true_recvfrom;
recvmsg_t true_recvmsg;
read_t true_read;
write_t true_write;

int tcp_read_time_out;
int tcp_connect_time_out;
chain_type proxychains_ct;
proxy_data proxychains_pd[MAX_CHAIN];
unsigned int proxychains_proxy_count = 0;
unsigned int proxychains_proxy_offset = 0;
int proxychains_got_chain_data = 0;
unsigned int proxychains_max_chain = 1;
int proxychains_quiet_mode = 0;
int proxychains_block_non_tcp = 0;
enum dns_lookup_flavor proxychains_resolver = DNSLF_LIBC;
localaddr_arg localnet_addr[MAX_LOCALNET];
size_t num_localnet_addr = 0;
dnat_arg dnats[MAX_DNAT];
size_t num_dnats = 0;
unsigned int remote_dns_subnet = 224;

pthread_once_t init_once = PTHREAD_ONCE_INIT;

static int init_l = 0;

/* ---- LCProxy control & traffic stats (added on top of proxychains) ---- */
#define LC_STATS_BUCKET_SECONDS 600
#define LC_STATS_MAX_BUCKETS 2016

typedef struct {
    int64_t start;
    uint64_t upload;
    uint64_t download;
} lc_traffic_bucket;

static int lc_proxy_disabled = 0;
/* No managed config at process start is never permission for a direct leak. */
static int lc_proxy_config_valid = 0;
static pthread_mutex_t lc_proxy_chain_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t lc_stats_lock = PTHREAD_MUTEX_INITIALIZER;
static lc_traffic_bucket lc_buckets[LC_STATS_MAX_BUCKETS];
static int lc_bucket_count = 0;
static int64_t lc_current_start = 0;
static uint64_t lc_current_upload = 0;
static uint64_t lc_current_download = 0;
static int lc_cellular_cache = -1;
static time_t lc_cellular_checked = 0;
static int lc_network_known = 0;
static int lc_network_non_cellular = 0;

static pthread_key_t lc_bypass_key;
static pthread_once_t lc_bypass_once = PTHREAD_ONCE_INIT;

static void lc_bypass_destroy(void *v) { (void)v; }
static void lc_bypass_init(void) {
    pthread_key_create(&lc_bypass_key, lc_bypass_destroy);
}
static void lc_bypass_set(int v) {
    pthread_once(&lc_bypass_once, lc_bypass_init);
    pthread_setspecific(lc_bypass_key, (void *)(intptr_t)v);
}
static int lc_bypass_get(void) {
    pthread_once(&lc_bypass_once, lc_bypass_init);
    return (int)(intptr_t)pthread_getspecific(lc_bypass_key);
}

void lcproxy_socket_set_bypass(int on) {
    lc_bypass_set(on);
}

static int64_t lc_now_bucket_start(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    int64_t sec = (int64_t)ts.tv_sec;
    return sec - (sec % LC_STATS_BUCKET_SECONDS);
}

static void lc_stats_rotate_locked(int64_t now_bucket) {
    if (lc_current_start == 0) {
        lc_current_start = now_bucket;
        return;
    }
    if (lc_current_start == now_bucket)
        return;
    // 先原子取走当前计数，再切桶。并发 add 直接原子累加，不经过这里。
    uint64_t up = __atomic_exchange_n(&lc_current_upload, 0, __ATOMIC_RELAXED);
    uint64_t down = __atomic_exchange_n(&lc_current_download, 0, __ATOMIC_RELAXED);
    if (lc_bucket_count < LC_STATS_MAX_BUCKETS) {
        lc_buckets[lc_bucket_count].start = lc_current_start;
        lc_buckets[lc_bucket_count].upload = up;
        lc_buckets[lc_bucket_count].download = down;
        lc_bucket_count++;
    } else {
        memmove(&lc_buckets[0], &lc_buckets[1], sizeof(lc_buckets[0]) * (LC_STATS_MAX_BUCKETS - 1));
        lc_buckets[LC_STATS_MAX_BUCKETS - 1].start = lc_current_start;
        lc_buckets[LC_STATS_MAX_BUCKETS - 1].upload = up;
        lc_buckets[LC_STATS_MAX_BUCKETS - 1].download = down;
    }
    lc_current_start = now_bucket;
}

static void lc_direct_track_close_all(void);
static void lc_direct_track_remove(int fd);
static void lc_direct_track_remove_range(unsigned first, unsigned last);
static void lc_direct_track_add_if_remote(int sock, const struct sockaddr *addr, socklen_t addrlen);
static void lc_direct_track_copy(int source, int duplicate);
static int lc_direct_track_contains(int fd);

typedef struct {
    proxy_data chain[MAX_CHAIN];
    unsigned int chain_count;
    unsigned int max_chain;
    chain_type chain_type;
    localaddr_arg localnet[MAX_LOCALNET];
    size_t localnet_count;
    dnat_arg dnat[MAX_DNAT];
    size_t dnat_count;
    unsigned int remote_dns_subnet;
    enum dns_lookup_flavor resolver;
    int config_valid;
} lc_proxy_config_snapshot;

static pthread_mutex_t lc_direct_admission_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t lc_direct_admission_cond = PTHREAD_COND_INITIALIZER;
static int lc_direct_admissions = 0;
static int lc_direct_admissions_blocked = 0;

static int lc_direct_admission_begin(void) {
    pthread_mutex_lock(&lc_direct_admission_lock);
    int admitted = __atomic_load_n(&lc_proxy_disabled, __ATOMIC_ACQUIRE) &&
                   !lc_direct_admissions_blocked;
    if (admitted) lc_direct_admissions++;
    pthread_mutex_unlock(&lc_direct_admission_lock);
    return admitted;
}

static void lc_direct_admission_end(void) {
    pthread_mutex_lock(&lc_direct_admission_lock);
    if (lc_direct_admissions > 0) lc_direct_admissions--;
    if (lc_direct_admissions == 0) pthread_cond_broadcast(&lc_direct_admission_cond);
    pthread_mutex_unlock(&lc_direct_admission_lock);
}

void lcproxy_control_set_enabled(int enabled) {
    int now_disabled = enabled ? 0 : 1;
    int was_disabled = __atomic_exchange_n(&lc_proxy_disabled, now_disabled, __ATOMIC_ACQ_REL);
    pthread_mutex_lock(&lc_direct_admission_lock);
    lc_direct_admissions_blocked = now_disabled ? 0 : 1;
    while (!now_disabled && lc_direct_admissions > 0)
        pthread_cond_wait(&lc_direct_admission_cond, &lc_direct_admission_lock);
    pthread_mutex_unlock(&lc_direct_admission_lock);
    if (was_disabled && !now_disabled) {
        // Leaving direct mode: kill sockets that were opened directly while on
        // Wi-Fi/auto-direct so they cannot keep leaking on cellular.
        lc_direct_track_close_all();
    }
}
int lcproxy_control_get_enabled(void) {
    return __atomic_load_n(&lc_proxy_disabled, __ATOMIC_ACQUIRE) ? 0 : 1;
}
void lcproxy_control_set_config_valid(int valid) {
    __atomic_store_n(&lc_proxy_config_valid, valid ? 1 : 0, __ATOMIC_RELEASE);
    if (!valid)
        lc_direct_track_close_all();
}
int lcproxy_control_get_config_valid(void) {
    return __atomic_load_n(&lc_proxy_config_valid, __ATOMIC_ACQUIRE);
}
void lcproxy_control_set_block_non_tcp(int enabled) {
    __atomic_store_n(&proxychains_block_non_tcp, enabled ? 1 : 0, __ATOMIC_RELEASE);
}
int lcproxy_control_get_block_non_tcp(void) {
    return __atomic_load_n(&proxychains_block_non_tcp, __ATOMIC_ACQUIRE);
}

int lcproxy_control_get_proxy_count(void) {
    pthread_mutex_lock(&lc_proxy_chain_lock);
    int count = (int)proxychains_proxy_count;
    pthread_mutex_unlock(&lc_proxy_chain_lock);
    return count;
}

static int lc_proxy_config_missing(void) {
	return !__atomic_load_n(&lc_proxy_disabled, __ATOMIC_ACQUIRE) &&
           (!lcproxy_control_get_config_valid() || !lcproxy_control_get_proxy_count());
}

void lcproxy_control_copy_proxy_chain(proxy_data *dst, unsigned int dst_cap,
                                      unsigned int *out_count,
                                      chain_type *out_chain_type,
                                      unsigned int *out_max_chain) {
    pthread_mutex_lock(&lc_proxy_chain_lock);
    unsigned int count = proxychains_proxy_count;
    if (count > dst_cap || (count > 0 && !dst)) count = 0;
    if (count > 0) {
        memcpy(dst, proxychains_pd, sizeof(proxy_data) * count);
    }
    if (out_count) *out_count = count;
    if (out_chain_type) *out_chain_type = proxychains_ct;
    if (out_max_chain) *out_max_chain = proxychains_max_chain;
    pthread_mutex_unlock(&lc_proxy_chain_lock);
}

static void lcproxy_control_copy_config_snapshot(lc_proxy_config_snapshot *snapshot) {
    if (!snapshot) return;
    memset(snapshot, 0, sizeof(*snapshot));
    pthread_mutex_lock(&lc_proxy_chain_lock);
    snapshot->chain_count = proxychains_proxy_count;
    if (snapshot->chain_count > MAX_CHAIN) snapshot->chain_count = 0;
    if (snapshot->chain_count > 0)
        memcpy(snapshot->chain, proxychains_pd, sizeof(proxy_data) * snapshot->chain_count);
    snapshot->max_chain = proxychains_max_chain ? proxychains_max_chain : 1;
    snapshot->chain_type = proxychains_ct;
    snapshot->localnet_count = num_localnet_addr <= MAX_LOCALNET ? num_localnet_addr : 0;
    if (snapshot->localnet_count > 0)
        memcpy(snapshot->localnet, localnet_addr,
               sizeof(localaddr_arg) * snapshot->localnet_count);
    snapshot->dnat_count = num_dnats <= MAX_DNAT ? num_dnats : 0;
    if (snapshot->dnat_count > 0)
        memcpy(snapshot->dnat, dnats, sizeof(dnat_arg) * snapshot->dnat_count);
    snapshot->remote_dns_subnet = remote_dns_subnet;
    snapshot->resolver = proxychains_resolver;
    snapshot->config_valid = __atomic_load_n(&lc_proxy_config_valid, __ATOMIC_ACQUIRE);
    pthread_mutex_unlock(&lc_proxy_chain_lock);
}

void lcproxy_control_copy_route_rules(localaddr_arg *localnet, size_t localnet_cap,
                                      size_t *out_localnet_count,
                                      dnat_arg *dnat, size_t dnat_cap,
                                      size_t *out_dnat_count,
                                      unsigned int *out_remote_dns_subnet) {
    pthread_mutex_lock(&lc_proxy_chain_lock);
    size_t localnet_count = num_localnet_addr <= localnet_cap ? num_localnet_addr : 0;
    size_t dnat_count = num_dnats <= dnat_cap ? num_dnats : 0;
    if (localnet_count > 0 && localnet) memcpy(localnet, localnet_addr, sizeof(localaddr_arg) * localnet_count);
    if (dnat_count > 0 && dnat) memcpy(dnat, dnats, sizeof(dnat_arg) * dnat_count);
    if (out_localnet_count) *out_localnet_count = localnet_count;
    if (out_dnat_count) *out_dnat_count = dnat_count;
    if (out_remote_dns_subnet) *out_remote_dns_subnet = remote_dns_subnet;
    pthread_mutex_unlock(&lc_proxy_chain_lock);
}

enum dns_lookup_flavor lcproxy_control_get_resolver(void) {
    pthread_mutex_lock(&lc_proxy_chain_lock);
    enum dns_lookup_flavor resolver = proxychains_resolver;
    pthread_mutex_unlock(&lc_proxy_chain_lock);
    return resolver;
}

int lcproxy_stats_is_cellular(void) {
    time_t now = time(NULL);
    if (now - lc_cellular_checked < 2 && lc_cellular_cache >= 0)
        return lc_cellular_cache;
    struct ifaddrs *ifa = NULL;
    int cellular = 0;
    int has_wifi = 0;
    if (getifaddrs(&ifa) == 0) {
        struct ifaddrs *p;
        for (p = ifa; p; p = p->ifa_next) {
            if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET)
                continue;
            if (!(p->ifa_flags & IFF_UP) || !(p->ifa_flags & IFF_RUNNING))
                continue;
            if (strncmp(p->ifa_name, "en", 2) == 0)
                has_wifi = 1;
            else if (strncmp(p->ifa_name, "pdp_ip", 6) == 0)
                cellular = 1;
        }
        freeifaddrs(ifa);
    }
    if (has_wifi)
        cellular = 0;
    lc_cellular_cache = cellular;
    lc_cellular_checked = now;
    return cellular;
}

void lcproxy_network_monitor_update(int known, int non_cellular) {
    lc_network_known = known ? 1 : 0;
    lc_network_non_cellular = non_cellular ? 1 : 0;
    if (known) {
        lc_cellular_cache = non_cellular ? 0 : 1;
        lc_cellular_checked = time(NULL);
    }
}

int lcproxy_network_should_direct(void) {
    return lc_network_known && lc_network_non_cellular;
}

// 热路径专用：只读取缓存，不在每个 read/write 上跑 getifaddrs。
// 缓存由 lcproxy_stats_is_cellular() 刷新（LCProxyStats 定时 flush 前会调用）。
static int lcproxy_stats_is_cellular_fast(void) {
    if (lc_cellular_cache < 0) return lcproxy_stats_is_cellular();
    return lc_cellular_cache == 1;
}

void lcproxy_stats_add_upload(uint64_t n) {
    if (!n) return;
    (void)__atomic_add_fetch(&lc_current_upload, n, __ATOMIC_RELAXED);
}
void lcproxy_stats_add_download(uint64_t n) {
    if (!n) return;
    (void)__atomic_add_fetch(&lc_current_download, n, __ATOMIC_RELAXED);
}

int lcproxy_stats_bucket_count(void) {
    pthread_mutex_lock(&lc_stats_lock);
    int n = lc_bucket_count;
    pthread_mutex_unlock(&lc_stats_lock);
    return n;
}
int lcproxy_stats_get_bucket(int i, int64_t *start, uint64_t *up, uint64_t *down) {
    pthread_mutex_lock(&lc_stats_lock);
    int ok = (i >= 0 && i < lc_bucket_count);
    if (ok) {
        *start = lc_buckets[i].start;
        *up = lc_buckets[i].upload;
        *down = lc_buckets[i].download;
    }
    pthread_mutex_unlock(&lc_stats_lock);
    return ok;
}
void lcproxy_stats_get_current(int64_t *start, uint64_t *up, uint64_t *down) {
    pthread_mutex_lock(&lc_stats_lock);
    lc_stats_rotate_locked(lc_now_bucket_start());
    *start = lc_current_start;
    *up = __atomic_load_n(&lc_current_upload, __ATOMIC_RELAXED);
    *down = __atomic_load_n(&lc_current_download, __ATOMIC_RELAXED);
    pthread_mutex_unlock(&lc_stats_lock);
}
uint64_t lcproxy_stats_total_upload(void) {
    pthread_mutex_lock(&lc_stats_lock);
    uint64_t total = __atomic_load_n(&lc_current_upload, __ATOMIC_RELAXED);
    for (int i = 0; i < lc_bucket_count; i++) total += lc_buckets[i].upload;
    pthread_mutex_unlock(&lc_stats_lock);
    return total;
}
uint64_t lcproxy_stats_total_download(void) {
    pthread_mutex_lock(&lc_stats_lock);
    uint64_t total = __atomic_load_n(&lc_current_download, __ATOMIC_RELAXED);
    for (int i = 0; i < lc_bucket_count; i++) total += lc_buckets[i].download;
    pthread_mutex_unlock(&lc_stats_lock);
    return total;
}

// fd 分类缓存：避免每个 read/write 都 getsockname+getsockopt。
// 0=未知，1=需要统计的远端 TCP socket，2=不需统计（普通文件/管道/回环等）。
#define LC_FD_CLASS_UNKNOWN 0
#define LC_FD_CLASS_COUNT   1
#define LC_FD_CLASS_NOCOUNT 2
#define LC_FD_CLASS_CACHE_SIZE 4096
static unsigned char lc_fd_class[LC_FD_CLASS_CACHE_SIZE];

static void lc_fd_class_set(int fd, unsigned char v) {
    if (fd >= 0 && fd < LC_FD_CLASS_CACHE_SIZE)
        lc_fd_class[fd] = v;
}

static unsigned char lc_fd_class_get(int fd) {
    if (fd >= 0 && fd < LC_FD_CLASS_CACHE_SIZE)
        return lc_fd_class[fd];
    return LC_FD_CLASS_UNKNOWN;
}

static int lc_should_count_fd(int fd) {
    unsigned char cls = lc_fd_class_get(fd);
    if (cls == LC_FD_CLASS_NOCOUNT)
        return 0;
    if (lc_bypass_get())
        return 0;
    if (cls == LC_FD_CLASS_COUNT)
        return lcproxy_stats_is_cellular_fast();

    // 未知 fd：首次分类也走缓存；getifaddrs 只由定时器/配置刷新触发。
    if (!lcproxy_stats_is_cellular_fast()) {
        lc_fd_class_set(fd, LC_FD_CLASS_NOCOUNT);
        return 0;
    }
    struct sockaddr_storage ss;
    socklen_t len = sizeof(ss);
    if (getsockname(fd, (struct sockaddr *)&ss, &len) != 0) {
        lc_fd_class_set(fd, LC_FD_CLASS_NOCOUNT);
        return 0;
    }
    if (ss.ss_family == AF_INET) {
        struct sockaddr_in *sin = (struct sockaddr_in *)&ss;
        unsigned long a = ntohl(sin->sin_addr.s_addr);
        if ((a >> 24) == 127) {
            lc_fd_class_set(fd, LC_FD_CLASS_NOCOUNT);
            return 0;
        }
    } else if (ss.ss_family == AF_INET6) {
        struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)&ss;
        if (IN6_IS_ADDR_LOOPBACK(&sin6->sin6_addr)) {
            lc_fd_class_set(fd, LC_FD_CLASS_NOCOUNT);
            return 0;
        }
    } else {
        lc_fd_class_set(fd, LC_FD_CLASS_NOCOUNT);
        return 0;
    }
    int type = 0;
    socklen_t tl = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &tl) != 0) {
        lc_fd_class_set(fd, LC_FD_CLASS_NOCOUNT);
        return 0;
    }
    lc_fd_class_set(fd, LC_FD_CLASS_COUNT);
    return 1;
}

// Direct-connection kill switch tracking.
// While auto-direct mode is active, remote TCP sockets are recorded so that a
// later transition to cellular can close them before proxy mode is enabled.
// This prevents old Wi-Fi direct connections from continuing to send traffic
// on the cellular interface after the network path has changed.
#define LC_DIRECT_FD_MAX 2048
static int lc_direct_fds[LC_DIRECT_FD_MAX];
static int lc_direct_fd_count = 0;
static pthread_mutex_t lc_direct_lock = PTHREAD_MUTEX_INITIALIZER;

static int lc_direct_is_local_addr(const struct sockaddr *addr, unsigned short port) {
    if (!addr) return 0;
    int family = addr->sa_family;
    localaddr_arg localnet[MAX_LOCALNET];
    size_t localnet_count = 0;
    lcproxy_control_copy_route_rules(localnet, MAX_LOCALNET, &localnet_count,
                                     NULL, 0, NULL, NULL);
    size_t i;
    for (i = 0; i < localnet_count; i++) {
        if (localnet[i].port && localnet[i].port != port)
            continue;
        if (localnet[i].family != family)
            continue;
        if (family == AF_INET) {
            const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
            if (((sin->sin_addr.s_addr ^ localnet[i].in_addr.s_addr) &
                 localnet[i].in_mask.s_addr) == 0)
                return 1;
        } else if (family == AF_INET6) {
            const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
            size_t prefix_bytes = localnet[i].in6_prefix / CHAR_BIT;
            size_t prefix_bits = localnet[i].in6_prefix % CHAR_BIT;
            if (prefix_bytes && memcmp(&sin6->sin6_addr, &localnet[i].in6_addr, prefix_bytes) != 0)
                continue;
            if (prefix_bits && (sin6->sin6_addr.s6_addr[prefix_bytes] ^ localnet[i].in6_addr.s6_addr[prefix_bytes]) >> (CHAR_BIT - prefix_bits))
                continue;
            return 1;
        }
    }
    return 0;
}

static void lc_direct_track_add_if_remote(int sock, const struct sockaddr *addr, socklen_t addrlen) {
    if (!addr || addrlen < sizeof(sa_family_t))
        return;
    int socktype = 0;
    socklen_t optlen = sizeof(socktype);
    if (getsockopt(sock, SOL_SOCKET, SO_TYPE, &socktype, &optlen) != 0)
        return;
    if (socktype != SOCK_STREAM)
        return;
    unsigned short port = 0;
    if (addr->sa_family == AF_INET) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
        port = ntohs(sin->sin_port);
    } else if (addr->sa_family == AF_INET6) {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
        port = ntohs(sin6->sin6_port);
    } else {
        return;
    }
    if (lc_direct_is_local_addr(addr, port))
        return;

    pthread_mutex_lock(&lc_direct_lock);
    int i;
    for (i = 0; i < lc_direct_fd_count; i++) {
        if (lc_direct_fds[i] == sock) {
            pthread_mutex_unlock(&lc_direct_lock);
            return;
        }
    }
    if (lc_direct_fd_count < LC_DIRECT_FD_MAX)
        lc_direct_fds[lc_direct_fd_count++] = sock;
    pthread_mutex_unlock(&lc_direct_lock);
}

static void lc_direct_track_remove(int fd) {
    pthread_mutex_lock(&lc_direct_lock);
    int i;
    for (i = 0; i < lc_direct_fd_count; i++) {
        if (lc_direct_fds[i] == fd) {
            lc_direct_fds[i] = lc_direct_fds[lc_direct_fd_count - 1];
            lc_direct_fd_count--;
            break;
        }
    }
    pthread_mutex_unlock(&lc_direct_lock);
}

static int lc_direct_track_contains(int fd) {
    int found = 0;
    pthread_mutex_lock(&lc_direct_lock);
    for (int i = 0; i < lc_direct_fd_count; i++) {
        if (lc_direct_fds[i] == fd) {
            found = 1;
            break;
        }
    }
    pthread_mutex_unlock(&lc_direct_lock);
    return found;
}

static void lc_direct_track_copy(int source, int duplicate) {
    if (source < 0 || duplicate < 0 || source == duplicate) return;
    pthread_mutex_lock(&lc_direct_lock);
    int source_is_direct = 0;
    for (int i = 0; i < lc_direct_fd_count; i++) {
        if (lc_direct_fds[i] == source) {
            source_is_direct = 1;
            break;
        }
    }
    for (int i = 0; i < lc_direct_fd_count; i++) {
        if (lc_direct_fds[i] == duplicate) {
            lc_direct_fds[i] = lc_direct_fds[lc_direct_fd_count - 1];
            lc_direct_fd_count--;
            break;
        }
    }
    if (source_is_direct && lc_direct_fd_count < LC_DIRECT_FD_MAX)
        lc_direct_fds[lc_direct_fd_count++] = duplicate;
    pthread_mutex_unlock(&lc_direct_lock);
}

static void lc_direct_track_remove_range(unsigned first, unsigned last) {
    pthread_mutex_lock(&lc_direct_lock);
    int out = 0;
    int i;
    for (i = 0; i < lc_direct_fd_count; i++) {
        int fd = lc_direct_fds[i];
        if (fd >= (int)first && fd <= (int)last)
            continue;
        lc_direct_fds[out++] = fd;
    }
    lc_direct_fd_count = out;
    pthread_mutex_unlock(&lc_direct_lock);
}

static void lc_direct_track_close_all(void) {
    pthread_mutex_lock(&lc_direct_lock);
    int i;
    for (i = 0; i < lc_direct_fd_count; i++) {
        int fd = lc_direct_fds[i];
        if (fd >= 0) {
            /* shutdown invalidates every duplicated descriptor of this socket. */
            shutdown(fd, SHUT_RDWR);
            true_close(fd);
        }
    }
    lc_direct_fd_count = 0;
    pthread_mutex_unlock(&lc_direct_lock);
}

static void get_chain_data(proxy_data * pd, unsigned int *proxy_count, chain_type * ct);

static void* load_sym(char* symname, void* proxyfunc, int is_mandatory) {
	void *funcptr = dlsym(RTLD_NEXT, symname);

	if(is_mandatory && !funcptr) {
		fprintf(stderr, "Cannot load symbol '%s' %s\n", symname, dlerror());
		exit(1);
	} else if (!funcptr) {
		return funcptr;
	} else {
		PDEBUG("loaded symbol '%s'" " real addr %p  wrapped addr %p\n", symname, funcptr, proxyfunc);
	}
	if(funcptr == proxyfunc) {
		PDEBUG("circular reference detected, aborting!\n");
		abort();
	}
	return funcptr;
}

#include "allocator_thread.h"

const char *proxychains_get_version(void);

static void setup_hooks(void);
static void setup_runtime_hooks(void);
extern void livecontainer_install_webkit_proxy(void);

typedef struct {
	unsigned int first, last, flags;
} close_range_args_t;

/* If there is some `close` or `close_range` system call before do_init, 
   we buffer it, and actually execute them in do_init. */
static int close_fds[16];
static int close_fds_cnt = 0;
static close_range_args_t close_range_buffer[16];
static int close_range_buffer_cnt = 0;

static unsigned get_rand_seed(void) {
#ifdef HAVE_CLOCK_GETTIME
	struct timespec now;
	clock_gettime(CLOCK_REALTIME, &now);
	return now.tv_sec ^ now.tv_nsec;
#else
	return time(NULL);
#endif
}

static void do_init(void) {
	char *env;

	srand(get_rand_seed());
	core_initialize();

	env = getenv(PROXYCHAINS_QUIET_MODE_ENV_VAR);
	if(env && *env == '1')
		proxychains_quiet_mode = 1;

	proxychains_write_log(LOG_PREFIX "DLL init: proxychains-ng %s\n", proxychains_get_version());
	{
		Dl_info dli;
		if(dladdr((void*)&do_init, &dli) && dli.dli_fname && dli.dli_fname[0])
			proxychains_write_log(LOG_PREFIX "dylib path: %s\n", dli.dli_fname);
	}

	setup_hooks();
	setup_runtime_hooks();
	livecontainer_install_webkit_proxy();

	/* read the config file */
	get_chain_data(proxychains_pd, &proxychains_proxy_count, &proxychains_ct);
	DUMP_PROXY_CHAIN(proxychains_pd, proxychains_proxy_count);

	while(close_fds_cnt) true_close(close_fds[--close_fds_cnt]);
	while(close_range_buffer_cnt) {
		int i = --close_range_buffer_cnt;
		true_close_range(close_range_buffer[i].first, close_range_buffer[i].last, close_range_buffer[i].flags);
	}
	init_l = 1;

	rdns_init(proxychains_resolver);
}

static void init_lib_wrapper(const char* caller) {
#ifndef DEBUG
	(void) caller;
#endif
	if(!init_l) PDEBUG("%s called from %s\n", __FUNCTION__,  caller);
	pthread_once(&init_once, do_init);
}

/* if we use gcc >= 3, we can instruct the dynamic loader
 * to call init_lib at link time. otherwise it gets loaded
 * lazily, which has the disadvantage that there's a potential
 * race condition if 2 threads call it before init_l is set
 * and PTHREAD support was disabled */
#if __GNUC__+0 > 2
__attribute__((constructor))
static void gcc_init(void) {
	init_lib_wrapper(__FUNCTION__);
}
#define INIT() do {} while(0)
#else
#define INIT() init_lib_wrapper(__FUNCTION__)
#endif


typedef enum {
	RS_PT_NONE = 0,
	RS_PT_SOCKS4,
	RS_PT_SOCKS5,
	RS_PT_HTTP
} rs_proxyType;

/*
  proxy_from_string() taken from rocksock network I/O library (C) rofl0r
  valid inputs:
	socks5://user:password@proxy.domain.com:port
	socks5://proxy.domain.com:port
	socks4://proxy.domain.com:port
	http://user:password@proxy.domain.com:port
	http://proxy.domain.com:port

	supplying port number is obligatory.
	user:pass@ part is optional for http and socks5.
	however, user:pass authentication is currently not implemented for http proxies.
  return 1 on success, 0 on error.
*/
static int proxy_from_string(const char *proxystring,
	char *type_buf,
	char* host_buf,
	int *port_n,
	char *user_buf,
	char* pass_buf)
{
	const char* p;
	rs_proxyType proxytype;

	size_t next_token = 6, ul = 0, pl = 0, hl;
	if(!proxystring[0] || !proxystring[1] || !proxystring[2] || !proxystring[3] || !proxystring[4] || !proxystring[5]) goto inv_string;
	if(*proxystring == 's') {
		switch(proxystring[5]) {
			case '5': proxytype = RS_PT_SOCKS5; break;
			case '4': proxytype = RS_PT_SOCKS4; break;
			default: goto inv_string;
		}
	} else if(*proxystring == 'h') {
		proxytype = RS_PT_HTTP;
		next_token = 4;
	} else goto inv_string;
	if(
	   proxystring[next_token++] != ':' ||
	   proxystring[next_token++] != '/' ||
	   proxystring[next_token++] != '/') goto inv_string;
	const char *at = strrchr(proxystring+next_token, '@');
	if(at) {
		if(proxytype == RS_PT_SOCKS4)
			return 0;
		p = strchr(proxystring+next_token, ':');
		if(!p || p >= at) goto inv_string;
		const char *u = proxystring+next_token;
		ul = p-u;
		p++;
		pl = at-p;
		if(proxytype == RS_PT_SOCKS5 && (ul > 255 || pl > 255))
			return 0;
		memcpy(user_buf, u, ul);
		user_buf[ul]=0;
		memcpy(pass_buf, p, pl);
		pass_buf[pl]=0;
		next_token += 2+ul+pl;
	} else {
		user_buf[0]=0;
		pass_buf[0]=0;
	}
	const char* h = proxystring+next_token;
	p = strchr(h, ':');
	if(!p) goto inv_string;
	hl = p-h;
	if(hl > 255)
		return 0;
	memcpy(host_buf, h, hl);
	host_buf[hl]=0;
	*port_n = atoi(p+1);
	switch(proxytype) {
		case RS_PT_SOCKS4:
			strcpy(type_buf, "socks4");
			break;
		case RS_PT_SOCKS5:
			strcpy(type_buf, "socks5");
			break;
		case RS_PT_HTTP:
			strcpy(type_buf, "http");
			break;
		default:
			return 0;
	}
	return 1;
inv_string:
	return 0;
}

static const char* bool_str(int bool_val) {
	if(bool_val) return "true";
	return "false";
}

#define STR_STARTSWITH(P, LIT) (!strncmp(P, LIT, sizeof(LIT)-1))
/* get configuration from config file */
static void get_chain_data(proxy_data * pd, unsigned int *proxy_count, chain_type * ct) {
	int count = 0, port_n = 0, list = 0;
	char buf[1024], type[1024], host[1024], user[1024];
	char *buff, *env, *p;
	char local_addr_port[64], local_addr[64], local_netmask[32];
	char dnat_orig_addr_port[32], dnat_new_addr_port[32];
	char dnat_orig_addr[32], dnat_orig_port[32], dnat_new_addr[32], dnat_new_port[32];
	char rdnsd_addr[32], rdnsd_port[8];
	FILE *file = NULL;

	if(proxychains_got_chain_data)
		return;

	PFUNC();

	//Some defaults
	tcp_read_time_out = 4 * 1000;
	tcp_connect_time_out = 10 * 1000;
	*ct = DYNAMIC_TYPE;
	proxychains_max_chain = 1;
	proxychains_quiet_mode = 0;
	__atomic_store_n(&proxychains_block_non_tcp, 0, __ATOMIC_RELEASE);
	proxychains_resolver = DNSLF_LIBC;
	remote_dns_subnet = 224;
	num_localnet_addr = 0;
	num_dnats = 0;
	memset(localnet_addr, 0, sizeof(localnet_addr));
	memset(dnats, 0, sizeof(dnats));
	memset(pd, 0, sizeof(proxy_data) * MAX_CHAIN);

	env = get_config_path(getenv(PROXYCHAINS_CONF_FILE_ENV_VAR), buf, sizeof(buf));
	if(!env || (file = fopen(env, "r")) == NULL) {
		proxychains_write_log(LOG_PREFIX "couldnt find configuration file, proxychains disabled\n");
		goto no_proxy;
	}

	proxychains_write_log(LOG_PREFIX "config file found: %s\n", env);
	while(fgets(buf, sizeof(buf), file)) {
		buff = buf;
		/* remove leading whitespace */
		while(isspace(*buff)) buff++;
		/* remove trailing '\n' */
		if((p = strrchr(buff, '\n'))) *p = 0;
		p = buff + strlen(buff)-1;
		/* remove trailing whitespace */
		while(p >= buff && isspace(*p)) *(p--) = 0;
		if(!*buff || *buff == '#') continue; /* skip empty lines and comments */
		if(1) {
			/* proxylist has to come last */
			if(list) {
				if(count >= MAX_CHAIN)
					break;

				memset(&pd[count], 0, sizeof(proxy_data));

				pd[count].ps = PLAY_STATE;
				port_n = 0;

				int ret = sscanf(buff, "%s %s %d %s %s", type, host, &port_n, pd[count].user, pd[count].pass);
				if(ret < 3 || ret == EOF) {
					if(!proxy_from_string(buff, type, host, &port_n, pd[count].user, pd[count].pass)) {
						inv:
						fprintf(stderr, "error: invalid item in proxylist section: %s", buff);
						goto no_proxy;
					}
				}

				memset(&pd[count].ip, 0, sizeof(pd[count].ip));
				pd[count].ip.is_v6 = !!strchr(host, ':');
				pd[count].port = htons((unsigned short) port_n);
				ip_type* host_ip = &pd[count].ip;
				if(1 != inet_pton(host_ip->is_v6 ? AF_INET6 : AF_INET, host, host_ip->addr.v6)) {
					if(*ct == STRICT_TYPE && proxychains_resolver >= DNSLF_RDNS_START && count > 0) {
						/* we can allow dns hostnames for all but the first proxy in the list if chaintype is strict, as remote lookup can be done */
						rdns_init(proxychains_resolver);
						ip_type4 internal_ip = rdns_get_ip_for_host(host, strlen(host));
						pd[count].ip.is_v6 = 0;
						host_ip->addr.v4 = internal_ip;
						if(internal_ip.as_int == IPT4_INVALID.as_int)
							goto inv_host;
					} else {
inv_host:
						fprintf(stderr, "proxy %s has invalid value or is not numeric\n", host);
						fprintf(stderr, "non-numeric ips are only allowed under the following circumstances:\n");
						fprintf(stderr, "chaintype == strict (%s), proxy is not first in list (%s), proxy_dns active (%s)\n\n", bool_str(*ct == STRICT_TYPE), bool_str(count > 0), rdns_resolver_string(proxychains_resolver));
						goto no_proxy;
					}
				}

				if(!strcmp(type, "http")) {
					pd[count].pt = HTTP_TYPE;
				} else if(!strcmp(type, "raw")) {
					pd[count].pt = RAW_TYPE;
				} else if(!strcmp(type, "socks4")) {
					pd[count].pt = SOCKS4_TYPE;
				} else if(!strcmp(type, "socks5")) {
					pd[count].pt = SOCKS5_TYPE;
				} else
					goto inv;

				if(port_n)
					count++;
			} else {
				if(!strcmp(buff, "[ProxyList]")) {
					list = 1;
				} else if(!strcmp(buff, "random_chain")) {
					*ct = RANDOM_TYPE;
				} else if(!strcmp(buff, "strict_chain")) {
					*ct = STRICT_TYPE;
				} else if(!strcmp(buff, "dynamic_chain")) {
					*ct = DYNAMIC_TYPE;
				} else if(!strcmp(buff, "round_robin_chain")) {
					*ct = ROUND_ROBIN_TYPE;
				} else if(!strcmp(buff, "block_non_tcp")) {
					proxychains_block_non_tcp = 1;
					proxychains_write_log(LOG_PREFIX "block_non_tcp enabled: non-TCP traffic will be dropped\n");
				} else if(STR_STARTSWITH(buff, "tcp_read_time_out")) {
					sscanf(buff, "%s %d", user, &tcp_read_time_out);
				} else if(STR_STARTSWITH(buff, "tcp_connect_time_out")) {
					sscanf(buff, "%s %d", user, &tcp_connect_time_out);
				} else if(STR_STARTSWITH(buff, "remote_dns_subnet")) {
					sscanf(buff, "%s %u", user, &remote_dns_subnet);
					if(remote_dns_subnet >= 256) {
						fprintf(stderr,
							"remote_dns_subnet: invalid value. requires a number between 0 and 255.\n");
						goto no_proxy;
					}
				} else if(STR_STARTSWITH(buff, "localnet")) {
					char colon, extra, right_bracket[2];
					unsigned short local_port = 0, local_prefix;
					int local_family, n, valid;
					if(sscanf(buff, "%s %53[^/]/%15s%c", user, local_addr_port, local_netmask, &extra) != 3) {
						fprintf(stderr, "localnet format error");
						goto no_proxy;
					}
					p = strchr(local_addr_port, ':');
					if(!p || p == strrchr(local_addr_port, ':')) {
						local_family = AF_INET;
						n = sscanf(local_addr_port, "%15[^:]%c%5hu%c", local_addr, &colon, &local_port, &extra);
						valid = n == 1 || (n == 3 && colon == ':');
					} else if(local_addr_port[0] == '[') {
						local_family = AF_INET6;
						n = sscanf(local_addr_port, "[%45[^][]%1[]]%c%5hu%c", local_addr, right_bracket, &colon, &local_port, &extra);
						valid = n == 2 || (n == 4 && colon == ':');
					} else {
						local_family = AF_INET6;
						valid = sscanf(local_addr_port, "%45[^][]%c", local_addr, &extra) == 1;
					}
					if(!valid) {
						fprintf(stderr, "localnet address or port error\n");
						goto no_proxy;
					}
					if(local_port) {
						PDEBUG("added localnet: netaddr=%s, port=%u, netmask=%s\n",
						       local_addr, local_port, local_netmask);
					} else {
						PDEBUG("added localnet: netaddr=%s, netmask=%s\n",
						       local_addr, local_netmask);
					}
					if(num_localnet_addr < MAX_LOCALNET) {
						localnet_addr[num_localnet_addr].family = local_family;
						localnet_addr[num_localnet_addr].port = local_port;
						valid = 0;
						if (local_family == AF_INET) {
							valid =
							    inet_pton(local_family, local_addr,
							              &localnet_addr[num_localnet_addr].in_addr) > 0;
						} else if(local_family == AF_INET6) {
							valid =
							    inet_pton(local_family, local_addr,
							              &localnet_addr[num_localnet_addr].in6_addr) > 0;
						}
						if(!valid) {
							fprintf(stderr, "localnet address error\n");
							goto no_proxy;
						}
						if(local_family == AF_INET && strchr(local_netmask, '.')) {
							valid =
							    inet_pton(local_family, local_netmask,
							              &localnet_addr[num_localnet_addr].in_mask) > 0;
						} else {
							valid = sscanf(local_netmask, "%hu%c", &local_prefix, &extra) == 1;
							if (valid) {
								if(local_family == AF_INET && local_prefix <= 32) {
									localnet_addr[num_localnet_addr].in_mask.s_addr =
										htonl(0xFFFFFFFFu << (32u - local_prefix));
								} else if(local_family == AF_INET6 && local_prefix <= 128) {
									localnet_addr[num_localnet_addr].in6_prefix =
										local_prefix;
								} else {
									valid = 0;
								}
							}
						}
						if(!valid) {
							fprintf(stderr, "localnet netmask error\n");
							goto no_proxy;
						}
						++num_localnet_addr;
					} else {
						fprintf(stderr, "# of localnet exceed %d.\n", MAX_LOCALNET);
					}
				} else if(STR_STARTSWITH(buff, "chain_len")) {
					char *pc;
					int len;
					pc = strchr(buff, '=');
					if(!pc) {
						fprintf(stderr, "error: missing equals sign '=' in chain_len directive.\n");
						goto no_proxy;
					}
					len = atoi(++pc);
					proxychains_max_chain = (len ? len : 1);
				} else if(!strcmp(buff, "quiet_mode")) {
					proxychains_quiet_mode = 1;
				} else if(!strcmp(buff, "proxy_dns_old")) {
					proxychains_resolver = DNSLF_FORKEXEC;
				} else if(!strcmp(buff, "proxy_dns")) {
					proxychains_resolver = DNSLF_RDNS_THREAD;
				} else if(STR_STARTSWITH(buff, "proxy_dns_daemon")) {
					struct sockaddr_in rdns_server_buffer;

					if(sscanf(buff, "%s %15[^:]:%5s", user, rdnsd_addr, rdnsd_port) < 3) {
						fprintf(stderr, "proxy_dns_daemon format error\n");
						goto no_proxy;
					}
					rdns_server_buffer.sin_family = AF_INET;
					int error = inet_pton(AF_INET, rdnsd_addr, &rdns_server_buffer.sin_addr);
					if(error <= 0) {
						fprintf(stderr, "bogus proxy_dns_daemon address\n");
						goto no_proxy;
					}
					rdns_server_buffer.sin_port = htons(atoi(rdnsd_port));
					proxychains_resolver = DNSLF_RDNS_DAEMON;
					rdns_set_daemon(&rdns_server_buffer);
				} else if(STR_STARTSWITH(buff, "dnat")) {
					if(sscanf(buff, "%s %21[^ ] %21s\n", user, dnat_orig_addr_port, dnat_new_addr_port) < 3) {
						fprintf(stderr, "dnat format error");
						goto no_proxy;
					}
					/* clean previously used buffer */
					memset(dnat_orig_port, 0, sizeof(dnat_orig_port) / sizeof(dnat_orig_port[0]));
					memset(dnat_new_port, 0, sizeof(dnat_new_port) / sizeof(dnat_new_port[0]));

					(void)sscanf(dnat_orig_addr_port, "%15[^:]:%5s", dnat_orig_addr, dnat_orig_port);
					(void)sscanf(dnat_new_addr_port, "%15[^:]:%5s", dnat_new_addr, dnat_new_port);

					if(num_dnats < MAX_DNAT) {
						int error;
						error =
						    inet_pton(AF_INET, dnat_orig_addr,
							      &dnats[num_dnats].orig_dst);
						if(error <= 0) {
							fprintf(stderr, "dnat original destination address error\n");
							goto no_proxy;
						}

						error =
						    inet_pton(AF_INET, dnat_new_addr,
							      &dnats[num_dnats].new_dst);
						if(error <= 0) {
							fprintf(stderr, "dnat effective destination address error\n");
							goto no_proxy;
						}

						if(dnat_orig_port[0]) {
							dnats[num_dnats].orig_port =
							    (short) atoi(dnat_orig_port);
						} else {
							dnats[num_dnats].orig_port = 0;
						}

						if(dnat_new_port[0]) {
							dnats[num_dnats].new_port =
							    (short) atoi(dnat_new_port);
						} else {
							dnats[num_dnats].new_port = 0;
						}

						PDEBUG("added dnat: orig-dst=%s orig-port=%d new-dst=%s new-port=%d\n", dnat_orig_addr, dnats[num_dnats].orig_port, dnat_new_addr, dnats[num_dnats].new_port);
						++num_dnats;
					} else {
						fprintf(stderr, "# of dnat exceed %d.\n", MAX_DNAT);
					}
				}
			}
		}
	}
#ifndef BROKEN_FCLOSE
	fclose(file);
	file = NULL;
#endif
	if(!count) {
		fprintf(stderr, "error: no valid proxy found in config\n");
		goto no_proxy;
	}
	*proxy_count = count;
	proxychains_got_chain_data = 1;
	lcproxy_control_set_config_valid(1);
	PDEBUG("proxy_dns: %s\n", rdns_resolver_string(proxychains_resolver));
	return;

no_proxy:
	if(file)
		fclose(file);
	*proxy_count = 0;
	proxychains_got_chain_data = 1;
	proxychains_resolver = DNSLF_LIBC;
	lcproxy_control_set_config_valid(0);
	proxychains_write_log(LOG_PREFIX "no usable proxy config, proxychains disabled\n");
}

void lcproxy_control_reload_config(void) {
	pthread_mutex_lock(&lc_proxy_chain_lock);
	unsigned int old_proxy_count = proxychains_proxy_count;
	proxychains_got_chain_data = 0;
	proxychains_proxy_count = 0;
	get_chain_data(proxychains_pd, &proxychains_proxy_count, &proxychains_ct);
	lcproxy_control_apply_proxy_override(proxychains_pd, proxychains_proxy_count);
	rdns_init(proxychains_resolver);
	int close_old_direct = (!__atomic_load_n(&lc_proxy_disabled, __ATOMIC_ACQUIRE) && old_proxy_count == 0 && proxychains_proxy_count > 0);
	unsigned int new_count = proxychains_proxy_count;
	pthread_mutex_unlock(&lc_proxy_chain_lock);
	// If a direct-mode config (no proxy list) is replaced by a proxy config
	// while proxy mode is already enabled, close old direct sockets too.
	if (close_old_direct)
		lc_direct_track_close_all();
	proxychains_write_log(LOG_PREFIX "config reloaded, proxy_count=%u\n", new_count);
}


/*******  HOOK FUNCTIONS  *******/

#define EXPAND( args...) args
#ifdef MONTEREY_HOOKING
#define HOOKFUNC(R, N, args...) R pxcng_ ## N ( EXPAND(args) )
#else
#define HOOKFUNC(R, N, args...) R N ( EXPAND(args) )
#endif

static int lc_drop_non_tcp_if_enabled(int fd) {
	int socktype = 0;
	socklen_t optlen = sizeof(socktype);
	if(!__atomic_load_n(&proxychains_block_non_tcp, __ATOMIC_ACQUIRE))
		return 0;
	if(getsockopt(fd, SOL_SOCKET, SO_TYPE, &socktype, &optlen) != 0)
		return 0;
	if(socktype != SOCK_STREAM) {
		errno = EPROTONOSUPPORT;
		return 1;
	}
	return 0;
}

HOOKFUNC(int, close, int fd) {
	lc_direct_track_remove(fd);
	lc_fd_class_set(fd, LC_FD_CLASS_UNKNOWN);
	if(!init_l) {
		if((size_t)close_fds_cnt >= (sizeof close_fds / sizeof close_fds[0])) goto err;
		close_fds[close_fds_cnt++] = fd;
		errno = 0;
		return 0;
	}
	if(proxychains_resolver != DNSLF_RDNS_THREAD) return true_close(fd);

	/* prevent rude programs (like ssh) from closing our pipes */
	if(fd != req_pipefd[0]  && fd != req_pipefd[1] &&
	   fd != resp_pipefd[0] && fd != resp_pipefd[1]) {
		return true_close(fd);
	}
	err:
	errno = EBADF;
	return -1;
}
static int is_v4inv6(const struct in6_addr *a) {
	return !memcmp(a->s6_addr, "\0\0\0\0\0\0\0\0\0\0\xff\xff", 12);
}

static void intsort(int *a, int n) {
	int i, j, s;
	for(i=0; i<n; ++i)
		for(j=i+1; j<n; ++j)
			if(a[j] < a[i]) {
				s = a[i];
				a[i] = a[j];
				a[j] = s;
			}
}

/* Warning: Linux manual says the third arg is `unsigned int`, but unistd.h says `int`. */
HOOKFUNC(int, close_range, unsigned first, unsigned last, int flags) {
	// CLOSE_RANGE_CLOEXEC preserves descriptors, so their kill-switch records
	// must survive until a later real close.
#ifdef CLOSE_RANGE_CLOEXEC
	if (!(flags & CLOSE_RANGE_CLOEXEC)) {
		lc_direct_track_remove_range(first, last);
		memset(lc_fd_class, 0, sizeof(lc_fd_class));
	}
#else
	lc_direct_track_remove_range(first, last);
	memset(lc_fd_class, 0, sizeof(lc_fd_class));
#endif
	if(true_close_range == NULL) {
		fprintf(stderr, "Calling close_range, but this platform does not provide this system call. ");
		return -1;
	}
	if(!init_l) {
		/* push back to cache, and delay the execution. */
		if((size_t)close_range_buffer_cnt >= (sizeof close_range_buffer / sizeof close_range_buffer[0])) {
			errno = ENOMEM;
			return -1;
		}
		int i = close_range_buffer_cnt++;
		close_range_buffer[i].first = first;
		close_range_buffer[i].last = last;
		close_range_buffer[i].flags = flags;
		return errno = 0;
	}
	if(proxychains_resolver != DNSLF_RDNS_THREAD) return true_close_range(first, last, flags);

	/* prevent rude programs (like ssh) from closing our pipes */
	int res = 0, uerrno = 0, i;
	int protected_fds[] = {req_pipefd[0], req_pipefd[1], resp_pipefd[0], resp_pipefd[1]};
	intsort(protected_fds, 4);
	/* We are skipping protected_fds while calling true_close_range()
	 * If protected_fds cut the range into some sub-ranges, we close sub-ranges BEFORE cut point in the loop. 
	 * [first, cut1-1] , [cut1+1, cut2-1] , [cut2+1, cut3-1]
	 * Finally, we delete the remaining sub-range, outside the loop. [cut3+1, tail]
	 */
	unsigned next_fd_to_close = first;
	for(i = 0; i < 4; ++i) {
		if(protected_fds[i] < 0 || (unsigned)protected_fds[i] < first ||
		   (unsigned)protected_fds[i] > last)
			continue;
		unsigned prev = (i == 0 || protected_fds[i - 1] < 0 ||
		                 (unsigned)protected_fds[i - 1] < first) ?
		                first : (unsigned)protected_fds[i - 1] + 1;
		if(prev != (unsigned)protected_fds[i]) {
			if(-1 == true_close_range(prev, (unsigned)protected_fds[i] - 1, flags)) {
				res = -1;
				uerrno = errno;
			}
		}
		next_fd_to_close = (unsigned)protected_fds[i] + 1;
	}
	if(next_fd_to_close <= last) {
		if(-1 == true_close_range(next_fd_to_close, last, flags)) {
			res = -1;
			uerrno = errno;
		}
	}
	errno = uerrno;
	return res;
}

static void lc_fd_class_copy(int source, int duplicate) {
	if (source != duplicate)
		lc_fd_class_set(duplicate, lc_fd_class_get(source));
}

static void lc_track_duplicated_fd(int source, int duplicate) {
	if (duplicate < 0) return;
	lc_direct_track_copy(source, duplicate);
	lc_fd_class_copy(source, duplicate);
}

HOOKFUNC(int, dup, int source) {
	INIT();
	int duplicate = true_dup(source);
	lc_track_duplicated_fd(source, duplicate);
	return duplicate;
}

HOOKFUNC(int, dup2, int source, int duplicate) {
	INIT();
	int result = true_dup2(source, duplicate);
	lc_track_duplicated_fd(source, result);
	return result;
}

#if defined(__linux__)
HOOKFUNC(int, dup3, int source, int duplicate, int flags) {
	INIT();
	int result = true_dup3(source, duplicate, flags);
	lc_track_duplicated_fd(source, result);
	return result;
}
#endif

static int lc_fcntl_is_noarg_command(int command) {
	switch (command) {
	case F_GETFD:
	case F_GETFL:
#ifdef F_GETOWN
	case F_GETOWN:
#endif
#ifdef F_GETSIG
	case F_GETSIG:
#endif
#ifdef F_GETLEASE
	case F_GETLEASE:
#endif
#ifdef F_GETPIPE_SZ
	case F_GETPIPE_SZ:
#endif
		return 1;
	default:
		return 0;
	}
}

static int lc_fcntl_is_duplicate_command(int command) {
	if (command == F_DUPFD) return 1;
#ifdef F_DUPFD_CLOEXEC
	if (command == F_DUPFD_CLOEXEC) return 1;
#endif
	return 0;
}

HOOKFUNC(int, fcntl, int fd, int command, ...) {
	INIT();
	if (lc_fcntl_is_noarg_command(command))
		return true_fcntl(fd, command);

	va_list args;
	va_start(args, command);
	/* Darwin and Linux pass fcntl's scalar and pointer third arguments in the
	 * same ABI slot; preserving the raw word lets the real libc interpret it. */
	uintptr_t arg = va_arg(args, uintptr_t);
	va_end(args);
	int result = true_fcntl(fd, command, arg);
	if (lc_fcntl_is_duplicate_command(command))
		lc_track_duplicated_fd(fd, result);
	return result;
}

HOOKFUNC(int, connect, int sock, const struct sockaddr *addr, unsigned int len) {
	INIT();
	PFUNC();
	PDEBUG("connect called: sock=%d family=%u\n", sock, addr ? (unsigned)addr->sa_family : 0u);

	if(lc_bypass_get())
		return true_connect(sock, addr, len);
	if(!addr || len < sizeof(sa_family_t)) {
		errno = EINVAL;
		return -1;
	}
	if(__atomic_load_n(&lc_proxy_disabled, __ATOMIC_ACQUIRE) &&
	   lc_direct_admission_begin()) {
		lc_direct_track_add_if_remote(sock, addr, len);
		int direct_ret = true_connect(sock, addr, len);
		lc_direct_admission_end();
		return direct_ret;
	}
	// A missing or invalid managed config is never permission to leak traffic.
	// LCProxyConfig reloads after it creates/migrates the config; until then,
	// fail closed unless the user explicitly selected direct/disabled mode above.
	lc_proxy_config_snapshot config;
	lcproxy_control_copy_config_snapshot(&config);
	if(!config.config_valid || config.chain_count == 0) {
		errno = ECONNREFUSED;
		return -1;
	}
	int socktype = 0, flags = 0, ret = 0;
	socklen_t optlen = 0;
	ip_type dest_ip;
	DEBUGDECL(char str[256]);

	struct in_addr *p_addr_in;
	struct in6_addr *p_addr_in6;
	dnat_arg *dnat = NULL;
	unsigned short port;
	size_t i;
	int remote_dns_connect = 0;
	optlen = sizeof(socktype);
	sa_family_t fam = SOCKFAMILY(*addr);
	getsockopt(sock, SOL_SOCKET, SO_TYPE, &socktype, &optlen);
	if(lc_drop_non_tcp_if_enabled(sock))
		return -1;
	if(!((fam  == AF_INET || fam == AF_INET6) && socktype == SOCK_STREAM))
		return true_connect(sock, addr, len);

	// 默认按不统计处理；只有通过 localnet 检查的远端 TCP 连接才标记为可统计。
	lc_fd_class_set(sock, LC_FD_CLASS_NOCOUNT);

	int v6 = dest_ip.is_v6 = fam == AF_INET6;

	p_addr_in = &((struct sockaddr_in *) addr)->sin_addr;
	p_addr_in6 = &((struct sockaddr_in6 *) addr)->sin6_addr;
	port = !v6 ? ntohs(((struct sockaddr_in *) addr)->sin_port)
	           : ntohs(((struct sockaddr_in6 *) addr)->sin6_port);
	struct in_addr v4inv6;
	if(v6 && is_v4inv6(p_addr_in6)) {
		memcpy(&v4inv6.s_addr, &p_addr_in6->s6_addr[12], 4);
		v6 = dest_ip.is_v6 = 0;
		p_addr_in = &v4inv6;
	}
	if(!v6 && !memcmp(p_addr_in, "\0\0\0\0", 4)) {
		errno = ECONNREFUSED;
		return -1;
	}

//      PDEBUG("localnet: %s; ", inet_ntop(AF_INET,&in_addr_localnet, str, sizeof(str)));
//      PDEBUG("netmask: %s; " , inet_ntop(AF_INET, &in_addr_netmask, str, sizeof(str)));
	PDEBUG("target: %s\n", inet_ntop(v6 ? AF_INET6 : AF_INET, v6 ? (void*)p_addr_in6 : (void*)p_addr_in, str, sizeof(str)));
	PDEBUG("port: %d\n", port);

	// check if connect called from proxydns
        remote_dns_connect = !v6 && (ntohl(p_addr_in->s_addr) >> 24 == config.remote_dns_subnet);

	// more specific first
	if (!v6) for(i = 0; i < config.dnat_count && !remote_dns_connect && !dnat; i++)
		if(config.dnat[i].orig_dst.s_addr == p_addr_in->s_addr)
			if(config.dnat[i].orig_port && (config.dnat[i].orig_port == port))
				dnat = &config.dnat[i];

	if (!v6) for(i = 0; i < config.dnat_count && !remote_dns_connect && !dnat; i++)
		if(config.dnat[i].orig_dst.s_addr == p_addr_in->s_addr)
			if(!config.dnat[i].orig_port)
				dnat = &config.dnat[i];

	if (dnat) {
		p_addr_in = &dnat->new_dst;
		if (dnat->new_port)
			port = dnat->new_port;
	}

	for(i = 0; i < config.localnet_count && !remote_dns_connect; i++) {
		if (config.localnet[i].port && config.localnet[i].port != port)
			continue;
		if (config.localnet[i].family != (v6 ? AF_INET6 : AF_INET))
			continue;
		if (v6) {
			size_t prefix_bytes = config.localnet[i].in6_prefix / CHAR_BIT;
			size_t prefix_bits = config.localnet[i].in6_prefix % CHAR_BIT;
			if (prefix_bytes && memcmp(p_addr_in6->s6_addr, config.localnet[i].in6_addr.s6_addr, prefix_bytes) != 0)
				continue;
			if (prefix_bits && (p_addr_in6->s6_addr[prefix_bytes] ^ config.localnet[i].in6_addr.s6_addr[prefix_bytes]) >> (CHAR_BIT - prefix_bits))
				continue;
		} else {
			if((p_addr_in->s_addr ^ config.localnet[i].in_addr.s_addr) & config.localnet[i].in_mask.s_addr)
				continue;
		}
		PDEBUG("accessing localnet using true_connect\n");
		return true_connect(sock, addr, len);
	}

	if (!remote_dns_connect)
		lc_fd_class_set(sock, LC_FD_CLASS_COUNT);

	flags = fcntl(sock, F_GETFL, 0);

	memcpy(dest_ip.addr.v6, v6 ? (void*)p_addr_in6 : (void*)p_addr_in, v6?16:4);

	if((flags & O_NONBLOCK) && lcproxy_async_connect_start(sock, dest_ip, port, flags) == 0) {
		lc_fd_class_set(sock, LC_FD_CLASS_NOCOUNT);
		errno = EINPROGRESS;
		return -1;
	}

	if(flags & O_NONBLOCK)
		fcntl(sock, F_SETFL, flags & ~O_NONBLOCK);

	lc_bypass_set(1);
	ret = connect_proxy_chain(sock,
				  dest_ip,
				  htons(port),
				  config.chain, config.chain_count, config.chain_type,
				  config.max_chain);
	lc_bypass_set(0);

	fcntl(sock, F_SETFL, flags);
	if(ret != SUCCESS)
		errno = ECONNREFUSED;
	return ret;
}

#ifdef MONTEREY_HOOKING
/* Apple's Network.framework / NSURLSession can use connectx() instead of
 * connect().  The ABI-compatible prototype below matches the Darwin
 * connectx() syscall wrapper.  We only intercept plain stream connects and
 * route them through the same proxychains core. */

static int lc_sockaddr_is_loopback(const struct sockaddr *addr, socklen_t addrlen) {
	if(!addr)
		return 0;
	if(addr->sa_family == AF_INET) {
		if(addrlen < sizeof(struct sockaddr_in))
			return 0;
		const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
		return (ntohl(sin->sin_addr.s_addr) & 0xff000000U) == 0x7f000000U;
	}
	if(addr->sa_family == AF_INET6) {
		if(addrlen < sizeof(struct sockaddr_in6))
			return 0;
		const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
		static const unsigned char kLcLoopbackV6[16] = {
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
		};
		return memcmp(&sin6->sin6_addr, kLcLoopbackV6, sizeof(kLcLoopbackV6)) == 0;
	}
	return 0;
}

HOOKFUNC(int, connectx, int sock, const sa_endpoints_t *endpoints,
         sae_associd_t associd, unsigned int flags, const struct iovec *ext,
         unsigned int extlen, size_t *pcid, sae_connid_t *connid) {
	INIT();
	PDEBUG("connectx called: sock=%d flags=%u ext=%p pcid=%p connid=%p\n",
	       sock, flags, (void*)ext, (void*)pcid, (void*)connid);
	if(endpoints)
		PDEBUG("connectx dst: family=%u len=%u\n",
		       endpoints->sae_dstaddr ? (unsigned)endpoints->sae_dstaddr->sa_family : 0u,
		       (unsigned)endpoints->sae_dstaddrlen);
	(void)associd;
	(void)ext;
	(void)extlen;
	(void)pcid;
	(void)connid;
	if(lc_bypass_get())
		return true_connectx(sock, endpoints, associd, flags, ext, extlen, pcid, connid);
	if(__atomic_load_n(&lc_proxy_disabled, __ATOMIC_ACQUIRE) &&
	   lc_direct_admission_begin()) {
		if (endpoints)
			lc_direct_track_add_if_remote(sock, endpoints->sae_dstaddr, endpoints->sae_dstaddrlen);
		int direct_ret = true_connectx(sock, endpoints, associd, flags, ext, extlen, pcid, connid);
		lc_direct_admission_end();
		return direct_ret;
	}
	if(lc_proxy_config_missing()) {
		errno = ECONNREFUSED;
		return -1;
	}
	// NSURLSession may use connectx with extensions for its explicit local HTTP
	// proxy connection. Loopback cannot leak Internet traffic, so preserve the
	// localnet behavior before rejecting unsupported external extensions.
	if(endpoints && lc_sockaddr_is_loopback(endpoints->sae_dstaddr, endpoints->sae_dstaddrlen))
		return true_connectx(sock, endpoints, associd, flags, ext, extlen, pcid, connid);
	if(!endpoints || !endpoints->sae_dstaddr ||
	   endpoints->sae_dstaddrlen < sizeof(struct sockaddr) || flags != 0 ||
	   ext != NULL || extlen != 0 || pcid != NULL || connid != NULL) {
		// connectx extensions cannot be represented by the connect() proxy path.
		// Reject them while proxying instead of silently opening a direct socket.
		PDEBUG("connectx rejected: proxy_count=%u endpoints=%p dst=%p flags=%u ext=%p extlen=%u pcid=%p connid=%p\n",
		       (unsigned int)lcproxy_control_get_proxy_count(), (void*)endpoints,
		       endpoints ? (void*)endpoints->sae_dstaddr : 0,
		       flags, (void*)ext, extlen, (void*)pcid, (void*)connid);
		errno = EOPNOTSUPP;
		return -1;
	}
	PDEBUG("connectx proxying via pxcng_connect\n");
	return pxcng_connect(sock, endpoints->sae_dstaddr, endpoints->sae_dstaddrlen);
}
#endif

#ifdef IS_SOLARIS
HOOKFUNC(int, __xnet_connect, int sock, const struct sockaddr *addr, unsigned int len)
	return connect(sock, addr, len);
}
#endif

static struct gethostbyname_data ghbndata;
HOOKFUNC(struct hostent*, gethostbyname, const char *name) {
	INIT();
	PDEBUG("gethostbyname: %s\n", name);

	if(lc_bypass_get())
		return true_gethostbyname(name);
	if(lc_proxy_config_missing())
		return NULL;

	if(proxychains_resolver == DNSLF_FORKEXEC)
		return proxy_gethostbyname_old(name);
	else if(proxychains_resolver == DNSLF_LIBC)
		return true_gethostbyname(name);
	else
		return proxy_gethostbyname(name, &ghbndata);

	return NULL;
}

HOOKFUNC(int, getaddrinfo, const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
	INIT();
	PDEBUG("getaddrinfo: %s %s\n", node ? node : "null", service ? service : "null");

	if(lc_bypass_get())
		return true_getaddrinfo(node, service, hints, res);
	if(lc_proxy_config_missing())
		return EAI_FAIL;

	if(proxychains_resolver != DNSLF_LIBC)
		return proxy_getaddrinfo(node, service, hints, res);
	else
		return true_getaddrinfo(node, service, hints, res);
}

HOOKFUNC(void, freeaddrinfo, struct addrinfo *res) {
	INIT();
	PDEBUG("freeaddrinfo %p \n", (void *) res);

	if(lc_bypass_get()) {
		true_freeaddrinfo(res);
		return;
	}

	if(proxychains_resolver == DNSLF_LIBC)
		true_freeaddrinfo(res);
	else
		proxy_freeaddrinfo(res);
}

HOOKFUNC(int, getnameinfo, const struct sockaddr *sa, socklen_t salen,
	           char *host, GN_NODELEN_T hostlen, char *serv,
	           GN_SERVLEN_T servlen, GN_FLAGS_T flags)
{
	INIT();
	PFUNC();

	if(lc_bypass_get())
		return true_getnameinfo(sa, salen, host, hostlen, serv, servlen, flags);
	if(lc_proxy_config_missing())
		return EAI_FAIL;

	if(proxychains_resolver == DNSLF_LIBC) {
		return true_getnameinfo(sa, salen, host, hostlen, serv, servlen, flags);
	} else {
		if(!salen || !(SOCKFAMILY(*sa) == AF_INET || SOCKFAMILY(*sa) == AF_INET6))
			return EAI_FAMILY;
		int v6 = SOCKFAMILY(*sa) == AF_INET6;
		if(salen < (v6?sizeof(struct sockaddr_in6):sizeof(struct sockaddr_in)))
			return EAI_FAMILY;
		if(hostlen) {
			unsigned char v4inv6buf[4];
			const void *ip = v6 ? (void*)&((struct sockaddr_in6*)sa)->sin6_addr
			                    : (void*)&((struct sockaddr_in*)sa)->sin_addr;
			unsigned scopeid = 0;
			if(v6) {
				if(is_v4inv6(&((struct sockaddr_in6*)sa)->sin6_addr)) {
					memcpy(v4inv6buf, &((struct sockaddr_in6*)sa)->sin6_addr.s6_addr[12], 4);
					ip = v4inv6buf;
					v6 = 0;
				} else
					scopeid = ((struct sockaddr_in6 *)sa)->sin6_scope_id;
			}
			if(!inet_ntop(v6?AF_INET6:AF_INET,ip,host,hostlen))
				return EAI_OVERFLOW;
			if(scopeid) {
				size_t l = strlen(host);
				int n = snprintf(host + l, hostlen - l, "%%%u", scopeid);
				if(n < 0 || (size_t)n >= hostlen - l)
					return EAI_OVERFLOW;
			}
		}
		if(servlen) {
			int n = snprintf(serv, servlen, "%d", ntohs(SOCKPORT(*sa)));
			if(n < 0 || (socklen_t)n >= servlen)
				return EAI_OVERFLOW;
		}
	}
	return 0;
}

HOOKFUNC(struct hostent*, gethostbyaddr, const void *addr, socklen_t len, int type) {
	INIT();
	PDEBUG("TODO: proper gethostbyaddr hook\n");

	static char buf[16];
	static char ipv4[4];
	static char *list[2];
	static char *aliases[1];
	static struct hostent he;

	if(lc_bypass_get())
		return true_gethostbyaddr(addr, len, type);
	if(lc_proxy_config_missing())
		return NULL;

	if(proxychains_resolver == DNSLF_LIBC)
		return true_gethostbyaddr(addr, len, type);
	else {

		PDEBUG("len %u\n", len);
		if(len != 4)
			return NULL;
		he.h_name = buf;
		memcpy(ipv4, addr, 4);
		list[0] = ipv4;
		list[1] = NULL;
		he.h_addr_list = list;
		he.h_addrtype = AF_INET;
		aliases[0] = NULL;
		he.h_aliases = aliases;
		he.h_length = 4;
		pc_stringfromipv4((unsigned char *) addr, buf);
		return &he;
	}
	return NULL;
}

#ifndef MSG_FASTOPEN
#   define MSG_FASTOPEN 0x20000000
#endif

HOOKFUNC(ssize_t, sendto, int sockfd, const void *buf, size_t len, int flags,
	       const struct sockaddr *dest_addr, socklen_t addrlen) {
	INIT();
	PFUNC();
	if(!lc_bypass_get() && lc_proxy_config_missing()) {
		errno = ECONNREFUSED;
		return -1;
	}
	if(lc_drop_non_tcp_if_enabled(sockfd))
		return -1;
	if (flags & MSG_FASTOPEN) {
		if (!connect(sockfd, dest_addr, addrlen) && errno != EINPROGRESS) {
			return -1;
		}
		dest_addr = NULL;
		addrlen = 0;
		flags &= ~MSG_FASTOPEN;
	}
	ssize_t lc_ret = true_sendto(sockfd, buf, len, flags, dest_addr, addrlen);
	if(lc_ret > 0 && lc_should_count_fd(sockfd))
		lcproxy_stats_add_upload((uint64_t)lc_ret);
	return lc_ret;
}

HOOKFUNC(ssize_t, sendmsg, int sockfd, const struct msghdr *msg, int flags) {
	INIT();
	PFUNC();
	if(!lc_bypass_get() && lc_proxy_config_missing()) {
		errno = ECONNREFUSED;
		return -1;
	}
	if(lc_drop_non_tcp_if_enabled(sockfd))
		return -1;
	ssize_t lc_ret = true_sendmsg(sockfd, msg, flags);
	if(lc_ret > 0 && lc_should_count_fd(sockfd))
		lcproxy_stats_add_upload((uint64_t)lc_ret);
	return lc_ret;
}

static ssize_t lc_real_write(int fd, const void *buf, size_t len) {
    if (true_write) return true_write(fd, buf, len);
    static write_t sym;
    if (!sym) sym = (write_t)dlsym(RTLD_NEXT, "write");
    return sym ? sym(fd, buf, len) : -1;
}
static ssize_t lc_real_read(int fd, void *buf, size_t len) {
    if (true_read) return true_read(fd, buf, len);
    static read_t sym;
    if (!sym) sym = (read_t)dlsym(RTLD_NEXT, "read");
    return sym ? sym(fd, buf, len) : -1;
}

HOOKFUNC(ssize_t, send, int sockfd, const void *buf, size_t len, int flags) {
	INIT();
	PFUNC();
	if(!lc_bypass_get() && !lcproxy_control_get_config_valid() &&
	   lc_direct_track_contains(sockfd)) {
		errno = ECONNREFUSED;
		return -1;
	}
	if(lc_drop_non_tcp_if_enabled(sockfd))
		return -1;
	ssize_t lc_ret = true_send(sockfd, buf, len, flags);
	if(lc_ret > 0 && lc_should_count_fd(sockfd))
		lcproxy_stats_add_upload((uint64_t)lc_ret);
	return lc_ret;
}

HOOKFUNC(ssize_t, write, int fd, const void *buf, size_t len) {
	if(!init_l)
		return lc_real_write(fd, buf, len);
	INIT();
	PFUNC();
	if(!lc_bypass_get() && !lcproxy_control_get_config_valid() &&
	   lc_direct_track_contains(fd)) {
		errno = ECONNREFUSED;
		return -1;
	}
	ssize_t lc_ret = lc_real_write(fd, buf, len);
	if(lc_ret > 0 && lc_should_count_fd(fd))
		lcproxy_stats_add_upload((uint64_t)lc_ret);
	return lc_ret;
}

HOOKFUNC(ssize_t, recv, int sockfd, void *buf, size_t len, int flags) {
	INIT();
	PFUNC();
	ssize_t lc_ret = true_recv(sockfd, buf, len, flags);
	if(lc_ret > 0 && lc_should_count_fd(sockfd))
		lcproxy_stats_add_download((uint64_t)lc_ret);
	return lc_ret;
}

HOOKFUNC(ssize_t, recvfrom, int sockfd, void *buf, size_t len, int flags,
	       struct sockaddr *src_addr, socklen_t *addrlen) {
	INIT();
	PFUNC();
	ssize_t lc_ret = true_recvfrom(sockfd, buf, len, flags, src_addr, addrlen);
	if(lc_ret > 0 && lc_should_count_fd(sockfd))
		lcproxy_stats_add_download((uint64_t)lc_ret);
	return lc_ret;
}

HOOKFUNC(ssize_t, recvmsg, int sockfd, struct msghdr *msg, int flags) {
	INIT();
	PFUNC();
	ssize_t lc_ret = true_recvmsg(sockfd, msg, flags);
	if(lc_ret > 0 && lc_should_count_fd(sockfd))
		lcproxy_stats_add_download((uint64_t)lc_ret);
	return lc_ret;
}

HOOKFUNC(ssize_t, read, int fd, void *buf, size_t len) {
	if(!init_l)
		return lc_real_read(fd, buf, len);
	INIT();
	PFUNC();
	ssize_t lc_ret = lc_real_read(fd, buf, len);
	if(lc_ret > 0 && lc_should_count_fd(fd))
		lcproxy_stats_add_download((uint64_t)lc_ret);
	return lc_ret;
}

#ifdef MONTEREY_HOOKING
#define SETUP_SYM(X) do { if (! true_ ## X ) true_ ## X = &X; } while(0)
#define SETUP_SYM_OPTIONAL(X)
#else
#define SETUP_SYM_IMPL(X, IS_MANDATORY) do { if (! true_ ## X ) true_ ## X = load_sym( # X, X, IS_MANDATORY ); } while(0)
#define SETUP_SYM(X) SETUP_SYM_IMPL(X, 1)
#define SETUP_SYM_OPTIONAL(X) SETUP_SYM_IMPL(X, 0)
#endif

static void setup_hooks(void) {
	SETUP_SYM(connect);
#ifdef MONTEREY_HOOKING
	SETUP_SYM(connectx);
#endif
	SETUP_SYM(sendto);
	SETUP_SYM(sendmsg);
	SETUP_SYM(send);
	SETUP_SYM(write);
	SETUP_SYM(recv);
	SETUP_SYM(recvfrom);
	SETUP_SYM(recvmsg);
	SETUP_SYM(read);
	SETUP_SYM(gethostbyname);
	SETUP_SYM(getaddrinfo);
	SETUP_SYM(freeaddrinfo);
	SETUP_SYM(gethostbyaddr);
	SETUP_SYM(getnameinfo);
#ifdef IS_SOLARIS
	SETUP_SYM(__xnet_connect);
#endif
	SETUP_SYM(close);
	SETUP_SYM_OPTIONAL(close_range);
	SETUP_SYM(dup);
	SETUP_SYM(dup2);
	SETUP_SYM(fcntl);
#if defined(__linux__)
	SETUP_SYM_OPTIONAL(dup3);
#endif
}

#ifdef MONTEREY_HOOKING
static void setup_runtime_hooks(void) {
	struct rebinding rebindings[] = {
		{"connect", (void*)pxcng_connect, (void**)&true_connect},
		{"connectx", (void*)pxcng_connectx, (void**)&true_connectx},
		{"sendto", (void*)pxcng_sendto, (void**)&true_sendto},
		{"sendmsg", (void*)pxcng_sendmsg, (void**)&true_sendmsg},
		{"send", (void*)pxcng_send, (void**)&true_send},
		{"write", (void*)pxcng_write, (void**)&true_write},
		{"recv", (void*)pxcng_recv, (void**)&true_recv},
		{"recvfrom", (void*)pxcng_recvfrom, (void**)&true_recvfrom},
		{"recvmsg", (void*)pxcng_recvmsg, (void**)&true_recvmsg},
		{"read", (void*)pxcng_read, (void**)&true_read},
		{"gethostbyname", (void*)pxcng_gethostbyname, (void**)&true_gethostbyname},
		{"getaddrinfo", (void*)pxcng_getaddrinfo, (void**)&true_getaddrinfo},
		{"freeaddrinfo", (void*)pxcng_freeaddrinfo, (void**)&true_freeaddrinfo},
		{"gethostbyaddr", (void*)pxcng_gethostbyaddr, (void**)&true_gethostbyaddr},
		{"getnameinfo", (void*)pxcng_getnameinfo, (void**)&true_getnameinfo},
		{"close", (void*)pxcng_close, (void**)&true_close},
		{"dup", (void*)pxcng_dup, (void**)&true_dup},
		{"dup2", (void*)pxcng_dup2, (void**)&true_dup2},
		{"fcntl", (void*)pxcng_fcntl, (void**)&true_fcntl},
	};
	if(rebind_symbols(rebindings, sizeof(rebindings)/sizeof(rebindings[0])) != 0)
		proxychains_write_log(LOG_PREFIX "fishhook rebind_symbols failed\n");
	else
		proxychains_write_log(LOG_PREFIX "fishhook runtime rebinding installed\n");
}
#else
static void setup_runtime_hooks(void) {}
#endif
#ifdef MONTEREY_HOOKING

#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
   __attribute__((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };
#define DYLD_HOOK(F) DYLD_INTERPOSE(pxcng_ ## F, F)

DYLD_HOOK(connect);
#ifdef MONTEREY_HOOKING
DYLD_HOOK(connectx);
#endif
DYLD_HOOK(sendto);
DYLD_HOOK(sendmsg);
DYLD_HOOK(send);
DYLD_HOOK(write);
DYLD_HOOK(recv);
DYLD_HOOK(recvfrom);
DYLD_HOOK(recvmsg);
DYLD_HOOK(read);
DYLD_HOOK(gethostbyname);
DYLD_HOOK(getaddrinfo);
DYLD_HOOK(freeaddrinfo);
DYLD_HOOK(gethostbyaddr);
DYLD_HOOK(getnameinfo);
DYLD_HOOK(close);
DYLD_HOOK(dup);
DYLD_HOOK(dup2);
DYLD_HOOK(fcntl);

#endif
