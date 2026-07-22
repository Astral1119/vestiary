#!/usr/bin/env python3

import copy
import io
import json
import pathlib
import tarfile
import tempfile
import unittest
from unittest import mock

import contract
import lifecycle_subject_archive_verification_v1 as verifier


def clone(image):
    return {"files": dict(image["files"]), "directories": set(image["directories"]), "mtimes": dict(image["mtimes"]), "archiveIdentity": dict(image["archiveIdentity"])}


def replace_chain(image, name, value):
    wal_name = f"wal/{name}.json"
    receipt_name = f"receipts/{name}.receipt.json"
    old_receipt = json.loads(image["files"][receipt_name])
    old_cas = "store/" + old_receipt["casPath"]
    payload = contract.canonical_json_bytes(value)
    identity = verifier.identity_bytes(payload)
    receipt = dict(old_receipt)
    receipt.update({
        "walSha256": identity["sha256"], "walBytes": identity["bytes"],
        "readbackSha256": identity["sha256"], "readbackBytes": identity["bytes"],
        "casPath": f"artifacts/sha256/{identity['sha256'][:2]}/{identity['sha256']}",
    })
    new_cas = "store/" + receipt["casPath"]
    del image["files"][old_cas]
    image["files"][new_cas] = payload
    image["files"][wal_name] = payload
    image["files"][receipt_name] = contract.canonical_json_bytes(receipt)
    image["directories"] = verifier.expected_directories(image["files"])
    return receipt, identity


def mutate_run(image, ordinal, change):
    campaign = json.loads(image["files"]["wal/accepted-campaign.json"])
    run = copy.deepcopy(campaign["runs"][ordinal - 1])
    change(run)
    role = verifier.ORDER[ordinal - 1]
    receipt, _ = replace_chain(image, f"slot-{ordinal:02d}-{role}", run)
    campaign["runs"][ordinal - 1] = run
    campaign["runReceipts"][ordinal - 1] = {"ordinal": ordinal, "role": role, **receipt}
    _, campaign_identity = replace_chain(image, "accepted-campaign", campaign)
    return campaign_identity


def mutate_campaign(image, change):
    campaign = json.loads(image["files"]["wal/accepted-campaign.json"])
    change(campaign)
    _, identity = replace_chain(image, "accepted-campaign", campaign)
    return identity


def tar_bytes(image, extra=None, unsafe=None):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        for name, value in image["files"].items():
            info = tarfile.TarInfo(name); info.size = len(value)
            archive.addfile(info, io.BytesIO(value))
        if extra:
            info = tarfile.TarInfo(extra); info.size = 1
            archive.addfile(info, io.BytesIO(b"x"))
        if unsafe:
            info = tarfile.TarInfo(unsafe); info.size = 1
            archive.addfile(info, io.BytesIO(b"x"))
    return output.getvalue()


