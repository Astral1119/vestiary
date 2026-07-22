#!/usr/bin/env python3

import argparse
import copy
import pathlib
import tempfile
import unittest

import sdl3_presentation_test_v2 as presentation


EXECUTABLE = None
REFERENCE_ROOT = None
FAULTS = (
    "early-wake",
    "stale-fps-after-retime",
    "pause-wake",
    "duplicate-uncoalesced",
    "altered-decision-timestamp",
    "missing-reason",
    "presentation-without-decision",
)


class PresentationEvidenceV2Test(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="fresco-sdl3-presentation-v2-hostile-")
        cls.output_root = pathlib.Path(cls.temporary.name) / "normative"
        cls.output_root.mkdir()
        cls.reference = presentation.load(pathlib.Path(__file__).with_name("presentation-reference-v2.json"))
        cls.record = presentation.run_json(EXECUTABLE, cls.output_root)
        presentation.validate_record(cls.record, cls.reference, REFERENCE_ROOT, cls.output_root)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def assert_rejected(self, mutate):
        record = copy.deepcopy(self.record)
        mutate(record)
        with self.assertRaises(presentation.PresentationError):
            presentation.validate_record(record, self.reference, REFERENCE_ROOT, self.output_root)

    def test_runtime_scheduler_fault_modes_are_rejected(self):
        for fault in FAULTS:
            with self.subTest(fault=fault):
                output_root = pathlib.Path(self.temporary.name) / fault
                output_root.mkdir()
                record = presentation.run_json(EXECUTABLE, output_root, fault)
                with self.assertRaises(presentation.PresentationError):
                    presentation.validate_record(record, self.reference, REFERENCE_ROOT, output_root)

    def test_input_wake_and_decision_timestamp_drift_are_rejected(self):
        self.assert_rejected(lambda value: value["workloads"][1]["scheduler"]["inputEvents"][2].update(nextWakeAfterNanoseconds=800000001))
        self.assert_rejected(lambda value: value["workloads"][1]["scheduler"]["decisions"][12].update(semanticNanoseconds=800000001))

    def test_reason_completion_and_unbacked_present_drift_are_rejected(self):
        self.assert_rejected(lambda value: value["workloads"][1]["scheduler"]["decisions"][12].update(reasons=["continuous-lease"]))
        self.assert_rejected(lambda value: value["workloads"][1]["scheduler"]["decisions"][12]["completion"].update(submissionOrdinal=12))
        self.assert_rejected(lambda value: value["workloads"][0]["lifecycle"].update(presents=4))

    def test_pause_retime_and_duplicate_decision_drift_are_rejected(self):
        self.assert_rejected(lambda value: value["workloads"][1]["scheduler"]["inputEvents"][7].update(nextWakeAfterNanoseconds=1866666666))
        self.assert_rejected(lambda value: value["workloads"][1]["scheduler"]["decisions"][12].update(fpsCeiling=15))
        self.assert_rejected(lambda value: value["workloads"][1]["scheduler"]["decisions"].insert(13, copy.deepcopy(value["workloads"][1]["scheduler"]["decisions"][12])))

    def test_driver_oracle_and_claim_boundary_drift_are_rejected(self):
        self.assert_rejected(lambda value: value["workloads"][0]["window"].update(videoDriver="offscreen"))
        self.assert_rejected(lambda value: value["workloads"][0]["window"].update(gpuDriver="vulkan"))
        self.assert_rejected(lambda value: value.update(drawablePixelClaim=True))
        self.assert_rejected(lambda value: value["workloads"][0]["outputs"][0].update(evidenceRole="drawable-readback"))


def main():
    global EXECUTABLE, REFERENCE_ROOT
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", type=pathlib.Path, required=True)
    parser.add_argument("--reference-root", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    EXECUTABLE = arguments.executable
    REFERENCE_ROOT = arguments.reference_root
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PresentationEvidenceV2Test)
    result = unittest.TextTestRunner().run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
