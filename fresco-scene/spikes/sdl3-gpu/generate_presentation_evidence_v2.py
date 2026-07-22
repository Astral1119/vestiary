#!/usr/bin/env python3

import argparse
import datetime
import gzip
import hashlib
import io
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import tarfile
import time

import sdl3_presentation_test_v2 as gate


HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
GENERATOR = "Unix Makefiles"
BUILD_TYPE = "Release"
DEPLOYMENT_TARGET = "14.0"
SDL_URL = "https://github.com/libsdl-org/SDL/releases/download/release-3.4.10/SDL3-3.4.10.tar.gz"
SDL_TAR_SHA256 = "12b34280415ec8418c864408b93d008a20a6530687ee613d60bfbd20411f2785"
SDL_LICENSE = {"sha256": "1c040b8271b37e5076359f8fd54240e371114112924d2df81ef87c7d6a1dfdfd", "bytes": 884}
FOUNDATION = {
    "relationship": "foundation",
    "path": "/Users/astral/personal/vestiary/.fresco-evidence/sdl3-gpu-static-render-foundation-v2/evidence.tar.gz",
    "sha256": "96cdc7de24e86949524519f4ab210fd4b08ca41110799472a421cdd1b5357707",
    "bytes": 1132663,
}
PRESENTATION_V1 = {
    "relationship": "supersedes",
    "path": "/Users/astral/personal/vestiary/.fresco-evidence/sdl3-presentation-scheduling-v1/evidence.tar.gz",
    "sha256": "e7e0c57a3370f1750dc9f4d6c0021049ddf2ee35569d0e376685ce4dd748f967",
    "bytes": 1135454,
}
WORKLOADS = ("static-no-media", "continuous-animation")
SOURCE_PATHS = [
    "CMakeLists.txt", "THIRD_PARTY.md",
    "spikes/sdl3-gpu/CMakeLists.txt", "spikes/sdl3-gpu/README.md",
    "spikes/sdl3-gpu/PresentationScheduler.h",
    "spikes/sdl3-gpu/PresentationScheduler.cpp",
    "spikes/sdl3-gpu/presentation.cpp",
    "spikes/sdl3-gpu/presentation-reference-v2.json",
    "spikes/sdl3-gpu/sdl3_presentation_test_v2.py",
    "spikes/sdl3-gpu/test_sdl3_presentation_evidence_v2.py",
    "spikes/sdl3-gpu/generate_presentation_evidence_v2.py",
    "spikes/sdl3-gpu/sdl3_presentation_evidence_archive_v2.py",
    "spikes/sdl3-gpu/test_sdl3_presentation_evidence_archive_v2.py",
]
for workload in WORKLOADS:
    for name in ("manifest-v1.json", "trace-v1.json", "reference-v1.json", "project.json", "scene.json"):
        SOURCE_PATHS.append(f"tools/common-harness/workloads/{workload}/{name}")


def identity_bytes(value):
    return {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}


def identity(path):
    return identity_bytes(pathlib.Path(path).read_bytes())


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def run_command(command, cwd, raw_root, name):
    started = utc_now()
    before = time.monotonic()
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    completed = utc_now()
    stdout = raw_root / f"{name}.stdout"
    stderr = raw_root / f"{name}.stderr"
    stdout.write_text(result.stdout, encoding="utf-8")
    stderr.write_text(result.stderr, encoding="utf-8")
    if result.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(map(os.fspath, command))}")
    return {
        "command": [os.fspath(item) for item in command],
        "startedAtUtc": started,
        "completedAtUtc": completed,
        "durationSeconds": round(time.monotonic() - before, 6),
        "exitCode": result.returncode,
        "warningCount": len(re.findall(r"(?im)^.*warning(?:s|:).*$", result.stdout + result.stderr)),
        "stdout": {"path": f"raw/{stdout.name}", **identity(stdout)},
        "stderr": {"path": f"raw/{stderr.name}", **identity(stderr)},
    }, result


def single_json(stdout):
    records = [json.loads(line) for line in stdout.splitlines() if line.startswith("{")]
    if len(records) != 1:
        raise RuntimeError("expected one JSON record")
    return records[0]


def system_value(command):
    return subprocess.run(command, check=True, text=True, capture_output=True).stdout.strip()


def publish(staging, destination):
    with destination.open("wb") as output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as archive:
                for path in sorted(item for item in staging.rglob("*") if item.is_file()):
                    value = path.read_bytes()
                    info = tarfile.TarInfo(path.relative_to(staging).as_posix())
                    info.size = len(value)
                    info.mode = 0o644
                    info.mtime = 0
                    archive.addfile(info, io.BytesIO(value))


