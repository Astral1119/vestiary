#!/usr/bin/env python3

import json
import os
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]


def message(message_type, assignment_id, **values):
    return {
        "protocolVersion": 1,
        "type": message_type,
        "assignmentID": assignment_id,
        **values,
    }


def verify(project_id, assignment_id, handlers):
    project = os.path.join(WORKSHOP, project_id)
    assert os.path.isfile(os.path.join(project, "scene.pkg")), project
    properties = message("media-session", assignment_id)
    properties.update(
        {
            "kind": "properties",
            "payload": {
                "title": "Fresco Song",
                "artist": "Fresco Artist",
                "albumTitle": "Fresco Album",
            },
        }
    )
    commands = [
        message(
            "load",
            assignment_id,
            path=project,
            assetRoot=ASSETS,
            width=320,
            height=180,
            visible=True,
            evidenceFrames=2,
        ),
        properties,
        message("capture-frame-difference", assignment_id),
        message("metrics", assignment_id),
        message("stop", assignment_id),
    ]
    result = subprocess.run(
        [HELPER],
        input="".join(json.dumps(command) + "\n" for command in commands),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
        check=True,
    )
    assert not result.stderr, result.stderr
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert [event["type"] for event in events] == [
        "ready",
        "media-session-applied",
        "frame-difference",
        "metrics",
        "stopped",
    ], events
    ready, applied, frame, metrics, _ = events
    assert ready["backend"] == EXPECTED_BACKEND, ready
    assert ready["mediaPropertyScripts"] == handlers, ready
    assert ready["mediaPropertyScriptDispatches"] == 0, ready
    assert ready["mediaPropertyScriptErrors"] == 0, ready
    assert applied["kind"] == "properties", applied
    assert frame["mediaPropertyScripts"] == handlers, frame
    assert frame["backend"] == EXPECTED_BACKEND, frame
    assert frame["mediaPropertyScriptDispatches"] == handlers, frame
    assert frame["mediaPropertyScriptErrors"] == 0, frame
    assert frame["scriptTextChanges"] > ready["scriptTextChanges"], frame
    assert metrics["mediaPropertyScripts"] == handlers, metrics
    assert metrics["backend"] == EXPECTED_BACKEND, metrics
    assert metrics["mediaPropertyScriptDispatches"] == handlers, metrics
    assert metrics["mediaPropertyScriptErrors"] == 0, metrics
    assert metrics["scriptErrors"] == 0, metrics


verify("3479521040", "hyuga-media-text", 1)
verify("3151551777", "persona-media-text", 12)
print("SceneScript media-property text checks passed: Hyuga=1 Persona=12")
