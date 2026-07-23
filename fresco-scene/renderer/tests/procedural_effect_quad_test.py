#!/usr/bin/env python3

import json
import os
import pathlib
import struct
import subprocess
import sys


HELPER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
LONELY = WORKSHOP / "3299228616"
ASSIGNMENT = "procedural-effect-quad"
IDS = {259, 565, 601, 1170, 1529, 1959}
LANGUAGE_ROOTS = {239, 246, 547, 1155, 1514, 1944}


def read_scene():
    with (LONELY / "scene.pkg").open("rb") as handle:
        def read_u32():
            return struct.unpack("<I", handle.read(4))[0]

        def read_string():
            return handle.read(read_u32()).decode("utf-8")

        assert read_string() == "PKGV0022"
        entries = [
            (read_string(), read_u32(), read_u32())
            for _ in range(read_u32())
        ]
        base = handle.tell()
        _, offset, length = next(entry for entry in entries if entry[0] == "scene.json")
        handle.seek(base + offset)
        return json.loads(handle.read(length))


def message(kind, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": ASSIGNMENT,
        **values,
    }


def load(frames=2, properties=None):
    command = message(
        "load",
        path=str(LONELY),
        assetRoot=str(ASSETS),
        width=320,
        height=180,
        visible=True,
        evidenceFrames=frames,
    )
    if properties is not None:
        command["userProperties"] = properties
    return command


