#!/usr/bin/env python3

"""A hidden text parent must gate the children hanging off it.

Persona offers its date and time in two authored layouts, selected by the
`datetime` combo: Type 1 in the top right, rooted at text object 626, and Type 2
in the middle, rooted at text object 476 `Clock-SHADOW`. The default is Type 1,
so 476 is authored `visible: false` and Wallpaper Engine draws nothing in the
middle — confirmed against the reference on 2026-07-28.

Fresco drew the middle cluster anyway. Its five children author no visibility of
their own, and the ancestor walk used to exclude text parents from propagating
visibility, so each child resolved visible under a hidden parent.

The test pins both halves. The premise is that 476 really is hidden and its
children really do author nothing, or the render assertion would pass for the
unrelated reason that nothing was ever meant to draw. The result is that a child
resolves hidden and draws no pixels, with Type 1's still-visible children as the
control that the walk did not simply start hiding text.
"""

import os
import pathlib
import subprocess
import sys
import tempfile

RENDERER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
PERSONA = WORKSHOP / "3151551777"
FRAMES = 30

# Type 2, the middle cluster. Authored off under the default `datetime`.
MIDDLE_ROOT = 476
MIDDLE_CHILDREN = (79, 86, 92, 641, 662)

# Type 1, the top-right cluster. Authored on under the same default, and the
# control that proves this change gates on the parent rather than on the type.
TOP_RIGHT_ROOT = 626
TOP_RIGHT_CHILDREN = (20, 114, 392, 435, 646)

# The child rendered alone. Measured solo on the parent build, the five draw
# 130, 3542, 308, 3553 and 326 varying pixels, so `D a y` is picked to make a
# regression loud rather than a few stray pixels.
FILTERED = 86


def visibility(stdout, identifier):
    lines = [
        line
        for line in stdout.splitlines()
        if line.startswith(f"visibility id={identifier} ")
    ]
    assert len(lines) == 1, f"expected one visibility line for {identifier}, got {lines}"
    return lines[0]


with tempfile.TemporaryDirectory(prefix="fresco-persona-text-parent-") as directory:
    output = pathlib.Path(directory) / "middle-clock.png"
    environment = os.environ.copy()
    environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    environment["FRESCO_SCENE_VISIBILITY_TRACE"] = "1"
    environment["FRESCO_SCENE_OBJECT_FILTER"] = str(FILTERED)
    result = subprocess.run(
        [RENDERER, PERSONA, ASSETS, output, str(FRAMES)],
        capture_output=True,
        check=False,
        env=environment,
        text=True,
        timeout=300,
    )

    # Drawing nothing is the result here, so the smoke tool's uniform-frame
    # tripwire is the assertion rather than a failure. It fires after the PNG is
    # written, and it reports the varying-pixel count that makes it specific —
    # an unrelated crash would not carry this diagnostic.
    assert "varyingPixels=0" in result.stderr and "uniform frame" in result.stderr, (
        f"the middle clock drew pixels under the default `datetime` of 1, or the "
        f"render failed for an unrelated reason: {result.stderr[-2000:]}"
    )

    # Premise: the middle root is hidden and the top-right root is not, which is
    # what the default `datetime` of 1 authors.
    middle_root = visibility(result.stdout, MIDDLE_ROOT)
    assert "own=0" in middle_root, (
        f"the middle cluster root is not hidden, so this test no longer covers "
        f"parent gating: {middle_root}"
    )
    top_right_root = visibility(result.stdout, TOP_RIGHT_ROOT)
    assert "own=1 resolved=1" in top_right_root, (
        f"the top-right cluster root is not visible: {top_right_root}"
    )

    # Result: every middle child owns a visible property and resolves hidden
    # through its parent. `own=1` is what makes this a parent-gating result
    # rather than a child that hides itself.
    for child in MIDDLE_CHILDREN:
        line = visibility(result.stdout, child)
        assert "own=1 resolved=0" in line, (
            f"middle child {child} did not resolve hidden under its authored-off "
            f"parent {MIDDLE_ROOT}: {line}"
        )

    # Control: the top-right children still resolve visible. Without this the
    # result above would also pass if text parents hid their children
    # unconditionally.
    for child in TOP_RIGHT_CHILDREN:
        line = visibility(result.stdout, child)
        assert "own=1 resolved=1" in line, (
            f"top-right child {child} stopped resolving visible under its "
            f"authored-on parent {TOP_RIGHT_ROOT}: {line}"
        )

print(
    f"middle cluster gated by hidden text parent {MIDDLE_ROOT}; "
    f"child {FILTERED} rendered a uniform frame"
)
