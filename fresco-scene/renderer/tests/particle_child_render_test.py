#!/usr/bin/env python3

import json
import os
import pathlib
import subprocess
import sys


HELPER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
ASSIGNMENT = "particle-child-runtime"
FIXTURES = ("3299228616", "3151551777", "3479521040")


def message(kind, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": ASSIGNMENT,
        **values,
    }


environment = os.environ.copy()
environment["FRESCO_PARTICLE_CHILD_TRACE"] = "1"
environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
environment["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "0"
all_events = []
all_stderr = []
for fixture in FIXTURES:
    commands = (
        message(
                "load",
                path=str(WORKSHOP / fixture),
                assetRoot=str(ASSETS),
                # Persona's eventspawn child rides its night star layers, so
                # its clock is pinned rather than left on the authored "99"
                # cycle. The other two fixtures have no timeofday property.
                userProperties=(
                    {"timeofday": {"value": "2"}}
                    if fixture == "3151551777"
                    else {}
                ),
                width=320,
                height=180,
                visible=True,
                evidenceFrames=360,
            ),
        message("pause"),
        message("metrics"),
        message("capture-frame-difference"),
        message("metrics"),
        message("resume"),
        message("capture-frame-difference"),
        message("stop"),
    )
    result = subprocess.run(
        [HELPER],
        input="".join(json.dumps(command) + "\n" for command in commands),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=120,
        env=environment,
        check=True,
    )
    all_events.extend(json.loads(line) for line in result.stdout.splitlines())
    all_stderr.extend(result.stderr.splitlines())

events = all_events
expected_types = [
    event_type for _ in FIXTURES for event_type in (
        "ready",
        "paused",
        "metrics",
        "frame-difference",
        "metrics",
        "resumed",
        "frame-difference",
        "stopped",
    )
]
assert [event["type"] for event in events] == expected_types, events
for offset in range(0, len(events), 8):
    ready, _, before, paused_frame, after, _, resumed_frame, _ = events[offset : offset + 8]
    assert ready["drawComplete"] is True and ready["frames"] == 360, ready
    assert before["paused"] is True and after["paused"] is True, (before, after)
    assert before["frames"] == after["frames"], (before, after)
    assert paused_frame["changedPixels"] == 0, paused_frame
    assert resumed_frame["changedPixels"] > 0, resumed_frame
    assert resumed_frame["drawComplete"] is True, resumed_frame

traces = []
for line in all_stderr:
    if not line.startswith("particle-child|"):
        raise AssertionError(f"unexpected renderer diagnostic: {line}")
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
assert len(declarations) >= 11, declarations
assert sum(trace["type"] == "static" for trace in declarations) == 3, declarations
assert sum(trace["type"] == "eventfollow" for trace in declarations) >= 6, declarations
assert sum(trace["type"] == "eventspawn" for trace in declarations) >= 2, declarations
assert not [trace for trace in traces if trace["event"] == "failure"], traces
static_capacities = {
    trace["path"]: (trace["active"], trace["maximum"])
    for trace in traces
    if trace["event"] == "capacity" and trace["type"] == "static"
}
assert static_capacities["particles/presets/leaves2b.json"] == (50, 10), (
    static_capacities
)
assert static_capacities["particles/presets/emberglow.json"] == (500, 20), (
    static_capacities
)

for child_type in ("static", "eventfollow", "eventspawn"):
    assert any(
        trace["event"] == "birth" and trace["type"] == child_type
        for trace in traces
    ), child_type
assert any(trace["event"] == "follow" for trace in traces), traces
assert any(trace["event"] == "death" for trace in traces), traces
bookkeeping = [trace for trace in traces if trace["event"] == "bookkeeping"]
assert bookkeeping, traces
assert all(trace["active"] <= trace["maximum"] for trace in bookkeeping), bookkeeping
assert len([trace for trace in traces if trace["event"] == "teardown"]) == len(
    declarations
), traces
for trace in traces:
    if trace["event"] in {"birth", "follow", "death", "rejected", "bookkeeping"}:
        assert 0 <= trace["active"] <= trace["maximum"], trace

failure_environment = environment.copy()
failure_environment["FRESCO_PARTICLE_CHILD_FAIL_PATH"] = (
    "particles/presets/leaves2b.json"
)
failure_commands = (
    message(
        "load",
        path=str(WORKSHOP / "3479521040"),
        assetRoot=str(ASSETS),
        width=320,
        height=180,
        visible=False,
        evidenceFrames=60,
    ),
    message("stop"),
)
failure_result = subprocess.run(
    [HELPER],
    input="".join(json.dumps(command) + "\n" for command in failure_commands),
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=60,
    env=failure_environment,
    check=True,
)
failure_events = [json.loads(line) for line in failure_result.stdout.splitlines()]
assert [event["type"] for event in failure_events] == ["ready", "stopped"], (
    failure_events
)
assert failure_events[0]["drawComplete"] is True, failure_events[0]
assert "particle-child|failure|static|0|particles/presets/leaves2b.json" in (
    failure_result.stderr
), failure_result.stderr
assert "particle-child|birth|static|0|particles/presets/emberglow.json" in (
    failure_result.stderr
), failure_result.stderr

print("particle children: birth/follow/death/caps/pause/teardown/failure isolation passed")
