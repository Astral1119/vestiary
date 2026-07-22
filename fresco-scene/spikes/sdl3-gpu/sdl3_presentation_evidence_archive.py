#!/usr/bin/env python3

import argparse
import hashlib
import io
import json
import pathlib
import re
import tarfile

import sdl3_presentation_test as gate


class ArchiveError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise ArchiveError(message)


def identity_bytes(value):
    return {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}


def exact(value, keys, path):
    require(isinstance(value, dict) and set(value) == set(keys), f"{path} schema changed")


def read_archive(path):
    raw = pathlib.Path(path).read_bytes()
    files = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as archive:
            for member in archive:
                pure = pathlib.PurePosixPath(member.name)
                require(not pure.is_absolute() and ".." not in pure.parts, "unsafe archive path")
                require(member.isfile() and member.name not in files, "unsafe or duplicate archive member")
                stream = archive.extractfile(member)
                require(stream is not None, "archive member has no bytes")
                files[member.name] = stream.read()
    except (tarfile.TarError, OSError) as error:
        raise ArchiveError("archive cannot be read") from error
    return files, identity_bytes(raw)


def load(files, path):
    require(path in files, f"missing {path}")
    try:
        return json.loads(files[path])
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ArchiveError(f"invalid JSON: {path}") from error


def descriptor(files, value, path):
    exact(value, {"path", "sha256", "bytes"}, path)
    require(value["path"] in files and identity_bytes(files[value["path"]]) == {"sha256": value["sha256"], "bytes": value["bytes"]}, f"{path} identity changed")


def command(files, value, path):
    exact(value, {"command", "startedAtUtc", "completedAtUtc", "durationSeconds", "exitCode", "warningCount", "stdout", "stderr"}, path)
    require(value["exitCode"] == 0 and value["warningCount"] == 0 and value["durationSeconds"] >= 0, f"{path} failed or warned")
    descriptor(files, value["stdout"], f"{path}.stdout")
    descriptor(files, value["stderr"], f"{path}.stderr")


def cache_values(value):
    result = {}
    for line in value.decode().splitlines():
        match = re.match(r"^([^#/:][^:=]*)(?::[^=]+)?=(.*)$", line)
        if match:
            result[match.group(1)] = match.group(2)
    return result


def validate_semantics(runtime, reference):
    exact(runtime, {"schemaVersion", "mode", "sdlVersion", "semanticTimeDistinctFromWallTime", "performanceClaim", "workloads"}, "runtime")
    require(runtime["schemaVersion"] == 1 and runtime["mode"] == "presentation-scheduling" and runtime["sdlVersion"] == "3.4.10" and runtime["semanticTimeDistinctFromWallTime"] is True and runtime["performanceClaim"] is False, "runtime identity or clock boundary changed")
    static, continuous = runtime["workloads"]
    require(static["identity"] == "static-no-media" and continuous["identity"] == "continuous-animation", "workload order changed")
    gate.validate_window(static["window"], reference["window"], "static window")
    gate.validate_window(continuous["window"], reference["window"], "continuous window")
    zero = {"evaluations": 0, "schedulerDecisions": 0, "submissions": 0, "presents": 0}
    require(static["intervals"] == {"initialQuiescence": {"fromNanoseconds": 0, "toNanoseconds": 400000000, **zero}, "propertyRequiescence": {"fromNanoseconds": 400000001, "toNanoseconds": 700000001, **zero}}, "static quiescence changed")
    require(static["propertyDelta"] == {"evaluations": 1, "schedulerDecisions": 1, "submissions": 1, "presents": 1}, "property wake changed")
    require(static["resize"] == {"requestedLogicalWidth": 480, "requestedLogicalHeight": 270, "actualLogicalWidth": 480, "actualLogicalHeight": 270, "actualPixelWidth": 960, "actualPixelHeight": 540, "submissionWidth": 960, "submissionHeight": 540, "evaluations": 1, "schedulerDecisions": 1, "submissions": 1, "presents": 1}, "resize evidence changed")
    gate.validate_event_schema(static["events"], "static")
    require([item["semanticNanoseconds"] for item in static["events"]] == [0, 400000001, 700000002] and [item["reason"] for item in static["events"]] == ["constructor", "property-invalidation", "resize-invalidation"], "static event order changed")
    gate.validate_lifecycle(static["lifecycle"], {"windowsCreated": 1, "windowsDestroyed": 1, "devicesCreated": 1, "devicesDestroyed": 1, "windowsClaimed": 1, "windowsReleased": 1, "evaluations": 3, "schedulerDecisions": 3, "commandBuffersAcquired": 3, "commandBuffersSubmitted": 3, "swapchainAcquisitions": 3, "presents": 3, "fencesCreated": 3, "fencesWaited": 3, "fencesReleased": 3, "texturesCreated": 2, "texturesReleased": 2, "transfersCreated": 3, "transfersReleased": 3, "resizeRetirementsAfterCompletion": 1}, "static")
    expected_phases = [{"fpsCeiling": fps, "durationMilliseconds": duration, "policyRevision": revision, "frames": frames, "schedulerDecisions": frames, "evaluations": frames, "submissions": frames, "presents": frames, "coalescedReasonsPerFrame": 2} for revision, (fps, duration, frames) in enumerate(((15, 800, 12), (30, 600, 18), (60, 450, 27)), 1)]
    require(continuous["phases"] == expected_phases, "continuous cadence or coalescing changed")
    require(continuous["pause"] == {"fromNanoseconds": 1850000000, "toNanoseconds": 2150000000, "frames": 0, "evaluations": 0, "schedulerDecisions": 0, "submissions": 0, "presents": 0}, "pause changed")
    require(continuous["resume"] == {"durationMilliseconds": 350, "fpsCeiling": 60, "policyRevision": 4, "frames": 21, "schedulerDecisions": 21, "submissions": 21, "presents": 21, "firstFrameBoundNanoseconds": 16666666}, "resume changed")
    gate.validate_event_schema(continuous["events"], "continuous")
    stripped = [{key: event[key] for key in event if key != "wallObservedAtNanoseconds"} for event in continuous["events"]]
    require(stripped == gate.expected_continuous_events(), "continuous deadlines or no-overspeed evidence changed")
    gate.validate_lifecycle(continuous["lifecycle"], {"windowsCreated": 1, "windowsDestroyed": 1, "devicesCreated": 1, "devicesDestroyed": 1, "windowsClaimed": 1, "windowsReleased": 1, "evaluations": 78, "schedulerDecisions": 78, "commandBuffersAcquired": 78, "commandBuffersSubmitted": 78, "swapchainAcquisitions": 78, "presents": 78, "fencesCreated": 78, "fencesWaited": 78, "fencesReleased": 78, "texturesCreated": 1, "texturesReleased": 1, "transfersCreated": 4, "transfersReleased": 4, "resizeRetirementsAfterCompletion": 0}, "continuous")


