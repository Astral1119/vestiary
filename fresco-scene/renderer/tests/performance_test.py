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
CAT = os.path.join(WORKSHOP, "3351508588")


def message(kind, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": "renderer-performance",
        **values,
    }


def send(process, kind, **values):
    process.stdin.write(json.dumps(message(kind, **values)) + "\n")
    process.stdin.flush()


def receive(process, expected, timeout=10.0):
    readable, _, _ = select.select([process.stdout], [], [], timeout)
    if not readable:
        raise AssertionError(f"timed out waiting for {expected}")
    line = process.stdout.readline()
    if not line:
        raise AssertionError(
            f"helper exited while waiting for {expected}: {process.stderr.read()}"
        )
    event = json.loads(line)
    assert event["type"] == expected, event
    return event


def command(process, kind, expected=None, timeout=10.0, **values):
    started = time.monotonic()
    send(process, kind, **values)
    event = receive(process, expected or kind, timeout)
    return event, time.monotonic() - started


def process_usage(process):
    output = subprocess.check_output(
        ["ps", "-o", "rss=", "-o", "%cpu=", "-p", str(process.pid)],
        text=True,
    ).strip()
    resident_kib, cpu_percent = output.split()
    return int(resident_kib), float(cpu_percent)


def run_case(target_fps):
    process = subprocess.Popen(
        [HELPER],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    try:
        hello, _ = command(process, "hello")
        assert "runtime-metrics" in hello["capabilities"], hello

        ready, _ = command(
            process,
            "load",
            expected="ready",
            path=CAT,
            assetRoot=ASSETS,
            width=320,
            height=180,
            fps=target_fps,
            visible=True,
        )
        assert ready["targetFPS"] == target_fps, ready
        assert ready["drawComplete"] is True, ready

        baseline, _ = command(process, "metrics")
        time.sleep(1.25)
        running, _ = command(process, "metrics")
        elapsed_seconds = (
            running["elapsedMilliseconds"] - baseline["elapsedMilliseconds"]
        ) / 1000.0
        frame_delta = running["frames"] - baseline["frames"]
        observed_fps = frame_delta / elapsed_seconds
        frame_budget_ms = 1000.0 / target_fps

        assert running["targetFPS"] == target_fps, running
        assert target_fps * 0.65 <= observed_fps <= target_fps * 1.35, running
        assert 0.0 < running["averageRenderMilliseconds"] < frame_budget_ms * 1.5, running
        assert running["maximumRenderMilliseconds"] < 1000.0, running
        assert running["missedFrameIntervals"] <= running["frames"] * 0.2 + 2, running
        assert running["scriptErrors"] == 0, running
        assert running["paused"] is False, running
        assert running["visible"] is True, running

        resident_kib, cpu_percent = process_usage(process)
        assert resident_kib < 1_500_000, resident_kib
        assert cpu_percent < 400.0, cpu_percent

        _, pause_latency = command(process, "pause", expected="paused")
        paused, _ = command(process, "metrics")
        time.sleep(0.35)
        still_paused, _ = command(process, "metrics")
        assert pause_latency < 0.5, pause_latency
        assert paused["paused"] is True, paused
        assert still_paused["frames"] == paused["frames"], (paused, still_paused)

        _, resume_latency = command(process, "resume", expected="resumed")
        time.sleep(0.5)
        resumed, _ = command(process, "metrics")
        assert resume_latency < 0.5, resume_latency
        assert resumed["paused"] is False, resumed
        assert resumed["frames"] > still_paused["frames"] + target_fps * 0.2, resumed

        command(process, "stop", expected="stopped")
        _, stderr = process.communicate(timeout=5)
        assert process.returncode == 0, process.returncode
        assert not stderr, stderr
        return {
            "targetFPS": target_fps,
            "observedFPS": round(observed_fps, 1),
            "averageRenderMilliseconds": round(
                running["averageRenderMilliseconds"], 2
            ),
            "maximumRenderMilliseconds": round(
                running["maximumRenderMilliseconds"], 2
            ),
            "residentMiB": round(resident_kib / 1024.0, 1),
            "cpuPercent": cpu_percent,
            "pauseLatencyMilliseconds": round(pause_latency * 1000.0, 1),
            "resumeLatencyMilliseconds": round(resume_latency * 1000.0, 1),
        }
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()


if not os.path.isfile(os.path.join(CAT, "scene.pkg")):
    raise SystemExit(f"renderer performance fixture missing: {CAT}")

results = [run_case(target_fps) for target_fps in (30, 60)]
print(json.dumps(results, separators=(",", ":")))
