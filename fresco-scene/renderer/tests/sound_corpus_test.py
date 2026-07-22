#!/usr/bin/env python3

import json
import pathlib
import re
import struct
import subprocess
import sys
import tempfile


PROBE = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])


def read_u32(handle):
    return struct.unpack("<I", handle.read(4))[0]


def read_string(handle):
    return handle.read(read_u32(handle)).decode("utf-8")


def package(item_id, include_audio=True):
    with (WORKSHOP / item_id / "scene.pkg").open("rb") as handle:
        read_string(handle)
        entries = [
            (read_string(handle), read_u32(handle), read_u32(handle))
            for _ in range(read_u32(handle))
        ]
        base = handle.tell()
        contents = {}
        for name, offset, length in entries:
            if name == "scene.json" or (
                include_audio
                and name.lower().endswith((".mp3", ".flac", ".ogg", ".wav"))
            ):
                handle.seek(base + offset)
                contents[name] = handle.read(length)
    scene = json.loads(contents.pop("scene.json"))
    sounds = [item for item in scene["objects"] if isinstance(item.get("sound"), list)]
    return scene, sounds, contents


def project_properties(item_id):
    with (WORKSHOP / item_id / "project.json").open(encoding="utf-8") as handle:
        project = json.load(handle)
    return project["general"]["properties"]


def volume(item):
    value = item.get("volume", 1.0)
    return value.get("value", 1.0) if isinstance(value, dict) else value


