#!/usr/bin/env python3

import json
import os
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
PERSONA = os.path.join(WORKSHOP, "3151551777")
ARTWORK = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY"
    "42YAAAAASUVORK5CYII="
)


def message(message_type, assignment, **values):
    return {
        "protocolVersion": 1,
        "type": message_type,
        "assignmentID": assignment,
        **values,
    }


def run(alignment, disabled):
    assignment = f"persona-text-effects-{alignment}-{'off' if disabled else 'on'}"
    load = message(
        "load",
        assignment,
        path=PERSONA,
        assetRoot=ASSETS,
        width=320,
        height=180,
        visible=False,
        evidenceFrames=3,
        userProperties={"mediaintegration": {"value": alignment}},
    )
    commands = [
        load,
        message(
            "media-session",
            assignment,
            kind="properties",
            payload={
                "title": "Fresco Effect Evidence",
                "artist": "Fresco Artist",
                "albumTitle": "Fresco Album",
            },
        ),
        message(
            "media-session",
            assignment,
            kind="thumbnail",
            payload={"thumbnail": f"data:image/png;base64,{ARTWORK}"},
        ),
        message("capture-frame-difference", assignment),
        message("metrics", assignment),
        load,
        message("metrics", assignment),
        message("stop", assignment),
    ]
    environment = os.environ.copy()
    if disabled:
        environment["FRESCO_SCENE_TEXT_EFFECTS_DISABLED"] = "1"
    else:
        environment.pop("FRESCO_SCENE_TEXT_EFFECTS_DISABLED", None)
    result = subprocess.run(
        [HELPER],
        input="".join(json.dumps(command) + "\n" for command in commands),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=90,
        check=True,
        env=environment,
    )
    assert not result.stderr, result.stderr
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert [event["type"] for event in events] == [
        "ready",
        "media-session-applied",
        "media-session-applied",
        "frame-difference",
        "metrics",
        "ready",
        "metrics",
        "stopped",
    ], events
    ready, properties, thumbnail, difference, metrics, reloaded, reloaded_metrics, _ = events
    assert properties["kind"] == "properties", properties
    assert thumbnail["kind"] == "thumbnail" and thumbnail["hasThumbnail"] is True, thumbnail
    for event in (ready, difference, metrics, reloaded, reloaded_metrics):
        assert event["backend"] == EXPECTED_BACKEND, event
        assert event["genericPropertyScripts"] == 137, event
        assert event["genericPropertyScriptErrors"] == 0, event
        assert event["scriptErrors"] == 0, event
    for event in (ready, reloaded):
        assert event["deferredScriptValues"] == 0, event
    assert ready["initialUserProperties"]["acceptedScriptProperties"] == 1, ready
    assert ready["initialUserProperties"]["ignored"] == 0, ready
    assert reloaded["genericPropertyScriptUpdates"] == ready["genericPropertyScriptUpdates"], reloaded
    assert reloaded["genericPropertyScriptChanges"] == ready["genericPropertyScriptChanges"], reloaded
    assert reloaded_metrics["genericPropertyScriptUpdates"] == ready["genericPropertyScriptUpdates"], reloaded_metrics
    assert reloaded_metrics["genericPropertyScriptChanges"] == ready["genericPropertyScriptChanges"], reloaded_metrics
    if not disabled:
        assert ready["textEffectChains"], ready
        assert reloaded["textEffectChains"] == ready["textEffectChains"], reloaded
        assert reloaded_metrics["textEffectChains"] == reloaded["textEffectChains"], reloaded_metrics
    return difference


signatures = []
for alignment in ("1", "2"):
    enabled = run(alignment, False)
    disabled = run(alignment, True)
    assert enabled["pixelRGBTotal"] != disabled["pixelRGBTotal"], (alignment, enabled, disabled)
    assert enabled["pixelRGBAHash"] != disabled["pixelRGBAHash"], (alignment, enabled, disabled)
    signatures.append(
        f"{alignment}:on={enabled['pixelRGBTotal']}/{enabled['pixelRGBAHash']}"
        f",off={disabled['pixelRGBTotal']}/{disabled['pixelRGBAHash']}"
    )

print(
    f"Text effect rendering passed: {EXPECTED_BACKEND} Persona opacity/transform/blurprecise "
    f"alignments=right,left callbacks=28 signatures={';'.join(signatures)}"
)
