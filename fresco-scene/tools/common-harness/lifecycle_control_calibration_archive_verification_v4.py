#!/usr/bin/env python3

import hashlib
import io
import json
import pathlib
import tarfile

import contract
import lifecycle_control_calibration_verification_v3 as semantic


CAMPAIGN = semantic.CAMPAIGN_ID
METADATA = {
    "lifecycle-control-calibration-ledger-v3.jsonl",
    "lifecycle-control-calibration-freeze-v3-attempt2.json",
    "lifecycle-control-calibration-plan-v3-attempt2.json",
    "lifecycle-control-calibration-schema-v3-attempt2.json",
}


class ArchiveVerificationError(Exception):
    pass


def require(value, message):
    if not value:
        raise ArchiveVerificationError(message)


def digest(value):
    return {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}


def file_identity(path):
    return digest(pathlib.Path(path).read_bytes())


def archive_files(path):
    files, directories, names = {}, set(), set()
    try:
        archive = tarfile.open(path, "r:gz")
    except (OSError, tarfile.TarError) as error:
        raise ArchiveVerificationError("archive cannot be opened") from error
    with archive:
        for member in archive:
            name = member.name.rstrip("/")
            pure = pathlib.PurePosixPath(name)
            require(name and name not in names, "duplicate archive member")
            require(not pure.is_absolute() and ".." not in pure.parts, "unsafe archive member path")
            require(member.isfile() or member.isdir(), "archive links and special members are forbidden")
            names.add(name)
            if member.isdir():
                directories.add(name)
            else:
                stream = archive.extractfile(member)
                require(stream is not None, "archive file has no bytes")
                files[name] = stream.read()
    return files, directories


def load_json(files, name):
    require(name in files, f"missing archive member {name}")
    try:
        return json.loads(files[name])
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ArchiveVerificationError(f"invalid JSON member {name}") from error


def verify_archive(path):
    files, directories = archive_files(path)
    campaign_name = f"wal/{CAMPAIGN}.json"
    campaign = load_json(files, campaign_name)
    require(set(campaign) == {
        "schemaVersion", "identity", "purpose", "attempt", "plan", "schema",
        "ledger", "host", "tool", "helpers", "frozenOrder", "runReceipts",
        "runs", "campaignStatus", "invalidRuns", "derivedTable",
    }, "campaign schema changed")
    require(campaign["purpose"] == "control-only-calibration" and "subject" not in campaign, "subject data is forbidden")
    require(campaign["frozenOrder"] == semantic.EXPECTED_ORDER and len(campaign["runs"]) == 40, "campaign order changed")
    expected_wal = {campaign_name}
    expected_receipts = {f"receipts/{CAMPAIGN}.receipt.json"}
    expected_cas = set()
    reparsed = []
    historical_project = pathlib.Path("/private/var/tmp/fresco-calibration-attempt2-wal.0TKx2c/appkit-window-control")
    for ordinal, (backend, run, receipt) in enumerate(zip(semantic.EXPECTED_ORDER, campaign["runs"], campaign["runReceipts"]), 1):
        name = f"calibration-attempt-2-slot-{ordinal:03d}-{backend}"
        wal_name, receipt_name = f"wal/{name}.json", f"receipts/{name}.receipt.json"
        expected_wal.add(wal_name); expected_receipts.add(receipt_name); expected_cas.add(receipt["casPath"])
        require(receipt["ordinal"] == ordinal and receipt["backend"] == backend and receipt["name"] == name, f"receipt {ordinal} identity changed")
        require(receipt["walPath"] == f"/private/var/tmp/fresco-calibration-attempt2-wal.0TKx2c/wal/{name}.json", f"receipt {ordinal} historical path changed")
        wal_bytes = files.get(wal_name); require(wal_bytes is not None, f"missing WAL {ordinal}")
        archived_run = load_json(files, wal_name); require(archived_run == run, f"WAL {ordinal} changed")
        identity = digest(wal_bytes)
        require(identity == {"sha256": receipt["walSha256"], "bytes": receipt["walBytes"]}, f"WAL {ordinal} hash changed")
        disk_receipt = load_json(files, receipt_name)
        require(disk_receipt == {key: receipt[key] for key in receipt if key not in {"ordinal", "backend"}}, f"receipt {ordinal} bytes changed")
        cas_bytes = files.get(receipt["casPath"]); require(cas_bytes is not None and digest(cas_bytes) == identity, f"CAS {ordinal} changed")
        derived, invalid = semantic.rederive(run, backend, ordinal, historical_project)
        require(run["derived"] == derived and run["invalidReasons"] == invalid and not invalid and run["status"] == "valid", f"run {ordinal} semantic evidence changed")
        reparsed.append({**run, "derived": derived})
    final_receipt = load_json(files, f"receipts/{CAMPAIGN}.receipt.json")
    expected_cas.add(final_receipt["casPath"])
    campaign_identity = digest(files[campaign_name])
    require(campaign_identity == {"sha256": "b01890aaed4d92eeaca9d8effaa005368bd5bbaef0ebfccebfb63e94e14ca471", "bytes": 6153169}, "campaign bytes changed")
    require(digest(files.get(final_receipt["casPath"], b"")) == campaign_identity, "campaign CAS changed")
    require({name for name in files if name.startswith("wal/")} == expected_wal, "WAL inventory changed")
    require({name for name in files if name.startswith("receipts/")} == expected_receipts, "receipt inventory changed")
    require({name for name in files if name.startswith("artifacts/")} == expected_cas, "CAS inventory changed")
    require({name for name in files if "/" not in name} == METADATA, "metadata inventory changed")
    require(len(expected_wal) == len(expected_receipts) == len(expected_cas) == 41 and len(METADATA) == 4, "archive count changed")
    allowed_directories = set()
    for name in files:
        parent = pathlib.PurePosixPath(name).parent
        while str(parent) != ".":
            allowed_directories.add(str(parent)); parent = parent.parent
    require(directories == allowed_directories, "archive directory inventory changed")
    ledger = files["lifecycle-control-calibration-ledger-v3.jsonl"]
    require(digest(ledger) == campaign["ledger"] == {"sha256": "3af1c8da158cff305343ba6cba7e83b9859dc00fd75ce7088b3d6d468f1e1f05", "bytes": 1760}, "ledger prefix changed")
    freeze = load_json(files, "lifecycle-control-calibration-freeze-v3-attempt2.json")
    require(freeze["plan"] == campaign["plan"] and freeze["schema"] == campaign["schema"], "freeze binding changed")
    require(digest(files["lifecycle-control-calibration-plan-v3-attempt2.json"]) == campaign["plan"], "plan binding changed")
    require(digest(files["lifecycle-control-calibration-schema-v3-attempt2.json"]) == campaign["schema"], "schema binding changed")
    caps = semantic.derive_caps(reparsed)
    require(campaign["derivedTable"] == caps and campaign["invalidRuns"] == [] and campaign["campaignStatus"] == "valid", "campaign verdict changed")
    return {"campaign": campaign_identity, "caps": caps, "files": 127, "directories": len(directories)}


