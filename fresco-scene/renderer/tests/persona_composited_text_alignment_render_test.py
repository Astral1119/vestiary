#!/usr/bin/env python3

"""Composited right-aligned text must keep its raster and end at its origin.

The composited path splits alignment across two places. `CText` draws the glyph
quad it built for the direct path, which carries the authored alignment —
right-aligned text spans (-width, 0) rather than (-width/2, width/2) — and
`TextEffectRenderer` renders that quad through an ortho centred on the source
FBO, then applies alignment a second time when it places the composited quad in
the scene. Drawn as authored, Persona's date root 626 landed half its width left
of the FBO and everything past the edge was clipped away before any pass ran:
7,711 covered source pixels bounded at x=0..127 of a 265-wide FBO, against
10,177 at 37..227 once the raster is centred.

The scene-side half is measured separately, because the source can be intact and
still land in the wrong place. The composited quad is the padded texture wide
with the glyphs in its middle, so offsetting by half the texture rather than half
the raster put the right edge of the glyphs a padding short of the authored
origin — 10 capture pixels for 626, whose composited extent ended at 1108
against the direct path's 1118 and an authored origin at 1120.

Both assertions fail on the build before the fix. The probe bound catches the
clipping directly; the extent catches the placement. A capture-only test would
have caught neither cleanly, because the blur smears across the whole FBO width
and the clipped render's bounding box is the same width as the intact one.
"""

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
PERSONA = WORKSHOP / "3151551777"

# 626 is the Type 1 date root, right-aligned. 646 is its clock shadow, centred,
# and is the control: centred text was never clipped, so it pins that the fix
# leaves the majority case alone.
ALIGNED = 626
CENTRED = 646

RENDER_SIZE = (1280, 720)

# The blur spreads about a pixel each side of the glyph extent, so the composited
# right edge sits within a pixel or two of the direct one. Three leaves room for
# that without admitting the padding-wide error, which is ten.
EDGE_TOLERANCE = 3
# Glyph bearing puts the ink a pixel or two off the raster's exact centre. An
# alignment offset wrongly applied to centred text moves it half a raster --
# 51 pixels for 646 -- so this separates the two without pinning font metrics.
CENTRE_TOLERANCE = 4


def package_scene():
    with (PERSONA / "scene.pkg").open("rb") as package:
        def u32():
            return struct.unpack("<I", package.read(4))[0]

        def string():
            return package.read(u32()).decode("utf-8")

        string()
        entries = [(string(), u32(), u32()) for _ in range(u32())]
        base = package.tell()
        _, offset, length = next(
            entry for entry in entries if entry[0] == "scene.json"
        )
        package.seek(base + offset)
        return json.loads(package.read(length))


def authored_origin_x(scene, obj):
    # 626's origin arrives through a position script whose sliders default to the
    # static value, so the static value is what a smoke render resolves.
    origin = obj["origin"]
    if isinstance(origin, dict):
        origin = origin["value"]
    origin_x = float(origin.split()[0])
    scene_width = float(scene["general"]["orthogonalprojection"]["width"])
    zoom = float(scene["general"]["zoom"]["value"])
    return (
        RENDER_SIZE[0] * 0.5
        + (origin_x - scene_width * 0.5) * zoom * RENDER_SIZE[0] / scene_width
    )


def render(directory, identifier):
    output = pathlib.Path(directory) / f"solo-{identifier}.png"
    environment = os.environ.copy()
    environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    environment["FRESCO_SCENE_OBJECT_FILTER"] = str(identifier)
    environment["FRESCO_SCENE_TEXT_EFFECT_PROBE"] = "1"
    environment["FRESCO_SCENE_TEXT_EFFECT_TRACE"] = "1"
    environment.pop("FRESCO_SCENE_TEXT_EFFECTS_DISABLED", None)
    result = subprocess.run(
        [RENDERER, PERSONA, ASSETS, output, "2"],
        capture_output=True,
        check=True,
        env=environment,
        text=True,
        timeout=300,
    )
    return output, result.stdout + result.stderr


def fields(reported, prefix, identifier):
    """The last line the prefix reports for one object, as a field mapping."""
    lines = [
        line.split()
        for line in reported.splitlines()
        if line.startswith(f"{prefix} id={identifier} ")
    ]
    assert lines, f"{prefix} reported nothing for object {identifier}"
    return [
        dict(part.split("=", 1) for part in line[1:] if "=" in part)
        for line in lines
    ]


def source_probe(reported, identifier):
    stages = [
        stage
        for stage in fields(reported, "textEffectProbe", identifier)
        if stage["stage"] == "source"
    ]
    assert stages, f"no source stage probed for object {identifier}"
    return stages[-1]


scene = package_scene()
aligned = next(obj for obj in scene["objects"] if obj["id"] == ALIGNED)
centred = next(obj for obj in scene["objects"] if obj["id"] == CENTRED)

