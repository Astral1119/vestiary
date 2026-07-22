#!/usr/bin/env python3

import json
import pathlib
import struct
import sys


WORKSHOP = pathlib.Path(sys.argv[1])
GENERATED_OBJECT = pathlib.Path(sys.argv[2])
GENERATED_PARSER = pathlib.Path(sys.argv[3])
GENERATED_IMAGE = pathlib.Path(sys.argv[4])


def scene(item_id):
    with (WORKSHOP / item_id / "scene.pkg").open("rb") as package:
        def u32():
            return struct.unpack("<I", package.read(4))[0]

        def string():
            return package.read(u32()).decode("utf-8")

        string()
        entries = [(string(), u32(), u32()) for _ in range(u32())]
        base = package.tell()
        _, offset, length = next(item for item in entries if item[0] == "scene.json")
        package.seek(base + offset)
        return json.loads(package.read(length))


lonely = {item["id"]: item for item in scene("3299228616")["objects"]}
bar = lonely[387]
assert bar["config"]["passthrough"] is True
assert bar["copybackground"] is False
assert [effect["visible"] for effect in bar["effects"]] == [
    {"user": {"condition": "3", "name": "barstyle"}, "value": False},
    True,
]

assert "bool copyBackground = true;" in GENERATED_OBJECT.read_text()
assert (
    '.copyBackground = it.optional ("copybackground", true),'
    in GENERATED_PARSER.read_text()
)
image = GENERATED_IMAGE.read_text()
assert "FrescoScene::shouldCopyPassthroughBackground" in image
assert "this->getImage ().copyBackground" in image

print(
    "passthrough copy-background contract: Lonely Bar 3 starts transparent "
    "when its generator is disabled"
)
