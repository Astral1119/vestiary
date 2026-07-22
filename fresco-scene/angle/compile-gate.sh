#!/bin/sh

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)

if [ "$#" -ne 1 ] || [ ! -d "$1/.git" ] || [ ! -f "$1/include/GLES3/gl3.h" ]; then
    echo "usage: $0 ANGLE_CHECKOUT" >&2
    exit 64
fi

checkout=$(CDPATH= cd -- "$1" && pwd)
expected_revision=$(tr -d '\n' < "$here/REVISION")
actual_revision=$(git -C "$checkout" rev-parse HEAD)
if [ "$actual_revision" != "$expected_revision" ]; then
    echo "fail: ANGLE checkout must be $expected_revision; found $actual_revision" >&2
    exit 1
fi

build=$(mktemp -d "${TMPDIR:-/tmp}/fresco-angle-core.XXXXXX")
trap 'rm -rf "$build"' EXIT HUP INT TERM

set -- cmake -S "$root" -B "$build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF \
    -DFRESCO_SCENE_BUILD_RENDERER=ON \
    -DFRESCO_SCENE_RENDER_BACKEND=angle-gles-compile \
    -DFRESCO_SCENE_ANGLE_INCLUDE_DIR="$checkout/include"
if [ -n "${FRESCO_SCENE_RENDERER_UPSTREAM:-}" ]; then
    set -- "$@" \
        -DFRESCO_SCENE_RENDERER_UPSTREAM="$FRESCO_SCENE_RENDERER_UPSTREAM"
fi
"$@"
cmake --build "$build" --target fresco-scene-renderer-gles-compile --parallel
