#!/usr/bin/env python3

import ctypes
import hashlib
import json
import os
import pathlib
import re
import subprocess
import tempfile

import adapter
import contract


LIFECYCLE_MANIFEST = "lifecycle-manifest-v2.json"
LIFECYCLE_TRACE = "lifecycle-trace-v2.json"
LIFECYCLE_REFERENCE = "lifecycle-reference-v2.json"
AUDITOR_IDENTITY = "fresco-process-resource-auditor"
AUDITOR_VERSION = "1"
LEAK_TOOL = pathlib.Path("/usr/bin/leaks")
LEAK_TOOL_IDENTITY = "macos-leaks"
LEAK_TOOL_VERSION = "report-7"
PROC_PIDLISTFDS = 1
PROC_PIDTASKINFO = 4

LEAK_STACK_HEADING = re.compile(
    r"(?m)^STACK OF ([0-9]+) INSTANCES? OF .+$"
)


class ProcTaskInfo(ctypes.Structure):
    _fields_ = [
        ("virtualSize", ctypes.c_uint64),
        ("residentSize", ctypes.c_uint64),
        ("totalUser", ctypes.c_uint64),
        ("totalSystem", ctypes.c_uint64),
        ("threadsUser", ctypes.c_uint64),
        ("threadsSystem", ctypes.c_uint64),
        ("policy", ctypes.c_int32),
        ("faults", ctypes.c_int32),
        ("pageins", ctypes.c_int32),
        ("copyOnWriteFaults", ctypes.c_int32),
        ("messagesSent", ctypes.c_int32),
        ("messagesReceived", ctypes.c_int32),
        ("machSyscalls", ctypes.c_int32),
        ("unixSyscalls", ctypes.c_int32),
        ("contextSwitches", ctypes.c_int32),
        ("threadCount", ctypes.c_int32),
        ("runningThreadCount", ctypes.c_int32),
        ("priority", ctypes.c_int32),
    ]


def _proc_library():
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    library.proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    library.proc_pidinfo.restype = ctypes.c_int
    return library


def _task_resources(library, pid):
    info = ProcTaskInfo()
    size = ctypes.sizeof(info)
    if library.proc_pidinfo(
        pid, PROC_PIDTASKINFO, 0, ctypes.byref(info), size
    ) != size:
        raise adapter.AdapterError(f"cannot inspect lifecycle process {pid}")
    capacity = library.proc_pidinfo(pid, PROC_PIDLISTFDS, 0, None, 0)
    if capacity <= 0:
        raise adapter.AdapterError(f"cannot list lifecycle descriptors for {pid}")
    buffer = ctypes.create_string_buffer(capacity)
    used = library.proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer, capacity)
    if used < 0 or used % 8 != 0:
        raise adapter.AdapterError(f"invalid lifecycle descriptor list for {pid}")
    return {
        "pid": pid,
        "rssBytes": int(info.residentSize),
        "threads": int(info.threadCount),
        "fileDescriptors": used // 8,
    }


def _process_table():
    completed = subprocess.run(
        ["/bin/ps", "-axo", "pid=,ppid=,comm="],
        capture_output=True,
        text=True,
        check=True,
    )
    result = {}
    for line in completed.stdout.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) != 3:
            continue
        pid, parent, command = fields
        result[int(pid)] = {"parent": int(parent), "command": command}
    return result


def _descendants(root_pid, table):
    result = []
    frontier = [root_pid]
    while frontier:
        parent = frontier.pop()
        children = sorted(
            pid for pid, item in table.items() if item["parent"] == parent
        )
        result.extend(children)
        frontier.extend(children)
    return result


def _snapshot(library, root_pid, label):
    table = _process_table()
    if root_pid not in table:
        raise adapter.AdapterError("lifecycle candidate disappeared during sampling")
    children = _descendants(root_pid, table)
    processes = [_task_resources(library, pid) for pid in [root_pid, *children]]
    return {
        "label": label,
        "rootPid": root_pid,
        "children": [
            {"pid": pid, "parentPid": table[pid]["parent"],
             "command": table[pid]["command"]}
            for pid in children
        ],
        "processes": processes,
        "totals": {
            "processes": len(processes),
            "childProcesses": len(children),
            "rssBytes": sum(item["rssBytes"] for item in processes),
            "threads": sum(item["threads"] for item in processes),
            "fileDescriptors": sum(item["fileDescriptors"] for item in processes),
        },
    }


