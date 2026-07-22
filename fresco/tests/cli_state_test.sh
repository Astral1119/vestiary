#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fresco-cli-state-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
export FRESCO_STATE_DIR="$TMP/state"
mkdir -p "$FRESCO_STATE_DIR"
printf '%s\n' '/legacy/wallpaper' > "$FRESCO_STATE_DIR/current"

swiftc \
  -O \
  -warnings-as-errors \
  -framework AppKit \
  -framework WebKit \
  -framework AVFoundation \
  -framework JavaScriptCore \
  "$ROOT/Fresco.swift" \
  "$ROOT/FrescoStatePlanner.swift" \
  "$ROOT/FrescoStateStore.swift" \
  "$ROOT/RuntimeAssignments.swift" \
  "$ROOT/FrescoObservation.swift" \
  "$ROOT/FrescoStatusPipeline.swift" \
  "$ROOT/SceneSupervisor.swift" \
  "$ROOT/WebWallpaperAudit.swift" \
  "$ROOT/FrescoMain.swift" \
  -o "$TMP/fresco-worker"

"$TMP/fresco-worker" --state-select workshop:fixture /resolved/fixture > "$TMP/select.json"
python3 - "$FRESCO_STATE_DIR" "$TMP/select.json" <<'PY'
import json
import pathlib
import sys

state_dir = pathlib.Path(sys.argv[1])
response = json.loads(pathlib.Path(sys.argv[2]).read_text())
state = json.loads((state_dir / "state.json").read_text())
assert response["revision"] == 2, response
assert state["revision"] == 2, state
assert state["desired"]["layout"] == {
    "mode": "clone",
    "binding": {"kind": "wallpaper", "target": "workshop:fixture"},
}, state
assert (state_dir / "current").read_text() == "/resolved/fixture\n"
PY

"$TMP/fresco-worker" --state-clear > "$TMP/clear.json"
python3 - "$FRESCO_STATE_DIR" "$TMP/clear.json" <<'PY'
import json
import pathlib
import sys

state_dir = pathlib.Path(sys.argv[1])
response = json.loads(pathlib.Path(sys.argv[2]).read_text())
state = json.loads((state_dir / "state.json").read_text())
assert response["revision"] == 3, response
assert state["revision"] == 3, state
assert state["desired"]["layout"] == {
    "mode": "clone",
    "binding": {"kind": "idle"},
}, state
assert (state_dir / "current").read_text() == ""
PY

"$TMP/fresco-worker" --state-muted true > "$TMP/mute.json"
python3 - "$FRESCO_STATE_DIR" "$TMP/mute.json" <<'PY'
import json
import pathlib
import sys

state_dir = pathlib.Path(sys.argv[1])
response = json.loads(pathlib.Path(sys.argv[2]).read_text())
state = json.loads((state_dir / "state.json").read_text())
assert response["revision"] == 4, response
assert response["muted"] is True, response
assert state["revision"] == 4, state
assert state["desired"]["controls"] == {"muted": True, "paused": False}, state
assert (state_dir / "current").read_text() == ""
PY

"$TMP/fresco-worker" --state-muted toggle > "$TMP/unmute.json"
python3 - "$FRESCO_STATE_DIR" "$TMP/unmute.json" <<'PY'
import json
import pathlib
import sys

state_dir = pathlib.Path(sys.argv[1])
response = json.loads(pathlib.Path(sys.argv[2]).read_text())
state = json.loads((state_dir / "state.json").read_text())
assert response["revision"] == 5, response
assert response["muted"] is False, response
assert state["desired"]["controls"] == {"muted": False, "paused": False}, state
PY

python3 "$ROOT/tests/cli_state_test.py"
echo "Fresco state transaction and migration checks passed"
