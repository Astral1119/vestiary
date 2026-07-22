#!/usr/bin/env python3

import json
import os
import select
import subprocess
import sys
import time


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ELAINA = os.path.join(WORKSHOP, "3326873240")

if not os.path.isfile(os.path.join(ELAINA, "scene.pkg")):
    raise SystemExit(f"Elaina renderer fixture missing: {ELAINA}")


def message(kind, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": "elaina-video-temporal",
        **values,
    }


process = subprocess.Popen(
    [HELPER],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)


def exchange(kind, expected, **values):
    process.stdin.write(json.dumps(message(kind, **values)) + "\n")
    process.stdin.flush()
    readable, _, _ = select.select([process.stdout], [], [], 90)
    assert readable, (kind, "timed out")
    event = json.loads(process.stdout.readline())
    assert event["type"] == expected, event
    return event


ready = exchange(
    "load",
    "ready",
    path=ELAINA,
    assetRoot=ASSETS,
    width=320,
    height=180,
    visible=True,
    evidenceFrames=2,
    userProperties={
        "timevarying": {"value": False},
        "display": {"value": "1"},
    },
)
assert ready["drawComplete"] is True, ready
assert ready["backend"] == EXPECTED_BACKEND, ready
assert ready["range"][0] < ready["range"][1], ready

selection = exchange(
    "user-properties",
    "user-properties-applied",
    properties={
        "timevarying": {"value": False},
        "display": {"value": "1"},
    },
)
assert selection["acceptedScriptProperties"] == 2 and selection["ignored"] == 0

before_motion = exchange("metrics", "metrics")
time.sleep(0.25)
moving = exchange("capture-frame-difference", "frame-difference")
moving_metrics = exchange("metrics", "metrics")
assert moving["drawComplete"] is True, moving
assert moving_metrics["mediaTextures"]["decodes"] > before_motion[
    "mediaTextures"
]["decodes"], (before_motion, moving_metrics)
assert moving_metrics["mediaTextures"]["temporallyActivePlayers"] == 1

exchange("pause", "paused")
paused = exchange("metrics", "metrics")
time.sleep(0.30)
paused_later = exchange("metrics", "metrics")
assert paused_later["frames"] == paused["frames"], (paused, paused_later)

exchange("resume", "resumed")
time.sleep(0.20)
resumed = exchange("capture-frame-difference", "frame-difference")
resumed_metrics = exchange("metrics", "metrics")
assert resumed["drawComplete"] is True, resumed
assert resumed_metrics["mediaTextures"]["decodes"] > paused_later[
    "mediaTextures"
]["decodes"], (paused_later, resumed_metrics)

exchange("hide", "hidden")
time.sleep(0.30)
exchange("show", "shown")
time.sleep(0.20)
shown = exchange("capture-frame-difference", "frame-difference")
assert shown["drawComplete"] is True, shown

exchange("stop", "stopped")
process.stdin.close()
process.wait(timeout=10)
stderr = process.stderr.read()
assert not stderr, stderr

print(f"Elaina video texture: {EXPECTED_BACKEND} temporal playback and host lifecycle passed")
