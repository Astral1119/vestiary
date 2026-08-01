#!/usr/bin/env python3

"""Pins the pointer chain from the protocol to the shader uniform.

cursor-move carries absolute, bottom-up scene coordinates. CScene::updateMouse
divides those by the viewport and inverts y, and CPass binds the result as
g_PointerPosition. Before the host mouse existed the renderer bound a mouse that
reported (0, 0) forever, so every scene that follows the cursor sat frozen at one
corner. These are the corners and the centre of GBC's 3840x2160 projection.
"""

import json
import os
import subprocess
import sys

HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "pointer-position-uniform"

SCENE_WIDTH = 3840
SCENE_HEIGHT = 2160

# scene coordinate -> g_PointerPosition. y inverts because the shader convention
# puts 0 at the top; GBC's iris_movement effect undoes it with 1.0 - y.
CORNERS = [
    ((0, 0), (0.0, 1.0)),
    ((SCENE_WIDTH, 0), (1.0, 1.0)),
    ((0, SCENE_HEIGHT), (0.0, 0.0)),
    ((SCENE_WIDTH, SCENE_HEIGHT), (1.0, 0.0)),
    ((SCENE_WIDTH // 2, SCENE_HEIGHT // 2), (0.5, 0.5)),
]


def message(message_type, **values):
    return {"protocolVersion": 1, "type": message_type, "assignmentID": ASSIGNMENT, **values}


gbc = os.path.join(WORKSHOP, "3448290956")
commands = [
    message(
        "load", path=gbc, assetRoot=ASSETS, width=320, height=180,
        visible=True, evidenceFrames=2,
    )
]
for (x, y), _ in CORNERS:
    commands.append(message("cursor-move", x=x, y=y))
    commands.append(message("capture-frame-difference"))
commands.append(message("stop"))

result = subprocess.run(
    [HELPER], input="".join(json.dumps(command) + "\n" for command in commands),
    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180, check=True,
)
assert not result.stderr, result.stderr
events = [json.loads(line) for line in result.stdout.splitlines()]

ready = events[0]
assert ready["type"] == "ready", ready
assert ready["backend"] == EXPECTED_BACKEND, ready
assert ready["scriptErrors"] == 0, ready

# An unloaded pointer reads as the bottom-left corner, not as a live position.
assert ready["pointerPosition"] == [0.0, 1.0], ready

differences = [event for event in events if event["type"] == "frame-difference"]
assert len(differences) == len(CORNERS), events

for ((x, y), expected), difference in zip(CORNERS, differences):
    assert difference["backend"] == EXPECTED_BACKEND, difference
    actual = difference["pointerPosition"]
    assert len(actual) == 2, difference
    assert all(
        abs(component - want) < 1e-6 for component, want in zip(actual, expected)
    ), (x, y, expected, difference)

dispatched = [event for event in events if event["type"] == "cursor-event-dispatched"]
assert len(dispatched) == len(CORNERS), events
for event in dispatched:
    assert event["phase"] == "move", event
    # GBC's four cursor-driven scripts stay reachable while the mouse is live.
    assert event["handled"] == 4, event

print(
    f"pointer position uniform passed: {EXPECTED_BACKEND} "
    f"corners={len(CORNERS)} consumers=4"
)
