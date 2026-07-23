#!/usr/bin/env python3

import base64
import binascii
import collections
import hashlib
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
FIXTURE_NAME = sys.argv[5]

FIXTURES = {
    "elaina": {
        "id": "3326873240",
        "sha256": "aca149b27aecd174ac008bbda68875c2d83e1619602605ab4f634bb91df2da5d",
        "genericScripts": None,
        "mediaPropertyScripts": 2,
        "initialProperties": {
            "display": {"value": 0},
            "newproperty67": {"value": True},
        },
        "changedProperties": {"display": {"value": 1}},
        "sound": {129: None},
        "particleChildren": {},
    },
    "hyuga": {
        "id": "3479521040",
        "sha256": "c8e35f0ad9b49f882eda411fb0feada0fb1059fa7bb058db79271cae794cf147",
        "genericScripts": 1,
        "mediaPropertyScripts": 1,
        "initialProperties": {},
        "changedProperties": {"newproperty2": {"value": False}},
        "sound": {193: None},
        "particleChildren": {"static": 3},
    },
    "persona": {
        "id": "3151551777",
        "sha256": "07ff04ebf6cf05b25daa45e4430a5d76f045ca5090235aa63a2bcebf23174c1e",
        "genericScripts": 137,
        "mediaPropertyScripts": 12,
        "initialProperties": {
            "character": {"value": "1"},
            "timeofday": {"value": "99"},
            "music": {"value": "2"},
            "musicvolume": {"value": 0.3},
            "trainsfxvolume": {"value": 0.8},
        },
        "changedProperties": {
            "character": {"value": "3"},
            "timeofday": {"value": "2"},
            "bgaudiobarsybounds": {"value": 0.25},
            "music": {"value": "1"},
        },
        "sound": {604: "Color Your Night.ogg", 823: None},
        "changedSound": {456: "Full Moon Full Life.ogg", 823: None},
        "particleChildren": {"eventfollow": 3, "eventspawn": 1},
    },
}

if FIXTURE_NAME not in FIXTURES:
    raise SystemExit(f"unknown stretch promotion fixture: {FIXTURE_NAME}")

FIXTURE = FIXTURES[FIXTURE_NAME]
PROJECT = os.path.join(WORKSHOP, FIXTURE["id"])
ASSIGNMENT = f"{FIXTURE_NAME}-promotion-gate"


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


ARTWORK = png(255, 0, 0)


def package_scene():
    def read_u32(handle):
        return struct.unpack("<I", handle.read(4))[0]

    def read_string(handle):
        return handle.read(read_u32(handle)).decode("utf-8")

    with open(os.path.join(PROJECT, "scene.pkg"), "rb") as handle:
        read_string(handle)
        entries = [
            (read_string(handle), read_u32(handle), read_u32(handle))
            for _ in range(read_u32(handle))
        ]
        base = handle.tell()
        _, offset, length = next(entry for entry in entries if entry[0] == "scene.json")
        handle.seek(base + offset)
        return json.loads(handle.read(length))


def scripted_values(value, path=()):
    if isinstance(value, dict):
        if isinstance(value.get("script"), str):
            yield path, value
        for key, child in value.items():
            if key != "script":
                yield from scripted_values(child, path + (str(key),))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from scripted_values(child, path + (str(index),))