def _live_renderer_allocations(event):
    allocations = event.get("renderAllocations")
    adapter._require(
        isinstance(allocations, dict),
        "renderer metrics omitted allocation-class evidence",
    )
    total = 0
    for identity, counters in allocations.items():
        adapter._require(
            isinstance(counters, dict)
            and isinstance(counters.get("live"), int)
            and counters["live"] >= 0,
            f"renderer allocation evidence is malformed for {identity}",
        )
        total += counters["live"]
    return total


def _leak_at_exit_report(configuration, assignment, common, projects):
    commands = [
        {"protocolVersion": 1, "type": "hello", "assignmentID": assignment}
    ]
    commands.extend(
        {
            "protocolVersion": 1,
            "type": "load",
            "assignmentID": assignment,
            "path": os.fspath(project),
            **common,
        }
        for project in projects
    )
    commands.append(
        {"protocolVersion": 1, "type": "stop", "assignmentID": assignment}
    )
    environment = os.environ.copy()
    environment.update({
        "FRESCO_SCENE_AUDIO_DISABLED": "1",
        "FRESCO_SCENE_SOUND_EXPERIMENTAL": "0",
    })
    completed = subprocess.run(
        [
            os.fspath(LEAK_TOOL),
            "--atExit",
            "--",
            os.fspath(configuration.helper_binary),
        ],
        input="".join(
            json.dumps(command, separators=(",", ":")) + "\n"
            for command in commands
        ),
        capture_output=True,
        text=True,
        env=environment,
        timeout=configuration.timeout_seconds,
        check=False,
    )
    leak_summary = re.search(
        r"Process [0-9]+: ([0-9]+) leaks for ([0-9]+) total leaked bytes\.",
        completed.stdout,
    )
    if leak_summary is None:
        raise adapter.AdapterError(
            "macOS leaks --atExit emitted no parseable leak summary"
        )
    leak_count = int(leak_summary.group(1))
    leaked_bytes = int(leak_summary.group(2))
    clean = leak_count == 0
    lines = completed.stdout.splitlines()
    events = []
    for line in lines:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict) and event.get("assignmentID") == assignment:
            events.append(event)
    if len(events) != len(commands):
        raise adapter.AdapterError(
            "macOS leaks --atExit obscured helper protocol evidence"
        )
    expected = ["hello", *("ready" for _ in projects), "stopped"]
    adapter._require(
        [event.get("type") for event in events] == expected
        and all(event.get("assignmentID") == assignment for event in events),
        "macOS leaks --atExit helper protocol sequence changed",
    )
    for event in events[:-1]:
        adapter._validate_candidate_event(event, configuration)
    stopped_lifecycle = events[-1].get("renderResourceLifecycle", {})
    adapter._require(
        stopped_lifecycle.get("liveGenerations") == 0
        and stopped_lifecycle.get("programPublications")
            == stopped_lifecycle.get("programDeletions"),
        "macOS leaks --atExit run did not retire renderer resources",
    )
    return {
        "assignment": assignment,
        "loadCount": len(projects),
        "commands": commands,
        "exitStatus": completed.returncode,
        "clean": clean,
        "leakCount": leak_count,
        "leakedBytes": leaked_bytes,
        "eventTypes": expected,
        "stoppedLifecycle": stopped_lifecycle,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }


def _normalized_leak_evidence(report, criteria):
    matches = list(LEAK_STACK_HEADING.finditer(report["stdout"]))
    adapter._require(
        report["leakCount"] == 0 or matches,
        "macOS leaks reported objects without complete STACK OF evidence",
    )
    groups = []
    for index, match in enumerate(matches):
        next_heading = (
            matches[index + 1].start()
            if index + 1 < len(matches) else len(report["stdout"])
        )
        delimiter = re.search(
            r"(?m)^====\s*$", report["stdout"][match.end():next_heading]
        )
        adapter._require(
            delimiter is not None,
            "macOS leaks STACK OF evidence has no closing delimiter",
        )
        end = match.end() + delimiter.end()
        stack = report["stdout"][match.start():end].rstrip() + "\n"
        signatures = sorted(
            item["identity"]
            for item in criteria["allowedNormalizedSignatures"]
            if item["stackToken"] in stack
        )
        forbidden = sorted(
            token for token in criteria["forbiddenAttributionTokens"]
            if token in stack
        )
        groups.append({
            "instanceCount": int(match.group(1)),
            "stackSha256": hashlib.sha256(stack.encode("utf-8")).hexdigest(),
            "signatures": signatures,
            "forbiddenAttributionTokens": forbidden,
        })
    signatures = sorted({
        signature for group in groups for signature in group["signatures"]
    })
    return {
        "normalizationVersion": criteria["normalizationVersion"],
        "groups": groups,
        "normalizedSignatures": signatures,
        "unknownGroupCount": sum(not group["signatures"] for group in groups),
        "forbiddenAttributionGroupCount": sum(
            bool(group["forbiddenAttributionTokens"]) for group in groups
        ),
    }


