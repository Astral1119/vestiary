#!/usr/bin/env python3

import json
import os
import select
import subprocess
import sys
import time


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
ELAINA = os.path.join(WORKSHOP, "3326873240")
ASSIGNMENT = "hidden-lifecycle-regression"
HIDDEN_SETTLE_SECONDS = 0.30
PARTICLE_CLOCK_FIELD = "particleSimulationSteps"


def message(kind, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": ASSIGNMENT,
        **values,
    }


def environment():
    result = os.environ.copy()
    result["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "1"
    result["FRESCO_SCENE_SCRIPT_CLOCK_HOUR"] = "9"
    return result


class Helper:
    def __init__(self):
        self.process = subprocess.Popen(
            [HELPER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=environment(),
        )

    def exchange(self, kind, expected=None, timeout=90, **values):
        self.process.stdin.write(json.dumps(message(kind, **values)) + "\n")
        self.process.stdin.flush()
        readable, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not readable:
            raise AssertionError((kind, "timed out", self.process.stderr.read()))
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError((kind, self.process.stderr.read()))
        event = json.loads(line)
        assert event["type"] == (expected or kind), event
        assert event["assignmentID"] == ASSIGNMENT, event
        return event

    def stop(self):
        if self.process.poll() is not None:
            return
        self.exchange("stop", "stopped")
        self.process.stdin.close()
        self.process.wait(timeout=10)
        assert self.process.returncode == 0, self.process.returncode
        assert not self.process.stderr.read(), self.process.stderr.read()

    def kill(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.communicate(timeout=10)


def sound_state(event):
    controls = event["soundControls"]
    assert len(controls) == 1 and controls[0]["id"] == 129, controls
    return tuple(sorted(controls[0].items()))


def activity_state(event):
    if PARTICLE_CLOCK_FIELD not in event:
        raise AssertionError(
            f"metrics missing {PARTICLE_CLOCK_FIELD}: cumulative particle "
            "simulation steps are required to prove hidden particle stability"
        )
    return {
        "frames": event["frames"],
        "scripts": event["genericPropertyScriptUpdates"],
        "particles": event[PARTICLE_CLOCK_FIELD],
        "videoDecodes": event["mediaTextures"]["decodes"],
        "videoBytes": event["mediaTextures"]["uploadedBytes"],
        "audio": sound_state(event),
    }


def assert_advanced(before, after):
    for key in ("frames", "scripts", "particles", "videoDecodes", "videoBytes"):
        assert after[key] > before[key], (key, before, after)


if not os.path.isfile(os.path.join(ELAINA, "scene.pkg")):
    raise SystemExit(f"hidden lifecycle fixture missing: {ELAINA}")

helper = Helper()
try:
    ready = helper.exchange(
        "load",
        "ready",
        path=ELAINA,
        assetRoot=ASSETS,
        width=320,
        height=180,
        fps=60,
        visible=True,
        muted=True,
        evidenceFrames=120,
        userProperties={
            "display": {"value": "1"},
            "newproperty67": {"value": True},
            "timevarying": {"value": False},
        },
    )
    assert ready["backend"] == EXPECTED_BACKEND, ready
    assert ready["drawComplete"] is True, ready

    running_start = helper.exchange("metrics")
    time.sleep(HIDDEN_SETTLE_SECONDS)
    running_end = helper.exchange("metrics")
    assert_advanced(activity_state(running_start), activity_state(running_end))
    running_sound = running_end["soundControls"][0]
    assert running_sound["playing"] is True, running_sound
    assert running_sound["requestedPlaying"] is True, running_sound

    helper.exchange("hide", "hidden")
    hidden_start = helper.exchange("metrics")
    assert hidden_start["visible"] is False, hidden_start
    assert hidden_start["paused"] is False, hidden_start
    assert hidden_start["muted"] is True, hidden_start
    assert hidden_start["soundControls"][0]["playing"] is False, hidden_start
    time.sleep(HIDDEN_SETTLE_SECONDS)
    hidden_end = helper.exchange("metrics")
    assert activity_state(hidden_end) == activity_state(hidden_start), (
        hidden_start,
        hidden_end,
    )

    helper.exchange("pause", "paused")
    paused = helper.exchange("metrics")
    assert paused["visible"] is False and paused["paused"] is True, paused
    assert activity_state(paused) == activity_state(hidden_end), (hidden_end, paused)

    helper.exchange("show", "shown")
    shown_start = helper.exchange("metrics")
    assert shown_start["visible"] is True and shown_start["paused"] is True, shown_start
    assert activity_state(shown_start) == activity_state(paused), (paused, shown_start)
    time.sleep(HIDDEN_SETTLE_SECONDS)
    shown_end = helper.exchange("metrics")
    assert activity_state(shown_end) == activity_state(shown_start), (
        shown_start,
        shown_end,
    )

    helper.exchange("resume", "resumed")
    resumed_start = helper.exchange("metrics")
    assert resumed_start["visible"] is True and resumed_start["paused"] is False
    time.sleep(HIDDEN_SETTLE_SECONDS)
    resumed_end = helper.exchange("metrics")
    assert_advanced(activity_state(resumed_start), activity_state(resumed_end))
    resumed_sound = resumed_end["soundControls"][0]
    assert resumed_sound["playing"] is True, resumed_sound
    assert resumed_sound["requestedPlaying"] is True, resumed_sound

    helper.stop()
finally:
    helper.kill()

print(
    f"hidden lifecycle: {EXPECTED_BACKEND} render, script, particle, video, and "
    "muted sound clocks compose across hide, pause, show, and resume"
)
