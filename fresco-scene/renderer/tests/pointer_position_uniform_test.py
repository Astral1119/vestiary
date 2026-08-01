#!/usr/bin/env python3

"""Pins the pointer chain from the protocol to the shader uniform.

cursor-move carries absolute, bottom-up scene coordinates. CScene::updateMouse
divides those by the viewport and inverts y, and CPass binds the result as
g_PointerPosition. Before the host mouse existed the renderer bound a mouse that
reported (0, 0) forever, so every scene that follows the cursor sat frozen at one
corner. These are the corners and the centre of GBC's 3840x2160 projection.

A scene is drawn to fill the surface, matching one axis and cropping the other,
so on a surface that is not the scene's shape only part of the projection is on
screen. The renderer used to scale a scene coordinate by the whole projection and
then let updateMouse crop it a second time, which left the pointer short of where
it was aimed by the cropped margin. Only a mismatched aspect can see that, and
every other test in this suite renders 16:9. The two loads below crop each axis
in turn, and `ready` reports the window they leave as `visibleScene`.
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

# A 4:3 surface against a 16:9 scene matches height and crops width to three
# quarters, and a 20:9 surface matches width and crops height to four fifths.
# Both crops are centred. The margin is the whole defect, so it is stated here
# rather than derived from what the helper reports.
CROPPED = [
    {
        "width": 320,
        "height": 240,
        "visible": {"x": 480.0, "y": 0.0, "width": 2880.0, "height": 2160.0},
        # Well inside the visible window, at coordinates the float uniform holds
        # exactly, so the round trip is not being compared against its own error.
        "inside": [
            ((960, 540), (0.25, 0.75)),
            ((1920, 1080), (0.5, 0.5)),
            ((2880, 1620), (0.75, 0.25)),
            ((960, 0), (0.25, 1.0)),
        ],
        # Off screen on the cropped axis. These are the scene corners the first
        # load reads as 0 and 1; here they are behind the crop.
        "clamped": [(0, 1080), (SCENE_WIDTH, 1080)],
    },
    {
        "width": 400,
        "height": 180,
        "visible": {"x": 0.0, "y": 216.0, "width": 3840.0, "height": 1728.0},
        "inside": [
            ((1920, 540), (0.5, 0.75)),
            ((1920, 1080), (0.5, 0.5)),
            ((1920, 1620), (0.5, 0.25)),
            ((0, 1080), (0.0, 0.5)),
        ],
        "clamped": [(1920, 0), (1920, SCENE_HEIGHT)],
    },
]

# The crop is computed in integer pixels, so the margin lands within a pixel of
# the exact ratio rather than on it. One surface pixel is 12 scene units wide.
VISIBLE_TOLERANCE = 12.0
# g_PointerPosition is a float32 uniform.
POINTER_TOLERANCE = 1e-6


def message(message_type, **values):
    return {"protocolVersion": 1, "type": message_type, "assignmentID": ASSIGNMENT, **values}


def moves(points):
    for x, y in points:
        yield message("cursor-move", x=x, y=y)
        yield message("capture-frame-difference")


gbc = os.path.join(WORKSHOP, "3448290956")


def load(width, height):
    return message(
        "load", path=gbc, assetRoot=ASSETS, width=width, height=height,
        visible=True, evidenceFrames=2,
    )


commands = [load(320, 180)]
commands.extend(moves([point for point, _ in CORNERS]))
for case in CROPPED:
    commands.append(load(case["width"], case["height"]))
    commands.extend(moves([point for point, _ in case["inside"]]))
    commands.extend(moves(case["clamped"]))
commands.append(message("stop"))

result = subprocess.run(
    [HELPER], input="".join(json.dumps(command) + "\n" for command in commands),
    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180, check=True,
)
assert not result.stderr, result.stderr
events = [json.loads(line) for line in result.stdout.splitlines()]

readies = [event for event in events if event["type"] == "ready"]
assert len(readies) == 1 + len(CROPPED), events
for ready in readies:
    assert ready["backend"] == EXPECTED_BACKEND, ready
    assert ready["scriptErrors"] == 0, ready

# An unloaded pointer reads as the bottom-left corner, not as a live position.
assert readies[0]["pointerPosition"] == [0.0, 1.0], readies[0]

# A surface of the scene's own shape shows all of it.
assert readies[0]["visibleScene"] == {
    "x": 0.0, "y": 0.0, "width": float(SCENE_WIDTH), "height": float(SCENE_HEIGHT),
}, readies[0]

differences = [event for event in events if event["type"] == "frame-difference"]
expected_differences = len(CORNERS) + sum(
    len(case["inside"]) + len(case["clamped"]) for case in CROPPED
)
assert len(differences) == expected_differences, events


def check(point, expected, difference):
    actual = difference["pointerPosition"]
    assert len(actual) == 2, difference
    assert all(
        abs(component - want) < POINTER_TOLERANCE
        for component, want in zip(actual, expected)
    ), (point, expected, difference)


consumed = 0
for (point, expected) in CORNERS:
    check(point, expected, differences[consumed])
    consumed += 1

for case, ready in zip(CROPPED, readies[1:]):
    visible = ready["visibleScene"]
    for key, want in case["visible"].items():
        assert abs(visible[key] - want) < VISIBLE_TOLERANCE, (case, ready)

    # A scene coordinate inside the window resolves to itself, whatever the
    # surface is shaped like: the renderer's scale is the inverse of the crop
    # rather than a second application of it.
    for point, expected in case["inside"]:
        check(point, expected, differences[consumed])
        consumed += 1

    # One outside it is off screen and resolves to the nearest visible edge,
    # which is the window the same `ready` reported.
    left = visible["x"] / SCENE_WIDTH
    right = (visible["x"] + visible["width"]) / SCENE_WIDTH
    bottom = 1.0 - visible["y"] / SCENE_HEIGHT
    top = 1.0 - (visible["y"] + visible["height"]) / SCENE_HEIGHT
    edges = {
        (0, 1080): (left, 0.5),
        (SCENE_WIDTH, 1080): (right, 0.5),
        (1920, 0): (0.5, bottom),
        (1920, SCENE_HEIGHT): (0.5, top),
    }
    for point in case["clamped"]:
        check(point, edges[point], differences[consumed])
        consumed += 1

assert consumed == len(differences), (consumed, len(differences))

dispatched = [event for event in events if event["type"] == "cursor-event-dispatched"]
assert len(dispatched) == expected_differences, events
for event in dispatched:
    assert event["phase"] == "move", event
    # GBC's four cursor-driven scripts stay reachable while the mouse is live.
    assert event["handled"] == 4, event

print(
    f"pointer position uniform passed: {EXPECTED_BACKEND} "
    f"corners={len(CORNERS)} crops={len(CROPPED)} consumers=4"
)
