#!/usr/bin/env python3

import argparse
import copy
import json
import pathlib
import subprocess
import tempfile

import sdl3_presentation_test_v2 as v2


PresentationError = v2.PresentationError
require = v2.require
exact = v2.exact
identity = v2.identity
load = v2.load
validate_window = v2.validate_window
validate_scheduler = v2.validate_scheduler
validate_lifecycle = v2.validate_lifecycle
static_model = v2.static_model
continuous_model = v2.continuous_model

PROBES = (
    "zero",
    "forged-999",
    "stale-prior",
    "duplicate-current",
    "already-completed",
)
GPU_COUNTER_KEYS = {
    "commandBuffersAcquired", "commandBuffersSubmitted",
    "swapchainAcquisitions", "presents", "fencesCreated",
    "fencesWaited", "fencesReleased", "texturesCreated",
    "texturesReleased", "transfersCreated", "transfersReleased",
    "resizeRetirementsAfterCompletion",
}


def run_json(executable, output_root, fault=None):
    return v2.run_json(executable, output_root, fault)


def run_authorization_probe(executable, output_root, probe):
    result = subprocess.run(
        [executable, "--output", output_root,
         "--authorization-probe", probe],
        check=True, text=True, capture_output=True,
    )
    records = [json.loads(line) for line in result.stdout.splitlines()
               if line.startswith("{")]
    require(len(records) == 1, f"authorization probe {probe} emitted invalid JSON")
    return records[0]


def validate_authorization_probe(value, expected_probe):
    exact(value, {"schemaVersion", "mode", "probe", "requestedSequence",
                  "rejected", "error", "before", "after",
                  "gpuCountersUnchanged"}, f"authorization probe {expected_probe}")
    require(value["schemaVersion"] == 1 and
            value["mode"] == "authorization-probe" and
            value["probe"] == expected_probe,
            f"authorization probe identity changed: {expected_probe}")
    exact(value["before"], GPU_COUNTER_KEYS, f"{expected_probe} before")
    exact(value["after"], GPU_COUNTER_KEYS, f"{expected_probe} after")
    require(value["rejected"] is True and value["error"] and
            value["gpuCountersUnchanged"] is True and
            value["before"] == value["after"],
            f"authorization rejection touched GPU state: {expected_probe}")
    expected_sequences = {
        "zero": 0, "forged-999": 999, "stale-prior": 1,
        "duplicate-current": 1, "already-completed": 1,
    }
    require(value["requestedSequence"] == expected_sequences[expected_probe],
            f"authorization request changed: {expected_probe}")


def validate_record(value, reference, reference_root, output_root):
    require(value.get("schemaVersion") == 2 and
            value.get("schedulerIdentity") ==
            "standalone-virtual-state-machine-v2" and
            value.get("authorizationIdentity") ==
            "scheduler-owned-one-shot-v1",
            "one-shot scheduler identity changed")
    translated = copy.deepcopy(value)
    translated.pop("authorizationIdentity", None)
    translated["schedulerIdentity"] = "standalone-virtual-state-machine-v1"
    v2.validate_record(translated, reference, reference_root, output_root)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", type=pathlib.Path, required=True)
    parser.add_argument("--reference-root", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    reference = load(pathlib.Path(__file__).with_name(
        "presentation-reference-v2.json"))
    with tempfile.TemporaryDirectory(
            prefix="fresco-sdl3-presentation-v3-") as directory:
        root = pathlib.Path(directory)
        normative = root / "normative"
        normative.mkdir()
        validate_record(
            run_json(arguments.executable, normative), reference,
            arguments.reference_root, normative)
        for probe in PROBES:
            output = root / probe
            output.mkdir()
            validate_authorization_probe(
                run_authorization_probe(arguments.executable, output, probe),
                probe)


if __name__ == "__main__":
    main()
