#!/usr/bin/env python3

import copy
import hashlib
import io
import json
import pathlib
import tarfile
import tempfile
import unittest

import sdl3_presentation_evidence_archive_v2 as evidence


ARCHIVE = pathlib.Path("/Users/astral/personal/vestiary/.fresco-evidence/sdl3-presentation-scheduling-v2/evidence.tar.gz")
ADDENDUM = pathlib.Path(__file__).with_name("presentation-evidence-addendum-v2.json")


def encode(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def rewrite(files):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        for name, value in sorted(files.items()):
            info = tarfile.TarInfo(name)
            info.size = len(value)
            archive.addfile(info, io.BytesIO(value))
    return output.getvalue()


class PresentationArchiveV2Test(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files, _ = evidence.read_archive(ARCHIVE)

    def assert_rejected(self, mutate):
        files = copy.deepcopy(self.files)
        mutate(files)
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "mutated.tar.gz"
            path.write_bytes(rewrite(files))
            with self.assertRaises(evidence.ArchiveError):
                evidence.verify_archive(path)

    def mutate_record(self, files, mutate):
        record = json.loads(files["record.json"])
        mutate(record)
        files["record.json"] = encode(record)

    def mutate_runtime(self, files, mutate):
        record = json.loads(files["record.json"])
        raw_path = record["runtime"]["raw"]["stdout"]["path"]
        runtime = json.loads(files[raw_path])
        mutate(runtime)
        raw = (json.dumps(runtime, separators=(",", ":")) + "\n").encode()
        files[raw_path] = raw
        record["runtime"]["record"] = runtime
        record["runtime"]["raw"]["stdout"].update(
            sha256=hashlib.sha256(raw).hexdigest(), bytes=len(raw)
        )
        files["record.json"] = encode(record)

    def test_archive_binding_and_actual_lineage(self):
        result = evidence.validate_addendum(json.loads(ADDENDUM.read_text()), ARCHIVE)
        self.assertTrue(result["accepted"])

    def test_lineage_source_contract_build_and_oracle_drift(self):
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["lineage"]["foundation"].update(sha256="0" * 64)))
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["lineage"]["presentationPredecessor"].update(bytes=0)))
        self.assert_rejected(lambda files: files.__setitem__("source-manifest.json", files["source-manifest.json"] + b" "))
        self.assert_rejected(lambda files: files.__setitem__("contracts/continuous-animation/trace-v1.json", files["contracts/continuous-animation/trace-v1.json"] + b" "))
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["build"].update(generator="Ninja")))
        def oracle(files):
            name = next(name for name in files if name.startswith("artifacts/sha256/"))
            files[name] = files[name][:-1] + bytes([files[name][-1] ^ 1])
        self.assert_rejected(oracle)

    def test_scheduler_input_deadline_reason_and_completion_drift(self):
        self.assert_rejected(lambda files: self.mutate_runtime(files, lambda runtime: runtime["workloads"][1]["scheduler"]["inputEvents"][2].update(nextWakeAfterNanoseconds=800000001)))
        self.assert_rejected(lambda files: self.mutate_runtime(files, lambda runtime: runtime["workloads"][1]["scheduler"]["decisions"][12].update(semanticNanoseconds=800000001)))
        self.assert_rejected(lambda files: self.mutate_runtime(files, lambda runtime: runtime["workloads"][1]["scheduler"]["decisions"][12].update(reasons=["continuous-lease"])))
        self.assert_rejected(lambda files: self.mutate_runtime(files, lambda runtime: runtime["workloads"][1]["scheduler"]["decisions"][12]["completion"].update(submissionOrdinal=12)))

    def test_pause_driver_lifecycle_and_oracle_boundary_drift(self):
        self.assert_rejected(lambda files: self.mutate_runtime(files, lambda runtime: runtime["workloads"][1]["scheduler"]["inputEvents"][7].update(nextWakeAfterNanoseconds=1866666666)))
        self.assert_rejected(lambda files: self.mutate_runtime(files, lambda runtime: runtime["workloads"][0]["window"].update(videoDriver="offscreen")))
        self.assert_rejected(lambda files: self.mutate_runtime(files, lambda runtime: runtime["workloads"][1]["lifecycle"].update(presents=79)))
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["oracleBoundary"].update(drawablePixelClaim=True)))

    def test_unsafe_and_extra_members(self):
        self.assert_rejected(lambda files: files.update({"unexpected": b"x"}))
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "link.tar.gz"
            with tarfile.open(path, "w:gz") as archive:
                info = tarfile.TarInfo("link")
                info.type = tarfile.SYMTYPE
                info.linkname = "record.json"
                archive.addfile(info)
            with self.assertRaises(evidence.ArchiveError):
                evidence.verify_archive(path)


if __name__ == "__main__":
    unittest.main()
