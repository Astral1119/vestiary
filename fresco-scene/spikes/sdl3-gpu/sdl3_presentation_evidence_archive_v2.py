#!/usr/bin/env python3

import argparse
import hashlib
import io
import json
import pathlib
import re
import tarfile

import sdl3_presentation_test_v2 as gate


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


class ArchiveError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise ArchiveError(message)


def exact(value, keys, path):
    require(isinstance(value, dict) and set(value) == set(keys), f"{path} schema changed")


def identity_bytes(value):
    return {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}


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


def validate_lineage(value):
    exact(value, {"foundation", "presentationPredecessor"}, "lineage")
    require(value == {"foundation": FOUNDATION, "presentationPredecessor": PRESENTATION_V1}, "lineage identity changed")
    for item in value.values():
        path = pathlib.Path(item["path"])
        require(path.is_file() and identity_bytes(path.read_bytes()) == {"sha256": item["sha256"], "bytes": item["bytes"]}, f"actual lineage archive changed: {path}")


def validate_runtime(runtime, reference, traces):
    exact(runtime, {"schemaVersion", "mode", "sdlVersion", "schedulerIdentity", "semanticTimeDistinctFromWallTime", "performanceClaim", "drawablePixelClaim", "retainedFrameRole", "faultMode", "workloads"}, "runtime")
    require(runtime["schemaVersion"] == 2 and runtime["mode"] == "presentation-scheduling" and runtime["sdlVersion"] == "3.4.10", "runtime identity changed")
    require(runtime["schedulerIdentity"] == "standalone-virtual-state-machine-v1" and runtime["semanticTimeDistinctFromWallTime"] is True and runtime["performanceClaim"] is False, "scheduler clock boundary changed")
    require(runtime["drawablePixelClaim"] is False and runtime["retainedFrameRole"] == "mirrored-render-oracle" and runtime["faultMode"] == "none", "oracle or fault boundary changed")
    static, continuous = runtime["workloads"]
    require([static.get("identity"), continuous.get("identity")] == ["static-no-media", "continuous-animation"], "workload order changed")
    exact(static, {"identity", "manifestVersion", "criteriaVersion", "semanticClock", "wallClockRole", "window", "scheduler", "resizeEvidence", "outputs", "lifecycle"}, "static")
    exact(continuous, {"identity", "manifestVersion", "criteriaVersion", "semanticClock", "wallClockRole", "window", "scheduler", "outputs", "lifecycle"}, "continuous")
    require(static["manifestVersion"] == continuous["manifestVersion"] == 1 and static["criteriaVersion"] == "static-baseline-v1" and continuous["criteriaVersion"] == "continuous-cadence-v1", "workload contracts changed")
    require(static["semanticClock"] == continuous["semanticClock"] == "deterministic-virtual-nanoseconds" and static["wallClockRole"] == continuous["wallClockRole"] == "event-order-observation-only-not-performance", "workload clock boundary changed")
    gate.validate_window(static["window"], reference["window"], "static window")
    gate.validate_window(continuous["window"], reference["window"], "continuous window")
    static_decisions = gate.validate_scheduler(static["scheduler"], gate.static_model(traces["static-no-media"]), "static scheduler")
    continuous_decisions = gate.validate_scheduler(continuous["scheduler"], gate.continuous_model(traces["continuous-animation"]), "continuous scheduler")
    require([item["semanticNanoseconds"] for item in static_decisions] == [0, 400000001, 700000002], "static quiescence changed")
    require(static["resizeEvidence"] == {"requestedLogicalWidth": 480, "requestedLogicalHeight": 270, "actualLogicalWidth": 480, "actualLogicalHeight": 270, "actualPixelWidth": 960, "actualPixelHeight": 540}, "resize evidence changed")
    gate.validate_lifecycle(static["lifecycle"], static_decisions, static["outputs"], "static lifecycle", 2)
    gate.validate_lifecycle(continuous["lifecycle"], continuous_decisions, continuous["outputs"], "continuous lifecycle", 1)
    require([(item["completion"]["width"], item["completion"]["height"]) for item in static_decisions] == [(640, 360), (640, 360), (960, 540)], "static completion extents changed")
    require(all((item["completion"]["width"], item["completion"]["height"]) == (640, 360) for item in continuous_decisions), "continuous completion extents changed")
    require([sum(item["policyRevision"] == revision for item in continuous_decisions) for revision in (1, 2, 3, 4)] == [12, 18, 27, 21], "continuous phase counts changed")
    coalesced = [item["reasons"] for item in continuous_decisions if len(item["reasons"]) > 1]
    require(coalesced == [["fps-ceiling", "continuous-lease"], ["fps-ceiling", "scene-property", "continuous-lease"], ["resume-invalidation", "continuous-lease"]], "reason coalescing changed")
    return static_decisions, continuous_decisions


