#!/usr/bin/env python3

import json
import os
import select
import subprocess
import sys
import time


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "session-lifetime-ownership"
PRIMARY_ITEM = "3326873240"
SECONDARY_ITEM = "3151551777"


def message(kind, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": ASSIGNMENT,
        **values,
    }


environment = os.environ.copy()
environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
environment["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "0"
environment["FRESCO_SCENE_TEST_FAIL_AFTER_TEXT_EFFECT_RENDER_ONCE"] = "3"
environment["FRESCO_SCENE_TEST_FAIL_BEFORE_SCENE_CONSTRUCTION_ONCE"] = "2"
process = subprocess.Popen(
    [HELPER],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
    env=environment,
)


def exchange(kind, expected=None, **values):
    process.stdin.write(json.dumps(message(kind, **values)) + "\n")
    process.stdin.flush()
    readable, _, _ = select.select([process.stdout], [], [], 120)
    assert readable, (kind, "timed out", process.stderr.read())
    event = json.loads(process.stdout.readline())
    assert event["type"] == (expected or kind), event
    assert event["assignmentID"] == ASSIGNMENT, event
    return event


def load(item_id, frames=2, expected="ready"):
    return exchange(
        "load",
        expected,
        path=os.path.join(WORKSHOP, item_id),
        assetRoot=ASSETS,
        width=320,
        height=180,
        visible=True,
        muted=True,
        evidenceFrames=frames,
    )


def assert_allocation_balance(metrics):
    assert metrics["renderDurationSamplesMilliseconds"] == [], metrics
    for name, counts in metrics["renderAllocations"].items():
        assert counts["allocations"] - counts["deallocations"] == counts["live"], (
            name,
            counts,
        )


try:
    first = load(PRIMARY_ITEM)
    assert first["backend"] == EXPECTED_BACKEND, first
    first_metrics = exchange("metrics")
    assert_allocation_balance(first_metrics)
    first_media = first_metrics["mediaTextures"]
    assert first_media["players"] == 5, first_media
    assert first_media["referencedPlayers"] == 5, first_media

    failed = load(PRIMARY_ITEM, expected="fatal")
    assert failed["code"] == "renderer-load-failed", failed
    assert failed["scope"] == "assignment", failed
    assert failed["message"] == "injected failure before scene construction", failed

    failed = load(PRIMARY_ITEM, expected="fatal")
    assert failed["code"] == "renderer-load-failed", failed
    assert failed["scope"] == "assignment", failed
    assert failed["message"] == (
        "injected failure after text effect evidence render"
    ), failed

    time.sleep(0.25)
    exchange("metrics")
    replacement = load(PRIMARY_ITEM)
    replacement_metrics = exchange("metrics")
    assert_allocation_balance(replacement_metrics)
    replacement_media = replacement_metrics["mediaTextures"]
    assert replacement_media["players"] == 5, replacement_media
    assert replacement_media["referencedPlayers"] == 5, replacement_media
    assert replacement["resourceGeneration"] == first["resourceGeneration"] + 3, (
        first["resourceGeneration"],
        replacement["resourceGeneration"],
    )
    replacement_pixel_difference = abs(
        replacement["pixelRGBTotal"] - first["pixelRGBTotal"]
    )
    assert replacement_pixel_difference < 10_000, (
        replacement_pixel_difference,
        first["pixelRGBTotal"],
        replacement["pixelRGBTotal"],
    )

    secondary = load(SECONDARY_ITEM)
    assert secondary["backend"] == EXPECTED_BACKEND, secondary
    secondary_metrics = exchange("metrics")
    assert_allocation_balance(secondary_metrics)
    secondary_media = secondary_metrics["mediaTextures"]
    assert secondary_media["players"] == 0, secondary_media
    assert secondary_media["referencedPlayers"] == 0, secondary_media

    exchange("stop", "stopped")
    process.stdin.close()
    process.wait(timeout=10)
    assert process.returncode == 0, process.returncode
    assert not process.stderr.read(), process.stderr.read()
finally:
    if process.poll() is None:
        process.kill()
        process.wait(timeout=10)

clean_commands = (
    message(
        "load",
        path=os.path.join(WORKSHOP, PRIMARY_ITEM),
        assetRoot=ASSETS,
        width=320,
        height=180,
        visible=True,
        muted=True,
        evidenceFrames=2,
    ),
    message("metrics"),
    message("stop"),
)
clean_environment = os.environ.copy()
clean_environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
clean_environment["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "0"
clean = subprocess.run(
    [HELPER],
    input="".join(json.dumps(command) + "\n" for command in clean_commands),
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=120,
    check=True,
    env=clean_environment,
)
assert not clean.stderr, clean.stderr
clean_events = [json.loads(line) for line in clean.stdout.splitlines()]
assert [event["type"] for event in clean_events] == ["ready", "metrics", "stopped"], clean_events
clean_metrics = clean_events[1]
assert_allocation_balance(clean_metrics)
failed_then_recovered_live = {
    name: counts["live"]
    for name, counts in first_metrics["renderAllocations"].items()
}
clean_live = {
    name: counts["live"]
    for name, counts in clean_metrics["renderAllocations"].items()
}
assert failed_then_recovered_live == clean_live, (
    failed_then_recovered_live,
    clean_live,
)

print(
    f"session lifetime ownership: {EXPECTED_BACKEND} unwind, media 5→5→0, "
    "and time-sensitive replacement parity passed"
)
