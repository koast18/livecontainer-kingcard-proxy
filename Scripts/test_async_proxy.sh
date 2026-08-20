#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/async-test
cc -std=c99 -O0 -g \
  -ITweak/ProxyCore/src \
  -ITweak/ProxyCore/vendor/proxychains-ng/src \
  Scripts/test_async_proxy.c \
  Tweak/ProxyCore/src/async_proxy.c \
  -lpthread -o build/async-test/async_proxy_test
./build/async-test/async_proxy_test
