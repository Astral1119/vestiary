#!/usr/bin/env python3

import json
import os
import subprocess
import sys

HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "lonely-cursor-drag"


def message(message_type, **values):
    return {"protocolVersion": 1, "type": message_type, "assignmentID": ASSIGNMENT, **values}


lonely = os.path.join(WORKSHOP, "3299228616")
commands = [
    message("load", path=lonely, assetRoot=ASSETS, width=320, height=180, visible=True, evidenceFrames=2),
    message("cursor-down", x=150, y=90),
    message("cursor-move", x=170, y=100),
    message("capture-frame-difference"),
    message("cursor-up", x=170, y=100),
    message("capture-frame-difference"),
    message("pause"),
    message("cursor-move", x=120, y=80),
    message("metrics"),
    message("resume"),
    message("capture-frame-difference"),
    message("stop"),
]
result = subprocess.run(
    [HELPER], input="".join(json.dumps(command) + "\n" for command in commands),
    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60, check=True,
)
assert not result.stderr, result.stderr
events = [json.loads(line) for line in result.stdout.splitlines()]
assert [event["type"] for event in events] == [
    "ready", "cursor-event-dispatched", "cursor-event-dispatched", "frame-difference",
    "cursor-event-dispatched", "frame-difference", "paused", "cursor-event-dispatched",
    "metrics", "resumed", "frame-difference", "stopped",
], events
ready, down, move, dragged, up, bouncing, _, paused_move, paused, _, resumed, _ = events

for event in (ready, dragged, bouncing, paused, resumed):
    assert event["backend"] == EXPECTED_BACKEND, event
    assert event["genericPropertyScripts"] == 36, event
    assert event["genericPropertyScriptErrors"] == 0, event
    assert event["scriptErrors"] == 0, event
assert ready["deferredScriptValues"] == 0, ready
for event, phase in ((down, "down"), (move, "move"), (up, "up"), (paused_move, "move")):
    assert (event["phase"], event["handled"]) == (phase, 6), event
assert (ready["genericPropertyScriptUpdates"], ready["genericPropertyScriptChanges"]) == (108, 30), ready
assert (dragged["genericPropertyScriptUpdates"], dragged["genericPropertyScriptChanges"]) == (144, 42), dragged
assert (bouncing["genericPropertyScriptUpdates"], bouncing["genericPropertyScriptChanges"]) == (180, 54), bouncing
assert paused["paused"] is True, paused
assert (paused["genericPropertyScriptUpdates"], paused["genericPropertyScriptChanges"]) == (180, 54), paused
assert (resumed["genericPropertyScriptUpdates"], resumed["genericPropertyScriptChanges"]) == (216, 66), resumed

print(f"SceneScript cursor drag passed: {EXPECTED_BACKEND} Lonely consumers=6")
