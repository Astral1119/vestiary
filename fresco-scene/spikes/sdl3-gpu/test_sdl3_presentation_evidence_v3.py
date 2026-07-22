#!/usr/bin/env python3

import argparse
import copy
import pathlib
import tempfile
import unittest

import sdl3_presentation_test_v3 as presentation


EXECUTABLE = None
REFERENCE_ROOT = None
SCHEDULER_FAULTS = (
    "early-wake", "stale-fps-after-retime", "pause-wake",
    "duplicate-uncoalesced", "altered-decision-timestamp",
    "missing-reason",
)


class PresentationEvidenceV3Test(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(
            prefix="fresco-sdl3-presentation-v3-hostile-")
        cls.output_root = pathlib.Path(cls.temporary.name) / "normative"
        cls.output_root.mkdir()
        cls.reference = presentation.load(
            pathlib.Path(__file__).with_name("presentation-reference-v2.json"))
        cls.record = presentation.run_json(EXECUTABLE, cls.output_root)
        presentation.validate_record(
            cls.record, cls.reference, REFERENCE_ROOT, cls.output_root)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def assert_rejected(self, mutate):
        value = copy.deepcopy(self.record)
        mutate(value)
        with self.assertRaises(presentation.PresentationError):
            presentation.validate_record(
                value, self.reference, REFERENCE_ROOT, self.output_root)

    def test_authorization_rejections_have_zero_gpu_delta(self):
        for probe in presentation.PROBES:
            with self.subTest(probe=probe):
                output = pathlib.Path(self.temporary.name) / probe
                output.mkdir()
                record = presentation.run_authorization_probe(
                    EXECUTABLE, output, probe)
                presentation.validate_authorization_probe(record, probe)

    def test_scheduler_fault_modes_are_rejected(self):
        for fault in SCHEDULER_FAULTS:
            with self.subTest(fault=fault):
                output = pathlib.Path(self.temporary.name) / fault
                output.mkdir()
                record = presentation.run_json(EXECUTABLE, output, fault)
                with self.assertRaises(presentation.PresentationError):
                    presentation.validate_record(
                        record, self.reference, REFERENCE_ROOT, output)

    def test_authorization_identity_completion_and_counter_drift_are_rejected(self):
        self.assert_rejected(
            lambda value: value.update(authorizationIdentity="caller-sequence"))
        self.assert_rejected(
            lambda value: value["workloads"][1]["scheduler"]["decisions"][12]["completion"].update(submissionOrdinal=12))
        self.assert_rejected(
            lambda value: value["workloads"][0]["lifecycle"].update(commandBuffersAcquired=4))

    def test_replay_driver_and_oracle_drift_are_rejected(self):
        self.assert_rejected(
            lambda value: value["workloads"][1]["scheduler"]["decisions"][12].update(semanticNanoseconds=800000001))
        self.assert_rejected(
            lambda value: value["workloads"][0]["window"].update(videoDriver="offscreen"))
        self.assert_rejected(
            lambda value: value.update(drawablePixelClaim=True))


def main():
    global EXECUTABLE, REFERENCE_ROOT
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", type=pathlib.Path, required=True)
    parser.add_argument("--reference-root", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    EXECUTABLE = arguments.executable
    REFERENCE_ROOT = arguments.reference_root
    result = unittest.TextTestRunner().run(
        unittest.defaultTestLoader.loadTestsFromTestCase(
            PresentationEvidenceV3Test))
    raise SystemExit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