def verify_lineage():
    for item in (FOUNDATION, PRESENTATION_V1):
        actual = identity(item["path"])
        expected = {"sha256": item["sha256"], "bytes": item["bytes"]}
        if actual != expected:
            raise RuntimeError(f"lineage archive changed: {item['path']}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence-root", type=pathlib.Path, required=True)
    parser.add_argument("--operator", required=True)
    parser.add_argument("--agent-role", choices=("automation", "operator", "root-agent", "subagent"), required=True)
    arguments = parser.parse_args()
    verify_lineage()
    evidence_root = arguments.evidence_root.resolve()
    if evidence_root.exists():
        raise RuntimeError(f"evidence root already exists: {evidence_root}")
    evidence_root.mkdir(parents=True)
    build_root = evidence_root / "build"
    staging = evidence_root / "staging"
    raw_root = staging / "raw"
    raw_root.mkdir(parents=True)
    started = utc_now()

    source_manifest = {
        "schemaVersion": 1,
        "identity": "sdl3-presentation-scheduling-source-v2",
        "files": [{"path": name, **identity(ROOT / name)} for name in SOURCE_PATHS],
    }
    source_bytes = canonical(source_manifest)
    (staging / "source-manifest.json").write_bytes(source_bytes)
    source_identity = identity_bytes(source_bytes)

    cmake_path = pathlib.Path(shutil.which("cmake") or "").resolve()
    if not cmake_path.is_file():
        raise RuntimeError("cmake executable is unavailable")
    cmake_version_record, cmake_result = run_command([cmake_path, "--version"], ROOT, raw_root, "cmake-version")
    configure = [
        cmake_path, "-G", GENERATOR, "-S", ROOT, "-B", build_root,
        "-DCMAKE_C_COMPILER=/usr/bin/clang",
        "-DCMAKE_CXX_COMPILER=/usr/bin/clang++",
        "-DCMAKE_OBJC_COMPILER=/usr/bin/clang",
        "-DCMAKE_OBJCXX_COMPILER=/usr/bin/clang++",
        f"-DCMAKE_BUILD_TYPE={BUILD_TYPE}",
        f"-DCMAKE_OSX_DEPLOYMENT_TARGET={DEPLOYMENT_TARGET}",
        "-DFRESCO_SCENE_BUILD_SDL3_GPU_SPIKE=ON",
        "-DFRESCO_SCENE_BUILD_RENDERER=OFF",
    ]
    configure_record, _ = run_command(configure, ROOT, raw_root, "configure")
    cache = staging / "build/CMakeCache.txt"
    cache.parent.mkdir(parents=True)
    shutil.copyfile(build_root / "CMakeCache.txt", cache)
    build_record, _ = run_command(
        [cmake_path, "--build", build_root, "--target", "fresco-scene-sdl3-presentation-spike", "--parallel"],
        ROOT, raw_root, "build")
    test_record, _ = run_command(
        ["ctest", "--test-dir", build_root, "--output-on-failure", "-R", "fresco-scene-sdl3-presentation-(correctness|hostile)|fresco-scene-common-harness-(contract|minimal-3d-contract)"],
        ROOT, raw_root, "test")

    binary = build_root / "spikes/sdl3-gpu/fresco-scene-sdl3-presentation-spike"
    archived_binary = staging / "build/fresco-scene-sdl3-presentation-spike"
    shutil.copyfile(binary, archived_binary)
    license_path = build_root / "_deps/fresco_scene_sdl3-src/LICENSE.txt"
    if identity(license_path) != SDL_LICENSE:
        raise RuntimeError("SDL license identity changed")
    archived_license = staging / "dependency/SDL-3.4.10-LICENSE.txt"
    archived_license.parent.mkdir()
    shutil.copyfile(license_path, archived_license)

    reference_path = HERE / "presentation-reference-v2.json"
    reference = gate.load(reference_path)
    shutil.copyfile(reference_path, staging / reference_path.name)
    contracts = []
    for binding in reference["workloadBindings"]:
        for key, filename in (("manifest", "manifest-v1.json"), ("trace", "trace-v1.json"), ("reference", "reference-v1.json")):
            source = ROOT / "tools/common-harness/workloads" / binding["identity"] / filename
            destination = staging / "contracts" / binding["identity"] / filename
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            contracts.append({"workload": binding["identity"], "kind": key, "path": destination.relative_to(staging).as_posix(), **identity(destination)})

    frame_root = evidence_root / "formal-raw-frames"
    frame_root.mkdir()
    runtime_record, runtime_result = run_command([binary, "--output", frame_root], ROOT, raw_root, "runtime")
    runtime = single_json(runtime_result.stdout)
    gate.validate_record(runtime, reference, ROOT / "tools/common-harness/workloads", frame_root)
    frames = []
    cas_root = staging / "artifacts/sha256"
    expected_outputs = {item["identity"]: item for item in reference["outputs"]}
    for workload in runtime["workloads"]:
        for output in workload["outputs"]:
            expected = expected_outputs[output["identity"]]
            source = pathlib.Path(output["path"])
            item_identity = identity(source)
            if item_identity != {"sha256": expected["sha256"], "bytes": expected["bytes"]}:
                raise RuntimeError(f"oracle reference changed: {output['identity']}")
            destination = cas_root / item_identity["sha256"][:2] / item_identity["sha256"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            if not destination.exists():
                shutil.copyfile(source, destination)
            frames.append({
                "name": output["identity"],
                "evidenceRole": "mirrored-render-oracle",
                "mediaType": "application/x-bgra8",
                "path": destination.relative_to(staging).as_posix(),
                **item_identity,
            })

    display_data = json.loads(system_value(["system_profiler", "SPDisplaysDataType", "-json"]))["SPDisplaysDataType"][0]
    display = display_data["spdisplays_ndrvs"][0]
    completed = utc_now()
    record = {
        "schemaVersion": 2,
        "identity": "sdl3-presentation-scheduling-formal-v2",
        "run": {"startedAtUtc": started, "completedAtUtc": completed, "operator": arguments.operator, "agentRole": arguments.agent_role, "agentIdentity": "/root/architecture_contract", "purpose": "correctness", "sourceManifest": source_identity, "binary": identity(binary)},
        "lineage": {"foundation": FOUNDATION, "presentationPredecessor": PRESENTATION_V1},
        "host": {"model": system_value(["sysctl", "-n", "hw.model"]), "architecture": platform.machine(), "os": {"product": system_value(["sw_vers", "-productName"]), "version": system_value(["sw_vers", "-productVersion"]), "build": system_value(["sw_vers", "-buildVersion"])}, "gpu": display_data["sppci_model"]},
        "display": {"identity": display["_name"], "connection": display["spdisplays_connection_type"], "main": display["spdisplays_main"], "pixels": display["_spdisplays_pixels"], "logicalRefresh": display["_spdisplays_resolution"]},
        "build": {"identity": "sdl3-presentation-scheduling-appleclang-v2", "cmakeTool": {"executable": {"path": os.fspath(cmake_path), **identity(cmake_path)}, "version": cmake_result.stdout.splitlines()[0], "raw": cmake_version_record}, "generator": GENERATOR, "buildType": BUILD_TYPE, "deploymentTarget": {"status": "available", "value": DEPLOYMENT_TARGET}, "configureCache": {"path": "build/CMakeCache.txt", **identity(cache)}, "compiler": system_value(["/usr/bin/clang", "--version"]).splitlines()[0], "xcode": system_value(["xcodebuild", "-version"]).splitlines(), "sdk": {"path": system_value(["xcrun", "--show-sdk-path"]), "version": system_value(["xcrun", "--show-sdk-version"])}, "commands": [configure_record, build_record, test_record], "binaryArtifact": {"path": "build/fresco-scene-sdl3-presentation-spike", **identity(archived_binary)}},
        "dependency": {"identity": "SDL-3.4.10", "version": "3.4.10", "sourceUrl": SDL_URL, "sourceTarSha256": SDL_TAR_SHA256, "revision": "SDL-release-3.4.10-0-g8e37db5e7", "license": {"name": "zlib", "path": "dependency/SDL-3.4.10-LICENSE.txt", **SDL_LICENSE}, "linkage": "static", "scope": "opt-in-spike-only", "installRule": False},
        "contracts": contracts,
        "reference": {"identity": reference["identity"], "path": reference_path.name, **identity(reference_path)},
        "schedulerEvidence": {"identity": runtime["schedulerIdentity"], "clock": "deterministic-virtual-nanoseconds", "inputEvents": {item["identity"]: len(item["scheduler"]["inputEvents"]) for item in runtime["workloads"]}, "decisions": {item["identity"]: len(item["scheduler"]["decisions"]) for item in runtime["workloads"]}, "completionRequiredBeforeNextDecision": True},
        "presentationEvidence": {"videoDriver": "cocoa", "gpuDriver": "metal", "swapchainAcquisitions": {item["identity"]: item["lifecycle"]["swapchainAcquisitions"] for item in runtime["workloads"]}, "swapchainPresents": {item["identity"]: item["lifecycle"]["presents"] for item in runtime["workloads"]}},
        "oracleBoundary": {"retainedFrameRole": "mirrored-render-oracle", "drawablePixelClaim": False, "swapchainWorkProvenSeparately": True},
        "runtime": {"raw": runtime_record, "record": runtime, "frames": frames},
        "lifecycle": {item["identity"]: item["lifecycle"] for item in runtime["workloads"]},
        "verdict": {"build": True, "contracts": True, "schedulerStateMachine": True, "decisionAuthorizedPresentation": True, "swapchain": True, "mirroredOracles": True, "staticScheduling": True, "continuousScheduling": True, "resize": True, "lifecycle": True, "accepted": True, "performance": "not-measured"},
    }
    (staging / "record.json").write_bytes(canonical(record))
    archive = evidence_root / "evidence.tar.gz"
    publish(staging, archive)
    publication = {"schemaVersion": 2, "archive": {"path": os.fspath(archive), **identity(archive)}, "record": identity(staging / "record.json"), "sourceManifest": source_identity, "rawFrames": os.fspath(frame_root), "firstFormalEvidenceRun": True, "lineage": record["lineage"]}
    (evidence_root / "archive-publication.json").write_bytes(canonical(publication))
    print(json.dumps(publication, separators=(",", ":")))


if __name__ == "__main__":
    main()
