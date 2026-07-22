#!/usr/bin/env python3

import json
import os
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
PROJECT = os.path.join(WORKSHOP, "3326873240")
RECOVERY_PROJECT = PROJECT
ASSIGNMENT = "scene-script-graph-construction-unwind"


def message(request_type, path=PROJECT):
    return {
        "protocolVersion": 1,
        "type": request_type,
        "assignmentID": ASSIGNMENT,
        "path": path,
        "assetRoot": ASSETS,
        "width": 320,
        "height": 180,
        "visible": False,
        "muted": True,
        "evidenceFrames": 2,
    }


failure_environment = os.environ.copy()
failure_environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
failure_environment["FRESCO_SCENE_TEST_FAIL_DURING_SCRIPT_GRAPH_CONSTRUCTION_ONCE"] = "1"
failure_result = subprocess.run(
    [HELPER],
    input=json.dumps(message("load")) + "\n",
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=120,
    check=True,
    env=failure_environment,
)
failure_events = [json.loads(line) for line in failure_result.stdout.splitlines()]
assert [event["type"] for event in failure_events] == ["fatal"], (
    failure_events,
    failure_result.stderr,
)
failed = failure_events[0]
assert failed["assignmentID"] == ASSIGNMENT, failed
assert failed["code"] == "renderer-load-failed", failed
assert failed["scope"] == "process", failed
assert failed["message"] == (
    "injected failure during SceneScript graph construction"
), failed
assert not failure_result.stderr, failure_result.stderr

recovery_environment = os.environ.copy()
recovery_environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
recovery_environment.pop(
    "FRESCO_SCENE_TEST_FAIL_DURING_SCRIPT_GRAPH_CONSTRUCTION_ONCE", None
)
recovery_result = subprocess.run(
    [HELPER],
    input="".join(
        json.dumps(command) + "\n"
        for command in (message("load", RECOVERY_PROJECT), message("stop"))
    ),
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=120,
    check=True,
    env=recovery_environment,
)
recovery_events = [json.loads(line) for line in recovery_result.stdout.splitlines()]
assert [event["type"] for event in recovery_events] == ["ready", "stopped"], (
    recovery_events,
    recovery_result.stderr,
)
recovered, stopped = recovery_events
assert recovered["assignmentID"] == ASSIGNMENT, recovered
assert recovered["backend"] == EXPECTED_BACKEND, recovered
assert recovered["drawComplete"] is True, recovered
assert recovered["scriptErrors"] == 0, recovered
assert recovered["genericPropertyScriptErrors"] == 0, recovered
assert stopped["assignmentID"] == ASSIGNMENT, stopped
assert not recovery_result.stderr, recovery_result.stderr

print(
    f"SceneScript graph construction unwind: {EXPECTED_BACKEND} "
    "process-fatal cleanup and fresh-helper recovery passed"
)
