#!/usr/bin/env python3

import json
import os
import select
import struct
import subprocess
import sys
import tempfile
import time


HELPER = os.path.abspath(sys.argv[1])
ASSETS = os.path.abspath(sys.argv[2])
EXPECTED_BACKEND = sys.argv[3]
ASSIGNMENT = "static-scheduling"


def package_bytes(name, document):
    name_bytes = name.encode("utf-8")
    payload = json.dumps(document).encode("utf-8")
    version = b"PKGV0024"
    return (
        struct.pack("<I", len(version))
        + version
        + struct.pack("<I", 1)
        + struct.pack("<I", len(name_bytes))
        + name_bytes
        + struct.pack("<II", 0, len(payload))
        + payload
    )


def message(command_type, **values):
    return {
        "protocolVersion": 1,
        "type": command_type,
        "assignmentID": ASSIGNMENT,
        **values,
    }


class Helper:
    def __init__(self, *, legacy_loop=False):
        environment = os.environ.copy()
        if legacy_loop:
            environment["FRESCO_SCENE_LEGACY_FRAME_LOOP"] = "1"
        self.process = subprocess.Popen(
            [HELPER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=environment,
        )

    def exchange(self, command_type, expected=None, timeout=30, **values):
        self.process.stdin.write(json.dumps(message(command_type, **values)) + "\n")
        self.process.stdin.flush()
        readable, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not readable:
            raise AssertionError(
                (command_type, "timed out", self.process.stderr.read())
            )
        event = json.loads(self.process.stdout.readline())
        assert event["type"] == (expected or command_type), event
        return event

    def send(self, command_type, **values):
        self.process.stdin.write(json.dumps(message(command_type, **values)) + "\n")
        self.process.stdin.flush()

    def send_raw(self, value):
        self.process.stdin.write(value)
        self.process.stdin.flush()

    def receive(self, expected, timeout=30):
        readable, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not readable:
            raise AssertionError(
                (expected, "timed out", self.process.stderr.read())
            )
        event = json.loads(self.process.stdout.readline())
        assert event["type"] == expected, event
        return event

    def stop(self):
        self.exchange("stop", "stopped")
        self.process.stdin.close()
        self.process.wait(timeout=10)
        assert self.process.returncode == 0, self.process.returncode
        assert not self.process.stderr.read(), self.process.stderr.read()


with tempfile.TemporaryDirectory(prefix="fresco-static-scheduling.") as temporary:
    with open(os.path.join(temporary, "project.json"), "w", encoding="utf-8") as handle:
        json.dump(
            {
                "file": "scene.json",
                "general": {"properties": {}},
                "title": "Static scheduling fixture",
                "type": "scene",
                "version": 0,
            },
            handle,
        )
    scene = {
        "camera": {
            "center": "0 0 0",
            "eye": "0 0 1",
            "up": "0 1 0",
        },
        "general": {
            "ambientcolor": "0.3 0.3 0.3",
            "clearcolor": "0.1 0.2 0.3",
            "clearenabled": True,
            "farz": 10000.0,
            "nearz": 0.01,
            "orthogonalprojection": {"height": 180, "width": 320},
        },
        "objects": [],
        "version": 4,
    }
    with open(os.path.join(temporary, "scene.pkg"), "wb") as handle:
        handle.write(package_bytes("scene.json", scene))

    helper = Helper()
    ready = helper.exchange(
        "load",
        "ready",
        path=temporary,
        assetRoot=ASSETS,
        width=320,
        height=180,
        fps=24,
        policyRevision=3,
        reasonTokens=["profile:static"],
        staticContent=True,
        visible=True,
        muted=True,
    )
    assert ready["backend"] == EXPECTED_BACKEND, ready
    assert ready["targetFPS"] == 24, ready
    assert ready["policyRevision"] == 3, ready
    assert ready["reasonTokens"] == ["profile:static"], ready
    assert ready["schedulingMode"] == "static-present-on-change", ready
    assert ready["schedulingMechanism"] == "change-index-v1", ready
    assert ready["schedulingEvidence"]["externalPresentations"] == 1, ready
    assert ready["schedulingEvidence"]["invalidations"] == 0, ready
    assert ready["programCacheEntries"] == 0, ready
    assert ready["programCacheInsertions"] == 0, ready

    replayed = helper.exchange(
        "scheduling-policy",
        "scheduling-policy-applied",
        fpsCeiling=24,
        policyRevision=3,
        reasonTokens=["profile:static"],
    )
    assert replayed["fpsCeiling"] == 24, replayed
    assert replayed["policyRevision"] == 3, replayed

    before = helper.exchange("metrics")
    time.sleep(0.25)
    after = helper.exchange("metrics")
    assert after["frames"] == before["frames"], (before, after)
    assert after["schedulingMode"] == "static-present-on-change", after
    assert after["schedulingMechanism"] == "change-index-v1", after
    assert isinstance(after["schedulingEvidence"]["reasonCounts"], list), after
    assert len(after["schedulingEvidence"]["reasonCounts"]) == 14, after
    assert after["programCacheEntries"] == 0, after
    assert after["programCacheInsertions"] == 0, after

    applied = helper.exchange(
        "scheduling-policy",
        "scheduling-policy-applied",
        fpsCeiling=15,
        policyRevision=4,
        reasonTokens=["rule:low-power"],
    )
    assert applied["fpsCeiling"] == 15, applied
    assert applied["policyRevision"] == 4, applied
    assert applied["reasonTokens"] == ["rule:low-power"], applied

    stale = helper.exchange(
        "scheduling-policy",
        "warning",
        fpsCeiling=5,
        policyRevision=3,
        reasonTokens=["stale"],
    )
    assert stale["code"] == "stale-scheduling-policy", stale
    conflicting = helper.exchange(
        "scheduling-policy",
        "warning",
        fpsCeiling=10,
        policyRevision=4,
        reasonTokens=["conflict"],
    )
    assert conflicting["code"] == "conflicting-scheduling-policy", conflicting
    invalid_fps_boolean = helper.exchange(
        "scheduling-policy",
        "warning",
        fpsCeiling=True,
        policyRevision=5,
        reasonTokens=["invalid:boolean-fps"],
    )
    assert invalid_fps_boolean["code"] == "invalid-scheduling-policy", (
        invalid_fps_boolean
    )
    invalid_revision_boolean = helper.exchange(
        "scheduling-policy",
        "warning",
        fpsCeiling=10,
        policyRevision=True,
        reasonTokens=["invalid:boolean-revision"],
    )
    assert invalid_revision_boolean["code"] == "invalid-scheduling-policy", (
        invalid_revision_boolean
    )
    invalid_fps_fractional = helper.exchange(
        "scheduling-policy",
        "warning",
        fpsCeiling=10.5,
        policyRevision=5,
        reasonTokens=["invalid:fractional-fps"],
    )
    assert invalid_fps_fractional["code"] == "invalid-scheduling-policy", (
        invalid_fps_fractional
    )
    time.sleep(0.25)
    updated = helper.exchange("metrics")
    assert updated["frames"] == after["frames"], (after, updated)
    assert updated["targetFPS"] == 15, updated
    assert updated["policyRevision"] == 4, updated
    assert updated["reasonTokens"] == ["rule:low-power"], updated

    helper.exchange(
        "user-properties",
        "user-properties-applied",
        properties={"fixture": {"value": True}},
    )
    changed = helper.exchange("metrics")
    assert changed["frames"] == updated["frames"] + 1, (updated, changed)
    time.sleep(0.25)
    requiesced = helper.exchange("metrics")
    assert requiesced["frames"] == changed["frames"], (changed, requiesced)

    captured = helper.exchange(
        "capture-frame-difference", "frame-difference"
    )
    assert captured["presented"] is True, captured
    captured_metrics = helper.exchange("metrics")
    assert captured_metrics["schedulingEvidence"]["externalPresentations"] == 2, (
        captured,
        captured_metrics,
    )

    audio_applied = helper.exchange(
        "audio-spectrum", "audio-spectrum-applied", values=[0.0] * 128
    )
    assert audio_applied["changed"] is True, audio_applied
    assert audio_applied["inputs"] == 1, audio_applied
    assert audio_applied["changes"] == 1, audio_applied
    time.sleep(0.1)
    audio_metrics = helper.exchange("metrics")
    assert audio_metrics["frames"] == captured_metrics["frames"] + 1, (
        captured_metrics,
        audio_metrics,
    )
    helper.exchange(
        "media-session",
        "media-session-applied",
        kind="status",
        payload={"enabled": True},
    )
    time.sleep(0.1)
    media_metrics = helper.exchange("metrics")
    assert media_metrics["frames"] == audio_metrics["frames"] + 1, (
        audio_metrics,
        media_metrics,
    )

    helper.exchange("hide", "hidden")
    hidden_before = helper.exchange("metrics")
    helper.exchange(
        "user-properties",
        "user-properties-applied",
        properties={"fixture": {"value": True}},
    )
    time.sleep(0.1)
    hidden_after = helper.exchange("metrics")
    assert hidden_after["frames"] == hidden_before["frames"], (
        hidden_before,
        hidden_after,
    )
    assert hidden_after["schedulingEvidence"]["decisions"] == hidden_before[
        "schedulingEvidence"
    ]["decisions"], (hidden_before, hidden_after)
    helper.exchange("show", "shown")
    shown = helper.exchange("metrics")
    assert shown["frames"] == hidden_after["frames"] + 1, (hidden_after, shown)

    helper.exchange("pause", "paused")
    paused_before = helper.exchange("metrics")
    helper.exchange(
        "user-properties",
        "user-properties-applied",
        properties={"fixture": {"value": False}},
    )
    time.sleep(0.1)
    paused_after = helper.exchange("metrics")
    assert paused_after["frames"] == paused_before["frames"], (
        paused_before,
        paused_after,
    )
    assert paused_after["schedulingEvidence"]["decisions"] == paused_before[
        "schedulingEvidence"
    ]["decisions"], (paused_before, paused_after)
    helper.exchange("resume", "resumed")
    resumed = helper.exchange("metrics")
    assert resumed["frames"] == paused_after["frames"] + 1, (
        paused_after,
        resumed,
    )

    retiming_capture = helper.exchange(
        "capture-frame-difference", "frame-difference"
    )
    assert retiming_capture["presented"] is True, retiming_capture
    retiming_capture_metrics = helper.exchange("metrics")
    helper.exchange(
        "scheduling-policy",
        "scheduling-policy-applied",
        fpsCeiling=1,
        policyRevision=5,
        reasonTokens=["test:retiming"],
    )
    helper.exchange(
        "user-properties",
        "user-properties-applied",
        properties={"fixture": {"value": True}},
    )
    retiming_before = helper.exchange("metrics")
    assert retiming_before["frames"] == retiming_capture_metrics["frames"], (
        retiming_capture_metrics,
        retiming_before,
    )
    time.sleep(0.2)
    retiming_capped = helper.exchange("metrics")
    assert retiming_capped["frames"] == retiming_before["frames"], (
        retiming_before,
        retiming_capped,
    )
    time.sleep(0.9)
    retiming_presented = helper.exchange("metrics")
    assert retiming_presented["frames"] == retiming_capped["frames"] + 1, (
        retiming_capped,
        retiming_presented,
    )
    helper.exchange(
        "scheduling-policy",
        "scheduling-policy-applied",
        fpsCeiling=15,
        policyRevision=6,
        reasonTokens=["rule:low-power"],
    )

    queued_before = helper.exchange("metrics")
    queued_property = json.dumps(
        message(
            "user-properties",
            properties={"fixture": {"value": False}},
        )
    )
    oversized_pause = json.dumps(message("pause", padding="x" * 9000))
    helper.send_raw(queued_property + "\n" + oversized_pause[:8192])
    helper.receive("user-properties-applied")
    time.sleep(0.1)
    helper.send_raw(oversized_pause[8192:] + "\n")
    helper.receive("paused")
    queued_after = helper.exchange("metrics")
    assert queued_after["frames"] == queued_before["frames"], (
        queued_before,
        queued_after,
    )
    time.sleep(0.1)
    queued_quiescent = helper.exchange("metrics")
    assert queued_quiescent["frames"] == queued_after["frames"], (
        queued_after,
        queued_quiescent,
    )
    assert queued_quiescent["schedulingEvidence"]["decisions"] == queued_after[
        "schedulingEvidence"
    ]["decisions"], (queued_after, queued_quiescent)

    helper.exchange("hide", "hidden")
    helper.exchange("show", "shown")
    shown_while_paused = helper.exchange("metrics")
    assert shown_while_paused["frames"] == queued_quiescent["frames"], (
        queued_quiescent,
        shown_while_paused,
    )
    assert shown_while_paused["schedulingEvidence"]["decisions"] == (
        queued_quiescent["schedulingEvidence"]["decisions"]
    ), (queued_quiescent, shown_while_paused)

    helper.exchange("hide", "hidden")
    helper.exchange("resume", "resumed")
    resumed_while_hidden = helper.exchange("metrics")
    assert resumed_while_hidden["frames"] == shown_while_paused["frames"], (
        shown_while_paused,
        resumed_while_hidden,
    )
    assert resumed_while_hidden["schedulingEvidence"]["decisions"] == (
        shown_while_paused["schedulingEvidence"]["decisions"]
    ), (shown_while_paused, resumed_while_hidden)
    helper.exchange("show", "shown")
    crossed_active = helper.exchange("metrics")
    assert crossed_active["frames"] == resumed_while_hidden["frames"] + 1, (
        resumed_while_hidden,
        crossed_active,
    )
    helper.stop()

    dynamic = Helper()
    dynamic_ready = dynamic.exchange(
        "load",
        "ready",
        path=temporary,
        assetRoot=ASSETS,
        width=320,
        height=180,
        fps=24,
        visible=True,
        muted=True,
    )
    assert dynamic_ready["schedulingMode"] == "legacy-continuous", dynamic_ready
    assert dynamic_ready["schedulingMechanism"] == "change-index-v1", dynamic_ready
    dynamic_before = dynamic.exchange("metrics")
    time.sleep(0.15)
    dynamic_after = dynamic.exchange("metrics")
    assert dynamic_after["frames"] > dynamic_before["frames"], (
        dynamic_before,
        dynamic_after,
    )
    dynamic.stop()

    legacy = Helper(legacy_loop=True)
    legacy_ready = legacy.exchange(
        "load",
        "ready",
        path=temporary,
        assetRoot=ASSETS,
        width=320,
        height=180,
        fps=24,
        policyRevision=5,
        reasonTokens=["rollback:test"],
        staticContent=True,
        visible=True,
        muted=True,
    )
    assert legacy_ready["schedulingMode"] == "legacy-continuous", legacy_ready
    assert legacy_ready["schedulingMechanism"] == "legacy-frame-loop", legacy_ready
    assert legacy_ready["schedulingEvidence"] is None, legacy_ready
    legacy_before = legacy.exchange("metrics")
    time.sleep(0.25)
    legacy_after = legacy.exchange("metrics")
    assert legacy_after["frames"] > legacy_before["frames"], (
        legacy_before,
        legacy_after,
    )

    legacy.exchange("pause", "paused")
    legacy_paused = legacy.exchange("metrics")
    legacy_resume = json.dumps(message("resume"))
    legacy_oversized_pause = json.dumps(
        message("pause", padding="x" * 9000)
    )
    legacy.send_raw(legacy_resume + "\n" + legacy_oversized_pause[:8192])
    legacy.receive("resumed")
    time.sleep(0.1)
    legacy.send_raw(legacy_oversized_pause[8192:] + "\n")
    legacy.receive("paused")
    legacy_split_paused = legacy.exchange("metrics")
    assert legacy_split_paused["frames"] == legacy_paused["frames"], (
        legacy_paused,
        legacy_split_paused,
    )
    legacy.stop()

print(f"static scheduling: {EXPECTED_BACKEND} load, update, and quiescence passed")
