#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$ROOT/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/livery-adapters.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

mkdir -p "$TEST_ROOT/config/vestiary" "$TEST_ROOT/rendered"
TARGETS_CONFIG="$TEST_ROOT/config/vestiary/targets.json"

printf '%s\n' '{"enabled":["css"]}' > "$TARGETS_CONFIG"
targets=$(LIVERY_TARGETS_CONFIG="$TARGETS_CONFIG" "$ROOT/liveryctl" targets)
printf '%s\n' "$targets" | grep -Eq '^css[[:space:]]+enabled[[:space:]]'
printf '%s\n' "$targets" | grep -Eq '^tmux[[:space:]]+disabled[[:space:]]'

mkdir -p "$TEST_ROOT/adapters-first" "$TEST_ROOT/adapters-second"
cp "$REPO_ROOT/adapters/css" "$TEST_ROOT/adapters-first/example"
cp "$REPO_ROOT/adapters/css" "$TEST_ROOT/adapters-second/example"
chmod +x "$TEST_ROOT/adapters-first/example" "$TEST_ROOT/adapters-second/example"
external_targets=$(LIVERY_ADAPTER_PATH="$TEST_ROOT/adapters-first:$TEST_ROOT/adapters-second:$REPO_ROOT/adapters" \
  LIVERY_TARGETS_CONFIG="$TEST_ROOT/no-targets.json" \
  "$ROOT/liveryctl" targets)
printf '%s\n' "$external_targets" \
  | grep -Fq "example$(printf '\t')enabled$(printf '\t')$TEST_ROOT/adapters-first/example"

printf '%s\n' '{"enabled":["css","tmux"],"disabled":["tmux"]}' > "$TARGETS_CONFIG"
if LIVERY_TARGETS_CONFIG="$TARGETS_CONFIG" "$ROOT/liveryctl" targets >/dev/null 2>&1; then
  echo "overlapping target selection unexpectedly passed" >&2
  exit 1
fi

for invalid_targets in \
  '{"enabled":null}' \
  '{"enabled":["not-a-real-adapter"]}'; do
  printf '%s\n' "$invalid_targets" > "$TARGETS_CONFIG"
  if LIVERY_TARGETS_CONFIG="$TARGETS_CONFIG" "$ROOT/liveryctl" targets >/dev/null 2>&1; then
    echo "invalid target selection unexpectedly passed: $invalid_targets" >&2
    exit 1
  fi
done

printf '%s\n' '{"disabled":["tmux"]}' > "$TARGETS_CONFIG"
targets=$(LIVERY_TARGETS_CONFIG="$TARGETS_CONFIG" "$ROOT/liveryctl" targets)
printf '%s\n' "$targets" | grep -Eq '^css[[:space:]]+enabled[[:space:]]'
printf '%s\n' "$targets" | grep -Eq '^tmux[[:space:]]+disabled[[:space:]]'

printf '%s\n' '{"enabled":["css"]}' > "$TARGETS_CONFIG"
LIVERY_CONFIG_ROOT="$TEST_ROOT/config" \
  LIVERY_TARGETS_CONFIG="$TARGETS_CONFIG" \
  "$ROOT/liveryctl" resolve default > "$TEST_ROOT/manifest.json"
"$REPO_ROOT/adapters/css" render \
  "$TEST_ROOT/manifest.json" "$TEST_ROOT/rendered" >/dev/null
"$REPO_ROOT/adapters/css" validate "$TEST_ROOT/rendered" >/dev/null
grep -Eq '^  --vestiary-ui-background: #[0-9a-f]{6};$' \
  "$TEST_ROOT/rendered/vestiary.css"
grep -Eq '^  --vestiary-ui-background-rgb: [0-9]+ [0-9]+ [0-9]+;$' \
  "$TEST_ROOT/rendered/vestiary.css"

jq 'del(.fonts)' "$TEST_ROOT/manifest.json" > "$TEST_ROOT/manifest-no-fonts.json"
"$REPO_ROOT/adapters/css" render \
  "$TEST_ROOT/manifest-no-fonts.json" "$TEST_ROOT/rendered" >/dev/null
"$REPO_ROOT/adapters/css" validate "$TEST_ROOT/rendered" >/dev/null
if grep -q -- '--vestiary-fonts-' "$TEST_ROOT/rendered/vestiary.css"; then
  echo "fontless manifest unexpectedly emitted font properties" >&2
  exit 1
fi

jq '.schemaVersion = 99' "$TEST_ROOT/manifest.json" > "$TEST_ROOT/manifest-unsupported.json"
mkdir -p "$TEST_ROOT/unsupported-render"
if ! "$REPO_ROOT/adapters/css" render \
  "$TEST_ROOT/manifest-unsupported.json" "$TEST_ROOT/unsupported-render" >/dev/null 2>&1; then
  echo "unsupported manifest did not no-op successfully" >&2
  exit 1
fi
if [ -e "$TEST_ROOT/unsupported-render/vestiary.css" ]; then
  echo "unsupported manifest unexpectedly emitted CSS" >&2
  exit 1
fi

for adapter in borders css ghostty nvim sketchybar tmux; do
  "$ROOT/liveryctl" adapter-check "$adapter" >/dev/null
done

if command -v node >/dev/null 2>&1; then
  node "$REPO_ROOT/integrations/vscode/test/extension.test.js"
fi

echo "adapter integration checks passed"
