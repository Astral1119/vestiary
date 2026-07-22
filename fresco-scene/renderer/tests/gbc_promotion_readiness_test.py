#!/usr/bin/env python3

import argparse
import json
import os
import select
import subprocess
import tempfile
import time


GBC_ID = "3448290956"
SECONDARY_MOTION_WARNING = (
    "puppet secondary motion lacks independent changes "
    "(simulation-enabled bones=5)"
)
DYNAMIC_FLOAT_KEYS = {
    "animation-rate:179:193",
    "animation-rate:179:200",
}


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Exercise GBC promotion sentinels across helper generations."
    )
    parser.add_argument("helper")
    parser.add_argument("workshop")
    parser.add_argument("assets")
    parser.add_argument("expected_backend")
    parser.add_argument(
        "--require-promotable",
        action="store_true",
        help="require independent advancing secondary-motion evidence and no warning",
    )
    return parser.parse_args()


def message(assignment, message_type, **values):
    return {
        "protocolVersion": 1,
        "type": message_type,
        "assignmentID": assignment,
        **values,
    }


class HelperGeneration:
    def __init__(self, helper, project, assets, expected_backend, generation):
        self.project = project
        self.assets = assets
        self.expected_backend = expected_backend
        self.assignment = f"gbc-promotion-readiness-{generation}"
        environment = os.environ.copy()
        environment["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "1"
        environment.pop("FRESCO_SCENE_AUDIO_DISABLED", None)
        self.stderr = tempfile.TemporaryFile(mode="w+")
        self.process = subprocess.Popen(
            [helper],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr,
            text=True,
            bufsize=1,
            env=environment,
        )

    def stderr_text(self):
        self.stderr.flush()
        self.stderr.seek(0)
        result = self.stderr.read()
        self.stderr.seek(0, os.SEEK_END)
        return result

    def send(self, message_type, **values):
        self.process.stdin.write(
            json.dumps(message(self.assignment, message_type, **values)) + "\n"
        )
        self.process.stdin.flush()

    def exchange(self, message_type, expected=None, timeout=90, **values):
        self.send(message_type, **values)
        readable, _, _ = select.select([self.process.stdout], [], [], timeout)
        assert readable, (message_type, "timed out", self.stderr_text())
        line = self.process.stdout.readline()
        assert line, (message_type, self.stderr_text())
        event = json.loads(line)
        assert event["type"] == (expected or message_type), event
        assert event["assignmentID"] == self.assignment, event
        return event

    def load(self):
        ready = self.exchange(
            "load",
            "ready",
            path=self.project,
            assetRoot=self.assets,
            width=320,
            height=180,
            visible=True,
            muted=True,
            evidenceFrames=2,
        )
        return ready

    def metrics(self):
        return self.exchange("metrics")

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
    result = {control["id"]: control for control in event["soundControls"]}
    for sound_id in (208, 283):
        assert sound_id in result, event
        assert {
            "playing",
            "requestedPlaying",
            "playerConstructed",
            "playRequests",
            "activeAsset",
            "error",
        } <= result[sound_id].keys(), result[sound_id]
    return result


def poll(helper, predicate, label, timeout=15):
    deadline = time.monotonic() + timeout
    latest = None
    while time.monotonic() < deadline:
        latest = helper.metrics()
        if predicate(latest):
            return latest
        time.sleep(0.05)
    raise AssertionError((label, latest, helper.stderr_text()))


def dynamic_float_state(event):
    return {
        value["key"]: (value["value"], value["changes"])
        for value in event["scriptedDynamicFloats"]
    }


def assert_common(event, expected_backend):
    assert event["backend"] == expected_backend, event
    assert event["genericPropertyScripts"] == 10, event
    assert event["genericPropertyScriptErrors"] == 0, event
    assert event["scriptErrors"] == 0, event


def assert_ready(ready, expected_backend, require_promotable):
    assert_common(ready, expected_backend)
    assert ready["drawComplete"] is True, ready
    assert ready["range"][0] < ready["range"][1], ready
    assert ready["deferredScriptValues"] == 0, ready
    assert ready["camera2DActive"] is True, ready
    assert ready["camera2DCenter"] == [1920, 1080], ready
    assert ready["camera2DZoom"] == 1, ready
    assert not any("SceneScript" in warning for warning in ready["warnings"]), ready
    if not require_promotable:
        assert ready["warnings"] == [SECONDARY_MOTION_WARNING], ready


def assert_secondary_motion_progress(loaded, advanced, generation):
    blockers = []
    for field in ("secondaryMotionSteps", "secondaryMotionChanges"):
        if field not in loaded or field not in advanced:
            blockers.append(f"generation {generation}: independent {field} evidence missing")
            continue
        before = loaded[field]
        after = advanced[field]
        if (
            isinstance(before, bool)
            or isinstance(after, bool)
            or not isinstance(before, (int, float))
            or not isinstance(after, (int, float))
        ):
            blockers.append(f"generation {generation}: {field} is not numeric")
        elif before < 0 or after <= before:
            blockers.append(
                f"generation {generation}: {field} did not advance ({before} -> {after})"
            )
    return blockers


def exercise_generation(helper, generation, require_promotable):
    promotion_blockers = []
    hello = helper.exchange("hello")
    assert hello["backend"] == helper.expected_backend, hello
    assert "sound-playback" in hello["capabilities"], hello

    ready = helper.load()
    assert_ready(ready, helper.expected_backend, require_promotable)
    if require_promotable and ready["warnings"]:
        promotion_blockers.append(
            f"generation {generation}: warnings remain: {ready['warnings']}"
        )
    assert set(dynamic_float_state(ready)) == DYNAMIC_FLOAT_KEYS, ready
    assert all(value == (1.5, 1) for value in dynamic_float_state(ready).values()), ready
    initial_voice = controls(ready)[283]
    assert initial_voice["requestedPlaying"] is False, initial_voice
    assert initial_voice["playing"] is False, initial_voice
    assert initial_voice["playerConstructed"] is False, initial_voice
    assert initial_voice["playRequests"] == 0, initial_voice

    background = poll(
        helper,
        lambda event: (
            controls(event)[208]["playerConstructed"]
            and controls(event)[208]["requestedPlaying"]
            and controls(event)[208]["playing"]
            and controls(event)[208]["error"] == ""
        ),
        "background sound 208 did not converge",
    )
    assert_common(background, helper.expected_backend)
    assert background["muted"] is True, background

    loaded = helper.exchange("capture-puppet-evidence", "puppet-evidence")
    assert loaded["loadedMeshes"] > 0, loaded
    assert loaded["loadedAttachments"] > 0, loaded
    assert loaded["deformationChanges"] > 0, loaded

    moved = helper.exchange("cursor-move", "cursor-event-dispatched", x=200, y=100)
    assert (moved["phase"], moved["handled"]) == ("move", 4), moved
    moved_frame = helper.exchange("capture-frame-difference", "frame-difference")
    assert_common(moved_frame, helper.expected_backend)
    assert moved_frame["changedPixels"] > 0, moved_frame
    assert moved_frame["genericPropertyScriptChanges"] > ready["genericPropertyScriptChanges"], (
        ready,
        moved_frame,
    )

    applied = helper.exchange(
        "user-properties",
        "user-properties-applied",
        properties={"x3": {"value": 0.1}},
    )
    assert applied["acceptedScriptProperties"] == 1, applied
    camera_frame = helper.exchange("capture-frame-difference", "frame-difference")
    assert_common(camera_frame, helper.expected_backend)
    assert camera_frame["camera2DCenter"] == [2304, 1080], camera_frame
    assert camera_frame["camera2DZoom"] == 1, camera_frame

    first_named = helper.exchange(
        "cursor-click",
        "cursor-clicked",
        objectID=134,
        monotonicMilliseconds=1000,
    )
    second_named = helper.exchange(
        "cursor-click",
        "cursor-clicked",
        objectID=134,
        monotonicMilliseconds=1200,
    )
    assert first_named["handled"] is True and second_named["handled"] is True
    named = helper.metrics()
    assert_common(named, helper.expected_backend)
    assert named["namedAnimationTargetPlays"] == 2, named
    named_frame = helper.exchange("capture-frame-difference", "frame-difference")
    assert_common(named_frame, helper.expected_backend)
    assert (
        named_frame["namedAnimationActive"] > 0
        or named_frame["namedAnimationFrameTotal"]
        > named["namedAnimationFrameTotal"]
    ), (named, named_frame)

    helper.send("audio-spectrum", values=[1.0] * 128)
    spectrum = helper.exchange("capture-frame-difference", "frame-difference")
    assert_common(spectrum, helper.expected_backend)
    assert set(dynamic_float_state(spectrum)) == DYNAMIC_FLOAT_KEYS, spectrum
    assert all(value == (10, 2) for value in dynamic_float_state(spectrum).values()), spectrum

    first_voice = helper.exchange("cursor-click", "cursor-clicked", objectID=289)
    second_voice = helper.exchange("cursor-click", "cursor-clicked", objectID=289)
    assert first_voice["handled"] is True and second_voice["handled"] is True
    decoded_voice = poll(
        helper,
        lambda event: (
            controls(event)[283]["playerConstructed"]
            and controls(event)[283]["error"] == ""
        ),
        "single sound 283 did not construct",
    )
    assert controls(decoded_voice)[283]["activeAsset"] is not None, decoded_voice
    settled_voice = poll(
        helper,
        lambda event: (
            not controls(event)[283]["requestedPlaying"]
            and not controls(event)[283]["playing"]
            and controls(event)[283]["error"] == ""
        ),
        "single sound 283 did not settle",
    )
    settled_control = controls(settled_voice)[283]
    assert settled_control["playerConstructed"] is False, settled_voice
    assert settled_control["playRequests"] == 1, settled_voice

    before_pause = helper.exchange("capture-puppet-evidence", "puppet-evidence")
    helper.exchange("pause", "paused")
    paused = helper.exchange("capture-puppet-evidence", "puppet-evidence")
    time.sleep(0.1)
    paused_settled = helper.exchange(
        "capture-puppet-evidence", "puppet-evidence"
    )
    assert paused_settled == paused, (before_pause, paused, paused_settled)
    helper.exchange("resume", "resumed")
    resumed = helper.exchange("capture-frame-difference", "frame-difference")
    assert_common(resumed, helper.expected_backend)
    advanced = helper.exchange("capture-puppet-evidence", "puppet-evidence")
    assert advanced["deformationChanges"] >= paused_settled["deformationChanges"], advanced

    reloaded = helper.load()
    assert_ready(reloaded, helper.expected_backend, require_promotable)
    if require_promotable and reloaded["warnings"]:
        promotion_blockers.append(
            f"generation {generation} reload: warnings remain: {reloaded['warnings']}"
        )
    assert reloaded["namedAnimationTargetPlays"] == 0, reloaded
    assert set(dynamic_float_state(reloaded)) == DYNAMIC_FLOAT_KEYS, reloaded
    assert all(value == (1.5, 1) for value in dynamic_float_state(reloaded).values()), reloaded
    dormant_voice = controls(reloaded)[283]
    assert dormant_voice["requestedPlaying"] is False, dormant_voice
    assert dormant_voice["playRequests"] == 0, dormant_voice
    reloaded_puppet = helper.exchange(
        "capture-puppet-evidence", "puppet-evidence"
    )
    helper.exchange("capture-frame-difference", "frame-difference")
    reloaded_puppet_advanced = helper.exchange(
        "capture-puppet-evidence", "puppet-evidence"
    )
    promotion_blockers.extend(
        assert_secondary_motion_progress(
            reloaded_puppet, reloaded_puppet_advanced, generation
        )
    )
    reconverged = poll(
        helper,
        lambda event: (
            controls(event)[208]["playerConstructed"]
            and controls(event)[208]["requestedPlaying"]
            and controls(event)[208]["playing"]
            and controls(event)[208]["error"] == ""
        ),
        "reloaded background sound 208 did not reconverge",
    )
    assert_common(reconverged, helper.expected_backend)
    assert reconverged["muted"] is True, reconverged
    promotion_blockers.extend(
        assert_secondary_motion_progress(loaded, advanced, generation)
    )
    return promotion_blockers


def main():
    arguments = parse_arguments()
    helper_path = os.path.abspath(arguments.helper)
    project = os.path.join(os.path.abspath(arguments.workshop), GBC_ID)
    assets = os.path.abspath(arguments.assets)
    assert os.path.isfile(helper_path), helper_path
    assert os.path.isfile(os.path.join(project, "scene.pkg")), project

    promotion_blockers = []
    for generation in (1, 2):
        helper = HelperGeneration(
            helper_path,
            project,
            assets,
            arguments.expected_backend,
            generation,
        )
        try:
            promotion_blockers.extend(
                exercise_generation(helper, generation, arguments.require_promotable)
            )
            helper.stop()
        finally:
            if helper.process.poll() is None:
                helper.kill()

    if arguments.require_promotable:
        if promotion_blockers:
            raise AssertionError("GBC is not promotable: " + "; ".join(promotion_blockers))
        print(
            f"GBC promotion readiness: {arguments.expected_backend} promotable across "
            "two functional helper generations"
        )
        return

    blockers = sorted(set(promotion_blockers))
    print(
        f"GBC promotion readiness: {arguments.expected_backend} functional sentinels pass; "
        + ("blocked by: " + "; ".join(blockers) if blockers else "no blockers observed")
    )


if __name__ == "__main__":
    main()
