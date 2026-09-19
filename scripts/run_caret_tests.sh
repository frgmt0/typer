#!/usr/bin/env bash
# Build and run the headless caret-geometry unit tests.
#
# Only CaretGeometry.swift + the test file are compiled — CaretGeometry is deliberately
# free of NSScreen/AX/global state, so the placement rules can be exercised without a
# window server, an Accessibility grant, or the rest of the app. Exits non-zero on the
# first failing check.
#
# The test file lives in scripts/ (NOT scripts/typer/), so the app build's
# `scripts/typer/*.swift` glob never picks it up.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${TYPER_TEST_DIR:-${TMPDIR:-/tmp}/typer-caret-tests}"
mkdir -p "$OUT_DIR"
BIN="$OUT_DIR/caret-tests"

echo "==> Building caret geometry tests -> $BIN"
swiftc "$ROOT_DIR/scripts/typer/CaretGeometry.swift" "$ROOT_DIR/scripts/caret_tests.swift" -o "$BIN"

echo "==> Running"
"$BIN"