def _matched_control_leaks_passed(subject, control, criteria):
    allowed = sorted(
        item["identity"] for item in criteria["allowedNormalizedSignatures"]
    )
    protocol = criteria["controlProtocol"]
    subject_signatures = set(subject["normalization"]["normalizedSignatures"])
    control_signatures = set(control["normalization"]["normalizedSignatures"])
    return (
        control["assignment"] == protocol["assignment"]
        and control["eventTypes"] == protocol["eventTypes"]
        and control["loadCount"] == protocol["loads"]
        and sorted(control_signatures) == allowed
        and subject_signatures <= control_signatures
        and len(subject_signatures - control_signatures)
            <= criteria["maximumSubjectOnlySignatures"]
        and subject["normalization"]["unknownGroupCount"]
            <= criteria["maximumUnknownGroups"]
        and subject["normalization"]["forbiddenAttributionGroupCount"]
            <= criteria["maximumForbiddenAttributionGroups"]
        and control["normalization"]["unknownGroupCount"]
            <= criteria["maximumUnknownGroups"]
        and control["normalization"]["forbiddenAttributionGroupCount"]
            <= criteria["maximumForbiddenAttributionGroups"]
        and subject["leakCount"] <= control["leakCount"]
        and subject["leakedBytes"] <= control["leakedBytes"]
    )


def _resource_sample(peak):
    return {"status": "available", "before": 0, "after": 0, "peak": peak}


def _validate_stopped_lifecycle(lifecycle, required):
    adapter._require(
        lifecycle.get("generationsCreated")
            == required["generationsPerIteration"]
        and lifecycle.get("generationsRetired")
            == required["generationsPerIteration"]
        and lifecycle.get("liveGenerations")
            == required["liveGenerationsAfterStop"]
        and lifecycle.get("completionBarriersCompleted")
            == required["completionBarriersPerIteration"]
        and lifecycle.get("completionBarriersFailed") == 0
        and lifecycle.get("retirementsWithoutCompletion") == 0
        and (
            not required["programPublicationDeletionBalance"]
            or lifecycle.get("programPublications")
                == lifecycle.get("programDeletions")
        ),
        "lifecycle iteration did not satisfy the predeclared reference",
    )


def _resource_criteria_passed(resources, criteria):
    return all(
        sample["status"] == "available"
        and sample["before"] == criterion["before"]
        and sample["after"] == criterion["after"]
        and sample["peak"] >= criterion["peakAtLeast"]
        for name, criterion in criteria.items()
        for sample in (resources[name],)
    )


def _load_material():
    root = adapter.WORKLOAD_ROOT / "resource-reload"
    manifest = contract.load_json(root / LIFECYCLE_MANIFEST)
    contract.validate_manifest(manifest)
    for item in manifest["assets"]:
        filename = adapter.ASSET_FILES.get(item["identity"])
        if filename is None:
            raise adapter.AdapterError("lifecycle manifest has an unknown asset")
        source = adapter.WORKLOAD_ROOT / "masks-effects" / filename
        if adapter._sha256_file(source) != (item["sha256"], item["bytes"]):
            raise adapter.AdapterError(f"lifecycle asset hash mismatch: {filename}")
    trace_item = manifest["inputs"][0]
    if adapter._sha256_file(root / LIFECYCLE_TRACE) != (
        trace_item["sha256"], trace_item["bytes"]
    ):
        raise adapter.AdapterError("lifecycle trace hash mismatch")
    reference = manifest["reference"]
    if adapter._sha256_file(root / LIFECYCLE_REFERENCE) != (
        reference["sha256"], reference["bytes"]
    ):
        raise adapter.AdapterError("lifecycle reference hash mismatch")
    return (
        root,
        manifest,
        contract.load_json(root / LIFECYCLE_TRACE),
        contract.load_json(root / LIFECYCLE_REFERENCE),
    )


