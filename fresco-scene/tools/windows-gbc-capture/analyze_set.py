#!/usr/bin/env python3

import argparse
import csv
import json
import math
import os
import statistics
import subprocess
import sys
from collections import defaultdict

from PIL import Image, ImageChops, ImageStat


EXPECTED_FPS = (30, 60, 120)
EXPECTED_TRIALS = ("idle", "cursor-step", "cursor-sweep")
GRID_WIDTH = 11
GRID_HEIGHT = 14
ANALYSIS_WIDTH = 110
ANALYSIS_HEIGHT = 140
RESPONSE_SECONDS = 2.0


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Validate and reduce one nine-trial GBC Windows reference set."
    )
    parser.add_argument("capture_directories", nargs="+")
    parser.add_argument("--output-directory", required=True)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    return parser.parse_args()


def read_json(path):
    with open(path, encoding="utf-8-sig") as handle:
        return json.load(handle)


def require(condition, message, errors):
    if not condition:
        errors.append(message)


def percentile(values, fraction):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, math.ceil(len(ordered) * fraction) - 1))
    return ordered[index]


def load_capture(directory):
    metadata = read_json(os.path.join(directory, "capture.json"))
    analysis = read_json(os.path.join(directory, "analysis.json"))
    return {
        "directory": os.path.abspath(directory),
        "metadata": metadata,
        "analysis": analysis,
        "key": (metadata.get("requestedWallpaperFps"), metadata.get("trial")),
    }


def comparable_host(metadata):
    host = metadata.get("host", {})
    return {
        "computerName": host.get("computerName"),
        "os": host.get("os"),
        "videoControllers": host.get("videoControllers"),
    }


def validate_set(captures):
    errors = []
    warnings = []
    by_key = defaultdict(list)
    for capture in captures:
        by_key[capture["key"]].append(capture)
        require(
            capture["analysis"].get("accepted") is True,
            f"{os.path.basename(capture['directory'])} was not accepted by analyze.py",
            errors,
        )

    expected = {(fps, trial) for fps in EXPECTED_FPS for trial in EXPECTED_TRIALS}
    actual = set(by_key)
    for key in sorted(expected - actual):
        errors.append(f"missing {key[0]} FPS {key[1]} trial")
    for key in sorted(actual - expected):
        errors.append(f"unexpected {key[0]} FPS {key[1]} trial")
    for key, values in sorted(by_key.items()):
        if len(values) != 1:
            errors.append(f"expected one {key[0]} FPS {key[1]} trial; found {len(values)}")

    if not captures:
        return errors, warnings
    first = captures[0]
    shared_fields = {
        "wallpaperID": first["metadata"].get("wallpaperID"),
        "scenePackageSha256": first["metadata"].get("scenePackage", {}).get("sha256"),
        "desktop": first["metadata"].get("desktop"),
        "capture": first["metadata"].get("capture"),
        "roi": first["metadata"].get("roi"),
        "host": comparable_host(first["metadata"]),
    }
    for capture in captures[1:]:
        metadata = capture["metadata"]
        values = {
            "wallpaperID": metadata.get("wallpaperID"),
            "scenePackageSha256": metadata.get("scenePackage", {}).get("sha256"),
            "desktop": metadata.get("desktop"),
            "capture": metadata.get("capture"),
            "roi": metadata.get("roi"),
            "host": comparable_host(metadata),
        }
        for name, expected_value in shared_fields.items():
            require(
                values[name] == expected_value,
                f"{os.path.basename(capture['directory'])} has inconsistent {name}",
                errors,
            )

    backends = sorted({capture["analysis"].get("captureBackend") for capture in captures})
    if len(backends) > 1:
        warnings.append("capture set mixes backends: " + ", ".join(backends))

    for fps in EXPECTED_FPS:
        trials = [capture for capture in captures if capture["key"][0] == fps]
        intervals = [
            capture["analysis"].get("presentMon", {}).get("medianFrameIntervalMilliseconds")
            for capture in trials
        ]
        intervals = [value for value in intervals if isinstance(value, (int, float))]
        if intervals:
            expected_interval = 1000.0 / fps
            require(
                all(
                    abs(value - expected_interval) <= expected_interval * 0.2
                    for value in intervals
                ),
                f"{fps} FPS PresentMon medians differ from the requested "
                "limit by more than 20 percent",
                errors,
            )
    return errors, warnings


