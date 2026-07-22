#!/usr/bin/env python3

import argparse
import csv
import hashlib
import json
import math
import os
import statistics
import subprocess
import sys


EXPECTED_WALLPAPER_ID = "3448290956"
EXPECTED_SCENE_SHA256 = (
    "4bac6871f95380c374653c44a903538cfa841a8d17abe310a092543dd9ac6ac1"
)
EXPECTED_EVENTS = {
    "idle": ["capture-start-center"],
    "cursor-step": [
        "capture-start-center",
        "step-left",
        "step-right",
        "step-center",
    ],
    "cursor-sweep": [
        "capture-start-center",
        "sweep-start",
        "sweep-end-center",
    ],
}
EXPECTED_FILES = {
    "video": "capture.mkv",
    "presentMon": "presentmon.csv",
    "events": "events.csv",
    "ffmpegLog": "ffmpeg.log",
    "ffmpegTranscodeLog": "ffmpeg-transcode.log",
    "presentMonLog": "presentmon.log",
    "presentMonErrorLog": "presentmon-error.log",
}


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Validate and reduce one GBC Windows reference capture."
    )
    parser.add_argument("capture_directory")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--ffprobe", default="ffprobe")
    return parser.parse_args()


def read_json(path):
    with open(path, encoding="utf-8-sig") as handle:
        return json.load(handle)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require(condition, message, errors):
    if not condition:
        errors.append(message)


def finite_number(value):
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def validate_metadata(metadata, errors):
    required = {
        "schemaVersion",
        "wallpaperID",
        "scenePackage",
        "trial",
        "requestedWallpaperFps",
        "requestedCaptureFps",
        "captureBackend",
        "durationSeconds",
        "desktop",
        "capture",
        "roi",
        "processName",
        "files",
        "host",
        "tools",
    }
    require(isinstance(metadata, dict), "capture.json must contain an object", errors)
    if not isinstance(metadata, dict):
        return
    require(required <= metadata.keys(), "capture.json is missing required fields", errors)
    require(metadata.get("schemaVersion") == 1, "unsupported capture schema", errors)
    require(
        metadata.get("wallpaperID") == EXPECTED_WALLPAPER_ID,
        "capture is not GBC Subaru",
        errors,
    )
    package = metadata.get("scenePackage", {})
    if not isinstance(package, dict):
        package = {}
    require(
        package.get("sha256") == EXPECTED_SCENE_SHA256,
        "scene.pkg hash does not match the pinned GBC package",
        errors,
    )
    trial = metadata.get("trial")
    require(trial in EXPECTED_EVENTS, "unknown capture trial", errors)
    require(
        metadata.get("requestedWallpaperFps") in (30, 60, 120),
        "Wallpaper Engine FPS must be 30, 60, or 120",
        errors,
    )
    require(
        isinstance(metadata.get("requestedCaptureFps"), int)
        and 60 <= metadata["requestedCaptureFps"] <= 240,
        "capture FPS lies outside 60 through 240",
        errors,
    )
    require(
        metadata.get("captureBackend") in ("ddagrab", "gdigrab"),
        "unknown capture backend",
        errors,
    )
    require(
        finite_number(metadata.get("durationSeconds"))
        and 10 <= metadata["durationSeconds"] <= 30,
        "capture duration lies outside 10 through 30 seconds",
        errors,
    )
    for name in ("desktop", "capture", "roi"):
        rectangle = metadata.get(name, {})
        if not isinstance(rectangle, dict):
            rectangle = {}
        require(
            all(isinstance(rectangle.get(field), int) for field in ("x", "y", "width", "height"))
            and rectangle.get("x", -1) >= 0
            and rectangle.get("y", -1) >= 0
            and rectangle.get("width", 0) > 0
            and rectangle.get("height", 0) > 0,
            f"{name} must be a positive integer rectangle",
            errors,
        )
    require(
        metadata.get("files") == EXPECTED_FILES,
        "capture file manifest does not match schema version 1",
        errors,
    )


def parse_ratio(value):
    numerator, denominator = value.split("/", 1)
    denominator_value = float(denominator)
    if denominator_value == 0:
        return 0.0
    return float(numerator) / denominator_value


