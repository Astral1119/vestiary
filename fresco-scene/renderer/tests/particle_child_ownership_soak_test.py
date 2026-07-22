#!/usr/bin/env python3

import json
import os
import select
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "particle-child-ownership-soak"
CYCLES = 12


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
    return event


def resident_kib():
    output = subprocess.check_output(
        ["ps", "-o", "rss=", "-p", str(process.pid)], text=True
    )
    return int(output.strip())


try:
    live_signatures = []
    allocation_samples = []
    resident_samples = []
    for _ in range(CYCLES):
        ready = exchange(
            "load",
            "ready",
            path=os.path.join(WORKSHOP, "3479521040"),
            assetRoot=ASSETS,
            width=320,
            height=180,
            visible=True,
            muted=True,
            evidenceFrames=360,
        )
        assert ready["backend"] == EXPECTED_BACKEND, ready
        metrics = exchange("metrics")
        assert metrics["renderDurationSamplesMilliseconds"] == [], metrics
        allocations = metrics["renderAllocations"]
        signature = {}
        for name, counts in allocations.items():
            assert counts["allocations"] - counts["deallocations"] == counts["live"], (
                name,
                counts,
            )
            signature[name] = counts["live"]
        live_signatures.append(signature)
        allocation_samples.append(allocations)
        resident_samples.append(resident_kib())

    assert all(value == live_signatures[0] for value in live_signatures), live_signatures
    for name in (
        "shaders",
        "shaderVariables",
        "passAttributes",
        "passUniforms",
        "copiedUniformValues",
    ):
        assert allocation_samples[-1][name]["allocations"] > allocation_samples[0][name]["allocations"], (
            name,
            allocation_samples,
        )
        assert allocation_samples[-1][name]["deallocations"] > allocation_samples[0][name]["deallocations"], (
            name,
            allocation_samples,
        )
    warmed = resident_samples[2:]
    assert max(warmed) - min(warmed) <= 64 * 1024, resident_samples

    exchange("stop", "stopped")
    process.stdin.close()
    process.wait(timeout=10)
    assert process.returncode == 0, process.returncode
    assert not process.stderr.read(), process.stderr.read()
finally:
    if process.poll() is None:
        process.kill()
        process.wait(timeout=10)

print(
    f"particle child ownership soak: {EXPECTED_BACKEND} {CYCLES} cycles, "
    f"allocations={json.dumps(allocation_samples[-1], separators=(',', ':'))}, "
    f"warmedResidentKiB={min(warmed)}..{max(warmed)} passed"
)
