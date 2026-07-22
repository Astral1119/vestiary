#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fresco-playlist-cursor.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

swiftc \
  -O \
  -warnings-as-errors \
  "$ROOT/FrescoStatePlanner.swift" \
  "$ROOT/PlaylistRuntimeCursor.swift" \
  "$ROOT/tests/PlaylistRuntimeCursorTests.swift" \
  -o "$TMP/playlist-runtime-cursor-tests"

"$TMP/playlist-runtime-cursor-tests"
