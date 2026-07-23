#!/usr/bin/env python3

import json
import os
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "persona-user-property-scalars"


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
    userProperties={
        "character": {"value": "1"},
        "timeofday": {"value": "99"},
    },
)
commands = [
    load,
    message("user-properties", properties={"character": {"value": "3"}}),
    message("capture-frame-difference"),
    message("pause"),
    message("user-properties", properties={"character": {"value": "2"}}),
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
    aigis_applied,
    aigis,
    _,
    protagonist_applied,
    paused,
    _,
    protagonist,
    reloaded,
    reloaded_metrics,
    _,
) = events

for event in (ready, aigis, paused, protagonist, reloaded, reloaded_metrics):
    assert event["backend"] == EXPECTED_BACKEND, event
    assert event["genericPropertyScripts"] == 137, event
    assert event["genericPropertyScriptErrors"] == 0, event
    assert event["scriptErrors"] == 0, event
assert ready["initialUserProperties"]["acceptedScriptProperties"] == 2, ready
assert ready["initialUserProperties"]["ignored"] == 0, ready
assert ready["deferredScriptValues"] == 0, ready
for event in (aigis_applied, protagonist_applied):
    assert event["acceptedScriptProperties"] == 1, event
    assert event["ignored"] == 0, event
assert (ready["genericPropertyScriptUpdates"], ready["genericPropertyScriptChanges"]) == (
    270,
    81,
), ready
assert (aigis["genericPropertyScriptUpdates"], aigis["genericPropertyScriptChanges"]) == (
    392,
    95,
), aigis
assert paused["paused"] is True, paused
assert (paused["genericPropertyScriptUpdates"], paused["genericPropertyScriptChanges"]) == (
    392,
    95,
), paused
assert (
    protagonist["genericPropertyScriptUpdates"],
    protagonist["genericPropertyScriptChanges"],
) == (514, 120), protagonist
for event in (reloaded, reloaded_metrics):
    assert (
        event["genericPropertyScriptUpdates"],
        event["genericPropertyScriptChanges"],
    ) == (270, 81), event

print(
    f"SceneScript user scalars passed: {EXPECTED_BACKEND} Persona consumers=18; "
    "character/time lifecycle is deterministic"
)
