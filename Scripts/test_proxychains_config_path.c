#include "common.h"

#include <stdio.h>
#include <string.h>

int main(int argc, char *argv[]) {
    if (argc != 2 && argc != 3) {
        fprintf(stderr, "usage: %s <expected path|NONE> [managed canonical path]\n", argv[0]);
        return 2;
    }

    if (argc == 3 && !lcproxy_control_set_config_path(argv[2])) {
        fprintf(stderr, "could not set managed canonical path\n");
        return 2;
    }

    char path[4096];
    char *actual = get_config_path(NULL, path, sizeof(path));
    if (strcmp(argv[1], "NONE") == 0) {
        if (actual) {
            fprintf(stderr, "expected no config, got %s\n", actual);
            return 1;
        }
        return 0;
    }
    if (!actual) {
        fprintf(stderr, "expected %s, got no config\n", argv[1]);
        return 1;
    }
    if (strcmp(actual, argv[1]) != 0) {
        fprintf(stderr, "expected %s, got %s\n", argv[1], actual);
        return 1;
    }
    return 0;
}
