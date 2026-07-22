#!/usr/bin/env python3

import json
import os
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "lonely-clock-texture-frame"


def message(message_type, **values):
    return {
        "protocolVersion": 1,
        "type": message_type,
        "assignmentID": ASSIGNMENT,
        **values,
    }


lonely = os.path.join(WORKSHOP, "3299228616")
assert os.path.isfile(os.path.join(lonely, "scene.pkg")), lonely
load = message(
    "load",
    path=lonely,
    assetRoot=ASSETS,
    width=320,
    height=180,
    visible=True,
    evidenceFrames=2,
)
commands = [
    load,
    message("pause"),
    message("metrics"),
    message("resume"),
    message("capture-frame-difference"),
    load,
    message("metrics"),
    message("stop"),
]
environment = os.environ.copy()
environment["FRESCO_SCENE_SCRIPT_CLOCK_HOUR"] = "9"
result = subprocess.run(
    [HELPER],
    input="".join(json.dumps(command) + "\n" for command in commands),
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=45,
    check=True,
    env=environment,
)
assert not result.stderr, result.stderr
events = [json.loads(line) for line in result.stdout.splitlines()]
assert [event["type"] for event in events] == [
    "ready",
    "paused",
    "metrics",
    "resumed",
    "frame-difference",
    "ready",
    "metrics",
    "stopped",
], events
ready, _, paused, _, resumed, reloaded, reloaded_metrics, _ = events

for event in (ready, paused, resumed, reloaded, reloaded_metrics):
    assert event["backend"] == EXPECTED_BACKEND, event
    assert event["genericPropertyScripts"] == 36, event
    assert event["genericPropertyScriptErrors"] == 0, event
    assert event["scriptErrors"] == 0, event
assert ready["deferredScriptValues"] == 0, ready
assert not any("SceneScript dynamic values" in warning for warning in ready["warnings"]), ready
assert ready["genericPropertyScriptUpdates"] == 108, ready
assert ready["genericPropertyScriptChanges"] == 30, ready
assert paused["paused"] is True, paused
assert paused["genericPropertyScriptUpdates"] == 108, paused
assert paused["genericPropertyScriptChanges"] == 30, paused
assert resumed["genericPropertyScriptUpdates"] == 144, resumed
assert resumed["genericPropertyScriptChanges"] == 30, resumed
for event in (reloaded, reloaded_metrics):
    assert event["genericPropertyScriptUpdates"] == 108, event
    assert event["genericPropertyScriptChanges"] == 30, event


def render_at_hour(hour):
    environment = os.environ.copy()
    environment["FRESCO_SCENE_SCRIPT_CLOCK_HOUR"] = str(hour)
    render_assignment = f"{ASSIGNMENT}-hour-{hour}"
    render_commands = [
        {
            **load,
            "assignmentID": render_assignment,
            "evidenceFrames": 1,
        },
        {
            **message("stop"),
            "assignmentID": render_assignment,
        },
    ]
    rendered = subprocess.run(
        [HELPER],
        input="".join(json.dumps(command) + "\n" for command in render_commands),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=45,
        check=True,
        env=environment,
    )
    assert not rendered.stderr, rendered.stderr
    render_events = [json.loads(line) for line in rendered.stdout.splitlines()]
    assert [event["type"] for event in render_events] == ["ready", "stopped"], render_events
    assert render_events[0]["backend"] == EXPECTED_BACKEND, render_events[0]
    return render_events[0]["pixelRGBAHash"]


morning_hash = render_at_hour(9)
evening_hash = render_at_hour(18)
assert morning_hash != evening_hash, (morning_hash, evening_hash)

print(
    f"SceneScript texture-frame passed: {EXPECTED_BACKEND} Lonely consumers=30; "
    "composited frames differ across authored clock states"
)
