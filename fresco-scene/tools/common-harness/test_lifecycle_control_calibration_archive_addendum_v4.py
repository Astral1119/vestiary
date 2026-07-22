#!/usr/bin/env python3
import copy, pathlib, tempfile, unittest
import contract
import lifecycle_control_calibration_archive_verification_v4 as verify

class ArchiveAddendumV4Test(unittest.TestCase):
    root = pathlib.Path(__file__).parent
    archive = pathlib.Path("/Users/astral/personal/vestiary/.fresco-evidence/lifecycle-v3-calibration-attempt2/evidence.tar.gz")
    verifier = root / "lifecycle_control_calibration_archive_verification_v4.py"
    tests = root / "test_lifecycle_control_calibration_archive_verification_v4.py"
    predecessor = root / "workloads/resource-reload/lifecycle-control-calibration-verification-addendum-v3.json"
    addendum = contract.load_json(root / "workloads/resource-reload/lifecycle-control-calibration-archive-addendum-v4.json")

    def test_valid_and_verifier_sha_hostile(self):
        verify.verify_addendum(
            self.addendum, self.archive, self.predecessor,
            self.verifier, self.tests,
        )
        changed = copy.deepcopy(self.addendum)
        changed["verification"]["verifier"]["sha256"] = "0" * 64
        with self.assertRaises(verify.ArchiveVerificationError):
            verify.verify_addendum(
                changed, self.archive, self.predecessor,
                self.verifier, self.tests,
            )

    def test_repacked_archive_and_predecessor_drift_are_rejected(self):
        with tempfile.TemporaryDirectory() as value:
            root = pathlib.Path(value)
            repacked = root / "repacked.tar.gz"
            verify.rewrite_archive(
                self.archive, repacked, lambda files, directories: None
            )
            self.assertNotEqual(
                verify.file_identity(repacked), verify.file_identity(self.archive)
            )
            with self.assertRaises(verify.ArchiveVerificationError):
                verify.verify_addendum(
                    self.addendum, repacked, self.predecessor,
                    self.verifier, self.tests,
                )
            predecessor = root / "predecessor.json"
            predecessor.write_bytes(self.predecessor.read_bytes() + b"\n")
            with self.assertRaises(verify.ArchiveVerificationError):
                verify.verify_addendum(
                    self.addendum, self.archive, predecessor,
                    self.verifier, self.tests,
                )

if __name__ == "__main__": unittest.main()
