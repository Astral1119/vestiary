#!/usr/bin/env python3

import json
import os
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
PERSONA = os.path.join(WORKSHOP, "3151551777")


def message(kind, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": "persona-scene-zoom",
        **values,
    }


commands = [
    message(
        "load",
        path=PERSONA,
        assetRoot=ASSETS,
        width=320,
        height=180,
        visible=True,
        evidenceFrames=2,
        userProperties={"trainshake": {"value": True}},
    ),
    message(
        "user-properties",
        properties={"trainshake": {"value": False}},
    ),
    message("capture-frame-difference"),
    message("pause"),
    message(
        "user-properties",
        properties={"trainshake": {"value": True}},
    ),
    message("metrics"),
    message("resume"),
    message("capture-frame-difference"),
    message("metrics"),
    message("stop"),
]
result = subprocess.run(
    [HELPER],
    input="".join(json.dumps(command) + "\n" for command in commands),
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=90,
    check=True,
)
assert not result.stderr, result.stderr
events = [json.loads(line) for line in result.stdout.splitlines()]
assert [event["type"] for event in events] == [
    "ready",
    "user-properties-applied",
    "frame-difference",
    "paused",
    "user-properties-applied",
    "metrics",
    "resumed",
    "frame-difference",
    "metrics",
    "stopped",
], events
ready, applied_off, off_frame, _, queued_on, paused, _, on_frame, resumed, _ = events

for event in (ready, off_frame, paused, on_frame, resumed):
    assert event["backend"] == EXPECTED_BACKEND, event
    assert event["sceneZoomActive"] is True, event
    assert event["camera2DZoom"] == 1, event
    assert event["genericPropertyScriptErrors"] == 0, event
    assert event["scriptErrors"] == 0, event

assert abs(ready["sceneZoom"] - 1.01) < 0.0001, ready
assert abs(off_frame["sceneZoom"] - 1.0) < 0.0001, off_frame
assert applied_off["acceptedScriptProperties"] == 1, applied_off
assert queued_on["acceptedScriptProperties"] == 1, queued_on
assert abs(paused["sceneZoom"] - 1.0) < 0.0001, paused
assert abs(on_frame["sceneZoom"] - 1.01) < 0.0001, on_frame
assert abs(resumed["sceneZoom"] - 1.01) < 0.0001, resumed

print(f"Persona semantic scene zoom lifecycle passed: {EXPECTED_BACKEND}")
