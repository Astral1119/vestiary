#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fresco-runtime-assignments-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

swiftc \
  -O \
  -warnings-as-errors \
  "$ROOT/FrescoStatePlanner.swift" \
  "$ROOT/RuntimeAssignments.swift" \
  "$ROOT/tests/RuntimeAssignmentsTests.swift" \
  -o "$TMP/fresco-runtime-assignments-tests"

"$TMP/fresco-runtime-assignments-tests"
