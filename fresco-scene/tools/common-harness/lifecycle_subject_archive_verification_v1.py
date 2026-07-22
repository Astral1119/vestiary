#!/usr/bin/env python3

import argparse
import hashlib
import io
import json
import pathlib
import re
import tarfile

import contract


HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE / "workloads" / "resource-reload"
EVIDENCE = pathlib.Path("/Users/astral/personal/vestiary/.fresco-evidence")
ARCHIVES = {
    "native-opengl": {
        "path": EVIDENCE / "lifecycle-v3-subject-native-native-opengl-evidence.tar.gz",
        "identity": {"sha256": "2899c457a56de3b05d492b9bcdd525792133d6b7d544d198fa1d9d5cb0ada676", "bytes": 1620952},
        "campaign": {"sha256": "6622864ad86446d06bd2efc5b441f574ebbda121740999ed77200e64a98419a0", "bytes": 1573005},
        "helper": {"sha256": "8cded9380c2c3aa41d2a2602af8bc991d1d81d031b4b4f4f8fb1d959a70b225b", "bytes": 7995264},
        "sourceManifest": {"sha256": "2eb56f9b06377fd7e021a70cb7c4dc312ec6a9c789fff096857710248f0ef570", "bytes": 55693},
        "root": EVIDENCE / "lifecycle-v3-subject-native",
    },
    "angle-metal": {
        "path": EVIDENCE / "lifecycle-v3-subject-angle-angle-metal-evidence.tar.gz",
        "identity": {"sha256": "f66de092a3b9d30f01dd361ca4788b9ae048461529d66a4fc4c0284150a70ff3", "bytes": 1616433},
        "campaign": {"sha256": "bd6001a626db1598256babdf2125b6916f10efa3df94bf814955ec435d50cb1c", "bytes": 1559788},
        "helper": {"sha256": "80ad68c79dc3f8a6c9131f1a7dc94a1f6a95556b4b443d14f131d4888e2d6592", "bytes": 7995488},
        "sourceManifest": {"sha256": "03b9d77202d1bcd3b5b5a1cf9c49fe0d45cd43a1d586a9aa894a8794a2bdf0f0", "bytes": 64371},
        "root": EVIDENCE / "lifecycle-v3-subject-angle",
    },
}
BINDINGS = {
    "manifest": (ROOT / "lifecycle-subject-manifest-v3.json", "5a36283d0f5c2cb150312b4be893266b04ba18051eda7ac82b0cecabd13ee18c", 557),
    "reference": (ROOT / "lifecycle-subject-reference-v3.json", "254d9ce9b99aabce57b4117fdc0f9abb6ca166370fd74bb819f5018c7c84b2c9", 1910),
    "trace": (ROOT / "lifecycle-subject-trace-v3.json", "7ab5db03b3cbb11ab8d48e747888c95980b4b1831da9e63cd6009b7f52629a11", 575),
    "freeze": (ROOT / "lifecycle-subject-freeze-v3.json", "bca80be1a39662b55939e83a9a10d95f41c08b8ae8a7483ef9e56b06bad9548f", 670),
    "runner": (HERE / "lifecycle_subject_v3.py", "6a2456c5ee2c137d29cf672d8846c13e0b73d75b3706565cd86e038373e0a466", 16199),
    "fixtureManifest": (ROOT / "lifecycle-manifest-v2.json", "8a4624dff4a53fbc140665361d7c4f2c040c0de6b6667ea08083dee73a2c465d", 3586),
}
FIXTURES = {
    "control-project/project.json": ("3231d7a400a14e9a0df025dbd8858d19a29a9bc094cc3f01735531c51087aa6b", 149),
    "control-project/scene.pkg": ("9cb2ed23651ac97b39ed3be2959fc36b64551b926018db8e1d815b82bdf4c2f1", 285),
    "subject-a/project.json": ("aad360896c583f4a57833f4010136dd960ecec576b1bdbf222d7baf91e7f344d", 207),
    "subject-a/scene.pkg": ("d6d6f97e4d1f8af2c904960d9b1e30376bb8bc2f61ca97d46e70b29a00065e93", 4204),
    "subject-b/project.json": ("aad360896c583f4a57833f4010136dd960ecec576b1bdbf222d7baf91e7f344d", 207),
    "subject-b/scene.pkg": ("e8c7b0aaa153328c5ea97e466d704563ddf79648a84f8b665b56c7477576cde8", 4204),
}
ORDER = ["control", "subject", "subject", "control", "control", "subject", "subject", "control", "control", "subject"]
FORBIDDEN = ["FrescoScene", "fresco-scene", "WallpaperEngine", "OpenGL", "libGLES", "libEGL", "ANGLE", "Metal.framework", "AGXMetal", "MTL"]
HEADINGS = {"AppIntents": (0, 0), "LinkServices": (0, 0), "NSXPCConnection": (2, 3)}
CAPS = {"totalRootGroupCount": 2, "totalRootInstances": 3, "rawLeakObjects": 288, "rawLeakBytes": 18816}
STACK = re.compile(r"(?m)^STACK OF ([0-9]+) INSTANCES? OF (.+)$")
SUMMARY = re.compile(r"Process [0-9]+: ([0-9]+) leaks for ([0-9]+) total leaked bytes\.")


