#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import pathlib
import platform
import shutil
import subprocess
import time

import adapter
import contract
import lifecycle_control_calibration as calibration
import lifecycle_control_calibration_attempt2 as publication


ROOT = adapter.WORKLOAD_ROOT / "resource-reload"
MANIFEST_FILE = "lifecycle-subject-manifest-v3.json"
REFERENCE_FILE = "lifecycle-subject-reference-v3.json"
TRACE_FILE = "lifecycle-subject-trace-v3.json"
FREEZE_FILE = "lifecycle-subject-freeze-v3.json"
FORBIDDEN = [
    "FrescoScene", "fresco-scene", "WallpaperEngine", "OpenGL",
    "libGLES", "libEGL", "ANGLE", "Metal.framework", "AGXMetal", "MTL",
]
HEADINGS = [
    {"identity": "AppIntents", "headingToken": "AppIntents"},
    {"identity": "LinkServices", "headingToken": "LinkServices"},
    {"identity": "NSXPCConnection", "headingToken": "NSXPCConnection"},
]


class SubjectError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise SubjectError(message)


def identity(path):
    value = pathlib.Path(path).read_bytes()
    return {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}


def load_material():
    manifest = contract.load_json(ROOT / MANIFEST_FILE)
    reference = contract.load_json(ROOT / REFERENCE_FILE)
    trace = contract.load_json(ROOT / TRACE_FILE)
    freeze = contract.load_json(ROOT / FREEZE_FILE)
    require(manifest["identity"] == "resource-lifecycle-subject-manifest-v3", "manifest identity changed")
    require(reference["identity"] == "resource-lifecycle-subject-v3", "reference identity changed")
    require(trace["identity"] == "resource-lifecycle-subject-trace-v3", "trace identity changed")
    require(freeze["manifest"] == identity(ROOT / MANIFEST_FILE), "manifest binding changed")
    require(freeze["reference"] == identity(ROOT / REFERENCE_FILE), "reference binding changed")
    require(freeze["trace"] == identity(ROOT / TRACE_FILE), "trace binding changed")
    require(freeze["runner"] == identity(pathlib.Path(__file__).resolve()), "runner binding changed")
    bindings = reference["calibration"]
    inherited = {
        "archive": pathlib.Path("/Users/astral/personal/vestiary/.fresco-evidence/lifecycle-v3-calibration-attempt2/evidence.tar.gz"),
        "predecessorAddendum": ROOT / "lifecycle-control-calibration-verification-addendum-v3.json",
        "archiveAddendumV4": ROOT / "lifecycle-control-calibration-archive-addendum-v4.json",
        "archiveVerifier": pathlib.Path(__file__).with_name("lifecycle_control_calibration_archive_verification_v4.py"),
    }
    for name, path in inherited.items():
        require(identity(path) == bindings[name], f"calibration {name} binding changed")
    require(reference["absoluteCaps"] == {
        "totalRootGroupCount": 2, "totalRootInstances": 3,
        "rawLeakObjects": 288, "rawLeakBytes": 18816,
        "perHeading": {
            "AppIntents": {"groupCount": 0, "instanceCount": 0},
            "LinkServices": {"groupCount": 0, "instanceCount": 0},
            "NSXPCConnection": {"groupCount": 2, "instanceCount": 3},
        },
        "unknownGroups": 0, "forbiddenGroups": 0, "subjectOnlyHeadings": 0,
    }, "absolute caps changed")
    require(trace["backendOrder"] == ["native-opengl", "angle-metal"], "backend order changed")
    require(trace["slotOrder"] == ["control", "subject", "subject", "control", "control", "subject", "subject", "control", "control", "subject"], "slot order changed")
    return manifest, reference, trace, freeze


def extract_events(stdout, assignment):
    result = []
    for line in stdout.splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and value.get("assignmentID") == assignment:
            result.append(value)
    return result


