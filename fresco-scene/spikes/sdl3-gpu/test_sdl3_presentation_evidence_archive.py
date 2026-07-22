#!/usr/bin/env python3

import copy
import hashlib
import io
import json
import pathlib
import tarfile
import tempfile
import unittest

import sdl3_presentation_evidence_archive as evidence


ARCHIVE = pathlib.Path("/Users/astral/personal/vestiary/.fresco-evidence/sdl3-presentation-scheduling-v1/evidence.tar.gz")
ADDENDUM = pathlib.Path(__file__).with_name("presentation-evidence-addendum-v1.json")


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


class PresentationArchiveTest(unittest.TestCase):
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

    def test_archive_binding(self):
        result = evidence.validate_addendum(json.loads(ADDENDUM.read_text()), ARCHIVE)
        self.assertTrue(result["accepted"])

    def test_pixel_source_contract_and_build_drift(self):
        def pixel(files):
            name = next(name for name in files if name.startswith("artifacts/sha256/"))
            files[name] = files[name][:-1] + bytes([files[name][-1] ^ 1])
        self.assert_rejected(pixel)
        self.assert_rejected(lambda files: files.__setitem__("source-manifest.json", files["source-manifest.json"] + b" "))
        self.assert_rejected(lambda files: files.__setitem__("contracts/static-no-media/trace-v1.json", files["contracts/static-no-media/trace-v1.json"] + b" "))
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["build"].update(generator="Ninja")))
        self.assert_rejected(lambda files: files.__setitem__("build/CMakeCache.txt", files["build/CMakeCache.txt"].replace(b"CMAKE_BUILD_TYPE:STRING=Release", b"CMAKE_BUILD_TYPE:STRING=Debug")))

    def test_static_swapchain_quiescence_resize_and_lifecycle_drift(self):
        self.assert_rejected(lambda files: self.mutate_runtime(files, lambda runtime: runtime["workloads"][0]["window"].update(selectedPresentMode="immediate")))
        self.assert_rejected(lambda files: self.mutate_runtime(files, lambda runtime: runtime["workloads"][0]["intervals"]["initialQuiescence"].update(presents=1)))
        self.assert_rejected(lambda files: self.mutate_runtime(files, lambda runtime: runtime["workloads"][0]["resize"].update(submissionWidth=640)))
        self.assert_rejected(lambda files: self.mutate_runtime(files, lambda runtime: runtime["workloads"][0]["lifecycle"].update(texturesReleased=1)))

    def test_continuous_cadence_pause_order_and_present_drift(self):
        self.assert_rejected(lambda files: self.mutate_runtime(files, lambda runtime: runtime["workloads"][1]["phases"][0].update(frames=13)))
        self.assert_rejected(lambda files: self.mutate_runtime(files, lambda runtime: runtime["workloads"][1]["pause"].update(schedulerDecisions=1)))
        self.assert_rejected(lambda files: self.mutate_runtime(files, lambda runtime: runtime["workloads"][1]["events"][12].update(semanticNanoseconds=800000001)))
        self.assert_rejected(lambda files: self.mutate_runtime(files, lambda runtime: runtime["workloads"][1]["lifecycle"].update(presents=77)))

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
