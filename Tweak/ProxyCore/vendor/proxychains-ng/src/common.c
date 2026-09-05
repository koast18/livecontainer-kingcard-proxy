#include "common.h"
#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/stat.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

static pthread_mutex_t lc_config_path_lock = PTHREAD_MUTEX_INITIALIZER;
static char lc_config_path[PATH_MAX];
static int lc_config_path_configured = 0;

int lcproxy_control_set_config_path(const char *path) {
	int ok = 1;
	pthread_mutex_lock(&lc_config_path_lock);
	if(!path || !path[0]) {
		lc_config_path_configured = 0;
		lc_config_path[0] = '\0';
	} else {
		size_t len = strlen(path);
		lc_config_path_configured = 1;
		if(len >= sizeof(lc_config_path)) {
			lc_config_path[0] = '\0';
			ok = 0;
		} else {
			memcpy(lc_config_path, path, len + 1);
		}
	}
	pthread_mutex_unlock(&lc_config_path_lock);
	return ok;
}

/* 1: copied path, 0: no runtime path, -1: configured but unusable. */
static int copy_runtime_config_path(char *pbuf, size_t bufsize) {
	int result = 0;
	pthread_mutex_lock(&lc_config_path_lock);
	if(lc_config_path_configured) {
		size_t len = strlen(lc_config_path);
		if(len == 0 || len >= bufsize) {
			result = -1;
		} else {
			memcpy(pbuf, lc_config_path, len + 1);
			result = 1;
		}
	}
	pthread_mutex_unlock(&lc_config_path_lock);
	return result;
}

const char *proxy_type_strmap[] = {
    "http",
    "socks4",
    "socks5",
};

const char *chain_type_strmap[] = {
    "dynamic_chain",
    "strict_chain",
    "random_chain",
    "round_robin_chain",
};

const char *proxy_state_strmap[] = {
    "play",
    "down",
    "blocked",
    "busy",
};

/* isnumericipv4() taken from libulz */
int pc_isnumericipv4(const char* ipstring) {
	size_t x = 0, n = 0, d = 0;
	int wasdot = 0;
	while(1) {
		switch(ipstring[x]) {
			case 0: goto done;
			case '.':
				if(!n || wasdot) return 0;
				d++;
				wasdot = 1;
				break;
			case '0': case '1': case '2': case '3': case '4':
			case '5': case '6': case '7': case '8': case '9':
				n++;
				wasdot = 0;
				break;
			default:
				return 0;
		}
		x++;
	}
	done:
	if(d == 3 && n >= 4 && n <= 12) return 1;
	return 0;
}

// stolen from libulz (C) rofl0r
void pc_stringfromipv4(unsigned char *ip_buf_4_bytes, char *outbuf_16_bytes) {
	unsigned char *p;
	char *o = outbuf_16_bytes;
	unsigned char n;
	for(p = ip_buf_4_bytes; p < ip_buf_4_bytes + 4; p++) {
		n = *p;
		if(*p >= 100) {
			if(*p >= 200)
				*(o++) = '2';
			else
				*(o++) = '1';
			n %= 100;
		}
		if(*p >= 10) {
			*(o++) = (n / 10) + '0';
			n %= 10;
		}
		*(o++) = n + '0';
		*(o++) = '.';
	}
	o[-1] = 0;
}

static int check_path(char *path) {
	if(!path)
		return 0;
	return access(path, R_OK) != -1;
}

static int get_file_stat(const char *path, struct stat *st) {
	struct stat local_st;
	if(!st) st = &local_st;
	if(!check_path((char *)path) || stat(path, st) != 0)
		return 0;
	return S_ISREG(st->st_mode);
}

static int path_ends_with_component(const char *path, const char *component) {
	size_t path_len = strlen(path);
	size_t component_len = strlen(component);
	while(path_len > 1 && path[path_len - 1] == '/')
		path_len--;
	if(path_len < component_len)
		return 0;
	if(strncmp(path + path_len - component_len, component, component_len) != 0)
		return 0;
	return path_len == component_len || path[path_len - component_len - 1] == '/';
}