def corpus_contract():
    scene = package_scene()
    scripts = list(scripted_values(scene))
    if FIXTURE_NAME == "elaina":
        groups = collections.Counter()
        for path, value in scripts:
            if len(path) >= 3 and path[0] == "objects" and path[2:] == ("text",):
                continue
            property_path = "/".join(path[2:] if path[:1] == ("objects",) else path)
            source = value["script"]
            if "applyUserProperties" in source and "displayVideo" in source:
                group = "videoDayNight"
            elif "mediaThumbnailChanged" in source:
                group = (
                    "thumbnailAnimation"
                    if "thisObject.getAnimation().play" in source
                    else "thumbnailColor"
                )
            elif "mediaPlaybackChanged" in source:
                group = (
                    "playbackTimeline"
                    if "mediaTimelineChanged" in source
                    else "playbackLayout"
                )
            elif "registerAudioBuffers" in source:
                group = "audioTransform"
            elif any(
                f"function {name}" in source
                for name in ("cursorClick", "cursorDown", "cursorMove", "cursorUp")
            ):
                group = "cursorSettings"
            elif "engine.canvasSize" in source and property_path == "origin":
                group = "canvasOrigin"
            elif "shared." in source:
                group = "sharedWidget"
            elif "input.cursor" in source:
                group = "cursorFollow"
            else:
                group = "layerLayout"
            groups[group] += 1
        expected = {
            "audioTransform": 17,
            "canvasOrigin": 15,
            "cursorFollow": 1,
            "cursorSettings": 7,
            "layerLayout": 11,
            "playbackLayout": 6,
            "playbackTimeline": 1,
            "sharedWidget": 23,
            "thumbnailAnimation": 1,
            "thumbnailColor": 5,
            "videoDayNight": 1,
        }
        assert dict(groups) == expected, groups
        assert len(scripts) == 105, len(scripts)
        return {"authoredScripts": 105, "nonTextGroups": expected}

    if FIXTURE_NAME == "persona":
        eventfollow_owner = next(
            item for item in scene["objects"] if item.get("id") == 148
        )
        assert {
            key: eventfollow_owner.get(key)
            for key in ("id", "name", "particle", "visible")
        } == {
            "id": 148,
            "name": "Birds",
            "particle": "particles/workshop/2511104820/Birds_parent.json",
            "visible": False,
        }, eventfollow_owner
        groups = collections.Counter()
        targets = []
        for path, value in scripts:
            source = value["script"]
            property_path = "/".join(path[2:] if path[:1] == ("objects",) else path)
            if path[:2] == ("general", "zoom"):
                group = "cameraZoom"
            elif "mediaPlaybackChanged" in source:
                group = "playbackVisibility"
            elif "mediaThumbnailChanged" in source and "getAnimation().play" not in source:
                group = "thumbnailColor"
            elif path[:2] == ("objects", "1") and property_path.startswith("effects/4/"):
                group = "commentedWriter"
            elif path[:2] == ("objects", "5") and property_path == "instanceoverride/alpha":
                group = "malformedScalarVector"
            elif property_path == "origin" and "createScriptProperties" in source:
                group = "absoluteOrigin"
            else:
                continue
            groups[group] += 1
            targets.append((group, property_path))
        expected = {
            "absoluteOrigin": 4,
            "cameraZoom": 1,
            "commentedWriter": 1,
            "malformedScalarVector": 1,
            "playbackVisibility": 12,
            "thumbnailColor": 7,
        }
        assert dict(groups) == expected, (groups, targets)
        assert sum(groups.values()) == 26, groups
        assert len(scripts) == 162, len(scripts)
        return {
            "authoredScripts": 162,
            "residualGroups": expected,
            "inactiveEventFollowOwner": {
                "id": 148,
                "path": "particles/workshop/2511104820/Birds_parent.json",
                "childPath": "particles/workshop/2511104820/bird_child.json",
                "visible": False,
            },
        }

    cameras = [item for item in scene["objects"] if "camera" in item]
    assert cameras == [
        {
            "camera": "default",
            "fov": 50.0,
            "id": 309,
            "name": "",
            "origin": "0.00000 0.00000 500.00000",
            "path": "scripts/camera_paths_309.json",
            "queuemode": "random",
            "visible": {"user": "newproperty", "value": False},
            "zoom": 0.75,
        }
    ], cameras
    return {
        "authoredScripts": len(scripts),
        "disabledCamera": {"id": 309, "property": "newproperty"},
    }


