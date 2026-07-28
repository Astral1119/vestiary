#!/usr/bin/env python3

import hashlib
import json
import os
import struct


TESTS = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(TESTS, "scene-fixtures.json")
CONTENT = os.environ.get(
    "FRESCO_WORKSHOP_DIR",
    os.path.expanduser(
        "~/Library/Application Support/Steam/steamapps/workshop/content/431960"
    ),
)


def read_u32(handle):
    raw = handle.read(4)
    if len(raw) != 4:
        raise AssertionError("truncated package header")
    return struct.unpack("<I", raw)[0]


def read_string(handle):
    length = read_u32(handle)
    return handle.read(length).decode("utf-8")


def inspect_package(path):
    with open(path, "rb") as handle:
        raw = handle.read()
        digest = hashlib.sha256(raw).hexdigest()
        handle.seek(0)
        header = read_string(handle)
        file_count = read_u32(handle)
        entries = [
            (read_string(handle), read_u32(handle), read_u32(handle))
            for _ in range(file_count)
        ]
        base_offset = handle.tell()
        documents = {}
        for name, offset, length in entries:
            if not name.endswith(".json"):
                continue
            handle.seek(base_offset + offset)
            documents[name] = json.loads(handle.read(length))

    scene = documents.get("scene.json")
    assert scene is not None, "package has no scene.json"
    objects = scene.get("objects", [])
    object_types = {}

    def count(name):
        object_types[name] = object_types.get(name, 0) + 1

    for item in objects:
        if isinstance(item.get("image"), str):
            count("image")
        if isinstance(item.get("particle"), (str, dict)):
            count("particle")
        if isinstance(item.get("model"), str):
            count("model")
        if isinstance(item.get("sound"), list):
            count("sound")
        if "text" in item:
            count("text")
        if "light" in item:
            count("light")
        if "camera" in item:
            visible = item.get("visible")
            if isinstance(visible, dict) and visible.get("value") is False:
                count("inactiveCamera")
            else:
                count("camera")
        if "shape" in item and isinstance(item.get("effects"), list):
            count("effectQuad")

    script_values = 0

    def visit(value):
        nonlocal script_values
        if isinstance(value, dict):
            if isinstance(value.get("script"), str):
                script_values += 1
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(scene)
    effects = sum(
        len(item.get("effects", []))
        for item in objects
        if isinstance(item.get("effects"), list)
    )
    puppet_models = sum(
        1
        for name, document in documents.items()
        if name.startswith("models/")
        and isinstance(document, dict)
        and isinstance(document.get("puppet"), str)
    )
    shader_files = sum(
        1 for name, _, _ in entries if name.endswith((".vert", ".frag"))
    )
    audio_files = sum(
        1
        for name, _, _ in entries
        if name.lower().endswith((".mp3", ".ogg", ".flac", ".wav"))
    )
    return {
        "sha256": digest,
        "bytes": len(raw),
        "header": header,
        "files": file_count,
        "objects": len(objects),
        "objectTypes": object_types,
        "effects": effects,
        "shaderFiles": shader_files,
        "puppetModels": puppet_models,
        "audioFiles": audio_files,
        "scriptValues": script_values,
    }


with open(MANIFEST, encoding="utf-8") as handle:
    fixture_manifest = json.load(handle)

assert fixture_manifest["schemaVersion"] == 1
assert fixture_manifest["redistribute"] is False
picker_counts = {"available": 0, "reach": 0, "not-yet-possible": 0}
for fixture in fixture_manifest["items"]:
    picker = fixture["picker"]
    assert picker["status"] in picker_counts, (fixture["id"], picker)
    assert picker["note"].strip(), (fixture["id"], picker)
    picker_counts[picker["status"]] += 1
assert picker_counts == {
    "available": 5,
    "reach": 4,
    "not-yet-possible": 5,
}, picker_counts

checked = 0
for fixture in fixture_manifest["items"]:
    package_path = os.path.join(CONTENT, fixture["id"], "scene.pkg")
    if not os.path.isfile(package_path):
        continue
    actual = inspect_package(package_path)
    assert actual == fixture["package"], (fixture["id"], actual, fixture["package"])
    checked += 1

if checked:
    print(f"Scene fixture package checks passed: {checked}")
else:
    print("Scene fixture package checks skipped: no local scene fixtures")
