#!/usr/bin/env python3

import json
import os
import subprocess
import sys


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
LONELY = os.path.join(WORKSHOP, "3299228616")
ASSIGNMENT = "lonely-promotion-gate"


def message(kind, assignment=ASSIGNMENT, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": assignment,
        **values,
    }


def environment(hour=9, children=True):
    result = os.environ.copy()
    result["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    result["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "0"
    result["FRESCO_SCENE_SCRIPT_CLOCK_HOUR"] = str(hour)
    if not children:
        result["FRESCO_PARTICLE_CHILD_DISABLED"] = "1"
    return result


def run_batch(commands, *, hour=9, children=True, timeout=180):
    result = subprocess.run(
        [HELPER],
        input="".join(json.dumps(command) + "\n" for command in commands),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        env=environment(hour, children),
        check=True,
    )
    assert not result.stderr, result.stderr
    return [json.loads(line) for line in result.stdout.splitlines()]


def load(assignment=ASSIGNMENT, *, frames=120, visible=False, fps=60):
    return message(
        "load",
        assignment,
        path=LONELY,
        assetRoot=ASSETS,
        width=320,
        height=180,
        fps=fps,
        visible=visible,
        evidenceFrames=frames,
    )


def assert_clean_evidence(event, failures):
    assert event["backend"] == EXPECTED_BACKEND, event
    assert event["drawComplete"] is True, event
    assert event["scriptErrors"] == 0, event
    assert event["genericPropertyScriptErrors"] == 0, event
    assert event["mediaPropertyScriptErrors"] == 0, event
    assert event["deferredScriptValues"] == 0, event
    assert event["genericPropertyScripts"] == 36, event
    if event["warnings"]:
        failures.append(f"renderer warnings remain: {event['warnings']}")


def front_buffer_signature(hour):
    assignment = f"{ASSIGNMENT}-clock-{hour}"
    events = run_batch(
        [load(assignment, frames=1), message("stop", assignment)],
        hour=hour,
    )
    assert [event["type"] for event in events] == ["ready", "stopped"], events
    ready = events[0]
    assert ready["backend"] == EXPECTED_BACKEND, ready
    assert ready["drawComplete"] is True, ready
    return ready["pixelRGBTotal"], ready["varyingPixels"]


def audio_response(spectrum):
    assignment = f"{ASSIGNMENT}-audio-{int(any(spectrum))}"
    events = run_batch(
        [
            load(assignment, visible=True),
            message("audio-spectrum", assignment, values=spectrum),
            message("capture-frame-difference", assignment),
            message("stop", assignment),
        ]
    )
    assert [event["type"] for event in events] == [
        "ready",
        "frame-difference",
        "stopped",
    ], events
    return events[1]


def particle_children_on():
    assignment = f"{ASSIGNMENT}-children"
    child_environment = environment()
    child_environment["FRESCO_PARTICLE_CHILD_TRACE"] = "1"
    result = subprocess.run(
        [HELPER],
        input="".join(
            json.dumps(command) + "\n"
            for command in (
                load(assignment, frames=360),
                message("stop", assignment),
            )
        ),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=180,
        env=child_environment,
        check=True,
    )
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert [event["type"] for event in events] == ["ready", "stopped"], events
    assert events[0]["drawComplete"] is True and events[0]["frames"] == 360, events[0]
    traces = []
    for line in result.stderr.splitlines():
        assert line.startswith("particle-child|"), line
        _, event, child_type, ordinal, path, serial, active, maximum = line.split("|", 7)
        traces.append((event, child_type, int(ordinal), path, int(serial), int(active), int(maximum)))
    declarations = [trace for trace in traces if trace[0] == "declaration"]
    assert len(declarations) == 24, declarations
    assert sum(trace[1] == "eventfollow" for trace in declarations) == 18, declarations
    assert sum(trace[1] == "eventspawn" for trace in declarations) == 6, declarations
    assert not [trace for trace in traces if trace[0] == "failure"], traces
    assert any(
        trace[0] == "birth" and trace[1] == "eventfollow" for trace in traces
    ), traces
    assert any(trace[0] == "follow" for trace in traces), traces
    assert len([trace for trace in traces if trace[0] == "teardown"]) == 24, traces
    follow_births = [
        trace for trace in traces
        if trace[0] == "birth" and trace[1] == "eventfollow"
    ]
    unique_follow_serials = {trace[4] for trace in follow_births}
    repetitions = {
        serial: sum(trace[4] == serial for trace in follow_births)
        for serial in unique_follow_serials
    }
    return {
        "declarations": len(declarations),
        "followBirths": len(follow_births),
        "uniqueFollowSerials": len(unique_follow_serials),
        "maximumLanguageCopiesPerSerial": max(repetitions.values()),
    }


def lifecycle(failures):
    commands = [
        load(),
        message("show"),
        message("cursor-down", x=150, y=90),
        message("cursor-move", x=170, y=100),
        message("capture-frame-difference"),
        message("cursor-up", x=170, y=100),
        message("capture-frame-difference"),
        message("pause"),
        message("metrics"),
        message("capture-frame-difference"),
        message("metrics"),
        message("hide"),
        message("metrics"),
        message("show"),
        message("resume"),
        message("capture-frame-difference"),
        message("user-properties", properties={"barcolor": {"value": "1 0 0"}}),
        message("capture-frame-difference"),
        load(),
        message("metrics"),
        message("stop"),
    ]
    events = run_batch(commands)
    expected = [
        "ready",
        "shown",
        "cursor-event-dispatched",
        "cursor-event-dispatched",
        "frame-difference",
        "cursor-event-dispatched",
        "frame-difference",
        "paused",
        "metrics",
        "frame-difference",
        "metrics",
        "hidden",
        "metrics",
        "shown",
        "resumed",
        "frame-difference",
        "user-properties-applied",
        "frame-difference",
        "ready",
        "metrics",
        "stopped",
    ]
    assert [event["type"] for event in events] == expected, events
    (
        ready,
        _,
        cursor_down,
        cursor_move,
        dragged,
        cursor_up,
        bouncing,
        _,
        paused,
        paused_frame,
        paused_after_capture,
        _,
        hidden,
        _,
        _,
        resumed,
        property_applied,
        property_frame,
        reloaded,
        reloaded_metrics,
        _,
    ) = events
    for event in (ready, reloaded):
        assert_clean_evidence(event, failures)
    for event, phase in (
        (cursor_down, "down"),
        (cursor_move, "move"),
        (cursor_up, "up"),
    ):
        assert (event["phase"], event["handled"]) == (phase, 6), event
    assert dragged["changedPixels"] > 0, dragged
    assert bouncing["changedPixels"] > 0, bouncing
    assert paused["paused"] is True, paused
    assert paused_after_capture["paused"] is True, paused_after_capture
    assert paused["frames"] == paused_after_capture["frames"], (
        paused,
        paused_frame,
        paused_after_capture,
    )
    assert paused_after_capture["genericPropertyScriptUpdates"] == paused[
        "genericPropertyScriptUpdates"
    ], (paused, paused_after_capture)
    assert hidden["visible"] is False, hidden
    assert resumed["changedPixels"] > 0, resumed
    assert property_frame["drawComplete"] is True, property_frame
    if property_applied["acceptedScriptProperties"] != 1 or property_applied["ignored"]:
        failures.append(
            "authored property change is not bound: "
            f"{json.dumps(property_applied, separators=(',', ':'))}"
        )
    assert reloaded_metrics["paused"] is False, reloaded_metrics
    assert reloaded_metrics["visible"] is False, reloaded_metrics


def forced_restart(failures):
    assignment = f"{ASSIGNMENT}-restart"
    commands = [load(assignment), message("metrics", assignment), message("stop", assignment)]
    first = run_batch(commands)
    second = run_batch(commands)
    for events in (first, second):
        assert [event["type"] for event in events] == ["ready", "metrics", "stopped"], events
        assert_clean_evidence(events[0], failures)
        assert events[1]["frames"] == events[0]["frames"], events
    restart_delta = abs(
        first[0]["pixelRGBTotal"] - second[0]["pixelRGBTotal"]
    )
    assert restart_delta < 10_000, (restart_delta, first[0], second[0])


assert os.path.isfile(os.path.join(LONELY, "scene.pkg")), LONELY
failures = []

morning = front_buffer_signature(9)
evening = front_buffer_signature(18)
assert morning[0] != evening[0], (morning, evening)
assert morning[1] > 0 and evening[1] > 0, (morning, evening)

silent = audio_response([0.0] * 128)
energized = audio_response([1.0] * 128)
assert energized["changedPixels"] > silent["changedPixels"], (silent, energized)
assert energized["totalChannelDelta"] > silent["totalChannelDelta"] * 2, (silent, energized)

particle_child_evidence = particle_children_on()

lifecycle(failures)
forced_restart(failures)

summary = json.dumps(
    {
        "backend": EXPECTED_BACKEND,
        "frontBufferDelta": abs(morning[0] - evening[0]),
        "audioDeltaRatio": round(
            energized["totalChannelDelta"] / silent["totalChannelDelta"], 2
        ),
        "particleChildren": particle_child_evidence,
    },
    separators=(",", ":"),
)
if failures:
    raise AssertionError(
        "; ".join(dict.fromkeys(failures)) + f"; passing evidence: {summary}"
    )

print(summary)