def environment(*, trace_particles=False, children=True):
    result = os.environ.copy()
    result["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    result["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "1"
    result["FRESCO_SCENE_SCRIPT_CLOCK_HOUR"] = "9"
    if trace_particles:
        result["FRESCO_PARTICLE_CHILD_TRACE"] = "1"
    if not children:
        result["FRESCO_PARTICLE_CHILD_DISABLED"] = "1"
    return result


def message(message_type, assignment=ASSIGNMENT, **values):
    return {
        "protocolVersion": 1,
        "type": message_type,
        "assignmentID": assignment,
        **values,
    }


def load(assignment=ASSIGNMENT, *, frames=2, visible=False, fps=60):
    return message(
        "load",
        assignment,
        path=PROJECT,
        assetRoot=ASSETS,
        width=320,
        height=180,
        fps=fps,
        visible=visible,
        muted=True,
        evidenceFrames=frames,
        userProperties=FIXTURE["initialProperties"],
    )


def sound_ownership(event):
    return {
        control["id"]: control
        for control in event["soundControls"]
        if control["requestedPlaying"]
    }


def assert_expected_sound(event, expected):
    ownership = sound_ownership(event)
    assert set(ownership) == set(expected), (ownership, expected)
    for sound_id, name in expected.items():
        if name is not None:
            assert ownership[sound_id]["name"] == name, ownership[sound_id]


def clean_boundary(event, failures):
    assert event["backend"] == EXPECTED_BACKEND, event
    assert event["drawComplete"] is True, event
    for field in (
        "scriptErrors",
        "mediaPropertyScriptErrors",
        "propertyScriptErrors",
        "genericPropertyScriptErrors",
    ):
        if event[field] != 0:
            failures.append(f"{field}={event[field]}")
    if (
        FIXTURE["genericScripts"] is not None
        and event["genericPropertyScripts"] != FIXTURE["genericScripts"]
    ):
        failures.append(
            f"genericPropertyScripts={event['genericPropertyScripts']} "
            f"expected={FIXTURE['genericScripts']}"
        )
    if event["mediaPropertyScripts"] != FIXTURE["mediaPropertyScripts"]:
        failures.append(
            f"mediaPropertyScripts={event['mediaPropertyScripts']} "
            f"expected={FIXTURE['mediaPropertyScripts']}"
        )
    if event["deferredScriptValues"] != 0:
        failures.append(f"deferredScriptValues={event['deferredScriptValues']}")
    if event["warnings"]:
        failures.append(f"warnings={json.dumps(event['warnings'], ensure_ascii=False)}")


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

    def exchange(self, message_type, expected=None, timeout=90, **values):
        self.process.stdin.write(
            json.dumps(message(message_type, self.assignment, **values)) + "\n"
        )
        self.process.stdin.flush()
        readable, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not readable:
            raise AssertionError((message_type, "timed out", self.process.stderr.read()))
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError((message_type, self.process.stderr.read()))
        event = json.loads(line)
        assert event["type"] == (expected or message_type), event
        assert event["assignmentID"] == self.assignment, event
        return event

    def load(self, *, frames=2, visible=False, fps=60):
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
            userProperties=FIXTURE["initialProperties"],
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


def media_payload(helper, kind, payload):
    return helper.exchange(
        "media-session", "media-session-applied", kind=kind, payload=payload
    )


def media_hook_counters(event):
    return {
        name: event[name]
        for name in (
            "mediaPropertyScriptDispatches",
            "mediaPlaybackScriptDispatches",
            "mediaTimelineScriptDispatches",
            "mediaThumbnailScriptDispatches",
        )
    }


def lifecycle(failures):
    helper = Helper()
    ready = helper.load(frames=120)
    clean_boundary(ready, failures)
    assert_expected_sound(ready, FIXTURE["sound"])

    helper.exchange("show", "shown")
    initial = helper.exchange("metrics")
    assert initial["visible"] is True, initial

    media_payload(
        helper,
        "properties",
        {
            "title": "Fresco Song",
            "artist": "Fresco Artist",
            "albumTitle": "Fresco Album",
        },
    )
    properties_frame = helper.exchange("capture-frame-difference", "frame-difference")
    assert properties_frame["mediaPropertyScriptDispatches"] == FIXTURE[
        "mediaPropertyScripts"
    ], properties_frame
    assert properties_frame["scriptTextChanges"] > ready["scriptTextChanges"], (
        ready,
        properties_frame,
    )

    if FIXTURE_NAME in {"elaina", "persona"}:
        before_playback = helper.exchange("metrics")
        playback_reply = media_payload(helper, "playback", {"state": 1})
        playback = helper.exchange("capture-frame-difference", "frame-difference")
        assert playback["genericPropertyScriptUpdates"] > before_playback[
            "genericPropertyScriptUpdates"
        ], (before_playback, playback)
        if FIXTURE_NAME == "elaina":
            assert (playback_reply["events"], playback_reply["revision"]) == (2, 2)
            assert playback_reply["playbackState"] == 1, playback_reply
            assert playback["mediaPlaybackScriptDispatches"] - before_playback[
                "mediaPlaybackScriptDispatches"
            ] == 7, (before_playback, playback)
        else:
            assert playback["genericPropertyScriptChanges"] > before_playback[
                "genericPropertyScriptChanges"
            ], (before_playback, playback)
    if FIXTURE_NAME == "elaina":
        before_timeline = helper.exchange("metrics")
        timeline_reply = media_payload(
            helper, "timeline", {"position": 12.5, "duration": 240.0}
        )
        timeline = helper.exchange("capture-frame-difference", "frame-difference")
        assert timeline["genericPropertyScriptUpdates"] > before_timeline[
            "genericPropertyScriptUpdates"
        ], (before_timeline, timeline)
        assert (timeline_reply["events"], timeline_reply["revision"]) == (3, 3)
        assert timeline["mediaTimelineScriptDispatches"] - before_timeline[
            "mediaTimelineScriptDispatches"
        ] == 1, (before_timeline, timeline)

    before_thumbnail = helper.exchange("metrics")
    thumbnail = media_payload(
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
    assert thumbnail_frame["genericPropertyScriptUpdates"] > before_thumbnail[
        "genericPropertyScriptUpdates"
    ], (before_thumbnail, thumbnail_frame)
    if FIXTURE_NAME == "elaina":
        assert (thumbnail["events"], thumbnail["revision"]) == (4, 4), thumbnail
        assert thumbnail["hasThumbnail"] is True, thumbnail
        assert thumbnail["artworkRevision"] == 1, thumbnail
        assert thumbnail_frame["mediaThumbnailScriptDispatches"] - before_thumbnail[
            "mediaThumbnailScriptDispatches"
        ] == 6, (before_thumbnail, thumbnail_frame)
    else:
        assert thumbnail_frame["genericPropertyScriptChanges"] > before_thumbnail[
            "genericPropertyScriptChanges"
        ], (before_thumbnail, thumbnail_frame)
        assert thumbnail_frame["changedPixels"] > 0, thumbnail_frame

    before_pause = helper.exchange("metrics")
    helper.exchange("pause", "paused")
    paused = helper.exchange("metrics")
    time.sleep(0.20)
    paused_later = helper.exchange("metrics")
    assert paused["paused"] is True and paused_later["paused"] is True
    assert paused_later["frames"] == paused["frames"], (paused, paused_later)
    assert paused_later["genericPropertyScriptUpdates"] == paused[
        "genericPropertyScriptUpdates"
    ], (paused, paused_later)
    if FIXTURE_NAME == "elaina":
        assert media_hook_counters(paused_later) == media_hook_counters(paused)
    applied = helper.exchange(
        "user-properties",
        "user-properties-applied",
        properties=FIXTURE["changedProperties"],
    )
    assert applied["ignored"] == 0, applied
    assert applied["acceptedScriptProperties"] == len(FIXTURE["changedProperties"]), applied
    queued = helper.exchange("metrics")
    assert queued["genericPropertyScriptUpdates"] == paused[
        "genericPropertyScriptUpdates"
    ], (paused, queued)

    helper.exchange("hide", "hidden")
    hidden = helper.exchange("metrics")
    assert hidden["visible"] is False, hidden
    if FIXTURE_NAME == "elaina":
        assert media_hook_counters(hidden) == media_hook_counters(paused)
    helper.exchange("show", "shown")
    helper.exchange("resume", "resumed")
    if FIXTURE_NAME == "elaina":
        resumed_start = helper.exchange("metrics")
        assert media_hook_counters(resumed_start) == media_hook_counters(paused)
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
        assert media_hook_counters(resumed) == media_hook_counters(resumed_start)
    else:
        resumed = helper.exchange("capture-frame-difference", "frame-difference")
        assert resumed["changedPixels"] > 0, resumed
        assert resumed["genericPropertyScriptUpdates"] > queued[
            "genericPropertyScriptUpdates"
        ], (queued, resumed)
    if "changedSound" in FIXTURE:
        assert_expected_sound(resumed, FIXTURE["changedSound"])

    video = None
    if FIXTURE_NAME == "elaina":
        video = helper.exchange("metrics")["mediaTextures"]
        assert video["players"] == 5, video
        assert video["referencedPlayers"] == 5, video
        assert video["temporallyActivePlayers"] > 0, video
        assert video["decodes"] > 0 and video["uploadedBytes"] > 0, video

    puppet = None
    if FIXTURE_NAME == "hyuga":
        puppet = helper.exchange("capture-puppet-evidence", "puppet-evidence")
        assert puppet["loadedMeshes"] == 2, puppet
        assert puppet["loadedVertices"] == 790, puppet
        assert puppet["loadedMasks"] == 2, puppet
        assert puppet["loadedAttachments"] == 0, puppet
        assert puppet["deformationUploads"] > 0, puppet
        assert puppet["deformationChanges"] > 0, puppet
        assert puppet["maskPasses"] > 0, puppet

    helper.stop()
    return {
        "mediaDispatches": properties_frame["mediaPropertyScriptDispatches"],
        "thumbnailChanges": (
            thumbnail_frame["mediaThumbnailScriptDispatches"]
            - before_thumbnail["mediaThumbnailScriptDispatches"]
            if FIXTURE_NAME == "elaina"
            else thumbnail_frame["genericPropertyScriptChanges"]
            - before_thumbnail["genericPropertyScriptChanges"]
        ),
        "pausedAtFrame": paused["frames"],
        "video": video,
        "puppet": puppet,
        "prePauseFrames": before_pause["frames"],
    }


def helper_restart(failures):
    first = Helper(f"{ASSIGNMENT}-restart")
    first_ready = first.load(frames=2, visible=True)
    clean_boundary(first_ready, failures)
    first_ownership = sound_ownership(first_ready)
    first_before = first.exchange("metrics")
    first_thumbnail = media_payload(first, "thumbnail", {"thumbnail": ARTWORK})
    if FIXTURE_NAME == "elaina":
        assert (first_thumbnail["events"], first_thumbnail["revision"]) == (1, 1)
        first_after = first.exchange("metrics")
        assert first_after["mediaThumbnailScriptDispatches"] - first_before[
            "mediaThumbnailScriptDispatches"
        ] == 5, (first_before, first_after)
    first.crash()

    second = Helper(f"{ASSIGNMENT}-restart")
    second_ready = second.load(frames=2, visible=True)
    clean_boundary(second_ready, failures)
    assert set(sound_ownership(second_ready)) == set(first_ownership), (
        first_ready,
        second_ready,
    )
    second_before = second.exchange("metrics")
    if FIXTURE_NAME == "elaina":
        assert media_hook_counters(second_before) == media_hook_counters(first_before)
    replay = media_payload(second, "thumbnail", {"thumbnail": ARTWORK})
    assert replay["artworkReady"] is True and replay["artworkRevision"] == 1, replay
    replayed = second.exchange("capture-frame-difference", "frame-difference")
    if FIXTURE_NAME == "elaina":
        assert (replay["events"], replay["revision"]) == (1, 1), replay
        assert replayed["mediaThumbnailScriptDispatches"] - second_before[
            "mediaThumbnailScriptDispatches"
        ] == 5, (second_before, replayed)
    else:
        assert replayed["changedPixels"] > 0, replayed
    second.stop()


def particle_children():
    expected = FIXTURE["particleChildren"]
    if not expected:
        return None
    assignment = f"{ASSIGNMENT}-particles"
    commands = [
        load(assignment, frames=360, visible=True),
        message("pause", assignment),
        message("metrics", assignment),
        message("capture-frame-difference", assignment),
        message("metrics", assignment),
        message("resume", assignment),
        message("capture-frame-difference", assignment),
        message("stop", assignment),
    ]
    result = subprocess.run(
        [HELPER],
        input="".join(json.dumps(command) + "\n" for command in commands),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=180,
        env=environment(trace_particles=True),
        check=True,
    )
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert [event["type"] for event in events] == [
        "ready",
        "paused",
        "metrics",
        "frame-difference",
        "metrics",
        "resumed",
        "frame-difference",
        "stopped",
    ], events
    ready, _, paused, paused_frame, paused_later, _, resumed, _ = events
    assert ready["backend"] == EXPECTED_BACKEND, ready
    assert paused_later["frames"] == paused["frames"], (paused, paused_later)
    assert paused_frame["changedPixels"] == 0, paused_frame
    assert resumed["changedPixels"] > 0, resumed

    traces = []
    for line in result.stderr.splitlines():
        assert line.startswith("particle-child|"), line
        _, event, child_type, ordinal, path, serial, active, maximum = line.split("|", 7)
        traces.append(
            {
                "event": event,
                "type": child_type,
                "ordinal": int(ordinal),
                "path": path,
                "serial": int(serial),
                "active": int(active),
                "maximum": int(maximum),
            }
        )
    declarations = [trace for trace in traces if trace["event"] == "declaration"]
    observed = {
        child_type: sum(trace["type"] == child_type for trace in declarations)
        for child_type in expected
    }
    assert observed == expected, (observed, expected, declarations)
    assert not [trace for trace in traces if trace["event"] == "failure"], traces
    active_child_types = set(expected)
    if FIXTURE_NAME == "persona":
        inactive_path = "particles/workshop/2511104820/bird_child.json"
        inactive = [
            trace for trace in traces if trace["type"] == "eventfollow"
        ]
        assert [
            (trace["ordinal"], trace["path"])
            for trace in inactive if trace["event"] == "declaration"
        ] == [(ordinal, inactive_path) for ordinal in range(3)], inactive
        assert not [
            trace for trace in inactive
            if trace["event"] in {"birth", "follow", "rejected"}
        ], inactive
        assert [
            (
                trace["ordinal"], trace["path"], trace["serial"],
                trace["active"], trace["maximum"],
            )
            for trace in inactive if trace["event"] == "teardown"
        ] == [
            (ordinal, inactive_path, 0, 0, 1) for ordinal in range(3)
        ], inactive
        active_child_types.remove("eventfollow")
    for child_type in active_child_types:
        assert any(
            trace["event"] == "birth" and trace["type"] == child_type
            for trace in traces
        ), (child_type, traces)
    if "eventfollow" in active_child_types:
        assert any(trace["event"] == "follow" for trace in traces), traces
    bookkeeping = [trace for trace in traces if trace["event"] == "bookkeeping"]
    assert all(trace["active"] <= trace["maximum"] for trace in bookkeeping), bookkeeping
    assert len([trace for trace in traces if trace["event"] == "teardown"]) == len(
        declarations
    ), traces
    if FIXTURE_NAME == "hyuga":
        capacities = {
            trace["path"]: (trace["active"], trace["maximum"])
            for trace in traces
            if trace["event"] == "capacity"
        }
        assert capacities["particles/presets/leaves2b.json"] == (50, 10), capacities
        assert capacities["particles/presets/emberglow.json"] == (500, 20), capacities
    return {
        "declarations": observed,
        "births": sum(t["event"] == "birth" for t in traces),
        "inactiveEventFollow": FIXTURE_NAME == "persona",
        "activeEventFollowGate": (
            "fresco-scene-renderer-lonely-promotion-gate"
            if FIXTURE_NAME == "persona" else None
        ),
    }


def particle_visual_ab():
    if FIXTURE_NAME != "persona":
        return None

    def render(disabled):
        assignment = f"{ASSIGNMENT}-particle-ab"
        result = subprocess.run(
            [HELPER],
            input="".join(
                json.dumps(command) + "\n"
                for command in (load(assignment, frames=180), message("stop", assignment))
            ),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=120,
            env=environment(children=not disabled),
            check=True,
        )
        assert not result.stderr, result.stderr
        events = [json.loads(line) for line in result.stdout.splitlines()]
        assert [event["type"] for event in events] == ["ready", "stopped"], events
        assert events[0]["backend"] == EXPECTED_BACKEND, events[0]
        return events[0]["pixelRGBTotal"]

    enabled = (render(False), render(False))
    disabled = (render(True), render(True))
    baseline = max(abs(enabled[0] - enabled[1]), abs(disabled[0] - disabled[1]))
    child = min(abs(left - right) for left in enabled for right in disabled)
    assert child > 1_000 and child > max(1, baseline) * 4, (
        enabled,
        disabled,
        baseline,
        child,
    )
    return {"baseline": baseline, "child": child}


def process_usage(process):
    output = subprocess.check_output(
        ["ps", "-o", "rss=", "-o", "%cpu=", "-p", str(process.pid)],
        text=True,
    ).strip()
    resident_kib, cpu_percent = output.split()
    return int(resident_kib), float(cpu_percent)


def performance(target_fps):
    helper = Helper(f"{ASSIGNMENT}-performance-{target_fps}")
    try:
        ready = helper.load(frames=1, visible=True, fps=target_fps)
        assert ready["backend"] == EXPECTED_BACKEND, ready
        baseline = helper.exchange("metrics")
        time.sleep(1.25)
        running = helper.exchange("metrics")
        elapsed = (running["elapsedMilliseconds"] - baseline["elapsedMilliseconds"]) / 1000
        measured_frames = running["frames"] - baseline["frames"]
        observed_fps = measured_frames / elapsed
        missed_intervals = (
            running["missedFrameIntervals"] - baseline["missedFrameIntervals"]
        )
        frame_budget = 1000.0 / target_fps
        resident_kib, cpu_percent = process_usage(helper.process)
        assert target_fps * 0.65 <= observed_fps <= target_fps * 1.35, running
        assert 0 < running["averageRenderMilliseconds"] < frame_budget * 1.5, running
        assert running["maximumRenderMilliseconds"] < 1000, running
        assert missed_intervals <= measured_frames * 0.2 + 2, (
            baseline,
            running,
        )
        assert resident_kib < 1_500_000, resident_kib
        assert cpu_percent < 400, cpu_percent
        helper.stop()
        return {
            "targetFPS": target_fps,
            "observedFPS": round(observed_fps, 1),
            "averageRenderMilliseconds": round(running["averageRenderMilliseconds"], 2),
            "maximumRenderMilliseconds": round(running["maximumRenderMilliseconds"], 2),
            "missedFrameIntervals": missed_intervals,
            "residentMiB": round(resident_kib / 1024.0, 1),
            "cpuPercent": cpu_percent,
        }
    finally:
        if helper.process.poll() is None:
            helper.process.kill()
            helper.process.communicate()


package = os.path.join(PROJECT, "scene.pkg")
assert os.path.isfile(package), PROJECT
digest = hashlib.sha256()
with open(package, "rb") as handle:
    for contents in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(contents)
assert digest.hexdigest() == FIXTURE["sha256"], digest.hexdigest()

failures = []
corpus_evidence = corpus_contract()
lifecycle_evidence = lifecycle(failures)
helper_restart(failures)
particle_evidence = particle_children()
particle_ab_evidence = particle_visual_ab()
performance_evidence = [performance(fps) for fps in (30, 60)]

summary = json.dumps(
    {
        "fixture": FIXTURE_NAME,
        "id": FIXTURE["id"],
        "backend": EXPECTED_BACKEND,
        "corpus": corpus_evidence,
        "lifecycle": lifecycle_evidence,
        "particles": particle_evidence,
        "particleVisualAB": particle_ab_evidence,
        "performance": performance_evidence,
    },
    separators=(",", ":"),
)
if failures:
    raise AssertionError("; ".join(dict.fromkeys(failures)) + f"; passing evidence: {summary}")

print(summary)