def script_sources(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "script" and isinstance(child, str):
                yield child
            else:
                yield from script_sources(child)
    elif isinstance(value, list):
        for child in value:
            yield from script_sources(child)


def control_methods(source):
    return set(re.findall(r"\.\s*(play|pause|stop|isPlaying)\s*\(", source))


def matching_script(scene, marker):
    matches = [source for source in script_sources(scene) if marker in source]
    assert len(matches) == 1, (marker, len(matches))
    return matches[0]


def sound_index_names(scene):
    return {
        index: item["name"]
        for index, item in enumerate(scene["objects"])
        if isinstance(item.get("sound"), list)
    }


def visible_script_controller(scene, index, object_id):
    item = scene["objects"][index]
    assert item["id"] == object_id, item
    visible = item["visible"]
    assert isinstance(visible.get("value"), bool), visible
    assert isinstance(visible.get("script"), str), visible
    return visible


nier_scene, nier, nier_assets = package("1845706469")
assert len(nier) == 1
assert nier[0]["playbackmode"] == "loop"
assert nier[0]["startsilent"] is False
assert volume(nier[0]) == 0.5

arknights_scene, arknights, arknights_assets = package("3460973721")
assert len(arknights) == 4
assert sum(item["playbackmode"] == "random" for item in arknights) == 1
assert all(item["startsilent"] is True for item in arknights)
assert len(arknights_assets) == 3
assert all(name.lower().endswith(".flac") for name in arknights_assets)
arknights_control = matching_script(arknights_scene, "function playTargetMusic()")
arknights_visible = visible_script_controller(arknights_scene, 13, 95)
assert arknights_control == arknights_visible["script"]
assert arknights_visible["value"] is True
assert control_methods(arknights_control) == {"isPlaying", "play", "stop"}
assert "export function init()" in arknights_control
assert "export function applyUserProperties(" in arknights_control
assert "export function cursorClick(" not in arknights_control
arknights_music = project_properties("3460973721")["music"]
assert (arknights_music["type"], arknights_music["value"]) == ("combo", "1")
assert [option["value"] for option in arknights_music["options"]] == [
    "0", "1", "2", "3", "4"
]
assert sound_index_names(arknights_scene) == {
    14: "Storyteller(叙事者)",
    15: "Echoism (Instrumental).flac",
    16: "Silent Tales(未曾讲述之事).flac",
    17: "随机",
}
assert "targetMusicIndex = selectedMusic - 1" in arknights_control
assert "selectedMusic !== 0" in arknights_control

gbc_scene, gbc, gbc_assets = package("3448290956")
assert len(gbc) == 2
assert all(item["startsilent"] is False for item in gbc), "pinned GBC anomaly changed"
voice = next(item for item in gbc if item["name"] == "Voice1")
background = next(item for item in gbc if item["playbackmode"] == "loop")
assert voice["playbackmode"] == "single"
assert abs(volume(background) - 0.69999999) < 0.000001
gbc_control = matching_script(
    gbc_scene, "This script plays a sound from a specified layer"
)
assert control_methods(gbc_control) == {"play"}
assert "export function cursorClick(" in gbc_control
assert "value:'Voice1'" in gbc_control
assert "value:'Voice2'" in gbc_control
assert "Voice2" not in {item["name"] for item in gbc}
gbc_cursor_controllers = {
    (index, item["id"], item["visible"]["value"])
    for index, item in enumerate(gbc_scene["objects"])
    if "export function cursorClick(" in "".join(script_sources(item))
}
assert gbc_cursor_controllers == {(17, 134, True), (19, 289, False)}

persona_scene, persona, persona_assets = package("3151551777")
assert len(persona) == 18
assert len(persona_assets) == 17
assert sum(not item["startsilent"] for item in persona) == 1
assert any(name.lower().endswith(".ogg") for name in persona_assets)
persona_control = matching_script(persona_scene, "let songNames = [\"Full Moon Full Life.ogg\"")
persona_visible = visible_script_controller(persona_scene, 114, 460)
assert persona_control == persona_visible["script"]
assert persona_visible["value"] is False
assert control_methods(persona_control) == {"isPlaying", "play", "stop"}
assert "export function init()" in persona_control
assert "export function applyUserProperties(" in persona_control
assert "export function cursorClick(" not in persona_control
persona_music = project_properties("3151551777")["music"]
assert (persona_music["type"], persona_music["value"]) == ("combo", "2")
assert [option["value"] for option in persona_music["options"]][-3:] == [
    "16", "random", "17"
]
assert sound_index_names(persona_scene) == {
    115: "Shuffle playlist",
    116: "Full Moon Full Life.ogg",
    117: "Color Your Night.ogg",
    118: "Changing Seasons -Reload-.ogg",
    119: "Joy.ogg",
    120: "Memories of you Kimi no Kioku -Reload-.ogg",
    121: "Want To Be Close -Reload-.ogg",
    122: "When The Moon's Reaching Out Stars -Reload-.ogg",
    123: "Peace -Reload-.ogg",
    124: "Iwatodai Dorm -Reload-.ogg",
    125: "I Will Protect You -Reload-.ogg",
    126: "Memories of the School.ogg",
    127: "It's Going Down Now.ogg",
    128: "Disconnected.ogg",
    129: "Brand New Days -The Beginning-.ogg",
    130: "Brand New Days -Reload-.ogg",
    131: "Don't.ogg",
    132: "zapsplat_vehicles_train_metro_interior_ride_few_people_distant_chat_sydney_australia_32726.mp3",
}
assert 'changedUserProperties.music === "random"' in persona_control
assert "+changedUserProperties.music - 1" in persona_control
assert "+changedUserProperties.music !== 0" in persona_control

lifecycle_acceptance = {
    "3460973721": {
        "initial": "1",
        "stop": "0",
        "deterministic": {
            "1": (14, "Storyteller(叙事者)"),
            "2": (15, "Echoism (Instrumental).flac"),
        },
        "excluded": {"4"},
    },
    "3151551777": {
        "initial": "2",
        "stop": "0",
        "deterministic": {
            "1": (116, "Full Moon Full Life.ogg"),
            "2": (117, "Color Your Night.ogg"),
        },
        "excluded": {"random"},
    },
}
for item_id, expectation in lifecycle_acceptance.items():
    properties = project_properties(item_id)
    values = {option["value"] for option in properties["music"]["options"]}
    assert expectation["initial"] == properties["music"]["value"]
    assert expectation["stop"] in values
    assert set(expectation["deterministic"]) <= values
    assert expectation["excluded"] <= values

assert len(next(item for item in arknights if item["playbackmode"] == "random")["sound"]) == 3
persona_playlist = next(item for item in persona if item["name"] == "Shuffle playlist")
assert persona_playlist["playbackmode"] == "loop"
assert len(persona_playlist["sound"]) == 16

volume_corpus = {
    "1845706469": (nier_scene, nier),
    "3151551777": (persona_scene, persona),
    "3448290956": (gbc_scene, gbc),
    "3460973721": (arknights_scene, arknights),
}
for item_id in (
    "3299228616",
    "3326873240",
    "3354366708",
    "3479521040",
    "3509243656",
):
    scene, sounds, _ = package(item_id, include_audio=False)
    volume_corpus[item_id] = (scene, sounds)

all_sounds = [
    sound
    for _, sounds in volume_corpus.values()
    for sound in sounds
]
assert len(all_sounds) == 30
assert sum(
    isinstance(sound.get("volume"), dict) and "user" in sound["volume"]
    for sound in all_sounds
) == 22
assert not any(
    isinstance(sound.get("volume"), dict) and "script" in sound["volume"]
    for sound in all_sounds
)
assert not any(
    re.search(r"\.\s*volume\s*=", source)
    for scene, _ in volume_corpus.values()
    for source in script_sources(scene)
)

selected = {
    next(iter(nier_assets)): next(iter(nier_assets.values())),
    **arknights_assets,
    **gbc_assets,
    next(name for name in persona_assets if name.lower().endswith(".ogg")): next(
        data for name, data in persona_assets.items() if name.lower().endswith(".ogg")
    ),
}
with tempfile.TemporaryDirectory(prefix="fresco-scene-sound-") as directory:
    paths = []
    for index, (name, data) in enumerate(selected.items()):
        path = pathlib.Path(directory) / f"{index}{pathlib.Path(name).suffix}"
        path.write_bytes(data)
        paths.append(path)
    subprocess.run([PROBE, *paths], check=True, timeout=20)

print(
    "sound corpus: authored controls pinned; 30 layers, "
    "22 user-volume bindings; MP3, FLAC, and Ogg decode"
)
