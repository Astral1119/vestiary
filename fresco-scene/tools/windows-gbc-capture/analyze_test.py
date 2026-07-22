#!/usr/bin/env python3

import csv
import json
import os
import subprocess
import sys
import tempfile


ROOT = os.path.dirname(os.path.abspath(__file__))
ANALYZER = os.path.join(ROOT, "analyze.py")
SCENE_SHA256 = "4bac6871f95380c374653c44a903538cfa841a8d17abe310a092543dd9ac6ac1"


def synthetic_frames(width, height, frames, fps):
    result = bytearray()
    for frame in range(frames):
        seconds = frame / fps
        box_x = 5 if seconds < 3 or seconds >= 9 else 20 if seconds < 6 else 10
        pixels = bytearray(width * height)
        for y in range(40, 55):
            for x in range(box_x + 40, box_x + 50):
                pixels[y * width + x] = 255
        result.extend(pixels)
    return result


with tempfile.TemporaryDirectory(prefix="gbc-capture-analysis-test.") as temporary:
    width = 160
    height = 120
    fps = 60
    duration = 10
    frames = fps * duration
    video = os.path.join(temporary, "capture.mkv")
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-y",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "gray",
            "-video_size",
            f"{width}x{height}",
            "-framerate",
            str(fps),
            "-i",
            "-",
            "-c:v",
            "ffv1",
            "-level",
            "3",
            video,
        ],
        input=synthetic_frames(width, height, frames, fps),
        check=True,
    )

    with open(os.path.join(temporary, "presentmon.csv"), "w", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["Application", "CPUStartQPCTime", "MsBetweenPresents"],
        )
        writer.writeheader()
        for frame in range(frames):
            writer.writerow(
                {
                    "Application": "wallpaper64.exe",
                    "CPUStartQPCTime": frame * 1000 / fps,
                    "MsBetweenPresents": 1000 / fps,
                }
            )

    with open(os.path.join(temporary, "events.csv"), "w", newline="") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=["elapsedMilliseconds", "kind", "x", "y"]
        )
        writer.writeheader()
        for milliseconds, kind, x in (
            (0, "capture-start-center", 80),
            (3000, "step-left", 32),
            (6000, "step-right", 128),
            (9000, "step-center", 80),
        ):
            writer.writerow(
                {
                    "elapsedMilliseconds": milliseconds,
                    "kind": kind,
                    "x": x,
                    "y": 60,
                }
            )

    for name in (
        "ffmpeg.log",
        "ffmpeg-transcode.log",
        "presentmon.log",
        "presentmon-error.log",
    ):
        with open(os.path.join(temporary, name), "w", encoding="utf-8"):
            pass

    metadata = {
        "schemaVersion": 1,
        "wallpaperID": "3448290956",
        "scenePackage": {
            "path": "C:\\fixture\\scene.pkg",
            "sha256": SCENE_SHA256,
            "bytes": 15208836,
        },
        "trial": "cursor-step",
        "requestedWallpaperFps": 60,
        "requestedCaptureFps": 60,
        "captureBackend": "ddagrab",
        "durationSeconds": duration,
        "desktop": {"x": 0, "y": 0, "width": width, "height": height},
        "capture": {"x": 0, "y": 0, "width": width, "height": height},
        "roi": {"x": 40, "y": 30, "width": 40, "height": 50},
        "processName": "wallpaper64.exe",
        "files": {
            "video": "capture.mkv",
            "presentMon": "presentmon.csv",
            "events": "events.csv",
            "ffmpegLog": "ffmpeg.log",
            "ffmpegTranscodeLog": "ffmpeg-transcode.log",
            "presentMonLog": "presentmon.log",
            "presentMonErrorLog": "presentmon-error.log",
        },
        "host": {
            "capturedAtUtc": "2026-07-21T00:00:00Z",
            "computerName": "fixture",
            "os": "Windows fixture",
            "videoControllers": [{"name": "fixture GPU"}],
        },
        "tools": {
            "ffmpeg": "fixture",
            "ffprobe": "fixture",
            "presentMon": "fixture",
        },
    }
    with open(os.path.join(temporary, "capture.json"), "w", encoding="utf-8") as handle:
        json.dump(metadata, handle)

    result = subprocess.run(
        [sys.executable, ANALYZER, temporary],
        check=True,
        capture_output=True,
        text=True,
    )
    analysis = json.load(open(os.path.join(temporary, "analysis.json"), encoding="utf-8"))
    assert analysis["accepted"] is True, analysis
    assert analysis["video"]["codec"] == "ffv1", analysis
    assert analysis["video"]["frameCount"] == frames, analysis
    assert analysis["video"]["timestampedFrames"] == frames, analysis
    assert analysis["video"]["timestampRegressions"] == 0, analysis
    assert analysis["presentMon"]["frames"] == frames, analysis
    assert len(analysis["motion"]["responses"]) == 3, analysis
    assert analysis["motion"]["maximumPreviousMeanAbsoluteDifference"] > 1, analysis
    assert set(analysis["evidenceSha256"]) == {
        "capture.json",
        "capture.mkv",
        "presentmon.csv",
        "events.csv",
        "ffmpeg.log",
        "ffmpeg-transcode.log",
        "presentmon.log",
        "presentmon-error.log",
        "motion.csv",
    }, analysis
    print(result.stdout.strip())

    del metadata["captureBackend"]
    with open(os.path.join(temporary, "capture.json"), "w", encoding="utf-8") as handle:
        json.dump(metadata, handle)
    rejected = subprocess.run(
        [sys.executable, ANALYZER, temporary],
        capture_output=True,
        text=True,
    )
    assert rejected.returncode != 0, rejected
    assert "missing required fields" in rejected.stderr, rejected
    print("GBC capture analyzer test passed")
