#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/async-test
CC_BIN="${CC:-cc}"
POSIX_SOURCE_FLAG=""
if [ "$(uname -s)" != "Darwin" ]; then
    # Linux/glibc needs this feature macro for nanosleep/clock_gettime. On
    # Darwin it hides INADDR_LOOPBACK and the sa_endpoints_t/connectx_t
    # declarations, so it must never be defined there.
    POSIX_SOURCE_FLAG="-D_POSIX_C_SOURCE=200809L"
fi
"$CC_BIN" -std=c99 -O0 -g \
  $POSIX_SOURCE_FLAG \
  -DGN_NODELEN_T=socklen_t -DGN_SERVLEN_T=socklen_t -DGN_FLAGS_T=int \
  -ITweak/ProxyCore/src \
  -ITweak/ProxyCore/vendor/proxychains-ng/src \
  Scripts/test_async_proxy.c \
  Tweak/ProxyCore/src/async_proxy.c \
  -o build/async-test/async_proxy_test
./build/async-test/async_proxy_test
