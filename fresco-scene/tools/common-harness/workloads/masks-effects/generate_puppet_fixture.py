#!/usr/bin/env python3

import argparse
import json
import pathlib
import struct


SKIN_INDICES = 0x00800000
SKIN_WEIGHTS = 0x01000000
UV = 0x00000008


def u8(value):
    return struct.pack("<B", value)


def u16(value):
    return struct.pack("<H", value)


def u32(value):
    return struct.pack("<I", value)


def i32(value):
    return struct.pack("<i", value)


def f32(value):
    return struct.pack("<f", value)


def cstring(value):
    return value.encode("utf-8") + b"\0"


def matrix(values):
    return b"".join(f32(value) for value in values)


def texture(width, height, rgba):
    payload = bytes(rgba)
    if len(payload) != width * height * 4:
        raise ValueError("texture payload size does not match its dimensions")
    return (
        b"TEXV0005\0" + b"TEXI0001\0"
        + u32(0) + u32(3)
        + u32(width) + u32(height) + u32(width) + u32(height) + u32(0)
        + b"TEXB0001\0" + u32(1)
        + u32(1) + u32(width) + u32(height) + i32(len(payload)) + payload
    )


def vertex(position, uv):
    identity_indices = (0, 0, 0, 0)
    identity_weights = (1.0, 0.0, 0.0, 0.0)
    return (
        b"".join(f32(value) for value in position)
        + b"".join(u32(value) for value in identity_indices)
        + b"".join(f32(value) for value in identity_weights)
        + b"".join(f32(value) for value in uv)
    )


def model(parameters, masked):
    source = parameters["sourceBounds"]
    target = parameters["targetBounds"]
    source_uv = parameters["sourceUV"]
    target_uv = parameters["targetUV"]

    def rectangle(bounds, uv):
        left, bottom, right, top = bounds
        return [
            vertex((left, bottom, 0.0), uv),
            vertex((right, bottom, 0.0), uv),
            vertex((right, top, 0.0), uv),
            vertex((left, top, 0.0), uv),
        ]

    vertices = rectangle(source, source_uv) + rectangle(target, target_uv)
    indices = (0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7)
    flags = SKIN_INDICES | SKIN_WEIGHTS | UV
    result = bytearray()
    result += b"MDLV0023\0"
    result += u32(0) + u32(1) + u32(1) + cstring("fresco-mask-fixture")
    result += u32(0)
    result += b"".join(f32(value) for value in (*source[:2], *target[2:], 0.0, 0.0))
    vertex_payload = b"".join(vertices)
    result += u32(flags) + u32(len(vertex_payload)) + vertex_payload
    index_payload = b"".join(u16(value) for value in indices)
    result += u32(len(index_payload)) + index_payload
    result += u8(0)
    result += u8(1) + u32(32)
    result += u32(1) + u32(0) + u32(0) + u32(6)
    result += u32(2) + u32(0) + u32(6) + u32(6)
    result += u32(1 if masked else 0)
    if masked:
        result += u32(101) + u32(0)
        result += cstring(parameters["maskTexture"])
        result += u32(0)
        result += u32(1) + u32(1)
        result += u32(1) + u32(0)
    result += b"MDLS0004\0"
    skeleton_end_offset = len(result)
    result += u32(0)
    result += u16(1) + u16(0)
    result += cstring("root") + i32(-1) + u32(0xFFFFFFFF) + u32(64)
    result += matrix(parameters["identityMatrix"])
    result += cstring("")
    result += b"\0"
    struct.pack_into("<I", result, skeleton_end_offset, len(result))
    return bytes(result)


