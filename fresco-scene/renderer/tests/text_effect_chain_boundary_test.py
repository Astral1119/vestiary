#!/usr/bin/env python3

import copy
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = pathlib.Path(os.path.abspath(sys.argv[2]))
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
PERSONA = WORKSHOP / "3151551777"
TARGET_OBJECT_ID = 220
UNSUPPORTED_SOURCE_ID = 765
UNSUPPORTED_EFFECT_ID = 990001


def read_u32(handle):
    return struct.unpack("<I", handle.read(4))[0]


def read_string(handle):
    return handle.read(read_u32(handle)).decode("utf-8")


def encode_string(value):
    encoded = value.encode("utf-8")
    return struct.pack("<I", len(encoded)) + encoded


def read_package(path):
    with path.open("rb") as handle:
        revision = read_string(handle)
        entries = [
            (read_string(handle), read_u32(handle), read_u32(handle))
            for _ in range(read_u32(handle))
        ]
        payload_base = handle.tell()
        payloads = []
        for name, offset, length in entries:
            handle.seek(payload_base + offset)
            payloads.append((name, handle.read(length)))
    return revision, payloads


def write_package(path, revision, payloads):
    offset = 0
    entries = []
    for name, payload in payloads:
        entries.append((name, offset, len(payload)))
        offset += len(payload)
    with path.open("wb") as handle:
        handle.write(encode_string(revision))
        handle.write(struct.pack("<I", len(entries)))
        for name, entry_offset, length in entries:
            handle.write(encode_string(name))
            handle.write(struct.pack("<II", entry_offset, length))
        for _, payload in payloads:
            handle.write(payload)


def isolated_scene(scene):
    target = copy.deepcopy(
        next(item for item in scene["objects"] if item.get("id") == TARGET_OBJECT_ID)
    )
    unsupported = copy.deepcopy(
        next(
            item for item in scene["objects"]
            if item.get("id") == UNSUPPORTED_SOURCE_ID
        )["effects"][0]
    )

    target.pop("parent", None)
    target["alpha"] = 1.0
    target["color"] = "1.00000 1.00000 1.00000"
    target["horizontalalign"] = "center"
    target["origin"] = "1920.00000 1080.00000 0.00000"
    target["pointsize"] = 128.0
    target["size"] = "1600.00000 400.00000"
    target["text"] = "Fresco text effect chain boundary"
    target["visible"] = True

    supported = copy.deepcopy(target["effects"])
    supported[0]["passes"][0]["constantshadervalues"] = {"scale": "2 2"}
    supported[0]["passes"][1]["constantshadervalues"] = {"scale": "2 2"}
    supported[1]["passes"][0]["constantshadervalues"] = {"alpha": 0.45}
    supported[2]["passes"][0]["constantshadervalues"] = {
        "angle": 0,
        "offset": "180 0",
        "scale": "0.75 0.75",
    }
    for effect in supported:
        effect["visible"] = True

    unsupported["id"] = UNSUPPORTED_EFFECT_ID
    unsupported["name"] = "Unsupported active perspective boundary"
    unsupported["passes"][0]["id"] = 990002
    unsupported["visible"] = True

    isolated = copy.deepcopy(scene)
    isolated["objects"] = [target]
    return isolated, supported, unsupported


def variant_payloads(payloads, effects, final_target=False):
    scene_name, scene_payload = next(
        (name, payload) for name, payload in payloads if name == "scene.json"
    )
    scene = json.loads(scene_payload)
    isolated, _, _ = isolated_scene(scene)
    isolated["objects"][0]["effects"] = effects
    replacement = json.dumps(isolated, separators=(",", ":")).encode("utf-8")
    result = [
        (name, replacement if name == scene_name else payload)
        for name, payload in payloads
    ]
    if final_target:
        effect_name = effects[-1]["file"]
        effect_payload = next(payload for name, payload in result if name == effect_name)
        definition = json.loads(effect_payload)
        assert definition["fbos"], definition
        definition["passes"][-1]["target"] = definition["fbos"][0]["name"]
        replacement = json.dumps(definition, separators=(",", ":")).encode("utf-8")
        result = [
            (name, replacement if name == effect_name else payload)
            for name, payload in result
        ]
    return result


def message(assignment, project):
    return {
        "protocolVersion": 1,
        "type": "load",
        "assignmentID": assignment,
        "path": str(project),
        "assetRoot": ASSETS,
        "width": 320,
        "height": 180,
        "visible": False,
        "muted": True,
        "evidenceFrames": 3,
    }