def decode_video(ffmpeg, path):
    process = subprocess.Popen(
        [
            ffmpeg,
            "-v",
            "error",
            "-i",
            path,
            "-vf",
            f"scale={ANALYSIS_WIDTH}:{ANALYSIS_HEIGHT}:flags=area,format=gray",
            "-fps_mode",
            "passthrough",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "gray",
            "-",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    frame_bytes = ANALYSIS_WIDTH * ANALYSIS_HEIGHT
    frames = []
    while True:
        raw = process.stdout.read(frame_bytes)
        if not raw:
            break
        if len(raw) != frame_bytes:
            process.kill()
            raise RuntimeError(f"FFmpeg returned a truncated frame for {path}")
        frames.append(Image.frombytes("L", (ANALYSIS_WIDTH, ANALYSIS_HEIGHT), raw))
    stderr = process.stderr.read().decode("utf-8", errors="replace")
    return_code = process.wait()
    if return_code != 0:
        raise RuntimeError(f"FFmpeg decode failed for {path}: {stderr.strip()}")
    return frames


def tile_values(current, reference):
    difference = ImageChops.difference(current, reference)
    grid = difference.resize((GRID_WIDTH, GRID_HEIGHT), Image.Resampling.BOX)
    return list(grid.get_flattened_data()), difference


def read_events(path):
    with open(path, encoding="utf-8-sig", newline="") as handle:
        return [
            {
                "milliseconds": float(row["elapsedMilliseconds"]),
                "kind": row["kind"],
            }
            for row in csv.DictReader(handle)
            if row["kind"] not in ("capture-start-center", "sweep-sample")
        ]


def idle_tile_floor(frames, frame_rate):
    values = [[] for _ in range(GRID_WIDTH * GRID_HEIGHT)]
    for index in range(max(1, round(frame_rate)), len(frames)):
        tiles, _ = tile_values(frames[index], frames[index - 1])
        for tile_index, value in enumerate(tiles):
            values[tile_index].append(value)
    return [percentile(samples, 0.99) for samples in values]


def changed_centroid(difference, selected):
    mask = Image.new("L", difference.size)
    pixels = mask.load()
    cell_width = ANALYSIS_WIDTH // GRID_WIDTH
    cell_height = ANALYSIS_HEIGHT // GRID_HEIGHT
    for index in selected:
        cell_x = index % GRID_WIDTH
        cell_y = index // GRID_WIDTH
        for y in range(cell_y * cell_height, (cell_y + 1) * cell_height):
            for x in range(cell_x * cell_width, (cell_x + 1) * cell_width):
                pixels[x, y] = 255
    localized = ImageChops.multiply(difference, mask)
    total = ImageStat.Stat(localized).sum[0]
    if not total:
        return None, None
    x_projection = localized.resize((ANALYSIS_WIDTH, 1), Image.Resampling.BOX)
    y_projection = localized.resize((1, ANALYSIS_HEIGHT), Image.Resampling.BOX)
    xs = list(x_projection.get_flattened_data())
    ys = list(y_projection.get_flattened_data())
    x_total = sum(xs)
    y_total = sum(ys)
    return (
        sum(index * value for index, value in enumerate(xs)) / x_total if x_total else None,
        sum(index * value for index, value in enumerate(ys)) / y_total if y_total else None,
    )


def event_response(frames, frame_rate, event, idle_floor):
    event_frame = min(len(frames) - 1, max(1, round(event["milliseconds"] * frame_rate / 1000.0)))
    reference = frames[event_frame - 1]
    end = min(len(frames), event_frame + round(RESPONSE_SECONDS * frame_rate))
    samples = []
    peaks = [0.0] * (GRID_WIDTH * GRID_HEIGHT)
    raw = []
    for frame_index in range(event_frame, end):
        tiles, difference = tile_values(frames[frame_index], reference)
        peaks = [max(old, value) for old, value in zip(peaks, tiles)]
        raw.append((frame_index, tiles, difference))

    ranked = sorted(
        range(len(peaks)),
        key=lambda index: peaks[index] - idle_floor[index],
        reverse=True,
    )
    selected = [
        index
        for index in ranked
        if peaks[index] >= max(2.0, idle_floor[index] * 2.0 + 1.0)
    ][:12]
    if not selected:
        selected = ranked[:4]

    noise_floor = max(1.0, statistics.mean(idle_floor[index] for index in selected))
    threshold = noise_floor * 1.5 + 1.0
    for frame_index, tiles, difference in raw:
        displacement = statistics.mean(tiles[index] for index in selected)
        centroid_x, centroid_y = changed_centroid(difference, selected)
        samples.append(
            {
                "frame": frame_index,
                "delayMilliseconds": (frame_index - event_frame) * 1000.0 / frame_rate,
                "localizedDisplacement": displacement,
                "differenceCentroidX": centroid_x,
                "differenceCentroidY": centroid_y,
            }
        )

    peak = max(samples, key=lambda sample: sample["localizedDisplacement"])
    onset = next(
        (
            samples[index]
            for index in range(max(0, len(samples) - 1))
            if samples[index]["localizedDisplacement"] > threshold
            and samples[index + 1]["localizedDisplacement"] > threshold
        ),
        None,
    )
    tail_count = max(1, round(frame_rate / 4))
    residual = statistics.median(
        sample["localizedDisplacement"] for sample in samples[-tail_count:]
    )
    cell_width = ANALYSIS_WIDTH // GRID_WIDTH
    cell_height = ANALYSIS_HEIGHT // GRID_HEIGHT
    selected_cells = [
        {
            "x": (index % GRID_WIDTH) * cell_width,
            "y": (index // GRID_WIDTH) * cell_height,
            "width": cell_width,
            "height": cell_height,
            "peakDifference": peaks[index],
            "idleP99Difference": idle_floor[index],
        }
        for index in selected
    ]
    return {
        "kind": event["kind"],
        "eventMilliseconds": event["milliseconds"],
        "idleAdjacentDifferenceP99": noise_floor,
        "responseThreshold": threshold,
        "responseDetected": onset is not None,
        "thresholdCrossingDelayMilliseconds": (
            onset["delayMilliseconds"] if onset else None
        ),
        "peakDelayMilliseconds": peak["delayMilliseconds"],
        "peakLocalizedDisplacement": peak["localizedDisplacement"],
        "peakToIdleAdjacentNoise": peak["localizedDisplacement"] / max(noise_floor, 0.01),
        "residualLocalizedDisplacement": residual,
        "residualToPeak": residual / max(peak["localizedDisplacement"], 0.01),
        "responsiveCells": selected_cells,
        "samples": samples,
    }


def analyze_fps_set(ffmpeg, captures):
    by_trial = {capture["key"][1]: capture for capture in captures}
    frame_rate = by_trial["idle"]["analysis"]["video"]["frameRate"]
    decoded = {}
    for trial, capture in by_trial.items():
        video = os.path.join(
            capture["directory"], capture["metadata"]["files"]["video"]
        )
        decoded[trial] = decode_video(ffmpeg, video)
    idle_floor = idle_tile_floor(decoded["idle"], frame_rate)
    responses = {}
    rows = []
    for trial in ("cursor-step", "cursor-sweep"):
        capture = by_trial[trial]
        events_path = os.path.join(
            capture["directory"], capture["metadata"]["files"]["events"]
        )
        trial_responses = [
            event_response(decoded[trial], frame_rate, event, idle_floor)
            for event in read_events(events_path)
        ]
        responses[trial] = trial_responses
        for response in trial_responses:
            for sample in response.pop("samples"):
                rows.append(
                    {
                        "wallpaperFps": capture["key"][0],
                        "trial": trial,
                        "event": response["kind"],
                        **sample,
                    }
                )
    present_intervals = [
        capture["analysis"]["presentMon"]["medianFrameIntervalMilliseconds"]
        for capture in captures
    ]
    return {
        "presentedFpsMedian": 1000.0 / statistics.median(present_intervals),
        "idleAdjacentTileP99Median": statistics.median(idle_floor),
        "idleAdjacentTileP99Maximum": max(idle_floor),
        "responses": responses,
    }, rows


def write_csv(path, rows):
    fields = [
        "wallpaperFps",
        "trial",
        "event",
        "frame",
        "delayMilliseconds",
        "localizedDisplacement",
        "differenceCentroidX",
        "differenceCentroidY",
    ]
    with open(path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def main():
    arguments = parse_arguments()
    captures = [load_capture(os.path.abspath(path)) for path in arguments.capture_directories]
    errors, warnings = validate_set(captures)
    if errors:
        raise SystemExit("capture set rejected: " + "; ".join(errors))

    fps_results = {}
    rows = []
    for fps in EXPECTED_FPS:
        result, fps_rows = analyze_fps_set(
            arguments.ffmpeg, [capture for capture in captures if capture["key"][0] == fps]
        )
        fps_results[str(fps)] = result
        rows.extend(fps_rows)

    output_directory = os.path.abspath(arguments.output_directory)
    os.makedirs(output_directory, exist_ok=True)
    write_csv(os.path.join(output_directory, "set-motion.csv"), rows)
    result = {
        "schemaVersion": 1,
        "accepted": True,
        "errors": [],
        "warnings": warnings,
        "wallpaperID": captures[0]["metadata"]["wallpaperID"],
        "scenePackageSha256": captures[0]["metadata"]["scenePackage"]["sha256"],
        "desktop": captures[0]["metadata"]["desktop"],
        "capture": captures[0]["metadata"]["capture"],
        "roi": captures[0]["metadata"]["roi"],
        "analysisSize": {"width": ANALYSIS_WIDTH, "height": ANALYSIS_HEIGHT},
        "responsiveCellSize": {
            "width": ANALYSIS_WIDTH // GRID_WIDTH,
            "height": ANALYSIS_HEIGHT // GRID_HEIGHT,
        },
        "fps": fps_results,
        "captures": [
            {
                "directory": os.path.basename(capture["directory"]),
                "requestedWallpaperFps": capture["key"][0],
                "trial": capture["key"][1],
                "captureBackend": capture["analysis"].get("captureBackend"),
                "evidenceSha256": capture["analysis"].get("evidenceSha256"),
            }
            for capture in sorted(captures, key=lambda capture: capture["key"])
        ],
    }
    with open(os.path.join(output_directory, "set-analysis.json"), "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(
        "GBC capture set accepted: 9 trials · "
        + ", ".join(
            f"{fps} FPS measured {fps_results[str(fps)]['presentedFpsMedian']:.2f}"
            for fps in EXPECTED_FPS
        )
    )
    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)


if __name__ == "__main__":
    main()
