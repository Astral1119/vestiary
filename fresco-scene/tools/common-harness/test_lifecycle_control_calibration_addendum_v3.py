#!/usr/bin/env python3

import copy
import pathlib
import unittest

import contract
import lifecycle_control_calibration_verification_v3 as verification


class CalibrationAddendumV3Test(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.archive = pathlib.Path(
            "/Users/astral/personal/vestiary/.fresco-evidence/"
            "lifecycle-v3-calibration-attempt2/evidence.tar.gz"
        )
        cls.addendum = contract.load_json(
            pathlib.Path(__file__).with_name("workloads")
            / "resource-reload"
            / "lifecycle-control-calibration-verification-addendum-v3.json"
        )

    def assert_rejected(self, mutate, archive=None):
        value = copy.deepcopy(self.addendum)
        mutate(value)
        with self.assertRaises(verification.VerificationError):
            verification.validate_addendum(value, archive or self.archive)

    def test_addendum_binds_durable_archive_and_verdict(self):
        verification.validate_addendum(self.addendum, self.archive)

    def test_unknown_subject_archive_verdict_and_caps_mutations_are_rejected(self):
        self.assert_rejected(lambda value: value.update(subject={}))
        self.assert_rejected(lambda value: value["archive"].update(sha256="0" * 64))
        self.assert_rejected(lambda value: value["verdict"].update(subjectDataPresent=True))
        self.assert_rejected(lambda value: value["derivedTable"].update(maximumRawLeakBytes=1))
        self.assert_rejected(lambda value: None, archive=pathlib.Path("/missing/archive"))


if __name__ == "__main__":
    unittest.main()
