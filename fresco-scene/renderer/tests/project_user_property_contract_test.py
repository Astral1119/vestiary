#!/usr/bin/env python3

import json
import os
import subprocess
import sys

HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "project-user-property-contract"


def message(message_type, **values):
    return {"protocolVersion": 1, "type": message_type, "assignmentID": ASSIGNMENT, **values}


valid = {
    "_12": {"value": 1.0},
    "barstyle": {"value": 2.0},
    "clockopacity": {"value": "0.5"},
    "barcolor": {"value": "1 0 0 1"},
}
invalid = {
    "_12": {"value": "maybe"},
    "barstyle": {"value": "missing"},
    "clockopacity": {"value": "nan"},
    "barcolor": {"value": "2 0 0"},
    "unknown-property": {"value": True},
}
commands = [
    message(
        "load", path=os.path.join(WORKSHOP, "3299228616"), assetRoot=ASSETS,
        width=320, height=180, visible=False, evidenceFrames=2,
    ),
    message("user-properties", properties=valid),
    message("capture-frame-difference"),
    message("user-properties", properties=invalid),
    message("capture-frame-difference"),
    message("user-properties", properties=valid),
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
    "ready", "user-properties-applied", "frame-difference",
    "user-properties-applied", "frame-difference",
    "user-properties-applied", "frame-difference", "stopped",
], events
ready, normalized, normalized_frame, rejected, rejected_frame, recovered, recovered_frame, _ = events

for event in (ready, normalized_frame, rejected_frame, recovered_frame):
    assert event["backend"] == EXPECTED_BACKEND, event
    assert event["scriptErrors"] == 0, event
assert (normalized["received"], normalized["acceptedScriptProperties"], normalized["ignored"]) == (4, 4, 0), normalized
assert normalized["diagnostics"] == [], normalized
assert (rejected["received"], rejected["acceptedScriptProperties"], rejected["ignored"]) == (5, 0, 5), rejected
assert len(rejected["diagnostics"]) == 5, rejected
assert any("expected boolean" in value for value in rejected["diagnostics"]), rejected
assert any("unknown combo option" in value for value in rejected["diagnostics"]), rejected
assert any("finite in-range slider" in value for value in rejected["diagnostics"]), rejected
assert any("normalized color components" in value for value in rejected["diagnostics"]), rejected
assert any("unknown key" in value for value in rejected["diagnostics"]), rejected
assert (recovered["received"], recovered["acceptedScriptProperties"], recovered["ignored"]) == (4, 4, 0), recovered
assert recovered["diagnostics"] == [], recovered

print(f"project user-property contract passed: {EXPECTED_BACKEND} bool/combo/slider/color normalization and atomic rejection")
