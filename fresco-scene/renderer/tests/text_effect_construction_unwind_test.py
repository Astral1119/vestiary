#!/usr/bin/env python3

import json
import os
import pathlib
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = pathlib.Path(os.path.abspath(sys.argv[2]))
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
PROJECT = WORKSHOP / "3151551777"


def load(assignment):
    return {
        "protocolVersion": 1,
        "type": "load",
        "assignmentID": assignment,
        "path": str(PROJECT),
        "assetRoot": ASSETS,
        "width": 320,
        "height": 180,
        "visible": False,
        "muted": True,
        "evidenceFrames": 3,
    }


if not (PROJECT / "scene.pkg").is_file():
    raise SystemExit(f"text effect unwind fixture missing: {PROJECT}")

failed_assignment = "text-effect-construction-unwind-failed"
recovered_assignment = "text-effect-construction-unwind-recovered"
failure_environment = os.environ.copy()
failure_environment["FRESCO_SCENE_TEST_FAIL_AFTER_TEXT_EFFECT_RENDER_ONCE"] = "1"
failure_result = subprocess.run(
    [HELPER],
    input=json.dumps(load(failed_assignment)) + "\n",
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
failure = failure_events[0]
assert failure["assignmentID"] == failed_assignment, failure
assert failure["code"] == "renderer-load-failed", failure
assert failure["scope"] == "process", failure
assert "injected failure after text effect evidence render" in failure["message"], failure
assert not failure_result.stderr, failure_result.stderr

recovery_commands = [
    load(recovered_assignment),
    {
        "protocolVersion": 1,
        "type": "metrics",
        "assignmentID": recovered_assignment,
    },
    {
        "protocolVersion": 1,
        "type": "stop",
        "assignmentID": recovered_assignment,
    },
]
recovery_environment = os.environ.copy()
recovery_environment.pop("FRESCO_SCENE_TEST_FAIL_AFTER_TEXT_EFFECT_RENDER_ONCE", None)
recovery_result = subprocess.run(
    [HELPER],
    input="".join(json.dumps(command) + "\n" for command in recovery_commands),
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=120,
    check=True,
    env=recovery_environment,
)
events = [json.loads(line) for line in recovery_result.stdout.splitlines()]
assert [event["type"] for event in events] == [
    "ready", "metrics", "stopped"
], (events, recovery_result.stderr)
ready, metrics, stopped = events
assert ready["assignmentID"] == recovered_assignment, ready
assert ready["backend"] == EXPECTED_BACKEND, ready
assert ready["drawComplete"] is True, ready
assert ready["scriptErrors"] == 0, ready
assert ready["textEffectChains"], ready
assert metrics["assignmentID"] == recovered_assignment, metrics
assert metrics["backend"] == EXPECTED_BACKEND, metrics
assert metrics["textEffectChains"] == ready["textEffectChains"], (ready, metrics)
assert stopped["assignmentID"] == recovered_assignment, stopped
assert not recovery_result.stderr, recovery_result.stderr

print(
    f"text effect construction unwind: {EXPECTED_BACKEND} "
    "process-fatal first load cleaned and fresh helper rendered"
)
