#!/usr/bin/env python3

import json
import pathlib
import struct
import sys


WORKSHOP = pathlib.Path(sys.argv[1])
GENERATED_TEXT = pathlib.Path(sys.argv[2])
SCRIPTABLE_OBJECT = pathlib.Path(sys.argv[3])
PUPPET_INTEGRATION = pathlib.Path(sys.argv[4])
GENERATED_SCENE = pathlib.Path(sys.argv[5])
SCRIPT_ENGINE = pathlib.Path(sys.argv[6])
GENERATED_IMAGE = pathlib.Path(sys.argv[7])


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


def objects(item_id):
    return {item["id"]: item for item in scene(item_id)["objects"]}


arknights = objects("3460973721")
assert arknights[88]["parent"] == 129
assert {arknights[item]["parent"] for item in (90, 96, 101)} == {88}

lonely = objects("3299228616")
assert lonely[210]["parent"] == 246
assert {lonely[item]["parent"] for item in (150, 151, 303, 312, 387, 678)} == {210}

gbc = objects("3448290956")
assert [gbc[item].get("parent") for item in (346, 137, 142, 377, 179)] == [
    137, 142, 377, 179, None,
]
assert "script" in gbc[137]["angles"]
assert "animation" in gbc[142]["scale"]
assert "script" in gbc[142]["angles"]
assert "animation" in gbc[377]["origin"]
assert "script" in gbc[179]["origin"]

scriptable = SCRIPTABLE_OBJECT.read_text()
for token in (
    'registerProperty ("scale", *image->scale->value)',
    'registerProperty ("angles", *image->angles->value)',
    'registerProperty ("visible", *image->visible->value)',
    'registerProperty ("scale", *object.groupScale->value)',
):
    assert token in scriptable, token

text = GENERATED_TEXT.read_text()
assert "FrescoScene::resolveSceneObjectTransform (getScene (), m_text)" in text
assert "FrescoScene::sceneObjectVisibleWithParents (getScene (), m_text)" in text
assert "glm::rotate (model, -transform.angle" in text

puppet = PUPPET_INTEGRATION.read_text()
assert "const auto transform = this->resolveTransform (this->getImage ())" in puppet
assert "local.origin.y * resolved.scale.y" in puppet
assert "FrescoScene::sceneObjectVisibleWithParents" in puppet
for field in ("translationX", "translationY", "rotationZ", "scaleX", "scaleY"):
    assert f".{field} = transform." in puppet, field

generated_image = GENERATED_IMAGE.read_text()
assert "local.origin.y * resolved.scale.y" in generated_image
assert "-local.origin.y * resolved.scale.y" not in generated_image

generated_scene = GENERATED_SCENE.read_text()
assert "requiredAsParent = std::ranges::any_of" in generated_scene
assert "Using a transform-only placeholder for failed parent object" in generated_scene
assert "new WallpaperEngine::Scripting::ScriptableObject (*this, object)" in generated_scene

script_engine = SCRIPT_ENGINE.read_text()
assert "existing->second.target = target" in script_engine
assert "pending->second.target = target" in script_engine

print(
    "parent transform contract: Arknights and Lonely text groups composed; "
    "GBC five-node animated chain drives puppet input"
)