def rewrite_archive(source, target, mutation):
    files, directories = archive_files(source)
    mutation(files, directories)
    with tarfile.open(target, "w:gz") as archive:
        for name in sorted(directories):
            info = tarfile.TarInfo(name + "/"); info.type = tarfile.DIRTYPE; info.mode = 0o700
            archive.addfile(info)
        for name, value in sorted(files.items()):
            info = tarfile.TarInfo(name); info.size = len(value); info.mode = 0o600
            archive.addfile(info, io.BytesIO(value))


def verify_addendum(
    addendum, archive, predecessor_addendum, verifier_source, test_source
):
    require(set(addendum) == {
        "schemaVersion", "identity", "purpose", "predecessorAddendum",
        "archive", "verification", "verdict", "derivedTable",
    }, "archive addendum schema changed")
    require(addendum["schemaVersion"] == 1 and addendum["identity"] == "resource-lifecycle-control-calibration-archive-addendum-v4" and addendum["purpose"] == "archive-native-post-campaign-verification", "archive addendum identity changed")
    require(addendum["predecessorAddendum"] == {"sha256": "5fc22a625092183576816ee1ec8195ec4788d28db9dd4561c328ff9c412cf5b8", "bytes": 1610}, "predecessor addendum changed")
    require(
        file_identity(predecessor_addendum) == addendum["predecessorAddendum"],
        "predecessor addendum bytes changed",
    )
    require(addendum["archive"] == {"path": str(pathlib.Path(archive)), "sha256": "8c55dbf13fb177f995941779a025dc266e075cd9c4367156e62ea7208c7b3549", "bytes": 6521240, "fileCount": 127}, "archive addendum binding changed")
    require(
        file_identity(archive) == {
            "sha256": addendum["archive"]["sha256"],
            "bytes": addendum["archive"]["bytes"],
        },
        "archive bytes changed",
    )
    require(file_identity(verifier_source) == addendum["verification"]["verifier"] and file_identity(test_source) == addendum["verification"]["tests"], "verifier source binding changed")
    result = verify_archive(archive)
    require(addendum["verdict"] == {"accepted": True, "archiveOnly": True, "stagingRequired": False, "slotCount": 40, "receiptCount": 40, "invalidRuns": [], "subjectDataPresent": False}, "archive addendum verdict changed")
    require(addendum["derivedTable"] == result["caps"], "archive addendum caps changed")
    return addendum
