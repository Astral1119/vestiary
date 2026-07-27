#!/usr/bin/env python3

import json
import os
import pathlib
import re
import subprocess
import sys


HELPER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
LONELY = WORKSHOP / "3299228616"
ACTIVE_TEXT_IDS = {150, 312}


def message(kind, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": "lonely-font-runtime",
        **values,
    }


commands = (
    message(
        "load",
        path=str(LONELY),
        assetRoot=str(ASSETS),
        width=320,
        height=180,
        fps=60,
        visible=False,
        muted=True,
        evidenceFrames=120,
    ),
    message("stop"),
)
environment = os.environ.copy()
environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
environment["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "0"
environment["FRESCO_SCENE_TRACE_TEXT_FONT"] = "1"
result = subprocess.run(
    [HELPER],
    input="".join(json.dumps(command) + "\n" for command in commands),
    capture_output=True,
    check=True,
    env=environment,
    text=True,
    timeout=180,
)
events = [json.loads(line) for line in result.stdout.splitlines()]
assert [event["type"] for event in events] == ["ready", "stopped"], events
ready = events[0]
assert ready["backend"] == EXPECTED_BACKEND, ready
assert ready["drawComplete"] is True, ready
assert ready["scriptErrors"] == 0, ready

font_pattern = re.compile(
    r"^text-font object=(\d+) requested=(.*?) resolved=(.*?) "
    r"substituted=([01]) fixed=([01]) path=(.+)$"
)
glyph_pattern = re.compile(
    r"^text-glyphs object=(\d+) chars=(\d+) covered=(\d+) "
    r"missing=(\d+) family=(.+)$"
)
fonts = {}
glyphs = {object_id: [] for object_id in ACTIVE_TEXT_IDS}
unexpected = []
for line in result.stderr.splitlines():
    font = font_pattern.match(line)
    glyph = glyph_pattern.match(line)
    if font:
        object_id = int(font.group(1))
        if object_id in ACTIVE_TEXT_IDS:
            fonts[object_id] = font.groups()[1:]
    elif glyph:
        object_id = int(glyph.group(1))
        if object_id in ACTIVE_TEXT_IDS:
            glyphs[object_id].append(tuple(map(int, glyph.groups()[1:4])))
    elif line:
        unexpected.append(line)

assert not unexpected, unexpected
assert set(fonts) == ACTIVE_TEXT_IDS, fonts
for object_id, (requested, resolved, substituted, fixed, path) in fonts.items():
    assert requested.lower() == "consolas", (object_id, fonts[object_id])
    assert resolved, (object_id, fonts[object_id])
    assert substituted in {"0", "1"}, (object_id, fonts[object_id])
    assert fixed == "1", (object_id, fonts[object_id])
    assert pathlib.Path(path).is_file(), (object_id, path)

for object_id, samples in glyphs.items():
    rendered = [sample for sample in samples if sample[0] > 1]
    assert rendered, (object_id, samples)
    for char_count, covered, missing in rendered:
        assert missing == 0, (object_id, char_count, covered, missing)
        assert covered == char_count, (object_id, char_count, covered, missing)

print(
    "Lonely font runtime: active clock/date use fixed-pitch resolved fonts "
    "with complete glyph coverage"
)
