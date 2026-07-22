#!/usr/bin/env python3

import collections
import hashlib
import json
import os
import pathlib
import struct
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = pathlib.Path(os.path.abspath(sys.argv[2]))
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
PROJECT = WORKSHOP / "3460973721"
ASSIGNMENT = "arknights-promotion-gate"
PACKAGE_SHA256 = "1dca928a8f1acf64e1f13aa7d2a7bc54631d452c7f613887030c1c972a2eb807"
PROPERTY_INVENTORY_SHA256 = "230354c0d941cb1dd9f4f74562c61f4b2abdbf93390b099189117cac8ec187af"


def message(kind, assignment=ASSIGNMENT, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": assignment,
        **values,
    }


def environment():
    result = os.environ.copy()
    result["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    result["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "1"
    result["FRESCO_SCENE_SCRIPT_CLOCK_HOUR"] = "9"
    return result


INITIAL_PROPERTIES = {
    "_24": {"value": True},
    "music": {"value": "1"},
    "newproperty": {"value": 1.0},
    "newproperty1": {"value": 0.45},
    "newproperty2": {"value": 1.0},
    "newproperty3": {"value": 1.0},
    "newproperty4": {"value": 0.58},
    "newproperty5": {"value": 1.0},
    "newproperty6": {"value": "1 1 1"},
    "newproperty11": {"value": 0.5},
    "newproperty12": {"value": "0.2"},
    "newproperty13": {"value": "0"},
    "suipian": {"value": True},
    "time": {"value": "1"},
    "time1": {"value": True},
    "yangshi": {"value": "2"},
    "yinpin": {"value": "1"},
}


def load(assignment=ASSIGNMENT, *, frames=120, visible=True, properties=None):
    return message(
        "load",
        assignment,
        path=str(PROJECT),
        assetRoot=ASSETS,
        width=320,
        height=180,
        fps=60,
        visible=visible,
        muted=True,
        evidenceFrames=frames,
        userProperties=properties or INITIAL_PROPERTIES,
    )


def run_batch(commands, timeout=240):
    result = subprocess.run(
        [HELPER],
        input="".join(json.dumps(command) + "\n" for command in commands),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        env=environment(),
        check=True,
    )
    assert not result.stderr, result.stderr
    return [json.loads(line) for line in result.stdout.splitlines()]


def package_documents():
    with (PROJECT / "scene.pkg").open("rb") as handle:
        def read_u32():
            return struct.unpack("<I", handle.read(4))[0]

        def read_string():
            return handle.read(read_u32()).decode("utf-8")

        assert read_string() == "PKGV0024"
        entries = [
            (read_string(), read_u32(), read_u32())
            for _ in range(read_u32())
        ]
        base = handle.tell()
        documents = {}
        for name, offset, length in entries:
            if not name.endswith(".json"):
                continue
            handle.seek(base + offset)
            documents[name] = json.loads(handle.read(length))
        return documents


def scripted_values(value, object_id=None, path=()):
    if isinstance(value, dict):
        next_object_id = value.get("id", object_id) if path[:1] == ("objects",) else object_id
        if isinstance(value.get("script"), str):
            yield next_object_id, path, value
        for key, child in value.items():
            if key != "script":
                yield from scripted_values(child, next_object_id, path + (str(key),))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            child_id = child.get("id") if path == ("objects",) and isinstance(child, dict) else object_id
            yield from scripted_values(child, child_id, path + (str(index),))


def corpus_contract():
    documents = package_documents()
    scene = documents["scene.json"]
    scripts = list(scripted_values(scene))
    observed = collections.Counter()
    cursor_objects = []
    for object_id, path, value in scripts:
        field = path[-1]
        source = value["script"]
        if field == "text":
            assert object_id in {90, 96, 101}
            assert "export function update" in source and "new Date()" in source
            observed["clockText"] += 1
        elif object_id == 95:
            assert field == "visible"
            assert "applyUserProperties" in source and "playTargetMusic" in source
            observed["musicController"] += 1
        else:
            assert field == "visible" and object_id in {90, 96, 101, 113, 144}
            for token in (
                "export function resetPosition()",
                "localStorage.remove(",
                "thisLayer.originalOrigin",
                "export function cursorDown(event)",
                "export function cursorMove(event)",
                "export function cursorUp(event)",
                "export function init()",
                "shared.miDragable",
            ):
                assert token in source, (object_id, token)
            cursor_objects.append(object_id)
            observed["cursorStorage"] += 1
    assert observed == {
        "clockText": 3,
        "cursorStorage": 5,
        "musicController": 1,
    }, observed
    assert sorted(cursor_objects) == [90, 96, 101, 113, 144]

    objects = {item["id"]: item for item in scene["objects"]}
    assert all(objects[item]["parent"] == 88 for item in (90, 96, 101))
    assert objects[88]["visible"] == {"user": "time1", "value": True}
    assert objects[113]["visible"]["value"] is False
    assert objects[113]["visible"]["user"] == {"condition": "1", "name": "yangshi"}
    assert objects[144]["visible"]["value"] is True
    assert objects[144]["visible"]["user"] == {"condition": "2", "name": "yangshi"}
    for item in (90, 96, 101):
        assert objects[item]["visible"]["scriptproperties"]["isMovable"] == {
            "user": {"condition": "1", "name": "time"},
            "value": True,
        }
    assert objects[144]["visible"]["scriptproperties"]["isMovable"] == {
        "user": {"condition": "1", "name": "yinpin"},
        "value": True,
    }
    assert objects[113]["visible"]["scriptproperties"]["isMovable"] == {
        "user": {"condition": "1", "name": "yinpin"},
        "value": {
            "user": {"condition": "1", "name": "time"},
            "value": True,
        },
    }

    project = json.loads((PROJECT / "project.json").read_text(encoding="utf-8"))
    properties = project["general"]["properties"]
    inventory = {
        key: [value["type"], value.get("value")]
        for key, value in sorted(properties.items())
    }
    encoded = json.dumps(
        inventory, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode()
    assert len(inventory) == 29
    assert hashlib.sha256(encoded).hexdigest() == PROPERTY_INVENTORY_SHA256
    assert collections.Counter(value[0] for value in inventory.values()) == {
        "bool": 7,
        "color": 2,
        "combo": 5,
        "group": 1,
        "scenetexture": 1,
        "slider": 10,
        "textinput": 3,
    }
    functional = {
        key: inventory[key]
        for key in (
            "_24", "music", "newproperty", "newproperty1", "newproperty2",
            "newproperty3", "newproperty4", "newproperty5", "newproperty6",
            "newproperty9", "newproperty10", "newproperty11", "newproperty12",
            "newproperty13", "suipian", "time", "time1", "yangshi", "yinpin",
        )
    }
    assert functional["music"] == ["combo", "1"]
    assert functional["time"] == ["combo", "1"]
    assert functional["yangshi"] == ["combo", "2"]
    assert functional["suipian"] == ["bool", True]

    particles = {
        item["id"]: item["particle"]
        for item in scene["objects"] if "particle" in item
    }
    assert particles == {
        46: "particles/workshop/2446178284/rising_debris_copy1.json",
        73: "particles/workshop/2446178284/dust_copy1.json",
        126: "particles/presets/wildfire.json",
    }
    return {
        "scripts": dict(observed),
        "projectProperties": len(inventory),
        "functionalProperties": len(functional),
        "cursorStorageObjects": sorted(cursor_objects),
        "defaultActiveCursorStorageObjects": [90, 96, 101, 144],
        "alternateCursorStorageObject": 113,
        "particleObjects": particles,
    }


def sound_ownership(event):
    return {
        control["id"]: control
        for control in event["soundControls"]
        if control["requestedPlaying"]
    }


def assert_clean(event):
    assert event["backend"] == EXPECTED_BACKEND, event
    assert event["drawComplete"] is True, event
    assert event["deferredScriptValues"] == 0, event
    assert event["genericPropertyScripts"] == 5, event
    assert event["scriptLayers"] == 3, event
    for field in (
        "scriptErrors",
        "propertyScriptErrors",
        "genericPropertyScriptErrors",
        "mediaPropertyScriptErrors",
    ):
        assert event[field] == 0, (field, event)
    assert not event["warnings"], event["warnings"]


def lifecycle():
    changed = {
        "_24": {"value": False},
        "music": {"value": "2"},
        "newproperty1": {"value": 0.2},
        "newproperty2": {"value": 2.0},
        "newproperty3": {"value": 1.5},
        "newproperty4": {"value": 0.8},
        "newproperty5": {"value": 1.5},
        "newproperty13": {"value": "60"},
        "suipian": {"value": False},
        "time": {"value": "2"},
        "yangshi": {"value": "1"},
        "yinpin": {"value": "2"},
    }
    commands = [
        load(),
        message("metrics"),
        message("cursor-down", x=150, y=90),
        message("cursor-move", x=175, y=105),
        message("cursor-up", x=175, y=105),
        message("capture-frame-difference"),
        message("user-properties", properties=changed),
        *[message("capture-frame-difference") for _ in range(15)],
        message("metrics"),
        message("pause"),
        message("metrics"),
        message("capture-frame-difference"),
        message("metrics"),
        message("resume"),
        message("hide"),
        message("metrics"),
        message("show"),
        load(),
        message("metrics"),
        message("stop"),
    ]
    events = run_batch(commands)
    assert events[0]["type"] == "ready" and events[-1]["type"] == "stopped", events
    ready = events[0]
    baseline_metrics = events[1]
    cursor_events = events[2:5]
    dragged = events[5]
    applied = events[6]
    changed_frames = events[7:22]
    changed_metrics = events[22]
    paused_metrics = events[24]
    paused_frame = events[25]
    paused_after = events[26]
    hidden_metrics = events[29]
    reloaded = events[31]
    reloaded_metrics = events[32]
    for event in (ready, reloaded):
        assert_clean(event)
    assert ready["initialUserProperties"]["ignored"] == 0, ready
    assert ready["initialUserProperties"]["acceptedScriptProperties"] >= 6, ready
    assert [event["phase"] for event in cursor_events] == ["down", "move", "up"]
    assert all(event["handled"] == 5 for event in cursor_events), cursor_events
    assert dragged["changedPixels"] > 0, dragged
    assert applied["ignored"] == 0, applied
    assert applied["acceptedScriptProperties"] >= 6, applied
    assert any(frame["changedPixels"] > 0 for frame in changed_frames)
    ownership = sound_ownership(changed_metrics)
    assert set(ownership) == {82}, ownership
    assert changed_metrics["particleSimulationSteps"] > baseline_metrics["particleSimulationSteps"]
    assert paused_after["frames"] == paused_metrics["frames"], (paused_metrics, paused_after)
    assert paused_frame["drawComplete"] is True and paused_after["paused"] is True
    assert hidden_metrics["visible"] is False, hidden_metrics
    assert reloaded_metrics["paused"] is False and reloaded_metrics["visible"] is True
    assert set(sound_ownership(reloaded_metrics)) == {76}, reloaded_metrics
    return {
        "cursorHandlers": cursor_events[0]["handled"],
        "propertyBindings": applied["acceptedScriptProperties"],
        "particleSteps": changed_metrics["particleSimulationSteps"],
        "selectedSound": 82,
    }


def restart_contract():
    command = [load(frames=30), message("metrics"), message("stop")]
    runs = [run_batch(command) for _ in range(2)]
    for events in runs:
        assert [event["type"] for event in events] == ["ready", "metrics", "stopped"]
        assert_clean(events[0])
        assert set(sound_ownership(events[1])) == {76}, events[1]
    difference = abs(runs[0][0]["pixelRGBTotal"] - runs[1][0]["pixelRGBTotal"])
    assert difference < 10_000, difference
    return {"frontBufferDifference": difference}


def textinput_contract():
    assignment = f"{ASSIGNMENT}-textinput"
    events = run_batch([
        load(assignment, frames=2, visible=False),
        message(
            "user-properties",
            assignment,
            properties={
                "newproperty12": {"value": "0.75"},
                "newproperty13": {"value": "-2"},
            },
        ),
        message(
            "user-properties",
            assignment,
            properties={
                "newproperty12": {"value": True},
                "newproperty13": {"value": "bad\0clock"},
            },
        ),
        message(
            "user-properties",
            assignment,
            properties={"newproperty12": {"value": "x" * 4097}},
        ),
        message("stop", assignment),
    ])
    assert [event["type"] for event in events] == [
        "ready", "user-properties-applied", "user-properties-applied",
        "user-properties-applied", "stopped",
    ], events
    ready, valid, invalid, oversized, _ = events
    assert_clean(ready)
    assert ready["initialUserProperties"]["ignored"] == 0, ready
    assert (valid["received"], valid["acceptedScriptProperties"], valid["ignored"]) == (
        2, 2, 0
    ), valid
    assert (invalid["received"], invalid["acceptedScriptProperties"], invalid["ignored"]) == (
        2, 0, 2
    ), invalid
    assert any("expected text" in value for value in invalid["diagnostics"]), invalid
    assert any("embedded NUL" in value for value in invalid["diagnostics"]), invalid
    assert (oversized["received"], oversized["acceptedScriptProperties"], oversized["ignored"]) == (
        1, 0, 1
    ), oversized
    assert any("exceeds 4096 bytes" in value for value in oversized["diagnostics"]), oversized
    return {"accepted": 2, "rejected": 3, "maximumBytes": 4096}


def particle_visual_ab():
    def render(overrides, suffix):
        properties = dict(INITIAL_PROPERTIES)
        properties.update(overrides)
        assignment = f"{ASSIGNMENT}-particle-{suffix}"
        events = run_batch([load(assignment, frames=180, properties=properties), message("stop", assignment)])
        assert [event["type"] for event in events] == ["ready", "stopped"], events
        assert_clean(events[0])
        return events[0]["pixelRGBTotal"]

    enabled = (render({}, "enabled-a"), render({}, "enabled-b"))
    baseline = abs(enabled[0] - enabled[1])
    disabled = {
        "risingDebris": render({"suipian": {"value": False}}, "debris-off"),
        "dust": render({"newproperty5": {"value": 0.0}}, "dust-off"),
        "wildfire": render({"newproperty1": {"value": 0.0}}, "wildfire-off"),
    }
    deltas = {
        name: min(abs(value - reference) for reference in enabled)
        for name, value in disabled.items()
    }
    assert all(value > 100 and value > max(1, baseline) * 4 for value in deltas.values()), (
        enabled, disabled, baseline, deltas
    )
    return {"baseline": baseline, "deltas": deltas}


assert (PROJECT / "scene.pkg").is_file(), PROJECT
assert hashlib.sha256((PROJECT / "scene.pkg").read_bytes()).hexdigest() == PACKAGE_SHA256
summary = {
    "id": "3460973721",
    "backend": EXPECTED_BACKEND,
    "corpus": corpus_contract(),
    "lifecycle": lifecycle(),
    "restart": restart_contract(),
    "textinput": textinput_contract(),
    "particles": particle_visual_ab(),
}
print(json.dumps(summary, separators=(",", ":")))
