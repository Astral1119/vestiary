#!/usr/bin/env python3

"""Pins that an attached child inherits its parent bone's orientation.

GBC hangs the visible head off object 377, whose `attachment` names a bone on
179's puppet. Animation 196 (摇头) is pure rotation, so before orientation
propagated the head could not move at all. Every bound here is derived from the
authored track in the .mdl rather than from a constant, so re-authoring the
fixture fails the test instead of silently passing it.
"""

import json
import math
import os
import select
import struct
import subprocess
import sys
import time


HELPER = os.path.abspath(sys.argv[1])
WORKSHOP = os.path.abspath(sys.argv[2])
ASSETS = os.path.abspath(sys.argv[3])
EXPECTED_BACKEND = sys.argv[4]
GBC = os.path.join(WORKSHOP, "3448290956")
PUPPET = "models/左眼白_puppet.mdl"
ATTACHED_OBJECT = 377
PUPPET_OBJECT = 179
ROTATION_ANIMATION = 196


def package_entry(path, name):
    with open(path, "rb") as handle:
        def u32():
            return struct.unpack("<I", handle.read(4))[0]

        def string():
            return handle.read(u32()).decode("utf-8")

        string()
        entries = [(string(), u32(), u32()) for _ in range(u32())]
        base = handle.tell()
        _, offset, length = next(e for e in entries if e[0] == name)
        handle.seek(base + offset)
        return handle.read(length)


def rotation_track(mdl, animation_id):
    """angleZ per frame for bone 0 of one MDLA animation.

    Mirrors parseAnimation in renderer/src/PuppetModel.cpp; this fixture has a
    single bone, which is what keeps the reader this short.
    """
    cursor = mdl.index(b"MDLA0006") + 9
    _end, count = struct.unpack_from("<II", mdl, cursor)
    cursor += 8
    for _ in range(count):
        identifier = struct.unpack_from("<i", mdl, cursor)[0]
        cursor += 8
        for _ in range(2):  # name, then play mode
            end = mdl.index(b"\x00", cursor)
            if end == cursor:  # an empty name is followed by the real one
                cursor += 1
                end = mdl.index(b"\x00", cursor)
            cursor = end + 1
        _fps, length = struct.unpack_from("<fi", mdl, cursor)
        cursor += 12
        bones = struct.unpack_from("<I", mdl, cursor)[0]
        cursor += 4
        angles = []
        for bone in range(bones):
            cursor += 4
            size = struct.unpack_from("<I", mdl, cursor)[0]
            cursor += 4
            if bone == 0:
                for frame in range(size // 36):
                    angles.append(
                        struct.unpack_from("<f", mdl, cursor + frame * 36 + 20)[0]
                    )
            cursor += size
        if identifier == animation_id:
            assert len(angles) == length + 1, (len(angles), length)
            return angles
        raise AssertionError(f"animation {animation_id} is not first in {PUPPET}")
    raise AssertionError(f"animation {animation_id} missing from {PUPPET}")


track = rotation_track(package_entry(os.path.join(GBC, "scene.pkg"), PUPPET),
                       ROTATION_ANIMATION)
track_low, track_high = min(track), max(track)
track_span = track_high - track_low
assert track_span > 0.0, track_span

process = subprocess.Popen(
    [HELPER],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    bufsize=1,
)


def exchange(kind, expected, **values):
    process.stdin.write(
        json.dumps(
            {
                "protocolVersion": 1,
                "type": kind,
                "assignmentID": "puppet-attachment-orientation",
                **values,
            }
        )
        + "\n"
    )
    process.stdin.flush()
    readable, _, _ = select.select([process.stdout], [], [], 90)
    assert readable, (kind, "timed out")
    event = json.loads(process.stdout.readline())
    assert event["type"] == expected, event
    return event


ready = exchange(
    "load",
    "ready",
    path=GBC,
    assetRoot=ASSETS,
    width=320,
    height=180,
    visible=True,
    evidenceFrames=2,
)
assert ready["backend"] == EXPECTED_BACKEND, ready
assert ready["drawComplete"] is True, ready

# The rotation animation is 121 frames at 30 fps driven at rate 1.5, so a period
# is about 2.7 s; sample past two of them.
samples = []
for _ in range(24):
    time.sleep(0.30)
    exchange("capture-frame-difference", "frame-difference")
    evidence = exchange("capture-puppet-evidence", "puppet-evidence")
    attached = [
        a for a in evidence["attachments"] if a["objectID"] == ATTACHED_OBJECT
    ]
    assert len(attached) == 1, evidence["attachments"]
    samples.append((attached[0], evidence))

first, first_evidence = samples[0]
assert first["parentObjectID"] == PUPPET_OBJECT, first
assert first["name"] == "Attachment", first

blend = next(
    layer["appliedBlend"]
    for layer in first_evidence["layers"]
    if layer["objectID"] == PUPPET_OBJECT and layer["animationID"] == ROTATION_ANIMATION
)

for record, _ in samples:
    # Scene space is y-down and puppet space is y-up, so the applied angle is
    # the negation of the bone angle. Pinning the relation rather than a value
    # is what catches a sign regression.
    assert record["appliedAngle"] == -record["boneAngle"], record
    # The bone frame REPLACES the carrier's authored origin. Adding to it seats
    # the subtree low and tears the face mesh, so the resolved placement must be
    # the anchor itself and must not track the authored origin.
    assert record["resolvedX"] == record["anchorX"], record
    assert record["resolvedY"] == record["anchorY"], record
    # The seam may only ever apply an angle the track actually authors.
    assert track_low - 1e-6 <= record["boneAngle"] <= track_high + 1e-6, (
        record,
        (track_low, track_high),
    )

angles = [record["boneAngle"] for record, _ in samples]
observed = max(angles) - min(angles)
expected = blend * track_span
# Sampling is wall-clock, so the extremes are approached rather than hit; the
# bound that matters is that the swing is the blended track and not the raw one.
assert observed <= expected + 1e-4, (observed, expected)
assert observed > expected * 0.5, (observed, expected)

# It has to oscillate, not drift: the angle must reverse direction.
deltas = [b - a for a, b in zip(angles, angles[1:]) if abs(b - a) > 1e-9]
assert any(d > 0 for d in deltas) and any(d < 0 for d in deltas), angles

# The anchor sits on a lever arm from the bone pivot, so rotation moves the
# carrier's resolved origin even with no translation channel authored.
positions = {(round(r["resolvedX"], 4), round(r["resolvedY"], 4)) for r, _ in samples}
assert len(positions) > 1, positions
authored = {(round(r["authoredX"], 4), round(r["authoredY"], 4)) for r, _ in samples}
assert len(authored) == 1, authored

# Animation 186 animates this bone's scale, so the child inherits that too.
scales = {round(r["appliedScaleX"], 5) for r, _ in samples}
assert len(scales) > 1, scales

exchange("stop", "stopped")
process.stdin.close()
process.wait(timeout=10)
stderr = process.stderr.read()
assert not stderr, stderr

print(
    f"Puppet attachment orientation: {EXPECTED_BACKEND} object {ATTACHED_OBJECT} "
    f"inherits a bone angle spanning {math.degrees(observed):.2f} deg "
    f"(blend {blend:.2f} of a {math.degrees(track_span):.2f} deg track), "
    "with the anchor replacing the authored origin"
)
