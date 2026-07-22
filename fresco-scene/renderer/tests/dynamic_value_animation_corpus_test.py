#!/usr/bin/env python3

import collections
import json
import pathlib
import struct
import sys


WORKSHOP = pathlib.Path(sys.argv[1])
EXPECTED = {
    "3479521040": {
        "package": "PKGV0022", "scene": 5,
        "curves": 1, "channels": {1: 1}, "keys": 2, "magic": 4,
    },
    "3151551777": {
        "package": "PKGV0021", "scene": 1,
        "curves": 31, "channels": {1: 17, 2: 14}, "keys": 90, "magic": 8,
        "preview": {"absent": 15, "0": 14, "1": 2},
    },
}


def scene(item_id):
    with (WORKSHOP / item_id / "scene.pkg").open("rb") as handle:
        def read_u32():
            return struct.unpack("<I", handle.read(4))[0]

        def read_string():
            return handle.read(read_u32()).decode("utf-8")

        package_revision = read_string()
        entries = [
            (read_string(), read_u32(), read_u32())
            for _ in range(read_u32())
        ]
        base = handle.tell()
        _, offset, length = next(entry for entry in entries if entry[0] == "scene.json")
        handle.seek(base + offset)
        return package_revision, json.loads(handle.read(length))


def scripted_curves(value):
    result = []

    def walk(node):
        if isinstance(node, dict):
            if isinstance(node.get("animation"), dict) and isinstance(node.get("script"), str):
                result.append((node["animation"], node["script"]))
            for child in node.values():
                walk(child)
        elif isinstance(node, list):
            for child in node:
                walk(child)

    walk(value)
    return result


for item_id, expected in EXPECTED.items():
    package_revision, scene_json = scene(item_id)
    assert package_revision == expected["package"], (item_id, package_revision)
    assert scene_json["version"] == expected["scene"], (item_id, scene_json["version"])
    curves = scripted_curves(scene_json)
    assert len(curves) == expected["curves"], (item_id, len(curves))
    assert len({source for _, source in curves}) == 1
    assert all("thisObject.getAnimation().play();" in source for _, source in curves)
    preview = collections.Counter(
        "absent" if "previewvalue" not in animation else str(animation["previewvalue"])
        for animation, _ in curves
    )
    assert dict(preview) == expected.get("preview", {"absent": expected["curves"]})

    channels = collections.Counter()
    keys = []
    for animation, _ in curves:
        channel_count = len([
            key for key in animation if key.startswith("c") and key[1:].isdigit()
        ])
        channels[channel_count] += 1
        assert animation["options"]["mode"] == "single"
        assert animation["options"]["fps"] == 30
        assert animation["options"]["length"] in (30, 60)
        assert animation["options"]["wraploop"] is None
        assert set(animation["options"]) <= {
            "fps", "length", "mode", "startpaused", "wraploop"
        }
        for channel in range(channel_count):
            keys.extend(animation[f"c{channel}"])

    assert dict(channels) == expected["channels"], (item_id, channels)
    assert len(keys) == expected["keys"], (item_id, len(keys))
    assert all(key["lockangle"] is True and key["locklength"] is True for key in keys)
    assert all(key[side]["enabled"] is True for key in keys for side in ("front", "back"))
    magic = sum("magic" in key[side] for key in keys for side in ("front", "back"))
    assert magic == expected["magic"], (item_id, magic)
    assert all(
        key[side].get("magic", True) is True
        for key in keys
        for side in ("front", "back")
    )

print("dynamic-value animation corpus: ok (32 curves, 92 keys, 32 callbacks)")
