#!/bin/bash
# Usage: compile.sh <harness.cpp> <output_binary>
# Compiles a libFuzzer harness with ASan against the ICU static libs.
set -euo pipefail

SRC="${1:?Usage: compile.sh <source.cpp> <output_binary>}"
OUT="${2:?Usage: compile.sh <source.cpp> <output_binary>}"
ICU_HOME="${ICU_HOME:-/opt/icu-install}"

clang++ \
    -std=c++17 \
    -fsanitize=address,fuzzer \
    -fno-omit-frame-pointer \
    -g -O1 \
    "-I${ICU_HOME}/include" \
    "$SRC" \
    "-L${ICU_HOME}/lib" \
    -licui18n -licuuc -licudata \
    -lstdc++ -lm -lpthread -ldl \
    -Wl,-rpath,"${ICU_HOME}/lib" \
    -o "$OUT"

echo "[+] Compiled: $OUT"
