#!/usr/bin/env python3

import argparse
import copy
import json
import pathlib

import sdl3_presentation_evidence_archive_v2 as base
import sdl3_presentation_test_v3 as gate


FOUNDATION = base.FOUNDATION
PRESENTATION_V1 = {
    **base.PRESENTATION_V1, "relationship": "predecessor"}
PRESENTATION_V2 = {
    "relationship": "supersedes",
    "path": "/Users/astral/personal/vestiary/.fresco-evidence/sdl3-presentation-scheduling-v2/evidence.tar.gz",
    "sha256": "32ab97dc379f9fc4182774839f6dfcaa09b70f8a04f25244895edeba0bdca8c6",
    "bytes": 1150069,
}

ArchiveError = base.ArchiveError
require = base.require
exact = base.exact
identity_bytes = base.identity_bytes
read_archive = base.read_archive
load = base.load


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def validate_lineage(value):
    expected = {
        "foundation": FOUNDATION,
        "presentationV1": PRESENTATION_V1,
        "presentationV2": PRESENTATION_V2,
    }
    require(value == expected, "v3 lineage identity changed")
    for item in value.values():
        path = pathlib.Path(item["path"])
        require(path.is_file() and
                identity_bytes(path.read_bytes()) ==
                {"sha256": item["sha256"], "bytes": item["bytes"]},
                f"actual lineage archive changed: {path}")


def normalize_for_v2(files, record, source):
    normalized_files = copy.deepcopy(files)
    normalized = copy.deepcopy(record)
    for probe in normalized.pop("authorizationEvidence"):
        normalized_files.pop(probe["raw"]["stdout"]["path"])
        normalized_files.pop(probe["raw"]["stderr"]["path"])
    normalized["schemaVersion"] = 2
    normalized["identity"] = "sdl3-presentation-scheduling-formal-v2"
    normalized["lineage"] = {
        "foundation": FOUNDATION,
        "presentationPredecessor": base.PRESENTATION_V1,
    }
    normalized["build"]["identity"] = (
        "sdl3-presentation-scheduling-appleclang-v2")
    normalized["schedulerEvidence"].pop("authorization")
    normalized["schedulerEvidence"]["identity"] = (
        "standalone-virtual-state-machine-v1")
    normalized["verdict"].pop("oneShotAuthorization")
    runtime = normalized["runtime"]["record"]
    runtime.pop("authorizationIdentity")
    runtime["schedulerIdentity"] = "standalone-virtual-state-machine-v1"
    raw_path = normalized["runtime"]["raw"]["stdout"]["path"]
    raw_bytes = (json.dumps(runtime, separators=(",", ":")) + "\n").encode()
    normalized_files[raw_path] = raw_bytes
    normalized["runtime"]["raw"]["stdout"].update(identity_bytes(raw_bytes))

    normalized_source = copy.deepcopy(source)
    normalized_source["identity"] = "sdl3-presentation-scheduling-source-v2"
    normalized_source["files"] = normalized_source["files"][:23]
    source_bytes = canonical(normalized_source)
    normalized_files["source-manifest.json"] = source_bytes
    normalized["run"]["sourceManifest"] = identity_bytes(source_bytes)
    normalized_files["record.json"] = canonical(normalized)
    return normalized_files


