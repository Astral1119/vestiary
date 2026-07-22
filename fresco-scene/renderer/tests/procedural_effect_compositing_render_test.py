#!/usr/bin/env python3

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
FIXTURES = {
    "3460973721": {
        "label": "arknights",
        "bounds": (521, 27, 854, 361),
        "transparentSamples": ((530, 30), (850, 30)),
        "flatGrayBounds": (0, 640, 1280, 720),
    },
    "3299228616": {
        "label": "lonely",
        "bounds": (253, 0, 940, 469),
        "transparentSamples": ((260, 10),),
    },
}


def package_payloads(project):
    with (project / "scene.pkg").open("rb") as package:
        def u32():
            return struct.unpack("<I", package.read(4))[0]

        def string():
            return package.read(u32()).decode("utf-8")

        assert string() == "PKGV0024"
        entries = [(string(), u32(), u32()) for _ in range(u32())]
        base = package.tell()
        payloads = {}
        for name, offset, length in entries:
            package.seek(base + offset)
            payloads[name] = package.read(length)
        return payloads


def validate_arknights_passthrough_contract(project):
    payloads = package_payloads(project)
    scene = json.loads(payloads["scene.json"])
    image = next(item for item in scene["objects"] if item["id"] == 144)
    assert image["parent"] == 148
    assert image["image"] == "models/util/composelayer.json"
    assert image["effects"][0]["file"] == (
        "effects/workshop/3021673417/Simple_Audio_Bars/effect.json"
    )
    material = json.loads(
        payloads["materials/workshop/3021673417/effects/Simple_Audio_Bars.json"]
    )
    assert material["passes"][0]["blending"] == "normal"
    shader = payloads[
        "shaders/workshop/3021673417/effects/Simple_Audio_Bars.frag"
    ]
    assert b'"combo":"TRANSPARENCY"' in shader
    assert b'"default":1' in shader
    model = json.loads((ASSETS / image["image"]).read_bytes())
    assert model["passthrough"] is True


def render(project, output, *, disabled):
    environment = os.environ.copy()
    environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    environment["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "0"
    if disabled:
        environment["FRESCO_SCENE_PROCEDURAL_QUAD_DISABLED"] = "1"
    result = subprocess.run(
        [RENDERER, project, ASSETS, output, "120"],
        capture_output=True,
        check=False,
        env=environment,
        text=True,
        timeout=180,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"render failed ({result.returncode})\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return Image.open(output).convert("RGB")


with tempfile.TemporaryDirectory(prefix="fresco-procedural-composite-") as directory:
    root = pathlib.Path(directory)
    for workshop_id, fixture in FIXTURES.items():
        project = WORKSHOP / workshop_id
        assert (project / "scene.pkg").is_file(), project
        if fixture["label"] == "arknights":
            validate_arknights_passthrough_contract(project)
        enabled = render(
            project, root / f"{fixture['label']}-enabled.png", disabled=False
        )
        disabled = render(
            project, root / f"{fixture['label']}-disabled.png", disabled=True
        )

        assert enabled.size == disabled.size == (1280, 720), enabled.size
        difference = ImageChops.difference(enabled, disabled)
        changed = sum(
            pixel != (0, 0, 0) for pixel in difference.get_flattened_data()
        )
        assert changed > 1_000, (fixture["label"], changed)

        false_black = 0
        for active, control in zip(
            enabled.crop(fixture["bounds"]).get_flattened_data(),
            disabled.crop(fixture["bounds"]).get_flattened_data(),
        ):
            if max(active) <= 2 and max(control) >= 16:
                false_black += 1
        assert false_black < 100, (fixture["label"], false_black)

        for sample in fixture["transparentSamples"]:
            assert enabled.getpixel(sample) == disabled.getpixel(sample), (
                fixture["label"],
                sample,
                enabled.getpixel(sample),
                disabled.getpixel(sample),
            )

        if "flatGrayBounds" in fixture:
            flat_gray = sum(
                max(pixel) - min(pixel) <= 1 and 160 <= min(pixel) <= 190
                for pixel in enabled.crop(
                    fixture["flatGrayBounds"]
                ).get_flattened_data()
            )
            assert flat_gray < 1_000, (fixture["label"], flat_gray)

print(
    "procedural effect compositing: Arknights and Lonely coverage remains "
    "transparent; passthrough effects do not expose flat RGB"
)
