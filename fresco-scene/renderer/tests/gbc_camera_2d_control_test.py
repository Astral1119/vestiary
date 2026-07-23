#!/usr/bin/env python3

import json
import os
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "gbc-camera-2d"


def message(message_type, **values):
    return {
        "protocolVersion": 1,
        "type": message_type,
        "assignmentID": ASSIGNMENT,
        **values,
    }


def run(commands, disabled=False):
    environment = os.environ.copy()
    if disabled:
        environment["FRESCO_SCENE_2D_CAMERA_DISABLED"] = "1"
    result = subprocess.run(
        [HELPER], input="".join(json.dumps(command) + "\n" for command in commands),
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=environment, timeout=90, check=True,
    )
    assert not result.stderr, result.stderr
    return [json.loads(line) for line in result.stdout.splitlines()]


gbc = os.path.join(WORKSHOP, "3448290956")
hyuga = os.path.join(WORKSHOP, "3479521040")
load = message(
    "load", path=gbc, assetRoot=ASSETS, width=320, height=180,
    visible=True, evidenceFrames=2,
)

disabled = run([load, message("stop")], disabled=True)[0]
hyuga_default = run([
    message(
        "load", path=hyuga, assetRoot=ASSETS, width=320, height=180,
        visible=False, evidenceFrames=2,
    ),
    message("stop"),
])[0]
hyuga_enabled = run([
    message(
        "load", path=hyuga, assetRoot=ASSETS, width=320, height=180,
        visible=False, evidenceFrames=2,
        userProperties={"newproperty": {"value": True}},
    ),
    message("stop"),
])[0]
hyuga_live_events = run([
    message(
        "load", path=hyuga, assetRoot=ASSETS, width=320, height=180,
        visible=False, evidenceFrames=2,
    ),
    message("user-properties", properties={"newproperty": {"value": True}}),
    message("user-properties", properties={"newproperty": {"value": False}}),
    message("stop"),
])
commands = [
    load,
    message("metrics"),
    message("capture-frame-difference"),
    message("user-properties", properties={"x3": {"value": 0.1}}),
    message("capture-frame-difference"),
    message("metrics"),
    message("user-properties", properties={"x3": {"value": 0}, "y1": {"value": 0.1}}),
    message("capture-frame-difference"),
    message("metrics"),
    message("user-properties", properties={"y1": {"value": 0}, "newproperty30": {"value": 1.2}}),
    message("capture-frame-difference"),
    message("metrics"),
    message("pause"),
    message("user-properties", properties={"x3": {"value": 0.2}}),
    message("metrics"),
    message("resume"),
    message("capture-frame-difference"),
    message("metrics"),
    load,
    message("metrics"),
    message("stop"),
]
events = run(commands)
ready = events[0]
assert ready["backend"] == EXPECTED_BACKEND, ready
assert disabled["backend"] == EXPECTED_BACKEND, disabled
assert ready["camera2DActive"] is True, ready
assert disabled["camera2DActive"] is False, disabled
assert ready["camera2DCenter"] == [1920, 1080], ready
assert ready["camera2DZoom"] == 1, ready
identity_delta = abs(ready["pixelRGBTotal"] - disabled["pixelRGBTotal"])
assert identity_delta < 10_000, (identity_delta, ready, disabled)
assert hyuga_default["camera2DActive"] is False, hyuga_default
assert not any("camera" in warning for warning in hyuga_default["warnings"]), hyuga_default
assert not any("puppet" in warning for warning in hyuga_default["warnings"]), hyuga_default
assert (
    "camera 309 is property-gated off; enabling it is unsupported because "
    "only canvas-origin scripted 2D cameras are implemented"
) in hyuga_enabled["warnings"], hyuga_enabled
hyuga_live_enabled, hyuga_live_disabled = hyuga_live_events[1:3]
assert (
    "camera 309 is property-gated off; enabling it is unsupported because "
    "only canvas-origin scripted 2D cameras are implemented"
) in hyuga_live_enabled["warnings"], hyuga_live_enabled
assert hyuga_live_disabled["warnings"] == [], hyuga_live_disabled

for event in events:
    if event["type"] in ("ready", "metrics", "frame-difference"):
        assert event["backend"] == EXPECTED_BACKEND, event
        assert event["genericPropertyScripts"] == 10, event
        assert event["genericPropertyScriptErrors"] == 0, event
        assert event["scriptErrors"] == 0, event
        if event["type"] == "ready":
            assert event["deferredScriptValues"] == 0, event
            assert not any("SceneScript" in warning for warning in event["warnings"]), event

metrics = [event for event in events if event["type"] == "metrics"]
assert len(metrics) == 7, metrics
initial, x_shift, y_shift, zoomed, paused, resumed, reloaded = metrics
assert (initial["camera2DCenter"], initial["camera2DZoom"]) == ([1920, 1080], 1), initial
assert (x_shift["camera2DCenter"], x_shift["camera2DZoom"]) == ([2304, 1080], 1), x_shift
assert (y_shift["camera2DCenter"], y_shift["camera2DZoom"]) == ([1920, 1296], 1), y_shift
assert zoomed["camera2DCenter"] == [1920, 1080], zoomed
assert abs(zoomed["camera2DZoom"] - 1.2) < 0.0001, zoomed
assert paused["paused"] is True, paused
assert paused["camera2DCenter"] == [1920, 1080], paused
assert resumed["camera2DCenter"] == [2688, 1080], resumed
assert abs(resumed["camera2DZoom"] - 1.2) < 0.0001, resumed
assert (reloaded["camera2DCenter"], reloaded["camera2DZoom"]) == ([1920, 1080], 1), reloaded

differences = [event for event in events if event["type"] == "frame-difference"]
assert len(differences) == 5, differences
for event in differences[1:]:
    assert 0 < event["changedPixels"] <= 320 * 180 * 4, event

applied = [event for event in events if event["type"] == "user-properties-applied"]
assert [event["acceptedScriptProperties"] for event in applied] == [1, 2, 2, 1], applied

print(
    f"GBC empty-path 2D camera passed: {EXPECTED_BACKEND} "
    f"default=identity RGBDelta={identity_delta} "
    "x/y/zoom=visible pause/reload=stable"
)