def derive(raw, assignment, role, reference):
    invalid = []
    match = calibration.LEAK_SUMMARY.search(raw["stdout"])
    objects, leaked_bytes = (None, None) if match is None else (int(match.group(1)), int(match.group(2)))
    if match is None:
        invalid.append("missing-raw-leak-summary")
    plan = {"allowedRootIdentities": HEADINGS, "forbiddenFrameTokens": FORBIDDEN}
    groups, group_invalid = calibration._classify_groups(raw["stdout"], plan)
    invalid.extend(group_invalid)
    events = extract_events(raw["stdout"], assignment)
    expected_events = ["hello", "ready", "stopped"] if role == "control" else ["hello", "ready", "ready", "stopped"]
    event_types = [item.get("type") for item in events]
    if event_types != expected_events:
        invalid.append("protocol-mismatch")
    endpoint = events[-1].get("renderResourceLifecycle", {}) if events else {}
    expected_endpoint = reference["endpoints"][role]
    endpoint_projection = {
        key: endpoint.get(key) for key in (
            "generationsCreated", "generationsRetired", "liveGenerations",
            "completionBarriersCompleted", "completionBarriersFailed",
            "retirementsWithoutCompletion",
        )
    }
    endpoint_projection["programPublicationDeletionBalance"] = (
        isinstance(endpoint.get("programPublications"), int)
        and endpoint.get("programPublications") == endpoint.get("programDeletions")
    )
    if endpoint_projection != expected_endpoint:
        invalid.append("renderer-lifecycle-endpoint")
    if events:
        allocations = events[-1].get("renderAllocations")
        if not isinstance(allocations, dict) or any(
            not isinstance(item, dict) or item.get("live") != 0
            for item in allocations.values()
        ):
            invalid.append("renderer-allocation-endpoint")
    per_heading = {
        item["identity"]: {
            "groupCount": sum(group["identity"] == item["identity"] for group in groups),
            "instanceCount": sum(group["instanceCount"] for group in groups if group["identity"] == item["identity"]),
        } for item in HEADINGS
    }
    derived = {
        "eventTypes": event_types,
        "totalRootGroupCount": len(groups),
        "totalRootInstances": sum(group["instanceCount"] for group in groups),
        "perHeading": per_heading,
        "rawLeakObjects": objects,
        "rawLeakBytes": leaked_bytes,
        "unknownGroups": sum(group["identity"] is None for group in groups),
        "forbiddenGroups": sum(bool(group["forbiddenFrameTokens"]) for group in groups),
        "subjectOnlyHeadings": 0,
        "groups": groups,
        "endpoint": endpoint_projection,
    }
    caps = reference["absoluteCaps"]
    for key in ("totalRootGroupCount", "totalRootInstances", "rawLeakObjects", "rawLeakBytes", "unknownGroups", "forbiddenGroups", "subjectOnlyHeadings"):
        if derived[key] is None or derived[key] > caps[key]:
            invalid.append(f"absolute-cap-{key}")
    for heading, cap in caps["perHeading"].items():
        if any(per_heading[heading][key] > cap[key] for key in ("groupCount", "instanceCount")):
            invalid.append(f"absolute-cap-heading-{heading}")
    if raw["exitStatus"] not in (0, 1):
        invalid.append("leak-tool-exit-status")
    if raw["timedOut"]:
        invalid.append("timeout")
    return derived, sorted(set(invalid))


