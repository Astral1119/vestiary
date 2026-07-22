#!/usr/bin/env python3

import json
import os
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "persona-shared-time-state"


def message(message_type, **values):
    return {
        "protocolVersion": 1,
        "type": message_type,
        "assignmentID": ASSIGNMENT,
        **values,
    }


persona = os.path.join(WORKSHOP, "3151551777")
assert os.path.isfile(os.path.join(persona, "scene.pkg")), persona
load = message(
    "load",
    path=persona,
    assetRoot=ASSETS,
    width=320,
    height=180,
    visible=True,
    evidenceFrames=2,
)
commands = [
    load,
    message("user-properties", properties={"timeofday": {"value": "2"}}),
    message("capture-frame-difference"),
    message("pause"),
    message("user-properties", properties={"timeofday": {"value": "1"}}),
    message("metrics"),
    message("resume"),
    message("capture-frame-difference"),
    load,
    message("metrics"),
    message("stop"),
]
environment = os.environ.copy()
environment["FRESCO_SCENE_SCRIPT_CLOCK_HOUR"] = "9"
result = subprocess.run(
    [HELPER],
    input="".join(json.dumps(command) + "\n" for command in commands),
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=60,
    check=True,
    env=environment,
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
    "ready",
    "metrics",
    "stopped",
], events
(
    ready,
    night_applied,
    night,
    _,
    sunset_applied,
    paused,
    _,
    sunset,
    reloaded,
    reloaded_metrics,
    _,
) = events

for event in (ready, night, paused, sunset, reloaded, reloaded_metrics):
    assert event["backend"] == EXPECTED_BACKEND, event
    assert event["genericPropertyScripts"] == 137, event
    assert event["genericPropertyScriptErrors"] == 0, event
    assert event["scriptErrors"] == 0, event
assert ready["deferredScriptValues"] == 0, ready
assert ready["warnings"] == [], ready
assert night_applied["acceptedScriptProperties"] == 1, night_applied
assert night_applied["ignored"] == 0, night_applied
assert sunset_applied["acceptedScriptProperties"] == 1, sunset_applied
assert sunset_applied["ignored"] == 0, sunset_applied
assert (ready["genericPropertyScriptUpdates"], ready["genericPropertyScriptChanges"]) == (
    270,
    66,
), ready
assert (night["genericPropertyScriptUpdates"], night["genericPropertyScriptChanges"]) == (
    392,
    109,
), night
assert paused["paused"] is True, paused
assert (paused["genericPropertyScriptUpdates"], paused["genericPropertyScriptChanges"]) == (
    392,
    109,
), paused
assert (sunset["genericPropertyScriptUpdates"], sunset["genericPropertyScriptChanges"]) == (
    514,
    179,
), sunset
for event in (reloaded, reloaded_metrics):
    assert (
        event["genericPropertyScriptUpdates"],
        event["genericPropertyScriptChanges"],
    ) == (270, 66), event

print(
    f"SceneScript shared state passed: {EXPECTED_BACKEND} Persona consumers=59; "
    "night/sunset property lifecycle is deterministic"
)