# Premise: the fixture still authors the shape this measures. Right alignment
# without width limiting is what routes 626 through the unlimited quad, and the
# padding is what separates the raster from the texture the quad is sized from.
assert aligned["horizontalalign"] == "right", aligned
assert aligned["limitwidth"] is False, aligned
assert int(aligned["padding"]) > 0, aligned
assert centred["horizontalalign"] == "center", centred

with tempfile.TemporaryDirectory(prefix="fresco-persona-composited-align-") as directory:
    output, reported = render(directory, ALIGNED)

    quad = fields(reported, "textEffectQuad", ALIGNED)[-1]
    raster_width, _ = (int(value) for value in quad["raster"].split("x"))
    texture_width, _ = (int(value) for value in quad["texture"].split("x"))
    padding = int(quad["padding"])

    # Premise: the object composites at all, and the source FBO really is the
    # raster plus the padding on each side. Without this the bound below could
    # hold for an object that never entered the path.
    assert padding > 0, quad
    assert texture_width == raster_width + padding * 2, quad

    probe = source_probe(reported, ALIGNED)
    left, _, right, _ = (int(value) for value in probe["bounds"].split(","))

    # Result: the glyphs sit inside the padded raster, so nothing was clipped
    # against the FBO edge on the way in. The unfixed build reports left=0.
    assert left >= padding, (
        f"object {ALIGNED} drew its glyphs from x={left} of a {texture_width}-"
        f"wide source FBO whose padding is {padding}, so the raster is clipped "
        f"against the left edge before any pass runs: {probe}"
    )
    assert right <= padding + raster_width - 1, (
        f"object {ALIGNED} drew its glyphs out to x={right}, past the "
        f"{raster_width}-wide raster at padding {padding}: {probe}"
    )

    image = Image.open(output).convert("RGB")
    assert image.size == RENDER_SIZE, image.size
    background = Image.new("RGB", image.size, image.getpixel((0, 0)))
    extent = ImageChops.difference(image, background).getbbox()
    assert extent is not None, f"object {ALIGNED} composited alone drew nothing"
    rightmost = extent[2] - 1
    origin_x = authored_origin_x(scene, aligned)

    # Result: and the composited quad ends where the authored right alignment
    # says it ends. The unfixed build lands a padding short of it.
    assert abs(rightmost - origin_x) <= EDGE_TOLERANCE, (
        f"object {ALIGNED} composited to a right extent of {rightmost} against "
        f"an authored right-aligned origin of {origin_x:.1f}; extent={extent}, "
        f"padding={padding}, capture={output}"
    )

    # Control: centring the raster must not move centred text, and must not
    # clip it. This asserts the ink sits inside the padded raster and stays
    # centred within it -- NOT that it begins on the very first raster column.
    # That stricter form was an accident of 646's glyph bearing: its raster is
    # 102 wide and its ink spans columns 1..98, so column 0 is empty and the
    # equality failed while the placement was correct. Composited 646 centres
    # at x=1145.5 against the direct path's 1145.0.
    _, centred_reported = render(directory, CENTRED)
    centred_quad = fields(centred_reported, "textEffectQuad", CENTRED)[-1]
    centred_probe = source_probe(centred_reported, CENTRED)
    centred_padding = int(centred_quad["padding"])
    centred_raster = int(centred_quad["raster"].split("x")[0])
    centred_left, _, centred_right, _ = (
        int(value) for value in centred_probe["bounds"].split(",")
    )

    # The unfixed build clipped against the source FBO edge and reported left=0.
    assert centred_left >= centred_padding, (
        f"centred object {CENTRED} drew its glyphs from x={centred_left}, "
        f"outside its padding {centred_padding}, so the raster is clipped "
        f"against the source FBO edge: {centred_probe}"
    )
    assert centred_right <= centred_padding + centred_raster - 1, (
        f"centred object {CENTRED} drew its glyphs out to x={centred_right}, "
        f"past the {centred_raster}-wide raster at padding {centred_padding}: "
        f"{centred_probe}"
    )

    # And it is still centred: an alignment offset applied to centred text
    # would push the ink half a raster off, which dwarfs any bearing.
    ink_centre = (centred_left + centred_right) / 2.0
    raster_centre = centred_padding + centred_raster / 2.0
    assert abs(ink_centre - raster_centre) <= CENTRE_TOLERANCE, (
        f"centred object {CENTRED} put its ink centre at {ink_centre:.1f} "
        f"against a raster centre of {raster_centre:.1f}: {centred_probe}"
    )

print(
    f"composited object {ALIGNED}: source glyphs at x={left}..{right} inside a "
    f"{texture_width}-wide FBO padded {padding} around a {raster_width}-wide "
    f"raster, right extent {rightmost} against an authored origin of "
    f"{origin_x:.1f}; centred control {CENTRED} starts at x={centred_left}"
)
