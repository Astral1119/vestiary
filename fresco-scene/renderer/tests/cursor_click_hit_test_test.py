#!/usr/bin/env python3

"""Pins cursor-click routing by scene position rather than by object ID.

The host used to send one hardcoded object ID, which reached a single script in
a single fixture. A click carrying scene x and y instead resolves to every layer
under the point that has a click handler, topmost first, using the box the layer
actually draws.

GBC Subaru carries two full-size copies of 主发: object 289 plays a sound, object
134 runs the head-poke animation on a double click. Both have to be reachable.
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
commands = [
    message(
        "load", path=gbc, assetRoot=ASSETS, width=320, height=180,
        visible=True, evidenceFrames=2,
    ),
    message("cursor-click", x=BOTH[0], y=BOTH[1], monotonicMilliseconds=1000),
    message("cursor-click", x=BOTH[0], y=BOTH[1], monotonicMilliseconds=1200),
    message("metrics"),
]
for x, y in EMPTY:
    commands.append(message("cursor-click", x=x, y=y, monotonicMilliseconds=1400))
# Addressing an object directly still works, and is what the promotion gate uses.
commands.append(message("cursor-click", objectID=134, monotonicMilliseconds=2000))
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

clicks = [event for event in events if event["type"] == "cursor-clicked"]
assert len(clicks) == 3 + len(EMPTY), events
first, second = clicks[0], clicks[1]
empties = clicks[2:2 + len(EMPTY)]
addressed = clicks[-1]

# Topmost first: 289 is drawn after 134.
for click in (first, second):
    assert click["handled"] is True, click
    assert click["objectIDs"] == [289, 134], click
    assert click["objectID"] == 289, click

# The pair 200ms apart is inside the script's 500ms double-click threshold, so
# the head-poke animation runs. This is the same count the promotion gate gets
# by addressing 134 directly.
metrics = next(event for event in events if event["type"] == "metrics")
assert metrics["namedAnimationTargetPlays"] == 2, metrics

for click in empties:
    assert click["handled"] is False, click
    assert click["objectIDs"] == [], click

assert addressed["handled"] is True, addressed
assert addressed["objectIDs"] == [134], addressed

print(
    f"cursor click hit test passed: {EXPECTED_BACKEND} "
    f"targets={first['objectIDs']} misses={len(EMPTY)}"
)
