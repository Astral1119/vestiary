#!/usr/bin/env python3

import contextlib
import io
import json
import os
import pathlib
import sys

import generate_presentation_evidence_v2 as base
import sdl3_presentation_test_v3 as gate


HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
PRESENTATION_V2 = {
    "relationship": "supersedes",
    "path": "/Users/astral/personal/vestiary/.fresco-evidence/sdl3-presentation-scheduling-v2/evidence.tar.gz",
    "sha256": "32ab97dc379f9fc4182774839f6dfcaa09b70f8a04f25244895edeba0bdca8c6",
    "bytes": 1150069,
}
SOURCE_PATHS = [
    "CMakeLists.txt", "THIRD_PARTY.md",
    "spikes/sdl3-gpu/CMakeLists.txt", "spikes/sdl3-gpu/README.md",
    "spikes/sdl3-gpu/PresentationScheduler.h",
    "spikes/sdl3-gpu/PresentationScheduler.cpp",
    "spikes/sdl3-gpu/presentation.cpp",
    "spikes/sdl3-gpu/presentation-reference-v2.json",
    "spikes/sdl3-gpu/sdl3_presentation_test_v2.py",
    "spikes/sdl3-gpu/sdl3_presentation_test_v3.py",
    "spikes/sdl3-gpu/test_sdl3_presentation_evidence_v3.py",
    "spikes/sdl3-gpu/generate_presentation_evidence_v2.py",
    "spikes/sdl3-gpu/generate_presentation_evidence_v3.py",
    "spikes/sdl3-gpu/sdl3_presentation_evidence_archive_v2.py",
    "spikes/sdl3-gpu/sdl3_presentation_evidence_archive_v3.py",
    "spikes/sdl3-gpu/test_sdl3_presentation_evidence_archive_v3.py",
]
for workload in base.WORKLOADS:
    for name in ("manifest-v1.json", "trace-v1.json", "reference-v1.json", "project.json", "scene.json"):
        SOURCE_PATHS.append(f"tools/common-harness/workloads/{workload}/{name}")


def argument_value(name):
    try:
        return sys.argv[sys.argv.index(name) + 1]
    except (ValueError, IndexError) as error:
        raise RuntimeError(f"missing {name}") from error


def verify_v2():
    actual = base.identity(PRESENTATION_V2["path"])
    expected = {"sha256": PRESENTATION_V2["sha256"], "bytes": PRESENTATION_V2["bytes"]}
    if actual != expected:
        raise RuntimeError("presentation v2 lineage archive changed")


def main():
    verify_v2()
    evidence_root = pathlib.Path(argument_value("--evidence-root")).resolve()
    base.SOURCE_PATHS = SOURCE_PATHS
    base.gate = gate
    with contextlib.redirect_stdout(io.StringIO()):
        base.main()

    staging = evidence_root / "staging"
    raw_root = staging / "raw"
    build_root = evidence_root / "build"
    binary = build_root / "spikes/sdl3-gpu/fresco-scene-sdl3-presentation-spike"
    authorization = []
    probe_root = evidence_root / "formal-authorization-probes"
    probe_root.mkdir()
    for probe in gate.PROBES:
        output = probe_root / probe
        output.mkdir()
        raw, result = base.run_command(
            [binary, "--output", output, "--authorization-probe", probe],
            ROOT, raw_root, f"authorization-{probe}")
        record = base.single_json(result.stdout)
        gate.validate_authorization_probe(record, probe)
        authorization.append({"probe": probe, "raw": raw, "record": record})

    source = json.loads((staging / "source-manifest.json").read_text())
    source["identity"] = "sdl3-presentation-scheduling-source-v3"
    source_bytes = base.canonical(source)
    (staging / "source-manifest.json").write_bytes(source_bytes)
    source_identity = base.identity_bytes(source_bytes)

    record_path = staging / "record.json"
    record = json.loads(record_path.read_text())
    record["schemaVersion"] = 3
    record["identity"] = "sdl3-presentation-scheduling-formal-v3"
    record["run"]["sourceManifest"] = source_identity
    record["lineage"] = {
        "foundation": base.FOUNDATION,
        "presentationV1": {
            **base.PRESENTATION_V1, "relationship": "predecessor"},
        "presentationV2": PRESENTATION_V2,
    }
    record["build"]["identity"] = "sdl3-presentation-scheduling-appleclang-v3"
    record["schedulerEvidence"]["authorization"] = (
        "scheduler-owned-one-shot-v1")
    record["authorizationEvidence"] = authorization
    record["verdict"]["oneShotAuthorization"] = True
    record_path.write_bytes(base.canonical(record))

    archive = evidence_root / "evidence.tar.gz"
    base.publish(staging, archive)
    publication = {
        "schemaVersion": 3,
        "archive": {"path": os.fspath(archive), **base.identity(archive)},
        "record": base.identity(record_path),
        "sourceManifest": source_identity,
        "rawFrames": os.fspath(evidence_root / "formal-raw-frames"),
        "authorizationProbes": os.fspath(probe_root),
        "firstFormalEvidenceRun": True,
        "lineage": record["lineage"],
    }
    (evidence_root / "archive-publication.json").write_bytes(
        base.canonical(publication))
    print(json.dumps(publication, separators=(",", ":")))


if __name__ == "__main__":
    main()
