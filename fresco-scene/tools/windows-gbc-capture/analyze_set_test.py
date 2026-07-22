#!/usr/bin/env python3

import os
import sys

from PIL import Image


ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, ROOT)

import analyze_set


def make_frames(moving):
    frames = []
    for frame in range(240):
        image = Image.new("L", (analyze_set.ANALYSIS_WIDTH, analyze_set.ANALYSIS_HEIGHT))
        pixels = image.load()
        pixels[5, 5] = frame % 2
        if moving and frame >= 65:
            offset = min(20, frame - 65)
            for y in range(40, 60):
                for x in range(20 + offset, 40 + offset):
                    pixels[x, y] = 180
        frames.append(image)
    return frames


idle = make_frames(False)
moving = make_frames(True)
floor = analyze_set.idle_tile_floor(idle, 60)
response = analyze_set.event_response(
    moving,
    60,
    {"milliseconds": 1000.0, "kind": "step-left"},
    floor,
)
assert response["responseDetected"] is True, response
assert 50 <= response["thresholdCrossingDelayMilliseconds"] <= 150, response
assert response["peakLocalizedDisplacement"] > 20, response
assert any(
    cell["x"] < 60 and 30 <= cell["y"] < 70
    for cell in response["responsiveCells"]
), response


def fixture_capture(fps, trial, backend="gdigrab"):
    metadata = {
        "wallpaperID": "3448290956",
        "scenePackage": {
            "sha256": "4bac6871f95380c374653c44a903538cfa841a8d17abe310a092543dd9ac6ac1"
        },
        "requestedWallpaperFps": fps,
        "trial": trial,
        "desktop": {"x": 0, "y": 0, "width": 1920, "height": 1080},
        "capture": {"x": 10, "y": 20, "width": 220, "height": 280},
        "roi": {"x": 10, "y": 20, "width": 220, "height": 280},
        "host": {
            "computerName": "fixture",
            "os": "Windows fixture",
            "videoControllers": [{"name": "fixture GPU"}],
        },
    }
    return {
        "directory": f"/fixture/{fps}-{trial}",
        "metadata": metadata,
        "analysis": {
            "accepted": True,
            "captureBackend": backend,
            "presentMon": {"medianFrameIntervalMilliseconds": 1000 / fps},
        },
        "key": (fps, trial),
    }


captures = [
    fixture_capture(fps, trial)
    for fps in analyze_set.EXPECTED_FPS
    for trial in analyze_set.EXPECTED_TRIALS
]
errors, warnings = analyze_set.validate_set(captures)
assert errors == [], errors
assert warnings == [], warnings

captures[-1]["metadata"]["desktop"]["width"] = 1280
errors, _ = analyze_set.validate_set(captures)
assert any("inconsistent desktop" in error for error in errors), errors

print("GBC capture set analyzer test passed")