def run_slot(configuration, projects, common, backend, role, ordinal, reference, environment):
    assignment = f"subject-v3-{backend}-{ordinal:02d}-{role}"
    commands = [{"protocolVersion": 1, "type": "hello", "assignmentID": assignment}]
    commands.extend({"protocolVersion": 1, "type": "load", "assignmentID": assignment, "path": os.fspath(project), **common} for project in projects)
    commands.append({"protocolVersion": 1, "type": "stop", "assignmentID": assignment})
    child_environment = os.environ.copy()
    child_environment.update(environment)
    started = time.monotonic_ns()
    timed_out = False
    try:
        completed = subprocess.run(
            [os.fspath(calibration.LEAK_TOOL), "--atExit", "--", os.fspath(configuration.helper_binary)],
            input="".join(json.dumps(item, separators=(",", ":")) + "\n" for item in commands),
            capture_output=True, text=True, env=child_environment,
            timeout=configuration.timeout_seconds, check=False,
        )
        exit_status, stdout, stderr = completed.returncode, completed.stdout, completed.stderr
    except subprocess.TimeoutExpired as error:
        timed_out, exit_status = True, None
        stdout, stderr = error.stdout or "", error.stderr or ""
        if isinstance(stdout, bytes): stdout = stdout.decode("utf-8", errors="replace")
        if isinstance(stderr, bytes): stderr = stderr.decode("utf-8", errors="replace")
    raw = {"commands": commands, "exitStatus": exit_status, "timedOut": timed_out, "stdout": stdout, "stderr": stderr}
    derived, invalid = derive(raw, assignment, role, reference)
    return {
        "ordinal": ordinal, "backend": backend, "role": role, "attempt": 1,
        "assignment": assignment, "elapsedNanoseconds": time.monotonic_ns() - started,
        "status": "valid" if not invalid else "invalid", "invalidReasons": invalid,
        "rawReport": raw, "derived": derived,
    }


def validate_campaign(campaign, reference, trace, *, complete=True):
    runs = campaign["runs"]
    require(campaign["slotOrder"] == trace["slotOrder"], "campaign order changed")
    require(len(runs) <= 10 and len(campaign["runReceipts"]) == len(runs), "slot receipt omitted")
    for ordinal, run in enumerate(runs, 1):
        require(run["ordinal"] == ordinal and run["role"] == trace["slotOrder"][ordinal - 1], "slot reordered or omitted")
        require(run["attempt"] == 1, "slot retry detected")
        expected_derived, invalid = derive(run["rawReport"], run["assignment"], run["role"], reference)
        require(run["derived"] == expected_derived and run["invalidReasons"] == invalid, "slot derivation changed")
        require(run["status"] == ("valid" if not invalid else "invalid"), "slot verdict inconsistent")
    invalid_runs = [run["ordinal"] for run in runs if run["status"] != "valid"]
    require(campaign["invalidRuns"] == invalid_runs, "invalid inventory inconsistent")
    if complete:
        require(len(runs) == 10, "campaign omitted a slot")
        require(not invalid_runs and campaign["campaignStatus"] == "accepted", "campaign did not accept all controls and subjects")
        require(sum(run["role"] == "control" for run in runs) == 5 and sum(run["role"] == "subject" for run in runs) == 5, "campaign role counts changed")
    else:
        require(campaign["campaignStatus"] == "rejected", "partial campaign must be rejected")
    return campaign


def publish_archive(evidence_root, backend):
    archive_base = evidence_root.parent / f"{evidence_root.name}-{backend}-evidence"
    archive = pathlib.Path(shutil.make_archive(os.fspath(archive_base), "gztar", root_dir=evidence_root))
    result = {"path": os.fspath(archive), **identity(archive)}
    publication._atomic_json(evidence_root / "archive-publication.json", result)
    return result


