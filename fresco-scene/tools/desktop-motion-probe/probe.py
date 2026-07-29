#!/usr/bin/env python3

"""Sample how much the live wallpaper is moving, to catch an animation stall.

Nothing in the renderer suite can see a stall that only appears after the scene
has been running a while, because the smoke tool renders a fixed frame count and
exits. This observes the presented desktop instead.

Each sample captures two frames a short interval apart and counts the pixels
that changed between them. A scene that is animating moves thousands; a stalled
one moves none. Frames minutes apart always differ, so the pair has to be close
together — the measurement is instantaneous motion, not drift.

The frame is scored in a grid as well as whole, so a stall that spares one
region is distinguishable from the whole scene freezing. That split is the
reported symptom for Elaina 3326873240, whose audio visualizer keeps working
after the rest stops.

Usage:

    tools/desktop-motion-probe/probe.py [--interval SECONDS] [--gap SECONDS]
                                        [--out DIRECTORY] [--samples N]

Writes one JSON object per sample to stdout and to `motion.jsonl` under the
output directory, plus a downscaled frame per sample for a filmstrip.
"""

import argparse
import json
import pathlib
import subprocess
import sys
import time

try:
    from PIL import Image, ImageChops
except ImportError:  # pragma: no cover - environment guidance, not logic
    sys.exit("probe requires Pillow: python3 -m pip install --user Pillow")

HERE = pathlib.Path(__file__).resolve().parent
WINDOW_SOURCE = HERE / "scene-window.swift"

# A quarter-scale frame keeps a 4K capture cheap to diff and still resolves
# single glyphs. The threshold ignores the capture pipeline's own dithering.
SCALE = 4
THRESHOLD = 8
GRID = 4


def window_resolver(build_root):
    """Compile the window-id helper on demand, the way liveryctl does."""
    binary = build_root / "scene-window"
    if not binary.exists() or WINDOW_SOURCE.stat().st_mtime > binary.stat().st_mtime:
        build_root.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["swiftc", "-O", str(WINDOW_SOURCE), "-o", str(binary)],
            check=True,
        )
    return binary


def window_id(resolver):
    return subprocess.run(
        [str(resolver)], capture_output=True, text=True, check=True
    ).stdout.strip()


def capture(path, identifier):
    subprocess.run(
        ["screencapture", "-x", "-o", "-l", identifier, str(path)],
        check=True, capture_output=True,
    )
    image = Image.open(path).convert("RGB")
    return image.resize(
        (image.width // SCALE, image.height // SCALE), Image.BILINEAR
    )


def moving_pixels(first, second):
    """Pixels differing by more than THRESHOLD, whole frame and per grid cell."""
    mask = ImageChops.difference(first, second).convert("L").point(
        lambda value: 255 if value > THRESHOLD else 0
    )
    # The mask is binary, so the 255 bucket of the histogram is the count.
    total = mask.histogram()[255]
    cells = []
    width, height = mask.width // GRID, mask.height // GRID
    for row in range(GRID):
        for column in range(GRID):
            box = (column * width, row * height,
                   (column + 1) * width, (row + 1) * height)
            cells.append(mask.crop(box).histogram()[255])
    return total, cells


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interval", type=float, default=60.0,
                        help="seconds between samples (default 60)")
    parser.add_argument("--gap", type=float, default=1.2,
                        help="seconds between the two frames of a sample")
    parser.add_argument("--out", type=pathlib.Path,
                        default=pathlib.Path("motion-probe"),
                        help="output directory")
    parser.add_argument("--samples", type=int, default=0,
                        help="stop after N samples (default: run until killed)")
    arguments = parser.parse_args()

    frames = arguments.out / "frames"
    frames.mkdir(parents=True, exist_ok=True)
    log = arguments.out / "motion.jsonl"
    resolver = window_resolver(arguments.out / "build")

    start = time.time()
    identifier = window_id(resolver)
    sample = 0
    while not arguments.samples or sample < arguments.samples:
        try:
            first = capture(frames / "_a.png", identifier)
            time.sleep(arguments.gap)
            second = capture(frames / "_b.png", identifier)
            total, cells = moving_pixels(first, second)
            first.save(frames / f"sample-{sample:04d}.png")
            record = {
                "sample": sample,
                "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "elapsedMinutes": round((time.time() - start) / 60.0, 1),
                "window": identifier,
                "movingPixels": total,
                "movingFraction": round(
                    total / float(first.width * first.height), 6
                ),
                "cells": cells,
            }
        except subprocess.CalledProcessError as error:
            # A helper restart replaces the window, so re-resolve rather than
            # ending a run that may have hours in it.
            record = {
                "sample": sample,
                "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "elapsedMinutes": round((time.time() - start) / 60.0, 1),
                "error": str(error),
            }
            try:
                identifier = window_id(resolver)
            except subprocess.CalledProcessError:
                pass
        with log.open("a") as handle:
            handle.write(json.dumps(record) + "\n")
        print(json.dumps(record), flush=True)
        sample += 1
        if arguments.samples and sample >= arguments.samples:
            break
        time.sleep(max(0.0, arguments.interval - arguments.gap))


if __name__ == "__main__":
    sys.exit(main())
