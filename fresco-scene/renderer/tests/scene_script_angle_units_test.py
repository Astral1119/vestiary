#!/usr/bin/env python3

"""Pins the unit layer angles cross the SceneScript boundary in.

scene.json stores angles in radians; SceneScript reads and writes them in
degrees. Nothing in the counters can see the difference — a script that runs,
updates and changes the property does all three whether the conversion is
applied or absent — so this reads the resolved value out of
`scriptedPropertyVectors` and checks the number.

GBC Subaru's head multiplies a scene-unit cursor x by 0.003 and lerps toward it.
At the right edge of a 3840-wide projection that is 11.52, which is a plausible
head tilt in degrees and 660 degrees — nearly two full turns — in radians. The
renderer used to apply it as radians, and the head span the whole rotation.

The convention is the corpus's, not an inference: 3477054430 labels its slider
"Max Rotation (degrees)" and seeds `new Vec3(0, -32, 0)` for a layer authored at
-0.55851, which is -32 degrees exactly.
"""

import json
import math
import os
import subprocess
import sys

HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "scene-script-angle-units"

HEAD = 142
SCENE_WIDTH = 3840
# The head script's authored zScaleFactor, in degrees per scene unit.
Z_SCALE_FACTOR = 0.003
# lerpFactor is 0.22, so the remaining gap is 0.78**n after n ticks. Sixty ticks
# leaves about 4e-7 of it, well under the tolerance below.
SETTLE_TICKS = 60
TOLERANCE_DEGREES = 1e-3

CURSOR_X = [0, 1920, 3840]


def message(message_type, **values):
    return {"protocolVersion": 1, "type": message_type, "assignmentID": ASSIGNMENT, **values}


gbc = os.path.join(WORKSHOP, "3448290956")
commands = []
for x in CURSOR_X:
    commands.append(message(
        "load", path=gbc, assetRoot=ASSETS, width=320, height=180,
        visible=True, evidenceFrames=2,
    ))
    for _ in range(SETTLE_TICKS):
        commands.append(message("cursor-move", x=x, y=1080))
        commands.append(message("capture-frame-difference"))
    commands.append(message("metrics"))
commands.append(message("stop"))

result = subprocess.run(
    [HELPER], input="".join(json.dumps(command) + "\n" for command in commands),
    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300, check=True,
)
assert not result.stderr, result.stderr
events = [json.loads(line) for line in result.stdout.splitlines()]

readies = [event for event in events if event["type"] == "ready"]
assert len(readies) == len(CURSOR_X), events
for ready in readies:
    assert ready["backend"] == EXPECTED_BACKEND, ready
    assert ready["scriptErrors"] == 0, ready

metrics = [event for event in events if event["type"] == "metrics"]
assert len(metrics) == len(CURSOR_X), events

for x, reading in zip(CURSOR_X, metrics):
    assert reading["genericPropertyScriptErrors"] == 0, reading
    vectors = {
        (entry["objectID"], entry["property"]): entry["value"]
        for entry in reading["scriptedPropertyVectors"]
    }
    # Every scripted property reports which one it is; an unnamed one would
    # leave the angle conversion unable to tell rotations from origins.
    assert all(property for _, property in vectors), reading
    resolved = vectors[(HEAD, "angles")]
    # The scene stores radians, so this is what the renderer must have written.
    expected = x * Z_SCALE_FACTOR
    actual = math.degrees(resolved[2])
    assert abs(actual - expected) < TOLERANCE_DEGREES, (x, expected, actual, resolved)
    assert resolved[0] == 0.0 and resolved[1] == 0.0, resolved

# The eyes and the mouth read the same cursor in scene units and are unaffected
# by the angle conversion; they move, so the cursor really did reach the scripts.
last = {
    (entry["objectID"], entry["property"]): entry["value"]
    for entry in metrics[-1]["scriptedPropertyVectors"]
}
first = {
    (entry["objectID"], entry["property"]): entry["value"]
    for entry in metrics[0]["scriptedPropertyVectors"]
}
for key in ((576, "origin"), (87, "origin")):
    assert first[key] != last[key], (key, first[key], last[key])

print(
    f"scene script angle units passed: {EXPECTED_BACKEND} "
    f"head={math.degrees(last[(HEAD, 'angles')][2]):.3f}deg positions={len(CURSOR_X)}"
)
