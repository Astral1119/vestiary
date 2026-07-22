#!/bin/sh

set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
revision=$(tr -d '\n' < "$here/REVISION")
origin=https://chromium.googlesource.com/angle/angle

usage() {
    echo "usage: $0 preflight | build CHECKOUT | runtime ANGLE_LIBRARY_DIRECTORY | audit LINUX_WALLPAPERENGINE_CHECKOUT" >&2
    exit 64
}

preflight() {
    test "$(uname -m)" = arm64 || {
            echo "fail: probe requires an arm64 host" >&2
            exit 1
        }
    developer_dir=$(xcode-select -p)
    case "$developer_dir" in
        */Xcode.app/Contents/Developer) ;;
        *)
            echo "fail: full Xcode is not selected (found $developer_dir)" >&2
            exit 1
            ;;
    esac
    for tool in fetch gclient gn autoninja; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "fail: depot_tools command is missing: $tool" >&2
            exit 1
        }
    done
    echo "pass: arm64 ANGLE build prerequisites for $revision"
}

case "${1:-}" in
    preflight)
        preflight
        ;;
    build)
        test "$#" -eq 2 || usage
        checkout=$2
        preflight
        if [ -e "$checkout" ]; then
            git -C "$checkout" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
                echo "fail: existing checkout is not an ANGLE git worktree: $checkout" >&2
                exit 1
            }
            actual_origin=$(git -C "$checkout" remote get-url origin)
            test "$actual_origin" = "$origin" || {
                echo "fail: ANGLE checkout origin must be $origin; found $actual_origin" >&2
                exit 1
            }
            actual_revision=$(git -C "$checkout" rev-parse HEAD)
            test "$actual_revision" = "$revision" || {
                echo "fail: ANGLE checkout must be $revision; found $actual_revision" >&2
                exit 1
            }
            echo "resume: verified ANGLE checkout at $revision"
        else
            git clone "$origin" "$checkout"
            git -C "$checkout" checkout --detach "$revision"
        fi
        (
            cd "$checkout"
            python3 scripts/bootstrap.py
            gclient sync
            gn gen out/fresco-metal --args='target_cpu="arm64" is_component_build=false is_debug=false symbol_level=0 angle_build_all=false angle_enable_metal=true angle_enable_gl=false angle_enable_vulkan=false angle_enable_swiftshader=false angle_enable_wgpu=false angle_enable_null=false'
            autoninja -C out/fresco-metal libEGL libGLESv2
        )
        test "$(git -C "$checkout" rev-parse HEAD)" = "$revision" || {
            echo "fail: checkout moved away from pinned revision" >&2
            exit 1
        }
        "$0" runtime "$checkout/out/fresco-metal"
        ;;
    runtime)
        test "$#" -eq 2 || usage
        library_dir=$2
        test -f "$library_dir/libEGL.dylib" || {
            echo "fail: missing $library_dir/libEGL.dylib" >&2
            exit 1
        }
        test -f "$library_dir/libGLESv2.dylib" || {
            echo "fail: missing $library_dir/libGLESv2.dylib" >&2
            exit 1
        }
        output_dir=$(mktemp -d "${TMPDIR:-/tmp}/fresco-angle-probe.XXXXXX")
        trap 'rm -rf "$output_dir"' EXIT HUP INT TERM
        clang++ -std=c++20 -fobjc-arc -Wall -Wextra -Werror \
            -framework AppKit -framework QuartzCore \
            "$here/probe.mm" -o "$output_dir/fresco-angle-probe"
        "$output_dir/fresco-angle-probe" "$library_dir"
        ;;
    audit)
        test "$#" -eq 2 || usage
        python3 "$here/compatibility_audit.py" "$2"
        ;;
    *) usage ;;
esac
