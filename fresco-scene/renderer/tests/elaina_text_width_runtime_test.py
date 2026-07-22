#!/usr/bin/env python3

import json
import os
import re
import subprocess
import sys
import time


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ELAINA = os.path.join(WORKSHOP, "3326873240")
ASSIGNMENT = "elaina-text-width-runtime"
TRACE = re.compile(
    r"text-width object=(160|161) full=(\d+) offset=(\d+) visible=(\d+) "
    r"left=(-?[\d.]+) right=(-?[\d.]+) alignment=(left|right) "
    r"maxwidth=(-?[\d.]+)"
)


def message(request_type, **values):
    return {
        "protocolVersion": 1,
        "type": request_type,
        "assignmentID": ASSIGNMENT,
        **values,
    }


environment = os.environ.copy()
environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
environment["FRESCO_SCENE_TRACE_TEXT_WIDTH"] = "1"
process = subprocess.Popen(
    [HELPER],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
    env=environment,
)


def exchange(request_type, expected=None, **values):
    process.stdin.write(json.dumps(message(request_type, **values)) + "\n")
    process.stdin.flush()
    line = process.stdout.readline()
    assert line, (request_type, process.stderr.read())
    event = json.loads(line)
    assert event["type"] == (expected or request_type), event
    assert event["assignmentID"] == ASSIGNMENT, event
    return event


ready = exchange(
    "load",
    "ready",
    path=ELAINA,
    assetRoot=ASSETS,
    width=320,
    height=180,
    fps=60,
    visible=True,
    muted=True,
    evidenceFrames=2,
    userProperties={"newproperty67": {"value": False}},
)
assert ready["backend"] == EXPECTED_BACKEND, ready
assert ready["genericPropertyScripts"] == 88, ready
assert ready["mediaPropertyScripts"] == 2, ready
assert ready["deferredScriptValues"] == 0, ready
assert ready["warnings"] == [], ready

enabled = exchange(
    "user-properties",
    "user-properties-applied",
    properties={"newproperty67": {"value": True}},
)
assert enabled["acceptedScriptProperties"] == 1 and enabled["ignored"] == 0
exchange("media-session", "media-session-applied", kind="playback", payload={"state": 1})
long_text = "W" * 3000
exchange(
    "media-session",
    "media-session-applied",
    kind="properties",
    payload={"title": long_text, "artist": long_text, "albumTitle": ""},
)
exchange("capture-frame-difference", "frame-difference")

down = exchange("cursor-down", "cursor-event-dispatched", x=10, y=90)
assert down["handled"] == 2, down
for _ in range(6):
    time.sleep(0.06)
    exchange("capture-frame-difference", "frame-difference")
move = exchange("cursor-move", "cursor-event-dispatched", x=1000, y=90)
assert move["handled"] == 1, move
time.sleep(0.08)
changed = exchange("capture-frame-difference", "frame-difference")
assert changed["changedPixels"] > 0, changed
up = exchange("cursor-up", "cursor-event-dispatched", x=1000, y=90)
assert up["handled"] == 2, up

metrics = exchange("metrics")
for field in (
    "scriptErrors",
    "mediaPropertyScriptErrors",
    "propertyScriptErrors",
    "genericPropertyScriptErrors",
):
    assert metrics[field] == 0, (field, metrics)
exchange("stop", "stopped")
process.stdin.close()
process.wait(timeout=10)
assert process.returncode == 0, process.returncode

stderr = process.stderr.read()
unexpected = [
    line
    for line in stderr.splitlines()
    if not line.startswith("text-width object=")
    and not line.startswith("text-width-layout object=")
]
assert unexpected == [], unexpected
records = [
    {
        "object": int(match.group(1)),
        "full": int(match.group(2)),
        "offset": int(match.group(3)),
        "visible": int(match.group(4)),
        "left": float(match.group(5)),
        "right": float(match.group(6)),
        "alignment": match.group(7),
        "maxwidth": float(match.group(8)),
    }
    for match in TRACE.finditer(stderr)
]
for object_id in (160, 161):
    object_records = [record for record in records if record["object"] == object_id]
    empty = next(record for record in object_records if record["maxwidth"] < 0)
    assert empty["visible"] == 0 and empty["offset"] == empty["full"], empty
    positive = next(
        record
        for record in object_records
        if record["maxwidth"] > 0 and record["full"] > record["visible"] > 0
    )
    assert positive["alignment"] == "right", positive
    assert positive["offset"] == positive["full"] - positive["visible"], positive
    assert positive["left"] == -positive["visible"], positive
    assert positive["right"] == 0.0, positive

print(
    "Elaina text width runtime: finite no-space state, root-drag maxwidth update, "
    "right-anchored hard crop, and framebuffer change"
)
