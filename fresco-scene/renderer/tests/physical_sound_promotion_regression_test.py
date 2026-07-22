#!/usr/bin/env python3

import hashlib
import json
import os
import select
import struct
import subprocess
import sys
import tempfile
import time


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]

FIXTURES = {
    "elaina": {
        "id": "3326873240",
        "package": "PKGV0023",
        "sha256": "aca149b27aecd174ac008bbda68875c2d83e1619602605ab4f634bb91df2da5d",
        "properties": {"newproperty45": {"value": 0.9}},
        "sounds": {
            129: {
                "name": "【8K120FPS·Hi-Res】全站最高音画质 魔女之旅 NCOP《リテラチュア》 - 1.【8K120FPS·Hi-Res】全站最高音画质 魔女之旅 NCOP《リテラ(Av698431744,P1).mp3",
                "asset": "sounds/【8K120FPS·Hi-Res】全站最高音画质 魔女之旅 NCOP《リテラチュア》 - 1.【8K120FPS·Hi-Res】全站最高音画质 魔女之旅 NCOP《リテラ(Av698431744,P1).mp3",
                "mode": "loop",
                "startsilent": False,
            },
        },
        "owned": {129},
    },
    "hyuga": {
        "id": "3479521040",
        "package": "PKGV0022",
        "sha256": "c8e35f0ad9b49f882eda411fb0feada0fb1059fa7bb058db79271cae794cf147",
        "properties": {},
        "sounds": {
            193: {
                "name": "松谷卓 - 君の膵臓をたべたい -Prologue.flac",
                "asset": "sounds/松谷卓 - 君の膵臓をたべたい -Prologue.flac",
                "mode": "loop",
                "startsilent": False,
            },
        },
        "owned": {193},
    },
    "persona": {
        "id": "3151551777",
        "package": "PKGV0021",
        "sha256": "07ff04ebf6cf05b25daa45e4430a5d76f045ca5090235aa63a2bcebf23174c1e",
        "properties": {
            "music": {"value": "2"},
            "musicvolume": {"value": 0.3},
            "trainsfxvolume": {"value": 0.8},
        },
        "sounds": {
            604: {
                "name": "Color Your Night.ogg",
                "asset": "sounds/1.16 Color Your Night.ogg",
                "mode": "loop",
                "startsilent": True,
            },
            823: {
                "name": "zapsplat_vehicles_train_metro_interior_ride_few_people_distant_chat_sydney_australia_32726.mp3",
                "asset": "sounds/zapsplat_vehicles_train_metro_interior_ride_few_people_distant_chat_sydney_australia_32726.mp3",
                "mode": "loop",
                "startsilent": False,
            },
        },
        "owned": {604, 823},
    },
    "gbc": {
        "id": "3448290956",
        "package": "PKGV0022",
        "sha256": "4bac6871f95380c374653c44a903538cfa841a8d17abe310a092543dd9ac6ac1",
        "properties": {},
        "sounds": {
            208: {
                "name": "日常的小曲.mp3",
                "asset": "sounds/日常的小曲.mp3",
                "mode": "loop",
                "startsilent": False,
            },
            283: {
                "name": "Voice1",
                "asset": "sounds/哈？.mp3",
                "mode": "single",
                "startsilent": False,
            },
        },
        "owned": {208},
        "trigger": {"objectID": 289, "soundID": 283},
    },
}


def message(kind, assignment, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": assignment,
        **values,
    }


def read_u32(handle):
    return struct.unpack("<I", handle.read(4))[0]


def read_string(handle):
    return handle.read(read_u32(handle)).decode("utf-8")


def package_contract(fixture):
    package = os.path.join(WORKSHOP, fixture["id"], "scene.pkg")
    with open(package, "rb") as handle:
        digest = hashlib.sha256()
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
        assert digest.hexdigest() == fixture["sha256"]
        handle.seek(0)
        assert read_string(handle) == fixture["package"]
        entries = [
            (read_string(handle), read_u32(handle), read_u32(handle))
            for _ in range(read_u32(handle))
        ]
        base = handle.tell()
        _, offset, length = next(entry for entry in entries if entry[0] == "scene.json")
        handle.seek(base + offset)
        scene = json.loads(handle.read(length))

    sound_objects = {
        item["id"]: item
        for item in scene["objects"]
        if isinstance(item.get("sound"), list)
    }
    entry_names = {entry[0] for entry in entries}
    for sound_id, expected in fixture["sounds"].items():
        authored = sound_objects[sound_id]
        assert authored["name"] == expected["name"], authored
        assert authored["sound"] == [expected["asset"]], authored
        assert authored["playbackmode"] == expected["mode"], authored
        assert authored["startsilent"] is expected["startsilent"], authored
        assert expected["asset"] in entry_names, expected


