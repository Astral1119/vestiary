#!/usr/bin/env python3

import json
import os
import struct
import sys


WORKSHOP = os.path.abspath(sys.argv[1])
PERSONA = os.path.join(WORKSHOP, "3151551777")


def package_scene():
    with open(os.path.join(PERSONA, "scene.pkg"), "rb") as package:
        def u32():
            return struct.unpack("<I", package.read(4))[0]

        def string():
            return package.read(u32()).decode("utf-8")

        revision = string()
        entries = [(string(), u32(), u32()) for _ in range(u32())]
        base = package.tell()
        _, offset, length = next(entry for entry in entries if entry[0] == "scene.json")
        package.seek(base + offset)
        return revision, json.loads(package.read(length))


def scripted_values(node, path=""):
    if isinstance(node, dict):
        if isinstance(node.get("script"), str):
            yield path, node
        for key, value in node.items():
            yield from scripted_values(value, f"{path}/{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            yield from scripted_values(value, f"{path}/{index}")


revision, scene = package_scene()
assert revision == "PKGV0021", revision
with open(os.path.join(PERSONA, "project.json"), encoding="utf-8") as project_file:
    project = json.load(project_file)
properties = project["general"]["properties"]

playback = []
colors = []
origins = []
commented = []
type_mismatch = []

for index, obj in enumerate(scene["objects"]):
    for path, wrapped in scripted_values(obj):
        source = wrapped["script"]
        record = (obj["id"], obj["name"], path, wrapped)
        if "mediaPlaybackChanged" in source:
            assert path == "/visible", record
            assert "event.state !== MediaPlaybackEvent.PLAYBACK_STOPPED" in source, record
            playback.append(record)
        if "mediaThumbnailChanged" in source and "event.primaryColor" in source:
            assert "const DURATION = 1;" in source, record
            assert "timer += engine.frametime;" in source, record
            colors.append(record)
        if path == "/origin" and all(token in source for token in ("posX", "posY", "posZ")):
            origins.append(record)
        if source.startswith("//'use strict';"):
            assert "//export function update(value)" in source, record
            assert "\nexport function" not in source, record
            commented.append(record)
        if path == "/instanceoverride/alpha" and "value = new Vec3(" in source:
            assert isinstance(wrapped["value"], (int, float)), record
            type_mismatch.append(record)

expected_playback = {
    2687, 2690, 2699, 2792, 2820, 2848,
    199, 140, 147, 220, 245, 243,
}
assert {record[0] for record in playback} == expected_playback, playback
assert len(playback) == 12, playback

expected_colors = {
    (805, "/instanceoverride/colorn"),
    (568, "/effects/1/passes/0/constantshadervalues/Bar Color"),
    (43965, "/effects/0/passes/0/constantshadervalues/Bar Color"),
    (282, "/color"),
    (528, "/effects/0/passes/1/constantshadervalues/color"),
    (2687, "/color"),
    (199, "/color"),
}
assert {(record[0], record[2]) for record in colors} == expected_colors, colors
assert len(colors) == 7, colors

expected_origins = {
    626: ("date1xposition", "date1yposition", 50),
    476: ("date2xposition", "date2yposition", 50),
    10930: ("mediaintegrationxposition", "mediaintegrationyposition", 0),
    10503: ("mediaintegrationxposition", "mediaintegrationyposition", 0),
}
assert {record[0] for record in origins} == set(expected_origins), origins
resolved_origins = {}
for object_id, _, _, wrapped in origins:
    x_property, y_property, z = expected_origins[object_id]
    script_properties = wrapped["scriptproperties"]
    assert script_properties["posX"]["user"] == x_property, wrapped
    assert script_properties["posY"]["user"] == y_property, wrapped
    assert script_properties["posZ"] == z, wrapped
    resolved_origins[object_id] = (
        properties[x_property]["value"], properties[y_property]["value"], z
    )
assert resolved_origins == {
    626: (3347, 1997, 50),
    476: (1917, 1797, 50),
    10930: (3345, 250, 0),
    10503: (3345, 250, 0),
}, resolved_origins

zoom = scene["general"]["zoom"]
assert zoom["value"] == 1.01, zoom
assert properties["trainshake"]["type"] == "bool", properties["trainshake"]
assert properties["trainshake"]["value"] is True, properties["trainshake"]
assert "thisScene.getCameraTransforms()" in zoom["script"], zoom
assert "cameraTransforms.zoom = changedUserProperties.trainshake ? 1.01 : 1.0;" in zoom["script"], zoom
assert "thisScene.setCameraTransforms(cameraTransforms)" in zoom["script"], zoom

assert [(record[0], record[2]) for record in commented] == [
    (550, "/effects/4/passes/0/constantshadervalues/multiply1")
], commented
assert [(record[0], record[2]) for record in type_mismatch] == [
    (805, "/instanceoverride/alpha")
], type_mismatch

assert len(playback) + len(colors) + len(origins) + 1 + len(commented) + len(type_mismatch) == 26

# Behavioral boundaries for the eventual runtime profiles.
assert {0: False, 1: True, 2: True} == {
    state: state != 0 for state in (0, 1, 2)
}
assert tuple(round(int("112233"[offset:offset + 2], 16) / 255.0, 8) for offset in (0, 2, 4)) == (
    0.06666667, 0.13333333, 0.2
)
assert (1.01 if properties["trainshake"]["value"] else 1.0) == 1.01

print(
    "Persona residual contract passed: playback=12 thumbnail-primary-color=7 "
    "origin-vec3=4 camera-zoom=1 inert=2 total=26"
)
