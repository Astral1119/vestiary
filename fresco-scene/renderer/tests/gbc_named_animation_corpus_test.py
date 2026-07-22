#!/usr/bin/env python3

import hashlib
import json
import pathlib
import struct
import sys


WORKSHOP = pathlib.Path(sys.argv[1])
PACKAGE = WORKSHOP / "3448290956" / "scene.pkg"
PROJECT = WORKSHOP / "3448290956" / "project.json"
EXPECTED_SHA256 = "4bac6871f95380c374653c44a903538cfa841a8d17abe310a092543dd9ac6ac1"


def package_scene():
    with PACKAGE.open("rb") as handle:
        def read_u32():
            return struct.unpack("<I", handle.read(4))[0]

        def read_string():
            return handle.read(read_u32()).decode("utf-8")

        revision = read_string()
        entries = [
            (read_string(), read_u32(), read_u32())
            for _ in range(read_u32())
        ]
        base = handle.tell()
        _, offset, length = next(entry for entry in entries if entry[0] == "scene.json")
        handle.seek(base + offset)
        return revision, json.loads(handle.read(length))


assert hashlib.sha256(PACKAGE.read_bytes()).hexdigest() == EXPECTED_SHA256
revision, scene = package_scene()
assert revision == "PKGV0022", revision
objects = {item["id"]: item for item in scene["objects"]}

controller = objects[134]["visible"]
source = controller["script"]
assert len(source) == 1846, len(source)
assert hashlib.sha256(source.encode()).hexdigest() == (
    "41598d5f278f90642500fb66d7a5fc17ce39bc7bebff14f683fba3ac138c71e5"
)
assert controller["scriptproperties"] == {
    "kaiguan": {"user": "kaiguan", "value": True}
}
for token in (
    "Date.now()",
    "doubleClickThreshold = 500",
    'thisScene.getLayer("左眼白")',
    'leftEyeLayer.getAnimation("点击动画")',
    'thisScene.getLayer("戳头")',
    'headPokeLayer.getAnimation("chuo")',
    "clickAnimation.play()",
    "chuoAnimation.play()",
):
    assert token in source, token

eye = objects[377]
assert eye["name"] == "左眼白"
assert eye["origin"]["value"] == "3.10315 -226.51782 0.00000"
eye_animation = eye["origin"]["animation"]
assert eye_animation["relative"] is True
assert eye_animation["options"] == {
    "fps": 30,
    "length": 90,
    "mode": "single",
    "name": "点击动画",
    "startpaused": True,
    "wraploop": None,
}
assert [len(eye_animation[f"c{axis}"]) for axis in range(3)] == [6, 6, 6]
assert eye_animation["c1"][0]["value"] == 0
assert eye_animation["c1"][1]["value"] == -338.20648
assert eye_animation["c1"][-1]["value"] == 0

poke = objects[372]
assert poke["name"] == "戳头"
assert poke["visible"] is False
assert poke["alpha"]["value"] == 1.0
poke_animation = poke["alpha"]["animation"]
assert poke_animation["options"] == {
    "fps": 30,
    "length": 90,
    "mode": "single",
    "name": "chuo",
    "startpaused": True,
    "wraploop": None,
}
assert [key["frame"] for key in poke_animation["c0"]] == [0, 20, 77, 90, 97]
assert [key["value"] for key in poke_animation["c0"]] == [0, 1, 1, 0, 0]

camera = objects[1297271]
assert camera["camera"] == "default"
assert camera["path"] == "scripts/camera_paths_1297271.json"
assert camera["zoom"] == {"user": "newproperty30", "value": 1.0}
assert camera["origin"]["scriptproperties"] == {
    "x": {"user": "x3", "value": 0.5},
    "y": {"user": "y1", "value": 0.5},
}
project_properties = json.loads(PROJECT.read_text())["general"]["properties"]
assert project_properties["x3"]["value"] == 0
assert project_properties["y1"]["value"] == 0
assert project_properties["newproperty30"]["value"] == 1

print("GBC named-animation/camera corpus: ok (2 named curves, empty 2D camera path)")
