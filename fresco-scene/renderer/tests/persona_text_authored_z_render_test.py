#!/usr/bin/env python3

"""Orthographic text must render independently of its authored origin z.

Persona's date root resolves to z=50 through its origin script. The direct
clock child inherits that z, while the date root renders through the text
effect compositor. Both used to land outside the orthographic camera volume.
"""

import json
import os
import pathlib
import struct
import subprocess
import sys
import tempfile

from PIL import Image

RENDERER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
PERSONA = WORKSHOP / "3151551777"
FRAMES = 30
EXPECTED_Z = 50.0

OBJECTS = {
    435: "direct",
    626: "effect-composited",
}


def package_scene():
    with (PERSONA / "scene.pkg").open("rb") as package:
        def u32():
            return struct.unpack("<I", package.read(4))[0]

        def string():
            return package.read(u32()).decode("utf-8")

        revision = string()
        entries = [(string(), u32(), u32()) for _ in range(u32())]
        base = package.tell()
        _, offset, length = next(
            entry for entry in entries if entry[0] == "scene.json"
        )
        package.seek(base + offset)
        return revision, json.loads(package.read(length))


def local_origin_z(origin):
    if isinstance(origin, str):
        return float(origin.split()[2])

    script_properties = origin["scriptproperties"]
    assert "value.z = scriptProperties.posZ;" in origin["script"], origin
    return float(script_properties["posZ"])


revision, scene = package_scene()
assert revision == "PKGV0021", revision
objects_by_id = {obj["id"]: obj for obj in scene["objects"]}

for object_id in OBJECTS:
    resolved_z = 0.0
    current = objects_by_id[object_id]
    while True:
        resolved_z += local_origin_z(current["origin"])
        parent = current.get("parent")
        if parent is None:
            break
        current = objects_by_id[parent]

    assert resolved_z == EXPECTED_Z, (
        f"object {object_id} resolved origin z={resolved_z}, "
        f"expected {EXPECTED_Z}"
    )

measurements = {}
with tempfile.TemporaryDirectory(prefix="fresco-persona-text-z-") as directory:
    for object_id, render_path in OBJECTS.items():
        output = pathlib.Path(directory) / f"{object_id}.png"
        environment = os.environ.copy()
        environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
        environment["FRESCO_SCENE_OBJECT_FILTER"] = str(object_id)
        result = subprocess.run(
            [RENDERER, PERSONA, ASSETS, output, str(FRAMES)],
            capture_output=True,
            check=False,
            env=environment,
            text=True,
            timeout=300,
        )

        assert result.returncode == 0, (
            f"rendering {render_path} text object {object_id} with resolved "
            f"z={EXPECTED_Z:g} failed: "
            f"{result.stderr[-2000:]}"
        )

        image = Image.open(output).convert("RGB")
        pixels = list(image.getdata())
        background = pixels[0]
        varying_nonzero = sum(
            pixel != background and any(channel != 0 for channel in pixel)
            for pixel in pixels
        )
        measurements[object_id] = (varying_nonzero, background)

        assert varying_nonzero > 0, (
            f"{render_path} text object {object_id} resolved to z={EXPECTED_Z} "
            f"but drew {varying_nonzero} varying nonzero pixels against "
            f"{background}"
        )

for object_id, render_path in OBJECTS.items():
    varying_nonzero, background = measurements[object_id]
    print(
        f"{render_path} text object {object_id}: resolved z={EXPECTED_Z:g}, "
        f"varying nonzero pixels={varying_nonzero}, background={background}"
    )
