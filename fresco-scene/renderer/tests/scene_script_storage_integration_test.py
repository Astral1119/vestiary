#!/usr/bin/env python3

import json
import os
import select
import shutil
import subprocess
import sys
import tempfile


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
PROJECT = os.path.join(WORKSHOP, "3326873240")
ASSIGNMENT = "scene-script-storage-integration"


def message(request_type, **values):
    return {
        "protocolVersion": 1,
        "type": request_type,
        "assignmentID": ASSIGNMENT,
        **values,
    }


class Helper:
    def __init__(self):
        environment = os.environ.copy()
        environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
        environment["FRESCO_SCENE_SCRIPT_CLOCK_HOUR"] = "9"
        self.process = subprocess.Popen(
            [HELPER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=environment,
        )

    def exchange(self, request_type, expected=None, **values):
        self.process.stdin.write(json.dumps(message(request_type, **values)) + "\n")
        self.process.stdin.flush()
        readable, _, _ = select.select([self.process.stdout], [], [], 120)
        assert readable, (request_type, "timed out", self.process.stderr.read())
        event = json.loads(self.process.stdout.readline())
        assert event["type"] == (expected or request_type), event
        assert event["assignmentID"] == ASSIGNMENT, event
        return event

    def load(self, project):
        ready = self.exchange(
            "load",
            "ready",
            path=project,
            assetRoot=ASSETS,
            width=320,
            height=180,
            visible=True,
            muted=True,
            evidenceFrames=2,
            userProperties={"newproperty67": {"value": True}},
        )
        assert ready["backend"] == EXPECTED_BACKEND, ready
        assert ready["genericPropertyScriptErrors"] == 0, ready
        return self.exchange("metrics")

    def stop(self):
        self.exchange("stop", "stopped")
        self.process.stdin.close()
        self.process.wait(timeout=10)
        assert self.process.returncode == 0, self.process.returncode
        assert not self.process.stderr.read(), self.process.stderr.read()


assert os.path.isfile(os.path.join(PROJECT, "scene.pkg")), PROJECT

with tempfile.TemporaryDirectory(prefix="fresco-storage-identity-") as temporary:
    isolated = os.path.join(temporary, "3326873240-copy")
    os.mkdir(isolated)
    shutil.copy2(os.path.join(PROJECT, "project.json"), isolated)
    os.link(
        os.path.join(PROJECT, "scene.pkg"),
        os.path.join(isolated, "scene.pkg"),
    )

    first = Helper()
    try:
        initial = first.load(PROJECT)
        assert initial["scriptStorageKeys"] == 0, initial

        down = first.exchange(
            "cursor-down", "cursor-event-dispatched", x=160, y=90
        )
        up = first.exchange("cursor-up", "cursor-event-dispatched", x=160, y=90)
        assert down["handled"] > 0 and up["handled"] > 0, (down, up)
        written = first.exchange("metrics")
        assert written["scriptStorageKeys"] == 1, written
        assert written["scriptStorageBytes"] > 0, written

        retained = first.load(PROJECT)
        assert retained["scriptStorageKeys"] == 1, retained
        isolated_metrics = first.load(isolated)
        assert isolated_metrics["scriptStorageKeys"] == 0, isolated_metrics
        retained_again = first.load(PROJECT)
        assert retained_again["scriptStorageKeys"] == 1, retained_again
        first.stop()
    finally:
        if first.process.poll() is None:
            first.process.kill()
            first.process.wait(timeout=10)

    restarted = Helper()
    try:
        empty_after_restart = restarted.load(PROJECT)
        assert empty_after_restart["scriptStorageKeys"] == 0, empty_after_restart
        restarted.stop()
    finally:
        if restarted.process.poll() is None:
            restarted.process.kill()
            restarted.process.wait(timeout=10)

print(
    f"scene script storage: {EXPECTED_BACKEND} same-path retention, "
    "canonical-path isolation, and helper-restart reset passed"
)
