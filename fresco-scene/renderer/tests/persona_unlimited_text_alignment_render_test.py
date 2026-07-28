#!/usr/bin/env python3

"""Persona's unlimited credit text must use its authored right alignment."""

import json
import os
import pathlib
import struct
import subprocess
import sys

from PIL import Image, ImageChops


RENDERER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
EVIDENCE = pathlib.Path(sys.argv[4])
PERSONA = WORKSHOP / "3151551777"
CREDIT = 887
FRAMES = 30
EXPECTED_TEXT = "©ATLUS ©SEGA All rights reserved."
RENDER_SIZE = (1280, 720)


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


revision, scene = package_scene()
assert revision == "PKGV0021", revision
credit = next(obj for obj in scene["objects"] if obj["id"] == CREDIT)

# Pin the defect premise so a later fixture change cannot make the render
# assertion pass through width limiting.
assert credit["text"] == EXPECTED_TEXT, credit
assert credit["horizontalalign"] == "right", credit
assert credit["limitwidth"] is False, credit

scene_width = float(scene["general"]["orthogonalprojection"]["width"])
origin_x = float(credit["origin"].split()[0])
camera_zoom = float(scene["general"]["zoom"]["value"])
scene_center_x = scene_width * 0.5
render_center_x = RENDER_SIZE[0] * 0.5
authored_origin_x = round(
    render_center_x
    + (origin_x - scene_center_x) * camera_zoom
    * RENDER_SIZE[0] / scene_width
)

EVIDENCE.mkdir(parents=True, exist_ok=True)
output = EVIDENCE / "persona-credit-887.png"
environment = os.environ.copy()
environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
environment["FRESCO_SCENE_OBJECT_FILTER"] = str(CREDIT)
result = subprocess.run(
    [RENDERER, PERSONA, ASSETS, output, str(FRAMES)],
    capture_output=True,
    check=False,
    env=environment,
    text=True,
    timeout=300,
)
assert result.returncode == 0, (
    f"rendering Persona credit object {CREDIT} failed ({result.returncode})\n"
    f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
)

image = Image.open(output).convert("RGB")
assert image.size == RENDER_SIZE, image.size
background = Image.new("RGB", image.size, image.getpixel((0, 0)))
extent = ImageChops.difference(image, background).getbbox()
assert extent is not None, f"credit object {CREDIT} drew no glyph pixels"
left, top, right, bottom = extent
rightmost_pixel = right - 1

assert right <= image.width, (
    f"credit glyph extent {extent} crosses scene right edge {image.width}; "
    f"capture={output}"
)
assert rightmost_pixel <= authored_origin_x, (
    f"credit glyph right extent {rightmost_pixel} exceeds authored origin "
    f"{authored_origin_x}; extent={extent}; capture={output}"
)
assert authored_origin_x - rightmost_pixel <= 2, (
    f"credit glyph right extent {rightmost_pixel} does not sit at authored "
    f"origin {authored_origin_x}; extent={extent}; capture={output}"
)

print(
    f"Persona credit {CREDIT}: authored right origin={authored_origin_x}, "
    f"camera zoom={camera_zoom}, glyph extent={extent}, "
    f"scene right={image.width}, capture={output}"
)
