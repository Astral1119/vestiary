#!/usr/bin/env python3

"""Invisible effect dependencies must not reorder authored scene layers."""

import json
import os
import pathlib
import struct
import subprocess
import sys

from PIL import Image


RENDERER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
EVIDENCE = pathlib.Path(sys.argv[4])
PERSONA = WORKSHOP / "3151551777"
DEPENDENT = 118
DEPENDENCY = 114
COMPOSITE = "_rt_imageLayerComposite_114_a"
BADGE_BOUNDS = (1125, 39, 1168, 72)
FRAMES = 30
MINIMUM_WHITE_GLYPH_PIXELS = 100


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
objects = {obj["id"]: obj for obj in scene["objects"]}
badge = objects[DEPENDENT]

assert badge["dependencies"] == [DEPENDENCY], badge
consumers = [
    effect
    for effect in badge["effects"]
    if any(
        COMPOSITE in effect_pass.get("textures", [])
        for effect_pass in effect.get("passes", [])
    )
]
assert len(consumers) == 1, consumers
assert consumers[0]["visible"] is False, consumers[0]

EVIDENCE.mkdir(parents=True, exist_ok=True)


def render(output, *, skipped=None):
    environment = os.environ.copy()
    environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    if skipped is not None:
        environment["FRESCO_SCENE_SKIP_OBJECTS"] = str(skipped)
    result = subprocess.run(
        [RENDERER, PERSONA, ASSETS, output, str(FRAMES)],
        capture_output=True,
        check=False,
        env=environment,
        text=True,
        timeout=300,
    )
    assert result.returncode == 0, (
        f"rendering Persona failed ({result.returncode})\n"
        f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    )
    image = Image.open(output).convert("RGB")
    assert image.size == (1280, 720), image.size
    return image


intact_output = EVIDENCE / "persona-dependency-render-order.png"
skipped_output = EVIDENCE / "persona-dependency-render-order-skip-114.png"
intact = render(intact_output)
skipped = render(skipped_output, skipped=DEPENDENCY)

bright_glyph_pixels = 0
for y in range(BADGE_BOUNDS[1], BADGE_BOUNDS[3]):
    for x in range(BADGE_BOUNDS[0], BADGE_BOUNDS[2]):
        intact_pixel = intact.getpixel((x, y))
        skipped_pixel = skipped.getpixel((x, y))
        if min(intact_pixel) >= 192 and max(skipped_pixel) <= 64:
            bright_glyph_pixels += 1

assert bright_glyph_pixels >= MINIMUM_WHITE_GLYPH_PIXELS, (
    f"object {DEPENDENCY} drew {bright_glyph_pixels} white glyph pixels "
    f"inside badge bounds {BADGE_BOUNDS}, expected at least "
    f"{MINIMUM_WHITE_GLYPH_PIXELS}; intact capture: {intact_output}; "
    f"skipped capture: {skipped_output}"
)

print(
    f"Persona dependency render order: {DEPENDENT} -> [{DEPENDENCY}], "
    f"consumer visible=false, badge bounds={BADGE_BOUNDS}, "
    f"white glyph pixels={bright_glyph_pixels}, "
    f"intact capture={intact_output}, skipped capture={skipped_output}"
)
