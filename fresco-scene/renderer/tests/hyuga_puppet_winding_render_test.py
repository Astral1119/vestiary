#!/usr/bin/env python3

import json
import os
import pathlib
import re
import struct
import subprocess
import sys


RENDERER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
EVIDENCE = pathlib.Path(sys.argv[4])
HYUGA = WORKSHOP / "3479521040"
OBJECT_ID = 84
FRAMES = 120
MINIMUM_VARYING_PIXELS = 20_000


def package_payloads():
    with (HYUGA / "scene.pkg").open("rb") as package:
        def u32():
            return struct.unpack("<I", package.read(4))[0]

        def string():
            return package.read(u32()).decode("utf-8")

        revision = string()
        entries = [(string(), u32(), u32()) for _ in range(u32())]
        base = package.tell()
        payloads = {}
        for name, offset, length in entries:
            if not name.endswith(".json"):
                continue
            package.seek(base + offset)
            payloads[name] = package.read(length)
        return revision, payloads


revision, payloads = package_payloads()
assert revision == "PKGV0022", revision
scene = json.loads(payloads["scene.json"])
object_84 = next(obj for obj in scene["objects"] if obj["id"] == OBJECT_ID)
model_path = object_84["image"]
model = json.loads(payloads[model_path])
assert model["puppet"].endswith("_puppet.mdl"), model
material = json.loads(payloads[model["material"]])
cull_modes = [render_pass["cullmode"] for render_pass in material["passes"]]
assert cull_modes == ["normal"], (
    f"Hyuga object {OBJECT_ID} no longer authors its expected culling mode: "
    f"{cull_modes}"
)

EVIDENCE.mkdir(parents=True, exist_ok=True)
output = EVIDENCE / "hyuga-object-84.png"
environment = os.environ.copy()
environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
environment["FRESCO_SCENE_OBJECT_FILTER"] = str(OBJECT_ID)
result = subprocess.run(
    [RENDERER, HYUGA, ASSETS, output, str(FRAMES)],
    capture_output=True,
    check=False,
    env=environment,
    text=True,
    timeout=300,
)
assert result.returncode == 0, (
    f"Hyuga object {OBJECT_ID} solo render failed ({result.returncode}): "
    f"{result.stderr[-2000:]}"
)
match = re.search(r"frames=(\d+).*varyingPixels=(\d+)", result.stdout)
assert match is not None, result.stdout
frames, varying_pixels = map(int, match.groups())
assert frames == FRAMES, frames
assert varying_pixels > MINIMUM_VARYING_PIXELS, (
    f"Hyuga object {OBJECT_ID} produced {varying_pixels} varying pixels; "
    f"expected more than {MINIMUM_VARYING_PIXELS}"
)
assert output.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), output

print(
    f"Hyuga object {OBJECT_ID}: cullmode={cull_modes[0]}, "
    f"varyingPixels={varying_pixels} > {MINIMUM_VARYING_PIXELS}"
)
