#!/usr/bin/env bash
# Compile and run the store-sanitation tests (TextSanitizer scalar policy,
# PersonalLexicon word shape, StoreMigration end to end on a synthetic fixture).
#
# Nothing here touches ~/Library/Application Support/typer: the fixtures are built in a
# throwaway directory, and the optional real-data pass runs against a COPY you point it
# at. Exits non-zero on the first failing assertion set.
#
# Usage:
#   scripts/run_store_tests.sh                    # synthetic fixtures only
#   scripts/run_store_tests.sh <store-copy-dir>   # also migrate a COPY of a real store dir
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TYPER_TEST_BUILD_DIR:-${TMPDIR:-/tmp}/typer-store-tests}"
mkdir -p "$BUILD_DIR"

# Only the files the harness actually needs, and only ones that compile standalone:
# TextSanitizer and StoreMigration are the units under test, PersonalLexicon carries the
# shared word-shape rule that the migration applies to lexicon.json, and TrainingLog is
# exercised directly (its write gate and its streaming roll) against a throwaway file.
SOURCES=(
  "$ROOT_DIR/scripts/typer/TextSanitizer.swift"
  "$ROOT_DIR/scripts/typer/StoreMigration.swift"
  "$ROOT_DIR/scripts/typer/PersonalLexicon.swift"
  "$ROOT_DIR/scripts/typer/TrainingLog.swift"
  "$ROOT_DIR/scripts/store_tests.swift"
)

echo "==> Building store tests"
swiftc "${SOURCES[@]}" -o "$BUILD_DIR/store-tests"

echo "==> Running store tests"
"$BUILD_DIR/store-tests" "$BUILD_DIR" "$@"
