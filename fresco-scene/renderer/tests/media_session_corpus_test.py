#!/usr/bin/env python3

import json
import pathlib
import struct
import sys


WORKSHOP = pathlib.Path(sys.argv[1])


def read_u32(handle):
    return struct.unpack("<I", handle.read(4))[0]


def read_string(handle):
    return handle.read(read_u32(handle)).decode("utf-8")


def scene_and_scripts(item_id):
    with (WORKSHOP / item_id / "scene.pkg").open("rb") as handle:
        read_string(handle)
        entries = [
            (read_string(handle), read_u32(handle), read_u32(handle))
            for _ in range(read_u32(handle))
        ]
        base = handle.tell()
        _, offset, length = next(item for item in entries if item[0] == "scene.json")
        handle.seek(base + offset)
        scene = json.loads(handle.read(length))

    result = []

    def walk(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if key == "script" and isinstance(child, str):
                    result.append(child)
                else:
                    walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)

    walk(scene)
    return scene, result


expected = {
    "3326873240": {
        "handlers": {"properties": 2, "playback": 7, "timeline": 1, "thumbnail": 6},
        "fields": {
            "title": 1, "artist": 1, "albumTitle": 0, "state": 7,
            "position": 1, "duration": 2, "primaryColor": 2,
            "tertiaryColor": 1, "textColor": 2, "secondaryColor": 0,
            "highContrastColor": 0,
        },
        "textures": {"$mediaThumbnail": 1, "$mediaPreviousThumbnail": 1},
    },
    "3479521040": {
        "handlers": {"properties": 1, "playback": 0, "timeline": 0, "thumbnail": 1},
        "fields": {
            "title": 1, "artist": 0, "albumTitle": 0, "state": 0,
            "position": 0, "duration": 0, "primaryColor": 0,
            "tertiaryColor": 0, "textColor": 0, "secondaryColor": 0,
            "highContrastColor": 0,
        },
        "textures": {"$mediaThumbnail": 1, "$mediaPreviousThumbnail": 1},
    },
    "3151551777": {
        "handlers": {"properties": 12, "playback": 12, "timeline": 0, "thumbnail": 38},
        "fields": {
            "title": 4, "artist": 4, "albumTitle": 4, "state": 12,
            "position": 0, "duration": 0, "primaryColor": 7,
            "tertiaryColor": 0, "textColor": 0, "secondaryColor": 0,
            "highContrastColor": 0,
        },
        "textures": {"$mediaThumbnail": 1, "$mediaPreviousThumbnail": 3},
    },
}
handlers = {
    "properties": "mediaPropertiesChanged",
    "playback": "mediaPlaybackChanged",
    "timeline": "mediaTimelineChanged",
    "thumbnail": "mediaThumbnailChanged",
}
for item_id, contract in expected.items():
    scene, sources = scene_and_scripts(item_id)
    actual = {
        kind: sum(f"function {handler}" in source for source in sources)
        for kind, handler in handlers.items()
    }
    assert actual == contract["handlers"], (item_id, actual)
    fields = {
        field: sum(source.count(f"event.{field}") for source in sources)
        for field in contract["fields"]
    }
    assert fields == contract["fields"], (item_id, fields)
    serialized = json.dumps(scene, ensure_ascii=False)
    textures = {
        name: serialized.count(f'"{name}"') for name in contract["textures"]
    }
    assert textures == contract["textures"], (item_id, textures)

print(
    "media session corpus: exact playback/timeline/color and current/previous artwork "
    "consumers pinned; secondary/high-contrast have no visible corpus consumer"
)
