#!/usr/bin/env python3

import hashlib
import json
import os
import pathlib
import re

import contract


CAMPAIGN_ID = "resource-lifecycle-control-calibration-v3-attempt-2"
EXPECTED_ORDER = [item for _ in range(20) for item in ("angle-metal", "native-opengl")]
ALLOWED = [
    {"identity": "AppIntents", "headingToken": "AppIntents"},
    {"identity": "LinkServices", "headingToken": "LinkServices"},
    {"identity": "NSXPCConnection", "headingToken": "NSXPCConnection"},
]
FORBIDDEN = [
    "FrescoScene", "fresco-scene", "WallpaperEngine", "OpenGL",
    "libGLES", "libEGL", "ANGLE", "Metal.framework", "AGXMetal", "MTL",
]
STACK = re.compile(r"(?m)^STACK OF ([0-9]+) INSTANCES? OF (.+)$")
DELIMITER = re.compile(r"(?m)^====\s*$")
SUMMARY = re.compile(r"Process [0-9]+: ([0-9]+) leaks for ([0-9]+) total leaked bytes\.")


class VerificationError(Exception):
    pass


def _require(condition, message):
    if not condition:
        raise VerificationError(message)


def _exact(value, keys, path):
    _require(isinstance(value, dict) and set(value) == set(keys), f"{path} schema changed")


def identity(path):
    try:
        value = pathlib.Path(path).read_bytes()
    except OSError as error:
        raise VerificationError(f"evidence path is missing: {path}") from error
    return {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}


def _events(stdout, assignment):
    result = []
    for line in stdout.splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and value.get("assignmentID") == assignment:
            result.append(value)
    return result


def rederive(run, expected_backend, ordinal, static_project):
    _exact(
        run,
        {
            "ordinal", "backend", "attemptWithinBackend", "attempt",
            "assignment", "elapsedNanoseconds", "status", "invalidReasons",
            "rawReport", "derived",
        },
        f"run {ordinal}",
    )
    _require(run["ordinal"] == ordinal and run["backend"] == expected_backend, f"run {ordinal} order changed")
    _require(run["attempt"] == 1, f"run {ordinal} was retried")
    raw = run["rawReport"]
    _exact(raw, {"commands", "exitStatus", "timedOut", "stdout", "stderr"}, f"run {ordinal} raw")
    commands = raw["commands"]
    _require(
        len(commands) == 3
        and [item.get("type") for item in commands] == ["hello", "load", "stop"]
        and all(item.get("assignmentID") == run["assignment"] for item in commands)
        and all(item.get("protocolVersion") == 1 for item in commands),
        f"run {ordinal} command protocol changed",
    )
    load = commands[1]
    _require(
        load == {
            "protocolVersion": 1, "type": "load", "assignmentID": run["assignment"],
            "path": os.fspath(static_project),
            "assetRoot": "/Users/astral/Library/Application Support/Fresco/Wallpaper Engine/assets",
            "width": 320, "height": 180, "fps": 5, "policyRevision": 1,
            "reasonTokens": ["harness:lifecycle-resource-reload"],
            "visible": True, "muted": True, "evidenceFrames": 1,
        },
        f"run {ordinal} is not the frozen static control",
    )
    invalid = []
    summary = SUMMARY.search(raw["stdout"])
    if summary is None:
        invalid.append("missing-raw-leak-summary")
        objects = leaked_bytes = None
    else:
        objects, leaked_bytes = int(summary.group(1)), int(summary.group(2))
    matches = list(STACK.finditer(raw["stdout"]))
    groups = []
    for index, match in enumerate(matches):
        next_start = matches[index + 1].start() if index + 1 < len(matches) else len(raw["stdout"])
        delimiter = DELIMITER.search(raw["stdout"], match.end(), next_start)
        if delimiter is None:
            invalid.append(f"group-{index + 1}-missing-delimiter")
            continue
        stack = raw["stdout"][match.start():delimiter.end()].rstrip() + "\n"
        identities = [item["identity"] for item in ALLOWED if item["headingToken"] in match.group(2)]
        forbidden = sorted(token for token in FORBIDDEN if token in stack)
        if len(identities) != 1:
            invalid.append(f"group-{index + 1}-classification-count-{len(identities)}")
        if forbidden:
            invalid.append(f"group-{index + 1}-forbidden-frame")
        groups.append({
            "identity": identities[0] if len(identities) == 1 else None,
            "instanceCount": int(match.group(1)),
            "stackSha256": hashlib.sha256(stack.encode()).hexdigest(),
            "forbiddenFrameTokens": forbidden,
        })
    if objects and not groups:
        invalid.append("leaks-without-root-groups")
    events = _events(raw["stdout"], run["assignment"])
    event_types = [item.get("type") for item in events]
    if event_types != ["hello", "ready", "stopped"]:
        invalid.append("control-protocol-mismatch")
    if raw["exitStatus"] not in (0, 1):
        invalid.append("leak-tool-exit-status")
    if raw["timedOut"]:
        invalid.append("control-timeout")
    lifecycle = events[-1].get("renderResourceLifecycle", {}) if events else {}
    if not (
        lifecycle.get("liveGenerations") == 0
        and lifecycle.get("completionBarriersFailed") == 0
        and lifecycle.get("retirementsWithoutCompletion") == 0
        and lifecycle.get("programPublications") == lifecycle.get("programDeletions")
    ):
        invalid.append("renderer-lifecycle-endpoint")
    per_signature = {
        item["identity"]: {
            "groupCount": sum(group["identity"] == item["identity"] for group in groups),
            "instanceCount": sum(group["instanceCount"] for group in groups if group["identity"] == item["identity"]),
        }
        for item in ALLOWED
    }
    derived = {
        "eventTypes": event_types,
        "totalRootGroupCount": len(groups),
        "totalRootInstances": sum(group["instanceCount"] for group in groups),
        "perSignature": per_signature,
        "rawLeakObjects": objects,
        "rawLeakBytes": leaked_bytes,
        "groups": groups,
    }
    return derived, sorted(set(invalid))


