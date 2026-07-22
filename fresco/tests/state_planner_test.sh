#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fresco-state-planner.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT HUP INT TERM

swiftc \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -warnings-as-errors \
  "$ROOT/FrescoStatePlanner.swift" \
  "$ROOT/tests/FrescoStatePlannerTests.swift" \
  -o "$BUILD_DIR/state-planner-tests"

"$BUILD_DIR/state-planner-tests" "$ROOT/tests/fixtures"
