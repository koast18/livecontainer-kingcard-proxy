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
  Scripts/queen_wup_dump.m \
  -o build/queen-test/queen_wup_dump

./build/queen-test/queen_wup_dump > build/queen-test/native_wup.txt
python3 Scripts/compare_queen_wup.py > build/queen-test/python_wup.txt
diff -u build/queen-test/python_wup.txt build/queen-test/native_wup.txt
echo "WUP binary comparison OK"
