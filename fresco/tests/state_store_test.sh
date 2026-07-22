#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fresco-state-store-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

swiftc \
  -O \
  -warnings-as-errors \
  "$ROOT/FrescoStatePlanner.swift" \
  "$ROOT/FrescoStateStore.swift" \
  "$ROOT/tests/FrescoStateStoreTests.swift" \
  -o "$TMP/fresco-state-store-tests"

"$TMP/fresco-state-store-tests"