def verify_files(files):
    record = load(files, "record.json")
    exact(record, {"schemaVersion", "identity", "run", "lineage", "host", "display", "build", "dependency", "contracts", "reference", "schedulerEvidence", "presentationEvidence", "oracleBoundary", "runtime", "lifecycle", "verdict"}, "record")
    require(record["schemaVersion"] == 2 and record["identity"] == "sdl3-presentation-scheduling-formal-v2", "record identity changed")
    run = record["run"]
    require(run["purpose"] == "correctness" and run["agentRole"] == "subagent" and run["agentIdentity"] == "/root/architecture_contract", "run ownership changed")
    validate_lineage(record["lineage"])
    require(identity_bytes(files["source-manifest.json"]) == run["sourceManifest"], "source manifest changed")
    source = load(files, "source-manifest.json")
    require(source["identity"] == "sdl3-presentation-scheduling-source-v2" and len(source["files"]) == 23 and len({item["path"] for item in source["files"]}) == 23, "source inventory changed")

    build = record["build"]
    require(build["identity"] == "sdl3-presentation-scheduling-appleclang-v2" and build["generator"] == "Unix Makefiles" and build["buildType"] == "Release" and build["deploymentTarget"] == {"status": "available", "value": "14.0"}, "build identity changed")
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
    require(record["dependency"]["sourceTarSha256"] == "12b34280415ec8418c864408b93d008a20a6530687ee613d60bfbd20411f2785" and identity_bytes(files[license_item["path"]]) == {"sha256": license_item["sha256"], "bytes": license_item["bytes"]}, "SDL dependency changed")

    reference = load(files, record["reference"]["path"])
    require(reference["identity"] == record["reference"]["identity"] and identity_bytes(files[record["reference"]["path"]]) == {"sha256": record["reference"]["sha256"], "bytes": record["reference"]["bytes"]}, "presentation reference changed")
    require(len(record["contracts"]) == 6, "contract binding count changed")
    traces = {}
    for contract in record["contracts"]:
        require(identity_bytes(files[contract["path"]]) == {"sha256": contract["sha256"], "bytes": contract["bytes"]}, "workload contract changed")
        if contract["kind"] == "trace":
            traces[contract["workload"]] = json.loads(files[contract["path"]])
    runtime_raw = record["runtime"]["raw"]
    command(files, runtime_raw, "runtime")
    raw_values = [json.loads(line) for line in files[runtime_raw["stdout"]["path"]].decode().splitlines() if line.startswith("{")]
    require(raw_values == [record["runtime"]["record"]], "raw runtime changed")
    try:
        static_decisions, continuous_decisions = validate_runtime(record["runtime"]["record"], reference, traces)
    except gate.PresentationError as error:
        raise ArchiveError(str(error)) from error

    runtime = record["runtime"]["record"]
    workloads = runtime["workloads"]
    require(record["schedulerEvidence"] == {"identity": "standalone-virtual-state-machine-v1", "clock": "deterministic-virtual-nanoseconds", "inputEvents": {item["identity"]: len(item["scheduler"]["inputEvents"]) for item in workloads}, "decisions": {item["identity"]: len(item["scheduler"]["decisions"]) for item in workloads}, "completionRequiredBeforeNextDecision": True}, "scheduler evidence binding changed")
    require(record["presentationEvidence"] == {"videoDriver": "cocoa", "gpuDriver": "metal", "swapchainAcquisitions": {item["identity"]: item["lifecycle"]["swapchainAcquisitions"] for item in workloads}, "swapchainPresents": {item["identity"]: item["lifecycle"]["presents"] for item in workloads}}, "presentation evidence binding changed")
    require(record["oracleBoundary"] == {"retainedFrameRole": "mirrored-render-oracle", "drawablePixelClaim": False, "swapchainWorkProvenSeparately": True}, "oracle boundary changed")
    require(record["lifecycle"] == {item["identity"]: item["lifecycle"] for item in workloads}, "lifecycle binding changed")

    expected_outputs = {item["identity"]: item for item in reference["outputs"]}
    runtime_outputs = [output for workload in workloads for output in workload["outputs"]]
    output_order = [output["identity"] for output in runtime_outputs]
    require(len(record["runtime"]["frames"]) == 7 and [item["name"] for item in record["runtime"]["frames"]] == output_order == list(expected_outputs), "oracle inventory changed")
    for output in runtime_outputs:
        expected = expected_outputs[output["identity"]]
        exact(output, {"identity", "evidenceRole", "path", "width", "height"}, f"runtime oracle {output['identity']}")
        require(output["evidenceRole"] == "mirrored-render-oracle" and output["width"] == expected["width"] and output["height"] == expected["height"] and pathlib.Path(output["path"]).name == f"{output['identity']}.bgra", f"runtime oracle metadata changed: {output['identity']}")
    for frame in record["runtime"]["frames"]:
        expected = expected_outputs[frame["name"]]
        require(frame["evidenceRole"] == "mirrored-render-oracle" and frame["path"] == f"artifacts/sha256/{frame['sha256'][:2]}/{frame['sha256']}" and frame["sha256"] == expected["sha256"] and frame["bytes"] == expected["bytes"], f"oracle reference changed: {frame['name']}")
        require(identity_bytes(files[frame["path"]]) == {"sha256": frame["sha256"], "bytes": frame["bytes"]}, f"oracle bytes changed: {frame['name']}")
        pixel = bytes.fromhex(expected["bgra8"])
        raw = files[frame["path"]]
        require(set(raw[index:index + 4] for index in range(0, len(raw), 4)) == {pixel}, f"oracle color changed: {frame['name']}")
    expected_verdict = {"build": True, "contracts": True, "schedulerStateMachine": True, "decisionAuthorizedPresentation": True, "swapchain": True, "mirroredOracles": True, "staticScheduling": True, "continuousScheduling": True, "resize": True, "lifecycle": True, "accepted": True, "performance": "not-measured"}
    require(record["verdict"] == expected_verdict, "verdict changed")
    referenced = {"record.json", "source-manifest.json", record["reference"]["path"], build["configureCache"]["path"], build["binaryArtifact"]["path"], license_item["path"]}
    for item in record["contracts"] + record["runtime"]["frames"]:
        referenced.add(item["path"])
    for item in [build["cmakeTool"]["raw"], *build["commands"], runtime_raw]:
        referenced |= {item["stdout"]["path"], item["stderr"]["path"]}
    require(set(files) == referenced, "archive inventory changed")
    return {"accepted": True, "record": identity_bytes(files["record.json"]), "sourceManifest": run["sourceManifest"], "binary": run["binary"], "lineage": record["lineage"], "oracles": 7, "staticDecisions": len(static_decisions), "continuousDecisions": len(continuous_decisions)}


def verify_archive(path):
    files, archive_identity = read_archive(path)
    result = verify_files(files)
    result["archive"] = archive_identity
    return result


def validate_addendum(addendum, archive_path):
    exact(addendum, {"schemaVersion", "identity", "purpose", "archive", "record", "sourceManifest", "lineage", "verdict"}, "addendum")
    require(addendum["schemaVersion"] == 2 and addendum["identity"] == "sdl3-presentation-scheduling-evidence-addendum-v2" and addendum["purpose"] == "archive-native-correctness-verification", "addendum identity changed")
    result = verify_archive(archive_path)
    require(addendum["archive"] == {"path": str(pathlib.Path(archive_path)), **result["archive"]} and addendum["record"] == result["record"] and addendum["sourceManifest"] == result["sourceManifest"] and addendum["lineage"] == result["lineage"], "addendum binding changed")
    require(addendum["verdict"] == {"accepted": True, "archiveOnly": True, "stagingRequired": False, "oracles": 7, "staticDecisions": 3, "continuousDecisions": 78, "performance": "not-measured"}, "addendum verdict changed")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=pathlib.Path)
    arguments = parser.parse_args()
    print(json.dumps(verify_archive(arguments.archive), sort_keys=True))


if __name__ == "__main__":
    main()
