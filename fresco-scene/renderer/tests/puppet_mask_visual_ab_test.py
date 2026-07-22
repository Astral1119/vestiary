#!/usr/bin/env python3

import hashlib
import json
import os
import pathlib
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import time


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = pathlib.Path(os.path.abspath(sys.argv[2]))
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
HYUGA = WORKSHOP / "3479521040"
GBC = WORKSHOP / "3448290956"
HYUGA_SHA256 = "c8e35f0ad9b49f882eda411fb0feada0fb1059fa7bb058db79271cae794cf147"
GBC_SHA256 = "4bac6871f95380c374653c44a903538cfa841a8d17abe310a092543dd9ac6ac1"


class Reader:
    def __init__(self, data):
        self.data = data
        self.position = 0

    def take(self, length):
        start = self.position
        self.position += length
        assert self.position <= len(self.data), (start, length, len(self.data))
        return self.data[start : self.position]

    def u8(self):
        return self.take(1)[0]

    def u16(self):
        return struct.unpack("<H", self.take(2))[0]

    def u32(self):
        return struct.unpack("<I", self.take(4))[0]

    def cstring(self):
        end = self.data.index(0, self.position)
        value = self.data[self.position:end]
        self.position = end + 1
        return value


def read_string(handle):
    return handle.read(struct.unpack("<I", handle.read(4))[0]).decode("utf-8")


def encode_string(value):
    encoded = value.encode("utf-8")
    return struct.pack("<I", len(encoded)) + encoded


def read_package(path):
    with path.open("rb") as handle:
        revision = read_string(handle)
        entries = [
            (read_string(handle), *struct.unpack("<II", handle.read(8)))
            for _ in range(struct.unpack("<I", handle.read(4))[0])
        ]
        base = handle.tell()
        payloads = []
        for name, offset, length in entries:
            handle.seek(base + offset)
            payloads.append((name, handle.read(length)))
    return revision, payloads


def write_package(path, revision, payloads):
    offset = 0
    entries = []
    for name, payload in payloads:
        entries.append((name, offset, len(payload)))
        offset += len(payload)
    with path.open("wb") as handle:
        handle.write(encode_string(revision))
        handle.write(struct.pack("<I", len(entries)))
        for name, entry_offset, length in entries:
            handle.write(encode_string(name))
            handle.write(struct.pack("<II", entry_offset, length))
        for _, payload in payloads:
            handle.write(payload)


def mask_count_offset(data):
    reader = Reader(data)
    assert reader.take(9) == b"MDLV0023\x00"
    reader.u32()
    assert reader.u32() == 1 and reader.u32() == 1
    reader.cstring()
    if reader.u32() == 2:
        reader.u32()
    reader.take(6 * 4)
    reader.u32()
    vertex_bytes = reader.u32()
    reader.take(vertex_bytes)
    index_bytes = reader.u32()
    reader.take(index_bytes)
    part_extras = reader.u8()
    assert part_extras in (0, 1), part_extras
    if part_extras == 1 and reader.u8() != 0:
        assert reader.u16() == 0
        reader.u8()
        reader.take(reader.u32())
    if reader.u8() != 0:
        part_bytes = reader.u32()
        assert part_bytes % 16 == 0, part_bytes
        reader.take(part_bytes)
    return reader.position


def model_mask_counts(payloads):
    result = {}
    for name, payload in payloads:
        if not name.endswith(".mdl"):
            continue
        offset = mask_count_offset(payload)
        result[name] = struct.unpack_from("<I", payload, offset)[0]
    return result


