#!/usr/bin/env python3

import pathlib
import struct
import subprocess
import sys
import tempfile


PROBE = pathlib.Path(sys.argv[1])
WORKSHOP = pathlib.Path(sys.argv[2])


def read_u32(handle):
    return struct.unpack("<I", handle.read(4))[0]


def read_string(handle):
    return handle.read(read_u32(handle)).decode("utf-8")


def video_textures(item_id):
    with (WORKSHOP / item_id / "scene.pkg").open("rb") as handle:
        read_string(handle)
        entries = [
            (read_string(handle), read_u32(handle), read_u32(handle))
            for _ in range(read_u32(handle))
        ]
        base = handle.tell()
        videos = []
        for name, offset, length in entries:
            if not name.endswith(".tex"):
                continue
            handle.seek(base + offset)
            contents = handle.read(length)
            marker = contents.find(b"ftyp")
            if marker >= 4:
                videos.append((name, contents[marker - 4 :]))
        return videos


elaina = video_textures("3326873240")
hyuga = video_textures("3479521040")
persona = video_textures("3151551777")

assert [name for name, _ in elaina] == [
    "materials/窗边的伊蕾娜 昼夜变化.tex",
    "materials/窗边的伊蕾娜（黄昏）.tex",
    "materials/窗边的伊蕾娜（白天）.tex",
    "materials/窗边的伊蕾娜（夜晚）.tex",
    "materials/窗边的伊蕾娜（清晨）.tex",
]
assert not hyuga, "Hyuga has no authored video textures in the pinned package"
assert not persona, "Persona has media-session integration, not authored video textures"

with tempfile.TemporaryDirectory(prefix="fresco-scene-video-") as directory:
    paths = []
    for index, (_, contents) in enumerate(elaina):
        path = pathlib.Path(directory) / f"elaina-{index}.mp4"
        path.write_bytes(contents)
        paths.append(path)
    subprocess.run([PROBE, *paths], check=True, timeout=90)

print(
    "media video corpus: Elaina 5/5 embedded MP4 textures decode; "
    "Hyuga and Persona require non-video media paths"
)
