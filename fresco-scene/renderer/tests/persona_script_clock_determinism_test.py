#!/usr/bin/env python3

"""A pinned script clock must reach the text scripts and make the scene repeat.

Persona's object 392, "Clock-SHADOW", builds its text from `new Date()`, and
the fixture turns `showSeconds` on, so the wallpaper redraws its rightmost
digits every second. `SceneScriptEngine::createLayer` installed no `Date` at
all, so QuickJS resolved the real one and every render carried whatever second
it happened to start in. That is the whole of the "nondeterministic patch" that
sat under every Persona pixel comparison: two full-scene renders two seconds
apart differed by 51 pixels, all inside (1155, 61)-(1161, 72), and two renders
forty minutes apart differed out to x=1141 because the minutes had moved too.
It was never nondeterminism. It was a clock.

`FRESCO_SCENE_SCRIPT_CLOCK_HOUR` already pinned the hour on the layer-graph
path; the minute and second variables are new, and any of the three now freezes
the whole reading, because a Date whose hour is pinned and whose minute still
runs is not a time a script can format.

The hour comparison is what fails on the parent build. Two renders pinned to
the same instant can pass there by accident — they do whenever both land inside
one wall-clock second — but no accident of timing moves the *hours* digits, so
a build that ignores the pin renders morning and afternoon identically and the
assertion below catches it.
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

CLOCK = 392

RENDER_SIZE = (1280, 720)

# Two pins six hours apart, sharing a minute and a second so the hour is the
# only thing that moves. Six rather than twelve: a twelve-hour step collapses
# under the script's 12h branch, where 9 and 21 both print "09", and
# `use24hFormat` is a user property that a smoke render need not resolve the
# way the fixture defaults it. Nine against fifteen differs either way — "09"
# against "15", or "09" against "03".
MORNING = ("9", "41", "7")
AFTERNOON = ("15", "41", "7")


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


def render(directory, name, clock, solo=True):
    output = pathlib.Path(directory) / f"{name}.png"
    environment = os.environ.copy()
    environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    hour, minute, second = clock
    environment["FRESCO_SCENE_SCRIPT_CLOCK_HOUR"] = hour
    environment["FRESCO_SCENE_SCRIPT_CLOCK_MINUTE"] = minute
    environment["FRESCO_SCENE_SCRIPT_CLOCK_SECOND"] = second
    if solo:
        environment["FRESCO_SCENE_OBJECT_FILTER"] = str(CLOCK)
    else:
        environment.pop("FRESCO_SCENE_OBJECT_FILTER", None)
    subprocess.run(
        [RENDERER, PERSONA, ASSETS, output, "2"],
        capture_output=True,
        check=True,
        env=environment,
        text=True,
        timeout=300,
    )
    image = Image.open(output).convert("RGB")
    assert image.size == RENDER_SIZE, image.size
    return image


def difference(first, second):
    return ImageChops.difference(first, second).getbbox()


def extent(image):
    background = Image.new("RGB", image.size, image.getpixel((0, 0)))
    return ImageChops.difference(image, background).getbbox()


scene = package_scene()
clock = next(obj for obj in scene["objects"] if obj["id"] == CLOCK)

# Premise: the fixture still authors a script-driven clock that reads the host
# date and prints seconds. Without both, this measures nothing — a static text
# value repeats on any build.
assert "script" in clock["text"], clock["text"]
assert "new Date()" in clock["text"]["script"], clock["text"]["script"]
assert clock["text"]["scriptproperties"]["showSeconds"] is True, clock["text"]

with tempfile.TemporaryDirectory(prefix="fresco-persona-script-clock-") as directory:
    morning = render(directory, "solo-morning", MORNING)
    repeat = render(directory, "solo-morning-repeat", MORNING)
    afternoon = render(directory, "solo-afternoon", AFTERNOON)

    bounds = extent(morning)
    assert bounds is not None, f"object {CLOCK} rendered alone drew nothing"

    # Result: the same pin twice is the same frame, to the byte.
    assert difference(morning, repeat) is None, (
        f"object {CLOCK} pinned to {':'.join(MORNING)} rendered differently "
        f"twice, at {difference(morning, repeat)}"
    )

    # Result: and the pin is what the script read, not a coincidence — moving
    # it six hours moves the hours digits, which no elapsed second can do.
    moved = difference(morning, afternoon)
    assert moved is not None, (
        f"object {CLOCK} rendered identically at {':'.join(MORNING)} and "
        f"{':'.join(AFTERNOON)}, so the pinned clock never reached its text script"
    )
    midpoint = (bounds[0] + bounds[2]) // 2
    assert moved[0] < midpoint, (
        f"pinning the hour changed object {CLOCK} only at x={moved[0]}..{moved[2] - 1}, "
        f"right of the midpoint {midpoint} of its extent {bounds}: the hours "
        f"digits are unmoved, so what changed is the seconds and the pin is "
        f"being ignored"
    )

    # Result: with the clock pinned the whole scene repeats, which is the point.
    # This is the number every Persona A/B has been carrying as a noise floor.
    first = render(directory, "scene-first", MORNING, solo=False)
    second = render(directory, "scene-second", MORNING, solo=False)
    floor = difference(first, second)
    assert floor is None, (
        f"the full scene pinned to {':'.join(MORNING)} still differs between "
        f"two renders, at {floor}"
    )

print(
    f"object {CLOCK} pinned to {':'.join(MORNING)} repeats byte-identically "
    f"within an extent of {bounds}; pinning to {':'.join(AFTERNOON)} moves it "
    f"from x={moved[0]}, left of the midpoint {midpoint}; the full scene "
    f"repeats with a difference of none"
)
