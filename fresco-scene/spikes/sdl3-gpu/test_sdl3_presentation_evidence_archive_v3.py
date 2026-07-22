#!/usr/bin/env python3

import copy
import hashlib
import io
import json
import pathlib
import tarfile
import tempfile
import unittest

import sdl3_presentation_evidence_archive_v3 as evidence


ARCHIVE = pathlib.Path("/Users/astral/personal/vestiary/.fresco-evidence/sdl3-presentation-scheduling-v3/evidence.tar.gz")
ADDENDUM = pathlib.Path(__file__).with_name(
    "presentation-evidence-addendum-v3.json")


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


class PresentationArchiveV3Test(unittest.TestCase):
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

    def mutate_probe(self, files, probe_name, mutate):
        record = json.loads(files["record.json"])
        probe = next(item for item in record["authorizationEvidence"]
                     if item["probe"] == probe_name)
        mutate(probe["record"])
        raw = (json.dumps(probe["record"], separators=(",", ":")) + "\n").encode()
        raw_path = probe["raw"]["stdout"]["path"]
        files[raw_path] = raw
        probe["raw"]["stdout"].update(
            sha256=hashlib.sha256(raw).hexdigest(), bytes=len(raw))
        files["record.json"] = encode(record)

    def test_archive_binding_and_actual_three_archive_lineage(self):
        result = evidence.validate_addendum(
            json.loads(ADDENDUM.read_text()), ARCHIVE)
        self.assertTrue(result["accepted"])

    def test_lineage_source_and_build_drift(self):
        self.assert_rejected(lambda files: self.mutate_record(
            files, lambda record: record["lineage"]["presentationV2"].update(bytes=0)))
        self.assert_rejected(lambda files: files.__setitem__(
            "source-manifest.json", files["source-manifest.json"] + b" "))
        self.assert_rejected(lambda files: self.mutate_record(
            files, lambda record: record["build"].update(generator="Ninja")))

    def test_probe_rejection_and_zero_delta_drift(self):
        self.assert_rejected(lambda files: self.mutate_probe(
            files, "forged-999", lambda probe: probe.update(rejected=False)))
        self.assert_rejected(lambda files: self.mutate_probe(
            files, "duplicate-current", lambda probe:
            probe["after"].update(commandBuffersAcquired=1)))
        self.assert_rejected(lambda files: self.mutate_probe(
            files, "already-completed", lambda probe:
            probe.update(gpuCountersUnchanged=False)))

    def test_authorization_runtime_and_scheduler_drift(self):
        self.assert_rejected(lambda files: self.mutate_record(
            files, lambda record:
            record["schedulerEvidence"].update(authorization="caller-owned")))
        self.assert_rejected(lambda files: self.mutate_record(
            files, lambda record:
            record["verdict"].update(oneShotAuthorization=False)))

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
