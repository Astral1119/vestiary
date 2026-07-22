#!/usr/bin/env python3

import collections
import hashlib
import json
import os
import re
import struct
import sys


WORKSHOP = os.path.abspath(sys.argv[1])
PROJECT = os.path.join(WORKSHOP, "3326873240")
PACKAGE = os.path.join(PROJECT, "scene.pkg")
EXPECTED_SHA256 = "aca149b27aecd174ac008bbda68875c2d83e1619602605ab4f634bb91df2da5d"


def read_scene():
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
        return json.loads(handle.read(length))


def scripted_values(value, path=()):
    if isinstance(value, dict):
        if isinstance(value.get("script"), str):
            yield path, value
        for key, child in value.items():
            if key != "script":
                yield from scripted_values(child, path + (str(key),))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from scripted_values(child, path + (str(index),))


def group(path, value):
    source = value["script"]
    property_path = "/".join(path[2:] if path[:1] == ("objects",) else path)
    if len(path) >= 3 and path[0] == "objects" and path[2:] == ("text",):
        return "text"
    if "applyUserProperties" in source and "displayVideo" in source:
        return "videoDayNight"
    if "mediaThumbnailChanged" in source:
        return (
            "thumbnailAnimation"
            if "thisObject.getAnimation().play" in source
            else "thumbnailColor"
        )
    if "mediaPlaybackChanged" in source:
        return (
            "playbackTimeline"
            if "mediaTimelineChanged" in source
            else "playbackLayout"
        )
    if "registerAudioBuffers" in source:
        return "audioTransform"
    if any(
        f"function {name}" in source
        for name in ("cursorClick", "cursorDown", "cursorMove", "cursorUp")
    ):
        return "cursorSettings"
    if "engine.canvasSize" in source and property_path == "origin":
        return "canvasOrigin"
    if "shared." in source:
        return "sharedWidget"
    if "input.cursor" in source:
        return "cursorFollow"
    return "layerLayout"


digest = hashlib.sha256()
with open(PACKAGE, "rb") as handle:
    for contents in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(contents)
assert digest.hexdigest() == EXPECTED_SHA256, digest.hexdigest()

scene = read_scene()
scripts = list(scripted_values(scene))
groups = collections.Counter(group(path, value) for path, value in scripts)
assert groups == {
    "audioTransform": 17,
    "canvasOrigin": 15,
    "cursorFollow": 1,
    "cursorSettings": 7,
    "layerLayout": 11,
    "playbackLayout": 6,
    "playbackTimeline": 1,
    "sharedWidget": 23,
    "text": 17,
    "thumbnailAnimation": 1,
    "thumbnailColor": 5,
    "videoDayNight": 1,
}, groups
assert len(scripts) == 105, len(scripts)
assert len({hashlib.sha256(value["script"].encode()).digest() for _, value in scripts}) == 53


def value_kind(value):
    value = value.get("value")
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "float"
    if isinstance(value, str):
        channels = len(value.split())
        return {2: "vector2", 3: "vector3", 4: "vector4"}.get(channels, "string")
    raise AssertionError(type(value))


kinds = collections.defaultdict(collections.Counter)
for path, value in scripts:
    if group(path, value) != "text":
        kinds[group(path, value)][value_kind(value)] += 1
assert {name: dict(counts) for name, counts in kinds.items()} == {
    "audioTransform": {"vector3": 17},
    "canvasOrigin": {"vector3": 15},
    "cursorFollow": {"vector3": 1},
    "cursorSettings": {"boolean": 2, "vector3": 5},
    "layerLayout": {"boolean": 1, "float": 2, "vector3": 8},
    "playbackLayout": {"boolean": 1, "float": 2, "vector3": 3},
    "playbackTimeline": {"vector3": 1},
    "sharedWidget": {"boolean": 4, "float": 1, "vector3": 18},
    "thumbnailAnimation": {"integer": 1},
    "thumbnailColor": {"vector3": 5},
    "videoDayNight": {"boolean": 1},
}, kinds

nontext = [value["script"] for path, value in scripts if group(path, value) != "text"]
joined = "\n".join(nontext)

