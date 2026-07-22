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
    value = pathlib.Path(path).read_bytes()
    return {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}


def load(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def run_json(executable, output_root, fault=None):
    command = [executable, "--output", output_root]
    if fault is not None:
        command += ["--fault", fault]
    result = subprocess.run(command, check=True, text=True, capture_output=True)
    records = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    require(len(records) == 1, "presentation spike emitted an invalid JSON record count")
    return records[0]


class SchedulerModel:
    def __init__(self):
        self.now = 0
        self.fps = 0
        self.revision = 0
        self.lease = False
        self.paused = False
        self.anchor = 0
        self.ordinal = 0
        self.next_wake = None
        self.pending = []
        self.inputs = []
        self.decisions = []

    @property
    def period(self):
        return 0 if self.fps == 0 else 1_000_000_000 // self.fps

    def record(self, kind, reason="", target=None, requested_fps=0):
        self.inputs.append({
            "sequence": len(self.inputs) + 1,
            "appliedAtNanoseconds": self.now,
            "kind": kind,
            "reason": reason,
            "targetNanoseconds": target,
            "requestedFpsCeiling": requested_fps,
            "policyRevisionAfter": self.revision,
            "nextWakeAfterNanoseconds": self.next_wake,
        })

    def queue(self, reason):
        if reason not in self.pending:
            self.pending.append(reason)

    def deadline(self):
        return self.anchor + self.ordinal * 1_000_000_000 // self.fps

    def static_policy(self, fps):
        self.fps = fps
        self.revision += 1
        self.record("static-policy", "fps-ceiling", requested_fps=fps)

    def invalidate(self, reason, kind="invalidate"):
        self.queue(reason)
        if not self.lease and not self.paused:
            self.next_wake = self.now
        self.record(kind, reason)

    def start(self, fps):
        self.lease = True
        self.fps = fps
        self.revision += 1
        self.anchor = self.now
        self.ordinal = 1
        self.next_wake = self.deadline()
        self.record("lease-start", "continuous-lease", requested_fps=fps)

    def retime(self, fps):
        self.fps = fps
        self.revision += 1
        self.anchor = self.now
        self.ordinal = 1
        self.queue("fps-ceiling")
        self.next_wake = self.deadline()
        self.record("retime", "fps-ceiling", requested_fps=fps)

    def pause(self):
        self.paused = True
        self.next_wake = None
        self.record("pause", "pause", requested_fps=self.fps)

    def resume(self):
        self.paused = False
        self.revision += 1
        self.anchor = self.now
        self.ordinal = 1
        self.queue("resume-invalidation")
        self.next_wake = self.deadline()
        self.record("resume", "resume-invalidation", requested_fps=self.fps)

    def advance(self, target):
        self.record("advance", target=target)
        while self.next_wake is not None and self.next_wake <= target:
            self.now = self.next_wake
            if self.lease and not self.paused:
                self.queue("continuous-lease")
                self.ordinal += 1
                self.next_wake = self.deadline()
            else:
                self.next_wake = None
            require(self.pending, "reference scheduler produced an empty decision")
            self.decisions.append({
                "sequence": len(self.decisions) + 1,
                "kind": "present",
                "semanticNanoseconds": self.now,
                "reasons": self.pending,
                "policyRevision": self.revision,
                "fpsCeiling": self.fps,
                "periodNanoseconds": self.period,
                "nextWakeAfterNanoseconds": self.next_wake,
            })
            self.pending = []
        self.now = target

    def final_state(self):
        return {
            "nowNanoseconds": self.now,
            "fpsCeiling": self.fps,
            "periodNanoseconds": self.period,
            "continuousLease": self.lease,
            "paused": self.paused,
            "nextWakeNanoseconds": self.next_wake,
        }


def static_model(trace):
    model = SchedulerModel()
    boundary = (trace["settleMilliseconds"] + trace["quiescenceMilliseconds"]) * 1_000_000
    property_at = boundary + 1
    resize_boundary = property_at + trace["quiescenceMilliseconds"] * 1_000_000
    resize_at = resize_boundary + 1
    model.static_policy(trace["fpsCeiling"])
    model.invalidate("constructor", "constructor-invalidation")
    model.advance(0)
    model.advance(boundary)
    model.advance(property_at)
    model.invalidate("property-invalidation")
    model.advance(property_at)
    model.advance(resize_boundary)
    model.advance(resize_at)
    model.invalidate("resize-invalidation", "resize")
    model.advance(resize_at)
    return model


def continuous_model(trace):
    model = SchedulerModel()
    phase_end = 0
    for index, phase in enumerate(trace["phases"]):
        if index == 0:
            model.start(phase["fpsCeiling"])
        else:
            model.retime(phase["fpsCeiling"])
            if index == 2:
                model.invalidate("scene-property")
        phase_end += phase["durationMilliseconds"] * 1_000_000
        model.advance(phase_end)
    model.pause()
    model.advance(phase_end + trace["pauseMilliseconds"] * 1_000_000)
    model.resume()
    model.advance(
        phase_end +
        (trace["pauseMilliseconds"] + trace["resumeMilliseconds"]) * 1_000_000
    )
    return model


def validate_window(value, expected, path):
    exact(value, expected, path)
    require(value == expected, f"{path} Cocoa/Metal swapchain evidence changed")


def validate_outputs(outputs, expected, output_root):
    require(len(outputs) == len(expected), "retained oracle count changed")
    for actual, reference in zip(outputs, expected):
        exact(actual, {"identity", "evidenceRole", "path", "width", "height"}, f"output {reference['identity']}")
        require(actual["identity"] == reference["identity"], f"oracle order changed: {reference['identity']}")
        require(actual["evidenceRole"] == "mirrored-render-oracle", f"oracle role changed: {reference['identity']}")
        require((actual["width"], actual["height"]) == (reference["width"], reference["height"]), f"oracle extent changed: {reference['identity']}")
        path = pathlib.Path(actual["path"])
        require(path == output_root / f"{reference['identity']}.bgra", f"oracle path changed: {reference['identity']}")
        require(identity(path) == {"sha256": reference["sha256"], "bytes": reference["bytes"]}, f"oracle bytes changed: {reference['identity']}")
        pixel = bytes.fromhex(reference["bgra8"])
        raw = path.read_bytes()
        require(set(raw[index:index + 4] for index in range(0, len(raw), 4)) == {pixel}, f"oracle clear changed: {reference['identity']}")


def validate_scheduler(value, model, path):
    exact(value, {"inputEvents", "decisions", "finalState"}, path)
    require(value["inputEvents"] == model.inputs, f"{path} input trace or scheduler state changed")
    require(value["finalState"] == model.final_state(), f"{path} final scheduler state changed")
    actual = value["decisions"]
    require(len(actual) == len(model.decisions), f"{path} decision count changed")
    last_wall = -1
    for expected, decision in zip(model.decisions, actual):
        exact(decision, {*expected, "completion"}, f"{path} decision {expected['sequence']}")
        core = {key: decision[key] for key in expected}
        require(core == expected, f"{path} decision {expected['sequence']} was not derived from inputs")
        require(decision["reasons"] and len(decision["reasons"]) == len(set(decision["reasons"])), f"{path} decision reason coalescing changed")
        completion = decision["completion"]
        exact(completion, {"submissionOrdinal", "width", "height", "wallObservedAtNanoseconds"}, f"{path} completion {expected['sequence']}")
        require(completion["submissionOrdinal"] == expected["sequence"], f"{path} presentation is not backed by its decision")
        require(completion["wallObservedAtNanoseconds"] > last_wall, f"{path} completion order changed")
        last_wall = completion["wallObservedAtNanoseconds"]
    for before, after in zip(actual, actual[1:]):
        if before["policyRevision"] == after["policyRevision"]:
            require(after["semanticNanoseconds"] - before["semanticNanoseconds"] >= after["periodNanoseconds"], f"{path} exceeded its FPS ceiling")
    return actual


def validate_lifecycle(value, decisions, outputs, path, texture_count):
    keys = {"windowsCreated", "windowsDestroyed", "devicesCreated", "devicesDestroyed", "windowsClaimed", "windowsReleased", "evaluations", "schedulerDecisions", "commandBuffersAcquired", "commandBuffersSubmitted", "swapchainAcquisitions", "presents", "fencesCreated", "fencesWaited", "fencesReleased", "texturesCreated", "texturesReleased", "transfersCreated", "transfersReleased", "resizeRetirementsAfterCompletion"}
    exact(value, keys, path)
    count = len(decisions)
    require(value["evaluations"] == value["schedulerDecisions"] == count, f"{path} scheduler counters are not decision-derived")
    for name in ("commandBuffersAcquired", "commandBuffersSubmitted", "swapchainAcquisitions", "presents", "fencesCreated", "fencesWaited", "fencesReleased"):
        require(value[name] == count, f"{path} {name} is not decision-backed")
    require(value["windowsCreated"] == value["windowsDestroyed"] == value["devicesCreated"] == value["devicesDestroyed"] == value["windowsClaimed"] == value["windowsReleased"] == 1, f"{path} window/device teardown changed")
    require(value["texturesCreated"] == value["texturesReleased"] == texture_count, f"{path} texture retirement changed")
    require(value["transfersCreated"] == value["transfersReleased"] == len(outputs), f"{path} oracle transfer lifecycle changed")
    require(value["resizeRetirementsAfterCompletion"] == texture_count - 1, f"{path} resize retirement changed")


def validate_bindings(reference, reference_root):
    require([item["identity"] for item in reference["workloadBindings"]] == ["static-no-media", "continuous-animation"], "workload binding order changed")
    traces = {}
    for binding in reference["workloadBindings"]:
        root = pathlib.Path(reference_root) / binding["identity"]
        for key, name in (("manifest", "manifest-v1.json"), ("trace", "trace-v1.json"), ("reference", "reference-v1.json")):
            require(identity(root / name) == binding[key], f"{binding['identity']} {key} binding changed")
        traces[binding["identity"]] = load(root / "trace-v1.json")
    return traces


def validate_record(value, reference, reference_root, output_root):
    exact(value, {"schemaVersion", "mode", "sdlVersion", "schedulerIdentity", "semanticTimeDistinctFromWallTime", "performanceClaim", "drawablePixelClaim", "retainedFrameRole", "faultMode", "workloads"}, "record")
    require(value["schemaVersion"] == 2 and value["mode"] == "presentation-scheduling" and value["sdlVersion"] == "3.4.10", "record identity changed")
    require(value["schedulerIdentity"] == "standalone-virtual-state-machine-v1", "scheduler identity changed")
    require(value["semanticTimeDistinctFromWallTime"] is True and value["performanceClaim"] is False, "semantic/wall boundary changed")
    require(value["drawablePixelClaim"] is False and value["retainedFrameRole"] == reference["retainedFrameRole"], "mirrored oracle boundary changed")
    require(value["faultMode"] == "none", "runtime fault mode is active")
    traces = validate_bindings(reference, reference_root)
    static, continuous = value["workloads"]
    require([static.get("identity"), continuous.get("identity")] == ["static-no-media", "continuous-animation"], "workload order changed")

    static_keys = {"identity", "manifestVersion", "criteriaVersion", "semanticClock", "wallClockRole", "window", "scheduler", "resizeEvidence", "outputs", "lifecycle"}
    exact(static, static_keys, "static")
    require(static["manifestVersion"] == 1 and static["criteriaVersion"] == "static-baseline-v1", "static contract changed")
    validate_window(static["window"], reference["window"], "static window")
    static_decisions = validate_scheduler(static["scheduler"], static_model(traces["static-no-media"]), "static scheduler")
    require([item["semanticNanoseconds"] for item in static_decisions] == [0, 400000001, 700000002], "static wake/quiescence trace changed")
    require(static["resizeEvidence"] == {"requestedLogicalWidth": 480, "requestedLogicalHeight": 270, "actualLogicalWidth": 480, "actualLogicalHeight": 270, "actualPixelWidth": 960, "actualPixelHeight": 540}, "static resize changed")
    validate_outputs(static["outputs"], reference["outputs"][:3], output_root)
    validate_lifecycle(static["lifecycle"], static_decisions, static["outputs"], "static lifecycle", 2)
    require(static_decisions[0]["completion"]["width"] == static_decisions[1]["completion"]["width"] == 640 and static_decisions[2]["completion"]["width"] == 960, "resize decision extent changed")

    continuous_keys = {"identity", "manifestVersion", "criteriaVersion", "semanticClock", "wallClockRole", "window", "scheduler", "outputs", "lifecycle"}
    exact(continuous, continuous_keys, "continuous")
    require(continuous["manifestVersion"] == 1 and continuous["criteriaVersion"] == "continuous-cadence-v1", "continuous contract changed")
    validate_window(continuous["window"], reference["window"], "continuous window")
    continuous_decisions = validate_scheduler(continuous["scheduler"], continuous_model(traces["continuous-animation"]), "continuous scheduler")
    phase_counts = [sum(decision["policyRevision"] == revision for decision in continuous_decisions) for revision in (1, 2, 3, 4)]
    require(phase_counts == [12, 18, 27, 21], "continuous phase counts changed")
    coalesced = [decision for decision in continuous_decisions if len(decision["reasons"]) > 1]
    require([decision["reasons"] for decision in coalesced] == [["fps-ceiling", "continuous-lease"], ["fps-ceiling", "scene-property", "continuous-lease"], ["resume-invalidation", "continuous-lease"]], "coincident reason coalescing changed")
    pause_start = sum(phase["durationMilliseconds"] for phase in traces["continuous-animation"]["phases"]) * 1_000_000
    pause_end = pause_start + traces["continuous-animation"]["pauseMilliseconds"] * 1_000_000
    require(not any(pause_start < decision["semanticNanoseconds"] <= pause_end for decision in continuous_decisions), "pause emitted scheduler work")
    require(continuous_decisions[57]["semanticNanoseconds"] - pause_end <= continuous_decisions[57]["periodNanoseconds"], "resume first frame exceeded its bound")
    validate_outputs(continuous["outputs"], reference["outputs"][3:], output_root)
    validate_lifecycle(continuous["lifecycle"], continuous_decisions, continuous["outputs"], "continuous lifecycle", 1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", type=pathlib.Path, required=True)
    parser.add_argument("--reference-root", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    reference = load(pathlib.Path(__file__).with_name("presentation-reference-v2.json"))
    with tempfile.TemporaryDirectory(prefix="fresco-sdl3-presentation-v2-") as directory:
        output_root = pathlib.Path(directory)
        record = run_json(arguments.executable, output_root)
        validate_record(record, reference, arguments.reference_root, output_root)


if __name__ == "__main__":
    main()
