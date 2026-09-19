#!/usr/bin/env bash
# Compile and run the input-layer unit tests (scripts/input_tests.swift).
#
# Only InputSanitizer.swift + TextSanitizer.swift are compiled alongside the test file:
# both are deliberately free of AppKit, Accessibility and TyperApp state, so the key
# classification, the harmless-chord list, the rejected-suggestion match and the
# learnable-span bookkeeping can all be exercised with no window server, no Accessibility
# grant and no running app. Exits non-zero on the first failing assertion set.
#
# The test file lives in scripts/ (NOT scripts/typer/), so the app build's
# `scripts/typer/*.swift` glob never picks it up, and the binary is built in a scratch
# directory, never in the repo.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${TYPER_TEST_DIR:-${TMPDIR:-/tmp}/typer-input-tests}"
mkdir -p "$OUT_DIR"
BIN="$OUT_DIR/input-tests"

echo "==> Building input tests -> $BIN"
swiftc "$ROOT_DIR/scripts/typer/InputSanitizer.swift" \
       "$ROOT_DIR/scripts/typer/TextSanitizer.swift" \
       "$ROOT_DIR/scripts/input_tests.swift" \
       -o "$BIN"

echo "==> Running"
"$BIN"
