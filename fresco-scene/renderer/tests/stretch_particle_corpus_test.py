#!/usr/bin/env python3

import json
import pathlib
import struct
import sys


WORKSHOP = pathlib.Path(sys.argv[1])
EXPECTED = {
    "3326873240": {"instances": 1, "definitions": 1, "children": {}, "audio": 0},
    "3299228616": {
        "instances": 42,
        "definitions": 7,
        "children": {"eventfollow": 3, "eventspawn": 1},
        "audio": 6,
    },
    "3479521040": {
        "instances": 8,
        "definitions": 7,
        "children": {"static": 2, "implicit": 1},
        "audio": 0,
    },
    "3448290956": {"instances": 1, "definitions": 1, "children": {}, "audio": 0},
    "3151551777": {
        "instances": 33,
        "definitions": 24,
        "children": {"eventfollow": 3, "eventspawn": 1},
        "audio": 2,
    },
    "3460973721": {
        "instances": 3,
        "definitions": 3,
        "children": {"implicit": 1},
        "audio": 0,
    },
}


def read_u32(handle):
    return struct.unpack("<I", handle.read(4))[0]


def read_string(handle):
    return handle.read(read_u32(handle)).decode("utf-8")


def package_json(item_id):
    with (WORKSHOP / item_id / "scene.pkg").open("rb") as handle:
        read_string(handle)
        entries = [
            (read_string(handle), read_u32(handle), read_u32(handle))
            for _ in range(read_u32(handle))
        ]
        base = handle.tell()
        result = {}
        for name, offset, length in entries:
            if not name.endswith(".json"):
                continue
            handle.seek(base + offset)
            result[name] = json.loads(handle.read(length))
        return result


def active_audio_processing(document):
    total = 0
    for section in ("emitter", "initializer", "operator"):
        values = document.get(section, [])
        if not isinstance(values, list):
            continue
        for value in values:
            if not isinstance(value, dict) or value.get("audioprocessingmode", 0) == 0:
                continue
            assert section == "emitter", (section, value)
            assert value["audioprocessingmode"] == 3, value
            assert 0 <= value.get("audioprocessingfrequencyend", 1) <= 15, value
            assert 0 <= value.get("audioprocessingfrequencystart", 0) <= 15, value
            assert value.get("audioprocessingexponent", 2) > 0, value
            total += 1
    return total


def inspect(item_id):
    documents = package_json(item_id)
    scene = documents["scene.json"]
    references = [
        item["particle"] for item in scene["objects"] if "particle" in item
    ]
    definitions = set(references)
    assert definitions <= documents.keys(), (item_id, definitions - documents.keys())

    children = {}
    audio = 0
    for reference in definitions:
        document = documents[reference]
        audio += active_audio_processing(document)
        values = document.get("children") or []
        for child in values:
            child_type = child.get("type", "implicit")
            assert child_type in {"static", "eventfollow", "eventspawn", "implicit"}, child
            assert isinstance(child.get("name"), str) and child["name"], child
            assert child.get("maxcount", 20) > 0, child
            children[child_type] = children.get(child_type, 0) + 1
    return {
        "instances": len(references),
        "definitions": len(definitions),
        "children": children,
        "audio": audio,
    }


observed = {item_id: inspect(item_id) for item_id in EXPECTED}
assert observed == EXPECTED, observed
assert sum(item["instances"] for item in observed.values()) == 88
assert sum(sum(item["children"].values()) for item in observed.values()) == 12
assert sum(item["audio"] for item in observed.values()) == 8
hyuga = package_json("3479521040")
assert hyuga["particles/presets/leaves2b.json"]["maxcount"] == 50
assert hyuga["particles/presets/emberglow.json"]["maxcount"] == 500
hyuga_child_caps = sorted(
    child.get("maxcount", 20)
    for document in hyuga.values()
    if isinstance(document, dict)
    for child in (document.get("children") or [])
)
assert hyuga_child_caps == [10, 10, 20], hyuga_child_caps
arknights = package_json("3460973721")
arknights_variants = {
    name: arknights[name]
    for name in (
        "particles/workshop/2446178284/rising_debris_copy1.json",
        "particles/workshop/2446178284/dust_copy1.json",
    )
}
assert {
    name: {
        "emitters": [item["name"] for item in value["emitter"]],
        "initializers": [item["name"] for item in value["initializer"]],
        "operators": [item["name"] for item in value["operator"]],
    }
    for name, value in arknights_variants.items()
} == {
    "particles/workshop/2446178284/rising_debris_copy1.json": {
        "emitters": ["sphererandom"],
        "initializers": [
            "lifetimerandom", "sizerandom", "velocityrandom", "colorrandom",
            "angularvelocityrandom",
        ],
        "operators": ["movement", "alphafade", "angularmovement"],
    },
    "particles/workshop/2446178284/dust_copy1.json": {
        "emitters": ["sphererandom"],
        "initializers": [
            "lifetimerandom", "sizerandom", "velocityrandom", "colorrandom",
        ],
        "operators": ["movement", "alphafade"],
    },
}
assert arknights_variants[
    "particles/workshop/2446178284/rising_debris_copy1.json"
]["animationmode"] == "randomframe"
assert arknights_variants[
    "particles/workshop/2446178284/dust_copy1.json"
]["flags"] == 4
print("stretch particle corpus: 88 instances, 12 child systems, 8 audio processors")
