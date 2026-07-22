#!/usr/bin/env python3

import json
import os
import subprocess
import sys

HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ARTWORK = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY"
    "42YAAAAASUVORK5CYII="
)


def run_fixture(item_id, assignment):
    def message(message_type, **values):
        return {
            "protocolVersion": 1, "type": message_type,
            "assignmentID": assignment, **values,
        }

    load = message(
        "load", path=os.path.join(WORKSHOP, item_id), assetRoot=ASSETS,
        width=320, height=180, visible=True, evidenceFrames=2,
    )
    commands = [
        load,
        message(
            "media-session", kind="thumbnail",
            payload={
                "thumbnail": f"data:image/png;base64,{ARTWORK}",
                "primaryColor": "#112233",
            },
        ),
        message("capture-frame-difference"),
        message("pause"),
        message("metrics"),
        message("resume"),
        message("capture-frame-difference"),
        load,
        message("metrics"),
        message("stop"),
    ]
    result = subprocess.run(
        [HELPER], input="".join(json.dumps(command) + "\n" for command in commands),
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=60, check=True,
    )
    assert not result.stderr, result.stderr
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert [event["type"] for event in events] == [
        "ready", "media-session-applied", "frame-difference", "paused",
        "metrics", "resumed", "frame-difference", "ready", "metrics", "stopped",
    ], events
    ready, thumbnail, advanced, _, paused, _, resumed, reloaded, reloaded_metrics, _ = events
    assert thumbnail["kind"] == "thumbnail", thumbnail
    assert thumbnail["hasThumbnail"] is True, thumbnail
    for event in (ready, advanced, paused, resumed, reloaded, reloaded_metrics):
        assert event["backend"] == EXPECTED_BACKEND, event
        assert event["genericPropertyScriptErrors"] == 0, event
        assert event["scriptErrors"] == 0, event
    assert paused["paused"] is True, paused
    assert paused["genericPropertyScriptUpdates"] == advanced["genericPropertyScriptUpdates"], paused
    assert paused["genericPropertyScriptChanges"] == advanced["genericPropertyScriptChanges"], paused
    assert reloaded["genericPropertyScriptUpdates"] == ready["genericPropertyScriptUpdates"], reloaded
    assert reloaded["genericPropertyScriptChanges"] == ready["genericPropertyScriptChanges"], reloaded
    assert reloaded_metrics["genericPropertyScriptUpdates"] == ready["genericPropertyScriptUpdates"], reloaded_metrics
    assert reloaded_metrics["genericPropertyScriptChanges"] == ready["genericPropertyScriptChanges"], reloaded_metrics
    return ready, advanced, resumed


hyuga_ready, hyuga_advanced, hyuga_resumed = run_fixture("3479521040", "hyuga-thumbnail-animation")
assert hyuga_ready["genericPropertyScripts"] == 1, hyuga_ready
assert hyuga_ready["deferredScriptValues"] == 0, hyuga_ready
assert hyuga_advanced["genericPropertyScriptUpdates"] == hyuga_ready["genericPropertyScriptUpdates"] + 1, hyuga_advanced
assert hyuga_advanced["genericPropertyScriptChanges"] == hyuga_ready["genericPropertyScriptChanges"] + 1, hyuga_advanced
assert hyuga_resumed["genericPropertyScriptUpdates"] == hyuga_advanced["genericPropertyScriptUpdates"] + 1, hyuga_resumed
assert hyuga_resumed["genericPropertyScriptChanges"] == hyuga_advanced["genericPropertyScriptChanges"] + 1, hyuga_resumed

persona_ready, persona_advanced, persona_resumed = run_fixture("3151551777", "persona-thumbnail-animation")
assert persona_ready["genericPropertyScripts"] == 137, persona_ready
assert persona_ready["deferredScriptValues"] == 0, persona_ready
assert persona_ready["warnings"] == [], persona_ready
assert persona_advanced["genericPropertyScriptUpdates"] == (
    persona_ready["genericPropertyScriptUpdates"] + 122
), persona_advanced
assert persona_advanced["mediaThumbnailScriptDispatches"] == 38, persona_advanced
assert persona_advanced["genericPropertyScriptChanges"] > (
    persona_ready["genericPropertyScriptChanges"]
), persona_advanced
assert persona_resumed["genericPropertyScriptUpdates"] == (
    persona_advanced["genericPropertyScriptUpdates"] + 122
), persona_resumed
assert persona_resumed["genericPropertyScriptChanges"] >= (
    persona_advanced["genericPropertyScriptChanges"]
), persona_resumed

print(f"media-thumbnail authored animations passed: {EXPECTED_BACKEND} Hyuga=1 Persona-image=3 Persona-text=28")
