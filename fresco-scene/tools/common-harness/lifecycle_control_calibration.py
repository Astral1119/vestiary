#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import pathlib
import platform
import re
import subprocess
import tempfile
import time

import adapter
import contract


PLAN_FILE = "lifecycle-control-calibration-plan-v3.json"
LEAK_TOOL = pathlib.Path("/usr/bin/leaks")
LEAK_TOOL_IDENTITY = "macos-leaks"
LEAK_TOOL_VERSION = "report-7"
STACK_HEADING = re.compile(r"(?m)^STACK OF ([0-9]+) INSTANCES? OF (.+)$")
STACK_DELIMITER = re.compile(r"(?m)^====\s*$")
LEAK_SUMMARY = re.compile(
    r"Process [0-9]+: ([0-9]+) leaks for ([0-9]+) total leaked bytes\."
)


class CalibrationError(Exception):
    pass


def _require(condition, message):
    if not condition:
        raise CalibrationError(message)


def _exact(value, keys, path):
    _require(isinstance(value, dict), f"{path} must be an object")
    _require(set(value) == set(keys), f"{path} schema changed")
    return value


def _sha256_file(path):
    value = pathlib.Path(path).read_bytes()
    return hashlib.sha256(value).hexdigest(), len(value)


def _load_plan():
    path = adapter.WORKLOAD_ROOT / "resource-reload" / PLAN_FILE
    plan = contract.load_json(path)
    validate_plan(plan)
    digest, size = _sha256_file(path)
    return path, plan, {"sha256": digest, "bytes": size}


def validate_plan(plan):
    _exact(
        plan,
        {
            "schemaVersion", "identity", "purpose", "attemptsPerBackend",
            "frozenOrder", "protocol", "environment",
            "allowedRootIdentities", "forbiddenFrameTokens",
            "groupBoundary", "classificationRule", "derivation",
        },
        "calibration plan",
    )
    _require(
        plan["schemaVersion"] == 3
        and plan["identity"] == "resource-lifecycle-control-calibration-v3"
        and plan["purpose"] == "control-only-calibration"
        and plan["attemptsPerBackend"] == 20,
        "calibration plan identity changed",
    )
    expected_order = [item for _ in range(20) for item in ("native-opengl", "angle-metal")]
    _require(plan["frozenOrder"] == expected_order, "calibration order changed")
    _require(
        plan["protocol"] == {
            "version": 1,
            "eventTypes": ["hello", "ready", "stopped"],
            "loads": 1,
            "project": "static-no-media-minimal-appkit-window",
        },
        "calibration protocol changed",
    )
    _require(
        plan["environment"] == {
            "FRESCO_SCENE_AUDIO_DISABLED": "1",
            "FRESCO_SCENE_SOUND_EXPERIMENTAL": "0",
        },
        "calibration environment changed",
    )
    _require(
        plan["allowedRootIdentities"] == [
            {"identity": "AppIntents", "headingToken": "AppIntents"},
            {"identity": "LinkServices", "headingToken": "LinkServices"},
            {"identity": "NSXPCConnection", "headingToken": "NSXPCConnection"},
        ],
        "calibration root identities changed",
    )
    _require(
        plan["groupBoundary"] == "STACK OF heading through the next ==== delimiter"
        and plan["classificationRule"]
            == "exactly one allowed heading token per STACK OF group",
        "calibration classification changed",
    )


def _extract_events(stdout, assignment):
    events = []
    for line in stdout.splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and value.get("assignmentID") == assignment:
            events.append(value)
    return events


