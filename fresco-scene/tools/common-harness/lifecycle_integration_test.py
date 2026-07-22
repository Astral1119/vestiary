#!/usr/bin/env python3

import json
import os
import pathlib
import sys
import tempfile

import adapter
import contract
import lifecycle_adapter


if len(sys.argv) != 9 or sys.argv[8] not in {"--gate", "--evidence"}:
    raise SystemExit(
        "usage: lifecycle_integration_test.py HELPER ASSETS BACKEND CANDIDATE "
        "SOURCE_MANIFEST SOURCE_SHA256_FILE BUILD_LABEL (--gate|--evidence)"
    )

helper = adapter.normalize_wrapper_path(sys.argv[1])
assets = adapter.normalize_wrapper_path(sys.argv[2])
backend = sys.argv[3]
candidate = sys.argv[4]
source_manifest = adapter.normalize_wrapper_path(sys.argv[5])
source_sha256 = pathlib.Path(sys.argv[6]).read_text(encoding="ascii").strip()

with tempfile.TemporaryDirectory(prefix="fresco-lifecycle-integration.") as value:
    store = pathlib.Path(os.path.realpath(value))
    configuration = adapter.CandidateConfiguration(
        helper_binary=helper,
        asset_root=assets,
        expected_candidate=candidate,
        expected_backend=backend,
        store_root=store,
        source_manifest=source_manifest,
        source_sha256=source_sha256,
        build_identity=sys.argv[7],
        build_commands=(
            f"cmake --build configured-{backend} --target fresco-scene",
        ),
        operator="ctest-lifecycle",
        agent_role="automation",
        timeout_seconds=30,
    )
    record, path = lifecycle_adapter.run_lifecycle(configuration)
    manifest = contract.load_json(
        adapter.WORKLOAD_ROOT
        / "resource-reload"
        / lifecycle_adapter.LIFECYCLE_MANIFEST
    )
    contract.validate_result_against_manifest(record, manifest, store)
    if not path.is_file():
        raise AssertionError(f"lifecycle record was not persisted: {path}")
    raw_artifact = next(
        artifact for artifact in record["artifacts"]
        if artifact["name"] == "lifecycle-raw-evidence"
    )
    raw_evidence = contract.load_json(store / raw_artifact["path"])
    result = {
        "purpose": record["run"]["purpose"],
        "backend": backend,
        "recordSha256": contract.canonical_hash(record),
        "accepted": record["verdict"]["accepted"],
        "iterations": record["lifecycle"]["iterations"],
        "resources": record["lifecycle"]["resources"],
        "processManifest": record["lifecycle"]["processManifest"],
        "leakTool": record["lifecycle"]["leakEvidence"]["tool"],
        "leakStatus": record["lifecycle"]["leakEvidence"]["status"],
        "matchedControlLeakCount": raw_evidence["matchedAppKitControl"][
            "leakCount"
        ],
        "failures": record["verdict"]["failures"],
    }

print(json.dumps(result, separators=(",", ":")))
if sys.argv[8] == "--gate" and not result["accepted"]:
    raise SystemExit("lifecycle acceptance gate rejected the persisted record")