class ArchiveVerificationV1Test(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.images = {backend: verifier.read_archive(item["path"], item["identity"]) for backend, item in verifier.ARCHIVES.items()}
        cls.local = verifier.validate_local_bindings()

    def assert_rejected(self, image, backend="native-opengl", campaign_identity=None):
        specification = copy.deepcopy(verifier.ARCHIVES)
        if campaign_identity is not None:
            specification[backend]["campaign"] = campaign_identity
        with mock.patch.object(verifier, "ARCHIVES", specification):
            with self.assertRaises(verifier.VerificationError):
                verifier.verify_image(image, backend, self.local)

    def test_baseline_and_local_binding_drift(self):
        verifier.verify_pair(self.images)
        original = verifier.identity_file
        fixture = verifier.BINDINGS["fixtureManifest"][0]
        def drift(path):
            value = original(path)
            return {**value, "bytes": value["bytes"] + 1} if pathlib.Path(path) == fixture else value
        with mock.patch.object(verifier, "identity_file", side_effect=drift):
            with self.assertRaisesRegex(verifier.VerificationError, "fixtureManifest"):
                verifier.validate_local_bindings()
        calibration = verifier.EVIDENCE / "lifecycle-v3-calibration-attempt2/evidence.tar.gz"
        def calibration_drift(path):
            value = original(path)
            return {**value, "bytes": value["bytes"] + 1} if pathlib.Path(path) == calibration else value
        with mock.patch.object(verifier, "identity_file", side_effect=calibration_drift):
            with self.assertRaisesRegex(verifier.VerificationError, "calibration archive"):
                verifier.validate_local_bindings()
        changed_caps = dict(verifier.CAPS); changed_caps["rawLeakBytes"] -= 1
        with mock.patch.object(verifier, "CAPS", changed_caps):
            with self.assertRaisesRegex(verifier.VerificationError, "criterion caps"):
                verifier.validate_local_bindings()

    def test_archive_repack_identity_unsafe_extra_and_missing(self):
        image = self.images["native-opengl"]
        with tempfile.TemporaryDirectory() as value:
            path = pathlib.Path(value) / "repacked.tar.gz"
            path.write_bytes(tar_bytes(image))
            with self.assertRaisesRegex(verifier.VerificationError, "repack"):
                verifier.read_archive(path, verifier.ARCHIVES["native-opengl"]["identity"])
            path.write_bytes(tar_bytes(image, unsafe="../escape"))
            with self.assertRaisesRegex(verifier.VerificationError, "unsafe"):
                verifier.read_archive(path)
        changed = clone(image); changed["files"]["extra"] = b"x"; self.assert_rejected(changed)
        changed = clone(image); del changed["files"]["subject-b/scene.pkg"]; self.assert_rejected(changed)

    def test_receipt_cas_and_wal_mutations(self):
        image = clone(self.images["native-opengl"]); image["files"]["receipts/slot-01-control.receipt.json"] += b" "; self.assert_rejected(image)
        image = clone(self.images["native-opengl"]); cas = next(name for name in image["files"] if name.startswith("store/artifacts/sha256/")); image["files"][cas] += b"x"; self.assert_rejected(image)
        image = clone(self.images["native-opengl"]); image["files"]["wal/slot-01-control.json"] += b"x"; self.assert_rejected(image)

    def test_top_level_identity_backend_helper_source_and_manifest_fixture(self):
        changes = [
            lambda c: c.__setitem__("identity", "forged"),
            lambda c: c.__setitem__("backend", "angle-metal"),
            lambda c: c.__setitem__("helper", {"sha256": "0" * 64, "bytes": 1}),
            lambda c: c.__setitem__("sourceManifest", {"sha256": "0" * 64, "bytes": 1}),
        ]
        for change in changes:
            image = clone(self.images["native-opengl"]); identity = mutate_campaign(image, change); self.assert_rejected(image, campaign_identity=identity)
        manifest = copy.deepcopy(self.local["manifest"]); manifest["fixtureManifest"]["bytes"] += 1
        local = dict(self.local); local["manifest"] = manifest
        # The live binding validator, not caller-supplied parsed state, owns this boundary.
        with mock.patch.object(verifier, "identity_file", return_value={"sha256": "0" * 64, "bytes": 0}):
            with self.assertRaises(verifier.VerificationError): verifier.validate_local_bindings()

    def test_order_role_attempt_assignment_commands_project_and_policy(self):
        mutations = [
            lambda r: r.__setitem__("ordinal", 2),
            lambda r: r.__setitem__("role", "subject"),
            lambda r: r.__setitem__("attempt", 2),
            lambda r: r.__setitem__("assignment", "forged"),
            lambda r: r["rawReport"]["commands"].reverse(),
            lambda r: r["rawReport"]["commands"][1].__setitem__("path", "/tmp/forged"),
            lambda r: r["rawReport"]["commands"][1].__setitem__("fps", 60),
        ]
        for mutation in mutations:
            image = clone(self.images["native-opengl"]); identity = mutate_run(image, 1, mutation); self.assert_rejected(image, campaign_identity=identity)

    def test_endpoint_allocation_attribution_and_verdict_mutations(self):
        def replace(run, old, new): run["rawReport"]["stdout"] = run["rawReport"]["stdout"].replace(old, new, 1)
        mutations = [
            lambda r: replace(r, '"liveGenerations":0', '"liveGenerations":1'),
            lambda r: replace(r, '"live":0', '"live":1'),
            lambda r: r["rawReport"].__setitem__("stdout", r["rawReport"]["stdout"] + "STACK OF 1 INSTANCE OF FrescoScene:\n0 bad\n====\n"),
            lambda r: r.__setitem__("status", "invalid"),
        ]
        for mutation in mutations:
            image = clone(self.images["native-opengl"]); identity = mutate_run(image, 1, mutation); self.assert_rejected(image, campaign_identity=identity)

    def test_cross_backend_fixture_host_and_time_mutations(self):
        reports = verifier.verify_pair(self.images)
        native, angle = copy.deepcopy(reports["native-opengl"]), copy.deepcopy(reports["angle-metal"])
        for mutation, message in (
            (lambda: angle.__setitem__("host", {"architecture": "forged"}), "host"),
            (lambda: angle["fixtureIdentities"].__setitem__("subject-a/scene.pkg", {"sha256": "0" * 64, "bytes": 1}), "fixture"),
            (lambda: angle.__setitem__("acceptedMtime", native["acceptedMtime"] - 1), "chronology"),
        ):
            native, angle = copy.deepcopy(reports["native-opengl"]), copy.deepcopy(reports["angle-metal"])
            mutation()
            with mock.patch.object(verifier, "validate_local_bindings", return_value=self.local), mock.patch.object(verifier, "verify_image", side_effect=[native, angle]):
                with self.assertRaisesRegex(verifier.VerificationError, message): verifier.verify_pair(self.images)


if __name__ == "__main__":
    unittest.main()
