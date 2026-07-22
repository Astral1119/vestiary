#!/usr/bin/env python3

import pathlib
import re
import subprocess
import sys
import tempfile


BASELINES = {
    "3351508588": ("cat-in-space", 120, 0, 0),
    "1568648985": ("shimmering-particles", 120, 0, 0),
    "1845706469": ("nier-automata", 120, 0, 0),
    "3402326745": ("balatro", 600, 0, 0),
    "3460973721": ("arknights", 120, 3, 1),
    "2999232230": ("clock", 120, 6, 1),
}


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: renderer_smoke_test.py RENDERER WORKSHOP_ROOT ASSET_ROOT"
        )

    renderer = pathlib.Path(sys.argv[1])
    workshop_root = pathlib.Path(sys.argv[2])
    asset_root = pathlib.Path(sys.argv[3])

    with tempfile.TemporaryDirectory(prefix="fresco-scene-render-") as directory:
        temporary_root = pathlib.Path(directory)
        for workshop_id, baseline in BASELINES.items():
            label, frame_count, expected_script_layers, minimum_script_changes = baseline
            project_root = workshop_root / workshop_id
            if not (project_root / "scene.pkg").is_file():
                raise AssertionError(f"missing pinned fixture {workshop_id}")

            output = temporary_root / f"{label}.png"
            process = subprocess.run(
                [renderer, project_root, asset_root, output, str(frame_count)],
                capture_output=True,
                check=False,
                text=True,
            )
            if process.returncode != 0:
                raise AssertionError(
                    f"{label} failed ({process.returncode})\n"
                    f"stdout:\n{process.stdout}\nstderr:\n{process.stderr}"
                )

            match = re.search(
                r"frames=(\d+) range=(\d+)-(\d+) varyingPixels=(\d+) "
                r"scriptLayers=(\d+) scriptUpdates=(\d+) scriptTextChanges=(\d+) "
                r"scriptErrors=(\d+)",
                process.stdout,
            )
            if match is None:
                raise AssertionError(f"{label} returned no pixel metrics: {process.stdout}")
            (
                frames,
                minimum,
                maximum,
                varying_pixels,
                script_layers,
                script_updates,
                script_text_changes,
                script_errors,
            ) = map(int, match.groups())
            assert frames == frame_count, (label, frames)
            assert minimum < maximum, (label, minimum, maximum)
            assert varying_pixels > 0, (label, varying_pixels)
            assert script_layers == expected_script_layers, (label, script_layers)
            assert script_updates >= expected_script_layers, (label, script_updates)
            assert script_text_changes >= minimum_script_changes, (
                label,
                script_text_changes,
            )
            assert script_errors == 0, (label, script_errors)
            assert output.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), label
            assert output.stat().st_size > 1024, (label, output.stat().st_size)

    print("renderer baselines: ok (cat, shimmering, nier, balatro, arknights, clock)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
