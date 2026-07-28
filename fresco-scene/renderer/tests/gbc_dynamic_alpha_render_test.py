#!/usr/bin/env python3

"""GBC's solid cover must follow its authored alpha animation."""

import json
import os
import pathlib
import struct
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops


RENDERER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
GBC = WORKSHOP / "3448290956"
COVER = 209
PEAK_FRAMES = 120
LATE_FRAMES = 240
MINIMUM_COVER_CHANGED = 850_000
MAXIMUM_LATE_SKIP_CHANGED = 1_000


def package_scene():
    with (GBC / "scene.pkg").open("rb") as package:
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


def render(output, frames, *, skipped=False):
    environment = os.environ.copy()
    environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    environment["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "0"
    if skipped:
        environment["FRESCO_SCENE_SKIP_OBJECTS"] = str(COVER)
    result = subprocess.run(
        [RENDERER, GBC, ASSETS, output, str(frames)],
        capture_output=True,
        check=False,
        env=environment,
        text=True,
        timeout=300,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"render failed ({result.returncode})\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return Image.open(output).convert("RGB")


def changed_pixels(left, right):
    difference = ImageChops.difference(left, right)
    return sum(pixel != (0, 0, 0) for pixel in difference.get_flattened_data())


revision, scene = package_scene()
assert revision == "PKGV0022", revision
cover = next(obj for obj in scene["objects"] if obj["id"] == COVER)
assert cover["name"] == "纯色", cover["name"]
assert cover["image"] == "models/util/solidlayer.json", cover["image"]

alpha = cover["alpha"]
animation = alpha["animation"]
keys = animation["c0"]
assert alpha["value"] == 0.30000001, alpha
assert animation["options"]["fps"] == 30, animation["options"]
assert animation["options"]["mode"] == "single", animation["options"]
assert animation["options"]["length"] == 180, animation["options"]
assert [key["frame"] for key in keys] == [0, 60, 100], keys
assert [key["value"] for key in keys] == [0, 0.5, 0], keys

# The smoke driver advances at 60 Hz, twice the authored curve's frame rate.
assert keys[1]["frame"] * 2 == PEAK_FRAMES, keys[1]
assert keys[-1]["frame"] * 2 < LATE_FRAMES, keys[-1]

model = json.loads((ASSETS / cover["image"]).read_text())
assert model["material"] == "materials/util/solidlayer.json", model
material = json.loads((ASSETS / model["material"]).read_text())
passes = material["passes"]
assert len(passes) == 1, passes
assert passes[0]["shader"] == "flat", passes[0]
fragment = (ASSETS / "shaders/flat.frag").read_text()
assert "uniform mediump float g_Alpha;" in fragment
assert "gl_FragColor = vec4(g_Color, g_Alpha);" in fragment

with tempfile.TemporaryDirectory(prefix="fresco-gbc-alpha-") as directory:
    root = pathlib.Path(directory)
    peak = render(root / "frame-120.png", PEAK_FRAMES)
    peak_skipped = render(
        root / "frame-120-skip-209.png", PEAK_FRAMES, skipped=True
    )
    late = render(root / "frame-240.png", LATE_FRAMES)
    late_skipped = render(
        root / "frame-240-skip-209.png", LATE_FRAMES, skipped=True
    )

    assert peak.size == peak_skipped.size == late.size == late_skipped.size
    assert peak.size == (1280, 720)
    peak_cover_changed = changed_pixels(peak, peak_skipped)
    fade_changed = changed_pixels(peak, late)
    late_skip_changed = changed_pixels(late, late_skipped)

assert peak_cover_changed >= MINIMUM_COVER_CHANGED, (
    f"object {COVER} changed only {peak_cover_changed} pixels at its alpha "
    f"peak; expected at least {MINIMUM_COVER_CHANGED}"
)
assert fade_changed >= MINIMUM_COVER_CHANGED, (
    f"object {COVER}'s completed alpha fade changed only {fade_changed} "
    f"pixels; expected at least {MINIMUM_COVER_CHANGED}"
)
assert late_skip_changed <= MAXIMUM_LATE_SKIP_CHANGED, (
    f"skipping faded object {COVER} still changed {late_skip_changed} pixels; "
    f"expected at most {MAXIMUM_LATE_SKIP_CHANGED}"
)

print(
    f"GBC dynamic alpha: peak/skip changed={peak_cover_changed}; "
    f"peak/late changed={fade_changed}; late/skip changed={late_skip_changed}"
)
