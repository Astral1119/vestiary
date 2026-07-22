#!/usr/bin/env python3

import json
import os
import pathlib
import select
import subprocess
import sys
import time


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from performance_promotion_policy import (  # noqa: E402
    PerformanceMeasurement,
    evaluate,
    measured_render_samples,
    report,
)


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = pathlib.Path(os.path.abspath(sys.argv[2]))
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
FIXTURE_ID = sys.argv[5]
PROJECT = WORKSHOP / FIXTURE_ID
WARMUP_SECONDS = 2.0
MEASUREMENT_SECONDS = 4.0


def message(kind, assignment, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": assignment,
        **values,
    }


def exchange(process, assignment, kind, expected=None, timeout=90, **values):
    process.stdin.write(json.dumps(message(kind, assignment, **values)) + "\n")
    process.stdin.flush()
    readable, _, _ = select.select([process.stdout], [], [], timeout)
    if not readable:
        raise AssertionError((kind, "timed out", process.stderr.read()))
    line = process.stdout.readline()
    if not line:
        raise AssertionError((kind, process.stderr.read()))
    event = json.loads(line)
    assert event["type"] == (expected or kind), event
    assert event["assignmentID"] == assignment, event
    return event


def process_usage(process):
    output = subprocess.check_output(
        ["ps", "-o", "rss=", "-o", "%cpu=", "-p", str(process.pid)],
        text=True,
    ).strip()
    resident_kib, cpu_percent = output.split()
    return int(resident_kib), float(cpu_percent)


def run(target_fps):
    assignment = f"promotion-performance-{FIXTURE_ID}-{target_fps}"
    process = subprocess.Popen(
        [HELPER],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    try:
        ready = exchange(
            process,
            assignment,
            "load",
            "ready",
            path=str(PROJECT),
            assetRoot=ASSETS,
            width=320,
            height=180,
            fps=target_fps,
            visible=True,
            muted=True,
            evidenceFrames=2,
            collectRenderDurationSamples=True,
        )
        assert ready["backend"] == EXPECTED_BACKEND, ready
        assert ready["drawComplete"] is True, ready

        time.sleep(WARMUP_SECONDS)
        baseline = exchange(process, assignment, "metrics")
        time.sleep(MEASUREMENT_SECONDS)
        measured = exchange(process, assignment, "metrics")
        samples = measured_render_samples(baseline, measured)
        frames = measured["frames"] - baseline["frames"]
        elapsed_seconds = (
            measured["elapsedMilliseconds"] - baseline["elapsedMilliseconds"]
        ) / 1000.0
        missed = (
            measured["missedFrameIntervals"] - baseline["missedFrameIntervals"]
        )
        resident_kib, cpu_percent = process_usage(process)
        measurement = PerformanceMeasurement(
            backend=EXPECTED_BACKEND,
            target_fps=float(target_fps),
            elapsed_seconds=elapsed_seconds,
            frames=frames,
            render_milliseconds=samples,
            missed_intervals=missed,
            resident_kib=resident_kib,
            cpu_percent=cpu_percent,
        )
        verdict = evaluate(measurement)
        result = report(measurement, verdict)

        exchange(process, assignment, "hide", "hidden")
        hidden = exchange(process, assignment, "metrics")
        time.sleep(0.25)
        still_hidden = exchange(process, assignment, "metrics")
        assert still_hidden["frames"] == hidden["frames"], (hidden, still_hidden)
        assert (
            still_hidden["renderDurationSamplesMilliseconds"]
            == hidden["renderDurationSamplesMilliseconds"]
        ), (hidden, still_hidden)

        exchange(process, assignment, "show", "shown")
        exchange(process, assignment, "pause", "paused")
        paused = exchange(process, assignment, "metrics")
        time.sleep(0.25)
        still_paused = exchange(process, assignment, "metrics")
        assert still_paused["frames"] == paused["frames"], (paused, still_paused)
        assert (
            still_paused["renderDurationSamplesMilliseconds"]
            == paused["renderDurationSamplesMilliseconds"]
        ), (paused, still_paused)

        exchange(process, assignment, "stop", "stopped")
        process.stdin.close()
        process.wait(timeout=10)
        assert process.returncode == 0, process.returncode
        stderr = process.stderr.read()
        assert not stderr, stderr
        return result
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=10)


if not (PROJECT / "scene.pkg").is_file():
    raise SystemExit(f"promotion performance fixture missing: {PROJECT}")

results = [run(30), run(60)]
print(json.dumps(results, separators=(",", ":")), flush=True)
failures = [result for result in results if not result["passed"]]
assert not failures, failures