def _artifact_set(
    scratch, configuration, binary_sha256, runs, evidence, reference_path
):
    paths = {
        "build-evidence": scratch / "build-evidence.json",
        "source-manifest": configuration.source_manifest,
        "lifecycle-commands": scratch / "lifecycle-commands.json",
        "lifecycle-stdout": scratch / "lifecycle.stdout.ndjson",
        "lifecycle-stderr": scratch / "lifecycle.stderr.txt",
        "lifecycle-raw-evidence": scratch / "lifecycle-raw-evidence.json",
        "lifecycle-reference": reference_path,
        "lifecycle-auditor-source": pathlib.Path(__file__).resolve(),
        "leak-tool-binary": LEAK_TOOL,
    }
    adapter._write_json(
        paths["build-evidence"],
        {
            "identity": configuration.build_identity,
            "sourceSha256": configuration.source_sha256,
            "binarySha256": binary_sha256,
            "commands": list(configuration.build_commands),
        },
    )
    adapter._write_json(
        paths["lifecycle-commands"],
        [command for run in runs for command in run["commands"]],
    )
    paths["lifecycle-stdout"].write_text(
        "".join(run["stdout"] for run in runs), encoding="utf-8"
    )
    paths["lifecycle-stderr"].write_text(
        "".join(run["stderr"] for run in runs), encoding="utf-8"
    )
    adapter._write_json(paths["lifecycle-raw-evidence"], evidence)
    media_types = {
        "build-evidence": "application/json",
        "source-manifest": "application/json",
        "lifecycle-commands": "application/json",
        "lifecycle-stdout": "application/x-ndjson",
        "lifecycle-stderr": "text/plain",
        "lifecycle-raw-evidence": "application/json",
        "lifecycle-reference": "application/json",
        "lifecycle-auditor-source": "text/x-python",
        "leak-tool-binary": "application/x-mach-binary",
    }
    return [
        contract.ingest_artifact(
            path, configuration.store_root, name, media_types[name]
        )
        for name, path in paths.items()
    ]


