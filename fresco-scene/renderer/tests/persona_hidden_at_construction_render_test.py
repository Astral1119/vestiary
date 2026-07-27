#!/usr/bin/env python3

"""A layer hidden when the scene is built must render once its script shows it.

CImage wires its pass list once, in setupPasses, and the final pass is the one
that targets the scene framebuffer. That decision used to read the dynamic
visible property, so a layer that was hidden at construction drew into its own
ping-pong framebuffer for the lifetime of the scene and never appeared, no
matter what its script did afterwards.

Persona's protagonist is the case: its visible script reads
engine.userProperties.character, and the user properties are seeded after the
scene is constructed, so the script resolves false exactly once and true from
the first frame onward. The test pins both halves — that the layer really is
hidden at construction, and that it draws anyway.
"""

import os
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image

RENDERER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
PERSONA = WORKSHOP / "3151551777"
PROTAGONIST = 29716
FRAMES = 30

# The protagonist covers about 81k of the 921k pixels in a 1280x720 render. The
# bounds are wide enough to survive effect animation and narrow enough that an
# empty frame or a whole-screen wash both fail.
MINIMUM_DRAWN = 40_000
MAXIMUM_DRAWN = 200_000

with tempfile.TemporaryDirectory(prefix="fresco-persona-hidden-") as directory:
    output = pathlib.Path(directory) / "protagonist.png"
    environment = os.environ.copy()
    environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    environment["FRESCO_SCENE_VISIBILITY_TRACE"] = "1"
    environment["FRESCO_SCENE_OBJECT_FILTER"] = str(PROTAGONIST)
    result = subprocess.run(
        [RENDERER, PERSONA, ASSETS, output, str(FRAMES)],
        capture_output=True,
        check=False,
        env=environment,
        text=True,
        timeout=300,
    )

    assert result.returncode == 0, (
        "rendering the protagonist alone failed, which is how the latched "
        f"wiring reports itself: {result.stderr[-2000:]}"
    )

    # The premise: hidden when the scene was built, shown from frame zero on.
    # Without this the render assertion below could pass for the unrelated
    # reason that the layer was never hidden in the first place.
    flip = f"visibilityFlip frame=0 phase=post id={PROTAGONIST} own=1"
    assert flip in result.stdout, (
        "the protagonist was not hidden at construction, so this render no "
        "longer covers the wiring latch"
    )

    resolved = [
        line
        for line in result.stdout.splitlines()
        if line.startswith(f"visibility id={PROTAGONIST} ")
    ]
    assert len(resolved) == 1, f"expected one visibility line, got {resolved}"
    assert "own=1 resolved=1" in resolved[0], (
        f"the protagonist did not settle visible: {resolved[0]}"
    )

    image = Image.open(output).convert("RGB")
    background = image.getpixel((0, 0))
    drawn = sum(pixel != background for pixel in image.getdata())

assert MINIMUM_DRAWN <= drawn <= MAXIMUM_DRAWN, (
    f"the protagonist drew {drawn} pixels against the background {background}, "
    f"outside the expected {MINIMUM_DRAWN}-{MAXIMUM_DRAWN}"
)

print(f"protagonist drawn pixels: {drawn}")
