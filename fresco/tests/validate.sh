#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fresco-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

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

"$ROOT/tests/state_store_test.sh"
"$ROOT/tests/runtime_assignments_test.sh"
"$ROOT/tests/playlist_runtime_cursor_test.sh"
"$ROOT/tests/status_pipeline_test.sh"
"$ROOT/tests/cli_state_test.sh"

"$TMP/fresco-worker" --self-test-agent-counts
"$TMP/fresco-worker" --self-test-per-display-properties
"$TMP/fresco-worker" --self-test-project-entry-resolution
"$TMP/fresco-worker" --self-test-audio-layout
"$TMP/fresco-worker" \
  --self-test-web-properties \
  "$ROOT/tests/fixtures/web-properties"
"$TMP/fresco-worker" \
  --self-test-property-model \
  "$ROOT/tests/fixtures/web-properties"
"$TMP/fresco-worker" --self-test-web-bridge
"$TMP/fresco-worker" --self-test-scene-supervisor
"$TMP/fresco-worker" --self-test-scene-audio
"$TMP/fresco-worker" \
  --self-test-scene-resolution \
  "$ROOT/tests/fixtures/scene-project"
FRESCO_STATE_DIR="$TMP/scene-property-state" \
  "$TMP/fresco-worker" \
  --self-test-scene-properties \
  "$TMP/scene-property-project"

"$TMP/fresco-worker" \
  --audit-web \
  "$ROOT/tests/fixtures/web-properties" \
  "$TMP/web-audit-pass.json" \
  "$TMP/web-audit-pass.png"
python3 - "$TMP/web-audit-pass.json" "$TMP/web-audit-pass.png" <<'PY'
import json
import os
import sys

with open(sys.argv[1]) as handle:
    report = json.load(handle)
assert report["verdict"] == "pass", report
assert report["render"]["nonBlank"] is True, report
assert os.path.getsize(sys.argv[2]) > 0
PY

"$TMP/fresco-worker" \
  --audit-web \
  "$ROOT/tests/fixtures/web-audit-uniform" \
  "$TMP/web-audit-warning.json" \
  "$TMP/web-audit-warning.png"
python3 - "$TMP/web-audit-warning.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    report = json.load(handle)
assert report["verdict"] == "warning", report
assert "uniform render" in report["warnings"], report
PY

if "$TMP/fresco-worker" \
  --audit-web \
  "$ROOT/tests/fixtures/web-audit-broken" \
  "$TMP/web-audit-fail.json" \
  "$TMP/web-audit-fail.png"
then
  echo "broken web audit unexpectedly passed" >&2
  exit 1
fi
python3 - "$TMP/web-audit-fail.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    report = json.load(handle)
assert report["verdict"] == "fail", report
assert "required local resource failure" in report["failureReasons"], report
assert "broken local image" in report["failureReasons"], report
PY

"$TMP/fresco-worker" \
  --audit-web \
  "$ROOT/tests/fixtures/web-audit-apis" \
  "$TMP/web-audit-apis.json" \
  "$TMP/web-audit-apis.png"
python3 - "$TMP/web-audit-apis.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    report = json.load(handle)
diagnostics = report["page"]["diagnostics"]
assert report["verdict"] == "pass", report
assert {request["api"] for request in diagnostics["network"]} == {"fetch", "xhr"}, report
assert "fresco-audit-local" in diagnostics["storage"]["local"]["keys"], report
assert "fresco-audit-session" in diagnostics["storage"]["session"]["keys"], report
requests = diagnostics["storage"]["indexedDB"]["requests"]
assert any(request["name"] == "fresco-audit-fixture" for request in requests), report
assert any(entry["arguments"][0] == "api fixture started"
           for entry in diagnostics["console"]), report
assert any(entry["arguments"][0] == "fetch complete"
           for entry in diagnostics["console"]), report
assert any(entry["arguments"][0] == "xhr complete"
           for entry in diagnostics["console"]), report
assert report["page"]["fixtureCleanupScheduled"] is True, report
PY

"$TMP/fresco-worker" \
  --audit-web \
  "$ROOT/tests/fixtures/web-audit-media" \
  "$TMP/web-audit-media.json" \
  "$TMP/web-audit-media.png"
python3 - "$TMP/web-audit-media.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    report = json.load(handle)
diagnostics = report["page"]["diagnostics"]
assert report["verdict"] == "pass", report
fonts = {font["family"].strip('"'): font["status"] for font in diagnostics["fonts"]}
assert fonts["AuditTTF"] == "loaded", report
assert fonts["AuditWOFF2"] == "loaded", report
media = diagnostics["media"]
assert len(media["elements"]) == 3, report
assert all(element["readyState"] == 4 and element["errorCode"] is None
           for element in media["elements"]), report
assert {element["url"].rsplit('.', 1)[-1] for element in media["elements"]} == {
    "ogg", "webm", "mp4"
}, report
assert set(media["canPlayType"]) == {
    'audio/ogg; codecs="vorbis"',
    'audio/ogg; codecs="opus"',
    'video/webm; codecs="vp8, vorbis"',
    'video/webm; codecs="vp9, opus"',
    'video/mp4; codecs="avc1.42E01E, mp4a.40.2"',
}, report
assert all(media["canPlayType"].values()), report
assert media["errors"] == [], report
PY

"$TMP/fresco-worker" \
  --audit-web \
  "$ROOT/tests/fixtures/web-audit-webgl" \
  "$TMP/web-audit-webgl.json" \
  "$TMP/web-audit-webgl.png"
python3 - "$TMP/web-audit-webgl.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    report = json.load(handle)
diagnostics = report["page"]["diagnostics"]
assert report["verdict"] == "pass", report
contexts = [event for event in diagnostics["webgl"]["events"]
            if event["event"] == "context" and event["available"]]
assert {context["actual"] for context in contexts} >= {"webgl", "webgl2"}, report
assert all(shader["compiled"] for context in contexts for shader in context["shaders"]), report
assert all(program["linked"] for context in contexts for program in context["programs"]), report
canvases = diagnostics["webgl"]["canvases"]
assert len(canvases) >= 2, report
assert all(canvas.get("uniqueQuantizedColors", 0) >= 3 for canvas in canvases[:2]), report
assert report["render"]["uniqueQuantizedColors"] >= 6, report
assert any(event["event"] == "contextlost" for event in diagnostics["webgl"]["events"]), report
PY

swiftc \
  -O \
  -warnings-as-errors \
  "$ROOT/FrescoHost.swift" \
  -o "$TMP/fresco-host"

python3 "$ROOT/tests/workshop_test.py"
python3 "$ROOT/tests/property_test.py"
python3 "$ROOT/tests/scene_fixture_test.py"
python3 "$ROOT/tests/scene_cli_test.py"
python3 "$ROOT/tests/state_contract_test.py"
"$ROOT/tests/state_planner_test.sh"
python3 -m py_compile "$ROOT/fresco" "$ROOT/workshop"
sh -n "$ROOT/run" "$ROOT/fetch-samples"
plutil -lint "$ROOT/HostInfo.plist" >/dev/null

sh "$ROOT/../fresco-scene/tests/validate.sh"
