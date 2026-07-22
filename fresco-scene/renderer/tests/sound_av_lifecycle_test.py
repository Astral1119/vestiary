#!/usr/bin/env python3

import json
import os
import select
import subprocess
import sys
import tempfile
import time


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ASSIGNMENT = "persona-av-sound-lifecycle"
PERSONA = os.path.join(WORKSHOP, "3151551777")
PROPERTIES = {
    "music": {"value": "2"},
    "musicvolume": {"value": 0.3},
    "trainsfxvolume": {"value": 0.8},
}
EXPECTED_OWNERSHIP = {
    604: "Color Your Night.ogg",
    823: (
        "zapsplat_vehicles_train_metro_interior_ride_few_people_distant_chat_"
        "sydney_australia_32726.mp3"
    ),
}


def message(kind, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": ASSIGNMENT,
        **values,
    }


def assert_no_audio_diagnostics(stderr):
    unrelated_prefixes = ("SceneScript generic-property creation failed:",)
    unexpected = [
        line for line in stderr.splitlines()
        if line and not line.startswith(unrelated_prefixes)
    ]
    assert not unexpected, unexpected


class HelperGeneration:
    def __init__(self):
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

    def exchange(self, kind, expected, **values):
        self.process.stdin.write(json.dumps(message(kind, **values)) + "\n")
        self.process.stdin.flush()
        readable, _, _ = select.select([self.process.stdout], [], [], 60)
        assert readable, (kind, "timed out", self.stderr_text())
        event = json.loads(self.process.stdout.readline())
        assert event["type"] == expected, event
        assert event["assignmentID"] == ASSIGNMENT, event
        return event

    def load_muted(self):
        hello = self.exchange("hello", "hello")
        assert hello["backend"] == EXPECTED_BACKEND, hello
        assert "sound-playback" in hello["capabilities"], hello
        return self.exchange(
            "load",
            "ready",
            path=PERSONA,
            assetRoot=ASSETS,
            width=320,
            height=180,
            visible=True,
            muted=True,
            evidenceFrames=2,
            userProperties=PROPERTIES,
        )

    def metrics(self):
        return self.exchange("metrics", "metrics")

    def stderr_text(self):
        self.stderr.flush()
        self.stderr.seek(0)
        result = self.stderr.read()
        self.stderr.seek(0, os.SEEK_END)
        return result

    def crash(self):
        self.process.kill()
        self.process.wait(timeout=10)
        assert self.process.returncode != 0, self.process.returncode
        assert_no_audio_diagnostics(self.stderr_text())
        self.stderr.close()

    def stop(self):
        self.exchange("stop", "stopped")
        self.process.stdin.close()
        self.process.wait(timeout=10)
        stderr = self.stderr_text()
        assert self.process.returncode == 0, self.process.returncode
        assert_no_audio_diagnostics(stderr)
        self.stderr.close()


def controls(event):
    return {control["id"]: control for control in event["soundControls"]}


def requested_ownership(event):
    return {
        sound_id: control["name"]
        for sound_id, control in controls(event).items()
        if control["requestedPlaying"]
    }


def poll_physical_playback(generation, expected):
    deadline = time.monotonic() + 10
    latest = None
    while time.monotonic() < deadline:
        latest = generation.metrics()
        selected = controls(latest)
        if all(selected[sound_id]["playing"] is expected for sound_id in EXPECTED_OWNERSHIP):
            return latest
        time.sleep(0.05)
    raise AssertionError(("physical playback did not converge", expected, latest))


assert os.path.isfile(os.path.join(PERSONA, "scene.pkg")), PERSONA

first = HelperGeneration()
first.load_muted()
first_playing = poll_physical_playback(first, True)
assert first_playing["muted"] is True, first_playing
assert requested_ownership(first_playing) == EXPECTED_OWNERSHIP, first_playing
assert all(
    controls(first_playing)[sound_id]["playing"] is True
    for sound_id in EXPECTED_OWNERSHIP
), first_playing

first.exchange("mute", "muted")
still_playing = poll_physical_playback(first, True)
assert still_playing["muted"] is True, still_playing
assert requested_ownership(still_playing) == EXPECTED_OWNERSHIP, still_playing

first.exchange("pause", "paused")
paused = poll_physical_playback(first, False)
assert paused["paused"] is True, paused
assert paused["muted"] is True, paused
assert requested_ownership(paused) == EXPECTED_OWNERSHIP, paused

first.exchange("resume", "resumed")
resumed = poll_physical_playback(first, True)
assert resumed["paused"] is False, resumed
assert resumed["muted"] is True, resumed
assert requested_ownership(resumed) == EXPECTED_OWNERSHIP, resumed
first.crash()

second = HelperGeneration()
second.load_muted()
recovered = poll_physical_playback(second, True)
assert recovered["muted"] is True, recovered
assert requested_ownership(recovered) == EXPECTED_OWNERSHIP, recovered
assert all(
    controls(recovered)[sound_id]["playing"] is True
    for sound_id in EXPECTED_OWNERSHIP
), recovered
second.stop()

print(
    "AVAudio sound lifecycle: muted Persona OGG/MP3 playback, pause/resume, "
    "and helper-generation recovery passed"
)