def run_case(name, project):
    assignment = f"text-effect-chain-{name}"
    load = message(assignment, project)
    commands = [
        load,
        load,
        {
            "protocolVersion": 1,
            "type": "metrics",
            "assignmentID": assignment,
        },
        {
            "protocolVersion": 1,
            "type": "capture-frame-difference",
            "assignmentID": assignment,
        },
        {
            "protocolVersion": 1,
            "type": "stop",
            "assignmentID": assignment,
        },
    ]
    result = subprocess.run(
        [HELPER],
        input="".join(json.dumps(command) + "\n" for command in commands),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=90,
        check=True,
    )
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert [event["type"] for event in events] == [
        "ready", "ready", "metrics", "frame-difference", "stopped"
    ], (name, events, result.stderr)
    ready, reloaded, metrics, frame, stopped = events
    assert stopped["assignmentID"] == assignment, stopped
    for event in (ready, reloaded, metrics, frame):
        assert event["assignmentID"] == assignment, event
        assert event["backend"] == EXPECTED_BACKEND, event
        assert event["scriptErrors"] == 0, event
    for event in (ready, reloaded, frame):
        assert event["drawComplete"] is True, event
    assert reloaded["pixelRGBTotal"] == ready["pixelRGBTotal"], (name, events)
    assert reloaded["pixelRGBAHash"] == ready["pixelRGBAHash"], (name, events)
    assert frame["pixelRGBTotal"] == reloaded["pixelRGBTotal"], (name, events)
    assert frame["pixelRGBAHash"] == reloaded["pixelRGBAHash"], (name, events)
    assert metrics["textEffectChains"] == reloaded["textEffectChains"], (name, events)
    assert frame["textEffectChains"] == reloaded["textEffectChains"], (name, events)
    return {
        "pixelRGBTotal": reloaded["pixelRGBTotal"],
        "pixelRGBAHash": reloaded["pixelRGBAHash"],
        "textEffectChains": reloaded["textEffectChains"],
    }


def signature(result):
    return result["pixelRGBTotal"], result["pixelRGBAHash"]


if not (PERSONA / "scene.pkg").is_file():
    raise SystemExit(f"text effect boundary fixture missing: {PERSONA}")

revision, payloads = read_package(PERSONA / "scene.pkg")
scene = json.loads(next(payload for name, payload in payloads if name == "scene.json"))
_, supported, unsupported = isolated_scene(scene)

cases = {
    "direct": ([], False),
    "supported": (supported, False),
    "all-inactive": ([{**effect, "visible": False} for effect in supported], False),
    "final-target": (supported[:1], True),
    "inactive-unsupported": (
        supported[:1] + [{**unsupported, "visible": False}] + supported[1:], False
    ),
    "active-before": ([unsupported] + supported, False),
    "active-between": (supported[:1] + [unsupported] + supported[1:], False),
    "active-after": (supported + [unsupported], False),
}

with tempfile.TemporaryDirectory(prefix="fresco-text-effect-chain-") as directory:
    root = pathlib.Path(directory)
    results = {}
    for name, (effects, final_target) in cases.items():
        project = root / name
        project.mkdir()
        shutil.copy2(PERSONA / "project.json", project / "project.json")
        write_package(
            project / "scene.pkg",
            revision,
            variant_payloads(payloads, effects, final_target),
        )
        results[name] = run_case(name, project)

direct = signature(results["direct"])
supported_only = signature(results["supported"])
assert supported_only != direct, results
assert results["direct"]["textEffectChains"] == [], results
supported_chain = results["supported"]["textEffectChains"]
assert len(supported_chain) == 1, results
assert supported_chain[0]["mode"] == "composited", supported_chain
assert supported_chain[0]["blockingEffectIDs"] == [], supported_chain
assert supported_chain[0]["firstBlockingEffectID"] is None, supported_chain
assert supported_chain[0]["firstBlockingStage"] == "none", supported_chain
assert signature(results["inactive-unsupported"]) == supported_only, results
inactive_chain = results["inactive-unsupported"]["textEffectChains"]
assert len(inactive_chain) == 1, results
assert inactive_chain[0]["mode"] == "composited", inactive_chain
assert inactive_chain[0]["blockingEffectIDs"] == [], inactive_chain
assert UNSUPPORTED_EFFECT_ID not in inactive_chain[0]["activeEffectIDs"], inactive_chain
assert signature(results["all-inactive"]) == direct, results
all_inactive_chain = results["all-inactive"]["textEffectChains"]
assert len(all_inactive_chain) == 1, all_inactive_chain
assert all_inactive_chain[0]["mode"] == "direct-fallback", all_inactive_chain
assert all_inactive_chain[0]["activeEffectIDs"] == [], all_inactive_chain
assert all_inactive_chain[0]["blockingEffectIDs"] == [], all_inactive_chain
assert all_inactive_chain[0]["firstBlockingEffectID"] is None, all_inactive_chain
assert all_inactive_chain[0]["firstBlockingStage"] == "none", all_inactive_chain
assert all_inactive_chain[0]["reason"] == "text-effect-chain-inactive", all_inactive_chain
assert signature(results["final-target"]) == direct, results
final_target_chain = results["final-target"]["textEffectChains"]
assert len(final_target_chain) == 1, final_target_chain
assert final_target_chain[0]["mode"] == "direct-fallback", final_target_chain
assert final_target_chain[0]["firstBlockingStage"] == "pass", final_target_chain
assert final_target_chain[0]["reason"] == "active-text-effect-pass-unsupported", final_target_chain
for name in ("active-before", "active-between", "active-after"):
    result = results[name]
    assert signature(result) == direct, results
    chains = result["textEffectChains"]
    assert len(chains) == 1, (name, chains)
    assert chains[0]["mode"] == "direct-fallback", (name, chains)
    assert chains[0]["blockingEffectIDs"] == [UNSUPPORTED_EFFECT_ID], (name, chains)
    assert chains[0]["firstBlockingEffectID"] == UNSUPPORTED_EFFECT_ID, (name, chains)
    assert chains[0]["firstBlockingStage"] == "material", (name, chains)
    assert chains[0]["reason"] == (
        "active-text-effect-material-unsupported"
    ), (name, chains)

print(
    f"text effect chain boundary: {EXPECTED_BACKEND} supported={supported_only} "
    f"direct={direct} reload stable and active unsupported chains fall back"
)
