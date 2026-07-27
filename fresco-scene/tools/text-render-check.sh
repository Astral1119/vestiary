#!/bin/sh
# Render corpus fixtures to PNG so text changes can be eyeballed against a
# baseline build. Renders the current tree, and a git ref for comparison when
# one is given.
#
#   tools/text-render-check.sh                 # current tree only
#   tools/text-render-check.sh HEAD~1          # current tree vs HEAD~1
#
# Output lands in .fresco-evidence/text-render-check/ (ignored, outside Git).
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
REPO=$(CDPATH='' cd -- "$ROOT/.." && pwd)
BASE_REF=${1:-}

ASSETS=${FRESCO_SCENE_ASSETS:-"${HOME}/Library/Application Support/Fresco/Wallpaper Engine/assets"}
WORKSHOP=${FRESCO_SCENE_WORKSHOP_ROOT:-"${HOME}/Library/Application Support/Steam/steamapps/workshop/content/431960"}
OUT="$REPO/.fresco-evidence/text-render-check"
FRAMES=${FRAMES:-30}

# Text-carrying corpus fixtures, as id:label.
FIXTURES="2999232230:clockjs 3299228616:lonelycat 3460973721:arknights"

build () {
  src=$1
  dir=$2
  cmake -S "$src" -B "$dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DFRESCO_SCENE_BUILD_RENDERER=ON \
    -DFRESCO_SCENE_ASSETS="$ASSETS" \
    -DFRESCO_SCENE_WORKSHOP_ROOT="$WORKSHOP" >/dev/null
  cmake --build "$dir" --target fresco-scene-render-smoke --parallel >/dev/null
}

render () {
  smoke=$1
  suffix=$2
  for fixture in $FIXTURES; do
    id=${fixture%%:*}
    label=${fixture##*:}
    printf '%-12s %-8s ' "$label" "$suffix"
    "$smoke" "$WORKSHOP/$id" "$ASSETS" "$OUT/$label-$suffix.png" "$FRAMES" 2>/dev/null \
      | tr ' ' '\n' | grep -E '^varyingPixels=' || echo "(render failed)"
  done
}

mkdir -p "$OUT"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fresco-text-check.XXXXXX")
trap 'rm -rf "$WORK"; [ -n "$BASE_REF" ] && git -C "$REPO" worktree prune || true' EXIT HUP INT TERM

echo "building current tree"
build "$ROOT" "$WORK/current"

if [ -n "$BASE_REF" ]; then
  echo "building $BASE_REF"
  git -C "$REPO" worktree add --detach "$WORK/base" "$BASE_REF" >/dev/null 2>&1
  build "$WORK/base/fresco-scene" "$WORK/base-build"
  render "$WORK/base-build/renderer/fresco-scene-render-smoke" before
fi
render "$WORK/current/renderer/fresco-scene-render-smoke" after

echo
echo "PNGs in $OUT"
echo "open them with:  open $OUT"
