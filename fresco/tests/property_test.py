#!/usr/bin/env python3

import importlib.util
import json
import os
import tempfile
from contextlib import redirect_stdout
from io import StringIO
from importlib.machinery import SourceFileLoader

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOADER = SourceFileLoader("fresco_cli", os.path.join(ROOT, "fresco"))
SPEC = importlib.util.spec_from_loader("fresco_cli", LOADER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load fresco CLI")
FRESCO = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(FRESCO)


def definition(name, property_type, **fields):
    return {"name": name, "type": property_type, **fields}


def expect_failure(callback):
    try:
        callback()
    except SystemExit:
        return
    raise AssertionError("expected validation failure")


assert FRESCO.parse_property_value(definition("enabled", "bool"), "on") is True
assert FRESCO.parse_property_value(definition("enabled", "bool"), "false") is False
assert FRESCO.parse_property_value(
    definition("speed", "slider", min=1, max=10), "7.5") == 7.5
expect_failure(lambda: FRESCO.parse_property_value(
    definition("speed", "slider", min=1, max=10), "11"))
assert FRESCO.parse_property_value(
    definition("accent", "color"), "#ff8000") == "1 0.501961 0"
expect_failure(lambda: FRESCO.parse_property_value(
    definition("accent", "color"), "2 0 0"))
combo = definition("mode", "combo", options=[
    {"value": 1, "label": "One"}, {"value": "wide", "label": "Wide"},
])
assert FRESCO.parse_property_value(combo, "1") == 1
assert FRESCO.parse_property_value(combo, "wide") == "wide"
expect_failure(lambda: FRESCO.parse_property_value(combo, "missing"))
assert FRESCO.parse_property_value(
    definition("caption", "textinput"), "hello world") == "hello world"

with tempfile.TemporaryDirectory() as temporary:
    image = os.path.join(temporary, "image.png")
    video = os.path.join(temporary, "video.mp4")
    open(image, "wb").close()
    open(video, "wb").close()
    assert FRESCO.parse_property_value(
        definition("image", "file", fileType="image"), image) == os.path.realpath(image)
    assert FRESCO.parse_property_value(
        definition("slides", "directory"), temporary) == os.path.realpath(temporary)
    expect_failure(lambda: FRESCO.parse_property_value(
        definition("image", "file", fileType="image"), video))

    state_path = os.path.join(temporary, "properties", "fixture.json")
    description = {
        "statePath": state_path,
        "wallpaperPath": "/tmp/fixture",
        "title": "Fixture",
    }
    FRESCO.save_property_record(description, {"speed": 7})
    with open(state_path) as handle:
        record = json.load(handle)
    assert record["schemaVersion"] == 1
    assert record["values"] == {"speed": 7}

    scene_path = os.path.join(temporary, "scene")
    os.makedirs(scene_path)
    scene_state = os.path.join(temporary, "properties", "scene.json")
    scene_description = {
        "statePath": scene_state,
        "stateID": "3448290956",
        "wallpaperPath": scene_path,
        "title": "Scene fixture",
        "kind": "scene",
        "presentation": [
            definition(
                "musicvolume", "slider", value=0.5, min=0, max=1,
                editable=True, runtimeSupported=True, active=True,
            ),
            definition(
                "tint", "color", value="1 1 1", editable=True,
                runtimeSupported=False, active=True,
            ),
        ],
    }
    original_describe = FRESCO.describe_project
    original_apply = FRESCO.apply_property_state
    applied = []
    FRESCO.describe_project = lambda path: scene_description
    FRESCO.apply_property_state = applied.append
    with redirect_stdout(StringIO()):
        FRESCO.property_command([scene_path, "list"])
        FRESCO.property_command([scene_path, "get", "musicvolume"])
        FRESCO.property_command([scene_path, "set", "musicvolume", "0.25"])
        FRESCO.property_command([scene_path, "set", "tint", "#804000"])
        FRESCO.property_command([scene_path, "reset", "musicvolume"])
    _, scene_values = FRESCO.property_record(scene_description)
    assert scene_values == {"tint": "0.501961 0.25098 0"}, scene_values
    assert applied == [scene_path, scene_path, scene_path]
    FRESCO.describe_project = original_describe
    FRESCO.apply_property_state = original_apply

    original_resolve = FRESCO.resolve
    original_current = FRESCO.current_wallpaper_path
    FRESCO.resolve = lambda target: scene_path if target == "3448290956" else os.path.realpath(target)
    assert FRESCO.property_target("3448290956") == scene_path
    assert FRESCO.property_target(scene_path) == os.path.realpath(scene_path)
    current_target = ["3448290956"]
    FRESCO.current_wallpaper_path = lambda: current_target[0]
    assert FRESCO.property_target("current") == scene_path
    current_target[0] = scene_path
    assert FRESCO.property_target("current") == os.path.realpath(scene_path)
    FRESCO.resolve = original_resolve
    FRESCO.current_wallpaper_path = original_current

    original_pid = FRESCO.runtime_pid
    original_stale = FRESCO.runtime_stale
    original_kill = FRESCO.os.kill
    signals = []
    FRESCO.runtime_pid = lambda: 123
    FRESCO.runtime_stale = lambda pid: False
    FRESCO.os.kill = lambda pid, sent_signal: signals.append((pid, sent_signal))
    with redirect_stdout(StringIO()):
        FRESCO.apply_property_state(os.path.join(temporary, "inactive-scene"))
    assert signals == [(123, FRESCO.signal.SIGHUP)]
    FRESCO.runtime_pid = original_pid
    FRESCO.runtime_stale = original_stale
    FRESCO.os.kill = original_kill

assert FRESCO.clean_property_label("<br>Visual&nbsp;Time") == "Visual Time"
print("Property CLI checks passed")
