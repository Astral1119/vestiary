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


HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SDL_URL = "https://github.com/libsdl-org/SDL/releases/download/release-3.4.10/SDL3-3.4.10.tar.gz"
SDL_TAR_SHA256 = "12b34280415ec8418c864408b93d008a20a6530687ee613d60bfbd20411f2785"
SDL_LICENSE = {"sha256": "1c040b8271b37e5076359f8fd54240e371114112924d2df81ef87c7d6a1dfdfd", "bytes": 884}
GENERATOR = "Unix Makefiles"
BUILD_TYPE = "Release"
DEPLOYMENT_TARGET = "14.0"
SUPERSEDED_ARCHIVE = {
    "path": "/Users/astral/personal/vestiary/.fresco-evidence/sdl3-gpu-static-render-foundation-v1/evidence.tar.gz",
    "sha256": "170c265c4cae55331956c2563153211148307ce05e4492e867ed399ef6aac86c",
    "bytes": 1258779,
    "recordSha256": "18808f87c808eb699ab94cec87d7bce77c6c554dfc5ccdac9708453f4fb842f5",
}
SOURCE_PATHS = [
    "CMakeLists.txt", "THIRD_PARTY.md",
    "spikes/sdl3-gpu/CMakeLists.txt", "spikes/sdl3-gpu/README.md",
    "spikes/sdl3-gpu/generate_evidence.py",
    "spikes/sdl3-gpu/generate_fixture_header.py",
    "spikes/sdl3-gpu/main.cpp", "spikes/sdl3-gpu/reference-v1.json",
    "spikes/sdl3-gpu/sdl3_gpu_evidence_archive.py",
    "spikes/sdl3-gpu/test_sdl3_gpu_evidence_archive.py",
    "spikes/sdl3-gpu/sdl3_gpu_spike_test.py",
    "spikes/sdl3-gpu/shaders/minimal.frag.metal",
    "spikes/sdl3-gpu/shaders/minimal.vert.metal",
    "tools/common-harness/minimal_3d_contract.py",
    "tools/common-harness/test_minimal_3d_contract.py",
    "tools/common-harness/workloads/minimal-3d/fixture-v1.json",
    "tools/common-harness/workloads/minimal-3d/manifest-v1.json",
    "tools/common-harness/workloads/minimal-3d/reference-v1.json",
    "tools/common-harness/workloads/minimal-3d/trace-v1.json",
]


def identity_bytes(value):
    return {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}


def identity(path):
    return identity_bytes(path.read_bytes())


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def run_command(command, cwd, raw_root, identity_name):
    started = utc_now()
    before = time.monotonic()
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    seconds = round(time.monotonic() - before, 6)
    completed = utc_now()
    stdout_path = raw_root / f"{identity_name}.stdout"
    stderr_path = raw_root / f"{identity_name}.stderr"
    stdout_path.write_text(result.stdout, encoding="utf-8")
    stderr_path.write_text(result.stderr, encoding="utf-8")
    if result.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(map(os.fspath, command))}")
    combined = result.stdout + result.stderr
    return {
        "command": [os.fspath(item) for item in command],
        "startedAtUtc": started, "completedAtUtc": completed,
        "durationSeconds": seconds, "exitCode": result.returncode,
        "warningCount": len(re.findall(r"(?im)^.*warning(?:s|:).*$", combined)),
        "stdout": {"path": f"raw/{stdout_path.name}", **identity(stdout_path)},
        "stderr": {"path": f"raw/{stderr_path.name}", **identity(stderr_path)},
    }, result


def parse_single_json(stdout):
    records = [json.loads(line) for line in stdout.splitlines() if line.startswith("{")]
    if len(records) != 1:
        raise RuntimeError("expected one JSON record")
    return records[0]


def system_value(command):
    return subprocess.run(command, check=True, text=True, capture_output=True).stdout.strip()


