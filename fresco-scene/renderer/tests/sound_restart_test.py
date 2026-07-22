#!/usr/bin/env python3

import json
import os
import select
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]


def message(kind, assignment_id, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": assignment_id,
        **values,
    }


class HelperGeneration:
    def __init__(self, assignment_id):
        environment = os.environ.copy()
        environment["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "1"
        environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
        self.assignment_id = assignment_id
        self.process = subprocess.Popen(
            [HELPER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=environment,
        )

    def exchange(self, kind, expected, **values):
        self.process.stdin.write(
            json.dumps(message(kind, self.assignment_id, **values)) + "\n"
        )
        self.process.stdin.flush()
        readable, _, _ = select.select([self.process.stdout], [], [], 60)
        assert readable, (kind, "timed out", self.process.stderr.read())
        event = json.loads(self.process.stdout.readline())
        assert event["type"] == expected, event
        assert event["assignmentID"] == self.assignment_id, event
        return event

    def load(self, project, user_properties=None):
        hello = self.exchange("hello", "hello")
        assert hello["backend"] == EXPECTED_BACKEND, hello
        assert "sound-playback" not in hello["capabilities"], hello
        ready = self.exchange(
            "load",
            "ready",
            path=project,
            assetRoot=ASSETS,
            width=320,
            height=180,
            visible=False,
            muted=True,
            evidenceFrames=2,
            userProperties=user_properties or {},
        )
        self.exchange("unmute", "unmuted")
        return ready

    def metrics(self):
        return self.exchange("metrics", "metrics")

    def crash(self):
        self.process.kill()
        self.process.wait(timeout=10)
        assert self.process.returncode != 0, self.process.returncode
        assert not self.process.stderr.read(), self.process.stderr.read()

    def stop(self):
        self.exchange("stop", "stopped")
        self.process.stdin.close()
        self.process.wait(timeout=10)
        stderr = self.process.stderr.read()
        assert self.process.returncode == 0, self.process.returncode
        assert not stderr, stderr


def controls(event):
    required = {
        "id",
        "name",
        "playing",
        "requestedPlaying",
        "playRequests",
        "pauseRequests",
        "stopRequests",
    }
    assert event["muted"] is False, event
    assert all(required <= control.keys() for control in event["soundControls"]), event
    return {control["id"]: control for control in event["soundControls"]}


def ownership(event):
    return {
        sound_id: control["name"]
        for sound_id, control in controls(event).items()
        if control["requestedPlaying"]
    }


gbc = os.path.join(WORKSHOP, "3448290956")
persona = os.path.join(WORKSHOP, "3151551777")
for project in (gbc, persona):
    assert os.path.isfile(os.path.join(project, "scene.pkg")), project


gbc_first = HelperGeneration("gbc-sound-restart")
gbc_first.load(gbc)
gbc_before_clicks = gbc_first.metrics()
gbc_first.exchange("cursor-click", "cursor-clicked", objectID=289)
gbc_first.exchange("cursor-click", "cursor-clicked", objectID=289)
gbc_after_clicks = gbc_first.metrics()
gbc_background = ownership(gbc_before_clicks)
assert len(gbc_background) == 1, gbc_before_clicks
assert 283 not in gbc_background, gbc_before_clicks
assert ownership(gbc_after_clicks) == {**gbc_background, 283: "Voice1"}, gbc_after_clicks
assert controls(gbc_after_clicks)[283]["playRequests"] == 1, gbc_after_clicks
gbc_first.crash()

gbc_second = HelperGeneration("gbc-sound-restart")
gbc_second.load(gbc)
gbc_restarted = gbc_second.metrics()
assert ownership(gbc_restarted) == gbc_background, gbc_restarted
assert controls(gbc_restarted)[283]["playRequests"] == 0, gbc_restarted
gbc_second.exchange("cursor-click", "cursor-clicked", objectID=289)
gbc_second.exchange("cursor-click", "cursor-clicked", objectID=289)
gbc_recovered = gbc_second.metrics()
assert ownership(gbc_recovered) == ownership(gbc_after_clicks), gbc_recovered
assert controls(gbc_recovered)[283]["playRequests"] == 1, gbc_recovered
gbc_second.stop()


persona_properties = {
    "music": {"value": "2"},
    "musicvolume": {"value": 0.3},
    "trainsfxvolume": {"value": 0.8},
}
persona_first = HelperGeneration("persona-sound-restart")
persona_first.load(persona, persona_properties)
persona_initial = persona_first.metrics()
persona_ownership = ownership(persona_initial)
assert persona_ownership == {
    604: "Color Your Night.ogg",
    823: (
        "zapsplat_vehicles_train_metro_interior_ride_few_people_distant_chat_"
        "sydney_australia_32726.mp3"
    ),
}, persona_initial
assert controls(persona_initial)[604]["playRequests"] == 1, persona_initial
persona_first.crash()

persona_second = HelperGeneration("persona-sound-restart")
persona_second.load(persona, persona_properties)
persona_recovered = persona_second.metrics()
assert ownership(persona_recovered) == persona_ownership, persona_recovered
assert controls(persona_recovered)[604]["playRequests"] == 1, persona_recovered
persona_second.stop()

print(
    "sound restart: GBC ambient/cursor and Persona selected-track ownership "
    "recovered across helper generations"
)