def verify_files(files):
    record = load(files, "record.json")
    exact(record, {"schemaVersion", "identity", "run", "host", "display", "build", "dependency", "contracts", "reference", "windowEvidence", "semanticDriver", "runtime", "lifecycle", "verdict"}, "record")
    require(record["schemaVersion"] == 1 and record["identity"] == "sdl3-presentation-scheduling-formal-v1", "record identity changed")
    run = record["run"]
    require(run["purpose"] == "correctness" and run["agentRole"] == "subagent" and run["agentIdentity"] == "/root/architecture_contract", "run ownership changed")
    require(identity_bytes(files["source-manifest.json"]) == run["sourceManifest"], "source manifest changed")
    source = load(files, "source-manifest.json")
    require(source["identity"] == "sdl3-presentation-scheduling-source-v1" and len({item["path"] for item in source["files"]}) == len(source["files"]), "source inventory changed")

    build = record["build"]
    require(build["identity"] == "sdl3-presentation-scheduling-appleclang-v1" and build["generator"] == "Unix Makefiles" and build["buildType"] == "Release" and build["deploymentTarget"] == {"status": "available", "value": "14.0"}, "build identity changed")
    descriptor(files, build["configureCache"], "configure cache")
    cache = cache_values(files[build["configureCache"]["path"]])
    require(cache.get("CMAKE_GENERATOR") == "Unix Makefiles" and cache.get("CMAKE_BUILD_TYPE") == "Release" and cache.get("CMAKE_OSX_DEPLOYMENT_TARGET") == "14.0", "configure cache changed")
    command(files, build["cmakeTool"]["raw"], "cmake tool")
    require(build["cmakeTool"]["version"] == "cmake version 4.4.0", "cmake tool changed")
    for item, name in zip(build["commands"], ("configure", "build", "test")):
        command(files, item, name)
    descriptor(files, build["binaryArtifact"], "binary")
    require(run["binary"] == {"sha256": build["binaryArtifact"]["sha256"], "bytes": build["binaryArtifact"]["bytes"]}, "binary binding changed")
    license_item = record["dependency"]["license"]
    require(record["dependency"]["sourceTarSha256"] == "12b34280415ec8418c864408b93d008a20a6530687ee613d60bfbd20411f2785" and license_item["sha256"] == "1c040b8271b37e5076359f8fd54240e371114112924d2df81ef87c7d6a1dfdfd" and identity_bytes(files[license_item["path"]]) == {"sha256": license_item["sha256"], "bytes": license_item["bytes"]}, "SDL dependency changed")

    reference = load(files, record["reference"]["path"])
    require(reference["identity"] == record["reference"]["identity"] and identity_bytes(files[record["reference"]["path"]]) == {"sha256": record["reference"]["sha256"], "bytes": record["reference"]["bytes"]}, "presentation reference changed")
    require(len(record["contracts"]) == 6, "contract binding count changed")
    for contract in record["contracts"]:
        require(identity_bytes(files[contract["path"]]) == {"sha256": contract["sha256"], "bytes": contract["bytes"]}, "workload contract changed")
    runtime_raw = record["runtime"]["raw"]
    command(files, runtime_raw, "runtime")
    raw_values = [json.loads(line) for line in files[runtime_raw["stdout"]["path"]].decode().splitlines() if line.startswith("{")]
    require(raw_values == [record["runtime"]["record"]], "raw runtime changed")
    try:
        validate_semantics(record["runtime"]["record"], reference)
    except gate.PresentationError as error:
        raise ArchiveError(str(error)) from error
    require(record["windowEvidence"] == [item["window"] for item in record["runtime"]["record"]["workloads"]], "window evidence binding changed")
    require(record["semanticDriver"] == {"clock": "deterministic-virtual-nanoseconds", "wallClockRole": "event-order-observation-only-not-performance", "performanceClaim": False, "staticEvents": 3, "continuousEvents": 78}, "semantic driver changed")
    require(record["lifecycle"] == {item["identity"]: item["lifecycle"] for item in record["runtime"]["record"]["workloads"]}, "lifecycle binding changed")

    expected_outputs = {item["identity"]: item for item in reference["outputs"]}
    require(len(record["runtime"]["frames"]) == 7, "frame count changed")
    require([item["name"] for item in record["runtime"]["frames"]] == [item["identity"] for item in reference["outputs"]], "frame order changed")
    for frame in record["runtime"]["frames"]:
        expected = expected_outputs[frame["name"]]
        require(frame["path"] == f"artifacts/sha256/{frame['sha256'][:2]}/{frame['sha256']}" and frame["sha256"] == expected["sha256"] and frame["bytes"] == expected["bytes"], f"frame reference changed: {frame['name']}")
        require(identity_bytes(files[frame["path"]]) == {"sha256": frame["sha256"], "bytes": frame["bytes"]}, f"frame bytes changed: {frame['name']}")
        raw = files[frame["path"]]
        pixel = bytes.fromhex(expected["bgra8"])
        require(set(raw[index:index + 4] for index in range(0, len(raw), 4)) == {pixel}, f"frame color changed: {frame['name']}")
    require(record["verdict"] == {"build": True, "contracts": True, "swapchain": True, "pixels": True, "staticScheduling": True, "continuousScheduling": True, "resize": True, "lifecycle": True, "accepted": True, "performance": "not-measured"}, "verdict changed")
    referenced = {"record.json", "source-manifest.json", record["reference"]["path"], build["configureCache"]["path"], build["binaryArtifact"]["path"], license_item["path"]}
    for item in record["contracts"] + record["runtime"]["frames"]:
        referenced.add(item["path"])
    for item in [build["cmakeTool"]["raw"], *build["commands"], runtime_raw]:
        referenced |= {item["stdout"]["path"], item["stderr"]["path"]}
    require(set(files) == referenced, "archive inventory changed")
    return {"accepted": True, "record": identity_bytes(files["record.json"]), "sourceManifest": run["sourceManifest"], "binary": run["binary"], "frames": 7, "staticPresents": 3, "continuousPresents": 78}


def verify_archive(path):
    files, archive_identity = read_archive(path)
    result = verify_files(files)
    result["archive"] = archive_identity
    return result


def validate_addendum(addendum, archive_path):
    exact(addendum, {"schemaVersion", "identity", "purpose", "archive", "record", "sourceManifest", "verdict"}, "addendum")
    require(addendum["schemaVersion"] == 1 and addendum["identity"] == "sdl3-presentation-scheduling-evidence-addendum-v1" and addendum["purpose"] == "archive-native-correctness-verification", "addendum identity changed")
    result = verify_archive(archive_path)
    require(addendum["archive"] == {"path": str(pathlib.Path(archive_path)), **result["archive"]} and addendum["record"] == result["record"] and addendum["sourceManifest"] == result["sourceManifest"], "addendum binding changed")
    require(addendum["verdict"] == {"accepted": True, "archiveOnly": True, "stagingRequired": False, "frames": 7, "staticPresents": 3, "continuousPresents": 78}, "addendum verdict changed")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=pathlib.Path)
    arguments = parser.parse_args()
    print(json.dumps(verify_archive(arguments.archive), sort_keys=True))


if __name__ == "__main__":
    main()
