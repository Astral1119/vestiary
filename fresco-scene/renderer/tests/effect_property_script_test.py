#!/usr/bin/env python3

import json
import os
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "persona-effect-properties"


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
    message(
        "user-properties",
        properties={"bgaudiobarsybounds": {"value": 0.25}},
    ),
    message("capture-frame-difference"),
    message("pause"),
    message(
        "user-properties",
        properties={"bgaudiobarsxbounds": {"value": 0.5}},
    ),
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
    timeout=45,
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
    first_applied,
    first_change,
    _,
    second_applied,
    paused,
    _,
    resumed,
    reloaded,
    reloaded_metrics,
    _,
) = events

assert ready["genericPropertyScripts"] == 137, ready
assert ready["backend"] == EXPECTED_BACKEND, ready
assert ready["genericPropertyScriptUpdates"] == 270, ready
assert ready["genericPropertyScriptChanges"] == 66, ready
assert ready["genericPropertyScriptErrors"] == 0, ready
assert first_applied["acceptedScriptProperties"] == 1, first_applied
assert first_applied["ignored"] == 0, first_applied
assert first_change["genericPropertyScriptUpdates"] == 392, first_change
assert first_change["genericPropertyScriptChanges"] == 77, first_change
assert paused["paused"] is True, paused
assert paused["genericPropertyScriptUpdates"] == 392, paused
assert paused["genericPropertyScriptChanges"] == 77, paused
assert second_applied["acceptedScriptProperties"] == 1, second_applied
assert second_applied["ignored"] == 0, second_applied
assert resumed["genericPropertyScriptUpdates"] == 514, resumed
assert resumed["genericPropertyScriptChanges"] == 88, resumed
assert resumed["genericPropertyScriptErrors"] == 0, resumed
for event in (reloaded, reloaded_metrics):
    assert event["backend"] == EXPECTED_BACKEND, event
    assert event["genericPropertyScripts"] == 137, event
    assert event["genericPropertyScriptUpdates"] == 270, event
    assert event["genericPropertyScriptChanges"] == 66, event
    assert event["genericPropertyScriptErrors"] == 0, event
    assert event["scriptErrors"] == 0, event

print(
    f"SceneScript effect properties passed: {EXPECTED_BACKEND} "
    "Persona Vec2 consumers=3 changes=6"
)
