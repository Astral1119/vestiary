#!/usr/bin/env python3

import json
import os
import pathlib
import tempfile
import sys

import adapter
import contract


if len(sys.argv) != 9:
    raise SystemExit(
        "usage: integration_test.py HELPER ASSETS BACKEND CANDIDATE "
        "SOURCE_MANIFEST SOURCE_SHA256_FILE WORKLOAD MEDIA_FIXTURE_GENERATOR"
    )

helper = adapter.normalize_wrapper_path(sys.argv[1])
assets = adapter.normalize_wrapper_path(sys.argv[2])
backend = sys.argv[3]
candidate = sys.argv[4]
source_manifest = adapter.normalize_wrapper_path(sys.argv[5])
source_sha256_file = adapter.normalize_wrapper_path(sys.argv[6])
source_sha256 = source_sha256_file.read_text(encoding="ascii").strip()
workload = sys.argv[7]
media_fixture_generator = adapter.normalize_wrapper_path(sys.argv[8])

with tempfile.TemporaryDirectory(prefix="fresco-harness-integration.") as temporary:
    store = pathlib.Path(os.path.realpath(temporary))
    configuration = adapter.CandidateConfiguration(
        helper_binary=helper,
        asset_root=assets,
        expected_candidate=candidate,
        expected_backend=backend,
        store_root=store,
        source_manifest=source_manifest,
        source_sha256=source_sha256,
        build_identity=f"integration-{backend}",
        build_commands=(
            f"cmake --build configured-{backend} --target fresco-scene",
        ),
        operator="ctest-integration",
        agent_role="automation",
        media_fixture_generator=media_fixture_generator,
        timeout_seconds=30,
    )
    record, path = adapter.run_correctness(workload, configuration)
    manifest = contract.load_json(
        adapter.WORKLOAD_ROOT / workload / "manifest-v1.json"
    )
    contract.validate_result_against_manifest(record, manifest, store)
    if not path.is_file():
        raise AssertionError(f"record was not persisted: {workload}")
    result = {
        "workload": workload,
        "backend": backend,
        "recordSha256": contract.canonical_hash(record),
        "accepted": record["verdict"]["accepted"],
    }

print(json.dumps(result, separators=(",", ":")))
