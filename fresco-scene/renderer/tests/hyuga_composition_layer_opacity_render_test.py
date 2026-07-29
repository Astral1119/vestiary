#!/usr/bin/env python3

"""Hyuga's ember fades with the composition layer it hangs under.

Object 261 (`大型`) is a particle child of 367 (`可调整组合层`), a passthrough
composition layer whose second opacity effect animates its `alpha` constant from
0.16 to 1 and back to 0 across the 90-frame opening. 261 declares no alpha and
no visibility of its own, and it draws after 367 in authored order, so nothing
scaled it and the embers kept burning at full strength over a fully faded layer.

The controls are the scene's other particle systems. 1724 is also a child of a
passthrough composition layer (1695), but that layer's effects declare no
`alpha` constant, so it must stay fully opaque — that is what holds the rule to
composition layers that actually author an opacity, rather than to parentage.
"""

import os
import pathlib
import re
import subprocess
import sys

RENDERER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
EVIDENCE = pathlib.Path(sys.argv[4])
HYUGA = WORKSHOP / "3479521040"

EMBER = 261
# The smoke tool advances two frames per authored frame, so the 90-frame
# opening completes at 180 and the tail proves the fade holds rather than
# dipping through zero.
FRAMES = 220
FADE_COMPLETE = 180

TRACE = re.compile(
    r"particleTrace id=(\d+) .*inheritedOpacity=([0-9.]+)"
)

EVIDENCE.mkdir(parents=True, exist_ok=True)
output = EVIDENCE / "hyuga-composition-layer-opacity.png"
environment = os.environ.copy()
environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
environment["FRESCO_SCENE_PARTICLE_TRACE"] = "1"
result = subprocess.run(
    [RENDERER, HYUGA, ASSETS, output, str(FRAMES)],
    capture_output=True,
    check=False,
    env=environment,
    text=True,
    timeout=600,
)
assert result.returncode == 0, (
    f"Hyuga render failed ({result.returncode}): {result.stderr[-2000:]}"
)

series = {}
for match in TRACE.finditer(result.stderr):
    series.setdefault(int(match.group(1)), []).append(float(match.group(2)))

assert EMBER in series, (
    f"no particleTrace for object {EMBER}; the trace reports "
    f"{sorted(series)}. Does this build carry inheritedOpacity?"
)
ember = series[EMBER]
assert len(ember) >= FADE_COMPLETE, f"only {len(ember)} traced frames"

# The authored curve: opens near 0.16, holds at 1 through the middle with the
# Bezier overshoot the same corpus shows on object 187, then reaches 0. The
# first traced frame predates the first refresh and still carries the member's
# 1.0 initialiser, so the opening is read from the early ramp rather than
# frame 0.
opening = min(ember[:FADE_COMPLETE // 4])
assert opening < 0.5, f"ember ramps from {opening}, expected the authored 0.16"
assert max(ember) >= 1.0, f"ember peaks at {max(ember)}, expected a hold at 1"

tail = ember[FADE_COMPLETE:]
assert tail, "no frames past the end of the opening animation"
assert max(tail) <= 0.001, (
    f"ember still carries opacity {max(tail)} after the opening animation "
    f"completes at frame {FADE_COMPLETE}; the composition layer's fade is not "
    f"reaching its particle child"
)

controls = {
    identifier: values for identifier, values in series.items()
    if identifier != EMBER
}
assert controls, "no control particle systems traced"
for identifier, values in sorted(controls.items()):
    assert min(values) == 1.0 and max(values) == 1.0, (
        f"control particle {identifier} inherited opacity in "
        f"[{min(values)}, {max(values)}]; only a composition layer authoring an "
        f"alpha constant may propagate"
    )

print(
    f"Hyuga object {EMBER}: inheritedOpacity {opening:.4f} -> "
    f"{max(ember):.4f} -> {max(tail):.4f} past frame {FADE_COMPLETE}; "
    f"{len(controls)} control systems held at 1.0"
)
