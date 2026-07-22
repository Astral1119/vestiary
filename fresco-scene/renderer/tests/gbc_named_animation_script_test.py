#!/usr/bin/env python3

import json
import os
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "gbc-named-animation"


def message(message_type, **values):
    return {
        "protocolVersion": 1,
        "type": message_type,
        "assignmentID": ASSIGNMENT,
        **values,
    }


gbc = os.path.join(WORKSHOP, "3448290956")
load = message(
    "load", path=gbc, assetRoot=ASSETS, width=320, height=180,
    visible=True, evidenceFrames=2,
)
commands = [load, message("metrics")]
commands += [
    message("cursor-click", objectID=134, monotonicMilliseconds=1000),
    message("metrics"),
    message("cursor-click", objectID=134, monotonicMilliseconds=1200),
]
commands += [message("capture-frame-difference") for _ in range(16)]
commands += [
    message("metrics"),
    message("pause"),
    message("cursor-click", objectID=134, monotonicMilliseconds=2000),
    message("cursor-click", objectID=134, monotonicMilliseconds=2600),
    message("metrics"),
    message("cursor-click", objectID=134, monotonicMilliseconds=2700),
    message("metrics"),
    message("resume"),
    message("user-properties", properties={"kaiguan": {"value": False}}),
    message("cursor-click", objectID=134, monotonicMilliseconds=2800),
    message("user-properties", properties={"kaiguan": {"value": True}}),
    message("cursor-click", objectID=134, monotonicMilliseconds=2900),
    message("metrics"),
    message("cursor-click", objectID=134, monotonicMilliseconds=3000),
    message("metrics"),
    message("capture-frame-difference"),
    load,
    message("metrics"),
    message("stop"),
]

result = subprocess.run(
    [HELPER], input="".join(json.dumps(command) + "\n" for command in commands),
    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90, check=True,
)
assert not result.stderr, result.stderr
events = [json.loads(line) for line in result.stdout.splitlines()]
for event in events:
    if event["type"] in ("ready", "metrics", "frame-difference"):
        assert event["backend"] == EXPECTED_BACKEND, event
        assert event["genericPropertyScripts"] == 10, event
        assert event["genericPropertyScriptErrors"] == 0, event
        assert event["scriptErrors"] == 0, event

metrics = [event for event in events if event["type"] == "metrics"]
assert len(metrics) == 8, metrics
initial, first, animated, timed_out, second_pair, disabled, third_pair, reloaded = metrics
for event in (initial, first):
    assert event["namedAnimationTargetPlays"] == 0, event
    assert event["namedAnimationActive"] == 0, event
    assert event["namedAnimationFrameTotal"] == 0, event
assert animated["namedAnimationTargetPlays"] == 2, animated
assert animated["namedAnimationActive"] == 2, animated
assert abs(animated["namedAnimationFrameTotal"] - 16) < 0.001, animated
assert timed_out["paused"] is True, timed_out
assert timed_out["namedAnimationTargetPlays"] == 2, timed_out
assert abs(timed_out["namedAnimationFrameTotal"] - 16) < 0.001, timed_out
assert second_pair["namedAnimationTargetPlays"] == 4, second_pair
assert disabled["namedAnimationTargetPlays"] == 4, disabled
assert third_pair["namedAnimationTargetPlays"] == 6, third_pair
for event in (reloaded,):
    assert event["namedAnimationTargetPlays"] == 0, event
    assert event["namedAnimationActive"] == 0, event
    assert event["namedAnimationFrameTotal"] == 0, event

differences = [event for event in events if event["type"] == "frame-difference"]
assert len(differences) == 17, len(differences)
assert max(event["changedPixels"] for event in differences[14:16]) > 0, differences[-3:]

clicks = [event for event in events if event["type"] == "cursor-clicked"]
assert len(clicks) == 8, clicks
assert all(event["objectID"] == 134 and event["handled"] is True for event in clicks)

print(
    f"GBC named-animation double-click passed: {EXPECTED_BACKEND} "
    "targets=2 timeout=500ms reload=clean"
)