def _classify_groups(stdout, plan):
    matches = list(STACK_HEADING.finditer(stdout))
    groups = []
    invalid = []
    for index, match in enumerate(matches):
        next_heading = matches[index + 1].start() if index + 1 < len(matches) else len(stdout)
        delimiter = STACK_DELIMITER.search(stdout, match.end(), next_heading)
        if delimiter is None:
            invalid.append(f"group-{index + 1}-missing-delimiter")
            continue
        stack = stdout[match.start():delimiter.end()].rstrip() + "\n"
        heading = match.group(2)
        identities = [
            item["identity"] for item in plan["allowedRootIdentities"]
            if item["headingToken"] in heading
        ]
        forbidden = sorted(
            token for token in plan["forbiddenFrameTokens"] if token in stack
        )
        if len(identities) != 1:
            invalid.append(f"group-{index + 1}-classification-count-{len(identities)}")
        if forbidden:
            invalid.append(f"group-{index + 1}-forbidden-frame")
        groups.append({
            "identity": identities[0] if len(identities) == 1 else None,
            "instanceCount": int(match.group(1)),
            "stackSha256": hashlib.sha256(stack.encode("utf-8")).hexdigest(),
            "forbiddenFrameTokens": forbidden,
        })
    return groups, invalid


def _derive_attempt(raw, assignment, plan):
    invalid = []
    summary = LEAK_SUMMARY.search(raw["stdout"])
    if summary is None:
        invalid.append("missing-raw-leak-summary")
        leak_objects = None
        leak_bytes = None
    else:
        leak_objects = int(summary.group(1))
        leak_bytes = int(summary.group(2))
    groups, group_invalid = _classify_groups(raw["stdout"], plan)
    invalid.extend(group_invalid)
    if leak_objects and not groups:
        invalid.append("leaks-without-root-groups")
    events = _extract_events(raw["stdout"], assignment)
    event_types = [event.get("type") for event in events]
    if event_types != plan["protocol"]["eventTypes"]:
        invalid.append("control-protocol-mismatch")
    if raw["exitStatus"] not in (0, 1):
        invalid.append("leak-tool-exit-status")
    if raw["timedOut"]:
        invalid.append("control-timeout")
    if events:
        lifecycle = events[-1].get("renderResourceLifecycle", {})
        if not (
            lifecycle.get("liveGenerations") == 0
            and lifecycle.get("completionBarriersFailed") == 0
            and lifecycle.get("retirementsWithoutCompletion") == 0
            and lifecycle.get("programPublications")
                == lifecycle.get("programDeletions")
        ):
            invalid.append("renderer-lifecycle-endpoint")
    per_signature = {
        item["identity"]: {
            "groupCount": sum(group["identity"] == item["identity"] for group in groups),
            "instanceCount": sum(
                group["instanceCount"] for group in groups
                if group["identity"] == item["identity"]
            ),
        }
        for item in plan["allowedRootIdentities"]
    }
    derived = {
        "eventTypes": event_types,
        "totalRootGroupCount": len(groups),
        "totalRootInstances": sum(group["instanceCount"] for group in groups),
        "perSignature": per_signature,
        "rawLeakObjects": leak_objects,
        "rawLeakBytes": leak_bytes,
        "groups": groups,
    }
    return derived, sorted(set(invalid))


def _run_attempt(configuration, project, common, ordinal, attempt_within_backend, plan):
    backend = configuration.expected_backend
    assignment = f"calibration-v3-{ordinal:03d}-{backend}"
    commands = [
        {"protocolVersion": 1, "type": "hello", "assignmentID": assignment},
        {
            "protocolVersion": 1, "type": "load", "assignmentID": assignment,
            "path": os.fspath(project), **common,
        },
        {"protocolVersion": 1, "type": "stop", "assignmentID": assignment},
    ]
    environment = os.environ.copy()
    environment.update(plan["environment"])
    started = time.monotonic_ns()
    timed_out = False
    try:
        completed = subprocess.run(
            [os.fspath(LEAK_TOOL), "--atExit", "--", os.fspath(configuration.helper_binary)],
            input="".join(json.dumps(command, separators=(",", ":")) + "\n" for command in commands),
            capture_output=True,
            text=True,
            env=environment,
            timeout=configuration.timeout_seconds,
            check=False,
        )
        exit_status = completed.returncode
        stdout, stderr = completed.stdout, completed.stderr
    except subprocess.TimeoutExpired as error:
        timed_out = True
        exit_status = None
        stdout = error.stdout or ""
        stderr = error.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", errors="replace")
    raw = {
        "commands": commands,
        "exitStatus": exit_status,
        "timedOut": timed_out,
        "stdout": stdout,
        "stderr": stderr,
    }
    derived, invalid = _derive_attempt(raw, assignment, plan)
    return {
        "ordinal": ordinal,
        "backend": backend,
        "attemptWithinBackend": attempt_within_backend,
        "attempt": 1,
        "assignment": assignment,
        "elapsedNanoseconds": time.monotonic_ns() - started,
        "status": "valid" if not invalid else "invalid",
        "invalidReasons": invalid,
        "rawReport": raw,
        "derived": derived,
    }