def verify_files(files):
    record = load(files, "record.json")
    exact(record, {"schemaVersion", "identity", "run", "lineage", "host",
                   "display", "build", "dependency", "contracts",
                   "reference", "schedulerEvidence", "presentationEvidence",
                   "oracleBoundary", "authorizationEvidence", "runtime",
                   "lifecycle", "verdict"}, "record")
    require(record["schemaVersion"] == 3 and
            record["identity"] == "sdl3-presentation-scheduling-formal-v3",
            "v3 record identity changed")
    validate_lineage(record["lineage"])
    require(identity_bytes(files["source-manifest.json"]) ==
            record["run"]["sourceManifest"], "v3 source manifest changed")
    source = load(files, "source-manifest.json")
    require(source["identity"] == "sdl3-presentation-scheduling-source-v3" and
            len(source["files"]) == 26 and
            len({item["path"] for item in source["files"]}) == 26,
            "v3 source inventory changed")
    require(record["build"]["identity"] ==
            "sdl3-presentation-scheduling-appleclang-v3",
            "v3 build identity changed")
    require(record["schedulerEvidence"].get("authorization") ==
            "scheduler-owned-one-shot-v1",
            "authorization evidence identity changed")
    runtime = record["runtime"]["record"]
    require(runtime.get("schedulerIdentity") ==
            "standalone-virtual-state-machine-v2" and
            runtime.get("authorizationIdentity") ==
            "scheduler-owned-one-shot-v1",
            "runtime authorization identity changed")
    raw = record["runtime"]["raw"]
    base.command(files, raw, "runtime")
    raw_values = [json.loads(line) for line in
                  files[raw["stdout"]["path"]].decode().splitlines()
                  if line.startswith("{")]
    require(raw_values == [runtime], "raw v3 runtime changed")

    probes = record["authorizationEvidence"]
    require([item.get("probe") for item in probes] == list(gate.PROBES),
            "authorization probe inventory changed")
    for item in probes:
        exact(item, {"probe", "raw", "record"},
              f"authorization evidence {item.get('probe')}")
        base.command(files, item["raw"], f"authorization {item['probe']}")
        values = [json.loads(line) for line in
                  files[item["raw"]["stdout"]["path"]].decode().splitlines()
                  if line.startswith("{")]
        require(values == [item["record"]],
                f"raw authorization probe changed: {item['probe']}")
        try:
            gate.validate_authorization_probe(item["record"], item["probe"])
        except gate.PresentationError as error:
            raise ArchiveError(str(error)) from error
    require(record["verdict"].get("oneShotAuthorization") is True,
            "one-shot authorization verdict changed")

    base_result = base.verify_files(normalize_for_v2(files, record, source))
    return {
        "accepted": base_result["accepted"],
        "record": identity_bytes(files["record.json"]),
        "sourceManifest": record["run"]["sourceManifest"],
        "binary": record["run"]["binary"],
        "lineage": record["lineage"],
        "authorizationProbes": len(probes),
        "oracles": base_result["oracles"],
        "staticDecisions": base_result["staticDecisions"],
        "continuousDecisions": base_result["continuousDecisions"],
    }


def verify_archive(path):
    files, archive_identity = read_archive(path)
    result = verify_files(files)
    result["archive"] = archive_identity
    return result


def validate_addendum(addendum, archive_path):
    exact(addendum, {"schemaVersion", "identity", "purpose", "archive",
                     "record", "sourceManifest", "lineage", "verdict"},
          "addendum")
    require(addendum["schemaVersion"] == 3 and
            addendum["identity"] ==
            "sdl3-presentation-scheduling-evidence-addendum-v3" and
            addendum["purpose"] ==
            "archive-native-correctness-verification",
            "v3 addendum identity changed")
    result = verify_archive(archive_path)
    require(addendum["archive"] == {
                "path": str(pathlib.Path(archive_path)), **result["archive"]} and
            addendum["record"] == result["record"] and
            addendum["sourceManifest"] == result["sourceManifest"] and
            addendum["lineage"] == result["lineage"],
            "v3 addendum binding changed")
    require(addendum["verdict"] == {
        "accepted": True, "archiveOnly": True, "stagingRequired": False,
        "authorizationProbes": 5, "oracles": 7, "staticDecisions": 3,
        "continuousDecisions": 78, "performance": "not-measured"},
        "v3 addendum verdict changed")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=pathlib.Path)
    arguments = parser.parse_args()
    print(json.dumps(verify_archive(arguments.archive), sort_keys=True))


if __name__ == "__main__":
    main()