reads = collections.Counter(
    match.group(0)
    for source in nontext
    for root in (
        "engine",
        "event",
        "input",
        "localStorage",
        "shared",
        "thisLayer",
        "thisObject",
        "thisScene",
    )
    for match in re.finditer(rf"\b{root}\.[A-Za-z_]\w*", source)
)
required_reads = {
    "engine.AUDIO_RESOLUTION_16",
    "engine.canvasSize",
    "engine.frametime",
    "engine.registerAudioBuffers",
    "engine.setTimeout",
    "event.duration",
    "event.position",
    "event.primaryColor",
    "event.state",
    "event.tertiaryColor",
    "event.textColor",
    "event.worldPosition",
    "input.cursorWorldPosition",
    "localStorage.get",
    "localStorage.set",
    "thisLayer.getAnimationLayer",
    "thisLayer.getParent",
    "thisLayer.getTextureAnimation",
    "thisLayer.getTransformMatrix",
    "thisObject.getAnimation",
    "thisScene.getLayer",
}
assert required_reads <= reads.keys(), sorted(required_reads - reads.keys())

writes = collections.Counter(
    f"{match.group(1)}.{match.group(2)}"
    for source in nontext
    for match in re.finditer(
        r"\b(thisLayer|shared)\.([A-Za-z_]\w*)\s*(?:=|\+=|-=|\*=|/=)",
        source,
    )
)
assert writes == {
    "shared.miClockPos": 8,
    "shared.miCursorIn": 3,
    "shared.miDragable": 4,
    "shared.miInitTextBgColorAlpha": 1,
    "shared.miMaxCLickTime": 1,
    "shared.miPrimaryColor": 3,
    "shared.miSettingsOpen": 2,
    "shared.miSettingsOpenSpeed": 2,
    "shared.miSettingsVisible": 3,
    "shared.miShowClock": 7,
    "shared.miTextBgColor": 3,
    "shared.miTextBgColorFadeSpeed": 2,
    "shared.miTextColor": 2,
    "shared.miTextContainerScale": 3,
    "shared.miTextPos": 10,
    "shared.miTextVisible": 6,
    "shared.miTextVisibleTriggerValue": 1,
    "thisLayer.horizontalalign": 2,
    "thisLayer.origin": 1,
    "thisLayer.verticalalign": 1,
    "thisLayer.visible": 6,
}, writes

objects = {item["id"]: item for item in scene["objects"]}
assert objects[131]["name"] == "Media Info (ROUND)"
assert objects[131]["visible"] == {"user": "newproperty67", "value": False}
assert {
    item["name"]: item["id"]
    for item in scene["objects"]
    if item.get("name") in {"morning", "day", "dusk", "night", "mddn"}
} == {"morning": 718, "day": 781, "dusk": 899, "night": 960, "mddn": 1210}

assert joined.count("engine.registerAudioBuffers") == 20
assert joined.count("thisLayer.getParent") == 17
assert joined.count("thisScene.getLayer") == 7
assert joined.count("localStorage.get") == 5
assert joined.count("localStorage.set") == 5
assert joined.count("engine.setTimeout") == 3
assert joined.count("thisLayer.getTransformMatrix") == 3
assert joined.count("getVideoTexture().play") == 1
assert joined.count("getVideoTexture().pause") == 1
assert joined.count("thisObject.getAnimation().play") == 3
assert joined.count("thisLayer.getTextureAnimation") == 4
assert joined.count("thisLayer.getAnimationLayer") == 1
assert joined.count("function mediaPlaybackChanged") == 7
assert joined.count("function mediaTimelineChanged") == 1
assert joined.count("function mediaThumbnailChanged") == 6
assert joined.count("function applyUserProperties") == 1
assert joined.count("function cursorClick") == 5
assert joined.count("function cursorDown") == 2
assert joined.count("function cursorMove") == 1
assert joined.count("function cursorUp") == 2
assert joined.count("function cursorEnter") == 2
assert joined.count("function cursorLeave") == 2
assert set(re.findall(r"import \* as \w+ from ['\"]([^'\"]+)", joined)) == {"WEMath"}

for forbidden in (
    "eval(",
    "Function(",
    "fetch(",
    "require(",
    "WebSocket",
    "XMLHttpRequest",
    "globalThis",
    "__fresco",
    "__proto__",
    ".constructor",
    ".prototype",
    "thisScene.setCamera",
    "engine.setCamera",
    "thisLayer[",
    "thisObject[",
    "thisScene[",
    "scene[",
    "engine[",
    "input[",
    "localStorage[",
    "event[",
):
    assert forbidden not in joined, forbidden

print(
    "Elaina SceneScript contract: 105 scripts, 88 non-text, 53 distinct bodies; "
    "bounded 2D layer graph, media, audio, cursor/storage, and five video layers"
)
