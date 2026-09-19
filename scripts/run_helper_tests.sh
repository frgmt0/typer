#!/usr/bin/env bash
# Compile + run the helper's text-layer unit tests (scripts/helper_tests.cpp).
#
# Deliberately free of llama.cpp: the tested code lives in scripts/llama_server_text.h,
# so this needs nothing but clang++ and takes about a second. Run it after touching
# any of the JSON parsing, the scalar screen, or the completion quality gates.
#
# The binary is built in a scratch directory (override with TYPER_TEST_OUT), never
# in the repo.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${TYPER_TEST_OUT:-$(mktemp -d)}"
mkdir -p "$OUT_DIR"
BIN="$OUT_DIR/typer-helper-tests"

echo "==> Building helper tests -> $BIN"
clang++ -std=c++17 -O1 -Wall -Wextra \
  "$ROOT_DIR/scripts/helper_tests.cpp" \
  -I"$ROOT_DIR/scripts" \
  -o "$BIN"

echo "==> Running"
"$BIN"
