#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/fresco-scene-build.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

ASSET_ROOT=${FRESCO_SCENE_ASSETS:-"${HOME}/Library/Application Support/Fresco/Wallpaper Engine/assets"}
WORKSHOP_ROOT=${FRESCO_SCENE_WORKSHOP_ROOT:-"${HOME}/Library/Application Support/Steam/steamapps/workshop/content/431960"}

if [ -d "$ASSET_ROOT" ] && [ -d "$WORKSHOP_ROOT" ]; then
  cmake -S "$ROOT" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=ON \
    -DFRESCO_SCENE_BUILD_RENDERER=ON \
    -DFRESCO_SCENE_ASSETS="$ASSET_ROOT" \
    -DFRESCO_SCENE_WORKSHOP_ROOT="$WORKSHOP_ROOT"
else
  cmake -S "$ROOT" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON
fi
cmake --build "$BUILD" --parallel
ctest --test-dir "$BUILD" --output-on-failure
python3 "$ROOT/tools/windows-gbc-capture/analyze_test.py"