def probe_video(ffprobe, path):
    result = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-count_frames",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_name,width,height,pix_fmt,avg_frame_rate,r_frame_rate,nb_read_frames,duration:format=duration,format_name:frame=best_effort_timestamp_time,pkt_dts_time",
            "-of",
            "json",
            path,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)
    stream = payload["streams"][0]
    frame_rate = parse_ratio(stream.get("avg_frame_rate", "0/1"))
    if frame_rate <= 0:
        frame_rate = parse_ratio(stream.get("r_frame_rate", "0/1"))
    duration = float(stream.get("duration") or payload["format"].get("duration") or 0)
    frame_count = int(stream.get("nb_read_frames") or round(duration * frame_rate))
    timestamps = []
    for frame in payload.get("frames", []):
        value = frame.get("best_effort_timestamp_time")
        if value in (None, "N/A"):
            value = frame.get("pkt_dts_time")
        try:
            timestamp = float(value)
        except (TypeError, ValueError):
            continue
        if math.isfinite(timestamp):
            timestamps.append(timestamp)
    timestamp_regressions = sum(
        current + 1e-9 < previous
        for previous, current in zip(timestamps, timestamps[1:])
    )
    return {
        "codec": stream.get("codec_name"),
        "pixelFormat": stream.get("pix_fmt"),
        "width": int(stream["width"]),
        "height": int(stream["height"]),
        "frameRate": frame_rate,
        "frameCount": frame_count,
        "durationSeconds": duration,
        "container": payload["format"].get("format_name"),
        "timestampedFrames": len(timestamps),
        "timestampRegressions": timestamp_regressions,
        "firstTimestampSeconds": timestamps[0] if timestamps else None,
        "lastTimestampSeconds": timestamps[-1] if timestamps else None,
        "_frameTimestampsSeconds": timestamps,
    }