def run_campaign(configuration, evidence_root):
    manifest, reference, trace, freeze = load_material()
    backend = configuration.expected_backend
    require(backend in trace["backendOrder"], "unknown backend")
    evidence_root = pathlib.Path(os.path.realpath(evidence_root))
    require(not evidence_root.exists(), "campaign directory already exists; resume and rerun are forbidden")
    (evidence_root / "wal").mkdir(parents=True)
    (evidence_root / "receipts").mkdir()
    store = evidence_root / "store"
    fixture_root = adapter.WORKLOAD_ROOT / "masks-effects"
    files = tuple(adapter.ASSET_FILES[item] for item in contract.load_json(ROOT / "lifecycle-trace-v2.json")["assetIdentities"])
    control = evidence_root / "control-project"
    project_a, project_b = evidence_root / "subject-a", evidence_root / "subject-b"
    control.mkdir(); project_a.mkdir(); project_b.mkdir()
    adapter._materialize_project(adapter.WORKLOAD_ROOT / "static-no-media", control)
    adapter._materialize_project(fixture_root, project_a, package_files=files)
    adapter._materialize_resource_reload_variant(fixture_root, project_b, files)
    protocol = trace["protocol"]
    common = {
        "assetRoot": os.fspath(configuration.asset_root), "width": protocol["width"],
        "height": protocol["height"], "fps": protocol["fps"], "policyRevision": 1,
        "reasonTokens": ["harness:lifecycle-resource-reload-subject-v3"],
        "visible": protocol["visible"], "muted": protocol["muted"],
        "evidenceFrames": protocol["evidenceFrames"],
    }
    campaign = {
        "schemaVersion": 3, "identity": f"resource-lifecycle-subject-v3-{backend}",
        "backend": backend, "host": {"osVersion": platform.mac_ver()[0], "architecture": platform.machine()},
        "bindings": {"manifest": identity(ROOT / MANIFEST_FILE), "reference": identity(ROOT / REFERENCE_FILE), "trace": identity(ROOT / TRACE_FILE), "freeze": identity(ROOT / FREEZE_FILE)},
        "helper": identity(configuration.helper_binary), "sourceManifest": identity(configuration.source_manifest),
        "slotOrder": trace["slotOrder"], "runs": [], "runReceipts": [],
        "invalidRuns": [], "campaignStatus": "rejected",
    }
    for ordinal, role in enumerate(trace["slotOrder"], 1):
        projects = (control,) if role == "control" else (project_a, project_b)
        run = run_slot(configuration, projects, common, backend, role, ordinal, reference, trace["environment"])
        _, receipt = publication._persist_record(run, f"slot-{ordinal:02d}-{role}", evidence_root / "wal", evidence_root / "receipts", store)
        campaign["runs"].append(run)
        campaign["runReceipts"].append({"ordinal": ordinal, "role": role, **receipt})
        if run["status"] != "valid":
            campaign["invalidRuns"] = [ordinal]
            validate_campaign(campaign, reference, trace, complete=False)
            publication._persist_record(campaign, "partial-rejected-campaign", evidence_root / "wal", evidence_root / "receipts", store)
            return campaign, publish_archive(evidence_root, backend)
    campaign["campaignStatus"] = "accepted"
    validate_campaign(campaign, reference, trace)
    publication._persist_record(campaign, "accepted-campaign", evidence_root / "wal", evidence_root / "receipts", store)
    return campaign, publish_archive(evidence_root, backend)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", required=True, choices=("native-opengl", "angle-metal"))
    parser.add_argument("--helper", required=True, type=pathlib.Path)
    parser.add_argument("--assets", required=True, type=pathlib.Path)
    parser.add_argument("--source-manifest", required=True, type=pathlib.Path)
    parser.add_argument("--evidence-root", required=True, type=pathlib.Path)
    parser.add_argument("--timeout", type=float, default=30)
    arguments = parser.parse_args()
    candidate = "opengl-4.1-2d" if arguments.backend == "native-opengl" else "angle-metal-es3-2d"
    configuration = adapter.CandidateConfiguration(
        helper_binary=adapter.normalize_wrapper_path(arguments.helper),
        asset_root=adapter.normalize_wrapper_path(arguments.assets),
        expected_candidate=candidate, expected_backend=arguments.backend,
        store_root=arguments.evidence_root / "store",
        source_manifest=adapter.normalize_wrapper_path(arguments.source_manifest),
        source_sha256=identity(arguments.source_manifest)["sha256"],
        build_identity=f"subject-v3-{arguments.backend}", build_commands=("prebuilt frozen helper",),
        operator="subject-v3", agent_role="subagent", timeout_seconds=arguments.timeout,
    )
    campaign, archive = run_campaign(configuration, arguments.evidence_root)
    print(json.dumps({"backend": arguments.backend, "status": campaign["campaignStatus"], "records": len(campaign["runs"]), "invalidRuns": campaign["invalidRuns"], "archive": archive}, separators=(",", ":")))
    if campaign["campaignStatus"] != "accepted":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
