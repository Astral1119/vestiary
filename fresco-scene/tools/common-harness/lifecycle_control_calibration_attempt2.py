#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import pathlib
import platform
import subprocess
import time

import adapter
import contract
import lifecycle_control_calibration as base


CAMPAIGN_ID = "resource-lifecycle-control-calibration-v3-attempt-2"
PLAN_FILE = "lifecycle-control-calibration-plan-v3-attempt2.json"
SCHEMA_FILE = "lifecycle-control-calibration-schema-v3-attempt2.json"
FREEZE_FILE = "lifecycle-control-calibration-freeze-v3-attempt2.json"
LEDGER_FILE = "lifecycle-control-calibration-ledger-v3.jsonl"


def _require(condition, message):
    if not condition:
        raise base.CalibrationError(message)


def _identity(path):
    value = pathlib.Path(path).read_bytes()
    return {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}


def _atomic_json(path, value):
    path = pathlib.Path(os.path.realpath(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = contract.canonical_json_bytes(value)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as stream:
            stream.write(payload)
            stream.flush()
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    return _identity(path)


def _readback(store, artifact, expected):
    path = pathlib.Path(store) / artifact["path"]
    identity = _identity(path)
    _require(identity == expected, "CAS readback identity changed")
    return identity


def _persist_record(value, name, wal_directory, receipt_directory, store):
    store = pathlib.Path(os.path.realpath(store))
    store.mkdir(parents=True, exist_ok=True)
    wal = pathlib.Path(wal_directory) / f"{name}.json"
    wal_identity = _atomic_json(wal, value)
    artifact = contract.ingest_artifact(wal, store, name, "application/json")
    readback = _readback(store, artifact, wal_identity)
    receipt = {
        "name": name,
        "walPath": os.fspath(wal),
        "walSha256": wal_identity["sha256"],
        "walBytes": wal_identity["bytes"],
        "casPath": artifact["path"],
        "readbackSha256": readback["sha256"],
        "readbackBytes": readback["bytes"],
    }
    receipt_path = pathlib.Path(receipt_directory) / f"{name}.receipt.json"
    _atomic_json(receipt_path, receipt)
    return artifact, receipt


def _load_material():
    root = adapter.WORKLOAD_ROOT / "resource-reload"
    plan_path, schema_path, freeze_path, ledger_path = (
        root / PLAN_FILE, root / SCHEMA_FILE, root / FREEZE_FILE, root / LEDGER_FILE
    )
    plan = contract.load_json(plan_path)
    schema = contract.load_json(schema_path)
    freeze = contract.load_json(freeze_path)
    ledger = [json.loads(line) for line in ledger_path.read_text().splitlines() if line]
    validate_plan(plan)
    _require(freeze["campaignIdentity"] == CAMPAIGN_ID, "freeze campaign changed")
    _require(freeze["plan"] == _identity(plan_path), "freeze plan hash changed")
    _require(freeze["schema"] == _identity(schema_path), "freeze schema hash changed")
    _require(freeze["runner"] == _identity(pathlib.Path(__file__).resolve()), "freeze runner hash changed")
    validate_ledger(ledger, freeze)
    return root, plan, schema, freeze, ledger


def validate_plan(plan):
    _require(plan["schemaVersion"] == 3 and plan["identity"] == CAMPAIGN_ID, "attempt-2 plan identity changed")
    _require(plan["attempt"] == 2 and plan["orderSeed"] == 2026072202, "attempt-2 seed changed")
    expected = [item for _ in range(20) for item in ("angle-metal", "native-opengl")]
    _require(plan["frozenOrder"] == expected, "attempt-2 order changed")
    _require(plan["completenessPolicy"] == "exactly 40 fresh slots; one attempt each; no retry, resume, or replacement", "attempt-2 completeness policy changed")
    shadow = dict(plan)
    shadow.pop("attempt")
    shadow.pop("orderSeed")
    shadow.pop("completenessPolicy")
    shadow["identity"] = "resource-lifecycle-control-calibration-v3"
    shadow["frozenOrder"] = [item for _ in range(20) for item in ("native-opengl", "angle-metal")]
    base.validate_plan(shadow)


def validate_ledger(entries, freeze):
    _require(len(entries) == 2, "ledger must contain attempt-1 failure and excluded smoke before controls")
    failure, smoke = entries
    _require(
        failure.get("entryType") == "campaign-failure"
        and failure.get("attempt") == 1
        and failure.get("completedChildSlots") == 40
        and failure.get("storeState") == "empty"
        and failure.get("retention") == {
            "rawTotals": False, "rawOutputs": False,
            "runRecords": False, "derivedCaps": False,
        },
        "attempt-1 failure ledger changed",
    )
    _require(
        smoke.get("entryType") == "publication-smoke"
        and smoke.get("campaignIdentity") == CAMPAIGN_ID
        and smoke.get("excludedFromCalibration") is True
        and smoke.get("freezeSha256") == hashlib.sha256(
            contract.canonical_json_bytes(freeze)
        ).hexdigest()
        and smoke.get("status") == "passed",
        "publication smoke ledger is missing or invalid",
    )


def run_preflight(wal_root, store):
    wal_root = pathlib.Path(os.path.realpath(wal_root))
    store = pathlib.Path(os.path.realpath(store))
    _require(str(wal_root).startswith("/private/var/tmp/"), "smoke WAL is not physical /private/var/tmp")
    _require(str(store).startswith("/private/var/tmp/"), "smoke store is not physical /private/var/tmp")
    payload = {
        "schemaVersion": 1,
        "identity": "calibration-attempt-2-publication-smoke",
        "excludedFromCalibration": True,
        "nonce": hashlib.sha256(f"{time.time_ns()}".encode()).hexdigest(),
    }
    artifact, receipt = _persist_record(
        payload, "calibration-attempt-2-publication-smoke",
        wal_root / "wal", wal_root / "receipts", store,
    )
    return {"payload": payload, "artifact": artifact, "receipt": receipt}


def _partial_campaign(plan, freeze, ledger_identity, host, tool, helpers, receipts, runs, invalid):
    return {
        "schemaVersion": 3,
        "identity": CAMPAIGN_ID,
        "purpose": "control-only-calibration",
        "attempt": 2,
        "plan": freeze["plan"],
        "schema": freeze["schema"],
        "ledger": ledger_identity,
        "host": host,
        "tool": tool,
        "helpers": helpers,
        "frozenOrder": plan["frozenOrder"],
        "runReceipts": receipts,
        "runs": runs,
        "campaignStatus": "invalid",
        "invalidRuns": invalid,
        "derivedTable": None,
    }


def validate_campaign(campaign, plan, freeze, ledger_identity, store, *, require_complete=True):
    _require(campaign["identity"] == CAMPAIGN_ID and campaign["attempt"] == 2, "attempt-2 campaign identity changed")
    _require(campaign["plan"] == freeze["plan"] and campaign["schema"] == freeze["schema"], "attempt-2 frozen binding changed")
    _require(campaign["ledger"] == ledger_identity, "attempt-2 ledger binding changed")
    _require(campaign["frozenOrder"] == plan["frozenOrder"], "attempt-2 campaign order changed")
    runs, receipts = campaign["runs"], campaign["runReceipts"]
    _require(len(runs) == len(receipts), "attempt-2 run receipt omitted")
    for index, (run, receipt) in enumerate(zip(runs, receipts), 1):
        _require(run["ordinal"] == index and run["backend"] == plan["frozenOrder"][index - 1], "attempt-2 slot reordered")
        _require(run["attempt"] == 1, "attempt-2 slot retried")
        payload = contract.canonical_json_bytes(run)
        expected = {"sha256": hashlib.sha256(payload).hexdigest(), "bytes": len(payload)}
        _require(receipt["walSha256"] == expected["sha256"] and receipt["walBytes"] == expected["bytes"], "attempt-2 WAL receipt changed")
        cas = pathlib.Path(store) / receipt["casPath"]
        _require(_identity(cas) == expected, "attempt-2 CAS receipt changed")
    if require_complete:
        _require(len(runs) == 40 and not campaign["invalidRuns"], "attempt-2 campaign incomplete")
        _require(campaign["campaignStatus"] == "valid", "attempt-2 campaign is not valid")
        _require(campaign["derivedTable"] == base._derived_table(runs, plan), "attempt-2 maxima changed")
    else:
        _require(campaign["campaignStatus"] == "invalid" and campaign["derivedTable"] is None, "partial campaign derived caps")
    return campaign


def run_campaign(configurations, wal_root, store):
    root, plan, _schema, freeze, _ledger = _load_material()
    wal_root = pathlib.Path(os.path.realpath(wal_root))
    store = pathlib.Path(os.path.realpath(store))
    _require(str(wal_root).startswith("/private/var/tmp/"), "campaign WAL is not physical /private/var/tmp")
    _require(str(store).startswith("/private/var/tmp/"), "campaign store is not physical /private/var/tmp")
    ledger_identity = _identity(root / LEDGER_FILE)
    by_backend = {item.expected_backend: item for item in configurations}
    _require(set(by_backend) == {"native-opengl", "angle-metal"}, "attempt-2 helper set changed")
    leak_identity = _identity(base.LEAK_TOOL)
    tool = {"identity": base.LEAK_TOOL_IDENTITY, "version": base.LEAK_TOOL_VERSION, **leak_identity}
    host = {
        "osVersion": platform.mac_ver()[0],
        "osBuild": subprocess.run(["/usr/bin/sw_vers", "-buildVersion"], capture_output=True, text=True, check=True).stdout.strip(),
        "architecture": platform.machine(),
    }
    helpers = {
        backend: {
            "candidate": item.expected_candidate,
            "buildIdentity": item.build_identity,
            "helper": _identity(item.helper_binary),
            "sourceManifest": _identity(item.source_manifest),
        }
        for backend, item in by_backend.items()
    }
    project = wal_root / "appkit-window-control"
    project.mkdir(parents=True, exist_ok=False)
    adapter._materialize_project(adapter.WORKLOAD_ROOT / "static-no-media", project)
    trace = contract.load_json(adapter.WORKLOAD_ROOT / "resource-reload" / "lifecycle-trace-v2.json")
    common = {
        "assetRoot": os.fspath(configurations[0].asset_root),
        "width": trace["logicalWidth"], "height": trace["logicalHeight"],
        "fps": trace["fpsCeiling"], "policyRevision": trace["policyRevision"],
        "reasonTokens": trace["reasonTokens"], "visible": True, "muted": True,
        "evidenceFrames": 1,
    }
    runs, receipts = [], []
    counts = {"native-opengl": 0, "angle-metal": 0}
    for ordinal, backend in enumerate(plan["frozenOrder"], 1):
        counts[backend] += 1
        run = base._run_attempt(by_backend[backend], project, common, ordinal, counts[backend], plan)
        name = f"calibration-attempt-2-slot-{ordinal:03d}-{backend}"
        try:
            _artifact, receipt = _persist_record(run, name, wal_root / "wal", wal_root / "receipts", store)
        except Exception as error:
            failure = {"ordinal": ordinal, "backend": backend, "error": f"{type(error).__name__}: {error}"}
            _atomic_json(wal_root / "publication-failure.json", failure)
            partial = _partial_campaign(plan, freeze, ledger_identity, host, tool, helpers, receipts, runs, [ordinal])
            _atomic_json(wal_root / "partial-campaign.json", partial)
            raise
        runs.append(run)
        receipts.append({"ordinal": ordinal, "backend": backend, **receipt})
        if run["status"] != "valid":
            partial = _partial_campaign(plan, freeze, ledger_identity, host, tool, helpers, receipts, runs, [ordinal])
            validate_campaign(partial, plan, freeze, ledger_identity, store, require_complete=False)
            _persist_record(partial, "calibration-attempt-2-partial-invalid", wal_root / "wal", wal_root / "receipts", store)
            return partial, None
    campaign = _partial_campaign(plan, freeze, ledger_identity, host, tool, helpers, receipts, runs, [])
    campaign["campaignStatus"] = "valid"
    campaign["derivedTable"] = base._derived_table(runs, plan)
    validate_campaign(campaign, plan, freeze, ledger_identity, store)
    artifact, receipt = _persist_record(campaign, CAMPAIGN_ID, wal_root / "wal", wal_root / "receipts", store)
    return campaign, {"artifact": artifact, "receipt": receipt}


def configurations(arguments):
    result = []
    for backend, candidate, helper, manifest in (
        ("native-opengl", "opengl-4.1-2d", arguments.native_helper, arguments.native_source_manifest),
        ("angle-metal", "angle-metal-es3-2d", arguments.angle_helper, arguments.angle_source_manifest),
    ):
        result.append(adapter.CandidateConfiguration(
            helper_binary=adapter.normalize_wrapper_path(helper),
            asset_root=adapter.normalize_wrapper_path(arguments.assets),
            expected_candidate=candidate, expected_backend=backend,
            store_root=pathlib.Path(os.path.realpath(arguments.store)),
            source_manifest=adapter.normalize_wrapper_path(manifest),
            source_sha256=_identity(manifest)["sha256"],
            build_identity=f"calibration-attempt-2-{backend}",
            build_commands=(f"prebuilt control helper: {backend}",),
            operator="calibration-v3-attempt-2", agent_role="subagent",
            timeout_seconds=arguments.timeout,
        ))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("preflight", "campaign"), required=True)
    parser.add_argument("--native-helper", type=pathlib.Path)
    parser.add_argument("--angle-helper", type=pathlib.Path)
    parser.add_argument("--assets", type=pathlib.Path)
    parser.add_argument("--native-source-manifest", type=pathlib.Path)
    parser.add_argument("--angle-source-manifest", type=pathlib.Path)
    parser.add_argument("--wal-root", required=True, type=pathlib.Path)
    parser.add_argument("--store", required=True, type=pathlib.Path)
    parser.add_argument("--timeout", type=float, default=30)
    arguments = parser.parse_args()
    if arguments.mode == "preflight":
        print(json.dumps(run_preflight(arguments.wal_root, arguments.store), separators=(",", ":")))
        return
    campaign, publication = run_campaign(configurations(arguments), arguments.wal_root, arguments.store)
    print(json.dumps({
        "campaignStatus": campaign["campaignStatus"],
        "invalidRuns": campaign["invalidRuns"],
        "derivedTable": campaign["derivedTable"],
        "publication": publication,
    }, separators=(",", ":")))


if __name__ == "__main__":
    main()
