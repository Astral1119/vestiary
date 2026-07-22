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
PROJECT = os.path.join(WORKSHOP, "3326873240")

MEDIA_COUNTERS = {
    "mediaPropertyScriptDispatches": 2,
    "mediaPlaybackScriptDispatches": 7,
    "mediaTimelineScriptDispatches": 1,
    "mediaThumbnailScriptDispatches": 6,
}


def png(red, green, blue):
    def chunk(kind, payload):
        contents = kind + payload
        checksum = binascii.crc32(contents) & 0xFFFFFFFF
        return struct.pack(">I", len(payload)) + contents + struct.pack(">I", checksum)

    data = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes((0, red, green, blue, 255))))
        + chunk(b"IEND", b"")
    )
    return "data:image/png;base64," + base64.b64encode(data).decode("ascii")


RED_THUMBNAIL = {
    "thumbnail": png(255, 0, 0),
    "primaryColor": "#ff0000",
    "secondaryColor": "#00ff00",
    "tertiaryColor": "#0000ff",
    "textColor": "#ffffff",
    "highContrastColor": "#000000",
}
BLUE_THUMBNAIL = {
    "thumbnail": png(0, 0, 255),
    "primaryColor": "#0000ff",
    "secondaryColor": "#ff0000",
    "tertiaryColor": "#00ff00",
    "textColor": "#000000",
    "highContrastColor": "#ffffff",
}