def _derived_table(runs, plan):
    _require(all(run["status"] == "valid" for run in runs), "invalid control prevents cap derivation")
    identities = [item["identity"] for item in plan["allowedRootIdentities"]]
    return {
        "populationCount": len(runs),
        "maximumTotalRootGroupCount": max(run["derived"]["totalRootGroupCount"] for run in runs),
        "maximumTotalRootInstances": max(run["derived"]["totalRootInstances"] for run in runs),
        "perSignatureMaxima": {
            identity: {
                "groupCount": max(run["derived"]["perSignature"][identity]["groupCount"] for run in runs),
                "instanceCount": max(run["derived"]["perSignature"][identity]["instanceCount"] for run in runs),
            }
            for identity in identities
        },
        "maximumRawLeakObjects": max(run["derived"]["rawLeakObjects"] for run in runs),
        "maximumRawLeakBytes": max(run["derived"]["rawLeakBytes"] for run in runs),
    }


def validate_campaign(campaign, plan, plan_identity, *, require_valid=True):
    validate_plan(plan)
    _exact(
        campaign,
        {
            "schemaVersion", "identity", "purpose", "plan", "host", "tool",
            "helpers", "frozenOrder", "runs", "campaignStatus", "invalidRuns",
            "derivedTable",
        },
        "calibration campaign",
    )
    _require(
        campaign["schemaVersion"] == 3
        and campaign["identity"] == "resource-lifecycle-control-calibration-v3"
        and campaign["purpose"] == "control-only-calibration",
        "campaign identity changed",
    )
    _require(campaign["plan"] == plan_identity, "campaign plan binding changed")
    _require(campaign["frozenOrder"] == plan["frozenOrder"], "campaign order changed")
    _exact(campaign["host"], {"osVersion", "osBuild", "architecture"}, "campaign host")
    _require(all(isinstance(value, str) and value for value in campaign["host"].values()), "campaign host identity is incomplete")
    _exact(campaign["tool"], {"identity", "version", "sha256", "bytes"}, "campaign tool")
    _require(
        campaign["tool"]["identity"] == LEAK_TOOL_IDENTITY
        and campaign["tool"]["version"] == LEAK_TOOL_VERSION
        and re.fullmatch(r"[0-9a-f]{64}", campaign["tool"]["sha256"])
        and isinstance(campaign["tool"]["bytes"], int)
        and campaign["tool"]["bytes"] > 0,
        "campaign leak tool identity changed",
    )
    _require(set(campaign["helpers"]) == {"native-opengl", "angle-metal"}, "campaign helper set changed")
    for backend, helper in campaign["helpers"].items():
        _exact(
            helper,
            {
                "candidate", "buildIdentity", "helperSha256", "helperBytes",
                "sourceManifestSha256", "sourceManifestBytes",
            },
            f"campaign helper {backend}",
        )
        _require(
            all(re.fullmatch(r"[0-9a-f]{64}", helper[name]) for name in ("helperSha256", "sourceManifestSha256"))
            and helper["helperBytes"] > 0 and helper["sourceManifestBytes"] > 0,
            f"campaign helper {backend} identity is incomplete",
        )
    runs = campaign["runs"]
    _require(isinstance(runs, list) and len(runs) == 40, "campaign omitted a scheduled control")
    backend_counts = {"native-opengl": 0, "angle-metal": 0}
    for ordinal, (run, backend) in enumerate(zip(runs, plan["frozenOrder"]), 1):
        backend_counts[backend] += 1
        _exact(
            run,
            {
                "ordinal", "backend", "attemptWithinBackend", "attempt",
                "assignment", "elapsedNanoseconds", "status", "invalidReasons",
                "rawReport", "derived",
            },
            f"calibration run {ordinal}",
        )
        _require(
            run["ordinal"] == ordinal and run["backend"] == backend
            and run["attemptWithinBackend"] == backend_counts[backend]
            and run["attempt"] == 1,
            f"calibration run {ordinal} was reordered or retried",
        )
        _require(
            run["assignment"] == f"calibration-v3-{ordinal:03d}-{backend}"
            and isinstance(run["elapsedNanoseconds"], int)
            and run["elapsedNanoseconds"] >= 0,
            f"calibration run {ordinal} identity changed",
        )
        _require(isinstance(run["rawReport"], dict), f"calibration run {ordinal} omitted raw evidence")
        _exact(
            run["rawReport"],
            {"commands", "exitStatus", "timedOut", "stdout", "stderr"},
            f"calibration run {ordinal} raw report",
        )
        commands = run["rawReport"]["commands"]
        _require(
            isinstance(commands, list) and len(commands) == 3
            and [command.get("type") for command in commands]
                == ["hello", "load", "stop"]
            and all(command.get("protocolVersion") == 1 for command in commands)
            and all(command.get("assignmentID") == run["assignment"] for command in commands),
            f"calibration run {ordinal} command protocol changed",
        )
        derived, invalid = _derive_attempt(run["rawReport"], run["assignment"], plan)
        _require(run["derived"] == derived, f"calibration run {ordinal} derived evidence changed")
        _require(run["invalidReasons"] == invalid, f"calibration run {ordinal} invalid reasons changed")
        _require(run["status"] == ("valid" if not invalid else "invalid"), f"calibration run {ordinal} status changed")
    invalid_runs = [run["ordinal"] for run in runs if run["status"] != "valid"]
    _require(campaign["invalidRuns"] == invalid_runs, "campaign invalid-run inventory changed")
    if invalid_runs:
        _require(campaign["campaignStatus"] == "invalid" and campaign["derivedTable"] is None, "invalid campaign derived caps")
        if require_valid:
            raise CalibrationError("campaign contains invalid control runs")
    else:
        _require(campaign["campaignStatus"] == "valid", "valid campaign status changed")
        _require(campaign["derivedTable"] == _derived_table(runs, plan), "campaign maxima were forged")
    return campaign