def without_model_masks(payloads):
    changed = []
    removed = 0
    for name, payload in payloads:
        if not name.endswith(".mdl"):
            changed.append((name, payload))
            continue
        mutable = bytearray(payload)
        offset = mask_count_offset(mutable)
        count = struct.unpack_from("<I", mutable, offset)[0]
        removed += count
        struct.pack_into("<I", mutable, offset, 0)
        changed.append((name, bytes(mutable)))
    assert removed == 2, removed
    return changed


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def environment():
    result = os.environ.copy()
    result["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    result["FRESCO_SCENE_SCRIPT_CLOCK_HOUR"] = "9"
    return result


def message(kind, assignment, **values):
    return {
        "protocolVersion": 1,
        "type": kind,
        "assignmentID": assignment,
        **values,
    }


class Helper:
    def __init__(self, assignment):
        self.assignment = assignment
        self.process = subprocess.Popen(
            [HELPER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=environment(),
        )

    def exchange(self, kind, expected=None, timeout=90, **values):
        self.process.stdin.write(
            json.dumps(message(kind, self.assignment, **values)) + "\n"
        )
        self.process.stdin.flush()
        readable, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not readable:
            raise AssertionError((kind, "timed out", self.process.stderr.read()))
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError((kind, self.process.stderr.read()))
        event = json.loads(line)
        assert event["type"] == (expected or kind), event
        assert event["assignmentID"] == self.assignment, event
        return event

    def load(self, project):
        return self.exchange(
            "load",
            "ready",
            path=str(project),
            assetRoot=ASSETS,
            width=320,
            height=180,
            visible=True,
            muted=True,
            evidenceFrames=3,
            userProperties={"newproperty1": {"value": False}},
        )

    def evidence(self):
        return self.exchange("capture-puppet-evidence", "puppet-evidence")

    def stop(self):
        self.exchange("stop", "stopped")
        self.process.stdin.close()
        self.process.wait(timeout=10)
        assert self.process.returncode == 0, self.process.returncode
        assert not self.process.stderr.read(), self.process.stderr.read()

    def kill(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.communicate(timeout=10)


def assert_puppet_boundary(evidence, expected_masks, expected_mask_passes):
    assert evidence["loadedMeshes"] == 2, evidence
    assert evidence["loadedVertices"] == 790, evidence
    assert evidence["loadedMasks"] == expected_masks, evidence
    assert evidence["loadedAttachments"] == 0, evidence
    assert evidence["maskPasses"] == expected_mask_passes, evidence


def run_case(project, label, expected_masks):
    helper = Helper(f"puppet-mask-ab-{label}")
    try:
        ready = helper.load(project)
        assert ready["backend"] == "native-opengl" == EXPECTED_BACKEND, ready
        assert ready["drawComplete"] is True, ready
        assert ready["range"][0] < ready["range"][1], ready
        initial = helper.evidence()
        initial_mask_passes = initial["maskPasses"]
        if expected_masks == 0:
            assert initial_mask_passes == 0, initial
        else:
            assert initial_mask_passes > 0, initial
        assert_puppet_boundary(initial, expected_masks, initial_mask_passes)

        helper.exchange("pause", "paused")
        paused = helper.evidence()
        time.sleep(0.20)
        assert helper.evidence() == paused
        helper.exchange("resume", "resumed")
        difference = helper.exchange(
            "capture-frame-difference", "frame-difference"
        )
        assert difference["drawComplete"] is True, difference
        resumed = helper.evidence()
        assert resumed["deformationUploads"] > paused["deformationUploads"], resumed
        if expected_masks == 0:
            assert resumed["maskPasses"] == 0, resumed
        else:
            assert resumed["maskPasses"] > paused["maskPasses"], resumed

        reloaded = helper.load(project)
        assert reloaded["backend"] == "native-opengl", reloaded
        reload_evidence = helper.evidence()
        assert_puppet_boundary(
            reload_evidence, expected_masks, initial_mask_passes
        )
        helper.stop()
        return {
            "pixelRGBTotal": ready["pixelRGBTotal"],
            "pixelRGBAHash": ready["pixelRGBAHash"],
            "maskPasses": initial_mask_passes,
        }
    finally:
        helper.kill()


if EXPECTED_BACKEND != "native-opengl":
    raise SystemExit("puppet mask visual A/B requires native-opengl")
for project, expected_hash in ((HYUGA, HYUGA_SHA256), (GBC, GBC_SHA256)):
    package = project / "scene.pkg"
    if not package.is_file():
        raise SystemExit(f"puppet mask fixture missing: {project}")
    assert digest(package) == expected_hash, (project, digest(package))

hyuga_revision, hyuga_payloads = read_package(HYUGA / "scene.pkg")
hyuga_masks = model_mask_counts(hyuga_payloads)
assert sorted(hyuga_masks.values()) == [0, 2], hyuga_masks
_, gbc_payloads = read_package(GBC / "scene.pkg")
assert sum(model_mask_counts(gbc_payloads).values()) == 0

with tempfile.TemporaryDirectory(prefix="fresco-puppet-mask-ab-") as directory:
    unmasked = pathlib.Path(directory) / "hyuga-unmasked"
    unmasked.mkdir()
    shutil.copy2(HYUGA / "project.json", unmasked / "project.json")
    write_package(
        unmasked / "scene.pkg",
        hyuga_revision,
        without_model_masks(hyuga_payloads),
    )

    normal = [run_case(HYUGA, f"normal-{index}", 2) for index in range(2)]
    disabled = [run_case(unmasked, f"unmasked-{index}", 0) for index in range(2)]

normal_noise = abs(normal[0]["pixelRGBTotal"] - normal[1]["pixelRGBTotal"])
disabled_noise = abs(disabled[0]["pixelRGBTotal"] - disabled[1]["pixelRGBTotal"])
baseline_noise = max(normal_noise, disabled_noise)
assert normal[0]["pixelRGBAHash"] == normal[1]["pixelRGBAHash"], normal
assert disabled[0]["pixelRGBAHash"] == disabled[1]["pixelRGBAHash"], disabled
assert normal[0]["maskPasses"] == normal[1]["maskPasses"] > 0, normal
assert disabled[0]["maskPasses"] == disabled[1]["maskPasses"] == 0, disabled
ab_delta = min(
    abs(masked["pixelRGBTotal"] - unmasked["pixelRGBTotal"])
    for masked in normal
    for unmasked in disabled
)
assert ab_delta > baseline_noise * 10 + 1000, (
    ab_delta,
    baseline_noise,
    normal,
    disabled,
)
assert normal[0]["pixelRGBAHash"] != disabled[0]["pixelRGBAHash"], (
    normal,
    disabled,
)

print(
    f"puppet mask visual A/B: native Hyuga maskPasses={normal[0]['maskPasses']} "
    f"RGBDelta={ab_delta} baselineNoise={baseline_noise}; GBC has no masks"
)
