#!/usr/bin/env python3

import copy
import json
import pathlib
import tempfile
import unittest

import lifecycle_control_calibration_verification_v3 as verification


class CalibrationVerificationV3Test(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.wal = pathlib.Path("/private/var/tmp/fresco-calibration-attempt2-wal.0TKx2c")
        cls.store = pathlib.Path("/private/var/tmp/fresco-calibration-attempt2-store.3j9y5U")
        with open(cls.wal / "wal" / f"{verification.CAMPAIGN_ID}.json") as source:
            cls.campaign = json.load(source)

    def assert_rejected(self, mutate, *, store=None):
        campaign = copy.deepcopy(self.campaign)
        mutate(campaign)
        with self.assertRaises(verification.VerificationError):
            verification.validate(campaign, self.wal, store or self.store)

    def test_unchanged_campaign_rederives_and_revalidates(self):
        result = verification.validate(self.campaign, self.wal, self.store)
        self.assertEqual(result["slotCount"], 40)
        self.assertEqual(result["caps"]["maximumRawLeakBytes"], 18816)

    def test_unknown_subject_host_tool_and_helper_mutations_are_rejected(self):
        self.assert_rejected(lambda value: value.update(subject={"accepted": True}))
        self.assert_rejected(lambda value: value["host"].update(osBuild="forged"))
        self.assert_rejected(lambda value: value["tool"].update(version="report-8"))
        self.assert_rejected(
            lambda value: value["helpers"]["angle-metal"]["helper"].update(
                sha256="0" * 64
            )
        )

    def test_slot_status_protocol_static_control_and_caps_are_rederived(self):
        self.assert_rejected(lambda value: value["runs"][0].update(status="invalid"))
        self.assert_rejected(
            lambda value: value["runs"][0]["rawReport"]["commands"][1].update(
                path="/subject"
            )
        )
        self.assert_rejected(
            lambda value: value["runs"][0]["rawReport"]["commands"][0].update(
                assignmentID="retry"
            )
        )
        self.assert_rejected(
            lambda value: value["derivedTable"].update(maximumRawLeakBytes=1)
        )

    def test_raw_summary_unknown_mixed_and_forbidden_stacks_are_rejected(self):
        self.assert_rejected(
            lambda value: value["runs"][0]["rawReport"].update(
                stdout=value["runs"][0]["rawReport"]["stdout"].replace(
                    "total leaked bytes.", "total forged bytes."
                )
            )
        )
        self.assert_rejected(
            lambda value: value["runs"][0]["rawReport"].update(
                stdout=value["runs"][0]["rawReport"]["stdout"].replace(
                    "ROOT CYCLE: <NSXPCConnection>", "ROOT CYCLE: <Unknown>"
                )
            )
        )
        self.assert_rejected(
            lambda value: value["runs"][0]["rawReport"].update(
                stdout=value["runs"][0]["rawReport"]["stdout"].replace(
                    "ROOT CYCLE: <NSXPCConnection>",
                    "ROOT CYCLE: <AppIntents LinkServices>",
                )
            )
        )
        self.assert_rejected(
            lambda value: value["runs"][0]["rawReport"].update(
                stdout=value["runs"][0]["rawReport"]["stdout"].replace(
                    "com.apple.AppIntents", "com.apple.AppIntents FrescoScene"
                )
            )
        )

    def test_order_retry_receipt_wal_and_cas_mutations_are_rejected(self):
        self.assert_rejected(
            lambda value: value["runs"].__setitem__(
                slice(0, 2), list(reversed(value["runs"][:2]))
            )
        )
        self.assert_rejected(lambda value: value["runs"][0].update(attempt=2))
        self.assert_rejected(
            lambda value: value["runReceipts"][0].update(name="replacement")
        )
        self.assert_rejected(
            lambda value: value["runReceipts"][0].update(readbackSha256="0" * 64)
        )
        with tempfile.TemporaryDirectory() as empty:
            self.assert_rejected(lambda value: None, store=pathlib.Path(empty))


if __name__ == "__main__":
    unittest.main()
