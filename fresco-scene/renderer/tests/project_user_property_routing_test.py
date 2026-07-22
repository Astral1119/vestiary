#!/usr/bin/env python3

import json
import os
import struct
import subprocess
import sys

HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "lonely-project-user-property"
LONELY = os.path.join(WORKSHOP, "3299228616")


def message(message_type, **values):
    return {"protocolVersion": 1, "type": message_type, "assignmentID": ASSIGNMENT, **values}


with open(os.path.join(LONELY, "project.json"), encoding="utf-8") as handle:
    project = json.load(handle)
barcolor = project["general"]["properties"]["barcolor"]
assert (barcolor["type"], barcolor["value"]) == ("color", "1 1 1"), barcolor

with open(os.path.join(LONELY, "scene.pkg"), "rb") as handle:
    def read_u32():
        return struct.unpack("<I", handle.read(4))[0]

    def read_string():
        return handle.read(read_u32()).decode("utf-8")

    read_string()
    entries = [(read_string(), read_u32(), read_u32()) for _ in range(read_u32())]
    base = handle.tell()
    _, offset, length = next(entry for entry in entries if entry[0] == "scene.json")
    handle.seek(base + offset)
    scene = json.loads(handle.read(length))

barcolor_bindings = []


def collect(node, path=""):
    if isinstance(node, dict):
        if node.get("user") == "barcolor":
            barcolor_bindings.append(path)
        for key, value in node.items():
            collect(value, f"{path}/{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            collect(value, f"{path}/{index}")


collect(scene)
assert len(barcolor_bindings) == 15, barcolor_bindings
assert all("/effects/0/passes/0/constantshadervalues/Bar Color" in path for path in barcolor_bindings), barcolor_bindings

load = message(
    "load", path=LONELY, assetRoot=ASSETS, width=320, height=180,
    visible=True, evidenceFrames=2,
    userProperties={"barcolor": {"value": "1 1 1"}},
)
commands = [
    load,
    message("user-properties", properties={"barcolor": {"value": "1 0 0"}}),
    message("capture-frame-difference"),
    message("pause"),
    message("user-properties", properties={"barcolor": {"value": "0 1 0"}}),
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
    "ready", "user-properties-applied", "frame-difference", "paused",
    "user-properties-applied", "metrics", "resumed", "frame-difference",
    "ready", "metrics", "stopped",
], events
ready, red_applied, red, _, green_applied, paused, _, green, reloaded, reloaded_metrics, _ = events

for event in (ready, red, paused, green, reloaded, reloaded_metrics):
    assert event["backend"] == EXPECTED_BACKEND, event
    assert event["scriptErrors"] == 0, event
assert ready["initialUserProperties"]["acceptedScriptProperties"] == 1, ready
assert ready["initialUserProperties"]["ignored"] == 0, ready
for event in (red_applied, green_applied):
    assert event["acceptedScriptProperties"] == 1, event
    assert event["ignored"] == 0, event
assert red["changedPixels"] > 0 and red["totalChannelDelta"] > 0, red
assert paused["paused"] is True, paused
assert green["changedPixels"] > 0 and green["totalChannelDelta"] > 0, green
assert reloaded["initialUserProperties"]["acceptedScriptProperties"] == 1, reloaded

print(f"project UserSetting routing passed: {EXPECTED_BACKEND} barcolor type=color fanout=15")
