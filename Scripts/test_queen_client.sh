#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/queen-test
clang -fobjc-arc -O0 -g \
  -framework Foundation -lz \
  -ITweak/Sources -ITweak/ProxyCore/src \
  Tweak/Sources/LCProxyKingClient.m \
  Tweak/Sources/KPKCrypto.c \
  Tweak/Sources/KPKQueenCore.c \
  Tweak/Sources/KPSocketHookShim.c \
  Scripts/queen_client_test.m \
  -o build/queen-test/queen_client_test
./build/queen-test/queen_client_test "$@"
