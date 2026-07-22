#!/usr/bin/env python3

import os
import subprocess
import sys
import tempfile


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, "fresco")
ASSET_FILES = (
    "shaders/generic4.vert",
    "shaders/generic4.frag",
    "shaders/genericimage2.vert",
    "shaders/genericimage2.frag",
    "shaders/genericimage3.vert",
    "shaders/genericimage3.frag",
    "shaders/genericimage4.vert",
    "shaders/genericimage4.frag",
    "shaders/genericparticle.vert",
    "shaders/genericparticle.frag",
    "materials/particle/halo.tex",
)


def run(arguments, environment, check=True):
    return subprocess.run(
        [sys.executable, CLI, *arguments],
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
        check=check,
    )


with tempfile.TemporaryDirectory(prefix="fresco-scene-cli.") as temporary:
    state = os.path.join(temporary, "state")
    environment = os.environ.copy()
    environment["FRESCO_STATE_DIR"] = state
    environment["FRESCO_SCENE_INSPECTION_ONLY"] = "1"

    build = run(["scene-build"], environment)
    helper = os.path.join(state, "bin", "fresco-scene")
    assert os.access(helper, os.X_OK), (build.stdout, build.stderr)

    wallpaper_engine = os.path.join(temporary, "wallpaper_engine")
    assets = os.path.join(wallpaper_engine, "assets")
    for relative in ASSET_FILES:
        target = os.path.join(assets, relative)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as handle:
            handle.write(b"fixture")
    canonical_assets = os.path.realpath(assets)

    validation = run(["scene-assets", "validate", wallpaper_engine], environment)
    assert validation.stdout.strip() == (
        f"scene assets valid: {canonical_assets}"
    ), validation
    config = os.path.join(state, "scene-assets")
    assert not os.path.exists(config)

    setting = run(["scene-assets", "set", wallpaper_engine], environment)
    assert setting.stdout.strip() == f"scene assets set: {canonical_assets}", setting
    with open(config) as handle:
        assert handle.read().strip() == canonical_assets

    status = run(["scene-assets"], environment)
    assert status.stdout.strip() == (
        f"scene assets: valid ({canonical_assets})"
    ), status

    incomplete = os.path.join(temporary, "incomplete")
    os.makedirs(incomplete)
    rejected = run(
        ["scene-assets", "set", incomplete], environment, check=False
    )
    assert rejected.returncode != 0, rejected
    assert "missing 11 required asset(s)" in rejected.stderr, rejected
    with open(config) as handle:
        assert handle.read().strip() == canonical_assets

    cleared = run(["scene-assets", "clear"], environment)
    assert cleared.stdout.strip() == "scene assets cleared", cleared
    assert not os.path.exists(config)

print("Scene helper build and asset CLI checks passed")
