#!/usr/bin/env python3

import os
import pathlib
import sys
import tempfile


HELPER = pathlib.Path(sys.argv[1]).resolve()
ASSETS = pathlib.Path(sys.argv[2]).resolve()
HARNESS = pathlib.Path(sys.argv[3]).resolve()
EXPECTED_BACKEND = sys.argv[4]
sys.path.insert(0, os.fspath(HARNESS))

import adapter  # noqa: E402


fixture_root = HARNESS / "workloads" / "masks-effects"
resource_root = HARNESS / "workloads" / "resource-reload"
asset_identities = (
    "effect-model-json",
    "effect-base-material-json",
    "effect-graph-json",
    "effect-pass-a-material-json",
    "effect-pass-b-material-json",
    "effect-composite-material-json",
    "effect-pass-a-vertex-shader",
    "effect-pass-b-vertex-shader",
    "effect-composite-vertex-shader",
    "effect-pass-a-fragment-shader",
    "effect-pass-b-fragment-shader",
    "effect-composite-fragment-shader",
)
package_files = tuple(adapter.ASSET_FILES[item] for item in asset_identities)

with tempfile.TemporaryDirectory(prefix="fresco-invalid-shader.") as scratch_value:
    scratch = pathlib.Path(scratch_value)
    project = scratch / "invalid-project"
    project.mkdir()
    adapter._materialize_invalid_shader_variant(
        fixture_root, resource_root, project, package_files
    )
    helper = adapter.HelperProcess(
        HELPER,
        "invalid-shader-first-load",
        60,
        environment={"FRESCO_SCENE_AUDIO_DISABLED": "1"},
    )
    with helper:
        helper.exchange("hello")
        ready = helper.exchange(
            "load",
            "ready",
            path=os.fspath(project),
            assetRoot=os.fspath(ASSETS),
            width=320,
            height=180,
            fps=5,
            policyRevision=1,
            reasonTokens=["test:invalid-shader-first-load"],
            visible=True,
            muted=True,
            evidenceFrames=1,
        )
        lifecycle = ready["renderResourceLifecycle"]
        assert lifecycle["generationsCreated"] == 1, lifecycle
        assert lifecycle["generationsRetired"] == 0, lifecycle
        assert lifecycle["liveGenerations"] == 1, lifecycle
        assert lifecycle["objectSetupFailures"] == 1, lifecycle
        assert lifecycle["programPublications"] == 1, lifecycle
        assert ready["programCacheEntries"] == 1, ready
        assert ready["programCacheInsertions"] == 1, ready
        if EXPECTED_BACKEND == "native-opengl":
            assert lifecycle["programRollbacks"] == 1, lifecycle
            assert lifecycle["shaderCompileFailures"] == 0, lifecycle
        else:
            assert lifecycle["programRollbacks"] == 0, lifecycle
            assert lifecycle["shaderCompileFailures"] == 1, lifecycle
        stopped = helper.exchange("stop", "stopped")
        stopped_lifecycle = stopped["renderResourceLifecycle"]
        assert stopped_lifecycle["generationsRetired"] == 1, stopped_lifecycle
        assert stopped_lifecycle["liveGenerations"] == 0, stopped_lifecycle
        assert (
            stopped_lifecycle["programPublications"]
            == stopped_lifecycle["programDeletions"]
        ), stopped_lifecycle