class VerificationError(Exception):
    pass


def require(value, message):
    if not value:
        raise VerificationError(message)


def identity_bytes(value):
    return {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}


def identity_file(path):
    return identity_bytes(pathlib.Path(path).read_bytes())


def validate_local_bindings():
    values = {}
    for name, (path, digest, size) in BINDINGS.items():
        require(identity_file(path) == {"sha256": digest, "bytes": size}, f"{name} binding changed")
        values[name] = json.loads(path.read_text()) if path.suffix == ".json" else None
    manifest, reference, freeze = values["manifest"], values["reference"], values["freeze"]
    require(manifest["fixtureManifest"] == {"sha256": BINDINGS["fixtureManifest"][1], "bytes": BINDINGS["fixtureManifest"][2]}, "manifest fixture identity changed")
    require(freeze["runner"] == {"sha256": BINDINGS["runner"][1], "bytes": BINDINGS["runner"][2]}, "freeze runner changed")
    calibration = reference["calibration"]
    expected_calibration = {
        "archive": {"sha256": "8c55dbf13fb177f995941779a025dc266e075cd9c4367156e62ea7208c7b3549", "bytes": 6521240},
        "predecessorAddendum": {"sha256": "5fc22a625092183576816ee1ec8195ec4788d28db9dd4561c328ff9c412cf5b8", "bytes": 1610},
        "archiveAddendumV4": {"sha256": "f20f88b2aeee086df55d26e1aee530fd2634ae2ad92bd67603c838e84c60348b", "bytes": 1388},
        "archiveVerifier": {"sha256": "a9c5745de01448c44d0295ab9d3f8f3186b9dfa2d561a6f0eced2ed69f10cf73", "bytes": 9418},
    }
    require(calibration == expected_calibration, "calibration binding or caps changed")
    calibration_paths = {
        "archive": EVIDENCE / "lifecycle-v3-calibration-attempt2/evidence.tar.gz",
        "predecessorAddendum": ROOT / "lifecycle-control-calibration-verification-addendum-v3.json",
        "archiveAddendumV4": ROOT / "lifecycle-control-calibration-archive-addendum-v4.json",
        "archiveVerifier": HERE / "lifecycle_control_calibration_archive_verification_v4.py",
    }
    for name, path in calibration_paths.items():
        require(identity_file(path) == expected_calibration[name], f"calibration {name} material changed")
    expected_caps = {
        **CAPS,
        "perHeading": {name: {"groupCount": cap[0], "instanceCount": cap[1]} for name, cap in HEADINGS.items()},
        "unknownGroups": 0, "forbiddenGroups": 0, "subjectOnlyHeadings": 0,
    }
    require(reference["absoluteCaps"] == expected_caps, "criterion caps changed")
    return values


