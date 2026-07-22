#!/usr/bin/env python3

import argparse
import hashlib
import io
import json
import pathlib
import re
import tarfile


class VerificationError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def identity_bytes(value):
    return {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}


def exact(value, keys, path):
    require(isinstance(value, dict) and set(value) == set(keys), f"{path} schema changed")


def load_json(value, path):
    try:
        return json.loads(value)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"{path} is not JSON") from error


def read_archive(path):
    raw = pathlib.Path(path).read_bytes()
    files = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as archive:
            for member in archive:
                pure = pathlib.PurePosixPath(member.name)
                require(not pure.is_absolute() and ".." not in pure.parts, "unsafe archive path")
                require(member.isfile(), "archive contains a link, directory, or special member")
                require(member.name not in files, "archive contains a duplicate member")
                stream = archive.extractfile(member)
                require(stream is not None, "archive member has no bytes")
                files[member.name] = stream.read()
    except (tarfile.TarError, OSError) as error:
        raise VerificationError("archive cannot be read") from error
    return files, identity_bytes(raw)


def descriptor(files, value, path):
    exact(value, {"path", "sha256", "bytes"}, path)
    require(value["path"] in files, f"{path} artifact is missing")
    require(identity_bytes(files[value["path"]]) == {"sha256": value["sha256"], "bytes": value["bytes"]}, f"{path} identity changed")


def command_artifacts(files, command, identity):
    exact(command, {"command", "startedAtUtc", "completedAtUtc", "durationSeconds", "exitCode", "warningCount", "stdout", "stderr"}, f"build command {identity}")
    require(command["exitCode"] == 0 and command["warningCount"] == 0 and command["durationSeconds"] >= 0, f"build command failed or warned: {identity}")
    require(command["startedAtUtc"].endswith("Z") and command["completedAtUtc"].endswith("Z"), f"build command UTC bounds changed: {identity}")
    descriptor(files, command["stdout"], f"build command {identity}.stdout")
    descriptor(files, command["stderr"], f"build command {identity}.stderr")


def raw_json(files, raw, path):
    command_artifacts(files, raw, path)
    records = [json.loads(line) for line in files[raw["stdout"]["path"]].decode().splitlines() if line.startswith("{")]
    require(len(records) == 1, f"{path} raw JSON count changed")
    return records[0]


def cache_values(value):
    result = {}
    for line in value.decode().splitlines():
        match = re.match(r"^([^#/:][^:=]*)(?::[^=]+)?=(.*)$", line)
        if match:
            result[match.group(1)] = match.group(2)
    return result


