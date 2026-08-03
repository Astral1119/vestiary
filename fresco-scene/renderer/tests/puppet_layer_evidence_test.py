#!/usr/bin/env python3

"""Pins the per-layer puppet playback readout against GBC's authored inputs.

GBC object 179 (头位置) carries two additive animation layers whose rate is
scripted. With audio disabled the rate script falls back to its authored
silence value, so the rate is deterministic here.
"""

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
GBC = os.path.join(WORKSHOP, "3448290956")

process = subprocess.Popen(
    [HELPER],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)


def exchange(kind, expected, **values):
    process.stdin.write(
        json.dumps(
            {
                "protocolVersion": 1,
                "type": kind,
                "assignmentID": "puppet-layer-evidence",
                **values,
            }
        )
        + "\n"
    )
    process.stdin.flush()
    readable, _, _ = select.select([process.stdout], [], [], 90)
    assert readable, (kind, "timed out")
    event = json.loads(process.stdout.readline())
    assert event["type"] == expected, event
    return event


def layers_of(evidence, object_id):
    return {
        layer["layerID"]: layer
        for layer in evidence["layers"]
        if layer["objectID"] == object_id
    }


ready = exchange(
    "load",
    "ready",
    path=GBC,
    assetRoot=ASSETS,
    width=320,
    height=180,
    visible=True,
    evidenceFrames=2,
)
assert ready["backend"] == EXPECTED_BACKEND, ready
assert ready["drawComplete"] is True, ready

first = exchange("capture-puppet-evidence", "puppet-evidence")
assert first["loadedMeshes"] == 9, first

head = layers_of(first, 179)
assert sorted(head) == [193, 200], first["layers"]

# Authored: both layers additive, blend 0.3, visible, rate 1.5 at the script's
# silence fallback. Animation 196 is the 120-frame 摇头; 186 is the 60-frame 动画 2.
assert head[200]["animationID"] == 196, head[200]
assert head[193]["animationID"] == 186, head[193]
assert head[200]["length"] == 120, head[200]
assert head[193]["length"] == 60, head[193]
for layer in head.values():
    assert layer["visible"] is True, layer
    assert layer["additive"] is True, layer
    assert layer["sampled"] is True, layer
    assert abs(layer["rate"] - 1.5) < 1e-6, layer
    assert abs(layer["requestedBlend"] - 0.3) < 1e-6, layer
    assert abs(layer["framesPerSecond"] - 30.0) < 1e-6, layer
    # The authored slider stops well inside the clamp, so the applied weight is
    # the requested one. A slider past 1.0 is what separates them.
    assert layer["appliedBlend"] == layer["requestedBlend"], layer

# No layer in the stack is a replacement, so the composition promotes the first
# sampled one to supply the base pose. That promotion moves the rest pose off
# the bind pose, so it is recorded rather than left implicit.
assert head[200]["replacement"] is True, head[200]
assert head[200]["promotedToReplacement"] is True, head[200]
assert head[193]["replacement"] is False, head[193]
assert head[193]["promotedToReplacement"] is False, head[193]

time.sleep(0.40)
exchange("capture-frame-difference", "frame-difference")
second = exchange("capture-puppet-evidence", "puppet-evidence")
advanced = layers_of(second, 179)

for layer_id, layer in advanced.items():
    previous = head[layer_id]
    assert layer["framesAdvanced"] > previous["framesAdvanced"], (previous, layer)
    assert layer["updates"] > previous["updates"], (previous, layer)
assert second["deformationChanges"] > first["deformationChanges"], second

# Frames advance on the animation clock, so a paused scene freezes them.
exchange("pause", "paused")
paused = exchange("capture-puppet-evidence", "puppet-evidence")
time.sleep(0.20)
assert exchange("capture-puppet-evidence", "puppet-evidence") == paused

metrics = exchange("metrics", "metrics")
assert metrics["puppet"]["loadedMeshes"] == 9, metrics["puppet"]
assert layers_of(metrics["puppet"], 179).keys() == {193, 200}, metrics["puppet"]

exchange("stop", "stopped")
process.stdin.close()
process.wait(timeout=10)
stderr = process.stderr.read()
assert not stderr, stderr

print(
    f"Puppet per-layer evidence: {EXPECTED_BACKEND} GBC object 179 layers "
    "200/193 additive at blend 0.3, layer 200 promoted, frames advancing"
)