class Helper:
    def __init__(self, fixture_name, generation):
        self.fixture_name = fixture_name
        self.fixture = FIXTURES[fixture_name]
        self.assignment = f"physical-sound-{fixture_name}-{generation}"
        environment = os.environ.copy()
        environment["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "1"
        environment.pop("FRESCO_SCENE_AUDIO_DISABLED", None)
        self.stderr = tempfile.TemporaryFile(mode="w+")
        self.process = subprocess.Popen(
            [HELPER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr,
            text=True,
            bufsize=1,
            env=environment,
        )

    def exchange(self, kind, expected=None, timeout=90, **values):
        self.process.stdin.write(
            json.dumps(message(kind, self.assignment, **values)) + "\n"
        )
        self.process.stdin.flush()
        readable, _, _ = select.select([self.process.stdout], [], [], timeout)
        assert readable, (kind, "timed out", self.stderr_text())
        line = self.process.stdout.readline()
        assert line, (kind, self.stderr_text())
        event = json.loads(line)
        assert event["type"] == (expected or kind), event
        assert event["assignmentID"] == self.assignment, event
        return event

    def load(self):
        hello = self.exchange("hello")
        assert hello["backend"] == EXPECTED_BACKEND, hello
        assert "sound-playback" in hello["capabilities"], hello
        ready = self.exchange(
            "load",
            "ready",
            path=os.path.join(WORKSHOP, self.fixture["id"]),
            assetRoot=ASSETS,
            width=320,
            height=180,
            visible=True,
            muted=True,
            evidenceFrames=2,
            userProperties=self.fixture["properties"],
        )
        return ready

    def metrics(self):
        return self.exchange("metrics")

    def stderr_text(self):
        self.stderr.flush()
        self.stderr.seek(0)
        result = self.stderr.read()
        self.stderr.seek(0, os.SEEK_END)
        return result

    def stop(self):
        self.exchange("stop", "stopped")
        self.process.stdin.close()
        self.process.wait(timeout=10)
        assert self.process.returncode == 0, self.process.returncode
        self.stderr.close()

    def kill(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=10)
        self.stderr.close()


def controls(event):
    required = {
        "id",
        "name",
        "playing",
        "requestedPlaying",
        "playRequests",
        "pauseRequests",
        "stopRequests",
        "playerConstructed",
        "activeAsset",
        "error",
    }
    result = {control["id"]: control for control in event["soundControls"]}
    missing = {
        sound_id: sorted(required - control.keys())
        for sound_id, control in result.items()
        if required - control.keys()
    }
    if missing:
        raise AssertionError(
            "sound metrics lack physical decode evidence fields: " + repr(missing)
        )
    return result


def assert_decoded_assets(event, fixture, sound_ids):
    selected = controls(event)
    for sound_id in sound_ids:
        control = selected[sound_id]
        expected = fixture["sounds"][sound_id]
        assert control["name"] == expected["name"], control
        assert control["playerConstructed"] is True, control
        assert control["activeAsset"] == expected["asset"], control
        assert control["error"] == "", control


def requested_ownership(event):
    return {
        sound_id
        for sound_id, control in controls(event).items()
        if control["requestedPlaying"]
    }


def physical_ownership(event):
    return {
        sound_id
        for sound_id, control in controls(event).items()
        if control["playing"]
    }


def request_counts(event):
    return {
        sound_id: (
            control["playRequests"],
            control["pauseRequests"],
            control["stopRequests"],
        )
        for sound_id, control in controls(event).items()
    }


def poll(helper, predicate, label, timeout=10):
    deadline = time.monotonic() + timeout
    latest = None
    while time.monotonic() < deadline:
        latest = helper.metrics()
        if predicate(latest):
            return latest
        time.sleep(0.05)
    raise AssertionError((label, latest, helper.stderr_text()))


def poll_owned_physical(helper, expected_owned, playing):
    def converged(event):
        expected_physical = expected_owned if playing else set()
        return (
            requested_ownership(event) == expected_owned
            and physical_ownership(event) == expected_physical
        )

    return poll(helper, converged, ("physical ownership did not converge", playing))


def assert_default_capability_disabled():
    assignment = "physical-sound-default-capability"
    environment = os.environ.copy()
    environment.pop("FRESCO_SCENE_SOUND_EXPERIMENTAL", None)
    environment.pop("FRESCO_SCENE_AUDIO_DISABLED", None)
    commands = [message("hello", assignment), message("stop", assignment)]
    result = subprocess.run(
        [HELPER],
        input="".join(json.dumps(command) + "\n" for command in commands),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
        check=True,
        env=environment,
    )
    assert not result.stderr, result.stderr
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert [event["type"] for event in events] == ["hello", "stopped"], events
    assert "sound-playback" not in events[0]["capabilities"], events[0]


def exercise_generation(fixture_name, generation, full_lifecycle):
    fixture = FIXTURES[fixture_name]
    helper = Helper(fixture_name, generation)
    try:
        helper.load()
        running = poll_owned_physical(helper, fixture["owned"], True)
        assert_decoded_assets(running, fixture, fixture["owned"])

        trigger = fixture.get("trigger")
        if trigger is not None:
            dormant = controls(running)[trigger["soundID"]]
            assert dormant["playerConstructed"] is False, dormant
            assert dormant["activeAsset"] is None, dormant
            assert dormant["error"] == "", dormant
            helper.exchange("cursor-click", "cursor-clicked", objectID=trigger["objectID"])
            helper.exchange("cursor-click", "cursor-clicked", objectID=trigger["objectID"])
            triggered = poll(
                helper,
                lambda event: controls(event)[trigger["soundID"]]["playerConstructed"]
                and controls(event)[trigger["soundID"]]["error"] == "",
                "triggered sound did not decode",
            )
            assert_decoded_assets(triggered, fixture, {trigger["soundID"]})
            settled = poll(
                helper,
                lambda event: not controls(event)[trigger["soundID"]]["requestedPlaying"]
                and not controls(event)[trigger["soundID"]]["playing"],
                "single sound requested/physical state did not converge",
            )
            assert controls(settled)[trigger["soundID"]]["error"] == "", settled

        if full_lifecycle:
            lifecycle_request_counts = request_counts(running)
            if trigger is not None:
                lifecycle_request_counts = request_counts(settled)

            helper.exchange("pause", "paused")
            paused = poll_owned_physical(helper, fixture["owned"], False)
            assert paused["paused"] is True and paused["visible"] is True, paused
            assert request_counts(paused) == lifecycle_request_counts, paused

            helper.exchange("resume", "resumed")
            resumed = poll_owned_physical(helper, fixture["owned"], True)
            assert resumed["paused"] is False and resumed["visible"] is True, resumed
            assert request_counts(resumed) == lifecycle_request_counts, resumed

            helper.exchange("hide", "hidden")
            hidden = poll_owned_physical(helper, fixture["owned"], False)
            assert hidden["paused"] is False and hidden["visible"] is False, hidden
            assert request_counts(hidden) == lifecycle_request_counts, hidden

            helper.exchange("show", "shown")
            shown = poll_owned_physical(helper, fixture["owned"], True)
            assert shown["paused"] is False and shown["visible"] is True, shown
            assert request_counts(shown) == lifecycle_request_counts, shown
            assert_decoded_assets(shown, fixture, fixture["owned"])

        helper.stop()
    finally:
        if helper.process.poll() is None:
            helper.kill()


assert_default_capability_disabled()
for name, fixture in FIXTURES.items():
    package_contract(fixture)
    exercise_generation(name, 1, True)
    exercise_generation(name, 2, False)

print(
    "physical sound promotion: Elaina, Hyuga, Persona, and GBC muted AVAudio "
    "decode, ownership, lifecycle, and clean restart passed"
)
