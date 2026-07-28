#!/usr/bin/env python3

"""Composited text must draw its glyphs and leave the rest of the scene alone.

`renderTextEffects` composites only for a scene a `TextEffectRegistrySession`
owns. Only `RendererSession` created one until now, so the smoke tool never
entered the path and nothing in the suite could see it. Three defects had
accumulated behind that silence and a fourth was found the moment the tool was
given a session: the source-FBO clear left `glClearColor` at (0, 0, 0, 0), and
`CScene::render` sets its clear colour once at construction and relies on that
state for every frame's `glClear`. One composited text object therefore cleared
the whole wallpaper to transparent black from the second frame on.

The test pins both halves against the same fixture rendered with the composited
path switched off. The premise is that Persona still routes its top-right
date/time cluster through the composited path, or the pixel assertions would
pass for the unrelated reason that nothing composited. The result is that the
difference between composited and direct is confined to the cluster: before the
clear-colour fix it was 920,573 pixels covering the entire frame at 30 frames,
against 2,028 at one frame, because the leak only reached the following frame's
clear. That frame-count dependence is why this renders more than one frame.

It also asserts that each chain draws at all, rendered alone. Containment on its
own does not: two paths disagree just as loudly when one of them contributes
nothing, and that is what this file measured when it was written — every chain
reported mode=composited and rasterised outside clip space, so object 626 alone
composited to a uniform frame. `blur_precise_gaussian.vert` takes no MVP in its
horizontal variant, so the copy-space quad the first pass was given never
reached the viewport. The per-object assertion is what would have caught it.
"""

import os
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops

RENDERER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
PERSONA = WORKSHOP / "3151551777"

# Two would expose the clear-colour leak. Six leaves room for a leak that needs
# a few frames to show without paying for a thirty-frame render twice.
FRAMES = 6

# Type 1's date, its clock shadow and its day shadow. Each carries one
# `blurprecise` effect whose chain the decision layer accepts, which is what
# routes them through TextEffectRenderer rather than the direct glyph path.
COMPOSITED = (392, 626, 646)

# The cluster sits in the top-right corner. Measured after the fix, every
# differing RGB pixel falls in x=960-1279, y=0-119; the box is drawn wider so a
# re-authored position is a real failure rather than a boundary graze.
REGION = (880, 0, 1280, 220)

# Pixels each chain draws when rendered alone, measured after the source raster
# was centred in its FBO. Compared against half these numbers, because the point
# is to separate "draws" from "draws nothing" — the exact counts move whenever
# the raster or the blur changes. Centring moved 626 from 1,224 to 1,720, which
# is the third of its raster that used to fall off the left edge of the source;
# 646 is unchanged at 439, and 392 varies by a few pixels between runs because
# its text is a clock.
DRAWN = {392: 278, 626: 1720, 646: 439}


def render(directory, name, composited):
    output = pathlib.Path(directory) / name
    environment = os.environ.copy()
    environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    environment["FRESCO_SCENE_TEXT_EFFECT_TRACE"] = "1"
    if composited:
        environment.pop("FRESCO_SCENE_TEXT_EFFECTS_DISABLED", None)
    else:
        environment["FRESCO_SCENE_TEXT_EFFECTS_DISABLED"] = "1"
    result = subprocess.run(
        [RENDERER, PERSONA, ASSETS, output, str(FRAMES)],
        capture_output=True,
        check=True,
        env=environment,
        text=True,
        timeout=300,
    )
    return output, result.stdout


