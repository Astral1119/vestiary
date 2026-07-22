#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$ROOT/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/livery-desktop-sync.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

CONFIG_ROOT="$TEST_ROOT/config"
RUNTIME_ROOT="$CONFIG_ROOT/livery"
TARGETS_CONFIG="$CONFIG_ROOT/vestiary/targets.json"
FRESCO_LOG="$TEST_ROOT/fresco.log"
mkdir -p "$CONFIG_ROOT/vestiary" "$RUNTIME_ROOT/lock/looks"
printf '%s\n' '{"enabled":["css"]}' > "$TARGETS_CONFIG"
cp "$REPO_ROOT/livery/assets/warm-dunes.jpg" "$RUNTIME_ROOT/lock/looks/pinned.jpg"
jq -n --arg image "$RUNTIME_ROOT/lock/looks/pinned.jpg" '{
  schemaVersion: 1,
  source: "look",
  image: $image,
  selection: "wallpaper:warm-dunes:content"
}' > "$RUNTIME_ROOT/lock.json"

LIVERY_CONFIG_ROOT="$CONFIG_ROOT" \
LIVERY_RUNTIME_ROOT="$RUNTIME_ROOT" \
LIVERY_TARGETS_CONFIG="$TARGETS_CONFIG" \
LIVERY_SKIP_RELOAD=1 \
LIVERY_TEST_DESKTOP_SYNC=1 \
LIVERY_WALLPAPERCTL="$ROOT/tests/fake-fresco" \
LIVERY_TEST_FRESCO_LOG="$FRESCO_LOG" \
  "$ROOT/liveryctl" apply wallpaper:warm-dunes:content >/dev/null

grep -Eq '^set .*/wallpaper/[0-9a-f]{64}\.jpg$' "$FRESCO_LOG"

jq '.source = "theme"' "$RUNTIME_ROOT/lock.json" > "$TEST_ROOT/theme-lock.json"
mv "$TEST_ROOT/theme-lock.json" "$RUNTIME_ROOT/lock.json"
LIVERY_CONFIG_ROOT="$CONFIG_ROOT" \
LIVERY_RUNTIME_ROOT="$RUNTIME_ROOT" \
LIVERY_TARGETS_CONFIG="$TARGETS_CONFIG" \
LIVERY_SKIP_RELOAD=1 \
LIVERY_TEST_DESKTOP_SYNC=1 \
LIVERY_WALLPAPERCTL="$ROOT/tests/fake-fresco" \
LIVERY_TEST_FRESCO_LOG="$FRESCO_LOG" \
  "$ROOT/liveryctl" apply wallpaper:warm-dunes:content >/dev/null

[ "$(tail -n 1 "$FRESCO_LOG")" = "clear" ]
echo "desktop-layer sync checks passed"