def validate(data, expected_masks):
    offset = 0

    def take(count):
        nonlocal offset
        value = data[offset:offset + count]
        if len(value) != count:
            raise ValueError("generated puppet is truncated")
        offset += count
        return value

    def read_u8():
        return take(1)[0]

    def read_u16():
        return struct.unpack("<H", take(2))[0]

    def read_u32():
        return struct.unpack("<I", take(4))[0]

    def read_f32():
        return struct.unpack("<f", take(4))[0]

    def read_cstring():
        nonlocal offset
        end = data.index(0, offset)
        value = data[offset:end]
        offset = end + 1
        return value

    if take(9) != b"MDLV0023\0":
        raise ValueError("generated puppet has wrong model version")
    read_u32()
    if (read_u32(), read_u32()) != (1, 1):
        raise ValueError("generated puppet is not one mesh")
    read_cstring()
    if read_u32() != 0:
        raise ValueError("generated puppet has unexpected mesh preamble")
    take(24)
    flags = read_u32()
    if flags != SKIN_INDICES | SKIN_WEIGHTS | UV:
        raise ValueError("generated puppet vertex flags changed")
    vertex_bytes = read_u32()
    if vertex_bytes != 8 * 52:
        raise ValueError("generated puppet vertex count or stride changed")
    for _ in range(8):
        take(12)
        indices = [read_u32() for _ in range(4)]
        weights = [read_f32() for _ in range(4)]
        take(8)
        if indices != [0, 0, 0, 0] or weights != [1.0, 0.0, 0.0, 0.0]:
            raise ValueError("generated puppet weights are not normalized to root")
    index_bytes = read_u32()
    indices = [read_u16() for _ in range(index_bytes // 2)]
    if index_bytes != 24 or len(indices) != 12 or max(indices) >= 8:
        raise ValueError("generated puppet index buffer changed")
    if read_u8() != 0 or read_u8() != 1 or read_u32() != 32:
        raise ValueError("generated puppet part table changed")
    parts = []
    for _ in range(2):
        part = (read_u32(), read_u32(), read_u32(), read_u32())
        if part[1] != 0 or part[2] + part[3] > len(indices):
            raise ValueError("generated puppet part lies outside index buffer")
        parts.append(part)
    if parts != [(1, 0, 0, 6), (2, 0, 6, 6)]:
        raise ValueError("generated puppet source/target parts changed")
    if read_u32() != expected_masks:
        raise ValueError("generated puppet mask count changed")
    if expected_masks:
        read_u32(); read_u32(); read_cstring(); read_u32()
        targets = [read_u32() for _ in range(read_u32())]
        sources = [read_u32() for _ in range(read_u32())]
        if targets != [1] or sources != [0]:
            raise ValueError("generated puppet mask ordinals changed")
    if take(9) != b"MDLS0004\0":
        raise ValueError("generated puppet has wrong skeleton version")
    skeleton_end = read_u32()
    if (read_u16(), read_u16()) != (1, 0):
        raise ValueError("generated puppet does not have one root bone")
    read_cstring(); take(4)
    if read_u32() != 0xFFFFFFFF or read_u32() != 64:
        raise ValueError("generated puppet root binding changed")
    take(64); read_cstring()
    if skeleton_end != len(data) or offset >= skeleton_end:
        raise ValueError("generated puppet skeleton extent changed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("parameters", type=pathlib.Path)
    parser.add_argument("destination", type=pathlib.Path)
    arguments = parser.parse_args()
    parameters = json.loads(arguments.parameters.read_text(encoding="utf-8"))
    models = arguments.destination / "models"
    textures = arguments.destination / "materials"
    masks = textures / "masks"
    models.mkdir(parents=True, exist_ok=True)
    masks.mkdir(parents=True, exist_ok=True)
    masked = model(parameters, True)
    unmasked = model(parameters, False)
    validate(masked, 1)
    validate(unmasked, 0)
    (models / "masked.mdl").write_bytes(masked)
    (models / "unmasked.mdl").write_bytes(unmasked)
    (textures / "base.tex").write_bytes(texture(
        2, 1, parameters["baseRGBA"]
    ))
    (masks / "mask.tex").write_bytes(texture(
        1, 1, parameters["maskRGBA"]
    ))


if __name__ == "__main__":
    main()
