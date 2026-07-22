#!/usr/bin/env python3

import json
import pathlib
import subprocess
import sys


HELPER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
PERSONA = WORKSHOP / "3151551777"
ASSIGNMENT = "particle-mode-3-render"


def message(kind, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": ASSIGNMENT,
        **values,
    }


commands = [
    message(
        "load",
        path=str(PERSONA),
        assetRoot=str(ASSETS),
        width=320,
        height=180,
        visible=True,
        evidenceFrames=60,
    ),
    message("audio-spectrum", values=[1.0] * 128),
    message("capture-frame-difference"),
    message("audio-spectrum", values=[0.0] * 128),
    message("capture-frame-difference"),
    message("stop"),
]
result = subprocess.run(
    [HELPER],
    input="".join(json.dumps(command) + "\n" for command in commands),
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=60,
    check=True,
)
assert not result.stderr, result.stderr
events = [json.loads(line) for line in result.stdout.splitlines()]
assert [event["type"] for event in events] == [
    "ready",
    "frame-difference",
    "frame-difference",
    "stopped",
], events
ready, live, silent, _ = events
assert ready["backend"] in {"native-opengl", "angle-metal"}, ready
assert ready["drawComplete"] is True, ready
assert ready["frames"] == 60, ready
assert live["drawComplete"] is True and live["changedPixels"] > 0, live
assert silent["drawComplete"] is True and silent["changedPixels"] > 0, silent
print(f"particle mode-3 render: {ready['backend']} live/silence passed")