def run_lifecycle(configuration):
    configuration = adapter._validate_configuration(configuration)
    root, manifest, trace, reference = _load_material()
    binary_sha256, _binary_bytes = adapter._sha256_file(
        configuration.helper_binary
    )
    auditor_sha256, _auditor_bytes = adapter._sha256_file(
        pathlib.Path(__file__).resolve()
    )
    leak_tool_sha256, _leak_tool_bytes = adapter._sha256_file(LEAK_TOOL)
    started = adapter._utc_now()
    library = _proc_library()
    with tempfile.TemporaryDirectory(prefix="fresco-lifecycle-adapter.") as value:
        scratch = pathlib.Path(os.path.realpath(value))
        fixture_root = adapter.WORKLOAD_ROOT / "masks-effects"
        files = tuple(
            adapter.ASSET_FILES[identity]
            for identity in trace["assetIdentities"]
        )
        project_a = scratch / "project-a"
        project_b = scratch / "project-b"
        control_project = scratch / "appkit-window-control"
        project_a.mkdir()
        project_b.mkdir()
        control_project.mkdir()
        adapter._materialize_project(
            fixture_root, project_a, package_files=files
        )
        adapter._materialize_resource_reload_variant(
            fixture_root, project_b, files
        )
        adapter._materialize_project(
            adapter.WORKLOAD_ROOT / "static-no-media", control_project
        )
        common = {
            "assetRoot": os.fspath(configuration.asset_root),
            "width": trace["logicalWidth"],
            "height": trace["logicalHeight"],
            "fps": trace["fpsCeiling"],
            "policyRevision": trace["policyRevision"],
            "reasonTokens": trace["reasonTokens"],
            "visible": True,
            "muted": True,
            "evidenceFrames": 1,
        }
        raw_runs = []
        helper_runs = []
        resource_peaks = {
            "processes": 0,
            "childProcesses": 0,
            "rssBytes": 0,
            "threads": 0,
            "fileDescriptors": 0,
            "trackedPrograms": 0,
            "trackedRendererAllocations": 0,
        }
        child_executables = {}
        for iteration in range(1, trace["createDestroyIterations"] + 1):
            helper = adapter.HelperProcess(
                configuration.helper_binary,
                f"lifecycle-resource-{iteration}",
                configuration.timeout_seconds,
                environment={
                    "FRESCO_SCENE_AUDIO_DISABLED": "1",
                    "FRESCO_SCENE_SOUND_EXPERIMENTAL": "0",
                },
            )
            snapshots = []
            with helper:
                adapter._validate_candidate_event(
                    helper.exchange("hello"), configuration
                )
                snapshots.append(
                    _snapshot(library, helper.process.pid, "candidate-started")
                )
                first = helper.exchange(
                    "load", "ready", path=os.fspath(project_a), **common
                )
                adapter._validate_candidate_event(first, configuration)
                first_metrics = helper.exchange("metrics")
                adapter._validate_candidate_event(first_metrics, configuration)
                snapshots.append(
                    _snapshot(library, helper.process.pid, "first-load")
                )
                second = helper.exchange(
                    "load", "ready", path=os.fspath(project_b), **common
                )
                adapter._validate_candidate_event(second, configuration)
                second_metrics = helper.exchange("metrics")
                adapter._validate_candidate_event(second_metrics, configuration)
                snapshots.append(
                    _snapshot(library, helper.process.pid, "reload")
                )
                stopped = helper.stop()
                lifecycle = stopped.get("renderResourceLifecycle", {})
                _validate_stopped_lifecycle(lifecycle, reference["required"])
            table_after = _process_table()
            owned_pids = {
                snapshot["rootPid"] for snapshot in snapshots
            } | {
                child["pid"]
                for snapshot in snapshots
                for child in snapshot["children"]
            }
            adapter._require(
                not (owned_pids & set(table_after)),
                "lifecycle iteration left an owned process alive",
            )
            for snapshot in snapshots:
                for name, amount in snapshot["totals"].items():
                    resource_peaks[name] = max(resource_peaks[name], amount)
                for child in snapshot["children"]:
                    command = pathlib.Path(child["command"])
                    adapter._require(
                        command.is_file(),
                        "cannot identify an owned lifecycle child executable",
                    )
                    child_executables[child["command"]] = (
                        adapter._sha256_file(command)[0]
                    )
            resource_peaks["trackedPrograms"] = max(
                resource_peaks["trackedPrograms"],
                int(first.get("programCacheEntries", 0)),
                int(second.get("programCacheEntries", 0)),
            )
            resource_peaks["trackedRendererAllocations"] = max(
                resource_peaks["trackedRendererAllocations"],
                _live_renderer_allocations(first_metrics),
                _live_renderer_allocations(second_metrics),
            )
            raw_runs.append(
                {
                    "iteration": iteration,
                    "snapshots": snapshots,
                    "firstLoad": {
                        "resourceGeneration": first.get("resourceGeneration"),
                        "programCacheEntries": first.get("programCacheEntries"),
                        "liveRendererAllocations": _live_renderer_allocations(
                            first_metrics
                        ),
                    },
                    "reload": {
                        "resourceGeneration": second.get("resourceGeneration"),
                        "programCacheEntries": second.get("programCacheEntries"),
                        "liveRendererAllocations": _live_renderer_allocations(
                            second_metrics
                        ),
                    },
                    "stoppedLifecycle": lifecycle,
                    "ownedProcessesAfterStop": sorted(owned_pids & set(table_after)),
                }
            )
            helper_runs.append(
                {
                    "commands": helper.commands,
                    "stdout": helper.stdout,
                    "stderr": helper.stderr,
                }
            )
        adapter._require(
            not any(run["stderr"] for run in helper_runs),
            "lifecycle helper emitted diagnostics on stderr",
        )
        adapter._require(
            resource_peaks["processes"] >= 1
            and resource_peaks["rssBytes"] > 0
            and resource_peaks["threads"] > 0
            and resource_peaks["fileDescriptors"] > 0
            and resource_peaks["trackedPrograms"] > 0,
            "lifecycle resource sampling was incomplete",
        )
        leak_report = _leak_at_exit_report(
            configuration,
            "lifecycle-at-exit-leak-check",
            common,
            (project_a, project_b),
        )
        adapter._require(
            leak_report["exitStatus"] in (0, 1),
            "macOS leaks --atExit could not inspect the candidate",
        )
        completed = adapter._utc_now()
        matched_control = _leak_at_exit_report(
            configuration,
            "lifecycle-appkit-window-control",
            common,
            (control_project,),
        )
        leak_criteria = reference["leakCriteria"]
        leak_report["normalization"] = _normalized_leak_evidence(
            leak_report, leak_criteria
        )
        matched_control["normalization"] = _normalized_leak_evidence(
            matched_control, leak_criteria
        )
        matched_control_passed = _matched_control_leaks_passed(
            leak_report, matched_control, leak_criteria
        )
        raw_evidence = {
            "schemaVersion": 3,
            "auditor": {
                "identity": AUDITOR_IDENTITY,
                "version": AUDITOR_VERSION,
                "sourceSha256": auditor_sha256,
                "processApi": "macos-libproc-proc_pidinfo",
            },
            "iterations": raw_runs,
            "atExitLeakReport": leak_report,
            "matchedAppKitControl": matched_control,
            "resourcePeaks": resource_peaks,
            "deviceLoss": reference["deviceLoss"],
        }
        artifacts = _artifact_set(
            scratch,
            configuration,
            binary_sha256,
            helper_runs,
            raw_evidence,
            root / LIFECYCLE_REFERENCE,
        )
        process_manifest = [
            {
                "role": "candidate",
                "executableSha256": binary_sha256,
                "parentRole": None,
                "ownedByRun": True,
            }
        ]
        for index, (_command, digest) in enumerate(sorted(child_executables.items())):
            process_manifest.append(
                {
                    "role": f"child-{index + 1}",
                    "executableSha256": digest,
                    "parentRole": "candidate",
                    "ownedByRun": True,
                }
            )
        leak_status = "clean" if matched_control_passed else "leaks"
        failures = [] if matched_control_passed else [
            "macOS leaks --atExit evidence failed the predeclared matched-control criterion"
        ]
        lifecycle_resources = {
            **{
                name: _resource_sample(resource_peaks[name])
                for name in (
                    "processes",
                    "childProcesses",
                    "rssBytes",
                    "threads",
                    "fileDescriptors",
                    "trackedPrograms",
                    "trackedRendererAllocations",
                )
            },
            "driverGpuResources": reference["driverGpuResources"],
        }
        resources_passed = _resource_criteria_passed(
            lifecycle_resources, reference["resourceCriteria"]
        )
        record = {
            "schemaVersion": 2,
            "run": {
                "identity": (
                    "resource-reload-lifecycle-"
                    f"{configuration.expected_backend}-{binary_sha256[:12]}"
                ),
                "startedAtUtc": started,
                "completedAtUtc": completed,
                "operator": configuration.operator,
                "agentRole": configuration.agent_role,
                "purpose": "lifecycle",
                "sourceSha256": configuration.source_sha256,
                "binarySha256": binary_sha256,
                "workload": {"identity": "resource-reload", "version": 1},
                "manifestSha256": contract.manifest_hash(manifest),
                "assets": manifest["assets"],
                "inputs": manifest["inputs"],
                "seed": manifest["seed"],
            },
            "candidate": {
                "identity": configuration.expected_candidate,
                "backend": configuration.expected_backend,
                "graphicsApi": adapter.BACKENDS[
                    configuration.expected_backend
                ]["graphicsApi"],
                "shaderApi": adapter.BACKENDS[
                    configuration.expected_backend
                ]["shaderApi"],
            },
            "criteriaVersion": manifest["criteriaVersion"],
            "build": {
                "identity": configuration.build_identity,
                "sourceSha256": configuration.source_sha256,
                "binarySha256": binary_sha256,
                "commands": list(configuration.build_commands),
                "artifacts": ["build-evidence", "source-manifest"],
            },
            "lifecycle": {
                "processManifest": process_manifest,
                "iterations": {
                    "createDestroy": adapter._available(
                        trace["createDestroyIterations"]
                    ),
                    "reload": adapter._available(trace["reloadIterations"]),
                    "deviceLoss": reference["deviceLoss"],
                },
                "resources": lifecycle_resources,
                "leakEvidence": {
                    "tool": {
                        "identity": LEAK_TOOL_IDENTITY,
                        "version": LEAK_TOOL_VERSION,
                        "executableSha256": leak_tool_sha256,
                        "artifact": "leak-tool-binary",
                    },
                    "status": leak_status,
                    "artifact": "lifecycle-raw-evidence",
                },
                "artifacts": [
                    "lifecycle-commands",
                    "lifecycle-stdout",
                    "lifecycle-stderr",
                    "lifecycle-raw-evidence",
                    "lifecycle-reference",
                    "lifecycle-auditor-source",
                    "leak-tool-binary",
                ],
            },
            "artifacts": artifacts,
            "verdict": {
                "accepted": matched_control_passed and resources_passed,
                "criteriaVersion": manifest["criteriaVersion"],
                "checks": {
                    "build": True,
                    "lifecycle": True,
                    "resources": resources_passed,
                    "leaks": matched_control_passed,
                },
                "failures": failures,
            },
        }
        output = contract.write_record(
            record, manifest, configuration.store_root
        )
        return record, output