def read_events(path, trial, errors):
    with open(path, encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    events = []
    for row in rows:
        try:
            event = {
                "elapsedMilliseconds": float(row["elapsedMilliseconds"]),
                "kind": row["kind"],
                "x": int(row["x"]),
                "y": int(row["y"]),
            }
        except (KeyError, TypeError, ValueError):
            errors.append("events.csv contains an invalid row")
            continue
        if events and event["elapsedMilliseconds"] < events[-1]["elapsedMilliseconds"]:
            errors.append("events.csv timestamps regress")
        events.append(event)
    meaningful = [
        event["kind"] for event in events if event["kind"] != "sweep-sample"
    ]
    require(
        meaningful == EXPECTED_EVENTS.get(trial, []),
        f"{trial} event sequence is incomplete",
        errors,
    )
    return events


def first_float(row, names):
    for name in names:
        value = row.get(name)
        if value not in (None, "", "NA"):
            try:
                return float(value)
            except ValueError:
                pass
    return None


def read_presentmon(path, process_name, errors):
    with open(path, encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    filtered = [
        row
        for row in rows
        if row.get("Application", "").casefold() == process_name.casefold()
    ]
    require(bool(filtered), f"PresentMon contains no {process_name} frames", errors)
    starts = [
        first_float(
            row,
            ("CPUStartQPCTime", "CPUStartTime", "AnimationTime"),
        )
        for row in filtered
    ]
    starts = [value for value in starts if value is not None]
    intervals = [
        first_float(
            row,
            ("MsBetweenDisplayChange", "MsBetweenPresents", "MsBetweenAppStart"),
        )
        for row in filtered
    ]
    intervals = [value for value in intervals if value is not None and value >= 0]
    span = max(starts) - min(starts) if len(starts) >= 2 else sum(intervals) / 1000.0
    if len(starts) >= 2 and span > 1000:
        span /= 1000.0
    return {
        "frames": len(filtered),
        "spanSeconds": span,
        "medianFrameIntervalMilliseconds": (
            statistics.median(intervals) if intervals else None
        ),
        "p95FrameIntervalMilliseconds": (
            sorted(intervals)[min(len(intervals) - 1, math.ceil(len(intervals) * 0.95) - 1)]
            if intervals
            else None
        ),
    }


def frame_metrics(current, reference, previous, width, height):
    reference_total = 0
    previous_total = 0
    weighted_x = 0
    weighted_y = 0
    for index, value in enumerate(current):
        reference_difference = abs(value - reference[index])
        previous_difference = abs(value - previous[index])
        reference_total += reference_difference
        previous_total += previous_difference
        weighted_x += (index % width) * reference_difference
        weighted_y += (index // width) * reference_difference
    pixels = width * height
    return {
        "referenceMeanAbsoluteDifference": reference_total / pixels,
        "previousMeanAbsoluteDifference": previous_total / pixels,
        "differenceCentroidX": weighted_x / reference_total if reference_total else None,
        "differenceCentroidY": weighted_y / reference_total if reference_total else None,
    }


def analyze_motion(ffmpeg, video, roi, video_info, motion_path):
    source_width = roi["width"]
    source_height = roi["height"]
    scale = min(1.0, 160.0 / source_width, 160.0 / source_height)
    width = max(1, round(source_width * scale))
    height = max(1, round(source_height * scale))
    frame_bytes = width * height
    filter_value = (
        f"crop={source_width}:{source_height}:{roi['x']}:{roi['y']},"
        f"scale={width}:{height}:flags=area,format=gray"
    )
    process = subprocess.Popen(
        [
            ffmpeg,
            "-v",
            "error",
            "-i",
            video,
            "-vf",
            filter_value,
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
    frame_rate = video_info["frameRate"]
    timestamps = video_info["_frameTimestampsSeconds"]
    first_timestamp = timestamps[0] if timestamps else 0.0
    reference_index = max(1, round(frame_rate))
    frames = []
    previous = None
    reference = None
    index = 0
    while True:
        raw = process.stdout.read(frame_bytes)
        if not raw:
            break
        if len(raw) != frame_bytes:
            process.kill()
            raise RuntimeError("FFmpeg returned a truncated ROI frame")
        current = memoryview(raw)
        if index == reference_index:
            reference = bytes(raw)
        if reference is not None and previous is not None:
            values = frame_metrics(current, reference, previous, width, height)
        else:
            values = {
                "referenceMeanAbsoluteDifference": 0.0,
                "previousMeanAbsoluteDifference": 0.0,
                "differenceCentroidX": None,
                "differenceCentroidY": None,
            }
        frames.append(
            {
                "frame": index,
                "seconds": (
                    timestamps[index] - first_timestamp
                    if index < len(timestamps)
                    else index / frame_rate
                ),
                **values,
            }
        )
        previous = bytes(raw)
        index += 1
    stderr = process.stderr.read().decode("utf-8", errors="replace")
    return_code = process.wait()
    if return_code != 0:
        raise RuntimeError(f"FFmpeg ROI decode failed: {stderr.strip()}")

    fields = [
        "frame",
        "seconds",
        "referenceMeanAbsoluteDifference",
        "previousMeanAbsoluteDifference",
        "differenceCentroidX",
        "differenceCentroidY",
    ]
    with open(motion_path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(frames)
    return frames, {"width": width, "height": height}


def motion_summary(frames, events, trial, frame_rate):
    one_second = max(1, round(frame_rate))
    baseline_end = min(len(frames), 2 * one_second)
    baseline_values = [
        frame["previousMeanAbsoluteDifference"]
        for frame in frames[one_second:baseline_end]
    ] or [0.0]
    baseline_median = statistics.median(baseline_values)
    baseline_mad = statistics.median(
        abs(value - baseline_median) for value in baseline_values
    )
    threshold = max(0.25, baseline_median + 8 * max(baseline_mad, 0.01))

    meaningful_events = [
        event for event in events if event["kind"] not in ("capture-start-center", "sweep-sample")
    ]
    responses = []
    for event in meaningful_events:
        start = max(0, round(event["elapsedMilliseconds"] * frame_rate / 1000.0))
        end = min(len(frames), start + 2 * one_second)
        window = frames[start:end]
        if not window:
            continue
        peak = max(window, key=lambda value: value["previousMeanAbsoluteDifference"])
        onset = next(
            (
                value
                for value in window
                if value["previousMeanAbsoluteDifference"] > threshold
            ),
            None,
        )
        responses.append(
            {
                "kind": event["kind"],
                "eventMilliseconds": event["elapsedMilliseconds"],
                "peakPreviousMeanAbsoluteDifference": peak[
                    "previousMeanAbsoluteDifference"
                ],
                "peakDelayMilliseconds": max(
                    0.0, peak["seconds"] * 1000 - event["elapsedMilliseconds"]
                ),
                "onsetDelayMilliseconds": (
                    max(0.0, onset["seconds"] * 1000 - event["elapsedMilliseconds"])
                    if onset
                    else None
                ),
            }
        )
    return {
        "trial": trial,
        "baselinePreviousDifferenceMedian": baseline_median,
        "baselinePreviousDifferenceMAD": baseline_mad,
        "localResponseThreshold": threshold,
        "maximumReferenceMeanAbsoluteDifference": max(
            frame["referenceMeanAbsoluteDifference"] for frame in frames
        ),
        "maximumPreviousMeanAbsoluteDifference": max(
            frame["previousMeanAbsoluteDifference"] for frame in frames
        ),
        "responses": responses,
    }


def main():
    arguments = parse_arguments()
    capture_directory = os.path.abspath(arguments.capture_directory)
    metadata_path = os.path.join(capture_directory, "capture.json")
    if not os.path.isfile(metadata_path):
        raise SystemExit(f"capture metadata missing: {metadata_path}")
    metadata = read_json(metadata_path)
    errors = []
    warnings = []
    validate_metadata(metadata, errors)
    if errors:
        raise SystemExit("invalid capture metadata: " + "; ".join(errors))

    paths = {
        name: os.path.join(capture_directory, filename)
        for name, filename in metadata["files"].items()
    }
    for name in (
        "video",
        "presentMon",
        "events",
        "ffmpegLog",
        "ffmpegTranscodeLog",
        "presentMonLog",
        "presentMonErrorLog",
    ):
        require(os.path.isfile(paths[name]), f"missing {paths[name]}", errors)
    if errors:
        raise SystemExit("invalid capture: " + "; ".join(errors))

    video_info = probe_video(arguments.ffprobe, paths["video"])
    desktop = metadata["desktop"]
    capture = metadata["capture"]
    roi = metadata["roi"]
    require(video_info["codec"] == "ffv1", "capture video is not FFV1", errors)
    require(
        video_info["timestampedFrames"] >= video_info["frameCount"] * 0.95,
        "FFprobe returned timestamps for fewer than 95 percent of video frames",
        errors,
    )
    require(
        video_info["timestampRegressions"] == 0,
        "video frame timestamps regress",
        errors,
    )
    require(
        (video_info["width"], video_info["height"])
        == (capture["width"], capture["height"]),
        "capture dimensions do not match capture.json",
        errors,
    )
    require(
        capture["x"] + capture["width"] <= desktop["width"]
        and capture["y"] + capture["height"] <= desktop["height"],
        "capture rectangle lies outside the desktop",
        errors,
    )
    require(
        roi["x"] >= capture["x"]
        and roi["y"] >= capture["y"]
        and roi["x"] + roi["width"] <= capture["x"] + capture["width"]
        and roi["y"] + roi["height"] <= capture["y"] + capture["height"],
        "ROI lies outside the capture rectangle",
        errors,
    )
    expected_frames = (
        metadata["requestedCaptureFps"] * metadata["durationSeconds"]
    )
    require(
        video_info["frameCount"] >= expected_frames * 0.95,
        "video contains fewer than 95 percent of requested frames",
        errors,
    )
    if abs(video_info["frameRate"] - metadata["requestedCaptureFps"]) > 0.5:
        warnings.append("video average frame rate differs from the capture request")

    events = read_events(paths["events"], metadata["trial"], errors)
    present_mon = read_presentmon(paths["presentMon"], metadata["processName"], errors)
    require(
        present_mon["spanSeconds"] >= video_info["durationSeconds"] * 0.9,
        "PresentMon covers less than 90 percent of the video duration",
        errors,
    )

    motion_path = os.path.join(capture_directory, "motion.csv")
    video_roi = dict(roi)
    video_roi["x"] -= capture["x"]
    video_roi["y"] -= capture["y"]
    frames, analysis_size = analyze_motion(
        arguments.ffmpeg,
        paths["video"],
        video_roi,
        video_info,
        motion_path,
    )
    frame_count_delta = abs(len(frames) - video_info["frameCount"])
    require(
        frame_count_delta <= max(2, round(video_info["frameCount"] * 0.01)),
        "ROI decode frame count differs materially from FFprobe",
        errors,
    )
    if frame_count_delta:
        warnings.append("ROI decode frame count differs slightly from FFprobe")
    motion = motion_summary(
        frames, events, metadata["trial"], video_info["frameRate"]
    )
    motion["analysisWidth"] = analysis_size["width"]
    motion["analysisHeight"] = analysis_size["height"]

    evidence_paths = {
        "capture.json": metadata_path,
        "motion.csv": motion_path,
    }
    evidence_paths.update(
        (filename, paths[name]) for name, filename in metadata["files"].items()
    )
    evidence_hashes = {
        name: sha256(path) for name, path in evidence_paths.items()
    }
    public_video_info = {
        name: value
        for name, value in video_info.items()
        if not name.startswith("_")
    }
    result = {
        "schemaVersion": 1,
        "accepted": not errors,
        "errors": errors,
        "warnings": warnings,
        "wallpaperID": metadata["wallpaperID"],
        "scenePackageSha256": metadata["scenePackage"]["sha256"],
        "trial": metadata["trial"],
        "requestedWallpaperFps": metadata["requestedWallpaperFps"],
        "captureBackend": metadata["captureBackend"],
        "video": public_video_info,
        "presentMon": present_mon,
        "motion": motion,
        "evidenceSha256": evidence_hashes,
    }
    analysis_path = os.path.join(capture_directory, "analysis.json")
    with open(analysis_path, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write("\n")
    if errors:
        raise SystemExit("capture rejected: " + "; ".join(errors))
    print(
        f"GBC capture accepted: {metadata['requestedWallpaperFps']} FPS "
        f"{metadata['trial']} · {video_info['frameCount']} video frames · "
        f"{present_mon['frames']} presented frames"
    )


if __name__ == "__main__":
    main()