def read_archive(path, expected=None):
    raw = pathlib.Path(path).read_bytes()
    if expected is not None:
        require(identity_bytes(raw) == expected, "archive repack or identity changed")
    files, directories, mtimes = {}, set(), {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r|gz") as archive:
        for member in archive:
            name = member.name[2:] if member.name.startswith("./") else member.name
            require(name not in ("", ".") or member.isdir(), "invalid root member")
            require(not name.startswith("/") and ".." not in pathlib.PurePosixPath(name).parts, "unsafe archive member")
            require(member.isfile() or member.isdir(), "unsafe archive member type")
            require(name not in files and name not in directories, "duplicate archive member")
            mtimes[name] = member.mtime
            if member.isdir():
                directories.add(name.rstrip("/"))
            else:
                stream = archive.extractfile(member)
                require(stream is not None, "archive file unreadable")
                files[name] = stream.read()
    return {"files": files, "directories": directories, "mtimes": mtimes, "archiveIdentity": identity_bytes(raw)}


def json_member(image, name):
    require(name in image["files"], f"missing member {name}")
    try:
        value = json.loads(image["files"][name])
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise VerificationError(f"invalid JSON member {name}")
    require(contract.canonical_json_bytes(value) == image["files"][name], f"noncanonical JSON member {name}")
    return value


def expected_directories(files):
    result = {"."}
    for name in files:
        parent = pathlib.PurePosixPath(name).parent
        while str(parent) != ".":
            result.add(str(parent)); parent = parent.parent
    return result


def derive(raw, assignment, role):
    match = SUMMARY.search(raw["stdout"])
    require(match is not None, "missing leak summary")
    groups = []
    matches = list(STACK.finditer(raw["stdout"]))
    for index, item in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(raw["stdout"])
        delimiter = re.search(r"(?m)^====\s*$", raw["stdout"][item.end():end])
        require(delimiter is not None, "unterminated leak group")
        stack = raw["stdout"][item.start():item.end() + delimiter.end()]
        heading = item.group(2)
        identities = [name for name in HEADINGS if name in heading]
        require(len(identities) == 1, "unknown or ambiguous attribution group")
        require(not any(token in stack for token in FORBIDDEN), "forbidden attribution group")
        groups.append((identities[0], int(item.group(1))))
    events = []
    for line in raw["stdout"].splitlines():
        try: event = json.loads(line)
        except json.JSONDecodeError: continue
        if isinstance(event, dict) and event.get("assignmentID") == assignment: events.append(event)
    expected_types = ["hello", "ready", "stopped"] if role == "control" else ["hello", "ready", "ready", "stopped"]
    require([event.get("type") for event in events] == expected_types, "event sequence changed")
    endpoint = events[-1].get("renderResourceLifecycle", {})
    expected_endpoint = {
        "control": (1, 1, 0, 1), "subject": (2, 2, 0, 2),
    }[role]
    require((endpoint.get("generationsCreated"), endpoint.get("generationsRetired"), endpoint.get("liveGenerations"), endpoint.get("completionBarriersCompleted")) == expected_endpoint, "lifecycle endpoint changed")
    require(endpoint.get("completionBarriersFailed") == 0 and endpoint.get("retirementsWithoutCompletion") == 0, "lifecycle failure endpoint changed")
    require(isinstance(endpoint.get("programPublications"), int) and endpoint.get("programPublications") == endpoint.get("programDeletions"), "publication deletion endpoint changed")
    allocations = events[-1].get("renderAllocations")
    require(isinstance(allocations, dict) and all(isinstance(value, dict) and value.get("live") == 0 for value in allocations.values()), "allocation endpoint changed")
    per_heading = {name: {"groupCount": sum(group == name for group, _ in groups), "instanceCount": sum(count for group, count in groups if group == name)} for name in HEADINGS}
    derived = {
        "eventTypes": expected_types, "totalRootGroupCount": len(groups), "totalRootInstances": sum(count for _, count in groups),
        "perHeading": per_heading, "rawLeakObjects": int(match.group(1)), "rawLeakBytes": int(match.group(2)),
        "unknownGroups": 0, "forbiddenGroups": 0, "subjectOnlyHeadings": 0,
    }
    for key, cap in CAPS.items(): require(derived[key] <= cap, f"absolute cap exceeded: {key}")
    for name, (group_cap, instance_cap) in HEADINGS.items():
        require(per_heading[name]["groupCount"] <= group_cap and per_heading[name]["instanceCount"] <= instance_cap, f"heading cap exceeded: {name}")
    require(raw["exitStatus"] in (0, 1) and raw["timedOut"] is False, "process endpoint changed")
    return derived, endpoint, events


def verify_image(image, backend, local):
    specification = ARCHIVES[backend]
    campaign_name = "wal/accepted-campaign.json"
    campaign_bytes = image["files"].get(campaign_name, b"")
    require(identity_bytes(campaign_bytes) == specification["campaign"], "campaign identity changed")
    campaign = json_member(image, campaign_name)
    require(campaign["identity"] == f"resource-lifecycle-subject-v3-{backend}" and campaign["backend"] == backend, "campaign identity or backend changed")
    require(campaign["helper"] == specification["helper"] and campaign["sourceManifest"] == specification["sourceManifest"], "helper or source manifest changed")
    expected_bindings = {name: {"sha256": BINDINGS[name][1], "bytes": BINDINGS[name][2]} for name in ("manifest", "reference", "trace", "freeze")}
    require(campaign["bindings"] == expected_bindings, "campaign criterion binding changed")
    require(campaign["slotOrder"] == ORDER and campaign["campaignStatus"] == "accepted" and campaign["invalidRuns"] == [], "campaign order or verdict changed")
    require(len(campaign["runs"]) == len(campaign["runReceipts"]) == 10, "campaign completeness changed")
    wal_names = [f"wal/slot-{ordinal:02d}-{role}.json" for ordinal, role in enumerate(ORDER, 1)] + [campaign_name]
    receipt_names = [name.replace("wal/", "receipts/").replace(".json", ".receipt.json") for name in wal_names]
    cas_names = set()
    for wal_name, receipt_name in zip(wal_names, receipt_names):
        wal = image["files"].get(wal_name, b"")
        receipt = json_member(image, receipt_name)
        expected_name = pathlib.PurePosixPath(wal_name).stem
        require(receipt["name"] == expected_name, "receipt name changed")
        require(receipt["walSha256"] == hashlib.sha256(wal).hexdigest() and receipt["walBytes"] == len(wal), "WAL receipt changed")
        require(receipt["readbackSha256"] == receipt["walSha256"] and receipt["readbackBytes"] == receipt["walBytes"], "CAS readback receipt changed")
        expected_wal_path = specification["root"] / wal_name
        require(receipt["walPath"] == str(expected_wal_path), "WAL path changed")
        cas_name = "store/" + receipt["casPath"]
        require(cas_name == f"store/artifacts/sha256/{receipt['walSha256'][:2]}/{receipt['walSha256']}", "CAS path changed")
        require(image["files"].get(cas_name) == wal, "CAS content changed")
        cas_names.add(cas_name)
    expected_files = set(FIXTURES) | set(wal_names) | set(receipt_names) | cas_names
    require(len(image["files"]) == 39 and set(image["files"]) == expected_files, "archive file inventory changed")
    require(image["directories"] == expected_directories(expected_files), "archive directory inventory changed")
    for name, expected in FIXTURES.items(): require(identity_bytes(image["files"][name]) == {"sha256": expected[0], "bytes": expected[1]}, f"fixture changed: {name}")
    observed = {"totalRootGroupCount": 0, "totalRootInstances": 0, "rawLeakObjects": 0, "rawLeakBytes": 0, "perHeading": {name: {"groupCount": 0, "instanceCount": 0} for name in HEADINGS}, "unknownGroups": 0, "forbiddenGroups": 0, "subjectOnlyHeadings": 0}
    for ordinal, (role, run, embedded_receipt) in enumerate(zip(ORDER, campaign["runs"], campaign["runReceipts"]), 1):
        require(run == json_member(image, wal_names[ordinal - 1]), "campaign run differs from WAL")
        require(run["ordinal"] == ordinal and run["backend"] == backend and run["role"] == role and run["attempt"] == 1, "slot identity/order/role/attempt changed")
        assignment = f"subject-v3-{backend}-{ordinal:02d}-{role}"
        require(run["assignment"] == assignment, "assignment changed")
        commands = run["rawReport"]["commands"]
        expected_paths = [specification["root"] / "control-project"] if role == "control" else [specification["root"] / "subject-a", specification["root"] / "subject-b"]
        require([item.get("type") for item in commands] == ["hello", *("load" for _ in expected_paths), "stop"], "command sequence changed")
        require(all(item.get("protocolVersion") == 1 and item.get("assignmentID") == assignment for item in commands), "command protocol changed")
        loads = commands[1:-1]
        for command, project in zip(loads, expected_paths):
            require(command == {"protocolVersion": 1, "type": "load", "assignmentID": assignment, "path": str(project), "assetRoot": "/Users/astral/Library/Application Support/Fresco/Wallpaper Engine/assets", "width": 320, "height": 180, "fps": 5, "policyRevision": 1, "reasonTokens": ["harness:lifecycle-resource-reload-subject-v3"], "visible": True, "muted": True, "evidenceFrames": 1}, "load project or policy changed")
        derived, _endpoint, events = derive(run["rawReport"], assignment, role)
        comparable = {key: run["derived"][key] for key in derived}
        require(comparable == derived and run["status"] == "valid" and run["invalidReasons"] == [], "derived evidence or verdict changed")
        expected_renderer = ("opengl-4.1-2d", "OpenGL 4.1 core", "native-opengl") if backend == "native-opengl" else ("angle-metal-es3-2d", "OpenGL ES 3.0 via ANGLE Metal", "angle-metal")
        require((events[0].get("renderer"), events[0].get("graphicsAPI"), events[0].get("backend")) == expected_renderer, "raw backend attribution changed")
        receipt = json_member(image, receipt_names[ordinal - 1])
        require(embedded_receipt == {"ordinal": ordinal, "role": role, **receipt}, "embedded receipt changed")
        for key in CAPS: observed[key] = max(observed[key], derived[key])
        for name in HEADINGS:
            for key in ("groupCount", "instanceCount"): observed["perHeading"][name][key] = max(observed["perHeading"][name][key], derived["perHeading"][name][key])
    return {"backend": backend, "campaign": specification["campaign"], "archive": specification["identity"], "helper": specification["helper"], "sourceManifest": specification["sourceManifest"], "records": 10, "controls": 5, "subjects": 5, "verdict": "accepted", "observedMaxima": observed, "host": campaign["host"], "acceptedMtime": image["mtimes"][campaign_name], "fixtureIdentities": {name: identity_bytes(image["files"][name]) for name in FIXTURES}}


def verify_pair(images=None):
    local = validate_local_bindings()
    if images is None:
        images = {backend: read_archive(item["path"], item["identity"]) for backend, item in ARCHIVES.items()}
    reports = {backend: verify_image(images[backend], backend, local) for backend in ("native-opengl", "angle-metal")}
    native, angle = reports["native-opengl"], reports["angle-metal"]
    require(native["host"] == angle["host"], "cross-archive host changed")
    require(native["fixtureIdentities"] == angle["fixtureIdentities"], "cross-archive fixture changed")
    require(native["acceptedMtime"] < angle["acceptedMtime"], "native-before-ANGLE chronology changed")
    return reports


def write_addendum(path, reports, test_identity):
    verifier = identity_file(pathlib.Path(__file__).resolve())
    value = {
        "schemaVersion": 1, "identity": "resource-lifecycle-subject-v3-archive-verification-addendum-v1",
        "criterion": {name: {"sha256": BINDINGS[name][1], "bytes": BINDINGS[name][2]} for name in ("manifest", "reference", "trace", "freeze", "runner", "fixtureManifest")},
        "calibration": json.loads((ROOT / "lifecycle-subject-reference-v3.json").read_text())["calibration"],
        "absoluteCaps": json.loads((ROOT / "lifecycle-subject-reference-v3.json").read_text())["absoluteCaps"],
        "verifier": verifier, "hostileTests": test_identity,
        "archiveNativeProof": {"safeRegularFilesPerArchive": 39, "walReceiptCasChainsPerArchive": 11, "liveCampaignDirectoriesRequired": False, "stagingRequired": False},
        "backends": {backend: {key: report[key] for key in ("archive", "campaign", "helper", "sourceManifest", "records", "controls", "subjects", "verdict", "observedMaxima")} for backend, report in reports.items()},
        "crossArchive": {"sameHost": True, "sameFixtures": True, "nativeBeforeAngle": True},
    }
    pathlib.Path(path).write_bytes(contract.canonical_json_bytes(value))
    return {"path": str(path), **identity_file(path)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--addendum", type=pathlib.Path)
    parser.add_argument("--test-file", type=pathlib.Path)
    arguments = parser.parse_args()
    reports = verify_pair()
    result = {"status": "accepted", "backends": reports}
    if arguments.addendum:
        require(arguments.test_file is not None, "addendum requires hostile test binding")
        result["addendum"] = write_addendum(arguments.addendum, reports, identity_file(arguments.test_file))
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
