#!/usr/bin/env python3

import dataclasses
import math


MINIMUM_WINDOW_SECONDS = 3.0
MAXIMUM_WINDOW_SECONDS = 5.0
RENDER_SAMPLE_FIELD = "renderDurationSamplesMilliseconds"


@dataclasses.dataclass(frozen=True)
class BackendPolicy:
    achieved_fps_fraction: float
    p95_budget_fraction: float
    maximum_budget_multiple: float
    missed_interval_fraction: float


POLICIES = {
    "native-opengl": BackendPolicy(
        achieved_fps_fraction=0.95,
        p95_budget_fraction=1.00,
        maximum_budget_multiple=4.00,
        missed_interval_fraction=0.02,
    ),
    "angle-metal": BackendPolicy(
        achieved_fps_fraction=0.90,
        p95_budget_fraction=1.10,
        maximum_budget_multiple=6.00,
        missed_interval_fraction=0.05,
    ),
}


@dataclasses.dataclass(frozen=True)
class PerformanceMeasurement:
    backend: str
    target_fps: float
    elapsed_seconds: float
    frames: int
    render_milliseconds: tuple[float, ...]
    missed_intervals: int
    resident_kib: int
    cpu_percent: float


@dataclasses.dataclass(frozen=True)
class PerformanceVerdict:
    passed: bool
    failures: tuple[str, ...]
    achieved_fps: float
    fps_floor: float
    p95_render_milliseconds: float
    p95_limit_milliseconds: float
    maximum_render_milliseconds: float
    maximum_limit_milliseconds: float
    missed_interval_limit: int
    resident_kib: int
    cpu_percent: float


class MissingPerformanceMetric(ValueError):
    pass


def percentile(values, fraction):
    if not values:
        raise ValueError("percentile requires at least one sample")
    if not 0.0 < fraction <= 1.0:
        raise ValueError("percentile fraction must be within (0, 1]")
    ordered = sorted(values)
    index = math.ceil(len(ordered) * fraction) - 1
    return ordered[index]


def measured_render_samples(baseline, measured):
    if RENDER_SAMPLE_FIELD not in baseline or RENDER_SAMPLE_FIELD not in measured:
        raise MissingPerformanceMetric(
            f"metrics missing {RENDER_SAMPLE_FIELD}: cumulative per-frame render "
            "durations are required to exclude warm-up and compute measured p95/max"
        )
    before = baseline[RENDER_SAMPLE_FIELD]
    after = measured[RENDER_SAMPLE_FIELD]
    if not isinstance(before, list) or not isinstance(after, list):
        raise MissingPerformanceMetric(f"{RENDER_SAMPLE_FIELD} must be an array")
    for label, event, samples in (
        ("baseline", baseline, before),
        ("measured", measured, after),
    ):
        frames = event.get("frames")
        if (
            not isinstance(frames, int)
            or isinstance(frames, bool)
            or frames < 0
            or len(samples) != frames
        ):
            raise MissingPerformanceMetric(
                f"{label} {RENDER_SAMPLE_FIELD} count must equal frames"
            )
    if len(after) < len(before) or after[: len(before)] != before:
        raise MissingPerformanceMetric(
            f"{RENDER_SAMPLE_FIELD} must be cumulative and prefix-stable"
        )
    samples = after[len(before) :]
    if not all(
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
        and value >= 0.0
        for value in samples
    ):
        raise MissingPerformanceMetric(
            f"{RENDER_SAMPLE_FIELD} contains an invalid duration"
        )
    return tuple(float(value) for value in samples)


def evaluate(measurement):
    if measurement.backend not in POLICIES:
        raise ValueError(f"unknown performance backend: {measurement.backend}")
    if measurement.target_fps <= 0.0:
        raise ValueError("target FPS must be positive")
    if measurement.elapsed_seconds <= 0.0:
        raise ValueError("elapsed measurement window must be positive")
    if measurement.frames <= 0:
        raise ValueError("measurement requires rendered frames")
    if len(measurement.render_milliseconds) != measurement.frames:
        raise ValueError(
            "render sample count must equal frames in the measured window"
        )

    policy = POLICIES[measurement.backend]
    frame_budget = 1000.0 / measurement.target_fps
    achieved_fps = measurement.frames / measurement.elapsed_seconds
    fps_floor = measurement.target_fps * policy.achieved_fps_fraction
    p95 = percentile(measurement.render_milliseconds, 0.95)
    p95_limit = frame_budget * policy.p95_budget_fraction
    maximum = max(measurement.render_milliseconds)
    maximum_limit = frame_budget * policy.maximum_budget_multiple
    missed_limit = math.ceil(
        measurement.frames * policy.missed_interval_fraction
    )

    failures = []
    if not MINIMUM_WINDOW_SECONDS <= measurement.elapsed_seconds <= MAXIMUM_WINDOW_SECONDS:
        failures.append(
            f"measurement window {measurement.elapsed_seconds:.3f}s is outside "
            f"{MINIMUM_WINDOW_SECONDS:.0f}-{MAXIMUM_WINDOW_SECONDS:.0f}s"
        )
    if achieved_fps < fps_floor:
        failures.append(
            f"achieved FPS {achieved_fps:.3f} is below {fps_floor:.3f}"
        )
    if p95 > p95_limit:
        failures.append(
            f"p95 render {p95:.3f}ms exceeds {p95_limit:.3f}ms"
        )
    if maximum > maximum_limit:
        failures.append(
            f"maximum render {maximum:.3f}ms exceeds {maximum_limit:.3f}ms"
        )
    if measurement.missed_intervals > missed_limit:
        failures.append(
            f"missed intervals {measurement.missed_intervals} exceed {missed_limit}"
        )

    return PerformanceVerdict(
        passed=not failures,
        failures=tuple(failures),
        achieved_fps=achieved_fps,
        fps_floor=fps_floor,
        p95_render_milliseconds=p95,
        p95_limit_milliseconds=p95_limit,
        maximum_render_milliseconds=maximum,
        maximum_limit_milliseconds=maximum_limit,
        missed_interval_limit=missed_limit,
        resident_kib=measurement.resident_kib,
        cpu_percent=measurement.cpu_percent,
    )


def report(measurement, verdict):
    return {
        "backend": measurement.backend,
        "targetFPS": measurement.target_fps,
        "windowSeconds": measurement.elapsed_seconds,
        "frames": measurement.frames,
        "achievedFPS": verdict.achieved_fps,
        "achievedFPSFloor": verdict.fps_floor,
        "p95RenderMilliseconds": verdict.p95_render_milliseconds,
        "p95RenderLimitMilliseconds": verdict.p95_limit_milliseconds,
        "maximumRenderMilliseconds": verdict.maximum_render_milliseconds,
        "maximumRenderLimitMilliseconds": verdict.maximum_limit_milliseconds,
        "missedFrameIntervals": measurement.missed_intervals,
        "missedFrameIntervalLimit": verdict.missed_interval_limit,
        "residentKiB": verdict.resident_kib,
        "cpuPercent": verdict.cpu_percent,
        "passed": verdict.passed,
        "failures": list(verdict.failures),
    }
