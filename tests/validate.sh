#!/bin/sh
set -eu

ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d /tmp/sketchybar-preview-validate.XXXXXX)
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

for command in jq python3 luac shellcheck; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'missing validation dependency: %s\n' "$command" >&2
    exit 1
  }
done

sh -n "$ROOT/live-preview"
shellcheck "$ROOT/live-preview" "$ROOT"/preview/providers/*.sh "$0"
python3 -c 'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' "$ROOT/preview/compile_manifest.py"
luac -p "$ROOT/preview/sketchybarrc" "$ROOT/preview/lib/theme.lua" "$ROOT/preview/lib/builder.lua"

ids=""
for concept in "$ROOT"/concepts/*/concept.json; do
  jq empty "$concept"
  id=$(jq -r '.id' "$concept")
  case " $ids " in *" $id "*) printf 'duplicate concept id: %s\n' "$id" >&2; exit 1 ;; esac
  ids="$ids $id"
  python3 "$ROOT/preview/compile_manifest.py" "$concept" "$TMP/$id.lua" --mode sample --placement bottom > "$TMP/$id.json"
  luac -p "$TMP/$id.lua"
  jq -e '.used + .headroom == 1728' "$TMP/$id.json" >/dev/null
done

if rg -n \
  -e 'killall' \
  -e 'pkill' \
  -e 'brew[[:space:]]+services' \
  -e 'launchctl' \
  -e 'pbcopy' \
  -e 'osascript' \
  -e 'yabai[[:space:]]+-m[[:space:]]+(config|window|space|rule|signal)' \
  "$ROOT/preview"; then
  printf 'forbidden side-effect command found in preview runtime\n' >&2
  exit 1
fi


if rg -n \
  -e 'yabai[[:space:]]+-m[[:space:]]+(window|space|rule|signal)' \
  "$ROOT/live-preview"; then
  printf 'forbidden yabai mutation found in preview controller\n' >&2
  exit 1
fi

count=$(find "$ROOT/concepts" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
printf 'Static validation passed for %s concepts.\n' "$count"