def derive_caps(runs):
    return {
        "populationCount": 40,
        "maximumTotalRootGroupCount": max(run["derived"]["totalRootGroupCount"] for run in runs),
        "maximumTotalRootInstances": max(run["derived"]["totalRootInstances"] for run in runs),
        "perSignatureMaxima": {
            identity: {
                "groupCount": max(run["derived"]["perSignature"][identity]["groupCount"] for run in runs),
                "instanceCount": max(run["derived"]["perSignature"][identity]["instanceCount"] for run in runs),
            }
            for identity in ("AppIntents", "LinkServices", "NSXPCConnection")
        },
        "maximumRawLeakObjects": max(run["derived"]["rawLeakObjects"] for run in runs),
        "maximumRawLeakBytes": max(run["derived"]["rawLeakBytes"] for run in runs),
    }


def validate(campaign, wal_root, store):
    wal_root, store = pathlib.Path(wal_root), pathlib.Path(store)
    _exact(
        campaign,
        {
            "schemaVersion", "identity", "purpose", "attempt", "plan", "schema",
            "ledger", "host", "tool", "helpers", "frozenOrder", "runReceipts",
            "runs", "campaignStatus", "invalidRuns", "derivedTable",
        },
        "campaign",
    )
    _require(campaign["schemaVersion"] == 3 and campaign["identity"] == CAMPAIGN_ID and campaign["purpose"] == "control-only-calibration" and campaign["attempt"] == 2, "campaign identity changed")
    _require(campaign["host"] == {"architecture": "arm64", "osBuild": "25F80", "osVersion": "26.5.1"}, "campaign host changed")
    _require(campaign["tool"] == {"bytes": 465440, "identity": "macos-leaks", "sha256": "5116e2b4f3ccb462a54f76991bfa82f13f0fb12dfc0c99712c6d926e1a1036d8", "version": "report-7"}, "campaign tool changed")
    expected_helpers = {
        "angle-metal": {"buildIdentity": "calibration-attempt-2-angle-metal", "candidate": "angle-metal-es3-2d", "helper": {"bytes": 7995488, "sha256": "80ad68c79dc3f8a6c9131f1a7dc94a1f6a95556b4b443d14f131d4888e2d6592"}, "sourceManifest": {"bytes": 60077, "sha256": "f30472394b78c9e90f2cb07e500fded80cebeec0b64a9484e3c74bee67d66dc1"}},
        "native-opengl": {"buildIdentity": "calibration-attempt-2-native-opengl", "candidate": "opengl-4.1-2d", "helper": {"bytes": 25106224, "sha256": "3c1bc0ad5d546e7f8172e005f2027c02793d60838f1feb02160c7b4e8de83353"}, "sourceManifest": {"bytes": 51403, "sha256": "d6cb2febd2575c49ea0519925e48ad3fc2f1c46ec86cf35a0166857f747426d8"}},
    }
    _require(campaign["helpers"] == expected_helpers, "campaign helpers changed")
    _require(campaign["frozenOrder"] == EXPECTED_ORDER and len(campaign["runs"]) == 40 and len(campaign["runReceipts"]) == 40, "campaign order or count changed")
    _require(campaign["invalidRuns"] == [] and campaign["campaignStatus"] == "valid", "campaign invalid-run verdict changed")
    static_project = wal_root / "appkit-window-control"
    counts = {"angle-metal": 0, "native-opengl": 0}
    reparsed = []
    for ordinal, (backend, run, receipt) in enumerate(zip(EXPECTED_ORDER, campaign["runs"], campaign["runReceipts"]), 1):
        counts[backend] += 1
        _require(run["attemptWithinBackend"] == counts[backend], f"run {ordinal} backend sequence changed")
        derived, invalid = rederive(run, backend, ordinal, static_project)
        _require(run["derived"] == derived and run["invalidReasons"] == invalid and run["status"] == ("valid" if not invalid else "invalid"), f"run {ordinal} derived verdict changed")
        _require(not invalid, f"run {ordinal} is invalid")
        name = f"calibration-attempt-2-slot-{ordinal:03d}-{backend}"
        _exact(receipt, {"ordinal", "backend", "name", "walPath", "walSha256", "walBytes", "casPath", "readbackSha256", "readbackBytes"}, f"receipt {ordinal}")
        expected_wal = wal_root / "wal" / f"{name}.json"
        _require(receipt["ordinal"] == ordinal and receipt["backend"] == backend and receipt["name"] == name and receipt["walPath"] == os.fspath(expected_wal), f"receipt {ordinal} identity changed")
        run_identity = {"sha256": hashlib.sha256(contract.canonical_json_bytes(run)).hexdigest(), "bytes": len(contract.canonical_json_bytes(run))}
        _require(identity(expected_wal) == run_identity, f"slot {ordinal} WAL changed")
        receipt_file = wal_root / "receipts" / f"{name}.receipt.json"
        disk_receipt = contract.load_json(receipt_file)
        _require(disk_receipt == {key: receipt[key] for key in receipt if key not in {"ordinal", "backend"}}, f"receipt {ordinal} file changed")
        _require(identity(receipt_file)["bytes"] > 0, f"receipt {ordinal} missing")
        _require(identity(store / receipt["casPath"]) == run_identity, f"slot {ordinal} CAS changed")
        _require(receipt["walSha256"] == receipt["readbackSha256"] == run_identity["sha256"] and receipt["walBytes"] == receipt["readbackBytes"] == run_identity["bytes"], f"receipt {ordinal} hash changed")
        reparsed.append({**run, "derived": derived})
    caps = derive_caps(reparsed)
    _require(campaign["derivedTable"] == caps, "campaign caps changed")
    campaign_wal = wal_root / "wal" / f"{CAMPAIGN_ID}.json"
    campaign_identity = identity(campaign_wal)
    _require(campaign_identity == {"sha256": "b01890aaed4d92eeaca9d8effaa005368bd5bbaef0ebfccebfb63e94e14ca471", "bytes": 6153169}, "final campaign WAL changed")
    final_receipt_path = wal_root / "receipts" / f"{CAMPAIGN_ID}.receipt.json"
    final_receipt = contract.load_json(final_receipt_path)
    _require(final_receipt["walSha256"] == final_receipt["readbackSha256"] == campaign_identity["sha256"] and final_receipt["walBytes"] == final_receipt["readbackBytes"] == campaign_identity["bytes"], "final receipt changed")
    _require(identity(store / final_receipt["casPath"]) == campaign_identity, "final campaign CAS changed")
    return {"campaign": campaign_identity, "caps": caps, "slotCount": 40, "receiptCount": 40}


