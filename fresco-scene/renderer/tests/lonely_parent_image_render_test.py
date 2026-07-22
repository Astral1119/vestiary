#!/usr/bin/env python3

import math
import os
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image


RENDERER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
LONELY = WORKSHOP / "3299228616"
EXPECTED = {
    151: (-2.771000, 640.576904, 1917.229370, 1720.577026),
    303: (232.783447, 671.493774, 2152.783691, 1751.493896),
    387: (-0.969240, 815.573547, 1919.031128, 1895.573730),
    678: (-2.669070, 873.919800, 1917.331299, 1953.919922),
}


def neutral_white_pixels(image, bounds):
    return sum(
        min(pixel) > 180 and max(pixel) - min(pixel) < 45
        for pixel in image.crop(bounds).get_flattened_data()
    )


def edge_changes(image, *, x=None, y=None, threshold=10):
    if x is not None:
        pairs = (
            (image.getpixel((x - 1, row)), image.getpixel((x, row)))
            for row in range(200)
        )
    else:
        pairs = (
            (image.getpixel((column, y - 1)), image.getpixel((column, y)))
            for column in range(450, 850)
        )
    return sum(
        max(abs(left[channel] - right[channel]) for channel in range(3))
        > threshold
        for left, right in pairs
    )


with tempfile.TemporaryDirectory(prefix="fresco-lonely-parent-image-") as directory:
    output = pathlib.Path(directory) / "lonely.png"
    environment = os.environ.copy()
    environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    environment["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "0"
    environment["FRESCO_SCENE_SCRIPT_CLOCK_HOUR"] = "15"
    environment["FRESCO_SCENE_TRACE_IMAGE_TRANSFORM"] = "1"
    result = subprocess.run(
        [RENDERER, LONELY, ASSETS, output, "120"],
        capture_output=True,
        check=True,
        env=environment,
        text=True,
        timeout=180,
    )

    transforms = {}
    for line in result.stderr.splitlines():
        if not line.startswith("image-transform|"):
            continue
        _, object_id, parent_id, *values = line.split("|")
        object_id = int(object_id)
        if object_id in EXPECTED:
            assert int(parent_id) == 210, line
            transforms[object_id] = tuple(float(value) for value in values)

    assert transforms.keys() == EXPECTED.keys(), transforms
    for object_id, expected in EXPECTED.items():
        assert all(
            math.isclose(actual, reference, abs_tol=0.002)
            for actual, reference in zip(transforms[object_id], expected)
        ), (object_id, transforms[object_id], expected)

    image = Image.open(output).convert("RGB")
    assert image.size == (1280, 720), image.size
    assert neutral_white_pixels(image, (710, 125, 760, 155)) > 30
    assert neutral_white_pixels(image, (710, 560, 760, 610)) < 10
    assert edge_changes(image, y=18) < 20
    assert edge_changes(image, x=513) < 40
    assert edge_changes(image, y=158) < 100

print(
    "Lonely parent images: AM/PM and bar children compose in positive scene Y; "
    "transparent passthrough chains leave no hard-edged scene copy"
)
