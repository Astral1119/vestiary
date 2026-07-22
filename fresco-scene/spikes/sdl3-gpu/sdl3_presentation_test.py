#!/usr/bin/env python3

import argparse
import hashlib
import json
import pathlib
import subprocess
import tempfile


class PresentationError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise PresentationError(message)


def exact(value, keys, path):
    require(isinstance(value, dict) and set(value) == set(keys), f"{path} schema changed")


def identity(path):
    value = path.read_bytes()
    return {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def run_json(executable, output_root):
    result = subprocess.run(
        [executable, "--output", output_root], check=True, text=True,
        capture_output=True,
    )
    records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    require(len(records) == 1, "presentation spike emitted an invalid JSON record count")
    return records[0]


def validate_window(value, expected, path):
    exact(value, expected, path)
    require(value == expected, f"{path} swapchain evidence changed")


def validate_lifecycle(value, expected, path):
    exact(value, expected, path)
    require(value == expected, f"{path} lifecycle changed")
    for created, released in (
        ("windowsCreated", "windowsDestroyed"),
        ("devicesCreated", "devicesDestroyed"),
        ("windowsClaimed", "windowsReleased"),
        ("commandBuffersAcquired", "commandBuffersSubmitted"),
        ("fencesCreated", "fencesWaited"),
        ("fencesCreated", "fencesReleased"),
        ("texturesCreated", "texturesReleased"),
        ("transfersCreated", "transfersReleased"),
    ):
        require(value[created] == value[released], f"{path} is unbalanced: {created}")
    require(value["swapchainAcquisitions"] == value["presents"] == value["commandBuffersSubmitted"], f"{path} presentation accounting changed")


def validate_outputs(outputs, expected, output_root):
    require(len(outputs) == len(expected), "output count changed")
    result = {}
    for actual, reference in zip(outputs, expected):
        exact(actual, {"identity", "path", "width", "height"}, f"output {reference['identity']}")
        require(actual["identity"] == reference["identity"] and actual["width"] == reference["width"] and actual["height"] == reference["height"], f"output metadata changed: {reference['identity']}")
        path = pathlib.Path(actual["path"])
        require(path == output_root / f"{reference['identity']}.bgra", f"output path changed: {reference['identity']}")
        require(identity(path) == {"sha256": reference["sha256"], "bytes": reference["bytes"]}, f"output bytes changed: {reference['identity']}")
        raw = path.read_bytes()
        expected_pixel = bytes.fromhex(reference["bgra8"])
        require(set(raw[index:index + 4] for index in range(0, len(raw), 4)) == {expected_pixel}, f"output clear changed: {reference['identity']}")
        result[reference["identity"]] = reference
    return result


def validate_event_schema(events, path):
    require(isinstance(events, list) and events, f"{path} events are missing")
    last_wall = -1
    for index, event in enumerate(events):
        exact(event, {"semanticNanoseconds", "wallObservedAtNanoseconds", "reason", "policyRevision", "fpsCeiling", "submissionOrdinal", "width", "height"}, f"{path} event {index}")
        require(event["wallObservedAtNanoseconds"] > last_wall, f"{path} wall observation order changed")
        require(event["submissionOrdinal"] == index + 1, f"{path} submission order changed")
        last_wall = event["wallObservedAtNanoseconds"]


def validate_static(value, reference, output_root):
    exact(value, {"identity", "manifestVersion", "criteriaVersion", "semanticClock", "wallClockRole", "window", "outputs", "intervals", "propertyDelta", "resize", "events", "lifecycle"}, "static")
    require(value["identity"] == "static-no-media" and value["manifestVersion"] == 1 and value["criteriaVersion"] == "static-baseline-v1", "static identity changed")
    require(value["semanticClock"] == "deterministic-virtual-nanoseconds" and value["wallClockRole"] == "event-order-observation-only-not-performance", "static clock boundary changed")
    validate_window(value["window"], reference["window"], "static window")
    outputs = validate_outputs(value["outputs"], reference["outputs"][:3], output_root)
    require(outputs["static-constructor"]["sha256"] != outputs["static-property"]["sha256"], "property output did not change")
    zero = {"evaluations": 0, "schedulerDecisions": 0, "submissions": 0, "presents": 0}
    require(value["intervals"] == {
        "initialQuiescence": {"fromNanoseconds": 0, "toNanoseconds": 400000000, **zero},
        "propertyRequiescence": {"fromNanoseconds": 400000001, "toNanoseconds": 700000001, **zero},
    }, "static durable quiescence changed")
    require(value["propertyDelta"] == {"evaluations": 1, "schedulerDecisions": 1, "submissions": 1, "presents": 1}, "property invalidation changed")
    require(value["resize"] == {"requestedLogicalWidth": 480, "requestedLogicalHeight": 270, "actualLogicalWidth": 480, "actualLogicalHeight": 270, "actualPixelWidth": 960, "actualPixelHeight": 540, "submissionWidth": 960, "submissionHeight": 540, "evaluations": 1, "schedulerDecisions": 1, "submissions": 1, "presents": 1}, "resize invalidation changed")
    events = value["events"]
    validate_event_schema(events, "static")
    require([{key: event[key] for key in event if key != "wallObservedAtNanoseconds"} for event in events] == [
        {"semanticNanoseconds": 0, "reason": "constructor", "policyRevision": 1, "fpsCeiling": 60, "submissionOrdinal": 1, "width": 640, "height": 360},
        {"semanticNanoseconds": 400000001, "reason": "property-invalidation", "policyRevision": 1, "fpsCeiling": 60, "submissionOrdinal": 2, "width": 640, "height": 360},
        {"semanticNanoseconds": 700000002, "reason": "resize-invalidation", "policyRevision": 1, "fpsCeiling": 60, "submissionOrdinal": 3, "width": 960, "height": 540},
    ], "static event semantics changed")
    validate_lifecycle(value["lifecycle"], {"windowsCreated": 1, "windowsDestroyed": 1, "devicesCreated": 1, "devicesDestroyed": 1, "windowsClaimed": 1, "windowsReleased": 1, "evaluations": 3, "schedulerDecisions": 3, "commandBuffersAcquired": 3, "commandBuffersSubmitted": 3, "swapchainAcquisitions": 3, "presents": 3, "fencesCreated": 3, "fencesWaited": 3, "fencesReleased": 3, "texturesCreated": 2, "texturesReleased": 2, "transfersCreated": 3, "transfersReleased": 3, "resizeRetirementsAfterCompletion": 1}, "static")


def expected_continuous_events():
    result = []
    start = 0
    ordinal = 0
    for revision, (fps, duration_ms) in enumerate(((15, 800), (30, 600), (60, 450)), 1):
        frames = fps * duration_ms // 1000
        for frame in range(frames):
            ordinal += 1
            result.append({"semanticNanoseconds": start + (frame + 1) * 1_000_000_000 // fps, "reason": "continuous-lease+fps-ceiling", "policyRevision": revision, "fpsCeiling": fps, "submissionOrdinal": ordinal, "width": 640, "height": 360})
        start += duration_ms * 1_000_000
    resume_start = start + 300_000_000
    for frame in range(21):
        ordinal += 1
        result.append({"semanticNanoseconds": resume_start + (frame + 1) * 1_000_000_000 // 60, "reason": "continuous-lease+fps-ceiling", "policyRevision": 4, "fpsCeiling": 60, "submissionOrdinal": ordinal, "width": 640, "height": 360})
    return result


def validate_continuous(value, reference, output_root):
    exact(value, {"identity", "manifestVersion", "criteriaVersion", "semanticClock", "wallClockRole", "window", "phases", "pause", "resume", "outputs", "events", "lifecycle"}, "continuous")
    require(value["identity"] == "continuous-animation" and value["manifestVersion"] == 1 and value["criteriaVersion"] == "continuous-cadence-v1", "continuous identity changed")
    require(value["semanticClock"] == "deterministic-virtual-nanoseconds" and value["wallClockRole"] == "event-order-observation-only-not-performance", "continuous clock boundary changed")
    validate_window(value["window"], reference["window"], "continuous window")
    expected_phases = []
    for revision, (fps, duration, frames) in enumerate(((15, 800, 12), (30, 600, 18), (60, 450, 27)), 1):
        expected_phases.append({"fpsCeiling": fps, "durationMilliseconds": duration, "policyRevision": revision, "frames": frames, "schedulerDecisions": frames, "evaluations": frames, "submissions": frames, "presents": frames, "coalescedReasonsPerFrame": 2})
    require(value["phases"] == expected_phases, "continuous phase counts or coalescing changed")
    require(value["pause"] == {"fromNanoseconds": 1850000000, "toNanoseconds": 2150000000, "frames": 0, "evaluations": 0, "schedulerDecisions": 0, "submissions": 0, "presents": 0}, "continuous pause changed")
    require(value["resume"] == {"durationMilliseconds": 350, "fpsCeiling": 60, "policyRevision": 4, "frames": 21, "schedulerDecisions": 21, "submissions": 21, "presents": 21, "firstFrameBoundNanoseconds": 16666666}, "continuous resume changed")
    validate_outputs(value["outputs"], reference["outputs"][3:], output_root)
    events = value["events"]
    validate_event_schema(events, "continuous")
    stripped = [{key: event[key] for key in event if key != "wallObservedAtNanoseconds"} for event in events]
    require(stripped == expected_continuous_events(), "continuous deadlines, retiming, or no-overspeed order changed")
    require(events[57]["semanticNanoseconds"] - value["pause"]["toNanoseconds"] == 16666666, "resume first-frame bound changed")
    validate_lifecycle(value["lifecycle"], {"windowsCreated": 1, "windowsDestroyed": 1, "devicesCreated": 1, "devicesDestroyed": 1, "windowsClaimed": 1, "windowsReleased": 1, "evaluations": 78, "schedulerDecisions": 78, "commandBuffersAcquired": 78, "commandBuffersSubmitted": 78, "swapchainAcquisitions": 78, "presents": 78, "fencesCreated": 78, "fencesWaited": 78, "fencesReleased": 78, "texturesCreated": 1, "texturesReleased": 1, "transfersCreated": 4, "transfersReleased": 4, "resizeRetirementsAfterCompletion": 0}, "continuous")


def validate_bindings(reference, reference_root):
    require([item["identity"] for item in reference["workloadBindings"]] == ["static-no-media", "continuous-animation"], "workload binding order changed")
    for binding in reference["workloadBindings"]:
        root = reference_root / binding["identity"]
        for key, name in (("manifest", "manifest-v1.json"), ("trace", "trace-v1.json"), ("reference", "reference-v1.json")):
            require(identity(root / name) == binding[key], f"{binding['identity']} {key} binding changed")


def validate_record(value, reference, reference_root, output_root):
    exact(value, {"schemaVersion", "mode", "sdlVersion", "semanticTimeDistinctFromWallTime", "performanceClaim", "workloads"}, "record")
    require(value["schemaVersion"] == 1 and value["mode"] == "presentation-scheduling" and value["sdlVersion"] == "3.4.10", "record identity changed")
    require(value["semanticTimeDistinctFromWallTime"] is True and value["performanceClaim"] is False, "semantic/wall clock boundary changed")
    validate_bindings(reference, reference_root)
    require([item.get("identity") for item in value["workloads"]] == ["static-no-media", "continuous-animation"], "workload order changed")
    validate_static(value["workloads"][0], reference, output_root)
    validate_continuous(value["workloads"][1], reference, output_root)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", type=pathlib.Path, required=True)
    parser.add_argument("--reference-root", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    reference = load(pathlib.Path(__file__).with_name("presentation-reference-v1.json"))
    with tempfile.TemporaryDirectory(prefix="fresco-sdl3-presentation-") as directory:
        output_root = pathlib.Path(directory)
        record = run_json(arguments.executable, output_root)
        validate_record(record, reference, arguments.reference_root, output_root)


if __name__ == "__main__":
    main()
