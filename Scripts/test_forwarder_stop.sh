#!/bin/bash
# Host-side regression test for the KingCard forwarder stop wedge.
#
# Reproduces: a relay thread blocked on a half-open upstream (recv after a 200
# response header, upstream silent forever) used to hang kp_forwarder_stop
# indefinitely, which wedged the lifecycle lock and left the app with no
# network until it was killed. The fix shuts down registered upstream fds and
# bounds the stop wait; this test asserts stop returns cleanly and fast.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/fw-test

CC_BIN="${CC:-cc}"

# KPKIngCore.c needs zlib (kp_gunzip). Most hosts have -lz; some minimal Linux
# sandboxes only ship zlib.h via node dev headers and no libz.so — fall back
# to inflate stubs there (gunzip is irrelevant to the stop semantics).
ZLIB_INCLUDE=""
ZLIB_LINK="-lz"
ZLIB_STUB=""
printf '#include <zlib.h>\nint main(void){return 0;}\n' > build/fw-test/zlib_probe.c
if ! $CC_BIN -std=gnu99 build/fw-test/zlib_probe.c -o build/fw-test/zlib_probe $ZLIB_LINK 2>/dev/null; then
    if [ -f /usr/include/node/zlib.h ]; then
        ZLIB_INCLUDE="-I/usr/include/node"
        ZLIB_LINK=""
        printf '%s\n' \
            '#include <zlib.h>' \
            'int inflateInit2_(z_streamp s, int w, const char *v, int sz) { (void)s;(void)w;(void)v;(void)sz; return Z_OK; }' \
            'int inflate(z_streamp s, int f) { (void)s;(void)f; return Z_STREAM_ERROR; }' \
            'int inflateEnd(z_streamp s) { (void)s; return Z_OK; }' \
            > build/fw-test/zlib_stubs.c
        ZLIB_STUB="build/fw-test/zlib_stubs.c"
    else
        echo "no usable zlib (need -lz or /usr/include/node/zlib.h), skipping" >&2
        exit 0
    fi
fi

# Host stubs for symbols provided by the dylib runtime on iOS.
printf '%s\n' \
    '#include <stdarg.h>' \
    'void proxychains_write_log(char *str, ...) { (void)str; }' \
    'void kp_socket_set_bypass(int on) { (void)on; }' \
    > build/fw-test/host_stubs.c

$CC_BIN -std=gnu99 -O1 -g \
  -ITweak/Sources \
  -ITweak/ProxyCore/src \
  $ZLIB_INCLUDE \
  Scripts/test_forwarder_stop.c \
  Tweak/Sources/KPKIngCore.c \
  build/fw-test/host_stubs.c \
  $ZLIB_STUB \
  $ZLIB_LINK \
  -pthread \
  -o build/fw-test/forwarder_stop_test

./build/fw-test/forwarder_stop_test