def run_campaign(configurations, store_root):
    plan_path, plan, plan_identity = _load_plan()
    by_backend = {configuration.expected_backend: configuration for configuration in configurations}
    _require(set(by_backend) == {"native-opengl", "angle-metal"}, "campaign helpers changed")
    leak_hash, leak_bytes = _sha256_file(LEAK_TOOL)
    host = {
        "osVersion": platform.mac_ver()[0],
        "osBuild": subprocess.run(["/usr/bin/sw_vers", "-buildVersion"], capture_output=True, text=True, check=True).stdout.strip(),
        "architecture": platform.machine(),
    }
    helpers = {}
    for backend, configuration in by_backend.items():
        helper_hash, helper_bytes = _sha256_file(configuration.helper_binary)
        source_hash, source_bytes = _sha256_file(configuration.source_manifest)
        helpers[backend] = {
            "candidate": configuration.expected_candidate,
            "buildIdentity": configuration.build_identity,
            "helperSha256": helper_hash,
            "helperBytes": helper_bytes,
            "sourceManifestSha256": source_hash,
            "sourceManifestBytes": source_bytes,
        }
    with tempfile.TemporaryDirectory(prefix="fresco-lifecycle-control-v3.") as value:
        scratch = pathlib.Path(value)
        project = scratch / "appkit-window-control"
        project.mkdir()
        adapter._materialize_project(adapter.WORKLOAD_ROOT / "static-no-media", project)
        trace = contract.load_json(
            adapter.WORKLOAD_ROOT / "resource-reload" / "lifecycle-trace-v2.json"
        )
        common = {
            "assetRoot": os.fspath(configurations[0].asset_root),
            "width": trace["logicalWidth"], "height": trace["logicalHeight"],
            "fps": trace["fpsCeiling"], "policyRevision": trace["policyRevision"],
            "reasonTokens": trace["reasonTokens"], "visible": True,
            "muted": True, "evidenceFrames": 1,
        }
        runs = []
        counts = {"native-opengl": 0, "angle-metal": 0}
        for ordinal, backend in enumerate(plan["frozenOrder"], 1):
            counts[backend] += 1
            runs.append(_run_attempt(by_backend[backend], project, common, ordinal, counts[backend], plan))
        invalid_runs = [run["ordinal"] for run in runs if run["status"] != "valid"]
        campaign = {
            "schemaVersion": 3,
            "identity": "resource-lifecycle-control-calibration-v3",
            "purpose": "control-only-calibration",
            "plan": plan_identity,
            "host": host,
            "tool": {
                "identity": LEAK_TOOL_IDENTITY, "version": LEAK_TOOL_VERSION,
                "sha256": leak_hash, "bytes": leak_bytes,
            },
            "helpers": helpers,
            "frozenOrder": plan["frozenOrder"],
            "runs": runs,
            "campaignStatus": "invalid" if invalid_runs else "valid",
            "invalidRuns": invalid_runs,
            "derivedTable": None if invalid_runs else _derived_table(runs, plan),
        }
        validate_campaign(campaign, plan, plan_identity, require_valid=False)
        campaign_path = scratch / "lifecycle-control-calibration-v3.json"
        adapter._write_json(campaign_path, campaign)
        artifact = contract.ingest_artifact(
            campaign_path, store_root, "lifecycle-control-calibration-v3",
            "application/json",
        )
        return campaign, artifact, plan_path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--native-helper", required=True, type=pathlib.Path)
    parser.add_argument("--angle-helper", required=True, type=pathlib.Path)
    parser.add_argument("--assets", required=True, type=pathlib.Path)
    parser.add_argument("--native-source-manifest", required=True, type=pathlib.Path)
    parser.add_argument("--angle-source-manifest", required=True, type=pathlib.Path)
    parser.add_argument("--store", required=True, type=pathlib.Path)
    parser.add_argument("--timeout", type=float, default=30)
    arguments = parser.parse_args()
    configurations = []
    for backend, candidate, helper, source_manifest in (
        ("native-opengl", "opengl-4.1-2d", arguments.native_helper, arguments.native_source_manifest),
        ("angle-metal", "angle-metal-es3-2d", arguments.angle_helper, arguments.angle_source_manifest),
    ):
        source_sha256, _ = _sha256_file(source_manifest)
        configurations.append(adapter.CandidateConfiguration(
            helper_binary=adapter.normalize_wrapper_path(helper),
            asset_root=adapter.normalize_wrapper_path(arguments.assets),
            expected_candidate=candidate,
            expected_backend=backend,
            store_root=adapter.normalize_wrapper_path(arguments.store),
            source_manifest=adapter.normalize_wrapper_path(source_manifest),
            source_sha256=source_sha256,
            build_identity=f"lifecycle-control-calibration-{backend}",
            build_commands=(f"prebuilt control helper: {backend}",),
            operator="calibration-v3",
            agent_role="subagent",
            timeout_seconds=arguments.timeout,
        ))
    campaign, artifact, plan_path = run_campaign(configurations, arguments.store)
    print(json.dumps({
        "campaignStatus": campaign["campaignStatus"],
        "invalidRuns": campaign["invalidRuns"],
        "derivedTable": campaign["derivedTable"],
        "artifact": artifact,
        "plan": os.fspath(plan_path),
    }, separators=(",", ":")))


if __name__ == "__main__":
    main()
