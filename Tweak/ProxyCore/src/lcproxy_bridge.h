#ifndef LCPROXY_BRIDGE_H
#define LCPROXY_BRIDGE_H

#include <stdint.h>
#include "proxy_override.h"

#ifdef __cplusplus
extern "C" {
#endif

// Runtime proxy controls (applied immediately in addition to proxychains.conf)
void lcproxy_socket_set_bypass(int on);
void lcproxy_control_set_enabled(int enabled);
void lcproxy_control_reload_config(void);
int  lcproxy_control_get_proxy_count(void);
int  lcproxy_control_get_enabled(void);
void lcproxy_control_set_block_non_tcp(int enabled);
int  lcproxy_control_get_block_non_tcp(void);

// Cellular traffic statistics
int      lcproxy_stats_is_cellular(void);
void     lcproxy_stats_add_upload(uint64_t n);
void     lcproxy_stats_add_download(uint64_t n);
int      lcproxy_stats_bucket_count(void);
int      lcproxy_stats_get_bucket(int i, int64_t *start, uint64_t *up, uint64_t *down);
void     lcproxy_stats_get_current(int64_t *start, uint64_t *up, uint64_t *down);
uint64_t lcproxy_stats_total_upload(void);
uint64_t lcproxy_stats_total_download(void);

#ifdef __cplusplus
}
#endif

#endif
