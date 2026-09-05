#ifndef LCPROXY_BRIDGE_H
#define LCPROXY_BRIDGE_H

#include <stdint.h>
#include "core.h"
#include "proxy_override.h"

#ifdef __cplusplus
extern "C" {
#endif

// Runtime proxy controls (applied immediately in addition to proxychains.conf)
void lcproxy_socket_set_bypass(int on);
void lcproxy_control_set_enabled(int enabled);
int  lcproxy_control_set_config_path(const char *path);
void lcproxy_control_reload_config(void);
int  lcproxy_control_get_proxy_count(void);
int  lcproxy_control_get_enabled(void);
void lcproxy_control_set_config_valid(int valid);
int  lcproxy_control_get_config_valid(void);
void lcproxy_control_set_block_non_tcp(int enabled);
int  lcproxy_control_get_block_non_tcp(void);

// Thread-safe snapshot of the active proxychains chain. The snapshot is copied
// under the chain lock so connect/relay workers never observe a half-reloaded
// proxy array.
#define LC_PROXY_CHAIN_MAX 512
void lcproxy_control_copy_proxy_chain(proxy_data *dst, unsigned int dst_cap,
                                      unsigned int *out_count,
                                      chain_type *out_chain_type,
                                      unsigned int *out_max_chain);
void lcproxy_control_copy_route_rules(localaddr_arg *localnet, size_t localnet_cap,
                                      size_t *out_localnet_count,
                                      dnat_arg *dnat, size_t dnat_cap,
                                      size_t *out_dnat_count,
                                      unsigned int *out_remote_dns_subnet);
enum dns_lookup_flavor lcproxy_control_get_resolver(void);

// Real-time network path hints (NWPathMonitor updates routing fail-closed)
void     lcproxy_network_monitor_update(int known, int non_cellular);
int      lcproxy_network_should_direct(void);

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
