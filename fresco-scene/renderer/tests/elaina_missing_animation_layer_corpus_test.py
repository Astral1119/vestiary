#!/usr/bin/env python3

import hashlib
import io
import json
import pathlib
import struct
import sys


WORKSHOP = pathlib.Path(sys.argv[1]).resolve()
PACKAGE = WORKSHOP / "3326873240" / "scene.pkg"
EXPECTED_SHA256 = "aca149b27aecd174ac008bbda68875c2d83e1619602605ab4f634bb91df2da5d"
EXPECTED_CLASSIFICATION = "recognized inert: missing serialized animation-layer target"


def read_u32(handle):
    return struct.unpack("<I", handle.read(4))[0]


def read_string(handle):
    return handle.read(read_u32(handle)).decode("utf-8")


def read_package(path):
    with path.open("rb") as handle:
        assert read_string(handle) == "PKGV0023"
        entries = [
            (read_string(handle), read_u32(handle), read_u32(handle))
            for _ in range(read_u32(handle))
        ]
        base = handle.tell()
        contents = {}
        for name, offset, length in entries:
            handle.seek(base + offset)
            contents[name] = handle.read(length)
    return contents


def animation_names(value):
    names = []
    if isinstance(value, dict):
        animation = value.get("animation")
        if isinstance(animation, dict):
            options = animation.get("options")
            if isinstance(options, dict) and isinstance(options.get("name"), str):
                names.append(options["name"])
        for child in value.values():
            names.extend(animation_names(child))
    elif isinstance(value, list):
        for child in value:
            names.extend(animation_names(child))
    return names


def texture_topology(contents):
    handle = io.BytesIO(contents)
    assert handle.read(9) == b"TEXV0005\0"
    assert handle.read(9) == b"TEXI0001\0"
    texture_format = read_u32(handle)
    flags = read_u32(handle)
    texture_width = read_u32(handle)
    texture_height = read_u32(handle)
    width = read_u32(handle)
    height = read_u32(handle)
    read_u32(handle)
    assert handle.read(9) == b"TEXB0003\0"
    image_count = read_u32(handle)
    return {
        "format": texture_format,
        "flags": flags,
        "texture_width": texture_width,
        "texture_height": texture_height,
        "width": width,
        "height": height,
        "image_count": image_count,
    }


def classify_missing_animation_layer(
    layer, model, material, texture, requested_name, named_animations
):
    animation_layers = layer.get("animationlayers", [])
    serialized_names = {
        candidate.get("name")
        for candidate in animation_layers
        if isinstance(candidate, dict) and isinstance(candidate.get("name"), str)
    }
    has_static_image_topology = (
        isinstance(layer.get("image"), str)
        and not animation_layers
        and set(model) == {"autosize", "material"}
        and len(material.get("passes", [])) == 1
        and material["passes"][0].get("shader") == "genericimage4"
        and texture["image_count"] == 1
        and texture["flags"] & 4 == 0
    )
    if (
        has_static_image_topology
        and requested_name not in serialized_names
        and requested_name not in named_animations
    ):
        return EXPECTED_CLASSIFICATION
    return "animation-layer target may be present"


package_bytes = PACKAGE.read_bytes()
assert hashlib.sha256(package_bytes).hexdigest() == EXPECTED_SHA256
contents = read_package(PACKAGE)
scene = json.loads(contents["scene.json"])
layer = next(item for item in scene["objects"] if item.get("id") == 398)

assert set(layer) == {
    "angles",
    "castshadow",
    "clampuvs",
    "disablepropagation",
    "id",
    "image",
    "name",
    "origin",
    "parallaxDepth",
    "scale",
    "size",
    "visible",
}
assert "animationlayers" not in layer
assert "effects" not in layer
assert layer["image"] == "models/鼠标指针.json"

script = layer["visible"]["script"]
assert script.count('thisLayer.getAnimationLayer("dianji").play()') == 1
assert package_bytes.count(b"dianji") == 1

named_animations = animation_names(scene)
assert "dianji" not in named_animations

model = json.loads(contents[layer["image"]])
assert model == {
    "autosize": True,
    "material": "materials/鼠标指针.json",
}
material = json.loads(contents[model["material"]])
assert len(material["passes"]) == 1
assert material["passes"][0]["textures"] == ["伊蕾娜"]
texture = texture_topology(contents["materials/伊蕾娜.tex"])
assert texture == {
    "format": 4,
    "flags": 2,
    "texture_width": 800,
    "texture_height": 800,
    "width": 800,
    "height": 800,
    "image_count": 1,
}

classification = classify_missing_animation_layer(
    layer, model, material, texture, "dianji", set(named_animations)
)
assert classification == EXPECTED_CLASSIFICATION

print(
    "Elaina missing animation layer: object 398 is a static image; "
    "dianji is a single stale script reference; " + classification
)