static int build_launch_private_config_path(char *path, size_t path_size) {
	const char *home = getenv("LC_HOME_PATH");
	if(!home || !home[0])
		return 0;
	const char *suffix = path_ends_with_component(home, "Documents") ?
		"/LCProxy/" PROXYCHAINS_CONF_FILE :
		"/Documents/LCProxy/" PROXYCHAINS_CONF_FILE;
	size_t home_len = strlen(home);
	while(home_len > 1 && home[home_len - 1] == '/')
		home_len--;
	size_t suffix_len = strlen(suffix);
	if(home_len + suffix_len + 1 > path_size)
		return 0;
	memcpy(path, home, home_len);
	memcpy(path + home_len, suffix, suffix_len + 1);
	return 1;
}

char *get_config_path(char* default_path, char* pbuf, size_t bufsize) {
	(void)default_path;
	if(!pbuf || bufsize == 0)
		return NULL;
	/* LCProxyConfig resolves the App Group path with Foundation. Do not let a
	 * failed canonical reload revive a stale private configuration. */
	int runtime_path = copy_runtime_config_path(pbuf, bufsize);
	if(runtime_path != 0)
		return runtime_path > 0 && get_file_stat(pbuf, NULL) ? pbuf : NULL;

	char *primary_path = malloc(bufsize);
	char *private_path = malloc(bufsize);
	if(!primary_path || !private_path) {
		free(primary_path);
		free(private_path);
		return NULL;
	}

	Dl_info dli;
	if(!dladdr((void*)&get_config_path, &dli) || !dli.dli_fname || !dli.dli_fname[0]) {
		free(primary_path);
		free(private_path);
		return NULL;
	}

	int n = snprintf(primary_path, bufsize, "%s", dli.dli_fname);
	if(n < 0 || (size_t)n >= bufsize) {
		free(primary_path);
		free(private_path);
		return NULL;
	}
	char *slash = strrchr(primary_path, '/');
	if(!slash) {
		free(primary_path);
		free(private_path);
		return NULL;
	}
	*slash = '\0';

	// The dylib path identifies the canonical App Group route. LC_HOME_PATH is
	// only a migration fallback when no canonical configuration exists; allowing
	// a newer private copy to win would roll a shared app back after conversion.
	char *tweaks = NULL;
	size_t plen = strlen(primary_path);
	for (size_t i = plen; i >= 7; i--) {
		if (primary_path[i - 7] == '/' &&
			strncmp(primary_path + i - 7, "/Tweaks", 7) == 0 &&
			(primary_path[i] == '\0' || primary_path[i] == '/')) {
			tweaks = primary_path + i - 7;
			break;
		}
	}
	if (tweaks) {
		*tweaks = '\0';
		if (strlen(primary_path) + sizeof("/LCProxy/" PROXYCHAINS_CONF_FILE) <= bufsize) {
			strncat(primary_path, "/LCProxy/" PROXYCHAINS_CONF_FILE, bufsize - strlen(primary_path) - 1);
		} else {
			free(primary_path);
			free(private_path);
			return NULL;
		}
	} else {
		const char *base = strrchr(primary_path, '/');
		base = base ? base + 1 : primary_path;
		if(strcmp(base, "LCProxy") == 0) {
			if(strlen(primary_path) + sizeof("/" PROXYCHAINS_CONF_FILE) <= bufsize) {
				strncat(primary_path, "/" PROXYCHAINS_CONF_FILE, bufsize - strlen(primary_path) - 1);
			} else {
				free(primary_path);
				free(private_path);
				return NULL;
			}
		} else {
			if(strlen(primary_path) + sizeof("/../LCProxy/" PROXYCHAINS_CONF_FILE) <= bufsize) {
				strncat(primary_path, "/../LCProxy/" PROXYCHAINS_CONF_FILE, bufsize - strlen(primary_path) - 1);
			} else {
				free(primary_path);
				free(private_path);
				return NULL;
			}
		}
	}

	struct stat primary_stat;
	struct stat private_stat;
	int has_primary = get_file_stat(primary_path, &primary_stat);
	int has_private = build_launch_private_config_path(private_path, bufsize) &&
		get_file_stat(private_path, &private_stat);
	const char *selected = NULL;
	if(has_primary)
		selected = primary_path;
	else if(has_private)
		selected = private_path;

	if(selected)
		snprintf(pbuf, bufsize, "%s", selected);
	free(primary_path);
	free(private_path);
	return selected ? pbuf : NULL;
}
