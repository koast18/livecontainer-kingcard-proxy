#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/build_ios.sh
./Scripts/build_console.sh
echo "All artifacts in build/"
ls -lh build/*.dylib build/*.ipa
