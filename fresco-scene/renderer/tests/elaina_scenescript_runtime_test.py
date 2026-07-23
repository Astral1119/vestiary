#!/usr/bin/env python3

import base64
import binascii
import json
import os
import select
import struct
import subprocess
import sys
import time
import zlib


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ELAINA = os.path.join(WORKSHOP, "3326873240")
ASSIGNMENT = "elaina-scenescript-runtime"


def png(red, green, blue):
    def chunk(kind, payload):
        contents = kind + payload
        checksum = binascii.crc32(contents) & 0xFFFFFFFF
        return struct.pack(">I", len(payload)) + contents + struct.pack(">I", checksum)

    return "data:image/png;base64," + base64.b64encode(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes((0, red, green, blue, 255))))
        + chunk(b"IEND", b"")
    ).decode("ascii")


ARTWORK = png(255, 0, 0)


def message(request_type, assignment=ASSIGNMENT, **values):
    return {
        "protocolVersion": 1,
        "type": request_type,
        "assignmentID": assignment,
        **values,
    }


def environment():
    result = os.environ.copy()
    result["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    result["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "1"
    result["FRESCO_SCENE_SCRIPT_CLOCK_HOUR"] = "9"
    return result


class Helper:
    def __init__(self, assignment=ASSIGNMENT):
        self.assignment = assignment
        self.process = subprocess.Popen(
            [HELPER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=environment(),
        )

    def exchange(self, request_type, expected=None, timeout=90, **values):
        self.send(request_type, **values)
        readable, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not readable:
            raise AssertionError(
                (request_type, "timed out", self.process.stderr.read())
            )
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError((request_type, self.process.stderr.read()))
        event = json.loads(line)
        assert event["type"] == (expected or request_type), event
        assert event["assignmentID"] == self.assignment, event
        return event

    def send(self, request_type, **values):
        self.process.stdin.write(
            json.dumps(message(request_type, self.assignment, **values)) + "\n"
        )
        self.process.stdin.flush()

    def load(self, *, media_enabled=False, frames=120):
        return self.exchange(
            "load",
            "ready",
            path=ELAINA,
            assetRoot=ASSETS,
            width=320,
            height=180,
            fps=60,
            visible=True,
            muted=True,
            evidenceFrames=frames,
            userProperties={"newproperty67": {"value": media_enabled}},
        )

    def stop(self):
        self.exchange("stop", "stopped")
        self.process.stdin.close()
        self.process.wait(timeout=10)
        assert self.process.returncode == 0, self.process.returncode
        assert not self.process.stderr.read(), self.process.stderr.read()

    def crash(self):
        self.process.kill()
        self.process.wait(timeout=10)
        assert self.process.returncode != 0, self.process.returncode
        assert not self.process.stderr.read(), self.process.stderr.read()


def assert_clean(event):
    assert event["backend"] == EXPECTED_BACKEND, event
    assert event["drawComplete"] is True, event
    assert event["genericPropertyScripts"] == 88, event
    assert event["audioVectorScripts"] == 17, event
    assert event["mediaPropertyScripts"] == 2, event
    assert event["deferredScriptValues"] == 0, event
    assert event["warnings"] == [], event
    for field in (
        "scriptErrors",
        "mediaPropertyScriptErrors",
        "propertyScriptErrors",
        "genericPropertyScriptErrors",
    ):
        assert event[field] == 0, (field, event)


def media(helper, kind, payload):
    return helper.exchange(
        "media-session", "media-session-applied", kind=kind, payload=payload
    )


helper = Helper()
ready = helper.load(media_enabled=False)
assert_clean(ready)

before_inert_click = helper.exchange("metrics")
inert_click = helper.exchange(
    "cursor-click", "cursor-clicked", objectID=398
)
assert inert_click["handled"] is True, inert_click
after_inert_click = helper.exchange("metrics")
assert after_inert_click["genericPropertyScripts"] == 88, after_inert_click
assert after_inert_click["genericPropertyScriptErrors"] == before_inert_click[
    "genericPropertyScriptErrors"
], (before_inert_click, after_inert_click)
assert after_inert_click["scriptErrors"] == before_inert_click["scriptErrors"], (
    before_inert_click,
    after_inert_click,
)

# The authored default keeps the media widget root hidden. Direct project-property
# propagation enables it without changing the private script-property graph.
disabled = helper.exchange("capture-frame-difference", "frame-difference")
applied = helper.exchange(
    "user-properties",
    "user-properties-applied",
    properties={"newproperty67": {"value": True}},
)
assert applied["acceptedScriptProperties"] == 1 and applied["ignored"] == 0, applied
enabled = helper.exchange("capture-frame-difference", "frame-difference")
assert enabled["drawComplete"] is True, (disabled, enabled)

before_audio = helper.exchange("metrics")
spectrum = [0.0] * 128
spectrum[:16] = [index / 15.0 for index in range(16)]
spectrum[64:80] = [index / 15.0 for index in range(16)]
audio_applied = helper.exchange(
    "audio-spectrum", "audio-spectrum-applied", values=spectrum
)
assert audio_applied["changed"] is True, audio_applied
assert audio_applied["inputs"] == 1, audio_applied
audio = helper.exchange("capture-frame-difference", "frame-difference")
assert audio["audioVectorScripts"] == 17, audio
assert audio["audioVectorScriptChanges"] == (
    before_audio["audioVectorScriptChanges"] + 17
), (before_audio, audio)
assert audio["genericPropertyScriptChanges"] >= (
    before_audio["genericPropertyScriptChanges"] + 17
), (before_audio, audio)
assert audio["changedPixels"] > 0, audio

before_media = helper.exchange("metrics")
media(helper, "playback", {"state": 1})
playback = helper.exchange("capture-frame-difference", "frame-difference")
assert playback["genericPropertyScriptChanges"] > before_media[
    "genericPropertyScriptChanges"
], (before_media, playback)
media(helper, "timeline", {"position": 12.5, "duration": 240.0})
timeline = helper.exchange("capture-frame-difference", "frame-difference")
assert timeline["genericPropertyScriptChanges"] > playback[
    "genericPropertyScriptChanges"
], (playback, timeline)
thumbnail = media(
    helper,
    "thumbnail",
    {
        "thumbnail": ARTWORK,
        "primaryColor": "#ff0000",
        "secondaryColor": "#00ff00",
        "tertiaryColor": "#0000ff",
        "textColor": "#ffffff",
        "highContrastColor": "#000000",
    },
)
assert thumbnail["artworkReady"] is True, thumbnail
thumbnail_frame = helper.exchange("capture-frame-difference", "frame-difference")
assert thumbnail_frame["genericPropertyScriptChanges"] > timeline[
    "genericPropertyScriptChanges"
], (timeline, thumbnail_frame)

# Combo value 1 selects the day layer and must leave exactly one script-controlled
# video running. The other four retain their last frame while manually paused.
selection = helper.exchange(
    "user-properties",
    "user-properties-applied",
    properties={
        "timevarying": {"value": False},
        "display": {"value": "1"},
    },
)
assert selection["acceptedScriptProperties"] == 2 and selection["ignored"] == 0
time.sleep(0.25)
video_frame = helper.exchange("capture-frame-difference", "frame-difference")
video = helper.exchange("metrics")["mediaTextures"]
assert video_frame["changedPixels"] > 100, video_frame
assert video["players"] == 5 and video["referencedPlayers"] == 5, video
assert video["scriptControlledPlayers"] == 5, video
assert video["scriptPlayingPlayers"] == 1, video
assert video["scriptPausedPlayers"] == 4, video

before_pause = helper.exchange("metrics")
helper.exchange("pause", "paused")
paused = helper.exchange("metrics")
time.sleep(0.20)
paused_later = helper.exchange("metrics")
assert paused_later["frames"] == paused["frames"], (paused, paused_later)
assert paused_later["genericPropertyScriptUpdates"] == paused[
    "genericPropertyScriptUpdates"
], (paused, paused_later)
helper.exchange("resume", "resumed")
resumed = helper.exchange("capture-frame-difference", "frame-difference")
assert resumed["genericPropertyScriptUpdates"] > before_pause[
    "genericPropertyScriptUpdates"
], (before_pause, resumed)
helper.stop()

first = Helper(f"{ASSIGNMENT}-restart")
assert_clean(first.load(media_enabled=True, frames=2))
media(first, "thumbnail", {"thumbnail": ARTWORK})
first.crash()
second = Helper(f"{ASSIGNMENT}-restart")
assert_clean(second.load(media_enabled=True, frames=2))
replayed = media(second, "thumbnail", {"thumbnail": ARTWORK})
assert replayed["artworkReady"] is True and replayed["artworkRevision"] == 1
assert second.exchange("capture-frame-difference", "frame-difference")[
    "drawComplete"
] is True
second.stop()

print(
    f"Elaina SceneScript runtime: {EXPECTED_BACKEND} 88 modeled non-text scripts "
    "+ 2 media callbacks, "
    "property graph, audio vectors, media hooks, video selection, pause, and restart"
)
