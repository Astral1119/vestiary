#!/usr/bin/env python3

import pathlib
import sys


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from performance_promotion_policy import (  # noqa: E402
    MissingPerformanceMetric,
    PerformanceMeasurement,
    evaluate,
    measured_render_samples,
    percentile,
    report,
)


def measurement(
    backend="native-opengl",
    target=60.0,
    elapsed=4.0,
    frames=228,
    samples=None,
    missed=5,
):
    if samples is None:
        budget = 1000.0 / target
        samples = [budget] * (frames - 1) + [budget * 4.0]
    return PerformanceMeasurement(
        backend=backend,
        target_fps=target,
        elapsed_seconds=elapsed,
        frames=frames,
        render_milliseconds=tuple(samples),
        missed_intervals=missed,
        resident_kib=401_408,
        cpu_percent=187.5,
    )


assert percentile((1.0, 2.0, 3.0, 4.0, 100.0), 0.80) == 4.0
assert percentile(tuple(range(1, 101)), 0.95) == 95

native_boundary = evaluate(measurement())
assert native_boundary.passed, native_boundary
assert native_boundary.achieved_fps == 57.0
assert native_boundary.fps_floor == 57.0
assert native_boundary.missed_interval_limit == 5

angle_budget = 1000.0 / 60.0
angle_samples = [angle_budget * 1.10] * 215 + [angle_budget * 6.0]
angle_boundary = evaluate(
    measurement(
        backend="angle-metal",
        frames=216,
        samples=angle_samples,
        missed=11,
    )
)
assert angle_boundary.passed, angle_boundary
assert angle_boundary.achieved_fps == 54.0
assert angle_boundary.fps_floor == 54.0

for achieved in (39, 46):
    frames = achieved * 4
    verdict = evaluate(
        measurement(
            frames=frames,
            samples=[10.0] * frames,
            missed=0,
        )
    )
    assert not verdict.passed, (achieved, verdict)
    assert any("achieved FPS" in failure for failure in verdict.failures)

native_30 = evaluate(
    measurement(
        target=30.0,
        frames=114,
        samples=[20.0] * 113 + [100.0],
        missed=3,
    )
)
assert native_30.passed, native_30
assert native_30.fps_floor == 28.5

for elapsed in (2.999, 5.001):
    frames = round(57.0 * elapsed)
    verdict = evaluate(
        measurement(
            elapsed=elapsed,
            frames=frames,
            samples=[10.0] * frames,
            missed=0,
        )
    )
    assert not verdict.passed, verdict
    assert any("measurement window" in failure for failure in verdict.failures)

p95_failure_samples = [10.0] * 215 + [17.0] * 13
p95_failure = evaluate(measurement(samples=p95_failure_samples))
assert not p95_failure.passed, p95_failure
assert any("p95 render" in failure for failure in p95_failure.failures)

maximum_failure = evaluate(
    measurement(samples=[10.0] * 227 + [66.667])
)
assert not maximum_failure.passed, maximum_failure
assert any("maximum render" in failure for failure in maximum_failure.failures)

missed_failure = evaluate(measurement(missed=6))
assert not missed_failure.passed, missed_failure
assert any("missed intervals" in failure for failure in missed_failure.failures)

baseline = {
    "frames": 2,
    "renderDurationSamplesMilliseconds": [1.0, 2.0],
}
measured = {
    "frames": 4,
    "renderDurationSamplesMilliseconds": [1.0, 2.0, 3.0, 4.0],
}
assert measured_render_samples(baseline, measured) == (3.0, 4.0)
for invalid_baseline, invalid_measured in (
    ({}, {}),
    ({"frames": 1, "renderDurationSamplesMilliseconds": [1.0]}, {}),
    (
        {"frames": 2, "renderDurationSamplesMilliseconds": [1.0, 2.0]},
        {"frames": 2, "renderDurationSamplesMilliseconds": [1.0, 3.0]},
    ),
    (
        {"frames": 1, "renderDurationSamplesMilliseconds": [1.0, 2.0]},
        {"frames": 2, "renderDurationSamplesMilliseconds": [1.0, 2.0]},
    ),
):
    try:
        measured_render_samples(invalid_baseline, invalid_measured)
    except MissingPerformanceMetric:
        pass
    else:
        raise AssertionError((invalid_baseline, invalid_measured))

summary = report(measurement(), native_boundary)
assert summary["residentKiB"] == 401_408
assert summary["cpuPercent"] == 187.5
assert summary["passed"] is True and summary["failures"] == []

print(
    "promotion performance policy: native floors=28.5/57, ANGLE floors=27/54, "
    "3-5s window, p95/max/missed boundaries and RSS/CPU reporting passed"
)