def run(commands, disabled=False, selected=None):
    environment = os.environ.copy()
    environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    environment["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "0"
    if disabled:
        environment["FRESCO_SCENE_PROCEDURAL_QUAD_DISABLED"] = "1"
    if selected is not None:
        environment["FRESCO_SCENE_PROCEDURAL_QUAD_OBJECT_ID"] = str(selected)
    result = subprocess.run(
        [HELPER],
        input="".join(json.dumps(command) + "\n" for command in commands),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=90,
        env=environment,
        check=True,
    )
    assert not result.stderr, result.stderr
    return [json.loads(line) for line in result.stdout.splitlines()]


scene = read_scene()
objects = {value["id"]: value for value in scene["objects"]}
quads = [value for value in scene["objects"] if value.get("shape") == "quad"]
assert {value["id"] for value in quads} == IDS, quads
assert {value["parent"] for value in quads} == LANGUAGE_ROOTS, quads
for quad in quads:
    assert quad["origin"] == "-129.66199 706.48511 0.00000", quad
    assert quad["scale"] == "2.06018 2.06018 2.06018", quad
    assert quad["angles"] == "0.00000 -0.00000 0.00000", quad
    assert quad["castshadow"] is False, quad
    assert len(quad["effects"]) == 1, quad
    effect = quad["effects"][0]
    assert effect["file"] == "effects/lightshafts/effect.json", effect
    assert len(effect["passes"]) == 1, effect
    authored_pass = effect["passes"][0]
    assert authored_pass["combos"] == {"DIRECTDRAW": 1, "RENDERING": 1}, authored_pass
    assert set(authored_pass["constantshadervalues"]) == {
        "colorastart", "colorend", "colorwexponent", "colorwintensity",
        "noiseamount", "noisescale", "point0", "point1", "point2", "point3",
        "rayfeather", "rayradius", "rayscale", "raysmoothness", "rayspeed",
    }, authored_pass

default_roots = {
    value["id"]
    for value in objects.values()
    if value["id"] in LANGUAGE_ROOTS
    and value["visible"]["value"] is True
}
assert default_roots == {246}, default_roots
assert all("image" in objects[root] for root in LANGUAGE_ROOTS), LANGUAGE_ROOTS
assert {
    value["visible"]["user"]["condition"]
    for value in objects.values()
    if value["id"] in LANGUAGE_ROOTS
} == {"1", "2", "3", "4", "5", "6"}
assert objects[601]["parent"] == 246
for root in LANGUAGE_ROOTS:
    descendants = {root}
    pending = [root]
    while pending:
        parent = pending.pop()
        children = {
            value["id"]
            for value in objects.values()
            if value.get("parent") == parent
        }
        descendants.update(children)
        pending.extend(children)
    particles = [
        objects[object_id]
        for object_id in descendants
        if "particle" in objects[object_id]
    ]
    assert len(descendants) == 45, (root, descendants)
    assert len(particles) == 7, (root, particles)
    assert sum(
        particle["particle"] == "particles/presets/fireflies.json"
        for particle in particles
    ) == 1, (root, particles)

enabled = []
disabled = []
for is_disabled, samples in ((False, enabled), (True, disabled)):
    for _ in range(2):
        events = run([load(), message("stop")], disabled=is_disabled)
        assert [event["type"] for event in events] == ["ready", "stopped"], events
        ready = events[0]
        assert ready["backend"] == EXPECTED_BACKEND, ready
        assert ready["drawComplete"] is True and ready["warnings"] == [], ready
        assert ready["deferredScriptValues"] == 0, ready
        samples.append(ready["pixelRGBTotal"])

selected = []
for _ in range(2):
    events = run([load(), message("stop")], selected=601)
    assert [event["type"] for event in events] == ["ready", "stopped"], events
    selected.append(events[0]["pixelRGBTotal"])

baseline_delta = max(abs(enabled[0] - enabled[1]), abs(disabled[0] - disabled[1]))
quad_delta = min(abs(left - right) for left in enabled for right in disabled)
assert quad_delta > 10_000, (
    enabled,
    disabled,
    baseline_delta,
    quad_delta,
)
selected_delta = max(abs(left - right) for left in selected for right in enabled)
assert selected_delta < 10_000, (
    enabled,
    selected,
    selected_delta,
    quad_delta,
)

hidden = []
shown = []
shown_disabled = []
for _ in range(2):
    hidden_events = run([load(), message("stop")], selected=259)
    shown_events = run([
        load(properties={"language": {"value": 2}}),
        message("stop"),
    ], selected=259)
    shown_disabled_events = run([
        load(properties={"language": {"value": 2}}),
        message("stop"),
    ], disabled=True)
    hidden.append(hidden_events[0]["pixelRGBTotal"])
    shown.append(shown_events[0]["pixelRGBTotal"])
    shown_disabled.append(shown_disabled_events[0]["pixelRGBTotal"])
hidden_delta = max(abs(left - right) for left in hidden for right in disabled)
assert hidden_delta < 10_000, (
    hidden,
    disabled,
    hidden_delta,
    quad_delta,
)
control_noise = max(1, baseline_delta, selected_delta, hidden_delta)
assert quad_delta > control_noise * 5, (
    enabled,
    disabled,
    selected,
    hidden,
    control_noise,
    quad_delta,
)
shown_baseline = max(abs(shown_disabled[0] - shown_disabled[1]), 1)
shown_delta = min(abs(left - right) for left in shown for right in shown_disabled)
assert shown_delta > 10_000 and shown_delta > shown_baseline * 5, (
    shown,
    shown_disabled,
    shown_baseline,
    shown_delta,
)

lifecycle = run([
    load(60),
    message("pause"),
    message("metrics"),
    message("capture-frame-difference"),
    message("metrics"),
    message("resume"),
    message("capture-frame-difference"),
    load(60),
    message("metrics"),
    message("stop"),
])
assert [event["type"] for event in lifecycle] == [
    "ready", "paused", "metrics", "frame-difference", "metrics",
    "resumed", "frame-difference", "ready", "metrics", "stopped",
], lifecycle
ready, _, paused, paused_frame, paused_after, _, resumed, reloaded, reloaded_metrics, _ = lifecycle
for event in (ready, reloaded):
    assert event["backend"] == EXPECTED_BACKEND, event
    assert event["drawComplete"] is True and event["warnings"] == [], event
assert paused["paused"] is True and paused_after["paused"] is True, (paused, paused_after)
assert paused["frames"] == paused_after["frames"], (paused, paused_frame, paused_after)
assert paused_frame["changedPixels"] == 0, paused_frame
assert resumed["changedPixels"] > 0, resumed
assert reloaded_metrics["paused"] is False and reloaded_metrics["visible"] is True, reloaded_metrics

print(
    f"procedural effect quad: {EXPECTED_BACKEND} Lonely=6 default=601 "
    f"baseline={baseline_delta} quad={quad_delta} selected={selected[0]} "
    f"selectedDelta={selected_delta} "
    f"hidden={hidden[0]} hiddenDelta={hidden_delta} "
    f"controlNoise={control_noise} shownDelta={shown_delta}"
)
