#!/usr/bin/env python3

import copy
import hashlib
import pathlib
import shutil
import tempfile
import unittest

import contract
import lifecycle_control_calibration as base
import lifecycle_control_calibration_attempt2 as attempt2


class CalibrationAttempt2Test(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = pathlib.Path(__file__).with_name("workloads") / "resource-reload"
        cls.plan = contract.load_json(
            root / "lifecycle-control-calibration-plan-v3-attempt2.json"
        )
        attempt2.validate_plan(cls.plan)

    def setUp(self):
        self.root = pathlib.Path(
            tempfile.mkdtemp(prefix="calibration-attempt2-test.", dir="/private/var/tmp")
        ).resolve()

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_production_path_smoke_fsync_ingest_and_readback(self):
        result = attempt2.run_preflight(self.root / "smoke", self.root / "store")
        receipt = result["receipt"]
        self.assertEqual(receipt["walSha256"], receipt["readbackSha256"])
        self.assertEqual(receipt["walBytes"], receipt["readbackBytes"])
        self.assertTrue((self.root / "store" / receipt["casPath"]).is_file())

    def test_wal_and_receipt_bind_exact_canonical_record(self):
        value = {"identity": "slot", "raw": {"stdout": "complete", "stderr": ""}}
        _artifact, receipt = attempt2._persist_record(
            value, "slot-001", self.root / "wal", self.root / "receipts",
            self.root / "store",
        )
        payload = contract.canonical_json_bytes(value)
        self.assertEqual(receipt["walSha256"], hashlib.sha256(payload).hexdigest())
        self.assertEqual(receipt["walBytes"], len(payload))
        self.assertTrue((self.root / "receipts" / "slot-001.receipt.json").is_file())

    def test_ledger_requires_failure_and_excluded_smoke(self):
        freeze = {"identity": "freeze"}
        digest = hashlib.sha256(contract.canonical_json_bytes(freeze)).hexdigest()
        failure = {
            "entryType": "campaign-failure", "attempt": 1,
            "completedChildSlots": 40, "storeState": "empty",
            "retention": {
                "rawTotals": False, "rawOutputs": False,
                "runRecords": False, "derivedCaps": False,
            },
        }
        smoke = {
            "entryType": "publication-smoke",
            "campaignIdentity": attempt2.CAMPAIGN_ID,
            "excludedFromCalibration": True,
            "freezeSha256": digest,
            "status": "passed",
        }
        attempt2.validate_ledger([failure, smoke], freeze)
        for entries in ([failure], [smoke, failure], [failure, {**smoke, "excludedFromCalibration": False}]):
            with self.subTest(entries=entries):
                with self.assertRaises(base.CalibrationError):
                    attempt2.validate_ledger(entries, freeze)

    def test_partial_campaign_cannot_publish_caps_or_pass_complete_validation(self):
        run = {"ordinal": 1, "backend": "angle-metal", "attempt": 1}
        payload = contract.canonical_json_bytes(run)
        wal = self.root / "slot.json"
        attempt2._atomic_json(wal, run)
        (self.root / "store").mkdir()
        artifact = contract.ingest_artifact(
            wal, self.root / "store", "slot", "application/json"
        )
        receipt = {
            "ordinal": 1, "backend": "angle-metal",
            "walSha256": hashlib.sha256(payload).hexdigest(),
            "walBytes": len(payload), "casPath": artifact["path"],
        }
        freeze = {"plan": {"sha256": "a" * 64, "bytes": 1}, "schema": {"sha256": "b" * 64, "bytes": 1}}
        ledger = {"sha256": "c" * 64, "bytes": 1}
        campaign = {
            "identity": attempt2.CAMPAIGN_ID, "attempt": 2,
            "plan": freeze["plan"], "schema": freeze["schema"],
            "ledger": ledger, "frozenOrder": self.plan["frozenOrder"],
            "runs": [run], "runReceipts": [receipt],
            "campaignStatus": "invalid", "invalidRuns": [1],
            "derivedTable": None,
        }
        attempt2.validate_campaign(
            campaign, self.plan, freeze, ledger, self.root / "store",
            require_complete=False,
        )
        with self.assertRaises(base.CalibrationError):
            attempt2.validate_campaign(
                campaign, self.plan, freeze, ledger, self.root / "store"
            )
        forged = copy.deepcopy(campaign)
        forged["derivedTable"] = {"maximumRawLeakObjects": 1}
        with self.assertRaises(base.CalibrationError):
            attempt2.validate_campaign(
                forged, self.plan, freeze, ledger, self.root / "store",
                require_complete=False,
            )

    def test_missing_receipt_and_retry_are_rejected(self):
        campaign = {
            "identity": attempt2.CAMPAIGN_ID, "attempt": 2,
            "plan": {"sha256": "a" * 64, "bytes": 1},
            "schema": {"sha256": "b" * 64, "bytes": 1},
            "ledger": {"sha256": "c" * 64, "bytes": 1},
            "frozenOrder": self.plan["frozenOrder"],
            "runs": [{"ordinal": 1, "backend": "angle-metal", "attempt": 2}],
            "runReceipts": [], "campaignStatus": "invalid",
            "invalidRuns": [1], "derivedTable": None,
        }
        freeze = {"plan": campaign["plan"], "schema": campaign["schema"]}
        with self.assertRaises(base.CalibrationError):
            attempt2.validate_campaign(
                campaign, self.plan, freeze, campaign["ledger"], self.root,
                require_complete=False,
            )


if __name__ == "__main__":
    unittest.main()
