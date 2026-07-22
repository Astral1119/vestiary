#!/usr/bin/env python3

import pathlib
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops, ImageStat


RENDERER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
PERSONA = WORKSHOP / "3151551777"


def render(output, spectrum):
    result = subprocess.run(
        [RENDERER, PERSONA, ASSETS, output, "60", str(spectrum)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60,
        check=True,
    )
    assert "frames=60" in result.stdout, result.stdout
    assert "GLSL " not in result.stderr and "Failed to setup" not in result.stderr, (
        result.stderr
    )
    return Image.open(output).convert("RGB")


def total_delta(left, right):
    return sum(ImageStat.Stat(ImageChops.difference(left, right)).sum)


with tempfile.TemporaryDirectory(prefix="fresco-particle-audio-ab-") as directory:
    root = pathlib.Path(directory)
    silent_a = render(root / "silent-a.png", 0.0)
    silent_b = render(root / "silent-b.png", 0.0)
    energized = render(root / "energized.png", 1.0)
    baseline_delta = total_delta(silent_a, silent_b)
    audio_delta = total_delta(silent_a, energized)
    assert baseline_delta < 10_000, baseline_delta
    assert audio_delta > 100_000 and audio_delta > baseline_delta * 100, (
        baseline_delta,
        audio_delta,
    )

print("particle audio A/B: matched silent state is deterministic; energized state differs")
