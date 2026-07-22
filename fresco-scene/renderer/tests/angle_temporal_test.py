#!/usr/bin/env python3

import hashlib
import json
import os
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
MANIFEST = os.path.abspath(sys.argv[4])

BASELINES = {
    "3351508588": ("cat-in-space", 120, 0, 0),
    "1568648985": ("shimmering-particles", 120, 0, 0),
    "3402326745": ("balatro", 600, 0, 0),
    "2999232230": ("clock", 120, 6, 1),
}

with open(MANIFEST, encoding="utf-8") as handle:
    fixture_items = json.load(handle)["items"]
EXPECTED_HASHES = {
    item["id"]: item["package"]["sha256"] for item in fixture_items
}


def message(kind, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": "angle-temporal",
        **values,
    }


for workshop_id, baseline in BASELINES.items():
    label, frame_count, expected_script_layers, minimum_script_changes = baseline
    project = os.path.join(WORKSHOP, workshop_id)
    if not os.path.isfile(os.path.join(project, "scene.pkg")):
        raise AssertionError(f"missing pinned fixture {workshop_id}")
    package = os.path.join(project, "scene.pkg")
    actual_hash = hashlib.sha256()
    with open(package, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            actual_hash.update(chunk)
    expected_hash = EXPECTED_HASHES.get(workshop_id)
    if expected_hash is None or actual_hash.hexdigest() != expected_hash:
        raise AssertionError(
            f"fixture {workshop_id} package hash mismatch: "
            f"expected {expected_hash}, found {actual_hash.hexdigest()}"
        )

    commands = [
        message(
            "load",
            path=project,
            assetRoot=ASSETS,
            width=320,
            height=180,
            visible=False,
            evidenceFrames=frame_count,
        ),
        message("stop"),
    ]
    result = subprocess.run(
        [HELPER],
        input="".join(json.dumps(command) + "\n" for command in commands),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60,
        check=True,
    )
    assert not result.stderr, (label, result.stderr)
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert [event["type"] for event in events] == ["ready", "stopped"], events

    ready = events[0]
    assert ready["backend"] == "angle-metal", ready
    assert ready["frames"] == frame_count, ready
    assert ready["range"][0] < ready["range"][1], ready
    assert ready["varyingPixels"] > 0, ready
    assert ready["drawComplete"] is True, ready
    assert ready["scriptLayers"] == expected_script_layers, ready
    assert ready["scriptUpdates"] >= expected_script_layers, ready
    assert ready["scriptTextChanges"] >= minimum_script_changes, ready
    assert ready["scriptErrors"] == 0, ready

print("ANGLE temporal baselines: ok (cat, shimmering, balatro, clock)")