def publish_archive(staging, destination):
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence-root", type=pathlib.Path, required=True)
    parser.add_argument("--operator", required=True)
    parser.add_argument("--agent-role", choices=("automation", "operator", "root-agent", "subagent"), required=True)
    arguments = parser.parse_args()
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
        "identity": "sdl3-gpu-static-render-foundation-source-v2",
        "files": [{"path": name, **identity(ROOT / name)} for name in SOURCE_PATHS],
    }
    source_bytes = canonical(source_manifest)
    (staging / "source-manifest.json").write_bytes(source_bytes)
    source_identity = identity_bytes(source_bytes)

    cmake_path = pathlib.Path(shutil.which("cmake") or "").resolve()
    if not cmake_path.is_file():
        raise RuntimeError("cmake executable is unavailable")
    cmake_version_record, cmake_version_result = run_command(
        [os.fspath(cmake_path), "--version"], ROOT, raw_root, "cmake-version")
    cmake_version = cmake_version_result.stdout.splitlines()[0]
    configure = [
        os.fspath(cmake_path), "-G", GENERATOR,
        "-S", os.fspath(ROOT), "-B", os.fspath(build_root),
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
    archived_cache = staging / "build/CMakeCache.txt"
    archived_cache.parent.mkdir(parents=True)
    shutil.copyfile(build_root / "CMakeCache.txt", archived_cache)
    build = [os.fspath(cmake_path), "--build", os.fspath(build_root), "--target", "fresco-scene-sdl3-gpu-spike", "--parallel"]
    build_record, _ = run_command(build, ROOT, raw_root, "build")
    tests = ["ctest", "--test-dir", os.fspath(build_root), "--output-on-failure", "-R", "fresco-scene-sdl3-gpu-(depth-probe|correctness)|fresco-scene-common-harness-minimal-3d-contract"]
    test_record, _ = run_command(tests, ROOT, raw_root, "test")

    binary = build_root / "spikes/sdl3-gpu/fresco-scene-sdl3-gpu-spike"
    archived_binary = staging / "build/fresco-scene-sdl3-gpu-spike"
    archived_binary.parent.mkdir(exist_ok=True)
    shutil.copyfile(binary, archived_binary)
    license_path = build_root / "_deps/fresco_scene_sdl3-src/LICENSE.txt"
    if identity(license_path) != SDL_LICENSE:
        raise RuntimeError("fetched SDL license identity changed")
    archived_license = staging / "dependency/SDL-3.4.10-LICENSE.txt"
    archived_license.parent.mkdir()
    shutil.copyfile(license_path, archived_license)

    probe_command = [os.fspath(binary), "--probe-depth"]
    probe_record, probe_result = run_command(probe_command, ROOT, raw_root, "depth-probe")
    probe = parse_single_json(probe_result.stdout)
    reference = json.loads((HERE / "reference-v1.json").read_text(encoding="utf-8"))
    expected_support = reference["depthProbe"]
    if probe["support"] != expected_support or not probe["support"]["depth32float"]:
        raise RuntimeError("depth capability gate changed")
    shutil.copyfile(HERE / "reference-v1.json", staging / "reference-v1.json")
    minimal_reference_path = ROOT / "tools/common-harness/workloads/minimal-3d/reference-v1.json"
    shutil.copyfile(minimal_reference_path, staging / "minimal-3d-reference-v1.json")

    frame_root = evidence_root / "formal-raw-frames"
    frame_root.mkdir()
    runtime_command = [os.fspath(binary), "--depth", "depth32float", "--output", os.fspath(frame_root)]
    runtime_record, runtime_result = run_command(runtime_command, ROOT, raw_root, "runtime")
    runtime = parse_single_json(runtime_result.stdout)
    artifacts = []
    cas_root = staging / "artifacts/sha256"
    for output, expected in zip(runtime["outputs"], reference["outputs"]):
        frame = pathlib.Path(output["path"])
        frame_identity = identity(frame)
        if frame_identity != {"sha256": expected["sha256"], "bytes": expected["bytes"]}:
            raise RuntimeError(f"frame reference changed: {expected['identity']}")
        cas = cas_root / frame_identity["sha256"][:2] / frame_identity["sha256"]
        cas.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(frame, cas)
        artifacts.append({"name": expected["identity"], "mediaType": "application/x-bgra8", "path": cas.relative_to(staging).as_posix(), **frame_identity})

    display_data = json.loads(system_value(["system_profiler", "SPDisplaysDataType", "-json"]))["SPDisplaysDataType"][0]
    display = display_data["spdisplays_ndrvs"][0]
    shader_paths = ["spikes/sdl3-gpu/shaders/minimal.vert.metal", "spikes/sdl3-gpu/shaders/minimal.frag.metal"]
    source_by_path = {item["path"]: item for item in source_manifest["files"]}
    completed = utc_now()
    record = {
        "schemaVersion": 1,
        "identity": "sdl3-gpu-static-render-foundation-formal-v2",
        "supersedes": SUPERSEDED_ARCHIVE,
        "run": {"startedAtUtc": started, "completedAtUtc": completed, "operator": arguments.operator, "agentRole": arguments.agent_role, "agentIdentity": "/root/architecture_contract", "purpose": "correctness", "sourceManifest": source_identity, "binary": identity(binary)},
        "host": {"model": system_value(["sysctl", "-n", "hw.model"]), "architecture": platform.machine(), "os": {"product": system_value(["sw_vers", "-productName"]), "version": system_value(["sw_vers", "-productVersion"]), "build": system_value(["sw_vers", "-buildVersion"])}, "gpu": display_data["sppci_model"]},
        "display": {"identity": display["_name"], "connection": display["spdisplays_connection_type"], "main": display["spdisplays_main"], "pixels": display["_spdisplays_pixels"], "logicalRefresh": display["_spdisplays_resolution"]},
        "build": {"identity": "sdl3-gpu-static-render-foundation-appleclang-v2", "cmakeTool": {"executable": {"path": os.fspath(cmake_path), **identity(cmake_path)}, "version": cmake_version, "raw": cmake_version_record}, "generator": GENERATOR, "buildType": BUILD_TYPE, "deploymentTarget": {"status": "available", "value": DEPLOYMENT_TARGET}, "configureCache": {"path": "build/CMakeCache.txt", **identity(archived_cache)}, "compiler": system_value(["/usr/bin/clang", "--version"]).splitlines()[0], "xcode": system_value(["xcodebuild", "-version"]).splitlines(), "sdk": {"path": system_value(["xcrun", "--show-sdk-path"]), "version": system_value(["xcrun", "--show-sdk-version"])}, "commands": [configure_record, build_record, test_record], "binaryArtifact": {"path": "build/fresco-scene-sdl3-gpu-spike", **identity(archived_binary)}},
        "dependency": {"identity": "SDL-3.4.10", "version": "3.4.10", "sourceUrl": SDL_URL, "sourceTarSha256": SDL_TAR_SHA256, "revision": "SDL-release-3.4.10-0-g8e37db5e7", "license": {"name": "zlib", "path": "dependency/SDL-3.4.10-LICENSE.txt", **SDL_LICENSE}, "linkage": "static", "scope": "opt-in-spike-only", "installRule": False},
        "shaders": {"format": "MSL-source", "sources": [{"path": path, "sha256": source_by_path[path]["sha256"], "bytes": source_by_path[path]["bytes"]} for path in shader_paths], "pipelineCount": 2, "diagnostics": {"errors": [], "warnings": []}},
        "depthCapability": {"query": "SDL_GPUTextureSupportsFormat", "raw": probe_record, "result": probe["support"], "selected": "depth32float"},
        "referenceGeneration": {"identity": reference["identity"], "tool": {"path": "spikes/sdl3-gpu/generate_evidence.py", "sha256": source_by_path["spikes/sdl3-gpu/generate_evidence.py"]["sha256"], "bytes": source_by_path["spikes/sdl3-gpu/generate_evidence.py"]["bytes"]}, "reference": {"path": "reference-v1.json", **identity(HERE / "reference-v1.json")}, "contractReference": {"path": "minimal-3d-reference-v1.json", **identity(minimal_reference_path)}, "sequence": ["cmake-tool", "configure", "build", "test", "depth-probe", "reference-freeze", "render", "archive"], "outputOrder": [item["identity"] for item in reference["outputs"]], "probeOrder": [[item["identity"], item["checkpoint"]] for item in reference["probeColors"]]},
        "runtime": {"raw": runtime_record, "record": runtime, "frames": artifacts, "lifecycle": runtime["lifecycle"]},
        "verdict": {"build": True, "depthCapability": True, "shaderDiagnostics": True, "pixels": True, "resize": runtime["lifecycle"]["resizeRetirementsAfterCompletion"] == 2, "lifecycle": True, "accepted": True, "scope": "static-render-foundation-and-minimal-3d"},
    }
    (staging / "record.json").write_bytes(canonical(record))
    archive = evidence_root / "evidence.tar.gz"
    publish_archive(staging, archive)
    publication = {"schemaVersion": 1, "archive": {"path": os.fspath(archive), **identity(archive)}, "record": identity(staging / "record.json"), "sourceManifest": source_identity, "rawFrames": os.fspath(frame_root), "replacementFormalEvidenceRun": True, "supersedes": SUPERSEDED_ARCHIVE}
    (evidence_root / "archive-publication.json").write_bytes(canonical(publication))
    print(json.dumps(publication, separators=(",", ":")))


if __name__ == "__main__":
    main()
