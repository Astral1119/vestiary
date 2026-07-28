#!/usr/bin/env python3

import os
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops, ImageStat


RENDERER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
FRAMES = 30
PERSONA = WORKSHOP / "3151551777"
HYUGA = WORKSHOP / "3479521040"
PERSONA_LAYERS = "528,605"
HYUGA_LAYERS = "367,1695"
PERSONA_PROTAGONIST_BOUNDS = (390, 160, 850, 720)
PERSONA_PATCH_BOUNDS = (
    (646, 477, 705, 536),
    (461, 549, 520, 608),
)


def render(project, output, *, skipped):
    environment = os.environ.copy()
    environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    environment["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "0"
    if skipped:
        environment["FRESCO_SCENE_SKIP_OBJECTS"] = skipped
    result = subprocess.run(
        [RENDERER, project, ASSETS, output, str(FRAMES)],
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


def horizontal_gradient(image, bounds):
    cropped = image.crop(bounds)
    left = cropped.crop((0, 0, cropped.width - 1, cropped.height))
    right = cropped.crop((1, 0, cropped.width, cropped.height))
    return sum(ImageStat.Stat(ImageChops.difference(left, right)).mean) / 3.0


def changed_pixel_counts(difference):
    changed = [pixel != (0, 0, 0) for pixel in difference.get_flattened_data()]
    width, _ = difference.size
    inside = []
    for left, top, right, bottom in PERSONA_PATCH_BOUNDS:
        inside.append(
            sum(
                changed[y * width + x]
                for y in range(top, bottom)
                for x in range(left, right)
            )
        )
    allowed = sum(inside)
    return sum(changed), allowed, inside


with tempfile.TemporaryDirectory(
    prefix="fresco-composition-resolution-"
) as directory:
    root = pathlib.Path(directory)
    persona_intact = render(
        PERSONA, root / "persona-intact.png", skipped=None
    )
    persona_skipped = render(
        PERSONA, root / "persona-skipped.png", skipped=PERSONA_LAYERS
    )
    hyuga_intact = render(HYUGA, root / "hyuga-intact.png", skipped=None)
    hyuga_skipped = render(
        HYUGA, root / "hyuga-skipped.png", skipped=HYUGA_LAYERS
    )

    assert (
        persona_intact.size
        == persona_skipped.size
        == hyuga_intact.size
        == hyuga_skipped.size
        == (1280, 720)
    )

    persona_difference = ImageChops.difference(
        persona_intact, persona_skipped
    )
    changed, allowed, inside = changed_pixel_counts(persona_difference)
    outside = changed - allowed
    assert outside == 0 and changed > 100, (
        persona_difference.getbbox(),
        changed,
        outside,
        inside,
        PERSONA_PATCH_BOUNDS,
    )

    persona_gradients = (
        horizontal_gradient(persona_intact, PERSONA_PROTAGONIST_BOUNDS),
        horizontal_gradient(persona_skipped, PERSONA_PROTAGONIST_BOUNDS),
    )
    full_frame = (0, 0, 1280, 720)
    hyuga_gradients = (
        horizontal_gradient(hyuga_intact, full_frame),
        horizontal_gradient(hyuga_skipped, full_frame),
    )
    persona_ratio = persona_gradients[0] / persona_gradients[1]
    hyuga_ratio = hyuga_gradients[0] / hyuga_gradients[1]
    assert persona_ratio >= 0.90 and 0.90 <= hyuga_ratio <= 1.10, (
        persona_gradients,
        persona_ratio,
        hyuga_gradients,
        hyuga_ratio,
    )

print(
    "composition resolution: "
    f"persona changed={changed} outside={outside} patches={inside} "
    f"gradient={persona_gradients[0]:.4f}/{persona_gradients[1]:.4f} "
    f"ratio={persona_ratio:.4f}; "
    f"hyuga gradient={hyuga_gradients[0]:.4f}/{hyuga_gradients[1]:.4f} "
    f"ratio={hyuga_ratio:.4f}"
)
