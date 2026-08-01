#!/usr/bin/env python3

"""Pins cursor-click routing by scene position rather than by object ID.

The host used to send one hardcoded object ID, which reached a single script in
a single fixture. A click carrying scene x and y instead resolves to every layer
under the point that has a click handler, topmost first, using the box the layer
actually draws.

GBC Subaru carries two full-size copies of 主发: object 289 plays a sound, object
134 runs the head-poke animation on a double click. Both have to be reachable.

The hit-test reads a scene coordinate against the boxes the layers draw, both of
which are in the authored projection, so it does not depend on the shape of the
surface the scene is rendered to. The second load is a 4:3 surface, which crops a
quarter of a 16:9 scene's width away, and every click has to land where it did.
"""

import json
import os
import subprocess
import sys

HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "cursor-click-hit-test"

# Over both copies of 主発. Chosen so the two boxes overlap, which is what makes
# the multi-target rule observable at all.
BOTH = (1920, 300)
# Scene corners, clear of every clickable layer.
EMPTY = [(50, 50), (3700, 2100)]


def message(message_type, **values):
    return {"protocolVersion": 1, "type": message_type, "assignmentID": ASSIGNMENT, **values}


gbc = os.path.join(WORKSHOP, "3448290956")


def load(width, height):
    return message(
        "load", path=gbc, assetRoot=ASSETS, width=width, height=height,
        visible=True, evidenceFrames=2,
    )


commands = [
    load(320, 180),
    message("cursor-click", x=BOTH[0], y=BOTH[1], monotonicMilliseconds=1000),
    message("cursor-click", x=BOTH[0], y=BOTH[1], monotonicMilliseconds=1200),
    message("metrics"),
]
for x, y in EMPTY:
    commands.append(message("cursor-click", x=x, y=y, monotonicMilliseconds=1400))
# Addressing an object directly still works, and is what the promotion gate uses.
commands.append(message("cursor-click", objectID=134, monotonicMilliseconds=2000))
# The same clicks on a surface that shows three quarters of the scene's width.
commands.append(load(320, 240))
commands.append(message("cursor-click", x=BOTH[0], y=BOTH[1], monotonicMilliseconds=1000))
commands.append(message("cursor-click", x=BOTH[0], y=BOTH[1], monotonicMilliseconds=1200))
commands.append(message("metrics"))
for x, y in EMPTY:
    commands.append(message("cursor-click", x=x, y=y, monotonicMilliseconds=1400))
commands.append(message("stop"))

result = subprocess.run(
    [HELPER], input="".join(json.dumps(command) + "\n" for command in commands),
    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180, check=True,
)
assert not result.stderr, result.stderr
events = [json.loads(line) for line in result.stdout.splitlines()]

readies = [event for event in events if event["type"] == "ready"]
assert len(readies) == 2, events
for ready in readies:
    assert ready["backend"] == EXPECTED_BACKEND, ready
    assert ready["scriptErrors"] == 0, ready

# The second surface really does crop, or it would not be testing anything.
assert readies[0]["visibleScene"]["width"] == 3840.0, readies[0]
assert readies[1]["visibleScene"]["width"] < 3000.0, readies[1]

clicks = [event for event in events if event["type"] == "cursor-clicked"]
assert len(clicks) == 3 + 2 * len(EMPTY) + 2, events
first, second = clicks[0], clicks[1]
empties = clicks[2:2 + len(EMPTY)]
addressed = clicks[2 + len(EMPTY)]
cropped_hits = clicks[3 + len(EMPTY):5 + len(EMPTY)]
cropped_empties = clicks[5 + len(EMPTY):]

# Topmost first: 289 is drawn after 134.
for click in (first, second, *cropped_hits):
    assert click["handled"] is True, click
    assert click["objectIDs"] == [289, 134], click
    assert click["objectID"] == 289, click

# The pair 200ms apart is inside the script's 500ms double-click threshold, so
# the head-poke animation runs. This is the same count the promotion gate gets
# by addressing 134 directly.
metrics = [event for event in events if event["type"] == "metrics"]
assert len(metrics) == 2, events
for reading in metrics:
    assert reading["namedAnimationTargetPlays"] == 2, reading

for click in (*empties, *cropped_empties):
    assert click["handled"] is False, click
    assert click["objectIDs"] == [], click

assert addressed["handled"] is True, addressed
assert addressed["objectIDs"] == [134], addressed

print(
    f"cursor click hit test passed: {EXPECTED_BACKEND} "
    f"targets={first['objectIDs']} misses={len(EMPTY)} aspects=2"
)
