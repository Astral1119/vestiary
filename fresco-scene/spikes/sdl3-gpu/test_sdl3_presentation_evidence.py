#!/usr/bin/env python3

import argparse
import copy
import pathlib
import tempfile
import unittest

import sdl3_presentation_test as presentation


EXECUTABLE = None
REFERENCE_ROOT = None


class PresentationEvidenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="fresco-sdl3-presentation-hostile-")
        cls.output_root = pathlib.Path(cls.temporary.name)
        cls.reference = presentation.load(pathlib.Path(__file__).with_name("presentation-reference-v1.json"))
        cls.record = presentation.run_json(EXECUTABLE, cls.output_root)
        presentation.validate_record(cls.record, cls.reference, REFERENCE_ROOT, cls.output_root)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def assert_rejected(self, mutate):
        value = copy.deepcopy(self.record)
        mutate(value)
        with self.assertRaises(presentation.PresentationError):
            presentation.validate_record(value, self.reference, REFERENCE_ROOT, self.output_root)

    def test_static_quiescence_property_and_resize_drift_are_rejected(self):
        self.assert_rejected(lambda value: value["workloads"][0]["intervals"]["initialQuiescence"].update(submissions=1))
        self.assert_rejected(lambda value: value["workloads"][0]["propertyDelta"].update(presents=2))
        self.assert_rejected(lambda value: value["workloads"][0]["resize"].update(submissionWidth=640))

    def test_swapchain_and_teardown_drift_are_rejected(self):
        self.assert_rejected(lambda value: value["workloads"][0]["window"].update(selectedPresentMode="immediate"))
        self.assert_rejected(lambda value: value["workloads"][1]["lifecycle"].update(windowsReleased=0))

    def test_cadence_deadline_pause_and_present_drift_are_rejected(self):
        self.assert_rejected(lambda value: value["workloads"][1]["phases"][0].update(frames=13))
        self.assert_rejected(lambda value: value["workloads"][1]["events"][12].update(semanticNanoseconds=800000001))
        self.assert_rejected(lambda value: value["workloads"][1]["pause"].update(schedulerDecisions=1))
        self.assert_rejected(lambda value: value["workloads"][1]["lifecycle"].update(presents=77))

    def test_semantic_wall_boundary_and_pixel_drift_are_rejected(self):
        self.assert_rejected(lambda value: value.update(performanceClaim=True))
        path = self.output_root / "static-constructor.bgra"
        original = path.read_bytes()
        try:
            path.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
            with self.assertRaises(presentation.PresentationError):
                presentation.validate_record(self.record, self.reference, REFERENCE_ROOT, self.output_root)
        finally:
            path.write_bytes(original)


def main():
    global EXECUTABLE, REFERENCE_ROOT
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", type=pathlib.Path, required=True)
    parser.add_argument("--reference-root", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    EXECUTABLE = arguments.executable
    REFERENCE_ROOT = arguments.reference_root
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PresentationEvidenceTest)
    result = unittest.TextTestRunner().run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
