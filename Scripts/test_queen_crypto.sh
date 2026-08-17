#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/queen-test
clang -O0 -g -ITweak/Sources \
  Tweak/Sources/KPKCrypto.c \
  Scripts/queen_crypto_test.c \
  -lz -o build/queen-test/queen_crypto_test
./build/queen-test/queen_crypto_test