def validate_addendum(addendum, archive_path):
    _exact(
        addendum,
        {
            "schemaVersion", "identity", "purpose", "campaign", "ledgerPrefix",
            "verification", "archive", "verdict", "derivedTable",
        },
        "verification addendum",
    )
    _require(
        addendum["schemaVersion"] == 1
        and addendum["identity"]
            == "resource-lifecycle-control-calibration-verification-addendum-v3"
        and addendum["purpose"] == "post-campaign-control-only-verification",
        "verification addendum identity changed",
    )
    _require(
        addendum["campaign"] == {
            "identity": CAMPAIGN_ID,
            "sha256": "b01890aaed4d92eeaca9d8effaa005368bd5bbaef0ebfccebfb63e94e14ca471",
            "bytes": 6153169,
        },
        "verification addendum campaign changed",
    )
    _require(
        addendum["ledgerPrefix"] == {
            "sha256": "3af1c8da158cff305343ba6cba7e83b9859dc00fd75ce7088b3d6d468f1e1f05",
            "bytes": 1760,
        },
        "verification addendum ledger prefix changed",
    )
    _require(
        addendum["verdict"] == {
            "accepted": True, "slotCount": 40, "receiptCount": 40,
            "invalidRuns": [], "unknownGroups": 0,
            "forbiddenAttributionGroups": 0,
            "subjectDataPresent": False,
        },
        "verification addendum verdict changed",
    )
    _exact(addendum["archive"], {"path", "sha256", "bytes", "entryCount"}, "verification archive")
    _exact(addendum["verification"], {"validatorSha256", "validatorBytes", "testsSha256", "testsBytes"}, "verification implementation")
    _require(
        all(
            re.fullmatch(r"[0-9a-f]{64}", addendum["verification"][name])
            for name in ("validatorSha256", "testsSha256")
        )
        and addendum["verification"]["validatorBytes"] > 0
        and addendum["verification"]["testsBytes"] > 0,
        "verification implementation binding changed",
    )
    _require(
        addendum["archive"]["path"] == os.fspath(pathlib.Path(archive_path))
        and identity(archive_path) == {
            "sha256": addendum["archive"]["sha256"],
            "bytes": addendum["archive"]["bytes"],
        }
        and addendum["archive"]["entryCount"] == 168,
        "verification archive binding changed",
    )
    expected_caps = {
        "populationCount": 40,
        "maximumTotalRootGroupCount": 2,
        "maximumTotalRootInstances": 3,
        "perSignatureMaxima": {
            "AppIntents": {"groupCount": 0, "instanceCount": 0},
            "LinkServices": {"groupCount": 0, "instanceCount": 0},
            "NSXPCConnection": {"groupCount": 2, "instanceCount": 3},
        },
        "maximumRawLeakObjects": 288,
        "maximumRawLeakBytes": 18816,
    }
    _require(addendum["derivedTable"] == expected_caps, "verification addendum caps changed")
    return addendum
