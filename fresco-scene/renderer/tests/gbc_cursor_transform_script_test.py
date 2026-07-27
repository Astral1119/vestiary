#!/usr/bin/env python3

import json
import os
import subprocess
import sys

HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "gbc-cursor-transform"


def message(message_type, **values):
    return {"protocolVersion": 1, "type": message_type, "assignmentID": ASSIGNMENT, **values}


gbc = os.path.join(WORKSHOP, "3448290956")
load = message(
    "load", path=gbc, assetRoot=ASSETS, width=320, height=180,
    visible=True, evidenceFrames=2,
)
commands = [
    load,
    message("cursor-move", x=200, y=100),
    message("capture-frame-difference"),
    message("pause"),
    message("cursor-move", x=100, y=50),
    message("metrics"),
    message("resume"),
    message("capture-frame-difference"),
    load,
    message("metrics"),
    message("stop"),
]
result = subprocess.run(
    [HELPER], input="".join(json.dumps(command) + "\n" for command in commands),
    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, check=True,
)
assert not result.stderr, result.stderr
events = [json.loads(line) for line in result.stdout.splitlines()]
assert [event["type"] for event in events] == [
    "ready", "cursor-event-dispatched", "frame-difference", "paused",
    "cursor-event-dispatched", "metrics", "resumed", "frame-difference",
    "ready", "metrics", "stopped",
], events
(
    ready, moved, cursor_difference, _, paused_move, paused, _, resumed,
    reloaded, reloaded_metrics, _,
) = events

for event in (ready, cursor_difference, paused, resumed, reloaded, reloaded_metrics):
    assert event["backend"] == EXPECTED_BACKEND, event
    assert event["genericPropertyScripts"] == 10, event
    assert event["genericPropertyScriptErrors"] == 0, event
    assert event["scriptErrors"] == 0, event
assert ready["deferredScriptValues"] == 0, ready
assert not any("SceneScript" in warning for warning in ready["warnings"]), ready
for event in (moved, paused_move):
    assert (event["phase"], event["handled"]) == ("move", 4), event
assert (ready["genericPropertyScriptUpdates"], ready["genericPropertyScriptChanges"]) == (29, 8), ready
assert (cursor_difference["genericPropertyScriptUpdates"], cursor_difference["genericPropertyScriptChanges"]) == (39, 11), cursor_difference
assert cursor_difference["changedPixels"] > 0, cursor_difference
assert paused["paused"] is True, paused
assert (paused["genericPropertyScriptUpdates"], paused["genericPropertyScriptChanges"]) == (39, 11), paused
assert (resumed["genericPropertyScriptUpdates"], resumed["genericPropertyScriptChanges"]) == (49, 14), resumed
assert resumed["changedPixels"] > 0, resumed
for event in (reloaded, reloaded_metrics):
    assert (event["genericPropertyScriptUpdates"], event["genericPropertyScriptChanges"]) == (29, 8), event

print(f"SceneScript GBC cursor transforms passed: {EXPECTED_BACKEND} consumers=4 residual=0")