def render_object(directory, identifier):
    """Render one object alone. None means it drew nothing at all.

    The smoke tool rejects a uniform frame itself, with an exit status, so a
    chain that draws nothing never reaches the image comparison. Reporting that
    as "drew nothing" rather than letting CalledProcessError out keeps the
    failure legible — the unfixed build lands here for all three objects.
    """
    output = pathlib.Path(directory) / f"solo-{identifier}.png"
    environment = os.environ.copy()
    environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    environment["FRESCO_SCENE_OBJECT_FILTER"] = str(identifier)
    environment.pop("FRESCO_SCENE_TEXT_EFFECTS_DISABLED", None)
    result = subprocess.run(
        [RENDERER, PERSONA, ASSETS, output, "2"],
        capture_output=True,
        env=environment,
        text=True,
        timeout=300,
    )
    if result.returncode != 0:
        reported = result.stdout + result.stderr
        if "uniform frame" in reported:
            return None
        raise AssertionError(
            f"rendering object {identifier} alone failed with "
            f"{result.returncode}: {reported[-2000:]}"
        )
    return output


def chains(stdout):
    return {
        int(line.split()[1].removeprefix("id=")): line.split()[2].removeprefix("mode=")
        for line in stdout.splitlines()
        if line.startswith("textEffectChain ")
    }


def reported(stdout):
    line = next(
        line for line in stdout.splitlines() if line.startswith("rendered=")
    )
    return int(line.rsplit("textEffectChains=", 1)[1])


with tempfile.TemporaryDirectory(prefix="fresco-persona-composited-text-") as directory:
    composited, composited_stdout = render(directory, "composited.png", True)
    direct, direct_stdout = render(directory, "direct.png", False)

    # Premise: the path is entered at all, and the three authored chains are the
    # ones that enter it. Without this the pixel assertions below would pass for
    # a build in which compositing silently stopped happening.
    decisions = chains(composited_stdout)
    for identifier in COMPOSITED:
        assert decisions.get(identifier) == "composited", (
            f"object {identifier} no longer composites, so this test no longer "
            f"covers the composited path: {decisions}"
        )
    assert reported(composited_stdout) == len(COMPOSITED), composited_stdout

    # Control: the disabled build reports no composited chains, which is what
    # makes the comparison below a comparison of the two paths.
    assert reported(direct_stdout) == 0, direct_stdout

    left, top, right, bottom = REGION
    difference = ImageChops.difference(
        Image.open(composited).convert("RGB"), Image.open(direct).convert("RGB")
    )

    # Premise: the two paths disagree inside the cluster. Without this the
    # containment result below would pass on a build where switching the path
    # changed nothing at all, which is not a build that renders text.
    cluster = difference.crop(REGION).tobytes()
    changed = sum(
        1
        for offset in range(0, len(cluster), 3)
        if any(cluster[offset : offset + 3])
    )
    assert changed > 100, (
        f"composited and direct differ by only {changed} pixels inside the "
        f"cluster, so the composited path is no longer reaching the frame"
    )

    # Result: and it draws nowhere else. This is the clear-colour regression —
    # the leak put a difference on every edge in the scene.
    outside = difference.copy()
    outside.paste(Image.new("RGB", (right - left, bottom - top)), (left, top))
    stray = outside.getbbox()
    assert stray is None, (
        f"compositing changed pixels outside the date/time cluster at {stray}, "
        f"which means it is degrading the rest of the scene"
    )

    # Result: and each chain draws something. The containment assertions above
    # measure the two paths disagreeing, which a chain that composites nothing
    # also satisfies — that is exactly what the build before this one did, and
    # the reason this file used to disclaim any assertion that the glyphs
    # appear. Rendered alone, an empty chain leaves the frame one flat colour.
    for identifier, expected in DRAWN.items():
        solo = render_object(directory, identifier)
        if solo is None:
            drawn = 0
        else:
            colors = Image.open(solo).convert("RGB").getcolors(1 << 22)
            background = max(colors)[1]
            drawn = sum(count for count, color in colors if color != background)
        assert drawn > expected // 2, (
            f"object {identifier} composited alone drew {drawn} pixels against "
            f"{expected} measured; a chain that rasterises outside clip space "
            f"drops to 0 and leaves the frame uniform"
        )

print(
    f"composited text confined to the date/time cluster: {changed} pixels "
    f"differ inside {REGION} and none outside, over {FRAMES} frames, "
    f"chains={sorted(COMPOSITED)}, each drawing {sorted(DRAWN.values())} pixels "
    f"alone"
)
