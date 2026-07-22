#!/usr/bin/env python3

import io
import json
import pathlib
import tarfile
import tempfile
import unittest

import lifecycle_control_calibration_archive_verification_v4 as verify


class ArchiveVerificationV4Test(unittest.TestCase):
    archive = pathlib.Path("/Users/astral/personal/vestiary/.fresco-evidence/lifecycle-v3-calibration-attempt2/evidence.tar.gz")

    def mutated(self, mutation):
        temporary = tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False)
        temporary.close(); target = pathlib.Path(temporary.name)
        verify.rewrite_archive(self.archive, target, mutation)
        self.addCleanup(target.unlink)
        return target

    def test_archive_only_verification(self):
        self.assertEqual(verify.verify_archive(self.archive)["files"], 127)

    def test_missing_extra_receipt_cas_subject_and_raw_mutations(self):
        mutations = [
            lambda files, dirs: files.pop(next(name for name in files if name.startswith("wal/calibration-attempt-2-slot"))),
            lambda files, dirs: files.update({"extra": b"x"}),
            lambda files, dirs: files.__setitem__(next(name for name in files if name.startswith("receipts/calibration")), b"{}"),
            lambda files, dirs: files.__setitem__(next(name for name in files if name.startswith("artifacts/") and len(files[name]) < 1000000), b"changed"),
        ]
        def subject(files, dirs):
            name = f"wal/{verify.CAMPAIGN}.json"; value = json.loads(files[name]); value["subject"] = {}; files[name] = json.dumps(value).encode()
        def raw(files, dirs):
            name = next(name for name in files if name.startswith("wal/calibration-attempt-2-slot")); files[name] = files[name].replace(b"NSXPCConnection", b"UnknownFramework", 1)
        mutations += [subject, raw]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                with self.assertRaises(verify.ArchiveVerificationError):
                    verify.verify_archive(self.mutated(mutation))

    def test_unsafe_absolute_duplicate_and_link_members_are_rejected(self):
        for kind in ("absolute", "duplicate", "link"):
            with self.subTest(kind=kind):
                temporary = tempfile.NamedTemporaryFile(suffix=".tar.gz", delete=False); temporary.close(); path = pathlib.Path(temporary.name); self.addCleanup(path.unlink)
                with tarfile.open(path, "w:gz") as archive:
                    name = "/absolute" if kind == "absolute" else "duplicate"
                    info = tarfile.TarInfo(name)
                    if kind == "link": info.name = "link"; info.type = tarfile.SYMTYPE; info.linkname = "target"; archive.addfile(info)
                    else:
                        info.size = 1; archive.addfile(info, io.BytesIO(b"x"))
                        if kind == "duplicate": archive.addfile(info, io.BytesIO(b"x"))
                with self.assertRaises(verify.ArchiveVerificationError): verify.verify_archive(path)


if __name__ == "__main__": unittest.main()
