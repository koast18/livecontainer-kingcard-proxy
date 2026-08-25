#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/queen-test
# 与 queen_wup_compare 一致：KingClient 依赖 KPKIngCore.c 与桩。
cat > build/queen-test/pc_log_stub.c <<'EOF'
#include <stdarg.h>
#include <stdio.h>
void proxychains_write_log(char *str, ...) {
    (void)str;
}
EOF

clang -fobjc-arc -O0 -g \
  -framework Foundation -lz \
  -ITweak/Sources -ITweak/ProxyCore/src -ITweak/ProxyCore/vendor/proxychains-ng/src \
  Tweak/Sources/LCProxyKingClient.m \
  Tweak/Sources/KPKCrypto.c \
  Tweak/Sources/KPKQueenCore.c \
  Tweak/Sources/KPKIngCore.c \
  Tweak/Sources/KPSocketHookShim.c \
  build/queen-test/pc_log_stub.c \
  Scripts/queen_client_test.m \
  -o build/queen-test/queen_client_test
./build/queen-test/queen_client_test "${1:-18812341234}"
