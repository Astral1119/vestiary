#!/usr/bin/env python3

import copy
import hashlib
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops


RENDERER = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])
ASSETS = pathlib.Path(sys.argv[3])
PROJECT = WORKSHOP / "3460973721"
EXPECTED_SHA256 = "1dca928a8f1acf64e1f13aa7d2a7bc54631d452c7f613887030c1c972a2eb807"
PARTICLE_IDS = {46, 73}


def read_u32(handle):
    return struct.unpack("<I", handle.read(4))[0]


def read_string(handle):
    return handle.read(read_u32(handle)).decode("utf-8")


def encode_string(value):
    encoded = value.encode("utf-8")
    return struct.pack("<I", len(encoded)) + encoded


def read_package(path):
    with path.open("rb") as handle:
        revision = read_string(handle)
        entries = [
            (read_string(handle), read_u32(handle), read_u32(handle))
            for _ in range(read_u32(handle))
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


def scene_variant(payloads, *, particle_ids=PARTICLE_IDS, detached=False):
    result = []
    for name, payload in payloads:
        if name != "scene.json":
            result.append((name, payload))
            continue
        scene = json.loads(payload)
        objects = {item["id"]: copy.deepcopy(item) for item in scene["objects"]}
        selected = [objects[129], objects[16]]
        for particle_id in sorted(particle_ids):
            particle = objects[particle_id]
            if detached:
                particle.pop("parent", None)
            selected.append(particle)
        scene["objects"] = selected
        result.append(
            (name, json.dumps(scene, separators=(",", ":")).encode("utf-8"))
        )
    return result


def project_variant(root, name, revision, payloads):
    project = root / name
    project.mkdir()
    shutil.copy2(PROJECT / "project.json", project / "project.json")
    write_package(project / "scene.pkg", revision, payloads)
    return project


def render(project, output):
    environment = os.environ.copy()
    environment["FRESCO_SCENE_AUDIO_DISABLED"] = "1"
    environment["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "0"
    result = subprocess.run(
        [RENDERER, project, ASSETS, output, "120"],
        capture_output=True,
        check=False,
        env=environment,
        text=True,
        timeout=180,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"render failed ({result.returncode})\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    assert "frames=120" in result.stdout, result.stdout
    return Image.open(output).convert("RGB")


package = PROJECT / "scene.pkg"
assert hashlib.sha256(package.read_bytes()).hexdigest() == EXPECTED_SHA256
revision, payloads = read_package(package)
assert revision == "PKGV0024", revision
scene = json.loads(next(payload for name, payload in payloads if name == "scene.json"))
objects = {item["id"]: item for item in scene["objects"]}
assert {objects[item]["parent"] for item in PARTICLE_IDS} == {16}
assert objects[16]["parent"] == 129
assert {objects[item]["particle"] for item in PARTICLE_IDS} == {
    "particles/workshop/2446178284/rising_debris_copy1.json",
    "particles/workshop/2446178284/dust_copy1.json",
}

with tempfile.TemporaryDirectory(prefix="fresco-arknights-particles-") as directory:
    root = pathlib.Path(directory)
    parented = project_variant(
        root, "parented", revision, scene_variant(payloads)
    )
    detached = project_variant(
        root,
        "detached",
        revision,
        scene_variant(payloads, detached=True),
    )
    control = project_variant(
        root, "control", revision, scene_variant(payloads, particle_ids=set())
    )
    debris = project_variant(
        root, "debris", revision, scene_variant(payloads, particle_ids={46})
    )
    dust = project_variant(
        root, "dust", revision, scene_variant(payloads, particle_ids={73})
    )

    first = render(parented, root / "parented-first.png")
    second = render(parented, root / "parented-second.png")
    detached_image = render(detached, root / "detached.png")
    control_image = render(control, root / "control.png")
    debris_image = render(debris, root / "debris.png")
    dust_image = render(dust, root / "dust.png")

    assert first.tobytes() == second.tobytes(), "particle render changed across reload"
    particle_pixels = sum(
        pixel != (0, 0, 0)
        for pixel in ImageChops.difference(
            first, control_image
        ).get_flattened_data()
    )
    transform_pixels = sum(
        pixel != (0, 0, 0)
        for pixel in ImageChops.difference(first, detached_image).get_flattened_data()
    )
    debris_pixels = sum(
        pixel != (0, 0, 0)
        for pixel in ImageChops.difference(
            debris_image, control_image
        ).get_flattened_data()
    )
    dust_pixels = sum(
        pixel != (0, 0, 0)
        for pixel in ImageChops.difference(
            dust_image, control_image
        ).get_flattened_data()
    )
    assert particle_pixels > 1_000, particle_pixels
    assert transform_pixels > 1_000, transform_pixels
    assert debris_pixels > 100, debris_pixels
    assert dust_pixels > 100, dust_pixels

print(
    "Arknights particles: two custom systems render deterministically with "
    f"composed parent transforms; particle pixels={particle_pixels}, "
    f"transform pixels={transform_pixels}, debris pixels={debris_pixels}, "
    f"dust pixels={dust_pixels}"
)