def environment():
    result = os.environ.copy()
    result["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    result["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "1"
    result["FRESCO_SCENE_SCRIPT_CLOCK_HOUR"] = "9"
    return result


def message(request_type, assignment, **values):
    return {
        "protocolVersion": 1,
        "type": request_type,
        "assignmentID": assignment,
        **values,
    }


class Helper:
    def __init__(self, assignment):
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
        self.process.stdin.write(
            json.dumps(message(request_type, self.assignment, **values)) + "\n"
        )
        self.process.stdin.flush()
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

    def load(
        self, *, frames=120, visible=True, display="1", fps=60,
        extra_properties=None
    ):
        properties = {
            "newproperty67": {"value": True},
            "timevarying": {"value": False},
            "display": {"value": display},
        }
        properties.update(extra_properties or {})
        return self.exchange(
            "load",
            "ready",
            path=PROJECT,
            assetRoot=ASSETS,
            width=320,
            height=180,
            fps=fps,
            visible=visible,
            muted=True,
            evidenceFrames=frames,
            userProperties=properties,
        )

    def stop(self):
        self.exchange("stop", "stopped")
        self.process.stdin.close()
        self.process.wait(timeout=10)
        stderr = self.process.stderr.read()
        assert self.process.returncode == 0, self.process.returncode
        assert not stderr, stderr

    def crash(self):
        self.process.kill()
        self.process.wait(timeout=10)
        assert self.process.returncode != 0, self.process.returncode
        assert not self.process.stderr.read(), self.process.stderr.read()


def require_media_counters(event):
    missing = sorted(set(MEDIA_COUNTERS) - set(event))
    if missing:
        raise AssertionError(
            "metrics missing deterministic media hook counters: " + ", ".join(missing)
        )
    return {name: event[name] for name in MEDIA_COUNTERS}


def counter_delta(before, after, name, expected):
    assert after[name] - before[name] == expected, (name, before, after)


def media(helper, kind, payload, *, events, revision):
    applied = helper.exchange(
        "media-session", "media-session-applied", kind=kind, payload=payload
    )
    assert applied["kind"] == kind, applied
    assert applied["events"] == events, applied
    assert applied["revision"] == revision, applied
    return applied


def clock_state(event):
    counters = require_media_counters(event)
    return {
        "frames": event["frames"],
        "scripts": event["genericPropertyScriptUpdates"],
        "decodes": event["mediaTextures"]["decodes"],
        "uploadedBytes": event["mediaTextures"]["uploadedBytes"],
        **counters,
    }


def assert_video_state(event, *, temporally_active=True):
    video = event["mediaTextures"]
    assert video["players"] == 5, video
    assert video["referencedPlayers"] == 5, video
    assert video["scriptControlledPlayers"] == 5, video
    assert video["scriptPlayingPlayers"] == 1, video
    assert video["scriptPausedPlayers"] == 4, video
    if temporally_active is not None:
        assert video["temporallyActivePlayers"] == int(temporally_active), video


def lifecycle():
    helper = Helper("elaina-deterministic-promotion-lifecycle")
    ready = helper.load()
    assert ready["backend"] == EXPECTED_BACKEND, ready
    assert ready["drawComplete"] is True, ready
    assert ready["warnings"] == [], ready
    baseline = helper.exchange("metrics")
    initial_counters = require_media_counters(baseline)

    properties = media(
        helper,
        "properties",
        {
            "title": "Fresco Song",
            "artist": "Fresco Artist",
            "albumTitle": "Fresco Album",
        },
        events=1,
        revision=1,
    )
    assert properties["playbackState"] == 0, properties
    after_properties = helper.exchange("metrics")
    counter_delta(
        initial_counters,
        require_media_counters(after_properties),
        "mediaPropertyScriptDispatches",
        MEDIA_COUNTERS["mediaPropertyScriptDispatches"],
    )
    playback = media(
        helper, "playback", {"state": 1}, events=2, revision=2
    )
    assert playback["playbackState"] == 1, playback
    after_playback = helper.exchange("metrics")
    counter_delta(
        require_media_counters(after_properties),
        require_media_counters(after_playback),
        "mediaPlaybackScriptDispatches",
        MEDIA_COUNTERS["mediaPlaybackScriptDispatches"],
    )

    timeline = media(
        helper,
        "timeline",
        {"position": 12.5, "duration": 240.0},
        events=3,
        revision=3,
    )
    assert timeline["playbackState"] == 1, timeline
    after_timeline = helper.exchange("metrics")
    counter_delta(
        require_media_counters(after_playback),
        require_media_counters(after_timeline),
        "mediaTimelineScriptDispatches",
        MEDIA_COUNTERS["mediaTimelineScriptDispatches"],
    )

    thumbnail = media(
        helper, "thumbnail", RED_THUMBNAIL, events=4, revision=4
    )
    assert thumbnail["playbackState"] == 1, thumbnail
    assert thumbnail["hasThumbnail"] is True, thumbnail
    assert thumbnail["artworkReady"] is True, thumbnail
    assert thumbnail["artworkRevision"] == 1, thumbnail
    after_thumbnail = helper.exchange("metrics")
    counter_delta(
        require_media_counters(after_timeline),
        require_media_counters(after_thumbnail),
        "mediaThumbnailScriptDispatches",
        MEDIA_COUNTERS["mediaThumbnailScriptDispatches"],
    )

    time.sleep(0.25)
    running = helper.exchange("metrics")
    assert_video_state(running)
    helper.exchange("pause", "paused")
    paused = helper.exchange("metrics")
    assert paused["paused"] is True and paused["visible"] is True, paused
    paused_state = clock_state(paused)
    time.sleep(0.25)
    paused_later = helper.exchange("metrics")
    assert clock_state(paused_later) == paused_state, (paused, paused_later)

    helper.exchange("hide", "hidden")
    hidden = helper.exchange("metrics")
    assert hidden["paused"] is True and hidden["visible"] is False, hidden
    assert clock_state(hidden) == paused_state, (paused, hidden)
    time.sleep(0.25)
    hidden_later = helper.exchange("metrics")
    assert clock_state(hidden_later) == paused_state, (hidden, hidden_later)

    helper.exchange("show", "shown")
    shown = helper.exchange("metrics")
    assert shown["paused"] is True and shown["visible"] is True, shown
    assert clock_state(shown) == paused_state, (paused, shown)
    helper.exchange("resume", "resumed")
    resumed_start = helper.exchange("metrics")
    assert resumed_start["paused"] is False and resumed_start["visible"] is True
    time.sleep(0.25)
    resumed = helper.exchange("metrics")
    assert resumed["frames"] > resumed_start["frames"], (resumed_start, resumed)
    assert resumed["genericPropertyScriptUpdates"] > resumed_start[
        "genericPropertyScriptUpdates"
    ], (resumed_start, resumed)
    assert resumed["mediaTextures"]["decodes"] > resumed_start["mediaTextures"][
        "decodes"
    ], (resumed_start, resumed)
    assert resumed["mediaTextures"]["uploadedBytes"] > resumed_start[
        "mediaTextures"
    ]["uploadedBytes"], (resumed_start, resumed)
    assert require_media_counters(resumed) == require_media_counters(resumed_start)
    assert_video_state(resumed)
    helper.stop()


def restart():
    first = Helper("elaina-deterministic-promotion-restart")
    first_ready = first.load(frames=2)
    first_metrics = first.exchange("metrics")
    first_counters = require_media_counters(first_metrics)
    first_thumbnail = media(
        first, "thumbnail", RED_THUMBNAIL, events=1, revision=1
    )
    assert first_thumbnail["artworkReady"] is True, first_thumbnail
    assert first_thumbnail["artworkRevision"] == 1, first_thumbnail
    assert first_thumbnail["artworkRGBAHash"] != 0, first_thumbnail
    first_after = first.exchange("metrics")
    assert_video_state(first_after, temporally_active=None)
    counter_delta(
        first_counters,
        require_media_counters(first_after),
        "mediaThumbnailScriptDispatches",
        MEDIA_COUNTERS["mediaThumbnailScriptDispatches"],
    )
    first_sound = first_after["soundControls"]
    first.crash()

    second = Helper("elaina-deterministic-promotion-restart")
    second_ready = second.load(frames=2)
    assert second_ready["backend"] == EXPECTED_BACKEND, second_ready
    second_before = second.exchange("metrics")
    assert require_media_counters(second_before) == first_counters, second_before
    assert second_before["soundControls"] == first_sound, (first_after, second_before)
    assert_video_state(second_before, temporally_active=None)
    replay = media(second, "thumbnail", RED_THUMBNAIL, events=1, revision=1)
    assert replay["hasThumbnail"] is True, replay
    assert replay["artworkReady"] is True, replay
    assert replay["artworkRevision"] == 1, replay
    assert replay["artworkRGBAHash"] == first_thumbnail["artworkRGBAHash"], (
        first_thumbnail,
        replay,
    )
    second_after = second.exchange("metrics")
    counter_delta(
        require_media_counters(second_before),
        require_media_counters(second_after),
        "mediaThumbnailScriptDispatches",
        MEDIA_COUNTERS["mediaThumbnailScriptDispatches"],
    )
    second.stop()


def frozen_thumbnail_snapshot(payload, label, repetition):
    helper = Helper(f"elaina-thumbnail-ab-{label}-{repetition}")
    ready = helper.load(
        frames=2,
        visible=False,
        display=0,
        fps=1,
        extra_properties={
            "newproperty61": {"value": False},
            "shu": {"value": False},
        },
    )
    assert ready["backend"] == EXPECTED_BACKEND, ready
    helper.exchange("pause", "paused")
    playback = media(helper, "playback", {"state": 1}, events=1, revision=1)
    assert playback["playbackState"] == 1, playback
    before = helper.exchange("metrics")
    applied = media(helper, "thumbnail", payload, events=2, revision=2)
    assert applied["artworkReady"] is True, applied
    assert applied["artworkRGBAHash"] != 0, applied
    after = helper.exchange("metrics")
    counter_delta(
        require_media_counters(before),
        require_media_counters(after),
        "mediaThumbnailScriptDispatches",
        MEDIA_COUNTERS["mediaThumbnailScriptDispatches"],
    )
    assert clock_state(after) == {
        **clock_state(before),
        "mediaThumbnailScriptDispatches": (
            before["mediaThumbnailScriptDispatches"]
            + MEDIA_COUNTERS["mediaThumbnailScriptDispatches"]
        ),
    }, (before, after)
    helper.stop()
    return applied["artworkRGBAHash"]


def thumbnail_visual_ab():
    red = [frozen_thumbnail_snapshot(RED_THUMBNAIL, "red", run) for run in range(2)]
    blue = [frozen_thumbnail_snapshot(BLUE_THUMBNAIL, "blue", run) for run in range(2)]
    assert red[0] == red[1], red
    assert blue[0] == blue[1], blue
    assert red[0] != blue[0], (red, blue)


if not os.path.isfile(os.path.join(PROJECT, "scene.pkg")):
    raise SystemExit(f"Elaina promotion fixture missing: {PROJECT}")

lifecycle()
restart()
thumbnail_visual_ab()

print(
    "Elaina deterministic promotion lifecycle: media hook dispatch, host clocks, "
    "video ownership, restart, and frozen thumbnail A/B passed"
)
