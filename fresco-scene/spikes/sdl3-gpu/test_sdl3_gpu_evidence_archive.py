#!/usr/bin/env python3

import copy
import io
import json
import pathlib
import tarfile
import tempfile
import unittest

import sdl3_gpu_evidence_archive as evidence


ARCHIVE = pathlib.Path("/Users/astral/personal/vestiary/.fresco-evidence/sdl3-gpu-static-render-foundation-v2/evidence.tar.gz")
ADDENDUM = pathlib.Path(__file__).with_name("evidence-addendum-v2.json")


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


class EvidenceArchiveTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files, _ = evidence.read_archive(ARCHIVE)

    def assert_rejected(self, mutate):
        files = copy.deepcopy(self.files)
        mutate(files)
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "mutated.tar.gz"
            path.write_bytes(rewrite(files))
            with self.assertRaises(evidence.VerificationError):
                evidence.verify_archive(path)

    def mutate_record(self, files, mutate):
        record = json.loads(files["record.json"])
        mutate(record)
        files["record.json"] = encode(record)

    def test_archive_only_verdict_and_checked_in_binding(self):
        result = evidence.validate_addendum(json.loads(ADDENDUM.read_text()), ARCHIVE)
        self.assertTrue(result["accepted"])
        self.assertEqual(result["frames"], 5)
        self.assertEqual(result["probes"], 8)

    def test_pixel_and_shader_drift_are_rejected(self):
        def pixel(files):
            name = next(name for name in files if name.startswith("artifacts/sha256/"))
            files[name] = files[name][:-1] + bytes([files[name][-1] ^ 1])
        self.assert_rejected(pixel)
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["shaders"]["sources"][0].update(sha256="0" * 64)))

    def test_source_and_build_drift_are_rejected(self):
        self.assert_rejected(lambda files: files.__setitem__("source-manifest.json", files["source-manifest.json"] + b" "))
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["build"].update(compiler="generic clang")))
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["build"]["commands"][0]["command"].remove("-DFRESCO_SCENE_BUILD_SDL3_GPU_SPIKE=ON")))

    def test_generator_cmake_build_type_deployment_and_cache_drift_are_rejected(self):
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["build"].update(generator="Ninja")))
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["build"]["cmakeTool"].update(version="cmake version 0.0.0")))
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["build"].update(buildType="Debug")))
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["build"]["deploymentTarget"].update(value="13.0")))
        self.assert_rejected(lambda files: files.__setitem__("build/CMakeCache.txt", files["build/CMakeCache.txt"].replace(b"CMAKE_GENERATOR:INTERNAL=Unix Makefiles", b"CMAKE_GENERATOR:INTERNAL=Ninja")))

    def test_probe_and_generation_order_drift_are_rejected(self):
        def probe(files):
            value = json.loads(files["raw/depth-probe.stdout"])
            value["support"]["depth32float"] = False
            files["raw/depth-probe.stdout"] = (json.dumps(value, separators=(",", ":")) + "\n").encode()
        self.assert_rejected(probe)
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["referenceGeneration"]["sequence"].reverse()))
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["referenceGeneration"]["probeOrder"].reverse()))

    def test_resize_and_lifecycle_drift_are_rejected(self):
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["runtime"]["lifecycle"].update(resizeRetirementsAfterCompletion=1)))
        self.assert_rejected(lambda files: self.mutate_record(files, lambda record: record["runtime"]["lifecycle"].update(fencesWaited=5)))

    def test_extra_link_and_duplicate_members_are_rejected(self):
        self.assert_rejected(lambda files: files.update({"unexpected": b"x"}))
        for kind in ("link", "duplicate"):
            with tempfile.TemporaryDirectory() as directory:
                path = pathlib.Path(directory) / f"{kind}.tar.gz"
                with tarfile.open(path, "w:gz") as archive:
                    info = tarfile.TarInfo("bad")
                    if kind == "link":
                        info.type = tarfile.SYMTYPE
                        info.linkname = "record.json"
                        archive.addfile(info)
                    else:
                        info.size = 1
                        archive.addfile(info, io.BytesIO(b"x"))
                        archive.addfile(info, io.BytesIO(b"x"))
                with self.assertRaises(evidence.VerificationError):
                    evidence.verify_archive(path)


if __name__ == "__main__":
    unittest.main()
