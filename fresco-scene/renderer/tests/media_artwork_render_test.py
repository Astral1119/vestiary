#!/usr/bin/env python3

import base64
import binascii
import json
import os
import select
import struct
import subprocess
import sys
import zlib


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
HYUGA = os.path.join(WORKSHOP, "3479521040")


def png(red, green, blue):
    def chunk(kind, payload):
        contents = kind + payload
        return struct.pack(">I", len(payload)) + contents + struct.pack(
            ">I", binascii.crc32(contents) & 0xFFFFFFFF
        )

    data = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes((0, red, green, blue, 255))))
        + chunk(b"IEND", b"")
    )
    return "data:image/png;base64," + base64.b64encode(data).decode("ascii")


def message(command_type, **values):
    return {
        "protocolVersion": 1,
        "type": command_type,
        "assignmentID": "media-artwork-render",
        **values,
    }


process = subprocess.Popen(
    [HELPER],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)


def exchange(command_type, expected=None, **values):
    process.stdin.write(json.dumps(message(command_type, **values)) + "\n")
    process.stdin.flush()
    readable, _, _ = select.select([process.stdout], [], [], 90)
    assert readable, (command_type, "timed out")
    event = json.loads(process.stdout.readline())
    assert event["type"] == (expected or command_type), event
    return event


def load():
    ready = exchange(
        "load",
        "ready",
        path=HYUGA,
        assetRoot=ASSETS,
        width=320,
        height=180,
        visible=True,
        evidenceFrames=2,
    )
    assert ready["drawComplete"] is True, ready
    assert ready["backend"] == EXPECTED_BACKEND, ready


def artwork(uri):
    return exchange(
        "media-session",
        "media-session-applied",
        kind="thumbnail",
        payload={
            "thumbnail": uri,
            "primaryColor": "#ff0000",
            "secondaryColor": "#00ff00",
            "tertiaryColor": "#0000ff",
            "textColor": "#ffffff",
            "highContrastColor": "#000000",
        },
    )


red = png(255, 0, 0)
blue = png(0, 0, 255)

load()
first = artwork(red)
assert first["artworkReady"] is True, first
assert first["artworkRevision"] == 1, first
assert first["artworkError"] == "none", first
first_difference = exchange("capture-frame-difference", "frame-difference")
assert first_difference["changedPixels"] > 0, first_difference

second = artwork(blue)
assert second["artworkReady"] is True, second
assert second["artworkRevision"] == 2, second
second_difference = exchange("capture-frame-difference", "frame-difference")
assert second_difference["changedPixels"] > 0, second_difference
assert second_difference["backend"] == EXPECTED_BACKEND, second_difference

rejected = artwork("data:image/png;base64,rejected-artwork")
assert rejected["artworkReady"] is True, rejected
assert rejected["artworkRevision"] == 2, rejected
assert rejected["artworkError"] == "invalid-base64", rejected
assert rejected["artworkRGBAHash"] == second["artworkRGBAHash"], (second, rejected)
rejected_difference = exchange("capture-frame-difference", "frame-difference")
assert rejected_difference["backend"] == EXPECTED_BACKEND, rejected_difference
assert rejected_difference["drawComplete"] is True, rejected_difference

cleared = exchange(
    "media-session",
    "media-session-applied",
    kind="thumbnail",
    payload={"thumbnail": ""},
)
assert cleared["artworkReady"] is False, cleared
assert cleared["artworkRevision"] == 3, cleared
clear_difference = exchange("capture-frame-difference", "frame-difference")
assert clear_difference["changedPixels"] > 0, clear_difference

# A renderer replacement starts with empty textures. Replaying the retained event
# deterministically reconstructs current artwork with a fresh local revision.
load()
replayed = artwork(blue)
assert replayed["artworkReady"] is True, replayed
assert replayed["artworkRevision"] == 1, replayed
replay_difference = exchange("capture-frame-difference", "frame-difference")
assert replay_difference["changedPixels"] > 0, replay_difference

exchange("stop", "stopped")
process.stdin.close()
process.wait(timeout=10)
assert not process.stderr.read()

print("media artwork render: current, previous, clear, and reload replay passed")
