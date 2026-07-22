#!/usr/bin/env python3

import hashlib
import json
import os
import struct
import sys


WORKSHOP = os.path.abspath(sys.argv[1])
PACKAGE = os.path.join(WORKSHOP, "3326873240", "scene.pkg")


def read_u32(handle):
    return struct.unpack("<I", handle.read(4))[0]


def read_string(handle):
    return handle.read(read_u32(handle)).decode("utf-8")


with open(PACKAGE, "rb") as handle:
    read_string(handle)
    entries = [
        (read_string(handle), read_u32(handle), read_u32(handle))
        for _ in range(read_u32(handle))
    ]
    base = handle.tell()
    _, offset, length = next(entry for entry in entries if entry[0] == "scene.json")
    handle.seek(base + offset)
    scene = json.loads(handle.read(length))

objects = {item["id"]: item for item in scene["objects"]}
expected = {
    160: {
        "name": "Artist Name",
        "verticalalign": "bottom",
        "script_bytes": 559,
        "script_sha256": "16d7b171299b910386026beb333a4a71ee868b558d9da97fb1dc19b900e21919",
    },
    161: {
        "name": "Song Title",
        "verticalalign": "top",
        "script_bytes": 586,
        "script_sha256": "f999af63481d57d39eb066b65fb02d700d10834adbbcc2dade21d55048d820a6",
    },
}

for object_id, contract in expected.items():
    layer = objects[object_id]
    assert layer["name"] == contract["name"]
    assert layer["horizontalalign"] == "right"
    assert layer["verticalalign"] == contract["verticalalign"]
    assert layer["limitwidth"] is True
    assert layer["limitrows"] is True
    assert layer["maxrows"] == 1
    assert layer["limituseellipsis"] is False
    assert "overflowellipsis" not in layer
    assert layer["padding"] == 0
    assert "\n" in layer["text"]["value"]

    maxwidth = layer["maxwidth"]
    assert maxwidth["value"] == 1200.0
    source = maxwidth["script"]
    assert len(source) == contract["script_bytes"]
    assert hashlib.sha256(source.encode()).hexdigest() == contract["script_sha256"]
    assert "export function init" in source
    assert "export function update" in source
    assert 'thisScene.getLayer(mediaInfo)' in source
    assert "thisLayer.scale.x" in source
    assert "engine.canvasSize.x" in source
    assert "mediaInfo.scale.x" in source
    assert "mediaInfo.origin.x" in source
    for unsupported in (
        "registerAudioBuffers",
        "getVideoTexture",
        "mediaThumbnailChanged",
        "mediaTimelineChanged",
        "cursorClick",
    ):
        assert unsupported not in source

print(
    "Elaina text-width contract: objects 160/161, scripted maxwidth, "
    "single row, hard clip, right/left alignment"
)
