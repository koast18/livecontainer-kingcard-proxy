#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/queen-test
# LCProxyKingClient 的 KPKSyncPost 现调用 KPKIngCore.c 的
# kp_http_post_direct_len / kp_parse_http_response，需一并编译；
# IngCore.c 依赖 proxychains_write_log，宿主测试环境下用桩替代。
cat > build/queen-test/pc_log_stub.c <<'EOF'
#include <stdarg.h>
#include <stdio.h>
void proxychains_write_log(char *str, ...) {
    (void)str;
}
EOF

clang -fobjc-arc -O0 -g \
  -framework Foundation -framework CFNetwork -lz \
  -ITweak/Sources -ITweak/ProxyCore/src -ITweak/ProxyCore/vendor/proxychains-ng/src \
  Tweak/Sources/LCProxyKingClient.m \
  Tweak/Sources/KPKCrypto.c \
  Tweak/Sources/KPKQueenCore.c \
  Tweak/Sources/KPKIngCore.c \
  Tweak/Sources/KPSocketHookShim.c \
  build/queen-test/pc_log_stub.c \
  Scripts/queen_wup_dump.m \
  -o build/queen-test/queen_wup_dump

./build/queen-test/queen_wup_dump > build/queen-test/native_wup.txt
python3 Scripts/compare_queen_wup.py > build/queen-test/python_wup.txt
diff -u build/queen-test/python_wup.txt build/queen-test/native_wup.txt
echo "WUP binary comparison OK"