def rectangle_colors(raw, width, rect):
    x, y, rect_width, rect_height = rect
    height = len(raw) // (width * 4)
    colors = set()
    for row in range(y * height // 1000, (y + rect_height) * height // 1000):
        for column in range(x * width // 1000, (x + rect_width) * width // 1000):
            offset = (row * width + column) * 4
            colors.add(raw[offset:offset + 4].hex())
    return sorted(colors)


def verify_files(files):
    require("record.json" in files and "source-manifest.json" in files and "reference-v1.json" in files and "minimal-3d-reference-v1.json" in files, "archive metadata is incomplete")
    record = load_json(files["record.json"], "record.json")
    exact(record, {"schemaVersion", "identity", "supersedes", "run", "host", "display", "build", "dependency", "shaders", "depthCapability", "referenceGeneration", "runtime", "verdict"}, "record")
    require(record["schemaVersion"] == 1 and record["identity"] == "sdl3-gpu-static-render-foundation-formal-v2", "record identity changed")
    require(record["supersedes"] == {"path": "/Users/astral/personal/vestiary/.fresco-evidence/sdl3-gpu-static-render-foundation-v1/evidence.tar.gz", "sha256": "170c265c4cae55331956c2563153211148307ce05e4492e867ed399ef6aac86c", "bytes": 1258779, "recordSha256": "18808f87c808eb699ab94cec87d7bce77c6c554dfc5ccdac9708453f4fb842f5"}, "superseded evidence binding changed")
    run = record["run"]
    exact(run, {"startedAtUtc", "completedAtUtc", "operator", "agentRole", "agentIdentity", "purpose", "sourceManifest", "binary"}, "run")
    require(run["purpose"] == "correctness" and run["agentRole"] == "subagent" and run["agentIdentity"] == "/root/architecture_contract", "run ownership or purpose changed")
    require(run["startedAtUtc"].endswith("Z") and run["completedAtUtc"].endswith("Z"), "run UTC bounds changed")
    require(identity_bytes(files["source-manifest.json"]) == run["sourceManifest"], "source manifest identity changed")
    source = load_json(files["source-manifest.json"], "source-manifest.json")
    exact(source, {"schemaVersion", "identity", "files"}, "source manifest")
    require(source["schemaVersion"] == 1 and source["identity"] == "sdl3-gpu-static-render-foundation-source-v2", "source manifest identity changed")
    source_by_path = {item["path"]: item for item in source["files"]}
    require(len(source_by_path) == len(source["files"]) and all(set(item) == {"path", "sha256", "bytes"} for item in source["files"]), "source manifest file inventory changed")

    build = record["build"]
    exact(build, {"identity", "cmakeTool", "generator", "buildType", "deploymentTarget", "configureCache", "compiler", "xcode", "sdk", "commands", "binaryArtifact"}, "build")
    require(build["identity"] == "sdl3-gpu-static-render-foundation-appleclang-v2" and build["compiler"].startswith("Apple clang version 21.0.0"), "build compiler identity changed")
    cmake_tool = build["cmakeTool"]
    exact(cmake_tool, {"executable", "version", "raw"}, "cmake tool")
    exact(cmake_tool["executable"], {"path", "sha256", "bytes"}, "cmake executable")
    require(cmake_tool["executable"]["path"].endswith("/bin/cmake") and re.fullmatch(r"[0-9a-f]{64}", cmake_tool["executable"]["sha256"]) and cmake_tool["executable"]["bytes"] > 0, "cmake executable identity changed")
    command_artifacts(files, cmake_tool["raw"], "cmake tool")
    require(cmake_tool["raw"]["command"] == [cmake_tool["executable"]["path"], "--version"], "cmake version command changed")
    require(cmake_tool["version"] == "cmake version 4.4.0" and files[cmake_tool["raw"]["stdout"]["path"]].decode().splitlines()[0] == cmake_tool["version"], "cmake version identity changed")
    require(build["generator"] == "Unix Makefiles" and build["buildType"] == "Release" and build["deploymentTarget"] == {"status": "available", "value": "14.0"}, "generator, build type, or deployment target changed")
    descriptor(files, build["configureCache"], "configure cache")
    cache = cache_values(files[build["configureCache"]["path"]])
    require(cache.get("CMAKE_GENERATOR") == "Unix Makefiles", "cache generator changed")
    require(cache.get("CMAKE_BUILD_TYPE") == "Release", "cache build type changed")
    require(cache.get("CMAKE_OSX_DEPLOYMENT_TARGET") == "14.0", "cache deployment target changed")
    require(cache.get("CMAKE_C_COMPILER") == "/usr/bin/clang" and cache.get("CMAKE_CXX_COMPILER") == "/usr/bin/clang++", "cache compiler changed")
    require(len(build["commands"]) == 3, "build command count changed")
    for command, name in zip(build["commands"], ("configure", "build", "test")):
        command_artifacts(files, command, name)
    configure, build_command, test = [item["command"] for item in build["commands"]]
    require(configure[:3] == [cmake_tool["executable"]["path"], "-G", "Unix Makefiles"], "configure generator changed")
    require("-DCMAKE_BUILD_TYPE=Release" in configure and "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0" in configure, "configure build type or deployment target changed")
    require("-DFRESCO_SCENE_BUILD_SDL3_GPU_SPIKE=ON" in configure and "-DCMAKE_C_COMPILER=/usr/bin/clang" in configure and "-DCMAKE_CXX_COMPILER=/usr/bin/clang++" in configure, "configure command changed")
    require(build_command[-3:] == ["--target", "fresco-scene-sdl3-gpu-spike", "--parallel"], "build target changed")
    require(test[-2:] == ["-R", "fresco-scene-sdl3-gpu-(depth-probe|correctness)|fresco-scene-common-harness-minimal-3d-contract"], "test gate changed")
    descriptor(files, build["binaryArtifact"], "build binary")
    require(run["binary"] == {"sha256": build["binaryArtifact"]["sha256"], "bytes": build["binaryArtifact"]["bytes"]}, "run binary identity changed")

    dependency = record["dependency"]
    require(dependency == {"identity": "SDL-3.4.10", "version": "3.4.10", "sourceUrl": "https://github.com/libsdl-org/SDL/releases/download/release-3.4.10/SDL3-3.4.10.tar.gz", "sourceTarSha256": "12b34280415ec8418c864408b93d008a20a6530687ee613d60bfbd20411f2785", "revision": "SDL-release-3.4.10-0-g8e37db5e7", "license": {"name": "zlib", "path": "dependency/SDL-3.4.10-LICENSE.txt", "sha256": "1c040b8271b37e5076359f8fd54240e371114112924d2df81ef87c7d6a1dfdfd", "bytes": 884}, "linkage": "static", "scope": "opt-in-spike-only", "installRule": False}, "SDL dependency identity changed")
    require(identity_bytes(files[dependency["license"]["path"]]) == {"sha256": dependency["license"]["sha256"], "bytes": dependency["license"]["bytes"]}, "SDL license bytes changed")

    shaders = record["shaders"]
    require(shaders["format"] == "MSL-source" and shaders["pipelineCount"] == 2 and shaders["diagnostics"] == {"errors": [], "warnings": []}, "shader diagnostics changed")
    for shader in shaders["sources"]:
        require(shader == source_by_path.get(shader["path"]), f"shader source identity changed: {shader['path']}")

    depth = record["depthCapability"]
    probe = raw_json(files, depth["raw"], "depth capability")
    expected_support = {"depth32float": True, "depth24unorm-stencil8": False, "depth16unorm": True}
    require(depth["query"] == "SDL_GPUTextureSupportsFormat" and depth["selected"] == "depth32float" and depth["result"] == expected_support, "depth capability record changed")
    require(probe == {"schemaVersion": 1, "mode": "depth-probe", "sdlVersion": "3.4.10", "driver": "metal", "support": expected_support}, "raw depth capability changed")

    reference = load_json(files["reference-v1.json"], "reference-v1.json")
    minimal_reference = load_json(files["minimal-3d-reference-v1.json"], "minimal-3d-reference-v1.json")
    generation = record["referenceGeneration"]
    require(generation["identity"] == reference["identity"], "reference generation identity changed")
    require(generation["sequence"] == ["cmake-tool", "configure", "build", "test", "depth-probe", "reference-freeze", "render", "archive"], "probe-to-reference generation order changed")
    require(generation["outputOrder"] == [item["identity"] for item in reference["outputs"]], "reference output order changed")
    require(generation["probeOrder"] == [[item["identity"], item["checkpoint"]] for item in reference["probeColors"]], "reference probe order changed")
    require(identity_bytes(files[generation["reference"]["path"]]) == {"sha256": generation["reference"]["sha256"], "bytes": generation["reference"]["bytes"]}, "pixel reference identity changed")
    require(identity_bytes(files[generation["contractReference"]["path"]]) == {"sha256": generation["contractReference"]["sha256"], "bytes": generation["contractReference"]["bytes"]}, "contract reference identity changed")
    require(generation["tool"] == source_by_path["spikes/sdl3-gpu/generate_evidence.py"], "evidence generation tool identity changed")

    runtime = record["runtime"]
    raw_runtime = raw_json(files, runtime["raw"], "runtime")
    require(raw_runtime == runtime["record"], "runtime raw JSON changed")
    require(runtime["record"]["depthFormat"] == "depth32float" and runtime["record"]["driver"] == "metal", "runtime backend changed")
    require(runtime["lifecycle"] == reference["lifecycle"] == runtime["record"]["lifecycle"], "runtime lifecycle changed")
    require(runtime["lifecycle"]["resizeRetirementsAfterCompletion"] == 2, "resize completion evidence changed")
    require(len(runtime["frames"]) == 5, "frame count changed")
    frames = {}
    for artifact, expected in zip(runtime["frames"], reference["outputs"]):
        exact(artifact, {"name", "mediaType", "path", "sha256", "bytes"}, f"frame {expected['identity']}")
        require(artifact["name"] == expected["identity"] and artifact["sha256"] == expected["sha256"] and artifact["bytes"] == expected["bytes"], f"frame reference changed: {expected['identity']}")
        require(artifact["path"] == f"artifacts/sha256/{artifact['sha256'][:2]}/{artifact['sha256']}", f"frame CAS path changed: {expected['identity']}")
        require(identity_bytes(files[artifact["path"]]) == {"sha256": artifact["sha256"], "bytes": artifact["bytes"]}, f"frame bytes changed: {expected['identity']}")
        frames[artifact["name"]] = files[artifact["path"]]
    clear = frames["static-render-foundation-clear"]
    require(set(clear[index:index + 4] for index in range(0, len(clear), 4)) == {bytes.fromhex("000000ff")}, "static render foundation clear changed")
    rects = {item["identity"]: item["normalizedMilliRect"] for item in minimal_reference["probes"]}
    widths = {item["identity"]: item["width"] for item in reference["outputs"]}
    for probe_color in reference["probeColors"]:
        require(rectangle_colors(frames[probe_color["checkpoint"]], widths[probe_color["checkpoint"]], rects[probe_color["identity"]]) == probe_color["bgra8"], f"semantic probe changed: {probe_color['identity']}")

    verdict = record["verdict"]
    require(verdict == {"build": True, "depthCapability": True, "shaderDiagnostics": True, "pixels": True, "resize": True, "lifecycle": True, "accepted": True, "scope": "static-render-foundation-and-minimal-3d"}, "verdict changed")
    referenced = {"record.json", "source-manifest.json", "reference-v1.json", "minimal-3d-reference-v1.json", build["binaryArtifact"]["path"], build["configureCache"]["path"], dependency["license"]["path"]}
    referenced |= {cmake_tool["raw"]["stdout"]["path"], cmake_tool["raw"]["stderr"]["path"]}
    for item in build["commands"] + [depth["raw"], runtime["raw"]]:
        referenced |= {item["stdout"]["path"], item["stderr"]["path"]}
    referenced |= {item["path"] for item in runtime["frames"]}
    require(set(files) == referenced, "archive file inventory changed")
    return {"accepted": True, "record": identity_bytes(files["record.json"]), "sourceManifest": run["sourceManifest"], "binary": run["binary"], "frames": len(runtime["frames"]), "probes": len(reference["probeColors"])}


def verify_archive(path):
    files, archive_identity = read_archive(path)
    result = verify_files(files)
    result["archive"] = archive_identity
    return result


def validate_addendum(addendum, archive_path):
    exact(addendum, {"schemaVersion", "identity", "purpose", "archive", "record", "sourceManifest", "verdict"}, "addendum")
    require(addendum["schemaVersion"] == 1 and addendum["identity"] == "sdl3-gpu-static-render-foundation-evidence-addendum-v2" and addendum["purpose"] == "archive-native-correctness-verification", "addendum identity changed")
    result = verify_archive(archive_path)
    require(addendum["archive"] == {"path": str(pathlib.Path(archive_path)), **result["archive"]}, "archive binding changed")
    require(addendum["record"] == result["record"] and addendum["sourceManifest"] == result["sourceManifest"], "record or source manifest binding changed")
    require(addendum["verdict"] == {"accepted": True, "archiveOnly": True, "stagingRequired": False, "frames": 5, "semanticProbes": 8}, "addendum verdict changed")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=pathlib.Path)
    arguments = parser.parse_args()
    print(json.dumps(verify_archive(arguments.archive), sort_keys=True))


if __name__ == "__main__":
    main()
