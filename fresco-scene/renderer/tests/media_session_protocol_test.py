#!/usr/bin/env python3

import json
import os
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
PROJECT = os.path.join(WORKSHOP, "3351508588")
ARTWORK = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY"
    "42YAAAAASUVORK5CYII="
)


def message(command_type, **values):
    return {
        "protocolVersion": 1,
        "type": command_type,
        "assignmentID": "media-session-protocol",
        **values,
    }


commands = [
    message("hello"),
    message(
        "load",
        path=PROJECT,
        assetRoot=ASSETS,
        width=320,
        height=180,
        visible=False,
    ),
    message("media-session", kind="timeline", payload={"position": "bad"}),
    message("media-session", kind="status", payload={"enabled": True}),
    message(
        "media-session",
        kind="properties",
        payload={
            "title": "Full Moon Full Life",
            "artist": "Azumi Takahashi",
            "albumTitle": "Persona 3 Reload",
        },
    ),
    message("media-session", kind="playback", payload={"state": 1}),
    message(
        "media-session",
        kind="timeline",
        payload={"position": 12.5, "duration": 240.0},
    ),
    message(
        "media-session",
        kind="thumbnail",
        payload={
            "thumbnail": f"data:image/png;base64,{ARTWORK}",
            "primaryColor": "#112233",
            "secondaryColor": "#000000",
            "tertiaryColor": "#445566",
            "textColor": "#ffffff",
            "highContrastColor": "white",
        },
    ),
    message(
        "media-session",
        kind="properties",
        payload={
            "title": "Full Moon Full Life",
            "artist": "Azumi Takahashi",
            "albumTitle": "Persona 3 Reload",
        },
    ),
    message(
        "media-session",
        kind="thumbnail",
        payload={
            "thumbnail": f"data:image/png;base64,{ARTWORK}",
            "primaryColor": "#112233",
            "secondaryColor": "#000000",
            "tertiaryColor": "#445566",
            "textColor": "#ffffff",
            "highContrastColor": "white",
        },
    ),
    message("media-session", kind="thumbnail", payload={"thumbnail": ""}),
    message("media-session", kind="status", payload={"enabled": False}),
    message("stop"),
]

result = subprocess.run(
    [HELPER],
    input="".join(json.dumps(command) + "\n" for command in commands),
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=40,
    check=True,
)
assert not result.stderr, result.stderr
events = [json.loads(line) for line in result.stdout.splitlines()]
assert [event["type"] for event in events] == [
    "hello",
    "ready",
    "warning",
    "media-session-applied",
    "media-session-applied",
    "media-session-applied",
    "media-session-applied",
    "media-session-applied",
    "media-session-applied",
    "media-session-applied",
    "media-session-applied",
    "media-session-applied",
    "stopped",
], events
assert "media-session-v1" in events[0]["capabilities"], events[0]
assert events[2]["code"] == "invalid-media-session", events[2]

applied = events[3:-1]
assert [event["kind"] for event in applied] == [
    "status",
    "properties",
    "playback",
    "timeline",
    "thumbnail",
    "properties",
    "thumbnail",
    "thumbnail",
    "status",
], applied
assert [event["events"] for event in applied] == list(range(1, 10)), applied
assert [event["revision"] for event in applied] == [1, 2, 3, 4, 5, 5, 5, 6, 7], applied
assert applied[2]["playbackState"] == 1, applied[2]
assert applied[4]["hasThumbnail"] is True, applied[4]
assert applied[4]["artworkReady"] is True, applied[4]
assert applied[4]["artworkRevision"] == 1, applied[4]
assert applied[6]["artworkRevision"] == 1, applied[6]
assert applied[7]["artworkReady"] is False, applied[7]
assert applied[7]["artworkRevision"] == 2, applied[7]
assert applied[-1]["available"] is False, applied[-1]
assert applied[-1]["playbackState"] == 0, applied[-1]

print("media session protocol: validation, normalization, revision, and replay payloads passed")
