#!/bin/bash
# LCProxyDiagnosis 单元测试（需要 macOS + Foundation，因此只在 CI 上跑）。
#
# 诊断函数是纯函数，所以它可以在 CI 里做**真实的运行时断言** —— 这很重要：本项目的多数
# 误判发生在"读状态、下结论"这一步，而不是数据缺失。把判断逻辑用真实用例锁住，比再加
# 十个状态字段更能防止重复犯错。
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build/diagnosis-test

/usr/bin/clang -fobjc-arc \
  -ITweak/Sources \
  Scripts/test_lcproxy_diagnosis.m \
  Tweak/Sources/LCProxyDiagnosis.m \
  -framework Foundation \
  -o build/diagnosis-test/diagnosis_test

./build/diagnosis-test/diagnosis_test