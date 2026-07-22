#!/bin/sh

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
revision=$(tr -d '\n' < "$here/REVISION")

if [ "$#" -ne 1 ]; then
    echo "usage: $0 ANGLE_CHECKOUT" >&2
    exit 64
fi
git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "fail: ANGLE checkout is not a git worktree: $1" >&2
    exit 1
}

checkout=$(CDPATH= cd -- "$1" && pwd)
actual_revision=$(git -C "$checkout" rev-parse HEAD)
if [ "$actual_revision" != "$revision" ]; then
    echo "fail: ANGLE checkout must be $revision; found $actual_revision" >&2
    exit 1
fi

library_dir="$checkout/out/fresco-metal"
for library in libEGL.dylib libGLESv2.dylib; do
    path="$library_dir/$library"
    test -f "$path" || {
        echo "fail: missing $path" >&2
        exit 1
    }
    case "$(lipo -archs "$path")" in
        *arm64*) ;;
        *)
            echo "fail: $path does not contain arm64" >&2
            exit 1
            ;;
    esac
    install_name=$(otool -D "$path" | sed -n '2p')
    test "$install_name" = "./$library" || {
        echo "fail: $path install name must be ./$library; found $install_name" >&2
        exit 1
    }
done

asset_root=${FRESCO_SCENE_ASSETS:-"${HOME}/Library/Application Support/Fresco/Wallpaper Engine/assets"}
workshop_root=${FRESCO_SCENE_WORKSHOP_ROOT:-"${HOME}/Library/Application Support/Steam/steamapps/workshop/content/431960"}
test -d "$asset_root" || {
    echo "fail: Wallpaper Engine assets are missing: $asset_root" >&2
    exit 1
}
test -d "$workshop_root" || {
    echo "fail: Workshop root is missing: $workshop_root" >&2
    exit 1
}

build=$(mktemp -d "${TMPDIR:-/tmp}/fresco-angle-validate.XXXXXX")
trap 'rm -rf "$build"' EXIT HUP INT TERM

set -- cmake -S "$root" -B "$build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=ON \
    -DFRESCO_SCENE_BUILD_RENDERER=ON \
    -DFRESCO_SCENE_RENDER_BACKEND=angle-metal \
    -DFRESCO_SCENE_ANGLE_INCLUDE_DIR="$checkout/include" \
    -DFRESCO_SCENE_ANGLE_LIBRARY_DIR="$library_dir" \
    -DFRESCO_SCENE_ASSETS="$asset_root" \
    -DFRESCO_SCENE_WORKSHOP_ROOT="$workshop_root"
if [ -n "${FRESCO_SCENE_RENDERER_UPSTREAM:-}" ]; then
    set -- "$@" \
        -DFRESCO_SCENE_RENDERER_UPSTREAM="$FRESCO_SCENE_RENDERER_UPSTREAM"
fi
"$@"
cmake --build "$build" --parallel
"$here/probe.sh" runtime "$library_dir"

install_log="$build/angle-install.log"
if cmake --install "$build" >"$install_log" 2>&1; then
    echo "fail: angle-metal installation unexpectedly succeeded" >&2
    exit 1
fi
grep -F \
    "angle-metal installation is unsupported" \
    "$install_log" >/dev/null || {
        cat "$install_log" >&2
        echo "fail: angle-metal installation did not return the expected diagnostic" >&2
        exit 1
    }
echo "pass: angle-metal installation is explicitly unsupported"

ctest --test-dir "$build" \
    --tests-regex '^(fresco-scene-protocol|fresco-scene-renderer-audio-spectrum|fresco-scene-renderer-sound-registry|fresco-scene-renderer-sound-script-bridge|fresco-scene-renderer-sound-corpus|fresco-scene-renderer-sound-restart|fresco-scene-renderer-sound-av-lifecycle|fresco-scene-renderer-helper|fresco-scene-renderer-performance|fresco-scene-renderer-angle-temporal|fresco-scene-renderer-particle-child-visual-ab)$' \
    --output-on-failure
grep -F \
    "particle child visual A/B:" \
    "$build/Testing/Temporary/LastTest.log"
