#!/usr/bin/env python3

import json
import os
import pathlib
import subprocess
import sys


HELPER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
PERSONA = WORKSHOP / "3151551777"
ASSIGNMENT = "particle-child-visual-ab"


def render(disabled):
    environment = os.environ.copy()
    environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    environment["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "0"
    if disabled:
        environment["FRESCO_PARTICLE_CHILD_DISABLED"] = "1"
    commands = (
        {
            "protocolVersion": 1,
            "type": "load",
            "assignmentID": ASSIGNMENT,
            "path": str(PERSONA),
            "assetRoot": str(ASSETS),
            # The eventspawn child rides Persona's night star layers, so the
            # clock is pinned rather than left on the authored "99" cycle.
            "userProperties": {"timeofday": {"value": "2"}},
            "width": 320,
            "height": 180,
            "visible": False,
            "evidenceFrames": 180,
        },
        {
            "protocolVersion": 1,
            "type": "stop",
            "assignmentID": ASSIGNMENT,
        },
    )
    result = subprocess.run(
        [HELPER],
        input="".join(json.dumps(command) + "\n" for command in commands),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=90,
        env=environment,
        check=True,
    )
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert [event["type"] for event in events] == ["ready", "stopped"], events
    ready = events[0]
    assert ready["backend"] == EXPECTED_BACKEND, ready
    assert ready["drawComplete"] is True and ready["frames"] == 180, ready
    return ready["pixelRGBTotal"]


enabled = (render(False), render(False))
disabled = (render(True), render(True))
baseline_delta = max(abs(enabled[0] - enabled[1]), abs(disabled[0] - disabled[1]))
child_delta = min(abs(left - right) for left in enabled for right in disabled)
assert child_delta > 1_000 and child_delta > max(1, baseline_delta) * 4, (
    enabled,
    disabled,
    baseline_delta,
    child_delta,
)
print(
    f"particle child visual A/B: {EXPECTED_BACKEND} "
    f"baseline={baseline_delta} child={child_delta}"
)
